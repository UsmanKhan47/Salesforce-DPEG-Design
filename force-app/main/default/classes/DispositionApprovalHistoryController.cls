/**
 * The `@AuraEnabled` boundary for the card titled "Approval History" on the Disposition record page
 * — backs `c/dispositionApprovalHistory`. Built 2026-08-26.
 *
 * 🔴 WHY THIS EXISTS AT ALL, IN ONE PARAGRAPH. The disposition flow's five approvals target THREE
 * objects: three aim at `Disposition__c`, `Broker_Finalize_Approval` aims at the selected
 * `BOV_Submission__c` and `Offer_Selection_Approval` at the selected `Disposition_Offer__c`. The
 * platform's Approval History related list matches `ProcessInstance.TargetObjectId` to the record
 * it renders on, so the last two are structurally invisible on the Disposition page — which is
 * exactly the report that produced this card ("I sent the disposition for approval on BOV Outreach
 * but it is not appearing on the disposition record", 2026-08-25). The full table and the reasoning
 * are in `DispositionApprovalHistoryService`'s header; read it before changing anything here.
 *
 * ⚠ THIS DOES NOT REPLACE THE STANDARD RELATED LIST AND ITS EXISTENCE IS NOT AN ARGUMENT FOR
 * REMOVING ONE. `force:relatedListContainer` in the FlexiPage's header region is the ONLY route to
 * the Recall button on a record the approval has locked (`recordEditability = AdminOnly`). This
 * class is read-only and offers no actions at all.
 *
 * Layering: THIN controller (ARCHITECTURE.md §2, `layer=controller`) — marshal, delegate, catch,
 * throw `AuraHandledException` with a fixed user-safe message. ZERO SOQL of its own and zero
 * business logic; the target resolution, the `Started`-step rule and both orderings live in the
 * service.
 *
 * ── ⚠ `cacheable=true`, AND WHAT THAT COSTS ─────────────────────────────────────────────────
 * A read-only card on a record page, called once per page view per record, over data that changes a
 * handful of times per deal. The client therefore holds the payload, and an approval decided
 * elsewhere will not appear here until the wire is refreshed — which is precisely why the component
 * ALSO wires `getRecord` on `Disposition__c.LastModifiedDate` and calls `refreshApex` when it
 * changes: every approval on this flow writes the parent (a stage advance, a semaphore, a broker
 * stamp), so the record's own modification time is a cheap, LDS-cached proxy for "an approval just
 * moved". ⚠ IT IS A PROXY, NOT A GUARANTEE — a rejection that changes nothing on the parent will
 * not trigger it, and the accepted fallback is a page refresh. Same trade
 * `DispositionBuyerTimelineController` documents at length.
 *
 * ── 🔴 A `QueryException` IS **NOT** SWALLOWED INTO AN EMPTY CARD ────────────────────────────
 * Every read behind this method is `WITH USER_MODE`, so a missing grant throws rather than
 * degrading, and this controller turns that into a VISIBLE error message. It deliberately does NOT
 * catch-and-return-empty: the whole card IS the data, and "(0)" on a sale with a pending approval
 * is a CONFIDENT WRONG ANSWER — and it is the exact wrong answer the user already reported once,
 * from the related list, which is what makes it the one failure mode this card must never
 * reproduce. 🔴 THE FIX FOR SUCH AN ERROR IS A PERMISSION SET, NEVER `SYSTEM_MODE` ON A SELECTOR:
 * this card shows approval trails, so a system-mode read would show a reader decisions on records
 * their sharing hides.
 * ⚠ THE GATE LIST IS FOUR SELECTOR METHODS WIDE, and three of them were added with this card:
 * `DispositionSelector.selectNameById` (`Name` only),
 * `BovSubmissionSelector.selectApprovalTargetsByDispositionId` (Name / Contact_Name__c /
 * Broker_Firm__c), `DispositionOfferSelector.selectApprovalTargetsByDispositionId` (Name /
 * Offer_Amount__c), and `ProcessInstanceSelector.selectHistoryByTargetIds` (ProcessInstance,
 * ProcessDefinition, the polymorphic `Name` behind SubmittedBy/Actor, and the
 * `ProcessInstanceHistory` subquery). Each of the three new ones is deliberately the NARROWEST read
 * that answers its question, because **this card carries no FlexiPage visibility rule** — it renders
 * at every stage of every disposition, so it is the component most exposed to a missing grant.
 * ✅ NO NEW FLS IS REQUIRED, AND THAT WAS CHECKED RATHER THAN ASSUMED (2026-08-26). The only three
 * CUSTOM fields in the whole gate list — `BOV_Submission__c.Contact_Name__c`,
 * `BOV_Submission__c.Broker_Firm__c` and `Disposition_Offer__c.Offer_Amount__c` — already carry
 * `readable = true` on BOTH `DPEG_Disposition_View` and `DPEG_Disposition_Edit`. (Reading the
 * permission-set XML is sound HERE specifically because a permission-set GROUP can only UNION
 * grants: an XML that grants read cannot be narrowed by another member. The reverse inference —
 * "the XML does not grant it, therefore nobody has it" — is NOT sound and needs a `FieldPermissions`
 * query.) Everything else selected is a standard `Name`/audit field, or a system entity that carries
 * no field-level security at all.
 * 🔴 THE ONE GRANT THAT *IS* REQUIRED IS `classAccesses` ON `DPEG_Apex_Access`, AND IT SHIPS IN THE
 * SAME CHANGE. Three separate live-breaks recorded at the top of that file were each a controller
 * that forgot it, and the UAT symptom every time was "You do not have access to the Apex class
 * named '<Controller>'". Deploy that permission set in the same payload as this class.
 *
 * @see force-app/main/default/classes/DispositionApprovalHistoryService.cls
 * @see force-app/main/default/lwc/dispositionApprovalHistory/dispositionApprovalHistory.js
 * @see force-app/main/default/classes/DispositionBuyerTimelineController.cls (the shape this copies)
 */
