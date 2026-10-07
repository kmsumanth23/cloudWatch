# CloudWatch Agent — Memory Utilization Monitoring

Procedure for enabling per-instance memory metrics on EC2, as implemented and
verified in the HXSA test environment.

| | |
|---|---|
| AWS account | `491004314536` (hclsw-aws-hxsa) |
| Region | `us-east-1` |
| Client / environment | `hxsa` / `awsv9m` (`env_seq: 3`) |
| Reference instance | `i-051a3ed2c30e1e36d` — `duusea1ahxsautlbst3001`, t2.large |
| OS | AlmaLinux 8.10 |
| Agent version | `1.300073.1b1859` |

---

## 1. Purpose

EC2 instances are monitored only for CPU via default CloudWatch metrics. CPU
alone is insufficient for right-sizing: an instance can look idle on CPU while
being fully committed on memory, and downsizing on CPU evidence alone causes
incidents.

This procedure publishes per-instance memory utilization to CloudWatch so
right-sizing analysis has a complete picture. It is read-only monitoring — the
agent collects and publishes metrics, and changes nothing about the instance or
its workload.

---

## 2. Prerequisite — provided by the IAM team

An IAM role and a matching instance profile must exist before anything below
can run. **Creating them is the IAM team's task, not part of this procedure.**

What was provided for HXSA:

```
Role name          HCLSW_AWS_HXSA_EC2_CLOUDWATCH_FULLACCESS_SVC_ROLE
Role ARN           arn:aws:iam::491004314536:role/HCLSW_AWS_HXSA_EC2_CLOUDWATCH_FULLACCESS_SVC_ROLE
Trusted entity     ec2.amazonaws.com
Attached policies  arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
                   arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
Instance profile   HCLSW_AWS_HXSA_EC2_CLOUDWATCH_FULLACCESS_SVC_ROLE
```

`CloudWatchAgentServerPolicy` is the one the agent needs. It grants
`cloudwatch:PutMetricData`, `ec2:DescribeVolumes`, `ec2:DescribeTags`, the
CloudWatch Logs write actions, and `ssm:GetParameter` scoped to
`AmazonCloudWatch-*` parameters.

`CloudWatchLogsFullAccess` was attached as well. It is not required for a
metrics-only configuration and grants destructive log actions
(`logs:DeleteLogGroup` and similar), so it is worth reviewing before this is
applied more widely.

Confirm the prerequisite is complete before proceeding:

```bash
P="--profile srvchxsa"
R=HCLSW_AWS_HXSA_EC2_CLOUDWATCH_FULLACCESS_SVC_ROLE

# trust policy must include ec2.amazonaws.com
aws iam get-role $P --role-name $R --query 'Role.AssumeRolePolicyDocument'

# attached policies
aws iam list-attached-role-policies $P --role-name $R --output text

# an instance profile must exist — a role with EC2 trust is not usable without one
aws iam list-instance-profiles-for-role $P --role-name $R \
  --query 'InstanceProfiles[].InstanceProfileName' --output text
```

An empty result from the last command means the role cannot be attached to an
instance yet. Return to the IAM team.

---

## 3. Associate the instance profile

```bash
P="--profile srvchxsa"
VM=i-051a3ed2c30e1e36d
PROF=HCLSW_AWS_HXSA_EC2_CLOUDWATCH_FULLACCESS_SVC_ROLE

aws ec2 associate-iam-instance-profile $P \
  --instance-id $VM \
  --iam-instance-profile Name=$PROF
```

Record the returned `AssociationId` — it is the rollback handle. For the
reference instance it was `iip-assoc-0e879972269eb57be`.

Requires `ec2:AssociateIamInstanceProfile` **and** `iam:PassRole` on the role.
A missing `iam:PassRole` produces a confusingly-worded denial.

**An instance can hold exactly one instance profile.** Where the instance has
none, associating is purely additive. Where one is already attached, this is a
*replacement* and the previous profile's permissions are silently lost — check
first and resolve deliberately:

```bash
aws ec2 describe-instances $P --instance-ids $VM \
  --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text
```

Allow about a minute for credentials to appear in IMDS.

---

## 4. Confirm the instance has credentials

Three checks, each isolating a different failure. Run them before installing
anything, so that a later problem is known to be configuration rather than IAM.

