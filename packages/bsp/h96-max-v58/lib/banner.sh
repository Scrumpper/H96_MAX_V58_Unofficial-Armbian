#!/bin/bash
# banner.sh: shared block-letter header for H96 tools; source it and call h96_banner "S U B T I T L E".
# TTY-gated: skips output under systemd/non-TTY and honours NO_COLOR.

h96_banner() {
    [ -t 1 ] || return 0
    [ -n "${NO_COLOR:-}" ] && return 0
    local sub="${1:-}"
    local B=$'\033[96m' P=$'\033[95m' DIM=$'\033[2m' BOLD=$'\033[1m' X=$'\033[0m'
    printf '%s' "${B}${BOLD}"
    cat <<'ART'

   ██╗  ██╗ █████╗  ██████╗    ██╗   ██╗███████╗ █████╗
   ██║  ██║██╔══██╗██╔════╝    ██║   ██║██╔════╝██╔══██╗
   ███████║╚██████║███████╗    ██║   ██║███████╗╚█████╔╝
   ██╔══██║ ╚═══██║██╔═══██╗    ╚██╗ ██╔╝╚════██║██╔══██╗
   ██║  ██║ █████╔╝╚██████╔╝     ╚████╔╝ ███████║╚█████╔╝
   ╚═╝  ╚═╝ ╚════╝  ╚═════╝       ╚═══╝  ╚══════╝ ╚════╝
ART
    printf '%s\n' "${X}"
    printf '%s%*s%s\n' "${P}${BOLD}" $(( (64 + 25) / 2 )) "  S C R U M P P E R ' S  " "${X}"
    printf '%s%*s%s\n' "${P}${BOLD}" $(( (64 + 39) / 2 )) "  U N O F F I C I A L   A R M B I A N  " "${X}"
    [ -n "$sub" ] && printf '%s%*s%s\n' "${P}${BOLD}" $(( (64 + ${#sub}) / 2 )) "$sub" "${X}"
    printf '%s%*s%s\n' "${DIM}" 47 "H96 Max V58  ·  Rockchip RK3588" "${X}"
    printf '%s  %s%s\n' "${DIM}" "$(printf '─%.0s' $(seq 1 60))" "${X}"
}
