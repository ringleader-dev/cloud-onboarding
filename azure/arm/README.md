# Azure onboarding — ARM template + az

For teams that prefer ARM / the portal over Terraform. Because the Entra **app
registration** and its **federated credential** are Microsoft Graph directory
objects (not ARM resources), the ARM template covers only the **custom role +
its assignment**; the app + service principal + federated credential are created
with `az`. [`deploy.sh`](deploy.sh) does all of it in one idempotent run.

## Files

| File | What it is |
|---|---|
| [`azuredeploy.json`](azuredeploy.json) | ARM template: the custom least-privilege role definition + a role assignment, scoped to the resource group. Deploy at **resource-group scope**. Takes the service-principal **object id** as `principalId`. |
| [`azuredeploy.parameters.example.json`](azuredeploy.parameters.example.json) | Example parameters file. |
| [`deploy.sh`](deploy.sh) | End-to-end wrapper: creates the app + SP + OIDC federated credential with `az`, then deploys the template. |

## Quick start (recommended)

```bash
export RG=ringleader-workstations                      # existing RG you own
export ISSUER_URL='https://oidc-app.ringleader.dev'    # Ringleader gives you this
export ORG_UID='0192f5bf-af83-7178-8d0a-f1c7aea06bde'  # ...and this
az login
./deploy.sh
```

`deploy.sh` prints the exact values to hand back to Ringleader (app client id,
tenant id, subscription id, resource group).

Env vars: `RG`, `ISSUER_URL`, `ORG_UID` (required); `APP_NAME`
(`ringleader-workstations`), `ROLE_NAME` (`Ringleader Workstation Operator`),
`WORKSTATION_IDENTITIES` (`1` to also grant the per-workstation runtime-identity
actions — see [`../README.md`](../README.md) before turning it on).

## Deploy the template by itself

If you already have the app + service principal + federated credential and just
want the role + assignment (e.g. from the portal or a pipeline):

```bash
# service principal OBJECT id (not the app/client id):
SP_OBJECT_ID=$(az ad sp show --id <client-id> --query id -o tsv)

az deployment group create \
  --resource-group ringleader-workstations \
  --template-file azuredeploy.json \
  --parameters principalId="$SP_OBJECT_ID"
```

Then add the federated credential yourself:

```bash
az ad app federated-credential create --id <client-id> --parameters '{
  "name": "ringleader-oidc",
  "issuer": "https://oidc-app.ringleader.dev/org/<org-id>",
  "subject": "org:<org-id>",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

See [`../README.md`](../README.md) for the trust model and the values to hand back.
