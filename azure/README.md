# Onboarding Microsoft Azure

Let a Ringleader control plane run **workstation VMs** in **one of your Azure resource
groups** using a **custom role narrower than built-in Contributor**, scoped to that one
resource group, and a **keyless** federation trust — no client secret.

## The model

```
Ringleader control plane
  |  signs a short-lived OIDC token:  iss = <issuer>/org/<org-id>,  sub = org:<org-id>
  |  presents it as the client assertion for your Entra app
  v
Federated Identity Credential on YOUR Entra app
  |  trusts ONLY (issuer = Ringleader's per-org issuer, subject = org:<org-id>,
  |               audience = api://AzureADTokenExchange)
  v
service principal  ->  custom role (VM / disk / NIC / public-IP / subnet-join only)
  v
creates / manages / deletes workstation VMs in ONE resource group
```

- **Keyless.** No client secret is created or stored, and there is no keyed alternative:
  federation is the only way Ringleader authenticates to your cloud. The federated
  credential trusts only your org's subject from Ringleader's issuer; a token minted for
  any other customer is refused (`AADSTS700211`).
- **Least privilege.** Instead of built-in **Contributor** (which can touch every
  resource type in the group), the assets define a **custom role** with only the ARM
  actions Ringleader's Azure provider performs.

## Before you start

Ringleader gives you two values:

- **`ISSUER_URL`** — e.g. `https://oidc-app.ringleader.dev` (no trailing slash).
- **`ORG_UID`** — your Ringleader organization id, a UUID like
  `0192f5bf-af83-7178-8d0a-f1c7aea06bde`.

You also need an **existing resource group** you own (the role is scoped to it; these
assets do not create it) and rights to create an app registration in your Entra tenant.

### Register one subscription feature first

Register **`Microsoft.Compute/UseStandardSecurityType`** on the subscription. Ringleader
creates VMs with `securityType=Standard` (Trusted Launch is incompatible with the nested
virtualization workstations rely on), and without this feature **every VM create fails** —
the trust will be perfect and no workstation will ever boot.

```bash
az feature register --namespace Microsoft.Compute --name UseStandardSecurityType
# poll until Registered (can take several minutes), then propagate:
az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query properties.state -o tsv
az provider register --namespace Microsoft.Compute
```

Also confirm your chosen region has capacity for the VM size you intend to use, or every
create returns `SkuNotAvailable`.

## Two ways to apply

| Path | Creates | Use when |
|---|---|---|
| **[Terraform](terraform/)** | app + SP + FIC + custom role + assignment (+ optional network), end to end | you manage infra as code |
| **[ARM](arm/)** | the custom role + assignment, plus the optional network landing pad (the app + SP + FIC are created with `az` first) | you prefer ARM / the portal |

The Entra **app registration** and its **federated credential** are Microsoft Graph
directory objects, not ARM resources, so an ARM template cannot create them. The ARM
path therefore creates the app + SP + FIC with `az`, then deploys the role + assignment
as a template. Terraform does the whole thing (the `azuread` provider talks to Graph
directly).

### ARM quick start (recommended for non-Terraform users)

```bash
export RG=ringleader-workstations                      # existing RG you own
export ISSUER_URL='https://oidc-app.ringleader.dev'    # Ringleader gives you this
export ORG_UID='0192f5bf-af83-7178-8d0a-f1c7aea06bde'  # ...and this
az login
cd arm
./deploy.sh
```

### Terraform quick start

```bash
cd terraform/examples/standalone
cp terraform.tfvars.example terraform.tfvars   # then edit
az login
terraform init && terraform apply
terraform output handoff
```

## Reaching your workstations

Ringleader has **no bastion and no SSH tunnel**: `rl shell`, `rl tmux`, port-forwards,
and VS Code Web all dial the workstation on **TCP 22**. Bringing a workstation up needs
only *egress*, so one can finish setting up, report `Ready`, and still be unreachable.

On Azure a workstation gets **no public IP unless you ask for one**
(`providerConfig.azure.publicIp: true`), which has two consequences:

1. **No public IP and no NAT gateway → no egress → the workstation never comes up.** Azure's
   default outbound access is being retired, so a private VM with nothing in front of it
   cannot reach the Ringleader control plane. The landing pad (`create_network = true`) gives
   it a NAT gateway, fixing egress without a public IP.
2. **Egress alone still leaves nobody able to SSH in.** A subnet with no NSG is not
   "open" — Azure allows intra-VNet traffic and denies the Internet. To use the workstation:

```hcl
create_network    = true
ssh_source_ranges = ["203.0.113.0/24"]   # the CIDRs your engineers connect from
```

Leave `ssh_source_ranges` empty **only** if you reach the VNet privately (VPN /
ExpressRoute / peering).

### A second SSH port — opt-in, and off unless you ask

Some Ringleader workstation types run their **own SSH daemon on a secondary port** inside the VM,
while the VM's own sshd keeps 22, and `rl shell` dials that port for such a workstation. To open
it:

```hcl
create_network              = true
secondary_ssh_source_ranges = ["203.0.113.0/24"]
```

