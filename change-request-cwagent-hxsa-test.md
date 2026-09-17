# Change Request — Install CloudWatch Agent for Memory Utilization Metrics (HXSA Test Environment)

> Pilot / proof-of-concept only. This ticket covers the **HXSA test environment**.
> Rollout to remaining AWS accounts is a separate change, raised only after this pilot is validated.
>
> **Fill the `<...>` placeholders before submitting.** They are listed in "Pre-submission checklist" at the end.

---

## 1. Ticket header

| Field | Value |
|---|---|
| **Title** | Install and configure Amazon CloudWatch Agent for memory utilization metrics — HXSA test environment |
| **Change type** | Normal change (pilot) |
| **Category** | Monitoring / Observability |
| **Risk** | Low |
| **Impact** | Low — no change to running workloads or application behaviour |
| **Priority** | `<P3 / Standard>` |
| **Requested by** | `<name>` |
| **Assignment group** | `<Cloud Platform / Infrastructure team>` |
| **AWS account** | `<HXSA test account ID / alias>` |
| **Region(s)** | `<e.g. us-east-1>` |
| **Target instances** | `<N>` EC2 instances — see Appendix A |
| **Proposed window** | `<date/time, TZ>` (no outage required; can be done in hours) |
| **Duration** | ~`<30–60>` minutes for install; 7–14 days of metric collection before evaluation |

---

## 2. Business justification

EC2 instances are currently monitored only for CPU utilization via default CloudWatch metrics. CPU data alone is insufficient for accurate right-sizing: an instance can look underutilized on CPU while being fully utilized on memory, and downsizing it on CPU evidence alone would cause a production incident.

The CloudWatch Agent publishes memory utilization alongside the existing CPU metrics, giving a complete utilization profile per instance. That data enables:

- **Accurate right-sizing recommendations** — memory metrics are a prerequisite for AWS Compute Optimizer (and most third-party right-sizing tooling) to make memory-aware recommendations instead of CPU-only ones.
- **Elimination of over-provisioned EC2 instances** and reduction of unnecessary compute cost.
- **Data-driven infrastructure optimization decisions** rather than assumption-based sizing.

This is a **read-only monitoring activity**. The agent collects and publishes metrics to CloudWatch. It makes no change to instance configuration, application configuration, or application behaviour. **No customer environments are impacted** — this change is confined to the HXSA test environment.

---

## 3. Scope

### In scope
- Install the Amazon CloudWatch Agent on the `<N>` EC2 instances listed in Appendix A (HXSA test environment only).
- Apply a **memory-metrics-only** agent configuration (see Section 5).
- Attach the IAM permissions the agent requires to publish metrics (see Section 6).
- Validate that metrics land in CloudWatch and are consumable for right-sizing.

### Out of scope
- All other AWS accounts and environments (production, customer-facing, other test/dev accounts).
- Log collection / CloudWatch Logs agent configuration.
- Disk, network, swap, or process-level metrics.
- Creating alarms, dashboards, or any automated action on the new metrics.
- Any resize, stop, start, or reboot of instances as a result of this change.

---

## 4. What is being installed

- **Software:** Amazon CloudWatch Agent (`amazon-cloudwatch-agent`), AWS-published and AWS-maintained.
- **Install method:** AWS Systems Manager Distributor package `AmazonCloudWatchAgent`, deployed via the `AWS-ConfigureAWSPackage` SSM document. No manual RPM/MSI handling, no SSH/RDP to instances required.
- **Version:** `latest` at time of install — record the resolved version in the ticket work notes.
- **Runtime footprint:** a metrics-only configuration is lightweight (single background process, tens of MB of RSS, negligible CPU). Actual footprint will be measured during validation and recorded in the ticket (see Test 6).
- **Reboot required:** **No.** Install and start are online operations.

---

## 5. Agent configuration

Only the memory metric is collected. Configuration is stored centrally in SSM Parameter Store so every instance receives an identical, version-controlled config.

**SSM parameter name:** `/hxsa/test/cloudwatch-agent/config-linux` (and `.../config-windows` if Windows hosts are in scope)

**Linux config** (repo: `config/amazon-cloudwatch-agent-linux.json`):

```json
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent",
    "debug": false
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "mem": {
        "measurement": [
          { "name": "mem_used_percent", "unit": "Percent" }
        ],
        "metrics_collection_interval": 60
      }
    }
  }
}
```

**Windows config** (repo: `config/amazon-cloudwatch-agent-windows.json`) collects the equivalent counter `Memory % Committed Bytes In Use`.

