#!/usr/bin/env bash
# test-thin-client-e2e.sh — End-to-end tests for CLaaS thin client.
# Starts the session API locally, tests dispatch wiring, command channel,
# agent execution, and security enforcement.
# Usage: bash scripts/test/test-thin-client-e2e.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SESSION_API="$REPO_ROOT/scripts/fleet/claas-session-api.py"
TUI="$REPO_ROOT/scripts/fleet/claas-tui.py"
API_PORT=18081
API_URL="http://localhost:$API_PORT"

PASS=0; FAIL=0
check() {
    local desc="$1" result="$2"
    if [ "$result" = "true" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL + 1))
    fi
}

cleanup() {
    [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null || true
    rm -rf "${TMPDIR:-/tmp}/claas-test-e2e"
}
trap cleanup EXIT

echo "=== CLaaS Thin Client E2E Tests ==="
echo ""

# --- Check Python + Flask available ---
echo "-- Prerequisites --"
FLASK_OK=$(python3 -c "import flask; print('ok')" 2>/dev/null || echo "no")
if [ "$FLASK_OK" != "ok" ]; then
    echo "  SKIP: Flask not installed (pip install flask). Running structural tests only."
    echo ""

    echo "-- Structural: Dispatch wiring (T005) --"
    check "dispatch calls CLaaS v2 /api/v1/submit" "$(grep -q 'api/v1/submit' "$SESSION_API" && echo true || echo false)"
    check "dispatch polls task status" "$(grep -q '_poll_task_output' "$SESSION_API" && echo true || echo false)"
    check "dispatch streams output chunks" "$(grep -q 'response_chunks' "$SESSION_API" && echo true || echo false)"
    check "has HTTP POST helper" "$(grep -q '_http_post' "$SESSION_API" && echo true || echo false)"
    check "has HTTP GET helper" "$(grep -q '_http_get' "$SESSION_API" && echo true || echo false)"
    check "handles dispatch error" "$(grep -q 'Dispatch failed' "$SESSION_API" && echo true || echo false)"
    check "handles task timeout" "$(grep -q 'timed out' "$SESSION_API" && echo true || echo false)"
    check "supports integrated mode" "$(grep -q 'register_with_claas' "$SESSION_API" && echo true || echo false)"

    echo ""
    echo "-- Structural: Whitelist enforcement (T006) --"
    check "path whitelist uses realpath" "$(grep -q 'os.path.realpath' "$TUI" && echo true || echo false)"
    check "path traversal protection" "$(grep -q 'os.sep' "$TUI" && echo true || echo false)"
    check "read_file checks whitelist" "$(grep -c 'is_path_allowed' "$TUI" | awk '{print ($1 >= 5) ? "true" : "false"}')"
    check "write_file checks whitelist" "$(grep -A5 'write_file' "$TUI" | grep -q 'is_path_allowed' && echo true || echo false)"
    check "run_script checks cwd whitelist" "$(grep -A5 'run_script' "$TUI" | grep -q 'is_path_allowed' && echo true || echo false)"
    check "file read size limited (100KB)" "$(grep -q '100000' "$TUI" && echo true || echo false)"
    check "script execution timeout (60s)" "$(grep -q 'timeout=60' "$TUI" && echo true || echo false)"
    check "script output truncated" "$(grep -q '\[-5000:\]' "$TUI" && echo true || echo false)"

    echo ""
    echo "-- Structural: Worker integration (T007) --"
    check "system prompt builder exists" "$(grep -q '_build_system_prompt' "$SESSION_API" && echo true || echo false)"
    check "system prompt includes command channel URL" "$(grep -q 'SESSION_API_URL' "$SESSION_API" && echo true || echo false)"
    check "system prompt lists all operations" "$(grep -q 'read_file.*list_dir.*search_files' "$SESSION_API" && echo true || echo false)"
    check "system prompt includes working dir" "$(grep -q 'working_dir' "$SESSION_API" && echo true || echo false)"
    check "full prompt includes conversation history" "$(grep -q '_build_full_prompt' "$SESSION_API" && echo true || echo false)"
    check "history limited to last 20 messages" "$(grep -q '\-21:-1\]' "$SESSION_API" && echo true || echo false)"

    echo ""
    echo "-- Structural: E2E flow (T008) --"
    check "TUI has /workers command" "$(grep -q '/workers' "$TUI" && echo true || echo false)"
    check "TUI has /allowdir command" "$(grep -q '/allowdir' "$TUI" && echo true || echo false)"
    check "TUI stream handles error type" "$(grep -q "dtype == .error." "$TUI" && echo true || echo false)"
    check "TUI stream shows command details" "$(grep -q 'read_file\|list_dir\|run_script' "$TUI" && echo true || echo false)"
    check "TUI stream timeout 900s" "$(grep -q 'timeout=900' "$TUI" && echo true || echo false)"
    check "Agent prints operation status" "$(grep -q '\[agent\]' "$TUI" && echo true || echo false)"
    check "Session API configurable via env vars" "$(grep -q 'CLAAS_API_URL' "$SESSION_API" && echo true || echo false)"
    check "Session API URL configurable for workers" "$(grep -q 'CLAAS_SESSION_API_URL' "$SESSION_API" && echo true || echo false)"

    echo ""
    TOTAL=$((PASS + FAIL))
    echo "=== Results: $PASS/$TOTAL passed (structural) ==="
    [ $FAIL -gt 0 ] && { echo "FAILED"; exit 1; }
    echo "ALL TESTS PASSED"
    exit 0
fi

# --- Start session API in background ---
echo "-- Starting session API --"
TMPDIR=$(mktemp -d /tmp/claas-test-e2e-XXXXXX)
export CLAAS_DATA_DIR="$TMPDIR"
export CLAAS_API_URL="http://localhost:19999"  # Non-existent CLaaS v2 (we test the wiring, not the fleet)
export CLAAS_SESSION_API_URL="$API_URL"

python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/fleet')
from importlib.machinery import SourceFileLoader
mod = SourceFileLoader('session_api', '$SESSION_API').load_module()
app = mod.create_app()
app.run(host='127.0.0.1', port=$API_PORT)
" &>/dev/null &
API_PID=$!
sleep 2

# Check if API is running
if ! kill -0 "$API_PID" 2>/dev/null; then
    echo "  FAIL: Session API failed to start"
    exit 1
fi
echo "  Session API running (PID=$API_PID)"
echo ""

# --- Test: Create session ---
echo "-- Session lifecycle --"
RESP=$(curl -s -X POST "$API_URL/api/v1/session" \
    -H 'Content-Type: application/json' \
    -d '{"working_dir":"/tmp/test","allowed_ops":["read_file","list_dir"]}')
SESSION_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
check "Create session returns ID" "$([ -n "$SESSION_ID" ] && echo true || echo false)"

# --- Test: Session status ---
STATUS=$(curl -s "$API_URL/api/v1/session/$SESSION_ID/status")
check "Session status returns active" "$(echo "$STATUS" | grep -q '"active"' && echo true || echo false)"

# --- Test: List sessions ---
SESSIONS=$(curl -s "$API_URL/api/v1/sessions")
check "List sessions includes our session" "$(echo "$SESSIONS" | grep -q "$SESSION_ID" && echo true || echo false)"

# --- Test: Send prompt (will fail dispatch since CLaaS v2 isn't running, but should handle gracefully) ---
echo ""
echo "-- Dispatch wiring --"
PROMPT_RESP=$(curl -s -X POST "$API_URL/api/v1/session/$SESSION_ID/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"list the files in the current directory"}')
check "Send prompt returns dispatched" "$(echo "$PROMPT_RESP" | grep -q 'dispatched' && echo true || echo false)"

# Wait a moment for dispatch to fail (CLaaS v2 not running)
sleep 3

STATUS2=$(curl -s "$API_URL/api/v1/session/$SESSION_ID/status")
check "Session still accessible after failed dispatch" "$(echo "$STATUS2" | grep -q "$SESSION_ID" && echo true || echo false)"

# --- Test: Command channel ---
echo ""
echo "-- Command channel --"

# Post a command (simulating what a worker would do)
CMD_RESP=$(curl -s -X POST "$API_URL/api/v1/session/$SESSION_ID/command" \
    -H 'Content-Type: application/json' \
    -d '{"operation":"read_file","args":{"path":"/tmp/test/foo.txt"}}' &)
CMD_PID=$!

# Poll for pending commands (simulating what the agent does)
sleep 1
PENDING=$(curl -s "$API_URL/api/v1/session/$SESSION_ID/commands")
check "Pending commands returns array" "$(echo "$PENDING" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if isinstance(d,list) else 'false')" 2>/dev/null || echo false)"

CMD_ID=$(echo "$PENDING" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || echo "")
check "Command has ID" "$([ -n "$CMD_ID" ] && echo true || echo false)"

# Submit result (simulating agent response)
if [ -n "$CMD_ID" ]; then
    RESULT_RESP=$(curl -s -X POST "$API_URL/api/v1/session/$SESSION_ID/result" \
        -H 'Content-Type: application/json' \
        -d "{\"command_id\":\"$CMD_ID\",\"result\":\"file contents here\"}")
    check "Submit result accepted" "$(echo "$RESULT_RESP" | grep -q '"ok"' && echo true || echo false)"
fi
wait "$CMD_PID" 2>/dev/null || true

# --- Test: Blocked operation ---
BLOCKED=$(curl -s -X POST "$API_URL/api/v1/session/$SESSION_ID/command" \
    -H 'Content-Type: application/json' \
    -d '{"operation":"run_script","args":{"command":"rm -rf /"}}' 2>/dev/null)
check "Blocked operation rejected (403)" "$(echo "$BLOCKED" | grep -q 'not allowed' && echo true || echo false)"

# --- Test: End session ---
echo ""
echo "-- Cleanup --"
END_RESP=$(curl -s -X DELETE "$API_URL/api/v1/session/$SESSION_ID")
check "End session succeeds" "$(echo "$END_RESP" | grep -q '"ended"' && echo true || echo false)"

# --- Test: Agent whitelist (TUI-side) ---
echo ""
echo "-- Agent security --"
AGENT_TEST=$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/fleet')
from importlib.machinery import SourceFileLoader
tui = SourceFileLoader('tui', '$TUI').load_module()

config = {'allowed_paths': ['/tmp/test'], 'audit_log': '', 'working_dir': '/tmp/test'}

# Test: allowed path
assert tui.is_path_allowed('/tmp/test/foo.txt', ['/tmp/test']) == True
# Test: blocked path
assert tui.is_path_allowed('/etc/passwd', ['/tmp/test']) == False
# Test: traversal attempt
assert tui.is_path_allowed('/tmp/test/../../../etc/passwd', ['/tmp/test']) == False
# Test: exact match
assert tui.is_path_allowed('/tmp/test', ['/tmp/test']) == True

# Test execute_command
result = tui.execute_command(config, {'operation': 'read_file', 'args': {'path': '/etc/passwd'}})
assert 'error' in result and 'not allowed' in result['error'].lower()

result = tui.execute_command(config, {'operation': 'unknown_op', 'args': {}})
assert 'error' in result

print('ok')
" 2>&1)
check "Path whitelist blocks traversal" "$([ "$AGENT_TEST" = "ok" ] && echo true || echo false)"

echo ""
TOTAL=$((PASS + FAIL))
echo "=== Results: $PASS/$TOTAL passed ==="
[ $FAIL -gt 0 ] && { echo "FAILED"; exit 1; }
echo "ALL TESTS PASSED"
