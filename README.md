# azure-bicep-deployment-stacks

A small, end-to-end example of deploying Azure infrastructure with **Bicep**, **Azure Deployment Stacks**, and **GitHub Actions (OIDC)**.

It deploys a Container App (with a managed environment, Log Analytics, and a user-assigned identity) into its own resource group. The whole thing is owned by a **subscription-scoped deployment stack**, so the stack is the unit you create, update and delete.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the diagram.

## Why deployment stacks?

- **Drift cleanup**: `--action-on-unmanage deleteAll` means removing a resource from the Bicep actually deletes it in Azure on the next deploy.
- **Clean teardown**: deleting the stack deletes everything it owns, resource group included.
- **Guardrails (currently off)**: stacks support `--deny-settings-mode denyDelete` to block deleting managed resources from the portal. It's set to `none` for now because applying the deny assignment failed in this tenant with `InvalidAuthenticationToken`. See [Deny settings](#deny-settings).

## Setup guide

### Prerequisites

- An Azure subscription where you can assign roles
- Azure CLI 2.61+ and Bicep (`az bicep install`)
- A GitHub repo containing this code

> **Windows Git Bash:** Git Bash rewrites arguments starting with `/` into Windows paths, which breaks `--scope /subscriptions/...` with `MissingSubscription`. Prefix those commands with `MSYS_NO_PATHCONV=1` (shown below), or use PowerShell.

### Step 1 — Log in and set variables

```bash
az login --tenant <tenant-id>   # --tenant avoids MFA "InteractionRequired" errors
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
GH_REPO="<your-github-user>/azure-bicep-deployment-stacks"
```

### Step 2 — Register resource providers

```bash
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
```

### Step 3 — Create the app registration for GitHub

```bash
APP_ID=$(az ad app create --display-name "gh-stackdemo" --query appId -o tsv)
SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
echo "Client ID: $APP_ID   SP object ID: $SP_OBJECT_ID"
```

### Step 4 — Add federated credentials (OIDC)

```bash
for subject in "environment:dev" "environment:prod"; do
  name=$(echo "$subject" | tr ':' '-')
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"gh-$name\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$GH_REPO:$subject\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
done
```

The subject must match the `sub` claim GitHub sends exactly. If Azure Login fails with `AADSTS700213`, the error shows the subject GitHub actually sent; add a credential with that value.

### Step 5 — Assign roles at subscription scope

```bash
MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" --scope "/subscriptions/$SUB_ID"

MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Deployment Stack Owner" --scope "/subscriptions/$SUB_ID"
```

`Azure Deployment Stack Owner` is only needed for deny settings, but it's harmless to keep.

### Step 6 — Configure GitHub

In **Settings → Environments**, create `dev` (and `prod` when you enable it — add yourself as a required reviewer there).

On each environment, add these **environment variables** (not secrets — the workflows read `vars.*`):

| Variable                | Value        |
| ----------------------- | ------------ |
| `AZURE_CLIENT_ID`       | `$APP_ID`    |
| `AZURE_TENANT_ID`       | `$TENANT_ID` |
| `AZURE_SUBSCRIPTION_ID` | `$SUB_ID`    |

### Step 7 — Open a PR

Change something under `infra/` and open a PR. The `pr` workflow lints, validates the stack and posts the what-if to the job summary.

### Step 8 — Merge to main

`deploy` applies the dev stack and smoke-tests the URL. The prod job is commented out in `deploy.yml` for now; when enabled, it waits for approval on the `prod` environment after dev succeeds.

### Step 9 — See the stack in action

```bash
az stack sub show --name stack-stackdemo-dev --query "resources[].id" -o tsv
```

To demo drift cleanup, remove the `identity` resource from `infra/modules/containerapp.bicep` (and its reference in the app), merge, and watch the stack delete it.

### Step 10 — Tear down

Run **Actions → destroy**, or:

```bash
az stack sub delete --name stack-stackdemo-dev --action-on-unmanage deleteAll --yes
```

## Deny settings

To turn the guardrail back on, change `--deny-settings-mode none` to `denyDelete` in both the validate and create steps of `.github/workflows/_stack.yml`, and exclude the pipeline's service principal so it can still update resources:

```bash
--deny-settings-mode denyDelete \
--deny-settings-excluded-principals "${{ vars.DEPLOYER_OBJECT_ID }}" \
```

Then add a `DEPLOYER_OBJECT_ID` environment variable set to `$SP_OBJECT_ID`. Test it locally first with `az stack sub create ... --deny-settings-mode denyDelete` — in a personal (Microsoft account) tenant this failed with `DeploymentStackTenantRegistrationFailed` / `InvalidAuthenticationToken`.

## Cost

dev scales to zero (`minReplicas: 0`). prod, once enabled, keeps one small replica warm. Tear down when you're done demoing.
