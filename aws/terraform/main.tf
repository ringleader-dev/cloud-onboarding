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

  lifecycle_actions = [
    "ec2:RunInstances",
    "ec2:TerminateInstances",
    "ec2:StartInstances",
    "ec2:StopInstances",
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
  # names hostnames rather than address ranges. On AWS a route table is per SUBNET, so
  # per-policy steering needs a subnet per policy and a route table to go with it -- which is
  # why subnet and route-table writes are here and are not in the base grant.
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
# ranges. Give every region a distinct vpc_cidr from the first apply; see the variable's
# description and aws/README.md for a suggested plan. Renumbering later means re-onboarding.

data "aws_availability_zones" "available" {
  count = var.create_network ? 1 : 0
  state = "available"
}

resource "aws_vpc" "workstations" {
  count                = var.create_network ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "ringleader-workstations" })
}

resource "aws_internet_gateway" "workstations" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.workstations[0].id
  tags   = merge(var.tags, { Name = "ringleader-workstations" })
}

resource "aws_subnet" "workstations" {
  count                   = var.create_network ? 1 : 0
  vpc_id                  = aws_vpc.workstations[0].id
  cidr_block              = var.subnet_cidr
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

  dynamic "ingress" {
    for_each = length(var.ssh_source_ranges) > 0 ? [1] : []
    content {
      description = "SSH from the ranges your engineers connect from."
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_source_ranges
    }
  }

  # A second SSH port, opened to the same ranges as 22 unless you say otherwise.
  #
  # Some Ringleader workstation types run their own SSH daemon on a secondary port inside the
  # instance, while the instance's own sshd keeps 22, and `rl shell` dials that port for such
  # a workstation. Others never use it, and for those this rule is harmless -- which is why it
  # follows ssh_source_ranges rather than making you find out which kind you are running. Set
  # secondary_ssh_source_ranges = [] to close it.
  dynamic "ingress" {
    for_each = length(local.secondary_ssh_ranges) > 0 ? [1] : []
    content {
      description = "Secondary SSH port, for workstation types that run their own SSH daemon."
      from_port   = local.secondary_ssh_port
      to_port     = local.secondary_ssh_port
      protocol    = "tcp"
      cidr_blocks = local.secondary_ssh_ranges
    }
  }

  tags = merge(var.tags, { Name = "ringleader-workstations" })
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
  cidr_block              = var.gateway_subnet_cidr
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
