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
#   SECONDARY_SSH_RANGES
#                comma-separated CIDRs allowed to reach the SECONDARY SSH port
#                (default: empty -- NO rule is created)
#   SECONDARY_SSH_TAG
#                network tag that rule targets        (default: ringleader-secondary-ssh)
#   GATEWAY_CIDR an empty subnet reserved for the future DNS / HTTPS proxy VM
#                (default: 10.60.240.0/24; set to "none" to skip it)
#   GOVERNED_CIDR  a subnet for the workstations a gateway governs
#                (default: EMPTY -- none is created; see below)
#   ALLOW_INTERNAL  1 to let workstations reach each other inside the subnet
#                (default: 1; set 0 for the tighter posture)
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
# A SECOND SSH PORT -- only if Ringleader tells you your workstations need it.
#
# Some Ringleader workstation types run their OWN SSH daemon on a secondary port inside the VM,
# while the VM's own sshd keeps 22, and `rl shell` dials THAT port for such a workstation. Set
# SECONDARY_SSH_RANGES to open it; leave it empty (the default) and no such rule is created, which
# is the right answer for every workstation type that does not use one. The port itself is fixed
# by Ringleader and this script supplies it -- you never type the number.
#
# It is targeted by its OWN tag, so it applies only to the workstations you tag with it. Put BOTH
# tags on those workstations:
#   providerConfig.gcp.networkTags: [ringleader-workstation, ringleader-secondary-ssh]
#
set -euo pipefail

# Fixed by Ringleader: a constant, never an input. A wrong number here would be a rule that
# exists, reads correctly in the console, and admits nothing.
SECONDARY_SSH_PORT=2222

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
REGION="${REGION:-us-central1}"
CIDR="${CIDR:-10.60.0.0/20}"
SSH_RANGES="${SSH_RANGES:-}"
SSH_TAG="${SSH_TAG:-ringleader-workstation}"
# 2222 follows 22 unless you say otherwise: if you opened one to your engineers you almost
# certainly want the other open to the same people. "none" closes it.
SECONDARY_SSH_RANGES="${SECONDARY_SSH_RANGES:-$SSH_RANGES}"
if [ "$SECONDARY_SSH_RANGES" = "none" ]; then
  SECONDARY_SSH_RANGES=""
fi
SECONDARY_SSH_TAG="${SECONDARY_SSH_TAG:-ringleader-secondary-ssh}"
GATEWAY_CIDR="${GATEWAY_CIDR:-10.60.240.0/24}"
if [ "$GATEWAY_CIDR" = "none" ]; then
  GATEWAY_CIDR=""
fi
# A subnet for the workstations a gateway GOVERNS -- and the one thing here that is off by
# default where the AWS and Azure onboarding paths have it on.
#
# On those clouds a route table attaches to a SUBNET, so a gateway steers every box in the one
# it is given, and a governed fleet needs a range of its own or the ungoverned workstations
# beside it lose their egress. On GCP the steering route is scoped by NETWORK TAG -- the tag
# providerConfig.gcp.networkTags already sets -- so a box is governed by carrying that tag and
# an untagged workstation on the same subnet is untouched. Set GOVERNED_CIDR (10.60.224.0/20 is
# the range the Terraform module uses) if you want the governed fleet in its own range anyway.
GOVERNED_CIDR="${GOVERNED_CIDR:-}"
if [ "$GOVERNED_CIDR" = "none" ]; then
  GOVERNED_CIDR=""
fi
ALLOW_INTERNAL="${ALLOW_INTERNAL:-1}"

gcloud compute networks create ringleader-vpc --project "$PROJECT" --subnet-mode custom
gcloud compute networks subnets create ringleader-workstations --project "$PROJECT" \
  --network ringleader-vpc --region "$REGION" --range "$CIDR" \
  --enable-private-ip-google-access
