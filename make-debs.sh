#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# make-debs.sh - fabrique les .deb de qosmo et c54x_exe a partir de l'image
# osmo-minioperator construite depuis les sources (BUILD_DEB=1) :
#
#   sudo docker build -t osmo-minioperator --build-arg BUILD_DEB=1 .
#   sudo ./make-debs.sh [dossier]          # defaut : ./debs
#
# Les paquets reprennent les chemins attendus par c54x_exe/run.sh
# (/opt/GSM/qosmo/build/qemu-system-arm, /opt/GSM/c54x_exe/...). La mask-ROM
# du DSP (code TI, hors GPL) n'est PAS dans le paquet c54x_exe : elle reste
# telechargee et verifiee par rom/fetch-rom.sh au build de l'image.
set -eu
IMG="${IMG:-osmo-minioperator}"
OUT="$(realpath -m "${1:-debs}")"
mkdir -p "$OUT"

docker run --rm --entrypoint bash -v "$OUT:/out" "$IMG" -c '
set -eu
[ -x /opt/GSM/qosmo/build/qemu-system-arm ] && [ -d /opt/GSM/c54x_exe/.git ] \
    || { echo "image sans les sources : la construire avec --build-arg BUILD_DEB=1" >&2; exit 1; }
version() {   # 0.git<date du commit>.<sha> (pas de ~ : GitHub le renomme dans les assets)
    git -C "$1" log -1 --format="0.git%cd.%h" --date=format:%Y%m%d
}
control() {   # control <dir> <nom> <version> <depends> <description>
    install -d "$1/DEBIAN"
    cat > "$1/DEBIAN/control" <<EOF
Package: $2
Version: $3
Architecture: amd64
Maintainer: Bastien Baranoff <bastienbaranoff@gmail.com>
Depends: $4
Section: misc
Priority: optional
Installed-Size: $(du -sk "$1" | cut -f1)
Description: $5
EOF
}

# ── qosmo : QEMU Calypso (ARM + layer1) ──────────────────────────────────────
Q=/opt/GSM/qosmo; V=$(version $Q); P=/tmp/qosmo_${V}_amd64
install -d $P$Q/build $P/usr/local/bin $P/usr/share/doc/qosmo
install -m755 $Q/build/qemu-system-arm $P$Q/build/
cp -a $Q/tools $P$Q/
ln -s $Q/build/qemu-system-arm $P/usr/local/bin/qemu-system-arm
install -m755 /usr/local/bin/qosmo $P/usr/local/bin/
cp $Q/COPYING $P/usr/share/doc/qosmo/copyright
echo "https://github.com/bbaranoff/qosmO commit $(git -C $Q rev-parse HEAD)" > $P/usr/share/doc/qosmo/SOURCE
control $P qosmo "$V" "libglib2.0-0t64, libpixman-1-0, libslirp0, libusb-1.0-0, zlib1g" \
    "QEMU Calypso (qosmo) : ARM du telephone + layer1, cible arm-softmmu"
dpkg-deb --root-owner-group -Zxz --build $P /out/ >/dev/null

# ── c54x_exe : DSP TMS320C54x hors QEMU ──────────────────────────────────────
C=/opt/GSM/c54x_exe; V=$(version $C); P=/tmp/c54x-exe_${V}_amd64
install -d $P$C $P/usr/share/doc/c54x-exe
# Fichiers du depot (calypso_dsp.Registers.bin compris : etat des registres au
# reset, pas de la ROM) ; les sections ROM ecrites par fetch-rom.sh en sont absentes.
git -C $C ls-files -z | tar -C $C --null -T - -cf - | tar -C $P$C -xf -
install -m755 $C/c54x_exe $P$C/
cp $C/LICENSE $P/usr/share/doc/c54x-exe/copyright
echo "https://github.com/bbaranoff/c54x_exe commit $(git -C $C rev-parse HEAD)" > $P/usr/share/doc/c54x-exe/SOURCE
control $P c54x-exe "$V" "libosmocore22, libosmogsm20, libosmocodec4, libosmocoding0, libtalloc2, python3, curl" \
    "Emulateur DSP TI C54x du Calypso (c54x_exe), sans la mask-ROM TI (rom/fetch-rom.sh)"
dpkg-deb --root-owner-group -Zxz --build $P /out/ >/dev/null

# Aucune ROM TI dans les paquets (Registers.bin : pas de la ROM).
for d in /out/*.deb; do
    ! dpkg-deb -c "$d" | grep -vF Registers.bin | grep -qE "calypso_dsp[^/]*\.(bin|txt)$" || { echo "ROM dans $d" >&2; exit 1; }
done
chown "'"$(id -u):$(id -g)"'" /out/*.deb
'
(cd "$OUT" && sha256sum *.deb | tee SHA256SUMS)
