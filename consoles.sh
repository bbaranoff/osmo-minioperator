#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# consoles.sh - « Three consoles, one phone call » : une session tmux, trois panneaux.
# ─────────────────────────────────────────────────────────────────────────────
#   fenetre « consoles »  1. shell Harvard du DSP C54x (c54x_exe/harvard.sh repl : d@ d_task_d ...)
#                         2. gdb-multiarch sur le layer1 de l'ARM (gdbstub QEMU 127.0.0.1:1234)
#                         3. VTY du mobile OsmocomBB (telnet 127.0.0.1 4247, « enable » envoye)
#   fenetre « pile »      ./run-dsp.sh (toute la pile), puis un shell
#
# Chaque panneau attend son service avant de s'y connecter, et se reconnecte quand
# on le quitte (q / quit / Ctrl-]). L'attente ne se connecte JAMAIS au port : une
# simple connexion au gdbstub QEMU arrete l'ARM (gdbstub/system.c : vm_stop a
# l'ouverture). On regarde donc les sockets en ecoute (ss), pas « qui repond ».
#
#   ./consoles.sh              cree la session (si besoin) et s'y attache
#   ./consoles.sh --pane X     contenu d'un panneau (dsp | gdb | vty), usage interne
# Variables : CONSOLES_SESSION (demo), TTYD=1 (acces navigateur, voir plus bas).
# ─────────────────────────────────────────────────────────────────────────────
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${CONSOLES_SESSION:-demo}"
GSM_ROOT="${GSM_ROOT:-/opt/GSM}"

# Valeurs reprises des lanceurs, pas choisies ici :
#   c54x_exe/run.sh : DSP_SOCK, DSP_SHM, RUNDIR=/tmp/c54x-pont, GDB_STUB=1234,
#                     FIRMWARE_ELF=$_FW/layer1.highram.elf (_FW=/opt/GSM/firmware/board/compal_e88)
#   configs/mobile.cfg : « bind 127.0.0.1 4247 » (VTY du mobile)
C54X="${C54X:-$GSM_ROOT/c54x_exe}"
QOSMO="${QOSMO:-$GSM_ROOT/qosmo}"
DSP_SOCK=/tmp/calypso_dsp.sock
DSP_SHM=/dev/shm/calypso_api_ram
MOBILE_LOG=/tmp/c54x-pont/mobile.log
GDB_STUB=1234
VTY_PORT=4247
FIRMWARE_ELF="${FIRMWARE_ELF:-$GSM_ROOT/firmware/board/compal_e88/layer1.highram.elf}"
# L'ELF a ete compile dans /opt/GSM/osmocom-bb/src/target/firmware (DW_AT_comp_dir),
# ses sources sont celles du depot firmware (/opt/GSM/firmware, meme commit que l'ELF).
FW_DWARF_DIR=/opt/GSM/osmocom-bb/src/target/firmware
FW_SRC="${FW_SRC:-$GSM_ROOT/firmware}"

gras() { printf '\033[1m%s\033[0m\n' "$*"; }

# ecoute <port> : un socket TCP en ecoute sur ce port (sans s'y connecter)
ecoute() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }

# attendre <description> <commande...> : attente active, un point par seconde
attendre() {
    local quoi="$1"; shift
    "$@" && return 0
    printf 'attente : %s ' "$quoi"
    until "$@"; do printf '.'; sleep 1; done
    echo " ok"
}

# Le gdb et le VTY attendent en plus l'attachement du mobile (max 300 s, comme
# verif.sh) : arreter l'ARM pendant la recherche de cellule la retarderait, et
# « call » avant le LU echoue.
attendre_lu() {
    local n=0
    grep -q 'LOCATION UPDATING ACCEPT' "$MOBILE_LOG" 2>/dev/null && return 0
    printf 'attente : LOCATION UPDATING ACCEPT dans %s ' "$MOBILE_LOG"
    until grep -q 'LOCATION UPDATING ACCEPT' "$MOBILE_LOG" 2>/dev/null; do
        n=$((n + 1)); [ "$n" -ge 300 ] && { echo " (pas de LU apres 300 s, on continue)"; return 0; }
        printf '.'; sleep 1
    done
    echo " ok"
}

relancer() { echo; gras "[$1] termine. Entree pour reconnecter."; read -r _ || sleep 2; }

panneau_dsp() {
    while :; do
        clear; gras "1. DSP C54x : shell Harvard (API RAM $DSP_SHM)"
        attendre "DSP c54x_exe --arm ($DSP_SOCK, $DSP_SHM)" \
            sh -c "[ -S '$DSP_SOCK' ] && [ -e '$DSP_SHM' ]"
        echo "essayer :  d@ d_task_d    d@ W0    d@ R0    d@ noms d_task    aide"
        "$C54X/harvard.sh" repl
        relancer dsp
    done
}

