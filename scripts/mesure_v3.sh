#!/usr/bin/env bash
# Mesure V3 : montée en charge, débit avec N=2 puis N=4 serveurs applicatifs.
#
# Pour chaque configuration : mise à l'échelle (scripts/scale.sh), attente que
# les N serveurs soient dans la rotation de HAProxy, répartition de 20 appels à
# /info (V1 pour ce N), un tir de chauffe non compté, puis ESSAIS tirs
#   ab -n 2000 -c 50 http://localhost:8080/resultat?matricule=BF000042
# On garde la médiane : une mesure isolée peut être un accident.
#
# À lancer depuis le POSTE HÔTE, à la racine du dépôt (jamais dans une VM :
# ab y consommerait le processeur partagé et fausserait la mesure).
#
# Usage : bash scripts/mesure_v3.sh          (campagne du sujet : N=2 puis N=4)
#         bash scripts/mesure_v3.sh 2 4 6    (autres configurations, croissantes)
# Réglages : ESSAIS=3 REQUETES=2000 CONCURRENCE=50 URL=... (variables d'environnement)
#
# Prérequis : socle démarré avec NB_APP égal à la première configuration
# (vagrant up), extensions éteintes (lb2 et obs prendraient du processeur),
# ab installé sur l'hôte. La plateforme reste à la dernière configuration.
#
# Résultat : docs/mesures/v3-charge.txt (sorties brutes de ab + tableau final)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

URL="${URL:-http://localhost:8080/resultat?matricule=BF000042}"
ESSAIS="${ESSAIS:-3}"
REQUETES="${REQUETES:-2000}"
CONCURRENCE="${CONCURRENCE:-50}"
SORTIE="docs/mesures/v3-charge.txt"
CONFIGS=("$@")
[ "${#CONFIGS[@]}" -gt 0 ] || CONFIGS=(2 4)

# --- Contrôles avant de commencer -------------------------------------------
command -v ab >/dev/null 2>&1 || {
  echo "ERREUR : ab (Apache Bench) introuvable sur ce poste."
  echo "  Linux/WSL : sudo apt install apache2-utils"
  echo "  Windows   : binaires Apache Lounge, dossier bin/ dans le PATH de Git Bash"
  exit 1
}
precedent=0
for n in "${CONFIGS[@]}"; do
  case "$n" in ''|*[!0-9]*) echo "ERREUR : '$n' n'est pas un nombre de serveurs"; exit 1;; esac
  if [ "$n" -lt 2 ] || [ "$n" -le "$precedent" ]; then
    # Ordre décroissant interdit : scale.sh ne détruit pas les serveurs en trop,
    # ils resteraient allumés et prendraient du processeur pendant la mesure.
    echo "ERREUR : configurations croissantes et >= 2 attendues (ex. : 2 4)"; exit 1
  fi
  precedent=$n
done
if [ "${LB2:-0}" = 1 ] || [ "${OBS:-0}" = 1 ]; then
  echo "ATTENTION : LB2/OBS positionnées dans ce terminal. Pour une mesure juste,"
  echo "            éteindre les extensions (vagrant halt lb2 obs) et faire unset LB2 OBS."
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL")
[ "$code" = 200 ] || { echo "ERREUR : $URL répond HTTP $code (plateforme démarrée ?)"; exit 1; }

# Les binaires Windows (ab.exe, vagrant.exe) écrivent des fins de ligne CRLF
sans_cr() { tr -d '\r'; }

# Champ d'une sortie de ab
champ() {  # $1 = fichier, $2 = début de ligne, $3 = numéro de champ
  sans_cr < "$1" | awk -v debut="$2" -v n="$3" 'index($0, debut) == 1 { print $n; exit }'
}

