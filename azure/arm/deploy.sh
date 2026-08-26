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
#   WORKSTATION_IDENTITIES  1 to also grant the per-workstation runtime-identity
#                actions (see below)                          (default: unset)
#   CREATE_NETWORK  true to also deploy the vnet + subnet + NAT
#                gateway + NSG landing pad                     (default: false)
#   NAME_PREFIX  prefix for the landing pad's resources        (default: ringleader)
#   VNET_CIDR / SUBNET_CIDR  its address space / subnet prefix (defaults: 10.70.0.0/16, 10.70.1.0/24)
#   SSH_SOURCE_CIDR  one CIDR allowed inbound on TCP 22        (default: empty = no inbound rule)
#   SECONDARY_SSH_SOURCE_CIDR  one CIDR allowed inbound on the
#                SECONDARY SSH port, for workstation types that
#                run their own SSH daemon inside the VM        (default: empty = no rule)
#
# WORKSTATION_IDENTITIES=1 lets Ringleader provision a dedicated user-assigned managed
# identity per workstation user and assign roles to it. It adds the Microsoft.ManagedIdentity
# CRUD/assign actions and Microsoft.Authorization roleAssignments write -- which built-in
# Contributor does NOT have either. Scoped to this one resource group. Left off, the feature
# fails closed with a 403.
#
set -euo pipefail

RG="${RG:?set RG to your existing resource group}"
ISSUER_URL="${ISSUER_URL:?set ISSUER_URL to the Ringleader issuer origin, e.g. https://oidc-app.ringleader.dev}"
ORG_UID="${ORG_UID:?set ORG_UID to your Ringleader organization id, a UUID}"
APP_NAME="${APP_NAME:-ringleader-workstations}"
ROLE_NAME="${ROLE_NAME:-Ringleader Workstation Operator}"
CREATE_NETWORK="${CREATE_NETWORK:-false}"
NAME_PREFIX="${NAME_PREFIX:-ringleader}"
VNET_CIDR="${VNET_CIDR:-10.70.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.70.1.0/24}"
SSH_SOURCE_CIDR="${SSH_SOURCE_CIDR:-}"
SECONDARY_SSH_SOURCE_CIDR="${SECONDARY_SSH_SOURCE_CIDR:-}"
if [[ "${WORKSTATION_IDENTITIES:-0}" == "1" ]]; then
  ENABLE_IDENTITIES=true
else
  ENABLE_IDENTITIES=false
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
  --query 'properties.provisioningState' -o tsv

# 4. The OPTIONAL network landing pad, from its own template.
#
#    A SEPARATE file from azuredeploy.json on purpose: that one is also deployed by the Terraform
#    module, which compares Azure's normalized echo of it against the file on every plan, so it
#    may carry no outputs block -- and a network landing pad is useless without one (you need the
#    subnet id back). Deploying them as two deployments keeps both properties.
SUBNET_ID=""
if [ "$CREATE_NETWORK" = "true" ]; then
  echo ">> deploying the network landing pad (${NAME_PREFIX}-vnet, NAT gateway, NSG)"
  echo ">>   inbound 22:   ${SSH_SOURCE_CIDR:-<none>}"
  echo ">>   secondary:    ${SECONDARY_SSH_SOURCE_CIDR:-<none>}"
  SUBNET_ID="$(az deployment group create \
    --resource-group "$RG" \
    --name ringleader-onboarding-network \
    --template-file "${SCRIPT_DIR}/azuredeploy-network.json" \
    --parameters namePrefix="$NAME_PREFIX" vnetCidr="$VNET_CIDR" subnetCidr="$SUBNET_CIDR" \
                 sshSourceCidr="$SSH_SOURCE_CIDR" \
                 secondarySshSourceCidr="$SECONDARY_SSH_SOURCE_CIDR" \
    --query 'properties.outputs.subnetId.value' -o tsv)"
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
echo "==============================================================="