# A home for the future DNS / HTTPS proxy VM -- created empty, and only if you ask.
#
# Ringleader's hostname-level egress control points workstations at a proxy that resolves
# names and terminates HTTPS for the hosts you allow. That VM is not built yet, but a subnet
# of its own means the firewall rules permitting workstation -> proxy traffic can name one
# stable range rather than one VM's address, and carving it now avoids renumbering later.
# GCP does not bill for a subnet, and Cloud NAT below covers every range in this region.
if [[ -n "$GATEWAY_CIDR" ]]; then
  gcloud compute networks subnets create ringleader-gateway --project "$PROJECT" \
    --network ringleader-vpc --region "$REGION" --range "$GATEWAY_CIDR" \
    --enable-private-ip-google-access
  echo ">> gateway subnet ringleader-gateway created at ${GATEWAY_CIDR}"
fi
if [[ -n "$GOVERNED_CIDR" ]]; then
  gcloud compute networks subnets create ringleader-governed --project "$PROJECT" \
    --network ringleader-vpc --region "$REGION" --range "$GOVERNED_CIDR" \
    --enable-private-ip-google-access
  echo ">> governed subnet ringleader-governed created at ${GOVERNED_CIDR}"
fi

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

if [[ -n "$SECONDARY_SSH_RANGES" ]]; then
  gcloud compute firewall-rules create ringleader-allow-secondary-ssh --project "$PROJECT" \
    --network ringleader-vpc --direction INGRESS --action allow \
    --rules "tcp:${SECONDARY_SSH_PORT}" \
    --source-ranges "$SECONDARY_SSH_RANGES" --target-tags "$SECONDARY_SSH_TAG"
  echo ">> secondary SSH port ${SECONDARY_SSH_PORT} allowed from ${SECONDARY_SSH_RANGES} to VMs tagged ${SECONDARY_SSH_TAG}"
fi

# Workstation-to-workstation traffic, on by default so this matches the Terraform module.
# Without it a custom-mode VPC has no firewall rules and two workstations cannot reach each
# other at all -- a tighter posture, in which a compromised box cannot scan its neighbours.
# Set ALLOW_INTERNAL=0 for that. It never admits anything from outside the subnet.
if [[ "$ALLOW_INTERNAL" == "1" ]]; then
  # The governed subnet counts as a workstation range when you asked for one: a workstation does
  # not stop being a workstation because a gateway steers it.
  INTERNAL_RANGES="$CIDR"
  if [[ -n "$GOVERNED_CIDR" ]]; then
    INTERNAL_RANGES="${CIDR},${GOVERNED_CIDR}"
  fi
  gcloud compute firewall-rules create ringleader-allow-internal --project "$PROJECT" \
    --network ringleader-vpc --direction INGRESS --action allow \
    --rules tcp,udp,icmp --source-ranges "$INTERNAL_RANGES" --target-tags "$SSH_TAG"
  echo ">> workstations tagged ${SSH_TAG} can reach each other within ${INTERNAL_RANGES}"
fi

echo
echo ">> subnet self-link (hand back to Ringleader as your workstation subnet):"
gcloud compute networks subnets describe ringleader-workstations \
  --project "$PROJECT" --region "$REGION" --format='value(selfLink)'

if [[ -n "$GATEWAY_CIDR" ]]; then
  echo
  echo ">> gateway subnet self-link (for the future DNS / HTTPS proxy VM):"
  gcloud compute networks subnets describe ringleader-gateway \
    --project "$PROJECT" --region "$REGION" --format='value(selfLink)'
fi

# Adding a region later: a GCP VPC is global and its subnets are regional, so another region
# is one more subnet in this same VPC -- no peering, and workstations reach each other on
# internal addresses. Cloud Router and Cloud NAT are regional though, so each new region
# needs its own pair:
#
#   gcloud compute networks subnets create ringleader-workstations-<region> \
#     --project <p> --network ringleader-vpc --region <region> --range <non-overlapping cidr> \
#     --enable-private-ip-google-access
#   gcloud compute routers create ringleader-router-<region> \
#     --project <p> --region <region> --network ringleader-vpc
#   gcloud compute routers nats create ringleader-nat-<region> \
#     --project <p> --region <region> --router ringleader-router-<region> \
#     --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
#
# The Terraform module does this for you -- see its additional_regions variable.
