#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

cat > /etc/apt/apt.conf.d/99-projet <<'CONF'
Acquire::Retries "5";
Acquire::http::Pipeline-Depth "0";
Acquire::http::No-Cache "true";
Acquire::By-Hash "no";
CONF

for essai in 1 2 3 4 5; do
  if apt-get update -qq; then break; fi
  echo "apt-get update a échoué (essai $essai/5), nettoyage et nouvel essai..."
  rm -rf /var/lib/apt/lists/*
  sleep 10
  if [ "$essai" = 5 ]; then exit 1; fi
done

apt-get install -y -qq python3-yaml
