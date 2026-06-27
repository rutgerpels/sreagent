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
    param([Parameter(Mandatory)][scriptblock]$Script)
    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $Script"
    }
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
    Invoke-Checked { az account set --subscription $SubscriptionName }
    $account = az account show | ConvertFrom-Json
}

# azurerm provider reads the subscription from this environment variable.
$env:ARM_SUBSCRIPTION_ID = $account.id
Write-Host "    Subscription: $($account.name) ($($account.id))"

# Verify the Docker daemon is reachable before we get deep into the deploy.
docker info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker daemon is not reachable. Start Docker Desktop and retry.'
}

Write-Host '==> terraform init' -ForegroundColor Cyan
Invoke-Checked { terraform -chdir="$infraDir" init -input=false }

Write-Host '==> terraform apply (phase 1: platform, no apps yet)' -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess('infra', 'terraform apply phase 1')) {
    Invoke-Checked {
        terraform -chdir="$infraDir" apply -input=false -auto-approve `
            -var 'deploy_apps=false'
    }
}

$acrName = terraform -chdir="$infraDir" output -raw acr_name
$acrLoginServer = terraform -chdir="$infraDir" output -raw acr_login_server
Write-Host "    ACR: $acrLoginServer"

if (-not $SkipBuild.IsPresent) {
    Write-Host '==> Logging in to ACR' -ForegroundColor Cyan
    Invoke-Checked { az acr login --name $acrName }

    foreach ($svc in $services) {
        $context = Join-Path $repoRoot "src/$svc"
        $imageSha = "${acrLoginServer}/${svc}:$ImageTag"
        $imageLatest = "${acrLoginServer}/${svc}:latest"
        Write-Host "==> Building $svc -> ${svc}:$ImageTag" -ForegroundColor Cyan
        Invoke-Checked { docker build -t $imageSha -t $imageLatest $context }
        Invoke-Checked { docker push $imageSha }
        Invoke-Checked { docker push $imageLatest }
    }
}

Write-Host '==> terraform apply (phase 2: container apps + alert)' -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess('infra', 'terraform apply phase 2')) {
    Invoke-Checked {
        terraform -chdir="$infraDir" apply -input=false -auto-approve `
            -var 'deploy_apps=true' -var "image_tag=$ImageTag"
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
Write-Host ' Next steps — connect the Azure SRE Agent:' -ForegroundColor Yellow
Write-Host '  1. Go to https://sre.azure.com and create an SRE Agent.'
Write-Host "  2. Point it at resource group '$resourceGroup'."
Write-Host '  3. Connect this GitHub repository (for commit correlation).'
Write-Host "  4. Subscribe the agent to action group 'ag-sre-*' in the RG."
Write-Host '  5. Run scripts/trigger-incident.sh to start the demo incident.'
Write-Host ''
