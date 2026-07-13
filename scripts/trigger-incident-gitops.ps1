<#
.SYNOPSIS
    Trigger (or reset) the ContosoPay demo incident the GitOps way.

.DESCRIPTION
    Instead of poking the live Azure resources, this script opens a PULL REQUEST
    that flips the planted memory-leak flag (enable_slow_leak) in the committed
    IaC file infra/leak.auto.tfvars.

    Merging that PR runs .github/workflows/apply-infra.yml, which performs a
    `terraform apply` against the remote state and deploys the change. This is
    the realistic, change-managed path: the incident enters the system as a code
    change with a reviewable diff and a deployment, exactly like a real
    regression -- and exactly the kind of change the Azure SRE Agent can later
    correlate the incident back to.

    Requires the GitHub CLI (`gh`) authenticated against this repository.

.PARAMETER Reset
    Open a PR that turns the leak back OFF (enable_slow_leak = false) instead of
    arming it. Use this if you want to script the "fix" yourself; normally the
    SRE Agent opens the reset PR as its remediation.

.PARAMETER Branch
    Override the branch name created for the PR. Defaults to a convention-based,
    timestamped name (Feature/... to arm, Bug/... to reset).

.PARAMETER Base
    Base branch the PR targets. Defaults to 'main'.

.PARAMETER NoPr
    Push the branch but skip `gh pr create` (open the PR manually).

.EXAMPLE
    pwsh ./scripts/trigger-incident-gitops.ps1
    # Opens a PR arming the leak. Review + merge it to start the incident.

.EXAMPLE
    pwsh ./scripts/trigger-incident-gitops.ps1 -Reset

.OUTPUTS
    None. Writes status and the created PR URL to the host.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch]$Reset,

    [Parameter()]
    [string]$Branch,

    [Parameter()]
    [string]$Base = 'main',

    [Parameter()]
    [switch]$NoPr
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$tfvarsFile = Join-Path $repoRoot 'infra/leak.auto.tfvars'
$desired = if ($Reset.IsPresent) { 'false' } else { 'true' }
$stamp = Get-Date -AsUTC -Format 'yyyyMMddHHmmss'

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Script)
    & $Script
    if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $Name" }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Required command 'git' not found on PATH." }
if (-not $NoPr.IsPresent -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "Required command 'gh' (GitHub CLI) not found on PATH. Install it, run 'gh auth login', or pass -NoPr."
}
git -C $repoRoot rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "$repoRoot is not a git repository." }
if (-not (Test-Path $tfvarsFile)) { throw "Source-of-truth file not found: $tfvarsFile" }

if (-not $Branch) {
    $Branch = if ($Reset.IsPresent) { "Bug/disable-memory-leak-$stamp" } else { "Feature/trigger-memory-leak-$stamp" }
}

$action = if ($Reset.IsPresent) { 'disable' } else { 'enable' }
$title = if ($Reset.IsPresent) {
    'fix(payment-service): disable slow memory leak (enable_slow_leak=false)'
} else {
    'demo(payment-service): enable slow memory leak (enable_slow_leak=true)'
}
$why = if ($Reset.IsPresent) {
    'Remediates the ContosoPay memory-leak incident by turning the planted fault off. Merging this PR runs the `apply-infra` workflow, which `terraform apply`s the change and rolls a fresh payment-service revision (clearing leaked memory).'
} else {
    'Arms the ContosoPay demo incident. Merging this PR runs the `apply-infra` workflow, which `terraform apply`s the change and deploys the leak. payment-service memory then climbs for roughly 8-12 min until the Azure Monitor alert fires and the SRE Agent investigates.'
}
$body = @"
## What

Sets ``enable_slow_leak = $desired`` in ``infra/leak.auto.tfvars``.

## Why

$why

## How it deploys

GitOps only -- no one edits the live Azure resources by hand. Merge to ``$Base`` -> ``.github/workflows/apply-infra.yml`` -> ``terraform apply``.
"@

Write-Host "==> Will $action the leak via a PR ($Branch -> $Base)" -ForegroundColor Cyan

if (-not $PSCmdlet.ShouldProcess($tfvarsFile, "open PR to set enable_slow_leak=$desired")) {
    Write-Host '    (WhatIf) no branch/commit/PR created.'
    return
}

# Work from an up-to-date base without disturbing the user's current checkout.
Invoke-Checked -Name 'git fetch' { git -C $repoRoot fetch origin $Base }
Invoke-Checked -Name 'git checkout -b' { git -C $repoRoot checkout -b $Branch "origin/$Base" }

try {
    $content = Get-Content -Path $tfvarsFile
    $updated = $content -replace '^\s*enable_slow_leak\s*=.*', "enable_slow_leak = $desired"
    Set-Content -Path $tfvarsFile -Value $updated -Encoding ascii

    git -C $repoRoot diff --quiet -- $tfvarsFile
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    enable_slow_leak is already $desired; nothing to change." -ForegroundColor Yellow
        git -C $repoRoot checkout $Base *> $null
        git -C $repoRoot branch -D $Branch *> $null
        return
    }

    Invoke-Checked -Name 'git add' { git -C $repoRoot add $tfvarsFile }
    Invoke-Checked -Name 'git commit' { git -C $repoRoot commit -m $title }
    Invoke-Checked -Name 'git push' { git -C $repoRoot push -u origin $Branch }

    if ($NoPr.IsPresent) {
        Write-Host "==> Branch pushed. Open a PR from '$Branch' into '$Base' to deploy the change." -ForegroundColor Yellow
    }
    else {
        $repoSlug = gh repo view --json nameWithOwner -q '.nameWithOwner'
        $prUrl = gh pr create --repo $repoSlug --base $Base --head $Branch --title $title --body $body
        if ($LASTEXITCODE -ne 0) { throw 'gh pr create failed.' }
        Write-Host '==> Pull request opened:' -ForegroundColor Green
        Write-Host "    $prUrl"
        Write-Host '    Review + merge it to deploy the change (apply-infra workflow runs on merge).'
    }
}
finally {
    # Return the working tree to the base branch so the user is where they started.
    git -C $repoRoot checkout $Base *> $null
}
