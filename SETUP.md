# Setup / Build Instructions

## 1) Org & access
- A Salesforce sandbox (Developer Edition).
- Username Info:
  - Username: `eyald@cynethomeassignment.com`
  - Email: `eyald@cynet.com`
  - Password: I will send you by email

## 7) REST endpoints
### HubSpot inbound
- POST: `/services/apexrest/hubspot/inbound`

Body example (list): see `dataset/hubspot_inbound_sample.json`

### Outreach inbound
- POST: `/services/apexrest/outreach/inbound`

Body example (list): see `dataset/outreach_inbound_sample.json`

---

## 8) Postman steps (recommended)
### A) Authentication
Use OAuth access token or Session Id based auth.

**Option 1 (simplest for assignment):** Use a Session Id from Salesforce UI  
- Setup → “Session Settings” ensure API enabled  
- Get Session Id via browser dev tools (or a connected app if preferred)  
- In Postman: Authorization → **Bearer Token** → paste the token

> If you use a Connected App, configure scopes like `api` and then use OAuth flow.

### B) HubSpotInboundRest test
1. Method: **POST**
2. URL: `https://cynet-home-assignment-dev-ed.develop.my.salesforce.com/services/apexrest/hubspot/inbound`
3. Body → raw → JSON: paste `dataset/hubspot_inbound_sample.json`
4. Send and verify:
   - Lead(s) created
   - Queueable jobs ran (Identity + Routing)
   - Routing fields populated
   - Tasks created for Scenario 3 and post-convert follow-up for Scenario 1/2

### C) OutreachInboundRest test
1. Method: **POST**
2. URL: `https://cynet-home-assignment-dev-ed.develop.my.salesforce.com/services/apexrest/outreach/inbound`
3. Headers same as above
4. Body: paste `dataset/outreach_inbound_sample.json`
5. Send and verify Tasks created on matching Lead/Contact by email

---


### Queueables not running
- Check Apex Jobs
- Ensure org has async Apex enabled and you have permissions

