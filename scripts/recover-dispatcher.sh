#!/usr/bin/env bash
# recover-dispatcher.sh — Full dispatcher recovery after container restart.
# Applies all runtime patches, starts all services, registers workers.
# Run this whenever the dispatcher container is recreated or restarted.
# Usage: bash scripts/fleet/recover-dispatcher.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../fleet-config.sh"
source "$SCRIPT_DIR/../aws/common.sh"

CONTAINER="claude-portable"
REMOTE_USER="ubuntu"

info "=== Dispatcher Recovery ==="
info "Target: $DISPATCHER_IP"

# Step 1: Verify container is running
info "Step 1: Checking container..."
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker ps --filter name=$CONTAINER --format '{{.Status}}'" | grep -q "Up" || \
  die "Container $CONTAINER is not running"
info "  Container is up"

# Step 2: Check SSH keys
info "Step 2: SSH keys..."
KEY_COUNT=$(ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec $CONTAINER bash -c 'ls \$HOME/.ssh/ccc-keys/*.pem 2>/dev/null | wc -l'")
info "  $KEY_COUNT SSH keys present"

# Step 3: Start dispatcher process
info "Step 3: Starting dispatcher..."
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec $CONTAINER bash -c 'pkill -f git-dispatch.py 2>/dev/null || true'"
sleep 2
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec $CONTAINER bash -c 'cd /opt/claude-portable && CONTINUOUS_CLAUDE_ENABLED=0 DISPATCHER_DASHBOARD_PORT=8080 nohup python3 scripts/git-dispatch.py > /tmp/dispatcher.log 2>&1 &'"
sleep 5

# Step 4: Apply CLaaS persistence patch
info "Step 4: Applying CLaaS patches..."
bash "$SCRIPT_DIR/patch-claas-persist.sh" 2>&1 | grep -E "INFO|ERROR|DONE" || true

# Step 5: Re-register workers with current IPs
info "Step 5: Registering workers..."
bash "$SCRIPT_DIR/reregister-workers.sh" 10 2>&1 | grep -E "INFO|Fleet" || true

# Step 6: Start dashboard
info "Step 6: Starting dashboard..."
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec $CONTAINER bash -c 'pkill -f central-server || true'"
sleep 1

# Copy latest dashboard files
scp $SSH_OPTS -i "$FLEET_SSH_KEY" \
  "$SCRIPT_DIR/../../dashboard/central-server.js" \
  "$SCRIPT_DIR/../../dashboard/auth.js" \
  "$REMOTE_USER@$DISPATCHER_IP:/tmp/"
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker cp /tmp/central-server.js $CONTAINER:/opt/claude-portable/dashboard/ && \
   docker cp /tmp/auth.js $CONTAINER:/opt/claude-portable/dashboard/"

ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec -d -e DISPATCH_API_TOKEN=dummy -e DISPATCH_API_URL=http://localhost:8080 \
   $CONTAINER bash -c 'cd /opt/claude-portable/dashboard && node central-server.js > /tmp/dashboard.log 2>&1'"
sleep 3

# Step 7: Create user accounts
info "Step 7: Creating accounts..."
for PAIR in "admin boothapp2026" "casey booth2026" "kush booth2026" "chris booth2026" "joel booth2026"; do
  USER=$(echo $PAIR | cut -d' ' -f1)
  PASS=$(echo $PAIR | cut -d' ' -f2)
  ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
    "docker exec $CONTAINER curl -s -o /dev/null -w '' -X POST http://localhost:8082/signup \
     -H 'Content-Type: application/x-www-form-urlencoded' \
     -d 'username=$USER&password=$PASS&confirm=$PASS'" 2>/dev/null || true
done
info "  Accounts created"

# Step 8: Start Teams poller
info "Step 8: Starting poller..."
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec $CONTAINER bash -c 'pkill -f poller-supervisor 2>/dev/null; pkill -f poller.py 2>/dev/null; pkill -f worker.py 2>/dev/null || true'"
sleep 2
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec -d -e POLLER_HOME=/opt/teams-poller $CONTAINER bash /opt/teams-poller/poller-supervisor.sh"
sleep 5

# Step 9: Verify everything
info "Step 9: Verifying..."
HEALTH=$(ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec $CONTAINER curl -s http://localhost:8080/api/v1/health" 2>/dev/null)
DASHBOARD=$(ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec $CONTAINER curl -s -o /dev/null -w '%{http_code}' http://localhost:8082/" 2>/dev/null)
POLLER=$(ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" \
  "docker exec $CONTAINER bash -c 'ps aux | grep poller.py | grep -v grep | wc -l'" 2>/dev/null)

echo ""
info "=== Recovery Complete ==="
info "CLaaS API: $HEALTH"
info "Dashboard: HTTP $DASHBOARD"
info "Poller: $POLLER process(es)"
info "URL: https://$NGINX_IP/"
