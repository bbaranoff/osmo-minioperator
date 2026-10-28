#!/usr/bin/env bash
# install.sh - osmo-minioperator en natif (Ubuntu 24.04)
# ─────────────────────────────────────────────────────────────────────────────
# Equivalent natif du Dockerfile : meme pile Osmocom (depuis les .deb amont),
# meme qosmo + c54x_exe compiles, meme firmware. A lancer en root sur une
# ubuntu:24.04 (noble).
#
#   pile Osmocom reseau   depot binaire OBS osmocom:latest (pas de compilation)
#   /opt/GSM/qosmo        QEMU arm-softmmu --enable-l1-grgsm + lanceur `qosmo`
#   /opt/GSM/c54x_exe     le C54x hors QEMU (lie a libosmocoding/libosmocore)
#   /opt/GSM/firmware     binaires prebuild (github.com/bbaranoff/firmware)
#
# Idempotent : chaque etape saute si sa cible existe deja.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT=/opt/GSM
OSMO_OBS=${OSMO_OBS:-https://downloads.osmocom.org/packages/osmocom:/latest/xUbuntu_24.04}
OSMO_ASC_URL=${OSMO_ASC_URL:-https://obs.osmocom.org/projects/osmocom/public_key}
OSMOCOM_BB_REF=${OSMOCOM_BB_REF:-eac4eed1}
FREECALYPSO_URL=${FREECALYPSO_URL:-https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env}
export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
export LD_LIBRARY_PATH=/usr/local/lib

log() { echo -e "\n\033[1;36m== $* ==\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "A lancer en root (sudo bash install.sh)." >&2
    exit 1
fi

# ── 1. Dependances de build ──────────────────────────────────────────────────
log "Dependances apt (build qosmo + c54x_exe)"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential git gcc g++ make cmake autoconf automake libtool pkg-config \
    wget curl ca-certificates gnupg \
    python3 python3-dev python3-venv python3-pip python3-numpy python3-scipy \
    libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build \
    iproute2 procps psmisc util-linux

# ── 2. Depot binaire Osmocom + pile reseau (.deb amont) ──────────────────────
log "Depot Osmocom (OBS) + pile reseau"
# Cle publique armee (.asc) en /usr/share/osmocom-keyring/ : le paquet
# osmocom-keyring la met a jour la quand elle est etendue.
install -d /usr/share/osmocom-keyring
curl -fsSL "${OSMO_ASC_URL}" -o /usr/share/osmocom-keyring/osmocom.asc
echo "deb [signed-by=/usr/share/osmocom-keyring/osmocom.asc] ${OSMO_OBS}/ ./" \
    > /etc/apt/sources.list.d/osmocom.list
apt-get update
# libosmocore-dev : libosmocoding.pc + libosmocore.pc pour le link de c54x_exe.
# osmo-stp : MSC et BSC parlent SS7 (M3UA) au travers de lui. telnet : provisioning
# HLR par la VTY (run-dsp.sh).
# libosmo-gprs-*-dev : osmocom-bb (mobile/modem GPRS) les demande via pkg-config
# (sinon "Package 'libosmo-gprs-rlcmac', required by 'virtual:world', not found").
apt-get install -y --no-install-recommends \
    libosmocore-dev telnet \
    osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-bts osmo-pcu osmo-trx \
    osmo-sgsn osmo-ggsn osmo-sip-connector \
    libosmo-gprs-rlcmac-dev libosmo-gprs-llc-dev libosmo-gprs-gmm-dev \
    libosmo-gprs-sm-dev libosmo-gprs-csn1-dev

git config --global http.postBuffer 524288000
mkdir -p "$ROOT"

# ── 3. qosmo : QEMU arm-softmmu --enable-l1-grgsm ────────────────────────────
log "qosmo (QEMU Calypso)"
if [ ! -x /usr/local/bin/qosmo ]; then
    [ -d "$ROOT/qosmo" ] || git clone https://github.com/bbaranoff/qosmO "$ROOT/qosmo"
    cd "$ROOT/qosmo"
    [ -d /root/.venv-qemu ] || python3 -m venv /root/.venv-qemu
    # shellcheck disable=SC1091
    source /root/.venv-qemu/bin/activate
    pip install --no-cache-dir tomli
    mkdir -p build && cd build
    ../configure --target-list=arm-softmmu --enable-l1-grgsm \
        --prefix="$ROOT/qemu-install" --disable-werror --disable-docs
    make -j"$(nproc)"
    make install
    cp "$ROOT/qemu-install/bin/qemu-system-arm" /usr/local/bin/qemu-system-arm
    cp "$ROOT/qemu-install/bin/qosmo" /usr/local/bin/qosmo
    deactivate || true
else
    echo "qosmo deja installe, saute."
fi

# ── 4. Firmware Calypso (prebuild) ───────────────────────────────────────────
log "Firmware Calypso"
if [ ! -d "$ROOT/firmware" ]; then
    git clone --depth 1 https://github.com/bbaranoff/firmware "$ROOT/firmware"
else
    echo "firmware deja present, saute."
fi

# ── 5. c54x_exe : le C54x hors QEMU ──────────────────────────────────────────
# -march=native retire des CFLAGS (SIGILL possible si le CPU d'exec differe).
log "c54x_exe (C54x hors QEMU)"
[ -d "$ROOT/c54x_exe" ] || git clone https://github.com/bbaranoff/c54x_exe "$ROOT/c54x_exe"
cd "$ROOT/c54x_exe"
make QOSMO="$ROOT/qosmo" \
    CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare"
FREECALYPSO_URL="$FREECALYPSO_URL" bash rom/fetch-rom.sh --dest "$ROOT" --dest "$ROOT/c54x_exe/rom"
curl -fsS --retry 2 -o "$ROOT/calypso_dsp.txt" "$FREECALYPSO_URL/dsp-rom-3606-dump.txt"
cp "$ROOT/calypso_dsp.txt" rom/calypso_dsp.txt

# ── 6. osmocom-bb : layer 2/3 (mobile), osmocon, trxcon ──────────────────────
# Compile dans src/ avec `make nofirmware` (host tools, PAS le firmware). Pin
# eac4eed1 : au-dela, trxcon sort de `make nofirmware`.
log "osmocom-bb (make nofirmware dans src/)"
if [ ! -x "$ROOT/osmocom-bb/src/host/layer23/src/mobile/mobile" ]; then
    [ -d "$ROOT/osmocom-bb" ] || git clone https://gitea.osmocom.org/phone-side/osmocom-bb "$ROOT/osmocom-bb"
    git -C "$ROOT/osmocom-bb" checkout -q "$OSMOCOM_BB_REF"
    make -C "$ROOT/osmocom-bb/src" nofirmware
else
    echo "osmocom-bb deja compile, saute."
fi
# make nofirmware n'installe rien : on expose `mobile` dans le PATH.
ln -sf "$ROOT/osmocom-bb/src/host/layer23/src/mobile/mobile" /usr/local/bin/mobile

# ── 7. Configs figees (mono-operateur) -> /etc/osmocom ───────────────────────
log "Configs figees -> /etc/osmocom"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d /etc/osmocom /var/lib/osmocom
cp "$HERE/configs/"*.cfg /etc/osmocom/
chmod +x "$HERE/run-dsp.sh" "$HERE/start.sh" 2>/dev/null || true

ldconfig
log "Termine. Lancer l'operateur en DSP : $HERE/run-dsp.sh"
