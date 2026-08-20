# Linux Mint — UKI specifics

## Tooling situation

- **Mint 22+ / Ubuntu 24.04+:** `systemd-ukify` is available in the archive.
  Install it with `apt install systemd-ukify`. UKIs are built via `ukify build`.
- **Mint 21 / Ubuntu 22.04 and older:** `systemd` is too old (<253). You'd need
  to either upgrade to Mint 22+ or build `ukify` from source. Recommend the
  upgrade — Mint 21 is on borrowed time.
- **`sbctl` is not packaged for Debian/Mint.** Build from source:
  ```
  sudo apt install -y golang-go make git
  git clone https://github.com/Foxboron/sbctl.git
  cd sbctl && make && sudo install -m755 sbctl /usr/local/bin/sbctl
  ```
  Then run `sbctl create-keys`.

## /boot partition

Mint installers usually put `/boot` on the root filesystem, not on a separate
partition. Phase 30 detects this and routes UKIs to the ESP directly. As long
as the ESP is ≥1GB you're fine for ~3 UKIs. Check with `df -h /efi`.

If the ESP is the tiny 100-300MB Windows-default partition, you may need to
recreate it as a 1GB partition from a live USB before starting.

## Kernel update hook

Apt's kernel postinst hooks live in `/etc/kernel/postinst.d/`. The script
in this directory builds and signs a UKI on every kernel install:

```
sudo install -m755 distro/mint/kernel-postinst-zzz-uki-build \
                   /etc/kernel/postinst.d/zzz-uki-build
```

The `zzz-` prefix is load-bearing. `run-parts` sorts the postinst.d/ chain in
C-locale order — digits sort before letters, so a numerically-prefixed name
(e.g. `90-uki-build`) runs *before* `initramfs-tools`, when `/boot/initrd.img-X`
doesn't exist yet, and the hook silently bails. `zzz-` makes it run after
`zz-systemd-boot`, by which point the initrd is on disk.

Test it without an actual kernel update:
```
sudo run-parts --test /etc/kernel/postinst.d/   # lists, doesn't run
sudo /etc/kernel/postinst.d/zzz-uki-build $(uname -r) /boot/vmlinuz-$(uname -r)
```

### Companion postrm cleanup hook

When apt removes / autoremoves an old kernel, the matching UKI is left orphan
in `/boot/EFI/Linux/`. Install the postrm hook to clean it up and unregister
it from sbctl's signed-files database:

```
sudo install -m755 distro/mint/kernel-postrm-zzz-uki-cleanup \
                   /etc/kernel/postrm.d/zzz-uki-cleanup
```

Smoke test against a fake kernel version (no UKI on disk → silent no-op):
```
sudo /etc/kernel/postrm.d/zzz-uki-cleanup 9.99.99-fake /boot/vmlinuz-9.99.99-fake
```

## Disabling GRUB rebuild

Mint's `update-grub` runs from kernel hooks. After UKIs are stable:
```
sudo apt remove --purge grub-efi-amd64-signed grub-efi-amd64
# Or, less invasive — keep grub installed but stop the hook running:
sudo dpkg-divert --rename --add /etc/kernel/postinst.d/zz-update-grub
```
Note: if you remove grub entirely, signed `grubx64.efi` disappears from the ESP,
so any rescue USB that depends on shim+grub won't chain-load. Keep it installed
unless you're confident.