public with sharing class DispositionApprovalHistoryController {

    /**
     * Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never interpolate
     * platform text or exception detail into it — the detail goes to the debug log (admin-only).
     */
    private static final String READ_FAILURE_MESSAGE =
        'The approval history could not be loaded. Refresh the page or contact your administrator.';

    /** An Id of the wrong SObject type is a wiring mistake, not a data state. See getHistory. */
    private static final String WRONG_TYPE_MESSAGE =
        'Approval history can only be read for a Disposition.';

    /**
     * `AuraHandledException` loses its message unless `setMessage` is called explicitly — a platform
     * quirk this repo hits everywhere, hence the helper. Same shape as
     * `DispositionBuyerTimelineController.ahe`.
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
     * Every approval raised on this Disposition or on any of its BOV submissions or offers, newest
     * submission first.
     *
     * NOT-FOUND CONTRACT: a null Id, or a Disposition nothing has ever been submitted against,
     * returns an EMPTY LIST. That is the normal state of a sale in its first stage, and the
     * component renders the card title with `(0)` and nothing else — no empty-state prose, per the
     * user's 2026-08-25 instruction to stop shipping hard-coded empty sentences.
     *
     * ── ⚠ A WRONG SOBJECT TYPE IS A DIFFERENT THING AND IS REFUSED ─────────────────────────────
     * An Id of some other object is a WIRING MISTAKE, not a data state. Binding a foreign Id into
     * `WHERE Disposition__c = :id` throws NOTHING — it simply matches no rows — so without this
     * guard a component wired to the wrong `record-id` would render a confident, permanent `(0)`
     * and nobody would ever learn the card was pointed at the wrong record. On THIS card that is
     * indistinguishable from the very defect it was built to fix.
     * The guard sits OUTSIDE the try on purpose: inside it, the `catch (Exception)` below would
     * swallow its own `AuraHandledException` and replace a precise message with the generic one.
     *
     * ⚠ ONE `catch`, NOT TWO. A second typed catch (`QueryException`) on a controller this thin is
     * unreachable in test and drags the class under the 75% per-class coverage gate — a measured
     * failure mode in this repo. The type distinction is not needed: every exception a read can
     * raise here produces the same user-facing message.
     *
     * @param dispositionId The Disposition whose approval history to read.
     * @return One row per approval, newest first. Never null.
     * @throws AuraHandledException when the Id is of the wrong SObject type, or when the underlying
     *         read fails (almost always a missing FLS or object grant — see the class header).
     */
    @AuraEnabled(cacheable=true)
    public static List<DispositionApprovalHistoryService.ApprovalRow> getHistory(Id dispositionId) {
        if (dispositionId == null) {
            return new List<DispositionApprovalHistoryService.ApprovalRow>();
        }
        if (dispositionId.getSObjectType() != Disposition__c.SObjectType) {
            throw ahe(WRONG_TYPE_MESSAGE);
        }
        try {
            return DispositionApprovalHistoryService.getHistory(dispositionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionApprovalHistoryController.getHistory on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
