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
separate, optional step, and it costs real permissions (on GCP, the power to administer
project IAM; on Azure, the power to create role assignments). Each module therefore
leaves it **off** and the feature fails closed with a `403` rather than quietly working —
see `enable_workstation_identities` in each cloud's module, and read its warning before
turning it on.

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

### A second SSH port — opt-in, and off unless you ask

Some Ringleader workstation types run their **own SSH daemon on a secondary port** inside the
VM, while the VM's own sshd keeps 22; `rl shell` dials that port for such a workstation. Every
module here can open it and **none of them do by default**:

| Path | Set |
|---|---|
| Terraform (all three clouds) | `secondary_ssh_source_ranges` |
| `gcp/gcloud/network-landing-pad.sh` | `SECONDARY_SSH_RANGES` |
| `aws/cloudformation/deploy.sh` | `SECONDARY_SSH_SOURCE_CIDR` |

Leave them unset and nothing is created — your firewall admits exactly what it admits today.
Ringleader tells you whether the workstations you plan to run need this port; if in doubt, leave
it closed. **You never supply the port number** — each asset carries it, so it cannot drift from
the port Ringleader actually dials.

The clouds differ in how narrowly the rule can be aimed. **GCP** scopes it to its own network tag
(`ringleader-secondary-ssh`), so it reaches only the workstations you tag with it. **AWS** puts it
on the workstations security group, like the rule for 22. **Azure** cannot scope it at all — an
NSG attaches to the subnet and there is no per-VM tag to match — so the source ranges are the only
narrowing, and the rule admits the port to every VM on that subnet.

## Optional: controlling where workstations can connect

A Ringleader workstation reaches anything your network routes, and until now nothing in a
manifest could narrow that. Ringleader can restrict it to an allowlist you declare per
workstation — a set of IP ranges and hostnames — enforced by your cloud's own firewall:
security groups on AWS, VPC firewall rules on GCP, network security groups on Azure.

Enforcing it means Ringleader has to be able to **create and maintain those firewall
objects**, which is more than the read-only network access the base onboarding grants. So it
is a separate, opt-in switch in every module, **off by default**:

| Path | Set |
|---|---|
| Terraform (all three clouds) | `enable_egress_control = true` |
| `gcp/gcloud/onboard.sh` | `EGRESS_CONTROL=1` |
| `aws/cloudformation/deploy.sh` | `EGRESS_CONTROL=true` |
| `azure/arm/deploy.sh` | `EGRESS_CONTROL=1` |

Leave it off and nothing changes — your workstations behave exactly as they do today, and the
grant stays exactly as narrow as it is today. You can turn it on later by re-applying. Each
cloud's README lists the precise actions it adds; every module also prints them back as an
output so you can check what you granted rather than take it on trust.

Restricting egress by **hostname** rather than by IP range additionally needs a small DNS /
HTTPS proxy VM in your own account, because no cloud can answer DNS differently per VM. That
VM is not built yet, but every module can reserve an empty subnet for it now
(`create_gateway_subnet`), which costs nothing and saves renumbering later. If you plan to run
workstations in more than one region, read your cloud's README on address ranges **before the
first apply**: on AWS and Azure a second region is a second network, and joining them later is
impossible if the ranges overlap.

## What you return after applying

Each cloud's README lists the exact values. In short:

- **GCP** — service account email, project id, workload identity provider resource
  name, and (if created) subnet self-link.
- **Azure** — app client id, tenant id, subscription id, resource group, and (if
  created) subnet id.
- **AWS** — role ARN, region, and (if created) subnet id and security group id.

## Layout

```
README.md              <- you are here
gcp/     README.md + terraform/ + gcloud/
azure/   README.md + terraform/ + arm/
aws/     README.md + terraform/ + cloudformation/
```

## License

[Apache License 2.0](LICENSE).
