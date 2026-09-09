#!/usr/bin/env bash
#
# Optional: create a minimal network landing pad for Ringleader workstation NICs -- a custom
# VPC, one subnet, Cloud NAT for egress, and (only if you ask for it) one inbound-SSH rule.
# Idempotent-ish (create calls error if resources already exist; re-run only against a clean
# project).
#
#   PROJECT      your project id                     (required)
#   REGION       region for the subnet/NAT           (default: us-central1)
#   CIDR         subnet primary range                (default: 10.80.0.0/20)
#   SSH_RANGES   comma-separated CIDRs allowed to reach workstations on TCP 22
#                (default: empty -- NO inbound rule is created)
#   SSH_TAG      network tag the rule targets        (default: ringleader-workstation)
#   SECONDARY_SSH_RANGES
#                comma-separated CIDRs allowed to reach the SECONDARY SSH port
#                (default: empty -- NO rule is created)
#   SECONDARY_SSH_TAG
#                network tag that rule targets        (default: ringleader-secondary-ssh)
#   GATEWAY_MANAGEMENT_RANGES
#                comma-separated CIDRs allowed to reach the EGRESS GATEWAY VM on the
#                management ports, so a workstation the gateway steers stays reachable
#                (default: mirrors SSH_RANGES; set to "none" to close it)
#   GATEWAY_CIDR an empty range reserved beside the workstations subnet. Nothing is
#                placed in it on GCP -- see below
#                (default: 10.80.240.0/24; set to "none" to skip it)
#   GOVERNED_CIDR  a subnet for the workstations a gateway governs
#                (default: EMPTY -- none is created; see below)
#   ALLOW_INTERNAL  1 to let workstations reach each other inside the subnet
#                (default: 1; set 0 for the tighter posture)
#
# ADDRESSING -- 10.80.x, and why it is not 10.60.x.
#
# Each cloud's onboarding assets allocate a block of their own: AWS 10.60-10.69, Azure
# 10.70-10.79, GCP 10.80-10.89. They used to overlap -- GCP and AWS both defaulted into 10.60.x
# -- so a customer onboarding both clouds on the documented happy path held two networks that
# could never be joined by a VPN or an interconnect.
#
# This script creates the VPC, so it errors rather than renumbering if one already exists. If
# you built your landing pad on the old defaults and are adding to it, pass the ranges you
# already have (CIDR=10.60.0.0/20, GATEWAY_CIDR=10.60.240.0/24) -- a subnet in the wrong block
# is accepted by GCP and only bites later, at the peering.
#
# The Terraform module derives all three from one network_cidr and refuses to guess it; here
# they are three separate variables because the script cannot do CIDR arithmetic.
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
# REACHING A WORKSTATION AN EGRESS GATEWAY STEERS -- off unless you ask for it.
#
# Once a hostname-level egress policy steers a workstation, that box stops answering on its own
# address from outside this VPC. The steering object is a 0.0.0.0/0 static route, and a default
# route carries the REPLY to a connection the box never opened as much as it carries what the box
# sends: an SSH segment arriving on the workstation's external address is answered towards the
# gateway instead of back the way it came. Egress keeps working; only inbound is gone.
#
# It cannot be fixed inside the box -- a guest routing table does not participate in VPC routing,
# which is the same property that stops a governed box's root defeating the chokepoint. The
# management connection has to TERMINATE at the gateway and reach the box from inside the VPC, and
# on GCP the gateway's inbound firewall is a VPC rule in your project: Ringleader writes only EGRESS
# rules, and GCE has no per-instance firewall object it could own instead.
#
# So this rule FOLLOWS SSH_RANGES, and you need set nothing extra:
#
#   SSH_RANGES=203.0.113.0/24 PROJECT=... ./network-landing-pad.sh
#
# What that admits, exactly. A GCE ingress rule matches by SOURCE RANGE wherever the source sits.
# From OUTSIDE this VPC it opens nothing until you ask Ringleader for
# EgressGateway.spec.publicAddress -- off by default, and the gateway VM has no external address
# before it. From inside, from a network you joined to this VPC (VPN / Interconnect / peering), or
# from any range of yours overlapping CIDR, it takes effect when you run this script -- which is
# the case if your SSH_RANGES are private ranges. Behind it is the appliance's own sshd, which
# accepts only the keys Ringleader puts there, and a port range where nothing listens yet.
#
# So it never widens past the list you already chose for machines in this VPC, and closing it is
# one word:
#
#   GATEWAY_MANAGEMENT_RANGES=none PROJECT=... ./network-landing-pad.sh   # close it
#
# Closed, a steered workstation is reachable only from inside this VPC and reports that on its own
# status (EgressEnforced: True, reason InboundUnreachable) rather than looking healthy while nobody
# can open it. You never supply the ports.
#
set -euo pipefail

