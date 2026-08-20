#!/bin/bash
# audit-drift.sh — kernel-signing source vs deployed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
drift=0 missing=0 mismatches=()

# NOTE: /usr/local/bin/sign-* etc. have chattr +i — md5sum reads fine
# without clearing the immutable bit; only writes would be blocked.
pairs=(
    "bin/sign-modules                          /usr/local/bin/sign-modules"
    "bin/sign-all-dkms-modules                 /usr/local/bin/sign-all-dkms-modules"
    "bin/signed-kernel-build                   /usr/local/bin/signed-kernel-build"
    "bin/signed-kernel-ignorepkg-sync          /usr/local/bin/signed-kernel-ignorepkg-sync"
    "bin/signed-kernels-check                  /usr/local/bin/signed-kernels-check"
    "bin/signed-kernels-rebuild-all            /usr/local/bin/signed-kernels-rebuild-all"
    "bin/refresh-rescue-kernel                 /usr/local/bin/refresh-rescue-kernel"
    "etc/pacman.d/hooks/80-sign-nvidia-modules.hook    /etc/pacman.d/hooks/80-sign-nvidia-modules.hook"
    "etc/pacman.d/hooks/81-sign-all-dkms-modules.hook  /etc/pacman.d/hooks/81-sign-all-dkms-modules.hook"
    "etc/systemd/system/signed-kernels-check.service   /etc/systemd/system/signed-kernels-check.service"
    "etc/systemd/system/signed-kernels-check.timer     /etc/systemd/system/signed-kernels-check.timer"
)

for pair in "${pairs[@]}"; do
    read -r src dst <<<"$pair"
    srcfull="$HERE/$src"
    [[ -f "$srcfull" ]] || { echo "MISSING src: $srcfull"; missing=1; continue; }
    [[ -f "$dst"     ]] || { echo "MISSING dst: $dst";     missing=1; continue; }
    a=$(md5sum "$srcfull"      | awk '{print $1}')
    b=$(sudo md5sum "$dst" 2>/dev/null | awk '{print $1}')
    if [[ "$a" != "$b" || -z "$b" ]]; then
        echo "DRIFT: $src != $dst"
        mismatches+=("$src")
        drift=1
    fi
done

if (( drift == 0 && missing == 0 )); then
    echo "[kernel-signing] $(date -Is) — all ${#pairs[@]} pairs match ✓"
    exit 0
fi

echo "[kernel-signing] $(date -Is) — drift=$drift missing=$missing"
if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v notify-send >/dev/null; then
    notify-send -u critical "kernel-signing audit" "${#mismatches[@]} drift, $missing missing
Review ~/Projects/kernel-signing/ vs deployed."
fi
(( missing )) && exit 2
exit 1
