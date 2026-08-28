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
| `enable_workstation_identities` | **`true`** | grant `iam:PassRole`, scoped to roles under `workstation_identity_path` and to `ec2.amazonaws.com`, for instance profiles |
| `create_network` | **`true`** | create VPC + public subnet + IGW + security group. All free; the NAT gateway is not |
| `ssh_source_ranges` | `[]` | inbound-SSH CIDRs (empty = no inbound rule) |
| `secondary_ssh_source_ranges` | `null` | CIDRs for the **secondary SSH port** (TCP 2222) that some workstation types run their own SSH daemon on. Unset **mirrors `ssh_source_ranges`**; `[]` closes the port. You do not supply the port number |
| `create_nat_gateway` | **`true`** | a NAT gateway **and a private route table**, for workstations with no public IP. **The one default that costs money** — hourly plus $0.045/GB. The proxy replaces it later |
| `enable_egress_control` | **`true`** | let Ringleader manage the security groups an egress policy compiles to, **and** the subnets and route tables that steer traffic at the proxy; grants six security-group actions, a rules read, ten route/subnet actions, and `ec2:ModifyNetworkInterfaceAttribute`. Restricts nothing until you declare a policy |
| `egress_vpc_ids` | `[]` | confine those permissions to these VPCs. Empty uses the VPC this module created; empty **and** no created network means region-only scoping — check the `egress_scope` output |
| `create_gateway_subnet` | **`true`** | reserve an empty **public** subnet, plus its route table, for the future DNS / HTTPS proxy VM. Public and in the workstations AZ are both cost decisions — see `aws/README.md` |
| `gateway_subnet_cidr` | `10.60.240.0/24` | its CIDR, well clear of `subnet_cidr` |
| `vpc_cidr` | `10.60.0.0/16` | one region's worth. **Give every region a distinct range from the first apply** — a second region is a second VPC, and an inter-region Transit Gateway cannot route overlapping CIDRs |
| `max_session_duration` | `3600` | ceiling on the life of the credentials Ringleader mints by assuming the role (AWS bounds: 3600–43200). 3600 is AWS's own default, so setting it changes nothing on an existing role |

## Outputs

`target_role_arn`, `account_id`, `subnet_id`, `security_group_id`, and `handoff` (all of
them in one object). Hand `handoff` back to Ringleader. Plus `vpc_id`, `gateway_subnet_id`,
`gateway_subnet_cidr` and `private_route_table_id` when the matching options are on.

Four more are for **audit**, and none of them goes back to Ringleader — they exist so the
security property is something you can verify after applying rather than take on trust:

| Output | Read it back to confirm |
|---|---|
| `issuer_url` | the per-org issuer this account now trusts, byte for byte against what Ringleader gave you |
| `trusted_subject` | the **one** subject the trust policy admits — your org's uid and nothing else |
| `actions_granted` | every action the role holds, read from the same lists the policy is built from, so it cannot overstate or understate |
| `egress_scope` | how the egress-control permissions are bounded — a VPC list, a region list, or `UNBOUNDED` |

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
