#!/usr/bin/env bash
# Phase 99 — Rollback helper.
# Restores fstab and loader configs from the most recent backups/ snapshot.
# Does NOT undo bootctl install (you can leave systemd-boot alongside grub).
# For a *full* recovery from an unbootable system, see live-usb/ instead.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_root
KIT_ROOT="$(dirname "$(readlink -f "$0")")/.."
LATEST=$(ls -1dt "$KIT_ROOT"/backups/*/ 2>/dev/null | head -1 || true)
[[ -n "$LATEST" ]] || fail "No backups found in $KIT_ROOT/backups/"
info "Restoring from: $LATEST"

[[ -f "$LATEST/fstab" ]] && { cp -a "$LATEST/fstab" /etc/fstab; log "/etc/fstab restored"; }
[[ -d "$LATEST/loader" ]] && { rm -rf /efi/loader; cp -a "$LATEST/loader" /efi/loader; log "/efi/loader restored"; }
[[ -d "$LATEST/boot-loader" ]] && { rm -rf /boot/loader; cp -a "$LATEST/boot-loader" /boot/loader; log "/boot/loader restored"; }

warn "UKIs in $(uki_output_dir) NOT removed automatically — delete manually if rolling back to GRUB-only."
warn "If GRUB was your previous bootloader, set it as default via efibootmgr -o, or via UEFI menu."
