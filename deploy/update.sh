#!/bin/bash
# =============================================================================
# update.sh — Rebuild and redeploy TaskFlow from latest GitHub source
# =============================================================================
# Run this any time you have merged final changes to the main branch on GitHub.
# It will:
#   1. Pull the latest code from GitHub
#   2. Build a fresh Docker image (linux/amd64 for Fargate compatibility)
#   3. Push it to your ECR repository
#   4. Force ECS to redeploy using the new image
#   5. Wait and confirm the app is healthy
#
# Usage: ./update.sh
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

# ── AWS SESSION VALIDATION ────────────────────────────────────────────────────
header "Validating AWS session"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session and try again."

SESSION_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $SESSION_ACCOUNT)"

# ── LOAD STATE ────────────────────────────────────────────────────────────────
[ -f "$STATE_FILE" ] || error "No state file found ($STATE_FILE). Deploy the app first with ./deploy.sh"
# shellcheck source=/dev/null
source "$STATE_FILE"

# ── PRE-FLIGHT ────────────────────────────────────────────────────────────────
header "Pre-flight checks"

command -v docker >/dev/null 2>&1 || error "Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
docker info >/dev/null 2>&1      || error "Docker is not running. Start Docker Desktop and try again."
success "Docker is running"

command -v git >/dev/null 2>&1 || error "Git not found. Install from https://git-scm.com/"
success "Git is available"

# Confirm ECS service is actually running before we bother rebuilding
SVC_STATUS=$(aws ecs describe-services \
  --cluster "$APP_NAME" \
  --services "${APP_NAME}-webapp" \
  --query 'services[0].status' \
  --output text --region "$REGION" 2>/dev/null || echo "")
[ "$SVC_STATUS" = "ACTIVE" ] || error "ECS service is not running. Deploy the app first with ./deploy.sh"
success "ECS service is active"

ECR_IMAGE="${SESSION_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}-webapp:latest"

# ── PULL LATEST CODE ──────────────────────────────────────────────────────────
header "Pulling latest code from GitHub"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT   # always clean up temp dir on exit

log "Cloning main branch of tmanmidwest/taskDemoWebApp..."
git clone $GITHUB_REPO "$BUILD_DIR" \
  --branch main \
  --depth 1 \
  --quiet

# Show the latest commit so you know exactly what you're deploying
COMMIT_SHA=$(git -C "$BUILD_DIR" rev-parse --short HEAD)
COMMIT_MSG=$(git -C "$BUILD_DIR" log -1 --pretty=format:"%s")
COMMIT_DATE=$(git -C "$BUILD_DIR" log -1 --pretty=format:"%cd" --date=format:"%Y-%m-%d %H:%M")
success "Latest commit: ${COMMIT_SHA} — ${COMMIT_MSG} (${COMMIT_DATE})"

echo ""
echo -e "  ${BOLD}Deploying this commit to AWS. Continue?${NC}"
read -rp "  [Y/n] " confirm
confirm="${confirm:-Y}"
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted. Nothing was changed."; exit 0; }

# ── BUILD IMAGE ───────────────────────────────────────────────────────────────
header "Building Docker image"

log "Logging Docker into ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin \
  "${SESSION_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
success "Docker logged into ECR"

log "Building image for linux/amd64 (Fargate compatible)..."
log "This takes 3-5 minutes on first build, faster on subsequent runs..."
docker buildx build \
  --platform linux/amd64 \
  --push \
  -t "$ECR_IMAGE" \
  "$BUILD_DIR"
success "Image built and pushed: $ECR_IMAGE"

# Tag image with commit SHA as well so you have a history of builds
ECR_IMAGE_SHA="${SESSION_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}-webapp:${COMMIT_SHA}"
docker buildx build \
  --platform linux/amd64 \
  --push \
  -t "$ECR_IMAGE_SHA" \
  "$BUILD_DIR" --quiet
success "Also tagged as: ${APP_NAME}-webapp:${COMMIT_SHA}"

# ── REDEPLOY ECS ──────────────────────────────────────────────────────────────
header "Redeploying to ECS"

log "Forcing new ECS deployment with updated image..."
aws ecs update-service \
  --cluster "$APP_NAME" \
  --service "${APP_NAME}-webapp" \
  --force-new-deployment \
  --region "$REGION" >/dev/null
success "ECS deployment triggered"

# ── WAIT FOR HEALTHY ──────────────────────────────────────────────────────────
header "Waiting for new version to become healthy"
log "ECS will start the new container and drain the old one (takes 2-4 minutes)..."
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
  echo -ne "  Running tasks: ${RUNNING} | ALB health: ${HEALTH}\r"
  if [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ]; then
    echo ""
    break
  fi
  sleep 10
  attempt=$((attempt + 1))
done
echo ""

if [ $attempt -eq 40 ]; then
  warn "Timed out waiting for healthy status."
  warn "Check ./manage.sh status and ./manage.sh logs for details."
  exit 1
fi

echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Update complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Deployed commit:${NC}  ${COMMIT_SHA} — ${COMMIT_MSG}"
echo -e "  ${BOLD}App URL:${NC}          http://${ALB_DNS}/"
echo -e "  ${BOLD}API Docs:${NC}         http://${ALB_DNS}/docs"
echo ""
echo -e "  Run ${BOLD}./manage.sh logs${NC} to see the new container's output."
echo ""
