Subject: HXSA test (491004314536) — IAM prerequisite for CloudWatch Agent memory metrics

Hi team,

Following the approved change request "Install CloudWatch agent for memory
utilisation metrics — HXSA", I need one IAM prerequisite completed before the
agent can be installed. Raising it separately because it is IAM work rather
than the install itself.

BACKGROUND

The change enables memory utilisation collection on 8 standalone EC2 instances
in HXSA test, so right-sizing decisions can be based on memory as well as CPU.
Read-only monitoring — the agent publishes metrics and changes nothing on the
instances.

Two things currently block it:

  1. The 8 target instances have no IAM instance profile attached at all.
  2. As a result, none of them are registered with Systems Manager — the whole
     account returns empty for `ssm describe-instance-information` — so SSM Run
     Command cannot reach them.

WHAT I NEED

We can reuse the existing HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE. Its trust
policy already includes ec2.amazonaws.com, so no trust change is required.
What it lacks is an instance profile and the two managed policies below.

  Step 1 — attach two AWS managed policies to the existing role

    aws iam attach-role-policy \
      --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE \
      --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

    aws iam attach-role-policy \
      --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

  Step 2 — create an instance profile and add the role to it
           (the role currently has none: `list-instance-profiles-for-role`
            returns an empty list)

    aws iam create-instance-profile \
      --instance-profile-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_PROFILE

    aws iam add-role-to-instance-profile \
      --instance-profile-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_PROFILE \
      --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE

  Step 3 — associate the instance profile with the 8 target instances

    for id in i-05c918b7107b2a6e0 i-0571a1ad142aef15b i-0a1199a48c61b870d \
              i-0e19e77dfe3145ab0 i-051a3ed2c30e1e36d i-047cf06c8782f7fdd \
              i-02a0c02b5ec8aa243 i-08599c683d445dc85 ; do
      aws ec2 associate-iam-instance-profile \
        --instance-id "$id" \
        --iam-instance-profile Name=HCLSW_AWS_CLOUDWATCH_FULLACCESS_PROFILE
    done

  Target instances (all us-east-1, account 491004314536):

    i-05c918b7107b2a6e0   duusea1ahxsautlbst1002   t2.small
    i-0571a1ad142aef15b   duusea1ahxsautlbst2002   t2.small
    i-0a1199a48c61b870d   duusea1ahxsautlbst7001   t2.small
    i-0e19e77dfe3145ab0   duusea1ahxsamardbs1001   t2.small
    i-051a3ed2c30e1e36d   duusea1ahxsautlbst3001   t2.large
    i-047cf06c8782f7fdd   duusea1ahxsanetjmp1003   t2.large
    i-02a0c02b5ec8aa243   duusea1ahxsanetjmp1005   t2.large
    i-08599c683d445dc85   duusea1ahxsanetjmp1006   t2.large

  If you would prefer to stage this, start with i-05c918b7107b2a6e0
  (duusea1ahxsautlbst1002) only — that is our canary and I will validate
  against it before we go wider.

  Step 4 — please confirm the SSM Agent is installed and running on these hosts

    systemctl status amazon-ssm-agent
    rpm -q amazon-ssm-agent

  If it is not present, we will need it installed. The instance profile alone
  will not register a host that has no agent.

  Step 5 — permissions for me to run the install

  Please confirm HCLSW_AWS_SAAS_SVC_ADMIN_ROLE has the following, or grant them:

    ssm:PutParameter               (scoped to AmazonCloudWatch-* is fine)
    ssm:GetParameter
    ssm:SendCommand
    ssm:ListCommandInvocations
    ssm:DescribeInstanceInformation

  I do not need any IAM write permissions if you complete steps 1-3.

WHAT THESE POLICIES GRANT

  CloudWatchAgentServerPolicy (AWS managed)
    cloudwatch:PutMetricData
    ec2:DescribeVolumes, ec2:DescribeTags
    CloudWatch Logs write actions
    ssm:GetParameter, restricted to arn:aws:ssm:*:*:parameter/AmazonCloudWatch-*

  AmazonSSMManagedInstanceCore (AWS managed)
    The AWS standard policy for SSM-managed instances.

Neither grants access to application data, S3, databases, or the ability to
modify any resource. Both are AWS-managed, so no custom policy to review.

The instances currently have no instance profile, so this is purely additive —
there are no existing instance permissions to displace.

ALTERNATIVE

If you would rather not extend HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE — it is
also assumable by vpc-flow-logs.amazonaws.com, so it is a shared-purpose role —
a dedicated role is equally fine and avoids coupling the two use cases:

    Role name    HCLSW_AWS_EC2_CWAGENT_SSM_ROLE
    Trust        ec2.amazonaws.com
    Policies     arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
                 arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    Profile      HCLSW_AWS_EC2_CWAGENT_SSM_PROFILE

Please use whichever fits your standards — I have no preference beyond getting
the two policies onto an instance profile on those 8 hosts.

VERIFICATION

Once done, this should return the 8 instances within about 5 minutes:

    aws ssm describe-instance-information \
      --query 'InstanceInformationList[].[InstanceId,PingStatus,AgentVersion]' \
      --output text

I will run this myself and confirm back.

ROLLBACK

    aws ec2 disassociate-iam-instance-profile --association-id <id>
    aws iam detach-role-policy --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE \
      --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
    aws iam detach-role-policy --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

Returns the instances to their current state of having no instance profile.

WHAT THIS DOES NOT TOUCH

  - No EKS clusters or worker nodes. The 16 EKS nodes are explicitly out of
    scope; they already run the CloudWatch agent via the
    amazon-cloudwatch-observability add-on.
  - No changes to the role's existing trust policy.
  - No changes to the role's existing CloudWatchLogsFullAccess attachment or
    to anything currently using this role for VPC flow logs.
  - No instance restarts, resizes, or configuration changes.

Happy to jump on a call if easier.

Thanks,
KM Sumanth
