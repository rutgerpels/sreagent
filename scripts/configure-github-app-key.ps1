<#
.SYNOPSIS
    Uploads a GitHub App private key to the existing demo Key Vault.

.DESCRIPTION
    Reads the private key from a file so it never appears in Terraform state or
    command-line arguments. Run from the private runner network. If OperatorCidr
    is supplied, the script temporarily enables the Key Vault public endpoint
    for that single IPv4 CIDR and restores the original configuration on exit.
    When required, it grants the signed-in user temporary secret-write access
    and removes that role assignment on exit.

.PARAMETER VaultName
    Existing demo Key Vault name.

.PARAMETER PrivateKeyPath
    Path to the PEM private key downloaded when the GitHub App key was created.

.PARAMETER SecretName
    Key Vault secret name. Defaults to github-app-private-key.

.PARAMETER OperatorCidr
    Optional public IPv4 CIDR, normally the operator's public IP followed by /32.

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
    [string]$SecretName = 'github-app-private-key',

    [Parameter()]
    [ValidatePattern('^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$')]
    [string]$OperatorCidr
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
if ($keyHeader -notmatch 'BEGIN (RSA )?PRIVATE KEY') {
    throw 'The supplied file does not look like a PEM private key.'
}

$originalPublicAccess = $null
$ruleAdded = $false
$publicAccessChanged = $false
$roleAdded = $false
$operatorObjectId = $null
$vaultResourceId = $null

if (-not $PSCmdlet.ShouldProcess($VaultName, "Store GitHub App private key as secret '$SecretName'")) {
    return
}

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
        --role 'Key Vault Secrets Officer' `
        --query '[0].id' `
        --output tsv
    if (-not $existingRole) {
        az role assignment create `
            --assignee-object-id $operatorObjectId `
            --assignee-principal-type User `
            --role 'Key Vault Secrets Officer' `
            --scope $vaultResourceId `
            --output none
        if ($LASTEXITCODE -ne 0) { throw 'Failed to grant temporary Key Vault secret write access.' }
        $roleAdded = $true
    }

    if ($OperatorCidr) {
        $vault = az keyvault show --name $VaultName | ConvertFrom-Json
        $originalPublicAccess = if ($vault.properties.publicNetworkAccess) {
            $vault.properties.publicNetworkAccess
        } else {
            'Disabled'
        }

        $existingRule = $vault.properties.networkAcls.ipRules |
            Where-Object { $_.value -eq $OperatorCidr }
        if (-not $existingRule) {
            az keyvault network-rule add `
                --name $VaultName `
                --ip-address $OperatorCidr `
                --output none
            if ($LASTEXITCODE -ne 0) { throw 'Failed to add the temporary Key Vault firewall rule.' }
            $ruleAdded = $true
        }

        if ($originalPublicAccess -ne 'Enabled') {
            az keyvault update `
                --name $VaultName `
                --public-network-access Enabled `
                --output none
            if ($LASTEXITCODE -ne 0) { throw 'Failed to enable the Key Vault public endpoint.' }
            $publicAccessChanged = $true
        }
    }

    Write-Host '==> Uploading GitHub App private key to Key Vault' -ForegroundColor Cyan
    $uploaded = $false
    for ($attempt = 0; $attempt -lt 12 -and -not $uploaded; $attempt++) {
        az keyvault secret set `
            --vault-name $VaultName `
            --name $SecretName `
            --file $PrivateKeyPath `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            $uploaded = $true
        } else {
            Start-Sleep -Seconds 5
        }
    }
    if (-not $uploaded) {
        throw 'Key upload failed. Run from the private runner network or supply a permitted -OperatorCidr.'
    }
    Write-Host "GitHub App private key stored as secret '$SecretName'." -ForegroundColor Green
} finally {
    if ($publicAccessChanged) {
        az keyvault update `
            --name $VaultName `
            --public-network-access $originalPublicAccess `
            --output none 2>$null
    }
    if ($ruleAdded) {
        az keyvault network-rule remove `
            --name $VaultName `
            --ip-address $OperatorCidr `
            --output none 2>$null
    }
    if ($roleAdded) {
        az role assignment delete `
            --assignee-object-id $operatorObjectId `
            --role 'Key Vault Secrets Officer' `
            --scope $vaultResourceId `
            --output none 2>$null
    }
}
