# kernel-signing

Source-of-record for the custom ECDSA MOK-based kernel/module signing pipeline.

**Do not run from here — deployed copies are canonical. Edit → `./deploy.sh`.**

## What this pipeline does

1. NVIDIA / ZFS / SPL DKMS modules are signed with `/var/lib/dkms/mok.{key,pub}` on every package upgrade via pacman hooks.
2. Custom linux kernels are rebuilt with `CONFIG_SYSTEM_TRUSTED_KEYS` pointing at the same MOK key (Fedora-style), then held via `IgnorePkg` so pacman doesn't clobber them.
3. A weekly timer (`signed-kernels-check@<user>.timer`) compares the installed kernels with upstream and notifies that user when a rebuild is due.

## Layout

```
kernel-signing/
├── bin/                                            # → /usr/local/bin/
│   ├── sign-modules                    — sign NVIDIA .ko files for one kernel
│   ├── sign-all-dkms-modules           — catch-all: signs every /usr/lib/modules/*/extramodules
│   ├── signed-kernel-build             — rebuild linux-* from Arch sources with trusted key
│   ├── signed-kernel-ignorepkg-sync    — keep /etc/pacman.conf IgnorePkg list in sync
│   ├── signed-kernels-check            — compare installed kernels with upstream PKGBUILDs
│   ├── signed-kernels-rebuild-all      — re-run the build pipeline for every kernel
│   └── refresh-rescue-kernel           — regenerate the rescue UKI
├── etc/pacman.d/hooks/                             # → /etc/pacman.d/hooks/
│   ├── 80-sign-nvidia-modules.hook                 — fires on linux*-nvidia
│   └── 81-sign-all-dkms-modules.hook               — catch-all
├── etc/systemd/system/                             # → /etc/systemd/system/
│   ├── signed-kernels-check@.service               — template: instance = user
│   └── signed-kernels-check@.timer
├── deploy.sh
└── README.md
```

All `/usr/local/bin/*` scripts are `chattr +i` after install. `deploy.sh` removes the immutable bit, installs, and re-applies it.

## Build directory (`KERNEL_REBUILD_DIR`)

`signed-kernel-build` clones each kernel into `$KERNEL_REBUILD_DIR/<kernel>`, builds it there and logs to `$KERNEL_REBUILD_DIR/<kernel>.build.log`. `signed-kernels-rebuild-all` installs the packages from that same directory.

- **Default:** `kernel-rebuild` in the build user's home. Run by hand, `signed-kernel-build` uses `$HOME/kernel-rebuild`. `sudo signed-kernels-rebuild-all` uses `~<build user>/kernel-rebuild` (never `/root`), then passes the path to the build explicitly, so the build and the install always use the same tree.
- **Override:** `KERNEL_REBUILD_DIR=/path signed-kernel-build linux612`, or `sudo KERNEL_REBUILD_DIR=/path signed-kernels-rebuild-all`. Set the variable after `sudo`, because sudo drops your environment. `signed-kernels-rebuild-all` passes its own value to the build, so a value set in your shell profile does not apply to it.
- The path must be absolute and contain only letters, digits and `. _ / @ + -`. kbuild cannot build in a path with spaces or colons. The build user must be able to write to it.
- The build user is described in the next section.

Existing trees need no migration. The default is the same `kernel-rebuild` directory in the build user's home that earlier versions hard-coded. Each run re-clones the kernel, so moving to a new path needs no migration either. Old logs stay in the old directory.

## Build user and weekly check (`KERNEL_BUILD_USER`)

makepkg refuses to run as root, so `signed-kernels-rebuild-all` builds each kernel as an unprivileged user. That user is `KERNEL_BUILD_USER` if set, otherwise the account that ran `sudo` (or `doas`). It refuses to run when it can't tell, for example in a root shell from `su -`, or when the answer is root. Run it with `sudo` from your own account, or use `sudo KERNEL_BUILD_USER=name signed-kernels-rebuild-all`.

The weekly check is a template unit, `signed-kernels-check@<user>.timer`. It runs as that user and notifies them. `./deploy.sh` enables it for `KERNEL_BUILD_USER`, or otherwise for the account running `deploy.sh`. Run `deploy.sh` as yourself, not with `sudo`: it calls `sudo` where it needs root, and it refuses to set the check up for root.

**Migrating from the old timer.** Earlier versions installed `signed-kernels-check.service` and `.timer` with `User=will` hard-coded. On its next run, `deploy.sh` disables and removes those two units, enables `signed-kernels-check@<user>.timer` in their place, and prints `MIGRATED: …`. If the old timer was masked, `deploy.sh` leaves it masked, enables nothing, and says so. The unit's `StateDirectory=` makes `/var/lib/signed-kernels` writable by the check user.

`signed-kernel-ignorepkg-sync` runs as root with no session of its own. It notifies every logged-in user who has a session bus and a UID of at least `UID_MIN`.

## Related files NOT in this suite (by design)
- `/etc/kernel-signing/combined.pem` — the MOK public key, managed separately with its private half at `/var/lib/dkms/mok.key` (NOT backed up here; kept offline, on separate storage).
- `/etc/dkms/framework.conf` — DKMS config; may have user edits unrelated to signing.

