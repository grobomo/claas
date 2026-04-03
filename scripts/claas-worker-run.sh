#!/usr/bin/env bash
# claas-worker-run.sh — Worker-side task execution script.
# Deployed to worker by dispatcher. Handles full lifecycle:
#   pull latest → branch → claude -p with repo context → rebase → push → PR → report back
#
# Usage: bash claas-worker-run.sh (reads env vars set by dispatcher)
# Required env: TASK_ID, TASK_PROMPT, DISPATCHER_URL, TARGET_REPO (e.g. altarr/boothapp)
# Optional env: TARGET_BRANCH (default: main), WORKER_NAME (default: hostname)

set -euo pipefail

TASK_ID="${TASK_ID:?TASK_ID required}"
TASK_PROMPT="${TASK_PROMPT:?TASK_PROMPT required}"
DISPATCHER_URL="${DISPATCHER_URL:?DISPATCHER_URL required}"
TARGET_REPO="${TARGET_REPO:-altarr/boothapp}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
WORKER_NAME="${WORKER_NAME:-$(hostname)}"
WORKSPACE="${CLAAS_WORKSPACE:-$HOME/workspace}"
MAX_RETRIES=2

log() { echo "[worker-run] $(date -u +%H:%M:%S) $*"; }

# Report result back to dispatcher
report_result() {
    local status="$1" output="$2" pr_url="${3:-}"
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'status': sys.argv[1],
    'output': sys.argv[2][:2000],
    'pr_url': sys.argv[3],
    'worker': sys.argv[4]
}))
" "$status" "$output" "$pr_url" "$WORKER_NAME")

    curl -sf -X POST "${DISPATCHER_URL}/api/v1/task/${TASK_ID}/result" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1 || log "WARN: Failed to report result"
}

# Send heartbeat to dispatcher
heartbeat() {
    local phase="$1"
    curl -sf -X POST "${DISPATCHER_URL}/api/v1/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"worker\":\"$WORKER_NAME\",\"task_id\":\"$TASK_ID\",\"phase\":\"$phase\"}" \
        >/dev/null 2>&1 || true
}

# Derive branch name from task ID + prompt
branch_name() {
    local slug
    slug=$(echo "$TASK_PROMPT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | head -c 40 | sed 's/-$//')
    echo "claas-${TASK_ID}-${slug}"
}

# ── 1. Clone or update the target repo ────────────────────────────────────────
log "Phase 1: Preparing repo ${TARGET_REPO}..."
heartbeat "preparing_repo"

REPO_NAME=$(basename "$TARGET_REPO")
REPO_DIR="$WORKSPACE/$REPO_NAME"

if [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR"
    git checkout "$TARGET_BRANCH" 2>/dev/null || git checkout -b "$TARGET_BRANCH"
    git fetch origin "$TARGET_BRANCH" --prune 2>/dev/null || true
    git reset --hard "origin/$TARGET_BRANCH" 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    log "Repo updated."
else
    cd "$WORKSPACE"
    git clone "https://github.com/${TARGET_REPO}.git" "$REPO_NAME" 2>/dev/null || {
        report_result "failed" "Failed to clone ${TARGET_REPO}"
        exit 1
    }
    cd "$REPO_DIR"
    log "Repo cloned."
fi

# ── 2. Create task branch ─────────────────────────────────────────────────────
BRANCH=$(branch_name)
log "Phase 2: Creating branch ${BRANCH}..."
heartbeat "creating_branch"

git checkout -b "$BRANCH" 2>/dev/null || {
    # Branch may already exist from a retry
    git checkout "$BRANCH" 2>/dev/null
    git reset --hard "origin/$TARGET_BRANCH" 2>/dev/null || true
}

# ── 3. Read repo context (CLAUDE.md if exists) ────────────────────────────────
CONTEXT=""
if [ -f "CLAUDE.md" ]; then
    CONTEXT=$(head -200 CLAUDE.md)
    log "Read CLAUDE.md ($(wc -l < CLAUDE.md) lines)"
fi

# ── 4. Run claude -p with full context ────────────────────────────────────────
log "Phase 3: Running claude -p..."
heartbeat "running_claude"

FULL_PROMPT="You are working in the ${TARGET_REPO} repository on branch ${BRANCH}.

TASK: ${TASK_PROMPT}

INSTRUCTIONS:
- Make the changes requested in the task
- Create or modify files as needed
- Keep changes minimal and focused
- Do not modify unrelated code
- Run tests if test scripts exist"

if [ -n "$CONTEXT" ]; then
    FULL_PROMPT="${FULL_PROMPT}

REPO CONTEXT (from CLAUDE.md):
${CONTEXT}"
fi

# Write prompt to file to avoid quoting issues
echo "$FULL_PROMPT" > /tmp/claas-task-prompt.txt

# Run claude with timeout (10 min)
CLAUDE_OUTPUT=""
if timeout 600 claude -p "$(cat /tmp/claas-task-prompt.txt)" \
    --allowedTools Edit,Write,Bash,Read,Glob,Grep \
    > /tmp/claas-claude-output.txt 2>&1; then
    CLAUDE_OUTPUT=$(tail -50 /tmp/claas-claude-output.txt)
    log "Claude completed successfully."
else
    EXIT_CODE=$?
    CLAUDE_OUTPUT=$(tail -50 /tmp/claas-claude-output.txt 2>/dev/null || echo "No output")
    if [ $EXIT_CODE -eq 124 ]; then
        log "Claude timed out (10 min)."
        report_result "failed" "Claude timed out after 10 minutes. Output: ${CLAUDE_OUTPUT}"
        exit 1
    fi
    log "Claude exited with code ${EXIT_CODE}."
fi

# ── 5. Check if any changes were made ─────────────────────────────────────────
if git diff --quiet && git diff --cached --quiet; then
    log "No changes made by Claude."
    report_result "completed" "No changes needed. Claude output: ${CLAUDE_OUTPUT}"
    exit 0
fi

# ── 6. Commit changes ─────────────────────────────────────────────────────────
log "Phase 4: Committing changes..."
heartbeat "committing"

git add -A
git commit -m "$(cat <<EOF
CLaaS ${TASK_ID}: ${TASK_PROMPT}

Auto-implemented by ${WORKER_NAME} via CLaaS v2.
EOF
)" 2>/dev/null || {
    log "Nothing to commit after add."
    report_result "completed" "No staged changes. Claude output: ${CLAUDE_OUTPUT}"
    exit 0
}

