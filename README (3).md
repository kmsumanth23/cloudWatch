# CloudWatch Agent Memory Monitoring — Ansible

Drop-in for `aws-v9-automation`. Task files, not a role, matching the repo's
`tasks/` + `include_tasks` convention.

```
cloudwatch-agent.yml                      entry-point playbook, single play
tasks/cloudwatch-agent.yml                all phases
templates/amazon-cloudwatch-agent.json.j2
defaults/cloudwatch.yml
```

Phases inside the task file, in order: preflight, discover, IAM association,
target fact gathering, install, configure, verify.

## Prerequisite — IAM team, not this automation

A role trusting `ec2.amazonaws.com` with `CloudWatchAgentServerPolicy`
attached, and an instance profile containing that role. Creating it needs
`iam:CreateRole`, which the automation's identity does not hold. Set
`cloudwatch_instance_profile_name` to the profile name; the playbook asserts
it is non-empty and stops immediately if not.

## Targeting

Three modes, selected by `cloudwatch_discovery_mode`.

### vsi_vars (default)

Reads `vsi_instances` from the client environment vars file and acts on entries
carrying the opt-in flag:

```yaml
vsi_instances:
  - desc: dev_np_server
    stack: utl
    type: bst
    instance_count: 1
    instance_seq: 1
    cloudwatch_agent: true      # <-- opt this VSI in
    ...
```

Each selected entry is turned into a Name-tag pattern, one per instance in
`instance_count`:

```
*{{ client_code }}{{ stack }}{{ type }}{{ env_seq }}{{ '%03d' % instance_seq }}
```

For `hxsa` / `awsv9m` (`env_seq: 3`) that gives `*hxsautlbst3001`, which matches
`duusea1ahxsautlbst3001`. The prefix is deliberately not derived — the pattern
is anchored on the suffix, so host-naming prefixes do not have to be modelled.
If the convention differs anywhere, set `cloudwatch_vsi_name_patterns`
directly and derivation is skipped.

**Scope is one environment.** The client vars file describes one environment,
so a run covers that environment's VSIs and nothing else. Standalone instances
in this estate span four environments — `env_seq` 1, 2, 3 and 7 — so full
coverage means one run per environment vars file, not one run per account.
That is a feature: it keeps a run inside the blast radius of the vars file that
authorised it.

### tag

Acts on instances carrying an AWS tag (`cloudwatch_target_tag_key` /
`_value`). Self-maintaining for newly launched instances, but crosses
environment boundaries — it will find instances belonging to other vars files.

### explicit

`cloudwatch_target_instances: [i-...]`. Bypasses discovery entirely. Useful for
a single-host first run.

## Run

```bash
ansible-playbook cloudwatch-agent.yml \
  -e cloudwatch_defaults_file={{ default_var_dir }}/cloudwatch.yml

# discovery and reporting only, no changes
ansible-playbook cloudwatch-agent.yml --check --diff
```

## Variables

All in `defaults/cloudwatch.yml`. Nothing is hardcoded in a task file — no
instance IDs, role names, account IDs or regions. Per repo convention,
override in the client environment vars file rather than editing defaults.

`cloudwatch_aws_cli_env` is the credential seam: populate it from the
`sts_assume_role` pattern used elsewhere in this repo. Left empty, the AWS CLI
falls back to whatever the execution environment already has.

## Single play, and what it costs

`add_host` does not affect the current play's host list, so a single play with
tag discovery has to run on the control node and reach targets with
`delegate_to`. Three consequences, all inherent to the pattern rather than to
this implementation:

- **Host work is serial.** Loops run one host at a time. A play across a host
  group runs `forks` hosts in parallel. At 8 hosts and roughly a minute per
  install that is ~8 minutes instead of ~1, and it grows linearly.
- **A failing host aborts the task** rather than failing only that host.
  `cloudwatch_fail_fast: false` collects install failures and surfaces them in
  the post-install assertion instead.
- **Facts must be gathered by explicit delegation**, into `hostvars[ip]`.
  `cloudwatch_agent_os_family_override` forces the value if that is
  unavailable.

If parallelism matters later, the way to keep a single play and get it back is
to make target discovery an inventory concern — an AWX inventory source using
the `aws_ec2` plugin with the same tag filter — and have the play target that
group, with the AWS CLI tasks using `delegate_to: localhost` and
`run_once: true`. That needs the `amazon.aws` collection in the execution
environment and inventory configuration outside the playbook, which is why it
is not the default here.

## The connection override is load-bearing

The play sets `connection: local` so control-node tasks work however the
playbook is invoked. Ansible leaks that into `delegate_to`, so every delegated
task also carries:

