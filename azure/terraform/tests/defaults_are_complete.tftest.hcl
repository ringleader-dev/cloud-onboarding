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
    error_message = "naming ssh_source_ranges created no gateway-management rule. Azure evaluates the gateway subnet's NSG before the one on the gateway VM's NIC, so where Ringleader cannot write its own rule there, engineers who could reach a steered box would lose it."
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
    error_message = "an explicit [] did not close the gateway-management rule, so an operator who does not want their SSH ranges admitted to the gateway has no way to say so."
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
# group, on the wrong ports or with the wrong protocol reads correctly in the portal and admits
# nothing it promises.
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

# Flow logs are off by default, on purpose: they bill per GB collected and stored, and grant
# Ringleader nothing, so a customer who never asked for them must not start paying. Asserted on the
# deployment as well as on the variable, so a count that stops following the switch is caught too.
run "flow_logs_stay_off_until_asked_for" {
  command = plan

  assert {
    condition     = var.create_flow_logs == false
    error_message = "create_flow_logs defaults to true. Flow logs bill per GB and grant Ringleader nothing, so every customer who re-applies would start paying for logs they never asked for."
  }

  assert {
    condition     = length(azurerm_resource_group_template_deployment.flow_logs) == 0
    error_message = "The flow log deployment is planned on the defaults, so a customer who never set create_flow_logs gets a changed plan and a new bill."
  }
}

# Switched on, the flow log and its storage account are deployed outside the resource group
# Ringleader's role reaches, from the template the ARM route deploys, keeping a year of records.
run "flow_logs_land_outside_ringleaders_reach" {
  command = plan

  variables {
    create_flow_logs = true
  }

  # Planned, so the VNet id is unknown unless it is given one; the parameters below are built from it.
  override_resource {
    target          = azurerm_virtual_network.workstations
    override_during = plan
    values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet" }
  }

  # The deployment's parameters carry this subnet's id, so without an id the whole jsonencode is
  # unknown at plan time and every assertion on it is unevaluable.
  override_resource {
    target          = azurerm_subnet.flow_log_private_endpoint
    override_during = plan
    values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet/subnets/flowlog-endpoint" }
  }

  override_data {
    target = data.azurerm_network_watcher.flow_logs[0]
    values = { name = "NetworkWatcher_eastus", location = "eastus" }
  }

  assert {
    condition     = azurerm_resource_group_template_deployment.flow_logs[0].resource_group_name == "NetworkWatcherRG"
    error_message = "The flow log is not deployed into the Network Watcher's resource group. Azure requires a flow log beside its watcher, and a storage account in resource_group_name is one Ringleader's role may read and delete."
  }

  assert {
    condition     = azurerm_resource_group_template_deployment.flow_logs[0].template_content == file("../arm/azuredeploy-flowlogs.json")
    error_message = "The Terraform route does not deploy ../arm/azuredeploy-flowlogs.json verbatim, so the two routes can create different flow logs."
  }

  assert {
    condition     = jsondecode(azurerm_resource_group_template_deployment.flow_logs[0].parameters_content).retentionDays.value == 365
    error_message = "The flow log does not keep its records for 365 days by default."
  }

  assert {
    condition     = jsondecode(azurerm_resource_group_template_deployment.flow_logs[0].parameters_content).networkWatcherName.value == "NetworkWatcher_eastus"
    error_message = "The flow log is not recorded by the watcher Azure enables for the landing pad's region."
  }

  # The account's firewall denies every network except Azure trusted services, so the allowlist is
  # what decides who may read a record. Empty is the only safe default: a customer who turns flow
  # logs on and says nothing should get an account no reader outside Azure can reach, not one open
  # to an address they forgot.
  assert {
    condition     = length(jsondecode(azurerm_resource_group_template_deployment.flow_logs[0].parameters_content).logReaderIpRules.value) == 0
    error_message = "The flow log storage account admits a reader address by default, so turning flow logs on opens the records to somewhere the customer never named."
  }
}

