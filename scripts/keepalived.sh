#!/usr/bin/env bash
set -euo pipefail
source /vagrant/scripts/lib.sh
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq keepalived

IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP/" 'index($4, ip)==1 {print $2}')
if [ "$(hostname)" = "lb1" ]; then STATE=MASTER; PRIO=150; else STATE=BACKUP; PRIO=100; fi

cat > /tmp/keepalived.conf <<CONF
vrrp_script chk_haproxy {
    script "/usr/bin/pgrep haproxy"
    interval 1
    fall 2
    rise 2
}
vrrp_instance VI_1 {
    state $STATE
    interface $IFACE
    virtual_router_id $((50 + GROUPE))
    priority $PRIO
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass $VRRP_PASS
    }
    virtual_ipaddress {
        $VIP/24
    }
    track_script {
        chk_haproxy
    }
}
CONF

if install_si_different /tmp/keepalived.conf /etc/keepalived/keepalived.conf 600; then
  systemctl restart keepalived
fi
systemctl enable keepalived >/dev/null 2>&1
systemctl is-active --quiet keepalived
echo "keepalived actif ($STATE, priorite $PRIO, VIP $VIP)"
