#!/usr/bin/env bash
# Change le nombre de serveurs applicatifs.
# Usage : ./scale.sh 4      (garder LB2=1 / OBS=1 si les extensions sont actives)
set -euo pipefail
cd "$(dirname "$0")"
export NB_APP="${1:?nombre de serveurs applicatifs}"

vagrant up
vagrant provision lb1
if [ "${LB2:-0}" = "1" ]; then vagrant provision lb2; fi
if [ "${OBS:-0}" = "1" ]; then vagrant provision obs; fi
echo "NB_APP=$NB_APP : plateforme mise a jour"
