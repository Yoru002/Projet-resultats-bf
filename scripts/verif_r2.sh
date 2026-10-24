#!/usr/bin/env bash
# Vérification R2 : « vagrant provision rejoué deux fois de suite ne modifie
# rien et n'échoue pas ».
#
# Relève sur chaque VM démarrée l'empreinte (md5) des fichiers que les scripts
# de provisionnement écrivent, le PID des services et le nombre de lignes de la
# table resultats ; lance deux fois `vagrant provision` ; compare.
#   - R2 tenue si les deux rejeux réussissent et ne changent aucun fichier ni
#     aucune donnée (comparaison après rejeu 1 / après rejeu 2) ;
#   - les services redémarrés pendant le rejeu 2 sont signalés à part.
#
# Usage : bash scripts/verif_r2.sh      (depuis le poste hôte, racine du dépôt,
#         plateforme démarrée, mêmes NB_APP/LB2/OBS que lors de la construction)
# Durée : deux provisionnements complets, soit plusieurs minutes.
# Résultat : docs/mesures/r2-idempotence.txt ; journaux des rejeux dans
#            docs/mesures/r2-rejeu-1.log et r2-rejeu-2.log (non versionnés).
#
# Mode interne, exécuté DANS une VM par ce même script :
#   sudo bash /vagrant/scripts/verif_r2.sh --empreinte <role>
set -uo pipefail

empreinte() {  # $1 = rôle de la machine (colonne role de noeuds.yml)
  local v fichiers=(/etc/apt/apt.conf.d/99-projet) services=() f s
  v=$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -1)
  case "$1" in
    bdd)      fichiers+=("/etc/postgresql/$v/main/conf.d/resultats.conf" "/etc/postgresql/$v/main/pg_hba.conf")
              services=("postgresql@$v-main") ;;
    replique) fichiers+=("/etc/postgresql/$v/main/conf.d/resultats.conf" "/etc/postgresql/$v/main/pg_hba.conf"
                         /var/lib/postgresql/.pgpass "/var/lib/postgresql/$v/main/postgresql.auto.conf")
              services=("postgresql@$v-main") ;;
    app)      fichiers+=(/etc/default/resultats /etc/systemd/system/resultats.service /opt/resultats/serveur.py)
              services=(resultats) ;;
    lb)       fichiers+=(/etc/haproxy/haproxy.cfg /etc/keepalived/keepalived.conf)
              services=(haproxy keepalived) ;;
    obs)      fichiers+=(/etc/prometheus/prometheus.yml /etc/apt/sources.list.d/grafana.list
                         /etc/grafana/provisioning/datasources/projet.yml
                         /etc/grafana/provisioning/dashboards/projet.yml
                         /var/lib/grafana/dashboards/resultats-bf.json
                         /etc/systemd/system/grafana-server.service.d/projet.conf)
              services=(prometheus grafana-server) ;;
  esac
  for f in "${fichiers[@]}"; do
    if [ -f "$f" ]; then echo "fichier $f $(md5sum < "$f" | cut -d' ' -f1)"
    else echo "fichier $f ABSENT"; fi
  done
  for s in "${services[@]}"; do
    echo "service $s $(systemctl show -p MainPID --value "$s" 2>/dev/null)"
  done
  if [ "$1" = bdd ]; then
    echo "donnees resultats $(sudo -u postgres psql -d resultats -tAc 'SELECT count(*) FROM resultats' 2>&1)"
  fi
}

if [ "${1:-}" = "--empreinte" ]; then empreinte "${2:?rôle manquant}"; exit 0; fi

# ============================ Poste hôte ====================================
cd "$(dirname "$0")/.." || exit 1
SORTIE="docs/mesures/r2-idempotence.txt"
mkdir -p docs/mesures
sans_cr() { tr -d '\r'; }

[ -f config/noeuds.yml ] || { echo "config/noeuds.yml absent : lancez d'abord une commande vagrant"; exit 1; }
# "nom role" pour chaque machine de la table (clés quotées ou non)
MACHINES=$(sans_cr < config/noeuds.yml | tr -d '"' | awk '/nom:/ { n = $NF } /role:/ { print n, $NF }')
EN_MARCHE=$(vagrant status --machine-readable 2>/dev/null | sans_cr \
            | awk -F, '$3 == "state" && $4 == "running" { print $2 }')
CIBLES=$(echo "$MACHINES" | while read -r nom role; do
           echo "$EN_MARCHE" | grep -qx "$nom" && echo "$nom $role"
         done)
[ -n "$CIBLES" ] || { echo "Aucune VM démarrée : vagrant up d'abord"; exit 1; }

dans() { vagrant ssh "$1" -c "$2" < /dev/null 2>/dev/null | sans_cr; }

# --- Garde-fous : ne pas abîmer la plateforme en la vérifiant ---------------
# 1. Mauvais NB_APP dans ce terminal : provisionner lb1 retirerait des serveurs
if echo "$EN_MARCHE" | grep -qx lb1; then
  attendus=$(echo "$MACHINES" | awk '$2 == "app"' | wc -l | tr -d ' ')
  presents=$(dans lb1 "grep -c ' server app' /etc/haproxy/haproxy.cfg" | tr -d ' ')
  if [ "$attendus" != "$presents" ]; then
    echo "ARRÊT : HAProxy connaît $presents serveurs applicatifs, ce terminal en déclare $attendus."
    echo "        Exportez la valeur utilisée à la construction (export NB_APP=$presents) puis relancez."
    exit 1
  fi
