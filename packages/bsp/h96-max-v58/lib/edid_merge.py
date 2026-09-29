#!/usr/bin/env python3
"""H96 Max V58 HDMI detect: one kernel EDID from connected display (video) + sink audio.

Installed as /usr/local/lib/h96/edid_merge.py; used by edid_audio.py `plan`
(driven by `h96-display detect` / `h96-audio-passthrough detect`).

Merged EDID = display block 0 + display CTA-861 block, rewritten so dw-hdmi-qp keeps
RGB 8-bit and only modes this box drives are listed:
  block 0   EDID 1.4 colour-encoding bits -> RGB only (colour setting); standard timings and
            DTDs above clock ceiling removed; range-limit max clock clamped; preferred = first
            kept DTD (display preferred above 600 MHz or ceiling -> same resolution, highest
            rate within it)
  CTA       YCbCr 4:4:4/4:2:2 bits cleared (colour setting); VDB VICs above ceiling removed;
            Audio + Speaker Allocation = sink audio (compressed SAD channel clamp,
            edid_audio.kernel_sads); HDMI VSDB kept (CEC physical address), deep colour
            cleared, Max TMDS clamped; HDMI Forum VSDB replaced (see tiers); HDR, colorimetry,
            Dolby Vision, other vendor blocks dropped; VCDB kept; DTDs above ceiling removed
  modes     interlaced and <= 25 MHz timings removed (bridge rejects <= 25 MHz)
  ceiling   340000 kHz without scrambling. hdmi20 (default on): HDMI20_KHZ + minimal
            HF-VSDB (SCDC_Present only); h96-scdc checks sink SCDC after each modeset.
  frl       (default on with hdmi20, off: FRL_OFF_FLAG) sink HF-VSDB Max_FRL_Rate > 0: modes
            above 600 MHz up to FRL_KHZ / FRL_MAX_W that fit sink FRL rate; HF-VSDB carries
            Max_FRL_Rate (no DSC, no deep colour). RGB where it fits (<= Y420_KHZ); else
            YCbCr 4:2:0 in a 4:2:0-only VDB when sink lists 4:2:0 for that VIC; else removed.
            Preferred stays <= 600 MHz. Untested on hardware.
  colour    COLOR_FLAG: rgb (default, YCbCr bits cleared) | ycbcr (4:4:4 kept) | auto
            (4:4:4 + 4:2:2 kept as sink lists them)
  safe      preferred forced to 1920x1080@60 (guard revert for unconfirmed display)
No CTA block in display EDID: display block 0 + forced CTA audio/VSDB (no forced video).
Same display + switches = same bytes (KDE keys display config by kernel EDID md5).

CLI:
  edid_merge.py modes FILE      timings EDID FILE lists, accepted / rejected by this kernel
  edid_merge.py merge DISPLAY FORCED OUT [--hdmi20] [--safe] [--frl on|off]
                [--color rgb|ycbcr|auto]    merge (stereo audio); unset switches = flag files
  edid_merge.py kscreen-carry OLD_MD5 NEW_MD5 [HOME...]   copy KDE display config to new EDID
  edid_merge.py --selftest
  edid_merge.py --help | -h
"""
import hashlib
import json
import os
import sys

MAX_KHZ = 340000          # dw-hdmi-qp without SCDC: HDMI 1.4 TMDS limit
HDMI20_KHZ = 600000       # HDMI 2.0 TMDS max; above = FRL (dw_hdmi-rockchip hdmi_select_link_config)
FRL_KHZ = 2376000         # VOP2 VP0 dclk_max 2.4 GHz; 8K60 CTA timing
FRL_MAX_W = 7680          # VOP2 VP0 max output width (VP0+VP1 splice above 4096)
Y420_KHZ = 1188000        # glue forces YCbCr 4:2:0 above this clock
FRL_GBPS = {1: 9, 2: 18, 3: 24, 4: 32, 5: 40, 6: 48}   # HF-VSDB Max_FRL_Rate -> Gbit/s
FRL_OFF_FLAG = "/etc/h96/display-frl.off"
COLOR_FLAG = "/etc/h96/display-color"                    # legacy global, read until migrated
DISPLAY_DIR = "/etc/h96/display"                        # per display: <display_key>.conf color= range=
COLORS = {"rgb": 0x00, "ycbcr": 0x20, "auto": 0x30}      # CTA byte 3 YCbCr bits kept
MIN_KHZ = 25001           # dw_hdmi_qp_bridge_mode_valid: clock <= 25000 -> MODE_CLOCK_RANGE
SAFE_MODE = (1920, 1080, 60)
HEADER = bytes([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0])
OUI_HDMI = b"\x03\x0c\x00"
OUI_HF = b"\xd8\x5d\xc4"
DUMMY_DESC = bytes([0, 0, 0, 0x10]) + bytes(14)
# established timings I/II/manufacturer, EDID byte 35 bit 7 first: (w, h, hz, kHz)
EST = [(720, 400, 70, 28320), (720, 400, 88, 35500), (640, 480, 60, 25175),
       (640, 480, 67, 30240), (640, 480, 72, 31500), (640, 480, 75, 31500),
       (800, 600, 56, 36000), (800, 600, 60, 40000), (800, 600, 72, 50000),
       (800, 600, 75, 49500), (832, 624, 75, 57284), (1024, 768, 87, 44900),
       (1024, 768, 60, 65000), (1024, 768, 70, 75000), (1024, 768, 75, 78750),
       (1280, 1024, 75, 135000), (1152, 870, 75, 100000)]
# HDMI VSDB HDMI_VIC 1-4 (drm_edid.c edid_4k_modes)
HDMI_VIC = {1: (297000, 3840, 2160, 30), 2: (297000, 3840, 2160, 25),
            3: (297000, 3840, 2160, 24), 4: (297000, 4096, 2160, 24)}

