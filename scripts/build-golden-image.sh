#!/usr/bin/env bash
# build-golden-image.sh — Build the golden Docker image and push to ECR.
# Must run on a Linux host (dispatcher or worker) with Docker.
#
# Usage: bash build-golden-image.sh [--no-push]
#
# Steps:
#   1. Build config-bundle (hooks, rules, skills, settings, CLAUDE.md)
#   2. Prepare build context (Dockerfile.golden + config-bundle + entrypoint)
#   3. Build base claude-portable image (if not present)
#   4. Build golden image on top
#   5. Tag and push to ECR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load common constants
source "$REPO_ROOT/scripts/aws/common.sh"

# Pin Claude version — see .claude/rules/claude-version-pin.md
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.77}"
ECR_REPO="hackathon26/worker"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
TAG="latest"
NO_PUSH="${1:-}"

PORTABLE_DIR="${PORTABLE_DIR:-/home/claude/workspace/claude-portable}"
BUNDLE_SKILL="$PORTABLE_DIR/config/claude-defaults/skills/config-bundle"
BUILD_DIR="/tmp/golden-image-build-$$"

# ── 1. Build config-bundle ──────────────────────────────────────────────────────
info "Building config-bundle..."
if [ -d "$BUNDLE_SKILL" ] && [ -f "$BUNDLE_SKILL/bundle.js" ]; then
  export BUNDLE_TARGET=worker
  export HACKATHON_DIR="$REPO_ROOT"
  export HACKATHON_SYNC=0
  cd "$BUNDLE_SKILL"
  node bundle.js

  BUNDLE_TAR=$(ls -t output/config-bundle-*.tar.gz 2>/dev/null | head -1)
  if [ -z "$BUNDLE_TAR" ]; then
    die "No tar.gz produced by bundle.js"
  fi
  BUNDLE_TAR="$BUNDLE_SKILL/$BUNDLE_TAR"
  info "Bundle: $BUNDLE_TAR"
else
  # Fallback: use claude-defaults directory directly
  info "config-bundle skill not found, using claude-defaults directly"
  BUNDLE_TAR=""
fi
cd "$REPO_ROOT"

# ── 2. Prepare build context ────────────────────────────────────────────────────
info "Preparing build context at $BUILD_DIR..."
mkdir -p "$BUILD_DIR/config-bundle"

# Copy Dockerfile and entrypoint
cp "$REPO_ROOT/cloudformation/Dockerfile.golden" "$BUILD_DIR/Dockerfile.golden"
cp "$REPO_ROOT/scripts/fleet/golden-entrypoint.sh" "$BUILD_DIR/golden-entrypoint.sh"

# Extract config-bundle or copy defaults
if [ -n "$BUNDLE_TAR" ]; then
  tar xzf "$BUNDLE_TAR" -C "$BUILD_DIR/config-bundle/" --strip-components=1
elif [ -d "$PORTABLE_DIR/config/claude-defaults" ]; then
  cp -r "$PORTABLE_DIR/config/claude-defaults/"* "$BUILD_DIR/config-bundle/"
fi

# Extract MCP bundle (Blueprint MCP + mcp-manager) if present
MCP_BUNDLE="${MCP_BUNDLE:-/tmp/mcp-bundle.tar.gz}"
if [ -f "$MCP_BUNDLE" ]; then
  info "Including MCP bundle from $MCP_BUNDLE..."
  mkdir -p "$BUILD_DIR/mcp-bundle"
  tar xzf "$MCP_BUNDLE" -C "$BUILD_DIR/mcp-bundle/"
else
  info "No MCP bundle at $MCP_BUNDLE — skipping (workers won't have Blueprint MCP)"
fi

# ── 3. Build base image (if not present) ────────────────────────────────────────
if ! docker image inspect claude-portable:latest >/dev/null 2>&1; then
  info "Building base claude-portable image (Claude $CLAUDE_CODE_VERSION)..."
  cd "$PORTABLE_DIR"
  docker build --build-arg CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" -t claude-portable:latest .
  cd "$REPO_ROOT"
else
  info "Base image claude-portable:latest exists."
fi

# ── 4. Build golden image ──────────────────────────────────────────────────────
info "Building golden image..."
cd "$BUILD_DIR"
docker build -f Dockerfile.golden -t "${ECR_REPO}:${TAG}" .

# ── 5. Tag and push to ECR ─────────────────────────────────────────────────────
if [ "$NO_PUSH" = "--no-push" ]; then
  info "Skipping push (--no-push)."
else
  info "Authenticating with ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  info "Tagging and pushing to $ECR_URI:$TAG..."
  docker tag "${ECR_REPO}:${TAG}" "${ECR_URI}:${TAG}"
  docker push "${ECR_URI}:${TAG}"

  # Also tag with timestamp for rollback
  TS_TAG="v$(date -u +%Y%m%d-%H%M%S)"
  docker tag "${ECR_REPO}:${TAG}" "${ECR_URI}:${TS_TAG}"
  docker push "${ECR_URI}:${TS_TAG}"
  info "Pushed: ${ECR_URI}:${TAG} and ${ECR_URI}:${TS_TAG}"
fi

# ── Cleanup ────────────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
info "Golden image build complete."