# Fixed by Ringleader: a constant, never an input. A wrong number here would be a rule that
# exists, reads correctly in the console, and admits nothing.
SECONDARY_SSH_PORT=2222

# The management port set admitted to the egress gateway VM, in gcloud's --rules spelling. Fixed by
# Ringleader for the same reason SECONDARY_SSH_PORT is, and an ENVELOPE rather than one port: an SSH
# jump host on the appliance answers on 22, a per-box DNAT bastion needs one high port per governed
# box, and admitting both means this landing pad is applied ONCE whichever Ringleader ships.
# 30000-32767 sits below Linux's ephemeral range (32768-60999), so a forwarded port cannot collide
# with a source port the appliance itself is using. A port with no listener behind it is refused
# exactly as if this rule did not exist.
GATEWAY_MANAGEMENT_RULES="tcp:22,tcp:30000-32767"

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
REGION="${REGION:-us-central1}"
CIDR="${CIDR:-10.80.0.0/20}"
SSH_RANGES="${SSH_RANGES:-}"
SSH_TAG="${SSH_TAG:-ringleader-workstation}"
# 2222 follows 22 unless you say otherwise: if you opened one to your engineers you almost
# certainly want the other open to the same people. "none" closes it.
SECONDARY_SSH_RANGES="${SECONDARY_SSH_RANGES:-$SSH_RANGES}"
if [ "$SECONDARY_SSH_RANGES" = "none" ]; then
  SECONDARY_SSH_RANGES=""
fi
SECONDARY_SSH_TAG="${SECONDARY_SSH_TAG:-ringleader-secondary-ssh}"
# The tag Ringleader puts on the egress gateway VM it builds here. Not a knob: nothing of yours
# carries it, and it has to match what Ringleader actually tags or the rule below admits nothing.
GATEWAY_TAG="ringleader-egress-gateway"
# Who may reach that VM on the management ports. Follows SSH_RANGES, like SECONDARY_SSH_RANGES: if
# you opened 22 to your engineers, a policy steering one of their boxes must not be what takes it
# away again. "none" closes it, and an empty SSH_RANGES opens nothing here either. Only one
# assignment carries the default and one turns the "none" sentinel into emptiness -- the same two
# statements SECONDARY_SSH_RANGES above uses, and the only two a reader of this name may see.
GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-$SSH_RANGES}"
if [ "$GATEWAY_MANAGEMENT_RANGES" = "none" ]; then
  GATEWAY_MANAGEMENT_RANGES=""
fi
GATEWAY_CIDR="${GATEWAY_CIDR:-10.80.240.0/24}"
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
# an untagged workstation on the same subnet is untouched. Set GOVERNED_CIDR (10.80.224.0/20 is
# the range the Terraform module derives) if you want the governed fleet in its own range anyway.
GOVERNED_CIDR="${GOVERNED_CIDR:-}"
if [ "$GOVERNED_CIDR" = "none" ]; then
  GOVERNED_CIDR=""
fi
ALLOW_INTERNAL="${ALLOW_INTERNAL:-1}"

gcloud compute networks create ringleader-vpc --project "$PROJECT" --subnet-mode custom
gcloud compute networks subnets create ringleader-workstations --project "$PROJECT" \
  --network ringleader-vpc --region "$REGION" --range "$CIDR" \
  --enable-private-ip-google-access
# A reserved, empty range -- created only if you ask, and it STAYS empty here.
#
# Ringleader's hostname-level egress control points workstations at a proxy that resolves names
# and terminates HTTPS for the hosts you allow, and it builds that VM itself once a policy names
# hostnames. On GCP it builds it in the WORKSTATIONS subnet: the steering route is scoped by
# network tag and the proxy carries none, so it sits beside the boxes without steering itself.
# EgressGateway.spec.subnet is refused on this provider, so do not hand this range back.
# It is carved anyway so the addressing matches the AWS and Azure paths and a later renumbering
# does not collide. GCP does not bill for a subnet.
if [[ -n "$GATEWAY_CIDR" ]]; then
  gcloud compute networks subnets create ringleader-gateway --project "$PROJECT" \
    --network ringleader-vpc --region "$REGION" --range "$GATEWAY_CIDR" \
    --enable-private-ip-google-access
  echo ">> reserved range ringleader-gateway created at ${GATEWAY_CIDR} (stays empty; the gateway VM runs in the workstations subnet)"
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
# The workstation ranges, computed once because two rules name them. The governed subnet counts as
# one when you asked for one: a workstation does not stop being a workstation because a gateway
# steers it.
WORKSTATION_RANGES="$CIDR"
if [[ -n "$GOVERNED_CIDR" ]]; then
  WORKSTATION_RANGES="${CIDR},${GOVERNED_CIDR}"
fi

