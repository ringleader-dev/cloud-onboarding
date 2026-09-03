# Ringleader AWS onboarding module (OIDC federation, keyless).
#
# Creates, in one of your AWS accounts:
#   - an IAM OIDC identity provider trusting Ringleader's per-org issuer,
#   - an IAM role Ringleader assumes via sts:AssumeRoleWithWebIdentity, whose trust
#     policy pins both the audience and the subject to your org, and whose permissions
#     policy grants only the EC2 actions the workstation lifecycle needs (plus the SSM
#     public-parameter read that resolves an AMI at launch), and
#   - optionally, a VPC + public subnet + internet gateway + security group landing pad.
#
# All on by default, and each one a variable you can set to false: the landing pad, a NAT
# gateway and private route table, a private subnet for the DNS / HTTPS proxy VM that
# hostname-level egress control will use, egress control itself (letting Ringleader manage
# the security groups that restrict where workstations may connect), and instance profiles
# for workstations that run as an IAM role.
#
# The defaults grant what Ringleader needs for the features available today, so turning one
# on later does not mean a second onboarding pass. Only the NAT gateway costs money; see
# variables.tf for what each one does and the README for how to switch any of them off.
#
# Keyless throughout: no IAM user, no access key. Revoke by removing the OIDC provider
# (or the role) and Ringleader can no longer mint into your account. This module declares
# no provider block so it can be referenced from another repository; see
# examples/standalone for a ready-to-apply root configuration.

