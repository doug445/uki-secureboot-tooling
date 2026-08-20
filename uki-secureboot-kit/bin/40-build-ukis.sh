#!/usr/bin/env bash
# Phase 40 — Build a UKI for every installed kernel, distro-aware.
# Reads /etc/kernel/cmdline (creates one from /proc/cmdline if missing — review it!).
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_root
detect_distro
detect_partitions

CMDLINE_FILE=/etc/kernel/cmdline
if [[ ! -s "$CMDLINE_FILE" ]]; then
    warn "$CMDLINE_FILE missing or empty."
    info "Seeding it from /proc/cmdline (stripping initrd= and BOOT_IMAGE=)."
    awk '{
        out=""
        for (i=1; i<=NF; i++) {
            if ($i ~ /^initrd=/)      continue
            if ($i ~ /^BOOT_IMAGE=/)  continue
            out = (out=="") ? $i : out " " $i
        }
        print out
    }' /proc/cmdline > "$CMDLINE_FILE"
    warn "Seeded — REVIEW $CMDLINE_FILE before continuing!"
    cat "$CMDLINE_FILE"
    ask "Use this cmdline as-is?" || fail "Edit $CMDLINE_FILE manually, then re-run."
fi

OUTDIR=$(uki_output_dir)
mkdir -p "$OUTDIR"
info "UKI output: $OUTDIR"

# --- distro dispatch ----------------------------------------------------
build_arch() {
    info "mkinitcpio path — UKIs built via per-kernel presets."
    local kit_root; kit_root="$(dirname "$(readlink -f "$0")")/.."
    local preset_template="$kit_root/distro/arch/preset.template"
    [[ -r "$preset_template" ]] || fail "Missing $preset_template"

    for kver in $(list_installed_kernels); do
        local pkg=""
        case "$kver" in
            *MANJARO*|*-MANJARO*) pkg="${kver%%-x86_64}" ; pkg="linux${pkg//[!0-9]/}" ;;
            *) pkg="linux-$(echo "$kver" | awk -F. '{print $1$2}')" ;;
        esac
        local preset="/etc/mkinitcpio.d/${pkg}.preset"
        if [[ ! -f "$preset" ]]; then
            warn "Preset $preset not found for kernel $kver — skipping."
            continue
        fi
        info "Patching $preset for UKI output → $OUTDIR/${ID}-${kver}.efi"
        cp -a "$preset" "${preset}.bak.$(date +%s)"
        # Keep default_image= so a standalone initramfs is also built — required
        # by the BLS fallback entries from phase 35. Costs ~80MB per kernel.
        # Strip ALL_microcode= (deprecated; microcode hook handles it).
        awk -v out="$OUTDIR/${ID}-${kver}.efi" -v cl="$CMDLINE_FILE" '
            /^ALL_microcode=/ { next }
            /^default_uki=/   { next }
            /^default_options=/ { next }
            { print }
            END {
                print "default_uki=\"" out "\""
                print "default_options=\"--cmdline " cl "\""
            }
        ' "$preset" > "$preset.tmp" && mv "$preset.tmp" "$preset"
    done
    info "Running mkinitcpio -P (builds all presets)..."
    mkinitcpio -P
}

build_fedora() {
    info "Fedora path — using ukify directly (kernel-install plugin recommended for ongoing updates)."
    command -v ukify >/dev/null || fail "ukify missing — install systemd-ukify"
    for kver in $(list_installed_kernels); do
        local vmlinuz="/boot/vmlinuz-${kver}"
        local initrd="/boot/initramfs-${kver}.img"
        [[ -f "$vmlinuz" ]] || { warn "Missing $vmlinuz — skipping $kver"; continue; }
        [[ -f "$initrd" ]] || { warn "Missing $initrd — skipping $kver"; continue; }
        local out="$OUTDIR/${ID}-${kver}.efi"
        info "ukify build → $out"
        ukify build \
            --linux "$vmlinuz" \
            --initrd "$initrd" \
            --cmdline "@${CMDLINE_FILE}" \
            --uname "$kver" \
            --output "$out"
    done
    info "Install kernel-install plugin from distro/fedora/ for ongoing builds — see distro/fedora/README.md"
}

build_debian() {
    info "Debian/Mint path — using ukify directly."
    command -v ukify >/dev/null || fail "ukify missing — install systemd-ukify (Mint 22 / Ubuntu 24.04+)"
    for kver in $(list_installed_kernels); do
        local vmlinuz="/boot/vmlinuz-${kver}"
        local initrd="/boot/initrd.img-${kver}"
        [[ -f "$vmlinuz" ]] || { warn "Missing $vmlinuz — skipping $kver"; continue; }
        [[ -f "$initrd" ]] || { warn "Missing $initrd — skipping $kver"; continue; }
        local out="$OUTDIR/${ID}-${kver}.efi"
        info "ukify build → $out"
        ukify build \
            --linux "$vmlinuz" \
            --initrd "$initrd" \
            --cmdline "@${CMDLINE_FILE}" \
            --uname "$kver" \
            --output "$out"
    done
    info "Install /etc/kernel/postinst.d/ hook from distro/mint/ for ongoing builds."
}

case "$DISTRO_FAMILY" in
    arch)   build_arch ;;
    fedora) build_fedora ;;
    debian) build_debian ;;
esac

echo
log "UKI build complete. Files in $OUTDIR:"
ls -lh "$OUTDIR"
echo "Next: bin/50-sign-everything.sh"
