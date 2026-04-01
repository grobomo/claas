#!/usr/bin/env bash
# refresh-worker-creds.sh — Push fresh Claude OAuth tokens to all workers.
# Pulls from Secrets Manager (updated by store-secrets.sh), rebuilds
# .credentials.json, and pushes to each registered worker via dispatcher SSH.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../fleet-config.sh"
source "$SCRIPT_DIR/../aws/common.sh"

# Path inside worker containers (Docker, not local)
CONTAINER_CREDS_DIR="\$HOME/.claude"

info "Fetching fresh OAuth from Secrets Manager..."
OAUTH_JSON=$(aws secretsmanager get-secret-value \
  --secret-id hackathon26/claude-oauth \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query SecretString --output text)

if [ -z "$OAUTH_JSON" ]; then
  die "Failed to get OAuth from Secrets Manager"
fi

# Build a minimal .credentials.json
CREDS_JSON=$(python3 -c "
import json
oauth = json.loads('''$OAUTH_JSON''')
creds = {
  'claudeAiOauth': {
    'accessToken': oauth['accessToken'],
    'refreshToken': oauth['refreshToken'],
    'expiresAt': oauth['expiresAt'],
    'subscriptionType': 'enterprise'
  }
}
print(json.dumps(creds, indent=2))
")

info "Built credentials ($(echo "$CREDS_JSON" | wc -c) bytes)"

# Get worker list from dispatcher health endpoint
HEALTH=$(bash "${SCRIPT_DIR}/api-status.sh" health 2>/dev/null)
WORKER_LIST=$(python3 -c "
import json
h = json.loads('''$HEALTH''')
roster = h.get('fleet_roster', {})
for name, info in roster.items():
    ip = info.get('ip', '')
    if ip:
        print(name, ip)
")

if [ -z "$WORKER_LIST" ]; then
  die "Could not parse worker IPs from health endpoint"
fi

info "Found $(echo "$WORKER_LIST" | wc -l) workers"

# Write creds to a temp file on dispatcher host
CREDS_B64=$(echo "$CREDS_JSON" | base64 -w0)
DISP_KEY="$HOME/.ssh/ccc-keys/claude-portable-key.pem"

info "Pushing credentials to dispatcher host..."
ssh $SSH_OPTS -i "$DISP_KEY" "ubuntu@$DISPATCHER_IP" \
  "echo '$CREDS_B64' | base64 -d > /tmp/fresh-creds.json"

# For each worker, push creds from dispatcher via SSH
echo "$WORKER_LIST" | while read -r WNAME WIP; do
  # Skip dispatcher itself
  if [ "$WIP" = "$(echo "$DISPATCHER_IP" | xargs)" ] || echo "$WNAME" | grep -q "dispatcher"; then
    continue
  fi

  KEY_FILE="/tmp/ccc-keys/${WNAME}.pem"
  CREDS_PATH="${CONTAINER_CREDS_DIR}/.credentials.json"

  # SCP from dispatcher to worker, docker cp into container
  RESULT=$(ssh $SSH_OPTS -i "$DISP_KEY" "ubuntu@$DISPATCHER_IP" \
    "scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -i $KEY_FILE /tmp/fresh-creds.json ubuntu@${WIP}:/tmp/fresh-creds.json 2>&1 && \
     ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i $KEY_FILE ubuntu@${WIP} \
       'docker cp /tmp/fresh-creds.json claude-portable:${CREDS_PATH} && echo REFRESHED' 2>&1" 2>&1 || true)

  if echo "$RESULT" | grep -q "REFRESHED"; then
    info "  $WNAME ($WIP): OK"
  else
    warn "  $WNAME ($WIP): FAILED - $(echo "$RESULT" | tail -1)"
  fi
done

# Also refresh dispatcher container (for spec generation)
DISP_CREDS="${CONTAINER_CREDS_DIR}/.credentials.json"
ssh $SSH_OPTS -i "$DISP_KEY" "ubuntu@$DISPATCHER_IP" \
  "docker cp /tmp/fresh-creds.json claude-portable:${DISP_CREDS} && echo DISPATCHER_REFRESHED" 2>&1

# Clean up
ssh $SSH_OPTS -i "$DISP_KEY" "ubuntu@$DISPATCHER_IP" "rm -f /tmp/fresh-creds.json" 2>/dev/null || true

info "Credential refresh complete."
