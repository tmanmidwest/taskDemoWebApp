#!/bin/bash
# =============================================================================
# deploy.sh — taskDemoWebApp ECS Fargate Deployment
# =============================================================================
# Usage:  ./deploy.sh
# Requires: AWS CLI v2 configured with appropriate permissions
# =============================================================================

set -euo pipefail

# ── CONFIGURATION (edit these if needed) ─────────────────────────────────────
APP_NAME="task-demo"
GITHUB_REPO="https://github.com/tmanmidwest/taskDemoWebApp.git"  # <-- change if you fork
CONTAINER_IMAGE=""  # Set automatically — built from source and pushed to ECR
CONTAINER_PORT=8000
CPU=256        # 0.25 vCPU
MEMORY=512     # 0.5 GB
LOG_LEVEL="INFO"

# Default administrator seeded on first boot (change before a real demo if you like)
ADMIN_USERNAME="robbytheadmin"
ADMIN_PASSWORD="N0nPr0dF0r\$@viynt8"
ADMIN_EMAIL="admin@taskflow.demo"
# ─────────────────────────────────────────────────────────────────────────────

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

CHECKMARK="${GREEN}✔${NC}"
ARROW="${BLUE}▶${NC}"
WARNING="${YELLOW}⚠${NC}"

# State file — saves all resource IDs so teardown.sh can find them later
STATE_FILE=".task-demo-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }

wait_for() {
  local description="$1"
  local check_cmd="$2"
  local expected="$3"
  local max_attempts="${4:-30}"
  local attempt=0
  log "Waiting for $description..."
  while [ $attempt -lt $max_attempts ]; do
    result=$(eval "$check_cmd" 2>/dev/null || echo "")
    if echo "$result" | grep -q "$expected"; then
      success "$description is ready"
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
    echo -n "."
  done
  echo ""
  error "Timed out waiting for $description"
}

# ── PRE-FLIGHT CHECKS ─────────────────────────────────────────────────────────
header "Pre-flight checks"

command -v aws >/dev/null 2>&1 || error "AWS CLI not found. Install from https://aws.amazon.com/cli/"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session and try again."

ACCOUNT_ID=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $ACCOUNT_ID)"

# ── ECR IMAGE BUILD ──────────────────────────────────────────────────────────
header "Container image"

command -v docker >/dev/null 2>&1 || error "Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
docker info >/dev/null 2>&1 || error "Docker is not running. Please start Docker Desktop and try again."
success "Docker is running"

# ── REGION SELECTION ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Select an AWS region to deploy to:${NC}"
echo ""
echo -e "  ${BOLD} 1)${NC} us-east-1       US East (N. Virginia)      ${YELLOW}— most services, lowest cost${NC}"
echo -e "  ${BOLD} 2)${NC} us-east-2       US East (Ohio)"
echo -e "  ${BOLD} 3)${NC} us-west-1       US West (N. California)"
echo -e "  ${BOLD} 4)${NC} us-west-2       US West (Oregon)"
echo -e "  ${BOLD} 5)${NC} eu-west-1       Europe (Ireland)"
echo -e "  ${BOLD} 6)${NC} eu-west-2       Europe (London)"
echo -e "  ${BOLD} 7)${NC} eu-west-3       Europe (Paris)"
echo -e "  ${BOLD} 8)${NC} eu-central-1    Europe (Frankfurt)"
echo -e "  ${BOLD} 9)${NC} eu-north-1      Europe (Stockholm)"
echo -e "  ${BOLD}10)${NC} ap-southeast-1  Asia Pacific (Singapore)"
echo -e "  ${BOLD}11)${NC} ap-southeast-2  Asia Pacific (Sydney)"
echo -e "  ${BOLD}12)${NC} ap-northeast-1  Asia Pacific (Tokyo)"
echo -e "  ${BOLD}13)${NC} ap-northeast-2  Asia Pacific (Seoul)"
echo -e "  ${BOLD}14)${NC} ap-south-1      Asia Pacific (Mumbai)"
echo -e "  ${BOLD}15)${NC} ca-central-1    Canada (Central)"
echo -e "  ${BOLD}16)${NC} sa-east-1       South America (São Paulo)"
echo ""

DEFAULT_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
read -rp "  Enter number or region name [default: $DEFAULT_REGION]: " REGION_INPUT
echo ""

