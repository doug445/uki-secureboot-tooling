#!/usr/bin/env bash
# Phase 30 — Install systemd-boot and write loader.conf.
# Prereqs: ESP mounted at /efi (preferred) or /boot/efi.
#          /boot is FAT32 XBOOTLDR (recommended) — kit will warn otherwise.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_root
require_uefi
detect_distro
detect_partitions
print_state
echo

# Backup directory next to this script's parent
BACKUP_ROOT="$(dirname "$(readlink -f "$0")")/../backups/$(hostname)-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_ROOT"
info "Backups → $BACKUP_ROOT"

# --- back up anything we might overwrite --------------------------------
cp -a /etc/fstab "$BACKUP_ROOT/fstab" 2>/dev/null || true
[[ -d /efi/loader ]] && cp -a /efi/loader "$BACKUP_ROOT/loader" 2>/dev/null || true
[[ -d /boot/loader ]] && cp -a /boot/loader "$BACKUP_ROOT/boot-loader" 2>/dev/null || true
log "Backups taken."

# --- install systemd-boot ------------------------------------------------
if [[ -n "$BOOT_MOUNT" && "$BOOT_FSTYPE" == "vfat" ]]; then
    info "Installing systemd-boot with XBOOTLDR layout (esp=$ESP_MOUNT, boot=$BOOT_MOUNT)..."
    bootctl install --esp-path="$ESP_MOUNT" --boot-path="$BOOT_MOUNT"
else
    info "Installing systemd-boot to ESP only (no XBOOTLDR)..."
    bootctl install --esp-path="$ESP_MOUNT"
fi
log "systemd-boot installed."

# --- write loader.conf ---------------------------------------------------
LOADER_CONF="$ESP_MOUNT/loader/loader.conf"
info "Writing $LOADER_CONF"
cat > "$LOADER_CONF" <<'EOF'
default  @saved
timeout  10
console-mode 0
editor   no
EOF
log "loader.conf written."

# --- post-install state --------------------------------------------------
echo
bootctl status || true
echo
log "Verify above shows systemd-boot installed and Secure Boot in Setup Mode (or disabled)."
echo "Next: bin/40-build-ukis.sh"
