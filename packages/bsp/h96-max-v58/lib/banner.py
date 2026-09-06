"""/usr/local/lib/h96/banner.py

Shared block-letter header for the H96 Max V58 tools, matching the firmware
suite installer. `from banner import banner; banner("S U B T I T L E")`.

The art and colours live HERE and nowhere else.

TTY-gated on purpose: several of these tools also run from systemd units, and
block letters plus escape codes in the journal are noise. Not a TTY, no banner.
NO_COLOR is honoured as well.
"""
import os
import sys

ART = r"""
   ██╗  ██╗ █████╗  ██████╗    ██╗   ██╗███████╗ █████╗
   ██║  ██║██╔══██╗██╔════╝    ██║   ██║██╔════╝██╔══██╗
   ███████║╚██████║███████╗    ██║   ██║███████╗╚█████╔╝
   ██╔══██║ ╚═══██║██╔═══██╗    ╚██╗ ██╔╝╚════██║██╔══██╗
   ██║  ██║ █████╔╝╚██████╔╝     ╚████╔╝ ███████║╚█████╔╝
   ╚═╝  ╚═╝ ╚════╝  ╚═════╝       ╚═══╝  ╚══════╝ ╚════╝
"""

BRAND = (
    "  S C R U M P P E R ' S  ",
    "  U N O F F I C I A L   A R M B I A N  ",
)

B, P, DIM, BOLD, X = "\033[96m", "\033[95m", "\033[2m", "\033[1m", "\033[0m"


def banner(subtitle=""):
    if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
        return
    print(B + BOLD + ART + X)
    for _brand_line in BRAND:
        print(P + BOLD + _brand_line.center(64) + X)
    if subtitle:
        print(P + BOLD + subtitle.center(64) + X)
    print(DIM + "H96 Max V58  ·  Rockchip RK3588".center(64) + X)
    print(DIM + "  " + "─" * 60 + X)
