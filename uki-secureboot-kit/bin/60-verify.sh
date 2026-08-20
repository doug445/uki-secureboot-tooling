#!/usr/bin/env bash
# Phase 60 — Verification cheat-sheet, runnable.
# Read-only. Run after every reboot when validating.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

detect_distro
detect_partitions

section() { printf '\n%s== %s ==%s\n' "$C" "$*" "$N"; }

section "Bootloader status"
bootctl status 2>/dev/null | sed -n '1,40p' || true

section "Active cmdline"
cat /proc/cmdline
echo
grep -qE '(^| )(initrd=|cryptkey=)' /proc/cmdline && warn "Stray initrd=/cryptkey= in cmdline" || log "No stray initrd= or cryptkey="

section "Mounts"
findmnt /efi  2>/dev/null || true
findmnt /boot 2>/dev/null || true

section "Boot entries discovered by systemd-boot"
bootctl list 2>/dev/null | grep -E '(type|title|source)' | head -40 || true

section "Secure Boot state"
if command -v sbctl >/dev/null; then
    sbctl status
    echo
    sbctl verify || warn "Unsigned files registered — review."
fi

section "EFI boot order"
efibootmgr -v 2>/dev/null | head -20 || true

section "UKIs on disk"
ls -lh "$(uki_output_dir)" 2>/dev/null || warn "No UKI directory"

echo
log "Verification done."
