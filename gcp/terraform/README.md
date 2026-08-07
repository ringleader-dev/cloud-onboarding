# GCP onboarding — Terraform module

A reusable module that creates, in one of your projects: a least-privilege
service account, two predefined Compute roles, and a **Workload Identity Pool +
OIDC provider** trusting Ringleader's per-org issuer — plus, optionally, a
network landing pad (egress via Cloud NAT; inbound SSH only from the CIDRs you name).

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
| `enable_workstation_identities` | `false` | Let Ringleader provision a per-user SA and bind roles to it. **Grants `roles/resourcemanager.projectIamAdmin` — which can grant any role in the project to anyone, including `roles/owner` to itself.** Dedicated projects only. |
| `create_network` | `false` | Also create a VPC + subnet + Cloud NAT (egress out; inbound only via `ssh_source_ranges`). |
| `ssh_source_ranges` | `[]` | CIDRs allowed to reach workstations on **TCP 22**. Empty creates **no inbound rule** — workstations come up but nobody can open a shell on them (there is no bastion). Set it unless you reach the subnet privately. |
| `workstation_network_tag` | `ringleader-workstation` | Network tag the inbound-SSH rule targets; put the same tag on your workstations. |
| `region` | `us-central1` | Region for the optional network. |
| `subnet_cidr` | `10.60.0.0/20` | Primary range for the optional subnet. |

## Outputs

`handoff` bundles everything to hand back to Ringleader:
`target_service_account_email`, `project_id`, `workload_identity_provider`, and
`subnetwork_self_link` (when `create_network`).

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
