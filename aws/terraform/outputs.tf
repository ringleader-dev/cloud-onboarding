output "target_role_arn" {
  value       = aws_iam_role.ringleader.arn
  description = "Hand back to Ringleader: the IAM role it assumes (spec.aws.targetRoleArn on the CloudAccount)."
}

output "oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.ringleader.arn
  description = "The IAM OIDC identity provider ARN, for your reference. Ringleader does not need it -- the provider is resolved from the assertion's iss claim."
}

output "account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "The AWS account your workstations run in."
}

output "subnet_id" {
  value       = var.create_network ? aws_subnet.workstations[0].id : null
  description = "Hand back to Ringleader (only when create_network = true; otherwise supply your own): providerConfig.aws.subnetId."
}

output "vpc_cidr" {
  value       = var.create_network ? local.vpc_cidr : null
  description = <<-EOT
    The range this region's VPC took, derived from region_indexes unless you set vpc_cidr.
    Worth recording: it is what the NEXT region has to stay clear of, and what an inter-region
    Transit Gateway will one day have to route.
  EOT
}

output "subnet_cidr" {
  value       = var.create_network ? local.subnet_cidr : null
  description = "The workstations subnet's range, carved out of vpc_cidr."
}

output "security_group_id" {
  value       = var.create_network ? aws_security_group.workstations[0].id : null
  description = <<-EOT
    Hand back to Ringleader (only when create_network = true; otherwise supply your own):
    providerConfig.aws.securityGroupIds, for a workstation that declares NO egress policy.
    Egress out, inbound SSH from ssh_source_ranges.

    A workstation that DOES declare spec.egress wants inbound_only_security_group_id instead --
    beside this group its policy can restrict nothing, and Ringleader refuses to launch it.
  EOT
}

output "inbound_only_security_group_id" {
  value       = var.create_network && var.enable_egress_control ? aws_security_group.workstations_inbound_only[0].id : null
  description = <<-EOT
    Hand back to Ringleader as providerConfig.aws.securityGroupIds for a workstation that
    declares spec.egress. Same inbound rules as security_group_id above and NO egress rules.

    EC2 aggregates the rules of every security group on an interface and a security group
    cannot express a deny, so the group Ringleader compiles a policy into only ever ADDS to
    what the box's other groups permit. Beside this one -- which permits no egress -- the union
    is the policy. Beside security_group_id's allow-all it would be no restriction at all, and
    Ringleader refuses to launch such a workstation rather than report it enforced.

    Null when enable_egress_control = false: with no egress policies to compile there is
    nothing for it to sit beside, and an unused security group still counts against the
    account's 2,500-group cap.
  EOT
}

output "vpc_id" {
  value       = var.create_network ? aws_vpc.workstations[0].id : null
  description = "The VPC this module created. Also the VPC the egress permissions are bounded to, when enable_egress_control is set and egress_vpc_ids is empty."
}

output "gateway_subnet_id" {
  value       = var.create_network && var.create_gateway_subnet ? aws_subnet.gateway[0].id : null
  description = "Subnet reserved for the future DNS / HTTPS proxy VM (only when create_gateway_subnet = true). Public and in the workstations AZ -- both cost decisions; see the variable's description."
}

output "gateway_subnet_cidr" {
  value       = var.create_network && var.create_gateway_subnet ? local.gateway_subnet_cidr : null
  description = "The gateway subnet's range. This is what an egress allowlist names to let workstations reach the proxy, so it is worth recording."
}

output "governed_subnet_id" {
  value       = var.create_network && var.create_governed_subnet ? aws_subnet.governed[0].id : null
  description = "Subnet for the workstations a gateway governs (only when create_governed_subnet = true). Hand it back as providerConfig.aws.subnetId on the workstations that carry an egress policy -- placing a box in it is what makes it gateway-governed. It has no route table on purpose; see the variable's description."
}

output "governed_subnet_cidr" {
  value       = var.create_network && var.create_governed_subnet ? local.governed_subnet_cidr : null
  description = "The governed subnet's range. Worth recording: it is the source range the gateway keys its policies on."
}

output "private_route_table_id" {
  value       = var.create_network && var.create_nat_gateway ? aws_route_table.private[0].id : null
  description = "Route table sending 0.0.0.0/0 to the NAT gateway. Associate any subnet that should reach the internet without a public IP with it."
}

# --- Audit: read these back and confirm they say what you expect ------------------------------
#
# None of these goes back to Ringleader. They exist so the security properties of this module
# are something you can verify after applying rather than take on trust from a diff.

output "issuer_url" {
  value       = local.issuer
  description = "The per-org issuer this account now trusts. Confirm it matches the value Ringleader gave you, byte for byte."
}

output "trusted_subject" {
  value       = local.subject
  description = <<-EOT
    The one subject this role's trust policy admits. Confirm it is your org's uid and nothing
    else: this string, matched with StringEquals, is the entire boundary between your AWS
    account and every other Ringleader customer.
  EOT
}

output "actions_granted" {
  description = "Every action the role holds, for audit. Read from the same lists the policy is built from, so it cannot overstate or understate what was granted."
  value = concat(
    local.describe_actions,
    local.lifecycle_actions,
    ["ssm:GetParameter / ssm:GetParameters -- AWS's public image-alias parameters only"],
    var.enable_workstation_identities ? ["iam:PassRole -- roles under ${var.workstation_identity_path}, to ec2.amazonaws.com only"] : [],
    var.enable_egress_control ? concat(
      local.egress_group_actions,
      local.egress_route_actions,
      local.egress_describe_actions,
      ["ec2:ModifyNetworkInterfaceAttribute"],
    ) : [],
  )
}

output "egress_scope" {
  description = "How the egress-control permissions are bounded. \"region only\" means they reach every security group in the region, which is what you get by bringing your own VPC and not naming it in egress_vpc_ids."
  value = (
    !var.enable_egress_control ? "not granted" :
    length(local.egress_vpc_ids) > 0 ? "VPCs: ${join(", ", local.egress_vpc_ids)}" :
    length(var.allowed_regions) > 0 ? "region only: ${join(", ", var.allowed_regions)}" :
    "UNBOUNDED -- set egress_vpc_ids, or allowed_regions, or both"
  )
}

output "handoff" {
  description = <<-EOT
    Everything to hand back to Ringleader, in one place. TWO security-group ids, and which one
    a workstation gets is the difference between an enforced egress policy and a workstation
    that will not start -- see the two outputs above. TWO subnet ids for the same reason: a
    workstation that carries a policy goes in governed_subnet_id, every other one in subnet_id.
  EOT
  value = {
    target_role_arn                = aws_iam_role.ringleader.arn
    account_id                     = data.aws_caller_identity.current.account_id
    subnet_id                      = var.create_network ? aws_subnet.workstations[0].id : null
    governed_subnet_id             = var.create_network && var.create_governed_subnet ? aws_subnet.governed[0].id : null
    security_group_id              = var.create_network ? aws_security_group.workstations[0].id : null
    inbound_only_security_group_id = var.create_network && var.enable_egress_control ? aws_security_group.workstations_inbound_only[0].id : null
  }
}
