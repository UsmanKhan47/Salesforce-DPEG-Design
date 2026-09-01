/**
 * Mirrors an APPROVED LOI__c record's decision onto its parent Opportunity.
 *
 * Added 2026-09-01 as W1 of the LOI approval cutover
 * (agent-output/loi-approval-cutover-design.md), which moves the principal LOI approval OFF the
 * Opportunity and ONTO the LOI__c record. The new approval's own finalApprovalActions write the
 * child's LOI_Status__c; this invocable writes the ONE deal-level mirror field the rest of the
 * application still reads. Called from the after-save record-triggered flow on LOI__c that fires
 * when the approval is granted.
 *
 * Direct sibling of {@link UnderwritingApprovalStampService} (2026-08-28). Same shape, same
 * reasoning, different object — read that class alongside this one; where the two diverge it is
 * called out below.
 *
 * ── 🔴 THE INVOCABLE CONTRACT IS PINNED. DO NOT VARY IT. ──────────────────────────────────────
 * The declarative stream builds its Flow against these exact names, and a Flow binds an Apex
 * action by CLASS NAME and its inputs by @InvocableVariable FIELD NAME. Renaming the class, the
 * method, the inner `Request` type or the `loiId` member breaks that Flow at RUNTIME, not at
 * compile time, and the failure surfaces as an approval that silently stops mirroring:
 *     class  : LoiApprovalStampService
 *     method : stampParent(List<Request>)
 *     label  : 'Stamp LOI Approval To Deal'
 *     input  : Request.loiId (Id, required)
 *
 * ── 🔴 WHY THIS CLASS EXISTS AT ALL, AND WHY IT MUST LAND BEFORE ANYTHING IS RETIRED ──────────
 * An approval process can field-update only its own record or a MASTER-DETAIL parent, and
 * `LOI__c.Opportunity__c` is a LOOKUP. So an approval parented by LOI__c is STRUCTURALLY unable to
 * write any Opportunity field. Both of the retiring process's field updates were Opportunity
 * writes, so 100% of them are unreachable from the new one; this class replaces the half that is
 * still wanted.
 *
 * VERIFIED 2026-09-01, not inherited from the design document — a repo-wide grep for
 * `LOI_Approved__c` across classes, flows, workflows, objects and scripts (the profiles and
 * permissionsets directories excluded as grants, not writers) returns exactly ONE production writer:
 * `workflows/Opportunity.workflow-meta.xml` -> `Set_LOI_Approved_Flag`, the retiring approval's
 * finalApprovalAction. There is NO Apex writer today. Every other hit is a reader
 * (`Approved_LOI_Before_PSA`, `Deal_Sub_Stage__c`, `flows/LOI_Approval_Stamp`), a test fixture
 * (`TestDataFactory.placeApprovedLoi`) or a seed script.
 *
 * ⇒ Deactivating `Opportunity.LOI_Approval` with this class absent leaves
 *   `Approved_LOI_Before_PSA` (`ISBLANK(Primary_LOI__c) OR NOT(LOI_Approved__c)`) with NOTHING
 *   that can satisfy it, and every deal in the org is blocked out of `Under Contract (PSA)`
 *   permanently, with no route out that a user can perform. That is the whole reason W1 exists and
 *   is deployed and PROVEN before W5.
 *
 * ── WHAT IT WRITES, AND WHY IT IS ONE FIELD IN ONE DML ────────────────────────────────────────
 * Per Opportunity, in a SINGLE Database.update:
 *     LOI_Approved__c = true
 *
 * ONE field, deliberately — the retiring `finalApprovalActions` had exactly one action and this
 * mirrors it exactly. `Opportunity.Deal_Sub_Stage__c` is a FORMULA reading this flag and follows
 * it for free; no second write is wanted or correct.
 *
 * 🔴 ONE SAVE, NOT TWO, AND THAT IS A CORRECTNESS REQUIREMENT RATHER THAN A STYLE CHOICE. The
 * downstream consumer is `flows/LOI_Approval_Stamp` — an after-save flow on Opportunity with
 * `doesRequireRecordChangedToMeetCriteria = true` and the filter `LOI_Approved__c EqualTo true` —
 * which performs THREE actions in order: `ApprovalAuditService(gate='LOI')`, then TWO
 * `GroupNotifier` notifications to humans (LOI_Panel, and Acquisitions_Team "LOI approved - send
 * to broker"). A transition-scoped flow fires on the SAVE that carries the change. Splitting this
 * write, or writing the flag on a save that does not also carry the rest of the change, either
 * loses the transition or hands the flow a half-formed record. One shell per deal, one update,
 * always.
 *
 * IDEMPOTENT BY CONSTRUCTION. Re-running writes the same value; because the consumer is
 * transition-scoped, a repeat save fires nothing. This matters because the approval's field update
 * and the audit stamp both land in the same cascade.
 *
 * ── 🔴 ACCEPTED, DOCUMENTED REGRESSION: REJECTION IS NOT HANDLED HERE, AND THE DEAL IS NOT
 *      REWOUND ─────────────────────────────────────────────────────────────────────────────────
 * A deliberate user decision (D-3, 2026-09-01), quoted rather than paraphrased: *"The LOI stage
 * will remain on Under review after rejection."* It is recorded plainly rather than engineered
 * around. There is NO reject path in this class, no `finalRejectionActions` that moves a stage,
 * and NOTHING anywhere clears the mirror on a rejection.
 *
 * What that costs, precisely:
 *   - The retired `Opportunity.LOI_Approval` had a `Set_Stage_Underwriting` finalRejectionAction
 *     that rewound the deal a full stage, `LOI -> Underwriting`, so it visibly returned for
 *     rework. THAT BEHAVIOUR IS GONE. Nothing rewinds the deal on an LOI rejection any more.
 *   - The LOI itself simply stays at `Stage__c = 'Under Review'` — the stage the approval is
 *     entered from, and nothing moves it during the pending window.
 *   - `Is_Advance_Allowed__c` keeps a non-approved LOI correctly pinned at 'Under Review' (its
 *     formula requires `TEXT(LOI_Status__c) = "Approved"` for an Acquisition_LOI at that stage —
 *     verified against the field's own formula on 2026-09-01, not taken from the design), so a
 *     rejected LOI cannot advance. The loss is the deal-level REWIND signal, not the gate.
 *
 * 🔴 TWO TESTS PIN THE OLD BEHAVIOUR AND ONE OF THEM WILL GO RED. Named here so whoever finds them
 * red knows it was intended and does not "fix" the code back:
 *   - `LoiGateTest.rejectionReturnsDealToUnderwriting` — asserts the deal returns to
 *     'Underwriting'. Fails twice over after W5: the Opportunity submission itself stops resolving
 *     to an applicable process, AND the rewind is gone by this decision. RETIRE OR REPOINT IT
 *     CONSCIOUSLY; do not rebuild the rewind.
 *   - `LoiGateTest.directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval` — 🟢
 *     UNAFFECTED (it calls no `Approval.process`), and after W5 it becomes the ONLY remaining pin
 *     on `No_Backward_Stage_Movement` CARVE-OUT 1. Protect it.
 * ⚠ An Apex substitute for the rewind was considered and is NOT built. It would newly have to
 * satisfy `NDA_Signed_Before_Deal_Progression` and `No_Backward_Stage_Movement`, which the
 * approval field update bypassed (this org's measured finding that approval field updates skip
 * validation rules). A rejection could then be REFUSED. Do not add a compensating automation
 * without reopening D-3 with the user.
 *
 * ── 🔴 THE PSA GATE IS DELIBERATELY LEFT WHERE IT IS (D-2) ────────────────────────────────────
 * `Approved_LOI_Before_PSA` continues to read `Opportunity.LOI_Approved__c`. It is NOT repointed
 * at the child's own field and there is NO backfill, because this class writes the field the gate
 * already reads — which is the entire point of building it. Anyone tempted to "tidy" that gate
 * onto `Primary_LOI__r.LOI_Status__c` is reopening a decision that was consciously declined.
 *
 * ── WHAT THIS CLASS DOES *NOT* DO, SO NOBODY LOOKS FOR IT HERE ────────────────────────────────
 *   - It does NOT stamp the approver / date / comments onto the LOI. That is
 *     `ApprovalAuditService`'s LOI branch, from real approval history, on the save this write
 *     triggers. Inventing those values here would be worse than stamping them one save later —
 *     see that class for the argument.
 *   - It does NOT write `LOI_Status__c`. The new approval's own finalApprovalActions writes it
 *     directly on the LOI (see the marker note below); a second writer here would be a race with
 *     the audit stamp for no gain.
 *   - It does NOT touch `Stage__c` on either record. `LOI__c.Stage__c` is `restricted` and its
 *     record-type subsets differ, and restriction IS enforced by Apex DML in this org — a refusal
 *     inside an approval transaction rolls the approval back and tells the approver nothing
 *     intelligible.
 *
 * ── THE TRIGGERING MARKER (D-4), STATED HERE BECAUSE THIS CLASS IS INERT WITHOUT IT ───────────
 * The mirror flow must key on `LOI_Status__c` CHANGING TO 'Approved', with
 * `recordTriggerType = Update` and `doesRequireRecordChangedToMeetCriteria = true`. BOTH settings
 * are load-bearing and each was verified against a real call site on 2026-09-01:
 *   - `CreateAndUpdate` would fire on `TestDataFactory.placeApprovedLoi`, which INSERTS the LOI
 *     already at 'Approved'. Three of its callers insert 251 rows in one DML
 *     (`ContractExecutionServiceTest.bulkExecution251ContractsHandsOffToTransactions`,
 *     `ContractExecutionServiceTest.bulkExecution251AcquisitionPsasOpen251Offerings`,
 *     `ContractReviewTriggerHandlerTest.bulk251ExecutedContractsHandOff`).
 *   - Dropping `doesRequireRecordChangedToMeetCriteria` would fire on the LATER update those same
 *     two ContractExecutionServiceTest methods make (`Stage__c = 'Signed'` while LOI_Status__c is
 *     unchanged at 'Approved') — 251 rows again, cascading 251 Opportunity saves into a test that
 *     is measuring a governor budget.
 * With both set, no existing fixture, seed or production path produces the TRANSITION: the only
 * other production writers of `LOI_Status__c` are `CounterOfferService` ('Countered') and
 * `ApprovalAuditService` ('Approved', but only downstream of this write, by which point the value
 * is already 'Approved' so there is no transition and no loop).
 *
 * ── SHARING / ACCESS MODE ─────────────────────────────────────────────────────────────────────
 * 🔴 THE PARENT WRITE ESCAPES SHARING, AND THAT IS LOAD-BEARING, NOT BELT-AND-BRACES. It lives in
 * the narrow `private without sharing` inner class {@link ParentStampWriter}, which holds nothing
 * but that one DML; the full three-part justification is at that class's own declaration, as
 * ARCHITECTURE.md §2 requires. In short: this runs as the APPROVER, who is READ-ONLY on
 * Opportunity and does NOT own the deal, so SYSTEM_MODE alone is not enough — SYSTEM_MODE lifts
 * CRUD/FLS and NEVER sharing, and this project has already shipped that exact bug.
 *
 * The OUTER class stays `with sharing` (project default, ARCHITECTURE.md §2), which is the shape
 * §2 explicitly prescribes — `with sharing` plus a separately-justified escape on the single
 * statement that needs it, never `without sharing` across a whole class. `UnderwritingApprovalStampService`
 * is the live precedent. The SOQL takes the same two escapes for the same reasons and lives in
 * `LoiSelector.ApprovalAutomationReads`.
 *
 * @see force-app/main/default/classes/UnderwritingApprovalStampService.cls (the reference shape)
 * @see force-app/main/default/classes/ApprovalAuditService.cls (stamps the approver + timestamp)
 * @see force-app/main/default/classes/LoiSelector.cls (ApprovalAutomationReads — all SOQL)
 * @see agent-output/loi-approval-cutover-design.md (§0.2, §5.1, D-2, D-3, D-4)
 */
