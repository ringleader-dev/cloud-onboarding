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
#   WORKSTATION_IDENTITIES  0 to skip the per-workstation runtime-identity
#                 roles (see step 2b)                          (default: 1, granted)
#   EGRESS_CONTROL          0 to skip the custom role that lets Ringleader
#                 manage the firewall rules restricting workstation egress
#                 (see step 2c)                                (default: 1, granted)
#   EGRESS_ROLE   id of that custom role                       (default: ringleaderEgressControl)
#   IDENTITY_ROLE id of the role that lets Ringleader create the role-less service
#                 accounts its own appliances enrol with (step 2a-bis; always
#                 granted)                                     (default: ringleaderManagedIdentities)
#   ARTIFACT_STORAGE        0 to skip the grant that lets Ringleader hold artifact
#                 payloads in a bucket in THIS project (see step 2d)
#                                                              (default: 1, granted)
#   ARTIFACT_STORAGE_BUCKET a bucket YOU created, to take the narrower "named" width
#                 instead of letting Ringleader create its own  (default: empty, managed)
#   ARTIFACT_STORAGE_ROLE   id of that custom role             (default: ringleaderArtifactStorage)
#
# The defaults grant what Ringleader needs for the features available today, so enabling one
# later does not mean a second onboarding pass. Step 2b is the broadest of them -- read it
# before onboarding a project that holds anything else.
#
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
ISSUER_URL="${ISSUER_URL:?set ISSUER_URL to the Ringleader issuer origin, e.g. https://oidc-app.ringleader.dev}"
ORG_UID="${ORG_UID:?set ORG_UID to your Ringleader organization id, a UUID}"
SA="${SA:-ringleader-workstations}"
POOL="${POOL:-ringleader}"
PROVIDER="${PROVIDER:-oidc}"
EGRESS_ROLE="${EGRESS_ROLE:-ringleaderEgressControl}"
IDENTITY_ROLE="${IDENTITY_ROLE:-ringleaderManagedIdentities}"
ARTIFACT_STORAGE_ROLE="${ARTIFACT_STORAGE_ROLE:-ringleaderArtifactStorage}"
ARTIFACT_STORAGE_BUCKET="${ARTIFACT_STORAGE_BUCKET:-}"
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"

# The prefix every bucket Ringleader creates under the MANAGED width is named with, and the
# bound the IAM condition in step 2d is written against. Ringleader compiles the same string;
# a landing pad admitting a different one grants an authority that matches no bucket, and
# every bucket create fails with a 403 that looks like a Ringleader bug. Not an override, on
# purpose -- it is not the operator's to choose.
MANAGED_BUCKET_PREFIX="ringleader-"

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

# 2a-bis. The identities RINGLEADER creates for its OWN appliances -- always granted, and
# deliberately unable to grant anything.
#
# Some machines Ringleader runs in this project are not workstations: the egress gateway is one.
# They still need an attached service account, because on GCE the metadata server mints the
# instance identity assertion a machine enrols with ONLY for a VM that has one -- so without this
# the appliance boots, bills, and can never come up.
#
# Ringleader creates and deletes those accounts itself rather than asking you to declare them,
# which is what keeps this script from needing an edit every time Ringleader gains a machine. The
# role is exactly that capability and nothing more. It carries NO permission to BIND a role, on
# the project or on the account, so anything Ringleader creates with it is role-less by
# construction -- it can prove which machine it is and do nothing else. Granting a role is step
# 2b's projectIamAdmin, which is a separate, optional decision.
IDENTITY_PERMS="iam.serviceAccounts.create,iam.serviceAccounts.delete,iam.serviceAccounts.get,iam.serviceAccounts.list,iam.serviceAccounts.update"
if gcloud iam roles describe "$IDENTITY_ROLE" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud iam roles update "$IDENTITY_ROLE" --project "$PROJECT" \
    --permissions "$IDENTITY_PERMS" --quiet >/dev/null
  echo ">> updated custom role $IDENTITY_ROLE"
else
  gcloud iam roles create "$IDENTITY_ROLE" --project "$PROJECT" \
    --title "Ringleader Managed Identities" \
    --description "Create and delete the role-less service accounts Ringleader attaches to the machines it runs here." \
    --permissions "$IDENTITY_PERMS" >/dev/null
  echo ">> created custom role $IDENTITY_ROLE"
