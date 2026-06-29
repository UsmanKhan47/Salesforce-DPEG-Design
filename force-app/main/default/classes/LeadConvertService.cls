/**
 * Runs on lead conversion (from LeadConvertTrigger). Two jobs, in one transaction:
 *
 *   1. Deal type / record type — carries the lead's Deal Type onto the new
 *      Opportunity and sets the matching Opportunity record type (Land or
 *      Commercial) so the deal lands on the correct sales path. Standard
 *      conversion doesn't translate a custom picklist into the record-type
 *      choice, so we apply it here.
 *
 *   2. Property creation — standard conversion only ever creates the
 *      Account, Contact, and Opportunity (all standard objects); it never
 *      creates the custom Property. So we create the Property the deal is about
 *      and link it to the Opportunity (Opportunity.Property__c), copying the
 *      seller's asking price and cap rate (from the lead's Guidance fields)
 *      plus the address, asset type, and Placer/CoStar links carried on the lead.
 */
public with sharing class LeadConvertService {

    /**
     * Called from the Lead after-update trigger. For each lead that just
     * converted (and created an Opportunity), build its Property and stamp the
     * Opportunity's Property link, Deal Type, and RecordTypeId.
     */
    public static void stampConvertedOpportunities(List<Lead> newLeads, Map<Id, Lead> oldMap) {
        // Leads that just converted in this transaction, keyed by the Opportunity created.
        Map<Id, Lead> oppToLead = new Map<Id, Lead>();
        for (Lead l : newLeads) {
            Lead prior = (oldMap == null) ? null : oldMap.get(l.Id);
            Boolean justConverted = l.IsConverted && (prior == null || !prior.IsConverted);
            if (justConverted && l.ConvertedOpportunityId != null) {
                oppToLead.put(l.ConvertedOpportunityId, l);
            }
        }
        if (oppToLead.isEmpty()) {
            return;
        }

        // 1. Build one Property per converted deal; track which Opportunity each belongs to.
        Set<String> allowedAssetTypes = assetTypePicklistValues();
        List<Property__c> properties = new List<Property__c>();
        List<Id> propertyOppIds = new List<Id>(); // parallel to `properties`
        for (Id oppId : oppToLead.keySet()) {
            properties.add(buildProperty(oppToLead.get(oppId), allowedAssetTypes));
            propertyOppIds.add(oppId);
        }
        // allOrNone = false: a single bad Property must never roll back the whole conversion.
        Map<Id, Id> oppToPropertyId = new Map<Id, Id>();
        Database.SaveResult[] saves = Database.insert(properties, false);
        for (Integer i = 0; i < saves.size(); i++) {
            if (saves[i].isSuccess()) {
                oppToPropertyId.put(propertyOppIds[i], saves[i].getId());
            }
        }

        // 2. Resolve Opportunity record types by developer name (Land / Commercial).
        Map<String, Id> rtByName = new Map<String, Id>();
        for (RecordType rt : [
            SELECT Id, DeveloperName
            FROM RecordType
            WHERE SobjectType = 'Opportunity' AND DeveloperName IN ('Land', 'Commercial')
        ]) {
            rtByName.put(rt.DeveloperName, rt.Id);
        }

        // 3. One update per Opportunity: link the Property and stamp deal type / record type.
        List<Opportunity> updates = new List<Opportunity>();
        for (Id oppId : oppToLead.keySet()) {
            Lead l = oppToLead.get(oppId);
            Opportunity o = new Opportunity(Id = oppId);
            if (oppToPropertyId.containsKey(oppId)) {
                o.Property__c = oppToPropertyId.get(oppId);
            }
            if (String.isNotBlank(l.Deal_Type__c)) {
                o.Deal_Type__c = l.Deal_Type__c;
                Id rtId = rtByName.get(l.Deal_Type__c); // dealType is 'Land' or 'Commercial'
                if (rtId != null) {
                    o.RecordTypeId = rtId;
                }
            }
            updates.add(o);
        }
        update updates;
    }

    /**
     * Builds (does not insert) the Property for a converted lead, copying the fields the
     * lead carries. Asset type is only set when the lead's value exists on Property's
     * restricted picklist, so an unexpected value can't fail the insert.
     */
    private static Property__c buildProperty(Lead l, Set<String> allowedAssetTypes) {
        String address = String.isNotBlank(l.Property_Address__c) ? l.Property_Address__c : l.Street;
        String name = firstNonBlank(new List<String>{ address, l.Company, l.Name });
        if (name == null) {
            name = 'Property';
        }
        if (name.length() > 80) { // Name is a Text field, max 80 chars
            name = name.substring(0, 80);
        }

        Property__c p = new Property__c();
        p.Name = name;
        p.Address__c = address;
        p.City__c = l.City;
        p.State__c = l.State;
        p.Zip__c = l.PostalCode;
        // The seller's stated asking terms carried on the lead become the Property's asking terms.
        p.Asking_Price__c = l.Guidance_Price__c;
        p.Cap_Rate_Asking__c = l.Guidance_Cap_Rate__c;
        p.Placer_URL__c = l.Placer_AI_Link__c;
        p.CoStar_URL__c = l.CoStar_Link__c;
        if (String.isNotBlank(l.Asset_Type__c) && allowedAssetTypes.contains(l.Asset_Type__c)) {
            p.Asset_Type__c = l.Asset_Type__c;
        }
        return p;
    }

    private static String firstNonBlank(List<String> values) {
        for (String v : values) {
            if (String.isNotBlank(v)) {
                return v;
            }
        }
        return null;
    }

    // Active values on Property.Asset_Type__c, so we never push a value its restricted picklist rejects.
    private static Set<String> assetTypePicklistValues() {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry e : Property__c.Asset_Type__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                values.add(e.getValue());
            }
        }
        return values;
    }
}
