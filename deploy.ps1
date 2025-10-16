# DLP Policy Enrichment Playbook Deployment Script
# This script deploys the Logic App playbook and configures necessary permissions

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory=$false)]
    [string]$PlaybookName = "DLPPolicyEnrichment-Playbook",

    [Parameter(Mandatory=$false)]
    [string]$Location,

    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = "parameters.json"
)

# Import required modules
Write-Host "Checking required PowerShell modules..." -ForegroundColor Cyan

$requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.LogicApp', 'Az.OperationalInsights', 'AzureAD')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module" -ForegroundColor Yellow
        Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser
    }
    Import-Module $module
}

# Connect to Azure
Write-Host "`nConnecting to Azure..." -ForegroundColor Cyan
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount
    }
    Write-Host "Connected to Azure subscription: $($context.Subscription.Name)" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to Azure: $_"
    exit 1
}

# Get tenant ID
$tenantId = (Get-AzContext).Tenant.Id
Write-Host "Tenant ID: $tenantId" -ForegroundColor Green

# Verify resource group exists
Write-Host "`nVerifying resource group..." -ForegroundColor Cyan
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Error "Resource group '$ResourceGroupName' not found. Please create it first."
    exit 1
}

if (-not $Location) {
    $Location = $rg.Location
}
Write-Host "Using location: $Location" -ForegroundColor Green

# Verify Sentinel workspace exists
Write-Host "`nVerifying Sentinel workspace..." -ForegroundColor Cyan
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
if (-not $workspace) {
    Write-Error "Sentinel workspace '$WorkspaceName' not found in resource group '$ResourceGroupName'."
    exit 1
}
Write-Host "Found workspace: $WorkspaceName" -ForegroundColor Green

# Prepare deployment parameters
Write-Host "`nPreparing deployment parameters..." -ForegroundColor Cyan
$deploymentParams = @{
    PlaybookName = $PlaybookName
    WorkspaceName = $WorkspaceName
    WorkspaceResourceGroup = $ResourceGroupName
    SubscriptionId = (Get-AzContext).Subscription.Id
}

# Deploy the Logic App
Write-Host "`nDeploying Logic App playbook..." -ForegroundColor Cyan
Write-Host "Deployment parameters:" -ForegroundColor Yellow
$deploymentParams | Format-Table -AutoSize

try {
    $deployment = New-AzResourceGroupDeployment `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile "DLPPolicyEnrichment-Playbook.json" `
        -TemplateParameterObject $deploymentParams `
        -Name "DLPEnrichment-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
        -Verbose

    Write-Host "`nPlaybook deployed successfully!" -ForegroundColor Green
    Write-Host "Playbook Name: $($deployment.Outputs.playbookName.Value)" -ForegroundColor Green
} catch {
    Write-Error "Deployment failed: $_"
    exit 1
}

# Get the Logic App's Managed Identity
Write-Host "`nRetrieving Managed Identity..." -ForegroundColor Cyan
Start-Sleep -Seconds 10  # Wait for identity to propagate

$logicApp = Get-AzLogicApp -ResourceGroupName $ResourceGroupName -Name $PlaybookName
$principalId = $logicApp.Identity.PrincipalId

if (-not $principalId) {
    Write-Error "Failed to retrieve Managed Identity. Please check the Logic App configuration."
    exit 1
}

Write-Host "Managed Identity Principal ID: $principalId" -ForegroundColor Green

# Assign Sentinel Responder role
Write-Host "`nAssigning Microsoft Sentinel Responder role..." -ForegroundColor Cyan
try {
    $workspaceId = $workspace.ResourceId
    
    $roleAssignment = New-AzRoleAssignment `
        -ObjectId $principalId `
        -RoleDefinitionName "Microsoft Sentinel Responder" `
        -Scope $workspaceId `
        -ErrorAction SilentlyContinue
    
    if ($roleAssignment) {
        Write-Host "Sentinel Responder role assigned successfully!" -ForegroundColor Green
    } else {
        Write-Host "Role may already be assigned or assignment pending." -ForegroundColor Yellow
    }
} catch {
    if ($_.Exception.Message -like "*already exists*") {
        Write-Host "Sentinel Responder role already assigned." -ForegroundColor Yellow
    } else {
        Write-Warning "Failed to assign Sentinel Responder role: $_"
        Write-Host "You may need to assign this role manually." -ForegroundColor Yellow
    }
}

