# Ringleader cloud onboarding

Infrastructure-as-Code you run **once, in your own cloud account**, so a Ringleader
control plane can create, manage, and tear down **workstation VMs** inside your
account — your subscription, your project, your bill, your network — with only the
**minimum permissions** it needs and never broad account admin.

You apply a small set of assets, then hand a few identifiers back to Ringleader. You
never operate Ringleader's control plane yourself.

> Full documentation: **<https://docs.ringleader.dev/cloud-onboarding/>**.

## How Ringleader authenticates: keyless, pinned to your organization

Ringleader is an OpenID Connect (OIDC) issuer. When it needs to act in your account,
it mints a short-lived, signed token whose subject is **your Ringleader organization
id** and presents it to your cloud. You configure your cloud, once, to trust:

- **Ringleader's issuer**, and
- **only the subject `org:<your-organization-id>`**.

A token minted for any other customer carries a different subject, so your cloud
refuses it. There is no shared secret and no static key to leak — the same mechanism
GitHub Actions uses to deploy into your cloud without a stored key. Revoke by removing
the federation trust, and Ringleader can no longer act in your account.

Ringleader gives you two values to start:

| Value | Example |
|---|---|
| **Issuer URL** | `https://oidc-app.ringleader.dev` |
| **Your organization id** | `0192f5bf-af83-7178-8d0a-f1c7aea06bde` (a UUID) |

Everything below is built from those two values plus your own project / subscription /
account. More on the trust model: <https://docs.ringleader.dev/cloud-onboarding/federation/>.

## Pick your cloud

| Cloud | Boundary | What you create | Assets |
|---|---|---|---|
| **[Google Cloud](gcp/)** | one **project** | a least-privilege **service account** + three project roles + a **Workload Identity Federation** trust | [`terraform/`](gcp/terraform/), [`gcloud/`](gcp/gcloud/) |
| **[Microsoft Azure](azure/)** | one **resource group** | an Entra app + service principal, a **custom role narrower than Contributor**, and a **federated identity credential** | [`terraform/`](azure/terraform/), [`arm/`](azure/arm/) |
| **[AWS](aws/)** | one **account** (optionally one **region**) | an **IAM OIDC provider** + a least-privilege **IAM role**, assumed keyless via `AssumeRoleWithWebIdentity` | [`terraform/`](aws/terraform/), [`cloudformation/`](aws/cloudformation/) |

Each onboarding grants Ringleader a scoped identity inside **one billing/RBAC
boundary** and nothing else — no `owner`/`editor` on GCP, narrower than **Contributor**
on Azure, no account admin on AWS. All three are **keyless**.

Nothing you hand back is a secret: a service-account email, a workload identity
provider's resource name, an application client id, a tenant id are all public
identifiers. Naming a principal grants nothing — the authority is the short-lived token
Ringleader signs, whose subject your trust configuration pins to your organization.

## What a workstation itself can do in your cloud

On **Azure** and **AWS** a workstation VM carries no managed identity and no instance
profile unless an administrator declares one: nothing inside it can act as a cloud
principal.

