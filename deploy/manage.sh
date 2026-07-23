#!/bin/bash
# =============================================================================
# manage.sh — taskDemoWebApp (TaskFlow) Day-to-Day Management
# =============================================================================
# Usage:
#   ./manage.sh status      — show current app status and URL
#   ./manage.sh stop        — pause the app (no AWS compute charges, data kept)
#   ./manage.sh start       — resume the app after stopping
#   ./manage.sh restart     — force a restart (also pulls latest image)
#   ./manage.sh seed        — load sample users and tasks into an existing deployment
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

# ── SELECT DEPLOYMENT INSTANCE ────────────────────────────────────────────────
# Find every instance's state file. Set INSTANCE=<name> to pick one directly;
# otherwise use the only one, or choose from a list when several exist.
shopt -s nullglob
STATE_FILES=( .task-demo-state* )
shopt -u nullglob

[ "${#STATE_FILES[@]}" -gt 0 ] || error "No deployment found. Deploy first with ./deploy.sh"

STATE_FILE=""
if [ -n "${INSTANCE:-}" ]; then
  for f in "${STATE_FILES[@]}"; do
    grep -q "^APP_NAME=${INSTANCE}$" "$f" && { STATE_FILE="$f"; break; }
  done
  [ -n "$STATE_FILE" ] || error "No deployment found for instance '${INSTANCE}'."
elif [ "${#STATE_FILES[@]}" -eq 1 ]; then
  STATE_FILE="${STATE_FILES[0]}"
