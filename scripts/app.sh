#!/usr/bin/env bash
# Provisionnement du serveur applicatif (rôle : ingénieur applicatif).
# Idempotent : vagrant provision rejoué ne modifie rien et ne redémarre pas le
# service, sauf si le code, l'environnement ou l'unité ont réellement changé.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd /tmp

: "${DB_PASSWORD:?DB_PASSWORD manquant (voir .env)}"
: "${PRIMARY_IP:?PRIMARY_IP manquant}"
: "${NODE_IP:?NODE_IP manquant}"
: "${REPLICA_IP:?REPLICA_IP manquant}"

. /vagrant/scripts/lib.sh

# Un seul appel apt (contrainte : provisionnement derrière connexion lente)
apt-get update -qq
apt-get install -y -qq --no-upgrade python3-psycopg2 curl apache2-utils

install -d -m 755 /opt/resultats

# Environnement du service : le mot de passe ne passe que par /etc/default,
# jamais dans le dépôt (R7) ni dans la ligne de commande (ps visible)
#
# Choix C (ordre primaire d'abord) : DB_HOST commence par la PRIMAIRE pour
# éviter que chaque requête tente d'abord la réplique (lecture seule) :
# mesuré à ~86 req/s avec l'ordre réplique,primaire contre ~156 req/s ici.
# Après une panne de bdd1, scripts/bascule.sh réécrit cet ordre côté app et
# redémarre le service (voir étape 5/5 de bascule.sh).
#
# Pool de connexions (V3) : ouvrir une connexion authentifiée par requête
# saturait bdd1 sous charge (50 requêtes concourantes : 1 à 2 s par connexion,
# /sante au-delà du timeout de HAProxy, rafale de 503). DB_POOL connexions au
# plus par serveur applicatif : 4 serveurs x 10 = 40, loin du max_connections
# de PostgreSQL (100). DB_POOL_TIMEOUT borne l'attente : au-delà, 503 rapide.
cat > /tmp/resultats.env <<EOF
DB_HOST=${PRIMARY_IP},${REPLICA_IP}
DB_TARGET=read-write
DB_TIMEOUT=1
DB_POOL=10
DB_POOL_TIMEOUT=0.5
DB_PORT=5432
DB_NAME=resultats
DB_USER=appuser
DB_PASSWORD=${DB_PASSWORD}
APP_PORT=3000
EOF
# lib.sh renvoie 0 si le fichier a été (ré)installé, 1 s'il était déjà à jour
CHANGED=0
if install_si_different /tmp/resultats.env /etc/default/resultats 600; then CHANGED=1; fi

# Unité systemd : Restart=on-failure, mais jamais au démarrage d'une base
# absente — l'application doit simplement démarrer et répondre 503 sur /sante
cat > /tmp/resultats.service <<'EOF'
[Unit]
Description=Service applicatif RESULTATS-BF (sans etat)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/default/resultats
ExecStart=/usr/bin/python3 /opt/resultats/serveur.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
if install_si_different /tmp/resultats.service /etc/systemd/system/resultats.service 644; then CHANGED=1; fi

# Le code applicatif
if install_si_different /vagrant/app/serveur.py /opt/resultats/serveur.py 755; then CHANGED=1; fi

systemctl daemon-reload
systemctl enable resultats > /dev/null 2>&1
if [ "${CHANGED}" = 1 ]; then
  systemctl restart resultats          # redémarre seulement si quelque chose a changé
fi

# Vérification : le service doit répondre. /info ne dépend pas de la base,
# contrairement à /sante (503 légitime si bdd1 n'est pas encore prête).
systemctl is-active --quiet resultats
REPONDU=0
for i in $(seq 1 10); do
  if curl -fsS --max-time 2 http://127.0.0.1:3000/info; then REPONDU=1; break; fi
  sleep 1
done
[ "${REPONDU}" = 1 ] || { echo "ECHEC : le service ne repond pas sur :3000"; exit 1; }
echo " app provisionne, ecoute sur 0.0.0.0:3000"
