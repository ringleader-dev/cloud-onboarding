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
  |  roles/compute.instanceAdmin.v1  +  roles/compute.networkUser   (project-scoped)
  v
creates / manages / deletes workstation VMs in YOUR project
```

- **Keyless.** No service-account key is created. Ringleader exchanges its signed token
  for a short-lived federated token and impersonates your service account, bounded by
  the two IAM grants below. Delete the pool and access stops.
- **Pinned to your org.** The provider trusts Ringleader's issuer **and** requires the
  token's subject to be exactly `org:<org-id>` — never a pool-wide wildcard. A
  token minted for any other customer is refused at the token exchange.
- **Least privilege.** The onboarding service account holds only
  `roles/compute.instanceAdmin.v1` (instances and disks) and `roles/compute.networkUser`
  (attach a NIC to your subnets). No `owner`, `editor`, IAM, billing, or storage access.
  The VMs it boots have **no attached service account** unless an admin explicitly
  declares a runtime identity (see below).

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

## Optional: workstations that run AS an identity

Ringleader can boot each workstation as a dedicated per-user service account and bind
roles to it. This is **off by default** because it is not free:

| capability | role it needs |
|---|---|
| create/delete the per-user SA | `roles/iam.serviceAccountAdmin` |
| bind roles to it on the project | `roles/resourcemanager.projectIamAdmin` |
| attach it to a VM (`actAs`) | `roles/iam.serviceAccountUser` |

**`roles/resourcemanager.projectIamAdmin` can grant any role in the project to any
principal — including `roles/owner` to itself.** That is inherent: setting a role
binding *is* project-IAM administration. Enable it (`enable_workstation_identities =
true`) **only in a project dedicated to Ringleader workstations**. Left off, the feature
fails closed with a `403`.

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