case "$REGION_INPUT" in
  1)  REGION="us-east-1" ;;
  2)  REGION="us-east-2" ;;
  3)  REGION="us-west-1" ;;
  4)  REGION="us-west-2" ;;
  5)  REGION="eu-west-1" ;;
  6)  REGION="eu-west-2" ;;
  7)  REGION="eu-west-3" ;;
  8)  REGION="eu-central-1" ;;
  9)  REGION="eu-north-1" ;;
  10) REGION="ap-southeast-1" ;;
  11) REGION="ap-southeast-2" ;;
  12) REGION="ap-northeast-1" ;;
  13) REGION="ap-northeast-2" ;;
  14) REGION="ap-south-1" ;;
  15) REGION="ca-central-1" ;;
  16) REGION="sa-east-1" ;;
  "") REGION="$DEFAULT_REGION" ;;
  *)  REGION="$REGION_INPUT" ;;
esac

# Validate the region
aws ec2 describe-regions --region-names "$REGION" --query 'Regions[0].RegionName' \
  --output text >/dev/null 2>&1 \
  || error "Invalid or inaccessible region: '$REGION'. Check the name and that your account has access."

success "Region: $REGION"


if [ -f "$STATE_FILE" ]; then
  warn "A previous deployment state file exists ($STATE_FILE)."
  warn "This suggests the app may already be deployed."
  read -rp "  Continue anyway and overwrite? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── NETWORKING ────────────────────────────────────────────────────────────────
header "Networking"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text --region "$REGION")
[ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ] && error "No default VPC found. Please create one in the AWS console."
success "Default VPC: $VPC_ID"

# Grab up to 2 subnets from different AZs
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[*].SubnetId' \
  --output text --region "$REGION" | tr '\t' '\n' | head -2 | tr '\n' ' ' | xargs)
SUBNET_COUNT=$(echo "$SUBNET_IDS" | wc -w | xargs)
[ "$SUBNET_COUNT" -lt 2 ] && error "Need at least 2 subnets in your default VPC. Found: $SUBNET_COUNT"
SUBNET_1=$(echo "$SUBNET_IDS" | awk '{print $1}')
SUBNET_2=$(echo "$SUBNET_IDS" | awk '{print $2}')
success "Subnets: $SUBNET_1, $SUBNET_2"

# ── SECURITY GROUPS ───────────────────────────────────────────────────────────
header "Security groups"

# ALB security group
log "Creating ALB security group (or reusing if it exists)..."
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-alb-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$ALB_SG_ID" ] || [ "$ALB_SG_ID" = "None" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-alb-sg" \
    --description "Task Demo ALB - HTTP from internet" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text --region "$REGION")
  aws ec2 authorize-security-group-ingress \
    --group-id "$ALB_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
fi
success "ALB security group: $ALB_SG_ID"

# ECS task security group
log "Creating ECS task security group (or reusing if it exists)..."
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-ecs-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$ECS_SG_ID" ] || [ "$ECS_SG_ID" = "None" ]; then
  ECS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-ecs-sg" \
    --description "Task Demo ECS task - traffic from ALB only" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text --region "$REGION")
  # Allow container port from ALB SG only
  aws ec2 authorize-security-group-ingress \
    --group-id "$ECS_SG_ID" \
    --protocol tcp --port $CONTAINER_PORT \
    --source-group "$ALB_SG_ID" --region "$REGION" >/dev/null
  # Allow EFS (NFS port 2049) within the ECS SG
  aws ec2 authorize-security-group-ingress \
    --group-id "$ECS_SG_ID" \
    --protocol tcp --port 2049 \
    --source-group "$ECS_SG_ID" --region "$REGION" >/dev/null
fi
success "ECS task security group: $ECS_SG_ID"

# ── EFS (PERSISTENT STORAGE) ──────────────────────────────────────────────────
header "EFS filesystem (persistent storage)"

log "Creating EFS filesystem (or reusing if it exists)..."
EFS_ID=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='${APP_NAME}-data']].FileSystemId" \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$EFS_ID" ] || [ "$EFS_ID" = "None" ]; then
  EFS_ID=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --encrypted \
    --tags Key=Name,Value="${APP_NAME}-data" \
    --query 'FileSystemId' --output text --region "$REGION")
fi
success "EFS filesystem: $EFS_ID"

wait_for "EFS filesystem" \
  "aws efs describe-file-systems --file-system-id $EFS_ID --query 'FileSystems[0].LifeCycleState' --output text --region $REGION" \
  "available"

log "Creating EFS mount targets (or reusing if they exist)..."
MT_COUNT=$(aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --query 'MountTargets | length(@)' \
  --output text --region "$REGION" 2>/dev/null || echo "0")

if [ "$MT_COUNT" = "0" ]; then
  aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$SUBNET_1" \
    --security-groups "$ECS_SG_ID" \
    --region "$REGION" >/dev/null

  aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$SUBNET_2" \
    --security-groups "$ECS_SG_ID" \
    --region "$REGION" >/dev/null