# A private endpoint is the one thing in this module that bills by the hour, so a customer who
# turned flow logs on and said nothing more must not be paying for one. The subnet is the tell: it
# is carved only alongside the endpoint, so its absence proves neither exists.
run "the_flow_log_private_endpoint_stays_off_until_asked_for" {
  command = plan

  variables {
    create_flow_logs = true
  }

  # Planned, so the VNet id is unknown unless it is given one; the parameters below are built from it.
  override_resource {
    target          = azurerm_virtual_network.workstations
    override_during = plan
    values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet" }
  }

  # The deployment's parameters carry this subnet's id, so without an id the whole jsonencode is
  # unknown at plan time and every assertion on it is unevaluable.
  override_resource {
    target          = azurerm_subnet.flow_log_private_endpoint
    override_during = plan
    values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet/subnets/flowlog-endpoint" }
  }

  override_data {
    target = data.azurerm_network_watcher.flow_logs[0]
    values = { name = "NetworkWatcher_eastus", location = "eastus" }
  }

  assert {
    condition     = var.create_flow_log_private_endpoint == false
    error_message = "create_flow_log_private_endpoint defaults to true, so every customer who turns flow logs on starts paying for an endpoint they never asked for."
  }

  assert {
    condition     = jsondecode(azurerm_resource_group_template_deployment.flow_logs[0].parameters_content).privateEndpointSubnetId.value != ""
    error_message = "The flow log deployment is given no subnet for a private endpoint, so turning the endpoint on later would place it nowhere."
  }

  assert {
    condition     = jsondecode(azurerm_resource_group_template_deployment.flow_logs[0].parameters_content).createFlowLogPrivateEndpoint.value == false
    error_message = "The flow log deployment asks for a private endpoint on the defaults."
  }
}

# Asking for the endpoint has to carve the subnet it lives in, in the same apply. The template
# resolves that subnet from the VNet id by NAME, so a missing one is a deployment that fails at the
# customer rather than a plan that fails here.
run "the_private_endpoint_brings_its_own_subnet" {
  command = plan

  variables {
    create_flow_logs                 = true
    create_flow_log_private_endpoint = true
  }

  # Planned, so the VNet id is unknown unless it is given one; the parameters below are built from it.
  override_resource {
    target          = azurerm_virtual_network.workstations
    override_during = plan
    values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet" }
  }

  # The deployment's parameters carry this subnet's id, so without an id the whole jsonencode is
  # unknown at plan time and every assertion on it is unevaluable.
  override_resource {
    target          = azurerm_subnet.flow_log_private_endpoint
    override_during = plan
    values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet/subnets/flowlog-endpoint" }
  }

  override_data {
    target = data.azurerm_network_watcher.flow_logs[0]
    values = { name = "NetworkWatcher_eastus", location = "eastus" }
  }

  assert {
    condition     = length(azurerm_subnet.flow_log_private_endpoint) == 1
    error_message = "Asking for the private endpoint carved no subnet for it, so the endpoint would be placed nowhere."
  }

  assert {
    condition     = jsondecode(azurerm_resource_group_template_deployment.flow_logs[0].parameters_content).createFlowLogPrivateEndpoint.value == true
    error_message = "The flow log deployment was not asked for the private endpoint the module was."
  }

  assert {
    condition     = one(azurerm_subnet.flow_log_private_endpoint[*].address_prefixes[0]) == "10.70.241.0/24"
    error_message = "The private endpoint's subnet is not the /24 above the gateway range, so it no longer matches the ARM route or the table in azure/README.md."
  }
}

