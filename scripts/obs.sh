#!/usr/bin/env bash
set -euo pipefail
source /vagrant/scripts/lib.sh
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq prometheus gnupg curl

# --- Prometheus : cibles generees depuis noeuds.yml ---
python3 /vagrant/scripts/gen_prometheus.py > /tmp/prometheus.yml
if install_si_different /tmp/prometheus.yml /etc/prometheus/prometheus.yml; then
  systemctl restart prometheus
fi
systemctl enable prometheus >/dev/null 2>&1

# --- Grafana : depot officiel ---
if [ ! -f /etc/apt/keyrings/grafana.gpg ]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /tmp/grafana.list
if install_si_different /tmp/grafana.list /etc/apt/sources.list.d/grafana.list; then
  apt-get update -qq
fi
apt-get install -y -qq grafana

# --- Grafana : configuration par fichiers du depot ---
install -d /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
CHANGED=0
install_si_different /vagrant/config/grafana/datasource.yml /etc/grafana/provisioning/datasources/projet.yml && CHANGED=1
install_si_different /vagrant/config/grafana/dashboards.yml /etc/grafana/provisioning/dashboards/projet.yml && CHANGED=1
install_si_different /vagrant/config/grafana/dashboard.json /var/lib/grafana/dashboards/resultats-bf.json && CHANGED=1

cat > /tmp/grafana-env.conf <<CONF
[Service]
Environment=GF_AUTH_ANONYMOUS_ENABLED=true
Environment=GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
Environment=GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
CONF
install -d /etc/systemd/system/grafana-server.service.d
if install_si_different /tmp/grafana-env.conf /etc/systemd/system/grafana-server.service.d/projet.conf 600; then
  systemctl daemon-reload; CHANGED=1
fi

systemctl enable grafana-server >/dev/null 2>&1
if [ "$CHANGED" = 1 ] || ! systemctl is-active --quiet grafana-server; then
  systemctl restart grafana-server
fi

# --- Controles ---
for i in $(seq 1 30); do
  curl -fs http://localhost:9090/-/ready >/dev/null && curl -fs http://localhost:3000/api/health >/dev/null && break
  sleep 2
done
curl -fs http://localhost:9090/-/ready >/dev/null
curl -fs http://localhost:3000/api/health >/dev/null
echo "obs provisionne : Prometheus :9090, Grafana :3000"
