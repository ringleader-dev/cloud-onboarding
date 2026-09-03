# What this file is for: the subnet allocation is the one thing in this module that cannot be
# fixed after the fact. A subnet's ip_cidr_range is force-new, so a change that quietly
# renumbered an EXISTING landing pad would destroy and recreate the subnet every workstation
# sits in -- and the ranges this module used to default to sat inside the block the AWS module
# allocates, so a customer onboarding both clouds held two networks that can never be joined.
#
# Both directions are pinned here: that declaring the historical /16 still produces the exact
# literals this module shipped before the ranges were derived, and that a new landing pad lands
# in GCP's own block and nowhere near AWS's.
#
# Run it with `terraform test` (Terraform >= 1.7, for mock_provider). Nothing here touches GCP:
# the provider is mocked and only `plan` is ever run, so it needs no credentials and creates
# nothing.

mock_provider "google" {}

variables {
  project_id            = "ringleader-example"
  ringleader_issuer_url = "https://oidc-app.ringleader.dev"
  org_uid               = "0192f5bf-af83-7178-8d0a-f1c7aea06bde"

  # The allocation every run below starts from; the runs that care replace it.
  network_cidr = "10.80.0.0/16"
}

# A NEW landing pad takes GCP's own block. 10.80-10.89 is clear of the AWS module's
# 10.60-10.69 and the Azure module's 10.70-10.79, which is the whole point of the move.
run "a_new_landing_pad_takes_gcps_own_block" {
  command = plan

  assert {
    condition     = output.network_cidr == "10.80.0.0/16"
    error_message = "network_cidr is not GCP's block: got ${output.network_cidr}"
  }

  assert {
    condition     = output.subnet_cidr == "10.80.0.0/20"
    error_message = "subnet_cidr does not follow network_cidr: got ${output.subnet_cidr}"
  }
}

# The migration promise. An operator who has been running this module since before it derived
# anything declares the range they already had, and every value below is the literal that
# variable used to default to -- so the apply is a no-op and nothing is renumbered.
run "the_historical_16_reproduces_the_historical_literals" {
  command = plan

  variables {
    network_cidr           = "10.60.0.0/16"
    create_gateway_subnet  = true
    create_governed_subnet = true
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

# The two egress-control ranges sit at the top of whichever /16 was declared, so they follow it
# and stay clear of the workstations range as it grows.
run "the_egress_ranges_follow_the_declared_16" {
  command = plan

  variables {
    create_gateway_subnet  = true
    create_governed_subnet = true
  }

  assert {
    condition     = output.gateway_subnet_cidr == "10.80.240.0/24"
    error_message = "gateway_subnet_cidr does not follow network_cidr: got ${output.gateway_subnet_cidr}"
  }

  assert {
    condition     = output.governed_subnet_cidr == "10.80.224.0/20"
    error_message = "governed_subnet_cidr does not follow network_cidr: got ${output.governed_subnet_cidr}"
  }
}

# Refusing to guess is the mechanism, not a nicety: Terraform cannot tell a first apply from a
# hundredth, and the two answers renumber each other. Silence must fail.
run "an_undeclared_allocation_is_refused" {
  command = plan

  variables {
    network_cidr = null
  }

  expect_failures = [google_compute_network.workstations]
}

# ...but only when this module is creating the network. A customer who brings their own subnet
# carves no range here and has nothing to declare.
run "an_undeclared_allocation_is_fine_without_a_landing_pad" {
  command = plan

  variables {
    network_cidr   = null
    create_network = false
  }

  assert {
    condition     = output.subnetwork_self_link == null
    error_message = "create_network = false still produced a subnet"
  }
}

# Bringing your own IPAM: an explicit subnet range wins over the derivation, and the ranges that
# were not overridden still follow network_cidr.
run "explicit_subnet_overrides_still_win" {
  command = plan

  variables {
    subnet_cidr           = "192.168.7.0/24"
    create_gateway_subnet = true
  }

  assert {
    condition     = output.subnet_cidr == "192.168.7.0/24"
    error_message = "explicit subnet_cidr was overridden by the derivation: got ${output.subnet_cidr}"
  }

  assert {
    condition     = output.gateway_subnet_cidr == "10.80.240.0/24"
    error_message = "gateway_subnet_cidr stopped following network_cidr: got ${output.gateway_subnet_cidr}"
  }
}

# The derivation has to reach EVERY consumer, not just the subnets. `mock_provider` bypasses the
# provider's own schema validation, so a resource still reading the nullable VARIABLE instead of the
# derived LOCAL plans clean here and fails for a real customer with "Null value found in list" -- the
# documented default configuration, unable to plan. Asserting on the resource is what sees it.
run "every_consumer_reads_the_derived_range" {
  command = plan

  variables {
    allow_internal_traffic = true
    create_governed_subnet = true
  }

  assert {
    condition = alltrue([
      for r in google_compute_firewall.internal[0].source_ranges : r != null
    ])
    error_message = "the internal firewall's source_ranges carry a null -- a consumer still reads var.*_cidr rather than local.*_cidr"
  }

  assert {
    condition     = contains(google_compute_firewall.internal[0].source_ranges, "10.80.0.0/20")
    error_message = "the internal firewall does not admit the derived workstations range: ${join(",", google_compute_firewall.internal[0].source_ranges)}"
  }

  assert {
    condition     = contains(google_compute_firewall.internal[0].source_ranges, "10.80.224.0/20")
    error_message = "the internal firewall does not admit the derived governed range: ${join(",", google_compute_firewall.internal[0].source_ranges)}"
  }
}

# A range that is not a CIDR is refused by the variable rather than reaching the API.
run "a_malformed_network_cidr_is_refused" {
  command = plan

  variables {
    network_cidr = "10.80.0.0"
  }

  expect_failures = [var.network_cidr]
}
