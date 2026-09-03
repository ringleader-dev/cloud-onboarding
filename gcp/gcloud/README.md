# GCP onboarding — gcloud scripts

Shell scripts for teams that prefer the CLI over Terraform. They do exactly what
the [Terraform module](../terraform/) does.

`onboard.sh`, `verify.sh` and `revoke.sh` are idempotent — re-run them freely.
`network-landing-pad.sh` is not: its `gcloud ... create` calls fail if the network
already exists, so run it once, against a project with no Ringleader network yet.

| Script | What it does |
|---|---|
| [`onboard.sh`](onboard.sh) | Creates the onboarding SA, grants the three project roles, and creates a Workload Identity Pool + OIDC provider trusting Ringleader's issuer for your org, plus the `workloadIdentityUser` binding. |
| [`verify.sh`](verify.sh) | Checks the three required roles are present, then prints the provider's issuer/audience/condition and the impersonation binding. |
| [`revoke.sh`](revoke.sh) | Deletes the WIF pool (cuts federation; default) or also deletes the SA (`FULL=1`). |
| [`network-landing-pad.sh`](network-landing-pad.sh) | Optional: a minimal VPC + subnet + Cloud NAT, an inbound-SSH rule if you set `SSH_RANGES` (with 2222 following it), a workstation-to-workstation rule, an empty subnet for the future DNS / HTTPS proxy VM, and — only if you set `GOVERNED_CIDR` — a subnet for the workstations that proxy governs; prints the subnet self-links. |

Two grants on `onboard.sh` are **on by default**: `WORKSTATION_IDENTITIES` (let Ringleader
create per-user service accounts — the broadest grant here, so read
[`../README.md`](../README.md#optional-let-ringleader-create-the-per-user-identities) before
onboarding a shared project) and `EGRESS_CONTROL` (let Ringleader manage the firewall rules
that restrict where workstations connect — a custom role with `compute.firewalls.*`,
`compute.routes.*` and `compute.networks.updatePolicy`, ten permissions in all). Set either to `0` to skip it. The root README has
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
`network-landing-pad.sh`, hand back the printed subnet self-link too.

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
