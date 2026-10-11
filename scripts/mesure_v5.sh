#!/usr/bin/env bash
# Mesure V5 : destruction puis reconstruction complete de la plateforme (R1).
# ATTENTION : detruit toutes les VM du projet, donnees comprises.
# Usage : bash scripts/mesure_v5.sh [-y]      (-y : sans confirmation)
set -uo pipefail
cd "$(dirname "$0")/.."

SORTIE="docs/mesures/v5-reconstruction.txt"
mkdir -p docs/mesures

if [ "${1:-}" != "-y" ]; then
  read -r -p "Detruit toutes les VM puis reconstruit (15 a 30 min). Continuer ? [o/N] " rep
  [ "$rep" = "o" ] || { echo "Annule."; exit 1; }
fi

{
echo "=== V5 reconstruction - $(date) ==="
echo "NB_APP=${NB_APP:-2} LB2=${LB2:-0}"

t0=$(date +%s)
echo '$ vagrant destroy -f'
vagrant destroy -f --no-color
echo '$ vagrant up'
vagrant up --no-color
code_up=$?
duree=$(( $(date +%s) - t0 ))
echo "Code de sortie de vagrant up : $code_up"
printf "Duree totale (destroy + up) : %d min %d s\n" $((duree/60)) $((duree%60))

echo "--- Controles apres reconstruction ---"
ok=1
[ "$code_up" = 0 ] || ok=0

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/sante)
echo "GET /sante : HTTP $code"
[ "$code" = 200 ] || ok=0

printf "GET /resultat?matricule=BF000042 : "
curl -s --max-time 10 "http://localhost:8080/resultat?matricule=BF000042"
echo

repl=$(vagrant ssh bdd1 -c "sudo -u postgres psql -tAc \"SELECT count(*) FROM pg_stat_replication WHERE state='streaming'\"" 2>/dev/null | tr -d '\r')
echo "Repliques en streaming : $repl"
[ "$repl" = 1 ] || ok=0

if [ "$ok" = 1 ]; then echo "RESULTAT : OK"; else echo "RESULTAT : ECHEC"; fi
} 2>&1 | tee "$SORTIE"