fi
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role "projects/${PROJECT}/roles/${IDENTITY_ROLE}" --condition=None >/dev/null
echo ">> granted $IDENTITY_ROLE  (identities for Ringleader's own appliances)"

# 2b. Per-workstation runtime identities (on by default; WORKSTATION_IDENTITIES=0 to skip).
#
# Lets Ringleader provision a service account per workstation user and bind roles to it. Every
# workstation already runs as a service account without this (step 2); this is only about
# Ringleader creating those accounts and granting them roles. It is on by default, but it is
# the broadest grant here:
#
#   Worth knowing before you enable it: roles/resourcemanager.projectIamAdmin can grant any role
#   in this project to any principal, including roles/owner to itself. That is inherent --
#   setting a role binding is project-IAM administration -- so use it only in a project
#   dedicated to Ringleader workstations.
#
# Set WORKSTATION_IDENTITIES=0 and the feature fails closed with a 403. To run workstations as
# your own service accounts without it, create them yourself and name one on the workstation
# (providerConfig.gcp.serviceAccount): the actAs grant in step 2 is all Ringleader needs to attach
# an account it did not create.
if [[ "${WORKSTATION_IDENTITIES:-1}" == "1" ]]; then
  for ROLE in roles/iam.serviceAccountAdmin roles/resourcemanager.projectIamAdmin; do
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member "serviceAccount:${SA_EMAIL}" --role "$ROLE" --condition=None >/dev/null
    echo ">> granted $ROLE  (workstation runtime identities)"
  done
fi

# 2c. Egress control (on by default; EGRESS_CONTROL=0 to skip).
#
# Lets Ringleader restrict where your workstations may connect -- an allowlist declared in
# the workstation manifest, enforced by VPC firewall rules Ringleader creates and keeps up
# to date. It restricts nothing on its own: until you declare an egress policy, workstations
# reach whatever your network routes, exactly as they do today.
#
# Ringleader compiles each distinct policy into ONE firewall rule and targets it with a
# network tag, so a fleet sharing a policy costs one rule rather than one per workstation.
# Changing a workstation's policy is a tag change, which instanceAdmin.v1 already permits.
#
# The route permissions are for restricting by HOSTNAME rather than by address range, which
# needs the workstation's traffic to arrive at a Ringleader-run proxy. On GCP that steering is
# a custom static route with a next-hop instance, scoped by the same network tag -- no extra
# subnet, and nothing inside the workstation, where box root could undo it.
#
# A custom role, not roles/compute.securityAdmin: that predefined role is the usual answer and
# is wider than this needs -- it also carries Cloud Armor security policies, SSL policies and
# certificates. The permissions below are what managing VPC firewall rules and routes takes,
# per Google's own documentation.
#
# GCP's own FQDN filtering is NOT granted here. It lives in firewall POLICY rules targeted by
# SECURE tags, so it would need firewall-policy management plus resource-manager tag
# administration -- and tag administration is a privilege-escalation path in an organization
# that uses tags in IAM conditions. It is a deliberate opt-in; see gcp/README.md.
#
# compute.networks.updatePolicy is the one easy to leave out and hard to diagnose: creating a
# custom static route needs it in addition to compute.routes.create.
#
# THE PRIORITY BAND, and the one way a policy is defeated on this cloud. GCE evaluates firewall
# rules lowest-number-first. Ringleader writes a policy's allowances at 900 and its default-deny
# at 1000, both far below GCP's implied allow-all egress at 65535 -- which is what makes the deny
# bite. Everything under 900 is left free ON PURPOSE, so you can always override us in your own
# VPC. The corollary: an EGRESS rule of yours under 900 with an `allow` clause silently defeats
# every policy in that VPC, while Ringleader goes on reporting them enforced, because it checks
# the objects it wrote and not yours. network-landing-pad.sh creates INGRESS rules only. See
# gcp/README.md, "What can defeat a policy here".
if [[ "${EGRESS_CONTROL:-1}" == "1" ]]; then
  # compute.addresses.* is the reserved address for the egress gateway, so the address your
  # upstreams see does not change underneath them: without one the gateway leaves on an ephemeral
  # address, and Ringleader replaces that machine when it fails health, so anything you
  # allowlisted upstream would break at the worst moment. compute.addresses.use is already
  # covered by the base grant.
  EGRESS_PERMS="compute.firewalls.create,compute.firewalls.delete,compute.firewalls.get,compute.firewalls.list,compute.firewalls.update,compute.routes.create,compute.routes.delete,compute.routes.get,compute.routes.list,compute.networks.updatePolicy,compute.addresses.create,compute.addresses.delete,compute.addresses.get,compute.addresses.list"
  if gcloud iam roles describe "$EGRESS_ROLE" --project "$PROJECT" >/dev/null 2>&1; then
    gcloud iam roles update "$EGRESS_ROLE" --project "$PROJECT" \
      --permissions "$EGRESS_PERMS" --quiet >/dev/null
    echo ">> updated custom role $EGRESS_ROLE"
  else
    gcloud iam roles create "$EGRESS_ROLE" --project "$PROJECT" \
      --title "Ringleader Egress Control" \
      --description "Manage the VPC firewall rules that restrict where Ringleader workstations may connect." \
      --permissions "$EGRESS_PERMS" >/dev/null
    echo ">> created custom role $EGRESS_ROLE"
  fi
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:${SA_EMAIL}" \
    --role "projects/${PROJECT}/roles/${EGRESS_ROLE}" --condition=None >/dev/null
  echo ">> granted $EGRESS_ROLE  (egress control)"