**GCP is different, and by necessity.** A GCE workstation proves its identity to
Ringleader with a Google-signed instance identity assertion, which the metadata server
mints only for a VM that has an **attached service account** — so every GCP workstation
runs as one: the account it declares, or the project's **default compute service
account**. That is why the GCP module's base grant includes
`roles/iam.serviceAccountUser`, and why it asks for a project dedicated to Ringleader
workstations. Check what your default compute service account holds (older projects give
it `roles/editor`), or give workstations a role-less service account of their own — see
[`gcp/README.md`](gcp/README.md#every-workstation-runs-as-a-service-account).

Letting Ringleader **create** those per-user identities and **bind roles** to them is a
separate switch, `enable_workstation_identities`, and it costs real permissions: on GCP the
power to administer project IAM, on Azure the power to create role assignments, on AWS
`iam:PassRole` under one path. It is **on by default**, along with everything else — see
*What is on by default* below. **On GCP it is the one to think hardest about**, because
`roles/resourcemanager.projectIamAdmin` can grant any role in the project to any principal;
that is why this onboarding asks for a project dedicated to Ringleader workstations, and why
you should set it to `false` in a project that holds anything else.

## Reaching your workstations

Two different things need two different kinds of connectivity — conflate them and you
get a workstation that looks healthy but nobody can use:

| | needs | provided by |
|---|---|---|
| **Bringing the workstation up** (it finishing setup and reporting `Ready`) | **egress** from the VM to the Ringleader control plane | Cloud NAT / NAT gateway — or a public IP |
| **Using the workstation** (`rl shell`, `rl tmux`, port-forwards, VS Code Web) | **inbound TCP 22** to the VM, from wherever you run `rl` | a firewall/NSG rule you choose — or private connectivity |

Ringleader ships **no bastion, no proxy, and no SSH tunnel**. `rl shell` dials the
address the VM publishes on port 22, so a workstation with no inbound path finishes
setting up, reports `Ready`, and still cannot be opened. You have two supported choices:

- **Public + restricted** — set `ssh_source_ranges` to the CIDRs your engineers connect
  from. The module opens 22 to those ranges only.
- **Private only** — leave `ssh_source_ranges` empty and reach the subnet over VPN /
  Interconnect / ExpressRoute / peering. The workstation still comes up on egress alone.

The clouds differ in their default: **GCP** gives every workstation an external IP
unless you opt out; **Azure** gives none unless you opt in (so it needs the NAT gateway
for egress); **AWS** gives one by default. See each cloud's README.

### A second SSH port — opened to the same people as 22

Some Ringleader workstation types run their **own SSH daemon on a secondary port** inside the
VM, while the VM's own sshd keeps 22; `rl shell` dials that port for such a workstation. Others
never use it, and for those the rule is harmless — so rather than making you find out which kind
you are running, every module **follows whatever you set for port 22**:

| Path | Set | Default |
|---|---|---|
| Terraform (all three clouds) | `secondary_ssh_source_ranges` | unset — mirrors `ssh_source_ranges`; `[]` closes it |
| `gcp/gcloud/network-landing-pad.sh` | `SECONDARY_SSH_RANGES` | mirrors `SSH_RANGES`; `none` closes it |
| `aws/cloudformation/deploy.sh` | `SECONDARY_SSH_SOURCE_CIDR` | mirrors `SSH_SOURCE_CIDR`; `none` closes it |
| `azure/arm/deploy.sh` | `SECONDARY_SSH_SOURCE_CIDR` | mirrors `SSH_SOURCE_CIDR`; `none` closes it |

Open nothing for 22 and nothing opens for 2222 either. **You never supply the port number** —
each asset carries it, so it cannot drift from the port Ringleader actually dials.

The clouds differ in how narrowly the rule can be aimed. **GCP** scopes it to its own network tag
(`ringleader-secondary-ssh`), so it reaches only the workstations you tag with it. **AWS** puts it
on the workstations security group, like the rule for 22. **Azure** cannot scope it at all — an
NSG attaches to the subnet and there is no per-VM tag to match — so the source ranges are the only
narrowing, and the rule admits the port to every VM on that subnet.

## Controlling where workstations can connect

A Ringleader workstation reaches anything your network routes, and until now nothing in a
manifest could narrow that. Ringleader can restrict it to an allowlist you declare per
workstation — a set of IP ranges and hostnames — enforced by your cloud's own firewall:
security groups on AWS, VPC firewall rules on GCP, network security groups on Azure.

Enforcing it means Ringleader has to be able to **create and maintain those firewall
objects**, which is more than the read-only network access the base onboarding used to grant.
That grant is now part of the default (`enable_egress_control`); it **restricts nothing on its
own**, because until you declare an egress policy on a workstation, nothing changes.

Each cloud's README lists the precise actions it adds, and every module prints them back as an
output so you can check what you granted rather than take it on trust.

**One cloud asks you to choose, and two do not.** A GCP firewall rule and an Azure NSG can each
express a *deny*, so the object Ringleader compiles a policy into narrows the workstation by
itself: nothing extra to create, and nothing extra to hand back. An AWS security group cannot
express a deny at all, and EC2 **unions** the rules of every group on an interface — so beside the
landing pad's `0.0.0.0/0` egress rule a policy restricts nothing, however correct the group
Ringleader built. The AWS module therefore ships a **second, egress-less security group**, and
which of the two ids you return per workstation is the difference between an enforced policy and a
workstation that refuses to start. See
[which security group a workstation gets](aws/README.md#which-security-group-a-workstation-gets).

Each cloud has one way a correctly-built rule set can still be defeated from outside it, and each
README names its own: an egress firewall rule of yours below priority 900 on
[GCP](gcp/README.md#what-can-defeat-a-policy-here-and-the-priority-band-that-is-yours), an outbound
`Deny` added to the subnet NSG on [Azure](azure/README.md#two-nsgs-at-two-layers--and-which-one-is-yours),
and the wrong security group on [AWS](aws/README.md#which-security-group-a-workstation-gets).

Restricting egress by **hostname** rather than by address range additionally needs a small
**egress gateway** VM in your own account — one that reads the TLS SNI on 443 and the HTTP Host
on 80, checks the name against that workstation's policy, and re-resolves it itself rather than
trusting the address the box was heading for. Ringleader builds and maintains that VM for you on
all three clouds once you declare a policy naming hostnames; it is a **billed** instance, roughly
one to two extra workstations per region, and it is the one object in this whole grant that costs
money without your creating it by name. Every module reserves a subnet for it
(`create_gateway_subnet`), which costs nothing — but what happens to that subnet differs by cloud,
and it is the one handoff detail worth reading twice. **On AWS and Azure the VM goes in it**, and
you hand its id back as `spec.subnet` on the `EgressGateway`: a route table and a UDR attach per
subnet and replace the default route of everything in it, so a proxy sitting in a subnet it steers
would route its own egress into itself — Ringleader therefore builds no gateway VM at all until it
has that id. **On GCP nothing goes in it and you hand it back nowhere**: the steering route there is
scoped by network tag and the proxy carries none, so it runs in the workstations' own subnet
harmlessly and `spec.subnet` is refused. The AWS and Azure modules reserve a **second** subnet
(`create_governed_subnet`) for the workstations that gateway governs; GCP does not need one, for the
same reason — a box there is governed by its network tag rather than by where it sits.

Two things follow that are worth knowing before you budget:

- **Getting the traffic to the proxy is routing, not configuration inside the box.** A
  `HTTPS_PROXY` variable is ergonomics — anyone with root can `unset` it. The enforcement is
  the cloud's own routing plus a default-deny firewall rule, which is why the grant above
  includes route and subnet writes. On GCP a route can be scoped by network tag, so a box is
  governed by carrying that tag and the workstations beside it are untouched. On AWS and Azure
  a route table attaches per subnet, so a proxy steers a whole **subnet** — which is why those
  two modules carve a second one (`create_governed_subnet`) for the workstations it governs.
  One proxy still serves many policies from that one subnet; it tells them apart by source
  address, so this is never a subnet per policy.
- **A steered subnet is governed wholesale, so put only governed workstations in it.** The
  proxy holds a rule per box and refuses a source it has no rule for, so an ungoverned
  workstation sharing a steered subnet loses its egress the moment steering lands. That is the
  whole reason for a second subnet rather than steering the landing pad's own.
- **Put the proxy in the same zone as the workstations it serves.** Same-zone traffic is free
  on all three clouds; cross-zone is $0.01/GB, charged to the sender on GCP and to **both
  sides** on AWS and Azure. At 10 TB/month a misplaced proxy costs $100–$200, which is more
  than the VM it runs on.

### Address ranges — get them right on the FIRST apply

Every module here allocates out of `10.0.0.0/8`, and **each cloud has a block of its own** so
that onboarding more than one does not leave you holding networks that can never be joined:

| Cloud | Block | Declared as |
|---|---|---|
| AWS | `10.60.0.0/16`–`10.69.0.0/16` | `region_indexes` (Terraform), `RegionIndex` (CloudFormation) |
| Azure | `10.70.0.0/16`–`10.79.0.0/16` | `region_indexes` (Terraform), `regionIndex` (ARM) |
| GCP | `10.80.0.0/16`–`10.89.0.0/16` | `network_cidr` (Terraform), `CIDR` (`network-landing-pad.sh`) |

**On every Terraform, CloudFormation and ARM path this has no default, and that is the
mechanism.** Nothing in a fresh Terraform state or a first CloudFormation deploy says "this is
your second region", so a path that guessed would hand it the first one's range in silence — and
on AWS and Azure a second region is a second network that an inter-region link can never join
across overlapping ranges, while on GCP a subnet's range is force-new, so renumbering destroys
the subnet your workstations sit in. Those paths therefore refuse to apply until you say which
allocation this is, and the message names the answer that keeps an existing landing pad exactly
as it is.

`gcp/gcloud/network-landing-pad.sh` is the exception: it is a create-once bootstrap that cannot
renumber anything (it creates the VPC, so a second run fails on the one that exists), so it
simply **defaults** `CIDR` into GCP's block rather than refusing. If you built your landing pad
on the ranges that predate the block split, pass the ones you already have — its own header says
which.

Read your cloud's README before the first apply; the index tables there say which range each
answer produces.

## What is on by default, and how to turn it off

Onboarding grants what Ringleader needs for **every feature available today**, so adopting one
later never means a second onboarding pass and another change-approval cycle. Everything below
is a single variable away from off.

| | What it does | Terraform | Script | Costs money |
|---|---|---|---|---|
| **Landing-pad network** | VPC/VNet + subnet + egress + a security group / NSG | `create_network` | `CREATE_NETWORK` (AWS, Azure), `network-landing-pad.sh` (GCP) | GCP Cloud NAT, Azure NAT gateway + public IP |
| **NAT gateway** (AWS) | private route table, so an instance with no public IP has egress | `create_nat_gateway` | `CREATE_NAT_GATEWAY` | yes — hourly **and $0.045/GB** |
| **Gateway subnet** | where the egress gateway VM runs on AWS and Azure — hand its id back as `EgressGateway.spec.subnet`, and no gateway is built until you do. On GCP a reserved range that stays empty: the VM runs in the workstations subnet and `spec.subnet` is refused | `create_gateway_subnet` | `CREATE_GATEWAY_SUBNET`, `GATEWAY_CIDR` (GCP) | the subnet, no. On AWS and Azure the gateway VM Ringleader puts in it, **yes**; on GCP nothing is placed in it, and the VM still bills — it just runs in the workstations subnet |
| **Governed subnet** | an empty subnet for the workstations that gateway governs. On by default on AWS and Azure, **off on GCP**, which governs by network tag instead | `create_governed_subnet` | `CREATE_GOVERNED_SUBNET`, `GOVERNED_CIDR` (GCP) | no |
| **Egress control** | Ringleader may create and maintain the firewall objects an egress policy compiles to, the routes that steer traffic at the gateway, and the gateway VM itself | `enable_egress_control` | `EGRESS_CONTROL` | only if you declare a policy naming hostnames, which builds the gateway VM |
| **Workstation identities** | Ringleader may create per-user identities and bind roles to them | `enable_workstation_identities` | `WORKSTATION_IDENTITIES` (GCP `onboard.sh`, Azure `deploy.sh`) — **not available on the AWS CloudFormation path**, which grants no `iam:PassRole` at all; use the AWS Terraform module if you want it | no |
| **Workstation-to-workstation** (GCP) | boxes on the subnet can reach each other | `allow_internal_traffic` | `ALLOW_INTERNAL` | no |

Two of these deserve a deliberate decision rather than a default:

- **`enable_workstation_identities` on GCP** grants `roles/resourcemanager.projectIamAdmin`,
  which can grant any role in the project to any principal — including `roles/owner` to
  itself. That is inherent to binding roles, not an artifact of how this is written. It is why
  the onboarding asks for a **dedicated project**; in a shared one, set it to `false`.
- **`allow_internal_traffic` on GCP** widens rather than grants. Off, two workstations cannot
  reach each other at all and a compromised box cannot scan its neighbours. On, they can —
  matching what Azure's default NSG rules already allow.

One capability is deliberately left **off**, and it is the only one: **GCP's own FQDN
filtering**. It lives in firewall *policy* rules targeted by *secure tags*, so taking it would
need firewall-policy management plus resource-manager **tag administration** — and tag
administration is a privilege-escalation path in an organization that uses tags in IAM
conditions. It buys a capability nobody has committed to using, at a cost that depends on how
your organization uses tags, so it stays an explicit opt-in rather than a default.
[`gcp/README.md`](gcp/README.md#the-one-thing-left-as-a-future-opt-in) has what it would take.

**The AWS NAT gateway is worth a second look**, because it is the only default that meters
traffic: $0.045/hour plus **$0.045/GB processed**. Once the proxy ships, private workstations
can egress through it instead and the proxy meters nothing — roughly **$420/month cheaper at 10
TB**. So for a fleet already behind managed NAT, egress control arrives cheaper than the status
quo; for a fleet whose workstations have public addresses, it is new spend. Work out which you
are before you budget for it.

Inbound SSH is the one thing that is **not** on by default and cannot be: `ssh_source_ranges`
is empty until you name the CIDRs your engineers connect from. There is no safe default for
"who may reach your machines", and `0.0.0.0/0` is a decision, never one this module makes for
you. The secondary SSH port then follows whatever you set for 22.

### Already onboarded on the old defaults?

These switches used to default to **off**. Re-applying an existing configuration will now
create the landing pad and widen the grant unless you say otherwise. To keep exactly what you
have today:

```hcl
create_network                = false   # or leave true if you already use this module's network
create_nat_gateway            = false   # AWS only
create_gateway_subnet         = false
create_governed_subnet        = false   # AWS and Azure; already off on GCP
enable_egress_control         = false
enable_workstation_identities = false
allow_internal_traffic        = false   # GCP only
secondary_ssh_source_ranges   = []
```

Run `terraform plan` before applying, as always — the plan is the authority on what changes.

## What you return after applying

Each cloud's README lists the exact values. In short:

- **GCP** — service account email, project id, workload identity provider resource
  name, and (if created) subnet self-link.
- **Azure** — app client id, tenant id, subscription id, resource group, and (if
  created) subnet id.
- **AWS** — role ARN, region, and (if created) subnet id and security group id.

Each module also prints a **governed subnet id** where it created one. That is the subnet you
name on a workstation that carries an **egress policy** — placing a box in it is what puts it
behind the proxy, and mixing governed and ungoverned boxes in one subnet is what Ringleader
refuses.

## Layout

```
README.md              <- you are here
gcp/     README.md + terraform/ + gcloud/
azure/   README.md + terraform/ + arm/
aws/     README.md + terraform/ + cloudformation/
.github/ CI: the checks below, and the trust-pin guard they run
```

## Checks that run on every change

Everything here is applied by you, in your own account, so a broken template is not
something we find out about — these run on every pull request instead, and none of them
needs cloud credentials:

- **`terraform fmt -check` and `terraform validate`** on all six configurations: each
  cloud's module and the `examples/standalone` root a customer actually applies.
- **`terraform test`** for each module that ships a `tests/` directory. Providers are mocked
  and only `plan` runs, so it needs no cloud account.
- **`cfn-lint`** on the AWS CloudFormation template.
- **The AWS trust-pin guard** (`.github/scripts/check_aws_trust_pins.py`) — the one check
  that is about security rather than deployability. The Terraform module and the
  CloudFormation template each pin the assertion's `sub` and `aud` to one organization, and
  the guard fails the build if either stops. It reads past the obvious edits — a dropped
  condition, a `StringLike` in place of `StringEquals`, a wildcard — to the ones that leave
  the condition looking untouched: a `locals` value quietly hardcoded to some other org, a
  role repointed at a different policy document, a second statement slipped in beside the
  pinned one, a template parameter given a default. A renamed block, or any shape the guard
  cannot read, is a loud failure rather than a silent pass. Because every customer's
  assertion is signed by the same issuer, that `sub` condition is the only thing standing
  between your account and every other Ringleader tenant, and its weakened form reads exactly
  like hardening boilerplate. The guard's own failure modes are tested against the real
  templates, so it cannot rot into passing while scanning nothing.

## License

[Apache License 2.0](LICENSE).
