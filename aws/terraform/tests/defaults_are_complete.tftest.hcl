# A customer who sets ONLY the required variables must get every Ringleader feature.
#
# This is the property the module's own README promises — "each one is a single variable away from
# off" — stated as a test rather than as prose. Nothing else guards it: a default flipped to false
# in a later change would plan cleanly, pass every other test here, and be discovered by a customer
# who onboarded and then found the feature they were told they had was not granted.
#
# Nothing here touches AWS: the providers are mocked and only `plan` is ever run.

mock_provider "aws" {}
mock_provider "tls" {}

# The same data overrides the sibling test uses. They are scaffolding, not subject matter: the
# module reads a real TLS chain and real IAM policy documents, none of which a mocked provider can
# produce, and none of which this test is about.
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

override_data {
  target = data.aws_iam_policy_document.trust
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.permissions
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_region.current
  values = { region = "us-east-1" }
}

variables {
  ringleader_issuer_url = "https://oidc-app.example.test"
  org_uid               = "00000000-0000-4000-8000-000000000000"
  region_indexes        = { "us-east-1" = 0 }
}

run "every_capability_is_on_by_default" {
  command = plan

  assert {
    condition     = var.enable_egress_control
    error_message = "enable_egress_control defaults to false: a customer onboarding on the documented happy path would grant nothing for egress policies, and would discover it only when a policy failed to enforce."
  }

  assert {
    condition     = var.enable_workstation_identities
    error_message = "enable_workstation_identities defaults to false: a workstation that declares an identity would fail to start on a default onboarding."
  }

  assert {
    condition     = var.create_network
    error_message = "create_network defaults to false: a customer following the happy path would get no landing pad and no subnet to hand back."
  }

  assert {
    condition     = var.create_gateway_subnet
    error_message = "create_gateway_subnet defaults to false: the DNS/HTTPS proxy would have nowhere to live, and carving its range later means renumbering."
  }

  assert {
    condition     = var.create_governed_subnet
    error_message = "create_governed_subnet defaults to false: an AWS route table attaches per SUBNET, so a gateway steers every box in the one it is given. Without this subnet there is nowhere to put governed workstations that is not shared with ungoverned ones, and steering the shared one takes the egress of every box in it without a policy."
  }
}

# create_nat_gateway is the ONE default that bills, and it is on deliberately: without it a
# workstation created with assignPublicIp:false has no egress at all. Asserted so that turning it
# off is a decision someone makes and defends, not a quiet cost saving that strands private boxes.
run "the_one_default_that_costs_money_is_on_deliberately" {
  command = plan

  assert {
    condition     = var.create_nat_gateway
    error_message = "create_nat_gateway defaults to false. It bills hourly plus $0.045/GB, so turning it off is tempting -- but a workstation with assignPublicIp:false then has no egress at all and never converges. If this is being changed on purpose, change this assertion and say why in the same commit."
  }

  assert {
    condition     = length(var.ssh_source_ranges) == 0
    error_message = "ssh_source_ranges has a non-empty default. Opening TCP 22 is not a decision this module may make for an operator: 0.0.0.0/0 exposes every workstation, and any narrower guess locks them out of boxes that come up healthy and unreachable."
  }
}
