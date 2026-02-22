# Walkthrough — Example Dataset & Expected Outcomes

This walkthrough uses the sample files under `dataset/`.

---

## 1) Seed Data (Minimal)

Before running, make sure you have:

- An Account with `Website` containing `acme.com`
- At least 1 open Opportunity under the **acme** Account (to trigger Scenario 1)
- At least one Contact under the acme Account (optional)
- A second Account with `Website` containing `noopp.com` (with no Opportunity or Contact under it)
- Public group(s) populated with SDR users
- Queue `Inbound_Needs_Review`

---

## 2) HubSpot Inbound Dataset

File: `dataset/hubspot_inbound_sample.json`

It includes 4 inbound prospects designed to trigger each routing scenario:

1. Scenario 1 — Account match + open Opportunity  
2. Scenario 2 — Account match + no open Opportunity  
3. Scenario 3 — No Account match  
4. Scenario 4 — Incomplete data (no email + no website + company blank)

This payload is POSTed to:
/services/apexrest/hubspot/inbound





---

## 3) Expected Outcomes — HubSpot Processing

After running the HubSpot inbound dataset, the system produces the following results.

---

### Lead / Conversion Outcomes

| Scenario | HubSpot ID | Email | Final Record State | Routing Rule | Routing Status | Confidence | Assigned To | Task Created |
|----------|------------|-------|-------------------|--------------|----------------|------------|-------------|--------------|
| 1️⃣ Account + Open Opp | HS-20001 | dana@acme.com | Lead converted to Contact | ExistingAccount_OpenOpp | Converted | High | SDR User | Yes |
| 2️⃣ Account + No Open Opp | HS-20002 | alex@noopp.com | Lead converted to Contact | ExistingAccount_NoOpenOpp | Converted | Medium | SDR User | Yes |
| 3️⃣ No Account Match | HS-20003 | sam@newco.io | Lead remains Lead | NoAccount_InboundRR | Routed | High | SDR User | Yes |
| 4️⃣ Incomplete Data | HS-20004 | *(blank)* | Lead remains Lead | IncompleteData_NeedsReview | Needs Review | Low | Inbound Needs Review Queue | No |

---

### Tasks Created by HubSpot Inbound Process

| Related Record | Task Subject | Created On | Record Type |
|----------------|-------------|------------|-------------|
| Sam Green | Inbound follow-up (Lead) | dd-mm-yyyy | Lead |
| Dana Levi | Inbound follow-up (Converted to Contact) | dd-mm-yyyy | Contact |
| Alex Cohen | Inbound follow-up (Converted to Contact) | dd-mm-yyyy | Contact |

---

### Person Identity Records Created

| HubSpot ID | Person Identity Name | Normalized Email | Phone (E164) | Created On |
|------------|----------------------|------------------|--------------|------------|
| HS-20001 | PID-000023 | dana@acme.com | +972501112233 | dd-mm-yyyy |
| HS-20002 | PID-000024 | alex@noopp.com | +12025550144 | dd-mm-yyyy |
| HS-20003 | PID-000025 | sam@newco.io | +447700900123 | dd-mm-yyyy |
| HS-20004 | PID-000026 | *(none)* | *(none)* | dd-mm-yyyy |

---

### Contact Records After Conversion

| Contact Name | Related Scenario | Routing Rule | Routing Status | SDR Assigned | Routing Date |
|--------------|------------------|--------------|----------------|--------------|--------------|
| Dana Levi | Scenario 1 | ExistingAccount_OpenOpp | Routed | Assigned | dd-mm-yyyy |
| Alex Cohen | Scenario 2 | ExistingAccount_NoOpenOpp | Routed | Assigned | dd-mm-yyyy |

---

## 4) Outreach Inbound Dataset

File: `dataset/outreach_inbound_sample.json`

This dataset simulates engagement events coming from Outreach.

It includes examples such as:

- EMAIL_REPLY  
- CALL_COMPLETED  

This payload is POSTed to:


/services/apexrest/outreach/inbound


---

## 5) Expected Outcomes — Outreach Processing

After posting the Outreach engagement payload:

| Prospect Email | Engagement Type | Matched Record Type | Task Subject | Created On |
|----------------|----------------|--------------------|--------------|------------|
| dana@acme.com | EMAIL_REPLY | Contact | Inbound Engagement: EMAIL_REPLY | dd-mm-yyyy |
| sam@newco.io | CALL_COMPLETED | Lead | Inbound Engagement: CALL_COMPLETED | dd-mm-yyyy |

### Outreach Behavior Summary

- Matching is done by email.
- If Contact exists → Task created on Contact.
- If only Lead exists → Task created on Lead.
- If no match exists → No Task created.
- Routing fields are NOT modified during Outreach ingestion.

---

## 6) Postman GET Endpoints (Outreach Inspection)

These endpoints are implemented in:

`@RestResource(urlMapping='/outreach/inbound/*')`
`OutreachInboundRest`

---

### Lookup Specific Lead by HubSpot Contact ID


