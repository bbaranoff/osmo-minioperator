#!/usr/bin/env bash
# run-dsp.sh - lance l'operateur mono (configs figees) en mode DSP.
# ─────────────────────────────────────────────────────────────────────────────
# Chaque composant Osmocom est lance COMME UNE APPLICATION (le binaire en
# avant-plan, mis en arriere-plan ici), PAS comme un service systemd. Chacun lit
# sa config dans /etc/osmocom (posee par le Dockerfile / install.sh) et ecrit son
# log dans $LOG_DIR.
#
# Ordre (dependances SS7/A-interface) :
#   osmo-stp            coeur SS7 (M3UA) - tout le monde s'y connecte
#   osmo-hlr            base abonnes (+ provisioning de l'abonne 1 ci-dessous)
#   osmo-mgw            media gateway
#   osmo-msc            cause STP + HLR + MGW
#   osmo-bsc            cause STP + MGW, porte l'OML du BTS
#   osmo-bts-trx        le BTS cote air (TRXD 5700-5702)
#   osmo-pcu/sgsn/ggsn/sip-connector   le reste de la pile (best effort)
# puis la chaine DSP (c54x_exe/run.sh MODE=dsp PONT=1) :
#   c54x_exe --arm  ->  qosmo (ARM+L1)  ->  osmocon  ->  mobile  ->  pont_dsp.py
#
#   ./run-dsp.sh            lance tout
#   ./run-dsp.sh --stop     arrete tout
#   ./run-dsp.sh --logs     suit les logs du coeur
# ─────────────────────────────────────────────────────────────────────────────
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GSM_ROOT="${GSM_ROOT:-/opt/GSM}"
CFG_DIR="${OSMOCOM_CFG:-/etc/osmocom}"
LOG_DIR="${LOG_DIR:-/run/osmo-minioperator/logs}"
C54X="${C54X:-$GSM_ROOT/c54x_exe}"

# Plan mono-operateur (doit coller aux configs/ figees : op=1, node=1).
IMSI="${IMSI:-001010001000001}"
MSISDN="${MSISDN:-100101}"
KI_HEX="${KI_HEX:-00112233445566778899aabbccdd0101}"
HLR_VTY_IP="${HLR_VTY_IP:-127.0.0.1}"
HLR_VTY_PORT="${HLR_VTY_PORT:-4258}"

mkdir -p "$LOG_DIR"
# /var/log/osmocom : les configs ont "log file /var/log/osmocom/*.log".
install -d /var/log/osmocom /var/lib/osmocom
# mobile.cfg va dans le chemin par defaut du mobile (/root/.osmocom/bb), pas /etc/osmocom.
install -d /root/.osmocom/bb
cp "$HERE/configs/mobile.cfg" /root/.osmocom/bb/mobile.cfg
PIDS="$LOG_DIR/pids"

say() { printf '\033[1m[run-dsp]\033[0m %s\n' "$*"; }

# ── Arret ────────────────────────────────────────────────────────────────────
stop_all() {
    say "arret de la chaine DSP"
    [ -x "$C54X/run.sh" ] && MODE=dsp "$C54X/run.sh" --stop >/dev/null 2>&1 || true
    say "arret des composants Osmocom"
    if [ -f "$PIDS" ]; then
        # arret dans l'ordre inverse
        tac "$PIDS" | while read -r pid name; do
            kill "$pid" 2>/dev/null && say "  stop $name ($pid)"
        done
        rm -f "$PIDS"
    fi
    # filet : les binaires lances comme applications
    for b in osmo-sip-connector osmo-ggsn osmo-sgsn osmo-pcu osmo-bts-trx \
             osmo-bsc osmo-msc osmo-mgw osmo-hlr osmo-stp; do
        pkill -x "$b" 2>/dev/null || true
    done
}

