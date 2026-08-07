#!/usr/bin/env bash
#
# Verify the Ringleader GCP onboarding: the SA holds the two expected roles, the
# OIDC provider pins your org, and the workloadIdentityUser binding is present.
#
#   PROJECT   your project id                (required)
#   ORG_UID   your Ringleader organization id   (required)
#   SA        onboarding SA account id       (default: ringleader-workstations)
#   POOL      pool id                        (default: ringleader)
#   PROVIDER  provider id                    (default: oidc)
#
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT}"
ORG_UID="${ORG_UID:?set ORG_UID (your Ringleader organization id)}"
SA="${SA:-ringleader-workstations}"
POOL="${POOL:-ringleader}"
PROVIDER="${PROVIDER:-oidc}"
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"
SUBJECT="org:${ORG_UID}"

echo ">> project roles held by ${SA_EMAIL}:"
gcloud projects get-iam-policy "$PROJECT" \
  --flatten='bindings[].members' \
  --filter="bindings.members:${SA_EMAIL}" \
  --format='table(bindings.role)'

echo
echo ">> OIDC provider (issuer / audience / condition):"
gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project "$PROJECT" --location global --workload-identity-pool "$POOL" \
  --format='yaml(oidc.issuerUri, oidc.allowedAudiences, attributeCondition)'

echo
echo ">> workloadIdentityUser bindings on ${SA_EMAIL} (expect the principal for ${SUBJECT}):"
gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --project "$PROJECT" \
  --flatten='bindings[].members' \
  --filter="bindings.role:roles/iam.workloadIdentityUser" \
  --format='value(bindings.members)'
