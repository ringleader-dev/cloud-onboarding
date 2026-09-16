# What this file is for: the CIDR allocation is the one thing in this module that cannot be
# fixed after the fact. Two regions on one range can never be peered, and a change that quietly
# renumbers an EXISTING landing pad destroys and recreates its subnets. So both directions are
# pinned here -- that the defaults still produce the exact literals this module shipped before
# the ranges were derived, and that a second region cannot land on the first one's range.
#
# Run it with `terraform test` (Terraform >= 1.7, for mock_provider). Nothing here touches AWS:
# the providers are mocked and only `plan` is ever run, so it needs no credentials and creates
# nothing.

mock_provider "aws" {}
mock_provider "tls" {}

variables {
  ringleader_issuer_url = "https://oidc-app.ringleader.dev"
  org_uid               = "0192f5bf-af83-7178-8d0a-f1c7aea06bde"

  # The allocation every run below starts from; the runs that care replace it.
  region_indexes = {
    "us-east-1" = 0
  }
}

# Everything that is not the subject of these tests, stubbed once. A mocked provider generates
# an EMPTY list for a computed list attribute, which the OIDC thumbprint and the availability
# zone lookup both index into, so they have to be given something to find.
override_data {
  target = data.tls_certificate.issuer
  values = {
    certificates = [{ sha1_fingerprint = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" }]
  }
}

override_data {
  target = data.aws_availability_zones.available[0]
  values = { names = ["a", "b"] }
}

# The IAM documents are mocked to a random string, which the provider rejects as soon as the
# rest of the policy is known enough to validate -- nothing to do with the ranges under test.
override_data {
  target = data.aws_iam_policy_document.trust
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.permissions
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

# The default region for every run below; the runs that care override it.
override_data {
  target = data.aws_region.current
  values = { region = "us-east-1" }
}

# The whole point of the derivation: an operator who has been running this module since before
# it derived anything must see NO change. Every value below is the literal that variable used to
# default to.
run "defaults_reproduce_the_historical_literals" {
  command = plan

  assert {
    condition     = output.vpc_cidr == "10.60.0.0/16"
    error_message = "vpc_cidr moved off the historical default: got ${output.vpc_cidr}"
  }

  assert {
    condition     = output.subnet_cidr == "10.60.0.0/20"
    error_message = "subnet_cidr moved off the historical default: got ${output.subnet_cidr}"
  }

  assert {
    condition     = output.gateway_subnet_cidr == "10.60.240.0/24"
    error_message = "gateway_subnet_cidr moved off the historical default: got ${output.gateway_subnet_cidr}"
  }

  assert {
    condition     = output.governed_subnet_cidr == "10.60.224.0/20"
    error_message = "governed_subnet_cidr moved off the historical default: got ${output.governed_subnet_cidr}"
  }
}

# A landing pad in the second region takes the second /16, and every subnet follows it. This is
# the collision the module exists to prevent: same map, different region, different range.
run "a_second_region_takes_the_next_16" {
  command = plan

  variables {
    region_indexes = {
      "us-east-1" = 0
      "eu-west-1" = 1
    }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "eu-west-1" }
  }

  assert {
    condition     = output.vpc_cidr == "10.61.0.0/16"
    error_message = "second region did not take 10.61.0.0/16: got ${output.vpc_cidr}"
  }

  assert {
    condition     = output.subnet_cidr == "10.61.0.0/20"
    error_message = "subnets did not follow the VPC into the second /16: got ${output.subnet_cidr}"
  }

  assert {
    condition     = output.gateway_subnet_cidr == "10.61.240.0/24"
    error_message = "gateway subnet did not follow the VPC into the second /16: got ${output.gateway_subnet_cidr}"
  }

  assert {
    condition     = output.governed_subnet_cidr == "10.61.224.0/20"
    error_message = "governed subnet did not follow the VPC into the second /16: got ${output.governed_subnet_cidr}"
  }
}

# The map is shared between regions, so the FIRST region's apply must still produce the first
# region's range even though the map now names two.
run "the_first_region_is_unchanged_by_a_second_entry" {
  command = plan

  variables {
    region_indexes = {
      "us-east-1" = 0
      "eu-west-1" = 1
    }
  }

  assert {
    condition     = output.vpc_cidr == "10.60.0.0/16"
    error_message = "adding a second region moved the first one's range to ${output.vpc_cidr}"
  }
}

# Silence is refused, and this is the failure that matters most: an operator who copies a
# tfvars file to a second region and changes nothing else has declared no allocation at all,
# and a module that accepted that would hand them the first region's range without a word.
run "an_undeclared_allocation_is_refused" {
  command = plan

  variables {
    region_indexes = {}
  }

  expect_failures = [aws_vpc.workstations]
}

# ...but a customer who brings their own network carves no range here, so they are never asked
# to declare one.
run "an_undeclared_allocation_is_fine_without_a_landing_pad" {
  command = plan

  variables {
    region_indexes = {}
    create_network = false
  }

  assert {
    condition     = output.subnet_id == null
    error_message = "create_network = false still built a landing pad"
  }
}

# Applying in a region the map does not name is the accident this refuses: it would silently
# take index 0's range a second time.
run "an_unlisted_region_is_refused" {
  command = plan

  variables {
    region_indexes = {
      "us-east-1" = 0
    }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "eu-west-1" }
  }

  expect_failures = [aws_vpc.workstations]
}

# ...unless the operator has taken the allocation over entirely, which is what vpc_cidr means.
run "an_unlisted_region_is_allowed_when_vpc_cidr_is_explicit" {
  command = plan

  variables {
    region_indexes = {
      "us-east-1" = 0
    }
    vpc_cidr = "172.16.0.0/16"
  }

  override_data {
    target = data.aws_region.current
    values = { region = "eu-west-1" }
  }

  assert {
    condition     = output.vpc_cidr == "172.16.0.0/16"
    error_message = "an explicit vpc_cidr was not honoured: got ${output.vpc_cidr}"
  }

  assert {
    condition     = output.governed_subnet_cidr == "172.16.224.0/20"
    error_message = "subnets did not follow an explicit vpc_cidr: got ${output.governed_subnet_cidr}"
  }
}

# Two regions on one index is the exact overlap this variable exists to prevent, so it is
# refused before anything is planned.
run "two_regions_on_one_index_are_refused" {
  command = plan

  variables {
    region_indexes = {
      "us-east-1" = 0
      "eu-west-1" = 0
    }
  }

  expect_failures = [var.region_indexes]
}

run "an_index_outside_the_allocated_block_is_refused" {
  command = plan

  variables {
    region_indexes = {
      "us-east-1" = 10
    }
  }

  expect_failures = [var.region_indexes]
}

# An explicit subnet override still wins over the derivation -- the escape hatch for an operator
# with their own IPAM has to keep working.
run "explicit_subnet_overrides_still_win" {
  command = plan

  variables {
    subnet_cidr          = "10.60.32.0/20"
    gateway_subnet_cidr  = "10.60.250.0/24"
    governed_subnet_cidr = "10.60.208.0/20"
  }

  assert {
    condition     = output.subnet_cidr == "10.60.32.0/20"
    error_message = "an explicit subnet_cidr was not honoured: got ${output.subnet_cidr}"
  }

  assert {
    condition     = output.gateway_subnet_cidr == "10.60.250.0/24"
    error_message = "an explicit gateway_subnet_cidr was not honoured: got ${output.gateway_subnet_cidr}"
  }

  assert {
    condition     = output.governed_subnet_cidr == "10.60.208.0/20"
    error_message = "an explicit governed_subnet_cidr was not honoured: got ${output.governed_subnet_cidr}"
  }
}

# More governed subnets are opt-in. A landing pad that never sets additional_governed_subnets must
# plan exactly what it planned before the variable existed, or an unchanged configuration would
# grow subnets on its next apply.
run "no_additional_governed_subnet_by_default" {
  command = plan

  assert {
    condition     = length(aws_subnet.governed_additional) == 0
    error_message = "additional_governed_subnets created a subnet with the variable left at its default."
  }

  assert {
    condition     = output.governed_subnet_cidr == "10.60.224.0/20"
    error_message = "the default governed subnet moved: got ${output.governed_subnet_cidr}"
  }
}

# Each entry is its own subnet, keyed by its label, and built like the default governed subnet:
# no public IPs, and a name that says which label it came from. The default governed subnet stays
# where it was, so adding entries never renumbers a landing pad.
run "additional_governed_subnets_are_keyed_by_label" {
  command = plan

  variables {
    additional_governed_subnets = {
      team-a = "10.60.208.0/20"
      team-b = "10.60.192.0/20"
    }
  }

  assert {
    condition     = length(aws_subnet.governed_additional) == 2
    error_message = "expected one subnet per additional_governed_subnets entry, got ${length(aws_subnet.governed_additional)}"
  }

  assert {
    condition     = aws_subnet.governed_additional["team-a"].cidr_block == "10.60.208.0/20" && aws_subnet.governed_additional["team-b"].cidr_block == "10.60.192.0/20"
    error_message = "an additional governed subnet did not take the CIDR its entry names."
  }

  assert {
    condition     = aws_subnet.governed_additional["team-a"].tags["Name"] == "ringleader-governed-team-a"
    error_message = "an additional governed subnet is not named after its label: got ${aws_subnet.governed_additional["team-a"].tags["Name"]}"
  }

  assert {
    condition     = !aws_subnet.governed_additional["team-a"].map_public_ip_on_launch
    error_message = "an additional governed subnet hands out public IPs, which the default governed subnet does not."
  }

  assert {
    condition     = output.governed_subnet_cidr == "10.60.224.0/20"
    error_message = "adding additional governed subnets moved the default one: got ${output.governed_subnet_cidr}"
  }

  assert {
    condition     = toset(keys(output.additional_governed_subnet_ids)) == toset(["team-a", "team-b"])
    error_message = "additional_governed_subnet_ids is not keyed by the labels given."
  }
}

# Without a landing pad there is no VPC to carve into, so entries create nothing rather than fail.
run "additional_governed_subnets_need_a_landing_pad" {
  command = plan

  variables {
    create_network              = false
    additional_governed_subnets = { team-a = "10.60.208.0/20" }
  }

  assert {
    condition     = length(aws_subnet.governed_additional) == 0
    error_message = "an additional governed subnet was planned with create_network = false."
  }
}

# A label becomes part of a subnet name and an output key, so it is held to a plain shape, and a
# value that is not a CIDR is refused at plan rather than at the AWS API.
run "an_additional_governed_subnet_label_must_be_plain" {
  command = plan

  variables {
    additional_governed_subnets = { "Team_A" = "10.60.208.0/20" }
  }

  expect_failures = [var.additional_governed_subnets]
}

run "an_additional_governed_subnet_needs_a_cidr" {
  command = plan

  variables {
    additional_governed_subnets = { team-a = "10.60.208.0" }
  }

  expect_failures = [var.additional_governed_subnets]
}
