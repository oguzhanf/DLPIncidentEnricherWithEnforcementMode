# DLP Policy Context Enricher for Microsoft Sentinel

This solution automatically enriches Microsoft Sentinel incidents triggered by Microsoft Purview DLP alerts with policy context information, specifically the **Enforcement Mode** of the DLP policy that triggered the alert.

## Overview

When a Microsoft Purview DLP alert fires and creates an incident in Microsoft Sentinel (via Defender XDR integration), this playbook automatically:

1. Detects DLP-related incidents
2. Queries the Microsoft Graph Security API to retrieve DLP policy details
3. Extracts the **Enforcement Mode** and other policy metadata
4. Enriches the incident with:
   - **Incident Comment** containing policy details
   - **Tags** for easy filtering and searching

## Architecture

```
DLP Alert → Defender XDR → Sentinel Incident
                              ↓
                    [Playbook Triggered]
                              ↓
                    Query Graph API for Policy Details
                              ↓
                    Add Comment + Tags to Incident
```

## Components

- **DLPPolicyEnrichment-Playbook.json**: Azure Logic App ARM template
- **deploy.ps1**: PowerShell deployment script
- **parameters.json**: Configuration parameters

## Prerequisites

1. **Microsoft Sentinel** workspace
2. **Microsoft Purview** (formerly Compliance Center) with DLP policies configured
3. **Azure subscription** with permissions to:
   - Create Logic Apps
   - Create API Connections
   - Assign RBAC roles
4. **Required API Permissions** (will be configured during deployment):
   - `SecurityIncident.ReadWrite.All` (Sentinel)
   - `SecurityAlert.Read.All` (Graph API)
   - `InformationProtectionPolicy.Read.All` (Graph API)

## Deployment

### Option 1: Azure Portal (Deploy to Azure Button)

Click the button below to deploy directly to Azure:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Foguzhanf%2FDLPIncidentEnricherWithEnforcementMode%2Fmain%2FDLPPolicyEnrichment-Playbook.json)

### Option 2: PowerShell Deployment

1. **Clone or download this repository**

2. **Run the deployment script**:
   ```powershell
   .\deploy.ps1 -ResourceGroupName "your-rg-name" -WorkspaceName "your-sentinel-workspace"
   ```

### Option 3: Azure CLI

```bash
az deployment group create \
  --resource-group <your-rg-name> \
  --template-file DLPPolicyEnrichment-Playbook.json \
  --parameters PlaybookName="DLPPolicyEnrichment-Playbook" \
               WorkspaceName="<your-sentinel-workspace-name>"
```

## Post-Deployment Configuration

### 1. Grant API Permissions to Managed Identity

After deployment, the Logic App has a System-Assigned Managed Identity that needs permissions:

```powershell
# Get the playbook's managed identity
$playbook = Get-AzLogicApp -ResourceGroupName "your-rg" -Name "DLPPolicyEnrichment-Playbook"
$principalId = $playbook.Identity.PrincipalId

# Grant Microsoft Graph permissions
# This requires Global Administrator or Privileged Role Administrator
Connect-AzureAD

$graphApp = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# SecurityAlert.Read.All
$alertPermission = $graphApp.AppRoles | Where-Object {$_.Value -eq "SecurityAlert.Read.All"}
New-AzureADServiceAppRoleAssignment -ObjectId $principalId -PrincipalId $principalId `
  -ResourceId $graphApp.ObjectId -Id $alertPermission.Id

# InformationProtectionPolicy.Read.All
$policyPermission = $graphApp.AppRoles | Where-Object {$_.Value -eq "InformationProtectionPolicy.Read.All"}
New-AzureADServiceAppRoleAssignment -ObjectId $principalId -PrincipalId $principalId `
  -ResourceId $graphApp.ObjectId -Id $policyPermission.Id
```

### 2. Authorize Sentinel Connection

1. Go to Azure Portal → Resource Groups → Your RG
2. Find the API Connection: `azuresentinel-DLPPolicyEnrichment-Playbook`
3. Click **Edit API connection**
4. Click **Authorize** and sign in with an account that has Sentinel permissions
5. Click **Save**

### 3. Assign Sentinel Responder Role

```powershell
# Grant Sentinel Responder role to the managed identity
$workspaceId = "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>"

New-AzRoleAssignment -ObjectId $principalId `
  -RoleDefinitionName "Microsoft Sentinel Responder" `
  -Scope $workspaceId
```

### 4. Configure Automation Rule in Sentinel

**⚠️ CRITICAL: Without this step, the playbook will NOT trigger automatically!**