fi

log "Waiting for EFS mount targets to become available..."
attempt=0
while [ $attempt -lt 40 ]; do
  STATES=$(aws efs describe-mount-targets \
    --file-system-id "$EFS_ID" \
    --query 'MountTargets[*].LifeCycleState' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")
  TOTAL=$(echo "$STATES" | wc -w | xargs)
  READY=$(echo "$STATES" | tr '\t' '\n' | grep -c "^available$" || true)
  echo -ne "  Mount targets ready: ${READY} / ${TOTAL}\r"
  if [ "$TOTAL" -ge 1 ] && [ "$READY" = "$TOTAL" ]; then
    echo ""
    break
  fi
  sleep 8
  attempt=$((attempt + 1))
done
echo ""
success "EFS mount targets ready"


log "Creating EFS access point..."
ACCESS_POINT_ID=$(aws efs create-access-point \
  --file-system-id "$EFS_ID" \
  --posix-user Uid=1000,Gid=1000 \
  --root-directory "Path=/data,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755}" \
  --tags Key=Name,Value="${APP_NAME}-access-point" \
  --query 'AccessPointId' --output text --region "$REGION")
success "EFS access point: $ACCESS_POINT_ID"

# ── IAM TASK EXECUTION ROLE ───────────────────────────────────────────────────
header "IAM task execution role"

ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole \
  --query 'Role.Arn' --output text 2>/dev/null || true)

if [ -z "$ROLE_ARN" ]; then
  log "Creating ecsTaskExecutionRole..."
  ROLE_ARN=$(aws iam create-role \
    --role-name ecsTaskExecutionRole \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"ecs-tasks.amazonaws.com"},
        "Action":"sts:AssumeRole"
      }]
    }' \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  success "Created ecsTaskExecutionRole"
else
  success "ecsTaskExecutionRole already exists"
fi

# ── ECS SERVICE-LINKED ROLE ──────────────────────────────────────────────────────────────
header "ECS service-linked role"

log "Ensuring ECS service-linked role exists..."
aws iam create-service-linked-role \
  --aws-service-name ecs.amazonaws.com 2>/dev/null || true
success "ECS service-linked role ready"

# ── ECS CLUSTER ───────────────────────────────────────────────────────────────
header "ECS cluster"

log "Creating ECS cluster (or reusing if it exists)..."
aws ecs create-cluster --cluster-name "$APP_NAME" --region "$REGION" >/dev/null 2>/dev/null || true
success "Cluster: $APP_NAME"

# ── CLOUDWATCH LOGS ───────────────────────────────────────────────────────────
header "CloudWatch log group"

LOG_GROUP="/ecs/${APP_NAME}-webapp"
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null || true
success "Log group: $LOG_GROUP"

# ── ECR IMAGE BUILD & PUSH ────────────────────────────────────────────────────
header "Building and pushing container image to ECR"

ECR_REPO="${APP_NAME}-webapp"
CONTAINER_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"

log "Creating ECR repository (or reusing if it exists)..."
EXISTING_REPO=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$REGION" \
  --query 'repositories[0].repositoryUri' \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_REPO" ] || [ "$EXISTING_REPO" = "None" ]; then
  aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$REGION" >/dev/null
fi
success "ECR repository ready: $CONTAINER_IMAGE"

# Check if image already exists in ECR — skip build if so
EXISTING_IMAGE=$(aws ecr describe-images \
  --repository-name "$ECR_REPO" \
  --image-ids imageTag=latest \
  --region "$REGION" \
  --query 'imageDetails[0].imageTags[0]' \
  --output text 2>/dev/null || echo "")

if [ "$EXISTING_IMAGE" = "latest" ]; then
  success "Image already exists in ECR — skipping build"
else
  log "Logging Docker into ECR..."
  aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
  success "Docker logged into ECR"

  log "Cloning repo from GitHub..."
  BUILD_DIR=$(mktemp -d)
  git clone $GITHUB_REPO "$BUILD_DIR" --depth 1 --quiet
  success "Repo cloned"

  log "Building Docker image (this takes 3-5 minutes)..."
  docker buildx build --platform linux/amd64 --push -t "${CONTAINER_IMAGE}" "$BUILD_DIR" --quiet
  rm -rf "$BUILD_DIR"
  success "Image built and pushed to ECR: $CONTAINER_IMAGE"
fi

# ── TASK DEFINITION ───────────────────────────────────────────────────────────
header "Task definition"

