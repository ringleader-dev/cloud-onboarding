#!/usr/bin/env bash
#
# Ringleader AWS onboarding via the aws CLI + CloudFormation (OIDC federation, keyless).
# Idempotent -- safe to re-run (it updates the stack in place).
#
# It derives every org-specific value, recomputes the issuer's TLS thumbprint from the
# live chain, substitutes the one placeholder CloudFormation cannot parameterize (the
# trust-policy condition keys), and deploys the stack.
#
# Configure via env vars:
#   ISSUER_URL   Ringleader issuer origin, no trailing slash   (required)
#                  e.g. https://oidc-app.ringleader.dev
#   ORG_UID      your Ringleader organization id (a UUID)      (required)
#   REGION       AWS region for the stack + workstations       (default: us-east-1)
#   STACK_NAME   CloudFormation stack name                     (default: ringleader-onboarding)
#   ROLE_NAME    IAM role name Ringleader assumes              (default: ringleader-workstations)
#   CREATE_NETWORK  true|false: create a landing-pad network   (default: false)
#   SSH_SOURCE_CIDR a single CIDR allowed to SSH (network on)  (default: empty = no inbound)
#   SECONDARY_SSH_SOURCE_CIDR
#                a single CIDR allowed to reach the SECONDARY SSH
#                port, for workstation types that run their own SSH
#                daemon inside the instance                     (default: empty = no inbound)
#   ALLOWED_REGION  bound the role to one region (optional)    (default: $REGION)
#
set -euo pipefail

ISSUER_URL="${ISSUER_URL:?set ISSUER_URL to the Ringleader issuer origin, e.g. https://oidc-app.ringleader.dev}"
ORG_UID="${ORG_UID:?set ORG_UID to your Ringleader organization id, a UUID}"
REGION="${REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-ringleader-onboarding}"
ROLE_NAME="${ROLE_NAME:-ringleader-workstations}"
CREATE_NETWORK="${CREATE_NETWORK:-false}"
SSH_SOURCE_CIDR="${SSH_SOURCE_CIDR:-}"
SECONDARY_SSH_SOURCE_CIDR="${SECONDARY_SSH_SOURCE_CIDR:-}"
ALLOWED_REGION="${ALLOWED_REGION:-$REGION}"

case "$ISSUER_URL" in
  https://*/) echo "ISSUER_URL must not end in a slash" >&2; exit 1 ;;
  https://*) ;;
  *) echo "ISSUER_URL must be an https origin" >&2; exit 1 ;;
esac
if ! printf '%s' "$ORG_UID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  echo "ORG_UID must be a lowercase RFC-4122 UUID" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ISSUER="${ISSUER_URL}/org/${ORG_UID}"                  # the OIDC provider Url + iss claim
AUDIENCE="${ISSUER}/aws"                               # the aud claim + OIDC client id
SUBJECT="org:${ORG_UID}"                               # the sub claim
OIDC_PROVIDER="${ISSUER#https://}"                     # host+path, for the condition keys
ISSUER_HOST="${ISSUER_URL#https://}"

# Recompute the thumbprint from the live TLS chain (SHA-1 of the chain's root CA).
THUMBPRINT="$(echo | openssl s_client -servername "$ISSUER_HOST" -connect "${ISSUER_HOST}:443" -showcerts 2>/dev/null \
  | awk 'BEGIN{c=0} /-----BEGIN CERTIFICATE-----/{c++} {cert[c]=cert[c]$0"\n"} END{printf "%s", cert[c]}' \
  | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
  | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z')"
if ! printf '%s' "$THUMBPRINT" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "failed to compute the issuer TLS thumbprint for ${ISSUER_HOST}" >&2; exit 1
fi

echo ">> region:        $REGION"
echo ">> issuer:        $ISSUER"
echo ">> audience:      $AUDIENCE"
echo ">> subject:       $SUBJECT"
echo ">> thumbprint:    $THUMBPRINT"
echo ">> create network:$CREATE_NETWORK  ssh cidr: ${SSH_SOURCE_CIDR:-<none>}"
echo ">> secondary ssh cidr: ${SECONDARY_SSH_SOURCE_CIDR:-<none>}"

# Substitute the one placeholder CloudFormation cannot parameterize (a condition KEY).
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed "s|__OIDC_PROVIDER__|${OIDC_PROVIDER}|g" "${SCRIPT_DIR}/ringleader-onboarding.yaml" > "$RENDERED"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$RENDERED" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    IssuerUrl="$ISSUER" \
    Audience="$AUDIENCE" \
    Subject="$SUBJECT" \
    Thumbprint="$THUMBPRINT" \
    RoleName="$ROLE_NAME" \
    AllowedRegion="$ALLOWED_REGION" \
    CreateNetwork="$CREATE_NETWORK" \
    SshSourceCidr="$SSH_SOURCE_CIDR" \
    SecondarySshSourceCidr="$SECONDARY_SSH_SOURCE_CIDR"

echo
echo "================ hand these back to Ringleader ================"
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' --output table
echo "=============================================================="