else
  echo ""
  echo -e "  ${BOLD}Multiple deployments found — choose one:${NC}"
  i=1
  for f in "${STATE_FILES[@]}"; do
    nm=$(grep '^APP_NAME=' "$f" | cut -d= -f2)
    rg=$(grep '^REGION=' "$f" | cut -d= -f2)
    echo -e "    ${BOLD}${i})${NC} ${nm}  (${rg})"
    i=$((i + 1))
  done
  echo ""
  read -rp "  Select [1-${#STATE_FILES[@]}]: " sel
  { [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#STATE_FILES[@]}" ]; } \
    || error "Invalid selection."
  STATE_FILE="${STATE_FILES[$((sel - 1))]}"
fi

# shellcheck source=/dev/null
source "$STATE_FILE"

# Resolve the public base URL — HTTPS custom domain if enabled, else the ALB DNS name
if [ "${ENABLE_HTTPS:-false}" = "true" ] && [ -n "${DOMAIN_NAME:-}" ]; then
  APP_BASE="https://${DOMAIN_NAME}"
else
  APP_BASE="http://${ALB_DNS}"
fi

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
    echo -e "  ${BOLD}URL:${NC}       ${APP_BASE}/"
    echo -e "  ${BOLD}API Docs:${NC}  ${APP_BASE}/docs"
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
    echo -e "  ${BOLD}URL:${NC}  ${APP_BASE}/"
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
    echo -e "  ${BOLD}URL:${NC}  ${APP_BASE}/"
    echo ""
    ;;

  # ── SEED SAMPLE DATA ─────────────────────────────────────────────────────────
  # The app seeds sample users/tasks at startup only when TASKAPP_SEED_SAMPLE=true.
  # We flip it on, restart so seed() runs, then flip it back off — so a later
  # restart can't silently resurrect users a demo has just deprovisioned.
  seed)
    echo ""
    echo -e "${BOLD}  Load sample data into ${APP_NAME}${NC}"
    echo ""
    echo -e "  This restarts the app twice (~4 minutes) and creates, if missing:"
    echo -e "    • Maria Lopez    — Manager"
    echo -e "    • Devon Carter   — Sales Rep"
    echo -e "    • Aisha Khan     — Technical Support"
    echo -e "    • 3 example tasks assigned to them"
    echo ""
    echo -e "  Existing users and tasks are left alone. Your admin is unaffected."
    echo ""
    read -rp "  Continue? [y/N] " seed_confirm
    [[ "$seed_confirm" =~ ^[Yy]$ ]] || { echo "Aborted. Nothing changed."; exit 0; }
    echo ""

    # Scratch space for the rewritten task definition. It carries the admin
    # password, so it lives in a private directory, is written 0600, and is
    # removed on exit even if we bail out partway through.
    SEED_TMPDIR=$(mktemp -d) || error "Could not create a temporary directory."
    trap 'rm -rf "$SEED_TMPDIR"' EXIT INT TERM

    # Register a new task-definition revision with TASKAPP_SEED_SAMPLE set to $1.
    # Reuses the current revision verbatim apart from that one variable, so the
    # image, admin password, and volumes all carry over untouched.
    #
    # Note the temp file: AWS CLI v2 cannot read --cli-input-json from
    # file:///dev/stdin, and reports it as "Invalid JSON received" rather than
    # as a read failure — so piping into it silently looks like malformed input.
    register_with_seed_flag() {
      local want="$1" td_json new_arn tf
      tf="${SEED_TMPDIR}/td-${want}.json"

      td_json=$(aws ecs describe-task-definition \
        --task-definition "${APP_NAME}-webapp" \
        --region "$REGION" \
        --query 'taskDefinition' --output json) \
        || error "Could not read the current task definition."

      (umask 077; printf '%s' "$td_json" | python3 -c '
import json, sys
td = json.load(sys.stdin)
# Drop the server-populated fields that register-task-definition rejects
for k in ("taskDefinitionArn", "revision", "status", "requiresAttributes",
          "compatibilities", "registeredAt", "registeredBy", "deregisteredAt"):
    td.pop(k, None)
want = sys.argv[1]
for c in td.get("containerDefinitions", []):
    env = [e for e in c.get("environment", []) if e.get("name") != "TASKAPP_SEED_SAMPLE"]
    if want == "true":
        env.append({"name": "TASKAPP_SEED_SAMPLE", "value": "true"})
    c["environment"] = env
print(json.dumps(td))
' "$want" > "$tf") || error "Could not rewrite the task definition JSON."

      [ -s "$tf" ] || error "The rewritten task definition came out empty."

      new_arn=$(aws ecs register-task-definition \
        --cli-input-json "file://$tf" \
        --region "$REGION" \
        --query 'taskDefinition.taskDefinitionArn' --output text) \
        || error "Could not register the updated task definition."

      rm -f "$tf"
      printf '%s' "$new_arn"
    }

    wait_healthy() {
      local attempt=0 running health
      while [ $attempt -lt 40 ]; do
        running=$(aws ecs describe-services \
          --cluster "$APP_NAME" --services "${APP_NAME}-webapp" \
          --query 'services[0].runningCount' \
          --output text --region "$REGION" 2>/dev/null || echo "0")
        health=$(aws elbv2 describe-target-health \
          --target-group-arn "$TG_ARN" \
          --query 'TargetHealthDescriptions[0].TargetHealth.State' \
          --output text --region "$REGION" 2>/dev/null || echo "unknown")
        echo -ne "  Running tasks: ${running} | ALB health: ${health}\r"
        if [ "$running" = "1" ] && [ "$health" = "healthy" ]; then echo ""; return 0; fi
        sleep 10
        attempt=$((attempt + 1))
      done
      echo ""
      return 1
    }

    log "Registering a task definition with sample seeding enabled..."
    SEED_ON_ARN=$(register_with_seed_flag "true")
    success "Registered: $SEED_ON_ARN"

    log "Restarting the app so it seeds (this is the slow part)..."
    aws ecs update-service \
      --cluster "$APP_NAME" --service "${APP_NAME}-webapp" \
      --task-definition "$SEED_ON_ARN" \
      --force-new-deployment \
      --region "$REGION" >/dev/null
    echo ""
    wait_healthy || warn "Timed out waiting for healthy — check ./manage.sh logs before continuing."
    success "App restarted with seeding enabled"

    # Confirm from the logs that seed() actually ran, rather than assuming
    if aws logs tail "$LOG_GROUP" --since 10m --region "$REGION" 2>/dev/null \
         | grep -q "\[seed\] Created sample users and tasks"; then
      success "Sample users and tasks created"
    else
      warn "Didn't see the '[seed] Created sample users and tasks' line in the logs."
      warn "That's expected if the sample users already existed. Check ./manage.sh logs"
      warn "or the Users page to confirm before assuming it failed."
    fi

    log "Turning sample seeding back off..."
    SEED_OFF_ARN=$(register_with_seed_flag "false")
    aws ecs update-service \
      --cluster "$APP_NAME" --service "${APP_NAME}-webapp" \
      --task-definition "$SEED_OFF_ARN" \
      --force-new-deployment \
      --region "$REGION" >/dev/null
    echo ""
    wait_healthy || warn "Timed out waiting for healthy — check ./manage.sh status."
    success "Seeding disabled again (task definition: $SEED_OFF_ARN)"

    echo ""
    success "Done. Sample data loaded and the flag is back off."
    echo ""
    echo -e "  ${BOLD}URL:${NC}  ${APP_BASE}/users"
    echo ""
    echo -e "  ${YELLOW}Sample users get random passwords and aren't meant to log in —${NC}"
    echo -e "  ${YELLOW}sign in as your admin to see and manage them.${NC}"
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
    echo -e "  ${BOLD}App URL:${NC}   ${APP_BASE}/"
    echo -e "  ${BOLD}API Docs:${NC}  ${APP_BASE}/docs"
    echo -e "  ${BOLD}Health:${NC}    ${APP_BASE}/health"
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
    echo -e "  ${BOLD}./manage.sh seed${NC}     Load sample users and tasks (safe to re-run)"
    echo -e "  ${BOLD}./manage.sh logs${NC}     Stream live logs (Ctrl+C to stop)"
    echo -e "  ${BOLD}./manage.sh url${NC}      Print the app URL"
    echo ""
    echo -e "  ${BOLD}./deploy.sh${NC}          Deploy everything from scratch"
    echo -e "  ${BOLD}./update.sh${NC}          Rebuild and redeploy from latest GitHub source"
    echo -e "  ${BOLD}./teardown.sh${NC}        Delete all AWS resources permanently"
    echo ""
    ;;
esac
