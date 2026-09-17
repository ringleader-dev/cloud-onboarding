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
    condition     = var.enable_artifact_storage
    error_message = "enable_artifact_storage defaults to false: a namespace that declared a Storage object naming a bucket here would be refused, and the customer's transcripts would keep landing in Ringleader's own bucket after they had been told otherwise."
  }

  assert {
    condition     = var.allow_internal_traffic
    error_message = "allow_internal_traffic defaults to false: a custom-mode VPC has no firewall rules and GCP denies ingress, so two workstations could not reach each other at all -- which is a real posture, but not one to arrive at by accident."
  }
}

# The things that are deliberately NOT on, asserted so that staying off is a RECORDED DECISION
# rather than drift. Every one would be a bug to "fix" by flipping the default.
run "the_deliberate_exceptions_stay_off" {
  command = plan

  assert {
    condition     = var.create_governed_subnet == false
    error_message = "create_governed_subnet is on by default on GCP. It should not be: a gateway's steering route here is scoped by NETWORK TAG, so a box is governed by carrying the tag and an untagged neighbour on the same subnet is untouched. A governed subnet buys nothing the tag has not already bought, and offering one teaches the subnet-scoped model that is wrong on this cloud. AWS and Azure default it ON because a route table attaches per subnet there."
  }

  assert {
    condition     = var.artifact_storage_bucket == ""
    error_message = "artifact_storage_bucket has a non-empty default, which silently takes the NAMED width. The default width has to be the managed one: it is the only one that works without the customer having created anything, and a default naming a bucket would be a default naming a bucket nobody has."
  }

  assert {
    condition     = length(var.ssh_source_ranges) == 0
    error_message = "ssh_source_ranges has a non-empty default. Opening TCP 22 is not a decision this module may make for an operator: 0.0.0.0/0 exposes every workstation, and any narrower guess locks them out of boxes that come up healthy and unreachable."
  }

  assert {
    condition     = var.gateway_management_source_ranges == null
    error_message = "gateway_management_source_ranges no longer defaults to null. null is what MIRRORS ssh_source_ranges here, the shape secondary_ssh_source_ranges already uses; [] would be a module that silently stops following, and any other default is this module choosing who may reach the egress gateway appliance in someone else's project."
  }

  assert {
    condition     = length(google_compute_firewall.gateway_management) == 0
    error_message = "the inbound-management rule is created when no ssh_source_ranges were named. It FOLLOWS those ranges, so naming none must open nothing here either -- an operator who reaches this VPC privately has decided, and this module does not overrule it."
  }
}

# The mirror, which is what makes this rule land without a second decision. Asserted at the
# RESOURCE, because the promise is not "the variable is null" but "the rule admits the people you
# already named".
run "the_gateway_admission_follows_the_inbound_ssh_ranges" {
  command = plan

  variables {
    ssh_source_ranges = ["203.0.113.0/24"]
  }

  assert {
    condition     = length(google_compute_firewall.gateway_management) == 1
    error_message = "naming ssh_source_ranges created no inbound-management rule. Engineers given 22 would then lose the appliance's sshd, and nothing in this module would have told them."
  }

  assert {
    condition     = google_compute_firewall.gateway_management[0].source_ranges == toset(["203.0.113.0/24"])
    error_message = "the inbound-management rule does not follow ssh_source_ranges: ${join(",", google_compute_firewall.gateway_management[0].source_ranges)}"
  }
}

# ...and closing it stays possible, which is the other half of a default that follows.
run "an_explicit_empty_list_closes_the_admission" {
  command = plan

  variables {
    ssh_source_ranges                = ["203.0.113.0/24"]
    gateway_management_source_ranges = []
  }

  assert {
    condition     = length(google_compute_firewall.gateway_management) == 0
    error_message = "an explicit [] did not close the inbound-management rule, so an operator who does not want their SSH ranges admitted to the appliance has no way to say so."
  }

  assert {
    condition     = length(google_compute_firewall.ssh) == 1
    error_message = "closing the gateway admission also closed the workstations' own TCP 22 rule. They are separate decisions and one must not take the other with it."
  }
}

