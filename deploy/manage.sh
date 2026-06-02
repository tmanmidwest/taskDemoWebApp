#!/bin/bash
# =============================================================================
# manage.sh — taskDemoWebApp (TaskFlow) Day-to-Day Management
# =============================================================================
# Usage:
#   ./manage.sh status      — show current app status and URL
#   ./manage.sh stop        — pause the app (no AWS compute charges, data kept)
#   ./manage.sh start       — resume the app after stopping
#   ./manage.sh restart     — force a restart (also pulls latest image)
#   ./manage.sh logs        — stream live logs (Ctrl+C to stop)
#   ./manage.sh url         — print the app URL
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CHECKMARK="${GREEN}✔${NC}"
ARROW="${BLUE}▶${NC}"
WARNING="${YELLOW}⚠${NC}"

STATE_FILE=".task-demo-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }
skip()    { echo -e "  ${YELLOW}↷  Skipping: $1${NC}"; }

# ── AWS SESSION VALIDATION ────────────────────────────────────────────────────
header "Validating AWS session"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session and try again."

SESSION_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $SESSION_ACCOUNT)"

[ -f "$STATE_FILE" ] || error "No state file found ($STATE_FILE). Deploy the app first with ./deploy.sh"
# shellcheck source=/dev/null
source "$STATE_FILE"

CMD="${1:-help}"

