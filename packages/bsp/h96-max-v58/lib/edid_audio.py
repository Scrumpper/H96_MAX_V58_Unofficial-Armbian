#!/usr/bin/env python3
"""H96 Max V58 HDMI detection: sink EDID over DDC -> kernel EDID (video + audio), layouts, codecs.

Installed as /usr/local/lib/h96/edid_audio.py (+ edid_merge.py); driven by
`h96-display detect` = `h96-audio-passthrough detect`.

Kernel sees only forced EDID (drm.edid_firmware), so sink capabilities are read over DDC
(adapter 'i2c-ddc', i2c-gpio on HDMI0 DDC pins). Output of `plan`:
  offer.json          layouts (stereo / 5.1 / 7.1), passthrough codecs, video summary,
                      physical address, display md5, notes
  report.txt          human-readable report
  h96-hdmi.conf       ACP profile set: one mapping per offered layout (KDE profile list)
  51-h96-iec958.conf  WirePlumber rule: iec958.codecs = PCM + offered passthrough codecs
  h96-sink-audio.bin  kernel EDID: display video (edid_merge.build: RGB 8-bit, modes within
                      clock ceiling) + sink audio blocks; --audio-only: forced EDID with sink
                      audio blocks (block 0, video blocks, DTDs byte-identical)
  sink-edid.bin       raw sink EDID as read (re-plan without second DDC read)

CLI:
  edid_audio.py plan --forced FILE --outdir DIR [--edid FILE | --bus N] [--codecs-off]
                     [--audio-only] [--hdmi20] [--safe]
  edid_audio.py phys-addr [--edid FILE | --bus N]   CTA HDMI VSDB physical address, a.b.c.d
  edid_audio.py FILE...          report for saved EDID file(s)
  edid_audio.py --ddc [BUS]      report for live sink (read-only i2c)
  edid_audio.py --selftest       audio + merge + plan cases
  edid_audio.py --help | -h      this text
Fallback: EDID unreadable/invalid or merge refused -> forced 1080p EDID, stereo LPCM only,
no passthrough.
"""
import argparse
import fcntl
import hashlib
import json
import os
import sys
import time

I2C_SLAVE = 0x0703
EDID_ADDR = 0x50
SEGMENT_ADDR = 0x30
HEADER = bytes([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0])

# CTA-861 audio format codes -> (name, PipeWire iec958 codec short name or None)
AFMT = {
    1: ("LPCM", "PCM"), 2: ("AC-3", "AC3"), 3: ("MPEG-1", "MPEG"), 4: ("MP3", "MPEG"),
    5: ("MPEG-2", "MPEG"), 6: ("AAC-LC", "MPEG2-AAC"), 7: ("DTS", "DTS"), 8: ("ATRAC", None),
    9: ("DSD", None), 10: ("E-AC-3", "EAC3"), 11: ("DTS-HD", "DTS-HD"), 12: ("MAT (TrueHD)", "TrueHD"),
    13: ("DST", None), 14: ("WMA Pro", None), 15: ("extended", None),
}
EXT_AFMT = {4: "MPEG-4 HE-AAC", 5: "MPEG-4 HE-AACv2", 6: "MPEG-4 AAC-LC", 7: "DRA",
            8: "MPEG-4 HE-AAC+MPS", 10: "MPEG-4 AAC-LC+MPS", 11: "MPEG-H 3D", 12: "AC-4",
            13: "L-PCM 3D"}
RATES = [32000, 44100, 48000, 88200, 96000, 176400, 192000]
# Speaker Allocation Data Block byte 0 (CTA-861) and hdmi-codec.c spk_alloc_bits
SPK_BITS = ["FL/FR", "LFE", "FC", "RL/RR", "RC", "FLC/FRC", "RLC/RRC", "FLW/FRW"]
_KSPK = {0: {"FL", "FR"}, 1: {"LFE"}, 2: {"FC"}, 3: {"RL", "RR"}, 4: {"RC"},
         5: {"FLC", "FRC"}, 6: {"RLC", "RRC"}}
