@RestResource(urlMapping='/outreach/inbound/*')
global with sharing class OutreachInboundRest {

    global class InboundUpdate {
        public String inbound_type;     
        public String inbound_email;    
        public String notes;
        public String occurred_at;
    }

    global class ItemResult {
        public Integer index;
        public String status;
        public Id taskId;
        public String message;
    }

    global class BatchResponse {
        public String status;
        public Integer received;
        public Integer inserted;
        public Integer failed;
        public List<ItemResult> results = new List<ItemResult>();
    }

    global class LeadLookupResponse {
        public String status; 
        public String message;

        public Id leadId;


        public String email;
        public String phone;
        public String company;
        public String website;

        public String hubspotContactId;
        public Id personIdentityId;

        public Id sdrAssignedId;
        public String routingRule;
        public String routingConfidence;
        public String routingNotes;
        public Datetime routingDate;
        public String routingStatus;

        public Id piId;
        public String piHubspotContactId;
        public String piNormalizedEmail;
        public String piPhoneE164;
    }

    global class LeadListItem {
        public Id leadId;
        public String hubspotContactId;
        public String email;
        public String company;
        public Datetime createdDate;

        public Id sdrAssignedId;
        public String routingRule;
        public String routingConfidence;
        public Datetime routingDate;
        public String routingStatus;
    }

    global class LeadListResponse {
        public String status; 
        public String message;
        public Integer returnedCount;

        public Integer limitValue;

        public List<LeadListItem> items = new List<LeadListItem>();
    }

    @HttpPost
    global static BatchResponse doPost() {
        BatchResponse out = new BatchResponse();

        try {
            String body = (RestContext.request.requestBody == null)
                ? null
                : RestContext.request.requestBody.toString();

            if (String.isBlank(body)) {
                return errorResponse('Empty request body');
            }

            List<InboundUpdate> inboundItems = parseAsListOrSingle(body);
            out.received = inboundItems.size();

            if (inboundItems.isEmpty()) {
                return errorResponse('No inbound items found');
            }

            Set<String> emails = new Set<String>();
            for (InboundUpdate item : inboundItems) {
                if (item != null && !String.isBlank(item.inbound_email)) {
                    emails.add(item.inbound_email.trim().toLowerCase());
                }
            }

            Map<String, Id> emailToLeadId = new Map<String, Id>();
            Map<String, Id> emailToContactId = new Map<String, Id>();

            if (!emails.isEmpty()) {
                for (Lead l : [
                    SELECT Id, Email
                    FROM Lead
                    WHERE IsConverted = false
                    AND Email IN :emails
                ]) {
                    emailToLeadId.put(l.Email.trim().toLowerCase(), l.Id);
                }

                for (Contact c : [
                    SELECT Id, Email
                    FROM Contact
                    WHERE Email IN :emails
                ]) {
                    emailToContactId.put(c.Email.trim().toLowerCase(), c.Id);
                }
            }

            List<Task> tasksToInsert = new List<Task>();
            List<Integer> indexByInsertPos = new List<Integer>();
            List<ItemResult> resultsByIndex = new List<ItemResult>();

            for (Integer i = 0; i < inboundItems.size(); i++) {
                InboundUpdate item = inboundItems[i];

                ItemResult r = new ItemResult();
                r.index = i;

                if (item == null || String.isBlank(item.inbound_email)) {
                    r.status = 'ERROR';
                    r.message = 'Invalid inbound item';
                    resultsByIndex.add(r);
                    continue;
                }

                String email = item.inbound_email.trim().toLowerCase();

                Id whoId = emailToContactId.containsKey(email)
                    ? emailToContactId.get(email)
                    : emailToLeadId.get(email);

                if (whoId == null) {
                    r.status = 'ERROR';
                    r.message = 'No matching Lead/Contact found';
                    resultsByIndex.add(r);
                    continue;
                }

                Task t = new Task();
                t.Subject = 'Inbound Engagement: ' + item.inbound_type;
                t.Description = item.notes;
                t.WhoId = whoId;
                t.Status = 'Not Started';
                t.Priority = 'Normal';

                tasksToInsert.add(t);
                indexByInsertPos.add(i);

                r.status = 'OK';
                r.message = 'Queued';
                resultsByIndex.add(r);
            }

            Integer inserted = 0, failed = 0;

            if (!tasksToInsert.isEmpty()) {
                Database.SaveResult[] srs = Database.insert(tasksToInsert, false);

                for (Integer j = 0; j < srs.size(); j++) {
                    Integer originalIndex = indexByInsertPos[j];
                    ItemResult rr = resultsByIndex[originalIndex];

                    if (srs[j].isSuccess()) {
                        rr.taskId = srs[j].getId();
                        rr.message = 'Task created';
                        inserted++;
                    } else {
                        rr.status = 'ERROR';
                        rr.message = srs[j].getErrors()[0].getMessage();
                        failed++;
                    }
                }
            }

            out.results = resultsByIndex;
            out.inserted = inserted;
            out.failed = failed;
            out.status = failed == 0 ? 'OK' : (inserted > 0 ? 'PARTIAL' : 'ERROR');

            return out;

        } catch (Exception ex) {
            return errorResponse(ex.getMessage());
        }
    }

    @HttpGet
    global static void doGet() {
        try {
            String uri = RestContext.request.requestURI;
            String path = (uri == null) ? '' : uri.toLowerCase();

            if (path.contains('/outreach/inbound/leads')) {
                LeadListResponse r = getRecentLeads();
                writeJson(r);
                return;
            }

            if (path.contains('/outreach/inbound/lead')) {
                LeadLookupResponse r = getOneLeadByHsContactId();
                writeJson(r);
                return;
            }

            Map<String, Object> help = new Map<String, Object>();
            help.put('status', 'ERROR');
            help.put('message', 'Unsupported GET path. Use /outreach/inbound/lead or /outreach/inbound/leads');
            writeJson(help);

        } catch (Exception e) {
            Map<String, Object> err = new Map<String, Object>();
            err.put('status', 'ERROR');
            err.put('message', e.getMessage());
            writeJson(err);
        }
    }

    private static void writeJson(Object payload) {
        RestContext.response.addHeader('Content-Type', 'application/json');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(payload));
    }

    private static LeadLookupResponse getOneLeadByHsContactId() {
        LeadLookupResponse out = new LeadLookupResponse();

        String hs = RestContext.request.params.get('hs_contact_id');
        if (String.isBlank(hs)) {
            out.status = 'ERROR';
            out.message = 'Missing query param: hs_contact_id';
            return out;
        }
        hs = hs.trim();

        List<Lead> ls = [
            SELECT Id, Email, Phone, Company, Website,
                   HubSpot_Contact_ID__c, Person_Identity__c,
                   SDR_Assigned__c, Routing_Rule__c, Routing_Confidence__c, Routing_Notes__c,
                   Routing_Date__c, Routing_Status__c
            FROM Lead
            WHERE HubSpot_Contact_ID__c = :hs
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (ls.isEmpty()) {
            out.status = 'NOT_FOUND';
            out.message = 'No Lead found for hs_contact_id=' + hs;
            return out;
        }

        Lead l = ls[0];

        out.status = 'OK';
        out.message = 'Found';
        out.leadId = l.Id;

        out.email = l.Email;
        out.phone = l.Phone;
        out.company = l.Company;
        out.website = l.Website;

        out.hubspotContactId = l.HubSpot_Contact_ID__c;
        out.personIdentityId = l.Person_Identity__c;

        out.sdrAssignedId = l.SDR_Assigned__c;
        out.routingRule = l.Routing_Rule__c;
        out.routingConfidence = l.Routing_Confidence__c;
        out.routingNotes = l.Routing_Notes__c;
        out.routingDate = l.Routing_Date__c;
        out.routingStatus = l.Routing_Status__c;

        if (l.Person_Identity__c != null) {
            List<Person_Identity__c> pis = [
                SELECT Id, HubSpot_Contact_ID__c, Normalized_Email__c, Phone_E164__c
                FROM Person_Identity__c
                WHERE Id = :l.Person_Identity__c
                LIMIT 1
            ];
            if (!pis.isEmpty()) {
                Person_Identity__c p = pis[0];
                out.piId = p.Id;
                out.piHubspotContactId = p.HubSpot_Contact_ID__c;
                out.piNormalizedEmail = p.Normalized_Email__c;
                out.piPhoneE164 = p.Phone_E164__c;
            }
        }

        return out;
    }

    private static LeadListResponse getRecentLeads() {
        LeadListResponse out = new LeadListResponse();

        Integer lim = 50;
        String limStr = RestContext.request.params.get('limit');
        if (!String.isBlank(limStr)) {
            try {
                lim = Integer.valueOf(limStr.trim());
            } catch (Exception ignore) {
            }
        }

        if (lim < 1) lim = 1;
        if (lim > 200) lim = 200;

        out.limitValue = lim;

        List<Lead> ls = [
            SELECT Id, CreatedDate, Email, Company,
                   HubSpot_Contact_ID__c,
                   SDR_Assigned__c, Routing_Rule__c, Routing_Confidence__c, Routing_Date__c, Routing_Status__c
            FROM Lead
            ORDER BY CreatedDate DESC
            LIMIT :lim
        ];

        for (Lead l : ls) {
            LeadListItem i = new LeadListItem();
            i.leadId = l.Id;
            i.createdDate = l.CreatedDate;
            i.email = l.Email;
            i.company = l.Company;
            i.hubspotContactId = l.HubSpot_Contact_ID__c;

            i.sdrAssignedId = l.SDR_Assigned__c;
            i.routingRule = l.Routing_Rule__c;
            i.routingConfidence = l.Routing_Confidence__c;
            i.routingDate = l.Routing_Date__c;
            i.routingStatus = l.Routing_Status__c;

            out.items.add(i);
        }

        out.status = 'OK';
        out.message = 'Success';
        out.returnedCount = out.items.size();
        return out;
    }

    private static BatchResponse errorResponse(String msg) {
        BatchResponse out = new BatchResponse();
        out.status = 'ERROR';
        out.received = 0;
        out.inserted = 0;
        out.failed = 0;

        ItemResult r = new ItemResult();
        r.index = -1;
        r.status = 'ERROR';
        r.message = msg;

        out.results.add(r);
        return out;
    }

    private static List<InboundUpdate> parseAsListOrSingle(String body) {
        String t = body.trim();
        if (t.startsWith('[')) {
            return (List<InboundUpdate>) JSON.deserialize(t, List<InboundUpdate>.class);
        } else {
            InboundUpdate single = (InboundUpdate) JSON.deserialize(t, InboundUpdate.class);
            return new List<InboundUpdate>{ single };
        }
    }
}