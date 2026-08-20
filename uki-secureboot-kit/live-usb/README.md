# Live USB Recovery

A recovery USB lets you fix an unbootable system from outside it. Required if
both systemd-boot AND GRUB AND the BLS fallback entries are all broken (rare
but possible if the ESP gets corrupted).

## What you need

| Distro | Recommended live media | Why |
|--------|------------------------|-----|
| Arch family | Manjaro live ISO or Arch ISO | Has `arch-chroot`, `cryptsetup`, mkinitcpio |
| Fedora | Fedora Workstation Live | Has `chroot`, `cryptsetup`, dracut |
| Mint | Mint live ISO | Has `chroot`, `cryptsetup`, initramfs-tools |

You can recover any of the three from any of the live ISOs — but using a live
ISO of the same family means the chroot tools and package commands match.

## Build the recovery USB

1. Flash a live ISO to a USB stick (≥4GB). Tools: `dd`, Etcher, Ventoy, Rufus.
2. After flashing, mount the USB writable partition (Ventoy is easiest — it
   keeps the USB writable while the ISO sits as a file).
3. Copy this entire kit folder to the USB:
   ```
   cp -r ~/Projects/uki-secureboot-kit /run/media/$USER/<usb-label>/
   ```
4. **Copy your machine-specific backups too** — phase 30 wrote them under
   `backups/<host>-<timestamp>/`:
   ```
   cp -r ~/Projects/uki-secureboot-kit/backups \
         /run/media/$USER/<usb-label>/uki-secureboot-kit/
   ```
   Without these, the rollback script has nothing to restore.

## Recovery procedure (sd-encrypt, LUKS root, Btrfs example)

1. Boot live USB.
2. Open a terminal as root.
3. Identify the disks:
   ```
   lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT,PARTLABEL
   ```
4. Unlock LUKS:
   ```
   cryptsetup open /dev/nvme0n1p2 cryptroot
   ```
5. Mount root + boot + ESP:
   ```
   # Btrfs (subvolume @):
   mount -o subvol=@ /dev/mapper/cryptroot /mnt
   # ext4:
   # mount /dev/mapper/cryptroot /mnt

   # Adjust device paths:
   mount /dev/nvme0n1p3 /mnt/boot       # XBOOTLDR if present
   mount /dev/nvme0n1p1 /mnt/efi        # ESP

   # If on Btrfs with subvolumes for /home, /var/log etc., mount them too.

   for d in dev dev/pts proc sys; do mount --bind /$d /mnt/$d; done
   mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars
   ```
6. Enter the chroot:
   ```
   chroot /mnt /bin/bash
   # (Arch live ISOs: arch-chroot /mnt — handles binds for you)
   ```
7. Run the rollback script:
   ```
   bash /run/media/$USER/<usb-label>/uki-secureboot-kit/bin/99-rollback.sh
   ```
   This restores `/etc/fstab`, `/efi/loader/`, `/boot/loader/` from the most
   recent backup snapshot.
8. Rebuild initramfs/UKIs as needed:
   ```
   # Arch:    mkinitcpio -P
   # Fedora:  dracut --force --regenerate-all
   # Mint:    update-initramfs -u -k all
   ```
9. Reinstall the bootloader if needed:
   ```
   bootctl install --esp-path=/efi
   # (or --esp-path=/efi --boot-path=/boot if XBOOTLDR present)
   ```
10. Exit chroot, unmount, reboot:
    ```
    exit
    umount -R /mnt
    reboot
    ```

## Manual recovery without the kit

If you don't have the kit handy, the absolute minimum to recover a system
that booted before the conversion is:

```
# In chroot, restore your distro's stock bootloader path:

# Arch family:
pacman -S --needed grub
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=manjaro
grub-mkconfig -o /boot/grub/grub.cfg

# Fedora:
dnf reinstall grub2-efi-x64 shim-x64
grub2-mkconfig -o /boot/grub2/grub.cfg

# Mint:
apt install --reinstall grub-efi-amd64-signed shim-signed
update-grub
```

Then reboot and pick the GRUB entry from the UEFI boot menu.