That adds one NSG rule, `AllowRingleaderSecondarySSHInbound`. **It covers the whole subnet.** An
NSG attaches to the subnet and Azure has no per-VM tag for a rule to match, so — unlike the GCP
module, which aims the same rule at a network tag — this admits the port to every VM on the
workstations subnet. The source ranges are the only narrowing available; give the workstations
that need the port a subnet of their own if that is too broad.

Leave `secondary_ssh_source_ranges` empty — the default — and **no rule is created**; your VNet
admits exactly what it admits today. Ringleader tells you whether the workstations you plan to run
need this port. You never supply the port number: the module carries it, so it cannot drift from
the port Ringleader dials. On the ARM path it is `SECONDARY_SSH_SOURCE_CIDR` — see
[`arm/README.md`](arm/README.md#the-optional-network-landing-pad).

## Optional: workstations that run AS an identity

Ringleader can boot each workstation with a dedicated per-user managed identity and assign roles
to it. This is **off by default** because it needs the `Microsoft.ManagedIdentity` CRUD +
`assign/action` surface **and** `Microsoft.Authorization/roleAssignments/write` — which
built-in **Contributor does not have either**. Scoped to the one resource group, it is
still the power to hand out access inside that boundary.

Set `enable_workstation_identities = true` (Terraform) or run `deploy.sh` with
`WORKSTATION_IDENTITIES=1` (ARM). Left off, the feature fails closed with a `403`.

## Optional: egress control

By default a workstation can reach anything your network routes. Ringleader can narrow that
to an allowlist you declare in the workstation manifest — a set of IP ranges and hostnames —
enforced by network security groups that Ringleader creates and keeps in step with the
manifest.

It is **off by default**, and off changes nothing.

```hcl
enable_egress_control = true
```
```bash
EGRESS_CONTROL=1 ./deploy.sh    # the ARM path
```

It adds seven actions to the custom role, still scoped to your one resource group:

| action | why |
|---|---|
| `Microsoft.Network/networkSecurityGroups/read` / `write` / `delete` | one NSG per distinct egress policy |
| `.../networkSecurityGroups/securityRules/read` / `write` / `delete` | keep that NSG's rules in step with the manifest |
| `Microsoft.Network/networkSecurityGroups/join/action` | attach the NSG to a workstation's NIC — the one people forget |

Ringleader compiles each distinct policy into **one** NSG and attaches it to the NICs of the
workstations carrying that policy. That matters here: Azure caps an NSG at **1,000 rules** and
will not raise it, so a rule set per workstation would not reach fleet scale.

Note the difference from the inbound rules elsewhere in this module: those attach to the
**subnet**, so they reach every VM on it. Egress policies attach to the **NIC**, so they are
genuinely per workstation.

## Room for the DNS / HTTPS proxy

Restricting egress by **hostname** (rather than by IP range) needs a resolver that answers per
workstation, and no cloud offers one — so Ringleader runs a small DNS / HTTPS proxy VM in your
resource group. That VM does not exist yet, but it is worth reserving its address range now:

```hcl
create_gateway_subnet = true              # 10.70.240.0/24 by default
```
```bash
CREATE_GATEWAY_SUBNET=true ./deploy.sh
```

This creates an **empty subnet** and nothing else. Azure does not bill for a subnet, and the
subnet shares the landing pad's NAT gateway, so the proxy gets upstream egress without a
public IP. No NSG is attached: Azure's defaults already allow intra-VNet traffic and deny
inbound from the internet, which is the right posture for a proxy.

## Plan your address space before the second region

An Azure VNet is regional. A second region means a second VNet joined by **global VNet
peering**, which is non-transitive and cannot join overlapping address spaces. So pick the
ranges up front, even if you only need one region today:

| region | `vnet_address_space` | `subnet_prefix` | `gateway_subnet_prefix` |
|---|---|---|---|
| first | `10.70.0.0/16` | `10.70.1.0/24` | `10.70.240.0/24` |
| second | `10.71.0.0/16` | `10.71.1.0/24` | `10.71.240.0/24` |
| third | `10.72.0.0/16` | `10.72.1.0/24` | `10.72.240.0/24` |

Ringleader's proxy VMs are regional, so each region runs its own; nothing here requires the
regions to be joined at all until you want one proxy to serve several. Global VNet peering
also charges for cross-region transfer, which is a second reason to keep a proxy local.

## What you return to Ringleader

| Value | How to get it |
|---|---|
| **app client id** | printed by `deploy.sh` / `terraform output` |
| **tenant id** | `az account show --query tenantId -o tsv` |
| **subscription id** | `az account show --query id -o tsv` |
| **resource group** | the one you scoped |
| **subnet id** (only if you created a network) | `terraform output handoff` |

## Revoking

- **Terraform:** `terraform destroy`.
- **ARM / az:** delete the federated credential (cuts federation, keeps the app):
  `az ad app federated-credential delete --id <appId> --federated-credential-id ringleader-oidc`
  — or delete the app entirely: `az ad app delete --id <appId>`.

More detail: <https://docs.ringleader.dev/cloud-onboarding/azure/>.