Configuration notes:

- **One metric per instance.** `mem_used_percent` (Linux) / `Memory % Committed Bytes In Use` (Windows), namespace `CWAgent`.
- **`InstanceId` as the only dimension** — deliberate. AWS Compute Optimizer only consumes memory metrics published to the `CWAgent` namespace under these exact metric names with the `InstanceId` dimension. Adding `ImageId`/`InstanceType` dimensions would multiply the metric count and cost without adding right-sizing value.
- **60-second collection interval** for the pilot, to give good resolution while we validate. For a wider rollout we should consider 300 seconds: right-sizing analysis does not need per-minute granularity, and it cuts `PutMetricData` API cost roughly 5x. This is a recommendation to confirm during the pilot review, not part of this change.
- The agent runs as the unprivileged `cwagent` user on Linux (agent default).

---

## 6. Prerequisites

| # | Prerequisite | Notes |
|---|---|---|
| 1 | SSM Agent installed and instances show **Managed** in Systems Manager Fleet Manager | Pre-installed on current Amazon Linux, Ubuntu, and Windows AMIs |
| 2 | Instance profile has `AmazonSSMManagedInstanceCore` | Required for SSM-based install |
| 3 | Instance profile has `CloudWatchAgentServerPolicy` (AWS managed) | Grants `cloudwatch:PutMetricData`, `ssm:GetParameter` for the agent config, and EC2 describe calls the agent uses for dimensions |
| 4 | Network path to SSM, EC2 Messages, SSM Messages, and CloudWatch monitoring endpoints | Via NAT/IGW, or VPC interface endpoints for private subnets |
| 5 | Agent config JSON uploaded to SSM Parameter Store | Source of truth: this repo, `config/` |

**Permission delta introduced by this change:** `CloudWatchAgentServerPolicy` only. It is an AWS-managed, write-only-to-CloudWatch policy — it grants no read access to application data, no access to S3 or databases, and no ability to modify any resource. If the instance profiles already carry it, this change adds **no** new permissions.

---

## 7. Implementation plan

Run against a **single canary instance first**, verify, then the remaining instances.

1. **Pre-checks** — confirm target instances are SSM-Managed; capture current instance profile policies; snapshot current CloudWatch metric list for the instances (baseline: CPU only).
2. **Publish config** — write the agent config JSON to SSM Parameter Store:
   ```
   aws ssm put-parameter \
     --name "/hxsa/test/cloudwatch-agent/config-linux" \
     --type String \
     --value file://config/amazon-cloudwatch-agent-linux.json \
     --overwrite
   ```
3. **Attach IAM policy** (only if not already present) — attach `CloudWatchAgentServerPolicy` to the instances' IAM role(s).
4. **Install the agent on the canary** — SSM Run Command, document `AWS-ConfigureAWSPackage`:
   `action=Install`, `name=AmazonCloudWatchAgent`, `version=latest`.
5. **Start the agent with the config on the canary** — SSM Run Command, document `AmazonCloudWatch-ManageAgent`:
   `action=configure`, `mode=ec2`, `optionalConfigurationSource=ssm`,
   `optionalConfigurationLocation=/hxsa/test/cloudwatch-agent/config-linux`, `optionalRestart=yes`.
6. **Validate the canary** — run Tests 1–6 in Section 8. Do not proceed until they pass.
7. **Roll out to remaining instances** — repeat steps 4–5 targeting the remaining instances (SSM tag-based targeting, rate-controlled: `<e.g. 25% concurrency, 10% error threshold>`).
8. **Validate the fleet** — Tests 1–4 across all target instances; record results in the ticket.
9. **Soak** — leave running for 7–14 days to accumulate the data window right-sizing analysis needs. Note: AWS Compute Optimizer needs a minimum observation window before it will emit memory-aware recommendations.
10. **Close-out** — record agent version, per-instance footprint, actual metric count, and measured cost in the ticket work notes; raise the follow-on change for the wider account rollout.

---

## 8. Validation / test plan

