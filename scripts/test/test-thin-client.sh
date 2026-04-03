#!/usr/bin/env bash
# test-thin-client.sh — Validate CLaaS thin client components.
# Tests API, TUI, and agent code structure + syntax.
# Usage: bash scripts/test/test-thin-client.sh

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

echo "=== CLaaS Thin Client Tests ==="
echo ""

echo "-- Session API --"
check "session-api.py exists" "$([ -f "$SESSION_API" ] && echo true || echo false)"
check "Has create session endpoint" "$(grep -q 'def create_session' "$SESSION_API" && echo true || echo false)"
check "Has send prompt endpoint" "$(grep -q 'def send_prompt' "$SESSION_API" && echo true || echo false)"
check "Has SSE stream endpoint" "$(grep -q 'def stream_response' "$SESSION_API" && echo true || echo false)"
check "Has session status endpoint" "$(grep -q 'def session_status' "$SESSION_API" && echo true || echo false)"
check "Has end session endpoint" "$(grep -q 'def end_session' "$SESSION_API" && echo true || echo false)"
check "Has list sessions endpoint" "$(grep -q 'def list_sessions' "$SESSION_API" && echo true || echo false)"
check "Has command request endpoint" "$(grep -q 'def request_command' "$SESSION_API" && echo true || echo false)"
check "Has get pending commands" "$(grep -q 'def get_pending_commands' "$SESSION_API" && echo true || echo false)"
check "Has submit result endpoint" "$(grep -q 'def submit_command_result' "$SESSION_API" && echo true || echo false)"
check "Enforces allowed_ops whitelist" "$(grep -q 'allowed_ops' "$SESSION_API" && echo true || echo false)"
check "Has command timeout" "$(grep -q 'COMMAND_TIMEOUT' "$SESSION_API" && echo true || echo false)"
check "Persists sessions to disk" "$(grep -q 'claas-sessions.json' "$SESSION_API" && echo true || echo false)"
check "Has Flask blueprint" "$(grep -q 'Blueprint' "$SESSION_API" && echo true || echo false)"

echo ""
echo "-- TUI --"
check "claas-tui.py exists" "$([ -f "$TUI" ] && echo true || echo false)"
check "Has REPL loop" "$(grep -q 'input(' "$TUI" && echo true || echo false)"
check "Has /help command" "$(grep -q '/help' "$TUI" && echo true || echo false)"
check "Has /status command" "$(grep -q '/status' "$TUI" && echo true || echo false)"
check "Has /quit command" "$(grep -q '/quit' "$TUI" && echo true || echo false)"
check "Has SSE streaming" "$(grep -q 'stream_response' "$TUI" && echo true || echo false)"
check "Has agent loop" "$(grep -q 'agent_loop' "$TUI" && echo true || echo false)"
check "Has path whitelist" "$(grep -q 'is_path_allowed' "$TUI" && echo true || echo false)"
check "Has audit logging" "$(grep -q 'audit_log' "$TUI" && echo true || echo false)"
check "Has read_file operation" "$(grep -q 'read_file' "$TUI" && echo true || echo false)"
check "Has list_dir operation" "$(grep -q 'list_dir' "$TUI" && echo true || echo false)"
check "Has search_files operation" "$(grep -q 'search_files' "$TUI" && echo true || echo false)"
check "Has write_file operation" "$(grep -q 'write_file' "$TUI" && echo true || echo false)"
check "Has run_script operation" "$(grep -q 'run_script' "$TUI" && echo true || echo false)"
check "Zero external dependencies" "$(! grep -q '^import requests\|^from requests\|^import httpx\|^import aiohttp' "$TUI" && echo true || echo false)"
check "Has config file support" "$(grep -q 'config.json' "$TUI" && echo true || echo false)"
check "Has session resume (--session)" "$(grep -q '\-\-session' "$TUI" && echo true || echo false)"

echo ""
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
