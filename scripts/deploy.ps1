<#
.SYNOPSIS
    Single-command deployment for the ContosoPay / Azure SRE Agent demo.

.DESCRIPTION
    Orchestrates the full deploy:
      1. Validates prerequisites (az, terraform, docker, an az login).
      2. terraform init.
      3. terraform apply (phase 1) creating ACR/Key Vault/identities/observability/
         Container Apps environment WITHOUT the apps (images do not exist yet).
      4. Builds and pushes the three container images to ACR.
      5. terraform apply (phase 2) creating the three Container Apps + alert,
         pointing at the freshly pushed image tag.
      6. Prints the public frontend URL and SRE Agent wiring next-steps.

    No secrets are handled by this script. All app secrets live in Key Vault and
    are read by the apps via managed identity.

.PARAMETER SubscriptionName
    Optional subscription name or id to select before deploying. When omitted the
    currently selected az subscription is used.

.PARAMETER ImageTag
    Optional image tag override. Defaults to a UTC timestamp so each deploy
    produces a fresh revision.

.PARAMETER SkipBuild
    Reuse images already in ACR (skip docker build/push). Useful for re-runs.

.EXAMPLE
    pwsh ./scripts/deploy.ps1

.EXAMPLE
    pwsh ./scripts/deploy.ps1 -SubscriptionName 'My Subscription'

.OUTPUTS
    None. Writes status to the host and the frontend URL on success.

.NOTES
    The Azure SRE Agent itself is provisioned separately at https://sre.azure.com
    and is intentionally not part of this script (see docs/run-of-show.md).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionName,

    [Parameter()]
    [string]$ImageTag = (Get-Date -AsUTC -Format 'yyyyMMddHHmmss'),

    [Parameter()]
    [string]$Prefix = 'contosopay',

    [Parameter()]
    [string]$Environment = 'demo',

    [Parameter()]
    [string]$Location = 'swedencentral',

    [Parameter()]
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$infraDir = Join-Path $repoRoot 'infra'
$services = @('frontend', 'checkout-api', 'payment-service')

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Script)
    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $Name"
    }
}

# Deterministic, non-identifying names for the remote Terraform state. The same
# values must be reproduced by .github/workflows/apply-infra.yml, so they are
# derived purely from the subscription id + prefix (no random suffix).
function Get-BackendConfig {
    param([string]$SubscriptionId, [string]$Prefix, [string]$Environment)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$SubscriptionId-$Prefix"))
    $hex = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower().Substring(0, 16)
    [pscustomobject]@{
        ResourceGroup  = "rg-$Prefix-tfstate"
        StorageAccount = "sttf$hex"            # 20 chars, globally unique-ish, LRS
        Container      = 'tfstate'
        Key            = "$Prefix-$Environment.tfstate"
    }
}

