#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# verif.sh - verdict automatique de l'operateur en mode DSP :
#   1. (re)lance tout avec run-dsp.sh (sauf --no-restart)
#   2. attend le LOCATION UPDATING ACCEPT
#   3. N appels au 600 (echo Asterisk), pour chacun :
#        appel      : canal Asterisk Up
#        voix DL    : l'annonce d'Asterisk sort du vocodeur ROM sur gsm_audio
#        voix UL    : un 1 kHz injecte dans gsm_mic (micro du mobile) revient par l'echo
#   4. resume ; code de sortie 0 si tout est OK
#
#   ./verif.sh                     relance + 2 appels
#   ./verif.sh --appels 3          relance + 3 appels
#   ./verif.sh --no-restart        sur la pile deja lancee
#
# Les enregistrements de chaque appel restent dans /tmp/verif/ (s16le 8 kHz mono).
# Avec le PulseAudio de l'hote, l'annonce et le 1 kHz s'entendent dans les haut-parleurs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPELS=2 RESTART=1
while [ $# -gt 0 ]; do
    case "$1" in
        --appels) APPELS="$2"; shift ;;
        --no-restart) RESTART=0 ;;
        -h|--help) sed -n '4,17p' "$0"; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done
LOG_DIR="${LOG_DIR:-/run/osmo-minioperator/logs}"
MOBILE_LOG=/tmp/c54x-pont/mobile.log
LU_TIMEOUT="${LU_TIMEOUT:-300}"

say() { printf '\033[1m[verif]\033[0m %s\n' "$*"; }

if [ "$RESTART" = 1 ]; then
    say "lancement de la pile (run-dsp.sh) ..."
    "$HERE/run-dsp.sh" > "$LOG_DIR/../verif-run-dsp.log" 2>&1 || { say "ECHEC run-dsp.sh (voir $LOG_DIR/../verif-run-dsp.log)"; exit 1; }
fi
[ -r "$LOG_DIR/pulse_server" ] && export PULSE_SERVER="$(cat "$LOG_DIR/pulse_server")"
[ "${PULSE_SERVER:-}" = defaut ] && unset PULSE_SERVER

say "attente du LOCATION UPDATING ACCEPT (max ${LU_TIMEOUT}s) ..."
t=0
until grep -aq 'LOCATION UPDATING ACCEPT' "$MOBILE_LOG" 2>/dev/null; do
    [ "$t" -ge "$LU_TIMEOUT" ] && { say "ECHEC : pas de LU ACCEPT en ${LU_TIMEOUT}s"; exit 1; }
    sleep 2; t=$((t + 2))
done
say "LU ACCEPT ($([ "$RESTART" = 1 ] && echo "en ${t}s" || echo "deja obtenu"))"
# Apres le LU, le canal est libere et le mobile se recale sur la cellule : un
# appel lance dans la meme seconde voit son RACH ignore (cause 47).
[ "$RESTART" = 1 ] && { say "recalage du mobile apres le LU (20 s) ..."; sleep 20; }

exec python3 -I - "$APPELS" <<'PY'
import array, math, os, socket, subprocess, sys, time

APPELS = int(sys.argv[1])
DEST, VTY = "600", ("127.0.0.1", 4247)
TAUX, SEUIL_DL, SEUIL_TON = 8000, 300.0, 0.4
os.makedirs("/tmp/verif", exist_ok=True)

def dire(m): print(f"\033[1m[verif]\033[0m {m}", flush=True)

def vty(*cmds):
    with socket.create_connection(VTY, timeout=5) as s:
        time.sleep(0.3)
        for c in ("enable",) + cmds:
            s.sendall((c + "\r\n").encode()); time.sleep(0.3)

def canaux_up():
    r = subprocess.run(["asterisk", "-rx", "core show channels concise"], capture_output=True, text=True)
    return [l for l in r.stdout.splitlines() if "!Up!" in l]

def raccrocher():
    try: vty("hangup 1")
    except OSError: pass
    subprocess.run(["asterisk", "-rx", "channel request hangup all"], capture_output=True)
    for _ in range(20):
        if not canaux_up(): return
        time.sleep(0.5)

