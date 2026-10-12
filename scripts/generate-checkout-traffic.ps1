<#
.SYNOPSIS
    Send bounded synthetic checkout traffic to the Scenario D frontend.

.DESCRIPTION
    Posts generated test orders to the public frontend /api/checkout endpoint at
    a fixed rate for a finite duration. Start it before arming the incident and
    keep it running through recovery so alerts and the post-fix check have data.

.PARAMETER FrontendUrl
    Frontend HTTPS URL. Defaults to terraform output frontend_url.

.PARAMETER DurationSeconds
    How long to send traffic. Default 900, maximum 3600.

.PARAMETER IntervalSeconds
    Pause between orders. Default 5, minimum 1.

.EXAMPLE
    pwsh ./scripts/generate-checkout-traffic.ps1 -DurationSeconds 600

.OUTPUTS
    None. Writes per-order status to the host.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$FrontendUrl,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$DurationSeconds = 900,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $FrontendUrl) {
    $infraDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'infra'
    $FrontendUrl = (terraform -chdir="$infraDir" output -raw frontend_url 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($FrontendUrl)) {
        throw 'Could not read terraform output frontend_url; pass -FrontendUrl.'
    }
}
$FrontendUrl = $FrontendUrl.Trim().TrimEnd('/')
if (-not $FrontendUrl.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Frontend URL must use https.'
}

$endpoint = "$FrontendUrl/api/checkout"
$stopAt = (Get-Date).AddSeconds($DurationSeconds)
$ok = 0
$failed = 0

Write-Host "==> Sending test orders to $endpoint every ${IntervalSeconds}s for ${DurationSeconds}s"
try {
    while ((Get-Date) -lt $stopAt) {
        $body = @{ amount = [math]::Round((Get-Random -Minimum 10.0 -Maximum 100.0), 2); currency = 'EUR' } | ConvertTo-Json -Compress
        try {
            $response = Invoke-WebRequest -Uri $endpoint -Method Post -ContentType 'application/json' `
                -Body $body -TimeoutSec 10 -SkipHttpErrorCheck
            $code = [int]$response.StatusCode
        }
        catch {
            $code = 0
        }
        if ($code -ge 200 -and $code -lt 300) { $ok++ } else { $failed++ }
        Write-Host ("{0:HH:mm:ss} status={1} ok={2} failed={3}" -f (Get-Date).ToUniversalTime(), $code, $ok, $failed)
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    Write-Host "==> Stopped. ok=$ok failed=$failed"
}
