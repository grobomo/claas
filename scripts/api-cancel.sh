#!/usr/bin/env bash
# Cancel a pending task on the dispatcher.
# Usage: bash scripts/fleet/api-cancel.sh <task-id>

set -euo pipefail
FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$FLEET_DIR/../.." && pwd)"
source "$FLEET_DIR/../fleet-config.sh"

TASK_ID="${1:?Usage: api-cancel.sh <task-id>}"

RESULT=$(bash "$REPO_ROOT/scripts/aws/docker-exec.sh" hackathon26-ccc-dispatcher-golden-image \
  "curl -sf -X POST http://localhost:8080/api/cancel -H 'Content-Type: application/json' -d '{\"task_id\": \"$TASK_ID\"}'")

echo "$RESULT"