locals {
  # The org-specific issuer Ringleader signs for you. Both pins below derive from it:
  #   iss = <issuer>       (the OIDC provider Url)
  #   sub = org:<org_uid>  (the trust policy's :sub condition)
  #   aud = <iss>/aws      (the OIDC client id and the trust policy's :aud condition)
  issuer = "${var.ringleader_issuer_url}/org/${var.org_uid}"

  # The IAM condition-key prefix is the provider Url with the scheme stripped, e.g.
  # oidc-app.ringleader.dev/org/<org-id>. AWS forms "<prefix>:aud" / "<prefix>:sub".
  oidc_condition_prefix = replace(local.issuer, "https://", "")

  audience = "${local.issuer}/aws"
  subject  = "org:${var.org_uid}"

  # A region condition is applied only when allowed_regions is non-empty.
  region_condition = length(var.allowed_regions) > 0

  # The action lists, declared once and used by both the policy below and the
  # actions_granted output. What we grant and what we tell you we granted cannot drift.
  describe_actions = [
    "ec2:DescribeInstances",
    "ec2:DescribeInstanceStatus",
    "ec2:DescribeInstanceTypes",
    "ec2:DescribeImages",
    "ec2:DescribeSubnets",
    "ec2:DescribeSecurityGroups",
    "ec2:DescribeVpcs",
    "ec2:DescribeVolumes",
    "ec2:DescribeNetworkInterfaces",
    "ec2:DescribeTags",
    "ec2:DescribeAvailabilityZones",
  ]

  # ModifyInstanceAttribute is what a machine RESIZE issues. EC2 refuses it on anything but a
  # stopped instance, so Ringleader stops the workstation, resizes it and starts it again; without
  # this action that cycle ends in UnauthorizedOperation and the workstation rests stopped. It sits
  # with the other mutating lifecycle actions and takes their region bound.
  #
  # The same API also sets user-data, and IAM has no condition key to tell the two apart. Ringleader
  # does not use that form: a workstation never does, and an egress gateway's user-data carries only
  # its agent bootstrap, written once at create -- its egress policy arrives over the agent's own
  # config stream, not through this API. The role already holds RunInstances, which can launch an
  # instance with any user-data at all, so the action widens nothing this grant did not permit.
  lifecycle_actions = [
    "ec2:RunInstances",
    "ec2:TerminateInstances",
    "ec2:StartInstances",
    "ec2:StopInstances",
    "ec2:ModifyInstanceAttribute",
    "ec2:CreateTags",
    "ec2:DeleteTags",
  ]

  # Egress control: creating and maintaining the security groups that carry a workstation's
  # egress allowlist, and moving a workstation's NIC between them. Granted only when
  # enable_egress_control is set.
  #
  # The ingress pair is here for the DNS / HTTPS proxy VM, whose own group has to admit
  # workstation traffic. If you want the strict minimum for IP-level egress alone and no
  # proxy, drop those two -- the actions_granted output will show what you kept.
  egress_group_actions = [
    "ec2:CreateSecurityGroup",
    "ec2:DeleteSecurityGroup",
    "ec2:AuthorizeSecurityGroupEgress",
    "ec2:RevokeSecurityGroupEgress",
    "ec2:AuthorizeSecurityGroupIngress",
    "ec2:RevokeSecurityGroupIngress",
  ]

  # Steering: what makes a workstation's traffic ARRIVE at the DNS / HTTPS proxy when a policy
  # names hostnames rather than address ranges. On AWS a route table is per SUBNET, so steering
  # is per subnet rather than per workstation -- which is why subnet and route-table writes are
  # here and are not in the base grant. It is NOT a subnet per policy: the gateway tells
  # policies apart by SOURCE ADDRESS, so one subnet and one route table serve a whole governed
  # fleet on many different policies. What per-subnet steering does force is placement, which is
  # what create_governed_subnet below exists to give you.
  #
  # ec2:ModifyNetworkInterfaceAttribute (granted separately below) does double duty: it moves a
  # running workstation between security groups, and it clears the source/destination check on
  # the proxy's own interface, without which AWS silently drops every packet it forwards.
  egress_route_actions = [
    "ec2:CreateRouteTable",
    "ec2:DeleteRouteTable",
    "ec2:CreateRoute",
    "ec2:ReplaceRoute",
    "ec2:DeleteRoute",
    "ec2:AssociateRouteTable",
    "ec2:DisassociateRouteTable",
    "ec2:CreateSubnet",
    "ec2:DeleteSubnet",
  ]

  # The two reads the reconciler and its sweep need, in their own list because they cannot go
  # in the statement above. EC2's Describe actions support no resource-level permissions, so
  # `ec2:Vpc` is simply absent from the request context and a condition on it can never match:
  # granting them there reads correctly and denies at runtime. AWS documents this in as many
  # words -- "the Describe actions do not support resource-level permissions, so you must
  # specify them in a separate statement without conditions". The region condition is fine
  # (`aws:RequestedRegion` is global and present on every request); only the VPC one is not.
  egress_describe_actions = [
    "ec2:DescribeSecurityGroupRules",
    "ec2:DescribeRouteTables",
  ]

  # The VPCs the egress permissions are bounded to. When this module created the network we
  # use that VPC; otherwise you name your own in egress_vpc_ids. Empty means the permissions
  # are bounded by region alone -- see the variable's description.
  egress_vpc_ids = length(var.egress_vpc_ids) > 0 ? var.egress_vpc_ids : (
    var.create_network ? [aws_vpc.workstations[0].id] : []
  )

  # ec2:Vpc takes a VPC ARN. The region is left as a wildcard (matched with StringLike) so
  # this works whatever region the VPC is in without a second data source; the account is
  # pinned, and allowed_regions still bounds the region separately.
  egress_vpc_arns = [
    for id in local.egress_vpc_ids :
    "arn:${data.aws_partition.current.partition}:ec2:*:${data.aws_caller_identity.current.account_id}:vpc/${id}"
  ]

  # The secondary SSH port (see the security group below). Fixed by Ringleader, so it is a
  # constant here rather than a variable: you never have to know the number, and it cannot
  # drift from the port Ringleader actually dials. A wrong value would be an ingress rule
  # that exists, reads correctly in the console, and admits nothing.
  secondary_ssh_port = 2222

  # Unset mirrors ssh_source_ranges: if you opened 22 to your engineers you almost certainly
  # want 2222 open to the same people. An explicit [] closes the port.
  secondary_ssh_ranges = var.secondary_ssh_source_ranges == null ? var.ssh_source_ranges : var.secondary_ssh_source_ranges

  # The inbound rules BOTH workstation security groups carry, written once. The two groups below
  # are deliberately identical on ingress and differ only in egress, and a second copy of this
  # list is exactly how they would stop being identical -- leaving a workstation you can reach
  # or one you cannot, depending on which id you handed back.
  workstation_ingress = concat(
    length(var.ssh_source_ranges) > 0 ? [{
      description = "SSH from the ranges your engineers connect from."
      port        = 22
      cidr_blocks = var.ssh_source_ranges
    }] : [],
    length(local.secondary_ssh_ranges) > 0 ? [{
      description = "Secondary SSH port, for workstation types that run their own SSH daemon."
      port        = local.secondary_ssh_port
      cidr_blocks = local.secondary_ssh_ranges
    }] : [],
  )
}

