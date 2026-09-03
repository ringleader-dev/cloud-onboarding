#!/usr/bin/env bash
#
# Ringleader Azure onboarding via az + ARM (OIDC / Federated Identity Credential).
# Idempotent -- safe to re-run.
#
# Because the Entra app registration and its federated credential are Microsoft
# Graph directory objects (not ARM resources), this wrapper:
#   1. creates the app + service principal with az,
#   2. adds a federated identity credential trusting Ringleader's per-org issuer,
#   3. deploys the ARM template (custom role + assignment) at resource-group scope,
#   4. optionally deploys the network landing pad (CREATE_NETWORK=true).
#
# Configure via env vars:
#   RG           existing resource group you own              (required)
#   ISSUER_URL   Ringleader issuer origin, no trailing slash  (required)
#                  e.g. https://oidc-app.ringleader.dev
#   ORG_UID      your Ringleader organization id (a UUID)     (required)
#   APP_NAME     Entra app display name                       (default: ringleader-workstations)
#   ROLE_NAME    custom role display name                     (default: Ringleader Workstation Operator)
#   WORKSTATION_IDENTITIES  0 to skip the per-workstation runtime-identity
#                actions (see below)                          (default: 1, granted)
#   EGRESS_CONTROL  0 to skip the NSG actions Ringleader needs to restrict
#                where workstations may connect               (default: 1, granted)
#   CREATE_NETWORK  false to skip the vnet + subnet + NAT gateway
#                + NSG landing pad. Its NAT gateway and public IP
#                bill per hour                                 (default: true)
#   NAME_PREFIX  prefix for the landing pad's resources        (default: ringleader)
#   REGION_INDEX which /16 this region's landing pad takes:     (REQUIRED when
#                the VNet gets 10.(70 + REGION_INDEX).0.0/16      CREATE_NETWORK=true)
#                and every subnet is carved out of it. Give your
#                FIRST region 0 -- that is the range this template
#                has always created, so an existing deployment is
#                unchanged -- and the next region 1. Never reuse an
#                index: two VNets on one range can never be peered.
#   VNET_CIDR / SUBNET_CIDR  overrides; empty derives them from
#                REGION_INDEX                                    (default: empty)
#   SSH_SOURCE_CIDR  one CIDR allowed inbound on TCP 22        (default: empty = no inbound rule)
#   SECONDARY_SSH_SOURCE_CIDR  one CIDR allowed inbound on the
#                secondary SSH port, for workstation types that
#                run their own SSH daemon inside the VM. "none"
#                closes it                     (default: same as SSH_SOURCE_CIDR)
#   CREATE_GATEWAY_SUBNET  false to skip the empty subnet reserved for
#                the egress gateway VM                         (default: true)
#   GATEWAY_SUBNET_CIDR  override; empty derives the 241st /24  (default: empty)
#   CREATE_GOVERNED_SUBNET  false to skip the subnet the workstations
#                a gateway GOVERNS go in                       (default: true)
#   GOVERNED_SUBNET_CIDR  override; empty derives the 15th /20  (default: empty)
#
# The defaults grant what Ringleader needs for the features available today, so enabling one
# later does not mean a second onboarding pass. Only the landing pad costs money.
#
# WORKSTATION_IDENTITIES lets Ringleader provision a dedicated user-assigned managed identity
# per workstation user and assign roles to it. It adds the Microsoft.ManagedIdentity
# CRUD/assign actions and Microsoft.Authorization roleAssignments write, which built-in
# Contributor does not carry either -- still scoped to this one resource group, which is the
# bound that makes it reasonable as a default. Set it to 0 and the feature fails closed
# with a 403.
#
# EGRESS_CONTROL lets Ringleader manage the network security groups that restrict where
# workstations may connect. It adds NSG and security-rule read/write/delete plus join/action,
# still scoped to this resource group, and restricts nothing until you declare an egress
# policy on a workstation. Set it to 0 to skip the grant.
#
set -euo pipefail

