/**
 * The `@AuraEnabled` boundary for the card titled "Approval Tracker" on the Disposition record page
 * — backs `c/dispositionApprovalTracker`. Built 2026-08-31 (Tranche 3 item 3).
 *
 * 🔴 WHAT THE CARD IS, IN ONE PARAGRAPH. Five fixed rows, one per BA approval type: Sale Decision,
 * Broker Selection, NDA Issue, Final Sale Terms, Closing Wire Sign-Off. Each carries the current
 * state of that approval on this sale — Pending / Approved / Rejected / Recalled / Not started —
 * derived from `ProcessInstance.Status` and keyed on `ProcessDefinition.DeveloperName`. It is a
 * CHECKLIST, not a log: the empty boxes are the point. The full reasoning, including why five rows
 * cover SIX processes and why row 2 depends on the record type, is in
 * `DispositionApprovalTrackerService`'s header; read it before changing anything here.
 *
 * ⚠ IT IS A SIBLING OF `DispositionApprovalHistoryController`, NOT A REPLACEMENT. That card answers
 * *what happened, in order*; this one answers *which of the five is where*. Neither is derivable
 * from the other's payload without the key the other does not select — history publishes the
 * process LABEL, this publishes the API NAME. Building this as a separate bundle rather than
 * extending that one was a user decision at Gate 1 on 2026-08-31.
 *
 * ⚠ AND NEITHER REPLACES THE STANDARD RELATED LIST. `force:relatedListContainer` in the FlexiPage's
 * header region is the ONLY route to the Recall button on a record an approval has locked
 * (`recordEditability = AdminOnly`). This class is read-only and offers no actions at all.
 * 🔴 SO THIS CARD CAN SHOW A PENDING APPROVAL THAT CANNOT BE RECALLED FROM THE PAGE IT IS ON —
 * `Broker_Finalize_Approval` targets a `BOV_Submission__c` and `Offer_Selection_Approval` a
 * `Disposition_Offer__c`, and the related list matches `TargetObjectId`. That gap is reported, not
 * closed. Do not add a Recall affordance here without reading that component's FlexiPage comment.
 *
 * Layering: THIN controller (ARCHITECTURE.md §2, `layer=controller`) — marshal, delegate, catch,
 * throw `AuraHandledException` with a fixed user-safe message. ZERO SOQL of its own and zero
 * business logic; the record-type branch, the NDA aggregate and the newest-wins rule live in the
 * service.
 *
 * ── ⚠ `cacheable=true`, AND WHAT THAT COSTS ─────────────────────────────────────────────────
 * A read-only card on a record page, called once per page view per record, over data that changes a
 * handful of times per deal. The client therefore holds the payload, and an approval decided
 * elsewhere will not appear here until the wire is refreshed — which is why the component ALSO
 * wires `getRecord` on `Disposition__c.LastModifiedDate` and calls `refreshApex` when it changes.
 * ⚠ IT IS A PROXY, NOT A GUARANTEE: a decision that changes nothing on the parent will not fire it,
 * and the accepted fallback is a page refresh. Same trade `DispositionApprovalHistoryController` and
 * `DispositionBuyerTimelineController` both document at length.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS CARD FAILS **HARD**. A `QueryException` IS NOT SWALLOWED INTO AN EMPTY OR "NOT STARTED"
 *    TRACKER, AND THAT IS THE MOST CONSEQUENTIAL DECISION IN THIS FILE.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * Every read behind this method is `WITH USER_MODE`, so a missing grant THROWS rather than
 * degrading, and this controller turns that into a VISIBLE error banner. The alternative —
 * catch-and-return-empty — is uniquely dangerous on a CHECKLIST, more so than on the history card
 * beside it:
 *
 *   - The history card degrading shows "(0)", which at least reads as "nothing here".
 *   - This card degrading would show **FIVE ROWS, EVERY ONE "NOT STARTED"** — a confident,
 *     itemised, five-part assertion that a sale which has passed four principal approvals has
 *     passed none. A principal could read that and re-submit an approval that is already pending.
 *
 * ⇒ A read failure must never be dressed as a state. `isUnavailable` in the component is a
 * completely separate branch from `hasRows` and renders no rows at all.
 * 🔴 THE FIX FOR SUCH AN ERROR IS A PERMISSION SET, NEVER `SYSTEM_MODE` ON A SELECTOR. This card
 * shows approval outcomes, so a system-mode read would show a reader decisions on records their
 * sharing hides — the inversion ARCHITECTURE.md §2 warns about, on an audit surface. Same position
 * `DispositionBuyerTimelineController` and `ProcessInstanceSelector` both take, deliberately.
 *
 * ⚠ THE GATE LIST IS FIVE SELECTOR METHODS WIDE, AND IT WAS KEPT AS NARROW AS THE QUESTION ALLOWS,
 * BECAUSE THIS CARD CARRIES NO FLEXIPAGE VISIBILITY RULE — it renders at every stage of every
 * disposition, so it is maximally exposed to a missing grant:
 *   `DispositionSelector.selectApprovalTrackerContextById`   Name + RecordTypeId — NEITHER is
 *       permissionable, so this method cannot be the cause of a banner;
 *   `NdaSelector.selectApprovalTrackerTargetsByDispositionId` Id + Name only — the only gates are
 *       OBJECT read on `NDA__c` and FIELD read on `NDA__c.Disposition__c`, both of which
 *       `c/dispositionBuyerTimeline` on the same page already requires;
 *   `BovSubmissionSelector.selectApprovalTargetsByDispositionId` and
 *   `DispositionOfferSelector.selectApprovalTargetsByDispositionId` — REUSED, not re-written. Their
 *       three custom fields (`Contact_Name__c`, `Broker_Firm__c`, `Offer_Amount__c`) are already
 *       granted `readable = true` on BOTH `DPEG_Disposition_View` and `DPEG_Disposition_Edit`,
 *       verified when the history card shipped on 2026-08-26. ⚠ THIS CARD DOES NOT READ THOSE THREE
 *       VALUES — it takes the Ids and the Names. Reusing the methods costs three gates it does not
 *       need, and buys not having a second, drifting copy of the "an approval-history read filters
 *       on nothing but parentage" rule. If those grants are ever dropped, THIS CARD GOES DOWN WITH
 *       THE HISTORY CARD, together, which is at least a single diagnosis.
 *   `ProcessInstanceSelector.selectTrackerStatesByTargetIds` — `ProcessInstance` /
 *       `ProcessDefinition` are system entities with no field-level security and no
 *       `objectPermissions` block anywhere; row visibility follows access to the target record.
 *       `DPEG_Apex_Access` records that fact for the history card and it is unchanged here.
 * 🔴 THE ONE GRANT THAT **IS** REQUIRED IS `classAccesses` FOR THIS CLASS ON `DPEG_Apex_Access`,
 * AND IT MUST SHIP IN THE SAME PAYLOAD OR AN EARLIER ONE. Three separate live breaks recorded at
 * the top of that file were each a controller that forgot it; the UAT symptom every time was
 * "You do not have access to the Apex class named '<Controller>'". That file is owned by the
 * access pass, not by this change.
 *
 * @see force-app/main/default/classes/DispositionApprovalTrackerService.cls
 * @see force-app/main/default/lwc/dispositionApprovalTracker/dispositionApprovalTracker.js
 * @see force-app/main/default/classes/DispositionApprovalHistoryController.cls (the shape this
 *      copies, and the sibling card)
 */
