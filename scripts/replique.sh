#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd /tmp

: "${REPL_PASSWORD:?REPL_PASSWORD manquant (voir .env)}"
: "${PRIMARY_IP:?PRIMARY_IP manquant}"
: "${NODE_IP:?NODE_IP manquant}"

. /vagrant/scripts/lib.sh

RESEAU_CIDR="${NODE_IP%.*}.0/24"

apt-get update -qq
apt-get install -y -qq --no-upgrade postgresql

VERSION_PG=$(ls /usr/lib/postgresql | sort -V | tail -1)
CONF=/etc/postgresql/${VERSION_PG}/main
DATA=/var/lib/postgresql/${VERSION_PG}/main
# Témoin de la copie initiale, HORS du répertoire de données : il survit à
# une promotion (qui supprime standby.signal) et disparaît avec la VM.
MARQUEUR=/var/lib/postgresql/.replique_initialisee

# Mot de passe de réplication, pour la connexion permanente avec bdd1
cat > /var/lib/postgresql/.pgpass <<EOF
${PRIMARY_IP}:5432:replication:replicator:${REPL_PASSWORD}
EOF
chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

# Écouter sur toutes les interfaces, lecture seule autorisée sur la réplique.
# CHANGED=1 seulement si la configuration a réellement changé (R2)
CHANGED=0
cat > /tmp/resultats-pg.conf <<EOF
listen_addresses = '*'
hot_standby = on
EOF
if install_si_different /tmp/resultats-pg.conf "${CONF}/conf.d/resultats.conf" 644; then CHANGED=1; fi

# Mêmes règles d'accès que bdd1 : l'application doit pouvoir se connecter ici
# après une promotion
ajouter_regle() {
  grep -qxF "$1" "${CONF}/pg_hba.conf" || { echo "$1" >> "${CONF}/pg_hba.conf"; CHANGED=1; }
}
ajouter_regle "host resultats   appuser    ${RESEAU_CIDR}     scram-sha-256"

# VM construite avant l'ajout du marqueur : la copie existe déjà si bdd2 est
# une réplique (standby.signal) ou si elle contient la base resultats (réplique
# promue). Une installation neuve de PostgreSQL ne contient pas cette base.
if [ ! -f "${MARQUEUR}" ]; then
  if [ -f "${DATA}/standby.signal" ] || sudo -u postgres psql -tAc \
       "SELECT 1 FROM pg_database WHERE datname = 'resultats'" 2>/dev/null | grep -q 1; then
    touch "${MARQUEUR}"
  fi
fi

# Copie initiale, une seule fois dans la vie de la VM. Le test portait sur
# standby.signal seul : après une bascule (pg_promote supprime ce fichier),
# un simple « vagrant provision bdd2 » effaçait la nouvelle primaire.
# Pour refaire volontairement la copie : supprimer ${MARQUEUR}.
if [ ! -f "${MARQUEUR}" ]; then
  # Attendre que la base primaire réponde (bdd1 est démarrée avant bdd2)
  for _ in $(seq 1 30); do
    pg_isready -q -h "${PRIMARY_IP}" -p 5432 && break
    sleep 2
  done
  systemctl stop postgresql
  rm -rf "${DATA:?}"/*
  sudo -u postgres pg_basebackup -h "${PRIMARY_IP}" -U replicator \
       -D "${DATA}" -R -X stream
  touch "${MARQUEUR}"
  CHANGED=1
fi

# Redémarrer seulement si quelque chose a changé ou si le serveur est arrêté
if [ "${CHANGED}" = 1 ] || ! systemctl is-active --quiet "postgresql@${VERSION_PG}-main"; then
  systemctl restart postgresql
fi
