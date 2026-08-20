#!/usr/bin/env bash
# Phase 10 — Install required packages per distro.
# Idempotent. Safe to re-run.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_root
detect_distro

case "$DISTRO_FAMILY" in
    arch)
        info "Arch family — installing sbctl (mkinitcpio is pre-installed on these distros)."
        pacman -S --needed --noconfirm sbctl efibootmgr
        ;;
    fedora)
        info "Fedora family — installing sbctl, ukify, dracut, efibootmgr."
        dnf install -y sbctl systemd-ukify systemd-boot-unsigned dracut efibootmgr
        ;;
    debian)
        info "Debian family (Mint/Ubuntu) — installing systemd-ukify, systemd-boot, efibootmgr."
        apt-get update
        apt-get install -y systemd-ukify systemd-boot efibootmgr
        if ! command -v sbctl >/dev/null; then
            warn "sbctl is not packaged for Debian/Mint."
            warn "Build from source: https://github.com/Foxboron/sbctl"
            warn "Requires: golang, make. After build:"
            warn "  sudo install -m755 sbctl /usr/local/bin/sbctl"
        fi
        ;;
esac

log "Prerequisites installed."
echo "Next: bin/20-create-keys.sh"
