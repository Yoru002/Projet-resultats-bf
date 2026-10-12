#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq prometheus-node-exporter
systemctl enable --now prometheus-node-exporter >/dev/null 2>&1
systemctl is-active --quiet prometheus-node-exporter
echo "node_exporter actif sur :9100"
