#!/bin/bash
# =============================================================================
# setup.sh — Pre-deployment prerequisite checker for taskDemoWebApp
# =============================================================================
# Run this first before deploy.sh to confirm everything is in place.
# Safe to run multiple times — it checks only, never creates anything.
# =============================================================================

set -uo pipefail

GITHUB_REPO_WEB="https://github.com/tmanmidwest/taskDemoWebApp"  # <-- change if you fork

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS="${GREEN}✔${NC}"
FAIL="${RED}✖${NC}"
WARN="${YELLOW}⚠${NC}"
ARROW="${BLUE}▶${NC}"

header() { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }
pass()   { echo -e "  ${PASS}  $1"; }
fail()   { echo -e "  ${FAIL}  ${RED}$1${NC}"; FAILED=$((FAILED+1)); }
warn()   { echo -e "  ${WARN}  ${YELLOW}$1${NC}"; }
info()   { echo -e "  ${ARROW}  $1"; }

FAILED=0

echo ""
echo -e "${BOLD}${BLUE}  taskDemoWebApp — Setup Checker${NC}"
echo -e "  Checking everything you need before running deploy.sh"

# ── REQUIRED TOOLS ────────────────────────────────────────────────────────────
header "Required tools"

if command -v aws >/dev/null 2>&1; then
  AWS_VER=$(aws --version 2>&1 | awk '{print $1}')
  pass "AWS CLI installed ($AWS_VER)"
else
  fail "AWS CLI not found"
  info "Install from: https://aws.amazon.com/cli/"
fi

if command -v docker >/dev/null 2>&1; then
  DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
  pass "Docker installed ($DOCKER_VER)"
  if docker info >/dev/null 2>&1; then
    pass "Docker is running"
  else
    fail "Docker is installed but not running — start Docker Desktop"
  fi
else
  fail "Docker not found"
  info "Install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
fi

if docker buildx version >/dev/null 2>&1; then
  pass "Docker Buildx available (required for Apple Silicon Macs)"
else
  warn "Docker Buildx not found — may cause issues on Apple Silicon Macs"
  info "Update Docker Desktop to get Buildx automatically"
fi

if command -v git >/dev/null 2>&1; then
  GIT_VER=$(git --version | awk '{print $3}')
  pass "Git installed ($GIT_VER)"
else
  fail "Git not found"
  info "On Mac: run 'xcode-select --install' and follow the prompts"
  info "Or install from: https://git-scm.com/"
fi

if command -v python3 >/dev/null 2>&1; then
  PY_VER=$(python3 --version | awk '{print $2}')
  pass "Python 3 installed ($PY_VER)"
else
  fail "Python 3 not found"
  info "Install from: https://www.python.org/downloads/"
fi

# ── AWS CREDENTIALS ───────────────────────────────────────────────────────────
header "AWS credentials"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null || echo "")
if [ -n "$CALLER" ]; then
  ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])" 2>/dev/null || echo "unknown")
  USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])" 2>/dev/null || echo "unknown")
  REGION=$(aws configure get region 2>/dev/null || echo "")
  pass "Logged in to AWS"
  info "Account: $ACCOUNT"
  info "Identity: $USER"
  if [ -n "$REGION" ]; then
    pass "Default region set: $REGION"
  else
    fail "No default region configured"
    info "Run: aws configure set region us-east-1  (or your preferred region)"
  fi
else
  fail "Not logged in to AWS"
  info "Run 'aws configure' to set up your credentials"
  info "You will need: AWS Access Key ID, Secret Access Key, and a region"
fi

# ── AWS PERMISSIONS ───────────────────────────────────────────────────────────
header "AWS permissions"
info "Checking that your AWS account has the required permissions..."

aws ecs list-clusters --region "${REGION:-us-east-1}" >/dev/null 2>&1 \
  && pass "ECS access confirmed" \
  || fail "No ECS access — your AWS user may need ECS permissions"

aws ecr describe-repositories --region "${REGION:-us-east-1}" >/dev/null 2>&1 \
  && pass "ECR access confirmed" \
  || fail "No ECR access — your AWS user may need ECR permissions"

aws efs describe-file-systems --region "${REGION:-us-east-1}" >/dev/null 2>&1 \
  && pass "EFS access confirmed" \
  || fail "No EFS access — your AWS user may need EFS permissions"

aws ec2 describe-vpcs --region "${REGION:-us-east-1}" >/dev/null 2>&1 \
  && pass "EC2/VPC access confirmed" \
  || fail "No EC2 access — your AWS user may need EC2 permissions"

aws elbv2 describe-load-balancers --region "${REGION:-us-east-1}" >/dev/null 2>&1 \
  && pass "Elastic Load Balancing access confirmed" \
  || fail "No ELB access — your AWS user may need ELB permissions"

aws iam get-role --role-name ecsTaskExecutionRole >/dev/null 2>&1 \
  && pass "IAM access confirmed (ecsTaskExecutionRole exists)" \
  || {
    aws iam list-roles >/dev/null 2>&1 \
      && warn "IAM access confirmed but ecsTaskExecutionRole not yet created (deploy.sh will create it)" \
      || fail "No IAM access — your AWS user may need IAM permissions"
  }

# ── GITHUB CONNECTIVITY ───────────────────────────────────────────────────────
header "GitHub connectivity"

if curl -sf "$GITHUB_REPO_WEB" >/dev/null 2>&1; then
  pass "GitHub repo is reachable ($GITHUB_REPO_WEB)"
else
  warn "Cannot reach $GITHUB_REPO_WEB"
  info "If you haven't pushed the repo yet, create it and update the URL in deploy.sh/setup.sh"
fi

# ── DEFAULT VPC ───────────────────────────────────────────────────────────────
header "AWS networking"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text --region "${REGION:-us-east-1}" 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  pass "Default VPC found: $VPC_ID"
  SUBNET_COUNT=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'Subnets | length(@)' \
    --output text --region "${REGION:-us-east-1}" 2>/dev/null || echo "0")
  if [ "$SUBNET_COUNT" -ge 2 ]; then
    pass "Default VPC has $SUBNET_COUNT subnets (need at least 2)"
  else
    fail "Default VPC only has $SUBNET_COUNT subnet(s) — need at least 2 in different AZs"
    info "Contact your AWS administrator to add subnets to the default VPC"
  fi
else
  fail "No default VPC found"
  info "A default VPC is required. Create one in the AWS console:"
  info "EC2 → Your VPCs → Actions → Create Default VPC"
fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"

if [ "$FAILED" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}  All checks passed — you are ready to deploy!${NC}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Run ${BOLD}./deploy.sh${NC} to deploy the app to your AWS account."
else
  echo -e "${BOLD}${RED}  ${FAILED} check(s) failed — fix the issues above first.${NC}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Fix the ${RED}✖${NC} items above, then re-run ${BOLD}./setup.sh${NC} to verify."
fi
echo ""
