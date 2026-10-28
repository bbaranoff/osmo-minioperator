# syntax=docker/dockerfile:1
# Dockerfile - osmo-minioperator : pile Osmocom (debs) + qosmo + c54x_exe
# ─────────────────────────────────────────────────────────────────────────────
# Version reduite du Dockerfile d'osmo-operator. On garde :
#
#   la pile Osmocom reseau   installee depuis les .deb OFFICIELS Osmocom (depot
#                            OBS osmocom:latest), PAS compilee depuis les sources.
#                            Donc pas de patches reseau (RAND, osmo-trx IPC...) :
#                            ce sont les binaires amont tels quels.
#   /opt/GSM/qosmo           l'arbre QEMU unique (bbaranoff/qosmO), target
#                            arm-softmmu, --enable-l1-grgsm. Porte run.sh /
#                            run_modules / cfgs et le lanceur C `qosmo`.
#   /opt/GSM/c54x_exe        le C54x HORS QEMU (TI mask-ROM). Compile les sources
#                            de /opt/GSM/qosmo et lie a libosmocoding/libosmocore.
#
# Par rapport a osmo-operator on laisse tomber : osmocom-bb, gr-gsm/GNU Radio,
# grgsm_exe, le dashboard Node, le 4G (srsRAN/Open5GS), le cache .deb maison
# (osmo-deb) et la compilation source de la pile.
#
# qosmo et c54x_exe ne sont PAS packages en amont : on les compile. libosmocore
# vient du depot (libosmocore-dev fournit libosmocoding.pc + libosmocore.pc dont
# le Makefile de c54x_exe a besoin : calypso_bsp.c encode la RACH via
# gsm0503_rach_ext_encode).
#
# Base ubuntu:24.04 (noble), comme osmo-operator : python 3.12, gcc 13.
#
# Graphe des stages :
#
#                       base   (apt + depot osmocom + libosmocore-dev)
#                        |
#                      qemu     (build /opt/GSM/qosmo)
#                        |
#                      c54x     (apt install pile osmo-* + build c54x_exe)
# ─────────────────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────────────────
# STAGE base — ubuntu:24.04 + depot Osmocom + dependances de build
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM

ENV container=docker \
    OSMO_IMAGE=1 \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib \
    GIT_TERMINAL_PROMPT=0

