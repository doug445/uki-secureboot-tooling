# systemd-boot + Secure Boot + UKI Migration Guide

> This document captures a complete, battle-tested migration from GRUB to
> systemd-boot with UEFI Secure Boot and Unified Kernel Images (UKIs). It was derived from
> two live sessions on a Manjaro system (nvme, LUKS2, Btrfs). Use the distro-specific
> sections for package names and tooling differences. The "Gotchas" section at the end
> contains lessons that cost real debugging time — read it before starting.

**What this achieves:** Every byte of the boot chain — bootloader, kernel, initramfs, and
cmdline — is signed and verified by UEFI Secure Boot. Tampering with any component causes
the firmware to refuse to boot.

---

## Architecture Overview

```
UEFI firmware
  └── verifies signature on → systemd-boot (.efi, on ESP)
        └── discovers and verifies signature on → UKI (.efi, on XBOOTLDR)
              └── UKI contains (all signed as one unit):
                    ├── kernel (vmlinuz)
                    ├── initramfs (CPIO image)
                    ├── microcode (Intel/AMD)
                    └── cmdline (embedded, cannot be tampered)
```

**Before UKIs:** Secure Boot only verified vmlinuz. Initramfs, cmdline, and BLS .conf
entries were unsigned — an attacker with physical access could modify the initramfs or
inject kernel parameters.

**After UKIs:** A single signed .efi file contains everything. One tampered byte = boot
refused.

---

## Partition Layout (Target)

| Partition | Role | Filesystem | Mount | Size |
|-----------|------|------------|-------|------|
| pX | ESP (EFI System Partition) | FAT32 | `/efi` | 300MB+ |
| pY | XBOOTLDR (Extended Boot Loader) | FAT32 | `/boot` | 4–10GB |
| pZ | Root (LUKS2 optional) | ext4/btrfs/xfs | `/` | rest |

**Critical:** ESP mounts at `/efi`, NOT `/boot/efi`. See Gotchas section.

UKI files land at: `/boot/EFI/Linux/*.efi`

---

## Distro Comparison Table

| Item | Arch/Manjaro | Fedora | Ubuntu 23.10+ | Linux Mint |
|------|-------------|--------|---------------|------------|
| initramfs tool | mkinitcpio | dracut | initramfs-tools / dracut | initramfs-tools / dracut |
| UKI builder | mkinitcpio 40+ (native) | `ukify` or dracut `--uki` | `ukify` | `ukify` |
| sbctl package | `sbctl` (official) | `sbctl` (Fedora 37+) | `sbctl` (23.10+) | build from source or PPA |
| Package manager | pacman | dnf | apt | apt |
| GRUB package | `grub` | `grub2-efi-x64` | `grub-efi-amd64` | `grub-efi-amd64` |
| Kernel preset/config dir | `/etc/mkinitcpio.d/` | dracut config `/etc/dracut.conf.d/` | `/etc/initramfs-tools/` | `/etc/initramfs-tools/` |
| Typical /boot | FAT32 XBOOTLDR | ext4 (NOT FAT32) | ext4 | ext4 |

> **Fedora note:** Fedora's `/boot` is usually ext4, which cannot serve as XBOOTLDR (must
> be FAT32). You'll need to create a new FAT32 XBOOTLDR partition or use `/boot/efi` as
> the only EFI partition (requires a larger ESP — 1GB+).

---

## Phase 0: Preparation (on running system, before any live USB)

