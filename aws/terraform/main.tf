# Ringleader AWS onboarding module (OIDC federation, keyless).
#
# Creates, in one of your AWS accounts:
#   - an IAM OIDC identity provider trusting Ringleader's per-org issuer,
#   - an IAM role Ringleader assumes via sts:AssumeRoleWithWebIdentity, whose trust
#     policy pins BOTH the audience AND the subject to your org, and whose permissions
#     policy grants only the EC2 actions the workstation lifecycle needs (plus the SSM
#     public-parameter read that resolves an AMI at launch), and
#   - optionally, a VPC + public subnet + internet gateway + security group landing pad.
#
# Keyless throughout: no IAM user, no access key. Revoke by removing the OIDC provider
# (or the role) and Ringleader can no longer mint into your account. This module declares
# NO provider block so it can be referenced from another repository; see
# examples/standalone for a ready-to-apply root configuration.

locals {
  # The org-specific issuer Ringleader signs for you. Both pins below derive from it:
  #   iss = <issuer>                    (the OIDC provider Url)
  #   sub = org:<org_uid>               (the trust policy's :sub condition)
  #   aud = <iss>/aws                   (the OIDC client id AND the trust policy's :aud condition)
  issuer = "${var.ringleader_issuer_url}/org/${var.org_uid}"

  # The IAM condition-key prefix is the provider Url with the scheme stripped, e.g.
  # oidc-app.ringleader.dev/org/<org-id>. AWS forms "<prefix>:aud" / "<prefix>:sub".
  oidc_condition_prefix = replace(local.issuer, "https://", "")

  audience = "${local.issuer}/aws"
  subject  = "org:${var.org_uid}"

  # A region condition is applied only when allowed_regions is non-empty.
  region_condition = length(var.allowed_regions) > 0
}

# 1. The federation trust: an IAM OIDC identity provider for Ringleader's per-org issuer.
#
# The thumbprint is read from the issuer's live TLS chain -- the last certificate the server
# presents, which is the top-most CA in that chain. AWS no longer verifies it for an IdP served
# from a well-known public CA (Ringleader's issuer is), but the API still requires the field, so
# we compute it rather than hardcode a value that rots.
data "tls_certificate" "issuer" {
  url = var.ringleader_issuer_url
}

resource "aws_iam_openid_connect_provider" "ringleader" {
  url             = local.issuer
  client_id_list  = [local.audience]
  thumbprint_list = [data.tls_certificate.issuer.certificates[length(data.tls_certificate.issuer.certificates) - 1].sha1_fingerprint]

  tags = merge(var.tags, { "ringleader.dev/managed" = "onboarding" })
}

# 2. The role Ringleader assumes. Its trust policy admits ONLY an AssumeRoleWithWebIdentity
#    call presenting a Ringleader-signed assertion whose aud AND sub match your org -- a token
#    minted for any other Ringleader customer carries a different subject and is refused here.
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

  tags = merge(var.tags, { "ringleader.dev/managed" = "onboarding" })
}

# 3. The permissions policy: the EC2 actions the workstation lifecycle drives, and nothing
#    account-broad. Describe* actions do not support resource-level scoping, so they are on "*";
#    the mutating actions are on "*" too (RunInstances touches many resource types) but are
#    optionally bounded to allowed_regions below. SSM read is the public-parameter AMI resolve
#    (spec.image.distribution/version maps to a resolve:ssm:/aws/service/... alias at launch).
data "aws_iam_policy_document" "permissions" {
  statement {
    sid    = "Ec2Describe"
    effect = "Allow"
    actions = [
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
    resources = ["*"]
  }

  statement {
    sid    = "Ec2Lifecycle"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
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
    resources = ["arn:aws:ssm:*::parameter/aws/service/*"]
  }

  # OPTIONAL: pass an instance-profile role to a workstation (runtime identities). Off unless
  # enable_workstation_identities is set; scoped to roles under workstation_identity_path.
  dynamic "statement" {
    for_each = var.enable_workstation_identities ? [1] : []
    content {
      sid       = "PassWorkstationInstanceProfileRole"
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = ["arn:aws:iam::*:role${var.workstation_identity_path}*"]
      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["ec2.amazonaws.com"]
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

# Inbound SSH -- the difference between a workstation that COMES UP and one you can USE.
# Egress is open (a workstation needs it to come up); ingress is 22 from ssh_source_ranges only, and
# nothing at all when that list is empty (reach the workstation privately, or over a public IP whose
# CIDR you list).
resource "aws_security_group" "workstations" {
  count       = var.create_network ? 1 : 0
  name        = "ringleader-workstations"
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

  tags = merge(var.tags, { Name = "ringleader-workstations" })
}

# Optional NAT gateway for purely private (no public IP) workstations.
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
