#!/usr/bin/env bash
# Check fleet status: health, workers, tasks.
# Usage: bash scripts/fleet/api-status.sh [health|workers|tasks|all]

set -euo pipefail
FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$FLEET_DIR/../.." && pwd)"
source "$FLEET_DIR/../fleet-config.sh"

MODE="${1:-all}"

exec_api() {
  bash "$REPO_ROOT/scripts/aws/docker-exec.sh" hackathon26-ccc-dispatcher-golden-image \
    "curl -sf http://localhost:8080$1" 2>&1
}

case "$MODE" in
  health)
    exec_api /health | python3 -m json.tool 2>/dev/null || exec_api /health
    ;;
  workers)
    exec_api /health | python3 -c "
import sys, json
data = json.load(sys.stdin)
roster = data.get('fleet_roster', {})
for name, info in sorted(roster.items()):
    status = info.get('status', '?')
    ip = info.get('ip', '?')
    completions = info.get('completions', 0)
    print(f'  {status:10s} {name:45s} {ip:16s} completions={completions}')
print(f'\nTotal: {len(roster)} workers')
idle = sum(1 for w in roster.values() if w.get('status') == 'idle')
busy = sum(1 for w in roster.values() if w.get('status') in ('busy', 'dispatching'))
print(f'Idle: {idle}, Busy: {busy}')
" 2>/dev/null || exec_api /health
    ;;
  tasks)
    exec_api /api/tasks | python3 -m json.tool 2>/dev/null || exec_api /api/tasks
    ;;
  all)
    echo "=== Health ==="
    exec_api /health | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'Status: {data[\"status\"]}')
print(f'Uptime: {data.get(\"uptime_seconds\", 0)//60}m')
print(f'Pending: {data.get(\"pending_tasks\", 0)}')
print(f'Active workers: {data.get(\"active_workers\", 0)}')
print(f'Total dispatches: {data.get(\"total_dispatches\", 0)}')
print(f'Total completions: {data.get(\"total_completions\", 0)}')
roster = data.get('fleet_roster', {})
idle = sum(1 for w in roster.values() if w.get('status') == 'idle')
busy = sum(1 for w in roster.values() if w.get('status') in ('busy', 'dispatching'))
print(f'Fleet: {len(roster)} workers ({idle} idle, {busy} busy)')
" 2>/dev/null
    echo ""
    echo "=== Workers ==="
    exec_api /health | python3 -c "
import sys, json
data = json.load(sys.stdin)
roster = data.get('fleet_roster', {})
for name, info in sorted(roster.items()):
    status = info.get('status', '?')
    ip = info.get('ip', '?')
    completions = info.get('completions', 0)
    print(f'  {status:10s} {name:45s} {ip:16s} completions={completions}')
print(f'\nTotal: {len(roster)} workers')
idle = sum(1 for w in roster.values() if w.get('status') == 'idle')
busy = sum(1 for w in roster.values() if w.get('status') in ('busy', 'dispatching'))
print(f'Idle: {idle}, Busy: {busy}')
" 2>/dev/null
    echo ""
    echo "=== Recent Tasks ==="
    exec_api /api/tasks | python3 -c "
import sys, json
data = json.load(sys.stdin)
tasks = data if isinstance(data, list) else data.get('tasks', [])
for t in tasks[:10]:
    tid = t.get('task_id', t.get('id', '?'))[:12]
    status = t.get('status', '?')
    text = t.get('text', '')[:60]
    print(f'  {status:12s} {tid} {text}')
if not tasks:
    print('  (no tasks)')
" 2>/dev/null || echo "  (no task API)"
    ;;
  *)
    echo "Usage: api-status.sh [health|workers|tasks|all]"
    exit 1
    ;;
esac