# Dependances de build (pour qosmo/QEMU et c54x_exe).
#   Outils             : build-essential git ... pkg-config, gnupg (cle du depot)
#   QEMU Calypso        : venv + numpy/scipy (outillage DSP), glib/pixman/slirp
#                         (target arm-softmmu), ninja (meson), socat (run.sh)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git gcc g++ make cmake autoconf automake libtool pkg-config \
      wget curl ca-certificates gnupg \
      python3 python3-dev python3-venv python3-pip python3-numpy python3-scipy \
      libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build \
      iproute2 procps psmisc util-linux \
    && rm -rf /var/lib/apt/lists/*

# ── Depot binaire Osmocom (OBS) ──────────────────────────────────────────────
# osmocom:latest pour xUbuntu_24.04. Toute la pile reseau (osmo-msc, osmo-bsc,
# osmo-bts, osmo-hlr, osmo-mgw, osmo-sgsn, osmo-ggsn, osmo-pcu,
# osmo-sip-connector, osmo-trx...) et libosmocore y sont fournis en .deb amont.
# La cle publique est armee (.asc) et va en /usr/share/osmocom-keyring/ : le
# paquet osmocom-keyring la met a jour la quand elle est etendue.
# OSMO_ASC_URL (et pas *_KEY) : evite le warning BuildKit SecretsUsedInArgOrEnv,
# qui signale tout ARG/ENV dont le nom contient KEY/TOKEN/SECRET. Ce n'est pas un
# secret : c'est l'URL d'une cle PUBLIQUE de signature.
ARG OSMO_OBS=https://downloads.osmocom.org/packages/osmocom:/latest/xUbuntu_24.04
ARG OSMO_ASC_URL=https://obs.osmocom.org/projects/osmocom/public_key
RUN install -d /usr/share/osmocom-keyring \
    && curl -fsSL "${OSMO_ASC_URL}" -o /usr/share/osmocom-keyring/osmocom.asc \
    && echo "deb [signed-by=/usr/share/osmocom-keyring/osmocom.asc] ${OSMO_OBS}/ ./" \
         > /etc/apt/sources.list.d/osmocom.list

# libosmocore-dev : fournit libosmocoding.pc + libosmocore.pc pour le link de
# c54x_exe. Present des `base` pour que le stage qemu derive l'ait aussi.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libosmocore-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git config --global http.postBuffer 524288000
SHELL ["/bin/bash", "-c"]
WORKDIR ${ROOT}


# ─────────────────────────────────────────────────────────────────────────────
# STAGE qemu — l'arbre QEMU unique /opt/GSM/qosmo (--enable-l1-grgsm)
# ─────────────────────────────────────────────────────────────────────────────
# `ninja install` installe aussi le lanceur C `qosmo`. L'arbre complet (build/
# inclus) reste dans l'image : QEMU_BIN pointe sur build/qemu-system-arm et QEMU
# lit build/qemu-bundle pour se relocaliser.
FROM base AS qemu
ARG ROOT=/opt/GSM

RUN git clone https://github.com/bbaranoff/qosmO /opt/GSM/qosmo \
    && cd /opt/GSM/qosmo \
    && python3 -m venv /root/.venv-qemu \
    && . /root/.venv-qemu/bin/activate \
    && pip install --no-cache-dir tomli \
    && mkdir -p build && cd build \
    && ../configure --target-list=arm-softmmu --enable-l1-grgsm \
           --prefix=/opt/GSM/qemu-install --disable-werror --disable-docs \
    && make -j"$(nproc)" \
    && make install \
    && cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm \
    && cp /opt/GSM/qemu-install/bin/qosmo /usr/local/bin/qosmo


# ─────────────────────────────────────────────────────────────────────────────
# STAGE c54x — pile Osmocom (debs) + c54x_exe
# ─────────────────────────────────────────────────────────────────────────────
# Derive de qemu : les sources /opt/GSM/qosmo et libosmocore-dev sont deja la.
FROM qemu AS c54x
ARG ROOT=/opt/GSM

# ── Pile Osmocom reseau depuis les .deb amont ────────────────────────────────
# osmo-stp inclus : MSC et BSC parlent SS7 (M3UA) au travers de lui.
RUN apt-get update && apt-get install -y --no-install-recommends \
      osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-bts osmo-pcu osmo-trx \
      osmo-sgsn osmo-ggsn osmo-sip-connector \
      telnet \
    && rm -rf /var/lib/apt/lists/*

# ── Firmware Calypso (layer1.highram.*) ──────────────────────────────────────
# Binaires prebuild pris directement dans github.com/bbaranoff/firmware : c'est
# ce que QEMU (-kernel .elf) et osmocon (romload .bin) recoivent en PHY_MODE=qemu
# (qemu paths.env ne connait que $GSM_ROOT/firmware). --depth 1 : seulement les
# binaires, pas l'historique.
RUN GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
      https://github.com/bbaranoff/firmware /opt/GSM/firmware

# ── c54x_exe : le C54x hors QEMU ─────────────────────────────────────────────
# Son Makefile met -march=native dans CFLAGS, ce qui ferait un SIGILL au
# demarrage sur un CPU different de l'hote de build. On garde ses flags sans
# celui-la. La ROM n'est pas dans le repo : rom/fetch-rom.sh telecharge le dump
# FreeCalypso 3606, le convertit en .bin et verifie SHA256SUMS.3606 ; la ROM est
# aussi deposee en /opt/GSM/calypso_dsp.*.bin (--rom-dir par defaut de c54x_exe).
ARG FREECALYPSO_URL=https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env
RUN git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe \
    && cd /opt/GSM/c54x_exe \
    && make QOSMO=/opt/GSM/qosmo \
           CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare" \
    && FREECALYPSO_URL="$FREECALYPSO_URL" bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom \
    && curl -fsS --retry 2 -o /opt/GSM/calypso_dsp.txt "$FREECALYPSO_URL/dsp-rom-3606-dump.txt" \
    && cp /opt/GSM/calypso_dsp.txt rom/calypso_dsp.txt

# ── osmocom-bb : layer 2/3 (mobile), osmocon, trxcon ─────────────────────────
# Compile dans src/ avec `make nofirmware` (host tools, PAS le firmware Calypso :
# celui-ci vient deja de github.com/bbaranoff/firmware). Le mode DSP utilise
# mobile + osmocon (layer23 cause L1CTL au firmware via la PTY serie de QEMU).
# Pin eac4eed1 : au-dela, upstream a retire trxcon de `make nofirmware` et l'a
# rendu dependant de libosmo-trx, donc un clone de HEAD ne produit plus trxcon.
ARG OSMOCOM_BB_REF=eac4eed1
RUN git clone https://gitea.osmocom.org/phone-side/osmocom-bb /opt/GSM/osmocom-bb \
    && git -C /opt/GSM/osmocom-bb checkout -q ${OSMOCOM_BB_REF} \
    && cd /opt/GSM/osmocom-bb/src \
    && make nofirmware \
    # make nofirmware n'installe rien : on expose `mobile` dans le PATH, la ou
    # c54x_exe/run.sh le cherche (osmocon, lui, est pris a son chemin par defaut
    # /opt/GSM/osmocom-bb/src/host/osmocon/osmocon).
    && ln -sf /opt/GSM/osmocom-bb/src/host/layer23/src/mobile/mobile /usr/local/bin/mobile

# ── Configs figees (mono-operateur) + scripts de lancement ───────────────────
# Les configs/ ont ete generees une fois (valeurs op=1, node=1, plan local) a
# partir des gabarits d'osmo-operator : plus aucun marqueur __XXX__, plus de
# moteur de substitution. Installees dans /etc/osmocom, ou les .deb Osmocom
# cherchent leur configuration.
# pont/ : le bridge DSP (pont_dsp.py et son paquet), repris d'osmo-operator.
# run-dsp.sh pointe PONT_PY dessus.
COPY configs/ /opt/GSM/osmo-minioperator/configs/
COPY pont/ /opt/GSM/osmo-minioperator/pont/
COPY run-dsp.sh start.sh /opt/GSM/osmo-minioperator/
RUN chmod +x /opt/GSM/osmo-minioperator/run-dsp.sh /opt/GSM/osmo-minioperator/start.sh \
    && install -d /etc/osmocom /var/lib/osmocom \
    && cp /opt/GSM/osmo-minioperator/configs/*.cfg /etc/osmocom/

# Dossier par defaut du conteneur + entrypoint : start.sh y lance le run DSP.
WORKDIR /opt/GSM/osmo-minioperator
ENTRYPOINT ["/opt/GSM/osmo-minioperator/start.sh"]
