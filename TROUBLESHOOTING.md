# Troubleshooting Guide - DLP Policy Enrichment

This guide helps you diagnose and fix common issues with the DLP Policy Enrichment playbook.

## Quick Diagnostics Checklist

Run through this checklist first:

- [ ] Playbook is deployed and enabled
- [ ] Automation rule is created and enabled
- [ ] API connection is authorized
- [ ] Managed Identity has required permissions
- [ ] Incident is actually DLP-related
- [ ] Logic App run history shows executions

---

## Issue 1: Playbook Not Triggering

### Symptoms
- No runs in Logic App run history
- Incidents created but not enriched
- Automation rule shows 0 runs

### Diagnosis Steps

#### Step 1: Check Automation Rule
```powershell
# List automation rules
az sentinel automation-rule list \
  --resource-group "your-rg" \
  --workspace-name "your-workspace"
```

**Verify**:
- Rule is **Enabled**
- Trigger is "When incident is created"
- Conditions match DLP incidents

#### Step 2: Check Incident Matches Conditions
```kql
SecurityIncident
| where TimeGenerated > ago(24h)
| where ProviderName == "Microsoft Purview" or Title contains "DLP"
| project TimeGenerated, IncidentNumber, Title, ProviderName, Status
```

If no results, your incidents might not match the automation rule conditions.

#### Step 3: Verify Playbook Connection
1. Go to **Logic Apps** → Your playbook
2. Click **Logic app designer**
3. Check the trigger: "Microsoft Sentinel incident"
4. Ensure it's connected properly

### Solutions

**Solution A: Update Automation Rule Conditions**
```
Change condition from:
  "Incident provider equals Microsoft Purview"
To:
  "Incident title contains DLP"
  OR
  "Alert product name contains Purview"
```

**Solution B: Manually Test Playbook**
1. Go to Logic App → Overview
2. Click **Run Trigger**
3. Select a test incident
4. Check run history for errors

**Solution C: Recreate Automation Rule**
Sometimes the webhook connection breaks. Delete and recreate the automation rule.

---

## Issue 2: Permission Errors

### Symptoms
- Playbook runs but fails at API calls
- Error: "Forbidden" or "Unauthorized"
- HTTP 403 errors in run history

### Diagnosis Steps

#### Step 1: Check Managed Identity Exists
```powershell
$playbook = Get-AzLogicApp -ResourceGroupName "your-rg" -Name "DLPPolicyEnrichment-Playbook"
$principalId = $playbook.Identity.PrincipalId

if ($principalId) {
    Write-Host "Managed Identity exists: $principalId" -ForegroundColor Green
} else {
    Write-Host "ERROR: No Managed Identity found!" -ForegroundColor Red
}
```

#### Step 2: Check Graph API Permissions
```powershell
Connect-AzureAD
$msi = Get-AzureADServicePrincipal -ObjectId $principalId
$graphApp = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Check assigned permissions
Get-AzureADServiceAppRoleAssignment -ObjectId $principalId | 
    Where-Object {$_.ResourceId -eq $graphApp.ObjectId} |
    ForEach-Object {
        $role = $graphApp.AppRoles | Where-Object {$_.Id -eq $_.Id}
        Write-Host "Permission: $($role.Value)" -ForegroundColor Green
    }
```

**Expected permissions**:
- `SecurityAlert.Read.All`
- `InformationProtectionPolicy.Read.All`

#### Step 3: Check Sentinel Role
```powershell
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName "your-rg" -Name "your-workspace"
$roleAssignments = Get-AzRoleAssignment -ObjectId $principalId -Scope $workspace.ResourceId

$roleAssignments | Format-Table RoleDefinitionName, Scope
```

**Expected role**: `Microsoft Sentinel Responder`

### Solutions

**Solution A: Grant Graph API Permissions**
```powershell
Connect-AzureAD
$graphApp = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Grant SecurityAlert.Read.All
$permission1 = $graphApp.AppRoles | Where-Object {$_.Value -eq "SecurityAlert.Read.All"}
New-AzureADServiceAppRoleAssignment -ObjectId $principalId -PrincipalId $principalId `
  -ResourceId $graphApp.ObjectId -Id $permission1.Id