# CTA-861 VIC -> (kHz, h, hss, hse, htot, v, vss, vse, vtot, flags 1=interlace 2=+hsync
# 4=+vsync 8=dblclk); from drm_edid.c edid_cea_modes_1/_193 (6.1.115-h96)
CEA_VIC = {
    1: (25175, 640, 656, 752, 800, 480, 490, 492, 525, 0),
    2: (27000, 720, 736, 798, 858, 480, 489, 495, 525, 0),
    3: (27000, 720, 736, 798, 858, 480, 489, 495, 525, 0),
    4: (74250, 1280, 1390, 1430, 1650, 720, 725, 730, 750, 6),
    5: (74250, 1920, 2008, 2052, 2200, 1080, 1084, 1094, 1125, 7),
    6: (13500, 720, 739, 801, 858, 480, 488, 494, 525, 9),
    7: (13500, 720, 739, 801, 858, 480, 488, 494, 525, 9),
    8: (13500, 720, 739, 801, 858, 240, 244, 247, 262, 8),
    9: (13500, 720, 739, 801, 858, 240, 244, 247, 262, 8),
    10: (54000, 2880, 2956, 3204, 3432, 480, 488, 494, 525, 1),
    11: (54000, 2880, 2956, 3204, 3432, 480, 488, 494, 525, 1),
    12: (54000, 2880, 2956, 3204, 3432, 240, 244, 247, 262, 0),
    13: (54000, 2880, 2956, 3204, 3432, 240, 244, 247, 262, 0),
    14: (54000, 1440, 1472, 1596, 1716, 480, 489, 495, 525, 0),
    15: (54000, 1440, 1472, 1596, 1716, 480, 489, 495, 525, 0),
    16: (148500, 1920, 2008, 2052, 2200, 1080, 1084, 1089, 1125, 6),
    17: (27000, 720, 732, 796, 864, 576, 581, 586, 625, 0),
    18: (27000, 720, 732, 796, 864, 576, 581, 586, 625, 0),
    19: (74250, 1280, 1720, 1760, 1980, 720, 725, 730, 750, 6),
    20: (74250, 1920, 2448, 2492, 2640, 1080, 1084, 1094, 1125, 7),
    21: (13500, 720, 732, 795, 864, 576, 580, 586, 625, 9),
    22: (13500, 720, 732, 795, 864, 576, 580, 586, 625, 9),
    23: (13500, 720, 732, 795, 864, 288, 290, 293, 312, 8),
    24: (13500, 720, 732, 795, 864, 288, 290, 293, 312, 8),
    25: (54000, 2880, 2928, 3180, 3456, 576, 580, 586, 625, 1),
    26: (54000, 2880, 2928, 3180, 3456, 576, 580, 586, 625, 1),
    27: (54000, 2880, 2928, 3180, 3456, 288, 290, 293, 312, 0),
    28: (54000, 2880, 2928, 3180, 3456, 288, 290, 293, 312, 0),
    29: (54000, 1440, 1464, 1592, 1728, 576, 581, 586, 625, 0),
    30: (54000, 1440, 1464, 1592, 1728, 576, 581, 586, 625, 0),
    31: (148500, 1920, 2448, 2492, 2640, 1080, 1084, 1089, 1125, 6),
    32: (74250, 1920, 2558, 2602, 2750, 1080, 1084, 1089, 1125, 6),
    33: (74250, 1920, 2448, 2492, 2640, 1080, 1084, 1089, 1125, 6),
    34: (74250, 1920, 2008, 2052, 2200, 1080, 1084, 1089, 1125, 6),
    35: (108000, 2880, 2944, 3192, 3432, 480, 489, 495, 525, 0),
    36: (108000, 2880, 2944, 3192, 3432, 480, 489, 495, 525, 0),
    37: (108000, 2880, 2928, 3184, 3456, 576, 581, 586, 625, 0),
    38: (108000, 2880, 2928, 3184, 3456, 576, 581, 586, 625, 0),
    39: (72000, 1920, 1952, 2120, 2304, 1080, 1126, 1136, 1250, 3),
    40: (148500, 1920, 2448, 2492, 2640, 1080, 1084, 1094, 1125, 7),
    41: (148500, 1280, 1720, 1760, 1980, 720, 725, 730, 750, 6),
    42: (54000, 720, 732, 796, 864, 576, 581, 586, 625, 0),
    43: (54000, 720, 732, 796, 864, 576, 581, 586, 625, 0),
    44: (27000, 720, 732, 795, 864, 576, 580, 586, 625, 9),
    45: (27000, 720, 732, 795, 864, 576, 580, 586, 625, 9),
    46: (148500, 1920, 2008, 2052, 2200, 1080, 1084, 1094, 1125, 7),
    47: (148500, 1280, 1390, 1430, 1650, 720, 725, 730, 750, 6),
    48: (54000, 720, 736, 798, 858, 480, 489, 495, 525, 0),
    49: (54000, 720, 736, 798, 858, 480, 489, 495, 525, 0),
    50: (27000, 720, 739, 801, 858, 480, 488, 494, 525, 9),
    51: (27000, 720, 739, 801, 858, 480, 488, 494, 525, 9),
    52: (108000, 720, 732, 796, 864, 576, 581, 586, 625, 0),
    53: (108000, 720, 732, 796, 864, 576, 581, 586, 625, 0),
    54: (54000, 720, 732, 795, 864, 576, 580, 586, 625, 9),
    55: (54000, 720, 732, 795, 864, 576, 580, 586, 625, 9),
    56: (108000, 720, 736, 798, 858, 480, 489, 495, 525, 0),
    57: (108000, 720, 736, 798, 858, 480, 489, 495, 525, 0),
    58: (54000, 720, 739, 801, 858, 480, 488, 494, 525, 9),
    59: (54000, 720, 739, 801, 858, 480, 488, 494, 525, 9),
    60: (59400, 1280, 3040, 3080, 3300, 720, 725, 730, 750, 6),
    61: (74250, 1280, 3700, 3740, 3960, 720, 725, 730, 750, 6),
    62: (74250, 1280, 3040, 3080, 3300, 720, 725, 730, 750, 6),
    63: (297000, 1920, 2008, 2052, 2200, 1080, 1084, 1089, 1125, 6),
    64: (297000, 1920, 2448, 2492, 2640, 1080, 1084, 1089, 1125, 6),
    65: (59400, 1280, 3040, 3080, 3300, 720, 725, 730, 750, 6),
    66: (74250, 1280, 3700, 3740, 3960, 720, 725, 730, 750, 6),
    67: (74250, 1280, 3040, 3080, 3300, 720, 725, 730, 750, 6),
    68: (74250, 1280, 1720, 1760, 1980, 720, 725, 730, 750, 6),
    69: (74250, 1280, 1390, 1430, 1650, 720, 725, 730, 750, 6),
    70: (148500, 1280, 1720, 1760, 1980, 720, 725, 730, 750, 6),
    71: (148500, 1280, 1390, 1430, 1650, 720, 725, 730, 750, 6),
    72: (74250, 1920, 2558, 2602, 2750, 1080, 1084, 1089, 1125, 6),
    73: (74250, 1920, 2448, 2492, 2640, 1080, 1084, 1089, 1125, 6),
    74: (74250, 1920, 2008, 2052, 2200, 1080, 1084, 1089, 1125, 6),
    75: (148500, 1920, 2448, 2492, 2640, 1080, 1084, 1089, 1125, 6),
    76: (148500, 1920, 2008, 2052, 2200, 1080, 1084, 1089, 1125, 6),
    77: (297000, 1920, 2448, 2492, 2640, 1080, 1084, 1089, 1125, 6),
    78: (297000, 1920, 2008, 2052, 2200, 1080, 1084, 1089, 1125, 6),
    79: (59400, 1680, 3040, 3080, 3300, 720, 725, 730, 750, 6),
    80: (59400, 1680, 2908, 2948, 3168, 720, 725, 730, 750, 6),
    81: (59400, 1680, 2380, 2420, 2640, 720, 725, 730, 750, 6),
    82: (82500, 1680, 1940, 1980, 2200, 720, 725, 730, 750, 6),
    83: (99000, 1680, 1940, 1980, 2200, 720, 725, 730, 750, 6),
    84: (165000, 1680, 1740, 1780, 2000, 720, 725, 730, 825, 6),
    85: (198000, 1680, 1740, 1780, 2000, 720, 725, 730, 825, 6),
    86: (99000, 2560, 3558, 3602, 3750, 1080, 1084, 1089, 1100, 6),
    87: (90000, 2560, 3008, 3052, 3200, 1080, 1084, 1089, 1125, 6),
    88: (118800, 2560, 3328, 3372, 3520, 1080, 1084, 1089, 1125, 6),
    89: (185625, 2560, 3108, 3152, 3300, 1080, 1084, 1089, 1125, 6),
    90: (198000, 2560, 2808, 2852, 3000, 1080, 1084, 1089, 1100, 6),
    91: (371250, 2560, 2778, 2822, 2970, 1080, 1084, 1089, 1250, 6),
    92: (495000, 2560, 3108, 3152, 3300, 1080, 1084, 1089, 1250, 6),
    93: (297000, 3840, 5116, 5204, 5500, 2160, 2168, 2178, 2250, 6),
    94: (297000, 3840, 4896, 4984, 5280, 2160, 2168, 2178, 2250, 6),
    95: (297000, 3840, 4016, 4104, 4400, 2160, 2168, 2178, 2250, 6),
    96: (594000, 3840, 4896, 4984, 5280, 2160, 2168, 2178, 2250, 6),
    97: (594000, 3840, 4016, 4104, 4400, 2160, 2168, 2178, 2250, 6),
    98: (297000, 4096, 5116, 5204, 5500, 2160, 2168, 2178, 2250, 6),
    99: (297000, 4096, 5064, 5152, 5280, 2160, 2168, 2178, 2250, 6),
    100: (297000, 4096, 4184, 4272, 4400, 2160, 2168, 2178, 2250, 6),
    101: (594000, 4096, 5064, 5152, 5280, 2160, 2168, 2178, 2250, 6),
    102: (594000, 4096, 4184, 4272, 4400, 2160, 2168, 2178, 2250, 6),
    103: (297000, 3840, 5116, 5204, 5500, 2160, 2168, 2178, 2250, 6),
    104: (297000, 3840, 4896, 4984, 5280, 2160, 2168, 2178, 2250, 6),
    105: (297000, 3840, 4016, 4104, 4400, 2160, 2168, 2178, 2250, 6),
    106: (594000, 3840, 4896, 4984, 5280, 2160, 2168, 2178, 2250, 6),
    107: (594000, 3840, 4016, 4104, 4400, 2160, 2168, 2178, 2250, 6),
    108: (90000, 1280, 2240, 2280, 2500, 720, 725, 730, 750, 6),
    109: (90000, 1280, 2240, 2280, 2500, 720, 725, 730, 750, 6),
    110: (99000, 1680, 2490, 2530, 2750, 720, 725, 730, 750, 6),
    111: (148500, 1920, 2558, 2602, 2750, 1080, 1084, 1089, 1125, 6),
    112: (148500, 1920, 2558, 2602, 2750, 1080, 1084, 1089, 1125, 6),
    113: (198000, 2560, 3558, 3602, 3750, 1080, 1084, 1089, 1100, 6),
    114: (594000, 3840, 5116, 5204, 5500, 2160, 2168, 2178, 2250, 6),
    115: (594000, 4096, 5116, 5204, 5500, 2160, 2168, 2178, 2250, 6),
    116: (594000, 3840, 5116, 5204, 5500, 2160, 2168, 2178, 2250, 6),
    117: (1188000, 3840, 4896, 4984, 5280, 2160, 2168, 2178, 2250, 6),
    118: (1188000, 3840, 4016, 4104, 4400, 2160, 2168, 2178, 2250, 6),
    119: (1188000, 3840, 4896, 4984, 5280, 2160, 2168, 2178, 2250, 6),
    120: (1188000, 3840, 4016, 4104, 4400, 2160, 2168, 2178, 2250, 6),
    121: (396000, 5120, 7116, 7204, 7500, 2160, 2168, 2178, 2200, 6),
    122: (396000, 5120, 6816, 6904, 7200, 2160, 2168, 2178, 2200, 6),
    123: (396000, 5120, 5784, 5872, 6000, 2160, 2168, 2178, 2200, 6),
    124: (742500, 5120, 5866, 5954, 6250, 2160, 2168, 2178, 2475, 6),
    125: (742500, 5120, 6216, 6304, 6600, 2160, 2168, 2178, 2250, 6),
    126: (742500, 5120, 5284, 5372, 5500, 2160, 2168, 2178, 2250, 6),
    127: (1485000, 5120, 6216, 6304, 6600, 2160, 2168, 2178, 2250, 6),
    193: (1485000, 5120, 5284, 5372, 5500, 2160, 2168, 2178, 2250, 6),
    194: (1188000, 7680, 10232, 10408, 11000, 4320, 4336, 4356, 4500, 6),
    195: (1188000, 7680, 10032, 10208, 10800, 4320, 4336, 4356, 4400, 6),
    196: (1188000, 7680, 8232, 8408, 9000, 4320, 4336, 4356, 4400, 6),
    197: (2376000, 7680, 10232, 10408, 11000, 4320, 4336, 4356, 4500, 6),
    198: (2376000, 7680, 10032, 10208, 10800, 4320, 4336, 4356, 4400, 6),
    199: (2376000, 7680, 8232, 8408, 9000, 4320, 4336, 4356, 4400, 6),
    200: (4752000, 7680, 9792, 9968, 10560, 4320, 4336, 4356, 4500, 6),
    201: (4752000, 7680, 8032, 8208, 8800, 4320, 4336, 4356, 4500, 6),
    202: (1188000, 7680, 10232, 10408, 11000, 4320, 4336, 4356, 4500, 6),
    203: (1188000, 7680, 10032, 10208, 10800, 4320, 4336, 4356, 4400, 6),
    204: (1188000, 7680, 8232, 8408, 9000, 4320, 4336, 4356, 4400, 6),
    205: (2376000, 7680, 10232, 10408, 11000, 4320, 4336, 4356, 4500, 6),
    206: (2376000, 7680, 10032, 10208, 10800, 4320, 4336, 4356, 4400, 6),
    207: (2376000, 7680, 8232, 8408, 9000, 4320, 4336, 4356, 4400, 6),
    208: (4752000, 7680, 9792, 9968, 10560, 4320, 4336, 4356, 4500, 6),
    209: (4752000, 7680, 8032, 8208, 8800, 4320, 4336, 4356, 4500, 6),
    210: (1485000, 10240, 11732, 11908, 12500, 4320, 4336, 4356, 4950, 6),
    211: (1485000, 10240, 12732, 12908, 13500, 4320, 4336, 4356, 4400, 6),
    212: (1485000, 10240, 10528, 10704, 11000, 4320, 4336, 4356, 4500, 6),
    213: (2970000, 10240, 11732, 11908, 12500, 4320, 4336, 4356, 4950, 6),
    214: (2970000, 10240, 12732, 12908, 13500, 4320, 4336, 4356, 4400, 6),
    215: (2970000, 10240, 10528, 10704, 11000, 4320, 4336, 4356, 4500, 6),
    216: (5940000, 10240, 12432, 12608, 13200, 4320, 4336, 4356, 4500, 6),
    217: (5940000, 10240, 10528, 10704, 11000, 4320, 4336, 4356, 4500, 6),
    218: (1188000, 4096, 4896, 4984, 5280, 2160, 2168, 2178, 2250, 6),
    219: (1188000, 4096, 4184, 4272, 4400, 2160, 2168, 2178, 2250, 6),
}

