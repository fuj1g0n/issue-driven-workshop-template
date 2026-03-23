# setup-participant.ps1
# Usage: ./setup-participant.ps1 -Number "01"
# 
# Prerequisites:
#   - az login (Azure CLI)
#   - gh auth login (GitHub CLI)
#   - Copy config.json.template to config.json and fill in your values
#
# This script will:
#   1. Create Azure Web App
#   2. Configure app settings
#   3. Create repository from template
#   4. Set GitHub Actions secrets
#   5. Trigger initial deployment

param(
    [Parameter(Mandatory=$true)]
    [string]$Number
)

# ===========================================
# Load Configuration
# ===========================================
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.json not found." -ForegroundColor Red
    Write-Host "Copy config.json.template to config.json and fill in your values." -ForegroundColor Yellow
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

# Azure Resources
$resourceGroup = $config.azure.resourceGroup
$appServicePlan = $config.azure.appServicePlan
$webAppName = "$($config.azure.webAppNamePrefix)-$Number"
$storageAccount = $config.azure.storageAccount

# OIDC (for PR preview environments)
$clientId = $config.oidc.clientId
$tenantId = $config.oidc.tenantId
$subscriptionId = $config.oidc.subscriptionId

# App Settings
$tableName = "$($config.azure.tableNamePrefix)$Number"

# GitHub
$templateRepo = $config.github.templateRepo
$newRepoName = "$($config.github.repoPrefix)-$Number"
$ownerName = $config.github.owner
$visibility = if ($config.github.visibility) { "--$($config.github.visibility)" } else { "--public" }

# ===========================================
# Step 1: Create Azure Web App
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 1: Creating Azure Web App" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "Creating Web App: $webAppName" -ForegroundColor Yellow
az webapp create --name $webAppName --resource-group $resourceGroup --plan $appServicePlan --runtime "dotnet:8" --tags "CostControl=Ignore" "SecurityControl=Ignore" --basic-auth Enabled

# ===========================================
# Step 2: Configure App Settings & Managed Identity
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 2: Configuring App Settings & Managed Identity" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

az webapp config appsettings set --name $webAppName --resource-group $resourceGroup --settings "AzureTableStorage__StorageAccountName=$storageAccount" "AzureTableStorage__TableName=$tableName" --output none

Write-Host "Configuring 64-bit platform..." -ForegroundColor Yellow
az webapp config set --name $webAppName --resource-group $resourceGroup --use-32bit-worker-process false --output none

Write-Host "Enabling Managed Identity..." -ForegroundColor Yellow
$principalId = az webapp identity assign --name $webAppName --resource-group $resourceGroup --query principalId -o tsv

Write-Host "Assigning Storage Table Data Contributor role..." -ForegroundColor Yellow
$storageId = az storage account show --name $storageAccount --resource-group $resourceGroup --query id -o tsv
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Table Data Contributor" --scope $storageId --output none

Write-Host "App settings and Managed Identity configured" -ForegroundColor Green

# ===========================================
# Step 3: Get Publish Profile
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 3: Getting Publish Profile" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$publishProfile = az webapp deployment list-publishing-profiles --name $webAppName --resource-group $resourceGroup --xml
Write-Host "Publish profile retrieved" -ForegroundColor Green

# ===========================================
# Step 4: Create Repository from Template
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 4: Creating Repository from Template" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "Creating repository: $ownerName/$newRepoName" -ForegroundColor Yellow
gh repo create "$ownerName/$newRepoName" --template "$templateRepo" $visibility --clone=false

# Wait for repository to be ready
Write-Host "Waiting for repository to be ready..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# ===========================================
# Step 5: Remove _admin folder from participant repo
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 5: Removing _admin folder from participant repo" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$repoFullName = "$ownerName/$newRepoName"
$adminFiles = gh api "repos/$repoFullName/contents/_admin" --jq '.[].path' 2>$null
if ($adminFiles) {
    foreach ($filePath in $adminFiles) {
        $sha = gh api "repos/$repoFullName/contents/$filePath" --jq '.sha'
        gh api --method DELETE "repos/$repoFullName/contents/$filePath" -f message="Remove admin scripts (not needed for participants)" -f sha="$sha" --silent
    }
    Write-Host "_admin folder removed from participant repo" -ForegroundColor Green
} else {
    Write-Host "_admin folder not found, skipping" -ForegroundColor Gray
}

# ===========================================
# Step 6: Set GitHub Secrets
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 6: Setting GitHub Secrets" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "Setting AZURE_WEBAPP_NAME (as variable)..." -ForegroundColor Yellow
gh variable set AZURE_WEBAPP_NAME --body $webAppName --repo "$ownerName/$newRepoName"

Write-Host "Setting AZURE_WEBAPP_PUBLISH_PROFILE (as secret)..." -ForegroundColor Yellow
$publishProfile | gh secret set AZURE_WEBAPP_PUBLISH_PROFILE --repo "$ownerName/$newRepoName"

Write-Host "Setting OIDC variables for PR preview environments..." -ForegroundColor Yellow
gh variable set AZURE_RESOURCE_GROUP --body $resourceGroup --repo "$ownerName/$newRepoName"
gh variable set AZURE_CLIENT_ID --body $clientId --repo "$ownerName/$newRepoName"
gh variable set AZURE_TENANT_ID --body $tenantId --repo "$ownerName/$newRepoName"
gh variable set AZURE_SUBSCRIPTION_ID --body $subscriptionId --repo "$ownerName/$newRepoName"

# ===========================================
# Step 7: Trigger Initial Deployment
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 7: Triggering Initial Deployment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "Waiting for repository to be fully ready..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

Write-Host "Triggering deployment workflow..." -ForegroundColor Yellow
gh workflow run deploy.yml --repo "$ownerName/$newRepoName"
Write-Host "Deployment triggered" -ForegroundColor Green

# ===========================================
# Summary
# ===========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Web App URL  : https://$webAppName.azurewebsites.net" -ForegroundColor White
Write-Host "Repository   : https://github.com/$ownerName/$newRepoName" -ForegroundColor White
Write-Host "Table Name   : $tableName" -ForegroundColor White
Write-Host "Deployment   : Triggered (check Actions tab for status)" -ForegroundColor White
Write-Host ""
