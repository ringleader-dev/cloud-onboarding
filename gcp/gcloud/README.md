# GCP onboarding — gcloud scripts

Shell scripts for teams that prefer the CLI over Terraform. They do exactly what
the [Terraform module](../terraform/) does.

`onboard.sh`, `verify.sh` and `revoke.sh` are idempotent — re-run them freely.
`network-landing-pad.sh` is not: its `gcloud ... create` calls fail if the network
already exists, so run it once, against a project with no Ringleader network yet.

| Script | What it does |
|---|---|
| [`onboard.sh`](onboard.sh) | Creates the onboarding SA, grants the three project roles, and creates a Workload Identity Pool + OIDC provider trusting Ringleader's issuer for your org, plus the `workloadIdentityUser` binding. |
| [`verify.sh`](verify.sh) | Checks the four always-granted roles are present, reports which optional grants are on (and, for artifact storage, which width), then prints the provider's issuer/audience/condition and the impersonation binding. |
| [`revoke.sh`](revoke.sh) | Deletes the WIF pool (cuts federation; default) or also deletes the SA (`FULL=1`). |
| [`network-landing-pad.sh`](network-landing-pad.sh) | Optional: a minimal VPC + subnet + Cloud NAT, an inbound-SSH rule if you set `SSH_RANGES` (with 2222 following it), a workstation-to-workstation rule, a workstation-to-gateway rule admitting them to Ringleader's egress gateway VM by network tag (always created — `ALLOW_INTERNAL=0` does not remove it, since without it hostname-level egress control is a silent outage), an empty range reserved beside the workstations subnet (nothing is placed in it on GCP — the egress gateway VM runs in the workstations' own subnet), and — only if you set `GOVERNED_CIDR` — a subnet for the workstations that gateway governs; prints the subnet self-links. |

Three grants on `onboard.sh` are **on by default**: `WORKSTATION_IDENTITIES` (let Ringleader
create per-user service accounts — the broadest grant here, so read
[`../README.md`](../README.md#optional-let-ringleader-create-the-per-user-identities) before
onboarding a shared project), `EGRESS_CONTROL` (let Ringleader manage the firewall rules
that restrict where workstations connect — a custom role with `compute.firewalls.*`,
`compute.routes.*`, `compute.networks.updatePolicy` and `compute.addresses.*`, fourteen
permissions in all) and `ARTIFACT_STORAGE` (let Ringleader hold artifact payloads in a bucket in
this project rather than in its own — a custom role confined by IAM condition to buckets named
`ringleader-*`, or set `ARTIFACT_STORAGE_BUCKET` to a bucket you made and it narrows to object
access on that one). Set any of them to `0` to skip it.

A fourth grant is **always** made and has no switch: the custom role that lets Ringleader create
and delete the role-less service accounts its own appliances enrol with. GCE mints an instance
identity assertion only for a VM that has a service account attached, so without it an egress
gateway boots, bills, and can never come up. It carries no permission to bind a role, so
everything Ringleader creates with it is role-less by construction.

**Artifact storage narrows in one direction only.** Re-running with `ARTIFACT_STORAGE_BUCKET` set
removes the project-level bindings an earlier default run made. Unsetting it again does not remove
the grant on the bucket you named — the script no longer knows which bucket that was — so remove
that binding yourself; `../README.md`, "Switching between the widths later", has the command.

The root README has
[the full list of defaults](../../README.md#what-is-on-by-default-and-how-to-turn-it-off).

## Quick start

```bash
export PROJECT=my-company-dev-workstations
export ISSUER_URL='https://oidc-app.ringleader.dev'   # Ringleader gives you this
export ORG_UID='0192f5bf-af83-7178-8d0a-f1c7aea06bde' # ...and this

./onboard.sh
./verify.sh
```

`onboard.sh` prints the service account email, project id, and workload identity
provider resource name to hand back to Ringleader. If you ran
`network-landing-pad.sh`, hand back the **workstation** subnet self-link too — but not the
reserved gateway range it prints beside it: nothing is placed in that one, and
`EgressGateway.spec.subnet` is refused on GCP. See
[`../README.md`](../README.md#room-for-the-egress-gateway).

`GOVERNED_CIDR` is empty by default and creates nothing, which is the one place this path
differs from the AWS and Azure ones. There a proxy steers a whole subnet, so a governed fleet
needs a subnet of its own; on GCP the steering route is scoped by **network tag**, so a
workstation is governed by carrying that tag and an untagged neighbour on the same subnet is
untouched. Set `GOVERNED_CIDR=10.80.224.0/20` if you want the governed fleet in its own range
anyway — see [`../README.md`](../README.md#gcp-needs-no-subnet-for-the-workstations-that-proxy-governs).

Adding a region later is one more subnet in the same VPC — a GCP VPC is global — plus its
own Cloud Router and Cloud NAT, which are regional. `network-landing-pad.sh` prints the
exact commands at the end of its run, and the Terraform module does it for you via
`additional_regions`.

## Revoking

```bash
# non-destructive: cut federation, keep the SA
./revoke.sh
# or delete the SA entirely:
FULL=1 ./revoke.sh
```

See [`../README.md`](../README.md) for the trust model and prerequisites.
