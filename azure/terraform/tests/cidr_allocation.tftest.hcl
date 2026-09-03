# What this file is for: the address-space allocation is the one thing in this module that
# cannot be fixed after the fact. Two regions on one range can never be joined by a global VNet
# peering, and a change that quietly renumbers an EXISTING landing pad destroys and recreates
# its subnets. So both directions are pinned here -- that the defaults still produce the exact
# literals this module shipped before the prefixes were derived, and that a second region cannot
# land on the first one's range.
#
# Run it with `terraform test` (Terraform >= 1.7, for mock_provider). Nothing here touches Azure:
# the providers are mocked and only `plan` is ever run, so it needs no credentials and creates
# nothing.

mock_provider "azurerm" {}
mock_provider "azuread" {}

variables {
  subscription_id       = "00000000-0000-0000-0000-000000000000"
  resource_group_name   = "ringleader-workstations"
  ringleader_issuer_url = "https://oidc-app.ringleader.dev"
  org_uid               = "0192f5bf-af83-7178-8d0a-f1c7aea06bde"

  # The allocation every run below starts from; the runs that care replace it.
  region_indexes = {
    "eastus" = 0
  }
}

# The whole point of the derivation: an operator who has been running this module since before
# it derived anything must see NO change. Every value below is the literal that variable used to
# default to.
run "defaults_reproduce_the_historical_literals" {
  command = plan

  assert {
    condition     = output.vnet_address_space == "10.70.0.0/16"
    error_message = "vnet_address_space moved off the historical default: got ${output.vnet_address_space}"
  }

  assert {
    condition     = output.subnet_prefix == "10.70.1.0/24"
    error_message = "subnet_prefix moved off the historical default: got ${output.subnet_prefix}"
  }

  assert {
    condition     = output.gateway_subnet_prefix == "10.70.240.0/24"
    error_message = "gateway_subnet_prefix moved off the historical default: got ${output.gateway_subnet_prefix}"
  }

  assert {
    condition     = output.governed_subnet_prefix == "10.70.224.0/20"
    error_message = "governed_subnet_prefix moved off the historical default: got ${output.governed_subnet_prefix}"
  }
}

# A landing pad in the second region takes the second /16, and every subnet follows it. This is
# the collision the module exists to prevent: same map, different location, different range.
run "a_second_region_takes_the_next_16" {
  command = plan

  variables {
    location = "westeurope"
    region_indexes = {
      "eastus"     = 0
      "westeurope" = 1
    }
  }

  assert {
    condition     = output.vnet_address_space == "10.71.0.0/16"
    error_message = "second region did not take 10.71.0.0/16: got ${output.vnet_address_space}"
  }

  assert {
    condition     = output.subnet_prefix == "10.71.1.0/24"
    error_message = "subnets did not follow the VNet into the second /16: got ${output.subnet_prefix}"
  }

  assert {
    condition     = output.gateway_subnet_prefix == "10.71.240.0/24"
    error_message = "gateway subnet did not follow the VNet into the second /16: got ${output.gateway_subnet_prefix}"
  }

  assert {
    condition     = output.governed_subnet_prefix == "10.71.224.0/20"
    error_message = "governed subnet did not follow the VNet into the second /16: got ${output.governed_subnet_prefix}"
  }
}

# The map is shared between regions, so the FIRST region's apply must still produce the first
# region's range even though the map now names two.
run "the_first_region_is_unchanged_by_a_second_entry" {
  command = plan

  variables {
    location = "eastus"
    region_indexes = {
      "eastus"     = 0
      "westeurope" = 1
    }
  }

  assert {
    condition     = output.vnet_address_space == "10.70.0.0/16"
    error_message = "adding a second region moved the first one's range to ${output.vnet_address_space}"
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

  expect_failures = [azurerm_virtual_network.workstations]
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

# Applying in a location the map does not name is the accident this refuses: it would silently
# take index 0's range a second time.
run "an_unlisted_location_is_refused" {
  command = plan

  variables {
    location = "westeurope"
    region_indexes = {
      "eastus" = 0
    }
  }

  expect_failures = [azurerm_virtual_network.workstations]
}

# ...unless the operator has taken the allocation over entirely, which is what
# vnet_address_space means.
run "an_unlisted_location_is_allowed_when_the_address_space_is_explicit" {
  command = plan

  variables {
    location = "westeurope"
    region_indexes = {
      "eastus" = 0
    }
    vnet_address_space = "172.16.0.0/16"
  }

  assert {
    condition     = output.vnet_address_space == "172.16.0.0/16"
    error_message = "an explicit vnet_address_space was not honoured: got ${output.vnet_address_space}"
  }

  assert {
    condition     = output.governed_subnet_prefix == "172.16.224.0/20"
    error_message = "subnets did not follow an explicit vnet_address_space: got ${output.governed_subnet_prefix}"
  }
}

# Two regions on one index is the exact overlap this variable exists to prevent, so it is
# refused before anything is planned.
run "two_regions_on_one_index_are_refused" {
  command = plan

  variables {
    region_indexes = {
      "eastus"     = 0
      "westeurope" = 0
    }
  }

  expect_failures = [var.region_indexes]
}

run "an_index_outside_the_allocated_block_is_refused" {
  command = plan

  variables {
    region_indexes = {
      "eastus" = 10
    }
  }

  expect_failures = [var.region_indexes]
}

# An explicit subnet override still wins over the derivation -- the escape hatch for an operator
# with their own IPAM has to keep working.
run "explicit_subnet_overrides_still_win" {
  command = plan

  variables {
    subnet_prefix          = "10.70.32.0/24"
    gateway_subnet_prefix  = "10.70.250.0/24"
    governed_subnet_prefix = "10.70.208.0/20"
  }

  assert {
    condition     = output.subnet_prefix == "10.70.32.0/24"
    error_message = "an explicit subnet_prefix was not honoured: got ${output.subnet_prefix}"
  }

  assert {
    condition     = output.gateway_subnet_prefix == "10.70.250.0/24"
    error_message = "an explicit gateway_subnet_prefix was not honoured: got ${output.gateway_subnet_prefix}"
  }

  assert {
    condition     = output.governed_subnet_prefix == "10.70.208.0/20"
    error_message = "an explicit governed_subnet_prefix was not honoured: got ${output.governed_subnet_prefix}"
  }
}
