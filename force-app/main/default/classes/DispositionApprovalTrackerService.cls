/**
 * Builds the FIVE-ROW APPROVAL TRACKER for one Disposition — a fixed checklist answering, for each
 * of the BA's five principal-approval types, "where is this sale?". Backs
 * `DispositionApprovalTrackerController` -> `c/dispositionApprovalTracker`. Built 2026-08-31
 * (Tranche 3 item 3, design `agent-output/disposition-gap-closure-t3-design.md`).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 IT IS A SIBLING OF `DispositionApprovalHistoryService`, NOT AN EXTENSION OF IT — BY DECISION
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * The design recommended extending `c/dispositionApprovalHistory` (D-14). The user reversed that at
 * Gate 1 on 2026-08-31: **build a new component; do not extend that card and do not modify
 * `DispositionApprovalHistoryService`.** That is why two classes now read `ProcessInstance` for the
 * same sale, and the split is honest about what it costs:
 *
 *   - COST: if both cards are ever placed on the same page, the page pays FIVE queries here plus
 *     FOUR there. Neither number grows with data volume — both are pinned by a governor assertion
 *     — but they do add.
 *   - WHAT IT BUYS: the history card's `manyChildren_costsExactlyFourQueries` assertion, which its
 *     own header calls *"the highest-value governor assertion in this class"*, stays valid and
 *     untouched. Extending it would have made that four a five and required moving a pinned
 *     assertion in the same change that changed behaviour.
 *   - 🔴 THE TWO CARDS ANSWER DIFFERENT QUESTIONS AND MUST NOT BE MERGED LATER "to save a query".
 *     History answers *what happened, in order, in words a human recognises* — it is keyed on the
 *     process LABEL and shows a full step trail. This class answers *which of the five TYPES is
 *     where* — it is keyed on the process API NAME, publishes no trail, and has TWO STATES THE
 *     OTHER CARD CANNOT HAVE (`NotStarted`, `NotApplicable`), because a checklist must render a row
 *     for an approval that has never been raised and a history list must not.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 FIVE ROWS, SIX PROCESSES. THIS IS THE FACT THE WHOLE CLASS IS SHAPED AROUND.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *   BA approval type          Process(es)                                        Target object
 *   1 Sale Decision           `Sale_Decision_Approval`                           Disposition__c
 *   2 Broker Selection        `Broker_Finalize_Approval`   ON-market only        BOV_Submission__c
 *   2 Broker Selection        `Broker_Selection_Approval`  OFF-market only       Disposition__c
 *   3 NDA Issue               `NDA_Issue_Approval`                               NDA__c
 *   4 Final Sale Terms        `Offer_Selection_Approval`                         Disposition_Offer__c
 *   5 Closing Wire Sign-Off   `Closing_Approval`                                 Disposition__c
 *
 * Row 2 is therefore RECORD-TYPE-DEPENDENT, and getting it backwards is the failure mode that
 * matters most: an on-market sale keyed on `Broker_Selection_Approval` (whose entry criterion is
 * `Is_On_Market__c = False`, so it can NEVER run there) would read "Not started" forever, and the
 * card would report that every single on-market sale skipped an approval it in fact passed. The
 * row therefore tracks the applicable variant and PUBLISHES THE OTHER ONE as `naProcessApiName`,
 * which the component renders as N/A — never as "not started".
 * ⚠ NARROWED 2026-08-31 (review W-1): "PUBLISHES THE OTHER ONE" is now conditional on that other
 * one having NO `ProcessInstance`. The record type is an inference about which process CAN run; an
 * instance is proof about which one DID, and evidence wins. The Master record type is the case that
 * forced this — `recordTypeNameOf` answers `On_Market` there while `Is_On_Market__c` reads FALSE,
 * so `Broker_Selection_Approval` is genuinely runnable on a row this row called it N/A on. Full
 * argument at `brokerRow`.
 * ⚠ AND THERE IS NO DATA IN THE ORG TO CATCH AN INVERSION. `usman-dpeg` held ZERO `Disposition__c`
 * records on 2026-08-31, so `DispositionApprovalTrackerServiceTest` asserting BOTH directions is
 * the only thing standing between a swapped pair and production.
 *
 * ── 🔴 THE RECORD TYPE COMES FROM `DispositionDomain.recordTypeNameOf`, NOT `Is_On_Market__c` ──
 * The design proposed reading `Is_On_Market__c` through an LDS `getRecord` in the component. That
 * is rejected here for three reasons, the third of which is decisive:
 *   1. it would put a branch no Apex test can exercise into JavaScript, on the one row this repo
 *      has no data to verify by hand;
 *   2. it adds a second asynchronous source that can resolve AFTER the rows, so the row would
 *      render with the wrong variant and then correct itself;
 *   3. 🔴 IT DISAGREES WITH EVERY OTHER CONSUMER IN THE MODULE ABOUT A MASTER-TYPED ROW.
 *      `Is_On_Market__c` is a formula over `RecordType.DeveloperName` that reads BLANK — i.e. FALSE,
 *      i.e. OFF-market — on a Master row. `DispositionDomain.recordTypeNameOf` answers `On_Market`.
 *      `DispositionDomain`'s own header records what happened the last time two components disagreed
 *      about what "no record type" means (defect C-2: an approval submitted down the wrong branch,
 *      approved, and then stranded because the advance map had no key for it). Using the shared
 *      helper is what makes this card, the Advance button, the submit dispatch and the approval
 *      advance map give a Master row the same answer.
 *      `DispositionStageEntryService.ON_MARKET_RECORD_TYPE` rejects `Is_On_Market__c` as an Apex
 *      discriminator in the same terms.
 * ⚠ SO A MASTER-TYPED ROW TAKES THE **ON-MARKET** BRANCH HERE, which is the opposite of the
 * fail-direction the design assumed. It is bounded — `DispositionService` stamps a record type on
 * every row it creates — and it is the direction the rest of the module already takes.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 STATE COMES FROM `ProcessInstance.Status`. NEVER FROM AN `Approval_Pending__c` FLAG.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * `BOV_Submission__c` carries `Approval_Pending__c`; `Disposition_Offer__c` DOES NOT — its fields
 * are `Approval_Status__c` and nothing else. A flag-keyed tracker is therefore STRUCTURALLY BLIND
 * on row 4, and would be blind on row 3 too (T3 deliberately shipped no NDA pending flag, decision
 * D-10). `ProcessInstance` is the one source that exists for all six processes, and it is also the
 * only one that can distinguish `Rejected` from `Recalled` from `No Response`.
 *
 * ── 🔴 THE PROCESS KEY IS `DeveloperName`. A LABEL WOULD HAVE BROKEN ALREADY ──────────────────
 * On 2026-08-26 FOUR of the five processes were relabelled in one change ("Sale Decision Approval"
 * -> "Decide to Sell Approval"; "Broker Finalize Approval" -> "Broker Selection Approval (BOV)";
 * "Broker Selection Approval" -> "Broker Selection Approval (Off-Market)") and not one `<fullName>`
 * moved. A checklist keyed on the label would silently reclassify every row on the next copy edit —
 * no exception, no row-count change, just five "Not started" rows on a sale that passed four
 * approvals. `ProcessInstanceSelector.selectTrackerStatesByTargetIds` exists for this.
 * ⚠ `DeveloperName` IS NOT GLOBALLY UNIQUE — `Underwriting_Approval` exists TWICE in this org, on
 * `Opportunity` and on `Underwriting__c`. It is unambiguous here only because the target set is
 * restricted to one sale's Disposition / BOV / offer / NDA rows, and none of the six names is used
 * by a process targeting any of those four objects. RE-CHECK THAT before adding a sixth row.
 *
 * ── ⚠ `NDA_Issue_Approval` MAY NOT EXIST IN THE ORG YET, AND ITS ROW STILL RENDERS ────────────
 * It is being created concurrently (Tranche 3 item 2, admin-owned). This class NEVER queries
 * `ProcessDefinition` and never asserts the process resolves — an absent process simply matches no
 * instance, so row 3 reads `NotStarted` / "0 of m approved". That is honest on the day, and the row
 * starts working the moment the approval deploys, with no code change. 🔴 DO NOT "IMPROVE" THIS BY
 * LOOKING THE DEFINITION UP AND HIDING THE ROW WHEN IT IS MISSING: a hidden row is indistinguishable
 * from a passed one, and the whole point of a checklist is that the empty boxes are visible.
 *
 * ── LAYERING ──────────────────────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). **ZERO SOQL and ZERO DML.** Five selector calls, a
 * fixed cost regardless of how many BOVs, offers, NDAs or approvals the sale has — pinned by
 * `DispositionApprovalTrackerServiceTest.manyChildren_costsExactlyFiveQueries`, which is the
 * assertion that fails first if someone moves a lookup inside the row loop.
 *
 * ── ⚠ IT OFFERS NO ACTIONS, AND MUST NOT GROW ANY ─────────────────────────────────────────────
 * Recall stays reachable only from `force:relatedListContainer` in the FlexiPage header region, and
 * only for the three Disposition-TARGETED approvals — that component matches `TargetObjectId`. So
 * this card will show a pending `Broker_Finalize_Approval` or `Offer_Selection_Approval` that
 * cannot be recalled from the page it is displayed on. That gap is real and is reported rather than
 * papered over; making these rows LOOK actionable without being actionable is the one way this card
 * makes things worse.
 *
 * @see force-app/main/default/classes/DispositionApprovalTrackerController.cls
 * @see force-app/main/default/classes/ProcessInstanceSelector.cls
 * @see force-app/main/default/classes/DispositionApprovalHistoryService.cls (the sibling card)
 * @see force-app/main/default/lwc/dispositionApprovalTracker/dispositionApprovalTracker.js
 */
