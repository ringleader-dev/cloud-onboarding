#!/usr/bin/env bash
#
# Ringleader GCP onboarding via gcloud (OIDC / Workload Identity Federation).
# Idempotent -- safe to re-run.
#
# Creates a least-privilege service account Ringleader federates to, grants it three
# predefined roles on the project, and sets up a Workload Identity Pool +
# OIDC provider that trusts Ringleader's per-org issuer for YOUR org only. No
# service-account key is created.
#
# Configure via env vars:
#   PROJECT       your project id                              (required)
#   ISSUER_URL    Ringleader's issuer origin, no trailing slash (required)
#                   e.g. https://oidc-app.ringleader.dev
#   ORG_UID       your Ringleader organization id (a UUID)     (required)
#   SA            onboarding SA account id                     (default: ringleader-workstations)
#   POOL          workload identity pool id                    (default: ringleader)
#   PROVIDER      workload identity provider id                (default: oidc)
#
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
ISSUER_URL="${ISSUER_URL:?set ISSUER_URL to the Ringleader issuer origin, e.g. https://oidc-app.ringleader.dev}"
ORG_UID="${ORG_UID:?set ORG_UID to your Ringleader organization id, a UUID}"
SA="${SA:-ringleader-workstations}"
POOL="${POOL:-ringleader}"
PROVIDER="${PROVIDER:-oidc}"
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"

# Guardrails: a wrong issuer or organization id bakes a subtly-broken trust into your cloud.
case "$ISSUER_URL" in
  https://*/) echo "ISSUER_URL must not end in a slash" >&2; exit 1 ;;
  https://*) ;;
  *) echo "ISSUER_URL must be an https origin" >&2; exit 1 ;;
esac
if ! printf '%s' "$ORG_UID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  echo "ORG_UID must be a lowercase RFC-4122 UUID (as Ringleader gives it to you)" >&2; exit 1
fi

ISSUER="${ISSUER_URL}/org/${ORG_UID}"
SUBJECT="org:${ORG_UID}"
AUDIENCE="${ISSUER}/gcp"

echo ">> project:   $PROJECT"
echo ">> SA:        $SA_EMAIL"
echo ">> issuer:    $ISSUER"
echo ">> subject:   $SUBJECT"

# 0. Enable the APIs this script and the workstation lifecycle need. A fresh, dedicated
#    project -- the project this onboarding recommends -- has none of them on:
#
#      iam                  creating the service account, the pool and the provider
#      cloudresourcemanager setting the two project role bindings below
#      compute              the VM lifecycle, and the optional network landing pad
#      sts / iamcredentials the token exchange and impersonation Ringleader does at run time
#
#    Enabling one that is already on is a no-op.
gcloud services enable \
  iam.googleapis.com cloudresourcemanager.googleapis.com \
  compute.googleapis.com sts.googleapis.com iamcredentials.googleapis.com \
  --project "$PROJECT"

# 1. The onboarding service account.
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA" --project "$PROJECT" \
    --display-name "Ringleader Workstations"
else
  echo ">> service account already exists, reusing"
fi

# 2. Three predefined, least-privilege roles on the project.
#
# These three are the WHOLE grant for a workstation's lifecycle: create, boot, configure, stop,
# start and delete.
#
# The third one is easy to mistake for part of the optional feature below, and is not:
# every workstation VM runs AS a service account, and attaching one requires actAs on it
# (roles/iam.serviceAccountUser), which neither Compute role carries. A GCE workstation
# authenticates to Ringleader with a Google-signed instance identity assertion, which the metadata
# server mints only for a VM that HAS an attached service account -- so Ringleader attaches the
# workstation's declared service account, or this project's DEFAULT COMPUTE service account when it
# declares none. Without this role the first create fails with a 403 on actAs.
#
# It permits acting as any service account in this project, which is why this onboarding wants a
# project DEDICATED to Ringleader workstations. Worth checking what your default compute service
# account holds -- older projects give it roles/editor -- or give workstations a role-less service
# account of their own (providerConfig.gcp.serviceAccount).
for ROLE in roles/compute.instanceAdmin.v1 roles/compute.networkUser roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:${SA_EMAIL}" --role "$ROLE" --condition=None >/dev/null
  echo ">> granted $ROLE"
done