fi

# 2d. Artifact storage (on by default; ARTIFACT_STORAGE=0 to skip).
#
# Lets Ringleader put artifact PAYLOADS -- sealed agent-session transcripts, workflow file
# outputs, files a workstation publishes -- in a bucket in this project instead of in a bucket
# Ringleader owns. It is the answer to "which of our data sits in whose account, under whose
# key", and it is the one grant here that is about data rather than about machines.
#
# It grants no bucket and creates no bucket. Which bucket a given Ringleader namespace writes to
# is declared on a Storage object over there, and until one exists nothing is written here.
#
# TWO WIDTHS, picked by ARTIFACT_STORAGE_BUCKET rather than by a second switch:
#
#   MANAGED (ARTIFACT_STORAGE_BUCKET empty). Ringleader creates and converges its own buckets, so
#   their names, layout and lifecycle rules can change without you re-applying anything. Confined
#   by an IAM CONDITION to buckets named ringleader-*, so it reaches nothing else in this
#   project -- a project boundary alone would not be enough, because unlike compute, where the
#   worst case is a machine we created, an unbounded storage grant can READ what is already here.
#
#   NAMED (ARTIFACT_STORAGE_BUCKET set). Object access to that one bucket, bound on the bucket
#   rather than on the project, with no permission to create, reshape or delete a bucket. Its
#   location, lifecycle and default encryption key stay yours, which is what makes CMEK a
#   decision Ringleader never touches.
#
# SWITCHING WIDTHS. Re-running with a bucket named removes the project-level bindings a previous
# managed run made, so narrowing actually narrows. Going the other way -- named back to managed --
# cannot be cleaned up here, because with ARTIFACT_STORAGE_BUCKET now empty the script no longer
# knows which bucket to unbind. Remove that one yourself:
#
#   gcloud storage buckets remove-iam-policy-binding gs://<the bucket you had> \
#     --member "serviceAccount:<the onboarding SA>" \
#     --role "projects/<project>/roles/ringleaderArtifactStorage"
#
# TWO ROLES on the managed width, because storage.buckets.create is authorized against the
# PROJECT and not against the bucket being created -- the bucket does not exist yet -- so an IAM
# condition on resource.name can never match it. It sits alone in a second, unconditioned role
# that can create a bucket and do nothing to any bucket, new or existing.
#
# Withheld in both widths: storage.buckets.setIamPolicy and storage.objects.setIamPolicy (nothing
# here may GRANT authority), storage.hmacKeys.* (a long-lived static credential, and this
# onboarding is keyless throughout) and storage.buckets.list (Ringleader addresses buckets it
# already knows the name of).
if [[ "${ARTIFACT_STORAGE:-1}" == "1" ]]; then
  gcloud services enable storage.googleapis.com --project "$PROJECT"

  # storage.buckets.get is in BOTH widths and is the one easy to leave out: it is what reports
  # the bucket's default encryption key and its location back onto the Storage object. Without it
  # the destination still works and the status can only say "unknown", which is the answer this
  # feature exists to stop having to give.
  STORAGE_PERMS="storage.buckets.get,storage.objects.create,storage.objects.delete,storage.objects.get,storage.objects.list,storage.objects.update"
  # Reshaping a bucket is the managed width's alone. On a bucket you own these would let
  # Ringleader change or delete something of yours, which is the opposite of that width.
  STORAGE_MANAGED_PERMS="storage.buckets.delete,storage.buckets.update"
  # Creating one sits alone in a second role; see the note above on why it cannot be conditioned.
  STORAGE_PROVISION_PERMS="storage.buckets.create"
  STORAGE_ROLE_PERMS="$STORAGE_PERMS"
  if [ -z "$ARTIFACT_STORAGE_BUCKET" ]; then
    STORAGE_ROLE_PERMS="${STORAGE_PERMS},${STORAGE_MANAGED_PERMS}"
  fi

  if gcloud iam roles describe "$ARTIFACT_STORAGE_ROLE" --project "$PROJECT" >/dev/null 2>&1; then
    gcloud iam roles update "$ARTIFACT_STORAGE_ROLE" --project "$PROJECT" \
      --permissions "$STORAGE_ROLE_PERMS" --quiet >/dev/null
    echo ">> updated custom role $ARTIFACT_STORAGE_ROLE"
  else
    gcloud iam roles create "$ARTIFACT_STORAGE_ROLE" --project "$PROJECT" \
      --title "Ringleader Artifact Storage" \
      --description "Read and write the artifact payloads Ringleader holds in this project's Cloud Storage." \
      --permissions "$STORAGE_ROLE_PERMS" >/dev/null
    echo ">> created custom role $ARTIFACT_STORAGE_ROLE"
  fi

  if [ -z "$ARTIFACT_STORAGE_BUCKET" ]; then
    # An object's resource name is projects/_/buckets/<bucket>/objects/<object>, so one prefix
    # test covers the bucket and everything in it, and a request against any other resource --
    # including the project itself -- fails the test and is refused.
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member "serviceAccount:${SA_EMAIL}" \
      --role "projects/${PROJECT}/roles/${ARTIFACT_STORAGE_ROLE}" \
      --condition="title=Ringleader-managed artifact buckets only,description=Only buckets whose name starts with ${MANAGED_BUCKET_PREFIX} and the objects in them,expression=resource.name.startsWith(\"projects/_/buckets/${MANAGED_BUCKET_PREFIX}\")" >/dev/null
    echo ">> granted $ARTIFACT_STORAGE_ROLE  (artifact storage, buckets named ${MANAGED_BUCKET_PREFIX}* only)"

    if gcloud iam roles describe "${ARTIFACT_STORAGE_ROLE}Provision" --project "$PROJECT" >/dev/null 2>&1; then
      gcloud iam roles update "${ARTIFACT_STORAGE_ROLE}Provision" --project "$PROJECT" \
        --permissions "$STORAGE_PROVISION_PERMS" --quiet >/dev/null
      echo ">> updated custom role ${ARTIFACT_STORAGE_ROLE}Provision"
    else
      gcloud iam roles create "${ARTIFACT_STORAGE_ROLE}Provision" --project "$PROJECT" \
        --title "Ringleader Artifact Storage Provisioning" \
        --description "Create the Cloud Storage buckets Ringleader holds artifact payloads in. Carries no access to any bucket." \
        --permissions "$STORAGE_PROVISION_PERMS" >/dev/null
      echo ">> created custom role ${ARTIFACT_STORAGE_ROLE}Provision"
    fi
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member "serviceAccount:${SA_EMAIL}" \
      --role "projects/${PROJECT}/roles/${ARTIFACT_STORAGE_ROLE}Provision" --condition=None >/dev/null
    echo ">> granted ${ARTIFACT_STORAGE_ROLE}Provision  (bucket creation only)"
  else
    # Switching from the managed width must actually NARROW, and `gcloud` is additive: without
    # these two removals the project-level bindings an earlier managed run made would survive, and
    # Ringleader would keep object access across every ${MANAGED_BUCKET_PREFIX}* bucket in this
    # project plus the ability to create more -- exactly the reach this width exists to remove.
    # `--all` removes the binding whatever condition it carries. The roles themselves are left in
    # place unbound, because a deleted custom-role id is reserved for 7 days and an unbound role
    # grants nothing.
    #
    # "There was no such binding" is the normal case -- a first run, or a re-run already on this
    # width -- and is not a failure. Anything ELSE is, and must stop the script: a suppressed error
    # here means printing "narrowed to one bucket" while the wider grant is still in place, which
    # is the exact failure these two lines exist to prevent, one layer down. So the outcome is
    # inspected rather than discarded.
    #
    # The match requires the word BINDING, not a bare "not found": gcloud says "Policy bindings with
    # the specified principal and role not found!" here, while a wrong project or a wrong account
    # says something else entirely that also contains "not found". Misreading a real error as benign
    # is the failure that matters; misreading a benign one as fatal only stops the script with the
    # message printed, which an operator can read and act on. So the pattern errs tight.
    DROP_LOG="$(mktemp)"
    for DROP_ROLE in "${ARTIFACT_STORAGE_ROLE}" "${ARTIFACT_STORAGE_ROLE}Provision"; do
      if ! gcloud projects remove-iam-policy-binding "$PROJECT" \
            --member "serviceAccount:${SA_EMAIL}" \
            --role "projects/${PROJECT}/roles/${DROP_ROLE}" --all >"$DROP_LOG" 2>&1; then
        if grep -qiE 'binding[s]?.*(not found|does not exist)' "$DROP_LOG"; then
          echo ">> no project-level ${DROP_ROLE} binding to remove"
        else
          cat "$DROP_LOG" >&2
          rm -f "$DROP_LOG"
          echo "!! could not remove the project-level ${DROP_ROLE} binding" >&2
          echo "!! stopping: continuing would leave the WIDER managed grant in place beside the" >&2
          echo "!! narrower one you asked for, and report success" >&2
          exit 1
        fi
      else
        echo ">> removed the project-level ${DROP_ROLE} binding (narrowing to one bucket)"
      fi
    done
    rm -f "$DROP_LOG"

    gcloud storage buckets add-iam-policy-binding "gs://${ARTIFACT_STORAGE_BUCKET}" \
      --member "serviceAccount:${SA_EMAIL}" \
      --role "projects/${PROJECT}/roles/${ARTIFACT_STORAGE_ROLE}" >/dev/null
    echo ">> granted $ARTIFACT_STORAGE_ROLE  (artifact storage, on gs://${ARTIFACT_STORAGE_BUCKET} only)"
  fi
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

