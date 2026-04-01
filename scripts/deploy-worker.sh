#!/usr/bin/env bash
# deploy-worker.sh — Deploy a CCC worker from ECR golden image.
# Usage:
#   bash scripts/fleet/deploy-worker.sh 2        # deploys hackathon26-worker-2
#   bash scripts/fleet/deploy-worker.sh 3
#   INSTANCE_TYPE=t3.xlarge bash scripts/fleet/deploy-worker.sh 4

set -euo pipefail
FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$FLEET_DIR/../.." && pwd)"

source "$FLEET_DIR/../fleet-config.sh"
source "$REPO_ROOT/scripts/aws/common.sh"

WORKER_NUM="${1:?Usage: deploy-worker.sh <number>}"
WORKER_NAME="hackathon26-worker-${WORKER_NUM}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"
CF_TEMPLATE="$REPO_ROOT/cloudformation/hackathon26-worker.yaml"
ECR_IMAGE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/hackathon26/worker:latest"

[ -f "$CF_TEMPLATE" ] || die "CF template not found: $CF_TEMPLATE"

# Check if stack already exists
EXISTING_IP=$(bash "$REPO_ROOT/scripts/aws/get-stack-output.sh" "$WORKER_NAME" "PublicIP" 2>/dev/null || true)
if [ -n "$EXISTING_IP" ]; then
  info "Stack $WORKER_NAME already exists at $EXISTING_IP"
  echo "$EXISTING_IP"
  exit 0
fi

# Verify ECR image
info "Checking ECR image..."
aws ecr describe-images --repository-name hackathon26/worker --image-ids imageTag=latest \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1 || die "No golden image in ECR."

# Deploy
info "Deploying $WORKER_NAME..."
bash "$REPO_ROOT/scripts/aws/deploy-stack.sh" \
  "$WORKER_NAME" "$CF_TEMPLATE" \
  "WorkerName=$WORKER_NAME" "InstanceType=$INSTANCE_TYPE" "DockerImage=$ECR_IMAGE"

# Get IP
WORKER_IP=$(bash "$REPO_ROOT/scripts/aws/get-stack-output.sh" "$WORKER_NAME" "PublicIP")
[ -n "$WORKER_IP" ] || die "No PublicIP from stack $WORKER_NAME"

# Wait for container to be ready (check SSH + docker)
info "Waiting for $WORKER_NAME at $WORKER_IP..."
for i in $(seq 1 30); do
  if bash "$REPO_ROOT/scripts/aws/ssh-worker.sh" "$WORKER_NAME" "docker exec claude-portable echo OK" >/dev/null 2>&1; then
    info "$WORKER_NAME ready!"
    echo ""
    echo "=== $WORKER_NAME ==="
    echo "  Public IP:  $WORKER_IP"
    echo "  Private IP: $(bash "$REPO_ROOT/scripts/aws/get-private-ip.sh" "$WORKER_IP" 2>/dev/null)"
    echo "  SSH: bash scripts/aws/ssh-worker.sh $WORKER_NAME"
    exit 0
  fi
  sleep 10
done

warn "$WORKER_NAME deployed but container not yet responding. IP: $WORKER_IP"
echo "$WORKER_IP"
