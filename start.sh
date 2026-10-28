#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# start.sh - entrypoint du conteneur : exec la commande (bash par defaut).
# La preparation (dossiers, configs) est faite par run-dsp.sh : lancer
# ./run-dsp.sh suffit, sans passer par start.sh.
exec "${@:-/bin/bash}"
