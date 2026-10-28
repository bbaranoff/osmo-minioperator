#!/usr/bin/env bash
# start.sh - entrypoint conteneur : prepare l'environnement puis exec la commande
# (bash par defaut). NE lance PAS le run DSP tout seul : lancer ./run-dsp.sh a la
# main dans le conteneur.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -d /etc/osmocom /var/log/osmocom /var/lib/osmocom /root/.osmocom/bb /run/osmo-minioperator/logs
cp -n "$HERE/configs/"*.cfg /etc/osmocom/ 2>/dev/null || true
cp -n "$HERE/configs/mobile.cfg" /root/.osmocom/bb/mobile.cfg 2>/dev/null || true

exec "$@"
