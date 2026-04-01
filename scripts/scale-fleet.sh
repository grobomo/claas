#!/usr/bin/env bash
# Scale the CCC fleet to N workers by deploying CF stacks from ECR golden image.
# Usage: bash scripts/fleet/scale-fleet.sh <target_count> [start_from]
# Example: bash scripts/fleet/scale-fleet.sh 100   # deploy workers 10-99
#          bash scripts/fleet/scale-fleet.sh 50 20  # deploy workers 20-49
#
# Each worker is a t3.large spot instance pulling from ECR golden image.
# Workers auto-register with dispatcher after boot.

set -uo pipefail  # no -e, background jobs may fail individually
FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$FLEET_DIR/../.." && pwd)"
source "$FLEET_DIR/../fleet-config.sh"
source "$FLEET_DIR/../aws/common.sh"

TARGET="${1:?Usage: scale-fleet.sh <target_count> [start_from]}"
START="${2:-10}"
TEMPLATE="hackathon26-worker.yaml"
ECR_IMAGE="752266476357.dkr.ecr.us-east-2.amazonaws.com/hackathon26/worker:latest"
BATCH_SIZE=10

echo "[scale] Scaling fleet to $TARGET workers (starting from worker-$START)"
echo "[scale] Instance type: t3.large, ECR image: $ECR_IMAGE"

DEPLOYED=0
FAILED=0
PIDS=()

for ((i=START; i<TARGET; i++)); do
  STACK_NAME="hackathon26-worker-$i"
  WORKER_NAME="hackathon26-worker-$i"

  # Check if stack already exists
  STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NONE")

  if [[ "$STATUS" == "CREATE_COMPLETE" || "$STATUS" == "UPDATE_COMPLETE" ]]; then
    echo "[scale] $WORKER_NAME: already exists"
    DEPLOYED=$((DEPLOYED + 1))
    continue
  fi

  echo "[scale] $WORKER_NAME: deploying..."
  bash "$REPO_ROOT/scripts/aws/deploy-stack.sh" "$STACK_NAME" "$TEMPLATE" \
    "WorkerName=$WORKER_NAME" \
    "DockerImage=$ECR_IMAGE" \
    "InstanceType=t3.large" > /tmp/scale-${i}.log 2>&1 &
  PIDS+=($!)
  DEPLOYED=$((DEPLOYED + 1))

  # Batch throttle — wait for batch to complete before next
  if (( ${#PIDS[@]} >= BATCH_SIZE )); then
    echo "[scale] Waiting for batch of ${#PIDS[@]}..."
    for pid in "${PIDS[@]}"; do
      wait "$pid" 2>/dev/null || FAILED=$((FAILED + 1))
    done
    PIDS=()
    echo "[scale] Batch done. Deployed so far: $DEPLOYED (failed: $FAILED)"
  fi
done

# Wait for remaining
if (( ${#PIDS[@]} > 0 )); then
  echo "[scale] Waiting for final batch of ${#PIDS[@]}..."
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || FAILED=$((FAILED + 1))
  done
fi

echo ""
echo "[scale] Complete: $DEPLOYED deployed, $FAILED failed"
echo "[scale] Workers register with dispatcher automatically after boot"
echo "[scale] Monitor: bash scripts/fleet/api-status.sh workers"
