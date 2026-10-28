# syntax=docker/dockerfile:1
# osmo-minioperator : pile Osmocom (debs) + qosmo + c54x_exe + osmocom-bb, run DSP.

FROM ubuntu:24.04 AS base
ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM
ENV container=docker \
    OSMO_IMAGE=1 \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib \
    GIT_TERMINAL_PROMPT=0

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git gcc g++ make cmake autoconf automake libtool pkg-config \
      wget curl ca-certificates gnupg \
      python3 python3-dev python3-venv python3-pip python3-numpy python3-scipy \
      libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build \
      iproute2 procps psmisc util-linux \
    && rm -rf /var/lib/apt/lists/*

# Depot binaire Osmocom (OBS). OSMO_ASC_URL (pas *_KEY) : evite le warning
# BuildKit SecretsUsedInArgOrEnv ; c'est une cle PUBLIQUE de signature.
ARG OSMO_OBS=https://downloads.osmocom.org/packages/osmocom:/latest/xUbuntu_24.04
ARG OSMO_ASC_URL=https://obs.osmocom.org/projects/osmocom/public_key
RUN install -d /usr/share/osmocom-keyring \
    && curl -fsSL "${OSMO_ASC_URL}" -o /usr/share/osmocom-keyring/osmocom.asc \
    && echo "deb [signed-by=/usr/share/osmocom-keyring/osmocom.asc] ${OSMO_OBS}/ ./" \
         > /etc/apt/sources.list.d/osmocom.list

# libosmocore-dev : libosmocoding.pc + libosmocore.pc pour le link de c54x_exe.
RUN apt-get update && apt-get install -y --no-install-recommends libosmocore-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git config --global http.postBuffer 524288000
SHELL ["/bin/bash", "-c"]
WORKDIR ${ROOT}


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


FROM qemu AS c54x
ARG ROOT=/opt/GSM

# Pile Osmocom reseau depuis les .deb amont (osmo-stp inclus : SS7/M3UA).
# libosmo-csn1-dev + libosmo-gprs-*-dev : requis par osmocom-bb (pkg-config).
RUN apt-get update && apt-get install -y --no-install-recommends \
      osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-bts osmo-pcu osmo-trx \
      osmo-sgsn osmo-ggsn osmo-sip-connector telnet \
      asterisk asterisk-core-sounds-en pulseaudio-utils \
      libosmo-csn1-dev libosmo-gprs-rlcmac-dev libosmo-gprs-llc-dev \
      libosmo-gprs-gmm-dev libosmo-gprs-sm-dev libosmo-gprs-sndcp-dev \
    && rm -rf /var/lib/apt/lists/*

# Firmware Calypso prebuild (PHY_MODE=qemu : QEMU -kernel .elf, osmocon romload .bin).
RUN GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
      https://github.com/bbaranoff/firmware /opt/GSM/firmware

# c54x_exe : CFLAGS sans -march=native (SIGILL sur un autre CPU que l'hote de build).
ARG FREECALYPSO_URL=https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env
RUN git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe \
    && cd /opt/GSM/c54x_exe \
    && make QOSMO=/opt/GSM/qosmo \
           CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare" \
    && FREECALYPSO_URL="$FREECALYPSO_URL" bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom \
    && curl -fsS --retry 2 -o /opt/GSM/calypso_dsp.txt "$FREECALYPSO_URL/dsp-rom-3606-dump.txt" \
    && cp /opt/GSM/calypso_dsp.txt rom/calypso_dsp.txt

# osmocom-bb : make nofirmware dans src/ (mobile, osmocon, trxcon). Pin eac4eed1
# (au-dela trxcon sort de make nofirmware). On expose `mobile` dans le PATH.
ARG OSMOCOM_BB_REF=eac4eed1
RUN git clone https://gitea.osmocom.org/phone-side/osmocom-bb /opt/GSM/osmocom-bb \
    && git -C /opt/GSM/osmocom-bb checkout -q ${OSMOCOM_BB_REF} \
    && cd /opt/GSM/osmocom-bb/src \
    && make nofirmware \
    && ln -sf /opt/GSM/osmocom-bb/src/host/layer23/src/mobile/mobile /usr/local/bin/mobile

# Configs figees (mono-operateur) + pont DSP + scripts. Lien /opt/GSM/osmo-operator :
# c54x_exe/run.sh lance le pont audio VSP par "cd /opt/GSM/osmo-operator && python3 -m pont.vsp_audio".
COPY configs/ /opt/GSM/osmo-minioperator/configs/
COPY configs/asterisk/ /etc/asterisk/
COPY pont/ /opt/GSM/osmo-minioperator/pont/
COPY run-dsp.sh start.sh /opt/GSM/osmo-minioperator/
RUN chmod +x /opt/GSM/osmo-minioperator/run-dsp.sh /opt/GSM/osmo-minioperator/start.sh \
    && install -d /etc/osmocom /var/lib/osmocom /var/log/osmocom /root/.osmocom/bb \
    && cp /opt/GSM/osmo-minioperator/configs/*.cfg /etc/osmocom/ \
    && cp /opt/GSM/osmo-minioperator/configs/mobile.cfg /root/.osmocom/bb/mobile.cfg \
    && ln -s /opt/GSM/osmo-minioperator /opt/GSM/osmo-operator

# Audio : le socket PulseAudio de l'hote est monte ici par docker-run.sh.
ENV PULSE_SERVER=unix:/run/pulse/native

WORKDIR /opt/GSM/osmo-minioperator
ENTRYPOINT ["/opt/GSM/osmo-minioperator/start.sh"]
CMD ["/bin/bash"]
