# Bluetooth audio and headset microphone (v4.1, reworked in v6.2)

Files: `config/linux-rk35xx-vendor.config` (full kernel config, RFCOMM as module;
`config/kernel-h96-max-v58.config` is summary), plus under
`packages/bsp/h96-max-v58/`: `wireplumber/30-h96-bluetooth.conf`,
`modules-load.d/rfcomm.conf`, `systemd/h96-rfcomm.service`, `systemd/bt-sco-hci.service`,
and since v6.2 `pipewire/95-h96-silence-source.conf`, `pipewire/90-h96-eq.conf`,
`bluetooth/h96-bt-policy.py`, `systemd/bluetooth.service.d/20-h96-policy.conf`,
`bluetooth/h96-bt-a2dp-heal.py`, `systemd/h96-bt-a2dp-heal.service`,
`tmpfiles.d/h96-eq.conf` and `etc-h96/eq/active.txt` (flat EQ file).

## Microphone: why it needs kernel change

HFP (Hands-Free) and HSP (Headset) profiles carry microphone and run over
RFCOMM. Stock rockchip-rk3588 kernel builds core Bluetooth as module but omits
RFCOMM, so BlueZ cannot open those profiles:

    socket(STREAM, RFCOMM): Protocol not supported

With no RFCOMM, Bluetooth headset plays audio over A2DP but has no working mic,
and audio stack pins device to A2DP-only roles.

Fix: `CONFIG_BT_RFCOMM=m` + `CONFIG_BT_RFCOMM_TTY=y` in kernel config. Armbian
then compiles `rfcomm.ko` into kernel package with correct module dependencies;
`modules-load.d/rfcomm.conf` autoloads it at boot ahead of BlueZ, and
`systemd/h96-rfcomm.service` runs `depmod` for running kernel release (`uname -r`)
and loads `rfcomm` and `xpad` before `bluetooth.service`. HFP/HSP roles in
`wireplumber/30-h96-bluetooth.conf` then expose mic as `bluez_input` source
under "Headset Head Unit" profile.

## SCO routing over HCI

HFP voice rides SCO/eSCO link. On this Broadcom BCM4362A2 UART controller SCO
audio must be routed over HCI, set by vendor command 0xFC1C byte0=0x01 (Transport).
`bt-sco-hci.service` sends it after adapter appears. Check current routing:

    hcitool -i hci0 cmd 0x3f 0x1d   # reply byte after status: 01 = HCI, 00 = PCM

## Microphone codec: mSBC, CVSD fallback

Mic runs mSBC (wideband, 16 kHz) on headsets that offer it, CVSD (narrowband) otherwise.
Controller advertises transparent SCO and eSCO, and mSBC carries over HCI UART at 3 Mbps
(measured: mSBC link active, voice packets flowing, test signal picked up). Earlier builds
kept mSBC off because enabling it removed headset profile; cause was `bluez5.codecs`
allow-list, which did not name HFP codecs PipeWire 1.6 loads as plugins. No allow-list
is in place now, so every Classic Bluetooth (A2DP and HFP) codec PipeWire has installed is
offered. LE Audio (BAP) roles are not offered.

Classic Bluetooth cannot run A2DP output and mic at once.
WirePlumber autoswitch is on (`bluetooth.autoswitch-to-headset-profile = true`,
since v6.2): headset mic is listed as input device at all times, headset
switches to Handsfree (mono call quality) while app records, and returns to
A2DP stereo when recording stops. `pipewire/95-h96-silence-source.conf` adds
"Silence (no microphone)" input, so KDE audio applet shows its input selector (hidden
with single input) and headset mic can be confirmed as default. Since 8.0 silence input
ranks above output monitors of non-pro sinks (HDMI included) and below Bluetooth mics and
non-pro capture devices 0 to 27, so it becomes input when headset mic leaves, not HDMI
output monitor. Card set to pro-audio profile outranks silence input with its output
monitor.

