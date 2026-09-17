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

# The pool may already be gone, after a second run or a revoke before onboarding. Deleting a pool
# that is gone would fail under `set -e` and skip the FULL=1 service-account delete below, so this
# branches on the pool's state instead. `--show-deleted` lists a soft-deleted pool too, with the
# state DELETED, which counts as gone.
#
# The pools are listed in a plain assignment, so a failed call stops this script: an expired
# login, a network error, or a project you cannot read. Reading that failure as "already gone"
# would report federation cut while it is still in place.
POOLS=$(gcloud iam workload-identity-pools list \
  --project "$PROJECT" --location global --show-deleted --format='value(name.basename(),state)')
POOL_STATE=$(printf '%s\n' "$POOLS" | awk -v pool="$POOL" '$1 == pool { print $2 }')
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
