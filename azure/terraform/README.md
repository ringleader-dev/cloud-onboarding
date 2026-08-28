# Azure onboarding — Terraform module

A reusable module that creates, in an **existing resource group you own**: an
Entra app + service principal, a **federated identity credential** trusting
Ringleader's per-org issuer, a **custom least-privilege role**, and the role
assignment binding them — plus, optionally, a network landing pad (egress via NAT gateway;
inbound SSH only from the CIDRs you name, and a **secondary SSH port** only if you ask for one).

It declares **no provider blocks**, so you can reference it from your own
Terraform. A ready-to-apply root is in [`examples/standalone/`](examples/standalone/).

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `subscription_id` | — (required) | Subscription holding the resource group. |
| `resource_group_name` | — (required) | **Existing** RG you own; the role is scoped to it. |
| `ringleader_issuer_url` | — (required) | Ringleader's issuer origin, e.g. `https://oidc-app.ringleader.dev` (no trailing slash). |
| `org_uid` | — (required) | Your Ringleader organization id (RFC-4122 UUID). |
| `app_display_name` | `ringleader-workstations` | Entra app display name. |
| `role_name` | `Ringleader Workstation Operator` | Custom role name. |
| `enable_workstation_identities` | `false` | Let Ringleader provision a per-user managed identity and assign roles to it. Adds `Microsoft.ManagedIdentity` CRUD/assign + `Microsoft.Authorization/roleAssignments/write` — **which built-in Contributor does not have either.** |
| `create_network` | `false` | Also create a vnet + subnet + NAT gateway + NSG (egress out; inbound only via `ssh_source_ranges`). |
| `ssh_source_ranges` | `[]` | CIDRs allowed to reach workstations on **TCP 22**. Empty creates **no inbound rule** — workstations come up but nobody can open a shell on them (there is no bastion). Set it unless you reach the VNet privately. |
| `secondary_ssh_source_ranges` | `[]` | **Opt-in.** CIDRs allowed to reach the **secondary SSH port** (TCP 2222) that some workstation types run their own SSH daemon on. Empty creates **no rule** — an existing configuration plans clean. The rule is subnet-wide (Azure has no per-VM tag), and you do not supply the port. |
| `name_prefix` | `ringleader` | Prefix for the landing pad's resource names. Change it only if those names are already taken in the resource group; the default reproduces the names this module has always used. |
| `location` | `eastus` | Region for the optional network. |
| `vnet_address_space` | `10.70.0.0/16` | One region's worth. **Give every region a distinct range from the first apply** — a second region is a second VNet, and global VNet peering cannot join overlapping spaces. |
| `subnet_prefix` | `10.70.1.0/24` | Prefix for the optional workstations subnet. |
| `enable_egress_control` | `false` | Let Ringleader manage the NSGs that restrict where workstations may connect. Adds NSG and security-rule read/write/delete plus `join/action`, still scoped to this resource group. |
| `create_gateway_subnet` | `false` | Reserve an empty subnet for the future DNS / HTTPS proxy VM. Shares the NAT gateway, so no public IP is needed. |
| `gateway_subnet_prefix` | `10.70.240.0/24` | Its prefix, well clear of `subnet_prefix`. |

## Outputs

`handoff` bundles `target_app_client_id`, `subscription_id`, `resource_group_name`,
and `subnet_id` (when `create_network`). Add your **tenant id**
(`az account show --query tenantId -o tsv`) and hand all of it back to Ringleader.

Also available: `gateway_subnet_id` and `gateway_subnet_prefix` — the latter is what an
egress allowlist names to let workstations reach the proxy, so it is worth recording — and
`role_extras_granted`, which lists the optional action sets folded into the custom role so
you can check what you granted.

## Use as a module

```hcl
provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
provider "azuread" {}

module "ringleader" {
  source = "github.com/ringleader-dev/cloud-onboarding//azure/terraform" # or a local path

  subscription_id       = var.subscription_id
  resource_group_name   = "ringleader-workstations"
  ringleader_issuer_url = "https://oidc-app.ringleader.dev"
  org_uid               = "0192f5bf-af83-7178-8d0a-f1c7aea06bde"
}
```

The custom role is deployed straight from `../arm/azuredeploy.json` (via
`azurerm_resource_group_template_deployment`), so the action list lives in exactly
one place — edit the ARM template and both the Terraform and `deploy.sh` paths follow.

Azure stores its own **normalized** copy of that template and echoes it back, and this
resource compares the echo against the file — so anything Azure rewrites becomes a diff
on every `plan`, forever. The template is therefore authored in the form Azure stores;
[`../arm/README.md`](../arm/README.md#editing-this-template) has the four rules to keep
in mind when editing it. A plan against an unchanged configuration should report **no
changes**; if it reports a change to `template_content` or `parameters_content`, the
template has drifted from Azure's normal form, not from your infrastructure.