```yaml
vars:
  ansible_connection: "{{ cloudwatch_target_connection }}"
```

Without it, verified in this environment: a task with
`delegate_to: <target>` ran `hostname` on the **control node** and returned
rc=0. Every "install the agent on the target" task would have executed locally
and reported success. Do not remove it.

`ansible_user` and key material are not set here — they come from the
execution environment's machine credential, as in the rest of this repo.

## Safety properties

- **Never replaces an instance profile.** An instance can hold exactly one. If
  a target already carries a different profile, the run fails and names the
  instances rather than silently stripping the permissions its workload uses.
  `cloudwatch_replace_existing_profile` overrides, as a deliberate decision.
- **Idempotent.** `dnf`/`apt` skip an installed agent; the config template
  reports changed only on content difference; `fetch-config` runs only when the
  config changed or the agent is not running. A re-run on a healthy host
  changes nothing.
- **Verification queries CloudWatch, not service state.** The run fails unless
  datapoints actually arrive. Both silent failures seen during the pilot — the
  EKS add-on publishing nothing for four days with healthy pods, and an agent
  installed but never started — would pass a service-state check and fail this
  one.
- **Config JSON is validated before install.** The `template` task's `validate`
  parses it with `json.load`; a malformed render never reaches the host.

## Tags

Every task carries `tags: [cw-agent]`, and the include applies the tag to the
whole file, so the automation can be selected or skipped from a larger play:

```bash
ansible-playbook <orchestrator>.yml --tags cw-agent
ansible-playbook <orchestrator>.yml --skip-tags cw-agent
```

Note `--list-tasks` will not enumerate them: `include_tasks` is a dynamic
include, so its contents are not known until runtime. Tag filtering itself
works correctly at runtime — verified both ways.

## Variable precedence

The defaults are loaded with `vars_files`, **not** `include_vars`. This
matters: `include_vars` sits at precedence 18 and would override anything the
orchestrator had already loaded, silently discarding client overrides.
`vars_files` is precedence 14, so the client environment vars file, task vars
and `-e` all still win.

If you move this into an orchestrator that loads vars differently, keep the
defaults below the client vars or the overrides stop working — quietly.

## Validation performed

- `ansible-playbook --syntax-check` — passes.
- All files parse as YAML.
- **Connection leak reproduced and fixed.** With play-level `connection: local`
  and no override, a delegated task executed on the control node (rc=0,
  controller hostname). With the override it correctly attempts SSH. All 9
  delegated tasks carry it.
- **Instance-profile partition tested** against a fixture shaped like real
  `describe-instances` output, including `"profile": null`: absent / correct /
  conflict split correctly and exhaustively, and the conflict guard fires on
  an instance carrying a different profile.
- **Conditional `fetch-config` tested** with parallel register fixtures: skipped
  where the config was unchanged and the agent running, applied where the
  config changed, applied where the agent was stopped.
- **Metric query JSON verified** — valid, with `Period` as an integer.
- No instance IDs, account IDs, role names or hostnames appear in the task
  file, playbook or template.
- **vsi_vars discovery exercised end to end** against a stubbed AWS CLI with a
  realistic `vsi_instances` fixture: one of two entries flagged, correct
  pattern `*hxsautlbst3001` derived, instance resolved, and correctly
  identified as already associated.
- **Preflight assert confirmed** to stop the run when
  `cloudwatch_instance_profile_name` is unset.
- **Tag filtering verified at runtime** — `--tags cw-agent` runs the tasks,
  `--skip-tags cw-agent` runs none.
- Template rendered against `defaults/cloudwatch.yml` and compared to the
  config currently running on `i-051a3ed2c30e1e36d`: **structurally
  identical**. `${aws:InstanceId}` survives rendering as a literal.
- Template rendered against a multi-metric fixture (mem + disk + swap, extra
  dimensions, per-group interval override, debug on): valid JSON, correct
  comma placement, per-group interval honoured, `debug` emitted as a boolean
  rather than a string.

## Not yet exercised

- **No end-to-end run against live hosts.** Only the canary was configured by
  hand. The first real run is the test.
- **Debian/Ubuntu package URL is unverified** — taken from AWS docs. Only the
  RHEL-family path is confirmed (AlmaLinux 8.10).
- **`cloudwatch_agent_disable_gpg_check` defaults to `true`**, mirroring the
  manual `rpm -U`. Tighten once AWS's signing key is present on the hosts.
- **`verify.yml` assumes GNU `date`** on the control node for the time window.
- **OS spread across the remaining 7 hosts is unknown.** If any are not
  RHEL-family, `install.yml` asserts and stops rather than guessing.
