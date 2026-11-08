#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# tests-cli.sh - replays tests.ipynb (Tests section of the README: build, verif.sh at
# INSNS=120000) on the command line, cell by cell, recorded
# with asciinema. The figures are written as PNG into tests-out/.
#
#   ./tests-cli.sh                       build --no-cache + 2 verdicts, -> tests-out/campagne.cast
#   NO_CACHE=0 ./tests-cli.sh            incremental build
#   BUILD=0 IMG=osmo-minioperator ./tests-cli.sh   no build, existing image
#   ./tests-cli.sh --sans-asciinema      in the terminal only
#
# Replay: asciinema play tests-out/campagne.cast   (share: asciinema upload ...)
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
mkdir -p tests-out
RUN=(ipython --no-banner --colors=Neutral "$HERE/tests-out/.pas-a-pas.py" "$HERE/tests.ipynb")

# Runs the cells in a single IPython shell: markdown shown as a title,
# code shown then run; stops at the first failing cell.
cat > tests-out/.pas-a-pas.py <<'PY'
import sys, nbformat
nb = nbformat.read(sys.argv[1], as_version=4)
ip = get_ipython()
for i, c in enumerate(nb.cells, 1):
    if c.cell_type == "markdown":
        print(f"\n\033[1;36m{'=' * 78}\n{c.source}\n{'=' * 78}\033[0m", flush=True)
        continue
    print("\n\033[33m" + "\n".join(">>> " + l for l in c.source.splitlines()) + "\033[0m\n", flush=True)
    if not ip.run_cell(c.source).success:
        print(f"\n\033[1;31mstopped: cell {i} failed\033[0m"); sys.exit(1)
print("\n\033[1;32mstep by step done\033[0m")
PY

if [ "${1:-}" = --sans-asciinema ]; then
    exec "${RUN[@]}"
fi
command -v asciinema >/dev/null || { echo "asciinema missing: pip install asciinema (or apt install asciinema)" >&2; exit 1; }
exec asciinema rec --overwrite -t "osmo-minioperator: build + verif.sh (tests.ipynb)" \
     -c "$(printf '%q ' "${RUN[@]}")" tests-out/campagne.cast
