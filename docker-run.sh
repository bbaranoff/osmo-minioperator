#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# docker-run.sh - lance le conteneur avec l'audio de l'hote : le socket PulseAudio
# est monte en /run/pulse/native (sans lui l'appel est muet). Arguments passes
# tels quels au conteneur (defaut : bash).
set -eu
IMG="${IMG:-osmo-minioperator}"
args=(--rm -it --privileged)

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