# 1. The federation trust: an IAM OIDC identity provider for Ringleader's per-org issuer.
#
# The thumbprint is read from the issuer's live TLS chain -- the last certificate the server
# presents, which is the top-most CA in that chain. AWS no longer verifies it for an IdP
# served from a well-known public CA (Ringleader's issuer is), but the API still requires the
# field, so we compute it rather than hardcode a value that rots.
data "tls_certificate" "issuer" {
  url = var.ringleader_issuer_url
}

# The partition every ARN below is built in, read from the caller rather than assumed: `aws`
# in commercial regions, `aws-us-gov` in GovCloud, `aws-cn` in China. A hardcoded "aws"
# produces policies that are syntactically valid and match nothing outside the commercial
# partition -- an AccessDenied at box-create that points nowhere near its cause.
data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "ringleader" {
  url             = local.issuer
  client_id_list  = [local.audience]
  thumbprint_list = [data.tls_certificate.issuer.certificates[length(data.tls_certificate.issuer.certificates) - 1].sha1_fingerprint]

  tags = merge(var.tags, { "ringleader.dev/managed" = "onboarding" })
}

# 2. The role Ringleader assumes. Its trust policy admits only an AssumeRoleWithWebIdentity
#    call presenting a Ringleader-signed assertion whose aud and sub match your org -- a
#    token minted for any other Ringleader customer carries a different subject and is
#    refused here.
#
# The `sub` condition is the whole security property, so it is worth understanding before
# editing. Every Ringleader customer's assertion is signed by the same issuer service; what
# distinguishes your org from every other one is the `sub` claim, and the only thing that
# makes AWS check it is the StringEquals condition below.
#
# A trust policy that drops that condition -- or matches it with StringLike and a wildcard --
# will accept another Ringleader customer's assertion and hand them credentials in your
# account. Use StringEquals on a literal subject, always. To admit a second org, apply the
# module again rather than generalising the match. This is spelled out because the industry
# copy-paste for web-identity trust policies is exactly the wildcard form.
data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "RingleaderOrgFederation"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.ringleader.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_condition_prefix}:aud"
      values   = [local.audience]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_condition_prefix}:sub"
      values   = [local.subject]
    }
  }
}

resource "aws_iam_role" "ringleader" {
  name                 = var.role_name
  description          = "Least-privilege role Ringleader federates into (AssumeRoleWithWebIdentity) to manage workstation EC2 instances."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = var.max_session_duration

  tags = merge(var.tags, { "ringleader.dev/managed" = "onboarding" })
}

