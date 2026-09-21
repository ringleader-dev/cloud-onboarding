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
    error_message = "create_governed_subnet defaults to false: an AWS route table attaches per SUBNET, so a gateway steers every box in the one it is given. Without this subnet there is nowhere to put governed workstations that is not shared with ungoverned ones, and steering the shared one takes the egress of every box in it without a policy."
  }
}

# create_nat_gateway is the ONE default that bills, and it is on deliberately: without it a
# workstation created with assignPublicIp:false has no egress at all. Asserted so that turning it
# off is a decision someone makes and defends, not a quiet cost saving that strands private boxes.
# One account can serve several Ringleader organizations, and the managed artifact grant is bounded
# by a bucket-name pattern rather than by a scope. So a second organization has to be able to narrow
# that pattern, which is only possible if the label reaches the ARNs.
run "a_second_organization_can_narrow_the_managed_artifact_grant" {
  command = plan

  variables {
    artifact_storage_bucket_prefix = "0192f5bf"
  }

  assert {
    condition     = anytrue([for a in output.actions_granted : strcontains(a, ":s3:::ringleader-0192f5bf*")])
    error_message = "artifact_storage_bucket_prefix does not reach the artifact-storage ARNs, so two organizations in one account still share the managed grant: ${join(" | ", output.actions_granted)}"
  }

  assert {
    condition     = !anytrue([for a in output.actions_granted : strcontains(a, ":s3:::ringleader-*")])
    error_message = "The wider ringleader-* bound survives beside the narrowed one, so the grant still reaches every Ringleader-named bucket in the account and the narrowing buys nothing."
  }
}

# The separation two organizations get rests on every label being the SAME length: the bound is a
# prefix match, so a shorter label covers every longer one that starts with it.
run "an_artifact_label_of_the_wrong_length_is_refused" {
  command = plan

  variables {
    artifact_storage_bucket_prefix = "acme"
  }

  expect_failures = [var.artifact_storage_bucket_prefix]
}

run "the_one_default_that_costs_money_is_on_deliberately" {
  command = plan

  assert {
    condition     = var.create_nat_gateway
    error_message = "create_nat_gateway defaults to false. It bills hourly plus $0.045/GB, so turning it off is tempting -- but a workstation with assignPublicIp:false then has no egress at all and never converges. If this is being changed on purpose, change this assertion and say why in the same commit."
  }

  assert {
    condition     = var.artifact_storage_bucket == ""
    error_message = "artifact_storage_bucket has a non-empty default, which silently takes the NAMED width. The default width has to be the managed one: it is the only one that works without the customer having created anything, and a default naming a destination would be a default naming one nobody has."
  }

  assert {
    condition     = var.artifact_storage_bucket_prefix == ""
    error_message = "artifact_storage_bucket_prefix has a non-empty default. It narrows the managed grant's bucket-name bound, so a default would narrow it under every landing pad that has already applied one, and the grant would then match no bucket they have."
  }

  assert {
    condition     = anytrue([for a in output.actions_granted : strcontains(a, ":s3:::ringleader-*")])
    error_message = "The managed grant's bucket ARNs are not bounded to s3:::ringleader-* on the defaults. That bound is the only thing between the buckets Ringleader made and every bucket in the account, and Ringleader compiles the same literal."
  }

  assert {
    condition     = length(var.ssh_source_ranges) == 0
    error_message = "ssh_source_ranges has a non-empty default. Opening TCP 22 is not a decision this module may make for an operator: 0.0.0.0/0 exposes every workstation, and any narrower guess locks them out of boxes that come up healthy and unreachable."
  }
}

# An empty range list must CLOSE both workstation groups rather than stop managing them.
#
# The provider reads `ingress` in attributes-as-blocks mode, where a configuration carrying no block
# at all means "Terraform does not manage ingress" rather than "there is no ingress". So a `dynamic`
# block that produces nothing leaves whatever a previous apply opened in place: a customer who
# cleared ssh_source_ranges to close TCP 22 would keep it open, on every workstation, with a green
# plan and nothing to read. The groups therefore ASSIGN their rule list, which states the empty one
# too, and this asserts that they still do.
run "an_empty_range_list_closes_both_workstation_groups" {
  command = plan

  variables {
    create_network              = true
    ssh_source_ranges           = []
    secondary_ssh_source_ranges = []
  }

  assert {
    condition     = length(aws_security_group.workstations[0].ingress) == 0
    error_message = "The workstations group does not state an empty ingress list when ssh_source_ranges is empty. If this became a `dynamic` block again, the provider stops managing ingress and a rule an earlier apply opened stays open."
  }

  assert {
    condition     = length(aws_security_group.workstations_inbound_only[0].ingress) == 0
    error_message = "The inbound-only group does not state an empty ingress list when ssh_source_ranges is empty. The two groups are deliberately identical on ingress, so they close together or a workstation is reachable depending on which id was handed back."
  }
}

