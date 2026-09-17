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
#   4. optionally deploys the network landing pad (CREATE_NETWORK=true),
#   5. optionally records flow logs for its VNet (CREATE_FLOW_LOGS=true).
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
#   ARTIFACT_STORAGE  0 to skip the grant that lets Ringleader hold artifact
#                payloads in a storage account in THIS resource group
#                                                             (default: 1, granted)
#   ARTIFACT_STORAGE_ACCOUNT  a storage account YOU created, to take the
#                narrower "named" width instead of letting Ringleader
#                create its own                               (default: empty, managed)
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
#   SSH_SOURCE_CIDR  one CIDR allowed inbound on TCP 22        (default: empty = no rule of yours)
#   SECONDARY_SSH_SOURCE_CIDR  one CIDR allowed inbound on the
#                secondary SSH port, for workstation types that
#                run their own SSH daemon inside the VM. "none"
#                creates no rule for it        (default: same as SSH_SOURCE_CIDR)
#   GATEWAY_MANAGEMENT_SOURCE_CIDR  one CIDR allowed through the
#                egress gateway subnet's NSG on its management
#                ports, so a workstation an egress policy steers
#                stays reachable. "none" closes it
#                                              (default: same as SSH_SOURCE_CIDR)
#   CREATE_GATEWAY_SUBNET  false to skip the empty subnet reserved for
#                the egress gateway VM                         (default: true)
#   GATEWAY_SUBNET_CIDR  override; empty derives the 241st /24  (default: empty)
#   CREATE_GOVERNED_SUBNET  false to skip the subnet the workstations
#                a gateway GOVERNS go in                       (default: true)
#   GOVERNED_SUBNET_CIDR  override; empty derives the 15th /20  (default: empty)
#   ADDITIONAL_GOVERNED_SUBNETS  more governed subnets, one per namespace
#                that runs its own gateway, as label=cidr pairs
#                separated by commas. List every pair on every run
#                (default: empty, which deletes any the VNet has)
#   CREATE_FLOW_LOGS  true to record VNet flow logs for the landing pad
#                into a storage account created for them. Needs
#                CREATE_NETWORK=true. Bills per GB collected and
#                stored                                          (default: false)
#   FLOW_LOG_RETENTION_DAYS  days each flow record is kept, 1-365 (default: 365)
#   NETWORK_WATCHER_NAME  the region's Network Watcher        (default: NetworkWatcher_<VNet region>)
#   NETWORK_WATCHER_RG  its resource group. The flow log and its
#                storage account are created there, never in RG (default: NetworkWatcherRG)
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
# still scoped to this resource group, and restricts no outbound traffic until you declare an
# egress policy on a workstation. Ringleader also uses it to write its SSH rules, which narrow
# inbound from outside the VNet to TCP 22 and 2222 on a workstation with no policy. Set it to 0
# to skip the grant.
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
# certainly want the other open to the same people. "none" creates no rule for it.
SECONDARY_SSH_SOURCE_CIDR="${SECONDARY_SSH_SOURCE_CIDR:-$SSH_SOURCE_CIDR}"
if [ "$SECONDARY_SSH_SOURCE_CIDR" = "none" ]; then
  SECONDARY_SSH_SOURCE_CIDR=""
fi
# The egress gateway's management ports follow 22 as well: a workstation an egress policy steers is
# reached through the gateway VM, and this is the gateway subnet's half of that admission -- Azure
# evaluates the subnet's NSG before the NSG on the gateway VM's NIC, and both must allow. "none"
# closes it.
GATEWAY_MANAGEMENT_SOURCE_CIDR="${GATEWAY_MANAGEMENT_SOURCE_CIDR:-$SSH_SOURCE_CIDR}"
if [ "$GATEWAY_MANAGEMENT_SOURCE_CIDR" = "none" ]; then
  GATEWAY_MANAGEMENT_SOURCE_CIDR=""
