# 1. Does an instance profile actually exist for it?
#    Console-created roles get one automatically; Terraform/CFN ones often don't.
aws iam list-instance-profiles-for-role --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE

# 2. What can it actually do?
aws iam list-attached-role-policies --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE
aws iam list-role-policies --role-name HCLSW_AWS_CLOUDWATCH_FULLACCESS_ROLE

# 3. Is it already on your targets, or is something else?
aws ec2 describe-instances --instance-ids <i-xxx> \
  --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text
