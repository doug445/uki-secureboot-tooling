#!/bin/bash
# deploy.sh — sync source-of-record into deployed paths.
# Handles chattr +i: unlocks, installs, relocks.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# The weekly check runs as, and notifies, the user who builds kernels:
# $KERNEL_BUILD_USER, else whoever runs this script. Run it as yourself; it
# uses sudo where it needs root. Resolved first, so a refusal installs nothing.
CHECK_USER="${KERNEL_BUILD_USER:-${SUDO_USER:-$(id -un)}}"
check_uid=$(id -u "$CHECK_USER" 2>/dev/null) || { echo "[deploy] no such user: $CHECK_USER" >&2; exit 1; }
if (( check_uid == 0 )); then
    echo "[deploy] the kernel check must run as your desktop user, not root:" >&2
    echo "         run ./deploy.sh as that user, or set KERNEL_BUILD_USER" >&2
    exit 1
fi
CHECK_TIMER="signed-kernels-check@$(systemd-escape -- "$CHECK_USER").timer"

deploy_bin() {
    local name=$1
    local src="$HERE/bin/$name"
    local dst="/usr/local/bin/$name"
    if [[ -f "$dst" ]]; then
        if lsattr "$dst" 2>/dev/null | grep -q '^....i'; then
            echo "  unlock $dst"
            sudo chattr -i "$dst"
        fi
        if ! cmp -s "$src" "$dst"; then
            sudo cp -p "$dst" "$dst.bak-$(date +%s)"
            echo "  backed up $dst"
        fi
    fi
    sudo install -m 0755 -o root -g root "$src" "$dst"
    sudo chattr +i "$dst"
    echo "  installed + locked $dst"
}

echo "[deploy] bin/ scripts..."
for s in sign-modules sign-all-dkms-modules signed-kernel-build \
         signed-kernel-ignorepkg-sync signed-kernels-check \
         signed-kernels-rebuild-all refresh-rescue-kernel; do
    deploy_bin "$s"
done

echo "[deploy] pacman hooks..."
for h in 80-sign-nvidia-modules.hook 81-sign-all-dkms-modules.hook; do
    sudo install -m 0644 -o root -g root "$HERE/etc/pacman.d/hooks/$h" "/etc/pacman.d/hooks/$h"
    echo "  /etc/pacman.d/hooks/$h"
done

echo "[deploy] systemd units..."
for u in signed-kernels-check@.service signed-kernels-check@.timer; do
    sudo install -m 0644 -o root -g root "$HERE/etc/systemd/system/$u" "/etc/systemd/system/$u"
    echo "  /etc/systemd/system/$u"
done
# The check used to be a plain signed-kernels-check.{service,timer} with
# User=will hard-coded. Retire it so it can't run alongside the template,
# unless it was masked on purpose: then leave it, and enable nothing.
skip_enable=0
old_state=$(systemctl is-enabled signed-kernels-check.timer 2>/dev/null || true)
if [[ $old_state == masked* ]]; then
    echo "  signed-kernels-check.timer is masked: leaving it, and NOT enabling $CHECK_TIMER"
    skip_enable=1
elif [[ -e /etc/systemd/system/signed-kernels-check.timer || -e /etc/systemd/system/signed-kernels-check.service ]]; then
    sudo systemctl disable --now signed-kernels-check.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/signed-kernels-check.timer /etc/systemd/system/signed-kernels-check.service
    echo "  MIGRATED: removed signed-kernels-check.{service,timer}; $CHECK_TIMER replaces it"
fi
sudo systemctl daemon-reload
if (( skip_enable )); then
    :
elif [[ $(systemctl is-enabled "$CHECK_TIMER" 2>/dev/null || true) == masked* ]]; then
    echo "  $CHECK_TIMER is masked: not enabling it"
else
    sudo systemctl enable --now "$CHECK_TIMER"
    echo "  enabled $CHECK_TIMER (runs as $CHECK_USER)"
fi

echo "[deploy] done. Verify: ls -la /usr/local/bin/sign*  +  lsattr /usr/local/bin/sign-modules  +  systemctl list-timers 'signed-kernels-check@*'"
