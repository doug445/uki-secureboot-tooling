#!/bin/bash
# deploy.sh — sync source-of-record into deployed paths.
# Handles chattr +i: unlocks, installs, relocks.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

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
for u in signed-kernels-check.service signed-kernels-check.timer; do
    sudo install -m 0644 -o root -g root "$HERE/etc/systemd/system/$u" "/etc/systemd/system/$u"
done
sudo systemctl daemon-reload
sudo systemctl enable --now signed-kernels-check.timer

echo "[deploy] done. Verify: ls -la /usr/local/bin/sign*  +  lsattr /usr/local/bin/sign-modules"
