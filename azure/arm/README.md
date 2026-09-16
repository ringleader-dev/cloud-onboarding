# Azure onboarding — ARM template + az

For teams that prefer ARM / the portal over Terraform. Because the Entra **app
registration** and its **federated credential** are Microsoft Graph directory
objects (not ARM resources), the ARM templates here cover the **custom role + its
assignment** and the optional **network landing pad**; the app + service principal
+ federated credential are created with `az`. [`deploy.sh`](deploy.sh) does all of
it in one idempotent run.

## Files

| File | What it is |
|---|---|
| [`azuredeploy.json`](azuredeploy.json) | ARM template: the custom least-privilege role definition + a role assignment, scoped to the resource group. Deploy at **resource-group scope**. Takes the service-principal **object id** as `principalId`. It is the single source of the action list — the [Terraform module](../terraform/) deploys this same file. |
| [`azuredeploy-network.json`](azuredeploy-network.json) | ARM template: the **optional** landing pad — vnet + `workstations` subnet + NAT gateway + an NSG per subnet, with inbound rules only for the CIDRs you name. Outputs `subnetId`, `governedSubnetId` and `gatewaySubnetId`. Deploy at resource-group scope, after `azuredeploy.json`. |
| [`azuredeploy.parameters.example.json`](azuredeploy.parameters.example.json) | Example parameters file. |
| [`deploy.sh`](deploy.sh) | End-to-end wrapper: creates the app + SP + OIDC federated credential with `az`, then deploys the template. |

## Quick start (recommended)

```bash
export RG=ringleader-workstations                      # existing RG you own
export ISSUER_URL='https://oidc-app.ringleader.dev'    # Ringleader gives you this
export ORG_UID='0192f5bf-af83-7178-8d0a-f1c7aea06bde'  # ...and this
az login
./deploy.sh
```

`deploy.sh` prints the exact values to hand back to Ringleader (app client id,
tenant id, subscription id, resource group).

Env vars: `RG`, `ISSUER_URL`, `ORG_UID` (required); `APP_NAME`
(`ringleader-workstations`), `ROLE_NAME` (`Ringleader Workstation Operator`),
`WORKSTATION_IDENTITIES` (`1` to also grant the per-workstation runtime-identity
actions — see [`../README.md`](../README.md) before turning it on).

## The optional network landing pad

Add `CREATE_NETWORK=true` and `deploy.sh` also deploys `azuredeploy-network.json`
and prints the resulting subnet id:

```bash
CREATE_NETWORK=true \
REGION_INDEX=0 \
SSH_SOURCE_CIDR=203.0.113.0/24 \
  ./deploy.sh
```

`REGION_INDEX` is **required** whenever this creates a network, and picks which `/16` the
landing pad takes: the VNet gets `10.(70 + REGION_INDEX).0.0/16` and every subnet is carved out
of it. Give your first region `0` — that is `10.70.0.0/16`, the range this template has always
created, so an existing deployment is unchanged — and the next region `1`. There is no default
on purpose: an Azure VNet is regional, two VNets on one range can never be peered, and nothing
here can tell a first region from a second, so guessing would hand the second one the first
one's range in silence. See [`../README.md`](../README.md#a-second-region-name-it-do-not-renumber-it).

