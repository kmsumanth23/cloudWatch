# CloudWatch Agent + Memory Metrics — Reference

Scope: collecting EC2 memory utilization for right-sizing. Written against the
HXSA pilot, but the concepts are general.

## Reading order

**Before the install (~30 min)** — sections 1, 2, 3, 6.
**Before you trust the data (~1 hr)** — add 4, 5, 8.
**Reference** — 7, 9, 10.

---

## 1. The single most important concept: dimensions are part of metric identity

A CloudWatch metric is identified by the tuple:

    (Namespace, MetricName, {set of Dimensions})

Change any element and it is a **different metric**, stored separately and billed
separately. There is no "same metric with extra labels" — that is a Prometheus
mental model and it does not apply here.

Consequences that bite people:

- `mem_used_percent` with `{InstanceId}` and `mem_used_percent` with
  `{InstanceId, InstanceType}` are two metrics. You pay for both.
- A tool looking for the first will not find the second. This is exactly how
  Compute Optimizer silently sees nothing.
- You cannot "drop a dimension" at query time to aggregate. Aggregation across
  dimensions must be configured at publish time (`aggregation_dimensions`).

Read: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_concepts.html

---

## 2. Where the agent runs determines everything about IAM

Same binary, four deployment contexts, four different identity mechanisms.
Confusing these is the most common source of wasted time.

| Context | Identity mechanism | What you configure |
|---|---|---|
| **EC2 instance** | IAM role via **instance profile** | Trust `ec2.amazonaws.com`; attach `CloudWatchAgentServerPolicy` |
| **EKS pod** (DaemonSet) | **IRSA** (OIDC) or **EKS Pod Identity** | Service account in `amazon-cloudwatch` ns |
| **ECS task** | **Task role** | Task definition `taskRoleArn` |
| **On-premises** | IAM **user** + access keys, or SSM hybrid activation | `~/.aws/credentials` on the host |

An EC2 instance has **exactly one** instance profile. Attaching a new one
replaces the old one and silently removes whatever permissions the workload was
using. Add policies to the existing role instead of swapping the profile.

Read: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/create-iam-roles-for-cloudwatch-agent.html

---

## 3. Install, configure, and start are three separate things

This is the #1 cause of "the ticket is green but there is no data."

    1. Install    AWS-ConfigureAWSPackage (action=Install, name=AmazonCloudWatchAgent)
                  -> binary on disk. Agent NOT running. Zero metrics.

    2. Configure  AmazonCloudWatch-ManageAgent (action=configure,
                  optionalConfigurationSource=ssm, optionalConfigurationLocation=<param>)
                  -> config fetched and written to disk

    3. Start      same document with optionalRestart=yes, or
                  amazon-cloudwatch-agent-ctl -a start

A successful step-1 command proves nothing about data flowing. Always verify
with `list-metrics` (section 10), never with SSM command status.

Read: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/installing-cloudwatch-agent-ssm.html

---

## 4. Agent config file anatomy

Three top-level sections. For memory-only collection you need two.

    {
      "agent":   { ... }   // how the agent behaves: interval, run_as_user, logging
      "metrics": { ... }   // what to collect and how to label it
      "logs":    { ... }   // log collection. OMIT ENTIRELY if you don't want logs.
    }

Fields inside `metrics` that matter:

- **`namespace`** — where metrics land. Default `CWAgent`. Compute Optimizer
  requires exactly `CWAgent`.
- **`append_dimensions`** — adds dimensions to every metric. Supports the
  placeholders `${aws:InstanceId}`, `${aws:InstanceType}`, `${aws:ImageId}`,
  `${aws:AutoScalingGroupName}`, plus arbitrary static key/values.
  **Note:** if you omit `append_dimensions` entirely, the agent publishes
  `host` (the hostname) as the dimension instead — which Compute Optimizer
  cannot use.
- **`aggregation_dimensions`** — publishes additional rolled-up metrics across
  the dimension sets you list. `[["InstanceId"]]` means "also publish per
  InstanceId". Each entry creates more metrics, so more cost.
- **`drop_original_metrics`** — when using aggregation, suppresses the
  un-aggregated originals. The cost lever most people miss.
- **`metrics_collection_interval`** — settable globally in `agent` or per
  metric group. Lower = more `PutMetricData` calls = more cost (section 8).

Metric names are OS-specific:

| | Linux | Windows |
|---|---|---|
| Config key | `mem` | `Memory` |
| Measurement | `mem_used_percent` | `% Committed Bytes In Use` |
| Published as | `mem_used_percent` | `Memory % Committed Bytes In Use` |

Windows counters are Performance Monitor object/counter pairs; the agent
prefixes the object name automatically, so no `rename` is needed.

