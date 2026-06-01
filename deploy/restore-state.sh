#!/bin/bash
# =============================================================================
# restore-state.sh — Rebuild .task-demo-state from live AWS resources
# =============================================================================
# Use this on a second machine (or after losing the file) so manage.sh,
# update.sh, and teardown.sh can find your existing deployment.
#
# It looks every resource up by the same naming convention deploy.sh uses,
# then writes a .task-demo-state file identical to the one deploy.sh produces.
# It creates nothing in AWS — read-only discovery.
#
# Usage:
#   ./restore-state.sh            # uses your default AWS region
#   ./restore-state.sh us-west-2  # or pass the region you deployed to
# =============================================================================

set -euo pipefail

APP_NAME="task-demo"

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
skip()    { echo -e "  ${YELLOW}↷  $1${NC}"; }

# ── AWS SESSION VALIDATION ────────────────────────────────────────────────────
header "Validating AWS session"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session and try again."

ACCOUNT_ID=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $ACCOUNT_ID)"

# ── REGION ────────────────────────────────────────────────────────────────────
header "Region"

REGION="${1:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "$REGION" ] || REGION=$(aws configure get region 2>/dev/null || echo "")
[ -n "$REGION" ] || error "No region given and none configured. Pass one: ./restore-state.sh us-east-1"

aws ec2 describe-regions --region-names "$REGION" --query 'Regions[0].RegionName' \
  --output text >/dev/null 2>&1 \
  || error "Invalid or inaccessible region: '$REGION'."
success "Region: $REGION"

if [ -f "$STATE_FILE" ]; then
  warn "A state file already exists here ($STATE_FILE)."
  read -rp "  Overwrite it with freshly discovered values? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted. Nothing changed."; exit 0; }
fi

# ── DISCOVERY ─────────────────────────────────────────────────────────────────
header "Discovering resources for '${APP_NAME}' in ${REGION}"

# Networking (default VPC + first two subnets — same selection deploy.sh makes)
VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$VPC_ID" = "None" ] && VPC_ID=""

SUBNET_1=""; SUBNET_2=""
if [ -n "$VPC_ID" ]; then
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'Subnets[*].SubnetId' \
    --output text --region "$REGION" 2>/dev/null | tr '\t' '\n' | head -2 | tr '\n' ' ' | xargs || echo "")
  SUBNET_1=$(echo "$SUBNET_IDS" | awk '{print $1}')
  SUBNET_2=$(echo "$SUBNET_IDS" | awk '{print $2}')
fi
[ -n "$VPC_ID" ] && success "VPC: $VPC_ID  (subnets: ${SUBNET_1:-?}, ${SUBNET_2:-?})" \
                 || warn "Default VPC not found"

# Security groups
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-alb-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ALB_SG_ID" = "None" ] && ALB_SG_ID=""
[ -n "$ALB_SG_ID" ] && success "ALB security group: $ALB_SG_ID" || warn "ALB security group not found"

ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-ecs-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ECS_SG_ID" = "None" ] && ECS_SG_ID=""
[ -n "$ECS_SG_ID" ] && success "ECS security group: $ECS_SG_ID" || warn "ECS security group not found"

# EFS filesystem (by Name tag) + access point
EFS_ID=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='${APP_NAME}-data']].FileSystemId" \
  --output text --region "$REGION" 2>/dev/null || echo "")
[ "$EFS_ID" = "None" ] && EFS_ID=""

ACCESS_POINT_ID=""
if [ -n "$EFS_ID" ]; then
  ACCESS_POINT_ID=$(aws efs describe-access-points \
    --file-system-id "$EFS_ID" \
    --query 'AccessPoints[0].AccessPointId' \
    --output text --region "$REGION" 2>/dev/null || echo "")
  [ "$ACCESS_POINT_ID" = "None" ] && ACCESS_POINT_ID=""
fi
[ -n "$EFS_ID" ] && success "EFS: $EFS_ID  (access point: ${ACCESS_POINT_ID:-?})" \
                 || warn "EFS filesystem not found"

# Load balancer + DNS
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${APP_NAME}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ALB_ARN" = "None" ] && ALB_ARN=""

ALB_DNS=""
if [ -n "$ALB_ARN" ]; then
  ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' --output text --region "$REGION" 2>/dev/null || echo "")
  [ "$ALB_DNS" = "None" ] && ALB_DNS=""
fi
[ -n "$ALB_ARN" ] && success "ALB: ${ALB_DNS:-$ALB_ARN}" || warn "ALB not found"

# Target group
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${APP_NAME}-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$TG_ARN" = "None" ] && TG_ARN=""
[ -n "$TG_ARN" ] && success "Target group: $TG_ARN" || warn "Target group not found"

# Latest active task definition for the family
TASK_DEF_ARN=$(aws ecs list-task-definitions \
  --family-prefix "${APP_NAME}-webapp" \
  --status ACTIVE --sort DESC \
  --query 'taskDefinitionArns[0]' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$TASK_DEF_ARN" = "None" ] && TASK_DEF_ARN=""
[ -n "$TASK_DEF_ARN" ] && success "Task definition: $TASK_DEF_ARN" || warn "No active task definition found"

# Constants / derived
LOG_GROUP="/ecs/${APP_NAME}-webapp"

# CONTAINER_IMAGE — only meaningful once the image lives in ECR (set by deploy/fix-image)
CONTAINER_IMAGE=""
if aws ecr describe-repositories --repository-names "${APP_NAME}-webapp" \
     --region "$REGION" >/dev/null 2>&1; then
  CONTAINER_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}-webapp:latest"
fi

# ── SANITY CHECK ──────────────────────────────────────────────────────────────
# manage.sh / update.sh need the ALB DNS and target group above all else.
if [ -z "$ALB_ARN" ] || [ -z "$TG_ARN" ]; then
  echo ""
  error "Couldn't find the core load balancer / target group in '$REGION'.
  This usually means either the app isn't deployed yet, or it's in a different
  region. Re-run with the region you deployed to, e.g. ./restore-state.sh us-west-2"
fi

# ── WRITE STATE FILE ──────────────────────────────────────────────────────────
header "Writing $STATE_FILE"

cat > "$STATE_FILE" <<EOF
# taskDemoWebApp deployment state — regenerated by restore-state.sh
# Rediscovered from live AWS resources; not the original deploy.sh file.
# Used by manage.sh, update.sh, and teardown.sh — do not delete.
APP_NAME=$APP_NAME
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
VPC_ID=$VPC_ID
SUBNET_1=$SUBNET_1
SUBNET_2=$SUBNET_2
ALB_SG_ID=$ALB_SG_ID
ECS_SG_ID=$ECS_SG_ID
EFS_ID=$EFS_ID
ACCESS_POINT_ID=$ACCESS_POINT_ID
ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
TG_ARN=$TG_ARN
LOG_GROUP=$LOG_GROUP
TASK_DEF_ARN=$TASK_DEF_ARN
EOF

# Only record CONTAINER_IMAGE if the ECR repo exists (matches deploy.sh behaviour)
[ -n "$CONTAINER_IMAGE" ] && echo "CONTAINER_IMAGE=$CONTAINER_IMAGE" >> "$STATE_FILE"

success "State file written"

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  State restored.${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}App URL:${NC}  http://${ALB_DNS}/"
echo ""
echo -e "  You can now run ${BOLD}./manage.sh status${NC} from this machine."
echo ""
