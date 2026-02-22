# Salesforce Platform Architecture Home Assignment — SDR Identity, Routing, and Ownership

This repo contains the **design explanation**, **setup notes**, and a **small example dataset** to demonstrate an end-to-end flow:

**HubSpot → Salesforce Lead → Identity Resolution → Routing → (optional) Lead Conversion → SDR follow-up task**  
and **Outreach → Salesforce Task creation → API Inspection**.

---

## 1) Solution overview

### Goals
- Keep identity decisions **deterministic, auditable, explainable**.
- Ensure SDR follow-up stays consistent while **Account/Opportunity ownership remains unchanged**.
- Handle imperfect data and duplicates with a **controlled “Needs Review” lane**.

### High-level flow
1. **HubSpotInboundRest** receives inbound prospects (JSON list or single object).
2. Creates **Lead** records (allows “Incomplete Data” scenario by using `Company='Unknown'` when missing).
3. Enqueues **IdentityResolutionQueueable**:
   - Finds or creates a **Person_Identity__c** using **HubSpot ID, Phone, Email** (normalized).
   - Links `Lead.Person_Identity__c`.
4. Enqueues **RoutingQueueable**:
   - Attempts **Account match by domain** (from Email domain, fallback Website domain).
   - Routes using 4 scenarios (see section 3).
   - Creates **Task** for SDR follow-up (Lead or Contact depending on conversion).
5. **OutreachInboundRest** handles engagement updates:
   - Receives engagement payloads (EMAIL_REPLY, CALL_COMPLETED, etc.).
   - Matches records by normalized email.
   - If Contact exists → creates Task on Contact.
   - If only Lead exists → creates Task on Lead.
   - If no match exists → returns error (no Task created).
   - Does **not** modify routing or ownership logic.
   - Provides GET endpoints for inspection:
     - `https://cynet-home-assignment-dev-ed.develop.my.salesforce.com/services/apexrest/outreach/inbound/lead?hs_contact_id=HS-20001`
     - `https://cynet-home-assignment-dev-ed.develop.my.salesforce.com/services/apexrest/outreach/inbound/leads?limit=50`
     
     act by email match



---

## 2) Identity model — Person_Identity__c

### Why an identity object?
Email is not stable; a person can reappear with different emails. `Person_Identity__c` provides:
- a stable internal identity key
- a place to store normalized identifiers
- a way to link multiple Lead/Contact records over time

### Matching precedence (deterministic)
When resolving identity, match using the first available identifier in this order:
1. `HubSpot_Contact_ID__c`
2. `Phone` (normalized to E.164-ish digits + optional leading `+`)
3. `Email` (lowercased, trimmed)

### What happens when no match exists?
Create a new `Person_Identity__c` with whatever identifiers exist and link the Lead to it.

---

## 3) Routing & conversion logic (Lead + Contact)

### Routing scenarios
| Scenario | Condition | What happens | SDR assignment | Routing fields |
|---|---|---|---|---|
| 1️⃣ Existing Account + Open Opportunity | Lead’s domain matches an Account AND account has open Opp(s) | Convert Lead to Contact under that Account (or attach to existing Contact if email matches) | Deterministic “aligned” SDR using owner of most-recent open Opp (then mapped to pool) | `Routing_Rule__c=ExistingAccount_OpenOpp`, `Routing_Confidence__c=High`, `Routing_Status__c=Routed`, `Routing_Date__c=NOW()` |
| 2️⃣ Existing Account + No Open Opportunity | Lead’s domain matches Account AND no open Opp(s) | Convert Lead to Contact under Account (or existing Contact) | Segment/Region pool RR (fallback inbound pool) | `Routing_Rule__c=ExistingAccount_NoOpenOpp`, `Routing_Confidence__c=Medium`, `Routing_Status__c=Routed`, `Routing_Date__c=NOW()` |
| 3️⃣ No Account match | No Account match by domain | Keep as Lead | Standard inbound RR (deterministic) + create Task on Lead | `Routing_Rule__c=NoAccount_InboundRR`, `Routing_Confidence__c=High`, `Routing_Status__c=Routed`, `Routing_Date__c=NOW()` |
| 4️⃣ Incomplete Data | Missing Email + no domain + Company missing/Unknown | Keep as Lead; put into queue for review | No SDR assignment; owned by Needs Review queue | `Routing_Rule__c=IncompleteData_NeedsReview`, `Routing_Confidence__c=Low`, `Routing_Status__c=Needs Review`, `Routing_Date__c=NOW()` |

### Lead conversion policy
- If Account matched by domain → **convert** Lead to Contact under that Account.
- **Do not** change Account/Opportunity owners.
- Follow-up ownership is represented by `Lead.SDR_Assigned__c` and the created Task owner.

---

## 4) Why Queueable Apex (and not Batchable Apex)

The inbound flow is event-driven and designed for near real-time processing.  
Each POST represents a discrete business event that should trigger identity resolution and routing immediately.

Queueable Apex is used because it:


- Allows clear separation of stages (Identity → Routing) via chaining  
- Preserves deterministic execution order  

Batchable Apex is optimized for large scheduled dataset processing.  
This solution instead processes inbound records as they arrive, making Queueable the better architectural fit.

---

## 5) Scale considerations
- Identity resolution uses **bulk queries** (set-based) and avoids SOQL-in-loops.
- Production alternative: `Account.Domain__c` (indexed / external id) or a dedicated domain mapping table.
- Routing RR uses deterministic hashing (no reliance on stateful counters).

---

## 6) Assumptions

- HubSpot is source-of-truth for “new inbound prospect creation” (push only).
- Outreach is source-of-truth for engagement activity (push into Salesforce as Tasks).
- OutreachInboundRest matches engagement events by normalized email:
  - If a Contact exists → Task is created on Contact.
  - If only a Lead exists → Task is created on Lead.
  - If no match exists → no Task is created and an error response is returned.
- OutreachInboundRest exposes read-only GET endpoints for operational inspection:
  - `/outreach/inbound/lead?hs_contact_id=...`
  - `/outreach/inbound/leads?limit=...`
- GET endpoints do not modify data; they are used for routing transparency and explainability.

---

## 7) Files in this package
- `SETUP.md` — build + configuration steps
- `METADATA.md` — list of custom fields, picklists, groups, queues, mappings
- `WALKTHROUGH.md` — step-by-step dataset walkthrough + expected outcomes
- `dataset/hubspot_inbound_sample.json` — sample HubSpot inbound payloads
- `dataset/outreach_inbound_sample.json` — sample Outreach inbound payloads