| # | Test | Method | Pass criteria |
|---|---|---|---|
| 1 | Agent installed | `AWS-ConfigureAWSPackage` command output in SSM | Command status `Success` on every target |
| 2 | Agent running | `amazon-cloudwatch-agent-ctl -a status` (Linux) / service status (Windows) via Run Command | `status: running`, correct config hash |
| 3 | Metric published | `aws cloudwatch list-metrics --namespace CWAgent --metric-name mem_used_percent --dimensions Name=InstanceId,Value=<id>` | Metric exists for every target instance |
| 4 | Datapoints flowing & sane | `aws cloudwatch get-metric-statistics` over the last hour | Continuous datapoints at the configured interval; values in 0–100 and consistent with `free -m` / Task Manager on the host |
| 5 | Dimensions correct for right-sizing | Inspect the metric's dimensions | `InstanceId` only — no extra dimensions |
| 6 | No workload impact | Compare agent host CPU/memory footprint and application health checks before vs. after | No measurable change to application latency/error rate; agent footprint within expectations |
| 7 | Cost as forecast | CloudWatch usage metrics / Cost Explorer after 7 days | Within the Section 9 estimate |

---

## 9. Cost impact

Two cost components, both small:

- **Custom metrics:** 1 metric per instance × `<N>` instances. CloudWatch custom metrics are billed per metric per month (first 10,000 metrics at the standard rate).
- **`PutMetricData` API requests:** billed per 1,000 requests. At a 60-second interval this is ~43,800 requests per instance per month; at 300 seconds, ~8,760.

**Estimate for the pilot:** on the order of **well under USD 1 per instance per month**, i.e. roughly `<N × $1>` per month upper bound for this environment.

Confirm the exact figures against the CloudWatch pricing page for `<region>` before submitting — rates vary by region and change over time. This cost is expected to be dwarfed by the savings from the right-sizing decisions it enables; quantifying that is the point of the pilot.

---

## 10. Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Agent consumes noticeable host resources | Low | Low | Metrics-only config (no logs, no process metrics); canary-first; footprint measured in Test 6 |
| Agent install disrupts a running application | Very low | Low | Install is a package add + background service start; no reboot; no application file or config is touched; canary-first; test environment only |
| Unexpected CloudWatch cost | Low | Low | Single metric per instance; dimension count deliberately minimised; cost verified at day 7 (Test 7) |
| IAM permission over-grant | Low | Low | Only the AWS-managed `CloudWatchAgentServerPolicy`; write-only to CloudWatch; no data-plane access |
| Agent fails to start / no metrics | Low | Low | Detected by Tests 1–4 before rollout proceeds; backout in Section 11 |
| Sensitive data exposure | Very low | Low | Only a single numeric utilization percentage is published. No logs, no process names, no command lines, no application data leave the instance |

**Security note:** the configuration collects one aggregate memory percentage per host. It does not enable log collection, process-level collection, or anything that could capture application or customer data.

---

## 11. Backout plan

Backout is fast, online, and complete — no reboot, no data loss, no application restart.

1. **Stop the agent** — SSM Run Command, `AmazonCloudWatch-ManageAgent` with `action=stop`, or
   `amazon-cloudwatch-agent-ctl -a stop`. Metric publication ceases immediately.
2. **Uninstall the agent** (if full removal is required) — SSM Run Command, `AWS-ConfigureAWSPackage` with
   `action=Uninstall`, `name=AmazonCloudWatchAgent`.
3. **Detach `CloudWatchAgentServerPolicy`** from the instance role(s) if it was added by this change.
4. **Delete the SSM parameter** holding the agent config, if no longer needed.

Already-published metrics remain in CloudWatch until they age out per the standard retention schedule; they are harmless and incur no ongoing cost. **Backout target: under 15 minutes.**

---

## 12. Appendix A — target instances

| # | Instance ID | Name / tag | OS | Instance type | Owner |
|---|---|---|---|---|---|
| 1 | `<i-...>` (canary) | `<name>` | `<Amazon Linux 2023>` | `<t3.large>` | `<team>` |
| 2 | `<i-...>` | | | | |
| 3 | `<i-...>` | | | | |

---

## 13. Pre-submission checklist

- [ ] HXSA test AWS account ID / alias and region filled in
- [ ] Appendix A completed with the actual instance list; canary chosen
- [ ] Confirmed which targets are Linux vs. Windows (drives which config is used)
- [ ] Confirmed whether instance profiles already carry `AmazonSSMManagedInstanceCore` and `CloudWatchAgentServerPolicy` (changes the IAM section, and possibly who has to approve)
- [ ] Confirmed instances are SSM-Managed (if not, that is a prerequisite ticket of its own)
- [ ] Cost figures checked against current CloudWatch pricing for the target region
- [ ] Change window, requester, and assignment group filled in
- [ ] Ticket format mapped to the fields your ITSM tool actually requires
