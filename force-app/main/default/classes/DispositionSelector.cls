/**
 * Selector for Disposition__c. Encapsulates ALL SOQL against Disposition__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live
 * in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumers:
 *   - DispositionController.findOrCreate      -> selectMostRecentByPropertyAssetId
 *   - DispositionService.initiateAndSubmit    -> selectMostRecentByPropertyAssetId (2026-08-19)
 *   - DispositionController.getClosingSummary -> selectClosingSummaryById
 *   - BovController.getOutreachSummary        -> selectOutreachById
 *   - ContractExecutionService.handleExecution -> selectStagesByIds  (Tranche 3C, 2026-08-09)
 *   - BovSubmissionTriggerHandler             -> selectStagesByIds  (redesign, 2026-08-19)
 *   - DispositionOfferTriggerHandler          -> selectStagesByIds  (redesign, 2026-08-19)
 *   - DispositionTractionService.evaluateAll  -> selectListingClockByIds (Tranche 5B, 2026-08-10)
 *   - RecordStageAdvanceService.load          -> selectStageRequiredById (redesign, 2026-08-19)
 *   - DispositionApprovalService.submitForApproval / selectOffer
 *                                             -> selectApprovalContextById (redesign, 2026-08-19)
 *   - DispositionApprovalAdvanceService.advance -> selectStageAndTypeByIds (redesign, 2026-08-19)
 *   - DispositionDealSummaryService.summarise -> selectDealSummaryParentById (Tranche 2
 *                                              Workstream C, 2026-08-20; renamed from
 *                                              selectNdaCountsById 2026-08-24 when the Property
 *                                              Asset joined the same read)
 *   - DispositionOfferFormService.getFormContext -> selectBrokerContextById (Log Offer modal,
 *                                              2026-08-21)
 *   - BovAutoSelectionService.reselectForRepricedDispositions
 *                                             -> selectIdsByPropertyAssetIds (asset-side BOV
 *                                              re-rank, 2026-08-25 — replaced the Disposition-side
 *                                              Asking_Price__c hook when that field was retired)
 *
 * ⚠ MIXED MODES SINCE 2026-08-09 (Tranche 3C) — READ THE METHOD, NEVER THIS HEADER. SIX
 * controller-backed reads are `WITH USER_MODE` (selectMostRecentByPropertyAssetId,
 * selectClosingSummaryById, selectOutreachById, selectApprovalContextById, selectDealSummaryParentById
 * and, since 2026-08-21, selectBrokerContextById);
 * FIVE are
 * `WITH SYSTEM_MODE` under the ARCHITECTURE.md §2 automation-path exception (selectStagesByIds,
 * selectListingClockByIds, selectStageRequiredById, selectStageAndTypeByIds and, since 2026-08-25,
 * selectIdsByPropertyAssetIds), each justified at
 * its own declaration — which is where §2 says the authoritative inventory lives. The sentence
 * this replaced — "There is no guest path for the Disposition module, so no SYSTEM_MODE appears
 * here" — was reasoning from the wrong test: the exception is about reads the running user never
 * asked for, not about anonymous ones.
 *
 * ⚠ AND THE TWO NEWEST SYSTEM_MODE METHODS SPLIT ON A LINE THE OLDER TWO DID NOT.
 * `selectStageAndTypeByIds` is a textbook automation read (a Queueable, post-approval, on nobody's
 * request). `selectStageRequiredById` backs a BUTTON a human clicked, and reaches SYSTEM_MODE by a
 * DIFFERENT argument — the gate and the FLS are provisioned by two different permission sets, so a
 * principal can pass the gate and fail the read. That argument is stated in full at the method and
 * is deliberately NOT generalised to the sibling stage selectors (NdaSelector / LoiSelector /
 * ContractReviewSelector all stay USER_MODE); do not "harmonise" them onto it.
 *
 * ⚠ AND THE TWO SYSTEM_MODE METHODS REACH OPPOSITE CONCLUSIONS ON SHARING FROM THE ONE THIS CLASS
 * DECLARES — both leave it user-scoped, but for different reasons, and the sibling
 * `DispositionOfferSelector` reaches the OTHER answer for the same feature. `SYSTEM_MODE` never
 * implies `without sharing`; it is always a second, separate question.
 *
 * ⚠ THE NEXT SENTENCE USED TO OPEN "MODE (the three USER_MODE reads)" AND HAS BEEN CORRECTED
 * RATHER THAN DELETED — it said THREE while the paragraph above it listed FOUR, then FIVE as of
 * 2026-08-20, and SIX as of 2026-08-21. Re-count against the method list, never against a sentence;
 * a stale count in this exact position is the defect NdaSelector's header records propagating into
 * ARCHITECTURE.md twice.
 * MODE (the six USER_MODE reads) — Disposition__c is a custom object; P3 proved the custom-field
 * FLS gap is 0, so USER_MODE is safe and enforces the running user's sharing + FLS. USER_MODE also
 * covers the Wires__r relationship subquery (Wire__c is likewise custom, FLS gap 0).
 * ⚠ THREE OF THE SIX TRAVERSE TO A SECOND OBJECT (it said TWO until 2026-08-25 — re-count
 * against the SELECT clauses, never against this sentence), WHICH ADDS AN OBJECT-LEVEL GATE NO
 * DISPOSITION PERMISSION SET GRANTS — a gate of a different KIND from the custom-FIELD one P3 measured, so
 * "the FLS gap is 0" does not cover either of them. Each is argued at its own method:
 *   - `selectBrokerContextById` traverses `Broker__r.Name` to `Contact` (granted by
 *     `DPEG_Contact_View` / `DPEG_Contact_Edit` in the same permission-set GROUPS);
 *   - `selectDealSummaryParentById` traverses `Property_Asset__r.Name` to `Property_Asset__c`
 *     (granted by `DPEG_PropertyMgmt_View`, which is in both PSGs that can open a Disposition
 *     record page) — added 2026-08-24;
 *   - `selectApprovalContextById` traverses `Property_Asset__r.Target_Sale_Price__c` to the SAME
 *     object, on the SAME grant, and for the SAME reason — added 2026-08-25 when `Asking_Price__c`
 *     was retired from the disposition flow and the Readiness price gate moved to the asset.
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
     * ⚠ `Broker__c` (the 2026-08-20 off-market Contact lookup) IS DELIBERATELY **NOT** SELECTED HERE,
     * and the reason is structural rather than an omission. This read backs
     * `BovController.getOutreachSummary` -> the `c/bovOutreach` LWC, which is the ON-MARKET beauty
     * parade: it is not placed on `Disposition_Record_Page` at all, and `BOV Outreach` is restricted
     * OUT of the `Off_Market` value set, so an off-market row can never reach this surface. The
     * `Selected_Broker__c` this returns is therefore always the FIRM string the BOV chain stamps,
     * never the `Person - Firm` string `DispositionBrokerStampService` writes off-market. Adding the
     * lookup would widen a `WITH USER_MODE` read for a value the caller cannot use, on a page no
     * off-market row visits.
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
     * The parent-level fields the Deal Summary card needs — the two maintained NDA counters, and
     * the Property Asset this sale is about — for ONE Disposition. Backs
     * `DispositionDealSummaryService` -> `c/dispositionDealSummary`. Added 2026-08-20, Tranche 2
     * Workstream C (design D5).
     *
     * ⚠ RENAMED FROM `selectNdaCountsById` ON 2026-08-24, WHEN THE PROPERTY ASSET WAS ADDED. The
     * old name would now be a lie — a method called "NDA counts" returning a Property Asset is
     * exactly the kind of name a later reader trusts instead of reading. One production caller
     * moved with it.
     *
     * ⚠ THIS METHOD IS NOT IN THE D5 DELIVERABLE LIST AND WAS ADDED DELIBERATELY. D5 names the
     * counters as card content and names only three selectors to edit, none of which owns
     * `Disposition__c`. The alternatives were both worse: SOQL in the service or the controller
     * violates `.claude/rules/apex-layering-rule.md` outright, and a `getRecord` wire for these
     * fields alone would give one card two data sources with two independent refresh clocks and
     * two different failure shapes (D5 itself floats that hybrid only as "an alternative if the
     * user prefers LDS", while directing that the Apex version ship). One selector method is the
     * smallest correct answer.
     *
     * 🔴 BOTH COUNTERS ARE `DERIVED - DO NOT HAND-EDIT` AND ARE NULL, NOT ZERO, ON PRE-EXISTING
     * ROWS. They are maintained by the `NDA_Signed_Rollup` AFTER-SAVE FLOW — not a roll-up summary
     * (every child->Disposition relationship on this object is a Lookup, so no roll-up is possible)
     * and not Apex. A Disposition that existed before that flow, or that has never had an NDA,
     * holds null in both. Every existing reader wraps them in `BLANKVALUE(...,0)`; this method
     * returns them RAW and the coalescing happens once, in the client
     * (`dispositionDealSummary.js`), so that the Apex DTO cannot quietly report a real null as a
     * confident "0 of 0". Do not "helpfully" coalesce here as well.
     *
     * ── 🔴 `Property_Asset__r.Name` IS A TRAVERSAL, AND IT COSTS A SECOND OBJECT'S CRUD GATE ──
     * Added 2026-08-24 so the card can link the sale's Property Asset. It is deliberately part of
     * THIS query rather than a new one: `Disposition__c` is already being read here, and a second
     * `LIMIT 1` read of the same row to fetch two more fields would add a query to a card that has
     * a standing four-query budget test (`dispositionQueryCost_manyChildrenAcrossAllThreeObjects_
     * stillFourQueries`).
     *
     * ⚠ AND THE COST IS REAL, SO IT IS STATED RATHER THAN DISCOVERED. `Property_Asset__c.Name` has
     * no `FieldPermissions` row (a custom object's Name field is not FLS-gated), but the traversal
     * still requires CRUD Read on `Property_Asset__c` itself — a gate NO disposition permission set
     * grants. It arrives from `DPEG_PropertyMgmt_View`, which is in BOTH PSGs that can open a
     * Disposition record page (`DPEG_Principal_PSG`, `DPEG_Junior_Analyst_PSG` — verified against
     * the permission-set files 2026-08-24). This is the same KIND of gate `selectBrokerContextById`
     * documents for its `Broker__r.Name` -> Contact traversal, and it is NOT covered by "the
     * custom-FIELD FLS gap is 0" that the class header's USER_MODE argument rests on.
     *
     * 🔴 THE CONSEQUENCE OF THAT GATE FAILING IS SHARED WITH THE NDA COUNTERS, BY CONSTRUCTION.
     * One query means one exception: a persona without Property Asset Read makes this whole read
     * throw, and the caller's single catch flags `ndaCountsUnavailable`. So the NDA row would
     * report "NDA counts unavailable" for a Property Asset provisioning gap. That OVER-reports —
     * it never hides a gap, which is the failure mode design §0 C-1 was written about — and the
     * remedy is the same permission-set fix either way. It is recorded here, and at the caller, so
     * nobody debugs the counter flow for a Property Asset problem.
     *
     * READ-FOR-DISPLAY, null on miss — and that is a DEPARTURE from the two fetch-for-use reads
     * above it (`selectClosingSummaryById` / `selectOutreachById`), which throw. Those back cards
     * whose entire content is the Disposition. This one backs ONE ROW of a card that must survive
     * on all 11 stages, and its caller fails soft per row; returning null lets a vanished or
     * unreadable parent degrade one line instead of raising an exception the caller would only
     * swallow anyway.
     *
     * ── FLS: `WITH USER_MODE` — a read the user asked for by opening the record page ──
     * ARCHITECTURE.md §2's automation-path exception does not apply. All three Disposition fields
     * are granted in `DPEG_Disposition_View` and `DPEG_Disposition_Edit` (the two counters verified
     * 2026-08-20, `Property_Asset__c` verified 2026-08-24); a PermissionSet deploy REPLACES its
     * whole `<fieldPermissions>` set, so the caller's narrow fail-soft catch stands behind the
     * grant rather than instead of it.
     *
     * @param dispositionId Disposition__c Id to read; null-safe.
     * @return The Disposition__c with Id, NDA_Count__c, Signed_NDA_Count__c, Property_Asset__c and
     *         Property_Asset__r.Name populated — any of them may be null — or null when the input
     *         is null or the row is not visible.
     * @example
     * Disposition__c d = DispositionSelector.selectDealSummaryParentById(dispositionId);
     */
    public static Disposition__c selectDealSummaryParentById(Id dispositionId) {
        if (dispositionId == null) {
            return null;
        }
        List<Disposition__c> rows = [
            SELECT Id, NDA_Count__c, Signed_NDA_Count__c,
                   Property_Asset__c, Property_Asset__r.Name
            FROM Disposition__c
            WHERE Id = :dispositionId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Current stage for a set of Dispositions — backs ContractExecutionService.handleExecution's
     * disposition arm (Tranche 3C, 2026-08-09), which moves a sale to `Closing` when its PSA is
     * executed.
     *
     * ⚠ TWO MORE CONSUMERS SINCE 2026-08-19, AND THEY WANT IT FOR EXACTLY THE SAME REASON.
     * `BovSubmissionTriggerHandler` and `DispositionOfferTriggerHandler` each move the PARENT
     * disposition on a child-approval outcome, and each does so ONLY IF the parent is still on the
     * expected stage — the idempotency guard that makes a re-approval, or a broker replaced AFTER
     * the stage already advanced, a no-op instead of a backwards jump. That guard is this method's
     * read. Every consumer is therefore an after-update trigger on a DIFFERENT object, which is
     * what keeps the SYSTEM_MODE argument below intact rather than merely inherited.
     *
     * 🔴 IT EXISTS TO SUPPORT A NO-CHANGE CHECK, WHICH IS THE POINT AND NOT AN OPTIMISATION.
     * `Disposition__c` is the entry object of THREE approval processes (Sale_Decision at
     * Disposition Readiness, Broker_Selection at `Broker Selection` + Off_Market since the
     * 2026-08-19 flow redesign — it keyed on `BOV Outreach` before that — and Closing_Approval at
     * Closing + `Wire_Verification_Completed__c = true`), all
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

    /**
     * Stage + record type for ONE Disposition — backs `RecordStageAdvanceService.load`, which
     * registered `Disposition__c` in the 2026-08-19 flow redesign (design D-2 / DEV-7).
     *
     * FETCH-FOR-USE: `RecordStageAdvanceService` expects every `load()` branch to throw on a miss
     * (its own header records that contract), so this is a single-row assignment and NOT a
     * null-returning list read.
     *
     * ── 🔴 RecordTypeId IS NOT OPTIONAL — "DO NOT NARROW" ────────────────────
     * `Disposition__c` carries `On_Market` / `Off_Market`, and the redesign gives them DIFFERENT
     * manual-hop sequences (On_Market walks `Broker Selection -> NDA -> Release Materials ->
     * Active Listing` and `LOI -> PSA`; Off_Market walks only `NDA -> Release Materials` and
     * `LOI -> PSA`). Dropping this field does NOT fail loudly: `RecordStageAdvanceService` reads it
     * through `getPopulatedFieldsAsMap()`, which cannot tell "not selected" from "selected and
     * null", so both degrade to `defaultTypeKey` — here `On_Market` — and every OFF-market
     * disposition would silently offer `Broker Selection -> NDA` and `Release Materials ->
     * Active Listing`, two hops that belong to the approval and to Select Offer respectively. Same
     * contract NdaSelector (3A), LoiSelector (3B) and ContractReviewSelector (3C) carry.
     *
     * ── 🔴 WITH SYSTEM_MODE — AND NOT BY THE USUAL ARGUMENT. READ THIS BEFORE COPYING IT. ──
     * The three sibling `selectStageRequiredById` methods (NDA / LOI / Contract Review) are all
     * `WITH USER_MODE`, because a stage-advance read is a read the running user ASKED for by
     * clicking a button — ARCHITECTURE.md §2's primary rule, and the right answer on those objects.
     * This one is not, for a reason specific to how the DISPOSITION gate is provisioned:
     *
     *   🔴 THE ORIGINAL ARGUMENT HERE DIED ON 2026-08-19 AND IS QUOTED, NOT DELETED, BECAUSE THE
     *   CONCLUSION SURVIVED IT ON A DIFFERENT PRINCIPAL — a reader who checks only the quoted
     *   premise would correctly find it false and wrongly conclude the mode should flip:
     *     *"The gate is the `Disposition_Deal_Actions` CUSTOM PERMISSION, carried by the layer-5
     *     `Disposition_Deal_Driver` authorization set. FLS on `Disposition_Stage__c` is carried by
     *     the layer-4 `DPEG_Disposition_View` / `DPEG_Disposition_Edit` capability sets. THOSE ARE
     *     DIFFERENT SETS AND NEITHER IMPLIES THE OTHER, so a principal can hold the gate and not
     *     the field."*
     *   The user retired `Disposition_Deal_Driver` that day and moved the custom permission onto
     *   `DPEG_Disposition_Edit` — the very set that carries read+edit FLS on `Disposition_Stage__c`.
     *   For that principal the two now travel together and the divergence is gone.
     *
     *   ⚠ IT IS NOT GONE FOR THE OTHER PRINCIPAL, AND THAT ONE IS NOT HYPOTHETICAL.
     *   `DispositionActionPermissionService` passes anyone with "Modify All Data" WITHOUT the custom
     *   permission (the deliberate admin bypass). "Modify All Data" is an OBJECT permission and
     *   confers NO FLS, and a Metadata-API-deployed custom field arrives with no field permissions
     *   for any profile, System Administrator included — `Disposition_Stage__c`'s FLS lives only in
     *   the two `DPEG_Disposition_*` sets. So a System Administrator holding no disposition persona
     *   set passes the gate and cannot read the field. `USER_MODE` THROWS rather than degrades, so
     *   that user's Advance click dies with
     *   `System.QueryException: No such column 'Disposition_Stage__c' on entity 'Disposition__c'`
     *   — an FLS denial wearing a schema error — which the controller then masks as "this change
     *   could not be saved", naming nothing. The gate said yes and the read said no.
     *
     *   ⚠ SO THE MODE IS UNCHANGED, BUT ITS MARGIN IS NARROWER THAN IT WAS. It now rests on ONE
     *   principal (the bypassed admin) instead of a structural disjointness between two sets. Do not
     *   flip this to `USER_MODE` as a tidy-up on the strength of the retired premise; if the admin
     *   bypass is ever removed from `DispositionActionPermissionService`, re-open this decision
     *   deliberately rather than discovering it here.
     *
     * ⚠ THE HONEST COUNTER-STATEMENT: this IS a widening relative to the three siblings, and the
     * control that replaces FLS here is the custom-permission gate plus the validation rules — the
     * SAME residual `RecordStageAdvanceService.setStage` already documents for its plain `update`
     * (a driver without FLS edit on the stage field can drive the button). The widening is kept
     * minimal by the three-field SELECT: nothing on this row but its Id, its stage and its record
     * type crosses the boundary.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE. `SYSTEM_MODE` lifts CRUD and
     * FLS, never sharing, and this class stays `with sharing`. `Disposition__c` is OWD Private, so
     * a caller who cannot SEE the row gets a `System.QueryException` from this fetch-for-use read —
     * a refusal, not a wrong answer, which is the correct direction for a write-driving read.
     *
     * @param dispositionId Disposition__c Id; must reference an existing, visible row.
     * @return The Disposition with Id, Disposition_Stage__c and RecordTypeId populated.
     * @throws System.QueryException when no visible Disposition__c matches the Id.
     * @example
     * Disposition__c d = DispositionSelector.selectStageRequiredById(dispositionId);
     */
    public static Disposition__c selectStageRequiredById(Id dispositionId) {
        return [
            SELECT Id, Disposition_Stage__c, RecordTypeId
            FROM Disposition__c
            WHERE Id = :dispositionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    /**
     * Stage + record type for a SET of Dispositions — backs
     * `DispositionApprovalAdvanceService.advance`, the semaphore-driven auto-advance the THREE
     * Disposition-target approvals hand off to (design D-1).
     *
     * ⚠ THIS SAID "four" UNTIL 2026-08-19 AND IT WAS WRONG (code review W-5). There are exactly
     * THREE approvals whose target is a `Disposition__c`: `Sale_Decision_Approval`,
     * `Broker_Selection_Approval` and `Closing_Approval`. The redesign's other two —
     * `Broker_Finalize_Approval` and `Offer_Selection_Approval` — target CHILD records
     * (`BOV_Submission__c` and `Disposition_Offer__c`), never set a Disposition semaphore, and
     * update the parent SYNCHRONOUSLY from their own trigger handlers. The miscount almost
     * certainly came from `ADVANCE_TARGET`, which has FIVE entries because it is keyed on
     * `recordType|stage` and two approvals contribute two rows each — entry count is not approval
     * count. 🔴 THE NUMBER IS LOAD-BEARING: "which approvals can lock a Disposition" is the premise
     * four other files reason from, notably `DispositionOfferTriggerHandler`'s argument that no
     * Disposition approval can be pending at `Offer Selection`.
     *
     * 🔴 WITH SYSTEM_MODE — THE TEXTBOOK AUTOMATION PATH, AND THE FAILURE IT PREVENTS IS SILENT.
     * This read happens inside a `Queueable` enqueued by an after-update trigger, running as
     * WHOEVER APPROVED the record. A principal approver is, by design, a read-only persona on
     * `Disposition__c` — approving is not the same grant as reading the object's fields — and
     * `USER_MODE` THROWS rather than degrades. The `QueryException` would fail the AsyncApexJob,
     * the stage would never move, and `Approval_Advance_Pending__c` would stay `true` with nothing
     * on screen to say why: the approval would look complete and the sale would sit still.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS LEFT USER-SCOPED, EXACTLY AS `selectStagesByIds`
     * LEAVES IT. This class stays `with sharing`. A row the approver cannot SEE is simply ABSENT
     * from the result, and because the caller drives its write from what came BACK — never from
     * what went in — an absent row is SKIPPED rather than written wrongly. That skip leaves the
     * semaphore `true`, which is the same visible, admin-recoverable residual the caller documents
     * for every other refusal. Wrong direction would be writing a stage for a row we could not
     * read; that is not reachable from here.
     *
     * Bulk-safe: ONE query for the whole set, never one per record.
     *
     * @param dispositionIds Disposition__c Ids; null/empty-safe.
     * @return Dispositions with Id, Disposition_Stage__c and RecordTypeId populated; empty when
     *         the input is null or empty. A row the running user cannot SEE is simply absent.
     * @example
     * List&lt;Disposition__c&gt; rows = DispositionSelector.selectStageAndTypeByIds(ids);
     */
    public static List<Disposition__c> selectStageAndTypeByIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<Disposition__c>();
        }
        return [
            SELECT Id, Disposition_Stage__c, RecordTypeId
            FROM Disposition__c
            WHERE Id IN :dispositionIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * Everything `DispositionApprovalService` needs to decide WHICH approval a Submit click means
     * and whether it may proceed — backs both `submitForApproval` and `selectOffer`
     * (2026-08-19 flow redesign, DEV-2).
     *
     * The five fields are exactly the inputs to that decision and nothing else:
     *   `Disposition_Stage__c`            which of the four submit branches applies;
     *   `RecordTypeId`                    On_Market vs Off_Market, which splits two of them;
     *   `Broker__c`                       the Off-market `Broker Selection` pre-check;
     *   `Wire_Verification_Completed__c`  the `Closing` pre-check;
     *   `Selected_Broker__c`              DISPLAY-ONLY CARRY. No longer read by any gate.
     *   `Property_Asset__r.Target_Sale_Price__c`  the `Disposition Readiness` price pre-check
     *                                     (2026-08-25 — it replaced `Asking_Price__c`, which is
     *                                      retired from this flow; see the FLS note below, the
     *                                      span is a DIFFERENT KIND of gate from a plain field).
     *
     * ⚠ THE THIRD AND FIFTH ROWS SWAPPED ROLES ON 2026-08-20 (off-market broker lookup) AND THE OLD
     * ROLE MUST NOT BE RESTORED. `Selected_Broker__c` (Text) WAS the off-market pre-check —
     * `String.isBlank(...)` — and is now the denormalised display string that
     * `DispositionBrokerStampService` derives FROM `Broker__c`. Re-pointing the gate at it, or
     * adding it back as an `||` fallback, would make the gate UNFAILABLE: the stamp service writes
     * that field on every off-market pick, so the fallback would be satisfied by the feature's own
     * output. It is kept in the SELECT only because it is still displayed downstream and removing it
     * is out of scope — nothing in `DispositionApprovalService` reads it any more.
     *
     * 🔴 THE PRE-CHECK FIELDS EXIST TO REPLACE A PLATFORM ERROR WITH AN AUTHORED ONE.
     * `Closing_Approval` gained `Wire_Verification_Completed__c = true` as an ENTRY CRITERION in this
     * redesign, and an unmet entry criterion surfaces as the platform's "no applicable approval
     * process was found" — true, useless, and indistinguishable from a misconfigured org. Reading the
     * flag first is what lets the service say "wire verification must be complete before the closing
     * approval can be submitted". Deleting either PRE-CHECK field from this SELECT does not break the
     * submit; it silently restores the opaque error. **That warning now attaches to `Broker__c` too.**
     *
     * ── WITH USER_MODE, AND HERE THAT IS THE RIGHT ANSWER RATHER THAN THE DEFAULT ──
     * Unlike `selectStageRequiredById` above, this read has NO automation consumer: it happens
     * because a human clicked Submit for Approval, in a synchronous request, and every value it
     * returns is used to author a message shown to that same human. ARCHITECTURE.md §2's primary
     * rule applies unmodified — a throw here reports a real provisioning gap and the fix is a
     * permission set.
     *
     * ⚠ AND THE FLS IS SAFE BY CONSTRUCTION FOR `Wire_Verification_Completed__c`. The
     * `Submit_Closing_Approval` quick action's own Dynamic Actions visibility rule reads
     * `Wire_Verification_Completed__c`, and a visibility rule on an unreadable field evaluates
     * FALSE and hides the button — so a user who can SEE the button can read the field, and a user
     * who cannot read the field never reaches this method. The declarative gate and this read fail
     * in the same direction, which is what makes USER_MODE non-hazardous for THAT field.
     *
     * 🔴 THAT ARGUMENT DOES **NOT** EXTEND TO `Broker__c`, AND ASSUMING IT DOES IS THE MISTAKE THIS
     * PARAGRAPH EXISTS TO PREVENT (added 2026-08-20). `Broker__c` has NO Dynamic Actions gate keyed
     * on it: `Submit_Broker_Selection`'s visibility rule keys on the STAGE, so an unreadable
     * `Broker__c` hides nothing and every user reaches this method anyway. `Broker__c` is also a
     * BRAND-NEW Metadata-API-deployed field, which arrives with NO FLS for ANY profile, System
     * Administrator included. Until `DPEG_Disposition_Edit` (editable) and `DPEG_Disposition_View`
     * (readable) grant it, this query raises `System.QueryException: No such column 'Broker__c' on
     * entity 'Disposition__c'` — an FLS denial wearing a schema error — for EVERY user.
     *
     * 🔴 AND BECAUSE THIS ONE METHOD BACKS ALL FOUR APPROVAL BRANCHES, THAT BREAKS **SUBMIT FOR
     * APPROVAL ON EVERY DISPOSITION, AT EVERY STAGE, ON BOTH RECORD TYPES** — not just the
     * off-market broker step. The controller masks it as a generic save failure that names nothing,
     * so the symptom will not point here.
     *
     * 🔴 **WHOEVER HITS THAT WILL REACH FOR `WITH SYSTEM_MODE`. THAT IS THE WRONG TURN AND IT IS
     * BANNED HERE BY THE PARAGRAPH ABOVE.** The mode is not the defect; the missing grant is. **The
     * fix is the permission set, every time.** Flipping this read would ALSO silently re-authorise
     * the other four fields for principals the org deliberately withholds them from, to fix a
     * provisioning gap that a two-line permission-set edit closes properly. Deploy order is
     * load-bearing: field -> permission sets -> this Apex, and NEVER Apex first.
     *
     * ⚠ `Asking_Price__c` JOINED THIS LIST 2026-08-22 AND **LEFT IT AGAIN 2026-08-25** — the note
     * is amended in place rather than deleted, because the paragraph it was making is still the
     * live one, just about a different column. `Asking_Price__c` ("Expected Value") is RETIRED
     * from the disposition flow (user decision, 2026-08-25; the field is NOT deleted, it is simply
     * no longer read here), and the Disposition-Readiness price gate now reads the PROPERTY
     * ASSET's own `Target_Sale_Price__c` through `Property_Asset__r`.
     *
     * 🔴 THAT SWAPPED A FIELD-LEVEL GATE FOR A **CROSS-OBJECT** ONE, WHICH IS A DIFFERENT KIND OF
     * GATE, AND IT WAS CHECKED RATHER THAN ASSUMED. Under `WITH USER_MODE` this span now requires
     * (a) read on `Property_Asset__c` itself and (b) FLS read on `Target_Sale_Price__c`, NEITHER of
     * which any `DPEG_Disposition_*` permission set grants. Measured against this repo on
     * 2026-08-25: both are granted by `DPEG_PropertyMgmt_View`, which is a member of BOTH permission
     * set groups that can open a Disposition record page (`DPEG_Junior_Analyst_PSG` and
     * `DPEG_Principal_PSG`) — the identical argument `selectDealSummaryParentById` below already
     * makes for its own `Property_Asset__r.Name` traversal, and this method is now the SECOND
     * disposition read to depend on it. `Target_Sale_Price__c` is also granted by
     * `DPEG_PropertyAsset_View` and `DPEG_PropertyMgmt_Edit`.
     *
     * 🔴 THE SAME BAN APPLIES, AND IT MATTERS MORE NOW THAN IT DID FOR `Asking_Price__c`. If this
     * ever throws `No such column 'Target_Sale_Price__c'` — or the object-level equivalent — the
     * fix is to put `DPEG_PropertyMgmt_View` on the principal, NEVER `WITH SYSTEM_MODE` here. This
     * one method backs ALL FOUR approval branches, so flipping it to fix a provisioning gap would
     * re-authorise five other fields for principals the org deliberately withholds them from.
     * ⚠ A principal assigned a bare `DPEG_Disposition_Edit` WITHOUT the PSG around it has no route
     * to this column. That is a real, named residual: assignment in this org is by PSG, and both
     * PSGs carry it, but a hand-assigned standalone permission set would break Submit for Approval
     * at every stage. Assign the group, not the set.
     *
     * FETCH-FOR-USE: a miss is an error (the caller was handed an Id by a record page), so this is
     * a single-row assignment that throws.
     *
     * @param dispositionId Disposition__c Id; must reference an existing, visible row.
     * @return The Disposition with the decision/display fields populated, including the parent
     *         asset's `Target_Sale_Price__c` through `Property_Asset__r` (may itself be null —
     *         a Disposition need not have an asset, and an asset need not carry a target).
     * @throws System.QueryException when no visible Disposition__c matches the Id, OR when the
     *         running user lacks FLS read on any selected field — see the Broker__c note above.
     * @example
     * Disposition__c d = DispositionSelector.selectApprovalContextById(dispositionId);
     */
    public static Disposition__c selectApprovalContextById(Id dispositionId) {
        return [
            SELECT Id, Disposition_Stage__c, RecordTypeId,
                   Broker__c, Selected_Broker__c, Wire_Verification_Completed__c,
                   Property_Asset__r.Target_Sale_Price__c
            FROM Disposition__c
            WHERE Id = :dispositionId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * THE THREE FACTS THE LOG OFFER DIALOG NEEDS ABOUT THE PARENT SALE: which record type it is, and
     * — on the off-market path — which broker Contact was picked, with a name to display. Backs
     * `DispositionOfferFormService.getFormContext` -> `c/dispositionLogOfferModal` (2026-08-21).
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 IT IS A THIRD READ RATHER THAN A REUSE OF `selectApprovalContextById` ABOVE, AND THE REASON
     *    IS THAT METHOD'S OWN HEADER.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * That method carries `Wire_Verification_Completed__c` and `Selected_Broker__c`, neither of which
     * this caller uses, and under `WITH USER_MODE` every selected field is an FLS gate — so reusing
     * it would give the Log Offer dialog two extra ways to fail for a value it never reads. It also
     * FETCHES FOR USE (a single-row assignment that THROWS on miss), which is right for a Submit
     * click handed an Id by a record page and wrong here: this read is one of three the dialog makes,
     * and the dialog degrades rather than refuses. Narrower field list, softer not-found contract,
     * so a separate method — the same per-caller split `NdaSelector` makes between
     * `selectLatestByDispositionId` and `selectLatestSummaryByDispositionId`.
     * ⚠ Do NOT "de-duplicate" the two later. The overlap is two columns; the coupling it prevents is
     * Submit For Approval on every disposition, at every stage, on both record types.
     *
     * ── 🔴 `Selected_Broker__c` IS DELIBERATELY **NOT** SELECTED, AND THIS IS A STANDING RULE ───
     * `DispositionBrokerStampService`'s header: *"**NO CONSUMER MAY PARSE `Selected_Broker__c`.** It
     * is a display string only."* It reads `Firm` on on-market rows and `Person - Firm` on off-market
     * ones, so a parser works on whichever path its author tested and fails silently on the other. It
     * would be the obvious shortcut here — one field, both paths, no BOV query — and it is exactly
     * the wrong turn. Not selecting it at all is what makes taking that shortcut impossible without
     * editing this query first.
     *
     * ── WHY `RecordTypeId` AND NOT `Is_On_Market__c` ───────────────────────────────────────────
     * The caller resolves it through `DispositionDomain.recordTypeNameOf`, the ONE shared helper
     * whose null/Master fallback answers `On_Market` — the same helper `DispositionApprovalService`
     * and `DispositionApprovalAdvanceService` use, and whose existence is recorded there as the fix
     * for two copies of this test disagreeing. `RecordTypeId` is also a standard system field on
     * which field-level security cannot be configured, so it adds NO FLS surface.
     * ⚠ `DispositionBrokerStampService` argues AGAINST an `Is_On_Market__c` test for a different but
     * compatible reason (it would be a second, drifting copy of a FlexiPage visibility rule). Both
     * arguments land on the same answer; neither is a reason to introduce that field here.
     *
     * ── FLS: `WITH USER_MODE`, AND ONE OF THE TWO GATES IS AN OBJECT, NOT A FIELD ──────────────
     * A human opened the dialog. `SYSTEM_MODE` would be wrong (ARCHITECTURE.md §2) — no trigger to
     * roll back, no batch to disable. `Disposition__c.Broker__c` is granted read on BOTH
     * `DPEG_Disposition_View` and `DPEG_Disposition_Edit`, MEASURED in the org via `FieldPermissions`
     * on 2026-08-21 rather than read off the permission-set XML.
     * 🔴 `Broker__r.Name` traverses to `Contact` and `USER_MODE` enforces OBJECT-level read on the
     * related object; that grant is in `DPEG_Contact_View` / `DPEG_Contact_Edit`, separate members of
     * the same permission-set GROUPS. The name is selected rather than resolved by a second Contact
     * query because the modal DISPLAYS it read-only, and a broker Id with no name beside it is an
     * unreadable field. The caller wraps this in a NARROW fail-soft try/catch for exactly this
     * reason; the grant and the catch are BOTH required and neither substitutes for the other.
     *
     * READ-FOR-DISPLAY, null on miss. A missing row means the dialog was opened on an Id the running
     * user cannot see, which the caller renders as "no broker resolved" rather than as an exception —
     * the offer itself is still creatable, and §A.3 of the design records a null broker as an
     * ACCEPTED state for an offer logged before the broker is appointed.
     *
     * @param dispositionId Disposition__c Id; null-safe.
     * @return The Disposition with Id, RecordTypeId, Broker__c and Broker__r.Name populated, or NULL
     *         when the input is null or no visible row matches.
     * @throws System.QueryException when the running user lacks read on `Disposition__c.Broker__c` or
     *         on `Contact`. The caller catches it narrowly and degrades to "no broker resolved".
     * @example
     * Disposition__c d = DispositionSelector.selectBrokerContextById(dispositionId);
     */
    public static Disposition__c selectBrokerContextById(Id dispositionId) {
        if (dispositionId == null) {
            return null;
        }
        List<Disposition__c> rows = [
            SELECT Id, RecordTypeId, Broker__c, Broker__r.Name
            FROM Disposition__c
            WHERE Id = :dispositionId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * EVERY DISPOSITION HANGING OFF A SET OF PROPERTY ASSETS — Ids only. Backs
     * `BovAutoSelectionService.reselectForRepricedDispositions`, the asset-side re-ranking hook
     * added 2026-08-25 when `Asking_Price__c` was retired and `BOV_Score__c`'s value basis moved
     * to `Property_Asset__c.Target_Sale_Price__c`.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 MODE — `WITH SYSTEM_MODE`, UNDER ARCHITECTURE.md §2's AUTOMATION-PATH EXCEPTION,
     *    JUSTIFIED HERE AT THE DECLARATION AS §2 REQUIRES.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * This read happens ON A PRINCIPAL'S BEHALF, never at their request: it runs inside
     * `PropertyAssetTriggerHandler.afterUpdate` because somebody typed a Target Sale Price on a
     * PROPERTY ASSET. That person is a Property Management user; they may hold no Disposition
     * access whatsoever, and they are not asking to see dispositions. Under `WITH USER_MODE` an
     * FLS or CRUD gap does NOT degrade to an empty list — it throws
     * `System.QueryException: No such column`, which inside a trigger escapes as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the PM user's own save. Repricing an
     * asset would fail with a schema error naming an object they never touched.
     *
     * 🔴 AND `SYSTEM_MODE` DOES NOT LIFT SHARING — THAT IS A SEPARATE QUESTION AND IT IS ANSWERED
     * "LEAVE IT" HERE, DELIBERATELY. `Disposition__c` is OWD Private, so a PM user who owns no
     * disposition sees an EMPTY list from this query and the re-rank silently does nothing. That is
     * accepted, and it is accepted because of what the caller does with the result: it re-ranks
     * children whose SCORES ALREADY CHANGED THE INSTANT THE FORMULA'S INPUT DID. A missed re-rank
     * leaves the appointment stale until the next BOV edit; it does not corrupt anything and it
     * does not double anything. This is NOT the idempotency-guard case where a sharing-filtered
     * read inverts the feature into a duplicate-maker — there is no insert on this path, only an
     * update of an exclusive flag that is recomputed from scratch every time.
     * ⚠ IF THAT EVER STOPS BEING ACCEPTABLE the fix is a narrow `private without sharing` inner
     * class holding ONLY this query, argued on its own — not `without sharing` on this selector.
     *
     * ⚠ ID-ONLY BY DESIGN. The caller feeds the result straight back into
     * `BovSubmissionSelector.selectSelectionContextByDispositionIds`, which reads everything the
     * ranking needs off the CHILDREN. Adding a field here would buy nothing and widen a query that
     * runs on every Property Asset save that touches the target price.
     *
     * BULK: one query for the whole chunk. Never call this inside a loop.
     *
     * @param propertyAssetIds Property_Asset__c Ids. Null/empty-safe.
     * @return The Dispositions under those assets, Id only; an empty list when the input is
     *         null/empty or no row is shared with the running user.
     * @example
     * List&lt;Disposition__c&gt; rows = DispositionSelector.selectIdsByPropertyAssetIds(assetIds);
     */
    public static List<Disposition__c> selectIdsByPropertyAssetIds(Set<Id> propertyAssetIds) {
        if (propertyAssetIds == null || propertyAssetIds.isEmpty()) {
            return new List<Disposition__c>();
        }
        return [
            SELECT Id
            FROM Disposition__c
            WHERE Property_Asset__c IN :propertyAssetIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * ONE Disposition's `DISP-{0000}` number and nothing else. Backs
     * `DispositionApprovalHistoryService.getHistory`, which labels the rows of the consolidated
     * Approval History card — three of the five disposition approvals target the Disposition
     * ITSELF, and their row needs the same "which record is this?" label the BOV and offer rows get.
     * Added 2026-08-26.
     *
     * ⚠ IT IS THE NARROWEST READ IN THIS CLASS ON PURPOSE, AND IT IS NOT A REUSE OF ANY OF THE
     * SEVEN `…ById` METHODS ABOVE. Under `WITH USER_MODE` every selected field is an FLS gate, and
     * this caller renders on EVERY disposition at EVERY stage with no FlexiPage visibility rule —
     * so it is the read most exposed to a missing grant, and it selects exactly one field, the
     * AutoNumber the platform always exposes. Reusing `selectApprovalContextById` (five fields,
     * including a `Property_Asset__r` traversal) would import five failure modes for a value this
     * caller does not read. Same per-caller split this class already makes between
     * `selectApprovalContextById` and `selectBrokerContextById`.
     *
     * ── NOT-FOUND CONTRACT: read-for-display, so a LIST ────────────────────────────────────────
     * ⚠ IT RETURNS `List<Disposition__c>`, NOT `Disposition__c`, EVEN THOUGH IT READS ONE RECORD.
     * The four singular methods above FETCH FOR USE and throw `QueryException` on a miss, which is
     * right for a Submit handler that cannot proceed. This one feeds a read-only card: a
     * sharing-filtered miss must degrade to "no label for that row", not take down a card whose
     * BOV and offer rows are still perfectly readable. Same shape as
     * `ProcessInstanceSelector.selectPendingByTargetId`.
     *
     * @param dispositionId The Disposition to label; null-safe.
     * @return A single-element list carrying Id + Name, or an empty list when the input is null or
     *         the record is not visible. Never null.
     * @example
     * List&lt;Disposition__c&gt; rows = DispositionSelector.selectNameById(dispositionId);
     */
    public static List<Disposition__c> selectNameById(Id dispositionId) {
        if (dispositionId == null) {
            return new List<Disposition__c>();
        }
        return [
            SELECT Id, Name
            FROM Disposition__c
            WHERE Id = :dispositionId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
