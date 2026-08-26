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

### A second SSH port — opt-in, and off unless you ask

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
those accounts and granting them roles for you. It is **off by default** because it is
not free:

| capability | role it needs |
|---|---|
| create/delete the per-user SA | `roles/iam.serviceAccountAdmin` |
| bind roles to it on the project | `roles/resourcemanager.projectIamAdmin` |

**`roles/resourcemanager.projectIamAdmin` can grant any role in the project to any
principal — including `roles/owner` to itself.** That is inherent: setting a role
binding *is* project-IAM administration. Enable it (`enable_workstation_identities =
true`) **only in a project dedicated to Ringleader workstations**. Left off, the feature
fails closed with a `403`.

You can get the same end result without granting either: create the service accounts and
their role bindings yourself, and name one on the workstation
(`providerConfig.gcp.serviceAccount`). Ringleader attaches an account it did not create
using the `actAs` it already holds.

## What you return to Ringleader

| Value | Where it goes |
|---|---|
| **target service account email** | the identity Ringleader impersonates |
| **project id** | where your workstations run |
| **workload identity provider** (`//iam.googleapis.com/projects/…/providers/…`) | the token-exchange audience |
| **subnet self-link** (only if you created a network) | the subnet Ringleader attaches NICs to |

## Revoking

```bash
cd gcloud
./revoke.sh          # non-destructive: delete the WIF pool, keep the SA (ready to re-trust)
FULL=1 ./revoke.sh   # also delete the SA
```

(Terraform: `terraform destroy`.)

More detail: <https://docs.ringleader.dev/cloud-onboarding/gcp/>.