Read: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Agent-Configuration-File-Details.html
Examples: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/create-cloudwatch-agent-configuration-file-examples.html

**Avoid the config wizard** (`amazon-cloudwatch-agent-config-wizard`). Its
defaults collect cpu-per-core, disk, diskio, mem, netstat, swap and append
three dimensions — roughly 15-20x the metrics you need, and the extra
dimensions break Compute Optimizer compatibility. Write the JSON by hand.

---

## 5. The IAM gotcha that wastes an afternoon

`CloudWatchAgentServerPolicy` is:

    {
      "Version": "2012-10-17",
      "Statement": [
        { "Effect": "Allow",
          "Action": [ "cloudwatch:PutMetricData", "ec2:DescribeVolumes",
                      "ec2:DescribeTags", "logs:PutLogEvents",
                      "logs:DescribeLogStreams", "logs:DescribeLogGroups",
                      "logs:CreateLogStream", "logs:CreateLogGroup" ],
          "Resource": "*" },
        { "Effect": "Allow",
          "Action": [ "ssm:GetParameter" ],
          "Resource": "arn:aws:ssm:*:*:parameter/AmazonCloudWatch-*" }
      ]
    }

**`ssm:GetParameter` is scoped to parameters named `AmazonCloudWatch-*`.**

So a config stored at `/myorg/env/cloudwatch/config` is unreadable by the agent
under this policy, and the failure appears only in the agent log — the SSM
command still reports success.

Two ways out:
- Name the parameter `AmazonCloudWatch-<whatever>` at the root. Free.
- Add an inline policy granting `ssm:GetParameter` on your own path. More IAM to
  justify at review.

Prefer the first.

Also note `CloudWatchFullAccess` is **not** a superset in the way you would
expect — it grants `cloudwatch:*` but has no `ssm:GetParameter` at all, and it
grants destructive actions (`DeleteAlarms`, `DeleteDashboards`,
`logs:DeleteLogGroup`) that have no business on a fleet instance profile.

Policy reference: https://docs.aws.amazon.com/aws-managed-policy/latest/reference/CloudWatchAgentServerPolicy.html

---

## 6. Compute Optimizer requirements — the reason the config is prescriptive

Compute Optimizer only reads memory from specific places:

| OS | Namespace | Metric |
|---|---|---|
| Linux | `CWAgent` | `mem_used_percent` (or legacy `MemoryUtilization` in `System/Linux`) |
| Windows | `CWAgent` | `Memory % Committed Bytes In Use` |

And, quoting the docs directly:

> If the InstanceId dimension is missing or you overwrite it with a custom
> dimension name, Compute Optimizer can't collect memory utilization data for
> your instance.

It also needs a minimum observation window before emitting recommendations —
metrics appearing today does not mean recommendations tomorrow.

Read: https://docs.aws.amazon.com/compute-optimizer/latest/ug/ec2-metrics-analyzed.html

---

## 7. Systems Manager pieces you will touch

| Service | Role in this workflow |
|---|---|
| **SSM Agent** | Must be on the instance and >= 2.2.93.0. Pre-installed on current AL2023/Ubuntu/Windows AMIs. Instance must show *Managed* in Fleet Manager. |
| **Distributor** | Hosts the AWS-published `AmazonCloudWatchAgent` package |
| **Run Command** | One-off execution of `AWS-ConfigureAWSPackage` / `AmazonCloudWatch-ManageAgent` |
| **State Manager** | Associations that re-apply on a schedule — this is how you keep the fleet converged and auto-remediate drift. The right answer for a permanent rollout. |
| **Parameter Store** | Central storage for the agent config JSON |

Required on the instance role for SSM itself: `AmazonSSMManagedInstanceCore`.

Private subnets with no NAT need VPC interface endpoints for `ssm`,
`ssmmessages`, `ec2messages`, and `monitoring` (CloudWatch).

Read: https://docs.aws.amazon.com/prescriptive-guidance/latest/implementing-logging-monitoring-cloudwatch/install-cloudwatch-systems-manager.html

---

## 8. Cost model

Two components. The second is the one nobody budgets for.

1. **Custom metrics** — billed per metric per month. One metric per instance
   for a memory-only config.
2. **`PutMetricData` API requests** — billed per 1,000 requests.
   - 60s interval: ~43,800 requests/instance/month
   - 300s interval: ~8,760 requests/instance/month

At 60s, request cost typically **exceeds** the metric cost. Right-sizing
analysis does not need per-minute resolution; 300s is the sensible production
setting and cuts that component ~5x.

Levers: longer interval, fewer metrics, `drop_original_metrics` when
aggregating, and not collecting logs you will not read.

