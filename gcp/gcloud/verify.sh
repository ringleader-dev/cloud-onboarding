#!/usr/bin/env bash
#
# Verify the Ringleader GCP onboarding: the SA holds every role it is always granted, the
# OIDC provider pins your org, and the workloadIdentityUser binding is present.
#
#   PROJECT   your project id                (required)
#   ORG_UID   your Ringleader organization id   (required)
#   SA        onboarding SA account id       (default: ringleader-workstations)
#   POOL      pool id                        (default: ringleader)
#   PROVIDER  provider id                    (default: oidc)
#   EGRESS_ROLE  custom egress-control role id, if you enabled it
#                                            (default: ringleaderEgressControl)
#   IDENTITY_ROLE          custom role for the identities Ringleader's own appliances
#                enrol with, always granted  (default: ringleaderManagedIdentities)
#   ARTIFACT_STORAGE_ROLE  custom artifact-storage role id, if you enabled it
#                                            (default: ringleaderArtifactStorage)
#
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT}"
ORG_UID="${ORG_UID:?set ORG_UID (your Ringleader organization id)}"
SA="${SA:-ringleader-workstations}"
POOL="${POOL:-ringleader}"
PROVIDER="${PROVIDER:-oidc}"
EGRESS_ROLE="${EGRESS_ROLE:-ringleaderEgressControl}"
IDENTITY_ROLE="${IDENTITY_ROLE:-ringleaderManagedIdentities}"
ARTIFACT_STORAGE_ROLE="${ARTIFACT_STORAGE_ROLE:-ringleaderArtifactStorage}"
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
# The custom role Ringleader's own appliances need, granted unconditionally by onboard.sh. An
# onboarding that predates it looks perfectly healthy: workstations boot, the trust federates,
# and the first egress gateway 403s at service-account create and never comes up.
printf '%s\n' "$ROLES" | grep -qx "projects/${PROJECT}/roles/${IDENTITY_ROLE}" \
  || MISSING="${MISSING} projects/${PROJECT}/roles/${IDENTITY_ROLE}"

if [ -n "$MISSING" ]; then
  echo "!! MISSING required role(s):${MISSING}"
  echo "!! re-run ./onboard.sh (idempotent) to add them"
else
  echo ">> all four always-granted roles present"
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

# Artifact storage, and WHICH WIDTH -- the Provision role is the discriminator, because it is
# granted on the managed width alone. On the named width the grant is bound to the bucket rather
# than to the project, so it does not appear in the project policy above at all.
if printf '%s\n' "$ROLES" | grep -qx "projects/${PROJECT}/roles/${ARTIFACT_STORAGE_ROLE}Provision"; then
  echo ">> artifact storage is ON, MANAGED width (custom roles ${ARTIFACT_STORAGE_ROLE} + ${ARTIFACT_STORAGE_ROLE}Provision):"
  gcloud iam roles describe "$ARTIFACT_STORAGE_ROLE" --project "$PROJECT" \
    --format='value(includedPermissions)' | tr ';' '\n' | sed 's/^/   /'
  echo "   a bucket-scoped binding from an EARLIER named-width run is not in the policy above and"
  echo "   is not removed by switching back; check the bucket you used with"
  echo "   gcloud storage buckets get-iam-policy gs://<that bucket>"
  echo ">> the binding that carries them is CONDITIONED; confirm the condition still names your prefix:"
  gcloud projects get-iam-policy "$PROJECT" \
    --flatten='bindings[].members' \
    --filter="bindings.members:${SA_EMAIL} AND bindings.role:projects/${PROJECT}/roles/${ARTIFACT_STORAGE_ROLE}" \
    --format='value(bindings.condition.expression)' | sed 's/^/   /'
elif gcloud iam roles describe "$ARTIFACT_STORAGE_ROLE" --project "$PROJECT" >/dev/null 2>&1; then
  echo ">> artifact storage is ON, NAMED width (custom role ${ARTIFACT_STORAGE_ROLE}, bound on your bucket):"
  gcloud iam roles describe "$ARTIFACT_STORAGE_ROLE" --project "$PROJECT" \
    --format='value(includedPermissions)' | tr ';' '\n' | sed 's/^/   /'
  echo "   the binding is on the bucket, not on this project. Check it with:"
  echo "   gcloud storage buckets get-iam-policy gs://<your-bucket>"
else
  echo ">> artifact storage is off (no ${ARTIFACT_STORAGE_ROLE} role); payloads stay in Ringleader's own bucket"
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
