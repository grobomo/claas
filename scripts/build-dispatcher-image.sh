#!/usr/bin/env bash
# build-dispatcher-image.sh — Build dispatcher Docker image on the dispatcher host.
# Copies local files to the dispatcher, builds the image, optionally pushes to ECR.
#
# Usage: bash scripts/fleet/build-dispatcher-image.sh [--no-push]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/fleet-config.sh"
source "$REPO_ROOT/scripts/aws/common.sh"

NO_PUSH="${1:-}"
ECR_REPO="hackathon26/dispatcher"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
REMOTE_USER="ubuntu"
REMOTE_BUILD="/tmp/dispatcher-build-$$"

info "=== Building Dispatcher Image ==="

# ── 1. Create build context locally ─────────────────────────────────────────
BUILD_DIR="/tmp/dispatcher-build-local-$$"
mkdir -p "$BUILD_DIR/scripts/fleet" "$BUILD_DIR/dashboard" "$BUILD_DIR/cloudformation"

cp "$REPO_ROOT/cloudformation/Dockerfile.dispatcher" "$BUILD_DIR/Dockerfile"
cp "$REPO_ROOT/scripts/fleet/dispatcher-entrypoint.sh" "$BUILD_DIR/scripts/fleet/"
cp "$REPO_ROOT/scripts/fleet/git-dispatch-patched.py" "$BUILD_DIR/scripts/fleet/"
cp "$REPO_ROOT/scripts/fleet/aws-teams-poller.py" "$BUILD_DIR/scripts/fleet/"
cp "$REPO_ROOT/scripts/fleet/aws-coconut-worker.py" "$BUILD_DIR/scripts/fleet/"
cp "$REPO_ROOT/scripts/fleet/poller-supervisor.sh" "$BUILD_DIR/scripts/fleet/"
cp "$REPO_ROOT/dashboard/central-server.js" "$BUILD_DIR/dashboard/"
cp "$REPO_ROOT/dashboard/auth.js" "$BUILD_DIR/dashboard/"

info "Build context: $(du -sh "$BUILD_DIR" | cut -f1)"

# ── 2. Upload build context to dispatcher ────────────────────────────────────
info "Uploading build context to $DISPATCHER_IP..."
TAR_FILE="/tmp/dispatcher-build-$$.tar.gz"
cd "$BUILD_DIR"
tar czf "$TAR_FILE" .
scp $SSH_OPTS -i "$FLEET_SSH_KEY" "$TAR_FILE" "$REMOTE_USER@$DISPATCHER_IP:/tmp/dispatcher-build.tar.gz"
rm -f "$TAR_FILE"

# ── 3. Build on dispatcher host ─────────────────────────────────────────────
info "Building image on dispatcher..."
ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" bash -s <<'BUILDSCRIPT'
set -eu
BUILD_DIR="/tmp/dispatcher-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
tar xzf /tmp/dispatcher-build.tar.gz

echo "[build] Building hackathon26/dispatcher:latest..."
docker build -t hackathon26/dispatcher:latest .
echo "[build] Image built successfully."
docker images hackathon26/dispatcher:latest --format '{{.Repository}}:{{.Tag}} {{.Size}}'

rm -rf "$BUILD_DIR" /tmp/dispatcher-build.tar.gz
BUILDSCRIPT

# ── 4. Push to ECR (optional) ───────────────────────────────────────────────
if [ "$NO_PUSH" = "--no-push" ]; then
  info "Skipping ECR push (--no-push)."
else
  info "Pushing to ECR..."
  ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "$REMOTE_USER@$DISPATCHER_IP" bash -s -- "$ECR_URI" "$ACCOUNT_ID" "$AWS_REGION" <<'PUSHSCRIPT'
set -eu
ECR_URI="$1"
ACCOUNT_ID="$2"
AWS_REGION="$3"

# Ensure ECR repo exists
aws ecr describe-repositories --repository-names hackathon26/dispatcher --region "$AWS_REGION" 2>/dev/null || \
  aws ecr create-repository --repository-name hackathon26/dispatcher --region "$AWS_REGION"

# Login to ECR
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Tag and push
docker tag hackathon26/dispatcher:latest "${ECR_URI}:latest"
docker push "${ECR_URI}:latest"

TS_TAG="v$(date -u +%Y%m%d-%H%M%S)"
docker tag hackathon26/dispatcher:latest "${ECR_URI}:${TS_TAG}"
docker push "${ECR_URI}:${TS_TAG}"
echo "[push] Pushed ${ECR_URI}:latest and ${ECR_URI}:${TS_TAG}"
PUSHSCRIPT
fi

# ── Cleanup ─────────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
info "Dispatcher image build complete."
