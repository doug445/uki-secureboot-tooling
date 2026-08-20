#!/usr/bin/env bash
# Phase 20 — Create sbctl Secure Boot keys.
# Does NOT enroll them — enrollment happens after first successful systemd-boot test.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_root
command -v sbctl >/dev/null || fail "sbctl not installed — run bin/10-install-prereqs.sh first"

if [[ -d /etc/secureboot/keys ]] && [[ -n "$(ls -A /etc/secureboot/keys 2>/dev/null)" ]]; then
    warn "Keys already exist at /etc/secureboot/keys — skipping creation."
else
    info "Creating Secure Boot keys (PK / KEK / db) with sbctl..."
    sbctl create-keys
    log "Keys created."
fi

echo
sbctl status
echo
log "Expected after creation: Secure Boot disabled, Setup Mode disabled."
echo "Next: bin/30-install-systemd-boot.sh"
