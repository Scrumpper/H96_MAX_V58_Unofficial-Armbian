#!/usr/bin/env python3
"""edid_modes.py — validate an EDID blob and pick the best mode for the H96 Max V58.

Sits between the ddc-edid-read GPIO bit-bang helper and h96-display:

    /usr/local/lib/h96/ddc-edid-read /dev/gpiochip4 15 16 \
        | python3 /usr/local/lib/h96/edid_modes.py -

stdout : exactly one kernel-style mode string, e.g. 3840x2160@30
         (this is what `h96-display auto` captures and feeds into the
          existing set-mode + one-boot-trial machinery)
stderr : a short human-readable report (monitor name, preferred timing,
         CEA-861 / audio capability, why this mode was chosen, warnings)

exit codes:
    0  valid EDID, mode printed
    2  EDID invalid (header/checksum/size/nonsense timing) — REFUSED,
       nothing printed on stdout, reason on stderr
    3  EDID valid but contains no mode this box can drive — REFUSED

Box limits (why the cap exists): the h96-display presets top out at
3840x2160@30 ("4k"), so `auto` must never pick anything hotter.  We cap on
pixel *rate* (w*h*hz <= 3840*2160*30), which also correctly forbids e.g.
4K@60 while still allowing 2560x1440@60 and 1920x1080@60.  A preferred
timing whose resolution fits but whose refresh is too high (typical 4K@60
TV) is down-capped to the highest common refresh that fits (-> 4K@30),
mirroring the "4k" preset.

Validation rules (see v4-planning research notes):
  - header must be 00 FF FF FF FF FF FF 00, base-block checksum must be 0
  - blob length must be a multiple of 128, >= 128
  - preferred-timing sanity: 640<=W<=7680, 480<=H<=4320, 23<=Hz<=121,
    25MHz<=pclk<=600MHz, Htotal>Hactive, Vtotal>Vactive
  - a bad *extension* checksum only voids that extension (many real TVs
    ship broken extension checksums; the video mode lives in the base
    block) unless --strict is given, in which case it refuses.
  - CEA-861 presence is reported because on this image HDMI audio needs a
    CEA block (v3.4 rule); its absence is a WARNING, not a refusal —
    DVI-style monitors should still get video.

Python 3.14 stdlib only.  No third-party imports — the target image has no
pip and no compiler.
"""

import argparse
import json
import sys

EDID_HEADER = bytes((0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00))
BLOCK = 128

# --- box capability cap (matches the h96-display "4k" preset ceiling) -------
MAX_W = 3840
MAX_H = 2160
MAX_PIXRATE = 3840 * 2160 * 30          # px/s — the "4k" preset's demand
COMMON_HZ = (120, 100, 60, 50, 30, 25, 24)   # down-cap ladder, best first

# --- sanity ranges for detailed timings (research doc, plus HDMI2.0 pclk) ---
SANE_W = (640, 7680)
SANE_H = (480, 4320)
SANE_HZ = (23.0, 121.0)
SANE_PCLK_KHZ = (25_000, 600_000)       # 25 MHz .. 600 MHz TMDS

# Established-timing bitmap, bytes 35..37 of the base block.
# (byte, bit, w, h, hz, interlaced)
ESTABLISHED = (
    (35, 7, 720, 400, 70, False), (35, 6, 720, 400, 88, False),
    (35, 5, 640, 480, 60, False), (35, 4, 640, 480, 67, False),
    (35, 3, 640, 480, 72, False), (35, 2, 640, 480, 75, False),
    (35, 1, 800, 600, 56, False), (35, 0, 800, 600, 60, False),
    (36, 7, 800, 600, 72, False), (36, 6, 800, 600, 75, False),
    (36, 5, 832, 624, 75, False), (36, 4, 1024, 768, 87, True),
    (36, 3, 1024, 768, 60, False), (36, 2, 1024, 768, 70, False),
    (36, 1, 1024, 768, 75, False), (36, 0, 1280, 1024, 75, False),
    (37, 7, 1152, 870, 75, False),
)


