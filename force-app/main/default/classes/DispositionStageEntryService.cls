/**
 * Creates a Disposition's stage-entry child records — the disposition twin of
 * OpportunityReviewService, and deliberately shaped after it rather than invented fresh
 * (decisions D15/Q3, D16.2, D19.1).
 *
 * IT DOES FIVE THINGS, ONE PER STAGE, AND THE FIVE ARE NOT INTERCHANGEABLE:
 *
 *   | stage entered       | what happens                          | added  | DML mode    | parent stamp |
 *   | ------------------- | ------------------------------------- | ------ | ----------- | ------------ |
 *   | `NDA`               | OPENS NDA__c, Party_Role__c = 'Buyer',| 3A     | SYSTEM_MODE | DEFERRED     |
 *   |                     |   Broker__c resolved per record type  | +bkr   |             |              |
 *   | `LOI`               | OPENS LOI__c, Disposition_LOI,        | 3B fix | SYSTEM_MODE | DEFERRED     |
 *   |                     |   Selected_Offer__c stamped on child  | +offer |             |              |
 *   | `PSA`               | OPENS Contract_Review__c, Disp_PSA,   | 3C fix | SYSTEM_MODE | DEFERRED     |
 *   |                     |   Selected_Offer__c stamped on child  | +offer |             |              |
 *   | `Release Materials` | UPDATES existing buyer NDAs           | T2-D   | SYSTEM_MODE | NONE         |
 *   | `Active Listing`    | OPENS Broker_Listing__c               | 5B     | SYSTEM_MODE | BEFORE-SAVE  |
 *
 * 🔴 THE `Release Materials` ROW IS THE ODD ONE OUT AND ITS "what happens" CELL IS WHY THIS TABLE'S
 * HEADING CHANGED FROM "child opened" ON 2026-08-20. It CREATES NOTHING — it fills a blank field on
 * children that already exist (`Materials_Released_Date__c`, the buyer activity timeline's middle
 * hop). Its idempotency question is "is the field blank?", not "does the child exist?", and it is
 * the only block whose absence produces a wrong TIMELINE rather than a missing RECORD. Do not fold
 * it into the `open*` family.
 *
 * 🔴 THE LAST TWO COLUMNS ARE THE PART A READER MUST NOT SKIM. All five blocks use SYSTEM_MODE
 * DML, but they reach that answer by SEVERAL different routes and they handle the parent write three
 * different ways. THREE blocks now defer a parent stamp to a Queueable (NDA, LOI, PSA); the Release
 * Materials block has nothing to defer; and the Active Listing block writes its parent field IN A
 * BEFORE-SAVE CONTEXT, which is neither of the other two answers. Each block's reasoning is argued at the
 * block, from scratch, because inheriting a justification is precisely the mistake review W1
 * caught in DispositionNdaStampQueueable (which had copied OpportunityReviewService's LOI-block
 * wording verbatim into a case where it did not hold).
 *
 * ⚠ THAT SENTENCE SAID "Only the NDA block defers a parent stamp to a Queueable; the LOI, PSA and
 * Release Materials blocks have nothing to defer" UNTIL 2026-08-25, and this file argued from that
 * premise in FOUR places. It died when `Disposition__c.Primary_LOI__c` and `Primary_PSA__c` were
 * added so the record page's LOI/PSA Details sections could be NATIVE fieldSections spanning
 * formula fields (replacing an Apex-backed LWC). Every place that reasoned from it — the LOI
 * block's point 3(a), the PSA block's point 3, the two "NO PARENT STAMP AND NO QUEUEABLE" lines at
 * the end of each insert, and the `loiAndPsaAutoCreateEnqueueNothing` test — was rewritten or
 * inverted in that same change. `DispositionPrimaryChildStampQueueable` (the new job) argues the
 * deferral from scratch and does NOT inherit the NDA one's reasoning, per the W1 lesson above.
 *
 * ⚠ AND THE ACTIVE LISTING BLOCK'S SYSTEM_MODE REASON IS NOT THE OTHER THREE'S. They need it
 * because the disposition persona holds `allowCreate = false` on their child object. The
 * disposition persona holds `allowCreate = TRUE` on `Broker_Listing__c` (measured), so that
 * argument is simply false here and quoting it would be inheriting a justification again. The real
 * reason is stated at `openBrokerListings`, and it is a genuine, bounded widening rather than a
 * restoration of access the persona already had.
 *
 * ── 🔴 IT FIRES ON A RECORD THAT THREE APPROVALS LOCK ────────────────────────
 * `Disposition__c` is the entry object of `Sale_Decision_Approval` (at `Disposition Readiness`),
 * `Broker_Selection_Approval` (at `Broker Selection` AND record type Off Market) and
 * `Closing_Approval` (at `Closing` AND `Wire_Verification_Completed__c = true`). All three
 * declare `recordEditability = AdminOnly`, so while any of them is pending the record is LOCKED.
 *
 * ⚠ THE ENTRY CRITERIA ABOVE CHANGED ON 2026-08-19 AND THE OLD ONES ARE QUOTED HERE BECAUSE THIS
 * FILE ARGUED FROM THEM IN FOUR PLACES. RETRACTED, verbatim: "`Broker_Selection_Approval` (at BOV
 * Outreach)". That process now enters at `Broker Selection` and only on the OFF-MARKET record type,
 * and `Closing_Approval` gained the wire-verified term. Every block below that reasons "stage X is
 * not any approval's entry stage" has been re-checked against the NEW set, not the old one; where
 * the conclusion survived, the evidence for it was rewritten rather than left pointing at a
 * criterion that no longer exists.
 *
 * ⚠ AND THERE ARE NOW **FIVE** APPROVAL PROCESSES IN THIS MODULE, NOT THREE. The two new ones —
 * `Broker_Finalize_Approval` on `BOV_Submission__c` and `Offer_Selection_Approval` on
 * `Disposition_Offer__c` — are deliberately NOT in the list above, because their entry object is a
 * CHILD and they therefore lock the CHILD, never the Disposition. That is exactly why
 * `BovSubmissionTriggerHandler` and `DispositionOfferTriggerHandler` update the parent
 * SYNCHRONOUSLY where the three above need a Queueable. A future reader counting approvals must
 * count entry OBJECTS, not processes.
 *
 * ⚠ ALL THREE DISPOSITION-TARGET APPROVALS NOW CARRY `finalApprovalActions`, WHICH THEY DID NOT
 * BEFORE 2026-08-19. Each sets ONLY the boolean `Approval_Advance_Pending__c` (design D-1); the
 * stage is then written by `DispositionApprovalAdvanceQueueable` using ordinary
 * `Database.update(..., SYSTEM_MODE)`, so validation rules still evaluate and the write does not
 * run as the approver. Two blocks below used to lean on "none of the three approvals performs a
 * field update at all" — that premise is dead and is replaced in place.
 *
 * ⚠ THE LOCK BITES A PARENT WRITE, NOT A CHILD INSERT. `SYSTEM_MODE` lifts CRUD and FLS but does
 * NOT lift an approval lock (measured on the LOI path; see LoiPrimaryStampQueueable's header for
 * the two failed attempts). A child of a locked record is not itself locked, so every child insert
 * below is safe synchronously; a write BACK to `Disposition__c` is not. That single distinction is
 * what makes the NDA block's Queueable necessary and the other two blocks' absence of one correct.
 *
 * ⚠ And note the asymmetry OpportunityReviewService records: FIVE of its six child-creation blocks
 * deliberately use neither SYSTEM_MODE nor a deferred stamp, because a deal driver with Edit enters
 * those stages. Do not harmonize in either direction.
 *
 * ── LAYERING / BULK ─────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2). ZERO inline SOQL — the FIVE idempotency reads go to
 * NdaSelector.selectByDispositionIds (used TWICE, by two different stage blocks, for two different
 * questions), LoiSelector.selectByDispositionIds, ContractReviewSelector.selectByDispositionIds and
 * BrokerListingSelector.selectByDispositionIds, all `WITH SYSTEM_MODE` for automation-path reasons
 * documented at those methods. ⚠ SINCE 2026-08-21 THERE IS A SIXTH READ AND IT IS NOT AN
 * IDEMPOTENCY READ — `BovSubmissionSelector.selectSelectedBrokerByDispositionIds` resolves the
 * appointed broker for the NDA block's ON-MARKET entrants. It is CONDITIONAL (see the budget
 * below), which is why the count above still says FIVE for the idempotency family.
 *
 * ⚠ AND A THIRD FAMILY SINCE 2026-08-25, ALSO NOT AN IDEMPOTENCY READ:
 * `DispositionOfferSelector.selectNewestSelectedIdByDispositionIds` resolves the disposition's
 * selected offer so the LOI and PSA blocks can stamp it onto the CHILD they are inserting
 * (`LOI__c.Selected_Offer__c` / `Contract_Review__c.Selected_Offer__c`). One call per block,
 * ISSUED AFTER THAT BLOCK'S IDEMPOTENCY EARLY RETURN so a fully-suppressed chunk still costs
 * exactly one query — there is a test on that (`loiSuppressionPathCostsOneQueryAndNoDmlAt251`).
 * It adds a COLUMN to rows already being inserted, never a DML statement.
 *
 * Trigger-driven, so the `.claude/rules/bulk-test-rule.md` per-transaction-singleton exemption
 * does NOT apply and literal 251-record bulk tests exist for all five stages. Budget is
 * 1 SOQL / 1 DML PER STAGE ENTERED IN THE CHUNK (≤ 5 / ≤ 5, raised from ≤ 4 on 2026-08-20 by the
 * Release Materials block), plus ≤ 3 enqueues (the NDA, LOI and PSA parent stamps) — CONSTANT IN
 * THE NUMBER OF DISPOSITIONS.
 * ⚠ THE ENQUEUE CEILING READ "≤ 1 enqueue for the NDA block" UNTIL 2026-08-25. Each of the three
 * stamping blocks enqueues its OWN guarded job, so a single chunk entering all three stages costs
 * 3. Each guard is `Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()`, so in an ASYNC
 * caller (chained-job cap of 1) the FIRST block to run wins and the others silently skip their
 * stamp — the residual each block documents at its own enqueue. That constancy is the property the bulk tests assert, not merely that 251 rows
 * produced 251 children. A chunk that enters no target stage at all — the overwhelmingly common
 * case, since this trigger fires on EVERY Disposition write in the org — costs zero queries, zero
 * DML and zero enqueues.
 *
 * 🔴 THE SOQL CEILING IS **≤ 8** AS OF 2026-08-25. The paragraph immediately below raised it from
 * ≤ 5 to ≤ 6 on 2026-08-21 and its reasoning is unchanged; the LOI and PSA blocks each added ONE
 * MORE conditional read on 2026-08-25 (the selected-offer resolution above), taking it to ≤ 8.
 * Those two are conditional on STAGE and on surviving the idempotency filter — an LOI chunk where
 * every disposition already has its LOI still costs exactly 1. The DML ceiling stays ≤ 5.
 *
 * ⚠ THE SOQL CEILING IS **≤ 6**, NOT ≤ 5, SINCE 2026-08-21, AND THE SIXTH IS CONDITIONAL ON DATA
 * RATHER THAN ON STAGE. The NDA block issues a SECOND query — the broker resolution above — and
 * ONLY when, after the idempotency filter has run, at least one surviving entrant is on the
 * `On_Market` record type. So: an off-market-only NDA chunk still costs exactly 1; a chunk where
 * every entrant already has its buyer NDA still costs exactly 1 and returns before the resolution
 * is reached; a mixed or on-market chunk costs 2 for the NDA stage. The DML ceiling is UNCHANGED at
 * ≤ 5 — the broker is stamped onto rows the block was already inserting, so it adds a COLUMN, never
 * a statement. Both facts have their own falsifier in DispositionStageEntryServiceTest; the
 * "exactly ONE query on the suppression path" assertion that guards the constancy property is the
 * one that would go red first if the resolution ever moved ahead of the early return.
 * ⚠ A SINGLE CHUNK THAT ENTERS BOTH `NDA` AND `Release Materials` ISSUES
 * `NdaSelector.selectByDispositionIds` TWICE. That is the per-stage budget working as documented,
 * not a duplicate read: the two calls carry DIFFERENT Id sets (a disposition cannot be entering both
 * stages in one save) and answer different questions.
 *
 * ⚠ `stampListingDates` IS OUTSIDE THAT BUDGET BY CONSTRUCTION, NOT BY EXEMPTION: it runs in a
 * BEFORE context and performs zero SOQL, zero DML and zero enqueues at any record count. It cannot
 * move the numbers above because it issues no statements at all.
 *
 * @see force-app/main/default/classes/OpportunityReviewService.cls (the acquisitions twin)
 * @see force-app/main/default/classes/DispositionNdaStampQueueable.cls (the deferred NDA stamp)
 * @see force-app/main/default/classes/DispositionPrimaryChildStampQueueable.cls (the deferred LOI/PSA stamps)
 * @see force-app/main/default/classes/DispositionOfferSelector.cls (the selected-offer resolution)
 * @see force-app/main/default/classes/NdaSelector.cls (the NDA idempotency read)
 * @see force-app/main/default/classes/LoiSelector.cls (the LOI idempotency read)
 * @see force-app/main/default/classes/ContractReviewSelector.cls (the PSA idempotency read)
 * @see force-app/main/default/classes/BrokerListingSelector.cls (the listing idempotency read)
 * @see force-app/main/default/classes/DispositionTractionService.cls (what the clock feeds)
 */
