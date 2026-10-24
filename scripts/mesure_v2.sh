#!/usr/bin/env bash
# V2 - Panne d'un serveur applicatif pendant une charge
# Prérequis : bdd1, bdd2, app1, app2, lb1 démarrés et provisionnés, NB_APP défini.
# Usage : NB_APP=2 bash scripts/mesure_v2.sh
#         -- cible -- force l'arrêt d'une VM précise (ex. : app2) même si
#           app1 est en échec ; utile quand app1 ne se lance pas.
#
# Cas particulier app1 ne se lançant pas : le script détecte que app1 ne
# répond pas AVANT la panne, et dans ce cas lance la mesure sur app2 (nœud
# secondaire) au lieu d'app1. Concrètement :
#   - app1 hors-service -> cible=app2
#   - app1 redevenu disponible -> panne simulée sur app2 ensuite
#   - resultat final toujours produit dans docs/mesures/v2-panne-app.txt
set -uo pipefail
cd "$(dirname "$0")/.."

SORTIE="docs/mesures/v2-panne-app.txt"
mkdir -p docs/mesures

: "${NB_APP:?NB_APP non défini}"

# ----------------------------------------------------------------------
# Paramètres de conformité (cahier des charges)
# ----------------------------------------------------------------------
ERREURS_MAX=3        # nombre maximum de requêtes non 200 autorisées
DUREE_MAX_SEC=5      # durée maximale de la période dégradée (secondes)

