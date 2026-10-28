# osmo-minioperator

Copyright (C) 2026 Bastien Baranoff — licence GNU GPL v3 ou ultérieure (voir [Licence](#licence-et-attributions)).

Un opérateur GSM complet sur une seule machine, réduit à l'essentiel d'[osmo-operator](https://github.com/bbaranoff/osmo-operator) :
la pile réseau Osmocom (paquets `.deb` officiels), Asterisk, et un téléphone Calypso
émulé dont le **DSP TI C54x tourne hors QEMU** (`c54x_exe`, avec la vraie ROM).

**État : la chaîne marche jusqu'à la voix, dans les deux sens.** Le mobile s'attache
(LOCATION UPDATING ACCEPT, authentification COMP128 + chiffrement A5/1) et appelle Asterisk.
La **voix descendante** est décodée par le vocodeur de la ROM du DSP et sort sur son port voix
(annonce « echo test » du 600) ; la **voix montante** est codée par la même ROM : un son
injecté dans le micro du mobile revient par l'écho du 600. Vérifié par `./verif.sh`
(3 appels sur 3, voir [Version vérifiée](#version-vérifiée)).

## Le mode : DSP, vocodeur ROM (l1phy)

| Élément | Choix |
|---|---|
| Couche physique du mobile | **mode DSP** : `c54x_exe` = TMS320C54x avec la mask-ROM TI (3606), hors QEMU |
| ARM + layer1 | `qosmo` (QEMU Calypso) exécute le firmware osmocom-bb `layer1.highram.elf` |
| Couches 2/3 du mobile | `mobile` d'osmocom-bb, relié au firmware par `osmocon` (L1CTL) |
| Voix | **vocodeur ROM** : `tch-voice io-handler l1phy` (pas de gapk) ; le DSP code et décode le FR |
| Port voix | SP0 modélisé (`CALYPSO_VSP=1`) ↔ `pont/vsp_audio.py` ↔ PulseAudio (`gsm_audio` / `gsm_mic`) |
| Données | `tch-data io-handler unix-sock`, format `ti` |
| Radio | BTS `osmo-bts-trx` ↔ `pont/pont_dsp.py` (TRXC/TRXD 5700-5702) ↔ BSP du DSP (UDP 6702) |
| Rythme DSP | 60000 instructions/trame, LOCKSTEP=1, `CALYPSO_BSP_STREAM=1`, `CALYPSO_RHEA_DMA_XFER=1` |

Les drapeaux de l'émulateur C54x du profil « vocodeur ROM » d'osmo-operator
(`CALYPSO_MAC`, `CALYPSO_C54X_BCD_*`, `CALYPSO_C54X_OVM_LOGIQUE`, `CALYPSO_NORM_TC=0`…)
sont posés par `run-dsp.sh` : sans eux le port voix n'est jamais armé et l'appel est muet.

La mask-ROM du DSP (version 3606) est le code de Texas Instruments publié en dump par le
projet FreeCalypso. Elle **n'est pas dans ce dépôt** : `c54x_exe/rom/fetch-rom.sh` la
télécharge au build et vérifie ses sommes SHA-256.

## L'opérateur (valeurs figées)

Un seul opérateur, plus de gabarits ni de moteur de substitution : tout est écrit en dur
dans `configs/`.

| | |
|---|---|
| PLMN | MCC 001, MNC 01, « OsmoQEMU » |
| Cellule | ARFCN **514** (DCS1800), BSIC 7, LAC 0x0001, CI 6001 |
| Abonné | IMSI 001010001000001, MSISDN **100101**, Ki `00112233445566778899aabbccdd0101` (COMP128v1) |
| Sécurité | A5/1 |
| SS7 | point codes MSC 1.1.1, STP 1.1.2, BSC 1.1.3 |

Asterisk (`configs/asterisk/`) :

| Numéro | Effet |
|---|---|
| 600 | test d'écho (annonce puis écho) |
| 700 | annonce « hello world » |
| 100 / 200 | softphones Linphone A / B (`linphone_A`/`tester`, `linphone_B`/`testerB`) |
| 1001XX | mobiles GSM de l'opérateur |

Les trunks SIP externes (Zadarma) d'osmo-operator ont été retirés.

## Docker

```bash
sudo docker build -t osmo-minioperator .
sudo ./docker-run.sh
./verif.sh              # dans le conteneur : verdict en une commande
```

`docker-run.sh` monte le socket PulseAudio de l'hôte : **sans lui on n'entend rien**
(la voix circule quand même dans un PulseAudio local, et `verif.sh` la mesure).
L'équivalent à la main :

```bash
sudo docker run -it --cap-add NET_ADMIN --cap-add SYS_NICE --device /dev/net/tun \
     -v /run/pulse/native:/run/pulse/native osmo-minioperator
```

Pas besoin de `--privileged` : `NET_ADMIN` et `/dev/net/tun` servent à osmo-ggsn (TUN),
`SYS_NICE` à la priorité temps réel du DSP.

L'entrée dans le conteneur donne un shell ; rien ne démarre tout seul.

## Natif (Ubuntu 24.04)

```bash
sudo bash install.sh
```

Installe les paquets, compile qosmo, c54x_exe et osmocom-bb (`make nofirmware` dans `src/`),
récupère le firmware et la ROM, puis pose les configs dans `/etc/osmocom`, `/etc/asterisk`
et `/root/.osmocom/bb/mobile.cfg`.

## Lancer

```bash
./run-dsp.sh            # lance tout
./run-dsp.sh --stop     # arrête tout
./run-dsp.sh --logs     # suit les journaux du cœur
```

Chaque composant est lancé **comme une application** (pas de service systemd) :
osmo-stp, osmo-hlr (+ provisioning de l'abonné), osmo-mgw, osmo-msc, osmo-bsc, osmo-sgsn,
osmo-ggsn, asterisk, osmo-sip-connector, puis la chaîne DSP (`c54x_exe/run.sh MODE=dsp PONT=1`),
et enfin osmo-bts-trx et osmo-pcu une fois le pont à l'écoute.

osmo-sgsn, osmo-ggsn et osmo-pcu sont lancés pour que la cellule soit la même que celle
d'osmo-operator (indicateur GPRS dans les System Information). **Le GPRS n'est pas
démontré** dans ce dépôt : seuls l'attachement GSM et les appels vocaux le sont.

### Verdict automatique

```bash
./verif.sh                  # relance tout, LU, puis 2 appels au 600
./verif.sh --appels 3       # 3 appels
./verif.sh --no-restart     # sur la pile déjà lancée
```

Pour chaque appel : canal établi côté Asterisk, **voix descendante** (l'annonce d'Asterisk
sort du vocodeur ROM sur `gsm_audio`), **voix montante** (un 1 kHz injecté dans `gsm_mic`,
le micro du mobile, revient par l'écho du 600). Code de sortie 0 si tout est bon ;
enregistrements dans `/tmp/verif/`.

Vérifier l'attachement (≈ 1 min) :

```bash
grep -c 'LOCATION UPDATING ACCEPT' /tmp/c54x-pont/mobile.log
```

Passer un appel vers l'écho :

```bash
telnet 127.0.0.1 4247        # VTY du mobile
enable
call 1 600
hangup 1
```

## Journaux

| Fichier | Contenu |
|---|---|
| `/run/osmo-minioperator/logs/*.log` | composants Osmocom, Asterisk, provisioning HLR |
| `/tmp/c54x-pont/mobile.log` | couches 2/3 du mobile |
| `/tmp/c54x-pont/dsp.log` | DSP (`[vsp]` : état du port voix, `[a_dd]` : trames vocales) |
| `/tmp/c54x-pont/vsp.log` | pont audio VSP ↔ PulseAudio |
| `/dev/shm/pont.log` | pont TRX (statistiques DL/UL/TCH) |

## Réglages utiles

| Variable | Défaut | Rôle |
|---|---|---|
| `INSNS` | 60000 | instructions DSP par trame. 120000 marche aussi sur une machine rapide ; sur un CPU plus lent le DSP décroche face à la BTS et le LU échoue |
| `PONT_NOMTXPOWER` | 23 | puissance nominale renvoyée à osmo-bts-trx |
| `PULSE_SERVER` | `unix:/run/pulse/native` | serveur PulseAudio utilisé par le pont VSP |

## Contenu du dépôt

| Chemin | |
|---|---|
| `Dockerfile` | image : debs Osmocom + Asterisk, qosmo, c54x_exe, osmocom-bb, firmware |
| `install.sh` | même chose en natif |
| `run-dsp.sh` | lancement de l'opérateur en mode DSP |
| `start.sh` | entrypoint du conteneur |
| `docker-run.sh` | `docker run` avec l'audio de l'hôte, sans `--privileged` |
| `verif.sh` | verdict automatique : LU + appels au 600, voix DL et UL |
| `configs/` | configs Osmocom et mobile figées ; `configs/asterisk/` |
| `pont/` | pont TRX ↔ DSP et pont audio VSP (repris d'osmo-operator) |

## Version vérifiée

**Commit fonctionnel : [`5a51fb0`](https://github.com/bbaranoff/osmo-minioperator/commit/5a51fb0)** — vérifié le **2026-10-28**.

Image reconstruite de zéro (`docker build -t osmo-minioperator . --no-cache`, ~3 min),
lancée avec l'audio de l'hôte (`./docker-run.sh`), puis `./verif.sh` :

```
[verif] appel 1 : OK  | etabli oui | voix DL oui (RMS max 8028) | voix UL (echo 1 kHz) oui (part 1 kHz 1.00)
[verif] appel 2 : OK  | etabli oui | voix DL oui (RMS max 5112) | voix UL (echo 1 kHz) oui (part 1 kHz 1.00)
[verif] VERDICT : OK - attachement, appels, voix descendante et montante
```

LU ACCEPT, 2 appels sur 2 vers le 600, voix descendante (vocodeur ROM sur `gsm_audio`)
et montante (1 kHz renvoyé par l'écho). Défaut `INSNS=60000` ; `INSNS=120000` passe
aussi sur cette machine, mais sur un CPU plus lent le DSP décroche et le LU échoue.
`install.sh` (natif) n'est pas couvert par cette vérification.

Les dépôts compilés au build sont figés par `git checkout` (Dockerfile et `install.sh`) :

| Dépôt | Commit |
|---|---|
| [qosmO](https://github.com/bbaranoff/qosmO) | `cc9c9c02ed0cab3b4eef7917062923df94e3809e` |
| [c54x_exe](https://github.com/bbaranoff/c54x_exe) | `0097a4be162733e0edf6cc2eab2db5110a12bfa4` |
| [firmware](https://github.com/bbaranoff/firmware) | `cb97f3f6a071726b52b6c7fd88f096b0d5bbfb48` |
| [osmocom-bb](https://gitea.osmocom.org/phone-side/osmocom-bb) | `eac4eed1eff1003517fbc3e48c360a525707c4ab` |

Les paquets viennent du dépôt `osmocom:latest`, qui évolue ; versions de la vérification :
osmo-stp 2.3.0, osmo-hlr 1.9.4, osmo-mgw 1.16.1, osmo-msc 1.16.0, osmo-bsc 1.15.0,
osmo-bts-trx 1.12.0, osmo-pcu 1.5.3, osmo-sip-connector 1.7.2, libosmocore 1.14.2,
Asterisk 20.6.0 (Ubuntu 24.04).

## Licence et attributions

**osmo-minioperator** — un opérateur GSM mono-machine : pile Osmocom, Asterisk et
téléphone Calypso émulé dont le DSP C54x tourne hors QEMU avec le vocodeur de sa ROM.

Copyright (C) 2026 Bastien Baranoff

Ce programme est un logiciel libre : vous pouvez le redistribuer et/ou le modifier
selon les termes de la GNU General Public License telle que publiée par la Free
Software Foundation, soit la version 3 de la licence, soit (à votre choix) toute
version ultérieure.

Ce programme est distribué dans l'espoir qu'il sera utile, mais SANS AUCUNE GARANTIE ;
sans même la garantie implicite de QUALITÉ MARCHANDE ou d'ADÉQUATION À UN USAGE
PARTICULIER. Voir la GNU General Public License pour plus de détails.

Vous devriez avoir reçu une copie de la GNU General Public License avec ce programme
(fichier [`LICENSE`](LICENSE)). Sinon, voir <https://www.gnu.org/licenses/>.

La GPLv3 couvre le contenu de ce dépôt : `Dockerfile`, scripts (`install.sh`,
`run-dsp.sh`, `start.sh`, `docker-run.sh`), `configs/` et `pont/`.

### Attributions

Les composants ci-dessous ne sont pas dans ce dépôt : ils sont installés (paquets) ou
récupérés et compilés au build. Chacun reste sous sa propre licence et à ses auteurs.

| Composant | Origine | Licence |
|---|---|---|
| `pont/`, gabarits de `configs/` | [osmo-operator](https://github.com/bbaranoff/osmo-operator), Bastien Baranoff | GPLv3 |
| qosmo (QEMU Calypso) | [bbaranoff/qosmO](https://github.com/bbaranoff/qosmO), Bastien Baranoff ; fork de [QEMU](https://www.qemu.org) | GPLv3 (ajouts) ; QEMU : GPLv2, voir `COPYING` |
| c54x_exe (DSP hors QEMU) | [bbaranoff/c54x_exe](https://github.com/bbaranoff/c54x_exe), Bastien Baranoff | GPLv3 |
| Firmware Calypso `layer1.highram.*` | [bbaranoff/firmware](https://github.com/bbaranoff/firmware), construit depuis osmocom-bb | GPLv2+ |
| osmocom-bb (`mobile`, `osmocon`) | [Osmocom](https://osmocom.org), phone-side/osmocom-bb | GPLv2+ |
| libosmocore, libosmo-gprs, osmo-pcu, osmo-ggsn | [Osmocom](https://osmocom.org) (paquets `.deb` officiels) | GPLv2+ |
| osmo-msc, osmo-bsc, osmo-bts, osmo-hlr, osmo-mgw, osmo-trx, osmo-sgsn, osmo-sip-connector | [Osmocom](https://osmocom.org) (paquets `.deb` officiels) | AGPLv3+ |
| osmo-stp (libosmo-sigtran) | [Osmocom](https://osmocom.org) (paquets `.deb` officiels) | voir le projet |
| Asterisk | [Sangoma / Asterisk](https://www.asterisk.org) (paquets Ubuntu) | GPLv2 |
| Mask-ROM du DSP Calypso (3606) | Texas Instruments ; dump publié par le projet [FreeCalypso](https://www.freecalypso.org) | code TI, **hors GPL** : non inclus dans ce dépôt, téléchargé au build par `rom/fetch-rom.sh` de c54x_exe |

Merci aux projets Osmocom, osmocom-bb, QEMU, FreeCalypso et Asterisk, sans lesquels
rien de tout ça ne tournerait.
