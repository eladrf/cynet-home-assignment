public with sharing class RoutingQueueable implements Queueable {

    private final List<Id> leadIds;

    public RoutingQueueable(List<Id> leadIds) {
        this.leadIds = (leadIds == null) ? new List<Id>() : new List<Id>(leadIds);
    }

    private class RoutingDecision {
        public Id sdrId;
        public String rule;
        public String confidence;
        public String notes;
        public RoutingDecision(Id sdrId, String rule, String confidence, String notes) {
            this.sdrId = sdrId;
            this.rule = rule;
            this.confidence = confidence;
            this.notes = notes;
        }
    }

    public void execute(QueueableContext context) {
        if (leadIds.isEmpty()) return;

        Map<Id, RoutingDecision> routingByLead = new Map<Id, RoutingDecision>();

        Map<Id, Lead> leadsToUpdate = new Map<Id, Lead>();

        List<Lead> leads = [
            SELECT Id, Email, Company, Website, Phone, OwnerId,
                   Person_Identity__c,
                   SDR_Assigned__c, Routing_Rule__c, Routing_Confidence__c, Routing_Notes__c,
                   Routing_Date__c, Routing_Status__c
            FROM Lead
            WHERE Id IN :leadIds
            AND IsConverted = false
        ];
        if (leads.isEmpty()) return;

        Set<String> domains = new Set<String>();
        Map<Id, String> leadToDomain = new Map<Id, String>();
        for (Lead l : leads) {
            String d = extractDomainFromLead(l);
            if (!String.isBlank(d)) {
                domains.add(d);
                leadToDomain.put(l.Id, d);
            }
        }

        Map<String, Account> domainToAccount = new Map<String, Account>();
        if (!domains.isEmpty()) {
            List<Account> accts = [
                SELECT Id, Name, OwnerId, Website
                FROM Account
                WHERE Website != null
            ];
            for (Account a : accts) {
                String aw = a.Website == null ? null : a.Website.toLowerCase();
                if (aw == null) continue;
                for (String d : domains) { 
                    if (aw.contains(d) && !domainToAccount.containsKey(d)) {
                        domainToAccount.put(d, a); 
                    }
                }
            }
        }
        
        Set<Id> matchedAccountIds = new Set<Id>();
        Map<Id, Id> leadToAccountId = new Map<Id, Id>();
        for (Lead l : leads) {

            String d = leadToDomain.get(l.Id); 
            if (!String.isBlank(d) && domainToAccount.containsKey(d)) {
                Id aid = domainToAccount.get(d).Id; 
                matchedAccountIds.add(aid); 
                leadToAccountId.put(l.Id, aid);  
            }
        }
        
        Set<Id> accountsWithOpenOpp = new Set<Id>();
        if (!matchedAccountIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT AccountId accId, COUNT(Id) cnt
                FROM Opportunity
                WHERE AccountId IN :matchedAccountIds
                AND IsClosed = false
                GROUP BY AccountId
            ]) {
                accountsWithOpenOpp.add((Id) ar.get('accId')); 
            }
        }

        Map<Id, Id> accountToOpenOppOwnerId = new Map<Id, Id>();
        if (!matchedAccountIds.isEmpty()) {
            List<Account> accs = [
                SELECT Id,
                       (SELECT Id, OwnerId, LastModifiedDate
                        FROM Opportunities
                        WHERE IsClosed = false
                        ORDER BY LastModifiedDate DESC
                        LIMIT 1)
                FROM Account
                WHERE Id IN :matchedAccountIds
            ];
            for (Account a : accs) {
                if (a.Opportunities != null && !a.Opportunities.isEmpty()) {
                    accountToOpenOppOwnerId.put(a.Id, a.Opportunities[0].OwnerId);
                }
            }
        }

        Map<Id, String> accountIdToSegment = new Map<Id, String>();
        if (!matchedAccountIds.isEmpty()) {
            for (Account a : [
                SELECT Id, Region__c
                FROM Account
                WHERE Id IN :matchedAccountIds
            ]) {
                if (!String.isBlank(a.Region__c)) {
                    accountIdToSegment.put(a.Id, a.Region__c.trim());
                }
            }
        }

        Map<String, Id> accountEmailToContactId = new Map<String, Id>();
        if (!matchedAccountIds.isEmpty()) {
            List<Contact> cons = [
                SELECT Id, AccountId, Email, FirstName, LastName, Phone
                FROM Contact
                WHERE AccountId IN :matchedAccountIds
                AND Email != null
            ];
            for (Contact c : cons) {
                String key = c.AccountId + '|' + c.Email.trim().toLowerCase();
                if (!accountEmailToContactId.containsKey(key)) {
                    accountEmailToContactId.put(key, c.Id); 
                }
            }
        }


        List<Id> inboundPool = getUsersFromPublicGroup('Inbound_SDRs');      //Public Group - For all SDRs
        Map<String, List<Id>> segmentPools = new Map<String, List<Id>>();
        segmentPools.put('EMEA', getUsersFromPublicGroup('Inbound_SDRs_EMEA')); // Public Group - For all SDRs -- ישראל / אירופה → EMEA
        segmentPools.put('NA',   getUsersFromPublicGroup('Inbound_SDRs_NA'));   // Public Group - For all SDRs --  ארה״ב → NA
        segmentPools.put('APAC', getUsersFromPublicGroup('Inbound_SDRs_APAC')); // אסיהPublic Group - For all SDRs --  → APAC

        Id needsReviewQueueId = getQueueIdByDeveloperName('Inbound_Needs_Review'); // fetch the Queue Id

        String convertedStatus = getAnyConvertedLeadStatus(); // Closed - Converted

        List<Task> tasksToInsert = new List<Task>();
        List<Contact> contactsToUpdate = new List<Contact>();
        List<Database.LeadConvert> converts = new List<Database.LeadConvert>();

        //Cases : 1️⃣ 2️⃣ 3️⃣ 4️⃣
        for (Lead l : leads) {

            // START :  Case 4️⃣ : Incomplete data     
            Boolean companyMissing = String.isBlank(l.Company) || l.Company == 'Unknown';
            Boolean incomplete = String.isBlank(l.Email) && !leadToDomain.containsKey(l.Id) && companyMissing;
            if (incomplete) {
                System.debug('CASE 4');
                if (needsReviewQueueId != null) {
                    Lead upd = new Lead(
                        Id = l.Id,
                        OwnerId = needsReviewQueueId,
                        Routing_Rule__c = 'IncompleteData_NeedsReview',
                        Routing_Confidence__c = 'Low',
                        Routing_Notes__c = 'Missing email/domain/company',
                        Routing_Status__c = 'Needs Review',
                        Routing_Date__c = System.now()
                    );
                    leadsToUpdate.put(l.Id, upd);
                } else {
                    // fallback: do nothing if queue not found
                }
                continue;
            }
            // FINSIED Case 4️⃣  : Incomplete data

            //START : *️⃣ Lead Conversion Policy --- (Contain CASE 1 & CASE 2) 
            Id matchedAccountId = leadToAccountId.get(l.Id); //Acc V
            if (matchedAccountId != null && !String.isBlank(convertedStatus)) {

                Id existingContactId = null;
                if (!String.isBlank(l.Email)) {
                    String key = matchedAccountId + '|' + l.Email.trim().toLowerCase();
                    existingContactId = accountEmailToContactId.get(key); //Acc V Con V
                }

                if (existingContactId != null) {
                    contactsToUpdate.add(new Contact(
                        Id = existingContactId,
                        Phone = (l.Phone == null ? null : l.Phone)
                    ));
                }

                Database.LeadConvert lc = new Database.LeadConvert();
                lc.setLeadId(l.Id);
                lc.setConvertedStatus(convertedStatus);  // Closed - Converted
                lc.setDoNotCreateOpportunity(true);
                lc.setAccountId(matchedAccountId);

                if (existingContactId != null) {
                    lc.setContactId(existingContactId);
                }
                converts.add(lc);
                //START : Case 1️⃣: Account exists (Match) + Open Opportunity
                Boolean hasOpenOpp = accountsWithOpenOpp.contains(matchedAccountId);

                Id sdrId;

                Lead ldRec = new Lead();
                ldRec.Id = l.Id;
                
                if (hasOpenOpp) {
                    System.debug('CASE 1');
                    sdrId = pickSdrForAccount(matchedAccountId, hasOpenOpp, inboundPool, segmentPools, accountToOpenOppOwnerId);

                    //ldRec
                    
                    ldRec.Routing_Confidence__c = 'High';
                    ldRec.Routing_Rule__c = 'ExistingAccount_OpenOpp';
                    ldRec.Routing_Notes__c = 'Existing Account with OpenOpp - Inbound ';



                } else {
                    System.debug('CASE 2');
                    //START : Case 2️⃣: Account exists (Match) + NO Open Opportunity
                    String accSeg = accountIdToSegment.get(matchedAccountId); //Account.Region__c
                    sdrId = pickSdrForAccountNoOpenOpp(matchedAccountId, accSeg, inboundPool, segmentPools);


                    

                    
                    ldRec.Routing_Confidence__c = 'Medium';
                    ldRec.Routing_Rule__c = 'ExistingAccount_NoOpenOpp';
                    ldRec.Routing_Notes__c = 'Existing Account And No OpenOpp - Inbound ';
                    //END : Case 2️⃣: Account exists (Match) + NO Open Opportunity
                }

                routingByLead.put(l.Id, new RoutingDecision(
                    sdrId,
                    hasOpenOpp ? 'ExistingAccount_OpenOpp' : 'ExistingAccount_NoOpenOpp',
                    hasOpenOpp ? 'High' : 'Medium',
                    'Matched AccountId=' + matchedAccountId
                ));

                ldRec.SDR_Assigned__c = sdrId;
                ldRec.Routing_Status__c = 'Routed';
                ldRec.Routing_Date__c = System.now();

                leadsToUpdate.put(l.Id, ldRec);

                //END : Case 1️⃣: Account exists (Match) + Open Opportunity
                
                continue;
            }

            //  Finished -> *️⃣ Lead Conversion  Policy ---


            // START : Case 3️⃣: No Account match -> standard inbound round-robin  - -  We want update SDR_Assigned__c in those CASE 3 !!! [we dont have account !!!] [add task]

            Id sdr = pickInboundSdr(l, inboundPool, segmentPools); // fetch sdr

            if (sdr == null) {
                if (needsReviewQueueId != null) {
                    Lead upd = new Lead(
                        Id = l.Id,
                        OwnerId = needsReviewQueueId,
                        Routing_Status__c = 'Error',
                        Routing_Date__c = System.now()
                    );
                    leadsToUpdate.put(l.Id, upd);
                }
                continue;
            }

            System.debug('CASE 3');
            Lead upd = new Lead(Id = l.Id);
            upd.SDR_Assigned__c = sdr;
            upd.Routing_Rule__c = 'NoAccount_InboundRR';
            upd.Routing_Confidence__c = 'High';
            upd.Routing_Notes__c = 'No account match; inbound RR';
            upd.Routing_Status__c = 'Routed';
            upd.Routing_Date__c = System.now();

            leadsToUpdate.put(l.Id, upd);

            tasksToInsert.add(buildLeadTask(l.Id, sdr, 'Inbound follow-up (Lead)'));

            // FINISHED Case 3️⃣: No Account match -> standard inbound round-robin
        }

        if (!contactsToUpdate.isEmpty()) {
            Database.update(contactsToUpdate, false);
        }

        if (!leadsToUpdate.isEmpty()) {
            Database.update(leadsToUpdate.values(), false);
        }
        
        Map<Id, Database.LeadConvertResult> convertResultByLead = new Map<Id, Database.LeadConvertResult>();
        if (!converts.isEmpty()) {
            List<Database.LeadConvertResult> lcrs = Database.convertLead(converts, false);
            for (Integer i = 0; i < lcrs.size(); i++) {
                Database.LeadConvertResult r = lcrs[i];
                Id leadId = converts[i].getLeadId();
                convertResultByLead.put(leadId, r); // Lead Id -> LeadConvertResult
            }
        }

        if (!convertResultByLead.isEmpty()) {

            Map<Id, Lead> leadsToUpdateAfterConvert = new Map<Id, Lead>();

            for (Id leadId : convertResultByLead.keySet()) {
                Database.LeadConvertResult r = convertResultByLead.get(leadId);
                if (r == null || !r.isSuccess()) continue;

                RoutingDecision dec = routingByLead.get(leadId);

                Id contactId = r.getContactId();
                Id accountId = r.getAccountId();

                if (contactId != null && dec.sdrId != null) {
                    tasksToInsert.add(buildContactTask(contactId, accountId, dec.sdrId,
                        'Inbound follow-up (Converted to Contact)'));
                }

                leadsToUpdateAfterConvert.put(leadId, new Lead(
                    Id = leadId,
                    Routing_Status__c = 'Converted',
                    Routing_Date__c = System.now()
                ));
            }

            if (!leadsToUpdateAfterConvert.isEmpty()) {
                Database.update(leadsToUpdateAfterConvert.values(), false);
            }
        }

        if (!tasksToInsert.isEmpty()) {
            Database.insert(tasksToInsert, false);
        }
    }

    private static Id pickSdrForAccount(
        Id accountId, 
        Boolean hasOpenOpp, 
        List<Id> inboundPool, 
        Map<String, List<Id>> segmentPools,
        Map<Id, Id> accountToOpenOppOwnerId 
    ) {
        List<Id> pool = inboundPool;
        if (pool == null || pool.isEmpty()) return null;

        if (hasOpenOpp) {
            Id oppOwnerId = (accountToOpenOppOwnerId == null) ? null : accountToOpenOppOwnerId.get(accountId);

            if (oppOwnerId == null) oppOwnerId = accountId;

            Integer sizeVal = pool.size();
            Integer hashVal = Math.abs(String.valueOf(oppOwnerId).hashCode());
            Integer idx = safeMod(hashVal, sizeVal);

            return pool[idx];
        }

        Integer sizeVal = pool.size();
        Integer hashVal = Math.abs(String.valueOf(accountId).hashCode());
        Integer idx = safeMod(hashVal, sizeVal);
        return pool[idx];
    }

    private static Id pickSdrForAccountNoOpenOpp(
        Id accountId,
        String accountSegment, 
        List<Id> inboundPool, 
        Map<String, List<Id>> segmentPools 
    ) {
        //START : Case 2️⃣: Account exists (Match) + NO Open Opportunity
        List<Id> pool = inboundPool;

        if (!String.isBlank(accountSegment) && segmentPools != null && segmentPools.containsKey(accountSegment)) {
            List<Id> p = segmentPools.get(accountSegment);
            if (p != null && !p.isEmpty()) pool = p;
        }

        if (pool == null || pool.isEmpty()) return null;

        Integer sizeVal = pool.size();
        Integer hashVal = Math.abs(String.valueOf(accountId).hashCode());
        Integer idx = safeMod(hashVal, sizeVal);

        return pool[idx];

        //END : Case 2️⃣: Account exists (Match) + NO Open Opportunity
    }

    private static Id pickInboundSdr(Lead l, List<Id> inboundPool, Map<String, List<Id>> segmentPools) {
        String seg = deriveSegment(l); 

        List<Id> pool = inboundPool; 

        if (!String.isBlank(seg) && segmentPools != null && segmentPools.containsKey(seg)) {
            List<Id> p = segmentPools.get(seg);
            if (p != null && !p.isEmpty()) pool = p; 
        }

        if (pool == null || pool.isEmpty()) return null;

        Integer sizeVal = pool.size();
        Integer hashVal = Math.abs(String.valueOf(l.Id).hashCode());
        Integer idx = safeMod(hashVal, sizeVal);

        return pool[idx];
    }

    private static Integer safeMod(Integer a, Integer b) {
        if (b == null || b == 0) return 0;
        Integer q = a / b;         
        return a - (q * b);        
    }

    private static String deriveSegment(Lead l) {
        if (!String.isBlank(l.Phone)) {
            String p = l.Phone.trim();
            if (p.startsWith('+1')) return 'NA';
            if (p.startsWith('+81') || p.startsWith('+86') || p.startsWith('+82') || p.startsWith('+61') || p.startsWith('+64') || p.startsWith('+65') || p.startsWith('+91')) return 'APAC';
            if (p.startsWith('+972') || p.startsWith('+44') || p.startsWith('+33') || p.startsWith('+49') || p.startsWith('+39') || p.startsWith('+34') || p.startsWith('+31') || p.startsWith('+32')) return 'EMEA';
        }

        if (!String.isBlank(l.Email)) {
            String e = l.Email.trim().toLowerCase();

            // EMEA (your existing example + common EU/UK)
            if (e.endsWith('.il') || e.endsWith('.uk') || e.endsWith('.de') || e.endsWith('.fr') || e.endsWith('.es') || e.endsWith('.it') || e.endsWith('.nl')) return 'EMEA';

            // NA
            if (e.endsWith('.us') || e.endsWith('.ca') || e.endsWith('.mx')) return 'NA';

            // APAC
            if (e.endsWith('.jp') || e.endsWith('.cn') || e.endsWith('.sg') || e.endsWith('.au') || e.endsWith('.nz') || e.endsWith('.in') || e.endsWith('.kr')) return 'APAC';
        }

        return null;
    }

    private static String extractDomainFromLead(Lead l) {
        if (!String.isBlank(l.Email) && l.Email.contains('@')) {
            String d = l.Email.substringAfter('@').trim().toLowerCase();
            d = stripWww(d);
            if (d.contains('>')) return null; 
            return d;
        }
        if (!String.isBlank(l.Website)) {
            String d = normalizeDomainFromUrl(l.Website);
            return d;
        }
        return null;
    }

    private static String normalizeDomainFromUrl(String url) {
        if (String.isBlank(url)) return null;
        String u = url.trim().toLowerCase();
        u = u.replace('https://', '').replace('http://', '');
        Integer slash = u.indexOf('/');
        if (slash > 0) u = u.substring(0, slash);
        u = stripWww(u);
        return String.isBlank(u) ? null : u;
    }

    private static String stripWww(String d) {
        if (String.isBlank(d)) return d;
        return d.startsWith('www.') ? d.substring(4) : d;
    }

    private static Id getQueueIdByDeveloperName(String developerName) {
        if (String.isBlank(developerName)) return null;
        List<Group> gs = [
            SELECT Id
            FROM Group
            WHERE Type = 'Queue'
            AND DeveloperName = :developerName
            LIMIT 1
        ];
        return gs.isEmpty() ? null : gs[0].Id;
    }

    private static List<Id> getUsersFromPublicGroup(String groupDevName) {
        if (String.isBlank(groupDevName)) return new List<Id>();

        List<Group> gs = [
            SELECT Id
            FROM Group
            WHERE Type = 'Regular'
            AND DeveloperName = :groupDevName
            LIMIT 1
        ];
        if (gs.isEmpty()) return new List<Id>();

        Id groupId = gs[0].Id;

        List<GroupMember> gms = [
            SELECT UserOrGroupId
            FROM GroupMember
            WHERE GroupId = :groupId
        ];

        Set<Id> userIds = new Set<Id>();
        for (GroupMember gm : gms) {
            if (String.valueOf(gm.UserOrGroupId).startsWith('005')) {
                userIds.add(gm.UserOrGroupId);
            }
        }

        List<User> us = [
            SELECT Id
            FROM User
            WHERE Id IN :userIds
            AND IsActive = true
        ];

        List<Id> out = new List<Id>();
        for (User u : us) out.add(u.Id);
        return out;
    }

    private static String getAnyConvertedLeadStatus() {
        List<LeadStatus> sts = [SELECT MasterLabel, IsConverted FROM LeadStatus WHERE IsConverted = true LIMIT 1]; // Closed - Converted
        return sts.isEmpty() ? null : sts[0].MasterLabel;
    }

    private static Task buildLeadTask(Id leadId, Id ownerId, String subject) {
        Task t = new Task();
        t.OwnerId = ownerId;
        t.Subject = subject;
        t.WhoId = leadId;
        t.Status = 'Not Started';
        t.Priority = 'Normal';
        return t;
    }

    private static Task buildContactTask(Id contactId, Id accountId, Id ownerId, String subject) {
        Task t = new Task();
        t.OwnerId = ownerId;
        t.Subject = subject;
        t.WhoId = contactId;
        if (accountId != null) t.WhatId = accountId;
        t.Status = 'Not Started';
        t.Priority = 'Normal';
        return t;
    }
}