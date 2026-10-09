#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd /tmp

: "${REPL_PASSWORD:?REPL_PASSWORD manquant (voir .env)}"
: "${PRIMARY_IP:?PRIMARY_IP manquant}"
: "${NODE_IP:?NODE_IP manquant}"

RESEAU_CIDR="${NODE_IP%.*}.0/24"

apt-get update -qq
apt-get install -y -qq --no-upgrade postgresql

VERSION_PG=$(ls /usr/lib/postgresql | sort -V | tail -1)
CONF=/etc/postgresql/${VERSION_PG}/main
DATA=/var/lib/postgresql/${VERSION_PG}/main

# Mot de passe de réplication, pour la connexion permanente avec bdd1
cat > /var/lib/postgresql/.pgpass <<EOF
${PRIMARY_IP}:5432:replication:replicator:${REPL_PASSWORD}
EOF
chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

# Écouter sur toutes les interfaces, lecture seule autorisée sur la réplique
cat > ${CONF}/conf.d/resultats.conf <<EOF
listen_addresses = '*'
hot_standby = on
EOF

# Mêmes règles d'accès que bdd1 : l'application doit pouvoir se connecter ici
# après une promotion
ajouter_regle() {
  grep -qxF "$1" ${CONF}/pg_hba.conf || echo "$1" >> ${CONF}/pg_hba.conf
}
ajouter_regle "host resultats   appuser    ${RESEAU_CIDR}     scram-sha-256"

# Attendre que la base primaire réponde (bdd1 est démarrée avant bdd2)
for i in $(seq 1 30); do
  pg_isready -q -h "${PRIMARY_IP}" -p 5432 && break
  sleep 2
done

# Copie initiale, une seule fois : standby.signal prouve qu'elle est faite
if [ ! -f "${DATA}/standby.signal" ]; then
  systemctl stop postgresql
  rm -rf "${DATA:?}"/*
  sudo -u postgres pg_basebackup -h "${PRIMARY_IP}" -U replicator \
       -D "${DATA}" -R -X stream
fi

systemctl restart postgresql
