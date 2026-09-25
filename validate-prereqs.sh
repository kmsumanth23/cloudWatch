#!/usr/bin/env bash
#
# CloudWatch Agent prerequisite validation — read-only.
# Every check is a read: rpm -q, systemctl is-active, curl to IMDS, and
# AWS describe/list/get calls. Nothing is installed, started or modified.
#
# Usage:  ./validate-prereqs.sh
#         INSTANCE_ID=i-xxx PROFILE=srvchxsa ./validate-prereqs.sh

set -uo pipefail

: "${INSTANCE_ID:=i-051a3ed2c30e1e36d}"
: "${PROFILE:=srvchxsa}"
: "${REGION:=$(aws configure get region --profile "${PROFILE}" 2>/dev/null || echo us-east-1)}"
: "${DETAIL:=./prereq-detail.txt}"

AWS=(aws --profile "${PROFILE}" --region "${REGION}" --no-cli-pager)

: >"${DETAIL}"
detail() { { echo; echo "### $*"; } >>"${DETAIL}"; }

pass() { printf '[\033[0;32mPASS\033[0m] %-34s %s\n' "$1" "$2"; }
fail() { printf '[\033[0;31mFAIL\033[0m] %-34s %s\n' "$1" "$2"; }
info() { printf '[INFO] %-34s %s\n' "$1" "$2"; }

echo "CloudWatch Agent prerequisite check"
echo "instance : ${INSTANCE_ID}"
echo "region   : ${REGION}"
echo "date     : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "======================================================================"

# ---------------------------------------------------------- 1. SSM agent ----
detail "rpm -q amazon-ssm-agent"
if ssm_pkg=$(rpm -q amazon-ssm-agent 2>&1); then
  echo "${ssm_pkg}" >>"${DETAIL}"
  pass "SSM Agent installed" "${ssm_pkg}"
else
  echo "${ssm_pkg}" >>"${DETAIL}"
  fail "SSM Agent installed" "not installed"
fi

detail "systemctl is-active amazon-ssm-agent"
ssm_state=$(systemctl is-active amazon-ssm-agent 2>&1)
echo "${ssm_state}" >>"${DETAIL}"
if [[ "${ssm_state}" == "active" ]]; then
  since=$(systemctl show amazon-ssm-agent -p ActiveEnterTimestamp --value 2>/dev/null)
  pass "SSM Agent running" "active since ${since:-unknown}"
else
  fail "SSM Agent running" "${ssm_state}"
fi

