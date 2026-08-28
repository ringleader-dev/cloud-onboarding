#!/usr/bin/env bash
#
# Verify the Ringleader GCP onboarding: the SA holds the three expected roles, the
# OIDC provider pins your org, and the workloadIdentityUser binding is present.
#
#   PROJECT   your project id                (required)
#   ORG_UID   your Ringleader organization id   (required)
#   SA        onboarding SA account id       (default: ringleader-workstations)
#   POOL      pool id                        (default: ringleader)
#   PROVIDER  provider id                    (default: oidc)
#   EGRESS_ROLE  custom egress-control role id, if you enabled it
#                                            (default: ringleaderEgressControl)
#
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT}"
ORG_UID="${ORG_UID:?set ORG_UID (your Ringleader organization id)}"
SA="${SA:-ringleader-workstations}"
POOL="${POOL:-ringleader}"
PROVIDER="${PROVIDER:-oidc}"
EGRESS_ROLE="${EGRESS_ROLE:-ringleaderEgressControl}"
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"
SUBJECT="org:${ORG_UID}"

echo ">> project roles held by ${SA_EMAIL}:"
ROLES="$(gcloud projects get-iam-policy "$PROJECT" \
  --flatten='bindings[].members' \
  --filter="bindings.members:${SA_EMAIL}" \
  --format='value(bindings.role)')"
printf '%s\n' "$ROLES" | sed 's/^/   /'

# The three the workstation lifecycle needs. serviceAccountUser is the one people miss: a GCE
# workstation always runs AS a service account (its own, or the project default compute one), and
# attaching one needs actAs -- so without this role every create fails with a 403 and no
# workstation in this project can boot.
MISSING=""
for ROLE in roles/compute.instanceAdmin.v1 roles/compute.networkUser roles/iam.serviceAccountUser; do
  printf '%s\n' "$ROLES" | grep -qx "$ROLE" || MISSING="${MISSING} ${ROLE}"
done
if [ -n "$MISSING" ]; then
  echo "!! MISSING required role(s):${MISSING}"
  echo "!! re-run ./onboard.sh (idempotent) to add them"
else
  echo ">> all three required roles present"
fi

# Optional extras, reported rather than required -- both are off unless you asked for them.
if printf '%s\n' "$ROLES" | grep -qx "projects/${PROJECT}/roles/${EGRESS_ROLE}"; then
  echo ">> egress control is ON (custom role ${EGRESS_ROLE}):"
  gcloud iam roles describe "$EGRESS_ROLE" --project "$PROJECT" \
    --format='value(includedPermissions)' | tr ';' '\n' | sed 's/^/   /'
else
  echo ">> egress control is off (no ${EGRESS_ROLE} binding); workstations reach whatever your network routes"
fi
if printf '%s\n' "$ROLES" | grep -qx "roles/resourcemanager.projectIamAdmin"; then
  echo ">> workstation runtime identities are ON (roles/resourcemanager.projectIamAdmin is granted)"
fi

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
