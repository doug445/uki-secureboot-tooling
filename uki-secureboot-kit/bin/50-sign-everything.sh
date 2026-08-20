#!/usr/bin/env bash
# Phase 50 — Sign systemd-boot binaries and all UKIs with sbctl.
# Run before enabling Secure Boot in firmware.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_root
detect_distro
detect_partitions
command -v sbctl >/dev/null || fail "sbctl missing"

# --- bootloader binaries ------------------------------------------------
candidates=(
    "$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi"
    "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
)
case "$DISTRO_FAMILY" in
    fedora) candidates+=("$ESP_MOUNT/EFI/fedora/grubx64.efi" "$ESP_MOUNT/EFI/fedora/shimx64.efi") ;;
    debian) candidates+=("$ESP_MOUNT/EFI/ubuntu/grubx64.efi" "$ESP_MOUNT/EFI/ubuntu/shimx64.efi") ;;
    arch)
        for d in arch manjaro endeavouros garuda; do
            [[ -f "$ESP_MOUNT/EFI/$d/grubx64.efi" ]] && candidates+=("$ESP_MOUNT/EFI/$d/grubx64.efi")
        done
        ;;
esac

for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
        info "sbctl sign -s $f"
        sbctl sign -s "$f" || warn "Failed to sign $f"
    fi
done

# --- UKIs ---------------------------------------------------------------
OUTDIR=$(uki_output_dir)
shopt -s nullglob
for u in "$OUTDIR"/*.efi; do
    info "sbctl sign -s $u"
    sbctl sign -s "$u" || warn "Failed to sign $u"
done

# --- distro-resident vmlinuz (belt + suspenders) -----------------------
for v in /boot/vmlinuz-*; do
    [[ -f "$v" ]] || continue
    info "sbctl sign -s $v"
    sbctl sign -s "$v" || true
done

echo
log "Signing complete. Verifying..."
sbctl verify || warn "Some files unsigned — review above."
echo
log "If clean, run bin/60-verify.sh, then enroll keys & enable Secure Boot in firmware."
