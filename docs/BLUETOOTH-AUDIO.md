# Bluetooth audio and headset microphone (v4.1)

Files: `config/linux-rk35xx-vendor.config` (full kernel config, RFCOMM as a module;
`config/kernel-h96-max-v58.config` is the summary), plus under
`packages/bsp/h96-max-v58/`: `wireplumber/30-h96-bluetooth.conf`,
`modules-load.d/rfcomm.conf`, `systemd/h96-rfcomm.service`, `systemd/bt-sco-hci.service`.

## Microphone: why it needs a kernel change

HFP (Hands-Free) and HSP (Headset) profiles carry the microphone and run over
RFCOMM. Stock rockchip-rk3588 kernel builds core Bluetooth as a module but omits
RFCOMM, so BlueZ cannot open those profiles:

    socket(STREAM, RFCOMM): Protocol not supported

With no RFCOMM, a Bluetooth headset plays audio over A2DP but has no working mic,
and the audio stack pins the device to A2DP-only roles.

Fix: `CONFIG_BT_RFCOMM=m` + `CONFIG_BT_RFCOMM_TTY=y` in the kernel config. Armbian
then compiles `rfcomm.ko` into the kernel package with correct module dependencies;
`modules-load.d/rfcomm.conf` autoloads it at boot before BlueZ, and
`systemd/h96-rfcomm.service` runs `depmod` for the running kernel release (`uname -r`)
and loads `rfcomm` and `xpad` before `bluetooth.service`. HFP/HSP roles in
`wireplumber/30-h96-bluetooth.conf` then expose the mic as a `bluez_input` source
under a "Headset Head Unit" profile.

## SCO routing over HCI

HFP voice rides a SCO/eSCO link. On this Broadcom BCM4362A2 UART controller SCO
audio must be routed over HCI, set by vendor command 0xFC1C byte0=0x01 (Transport).
`bt-sco-hci.service` sends it after the adapter appears. Confirm current routing:

    hcitool -i hci0 cmd 0x3f 0x1d   # reply byte after status: 01 = HCI, 00 = PCM

## Codec: CVSD only

The mic works at CVSD (narrowband, call quality). Wideband mSBC negotiates at the
AT layer (headset sends AT+BAC=1,2; both agree AT+BCS=2) but its transparent-eSCO
transport will not establish over this chip's UART link, a Broadcom-UART limitation,
so `bluez5.enable-msbc = false`. Enabling mSBC removes the headset profile entirely
on this radio. Classic Bluetooth cannot run A2DP output and the mic at once;
selecting the mic profile drops output to mono call quality until deselected.

## A2DP output codecs, including AAC

`bluez5.codecs` prefers LDAC, aptX-HD, aptX, AAC, SBC-XQ, SBC. AAC needs the
`libspa-codec-bluez5-aac.so` plugin, shipped only in the `libspa-0.2-modules-extra`
package (FDK-AAC, split out of base PipeWire for licensing):

    sudo apt install libspa-0.2-modules-extra

LDAC needs libldacbt-abr2 / libldacbt-enc2; aptX and aptX-HD need libfreeaptx0.
All are open reimplementations, no vendor blob.

## Install (manual, on a running box)

    sudo install -m0644 wireplumber/30-h96-bluetooth.conf /etc/wireplumber/wireplumber.conf.d/
    sudo install -m0644 modules-load.d/rfcomm.conf /etc/modules-load.d/
    sudo install -m0644 systemd/h96-rfcomm.service /etc/systemd/system/
    sudo install -m0644 systemd/bt-sco-hci.service /etc/systemd/system/
    sudo systemctl enable h96-rfcomm.service bt-sco-hci.service
    sudo apt install libspa-0.2-modules-extra
    sudo modprobe rfcomm            # or reboot; needs CONFIG_BT_RFCOMM=m kernel
    systemctl --user restart wireplumber pipewire
