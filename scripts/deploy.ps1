<#
.SYNOPSIS
    Single-command deployment for the ContosoPay / Azure SRE Agent demo.

.DESCRIPTION
    Orchestrates the full deploy:
      1. Validates prerequisites (az, terraform, docker, an az login).
      2. terraform init.
      3. terraform apply (phase 1) creating ACR/Key Vault/identities/observability/
         Container Apps environment WITHOUT the apps (images do not exist yet).
      4. Builds and pushes the three app images to ACR.
      5. terraform apply (phase 2) creating the Container Apps + alert,
         pointing at the freshly published, locked image digest.
      6. Prints the public frontend URL and SRE Agent wiring next-steps.

    No secrets are handled by this script. All app secrets live in Key Vault and
    are read by the apps via managed identity.

.PARAMETER SubscriptionName
    Optional subscription name or id to select before deploying. When omitted the
    currently selected az subscription is used.

.PARAMETER ImageTag
    Optional immutable image tag override. Defaults to the repository HEAD and
    must be a full lowercase 40-character Git commit SHA.

.PARAMETER SkipBuild
    Reuse images already in ACR (skip docker build/push). Useful for re-runs.

.PARAMETER Scenario
    Immutable deployment profile A or B. Scenario C must use deploy.yml on the
    private self-hosted runner.

.EXAMPLE
    pwsh ./scripts/deploy.ps1

.EXAMPLE
    pwsh ./scripts/deploy.ps1 -SubscriptionName 'My Subscription'

.OUTPUTS
    None. Writes status to the host and the frontend URL on success.

.NOTES
    Direct Terraform settings control whether this local path provisions the
    selected SRE Agent. The GitHub deployment workflows always provision it.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionName,

    [Parameter()]
    [string]$ImageTag,

    [Parameter()]
    [string]$Prefix = 'contosopay',

    [Parameter()]
    [string]$Environment = 'demo',

    [Parameter()]
    [string]$Location = 'swedencentral',

    [Parameter()]
    [ValidateSet('A', 'B')]
    [string]$Scenario = 'A',

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
    param(
        [string]$SubscriptionId,
        [string]$Prefix,
        [string]$Environment,
        [ValidateSet('A', 'B')]
        [string]$Scenario
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashInput = "$SubscriptionId$([char]0)$Prefix$([char]0)$Scenario"
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashInput))
    $hex = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower().Substring(0, 16)
    [pscustomobject]@{
        ResourceGroup  = "rg-$Prefix-tfstate"
        StorageAccount = "sttf$hex"            # 20 chars, globally unique-ish, LRS
        Container      = 'tfstate'
        Key            = "$Prefix-$Scenario-$Environment.tfstate"
    }
}

