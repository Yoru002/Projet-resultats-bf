#!/usr/bin/env bash
# -*- mode: bash -*-
# scripts/lb.sh — Répartiteur HAProxy (extension E1).
#
# Rôle : faire commuter le traffic HTTP uniquement vers les serveurs
# applicatifs qui répondent 200 sur /sante, et les écartier en moins de
# 5 secondes quand un serveur tombe (R4). La configuration est engendrée à
# partir de la source unique de vérité config/noeuds.yml, jamais en dur (R3).
#
# Variables attendues dans l'environnement (injectées par le Vagrantfile) :
#   RESEAU      sous-réseau du groupe (192.168.59 pour GROUPE=4)
#   NB_APP      nombre de serveurs applicatifs
#   PRIMARY_IP  ip de la base primaire
#   REPLICA_IP  ip de la base réplique
#   VIP         adresse IP virtuelle VRRP (extension E1)
#   LB2         "1" pour inclure le second répartiteur, "0" sinon
#
# C'est lb2 (la machine lb2) qui exécute ce script à chaque démarrage avec
# run: "always", pour régénérer HAProxy indépendamment du statut de la VIP
# (keepalived.sh s'occupe de la VIP).

set -euo pipefail

# --- Lecture de la source unique de vérité ----------------------------------
[ -f /vagrant/config/noeuds.yml ] || {
  echo "ECHEC : /vagrant/config/noeuds.yml absent" >&2
  exit 1
}
mapfile -t NOEUDS_YML < <(cat /vagrant/config/noeuds.yml)

# Construire la liste des serveurs applicatifs depuis le YAML, comme le fait
# le Vagrantfile (interdit d'écrire les IPs en dur dans la config du LB).
APP_IPS=()
for i in $(seq 1 "${NB_APP:-2}"); do
  APP_IPS+=("app${i}")
done

# Déterminer l'adresse de la base pour la sonde.
PRIMARY_HOST=""
REPLICA_HOST=""
for node in "${NOEUDS_YML[@]}"; do
  case "${node}" in
    *"bdd1"*)
      PRIMARY_HOST=$(echo "${node}" | awk '{print $2}')
      ;;
    *"bdd2"*)
      REPLICA_HOST=$(echo "${node}" | awk '{print $2}')
      ;;
  esac
done
[ -n "${PRIMARY_HOST}" ] || PRIMARY_HOST="${PRIMARY_IP}"
[ -n "${REPLICA_HOST}" ] || REPLICA_HOST="${REPLICA_IP}"

# --- Génération de la configuration HAProxy ---------------------------------
# En mode E1 (LB2 actif), on écoute aussi sur la VIP. Dans le socle, c'est
# lb1 qui sert de frontend ; lb2 se synchronise sa propre configuration.
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    daemon
    maxconn 4096

defaults
    mode http
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    option httplog
    log /dev/log local0

frontend http-in
    bind *:80
    acl sante path /sante
    use_backend sondes if sante
    default_backend resultats

backend resultats
    balance roundrobin
    # Les serveurs applicatifs sont engendrés depuis noeuds.yml (R3).
    $(for i in "${!APP_IPS[@]}"; do
         echo "    server ${APP_IPS[$i]} ${RESEAU}.${20 + i}:8000 check inter 2s fall 3 rise 2"
       done)
EOF

# --- Démarrage ---------------------------------------------------------------
if command -v haproxy-systemd-wrapper > /dev/null 2>&1; then
  service haproxy start
elif command -v systemctl > /dev/null 2>&1; then
  systemctl restart haproxy
else
  haproxy -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid -D
fi

# Vérification : le LB doit répondre.
for i in $(seq 1 10); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/info > /dev/null 2>&1; then
    echo " lb1 provisionné, répartiteur HAProxy écoute sur 0.0.0.0:80"
    exit 0
  fi
  sleep 1
done

echo "ECHEC : le répartiteur ne répond pas sur 0.0.0.0:8080" >&2
exit 1