def lire(chemin, depuis=0):
    with open(chemin, "rb") as f:
        f.seek(depuis * 2); return array.array("h", f.read())

def rms(s): return math.sqrt(sum(x * x for x in s) / len(s)) if s else 0.0

def part_1k(s):
    """Part de l'energie a 1 kHz (Goertzel) dans le segment."""
    if not s: return 0.0
    k = 2 * math.cos(2 * math.pi * 1000 / TAUX); s1 = s2 = 0.0
    for x in s: s0 = x + k * s1 - s2; s2, s1 = s1, s0
    p = s1 * s1 + s2 * s2 - k * s1 * s2
    tot = sum(x * x for x in s)
    return (2 * p / len(s)) / tot if tot else 0.0

def ton(duree):
    n = int(duree * TAUX)
    return array.array("h", (int(8000 * math.sin(2 * math.pi * 1000 * i / TAUX)) for i in range(n))).tobytes()

def appel(i):
    raw = f"/tmp/verif/appel{i}.raw"
    rec = subprocess.Popen(["parec", "--device=gsm_audio.monitor", "--format=s16le", f"--rate={TAUX}",
                            "--channels=1", "--raw"], stdout=open(raw, "wb"))
    res = {"appel": False, "dl": 0.0, "ul": 0.0, "essais": 0}
    try:
        time.sleep(1)
        for essai in (1, 2):
            t0 = time.time()
            vty(f"call 1 {DEST}")
            while time.time() - t0 < 30 and not canaux_up(): time.sleep(0.5)
            if canaux_up(): break
            raccrocher(); time.sleep(10)
        res["essais"] = essai
        if not canaux_up():
            return res
        res["appel"] = True
        # annonce : attendre le debut (RMS > seuil) puis la fin (2 s calmes)
        debut = fin = None; pos = 0; t1 = time.time()
        while time.time() - t1 < 90:
            time.sleep(1)
            d = lire(raw)
            while pos + TAUX <= len(d):
                r = rms(d[pos:pos + TAUX]); res["dl"] = max(res["dl"], r)
                if debut is None and r > SEUIL_DL: debut = pos
                if debut is not None and r < SEUIL_DL / 3:
                    fin = fin if fin is not None else pos
                elif debut is not None:
                    fin = None
                pos += TAUX
            if fin is not None and pos - fin >= 2 * TAUX: break
        if debut is None:
            return res
        # echo : 4 s de 1 kHz dans le micro du mobile, on cherche le retour
        marque = len(lire(raw))
        subprocess.run(["pacat", "--playback", "--device=gsm_mic", "--format=s16le", f"--rate={TAUX}",
                        "--channels=1", "--raw"], input=ton(4.0))
        time.sleep(6)
        retour = lire(raw, marque)
        res["ul"] = max((part_1k(retour[p:p + TAUX]) for p in range(0, max(1, len(retour) - TAUX), TAUX // 2)),
                        default=0.0)
        return res
    finally:
        raccrocher(); rec.terminate(); rec.wait()

ok_total = True
for i in range(1, APPELS + 1):
    dire(f"appel {i}/{APPELS} vers {DEST} ...")
    r = appel(i)
    v_appel = r["appel"]; v_dl = r["dl"] > SEUIL_DL; v_ul = r["ul"] > SEUIL_TON
    ok = v_appel and v_dl and v_ul; ok_total &= ok
    dire(f"appel {i} : {'OK' if ok else 'ECHEC'}  | etabli {'oui' if v_appel else 'NON'}{' (2e tentative)' if r['essais'] == 2 else ''}"
         f" | voix DL {'oui' if v_dl else 'NON'} (RMS max {r['dl']:.0f})"
         f" | voix UL (echo 1 kHz) {'oui' if v_ul else 'NON'} (part 1 kHz {r['ul']:.2f})")
    time.sleep(3)
dire("VERDICT : " + ("OK - attachement, appels, voix descendante et montante" if ok_total else "ECHEC (voir ci-dessus)"))
sys.exit(0 if ok_total else 1)
PY
