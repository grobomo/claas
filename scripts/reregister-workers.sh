#!/usr/bin/env bash
# reregister-workers.sh — Query EC2 for current private IPs, re-register all workers with dispatcher.
# Fixes stale roster after spot reclamation or IP changes.
# Usage: bash scripts/fleet/reregister-workers.sh [LIMIT]
set -euo pipefail
FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$FLEET_DIR/../aws/common.sh"
source "$FLEET_DIR/../fleet-config.sh"

LIMIT="${1:-10}"

TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

info "Querying EC2 for running worker instances..."

aws ec2 describe-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --filters "Name=tag:Project,Values=hackathon26" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,PrivateIpAddress]" \
  --output text > "$TMPFILE" 2>&1

TOTAL=$(wc -l < "$TMPFILE")
info "Found $TOTAL instances total"

# Filter to workers with numeric suffix only
WORKERS=$(grep -E "^hackathon26-worker-[0-9]+\s" "$TMPFILE" | head -n "$LIMIT")
COUNT=$(echo "$WORKERS" | grep -c . || true)
info "Will register $COUNT workers (limit=$LIMIT)"

# Build a single batch curl script to run inside dispatcher container
CURL_SCRIPT=""
while read -r name ip; do
  [[ -z "$name" || -z "$ip" ]] && continue
  CURL_SCRIPT="${CURL_SCRIPT}curl -sf -X POST http://localhost:8080/worker/register -H 'Content-Type: application/json' -d '{\"name\":\"$name\",\"ip\":\"$ip\"}' && echo ' $name OK' || echo ' $name FAIL'
"
done <<< "$WORKERS"

if [[ -z "$CURL_SCRIPT" ]]; then
  warn "No workers to register"
  exit 0
fi

# Base64 encode and execute in one SSH call
B64=$(echo "$CURL_SCRIPT" | base64 -w0)
info "Sending batch registration to dispatcher..."
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "ubuntu@${DISPATCHER_IP}" \
  "echo $B64 | base64 -d | docker exec -i claude-portable bash" 2>&1

info "Registration complete."

# Verify
info "Verifying idle workers..."
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "ubuntu@${DISPATCHER_IP}" \
  "docker exec claude-portable curl -sf http://localhost:8080/api/workers" 2>/dev/null | \
  python3 -c "
import json,sys
w=json.load(sys.stdin)
idle=sum(1 for v in w.values() if v.get('status')=='idle')
busy=sum(1 for v in w.values() if v.get('status')=='busy')
print(f'Fleet: idle={idle} busy={busy} total={len(w)}')
" 2>&1 || echo "Could not verify"
