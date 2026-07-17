/**
 * Selector for ProcessInstanceStep (approval history). Encapsulates ALL SOQL
 * against ProcessInstanceStep per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * P4 cleanup wave G. Sole consumer: ApprovalAuditService.latestApprovedStepByTarget
 * (the invocable that stamps the approving principal + time onto the deal gate's
 * audit fields by reading who actually acted on the approval).
 *
 * ── MODE + SHARING (the deliberate exception on this object) ──────────────────
 * ApprovalAuditService is an AUDIT service declared `without sharing`, and its
 * ProcessInstanceStep read had NO `WITH` clause (legacy system-mode FLS). An audit
 * stamp MUST see the FULL approval trail — the final approver is frequently NOT the
 * running user (an after-save flow triggers the stamp), so the read cannot be scoped
 * to the running user's sharing or FLS without silently dropping the very steps it
 * exists to record. To PRESERVE that all-records visibility exactly, the audit query
 * lives in the nested `without sharing` {@link AuditReads} class and uses
 * `WITH SYSTEM_MODE` (API 67):
 *   - `without sharing` (inner class) reproduces the original all-records reach —
 *     inner classes do NOT inherit the outer class's sharing, so it is declared
 *     explicitly; the outer selector stays `with sharing` (project default).
 *   - `WITH SYSTEM_MODE` bypasses FLS, reproducing the original no-WITH-clause read.
 * Together they reproduce the original `without sharing` + system-mode behavior with
 * zero visibility change to the approval trail.
 *
 * This mirrors the established codebase precedent for a selector method that must
 * run without sharing: ContactSelector.GuestReads (guest broker-priority read).
 *
 * CONTRAST with the sibling ProcessInstanceSelector, which is `with sharing` +
 * USER_MODE: that selector backs a DUPLICATE-SUBMISSION guard the submitting user
 * runs against their OWN deal, so the running user's sharing is correct there. The
 * two selectors differ because their consumers have different visibility needs — an
 * audit read of the full trail vs. a user's read of their own pending approval.
 *
 * NOT-FOUND CONTRACT — read-for-audit: returns a List (never null), ordered newest
 * first, so the caller can fold it into a newest-per-target Map. A target with no
 * 'Approved' step is a normal state (the approval may still be pending) and yields
 * an empty list, not an exception.
 *
 * @see force-app/main/default/classes/ContactSelector.cls (GuestReads precedent)
 * @see force-app/main/default/classes/ProcessInstanceSelector.cls (USER_MODE sibling)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class ProcessInstanceStepSelector {

    // Apex forbids static members on inner classes, so this constant lives on the
    // top-level class and is bound into the AuditReads query below.
    private static final String STEP_STATUS_APPROVED = 'Approved';

    /**
     * Approval-trail reads that MUST run WITHOUT SHARING.
     *
     * `without sharing` — an audit stamp must see every 'Approved' step regardless
     * of the running user's sharing (see the class header). Inner classes do NOT
     * inherit the outer class's sharing, so it is declared explicitly here; the
     * outer ProcessInstanceStepSelector stays `with sharing`. Apex forbids static
     * methods on inner classes, so this is an instance method — call
     * `new ProcessInstanceStepSelector.AuditReads().selectApprovedStepsByTargetIds(...)`.
     */
    public without sharing class AuditReads {

        /**
         * The 'Approved' approval-history steps targeting a set of records, newest
         * first — backs ApprovalAuditService's newest-approved-step-per-target fold.
         * Selects the approver (ActorId), their Comments, the CreatedDate, and the
         * step's target (ProcessInstance.TargetObjectId) so the caller can key by
         * target. Filters StepStatus = 'Approved' so pending / rejected / started
         * steps are excluded, and orders CreatedDate DESC so the caller's first-wins
         * fold keeps the latest approval per target.
         *
         * SYSTEM_MODE (API 67) bypasses FLS; the enclosing `without sharing` bypasses
         * record sharing — together reproducing the original ApprovalAuditService
         * all-fields / all-records approval-trail read.
         *
         * @param targetIds The records the approvals target (deal Ids); null/empty-safe.
         * @return 'Approved' ProcessInstanceStep rows for the targets, ordered
         *         CreatedDate DESC; an empty list when the input is null/empty or no
         *         target has an approved step (never null).
         * @example
         * List<ProcessInstanceStep> steps =
         *     new ProcessInstanceStepSelector.AuditReads().selectApprovedStepsByTargetIds(targetIds);
         */
        public List<ProcessInstanceStep> selectApprovedStepsByTargetIds(Set<Id> targetIds) {
            if (targetIds == null || targetIds.isEmpty()) {
                return new List<ProcessInstanceStep>();
            }
            return [
                SELECT ActorId, Comments, CreatedDate, ProcessInstance.TargetObjectId
                FROM ProcessInstanceStep
                WHERE ProcessInstance.TargetObjectId IN :targetIds
                      AND StepStatus = :STEP_STATUS_APPROVED
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
            ];
        }
    }
}