class EdidError(Exception):
    """Raised for anything that makes the EDID untrustworthy (exit 2)."""


class Mode:
    __slots__ = ("w", "h", "hz", "hz_exact", "pclk_khz", "interlaced", "source")

    def __init__(self, w, h, hz, source, hz_exact=None, pclk_khz=None,
                 interlaced=False):
        self.w, self.h, self.hz = w, h, hz
        self.hz_exact = hz_exact if hz_exact is not None else float(hz)
        self.pclk_khz = pclk_khz
        self.interlaced = interlaced
        self.source = source

    def __str__(self):
        return f"{self.w}x{self.h}@{self.hz}"

    @property
    def pixrate(self):
        return self.w * self.h * self.hz

    def as_dict(self):
        return {"mode": str(self), "w": self.w, "h": self.h, "hz": self.hz,
                "hz_exact": round(self.hz_exact, 3),
                "pclk_mhz": (self.pclk_khz / 1000.0) if self.pclk_khz else None,
                "interlaced": self.interlaced, "source": self.source}


def supported(m):
    """True if this box can be asked to drive the mode (see cap rationale)."""
    return (not m.interlaced and m.w <= MAX_W and m.h <= MAX_H
            and m.pixrate <= MAX_PIXRATE)


def sane_dtd(m):
    return (SANE_W[0] <= m.w <= SANE_W[1]
            and SANE_H[0] <= m.h <= SANE_H[1]
            and SANE_HZ[0] <= m.hz_exact <= SANE_HZ[1]
            and SANE_PCLK_KHZ[0] <= m.pclk_khz <= SANE_PCLK_KHZ[1])


# --------------------------------------------------------------------------
# input handling
# --------------------------------------------------------------------------
def read_blob(path):
    """Read raw EDID bytes; tolerate a hex-text dump (handy on the bench)."""
    if path == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(path, "rb") as f:
            data = f.read()
    if data[:8] == EDID_HEADER:
        return data
    # Not binary EDID — maybe someone piped in hex text (xxd -p / edid-decode).
    try:
        text = data.decode("ascii")
        cleaned = "".join(text.split())
        if cleaned and all(c in "0123456789abcdefABCDEF" for c in cleaned):
            return bytes.fromhex(cleaned)
    except (UnicodeDecodeError, ValueError):
        pass
    return data   # let validate() produce the real error message


def checksum_ok(block):
    return sum(block) % 256 == 0


def validate(data, strict, warn):
    """Return the list of trustworthy 128-byte blocks, or raise EdidError."""
    if len(data) < BLOCK:
        raise EdidError(f"blob is {len(data)} bytes; a base EDID block is 128")
    if len(data) % BLOCK != 0:
        raise EdidError(f"blob is {len(data)} bytes — not a multiple of 128 "
                        "(noisy/truncated DDC read)")
    base = data[:BLOCK]
    if base[:8] != EDID_HEADER:
        raise EdidError("bad EDID header (expected 00 FF FF FF FF FF FF 00) "
                        "— not an EDID, or the DDC read glitched")
    if not checksum_ok(base):
        raise EdidError("base-block checksum failed — corrupt read, refusing")

    declared = base[126]
    provided = len(data) // BLOCK - 1
    if provided != declared:
        warn(f"EDID declares {declared} extension block(s) but {provided} "
             "provided — using what we have")

    blocks = [base]
    for i in range(provided):
        ext = data[BLOCK * (i + 1):BLOCK * (i + 2)]
        if checksum_ok(ext):
            blocks.append(ext)
        elif strict:
            raise EdidError(f"extension block {i + 1} checksum failed (--strict)")
        else:
            warn(f"extension block {i + 1} checksum failed — ignoring it "
                 "(video mode comes from the base block; audio caps unknown)")
    return blocks