### 0a. Sanity-check your partition layout

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,PARTTYPE,PARTUUID
# or
sudo fdisk -l /dev/nvme0n1   # or sda, sdb, etc.
```

Look for:
- Your ESP (FAT32, partition type EF00 or `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`)
- A separate `/boot` partition (FAT32 for XBOOTLDR, or ext4 on Ubuntu/Fedora)
- Your root partition (LUKS2 or plain)

Record the partition numbers — you'll need them.

### 0b. Check if /boot is a separate partition

```bash
findmnt /boot
# If this returns nothing, /boot is on the root filesystem — you'll need to create XBOOTLDR
# If it returns a device, check its filesystem type
```

**If /boot IS a separate FAT32 partition:** You're close to ready. Confirm its size is ≥4GB
for UKIs (each UKI is 200–350MB; 3 kernels = ~750MB).

**If /boot is ext4/xfs (Fedora):** systemd-boot cannot use this as XBOOTLDR. Either resize
and reformat to FAT32 (risky, data loss possible), or plan to use a large ESP instead.

**If /boot is on root filesystem:** You need to create a new XBOOTLDR partition. This
requires shrinking the root partition — requires live USB. See Phase 1b.

### 0c. Install sbctl and create Secure Boot keys

**Arch/Manjaro:**
```bash
sudo pacman -S sbctl
```

**Fedora:**
```bash
sudo dnf install sbctl
```

**Ubuntu 23.10+ / Mint (if available):**
```bash
sudo apt install sbctl
# If not in repos, build from source:
# https://github.com/Foxboron/sbctl — requires Go
```

**Create keys (do NOT enroll yet — enrollment happens after first successful boot):**
```bash
sudo sbctl create-keys
# Keys stored at /etc/secureboot/keys/
# Owner GUID is generated — record it for reference
sudo sbctl status  # should show: Secure Boot: disabled, Setup Mode: disabled
```

### 0d. Record current GRUB cmdline (you'll embed this in the UKI)

```bash
# From BLS entries (systemd-boot systems):
cat /boot/loader/entries/*.conf | grep "^options"

# From GRUB (current system):
grep "GRUB_CMDLINE_LINUX" /etc/default/grub

# From running system:
cat /proc/cmdline
```

Strip out any `initrd=` parameters and `cryptkey=` entries before embedding.
If you have a keyfile for LUKS auto-unlock, you'll need to migrate away from it
before UKIs (keyfile in initramfs is a security risk on an unencrypted /boot).

---

## Phase 1: Partition Setup

### 1a. If /boot is already a separate FAT32 partition (most setups)

Just verify:
```bash
findmnt /boot               # should show FAT32 device
df -h /boot                 # check it's large enough (≥4GB for UKIs)
sudo blkid /dev/nvme0n1pX  # note the UUID for fstab
```

If the partition is ext4, you'll need to reformat it as FAT32. Back up `/boot` contents
first, then format, then reinstall bootloader. This is safest from a live USB.

### 1b. If /boot is on the root filesystem (create XBOOTLDR from live USB)

This is the complex case. You need to:
1. Shrink root (Btrfs/ext4)
2. Shrink LUKS container (if encrypted)
3. Shrink the GPT partition
4. Create new FAT32 partition in the freed space

**Boot from a live USB** with: `cryptsetup`, `btrfs-progs`/`e2fsprogs`, `dosfstools`, `gdisk`

```bash
# Open LUKS (if encrypted)
sudo cryptsetup open /dev/nvme0n1p2 luks-tmp

# Mount root
sudo mount -o subvol=@ /dev/mapper/luks-tmp /mnt  # Btrfs
# OR
sudo mount /dev/mapper/luks-tmp /mnt               # ext4

# Shrink filesystem by 5GB (adjust for your situation)
# Btrfs:
sudo btrfs filesystem resize -5G /mnt
# ext4 (unmount first):
sudo umount /mnt
sudo e2fsck -f /dev/mapper/luks-tmp
sudo resize2fs /dev/mapper/luks-tmp $(( $(blockdev --getsz /dev/mapper/luks-tmp) - 10485760 ))s

# Shrink LUKS container (while mapper is open)
NEW_SECTORS=$(( $(sudo blockdev --getsz /dev/nvme0n1p2) - 10485760 ))
sudo cryptsetup resize luks-tmp --size $NEW_SECTORS
sudo cryptsetup close luks-tmp

# Shrink GPT partition and create XBOOTLDR
# Get exact sectors first:
sudo sgdisk -p /dev/nvme0n1    # or use fdisk -l

START_P2=<start sector of root partition>
DISK_END=<last usable sector>
XBOOTLDR_SECTORS=8388608   # 4GB; use 20971520 for 10GB
NEW_END_P2=$(( DISK_END - XBOOTLDR_SECTORS - 1 ))
XBOOTLDR_START=$(( NEW_END_P2 + 1 ))

sudo sgdisk \
  -d 2 \
  -n "2:${START_P2}:${NEW_END_P2}" -t "2:8309" -c "2:Linux LUKS" \
  -n "3:${XBOOTLDR_START}:${DISK_END}" \
    -t "3:BC13C2FF-59E6-4262-A352-B275FD6F7172" \
    -c "3:Linux Extended Boot" \
  /dev/nvme0n1
# BC13C2FF... is the GPT type GUID for XBOOTLDR

sudo partprobe /dev/nvme0n1
sudo mkfs.fat -F32 -n LINUXBOOT /dev/nvme0n1p3
sudo blkid /dev/nvme0n1p3   # save UUID
```

---

## Phase 2: systemd-boot Installation

Do this in a chroot from the live USB, or on the running system if you're replacing GRUB
without repartitioning.

### 2a. Mount everything

```bash
# Open LUKS (if encrypted)
sudo cryptsetup open /dev/nvme0n1p2 luks-root

# Mount root
sudo mount -o subvol=@  /dev/mapper/luks-root /mnt   # Btrfs
# OR
sudo mount /dev/mapper/luks-root /mnt                  # ext4

# Mount /boot (XBOOTLDR) and /efi (ESP)
sudo mount --mkdir /dev/nvme0n1p3 /mnt/boot
sudo mount --mkdir /dev/nvme0n1p1 /mnt/efi    # note: /efi not /boot/efi

# Mount subvolumes (Btrfs)
sudo mount -o subvol=@home  /dev/mapper/luks-root /mnt/home
sudo mount -o subvol=@cache /dev/mapper/luks-root /mnt/var/cache
sudo mount -o subvol=@log   /dev/mapper/luks-root /mnt/var/log

# Bind pseudo-filesystems
for d in dev dev/pts proc sys; do sudo mount --bind /$d /mnt/$d; done
sudo mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars

# Enter chroot
sudo chroot /mnt /bin/bash
# On Arch-based live USB: sudo arch-chroot /mnt
```

### 2b. Update /etc/fstab

**Critical: mount ESP at /efi, NOT /boot/efi.** See Gotchas section for why.

```
# XBOOTLDR — kernels, initramfs, UKIs
UUID=<XBOOTLDR_UUID>   /boot   vfat   umask=0077   0 2

# ESP — bootloader only
UUID=<ESP_UUID>        /efi    vfat   umask=0077   0 2
```

Remove or replace any existing `/boot` or `/boot/efi` entries.

### 2c. Install systemd-boot

```bash
bootctl install --esp-path=/efi --boot-path=/boot
```

This places:
- `systemd-bootx64.efi` on the ESP
- `loader/` config directory on the ESP
- `loader/entries/` BLS entry directory on the XBOOTLDR

### 2d. Create loader.conf

**File: `/efi/loader/loader.conf`**
```ini
default @saved
timeout 10
console-mode 0
editor no
```

`console-mode 0` forces 80×25 text — readable on 4K displays. `max` makes the font
microscopic on high-DPI screens.

### 2e. Copy kernel files to /boot (XBOOTLDR)

If kernels are still on the root filesystem:
```bash
cp /boot.old/vmlinuz-*      /boot/    # adjust source path
cp /boot.old/initramfs-*.img /boot/
cp /boot.old/*-ucode.img    /boot/    # intel-ucode.img or amd-ucode.img
```

### 2f. Create BLS entries

**Arch/Manjaro** — `/boot/loader/entries/manjaro-618.conf`:
```ini
title   Manjaro Linux (6.18)
linux   /vmlinuz-6.18-x86_64
initrd  /intel-ucode.img
initrd  /initramfs-6.18-x86_64.img
options cryptdevice=UUID=<LUKS_UUID>:<LUKS_MAPPER>:allow-discards root=/dev/mapper/<LUKS_MAPPER> rw rootflags=subvol=@ quiet apparmor=1 security=apparmor
sort-key 01
```

**Fedora** — `/boot/loader/entries/fedora-<kernel>.conf`:
```ini
title   Fedora Linux (<version>)
linux   /vmlinuz-<version>
initrd  /initramfs-<version>.img
options root=UUID=<ROOT_UUID> ro rhgb quiet
```

**Ubuntu/Mint** — `/boot/loader/entries/ubuntu-<kernel>.conf`:
```ini
title   Ubuntu <version>
linux   /vmmlinuz-<version>-generic
initrd  /initrd.img-<version>-generic
options root=UUID=<ROOT_UUID> ro quiet splash
```

### 2g. Regenerate initramfs (in chroot)

**Arch/Manjaro:**
```bash
mkinitcpio -P
```

**Fedora:**
```bash
dracut --force --kver <kernel-version>
# Or for all installed kernels:
for kver in $(ls /lib/modules); do dracut --force --kver $kver; done
```

**Ubuntu/Mint:**
```bash
update-initramfs -u -k all
```

---

## Phase 3: Sign Everything with sbctl

Do this in the chroot, before first boot.

```bash
# Sign systemd-boot binaries
sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI

# Sign GRUB (keep it working as a fallback during transition)
sbctl sign -s /efi/EFI/<distro>/grubx64.efi     # path varies by distro

# Sign all kernels
sbctl sign -s /boot/vmlinuz-<version>             # repeat for each kernel

# Verify all signatures
sbctl verify
sbctl list-files
```

**Fedora:** Fedora's GRUB binary is at `/efi/EFI/fedora/grubx64.efi`
**Ubuntu/Mint:** At `/efi/EFI/ubuntu/grubx64.efi`

---

## Phase 4: First Boot Test (Secure Boot Still OFF)

1. Exit chroot and unmount: `exit ; sudo umount -R /mnt`
2. Reboot
3. Press the UEFI boot menu key (F12/F11/ESC — varies by board)
4. Select **"Linux Boot Manager"** (systemd-boot)
5. Select your distro entry
6. After login, verify:

```bash
bootctl status          # should show systemd-boot as active loader
findmnt /boot           # should show XBOOTLDR device (nvme0n1p3 or similar)
findmnt /efi            # should show ESP device
cat /proc/cmdline       # verify your options are correct
sudo sbctl verify       # all signed files should show ✓
```

If this works, GRUB is still accessible as Boot0001 fallback via UEFI boot menu.
If systemd-boot fails, select GRUB from the UEFI boot menu to recover.

---

## Phase 5: Enable Secure Boot

### 5a. Enter UEFI firmware, set Setup Mode

1. Reboot → enter UEFI settings (DEL/F2/F10 during POST)
2. Navigate to Security → Secure Boot
3. Select "Delete all Secure Boot variables" or "Reset to Setup Mode"
4. Save and exit (F10)

### 5b. Enroll sbctl keys

```bash
sudo sbctl enroll-keys --microsoft
# --microsoft includes Microsoft's KEK and db certs
# Required for hardware compatibility (Option ROM signing, etc.)
```

### 5c. Enable Secure Boot in firmware

1. Reboot → UEFI settings again
2. Enable Secure Boot (it now has keys to enforce)
3. Save and exit
4. System boots — UEFI verifies systemd-bootx64.efi against your enrolled key

### 5d. Verify

```bash
sudo sbctl status
# Expected:
#   Secure Boot: ✓ Enabled
#   Setup Mode:  ✓ Disabled

bootctl status
# Should show: Secure Boot: enabled (user)
```

---

## Phase 6: UKI Migration

UKIs eliminate the remaining gap: initramfs and cmdline are now verified by Secure Boot.

### 6a. Create the cmdline file

```bash
# Remove cryptkey= if present (keyfile in initramfs is a separate security issue)
# Remove any initrd= parameters (UKIs don't use them)
sudo tee /etc/kernel/cmdline << 'EOF'
<your full cmdline here, one line, no initrd= or cryptkey=>
EOF

# Verify: should be exactly one line
cat /etc/kernel/cmdline
wc -l /etc/kernel/cmdline
```

### 6b. Create UKI output directory on XBOOTLDR

```bash
sudo mkdir -p /boot/EFI/Linux
# Verify it's on the XBOOTLDR (not the ESP):
df /boot/EFI/Linux   # should show the XBOOTLDR device
```

If `df /boot/EFI/Linux` shows the ESP device, your ESP is not mounted at `/efi` — see
Gotchas section before continuing.

### 6c. Configure UKI generation — Arch/Manjaro (mkinitcpio 40+)

Edit each preset in `/etc/mkinitcpio.d/`:

**`/etc/mkinitcpio.d/linux618.preset`:**
```bash
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-6.18-x86_64"
ALL_microcode=(/boot/intel-ucode.img)    # or amd-ucode.img

PRESETS=('default')

default_uki="/boot/EFI/Linux/manjaro-6.18-x86_64.efi"
default_options="--cmdline /etc/kernel/cmdline"
# Note: no default_image= line — UKI embeds the initramfs, so separate .img not needed
```

Repeat for each kernel preset (linux612.preset, linux66.preset, etc.).

To fix the `ALL_microcode` deprecation warning (cosmetic, builds still work):
```bash
# In /etc/mkinitcpio.conf, add 'microcode' to HOOKS before 'encrypt':
HOOKS=(base btrfs udev autodetect modconf kms block keyboard keymap encrypt microcode lvm2 filesystems fsck)
# Then remove ALL_microcode= from all presets
```

Build all UKIs:
```bash
sudo mkinitcpio -P
```

### 6d. Configure UKI generation — Fedora (dracut or ukify)

**Option A: dracut with --uki** (Fedora 39+)

Create `/etc/dracut.conf.d/uki.conf`:
```ini
uefi="yes"
uefi_stub="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
kernel_cmdline="<your cmdline here>"
```

Then regenerate:
```bash
sudo dracut --force --uki /boot/EFI/Linux/fedora-$(uname -r).efi --kver $(uname -r)
```

**Option B: ukify** (systemd 253+)

```bash
sudo ukify build \
  --linux /boot/vmlinuz-$(uname -r) \
  --initrd /boot/initramfs-$(uname -r).img \
  --cmdline @/etc/kernel/cmdline \
  --uname $(uname -r) \
  --output /boot/EFI/Linux/fedora-$(uname -r).efi
```

For automation, create a kernel-install plugin or dracut hook.

### 6e. Configure UKI generation — Ubuntu/Mint (ukify)

`ukify` is available from the `systemd` package (Ubuntu 23.10+):

```bash
# Check if available:
which ukify || dpkg -L systemd | grep ukify

sudo ukify build \
  --linux /boot/vmlinuz-$(uname -r) \
  --initrd /boot/initrd.img-$(uname -r) \
  --cmdline @/etc/kernel/cmdline \
  --uname $(uname -r) \
  --output /boot/EFI/Linux/ubuntu-$(uname -r).efi
```

For ongoing automation with Ubuntu, create a kernel hook in `/etc/kernel/postinst.d/`:

```bash
#!/bin/bash
# /etc/kernel/postinst.d/zzz-uki-build  (zzz- so it runs AFTER initramfs-tools)
set -e
KVER="$1"
ukify build \
  --linux /boot/vmlinuz-${KVER} \
  --initrd /boot/initrd.img-${KVER} \
  --cmdline @/etc/kernel/cmdline \
  --uname ${KVER} \
  --output /boot/EFI/Linux/ubuntu-${KVER}.efi
sbctl sign /boot/EFI/Linux/ubuntu-${KVER}.efi
```

### 6f. Sign the UKIs

```bash
# Sign and register for auto-resign on future updates
sudo sbctl sign -s /boot/EFI/Linux/<distro>-<kernel>.efi
# Repeat for each UKI

# Verify
sudo sbctl verify
```

If `sbctl sign -s` says "already signed" but doesn't register, the file was auto-signed
by the mkinitcpio/dracut hook but not added to the database. Directly edit the database:

```bash
sudo cat /var/lib/sbctl/files.json
# Add entries manually in the same JSON format, or force re-registration:
sudo sbctl sign -s --force /boot/EFI/Linux/...efi  # if --force is available in your version
```

### 6g. Verify systemd-boot discovers the UKIs

```bash
sudo bootctl list 2>&1 | grep -E "(type|title|source)"
```

Expected output includes entries like:
```
type: Boot Loader Specification Type #2 (UKI, .efi)
title: <Distro> (<kernel-version>)
source: /boot//EFI/Linux/<filename>.efi (on the Extended Boot Loader Partition)
```

If you only see Type #1 (.conf) entries, check that the UKIs are in the right directory
and that `/boot` is mounted as the XBOOTLDR (not the ESP).

### 6h. Update loader.conf default before removing BLS entries

The old BLS entry ID may be stored in `@saved`. Replace it with a UKI glob:

```bash
# Temporarily point to the UKI you want as default
sudo sed -i 's/^default.*/default <distro>-<kernel-version>*/' /efi/loader/loader.conf
```

### 6i. Remove old BLS entries and separate initramfs images

Only after verifying UKIs boot successfully:

```bash
# Remove BLS .conf entries
sudo rm /boot/loader/entries/*.conf
sudo ls /boot/loader/entries/   # should be empty

# Remove old separate initramfs images
sudo rm /boot/initramfs-*.img   # Arch/Manjaro
sudo rm /boot/initrd.img-*      # Ubuntu/Mint

# Verify only intel-ucode.img (or amd-ucode.img) remains
sudo ls /boot/*.img

# Rebuild UKIs one more time to confirm clean build without separate images
sudo mkinitcpio -P                              # Arch/Manjaro
# OR regenerate dracut/ukify as appropriate
```

---

## Phase 7: Post-Reboot Verification

After rebooting into a UKI:

```bash
# Confirm you're booting from a UKI (not a BLS entry)
bootctl status | grep -A5 "Current Entry"
# Expected: source path contains EFI/Linux/

# Confirm cmdline has no stray parameters
cat /proc/cmdline
# Must have: cryptdevice= (if LUKS), root=, rootflags= (if Btrfs), NO initrd=, NO cryptkey=

# Confirm Secure Boot is still active
sudo sbctl status
# Expected: Secure Boot: ✓ Enabled, Setup Mode: ✓ Disabled

# Confirm all registered files are signed
sudo sbctl verify

# Restore @saved default (remembers last-booted UKI across reboots)
sudo sed -i 's/^default.*/default @saved/' /efi/loader/loader.conf
```

---

## Ongoing: What Happens on Kernel Updates

**Arch/Manjaro:** pacman updates kernel → mkinitcpio hook runs → UKI rebuilt at
`/boot/EFI/Linux/...efi` → sbctl hook re-signs automatically. No manual steps.

**Fedora:** dnf updates kernel → dracut hook runs → UKI rebuilt → you may need to
manually sign if sbctl isn't integrated with dracut yet.

**Ubuntu/Mint:** apt updates kernel → kernel postinst.d hook runs (if you installed one
in Phase 6e) → UKI rebuilt and signed. Without the hook, you must manually rebuild.

---

## sbctl Registered Files Reference

After a complete setup, `sbctl list-files` should show all of these:

```
# Bootloader (on ESP at /efi)
/efi/EFI/systemd/systemd-bootx64.efi    ✓ Signed
/efi/EFI/BOOT/BOOTX64.EFI               ✓ Signed
/efi/EFI/<distro>/grubx64.efi           ✓ Signed   (GRUB fallback)