fi
CREATE_GATEWAY_SUBNET="${CREATE_GATEWAY_SUBNET:-true}"
GATEWAY_SUBNET_CIDR="${GATEWAY_SUBNET_CIDR:-}"
CREATE_GOVERNED_SUBNET="${CREATE_GOVERNED_SUBNET:-true}"
GOVERNED_SUBNET_CIDR="${GOVERNED_SUBNET_CIDR:-}"
# More governed subnets, one per namespace that runs its own gateway: a gateway steers a whole
# subnet, and a subnet belongs to one namespace. Each label=cidr pair becomes a subnet named
# governed-<label>, built like the governed subnet above. The VNet's subnets are deployed as one
# list, so a pair left out of a later run deletes that subnet, which Azure refuses while a network
# interface is still in it. List every pair on every run.
ADDITIONAL_GOVERNED_SUBNETS="${ADDITIONAL_GOVERNED_SUBNETS:-}"
ADDITIONAL_GOVERNED_SUBNETS_JSON="{}"
if [ -n "$ADDITIONAL_GOVERNED_SUBNETS" ]; then
  ADDITIONAL_GOVERNED_SUBNETS_JSON=""
  GOVERNED_REST="${ADDITIONAL_GOVERNED_SUBNETS},"
  while [ -n "$GOVERNED_REST" ]; do
    pair="${GOVERNED_REST%%,*}"
    GOVERNED_REST="${GOVERNED_REST#*,}"
    label="${pair%%=*}"
    cidr="${pair#*=}"
    if ! printf '%s' "$label" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' ||
      ! printf '%s' "$cidr" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
      echo "ADDITIONAL_GOVERNED_SUBNETS entry '$pair' is not label=cidr, with a label of lowercase letters, digits and hyphens, e.g. team-a=10.70.208.0/20" >&2
      exit 1
    fi
    case ",$ADDITIONAL_GOVERNED_SUBNETS_JSON," in
      *"\"$label\":"*) echo "ADDITIONAL_GOVERNED_SUBNETS names the label '$label' twice" >&2; exit 1 ;;
    esac
    ADDITIONAL_GOVERNED_SUBNETS_JSON="${ADDITIONAL_GOVERNED_SUBNETS_JSON:+$ADDITIONAL_GOVERNED_SUBNETS_JSON,}\"$label\":\"$cidr\""
  done
  ADDITIONAL_GOVERNED_SUBNETS_JSON="{${ADDITIONAL_GOVERNED_SUBNETS_JSON}}"
fi
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
if [[ "${ARTIFACT_STORAGE:-1}" == "1" ]]; then
  ENABLE_ARTIFACT_STORAGE=true
else
  ENABLE_ARTIFACT_STORAGE=false
fi
ARTIFACT_STORAGE_ACCOUNT="${ARTIFACT_STORAGE_ACCOUNT:-}"

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

# Flow logs are off by default: they bill, and they grant Ringleader nothing. They go in the Network
# Watcher's resource group rather than in RG, because Ringleader's role is scoped to RG and, with
# ARTIFACT_STORAGE on, may read and delete every blob there, and on the default settings delete the
# storage accounts too. Refused up front rather than
# after the app, role and network are deployed.
CREATE_FLOW_LOGS="${CREATE_FLOW_LOGS:-false}"
FLOW_LOG_RETENTION_DAYS="${FLOW_LOG_RETENTION_DAYS:-365}"
NETWORK_WATCHER_NAME="${NETWORK_WATCHER_NAME:-}"
NETWORK_WATCHER_RG="${NETWORK_WATCHER_RG:-NetworkWatcherRG}"
if [ "$CREATE_FLOW_LOGS" != "true" ] && [ "$CREATE_FLOW_LOGS" != "false" ]; then
  echo "CREATE_FLOW_LOGS must be true or false, not '${CREATE_FLOW_LOGS}'" >&2
  exit 1
fi
if [ "$CREATE_FLOW_LOGS" = "true" ] && [ "$CREATE_NETWORK" != "true" ]; then
  echo "CREATE_FLOW_LOGS=true needs CREATE_NETWORK=true: this script records flow logs only for the VNet it creates." >&2
  exit 1
fi
if [ "$CREATE_FLOW_LOGS" = "true" ] && [ "$(printf '%s' "$NETWORK_WATCHER_RG" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$RG" | tr 'A-Z' 'a-z')" ]; then
  echo "NETWORK_WATCHER_RG is RG, the resource group Ringleader's role reaches. The flow log's storage account would be one Ringleader can read and delete. Use a Network Watcher in a resource group of its own." >&2
  exit 1
fi
if [ "$CREATE_FLOW_LOGS" = "true" ] && ! printf '%s' "$FLOW_LOG_RETENTION_DAYS" | grep -Eq '^([1-9]|[1-9][0-9]|[12][0-9][0-9]|3[0-5][0-9]|36[0-5])$'; then
  echo "FLOW_LOG_RETENTION_DAYS must be a whole number from 1 to 365, not '${FLOW_LOG_RETENTION_DAYS}'" >&2
  exit 1
