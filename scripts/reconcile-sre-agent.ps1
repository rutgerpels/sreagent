[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('apply', 'verify', 'render')]
    [string]$Mode,

    [string]$Subscription,
    [string]$ResourceGroup,
    [string]$Agent,
    [string]$Config = (Join-Path $PSScriptRoot '..\agent\scenario-c')
)

$ErrorActionPreference = 'Stop'
$arguments = @(
    (Join-Path $PSScriptRoot 'reconcile-sre-agent.mjs'),
    '--mode', $Mode,
    '--config', $Config
)

if ($Mode -ne 'render') {
    foreach ($required in @{
        Subscription = $Subscription
        ResourceGroup = $ResourceGroup
        Agent = $Agent
    }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($required.Value)) {
            throw "$($required.Key) is required for $Mode."
        }
    }
    $arguments += @(
        '--subscription', $Subscription,
        '--resource-group', $ResourceGroup,
        '--agent', $Agent
    )
}

& node @arguments
if ($LASTEXITCODE -ne 0) {
    throw "SRE Agent reconciliation failed with exit code $LASTEXITCODE."
}