fi
# 2. Plateforme en état de bascule (V4) : bdd1 arrêtée ou bdd2 promue
if echo "$EN_MARCHE" | grep -qx bdd2; then
  etat=$(dans bdd2 "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'" | tr -d '[:space:]')
  if [ "$etat" != "t" ] || ! echo "$EN_MARCHE" | grep -qx bdd1; then
    echo "ARRÊT : bdd2 n'est pas une réplique de bdd1 en marche (bascule V4 effectuée ?)."
    echo "        Reconstruire la paire d'abord (README, §6.2), puis relancer."
    exit 1
  fi
fi

instantane() {  # $1 = fichier de sortie
  : > "$1"
  echo "$CIBLES" | while read -r nom role; do
    dans "$nom" "sudo bash /vagrant/scripts/verif_r2.sh --empreinte $role" | sed "s|^|$nom |" >> "$1"
  done
}

rejeu() {  # $1 = numéro
  echo ">>> vagrant provision n°$1 (journal : docs/mesures/r2-rejeu-$1.log)"
  vagrant provision --no-color > "docs/mesures/r2-rejeu-$1.log" 2>&1
  echo $? > "$TMP/code$1"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
debut=$(date +%s)

echo ">>> Empreintes avant rejeu ($(echo "$CIBLES" | wc -l | tr -d ' ') VM)"
instantane "$TMP/avant"
grep -q '^[^ ]* fichier ' "$TMP/avant" || {
  echo "ERREUR : aucune empreinte relevée. /vagrant est-il monté dans les VM ?"; exit 1; }
rejeu 1
echo ">>> Empreintes après rejeu 1"
instantane "$TMP/apres1"
rejeu 2
echo ">>> Empreintes après rejeu 2"
instantane "$TMP/apres2"

c1=$(cat "$TMP/code1"); c2=$(cat "$TMP/code2")
# Lignes qui diffèrent entre deux instantanés, pour un type donné (fichier, service, donnees)
ecarts() { diff <(grep " $3 " "$1") <(grep " $3 " "$2") | grep '^>' | cut -c3-; }

{
echo "=== R2 idempotence - $(date) ==="
echo "Commande : vagrant provision, deux fois de suite (toutes les VM démarrées)"
echo "Version du dépôt testée : $(git rev-parse --short HEAD 2>/dev/null || echo ?) (branche $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ?))"
echo "VM vérifiées : $(echo "$CIBLES" | awk '{ printf "%s ", $1 }')"
echo "NB_APP=${NB_APP:-2} LB2=${LB2:-0} OBS=${OBS:-0} ; durée totale : $(( $(date +%s) - debut )) s"
echo "Code de sortie : rejeu 1 = $c1, rejeu 2 = $c2"
echo ""
echo "--- Empreintes après le rejeu 2 (fichiers écrits par le provisionnement) ---"
grep -E ' (fichier|donnees) ' "$TMP/apres2"
echo ""
echo "--- Comparaison rejeu 1 -> rejeu 2 ---"
f2=$(ecarts "$TMP/apres1" "$TMP/apres2" fichier); d2=$(ecarts "$TMP/apres1" "$TMP/apres2" donnees)
s2=$(ecarts "$TMP/apres1" "$TMP/apres2" service)
echo "Fichiers modifiés : $( [ -n "$f2" ] && echo "$f2" | awk '{ printf "%s:%s ", $1, $3 }' || echo aucun)"
echo "Données modifiées : $( [ -n "$d2" ] && echo "$d2" || echo aucune)"
echo "Services redémarrés (PID changé) : $( [ -n "$s2" ] && echo "$s2" | awk '{ printf "%s:%s ", $1, $3 }' || echo aucun)"
echo ""
echo "--- Pour information : état initial -> rejeu 1 ---"
f1=$(ecarts "$TMP/avant" "$TMP/apres1" fichier)
if [ -n "$f1" ]; then
  echo "Fichiers mis à jour par le rejeu 1 (VM construites avec une version plus ancienne du dépôt) :"
  echo "$f1" | awk '{ printf "  %s %s\n", $1, $3 }'
else
  echo "Aucun fichier modifié par le rejeu 1."
fi
echo ""
if [ "$c1" = 0 ] && [ "$c2" = 0 ] && [ -z "$f2" ] && [ -z "$d2" ]; then
  echo "RESULTAT R2 : CONFORME (deux rejeux sans échec, aucun fichier ni donnée modifié)"
  [ -n "$s2" ] && echo "  Remarque : services redémarrés sans changement de configuration (voir ci-dessus)."
else
  echo "RESULTAT R2 : NON CONFORME (voir les écarts ci-dessus et les journaux r2-rejeu-*.log)"
fi
} 2>&1 | tee "$SORTIE"