# Idempotently create the LRS state storage (no account keys: AAD data-plane auth).
function Initialize-StateStorage {
    param([object]$Backend, [string]$Location, [string]$PrincipalId, [hashtable]$Tags)
    Write-Host "==> Ensuring remote state storage ($($Backend.StorageAccount))" -ForegroundColor Cyan
    $tagArgs = ($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    # The state resource group's location is immutable and independent of the app
    # region -- if it already exists (e.g. an earlier deploy in another region),
    # reuse its location so switching -Location doesn't fail with
    # InvalidResourceGroupLocation.
    $stateLocation = az group show --name $Backend.ResourceGroup --query location --output tsv 2>$null
    if (-not $stateLocation) { $stateLocation = $Location }
    Invoke-Checked -Name 'az group create (tfstate)' {
        az group create --name $Backend.ResourceGroup --location $stateLocation --tags @tagArgs --output none
    }
    $exists = az storage account show --name $Backend.StorageAccount --resource-group $Backend.ResourceGroup --query name --output tsv 2>$null
    if (-not $exists) {
        Invoke-Checked -Name 'az storage account create (tfstate)' {
            az storage account create --name $Backend.StorageAccount --resource-group $Backend.ResourceGroup `
                --location $stateLocation --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
                --allow-blob-public-access false --allow-shared-key-access false --https-only true `
                --tags @tagArgs --output none
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
Assert-Command git

if (-not $ImageTag) {
    $ImageTag = git -C $repoRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not resolve the repository HEAD commit SHA.'
    }
}
if ($ImageTag -notmatch '^[0-9a-f]{40}$') {
    throw 'ImageTag must be a full lowercase 40-character Git commit SHA.'
}

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
$backend = Get-BackendConfig -SubscriptionId $account.id -Prefix $Prefix -Environment $Environment -Scenario $Scenario
$tags = @{ project = 'sre-agent-demo'; env = $Environment; scenario = $Scenario; managed_by = 'terraform' }
Initialize-StateStorage -Backend $backend -Location $Location -PrincipalId $signedInId -Tags $tags

Write-Host '==> terraform init (remote azurerm backend)' -ForegroundColor Cyan
Invoke-Checked -Name 'terraform init' {
    terraform -chdir="$infraDir" init -input=false -migrate-state -force-copy `
        -backend-config="resource_group_name=$($backend.ResourceGroup)" `
        -backend-config="storage_account_name=$($backend.StorageAccount)" `
        -backend-config="container_name=$($backend.Container)" `
        -backend-config="key=$($backend.Key)"
}

# Reject state created for another or legacy profile.
$stateResources = terraform -chdir="$infraDir" state list 2>$null
if ($stateResources) {
    $existingScenario = terraform -chdir="$infraDir" output -raw scenario 2>$null
    if ($existingScenario -ne $Scenario) {
        throw "State scenario '$existingScenario' does not match '$Scenario'. In-place conversion is unsupported."
    }
}

# Preserve the immutable application resource-group location on reruns.
$existingResourceGroup = terraform -chdir="$infraDir" output -raw resource_group_name 2>$null
if ($existingResourceGroup) {
    $existingLocation = az group show --name $existingResourceGroup --query location --output tsv 2>$null
    if ($existingLocation -and $existingLocation -ine $Location) {
        Write-Warning "Ignoring requested location '$Location'; existing resource group '$existingResourceGroup' is in '$existingLocation'."
        $Location = $existingLocation
    }
}

Write-Host '==> terraform apply (phase 1: platform, no apps yet)' -ForegroundColor Cyan
$existingAppDeployment = $stateResources | Where-Object { $_ -match '^azurerm_container_app\.app\[' }
if (-not $existingAppDeployment -and $PSCmdlet.ShouldProcess('infra', 'terraform apply phase 1')) {
    Invoke-Checked -Name 'terraform apply (phase 1)' {
        terraform -chdir="$infraDir" apply -input=false -auto-approve `
            -var 'deploy_apps=false' -var "scenario=$Scenario" -var "prefix=$Prefix" `
            -var "environment=$Environment" -var "location=$Location"
    }
} elseif ($existingAppDeployment) {
    Write-Host '    Existing app deployment detected; preserving running revisions.'
}


$acrName = terraform -chdir="$infraDir" output -raw acr_name
$acrLoginServer = terraform -chdir="$infraDir" output -raw acr_login_server
Write-Host "    ACR: $acrLoginServer"

Write-Host '==> Logging in to ACR' -ForegroundColor Cyan
Invoke-Checked -Name 'az acr login' { az acr login --name $acrName }

$repositoryList = az acr repository list --name $acrName --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not list ACR repositories.' }
$imageDigests = [ordered]@{}
foreach ($svc in $services) {
    $tagExists = $false
    if ($repositoryList -contains $svc) {
        $tags = az acr repository show-tags --name $acrName --repository $svc --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "Could not list tags for ACR repository '$svc'." }
        $tagExists = $tags -contains $ImageTag
    }

    if ($tagExists) {
        $metadata = az acr repository show --name $acrName --image "${svc}:$ImageTag" --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "Could not inspect image ${svc}:$ImageTag." }
        if ($metadata.changeableAttributes.writeEnabled -or $metadata.changeableAttributes.deleteEnabled) {
            throw "Image ${svc}:$ImageTag exists but is not write/delete locked."
        }
        Write-Host "==> Reusing locked image ${svc}:$ImageTag" -ForegroundColor Cyan
    } else {
        if ($SkipBuild.IsPresent) {
            throw "Image ${svc}:$ImageTag is absent and -SkipBuild was supplied."
        }
        $context = Join-Path $repoRoot "src/$svc"
        $imageSha = "${acrLoginServer}/${svc}:$ImageTag"
        Write-Host "==> Building $svc -> ${svc}:$ImageTag" -ForegroundColor Cyan
        Invoke-Checked -Name "docker build $svc" {
            docker build `
                --label "org.opencontainers.image.revision=$ImageTag" `
                --label "org.opencontainers.image.source=https://github.com/rutgerpels/sreagent" `
                -t $imageSha $context
        }
        Invoke-Checked -Name "docker push $svc" { docker push $imageSha }
        Invoke-Checked -Name "lock ACR image $svc" {
            az acr repository update --name $acrName --image "${svc}:$ImageTag" `
                --write-enabled false --delete-enabled false --output none
        }
        $metadata = az acr repository show --name $acrName --image "${svc}:$ImageTag" --output json | ConvertFrom-Json
    }
    if (
        $LASTEXITCODE -ne 0 -or
        $metadata.digest -notmatch '^sha256:[0-9a-f]{64}$' -or
        $metadata.changeableAttributes.writeEnabled -or
        $metadata.changeableAttributes.deleteEnabled
    ) {
        throw "Image ${svc}:$ImageTag does not resolve to a locked manifest digest."
    }
    $imageDigests[$svc] = $metadata.digest
}
$imageDigestsJson = $imageDigests | ConvertTo-Json -Compress

Write-Host '==> terraform apply (phase 2: container apps + alert)' -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess('infra', 'terraform apply phase 2')) {
    Invoke-Checked -Name 'terraform apply (phase 2)' {
        terraform -chdir="$infraDir" apply -input=false -auto-approve `
            -var 'deploy_apps=true' -var "image_tag=$ImageTag" `
            -var "image_digests=$imageDigestsJson" `
            -var "scenario=$Scenario" -var "prefix=$Prefix" `
            -var "environment=$Environment" -var "location=$Location"
    }
}

$appliedScenario = terraform -chdir="$infraDir" output -raw scenario
if ($appliedScenario -ne $Scenario) {
    throw "Applied Terraform state does not match Scenario $Scenario."
}

$frontendUrl = terraform -chdir="$infraDir" output -raw frontend_url
$resourceGroup = terraform -chdir="$infraDir" output -raw resource_group_name
$grafana = terraform -chdir="$infraDir" output -raw grafana_endpoint 2>$null
$brokerEndpoint = terraform -chdir="$infraDir" output -raw sre_remediation_broker_endpoint_url 2>$null

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' ContosoPay demo deployed' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  Frontend URL : $frontendUrl"
Write-Host "  Resource grp : $resourceGroup"
Write-Host "  Scenario     : $Scenario"
if ($grafana) { Write-Host "  Grafana      : $grafana" }
if ($brokerEndpoint -and $brokerEndpoint -ne 'null') { Write-Host "  MCP broker   : $brokerEndpoint" }
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
if ($Scenario -eq 'A') {
    Write-Host '  3. Follow docs/scenario-a-direct.md and run scripts/trigger-incident-direct.ps1.'
} else {
    Write-Host '  3. Follow docs/scenario-b-gitops.md and run scripts/trigger-incident-gitops.ps1.'
}
Write-Host ''
