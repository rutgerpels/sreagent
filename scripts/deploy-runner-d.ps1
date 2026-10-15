#Requires -Version 7.0
<#
.SYNOPSIS
    Provisions the Scenario D private runner (VNet, NAT gateway, VM) and registers it with GitHub.

.DESCRIPTION
    Operator-side bootstrap that runs once per subscription. It:
      1. applies infra/runner-d (Terraform, local git-ignored state);
      2. fetches a short-lived runner registration token with the gh CLI;
      3. installs Docker/az/Node and registers the runner through az vm run-command.

    Requires an existing `az login`, `gh auth login`, and Terraform. No secret is written to the
    repository, Terraform state, or VM custom data.

.PARAMETER SubscriptionName
    Display name of the target subscription. The ID is resolved at run time and never persisted.

.PARAMETER Repository
    Required customer GitHub repository (owner/name) the runner registers with.

.PARAMETER VnetName
    Name of the runner VNet to create. Set D_RUNNER_VNET_NAME to this value.

.PARAMETER ResourceGroupName
    Resource group to create for the retained foundation. Set D_RUNNER_NETWORK_RG to this value.

.PARAMETER SkipTerraform
    Skip the Terraform apply and only (re)register the runner on an existing VM.

.PARAMETER Destroy
    Remove the runner registration and destroy the foundation instead of creating it.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository,

    [Parameter()]
    [string]$Location = 'swedencentral',

    [Parameter()]
    [string]$ResourceGroupName = 'agentrg-d',

    [Parameter()]
    [string]$VnetName = 'agent-vnet-d',

    [Parameter()]
    [string]$VmName = 'vm-payd-runner',

    [Parameter()]
    [string]$RunnerLabels = 'self-hosted,Linux,X64,azure-private-d,contosopay',

    [Parameter()]
    [switch]$SkipTerraform,

    [Parameter()]
    [switch]$Destroy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$terraformDir = Join-Path $repoRoot 'infra/runner-d'
$installScript = Join-Path $PSScriptRoot 'runner-d-install.sh'

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$subscriptionId = az account list --query "[?name=='$SubscriptionName'].id | [0]" -o tsv
if (-not $subscriptionId) {
    throw "Subscription '$SubscriptionName' not found in the current az login."
}
Invoke-Native az @('account', 'set', '--subscription', $subscriptionId)
$env:ARM_SUBSCRIPTION_ID = $subscriptionId

if ($Destroy) {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Destroy Scenario D runner foundation')) {
        $runnerId = gh api "repos/$Repository/actions/runners" --jq ".runners[] | select(.name==`"$VmName`") | .id"
        if ($runnerId) {
            Invoke-Native gh @('api', '-X', 'DELETE', "repos/$Repository/actions/runners/$runnerId")
        }
        Invoke-Native terraform @("-chdir=$terraformDir", 'destroy', '-auto-approve', '-input=false', '-var', 'admin_ssh_public_key=unused')
    }
    return
}

if (-not $SkipTerraform) {
    # The VM is only managed through run-command, so the SSH key is throwaway: generate it,
    # hand Terraform the public half and discard the private half.
    $keyDir = Join-Path $repoRoot (".runner-d-key-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $keyDir | Out-Null
    try {
        $keyPath = Join-Path $keyDir 'id'
        Invoke-Native ssh-keygen @('-q', '-t', 'ed25519', '-N', '', '-f', $keyPath)
        $publicKey = (Get-Content -Path "$keyPath.pub" -Raw).Trim()

        Invoke-Native terraform @("-chdir=$terraformDir", 'init', '-input=false')
        Invoke-Native terraform @(
            "-chdir=$terraformDir", 'apply', '-auto-approve', '-input=false',
            '-var', "location=$Location",
            '-var', "resource_group_name=$ResourceGroupName",
            '-var', "vnet_name=$VnetName",
            '-var', "vm_name=$VmName",
            '-var', "admin_ssh_public_key=$publicKey")
    }
    finally {
        Remove-Item -Path $keyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$registrationToken = gh api -X POST "repos/$Repository/actions/runners/registration-token" --jq '.token'
if (-not $registrationToken) {
    throw 'Could not obtain a runner registration token (needs repo admin permission).'
}

Write-Host "Installing tooling and registering runner '$VmName' (this takes a few minutes)..."
$result = az vm run-command invoke `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --command-id RunShellScript `
    --scripts "@$installScript" `
    --parameters $Repository $VmName $RunnerLabels $registrationToken `
    --query 'value[0].message' -o tsv
Write-Host $result

Write-Host 'Runner status on GitHub:'
gh api "repos/$Repository/actions/runners" --jq ".runners[] | select(.name==`"$VmName`") | {name, status, labels: [.labels[].name]}"
Write-Host 'Configure these repository Actions variables before deploying the D workload:'
Write-Host "D_RUNNER_NETWORK_RG=$ResourceGroupName"
Write-Host "D_RUNNER_VNET_NAME=$VnetName"