case "${1:-}" in
    --stop) stop_all; exit 0 ;;
    --logs) exec tail -n +1 -F "$LOG_DIR"/*.log ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
esac

# ── Lancer un composant comme une application ────────────────────────────────
# app <binaire> <fichier-conf> [args...]
: > "$PIDS"
app() {
    local bin="$1" cfg="$2"; shift 2
    local path; path="$(command -v "$bin" || true)"
    if [ -z "$path" ]; then say "  ABSENT : $bin (saute)"; return 0; fi
    if [ -n "$cfg" ] && [ ! -f "$CFG_DIR/$cfg" ]; then
        say "  config absente : $CFG_DIR/$cfg ($bin saute)"; return 0
    fi
    local args=()
    [ -n "$cfg" ] && args+=(-c "$CFG_DIR/$cfg")
    "$path" "${args[@]}" "$@" >"$LOG_DIR/$bin.log" 2>&1 &
    local pid=$!
    echo "$pid $bin" >> "$PIDS"
    say "  start $bin ($pid)  cfg=${cfg:-aucune}"
    sleep 1
}

say "configs : $CFG_DIR    logs : $LOG_DIR"

# Coeur, chacun comme une application (ordre des dependances)
app osmo-stp        osmo-stp.cfg
app osmo-hlr        osmo-hlr.cfg       --database /var/lib/osmocom/hlr.db
app osmo-mgw        osmo-mgw.cfg
app osmo-msc        osmo-msc.cfg
app osmo-bsc        osmo-bsc.cfg
app osmo-bts-trx    osmo-bts-trx.cfg
# Reste de la pile (best effort : peut attendre ses pairs sans bloquer)
app osmo-pcu            osmo-pcu.cfg
app osmo-sgsn           osmo-sgsn.cfg
app osmo-ggsn           osmo-ggsn.cfg
app osmo-sip-connector  osmo-sip-connector.cfg

# ── Provisioning de l'abonne 1 dans le HLR (par la VTY, pas un service) ──────
say "provisioning HLR : IMSI=$IMSI MSISDN=$MSISDN"
for _ in $(seq 1 20); do
    ss -ltnH 2>/dev/null | grep -q "$HLR_VTY_IP:$HLR_VTY_PORT " && break
    sleep 0.5
done
{
    sleep 1
    printf 'enable\r\n'
    printf 'subscriber imsi %s create\r\n' "$IMSI"
    printf 'subscriber imsi %s update msisdn %s\r\n' "$IMSI" "$MSISDN"
    printf 'subscriber imsi %s update aud2g comp128v1 ki %s\r\n' "$IMSI" "$KI_HEX"
    printf 'show subscriber imsi %s\r\n' "$IMSI"
    sleep 2
} | telnet "$HLR_VTY_IP" "$HLR_VTY_PORT" >"$LOG_DIR/hlr-provision.log" 2>&1
if grep -q "$KI_HEX" "$LOG_DIR/hlr-provision.log"; then
    say "  abonne provisionne (Ki present)"
else
    say "  ECHEC provisioning - voir $LOG_DIR/hlr-provision.log"
fi

# ── La chaine DSP ────────────────────────────────────────────────────────────
# c54x_exe/run.sh porte DSP + qosmo (ARM+L1) + osmocon + mobile + pont_dsp.py.
# PONT_PY pointe sur le paquet pont/ de ce repo.
say "demarrage de la chaine DSP (MODE=dsp PONT=1)"
export MODE=dsp PONT=1
export PONT_PY="${PONT_PY:-$HERE/pont/pont_dsp.py}"
export OSMOCON="${OSMOCON:-$GSM_ROOT/osmocom-bb/src/host/osmocon/osmocon}"
export MOBILE="${MOBILE:-$(command -v mobile || echo /usr/local/bin/mobile)}"
export QOSMO="${QOSMO:-$GSM_ROOT/qosmo}"
# Config mobile FIGEE (ARFCN 514, tch-voice deja en io-handler l1phy). Elle est
# deja dans l'etat cible, donc on NE force PAS BANC_VOCODEUR=rom : la conversion
# gapk->l1phy de run.sh (config_vocodeur_rom) exigerait un bloc "io-handler
# gapk" et echouerait sur un fichier deja l1phy. BANC_VOCODEUR reste a "hote"
# (defaut de run.sh = aucune conversion) ; le vocodeur ROM du DSP est tenu par
# CALYPSO_VSP=1 (port voix modelise).
export MOBILE_CFG="${MOBILE_CFG:-/root/.osmocom/bb/mobile.cfg}"
export BANC_VOCODEUR="${BANC_VOCODEUR:-hote}"
export CALYPSO_VSP="${CALYPSO_VSP:-1}"
# Reglages du banc reel d'osmo-operator (c54x_exe/run_real.sh) : DSP au rythme de
# la BTS, une rafale TS0 par trame dans l'ordre des FN, livraison DMA/RIF.
export IQ="${IQ:-none}" INSNS="${INSNS:-60000}" LOCKSTEP="${LOCKSTEP:-1}"
export CALYPSO_RHEA_DMA_XFER="${CALYPSO_RHEA_DMA_XFER:-1}"
export CALYPSO_BSP_DIRECT_FEED="${CALYPSO_BSP_DIRECT_FEED:-1}"
export CALYPSO_BSP_STREAM="${CALYPSO_BSP_STREAM:-1}"
exec "$C54X/run.sh"