# UKIs (on XBOOTLDR at /boot)
/boot/EFI/Linux/<distro>-<kver1>.efi    ✓ Signed
/boot/EFI/Linux/<distro>-<kver2>.efi    ✓ Signed
...

# Kernels (on XBOOTLDR — signed individually as a belt-and-suspenders measure)
/boot/vmlinuz-<kver1>                   ✓ Signed
/boot/vmlinuz-<kver2>                   ✓ Signed
...
```

---

## Gotchas (Lessons Learned the Hard Way)

### 1. FAT32 vfat case-insensitive mount collision

**Problem:** Linux's vfat driver uses case-insensitive dentry hashing. If the ESP is
mounted at `/boot/efi` and you create `/boot/EFI/Linux/` on the XBOOTLDR, the path
silently resolves to the ESP root — because `EFI` and `efi` hash to the same dentry.
Your UKIs end up on the 300MB ESP, not the 10GB XBOOTLDR.

**Symptom:** `df /boot/EFI/Linux/` reports the ESP device, not the XBOOTLDR. UKI builds
fail with "No space left on device" despite df showing free space.

**Fix:** Mount the ESP at `/efi` (not `/boot/efi`). Update `/etc/fstab` accordingly.
This is also the BLS-recommended layout.

```
# Wrong — causes collision:
UUID=<ESP>   /boot/efi   vfat   ...