# common DMT rates for standard timings (drm_mode_find_dmt hits); rest estimated by CVT
DMT = {(1920, 1080, 60): 148500, (1280, 1024, 60): 108000, (1280, 1024, 75): 135000,
       (1600, 1200, 60): 162000, (1680, 1050, 60): 146250, (1440, 900, 60): 106500,
       (1280, 800, 60): 83500, (1280, 960, 60): 108000, (1360, 768, 60): 85500,
       (1920, 1200, 60): 193250, (1280, 720, 60): 74250, (1366, 768, 60): 85500,
       (1600, 900, 60): 108000, (1152, 864, 75): 108000, (1024, 768, 60): 65000,
       (800, 600, 60): 40000, (640, 480, 60): 25175, (2560, 1600, 60): 348500}
EXT_NAMES = {0: "VCDB", 1: "vendor video (Dolby Vision / HDR10+)", 5: "colorimetry",
             6: "HDR static metadata", 7: "HDR dynamic metadata", 13: "video format preference",
             14: "YCbCr 4:2:0 video", 15: "YCbCr 4:2:0 capability map",
             17: "vendor audio", 18: "HDMI audio", 19: "room config", 20: "speaker location",
             32: "InfoFrame", 34: "DisplayID type VII", 0x78: "HF-EEODB", 0x79: "HF-SCDB"}


def fix_csum(block):
    b = bytearray(block)
    b[127] = (-sum(b[:127])) & 0xFF
    return bytes(b)


def _mode(w, h, hz, khz, src, il=False, ht=0):
    m = {"w": w, "h": h, "hz": round(hz, 2), "khz": khz, "il": il, "src": src}
    if ht:
        m["ht"] = ht
    return m


def mode_str(m):
    return f"{m['w']}x{m['h']}{'i' if m['il'] else ''}@{m['hz']:g} ({m['khz'] / 1000:g} MHz)"


def _key(m):
    return (m["w"], m["h"], round(m["hz"]), m["il"])


def vic_mode(vic):
    t = CEA_VIC.get(vic)
    if not t:
        return None
    clk, h, _, _, ht, v, _, _, vt, f = t
    il = bool(f & 1)
    return _mode(h, v, clk * 1000 / (ht * vt) * (2 if il else 1), clk, f"VIC {vic}", il, ht)


def dtd_mode(d):
    """18-byte detailed timing -> mode dict (None for display descriptors)."""
    clk = (d[0] | d[1] << 8) * 10
    if not clk:
        return None
    ha, hb = d[2] | (d[4] & 0xF0) << 4, d[3] | (d[4] & 0x0F) << 8
    va, vb = d[5] | (d[7] & 0xF0) << 4, d[6] | (d[7] & 0x0F) << 8
    if not ha or not va:
        return None
    il = bool(d[17] & 0x80)
    m = _mode(ha, va * (2 if il else 1), clk * 1000 / ((ha + hb) * (va + vb)), clk, "DTD", il,
              ha + hb)
    m["mm"] = (d[12] | (d[14] & 0xF0) << 4, d[13] | (d[14] & 0x0F) << 8)
    return m