public with sharing class DispositionApprovalTrackerService {

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // PROCESS API NAMES — `ProcessDefinition.DeveloperName`, matching approvalProcesses/ exactly.
    // 🔴 CASE-SENSITIVE. These are Apex `Map<String, ...>` keys and Apex string-map keys are
    // case-SENSITIVE (unlike `==` on String). A mis-cased literal matches nothing, throws nothing,
    // and renders a permanent "Not started" — the exact failure this class is built to avoid.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    @TestVisible
    private static final String PROC_SALE_DECISION = 'Sale_Decision_Approval';

    /** ON-market broker selection. Targets the SELECTED `BOV_Submission__c`, not the sale. */
    @TestVisible
    private static final String PROC_BROKER_FINALIZE = 'Broker_Finalize_Approval';

    /** OFF-market broker selection. Targets the `Disposition__c` itself. */
    @TestVisible
    private static final String PROC_BROKER_SELECTION = 'Broker_Selection_Approval';

    /**
     * ⚠ MAY NOT RESOLVE TO A DEPLOYED PROCESS YET — see the class header. That is handled by never
     * asking, rather than by a guard.
     */
    @TestVisible
    private static final String PROC_NDA_ISSUE = 'NDA_Issue_Approval';

    @TestVisible
    private static final String PROC_OFFER_SELECTION = 'Offer_Selection_Approval';

    @TestVisible
    private static final String PROC_CLOSING = 'Closing_Approval';

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // ROW KEYS — stable tokens the component maps to display copy.
    // ⚠ THE **LABELS** ARE NOT HERE, DELIBERATELY. Copy lives in the component, per the idiom
    // `c/dispositionApprovalHistory` records: a wording change then costs no deploy, and an Apex
    // test asserting on a display string would be asserting on Apex for a decision the UI owns.
    // Apex owns the ORDER, the KEYS and the STATE; the component owns every word a user reads.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    @TestVisible
    private static final String ROW_SALE_DECISION = 'SALE_DECISION';
    @TestVisible
    private static final String ROW_BROKER_SELECTION = 'BROKER_SELECTION';
    @TestVisible
    private static final String ROW_NDA_ISSUE = 'NDA_ISSUE';
    @TestVisible
    private static final String ROW_FINAL_TERMS = 'FINAL_TERMS';
    @TestVisible
    private static final String ROW_CLOSING = 'CLOSING';

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // STATES.
    // 🔴 THE SIX PLATFORM VALUES ARE PUBLISHED **RAW** — `Pending` / `Approved` / `Rejected` /
    // `Removed` / `Reassigned` / `NoResponse`. `Removed` is what a RECALL leaves behind and reads
    // to a user as though someone deleted their approval; the component translates it to
    // "Recalled" and pins the translation in Jest, exactly as the sibling card does. Translating
    // here would move a copy decision into a deploy.
    // ⚠ THE TWO SYNTHETIC TOKENS BELOW ARE THIS CLASS'S OWN AND CANNOT COLLIDE with a platform
    // value — the platform emits neither. They are what makes this a CHECKLIST rather than a list.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /** No `ProcessInstance` has ever been raised for this row's process on this sale. */
    @TestVisible
    private static final String STATE_NOT_STARTED = 'NotStarted';

    /**
     * The named variant cannot run on this record type at all. Published on `naState`, NOT on
     * `state` — the row itself always tracks a process that CAN run. See `brokerRow`.
     * ⚠ SINCE 2026-08-31 THIS IS ONLY CLAIMED WHERE THE VARIANT HAS NO `ProcessInstance`. An
     * instance disproves "cannot run", whatever the record type suggests.
     */
    @TestVisible
    private static final String STATE_NOT_APPLICABLE = 'NotApplicable';

    private static final String STATUS_PENDING = 'Pending';
    private static final String STATUS_APPROVED = 'Approved';
    private static final String STATUS_REJECTED = 'Rejected';

    /**
     * Lightning record-view path. Composed once; never a hard-coded org URL or record Id.
     * ⚠ THIS IS A SECOND COPY OF `DispositionApprovalHistoryService`'s URL rule, and it is a
     * knowing duplication rather than an oversight: that class is FROZEN by the Gate 1 decision
     * that produced this one, so its private helper cannot be reached or shared. If a third copy is
     * ever needed, promote the rule to a domain helper and repoint all three at once.
     */
    private static final String RECORD_URL_PREFIX = '/lightning/r/';
    private static final String RECORD_URL_SUFFIX = '/view';

    /**
     * ONE row of the checklist. Every member crosses the `@AuraEnabled` boundary and is a value the
     * component renders — no raw sObjects, per ARCHITECTURE.md §2.
     */
    public class TrackerRow {

        /**
         * A STABLE TOKEN (`SALE_DECISION`, `BROKER_SELECTION`, …), not a label. The component maps
         * it to display copy and falls back to the raw token, so a key it does not recognise still
         * renders something readable rather than a blank row.
         */
        @AuraEnabled
        public String rowKey;

        /** 1-5, the BA's own numbering. The list is returned in this order and is NOT re-sorted. */
        @AuraEnabled
        public Integer sequence;

        /**
         * `ProcessDefinition.DeveloperName` of the process this row is TRACKING on this record type.
         * On row 2 it is one of two values (see `naProcessApiName`); on every other row it is fixed.
         * ⚠ Exposed so a test can assert on the PROCESS rather than on the rendered word — the
         * record-type inversion is invisible in the state alone.
         */
        @AuraEnabled
        public String processApiName;

        /**
         * 🔴 ROW 2 ONLY, AND THE REASON THE CARD DOES NOT LIBEL AN ON-MARKET SALE. The API name of
         * the broker-selection variant that CANNOT run on this record type. The component renders
         * it as N/A. NULL on every other row, and never equal to `processApiName`.
         * ⚠ ALSO NULL ON ROW 2 ITSELF WHEN BOTH VARIANTS HAVE A `ProcessInstance` — added
         * 2026-08-31, review W-1. An N/A claim is a factual assertion that a process did not and
         * cannot run; it is not made about a process that demonstrably ran. See `brokerRow`.
         */
        @AuraEnabled
        public String naProcessApiName;

        /**
         * 🔴 ROW 2 ONLY, AND ALWAYS EXACTLY `NotApplicable` WHEN `naProcessApiName` IS SET. NULL
         * everywhere else — INCLUDING on row 2 when no N/A claim is made (see `naProcessApiName`).
         * The two are set together or not at all; the component's `hasNaVariant` gate requires
         * both, so half-populating them would render an empty pill.
         * ⚠ IT LOOKS REDUNDANT WITH `naProcessApiName != null` AND IS NOT. It lets the component
         * push BOTH states through ONE display map, so N/A gets the same pill treatment as
         * `Approved` or `Recalled` with no special case in the template — and it makes the
         * requirement *"the variant that does not apply must render N/A, never 'not started'"*
         * a thing an APEX test can assert directly, on the one row this org has no data to check
         * by hand. If it is ever removed, the N/A rule survives only in JavaScript.
         */
        @AuraEnabled
        public String naState;

        /**
         * Raw `ProcessInstance.Status`, or one of this class's two synthetic tokens. See the STATES
         * block. RAW, NOT A DISPLAY LABEL.
         */
        @AuraEnabled
        public String state;

        /** The record the newest matching approval targets. NULL when nothing was ever submitted. */
        @AuraEnabled
        public Id targetId;

        /** That record's AutoNumber — `DISP-0025` / `BOV-0027` / `OFFER-0012`. Nullable. */
        @AuraEnabled
        public String targetLabel;

        /** A RELATIVE Lightning record URL. Relative on purpose — an absolute one hard-codes a My
         *  Domain and breaks on every sandbox refresh. Nullable. */
        @AuraEnabled
        public String targetUrl;

        /** `ProcessInstance.CreatedDate` of the newest matching approval. Nullable. */
        @AuraEnabled
        public Datetime submittedDateTime;

        /** `ProcessInstance.CompletedDate`. NULL WHILE PENDING — that is the normal live state. */
        @AuraEnabled
        public Datetime decidedDateTime;

        /**
         * 🔴 ROW 3 ONLY. How many of the sale's NDAs have an APPROVED NDA-issue approval, and how
         * many NDAs there are. NULL on every other row, so the component can tell "this row has no
         * count" from "this row counts zero".
         * ⚠ THIS IS THE ONE ROW WHOSE CARDINALITY IS NOT 1. A sale invites several counterparties
         * into its data room and each gets its own NDA; showing only the latest would report the
         * sale approved on the strength of one party out of three.
         */
        @AuraEnabled
        public Integer approvedCount;

        @AuraEnabled
        public Integer totalCount;
    }

    /** What this class knows about one approval TARGET before it knows whether anything was
     *  submitted against it. Private — it never crosses the `@AuraEnabled` boundary. */
    private class TargetInfo {
        private String recordLabel;
        private String url;
    }

    /**
     * The five-row approval checklist for one Disposition, in BA order, always five rows.
     *
     * NOT-FOUND CONTRACT: a null Id, or a Disposition the reader cannot see, returns an EMPTY LIST.
     * 🔴 EMPTY IS **NOT** THE SAME AS "FIVE NOT-STARTED ROWS", AND THE DIFFERENCE IS DELIBERATE. A
     * sale that exists and has been submitted for nothing returns five rows, every one
     * `NotStarted` — that is a statement about the SALE. An empty list means the sale could not be
     * resolved at all, which is a statement about the READER or the wiring, and the component must
     * not dress it up as a checklist of zeros.
     *
     * COST: exactly FIVE queries — four target lookups and one `ProcessInstance` read — whatever
     * the row counts. Pinned by the service test.
     *
     * ⚠ IT DOES NOT VALIDATE THE SOBJECT TYPE. That guard lives in the controller, outside its
     * `try`, so its precise message is not swallowed by the generic read-failure catch.
     *
     * @param dispositionId The Disposition whose approval tracker to build.
     * @return Five rows in sequence order, or an empty list. Never null.
     */
    public static List<TrackerRow> getTracker(Id dispositionId) {
        List<TrackerRow> rows = new List<TrackerRow>();
        if (dispositionId == null) {
            return rows;
        }

        List<Disposition__c> sales =
            DispositionSelector.selectApprovalTrackerContextById(dispositionId);
        if (sales.isEmpty()) {
            return rows;
        }
        Disposition__c sale = sales[0];

        Map<Id, TargetInfo> targetsById = new Map<Id, TargetInfo>();
        targetsById.put(sale.Id, info(sale.Name, sale.Id));

        for (BOV_Submission__c submission
                : BovSubmissionSelector.selectApprovalTargetsByDispositionId(dispositionId)) {
            targetsById.put(submission.Id, info(submission.Name, submission.Id));
        }
        for (Disposition_Offer__c offer
                : DispositionOfferSelector.selectApprovalTargetsByDispositionId(dispositionId)) {
            targetsById.put(offer.Id, info(offer.Name, offer.Id));
        }

        // Held separately from `targetsById` because row 3 needs the DENOMINATOR — how many NDAs
        // the sale has — and that is a count of NDAs, not of every approval target.
        Set<Id> ndaIds = new Set<Id>();
        for (NDA__c nda : NdaSelector.selectApprovalTrackerTargetsByDispositionId(dispositionId)) {
            ndaIds.add(nda.Id);
            targetsById.put(nda.Id, info(nda.Name, nda.Id));
        }

        // ⚠ NEWEST FIRST, AND THE TWO MAPS BELOW DEPEND ON IT. `selectTrackerStatesByTargetIds`
        // orders `CreatedDate DESC, Id DESC`; taking the FIRST row seen per key is therefore
        // "the newest", which is what makes a RESUBMITTED approval report its CURRENT state rather
        // than its first. Nothing is re-sorted here — a second copy of that rule is a second thing
        // to get wrong, and the selector argues it at the point it is imposed.
        Map<String, ProcessInstance> newestByProcess = new Map<String, ProcessInstance>();
        Map<Id, ProcessInstance> newestNdaApprovalByNda = new Map<Id, ProcessInstance>();

        for (ProcessInstance instance
                : ProcessInstanceSelector.selectTrackerStatesByTargetIds(targetsById.keySet())) {
            String processName = instance.ProcessDefinition == null
                ? null
                : instance.ProcessDefinition.DeveloperName;
            if (String.isBlank(processName)) {
                // An instance cannot exist without a definition, so this is unreachable in
                // practice. Skipping rather than bucketing it under a null key keeps that
                // guarantee visible instead of implicit.
                continue;
            }
            if (!newestByProcess.containsKey(processName)) {
                newestByProcess.put(processName, instance);
            }
            if (PROC_NDA_ISSUE.equals(processName)
                    && ndaIds.contains(instance.TargetObjectId)
                    && !newestNdaApprovalByNda.containsKey(instance.TargetObjectId)) {
                newestNdaApprovalByNda.put(instance.TargetObjectId, instance);
            }
        }

        rows.add(simpleRow(
            ROW_SALE_DECISION, 1, PROC_SALE_DECISION, newestByProcess, targetsById));
        rows.add(brokerRow(sale, newestByProcess, targetsById));
        rows.add(ndaRow(newestByProcess, ndaIds, newestNdaApprovalByNda));
        rows.add(simpleRow(
            ROW_FINAL_TERMS, 4, PROC_OFFER_SELECTION, newestByProcess, targetsById));
        rows.add(simpleRow(
            ROW_CLOSING, 5, PROC_CLOSING, newestByProcess, targetsById));
        return rows;
    }

    /**
     * A row whose type maps to exactly ONE process on both record types (1, 4 and 5).
     *
     * @param rowKey          The stable token the component maps to copy.
     * @param sequence        The BA's row number.
     * @param processApiName  The `ProcessDefinition.DeveloperName` to look for.
     * @param newestByProcess Newest instance per process, built in `getTracker`.
     * @param targetsById     Label/url per approval target.
     * @return The populated row; `NotStarted` when nothing matched.
     */
    private static TrackerRow simpleRow(
        String rowKey,
        Integer sequence,
        String processApiName,
        Map<String, ProcessInstance> newestByProcess,
        Map<Id, TargetInfo> targetsById
    ) {
        TrackerRow row = new TrackerRow();
        row.rowKey = rowKey;
        row.sequence = sequence;
        row.processApiName = processApiName;
        applyInstance(row, newestByProcess.get(processApiName), targetsById);
        return row;
    }

    /**
     * 🔴 ROW 2 — THE ONE ROW THAT DEPENDS ON THE RECORD TYPE, AND THE ONE THIS ORG HAS NO DATA TO
     * VERIFY BY HAND.
     *
     * An ON-market sale appoints its broker through `Broker_Finalize_Approval`, raised against the
     * SELECTED `BOV_Submission__c`. An OFF-market sale has no BOV matrix at all and appoints
     * directly through `Broker_Selection_Approval`, raised against the `Disposition__c` — whose
     * entry criterion is literally `Is_On_Market__c = False`.
     *
     * ⚠ SO THE INAPPLICABLE VARIANT IS NOT "NOT STARTED", IT IS **UNREACHABLE**, and the two must
     * never render alike. "Not started" invites someone to go and start it; on the wrong record
     * type there is nothing to start, and a permanently-"Not started" row on 100% of sales of one
     * type is a defect report the card generates about itself. `naProcessApiName` is what the
     * component renders as N/A.
     *
     * ⚠ THE RECORD TYPE IS RESOLVED THROUGH THE SHARED DOMAIN HELPER, so a Master/unset row takes
     * the ON-market branch — see the class header for why that fallback, and not
     * `Is_On_Market__c`'s opposite one, is the right answer here.
     *
     * ═════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 EVIDENCE OVERRIDES THE INFERENCE. THE RECORD TYPE IS A GUESS ABOUT WHICH PROCESS *CAN*
     *    RUN; A `ProcessInstance` IS PROOF ABOUT WHICH ONE *DID*. ADDED 2026-08-31 (review W-1).
     * ═════════════════════════════════════════════════════════════════════════════════════════
     * The record-type inference is not a control on what the platform actually does.
     * `Approval.process` routes by ENTRY CRITERIA ALONE — no code anywhere names either of these
     * processes — and the criteria are `Is_On_Market__c` predicates, not record-type predicates.
     * On the MASTER record type `Is_On_Market__c` reads FALSE, so `Broker_Selection_Approval`'s
     * criteria are SATISFIABLE while `recordTypeNameOf` answers `On_Market`. A Master-typed sale
     * could therefore carry a REAL, PENDING `Broker_Selection_Approval` that this row published as
     * `naProcessApiName` + `NotApplicable` — the card asserting, itemised and in the user's face,
     * that an approval sitting in somebody's queue right now does not exist, with the tracked row
     * reading "Not started" beside it. That is the exact false claim the fail-hard design in this
     * class's header exists to prevent, arriving through the THIRD record-type state rather than
     * through a swapped pair.
     *
     * Two corrections, both self-correcting against live evidence and both costing ZERO queries
     * (`newestByProcess` is already built and already in hand):
     *
     *   1. If the variant this record type is presumed NOT to run has an instance and the presumed
     *      applicable one does NOT, the presumption was wrong for this row — TRACK the one with
     *      evidence. The row then reports the approval that is really there.
     *   2. NEVER publish `naProcessApiName` for a process that has an instance. When both have one,
     *      NEITHER is unreachable, so no N/A claim is published at all and the fields stay null.
     *
     * ⚠ THE N/A CLAIM IS NOW CONDITIONAL, WHICH IS A CONTRACT CHANGE FOR ROW 2: `naProcessApiName`
     * and `naState` can be null on this row where they were previously always set. The component
     * already gates on `!!row.naProcessApiName && !!row.naState` (`hasNaVariant`), so it renders
     * nothing rather than an empty pill — do not "simplify" that gate away.
     *
     * ⚠ THIS DOES NOT MAKE `recordTypeNameOf` REDUNDANT. It is still the only answer available on
     * the overwhelmingly common row where NEITHER process has run yet, which is every sale before
     * its broker approval is raised.
     *
     * @param sale            The Disposition, with `RecordTypeId` selected.
     * @param newestByProcess Newest instance per process.
     * @param targetsById     Label/url per approval target.
     * @return The populated row, tracking whichever variant this record has evidence of, else
     *         whichever one its record type can run.
     */
    private static TrackerRow brokerRow(
        Disposition__c sale,
        Map<String, ProcessInstance> newestByProcess,
        Map<Id, TargetInfo> targetsById
    ) {
        Boolean onMarket =
            DispositionDomain.RT_ON_MARKET.equals(DispositionDomain.recordTypeNameOf(sale));

        String applicable = onMarket ? PROC_BROKER_FINALIZE : PROC_BROKER_SELECTION;
        String inapplicable = onMarket ? PROC_BROKER_SELECTION : PROC_BROKER_FINALIZE;

        // Correction 1 — the record type said one thing and the approval history says the other.
        if (!newestByProcess.containsKey(applicable)
            && newestByProcess.containsKey(inapplicable)) {
            String tracked = applicable;
            applicable = inapplicable;
            inapplicable = tracked;
        }

        TrackerRow row = new TrackerRow();
        row.rowKey = ROW_BROKER_SELECTION;
        row.sequence = 2;
        row.processApiName = applicable;
        // Correction 2 — an N/A claim is only ever made about a process with NO instance.
        // ⚠ NO TEST FALSIFIES THIS `if`. Deleting the wrapper (always publishing) leaves the whole
        // suite GREEN — the Master tests reach correction 1 only, because on those fixtures just
        // one of the two processes has an instance. The gap, the fixture it would take and why it
        // was not built are recorded in DispositionApprovalTrackerServiceTest, above
        // `masterTypedSale_takesTheOnMarketBranch`. Do not read the green suite as proof of this
        // line.
        if (!newestByProcess.containsKey(inapplicable)) {
            row.naProcessApiName = inapplicable;
            row.naState = STATE_NOT_APPLICABLE;
        }
        applyInstance(row, newestByProcess.get(row.processApiName), targetsById);
        return row;
    }

    /**
     * 🔴 ROW 3 — THE AGGREGATE. A sale invites several counterparties into its data room and each
     * gets its own NDA, so this row is `n of m approved` rather than a single outcome.
     *
     * THE RULES, IN ORDER, AND EACH ONE IS A DECISION:
     *   1. `m == 0`  -> `NotStarted`, `0 of 0`. 🔴 NOT `Approved`. "Every NDA is approved" is
     *      VACUOUSLY TRUE of a sale with no NDAs, and rule 3 below would return `Approved` for it —
     *      a sale that has issued nothing reported as having cleared the NDA gate. This guard
     *      exists solely to refuse that.
     *   2. nothing submitted -> `NotStarted`, `0 of m`.
     *   3. every NDA approved -> `Approved`.
     *   4. any REJECTED -> `Rejected`. Ranked ABOVE "pending" on purpose: a rejection is the thing
     *      a reader must act on, and a mixed sale that reported `Pending` would hide it behind a
     *      state that reads like "wait".
     *   5. otherwise -> `Pending`. This covers partial approval with nothing outstanding (1 of 3
     *      approved, 2 never submitted), which is genuinely "in progress"; the `n of m` count is
     *      what stops that being a lie, so THE COUNT MUST ALWAYS RENDER on this row.
     *
     * ⚠ AN ABSENT `NDA_Issue_Approval` PROCESS LANDS ON RULE 2, not on an exception — see the class
     * header. On the day this ships that is the expected reading for every sale.
     *
     * @param newestByProcess       Newest instance per process — supplies the row's timestamps.
     * @param ndaIds                Every NDA on the sale. The DENOMINATOR.
     * @param newestApprovalByNda   Newest NDA-issue approval per NDA.
     * @return The populated row, always carrying both counts.
     */
    private static TrackerRow ndaRow(
        Map<String, ProcessInstance> newestByProcess,
        Set<Id> ndaIds,
        Map<Id, ProcessInstance> newestApprovalByNda
    ) {
        TrackerRow row = new TrackerRow();
        row.rowKey = ROW_NDA_ISSUE;
        row.sequence = 3;
        row.processApiName = PROC_NDA_ISSUE;
        row.totalCount = ndaIds.size();
        row.approvedCount = 0;

        Integer submitted = 0;
        Integer rejected = 0;
        for (Id ndaId : ndaIds) {
            ProcessInstance instance = newestApprovalByNda.get(ndaId);
            if (instance == null) {
                continue;
            }
            submitted = submitted + 1;
            if (STATUS_APPROVED.equals(instance.Status)) {
                row.approvedCount = row.approvedCount + 1;
            } else if (STATUS_REJECTED.equals(instance.Status)) {
                rejected = rejected + 1;
            }
        }

        // Timestamps describe the MOST RECENT NDA-issue approval anywhere on the sale, which is the
        // only "when" an aggregate row can honestly carry. Deliberately taken from the whole-sale
        // map rather than recomputed, so it cannot disagree with the other rows' notion of newest.
        ProcessInstance latest = newestByProcess.get(PROC_NDA_ISSUE);
        if (latest != null) {
            row.submittedDateTime = latest.CreatedDate;
            row.decidedDateTime = latest.CompletedDate;
        }

        row.state = ndaAggregateState(row.totalCount, submitted, row.approvedCount, rejected);
        return row;
    }

    /**
     * 🔴 ROW 3'S FIVE RULES, EXTRACTED AS A PURE FUNCTION SO THEY CAN BE FALSIFIED DIRECTLY.
     *
     * ⚠ IT IS SEPARATE FROM `ndaRow` FOR A TESTABILITY REASON THAT IS NOT COSMETIC. `ProcessInstance`
     * is NOT CREATEABLE — no fixture can insert one — so the only way to reach these branches
     * through `ndaRow` is to submit and DECIDE a real approval against a real NDA, which requires
     * `NDA_Issue_Approval` to be DEPLOYED. That process is being created concurrently and is not in
     * the org yet, so a test written that way would either fail on a dependency this class does not
     * have, or be silently skipped. Taking four integers instead makes every rule — including the
     * vacuous-truth guard in rule 1 — provable today, with no approval process and no fixture at
     * all. The wiring that produces the four integers is covered separately.
     *
     * @param total     How many NDAs the sale has. The DENOMINATOR.
     * @param submitted How many of them have any NDA-issue approval instance.
     * @param approved  How many have a newest instance reading `Approved`.
     * @param rejected  How many have a newest instance reading `Rejected`.
     * @return One of `NotStarted` / `Approved` / `Rejected` / `Pending`.
     */
    @TestVisible
    private static String ndaAggregateState(
        Integer total,
        Integer submitted,
        Integer approved,
        Integer rejected
    ) {
        // RULE 1 — 🔴 THE VACUOUS-TRUTH GUARD, AND IT IS THE MOST IMPORTANT LINE IN THIS METHOD.
        // "Every NDA is approved" is TRUE of a sale with no NDAs, so without this the next branch
        // would report `Approved` for a sale that has issued nothing at all. Deleting it does not
        // throw and changes no count — the row simply turns green on the emptiest possible state.
        // RULE 2 — nothing submitted yet. Also where an UNDEPLOYED `NDA_Issue_Approval` lands.
        if (total == 0 || submitted == 0) {
            return STATE_NOT_STARTED;
        }
        // RULE 3 — every party's NDA has been approved. The only fully-cleared reading.
        if (approved == total) {
            return STATUS_APPROVED;
        }
        // RULE 4 — RANKED ABOVE `Pending` DELIBERATELY. A rejection is the thing a reader must act
        // on; a mixed sale reported as `Pending` would hide it behind a word that reads like
        // "wait". The `n of m` count is what keeps this honest when only some parties are affected.
        if (rejected > 0) {
            return STATUS_REJECTED;
        }
        // RULE 5 — in progress. Covers a genuinely pending approval AND partial approval with
        // nothing outstanding (1 of 3 approved, 2 never submitted). ⚠ THE COUNT MUST ALWAYS RENDER
        // ON THIS ROW: `Pending` alone would let a reader assume one NDA and one decision.
        return STATUS_PENDING;
    }

    /**
     * Copies one `ProcessInstance` onto a row, or leaves the row `NotStarted`.
     *
     * ⚠ THE TARGET LOOKUP CAN MISS ONLY IF THE QUERY RETURNED A ROW OUTSIDE ITS OWN FILTER, which
     * it cannot. A null target leaves the label and link null rather than fabricating them; the
     * STATE still renders, because a state without a link is useful and a link without a state is
     * not.
     *
     * @param row         The row to populate.
     * @param instance    The newest matching approval, or null.
     * @param targetsById Label/url per approval target.
     */
    private static void applyInstance(
        TrackerRow row,
        ProcessInstance instance,
        Map<Id, TargetInfo> targetsById
    ) {
        if (instance == null) {
            row.state = STATE_NOT_STARTED;
            return;
        }
        row.state = instance.Status;
        row.targetId = instance.TargetObjectId;
        row.submittedDateTime = instance.CreatedDate;
        row.decidedDateTime = instance.CompletedDate;

        TargetInfo target = targetsById.get(instance.TargetObjectId);
        if (target != null) {
            row.targetLabel = target.recordLabel;
            row.targetUrl = target.url;
        }
    }

    /**
     * Assembles one `TargetInfo`, deriving the record URL from the Id's own SObject type.
     *
     * ⚠ THE OBJECT API NAME IS DERIVED, NOT WRITTEN DOWN. `String.valueOf(id.getSObjectType())`
     * cannot drift from the record it describes and costs no describe call, whereas four string
     * constants would silently produce a 404 link if an object were ever renamed.
     *
     * @param recordLabel The record's AutoNumber.
     * @param recordId    The record the link points at.
     * @return The populated holder.
     */
    private static TargetInfo info(String recordLabel, Id recordId) {
        TargetInfo target = new TargetInfo();
        target.recordLabel = recordLabel;
        target.url = RECORD_URL_PREFIX
            + String.valueOf(recordId.getSObjectType())
            + '/' + recordId + RECORD_URL_SUFFIX;
        return target;
    }
}
