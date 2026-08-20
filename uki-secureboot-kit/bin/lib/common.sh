#!/usr/bin/env bash
# Shared helpers for the UKI/Secure Boot deploy kit.
# Source this file from numbered phase scripts:
#   . "$(dirname "$0")/lib/common.sh"

# --- color output ---------------------------------------------------------
if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
    B=$'\033[0;34m'; C=$'\033[0;36m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; B=''; C=''; N=''
fi

log()  { printf '%s[OK]%s %s\n'   "$G" "$N" "$*"; }
info() { printf '%s[..]%s %s\n'   "$B" "$N" "$*"; }
warn() { printf '%s[!!]%s %s\n'   "$Y" "$N" "$*" >&2; }
fail() { printf '%s[XX]%s %s\n'   "$R" "$N" "$*" >&2; exit 1; }
ask()  { local q="$1"; local a; read -r -p "$q [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

require_root() { [[ $EUID -eq 0 ]] || fail "Run as root (sudo $0)"; }

# --- distro detection -----------------------------------------------------
# Sets:
#   DISTRO_FAMILY = arch | fedora | debian
#   DISTRO_ID     = manjaro | arch | endeavouros | fedora | linuxmint | ubuntu | debian
#   DISTRO_NAME   = pretty name
detect_distro() {
    [[ -r /etc/os-release ]] || fail "/etc/os-release not readable"
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    case "$DISTRO_ID" in
        arch|manjaro|endeavouros|garuda|cachyos)
            DISTRO_FAMILY=arch ;;
        fedora|nobara|bazzite)
            DISTRO_FAMILY=fedora ;;
        linuxmint|ubuntu|debian|pop|elementary)
            DISTRO_FAMILY=debian ;;
        *)
            # Fall back to ID_LIKE
            case "${ID_LIKE:-}" in
                *arch*)   DISTRO_FAMILY=arch ;;
                *fedora*|*rhel*) DISTRO_FAMILY=fedora ;;
                *debian*|*ubuntu*) DISTRO_FAMILY=debian ;;
                *) fail "Unsupported distro: $DISTRO_ID (ID_LIKE=$ID_LIKE)" ;;
            esac
            ;;
    esac
    export DISTRO_FAMILY DISTRO_ID DISTRO_NAME
}

# --- firmware checks ------------------------------------------------------
require_uefi() {
    [[ -d /sys/firmware/efi ]] || fail "Not booted in UEFI mode — Secure Boot/UKIs require UEFI"
}

# --- partition discovery --------------------------------------------------
# Sets globals:
#   ESP_DEV, ESP_UUID, ESP_MOUNT
#   BOOT_DEV, BOOT_FSTYPE, BOOT_MOUNT  (XBOOTLDR if FAT32, else legacy /boot)
#   ROOT_DEV, ROOT_UUID, ROOT_FSTYPE
#   LUKS_PARENT_DEV, LUKS_PARENT_UUID  (set if root sits on a LUKS mapper)
detect_partitions() {
    ESP_DEV=$(findmnt -no SOURCE /efi 2>/dev/null || findmnt -no SOURCE /boot/efi 2>/dev/null || true)
    [[ -n "$ESP_DEV" ]] || fail "ESP not mounted at /efi or /boot/efi"
    ESP_MOUNT=$(findmnt -no TARGET "$ESP_DEV")
    ESP_UUID=$(blkid -o value -s UUID "$ESP_DEV")
    if [[ "$ESP_MOUNT" != "/efi" ]]; then
        warn "ESP is at $ESP_MOUNT — kit assumes /efi (XBOOTLDR layout). See GOTCHAS.md."
    fi

    BOOT_DEV=$(findmnt -no SOURCE /boot 2>/dev/null || true)
    if [[ -n "$BOOT_DEV" ]]; then
        BOOT_FSTYPE=$(findmnt -no FSTYPE /boot)
        BOOT_MOUNT=/boot
    else
        BOOT_DEV=""; BOOT_FSTYPE=""; BOOT_MOUNT=""
        warn "/boot is on the root filesystem — XBOOTLDR not present"
    fi

    ROOT_DEV=$(findmnt -no SOURCE /)
    ROOT_FSTYPE=$(findmnt -no FSTYPE /)
    ROOT_UUID=$(blkid -o value -s UUID "$ROOT_DEV" 2>/dev/null || true)

    LUKS_PARENT_DEV=""; LUKS_PARENT_UUID=""
    if [[ "$ROOT_DEV" == /dev/mapper/* ]]; then
        local mapper; mapper="${ROOT_DEV#/dev/mapper/}"
        local slave; slave=$(lsblk -nso NAME /dev/mapper/"$mapper" | tail -1)
        if [[ -n "$slave" ]]; then
            LUKS_PARENT_DEV="/dev/$slave"
            LUKS_PARENT_UUID=$(blkid -o value -s UUID "$LUKS_PARENT_DEV" 2>/dev/null || true)
        fi
    fi

    export ESP_DEV ESP_UUID ESP_MOUNT
    export BOOT_DEV BOOT_FSTYPE BOOT_MOUNT
    export ROOT_DEV ROOT_UUID ROOT_FSTYPE
    export LUKS_PARENT_DEV LUKS_PARENT_UUID
}

# --- kernel discovery -----------------------------------------------------
# Returns space-separated list of installed kernel versions.
list_installed_kernels() {
    case "$DISTRO_FAMILY" in
        arch)
            # Manjaro/Arch keep modules at /usr/lib/modules/<kver>
            ls -1 /usr/lib/modules 2>/dev/null | sort -V
            ;;
        fedora|debian)
            ls -1 /lib/modules 2>/dev/null | sort -V
            ;;
    esac
}

# --- ESP/XBOOTLDR helpers -------------------------------------------------
uki_output_dir() {
    # XBOOTLDR if available, else ESP. systemd-boot scans both.
    if [[ -n "$BOOT_MOUNT" && "$BOOT_FSTYPE" == "vfat" ]]; then
        echo "$BOOT_MOUNT/EFI/Linux"
    else
        echo "$ESP_MOUNT/EFI/Linux"
    fi
}

# --- sanity print ---------------------------------------------------------
print_state() {
    info "Distro:        $DISTRO_NAME (family=$DISTRO_FAMILY)"
    info "ESP:           $ESP_DEV  UUID=$ESP_UUID  at $ESP_MOUNT"
    info "/boot:         ${BOOT_DEV:-(on root)} ${BOOT_FSTYPE:+($BOOT_FSTYPE)}"
    info "Root:          $ROOT_DEV ($ROOT_FSTYPE)"
    [[ -n "$LUKS_PARENT_DEV" ]] && info "LUKS parent:   $LUKS_PARENT_DEV  UUID=$LUKS_PARENT_UUID"
    info "Kernels:       $(list_installed_kernels | tr '\n' ' ')"
    info "UKI output:    $(uki_output_dir)"
}
