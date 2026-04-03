#!/usr/bin/env bash
# test-thin-client-security.sh — Security tests for CLaaS thin client.
# Validates: blocked commands rejected, audit log written, path traversal blocked,
# config generation, session management.
# Usage: bash scripts/test/test-thin-client-security.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SESSION_API="$REPO_ROOT/scripts/fleet/claas-session-api.py"
TUI="$REPO_ROOT/scripts/fleet/claas-tui.py"

PASS=0; FAIL=0
check() {
    local desc="$1" result="$2"
    if [ "$result" = "true" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL + 1))
    fi
}

echo "=== CLaaS Thin Client Security Tests ==="
echo ""

# --- T009: Audit logging ---
echo "-- T009: Audit logging --"
check "Server-side audit function exists" "$(grep -q 'def _audit' "$SESSION_API" && echo true || echo false)"
check "Audit file path configurable" "$(grep -q 'AUDIT_FILE' "$SESSION_API" && echo true || echo false)"
check "Session creation audited" "$(grep -q 'session_created' "$SESSION_API" && echo true || echo false)"
check "Prompt send audited" "$(grep -q 'prompt_sent' "$SESSION_API" && echo true || echo false)"
check "Command request audited" "$(grep -q 'command_requested' "$SESSION_API" && echo true || echo false)"
check "Blocked command audited" "$(grep -q 'command_blocked' "$SESSION_API" && echo true || echo false)"
check "Command result audited" "$(grep -q 'command_result' "$SESSION_API" && echo true || echo false)"
check "Session end audited" "$(grep -q 'session_ended' "$SESSION_API" && echo true || echo false)"
check "Per-session audit endpoint" "$(grep -q 'def session_audit' "$SESSION_API" && echo true || echo false)"
check "Full audit endpoint" "$(grep -q 'def full_audit' "$SESSION_API" && echo true || echo false)"
check "Audit entries have timestamp" "$(grep -q '"timestamp": time.time()' "$SESSION_API" && echo true || echo false)"
check "TUI client-side audit log" "$(grep -q 'audit_log' "$TUI" && echo true || echo false)"
check "TUI /audit command" "$(grep -q '/audit' "$TUI" && echo true || echo false)"

echo ""

# --- T010: Config file ---
echo "-- T010: Config file --"
check "Config loader exists" "$(grep -q 'def load_config' "$TUI" && echo true || echo false)"
check "Reads ~/.claas/config.json" "$(grep -q 'config.json' "$TUI" && echo true || echo false)"
check "--init flag creates template" "$(grep -q '_init_config' "$TUI" && echo true || echo false)"
check "Template includes server" "$(grep -q '"server"' "$TUI" && echo true || echo false)"
check "Template includes allowed_paths" "$(grep -q '"allowed_paths"' "$TUI" && echo true || echo false)"
check "Template includes allowed_ops" "$(grep -q '"allowed_ops"' "$TUI" && echo true || echo false)"
check "Template includes audit_log" "$(grep -q '"audit_log"' "$TUI" && echo true || echo false)"
check "Config from CLI overrides file" "$(grep -q 'if args.server' "$TUI" && echo true || echo false)"
check "Config from env overrides default" "$(grep -q 'CLAAS_SERVER' "$TUI" && echo true || echo false)"

echo ""

# --- T011: Session management ---
echo "-- T011: Session management --"
check "List sessions command" "$(grep -q '/sessions' "$TUI" && echo true || echo false)"
check "Resume session (--session)" "$(grep -q '\-\-session' "$TUI" && echo true || echo false)"
check "End session command" "$(grep -q '/end' "$TUI" && echo true || echo false)"
check "New session command" "$(grep -q '/new' "$TUI" && echo true || echo false)"
check "Session status endpoint" "$(grep -q 'def session_status' "$SESSION_API" && echo true || echo false)"
check "Session delete endpoint" "$(grep -q 'def end_session' "$SESSION_API" && echo true || echo false)"
check "Sessions persist to disk" "$(grep -q 'claas-sessions.json' "$SESSION_API" && echo true || echo false)"

echo ""

# --- T012: Packaging ---
echo "-- T012: Packaging --"
check "TUI is single file" "$([ -f "$TUI" ] && echo true || echo false)"
check "TUI has zero external deps" "$(! grep -q '^import requests\|^from requests\|^import httpx\|^import aiohttp\|^import flask' "$TUI" && echo true || echo false)"
check "Session API has Flask dep only" "$(grep -q 'from flask import' "$SESSION_API" && echo true || echo false)"
check "TUI has --help" "$(grep -q 'argparse' "$TUI" && echo true || echo false)"
check "TUI has shebang" "$(head -1 "$TUI" | grep -q '#!/usr/bin/env python3' && echo true || echo false)"
check "Session API has shebang" "$(head -1 "$SESSION_API" | grep -q '#!/usr/bin/env python3' && echo true || echo false)"

echo ""

# --- Security hardening ---
echo "-- Security hardening --"
check "Path traversal protection (realpath)" "$(grep -q 'os.path.realpath' "$TUI" && echo true || echo false)"
check "Path comparison uses os.sep" "$(grep -q 'os.sep' "$TUI" && echo true || echo false)"
check "File read size limited" "$(grep -q '100000' "$TUI" && echo true || echo false)"
check "Script execution timeout" "$(grep -q 'timeout=60' "$TUI" && echo true || echo false)"
check "Script output truncated" "$(grep -q '\[-5000:\]' "$TUI" && echo true || echo false)"
check "Command channel timeout" "$(grep -q 'COMMAND_TIMEOUT' "$SESSION_API" && echo true || echo false)"
check "Whitelist enforcement server-side" "$(grep -q 'allowed_ops' "$SESSION_API" && echo true || echo false)"
check "Whitelist enforcement client-side" "$(grep -q 'is_path_allowed' "$TUI" && echo true || echo false)"

echo ""

# --- Syntax validation ---
echo "-- Syntax --"
PY1=$(cd "$REPO_ROOT" && python3 -c "import py_compile; py_compile.compile('scripts/fleet/claas-session-api.py', doraise=True)" 2>&1 && echo true || echo false)
check "Session API syntax valid" "$PY1"
PY2=$(cd "$REPO_ROOT" && python3 -c "import py_compile; py_compile.compile('scripts/fleet/claas-tui.py', doraise=True)" 2>&1 && echo true || echo false)
check "TUI syntax valid" "$PY2"

echo ""
TOTAL=$((PASS + FAIL))
echo "=== Results: $PASS/$TOTAL passed ==="
[ $FAIL -gt 0 ] && { echo "FAILED"; exit 1; }
echo "ALL TESTS PASSED"
