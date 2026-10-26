# shellcheck shell=bash
# Debian Edition pipeline paths; each one can be set from environment. Sourced by pipeline scripts.
H96_REPO=${H96_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
W=${H96_DEB_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/h96-debian-repro}   # scratch trees, tarballs, raw image (outside checkout)
IN=${H96_DEB_IN:-$W/inputs}                        # inputs at paths of build/pins/debian-inputs.tsv name column
EVR=${H96_DEB_EV:-$W/evidence}                     # logs and recorded shas
OUT=${H96_DEB_OUT:-$W/out}                         # image, xz, sums
PINS=${H96_DEB_PINS:-$H96_REPO/build/pins/debian-inputs.tsv}
KEYRING=${H96_REPO_KEYRING:-$H96_REPO/keys/offline-repo-public.gpg}   # offline repo public key
NAME=${H96_DEB_NAME:-H96-MAX-V58_Unofficial-Armbian_v8.0-debian}
V72=$IN/v72-rootfs.tar.zst
# pin NAME: sha256 column of pins file
pin() { awk -F'\t' -v n="$1" '$1==n{print $3; f=1} END{exit !f}' "$PINS"; }
V72SHA=${H96_DEB_V72_SHA:-$(pin v72-rootfs.tar.zst)}
export H96_REPO W IN EVR OUT PINS KEYRING NAME V72 V72SHA