log "Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --family "${APP_NAME}-webapp" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --execution-role-arn "$ROLE_ARN" \
  --region "$REGION" \
  --container-definitions "[
    {
      \"name\": \"${APP_NAME}-webapp\",
      \"image\": \"${CONTAINER_IMAGE}\",
      \"essential\": true,
      \"portMappings\": [{ \"containerPort\": ${CONTAINER_PORT}, \"protocol\": \"tcp\" }],
      \"environment\": [
        { \"name\": \"TASKAPP_LOG_LEVEL\",      \"value\": \"${LOG_LEVEL}\" },
        { \"name\": \"TASKAPP_BIND_HOST\",      \"value\": \"0.0.0.0\" },
        { \"name\": \"TASKAPP_BIND_PORT\",      \"value\": \"${CONTAINER_PORT}\" },
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
        \"command\": [\"CMD-SHELL\", \"curl -f http://localhost:${CONTAINER_PORT}/health || exit 1\"],
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
  ]" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
success "Task definition: $TASK_DEF_ARN"

# ── APPLICATION LOAD BALANCER ─────────────────────────────────────────────────
header "Application Load Balancer"

log "Creating ALB (or reusing if it exists)..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${APP_NAME}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${APP_NAME}-alb" \
    --subnets "$SUBNET_1" "$SUBNET_2" \
    --security-groups "$ALB_SG_ID" \
    --scheme internet-facing \
    --type application \
    --region "$REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$REGION")
success "ALB: $ALB_DNS"

log "Creating target group (or reusing if it exists)..."
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${APP_NAME}-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${APP_NAME}-tg" \
    --protocol HTTP \
    --port $CONTAINER_PORT \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path /health \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
success "Target group: $TG_ARN"

log "Creating ALB listener..."
aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
  --region "$REGION" >/dev/null 2>/dev/null || warn "Listener may already exist — continuing"
success "Listener created (port 80 → container port $CONTAINER_PORT)"

# ── ECS SERVICE ───────────────────────────────────────────────────────────────
header "ECS service"

log "Creating ECS service (or updating if it exists)..."
EXISTING_SVC=$(aws ecs describe-services \
  --cluster "$APP_NAME" --services "${APP_NAME}-webapp" \
  --query 'services[?status!=`INACTIVE`].status' \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [ -n "$EXISTING_SVC" ] && [ "$EXISTING_SVC" != "None" ]; then
  aws ecs update-service \
    --cluster "$APP_NAME" \
    --service "${APP_NAME}-webapp" \
    --task-definition "${APP_NAME}-webapp" \
    --desired-count 1 \
    --force-new-deployment \
    --region "$REGION" >/dev/null
else
aws ecs create-service \
  --cluster "$APP_NAME" \
  --service-name "${APP_NAME}-webapp" \
  --task-definition "${APP_NAME}-webapp" \
  --desired-count 1 \
  --launch-type FARGATE \
  --region "$REGION" \
  --network-configuration "awsvpcConfiguration={
    subnets=[$SUBNET_1,$SUBNET_2],
    securityGroups=[$ECS_SG_ID],
    assignPublicIp=ENABLED
  }" \
  --load-balancers "targetGroupArn=${TG_ARN},containerName=${APP_NAME}-webapp,containerPort=${CONTAINER_PORT}" \
  --health-check-grace-period-seconds 30 >/dev/null
fi
success "ECS service created"

# ── SAVE STATE ────────────────────────────────────────────────────────────────
cat > "$STATE_FILE" <<EOF
# taskDemoWebApp deployment state — generated by deploy.sh
# Used by teardown.sh and manage.sh — do not delete
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
CONTAINER_IMAGE=$CONTAINER_IMAGE
EOF
success "State saved to $STATE_FILE"

# ── WAIT FOR HEALTHY ──────────────────────────────────────────────────────────
header "Waiting for app to become healthy"
log "This takes 3-5 minutes while the container starts and the ALB health checks pass..."
echo ""

attempt=0
max=40
while [ $attempt -lt $max ]; do
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
echo -e "${BOLD}${GREEN}  Deployment complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}App URL:${NC}   http://${ALB_DNS}/"
echo -e "  ${BOLD}API Docs:${NC}  http://${ALB_DNS}/docs"
echo -e "  ${BOLD}Health:${NC}    http://${ALB_DNS}/health"
echo ""
echo -e "  ${BOLD}Username:${NC}  ${ADMIN_USERNAME}"
echo -e "  ${BOLD}Password:${NC}  ${ADMIN_PASSWORD}"
echo ""
echo -e "  ${YELLOW}This is the default administrator. Use it to log in and provision other users.${NC}"
echo ""
echo -e "  Run ${BOLD}./manage.sh${NC} to stop, start, restart, or view logs."
echo -e "  Run ${BOLD}./teardown.sh${NC} to delete all AWS resources."
echo ""