# 3. The permissions policy: the EC2 actions the workstation lifecycle drives, and nothing
#    account-broad. Describe* actions do not support resource-level scoping, so they are on
#    "*"; the mutating actions are on "*" too (RunInstances touches many resource types) but
#    are optionally bounded to allowed_regions. The SSM read is the public-parameter AMI
#    resolve (spec.image.distribution/version maps to a resolve:ssm:/aws/service/... alias).
#
# Scoped by region rather than by resource tag, deliberately. Tag-scoping RunInstances
# correctly requires conditions across every resource type a launch touches -- instance,
# volume, network-interface, security-group, subnet, image -- plus a matching
# ec2:CreateAction condition on CreateTags. It is easy to get subtly wrong, and the failure
# is an opaque UnauthorizedOperation at box-create that looks like a Ringleader bug. A region
# bound is simple, readable in the console, and already confines the role to where you run
# workstations. Tighten further if your platform team wants to; this is the floor, not a
# ceiling.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "Ec2Describe"
    effect    = "Allow"
    actions   = local.describe_actions
    resources = ["*"]
  }

  statement {
    sid       = "Ec2Lifecycle"
    effect    = "Allow"
    actions   = local.lifecycle_actions
    resources = ["*"]

    dynamic "condition" {
      for_each = local.region_condition ? [1] : []
      content {
        test     = "StringEquals"
        variable = "aws:RequestedRegion"
        values   = var.allowed_regions
      }
    }
  }

  statement {
    sid    = "SsmPublicParameterRead"
    effect = "Allow"
    actions = [
      "ssm:GetParameters",
      "ssm:GetParameter",
    ]
    # The AWS-owned public AMI parameters the alias table resolves
    # (/aws/service/canonical/..., /aws/service/debian/..., /aws/service/ami-amazon-linux-latest/...).
    resources = ["arn:${data.aws_partition.current.partition}:ssm:*::parameter/aws/service/*"]
  }

  # Pass an instance-profile role to a workstation (runtime identities). On by default, and
  # scoped to roles under workstation_identity_path -- with no roles there it reaches nothing.
  dynamic "statement" {
    for_each = var.enable_workstation_identities ? [1] : []
    content {
      sid       = "PassWorkstationInstanceProfileRole"
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = ["arn:${data.aws_partition.current.partition}:iam::*:role${var.workstation_identity_path}*"]
      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["ec2.amazonaws.com"]
      }
    }
  }

  # Egress control. Ringleader compiles each distinct egress policy into one
  # security group and attaches it to the workstations that carry that policy, so a fleet
  # sharing a policy costs one group rather than one per instance -- which matters, because
  # AWS caps an ENI at 5 security groups and a region at 2,500 groups.
  #
  # Bounded to the VPCs in egress_vpc_ids where one is known (see that variable), so these
  # permissions cannot touch a security group elsewhere in the account. With no VPC known,
  # the region condition is the only bound and the module says so at apply time.
  dynamic "statement" {
    for_each = var.enable_egress_control ? [1] : []
    content {
      sid       = "EgressSecurityGroups"
      effect    = "Allow"
      actions   = concat(local.egress_group_actions, local.egress_route_actions)
      resources = ["*"]

      dynamic "condition" {
        for_each = local.region_condition ? [1] : []
        content {
          test     = "StringEquals"
          variable = "aws:RequestedRegion"
          values   = var.allowed_regions
        }
      }

      dynamic "condition" {
        for_each = length(local.egress_vpc_arns) > 0 ? [1] : []
        content {
          test     = "StringLike"
          variable = "ec2:Vpc"
          values   = local.egress_vpc_arns
        }
      }
    }
  }

  # The reads, deliberately unbounded by VPC -- see egress_describe_actions above. They are
  # still gated on enable_egress_control and still bounded by region, so they widen nothing a
  # customer did not ask for; the base grant's own Describe statement is left untouched.
  dynamic "statement" {
    for_each = var.enable_egress_control ? [1] : []
    content {
      sid       = "EgressDescribe"
      effect    = "Allow"
      actions   = local.egress_describe_actions
      resources = ["*"]

      dynamic "condition" {
        for_each = local.region_condition ? [1] : []
        content {
          test     = "StringEquals"
          variable = "aws:RequestedRegion"
          values   = var.allowed_regions
        }
      }
    }
  }

  # The other half of egress control: moving a workstation's NIC onto the security group its
  # policy compiled to. This is what makes a policy change take effect on a running
  # workstation rather than only on the next one created.
  #
  # ModifyNetworkInterfaceAttribute authorizes against both the interface and the groups
  # being set, so the ec2:Vpc condition bounds it to your workstations VPC on both counts.
  dynamic "statement" {
    for_each = var.enable_egress_control ? [1] : []
    content {
      sid       = "EgressAttachToInstances"
      effect    = "Allow"
      actions   = ["ec2:ModifyNetworkInterfaceAttribute"]
      resources = ["*"]

      dynamic "condition" {
        for_each = local.region_condition ? [1] : []
        content {
          test     = "StringEquals"
          variable = "aws:RequestedRegion"
          values   = var.allowed_regions
        }
      }

      dynamic "condition" {
        for_each = length(local.egress_vpc_arns) > 0 ? [1] : []
        content {
          test     = "StringLike"
          variable = "ec2:Vpc"
          values   = local.egress_vpc_arns
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "ringleader" {
  name   = "ringleader-workstations"
  role   = aws_iam_role.ringleader.id
  policy = data.aws_iam_policy_document.permissions.json
}

# --- Optional network landing pad (public subnet; egress + optional inbound SSH) -----------
#
# One region's worth. An AWS VPC is regional, so a second region means a second VPC and,
# eventually, an inter-region Transit Gateway to join them -- which cannot route overlapping
# ranges. Two regions applied on one range can never be peered, and the only remedy is to
# renumber and re-onboard, so the allocation has to be right from the FIRST apply.
#
# Hence the ranges are DERIVED rather than documented. region_indexes maps each region to the
# /16 its landing pad takes, and the module reads the index for the region it is actually
# applying in -- so two regions given one map cannot take one range whatever order they are
# applied in. Every subnet then comes out of that /16, so there is no second variable to keep
# in step and no way to move the VPC and leave a subnet behind.
#
# Every default below reproduces the literal this module shipped before the derivation, so an
# existing single-region landing pad plans as a no-op: see aws/README.md for the table.

data "aws_availability_zones" "available" {
  count = var.create_network ? 1 : 0
  state = "available"
}

# The region the CALLER configured on its provider. This module declares no provider block, so
# this is the only way it can learn where it is being applied -- which is what binds an index
# in region_indexes to a region rather than to whichever tfvars file was reached for.
data "aws_region" "current" {}

locals {
  # Read ONCE, deliberately: three call sites reading it separately would be three deprecation
  # surfaces to chase the next time this attribute is renamed. `region` is the v6 spelling; `name`
  # and `id` are both deprecated there, which is why versions.tf floors the provider at >= 6.0.
  region = data.aws_region.current.region

  # An unlisted region falls back to index 0 so the expressions below stay evaluable; the
  # precondition on the VPC is what actually refuses it, with a message that names the region.
  region_index = try(var.region_indexes[local.region], 0)

  region_index_known = contains(keys(var.region_indexes), local.region)

  # 10.(60 + index).0.0/16. Index 0 is 10.60.0.0/16, this module's historical default.
  vpc_cidr = var.vpc_cidr != null ? var.vpc_cidr : cidrsubnet("10.0.0.0/8", 8, 60 + local.region_index)

  # The three subnets, carved out of whichever /16 the VPC took. The offsets reproduce the
  # literals these variables used to default to: the first /20, the 15th /20 immediately below
  # the gateway range, and the 241st /24 at the top.
  subnet_cidr          = var.subnet_cidr != null ? var.subnet_cidr : cidrsubnet(local.vpc_cidr, 4, 0)
  governed_subnet_cidr = var.governed_subnet_cidr != null ? var.governed_subnet_cidr : cidrsubnet(local.vpc_cidr, 4, 14)
  gateway_subnet_cidr  = var.gateway_subnet_cidr != null ? var.gateway_subnet_cidr : cidrsubnet(local.vpc_cidr, 8, 240)
}

resource "aws_vpc" "workstations" {
  count                = var.create_network ? 1 : 0
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "ringleader-workstations" })

  # The allocation has to be DECLARED, because Terraform cannot discover it. There is no signal
  # in a fresh state that says "this is the second region", so a module that accepted silence
  # would hand the second apply the first one's range and only find out at the peering months
  # later, when renumbering means re-onboarding. Refusing silence is what makes the collision
  # impossible instead of merely discouraged -- and the right moment to insist is the FIRST
  # apply, which is the only one where the answer is still free.
  #
  # Both preconditions are skipped entirely when create_network is false: a customer who brings
  # their own network never carves a range here and has nothing to declare.
  lifecycle {
    precondition {
      condition     = length(var.region_indexes) > 0 || var.vpc_cidr != null
      error_message = "region_indexes is empty, so this landing pad cannot know whether ${local.region} is your first region or your second. Name every region you onboard -- region_indexes = { \"${local.region}\" = 0 } keeps this one on 10.60.0.0/16, the range it has always had -- and give the next region index 1. Or set vpc_cidr to allocate the ranges yourself."
    }

    precondition {
      condition     = local.region_index_known || var.vpc_cidr != null
      error_message = "region_indexes does not name ${local.region}, the region this provider is configured for, so this apply would take index 0's range a second time. Add \"${local.region}\" with an index no other region uses, or set vpc_cidr to allocate this region's range yourself."
    }
  }
}

resource "aws_internet_gateway" "workstations" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.workstations[0].id
  tags   = merge(var.tags, { Name = "ringleader-workstations" })
}

resource "aws_subnet" "workstations" {
  count                   = var.create_network ? 1 : 0
  vpc_id                  = aws_vpc.workstations[0].id
  cidr_block              = local.subnet_cidr
  availability_zone       = coalesce(var.availability_zone, data.aws_availability_zones.available[0].names[0])
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "ringleader-workstations" })
}

