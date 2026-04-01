#!/usr/bin/env bash
# claas-client.sh — CLaaS (Claude-as-a-Service) CLI client
# Submit tasks to the CCC fleet and wait for results.
#
# Usage:
#   bash scripts/fleet/claas-client.sh "What is the capital of France?"
#   bash scripts/fleet/claas-client.sh --token demo "Build a hello world app"
#   CLAAS_TOKEN=team-alpha bash scripts/fleet/claas-client.sh "Refactor the auth module"
#
# Environment:
#   CLAAS_URL    — API base URL (default: https://your-claas-host)
#   CLAAS_TOKEN  — Bearer token (default: hackathon26)
#   CLAAS_POLL   — Poll interval in seconds (default: 10)
set -euo pipefail

CLAAS_URL="${CLAAS_URL:-https://your-claas-host}"
CLAAS_TOKEN="${CLAAS_TOKEN:-your-admin-token}"
CLAAS_POLL="${CLAAS_POLL:-10}"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) CLAAS_TOKEN="$2"; shift 2;;
    --url)   CLAAS_URL="$2"; shift 2;;
    --poll)  CLAAS_POLL="$2"; shift 2;;
    --help|-h)
      echo "Usage: claas-client.sh [--token TOKEN] [--url URL] [--poll SECONDS] \"task text\""
      echo ""
      echo "Tokens: configured via /api/v1/tokens"
      echo "Default URL: https://your-claas-host"
      exit 0;;
    *) TASK_TEXT="$1"; shift;;
  esac
done

if [ -z "${TASK_TEXT:-}" ]; then
  echo "Error: no task text provided"
  echo "Usage: claas-client.sh \"your task description\""
  exit 1
fi

CURL_OPTS="-s --insecure"

# Submit
echo "Submitting task..."
RESPONSE=$(curl $CURL_OPTS -X POST "$CLAAS_URL/api/v1/submit" \
  -H "Authorization: Bearer $CLAAS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"text\": \"$TASK_TEXT\"}")

TASK_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])" 2>/dev/null || true)

if [ -z "$TASK_ID" ]; then
  echo "Error: failed to submit task"
  echo "$RESPONSE"
  exit 1
fi

echo "Task ID: $TASK_ID"
echo "Polling every ${CLAAS_POLL}s..."
echo ""

# Poll for completion
LAST_STEP=""
while true; do
  STATUS=$(curl $CURL_OPTS "$CLAAS_URL/api/v1/task/$TASK_ID" \
    -H "Authorization: Bearer $CLAAS_TOKEN")

  STATE=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','UNKNOWN'))" 2>/dev/null)
  STEP=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('current_step',''))" 2>/dev/null)

  # Show new steps
  if [ "$STEP" != "$LAST_STEP" ] && [ -n "$STEP" ]; then
    TS=$(date -u +"%H:%M:%S")
    case "$STEP" in
      generating_spec) echo "[$TS] Generating specification...";;
      spec_ready)      echo "[$TS] Specification ready";;
      dispatched_to_worker) echo "[$TS] Dispatched to worker";;
      worker_completed) echo "[$TS] Worker completed!";;
      error)           echo "[$TS] Error occurred";;
      *)               echo "[$TS] $STEP";;
    esac
    LAST_STEP="$STEP"
  fi

  if [ "$STATE" = "COMPLETED" ]; then
    RESULT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','(no result)'))" 2>/dev/null)
    echo ""
    echo "=== Result ==="
    echo "$RESULT"
    exit 0
  elif [ "$STATE" = "FAILED" ]; then
    ERROR=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown error'))" 2>/dev/null)
    echo ""
    echo "=== Failed ==="
    echo "$ERROR"
    exit 1
  fi

  sleep "$CLAAS_POLL"
done