# The rule the default suppresses, once an operator asks for it. Asserted on the RESOURCE rather
# than on the variable: a rule that exists but targets the workstation tag, or opens some other
# port set, is a rule that reads correctly in the console and admits nothing it promises.
run "the_admission_is_the_rule_it_promises" {
  command = plan

  variables {
    ssh_source_ranges                = ["198.51.100.0/24"]
    gateway_management_source_ranges = ["203.0.113.0/24"]
  }

  assert {
    condition     = length(google_compute_firewall.gateway_management) == 1
    error_message = "an explicit narrower list created no inbound-management rule, so the appliance stays closed to ranges the operator has been told they named."
  }

  assert {
    condition     = google_compute_firewall.gateway_management[0].direction == "INGRESS"
    error_message = "the inbound-management rule is not INGRESS. An egress rule would admit nothing to the appliance, and this rule exists to admit your ranges to it."
  }

  assert {
    condition     = google_compute_firewall.gateway_management[0].target_tags == toset(["ringleader-egress-gateway"])
    error_message = "the inbound-management rule does not target the tag Ringleader puts on the gateway VM: ${join(",", google_compute_firewall.gateway_management[0].target_tags)}"
  }

  assert {
    condition     = google_compute_firewall.gateway_management[0].source_ranges == toset(["203.0.113.0/24"])
    error_message = "an explicit list did not override the ssh_source_ranges mirror: ${join(",", google_compute_firewall.gateway_management[0].source_ranges)}"
  }

  # ONE allow block, asserted before its contents: a second one is a second grant. The check below
  # finds the tcp entry it expects whether or not an `allow { protocol = "udp" }` was appended
  # beside it, and that appended block would hand these CIDRs unrestricted UDP to the appliance.
  assert {
    condition     = length(google_compute_firewall.gateway_management[0].allow) == 1
    error_message = "the inbound-management rule carries more than one allow block, so it grants something besides TCP on the pinned ports -- to CIDRs an operator named for management access, on a landing pad we cannot narrow again."
  }

  assert {
    condition = length([
      for a in google_compute_firewall.gateway_management[0].allow :
      a if a.protocol == "tcp" && a.ports == tolist(["22", "30000-32767"])
    ]) == 1
    error_message = "the inbound-management rule does not open TCP 22 plus the forwarded range. Both halves are needed: a jump host on the appliance answers on 22, a per-box forward needs the high ports where Ringleader cannot write its own rule, and this pad is applied once."
  }
}

# Flow logs are off by default, on purpose: Google bills them per GiB and they grant Ringleader
# nothing, so a customer who never asked for them must not start paying. Asserted on every subnet as
# well as on the variable, so a subnet that stops following the switch is caught too.
run "flow_logs_stay_off_until_asked_for" {
  command = plan

  variables {
    create_governed_subnet = true
    additional_regions     = { "europe-west1" = "10.80.16.0/20" }
  }

  assert {
    condition     = var.create_flow_logs == false
    error_message = "create_flow_logs defaults to true. Google bills flow logs per GiB and they grant Ringleader nothing, so every customer who re-applies would start paying for logs they never asked for."
  }

  assert {
    condition = alltrue([
      length(google_compute_subnetwork.workstations[0].log_config) == 0,
      length(google_compute_subnetwork.gateway[0].log_config) == 0,
      length(google_compute_subnetwork.governed[0].log_config) == 0,
      length(google_compute_subnetwork.additional["europe-west1"].log_config) == 0,
    ])
    error_message = "A subnet carries a log_config on the defaults, so a customer who never set create_flow_logs gets a changed plan and a new bill."
  }
}

# Switched on, every subnet this module creates logs its flows, with the three values
# network-landing-pad.sh passes.
run "flow_logs_cover_every_subnet_the_module_creates" {
  command = plan

  variables {
    create_flow_logs       = true
    create_governed_subnet = true
    additional_regions     = { "europe-west1" = "10.80.16.0/20" }
  }

  assert {
    condition = alltrue([
      for s in [
        google_compute_subnetwork.workstations[0],
        google_compute_subnetwork.gateway[0],
        google_compute_subnetwork.governed[0],
        google_compute_subnetwork.additional["europe-west1"],
        ] : length(s.log_config) == 1 && alltrue([
          for c in s.log_config : c.aggregation_interval == "INTERVAL_5_SEC" && c.flow_sampling == 1.0 && c.metadata == "INCLUDE_ALL_METADATA"
      ])
    ])
    error_message = "A subnet this module creates is not logged with 5-second aggregation, every sampled entry kept and all metadata. Those are the settings Security Command Center's flow log settings check asks for. A subnet left out, or logged with less, fails that check. Values that differ from network-landing-pad.sh mean the two routes record different traffic."
  }
}

# The switch cannot log a subnet this module did not create. It is refused, because a plan that
# creates nothing would let a customer who set it for a compliance scan believe the subnet was logged.
run "flow_logs_without_the_network_are_refused" {
  command = plan

  variables {
    create_network   = false
    create_flow_logs = true
  }

  expect_failures = [google_project_service.compute]
}
