/**
 * Selector for Underwriting__c. Encapsulates ALL SOQL against Underwriting__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers:
 *   - OpportunityDocStatusController — Deal Summary card's Underwriting row
 *     (primary-else-latest, read-for-display, null-on-empty).
 *   - OpportunityApprovalService.submitForApproval — reads the clicked Underwriting record's
 *     Stage__c (selectStageRequiredById) to explain a refused approval submission.
 *     ⚠ CHANGED 2026-08-28. This line used to read "OpportunityApprovalController.resolveDealId —
 *     resolves the parent deal Id from a clicked Underwriting record (fetch-for-use, throws on
 *     miss)". The resolver was renamed to resolveApprovalTargetId AND stopped needing the parent:
 *     an Underwriting record is now its OWN approval target, so it returns the Id without a query.
 *   - UnderwritingApprovalStampService / ApprovalAuditService — the deal <-> child edge, via the
 *     ApprovalAutomationReads inner class at the bottom of this file (NOT via the USER_MODE
 *     methods above; see that class's header for the two separate justifications).
 *
 * Underwriting__c is a custom object — USER_MODE (P3 custom-field FLS gap = 0) for every method on
 * the OUTER class. ⚠ The ApprovalAutomationReads inner class is the documented exception.
 *
 * Two not-found contracts coexist, so two method families exist:
 *   - selectById / selectLatestByOpportunityId : read-for-display -> return null.
 *   - selectOpportunityIdRequiredById          : fetch-for-use    -> single-row
 *     SOQL assignment; a miss throws native System.QueryException, matching the
 *     original `[SELECT Opportunity__c FROM Underwriting__c WHERE Id = :recordId
 *     LIMIT 1].Opportunity__c` assignment in resolveDealId.
 *
 * Field lists are deliberately per-caller (P4 design §4 note 4): the doc-status
 * reads select the card fields; the approval resolver selects only Id +
 * Opportunity__c, keeping the USER_MODE FLS surface minimal.
 *
 * @see agent-output/p4-selector-design.md (§3 #9, §5)
 */
