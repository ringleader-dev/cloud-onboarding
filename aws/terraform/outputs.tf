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

# --- Audit: read these back and confirm they say what you expect ------------------------------
#
# None of the three goes back to Ringleader. They exist so the security property of this module is
# something you can VERIFY after applying, rather than something you take on trust from a diff.

output "issuer_url" {
  value       = local.issuer
  description = "The per-org issuer this account now trusts. Confirm it matches the value Ringleader gave you, byte for byte."
}

output "trusted_subject" {
  value       = local.subject
  description = <<-EOT
    The ONE subject this role's trust policy admits. Confirm it is your org's uid and nothing else:
    this string, matched with StringEquals, is the entire boundary between your AWS account and
    every other Ringleader customer.
  EOT
}

output "actions_granted" {
  description = "Every action the role holds, for audit. Read from the same lists the policy is built from, so it cannot overstate or understate what was granted."
  value = concat(
    local.describe_actions,
    local.lifecycle_actions,
    ["ssm:GetParameter / ssm:GetParameters -- AWS's PUBLIC image-alias parameters only"],
    var.enable_workstation_identities ? ["iam:PassRole -- roles under ${var.workstation_identity_path}, to ec2.amazonaws.com only"] : [],
  )
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