Always check current rates for your region — they vary and change.

---

## 9. Gotchas checklist

- [ ] Agent installed but never configured/started → zero metrics, green ticket
- [ ] Config in Parameter Store under a name not matching `AmazonCloudWatch-*` → AccessDenied, visible only in agent log
- [ ] `append_dimensions` omitted → publishes `host` dimension → Compute Optimizer blind
- [ ] Extra dimensions added → metric multiplication + Compute Optimizer blind
- [ ] Wizard defaults used → 15-20 metrics/instance instead of 1
- [ ] New instance profile attached → silently strips the workload's existing permissions
- [ ] `CloudWatchFullAccess` assumed sufficient → no `ssm:GetParameter`
- [ ] EKS add-on assumed to cover node right-sizing → wrong namespace and dimensions entirely
- [ ] Private subnet without VPC endpoints → SSM shows instance as not Managed
- [ ] Windows metric name guessed rather than read from the metrics reference

---

## 10. Verification commands

Run these yourself. Do not accept SSM command status as proof.

    # Agent process state and which config it loaded
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status

    # Does the metric exist with the right identity?
    aws cloudwatch list-metrics \
      --namespace CWAgent \
      --metric-name mem_used_percent \
      --dimensions Name=InstanceId,Value=<i-xxx>
    # Empty result = not collecting, or wrong dimensions. Both are failures.

    # Are datapoints actually arriving?
    aws cloudwatch get-metric-statistics \
      --namespace CWAgent --metric-name mem_used_percent \
      --dimensions Name=InstanceId,Value=<i-xxx> \
      --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
      --end-time   $(date -u +%Y-%m-%dT%H:%M:%SZ) \
      --period 300 --statistics Average

    # Sanity: does it match reality on the host?
    free -m

    # Where errors actually surface
    tail -100 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log

Failure signatures:
- `running` + empty `list-metrics` → IAM (`PutMetricData` denied) or wrong namespace
- `stopped` → configure/start step never ran
- metric exists but dimension is `host` → `append_dimensions` missing

---

## 11. Link index

**Core**
- Agent config file schema — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Agent-Configuration-File-Details.html
- Metrics collected by the agent (per-OS names) — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/metrics-collected-by-CloudWatch-agent.html
- Config examples — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/create-cloudwatch-agent-configuration-file-examples.html
- Install via Systems Manager — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/installing-cloudwatch-agent-ssm.html
- IAM roles for the agent — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/create-iam-roles-for-cloudwatch-agent.html
- CloudWatchAgentServerPolicy — https://docs.aws.amazon.com/aws-managed-policy/latest/reference/CloudWatchAgentServerPolicy.html
- Metrics concepts (namespace/dimension model) — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_concepts.html
- Troubleshooting the agent — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/troubleshooting-CloudWatch-Agent.html

**Right-sizing**
- Compute Optimizer EC2 metrics — https://docs.aws.amazon.com/compute-optimizer/latest/ug/ec2-metrics-analyzed.html
- Metrics analyzed — https://docs.aws.amazon.com/compute-optimizer/latest/ug/metrics.html

**Fleet / multi-account (phase 2)**
- Prescriptive Guidance: install via SSM — https://docs.aws.amazon.com/prescriptive-guidance/latest/implementing-logging-monitoring-cloudwatch/install-cloudwatch-systems-manager.html
- Prescriptive Guidance: managing config files — https://docs.aws.amazon.com/prescriptive-guidance/latest/implementing-logging-monitoring-cloudwatch/create-store-cloudwatch-configurations.html

**EKS (adjacent, not this task)**
- CloudWatch Observability EKS add-on — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html
- Container Insights enhanced observability metrics — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-metrics-enhanced-EKS.html

**Ansible / AWX**
- `community.aws.ssm_parameter` — https://docs.ansible.com/projects/ansible/latest/collections/community/aws/ssm_parameter_module.html
- `amazon.aws.aws_ssm` connection plugin — https://docs.ansible.com/projects/ansible/latest/collections/amazon/aws/aws_ssm_connection.html
- `community.aws.ssm_inventory_info` — https://docs.ansible.com/projects/ansible/latest/collections/community/aws/ssm_inventory_info_module.html
- No `ssm_send_command` module exists in either collection. Run Command from
  AWX means AWS CLI via `command:`, a boto3 custom module, or the `aws_ssm`
  connection plugin instead.

**Source**
- aws/amazon-cloudwatch-agent (MIT, Telegraf-based) — https://github.com/aws/amazon-cloudwatch-agent
- awsdocs/amazon-cloudwatch-user-guide (docs as greppable markdown) — https://github.com/awsdocs/amazon-cloudwatch-user-guide
