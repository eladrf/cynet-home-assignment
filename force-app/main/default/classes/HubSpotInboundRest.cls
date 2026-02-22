@RestResource(urlMapping='/hubspot/inbound')
global with sharing class HubSpotInboundRest {

    // ---------- DTOs ----------
    global class InboundPayload {
        public String hs_contact_id;
        public String email;
        public String first_name;
        public String last_name;
        public String phone;
        public String company;
        public String website;
    }

    global class ItemResult {
        public Integer index;
        public String hs_contact_id;
        public String status;  
        public Id leadId;
        public String message;
    }

    global class BatchResponse {
        public String status;  
        public Integer received;
        public Integer inserted;
        public Integer failed;
        public List<ItemResult> results = new List<ItemResult>();
    }

    // ---------- REST ----------
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

            List<InboundPayload> payloads = parseAsListOrSingle(body);

            out.received = payloads.size();
            if (payloads.isEmpty()) {
                return errorResponse('No payload items found');
            }

            Id inboundLeadRtId = getLeadRecordTypeIdSafe('Inbound_Prospect'); // DeveloperName

            List<Lead> toInsert = new List<Lead>();
            List<Integer> leadIndexByInsertPos = new List<Integer>();
            List<ItemResult> resultsByIndex = new List<ItemResult>();

            List<Id> createdLeadIds = new List<Id>();

            for (Integer i = 0; i < payloads.size(); i++) {
                InboundPayload p = payloads[i];

                ItemResult r = new ItemResult();
                r.index = i;
                r.hs_contact_id = (p == null) ? null : p.hs_contact_id;

                if (p == null) {
                    r.status = 'ERROR';
                    r.message = 'Null item';
                    resultsByIndex.add(r);
                    continue;
                }

                Lead l = new Lead();
                if (inboundLeadRtId != null) l.RecordTypeId = inboundLeadRtId;

                l.FirstName = safeTrim(p.first_name);
                l.LastName  = String.isBlank(p.last_name) ? 'Unknown' : safeTrim(p.last_name);
                l.Company   = String.isBlank(p.company)   ? 'Unknown' : safeTrim(p.company);
                l.Email     = safeTrim(p.email);
                l.Phone     = safeTrim(p.phone);
                l.Website   = safeTrim(p.website);
                l.HubSpot_Contact_ID__c     = p.hs_contact_id;

                l.Routing_Status__c = 'Pending';

                toInsert.add(l);
                leadIndexByInsertPos.add(i);

                r.status = 'OK';
                r.message = 'Queued for insert';
                resultsByIndex.add(r);
            }

            Integer inserted = 0, failed = 0;
            if (!toInsert.isEmpty()) {
                Database.SaveResult[] srs = Database.insert(toInsert, /*allOrNone*/ false);

                for (Integer j = 0; j < srs.size(); j++) {
                    Integer originalIndex = leadIndexByInsertPos[j];
                    ItemResult rr = resultsByIndex[originalIndex];

                    if (srs[j].isSuccess()) {
                        rr.status = 'OK';
                        rr.leadId = srs[j].getId();
                        rr.message = 'Lead created';
                        inserted++;

                        createdLeadIds.add(rr.leadId);
                    } else {
                        rr.status = 'ERROR';
                        rr.message = joinErrors(srs[j].getErrors());
                        failed++;
                    }
                }
            }

            out.results = resultsByIndex;
            out.inserted = inserted;
            out.failed = failed;

            if (failed == 0) out.status = 'OK';
            else if (inserted > 0) out.status = 'PARTIAL';
            else out.status = 'ERROR';

            if (!createdLeadIds.isEmpty()) {
                System.enqueueJob(new IdentityResolutionQueueable(createdLeadIds));
            }

            return out;

        } catch (Exception e) {
            return errorResponse('Unhandled error: ' + e.getMessage());
        }
    }

    private static BatchResponse errorResponse(String msg) {
        BatchResponse out = new BatchResponse();
        out.status = 'ERROR';
        out.received = 0;
        out.inserted = 0;
        out.failed = 0;
        out.results = new List<ItemResult>();

        ItemResult r = new ItemResult();
        r.index = -1;
        r.status = 'ERROR';
        r.message = msg;

        out.results.add(r);
        return out;
    }

    private static List<InboundPayload> parseAsListOrSingle(String body) {
        String t = body.trim();
        if (t.startsWith('[')) {
            return (List<InboundPayload>) JSON.deserialize(t, List<InboundPayload>.class);
        } else {
            InboundPayload single = (InboundPayload) JSON.deserialize(t, InboundPayload.class);
            return new List<InboundPayload>{ single };
        }
    }

    private static String safeTrim(String s) {
        return s == null ? null : s.trim();
    }

    private static String joinErrors(Database.Error[] errs) {
        List<String> parts = new List<String>();
        for (Database.Error e : errs) parts.add(e.getStatusCode() + ': ' + e.getMessage());
        return String.join(parts, ' | ');
    }

    private static Id getLeadRecordTypeIdSafe(String developerName) {
        if (String.isBlank(developerName)) return null;
        Map<String, Schema.RecordTypeInfo> byDevName =
            Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName();
        if (byDevName != null && byDevName.containsKey(developerName)) {
            return byDevName.get(developerName).getRecordTypeId();
        }
        return null;
    }
}