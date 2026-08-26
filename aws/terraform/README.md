# Ringleader AWS onboarding — Terraform module

A reusable module that creates the IAM OIDC provider, the federated role, and (optionally)
a public-subnet landing-pad network (egress out, inbound SSH from the CIDRs you name, and a
**secondary SSH port** only if you ask for one). Declares no `provider` block, so reference it
from your own configuration; `examples/standalone/` is a ready-to-apply root.

## Usage

```hcl
module "ringleader_onboarding" {
  source = "github.com/ringleader-dev/cloud-onboarding//aws/terraform" # or a local path

  ringleader_issuer_url = "https://oidc-app.ringleader.dev" # from Ringleader
  org_uid               = "0192f5bf-af83-7178-8d0a-f1c7aea06bde" # from Ringleader

  allowed_regions   = ["us-east-1"]   # bound the role to the region(s) you use
  create_network    = true            # optional landing pad
  ssh_source_ranges = ["203.0.113.4/32"]
}

output "handoff" { value = module.ringleader_onboarding.handoff }
```

## Inputs (highlights)

| Variable | Default | Purpose |
|---|---|---|
| `ringleader_issuer_url` | — | Ringleader issuer origin, no trailing slash |
| `org_uid` | — | your Ringleader organization id (a UUID) |
| `role_name` | `ringleader-workstations` | IAM role name (its ARN is the handoff) |
| `allowed_regions` | `[]` | if non-empty, restrict EC2 actions to these regions |
| `enable_workstation_identities` | `false` | grant `iam:PassRole` (scoped) for instance profiles |
| `create_network` | `false` | create VPC + public subnet + IGW + security group |
| `ssh_source_ranges` | `[]` | inbound-SSH CIDRs (empty = no inbound rule) |
| `secondary_ssh_source_ranges` | `[]` | **opt-in** CIDRs for the **secondary SSH port** (TCP 2222) that some workstation types run their own SSH daemon on; empty = no rule, and an existing configuration plans clean. You do not supply the port |
| `create_nat_gateway` | `false` | add a NAT gateway for private (no-public-IP) workstations (bills hourly) |
| `max_session_duration` | `3600` | ceiling on the life of the credentials Ringleader mints by assuming the role (AWS bounds: 3600–43200). 3600 is AWS's own default, so setting it changes nothing on an existing role |

## Outputs

`target_role_arn`, `account_id`, `subnet_id`, `security_group_id`, and `handoff` (all of
them in one object). Hand `handoff` back to Ringleader.

Three more are for **audit**, and none of them goes back to Ringleader — they exist so the
security property is something you can verify after applying rather than take on trust:

| Output | Read it back to confirm |
|---|---|
| `issuer_url` | the per-org issuer this account now trusts, byte for byte against what Ringleader gave you |
| `trusted_subject` | the **one** subject the trust policy admits — your org's uid and nothing else |
| `actions_granted` | every action the role holds, read from the same lists the policy is built from, so it cannot overstate or understate |

## Partitions

Every ARN is built from `data.aws_partition.current`, so the module works unchanged in
GovCloud (`aws-us-gov`) and China (`aws-cn`). The CloudFormation template uses
`${AWS::Partition}` for the same reason.

## Providers

`hashicorp/aws >= 5.0` and `hashicorp/tls >= 4.0` (the `tls` provider reads the issuer's
chain to populate the OIDC provider thumbprint automatically).

## Revoke

`terraform destroy`, or delete just the OIDC provider / role — either stops Ringleader
minting into the account.