# ── 7. Rebase from main before push ───────────────────────────────────────────
log "Phase 5: Rebasing from ${TARGET_BRANCH}..."
heartbeat "rebasing"

REBASE_OK=true
for attempt in $(seq 1 $MAX_RETRIES); do
    git fetch origin "$TARGET_BRANCH" 2>/dev/null || true
    if git rebase "origin/$TARGET_BRANCH" 2>/dev/null; then
        REBASE_OK=true
        break
    else
        git rebase --abort 2>/dev/null || true
        REBASE_OK=false
        log "Rebase attempt $attempt failed."
        sleep 2
    fi
done

if [ "$REBASE_OK" != "true" ]; then
    log "Rebase failed after $MAX_RETRIES attempts."
    report_result "conflict" "Rebase conflict with ${TARGET_BRANCH}. Claude output: ${CLAUDE_OUTPUT}"
    exit 1
fi

# ── 8. Push branch ────────────────────────────────────────────────────────────
log "Phase 6: Pushing branch..."
heartbeat "pushing"

if ! git push -u origin "$BRANCH" 2>/dev/null; then
    # Force push on retry (branch may exist from previous attempt)
    git push --force-with-lease origin "$BRANCH" 2>/dev/null || {
        report_result "failed" "Git push failed. Claude output: ${CLAUDE_OUTPUT}"
        exit 1
    }
fi

# ── 9. Create PR ──────────────────────────────────────────────────────────────
log "Phase 7: Creating PR..."
heartbeat "creating_pr"

PR_BODY="## CLaaS Task ${TASK_ID}

**Prompt:** ${TASK_PROMPT}
**Worker:** ${WORKER_NAME}
**Branch:** ${BRANCH}

### Auto-generated by CLaaS v2"

PR_URL=""
PR_URL=$(gh pr create \
    --repo "$TARGET_REPO" \
    --base "$TARGET_BRANCH" \
    --head "$BRANCH" \
    --title "CLaaS ${TASK_ID}: $(echo "$TASK_PROMPT" | head -c 60)" \
    --body "$PR_BODY" 2>&1) || {
    # PR creation failed — maybe PR already exists
    EXISTING=$(gh pr list --repo "$TARGET_REPO" --head "$BRANCH" --json url --jq '.[0].url' 2>/dev/null || echo "")
    if [ -n "$EXISTING" ]; then
        PR_URL="$EXISTING"
        log "PR already exists: $PR_URL"
    else
        log "PR creation failed: $PR_URL"
        report_result "completed" "Pushed to ${BRANCH} but PR creation failed. Claude output: ${CLAUDE_OUTPUT}"
        exit 0
    fi
}

log "PR created: $PR_URL"

# ── 10. Report success ────────────────────────────────────────────────────────
heartbeat "completed"
report_result "completed" "PR: ${PR_URL}. Claude output: ${CLAUDE_OUTPUT}" "$PR_URL"
log "Done. Task ${TASK_ID} complete."
