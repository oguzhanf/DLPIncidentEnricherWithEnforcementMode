# Quick Start Guide - DLP Policy Enrichment for Sentinel

This guide will get you up and running in **15 minutes**.

## Prerequisites Checklist

- [ ] Azure subscription with Contributor access
- [ ] Microsoft Sentinel workspace deployed
- [ ] Microsoft Purview (Compliance Center) with DLP policies
- [ ] PowerShell 7+ installed
- [ ] Azure PowerShell modules (script will install if missing)

## Step-by-Step Deployment

### Step 1: Connect to Azure (1 minute)

```powershell
Connect-AzAccount
```

### Step 2: Deploy the Playbook (3 minutes)

Run the deployment script:

```powershell
.\deploy.ps1 `
    -ResourceGroupName "your-sentinel-rg" `
    -WorkspaceName "your-sentinel-workspace"
```

The script will:
- ✅ Deploy the Logic App with Managed Identity
- ✅ Assign Sentinel Responder role
- ✅ Grant Graph API permissions (SecurityAlert.Read.All, InformationProtectionPolicy.Read.All)

### Step 3: Authorize API Connection (3 minutes)

1. Go to **Azure Portal** → **Resource Groups** → Your RG
2. Find resource: `azuresentinel-DLPPolicyEnrichment-Playbook`
3. Click **Edit API connection**
4. Click **Authorize** button
5. Sign in with Sentinel admin account
6. Click **Save**

### Step 4: Create Automation Rule (3 minutes)

1. Go to **Microsoft Sentinel** → **Automation**
2. Click **+ Create** → **Automation rule**
3. Configure:
   - **Name**: `Enrich DLP Incidents`
   - **Trigger**: `When incident is created`
   - **Conditions**: 
     - Click **+ Add** → **Incident provider** → **Equals** → `Microsoft Purview`
     - OR
     - **Incident title** → **Contains** → `DLP`
   - **Actions**: 
     - Click **+ Add action** → **Run playbook**
     - Select: `DLPPolicyEnrichment-Playbook`
4. Click **Apply**

### Step 5: Test the Enrichment (2 minutes)

#### Option A: Wait for Real DLP Alert
Just wait for the next DLP policy violation to trigger an incident.

#### Option B: Manual Test
1. Go to **Logic Apps** → `DLPPolicyEnrichment-Playbook`
2. Click **Run Trigger** → **When a Microsoft Sentinel incident is created**
3. Select an existing DLP incident from the dropdown
4. Click **Run**

### Step 6: Verify Enrichment

1. Go to **Sentinel** → **Incidents**
2. Open a DLP incident
3. Check for:
   - **Comments** section: Should show "DLP Policy Enrichment" with Enforcement Mode
   - **Tags**: Should include `EnforcementMode:XXX`, `DLPPolicy:XXX`, `AutoEnriched`

## What You'll See

### Incident Comment Example:
```
DLP Policy Enrichment

Policy Name: Sensitive Data Protection Policy
Policy ID: 12345678-1234-1234-1234-123456789abc
Enforcement Mode: Enforce
Mode: Production

Enriched by automated playbook at 2025-10-15T10:30:00Z
```

### Tags Added:
- `EnforcementMode:Enforce`
- `DLPPolicy:Sensitive Data Protection Policy`
- `AutoEnriched`

## Quick KQL Queries

### See all enriched incidents:
```kql
SecurityIncident
| where Tags has "AutoEnriched"
| extend EnforcementMode = extract("EnforcementMode:([^,\\]]+)", 1, tostring(Tags))
| project TimeGenerated, IncidentNumber, Title, EnforcementMode
```

### Count by enforcement mode:
```kql
SecurityIncident
| where Tags has "EnforcementMode"
| extend EnforcementMode = extract("EnforcementMode:([^,\\]]+)", 1, tostring(Tags))
| summarize count() by EnforcementMode
```

## Troubleshooting

### Playbook not running?
- Check Automation Rule is **Enabled**
- Verify incident matches the conditions (Purview provider or DLP in title)
- Check Logic App **Run History** for errors

### Permission errors?
```powershell
# Re-run permission grant
$playbook = Get-AzLogicApp -ResourceGroupName "your-rg" -Name "DLPPolicyEnrichment-Playbook"
$principalId = $playbook.Identity.PrincipalId

# Grant Graph permissions
Connect-AzureAD
$graphApp = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

$permission = $graphApp.AppRoles | Where-Object {$_.Value -eq "SecurityAlert.Read.All"}
New-AzureADServiceAppRoleAssignment -ObjectId $principalId -PrincipalId $principalId -ResourceId $graphApp.ObjectId -Id $permission.Id
```

### No enrichment data?
- Verify the incident is actually from a DLP alert
- Check if Purview API is accessible
- Review Logic App run history for API call failures

## Next Steps

1. **Create a Workbook** to visualize enriched data
2. **Set up alerts** for high-severity incidents with "Enforce" mode
3. **Export data** for compliance reporting
4. **Customize** the playbook to add more fields

## Support

- Check **Logic App Run History** for detailed execution logs
- Review **README.md** for comprehensive documentation
- See **KQL-Queries.kql** for advanced analytics queries

## Cost Estimate

- **Logic App**: ~$0.01 per incident
- **API Calls**: Included in M365 license
- **Monthly cost** (1000 incidents): ~$10

---

**Deployment Time**: ~15 minutes  
**Maintenance**: Minimal (automatic)  
**Value**: High (immediate policy context visibility)