# 2b. OPTIONAL: per-workstation RUNTIME identities (WORKSTATION_IDENTITIES=1).
#
# Lets Ringleader PROVISION a service account per workstation user and BIND ROLES to it. Every
# workstation already runs as a service account without this (step 2); this is only about
# Ringleader creating those accounts and granting them roles. Off by default, because it is not
# free:
#
#   READ THIS -- roles/resourcemanager.projectIamAdmin can grant ANY role in this project to ANY
#   principal, including roles/owner to itself. That is inherent (setting a role binding IS
#   project-IAM administration). Turn it on ONLY in a project dedicated to Ringleader workstations.
#
# Left off, the feature simply fails closed with a 403. To run workstations as your own service
# accounts without it, create them yourself and name one on the workstation
# (providerConfig.gcp.serviceAccount): the actAs grant in step 2 is all Ringleader needs to attach
# an account it did not create.
if [[ "${WORKSTATION_IDENTITIES:-0}" == "1" ]]; then
  for ROLE in roles/iam.serviceAccountAdmin roles/resourcemanager.projectIamAdmin; do
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member "serviceAccount:${SA_EMAIL}" --role "$ROLE" --condition=None >/dev/null
    echo ">> granted $ROLE  (workstation runtime identities)"
  done
fi

# 3. Workload Identity Pool. NOTE: `describe` returns 0 even for a SOFT-DELETED
#    pool (state: DELETED) within its 30-day window, so branch on the state, not
#    on describe's exit code -- otherwise a re-onboard right after revoke would
#    treat the deleted pool as active and the provider create below would fail.
POOL_STATE=$(gcloud iam workload-identity-pools describe "$POOL" \
  --project "$PROJECT" --location global --format='value(state)' 2>/dev/null || true)
if [ -z "$POOL_STATE" ]; then
  gcloud iam workload-identity-pools create "$POOL" \
    --project "$PROJECT" --location global \
    --display-name "Ringleader" \
    --description "Trusts Ringleader's OIDC issuer to run workstation VMs."
elif [ "$POOL_STATE" = "DELETED" ]; then
  echo ">> workload identity pool is soft-deleted; undeleting"
  gcloud iam workload-identity-pools undelete "$POOL" --project "$PROJECT" --location global
else
  echo ">> workload identity pool already active, reusing"
fi

# 4. OIDC provider, pinned to your org by BOTH audience and subject.
if ! gcloud iam workload-identity-pools providers describe "$PROVIDER" \
      --project "$PROJECT" --location global --workload-identity-pool "$POOL" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --project "$PROJECT" --location global --workload-identity-pool "$POOL" \
    --display-name "Ringleader OIDC" \
    --issuer-uri "$ISSUER" \
    --allowed-audiences "$AUDIENCE" \
    --attribute-mapping "google.subject=assertion.sub" \
    --attribute-condition "assertion.sub == '${SUBJECT}'"
else
  echo ">> OIDC provider already exists; updating issuer/audience/condition"
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
    --project "$PROJECT" --location global --workload-identity-pool "$POOL" \
    --issuer-uri "$ISSUER" \
    --allowed-audiences "$AUDIENCE" \
    --attribute-mapping "google.subject=assertion.sub" \
    --attribute-condition "assertion.sub == '${SUBJECT}'"
fi

# 5. Only the federated principal for your org's subject may impersonate the SA.
POOL_NAME=$(gcloud iam workload-identity-pools describe "$POOL" \
  --project "$PROJECT" --location global --format='value(name)')
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project "$PROJECT" \
  --role roles/iam.workloadIdentityUser \
  --member "principal://iam.googleapis.com/${POOL_NAME}/subject/${SUBJECT}" >/dev/null
echo ">> granted workloadIdentityUser to principal for ${SUBJECT}"

PROVIDER_RESOURCE="//iam.googleapis.com/$(gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project "$PROJECT" --location global --workload-identity-pool "$POOL" --format='value(name)')"

cat <<EOF

================ hand these back to Ringleader ================
  target service account : ${SA_EMAIL}
  project id             : ${PROJECT}
  workload id provider   : ${PROVIDER_RESOURCE}
===============================================================
EOF
echo "Run ./network-landing-pad.sh if you need a subnet"
echo "(set SSH_RANGES to be able to open a shell on your workstations)."