`GET https://cynet-home-assignment-dev-ed.develop.my.salesforce.com/services/apexrest/outreach/inbound/lead?hs_contact_id=HS-10006`


Returns:

- Lead fields
- Routing fields
- Assigned SDR
- Person Identity reference
- Person Identity details

Used for record-level validation and explainability.

---

### Example GET Specific Lead Response — HS-20001

Request:

`GET https://cynet-home-assignment-dev-ed.develop.my.salesforce.com/services/apexrest/outreach/inbound/lead?hs_contact_id=HS-20001`


Response:

```json
{
  "website": "https://acme.com",
  "status": "OK",
  "sdrAssignedId": "005g5000003WNkdAAG",
  "routingStatus": "Converted",
  "routingRule": "ExistingAccount_OpenOpp",
  "routingNotes": "Existing Account with OpenOpp - Inbound",
  "routingDate": "2026-02-21T23:39:05.000Z",
  "routingConfidence": "High",
  "piPhoneE164": "+972501112233",
  "piNormalizedEmail": "dana@acme.com",
  "piId": "a00g500000FprmQAAR",
  "piHubspotContactId": "HS-20001",
  "phone": "+972501112233",
  "personIdentityId": "a00g500000FprmQAAR",
  "message": "Found",
  "leadId": "00Qg50000021DwXEAU",
  "hubspotContactId": "HS-20001",
  "email": "dana@acme.com",
  "company": "Acme Ltd"
}
```

---

### Retrieve Recent Leads

`
GET https://cynet-home-assignment-dev-ed.develop.my.salesforce.com/services/apexrest/outreach/inbound/leads?limit=50`


Returns:

- Recent Leads
- Routing information
- SDR assignment
- HubSpot ID
- Created date

Used for bulk inspection and demo purposes.

---

### Example GET Response — Recent Leads (limit=50)

Request:

`
GET https://cynet-home-assignment-dev-ed.develop.my.salesforce.com/services/apexrest/outreach/inbound/leads?limit=50`


Response:

```json
{
  "status": "OK",
  "returnedCount": 4,
  "message": "Success",
  "limitValue": 50,
  "items": [
    {
      "sdrAssignedId": "005g5000003WNkdAAG",
      "routingStatus": "Converted",
      "routingRule": "ExistingAccount_OpenOpp",
      "routingDate": "2026-02-21T23:39:05.000Z",
      "routingConfidence": "High",
      "leadId": "00Qg50000021DwXEAU",
      "hubspotContactId": "HS-20001",
      "email": "dana@acme.com",
      "createdDate": "2026-02-21T23:39:04.000Z",
      "company": "Acme Ltd"
    },
    {
      "sdrAssignedId": "005g5000003WNkdAAG",
      "routingStatus": "Converted",
      "routingRule": "ExistingAccount_NoOpenOpp",
      "routingDate": "2026-02-21T23:39:05.000Z",
      "routingConfidence": "Medium",
      "leadId": "00Qg50000021DwYEAU",
      "hubspotContactId": "HS-20002",
      "email": "alex@noopp.com",
      "createdDate": "2026-02-21T23:39:04.000Z",
      "company": "NoOpp Inc"
    },
    {
      "sdrAssignedId": "005g5000003WNRBAA4",
      "routingStatus": "Routed",
      "routingRule": "NoAccount_InboundRR",
      "routingDate": "2026-02-21T23:39:05.000Z",
      "routingConfidence": "High",
      "leadId": "00Qg50000021DwZEAU",
      "hubspotContactId": "HS-20003",
      "email": "sam@newco.io",
      "createdDate": "2026-02-21T23:39:04.000Z",
      "company": "NewCo"
    },
    {
      "sdrAssignedId": null,
      "routingStatus": "Needs Review",
      "routingRule": "IncompleteData_NeedsReview",
      "routingDate": "2026-02-21T23:39:05.000Z",
      "routingConfidence": "Low",
      "leadId": "00Qg50000021DwaEAE",
      "hubspotContactId": "HS-20004",
      "email": null,
      "createdDate": "2026-02-21T23:39:04.000Z",
      "company": "Unknown"
    }
  ]
}
```




---

## 7) Run Steps

1. POST hubspot payload → `/services/apexrest/hubspot/inbound`
2. Wait for Queueables to complete (Apex Jobs)
3. Validate per-row outcomes (fields + Tasks)
4. POST outreach payload → `/services/apexrest/outreach/inbound`
5. Validate Tasks created against the correct Lead/Contact
6. Use GET endpoints to inspect processed records

---

## 8) Explainability (What to Show in Review)

For each sample record, demonstrate:

- Lead created (and relevant fields)
- `Person_Identity__c` resolution result
- `Routing_*` fields and values
- If converted → resulting Contact record
- Task ownership (SDR or none for Needs Review)
- Verification via GET endpoints

---

This demonstrates the complete lifecycle:

Inbound → Identity Resolution → Routing → Conversion → Outreach Engagement → API Inspection