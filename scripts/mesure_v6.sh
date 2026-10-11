#!/usr/bin/env bash
# Mesure V6 : panne de lb1, reprise par lb2 via la VIP (E1).
# Prerequis : lb1 et lb2 demarrees et provisionnees (LB2 actif).
# Usage : bash scripts/mesure_v6.sh            (arret propre de lb1)
#         bash scripts/mesure_v6.sh brutal     (arret force, comme une vraie panne)
set -uo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-propre}"
[ -f config/noeuds.yml ] || { echo "config/noeuds.yml absent : lancez d'abord une commande vagrant"; exit 1; }
IP_LB1=$(awk '/nom: lb1/{f=1} f&&/ip:/{print $2; exit}' config/noeuds.yml)
VIP="${IP_LB1%.*}.5"
SORTIE="docs/mesures/v6-vrrp.txt"
mkdir -p docs/mesures
TMP=$(mktemp)

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$VIP/info")
[ "$code" = 200 ] || { echo "La VIP $VIP ne repond pas avant la panne (HTTP $code)"; exit 1; }

( while true; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://$VIP/info")
    echo "$(date +%s%3N) $c"
    sleep 0.2
  done ) > "$TMP" &
BOUCLE=$!

sleep 3
T_HALT=$(date +%s%3N)
if [ "$MODE" = "brutal" ]; then
  vagrant halt lb1 --force --no-color
else
  vagrant halt lb1 --no-color
fi
sleep 10
kill "$BOUCLE" 2>/dev/null
wait "$BOUCLE" 2>/dev/null

{
echo "=== V6 panne de lb1 - $(date) ==="
echo "VIP : $VIP"
echo "Mode : $MODE"
echo "Requetes totales : $(wc -l < "$TMP")"
awk -v th="$T_HALT" '$1>=th && $2!=200 { if(!f) f=$1; l=$1; n++ }
  END { if (n) printf "Requetes en echec : %d, coupure d environ %d ms\n", n, l-f+200;
        else print "Aucune requete en echec" }' "$TMP"
echo "Derniere reponse : HTTP $(tail -1 "$TMP" | cut -d' ' -f2)"
} | tee -a "$SORTIE"
rm -f "$TMP"
