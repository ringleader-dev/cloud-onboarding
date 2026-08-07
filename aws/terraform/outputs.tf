output "target_role_arn" {
  value       = aws_iam_role.ringleader.arn
  description = "Hand back to Ringleader: the IAM role it assumes (spec.aws.targetRoleArn on the CloudAccount)."
}

output "oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.ringleader.arn
  description = "The IAM OIDC identity provider ARN (for your reference; Ringleader does not need it -- the provider is resolved from the assertion's iss claim)."
}

output "account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "The AWS account your workstations run in."
}

output "subnet_id" {
  value       = var.create_network ? aws_subnet.workstations[0].id : null
  description = "Hand back to Ringleader (only when create_network = true; otherwise supply your own): providerConfig.aws.subnetId."
}

output "security_group_id" {
  value       = var.create_network ? aws_security_group.workstations[0].id : null
  description = "Hand back to Ringleader (only when create_network = true; otherwise supply your own): providerConfig.aws.securityGroupIds."
}

output "handoff" {
  description = "Everything to hand back to Ringleader, in one place."
  value = {
    target_role_arn   = aws_iam_role.ringleader.arn
    account_id        = data.aws_caller_identity.current.account_id
    subnet_id         = var.create_network ? aws_subnet.workstations[0].id : null
    security_group_id = var.create_network ? aws_security_group.workstations[0].id : null
  }
}

data "aws_caller_identity" "current" {}
