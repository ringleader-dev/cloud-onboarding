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

  # Which /16 this region's landing pad takes, as region => index: 10.(60 + index).0.0/16,
  # with every subnet carved out of it. Required whenever create_network is set and you
  # have not set vpc_cidr. Index 0 is 10.60.0.0/16, this module's historical range.
  region_indexes = { "us-east-1" = 0 }
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
| `create_gateway_subnet` | **`true`** | reserve an empty **public** subnet, plus its route table, for the DNS / HTTPS proxy VM. You hand its id back as `spec.subnet` on the `EgressGateway`, and Ringleader builds no gateway until you do. Public and in the workstations AZ are both cost decisions — see `aws/README.md` |
| `create_governed_subnet` | **`true`** | reserve the subnet the workstations that proxy **governs** go in — the 15th `/20` of the VPC, `10.60.224.0/20` at index 0. Empty, no route table (Ringleader claims it and refuses one already associated) and no public IPs — so a box in it has no egress until a proxy steers it. See `aws/README.md` |
| `region_indexes` | `{}` | **region => index**, and **required** whenever `create_network` is set and `vpc_cidr` is not. The VPC takes `10.(60 + index).0.0/16` and every subnet is carved out of it, so one number allocates the whole landing pad. The module looks the index up by the region it is *actually applying in*, so the same map in a second region's tfvars gives that region a different range by construction — and an undeclared region, a region the map does not name, two regions on one index, or an index outside `0`–`9` all fail the plan. Index 0 is `10.60.0.0/16`, this module's historical range, so naming your region at 0 changes nothing. See [aws/README.md](../README.md#a-second-region-name-it-do-not-renumber-it) |
| `vpc_cidr` | `null` (derived) | one region's worth. Unset, it comes from `region_indexes`. Set it to bring your own IPAM — the subnets follow it, `region_indexes` is then ignored, and keeping every region distinct becomes yours to do |
| `subnet_cidr` | `null` (derived) | the first `/20` of `vpc_cidr` — `10.60.0.0/20` at index 0. Set it only to override |
| `gateway_subnet_cidr` | `null` (derived) | the 241st `/24` of `vpc_cidr` — `10.60.240.0/24` at index 0, well clear of `subnet_cidr`. Set it only to override |
| `governed_subnet_cidr` | `null` (derived) | the 15th `/20` of `vpc_cidr` — `10.60.224.0/20` at index 0. Set it only to override |
| `max_session_duration` | `3600` | ceiling on the life of the credentials Ringleader mints by assuming the role (AWS bounds: 3600–43200). 3600 is AWS's own default, so setting it changes nothing on an existing role |

## Outputs

`target_role_arn`, `account_id`, `subnet_id`, `governed_subnet_id`, `gateway_subnet_id`,
`security_group_id`, `inbound_only_security_group_id`, and `handoff` (all of them in one
object). Hand `handoff` back to Ringleader. Plus `vpc_id`, `gateway_subnet_cidr` and
`private_route_table_id` when the matching options are on. `vpc_cidr` and `subnet_cidr` report
the ranges this region actually took — worth recording, since they are what the next region has
to stay clear of.

**Two security groups, and the choice is not cosmetic.** `security_group_id` is the landing
pad: egress out, inbound SSH. `inbound_only_security_group_id` has the same inbound rules and
**no egress rules at all**, and it is the one a workstation that declares `spec.egress` must
carry — see [the union rule](../README.md#which-security-group-a-workstation-gets). Give a
policy-bearing workstation the first id and Ringleader refuses to launch it.

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

`hashicorp/aws >= 6.0` and `hashicorp/tls >= 4.0` (the `tls` provider reads the issuer's
chain to populate the OIDC provider thumbprint automatically).

The **aws floor is 6.0**, and it is one attribute that puts it there. This module has to learn
the region it is being applied in — that is what binds an entry in `region_indexes` to a region
rather than to whichever `tfvars` file was reached for — and in v6 the only spelling of that
which is not deprecated is `data.aws_region.current.region`. `name` and `id` are both deprecated
there and will be removed; `region` does not exist in v5 at all, and referencing it is a schema
error rather than something `try()` can rescue. There is no spelling clean on both majors, so
the floor is what picks one. If your root configuration pins `aws ~> 5.0`, raise it before
adopting this module.

## Revoke

`terraform destroy`, or delete just the OIDC provider / role — either stops Ringleader
minting into the account.
