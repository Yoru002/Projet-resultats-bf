#!/usr/bin/env bash
set -euo pipefail
source /vagrant/scripts/lib.sh
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq haproxy

python3 /vagrant/scripts/gen_haproxy.py > /tmp/haproxy.cfg
haproxy -c -q -f /tmp/haproxy.cfg
if install_si_different /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg; then
  systemctl reload haproxy || systemctl restart haproxy
fi
systemctl enable haproxy >/dev/null 2>&1
systemctl is-active --quiet haproxy

if [ "${LB2:-0}" = "1" ]; then
  bash /vagrant/scripts/keepalived.sh
fi
echo "lb provisionne, HAProxy actif"
