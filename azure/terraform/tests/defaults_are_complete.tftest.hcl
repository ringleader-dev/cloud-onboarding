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
    condition     = var.enable_artifact_storage
    error_message = "enable_artifact_storage defaults to false: a namespace that declared a Storage object naming a destination here would be refused, and the customer's transcripts would keep landing in Ringleader's own bucket after they had been told otherwise."
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
    condition     = var.artifact_storage_account_name == ""
    error_message = "artifact_storage_account_name has a non-empty default, which silently takes the NAMED width. The default width has to be the managed one: it is the only one that works without the customer having created anything, and a default naming a destination would be a default naming one nobody has."
  }

  assert {
    condition     = length(var.ssh_source_ranges) == 0
    error_message = "ssh_source_ranges has a non-empty default. Opening TCP 22 is not a decision this module may make for an operator."
  }

  assert {
    condition     = var.gateway_management_source_ranges == null
    error_message = "gateway_management_source_ranges no longer defaults to null. null is what MIRRORS ssh_source_ranges, the shape secondary_ssh_source_ranges already uses; [] would be a module that silently stops following, and any other default is this module choosing who may reach the egress gateway in someone else's resource group."
  }

  assert {
    condition     = length(azurerm_network_security_rule.gateway_management) == 0
    error_message = "the gateway-management rule is created when no ssh_source_ranges were named. It FOLLOWS those ranges, so naming none must open nothing here either -- an operator who reaches this VNet privately has decided, and this module does not overrule it."
  }
}

# The mirror, which is what makes the gateway admission land without a second decision. Asserted at
# the RESOURCE, because the promise is not "the variable is null" but "the rule admits the people you
# already named".
run "the_gateway_admission_follows_the_inbound_ssh_ranges" {
  command = plan

  variables {
    ssh_source_ranges = ["203.0.113.0/24"]
  }

  assert {
    condition     = length(azurerm_network_security_rule.gateway_management) == 1
    error_message = "naming ssh_source_ranges created no gateway-management rule. Azure evaluates the gateway subnet's NSG before the one on the gateway VM's NIC, so a customer who opened 22 to their engineers would lose those boxes the moment an egress policy steered one."
  }

  assert {
    condition     = toset(azurerm_network_security_rule.gateway_management[0].source_address_prefixes) == toset(["203.0.113.0/24"])
    error_message = "the gateway-management rule does not follow ssh_source_ranges: ${join(",", azurerm_network_security_rule.gateway_management[0].source_address_prefixes)}"
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
    condition     = length(azurerm_network_security_rule.gateway_management) == 0
    error_message = "an explicit [] did not close the gateway-management rule, so an operator who wants a steered box reachable only from inside the VNet has no way to say so."
  }

  assert {
    condition     = length(azurerm_network_security_rule.ssh) == 1
    error_message = "closing the gateway admission also closed the workstations' own TCP 22 rule. They are separate decisions and one must not take the other with it."
  }
}

# No gateway subnet, no NSG for the rule to live in.
run "no_gateway_subnet_means_no_admission" {
  command = plan

  variables {
    ssh_source_ranges     = ["203.0.113.0/24"]
    create_gateway_subnet = false
  }

  assert {
    condition     = length(azurerm_network_security_rule.gateway_management) == 0
    error_message = "the gateway-management rule is planned with create_gateway_subnet = false, where there is no gateway NSG to put it in."
  }
}

# The rule itself, once an operator names who it admits. Asserted field by field: a rule on the wrong
# group, on the wrong ports or with the wrong protocol reads correctly in the portal and leaves a
# steered workstation exactly as unreachable as it was.
run "the_admission_is_the_rule_it_promises" {
  command = plan

  variables {
    ssh_source_ranges                = ["198.51.100.0/24"]
    gateway_management_source_ranges = ["203.0.113.0/24"]
  }

  assert {
    condition     = length(azurerm_network_security_rule.gateway_management) == 1
    error_message = "an explicit narrower list created no gateway-management rule."
  }

  assert {
    condition     = toset(azurerm_network_security_rule.gateway_management[0].source_address_prefixes) == toset(["203.0.113.0/24"])
    error_message = "an explicit list did not override the ssh_source_ranges mirror: ${join(",", azurerm_network_security_rule.gateway_management[0].source_address_prefixes)}"
  }

  assert {
    condition     = azurerm_network_security_rule.gateway_management[0].network_security_group_name == azurerm_network_security_group.gateway[0].name
    error_message = "the gateway-management rule is not on the gateway subnet's NSG, which is the one Azure evaluates before the gateway VM's NIC."
  }

  assert {
    condition = (
      azurerm_network_security_rule.gateway_management[0].direction == "Inbound" &&
      azurerm_network_security_rule.gateway_management[0].access == "Allow" &&
      azurerm_network_security_rule.gateway_management[0].protocol == "Tcp"
    )
    error_message = "the gateway-management rule is not an inbound TCP allow."
  }

  assert {
    condition     = toset(azurerm_network_security_rule.gateway_management[0].destination_port_ranges) == toset(["22", "30000-32767"])
    error_message = "the gateway-management rule does not open TCP 22 plus the forwarded range. Both halves are needed: a jump host on the gateway answers on 22, a per-box forward needs the high ports, and this pad is applied once whichever Ringleader uses."
  }

  assert {
    condition     = azurerm_network_security_rule.gateway_management[0].priority != azurerm_network_security_rule.gateway_vnet_inbound[0].priority
    error_message = "the gateway-management rule shares a priority with the VNet allow in the same NSG, which Azure refuses at apply time."
  }
}
