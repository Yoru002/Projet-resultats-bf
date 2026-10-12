#!/usr/bin/env bash
set -euo pipefail
source /vagrant/scripts/lib.sh
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq haproxy keepalived

python3 /vagrant/scripts/gen_haproxy.py > /tmp/haproxy.cfg
haproxy -c -q -f /tmp/haproxy.cfg
if install_si_different /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg; then
  systemctl reload haproxy || systemctl restart haproxy
fi
systemctl enable haproxy >/dev/null 2>&1
systemctl is-active --quiet haproxy

# keepalived toujours configuré : lb1 est maître de la VIP, E1 n'ajoute que lb2
bash /vagrant/scripts/keepalived.sh
echo "lb provisionne, HAProxy actif"
