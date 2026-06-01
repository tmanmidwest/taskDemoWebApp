#!/bin/bash
# =============================================================================
# fix-image.sh — Rebuild the container image from source and repair the service
# =============================================================================
# Use this if the ECS task can't pull its image, the task definition got into a
# bad state, or a deploy was interrupted. It rebuilds the image straight from
# the GitHub source into your own ECR, re-registers a clean task definition
# pinned to that image, and forces a fresh deployment.
#
# Unlike the hrDemoWebApp version, TaskFlow never uses GHCR — the image always
# lives in your own ECR — so this is a "rebuild and recover" tool, not a
# registry migration.
#
# Usage:  ./fix-image.sh
# =============================================================================

set -euo pipefail

# GitHub repo to build from — change this if you fork the repo
GITHUB_REPO="https://github.com/tmanmidwest/taskDemoWebApp.git"

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

# Admin seed values — used only if a brand-new EFS volume initialises an empty DB.
# Kept in sync with deploy.sh. Override by exporting before running if needed.
ADMIN_USERNAME="${ADMIN_USERNAME:-robbytheadmin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-N0nPr0dF0r\$@viynt8}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@taskflow.demo}"

# ── AWS SESSION VALIDATION ────────────────────────────────────────────────────
header "Validating AWS session"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session and try again."

SESSION_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $SESSION_ACCOUNT)"

[ -f "$STATE_FILE" ] || error "No state file found ($STATE_FILE). Run deploy.sh first."
# shellcheck source=/dev/null
source "$STATE_FILE"

ECR_REPO="${APP_NAME}-webapp"
ECR_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"

# ── PRE-FLIGHT ────────────────────────────────────────────────────────────────
header "Pre-flight checks"

command -v docker >/dev/null 2>&1 || error "Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
docker info >/dev/null 2>&1 || error "Docker is not running. Start Docker Desktop and try again."
success "Docker is running"

command -v git >/dev/null 2>&1 || error "Git not found. Install from https://git-scm.com/"
success "Git is available"

# ── ECR REPOSITORY ────────────────────────────────────────────────────────────
header "Amazon ECR repository"

log "Creating ECR repository (or reusing if it exists)..."
EXISTING=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$REGION" \
  --query 'repositories[0].repositoryUri' \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
  aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$REGION" >/dev/null
fi
success "ECR repository: $ECR_IMAGE"

# ── REBUILD IMAGE FROM SOURCE ─────────────────────────────────────────────────
header "Rebuilding image from GitHub source"

log "Logging Docker into ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
success "Docker logged into ECR"

log "Cloning repo and building image (linux/amd64 for Fargate)..."
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
git clone "$GITHUB_REPO" "$BUILD_DIR" --branch main --depth 1 --quiet
docker buildx build --platform linux/amd64 --push -t "$ECR_IMAGE" "$BUILD_DIR"
success "Image built and pushed: $ECR_IMAGE"

# ── UPDATE TASK DEFINITION ────────────────────────────────────────────────────
header "Re-registering ECS task definition"

log "Registering a clean task definition pinned to the rebuilt ECR image..."
aws ecs register-task-definition \
  --family "${APP_NAME}-webapp" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 \
  --memory 512 \
  --execution-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole" \
  --container-definitions "[
    {
      \"name\": \"${APP_NAME}-webapp\",
      \"image\": \"${ECR_IMAGE}\",
      \"essential\": true,
      \"portMappings\": [{ \"containerPort\": 8000, \"protocol\": \"tcp\" }],
      \"environment\": [
        { \"name\": \"TASKAPP_LOG_LEVEL\",      \"value\": \"INFO\" },
        { \"name\": \"TASKAPP_BIND_HOST\",      \"value\": \"0.0.0.0\" },
        { \"name\": \"TASKAPP_BIND_PORT\",      \"value\": \"8000\" },
        { \"name\": \"TASKAPP_DB_PATH\",        \"value\": \"/data/taskflow.db\" },
        { \"name\": \"TASKAPP_ADMIN_USERNAME\", \"value\": \"${ADMIN_USERNAME}\" },
        { \"name\": \"TASKAPP_ADMIN_PASSWORD\", \"value\": \"${ADMIN_PASSWORD}\" },
        { \"name\": \"TASKAPP_ADMIN_EMAIL\",    \"value\": \"${ADMIN_EMAIL}\" }
      ],
      \"mountPoints\": [{
        \"sourceVolume\": \"${APP_NAME}-data\",
        \"containerPath\": \"/data\",
        \"readOnly\": false
      }],
      \"healthCheck\": {
        \"command\": [\"CMD-SHELL\", \"curl -f http://localhost:8000/health || exit 1\"],
        \"interval\": 30,
        \"timeout\": 5,
        \"retries\": 3,
        \"startPeriod\": 10
      },
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"${LOG_GROUP}\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      }
    }
  ]" \
  --volumes "[
    {
      \"name\": \"${APP_NAME}-data\",
      \"efsVolumeConfiguration\": {
        \"fileSystemId\": \"${EFS_ID}\",
        \"transitEncryption\": \"ENABLED\",
        \"authorizationConfig\": {
          \"accessPointId\": \"${ACCESS_POINT_ID}\",
          \"iam\": \"DISABLED\"
        }
      }
    }
  ]" >/dev/null
success "Task definition re-registered"

# ── UPDATE SERVICE ────────────────────────────────────────────────────────────
header "Restarting ECS service"

log "Forcing new deployment with the rebuilt image..."
aws ecs update-service \
  --cluster "$APP_NAME" \
  --service "${APP_NAME}-webapp" \
  --task-definition "${APP_NAME}-webapp" \
  --force-new-deployment \
  --region "$REGION" >/dev/null
success "Service update triggered"

# ── UPDATE STATE FILE ─────────────────────────────────────────────────────────
grep -v "^CONTAINER_IMAGE=" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
echo "CONTAINER_IMAGE=${ECR_IMAGE}" >> "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"
success "State file updated to use the rebuilt ECR image"

# ── WAIT FOR HEALTHY ──────────────────────────────────────────────────────────
header "Waiting for app to become healthy"
log "This takes 3-5 minutes..."
echo ""

attempt=0
while [ $attempt -lt 40 ]; do
  RUNNING=$(aws ecs describe-services \
    --cluster "$APP_NAME" \
    --services "${APP_NAME}-webapp" \
    --query 'services[0].runningCount' \
    --output text --region "$REGION" 2>/dev/null || echo "0")
  HEALTH=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text --region "$REGION" 2>/dev/null || echo "unknown")
  echo -ne "  Running tasks: ${RUNNING} | ALB target health: ${HEALTH}\r"
  if [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ]; then
    echo ""
    break
  fi
  sleep 10
  attempt=$((attempt + 1))
done

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Image rebuild complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}App URL:${NC}   http://${ALB_DNS}/"
echo -e "  ${BOLD}API Docs:${NC}  http://${ALB_DNS}/docs"
echo ""
echo -e "  The image is stored in your own AWS account (ECR) — no external registry."
echo ""