```bash
# the role is visible to anything running on the host
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
# expect: HCLSW_AWS_HXSA_EC2_CLOUDWATCH_FULLACCESS_SVC_ROLE
```

```bash
# what a daemon sees — no --profile, no credentials file
aws sts get-caller-identity
```

Expected on the reference instance:

```json
{
  "UserId": "AROAXEURDIOUC6WCEC5CG:i-051a3ed2c30e1e36d",
  "Account": "491004314536",
  "Arn": "arn:aws:sts::491004314536:assumed-role/HCLSW_AWS_HXSA_EC2_CLOUDWATCH_FULLACCESS_SVC_ROLE/i-051a3ed2c30e1e36d"
}
```

The instance ID appearing as the session name is the signature of
instance-profile credentials. Note the contrast: `aws sts get-caller-identity
--profile srvchxsa` returns the *operator* role, because the credentials file
ranks above IMDS in the lookup chain. The CloudWatch agent has no credentials
file, so IMDS is what it gets.

```bash
# the role can actually publish — this is a write, and creates one throwaway metric
aws cloudwatch put-metric-data \
  --namespace CWAgentPreflight --metric-name preflight \
  --dimensions InstanceId=$VM --value 1 --region us-east-1
```

Silence means success. Confirm it landed:

```bash
aws cloudwatch list-metrics $P --namespace CWAgentPreflight --query 'length(Metrics)'
```

---

## 5. Install the agent

AlmaLinux 8.10 is RHEL 8 ABI, so the `redhat/amd64` package applies.

```bash
cd /tmp
curl -O https://amazoncloudwatch-agent-us-east-1.s3.us-east-1.amazonaws.com/redhat/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm
```

Creates the unprivileged `cwagent` user and group. No reboot.

---

## 6. Deploy the configuration

Write `/opt/aws/amazon-cloudwatch-agent/etc/cwagent-memory.json`:

```json
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent",
    "debug": false
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "mem": {
        "measurement": [{ "name": "mem_used_percent", "unit": "Percent" }],
        "metrics_collection_interval": 60
      }
    }
  }
}
```

The file is **identical on every host**. `${aws:InstanceId}` is an agent
placeholder resolved from IMDS at startup — not a shell variable, not an SSM
substitution. Do not replace it with a literal instance ID; that makes the file
host-specific and breaks any fleet rollout.

If writing it from a shell heredoc, quote the delimiter (`<<` followed by
`'EOF'`) or bash expands the placeholder to an empty string. Verify:

```bash
grep InstanceId /opt/aws/amazon-cloudwatch-agent/etc/cwagent-memory.json
# must show: "InstanceId": "${aws:InstanceId}"
```

### Why the configuration looks like this

- **One metric per instance.** Memory only — no logs, disk, network or process
  metrics. Keeps cost near zero and keeps the change read-only in every
  meaningful sense.
- **`InstanceId` as the sole dimension.** Minimum metric count, and the only
  shape AWS Compute Optimizer can consume should that be enabled later.
  Omitting `append_dimensions` entirely would publish a `host` dimension
  instead, which no right-sizing tool reads.
- **60-second interval** for the pilot. 300 seconds is the likely production
  setting: right-sizing does not need per-minute resolution, and it cuts
  `PutMetricData` request cost roughly fivefold.

Avoid `amazon-cloudwatch-agent-config-wizard`. Its defaults collect
cpu-per-core, disk, diskio, mem, netstat and swap, and append three dimensions
— roughly 15–20x the metrics needed, in a shape right-sizing tools cannot use.

---

## 7. Load the configuration and start

```bash
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/cwagent-memory.json
```

This validates the JSON, translates it to the agent's internal TOML, enables
the systemd unit and starts it. The `-s` is what starts it — without it the
agent stays stopped.

**Install, configure and start are three separate things.** A successful
package install leaves the agent on disk and not running. This step is what
makes it collect.

---

## 8. Verification

Ordered so each step isolates a different failure.

```bash
# agent state
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
# expect: "status": "running", "configstatus": "configured"

# the metric exists with the right identity
aws cloudwatch list-metrics $P --namespace CWAgent \
  --metric-name mem_used_percent \
  --dimensions Name=InstanceId,Value=$VM

# datapoints are arriving
aws cloudwatch get-metric-data $P --region us-east-1 \
  --metric-data-queries '[{"Id":"m1","MetricStat":{"Metric":{"Namespace":"CWAgent",
    "MetricName":"mem_used_percent",
    "Dimensions":[{"Name":"InstanceId","Value":"'"$VM"'"}]},
    "Period":60,"Stat":"Average"}}]' \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time   $(date -u +%Y-%m-%dT%H:%M:%SZ)

free -m
```