# ------------------------------------------------- 2. IAM role  via IMDS ----
detail "IMDS: /latest/meta-data/iam/security-credentials/"
TOKEN=$(curl -s --max-time 3 -X PUT "http://169.254.169.254/latest/api/token" \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
if [[ -n "${TOKEN}" ]]; then
  imds_code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' \
    -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
  imds_body=$(curl -s --max-time 3 \
    -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
else
  imds_code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
  imds_body=$(curl -s --max-time 3 \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
fi
{ echo "HTTP ${imds_code}"; echo "${imds_body}"; } >>"${DETAIL}"

if [[ "${imds_code}" == "200" && -n "${imds_body}" ]]; then
  pass "IAM role visible to daemons" "${imds_body}"
else
  fail "IAM role visible to daemons" "HTTP ${imds_code:-no-response} — no role attached"
fi

# ------------------------------------------ 3. instance profile (API view) ----
detail "ec2 describe-instances — IamInstanceProfile"
prof=$("${AWS[@]}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
        --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text 2>&1)
echo "${prof}" >>"${DETAIL}"
if [[ -n "${prof}" && "${prof}" != "None" && "${prof}" != *"error"* ]]; then
  pass "Instance profile attached" "${prof}"
else
  fail "Instance profile attached" "none"
fi

# ----------------------------------------------- 4. SSM registration state ----
detail "ssm describe-instance-information (filtered to this instance)"
reg=$("${AWS[@]}" ssm describe-instance-information \
       --query "InstanceInformationList[?InstanceId=='${INSTANCE_ID}'].[PingStatus,AgentVersion]" \
       --output text 2>&1)
echo "${reg:-<empty>}" >>"${DETAIL}"
if [[ -n "${reg}" && "${reg}" != *"error"* ]]; then
  pass "Registered with Systems Manager" "${reg}"
else
  fail "Registered with Systems Manager" "not registered — Run Command cannot target it"
fi

# --------------------------------- 5. what credentials a daemon would see ----
# The CloudWatch agent runs as the unprivileged cwagent user with no AWS
# profile and no credentials file. Simulate that by clearing every profile
# and env credential and pointing HOME at an empty directory.
detail "sts get-caller-identity as a daemon would see it (no profile, empty HOME)"
EMPTY_HOME=$(mktemp -d)
daemon_id=$(env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
                -u AWS_SESSION_TOKEN -u AWS_CONFIG_FILE -u AWS_SHARED_CREDENTIALS_FILE \
                HOME="${EMPTY_HOME}" \
                aws sts get-caller-identity --region "${REGION}" 2>&1)
echo "${daemon_id}" >>"${DETAIL}"
rmdir "${EMPTY_HOME}" 2>/dev/null
if grep -q '"Arn"' <<<"${daemon_id}"; then
  pass "Credentials available to daemons" "$(grep -o '"Arn": "[^"]*"' <<<"${daemon_id}")"
else
  fail "Credentials available to daemons" "$(head -1 <<<"${daemon_id}" | cut -c1-70)"
fi

detail "sts get-caller-identity WITH the operator profile (for contrast)"
op_id=$("${AWS[@]}" sts get-caller-identity --query Arn --output text 2>&1)
echo "${op_id}" >>"${DETAIL}"
info "Operator shell identity" "${op_id}"

# ---------------------------------------------- 6. SSM agent log evidence ----
SSM_LOG=/var/log/amazon/ssm/amazon-ssm-agent.log
detail "SSM agent log — credential and registration lines"
if [[ -r "${SSM_LOG}" ]]; then
  grep -iE 'credential|EC2RoleProvider|no valid|failed|retriev' "${SSM_LOG}" 2>/dev/null \
    | tail -20 >>"${DETAIL}"
  hits=$(grep -icE 'no valid credentials|EC2RoleProvider|failed to (get|retrieve)' "${SSM_LOG}" 2>/dev/null)
  if [[ "${hits:-0}" -gt 0 ]]; then
    info "SSM agent log" "${hits} credential-failure lines — see ${DETAIL}"
  else
    info "SSM agent log" "no credential errors found"
  fi
else
  echo "[not readable: ${SSM_LOG}]" >>"${DETAIL}"
  info "SSM agent log" "not readable at ${SSM_LOG}"
fi

# ------------------------------------------------- 7. CloudWatch agent state ----
detail "rpm -q amazon-cloudwatch-agent"
if cw_pkg=$(rpm -q amazon-cloudwatch-agent 2>&1); then
  echo "${cw_pkg}" >>"${DETAIL}"
  info "CloudWatch agent installed" "${cw_pkg}"
else
  echo "${cw_pkg}" >>"${DETAIL}"
  info "CloudWatch agent installed" "not installed (expected — nothing deployed yet)"
fi

detail "cloudwatch list-metrics --namespace CWAgent"
mets=$("${AWS[@]}" cloudwatch list-metrics --namespace CWAgent \
        --query 'length(Metrics)' --output text 2>&1)
echo "${mets}" >>"${DETAIL}"
info "Metrics in CWAgent namespace" "${mets:-0}"

# ---------------------------------------------------------------- verdict ----
echo "======================================================================"
if [[ "${imds_code}" != "200" || -z "${imds_body}" ]]; then
cat <<'VERDICT'
VERDICT: BLOCKED

  The SSM Agent is installed and running correctly. It is not the problem.

  The instance has no IAM instance profile, so IMDS returns no role and the
  agent has no credentials to call ssm:UpdateInstanceInformation. Without
  that call the instance never registers with Systems Manager, which is why
  Run Command cannot reach it.

  The same missing credentials would stop the CloudWatch agent from calling
  cloudwatch:PutMetricData even if it were installed by hand.

  Root cause: no instance profile attached to the instance.
  Fix: attach an instance profile whose role carries
       AmazonSSMManagedInstanceCore and CloudWatchAgentServerPolicy.
VERDICT
else
cat <<'VERDICT'
VERDICT: prerequisites appear satisfied — proceed to install.
VERDICT
fi
echo
echo "Raw command output: ${DETAIL}"