1. Go to **Microsoft Sentinel** → **Automation**
2. Click **+ Create** → **Automation rule**
3. Configure:
   - **Name**: "Enrich DLP Incidents from Defender XDR"
   - **Trigger**: When incident is created
   - **Conditions**:
     - **Incident provider** → **Equals** → **Microsoft 365 Defender** (ensures it only runs for Defender XDR incidents)
     - **AND** (optional): **Title** → **Contains** → **DLP** (further filters for DLP-specific incidents)
   - **Actions**:
     - **Run playbook** → Select **DLPPolicyEnrichment-Playbook**
   - **Order**: 1
   - **Expiration**: Leave blank
4. Click **Apply**

### 5. Verify Defender XDR Integration

Ensure Defender XDR incidents are syncing to Sentinel:

1. Go to **Microsoft Sentinel** → **Settings** → **Microsoft Defender XDR**
2. Verify **Connect incidents & alerts** is **enabled**
3. Ensure incident sync includes Microsoft Purview DLP alerts

## How It Works

### Incident Detection
The playbook triggers when a new incident is created in Sentinel. It filters for DLP-related incidents by checking:
- Related analytic rule IDs contain "DLP"
- Alert product name is "Microsoft Purview"

### API Calls
1. **Get Alert Details**: Queries Microsoft Graph Security API for alert details
2. **Extract Policy ID**: Parses the alert to find the DLP Policy ID
3. **Get Policy Details**: Calls Graph API to retrieve full policy information including Enforcement Mode

### Enrichment
The playbook adds:

**Incident Comment**:
```
DLP Policy Enrichment

Policy Name: Sensitive Data Protection Policy
Policy ID: 12345678-1234-1234-1234-123456789abc
Enforcement Mode: Enforce
Mode: Production

Enriched by automated playbook at 2025-10-15T10:30:00Z
```

**Tags**:
- `EnforcementMode:Enforce` (or Test, Audit, etc.)
- `DLPPolicy:<PolicyName>`
- `AutoEnriched`

## Querying Enriched Data

### Find all incidents with specific enforcement mode:
```kql
SecurityIncident
| where Tags has "EnforcementMode:Enforce"
| project TimeGenerated, IncidentNumber, Title, Severity, Status, Tags
```

### Get enrichment details from comments:
```kql
SecurityIncident
| join kind=inner (
    SecurityIncidentComment
    | where Comment contains "DLP Policy Enrichment"
) on IncidentNumber
| project TimeGenerated, IncidentNumber, Title, Comment
```

### Statistics by enforcement mode:
```kql
SecurityIncident
| where Tags has "EnforcementMode"
| extend EnforcementMode = extract("EnforcementMode:([^,\\]]+)", 1, tostring(Tags))
| summarize Count=count() by EnforcementMode, Severity
| render columnchart
```

## Troubleshooting

### Playbook not triggering
- Check the Automation Rule is enabled and conditions match
- Verify the incident is actually DLP-related
- Check Logic App run history for errors

### API Permission Errors
- Ensure Managed Identity has required Graph API permissions
- Verify permissions were granted admin consent
- Check Azure AD audit logs for permission issues

### No data in comments/tags
- Verify the Graph API endpoints are returning data
- Check if Policy ID is correctly extracted from alert
- Review Logic App run history for failed actions

### Testing the Playbook
You can manually trigger the playbook:
1. Go to Logic App → Overview
2. Click **Run Trigger** → **Manual**
3. Provide sample incident JSON payload

## API Endpoints Used

- **Microsoft Graph Security Alerts**: `https://graph.microsoft.com/v1.0/security/alerts_v2`
- **DLP Policies**: `https://graph.microsoft.com/v1.0/security/informationProtection/dlpPolicies/{id}`

## Customization

### Add More Fields
Edit the playbook to extract additional fields from the DLP policy:
- Policy description
- Sensitive info types
- Locations (Exchange, SharePoint, etc.)
- Actions configured

### Change Tag Format
Modify the "Add_Tag_to_Incident" action to use different tag naming conventions.

### Add to Incident Description
Instead of just comments, you can update the incident description field.

## Security Considerations

- Uses **Managed Identity** for authentication (no credentials stored)
- Follows **least privilege** principle (read-only access to policies)
- All API calls are logged in Logic App run history
- Supports Azure Private Link for enhanced security

## Cost Estimation

- **Logic App**: ~$0.01 per incident (based on actions executed)
- **API Calls**: Included in Microsoft 365/Graph API quotas
- Estimated monthly cost for 1000 DLP incidents: **~$10**

## Support & Contributions

For issues or enhancements, please open an issue in the repository.

## License

MIT License - See LICENSE file for details

## References

- [Microsoft Sentinel Playbooks](https://learn.microsoft.com/azure/sentinel/automate-responses-with-playbooks)
- [Microsoft Graph Security API](https://learn.microsoft.com/graph/api/resources/security-api-overview)
- [Microsoft Purview DLP](https://learn.microsoft.com/purview/dlp-learn-about-dlp)