panneau_gdb() {
    while :; do
        clear; gras "2. ARM : gdb sur layer1 ($FIRMWARE_ELF)"
        attendre "gdbstub QEMU en ecoute sur 127.0.0.1:$GDB_STUB" ecoute "$GDB_STUB"
        attendre_lu
        echo "la cible tourne (continue &) :  stop -> bt -> go     list l1a_l23_handler     help_osmo"
        # Memes options que qosmo/tools/gdb-telnet.py (console telnet 44444), en direct
        # dans le panneau pour pouvoir ajouter substitute-path. Un seul client gdb a la
        # fois sur le stub : tant que ce gdb est attache, « telnet 0 44444 » et la
        # commande gdb de harvard.sh ne peuvent pas s'y attacher.
        local panneau=()   # panneau osmocom de qosmo (help_osmo, stop, go, fn, ndb...)
        [ -f "$QOSMO/tools/cmd.gdb" ] && panneau=(-x "$QOSMO/tools/cmd.gdb")
        OSMO_GDB_TOOLS="$QOSMO/tools" gdb-multiarch -q -nx \
            -iex 'set pagination off' -iex 'set confirm off' \
            -iex 'set height 0' -iex 'set width 0' \
            -iex "set substitute-path $FW_DWARF_DIR $FW_SRC" \
            -ex 'set architecture armv5te' \
            -ex "target remote 127.0.0.1:$GDB_STUB" \
            -ex 'continue &' \
            "${panneau[@]}" \
            "$FIRMWARE_ELF"
        relancer gdb
    done
}

panneau_vty() {
    while :; do
        clear; gras "3. mobile OsmocomBB : VTY telnet 127.0.0.1:$VTY_PORT"
        attendre "VTY du mobile en ecoute sur 127.0.0.1:$VTY_PORT" ecoute "$VTY_PORT"
        attendre_lu
        echo "appel :  call 1 600   (puis : hangup 1)"
        # « call » est dans le noeud enable : on le tape pour l'utilisateur, une fois
        # telnet lance (la frappe attend dans le tty si telnet n'a pas encore lu).
        ( sleep 1; tmux send-keys -t "$TMUX_PANE" 'enable' Enter ) &
        telnet 127.0.0.1 "$VTY_PORT"
        relancer vty
    done
}

case "${1:-}" in
    --pane)
        # Locale UTF-8 pour les panneaux seulement (pas pour run-dsp.sh) : sans elle le
        # Python de cmd.gdb (demo-layer1.py) echoue sur ses tirets « — » (ascii codec).
        export LANG=C.UTF-8 LC_ALL=C.UTF-8
        case "${2:-}" in
            dsp) panneau_dsp ;; gdb) panneau_gdb ;; vty) panneau_vty ;;
            *) echo "usage : $0 --pane dsp|gdb|vty" >&2; exit 2 ;;
        esac; exit ;;
    -h|--help) sed -n '4,20p' "$0"; exit 0 ;;
esac

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    # Fenetre « pile » d'abord : la pile demarre pendant que les panneaux attendent.
    tmux -u new-session -d -s "$SESSION" -n pile -x 200 -y 50 -c "$HERE" \
        "bash -c '\"$HERE/run-dsp.sh\"; exec bash'"
    tmux set-option -t "$SESSION" -g mouse on >/dev/null
    tmux set-option -t "$SESSION" -g remain-on-exit off >/dev/null
    tmux new-window -t "$SESSION" -n consoles -c "$HERE" "\"$HERE/consoles.sh\" --pane dsp"
    tmux split-window -t "$SESSION:consoles" -h -c "$HERE" "\"$HERE/consoles.sh\" --pane gdb"
    tmux split-window -t "$SESSION:consoles.1" -v -c "$HERE" "\"$HERE/consoles.sh\" --pane vty"
    tmux select-pane -t "$SESSION:consoles.2"
    tmux select-window -t "$SESSION:consoles"
fi

if [ -t 0 ] && [ -t 1 ]; then
    tmux -u attach -t "$SESSION"
    # Detache (C-b d) : un shell, la pile continue de tourner.
    gras "session tmux « $SESSION » detachee (la pile tourne) : tmux attach -t $SESSION pour revenir"
    exec bash
fi
# Sans terminal (docker run -d) : on garde le conteneur en vie tant que la session existe.
while tmux has-session -t "$SESSION" 2>/dev/null; do sleep 5; done
