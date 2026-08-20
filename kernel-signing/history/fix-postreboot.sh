#!/usr/bin/env bash
# Post-reboot triage for 2026-04-21 A-grade hardening rollout.
# Run from root shell: bash /home/will/fix-postreboot.sh
# Safe reversible fixes only. All output tee'd to /home/will/fix-report.txt.

set +e
LOG=/home/will/fix-report.txt
exec > >(tee "$LOG") 2>&1

C_BOLD=$'\e[1m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_BAD=$'\e[31m'; C_DIM=$'\e[2m'; C_RESET=$'\e[0m'
section() { printf '\n%s=== %s ===%s\n' "$C_BOLD" "$1" "$C_RESET"; }
fix()     { printf '  %s[fix]%s %s\n' "$C_WARN" "$C_RESET" "$1"; }
pass()    { printf '  %s[ok]%s %s\n' "$C_OK" "$C_RESET" "$1"; }
fail()    { printf '  %s[!!]%s %s\n' "$C_BAD" "$C_RESET" "$1"; }

if [[ $EUID -ne 0 ]]; then
    echo "must be run as root (in your su - shell)"
    exit 1
fi

printf '%sPost-reboot triage — %s%s\n' "$C_BOLD" "$(date '+%Y-%m-%d %H:%M %Z')" "$C_RESET"

# ---------- 1. sudo diagnosis ----------
section "1. sudo failure diagnosis"
echo "--- visudo -c ---"
visudo -c
echo "--- journalctl _COMM=sudo this boot ---"
journalctl -b 0 _COMM=sudo --no-pager | tail -20
echo "--- pam_audit in stack? ---"
grep -E 'audit|unix' /etc/pam.d/sudo /etc/pam.d/system-auth 2>/dev/null | head -20

# ---------- 2. audit-rules failure → likely sudo killer ----------
section "2. audit-rules.service (likely culprit)"
systemctl status audit-rules.service --no-pager -n 20
echo "--- journal ---"
journalctl -u audit-rules.service -b 0 --no-pager | tail -30
echo "--- current audit state ---"
auditctl -s 2>&1
echo "--- hardening.rules content ---"
cat /etc/audit/rules.d/hardening.rules 2>&1
echo

# SAFE FIX: if -e 2 (immutable) is set, and audit-rules service is failed,
# remove the immutable flag. Rules stay loaded; only the lock goes away.
# This is reversible: re-add -e 2 later after stabilizing.
if grep -qE '^\s*-e\s+2' /etc/audit/rules.d/hardening.rules 2>/dev/null \
   && ! systemctl is-active --quiet audit-rules.service; then
    fix "removing '-e 2' from /etc/audit/rules.d/hardening.rules (makes rules mutable)"
    cp /etc/audit/rules.d/hardening.rules /etc/audit/rules.d/hardening.rules.bak-pre-fix
    sed -i -E 's/^\s*-e\s+2/# -e 2 # removed 2026-04-21 post-reboot — re-add after verify/' \
        /etc/audit/rules.d/hardening.rules
    augenrules --load 2>&1
    systemctl reset-failed audit-rules.service auditd 2>/dev/null
    systemctl restart auditd 2>&1
    systemctl start audit-rules.service 2>&1
    sleep 1
    if systemctl is-active --quiet audit-rules.service; then
        pass "audit-rules.service now active"
    else
        fail "audit-rules.service still failing — see journal above"
    fi
fi

# ---------- 3. systemd-modules-load failure ----------
section "3. systemd-modules-load.service"
systemctl status systemd-modules-load.service --no-pager -n 20
echo "--- journal ---"
journalctl -u systemd-modules-load.service -b 0 --no-pager | tail -20
echo "--- modules-load.d configs ---"
for d in /etc/modules-load.d /usr/lib/modules-load.d /run/modules-load.d; do
    [[ -d $d ]] && { echo "[$d]"; ls -la "$d" 2>/dev/null; }
done
echo "--- unsigned module rejections this boot ---"
journalctl -k -b 0 --no-pager \
  | grep -iE 'module verification failed|PKCS#7|Loading of [^ ]+ is rejected|unsigned module|module [^ ]+ not found' \
  | tail -30
echo
echo "Decision: do NOT auto-fix. Identify the module above, then either:"
echo "  (a) sign it with your MOK key and re-run modprobe, or"
echo "  (b) remove from /etc/modules-load.d if it was an optional autoload"

# ---------- 4. snapd failure ----------
section "4. snapd.service"
systemctl status snapd.service --no-pager -n 15
journalctl -u snapd.service -b 0 --no-pager | tail -20
echo
echo "Decision: snapd commonly fails under lockdown=integrity because snap"
echo "confinement hot-loads AppArmor policies into the kernel's securityfs."
echo "If you don't use snap packages actively, safe to disable:"
echo "  systemctl disable --now snapd snapd.socket snapd.apparmor 2>/dev/null"

# ---------- 5. USBGuard + mouse rescue ----------
section "5. USBGuard state + mouse rescue"
systemctl status usbguard --no-pager -n 10
echo "--- daemon config (relevant keys) ---"
grep -E '^(InsertedDevicePolicy|PresentDevicePolicy|ImplicitPolicyTarget|IPCAllowedUsers|RestoreControllerDeviceState)' \
    /etc/usbguard/usbguard-daemon.conf
echo "--- current device list ---"
usbguard list-devices
echo "--- block/reject events this boot ---"
journalctl -u usbguard.service -b 0 --no-pager | grep -iE 'block|reject|denied' | tail -20

# SAFE FIX: allow any currently-blocked device permanently
echo
blocked_ids=$(usbguard list-devices 2>/dev/null | awk '$2 == "block" {gsub(":",""); print $1}')
if [[ -n "$blocked_ids" ]]; then
    while read -r id; do
        [[ -z "$id" ]] && continue
        fix "allowing blocked device id=$id permanently"
        usbguard allow-device "$id" --permanent 2>&1
    done <<< "$blocked_ids"
else
    pass "no blocked devices — if mouse still dead it's not USBGuard"
fi

# ---------- 6. usbguard-lock-hook (user service) ----------
section "6. usbguard-lock-hook.service (user)"
# run as will, using their user bus
runuser -u will -- env XDG_RUNTIME_DIR=/run/user/1000 \
    systemctl --user status usbguard-lock-hook.service --no-pager -n 20 2>&1 | head -40
echo "--- journal ---"
runuser -u will -- env XDG_RUNTIME_DIR=/run/user/1000 \
    journalctl --user -u usbguard-lock-hook.service -b 0 --no-pager 2>&1 | tail -30
echo
echo "Decision: do NOT auto-fix. If the hook crashed on boot, note the"
echo "traceback above. Most likely cause: dbus session not yet available"
echo "at hook startup. Fix candidates (after we see the traceback):"
echo "  - add 'After=dbus.socket graphical-session.target' to unit"
echo "  - add a retry loop in the Python dbus code"

# ---------- 7. drkonqi coredumps ----------
section "7. KDE coredumps this boot"
coredumpctl list --since '1 hour ago' 2>/dev/null | head -20
echo "Run 'coredumpctl info <PID>' or 'coredumpctl gdb <PID>' for details."

# ---------- 8. Lockdown posture (should still be live) ----------
section "8. Lockdown posture (expected: integrity)"
echo "lockdown: $(cat /sys/kernel/security/lockdown)"
echo "sig_enforce: $(cat /sys/module/module/parameters/sig_enforce)"
echo "cmdline flags: $(grep -oE 'lockdown=\S+|module\.sig_enforce=\S+' /proc/cmdline | tr '\n' ' ')"

# ---------- Summary ----------
section "POST-FIX FAILED UNITS"
systemctl --failed --no-legend
echo
echo "[report saved to $LOG]"
echo "When you come back to Claude, I'll read $LOG to see what's left."
