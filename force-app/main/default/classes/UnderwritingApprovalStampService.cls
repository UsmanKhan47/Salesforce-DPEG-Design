/**
 * Mirrors an APPROVED Underwriting__c record's decision onto its parent Opportunity.
 *
 * Added 2026-08-28, when the principal underwriting approval moved OFF the Opportunity and ONTO
 * the Underwriting__c record. The approval's own finalApprovalActions write the child's
 * Stage__c / Status__c; this invocable writes the deal-level mirror fields that the rest of the
 * application still reads. Called from the after-save flow on Underwriting__c that fires when
 * the approval is granted.
 *
 * ── 🔴 THE INVOCABLE CONTRACT IS PINNED. DO NOT VARY IT. ──────────────────────────────────────
 * The declarative stream builds its Flow against these exact names, and a Flow binds an Apex
 * action by CLASS NAME and its inputs by @InvocableVariable FIELD NAME. Renaming the class, the
 * method, the inner `Request` type or the `underwritingId` member breaks that Flow at RUNTIME,
 * not at compile time, and the failure surfaces as an approval that silently stops mirroring:
 *     class  : UnderwritingApprovalStampService
 *     method : stampParent(List<Request>)
 *     label  : 'Stamp Underwriting Approval To Deal'
 *     input  : Request.underwritingId (Id, required)
 *
 * ── WHAT IT WRITES, AND WHY IT MUST BE ONE DML ────────────────────────────────────────────────
 * Per Opportunity, in a SINGLE Database.update:
 *     UW_Approved__c         = true
 *     Underwriting_Status__c = 'Approved by Principals'
 *
 * 🔴 SPLITTING THESE ACROSS TWO SAVES IS A SILENT BREAKAGE, NOT A STYLE CHOICE. The market-data
 * freeze (flows/Opportunity_UW_Approved_Notify -> MarketDataSnapshotService) has
 * `doesRequireRecordChangedToMeetCriteria = true` and fires on the TRANSITION into
 * Underwriting_Status__c = 'Approved by Principals'. If some other field were written first and
 * the status second, or the status twice, the freeze either never sees a transition or sees it on
 * a save that no longer carries the rest of the change. One shell per deal, one update, always.
 * The audit half of the mirror (UW_Approved_By__c / UW_Approval_Date__c) is deliberately NOT
 * written here — it is stamped by ApprovalAuditService from real approval history, on the save
 * the freeze flow itself triggers. See that class for why inventing those two values is worse
 * than stamping them one save later.
 *
 * ── 🔴 ACCEPTED, DOCUMENTED REGRESSION: REJECTION IS NO LONGER HANDLED AT ALL ──────────────────
 * This is a deliberate user decision (D2, 2026-08-28), recorded plainly rather than engineered
 * around. There is NO reject path in this class, NO Approval_Status__c field, and nothing
 * anywhere clears the mirror on a rejection.
 *
 * What that costs, precisely:
 *   - The retired Opportunity.Underwriting_Approval had a `UW_Reopen_For_Revision`
 *     finalRejectionAction that cleared Opportunity.Underwriting_Complete__c so the deal visibly
 *     returned for rework. THAT BEHAVIOUR IS GONE. Underwriting_Complete__c is never cleared on
 *     rejection any more, by anything.
 *   - On rejection the Underwriting record simply stays at Stage__c = 'In Progress' (its
 *     Stage__c does not change on rejection — the approval's entry criterion IS 'In Progress',
 *     and nothing moves it during the pending window). The ONLY durable record that a rejection
 *     happened is the approval history on the Underwriting record.
 *   - Consequently NO record-triggered automation can detect a rejection: a same-value field
 *     update is not a change, so an entry-scoped flow never fires. This is not an oversight that
 *     a cleverer trigger could fix; detecting it would require a new field, which was explicitly
 *     declined.
 *
 * The forward gate is unaffected and still fail-closed: a rejected underwriting is not
 * 'Approved', so Underwriting_Approved_Before_LOI still refuses Initiate LOI. The loss is the
 * REOPEN signal, not the gate.
 *
 * ── SHARING / ACCESS MODE ─────────────────────────────────────────────────────────────────────
 * The class is `with sharing` (project default, ARCHITECTURE.md §2). The parent write is NOT —
 * it lives in the narrow `private without sharing` inner class {@link ParentStampWriter}, which
 * holds nothing but that one DML. See its own header: `with sharing` on this class plus a
 * separately-justified escape on the single statement that needs it is exactly the shape
 * ARCHITECTURE.md §2 prescribes, and is the reason this class is not blanket `without sharing`.
 *
 * @see force-app/main/default/classes/ApprovalAuditService.cls (stamps the approver + timestamp)
 * @see force-app/main/default/classes/MarketDataSnapshotService.cls (the freeze this save fires)
 * @see force-app/main/default/classes/UnderwritingSelector.cls (ApprovalAutomationReads — all SOQL)
 */