def make_dtd(vic, mm=(0, 0)):
    """Progressive CEA VIC -> 18-byte DTD."""
    clk, h, hss, hse, ht, v, vss, vse, vt, f = CEA_VIC[vic]
    hb, hfp, hsw, vb, vfp, vsw = ht - h, hss - h, hse - hss, vt - v, vss - v, vse - vss
    d = bytearray(18)
    d[0:2] = (clk // 10).to_bytes(2, "little")
    d[2], d[3], d[4] = h & 0xFF, hb & 0xFF, (h >> 8) << 4 | hb >> 8
    d[5], d[6], d[7] = v & 0xFF, vb & 0xFF, (v >> 8) << 4 | vb >> 8
    d[8], d[9], d[10] = hfp & 0xFF, hsw & 0xFF, (vfp & 0xF) << 4 | (vsw & 0xF)
    d[11] = (hfp >> 8 & 3) << 6 | (hsw >> 8 & 3) << 4 | (vfp >> 4 & 3) << 2 | (vsw >> 4 & 3)
    d[12], d[13], d[14] = mm[0] & 0xFF, mm[1] & 0xFF, (mm[0] >> 8) << 4 | mm[1] >> 8
    d[17] = 0x18 | (0x04 if f & 4 else 0) | (0x02 if f & 2 else 0)
    return bytes(d)


def cvt_khz(w, h, hz):
    """VESA CVT (normal blanking) pixel clock, kHz; kernel uses CVT/GTF for non-DMT."""
    hp = ((1.0 / hz) - 550e-6) / (h + 3) * 1e6
    if hp <= 0:
        return 10 ** 7
    duty = max(30 - 300 * hp / 1000, 20)
    hr = w // 8 * 8
    hblank = int(hr * duty / (100 - duty) / 16) * 16
    vtot = h + max(int(550 / hp) + 1, 11) + 3
    return int((hr + hblank) * vtot * hz / 1000)


def std_mode(b1, b2, rev14):
    if b1 in (0, 1) and b2 in (0, 1):
        return None
    w, ar, hz = (b1 + 31) * 8, b2 >> 6, (b2 & 0x3F) + 60
    h = {0: w * 10 // 16 if rev14 else w, 1: w * 3 // 4, 2: w * 4 // 5, 3: w * 9 // 16}[ar]
    return _mode(w, h, hz, DMT.get((w, h, hz)) or cvt_khz(w, h, hz), "STD")


def dbc_blocks(cta):
    """CTA data block collection -> [(tag, raw bytes incl. header)]."""
    d = cta[2] if 4 <= cta[2] <= 127 else 4
    out, i = [], 4
    while i < d:
        tag, ln = cta[i] >> 5, cta[i] & 0x1F
        out.append((tag, bytes(cta[i:i + 1 + ln])))
        i += 1 + ln
    return out


def cta_dtds(cta):
    d = cta[2]
    out = []
    if d < 4:
        return out
    for o in range(d, 127 - 17, 18):
        if cta[o:o + 2] == b"\0\0":
            break
        out.append(bytes(cta[o:o + 18]))
    return out


def find_cta(edid):
    for i in range(1, len(edid) // 128):
        c = edid[i * 128:(i + 1) * 128]
        if c[0] == 0x02 and sum(c) % 256 == 0:
            return bytes(c)
    return None


def _vdb_vic(b):
    return b & 0x7F if 129 <= b <= 192 else b


def _is_hf(tag, raw):
    return (tag == 3 and raw[1:4] == OUI_HF) or (tag == 7 and len(raw) > 1 and raw[1] == 0x79)


def sink_limits(edid):
    """-> dict hdmi (HDMI VSDB present), vsdb_khz, hf_khz, scdc (HF SCDC_Present),
    frl (HF Max_FRL_Rate 0-6; reserved values as 6, like the driver)."""
    r = {"hdmi": False, "vsdb_khz": 0, "hf_khz": 0, "scdc": False, "frl": 0}
    cta = find_cta(edid)
    for tag, raw in dbc_blocks(cta) if cta else []:
        if tag == 3 and raw[1:4] == OUI_HDMI:
            r["hdmi"] = True
            if len(raw) > 7:
                r["vsdb_khz"] = raw[7] * 5000
        if _is_hf(tag, raw) and len(raw) > 6:
            r["hf_khz"] = raw[5] * 5000
            r["scdc"] = bool(raw[6] & 0x80)
            if len(raw) > 7:
                r["frl"] = min(raw[7] >> 4, 6)
    return r


def frl_need_gbps(m, bpp):
    """Link rate a mode needs: active pixels x bpp, 16b/18b coding, 5% packet/FEC margin."""
    act = m["w"] / m["ht"] if m.get("ht") else 1.0
    return m["khz"] * act * bpp * 18 / 16 * 1.05 / 1e6


def display_key(edid):
    """Sink identity for per-display settings: MFG-product-serial from base block, else md5."""
    b = bytes(edid[:128])
    if len(b) < 128 or b[:8] != HEADER:
        return None
    m = b[8] << 8 | b[9]
    mfg = "".join(chr(64 + (m >> sh & 31)) for sh in (10, 5, 0))
    if mfg.isalpha() and mfg.isupper():
        return f"{mfg}-{b[10] | b[11] << 8:04x}-{int.from_bytes(b[12:16], 'little'):08x}"
    return hashlib.md5(b).hexdigest()


def display_setting(key, name, default):
    """color / range for display key: entry, else legacy global flag, else default."""
    try:
        for ln in open(os.path.join(DISPLAY_DIR, f"{key}.conf")):
            k, _, v = ln.strip().partition("=")
            if k == name and v:
                return v
    except (OSError, TypeError):
        pass
    try:
        return open(COLOR_FLAG if name == "color" else COLOR_FLAG.replace("color", "range")
                    ).read().split()[0]
    except (OSError, IndexError):
        return default


def read_flags(key=None):
    """-> (frl tier on, colour setting): env H96_DISPLAY_FRL / _COLOR (h96-display trial)
    before per-display entry / flag files."""
    color = os.environ.get("H96_DISPLAY_COLOR") or display_setting(key, "color", "rgb")
    frl = {"on": True, "off": False}.get(os.environ.get("H96_DISPLAY_FRL", ""),
                                         not os.path.exists(FRL_OFF_FLAG))
    return frl, color if color in COLORS else "rgb"


def kscreen_carry(old, new, homes=None):
    """Copy KDE (kscreen) display config of kernel EDID md5 old to md5 new for every user:
    outputs/<md5> and setup files listing it (setup name = md5 of sorted output ids).
    -> list of files written."""
    if homes is None:
        homes = []
        try:
            import pwd
            homes = sorted({p.pw_dir for p in pwd.getpwall()})
        except ImportError:
            pass
    written = []
    for home in homes:
        ks = os.path.join(home, ".local/share/kscreen")
        src = os.path.join(ks, "outputs", old)
        if old == new or not os.path.isfile(src):
            continue
        st = os.stat(src)
        todo = [(src, os.path.join(ks, "outputs", new))]
        for name in sorted(os.listdir(ks)):
            p = os.path.join(ks, name)
            if not os.path.isfile(p):
                continue
            try:
                ids = [o.get("id") for o in json.load(open(p))]
            except (OSError, ValueError, AttributeError, TypeError):
                continue
            if old in ids:
                nid = sorted(new if i == old else i for i in ids)
                todo.append((p, os.path.join(ks, hashlib.md5("".join(nid).encode()).hexdigest())))
        for s, d in todo:
            txt = open(s).read().replace(old, new)
            with open(d + ".h96new", "w") as f:
                f.write(txt)
            os.replace(d + ".h96new", d)
            try:
                os.chown(d, st.st_uid, st.st_gid)
            except OSError:
                pass
            written.append(d)
    return written


def driver_max_khz(edid):
    """Max clock dw_hdmi_rockchip_mode_valid accepts for RGB (no 4:2:0) on this EDID."""
    s = sink_limits(edid)
    if not s["hdmi"]:
        return 340000                      # DVI sink: bridge rejects > 340 MHz
    m = s["vsdb_khz"] or 340000
    return s["hf_khz"] if s["hf_khz"] > 340000 else m


def modes_of(edid):
    """Timings an EDID lists (DTD, established, standard, VIC, HDMI VIC), deduplicated."""
    out, seen = [], set()

    def add(m):
        if m and _key(m) not in seen:
            seen.add(_key(m))
            out.append(m)
    b0 = edid[:128]
    rev14 = b0[18] == 1 and b0[19] >= 4
    for o in (54, 72, 90, 108):
        add(dtd_mode(b0[o:o + 18]))
    cta = find_cta(edid)
    for d in cta_dtds(cta) if cta else []:
        add(dtd_mode(d))
    for i, (w, h, hz, khz) in enumerate(EST):
        if b0[35 + i // 8] & (0x80 >> (i % 8)):
            add(_mode(w, h, hz, khz, "EST", (w, hz) == (1024, 87)))
    for i in range(38, 54, 2):
        add(std_mode(b0[i], b0[i + 1], rev14))
    for tag, raw in dbc_blocks(cta) if cta else []:
        if tag == 2:
            for b in raw[1:]:
                add(vic_mode(_vdb_vic(b)))
        elif tag == 7 and len(raw) > 1 and raw[1] == 14:
            for b in raw[2:]:
                m = vic_mode(_vdb_vic(b))
                if m:
                    m["src"] += " (4:2:0 only)"
                add(m)
        elif tag == 3 and raw[1:4] == OUI_HDMI and len(raw) > 8 and raw[8] & 0x20:
            p = 9 + (2 if raw[8] & 0x80 else 0) + (2 if raw[8] & 0x40 else 0)
            if p + 1 < len(raw):
                for v in raw[p + 2:p + 2 + (raw[p + 1] >> 5)]:
                    if v in HDMI_VIC:
                        c, w, h, hz = HDMI_VIC[v]
                        add(_mode(w, h, hz, c, f"HDMI VIC {v}"))
    return out


def kernel_modes(edid):
    """Modes this kernel accepts for EDID (bridge + rockchip glue mode_valid).
    -> (accepted, [(mode, reason)] rejected)."""
    top = driver_max_khz(edid)
    frl = sink_limits(edid)["frl"]
    acc, rej = [], []
    for m in modes_of(edid):
        if m["khz"] < MIN_KHZ:
            rej.append((m, "<= 25 MHz (bridge)"))
        elif m["khz"] > HDMI20_KHZ and not frl:
            rej.append((m, f"> {HDMI20_KHZ // 1000} MHz: sink lists no FRL rate (TMDS only)"))
        elif m["khz"] > FRL_KHZ or m["w"] > FRL_MAX_W:
            rej.append((m, f"> {FRL_KHZ // 1000} MHz or wider than {FRL_MAX_W} (VOP2 VP0)"))
        elif m["khz"] > Y420_KHZ and "4:2:0" not in m["src"]:
            rej.append((m, f"> {Y420_KHZ // 1000} MHz: driver sends 4:2:0, sink lists none"))
        elif m["khz"] > HDMI20_KHZ:
            m["src"] += f" (FRL {FRL_GBPS[frl]}G, untested)"
            acc.append(m)
        elif m["khz"] > top and "4:2:0" not in m["src"]:
            rej.append((m, f"> sink max TMDS {top // 1000} MHz (glue)"))
        else:
            acc.append(m)
    return acc, rej


# ------------------------------------------------------------------ merge
def _block_name(tag, raw):
    if _is_hf(tag, raw):
        return "HDMI Forum VSDB/SCDB"
    if tag == 3 and len(raw) > 3:
        return f"vendor block OUI {raw[3]:02x}-{raw[2]:02x}-{raw[1]:02x}"
    if tag == 7 and len(raw) > 1:
        return EXT_NAMES.get(raw[1], f"extended tag {raw[1]}")
    return f"data block tag {tag}"


def build(display, forced, audio, hdmi20=False, safe=False, frl=None, color=None):
    """Display EDID (valid block 0) + sink audio -> (merged EDID bytes, info dict).

    audio = (adb, sadb): raw Audio + Speaker Allocation data blocks, headers included.
    frl / color None = flag files (read_flags).
    Raises ValueError when display block 0 or result is unusable."""
    if len(display) < 128 or display[:8] != HEADER or sum(display[:128]) % 256:
        raise ValueError("display block 0 invalid")
    if frl is None or color is None:
        f_frl, f_color = read_flags(display_key(display))
        frl = f_frl if frl is None else frl
        color = f_color if color is None else color
    if color not in COLORS:
        raise ValueError(f"colour setting {color!r} unknown")
    info = {"dropped": [], "notes": [], "hdmi20": False, "safe": False, "frl": False,
            "color": color}
    b0 = bytearray(display[:128])
    rev14 = b0[18] == 1 and b0[19] >= 4
    cta = find_cta(display)
    lim = sink_limits(display)
    if cta is None:
        cta_src = find_cta(forced)
        if cta_src is None:
            raise ValueError("forced EDID has no CTA block")
        info["notes"].append("display has no CTA-861 block: forced CTA audio + HDMI VSDB, "
                             "display video only")
        dtd_src, blocks = [], [(t, r) for t, r in dbc_blocks(cta_src) if t != 2]
    else:
        cta_src, dtd_src, blocks = cta, cta_dtds(cta), dbc_blocks(cta)
    ceiling = MAX_KHZ
    if lim["hdmi"] and lim["vsdb_khz"]:
        ceiling = min(ceiling, lim["vsdb_khz"])
    hf_tmds = frl_gbps = 0
    if hdmi20:
        if lim["hdmi"] and lim["scdc"] and lim["hf_khz"] > MAX_KHZ:
            # sink DTDs may exceed its HF max TMDS (LG 1440p144 596.25 > 594): tier cap only
            ceiling = HDMI20_KHZ
            hf_tmds = HDMI20_KHZ // 5000
            info["hdmi20"] = True
            if frl and lim["frl"]:
                frl_gbps = FRL_GBPS[lim["frl"]]
                info.update(frl=True, frl_gbps=frl_gbps)
        else:
            info["notes"].append("hdmi20: sink lists no HF-VSDB with SCDC above 340 MHz: "
                                 "340 MHz ceiling")
    info["ceiling_khz"] = FRL_KHZ if info["frl"] else ceiling

    # sink 4:2:0: VICs in Y420VDB (4:2:0 only) and VDB VICs marked by Y420CMDB
    svds = [_vdb_vic(b) for t, r in blocks if t == 2 for b in r[1:]]
    y420_only, y420_cap = [], set()
    for tag, raw in blocks:
        if tag == 7 and len(raw) > 1 and raw[1] == 14:
            y420_only += [_vdb_vic(b) for b in raw[2:]]
        elif tag == 7 and len(raw) > 1 and raw[1] == 15:
            y420_cap |= {v for i, v in enumerate(svds)
                         if len(raw) == 2 or (2 + i // 8 < len(raw) and raw[2 + i // 8] >> (i % 8) & 1)}

    def carry(m, can420=False, only420=False):
        """-> 'rgb' | '420' | None (removed)."""
        if m is None or m["il"] or m["khz"] < MIN_KHZ:
            return None
        if m["khz"] <= ceiling:
            return None if only420 else "rgb"
        if not info["frl"] or m["khz"] > FRL_KHZ or m["w"] > FRL_MAX_W:
            return None
        if not only420 and m["khz"] <= Y420_KHZ and frl_need_gbps(m, 24) <= frl_gbps:
            return "rgb"
        if (can420 or only420) and frl_need_gbps(m, 12) <= frl_gbps:
            return "420"
        return None

    def ok(m):                              # interlaced out: VOP2 interlace path unexercised
        return carry(m) == "rgb"

    def tmds(m):                            # preferred candidates: TMDS only, FRL untested
        return ok(m) and m["khz"] <= ceiling

    def drop(what, m=None):
        info["dropped"].append(what + (f" {mode_str(m)}" if m else ""))

    # block 0: colour encoding (EDID 1.4 digital), standard timings, descriptors
    keep_c = COLORS[color]                  # EDID 1.4 byte 24: bit 3 = 4:4:4, bit 4 = 4:2:2
    strip0 = 0x18 & ~(((keep_c & 0x20) >> 2) | (keep_c & 0x10))
    if rev14 and b0[20] & 0x80 and b0[24] & strip0:
        b0[24] &= ~strip0 & 0xFF
        drop("block 0 colour encoding " + {0x18: "YCbCr 4:4:4/4:2:2", 0x10: "YCbCr 4:2:2"}[strip0])
    for i in range(38, 54, 2):
        m = std_mode(b0[i], b0[i + 1], rev14)
        if m and not tmds(m):
            b0[i], b0[i + 1] = 1, 1
            drop("standard timing", m)
    dtds, others = [], []
    for o in (54, 72, 90, 108):
        d = bytes(b0[o:o + 18])
        if d[0] | d[1]:
            dtds.append(d)
        elif d[3] != 0x10:
            top = info["ceiling_khz"]
            if d[3] == 0xFD and d[9] > -(-top // 10000):
                d = d[:9] + bytes([min(-(-top // 10000), 255)]) + d[10:]
            others.append(d)
    while len(others) > 3:                      # one slot stays for preferred DTD
        others.remove(next((x for x in reversed(others) if x[3] not in (0xFC, 0xFD)),
                           others[-1]))
    kept, seen = [], set()
    for d in dtds + dtd_src:
        m = dtd_mode(d)
        if not ok(m):
            if m:
                drop("DTD", m)
        elif _key(m) not in seen:
            seen.add(_key(m))
            kept.append((d, m))
    vics, y420 = [], []
    for tag, raw in blocks:
        if tag == 2:
            for b in raw[1:]:
                v = _vdb_vic(b)
                m = vic_mode(v)
                c = carry(m, can420=v in y420_cap)
                if c == "rgb":
                    vics.append(b)
                elif c == "420" and v not in y420:
                    y420.append(v)
                else:
                    drop(f"VIC {v}", m)
    for v in y420_only:
        if carry(vic_mode(v), only420=True) == "420" and v not in y420:
            y420.append(v)
    for v in y420:
        info["notes"].append(f"4:2:0 (no RGB fit at {frl_gbps}G FRL): {mode_str(vic_mode(v))}")
    mm = kept[0][1]["mm"] if kept else (b0[21] * 10, b0[22] * 10)
    pref0 = dtd_mode(dtds[0]) if dtds else None
    if pref0 and not tmds(pref0):           # display preferred above ceiling: same size, max Hz
        wh = (pref0["w"], pref0["h"])
        same = [(m["hz"], i, 0) for i, (_, m) in enumerate(kept)
                if (m["w"], m["h"]) == wh and tmds(m)]
        same += [(m["hz"], -1, v) for v in map(_vdb_vic, vics) for m in [vic_mode(v)]
                 if (m["w"], m["h"]) == wh and tmds(m) and not CEA_VIC[v][9] & 8]
        if same:
            _, i, v = max(same)
            if v:
                kept.insert(0, (make_dtd(v, pref0["mm"]), dtd_mode(make_dtd(v, pref0["mm"]))))
            else:
                kept.insert(0, kept.pop(i))
            info["notes"].append(f"preferred {mode_str(pref0)} above ceiling: "
                                 f"{mode_str(kept[0][1])} first")
    if kept and not tmds(kept[0][1]):       # FRL DTD first: first TMDS DTD instead
        i = next((i for i, (_, m) in enumerate(kept) if tmds(m)), None)
        if i is not None:
            kept.insert(0, kept.pop(i))
    if not kept or not tmds(kept[0][1]):
        cand = [(m["w"] * m["h"], m["hz"], _vdb_vic(b)) for b in vics
                for m in [vic_mode(_vdb_vic(b))] if tmds(m) and not
                CEA_VIC[_vdb_vic(b)][9] & 8]
        if not cand:
            raise ValueError(f"no mode within {ceiling} kHz")
        vic = max(cand)[2]
        kept.insert(0, (make_dtd(vic, mm), dtd_mode(make_dtd(vic, mm))))
        info["notes"].append(f"no DTD within ceiling: preferred built from VIC {vic}")
    if safe:
        info["safe"] = True
        want = [i for i, (_, m) in enumerate(kept) if _key(m) == SAFE_MODE + (False,)]
        listed = any(_vdb_vic(b) == 16 for b in vics) or any(
            (m["w"], m["h"], round(m["hz"])) == SAFE_MODE for m in modes_of(display))
        if want:
            kept.insert(0, kept.pop(want[0]))
        elif listed:
            kept.insert(0, (make_dtd(16, mm), dtd_mode(make_dtd(16, mm))))
        else:
            low = [(m["w"] * m["h"], m["hz"], i) for i, (_, m) in enumerate(kept)
                   if m["khz"] <= 165000 and not m["il"]]
            if low:
                kept.insert(0, kept.pop(max(low)[2]))
        info["notes"].append(f"safe: preferred {mode_str(kept[0][1])}")
    info["preferred"] = mode_str(kept[0][1])
    info["preferred_mode"] = "%dx%d@%d" % (kept[0][1]["w"], kept[0][1]["h"],
                                           round(kept[0][1]["hz"]))
    nslots = 4 - len(others)
    desc = [d for d, _ in kept[:nslots]] + others
    desc += [DUMMY_DESC] * (4 - len(desc))
    for i, d in enumerate(desc):
        b0[54 + i * 18:72 + i * 18] = d
    b0[126] = 1
    b0 = fix_csum(b0)
    # CTA block: VDB, audio, HDMI VSDB (+ HF-VSDB in hdmi20, + 4:2:0 VDB in frl), VCDB
    adb, sadb = audio

    def assemble():
        out, placed = [], False
        for tag, raw in blocks:
            if tag == 2:
                if vics:
                    out.append(bytes([0x40 | len(vics)]) + bytes(vics))
                if not placed:
                    out += [adb, sadb]
                    placed = True
            elif tag in (1, 4):
                if not placed:
                    out += [adb, sadb]
                    placed = True
            elif tag == 3 and raw[1:4] == OUI_HDMI:
                v = bytearray(raw)
                if len(v) > 6 and v[6] & 0x78:
                    v[6] &= 0x87
                if len(v) > 7 and v[7] > 0x44:
                    v[7] = 0x44
                out.append(bytes(v))
                if info["frl"]:                 # zero bytes 8-13: drm reads DSC byte 11 unchecked
                    out.append(bytes([0x6D]) + OUI_HF + bytes([1, hf_tmds, 0x80, lim["frl"] << 4]) +
                               bytes(6))
                elif info["hdmi20"]:
                    out.append(bytes([0x67]) + OUI_HF + bytes([1, hf_tmds, 0x80, 0]))
                if y420:
                    out.append(bytes([0xE0 | (len(y420) + 1), 14]) + bytes(y420))
            elif tag == 7 and len(raw) > 1 and raw[1] == 0:
                out.append(raw)
        if not placed:
            out[0:0] = [adb, sadb]
        return out

    for tag, raw in blocks:
        if tag == 3 and raw[1:4] == OUI_HDMI and len(raw) > 6 and raw[6] & 0x78:
            drop("HDMI VSDB deep colour flags")
        elif not (tag in (1, 2, 4) or (tag == 3 and raw[1:4] == OUI_HDMI) or
                  (tag == 7 and len(raw) > 1 and raw[1] == 0)):
            if not (y420 and tag == 7 and len(raw) > 1 and raw[1] in (14, 15)):
                drop(_block_name(tag, raw))
    out = assemble()
    while 4 + len(b"".join(out)) > 127:         # no room: highest-clock FRL VIC out first
        frl_v = [(vic_mode(v)["khz"], 1, v) for v in y420] + [
            (vic_mode(_vdb_vic(b))["khz"], 0, b) for b in vics
            if vic_mode(_vdb_vic(b))["khz"] > ceiling]
        if not frl_v:
            break
        _, is420, v = max(frl_v)
        (y420 if is420 else vics).remove(v)
        drop("VIC (no room in CTA block)", vic_mode(v if is420 else _vdb_vic(v)))
        out = assemble()
    if not any(r[0] >> 5 == 3 and r[1:4] == OUI_HDMI for r in out):
        fc = find_cta(forced)
        fv = [r for t, r in (dbc_blocks(fc) if fc else []) if t == 3 and r[1:4] == OUI_HDMI]
        if fv:
            out.append(fv[0])
            info["notes"].append("display lists no HDMI VSDB: forced VSDB added (HDMI mode, "
                                 "audio infoframes, as with forced EDID)")
    dbc = b"".join(out)
    cdtds = [d for d, _ in kept[nslots:]]
    while cdtds and 4 + len(dbc) + 18 * len(cdtds) > 127:
        drop("DTD (no room in CTA block)", dtd_mode(cdtds.pop()))
    if 4 + len(dbc) > 127:
        raise ValueError("merged CTA data blocks do not fit 128 bytes")
    if cta_src[3] & 0x30 & ~keep_c:
        drop("CTA YCbCr " + ("4:4:4/4:2:2" if cta_src[3] & 0x30 & ~keep_c == 0x30 else
                             "4:4:4" if cta_src[3] & 0x20 & ~keep_c else "4:2:2") + " support bits")
    c = bytearray(128)
    c[0:4] = bytes([0x02, max(cta_src[1], 3), 4 + len(dbc),
                    (cta_src[3] & 0x80) | 0x40 | (cta_src[3] & keep_c) |
                    min(cta_src[3] & 0x0F, len(kept))])
    c[4:4 + len(dbc)] = dbc
    for i, d in enumerate(cdtds):
        o = 4 + len(dbc) + 18 * i
        c[o:o + 18] = d
    if display[126] > 1:
        info["notes"].append(f"display EDID has {display[126]} extensions: first CTA block used")
    info["display_md5"] = hashlib.md5(display).hexdigest()
    return b0 + fix_csum(c), info


def audio_blocks(cta):
    """(ADB, SADB) raw blocks of a CTA block, None when absent."""
    adb = sadb = None
    for tag, raw in dbc_blocks(cta):
        if tag == 1 and adb is None:
            adb = raw
        elif tag == 4 and sadb is None:
            sadb = raw
    return adb, sadb


# ------------------------------------------------------------------ tests
SONY_HEX = (  # SONY TV (2009, EDID 1.3), DDC capture on this box's HDMI0
    "00ffffffffffff004dd9019c010101010113010380a05a780a0dc9a057479827"
    "12484c21080081800101010101010101010101010101023a801871382d40582c"
    "450040846300001e011d007251d01e206e28550040846300001e000000fd003a"
    "3e0f460f000a202020202020000000fc00534f4e592054560a20202020200106"
    "0203207049100405030207062001260907071507508301000066030c00200080"
    "011d8018711c1620582c250040846300009e8c0ad08a20e02d10103e96004084"
    "630000188c0ad08a20e02d10103e9600b084430000188c0aa01451f01600267c"
    "4300b08443000098000000000000000000000000000000000000000000000028")
AOC_B0_HEX = (  # AOC AG275QX block 0 (linuxhw/EDID Digital/AOC/AOCA503/19AFA839D5E8)
    "00ffffffffffff0005e303a5bc01000006210104b53c22783f29d5ad4f44a724"
    "0f5054bfef00d1c081803168317c4568457c6168617c565e00a0a0a029503020"
    "350055502100001e000000ff0056584a50324a41303030343434000000fc0041"
    "4732373551580a2020202020000000fd003caaffff44010a2020202020200260")
AOC_DTDS_HEX = ("98fc006aa0a01e500820350055502100001a",   # 2560x1440@165 646.64 MHz
                "40e7006aa0a067500820980455502100001a",   # 2560x1440@144 592 MHz
                "6fc200a0a0a055503020350055502100001e",   # 2560x1440@120 497.75 MHz
                "f03c00d051a0355060883a0055502100001c")   # 1280x1440@60 156 MHz


def _cta(blocks, dtds=(), flags=0x70):
    dbc = b"".join(blocks)
    c = bytearray(128)
    c[0:4] = bytes([0x02, 0x03, 4 + len(dbc), flags])
    c[4:4 + len(dbc)] = dbc
    for i, d in enumerate(dtds):
        c[4 + len(dbc) + 18 * i:4 + len(dbc) + 18 * (i + 1)] = d
    return fix_csum(c)


def _b0(name, dtds, rev=3, est=b"\x20\x00\x00", size=(160, 90), fd_mhz=60):
    b = bytearray(128)
    b[:8] = HEADER
    b[8:12] = bytes([0x4D, 0xD9, 0x34, 0x12])
    b[18:21] = bytes([1, rev, 0x80 | (0x30 if rev >= 4 else 0)])
    b[21:23] = bytes(size)
    b[24] = 0x0A | (0x18 if rev >= 4 else 0)
    b[35:38] = est
    b[38:54] = b"\x01" * 16
    desc = list(dtds)
    desc.append(bytes([0, 0, 0, 0xFD, 0, 23, 61, 15, 136, fd_mhz, 0, 0x0A]) + b"\x20" * 6)
    desc.append(bytes([0, 0, 0, 0xFC, 0]) + (name + b"\n").ljust(13, b" ")[:13])
    desc += [DUMMY_DESC] * (4 - len(desc))
    for i, d in enumerate(desc[:4]):
        b[54 + 18 * i:72 + 18 * i] = d
    b[126] = 1
    return fix_csum(b)


ADB_STEREO = bytes.fromhex("23090707")
SADB_FLFR = bytes.fromhex("83010000")
VSDB_DC = bytes.fromhex("6703" "0c00" "1000" "b844")          # PA 1.0.0.0, DC 48/36/30/Y444
HF_VSDB = bytes.fromhex("67d85dc4" "01" "78" "88" "07")       # 600 MHz, SCDC, DC_420
COLORIMETRY = bytes.fromhex("e305e301")
HDR_STATIC = bytes.fromhex("e606070162620" "0")
Y420_CMDB = bytes.fromhex("e10f")
VCDB = bytes.fromhex("e20040")
DOVI = bytes.fromhex("eb0146d000" "4403" "904b5c93")


def sample_1440p():
    """HDMI 2.0 1440p165 monitor: AOC AG275QX block 0 + HDMI-port style CTA block."""
    vdb = bytes([0x46, 0x90, 4, 31, 63, 1, 3])                # 1080p60 native, 1080p120
    cta = _cta([vdb, ADB_STEREO, SADB_FLFR, VSDB_DC, HF_VSDB, COLORIMETRY, HDR_STATIC,
                Y420_CMDB, VCDB], [bytes.fromhex(h) for h in AOC_DTDS_HEX])
    b0 = bytearray(bytes.fromhex(AOC_B0_HEX))
    b0[126] = 1
    return fix_csum(b0) + cta


def sample_4k_tv():
    """4K60 TV: 4K60/50 via 4:2:0 map, HDMI VICs, HF-VSDB, HDR, Dolby Vision, multichannel."""
    b0 = _b0(b"TEST 4K TV", [make_dtd(97, (1600, 900)), make_dtd(16, (1600, 900))],
             fd_mhz=60)
    vdb = bytes([0x4E, 97, 96, 95, 94, 93, 0x90, 31, 4, 19, 3, 18, 1, 5, 20])
    adb = bytes.fromhex("2c" "0f7f07" "150750" "3d0750" "570604")
    vsdb = bytes.fromhex("6e030c0020" "00" "b8" "3c" "20" "00" "80" "01" "01" "02" "03")
    y420vdb = bytes.fromhex("e30e6061")                       # 4K100/120 4:2:0 only
    cmdb = bytes.fromhex("e20f03")
    cta = _cta([vdb, adb, bytes.fromhex("834f0000"), vsdb, HF_VSDB, HDR_STATIC, COLORIMETRY,
                y420vdb, cmdb, VCDB, DOVI], [make_dtd(95, (1600, 900))])
    return b0 + cta


def sample_sony():
    return bytes.fromhex(SONY_HEX)


def sample_forced():
    """Forced EDID stand-in: 1080p60 block 0 + CTA (VDB, stereo, VSDB 1.0.0.0, 1 DTD)."""
    b0 = _b0(b"Linux FHD", [make_dtd(16, (500, 281))], est=b"\0\0\0", size=(50, 28))
    return b0 + _cta([bytes([0x47, 16, 31, 4, 19, 17, 2, 1]), ADB_STEREO, SADB_FLFR,
                      bytes.fromhex("65030c001000")], [make_dtd(16, (500, 281))], 0x41)


LG_HEX = (  # LG UltraGear 1440p144 (owner's HDMI 2.0 monitor), serial fields zeroed
    "00ffffffffffff001e6d6577000000000621010380462778eacdb4a55650a127"
    "135054210800d1c061400101010101010101010101016fc200a0a0a055503020"
    "3500b9882100001a000000fd0030901efa41000a202020202020000000fc004c"
    "4720554c545241474541520a000000ff003030303030303030303030300a0132"
    "020350f1230907074c1004031f13125d5e5f60613f830100006d030c001000b8"
    "7820006001020368d85dc40178800300e30f00066d1a00000205309000045a50"
    "5a50e305c000e2006ae60605015a5a50e9e800a0a0a0535030203500ba882100"
    "001a565e00a0a0a0295030203500ba882100001a0000000000000000000000af")
# merged md5 per (display, hdmi20) from pre-FRL edid_merge (sha 61b25116), sample_forced audio
PRE_FRL_MD5 = {("lg", False): "f47e1aaf44c69457b169eb363a3dbbe5",
               ("lg", True): "0e35268494d075e4453c748cbbe4c880",
               ("1440p", False): "fdc72564d1af34f606838e08e5638a2d",
               ("1440p", True): "8523967dae468a3af92183947f223321",
               ("4ktv", False): "42354fa6696a498147331eaf56f7412d",
               ("4ktv", True): "b5ad449ccc4a2dbb1395d3281aa70c61",
               ("sony", False): "bec556e552fa488b50d5637862032d49",
               ("sony", True): "bec556e552fa488b50d5637862032d49"}


def _hf(frl, extra=b""):
    """HF-VSDB: 600 MHz, SCDC + RR, DC_420 30/36/48, Max_FRL_Rate frl, optional tail."""
    body = OUI_HF + bytes([1, 0x78, 0xC8, frl << 4 | 0x07]) + extra
    return bytes([0x60 | len(body)]) + body


def sample_4k120_tv(frl=5, cmdb=True):
    """HDMI 2.1 4K120 TV: 4K100/120 in VDB (4:2:0 capable via CMDB), FRL rate frl."""
    b0 = _b0(b"TEST 4K120", [make_dtd(97, (1600, 900)), make_dtd(16, (1600, 900))])
    vdb = bytes([0x48, 97, 96, 0x90, 4, 31, 63, 117, 118])
    blocks = [vdb, ADB_STEREO, SADB_FLFR, VSDB_DC, _hf(frl, bytes([0x0A, 0, 0])), HDR_STATIC]
    if cmdb:
        blocks.append(bytes.fromhex("e20fc0"))                  # SVD 7, 8 (117, 118)
    return b0 + _cta(blocks + [VCDB], [make_dtd(95, (1600, 900))])


def sample_8k_tv(frl=6):
    """HDMI 2.1 8K60 TV: 8K24/30 + 4K120 in VDB, 8K60/100 4:2:0 only, 10K, DSC 1.2 fields."""
    b0 = _b0(b"TEST 8K TV", [make_dtd(97, (1600, 900)), make_dtd(16, (1600, 900))])
    vdb = bytes([0x48, 97, 0x90, 4, 118, 194, 196, 200, 216])
    y420vdb = bytes([0xE3, 14, 199, 200])
    hf = _hf(frl, bytes([0x0B, 0, 0, 0x8F, 0x67, 0x3F]))           # ALLM/VRR, DSC 1.2 48G
    return b0 + _cta([vdb, ADB_STEREO, SADB_FLFR, VSDB_DC, hf, HDR_STATIC, y420vdb, VCDB, DOVI])


def _keys(ms):
    return {(m["w"], m["h"], round(m["hz"]), m["il"]) for m in ms}


def selftest(check):
    global FRL_OFF_FLAG, COLOR_FLAG
    global DISPLAY_DIR
    FRL_OFF_FLAG = COLOR_FLAG = DISPLAY_DIR = "/nonexistent/h96-selftest"   # box settings ignored
    for k in ("H96_DISPLAY_FRL", "H96_DISPLAY_COLOR"):
        os.environ.pop(k, None)
    forced = sample_forced()
    au = (ADB_STEREO, SADB_FLFR)

    def valid(e):
        return len(e) == 256 and all(sum(e[i:i + 128]) % 256 == 0 for i in (0, 128))

    sony = sample_sony()
    m, i = build(sony, forced, (bytes.fromhex("26090707110750"), SADB_FLFR))
    acc, rej = kernel_modes(m)
    check(valid(m) and i["preferred_mode"] == "1920x1080@60", "merge sony: valid, 1080p60 first")
    check(_keys(acc) == {(1920, 1080, 60, False), (1280, 720, 60, False),
                         (720, 480, 60, False), (1920, 1080, 24, False),
                         (640, 480, 60, False), (800, 600, 60, False), (1024, 768, 60, False),
                         (1280, 1024, 60, False)},
          "merge sony: display progressive mode list, interlaced out")
    check(m[131] & 0x30 == 0 and b"\x03\x0c\x00\x20\x00" in m[128:], "merge sony: RGB, PA 2.0.0.0")
    a1440 = sample_1440p()
    m, i = build(a1440, forced, au)
    acc, rej = kernel_modes(m)
    k = _keys(acc)
    check(valid(m) and i["ceiling_khz"] == 340000 and driver_max_khz(m) == 340000,
          "merge 1440p: 340 MHz ceiling, kernel limit 340 MHz")
    check((2560, 1440, 60, False) in k and not {(2560, 1440, r, False) for r in (120, 144, 165)} & k
          and (1920, 1080, 120, False) in k, "merge 1440p: 1440p60 + 1080p120 kept, 120/144/165 out")
    check(i["preferred_mode"] == "2560x1440@60" and m[24] & 0x18 == 0, "merge 1440p: preferred, RGB")
    blk = dbc_blocks(m[128:])
    check(not any(_is_hf(t, r) or (t == 7 and r[1] != 0) for t, r in blk)
          and all(r[6] & 0x78 == 0 for t, r in blk if t == 3), "merge 1440p: no HF/HDR/420/DC")
    m, i = build(a1440, forced, au, hdmi20=True)
    k = _keys(kernel_modes(m)[0])
    check(i["hdmi20"] and {(2560, 1440, 120, False), (2560, 1440, 144, False)} <= k
          and (2560, 1440, 165, False) not in k and driver_max_khz(m) == 600000,
          "merge 1440p hdmi20: 120 + 144 kept, 165 (646 MHz) out")
    hf = [r for t, r in dbc_blocks(m[128:]) if _is_hf(t, r)]
    check(hf == [bytes.fromhex("67d85dc40178" "8000")], "merge hdmi20: minimal HF-VSDB, SCDC only")
    lg = bytearray(a1440)                                    # LG UltraGear 1440p144 DTD, 596.25 MHz
    lg[128 + lg[130] + 18:128 + lg[130] + 36] = bytes.fromhex("e9e800a0a0a0535030203500ba882100001a")
    lg[128:] = fix_csum(lg[128:])
    m, i = build(bytes(lg), forced, au, hdmi20=True)
    check(any(x["khz"] == 596250 for x in kernel_modes(m)[0]) and i["ceiling_khz"] == HDMI20_KHZ,
          "merge hdmi20: 596.25 MHz DTD kept, ceiling 600 MHz")
    check(build(bytes(lg), forced, au, hdmi20=True)[0] == m,
          "merge hdmi20: byte-stable for same display and tier")
    m, i = build(a1440, forced, au, safe=True)
    k = _keys(kernel_modes(m)[0])
    check(i["preferred_mode"] == "1920x1080@60" and (2560, 1440, 60, False) in k,
          "merge safe: 1080p60 first, 1440p60 listed")
    tv = sample_4k_tv()
    m, i = build(tv, forced, au)
    acc, rej = kernel_modes(m)
    k = _keys(acc)
    check(valid(m) and i["preferred_mode"] == "3840x2160@30" and (3840, 2160, 60, False) not in k
          and (3840, 2160, 24, False) in k, "merge 4K TV: 4K60 out, 4K30 preferred")
    check(not any(t == 7 and r[1] in (1, 5, 6, 14, 15) for t, r in dbc_blocks(m[128:])),
          "merge 4K TV: DV, HDR, colorimetry, 4:2:0 blocks out")
    check(all(x["khz"] <= 340000 for x in acc) and not rej or all(
        r[1].startswith("<=") for r in rej), "merge 4K TV: every listed mode accepted")
    m, i = build(tv, forced, au, hdmi20=True)
    check(i["preferred_mode"] == "3840x2160@60", "merge 4K TV hdmi20: 4K60 preferred")
    nocta = sony[:126] + b"\0" + bytes([(-sum(sony[:126])) & 0xFF])
    m, i = build(nocta, forced, au)
    check(valid(m) and b"\x03\x0c\x00\x10\x00" in m[128:] and not any(
        t == 2 for t, _ in dbc_blocks(m[128:])), "merge no CTA: forced audio + VSDB, no VDB")
    lo = sony[:128] + _cta([bytes([0x41, 16]), ADB_STEREO, SADB_FLFR,
                            bytes.fromhex("67030c0010000021")])        # VSDB max 165 MHz
    check(build(lo, forced, au)[1]["ceiling_khz"] == 165000, "merge: VSDB max TMDS honoured")
    bad = bytearray(sony)
    bad[60] ^= 0x10
    try:
        build(bytes(bad), forced, au)
        check(False, "merge corrupt block 0: refused")
    except ValueError:
        check(True, "merge corrupt block 0: refused")

    # FRL tier, colour setting, pre-FRL byte identity
    fa = sample_forced()
    lgd = bytes.fromhex("".join(LG_HEX))
    for name, e in (("lg", lgd), ("1440p", a1440), ("4ktv", tv), ("sony", sony)):
        for h20 in (False, True):
            md = hashlib.md5(build(e, fa, au, h20, frl=True, color="rgb")[0]).hexdigest()
            check(md == PRE_FRL_MD5[(name, h20)], f"frl on, {name} hdmi20 "
                  f"{'on' if h20 else 'off'}: bytes as pre-FRL (HDMI 2.0 unchanged)")
    check(build(lgd, fa, au, True)[0] == build(lgd, fa, au, True, frl=True, color="rgb")[0],
          "no flag files: frl on, rgb")
    t4 = sample_4k120_tv()
    m, i = build(t4, fa, au, True, frl=True, color="rgb")
    acc, rej = kernel_modes(m)
    k = _keys(acc)
    hf = [r for t, r in dbc_blocks(m[128:]) if _is_hf(t, r)]
    check(valid(m) and i["frl"] and i["frl_gbps"] == 40 and hf == [bytes.fromhex("6dd85dc401788050" "000000000000")],
          "4K120 TV 40G: HF-VSDB Max_FRL_Rate 5, SCDC only, no DC_420")
    check({(3840, 2160, 120, False), (3840, 2160, 100, False), (3840, 2160, 60, False)} <= k
          and not any("4:2:0" in x["src"] for x in acc) and not any(
              t == 7 and r[1] in (14, 15) for t, r in dbc_blocks(m[128:])),
          "4K120 TV 40G: 4K100/120 listed RGB, no 4:2:0 block")
    check(i["preferred_mode"] == "3840x2160@60" and m[131] & 0x30 == 0,
          "4K120 TV: preferred 4K60 (TMDS), RGB")
    check(build(t4, fa, au, True, frl=True, color="rgb")[0] == m, "4K120 TV: byte-stable")
    m2, i2 = build(t4, fa, au, True, frl=False, color="rgb")
    hf = [r for t, r in dbc_blocks(m2[128:]) if _is_hf(t, r)]
    check(not i2["frl"] and (3840, 2160, 120, False) not in _keys(kernel_modes(m2)[0])
          and hf == [bytes.fromhex("67d85dc401788000")] and m2 != m,
          "4K120 TV frl off: 600 MHz ceiling, HF-VSDB without FRL, other identity")
    m3, i3 = build(t4, fa, au, False, frl=True, color="rgb")
    check(not i3["frl"] and i3["ceiling_khz"] == 340000, "4K120 TV hdmi20 off: no FRL, 340 MHz")
    m, i = build(sample_4k120_tv(frl=3), fa, au, True, frl=True, color="rgb")
    acc = kernel_modes(m)[0]
    y = [r for t, r in dbc_blocks(m[128:]) if t == 7 and r[1] == 14]
    vdb = [r for t, r in dbc_blocks(m[128:]) if t == 2][0]
    check(y == [bytes([0xE3, 14, 117, 118])] and 118 not in vdb and 97 in vdb and any(
        (x["w"], round(x["hz"])) == (3840, 120) and "4:2:0" in x["src"] for x in acc),
          "4K120 TV 24G: 4K100/120 only as 4:2:0 (no RGB fit), 4K60 RGB")
    m, i = build(sample_4k120_tv(frl=3, cmdb=False), fa, au, True, frl=True, color="rgb")
    check((3840, 2160, 120, False) not in _keys(kernel_modes(m)[0]) and "VIC 118" in " ".join(
        i["dropped"]), "4K120 TV 24G, no 4:2:0 listed: 4K120 removed")
    t8 = sample_8k_tv()
    m, i = build(t8, fa, au, True, frl=True, color="rgb")
    acc, rej = kernel_modes(m)
    k = _keys(acc)
    blk = dbc_blocks(m[128:])
    hf = [r for t, r in blk if _is_hf(t, r)]
    y = [r for t, r in blk if t == 7 and r[1] == 14]
    check(valid(m) and hf == [bytes.fromhex("6dd85dc401788060" "000000000000")],
          "8K TV 48G: HF-VSDB Max_FRL_Rate 6, no DSC, no deep colour")
    check(y == [bytes([0xE2, 14, 199])] and any(
        (x["w"], round(x["hz"])) == (7680, 60) and "4:2:0" in x["src"] for x in acc),
          "8K TV: 8K60 as 4:2:0 only")
    check({(7680, 4320, 24, False), (7680, 4320, 30, False), (3840, 2160, 120, False)} <= k
          and not any(x["w"] > FRL_MAX_W or x["khz"] > FRL_KHZ for x in acc)
          and all("4:2:0" not in x["src"] for x in acc if (x["w"], round(x["hz"])) != (7680, 60)),
          "8K TV: 8K24/30 + 4K120 RGB; 8K100 + 10K removed")
    check(not any(t == 7 and r[1] in (1, 5, 6, 15) for t, r in blk) and i["preferred_mode"] ==
          "3840x2160@60" and all(r[6] & 0x78 == 0 for t, r in blk if t == 3 and r[1:4] == OUI_HDMI),
          "8K TV: no HDR/DV/colorimetry/CMDB, VSDB deep colour cleared, preferred 4K60")
    check(build(t8, fa, au, True, frl=True, color="rgb")[0] == m, "8K TV: byte-stable")
    m, i = build(sample_8k_tv(frl=3), fa, au, True, frl=True, color="rgb")
    k = _keys(kernel_modes(m)[0])
    check(not {(7680, 4320, 60, False), (7680, 4320, 30, False), (3840, 2160, 120, False)} & k
          and (7680, 4320, 24, False) in k, "8K TV 24G: 8K60/30 + 4K120 removed (no fit), 8K24 RGB")
    for c, b0bits, cbits in (("rgb", 0, 0), ("ycbcr", 0x08, 0x20), ("auto", 0x18, 0x30)):
        m, i = build(a1440, fa, au, True, frl=True, color=c)
        check(m[24] & 0x18 == b0bits and m[131] & 0x30 == cbits and i["color"] == c,
              f"colour {c}: block 0 bits {b0bits:#04x}, CTA bits {cbits:#04x}")
    lgm = {c: build(lgd, fa, au, True, frl=True, color=c)[0] for c in COLORS}
    check(lgm["ycbcr"][131] & 0x30 == 0x20 and lgm["auto"][131] & 0x30 == 0x30 and
          len({hashlib.md5(x).hexdigest() for x in lgm.values()}) == 3,
          "colour LG: ycbcr 4:4:4, auto 4:4:4 + 4:2:2, one identity per setting")
    try:
        build(lgd, fa, au, True, color="bgr")
        check(False, "colour unknown: refused")
    except ValueError:
        check(True, "colour unknown: refused")
    import random
    rnd, bad = random.Random(62), []
    for n in range(400):
        e = bytearray(t8 if n % 2 else t4)
        for _ in range(rnd.randint(1, 8)):
            e[rnd.randrange(128, 256) if n % 3 else rnd.randrange(256)] = rnd.randrange(256)
        if n % 4:
            e[128:] = fix_csum(e[128:])
        try:
            mm, _ = build(bytes(e), fa, au, True, frl=True, color="auto")
            kernel_modes(mm)
            if not valid(mm):
                bad.append(f"{n}: invalid output")
        except ValueError:
            pass
        except Exception as x:                  # any other exception = bug
            bad.append(f"{n}: {type(x).__name__} {x}")
    check(not bad, f"corrupt input fuzz (400): ValueError or valid EDID {bad[:2]}")
    short = t8[:128] + _cta([bytes([0x41, 16]), ADB_STEREO, SADB_FLFR, VSDB_DC,
                             bytes.fromhex("63d85dc4")])
    m, i = build(short, fa, au, True, frl=True, color="rgb")
    check(valid(m) and not i["frl"] and not i["hdmi20"], "truncated HF-VSDB: no FRL, no hdmi20")
    os.environ["H96_DISPLAY_COLOR"], os.environ["H96_DISPLAY_FRL"] = "auto", "off"
    check(read_flags() == (False, "auto"), "env trial values before flag files")
    del os.environ["H96_DISPLAY_COLOR"], os.environ["H96_DISPLAY_FRL"]
    import tempfile
    with tempfile.TemporaryDirectory() as home:
        ks = os.path.join(home, ".local/share/kscreen")
        os.makedirs(os.path.join(ks, "outputs"))
        old, other = "0306ced127f63c80d6000e7ea9b8b23d", "1c3d45454510b1d38566fb42e201d7c9"
        new = hashlib.md5(lgm["ycbcr"]).hexdigest()
        out = {"id": old, "mode": {"refresh": 143.9327392578125, "size": {"height": 1440, "width": 2560}},
               "scale": 1.5}
        json.dump(out, open(os.path.join(ks, "outputs", old), "w"))
        json.dump(dict(out, id=other), open(os.path.join(ks, "outputs", other), "w"))
        setup = os.path.join(ks, hashlib.md5(old.encode()).hexdigest())
        json.dump([dict(out, pos={"x": 0, "y": 0})], open(setup, "w"))
        json.dump([dict(out, id=other)], open(os.path.join(ks, hashlib.md5(other.encode()).hexdigest()), "w"))
        w = kscreen_carry(old, new, [home, "/nonexistent"])
        n_out = json.load(open(os.path.join(ks, "outputs", new)))
        n_set = json.load(open(os.path.join(ks, hashlib.md5(new.encode()).hexdigest())))
        check(len(w) == 2 and n_out["id"] == new and n_out["mode"] == out["mode"] and n_out["scale"] == 1.5
              and n_set[0]["id"] == new and n_set[0]["mode"]["refresh"] == 143.9327392578125
              and json.load(open(setup))[0]["id"] == old,
              "kscreen carry: mode/scale copied to new EDID identity, old identity kept")
        check(kscreen_carry(old, old, [home]) == [] and kscreen_carry("f" * 32, new, [home]) == [],
              "kscreen carry: same or unknown identity writes nothing")
    check(display_key(lgd) == "GSM-7765-00000000" and display_key(sony) == "SNY-9c01-01010101"
          and display_key(b"\0" * 128) is None, "display key: MFG-product-serial from base block")
    with tempfile.TemporaryDirectory() as d:
        DISPLAY_DIR, COLOR_FLAG = d, os.path.join(d, "display-color")
        open(os.path.join(d, "GSM-7765-00000000.conf"), "w").write("color=ycbcr\nrange=full\n")
        ml, il = build(lgd, fa, au, True)
        ms, isy = build(sony, fa, au, True)
        check(il["color"] == "ycbcr" and ml[131] & 0x30 == 0x20 and isy["color"] == "rgb"
              and ms == build(sony, fa, au, True, frl=True, color="rgb")[0],
              "per display: LG entry ycbcr, Sony without entry rgb (defaults)")
        open(COLOR_FLAG, "w").write("auto\n")
        check(build(sony, fa, au, True)[1]["color"] == "auto" and build(lgd, fa, au, True)[1]["color"]
              == "ycbcr", "legacy global colour: fallback only for displays without entry")
        DISPLAY_DIR = COLOR_FLAG = "/nonexistent/h96-selftest"

def _cli(argv):
    import argparse
    if argv[1:2] in (["--help"], ["-h"]) or len(argv) < 2:
        print(__doc__)
        return 0
    if argv[1] == "--selftest":
        ok = [True]

        def check(c, msg):
            print(("PASS " if c else "FAIL ") + msg)
            ok[0] &= bool(c)
        selftest(check)
        return 0 if ok[0] else 1
    if argv[1] == "modes":
        e = open(argv[2], "rb").read()
        acc, rej = kernel_modes(e)
        print(f"driver max TMDS {driver_max_khz(e) // 1000} MHz")
        for m in acc:
            print(f"  accept {mode_str(m):32} {m['src']}")
        for m, why in rej:
            print(f"  reject {mode_str(m):32} {m['src']}: {why}")
        return 0
    if argv[1] == "kscreen-carry" and len(argv) >= 4:
        for f in kscreen_carry(argv[2], argv[3], argv[4:] or None):
            print(f)
        return 0
    if argv[1] == "merge":
        ap = argparse.ArgumentParser(prog="edid_merge.py merge")
        ap.add_argument("display")
        ap.add_argument("forced")
        ap.add_argument("out")
        ap.add_argument("--hdmi20", action="store_true")
        ap.add_argument("--safe", action="store_true")
        ap.add_argument("--frl", choices=("on", "off"))
        ap.add_argument("--color", choices=tuple(COLORS))
        a = ap.parse_args(argv[2:])
        fc = find_cta(open(a.forced, "rb").read())
        m, info = build(open(a.display, "rb").read(), open(a.forced, "rb").read(),
                        audio_blocks(fc), a.hdmi20, a.safe,
                        None if a.frl is None else a.frl == "on", a.color)
        open(a.out, "wb").write(m)
        for k, v in info.items():
            print(f"{k}: {v}")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv))
