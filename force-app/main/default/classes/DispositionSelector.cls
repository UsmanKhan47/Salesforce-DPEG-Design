/**
 * Selector for Disposition__c. Encapsulates ALL SOQL against Disposition__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live
 * in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumers:
 *   - DispositionController.findOrCreate      -> selectMostRecentByPropertyAssetId
 *   - DispositionController.getClosingSummary -> selectClosingSummaryById
 *   - BovController.getOutreachSummary        -> selectOutreachById
 *
 * MODE — every query uses `WITH USER_MODE` (API 67). Disposition__c is a custom
 * object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe and
 * enforces the running user's sharing + FLS. There is no guest path for the
 * Disposition module, so no SYSTEM_MODE appears here. USER_MODE also covers the
 * Wires__r relationship subquery (Wire__c is likewise custom, FLS gap 0).
 *
 * NOT-FOUND CONTRACT is per-caller and encoded in the method shape:
 *   - read-for-display  (selectMostRecentByPropertyAssetId) -> a missing
 *     Disposition is normal (that is the whole point of find-OR-create), so this
 *     returns SObject-or-null. The assetId is bound straight into the query with
 *     no pre-query guard, preserving findOrCreate's exact query semantics.
 *   - fetch-for-use     (selectClosingSummaryById / selectOutreachById) -> both
 *     callers assigned the query straight to a single Disposition__c, so a miss
 *     threw the native System.QueryException. Those methods preserve that exact
 *     behavior via a single-row SOQL assignment — they do not invent a business
 *     exception and do not return null.
 *
 * RELATIONSHIP SUBQUERY — getClosingSummary needs the "has this Disposition a Wire
 * yet?" flag, which it derives from `(SELECT Id FROM Wires__r LIMIT 1)`. Per the
 * wave-E scope note, a relationship subquery stays inside the parent Disposition
 * query here; it is not split into a separate selector call.
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 * @see OpportunitySelector.cls (fetch-for-use single-row pattern)
 */
public with sharing class DispositionSelector {

    /**
     * Most-recent Disposition for one Property Asset — backs
     * DispositionController.findOrCreate. A Property Asset with no Disposition yet
     * is a normal state (the caller then inserts one), so this returns null rather
     * than throwing.
     *
     * ORDER BY is `CreatedDate DESC` only, preserving findOrCreate's original
     * ordering verbatim (no Id tiebreak was present, so none is added).
     *
     * @param propertyAssetId Property_Asset__c Id to read the latest Disposition for.
     * @return The most recently created Disposition__c for the asset
     *         (ORDER BY CreatedDate DESC LIMIT 1), or null when none exists.
     * @example
     * Disposition__c d = DispositionSelector.selectMostRecentByPropertyAssetId(assetId);
     */
    public static Disposition__c selectMostRecentByPropertyAssetId(Id propertyAssetId) {
        List<Disposition__c> dispositions = [
            SELECT Id
            FROM Disposition__c
            WHERE Property_Asset__c = :propertyAssetId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return dispositions.isEmpty() ? null : dispositions[0];
    }

    /**
     * Loads the closing-summary fields for one Disposition, plus whether it has any
     * Wire yet — backs DispositionController.getClosingSummary.
     *
     * FETCH-FOR-USE: the caller assigned the query straight to a single
     * Disposition__c, so a miss is an error. Preserved here via a single-row SOQL
     * assignment that throws the native System.QueryException when the Id resolves
     * to no row. The Wires__r subquery (LIMIT 1) is kept inside this parent query
     * so the caller can compute row.wireCreated = !d.Wires__r.isEmpty().
     *
     * @param dispositionId Disposition__c Id to load; must reference an existing row.
     * @return The Disposition__c with the closing-summary field set and its
     *         Wires__r child rows populated.
     * @throws System.QueryException when no Disposition__c matches the Id.
     */
    public static Disposition__c selectClosingSummaryById(Id dispositionId) {
        return [
            SELECT Id, Property_Asset__r.Name, Disposition_Stage__c,
                   PSA_Executed__c, Title_Company__c, Closing_Statement_Uploaded__c,
                   (SELECT Id FROM Wires__r LIMIT 1)
            FROM Disposition__c
            WHERE Id = :dispositionId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Loads the broker-outreach summary fields for one Disposition — backs
     * BovController.getOutreachSummary.
     *
     * FETCH-FOR-USE: the caller assigned the query straight to a single
     * Disposition__c, so a miss is an error. Preserved here via a single-row SOQL
     * assignment that throws the native System.QueryException when the Id resolves
     * to no row. Package_Sent__c is a DATE despite its Boolean-sounding name
     * (TestDataFactory ⚠2) — it is selected here as the package-sent date the
     * summary displays.
     *
     * @param dispositionId Disposition__c Id to load; must reference an existing row.
     * @return The Disposition__c with the outreach-summary field set populated.
     * @throws System.QueryException when no Disposition__c matches the Id.
     */
    public static Disposition__c selectOutreachById(Id dispositionId) {
        return [
            SELECT Id, Property_Asset__r.Name, Package_Sent__c, Submission_Deadline__c,
                   Responses_Received__c, Brokers_Contacted__c, Selected_Broker__c
            FROM Disposition__c
            WHERE Id = :dispositionId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