public with sharing class DispositionApprovalTrackerController {

    /**
     * Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never interpolate
     * platform text or exception detail into it — the detail goes to the debug log (admin-only).
     */
    private static final String READ_FAILURE_MESSAGE =
        'The approval tracker could not be loaded. Refresh the page or contact your administrator.';

    /** An Id of the wrong SObject type is a wiring mistake, not a data state. See getTracker. */
    private static final String WRONG_TYPE_MESSAGE =
        'The approval tracker can only be read for a Disposition.';

    /**
     * `AuraHandledException` loses its message unless `setMessage` is called explicitly — a platform
     * quirk this repo hits everywhere, hence the helper.
     *
     * @param msg The user-safe message.
     * @return The exception, with its message actually set.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The five-row approval checklist for one Disposition, in BA order.
     *
     * NOT-FOUND CONTRACT: a null Id — the normal transient state on a record page, before the wire's
     * `recordId` is provisioned — returns an EMPTY LIST and costs nothing.
     * 🔴 AN EMPTY LIST IS NOT "FIVE NOT-STARTED ROWS". A resolvable sale ALWAYS returns five rows,
     * even when nothing has been submitted; empty means the sale could not be resolved at all. The
     * component renders them differently for that reason — see the service's `getTracker`.
     *
     * ── ⚠ A WRONG SOBJECT TYPE IS A DIFFERENT THING AND IS REFUSED ─────────────────────────────
     * An Id of some other object is a WIRING MISTAKE, not a data state. Binding a foreign Id into
     * `WHERE Disposition__c = :id` throws NOTHING — it simply matches no rows — so without this
     * guard a component wired to the wrong `record-id` would render a confident, permanent
     * five-row "Not started" checklist and nobody would learn the card was pointed at the wrong
     * record. On a CHECKLIST that is the worst possible silent failure: it does not look empty, it
     * looks like a finding.
     * The guard sits OUTSIDE the try on purpose: inside it, the `catch (Exception)` below would
     * swallow its own `AuraHandledException` and replace a precise message with the generic one.
     *
     * ⚠ ONE `catch`, NOT TWO. A second typed catch (`QueryException`) on a controller this thin is
     * unreachable in test and drags the class under the 75% per-class coverage gate — a measured
     * failure mode in this repo. The type distinction is not needed: every exception a read can
     * raise here produces the same user-facing message.
     *
     * @param dispositionId The Disposition whose approval tracker to read.
     * @return Five rows in sequence order, or an empty list. Never null.
     * @throws AuraHandledException when the Id is of the wrong SObject type, or when the underlying
     *         read fails (almost always a missing FLS or object grant — see the class header).
     */
    @AuraEnabled(cacheable=true)
    public static List<DispositionApprovalTrackerService.TrackerRow> getTracker(Id dispositionId) {
        if (dispositionId == null) {
            return new List<DispositionApprovalTrackerService.TrackerRow>();
        }
        if (dispositionId.getSObjectType() != Disposition__c.SObjectType) {
            throw ahe(WRONG_TYPE_MESSAGE);
        }
        try {
            return DispositionApprovalTrackerService.getTracker(dispositionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionApprovalTrackerController.getTracker on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
