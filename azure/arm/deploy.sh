#!/usr/bin/env bash
#
# Ringleader Azure onboarding via az + ARM (OIDC / Federated Identity Credential).
# Idempotent -- safe to re-run.
#
# Because the Entra app registration and its federated credential are Microsoft
# Graph directory objects (not ARM resources), this wrapper:
#   1. creates the app + service principal with az,
#   2. adds a federated identity credential trusting Ringleader's per-org issuer,
#   3. deploys the ARM template (custom role + assignment) at resource-group scope.
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

cat <<EOF

================ hand these back to Ringleader ================
  app client id    : ${APP_ID}
  tenant id        : ${TENANT_ID}
  subscription id  : ${SUBSCRIPTION_ID}
  resource group   : ${RG}
===============================================================
EOF
