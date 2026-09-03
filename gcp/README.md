# Onboarding Google Cloud

Let a Ringleader control plane run **workstation VMs** in **one of your GCP projects**
with minimum permissions and **no static keys** — by trusting Ringleader's OIDC issuer
through **Workload Identity Federation**.

## The model

```
Ringleader control plane
  |  signs a short-lived OIDC token:  iss = <issuer>/org/<org-id>,  sub = org:<org-id>
  v
Workload Identity Pool + OIDC provider in YOUR project
  |  admits ONLY sub = org:<org-id>  +  the per-org audience
  v
ringleader-workstations@<your-project>   (the service account you create)
  |  roles/compute.instanceAdmin.v1  +  roles/compute.networkUser
  |  +  roles/iam.serviceAccountUser                               (project-scoped)
  v
creates / manages / deletes workstation VMs in YOUR project
```

- **Keyless.** No service-account key is created. Ringleader exchanges its signed token
  for a short-lived federated token and impersonates your service account, bounded by
  the three IAM grants below. Delete the pool and access stops.
- **Pinned to your org.** The provider trusts Ringleader's issuer **and** requires the
  token's subject to be exactly `org:<org-id>` — never a pool-wide wildcard. A
  token minted for any other customer is refused at the token exchange.
- **Least privilege.** The onboarding service account holds only
  `roles/compute.instanceAdmin.v1` (instances and disks), `roles/compute.networkUser`
  (attach a NIC to your subnets) and `roles/iam.serviceAccountUser` (attach a service
  account to a VM it creates — see the next section). No `owner`, `editor`, project-IAM,
  billing, or storage access.

## Every workstation runs as a service account

A GCE workstation proves who it is to Ringleader with a **Google-signed instance identity
assertion**, and the metadata server mints one only for a VM that **has an attached
service account**. So Ringleader attaches one to every workstation it creates: the
service account the workstation declares, or — when it declares none — this project's
**default compute service account**. Attaching one requires `iam.serviceAccounts.actAs`
on it, which is why `roles/iam.serviceAccountUser` is in the base grant above and not
optional: without it the very first create fails with a `403` and no workstation in this
project can boot.

Two consequences worth acting on, both reasons to give Ringleader a **project of its own**:

- **`roles/iam.serviceAccountUser` is project-scoped**, so it permits acting as any
  service account in this project. In a project that also holds a powerful service
  account, this reaches it.
- **Check what your default compute service account holds.** Projects created before
  Google changed the default have `roles/editor` on it, so a workstation that declares no
  identity of its own would run with project editor. Remove that binding if you do not
  want it, or give workstations a purpose-made service account with **no roles at all**
  and name it on the workstation (`providerConfig.gcp.serviceAccount`) — Ringleader
  attaches that one instead, and needs nothing beyond the `actAs` it already has.

## Before you start

Ringleader gives you two values:

- **`ISSUER_URL`** — e.g. `https://oidc-app.ringleader.dev` (no trailing slash).
- **`ORG_UID`** — your Ringleader organization id, a UUID like
  `0192f5bf-af83-7178-8d0a-f1c7aea06bde`.

## Two ways to apply

| Path | Use when |
|---|---|
| **[Terraform](terraform/)** | you manage infra as code |
| **[gcloud](gcloud/)** | you prefer the CLI (idempotent scripts) |

### gcloud quick start

```bash
export PROJECT=my-company-dev-workstations
export ISSUER_URL='https://oidc-app.ringleader.dev'
export ORG_UID='0192f5bf-af83-7178-8d0a-f1c7aea06bde'

cd gcloud
./onboard.sh          # prints the three values to hand back to Ringleader
./verify.sh
# optional, if you don't already have a subnet:
REGION=us-central1 ./network-landing-pad.sh
```

### Terraform quick start

```bash
cd terraform/examples/standalone
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init && terraform apply
terraform output handoff
```

## Reaching your workstations

Ringleader has **no bastion and no SSH tunnel**: `rl shell`, `rl tmux`, port-forwards,
and VS Code Web all dial the workstation on **TCP 22**. Bringing a workstation up needs
only *egress*, so one can finish setting up, report `Ready`, and still be unreachable.

On GCP a workstation gets an **external IP by default** (opt out per workstation with
`providerConfig.gcp.assignPublicIp: false`) — but a custom VPC has **no firewall rules**
and GCP denies ingress by default, so it stays unreachable until you allow 22:

```hcl
create_network    = true
ssh_source_ranges = ["203.0.113.0/24"]   # the CIDRs your engineers connect from
```

That creates one rule (`ringleader-allow-ssh`) targeting the `ringleader-workstation`
network tag, so it applies to your workstations and nothing else. Put the same tag on
the workstations (`providerConfig.gcp.networkTags: [ringleader-workstation]`).

