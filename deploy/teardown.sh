#!/bin/bash
# =============================================================================
# teardown.sh — TaskFlow (taskDemoWebApp) Complete AWS Resource Cleanup
# =============================================================================
# Usage:  ./teardown.sh
# Reads resource IDs from .task-demo-state (created by deploy.sh)
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

# ── LOAD STATE ────────────────────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
else
  warn "No state file found — looking up resources from AWS directly..."
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  APP_NAME="task-demo"
  LOG_GROUP="/ecs/task-demo-webapp"

  VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true     --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "")

  ALB_ARN=$(aws elbv2 describe-load-balancers --names "${APP_NAME}-alb"     --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION" 2>/dev/null || echo "")

  TG_ARN=$(aws elbv2 describe-target-groups --names "${APP_NAME}-tg"     --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION" 2>/dev/null || echo "")

  EFS_ID=$(aws efs describe-file-systems     --query "FileSystems[?Tags[?Key=='Name'&&Value=='${APP_NAME}-data']].FileSystemId"     --output text --region "$REGION" 2>/dev/null || echo "")

  ACCESS_POINT_ID=$(aws efs describe-access-points     --file-system-id "$EFS_ID"     --query 'AccessPoints[0].AccessPointId'     --output text --region "$REGION" 2>/dev/null || echo "")

  ALB_SG_ID=$(aws ec2 describe-security-groups     --filters Name=group-name,Values="${APP_NAME}-alb-sg" Name=vpc-id,Values="$VPC_ID"     --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")

  ECS_SG_ID=$(aws ec2 describe-security-groups     --filters Name=group-name,Values="${APP_NAME}-ecs-sg" Name=vpc-id,Values="$VPC_ID"     --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")

  success "Resources discovered from AWS"
fi

echo ""
echo -e "${BOLD}${RED}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${RED}  TaskFlow (taskDemoWebApp) — Complete Teardown${NC}"
echo -e "${BOLD}${RED}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  This will ${BOLD}permanently delete${NC} all AWS resources for ${BOLD}$APP_NAME${NC}:"
echo ""
echo -e "    • ECS service and cluster"
echo -e "    • Application Load Balancer"
echo -e "    • EFS filesystem and all stored data"
echo -e "    • Security groups"
echo -e "    • CloudWatch log group"
echo -e "    • ECR repository and all container images"
echo ""
echo -e "  ${RED}${BOLD}Your SQLite data (all users and tasks) will be gone. This cannot be undone.${NC}"
echo ""
read -rp "  Type 'delete' to confirm: " confirm
[ "$confirm" = "delete" ] || { echo "Aborted. Nothing was deleted."; exit 0; }
echo ""

# ── ECS SERVICE ───────────────────────────────────────────────────────────────
header "Stopping ECS service"

log "Scaling service to 0..."
aws ecs update-service \
  --cluster "$APP_NAME" \
  --service "${APP_NAME}-webapp" \
  --desired-count 0 \
  --region "$REGION" >/dev/null 2>/dev/null || warn "Service not found — may already be deleted"

log "Deleting ECS service..."
aws ecs delete-service \
  --cluster "$APP_NAME" \
  --service "${APP_NAME}-webapp" \
  --force \
  --region "$REGION" >/dev/null 2>/dev/null || warn "Service not found — skipping"

log "Waiting for ECS service to fully drain..."
attempt=0
while [ $attempt -lt 24 ]; do
  RUNNING=$(aws ecs describe-services \
    --cluster "$APP_NAME" \
    --services "${APP_NAME}-webapp" \
    --query 'services[?status!=`INACTIVE`] | length(@)' \
    --output text --region "$REGION" 2>/dev/null || echo "0")
  echo -ne "  Active services remaining: ${RUNNING}\r"
  if [ "$RUNNING" = "0" ] || [ "$RUNNING" = "None" ] || [ -z "$RUNNING" ]; then
    echo ""
    break
  fi
  sleep 5
  attempt=$((attempt + 1))
done
echo ""
success "ECS service deleted"

# ── ECS CLUSTER ───────────────────────────────────────────────────────────────
header "ECS cluster"

log "Deleting ECS cluster..."
aws ecs delete-cluster \
  --cluster "$APP_NAME" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "Cluster not found — skipping"

attempt=0
while [ $attempt -lt 12 ]; do
  CLUSTER_STATUS=$(aws ecs describe-clusters \
    --clusters "$APP_NAME" \
    --query 'clusters[0].status' \
    --output text --region "$REGION" 2>/dev/null || echo "INACTIVE")
  [ "$CLUSTER_STATUS" = "INACTIVE" ] || [ "$CLUSTER_STATUS" = "None" ] || [ -z "$CLUSTER_STATUS" ] && break
  echo -ne "  Cluster status: ${CLUSTER_STATUS}\r"
  sleep 5
  attempt=$((attempt + 1))
done
echo ""
success "ECS cluster deleted"


# ── TASK DEFINITIONS ──────────────────────────────────────────────────────────
header "Task definitions"

log "Deregistering task definitions..."
TASK_DEF_ARNS=$(aws ecs list-task-definitions \
  --family-prefix "${APP_NAME}-webapp" \
  --query 'taskDefinitionArns[*]' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [ -n "$TASK_DEF_ARNS" ]; then
  for arn in $TASK_DEF_ARNS; do
    aws ecs deregister-task-definition --task-definition "$arn" --region "$REGION" >/dev/null 2>/dev/null || true
  done
  success "Task definitions deregistered"
else
  skip "No task definitions found"
fi

# ── ECR REPOSITORY ────────────────────────────────────────────────────────────
header "ECR repository"

ECR_REPO="${APP_NAME}-webapp"
log "Deleting all images from ECR repository..."

IMAGE_IDS=$(aws ecr list-images \
  --repository-name "$ECR_REPO" \
  --query 'imageIds[*]' \
  --output json \
  --region "$REGION" 2>/dev/null || echo "[]")

if [ "$IMAGE_IDS" != "[]" ] && [ -n "$IMAGE_IDS" ]; then
  aws ecr batch-delete-image \
    --repository-name "$ECR_REPO" \
    --image-ids "$IMAGE_IDS" \
    --region "$REGION" >/dev/null 2>/dev/null || warn "Could not delete some images — skipping"
fi

log "Deleting ECR repository..."
aws ecr delete-repository \
  --repository-name "$ECR_REPO" \
  --force \
  --region "$REGION" >/dev/null 2>/dev/null || warn "ECR repository not found — skipping"
success "ECR repository deleted"

# ── ALB ───────────────────────────────────────────────────────────────────────
header "Application Load Balancer"

log "Deleting ALB listeners..."
LISTENER_ARNS=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[*].ListenerArn' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [ -n "$LISTENER_ARNS" ]; then
  for arn in $LISTENER_ARNS; do
    aws elbv2 delete-listener --listener-arn "$arn" --region "$REGION" >/dev/null 2>/dev/null || true
  done
fi

log "Deleting ALB..."
aws elbv2 delete-load-balancer \
  --load-balancer-arn "$ALB_ARN" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "ALB not found — skipping"
success "ALB deleted"

# Wait for ALB to finish deleting before removing the target group
log "Waiting for ALB to finish deleting..."
attempt=0
while [ $attempt -lt 20 ]; do
  STATE=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].State.Code' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "deleted")
  [ "$STATE" = "deleted" ] || [ "$STATE" = "None" ] || [ -z "$STATE" ] && break
  echo -n "."
  sleep 5
  attempt=$((attempt + 1))
done
echo ""

log "Deleting target group..."
aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "Target group not found — skipping"
success "Target group deleted"

# ── EFS ───────────────────────────────────────────────────────────────────────
header "EFS filesystem (persistent storage)"

log "Deleting EFS access point..."
aws efs delete-access-point \
  --access-point-id "$ACCESS_POINT_ID" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "Access point not found — skipping"
success "EFS access point deleted"

log "Deleting EFS mount targets..."
MT_IDS=$(aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --query 'MountTargets[*].MountTargetId' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [ -n "$MT_IDS" ]; then
  for mt in $MT_IDS; do
    aws efs delete-mount-target --mount-target-id "$mt" --region "$REGION" >/dev/null 2>/dev/null || true
  done
  # Wait for mount targets to finish deleting
  log "Waiting for mount targets to delete (up to 2 minutes)..."
  attempt=0
  while [ $attempt -lt 24 ]; do
    REMAINING=$(aws efs describe-mount-targets \
      --file-system-id "$EFS_ID" \
      --query 'MountTargets | length(@)' \
      --output text \
      --region "$REGION" 2>/dev/null || echo "0")
    [ "$REMAINING" = "0" ] && break
    echo -n "."
    sleep 5
    attempt=$((attempt + 1))
  done
  echo ""
fi
success "EFS mount targets deleted"

log "Deleting EFS filesystem..."
aws efs delete-file-system \
  --file-system-id "$EFS_ID" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "EFS filesystem not found — skipping"
success "EFS filesystem deleted"

# ── SECURITY GROUPS ───────────────────────────────────────────────────────────
header "Security groups"

# Brief pause — AWS needs a moment after ALB deletion before SGs can be removed
sleep 10

log "Deleting ECS security group..."
aws ec2 delete-security-group \
  --group-id "$ECS_SG_ID" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "ECS SG not found — skipping"
success "ECS security group deleted"

log "Deleting ALB security group..."
aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "ALB SG not found — skipping"
success "ALB security group deleted"

# ── CLOUDWATCH LOGS ───────────────────────────────────────────────────────────
header "CloudWatch log group"

log "Deleting log group..."
aws logs delete-log-group \
  --log-group-name "$LOG_GROUP" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "Log group not found — skipping"
success "Log group deleted"

# ── CLEAN UP STATE FILE ───────────────────────────────────────────────────────
rm -f "$STATE_FILE"
success "State file removed"

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Teardown complete. All resources deleted.${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  AWS is no longer billing you for this deployment."
echo -e "  Run ${BOLD}./deploy.sh${NC} any time to redeploy."
echo ""
