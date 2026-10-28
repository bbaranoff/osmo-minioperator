#!/usr/bin/env bash
# start.sh - entrypoint du conteneur osmo-minioperator.
# ─────────────────────────────────────────────────────────────────────────────
# Dossier par defaut du conteneur (/opt/GSM/osmo-minioperator). Prepare
# /etc/osmocom a partir des configs figees, puis lance l'operateur en mode DSP
# (chaque composant Osmocom demarre comme une APPLICATION, pas un service), et
# garde le conteneur vivant en suivant les logs.
#
#   docker run --rm -it --privileged osmo-minioperator
#   docker run --rm -it osmo-minioperator --stop     # passe l'arg a run-dsp.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/run/osmo-minioperator/logs}"

# Configs figees -> /etc/osmocom (le Dockerfile l'a deja fait au build ; on le
# rejoue au cas ou /etc/osmocom serait monte vide par l'hote).
install -d /etc/osmocom "$LOG_DIR"
cp -n "$HERE/configs/"*.cfg /etc/osmocom/ 2>/dev/null || true

# Un argument (--stop, --logs, --step...) est passe tel quel a run-dsp.sh.
if [ "$#" -gt 0 ]; then
    exec "$HERE/run-dsp.sh" "$@"
fi

# Lancement complet, puis on garde le PID 1 vivant sur les logs.
"$HERE/run-dsp.sh" &
RUN_PID=$!

term() { "$HERE/run-dsp.sh" --stop; kill "$RUN_PID" 2>/dev/null; exit 0; }
trap term TERM INT

# Attendre que les logs existent, puis les suivre (garde le conteneur en vie).
for _ in $(seq 1 30); do
    compgen -G "$LOG_DIR/*.log" >/dev/null && break
    sleep 1
done
exec tail -n +1 -F "$LOG_DIR"/*.log