RG="${RG:?set RG to your existing resource group}"
ISSUER_URL="${ISSUER_URL:?set ISSUER_URL to the Ringleader issuer origin, e.g. https://oidc-app.ringleader.dev}"
ORG_UID="${ORG_UID:?set ORG_UID to your Ringleader organization id, a UUID}"
APP_NAME="${APP_NAME:-ringleader-workstations}"
ROLE_NAME="${ROLE_NAME:-Ringleader Workstation Operator}"
CREATE_NETWORK="${CREATE_NETWORK:-true}"
NAME_PREFIX="${NAME_PREFIX:-ringleader}"
VNET_CIDR="${VNET_CIDR:-}"
SUBNET_CIDR="${SUBNET_CIDR:-}"

# The landing pad's /16 allocation. There is no default and there deliberately cannot be one:
# nothing here can tell a first region from a second, so a default would hand the second one the
# first one's range in silence, and two VNets on one range can never be peered. An existing
# single-region deployment keeps every range it has by passing 0.
REGION_INDEX="${REGION_INDEX:-}"
if [ "$CREATE_NETWORK" = "true" ] && [ -z "$VNET_CIDR" ] && [ -z "$REGION_INDEX" ]; then
  echo "set REGION_INDEX to which /16 this region's landing pad takes (0-9)." >&2
  echo "  REGION_INDEX=0 is 10.70.0.0/16, the range this template has always created --" >&2
  echo "  pass 0 for your FIRST region and 1 for the next, never the same index twice." >&2
  echo "  Or set VNET_CIDR to allocate the range yourself." >&2
  exit 1
fi
SSH_SOURCE_CIDR="${SSH_SOURCE_CIDR:-}"
# 2222 follows 22 unless you say otherwise: if you opened one to your engineers you almost
# certainly want the other open to the same people. "none" closes it.
SECONDARY_SSH_SOURCE_CIDR="${SECONDARY_SSH_SOURCE_CIDR:-$SSH_SOURCE_CIDR}"
if [ "$SECONDARY_SSH_SOURCE_CIDR" = "none" ]; then
  SECONDARY_SSH_SOURCE_CIDR=""
fi
CREATE_GATEWAY_SUBNET="${CREATE_GATEWAY_SUBNET:-true}"
GATEWAY_SUBNET_CIDR="${GATEWAY_SUBNET_CIDR:-}"
CREATE_GOVERNED_SUBNET="${CREATE_GOVERNED_SUBNET:-true}"
GOVERNED_SUBNET_CIDR="${GOVERNED_SUBNET_CIDR:-}"
if [[ "${WORKSTATION_IDENTITIES:-1}" == "1" ]]; then
  ENABLE_IDENTITIES=true
else
  ENABLE_IDENTITIES=false
fi
if [[ "${EGRESS_CONTROL:-1}" == "1" ]]; then
  ENABLE_EGRESS=true
else
  ENABLE_EGRESS=false
fi

case "$ISSUER_URL" in
  https://*/) echo "ISSUER_URL must not end in a slash" >&2; exit 1 ;;
  https://*) ;;
  *) echo "ISSUER_URL must be an https origin" >&2; exit 1 ;;
esac
if ! printf '%s' "$ORG_UID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  echo "ORG_UID must be a lowercase RFC-4122 UUID" >&2; exit 1
fi

ISSUER="${ISSUER_URL}/org/${ORG_UID}"
SUBJECT="org:${ORG_UID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

echo ">> resource group: $RG"
echo ">> issuer:         $ISSUER"
echo ">> subject:        $SUBJECT"

# 1. The Entra app (create if absent) + its service principal.
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  echo ">> created app $APP_ID"
else
  echo ">> app already exists: $APP_ID"
fi
if [ -z "$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)" ]; then
  az ad sp create --id "$APP_ID" >/dev/null
  echo ">> created service principal"
fi
SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv)"

# 2. The federated identity credential trusting Ringleader's issuer for your org.
#    (Delete-and-recreate makes it idempotent and keeps issuer/subject exact.)
if az ad app federated-credential show --id "$APP_ID" --federated-credential-id ringleader-oidc >/dev/null 2>&1; then
  az ad app federated-credential delete --id "$APP_ID" --federated-credential-id ringleader-oidc
