# GCP onboarding — gcloud scripts

Shell scripts for teams that prefer the CLI over Terraform. They do exactly what
the [Terraform module](../terraform/) does.

`onboard.sh`, `verify.sh` and `revoke.sh` are idempotent — re-run them freely.
`network-landing-pad.sh` is not: its `gcloud ... create` calls fail if the network
already exists, so run it once, against a project with no Ringleader network yet.

| Script | What it does |
|---|---|
| [`onboard.sh`](onboard.sh) | Creates the onboarding SA, grants the two Compute roles, and creates a Workload Identity Pool + OIDC provider trusting Ringleader's issuer for your org, plus the `workloadIdentityUser` binding. |
| [`verify.sh`](verify.sh) | Prints the SA's project roles, the provider's issuer/audience/condition, and the impersonation binding. |
| [`revoke.sh`](revoke.sh) | Deletes the WIF pool (cuts federation; default) or also deletes the SA (`FULL=1`). |
| [`network-landing-pad.sh`](network-landing-pad.sh) | Optional: a minimal VPC + subnet + Cloud NAT, plus an inbound-SSH rule if you set `SSH_RANGES`; prints the subnet self-link. |

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

## Revoking

```bash
# non-destructive: cut federation, keep the SA
./revoke.sh
# or delete the SA entirely:
FULL=1 ./revoke.sh
```

See [`../README.md`](../README.md) for the trust model and prerequisites.
