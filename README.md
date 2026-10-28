# osmo-minioperator

Un opérateur GSM complet sur une seule machine, réduit à l'essentiel d'[osmo-operator](https://github.com/bbaranoff/osmo-operator) :
la pile réseau Osmocom (paquets `.deb` officiels), Asterisk, et un téléphone Calypso
émulé dont le **DSP TI C54x tourne hors QEMU** (`c54x_exe`, avec la vraie ROM).

**État : la chaîne marche jusqu'à la voix.** Le mobile s'attache (LOCATION UPDATING ACCEPT,
authentification COMP128 + chiffrement A5/1), passe un appel vers Asterisk, et la voix
descendante est décodée par le **vocodeur de la ROM du DSP**, puis restituée sur le port
voix du DSP (annonce « echo test » du 600 entendue sur la sortie haut-parleur du mobile).

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
| Rythme DSP | 120000 instructions/trame, LOCKSTEP=1, `CALYPSO_BSP_STREAM=1`, `CALYPSO_RHEA_DMA_XFER=1` |

Les drapeaux de l'émulateur C54x du profil « vocodeur ROM » d'osmo-operator
(`CALYPSO_MAC`, `CALYPSO_C54X_BCD_*`, `CALYPSO_C54X_OVM_LOGIQUE`, `CALYPSO_NORM_TC=0`…)
sont posés par `run-dsp.sh` : sans eux le port voix n'est jamais armé et l'appel est muet.

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
```

`docker-run.sh` monte le socket PulseAudio de l'hôte : **sans lui l'appel est muet**.
L'équivalent à la main :

```bash
sudo docker run -it --privileged -v /run/pulse/native:/run/pulse/native osmo-minioperator
```

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
| `INSNS` | 120000 | instructions DSP par trame (plus bas = LU plus rapide, voix non garantie) |
| `PONT_NOMTXPOWER` | 23 | puissance nominale renvoyée à osmo-bts-trx |
| `PULSE_SERVER` | `unix:/run/pulse/native` | serveur PulseAudio utilisé par le pont VSP |

## Contenu du dépôt

| Chemin | |
|---|---|
| `Dockerfile` | image : debs Osmocom + Asterisk, qosmo, c54x_exe, osmocom-bb, firmware |
| `install.sh` | même chose en natif |
| `run-dsp.sh` | lancement de l'opérateur en mode DSP |
| `start.sh` | entrypoint du conteneur |
| `docker-run.sh` | `docker run` avec l'audio de l'hôte |
| `configs/` | configs Osmocom et mobile figées ; `configs/asterisk/` |
| `pont/` | pont TRX ↔ DSP et pont audio VSP (repris d'osmo-operator) |
