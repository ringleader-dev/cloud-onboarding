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
| `create_identity` | **`true`** | Create the Entra app registration, service principal and federated credential. The FIRST region does; set it **`false`** in every region after it and pass the two ids below, so all of them grant the role to the ONE identity Ringleader authenticates as. An app registration is tenant-wide while the role is scoped to a resource group, so a second region left on the default mints a second client id you would have to hand back as well — and neither identity could act in the other's group. See [azure/README.md](../README.md#a-second-region-name-it-do-not-renumber-it). |
| `existing_client_id` | `null` | The first region's `target_app_client_id`, required when `create_identity = false`. |
| `existing_principal_object_id` | `null` | The first region's `service_principal_object_id` — what the role assignment names. Required when `create_identity = false`; the plan refuses the pair half-set. |
| `role_name` | `Ringleader Workstation Operator` | Custom role name. |
| `enable_workstation_identities` | **`true`** | Let Ringleader provision a per-user managed identity and assign roles to it. Adds `Microsoft.ManagedIdentity` CRUD/assign + `Microsoft.Authorization/roleAssignments/write`, which built-in Contributor does not carry either — still scoped to this one resource group. |
| `create_network` | **`true`** | Create a vnet + subnet + NAT gateway + NSG (egress out; inbound only through `ssh_source_ranges` and the one SSH rule Ringleader adds). On Azure a workstation you opt out of a public IP (`providerConfig.azure.publicIp: false`) has no egress without this. The NAT gateway and its public IP bill per hour. |
| `ssh_source_ranges` | `[]` | CIDRs allowed to reach every VM on the workstations and governed subnets on **TCP 22**. Empty creates **no rule of yours**. Ringleader adds its own rule admitting TCP 22 and 2222 from any address to the workstations it creates. Set this to reach other VMs, or to keep your engineers' CIDRs working when Ringleader cannot write that rule. |
| `secondary_ssh_source_ranges` | `null` | CIDRs for the **secondary SSH port** (TCP 2222) that some workstation types run their own SSH daemon on. Unset **mirrors `ssh_source_ranges`**. `[]` creates no rule for the port. The rule is subnet-wide (Azure has no per-VM tag), and you do not supply the port number. |
| `gateway_management_source_ranges` | `null` | CIDRs allowed through the **gateway subnet's** NSG to the egress gateway VM on TCP 22 and 30000-32767. Azure evaluates that NSG before the NSG on the gateway VM's NIC, and both must allow. By default Ringleader also writes its own rule in that NSG, admitting the forwarded ports from any address. This one admits them only where Ringleader cannot. Unset **mirrors `ssh_source_ranges`**; `[]` closes it, and does not keep steered workstations off the internet (`spec.inboundManagement: false` on the `Edge` does). You do not supply the ports. |
| `name_prefix` | `ringleader` | Prefix for the landing pad's resource names. Change it only if those names are already taken in the resource group; the default reproduces the names this module has always used. |
| `location` | `eastus` | Region for the optional network, and the key `region_indexes` is looked up by. |
| `region_indexes` | `{}` | **location => index**, and **required** whenever `create_network` is set and `vnet_address_space` is not. The VNet takes `10.(70 + index).0.0/16` and every subnet is carved out of it, so one number allocates the whole landing pad. The module looks the index up by `location`, so the same map in a second region's tfvars gives that region a different range by construction — and an undeclared location, a location the map does not name, two locations on one index, or an index outside `0`–`9` all fail the plan. Index 0 is `10.70.0.0/16`, this module's historical range, so naming your location at 0 changes nothing. See [azure/README.md](../README.md#a-second-region-name-it-do-not-renumber-it). |
| `vnet_address_space` | `null` (derived) | One region's worth. Unset, it comes from `region_indexes`. Set it to bring your own IPAM — the subnets follow it, `region_indexes` is then ignored, and keeping every region distinct becomes yours to do. |
| `subnet_prefix` | `null` (derived) | The second `/24` of `vnet_address_space` — `10.70.1.0/24` at index 0. Set it only to override. |
| `enable_egress_control` | **`true`** | Let Ringleader manage the NSGs an egress policy compiles to, **and** the route tables and subnets that steer traffic at the DNS / HTTPS proxy. Adds twenty-three actions, still scoped to this resource group. Restricts no outbound traffic until you declare a policy. Ringleader also uses it to write its SSH rules, which narrow inbound from outside the VNet to TCP 22 and 2222 on a workstation with no policy. |
| `enable_artifact_storage` | **`true`** | Let Ringleader hold artifact payloads — sealed agent-session transcripts, workflow file outputs, files a box publishes — in a storage account in **this resource group** rather than in Ringleader's own cloud. Adds the `Microsoft.Storage` reads plus the four blob **data** actions, so access is by Entra ID and a short-lived token. Deliberately **not** `listKeys` or `listAccountSas`: an account key is a long-lived static credential and this onboarding is keyless throughout. Writes nothing until a Ringleader namespace declares a `Storage` naming a destination, and the Azure Blob backend ships after the GCS one — the grant arrives early so that does not cost a second apply. |
| `artifact_storage_account_name` | `""` (managed) | Name a storage account **you** created and every account and container write and delete is dropped: Ringleader may put blobs in containers you made and may neither create, reshape nor delete an account or a container. Note what this does **not** narrow — the role is scoped to this resource group, as every other action in it is, so naming an account narrows what Ringleader may *do* and not which account it may reach. Put the account in a resource group of its own if you need that too. |
| `create_gateway_subnet` | **`true`** | Reserve the subnet the DNS / HTTPS proxy VM runs in, and its NSG. Hand `gateway_subnet_id` back as `Edge.spec.subnet`; no gateway VM is built until you do. Azure bills for neither the subnet nor the NSG. The subnet is associated with the landing pad's NAT gateway, which is what the gateway VM's egress rests on. The VM has no public address until it first forwards a port to a steered workstation. |
| `create_governed_subnet` | **`true`** | Reserve the subnet the workstations that proxy **governs** go in — the 15th `/20` of the VNet, `10.70.224.0/20` at index 0. Carries the workstations NSG so `rl shell` still reaches a box in it; carries neither a route table nor the NAT gateway, and Azure's implicit default outbound access is **off** — a governed box's egress is the proxy's. That flag is fixed at subnet creation. See `azure/README.md`. |
| `gateway_subnet_prefix` | `null` (derived) | The 241st `/24` of `vnet_address_space` — `10.70.240.0/24` at index 0, well clear of `subnet_prefix`. Set it only to override. |
| `governed_subnet_prefix` | `null` (derived) | The 15th `/20` of `vnet_address_space` — `10.70.224.0/20` at index 0. Set it only to override. |
| `create_flow_logs` | `false` | Record VNet flow logs for the VNet this module creates, into a storage account created for them. **Off by default**, because in most regions Azure bills per GB collected beyond 5 GB a month, plus storage. The flow log and its storage account go in the **Network Watcher's resource group**. That is outside the resource group the role is scoped to, so Ringleader can neither read nor delete them. Whoever applies needs to create resources there. Turning it off again deletes the storage account and every record in it. Needs `create_network`. See `azure/README.md`. |
| `flow_log_retention_days` | `365` | How many days each flow log record is kept, 1 to 365. |
| `network_watcher_name` | `null` → `NetworkWatcher_<location>` | The region's Network Watcher. Set it if yours has another name, for example `<location>-watcher` from the Azure CLI. It must exist and be in `location`, or the plan or apply fails naming it. |
| `network_watcher_resource_group_name` | `NetworkWatcherRG` | The watcher's resource group. The flow log and its storage account are created here, and the plan refuses `resource_group_name`. |
| `additional_governed_subnets` | `{}` | One more governed subnet per namespace that runs its own proxy, as a map of your label to a prefix you write out. Each is built like the governed subnet and named `governed-<label>`. See `azure/README.md`. |

## Outputs

`handoff` bundles `target_app_client_id`, `subscription_id`, `resource_group_name`, and the
subnet ids (`subnet_id`, `governed_subnet_id`, `gateway_subnet_id`, and
`additional_governed_subnet_ids` keyed by your label) when `create_network` is on. Add your
**tenant id** (`az account show --query tenantId -o tsv`) and hand all of it back to Ringleader.
None of the subnets are interchangeable. A workstation carrying an egress policy goes in
`governed_subnet_id`, every other one in `subnet_id`, and `gateway_subnet_id` goes on the
`Edge` itself as `spec.subnet`. Each additional governed subnet is for one namespace's
workstations that carry an egress policy.

Also available: `gateway_subnet_prefix` — what an
egress allowlist names to let workstations reach the proxy, so it is worth recording — and
`role_extras_granted`, which lists the optional action sets folded into the custom role so
you can check what you granted. `vnet_address_space` and `subnet_prefix` report the ranges this
region actually took — worth recording, since they are what the next region has to stay clear
of.

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