public with sharing class DispositionStageEntryService {

    /**
     * The stage whose ENTRY opens the buyer's NDA.
     *
     * 🔴 IT IS ON **BOTH** RECORD TYPES SINCE 2026-08-19, AND THIS BLOCK'S PREVIOUS TEXT IS
     * RETRACTED RATHER THAN DELETED: "Off-market only by value set (D5)." That doctrine is dead.
     * The redesigned on-market path is
     * `... Broker Selection -> NDA -> Release Materials -> Active Listing ...`, so a broker-listed
     * sale now signs a buyer NDA exactly as a direct one does.
     *
     * ✅ AND THIS CONSTANT AND ITS BLOCK NEEDED NO CODE CHANGE FOR THAT, WHICH IS THE POINT WORTH
     * RECORDING. `createStageEntryRecords` keys on the STAGE VALUE and has never carried a
     * RecordType criterion — the D5 note was an OBSERVATION about the value set, never a condition
     * this code tested. Had anyone "helpfully" added the record-type filter the comment implied,
     * the redesign would have silently stripped the buyer NDA from every on-market sale. That is
     * the standing argument for keying on the transition and not on the type.
     *
     * ⚠ WHAT DOES CHANGE IS TEST COVERAGE, NOT BEHAVIOUR: NDA-on-`On_Market` is new territory for
     * this block and needs its own bulk case (design DEV-19).
     */
    @TestVisible
    private static final String NDA_STAGE = 'NDA';

    /**
     * The stage whose ENTRY opens the sell-side LOI.
     *
     * ⚠ THIS STAGE IS ON BOTH DISPOSITION RECORD TYPES — verified against
     * objects/Disposition__c/recordTypes/: `LOI` and `PSA` are exposed on `On_Market` AND
     * `Off_Market`. So these two blocks fire for a broker-listed sale as well as a direct one, and
     * that is correct: an on-market disposition negotiates an LOI exactly as an off-market one
     * does. A future change that scoped either block to a record type would silently strip the
     * negotiation record from every broker-listed sale.
     *
     * ⚠ THE CLAUSE THAT USED TO OPEN THAT PARAGRAPH — "UNLIKE `NDA`, ... while `NDA` is off-market
     * only" — DIED ON 2026-08-19. `NDA` is now on both types too, so LOI and PSA are no longer the
     * exception they are contrasted against; they are simply three of the many shared stages. The
     * CONCLUSION about not scoping by record type is unchanged and is now the rule rather than the
     * special case. See NDA_STAGE.
     */
    @TestVisible
    private static final String LOI_STAGE = 'LOI';

    /** The stage whose ENTRY opens the sell-side PSA. On BOTH record types — see LOI_STAGE. */
    @TestVisible
    private static final String PSA_STAGE = 'PSA';

    /**
     * The stage whose ENTRY opens the broker listing and starts the marketing clock (D28/Q3).
     *
     * 🔴 ON-MARKET ONLY BY VALUE SET — AND SINCE 2026-08-19 IT IS THE **ONLY** STAGE IN THIS FILE
     * FOR WHICH THAT IS STILL TRUE. `Active Listing` is exposed on the `On_Market` record type and
     * not on `Off_Market` (verified in objects/Disposition__c/recordTypes/), which is correct: a
     * direct sale has no listing broker and no marketing period, so there is nothing to clock. An
     * off-market sale collects its offers at `Release Materials` instead. No RecordType criterion is
     * needed here and none should be added — the value set is self-limiting.
     *
     * ⚠ THE CLAUSES THIS BLOCK USED TO CARRY ARE BOTH DEAD AND ARE RETRACTED VERBATIM: "like `NDA`
     * is off-market only" (`NDA` is now on both types — see NDA_STAGE) and "exactly as
     * `Broker_Selection_Approval`'s own description records for the same stage family" (that
     * approval no longer keys on this stage family at all; it enters at `Broker Selection` AND
     * record type Off Market). The self-limiting-value-set ARGUMENT survives both; only its two
     * illustrations were false, and an example nobody can find teaches nothing.
     */
    @TestVisible
    private static final String LISTING_STAGE = 'Active Listing';

    /**
     * The stage whose ENTRY default-stamps `NDA__c.Materials_Released_Date__c` on every buyer NDA
     * that does not already carry one (Tranche 2 Workstream D, design D6.1).
     *
     * 🔴 ON **BOTH** RECORD TYPES BY VALUE SET, and no RecordType criterion is needed or wanted.
     * Verified against objects/Disposition__c/recordTypes/: `Release Materials` is exposed on
     * `On_Market` AND `Off_Market` — the on-market path walks
     * `... Broker Selection -> NDA -> Release Materials -> Active Listing ...` and the off-market
     * path walks `... NDA -> Release Materials -> Offer Selection ...`. Both release a deal package
     * to the buyers who signed, which is exactly what this date records. Keying on the TRANSITION
     * rather than on the type is the standing argument this file already makes at `NDA_STAGE`.
     *
     * ⚠ UNLIKE THE OTHER FOUR STAGE CONSTANTS, THIS ONE OPENS NO CHILD RECORD. It updates children
     * that already exist. That is why it is handled by its own method below and is deliberately NOT
     * folded into the `open*` family — the four `open*` methods are all "create if absent", and this
     * is "fill if blank", which is a different idempotency question with a different failure mode.
     */
    @TestVisible
    private static final String RELEASE_MATERIALS_STAGE = 'Release Materials';

    /**
     * The `Listing_Status__c` every auto-created listing opens at.
     *
     * ⚠ IT HAPPENS TO EQUAL THE FIELD-LEVEL DEFAULT, and is set explicitly anyway for the same
     * reason DISPOSITION_PSA_INITIAL_STATUS is: a fresh listing starting On Track is a business
     * decision of this feature, and an implicit default is not falsifiable by a test.
     *
     * 🔴 NOTHING KEEPS THIS FIELD IN STEP AFTERWARDS, AND THAT IS DELIBERATE. The displayed
     * traction band is computed live by `DispositionTractionService` and deliberately does NOT read
     * this field, so a stale hand-set value cannot corrupt it. Writing it on a schedule is the
     * deferred D9 job's work; `DispositionTractionService.listingStatusValue` is the seam it uses.
     */
    @TestVisible
    private static final String LISTING_INITIAL_STATUS = 'On Track';

    /**
     * Developer name of the record type every auto-created DISPOSITION NDA is stamped with.
     * Case must match objects/NDA__c/recordTypes/ exactly — getRecordTypeInfosByDeveloperName()
     * keys its map case-SENSITIVELY.
     */
    @TestVisible
    private static final String DISPOSITION_NDA_RECORD_TYPE = 'Disposition_NDA';

    /** Ditto, objects/LOI__c/recordTypes/. */
    @TestVisible
    private static final String DISPOSITION_LOI_RECORD_TYPE = 'Disposition_LOI';

    /** Ditto, objects/Contract_Review__c/recordTypes/. */
    @TestVisible
    private static final String DISPOSITION_PSA_RECORD_TYPE = 'Disposition_PSA';

    /**
     * The DISPOSITION record type whose appointed broker lives on a `Selected` BOV submission
     * rather than on the disposition itself (2026-08-21 broker stamp — see `openBuyerNdas`).
     *
     * 🔴 IT IS THE **ONLY** RECORD-TYPE CRITERION IN THIS CLASS, AND EVERY OTHER BLOCK'S COMMENT
     * SAYS NOT TO ADD ONE. That instruction is not being broken — read what it forbids. `NDA_STAGE`
     * and `LISTING_STAGE` both argue, at length, that WHETHER A CHILD IS CREATED must key on the
     * STAGE TRANSITION and never on the record type, because a record-type filter there silently
     * strips the child from one whole path. This constant does not gate creation at all: every
     * entrant gets its NDA on both record types, exactly as before. It selects WHICH FIELD holds
     * the broker, which genuinely IS a property of the record type and is enforced as one by the
     * `Broker_Lookup_Is_Off_Market_Only` validation rule.
     *
     * ⚠ `Is_On_Market__c` WAS REJECTED AS THE DISCRIMINATOR EVEN THOUGH IT IS THE FIELD THAT LOOKS
     * PURPOSE-BUILT FOR THIS. It is a FORMULA over `RecordType.DeveloperName`, added (per its own
     * XML comment) solely so a FlexiPage visibility rule could test the record type without a
     * spanning merge field. A formula's value in `Trigger.new` is not a guarantee this code should
     * lean on, and the formula reads BLANK — i.e. FALSE, i.e. "off-market" — on a Master-record-type
     * row. `RecordTypeId` is a stored field, is always populated in trigger context, and is the
     * same thing the validation rule ultimately keys on.
     *
     * ⚠ A MASTER-RECORD-TYPE ROW TAKES THE OFF-MARKET BRANCH, and that is the safe direction: it
     * reads `Disposition__c.Broker__c`, which on such a row is whatever a human put there, and a
     * blank simply yields a blank broker. Taking the ON-market branch instead would have gone
     * looking for a `Selected` BOV that a Master row has no business having.
     *
     * Case must match objects/Disposition__c/recordTypes/ exactly — see `recordTypeIdFor`.
     */
    @TestVisible
    private static final String ON_MARKET_RECORD_TYPE = 'On_Market';

    /**
     * The counterparty role the auto-created NDA carries, and simultaneously the NDA block's
     * IDEMPOTENCY KEY (D19.1). Changing this constant silently changes both.
     */
    @TestVisible
    private static final String BUYER_ROLE = 'Buyer';

    /**
     * Disposition_NDA's default Status__c.
     *
     * ⚠ IT IS A CONSTANT AND HAS TO BE. Apex describes expose a picklist's FIELD-level default,
     * not a RECORD-TYPE-level one, so "the record type's default" is not readable from Apex at
     * any price.
     * ⚠ RETRACTED 2026-08-21 — this note used to continue: "and record-type picklist restriction is
     * UI-only, so DML would happily accept 'Pending' here and produce an NDA whose status is off
     * its own value set." False for a `restricted` value set, and `NDA__c.Status__c` is restricted.
     * A wrong constant here is REFUSED by DML — which means it does not produce a bad row, it
     * produces a failed NDA creation surfaced as an opaque INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST
     * from a stage entry the user did not know triggered an NDA. Still worth getting right, and now
     * the deploy ORDER matters too: the record type must carry this value before this class is
     * deployed naming it.
     * ⚠ SUPERSEDED 2026-08-25 as to the last sentence, which read: "Keep this in step with the
     * `<default>true</default>` entry under Status__c in
     * objects/NDA__c/recordTypes/Disposition_NDA.recordType-meta.xml." THERE IS NO SUCH ENTRY ANY
     * MORE — the user cleared that record type's default in Setup, so it has none, and there is
     * nothing left to keep this in step WITH.
     *
     * 🔴 CHANGED 2026-08-25: 'Not Sent' -> 'Prepare'. 'Not Sent' was removed from the
     * Disposition_NDA record type in the same change (measured live; see that record type file's
     * 2026-08-25 amendment). Leaving this constant at 'Not Sent' would have made EVERY future
     * disposition NDA insert fail — not silently, but with exactly the opaque
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST the paragraph above predicts, raised from a stage
     * change into `NDA` that the user has no reason to connect to an NDA at all.
     *
     * 🔴 THIS CONSTANT IS NOW THE ONLY DECLARATION OF THE DISPOSITION NDA ENTRY STATE ANYWHERE IN
     * THE ORG. With no record-type default, a UI-created NDA arrives BLANK and the user picks;
     * only this line decides where an AUTO-created one starts. 'Prepare' is the first step of the
     * record type's sequence (Prepare -> Approved -> Sent -> Signed, plus Declined).
     * ⚠ THAT SEQUENCE READ "Prepare -> Review -> Approved -> Sent -> Signed" FOR A FEW HOURS ON
     * 2026-08-25 before the user removed 'Review' from the record type in Setup as well. THIS
     * CONSTANT DID NOT MOVE and needed no change — 'Prepare' is still the first step. The value
     * that WAS affected was the next hop in RecordStageAdvanceService's map; see that class.
     * Seeding blank was rejected: a blank status on a record the user did not create reads as a
     * failed creation, and `NDA_Signed_Rollup` would count it as outstanding either way.
     */
    @TestVisible
    private static final String DISPOSITION_NDA_INITIAL_STATUS = 'Prepare';

    /**
     * Disposition_LOI's default Stage__c. Same "constants, not describes" reasoning as
     * DISPOSITION_NDA_INITIAL_STATUS — keep in step with the `<default>true</default>` entry under
     * Stage__c in objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml.
     *
     * 🔴 'Draft' — the FIELD-level default and the acquisition starting stage — WOULD INSERT
     * HAPPILY HERE and produce an LOI whose stage is off its own record type's value set. 'Draft'
     * is acquisition-only (D6), so RecordStageAdvanceService's disposition sequence has no 'Draft'
     * entry at all and the row could never be advanced. Nothing but this constant prevents that.
     * ⚠ This used to reach that conclusion via "the two LOI value sets are fully DISJOINT", which
     * observation 5 ended on 2026-08-14 by renaming 'Prepare/Review' to 'Under Review' — a value the
     * disposition sequence already carried. The sets overlap there now; 'Draft' specifically does
     * not, which is the only part this constant ever depended on.
     */
    @TestVisible
    private static final String DISPOSITION_LOI_INITIAL_STAGE = 'Received';

    /**
     * Disposition_PSA's default Negotiation_Status__c.
     *
     * 🔴 IT IS Negotiation_Status__c AND NOT Stage__c, AND THAT IS NOT A STYLE CHOICE. On
     * `Contract_Review__c`, `Stage__c` is a DERIVED PROJECTION: the active before-save flow
     * `Contract_Review_Stage_Sync` recomputes it from `Negotiation_Status__c` on every create and
     * update, so a direct write to `Stage__c` COMMITS AND IS SILENTLY DISCARDED (measured
     * 2026-08-05 on CTR-0000; the full note is at
     * ContractReviewSelector.selectStageRequiredById). Seeding `Stage__c` here would therefore look
     * like it worked and mean nothing. Setting the status is what actually produces
     * `Stage__c = 'PSA Drafting'`.
     *
     * ⚠ This value happens to equal the field-level default too, so leaving it unset would produce
     * the same row TODAY. It is set explicitly anyway: the value is a business decision of this
     * feature (a new sell-side PSA opens at its first draft), and an implicit default is not
     * falsifiable by a test. Keep in step with the `<default>true</default>` entry under
     * Negotiation_Status__c in
     * objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml.
     */
    @TestVisible
    private static final String DISPOSITION_PSA_INITIAL_STATUS = 'Initial Draft';

    /**
     * Called from the Disposition__c after-insert / after-update trigger. Opens each stage's child
     * record on ENTRY to that stage, exactly once per disposition.
     *
     * @param newDispositions Trigger.new
     * @param oldMap          Trigger.oldMap on update; null on insert (an insert is treated as
     *                        entry into whatever stage the row was created at)
     */
    public static void createStageEntryRecords(
        List<Disposition__c> newDispositions,
        Map<Id, Disposition__c> oldMap
    ) {
        // ⚠ THE NDA SET IS A MAP AND THE OTHER THREE ARE NOT. Since 2026-08-21 the NDA block reads
        // TWO values off the parent — `RecordTypeId` and `Broker__c` — to resolve the broker to
        // stamp, so it needs the WHOLE RECORD, exactly as the listing branch already did. A
        // Map<Id, Disposition__c> rather than a List because the block's idempotency filter removes
        // entrants BY PARENT ID, which a List cannot do without a scan per row.
        Map<Id, Disposition__c> ndaStageEntrants = new Map<Id, Disposition__c>();
        Set<Id> loiStageEntrants = new Set<Id>();
        Set<Id> psaStageEntrants = new Set<Id>();
        Set<Id> materialsStageEntrants = new Set<Id>();
        List<Disposition__c> listingStageEntrants = new List<Disposition__c>();
        for (Disposition__c d : newDispositions) {
            Disposition__c prior = (oldMap == null) ? null : oldMap.get(d.Id);
            String priorStage = (prior == null) ? null : prior.Disposition_Stage__c;
            // ENTRY, not presence. An update that leaves the stage alone must not re-open a child
            // — which is what makes the deferred parent stamp's own update a no-op here.
            if (priorStage == d.Disposition_Stage__c) {
                continue;
            }
            if (NDA_STAGE == d.Disposition_Stage__c) {
                ndaStageEntrants.put(d.Id, d);
            } else if (LOI_STAGE == d.Disposition_Stage__c) {
                loiStageEntrants.add(d.Id);
            } else if (PSA_STAGE == d.Disposition_Stage__c) {
                psaStageEntrants.add(d.Id);
            } else if (RELEASE_MATERIALS_STAGE == d.Disposition_Stage__c) {
                materialsStageEntrants.add(d.Id);
            } else if (LISTING_STAGE == d.Disposition_Stage__c) {
                // ⚠ The WHOLE RECORD, not just the Id — unlike the other three, this block copies
                // two values off the parent (Listing_Date__c and Selected_Broker__c) onto the
                // child, and re-querying for fields Trigger.new already carries would be a query
                // bought for nothing.
                listingStageEntrants.add(d);
            }
        }
        // Each helper returns immediately on an empty set, so a chunk that entered none of the
        // FIVE target stages — the overwhelmingly common Disposition save — costs nothing at all.
        openBuyerNdas(ndaStageEntrants);
        openDispositionLois(loiStageEntrants);
        openDispositionContractReviews(psaStageEntrants);
        stampMaterialsReleasedDates(materialsStageEntrants);
        openBrokerListings(listingStageEntrants);
    }

    /**
     * BEFORE INSERT / BEFORE UPDATE. Starts the 60-day marketing clock by stamping
     * `Listing_Date__c` on entry to `Active Listing` — in memory, on the record being saved.
     *
     * ═══════════════════════════════════════════════════════════════════════
     * 🔴 THE DML MODE AND THE LOCK, RE-ARGUED FROM SCRATCH. NOTHING HERE IS INHERITED.
     * ═══════════════════════════════════════════════════════════════════════
     *
     * ── FIRST, A MEASURED CORRECTION TO A PREMISE THAT LOOKS TRUE AND IS NOT ──
     * `Active Listing` is NOT any approval's entry stage. The three Disposition-target processes
     * key on `Disposition Readiness` (`Sale_Decision_Approval`), on `Broker Selection` AND record
     * type Off Market (`Broker_Selection_Approval`), and on `Closing` AND
     * `Wire_Verification_Completed__c = true` (`Closing_Approval`). So NO approval in this org has
     * `Active Listing` as its entry stage, and this block is not the "runs as the approver" case
     * that `OpportunityReviewService`'s LOI block is.
     *
     * ⚠ THE EVIDENCE ABOVE WAS REWRITTEN ON 2026-08-19; THE CONCLUSION WAS NOT. RETRACTED,
     * verbatim: "Read off
     * approvalProcesses/Disposition__c.Broker_Selection_Approval.approvalProcess-meta.xml, the
     * `entryCriteria` is `Disposition_Stage__c equals **BOV Outreach**`. The three disposition
     * approvals key on `Disposition Readiness`, `BOV Outreach` and `Closing` respectively." Two of
     * those three criteria moved in the flow redesign. `Active Listing` is still on none of them.
     *
     * ⚠ AND THE ADJACENCY ARGUMENT MOVED WITH THEM — THE HAZARD IS THE SAME SHAPE FROM A DIFFERENT
     * NEIGHBOUR. `Active Listing` is now the stage a disposition moves INTO from `Release
     * Materials` (it used to arrive from `BOV Outreach`), and `Release Materials` is NOT an
     * approval's entry stage either. 🔴 SO THE ADJACENT-LOCK CASE IS GONE ON THIS PATH: the nearest
     * locking stage upstream is `Broker Selection`, two hops away and off-market only, and an
     * off-market sale never reaches `Active Listing` at all. What remains is the general case —
     * `AdminOnly` lets an ADMIN edit a locked record, so an admin CAN drag a disposition from
     * `Broker Selection`-under-approval straight to `Active Listing` in one edit. Three cases, and
     * only one is live:
     *
     *   (a) approval already approved, then the owner advances — `finalApprovalRecordLock = false`
     *       released the lock in a PRIOR transaction, so the record is unlocked. Safe.
     *   (b) approval still pending, a NON-admin tries to advance — `AdminOnly` makes the platform
     *       refuse the update BEFORE any trigger runs. This code never executes. Safe.
     *   (c) approval still pending, an ADMIN advances — `AdminOnly` permits it, so this code runs
     *       with the approval still pending, i.e. with the record still locked against a SECOND
     *       DML. 🔴 This is the one live hazard, and it is exactly the residual review D20/W1
     *       recorded against DispositionNdaStampQueueable.
     *
     * ── WHAT WAS CHOSEN, AND WHY IT BEATS BOTH SIBLING ANSWERS ──────────────
     * A BEFORE-SAVE, IN-MEMORY ASSIGNMENT. No DML, no Queueable, no lock exposure, at any record
     * count. Case (c) becomes harmless: the admin's own update is permitted (that is what
     * `AdminOnly` means), and this writes into that same already-permitted save. There is no second
     * statement for ENTITY_IS_LOCKED to refuse.
     *
     *   an inline `update` in the AFTER context — REJECTED. In case (c) it throws
     *       ENTITY_IS_LOCKED with allOrNone = true, rolling back the admin's own stage change. The
     *       measured lesson (LoiPrimaryStampQueueable, Tranche 2 C1): SYSTEM_MODE lifts CRUD and
     *       FLS and NEVER a lock, so `AccessLevel.SYSTEM_MODE` would not rescue it either.
     *   a QUEUEABLE, copying the NDA block — REJECTED, AND IT WOULD NOT EVEN WORK. D20/W1
     *       established the reason precisely: `finalApprovalRecordLock = false` releases the lock
     *       ON FINAL APPROVAL, and on this path the triggering transaction is NOT the one releasing
     *       it, so a PENDING approval OUTLIVES the queueable and the async update throws too —
     *       with allOrNone = true, no retry, and nothing but a failed AsyncApexJob to show for it.
     *       Copying that pattern here would inherit its known residual and buy nothing.
     *
     * 🔴 AND THE REASON THIS OPTION IS AVAILABLE HERE BUT NOT TO THE NDA BLOCK IS STRUCTURAL, NOT
     * PREFERENCE. `Primary_NDA__c`'s value is the CHILD'S ID, which does not exist until after the
     * child is inserted, which needs the parent's Id, which needs the AFTER context. It is causally
     * downstream of the insert and cannot be computed early at any price. `Listing_Date__c` depends
     * on nothing but the transition being made, which is fully known in before-update. That is the
     * whole difference, and it is why the two must not be harmonised.
     *
     * ── FLS ────────────────────────────────────────────────────────────────
     * A before-trigger field assignment is an in-memory SObject mutation and is not FLS-checked, so
     * a persona without EDIT on `Listing_Date__c` still gets the stamp. That is the intended
     * outcome and matches `LeadConvertService`'s stamp: a missing FLS grant makes the value
     * invisible to that persona, it does not disable the clock. `DPEG_Disposition_View` holds the
     * field read-only and cannot change a stage anyway.
     *
     * ── 🔴 FILL-IF-BLANK, NEVER UNCONDITIONAL. THREE INDEPENDENT REASONS ────
     * 1. IDEMPOTENCY. Re-entering `Active Listing` must not restart the marketing clock — the same
     *    "never a second listing for one disposition" rule the child guard enforces. An
     *    unconditional stamp would reset the 60 days every time someone stepped back and forward.
     * 2. IT WOULD DESTROY REAL DATA. `TestDataFactory.createDispositions` seeds
     *    `Listing_Date__c = Date.today()` on EVERY fixture, and a human can set the true listing
     *    date by hand before advancing the stage. Overwriting a known date with "today" is a silent
     *    data loss.
     * 3. IT KEEPS THE PARENT CLOCK AND THE CHILD'S `List_Date__c` IN AGREEMENT, because
     *    `openBrokerListings` copies the parent value rather than re-deriving `Date.today()`.
     *
     * ⚠ CONSEQUENCE FOR TESTS, STATED BECAUSE IT MAKES THE OBVIOUS TEST VACUOUS: since the factory
     * pre-populates `Listing_Date__c`, a test asserting that this method stamps must NULL THE FIELD
     * FIRST. Without that it passes for the wrong reason — the value it asserts was put there by
     * the fixture, not by this code.
     *
     * @param newDispositions Trigger.new.
     * @param oldMap          Trigger.oldMap on update; null on insert (an insert is treated as
     *                        entry into whatever stage the row was created at).
     */
    public static void stampListingDates(
        List<Disposition__c> newDispositions,
        Map<Id, Disposition__c> oldMap
    ) {
        if (newDispositions == null || newDispositions.isEmpty()) {
            return;
        }
        // Resolved once for the whole chunk. Date.today() is stable within a transaction, but
        // hoisting it also makes every stamped row in one save carry an identical date rather than
        // relying on that.
        Date today = Date.today();
        for (Disposition__c d : newDispositions) {
            if (LISTING_STAGE != d.Disposition_Stage__c) {
                continue;
            }
            // ENTRY, not presence — the same test createStageEntryRecords makes, so the pair
            // cannot disagree about which saves are a stage entry. On insert oldMap is null and
            // priorStage is null, so being CREATED at Active Listing counts as entry.
            Disposition__c prior = (oldMap == null || d.Id == null) ? null : oldMap.get(d.Id);
            String priorStage = (prior == null) ? null : prior.Disposition_Stage__c;
            if (priorStage == d.Disposition_Stage__c) {
                continue;
            }
            if (d.Listing_Date__c == null) {
                d.Listing_Date__c = today;
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // `NDA` STAGE — the buyer's NDA. Tranche 3A.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Opens one buyer NDA per entrant, then defers the parent stamp.
     *
     * ── IDEMPOTENCY: THE KEY IS Party_Role__c = 'Buyer', NOT "any NDA" ───────
     * D19.1: auto-create makes the BUYER NDA only. A broker NDA is added by hand from the related
     * list when a broker actually introduced the buyer — something the system cannot know in
     * advance. So "already has an NDA" is the WRONG suppression test: a user who added the broker's
     * NDA early would then never get the buyer's. The key is "already has a BUYER NDA on this
     * disposition", which is also what makes re-entering the stage, a re-save, and the stamp update
     * itself all no-ops.
     *
     * ⚠ THIS IS THE ONE BLOCK WHOSE IDEMPOTENCY KEY IS NOT SIMPLE PRESENCE. The LOI and PSA blocks
     * have no Party_Role__c equivalent — there is exactly one kind of disposition LOI and one kind
     * of disposition PSA — so for them "already has one" IS the whole test. Do not "harmonize" this
     * one down to presence.
     *
     * ⚠ The check is deliberately NOT scoped to the Disposition_NDA record type. In the window
     * between the record-type deploy and post-deploy gate T-A1, a buyer NDA can legitimately sit on
     * MASTER — and suppressing on record type would then mint a second one.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 IT ALSO STAMPS `NDA__c.Broker__c` SINCE 2026-08-21, AND THAT IS A BUG FIX, NOT A FEATURE.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * The buyer-to-broker change of 2026-08-21 replaced the NDA counterparty entirely — `Buyer__c`
     * retired, `Broker__c` added, on the user's explicit instruction that "everything must be
     * linked with broker contact as he is the only person that DPEG will be communicating." THIS
     * CREATION PATH WAS MISSED. Measured in `usman-dpeg`: `NDA-0115`, auto-created by this method
     * on `DISP-0019`, carried `Broker__c = null`; `NDA-0114` has one only because a human typed it.
     * The counterparty field existed and nothing populated it, on the ONE code path that creates
     * most of the rows.
     *
     * ── WHERE THE BROKER ACTUALLY LIVES: TWO ANSWERS, ONE PER RECORD TYPE ───────────────────────
     *   `Off_Market`  ->  `Disposition__c.Broker__c`, straight off `Trigger.new`. Zero queries.
     *   `On_Market`   ->  the `Selected` `BOV_Submission__c`'s `Broker__c`, via
     *                     `BovSubmissionSelector.selectSelectedBrokerByDispositionIds`.
     *
     * 🔴 `Disposition__c.Selected_Broker__c` IS **NOT** THE SOURCE, AND IT IS THE FIELD A READER
     * WILL REACH FOR FIRST BECAUSE OF ITS NAME. It is a **Text(255)** holding a FIRM name on the
     * on-market path (measured: `"Colliers Houston"`) and a `Person - Firm` composite off-market —
     * one field, two formats, and its own field file states in capitals that NO CONSUMER MAY PARSE
     * IT. It cannot be assigned to a Contact lookup at all; it is a denormalised display copy with
     * a documented staleness window. The block immediately below (`openBrokerListings`) copies it
     * into `Broker_Listing__c.Broker_Firm__c`, which is a Text-to-Text copy and is the ONLY correct
     * use of it in this file. Do not harmonise the two.
     *
     * 🔴 AND THE ON-MARKET BRANCH CANNOT BE COLLAPSED INTO THE OFF-MARKET ONE BY "just reading
     * `Disposition__c.Broker__c` on both". `Broker_Lookup_Is_Off_Market_Only` is an ACTIVE
     * validation rule that REFUSES a value in that field whenever `Is_On_Market__c` is true, so on
     * an on-market row it is null by enforcement, not by convention — and it must stay that way
     * (the rule's own header explains that an off-market stamp there would poison
     * `Selected_Broker__c` and, through it, the listing's firm column). One lookup, two populations,
     * genuinely two reads.
     *
     * ── 🔴 "NO BROKER RESOLVABLE" IS A NORMAL OUTCOME AND MUST NEVER BLOCK THE NDA ─────────────
     * An off-market disposition whose `Broker__c` is blank, and an on-market one with no `Selected`
     * submission yet (or a Selected one that names no broker), BOTH get their NDA — created with a
     * null `Broker__c`, byte-identical to what this method produced before this change. There is no
     * throw, no refusal and no partial path. THE REASON IS A RANKING, NOT AN OVERSIGHT: this insert
     * is `allOrNone = true` and rides inside the user's own stage change, so ANY failure here rolls
     * that stage change back. An NDA that exists but names no broker is a row a human completes in
     * five seconds from the related list; a stage change refused because a broker was not appointed
     * yet is a wall in front of a legitimate workflow, surfaced from an object the user never
     * mentioned. Auto-create's whole job is that the record EXISTS; completeness is second.
     * ⚠ A CONSEQUENCE, STATED SO IT IS NOT LATER FILED AS A BUG: nothing back-fills. An NDA created
     * before the broker was appointed keeps `Broker__c = null` forever unless a human sets it —
     * this method runs once, on stage ENTRY, and the idempotency key above guarantees it never
     * revisits the row. Identical shape and identical accepted trade to
     * `DispositionOfferFormService`'s "no broker appointed yet" path, which lets an offer be logged
     * in the same window.
     *
     * ── ⚠ THE ONE RESIDUAL, NAMED RATHER THAN HIDDEN: THE LOOKUP FILTER ────────────────────────
     * `NDA__c.Broker__c` carries an ACTIVE, NON-OPTIONAL lookup filter
     * (`Contact.RecordType.DeveloperName = 'Broker'`), and a required lookup filter is enforced on
     * API/Apex saves, not only in the UI. Every broker this method can resolve came out of a field
     * carrying THE SAME filter (`Disposition__c.Broker__c` and `BOV_Submission__c.Broker__c` are
     * byte-for-byte the same `<lookupFilter>`), so the value is filter-valid by construction.
     * The one vector that breaks that is a Contact being moved OFF the Broker record type AFTER the
     * source lookup was set — the source rows keep the now-invalid reference, and this insert would
     * then fail and roll back the stage change. ⚠ THIS IS NOT THE ONLY WAY THIS INSERT CAN ROLL A
     * STAGE CHANGE BACK — see the record-type note immediately below, which is the one that
     * actually happened. It is not defended here: defending it means either
     * a Contact query per chunk (re-implementing a declarative filter in Apex, which then drifts
     * from it) or a two-phase insert whose second phase no test can reach. It is also not measured
     * — the state is unreachable through any UI or API path this application offers, because both
     * source fields refuse a non-broker Contact on their own save. Recorded so the next reader of a
     * `FIELD_FILTER_VALIDATION_EXCEPTION` from a stage change knows where to look.
     *
     * ── 🔴 THE RECORD-TYPE STAMP IS GUARDED ON isActive(), NOT ON isAvailable() ──
     * ⚠ ADDED 2026-08-25, and it is the first time this block states its stamp's guard at all —
     * the LOI and PSA blocks carried the argument and this one silently inherited it, which is the
     * W1 mistake the class header warns about. The guard was `isAvailable()` (the RUNNING USER's
     * record-type visibility) until DISP-0025; the measurement that forced the change and the
     * residual it leaves are argued ONCE, at the LOI block. They apply here unchanged, because the
     * helper is shared and because THIS block sits in the same approver cascade — an approval that
     * advances a disposition to `NDA` executes this insert as a read-only principal, and
     * `isAvailable()` is false for that principal.
     *
     * ⚠ WHAT DIFFERS HERE, AND IT IS THE ONLY REASON THIS BLOCK HAS NOT BLOWN UP TOO:
     * `Status__c = 'Prepare'`. An unstamped row lands on whatever default record type the running
     * user has, and if that type's value set excludes the seed value this insert throws
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST exactly as the LOI's did — `NDA__c.Status__c` is
     * `restricted`, and this repo has now measured four times that DML enforces record-type
     * restriction rather than leaving it to the UI. Whether it throws is therefore a property of
     * TODAY'S value sets, not of this block. Do not read the absence of an incident as safety.
     */
    private static void openBuyerNdas(Map<Id, Disposition__c> entrants) {
        if (entrants.isEmpty()) {
            return;
        }
        // One query for the whole chunk — never one per record.
        for (NDA__c existing : NdaSelector.selectByDispositionIds(entrants.keySet())) {
            if (BUYER_ROLE.equals(existing.Party_Role__c)) {
                entrants.remove(existing.Disposition__c);
            }
        }
        if (entrants.isEmpty()) {
            return;
        }

        // 🔴 RESOLVED **AFTER** THE EARLY RETURN ABOVE, AND THE ORDER IS THE BUDGET. Every
        // suppressed entrant is one this method will not insert, so resolving a broker for it would
        // be a query bought for a row that is never written. It is also what keeps the documented
        // "EXACTLY ONE query for 251 dispositions on the suppression path" property true — moving
        // this line above the return is the change that falsifier exists to catch.
        Map<Id, Id> brokerByDisposition = resolveBrokers(entrants);

        // Resolved ONCE for the whole chunk — a describe per record would be 251 describes for an
        // answer that cannot vary within a transaction.
        Id recordTypeId = recordTypeIdFor(NDA__c.SObjectType, DISPOSITION_NDA_RECORD_TYPE);
        List<NDA__c> toInsert = new List<NDA__c>();
        for (Id dispositionId : entrants.keySet()) {
            NDA__c nda = new NDA__c(
                Disposition__c = dispositionId,
                Status__c = DISPOSITION_NDA_INITIAL_STATUS,
                Party_Role__c = BUYER_ROLE,
                // ⚠ ASSIGNED UNCONDITIONALLY, INCLUDING WHEN IT IS NULL, AND THAT IS DELIBERATE.
                // A `Map.get` miss returns null, and null into a lookup on a NEW record is
                // identical to leaving the field unset — so an `if (brokerId != null)` guard would
                // add a branch with no behavioural difference and one more uncovered line. The
                // unresolvable case is expressed by the map having no entry, not by a conditional.
                Broker__c = brokerByDisposition.get(dispositionId)
            );
            if (recordTypeId != null) {
                nda.RecordTypeId = recordTypeId;
            }
            toInsert.add(nda);
        }

        // ⚠ EXPLICIT SYSTEM MODE — obstacle 1 of 2 for THIS block. The disposition persona holds
        // allowEdit and NOT allowCreate on NDA__c by decision D16.1, and the running user may
        // additionally be an APPROVER who is read-only on both objects. NDA__c is not the record
        // under approval, so it is not locked and inserts fine here; the user sees the NDA
        // immediately.
        //
        // allOrNone = true, matching the LOI block in OpportunityReviewService. The trade is
        // deliberate: if the NDA cannot be created, the stage change that was supposed to open it
        // is rolled back rather than leaving an off-market disposition sitting at `NDA` with
        // nothing to sign — a state the All_NDAs_Signed_Before_Progression gate would then read as
        // "no NDAs collected" and block on anyway, but silently and one stage later.
        Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);

        Map<Id, Id> ndaByDisposition = new Map<Id, Id>();
        for (NDA__c nda : toInsert) {
            ndaByDisposition.put(nda.Disposition__c, nda.Id);
        }

        // 🔴 OBSTACLE 2 OF 2 — THE BACK-STAMP MUST BE ASYNC, AND IT IS A LOCK, NOT A PERMISSION.
        // See the class header and LoiPrimaryStampQueueable's, which records the two failed
        // attempts (bare DML -> TypeException; SYSTEM_MODE -> ENTITY_IS_LOCKED) that produced
        // this pattern.
        //
        // 🔴 THIS HALF EXISTS ONLY BECAUSE `Disposition__c.Primary_NDA__c` EXISTS. It is the only
        // Primary_* lookup on the object — there is no Primary_LOI__c and no Primary_Contract__c —
        // which is exactly why the LOI and PSA blocks below have no Queueable and must not be
        // given one.
        //
        // The enqueue is GUARDED exactly as OpportunityReviewService's is: this trigger can fire
        // inside an async context that has already spent its chained-job budget (the async cap is
        // 1), and an uncaught LimitException here would roll back the stage change — or the
        // approval — it is riding on.
        //
        // ⚠ RESIDUAL, STATED RATHER THAN HIDDEN: when the budget IS exhausted the stamp is
        // silently skipped and Primary_NDA__c stays null. The NDA itself still exists and is
        // still reachable from the disposition's related list, so nothing is lost — but anything
        // that resolves THROUGH the lookup finds nothing. Identical trade, identical wording, to
        // the LOI block; if it ever needs closing, close both.
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new DispositionNdaStampQueueable(ndaByDisposition));
        }
    }

    /**
     * The appointed broker Contact for each entrant, resolved PER RECORD TYPE — the source of
     * `NDA__c.Broker__c` on every auto-created buyer NDA (2026-08-21). See `openBuyerNdas` for why
     * the two record types have two different sources and why an unresolved broker is a normal
     * answer rather than a failure.
     *
     * ── 🔴 AT MOST **ONE** QUERY, AND ZERO WHEN THE CHUNK IS ALL OFF-MARKET ────────────────────
     * The off-market broker is already on `Trigger.new` (`Disposition__c.Broker__c`), so that half
     * costs nothing at any record count. The on-market half is ONE set-based selector call for the
     * whole chunk, issued only when the chunk actually contains an on-market entrant. So a 251-row
     * off-market chunk adds zero queries and a 251-row on-market chunk adds exactly one — the
     * constancy property the rest of this class asserts, extended rather than broken.
     * ⚠ THE `onMarketIds.isEmpty()` RETURN IS NOT A MICRO-OPTIMISATION. `selectSelectedBrokerBy‑
     * DispositionIds` is itself empty-safe, so removing this line would not change the RESULT — it
     * would change the COST, from 0 queries to 1, on the off-market path that every existing
     * governor test in this suite measures. Keep it.
     *
     * ── 🔴 FIRST NON-NULL WINS, AND THE "NON-NULL" HALF LIVES IN THE SELECTOR ──────────────────
     * Exclusivity of the `Selected` submission is a SERVER invariant maintained by
     * `BovSubmissionService.replaceSelectedBroker`, not a schema constraint, so a disposition with
     * TWO `Selected` rows is a reachable data defect rather than an impossibility. The selector
     * returns them oldest-first under a TOTAL order (`CreatedDate ASC, Id ASC`) and filters out
     * rows whose `Broker__c` is null, so the `containsKey` guard below resolves the same broker on
     * every run and can never resolve a null over a real one. Do not "simplify" it to an
     * unconditional `put` — that would silently make the NEWEST duplicate win, disagreeing with
     * `DispositionOfferFormService`, which takes `[0]` from the same ordering for the same
     * disposition.
     *
     * ── ⚠ THE OFF-MARKET BRANCH IS FLS-FREE BY CONSTRUCTION, WHICH THE ON-MARKET ONE IS NOT ────
     * Reading `d.Broker__c` off an in-memory `Trigger.new` sObject is not an FLS-checked operation
     * at all, so the off-market half works for every persona unconditionally. The on-market half is
     * a SOQL read and needed an explicit mode decision — `WITH SYSTEM_MODE`, argued at the selector
     * method, on the measured ground that `DPEG_Admin_Access` holds no `FieldPermissions` row for
     * `BOV_Submission__c.Broker__c` at all (re-verified live 2026-08-21). Two halves, two access
     * stories; do not describe them as one.
     *
     * @param entrants Dispositions that just entered `NDA` and do NOT already have a buyer NDA,
     *                 as WHOLE records — this method reads `RecordTypeId` and `Broker__c` off them.
     * @return dispositionId -> broker Contact Id, containing an entry ONLY for the dispositions
     *         whose broker could be resolved. A disposition absent from this map is the normal
     *         "no broker appointed yet" case and its NDA is created with a null broker.
     */
    private static Map<Id, Id> resolveBrokers(Map<Id, Disposition__c> entrants) {
        Map<Id, Id> brokerByDisposition = new Map<Id, Id>();
        // ONE describe for the whole chunk, and null is a legitimate answer — see recordTypeIdFor.
        // A null here sends EVERY entrant down the off-market branch, which degrades to "no broker
        // resolved" rather than to a wrong broker.
        Id onMarketRecordTypeId = recordTypeIdFor(Disposition__c.SObjectType, ON_MARKET_RECORD_TYPE);
        Set<Id> onMarketIds = new Set<Id>();
        for (Disposition__c d : entrants.values()) {
            if (onMarketRecordTypeId != null && onMarketRecordTypeId == d.RecordTypeId) {
                onMarketIds.add(d.Id);
            } else if (d.Broker__c != null) {
                brokerByDisposition.put(d.Id, d.Broker__c);
            }
        }
        if (onMarketIds.isEmpty()) {
            return brokerByDisposition;
        }
        // One query for the whole chunk — never one per record.
        for (BOV_Submission__c selected
             : BovSubmissionSelector.selectSelectedBrokerByDispositionIds(onMarketIds)) {
            if (!brokerByDisposition.containsKey(selected.Disposition__c)) {
                brokerByDisposition.put(selected.Disposition__c, selected.Broker__c);
            }
        }
        return brokerByDisposition;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // `LOI` STAGE — the sell-side LOI. Tranche 3B fix pass (review C1).
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Opens one disposition LOI per entrant.
     *
     * ── 🔴 THE DML MODE, RE-ARGUED FROM SCRATCH. IT IS NOT INHERITED FROM THE NDA BLOCK. ──
     * Three questions, answered independently, because the NDA block's answers are right there for
     * the copying and two of its three premises do not hold here.
     *
     * 1. CRUD — SYSTEM_MODE IS REQUIRED. `DPEG_Disposition_Edit` grants `LOI__c`
     *    `allowCreate = false` (measured in the permission-set file, alongside allowEdit = true /
     *    allowRead = true), on the same premise D16.1 set for `NDA__c`: creation is this trigger's
     *    job. A `USER_MODE` insert therefore fails for the exact persona the feature exists for.
     *
     * 2. FLS — SYSTEM_MODE IS REQUIRED AGAIN, INDEPENDENTLY, AND THIS LEG SURVIVES EVEN IF SOMEONE
     *    LATER GRANTS allowCreate. `LOI__c.Disposition__c` is a Tranche 3B field, and a
     *    Metadata-API-deployed custom field arrives with NO field permissions for ANY profile,
     *    System Administrator included. Under `USER_MODE` the insert would be refused for
     *    EVERYONE — including the admin who deployed it — on the one field that makes the row a
     *    disposition LOI at all. Measured on the READ side of this very field on 2026-08-09
     *    (`System.QueryException: No such column 'Disposition__c' on entity 'LOI__c'`).
     *
     * 3. THE APPROVAL LOCK. 🔴 THIS ENTIRE POINT'S CONCLUSION REVERSED ON 2026-08-25 AND THE OLD
     *    TEXT IS RETRACTED VERBATIM RATHER THAN DELETED, because it was quoted in three other
     *    places and a reader who finds one of those copies needs to be able to date it.
     *      (a) 🔴 RETRACTED, verbatim: "THERE IS NO PARENT WRITE AT ALL. `Disposition__c` has no
     *          `Primary_LOI__c` — repo grep: `Primary_NDA__c` is the only Primary_* field on the
     *          object. The NDA block's Queueable exists SOLELY because `SYSTEM_MODE` does not lift
     *          an approval lock and it writes back to the locked parent. With nothing to write
     *          back, there is nothing to defer: a Queueable here would be a job that does nothing,
     *          and a reader would take its existence as evidence of a hazard that is not present."
     *          THE PREMISE DIED: `Primary_LOI__c` and `Primary_PSA__c` were added to
     *          `Disposition__c` on 2026-08-25 so the LOI/PSA Details sections could be NATIVE
     *          `fieldSection`s spanning formula fields, replacing an Apex-backed LWC. There is now
     *          a parent write, so this block enqueues
     *          `DispositionPrimaryChildStampQueueable` — see that class's header, which re-argues
     *          the deferral from scratch (approval lock + re-entrancy) rather than inheriting the
     *          NDA block's reasoning, and which also documents why it escapes SHARING where the
     *          NDA twin does not.
     *          ⚠ (b) AND (c) BELOW ARE UNAFFECTED AND STILL TRUE. They establish that `LOI` is not
     *          any approval's ENTRY stage, which is why the lock is an EDGE case here
     *          (`recordEditability = AdminOnly` still lets an administrator re-stage a record
     *          mid-approval) rather than the common one it is on the NDA path. An edge case is
     *          still a case; it is handled the same way.
     *      (b) `LOI` IS NOT ANY APPROVAL'S ENTRY STAGE. Read from the three Disposition-target
     *          approvalProcess files: `Sale_Decision_Approval` keys on `Disposition Readiness`,
     *          `Broker_Selection_Approval` on `Broker Selection` AND record type Off Market,
     *          `Closing_Approval` on `Closing` AND wire-verified. So entering `LOI` never coincides
     *          with an approval starting or finishing.
     *          ⚠ Two of those three criteria were rewritten on 2026-08-19; the conclusion did not
     *          move, because `LOI` was on none of the old set either.
     *      (c) 🔴 THIS POINT'S PREMISE DIED ON 2026-08-19 AND IS REPLACED, NOT PATCHED. RETRACTED,
     *          verbatim: "NONE OF THE THREE APPROVALS PERFORMS A FIELD UPDATE AT ALL (zero
     *          FieldUpdate elements across all three files), so `Disposition_Stage__c` is only ever
     *          moved to `LOI` by a human edit or a data load — never by an approval process's own
     *          field update running as a read-only APPROVER."
     *          ALL THREE NOW CARRY `finalApprovalActions`, and a fourth transition into `LOI` now
     *          exists that no human performs: `Offer_Selection_Approval` on the child
     *          `Disposition_Offer__c` moves the parent here (`DispositionOfferTriggerHandler`).
     *          THE CONCLUSION SURVIVES ANYWAY, AND FOR A BETTER REASON THAN "IT NEVER HAPPENS":
     *          neither writer runs as the approver's user context in a way that reaches this insert.
     *          The three Disposition approvals write ONLY the `Approval_Advance_Pending__c` boolean;
     *          the actual stage write is `DispositionApprovalAdvanceQueueable`'s
     *          `Database.update(..., AccessLevel.SYSTEM_MODE)`, and the child-approval path is
     *          likewise a SYSTEM_MODE update. This block's own insert is SYSTEM_MODE too (points 1
     *          and 2), so it is indifferent to whose context re-fires the trigger. What WOULD have
     *          broken it is the design that was REJECTED — a direct approval FieldUpdate on
     *          `Disposition_Stage__c`, or an approval-triggered Flow running as the approver. See
     *          `DispositionApprovalAdvanceService`'s header for why neither was used.
     *    ⚠ ONE HONEST CAVEAT: `recordEditability = AdminOnly` means an ADMIN can still edit — and
     *    therefore re-stage — a disposition while an approval is pending. Even on that path the
     *    conclusion holds: the child is not the record under approval so it is not locked, and
     *    there is still no parent write to throw.
     *
     * 4. allOrNone = true, matching the NDA block but for its own reason. With `false`, a failed
     *    insert would leave the disposition parked at `LOI` with no negotiation record and NOTHING
     *    downstream would notice — unlike the NDA case, where All_NDAs_Signed_Before_Progression
     *    would at least block the next hop. A refused stage change is loud; an empty `LOI` stage is
     *    silent, and silence is the failure mode this whole tranche keeps paying for.
     *
     * ── IDEMPOTENCY: SIMPLE PRESENCE ─────────────────────────────────────────
     * "This disposition already has an LOI" is the whole test — there is no Party_Role__c
     * equivalent and only one kind of disposition LOI. ⚠ Deliberately NOT scoped to the
     * Disposition_LOI record type, for the same reason as the NDA block: in the window before gate
     * T-A1 a disposition LOI can legitimately sit on MASTER, and a record-type-scoped check would
     * mint a second one. The `Disposition__c` lookup is the key.
     *
     * ⚠ CONSEQUENCE WORTH STATING: a second buyer on the same disposition does NOT get a second
     * auto-created LOI. That is correct for auto-create (re-entering the stage must not duplicate)
     * and it means a genuine second-round LOI is a hand-created record, exactly as a broker NDA is.
     *
     * ── 🔴 THE RECORD-TYPE STAMP IS GUARDED ON isActive(), NOT ON isAvailable() ──
     * ⚠ CHANGED 2026-08-25: the guard asked about the RUNNING USER's record-type VISIBILITY
     * (`isAvailable()`) until it took production down on this exact block. This is the canonical
     * argument for all three stamps in this file — the NDA block, the PSA block and
     * `recordTypeIdFor` point HERE rather than re-deriving it, because the change is one line in
     * the shared helper and re-arguing it three times would invite three different answers.
     *
     * MEASURED 2026-08-25 on usman-dpeg — DISP-0025 / OFFER-0012, approver Nikhil Dhanani, FINEST
     * log 07Liw000000I1vJEAS. The Principal persona (`DPEG_Principal_PSG` -> `DPEG_Disposition_View`,
     * which carried NO `recordTypeVisibilities` at all) approves an offer;
     * `DispositionOfferTriggerHandler` moves the parent to `LOI` AS THE APPROVER; `isAvailable()`
     * is FALSE for them, so the stamp silently no-ops; the LOI is built as {Disposition__c,
     * Stage__c = 'Received', Selected_Offer__c} with NO RecordTypeId, lands on the ACQUISITION
     * default type, and the `Database.insert` below throws
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST … Received: [Stage__c]` — rolling back the
     * approver's whole parent update.
     *
     * 🔴 SO THE GUARD DID NOT DEGRADE, IT DETONATED, AND IT DID SO IN EXACTLY THE FAILURE MODE IT
     * WAS CHOSEN TO PREVENT: "the user's own stage change rolled back with a raw platform error".
     * The retracted text below promised that outcome for the UNGUARDED stamp; the availability
     * guard produced it instead, one error code over. Admins (all types visible) and every test in
     * this repo (admin test-running user) never reach it — which is why it shipped.
     *
     * ⚠ isActive(), NOT UNCONDITIONAL. A record type that does not exist, or that is INACTIVE, is
     * still null, still an unstamped row, still not a throw — the whole null-is-a-legitimate-answer
     * contract below is unchanged. What changed is only this: an automation insert made ON A
     * PRINCIPAL'S BEHALF no longer asks a question about that principal's UI record-type
     * visibility, because that is not a question the DML it feeds is asking either.
     *
     * ── ⚠ THE RESIDUAL IS THE OLD MEASUREMENT, KEPT RATHER THAN DELETED ──────
     * RETAINED VERBATIM, MEASURED 2026-08-09 on usman-dpeg and reproduced 2026-08-10 (stack in
     * `TestDataFactory.recordTypeId`'s header): "an UNGUARDED RecordTypeId stamp throws
     * INVALID_CROSS_REFERENCE_KEY where a guarded one silently no-ops, and a record type assigned
     * to no profile resolves a real Id while being available to nobody — administrators included,
     * because Modify All Data is an OBJECT permission and confers no record-type access."
     * THAT FACT IS NOT RETRACTED, and it is now this block's residual risk: a record type DEPLOYED
     * BUT ASSIGNED TO NOBODY becomes a throw here where it used to be a silent no-op. Two things
     * bound it, and neither is a reason to put the availability guard back:
     *   (a) 🔴 STILL UNDETERMINED — both reproductions were on a BARE `insert`; this insert is an
     *       explicit `AccessLevel.SYSTEM_MODE` one, and whether SYSTEM_MODE accepts an unavailable
     *       record type has never been measured (OpportunityReviewService's header records the
     *       same open question against its own LOI insert). The new test
     *       `loiStampsTheDispositionTypeForARecordTypeBlindPrincipal` is the experiment that
     *       settles it: if it REDS with INVALID_CROSS_REFERENCE_KEY instead of passing, then
     *       record-type visibility IS enforced under SYSTEM_MODE, this change is wrong, and the
     *       permission-set grant is the only fix. Read the failure, do not soften the test.
     *   (b) `DPEG_Disposition_View` gained the five `recordTypeVisibilities` entries on 2026-08-25,
     *       so "assigned to nobody" is not this org's state for these three types today. That grant
     *       and this change are belt and braces on purpose: either alone fixes DISP-0025, and the
     *       code half is the one that also covers a principal nobody has provisioned yet.
     *
     * 🔴 WHAT AN UNSTAMPED LOI COSTS WHEN THE TYPE IS GENUINELY ABSENT — the NDA's cost, not the
     * PSA's. A Master-type disposition LOI seeds at 'Received', RecordStageAdvanceService falls
     * back to the ACQUISITION sequence, and that map has no 'Received' entry — so Advance Stage and
     * both loop actions refuse and the record cannot move at all. Visible on the record, like the
     * NDA; the remedy is deploying the record type, not a code change.
     */
    private static void openDispositionLois(Set<Id> entrants) {
        if (entrants.isEmpty()) {
            return;
        }
        for (LOI__c existing : LoiSelector.selectByDispositionIds(entrants)) {
            entrants.remove(existing.Disposition__c);
        }
        if (entrants.isEmpty()) {
            return;
        }

        // ⚠ READ AFTER THE IDEMPOTENCY EARLY RETURN, NOT BEFORE — deliberately, and there is a
        // test that fails if it moves. `loiSuppressionPathCostsOneQueryAndNoDmlAt251` asserts
        // EXACTLY ONE query on the suppression path; a chunk where every disposition already has
        // its LOI must still cost 1, not 2. See the class header's budget paragraph.
        // ONE set-based read for the whole chunk, so this is constant in the number of
        // dispositions, not per-record.
        Map<Id, Id> offerByDisposition =
            DispositionOfferSelector.selectNewestSelectedIdByDispositionIds(entrants);

        Id recordTypeId = recordTypeIdFor(LOI__c.SObjectType, DISPOSITION_LOI_RECORD_TYPE);
        List<LOI__c> toInsert = new List<LOI__c>();
        for (Id dispositionId : entrants) {
            LOI__c loi = new LOI__c(
                Disposition__c = dispositionId,
                Stage__c = DISPOSITION_LOI_INITIAL_STAGE,
                // ⚠ ASSIGNED UNCONDITIONALLY, INCLUDING WHEN IT IS NULL, for the same reason the
                // NDA block's Broker__c is: a `Map.get` miss returns null, and null into a lookup
                // on a NEW record is identical to leaving the field unset, so an `if` guard would
                // add a branch with no behavioural difference and one more uncovered line.
                // 🔴 AND NULL MUST NEVER BLOCK THE INSERT. A disposition can legitimately reach
                // `LOI` with no selected offer (an off-market deal that ran no offer round). The
                // link is a convenience; the LOI is the record the stage exists for.
                Selected_Offer__c = offerByDisposition.get(dispositionId)
            );
            if (recordTypeId != null) {
                loi.RecordTypeId = recordTypeId;
            }
            // ⚠ Opportunity__c is deliberately left NULL. A disposition LOI hangs off
            // Disposition__c only, and that blank is what CounterOfferService.isSaleSide falls back
            // to while every row still sits on Master. Populating it would make the LOI look
            // buy-side to every consumer that checks the lookup.
            toInsert.add(loi);
        }
        Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);

        // 🔴 THE PARENT STAMP — SEE POINT 3 ABOVE, WHICH THIS CHANGE REWROTE RATHER THAN IGNORED.
        // The line that stood here until 2026-08-25 read, verbatim: "NO PARENT STAMP AND NO
        // QUEUEABLE — see point 3 above. Do not add one 'for symmetry'." It was correct while
        // `Disposition__c` had no `Primary_LOI__c`. It does now, so there IS a parent write, and
        // this is NOT symmetry — it is the same hazard the NDA block faces, reached by the same
        // route. `DispositionPrimaryChildStampQueueable`'s header argues it from scratch.
        //
        // The enqueue is GUARDED exactly as the NDA block's is: this trigger can fire inside an
        // async context that has already spent its chained-job budget (the async cap is 1), and an
        // uncaught LimitException here would roll back the stage change it is riding on.
        //
        // ⚠ RESIDUAL, STATED RATHER THAN HIDDEN AND IDENTICAL TO THE NDA BLOCK'S: when the budget
        // IS exhausted the stamp is silently skipped and `Primary_LOI__c` stays null. The LOI
        // itself still exists and is still reachable from the disposition's LOIs related list, but
        // the LOI-stage Details section — which renders formula fields spanning this lookup — goes
        // BLANK. If that residual ever needs closing, close all three stamps together.
        Map<Id, Id> loiByDisposition = new Map<Id, Id>();
        for (LOI__c loi : toInsert) {
            loiByDisposition.put(loi.Disposition__c, loi.Id);
        }
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new DispositionPrimaryChildStampQueueable(
                loiByDisposition,
                DispositionPrimaryChildStampQueueable.PrimaryLookup.PRIMARY_LOI
            ));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // `PSA` STAGE — the sell-side PSA / Contract Review. Tranche 3C fix pass (review C1).
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Opens one disposition Contract Review per entrant.
     *
     * ── 🔴 THE DML MODE — SAME FOUR QUESTIONS, ANSWERED FOR THIS OBJECT ──────
     * 1. CRUD: `DPEG_Disposition_Edit` grants `Contract_Review__c` `allowCreate = false` (measured
     *    in the permission-set file, alongside allowEdit = true / allowRead = true, and argued
     *    there on the D16.1 premise that creation is this trigger's job). SYSTEM_MODE required.
     * 2. FLS: `Contract_Review__c.Disposition__c` is a Tranche 3C field with no field permissions
     *    for any profile, System Administrator included. SYSTEM_MODE required independently, and
     *    this leg survives a later `allowCreate` grant.
     * 3. APPROVAL LOCK. 🔴 REVERSED 2026-08-25, exactly as the LOI block's point 3(a) was — read
     *    that one, it carries the full retraction. RETRACTED, verbatim: "does not apply.
     *    `Disposition__c` has no `Primary_Contract__c` so there is NO PARENT WRITE; and `PSA` is
     *    not any approval's entry stage (`Sale_Decision` = `Disposition Readiness`,
     *    `Broker_Selection` = `Broker Selection` + Off Market, `Closing_Approval` = `Closing` +
     *    wire-verified). No Queueable, and adding one would assert a hazard that is not there."
     *    The SECOND clause is still true — `PSA` is still no approval's entry stage — but the
     *    FIRST is dead: `Disposition__c.Primary_PSA__c` exists as of that date (note the name: it
     *    is `Primary_PSA__c`, not the `Primary_Contract__c` this retracted text guessed at, which
     *    is the Opportunity twin's name). This block therefore enqueues
     *    `DispositionPrimaryChildStampQueueable` with `PrimaryLookup.PRIMARY_PSA`.
     *    ⚠ TWO CLAUSES HERE WERE REWRITTEN ON 2026-08-19. The entry-criteria list moved
     *    (`Broker_Selection` no longer keys on `BOV Outreach`), and the third clause is RETRACTED
     *    verbatim: "none of the three approvals performs a field update, so the stage is only ever
     *    entered by a human edit or a data load, never by an approval running as a read-only
     *    approver." All three now carry `finalApprovalActions`. The conclusion is unaffected for
     *    the same reason as the LOI block's point 3(c) — those actions write only a boolean, and
     *    the stage write is a SYSTEM_MODE `Database.update` from a Queueable, not an approval
     *    field update running as the approver. `PSA` is in any case reached from `LOI` by the
     *    manual Advance to PSA action, which no approval owns.
     * 4. allOrNone = true: an empty `PSA` stage is silent, a refused stage change is loud.
     *
     * ── 🔴 THE INITIAL VALUE IS Negotiation_Status__c, NEVER Stage__c ─────────
     * `Stage__c` on this object is recomputed by the active before-save flow
     * `Contract_Review_Stage_Sync`, so writing it commits and is silently discarded. See
     * DISPOSITION_PSA_INITIAL_STATUS. This is the one shape difference between this block and the
     * LOI block, and it is a property of the OBJECT, not of the side of the deal.
     *
     * ⚠ Opportunity__c IS DELIBERATELY LEFT NULL, AND HERE THAT IS LOAD-BEARING RATHER THAN MERELY
     * TIDY. `ContractExecutionService.handleExecution` runs its acquisition arm off
     * `Opportunity__c` and its disposition arm off `Disposition__c`, through two independent `if`s
     * — so a row carrying BOTH parents runs BOTH arms and an executed sell-side PSA would stamp an
     * Opportunity and arm a Day-0 Transaction fan-out on a deal that is not being bought. The
     * Disposition_PSA record type file records the same blank as load-bearing for the same reason.
     *
     * ── IDEMPOTENCY: SIMPLE PRESENCE, NOT SCOPED TO THE RECORD TYPE ──────────
     * 🔴 THE UNSCOPED CHECK MATTERS MORE ON THIS OBJECT THAN ON THE OTHER TWO. ⚠ THE PREMISE THAT
     * USED TO CARRY THAT SENTENCE DIED ON 2026-08-14 (observation 7 / review C9); the CONCLUSION
     * did not, so the check is unchanged and must stay unchanged. RETRACTED, verbatim: "Both PSA
     * record types expose the IDENTICAL four `Negotiation_Status__c` values, so a Master-type
     * disposition PSA walks its whole path correctly and looks completely normal — it is wrong only
     * about which PERSONA may drive it."
     *
     * Observation 7 split the sequences — acquisition `Draft -> Negotiation -> Signed -> Executed`,
     * disposition `Initial Draft -> Revised -> Ready for Execution -> Executed`, sharing only the
     * terminal 'Executed'. So a Master-type disposition PSA no longer looks normal at all: it falls
     * to RecordStageAdvanceService's defaultTypeKey, which is the ACQUISITION map, finds no entry
     * for its own 'Initial Draft', and is REFUSED on its first Advance Stage click naming that
     * status. See that class's header ("the fallback used to be the quietest of the three, and
     * observation 7 made it the loudest").
     *
     * 🔴 THE CHECK STAYS UNSCOPED, AND THE SPLIT MAKES THAT MORE RIGHT RATHER THAN LESS. A
     * record-type-scoped check would still mint a SECOND, duplicate PSA against the Master-type
     * first one — and the duplicate would carry Disposition_PSA, so it would advance perfectly
     * while the original stayed stuck. That is strictly worse than before: the refusal is now the
     * loud symptom pointing at gate T-B, and a working duplicate beside it reads as "the old row is
     * odd" rather than "this row was never migrated", masking the one signal the migration has.
     *
     * ── ⚠ THE RECORD-TYPE STAMP IS GUARDED ON isActive() ─────────────────────
     * ⚠ CHANGED 2026-08-25 with the other two blocks — the guard was `isAvailable()`. The full
     * argument, the DISP-0025 measurement that forced it and the residual it leaves are at the LOI
     * block above; do not re-derive them here. What is specific to THIS block: the same approver
     * cascade reaches it (`PSA` is entered from `LOI`), and this insert seeds
     * `Negotiation_Status__c = 'Initial Draft'`, which observation 7 split OFF the acquisition
     * value set — so an unstamped disposition PSA landing on the ACQUISITION default type would be
     * the same restricted-picklist rollback the LOI block measured, not merely a quiet mis-typing.
     * ⚠ INFERRED FROM THE LOI MEASUREMENT, NOT SEPARATELY MEASURED: the DISP-0025 transaction never
     * reached `PSA`. It lands on MASTER — which exposes every value and therefore inserts fine —
     * whenever MASTER is the running user's default, which is what the paragraph below assumes and
     * what makes the two costs differ.
     *
     * 🔴 BE HONEST THAT THE COST OF AN UNSTAMPED ROW IS QUIETER HERE, exactly as review J1 says of the sibling fallback in
     * RecordStageAdvanceService: a Master-type disposition PSA is not dead — it advances fine and
     * every toast is right — it is simply un-advanceable by the DISPOSITION persona and perfectly
     * advanceable by an acquisitions one, because the gate is picked off the record type. Nothing
     * in the system will notice. The remedy is post-deploy gate T-A1 plus its persona step, not a
     * code change; the record-type read-back test is the only permanent falsifier.
     */
    private static void openDispositionContractReviews(Set<Id> entrants) {
        if (entrants.isEmpty()) {
            return;
        }
        for (Contract_Review__c existing : ContractReviewSelector.selectByDispositionIds(entrants)) {
            entrants.remove(existing.Disposition__c);
        }
        if (entrants.isEmpty()) {
            return;
        }

        // ⚠ AFTER the idempotency early return, same reason as the LOI block: a fully-suppressed
        // chunk must still cost exactly ONE query. One set-based read for the whole chunk.
        Map<Id, Id> offerByDisposition =
            DispositionOfferSelector.selectNewestSelectedIdByDispositionIds(entrants);

        Id recordTypeId =
            recordTypeIdFor(Contract_Review__c.SObjectType, DISPOSITION_PSA_RECORD_TYPE);
        List<Contract_Review__c> toInsert = new List<Contract_Review__c>();
        for (Id dispositionId : entrants) {
            Contract_Review__c cr = new Contract_Review__c(
                Disposition__c = dispositionId,
                Negotiation_Status__c = DISPOSITION_PSA_INITIAL_STATUS,
                // ⚠ Unconditional, null included — see the LOI block for why an `if` guard here
                // would be a branch with no behavioural difference. Null must never block the
                // insert: the Contract Review is the record the stage exists for, the offer link
                // is a convenience.
                Selected_Offer__c = offerByDisposition.get(dispositionId)
            );
            if (recordTypeId != null) {
                cr.RecordTypeId = recordTypeId;
            }
            toInsert.add(cr);
        }
        Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);

        // 🔴 THE PARENT STAMP. The line that stood here until 2026-08-25 read, verbatim: "NO
        // PARENT STAMP AND NO QUEUEABLE — see point 3 above." True while `Disposition__c` had no
        // `Primary_PSA__c`; it has one now. Same hazard, same guard, same residual as the LOI
        // block immediately above — read its comment rather than re-deriving this one.
        Map<Id, Id> psaByDisposition = new Map<Id, Id>();
        for (Contract_Review__c cr : toInsert) {
            psaByDisposition.put(cr.Disposition__c, cr.Id);
        }
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new DispositionPrimaryChildStampQueueable(
                psaByDisposition,
                DispositionPrimaryChildStampQueueable.PrimaryLookup.PRIMARY_PSA
            ));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // `Release Materials` STAGE — the per-buyer materials date. Tranche 2 Workstream D (D6.1).
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Default-stamps `NDA__c.Materials_Released_Date__c = TODAY` on every BUYER-ROLE NDA of each
     * entrant that does not already carry a date.
     *
     * 🔴 THIS IS THE ONE BLOCK IN THIS FILE THAT CREATES NOTHING. It UPDATES existing children.
     * Every `open*` sibling asks "does a child exist?" and inserts if not; this asks "is a field
     * blank?" and fills if so. Do not harmonise it into the `open*` family — the questions, the
     * idempotency keys and the failure modes are all different.
     *
     * ── 🔴 WHY THE FIELD IS BOTH ANALYST-ENTERED **AND** MACHINE-DEFAULTED (design D6.1) ──────
     * A PURE DEFAULT cannot express *"materials went to buyer A on Tuesday and buyer B on Friday"*,
     * which is the entire point of tracking this per-NDA rather than once on the parent. A PURE
     * MANUAL FIELD would be blank on most rows and the timeline's MIDDLE HOP would simply disappear
     * — and with it both duration columns, since each is an arithmetic over this date. The default
     * gives the correct value for the common case (everyone gets the package when the sale enters
     * `Release Materials`) and the analyst overrides the exceptions.
     *
     * ── 🔴 BLANK-ONLY AND IDEMPOTENT. NEVER UNCONDITIONAL. THREE INDEPENDENT REASONS ──────────
     * 1. IT WOULD DESTROY REAL DATA. An analyst who recorded the true release date by hand before
     *    advancing the stage would have it silently replaced with "today". Same class of silent loss
     *    `stampListingDates` refuses for `Listing_Date__c`, for the same reason.
     * 2. IDEMPOTENCY. Stepping back out of `Release Materials` and forward again must not restamp.
     *    The `createStageEntryRecords` loop already tests ENTRY rather than presence, so a re-save
     *    never reaches here — this guard is the SECOND, independent mechanism, exactly as the
     *    `open*` blocks' existence reads are.
     * 3. IT IS THE SHAPE THE REST OF THIS FEATURE ALREADY USES: `NDA_Signed_Status_Sync`'s
     *    `Date_Signed_Is_Blank` gate and `openBuyerNdas`'s idempotency guard.
     *
     * ── 🔴 WHY THIS IS AN **AFTER** CONTEXT WHEN EVERY OTHER STAMP IN THIS FILE IS **BEFORE** ──
     * `stampListingDates` is before-context because `Listing_Date__c` is a field ON THE DISPOSITION
     * BEING SAVED. This writes a field on a CHILD — a different record, which the trigger is not
     * saving — so it is a DML no matter which context it sits in, and a before-context DML would be
     * a DML against uncommitted parents. Same structural distinction `DispositionTriggerHandler`'s
     * header draws between `Listing_Date__c` (movable) and `Primary_NDA__c` (not).
     *
     * ⚠ AND THE APPROVAL LOCK DOES NOT REACH IT, WHICH IS WHY NO QUEUEABLE IS NEEDED. The record
     * updated here is the NDA, not the Disposition. `NDA__c` is the entry object of NO approval
     * process in this org (measured 2026-08-20: the seven files in approvalProcesses/ enter on
     * `BOV_Submission__c`, `Disposition_Offer__c`, `Disposition__c` ×3 and `Opportunity` ×2), and a
     * CHILD OF A LOCKED RECORD IS NOT ITSELF LOCKED. `Release Materials` is in any case not any
     * approval's entry stage (`Disposition Readiness`; `Broker Selection` + Off Market; `Closing` +
     * wire-verified). Adding a Queueable would assert a hazard that is not present — the exact
     * mistake review W1 caught in `DispositionNdaStampQueueable`.
     *
     * ── SYSTEM_MODE, AND THE REASON IS THE FIELD ──────────────────────────────────────────────
     * `Materials_Released_Date__c` is a 2026-08-20 field, and a Metadata-API-deployed custom field
     * arrives with NO field permissions for ANY profile, System Administrator included. A
     * `USER_MODE` update would therefore be refused for EVERYONE in the deploy window — and, this
     * being an after-update trigger, that refusal ROLLS BACK THE USER'S OWN STAGE CHANGE with
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`. Independently: `DPEG_Disposition_Edit` grants `NDA__c`
     * `allowEdit = true` but the running user may be an APPROVER who is read-only on it. Both legs
     * hold; either alone is sufficient. The idempotency READ is `SYSTEM_MODE` too
     * (`NdaSelector.selectByDispositionIds`), and a USER_MODE read feeding a SYSTEM_MODE write would
     * be a shape where the write is permitted and the read deciding what to write is not.
     *
     * ── allOrNone = true, MATCHING THE THREE `open*` BLOCKS AND FOR THE SAME REASON ───────────
     * A silently un-stamped NDA is exactly the failure D6.1 exists to prevent: the timeline's middle
     * hop vanishes and both duration columns render `—` on a sale where the materials demonstrably
     * went out. Nothing anywhere would notice. A refused stage change is LOUD. Silence is the
     * failure mode this tranche keeps paying for.
     * ⚠ AND THE REFUSAL SURFACE HERE IS SMALL BY MEASUREMENT, NOT BY HOPE: `NDA__c` carries ZERO
     * validation rules (objects/NDA__c/ has no validationRules directory) and no approval, so there
     * is very little that can refuse this update once SYSTEM_MODE has covered CRUD and FLS.
     *
     * ── ⚠ WHAT IT DOES **NOT** DO, STATED SO IT IS NOT READ AS A BUG ─────────────────────────
     * It does not stamp `Introducing Broker` NDAs. The date means "the deal package went to THIS
     * BUYER", and a broker is not a buyer — the same distinction `openBuyerNdas` makes with the same
     * key, and the same one `NdaSelector.selectBuyerTimelineByDispositionId` filters on so the
     * timeline and this stamp cannot disagree about who counts.
     * It also does not stamp an NDA created AFTER the stage entry (a buyer added later gets no
     * default and the analyst types the date). Auto-defaults fire on a transition; a row that did
     * not exist at the transition missed it. That is the same accepted consequence
     * `openDispositionLois` records for a second-round LOI.
     *
     * ✅ IN PRACTICE THE ROWS THIS STAMPS ARE ALREADY SIGNED, AND THAT IS WORTH KNOWING RATHER THAN
     * ASSUMED: `All_NDAs_Signed_Before_Progression` blocks a real `update` INTO `Release Materials`
     * unless every non-Declined NDA on the disposition is `Signed`. So on the normal path the
     * materials date lands on NDAs whose `Date_Signed__c` is already set, and the timeline's first
     * duration is computable immediately. ⚠ That rule is `ISCHANGED`-only, so a row INSERTED
     * directly at `Release Materials` (seed scripts, data loads, several test surfaces) bypasses it
     * — which is precisely why this method must not assume a signed status and does not test one.
     *
     * @param entrants Dispositions that just entered `Release Materials`. Never null (the caller
     *                 always passes a constructed Set); empty is the common case and returns
     *                 immediately.
     */
    private static void stampMaterialsReleasedDates(Set<Id> entrants) {
        if (entrants.isEmpty()) {
            return;
        }

        // Resolved once for the whole chunk. Date.today() is stable within a transaction, but
        // hoisting it also makes every NDA stamped in one save carry an identical date rather than
        // relying on that — the same reason `stampListingDates` hoists it.
        Date today = Date.today();

        // ONE query for the whole chunk — never one per disposition. The selector returns
        // `Materials_Released_Date__c` for exactly this guard; see its ApexDoc for why that field is
        // now part of its contract.
        List<NDA__c> toStamp = new List<NDA__c>();
        for (NDA__c nda : NdaSelector.selectByDispositionIds(entrants)) {
            if (!BUYER_ROLE.equals(nda.Party_Role__c)) {
                continue;
            }
            if (nda.Materials_Released_Date__c != null) {
                // FILL-IF-BLANK. An analyst's own date, or a previous stamp, wins. Never overwrite.
                continue;
            }
            toStamp.add(new NDA__c(Id = nda.Id, Materials_Released_Date__c = today));
        }
        if (toStamp.isEmpty()) {
            return;
        }

        // ONE DML for the whole chunk. See the SYSTEM_MODE and allOrNone paragraphs above.
        Database.update(toStamp, true, AccessLevel.SYSTEM_MODE);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // `Active Listing` STAGE — the broker listing. Tranche 5B (D28/Q3).
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Opens one broker listing per entrant.
     *
     * 🔴 THIS IS A PREREQUISITE, NOT AN ENHANCEMENT. Before it existed, NOTHING in the application
     * created a `Broker_Listing__c` — repo-wide the only creators were `TestDataFactory` and three
     * seed scripts — and NOTHING wrote `Disposition__c.Listing_Date__c`. With
     * `Days_On_Market__c` carrying `formulaTreatBlanksAs = BlankAsZero`, an unset date reads **0
     * forever, not null**: a clock that looks healthy and never ticks. The traction monitor is
     * inert without this block.
     *
     * ── 🔴 THE DML MODE, RE-ARGUED FROM SCRATCH. THE SIBLING BLOCKS' REASON IS FALSE HERE. ──
     * The NDA, LOI and PSA blocks all reach SYSTEM_MODE through "the disposition persona holds
     * `allowCreate = false` on this child object". THAT ARGUMENT DOES NOT APPLY. Measured in
     * permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml: `Broker_Listing__c` is granted
     * `allowCreate = true`, `allowEdit = true`, `viewAllRecords = true`, and EVERY field this
     * method writes (`Disposition__c`, `List_Date__c`, `Listing_Status__c`, `Broker_Firm__c`) is
     * `editable = true`. `DPEG_Acquisitions` additionally carries `modifyAllRecords = true`. This
     * block also introduces NO NEW FIELD, so the second sibling leg — "a Metadata-API-deployed
     * field arrives with no FLS for anyone, System Administrator included" — is absent too.
     *
     * 🔴 SO ON THE EVIDENCE `USER_MODE` WOULD WORK FOR BOTH DISPOSITION PERSONAS, AND SYSTEM_MODE
     * IS CHOSEN ANYWAY FOR A DIFFERENT REASON. This insert is automation the user did not ask for:
     * they moved a stage, and a listing record appears as a side effect. `USER_MODE` THROWS rather
     * than degrades, so ANY principal outside the two measured permission sets — an administrator
     * holding neither, a data load, a future Flow-driven stage change, an integration user — would
     * have their legitimate stage change ROLLED BACK by a `DmlException` about an object they were
     * not trying to touch. That is the `TaskRollupService` production incident's exact shape
     * (ARCHITECTURE.md §2: a `USER_MODE` read inside a trigger threw and rolled back 82 Task
     * inserts, making a checklist unbuildable by any non-admin).
     *
     * ⚠ AND THE HONEST COUNTER-STATEMENT, BECAUSE THIS ONE IS A GENUINE WIDENING WHERE THE OTHER
     * THREE WERE NOT: SYSTEM_MODE here lets a principal create a `Broker_Listing__c` they could not
     * create by hand. It is bounded three ways — the row is created only as a side effect of a
     * stage change they were already permitted to make, every value on it is derived from the
     * parent record they already hold, and no user input reaches it. Do not restate the sibling
     * blocks' "the persona has no create" line here; it is measurably untrue and would leave the
     * next reader believing this grant restores access rather than adds it.
     *
     * ── THE APPROVAL LOCK — DOES NOT REACH THE CHILD ────────────────────────
     * `Active Listing` is not any approval's entry stage (measured 2026-08-19 against the current
     * files: `Disposition Readiness`; `Broker Selection` + Off Market; `Closing` + wire-verified),
     * and in the one case where this code CAN run under a pending
     * approval — an admin dragging a locked record forward, `recordEditability =
     * AdminOnly` — a child of a locked record is not itself locked, so the insert is safe
     * synchronously.
     *
     * ⚠ THE ILLUSTRATION IN THAT SENTENCE CHANGED WITH THE REDESIGN AND IS CORRECTED RATHER THAN
     * DELETED: it used to read "an admin advancing a locked record out of `BOV Outreach`". No
     * approval locks `BOV Outreach` any more — the on-market broker approval moved onto the
     * `BOV_Submission__c` child — and `Active Listing` is now reached from `Release Materials`,
     * which nothing locks either. The remaining case is an admin jumping a record forward from
     * `Broker Selection`-under-approval, which is off-market only and therefore cannot legitimately
     * land on `Active Listing` at all. The conclusion is unchanged and now rests on less.
     *
     * There is NO parent write in this method at all: `Listing_Date__c` is stamped
     * in the BEFORE context by `stampListingDates`, precisely so that the one write that WOULD
     * have been refused never becomes a second DML. No Queueable, and adding one would assert a
     * hazard that has been designed out rather than one that is present.
     *
     * ── allOrNone = true ────────────────────────────────────────────────────
     * Same trade as the LOI and PSA blocks, for the same reason: a disposition parked at
     * `Active Listing` with no listing is SILENT — the traction panel would read "not listed" while
     * the Path says otherwise — and a refused stage change is LOUD. Silence is the failure mode
     * this tranche keeps paying for.
     *
     * ── IDEMPOTENCY: SIMPLE PRESENCE, ANY LISTING ───────────────────────────
     * "This disposition already has a broker listing" is the whole test. Re-entering the stage,
     * a re-save, and the NDA block's own deferred stamp update are therefore all no-ops.
     *
     * ⚠ IT IS DELIBERATELY *NOT* KEYED ON THE BROKER, and that is what keeps the broker-change
     * history model reachable: `BrokerListingSelector.selectMostRecentByDispositionId` is already
     * `ORDER BY CreatedDate DESC LIMIT 1`, i.e. already written as "the current listing among
     * several", so a deliberate broker change APPENDS a second row and the card follows the new
     * broker with no schema change. Auto-create must never be the thing that appends it — a stage
     * re-entry is not a broker change.
     *
     * ── WHAT IS STAMPED, AND WHAT IS DELIBERATELY LEFT BLANK ────────────────
     *   `List_Date__c`      = the PARENT's Listing_Date__c, copied rather than re-derived from
     *                         Date.today(), so the child's date and the clock the badge reads can
     *                         never disagree. `stampListingDates` has already run in the before
     *                         context of this same save, so the value is present on Trigger.new.
     *   `Broker_Firm__c`    = `Disposition__c.Selected_Broker__c` — free, already on Trigger.new,
     *                         and by definition the broker just approved out of BOV Outreach. A
     *                         blank there simply leaves a blank here.
     *                         ⚠ "BY DEFINITION" RESTS ON A RECORD-TYPE FACT, NOT ON THE FIELD HAVING
     *                         ONE WRITER — and since 2026-08-20 it has two. `Selected_Broker__c` is
     *                         ALSO written off-market by `DispositionBrokerStampService`, in the
     *                         format `Person - Firm` rather than the bare firm this child field
     *                         expects. That value cannot reach here because `Active Listing` is
     *                         restricted OUT of the `Off_Market` value set, so only the on-market
     *                         BOV stamp is ever in flight at this stage. 🔴 If `Active Listing` is
     *                         ever added to the off-market value set, THIS LINE BECOMES WRONG —
     *                         `Broker_Listing__c.Broker_Firm__c` would silently start holding a
     *                         person's name. Re-read this before making that change.
     *   `Listing_Status__c` = LISTING_INITIAL_STATUS; see that constant.
     *   `Contact_Name__c`   — LEFT BLANK. The named contact lives on the `Selected` BOV_Submission__c
     *                         and would cost a query per chunk to fetch, for a display string.
     *                         A human fills it, or the future broker-change action supplies it.
     *   `Days_On_Market__c` — LEFT BLANK ON PURPOSE. It is the hand-keyed Number nothing writes;
     *                         seeding a 0 would resurrect the very field the clock was moved OFF.
     *   `Offers_Received__c`— LEFT BLANK. Same reason; the real count is `Disposition_Offer__c`
     *                         children, read live by DispositionTractionService.
     *
     * ── NO RECORD TYPE ─────────────────────────────────────────────────────
     * `Broker_Listing__c` has no `recordTypes/` directory — the object has none — so unlike the
     * other three blocks there is no stamp, no describe and no guard here at all. The
     * guarded-versus-unconditional question is not answerable in the abstract and is deliberately
     * left to whoever adds record types to this object, exactly as design §2.6 argued for
     * `Property_Asset__c` — ⚠ but if they do, the answer the other three blocks reached on
     * 2026-08-25 is `isActive()`, not `isAvailable()`; start from `openDispositionLois`.
     *
     * @param entrants Dispositions that just entered `Active Listing`, as whole records.
     */
    private static void openBrokerListings(List<Disposition__c> entrants) {
        if (entrants.isEmpty()) {
            return;
        }
        Map<Id, Disposition__c> byId = new Map<Id, Disposition__c>(entrants);
        // One query for the whole chunk — never one per record.
        for (Broker_Listing__c existing : BrokerListingSelector.selectByDispositionIds(byId.keySet())) {
            byId.remove(existing.Disposition__c);
        }
        if (byId.isEmpty()) {
            return;
        }

        List<Broker_Listing__c> toInsert = new List<Broker_Listing__c>();
        for (Disposition__c d : byId.values()) {
            toInsert.add(new Broker_Listing__c(
                Disposition__c = d.Id,
                List_Date__c = d.Listing_Date__c,
                Broker_Firm__c = d.Selected_Broker__c,
                Listing_Status__c = LISTING_INITIAL_STATUS
            ));
        }
        Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);
        // NO PARENT STAMP AND NO QUEUEABLE — the one parent write this feature needs happens in
        // the BEFORE context (stampListingDates). Do not add one "for symmetry" with the NDA block.
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SHARED
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The record type Id for a developer name on an object, or null when it does not exist in this
     * org or is INACTIVE.
     *
     * ── 🔴 ACTIVENESS, NOT AVAILABILITY. CHANGED 2026-08-25 — READ THE LOI BLOCK FIRST ──
     * RETRACTED, verbatim, so nobody restores it by reflex: "…or is not available to the running
     * user", implemented as `(info != null && info.isAvailable())`. Every caller of this helper is
     * an automation insert made ON A PRINCIPAL'S BEHALF — a trigger cascade that can run as an
     * APPROVER — and `isAvailable()` answers a question about that principal's UI record-type
     * visibility, which is not a question the `AccessLevel.SYSTEM_MODE` DML it feeds is asking.
     * On 2026-08-25 that mismatch stopped being theoretical: DISP-0025 / OFFER-0012, approver
     * Nikhil Dhanani, FINEST log 07Liw000000I1vJEAS — the stamp silently no-opped, the LOI landed
     * on the acquisition default type, and the insert threw
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST, rolling back the approval. The full argument, and
     * the retained 2026-08-09 residual (a type deployed but assigned to NOBODY may now throw
     * INVALID_CROSS_REFERENCE_KEY here where it used to no-op), are at `openDispositionLois`.
     *
     * ⚠ THE FOURTH CALLER IS A READ, NOT A STAMP, AND IT WAS FIXED BY THE SAME LINE.
     * `resolveBrokers` compares this value against `Disposition__c.RecordTypeId` to decide WHICH
     * FIELD holds the appointed broker. Under `isAvailable()` that comparison silently answered
     * "not On_Market" for any principal who could not see the type, so an on-market NDA was
     * created with `Broker__c = null` — a wrong answer, not a missing stamp. Activeness is the
     * only correct basis for a comparison against stored data.
     *
     * Null is still a legitimate answer, not an error — the caller then leaves RecordTypeId unset
     * and the platform applies its own default. See each block's Javadoc for what that costs on
     * that object and why a loud failure was still rejected.
     *
     * A describe, not a query — it costs no SOQL. Callers resolve it ONCE per chunk.
     *
     * ⚠ The developer-name lookup is case-SENSITIVE (getRecordTypeInfosByDeveloperName keys its map
     * that way), so the three constants above must match the recordTypes/ file names exactly. There
     * is deliberately no allow-list guard here — unlike TestDataFactory, every argument is one of
     * this class's own private constants, so a typo is a compile-time-visible edit to a named
     * constant rather than a caller mistake.
     */
    private static Id recordTypeIdFor(Schema.SObjectType objectType, String developerName) {
        Schema.RecordTypeInfo info = objectType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        // isActive(), NOT isAvailable() — see this method's Javadoc and openDispositionLois.
        return (info != null && info.isActive()) ? info.getRecordTypeId() : null;
    }
}
