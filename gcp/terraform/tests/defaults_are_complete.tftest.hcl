# A customer who sets ONLY the required variables must get every Ringleader feature.
#
# This is the property the module's own README promises — "each one is a single variable away from
# off" — stated as a test rather than as prose. Nothing else guards it: a default flipped to false
# in a later change would plan cleanly, pass every other test here, and be discovered by a customer
# who onboarded and then found the feature they were told they had was not granted.
#
# It asserts the DEFAULTS, so it sets nothing but the values a customer cannot avoid: the two that
# carry the trust, the project, and the range. Adding a variable below would defeat the test.
#
# Nothing here touches GCP: the provider is mocked and only `plan` is ever run.

mock_provider "google" {}

variables {
  project_id            = "ringleader-example"
  ringleader_issuer_url = "https://oidc-app.example.test"
  org_uid               = "00000000-0000-4000-8000-000000000000"
  network_cidr          = "10.80.0.0/16"
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
    error_message = "create_network defaults to false: a customer following the happy path would get no landing pad and no subnetwork to hand back."
  }

  assert {
    condition     = var.create_gateway_subnet
    error_message = "create_gateway_subnet defaults to false: the DNS/HTTPS proxy would have nowhere to live, and carving its range later means renumbering."
  }

  assert {
    condition     = var.allow_internal_traffic
    error_message = "allow_internal_traffic defaults to false: a custom-mode VPC has no firewall rules and GCP denies ingress, so two workstations could not reach each other at all -- which is a real posture, but not one to arrive at by accident."
  }
}

# The two things that are deliberately NOT on, asserted so that staying off is a RECORDED DECISION
# rather than drift. Both would be bugs to "fix" by flipping the default.
run "the_two_deliberate_exceptions_stay_off" {
  command = plan

  assert {
    condition     = var.create_governed_subnet == false
    error_message = "create_governed_subnet is on by default on GCP. It should not be: a gateway's steering route here is scoped by NETWORK TAG, so a box is governed by carrying the tag and an untagged neighbour on the same subnet is untouched. A governed subnet buys nothing the tag has not already bought, and offering one teaches the subnet-scoped model that is wrong on this cloud. AWS and Azure default it ON because a route table attaches per subnet there."
  }

  assert {
    condition     = length(var.ssh_source_ranges) == 0
    error_message = "ssh_source_ranges has a non-empty default. Opening TCP 22 is not a decision this module may make for an operator: 0.0.0.0/0 exposes every workstation, and any narrower guess locks them out of boxes that come up healthy and unreachable."
  }
}
