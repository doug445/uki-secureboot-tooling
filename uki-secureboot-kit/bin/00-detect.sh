#!/usr/bin/env bash
# Phase 00 — Detect environment and print what the kit will do.
# Read-only. Run this first on every target rig.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_uefi
detect_distro
detect_partitions

echo
echo "==============================================================================="
echo " UKI/Secure Boot deploy kit — environment report"
echo "==============================================================================="
print_state
echo

# --- compatibility checks -----------------------------------------------
warnings=0

# /boot must be FAT32 to act as XBOOTLDR; common Fedora/Mint installs use ext4.
if [[ -n "$BOOT_FSTYPE" && "$BOOT_FSTYPE" != "vfat" ]]; then
    warn "/boot is $BOOT_FSTYPE (not vfat) — cannot serve as XBOOTLDR."
    warn "Options: (1) reformat /boot as FAT32 + reinstall kernels, or"
    warn "         (2) use a large ESP (≥1GB) and drop UKIs there directly."
    warnings=$((warnings+1))
fi

# ESP at /boot/efi triggers the FAT32 case-insensitive collision bug.
if [[ "$ESP_MOUNT" == "/boot/efi" ]]; then
    warn "ESP mounted at /boot/efi — this triggers the EFI/efi dentry collision."
    warn "Plan to remount ESP at /efi (update /etc/fstab) before building UKIs."
    warnings=$((warnings+1))
fi

# Need free space on the UKI target (≥350MB per kernel).
target=$(uki_output_dir)
target_dev=$(df -P "$(dirname "$target")" 2>/dev/null | awk 'NR==2{print $1}')
free_mb=$(df -Pm "$(dirname "$target")" 2>/dev/null | awk 'NR==2{print $4}')
nkernels=$(list_installed_kernels | wc -l)
need_mb=$(( nkernels * 350 ))
if [[ ${free_mb:-0} -lt $need_mb ]]; then
    warn "Free space on $target_dev is ${free_mb}MB; need ≈${need_mb}MB for $nkernels kernel(s)."
    warnings=$((warnings+1))
fi

# Distro-specific tooling presence
case "$DISTRO_FAMILY" in
    arch)
        command -v mkinitcpio >/dev/null || { warn "mkinitcpio missing"; warnings=$((warnings+1)); }
        ;;
    fedora)
        command -v dracut >/dev/null || { warn "dracut missing"; warnings=$((warnings+1)); }
        command -v ukify >/dev/null || warn "ukify missing — install systemd-ukify (recommended for Fedora)"
        ;;
    debian)
        command -v ukify >/dev/null || warn "ukify missing — needs systemd-ukify (Mint 22 / Ubuntu 24.04+)"
        command -v update-initramfs >/dev/null || warn "update-initramfs missing"
        ;;
esac

command -v sbctl >/dev/null || { warn "sbctl not installed (will install in phase 10)"; }

echo
if [[ $warnings -eq 0 ]]; then
    log "No blockers detected. Proceed to: bin/10-install-prereqs.sh"
else
    warn "$warnings warning(s). Resolve or acknowledge before continuing."
fi