# --------------------------------------------------------------------------
# base-block parsing
# --------------------------------------------------------------------------
def parse_dtd(d, source):
    """Parse one 18-byte detailed timing descriptor; None if not a timing."""
    pclk_khz = (d[0] | (d[1] << 8)) * 10
    if pclk_khz == 0:
        return None                      # display descriptor, not a timing
    ha = d[2] | ((d[4] >> 4) << 8)
    hb = d[3] | ((d[4] & 0x0F) << 8)
    va = d[5] | ((d[7] >> 4) << 8)
    vb = d[6] | ((d[7] & 0x0F) << 8)
    ht, vt = ha + hb, va + vb
    if ha == 0 or va == 0 or ht <= ha or vt <= va:
        return None                      # degenerate blanking — nonsense
    hz_exact = (pclk_khz * 1000.0) / (ht * vt)
    return Mode(ha, va, round(hz_exact), source, hz_exact=hz_exact,
                pclk_khz=pclk_khz, interlaced=bool(d[17] & 0x80))


def monitor_name(base):
    for off in (54, 72, 90, 108):
        d = base[off:off + 18]
        if d[0:3] == b"\x00\x00\x00" and d[3] == 0xFC:
            return d[5:18].decode("ascii", "replace").strip("\n\r \x00\x20")
    return None


def established_modes(base):
    out = []
    for byte, bit, w, h, hz, ilace in ESTABLISHED:
        if base[byte] & (1 << bit):
            out.append(Mode(w, h, hz, "established", interlaced=ilace))
    return out


def standard_modes(base):
    # EDID < 1.3: aspect code 0 meant 1:1, not 16:10.
    old = (base[18], base[19]) < (1, 3)
    aspects = {0: (1, 1) if old else (16, 10), 1: (4, 3), 2: (5, 4), 3: (16, 9)}
    out = []
    for off in range(38, 54, 2):
        b1, b2 = base[off], base[off + 1]
        if (b1, b2) in ((0x01, 0x01), (0x00, 0x00)):
            continue                     # unused slot
        w = (b1 + 31) * 8
        num, den = aspects[b2 >> 6]
        h = (w * den) // num
        out.append(Mode(w, h, (b2 & 0x3F) + 60, "standard"))
    return out


def detailed_modes(base):
    out = []
    for i, off in enumerate((54, 72, 90, 108)):
        m = parse_dtd(base[off:off + 18], "preferred" if i == 0 else "detailed")
        if m:
            out.append(m)
    return out


def cea_info(blocks):
    """(has_cea, basic_audio, has_audio_block) from any CEA-861 extension."""
    for ext in blocks[1:]:
        if ext[0] != 0x02:
            continue
        version = ext[1]
        basic_audio = version >= 2 and bool(ext[3] & 0x40)
        has_adb = False
        dtd_off = ext[2]
        if 4 <= dtd_off <= BLOCK:
            i = 4
            while i < dtd_off:
                tag, length = (ext[i] >> 5) & 0x07, ext[i] & 0x1F
                if tag == 1:
                    has_adb = True
                i += 1 + length
        return True, basic_audio, has_adb
    return False, False, False


# --------------------------------------------------------------------------
# mode selection
# --------------------------------------------------------------------------
def downcap_hz(w, h, hz):
    """Highest common refresh <= hz that fits the box's pixel-rate cap."""
    for r in COMMON_HZ:
        if r <= hz and w * h * r <= MAX_PIXRATE:
            return r
    return None


def pick_mode(dtds, std, est, warn):
    """Return (Mode, reason) or (None, reason)."""
    preferred = dtds[0] if dtds and dtds[0].source == "preferred" else None

    if preferred is not None:
        if not sane_dtd(preferred):
            warn(f"preferred timing {preferred} "
                 f"(pclk {preferred.pclk_khz / 1000:.1f} MHz) fails sanity "
                 "ranges — skipping it")
        elif preferred.interlaced:
            warn(f"preferred timing {preferred} is interlaced — skipping it")
        elif supported(preferred):
            return preferred, "TV's preferred detailed timing"
        elif preferred.w <= MAX_W and preferred.h <= MAX_H:
            hz = downcap_hz(preferred.w, preferred.h, preferred.hz)
            if hz:
                capped = Mode(preferred.w, preferred.h, hz, "preferred-capped")
                return capped, (f"preferred {preferred} exceeds the box's "
                                f"pixel-rate ceiling; refresh capped to {hz}")
        else:
            warn(f"preferred timing {preferred} exceeds {MAX_W}x{MAX_H} — "
                 "falling back")

    # Fall back through every other advertised timing, biggest first.
    candidates = [m for m in (dtds[1:] if preferred else dtds) + std + est
                  if sane_or_listed(m) and supported(m)]
    candidates.sort(key=lambda m: (m.w * m.h, m.hz), reverse=True)
    seen, uniq = set(), []
    for m in candidates:
        if str(m) not in seen:
            seen.add(str(m))
            uniq.append(m)
    if uniq:
        return uniq[0], f"best supported fallback ({uniq[0].source} timing)"
    return None, "no advertised timing fits this box's limits"


