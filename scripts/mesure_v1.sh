#!/usr/bin/env bash
# V1 - Test de répartition (round-robin)
# Usage : bash scripts/mesure_v1.sh
#
# Ce script vérifie que :
# - Les serveurs applicatifs sont équitablement répartis
# - L'écart entre le plus et le moins sollicité est < 20%
# - Le round-robin fonctionne correctement
#
# Reset automatique : ce script ne modifie pas l'infrastructure
# (pas de machine arrêtée, juste des requêtes HTTP)

set -euo pipefail
cd "$(dirname "$0")/.."

# Obtenir la liste des serveurs applicatifs depuis noeuds.yml
APPS=$(awk '/- "?nom"?: app/{print $NF}' config/noeuds.yml | tr -d '"')
NB_APPS=$(echo "$APPS" | wc -w | tr -d " ")

# Un fichier par configuration : la mesure N=4 ne remplace plus celle de N=2
SORTIE="docs/mesures/v1-n${NB_APPS}.txt"
mkdir -p docs/mesures
TMP_BUFFER=$(mktemp)

# Vérifier que la plateforme est opérationnelle
if ! curl -fsS --max-time 5 http://localhost:8080/sante >/dev/null 2>&1; then
  echo "ERREUR : la plateforme ne répond pas (sante)"
  echo "Vérifiez : vagrant up && vagrant provision lb1"
  exit 1
fi

# Lancer 20 requêtes /info pour observer la répartition
declare -A COMPTEURS
TOTAL=0

{
echo "=== V1 - Test de répartition (round-robin) - $(date) ==="
echo "Configuration : NB_APP=${NB_APP:-2} serveurs applicatifs"
echo "Plateforme : HAProxy round-robin"
echo ""
echo "Serveurs applicatifs détectés : $NB_APPS ($APPS)"
echo ""

echo "Lancement de 20 requêtes /info..."
echo ""

for i in $(seq 1 20); do
  response=$(curl -s --max-time 5 http://localhost:8080/info)
  host=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('host','inconnu'))" 2>/dev/null || echo "?")
  COMPTEURS["$host"]=$(( ${COMPTEURS["$host"]:-0} + 1 ))
  TOTAL=$((TOTAL + 1))
  echo "  Requête $i : $host"
done

echo ""
echo "=== Résultats ==="
echo "Total des requêtes : $TOTAL"
echo ""

echo "Répartition :"
MAX=0
MIN=$TOTAL
SERVEUR_MAX=""
SERVEUR_MIN=""

for host in $APPS; do
  count=${COMPTEURS["$host"]:-0}
  if [ "$count" -gt 0 ]; then
    PCT=$(awk -v c="$count" -v t="$TOTAL" 'BEGIN{printf "%.1f", c/t*100}')
    printf "  %-10s : %3d requêtes (%.1f%%)\n" "$host" "$count" "$PCT"
    if [ "$count" -gt "$MAX" ]; then
      MAX=$count
      SERVEUR_MAX="$host"
    fi
    if [ "$count" -lt "$MIN" ]; then
      MIN=$count
      SERVEUR_MIN="$host"
    fi
  else
    echo "  $host : 0 requêtes (server non sollicité)"
    if [ "$MIN" -gt 0 ]; then
      MIN=0
      SERVEUR_MIN="$host"
    fi
  fi
done

echo ""
echo "=== Analyse ==="
echo "Serveur le plus sollicité : $SERVEUR_MAX ($MAX requêtes)"
echo "Serveur le moins sollicité : $SERVEUR_MIN ($MIN requêtes)"
echo ""

if [ "$TOTAL" -gt 0 ] && [ "$MAX" -gt 0 ]; then
  ECART=$(awk -v min="$MIN" -v max="$MAX" -v total="$TOTAL" 'BEGIN{printf "%.1f", (max-min)/total*100}')
  echo "Écart relatif : ($MAX - $MIN) / $TOTAL = $ECART %"
  echo "Seuil de conformité : < 20 %"
  echo ""
  
  if [ "$(awk -v e="$ECART" 'BEGIN{print (e < 20) ? "oui" : "non"}')" = "oui" ]; then
    echo "CONFORME : écart de $ECART % (< 20 %)"
    echo "Le round-robin fonctionne correctement."
    RESULTAT=CONFORME
  else
    echo "NON CONFORME : écart de $ECART % (>= 20 %)"
    echo "La répartition n'est pas équitable."
    RESULTAT=NON_CONFORME
  fi
else
  echo "ERREUR : impossible de calculer l'écart (TOTAL=$TOTAL, MAX=$MAX)"
  RESULTAT=ERREUR
fi

echo ""
echo "=== Conclusion ==="
echo "Résultat : $RESULTAT"

if [ "$RESULTAT" = "CONFORME" ]; then
  echo ""
  echo "Test V1 réussi : répartition équitable"
elif [ "$RESULTAT" = "NON_CONFORME" ]; then
  echo ""
  echo "Test V1 échoué : répartition inégale"
  echo "  Vérifiez :"
  echo "    - HAProxy est bien configuré (backend apps)"
  echo "    - Tous les serveurs sont UP (systemctl is-active resultats)"
  echo "    - La sonde /sante répond 200 sur chaque serveur"
fi

} > "$TMP_BUFFER" 2>&1

cat "$TMP_BUFFER"
cat "$TMP_BUFFER" > "$SORTIE"
rm -f "$TMP_BUFFER"

echo ""
echo "Résultat final : $RESULTAT"
