#!/usr/bin/env bash
# Mesure V4 avec l'application : normal -> panne de bdd1 -> bascule -> reprise.
# Prérequis : bdd1 (primaire), bdd2 (réplique) et app1 démarrées.
# Usage : ./scripts/mesure_v4.sh [fichier_de_sortie]
set -uo pipefail
cd "$(dirname "$0")/.."

[ -f config/noeuds.yml ] || { echo "config/noeuds.yml absent : lancez d'abord une commande vagrant"; exit 1; }
IP_APP=$(awk '/nom: app1/{f=1} f&&/ip:/{print $2; exit}' config/noeuds.yml)
URL="http://${IP_APP}:8000"
SORTIE="${1:-docs/mesures/v4-application-final.txt}"

mesure() {  # $1 = libellé, $2 = chemin
  curl -s -o /dev/null -w "$1 : HTTP %{http_code} en %{time_total}s\n" --max-time 10 "${URL}$2"
}

{
echo "=== V4 avec application - $(date) ==="
echo "--- 1. Fonctionnement normal (bdd1 primaire) ---"
mesure "/sante" /sante
mesure "/resultat" "/resultat?matricule=BF000001"
echo "--- 2. bdd1 arretee, bdd2 encore en lecture seule ---"
vagrant halt bdd1 > /dev/null 2>&1
mesure "/sante" /sante
echo "--- 3. Bascule, puis attente du retour a 200 ---"
debut=$(date +%s.%N)
./scripts/bascule.sh 2>&1
code=000
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${URL}/sante")
  [ "$code" = 200 ] && break
  sleep 1
done
fin=$(date +%s.%N)
awk -v d="$debut" -v f="$fin" -v c="$code" 'BEGIN{printf "Dernier code : %s ; retour a 200 apres %.1f s (bascule comprise)\n", c, f-d}'
echo "--- 4. Apres bascule (bdd2 primaire) ---"
mesure "/sante" /sante
mesure "/resultat" "/resultat?matricule=BF000001"
} 2>&1 | tee "${SORTIE}"
