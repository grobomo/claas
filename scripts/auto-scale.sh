#!/usr/bin/env bash
# auto-scale.sh — Auto-scale CLaaS workers based on queue depth.
#
# Scale-up: when pending_tasks > idle_workers, launch new spot instances.
# Scale-down: when workers idle > IDLE_TIMEOUT_MIN, terminate them.
# Re-register: when workers in "stopping" state, re-register to reset.
#
# Usage:
#   bash scripts/fleet/auto-scale.sh              # one-shot check
#   bash scripts/fleet/auto-scale.sh --loop       # continuous (every 60s)
#   bash scripts/fleet/auto-scale.sh --dry-run    # show what would happen
#
# Config via env:
#   CLAAS_API_URL       — CLaaS API base URL (default: http://localhost:8080)
#   MAX_WORKERS         — ceiling (default: 20)
#   MIN_WORKERS         — floor, never scale below (default: 2)
#   IDLE_TIMEOUT_MIN    — minutes idle before scale-down (default: 15)
#   COST_LIMIT_HOURLY   — max $/hr before hard stop (default: 2.50 = $60/day)
#   SCALE_UP_RATIO      — workers per pending task (default: 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/aws/common.sh"

# --- Config ---
CLAAS_API_URL="${CLAAS_API_URL:-http://localhost:8080}"
MAX_WORKERS="${MAX_WORKERS:-20}"
MIN_WORKERS="${MIN_WORKERS:-2}"
IDLE_TIMEOUT_MIN="${IDLE_TIMEOUT_MIN:-15}"
COST_LIMIT_HOURLY="${COST_LIMIT_HOURLY:-2.50}"
SCALE_UP_RATIO="${SCALE_UP_RATIO:-1}"
SPOT_PRICE="${SPOT_PRICE:-0.025}"
LOOP_INTERVAL="${LOOP_INTERVAL:-60}"

DRY_RUN=false
LOOP=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --loop) LOOP=true ;;
    esac
done

log() { echo "[auto-scale] $(date -u +%H:%M:%S) $*"; }

# --- Query CLaaS API ---
api_get() {
    curl -sf "${CLAAS_API_URL}/api/v1/$1" 2>/dev/null || echo "{}"
}