# Grant InformationProtectionPolicy.Read.All
$permission2 = $graphApp.AppRoles | Where-Object {$_.Value -eq "InformationProtectionPolicy.Read.All"}
New-AzureADServiceAppRoleAssignment -ObjectId $principalId -PrincipalId $principalId `
  -ResourceId $graphApp.ObjectId -Id $permission2.Id
```

**Solution B: Grant Sentinel Responder Role**
```powershell
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName "your-rg" -Name "your-workspace"
New-AzRoleAssignment -ObjectId $principalId `
  -RoleDefinitionName "Microsoft Sentinel Responder" `
  -Scope $workspace.ResourceId
```

**Solution C: Wait for Propagation**
Permissions can take 5-10 minutes to propagate. Wait and retry.

---

## Issue 3: API Connection Not Authorized

### Symptoms
- Error: "The API connection is not authorized"
- Playbook fails at Sentinel actions
- Red exclamation mark on API connection

### Diagnosis Steps

#### Step 1: Check Connection Status
1. Go to **Resource Groups** → Your RG
2. Find: `azuresentinel-DLPPolicyEnrichment-Playbook`
3. Check **Status** field

#### Step 2: View Connection Details
```powershell
$connection = Get-AzResource -ResourceType "Microsoft.Web/connections" `
  -ResourceGroupName "your-rg" `
  -Name "azuresentinel-DLPPolicyEnrichment-Playbook"

$connection.Properties | ConvertTo-Json
```

### Solutions

**Solution A: Authorize Connection**
1. Go to API Connection resource
2. Click **Edit API connection**
3. Click **Authorize**
4. Sign in with account that has Sentinel permissions
5. Click **Save**

**Solution B: Use Managed Identity for Connection**
Edit the playbook to use Managed Identity authentication:
```json
"connectionProperties": {
  "authentication": {
    "type": "ManagedServiceIdentity"
  }
}
```

---

## Issue 4: No Enrichment Data Added

### Symptoms
- Playbook runs successfully
- No errors in run history
- But no comments or tags added to incident

### Diagnosis Steps

#### Step 1: Check Run History Details
1. Go to Logic App → Runs history
2. Click on a recent run
3. Expand each action
4. Look for the "Add_Comment_to_Incident" and "Add_Tag_to_Incident" actions

#### Step 2: Check API Response
Look at the output of "Get_DLP_Policy_Details" action:
- Is the response empty?
- Is the Policy ID correct?
- Is the Enforcement Mode field present?

#### Step 3: Verify Incident ID
Check if the incident ARM ID is correct:
```
/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{workspace}/providers/Microsoft.SecurityInsights/Incidents/{incident-id}
```

### Solutions

**Solution A: Check Policy ID Extraction**
The playbook might not be extracting the Policy ID correctly. Check the alert structure:

```kql
SecurityAlert
| where TimeGenerated > ago(24h)
| where ProductName == "Microsoft Purview"
| extend ExtProps = parse_json(ExtendedProperties)
| project TimeGenerated, AlertName, ExtProps
```

Update the playbook to extract Policy ID from the correct field.

**Solution B: Verify Graph API Endpoint**
Test the Graph API manually:
```powershell
$token = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

# Test alerts endpoint
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/security/alerts_v2" -Headers $headers

# Test DLP policies endpoint
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/security/informationProtection/dlpPolicies" -Headers $headers
```

**Solution C: Add Error Handling**
Add a "Compose" action after API calls to see the raw response:
```json
{
  "type": "Compose",
  "inputs": "@body('Get_DLP_Policy_Details')"
}
```

---

## Issue 5: Wrong Enforcement Mode Displayed

### Symptoms
- Enrichment works but shows incorrect data
- Enforcement Mode doesn't match Purview portal

### Diagnosis Steps

#### Step 1: Verify in Purview Portal
1. Go to **Microsoft Purview Compliance Portal**
2. Navigate to **Data Loss Prevention** → **Policies**
3. Find the policy
4. Check the actual Enforcement Mode

#### Step 2: Check API Response
In Logic App run history, check the "Parse_Policy_Response" output.

### Solutions