Leave `ssh_source_ranges` empty **only** if you reach the subnet privately (VPN /
Interconnect / peering).

### A second SSH port — opened to the same people as 22

Some Ringleader workstation types run their **own SSH daemon on a secondary port** inside the VM,
while the VM's own sshd keeps 22, and `rl shell` dials that port for such a workstation. To open
it:

```hcl
create_network              = true
secondary_ssh_source_ranges = ["203.0.113.0/24"]
```

(or `SECONDARY_SSH_RANGES=203.0.113.0/24` for `network-landing-pad.sh`). That adds one rule,
`ringleader-allow-secondary-ssh`, targeting the **`ringleader-secondary-ssh`** network tag — so it
reaches only the workstations you tag with it. Put that tag on them **alongside** the first one:

```yaml
providerConfig:
  gcp:
    networkTags: [ringleader-workstation, ringleader-secondary-ssh]
```

Replacing rather than adding would take TCP 22 away with it.

Leave `secondary_ssh_source_ranges` empty — the default — and **no rule is created**; your project
admits exactly what it admits today. Ringleader tells you whether the workstations you plan to run
need this port. You never supply the port number: the module carries it, so it cannot drift from
the port Ringleader dials.

## Optional: let Ringleader create the per-user identities

Ringleader can **provision** a dedicated service account per workstation user and **bind
roles** to it, so one workstation can (say) read one bucket. Every workstation already
runs as a service account without this (above) — what this adds is Ringleader creating
those accounts and granting them roles for you. It is **on by default**, and it is the one
default here most worth a deliberate decision, because it is not free:

| capability | role it needs |
|---|---|
| create/delete the per-user SA | `roles/iam.serviceAccountAdmin` |
| bind roles to it on the project | `roles/resourcemanager.projectIamAdmin` |

`roles/resourcemanager.projectIamAdmin` can grant any role in the project to any principal,
including `roles/owner` to itself. That is inherent — setting a role binding *is* project-IAM
administration — and it is exactly why this onboarding asks for a **project dedicated to
Ringleader workstations**. In a project that holds anything else, set
`enable_workstation_identities = false` (or `WORKSTATION_IDENTITIES=0`); the feature then
fails closed with a `403` and nothing else changes.

You can get the same end result without granting either: create the service accounts and
their role bindings yourself, and name one on the workstation
(`providerConfig.gcp.serviceAccount`). Ringleader attaches an account it did not create
using the `actAs` it already holds.

## Optional: egress control

By default a workstation can reach anything your network routes. Ringleader can narrow that
to an allowlist you declare in the workstation manifest — a set of IP ranges and hostnames —
enforced by VPC firewall rules that Ringleader creates and keeps in step with the manifest.

It is **on by default**, and granting it restricts nothing on its own: until you declare an
egress policy on a workstation, everything behaves exactly as it does today. To opt out:

```hcl
enable_egress_control = false
```
```bash
EGRESS_CONTROL=0 ./onboard.sh    # the gcloud path
```

What that grants is a **custom project role** with ten permissions and nothing else:

| | |
|---|---|
| `compute.firewalls.create` / `delete` / `get` / `list` / `update` | create and maintain the firewall rules that carry each policy |
| `compute.routes.create` / `delete` / `get` / `list` | the static route that steers a workstation's traffic at the DNS / HTTPS proxy, when a policy names hostnames rather than address ranges |
| `compute.networks.updatePolicy` | creating that route additionally requires it — the one that is easy to leave out and hard to diagnose |

Deliberately **not** `roles/compute.securityAdmin`, which is the usual answer and reaches
further than this needs — it also carries Cloud Armor security policies, SSL policies and
certificates. Changing which policy a workstation is on is a network-tag change, which
`roles/compute.instanceAdmin.v1` already permits, so no extra grant is needed for that.

Ringleader compiles each distinct policy into **one** firewall rule targeted by network tag,
so a fleet of a hundred workstations sharing a policy costs one rule rather than a hundred.
The rules are **static** — written when a policy changes, never per connection and never per
DNS answer.

GCP is the easiest of the three clouds to steer, and worth knowing why: a custom static route
can be scoped by **network tag**, so per-policy steering needs no extra subnet. On AWS and
Azure a route table attaches to a *subnet*, so per-policy steering there needs a subnet per
policy.

### What can defeat a policy here, and the priority band that is yours

Nothing in this module changes when a workstation declares a policy, and there is no second
subnet, tag or id to hand back. That is a property of the cloud rather than of the module: a GCE
firewall rule can carry an explicit `denied` clause, so the rule set Ringleader compiles narrows
the workstation on its own. (An AWS security group cannot express a deny at all, which is why
that module ships a **second** security group and asks you to choose between them. GCP and Azure
need no equivalent.)