# Idempotently create the LRS state storage (no account keys: AAD data-plane auth).
function Initialize-StateStorage {
    param([object]$Backend, [string]$Location, [string]$PrincipalId, [hashtable]$Tags)
    Write-Host "==> Ensuring remote state storage ($($Backend.StorageAccount))" -ForegroundColor Cyan
    $tagArgs = ($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    Invoke-Checked -Name 'az group create (tfstate)' {
        az group create --name $Backend.ResourceGroup --location $Location --tags @tagArgs --output none
    }
    $exists = az storage account show --name $Backend.StorageAccount --resource-group $Backend.ResourceGroup --query name --output tsv 2>$null
    if (-not $exists) {
        Invoke-Checked -Name 'az storage account create (tfstate)' {
            az storage account create --name $Backend.StorageAccount --resource-group $Backend.ResourceGroup `
                --location $Location --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
                --allow-blob-public-access false --https-only true --tags @tagArgs --output none
        }
    }
    $saId = az storage account show --name $Backend.StorageAccount --resource-group $Backend.ResourceGroup --query id --output tsv
    # AAD data-plane access for the deployer (no storage keys). Idempotent.
    az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type User `
        --role 'Storage Blob Data Contributor' --scope $saId --output none 2>$null
    Write-Host '    Waiting for role propagation...'
    $created = $false
    for ($i = 0; $i -lt 12 -and -not $created; $i++) {
        az storage container create --name $Backend.Container --account-name $Backend.StorageAccount `
            --auth-mode login --output none 2>$null
        if ($LASTEXITCODE -eq 0) { $created = $true } else { Start-Sleep -Seconds 10 }
    }
    if (-not $created) { throw "Could not create state container '$($Backend.Container)' (role propagation timed out)." }
}

Write-Host '==> Checking prerequisites' -ForegroundColor Cyan
Assert-Command az
Assert-Command terraform
Assert-Command docker

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Not logged in to Azure. Run 'az login' first."
}

if ($SubscriptionName) {
    Write-Host "==> Selecting subscription: $SubscriptionName" -ForegroundColor Cyan
    Invoke-Checked -Name 'az account set' { az account set --subscription $SubscriptionName }
    $account = az account show | ConvertFrom-Json
}

# azurerm provider + backend read the subscription / AAD auth from these env vars.
$env:ARM_SUBSCRIPTION_ID = $account.id
$env:ARM_USE_AZUREAD = 'true'
Write-Host "    Subscription: $($account.name) ($($account.id))"

# Verify the Docker daemon is reachable before we get deep into the deploy.
docker info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker daemon is not reachable. Start Docker Desktop and retry.'
}

$signedInId = az ad signed-in-user show --query id --output tsv
$backend = Get-BackendConfig -SubscriptionId $account.id -Prefix $Prefix -Environment $Environment
$tags = @{ project = 'sre-agent-demo'; env = $Environment; managed_by = 'terraform' }
Initialize-StateStorage -Backend $backend -Location $Location -PrincipalId $signedInId -Tags $tags

Write-Host '==> terraform init (remote azurerm backend)' -ForegroundColor Cyan
Invoke-Checked -Name 'terraform init' {
    terraform -chdir="$infraDir" init -input=false -migrate-state -force-copy `
        -backend-config="resource_group_name=$($backend.ResourceGroup)" `
        -backend-config="storage_account_name=$($backend.StorageAccount)" `
        -backend-config="container_name=$($backend.Container)" `
        -backend-config="key=$($backend.Key)"
}

Write-Host '==> terraform apply (phase 1: platform, no apps yet)' -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess('infra', 'terraform apply phase 1')) {
    Invoke-Checked -Name 'terraform apply (phase 1)' {
        terraform -chdir="$infraDir" apply -input=false -auto-approve `
            -var 'deploy_apps=false' -var "prefix=$Prefix" -var "environment=$Environment" -var "location=$Location"
    }
}


$acrName = terraform -chdir="$infraDir" output -raw acr_name
$acrLoginServer = terraform -chdir="$infraDir" output -raw acr_login_server
Write-Host "    ACR: $acrLoginServer"

if (-not $SkipBuild.IsPresent) {
    Write-Host '==> Logging in to ACR' -ForegroundColor Cyan
    Invoke-Checked -Name 'az acr login' { az acr login --name $acrName }

    foreach ($svc in $services) {
        $context = Join-Path $repoRoot "src/$svc"
        $imageSha = "${acrLoginServer}/${svc}:$ImageTag"
        $imageLatest = "${acrLoginServer}/${svc}:latest"
        Write-Host "==> Building $svc -> ${svc}:$ImageTag" -ForegroundColor Cyan
        Invoke-Checked -Name "docker build $svc" { docker build -t $imageSha -t $imageLatest $context }
        Invoke-Checked -Name "docker push $svc (tag)" { docker push $imageSha }
        Invoke-Checked -Name "docker push $svc (latest)" { docker push $imageLatest }
    }
}

Write-Host '==> terraform apply (phase 2: container apps + alert)' -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess('infra', 'terraform apply phase 2')) {
    Invoke-Checked -Name 'terraform apply (phase 2)' {
        terraform -chdir="$infraDir" apply -input=false -auto-approve `
            -var 'deploy_apps=true' -var "image_tag=$ImageTag" `
            -var "prefix=$Prefix" -var "environment=$Environment" -var "location=$Location"
    }
}

$frontendUrl = terraform -chdir="$infraDir" output -raw frontend_url
$resourceGroup = terraform -chdir="$infraDir" output -raw resource_group_name
$grafana = terraform -chdir="$infraDir" output -raw grafana_endpoint 2>$null

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' ContosoPay demo deployed' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  Frontend URL : $frontendUrl"
Write-Host "  Resource grp : $resourceGroup"
if ($grafana) { Write-Host "  Grafana      : $grafana" }
Write-Host ''
Write-Host ' Remote Terraform state (set these as GitHub Actions *variables*' -ForegroundColor Yellow
Write-Host ' for apply-infra.yml):' -ForegroundColor Yellow
Write-Host "  TFSTATE_RG        : $($backend.ResourceGroup)"
Write-Host "  TFSTATE_SA        : $($backend.StorageAccount)"
Write-Host "  TFSTATE_CONTAINER : $($backend.Container)"
Write-Host "  TFSTATE_KEY       : $($backend.Key)"
Write-Host ''
Write-Host ' Next steps — connect the Azure SRE Agent (see docs/sre-agent-setup.md §1-5):' -ForegroundColor Yellow
Write-Host "  1. Go to https://sre.azure.com, create an SRE Agent, and point it at '$resourceGroup'."
Write-Host '  2. Connect this GitHub repo (Code Access) and Azure Monitor as the incident platform.'
Write-Host '  3. Then pick a demo scenario and finish the wiring:'
Write-Host '       Scenario A (on-the-spot): docs/scenario-a-direct.md  — grant Privileged access,'
Write-Host '                                 then: scripts/trigger-incident-direct.ps1'
Write-Host '       Scenario B (full GitOps): docs/scenario-b-gitops.md  — grant Reader + deny policy,'
Write-Host '                                 then: scripts/trigger-incident-gitops.ps1 (opens a PR)'
Write-Host ''