**Solution A: Update Field Mapping**
The API might return the field with a different name. Update the playbook:
```json
"enforcementMode": "@{body('Get_DLP_Policy_Details')?['mode']}"
```

Or try:
```json
"enforcementMode": "@{body('Get_DLP_Policy_Details')?['state']}"
```

**Solution B: Add Fallback Logic**
```json
"enforcementMode": "@{coalesce(body('Get_DLP_Policy_Details')?['enforcementMode'], body('Get_DLP_Policy_Details')?['mode'], 'Unknown')}"
```

---

## Issue 6: High Latency / Slow Enrichment

### Symptoms
- Enrichment takes several minutes
- Delays between incident creation and enrichment

### Diagnosis Steps

#### Step 1: Check Run Duration
```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.LOGIC"
| where resource_workflowName_s == "DLPPolicyEnrichment-Playbook"
| summarize avg(duration_d), max(duration_d) by bin(TimeGenerated, 1h)
```

#### Step 2: Identify Slow Actions
In run history, check duration of each action.

### Solutions

**Solution A: Optimize API Calls**
- Remove unnecessary parsing steps
- Combine multiple API calls if possible
- Use batch operations

**Solution B: Add Timeout Settings**
```json
"timeout": "PT30S"
```

**Solution C: Use Async Pattern**
For non-critical enrichment, consider async processing.

---

## Issue 7: Playbook Runs Multiple Times

### Symptoms
- Multiple comments added to same incident
- Duplicate tags
- Run history shows multiple executions for one incident

### Diagnosis Steps

#### Step 1: Check Automation Rules
```kql
// Check if multiple automation rules trigger the playbook
```

#### Step 2: Check for Incident Updates
The playbook might trigger on incident updates, not just creation.

### Solutions

**Solution A: Add Idempotency Check**
Add a condition at the start:
```json
{
  "type": "If",
  "expression": {
    "and": [
      {
        "not": {
          "contains": [
            "@triggerBody()?['object']?['properties']?['labels']",
            "AutoEnriched"
          ]
        }
      }
    ]
  }
}
```

**Solution B: Change Trigger to "Created" Only**
Ensure automation rule only triggers on incident creation, not updates.

---

## Debugging Tools

### Enable Diagnostic Logging
```powershell
$workspaceId = "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{workspace}"

Set-AzDiagnosticSetting -ResourceId $playbook.Id `
  -WorkspaceId $workspaceId `
  -Enabled $true `
  -Category WorkflowRuntime
```

### View Logs
```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.LOGIC"
| where resource_workflowName_s == "DLPPolicyEnrichment-Playbook"
| project TimeGenerated, status_s, error_message_s, resource_actionName_s
| order by TimeGenerated desc
```

### Test Graph API Manually
```powershell
# Get token
$token = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token

# Test endpoint
$headers = @{
    "Authorization" = "Bearer $token"
}

Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/security/alerts_v2?`$top=1" -Headers $headers
```

---

## Getting Help

### Check These Resources First
1. **Logic App Run History** - Most detailed error information
2. **Azure Activity Log** - Deployment and permission issues
3. **Sentinel Automation Logs** - Automation rule execution
4. **Graph API Documentation** - API schema changes

### Collect This Information for Support
- Playbook run history (screenshot)
- Error messages (full text)
- Incident details (IncidentNumber, Title)
- Azure subscription ID
- Tenant ID
- Deployment method used

### Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| "Forbidden" | Missing permissions | Grant Graph API permissions |
| "Not Found" | Wrong endpoint or ID | Verify API endpoint and IDs |
| "Unauthorized" | Connection not authorized | Authorize API connection |
| "Bad Request" | Invalid JSON | Check request body format |
| "Timeout" | API slow/unavailable | Add retry logic |

---

## Prevention Best Practices

1. **Monitor Playbook Health**
   - Set up alerts for failed runs
   - Review run history weekly

2. **Test After Changes**
   - Test manually after any modification
   - Use test incidents

3. **Document Customizations**
   - Keep notes on any changes made
   - Version control your templates

4. **Regular Permission Audits**
   - Verify permissions monthly
   - Check for expired credentials

5. **Stay Updated**
   - Monitor Graph API changelog
   - Update playbook for API changes

