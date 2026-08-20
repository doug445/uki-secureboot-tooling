# UKI / Secure Boot Deploy Kit

Distro-aware toolkit for converting a Linux machine to:

- **systemd-boot** as the EFI bootloader (replacing GRUB)
- **Unified Kernel Images (UKIs)** as the boot artifact (kernel + initramfs +
  cmdline signed as one .efi file)
- **UEFI Secure Boot** with your own keys via `sbctl`
- **sd-encrypt** initramfs path for LUKS root (Arch family) — or distro-native
  initramfs (dracut on Fedora, initramfs-tools on Mint) wrapped in a UKI

**Out of scope:** TPM2 sealing, TPM2-backed LUKS auto-unlock, PCR baselining.
The kit is built around passphrase-only LUKS by design.

---

## Supported distros

| Family | IDs handled | initramfs tool | UKI builder |
|--------|-------------|----------------|-------------|
| Arch   | manjaro, arch, endeavouros, garuda, cachyos | mkinitcpio | mkinitcpio (native) |
| Fedora | fedora, nobara, bazzite | dracut | ukify (kernel-install plugin) |
| Debian | linuxmint, ubuntu, debian, pop | initramfs-tools | ukify (apt postinst hook) |

---

## Layout

```
uki-secureboot-kit/
├── README.md            ← you are here
├── DEPLOYMENT.md        ← step-by-step guide for a fresh rig
├── GOTCHAS.md           ← lessons that cost real debug time
├── docs/
│   └── migration-guide.md   long-form, distro-comparison guide
├── bin/                 ← numbered phase scripts (run in order)
│   ├── 00-detect.sh
│   ├── 10-install-prereqs.sh
│   ├── 20-create-keys.sh
│   ├── 30-install-systemd-boot.sh
│   ├── 35-generate-bls-fallback.sh   ← rescue path; do not skip
│   ├── 40-build-ukis.sh
│   ├── 50-sign-everything.sh
│   ├── 60-verify.sh
│   ├── 99-rollback.sh
│   └── lib/common.sh    ← distro/partition detection
├── distro/              ← per-distro templates and update hooks
│   ├── arch/
│   ├── fedora/
│   └── mint/
├── hardening/           ← optional sysctl + cmdline hardening
└── live-usb/            ← scripts for preparing a recovery USB
```

---

## TL;DR

```
sudo bin/00-detect.sh                # report environment, no changes
sudo bin/10-install-prereqs.sh       # install sbctl/ukify/etc
sudo bin/20-create-keys.sh           # sbctl create-keys
sudo bin/30-install-systemd-boot.sh  # bootctl install + loader.conf
sudo bin/35-generate-bls-fallback.sh # rescue entries you can boot if UKI fails
sudo bin/40-build-ukis.sh            # builds standalone initramfs AND UKIs
sudo bin/50-sign-everything.sh       # sbctl sign -s for everything
sudo bin/60-verify.sh                # show state
# REBOOT, pick "Linux Boot Manager" in UEFI menu, confirm UKI boots
# Then enter UEFI firmware: enable Setup Mode → boot → sbctl enroll-keys --microsoft → enable Secure Boot
# Reboot once more, run bin/60-verify.sh again to confirm.
# Once confident, optionally remove the *-fallback.conf BLS entries.
```

See `DEPLOYMENT.md` for the full procedure with reboot points and recovery
checkpoints.

---

## Safety model

**Every conversion preserves a fallback boot path.** Phase 30 backs up your
existing bootloader configs into `backups/<host>-<timestamp>/`. Phase 35 writes
BLS Type #1 entries (`*-fallback.conf`) that systemd-boot lists alongside UKIs;
if the UKI fails to load, you pick the BLS entry and boot the same kernel via
the unsigned-but-functional path. GRUB (where present) stays installed and
signed as a third fallback.

**You are never one bad reboot from a live USB**, provided phase 35 runs and
its output is verified with `sudo bin/60-verify.sh` before reboot.

---

## What the kit does NOT do automatically

- Repartition disks. If `/boot` is on the root filesystem (common on Mint), or
  ext4 (common on Fedora), the kit warns and asks you to plan accordingly.
- Enable Secure Boot in firmware. That's a manual UEFI menu step.
- Enroll keys. Done after first successful systemd-boot test, with `sbctl
  enroll-keys --microsoft`.
- Apply hardening sysctls — those are in `hardening/`, opt-in.