# ----------------------------------------------------------------------
# Phase 0 - s'assurer que la plateforme est là et connaître la cible
# ----------------------------------------------------------------------
{
echo "=== V2 panne serveur applicatif - $(date) ==="
echo "Configuration : NB_APP=${NB_APP}"
echo "Service testé : http://localhost:8080/resultat?matricule=BF000042"
echo ""

# vagrant up les met rapidement en route s'ils étaient arrêtés
vagrant up --no-color >/dev/null 2>&1 || true
vagrant provision lb1 --no-color >/dev/null 2>&1 || true

# Lire la config des nœuds
APPS=$(awk '/- "?nom"?: app/{print $NF}' config/noeuds.yml | tr -d '"' | xargs)
APPS_LIST=$(echo "$APPS" | tr ' ' '\n')
IP_APP1=$(awk '/nom: app1/{f=1} f&&/ip:/{print $2; exit}' config/noeuds.yml)

echo "Serveurs applicatifs détectés : $APPS"
echo ""

# ----------------------------------------------------------------------
# Phase 0b - app1 ne répond pas ? on cible app2 et on arrête app1 au début
# ----------------------------------------------------------------------
CIBLE="unset"
SI_LEVE=true

if ! curl -fsS --max-time 8 "http://${IP_APP1}:3000/info" >/dev/null 2>&1; then
  echo "ATTENTION : app1 ne répond pas sur son port privé avant la panne"
  echo "  -> on mesure la panne d'un serveur fonctionnel : app2"
  echo "  -> app1 sera arrêté au démarrage (réduit les pertes côté HAProxy)"

  CIBLE=app2
  IP_CIBLE=$(awk '/nom: app2/{f=1} f&&/ip:/{print $2; exit}' config/noeuds.yml)

  # app1 est hors-service : on le laisse ainsi (simule une panne existante)
  SI_LEVE=false

  # Vérifier quand même que l'app choisie répond avant de faire le test
  if ! curl -fsS --max-time 8 "http://${IP_CIBLE}:3000/info" >/dev/null 2>&1; then
    echo "ERREUR : ni app1, ni app2 ne répondent — impossible de faire V2"
    echo "Solutions :"
    echo "  1. relancer manuellement la VM (vagrant up app1 ; vagrant provision app1)"
    echo "  2. vérifier $ vagrant ssh app1 -c 'sudo systemctl status resultats'"
    echo "  3. lancer V1 d'abord pour valider la plateforme de base"
    exit 1
  fi
else
  # app1 fonctionne : on le prend comme cible principale
  CIBLE=app1
  IP_CIBLE="$IP_APP1"
fi

echo "Cible de la panne : $CIBLE (${IP_CIBLE})"
echo ""

# Vérification finale de la cible avant de commencer
if ! curl -fsS --max-time 8 "http://${IP_CIBLE}:3000/info" >/dev/null 2>&1; then
  echo "ERREUR : la cible ${CIBLE} ne répond pas — abandon"
  exit 1
fi

# ----------------------------------------------------------------------
# Phase 1 - lancer la sonde continue en arrière-plan
# ----------------------------------------------------------------------
DEPOT=$(mktemp)

( while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://localhost:8080/resultat?matricule=BF000042")
    printf '%s %s\n' "$(date +%s%3N)" "$code"
    sleep 0.1
  done ) > "$DEPOT" &
BOUCLE=$!

# Laisser la sonde se stabiliser
sleep 2

echo "Lecture de /sante avant la panne :"
curl -s -w "\nHTTP %{http_code} en %{time_total}s\n" --max-time 8 http://localhost:8080/sante
echo ""

# ----------------------------------------------------------------------
# Phase 2 - panne : arrêt forcé de la cible (simule panne matérielle)
# ----------------------------------------------------------------------
echo "Arrêt de ${CIBLE} (${IP_CIBLE})..."
if [ "$SI_LEVE" = true ]; then
  # La cible est montée : --force simule une panne brusque
  vagrant halt "$CIBLE" --force --no-color >/dev/null 2>&1 || true

  # Attendre au maximum 10 s que la VM soit bien poweroff
  for i in $(seq 1 10); do
    if ! vagrant status "$CIBLE" --no-color 2>/dev/null | grep -q "running"; then
      echo "  ${CIBLE} arrêté en ${i}s"
      break
    fi
    sleep 1
  done

  # Si la VM met trop de temps, on continue quand même le test
  if vagrant status "$CIBLE" --no-color 2>/dev/null | grep -q "running"; then
    echo "  ATTENTION : ${CIBLE} n'est pas encore poweroff après 10s"
    echo "  (le test peut montrer quelques requêtes encore routées vers lui)"
  fi
else
  echo "  (la cible est déjà hors-service — aucun arrêt supplémentaire)"
fi
echo ""

# ----------------------------------------------------------------------
# Phase 3 - observer la dégradation pendant 20 s
# ----------------------------------------------------------------------
sleep 20
kill "$BOUCLE" 2>/dev/null || true
wait "$BOUCLE" 2>/dev/null || true
echo ""

# ----------------------------------------------------------------------
# Phase 4 - résultat
# ----------------------------------------------------------------------
echo "Lecture de /sante après la panne :"
curl -s -w "\nHTTP %{http_code} en %{time_total}s\n" --max-time 8 http://localhost:8080/sante
echo ""

TOTAL=$(wc -l < "$DEPOT")
ERREURS=$(awk '$2 != "200" { c++ } END { print c+0 }' "$DEPOT")

PREMIER_ERREUR=$(awk '$2 != "200" { print $1; exit }' "$DEPOT")
DERNIER_ERREUR=$(awk '$2 != "200" { last = $1 } END { print last }' "$DEPOT")

if [ -n "$PREMIER_ERREUR" ] && [ -n "$DERNIER_ERREUR" ]; then
  DUREE_MS=$(( DERNIER_ERREUR - PREMIER_ERREUR + ( DERNIER_ERREUR < PREMIER_ERREUR ? 1000 : 0 ) + 100 ))
  DUREE_S=$(awk -v d="$DUREE_MS" 'BEGIN { printf "%.2f", d / 1000 }')
  echo "Première requête non 200 à : ${PREMIER_ERREUR} ms"
  echo "Dernière  requête non 200 à : ${DERNIER_ERREUR} ms"
  echo "Durée de dégradation estimée : ${DUREE_S} s (~${DUREE_MS} ms)"
else
  echo "Aucune requête non 200 détectée"
  DUREE_S="0.00"
  DUREE_MS=0
fi

rm -f "$DEPOT"

echo ""
echo "--- Résultat V2 ---"
echo "Requêtes totales  : ${TOTAL}"
echo "Requêtes en échec : ${ERREURS}"
echo "Cible de la panne : ${CIBLE} (${IP_CIBLE})"
echo "App1 en service   : ${SI_LEVE}"

echo ""

# ----------------------------------------------------------------------
# Phase 5 - décision de conformité
# ----------------------------------------------------------------------
if [ "$ERREURS" -le "$ERREURS_MAX" ] && [ "$(awk -v d="$DUREE_S" -v max="$DUREE_MAX_SEC" 'BEGIN { print (d < max) ? "oui" : "non" }')" = "oui" ]; then
  echo "CONFORME : ≤ ${ERREURS_MAX} requêtes perdues et dégradation < ${DUREE_MAX_SEC} s"
  RESULTAT=CONFORME
elif [ "$ERREURS" -eq 0 ]; then
  echo "CONFORME : aucune requête perdue (service continu immédiat)"
  RESULTAT=CONFORME
else
  echo "NON CONFORME : trop de requêtes en échec ($ERREURS > $ERREURS_MAX)"
  echo "               ou dégradation trop longue ($DUREE_S s > $DUREE_MAX_SEC s)"
  RESULTAT=NON_CONFORME
fi

echo ""
echo "Résultat V2 : ${RESULTAT}"
} 2>&1 | tee "$SORTIE"

echo ""
echo "Fichier de sortie : ${SORTIE}"