# What to put on the Storage object over there: its spec.grant, and its spec.bucket on the
# named width. On the managed width Ringleader names the bucket itself, so there is nothing
# here to hand back -- ask it what it created.
if [[ "${ARTIFACT_STORAGE:-1}" != "1" ]]; then
  ARTIFACT_STORAGE_SUMMARY="not granted (payloads stay in Ringleader's own bucket)"
elif [ -z "$ARTIFACT_STORAGE_BUCKET" ]; then
  ARTIFACT_STORAGE_SUMMARY="grant: managed"
else
  ARTIFACT_STORAGE_SUMMARY="grant: named, bucket: ${ARTIFACT_STORAGE_BUCKET}"
fi

PROVIDER_RESOURCE="//iam.googleapis.com/$(gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project "$PROJECT" --location global --workload-identity-pool "$POOL" --format='value(name)')"

cat <<EOF

================ hand these back to Ringleader ================
  target service account : ${SA_EMAIL}
  project id             : ${PROJECT}
  workload id provider   : ${PROVIDER_RESOURCE}
  artifact storage       : ${ARTIFACT_STORAGE_SUMMARY}
===============================================================
EOF
echo "Run ./network-landing-pad.sh if you need a subnet"
echo "(set SSH_RANGES to be able to open a shell on your workstations)."
