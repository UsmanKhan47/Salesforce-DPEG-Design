/**
 * Builds the CONSOLIDATED "Approval History" card for one Disposition — every approval raised
 * anywhere in the disposition flow, whether it targets the Disposition itself or one of its
 * children, in one list, newest submission first. Backs
 * `DispositionApprovalHistoryController` -> `c/dispositionApprovalHistory`.
 * Built 2026-08-26 in response to a user report on 2026-08-25.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE DEFECT, BECAUSE EVERY DECISION BELOW FOLLOWS FROM IT
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * User, 2026-08-25: *"I sent the disposition for approval on BOV Outreach but it is not appearing
 * on the disposition record."* Nothing was broken. The disposition flow's five approvals target
 * THREE DIFFERENT OBJECTS:
 *
 *   PROCESS                       TARGET OBJECT           ENTRY CRITERION
 *   Sale_Decision_Approval        Disposition__c          Disposition_Stage__c = 'Disposition Readiness'
 *   Broker_Selection_Approval     Disposition__c          Stage = 'Broker Selection' AND NOT Is_On_Market__c
 *   Closing_Approval              Disposition__c          Stage = 'Closing' AND Wire_Verification_Completed__c
 *   Broker_Finalize_Approval      BOV_Submission__c       Submission_Status__c = 'Selected'
 *   Offer_Selection_Approval      Disposition_Offer__c    Is_Selected__c = true
 *
 * The platform's Approval History related list matches `ProcessInstance.TargetObjectId` to the
 * record it is rendered on — so on the Disposition page the last two are STRUCTURALLY INVISIBLE,
 * and "BOV Outreach" is exactly the stage whose approval targets a `BOV_Submission__c`. The user
 * was looking at a correct related list that could not, by construction, show what they submitted.
 *
 * 🔴 THIS CARD DOES NOT REPLACE THAT RELATED LIST AND MUST NOT BE USED TO JUSTIFY REMOVING IT.
 * `force:relatedListContainer` (identifier `relatedLists`, header region of
 * `flexipages/Disposition_Record_Page`) carries `showActionBar = true`, and **Recall is reachable
 * from nowhere else in the UI** — the disposition approvals set `recordEditability = AdminOnly`, so
 * a submitted record LOCKS and a driver whose approver went on leave has no other route. That
 * component's own FlexiPage comment records the incident that put it there. This card is
 * READ-ONLY: it shows the two approvals that list cannot, and repeats the three it can so a reader
 * does not have to reconcile two partial lists.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE TARGET SET IS EVERY CHILD EVER, NOT THE CURRENTLY-SELECTED ONE
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * Both child selectors return EVERY row on the disposition, unfiltered by the flag that gates the
 * approval's entry criterion. That is deliberate and is argued at each method
 * (`BovSubmissionSelector.selectApprovalTargetsByDispositionId`,
 * `DispositionOfferSelector.selectApprovalTargetsByDispositionId`). In one line: a broker who was
 * selected, approved and later REPLACED is no longer `Selected`, and a rejected offer is no longer
 * `Is_Selected__c` — filtering on those flags would delete completed, audited decisions from an
 * audit card at the moment they became history. **An approval-history read filters on nothing but
 * parentage.**
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE `Started` STEP IS NOT RENDERED AS A STEP. ITS COMMENT IS HOISTED ONTO THE ROW HEADER.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * `StepsAndWorkitems` always contains one `Started` row carrying the SUBMITTER and the SUBMISSION
 * TIME — both of which this DTO already publishes as `submittedBy` / `submittedDateTime`, read
 * from the ProcessInstance itself. Rendering it as a step too would print the same person and the
 * same timestamp twice inside a ~340px sidebar tile, which reads as two events.
 * 🔴 BUT ITS `Comments` ARE NOT DISCARDED — THAT IS THE HALF THAT WOULD HAVE BEEN A REAL DATA LOSS.
 * The text a user types into the Submit dialog lands on the `Started` step and NOWHERE ELSE. It is
 * lifted onto `submittedComments`, so dropping the step costs the card nothing. ⚠ If you ever
 * restore the `Started` row to `steps`, DELETE `submittedComments` in the same change — otherwise
 * the submitter's note renders twice, which is the defect this shape exists to avoid.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ ROW ORDER IS THE SELECTOR'S. STEP ORDER IS THIS CLASS'S. THEY LIVE IN DIFFERENT PLACES ON
 *   PURPOSE, AND NEITHER IS DUPLICATED.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * Rows arrive already ordered `CreatedDate DESC, Id DESC` and are NOT re-sorted here or in the
 * component. Steps arrive UNORDERED — `ProcessInstanceHistory` is a synthesised read-only entity
 * whose support for `ORDER BY` inside a child subquery this codebase has not measured, so the
 * selector deliberately omits it and `StepRow implements Comparable` does the work once, here.
 * See `ProcessInstanceSelector.selectHistoryByTargetIds`.
 *
 * ── ⚠ THE STEP TIE-BREAK IS NOT DECORATIVE ────────────────────────────────────────────────────
 * `CreatedDate` is SECOND-granular and an approve-then-auto-advance chain routinely writes two
 * steps inside one second. `List.sort()` is NOT stable in Apex, so without the `stepId` tie-break
 * the trail's order would differ between two renders of the same unchanged record — a log that
 * shuffles is not a log. The comparator is a TOTAL order for that reason.
 *
 * ── LAYERING ──────────────────────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). **ZERO SOQL and ZERO DML.** Four selector calls,
 * a fixed cost regardless of how many BOVs, offers or approvals the sale has — pinned by
 * `DispositionApprovalHistoryServiceTest.manyChildren_costsExactlyFourQueries`, which is the
 * assertion that fails first if someone moves a lookup inside a loop.
 *
 * @see force-app/main/default/classes/DispositionApprovalHistoryController.cls
 * @see force-app/main/default/classes/ProcessInstanceSelector.cls
 * @see force-app/main/default/lwc/dispositionApprovalHistory/dispositionApprovalHistory.js
 */
