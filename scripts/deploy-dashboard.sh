#!/usr/bin/env bash
# Deploy central-server.js to dispatcher container and start it on port 8082.
# Usage: bash scripts/fleet/deploy-dashboard.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$PROJECT_DIR/scripts/fleet-config.sh"
source "$PROJECT_DIR/scripts/aws/common.sh"

DASHBOARD_JS="$PROJECT_DIR/dashboard/central-server.js"
AUTH_JS="$PROJECT_DIR/dashboard/auth.js"
[ -f "$DASHBOARD_JS" ] || die "Dashboard file not found: $DASHBOARD_JS"
[ -f "$AUTH_JS" ] || die "Auth file not found: $AUTH_JS"

info "Copying dashboard files to dispatcher host..."
bash "$PROJECT_DIR/scripts/aws/scp-worker.sh" hackathon26-ccc-dispatcher-golden-image "$DASHBOARD_JS" "/tmp/central-server.js"
bash "$PROJECT_DIR/scripts/aws/scp-worker.sh" hackathon26-ccc-dispatcher-golden-image "$AUTH_JS" "/tmp/auth.js"

info "Deploying into container and starting..."
REMOTE_SCRIPT=$(cat <<'REMOTE'
#!/bin/bash
set -eu
# Copy into container
docker cp /tmp/central-server.js claude-portable:/opt/claude-portable/dashboard/central-server.js
docker cp /tmp/auth.js claude-portable:/opt/claude-portable/dashboard/auth.js

# Kill existing dashboard process
docker exec claude-portable bash -c 'pkill -f "node.*central-server" 2>/dev/null || true'
sleep 1

# Get API token from Secrets Manager for proxy auth
API_TOKEN=$(docker exec claude-portable bash -c 'aws secretsmanager get-secret-value --secret-id hackathon26/dispatch-api-token --query SecretString --output text --region us-east-2 2>/dev/null || echo ""')

# Start dashboard server with API token
docker exec -d claude-portable bash -c "cd /opt/claude-portable/dashboard && DISPATCH_API_TOKEN='${API_TOKEN}' node central-server.js > /tmp/dashboard.log 2>&1"
sleep 2

# Verify
LISTEN=$(docker exec claude-portable bash -c 'ss -tlnp 2>/dev/null | grep 8082 || netstat -tlnp 2>/dev/null | grep 8082 || echo ""')
if [ -n "$LISTEN" ]; then
  echo "Dashboard running on port 8082"
  docker exec claude-portable curl -s --max-time 3 http://localhost:8082/ | head -1
else
  echo "FAIL: Dashboard not listening on 8082"
  docker exec claude-portable cat /tmp/dashboard.log 2>/dev/null | tail -10
  exit 1
fi
REMOTE
)

B64=$(echo "$REMOTE_SCRIPT" | base64 -w0)
bash "$PROJECT_DIR/scripts/aws/ssh-worker.sh" hackathon26-ccc-dispatcher-golden-image "echo $B64 | base64 -d > /tmp/deploy-dash.sh && sudo bash /tmp/deploy-dash.sh"

info "Dashboard deployed."