if [[ "$ALLOW_INTERNAL" == "1" ]]; then
  gcloud compute firewall-rules create ringleader-allow-internal --project "$PROJECT" \
    --network ringleader-vpc --direction INGRESS --action allow \
    --rules tcp,udp,icmp --source-ranges "$WORKSTATION_RANGES" --target-tags "$SSH_TAG"
  echo ">> workstations tagged ${SSH_TAG} can reach each other within ${WORKSTATION_RANGES}"
fi

# Workstation-to-GATEWAY traffic. Without it, hostname-level egress control is a silent total
# outage: Ringleader's proxy VM comes up, the steering route exists, every object check passes, and
# a custom-mode VPC drops every forwarded packet at that VM's own NIC.
#
# It needs its own rule rather than allow-internal because the gateway VM does not carry the
# workstation tag -- it cannot, since Ringleader's steering route is scoped by tag and a gateway
# wearing a workstation's tag would route its traffic into itself. GATEWAY_TAG is fixed by
# Ringleader, like SECONDARY_SSH_PORT: a value that drifted from the one it actually tags would be a
# rule that reads correctly in the console and admits nothing.
#
# It follows no switch, including ALLOW_INTERNAL. That one is a posture choice about lateral movement
# between workstations; this admits them to the one machine that polices their egress, so turning it
# off would harden nothing and break egress control while leaving it looking enforced. Without
# hostname-level egress control there is no gateway VM and the rule admits nobody.
gcloud compute firewall-rules create ringleader-allow-gateway --project "$PROJECT" \
  --network ringleader-vpc --direction INGRESS --action allow \
  --rules tcp,udp,icmp --source-ranges "$WORKSTATION_RANGES" --target-tags "$GATEWAY_TAG"
echo ">> workstations within ${WORKSTATION_RANGES} can reach the egress gateway tagged ${GATEWAY_TAG}"

# INBOUND management to that same VM -- the one rule here that decides whether a workstation an
# egress policy STEERS stays usable. It follows SSH_RANGES; GATEWAY_MANAGEMENT_RANGES=none closes it.
#
# The steering route is a 0.0.0.0/0 static route, so it carries the reply to a connection the box
# never opened: an SSH segment arriving on the workstation's own address is answered towards the
# gateway and the session never establishes. Nothing in the box or on the appliance repairs that --
# the reply is sourced from the box's INTERNAL address, which neither the fabric nor your client
# would accept -- so the management connection has to terminate at the gateway and reach the box
# from inside the VPC. AWS and Azure need no landing-pad change for it, because there the gateway's
# inbound firewall is a security group or an NSG that Ringleader creates and owns; GCE has no
# per-instance firewall object, so on this cloud the admission can only live here.
#
# GATEWAY_MANAGEMENT_RULES is not yours to set. A port set that differed from what Ringleader
# listens on would be a rule that reads correctly in the console and admits nothing, and this
# landing pad cannot be re-applied by us afterwards.
if [[ -n "$GATEWAY_MANAGEMENT_RANGES" ]]; then
  gcloud compute firewall-rules create ringleader-allow-gateway-management --project "$PROJECT" \
    --network ringleader-vpc --direction INGRESS --action allow \
    --rules "$GATEWAY_MANAGEMENT_RULES" \
    --source-ranges "$GATEWAY_MANAGEMENT_RANGES" --target-tags "$GATEWAY_TAG"
  echo ">> ${GATEWAY_MANAGEMENT_RANGES} can reach the egress gateway tagged ${GATEWAY_TAG} on ${GATEWAY_MANAGEMENT_RULES}"
  echo "   Reachable from OUTSIDE this VPC only once EgressGateway.spec.publicAddress is set;"
  echo "   from inside it, or from a network you have joined to it, this is live now."
else
  echo ">> NOTE: no inbound-management rule created (GATEWAY_MANAGEMENT_RANGES is empty or none)."
  echo "   A workstation an egress policy steers will be reachable only from INSIDE this VPC."
  echo "   It reports that itself (EgressEnforced: True, reason InboundUnreachable) rather than"
  echo "   looking healthy while nobody can open it. To allow it:"
  echo "   GATEWAY_MANAGEMENT_RANGES=<your-cidr> ./network-landing-pad.sh"
fi

echo
echo ">> subnet self-link (hand back to Ringleader as your workstation subnet):"
gcloud compute networks subnets describe ringleader-workstations \
  --project "$PROJECT" --region "$REGION" --format='value(selfLink)'

if [[ -n "$GATEWAY_CIDR" ]]; then
  echo
  echo ">> reserved range self-link -- do NOT hand this back. Nothing is placed in it: the"
  echo "   gateway VM runs in the workstations subnet, and EgressGateway.spec.subnet is"
  echo "   refused on GCP. Kept only so the addressing matches the AWS and Azure paths."
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