public with sharing class UnderwritingSelector {

    /**
     * The Underwriting designated as an Opportunity's primary (Primary_Underwriting__c).
     *
     * @param underwritingId Underwriting__c Id; null-safe.
     * @return The record with the Deal Summary fields set, or null when the input
     *         is null or the row does not exist.
     */
    public static Underwriting__c selectById(Id underwritingId) {
        if (underwritingId == null) {
            return null;
        }
        List<Underwriting__c> rows = [
            SELECT Id, Name, Stage__c, My_Price__c, Verdict__c, CreatedDate
            FROM Underwriting__c
            WHERE Id = :underwritingId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created Underwriting related to an Opportunity — the
     * fallback when no primary is designated.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return The latest related Underwriting (ORDER BY CreatedDate DESC LIMIT 1),
     *         or null when the input is null or the Opportunity has none.
     */
    public static Underwriting__c selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<Underwriting__c> rows = [
            SELECT Id, Name, Stage__c, My_Price__c, Verdict__c, CreatedDate
            FROM Underwriting__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Loads an Underwriting for parent-deal resolution.
     *
     * 🔴 NO PRODUCTION CALLER AS OF 2026-08-28 (only UnderwritingSelectorTest). It backed
     * OpportunityApprovalService's resolver, which no longer needs the parent at all — an
     * Underwriting record is its own approval target, so the resolver returns the Id without
     * querying. KEPT rather than deleted: it is the class header's worked example of the
     * fetch-for-use not-found contract, and deleting it would leave that paragraph pointing at
     * nothing. Do not treat the paragraph below as evidence of a live caller.
     *
     * FETCH-FOR-USE: the caller dereferenced `.Opportunity__c` off a single-row
     * assignment, so a miss is an error. Preserved via a single-row SOQL
     * assignment that throws native System.QueryException.
     *
     * @param underwritingId Underwriting__c Id; must reference an existing row.
     * @return The Underwriting with Id and Opportunity__c populated.
     * @throws System.QueryException when no Underwriting matches the Id.
     */
    public static Underwriting__c selectOpportunityIdRequiredById(Id underwritingId) {
        return [
            SELECT Id, Opportunity__c
            FROM Underwriting__c
            WHERE Id = :underwritingId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Underwritings related to a set of Opportunities — backs
     * OpportunityReviewService.createReviewRecords idempotency (drop any deal that
     * already has an Underwriting so entering the Underwriting stage never opens a
     * second). Added by Module A2: the A2 service repoint needs a bulk, set-based
     * existence read that A1's single-record methods do not provide. Bulk-safe.
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return Underwritings with Id and Opportunity__c populated; empty when the
     *         input is null or empty.
     */
    public static List<Underwriting__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Underwriting__c>();
        }
        return [
            SELECT Id, Opportunity__c
            FROM Underwriting__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * The Ids of Underwritings related to a set of Opportunities.
     *
     * 🔴 NO CALLER AS OF 2026-08-28 — READ THIS BEFORE "TIDYING" IT AWAY. The docstring below
     * is retained verbatim because its per-caller minimal-field-list REASONING is still the
     * governing convention for this class, but its factual claim ("backs ApprovalAuditService")
     * is now FALSE: ApprovalAuditService's block that advanced each related Underwriting to
     * Approved was deleted when the principal approval moved onto the Underwriting record
     * (the approval's own finalApprovalActions now writes Stage__c directly — this said
     * "Stage__c / Status__c" until 2026-09-02, when Underwriting__c.Status__c was retired), and
     * its replacement read needs Opportunity__c as well as Id, so it uses
     * {@link ApprovalAutomationReads.selectByOpportunityIds} instead.
     *
     * KEPT, NOT DELETED, on purpose: it is exercised by UnderwritingSelectorTest and it is the
     * canonical worked example of this class's "minimal field list per caller" rule, which the
     * paragraph below argues better than anything else in the file. Deleting it would cost that
     * argument to save one unused method.
     *
     * ── original docstring (claims about the caller are stale; the reasoning is not) ──
     * Backs ApprovalAuditService, which on principal sign-off advances each related
     * Underwriting to Approved (it needs only Id to build the update). Added by P4
     * cleanup wave G.
     *
     * DELIBERATELY DISTINCT from selectByOpportunityIds (which also selects
     * Opportunity__c): the audit read needs ONLY Id, and this selector's per-caller
     * "minimal field list" philosophy keeps the USER_MODE FLS surface as small as the
     * caller requires. The original ApprovalAuditService query was `SELECT Id`; adding
     * Opportunity__c here would widen the FLS surface (that custom lookup is
     * FLS-controlled) and could throw USER_MODE where the Id-only read would not.
     * Bulk-safe.
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return Underwritings with Id populated; an empty list when the input is null
     *         or empty (never null).
     */
    public static List<Underwriting__c> selectIdsByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Underwriting__c>();
        }
        return [
            SELECT Id
            FROM Underwriting__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * Loads an Underwriting for the generic stage-advance quick action — backs
     * RecordStageAdvanceService.advance.
     *
     * FETCH-FOR-USE: the caller reads the stage, derives the next one and writes it back, so a miss
     * is an error. Single-row SOQL assignment -> native System.QueryException, matching
     * OpportunitySelector.selectStageRequiredById.
     *
     * ⚠ RETIRED HAZARD, KEPT AS A RECORD 2026-09-02. This paragraph used to warn: "`Stage__c` (the
     * Path field), NOT the coarse `Status__c` this object also carries. Both exist, both hold
     * near-identical words ('Complete' vs 'Completed'), and ApprovalAuditService writes BOTH on
     * principal sign-off. Selecting the wrong one here would make the quick action advance a
     * reporting field while the Path never moved." 🟢 That hazard is GONE, not merely unlikely:
     * `Underwriting__c.Status__c` has been DELETED, so the wrong field can no longer be named at
     * all — a mis-select is now a compile error rather than a silent behavioural bug. (The warning
     * had also already decayed on its own terms: ApprovalAuditService stopped writing either field
     * on 2026-08-28; see the ⚠ DELETED block in that class.) Do not re-add a coarse status field
     * to this object without re-reading this note first.
     *
     * Field list is deliberately MINIMAL (Id + Stage__c) — see the per-caller note in the class
     * header.
     *
     * @param underwritingId Underwriting__c Id; must reference an existing row.
     * @return The Underwriting with Id and Stage__c populated.
     * @throws System.QueryException when no Underwriting matches the Id.
     */
    public static Underwriting__c selectStageRequiredById(Id underwritingId) {
        return [
            SELECT Id, Stage__c
            FROM Underwriting__c
            WHERE Id = :underwritingId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Underwriting reads performed ON A PRINCIPAL'S BEHALF by approval automation, rather than
     * at the running user's request. Added 2026-08-28 with the move of the principal approval
     * onto Underwriting__c.
     *
     * 🔴 THIS INNER CLASS ESCAPES BOTH FLS *AND* SHARING, AND THOSE ARE TWO SEPARATE DECISIONS.
     * ARCHITECTURE.md §2 requires each to be justified at its own declaration, so:
     *
     * 1. `WITH SYSTEM_MODE` (the automation-path exception, ARCHITECTURE.md §2). Both callers run
     *    inside an after-save flow fired by the APPROVER's decision, not by a user asking to read
     *    anything. Under USER_MODE a single field the approving principal lacks FLS on raises
     *    `System.QueryException: No such column` — an FLS denial wearing a schema error — which
     *    from a flow-invoked Apex action aborts the approval save itself. Every DPEG persona is on
     *    Minimum Access and a Metadata-API-deployed field arrives with no FLS for anyone, so this
     *    is the default case for automation here, not an edge case.
     *
     * 2. `without sharing` (the inner class). SYSTEM_MODE lifts CRUD/FLS but NEVER sharing, and
     *    that distinction has already cost this project a live incident: an approval's parent
     *    write "silently wrote nothing" for every approver who did not OWN the record, and worked
     *    only when approver == owner — which is exactly what every test does, so no test caught
     *    it. Underwriting__c is OWD Private with ZERO sharing rules, so an approving principal
     *    who lacks View All reads an EMPTY list here — and an empty list is indistinguishable
     *    from "not approved", turning the mirror stamp into a silent no-op. Inner classes do not
     *    inherit the outer class's sharing, so `without sharing` is stated explicitly; the outer
     *    UnderwritingSelector stays `with sharing` (project default) and every method above it
     *    is unchanged USER_MODE.
     *
     * Scope is kept as narrow as the rule demands: two reads, both Id + Opportunity__c only.
     * Apex forbids static methods on inner classes, so these are instance methods — call
     * `new UnderwritingSelector.ApprovalAutomationReads().selectByOpportunityIds(...)`.
     *
     * @see force-app/main/default/classes/ProcessInstanceStepSelector.cls (AuditReads — the
     *      precedent this mirrors exactly)
     */
    public without sharing class ApprovalAutomationReads {

        /**
         * The parent Opportunity of each of a set of Underwritings — backs
         * UnderwritingApprovalStampService, which mirrors an approved underwriting's decision
         * onto its deal and therefore needs the child -> parent edge in bulk.
         *
         * NOT-FOUND CONTRACT — read-for-automation: returns a List (never null). A missing row,
         * or a row whose Opportunity__c is blank, simply does not appear / carries null, and the
         * caller skips it. An orphan underwriting is a legal state (Opportunity__c is a Lookup
         * with deleteConstraint SetNull), so it must not throw.
         *
         * @param underwritingIds Underwriting__c Ids; null/empty-safe.
         * @return Underwritings with Id and Opportunity__c populated; empty when the input is
         *         null or empty (never null).
         */
        public List<Underwriting__c> selectByIds(Set<Id> underwritingIds) {
            if (underwritingIds == null || underwritingIds.isEmpty()) {
                return new List<Underwriting__c>();
            }
            return [
                SELECT Id, Opportunity__c
                FROM Underwriting__c
                WHERE Id IN :underwritingIds
                WITH SYSTEM_MODE
            ];
        }

        /**
         * The Underwritings related to a set of Opportunities — backs ApprovalAuditService, which
         * must map each deal to its underwriting child(ren) in order to read THE CHILD's approval
         * history (the deal no longer has any).
         *
         * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
         * @return Underwritings with Id and Opportunity__c populated; empty when the input is
         *         null or empty (never null).
         */
        public List<Underwriting__c> selectByOpportunityIds(Set<Id> opportunityIds) {
            if (opportunityIds == null || opportunityIds.isEmpty()) {
                return new List<Underwriting__c>();
            }
            return [
                SELECT Id, Opportunity__c
                FROM Underwriting__c
                WHERE Opportunity__c IN :opportunityIds
                WITH SYSTEM_MODE
            ];
        }
    }
}