What *can* defeat a policy is an egress rule of your own, because GCE evaluates firewall rules by
priority and **the lowest number wins**:

| priority | rule |
|---|---|
| `0`–`899` | **yours** — deliberately left free, so you can always override Ringleader in your own VPC |
| `900` | the policy's allowances, written by Ringleader |
| `1000` | the policy's default-deny, written by Ringleader |
| `65535` | GCP's own implied allow-all egress, which the deny above exists to beat |

So an `EGRESS` / `allow` rule of yours below `900` wins over the deny, and a workstation carrying
the policy reaches whatever that rule permits — while Ringleader still reports the policy as
enforced, because it checks the objects it wrote and not yours. That is the intended escape hatch
rather than a defect, but it is worth knowing before the first policy, and it is the one thing on
this cloud that makes an enforced-looking workstation unenforced.

**This module creates no egress rule at all**, so a VPC it built is clear. In a VPC you already
had, check before you rely on a policy:

```bash
gcloud compute firewall-rules list --project "$PROJECT" --filter='direction=EGRESS' \
  --format='table(name, network.basename(), priority, disabled,
                  targetTags.list():label=TARGET_TAGS,
                  destinationRanges.list():label=DEST_RANGES,
                  allowed[].map().firewall_rule().list():label=ALLOW)'
```

Anything there with a priority under 900, an `ALLOW` clause and either no target tags or a tag
your workstations carry is wider than the policy you are about to declare.

### A policy also stops workstations reaching each other

`allow_internal_traffic` (on by default) creates an **ingress** rule, and until a workstation
declares a policy that is the whole story — GCP's implied egress rule is what lets the box open
the connection in the first place. Once it carries a policy, the default-deny applies to what the
box *initiates* too, so workstation-to-workstation traffic stops unless the policy names the
subnet range. If your workflows split work across boxes, list `subnet_cidr` (and any
`additional_regions` range) among that policy's allowed destinations.

### The one thing left as a future opt-in

Google can filter by hostname natively, through **FQDN objects in a firewall *policy* rule**.
It is the only native option on any of the three clouds priced in the same order as running a
small VM, and it may be the right answer for some customers.

It is **not** granted, deliberately, and that is the single exception to this module's
otherwise-everything-on defaults. Taking it needs two further grants:

- **firewall policy management** — `compute.firewallPolicies.create` / `update` / `use` plus
  `compute.networks.setFirewallPolicy`. Policy rules are a different object from the VPC
  firewall rules above, and FQDN objects exist only in them.
- **resource-manager tag administration**, because a policy rule targets a **secure tag**
  rather than the network tags Ringleader already sets. This is the sharp one: tag
  administration is a documented privilege-escalation path in an organization that uses tags
  in IAM conditions, since whoever can set a tag can satisfy a condition written against it.

So it buys a capability nobody has committed to using, at a cost that depends on how your
organization uses tags. If you want it, add a second custom role with those permissions and
bind it to the same service account — nothing else here changes.

## Room for the DNS / HTTPS proxy

Restricting egress by **hostname** (rather than by IP range) needs a resolver that answers
per workstation, and no cloud offers one — so Ringleader runs a small DNS / HTTPS proxy VM in
your project. That VM does not exist yet, but it is worth reserving its address range now:

It is on by default, taking the 241st `/24` of `network_cidr` — `10.80.240.0/24` on a new
landing pad. To skip it:

```hcl
create_gateway_subnet = false
```
```bash
GATEWAY_CIDR=none ./network-landing-pad.sh
```

It creates an **empty subnet** and nothing else. GCP does not bill for a subnet, and Cloud
NAT already covers every range in the region, so the proxy will have upstream egress with no
further setup. Doing it now means the firewall rules that let workstations reach the proxy
can name one stable range instead of one VM's address — and saves renumbering later.

### GCP needs no subnet for the workstations that proxy governs

This is the one place the three onboarding modules deliberately differ, and it is worth knowing
before you compare them.

On AWS and Azure a route table attaches to a *subnet*, so the proxy steers every box in the one it
is given — and since it serves only the boxes it holds a policy for, an ungoverned workstation
sharing that subnet would lose its egress. Both of those modules therefore carve a second subnet
(`create_governed_subnet`, on by default) for the governed fleet.

On GCP the steering route is a custom static route scoped by **network tag** — the same tag
`providerConfig.gcp.networkTags` already sets. A workstation is governed by carrying that tag, and
an untagged workstation on the same subnet is not steered and keeps its egress. So there is
nothing here for a second subnet to fix, and `create_governed_subnet` is **off by default**:

```hcl
create_governed_subnet = true   # its range derives: the 15th /20 of network_cidr
```
```bash
GOVERNED_CIDR=10.80.224.0/20 ./network-landing-pad.sh
```

Turn it on if you want the governed fleet in a range of your own firewall rules can name, or
simply to keep one manifest shape across all three clouds. It buys no isolation the tag does not
already give you. When it is on, `allow_internal_traffic` covers its range too — a workstation
does not stop being a workstation because a proxy steers it.

## Address ranges: declare the block, do not inherit one

This module carves every subnet out of one `/16`, and **it will not guess which one**:

```hcl
network_cidr = "10.80.0.0/16"   # a NEW landing pad
network_cidr = "10.60.0.0/16"   # what this module created BEFORE it derived anything
```

| | `subnet_cidr` | `governed_subnet_cidr` | `gateway_subnet_cidr` |
|---|---|---|---|
| `network_cidr = "10.80.0.0/16"` | `10.80.0.0/20` | `10.80.224.0/20` | `10.80.240.0/24` |
| `network_cidr = "10.60.0.0/16"` | `10.60.0.0/20` | `10.60.224.0/20` | `10.60.240.0/24` |

The second row is byte for byte what the three variables used to default to, so **if you have
already applied this module, declare `10.60.0.0/16` and the plan is a no-op** — nothing is
renumbered and the one line is the whole migration.

For a new landing pad take `10.80.0.0/16`. GCP's block is `10.80`–`10.89`, clear of the AWS
module's `10.60`–`10.69` and the Azure module's `10.70`–`10.79`; the old defaults sat inside
AWS's, so a customer who onboarded both clouds on the documented happy path held two networks a
VPN or an interconnect could never join. One `/16` covers every region — a GCP VPC is global —
and the rest of the block is yours for a second project.

**Why you are asked rather than defaulted.** A subnet's `ip_cidr_range` is force-new, and
Terraform cannot tell a first apply from a hundredth. Moving the default silently would destroy
the subnet every existing workstation sits in; keeping it would leave the overlap in place. The
AWS and Azure modules refuse silence for the same reason, through their `region_indexes` maps.

Bringing your own IPAM? Set `network_cidr` to your range and the three subnets follow it, or
override any of them individually. `additional_regions` is always yours to allocate — nothing
derives it — so keep those ranges inside the same `/16`.

## More than one region

A GCP VPC is a **global** resource whose subnets are regional, and instances in any region
reach each other on internal addresses with no peering. So a second region is one more
subnet in the same VPC, and one proxy VM can serve all of them. (This is materially cheaper
than AWS or Azure, where a second region means a second network and an inter-region link.)

```hcl
additional_regions = {
  "europe-west1"    = "10.80.16.0/20"
  "asia-southeast1" = "10.80.32.0/20"
}
```

Ranges must not overlap, and GCP refuses an overlapping subnet — so a mistake fails the apply
rather than breaking routing later. Nothing derives these from `network_cidr`, so keep them
inside whichever `/16` you gave it and clear of the two egress-control ranges at its top. Each region also gets its own Cloud Router and Cloud NAT,
because both are regional and a subnet without them comes up unable to reach Ringleader.

**Pin the proxy and the workstations it serves to the same zone.** Traffic between two VMs in
one zone is free on GCP; same-region-different-zone is $0.01/GiB, charged to the sender. At 10
TB/month that misplacement costs $100 — more than the `e2-standard-2` the proxy runs on. Zone
is `providerConfig.gcp.zone` on the workstation.

One trap worth naming: on GCP, *all* traffic to or from an **external** IPv4 address leaves the
zone regardless of destination. So a workstation reaching its proxy by public address pays
inter-zone rates while sitting right next to it — use internal addressing between them.

## What you return to Ringleader

| Value | Where it goes |
|---|---|
| **target service account email** | the identity Ringleader impersonates |
| **project id** | where your workstations run |
| **workload identity provider** (`//iam.googleapis.com/projects/…/providers/…`) | the token-exchange audience |
| **subnet self-link** (only if you created a network) | the subnet Ringleader attaches NICs to |
| **gateway subnet self-link** (only if you reserved one) | where the DNS / HTTPS proxy VM will run |
| **governed subnet self-link** (only if you turned it on) | an optional range for the governed fleet. GCP governs by network tag, so this is organizational rather than required |

## Revoking

```bash
cd gcloud
./revoke.sh          # non-destructive: delete the WIF pool, keep the SA (ready to re-trust)
FULL=1 ./revoke.sh   # also delete the SA
```

(Terraform: `terraform destroy`.)

More detail: <https://docs.ringleader.dev/cloud-onboarding/gcp/>.
