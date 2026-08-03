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
 * Standard conversion is relied on for everything else: (with setDoNotCreateOpportunity(false)) it
 * creates the Opportunity, whose Name the platform derives from the Lead's Company — so no
 * Opportunity name is supplied.
 *
 * ── SMART CONVERSION: ATTACH TO EXISTING RECORDS (added 2026-08-02) ──────────────────────────
 * Triggering incident, live on `usman-dpeg`: converting the Lead *Usman Khan /
 * usmankhan-96@hotmail.com / "Unknown - Via Email"* failed with `DUPLICATES_DETECTED, Duplicate
 * Alert: []`. That broker already existed as a Contact, so standard conversion tried to mint a
 * second Contact for the same person and the org's active Contact duplicate rule blocked the
 * entire conversion. Two changes fix it, and they are independent:
 *
 *   1. ATTACH. convert() now asks LeadConvertMatchService what each Lead should attach to and
 *      applies setContactId / setAccountId when there is a hit. This is wired HERE rather than in
 *      LeadConvertActionController deliberately: this method is the only place in the app that
 *      runs Database.convertLead, so putting it here makes "attach when possible" an invariant of
 *      CONVERSION ITSELF — a future second caller cannot bypass it. In the controller it would
 *      only have been an invariant of one button. The controller also stays thin, and its
 *      three-tier catch ladder and assertLeadActionAccess() ordering stay closed.
 *
 *   2. D4 — BYPASS THE DUPLICATE RULES, ALWAYS, MATCHED OR NOT. setBypassAccountDedupeCheck /
 *      setBypassContactDedupeCheck are set on every conversion. The org's own configured intent
 *      for the standard Contact and Account rules is ALREADY "alert and proceed"
 *      (actionOnInsert=Allow, operationsOnInsert=Alert,Report — i.e. warn a human, let them
 *      continue). Apex conversion has no surface on which to render an alert, so the platform
 *      degrades "Alert" into a hard DUPLICATES_DETECTED. That is not the configured intent, it is
 *      the absence of a UI — the bypass restores the intent. Blocking would protect nothing and
 *      strand the deal: from a headless quick action the user cannot merge, review, or override,
 *      so the failure is terminal for that Lead. (This module's fail-CLOSED philosophy is about
 *      claims and authorization — who wins a property, who may act — not about record creation.
 *      A duplicate Contact does not mis-attribute a commission.) Exact matching in (1) removes the
 *      common duplicate source, so what the bypass actually covers is the residual FUZZY near-miss
 *      — same person at a different email, near-identical firm name — which is rare and
 *      recoverable by a merge.
 *      ACCEPTED COST, stated not hidden: a bypass skips the rule ENTIRELY, including its Report
 *      operation, so NO DuplicateRecordSet is logged for a conversion-created duplicate.
 *      Database.DMLOptions.DuplicateRuleHeader.allowSave is not an alternative here — it does not
 *      reach the records conversion creates, which is why Salesforce added these call-specific
 *      setters. The duplicate rules themselves stay isActive=true and untouched; deactivating them
 *      (the org's precedent for the LEAD rules in e1f5a9f) would strip duplicate protection from
 *      every UI-driven creation path org-wide to unblock one Apex call.
 *      VERIFIED at build time, not assumed (design V1): on DPEG-Acq-5, with both standard rules
 *      active, one fixture converted with the setters and failed without them.
 *
 * Matching NEVER blocks conversion: LeadConvertMatchService fails soft (a denied read degrades to
 * no-match), so a Lead with no match — or a user who cannot read the match fields — still converts,
 * simply with nothing to attach to. ⚠ Note that is NOT the pre-change outcome: change (2) does not
 * degrade with change (1), so such a conversion now SUCCEEDS and silently creates a duplicate where
 * before it was blocked outright. See the fail-soft section of LeadConvertMatchService's header for
 * the combined baseline and its two mitigations (the deploy-time FLS gate on Lead.Email /
 * Contact.Email, and the scheduled Duplicate Job).
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). Still no inline SOQL:
 * the only read is delegated to LeadConvertMatchService, which reads through selectors.
 * WITH USER_MODE does not apply to the convert call itself: it is a native conversion call, not a
 * SOQL query, and it already enforces the running user's own convert/CRUD permissions.
 *
 * Permissions: if the running user lacks "Convert Leads", or Create access on
 * Account/Contact/Opportunity, Database.convertLead throws a DmlException. That is deliberately
 * left to propagate — LeadConvertActionController wraps it into a user-safe AuraHandledException
 * whose message the LWC surfaces as a toast.
 *
 * @see force-app/main/default/classes/LeadConvertActionController.cls (thin caller)
 * @see force-app/main/default/classes/LeadConvertMatchService.cls (decides what to attach to, before)
 * @see force-app/main/default/classes/LeadConvertService.cls (post-convert stamping, via trigger)
 * @see force-app/main/default/triggers/LeadConvertTrigger.trigger
 * @see agent-output/design-requirements-lead-convert-matching.md
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
     * Attaches to the broker's existing Contact and/or firm Account when one exists, instead of
     * minting duplicates — see the Smart Conversion section in the class header. Matching is
     * advisory: no match, or a denied read, converts exactly as this method did before.
     *
     * Bulk-safe: ONE bulk match call (3 SOQL total, independent of input size) followed by one
     * Database.LeadConvert per Id and a single Database.convertLead call — no SOQL, no conversion
     * and no DML inside a loop.
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

        // Decide what each Lead should ATTACH to before converting anything. One bulk call,
        // 3 SOQL total; an empty map (no match, or a denied read) means "behave as before".
        Map<Id, LeadConvertMatchService.ConversionMatch> matches =
            LeadConvertMatchService.matchForConversion(leadIds);

        List<Database.LeadConvert> conversions = new List<Database.LeadConvert>();
        for (Id leadId : leadIds) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(leadId);
            lc.setConvertedStatus(CONVERTED_STATUS);
            // Create (do not suppress) the Opportunity; the platform derives its Name from Company.
            lc.setDoNotCreateOpportunity(false);

            // Attach to the existing broker Contact / firm Account when one was found. Setting
            // only accountId is the valid firm-only match; setting contactId REQUIRES accountId,
            // which LeadConvertMatchService's invariant guarantees is that Contact's own Account.
            LeadConvertMatchService.ConversionMatch match = matches.get(leadId);
            if (match != null) {
                if (match.accountId != null) {
                    lc.setAccountId(match.accountId);
                }
                if (match.contactId != null) {
                    lc.setContactId(match.contactId);
                }
            }

            // ALWAYS bypass, matched or not — see the D4 note in this class's header.
            lc.setBypassAccountDedupeCheck(true);
            lc.setBypassContactDedupeCheck(true);

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