Env vars for it: `NAME_PREFIX` (`ringleader`), `VNET_CIDR` and
`SUBNET_CIDR` (both empty: overrides, derived from `REGION_INDEX` when unset),
`SSH_SOURCE_CIDR` (empty),
`SECONDARY_SSH_SOURCE_CIDR` (mirrors `SSH_SOURCE_CIDR`, and `none` closes it, as
[`../README.md`](../README.md#a-second-ssh-port--opened-to-the-same-people-as-22) describes), and
`GATEWAY_MANAGEMENT_SOURCE_CIDR` (mirrors `SSH_SOURCE_CIDR`, and `none` closes it, as described
below).
`SSH_SOURCE_CIDR` empty means the NSG is created with **no inbound rule**, which is
correct only if you reach the VNet privately.

`CREATE_GATEWAY_SUBNET` is on by default (`GATEWAY_SUBNET_CIDR` overrides its range; unset, it
derives the 241st `/24` of the VNet, `10.70.240.0/24` at index `0`). It reserves the subnet the
egress gateway VM for hostname-level egress control runs in, and prints its id as `gateway subnet`.
**Hand that id back as `spec.subnet` on the `EgressGateway`**, not on a workstation. Ringleader
builds no gateway VM until it has one, because a proxy placed in a subnet it steers would route its
own egress into itself. Azure does not bill for the subnet. The subnet is associated with the NAT
gateway, which is what the VM Ringleader builds in it uses to reach the internet. The VM takes no
public address of its own unless `EgressGateway.spec.publicAddress` asks for one.

The subnet also gets an NSG (`<prefix>-gateway-nsg`), because Azure's default rules live *inside* a
group and a bare subnet would leave the proxy's listeners reachable from the internet rather than
closed. The NSG carries two rules:

- **Allow the VNet inbound to any destination.** The group cannot go without it. `AllowVnetInBound`
  allows the VNet only to a *VNet* destination, and a steered packet still carries the public
  address the workstation was reaching, so an empty group would drop exactly the traffic the proxy
  exists to carry.
- **Allow `GATEWAY_MANAGEMENT_SOURCE_CIDR` on TCP 22 and 30000-32767**, created when that variable
  is not empty. It keeps a workstation an egress policy steers reachable through the gateway VM.
  Azure evaluates this subnet's NSG before the NSG on the gateway VM's NIC, and both must allow. See
  [`../README.md`](../README.md#room-for-the-egress-gateway).

Set `createGatewaySubnet` to `false` to skip the subnet and its NSG.

`CREATE_GOVERNED_SUBNET` is also on by default (`GOVERNED_SUBNET_CIDR` overrides its range;
unset, it derives the 15th `/20` — `10.70.224.0/20` at index `0`): it reserves the subnet the workstations that proxy **governs** go in, and
prints its id as `governed subnet`. A proxy steers a whole subnet and serves only the boxes it
holds a policy for, so mixing governed and ungoverned workstations in one is what Ringleader
refuses. It carries the workstations NSG (so `rl shell` still reaches a box in it) and
deliberately neither a route table nor the NAT gateway, with Azure's implicit default outbound
access turned **off** — a flag Azure fixes at subnet creation, so it has to be right on the first
deploy. See
[`../README.md`](../README.md#and-a-subnet-for-the-workstations-that-proxy-governs). Set it to
`false` to skip.

`EGRESS_CONTROL` is separate and goes on the **role**, not the network: it adds the NSG
actions Ringleader needs to enforce an egress policy. Also on by default; `EGRESS_CONTROL=0`
skips it.

`ARTIFACT_STORAGE` goes on the role too, and it is the only switch here that adds **dataActions**:
the four blob actions (read, write, delete, add) that let Ringleader hold artifact payloads in a
storage account in this resource group rather than in its own cloud. Access is by Entra ID and a
short-lived token — `listKeys` and `listAccountSas` are deliberately **not** granted, because an
account key is a long-lived static credential. On by default; `ARTIFACT_STORAGE=0` skips it, and
`ARTIFACT_STORAGE_ACCOUNT=<name>` takes the narrower width, dropping every account and container
write and delete so Ringleader may only put blobs in containers you made.

See [`../README.md`](../README.md#optional-egress-control) and
[the full list of defaults](../../README.md#what-is-on-by-default-and-how-to-turn-it-off).

The NSG this template creates is the **subnet** layer, and its rules are yours. A workstation that
declares `spec.egress` gets a second NSG on its **NIC**, written by Ringleader; Azure evaluates
both and both must allow, so this one decides who may reach the workstation and Ringleader's
decides where the workstation may connect. Keep inbound narrowing here rather than on a NIC, and
do not add an outbound `Deny` here — it cannot tighten a policy and it can break one. See
[`../README.md`](../README.md#two-nsgs-at-two-layers--and-which-one-is-yours).

**Leave priorities 4090 to 4096 free in both groups.** Ringleader will add one inbound allow rule
of its own in that range, admitting the SSH ports to the workstations it runs and the management
ports to the gateway VM, and it never edits or deletes a rule this template created. That is why
every rule here is deployed as its own `securityRules` child resource, and why `deploy.sh` passes
`workstationsNsgExists` and `gatewayNsgExists`: deploying a group sets its **whole** rule list, so
a group redeployed over one that already exists would delete Ringleader's rule and leave the
workstations behind it unreachable until Ringleader's next pass. The other side of that shape is
that a deployment never deletes a rule, so clearing `SSH_SOURCE_CIDR`,
`SECONDARY_SSH_SOURCE_CIDR` or `GATEWAY_MANAGEMENT_SOURCE_CIDR` closes its rule through
`deploy.sh` rather than through the template. Deploying the template by hand with a cleared CIDR
leaves that rule as it was.

**Why a second template rather than a `deployNetwork` flag on the first.**
`azuredeploy.json` is also deployed by the [Terraform module](../terraform/),
which compares Azure's normalized echo of it against the file on every plan — so
it may carry no `outputs` block and no parameter default it does not pass (see
*Editing this template* below). A landing pad is useless without an output (you
need the subnet id back), so the two cannot be one file. Two deployments keep
both properties.

## Deploy the template by itself

If you already have the app + service principal + federated credential and just
want the role + assignment (e.g. from the portal or a pipeline):

```bash
# service principal OBJECT id (not the app/client id):
SP_OBJECT_ID=$(az ad sp show --id <client-id> --query id -o tsv)

az deployment group create \
  --resource-group ringleader-workstations \
  --template-file azuredeploy.json \
  --parameters principalId="$SP_OBJECT_ID"
```

Then add the federated credential yourself:

```bash
az ad app federated-credential create --id <client-id> --parameters '{
  "name": "ringleader-oidc",
  "issuer": "https://oidc-app.ringleader.dev/org/<org-id>",
  "subject": "org:<org-id>",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

The role definition's name is a GUID derived from the resource group and the role name
(`guid(resourceGroup().id, roleName)`), so re-deploying updates the same role rather than
creating a second one. To find it:

```bash
az role definition list --name "Ringleader Workstation Operator" \
  --query '[0].{name:name, id:id}' -o json
```

## Editing this template

The [Terraform module](../terraform/) deploys this same file through
`azurerm_resource_group_template_deployment`, which compares the file against the
**normalized copy Azure stores and echoes back**. Anything Azure rewrites becomes a
permanent `terraform plan` diff — a step that reports changes on every run, forever, is a
step whose real changes nobody notices. So the template is written in the form Azure
stores, and edits must keep it that way:

- **no top-level `metadata` block** — Azure drops it. Describe the template here instead.
- **no `outputs` block** — Azure rewrites the output `type` casing.
- **no parameter with a `defaultValue` that the Terraform module does not pass
  explicitly** — Azure materializes the default into the stored parameters while the file
  leaves it unset. That is why the role definition GUID is a `variables` entry rather than
  a parameter.
- **parameter `type` in ARM's canonical casing** — `String`, `Bool`, `Int`, `Object`,
  `Array`, `SecureString`, `SecureObject`. ARM accepts the lowercase spellings and the docs
  use them, but Azure stores the capitalized form, so a lowercase `"type": "string"` here is
  a permanent one-line diff per parameter.

Parameter `metadata.description` blocks are preserved by Azure and are fine.

The optional action sets — `enableWorkstationIdentities`, `enableEgressControl` and
`enableArtifactStorage` — are folded in with nested `if`/`union` expressions over the `actions`
variable, so the base list stays in one place. `enableArtifactStorage` additionally selects the
role's `dataActions`, and `artifactStorageAccountName` chooses between the two widths by whether
`storageManagedActions` is unioned in. Every one of those parameters carries a `defaultValue`,
and every one is passed explicitly by the Terraform module and `deploy.sh`, which is what rule
three requires — `check_route_parity.py` fails the build if one stops being passed.

Check what Azure actually holds with
`az deployment group export -g <rg> -n ringleader-onboarding`.

See [`../README.md`](../README.md) for the trust model and the values to hand back.