public with sharing class LoiApprovalStampService {

    /**
     * Input for {@link #stampParent}.
     *
     * 🔴 PINNED — `loiId` is bound BY NAME from the Flow. Renaming it compiles cleanly and breaks
     * the Flow at runtime.
     */
    public class Request {
        @InvocableVariable(required=true label='LOI Id')
        public Id loiId;
    }

    /**
     * Stamps the principal approval of one or more LOI records onto their parent deals.
     *
     * Bulk-safe by construction: one selector read for the whole batch, one Database.update for
     * the whole batch, and no SOQL or DML inside any loop
     * (.claude/rules/apex-layering-rule.md). Idempotent — re-running it writes the same value, and
     * because the consumer flow is transition-scoped a repeat save fires nothing.
     *
     * Silently SKIPS, rather than failing, for: a null request list, an empty list, a null entry,
     * a null loiId, an LOI that no longer exists, and an LOI whose Opportunity__c is blank (a
     * legal state — the lookup has deleteConstraint SetNull, and a sell-side LOI hangs off
     * Disposition__c and has no Opportunity at all). Two requests naming two LOIs on the SAME deal
     * collapse to one update shell, so a deal is never listed twice in one DML.
     *
     * ⚠ SKIPPING IS NOT THE SAME AS TOLERATING FAILURE. Everything above is a shape that legally
     * has no parent to stamp. Once there IS a parent to stamp, the write is `allOrNone = true` and
     * a failure THROWS — see {@link ParentStampWriter}.
     *
     * @param requests one entry per approved LOI record (Flow passes a collection).
     */
    @InvocableMethod(
        label='Stamp LOI Approval To Deal'
        description='Writes LOI Approved = true onto the parent deal of each approved LOI record, in a single save.'
    )
    public static void stampParent(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }

        Set<Id> loiIds = new Set<Id>();
        for (Request r : requests) {
            if (r == null || r.loiId == null) {
                continue;
            }
            loiIds.add(r.loiId);
        }
        if (loiIds.isEmpty()) {
            return;
        }

        // Map<Id, Opportunity> keyed by deal Id: de-duplicates two LOIs on one deal into a single
        // update shell, so the DML below can never list the same row twice.
        Map<Id, Opportunity> dealUpdates = new Map<Id, Opportunity>();
        for (LOI__c loi : new LoiSelector.ApprovalAutomationReads().selectByIds(loiIds)) {
            if (loi.Opportunity__c == null) {
                continue; // orphan or sell-side LOI — nothing to mirror onto
            }
            // A minimal shell, never the queried record: this write must carry ONE field, so it
            // cannot re-send a stale value the selector happened to read.
            dealUpdates.put(loi.Opportunity__c, new Opportunity(
                Id = loi.Opportunity__c,
                LOI_Approved__c = true
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
     * reintroduces a write that FAILS SILENTLY — which on this code path means an approved LOI
     * whose deal never learns it was approved, and therefore a deal blocked out of
     * `Under Contract (PSA)` by `Approved_LOI_Before_PSA` with no error and no route out.
     *
     * 1. AccessLevel.SYSTEM_MODE (CRUD/FLS). This runs from a flow fired by the APPROVER, and the
     *    approving principals are deliberately READ-ONLY on Opportunity — measured, not assumed:
     *    `DPEG_Acquisition_View` carries `Opportunity` with `allowEdit=false` /
     *    `modifyAllRecords=false` (:1866-1874), and `ApprovalAuditService` (:167-169) records the
     *    same finding from production ("DPEG Principal PSG: Read yes, Edit no, measured"). A bare
     *    `update` inherits the calling flow's access mode. ApprovalAuditService also records the
     *    2026-08-05 measurement that setting `<runInMode>SystemModeWithoutSharing</runInMode>` on
     *    the calling flow did NOT lift the access mode and the stamp "silently wrote nothing"
     *    until SYSTEM_MODE was stated at the DML itself. Stating it here means the write no longer
     *    depends on how any caller happens to be configured. Justified per ARCHITECTURE.md §2.
     *    ⚠ Note the failure is not even a DmlException: when a principal lacked Edit on
     *    Opportunity the platform threw `System.TypeException` ('DML operation UPDATE not allowed
     *    on Opportunity'), which a DmlException-only catch does not see.
     *
     * 2. `without sharing` (record access). SYSTEM_MODE lifts CRUD/FLS but NEVER sharing. This
     *    project has already shipped that exact bug once: an approval's parent write failed for
     *    every approver who did not OWN the record, and passed in every test — because a test's
     *    approver IS the owner. Opportunity is OWD Private here, the approving principals hold
     *    `viewAllRecords` (READ-only record access, which does not confer Edit), and a principal
     *    approving another user's deal is the NORMAL case, not the exception. Inner classes do not
     *    inherit the outer class's sharing, so it is declared explicitly; the outer class stays
     *    `with sharing`.
     *
     * ⚠ allOrNone = true, deliberately. `Database.update(records, false, ...)` would let exactly
     * the failure this class exists to prevent be swallowed row-by-row with no exception at all —
     * the same partial-success pattern that hid failure #2 above. A failure here must be loud, and
     * loud is affordable: the caller is an approval decision a human is watching, not a batch.
     */
    private without sharing class ParentStampWriter {
        void stamp(List<Opportunity> dealUpdates) {
            Database.update(dealUpdates, true, AccessLevel.SYSTEM_MODE);
        }
    }
}
