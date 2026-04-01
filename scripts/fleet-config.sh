#!/usr/bin/env bash
# Shared fleet configuration — source this from other scripts.
# Update IPs and keys here when infrastructure changes.

KEY_DIR="$HOME/.ssh/ccc-keys"
FLEET_SSH_KEY="$KEY_DIR/claude-portable-key.pem"
DISPATCHER_KEY="$FLEET_SSH_KEY"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o LogLevel=ERROR"

# Phase 8 fleet — IPs updated 2026-04-01 (demo day)
# All stacks use hackathon26- prefix, tagged Project=hackathon26
NGINX_IP="${NGINX_HOST}"   # hackathon26-nginx
DISPATCHER_IP="${DISPATCHER_HOST}"   # hackathon26-ccc-dispatcher-golden-image

# Public IPs (for SSH from local machine)
declare -A WORKERS=(
  [hackathon26-worker-2]="16.58.32.121"
  [hackathon26-worker-4]="3.151.224.48"
  [hackathon26-worker-5]="18.219.252.36"
  [hackathon26-worker-7]="3.143.122.62"
  [hackathon26-worker-8]="3.141.185.78"
  [hackathon26-worker-24]="13.59.183.234"
  [hackathon26-worker-32]="3.133.225.58"
  [hackathon26-worker-58]="3.146.250.114"
  [hackathon26-worker-63]="3.151.183.223"
  [hackathon26-worker-83]="3.130.146.6"
)

# Private IPs (for dispatcher -> worker SSH inside VPC)
declare -A WORKER_PRIVATE_IPS=(
  [hackathon26-worker-2]="172.31.25.226"
  [hackathon26-worker-4]="172.31.29.107"
  [hackathon26-worker-5]="172.31.28.5"
  [hackathon26-worker-7]="172.31.16.68"
  [hackathon26-worker-8]="172.31.24.233"
  [hackathon26-worker-24]="172.31.24.115"
  [hackathon26-worker-32]="172.31.21.175"
  [hackathon26-worker-58]="172.31.26.193"
  [hackathon26-worker-63]="172.31.25.153"
  [hackathon26-worker-83]="172.31.19.206"
)

# Helpers
worker_key() { echo "$FLEET_SSH_KEY"; }
ssh_cmd() {
  local host="$1"; shift
  ssh $SSH_OPTS -i "$FLEET_SSH_KEY" "ubuntu@$host" "$@"
}
dispatcher_ssh() { ssh_cmd "$DISPATCHER_IP" "$@"; }
dispatcher_exec() { dispatcher_ssh "docker exec claude-portable $*"; }
worker_ssh() { local w="$1"; shift; ssh_cmd "${WORKERS[$w]}" "$@"; }