public with sharing class DispositionApprovalHistoryService {

    /**
     * The step the platform writes when a record ENTERS an approval process. Excluded from `steps`
     * and mined for `submittedComments` instead — see the class header.
     */
    private static final String STEP_STATUS_STARTED = 'Started';

    /** Lightning record-view path. Composed once; never a hard-coded org URL or record Id. */
    private static final String RECORD_URL_PREFIX = '/lightning/r/';
    private static final String RECORD_URL_SUFFIX = '/view';

    /**
     * ONE approval, with its trail. Every member crosses the `@AuraEnabled` boundary and is a value
     * the component renders — no raw sObjects, per ARCHITECTURE.md §2.
     */
    public class ApprovalRow {

        /** The `ProcessInstance` Id — the component's `for:each` key. Always present. */
        @AuraEnabled
        public Id processInstanceId;

        /**
         * `ProcessDefinition.Name` — the approval process's LABEL ("Broker Finalize Approval"), not
         * its API name. This is the row's heading and the single most important string on the card:
         * it is what tells a reader that the thing they submitted from BOV Outreach IS here.
         * ⚠ Falls back to nothing — it is never null in practice (an instance cannot exist without
         * a definition), and a blank heading would be a rendering failure worth seeing rather than
         * papering over.
         */
        @AuraEnabled
        public String processName;

        /** The record the approval targets. Exposed so a test can assert the TARGET, not the label. */
        @AuraEnabled
        public Id targetId;

        /**
         * The target's AutoNumber — `DISP-0025` / `BOV-0027` / `OFFER-0012`. THE ROW'S IDENTITY, and
         * the one label the platform guarantees is non-blank whatever FLS says about the rest.
         */
        @AuraEnabled
        public String targetLabel;

        /**
         * A human hint at WHOSE record this is — the BOV's `Contact_Name__c`, or its
         * `Broker_Firm__c` when the contact name is blank. NULL on offer and disposition rows, and
         * on a BOV that carries neither, and the component simply omits the segment.
         * ⚠ IT IS A SEPARATE MEMBER RATHER THAN CONCATENATED INTO `targetLabel` because the two
         * are rendered as separate spans with a CSS `gap` between them; a pre-joined string would
         * make the separator un-styleable and would print a dangling separator when the hint is
         * null.
         */
        @AuraEnabled
        public String targetDetail;

        /**
         * `Disposition_Offer__c.Offer_Amount__c` on an OFFER row; null on every other kind.
         *
         * 🔴 IT IS A NUMBER, NOT A PRE-FORMATTED STRING LIKE `"$2.0M"`, AND THAT IS A DELIBERATE
         * REVERSAL OF THE ABBREVIATED FORM THE BRIEF SUGGESTED. Abbreviating a currency to one
         * decimal makes $2,040,000 and $1,960,000 both render as "$2.0M"; on a card whose entire
         * job is to identify WHICH offer an approval decided, two different offers that print
         * identically is the one failure mode that matters. The component renders it with
         * `lightning-formatted-number`, which is exact and locale-correct.
         * ⚠ NULL IS NEVER SOFTENED TO `0` — a zero-amount offer is unusual but real, and a `0`
         * standing in for "not recorded" would misreport it.
         */
        @AuraEnabled
        public Decimal targetAmount;

        /**
         * A relative Lightning record URL for the target. Relative on purpose: an absolute one would
         * hard-code a My Domain, which breaks on every sandbox refresh.
         */
        @AuraEnabled
        public String targetUrl;

        /**
         * Raw `ProcessInstance.Status` — `Pending` / `Approved` / `Rejected` / `Removed` / …
         * ⚠ RAW, NOT A DISPLAY LABEL. `Removed` is what a RECALL leaves behind and reads as
         * nonsense to a user; the component maps it to "Recalled" and pins the mapping in Jest,
         * where a copy change costs no deploy. Do not translate it here — a test asserting on a
         * display string would then be asserting on Apex for a decision the UI owns.
         */
        @AuraEnabled
        public String status;

        /** `ProcessInstance.CreatedDate` — when it was submitted. Always present. */
        @AuraEnabled
        public Datetime submittedDateTime;

        /** `SubmittedBy.Name`. Null only if the submitting User is not visible to the reader. */
        @AuraEnabled
        public String submittedBy;

        /**
         * The comment typed into the Submit dialog, lifted off the excluded `Started` step. Null
         * when none was entered, which is the common case. See the class header.
         */
        @AuraEnabled
        public String submittedComments;

        /** `ProcessInstance.CompletedDate`. NULL WHILE PENDING — that is the normal live state. */
        @AuraEnabled
        public Datetime completedDateTime;

        /**
         * The trail, NEWEST FIRST, `Started` excluded. Never null — an empty list is a real state
         * (a just-submitted approval whose only history row is the excluded `Started` one).
         */
        @AuraEnabled
        public List<StepRow> steps;
    }

    /**
     * ONE row of an approval trail — a completed step or an outstanding workitem, which
     * `StepsAndWorkitems` returns together and this DTO deliberately does not distinguish beyond
     * `stepStatus`.
     */
    public class StepRow implements Comparable {

        /** The history row's Id — the component's `for:each` key AND the comparator's tie-break. */
        @AuraEnabled
        public Id stepId;

        /**
         * `Pending` / `Approved` / `Rejected` / `Reassigned` / … Rendered as visible TEXT, never as
         * a colour alone.
         */
        @AuraEnabled
        public String stepStatus;

        /**
         * `Actor.Name`. ⚠ `Actor` IS POLYMORPHIC (`Name`: a User OR a Group), so on a queue-assigned
         * step this is the QUEUE's name and that is correct — it is who holds the item. Nullable
         * when the actor is not visible to the reader.
         */
        @AuraEnabled
        public String actorName;

        /** The approver's comment. Null is the common case. */
        @AuraEnabled
        public String comments;

        /** `CreatedDate` — when the step was written. Always present; the primary sort key. */
        @AuraEnabled
        public Datetime createdDateTime;

        /**
         * Newest first, with a TOTAL order. See the class header for why the tie-break is not
         * optional: `CreatedDate` is second-granular and `List.sort()` is not stable in Apex.
         *
         * @param other The `StepRow` to compare against.
         * @return -1 when this row is newer, 1 when older, and the reverse `stepId` ordering when
         *         the timestamps are identical.
         */
        public Integer compareTo(Object other) {
            StepRow that = (StepRow) other;
            if (this.createdDateTime != that.createdDateTime) {
                return this.createdDateTime > that.createdDateTime ? -1 : 1;
            }
            return String.valueOf(that.stepId).compareTo(String.valueOf(this.stepId));
        }
    }

    /**
     * What this class knows about ONE approval target before it knows whether anything was ever
     * submitted against it. Private — it never crosses the `@AuraEnabled` boundary.
     */
    private class TargetInfo {
        private String recordLabel;
        private String detail;
        private Decimal amount;
        private String url;
    }

    /**
     * Every approval ever raised on a Disposition or on any of its BOV submissions or offers,
     * newest submission first.
     *
     * NOT-FOUND CONTRACT: a null Id, or a Disposition nothing has ever been submitted against,
     * returns an EMPTY LIST. "No approvals yet" is the normal state of a sale in its first stage —
     * it is not an error and it is not a null. The component renders the title with `(0)` and
     * nothing else.
     *
     * ⚠ IT DOES NOT VALIDATE THE SOBJECT TYPE. That guard lives in the controller, outside its
     * `try`, so its precise message is not swallowed by the generic read-failure catch. This method
     * is reachable only through that controller.
     *
     * COST: exactly FOUR queries — three target lookups and one `ProcessInstance` read — whatever
     * the row counts. Pinned by the service test.
     *
     * @param dispositionId The Disposition whose approval history to read.
     * @return One row per `ProcessInstance`, newest first, each with its trail newest-first and the
     *         `Started` step excluded. Never null.
     */
    public static List<ApprovalRow> getHistory(Id dispositionId) {
        List<ApprovalRow> rows = new List<ApprovalRow>();
        if (dispositionId == null) {
            return rows;
        }

        Map<Id, TargetInfo> targetsById = resolveTargets(dispositionId);
        if (targetsById.isEmpty()) {
            return rows;
        }

        for (ProcessInstance instance
                : ProcessInstanceSelector.selectHistoryByTargetIds(targetsById.keySet())) {
            TargetInfo target = targetsById.get(instance.TargetObjectId);
            if (target == null) {
                // Unreachable in practice - the query filters on this very key set. Skipping rather
                // than rendering a labelless row keeps that guarantee visible instead of implicit.
                continue;
            }
            rows.add(buildRow(instance, target));
        }
        return rows;
    }

    /**
     * The three lookups that turn "this Disposition" into the SET of record Ids an approval on this
     * sale could possibly target, each with the label the card will show for it.
     *
     * ⚠ THE DISPOSITION ITSELF IS ONE OF THE TARGETS. Three of the five processes aim at it, so
     * omitting it would hide the Sale Decision, Broker Selection and Closing approvals — i.e. it
     * would invert the defect rather than fix it.
     *
     * @param dispositionId The sale whose targets to resolve.
     * @return Record Id -> the label/detail/amount/url the card renders for that target. Never null;
     *         empty only if the reader can see none of the three (a sharing outcome, not a defect).
     */
    private static Map<Id, TargetInfo> resolveTargets(Id dispositionId) {
        Map<Id, TargetInfo> targetsById = new Map<Id, TargetInfo>();

        for (Disposition__c disposition : DispositionSelector.selectNameById(dispositionId)) {
            targetsById.put(
                disposition.Id,
                info(disposition.Name, null, null, disposition.Id)
            );
        }
        for (BOV_Submission__c submission
                : BovSubmissionSelector.selectApprovalTargetsByDispositionId(dispositionId)) {
            targetsById.put(
                submission.Id,
                info(submission.Name, brokerHint(submission), null, submission.Id)
            );
        }
        for (Disposition_Offer__c offer
                : DispositionOfferSelector.selectApprovalTargetsByDispositionId(dispositionId)) {
            targetsById.put(
                offer.Id,
                info(offer.Name, null, offer.Offer_Amount__c, offer.Id)
            );
        }
        return targetsById;
    }

    /**
     * Whose BOV submission this is, in one string.
     *
     * ⚠ BOTH COLUMNS ARE NULLABLE — they are stamped from the `Broker__c` lookup and a row can
     * carry neither — so this returns null rather than a placeholder. The row still identifies
     * itself by its `BOV-{0000}` number, so an absent hint costs nothing, whereas a fabricated
     * "Unknown broker" would read as a recorded fact.
     *
     * @param submission The submission to describe.
     * @return The contact name, else the firm, else null.
     */
    private static String brokerHint(BOV_Submission__c submission) {
        if (String.isNotBlank(submission.Contact_Name__c)) {
            return submission.Contact_Name__c;
        }
        return String.isNotBlank(submission.Broker_Firm__c) ? submission.Broker_Firm__c : null;
    }

    /**
     * Assembles one `TargetInfo`, deriving the record URL from the Id's own SObject type.
     *
     * ⚠ THE OBJECT API NAME IS DERIVED, NOT WRITTEN DOWN. `String.valueOf(id.getSObjectType())`
     * cannot drift from the record it describes and costs no describe call, whereas three string
     * constants would silently produce a 404 link if an object were ever renamed.
     *
     * @param recordLabel The record's AutoNumber.
     * @param detail A human hint, or null.
     * @param amount The offer amount, or null.
     * @param recordId The record the link points at.
     * @return The populated holder.
     */
    private static TargetInfo info(String recordLabel, String detail, Decimal amount, Id recordId) {
        TargetInfo target = new TargetInfo();
        target.recordLabel = recordLabel;
        target.detail = detail;
        target.amount = amount;
        target.url = RECORD_URL_PREFIX
            + String.valueOf(recordId.getSObjectType())
            + '/' + recordId + RECORD_URL_SUFFIX;
        return target;
    }

    /**
     * One `ProcessInstance` plus its trail, mapped to the DTO the component renders.
     *
     * @param instance The approval, with its `StepsAndWorkitems` child rows already loaded.
     * @param target   The label information for the record it targets.
     * @return The populated row; `steps` is newest-first and never null.
     */
    private static ApprovalRow buildRow(ProcessInstance instance, TargetInfo target) {
        ApprovalRow row = new ApprovalRow();
        row.processInstanceId = instance.Id;
        row.processName = instance.ProcessDefinition == null
            ? null
            : instance.ProcessDefinition.Name;
        row.targetId = instance.TargetObjectId;
        row.targetLabel = target.recordLabel;
        row.targetDetail = target.detail;
        row.targetAmount = target.amount;
        row.targetUrl = target.url;
        row.status = instance.Status;
        row.submittedDateTime = instance.CreatedDate;
        row.submittedBy = instance.SubmittedBy == null ? null : instance.SubmittedBy.Name;
        row.completedDateTime = instance.CompletedDate;
        row.steps = new List<StepRow>();

        for (ProcessInstanceHistory history : instance.StepsAndWorkitems) {
            if (STEP_STATUS_STARTED.equals(history.StepStatus)) {
                // The submit comment lives ONLY here. Take the FIRST one seen and do not overwrite:
                // a reassignment can write a second entry-shaped row, and the submitter's own note
                // is the earliest. See the class header.
                if (row.submittedComments == null) {
                    row.submittedComments = history.Comments;
                }
                continue;
            }
            row.steps.add(buildStep(history));
        }
        row.steps.sort();
        return row;
    }

    /**
     * One history row mapped to the DTO.
     *
     * @param history A `StepsAndWorkitems` child row.
     * @return The populated step.
     */
    private static StepRow buildStep(ProcessInstanceHistory history) {
        StepRow step = new StepRow();
        step.stepId = history.Id;
        step.stepStatus = history.StepStatus;
        step.actorName = history.Actor == null ? null : history.Actor.Name;
        step.comments = history.Comments;
        step.createdDateTime = history.CreatedDate;
        return step;
    }
}
