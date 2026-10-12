#!/usr/bin/env bash
# Bascule : promeut bdd2 en primaire quand bdd1 est en panne (R6, scénario V4).
# À lancer depuis l'hôte, à la racine du dépôt : ./scripts/bascule.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f config/noeuds.yml ] || { echo "config/noeuds.yml absent : lancez d'abord une commande vagrant"; exit 1; }
IP_BDD1=$(awk '/nom: bdd1/{f=1} f&&/ip:/{print $2; exit}' config/noeuds.yml)

ssh_bdd2() { vagrant ssh bdd2 -c "$1" < /dev/null; }

debut=$(date +%s.%N)

echo "[1/5] bdd2 est-elle demarree ?"
vagrant status bdd2 | grep -q "^bdd2 .*running" || { echo "ECHEC : bdd2 n'est pas demarree"; exit 1; }

echo "[2/5] bdd1 doit etre injoignable (sinon : risque de split-brain)"
if ssh_bdd2 "pg_isready -q -h ${IP_BDD1} -p 5432 -t 3"; then
  echo "REFUS : bdd1 repond encore. Promouvoir bdd2 creerait deux primaires."
  exit 1
fi

echo "[3/5] bdd2 est-elle bien une replique ?"
etat=$(ssh_bdd2 "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'" | tr -d '[:space:]')
[ "$etat" = "t" ] || { echo "ECHEC : bdd2 n'est pas une replique (deja promue ?)"; exit 1; }

echo "[4/5] Promotion de bdd2"
ssh_bdd2 "sudo -u postgres psql -tAc 'SELECT pg_promote(true, 60)'" > /dev/null
etat=$(ssh_bdd2 "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'" | tr -d '[:space:]')
[ "$etat" = "f" ] || { echo "ECHEC : bdd2 est toujours en lecture seule"; exit 1; }

echo "[5/5] Reconfiguration des applications (ordre DB_HOST -> nouvelle primaire bdd2)"
# Choix C : on réécrit DB_HOST sur chaque app pour mettre la nouvelle primaire
# (bdd2) en premier, puis on redémarre le service. Sans état, le redémarrage
# est indolore ; HAProxy reprend la main via la sonde /sante.
IP_BDD2=$(awk '/nom: bdd2/{f=1} f&&/ip:/{print $2; exit}' config/noeuds.yml)
# Liste des applications depuis noeuds.yml (source unique de vérité).
# Tolère les clés quotées ou non (format change selon la version de Psych).
APPS=$(awk '/- "?nom"?: app/{print $NF}' config/noeuds.yml | tr -d '"')
[ -n "${APPS}" ] || { echo "ECHEC : aucun serveur applicatif trouve dans noeuds.yml"; exit 1; }
echo "    Applications detectees : $(echo $APPS | tr '\n' ' ')"

# On lit la liste des applications depuis noeuds.yml (source unique de vérité)
for app in $APPS; do
  echo "    -> $app : mise a jour de l'ordre DB_HOST"
  # Via sed sur /etc/default/resultats, puis redémarrage ciblé du service
  vagrant ssh "$app" -c "sudo sed -i 's/^DB_HOST=.*/DB_HOST=${IP_BDD2},${IP_BDD1}/' /etc/default/resultats && sudo systemctl restart resultats" < /dev/null \
    || echo "    AVERTISSEMENT : $app non reconfigure (VM injoignable ?)"
  # Vérification que le service répond après redémarrage
  sleep 1
  vagrant ssh "$app" -c "curl -fsS --max-time 3 http://127.0.0.1:3000/info" < /dev/null \
    || echo "    AVERTISSEMENT : $app n'a pas repondu apres redemarrage"
done

fin=$(date +%s.%N)
echo "OK : bdd2 est maintenant la base primaire, applications reconfigurees."
awk -v d="$debut" -v f="$fin" 'BEGIN{printf "Duree totale de la bascule : %.1f s\n", f-d}'
