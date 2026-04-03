#!/usr/bin/env bash
# merge-bot.sh — Sequential PR merge bot for CLaaS.
# Merges PRs oldest-first with auto-rebase. Retries up to 3 times per PR.
#
# Usage:
#   bash scripts/fleet/merge-bot.sh                    # one-shot
#   bash scripts/fleet/merge-bot.sh --loop             # continuous (every 2 min)
#   bash scripts/fleet/merge-bot.sh --dry-run          # show what would happen
#   bash scripts/fleet/merge-bot.sh --repo owner/repo  # target repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TARGET_REPO="${TARGET_REPO:-altarr/boothapp}"
MAX_ATTEMPTS=3
LOOP=false
DRY_RUN=false
LOOP_INTERVAL=120

while [[ $# -gt 0 ]]; do
    case "$1" in
        --loop) LOOP=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --repo) TARGET_REPO="$2"; shift 2 ;;
        *) shift ;;
    esac
done

log() { echo "[merge-bot] $(date -u +%H:%M:%S) $*"; }

merge_prs() {
    # Get open PRs sorted by creation date (oldest first)
    local prs
    prs=$(gh pr list --repo "$TARGET_REPO" --state open --json number,title,createdAt,headRefName,mergeable \
        --jq 'sort_by(.createdAt) | .[] | "\(.number)\t\(.title)\t\(.headRefName)\t\(.mergeable)"' 2>/dev/null || echo "")

    if [ -z "$prs" ]; then
        log "No open PRs"
        return
    fi

    local merged=0 failed=0

    while IFS=$'\t' read -r pr_num title branch mergeable; do
        [ -z "$pr_num" ] && continue
        log "PR #$pr_num: $title (branch: $branch, mergeable: $mergeable)"

        if [ "$mergeable" = "CONFLICTING" ]; then
            log "  PR #$pr_num has conflicts — attempting rebase"
            if [ "$DRY_RUN" = "true" ]; then
                log "  [DRY-RUN] Would attempt rebase for PR #$pr_num"
                continue
            fi

            # Try to update the branch (rebase onto base)
            local attempt=0 rebased=false
            while [ $attempt -lt $MAX_ATTEMPTS ]; do
                attempt=$((attempt + 1))
                if gh pr update-branch "$pr_num" --repo "$TARGET_REPO" --rebase 2>/dev/null; then
                    log "  Rebased PR #$pr_num (attempt $attempt)"
                    rebased=true
                    sleep 5  # wait for GH to process
                    break
                else
                    log "  Rebase attempt $attempt failed"
                    sleep 3
                fi
            done

            if [ "$rebased" != "true" ]; then
                log "  SKIP: PR #$pr_num — rebase failed after $MAX_ATTEMPTS attempts"
                failed=$((failed + 1))
                continue
            fi
        fi

        # Merge (squash)
        if [ "$DRY_RUN" = "true" ]; then
            log "  [DRY-RUN] Would squash-merge PR #$pr_num"
            merged=$((merged + 1))
            continue
        fi

        local attempt=0
        while [ $attempt -lt $MAX_ATTEMPTS ]; do
            attempt=$((attempt + 1))
            if gh pr merge "$pr_num" --repo "$TARGET_REPO" --squash --delete-branch 2>/dev/null; then
                log "  MERGED PR #$pr_num (attempt $attempt)"
                merged=$((merged + 1))
                sleep 3  # let GH update before next PR
                break
            else
                log "  Merge attempt $attempt failed — waiting for CI or rebase"
                sleep 10
            fi
        done

        if [ $attempt -ge $MAX_ATTEMPTS ]; then
            log "  FAILED: PR #$pr_num after $MAX_ATTEMPTS attempts"
            failed=$((failed + 1))
        fi
    done <<< "$prs"

    log "Summary: $merged merged, $failed failed"
}

if [ "$LOOP" = "true" ]; then
    log "Starting merge bot loop (interval=${LOOP_INTERVAL}s, repo=$TARGET_REPO)"
    while true; do
        merge_prs
        sleep "$LOOP_INTERVAL"
    done
else
    merge_prs
fi
