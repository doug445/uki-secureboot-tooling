# Deployment Guide

End-to-end procedure for converting a single rig. Read fully before starting.

## Live-USB requirements

**The conversion itself runs entirely from the booted, working system.**
systemd-boot installs alongside GRUB without touching it; UKIs build from the
running kernel modules; sbctl creates and manages keys in-place. None of
phases 00–60 require external media.

Live USB is only needed in three situations:

1. **Repartitioning before phase 30** — and only on rigs that need it. Skip on
   most boxes; the kit avoids repartitioning by routing UKIs to the ESP root
   when no XBOOTLDR exists. You only need a live USB when you want to:
   - Convert Fedora's ext4 `/boot` to FAT32 XBOOTLDR (optional — the
     ESP-only fallback works fine for ≤3 kernels on a ≥1GB ESP).
   - Shrink an existing root partition to carve out a new XBOOTLDR.
   - Enlarge a too-small ESP (Mint installers sometimes leave you with the
     Windows-default 100–300MB partition; UKIs won't fit, ~350MB each).
   You can't shrink the disk you're booted from, so this part needs live media.

2. **Disaster recovery after a failed boot** — only if all three fallbacks
   fail simultaneously: UKI broken, BLS `*-fallback.conf` broken, and GRUB
   binary on ESP missing/corrupt. The kit's safety design makes this nearly
   impossible from a single bad change. See `live-usb/README.md`.

3. **ESP relocation from `/boot/efi` → `/efi`** — edge case. Usually doable
   on the live system: `umount /boot/efi`, edit fstab, `mkdir /efi`,
   `mount -a`. Only needs live USB if `/boot` is somehow nested in a way
   that won't unmount cleanly.

### Per-distro likelihood

| Distro | Likely needs live USB? |
|--------|------------------------|
| **Manjaro / Arch family** | No. ESP at `/efi`, FAT32 `/boot` (XBOOTLDR) typical, in-place conversion clean. |
| **Fedora** | No, **if** you accept ESP-only UKI placement (≥1GB ESP recommended). Yes, **if** you want a true XBOOTLDR (need to reformat ext4 `/boot`). |
| **Linux Mint / Ubuntu** | No, **if** ESP is ≥1GB. Yes, **if** the installer left you with a 100–300MB Windows-default ESP. |

Run `sudo bin/00-detect.sh` first — it reports your ESP/boot layout and free
space and tells you which path applies.

## Pre-flight (do once per rig, in your normal session)

1. **Take a system snapshot.** Whatever you use — Timeshift on Mint, Snapper
   on Fedora, btrfs send on Manjaro — take it now. Log the snapshot ID.
2. **Note your current cmdline:** `cat /proc/cmdline > ~/cmdline.before` — you
   want this for sanity-checking what the UKI ends up embedding.
3. **Confirm UEFI mode:** `[ -d /sys/firmware/efi ] && echo OK`. Legacy BIOS
   systems cannot use Secure Boot or systemd-boot.
4. **Prepare a recovery USB.** See `live-usb/README.md`. You want this in your
   pocket before phase 30.

## Phase-by-phase

Each numbered script under `bin/` is idempotent and prints what it's about to
do. Run them in order.

| Phase | Script | What changes | Reboot after? |
|-------|--------|--------------|---------------|
| 00 | `00-detect.sh` | Nothing — read-only environment report | No |
| 10 | `10-install-prereqs.sh` | Installs `sbctl`, `ukify`, etc | No |
| 20 | `20-create-keys.sh` | Creates `/etc/secureboot/keys/` | No |
| 30 | `30-install-systemd-boot.sh` | Writes `systemd-bootx64.efi` to ESP, writes `loader.conf` | No (don't yet) |
| 35 | `35-generate-bls-fallback.sh` | Writes `*-fallback.conf` BLS entries | No |
| 40 | `40-build-ukis.sh` | Builds initramfs AND UKIs for every kernel | No |
| 50 | `50-sign-everything.sh` | Signs bootloader + UKIs + vmlinuz with sbctl | No |
| 60 | `60-verify.sh` | Read-only state report | — |
| ⏸  | **REBOOT into systemd-boot, pick UKI entry** | First-boot test, Secure Boot OFF | Yes |
| ⏸  | **UEFI menu: Setup Mode → reboot → `sbctl enroll-keys --microsoft` → UEFI menu: enable Secure Boot** | Activates verification | Yes (twice) |
| 60 | `60-verify.sh` again | Confirm Secure Boot enabled, all signed | — |

## Reboot checkpoint #1 (after phase 50)

1. Reboot.
2. At UEFI POST, hit your boot-menu key (F12 / F11 / Esc, varies).
3. Select **"Linux Boot Manager"** — that's systemd-boot.
4. The systemd-boot menu shows entries. Pick a UKI entry first (usually the
   first one), confirm boot succeeds, login, run `bin/60-verify.sh`.
5. If the UKI fails to boot: at the systemd-boot menu, pick the matching
   `*-fallback.conf` BLS entry instead. You'll boot via the standalone
   kernel+initramfs path. Investigate the UKI issue from the running system.
6. If systemd-boot itself fails to boot: at the UEFI boot menu, select GRUB
   (still present as a Boot####). You're fully recovered without a live USB.

## Reboot checkpoint #2 (enabling Secure Boot)

1. Reboot into UEFI firmware (DEL/F2/F10 during POST).
2. Security → Secure Boot → "Reset to Setup Mode" (or "Delete all variables").
3. Save & exit. System boots — Setup Mode is now active.
4. Login. Run:
   ```
   sudo sbctl enroll-keys --microsoft
   ```
   The `--microsoft` flag includes Microsoft's KEK and db certs. Required for
   firmware-signed Option ROMs, dual-boot, etc.
5. Reboot into UEFI firmware. Re-enable Secure Boot. Save & exit.
6. System boots with full Secure Boot verification.
7. Run `sudo bin/60-verify.sh`. Expect:
   ```
   Secure Boot: ✓ Enabled
   Setup Mode:  ✓ Disabled
   ```

## Reboot checkpoint #3 (cleanup, optional)

After several successful boots / a couple kernel updates:
- Delete `*-fallback.conf` BLS entries to remove the unsigned-cmdline
  attack surface:
  ```
  sudo rm /boot/loader/entries/*-fallback.conf      # or /efi/loader/entries/
  ```
- Optionally remove GRUB if you're confident:
  ```
  Arch:    sudo pacman -Rns grub
  Fedora:  sudo dnf remove grub2-efi-x64
  Mint:    sudo apt remove --purge grub-efi-amd64-signed grub-efi-amd64
  ```
  Skip this if you ever boot rescue media that depends on shim+grub.

## Per-distro notes

| Distro | Read this | Hook installer |
|--------|-----------|----------------|
| Arch family | `distro/arch/README.md` | sbctl pacman hook is installed automatically; no extra hook needed |
| Fedora | `distro/fedora/README.md` | `sudo install -m755 distro/fedora/90-uki-build.install /etc/kernel/install.d/` |
| Linux Mint | `distro/mint/README.md` | `sudo install -m755 distro/mint/kernel-postinst-zzz-uki-build /etc/kernel/postinst.d/zzz-uki-build` (must sort AFTER `zz-systemd-boot` so initrd exists) — also install `kernel-postrm-zzz-uki-cleanup` to `/etc/kernel/postrm.d/` to remove orphan UKIs on kernel removal |

## Recovery

If a kernel update breaks UKI build:
- Boot the BLS fallback entry from systemd-boot menu (still working — uses
  the latest standalone initramfs).
- Investigate from the running system.

If systemd-boot itself is corrupted:
- Boot GRUB from UEFI menu (still installed and signed).

If the ESP is wiped or both bootloaders are broken:
- See `live-usb/README.md` for the live-USB recovery procedure.

If the LUKS unlock prompt never appears (sd-encrypt config issue):
- Boot the BLS fallback entry. The standalone initramfs may use a different
  unlock path that still works.
- If both fail, boot live USB, mount system, restore `/etc/mkinitcpio.conf`,
  `/etc/kernel/cmdline`, `/etc/crypttab.initramfs` from
  `backups/<host>-<timestamp>/`.
