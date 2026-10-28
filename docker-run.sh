#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# docker-run.sh - lance le conteneur avec l'audio de l'hote : le socket PulseAudio
# est monte en /run/pulse/native (sans lui l'appel est muet). Arguments passes
# tels quels au conteneur (defaut : bash).
set -eu
IMG="${IMG:-osmo-minioperator}"
# Pas de --privileged : NET_ADMIN + /dev/net/tun pour osmo-ggsn (TUN),
# SYS_NICE pour la priorite temps reel du DSP (run.sh, RT_NICE).
args=(--rm -it --cap-add NET_ADMIN --cap-add SYS_NICE --device /dev/net/tun)

uid="${SUDO_UID:-$(id -u)}"
for s in /run/pulse/native /var/run/pulse/native "/run/user/$uid/pulse/native"; do
    if [ -S "$s" ]; then
        args+=(-v "$(readlink -f "$s"):/run/pulse/native")
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

exec docker run "${args[@]}" "$IMG" "$@"
