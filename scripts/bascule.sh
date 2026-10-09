#!/usr/bin/env bash
# Bascule : promeut bdd2 en primaire quand bdd1 est en panne (R6, scénario V4).
# À lancer depuis l'hôte, à la racine du dépôt : ./scripts/bascule.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f config/noeuds.yml ] || { echo "config/noeuds.yml absent : lancez d'abord une commande vagrant"; exit 1; }
IP_BDD1=$(awk '/nom: bdd1/{f=1} f&&/ip:/{print $2; exit}' config/noeuds.yml)

ssh_bdd2() { vagrant ssh bdd2 -c "$1" < /dev/null; }

debut=$(date +%s.%N)

echo "[1/4] bdd2 est-elle demarree ?"
vagrant status bdd2 | grep -q "^bdd2 .*running" || { echo "ECHEC : bdd2 n'est pas demarree"; exit 1; }

echo "[2/4] bdd1 doit etre injoignable (sinon : risque de split-brain)"
if ssh_bdd2 "pg_isready -q -h ${IP_BDD1} -p 5432 -t 3"; then
  echo "REFUS : bdd1 repond encore. Promouvoir bdd2 creerait deux primaires."
  exit 1
fi

echo "[3/4] bdd2 est-elle bien une replique ?"
etat=$(ssh_bdd2 "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'" | tr -d '[:space:]')
[ "$etat" = "t" ] || { echo "ECHEC : bdd2 n'est pas une replique (deja promue ?)"; exit 1; }

echo "[4/4] Promotion de bdd2"
ssh_bdd2 "sudo -u postgres psql -tAc 'SELECT pg_promote(true, 60)'" > /dev/null
etat=$(ssh_bdd2 "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'" | tr -d '[:space:]')
[ "$etat" = "f" ] || { echo "ECHEC : bdd2 est toujours en lecture seule"; exit 1; }

fin=$(date +%s.%N)
echo "OK : bdd2 est maintenant la base primaire."
awk -v d="$debut" -v f="$fin" 'BEGIN{printf "Duree de la bascule : %.1f s\n", f-d}'
