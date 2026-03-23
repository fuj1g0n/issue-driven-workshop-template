# destroy-workshop.ps1
# Usage: ./destroy-workshop.ps1 -ParticipantCount 5
#        ./destroy-workshop.ps1 -ParticipantCount 5 -DeleteAzureResources
#
# Prerequisites:
#   - az login (Azure CLI)
#   - gh auth login (GitHub CLI)
#   - config.json must exist
#
# This script will:
#   1. Delete each participant's Web App and GitHub repository
#   2. Optionally delete Azure resource group (all base resources)

param(
    [Parameter(Mandatory=$true)]
    [int]$ParticipantCount,

    [switch]$DeleteAzureResources
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ===========================================
# Load Configuration
# ===========================================
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.json not found." -ForegroundColor Red
    Write-Host "Cannot determine resource names without config.json." -ForegroundColor Yellow
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$resourceGroup = $config.azure.resourceGroup
$webAppNamePrefix = $config.azure.webAppNamePrefix
$ownerName = $config.github.owner
$repoPrefix = $config.github.repoPrefix

# ===========================================
# Confirmation
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "WARNING: Workshop Destruction Plan" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""
Write-Host "This will DELETE the following:" -ForegroundColor Yellow
Write-Host ""

for ($i = 1; $i -le $ParticipantCount; $i++) {
    $number = $i.ToString("D2")
    Write-Host "  Web App    : $webAppNamePrefix-$number" -ForegroundColor White
    Write-Host "  Repository : $ownerName/$repoPrefix-$number" -ForegroundColor White
    Write-Host ""
}

if ($DeleteAzureResources) {
    Write-Host "  Resource Group : $resourceGroup (ALL resources inside will be deleted)" -ForegroundColor Red
    Write-Host ""
}

$confirmation = Read-Host "Type 'destroy' to confirm"
if ($confirmation -ne "destroy") {
    Write-Host "Cancelled." -ForegroundColor Gray
    exit
}

# ===========================================
# Step 1: Delete Participant Environments
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 1: Deleting Participant Environments" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

for ($i = 1; $i -le $ParticipantCount; $i++) {
    $number = $i.ToString("D2")
    $webAppName = "$webAppNamePrefix-$number"
    $repoName = "$repoPrefix-$number"

    Write-Host ""
    Write-Host "--- Participant $number ---" -ForegroundColor Yellow

    # Delete Web App
    Write-Host "Deleting Web App: $webAppName" -ForegroundColor Yellow
    az webapp delete --name $webAppName --resource-group $resourceGroup 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Web App deleted" -ForegroundColor Green
    } else {
        Write-Host "  Web App not found or already deleted" -ForegroundColor Gray
    }

    # Delete GitHub Repository
    Write-Host "Deleting repository: $ownerName/$repoName" -ForegroundColor Yellow
    gh repo delete "$ownerName/$repoName" --yes 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Repository deleted" -ForegroundColor Green
    } else {
        Write-Host "  Repository not found or already deleted" -ForegroundColor Gray
    }
}

# ===========================================
# Step 2: Delete Service Principal (optional)
# ===========================================
if ($DeleteAzureResources) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Step 2: Deleting Service Principal" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $clientId = $config.oidc.clientId
    if ($clientId) {
        Write-Host "Deleting Service Principal (clientId: $clientId)..." -ForegroundColor Yellow
        az ad app delete --id $clientId 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Service Principal deleted" -ForegroundColor Green
        } else {
            Write-Host "  Service Principal not found or already deleted" -ForegroundColor Gray
        }
    }

# ===========================================
# Step 3: Delete Azure Resources (optional)
# ===========================================
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Step 3: Deleting Azure Resource Group" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host "Deleting resource group: $resourceGroup" -ForegroundColor Yellow
    az group delete --name $resourceGroup --yes --no-wait

    Write-Host "Resource group deletion initiated (running in background)" -ForegroundColor Green
}

# ===========================================
# Summary
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Workshop Cleanup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Deleted $ParticipantCount participant environment(s)" -ForegroundColor White
if ($DeleteAzureResources) {
    Write-Host "Resource group '$resourceGroup' is being deleted in the background" -ForegroundColor White
}
Write-Host ""
