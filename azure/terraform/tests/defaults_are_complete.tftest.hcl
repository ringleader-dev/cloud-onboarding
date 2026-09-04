# A customer who sets ONLY the required variables must get every Ringleader feature.
#
# This is the property the module's own README promises — "each one is a single variable away from
# off" — stated as a test rather than as prose. Nothing else guards it: a default flipped to false
# in a later change would plan cleanly, pass every other test here, and only be discovered by a
# customer who onboarded and then found the feature they were told they had was not granted.
#
# It asserts the DEFAULTS, so it deliberately sets nothing but the four values a customer cannot
# avoid: the two that carry the trust, and the two that place the network. Adding a variable to the
# `variables` block below would defeat the test.

# Mocked, as the sibling test is: nothing here touches Azure, only `plan` is ever run, so it needs
# no credentials and creates nothing.
mock_provider "azurerm" {}
mock_provider "azuread" {}

variables {
  ringleader_issuer_url = "https://oidc-app.example.test"
  org_uid               = "00000000-0000-4000-8000-000000000000"
  subscription_id       = "00000000-0000-0000-0000-000000000000"
  resource_group_name   = "rg-defaults-test"
  region_indexes        = { "eastus" = 0 }
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
    error_message = "create_governed_subnet defaults to false on Azure: a gateway steers a whole subnet here, so without it there is nowhere to put governed workstations that is not shared with ungoverned ones."
  }

  assert {
    condition     = var.create_identity
    error_message = "create_identity defaults to false: the first (or only) invocation must mint the identity a customer hands back."
  }
}

# The one capability that is NOT on by default, asserted so that staying off is a DECISION rather
# than drift. Inbound SSH is the single thing a customer must choose, because both answers are
# wrong to guess: a default of 0.0.0.0/0 opens every workstation to the internet, and any narrower
# guess locks them out of boxes that come up healthy and unreachable.
run "inbound_ssh_is_the_one_thing_left_to_the_operator" {
  command = plan

  assert {
    condition     = length(var.ssh_source_ranges) == 0
    error_message = "ssh_source_ranges has a non-empty default. Opening TCP 22 is not a decision this module may make for an operator."
  }
}
