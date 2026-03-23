# init-workshop.ps1
# Usage: ./init-workshop.ps1 -ParticipantCount 5
#
# Prerequisites:
#   - az login (Azure CLI)
#   - gh auth login (GitHub CLI)
#
# This script will:
#   1. Create Azure resource group, App Service plan, and Storage account
#   2. Generate config.json automatically
#   3. Set up each participant's environment (Web App + repo + secrets + deploy)

param(
    [Parameter(Mandatory=$true)]
    [int]$ParticipantCount,

    [string]$Location = "swedencentral",
    [string]$ResourceGroup = "",
    [string]$AppServicePlan = "",
    [string]$StorageAccount = "",
    [string]$WebAppNamePrefix = "",
    [string]$GitHubOwner = "",
    [string]$TemplateRepo = "",
    [string]$RepoPrefix = "",
    [string]$Visibility = "public",
    [string]$Sku = "P0v4"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ===========================================
# Validation
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validating prerequisites" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check Azure CLI login
$azAccount = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Azure CLI is not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}
$subscriptionName = ($azAccount | ConvertFrom-Json).name
Write-Host "Azure subscription: $subscriptionName" -ForegroundColor Green

# Check GitHub CLI login
$ghStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: GitHub CLI is not logged in. Run 'gh auth login' first." -ForegroundColor Red
    exit 1
}
Write-Host "GitHub CLI: authenticated" -ForegroundColor Green

# Auto-detect GitHub owner if not specified
if (-not $GitHubOwner) {
    $GitHubOwner = (gh api user --jq '.login') 2>$null
    if (-not $GitHubOwner) {
        Write-Host "ERROR: Could not detect GitHub username. Specify -GitHubOwner." -ForegroundColor Red
        exit 1
    }
}
Write-Host "GitHub owner: $GitHubOwner" -ForegroundColor Green

# Default template repo
if (-not $TemplateRepo) {
    $TemplateRepo = "$GitHubOwner/issue-driven-workshop-template"
}

# Generate a shared random suffix for resource names (6 chars, lowercase alphanumeric)
$suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })

if (-not $ResourceGroup)   { $ResourceGroup   = "rg-workshop-$suffix" }
if (-not $AppServicePlan)  { $AppServicePlan  = "plan-workshop-$suffix" }
if (-not $StorageAccount)  { $StorageAccount  = "saworkshop$suffix" }
if (-not $WebAppNamePrefix){ $WebAppNamePrefix = "app-workshop-$suffix" }
if (-not $RepoPrefix)      { $RepoPrefix      = "workshop-$suffix" }

# ===========================================
# Confirmation
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Workshop Setup Plan" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Participants     : $ParticipantCount" -ForegroundColor White
Write-Host "Location         : $Location" -ForegroundColor White
Write-Host "Resource Group   : $ResourceGroup" -ForegroundColor White
Write-Host "App Service Plan : $AppServicePlan ($Sku)" -ForegroundColor White
Write-Host "Storage Account  : $StorageAccount" -ForegroundColor White
Write-Host "Web App Prefix   : $WebAppNamePrefix" -ForegroundColor White
Write-Host "GitHub Owner     : $GitHubOwner" -ForegroundColor White
Write-Host "Template Repo    : $TemplateRepo" -ForegroundColor White
Write-Host "Repo Prefix      : $RepoPrefix" -ForegroundColor White
Write-Host "Visibility       : $Visibility" -ForegroundColor White
Write-Host ""

$confirmation = Read-Host "Proceed? (yes/no)"
if ($confirmation -ne "yes") {
    Write-Host "Cancelled." -ForegroundColor Gray
    exit
}

# ===========================================
# Step 1: Create Azure Resources
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 1: Creating Azure Resources" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "Creating resource group: $ResourceGroup" -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none

Write-Host "Creating App Service plan: $AppServicePlan ($Sku)" -ForegroundColor Yellow
az appservice plan create --name $AppServicePlan --resource-group $ResourceGroup --location $Location --sku $Sku --output none

