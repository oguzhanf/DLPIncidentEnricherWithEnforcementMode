# Alternative Approaches for DLP Incident Enrichment

This document compares different approaches to enriching Sentinel incidents with DLP policy information.

## Comparison Matrix

| Approach | Visibility | Queryability | Automation | Complexity | Cost | Best For |
|----------|-----------|--------------|------------|------------|------|----------|
| **1. Comments/Tags** ⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ | $ | Quick visibility |
| **2. Custom Table** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | $$ | Analytics/Reporting |
| **3. Watchlist** | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ | ⭐ | $ | Static mappings |
| **4. Update Description** | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ | $ | Simple display |
| **5. Custom Details** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | $ | Analytics rules |

⭐ = Rating (more stars = better)

---

## Approach 1: Comments + Tags (Implemented Solution) ⭐ RECOMMENDED

### What We Built
The playbook in this repository implements this approach.

### Pros
✅ **Immediate visibility** - Shows directly in incident UI  
✅ **Easy to filter** - Tags enable quick searches  
✅ **No schema changes** - Works with existing Sentinel  
✅ **Audit trail** - Comments are timestamped  
✅ **User-friendly** - SOC analysts see data immediately  

### Cons
❌ **Limited querying** - Need to parse tags in KQL  
❌ **Not structured** - Comments are free text  
❌ **Tag limits** - Maximum 50 tags per incident  

### When to Use
- You want **immediate visibility** in the incident UI
- SOC analysts need to see enforcement mode **at a glance**
- You want **minimal complexity**
- You need **quick deployment** (15 minutes)

### Example Output
**Tags**: `EnforcementMode:Enforce`, `DLPPolicy:PII Protection`, `AutoEnriched`

**Comment**:
```
DLP Policy Enrichment
Policy Name: PII Protection Policy
Enforcement Mode: Enforce
```

---

## Approach 2: Custom Log Table

### How It Works
Create a custom table (e.g., `DLPEnrichment_CL`) and write enrichment data there.

### Implementation
```kql
// Create custom table via Data Collection Rule or Log Analytics API
// Table schema:
{
  "TimeGenerated": "datetime",
  "IncidentId": "string",
  "IncidentNumber": "int",
  "PolicyId": "string",
  "PolicyName": "string",
  "EnforcementMode": "string",
  "PolicyMode": "string",
  "EnrichedBy": "string"
}
```

### Playbook Changes
Add action to write to custom table:
```json
{
  "type": "Http",
  "inputs": {
    "method": "POST",
    "uri": "https://<workspace-id>.ods.opinsights.azure.com/api/logs?api-version=2016-04-01",
    "headers": {
      "Log-Type": "DLPEnrichment"
    },
    "body": {
      "IncidentId": "@{triggerBody()?['object']?['id']}",
      "EnforcementMode": "@{body('Parse_Policy_Response')?['enforcementMode']}"
    }
  }
}
```

### Query Example
```kql
SecurityIncident
| join kind=inner (
    DLPEnrichment_CL
) on $left.IncidentNumber == $right.IncidentNumber
| project TimeGenerated, IncidentNumber, Title, EnforcementMode, PolicyName
```

### Pros
✅ **Structured data** - Proper schema for analytics  
✅ **Advanced querying** - Full KQL capabilities  
✅ **Historical analysis** - Separate retention policy  
✅ **No limits** - Store unlimited fields  

### Cons
❌ **Not visible in UI** - Need to query to see data  
❌ **Extra cost** - Custom table ingestion charges  
❌ **More complex** - Requires DCR or API setup  
❌ **Delayed visibility** - Ingestion lag (1-5 minutes)  

### When to Use
- You need **advanced analytics** and reporting
- You want to store **many enrichment fields**
- You need **historical trend analysis**
- Cost is not a primary concern

---

## Approach 3: Watchlist

### How It Works
Maintain a Watchlist mapping Policy IDs to Enforcement Modes.

### Implementation
1. Create Watchlist: `DLPPolicyMappings`
2. Columns: `PolicyId`, `PolicyName`, `EnforcementMode`, `Description`
3. Manually update when policies change

### Query Example
```kql
SecurityIncident
| extend PolicyId = extract("PolicyId:([^,]+)", 1, tostring(AdditionalData))
| join kind=leftouter (
    _GetWatchlist('DLPPolicyMappings')
) on $left.PolicyId == $right.PolicyId
| project TimeGenerated, IncidentNumber, Title, EnforcementMode, PolicyName
```

### Pros
✅ **Simple setup** - No code required  
✅ **Easy maintenance** - Update via UI  
✅ **No automation needed** - Static mapping  
✅ **Low cost** - Watchlist is free  

### Cons
❌ **Manual updates** - Must update when policies change  
❌ **No automation** - Doesn't enrich incidents automatically  
❌ **Limited visibility** - Only in queries  
❌ **Stale data risk** - Can become outdated  