# Correct:
UUID=<ESP>   /efi        vfat   ...
```

### 2. FAT32 FSINFO stale free space counter

**Problem:** FAT32 maintains a cached free-space count in the FSINFO sector. After
operations that don't update it properly, `df` shows incorrect (usually too optimistic)
free space. A 10GB partition might show 9.3G free when almost full.

**Diagnosis:** Write a test file: `dd if=/dev/zero of=/boot/test.bin bs=1M count=500`
If it fails before 500MB, the actual free space is less than df reports.

**Fix:** Either fix the FSINFO with `fsck.fat -a /dev/nvme0n1p3` (unmounted), or just
trust `du` over `df` for FAT32.

### 3. sbctl sign -s doesn't register if file already signed

**Problem:** `sbctl sign -s /path/to/file` only adds to the database when it actually
performs signing. If the file was already signed (e.g., by the mkinitcpio hook), it
prints "File has already been signed" and exits without registering the path.

**Fix:** Directly edit `/var/lib/sbctl/files.json` to add missing paths, or remove the
signature and re-sign.

### 4. mkinitcpio builds both initramfs AND UKI if default_image= is present

**Problem:** If both `default_image=` and `default_uki=` are set in a preset, mkinitcpio
builds both. The separate initramfs and the UKI coexist on disk simultaneously during the
build, requiring twice the disk space.

**Fix:** Remove `default_image=` from presets once you're committed to UKIs. The initramfs
is embedded inside the UKI and doesn't need to exist as a separate file.

### 5. ALL_microcode deprecation in mkinitcpio 40

**Problem:** `ALL_microcode=(/boot/intel-ucode.img)` in presets is deprecated in
mkinitcpio 40. Builds still work but emit a warning.

**Fix:** Add `microcode` to the HOOKS array in `/etc/mkinitcpio.conf` (before `encrypt`),
then remove `ALL_microcode=` from all presets.

### 6. @saved default pointing to a deleted BLS entry

**Problem:** After removing BLS .conf entries, the `@saved` EFI variable still points to
the old entry ID. systemd-boot may fail to boot or show confusing "reported/absent"
entries.

**Fix:** Before removing BLS entries, update `/efi/loader/loader.conf` to use a UKI glob:
```ini
default <distro>-<kernel>*
```
After confirming UKI boot works, restore `default @saved`.

### 7. Fedora's /boot is ext4, not FAT32

XBOOTLDR must be FAT32. Fedora's default `/boot` partition is ext4, which is incompatible
with the XBOOTLDR GPT type requirement. Options:
- Reformat `/boot` as FAT32 (data loss — back up first, then reinstall kernels)
- Use a large ESP (≥1GB) and place kernels/UKIs there directly
- Create a new FAT32 partition for XBOOTLDR alongside the existing ext4 /boot

### 8. console-mode max makes text tiny on 4K displays

systemd-boot's `console-mode max` uses the highest available framebuffer resolution.
On a 4K display this makes the boot menu unreadable (3-4px font height).

**Fix:** Use `console-mode 0` in loader.conf (forces 80×25 text mode).

---

## Quick Reference: Key File Locations After Migration

| File | Purpose |
|------|---------|
| `/efi/loader/loader.conf` | systemd-boot config |
| `/efi/EFI/systemd/systemd-bootx64.efi` | systemd-boot binary |
| `/efi/EFI/BOOT/BOOTX64.EFI` | UEFI fallback binary |
| `/efi/EFI/<distro>/grubx64.efi` | GRUB fallback |
| `/boot/EFI/Linux/*.efi` | UKIs (XBOOTLDR) |
| `/boot/vmlinuz-*` | Kernels (XBOOTLDR) |
| `/boot/intel-ucode.img` | Microcode (still needed for mkinitcpio source) |
| `/etc/kernel/cmdline` | Cmdline embedded in UKIs |
| `/etc/mkinitcpio.d/*.preset` | mkinitcpio UKI presets (Arch/Manjaro) |
| `/etc/dracut.conf.d/uki.conf` | dracut UKI config (Fedora) |
| `/etc/kernel/postinst.d/zzz-uki-build` | UKI auto-build hook (Ubuntu/Mint) — `zzz-` prefix makes run-parts run it after `zz-systemd-boot`, so the initrd exists when called |
| `/var/lib/sbctl/files.json` | sbctl registered paths database |
| `/etc/secureboot/keys/` | sbctl Secure Boot keys |

---

## Verification Commands Cheat Sheet

```bash
# Boot state
bootctl status                          # active bootloader, Secure Boot state
bootctl list                            # all discovered boot entries
cat /proc/cmdline                       # active cmdline (no initrd=, no cryptkey=)
findmnt /boot                           # XBOOTLDR device
findmnt /efi                            # ESP device

# Secure Boot
sudo sbctl status                       # Secure Boot enabled/disabled, Setup Mode
sudo sbctl verify                       # all registered files signed ✓
sudo sbctl list-files                   # registered paths and sign status

# UKI content
sudo strings /boot/EFI/Linux/*.efi | grep "cryptdevice"  # check embedded cmdline

# EFI boot order
efibootmgr -v                           # all EFI boot entries, active order

# Disk layout
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,PARTUUID
df -h /boot /efi                        # free space on both partitions
```