def sane_or_listed(m):
    # Standard/established entries come from fixed tables — inherently sane.
    return sane_dtd(m) if m.pclk_khz is not None else True


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Validate an EDID blob and pick the best H96 Max V58 mode.")
    ap.add_argument("blob", nargs="?", default="-",
                    help="EDID file (raw or hex text); '-' = stdin (default)")
    ap.add_argument("--json", action="store_true",
                    help="emit a full machine-readable report on stdout")
    ap.add_argument("--strict", action="store_true",
                    help="refuse on bad extension checksums too")
    args = ap.parse_args(argv)

    warnings = []
    warn = warnings.append

    try:
        data = read_blob(args.blob)
        blocks = validate(data, args.strict, warn)
    except OSError as e:
        print(f"edid_modes: cannot read {args.blob}: {e}", file=sys.stderr)
        return 2
    except EdidError as e:
        for w in warnings:
            print(f"edid_modes: warning: {w}", file=sys.stderr)
        print(f"edid_modes: INVALID EDID: {e}", file=sys.stderr)
        return 2

    base = blocks[0]
    name = monitor_name(base)
    dtds = detailed_modes(base)
    std = standard_modes(base)
    est = established_modes(base)
    has_cea, basic_audio, audio_block = cea_info(blocks)

    chosen, reason = pick_mode(dtds, std, est, warn)

    if not has_cea:
        warn("no CEA-861 extension: HDMI audio will NOT work on this image "
             "(video is unaffected)")

    if args.json:
        print(json.dumps({
            "valid": True,
            "monitor": name,
            "extensions_declared": base[126],
            "extensions_used": len(blocks) - 1,
            "cea_extension": has_cea,
            "basic_audio": basic_audio,
            "audio_data_block": audio_block,
            "preferred": dtds[0].as_dict() if dtds else None,
            "detailed": [m.as_dict() for m in dtds],
            "standard": [m.as_dict() for m in std],
            "established": [m.as_dict() for m in est],
            "chosen": chosen.as_dict() if chosen else None,
            "reason": reason,
            "warnings": warnings,
        }, indent=2))
        return 0 if chosen else 3

    # Human report on stderr; the bare mode (the contract) on stdout.
    err = sys.stderr
    print(f"EDID: monitor {name!r}" if name else "EDID: (unnamed monitor)",
          file=err)
    if dtds:
        p = dtds[0]
        print(f"  preferred timing : {p} "
              f"(pclk {p.pclk_khz / 1000:.1f} MHz, {p.hz_exact:.2f} Hz)",
              file=err)
    print(f"  fallback timings : {len(dtds)} detailed, {len(std)} standard, "
          f"{len(est)} established", file=err)
    print(f"  CEA-861 extension: {'present' if has_cea else 'ABSENT'}"
          + (f", basic audio: {'yes' if basic_audio else 'no'}"
             f", audio data block: {'yes' if audio_block else 'no'}"
             if has_cea else ""), file=err)
    for w in warnings:
        print(f"  warning          : {w}", file=err)
    if chosen is None:
        print(f"edid_modes: REFUSED: {reason}", file=err)
        return 3
    print(f"  chosen mode      : {chosen}  ({reason})", file=err)
    print(chosen)
    return 0


if __name__ == "__main__":
    sys.exit(main())
