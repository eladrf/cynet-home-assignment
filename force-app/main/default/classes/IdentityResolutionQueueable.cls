public with sharing class IdentityResolutionQueueable implements Queueable {

    private final List<Id> leadIds;

    public IdentityResolutionQueueable(List<Id> leadIds) {
        this.leadIds = (leadIds == null) ? new List<Id>() : new List<Id>(leadIds);
    }

    public void execute(QueueableContext context) {
        if (leadIds.isEmpty()) return;
        
        List<Lead> leads = [
            SELECT Id, Email, Phone, HubSpot_Contact_ID__c, Person_Identity__c
            FROM Lead
            WHERE Id IN :leadIds
        ];

        List<Lead> work = new List<Lead>();
        for (Lead l : leads) if (l.Person_Identity__c == null) work.add(l);
        if (work.isEmpty()) {
            System.enqueueJob(new RoutingQueueable(leadIds));
            return;
        }

        Set<String> hsIds = new Set<String>();
        Set<String> emails = new Set<String>();
        Set<String> phones = new Set<String>();

        Map<Id, String> leadIdToEmail = new Map<Id, String>();
        Map<Id, String> leadIdToPhone = new Map<Id, String>();

        for (Lead l : work) {
            if (!String.isBlank(l.HubSpot_Contact_ID__c)) hsIds.add(l.HubSpot_Contact_ID__c.trim());

            String normEmail = normalizeEmail(l.Email);
            if (!String.isBlank(normEmail)) {
                emails.add(normEmail);
                leadIdToEmail.put(l.Id, normEmail);
            }

            String normPhone = normalizePhone(l.Phone);
            if (!String.isBlank(normPhone)) {
                phones.add(normPhone);
                leadIdToPhone.put(l.Id, normPhone);
            }
        }

        Map<String, Id> hsToPid = new Map<String, Id>();
        Map<String, Id> emailToPid = new Map<String, Id>();
        Map<String, Id> phoneToPid = new Map<String, Id>();

        if (!hsIds.isEmpty()) {
            for (Person_Identity__c p : [
                SELECT Id, HubSpot_Contact_ID__c
                FROM Person_Identity__c
                WHERE HubSpot_Contact_ID__c IN :hsIds
            ]) {
                hsToPid.put(p.HubSpot_Contact_ID__c, p.Id);
            }
        }

        if (!emails.isEmpty()) {
            for (Person_Identity__c p : [
                SELECT Id, Normalized_Email__c
                FROM Person_Identity__c
                WHERE Normalized_Email__c IN :emails
            ]) {
                emailToPid.put(p.Normalized_Email__c, p.Id);
            }
        }

        if (!phones.isEmpty()) {
            for (Person_Identity__c p : [
                SELECT Id, Phone_E164__c
                FROM Person_Identity__c
                WHERE Phone_E164__c IN :phones
            ]) {
                phoneToPid.put(p.Phone_E164__c, p.Id);
            }
        }

        List<Person_Identity__c> toCreate = new List<Person_Identity__c>();
        
        Map<String, Person_Identity__c> newByHs = new Map<String, Person_Identity__c>();
        Map<String, Person_Identity__c> newByPhone = new Map<String, Person_Identity__c>();
        Map<String, Person_Identity__c> newByEmail = new Map<String, Person_Identity__c>();

        for (Lead l : work) {

            String hs = String.isBlank(l.HubSpot_Contact_ID__c) ? null : l.HubSpot_Contact_ID__c.trim();
            String em = leadIdToEmail.get(l.Id);
            String ph = leadIdToPhone.get(l.Id);

            Boolean hasMatch =
                (hs != null && hsToPid.containsKey(hs)) ||
                (ph != null && phoneToPid.containsKey(ph)) ||
                (em != null && emailToPid.containsKey(em));
            if (hasMatch) continue;

            Boolean alreadyCreated =
                (hs != null && newByHs.containsKey(hs)) ||
                (ph != null && newByPhone.containsKey(ph)) ||
                (em != null && newByEmail.containsKey(em));
            if (alreadyCreated) continue;

            Person_Identity__c p = new Person_Identity__c();
            p.HubSpot_Contact_ID__c = hs;
            p.Normalized_Email__c = em;
            p.Phone_E164__c = ph;
            p.HubSpot_Contact_ID__c =l.HubSpot_Contact_ID__c; // Need to check

            toCreate.add(p);


            if (hs != null) newByHs.put(hs, p);
            else if (ph != null) newByPhone.put(ph, p);
            else if (em != null) newByEmail.put(em, p);
        }

        if (!toCreate.isEmpty()) {
            Database.insert(toCreate, false);
        }

        for (String hs : newByHs.keySet()) if (newByHs.get(hs).Id != null) hsToPid.put(hs, newByHs.get(hs).Id);
        for (String ph : newByPhone.keySet()) if (newByPhone.get(ph).Id != null) phoneToPid.put(ph, newByPhone.get(ph).Id);
        for (String em : newByEmail.keySet()) if (newByEmail.get(em).Id != null) emailToPid.put(em, newByEmail.get(em).Id);

        List<Lead> toUpdate = new List<Lead>();

        for (Lead l : work) {
            String hs = String.isBlank(l.HubSpot_Contact_ID__c) ? null : l.HubSpot_Contact_ID__c.trim();
            String em = leadIdToEmail.get(l.Id);
            String ph = leadIdToPhone.get(l.Id);

            Id pid =
                (hs != null && hsToPid.containsKey(hs)) ? hsToPid.get(hs) :
                (ph != null && phoneToPid.containsKey(ph)) ? phoneToPid.get(ph) :
                (em != null && emailToPid.containsKey(em)) ? emailToPid.get(em) :
                null;

            if (pid != null) {
                toUpdate.add(new Lead(Id = l.Id, Person_Identity__c = pid));
            }
        }

        if (!toUpdate.isEmpty()) update toUpdate;

        System.enqueueJob(new RoutingQueueable(leadIds));
    }

    private static String normalizeEmail(String email) {
        return String.isBlank(email) ? null : email.trim().toLowerCase();
    }

    private static String normalizePhone(String phone) {
        if (String.isBlank(phone)) return null;
        String t = phone.trim();
        String out = '';
        for (Integer i = 0; i < t.length(); i++) {
            String c = t.substring(i, i+1);
            if ((c >= '0' && c <= '9') || (c == '+' && out == '')) out += c;
        }
        return String.isBlank(out) ? null : out;
    }
}