#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd /tmp

: "${DB_PASSWORD:?DB_PASSWORD manquant (voir .env)}"
: "${REPL_PASSWORD:?REPL_PASSWORD manquant (voir .env)}"
: "${NODE_IP:?NODE_IP manquant}"
: "${REPLICA_IP:?REPLICA_IP manquant}"

RESEAU_CIDR="${NODE_IP%.*}.0/24"

apt-get update -qq
apt-get install -y -qq --no-upgrade postgresql

VERSION_PG=$(ls /usr/lib/postgresql | sort -V | tail -1)
CONF=/etc/postgresql/${VERSION_PG}/main

# Écouter sur toutes les interfaces (piège n°1) : fichier réécrit => idempotent
cat > ${CONF}/conf.d/resultats.conf <<EOF
listen_addresses = '*'
EOF

# Règles d'accès, ajoutées une seule fois chacune
ajouter_regle() {
  grep -qxF "$1" ${CONF}/pg_hba.conf || echo "$1" >> ${CONF}/pg_hba.conf
}
ajouter_regle "host resultats   appuser    ${RESEAU_CIDR}     scram-sha-256"
ajouter_regle "host replication replicator ${REPLICA_IP}/32   scram-sha-256"

systemctl restart postgresql

# Utilisateurs : l'application (lecture) et la réplication
sudo -u postgres psql -v ON_ERROR_STOP=1 -v mdp="$DB_PASSWORD" -v rmdp="$REPL_PASSWORD" <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'appuser') THEN
    CREATE ROLE appuser LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator LOGIN REPLICATION;
  END IF;
END $$;
ALTER ROLE appuser PASSWORD :'mdp';
ALTER ROLE replicator PASSWORD :'rmdp';
SQL

# Base de données
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = 'resultats'" | grep -q 1 \
  || sudo -u postgres createdb -O appuser resultats

# Table et 50 000 lignes, remplies une seule fois (données déterministes)
sudo -u postgres psql -d resultats -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS resultats (
  matricule text PRIMARY KEY,
  nom       text NOT NULL,
  serie     text NOT NULL,
  moyenne   numeric(4,2) NOT NULL,
  admis     boolean NOT NULL
);
INSERT INTO resultats
SELECT 'BF' || lpad(g::text, 6, '0'),
       'Candidat ' || g,
       (ARRAY['A','C','D','E'])[1 + g % 4],
       m,
       m >= 10
FROM (SELECT g, ((g * 37) % 2001) / 100.0 AS m FROM generate_series(1, 50000) AS g) AS t
WHERE NOT EXISTS (SELECT 1 FROM resultats);
GRANT SELECT ON resultats TO appuser;
SQL
