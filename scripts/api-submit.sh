#!/usr/bin/env bash
# Submit a task to the dispatcher API via docker-exec.
# Usage: bash scripts/fleet/api-submit.sh "task description" [--target-repo URL] [--sender NAME]
# secret-scan:ignore — no hardcoded secrets, all values from env vars or Secrets Manager

set -euo pipefail
FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$FLEET_DIR/../.." && pwd)"
source "$FLEET_DIR/../fleet-config.sh"

TEXT="${1:?Usage: api-submit.sh \"task description\" [--target-repo URL] [--sender NAME]}"
shift || true

TARGET_REPO=""
TARGET_WORKDIR=""
SENDER="Joel (local)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --target-workdir) TARGET_WORKDIR="$2"; shift 2 ;;
    --sender) SENDER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Build a python submit script that runs inside the container
# This avoids all the quoting/base64 issues with curl through SSH chains
SUBMIT_PY=$(cat <<'PYEOF'
import json, os, sys, urllib.request, urllib.error
# Auth credential from env or Secrets Manager (no hardcoded values)
auth_val = os.environ.get("DISPATCH_API_TOKEN") or ""
if not auth_val:
    import subprocess
    try:
        auth_val = subprocess.check_output([
            "aws", "secretsmanager", "get-secret-value",
            "--secret-id", "hackathon26/dispatch-api-token",
            "--query", "SecretString", "--output", "text",
            "--region", "us-east-2"
        ], text=True).strip()
    except Exception:
        pass
if not auth_val:
    print(json.dumps({"error": "No dispatch auth available"}))
    sys.exit(1)
payload = {"text": sys.argv[1], "sender": sys.argv[2]}
if len(sys.argv) > 3 and sys.argv[3]: payload["target_repo"] = sys.argv[3]
if len(sys.argv) > 4 and sys.argv[4]: payload["target_workdir"] = sys.argv[4]
data = json.dumps(payload).encode()
req = urllib.request.Request(
    "http://localhost:8080/api/submit",
    data=data,
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {auth_val}"},
    method="POST"
)
try:
    resp = urllib.request.urlopen(req)
    print(resp.read().decode())
except urllib.error.HTTPError as e:
    body = e.read().decode() if e.fp else ""
    print(json.dumps({"error": f"HTTP {e.code}", "detail": body}))
    sys.exit(1)
PYEOF
)

# Base64-encode the python script, write to /tmp inside container, execute with args
PY_B64=$(echo "$SUBMIT_PY" | base64 -w0)
# Args also base64-encoded to avoid quoting issues
ARGS_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "$TEXT" "$SENDER" "$TARGET_REPO" "$TARGET_WORKDIR")
ARGS_B64=$(echo "$ARGS_JSON" | base64 -w0)

EXEC_CMD="echo $PY_B64 | base64 -d > /tmp/_submit.py && echo $ARGS_B64 | base64 -d > /tmp/_submit_args.json && python3 -c \"
import json, sys
sys.argv = ['submit'] + json.load(open('/tmp/_submit_args.json'))
exec(open('/tmp/_submit.py').read())
\""

RESULT=$(bash "$REPO_ROOT/scripts/aws/docker-exec.sh" hackathon26-ccc-dispatcher-golden-image \
  "$EXEC_CMD" 2>&1)

echo "$RESULT"