Bluetooth sinks force 2048-sample audio cycle while playing (`node.force-quantum`): at 512
samples encoder and h96 EQ filter chain miss deadlines (xruns), heard as choppy audio. They
also never suspend (`session.suspend-timeout-seconds = 0`), so headsets do not see idle
link and power off. `bluetooth/h96-bt-policy.py` (installed to `/usr/local/lib/h96/`,
run by `systemd/bluetooth.service.d/20-h96-policy.conf` ahead of bluetoothd) sets
`FastConnectable = true` and `ReconnectAttempts = 15` with intervals up to 60 s in
`/etc/bluetooth/main.conf`. `bluetooth/h96-bt-a2dp-heal.py` with
`systemd/h96-bt-a2dp-heal.service` reconnects headset A2DP link when it drops while
headset stays connected (many headsets close A2DP when WirePlumber restarts, and BlueZ
reconnects profiles only after full link loss). `tmpfiles.d/h96-eq.conf` restores flat
EQ file at boot if missing.

`/etc/h96/eq/active.txt` must exist (flat copy included since v6.2): PipeWire 1.6
stops h96 EQ filter chain without it, and failed node stalls WirePlumber, so
Bluetooth headsets get no audio device at all.

## A2DP output codecs, including AAC

No `bluez5.codecs` list: PipeWire offers LDAC, aptX HD, aptX, aptX LL, AAC, AAC-ELD, SBC-XQ,
SBC, FastStream and Opus, and picks best one headset supports. AAC needs
`libspa-codec-bluez5-aac.so` plugin, packaged only in `libspa-0.2-modules-extra`
package (FDK-AAC, split out of base PipeWire for licensing). Package is not in
image's offline repo; release image installs it through `h96-online-extras` once box
reaches network, and by hand it requires network too:

    sudo apt install libspa-0.2-modules-extra

LDAC needs libldacbt-abr2 / libldacbt-enc2; aptX and aptX-HD need libfreeaptx0.
All are open reimplementations, no vendor blob.

## 8.0 packages

On 8.0 images, `h96-audio` package installs Bluetooth audio files: `30-h96-bluetooth.conf`
in `/etc/wireplumber/wireplumber.conf.d/`, `rfcomm.conf` in `/etc/modules-load.d/`,
`h96-rfcomm.service` and `bt-sco-hci.service` in `/usr/lib/systemd/system/`,
`h96-bt-policy.py` in `/usr/lib/h96/` with `20-h96-policy.conf` drop-in for
`bluetooth.service`. v7.2 builder removed `h96-bt-a2dp-heal` and v6.2 EQ files
(`90-h96-eq.conf`, flat EQ restore through tmpfiles), and 8.0 does not bring them back.
Manual install below applies to v6.x sources in this repo, not to 8.0 images.

## Install (manual, on running box)

From `packages/bsp/h96-max-v58/`:

    sudo install -m0644 wireplumber/30-h96-bluetooth.conf /etc/wireplumber/wireplumber.conf.d/
    sudo install -m0644 pipewire/90-h96-eq.conf pipewire/95-h96-silence-source.conf /etc/pipewire/pipewire.conf.d/
    sudo install -d /etc/h96/eq /usr/local/lib/h96
    sudo install -m0644 etc-h96/eq/active.txt /etc/h96/eq/active.txt
    sudo install -m0644 etc-h96/eq/active.txt /usr/local/lib/h96/eq-active-flat.txt
    sudo install -m0644 tmpfiles.d/h96-eq.conf /etc/tmpfiles.d/
    sudo install -m0644 bluetooth/h96-bt-policy.py bluetooth/h96-bt-a2dp-heal.py /usr/local/lib/h96/
    sudo install -D -m0644 systemd/bluetooth.service.d/20-h96-policy.conf /etc/systemd/system/bluetooth.service.d/20-h96-policy.conf
    sudo install -m0644 modules-load.d/rfcomm.conf /etc/modules-load.d/
    sudo install -m0644 systemd/h96-rfcomm.service systemd/bt-sco-hci.service systemd/h96-bt-a2dp-heal.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable h96-rfcomm.service bt-sco-hci.service h96-bt-a2dp-heal.service
    sudo apt install libspa-0.2-modules-extra   # AAC; needs network
    sudo modprobe rfcomm            # or reboot; needs CONFIG_BT_RFCOMM=m kernel
    sudo systemctl restart bluetooth
    systemctl --user restart wireplumber pipewire
