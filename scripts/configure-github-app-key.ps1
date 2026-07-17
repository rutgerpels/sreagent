<#
.SYNOPSIS
    Imports the Scenario C remediation GitHub App PEM as a Key Vault key.

.DESCRIPTION
    Imports the PEM as a non-exportable RSA key with only the sign operation.
    Run from the private runner network. The script never enables public access
    or adds firewall rules. It temporarily grants Key Vault Crypto Officer when
    required and removes only the role assignment it created.

.PARAMETER VaultName
    Existing Scenario C Key Vault name.

.PARAMETER PrivateKeyPath
    Path to the PEM private key downloaded when the remediation GitHub App key
    was created.

.PARAMETER KeyName
    Key Vault key name. Defaults to github-app-signing-key.

.PARAMETER Force
    Import a new key version when the named key already exists.

.EXAMPLE
    ./scripts/configure-github-app-key.ps1 -VaultName 'kv-example' -PrivateKeyPath './app.pem'

.OUTPUTS
    None.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VaultName,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$PrivateKeyPath,

    [Parameter()]
    [ValidatePattern('^[0-9A-Za-z-]{1,127}$')]
    [string]$KeyName = 'github-app-signing-key',

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) {
    throw "Required command 'az' was not found on PATH."
}

az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure. Run 'az login' first."
}

$keyHeader = Get-Content -LiteralPath $PrivateKeyPath -TotalCount 2
if (($keyHeader -join "`n") -notmatch 'BEGIN (RSA )?PRIVATE KEY') {
    throw 'The supplied file does not look like a PEM private key.'
}

if (-not $PSCmdlet.ShouldProcess(
        $VaultName,
        "Import non-exportable sign-only GitHub App key '$KeyName'"
    )) {
    return
}

$roleAssignmentId = $null
try {
    $operatorObjectId = az ad signed-in-user show --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $operatorObjectId) {
        throw 'Could not resolve the signed-in user object ID.'
    }

    $vaultResourceId = az keyvault show --name $VaultName --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $vaultResourceId) {
        throw "Could not resolve Key Vault '$VaultName'."
    }

    $existingRole = az role assignment list `
        --assignee $operatorObjectId `
        --scope $vaultResourceId `
        --role 'Key Vault Crypto Officer' `
        --query '[0].id' `
        --output tsv
    if (-not $existingRole) {
        $roleAssignmentId = az role assignment create `
            --assignee-object-id $operatorObjectId `
            --assignee-principal-type User `
            --role 'Key Vault Crypto Officer' `
            --scope $vaultResourceId `
            --query id `
            --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $roleAssignmentId) {
            throw 'Failed to grant temporary Key Vault Crypto Officer access.'
        }
    }

    $keyState = $null
    for ($attempt = 0; $attempt -lt 12 -and -not $keyState; $attempt++) {
        $keyError = (& az keyvault key show `
                --vault-name $VaultName `
                --name $KeyName `
                --output none 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) {
            $keyState = 'Exists'
            break
        }
        if ($keyError -match 'KeyNotFound|not found|status code: 404|\(404\)') {
            $keyState = 'Absent'
            break
        }
        if ($keyError -match 'Forbidden|AuthorizationFailed|status code: 403|\(403\)') {
            Start-Sleep -Seconds 5
            continue
        }
        throw "Could not verify whether key '$KeyName' exists: $($keyError.Trim())"
    }
    if (-not $keyState) {
        throw 'Key Vault Crypto Officer access did not become effective; refusing to import without verifying key existence.'
    }
    if ($keyState -eq 'Exists' -and -not $Force.IsPresent) {
        throw "Key '$KeyName' already exists. Use -Force only when rotating the GitHub App key."
    }

    Write-Host '==> Importing non-exportable GitHub App signing key' -ForegroundColor Cyan
    $imported = $false
    for ($attempt = 0; $attempt -lt 12 -and -not $imported; $attempt++) {
        az keyvault key import `
            --vault-name $VaultName `
            --name $KeyName `
            --pem-file $PrivateKeyPath `
            --ops sign `
            --exportable false `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            $imported = $true
        } else {
            Start-Sleep -Seconds 5
        }
    }
    if (-not $imported) {
        throw 'Key import failed. Run from the private runner network and verify Key Vault RBAC propagation.'
    }

    Write-Host "Imported key '$KeyName' with sign-only operations. The private key cannot be downloaded." -ForegroundColor Green
} finally {
    if ($roleAssignmentId) {
        $removed = $false
        for ($attempt = 0; $attempt -lt 6 -and -not $removed; $attempt++) {
            az role assignment delete --ids $roleAssignmentId --output none 2>$null
            $remaining = az role assignment list `
                --assignee $operatorObjectId `
                --scope $vaultResourceId `
                --role 'Key Vault Crypto Officer' `
                --query "[?id=='$roleAssignmentId'] | length(@)" `
                --output tsv 2>$null
            $removed = $LASTEXITCODE -eq 0 -and $remaining -eq '0'
            if (-not $removed) { Start-Sleep -Seconds 5 }
        }
        if (-not $removed) {
            throw "Could not remove temporary Key Vault Crypto Officer role assignment '$roleAssignmentId'."
        }
    }
}
