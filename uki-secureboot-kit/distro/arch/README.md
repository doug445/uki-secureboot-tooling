# Arch family (Manjaro, Arch, EndeavourOS) — UKI specifics

## Tooling
- `mkinitcpio` 40+ builds UKIs natively from per-kernel presets in
  `/etc/mkinitcpio.d/<pkg>.preset`.
- `sbctl` ships a pacman hook (`/usr/share/libalpm/hooks/zz-sbctl.hook`) that
  re-signs anything in its database after every transaction. Once a UKI is
  registered with `sbctl sign -s`, kernel updates require no manual signing.

## Files in this directory
| File | Purpose |
|------|---------|
| `mkinitcpio.conf` | Reference HOOKS+MODULES for sd-encrypt. Drop nvidia entries on non-NVIDIA rigs. |
| `preset.template` | Per-kernel preset producing both standalone initramfs (BLS fallback) and UKI |

## crypttab.initramfs (LUKS root)
sd-encrypt does NOT honor the legacy `cryptdevice=` cmdline. You need either
- `rd.luks.name=<luks-uuid>=<mapper-name> rd.luks.options=<luks-uuid>=discard` in `/etc/kernel/cmdline`, **or**
- an `/etc/crypttab.initramfs` line:
  ```
  <mapper-name>  UUID=<luks-uuid>  -  discard
  ```
  Both work; the cmdline form is preferred because it survives a `crypttab.initramfs` mistake.

## Manjaro-specific
- Kernel packages are named `linux<MAJ><MIN>` (linux66, linux612, linux618).
  Each has its own `/etc/mkinitcpio.d/<pkg>.preset`.
- After conversion, **disable GRUB hooks** to stop pacman from re-installing
  GRUB on every kernel update:
  ```
  pacman -Rns grub  # only after confirming systemd-boot works
  ```
  Or keep grub-mkconfig from running by removing `/etc/default/grub.d/*` overrides.