mediane() {  # nombres sur l'entrée standard
  sort -n | awk '{ v[NR] = $1 } END {
    if (NR == 0) { print "-"; exit }
    if (NR % 2) print v[(NR + 1) / 2]; else printf "%.2f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

# Les N serveurs doivent tous répondre à /info : HAProxy les a réintégrés
attendre_rotation() {  # $1 = N
  local hotes
  for _ in $(seq 1 30); do
    hotes=$(for _ in $(seq 1 $(( 4 * $1 ))); do
              curl -s --max-time 2 "${URL%%/resultat*}/info"; echo
            done | sans_cr | grep -o '"host": *"[^"]*"' | sort -u | wc -l)
    [ "$hotes" -eq "$1" ] && return 0
    sleep 2
  done
  return 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RESUME="$TMP/resume"
: > "$RESUME"

{
echo "=== V3 montée en charge - $(date) ==="
echo "Commande : ab -n $REQUETES -c $CONCURRENCE \"$URL\" ; $ESSAIS essais par configuration, médiane retenue"
echo "Configurations : N = ${CONFIGS[*]}"
echo "Version du dépôt testée : $(git rev-parse --short HEAD 2>/dev/null || echo ?) (branche $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ?))"
echo "Poste hôte : $(uname -srm) ; processeurs : $(nproc 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-?}")"
echo "Outils : $(ab -V 2>&1 | sans_cr | head -1) ; $(vagrant --version 2>&1 | sans_cr)"
echo "Chaque VM a 1 processeur virtuel ; toutes partagent le processeur de ce poste."
} | tee "$SORTIE"

for n in "${CONFIGS[@]}"; do
  echo ""
  echo ">>> Mise à l'échelle : NB_APP=$n (scripts/scale.sh, quelques minutes si des VM sont à créer)"
  export NB_APP="$n"
  if ! bash scripts/scale.sh "$n"; then
    echo "ERREUR : scale.sh a échoué pour N=$n" | tee -a "$SORTIE"; exit 1
  fi
  if ! attendre_rotation "$n"; then
    echo "ERREUR : les $n serveurs ne sont pas tous dans la rotation de HAProxy" | tee -a "$SORTIE"; exit 1
  fi

  {
  echo ""
  echo "================ N = $n serveurs applicatifs ================"
  echo "--- Répartition de 20 appels à /info ---"
  for _ in $(seq 1 20); do curl -s --max-time 2 "${URL%%/resultat*}/info"; echo; done \
    | sans_cr | grep -o '"host": *"[^"]*"' | sort | uniq -c
  } 2>&1 | tee -a "$SORTIE"

  # Chauffe non comptée (premiers accès : caches de PostgreSQL et de l'OS)
  ab -q -n 200 -c 10 "$URL" > /dev/null 2>&1
  sleep 3

  for e in $(seq 1 "$ESSAIS"); do
    ab -n "$REQUETES" -c "$CONCURRENCE" "$URL" > "$TMP/ab" 2>&1
    rps=$(champ "$TMP/ab" "Requests per second:" 4)
    echecs=$(champ "$TMP/ab" "Failed requests:" 3)
    non2xx=$(champ "$TMP/ab" "Non-2xx responses:" 3)
    p95=$(sans_cr < "$TMP/ab" | awk '$1 == "95%" { print $2; exit }')
    {
    echo ""
    echo "--- N=$n, essai $e/$ESSAIS : sortie brute de ab ---"
    sans_cr < "$TMP/ab"
    } >> "$SORTIE"
    echo "N=$n essai $e : ${rps:-?} req/s, échecs ${echecs:-?}, non-2xx ${non2xx:-0}, 95 % sous ${p95:-?} ms" \
      | tee -a "$SORTIE"
    echo "$n $e ${rps:-0} ${echecs:-0} ${non2xx:-0} ${p95:-0}" >> "$RESUME"
    sleep 5
  done
done

{
echo ""
echo "================ Synthèse V3 ================"
printf "%-4s | %-26s | %-14s | %-13s | %s\n" "N" "req/s par essai" "médiane req/s" "échecs+non2xx" "95 % sous (ms, médiane)"
for n in "${CONFIGS[@]}"; do
  essais=$(awk -v n="$n" '$1 == n { printf "%s ", $3 }' "$RESUME")
  med=$(awk -v n="$n" '$1 == n { print $3 }' "$RESUME" | mediane)
  err=$(awk -v n="$n" '$1 == n { s += $4 + $5 } END { print s + 0 }' "$RESUME")
  p95=$(awk -v n="$n" '$1 == n { print $6 }' "$RESUME" | mediane)
  printf "%-4s | %-26s | %-14s | %-13s | %s\n" "$n" "$essais" "$med" "$err" "$p95"
  echo "$n $med" >> "$TMP/medianes"
done
premier=$(head -1 "$TMP/medianes")
dernier=$(tail -1 "$TMP/medianes")
awk -v a="$premier" -v b="$dernier" 'BEGIN {
  split(a, x, " "); split(b, y, " ")
  if (x[1] != y[1] && x[2] > 0)
    printf "\nRapport des médianes N=%s / N=%s : x%.2f\n", y[1], x[1], y[2] / x[2] }'
echo ""
echo "À commenter dans le dossier : un rapport proche de x1 (ou inférieur) n'est pas"
echo "un échec, toutes les VM partagent le même processeur physique (voir le sujet)."
echo "NB_APP=$NB_APP : la plateforme reste dans cette configuration."
} | tee -a "$SORTIE"

echo ""
echo "Résultat complet : $SORTIE"
