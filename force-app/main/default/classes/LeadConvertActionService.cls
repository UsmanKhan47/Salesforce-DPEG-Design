/**
 * LeadConvertActionService — the ONLY class in the app that runs Database.convertLead.
 *
 * Backs the custom "Convert" button on the Lead record page (the leadStageActions LWC),
 * invoked through the thin LeadConvertActionController. It owns a single responsibility: run
 * the standard lead conversion for one or more Leads and return the resulting Opportunity Ids,
 * index-aligned to the input list.
 *
 * It deliberately does NOT re-implement any post-conversion stamping. Flipping a Lead to
 * IsConverted fires LeadConvertTrigger (after update) -> LeadConvertService in the SAME
 * transaction, which creates the Property__c and stamps the new Opportunity (Deal Type, the
 * Land/Commercial record type, and Lead_Approved_By__c). By the time Database.convertLead
 * returns, that work has already run synchronously, so the returned Opportunity Id is safe to
 * navigate to immediately.
 *
 * Standard conversion is relied on for everything else: Database.convertLead matches or creates
 * the Account and Contact, and (with setDoNotCreateOpportunity(false)) creates the Opportunity,
 * whose Name the platform derives from the Lead's Company — so no Opportunity name is supplied.
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). No inline SOQL and
 * no selector are needed — the happy path performs no read; Database.convertLead self-validates
 * convertibility. WITH USER_MODE does not apply here: convert is a native conversion call, not a
 * SOQL query, and it already enforces the running user's own convert/CRUD permissions.
 *
 * Permissions: if the running user lacks "Convert Leads", or Create access on
 * Account/Contact/Opportunity, Database.convertLead throws a DmlException. That is deliberately
 * left to propagate — LeadConvertActionController wraps it into a user-safe AuraHandledException
 * whose message the LWC surfaces as a toast.
 *
 * @see force-app/main/default/classes/LeadConvertActionController.cls (thin caller)
 * @see force-app/main/default/classes/LeadConvertService.cls (post-convert stamping, via trigger)
 * @see force-app/main/default/triggers/LeadConvertTrigger.trigger
 */
public with sharing class LeadConvertActionService {

    // The org's converted LeadStatus — the single LeadStatus value flagged converted=true.
    // Verified against LeadStatus.standardValueSet-meta.xml: New, Under Review, Qualified,
    // Disqualified, Converted — only 'Converted' carries <converted>true</converted>. Passing
    // any other value to setConvertedStatus throws.
    private static final String CONVERTED_STATUS = 'Converted';

    /**
     * Converts each Lead to an Account/Contact/Opportunity via the standard conversion path and
     * returns the new Opportunity Ids, index-aligned to the input list.
     *
     * Bulk-safe: builds one Database.LeadConvert per Id and performs a single Database.convertLead
     * call — no conversion (and no DML) inside a loop.
     *
     * @param leadIds the Leads to convert (Qualified in the UI flow; convertLead itself validates
     *                convertibility and throws if a Lead cannot be converted)
     * @return the created Opportunity Ids, one per input Lead in the same order; an empty list when
     *         leadIds is null or empty
     * @throws System.DmlException when the running user lacks convert/CRUD permission, or a Lead
     *         cannot be converted (already converted, blocked by a validation rule, etc.). Left to
     *         propagate so the controller can wrap it as a user-safe AuraHandledException.
     * @example
     * List<Id> oppIds = LeadConvertActionService.convert(new List<Id>{ leadId });
     */
    public static List<Id> convert(List<Id> leadIds) {
        List<Id> opportunityIds = new List<Id>();
        if (leadIds == null || leadIds.isEmpty()) {
            return opportunityIds;
        }

        List<Database.LeadConvert> conversions = new List<Database.LeadConvert>();
        for (Id leadId : leadIds) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(leadId);
            lc.setConvertedStatus(CONVERTED_STATUS);
            // Create (do not suppress) the Opportunity; the platform derives its Name from Company.
            lc.setDoNotCreateOpportunity(false);
            conversions.add(lc);
        }

        // Single all-or-none conversion call. Any failure throws a DmlException, which the
        // controller surfaces to the user; on success the trigger-driven Property/Opportunity
        // stamping has already completed in this same transaction.
        List<Database.LeadConvertResult> results = Database.convertLead(conversions);
        for (Database.LeadConvertResult result : results) {
            opportunityIds.add(result.getOpportunityId());
        }
        return opportunityIds;
    }
}
