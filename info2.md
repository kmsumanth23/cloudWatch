Subject: HXSA test (491004314536) — IAM prerequisite for CloudWatch Agent, single test VM

Hi team,

Following the approved change request "Install CloudWatch agent for memory utilisation metrics — HXSA", I need one IAM prerequisite before I can begin testing. Raising it separately as it is IAM work rather than the install itself.

This request covers ONE instance only — our test VM. Once the install is validated there, I will raise a follow-up for the remaining hosts.

BACKGROUND

The change enables memory utilisation collection so EC2 right-sizing decisions can account for memory as well as CPU. It is read-only monitoring: the agent publishes metrics to CloudWatch and changes nothing on the instance.

Two things currently block it:

The instance has no IAM instance profile attached.
Consequently it is not registered with Systems Manager, so SSM Run Command cannot reach it. (ssm describe-instance-information currently returns empty for the whole account.)
TARGET INSTANCE

Instance ID   i-051a3ed2c30e1e36d
Name          duusea1ahxsautlbst3001
Type          t2.large
Account       491004314536
Region        us-east-1
WHAT I NEED

We can reuse the existing HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE. Its trust policy already includes ec2.amazonaws.com, so no trust change is required. What it lacks is an instance profile and two managed policies.

Step 1 — attach two AWS managed policies to the existing role

aws iam attach-role-policy \
  --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam attach-role-policy \
  --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
Step 2 — create an instance profile and add the role to it

The role currently has no instance profile — list-instance-profiles-for-role returns an empty list — so one has to be created before the role can be used by an EC2 instance.

aws iam create-instance-profile \
  --instance-profile-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_PROFILE
aws iam add-role-to-instance-profile \
  --instance-profile-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_PROFILE \
  --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE
Step 3 — associate the instance profile with the test VM

aws ec2 associate-iam-instance-profile \
  --instance-id i-051a3ed2c30e1e36d \
  --iam-instance-profile Name=HCLSW_AWS_CLOUDWATCH_FULLACCESS_PROFILE
Step 4 — permissions for me to run the install

Please confirm HCLSW_AWS_SAAS_SVC_ADMIN_ROLE holds the following, or grant them:

ssm:PutParameter               (scoped to AmazonCloudWatch-* is fine)
ssm:GetParameter
ssm:SendCommand
ssm:ListCommandInvocations
ssm:DescribeInstanceInformation
I do not need any IAM write permissions if you complete steps 1-3.

WHAT THESE POLICIES GRANT

CloudWatchAgentServerPolicy (AWS managed) cloudwatch:PutMetricData ec2:DescribeVolumes, ec2:DescribeTags CloudWatch Logs write actions ssm:GetParameter, restricted to arn:aws:ssm:::parameter/AmazonCloudWatch-*

AmazonSSMManagedInstanceCore (AWS managed) The AWS standard policy for SSM-managed instances.

Neither grants access to application data, S3, databases, or the ability to modify any resource. Both are AWS-managed, so there is no custom policy to review.

The instance currently has no instance profile, so this is purely additive — there are no existing instance permissions to displace.

ALTERNATIVE

If you would rather not extend HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE — it is also assumable by vpc-flow-logs.amazonaws.com, so it is a shared-purpose role — a dedicated role is equally acceptable and avoids coupling the two use cases:

Role name    HCLSW_AWS_EC2_CWAGENT_SSM_ROLE
Trust        ec2.amazonaws.com
Policies     arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
             arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
Profile      HCLSW_AWS_EC2_CWAGENT_SSM_PROFILE
Please use whichever fits your standards. I have no preference beyond getting those two policies onto an instance profile attached to that one host.

VERIFICATION

Once done, this should list the instance within about 5 minutes. I will run it and confirm back:

aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,AgentVersion]' \
  --output text
ROLLBACK

aws ec2 disassociate-iam-instance-profile --association-id <id>
aws iam detach-role-policy --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam detach-role-policy --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
Returns the instance to its current state of having no instance profile.

WHAT THIS DOES NOT TOUCH

One instance only. No other EC2 instances are affected.
No EKS clusters or worker nodes. Those are out of scope; they already run the CloudWatch agent via the amazon-cloudwatch-observability add-on.
No change to the role's existing trust policy.
No change to the role's existing CloudWatchLogsFullAccess attachment, or to anything currently using this role for VPC flow logs.
No instance restart, resize, or configuration change.
NEXT STEPS AFTER THIS

Once validated on this VM, I will raise a follow-up request to extend the same instance profile to the remaining hosts, and we will automate the agent setup via Ansible from there.

Happy to jump on a call if easier.

Thanks, KM Sumanth
