#!/usr/bin/env bash
# auto-scale.sh — Check queue depth and adjust worker availability.
# When pending tasks exist and no idle workers, re-registers stopped workers.
# Run periodically (e.g., every 60s via cron or fleet-heal.sh).
#
# Usage: bash scripts/fleet/auto-scale.sh
#        bash scripts/fleet/auto-scale.sh --dry-run
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../fleet-config.sh"

DRY_RUN="${1:-}"

# Fetch fleet health from dispatcher
HEALTH=$(ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "ubuntu@$DISPATCHER_IP" \
  "curl -s http://localhost:8080/health" 2>/dev/null)

if [ -z "$HEALTH" ]; then
  echo "[auto-scale] ERROR: Cannot reach dispatcher"
  exit 1
fi

PENDING=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pending_tasks', 0))" 2>/dev/null)
IDLE=$(echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('fleet_roster',{}); print(sum(1 for v in r.values() if v.get('status')=='idle'))" 2>/dev/null)
STOPPING=$(echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('fleet_roster',{}); print(sum(1 for v in r.values() if v.get('status')=='stopping'))" 2>/dev/null)
TOTAL=$(echo "$HEALTH" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('fleet_roster',{})))" 2>/dev/null)

echo "[auto-scale] Fleet: ${TOTAL} total, ${IDLE} idle, ${STOPPING} stopping, ${PENDING} pending tasks"

# Scale-up logic: if tasks are pending and no idle workers, re-register stopped ones
if [ "$PENDING" -gt 0 ] && [ "$IDLE" -eq 0 ] && [ "$STOPPING" -gt 0 ]; then
  echo "[auto-scale] SCALE UP: $PENDING pending tasks, 0 idle workers, $STOPPING stopped — re-registering"
  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "[auto-scale] DRY RUN: would run reregister-workers.sh"
  else
    bash "$SCRIPT_DIR/reregister-workers.sh" 2>&1 | grep -E "INFO|OK|Error" || true
    echo "[auto-scale] Workers re-registered"
  fi
elif [ "$PENDING" -gt 0 ] && [ "$IDLE" -eq 0 ]; then
  echo "[auto-scale] WARNING: $PENDING pending tasks, 0 idle workers, 0 stopped — no workers available to wake"
elif [ "$PENDING" -eq 0 ] && [ "$IDLE" -gt 0 ]; then
  echo "[auto-scale] OK: No pending tasks, $IDLE idle workers (fleet-monitor handles scale-down)"
else
  echo "[auto-scale] OK: $IDLE idle workers available for $PENDING pending tasks"
fi