resource "aws_route_table" "workstations" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.workstations[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.workstations[0].id
  }

  tags = merge(var.tags, { Name = "ringleader-workstations" })
}

resource "aws_route_table_association" "workstations" {
  count          = var.create_network ? 1 : 0
  subnet_id      = aws_subnet.workstations[0].id
  route_table_id = aws_route_table.workstations[0].id
}

# Inbound SSH -- the difference between a workstation that comes up and one you can use.
# Egress is open (a workstation needs it to come up); ingress is 22 from ssh_source_ranges,
# plus the opt-in secondary port, and nothing at all while both lists are empty (reach the
# workstation privately, or over a public IP whose CIDR you list).
#
# This is the group for a workstation that declares NO egress policy, and the only one until
# egress control shipped. A workstation that declares one wants the inbound-only group below
# instead; the comment there is the whole reason there are two.
resource "aws_security_group" "workstations" {
  count = var.create_network ? 1 : 0
  name  = "ringleader-workstations"
  # Don't restate the ingress list here as it grows: `description` is ForceNew, so editing it
  # replaces the group and changes the id you handed back to Ringleader
  # (providerConfig.aws.securityGroupIds). The rules below are the authority on what is open.
  description = "Ringleader workstations: egress out; inbound SSH only from ssh_source_ranges."
  vpc_id      = aws_vpc.workstations[0].id

  egress {
    description = "All egress (a workstation reaching the Ringleader control plane)."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 22 from ssh_source_ranges, plus a second SSH port opened to the same ranges unless you say
  # otherwise. Some Ringleader workstation types run their own SSH daemon on that second port
  # inside the instance, while the instance's own sshd keeps 22, and `rl shell` dials it for
  # such a workstation. Others never use it, and for those the rule is harmless -- which is why
  # it follows ssh_source_ranges rather than making you find out which kind you are running.
  # Set secondary_ssh_source_ranges = [] to close it.
  dynamic "ingress" {
    for_each = local.workstation_ingress
    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  tags = merge(var.tags, { Name = "ringleader-workstations" })
}

# The same group for a workstation that DECLARES AN EGRESS POLICY: identical inbound rules, and
# no egress rule whatsoever.
#
# # Why a second group rather than an edit to the one above
#
# A security group is ALLOW-ONLY -- it cannot express a deny -- and EC2 AGGREGATES the rules of
# every group attached to a network interface. So the group Ringleader compiles a policy into
# can only ever ADD to what the box's other groups already permit. Beside the landing pad above
# it adds to `0.0.0.0/0` and narrows nothing at all; beside this one it IS the union, which is
# what makes the policy the box's actual limit.
#
# Both groups have to exist. Take the egress rule off the landing pad and every workstation
# WITHOUT a policy loses the egress it needs to come up at all.
#
# # An empty egress rule set is the mechanism, not an oversight
#
# AWS gives every new security group an allow-all egress rule; Terraform is authoritative over
# the rules it declares and removes the ones it does not, so declaring no `egress` block leaves
# this group with zero egress rules -- and a security group with no egress rules permits no
# egress. Adding an egress rule here to "fix" it re-breaks every policy-bearing workstation in
# the VPC. (The CloudFormation path cannot express this: see aws/cloudformation/.)
#
# Ringleader REFUSES to launch a policy-bearing workstation whose other security groups permit
# egress, naming the offending group, rather than report a policy it cannot deliver. So handing
# back the wrong id is a workstation that does not start -- loud, and the reason the two ids are
# labelled separately in outputs.tf.
resource "aws_security_group" "workstations_inbound_only" {
  count = var.create_network && var.enable_egress_control ? 1 : 0
  name  = "ringleader-workstations-inbound-only"
  # `description` is ForceNew here too -- see the group above.
  description = "Ringleader workstations with a declared egress policy: inbound SSH only, no egress."
  vpc_id      = aws_vpc.workstations[0].id

  # Deliberately no `egress` block. See above.

  dynamic "ingress" {
    for_each = local.workstation_ingress
    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  tags = merge(var.tags, { Name = "ringleader-workstations-inbound-only" })
}

# NAT gateway, for anything on this VPC without a public IP: a workstation created with
# providerConfig.aws.assignPublicIp: false, and the gateway subnet below.
#
# It lives in the public subnet (that is where a NAT gateway has to be) and is reached
# through the private route table, which is what actually gives a private instance egress.
# On by default, and the one default here that costs money -- it bills per hour plus $0.045
# per GB processed, whether or not anything uses it. Set it false if every workstation gets a
# public IP (the default), which the internet gateway already serves for free.
#
# Worth knowing for later: once the DNS / HTTPS proxy ships, a fleet of private workstations
# can reach the internet through it instead, and the proxy meters nothing. At 10 TB/month
# that is a saving of roughly $420 against managed NAT -- so for a fleet already behind NAT,
# egress control arrives cheaper than the status quo rather than as new spend.
resource "aws_eip" "nat" {
  count  = var.create_network && var.create_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "ringleader-nat" })
}

resource "aws_nat_gateway" "workstations" {
  count         = var.create_network && var.create_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.workstations[0].id
  tags          = merge(var.tags, { Name = "ringleader-workstations" })
  depends_on    = [aws_internet_gateway.workstations]
}

# The private route table. Nothing used the NAT gateway before this existed, so a "private"
# workstation had no egress at all; associate any subnet that should reach the internet
# without a public IP with this table.
resource "aws_route_table" "private" {
  count  = var.create_network && var.create_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.workstations[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.workstations[0].id
  }

  tags = merge(var.tags, { Name = "ringleader-private" })
}

# A home for the future DNS / HTTPS proxy VM -- created empty, and on by default.
#
# Ringleader's egress control can point workstations at a proxy that reads the hostname off
# each connection and allows or refuses it. That VM is not built yet, but where it will live
# is worth settling now: giving it a subnet of its own means the security-group rules that
# permit workstation -> proxy traffic can name one stable range instead of one instance's
# address, and carving the range now avoids renumbering later. AWS does not bill for a subnet.
#
# It is PUBLIC, routed through the internet gateway, and that is the cost decision rather
# than a convenience. The proxy carries a fleet's whole outbound volume; internet ingress is
# free on every cloud, and a proxy with its own public address pays nothing for it. Sending
# the same traffic through a managed NAT gateway instead meters it at $0.045/GB, which at 10
# TB/month is several hundred dollars for bytes the proxy could have taken for free.
#
# It also sits in the same availability zone as the workstations subnet: AWS charges cross-AZ
# traffic in BOTH directions, so a misplaced proxy costs more than the instance running it.
resource "aws_subnet" "gateway" {
  count                   = var.create_network && var.create_gateway_subnet ? 1 : 0
  vpc_id                  = aws_vpc.workstations[0].id
  cidr_block              = local.gateway_subnet_cidr
  availability_zone       = coalesce(var.availability_zone, data.aws_availability_zones.available[0].names[0])
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "ringleader-gateway" })
}

