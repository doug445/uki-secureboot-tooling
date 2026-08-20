# Fedora — UKI specifics

## Two big differences from Arch family

1. **`/boot` is ext4 by default**, not FAT32. XBOOTLDR requires FAT32.
   - Easiest path: do **not** create XBOOTLDR. Use a large ESP (≥1GB) and put
     UKIs directly under `/efi/EFI/Linux/`. Phase 30 detects this and falls
     back automatically.
   - Alternative #1 (no live USB): reformat `/boot` as FAT32 **in place**.
     Achievable on the running system because `/boot` can be unmounted.
     See "In-place /boot conversion" below — it's the recommended route if
     your ESP is too small for ≥3 UKIs.
   - Alternative #2 (live USB): boot a live USB, back up `/boot`, reformat
     it as FAT32, change its GPT type GUID to `BC13C2FF-59E6-4262-A352-B275FD6F7172`
     (XBOOTLDR), restore contents.
2. **`dracut` builds initramfs**, not mkinitcpio. UKIs build with `ukify`
   (preferred) or `dracut --uki`.

## Stop kernel-install from creating duplicate kernel layouts

By default, Fedora's `kernel-install` uses `layout=bls` and copies kernels
to `/boot/<machine-id>/<kver>/{linux,initrd}`, plus writes a BLS Type #1
`*.conf` entry. With our UKI flow this is **wasted disk** (~110 MB per
kernel) and adds entries to the systemd-boot menu that point at vmlinuz
copies the kit hasn't signed (so they fail under Secure Boot).

Set kernel-install to no-op layout — your `/etc/kernel/install.d/` plugins
(including `90-uki-build.install`) still run, but kernel-install itself
won't copy kernels around or write extra BLS entries:

```
echo 'layout=none' | sudo tee /etc/kernel/install.conf
```

Already-deployed duplicates (if any) — clean up after the switch:
```
sudo rm /boot/loader/entries/<machine-id>-*.conf
sudo rm -rf /boot/<machine-id>
```

## Kernel-install integration (the UKI build hook)

Drop `90-uki-build.install` (in this directory) into `/etc/kernel/install.d/`
to make every `dnf update kernel` rebuild + sign the matching UKI:

```
sudo install -m755 distro/fedora/90-uki-build.install \
                   /etc/kernel/install.d/90-uki-build.install
```

The plugin handles **both** `kernel-install add` (build + sign UKI) and
`kernel-install remove` (delete UKI + unregister from sbctl). No separate
removal hook needed.

Smoke test against the running kernel:
```
sudo /etc/kernel/install.d/90-uki-build.install add $(uname -r) /lib/modules/$(uname -r)/vmlinuz
ls /boot/EFI/Linux/  # should show fedora-$(uname -r).efi
```

## In-place /boot conversion (ext4 → FAT32 XBOOTLDR)

Doable from the running system; no live USB needed.

**Pre-flight gotcha**: `fwupd` (firmware update daemon) mounts `/boot` and
`/boot/grub2` in its **private mount namespace** for SPI/UEFI capsule
detection. From the host namespace this is invisible — `findmnt`,
`/proc/mounts`, `lsof`, `fuser`, `/sys/block/<dev>/holders/` all show
nothing. But `mkfs.fat`, `wipefs`, `blkdiscard`, even `mount` will fail
on `/dev/<boot>` with `Device or resource busy` because fwupd holds an
exclusive bdev claim through its namespaced mount.

Verify the situation:
```
sudo grep -l <boot-device> /proc/*/mountinfo
# If you see a fwupd PID — that's the holder.
```

Procedure (on the running system, single shot — don't reboot mid-way):

```bash
# 1. Snapshot whatever you have (timeshift, snapper, btrfs send, etc.)

# 2. Move the ESP off /boot/efi → /efi (avoid the FAT32 case-fold collision
#    documented in GOTCHAS #1 once /boot becomes FAT32).
sudo umount /boot/efi
sudo mkdir /efi
sudo sed -i 's|/boot/efi|/efi|' /etc/fstab
sudo mount /efi

# 3. Backup /boot to root fs
sudo mkdir -p /var/backups/boot-pre-uki
sudo cp -a /boot/. /var/backups/boot-pre-uki/

# 4. Retype the partition to XBOOTLDR + reformat
sudo sgdisk -t <N>:BC13C2FF-59E6-4262-A352-B275FD6F7172 \
            -c <N>:"Linux Extended Boot" /dev/<disk>

sudo systemctl stop fwupd.service          # ← critical, see above
sudo umount /boot
sudo mkfs.fat -F32 -n LINUXBOOT /dev/<boot-partition>
sudo systemctl start fwupd.service

# 5. Update fstab UUID, mount, restore
NEW_UUID=$(sudo blkid -o value -s UUID /dev/<boot-partition>)
sudo sed -i "s|^UUID=<old-boot-uuid>.*|UUID=${NEW_UUID}\t/boot\tvfat\tumask=0077,shortname=mixed,utf8\t0\t2|" /etc/fstab
sudo systemctl daemon-reload
sudo mount /boot
sudo cp -a /var/backups/boot-pre-uki/{vmlinuz-*,initramfs-*.img,config-*,System.map-*} /boot/

# 6. Reinstall GRUB so it picks up the new layout (still useful as fallback)
sudo grub2-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=fedora --recheck
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

After this the kit's phases (00 → 60) work as designed.

## dracut fallback (if you'd rather skip ukify)

```
sudo install -m644 distro/fedora/dracut-uki.conf /etc/dracut.conf.d/uki.conf
sudo dracut --force --uki /efi/EFI/Linux/fedora-$(uname -r).efi --kver $(uname -r)
```

## Disabling Fedora's GRUB-rebuild hooks

After UKIs are stable, prevent `grub2-mkconfig` from re-running on package
updates:
```
sudo dnf remove grub2-tools-extra      # removes the kernel hook
# OR keep grub installed but mask:
sudo systemctl mask grub2-mkconfig.service 2>/dev/null || true
```
GRUB itself can stay on the ESP as a fallback — its `.efi` is signed in
phase 50, so Secure Boot still trusts it. Remove fully when confident:
```
sudo dnf remove grub2-efi-x64 grub2-efi-x64-modules shim-x64
sudo rm -rf /efi/EFI/fedora /boot/grub2
```
