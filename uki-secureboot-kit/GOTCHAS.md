# Gotchas

Battle-tested footguns. Read before deploying.

## 1. ESP at `/boot/efi` triggers FAT32 dentry collision

Linux's vfat driver hashes `EFI` and `efi` to the same dentry. If the ESP is
mounted at `/boot/efi` and you create `/boot/EFI/Linux/`, the path silently
resolves to the ESP root. Your UKIs land on the (often 300MB) ESP, not the
XBOOTLDR.

**Symptom:** `df /boot/EFI/Linux/` shows the ESP device. UKI builds fail with
"No space left on device" while `df /boot` shows free space.

**Fix:** Mount ESP at `/efi` instead. Update `/etc/fstab` accordingly. Phase
30 warns when it sees the bad layout, but does not auto-fix it.

## 2. Fedora's `/boot` is ext4, not FAT32

XBOOTLDR partitions must be FAT32. Fedora ships ext4. The kit's phase 30
detects this and routes UKIs to the ESP root instead. Make sure your ESP is
≥1GB (≥350MB per kernel). If it's the standard 300MB Windows-default partition,
plan a re-partition before starting.

## 3. systemd-cryptsetup ignores `cryptdevice=`

The legacy `encrypt` initramfs hook reads `cryptdevice=UUID=…:mapper:opts`.
The `sd-encrypt` hook (what UKIs prefer) ignores it entirely and reads
`rd.luks.name=` / `rd.luks.options=` from cmdline, or `/etc/crypttab.initramfs`.
Mix them up and the system boots to a Dracut-style emergency shell.

## 4. `sbctl sign -s` doesn't register if file is already signed

If a file was signed by an automated hook (mkinitcpio's sbctl hook, ukify
build hook), `sbctl sign -s /path` prints "already signed" and **does not**
add the path to its database. Future re-signs will skip it.

**Fix:** Either edit `/var/lib/sbctl/files.json` directly, or strip the
signature and re-sign:
```
sbattach --remove /path/to/file.efi
sbctl sign -s /path/to/file.efi
```

## 5. `console-mode max` on a 4K display = unreadable boot menu

systemd-boot defaults to the largest available framebuffer. On 4K displays
the boot menu font is 3-4 pixels tall.

**Fix:** `console-mode 0` in `loader.conf` forces 80×25 text mode. Phase 30
sets this by default.

## 6. `default @saved` pointing to a deleted BLS entry

After deleting `*-fallback.conf` entries, the EFI variable storing
`@saved` may still reference the old entry ID, causing systemd-boot to
display "absent" or fail to boot.

**Fix:** Before deleting BLS entries, set `loader.conf` to a UKI glob:
```
default <distro>-*
```
Then after confirming UKI boot works, restore `default @saved`.

## 7. Mint 21 / Ubuntu 22.04: `ukify` doesn't exist

Their systemd is too old (<253). Either upgrade to Mint 22 / Ubuntu 24.04, or
build `ukify` from source. The kit will warn but won't try to install on these.

## 8. NVIDIA modules unsigned under Secure Boot

When you enable Secure Boot, the kernel refuses to load any module that isn't
signed against a key in the kernel's trust store. NVIDIA's prebuilt `.ko`
modules are not signed against your sbctl key.

**Workaround:** Sign them yourself with a MOK (Machine Owner Key) — see
`~/Projects/tpm2-uki-migration/scripts/sign-modules.sh` for a working example
from the original Manjaro setup. The kit doesn't include this by default
because it requires kernel-module key infrastructure that's distro-specific.

If you skip module signing, NVIDIA modules just won't load — system still
boots, you fall back to nouveau or framebuffer.

## 9. GRUB hooks rebuilding bootloader on kernel update

`grub-mkconfig` (Mint), `grub2-mkconfig` (Fedora), grub pacman hooks (Arch)
keep regenerating GRUB's config every kernel update. This doesn't break
systemd-boot (it lives at `/efi/EFI/systemd/`, GRUB at `/efi/EFI/<distro>/`),
but it does waste cycles and may overwrite `/efi/EFI/BOOT/BOOTX64.EFI`.

**Fix:** Either remove GRUB after UKIs are stable, or mask the hooks. See
each distro's README in `distro/`.

## 10. EFI var quota exhaustion

Some firmwares limit the EFI variable store to ~64KB. `sbctl enroll-keys`
writes ~10KB of variables. If you've accumulated other tools writing here
(rEFInd, custom boot menus, prior sbctl runs), you can hit the cap.

**Fix:** `efivar -L` lists current usage. `efivar -d -n <var>` deletes one.
Clean up before enrolling.

## 11. Cmdline change doesn't take effect

`/etc/kernel/cmdline` is the **source**; the cmdline lives **embedded inside
the UKI**. Editing the file does nothing until you rebuild and re-sign the UKI.
```
# After editing /etc/kernel/cmdline:
sudo bin/40-build-ukis.sh
sudo bin/50-sign-everything.sh
sudo bin/35-generate-bls-fallback.sh   # regenerate BLS entries with new cmdline too
```

## 12. fwupd holds /boot in a private mount namespace — invisible EBUSY

When reformatting `/boot` (e.g. ext4 → FAT32 XBOOTLDR conversion on Fedora /
Ubuntu / Mint), `mkfs.fat`, `wipefs`, `blkdiscard`, even `mount` may fail with
`Device or resource busy` — and `findmnt`, `/proc/mounts`, `lsof`, `fuser -mv`,
`/sys/block/<dev>/holders/`, `inflight` all show **nothing**. `flock -x`
succeeds (advisory locks work) but anything using `O_EXCL` fails.

**Cause:** `fwupd` (firmware update daemon) mounts `/boot` and `/boot/grub2`
in its own mount namespace at startup to scan for SPI/UEFI capsule artifacts.
The mount holds an exclusive bdev claim that's invisible from the host
namespace.

**Diagnose:**
```
sudo grep -l <devname> /proc/*/mountinfo
# A fwupd PID in the result = there's the holder.
sudo lsns -t mnt | grep fwupd
```

**Fix:** stop fwupd for the duration of the operation:
```
sudo systemctl stop fwupd.service
sudo mkfs.fat -F32 /dev/<boot-partition>     # or wipefs / mkfs / mount
sudo systemctl start fwupd.service
```

This is a strong candidate for "first thing to try" any time you get unexplained
EBUSY on a `/boot`-related block device with no visible holders.

## 13. kernel-install layout=bls duplicates kernels under /boot/<machine-id>/

When you install systemd-boot on a distro that ships `kernel-install` with
default `layout=auto` (Mint, Ubuntu, Fedora), every kernel gets copied a
second time into `/boot/<machine-id>/<kver>/{linux,initrd}` and a BLS
Type #1 `*.conf` entry is written. With this kit's UKI flow:

- ~110 MB per kernel of duplicate disk usage on `/boot`
- The duplicate `linux` file is *not* signed by sbctl (only `/boot/vmlinuz-X` is),
  so under Secure Boot those BLS entries fail to boot — but they still appear
  in the systemd-boot menu, looking like real entries.

**Fix:** disable kernel-install's layout work (your `install.d/` plugins still
run):
```
echo 'layout=none' | sudo tee /etc/kernel/install.conf
```

Then clean up any already-deployed copies:
```
sudo rm /boot/loader/entries/<machine-id>-*.conf
sudo rm -rf /boot/<machine-id>
```