get_fleet_state() {
    HEALTH=$(api_get health)
    WORKERS_JSON=$(api_get workers)

    pending_tasks=$(echo "$HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pending_tasks',0))" 2>/dev/null || echo 0)
    total_workers=$(echo "$HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_workers',0))" 2>/dev/null || echo 0)
    idle_workers=$(echo "$HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('workers_idle',0))" 2>/dev/null || echo 0)
    busy_workers=$(echo "$HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('workers_busy',0))" 2>/dev/null || echo 0)

    # Count workers in stopping/unresponsive state
    stopping_workers=$(echo "$WORKERS_JSON" | python3 -c "
import json,sys
w = json.load(sys.stdin)
if isinstance(w, dict):
    print(sum(1 for v in w.values() if v.get('status') in ('stopping','unresponsive')))
else:
    print(0)
" 2>/dev/null || echo 0)

    # Find workers idle longer than threshold
    idle_timeout_sec=$((IDLE_TIMEOUT_MIN * 60))
    long_idle_workers=$(echo "$WORKERS_JSON" | python3 -c "
import json,sys,time
w = json.load(sys.stdin)
now = time.time()
threshold = $idle_timeout_sec
if isinstance(w, dict):
    names = [name for name, v in w.items()
             if v.get('status') == 'idle'
             and v.get('last_completed_at', 0) > 0
             and (now - v.get('last_completed_at', 0)) > threshold]
    print(','.join(names) if names else '')
else:
    print('')
" 2>/dev/null || echo "")
}

# --- Scale-up: launch spot instances ---
scale_up() {
    local needed=$1
    if [ "$needed" -le 0 ]; then return; fi
    if [ "$total_workers" -ge "$MAX_WORKERS" ]; then
        log "At max workers ($MAX_WORKERS), skipping scale-up"
        return
    fi

    # Cap at MAX_WORKERS
    local can_add=$((MAX_WORKERS - total_workers))
    if [ "$needed" -gt "$can_add" ]; then
        needed=$can_add
    fi

    # Cost guard
    local projected_workers=$((total_workers + needed))
    local projected_hourly
    projected_hourly=$(python3 -c "print(round($projected_workers * $SPOT_PRICE, 3))")
    local over_budget
    over_budget=$(python3 -c "print('true' if $projected_hourly > $COST_LIMIT_HOURLY else 'false')")
    if [ "$over_budget" = "true" ]; then
        log "COST GUARD: $projected_workers workers @ \$$projected_hourly/hr exceeds \$$COST_LIMIT_HOURLY/hr limit"
        # Scale up only to budget limit
        needed=$(python3 -c "import math; print(max(0, math.floor($COST_LIMIT_HOURLY / $SPOT_PRICE) - $total_workers))")
        if [ "$needed" -le 0 ]; then return; fi
        log "Reduced scale-up to $needed workers (budget-capped)"
    fi

    log "SCALE-UP: launching $needed worker(s) (pending=$pending_tasks, idle=$idle_workers)"

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] Would launch $needed spot instance(s)"
        return
    fi

    # Launch via CloudFormation (one stack per worker)
    for i in $(seq 1 "$needed"); do
        local worker_num=$((total_workers + i))
        local stack_name="${PROJECT}-worker-${worker_num}"
        local worker_name="ccc-worker-${worker_num}"

        log "Launching $worker_name..."
        aws cloudformation create-stack \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --stack-name "$stack_name" \
            --template-body "file://$CF_DIR/worker.yaml" \
            --parameters \
                "ParameterKey=WorkerName,ParameterValue=$worker_name" \
                "ParameterKey=DispatcherIP,ParameterValue=$DISPATCHER_IP" \
            --tags "$PROJECT_TAG" \
            2>/dev/null && log "Stack $stack_name created" || log "WARN: Failed to create $stack_name"
    done
}

# --- Scale-down: terminate idle workers ---
scale_down() {
    if [ -z "$long_idle_workers" ]; then return; fi

    # Never go below MIN_WORKERS
    local current_active=$((total_workers - stopping_workers))
    if [ "$current_active" -le "$MIN_WORKERS" ]; then
        log "At min workers ($MIN_WORKERS), skipping scale-down"
        return
    fi

    IFS=',' read -ra IDLE_LIST <<< "$long_idle_workers"
    local can_remove=$((current_active - MIN_WORKERS))

    for worker_name in "${IDLE_LIST[@]}"; do
        if [ "$can_remove" -le 0 ]; then break; fi
        if [ -z "$worker_name" ]; then continue; fi

        log "SCALE-DOWN: $worker_name idle > ${IDLE_TIMEOUT_MIN}m"

        if [ "$DRY_RUN" = "true" ]; then
            log "[DRY-RUN] Would terminate $worker_name"
        else
            # Find and delete the CF stack for this worker
            local stack_name="${PROJECT}-${worker_name}"
            aws cloudformation delete-stack \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --stack-name "$stack_name" \
                2>/dev/null && log "Deleting stack $stack_name" || log "WARN: No stack for $worker_name"
        fi
        can_remove=$((can_remove - 1))
    done
}

# --- Re-register stopping workers ---
reregister_stopping() {
    if [ "$stopping_workers" -eq 0 ]; then return; fi

    log "REREGISTER: $stopping_workers worker(s) in stopping/unresponsive state"

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] Would re-register $stopping_workers worker(s)"
        return
    fi

    echo "$WORKERS_JSON" | python3 -c "
import json, sys, urllib.request
w = json.load(sys.stdin)
api = '${CLAAS_API_URL}'
if isinstance(w, dict):
    for name, v in w.items():
        if v.get('status') in ('stopping', 'unresponsive'):
            data = json.dumps({'name': name, 'private_ip': v.get('private_ip',''), 'public_ip': v.get('public_ip','')}).encode()
            req = urllib.request.Request(f'{api}/api/v1/workers/register', data=data, headers={'Content-Type': 'application/json'})
            try:
                urllib.request.urlopen(req)
                print(f'  Re-registered {name}')
            except Exception as e:
                print(f'  WARN: Failed to re-register {name}: {e}')
" 2>/dev/null || true
}

# --- Main check ---
run_check() {
    get_fleet_state

    log "State: pending=$pending_tasks idle=$idle_workers busy=$busy_workers stopping=$stopping_workers total=$total_workers"

    # 1. Re-register stuck workers
    reregister_stopping

    # 2. Scale up if needed
    local desired=$((pending_tasks * SCALE_UP_RATIO))
    local deficit=$((desired - idle_workers))
    if [ "$deficit" -gt 0 ]; then
        scale_up "$deficit"
    fi

    # 3. Scale down idle workers
    scale_down
}

# --- Entry point ---
if [ "$LOOP" = "true" ]; then
    log "Starting auto-scale loop (interval=${LOOP_INTERVAL}s, max=$MAX_WORKERS, min=$MIN_WORKERS)"
    while true; do
        run_check
        sleep "$LOOP_INTERVAL"
    done
else
    run_check
fi