fi

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
               enableArtifactStorage="$ENABLE_ARTIFACT_STORAGE" \
               artifactStorageAccountName="$ARTIFACT_STORAGE_ACCOUNT" \
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
  echo ">>   gateway mgmt: ${GATEWAY_MANAGEMENT_SOURCE_CIDR:-<none>}"
  WORKSTATIONS_NSG="${NAME_PREFIX}-workstations-nsg"
  GATEWAY_NSG="${NAME_PREFIX}-gateway-nsg"

  # Deploying a network security group sets its WHOLE rule list, so re-running this on a group that
  # already exists deletes every rule added since -- including the inbound rule Ringleader writes in
  # it to admit its own workstations. So each group is deployed only when it is absent. Its rules
  # are child resources, which add and update just themselves, so a changed CIDR above still lands
  # on a group this run leaves alone.
  #
  # The groups are listed in a plain assignment, so a failed az call stops this script instead of
  # reading as "no group yet", which would redeploy an existing group and delete Ringleader's rule.
  # Each name is matched from a here-string rather than a pipe: under pipefail, grep -q exits at the
  # first match, and the write it cuts off would fail the test on a long list.
  EXISTING_NSGS="$(az network nsg list -g "$RG" --query '[].name' -o tsv)"
  WORKSTATIONS_NSG_EXISTS=false
  if grep -qxF "$WORKSTATIONS_NSG" <<<"$EXISTING_NSGS"; then
    WORKSTATIONS_NSG_EXISTS=true
  fi
  GATEWAY_NSG_EXISTS=false
  if grep -qxF "$GATEWAY_NSG" <<<"$EXISTING_NSGS"; then
    GATEWAY_NSG_EXISTS=true
  fi

  # The VNet's subnets are deployed as one list, and a subnet deployed without a route table loses
  # the one it had. That includes the route table Ringleader associates with a governed subnet to
  # steer it at an egress gateway. So an existing VNet's route tables are read here and handed back
  # to the template, which keeps each one on its subnet. The VNet list is read the same way as the
  # groups above. A failed call must not read as "no VNet yet", because that drops every route table.
  SUBNET_ROUTE_TABLES="[]"
  EXISTING_VNETS="$(az network vnet list -g "$RG" --query '[].name' -o tsv)"
  if grep -qxF "${NAME_PREFIX}-vnet" <<<"$EXISTING_VNETS"; then
    SUBNET_ROUTE_TABLES="$(az network vnet subnet list -g "$RG" --vnet-name "${NAME_PREFIX}-vnet" --query '[?routeTable].{name: name, id: routeTable.id}' -o json)"
  fi

  # The other half of that shape: a deployment adds and updates rules, it never deletes one. So
  # clearing a CIDR closes its rule here rather than in the template. Deleting a rule that is not
  # there succeeds, which is what makes this safe to run on every pass.
  if [ "$WORKSTATIONS_NSG_EXISTS" = "true" ] && [ -z "$SSH_SOURCE_CIDR" ]; then
    echo ">>   closing AllowRingleaderSSHInbound"
    az network nsg rule delete -g "$RG" --nsg-name "$WORKSTATIONS_NSG" -n AllowRingleaderSSHInbound
  fi
  if [ "$WORKSTATIONS_NSG_EXISTS" = "true" ] && [ -z "$SECONDARY_SSH_SOURCE_CIDR" ]; then
    echo ">>   closing AllowRingleaderSecondarySSHInbound"
    az network nsg rule delete -g "$RG" --nsg-name "$WORKSTATIONS_NSG" -n AllowRingleaderSecondarySSHInbound
  fi
  if [ "$GATEWAY_NSG_EXISTS" = "true" ] && [ -z "$GATEWAY_MANAGEMENT_SOURCE_CIDR" ]; then
    echo ">>   closing allow-management-inbound"
    az network nsg rule delete -g "$RG" --nsg-name "$GATEWAY_NSG" -n allow-management-inbound
  fi

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
                 gatewayManagementSourceCidr="$GATEWAY_MANAGEMENT_SOURCE_CIDR" \
                 createGatewaySubnet="$CREATE_GATEWAY_SUBNET" \
                 gatewaySubnetCidr="$GATEWAY_SUBNET_CIDR" \
                 createGovernedSubnet="$CREATE_GOVERNED_SUBNET" \
                 governedSubnetCidr="$GOVERNED_SUBNET_CIDR" \
                 additionalGovernedSubnets="$ADDITIONAL_GOVERNED_SUBNETS_JSON" \
                 subnetRouteTables="$SUBNET_ROUTE_TABLES" \
                 workstationsNsgExists="$WORKSTATIONS_NSG_EXISTS" \
                 gatewayNsgExists="$GATEWAY_NSG_EXISTS" \
    --query '[properties.outputs.subnetId.value, properties.outputs.governedSubnetId.value, properties.outputs.gatewaySubnetId.value]' -o tsv)"
  SUBNET_ID="$(echo "$NETWORK_OUTPUTS" | sed -n 1p)"
  GOVERNED_SUBNET_ID="$(echo "$NETWORK_OUTPUTS" | sed -n 2p)"
  # The gateway subnet is printed for the same reason the other two are: it is a value the
  # operator has to hand back, and this script is the only place the ARM path shows them. Left
  # out, an operator on this path never learns the id -- and Ringleader builds no gateway VM at
  # all until an EgressGateway names it.
  GATEWAY_SUBNET_ID="$(echo "$NETWORK_OUTPUTS" | sed -n 3p)"
  ADDITIONAL_GOVERNED_SUBNET_IDS="$(az deployment group show \
    --resource-group "$RG" \
    --name ringleader-onboarding-network \
    --query 'properties.outputs.additionalGovernedSubnetIds.value[].id' -o tsv)"
