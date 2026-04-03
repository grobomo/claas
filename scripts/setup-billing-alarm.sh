#!/usr/bin/env bash
# setup-billing-alarm.sh — Create CloudWatch billing alarms for CLaaS fleet.
# Creates two alarms:
#   1. Warning at $50/day (SNS notification)
#   2. Hard stop at $100/day (triggers auto-scale.sh --shutdown)
#
# Usage: bash scripts/fleet/setup-billing-alarm.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/aws/common.sh"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

WARN_THRESHOLD="${CLAAS_BUDGET_DAILY:-50}"
STOP_THRESHOLD="${CLAAS_BUDGET_HARD_STOP:-100}"
SNS_TOPIC_NAME="${PROJECT}-billing-alerts"
ALARM_PREFIX="${PROJECT}-billing"

log() { echo "[billing-alarm] $(date -u +%H:%M:%S) $*"; }

# --- Create SNS topic ---
log "Creating SNS topic: $SNS_TOPIC_NAME"
if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] Would create SNS topic $SNS_TOPIC_NAME"
    SNS_ARN="arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}"
else
    SNS_ARN=$(aws sns create-topic \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --name "$SNS_TOPIC_NAME" \
        --tags "$PROJECT_TAG" \
        --query 'TopicArn' --output text 2>/dev/null) || die "Failed to create SNS topic"
    log "SNS topic: $SNS_ARN"
fi

# --- Warning alarm ($50/day) ---
log "Creating warning alarm at \$$WARN_THRESHOLD/day"
if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] Would create CloudWatch alarm: ${ALARM_PREFIX}-warning"
else
    aws cloudwatch put-metric-alarm \
        --profile "$AWS_PROFILE" \
        --region us-east-1 \
        --alarm-name "${ALARM_PREFIX}-warning" \
        --alarm-description "CLaaS fleet daily cost exceeds \$$WARN_THRESHOLD" \
        --namespace "AWS/Billing" \
        --metric-name "EstimatedCharges" \
        --dimensions "Name=Currency,Value=USD" \
        --statistic Maximum \
        --period 21600 \
        --evaluation-periods 1 \
        --threshold "$WARN_THRESHOLD" \
        --comparison-operator GreaterThanThreshold \
        --alarm-actions "$SNS_ARN" \
        --tags "$PROJECT_TAG" \
        2>/dev/null && log "Warning alarm created" || log "WARN: Failed to create warning alarm"
fi

# --- Hard stop alarm ($100/day) ---
log "Creating hard-stop alarm at \$$STOP_THRESHOLD/day"
if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] Would create CloudWatch alarm: ${ALARM_PREFIX}-hard-stop"
else
    aws cloudwatch put-metric-alarm \
        --profile "$AWS_PROFILE" \
        --region us-east-1 \
        --alarm-name "${ALARM_PREFIX}-hard-stop" \
        --alarm-description "CLaaS fleet daily cost exceeds \$$STOP_THRESHOLD — TERMINATE ALL WORKERS" \
        --namespace "AWS/Billing" \
        --metric-name "EstimatedCharges" \
        --dimensions "Name=Currency,Value=USD" \
        --statistic Maximum \
        --period 21600 \
        --evaluation-periods 1 \
        --threshold "$STOP_THRESHOLD" \
        --comparison-operator GreaterThanThreshold \
        --alarm-actions "$SNS_ARN" \
        --tags "$PROJECT_TAG" \
        2>/dev/null && log "Hard-stop alarm created" || log "WARN: Failed to create hard-stop alarm"
fi

log "Done. Alarms: warning=\$$WARN_THRESHOLD, hard-stop=\$$STOP_THRESHOLD"
log "Subscribe to SNS topic for email alerts: aws sns subscribe --topic-arn $SNS_ARN --protocol email --notification-endpoint YOUR_EMAIL"
