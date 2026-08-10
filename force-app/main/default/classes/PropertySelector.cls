/**
 * Selector for Property__c. Encapsulates ALL SOQL against Property__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live in
 * Selector classes. Nothing else queries that object.").
 *
 * 🔴 THIS IS THE FIRST AND ONLY `Property__c` SOQL IN THE APPLICATION. Measured
 * 2026-08-10: repo-wide there was NO production query against `Property__c` at all —
 * only eight statements inside `LeadConvertServiceTest` / `SellMeterControllerTest`.
 * `Property__c` is the root of the acquisition graph (ARCHITECTURE.md §1) and had no
 * selector, so every future Property read belongs here. Same argument `AccountSelector`
 * (2026-08-02) and `OpportunityContactRoleSelector` (2026-08-03) won.
 *
 * Consumers:
 *   - PropertyAssetService.ensureOnClosedWon -> selectAssetSeedByIds
 *
 * ── ⚠ WHY THIS CLASS EXISTS AT ALL, RATHER THAN A METHOD ON `OpportunitySelector` ──
 * The Tranche 5 design (§2.7 step 3) proposed reading the same two values through the
 * parent path on Opportunity (`SELECT Property__r.Name, Property__r.Asset_Type__c FROM
 * Opportunity`), on the stated grounds that "`Trigger.new` does not carry parent-path
 * fields, so this query is unavoidable". The query is indeed unavoidable; WHICH object it
 * runs against is not, and that half was not examined. `Trigger.new` DOES carry
 * `Opportunity.Property__c` — it is an ordinary field on the record — so the caller
 * already holds every Property Id it needs and re-reading Opportunity to reach Property
 * fields is an indirection that buys nothing. Two further reasons, in order of force:
 *
 *   1. `OpportunitySelector`'s header carries an explicit "🔴 NONE OF THEM MAY BE
 *      WIDENED" warning over its eleven `USER_MODE` methods, with exactly one
 *      `SYSTEM_MODE` exception argued for one automation path. Adding a second
 *      automation-path method there dilutes a warning that is doing real work.
 *   2. Keying on distinct Property Ids DEDUPES for free. Two Opportunities closing
 *      against the same Property return one row here and two rows there.
 *
 * ── MODE — `WITH SYSTEM_MODE`. ⚠ SHARING IS A SEPARATE DECISION, ARGUED BELOW ──
 * `SYSTEM_MODE` lifts CRUD and FLS ONLY. It does NOT touch sharing. Conflating the two
 * is the error recorded as D25 in `agent-output/stage-by-stage-decisions.md` and paid for
 * on 2026-08-08 in `InboundEmailStagingSelector`, so each half is argued on its own.
 *
 * NOT-FOUND CONTRACT — read-for-display: the caller iterates the result and builds one
 * asset per row RETURNED, never one per Id passed in. A Property that does not come back
 * (hard-deleted between the stage change and this read) silently produces no asset rather
 * than a nameless one. `Property_Asset__c.Name` is a mandatory Text name field, so a
 * fabricated row would fail the whole insert and, with it, the deal close.
 *
 * @see InboundEmailStagingSelector.RoutingReads (the `private without sharing` precedent)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class PropertySelector {

    /**
     * The two values `PropertyAssetService` copies onto a new `Property_Asset__c` when a
     * deal reaches Closed Won: the property's `Name` (which becomes the asset's Name) and
     * its `Asset_Type__c` (which is MAPPED, never copied, onto the asset's
     * `Property_Type__c` — see that service for why).
     *
     * ⚠ THE FIELD SET IS DELIBERATELY MINIMAL AND MUST STAY THAT WAY. This query runs on
     * EVERY Closed Won org-wide, inside an after-update trigger, and its caller's insert is
     * all-or-none — so every field added here becomes a new way for a deal close to fail.
     * Two fields are needed; two fields are selected.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION-PATH read in the ARCHITECTURE.md §2 sense: nobody asked for it. It
     * happens on the running user's behalf while the platform turns a won deal into a
     * managed asset. `WITH USER_MODE` does not degrade, it THROWS, and the throw escapes an
     * after-update trigger as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` — rolling back the deal
     * close itself. That is verbatim the `TaskSelector.selectByTransactionDealIds`
     * production incident (82 Day-0 Tasks rolled back by one FLS denial).
     *
     * The exposure is measured, not hypothetical. The Opportunity update that fires this is
     * reachable two ways, and BOTH run as a principal who may hold nothing on `Property__c`:
     *   - `StageAdvanceService.NEXT_STAGE` maps `PSA ⇒ Closed Won` and
     *     `About to Close ⇒ Closed Won`, so any deal driver can drive it; and
     *   - the `Transaction_Complete_Close` flow writes `StageName = 'Closed Won'` with **no
     *     `<runInMode>` element**, i.e. DefaultMode, i.e. as the TRANSACTIONS persona who
     *     flipped the `Transaction__c` to Closed.
     * Every DPEG persona sits on `Minimum Access - Salesforce`, which grants no FLS at all.
     *
     * 🔴 ── AND SHARING, SEPARATELY — SEE THE `AssetCreationReads` INNER CLASS ──
     * `Property__c` is `sharingModel = Private`. Under `with sharing` a principal outside the
     * four sets that grant `viewAllRecords` gets ZERO ROWS, no asset is built, and the deal
     * closes looking perfectly healthy. The SOQL therefore lives in the `without sharing`
     * inner class; this method is the wrapper.
     *
     * BULK read (Set&lt;Id&gt;): called ONCE per trigger chunk regardless of deal count.
     * Never call it per record.
     *
     * @param propertyIds Property Ids to load (bound with IN); null/empty-safe.
     * @return Property__c records with Id, Name and Asset_Type__c populated; an empty list
     *         when the input is null/empty (never null).
     * @example
     * for (Property__c p : PropertySelector.selectAssetSeedByIds(propertyIds)) { ... }
     */
    public static List<Property__c> selectAssetSeedByIds(Set<Id> propertyIds) {
        if (propertyIds == null || propertyIds.isEmpty()) {
            return new List<Property__c>();
        }
        return new AssetCreationReads().assetSeedByIds(propertyIds);
    }

    /**
     * 🔴 THE CLOSED-WON ASSET-CREATION READ, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * ═══ WHY — `WITH SYSTEM_MODE` IS NOT ENOUGH ═══
     * `SYSTEM_MODE` lifts FLS and CRUD only; it does NOT lift record sharing. Measured
     * against this repo 2026-08-10:
     *   - `objects/Property__c/Property__c.object-meta.xml` -> `sharingModel = Private`.
     *   - `sharingRules/Property__c.sharingRules-meta.xml` holds ONE rule, an OWNER rule
     *     sharing rows owned by the `Acquisition` QUEUE to `DPEG_Acquisitions_Team`. A
     *     Property created by `LeadConvertService` is owned by whoever converted the Lead,
     *     NOT by the queue, so that rule does not reach it.
     *   - `viewAllRecords = true` on `Property__c` comes from exactly four permission sets:
     *     `DPEG_Acquisitions`, `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`,
     *     `DPEG_Property_View`.
     * `Opportunity` OWD is `ReadWrite`, so ANY user with Edit on Opportunity can set the
     * stage to Closed Won — including one holding none of those four sets.
     *
     * The failure that produces is the WORSE of the two available failures, and that is the
     * whole argument: under `with sharing` this read returns zero rows, the caller builds
     * zero assets, the deal closes cleanly, and the Property Management tree has no root —
     * **byte-identical, from outside, to the bug this feature was built to fix.** By
     * contrast a `SYSTEM_MODE` + `without sharing` read cannot fail quietly.
     *
     * ═══ WHAT THIS DOES NOT WIDEN ═══
     * The two values never reach a user. They are written into a `Property_Asset__c` the
     * running principal may not be able to see, by a service with no return value, on a
     * record they already named by putting it on the deal they just closed. There is no
     * read surface here to leak through.
     *
     * ═══ PRECEDENT ═══
     * Identical in shape and argument to `InboundEmailStagingSelector.RoutingReads` and
     * `LeadSelector.GuestReads`: an automation that must act on ALL matching rows cannot be
     * scoped by an incidental principal's sharing.
     *
     * ═══ SCOPE — AS NARROW AS APEX ALLOWS ═══
     * Inner classes do NOT inherit the outer class's sharing, so this is declared explicitly
     * and `PropertySelector` itself STAYS `with sharing`. It is `private`, so the only way in
     * is the public static wrapper above — nothing outside this file can borrow an unshared
     * read of `Property__c`. Any future user-requested Property read belongs on the outer
     * class with `WITH USER_MODE`, and must not be moved in here for convenience.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new AssetCreationReads()` at the call site.
     */
    private without sharing class AssetCreationReads {

        /**
         * The asset seed values for a set of properties, read without sharing. See
         * `selectAssetSeedByIds` for the field set and the `SYSTEM_MODE` justification, and
         * the enclosing class for the sharing one.
         *
         * @param propertyIds The properties to read; never null/empty (the wrapper guards it).
         * @return The matching rows; empty when none of the Ids resolve.
         */
        private List<Property__c> assetSeedByIds(Set<Id> propertyIds) {
            return [
                SELECT Id, Name, Asset_Type__c
                FROM Property__c
                WHERE Id IN :propertyIds
                WITH SYSTEM_MODE
            ];
        }
    }
}