fi

# 5. Flow logs for the landing pad's VNet, from the template the Terraform module also deploys, so
#    both routes create the same storage account and flow log under the same names. It is deployed
#    into the Network Watcher's resource group: Azure requires a flow log beside its watcher, and
#    Ringleader's role does not reach that group. The watcher is looked up first, so a subscription
#    without one stops here naming it. Unlike the Terraform route, setting CREATE_FLOW_LOGS=false
#    later deletes nothing: remove the flow log and its storage account yourself if you want them gone.
if [ "$CREATE_FLOW_LOGS" = "true" ]; then
  VNET="$(az network vnet show -g "$RG" -n "${NAME_PREFIX}-vnet" --query '[id, location]' -o tsv)"
  VNET_ID="$(echo "$VNET" | sed -n 1p)"
  VNET_LOCATION="$(echo "$VNET" | sed -n 2p)"
  NETWORK_WATCHER_NAME="${NETWORK_WATCHER_NAME:-NetworkWatcher_${VNET_LOCATION}}"
  WATCHERS="$(az network watcher list --query '[].[resourceGroup, name, location]' -o tsv)"
  WATCHER_LOCATION="$(awk -F '\t' -v g="$NETWORK_WATCHER_RG" -v n="$NETWORK_WATCHER_NAME" 'tolower($1) == tolower(g) && tolower($2) == tolower(n) { print $3 }' <<<"$WATCHERS")"
  if [ -z "$WATCHER_LOCATION" ]; then
    echo "no Network Watcher ${NETWORK_WATCHER_NAME} in resource group ${NETWORK_WATCHER_RG}. If step 4 just created the first VNet in ${VNET_LOCATION}, Azure may not have enabled its watcher yet: run this script again. Otherwise set NETWORK_WATCHER_NAME and NETWORK_WATCHER_RG to the watcher for ${VNET_LOCATION}; az network watcher list shows them." >&2
    exit 1
  fi
  if [ "$WATCHER_LOCATION" != "$VNET_LOCATION" ]; then
    echo "the Network Watcher ${NETWORK_WATCHER_NAME} is in ${WATCHER_LOCATION}, but the VNet is in ${VNET_LOCATION}. A flow log is recorded by the watcher for its VNet's own region." >&2
    exit 1
  fi
  FLOW_LOG_DEPLOYMENT="${NAME_PREFIX}-flow-logs-${RG}"
  echo ">> recording flow logs for ${NAME_PREFIX}-vnet through ${NETWORK_WATCHER_NAME}, kept ${FLOW_LOG_RETENTION_DAYS} days, in ${NETWORK_WATCHER_RG}"
  az deployment group create \
    --resource-group "$NETWORK_WATCHER_RG" \
    --name "${FLOW_LOG_DEPLOYMENT:0:64}" \
    --template-file "${SCRIPT_DIR}/azuredeploy-flowlogs.json" \
    --parameters vnetId="$VNET_ID" location="$VNET_LOCATION" \
                 networkWatcherName="$NETWORK_WATCHER_NAME" \
                 retentionDays="$FLOW_LOG_RETENTION_DAYS" \
    --query 'properties.provisioningState' -o tsv
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
# One more governed subnet per ADDITIONAL_GOVERNED_SUBNETS pair, each for exactly one namespace's
# workstations, and never for two namespaces. Each id ends in governed-<label>.
if [ -n "${ADDITIONAL_GOVERNED_SUBNET_IDS:-}" ]; then
  echo "  additional governed subnets, one namespace each (the label ends each id):"
  printf '%s\n' "$ADDITIONAL_GOVERNED_SUBNET_IDS" | sed 's/^/    /'
fi
# The gateway subnet is where the proxy VM ITSELF goes, so it is handed back on the EgressGateway
# rather than on a workstation -- and no gateway VM is built until it is. A proxy placed in a
# subnet it steers would route its own egress into itself.
if [ -n "${GATEWAY_SUBNET_ID:-}" ]; then
  echo "  gateway subnet   : ${GATEWAY_SUBNET_ID}   (EgressGateway spec.subnet -- NOT a workstation)"
fi
echo "==============================================================="