# sound/soc/codecs/hdmi-codec.c hdmi_codec_channel_alloc[] (6.1.115-h96, table order matters)
KERNEL_CA = [
    (0x00, 2, "FL FR"), (0x01, 4, "FL FR LFE"), (0x02, 4, "FL FR FC"),
    (0x0b, 6, "FL FR LFE FC RL RR"), (0x08, 6, "FL FR RL RR"), (0x09, 6, "FL FR LFE RL RR"),
    (0x0a, 6, "FL FR FC RL RR"), (0x0f, 8, "FL FR LFE FC RL RR RC"),
    (0x13, 8, "FL FR LFE FC RL RR RLC RRC"), (0x03, 8, "FL FR LFE FC"), (0x04, 8, "FL FR RC"),
    (0x05, 8, "FL FR LFE RC"), (0x06, 8, "FL FR FC RC"), (0x07, 8, "FL FR LFE FC RC"),
    (0x0c, 8, "FL FR RC RL RR"), (0x0d, 8, "FL FR LFE RL RR RC"), (0x0e, 8, "FL FR FC RL RR RC"),
    (0x10, 8, "FL FR RL RR RLC RRC"), (0x11, 8, "FL FR LFE RL RR RLC RRC"),
    (0x12, 8, "FL FR FC RL RR RLC RRC"), (0x14, 8, "FL FR FLC FRC"), (0x15, 8, "FL FR LFE FLC FRC"),
    (0x16, 8, "FL FR FC FLC FRC"), (0x17, 8, "FL FR LFE FC FLC FRC"), (0x18, 8, "FL FR RC FLC FRC"),
    (0x19, 8, "FL FR LFE RC FLC FRC"), (0x1a, 8, "FL FR RC FC FLC FRC"),
    (0x1b, 8, "FL FR LFE RC FC FLC FRC"), (0x1c, 8, "FL FR RL RR FLC FRC"),
    (0x1d, 8, "FL FR LFE RL RR FLC FRC"), (0x1e, 8, "FL FR FC RL RR FLC FRC"),
    (0x1f, 8, "FL FR LFE FC RL RR FLC FRC"),
]
# Layouts exposed: (id, channels, required kernel CA, ACP mapping, description, mpv name,
# PipeWire channel-map in hdmi-codec slot order: driver does no reordering, slot = CEA order of CA)
LAYOUTS = [
    ("stereo", 2, 0x00, "hdmi-stereo", "Digital Stereo (HDMI)", "stereo",
     "front-left,front-right"),
    ("5.1", 6, 0x0b, "hdmi-surround", "Digital Surround 5.1 (HDMI)", "5.1",
     "front-left,front-right,lfe,front-center,rear-left,rear-right"),
    ("7.1", 8, 0x13, "hdmi-surround71", "Digital Surround 7.1 (HDMI)", "7.1",
     "front-left,front-right,lfe,front-center,side-left,side-right,rear-left,rear-right"),
]
# Passthrough enabled when sink lists it. TrueHD / DTS-HD need HBR (8ch 768 kHz IEC61937),
# unverified on dw-hdmi-qp: reported, not enabled. E-AC-3 needs 192 kHz IEC61937 frames.
PASSTHROUGH_OK = ("AC3", "DTS", "EAC3")


# ------------------------------------------------------------------ DDC
def find_ddc_bus():
    """i2c bus carrying HDMI-A-1 sink DDC.

    1. connector ddc link (/sys/class/drm/card*-HDMI-A-1/ddc), when driver sets connector->ddc
       (dw-hdmi-qp 6.1 BSP does not);
    2. adapter named 'i2c-ddc' (DT node /i2c-ddc, i2c-gpio on HDMI0 DDC pins: box image);
    3. adapter 'ddc' under the HDMI TX controller (fde80000.hdmi = HDMI0; defective on this box).
    """
    import glob
    for c in sorted(glob.glob("/sys/class/drm/card*-HDMI-A-1/ddc")):
        name = os.path.basename(os.path.realpath(c))
        if name.startswith("i2c-"):
            return int(name[4:])
    named = {}
    for a in glob.glob("/sys/bus/i2c/devices/i2c-*"):
        try:
            named[int(a.rsplit("-", 1)[1])] = (open(a + "/name").read().strip(),
                                               os.path.realpath(a))
        except (OSError, ValueError):
            pass
    for bus, (name, _) in sorted(named.items()):
        if name == "i2c-ddc":
            return bus
    for bus, (name, path) in sorted(named.items()):
        if name == "ddc" and "fde80000.hdmi" in path:
            return bus
    return None


def _read_block(fd, idx, chunk=16):
    """Read one 128-byte EDID block; offset write + chunked reads (short reads shift less)."""
    seg, off = idx // 2, (idx % 2) * 128
    if seg:
        fcntl.ioctl(fd, I2C_SLAVE, SEGMENT_ADDR)
        os.write(fd, bytes([seg]))
        fcntl.ioctl(fd, I2C_SLAVE, EDID_ADDR)
    out = bytearray()
    for o in range(off, off + 128, chunk):
        os.write(fd, bytes([o]))
        out += os.read(fd, chunk)
    return bytes(out)


def _block_ok(b, idx):
    if len(b) != 128 or sum(b) % 256:
        return False
    if idx == 0:
        return b[:8] == HEADER
    return b[0] in (0x02, 0x10, 0x40, 0x70, 0xF0)  # CTA, VTB, DI, DisplayID, block map


def _majority(cands):
    if not cands:
        return None
    return bytes(max(set(col), key=col.count) for col in zip(*cands))


def pick_block(cands, idx):
    """Choose one block from several reads: first read that validates, else byte majority
    (fixes a flipped bit or one shifted read when 2 of 3 agree), else None."""
    for c in cands:
        if _block_ok(c, idx):
            return c
    m = _majority([c for c in cands if len(c) == 128])
    return m if m is not None and _block_ok(m, idx) else None


def read_edid_ddc(bus, reads=3, retries=3, delay=0.15):
    """Read-only: 3 reads of each block, validated. Raises OSError/ValueError on failure."""
    fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE, EDID_ADDR)

        def get(idx):
            for _ in range(retries):
                cands = []
                for _ in range(reads):
                    try:
                        cands.append(_read_block(fd, idx))
                    except OSError:
                        pass
                    time.sleep(delay)
                b = pick_block(cands, idx)
                if b:
                    return b
            raise ValueError(f"EDID block {idx}: no valid read after {retries}x{reads}")

        b0 = get(0)
        out = b0
        for idx in range(1, min(b0[126], 3) + 1):
            out += get(idx)
        return out
    finally:
        os.close(fd)