fi
az ad app federated-credential create --id "$APP_ID" --parameters "$(cat <<JSON
{
  "name": "ringleader-oidc",
  "issuer": "${ISSUER}",
  "subject": "${SUBJECT}",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "Ringleader OIDC federation for org ${ORG_UID}."
}
JSON
)" >/dev/null
echo ">> federated credential set (issuer=${ISSUER}, subject=${SUBJECT})"

# 3. The custom role + assignment, scoped to the resource group (ARM).
az deployment group create \
  --resource-group "$RG" \
  --template-file "${SCRIPT_DIR}/azuredeploy.json" \
  --parameters principalId="$SP_OBJECT_ID" roleName="$ROLE_NAME" \
               enableWorkstationIdentities="$ENABLE_IDENTITIES" \
               enableEgressControl="$ENABLE_EGRESS" \
  --query 'properties.provisioningState' -o tsv

# 4. The optional network landing pad, from its own template.
#
#    A separate file from azuredeploy.json on purpose: that one is also deployed by the Terraform
#    module, which compares Azure's normalized echo of it against the file on every plan, so it
#    can carry no outputs block -- and a landing pad is useless without one, since you need the
#    subnet id back. Two deployments keep both properties.
SUBNET_ID=""
if [ "$CREATE_NETWORK" = "true" ]; then
  echo ">> deploying the network landing pad (${NAME_PREFIX}-vnet, NAT gateway, NSG)"
  echo ">>   inbound 22:   ${SSH_SOURCE_CIDR:-<none>}"
  echo ">>   secondary:    ${SECONDARY_SSH_SOURCE_CIDR:-<none>}"
  NETWORK_OUTPUTS="$(az deployment group create \
    --resource-group "$RG" \
    --name ringleader-onboarding-network \
    --template-file "${SCRIPT_DIR}/azuredeploy-network.json" \
    --parameters namePrefix="$NAME_PREFIX" \
                 `# regionIndex has no default in the template, so it must always be passed. The` \
                 `# guard above has already refused an empty one unless VNET_CIDR overrides the` \
                 `# derivation, and on that path the index is inert -- so 0 here is not a guess.` \
                 regionIndex="${REGION_INDEX:-0}" \
                 vnetCidr="$VNET_CIDR" subnetCidr="$SUBNET_CIDR" \
                 sshSourceCidr="$SSH_SOURCE_CIDR" \
                 secondarySshSourceCidr="$SECONDARY_SSH_SOURCE_CIDR" \
                 createGatewaySubnet="$CREATE_GATEWAY_SUBNET" \
                 gatewaySubnetCidr="$GATEWAY_SUBNET_CIDR" \
                 createGovernedSubnet="$CREATE_GOVERNED_SUBNET" \
                 governedSubnetCidr="$GOVERNED_SUBNET_CIDR" \
    --query '[properties.outputs.subnetId.value, properties.outputs.governedSubnetId.value]' -o tsv)"
  SUBNET_ID="$(echo "$NETWORK_OUTPUTS" | sed -n 1p)"
  GOVERNED_SUBNET_ID="$(echo "$NETWORK_OUTPUTS" | sed -n 2p)"
fi

cat <<EOF

================ hand these back to Ringleader ================
  app client id    : ${APP_ID}
  tenant id        : ${TENANT_ID}
  subscription id  : ${SUBSCRIPTION_ID}
  resource group   : ${RG}
EOF
if [ -n "$SUBNET_ID" ]; then
  echo "  subnet id        : ${SUBNET_ID}"
fi
# The governed subnet is where a workstation that carries an egress POLICY goes: a gateway
# steers a whole subnet, so mixing governed and ungoverned boxes in one is what the arm refuses.
if [ -n "${GOVERNED_SUBNET_ID:-}" ]; then
  echo "  governed subnet  : ${GOVERNED_SUBNET_ID}   (use for workstations with an egress policy)"
fi
echo "==============================================================="