# Configure Graph API permissions
Write-Host "`nConfiguring Microsoft Graph API permissions..." -ForegroundColor Cyan
Write-Host "Connecting to Azure AD..." -ForegroundColor Yellow

try {
    Connect-AzureAD -TenantId $tenantId -ErrorAction Stop | Out-Null
    
    # Get Microsoft Graph Service Principal
    $graphApp = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

    # Required permissions
    $requiredPermissions = @(
        "SecurityAlert.Read.All",
        "SecurityIncident.Read.All",
        "InformationProtectionPolicy.Read.All"
    )
    
    foreach ($permissionName in $requiredPermissions) {
        Write-Host "Granting permission: $permissionName" -ForegroundColor Yellow
        
        $permission = $graphApp.AppRoles | Where-Object {$_.Value -eq $permissionName}
        
        if ($permission) {
            try {
                New-AzureADServiceAppRoleAssignment `
                    -ObjectId $principalId `
                    -PrincipalId $principalId `
                    -ResourceId $graphApp.ObjectId `
                    -Id $permission.Id `
                    -ErrorAction SilentlyContinue | Out-Null
                
                Write-Host "  ✓ $permissionName granted" -ForegroundColor Green
            } catch {
                if ($_.Exception.Message -like "*already exists*") {
                    Write-Host "  ✓ $permissionName already granted" -ForegroundColor Yellow
                } else {
                    Write-Warning "  ✗ Failed to grant $permissionName : $_"
                }
            }
        } else {
            Write-Warning "  ✗ Permission $permissionName not found"
        }
    }
    
    Write-Host "`nGraph API permissions configured!" -ForegroundColor Green
    
} catch {
    Write-Warning "Failed to configure Graph API permissions automatically: $_"
    Write-Host "`nPlease grant the following permissions manually:" -ForegroundColor Yellow
    Write-Host "  1. Go to Azure AD > Enterprise Applications" -ForegroundColor White
    Write-Host "  2. Search for: $PlaybookName" -ForegroundColor White
    Write-Host "  3. Go to Permissions > Add permission > Microsoft Graph > Application permissions" -ForegroundColor White
    Write-Host "  4. Add: SecurityAlert.Read.All, SecurityIncident.Read.All, InformationProtectionPolicy.Read.All" -ForegroundColor White
    Write-Host "  5. Grant admin consent" -ForegroundColor White
}

# Summary
Write-Host "`n" + ("="*80) -ForegroundColor Cyan
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Cyan
Write-Host ("="*80) -ForegroundColor Cyan
Write-Host "`nPlaybook deployed successfully!" -ForegroundColor Green
Write-Host "  Name: $PlaybookName" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "  Managed Identity: $principalId" -ForegroundColor White

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "  1. Authorize the Sentinel API Connection:" -ForegroundColor White
Write-Host "     - Go to: Azure Portal > Resource Groups > $ResourceGroupName" -ForegroundColor Gray
Write-Host "     - Find: azuresentinel-$PlaybookName" -ForegroundColor Gray
Write-Host "     - Click 'Edit API connection' > Authorize > Save" -ForegroundColor Gray

Write-Host "`n  2. Create Automation Rule in Sentinel:" -ForegroundColor White
Write-Host "     - Go to: Sentinel > Automation > Create > Automation rule" -ForegroundColor Gray
Write-Host "     - Trigger: When incident is created" -ForegroundColor Gray
Write-Host "     - Condition: Alert product name contains 'Purview' OR Title contains 'DLP'" -ForegroundColor Gray
Write-Host "     - Action: Run playbook > $PlaybookName" -ForegroundColor Gray

Write-Host "`n  3. Test the playbook with a DLP incident" -ForegroundColor White

Write-Host "`n  4. Verify enrichment in incident comments and tags" -ForegroundColor White

Write-Host "`n" + ("="*80) -ForegroundColor Cyan
Write-Host "For detailed documentation, see README.md" -ForegroundColor Cyan
Write-Host ("="*80) -ForegroundColor Cyan

