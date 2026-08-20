# uki-secureboot-tooling

Tooling for a **signed Unified Kernel Image (UKI) + Secure Boot** boot pipeline,
spanning Linux Mint, Fedora, and Arch. Builds UKIs, signs them (and out-of-tree
DKMS modules) against an enrolled `sbctl` **db** key, and keeps the signed UKIs
in sync as kernels and drivers change.

## Layout

| Path | What it is |
|------|------------|
| `uki-secureboot-kit/` | The deployable kit. Numbered install steps in `bin/` (`00-detect` → `99-rollback`), per-distro glue in `distro/{arch,fedora,mint}/`, `hardening/` drop-ins, `live-usb/` recovery notes, plus `DEPLOYMENT.md` and `GOTCHAS.md`. |
| `kernel-signing/` | Arch/pacman kernel + DKMS module signing: `bin/` signers, `etc/pacman.d/hooks/` (sign nvidia + all DKMS modules), a `signed-kernels-check` systemd timer, `deploy.sh`, and `audit-drift.sh`. |
| `kernel-signing-backup/` | **Public** Secure Boot certificates only (`mok.pem`, `combined.pem`) — the enrolled db/MOK certs, no private keys. |
| `live-etc-snapshot/` | Snapshot of the currently-deployed pipeline on the Mint box, under real paths: the kernel `postinst.d`/`postrm.d` UKI build+cleanup hooks, the `initramfs/post-update.d/zz-uki-rebuild` guard hook, `sign-systemd-boot`, `dkms/framework.conf`, and the kernel `cmdline`. |

## The `zz-uki-rebuild` guard hook

`live-etc-snapshot/etc/initramfs/post-update.d/zz-uki-rebuild` closes a real gap:
the UKI builder only runs on **kernel-package** installs, so a **driver-only**
upgrade (e.g. an nvidia DKMS bump) would rebuild the module in `/lib/modules` and
regenerate the initrd, but leave the **signed UKI** carrying the *old* driver —
producing an `NVRM: API mismatch` and a boot that drops to a TTY with no GUI. The
guard hook fires on any initrd regeneration, restores the kernel image from the
`kernel-store` archive, and re-runs the builder so the signed UKI always tracks
the current initrd. It skips kernel-package installs (already handled) to avoid a
double build.

## Security

This is a **public** repo and is scrubbed of secrets. **Never** commit:

- signing **private keys** (`*.key`, `MOK.priv`, `sbctl` `db.key`),
- **LUKS header** dumps (`*.bin` — they hold encrypted master-key material),
- captured host state under `backups/` (machine-id, UUIDs, boot config),
- operational `logs/`.

The `.gitignore` enforces all of the above. Only public certificates and the
tooling scripts themselves are tracked.
