#!/usr/bin/env bash
#
# Revoke Ringleader's GCP access. Default is the non-destructive path: delete the
# Workload Identity Pool, which immediately stops any Ringleader token from
# federating in (the SA and its role grants stay, ready to re-trust). Set FULL=1
# to also delete the onboarding service account.
#
#   PROJECT   your project id            (required)
#   SA        onboarding SA account id   (default: ringleader-workstations)
#   POOL      pool id                    (default: ringleader)
#   FULL      1 to also delete the SA    (default: unset)
#
# A deleted Workload Identity Pool is soft-deleted for 30 days and its id stays
# reserved, so re-onboarding within that window reuses the same id -- onboard.sh
# undeletes it for you.
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT}"
SA="${SA:-ringleader-workstations}"
POOL="${POOL:-ringleader}"
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"

# The pool may already be gone -- a second run, or a revoke before onboarding. Under `set -e`
# a failing delete would abort the script and take the FULL=1 service-account delete below
# with it, so branch on the pool's state instead. `describe` exits 0 for a soft-deleted pool
# as well, so compare the state rather than the exit code.
POOL_STATE=$(gcloud iam workload-identity-pools describe "$POOL" \
  --project "$PROJECT" --location global --format='value(state)' 2>/dev/null || true)
if [ -z "$POOL_STATE" ] || [ "$POOL_STATE" = "DELETED" ]; then
  echo ">> workload identity pool ${POOL} is already gone; nothing to cut"
else
  echo ">> deleting workload identity pool ${POOL} (cuts all federation into ${SA_EMAIL})"
  gcloud iam workload-identity-pools delete "$POOL" \
    --project "$PROJECT" --location global --quiet
  echo ">> done -- Ringleader can no longer federate as ${SA_EMAIL}"
fi

if [ "${FULL:-}" = "1" ]; then
  echo ">> deleting service account ${SA_EMAIL} (removes its role grants too)"
  gcloud iam service-accounts delete "$SA_EMAIL" --project "$PROJECT" --quiet
  echo ">> done"
fi
