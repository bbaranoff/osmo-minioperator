#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# echo-tmux.sh - echo test « hello 40c3 » dans une session tmux (pas la commande par defaut du conteneur).
#   gauche        echotest.py : appel au 600, « >>> say: hello 40c3 » a l'entree dans Echo(),
#                 indicateurs SPEAK (micro) et ECHO (retour), enregistre les pistes GSM dans /root/echo
#                 (echo.cast, dl.wav descendant, ul.wav montant, echo.wav les deux ; jamais le micro brut)
#   droite haut   mobile.log : LU, service, etats d'appel (CC), perte de cellule
#   droite bas    pont.log : horloge vers la BTS (IND CLOCK) et marche/arret de l'emetteur
# Prerequis : la pile lancee (./run-dsp.sh) et l'audio de l'hote (./docker-run.sh).
#   ./echo-tmux.sh                 ./echo-tmux.sh --duree 25      (arguments passes a echotest.py)
# Ctrl-C dans le panneau de gauche arrete le test ; « C-b d » detache, « tmux kill-session -t echo » ferme.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S=echo
ARGS=$(printf ' %q' "$@")
tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -x "$(tput cols 2>/dev/null || echo 200)" -y "$(tput lines 2>/dev/null || echo 50)" \
  "python3 $HERE/echotest.py$ARGS; echo; read -rp 'Entree pour fermer la session ' _; tmux kill-session -t $S"
tmux split-window -h -t "$S" "tail -n 0 -F /tmp/c54x-pont/mobile.log 2>/dev/null | grep -a --line-buffered -E 'LOCATION UPDATING|CM SERVICE|gsm48_cc.c:[0-9]+ new state|no cell available|LOS during' | sed -u 's/\x1b\[[0-9;]*m//g' | cut -c12-130"
tmux split-window -v -t "$S" "tail -n 0 -F /tmp/c54x-pont/pont.log 2>/dev/null | grep -a --line-buffered -E 'IND CLOCK|CTRL POWER'"
tmux set -t "$S" pane-border-status top >/dev/null
tmux select-pane -t "$S:0.0" -T 'echotest.py (hello 40c3)'
tmux select-pane -t "$S:0.1" -T 'mobile.log : appel'
tmux select-pane -t "$S:0.2" -T 'pont.log : horloge vers la BTS'
tmux set-window-option -t "$S" main-pane-width "$(( $(tput cols 2>/dev/null || echo 200) * 55 / 100 ))" >/dev/null
tmux select-layout -t "$S" main-vertical >/dev/null
tmux select-pane -t "$S:0.0"
exec tmux attach -t "$S"