Write-Host "Creating storage account: $StorageAccount" -ForegroundColor Yellow
az storage account create --name $StorageAccount --resource-group $ResourceGroup --location $Location --sku Standard_LRS --output none

Write-Host "Azure resources created" -ForegroundColor Green

# ===========================================
# Step 2: Create Service Principal with OIDC
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 2: Creating Service Principal for OIDC" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$spName = "sp-workshop-$suffix"
$subscriptionId = (az account show --query id -o tsv)
$tenantId = (az account show --query tenantId -o tsv)

Write-Host "Creating Service Principal: $spName" -ForegroundColor Yellow
$spJson = az ad sp create-for-rbac --name $spName --role Contributor --scopes "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup" --query "{clientId: appId, objectId: id}" -o json
$sp = $spJson | ConvertFrom-Json
$clientId = $sp.clientId

Write-Host "Service Principal created (clientId: $clientId)" -ForegroundColor Green

# Configure OIDC federated credentials for GitHub Actions
Write-Host "Configuring OIDC federated credentials..." -ForegroundColor Yellow
$appObjectId = az ad app show --id $clientId --query id -o tsv

# Federated credential for pull_request events
$prCredential = @{
    name = "github-pr-$suffix"
    issuer = "https://token.actions.githubusercontent.com"
    subject = "repo:$RepoOwner/*:pull_request"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json -Compress

az ad app federated-credential create --id $appObjectId --parameters $prCredential --output none
Write-Host "OIDC federated credential configured for pull_request events" -ForegroundColor Green

# ===========================================
# Step 3: Generate config.json
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 3: Generating config.json" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$config = @{
    azure = @{
        resourceGroup    = $ResourceGroup
        appServicePlan   = $AppServicePlan
        storageAccount   = $StorageAccount
        webAppNamePrefix = $WebAppNamePrefix
        tableNamePrefix  = "Expenses"
    }
    oidc = @{
        clientId       = $clientId
        tenantId       = $tenantId
        subscriptionId = $subscriptionId
    }
    github = @{
        owner        = $GitHubOwner
        templateRepo = $TemplateRepo
        repoPrefix   = $RepoPrefix
        visibility   = $Visibility
    }
}

$configPath = Join-Path $PSScriptRoot "config.json"
$config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8
Write-Host "config.json generated" -ForegroundColor Green

# ===========================================
# Step 4: Setup Each Participant
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 4: Setting Up Participants" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$setupScript = Join-Path $PSScriptRoot "setup-participant.ps1"
$results = @()

for ($i = 1; $i -le $ParticipantCount; $i++) {
    $number = $i.ToString("D2")
    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host "Participant $number ($i/$ParticipantCount)" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Cyan

    try {
        & $setupScript -Number $number
        $results += @{ Number = $number; Status = "OK" }
    }
    catch {
        Write-Host "ERROR: Failed to setup participant $number - $_" -ForegroundColor Red
        $results += @{ Number = $number; Status = "FAILED: $_" }
    }
}

# ===========================================
# Summary
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Workshop Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Azure Resources:" -ForegroundColor White
Write-Host "  Resource Group   : $ResourceGroup" -ForegroundColor White
Write-Host "  App Service Plan : $AppServicePlan" -ForegroundColor White
Write-Host "  Storage Account  : $StorageAccount" -ForegroundColor White
Write-Host ""
Write-Host "Participant Results:" -ForegroundColor White

foreach ($r in $results) {
    $color = if ($r.Status -eq "OK") { "Green" } else { "Red" }
    $webApp = "$WebAppNamePrefix-$($r.Number)"
    $repo = "$GitHubOwner/$RepoPrefix-$($r.Number)"
    Write-Host "  [$($r.Status)] $($r.Number) - https://$webApp.azurewebsites.net | https://github.com/$repo" -ForegroundColor $color
}

Write-Host ""
Write-Host "Template Repo: https://github.com/$TemplateRepo" -ForegroundColor White
Write-Host ""
