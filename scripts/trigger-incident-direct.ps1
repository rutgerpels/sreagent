<#
.SYNOPSIS
    Trigger (or reset) the ContosoPay demo incident the direct, on-the-spot way.

.DESCRIPTION
    This is the SCENARIO A trigger. It flips the planted memory-leak feature flag
    (ENABLE_SLOW_LEAK) directly on the running payment-service Container App with a
    single `az containerapp update`. No Pull Request, no CI -- the change hits the
    live revision immediately.

    Use this for the fast, self-contained demo where the SRE Agent has Privileged
    (High) access and mitigates ON THE SPOT (restart revision / set the env var
    back) after you approve in the agent UI.

    For the realistic, change-managed GitOps flow (PR + CI, agent remediates via a
    PR) use scripts/trigger-incident-gitops.ps1 instead.

    Memory then climbs for roughly 8-12 min, the Azure Monitor alert fires, and the SRE
    Agent investigates.

.PARAMETER Reset
    Turn the leak back OFF (ENABLE_SLOW_LEAK=false) -- rolls a fresh revision and
    clears leaked memory. Normally the SRE Agent does this for you; use -Reset to
    clean up manually.

.PARAMETER ResourceGroup
    Demo resource group. Defaults to `terraform output resource_group_name`.

.PARAMETER PaymentApp
    payment-service Container App name. Defaults to `terraform output payment_app_name`.

.EXAMPLE
    pwsh ./scripts/trigger-incident-direct.ps1
    # Arms the leak on the live app. Watch memory climb, then let the agent fix it.

.EXAMPLE
    pwsh ./scripts/trigger-incident-direct.ps1 -Reset

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
$desired = if ($Reset.IsPresent) { 'false' } else { 'true' }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Required command 'az' not found on PATH. Install the Azure CLI and run 'az login'."
}

function Get-TfOutput {
    param([Parameter(Mandatory)][string]$Name)
    $value = terraform -chdir="$infraDir" output -raw $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Could not read terraform output '$Name'. Pass -ResourceGroup / -PaymentApp explicitly."
    }
    return $value.Trim()
}

if (-not $ResourceGroup) { $ResourceGroup = Get-TfOutput -Name 'resource_group_name' }
if (-not $PaymentApp) { $PaymentApp = Get-TfOutput -Name 'payment_app_name' }

$action = if ($Reset.IsPresent) { 'disable' } else { 'enable' }
Write-Host "==> Will $action the leak directly on '$PaymentApp' (rg: $ResourceGroup)" -ForegroundColor Cyan

if (-not $PSCmdlet.ShouldProcess($PaymentApp, "set ENABLE_SLOW_LEAK=$desired on the live Container App")) {
    Write-Host '    (WhatIf) no change applied.'
    return
}

az containerapp update `
    --name $PaymentApp `
    --resource-group $ResourceGroup `
    --set-env-vars "ENABLE_SLOW_LEAK=$desired" 1>$null
if ($LASTEXITCODE -ne 0) { throw "az containerapp update failed (exit $LASTEXITCODE)." }

if ($Reset.IsPresent) {
    Write-Host '==> Leak disabled. A new revision rolled out and memory reset.' -ForegroundColor Green
}
else {
    Write-Host '==> Incident armed. The memory alert should fire in roughly 8-12 min.' -ForegroundColor Green
    Write-Host '    Watch App Insights / the memory alert, then let the SRE Agent investigate and mitigate.'
}