### When to Use
- You have **few DLP policies** that rarely change
- You want **zero automation**
- You only need data for **queries/reports**
- You have a process to keep watchlist updated

---

## Approach 4: Update Incident Description

### How It Works
Append enrichment data to the incident description field.

### Playbook Changes
```json
{
  "type": "ApiConnection",
  "inputs": {
    "body": {
      "incidentArmId": "@triggerBody()?['object']?['id']",
      "description": "@{triggerBody()?['object']?['properties']?['description']}\n\n--- DLP Policy Enrichment ---\nEnforcement Mode: @{body('Parse_Policy_Response')?['enforcementMode']}\nPolicy: @{body('Parse_Policy_Response')?['name']}"
    },
    "host": {
      "connection": {
        "name": "@parameters('$connections')['azuresentinel']['connectionId']"
      }
    },
    "method": "put",
    "path": "/Incidents"
  }
}
```

### Pros
✅ **Highly visible** - Shows at top of incident  
✅ **Simple** - Single field update  
✅ **Searchable** - Can search in description  

### Cons
❌ **Overwrites risk** - Can conflict with other updates  
❌ **Not structured** - Free text only  
❌ **Hard to query** - Need text parsing in KQL  
❌ **Limited space** - Description field has size limits  

### When to Use
- You want **maximum visibility**
- You have **few enrichment fields**
- You don't need structured querying

---

## Approach 5: Custom Details in Analytics Rule

### How It Works
If you control the analytics rule creating the incident, add custom details.

### Implementation
In the analytics rule that creates DLP incidents:
```kql
SecurityAlert
| where ProductName == "Microsoft Purview"
| extend PolicyId = tostring(ExtendedProperties.PolicyId)
| join kind=leftouter (
    _GetWatchlist('DLPPolicyMappings')
) on PolicyId
| project 
    TimeGenerated,
    AlertName,
    // Custom Details
    EnforcementMode,
    PolicyName,
    PolicyId
```

### Pros
✅ **Native feature** - Built into Sentinel  
✅ **Structured data** - Proper fields  
✅ **Visible in UI** - Shows in incident details  
✅ **Queryable** - Available in AdditionalData  

### Cons
❌ **Requires rule control** - Only works if you create the rule  
❌ **Not for Defender XDR** - Can't modify Microsoft's rules  
❌ **Static at creation** - Can't update after incident created  
❌ **Needs data source** - Requires watchlist or other source  

### When to Use
- You **create custom analytics rules** for DLP
- You don't use Defender XDR integration
- You want native Sentinel features

---

## Hybrid Approach (Best of All Worlds)

### Recommended Combination
**Comments/Tags + Custom Table**

1. **Use Comments/Tags** (this solution) for:
   - Immediate SOC analyst visibility
   - Quick filtering and triage
   - Audit trail

2. **Add Custom Table** for:
   - Advanced analytics
   - Executive reporting
   - Trend analysis
   - Compliance audits

### Implementation
Modify the playbook to do BOTH:
- Add comment + tags (already implemented)
- ALSO write to custom table

### Benefits
✅ Best of both worlds  
✅ SOC gets immediate visibility  
✅ Analysts get powerful queries  
✅ Minimal additional cost  

---

## Decision Tree

```
Do you need immediate visibility in incident UI?
├─ YES → Use Comments/Tags (this solution) ⭐
└─ NO
   └─ Do you need advanced analytics?
      ├─ YES → Use Custom Table
      └─ NO
         └─ Do policies change frequently?
            ├─ YES → Use Playbook automation
            └─ NO → Use Watchlist
```

---

## Migration Path

### Start Simple → Scale Up

**Phase 1** (Week 1): Deploy Comments/Tags solution  
**Phase 2** (Week 2-4): Gather feedback from SOC  
**Phase 3** (Month 2): Add Custom Table if analytics needed  
**Phase 4** (Month 3+): Build Workbooks and advanced queries  

---

## Cost Comparison (1000 incidents/month)

| Approach | Monthly Cost | Notes |
|----------|-------------|-------|
| Comments/Tags | ~$10 | Logic App execution only |
| Custom Table | ~$25 | +$15 for ingestion (500MB) |
| Watchlist | ~$10 | Logic App or manual |
| Update Description | ~$10 | Logic App execution only |
| Custom Details | $0 | Native feature, no extra cost |

---

## Conclusion

**For most organizations**: Start with **Comments/Tags** (this solution)
- Fast deployment (15 min)
- Immediate value
- Low cost
- Easy to understand

**Add Custom Table later** if you need:
- Advanced analytics
- Executive dashboards
- Compliance reporting
- Historical trends

The solution in this repository gives you the best starting point with option to expand later.

