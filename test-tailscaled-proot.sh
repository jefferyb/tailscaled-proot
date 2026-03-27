#!/bin/bash
# Regression tests for tailscaled-proot
#
# Runs through all commands and verifies correct behavior.
# Exits 0 if all tests pass, 1 if any fail.
#
# WARNING: This will stop/start the daemon and remove/reinstall binaries
#          during testing. It restores everything at the end.
#          It does NOT run --purge (Tailscale state is always preserved).
#
# Usage:
#   ./test-tailscaled-proot.sh                     # test the installed script
#   ./test-tailscaled-proot.sh ./tailscaled-proot   # test a local copy

set -uo pipefail

SCRIPT="${1:-tailscaled-proot}"
PASS=0
FAIL=0
TESTS=()

red()   { echo -e "\033[1;31m$*\033[0m"; }
green() { echo -e "\033[1;32m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

pass() {
    PASS=$((PASS + 1))
    TESTS+=("$(green PASS) $1")
}

fail() {
    FAIL=$((FAIL + 1))
    TESTS+=("$(red FAIL) $1")
}

# Run a command, capture output and exit code, then run checks against them.
# Usage: run_and_check "test group" cmd [args...]
# After calling, use $OUT (combined stdout+stderr) and $RC (exit code).
OUT=""
RC=0
_RUN_TMP=$(mktemp)
trap 'rm -f "$_RUN_TMP"' EXIT
run() {
    "$@" > "$_RUN_TMP" 2>&1 && RC=0 || RC=$?
    OUT=$(cat "$_RUN_TMP")
}

check_exit() {
    local name="$1" expected="$2"
    if [ "$RC" -eq "$expected" ]; then pass "$name"; else fail "$name (expected exit $expected, got $RC)"; fi
}

check_contains() {
    local name="$1" pattern="$2"
    if echo "$OUT" | grep -qE "$pattern"; then pass "$name"; else fail "$name (pattern not found: $pattern)"; fi
}

check_not_contains() {
    local name="$1" pattern="$2"
    if echo "$OUT" | grep -qE "$pattern"; then fail "$name (pattern unexpectedly found: $pattern)"; else pass "$name"; fi
}

check() {
    local name="$1"; shift
    if "$@" 2>/dev/null; then pass "$name"; else fail "$name"; fi
}

count_daemons() { pgrep tailscaled 2>/dev/null | wc -l; }
daemon_running() { pgrep tailscaled &>/dev/null; }
daemon_pid() { pgrep tailscaled 2>/dev/null | head -1; }
bashrc_marker_count() { grep -c "tailscaled-proot" ~/.bashrc 2>/dev/null || echo 0; }

bold ""
bold "============================================"
bold "  tailscaled-proot regression tests"
bold "  Script: $SCRIPT"
bold "============================================"
echo ""

# ------------------------------------------------------------------
bold "[Section 1] Help, version, and error handling"
# ------------------------------------------------------------------

run "$SCRIPT"
check_exit "no args exits 0" 0
check_contains "no args shows help" "Usage:"

run "$SCRIPT" help
check_exit "help exits 0" 0
check_contains "help shows usage" "Usage:"
check_contains "help shows --purge" "\-\-purge"

run "$SCRIPT" --help
check_exit "--help exits 0" 0

run "$SCRIPT" -h
check_exit "-h exits 0" 0

run "$SCRIPT" --version
check_exit "--version exits 0" 0
check_contains "--version shows version" "tailscaled-proot"

run "$SCRIPT" -v
check_exit "-v exits 0" 0
check_contains "-v shows version" "tailscaled-proot"

run "$SCRIPT" boguscmd
check_exit "unknown command exits 1" 1
check_contains "unknown shows error" "Unknown command"

echo ""

# ------------------------------------------------------------------
bold "[Section 2] Status (before any changes)"
# ------------------------------------------------------------------

run "$SCRIPT" status
check_exit "status exits 0" 0
check_contains "status shows CLI version" "tailscale.*CLI"
check_contains "status shows daemon version" "tailscaled.*daemon"
check_contains "status shows daemon running" "Daemon.*running"
check_contains "status shows socket" "Socket:"
check_contains "status shows auto-start" "Auto-start:"

INITIAL_MARKERS=$(bashrc_marker_count)

echo ""

# ------------------------------------------------------------------
bold "[Section 3] Uninstall (keep config)"
# ------------------------------------------------------------------

run "$SCRIPT" uninstall
check_exit "uninstall exits 0" 0
check_contains "uninstall says Uninstalled" "Uninstalled"
check_contains "uninstall preserves config msg" "Config and state preserved"
check "daemon stopped after uninstall" test "$(count_daemons)" -eq 0
check "CLI binary removed" test ! -f /usr/bin/tailscale
check "daemon binary removed" test ! -f /usr/sbin/tailscaled
check "state dir preserved" test -d /var/lib/tailscale

echo ""

# ------------------------------------------------------------------
bold "[Section 4] Uninstall again (idempotent)"
# ------------------------------------------------------------------

run "$SCRIPT" uninstall
check_exit "uninstall again exits 0" 0
check_contains "uninstall again says clean" "Nothing to uninstall"
check "bashrc markers unchanged" test "$(bashrc_marker_count)" -eq "$INITIAL_MARKERS"

echo ""

# ------------------------------------------------------------------
bold "[Section 5] Status after uninstall"
# ------------------------------------------------------------------

run "$SCRIPT" status
check_exit "status after uninstall exits 0" 0
check_contains "status shows not installed" "not installed"
check_contains "status shows not running" "not running"
check_not_contains "status does NOT crash" "No such file"
check_not_contains "status no unbound variable" "unbound variable"

echo ""

# ------------------------------------------------------------------
bold "[Section 6] Install (fresh after uninstall)"
# ------------------------------------------------------------------

run "$SCRIPT" install
check_exit "install exits 0" 0
check_contains "checksum verification ran" "checksum verified"
check_contains "install shows PID" "PID [0-9]"
check "daemon running after install" daemon_running
check "CLI binary installed" test -x /usr/bin/tailscale
check "daemon binary installed" test -x /usr/sbin/tailscaled
check "socket exists" test -S /var/run/tailscale/tailscaled.sock
check "exactly 1 daemon process" test "$(count_daemons)" -eq 1
check "bashrc markers unchanged" test "$(bashrc_marker_count)" -eq "$INITIAL_MARKERS"

PID_AFTER_INSTALL=$(daemon_pid)

echo ""

# ------------------------------------------------------------------
bold "[Section 7] Install again (idempotent)"
# ------------------------------------------------------------------

run "$SCRIPT" install
check_exit "install again exits 0" 0
check_contains "install again says already installed" "Already installed"
check "still exactly 1 daemon" test "$(count_daemons)" -eq 1
check "same PID (no restart)" test "$(daemon_pid)" = "$PID_AFTER_INSTALL"
check "bashrc markers still unchanged" test "$(bashrc_marker_count)" -eq "$INITIAL_MARKERS"

echo ""

# ------------------------------------------------------------------
bold "[Section 8] Install third time (still idempotent)"
# ------------------------------------------------------------------

run "$SCRIPT" install
check_exit "install 3rd time exits 0" 0
check "same PID (still no restart)" test "$(daemon_pid)" = "$PID_AFTER_INSTALL"
check "still exactly 1 daemon" test "$(count_daemons)" -eq 1

echo ""

# ------------------------------------------------------------------
bold "[Section 9] Update (already at latest)"
# ------------------------------------------------------------------

run "$SCRIPT" update
check_exit "update exits 0" 0
check_contains "update says up to date" "Already up to date"
check "still exactly 1 daemon" test "$(count_daemons)" -eq 1

echo ""

# ------------------------------------------------------------------
bold "[Section 10] Update to specific version (reinstall)"
# ------------------------------------------------------------------

run "$SCRIPT" update v1.96.2
check_exit "update v1.96.2 exits 0" 0
check_contains "update shows reinstalling or updated" "Reinstalling|Updated to"
check "daemon running after reinstall" daemon_running
check "exactly 1 daemon after reinstall" test "$(count_daemons)" -eq 1

echo ""

# ------------------------------------------------------------------
bold "[Section 11] Error handling (bogus versions)"
# ------------------------------------------------------------------

run "$SCRIPT" install v99.99.99
check_exit "install bogus version exits 1" 1

run "$SCRIPT" update v99.99.99
check_exit "update bogus version exits 1" 1

check "daemon survived errors" daemon_running
check "still exactly 1 daemon" test "$(count_daemons)" -eq 1

echo ""

# ------------------------------------------------------------------
bold "[Section 12] Binary paths and versions"
# ------------------------------------------------------------------

check "CLI at /usr/bin" test -x /usr/bin/tailscale
check "daemon at /usr/sbin" test -x /usr/sbin/tailscaled
check "script at /usr/local/bin" test -x /usr/local/bin/tailscaled-proot
check "no stale CLI at /usr/local/bin" test ! -f /usr/local/bin/tailscale
check "no stale daemon at /usr/local/bin" test ! -f /usr/local/bin/tailscaled

CLI_VER=$(/usr/bin/tailscale version 2>/dev/null | head -1)
DAEMON_VER=$(/usr/sbin/tailscaled --version 2>/dev/null | head -1)
check "CLI and daemon versions match" test "$CLI_VER" = "$DAEMON_VER"

echo ""

# ------------------------------------------------------------------
bold "[Section 13] .bashrc integrity"
# ------------------------------------------------------------------

check "bashrc marker count preserved" test "$(bashrc_marker_count)" -eq "$INITIAL_MARKERS"

LINES_BEFORE=$(wc -l < ~/.bashrc)
"$SCRIPT" install &>/dev/null
LINES_AFTER=$(wc -l < ~/.bashrc)
check "bashrc line count unchanged after re-install" test "$LINES_BEFORE" -eq "$LINES_AFTER"

echo ""

# ------------------------------------------------------------------
bold "[Section 14] Network connectivity"
# ------------------------------------------------------------------

# Give daemon time to reconnect after section 10's reinstall
for _ in 1 2 3 4 5; do
    /usr/bin/tailscale status &>/dev/null && break
    sleep 2
done

run /usr/bin/tailscale status
check_exit "tailscale status exits 0" 0
check_contains "tailscale sees peers" "100\.64\."

echo ""

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------
bold "============================================"
TOTAL=$((PASS + FAIL))
bold "  Results: $(green "$PASS passed"), $([ "$FAIL" -gt 0 ] && red "$FAIL failed" || echo "$FAIL failed") out of $TOTAL"
bold "============================================"
echo ""

for t in "${TESTS[@]}"; do
    echo "  $t"
done

echo ""

if [ "$FAIL" -gt 0 ]; then
    red "SOME TESTS FAILED"
    exit 1
else
    green "ALL TESTS PASSED"
    exit 0
fi
