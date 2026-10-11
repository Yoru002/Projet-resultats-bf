#!/usr/bin/env bash
# -*- mode: bash -*-
# scripts/keepalived.sh — Redondance du répartiteur (extension E1).
#
# Rôle : maintenir une adresse IP virtuelle (VIP) en VRRP entre lb1 et lb2, et
# faire en sorte que le service reste joinable à la même adresse après le
# crash de lb1 (V6, scénario E1) : < 5 s de disruption en principe.
#
# Constraintes du projet :
#   - Pas de geste manuel : tout est décrit en code (Vagrantfile + scripts).
#   - Le traffic interne ne traverse que le réseau privé.
#   - Si l'adresse VIP n'est pas joignable depuis l'hôte, on peut activer
#     NIC promiscuity (voir comment dans le Vagrantfile) :
#       vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]
#
# Nom de la VIP : ${VIP} (injecté par le Vagrantfile, ex. 192.168.59.5).
# Mot de passe VRRP (auth) : ${VRRP_PASS} (à renseigner dans .env).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# VRRP ne peut fonctionner sans les bonnes variables.
: "${VIP:?VIP manquant (voir .env et Vagrantfile)}"
: "${VRRP_PASS:?VRRP_PASS manquant (voir .env et Vagrantfile)}"

# --- Installation de keepalived ---------------------------------------------
apt-get update -qq
apt-get install -y -qq keepalived

# --- Configuration VRRP ------------------------------------------------------
# Le fichier est remplacé à chaque provision (idempotent). keepalived choisit
# son rôle (MASTER / BACKUP) selon le précédent et le vote, donc aucune
# configuration manuelle nécessaire en cas de panne de lb1.
cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_script haproxy_check {
    script "exit $(curl -fsS --max-time 2 http://127.0.0.1:8080/sante >/dev/null 2>&1 && echo 0 || echo 1)"
    interval 2
    timeout 3
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth1
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${VRRP_PASS}
    }
    virtual_ipaddress {
        ${VIP}/32
    }
    track_script {
        haproxy_check
    }
}
EOF

# --- Démarrage ---------------------------------------------------------------
# Le second répartiteur (lb2) reprend la VIP si lb1 tombe. keepalived s'adapte
# seul à l'état de la machine, donc aucune commande manuelle après le
# provisionnement.

if command -v systemctl > /dev/null 2>&1; then
  systemctl enable keepalived
  systemctl restart keepalived
else
  keepalived -n
fi

echo " keepalived démarré : VIP ${VIP} en VRRP sur eth1"
