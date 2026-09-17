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
export REGION_INDEX=0                                  # which /16 this region takes
az login
cd arm
./deploy.sh
```

`REGION_INDEX` is required whenever this creates a network — `0` for your first region, `1` for
the next. It is the ARM half of *[A second region](#a-second-region-name-it-do-not-renumber-it)*
below, and `0` is the range this template has always created.

### Terraform quick start

```bash
cd terraform/examples/standalone
cp terraform.tfvars.example terraform.tfvars   # then edit
az login
terraform init && terraform apply
terraform output handoff
```

If you change `location` from the default, change the `region_indexes` key beside it too — it
is what decides the landing pad's range, and the plan fails rather than guessing if the two
disagree. See [A second region](#a-second-region-name-it-do-not-renumber-it).

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
2. **Ringleader admits SSH to its own workstations.** The landing pad attaches an NSG to every
   subnet it creates, and an NSG with no rules of yours still carries Azure's defaults,
   `AllowVnetInBound` and then `DenyAllInBound`, so nothing outside the VNet reaches a VM on it.
   Ringleader adds one rule to that NSG admitting TCP 22 and 2222 from any address to the
   workstations it creates, and to no other VM. A workstation with a public IP is then reachable
   from the internet on those ports, unless an egress policy steers it. One without a public IP is
   reachable from anywhere that can route to the VNet. See
   [Two NSGs, at two layers](#two-nsgs-at-two-layers--and-which-one-is-yours) for the rule itself.

`ssh_source_ranges` adds a rule of your own on TCP 22, for the CIDRs your engineers connect from:

```hcl
create_network    = true
ssh_source_ranges = ["203.0.113.0/24"]
```

Your rule covers every VM on the subnet, not only Ringleader's. It also keeps a workstation
reachable from those CIDRs when Ringleader cannot write its own rule, in which case the workstation
reports `SSHAdmissionMissing`. Leave it empty and Ringleader's rule is the only way in from outside
the VNet.

### A second SSH port — opened to the same people as 22

Some Ringleader workstation types run their **own SSH daemon on a secondary port** inside the VM,
while the VM's own sshd keeps 22, and `rl shell` dials that port for such a workstation. To open
it:

```hcl
create_network              = true
secondary_ssh_source_ranges = ["203.0.113.0/24"]
```

That adds one NSG rule, `AllowRingleaderSecondarySSHInbound`. **It covers the whole subnet.** An
NSG attaches to the subnet, and this rule names no destination inside it, so it admits the port to
every VM on the workstations subnet. The GCP module aims the same rule at a network tag. The
source ranges are the only narrowing available; give the workstations that need the port a subnet
of their own if that is too broad.

Leave `secondary_ssh_source_ranges` unset, the default, and it follows `ssh_source_ranges`: with
that empty too, **no rule is created**. Ringleader's own rule already admits the port to the
workstations it creates, so yours matters only for other VMs on the subnet, or for when Ringleader
cannot write its rule. You never supply the port number: the module carries it, so it cannot drift
from the port Ringleader dials. On the ARM path it is `SECONDARY_SSH_SOURCE_CIDR`, as
[`arm/README.md`](arm/README.md#the-optional-network-landing-pad) describes.

## Optional: workstations that run AS an identity

Ringleader can boot each workstation with a dedicated per-user managed identity and assign roles
to it. This is **on by default**; it needs the `Microsoft.ManagedIdentity` CRUD +
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

It is **on by default**. Granting it restricts no outbound traffic until you declare an egress
policy on a workstation. Ringleader also uses it to write the rules that admit SSH to the
workstations it creates. On a workstation with no policy, those rules narrow inbound traffic from
outside the VNet to TCP 22 and 2222, as
[Two NSGs, at two layers](#two-nsgs-at-two-layers--and-which-one-is-yours) describes. To opt out:

```hcl
enable_egress_control = false
```
```bash
EGRESS_CONTROL=0 ./deploy.sh    # the ARM path
```

It adds twenty-three actions to the custom role, still scoped to your one resource group:

| action | why |
|---|---|
| `Microsoft.Network/networkSecurityGroups/read` / `write` / `delete` | one NSG per distinct egress policy |
| `.../networkSecurityGroups/securityRules/read` / `write` / `delete` | keep that NSG's rules in step with the manifest |
| `Microsoft.Network/networkSecurityGroups/join/action` | attach the NSG to a workstation's NIC — the one people forget |
| `Microsoft.Network/applicationSecurityGroups/read` / `write` / `delete`, plus `joinIpConfiguration/action` and `joinNetworkSecurityRule/action` | the group Ringleader will create and put each workstation's NIC in. The inbound SSH rule it writes in your subnet NSG will name that group, so one rule stays right as workstations come and go. The two `join` actions are the ones people forget: read, write and delete grant neither. Ringleader creates the group and collects it, so nothing here declares one, and the grant arrives early so the rule does not cost you a second apply. `listIpConfigurations/action` is deliberately **not** granted: Azure refuses to delete a group an interface still uses and names those interfaces in the refusal, so collecting one needs no membership read |
| `Microsoft.Network/routeTables/*` (with `routes/*` and `join/action`) | steer a workstation's traffic at the egress gateway when a policy names hostnames |
| `Microsoft.Network/virtualNetworks/subnets/write` / `delete` | an Azure route table attaches **per subnet**, so steering is per subnet rather than per workstation — which is what `create_governed_subnet` below exists to give it — and a route table Ringleader creates, it must also be able to detach and collect. Not a subnet per policy: one gateway serves many policies from one subnet, telling them apart by source address |
| `Microsoft.Network/natGateways/read` | see whether a subnet already has an outbound path before giving a machine a public address of its own |
| `Microsoft.Resources/subscriptions/resourcegroups/resources/read` | the odd one out, and the reason it is called out below |

**The last row is not a networking action, and a least-privilege role that omits it fails in a
way that costs money rather than erroring.** The sweep that collects a leaked egress gateway
lists the resource group's generic `resources` collection rather than a typed per-provider one,
so it needs a `Microsoft.Resources` action where everything else it does is `Microsoft.Compute`
or `Microsoft.Network`. Built-in **Contributor** covers it, so a deployment using Contributor
never sees this; a hand-rolled role can hold all twenty-two networking actions above and still be
refused here. And the refusal is not a partial listing — the sweep collects **nothing**,
including the VM it did not need this action to see, so what is left behind is a running gateway
VM — and, if one was declared for it, a billed public IP.

Ringleader compiles each distinct policy into **one** NSG and attaches it to the NICs of the
workstations carrying that policy. That matters here: Azure caps an NSG at **1,000 rules** and
will not raise it, so a rule set per workstation would not reach fleet scale.

Note the difference from the inbound rules elsewhere in this module: those attach to the
**subnet**, so they reach every VM on it. Egress policies attach to the **NIC**, so they are
genuinely per workstation.

### Two NSGs, at two layers — and which one is yours

Ringleader creates each workstation with a network security group on its NIC, so a workstation on
one of this module's subnets carries **two** of them, and they are not interchangeable:

| layer | object | written by | decides |
|---|---|---|---|
| subnet | `ringleader-workstations-nsg`, from this module | **you**, plus one rule of Ringleader's | inbound: who may reach the workstation |
| NIC, with a policy | one NSG per distinct egress policy | **Ringleader** | outbound: where the workstation may connect |
| NIC, without a policy | one NSG of Ringleader's, shared by those workstations | **Ringleader** | inbound from outside the VNet: only TCP 22 and 2222 |

Azure evaluates both and **both must allow**. Four consequences, all worth having before the
first policy:

- **Keep your inbound rules on the subnet NSG, and know what the NIC layer adds.** A new NSG ends
  in `DenyAllInBound`, so a NIC NSG with no inbound allow would cut SSH from outside the VNet, and
  the workstation would come up unreachable without saying why. Every NIC NSG Ringleader writes
  therefore carries an inbound allow. On a workstation with an egress policy it admits all inbound
  traffic, so the subnet NSG alone decides who gets in. On a workstation with no policy it admits
  only TCP 22 and 2222, and the group has no outbound rule. Such a workstation takes no other port
  from outside the VNet, even one your subnet NSG opens. Neither group admits anything the subnet
  NSG refuses, because both layers have to agree.
- **A NIC NSG of your own is replaced, not merged.** A NIC carries at most one NSG. If you supply
  the interface yourself (`providerConfig.azure.networkInterfaceId`) and narrowed inbound *there*,
  Ringleader replaces that group when it creates the workstation, whether or not the workstation
  declares `spec.egress`. With a policy, the replacement admits all inbound, so the subnet's rules
  decide on their own, which **widens** inbound. Without one, it admits only TCP 22 and 2222 from
  outside the VNet. Move those rules onto the subnet NSG first. Ringleader adds a rule there, but
  never edits or deletes one you wrote.
- **Leave priorities 4090 to 4096 free in the subnet NSG.** Ringleader adds one inbound allow rule
  of its own there, at the lowest free priority in that range, so its workstations are reachable
  without you widening the group. The rule admits TCP 22 and 2222 from any address. Its
  destination is an application security group that Ringleader creates in your resource group and
  puts each of its workstations' NICs in. A VM in the subnet that Ringleader did not create is
  therefore as closed as your own rules leave it. The workstation reports `SSHAdmissionMissing`
  when Ringleader cannot write the rule. That happens, for example, when every priority in the
  range holds a rule of yours, or when the subnet's NSG is in a resource group the role does not
  cover. The workstation is then reachable only if your own rules admit it.
- **Do not add an outbound `Deny` to the subnet NSG.** It cannot make a policy tighter — the NIC
  NSG already denies everything the policy does not list — but it can make one *break*, by
  blocking a destination the policy allows. The failure looks like Ringleader ignoring your
  allowlist.

Unlike AWS, there is nothing extra to create or hand back: an Azure NSG expresses `Deny` directly,
so the compiled group narrows the workstation on its own. (An AWS security group cannot, which is
why that module ships a second, egress-less group and asks you to pick one per workstation.)

## Room for the egress gateway

Restricting egress by **hostname** (rather than by IP range) needs the connection read by
something that can see the hostname on it, and no cloud offers that per workstation — so
Ringleader runs a small **egress gateway** VM in your resource group. It builds and maintains
that VM itself, once a workstation declares a policy naming hostnames, and it is a **billed**
instance. Reserving its address range now is what keeps you from renumbering later:

It is on by default, taking the 241st `/24` of the VNet — `10.70.240.0/24` in a first region,
and following the VNet into whichever `/16` a later one takes. To skip it:

```hcl
create_gateway_subnet = false
```
```bash
CREATE_GATEWAY_SUBNET=false ./deploy.sh
```

It creates an **empty subnet and its NSG**, and Azure bills for neither. **The subnet is
associated with the landing pad's NAT gateway, and that is what the gateway VM's egress rests
on**: it takes no public address of its own unless Ringleader is asked for one
(`EgressGateway.spec.publicAddress`), so without that association it would boot and reach
nothing.

**Asking for one does not move its traffic off the NAT gateway.** Azure's NAT gateway takes
precedence over an instance-level public IP for outbound — measured, not inferred: a VM in this
subnet holding its own static address still egressed from the NAT gateway's. So a public address
here buys inbound reachability, which the gateway does not need, and changes neither the NAT
gateway's per-GB processing charge nor the source address your upstreams see. (On GCP it is the
other way round: an external address there bypasses Cloud NAT, which is why that cloud's README
prices the two against each other.)

**The NSG matters, and its first rule matters more.** Azure's default security rules are rules
*inside* a group, so a bare subnet is not "closed by default": it is unfiltered. That matters
whenever the gateway does carry a public address, and it costs nothing when it does not. But the
group cannot be an *empty* one. `AllowVnetInBound` allows the VNet **to a VNet destination**, and a
packet steered to the proxy still carries the **public** address the workstation was reaching,
because a route's next hop does not rewrite the destination. An empty group would drop exactly the
traffic the proxy exists to carry, while the gateway went on reporting healthy. So the group's
first rule allows the VNet inbound to **any** destination, which is the same rule Ringleader writes
in the NSG on the gateway VM's NIC. Both layers must say it, and the outer one decides. Outbound is
untouched.

**Its second rule keeps a steered workstation reachable, and it follows `ssh_source_ranges`.** A
workstation an egress policy steers stops answering on its own address from outside the VNet,
because the steering route is `0.0.0.0/0` and a default route also carries the *reply* to a
connection the box never opened. So the management connection goes through the gateway VM, which
forwards it to the box. Ringleader admits that traffic in the NSG on the gateway VM's NIC. For
inbound traffic Azure evaluates the subnet's NSG before the NIC's, and both must allow, so this
group carries the other half: `allow-management-inbound`, TCP 22 and 30000-32767, from the ranges in
`ssh_source_ranges`. You do not supply the ports.

Ringleader puts only the gateway VM in this subnet, and the NSG on its NIC still decides what
reaches it. From the internet nothing is reachable until the gateway has a public address, which it
gets only when `EgressGateway.spec.publicAddress` asks for one. Sources inside the VNet were already
admitted by the first rule. A forwarded connection keeps its source address, so the steered
workstation's own NSG still decides whether to accept it. To close the rule, set
`gateway_management_source_ranges = []` (Terraform) or `GATEWAY_MANAGEMENT_SOURCE_CIDR=none`
(`deploy.sh`). A steered workstation is then reachable only from inside the VNet or a network joined
to it.

**Hand its id back as `spec.subnet` on the `EgressGateway`.** It is `gateway_subnet_id` in the
handoff, and Ringleader builds no gateway VM until it has one: a route table attaches per
subnet and replaces the default route of everything in it, so a proxy sitting in a subnet it
steers would route its own egress into itself and black-hole every workstation it serves.
Do not hand `governed_subnet_id` here — that one is the workstations'.

**Pin the proxy and the workstations it serves to the same availability zone.** Azure charges
cross-zone traffic in **both directions** ($0.01/GB each way), so at 10 TB/month a misplaced
proxy costs $200 — more than the `Standard_D2as_v5` it runs on. Same-zone traffic is free.

### And a subnet for the workstations that proxy governs

`create_governed_subnet` is also on by default, taking the 15th `/20` of the VNet —
`10.70.224.0/20` in a first region. It is the subnet you put a
workstation in **once it carries an egress policy**, and placing a box there is the whole of what
makes it proxy-governed.

```hcl
create_governed_subnet = false
```
```bash
CREATE_GOVERNED_SUBNET=false ./deploy.sh
```

**Why it cannot just be the workstations subnet.** A route table (a UDR with a virtual-appliance
next hop) attaches to a *subnet*, so the proxy steers everything in the one it is given, and it
serves only the boxes it holds a policy for — an unknown source is refused. The `workstations`
subnet is where every workstation in this VNet goes, policy or no policy, so steering that one
would take the egress of every box in it that has none. One proxy still serves many policies from
this one subnet; it tells them apart by **source address**, so you never need a subnet per policy.

What it gets and what it deliberately does not:

- **The same NSG as the workstations subnet.** An NSG is what makes Azure's defaults apply at
  all, and its `DenyAllInBound` is what closes the box to the internet; Ringleader ships no
  bastion, so the SSH rule in that same group is what lets you reach a governed workstation.
  Without the group there is neither. The NSG narrows inbound only — `AllowInternetOutBound` at 65001
  is untouched — so attaching it grants the box no egress of its own.
- **No route table.** Ringleader claims the subnet by putting its own UDR on it and declines one
  that already references a route table. It *could* put yours back, unlike AWS where the
  permission to re-associate does not exist at all — it declines for the same fail-safe reason, so
  you learn one rule across both clouds.
- **No NAT gateway**, unlike the workstations and gateway subnets. A governed box's egress is the
  proxy's job; attaching one would hand every box in here an unpoliced path to the internet for
  the whole window before steering lands, and the UDR overrides it the moment it does. A box with
  its own public IP still has Azure's own outbound until then — that is Azure's behaviour, not
  something this module can remove, and it is a reason to create governed workstations without
  one. Reaching one does not need an address of its own either way: the gateway VM forwards a
  port per governed workstation when the `EgressGateway` asks for it (`spec.inboundManagement`,
  plus `spec.publicAddress` to reach that port from outside the VNet).
- **Azure's implicit default outbound access turned off**, which is the half Azure *does* let the
  module remove. Without it a workstation in here with no public IP would still reach the internet
  through Azure's own SNAT — an unpoliced path that survives withholding the NAT gateway, and the
  one thing that would leave this subnet less fail-safe than its AWS twin. **Azure fixes this at
  subnet creation**: turning it off later replaces the subnet, so it has to be right on the first
  apply.

### One governed subnet per namespace that runs a proxy

A proxy steers a whole subnet, so every workstation in a steered subnet should belong to the
Ringleader namespace that runs the proxy. A proxy takes the egress of any other workstation in its
subnet. So each namespace that runs its own proxy needs a governed subnet of its own.
`create_governed_subnet` makes the first, and `additional_governed_subnets` makes one more for each
further namespace:

```hcl
additional_governed_subnets = {
  team-a = "10.70.208.0/20"
  team-b = "10.70.192.0/20"
}
```
```bash
ADDITIONAL_GOVERNED_SUBNETS=team-a=10.70.208.0/20,team-b=10.70.192.0/20 ./deploy.sh
```

Each entry becomes a subnet named `governed-<label>`, built exactly like the governed subnet above.
The label names the subnet and keys the `additional_governed_subnet_ids` output. Ringleader never
reads it, so use the name of the namespace that will use the subnet. Set each id as
`providerConfig.azure.subnetId` on that namespace's workstations that carry an egress policy, and on
no other namespace's.

These subnets have no derived prefix, so write each one out. In a first region, the six `/20`s from
`10.70.128.0/20` to `10.70.208.0/20` are free and leave the workstations subnet room to grow. A
prefix outside the VNet, or overlapping another subnet, fails the deployment. Changing an entry's
prefix changes the subnet in place, and removing an entry deletes it. Azure refuses both while
anything is deployed in the subnet. Renaming a label replaces its subnet, which is refused the same
way.

The ARM path deploys the VNet's subnets as one list, so list every pair on every `deploy.sh` run. A
pair left out deletes its subnet, and leaving `ADDITIONAL_GOVERNED_SUBNETS` unset deletes them all.
That is unlike the AWS `deploy.sh`, which keeps them.

## Optional: artifact storage in a storage account of yours

Ringleader holds **artifact payloads** — the sealed transcript of an agent session above all,
plus workflow file outputs and files a workstation publishes. By default those bytes go to a
bucket Ringleader owns. `enable_artifact_storage` (`ARTIFACT_STORAGE` on the ARM path), **on by
default**, lets them go to a storage account in this resource group instead.

**The Azure Blob backend ships after the GCS one**, so on this cloud the grant deliberately
arrives before the feature. That is the point: it costs an unused subscription nothing, and it is
what stops Azure support from becoming a second apply for every customer later.

### Entra ID, never an account key

This is the only switch here that adds **`dataActions`** to the custom role — the four blob
actions `read`, `write`, `delete` and `add`. Access is therefore by Entra ID and a short-lived
token, exactly like every other action Ringleader takes in your subscription.

`Microsoft.Storage/storageAccounts/listKeys/action` and `listAccountSas/action` are **not**
granted, and that is a decision rather than an omission. An account key is a long-lived static
credential with full data-plane access; handing one over would undo the keyless property this
whole onboarding is built on. If you are comparing this role against a hand-written one, that is
the line to check.

### The two widths, and what "named" does and does not narrow

**Managed** — leave `artifact_storage_account_name` unset. Ringleader creates and converges the
storage account and its containers, so their names, layout and lifecycle rules can change without
you re-applying anything.

**Named** — set it to an account you created. Every account and container **write** and
**delete** is dropped: Ringleader may put blobs in containers you made and may neither create,
reshape nor delete an account or a container. Its location, its lifecycle rules and its
customer-managed key stay yours.

Read the bound carefully, because Azure differs from the other two clouds here. The custom role
is scoped to **this resource group**, as every other action in it is, and Azure offers no
name-prefix condition on these control-plane actions. So naming an account narrows what
Ringleader may **do** — not which account it may reach. If you need the reach narrowed too, put
the storage account in a resource group of its own. This module's boundary is one resource group
and it does not pretend otherwise.

### What you hand back

`artifact_storage_grant` (`managed` or `named`) becomes the `Storage` object's `spec.grant`. On
the named width, hand back `artifact_storage_account_name` **and** the container Ringleader should
write to; on the managed width Ringleader creates both itself, so ask it what it created rather
than guessing.

## Optional: flow logs for the VNet

Virtual network flow logs record the traffic through the VNet: source and destination, ports, bytes,
and whether a network security group allowed it. Compliance scans such as Azure Policy's *Audit
flow logs configuration for every virtual network* expect flow logs on every virtual network. This
onboarding can create them for the VNet it creates. They are VNet flow logs, not NSG flow logs:
Azure stopped accepting new NSG flow logs on June 30, 2025, and retires the rest on September 30,
2027.

Flow logs are off by default, because they cost money and Ringleader does not use them. To turn
them on, set one variable and apply again:

```hcl
create_flow_logs = true
```

On the ARM path, run `deploy.sh` with `CREATE_FLOW_LOGS=true`. Either way the apply adds resources
and changes none you already have. If you bring your own network (`create_network = false`), both
paths refuse the switch, because there is no VNet here to log.

With the switch on, you get a storage account and a flow log:

- The storage account is named `flowlogs` plus a suffix derived from the VNet's id, and is in the
  VNet's region.
- The flow log is on your region's Network Watcher. It writes the VNet's traffic into that account
  and deletes each record after `flow_log_retention_days` (`FLOW_LOG_RETENTION_DAYS`), 365 by
  default.

Both go in the Network Watcher's resource group, not in the one you onboard. Ringleader's custom
role is scoped to the resource group you onboard. With `enable_artifact_storage` on, which is the
default, it can read and delete every blob there, and on the default settings delete the storage
accounts too. The Network Watcher's resource group is outside that scope, so Ringleader can neither
read nor delete the records. Azure requires a flow log to be in its Network Watcher's resource group
too. Both paths refuse a Network Watcher's resource group that is the one you onboard.

Before you apply, check that your region has a Network Watcher and that you can create resources in
its resource group:

- Azure enables a Network Watcher in a region when a VNet is first created there, unless the
  subscription opted out. Azure's automatic watcher is usually named `NetworkWatcher_<region>`, in
  `NetworkWatcherRG`, which is what both paths look for. A watcher created with the Azure CLI is
  named `<region>-watcher` instead, and `az network watcher list` shows yours. If yours differs, set
  `network_watcher_name` and `network_watcher_resource_group_name` (`NETWORK_WATCHER_NAME` and
  `NETWORK_WATCHER_RG`). If there is no watcher, the apply or `deploy.sh` stops and names the one it
  looked for.
- If this apply creates the first VNet in the region, the watcher does not exist until the VNet
  does. The Terraform module reads the watcher after it creates the VNet. If the apply or
  `deploy.sh` still reports no watcher, run it again.
- Contributor on the Network Watcher's resource group is enough to create the resources. Network
  Contributor is not, because a flow log needs the storage account's key actions. The subscription
  also needs the `Microsoft.Insights` resource provider registered:
  `az provider register --namespace Microsoft.Insights`.

**What it costs.** In most regions, $0.50 per GB of flow logs collected after 5 GB free each month
per subscription, plus the blob storage the records take.

**Turning them off again** works differently on the two paths. On the Terraform path,
`create_flow_logs = false` deletes the flow log and the storage account, with every record in it.
`deploy.sh` does not delete them: a later run with `CREATE_FLOW_LOGS=false` leaves both in place, and
you delete them yourself if you want them gone.

## A second region: name it, do not renumber it

An Azure VNet is regional. A second region means a second VNet joined by **global VNet
peering**, which is non-transitive and cannot join overlapping address spaces. Two regions on
one range can never be peered, and the fix at that point is to renumber and re-onboard — so
the allocation has to be right from the **first** apply, not fixed when you need it.

The Terraform module therefore derives the ranges rather than asking you to plan them. Name
your locations in `region_indexes`, and use the **same map in every region**:

```hcl
region_indexes = {
  "eastus"     = 0
  "westeurope" = 1
}
```

The module looks up `var.location`, so those two applies take `10.70.0.0/16` and
`10.71.0.0/16` whichever order you run them in and whichever `tfvars` file you reach for.

**Naming them is required**, from one region onwards, whenever the module creates the landing
pad. There is no signal in a fresh Terraform state that says "this is the second region", so a
module that accepted silence would hand your second apply the first one's range without a word
— the declaration is the signal, and it costs one line:

```hcl
region_indexes = { "eastus" = 0 }   # index 0 is the range you already have
```

Three mistakes are then refused at plan time rather than discovered at the peering: a location
the map does not name, two locations sharing an index, and an index outside `0`–`9`. What no
module can catch is an operator who *replaces* an entry instead of adding one — Terraform
cannot read the other region's state. Keep one map, shared.

Every subnet is carved out of whichever `/16` the VNet took, so there is nothing else to keep
in step:

| index | region | `vnet_address_space` | `subnet_prefix` | `governed_subnet_prefix` | `gateway_subnet_prefix` |
|---|---|---|---|---|---|
| `0` | first | `10.70.0.0/16` | `10.70.1.0/24` | `10.70.224.0/20` | `10.70.240.0/24` |
| `1` | second | `10.71.0.0/16` | `10.71.1.0/24` | `10.71.224.0/20` | `10.71.240.0/24` |
| `2` | third | `10.72.0.0/16` | `10.72.1.0/24` | `10.72.224.0/20` | `10.72.240.0/24` |

Index `0` is what this module has always created, so an existing single-region landing pad
plans as a **no-op** once you name its location at `0` — nothing is renumbered by adopting
this, and the one-line addition is the whole migration. Indexes run `0`–`9`
(`10.70.0.0/16`–`10.79.0.0/16`). Each cloud has a block of its own — AWS `10.60`–`10.69`, Azure
`10.70`–`10.79`, GCP `10.80`–`10.89` — so onboarding all three does not overlap them either.

**Bringing your own IPAM?** Set `vnet_address_space` and the subnets follow it;
`region_indexes` is then ignored and keeping the regions distinct is yours to do. Overriding an
individual subnet still works too.

**The ARM template enforces the same allocation**, through a `regionIndex` parameter that has
no default: the deployment is refused with `Missing input parameters: regionIndex` until you
say which region this is, and the four CIDR parameters become overrides that derive from it
when unset. The two paths produce byte-identical ranges for the same index, so the table above
is the authority for both. An existing deployment keeps every range it has by passing
`regionIndex=0`.

### …and reuse the identity, do not mint a second one

The ranges are only half of a second region. The other half is the **identity**, and the default
is wrong for every region after the first.

An Entra **app registration is tenant-wide** — it has no region and no resource group — while the
custom role this module deploys is scoped to **one** resource group. So a second apply left on the
defaults gives you a second app registration, with its own client id and therefore a second
identity to hand Ringleader, and *neither* of them can act in the other's resource group. Ringleader
uses one credential per namespace for its gateways, so the second one has nowhere to go.

Set `create_identity = false` in every region after the first and pass the first one's two ids:

```hcl
create_identity              = false
existing_client_id           = "…"   # first region: terraform output target_app_client_id
existing_principal_object_id = "…"   # first region: terraform output service_principal_object_id
```

That apply creates no app, no service principal and no federated credential. It deploys the custom
role into **its own** resource group and assigns it to the identity you already have, plus that
region's landing pad. `terraform destroy` in that region then removes that region's grant and
leaves the identity — which is what you want, because another region is still using it.

**Applying twice into one resource group is not a way around this.** It collides on the role
deployment, whose name is the fixed literal `ringleader-onboarding`, and it would mint the second
app anyway: nothing about an app registration is scoped by group or by location, so the identity
problem is untouched by where you point the apply.

**Already applied twice and have two identities?** Nothing needs rebuilding — grant the first
region's principal the second region's role, and hand Ringleader back only the first client id:

```bash
# ids from the FIRST region's outputs, and the role/RG from the SECOND
az role assignment create \
  --assignee-object-id "$(terraform output -raw service_principal_object_id)" \
  --assignee-principal-type ServicePrincipal \
  --role "Ringleader Workstation Operator" \
  --scope "/subscriptions/<subscription-id>/resourceGroups/<second-region-rg>"
```

Then set `create_identity = false` in that region's tfvars before the next apply, so Terraform
stops managing the app it created and does not delete the assignment you just made. The second app
registration is then unused and can be deleted once nothing references it.

Ringleader's proxy VMs are regional, so each region runs its own; nothing here requires the
regions to be joined at all until you want one proxy to serve several. Global VNet peering
also charges for cross-region transfer, which is a second reason to keep a proxy local.

### Checking the allocation without an Azure subscription

The module ships its allocation rules as tests, so a change to them cannot quietly renumber a
landing pad. They mock both providers and only ever `plan`, so they need no credentials:

```console
$ cd azure/terraform && terraform init && terraform test
```

## What you return to Ringleader

| Value | How to get it |
|---|---|
| **app client id** | printed by `deploy.sh` / `terraform output` |
| **tenant id** | `az account show --query tenantId -o tsv` |
| **subscription id** | `az account show --query id -o tsv` |
| **resource group** | the one you scoped |
| **subnet id** (only if you created a network) | `terraform output handoff` |
| **governed subnet id** (only if you turned it on) | `terraform output handoff` — `providerConfig.azure.subnetId` for the workstations that carry an egress policy |
| **additional governed subnet ids** (only if you added them) | `terraform output handoff`, or printed by `deploy.sh`. One for each further namespace that runs a proxy, used on that namespace's workstations only. See [One governed subnet per namespace that runs a proxy](#one-governed-subnet-per-namespace-that-runs-a-proxy) |
| **gateway subnet id** (only if you reserved one) | `terraform output handoff` — goes on the `EgressGateway` as `spec.subnet`, not on a workstation; no gateway VM is built until it has one |
| **`artifact_storage_grant`** (`managed` or `named`) | `terraform output handoff` — the `Storage` object's `spec.grant`, if you want payloads in a storage account of yours |
| **`artifact_storage_account_name`** (named width only) | `terraform output handoff`, with the container Ringleader should write to. On the managed width Ringleader creates both itself |

## Revoking

- **Terraform:** `terraform destroy`.
- **ARM / az:** delete the federated credential (cuts federation, keeps the app):
  `az ad app federated-credential delete --id <appId> --federated-credential-id ringleader-oidc`
  — or delete the app entirely: `az ad app delete --id <appId>`.

More detail: <https://docs.ringleader.dev/cloud-onboarding/azure/>.