case "$CMD" in

  # ── STATUS ──────────────────────────────────────────────────────────────────
  status)
    echo ""
    echo -e "${BOLD}  TaskFlow (taskDemoWebApp) — Status${NC}"
    echo -e "  ─────────────────────────────────────────"

    SVC=$(aws ecs describe-services \
      --cluster "$APP_NAME" \
      --services "${APP_NAME}-webapp" \
      --region "$REGION" \
      --query 'services[0]' \
      --output json 2>/dev/null)

    DESIRED=$(echo "$SVC" | python3 -c "import sys,json; print(json.load(sys.stdin)['desiredCount'])" 2>/dev/null || echo "?")
    RUNNING=$(echo "$SVC" | python3 -c "import sys,json; print(json.load(sys.stdin)['runningCount'])" 2>/dev/null || echo "?")
    STATUS=$(echo "$SVC"  | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "?")

    HEALTH=$(aws elbv2 describe-target-health \
      --target-group-arn "$TG_ARN" \
      --region "$REGION" \
      --query 'TargetHealthDescriptions[0].TargetHealth.State' \
      --output text 2>/dev/null || echo "unknown")

    if [ "$RUNNING" = "0" ] && [ "$DESIRED" = "0" ]; then
      APP_STATUS="${YELLOW}Stopped${NC}"
    elif [ "$RUNNING" = "$DESIRED" ] && [ "$HEALTH" = "healthy" ]; then
      APP_STATUS="${GREEN}Running${NC}"
    else
      APP_STATUS="${YELLOW}Starting / Unhealthy${NC}"
    fi

    echo -e "  App status:    $(echo -e $APP_STATUS)"
    echo -e "  ECS status:    $STATUS"
    echo -e "  Running tasks: $RUNNING / $DESIRED desired"
    echo -e "  ALB health:    $HEALTH"
    echo -e "  Region:        $REGION"
    echo ""
    echo -e "  ${BOLD}URL:${NC}       http://${ALB_DNS}/"
    echo -e "  ${BOLD}API Docs:${NC}  http://${ALB_DNS}/docs"
    echo ""
    ;;

  # ── STOP ────────────────────────────────────────────────────────────────────
  stop)
    echo ""
    log "Stopping TaskFlow (setting desired count to 0)..."
    log "Your data on EFS is safe and will still be there when you restart."
    echo ""
    aws ecs update-service \
      --cluster "$APP_NAME" \
      --service "${APP_NAME}-webapp" \
      --desired-count 0 \
      --region "$REGION" >/dev/null
    success "App stopped. You are no longer being charged for Fargate compute."
    echo ""
    warn "The ALB still runs and incurs a small charge (~\$0.50/day)."
    warn "Run ./teardown.sh to remove all resources and stop all charges."
    echo ""
    echo -e "  Run ${BOLD}./manage.sh start${NC} to resume."
    echo ""
    ;;

  # ── START ────────────────────────────────────────────────────────────────────
  start)
    echo ""
    log "Starting TaskFlow..."
    aws ecs update-service \
      --cluster "$APP_NAME" \
      --service "${APP_NAME}-webapp" \
      --desired-count 1 \
      --region "$REGION" >/dev/null

    log "Waiting for the app to become healthy (takes ~2 minutes)..."
    echo ""
    attempt=0
    while [ $attempt -lt 30 ]; do
      RUNNING=$(aws ecs describe-services \
        --cluster "$APP_NAME" \
        --services "${APP_NAME}-webapp" \
        --query 'services[0].runningCount' \
        --output text --region "$REGION" 2>/dev/null || echo "0")
      HEALTH=$(aws elbv2 describe-target-health \
        --target-group-arn "$TG_ARN" \
        --query 'TargetHealthDescriptions[0].TargetHealth.State' \
        --output text --region "$REGION" 2>/dev/null || echo "unknown")
      echo -ne "  Running tasks: ${RUNNING} | ALB health: ${HEALTH}\r"
      if [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ]; then
        echo ""
        break
      fi
      sleep 10
      attempt=$((attempt + 1))
    done

    echo ""
    success "App is running!"
    echo ""
    echo -e "  ${BOLD}URL:${NC}  http://${ALB_DNS}/"
    echo ""
    ;;

  # ── RESTART ──────────────────────────────────────────────────────────────────
  restart)
    echo ""
    log "Forcing a new deployment (also pulls the latest container image)..."
    aws ecs update-service \
      --cluster "$APP_NAME" \
      --service "${APP_NAME}-webapp" \
      --force-new-deployment \
      --region "$REGION" >/dev/null

    log "Waiting for new task to become healthy..."
    echo ""
    attempt=0
    while [ $attempt -lt 30 ]; do
      RUNNING=$(aws ecs describe-services \
        --cluster "$APP_NAME" \
        --services "${APP_NAME}-webapp" \
        --query 'services[0].runningCount' \
        --output text --region "$REGION" 2>/dev/null || echo "0")
      HEALTH=$(aws elbv2 describe-target-health \
        --target-group-arn "$TG_ARN" \
        --query 'TargetHealthDescriptions[0].TargetHealth.State' \
        --output text --region "$REGION" 2>/dev/null || echo "unknown")
      echo -ne "  Running tasks: ${RUNNING} | ALB health: ${HEALTH}\r"
      if [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ]; then
        echo ""
        break
      fi
      sleep 10
      attempt=$((attempt + 1))
    done

    echo ""
    success "App restarted successfully. Your data is intact."
    echo ""
    echo -e "  ${BOLD}URL:${NC}  http://${ALB_DNS}/"
    echo ""
    ;;

  # ── LOGS ─────────────────────────────────────────────────────────────────────
  logs)
    echo ""
    log "Streaming live logs from ${LOG_GROUP} (press Ctrl+C to stop)..."
    echo ""
    aws logs tail "$LOG_GROUP" \
      --follow \
      --region "$REGION"
    ;;

  # ── URL ──────────────────────────────────────────────────────────────────────
  url)
    echo ""
    echo -e "  ${BOLD}App URL:${NC}   http://${ALB_DNS}/"
    echo -e "  ${BOLD}API Docs:${NC}  http://${ALB_DNS}/docs"
    echo -e "  ${BOLD}Health:${NC}    http://${ALB_DNS}/health"
    echo ""
    ;;

  # ── HELP ─────────────────────────────────────────────────────────────────────
  help|*)
    echo ""
    echo -e "${BOLD}  TaskFlow (taskDemoWebApp) — Management Commands${NC}"
    echo ""
    echo -e "  ${BOLD}./manage.sh status${NC}   Show current status and URL"
    echo -e "  ${BOLD}./manage.sh stop${NC}     Pause the app (data kept, compute charges stop)"
    echo -e "  ${BOLD}./manage.sh start${NC}    Resume after stopping"
    echo -e "  ${BOLD}./manage.sh restart${NC}  Force restart and pull latest image"
    echo -e "  ${BOLD}./manage.sh logs${NC}     Stream live logs (Ctrl+C to stop)"
    echo -e "  ${BOLD}./manage.sh url${NC}      Print the app URL"
    echo ""
    echo -e "  ${BOLD}./deploy.sh${NC}          Deploy everything from scratch"
    echo -e "  ${BOLD}./update.sh${NC}          Rebuild and redeploy from latest GitHub source"
    echo -e "  ${BOLD}./teardown.sh${NC}        Delete all AWS resources permanently"
    echo ""
    ;;
esac