**The datapoint query is the only step that proves the system works.**
Everything before it can pass while no usable data exists.

### Cross-check the value

```
mem_used_percent = (total - free - buff/cache) / total
```

Reference instance, measured:

```
free -m:  total 7950, free 3651, buff/cache 3327
          (7950 - 3651 - 3327) / 7950 = 12.23%
metric:   12.249%
```

Note the metric **excludes reclaimable page cache**. That is the correct figure
for right-sizing — cache is not memory pressure — but it reads far lower than a
naive `used/total` from a typical dashboard. On this host 3.3 GB of cache is
ignored.

### Failure signatures

| Symptom | Cause |
|---|---|
| `status: running`, `list-metrics` empty | IAM denial or wrong namespace — check `/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log` |
| `status: stopped` | `fetch-config` was run without `-s` |
| Metric exists, dimension is `host` | `append_dimensions` missing from the config |
| Dimension value empty | heredoc was unquoted; the shell expanded the placeholder |
| IMDS returns 404 | no instance profile associated |
| IMDS times out or returns 403 | IMDS disabled or hop-limit restricted — a different problem |

---

## 9. Rollback

Online, no reboot, no data loss, no application restart.

```bash
systemctl stop amazon-cloudwatch-agent
rpm -e amazon-cloudwatch-agent
aws ec2 disassociate-iam-instance-profile $P \
  --association-id iip-assoc-0e879972269eb57be
```

Published metrics remain until they age out. They are harmless and incur no
ongoing charge once data stops arriving. Target: under 15 minutes.

---

## 10. Cost

Per instance, one metric:

- Custom metric — billed per metric per month.
- `PutMetricData` requests — roughly 43,800/month at 60s, 8,760/month at 300s,
  billed per 1,000.

Order of magnitude: **under USD 1 per instance per month**. At 60s the request
component typically exceeds the metric component, which is the main reason to
prefer 300s at scale. Verify against current pricing for the region before
quoting figures.

---

## 11. Automation

The procedure above is automated in `aws-v9-automation`:

```
cloudwatch-agent.yml                      single play, entry point
tasks/cloudwatch-agent.yml                all phases, tagged cw-agent
templates/amazon-cloudwatch-agent.json.j2
defaults/cloudwatch.yml
```

Targets come from `vsi_instances` in the client environment vars file — entries
flagged `cloudwatch_agent: true` are selected, and a Name-tag pattern is derived
per entry. For `hxsa` / `awsv9m` that is `*hxsautlbst3001`, matching
`duusea1ahxsautlbst3001`.

Scope is one client environment per run, matching how AWX job templates select
a single inventory. The IAM prerequisite in Section 2 stays with the IAM team;
the automation asserts the instance profile name is configured and stops if not.

---

## 12. Open items

- [ ] Agent resource footprint on the host
- [ ] Measured cost after 7 days
- [ ] 7-14 day collection window before any right-sizing analysis
- [ ] Decide 60s vs 300s interval for production from pilot data
- [ ] Review `CloudWatchLogsFullAccess` on the instance role before wider rollout
- [ ] Remaining environments — the standalone instances in this account span
      `env_seq` 1, 2, 3 and 7, so full coverage is one run per environment
- [ ] New-instance coverage: an instance launched today gets nothing until the
      automation runs again

---

## 13. Reference

- Agent configuration schema — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Agent-Configuration-File-Details.html
- Metrics collected by the agent — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/metrics-collected-by-CloudWatch-agent.html
- IAM roles for the agent — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/create-iam-roles-for-cloudwatch-agent.html
- `CloudWatchAgentServerPolicy` — https://docs.aws.amazon.com/aws-managed-policy/latest/reference/CloudWatchAgentServerPolicy.html
- Compute Optimizer EC2 metrics — https://docs.aws.amazon.com/compute-optimizer/latest/ug/ec2-metrics-analyzed.html
- Troubleshooting the agent — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/troubleshooting-CloudWatch-Agent.html
- Agent source (MIT) — https://github.com/aws/amazon-cloudwatch-agent
