# kernel-signing

Source-of-record for the custom ECDSA MOK-based kernel/module signing pipeline.

**Do not run from here — deployed copies are canonical. Edit → `./deploy.sh`.**

## What this pipeline does

1. NVIDIA / ZFS / SPL DKMS modules are signed with `/var/lib/dkms/mok.{key,pub}` on every package upgrade via pacman hooks.
2. Custom linux kernels are rebuilt with `CONFIG_SYSTEM_TRUSTED_KEYS` pointing at the same MOK key (Fedora-style), then held via `IgnorePkg` so pacman doesn't clobber them.
3. A weekly timer (`signed-kernels-check`) verifies signatures and logs drift.

## Layout

```
kernel-signing/
├── bin/                                            # → /usr/local/bin/
│   ├── sign-modules                    — sign NVIDIA .ko files for one kernel
│   ├── sign-all-dkms-modules           — catch-all: signs every /usr/lib/modules/*/extramodules
│   ├── signed-kernel-build             — rebuild linux-* from Arch sources with trusted key
│   ├── signed-kernel-ignorepkg-sync    — keep /etc/pacman.conf IgnorePkg list in sync
│   ├── signed-kernels-check            — verify signatures across all installed kernels
│   ├── signed-kernels-rebuild-all      — re-run the build pipeline for every kernel
│   └── refresh-rescue-kernel           — regenerate the rescue UKI
├── etc/pacman.d/hooks/                             # → /etc/pacman.d/hooks/
│   ├── 80-sign-nvidia-modules.hook                 — fires on linux*-nvidia
│   └── 81-sign-all-dkms-modules.hook               — catch-all
├── etc/systemd/system/                             # → /etc/systemd/system/
│   ├── signed-kernels-check.service
│   └── signed-kernels-check.timer
├── deploy.sh
└── README.md
```

All `/usr/local/bin/*` scripts are `chattr +i` after install. `deploy.sh` removes the immutable bit, installs, and re-applies it.

## Build directory (`KERNEL_REBUILD_DIR`)

`signed-kernel-build` clones each kernel into `$KERNEL_REBUILD_DIR/<kernel>`, builds it there and logs to `$KERNEL_REBUILD_DIR/<kernel>.build.log`. `signed-kernels-rebuild-all` installs the packages from that same directory.

- **Default:** `kernel-rebuild` in the build user's home. Run by hand, `signed-kernel-build` uses `$HOME/kernel-rebuild`. `sudo signed-kernels-rebuild-all` uses `~<build user>/kernel-rebuild` (never `/root`), then passes the path to the build explicitly, so the build and the install always use the same tree.
- **Override:** `KERNEL_REBUILD_DIR=/path signed-kernel-build linux612`, or `sudo KERNEL_REBUILD_DIR=/path signed-kernels-rebuild-all`. Set the variable after `sudo`, because sudo drops your environment. `signed-kernels-rebuild-all` passes its own value to the build, so a value set in your shell profile does not apply to it.
- The path must be absolute and contain only letters, digits and `. _ / @ + -`. kbuild cannot build in a path with spaces or colons. The build user must be able to write to it.
- `signed-kernels-rebuild-all` builds as the user in `BUILD_USER` near the top of the script, because makepkg refuses to run as root. Set `BUILD_USER` to your own account before running `./deploy.sh`.

Existing trees need no migration. The default is the same `kernel-rebuild` directory in the build user's home that earlier versions hard-coded. Each run re-clones the kernel, so moving to a new path needs no migration either. Old logs stay in the old directory.

## Related files NOT in this suite (by design)
- `/etc/kernel-signing/combined.pem` — the MOK public key, managed separately with its private half at `/var/lib/dkms/mok.key` (NOT backed up here; kept offline, on separate storage).
- `/etc/dkms/framework.conf` — DKMS config; may have user edits unrelated to signing.

