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
  description = "Subnet the egress gateway VM runs in (only when create_gateway_subnet = true). Hand it back as spec.subnet on the EgressGateway -- Ringleader builds no gateway until you do, because a gateway placed in the subnet it steers routes its own egress into itself. NOT governed_subnet_id, which is the workstations'. Public and in the workstations AZ -- both cost decisions; see the variable's description."
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
    var.enable_artifact_storage ? concat(
      local.artifact_storage_bucket_actions,
      local.artifact_storage_managed ? local.artifact_storage_manage_actions : [],
      local.artifact_storage_object_actions,
      ["-- all of the above on ${join(", ", local.artifact_storage_bucket_arns)} and nothing else"],
    ) : [],
  )
}

output "artifact_storage_grant" {
  value       = var.enable_artifact_storage ? (local.artifact_storage_managed ? "managed" : "named") : null
  description = "Hand back to Ringleader: which width you took, as the Storage object's spec.grant. Null when enable_artifact_storage = false, which is also the answer to \"do not declare a Storage at all\"."
}

output "artifact_storage_bucket" {
  value       = var.enable_artifact_storage && !local.artifact_storage_managed ? var.artifact_storage_bucket : null
  description = "Hand back to Ringleader as the Storage object's spec.bucket, on the NAMED width. Null on the managed width, where Ringleader creates the bucket and names it ringleader-... itself -- ask it what it created rather than guessing."
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
    that will not start -- see the two outputs above. THREE subnet ids, and they are not
    interchangeable: a workstation that carries a policy goes in governed_subnet_id, every
    other one in subnet_id, and gateway_subnet_id goes on the EgressGateway itself as
    spec.subnet -- the gateway VM cannot sit in a subnet it steers.
  EOT
  value = {
    target_role_arn                = aws_iam_role.ringleader.arn
    account_id                     = data.aws_caller_identity.current.account_id
    subnet_id                      = var.create_network ? aws_subnet.workstations[0].id : null
    governed_subnet_id             = var.create_network && var.create_governed_subnet ? aws_subnet.governed[0].id : null
    gateway_subnet_id              = var.create_network && var.create_gateway_subnet ? aws_subnet.gateway[0].id : null
    security_group_id              = var.create_network ? aws_security_group.workstations[0].id : null
    inbound_only_security_group_id = var.create_network && var.enable_egress_control ? aws_security_group.workstations_inbound_only[0].id : null
  }
}
