# GCP onboarding — Terraform module

A reusable module that creates, in one of your projects: a least-privilege
service account, three predefined roles, and a **Workload Identity Pool +
OIDC provider** trusting Ringleader's per-org issuer — plus, optionally, a
network landing pad (egress via Cloud NAT; inbound SSH only from the CIDRs you name,
and a **secondary SSH port** only if you ask for one).

The three roles are `roles/compute.instanceAdmin.v1`, `roles/compute.networkUser` and
`roles/iam.serviceAccountUser`. The last one is required, not optional: every workstation
VM runs as a service account (its own, or the project default compute one) and attaching
one needs `actAs`. See [`../README.md`](../README.md#every-workstation-runs-as-a-service-account).

It declares **no provider block**, so you can reference it from your own
Terraform. A ready-to-apply root is in [`examples/standalone/`](examples/standalone/).

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `project_id` | — (required) | Project Ringleader manages VMs in. |
| `ringleader_issuer_url` | — (required) | Ringleader's issuer origin, e.g. `https://oidc-app.ringleader.dev` (no trailing slash). |
| `org_uid` | — (required) | Your Ringleader organization id (RFC-4122 UUID). |
| `sa_account_id` | `ringleader-workstations` | Account id of the onboarding SA. |
| `sa_display_name` | `Ringleader Workstations` | Display name of the onboarding SA. |
| `pool_id` | `ringleader` | WIF pool id. |
| `provider_id` | `oidc` | WIF provider id. |
| `enable_workstation_identities` | **`true`** | Let Ringleader **create** a per-user SA and bind roles to it (workstations run as a service account either way). Grants `roles/resourcemanager.projectIamAdmin`, which can grant any role in the project to anyone, including `roles/owner` to itself — the broadest grant here, and the reason this onboarding wants a dedicated project. Set `false` in a shared one. |
| `create_network` | **`true`** | Create a VPC + subnet + Cloud NAT (egress out; inbound only via `ssh_source_ranges`). Cloud NAT bills per hour and per GB. Set `false` if you already have a subnet. |
| `ssh_source_ranges` | `[]` | CIDRs allowed to reach workstations on **TCP 22**. Empty creates **no inbound rule** — workstations come up but nobody can open a shell on them (there is no bastion). Set it unless you reach the subnet privately. |
| `workstation_network_tag` | `ringleader-workstation` | Network tag the inbound-SSH rule targets; put the same tag on your workstations. |
| `secondary_ssh_source_ranges` | `null` | CIDRs for the **secondary SSH port** (TCP 2222) that some workstation types run their own SSH daemon on. Unset **mirrors `ssh_source_ranges`**; `[]` closes the port. You do not supply the port number. |
| `secondary_ssh_network_tag` | `ringleader-secondary-ssh` | Network tag that rule targets. Put it on the workstations that need the port **alongside** `workstation_network_tag`, never instead of it. |
| `name_prefix` | `ringleader` | Prefix for the landing pad's resource names. Change it only if those names are already taken in the project; the default reproduces the names this module has always used. |
| `allow_internal_traffic` | **`true`** | Let workstations reach **each other** (tcp/udp/icmp from the workstation subnet ranges). The one default that widens rather than grants: `false` means a compromised box cannot scan its neighbours. Never admits anything from outside the subnets. |
| `region` | `us-central1` | Region for the optional network's first subnet, router and NAT. |
| `subnet_cidr` | `10.60.0.0/20` | Primary range for the optional subnet. |
| `additional_regions` | `{}` | More regions in the **same global VPC**, as `region => subnet CIDR`. Each also gets its own Cloud Router and Cloud NAT, since both are regional. GCP refuses overlapping ranges, so a mistake fails the apply. |
| `enable_egress_control` | **`true`** | Let Ringleader manage the firewall rules an egress policy compiles to, **and** the static route that steers traffic at the DNS / HTTPS proxy. Grants a **custom role** with `compute.firewalls.*`, `compute.routes.*` and `compute.networks.updatePolicy` (ten permissions) — deliberately not `roles/compute.securityAdmin`, which reaches further. Restricts nothing until you declare a policy. GCP-native FQDN filtering is a separate, documented opt-in; see `gcp/README.md`. |
| `egress_role_id` | `ringleaderEgressControl` | Id of that custom role. GCP reserves a deleted custom-role id for 7 days, so a quick re-apply after a destroy may need a different one. |
| `create_gateway_subnet` | **`true`** | Reserve an empty subnet for the future DNS / HTTPS proxy VM. Costs nothing; saves renumbering later. |
| `gateway_subnet_cidr` | `10.60.240.0/24` | Its range. Sits well clear of `subnet_cidr` so growing that one does not collide. |

## Outputs

`handoff` bundles everything to hand back to Ringleader:
`target_service_account_email`, `project_id`, `workload_identity_provider`, and
`subnetwork_self_link` (when `create_network`).

Also available: `additional_subnetwork_self_links` (keyed by region),
`gateway_subnetwork_self_link` and `gateway_subnet_cidr` — the last is what an egress
allowlist names to let workstations reach the proxy, so it is worth recording.

Two are for **audit** and go nowhere near Ringleader: `trusted_subject` (the one subject
this project's provider admits) and `roles_granted` (every role the service account holds,
including the optional ones, so you can check what you granted rather than take it on trust).

## Use as a module

```hcl
provider "google" {
  project = var.project_id
}

module "ringleader" {
  source = "github.com/ringleader-dev/cloud-onboarding//gcp/terraform" # or a local path

  project_id            = var.project_id
  ringleader_issuer_url = "https://oidc-app.ringleader.dev"
  org_uid               = "0192f5bf-af83-7178-8d0a-f1c7aea06bde"
}

output "handoff" {
  value = module.ringleader.handoff
}
```

## Note on the WIF pool soft-delete

`terraform destroy` soft-deletes the pool for 30 days and keeps its id reserved.
Re-applying within that window fails. Either use a new `pool_id`, or undelete the
existing one first:

```sh
gcloud iam workload-identity-pools undelete ringleader \
  --project <your-project> --location global
```