# ------------------------------------------------------------------ parse
def _mfg(b0):
    v = (b0[8] << 8) | b0[9]
    return "".join(chr(((v >> s) & 0x1F) + 64) for s in (10, 5, 0))


def parse_edid(d):
    r = {"valid": False, "errors": [], "blocks": len(d) // 128}
    if len(d) < 128 or d[:8] != HEADER:
        r["errors"].append("no EDID header")
        return r
    for i in range(len(d) // 128):
        if sum(d[i * 128:(i + 1) * 128]) % 256:
            r["errors"].append(f"block {i} checksum")
    b0 = d[:128]
    r["vendor"] = _mfg(b0)
    r["product"] = b0[10] | (b0[11] << 8)
    r["name"] = ""
    for o in (54, 72, 90, 108):
        if b0[o:o + 3] == b"\0\0\0" and b0[o + 3] == 0xFC:
            r["name"] = b0[o + 5:o + 18].split(b"\n")[0].decode("ascii", "replace").strip()
    r.update(cta=False, hdmi=False, basic_audio=False, sads=[], spk_alloc=None, phys_addr=None)
    for i in range(1, len(d) // 128):
        c = d[i * 128:(i + 1) * 128]
        if c[0] != 0x02 or sum(c) % 256:
            continue
        r["cta"] = True
        r["cta_rev"] = c[1]
        r["basic_audio"] = bool(c[3] & 0x40)
        end = c[2] if 4 <= c[2] <= 127 else 4
        p = 4
        while p < end:
            tag, ln = c[p] >> 5, c[p] & 0x1F
            body = c[p + 1:p + 1 + ln]
            if tag == 1:
                for k in range(0, ln - ln % 3, 3):
                    r["sads"].append(_sad(body[k:k + 3]))
            elif tag == 4 and ln >= 1:
                r["spk_alloc"] = body[0]
                r["spk_alloc_ext"] = list(body[1:3])
            elif tag == 3 and ln >= 3 and body[:3] == b"\x03\x0c\x00":
                r["hdmi"] = True
                if len(body) >= 5:
                    r["phys_addr"] = "%d.%d.%d.%d" % (
                        body[3] >> 4, body[3] & 0xF, body[4] >> 4, body[4] & 0xF)
            p += 1 + ln
    r["valid"] = not r["errors"]
    return r


def _sad(s):
    code = (s[0] >> 3) & 0x0F
    x = {"code": code, "format": AFMT.get(code, ("reserved", None))[0],
         "iec958": AFMT.get(code, ("", None))[1], "channels": (s[0] & 7) + 1,
         "rates": [RATES[i] for i in range(7) if s[1] & (1 << i)], "raw": s.hex()}
    if code == 1:
        x["bits"] = [b for i, b in enumerate((16, 20, 24)) if s[2] & (1 << i)]
    elif 2 <= code <= 8:
        x["max_kbps"] = s[2] * 8
    elif code == 12:
        x["mat"] = "MAT 2.0 (Atmos)" if s[2] & 1 else "MAT 1.0 (TrueHD)"
    elif code == 10:
        x["joc"] = bool(s[2] & 1)
    elif code == 15:
        x["format"] = EXT_AFMT.get(s[2] >> 3, f"ext {s[2] >> 3}")
    return x


# ------------------------------------------------------------------ map
def kernel_ca(spk_alloc, channels):
    """Replicates hdmi_codec_get_ch_alloc_table_idx() (ELD bypass off)."""
    mask = set()
    for bit, names in _KSPK.items():
        if spk_alloc & (1 << bit):
            mask |= names
    for ca, n, need in KERNEL_CA:
        if not spk_alloc and ca == 0:
            return 0
        if n == channels and set(need.split()) <= mask:
            return ca
    return None


def derive_offer(p):
    """Map parsed EDID to what the box exposes. Unreadable/DVI/no audio -> stereo only."""
    off = {"source": "edid", "sink": p.get("name", ""), "layouts": ["stereo"], "codecs": ["PCM"],
           "not_enabled": [], "lpcm_max_channels": 2, "lpcm_rates": [32000, 44100, 48000],
           "notes": []}
    if not p.get("valid"):
        off["source"] = "fallback"
        off["notes"].append("EDID unreadable or invalid: stereo only")
        return off
    if not p.get("cta"):
        off["notes"].append("no CTA-861 block (DVI-style sink): stereo only")
        return off
    lpcm = [s for s in p["sads"] if s["code"] == 1]
    if lpcm:
        off["lpcm_max_channels"] = max(s["channels"] for s in lpcm)
        off["lpcm_rates"] = sorted({r for s in lpcm for r in s["rates"]})
    elif not p["basic_audio"]:
        off["notes"].append("sink lists no LPCM and no basic audio")
    spk = p["spk_alloc"]
    if spk is None:
        spk = 0x01
        off["notes"].append("no speaker allocation block: assume FL/FR")
    off["spk_alloc"] = spk
    off["speakers"] = [SPK_BITS[i] for i in range(8) if spk & (1 << i)]
    off["kernel_ca"] = {}
    for lid, ch, want_ca, *_ in LAYOUTS[1:]:
        ca = kernel_ca(spk, ch)
        off["kernel_ca"][lid] = None if ca is None else f"0x{ca:02x}"
        if off["lpcm_max_channels"] >= ch and ca == want_ca:
            off["layouts"].append(lid)
        elif off["lpcm_max_channels"] >= ch:
            off["notes"].append(f"{lid}: sink has {ch}ch LPCM but speaker map gives kernel CA "
                                f"{off['kernel_ca'][lid]} (need 0x{want_ca:02x}): not offered")
    rate192 = any(192000 in s["rates"] for s in lpcm)
    for s in p["sads"]:
        c = s["iec958"]
        if not c or c == "PCM" or c in off["codecs"] or c in off["not_enabled"]:
            continue
        if c == "EAC3" and not rate192:
            off["not_enabled"].append(c)
            off["notes"].append("E-AC-3 listed but no 192 kHz LPCM SAD: kernel ELD caps "
                                "IEC61937 frame rate below 192 kHz, not enabled")
        elif c in PASSTHROUGH_OK:
            off["codecs"].append(c)
        else:
            off["not_enabled"].append(c)
    return off


# ------------------------------------------------------------------ kernel EDID
def _dbc_blocks(cta):
    """Split CTA data block collection into [(tag, raw bytes)]."""
    d = cta[2] if 4 <= cta[2] <= 127 else 4
    out, i = [], 4
    while i < d:
        tag, ln = cta[i] >> 5, cta[i] & 0x1F
        out.append((tag, bytes(cta[i:i + 1 + ln])))
        i += 1 + ln
    return out


def kernel_sads(p, off):
    """SAD bytes for kernel ELD. hdmi-codec's ELD channel rule ignores SAD format, so a
    compressed SAD (e.g. AC-3 6ch) would widen LPCM channel range; clamp compressed SAD
    channel field to LPCM maximum so kernel constraint matches LPCM truth."""
    out = b""
    lmax = off["lpcm_max_channels"]
    for s in p["sads"][:10]:                  # ADB payload max 31 bytes
        raw = bytearray(bytes.fromhex(s["raw"]))
        if s["code"] != 1 and (raw[0] & 7) + 1 > lmax:
            raw[0] = (raw[0] & 0xF8) | (lmax - 1)
        out += bytes(raw)
    return out


def merge_audio_edid(forced, p, off):
    """Forced EDID with CTA Audio + Speaker Allocation blocks replaced by sink ones.
    Block 0, byte 3 flags, every non-audio data block and every DTD stay byte-identical.
    Fallback offer -> forced EDID returned unchanged."""
    if off["source"] != "edid" or not p.get("cta") or len(forced) < 256:
        return bytes(forced)
    cta = forced[128:256]
    if cta[0] != 0x02 or sum(cta) % 256:
        return bytes(forced)
    sads = kernel_sads(p, off)
    if not sads:
        return bytes(forced)
    adb = bytes([(1 << 5) | len(sads)]) + sads
    sadb = bytes([(4 << 5) | 3, off["spk_alloc"], 0, 0])
    dbc, placed = b"", False
    for tag, raw in _dbc_blocks(cta):
        if tag in (1, 4):
            if not placed:
                dbc += adb + sadb
                placed = True
            continue
        dbc += raw
    if not placed:
        dbc += adb + sadb
    d_old = cta[2]
    dtds = b""
    for o in range(d_old, 127 - 17, 18):
        if cta[o:o + 2] == b"\0\0":
            break
        dtds += cta[o:o + 18]
    if 4 + len(dbc) + len(dtds) > 127:
        raise ValueError("merged CTA block does not fit 128 bytes")
    b1 = bytearray(128)
    b1[0:4] = bytes([0x02, cta[1], 4 + len(dbc), cta[3]])
    b1[4:4 + len(dbc)] = dbc
    b1[4 + len(dbc):4 + len(dbc) + len(dtds)] = dtds
    b1[127] = (-sum(b1[:127])) & 0xFF
    out = bytes(forced[:128]) + bytes(b1) + bytes(forced[256:])
    assert sum(out[128:256]) % 256 == 0 and out[:128] == forced[:128]
    return out


# ------------------------------------------------------------------ generated config
def acp_profile_set(off):
    """ACP profile set listing only offered layouts (KDE card Profile list)."""
    out = ["# /etc/alsa-card-profile/mixer/profile-sets/h96-hdmi.conf",
           "# Generated by h96-audio-passthrough detect. Do not edit: next detect overwrites.",
           f"# Sink: '{off.get('sink', '')}' ({off['source']}). Mappings = layouts sink supports.",
           "# hdmi-codec does no reordering: channel-map = CEA slot order of kernel CA",
           "# (stereo 0x00, 5.1 0x0b, 7.1 0x13).",
           "", "[General]", "auto-profiles = yes", ""]
    for lid, ch, _, mapping, desc, _, cmap in LAYOUTS:
        if lid in off["layouts"]:
            out += [f"[Mapping {mapping}]", f"description = {desc}", "device-strings = hdmi:%f",
                    "paths-output = hdmi-output-0", f"channel-map = {cmap}",
                    f"priority = {10 - ch // 2}", "direction = output", ""]
    return "\n".join(out)


def wp_iec958_rule(off, codecs_off=False):
    # dw-hdmi-qp does not carry the IEC958 non-audio flag: a bitstream sent
    # over this HDMI path reaches the sink as PCM noise. PCM only, regardless
    # of what the sink lists, until a kernel fix lands (codecs_off kept for
    # CLI/caller compatibility; it changes nothing further now).
    listed = off["codecs"][1:]
    return f"""# /etc/wireplumber/wireplumber.conf.d/51-h96-iec958.conf
# Generated by h96-audio-passthrough detect. Do not edit: next detect overwrites.
# Sink: '{off.get('sink', '')}' ({off['source']}). Sink lists: {' '.join(listed) or 'none'}
# (passthrough not supported on this kernel: HDMI path sends it as PCM noise).
# PCM only; stereo and multichannel LPCM work.
# Matches HDMI-TX sink only (S/PDIF card is alsa_output.platform-spdif-tx0-sound.*).
monitor.alsa.rules = [
  {{
    matches = [ {{ node.name = "~alsa_output.platform-hdmi0-sound.*" }} ]
    actions = {{ update-props = {{ iec958.codecs = [ "PCM" ] }} }}
  }}
]
"""


def mpv_channels(off):
    names = [lay[5] for lay in LAYOUTS if lay[0] in off["layouts"]]
    return ",".join(reversed(names))


def report(p, o, label=""):
    L = [f"== {label}"]
    if p.get("vendor"):
        L.append(f"sink: {p['vendor']} product 0x{p['product']:04x} name '{p['name']}' "
                 f"blocks={p['blocks']} cta={p['cta']} hdmi_vsdb={p['hdmi']} "
                 f"basic_audio={p['basic_audio']}")
    for e in p.get("errors", []):
        L.append(f"ERROR: {e}")
    for s in p.get("sads", []):
        extra = (f" bits={s['bits']}" if "bits" in s else "") + \
                (f" max={s['max_kbps']}kbps" if "max_kbps" in s else "") + \
                (f" {s['mat']}" if "mat" in s else "") + \
                (f" joc={s['joc']}" if "joc" in s else "")
        L.append(f"  SAD {s['raw']}: {s['format']:<13} {s['channels']}ch "
                 f"{'/'.join(str(r // 1000) if r % 1000 == 0 else str(r / 1000) for r in s['rates'])} kHz{extra}")
    if p.get("spk_alloc") is not None:
        L.append(f"  speaker allocation 0x{p['spk_alloc']:02x}: " +
                 " ".join(SPK_BITS[i] for i in range(8) if p['spk_alloc'] & (1 << i)))
    L.append(f"layouts:     {' '.join(o['layouts'])}")
    pt_listed = " ".join(o["codecs"][1:])
    L.append(f"passthrough: {pt_listed + ' (not supported on this kernel: PCM only)' if pt_listed else 'none'}")
    if o["not_enabled"]:
        L.append(f"listed, not enabled: {' '.join(o['not_enabled'])}")
    if o.get("video") == "display":
        L.append(f"video:       display modes, preferred {o['preferred']}, ceiling "
                 f"{o['ceiling_khz'] // 1000} MHz{', hdmi20' if o['hdmi20'] else ''}"
                 f"{', FRL %dG (untested)' % o['frl_gbps'] if o.get('frl') else ''}"
                 f"{', colour ' + o['color'] if o.get('color', 'rgb') != 'rgb' else ''}"
                 f"{', safe (1080p60 first)' if o['safe'] else ''}")
        L.append(f"  modes:     {', '.join(o['modes'])}")
        for d in o["dropped"]:
            L.append(f"  removed:   {d}")
    elif o.get("video"):
        L.append("video:       forced 1920x1080@60 EDID")
    if o.get("phys_addr"):
        L.append(f"CEC physical address: {o['phys_addr']}")
    for n in o["notes"]:
        L.append(f"  note: {n}")
    return "\n".join(L)


def read_source(edid_file=None, bus=None):
    """-> (bytes, label). Empty bytes when unreadable."""
    if edid_file:
        try:
            return open(edid_file, "rb").read(), edid_file
        except OSError as e:
            return b"", f"{edid_file} ({e})"
    if bus is None:
        bus = find_ddc_bus()
    if bus is None:
        return b"", "DDC (no i2c-ddc bus)"
    try:
        return read_edid_ddc(bus), f"DDC i2c-{bus}"
    except (OSError, ValueError) as e:
        return b"", f"DDC i2c-{bus} ({e})"


def _merge_mod():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import edid_merge
    return edid_merge


def phys_addr_hex(pa):
    """'a.b.c.d' -> '0xABCD' (dw_hdmi_qp cec_phys_addr format); None when absent/malformed."""
    try:
        f = [int(x, 16) for x in pa.split(".")]
    except (AttributeError, ValueError):
        return None
    if len(f) != 4 or any(not 0 <= x <= 15 for x in f):
        return None
    return "0x%x%x%x%x" % tuple(f)


def plan_edid(data, p, o, forced, audio_only=False, hdmi20=False, safe=False):
    """-> (kernel EDID bytes, video dict). Display video merge unless audio_only; any
    refusal -> audio-only merge of forced EDID; any failure there -> forced + stereo."""
    em = _merge_mod()
    v = {"video": "forced", "preferred": "1920x1080@60", "hdmi20": False, "safe": False,
         "dropped": [], "display_md5": hashlib.md5(data).hexdigest() if data else None}
    if o["source"] == "edid" and not audio_only:
        try:
            sads = kernel_sads(p, o) if p.get("cta") else b""
            if sads:
                audio = (bytes([0x20 | len(sads)]) + sads, bytes([0x83, o["spk_alloc"], 0, 0]))
            else:
                audio = em.audio_blocks(em.find_cta(forced) or bytes(128))
                if None in audio:
                    raise ValueError("forced EDID lacks audio blocks")
                o["notes"].append("sink lists no audio blocks: forced stereo LPCM kept")
            merged, info = em.build(data, forced, audio, hdmi20, safe)
            pm = parse_edid(merged)
            acc = em.kernel_modes(merged)[0]
            if not pm["valid"] or not acc or (p.get("hdmi") and
                                              pm.get("phys_addr") != p.get("phys_addr")):
                raise ValueError("merged EDID failed validation")
            v.update(video="display", preferred=info["preferred_mode"], hdmi20=info["hdmi20"],
                     safe=info["safe"], dropped=info["dropped"], ceiling_khz=info["ceiling_khz"],
                     modes=[em.mode_str(m) for m in acc], frl=info.get("frl", False),
                     frl_gbps=info.get("frl_gbps", 0), color=info.get("color", "rgb"))
            o["notes"] += info["notes"]
            return merged, v
        except ValueError as e:
            o["notes"].append(f"display video merge refused ({e}): forced 1080p video")
    try:
        merged = merge_audio_edid(forced, p, o)
    except ValueError as e:
        o["notes"].append(f"kernel EDID merge failed ({e}): forced EDID kept, stereo only")
        o.update(layouts=["stereo"], codecs=["PCM"])
        merged = forced
    return merged, v


def cmd_plan(a):
    data, label = read_source(a.edid, a.bus)
    p = parse_edid(data)
    o = derive_offer(p)
    forced = open(a.forced, "rb").read()
    merged, v = plan_edid(data, p, o, forced, a.audio_only, a.hdmi20, a.safe)
    o.update(v)
    o["phys_addr"] = p.get("phys_addr") if o["source"] == "edid" else None
    o["display_key"] = _merge_mod().display_key(data) if data else None
    o["phys_addr_hex"] = phys_addr_hex(o["phys_addr"])
    o["kernel_edid_md5"] = hashlib.md5(merged).hexdigest()
    o["mpv_channels"] = mpv_channels(o)
    o["label"] = label
    os.makedirs(a.outdir, exist_ok=True)

    def put(name, content, mode="w"):
        with open(os.path.join(a.outdir, name), mode) as f:
            f.write(content)

    if data:
        put("sink-edid.bin", data, "wb")
    put("report.txt", report(p, o, label) + "\n")
    put("offer.json", json.dumps(o, indent=1, sort_keys=True) + "\n")
    put("h96-hdmi.conf", acp_profile_set(o))
    put("51-h96-iec958.conf", wp_iec958_rule(o, a.codecs_off))
    put("h96-sink-audio.bin", merged, "wb")
    print(report(p, o, label))
    return 0


# ------------------------------------------------------------------ tests
def _mk_edid(sads=b"", spk=None, basic=True, hdmi=True, name=b"TEST"):
    b0 = bytearray(128)
    b0[:8] = HEADER
    b0[8:10] = bytes([0x4D, 0xD9])            # SNY
    b0[18:20] = b"\x01\x03"
    b0[72:77] = b"\0\0\0\xFC\0"
    b0[77:90] = (name + b"\n").ljust(13, b" ")[:13]
    b0[126] = 1
    b0[127] = (-sum(b0[:127])) & 0xFF
    dbc = b""
    if sads:
        dbc += bytes([(1 << 5) | len(sads)]) + sads
    if spk is not None:
        dbc += bytes([(4 << 5) | 3, spk, 0, 0])
    if hdmi:
        dbc += bytes([(3 << 5) | 5, 0x03, 0x0C, 0x00, 0x10, 0x00])
    c = bytearray(128)
    c[0], c[1], c[2], c[3] = 0x02, 0x03, 4 + len(dbc), 0x40 if basic else 0
    c[4:4 + len(dbc)] = dbc
    c[127] = (-sum(c[:127])) & 0xFF
    return bytes(b0 + c)


def selftest():
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("PASS " if cond else "FAIL ") + msg)
        ok &= bool(cond)

    tv = _mk_edid(bytes.fromhex("090707" "1507" "50"), spk=0x01)
    o = derive_offer(parse_edid(tv))
    check(o["layouts"] == ["stereo"] and o["codecs"] == ["PCM", "AC3"], "TV: stereo + AC3 only")
    avr = _mk_edid(bytes.fromhex("0f7f07" "150750" "3d07c0" "570604" "5f7e01" "670301"), spk=0x4F)
    o = derive_offer(parse_edid(avr))
    check(o["layouts"] == ["stereo", "5.1", "7.1"], "AVR 7.1: all layouts")
    check(o["codecs"] == ["PCM", "AC3", "DTS", "EAC3"], "AVR: AC3 DTS EAC3 enabled")
    check(set(o["not_enabled"]) == {"DTS-HD", "TrueHD"}, "AVR: DTS-HD/TrueHD reported only")
    check('iec958.codecs = [ "PCM" ]' in wp_iec958_rule(o),
          "iec958 conf: PCM-only even though sink lists AC3/DTS/EAC3 (kernel path not fixed)")
    check('iec958.codecs = [ "PCM" ]' in wp_iec958_rule(o, codecs_off=True),
          "iec958 conf: PCM-only with codecs_off too")
    check(mpv_channels(o) == "7.1,5.1,stereo", "AVR: mpv channel list")
    eac48 = _mk_edid(bytes.fromhex("090707" "570604"), spk=0x01)
    o = derive_offer(parse_edid(eac48))
    check("EAC3" not in o["codecs"], "E-AC-3 without 192 kHz LPCM: not enabled")
    b51 = _mk_edid(bytes.fromhex("0f7f07"), spk=0x0F)
    o = derive_offer(parse_edid(b51))
    check(o["layouts"] == ["stereo", "5.1"], "8ch LPCM + 5.1 speakers: no 7.1 (kernel CA 0x03)")
    check(o["kernel_ca"]["7.1"] == "0x03", "kernel picks CA 0x03 for 8ch on 5.1 speakers")
    nospk = _mk_edid(bytes.fromhex("0f7f07"), spk=None)
    check(derive_offer(parse_edid(nospk))["layouts"] == ["stereo"], "no SADB: stereo only")
    check(derive_offer(parse_edid(b"\0" * 256))["source"] == "fallback", "garbage: fallback")
    dvi = _mk_edid(hdmi=False)[:128]
    dvi = dvi[:126] + b"\0" + bytes([(-sum(dvi[:126])) & 0xFF])
    check(derive_offer(parse_edid(dvi))["layouts"] == ["stereo"], "no CTA: stereo")
    blk = avr[128:]
    flip = bytearray(blk); flip[40] ^= 0x04
    shift = blk[1:] + b"\0"
    check(pick_block([bytes(flip), shift, blk], 1) == blk, "pick: clean read wins")
    flip2 = bytearray(blk); flip2[10] ^= 0x01
    check(pick_block([bytes(flip), bytes(flip2), blk[:]], 1) == blk, "pick: 3 reads majority")
    check(pick_block([bytes(flip), bytes(flip)], 1) is None, "pick: consistent corruption rejected")
    check(pick_block([shift, shift, shift], 1) is None, "pick: shifted block rejected")
    check(kernel_ca(0x01, 2) == 0 and kernel_ca(0x4F, 8) == 0x13 and kernel_ca(0x0F, 6) == 0x0b
          and kernel_ca(0x01, 6) is None and kernel_ca(0, 8) == 0, "kernel_ca table")
    # merge: forced-style EDID (VDB + ADB + SADB + VSDB + 1 DTD) keeps video bytes
    forced = bytearray(_mk_edid(bytes.fromhex("090707"), spk=0x01))
    dtd = bytes.fromhex("023a801871382d40582c4500c48e2100001e")
    d = forced[130]
    vdb = bytes([(2 << 5) | 2, 0x10, 0x04])
    cta = bytearray(128)
    body = vdb + bytes(forced[132:d + 128])
    cta[0:4] = bytes([0x02, 0x03, 4 + len(body), 0x41])
    cta[4:4 + len(body)] = body
    cta[4 + len(body):4 + len(body) + 18] = dtd
    cta[127] = (-sum(cta[:127])) & 0xFF
    forced = bytes(forced[:128]) + bytes(cta)
    pt = parse_edid(tv)
    m = merge_audio_edid(forced, pt, derive_offer(pt))
    pm = parse_edid(m)
    check(pm["valid"] and m[:128] == forced[:128], "merge: valid, block 0 identical")
    check([s["raw"] for s in pm["sads"]] == ["090707", "110750"],
          "merge: AC-3 6ch SAD clamped to LPCM max 2ch in kernel copy")
    check(m[128 + m[130]:128 + m[130] + 18] == dtd and m[131] == 0x41 and vdb in m[128:],
          "merge: DTD, byte-3 flags and VDB kept")
    pa = parse_edid(avr)
    ma = parse_edid(merge_audio_edid(forced, pa, derive_offer(pa)))
    check(ma["spk_alloc"] == 0x4F and ma["sads"][0]["channels"] == 8, "merge: AVR 8ch + 0x4F")
    fb = merge_audio_edid(forced, parse_edid(b""), derive_offer(parse_edid(b"")))
    check(fb == forced, "merge: fallback keeps forced EDID")
    # phys_addr: HDMI VSDB body = 03 0c 00 <A<<4|B> <C<<4|D>; port 2.0.0.0 -> 0x20
    port2 = _mk_edid(bytes.fromhex("090707"), spk=0x01)
    port2 = bytearray(port2)
    vsdb_off = port2.index(bytes.fromhex("030c00")) - 1  # tag/len byte precedes it
    port2[vsdb_off + 4] = 0x20
    port2[vsdb_off + 5] = 0x00
    c = port2[128:256]
    c[127] = 0
    c[127] = (-sum(c[:127])) & 0xFF
    port2[128:256] = c
    check(parse_edid(bytes(port2))["phys_addr"] == "2.0.0.0", "phys_addr: TV on input 2")
    check(phys_addr_hex("2.0.0.0") == "0x2000" and phys_addr_hex("1.2.3.f") == "0x123f"
          and phys_addr_hex(None) is None and phys_addr_hex("1.0.0") is None,
          "phys_addr_hex: a.b.c.d -> cec_phys_addr value")
    # display merge (edid_merge) + plan-level fallback
    em = _merge_mod()
    em.selftest(check)
    fz = em.sample_forced()
    sony = em.sample_sony()
    ps = parse_edid(sony)
    os_ = derive_offer(ps)
    m, v = plan_edid(sony, ps, os_, fz)
    pm = parse_edid(m)
    check(v["video"] == "display" and v["preferred"] == "1920x1080@60"
          and [s["raw"] for s in pm["sads"]] == ["090707", "110750"] and pm["phys_addr"] == "2.0.0.0",
          "plan sony: display video, stereo + AC-3 (clamped), PA 2.0.0.0")
    m, v = plan_edid(sony, ps, derive_offer(ps), fz, audio_only=True)
    check(v["video"] == "forced" and m[:128] == fz[:128], "plan audio-only: forced block 0")
    for label, bad in (("corrupt CTA", sony[:200] + bytes([sony[200] ^ 1]) + sony[201:]),
                       ("corrupt block 0", bytes(2) + sony[2:]), ("empty", b""),
                       ("short read", sony[:100])):
        pb = parse_edid(bad)
        ob = derive_offer(pb)
        m, v = plan_edid(bad, pb, ob, fz)
        check(m == fz and v["video"] == "forced" and ob["layouts"] == ["stereo"]
              and ob["codecs"] == ["PCM"], f"plan {label}: forced EDID, stereo, no passthrough")
    tv = em.sample_4k_tv()
    pt = parse_edid(tv)
    ot = derive_offer(pt)
    m, v = plan_edid(tv, pt, ot, fz)
    check(v["video"] == "display" and v["preferred"] == "3840x2160@30"
          and ot["layouts"] == ["stereo", "5.1", "7.1"] and parse_edid(m)["spk_alloc"] == 0x4F,
          "plan 4K TV: 4K30 preferred, sink audio kept (8ch LPCM)")
    return ok


def cmd_phys_addr(a):
    """Print the sink's CTA HDMI VSDB physical address as a.b.c.d. Exit 1 if unreadable
    or the sink has no HDMI VSDB (DVI-style sink): caller decides the fallback address."""
    data, label = read_source(a.edid, a.bus)
    p = parse_edid(data)
    if not p.get("valid") or not p.get("phys_addr"):
        err = "unreadable" if not p.get("valid") else "no HDMI VSDB"
        print(f"edid_audio.py: phys-addr: {label}: {err}", file=sys.stderr)
        return 1
    print(p["phys_addr"])
    return 0


def main(argv):
    # explicit --help/-h: usage only, never fall through to file-argument handling below
    if argv[1:2] and argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0
    if argv[1:2] == ["--selftest"]:
        return 0 if selftest() else 1
    if argv[1:2] == ["--ddc"]:
        data, label = read_source(None, int(argv[2]) if len(argv) > 2 else None)
        p = parse_edid(data)
        print(report(p, derive_offer(p), label))
        return 0
    if argv[1:2] == ["plan"]:
        ap = argparse.ArgumentParser(prog="edid_audio.py plan")
        ap.add_argument("--forced", required=True)
        ap.add_argument("--outdir", required=True)
        ap.add_argument("--edid")
        ap.add_argument("--bus", type=int)
        ap.add_argument("--codecs-off", action="store_true")
        ap.add_argument("--audio-only", action="store_true",
                        help="forced EDID video, sink audio only (autodetect off)")
        ap.add_argument("--hdmi20", action="store_true",
                        help="600 MHz ceiling + minimal HF-VSDB (SCDC scrambling via h96-scdc)")
        ap.add_argument("--safe", action="store_true", help="1920x1080@60 as preferred")
        return cmd_plan(ap.parse_args(argv[2:]))
    if argv[1:2] == ["phys-addr"]:
        ap = argparse.ArgumentParser(prog="edid_audio.py phys-addr")
        ap.add_argument("--edid")
        ap.add_argument("--bus", type=int)
        return cmd_phys_addr(ap.parse_args(argv[2:]))
    if len(argv) < 2:
        print(__doc__)
        return 2
    for f in argv[1:]:
        p = parse_edid(open(f, "rb").read())
        print(report(p, derive_offer(p), f))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
