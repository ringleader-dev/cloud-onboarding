#!/usr/bin/env bash
#
# Optional: create a minimal network landing pad for Ringleader workstation NICs -- a custom
# VPC, one subnet, Cloud NAT for egress, and (only if you ask for it) one inbound-SSH rule.
# Idempotent-ish (create calls error if resources already exist; re-run only against a clean
# project).
#
#   PROJECT      your project id                     (required)
#   REGION       region for the subnet/NAT           (default: us-central1)
#   CIDR         subnet primary range                (default: 10.60.0.0/20)
#   SSH_RANGES   comma-separated CIDRs allowed to reach workstations on TCP 22
#                (default: empty -- NO inbound rule is created)
#   SSH_TAG      network tag the rule targets        (default: ringleader-workstation)
#
# REACHABILITY -- the part that decides whether your workstations are USABLE.
#
# Coming up only needs EGRESS: a workstation dials the Ringleader control plane out, and
# Cloud NAT below provides that. But `rl shell`, `rl tmux`, port-forwards and VS Code Web all dial
# the workstation on TCP 22 -- Ringleader ships no bastion, no proxy and no SSH tunnel. A
# custom VPC has no firewall rules and GCP denies ingress by default, so WITHOUT
# SSH_RANGES your workstations will come up, report Ready, and be openable by nobody.
#
# Leave SSH_RANGES empty only if you reach this subnet privately (VPN / Interconnect / peering)
# from wherever you run `rl`. Otherwise set it to the CIDRs your engineers connect from:
#
#   SSH_RANGES=203.0.113.0/24 PROJECT=... ./network-landing-pad.sh
#
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
REGION="${REGION:-us-central1}"
CIDR="${CIDR:-10.60.0.0/20}"
SSH_RANGES="${SSH_RANGES:-}"
SSH_TAG="${SSH_TAG:-ringleader-workstation}"

gcloud compute networks create ringleader-vpc --project "$PROJECT" --subnet-mode custom
gcloud compute networks subnets create ringleader-workstations --project "$PROJECT" \
  --network ringleader-vpc --region "$REGION" --range "$CIDR" \
  --enable-private-ip-google-access
gcloud compute routers create ringleader-router --project "$PROJECT" \
  --region "$REGION" --network ringleader-vpc
gcloud compute routers nats create ringleader-nat --project "$PROJECT" \
  --region "$REGION" --router ringleader-router \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges

if [[ -n "$SSH_RANGES" ]]; then
  # Targeted by TAG, so it applies to your workstations and to nothing else in the VPC. Put the
  # same tag on the workstations: providerConfig.gcp.networkTags: [ringleader-workstation]
  gcloud compute firewall-rules create ringleader-allow-ssh --project "$PROJECT" \
    --network ringleader-vpc --direction INGRESS --action allow --rules tcp:22 \
    --source-ranges "$SSH_RANGES" --target-tags "$SSH_TAG"
  echo ">> inbound SSH allowed from ${SSH_RANGES} to VMs tagged ${SSH_TAG}"
else
  echo ">> NOTE: no inbound rule created (SSH_RANGES is empty)."
  echo "   Workstations here will come up but you will NOT be able to 'rl shell' into them"
  echo "   unless you reach this subnet privately (VPN / Interconnect / peering)."
  echo "   To allow SSH: SSH_RANGES=<your-cidr> ./network-landing-pad.sh"
fi

echo
echo ">> subnet self-link (hand back to Ringleader as your workstation subnet):"
gcloud compute networks subnets describe ringleader-workstations \
  --project "$PROJECT" --region "$REGION" --format='value(selfLink)'
