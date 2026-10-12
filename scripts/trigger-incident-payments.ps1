<#
.SYNOPSIS
    Trigger (or reset) the Scenario D incident: payments fail; checkout fails with them.

.DESCRIPTION
    Sets PAYMENT_FAILURE_MODE on the live payment-service Container App. Any
    environment-variable change rolls a new revision, so both arming and reset
    end with a fresh revision. Terraform's desired state stays healthy ('off');
    this is a temporary, audited live deviation and a later terraform apply will
    not re-arm it.

    Guards: Terraform state and the live resource group must both identify
    Scenario D, and the live app must be the state-owned resource. Only the single
    PAYMENT_FAILURE_MODE variable is changed.

.PARAMETER Reset
    Set PAYMENT_FAILURE_MODE back to 'off' and roll a fresh healthy revision.

.PARAMETER ResourceGroup
    Must match `terraform output resource_group_name` if supplied.

.PARAMETER PaymentApp
    Must match `terraform output payment_app_name` if supplied.

.EXAMPLE
    pwsh ./scripts/trigger-incident-payments.ps1

.EXAMPLE
    pwsh ./scripts/trigger-incident-payments.ps1 -Reset

.OUTPUTS
    None. Writes status to the host.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch]$Reset,

    [Parameter()]
    [string]$ResourceGroup,

    [Parameter()]
    [string]$PaymentApp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$infraDir = Join-Path $repoRoot 'infra'
$desired = if ($Reset.IsPresent) { 'off' } else { 'unavailable' }

foreach ($tool in 'az', 'terraform') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' not found on PATH."
    }
}

function Get-TfOutput {
    param([Parameter(Mandatory)][string]$Name)
    $value = terraform -chdir="$infraDir" output -raw $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Could not read terraform output '$Name'."
    }
    return $value.Trim()
}

$scenario = Get-TfOutput -Name 'scenario'
if ($scenario -ne 'D') {
    throw "This trigger is restricted to Scenario D; current Terraform state is Scenario $scenario."
}

$expectedResourceGroup = Get-TfOutput -Name 'resource_group_name'
$expectedPaymentApp = Get-TfOutput -Name 'payment_app_name'
if ($ResourceGroup -and $ResourceGroup -ne $expectedResourceGroup) {
    throw 'The ResourceGroup argument must match Terraform state; cross-environment mutation is forbidden.'
}
if ($PaymentApp -and $PaymentApp -ne $expectedPaymentApp) {
    throw 'The PaymentApp argument must match Terraform state; cross-environment mutation is forbidden.'
}
$ResourceGroup = $expectedResourceGroup
$PaymentApp = $expectedPaymentApp

$liveScenario = az group show --name $ResourceGroup --query tags.scenario --output tsv
if ($LASTEXITCODE -ne 0 -or $liveScenario.Trim() -ne 'D') {
    throw 'The live resource group is not tagged as Scenario D; refusing mutation.'
}
$appId = az containerapp show --name $PaymentApp --resource-group $ResourceGroup --query id --output tsv
$expectedAppSuffix = "/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$PaymentApp"
if ($LASTEXITCODE -ne 0 -or -not $appId.EndsWith($expectedAppSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The live payment app does not match the state-owned resource.'
}

Write-Host "==> Will set PAYMENT_FAILURE_MODE=$desired on '$PaymentApp' (rg: $ResourceGroup)" -ForegroundColor Cyan
if (-not $PSCmdlet.ShouldProcess($PaymentApp, "set PAYMENT_FAILURE_MODE=$desired on the live Container App")) {
    Write-Host '    (WhatIf) no change applied.'
    return
}

az containerapp update `
    --name $PaymentApp `
    --resource-group $ResourceGroup `
    --set-env-vars "PAYMENT_FAILURE_MODE=$desired" 1>$null
if ($LASTEXITCODE -ne 0) { throw "az containerapp update failed (exit $LASTEXITCODE)." }

if ($Reset.IsPresent) {
    Write-Host '==> Payment failure disabled. A fresh healthy revision is rolling out.' -ForegroundColor Green
    Write-Host '    Confirm with fresh checkout orders (scripts/generate-checkout-traffic.ps1).'
}
else {
    Write-Host '==> Incident armed. Payment calls now return 503 and checkout returns 502.' -ForegroundColor Green
    Write-Host '    Keep synthetic traffic running; the payment-failure alert should fire within minutes.'
}