# Growing a root volume, and the read that reports a grow's state, asserted on the output a customer
# reads to audit what the role holds. Both actions reach it through the same lists the policy is
# built from, so an entry dropped from either list shows up here.
run "the_default_role_can_grow_a_root_volume_and_read_its_state" {
  command = plan

  assert {
    condition     = contains(output.actions_granted, "ec2:ModifyVolume")
    error_message = "actions_granted does not list ec2:ModifyVolume on the defaults, so raising a workstation's rootVolumeGiB is refused, and the only way to a larger root volume is recreating the workstation at that size."
  }

  assert {
    condition     = contains(output.actions_granted, "ec2:DescribeVolumesModifications")
    error_message = "actions_granted does not list ec2:DescribeVolumesModifications on the defaults, so a later Ringleader that waits for a grow to reach completed would ask every customer to apply this module again."
  }
}

# Flow logs are the one network piece that is OFF by default, and on purpose: they bill for every GB
# CloudWatch Logs ingests and stores, and they grant Ringleader nothing, so a customer who never asked
# for them must not start paying. Asserted on the resources as well as the variable, so a count that
# stops following the switch is caught too.
run "flow_logs_stay_off_until_asked_for" {
  command = plan

  assert {
    condition     = var.create_flow_logs == false
    error_message = "create_flow_logs defaults to true. Flow logs bill per GB ingested and stored and grant Ringleader nothing, so every customer who re-applies would start paying for logs they never asked for."
  }

  assert {
    condition     = length(aws_flow_log.workstations) == 0 && length(aws_cloudwatch_log_group.flow_logs) == 0 && length(aws_iam_role.flow_logs) == 0
    error_message = "A flow log, its log group or its delivery role is planned on the defaults, so a customer who never set create_flow_logs gets a changed plan and a new bill."
  }
}

# Switched on, the VPC gets a flow log for ALL traffic, into a log group that keeps a year, delivered
# by a role only the VPC Flow Logs service can assume and that may write only to that group.
run "flow_logs_record_every_connection_for_a_year" {
  command = plan

  variables {
    create_flow_logs = true
  }

  override_data {
    target = data.aws_iam_policy_document.flow_logs_trust[0]
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.flow_logs_delivery[0]
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  assert {
    condition     = length(aws_flow_log.workstations) == 1 && aws_flow_log.workstations[0].traffic_type == "ALL"
    error_message = "create_flow_logs = true does not plan one flow log recording ALL traffic. A flow log of ACCEPT or REJECT alone leaves half the connections out of the record a compliance scan asks for."
  }

  assert {
    condition     = aws_flow_log.workstations[0].log_destination_type == "cloud-watch-logs"
    error_message = "The flow log does not deliver to CloudWatch Logs, where its log group's retention is what keeps the records for a year."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 365
    error_message = "The flow log group does not keep its records for 365 days by default: got ${aws_cloudwatch_log_group.flow_logs[0].retention_in_days}."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].name == "ringleader-workstations-flow-logs"
    error_message = "The flow log group's default name moved. It is the name every landing pad that already turned flow logs on carries, and a rename here replaces the group and discards its records: got ${aws_cloudwatch_log_group.flow_logs[0].name}."
  }

  assert {
    condition     = aws_iam_role.flow_logs[0].path == null || aws_iam_role.flow_logs[0].path == "/"
    error_message = "The delivery role is not at the default path. Under workstation_identity_path the iam:PassRole grant for workstation identities would reach it."
  }
}

# A log group name is unique per account and region, so a second Ringleader organization onboarding
# into the same one has to rename the group. That is only possible if the name reaches the resource.
run "a_second_organization_can_rename_the_flow_log_group" {
  command = plan

  variables {
    create_flow_logs    = true
    flow_log_group_name = "ringleader-workstations-flow-logs-two"
  }

  override_data {
    target = data.aws_iam_policy_document.flow_logs_trust[0]
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.flow_logs_delivery[0]
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].name == "ringleader-workstations-flow-logs-two"
    error_message = "flow_log_group_name does not reach the log group, so two organizations in one account and region still collide on it: got ${aws_cloudwatch_log_group.flow_logs[0].name}."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].tags["Name"] == "ringleader-workstations-flow-logs-two"
    error_message = "The log group's Name tag still carries the old literal, so two groups in one account would be tagged alike."
  }
}

# The switch cannot log a network this module did not create. It is refused, because a plan that
# creates nothing would let a customer who set it for a compliance scan believe the VPC was logged.
run "flow_logs_without_the_network_are_refused" {
  command = plan

  variables {
    create_network   = false
    create_flow_logs = true
  }

  expect_failures = [data.aws_region.current]
}