public with sharing class UnderwritingApprovalStampService {

    /** The deal-level status value the market-data freeze keys its transition on. */
    private static final String STATUS_APPROVED_BY_PRINCIPALS = 'Approved by Principals';

    /**
     * Input for {@link #stampParent}.
     *
     * 🔴 PINNED — `underwritingId` is bound BY NAME from the Flow. Renaming it compiles cleanly
     * and breaks the Flow at runtime.
     */
    public class Request {
        @InvocableVariable(required=true label='Underwriting Id')
        public Id underwritingId;
    }

    /**
     * Stamps the principal approval of one or more Underwriting records onto their parent deals.
     *
     * Bulk-safe by construction: one selector read for the whole batch, one Database.update for
     * the whole batch, and no SOQL or DML inside any loop
     * (.claude/rules/apex-layering-rule.md). Idempotent — re-running it writes the same two
     * values, and because the freeze flow is transition-scoped a repeat save fires nothing.
     *
     * Silently skips, rather than failing, for: a null request, a null underwritingId, an
     * underwriting that no longer exists, and an underwriting whose Opportunity__c is blank
     * (a legal state — the lookup has deleteConstraint SetNull). Two requests naming two
     * underwritings on the SAME deal collapse to one update shell, so a deal is never listed
     * twice in one DML.
     *
     * @param requests one entry per approved Underwriting record (Flow passes a collection).
     */
    @InvocableMethod(
        label='Stamp Underwriting Approval To Deal'
        description='Writes UW Approved and Underwriting Status = Approved by Principals onto the parent deal of each approved Underwriting record, in a single save.'
    )
    public static void stampParent(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }

        Set<Id> underwritingIds = new Set<Id>();
        for (Request r : requests) {
            if (r == null || r.underwritingId == null) {
                continue;
            }
            underwritingIds.add(r.underwritingId);
        }
        if (underwritingIds.isEmpty()) {
            return;
        }

        // Map<Id, Opportunity> keyed by deal Id: de-duplicates two underwritings on one deal into
        // a single update shell, so the DML below can never list the same row twice.
        Map<Id, Opportunity> dealUpdates = new Map<Id, Opportunity>();
        for (Underwriting__c uw :
                new UnderwritingSelector.ApprovalAutomationReads().selectByIds(underwritingIds)) {
            if (uw.Opportunity__c == null) {
                continue; // orphan underwriting — nothing to mirror onto
            }
            // 🔴 BOTH FIELDS ON ONE SHELL. See the class header: the market-data freeze must see
            // the transition into 'Approved by Principals' on the same save as the rest.
            dealUpdates.put(uw.Opportunity__c, new Opportunity(
                Id = uw.Opportunity__c,
                UW_Approved__c = true,
                Underwriting_Status__c = STATUS_APPROVED_BY_PRINCIPALS
            ));
        }
        if (dealUpdates.isEmpty()) {
            return;
        }

        new ParentStampWriter().stamp(dealUpdates.values());
    }

    /**
     * The parent-deal write, and NOTHING else.
     *
     * 🔴 `without sharing` AND `AccessLevel.SYSTEM_MODE` ARE TWO SEPARATE REQUIREMENTS. Both are
     * needed, each fixes a different, separately-measured failure, and dropping either one
     * reintroduces a write that FAILS SILENTLY — which on this code path means an approved
     * underwriting whose deal never learns it was approved, and a market-data freeze that never
     * fires.
     *
     * 1. AccessLevel.SYSTEM_MODE (CRUD/FLS). This runs from a flow fired by the APPROVER, and the
     *    approving principals are deliberately READ-ONLY on Opportunity. A bare `update` inherits
     *    the calling flow's access mode. ApprovalAuditService.cls records the measurement from
     *    2026-08-05: setting <runInMode>SystemModeWithoutSharing</runInMode> on the calling flow
     *    did NOT lift the access mode, and the stamp "silently wrote nothing" until SYSTEM_MODE
     *    was stated at the DML itself. Stating it here means the write no longer depends on how
     *    any caller happens to be configured. Justified per ARCHITECTURE.md §2.
     *
     * 2. `without sharing` (record access). SYSTEM_MODE lifts CRUD/FLS but NEVER sharing. This
     *    project has already shipped that exact bug once: an approval's parent write failed for
     *    every approver who did not OWN the record, and passed in every test — because a test's
     *    approver IS the owner. Opportunity is OWD Private here and a principal approving another
     *    user's deal is the NORMAL case, not the exception. Inner classes do not inherit the outer
     *    class's sharing, so it is declared explicitly; the outer class stays `with sharing`.
     *
     * ⚠ allOrNone = true, deliberately. `Database.update(records, false, ...)` would let exactly
     * the failure this class exists to prevent be swallowed row-by-row with no exception at all —
     * the same partial-success pattern that hid failure #2 above. A failure here must be loud.
     */
    private without sharing class ParentStampWriter {
        void stamp(List<Opportunity> dealUpdates) {
            Database.update(dealUpdates, true, AccessLevel.SYSTEM_MODE);
        }
    }
}
