# Azure onboarding — ARM template + az

For teams that prefer ARM / the portal over Terraform. Because the Entra **app
registration** and its **federated credential** are Microsoft Graph directory
objects (not ARM resources), the ARM template covers only the **custom role +
its assignment**; the app + service principal + federated credential are created
with `az`. [`deploy.sh`](deploy.sh) does all of it in one idempotent run.

## Files

| File | What it is |
|---|---|
| [`azuredeploy.json`](azuredeploy.json) | ARM template: the custom least-privilege role definition + a role assignment, scoped to the resource group. Deploy at **resource-group scope**. Takes the service-principal **object id** as `principalId`. It is the single source of the action list — the [Terraform module](../terraform/) deploys this same file. |
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

The role definition's name is a GUID derived from the resource group and the role name
(`guid(resourceGroup().id, roleName)`), so re-deploying updates the same role rather than
creating a second one. To find it:

```bash
az role definition list --name "Ringleader Workstation Operator" \
  --query '[0].{name:name, id:id}' -o json
```

## Editing this template

The [Terraform module](../terraform/) deploys this same file through
`azurerm_resource_group_template_deployment`, which compares the file against the
**normalized copy Azure stores and echoes back**. Anything Azure rewrites becomes a
permanent `terraform plan` diff — a step that reports changes on every run, forever, is a
step whose real changes nobody notices. So the template is written in the form Azure
stores, and edits must keep it that way:

- **no top-level `metadata` block** — Azure drops it. Describe the template here instead.
- **no `outputs` block** — Azure rewrites the output `type` casing.
- **no parameter with a `defaultValue` that the Terraform module does not pass
  explicitly** — Azure materializes the default into the stored parameters while the file
  leaves it unset. That is why the role definition GUID is a `variables` entry rather than
  a parameter.

Parameter `metadata.description` blocks are preserved by Azure and are fine.

See [`../README.md`](../README.md) for the trust model and the values to hand back.
