# kernel-signing

Source-of-record for the custom ECDSA MOK-based kernel/module signing pipeline. See memory `project_signed_kernel_pipeline.md` and `project_module_signing.md` for the full rationale.

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

All `/usr/local/bin/*` scripts are `chattr +i` after install (per `project_signed_kernel_pipeline.md`). `deploy.sh` removes the immutable bit, installs, and re-applies it.

## Related files NOT in this suite (by design)
- `/etc/kernel-signing/combined.pem` — the MOK public key, managed separately with its private half at `/var/lib/dkms/mok.key` (NOT backed up here; lives in a sealed drive per `project_module_signing.md`).
- `/etc/dkms/framework.conf` — DKMS config; may have user edits unrelated to signing.

## Backups of MOK key material
`~/Projects/tpm2-uki-migration/backups/mok.{key,pem}` (outside this repo because it predates this convention and contains different key material from the Asahi migration).
