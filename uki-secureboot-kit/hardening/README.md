# Optional Hardening

These configs are unrelated to the UKI/Secure Boot conversion itself —
they're sysctl and coredump tweaks that pair well with a hardened boot chain.
Apply only after you've confirmed the system boots cleanly via UKI.

## Files

| File | Apply to | Effect |
|------|----------|--------|
| `90-kernel-hardening.conf` | `/etc/sysctl.d/90-kernel-hardening.conf` | kptr_restrict, dmesg_restrict, kexec_load_disabled, BPF JIT hardening, etc |
| `coredump-disable-storage.conf` | `/etc/systemd/coredump.conf.d/no-storage.conf` | Disables core dump storage (credential leak prevention) |

## Apply

```
sudo install -m644 hardening/90-kernel-hardening.conf  /etc/sysctl.d/
sudo install -m644 hardening/coredump-disable-storage.conf /etc/systemd/coredump.conf.d/no-storage.conf
sudo sysctl --system
```

## Cmdline hardening (optional, embed in UKI)

These params can be appended to `/etc/kernel/cmdline` before phase 40 builds
the UKI. They survive in the embedded cmdline and are covered by Secure Boot
signature verification (an attacker can't add or remove them without breaking
the signature).

```
init_on_alloc=1                  # zero-initialize page allocations
slab_nomerge                     # don't merge slab caches (reduces UAF reach)
vsyscall=none                    # disable legacy vsyscall page (ROP gadget source)
debugfs=off                      # disable debugfs entirely
page_alloc.shuffle=1             # randomize free-list ordering
randomize_kstack_offset=on       # per-syscall kernel stack offset
```

NOT recommended without testing on the specific rig:
- `lockdown=integrity` — requires shim+MOK support; many UEFIs won't display
  MokManager. Test before committing.
- `module.sig_enforce=1` — locks out unsigned modules entirely. Combined with
  the NVIDIA module-signing setup, this is excellent. Without it, NVIDIA users
  fall back to nouveau on Secure Boot.

After editing the cmdline:
```
sudo bin/40-build-ukis.sh
sudo bin/50-sign-everything.sh
sudo bin/35-generate-bls-fallback.sh   # rewrite BLS entries to match
```
