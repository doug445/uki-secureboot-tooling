#!/usr/bin/env bash
# Phase 35 — Generate BLS Type #1 entries (loader/entries/*.conf) as a rescue path.
#
# Why: if a UKI fails to boot (bad cmdline, broken initramfs, signing problem),
# the systemd-boot menu still has a working "kernel + initramfs + cmdline" entry
# you can select to recover the system. Without this, a broken UKI leaves you
# with no fallback short of a live USB.
#
# Safe to re-run. Existing entries get overwritten with current cmdline/UUIDs.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_root
detect_distro
detect_partitions

CMDLINE_FILE=/etc/kernel/cmdline
[[ -s "$CMDLINE_FILE" ]] || fail "$CMDLINE_FILE missing — run bin/40-build-ukis.sh once to seed it (or write it manually)"
CMDLINE=$(< "$CMDLINE_FILE")

# BLS entries live in $BOOT/loader/entries (XBOOTLDR if present, else ESP).
if [[ -n "$BOOT_MOUNT" && "$BOOT_FSTYPE" == "vfat" ]]; then
    ENTRY_DIR="$BOOT_MOUNT/loader/entries"
    KERNEL_PREFIX=""        # paths relative to XBOOTLDR root
else
    ENTRY_DIR="$ESP_MOUNT/loader/entries"
    KERNEL_PREFIX=""
fi
mkdir -p "$ENTRY_DIR"
info "Writing BLS entries to $ENTRY_DIR"

# Pick microcode image (Intel or AMD), if present.
ucode=""
for u in /boot/intel-ucode.img /boot/amd-ucode.img; do
    [[ -f "$u" ]] && ucode="$u" && break
done
[[ -n "$ucode" ]] && info "Microcode: $ucode" || warn "No microcode image found in /boot — continuing without"

# initramfs filename pattern is distro-family specific.
case "$DISTRO_FAMILY" in
    arch)   initrd_pattern() { echo "/initramfs-${1}.img"; } ;;
    fedora) initrd_pattern() { echo "/initramfs-${1}.img"; } ;;
    debian) initrd_pattern() { echo "/initrd.img-${1}"; } ;;
esac

n=0
for kver in $(list_installed_kernels); do
    vmlinuz_src="/boot/vmlinuz-${kver}"
    initrd_src="/boot$(initrd_pattern "$kver")"
    if [[ ! -f "$vmlinuz_src" ]]; then
        warn "Skipping $kver — $vmlinuz_src missing"
        continue
    fi
    if [[ ! -f "$initrd_src" ]]; then
        warn "Skipping $kver — $initrd_src missing (UKI build with default_image= disabled?)"
        continue
    fi
    entry="$ENTRY_DIR/${ID}-${kver}-fallback.conf"
    {
        echo "title    ${PRETTY_NAME:-$ID} (${kver}) — BLS fallback"
        echo "version  ${kver}"
        echo "linux    /vmlinuz-${kver}"
        [[ -n "$ucode" ]] && echo "initrd   /$(basename "$ucode")"
        echo "initrd   $(initrd_pattern "$kver")"
        echo "options  ${CMDLINE}"
        echo "sort-key 99-bls-fallback"
    } > "$entry"
    log "Wrote $entry"
    n=$((n+1))
done

[[ $n -gt 0 ]] || fail "No BLS entries written — every kernel was missing a vmlinuz or initramfs"
log "$n BLS fallback entry(ies) written. systemd-boot will list them alongside UKIs."
echo
warn "These entries embed the cmdline as plaintext on $ENTRY_DIR — they are NOT covered"
warn "by Secure Boot signature verification. They are a rescue tool, not a security feature."
warn "Once UKIs are stable, delete them with: rm $ENTRY_DIR/*-fallback.conf"
