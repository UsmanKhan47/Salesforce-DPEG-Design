/**
 * Selector for Disposition__c. Encapsulates ALL SOQL against Disposition__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live
 * in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumers:
 *   - DispositionController.findOrCreate      -> selectMostRecentByPropertyAssetId
 *   - DispositionController.getClosingSummary -> selectClosingSummaryById
 *   - BovController.getOutreachSummary        -> selectOutreachById
 *   - ContractExecutionService.handleExecution -> selectStagesByIds  (Tranche 3C, 2026-08-09)
 *   - DispositionTractionService.evaluateAll  -> selectListingClockByIds (Tranche 5B, 2026-08-10)
 *
 * ⚠ MIXED MODES SINCE 2026-08-09 (Tranche 3C) — READ THE METHOD, NEVER THIS HEADER. The three
 * controller-backed reads above stay `WITH USER_MODE`; selectStagesByIds and
 * selectListingClockByIds are `WITH SYSTEM_MODE` under the ARCHITECTURE.md §2 automation-path
 * exception, each justified at its own declaration (which is where §2 says the authoritative
 * inventory lives). The sentence this replaced — "There is no guest path for the Disposition
 * module, so no SYSTEM_MODE appears here" — was reasoning from the wrong test: the exception is
 * about reads the running user never asked for, not about anonymous ones. That distinction is now
 * the difference between three USER_MODE methods and two SYSTEM_MODE ones.
 *
 * ⚠ AND THE TWO SYSTEM_MODE METHODS REACH OPPOSITE CONCLUSIONS ON SHARING FROM THE ONE THIS CLASS
 * DECLARES — both leave it user-scoped, but for different reasons, and the sibling
 * `DispositionOfferSelector` reaches the OTHER answer for the same feature. `SYSTEM_MODE` never
 * implies `without sharing`; it is always a second, separate question.
 *
 * MODE (the three USER_MODE reads) — Disposition__c is a custom object; P3 proved the custom-field
 * FLS gap is 0, so USER_MODE is safe and enforces the running user's sharing + FLS. USER_MODE also
 * covers the Wires__r relationship subquery (Wire__c is likewise custom, FLS gap 0).
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

    /**
     * Current stage for a set of Dispositions — backs ContractExecutionService.handleExecution's
     * disposition arm (Tranche 3C, 2026-08-09), which moves a sale to `Closing` when its PSA is
     * executed.
     *
     * 🔴 IT EXISTS TO SUPPORT A NO-CHANGE CHECK, WHICH IS THE POINT AND NOT AN OPTIMISATION.
     * `Disposition__c` is the entry object of THREE approval processes (Sale_Decision at
     * Disposition Readiness, Broker_Selection at BOV Outreach, Closing_Approval at Closing), all
     * declaring `recordEditability = AdminOnly` — so while any is pending the record is LOCKED and
     * ANY update to it throws ENTITY_IS_LOCKED. The sharpest case is self-inflicted:
     * `Closing_Approval`'s entry criteria is `Disposition_Stage__c equals Closing`, which is
     * exactly the value this feature writes, so a re-executed PSA on a disposition already at
     * Closing-under-approval would fire a write that changes NOTHING and can only fail. Reading the
     * stage first lets the caller drop those rows before the DML. That is Tranche 2's C1 lesson
     * (`Flag_Changed` no-change Decision + fault connector) expressed in Apex.
     *
     * ── 🔴 WITH SYSTEM_MODE — automation path, and the failure it prevents is not this feature's ──
     * ARCHITECTURE.md §2's exception applies on its own terms: this read happens INSIDE AN
     * AFTER-UPDATE TRIGGER on a DIFFERENT object, on behalf of whoever executed the PSA. Nobody
     * asked for it and nothing it returns is displayed.
     *
     * The consequence of USER_MODE here would be the `TaskRollupService` production failure
     * verbatim, one module over: whoever executes a sell-side PSA is Legal or a deal driver, not
     * necessarily a `Disposition__c` reader, and `USER_MODE` THROWS rather than degrades. That
     * `QueryException` would escape `ContractReviewTriggerHandler.afterUpdate` as
     * CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and roll back **the PSA execution itself** — the
     * Contract Review's own `Executed` status, the Opportunity Day-0 stamp, the three team
     * notifications — to protect a stage advance. A read added to make a feature safer must not be
     * able to destroy the transaction it was added to.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE. `SYSTEM_MODE` lifts CRUD and
     * FLS, never sharing, and this class stays `with sharing`. `Disposition__c` is OWD Private, so
     * a caller who cannot SEE the disposition reads no row for it — and because the caller treats
     * an unread Id as "do not write", that degrades to SKIPPING the stage advance rather than to
     * writing a wrong one. That is the correct failure direction and it is why no
     * `without sharing` inner class is warranted here: contrast
     * `InboundEmailStagingSelector.RoutingReads`, where the automation runs as a principal that
     * does not own the rows AND the miss produced silence indistinguishable from health. Here the
     * residual is visible on the record (a disposition parked at PSA whose Contract Review reads
     * Executed) and is fixable by hand.
     *
     * Bulk-safe: ONE query for the whole set, never one per record.
     *
     * @param dispositionIds Disposition__c Ids; null/empty-safe.
     * @return Dispositions with Id and Disposition_Stage__c populated; empty when the input is
     *         null or empty. A row the running user cannot SEE is simply absent (see above).
     * @example
     * List&lt;Disposition__c&gt; rows = DispositionSelector.selectStagesByIds(ids);
     */
    public static List<Disposition__c> selectStagesByIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<Disposition__c>();
        }
        return [
            SELECT Id, Disposition_Stage__c
            FROM Disposition__c
            WHERE Id IN :dispositionIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * The marketing clock for the Active Listing traction monitor — backs
     * `DispositionTractionService.evaluateAll` (Tranche 5 Item B, decisions D27.1 / D28).
     *
     * ── 🔴 IT SELECTS THE RAW DATE, NOT `Days_On_Market__c`, AND THAT IS THE POINT ──
     * `Disposition__c.Days_On_Market__c` is a formula carrying
     * `formulaTreatBlanksAs = BlankAsZero`, so a disposition whose `Listing_Date__c` was never set
     * reads **0**, which is indistinguishable from "listed today". Selecting the raw date is what
     * lets the service return NOT_LISTED instead of a healthy-looking day 0 — the exact failure
     * D28/Q3 calls "a clock that looks healthy and never ticks". Do not "simplify" this to the
     * formula field.
     *
     * ── WITH SYSTEM_MODE — automation-path exception, on the FLS leg only ───────
     * The read is triggered by opening a record page, but the value it produces is an assertion
     * about the DEAL ("this listing has no traction, discuss changing the broker"), not about the
     * viewer. `USER_MODE` THROWS rather than degrades, so a principal without FLS on
     * `Listing_Date__c` — measured: `DPEG_Admin_Access` grants none of these fields, and a
     * Metadata-API-deployed field arrives with no field permissions for ANY profile, System
     * Administrator included — would blank the entire traction panel rather than read a date. The
     * band would then be absent exactly where an administrator is most likely to be looking for it.
     *
     * ⚠ SHARING IS A SEPARATE DECISION AND IS DELIBERATELY LEFT USER-SCOPED. This class stays
     * `with sharing` and no `without sharing` inner class is warranted: `Disposition__c` is OWD
     * Private, and a principal who cannot SEE the disposition is not on its record page, so a
     * filtered-out row is the right answer rather than a silent corruption. Contrast
     * `DispositionOfferSelector.TractionReads`, where the sharing question genuinely does need its
     * own answer because an under-COUNT of offers manufactures a false "no traction" verdict rather
     * than an empty panel. Two reads, one feature, two different sharing conclusions — read each
     * method, never the class keyword.
     *
     * 🔴 THAT CONCLUSION IS SCOPED TO TODAY'S TWO CALLERS AND DOES NOT TRANSFER — DO NOT INHERIT IT
     * (added 2026-08-10, review W2). It rests entirely on the premise "there is a viewer, and the
     * viewer is on the record page", which holds for both live read paths
     * (`DispositionTractionController.getTraction` and `BrokerListingController.getListing`) and for
     * NOTHING ELSE. `DispositionTractionService`'s header advertises exactly one future non-record-
     * page consumer — the deferred D9 `Schedulable` that would write `Listing_Status__c` and raise
     * the month-1 alert — and in that context there is no viewer at all, so the premise is simply
     * absent rather than weakened. Under `with sharing` such a job would silently skip every
     * disposition the scheduling principal cannot see while its sibling read
     * (`DispositionOfferSelector.TractionReads`, already `without sharing`) returned counts for all
     * of them: the two halves of one computation disagreeing, with nothing to notice — the
     * "failing as silence" shape ARCHITECTURE.md §2 records for `RoutingRetrySweepBatch`.
     *
     * SO A `Schedulable` MUST RE-ARGUE SHARING BEFORE CALLING `evaluateAll`, and the shape it needs
     * is already in the repo: a `private without sharing` inner class holding ONLY that query
     * (`DispositionOfferSelector.TractionReads`, after `LeadSelector.GuestReads`), leaving this
     * outer class and this method untouched for the record-page callers. ⚠ It is deliberately NOT
     * being widened now: no such caller exists, and widening a live authorization boundary on
     * speculation is the opposite of what this programme has done everywhere else.
     *
     * Bulk-safe: ONE query for the whole set, never one per record.
     *
     * @param dispositionIds Disposition__c Ids; null/empty-safe.
     * @return Dispositions with Id and Listing_Date__c populated; empty when the input is null or
     *         empty. A row the running user cannot SEE is simply absent.
     * @example
     * List&lt;Disposition__c&gt; rows = DispositionSelector.selectListingClockByIds(ids);
     */
    public static List<Disposition__c> selectListingClockByIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<Disposition__c>();
        }
        return [
            SELECT Id, Listing_Date__c
            FROM Disposition__c
            WHERE Id IN :dispositionIds
            WITH SYSTEM_MODE
        ];
    }
}
