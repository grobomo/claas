#!/usr/bin/env bash
# fleet-heal.sh — Self-healing fleet monitor
# Checks fleet health, auto-fixes common issues, reports status.
# Usage: bash scripts/fleet/fleet-heal.sh
set -euo pipefail

FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$FLEET_DIR/../.." && pwd)"
source "$FLEET_DIR/../fleet-config.sh"

HEALED=0
ISSUES=0

info() { echo "[HEAL] $*"; }
warn() { echo "[WARN] $*"; ISSUES=$((ISSUES + 1)); }
fixed() { echo "[FIXED] $*"; HEALED=$((HEALED + 1)); }

# --- 1. Fleet reachability ---
info "Checking dispatcher reachability..."
HEALTH=$(bash "$FLEET_DIR/api-status.sh" health 2>/dev/null) || { warn "Dispatcher unreachable"; HEALTH=""; }

if [ -n "$HEALTH" ]; then
  STATUS=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
  PENDING=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pending_tasks',0))" 2>/dev/null)
  ERRORS=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('errors',0))" 2>/dev/null)

  WORKER_STATES=$(echo "$HEALTH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
states = {}
for v in d.get('fleet_roster', {}).values():
    s = v['status']
    states[s] = states.get(s, 0) + 1
print(json.dumps(states))
" 2>/dev/null)

  IDLE=$(echo "$WORKER_STATES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('idle',0))" 2>/dev/null)
  BUSY=$(echo "$WORKER_STATES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('busy',0))" 2>/dev/null)
  STOPPING=$(echo "$WORKER_STATES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stopping',0))" 2>/dev/null)

  info "Dispatcher: $STATUS | Workers: ${IDLE} idle, ${BUSY} busy, ${STOPPING} stopping | Pending: $PENDING | Errors: $ERRORS"

  # --- 2. Auto-heal: workers stuck in 'stopping' ---
  if [ "${STOPPING:-0}" -gt "${IDLE:-0}" ]; then
    warn "${STOPPING} workers stopping (> ${IDLE} idle) — re-registering..."
    bash "$REPO_ROOT/scripts/aws/ssh-worker.sh" hackathon26-ccc-dispatcher-golden-image \
      'docker exec claude-portable bash -c "test -f /tmp/register-all.sh && bash /tmp/register-all.sh 2>&1 | tail -3"' 2>/dev/null \
      && fixed "Workers re-registered" || warn "Re-registration failed"
  fi

  # --- 2b. Auto-scale: wake workers if tasks pending ---
  if [ "${PENDING:-0}" -gt 0 ] && [ "${IDLE:-0}" -eq 0 ]; then
    warn "Tasks pending ($PENDING) but no idle workers — running auto-scale..."
    bash "$FLEET_DIR/auto-scale.sh" 2>&1 | grep -E "auto-scale" || true
    fixed "Auto-scale triggered"
  fi

  # --- 3. Auto-heal: IAM creds expired ---
  info "Checking IAM creds..."
  IAM_OK=$(bash "$REPO_ROOT/scripts/aws/ssh-worker.sh" hackathon26-ccc-dispatcher-golden-image \
    'docker exec claude-portable aws sts get-caller-identity 2>&1 | head -1' 2>/dev/null)
  if echo "$IAM_OK" | grep -q "ExpiredToken\|error\|Error"; then
    warn "IAM creds expired — refreshing..."
    bash "$REPO_ROOT/scripts/aws/refresh-iam-creds.sh" 2>/dev/null \
      && fixed "IAM creds refreshed" || warn "IAM refresh failed"
  else
    info "IAM creds valid"
  fi

  # --- 4. Check dashboard ---
  info "Checking dashboard..."
  DASH_OK=$(bash "$REPO_ROOT/scripts/aws/ssh-worker.sh" hackathon26-ccc-dispatcher-golden-image \
    'docker exec claude-portable curl -s --max-time 3 -o /dev/null -w "%{http_code}" http://localhost:8082/ 2>/dev/null' 2>/dev/null || echo "")
  if [ -z "$DASH_OK" ] || [ "$DASH_OK" = "000" ]; then
    warn "Dashboard not responding on :8082"
  else
    info "Dashboard healthy"
  fi

  # --- 5. Check for open PRs to merge ---
  info "Checking open PRs..."
  OPEN_PRS=$(gh pr list --repo altarr/boothapp --state open --json number --jq length 2>/dev/null || echo "0")
  if [ "${OPEN_PRS:-0}" -gt 0 ]; then
    info "$OPEN_PRS open PRs — merging..."
    for pr in $(gh pr list --repo altarr/boothapp --state open --json number --jq '.[].number' 2>/dev/null); do
      gh pr merge "$pr" --repo altarr/boothapp --squash --auto 2>/dev/null && info "Merged PR #$pr" || true
    done
  else
    info "No open PRs"
  fi

else
  warn "Fleet unreachable — cannot heal"
fi

# --- Summary ---
echo ""
echo "=== Fleet Heal Summary ==="
echo "Issues found: $ISSUES"
echo "Auto-healed:  $HEALED"
[ "$ISSUES" -eq 0 ] && echo "Status: HEALTHY" || echo "Status: NEEDS ATTENTION ($((ISSUES - HEALED)) unresolved)"
exit $((ISSUES - HEALED > 0 ? 1 : 0))
