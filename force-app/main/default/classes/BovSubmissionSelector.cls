/**
 * Selector for BOV_Submission__c. Encapsulates ALL SOQL against
 * BOV_Submission__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumers:
 *   - BovController.getSubmissions (the broker-outreach matrix on the Disposition
 *     record page)                                    -> selectByDispositionId
 *   - DispositionApprovalService.submitForApproval, the `BOV Outreach` branch
 *     (2026-08-19 flow redesign)                      -> selectSelectedByDispositionId
 *   - BovSubmissionService.replaceSelectedBroker
 *     (2026-08-19 flow redesign)                      -> selectStatusesByDispositionId
 *   - BovSubmissionSelectionGuardService.enforceSingleSelected, the before-context
 *     single-Selected trigger guard (2026-08-20,
 *     Tranche 2 Workstream A2)                        -> selectSelectedByDispositionIds
 *
 * ⚠ MIXED MODES SINCE 2026-08-19 — READ THE METHOD, NEVER THIS HEADER. ⚠ CORRECTED 2026-08-20: this
 * paragraph used to say "Two methods are `WITH USER_MODE`; `selectStatusesByDispositionId` is
 * `WITH SYSTEM_MODE`", which was a COUNT and counts decay. It is now TWO of FOUR either way —
 * `selectStatusesByDispositionId` and `selectSelectedByDispositionIds` (the trigger guard's read)
 * are `WITH SYSTEM_MODE` under the ARCHITECTURE.md §2 automation-path exception, each justified at
 * its OWN declaration, which is where §2 says the authoritative inventory lives. 🔴 DO NOT TRUST A
 * NUMBER IN THIS HEADER — `NdaSelector`'s header records that this repo has already miscounted its
 * own SYSTEM_MODE inventory once. Re-count; do not assert.
 * ⚠ AN EARLIER SENTENCE HERE WAS REASONING FROM THE WRONG TEST and is retracted verbatim so nobody
 * re-derives it: "There is no guest path for the Disposition module, so no SYSTEM_MODE appears
 * here." The exception is about reads the running user never asked for, and about fields the running
 * user may not hold — not about anonymous ones.
 *
 * MODE (the two USER_MODE reads) — BOV_Submission__c is a custom object; P3 proved the
 * custom-field FLS gap is 0, so USER_MODE is safe and enforces the running user's sharing + FLS.
 * Neither of those two reads touches `Approval_Status__c`, which is the field that forced
 * `selectStatusesByDispositionId` the other way. (`selectSelectedByDispositionIds` is SYSTEM_MODE
 * for a different reason again — the CALLER, not the field. Read it there.)
 *
 * NOT-FOUND CONTRACT — read-for-display: a Disposition with no BOV submissions is
 * a normal state, so the list methods return their natural empty List, never null,
 * and `selectSelectedByDispositionId` returns null rather than throwing (its caller
 * raises the AUTHORED "no broker is marked Selected yet" error, which is the whole
 * reason it must not be a fetch-for-use throw).
 * The dispositionId is bound straight into the WHERE clause, mirroring the exact
 * query semantics of the relocated getSubmissions statement (which had no
 * pre-query null guard).
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class BovSubmissionSelector {

    /**
     * The `Submission_Status__c` value that marks the appointed broker.
     *
     * ⚠ A bind variable, not an inline literal, because the picklist is RESTRICTED to exactly
     * {Backup, Selected} — so this string is half the value set and a typo here would return an
     * empty list forever rather than failing. `BovSubmissionService` and
     * `BovSubmissionTriggerHandler` each hold their own copy for their own layer; this one is the
     * selector's.
     */
    @TestVisible
    private static final String STATUS_SELECTED = 'Selected';

    /**
     * All BOV submissions for one Disposition, highest-scoring first — backs the
     * broker-outreach matrix (BovController.getSubmissions).
     *
     * BOV_Score__c is a Number, so the ORDER BY is a numeric sort (DESC NULLS
     * LAST); unscored submissions fall to the bottom. The field list is the exact
     * set BovController.BovRow maps, so narrowing it would reintroduce a
     * "row retrieved via SOQL without querying the requested field" defect.
     *
     * @param dispositionId Disposition__c Id whose submissions to read.
     * @return The matching BOV_Submission__c records ordered by BOV_Score__c
     *         DESC NULLS LAST; an empty list when the Disposition has none (or
     *         when dispositionId is null).
     * @example
     * List<BOV_Submission__c> subs =
     *     BovSubmissionSelector.selectByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectByDispositionId(Id dispositionId) {
        return [
            SELECT Id, Broker_Firm__c, Contact_Name__c, BOV_Amount__c,
                   Commission_Rate__c, Days_To_Market__c, Hist_Success_Rate__c,
                   Cap_Rate__c, BOV_Score__c, Submission_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY BOV_Score__c DESC NULLS LAST
        ];
    }

    /**
     * The ONE submission a Disposition has marked `Selected`, or null when it has none — backs
     * `DispositionApprovalService.submitForApproval`'s `BOV Outreach` branch, which submits THAT
     * RECORD (not the Disposition) into `Broker_Finalize_Approval`.
     *
     * 🔴 NULL IS A FIRST-CLASS ANSWER HERE AND MUST STAY ONE. "No broker is Selected yet" is the
     * single most likely reason a Submit Selected Broker click fails, and it is entirely
     * user-actionable: pick a broker in the comparison matrix first. A fetch-for-use throw would
     * turn that into a `System.QueryException` the controller masks as "could not be submitted…
     * contact your administrator" — advice that sends the user to the wrong person. The caller
     * converts this null into an AUTHORED message naming the fix.
     *
     * ⚠ `Submission_Status__c` IS RESTRICTED TO {Backup, Selected} (measured in the field
     * metadata), so "Selected" is not one value among many — it is one of the only two. The
     * `LIMIT 1` therefore reflects a business invariant (`BovSubmissionService` demotes the
     * incumbent in the same DML that promotes the challenger) rather than an arbitrary cap. If
     * two rows are ever Selected the highest-scoring one wins here, which is the same ordering the
     * matrix displays — deterministic, and the invariant is repaired by a replace, not by this
     * read.
     *
     * ⚠ `Approval_Status__c` IS DELIBERATELY NOT SELECTED. It is a 2026-08-19 field, and a
     * Metadata-API-deployed custom field arrives with NO FLS for any profile — so selecting it
     * here would take this `WITH USER_MODE` read down for everyone until the permission-set deploy
     * lands, on a field this caller does not use. `selectStatusesByDispositionId` needs it, and
     * pays SYSTEM_MODE for it.
     *
     * @param dispositionId Disposition__c Id whose Selected submission to read; null-safe.
     * @return The Selected BOV_Submission__c (highest-scoring, if somehow more than one), or null
     *         when the Disposition has no Selected submission.
     * @example
     * BOV_Submission__c selected = BovSubmissionSelector.selectSelectedByDispositionId(dispId);
     */
    public static BOV_Submission__c selectSelectedByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return null;
        }
        List<BOV_Submission__c> selected = [
            SELECT Id, Broker_Firm__c, Contact_Name__c, Submission_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId AND Submission_Status__c = :STATUS_SELECTED
            WITH USER_MODE
            ORDER BY BOV_Score__c DESC NULLS LAST
            LIMIT 1
        ];
        return selected.isEmpty() ? null : selected[0];
    }

    /**
     * Every submission's SELECTION STATE for one Disposition — backs
     * `BovSubmissionService.replaceSelectedBroker`, which demotes the incumbent to `Backup` and
     * clears its `Approval_Status__c` in the same DML that promotes the challenger.
     *
     * 🔴 IT MUST RETURN EVERY ROW, NOT JUST THE SELECTED ONE. The replace is an EXCLUSIVITY
     * operation: after it, exactly one submission is `Selected`. A read scoped to
     * `Submission_Status__c = 'Selected'` would find the incumbent and miss a SECOND incumbent left
     * behind by an earlier partial failure, so the repair would leave the invariant broken and the
     * `Broker_Finalize_Approval` entry criterion (`Submission_Status__c = 'Selected'`) matching two
     * records. Reading all of them is what makes the operation self-healing.
     *
     * ── 🔴 WITH SYSTEM_MODE — THE FIELD, NOT THE CALLER, IS WHAT FORCES IT ──────
     * `Approval_Status__c` is a 2026-08-19 field. A Metadata-API-deployed custom field arrives with
     * NO field permissions for ANY profile, System Administrator included, and even after the
     * permission-set deploy it is granted READ ONLY on the two disposition sets (it is written by
     * an approval process, never by hand). `USER_MODE` THROWS rather than degrades, so a
     * `USER_MODE` read of this field would refuse the replace for EVERYONE in the deploy window and
     * for any principal outside those two sets afterwards — with
     * `System.QueryException: No such column 'Approval_Status__c'`, an FLS denial wearing a schema
     * error. That is the exact failure ARCHITECTURE.md §2's exception exists for.
     *
     * ⚠ IT ALSO KEEPS THE READ AND THE WRITE FROM DISAGREEING. `BovSubmissionService` writes these
     * rows with `AccessLevel.SYSTEM_MODE` for the same reason; a `USER_MODE` read feeding a
     * `SYSTEM_MODE` write is a shape where the write is permitted and the read that decides WHAT to
     * write is not.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE — this class stays
     * `with sharing`. A submission the running user cannot SEE is absent, so it is not demoted, and
     * the exclusivity invariant would be left broken. That is accepted rather than fixed with a
     * `without sharing` inner class, on measured grounds: both `DPEG_Disposition_View` and
     * `DPEG_Disposition_Edit` carry `viewAllRecords = true` on the disposition child objects, and
     * the caller is a human standing on the Disposition record page reading the very matrix these
     * rows render. Widening a live authorization boundary on speculation is what this repo declines
     * to do elsewhere (see `DispositionSelector.selectListingClockByIds`); the shape to reach for
     * if that ever changes is a `private without sharing` inner class holding only this query,
     * after `DispositionOfferSelector.TractionReads`.
     *
     * ⚠ `Broker__c` WAS ADDED TO THIS SELECT ON 2026-08-20 (Tranche 2 Workstream B, D4.3) AND IS
     * NOT USED BY THE SWAP ITSELF. Its caller now also writes a `BOV_Broker_Change__c` history row,
     * whose `Outgoing_Broker__c` / `Incoming_Broker__c` Contact lookups are stamped from this
     * column. Adding it here rather than issuing a second query is what keeps the caller's budget at
     * 1 SOQL. It is FLS-free by construction — this read is already SYSTEM_MODE for
     * `Approval_Status__c`, so the addition cannot take the read down the way it could on a
     * USER_MODE sibling. `Broker__c` was confirmed present in usman-dpeg (live describe) before it
     * was added.
     *
     * @param dispositionId Disposition__c Id whose submissions to read; null-safe.
     * @return All submissions with Id, Broker__c, Broker_Firm__c, Submission_Status__c and
     *         Approval_Status__c populated; an empty list when the Disposition has none or the
     *         input is null.
     * @example
     * List&lt;BOV_Submission__c&gt; subs =
     *     BovSubmissionSelector.selectStatusesByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectStatusesByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Disposition__c, Broker__c, Broker_Firm__c, Submission_Status__c,
                   Approval_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            WITH SYSTEM_MODE
            ORDER BY BOV_Score__c DESC NULLS LAST
        ];
    }

    /**
     * Every COMMITTED `Selected` submission across a SET of Dispositions — the one query behind
     * `BovSubmissionSelectionGuardService.enforceSingleSelected`, the before-context trigger guard
     * that refuses a save which would leave a disposition with two Selected brokers.
     *
     * 🔴 IT TAKES A SET, NOT AN ID, AND THAT IS THE WHOLE POINT. Its caller runs inside a trigger
     * chunk of up to 200 records spanning arbitrarily many dispositions. A single-Id sibling —
     * `selectSelectedByDispositionId`, three methods up — would have to be called once per record,
     * which is SOQL in a loop and blows the 100-query limit at 101 rows. Do not "simplify" the guard
     * onto that method.
     *
     * ⚠ IT DELIBERATELY RETURNS ROWS AND NOT A COUNT, EVEN THOUGH THE CALLER ONLY COUNTS THEM. The
     * guard must SUBTRACT the rows that are present in `Trigger.new` (their in-memory value
     * supersedes their committed one — that is what lets `BovSubmissionService.replaceSelectedBroker`
     * demote and promote in one DML without being refused). A `GROUP BY` aggregate cannot be
     * filtered by Id after the fact, so an aggregate here would silently count a demoted incumbent
     * and turn the guard into a blanket refusal of the replace feature.
     *
     * ⚠ NO `ORDER BY` AND NO `LIMIT`. Nothing ranks these rows — they are counted, not displayed —
     * and a `LIMIT` would cap the count and under-report a pre-existing duplicate, which is the one
     * state this read must be able to see.
     *
     * ── 🔴 WITH SYSTEM_MODE — THE CALLER, NOT THE FIELD, IS WHAT FORCES IT HERE ──────
     * This is the ARCHITECTURE.md §2 automation-path exception in its purest form: the read is
     * performed ON THE RUNNING USER'S BEHALF, not at their request. They asked to SAVE A SUBMISSION;
     * they never asked to read its siblings. `USER_MODE` THROWS rather than degrades — one
     * inaccessible field raises `System.QueryException: No such column`, an FLS denial wearing a
     * schema error — and inside a BEFORE trigger that throw escapes as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and ROLLS BACK THE USER'S OWN SAVE. A guard that takes
     * down the save it was meant to validate is worse than no guard.
     * ⚠ Contrast `selectStatusesByDispositionId`, which is SYSTEM_MODE because of a specific FIELD
     * (`Approval_Status__c`). Two different arguments reaching the same keyword; neither is
     * inherited from the other.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE — this class stays
     * `with sharing`, and `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing. 🔴 THE ASYMMETRY THAT
     * CREATES IS NAMED IN THE GUARD'S OWN HEADER AND IS REPEATED HERE BECAUSE IT IS A PROPERTY OF
     * THIS QUERY: a Selected sibling the running user cannot SEE is absent from this result, so the
     * guard FAILS OPEN — it permits the second Selected row rather than blocking a legitimate one.
     * That is the safer direction of the two (a `without sharing` read would let a user learn that a
     * row they cannot see exists, by being refused because of it), and it is bounded by
     * `viewAllRecords = true` on the disposition child objects in both disposition permission sets.
     *
     * @param dispositionIds Disposition__c Ids whose Selected submissions to read; null/empty-safe
     *                       and issues NO query when the set is empty.
     * @return Every committed submission on those dispositions whose `Submission_Status__c` is
     *         'Selected', with Id, Disposition__c and Submission_Status__c populated; an empty list
     *         when there are none.
     * @example
     * List&lt;BOV_Submission__c&gt; selected =
     *     BovSubmissionSelector.selectSelectedByDispositionIds(dispositionIds);
     */
    public static List<BOV_Submission__c> selectSelectedByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Disposition__c, Submission_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c IN :dispositionIds AND Submission_Status__c = :STATUS_SELECTED
            WITH SYSTEM_MODE
        ];
    }
}
