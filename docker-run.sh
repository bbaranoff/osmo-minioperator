#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# docker-run.sh - lance le conteneur avec l'audio de l'hote : le socket PulseAudio
# est monte en /run/pulse/native (sans lui l'appel est muet). Arguments passes
# tels quels au conteneur (defaut : bash). PULSE_SOCK=<chemin> force le socket.
set -eu
IMG="${IMG:-osmo-minioperator}"
# Pas de --privileged : NET_ADMIN + /dev/net/tun pour osmo-ggsn (TUN),
# SYS_NICE pour la priorite temps reel du DSP (run.sh, RT_NICE).
# --init : un vrai PID 1 ramasse les process termines de la pile.
args=(--rm -it --init --cap-add NET_ADMIN --cap-add SYS_NICE --device /dev/net/tun)

# Ordre : PULSE_SOCK (force), PulseAudio systeme, puis socket de session
# (PipeWire / pipewire-pulse des laptops : /run/user/<uid>/pulse/native).
uid="${SUDO_UID:-$(id -u)}"
for s in ${PULSE_SOCK:-} /run/pulse/native /var/run/pulse/native "/run/user/$uid/pulse/native"; do
    if [ -S "$s" ]; then
        args+=(-v "$(readlink -f "$s"):/run/pulse/native")
        echo "docker-run.sh : audio de l'hote via $s" >&2
        break
    fi
done
case " ${args[*]} " in
    *pulse/native*) ;;
    *) echo "docker-run.sh : aucun socket PulseAudio sur l'hote, l'appel sera muet" >&2 ;;
esac

# PulseAudio de session (non systeme) : il faut aussi le cookie de l'utilisateur.
home="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
[ -r "$home/.config/pulse/cookie" ] && args+=(-v "$home/.config/pulse/cookie:/root/.config/pulse/cookie:ro")
[ -d /dev/snd ] && args+=(--device /dev/snd)

# TTYD=1 : les consoles aussi dans le navigateur (ttyd, sans authentification : port
# publie sur 127.0.0.1 seulement). TTYD_PORT (7681) change le port, des deux cotes.
if [ "${TTYD:-0}" = 1 ]; then
    p="${TTYD_PORT:-7681}"
    args+=(-e TTYD=1 -e "TTYD_PORT=$p" -p "127.0.0.1:$p:$p")
    echo "docker-run.sh : consoles aussi sur http://127.0.0.1:$p/" >&2
fi

exec docker run "${args[@]}" "$IMG" "$@"