# The subnet has to outlive the endpoint's own switch. ARM's incremental mode never deletes a
# resource whose condition turns false, so turning the endpoint off leaves its interface in this
# subnet -- and Azure refuses to delete a subnet that still holds one. A subnet tied to the
# endpoint's switch would therefore fail the apply that turned it off.
run "the_endpoints_subnet_outlives_the_endpoints_switch" {
  command = plan

  variables {
    create_flow_logs                 = true
    create_flow_log_private_endpoint = false
  }

  # Planned, so the VNet id is unknown unless it is given one; the parameters below are built from it.
  override_resource {
    target          = azurerm_virtual_network.workstations
    override_during = plan
    values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet" }
  }

  # The deployment's parameters carry this subnet's id, so without an id the whole jsonencode is
  # unknown at plan time and every assertion on it is unevaluable.
  override_resource {
    target          = azurerm_subnet.flow_log_private_endpoint
    override_during = plan
    values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet/subnets/flowlog-endpoint" }
  }

  override_data {
    target = data.azurerm_network_watcher.flow_logs[0]
    values = { name = "NetworkWatcher_eastus", location = "eastus" }
  }

  assert {
    condition     = length(azurerm_subnet.flow_log_private_endpoint) == 1
    error_message = "The endpoint's subnet is gone once the endpoint is switched off, so a customer turning it off asks Azure to delete a subnet that still holds the endpoint's interface, and the apply fails."
  }
}

# Pointing the watcher's group at the group Ringleader's role reaches would put the records back
# within its reach, so it is refused.
run "flow_logs_in_ringleaders_resource_group_are_refused" {
  command = plan

  variables {
    create_flow_logs                    = true
    network_watcher_resource_group_name = "rg-defaults-test"
  }

  override_data {
    target = data.azurerm_network_watcher.flow_logs[0]
    values = { name = "NetworkWatcher_eastus", location = "eastus" }
  }

  expect_failures = [azurerm_resource_group_template_deployment.flow_logs]
}

# A watcher from another region cannot record this VNet's flows, so it is refused. Applied rather than
# planned, because the watcher is read after the VNet it would record, and the VNet is new here.
run "a_watcher_in_another_region_is_refused" {
  command = apply

  variables {
    create_flow_logs     = true
    network_watcher_name = "westeurope-watcher"
  }

  # A mocked provider invents ids the real provider refuses to parse on apply. These are
  # scaffolding for the apply, not what the run is about.
  override_resource {
    target = azuread_application.workstations
    values = { client_id = "00000000-0000-4000-8000-000000000001", id = "/applications/00000000-0000-4000-8000-000000000002" }
  }

  override_resource {
    target = azurerm_virtual_network.workstations
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet" }
  }

  override_resource {
    target = azurerm_subnet.workstations
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet/subnets/workstations" }
  }

  override_resource {
    target = azurerm_subnet.gateway
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet/subnets/gateway" }
  }

  override_resource {
    target = azurerm_subnet.governed
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/virtualNetworks/ringleader-vnet/subnets/governed" }
  }

  override_resource {
    target = azurerm_network_security_group.workstations
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/networkSecurityGroups/ringleader-workstations-nsg" }
  }

  override_resource {
    target = azurerm_network_security_group.gateway
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/networkSecurityGroups/ringleader-gateway-nsg" }
  }

  override_resource {
    target = azurerm_nat_gateway.workstations
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/natGateways/ringleader-nat" }
  }

  override_resource {
    target = azurerm_public_ip.nat
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defaults-test/providers/Microsoft.Network/publicIPAddresses/ringleader-nat-pip" }
  }

  override_data {
    target = data.azurerm_network_watcher.flow_logs[0]
    values = { name = "westeurope-watcher", location = "westeurope" }
  }

  expect_failures = [data.azurerm_network_watcher.flow_logs]
}

# The switch cannot log a network this module did not create. It is refused, because a plan that
# creates nothing would let a customer who set it for a compliance scan believe the VNet was logged.
run "flow_logs_without_the_network_are_refused" {
  command = plan

  variables {
    create_network   = false
    create_flow_logs = true
  }

  expect_failures = [azurerm_resource_group_template_deployment.role]
}