# Its own route table rather than a share of the workstations one. Same routes today, but the
# proxy's subnet is where a per-policy route eventually lands, and splitting it now means that
# change never has to touch the subnet the workstations are on.
resource "aws_route_table" "gateway" {
  count  = var.create_network && var.create_gateway_subnet ? 1 : 0
  vpc_id = aws_vpc.workstations[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.workstations[0].id
  }

  tags = merge(var.tags, { Name = "ringleader-gateway" })
}

resource "aws_route_table_association" "gateway" {
  count          = var.create_network && var.create_gateway_subnet ? 1 : 0
  subnet_id      = aws_subnet.gateway[0].id
  route_table_id = aws_route_table.gateway[0].id
}

# And a home for the WORKSTATIONS that gateway governs -- also empty, also on by default.
#
# A gateway steers a whole subnet and serves only the boxes it holds a policy for, so a steered
# subnet has to hold governed boxes and nothing else. ringleader-workstations above is where
# every workstation in the VPC goes, governed or not; steering that one would take the egress
# of every box in it that has no policy. Hence a second range.
#
# It has NO ROUTE TABLE, and that is the point rather than an omission. Ringleader claims the
# subnet by creating its own table and associating it, and it refuses a subnet that already
# carries one: taking over an existing association needs ec2:ReplaceRouteTableAssociation, which
# is in no grant here, and nothing could put the customer's association back afterwards. So the
# subnet is handed over unclaimed.
#
# Two consequences worth knowing before you put a box in it:
#
#   - Until a gateway steers it, this subnet falls back to the VPC's MAIN route table, which
#     carries only the local route. A workstation in here has no egress at all and will not
#     converge. That is the fail-safe direction -- a governed box egresses through its gateway
#     or not at all -- but the gateway has to exist first.
#   - Once steering lands, 0.0.0.0/0 points at the gateway's interface, which is also the reply
#     path for anything dialling the box from OUTSIDE the VPC. Reach a governed workstation on
#     its private address (VPN / peering / Direct Connect), and create it with
#     providerConfig.aws.assignPublicIp: false -- which is why this subnet, unlike the
#     workstations one, does not hand out public IPs.
resource "aws_subnet" "governed" {
  count                   = var.create_network && var.create_governed_subnet ? 1 : 0
  vpc_id                  = aws_vpc.workstations[0].id
  cidr_block              = local.governed_subnet_cidr
  availability_zone       = coalesce(var.availability_zone, data.aws_availability_zones.available[0].names[0])
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "ringleader-governed" })
}
