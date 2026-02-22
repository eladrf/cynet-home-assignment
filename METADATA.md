# Metadata / Configuration Inventory

## A) Apex classes
- `HubSpotInboundRest`
- `IdentityResolutionQueueable`
- `RoutingQueueable`
- `OutreachInboundRest`

## B) Custom Object
### Person_Identity__c
Fields:
- `HubSpot_Contact_ID__c` (Text)
- `Normalized_Email__c` (Text)
- `Phone_E164__c` (Text)

## C) Lead fields created/used
Identity:
- `HubSpot_Contact_ID__c` (Text)
- `Person_Identity__c` (Lookup)

Routing & SDR:
- `SDR_Assigned__c` (Lookup(User))
- `Routing_Rule__c` (Text 80)
- `Routing_Confidence__c` (Picklist: High / Medium / Low)
- `Routing_Notes__c` (Long Text Area)
- `Routing_Date__c` (Date/Time)
- `Routing_Status__c` (Picklist: Pending / Routed / Needs Review / Converted / Error)

Standard fields used:
- Lead: `Email`, `Phone`, `Company`, `Website`, `OwnerId`, `IsConverted`
- Account: `Website`, (optional) `Region__c`
- Contact: `Email`, `Phone`, `AccountId`
- Opportunity: `AccountId`, `IsClosed`, `OwnerId`

## D) Lead → Contact field mapping (conversion)
Recommended to map:
- `Person_Identity__c`
- `SDR_Assigned__c`
- `Routing_Rule__c`
- `Routing_Confidence__c`
- `Routing_Notes__c`
- `Routing_Date__c`
- `Routing_Status__c`

(You have already configured several of these in Setup → Object Manager → Lead → Fields & Relationships → **Map Lead Fields**.)

## E) Groups / Queues
Queue:
- `Inbound_Needs_Review` (Lead)

Public Groups:
- `Inbound_SDRs`
- `Inbound_SDRs_EMEA`
- `Inbound_SDRs_NA`
- `Inbound_SDRs_APAC`

## F) RecordType (optional)
Lead RecordType DeveloperName:
- `Inbound_Prospect` (used if present)

## G) Notes on deterministic routing
- Scenario 3 uses deterministic hashing on Lead.Id into a pool list
- Scenario 1 aligns to the most recent open Opportunity owner (then hashes into the pool)
- Scenario 2 hashes by AccountId within segment pool

