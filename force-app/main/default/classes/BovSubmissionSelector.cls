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
 *   - DispositionOfferFormService.getFormContext, the Log Offer modal's read-only
 *     broker on the ON-MARKET path (2026-08-21)       -> selectSelectedBrokerByDispositionId
 *
 * ⚠ MIXED MODES SINCE 2026-08-19 — READ THE METHOD, NEVER THIS HEADER. ⚠ CORRECTED 2026-08-20: this
 * paragraph used to say "Two methods are `WITH USER_MODE`; `selectStatusesByDispositionId` is
 * `WITH SYSTEM_MODE`", which was a COUNT and counts decay. ⚠ RE-COUNTED 2026-08-21 (the Log Offer
 * modal added `selectSelectedBrokerByDispositionId`): it is now TWO of **FIVE** —
 * `selectStatusesByDispositionId` and `selectSelectedByDispositionIds` (the trigger guard's read)
 * are `WITH SYSTEM_MODE` under the ARCHITECTURE.md §2 automation-path exception, each justified at
 * its OWN declaration, which is where §2 says the authoritative inventory lives. 🔴 DO NOT TRUST A
 * NUMBER IN THIS HEADER — `NdaSelector`'s header records that this repo has already miscounted its
 * own SYSTEM_MODE inventory once, and this line has now decayed twice. Re-count; do not assert.
 * ⚠ AN EARLIER SENTENCE HERE WAS REASONING FROM THE WRONG TEST and is retracted verbatim so nobody
 * re-derives it: "There is no guest path for the Disposition module, so no SYSTEM_MODE appears
 * here." The exception is about reads the running user never asked for, and about fields the running
 * user may not hold — not about anonymous ones.
 *
 * MODE (the THREE USER_MODE reads — `selectByDispositionId`, `selectSelectedByDispositionId` and,
 * since 2026-08-21, `selectSelectedBrokerByDispositionId`) — BOV_Submission__c is a custom object;
 * P3 proved the custom-field FLS gap is 0, so USER_MODE is safe and enforces the running user's
 * sharing + FLS. None of the three touches `Approval_Status__c`, which is the field that forced
 * `selectStatusesByDispositionId` the other way. (`selectSelectedByDispositionIds` is SYSTEM_MODE
 * for a different reason again — the CALLER, not the field. Read it there.)
 * 🔴 THE THIRD ONE IS NOT AS SAFE AS THE OTHER TWO AND MUST NOT BE READ AS ROUTINE.
 * `selectSelectedBrokerByDispositionId` selects `Broker__c`, which — measured in the org on
 * 2026-08-21 — `DPEG_Admin_Access` does NOT grant, and it traverses to `Contact`. Its own header
 * carries the grant matrix and the reason it is a separate method rather than a widened one. That
 * is exactly why P3's "the custom-field FLS gap is 0" is a statement about a moment in time, not a
 * standing licence to widen any `USER_MODE` SELECT in this class.
 *
 * NOT-FOUND CONTRACT — read-for-display: a Disposition with no BOV submissions is
 * a normal state, so EVERY method here returns its natural empty List, never null and
 * never a throw (the caller of `selectSelectedByDispositionId` raises the AUTHORED
 * "no broker is marked Selected yet" error, which is the whole reason it must not be
 * a fetch-for-use throw).
 * ⚠ CORRECTED 2026-08-21. This paragraph used to end "...and `selectSelectedByDispositionId`
 * returns null rather than throwing". That method no longer returns a single record at all — it
 * returns a `List` so that its caller can SEE a second Selected row. The not-found contract is
 * unchanged in spirit (empty, not an exception); only its shape moved.
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
     * ⚠ `Name` WAS ADDED 2026-08-21 AND IT IS NOT DECORATION — IT IS A DISAMBIGUATOR. The Select
     * Broker / Replace Broker picker composes each radio option from this payload, and this org
     * currently holds SIX broker Contacts that exist TWICE with an identical name AND an identical
     * firm. Firm + contact name therefore cannot tell two options apart on those brokers; the
     * submission's own auto-number can. It is FLS-free by construction — a custom object's `Name`
     * carries no `FieldPermissions` row, so adding it cannot take this `WITH USER_MODE` read down
     * the way an ordinary custom field would.
     *
     * ── 🔴 `, CreatedDate ASC, Id ASC` IS NOT POLISH — IT IS THE SORT KEY (added 2026-08-21) ──
     * `BOV_Score__c DESC NULLS LAST` alone has NO TIE-BREAK, and SOQL does not promise a stable
     * order for rows that tie. Every row that ties therefore reshuffles between page loads, and
     * the matrix reorders under a user who has not changed anything. That was already true for two
     * equal scores; it is about to become true for EVERY ROW IN THE ORG, because `BOV_Score__c` is
     * being recreated as a formula that returns null until the parent disposition has an asking
     * price — which no disposition has yet. `NULLS LAST` with nothing but nulls is not a sort.
     * `CreatedDate ASC` (oldest submission first, the order they arrived) then `Id ASC` (a total
     * order, so the result is fully determined even for two rows created in the same transaction)
     * closes it. All THREE queries in this class carry the same tie-break — see the note on
     * `selectStatusesByDispositionId`, where it also fixes a documented determinism claim.
     *
     * @param dispositionId Disposition__c Id whose submissions to read.
     * @return The matching BOV_Submission__c records ordered by BOV_Score__c
     *         DESC NULLS LAST, then CreatedDate ASC, Id ASC; an empty list when
     *         the Disposition has none (or when dispositionId is null).
     * @example
     * List<BOV_Submission__c> subs =
     *     BovSubmissionSelector.selectByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectByDispositionId(Id dispositionId) {
        return [
            SELECT Id, Name, Broker_Firm__c, Contact_Name__c, BOV_Amount__c,
                   Commission_Rate__c, Days_To_Market__c, Hist_Success_Rate__c,
                   Cap_Rate__c, BOV_Score__c, Submission_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC
        ];
    }

    /**
     * EVERY submission a Disposition has marked `Selected` — normally exactly one, occasionally
     * zero, and (the reason this method exists in this shape) possibly more than one. Backs
     * `DispositionApprovalService.submitForApproval`'s `BOV Outreach` branch, which submits THAT
     * RECORD (not the Disposition) into `Broker_Finalize_Approval`.
     *
     * ══════════════════════════════════════════════════════════════════════════════
     * 🔴 IT RETURNED A SINGLE RECORD WITH `LIMIT 1` UNTIL 2026-08-21. THE OLD JAVADOC IS QUOTED
     *    BELOW RATHER THAN DELETED, BECAUSE THE SENTENCE THAT HAD TO GO WAS THE ONE THAT SOUNDED
     *    MOST REASSURING:
     *
     *        RETRACTED: "The `LIMIT 1` therefore reflects a business invariant
     *        (`BovSubmissionService` demotes the incumbent in the same DML that promotes the
     *        challenger) rather than an arbitrary cap. If two rows are ever Selected the
     *        highest-scoring one wins here, which is the same ordering the matrix displays —
     *        deterministic, and the invariant is repaired by a replace, not by this read."
     *
     * That was an accurate description of a SILENT WRONG ANSWER. "The highest-scoring one wins
     * here" means: on a disposition that has somehow acquired two Selected brokers, this read
     * picked one of them and the caller submitted it into `Broker_Finalize_Approval` — appointing
     * a broker nobody chose, with nothing anywhere reporting that a choice had been made. A
     * `LIMIT 1` cannot express "exactly one", only "at most one", and the difference is precisely
     * the state the caller now needs to refuse. Making the caller see the second row is a change
     * to THIS QUERY; no `if` in the service could have detected what the query had already thrown
     * away.
     * ══════════════════════════════════════════════════════════════════════════════
     *
     * 🔴 AN EMPTY LIST IS A FIRST-CLASS ANSWER AND MUST STAY ONE. "No broker is Selected yet" is
     * the single most likely reason a Submit Selected Broker click fails, and it is entirely
     * user-actionable: pick a broker in the comparison matrix first. A fetch-for-use throw would
     * turn that into a `System.QueryException` the controller masks as "could not be submitted…
     * contact your administrator" — advice that sends the user to the wrong person. The caller
     * converts empty into an AUTHORED message naming the fix, and size > 1 into a different
     * authored message naming a different fix.
     *
     * ⚠ `Submission_Status__c` IS RESTRICTED TO {Backup, Selected} (measured in the field
     * metadata), so "Selected" is not one value among many — it is one of the only two.
     *
     * ⚠ THE `, CreatedDate ASC, Id ASC` TIE-BREAK IS KEPT EVEN THOUGH NO `LIMIT` CONSUMES IT NOW.
     * The caller reads `[0]` on the single-row happy path, so a tie is still a CHOICE — just a
     * choice among one. It also keeps the two-row REFUSAL reproducible: the same pair of rows
     * comes back in the same order on every click, so a screenshot of the error matches what the
     * matrix behind it shows. Once `BOV_Score__c` is a formula returning null with no asking
     * price, every score ties at null and the score leg decides nothing at all.
     *
     * ⚠ `Approval_Status__c` IS DELIBERATELY NOT SELECTED. It is a 2026-08-19 field, and a
     * Metadata-API-deployed custom field arrives with NO FLS for any profile — so selecting it
     * here would take this `WITH USER_MODE` read down for everyone until the permission-set deploy
     * lands, on a field this caller does not use. `selectStatusesByDispositionId` needs it, and
     * pays SYSTEM_MODE for it.
     *
     * ⚠ `WITH USER_MODE` IS CORRECT HERE AND IS NOT THE AUTOMATION-PATH CASE. The running user
     * clicked Submit Selected Broker; this is the read they asked for, so an FLS throw reports a
     * real provisioning gap and the fix is a permission set (ARCHITECTURE.md §2). Do NOT reach for
     * `selectSelectedByDispositionIds` two methods down merely because it has no `LIMIT` — that
     * one is `WITH SYSTEM_MODE` on grounds that are explicitly about ITS caller (a before-trigger),
     * and borrowing it here would invalidate its own justification.
     *
     * @param dispositionId Disposition__c Id whose Selected submissions to read; null-safe.
     * @return Every Selected BOV_Submission__c on that Disposition, highest-scoring first then
     *         oldest first; an empty list when it has none (or when dispositionId is null).
     * @example
     * List&lt;BOV_Submission__c&gt; selected =
     *     BovSubmissionSelector.selectSelectedByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectSelectedByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Broker_Firm__c, Contact_Name__c, Submission_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId AND Submission_Status__c = :STATUS_SELECTED
            WITH USER_MODE
            ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC
        ];
    }

    /**
     * THE APPOINTED BROKER CONTACT on an ON-MARKET disposition — the `Selected` submission's
     * `Broker__c`. Backs `DispositionOfferFormService.getFormContext` ->
     * `c/dispositionLogOfferModal`'s read-only Broker field (2026-08-21).
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 IT IS A SECOND METHOD RATHER THAN `Broker__c` ADDED TO `selectSelectedByDispositionId`
     *    ABOVE, AND THAT IS THE ENTIRE POINT.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * Both are `WITH USER_MODE`, and under `USER_MODE` **every added field is another way for the
     * query to throw**: one persona without read on `BOV_Submission__c.Broker__c` turns the widened
     * method into `System.QueryException: No such column` — an FLS denial wearing a schema error —
     * for EVERY caller of it, including Submit Selected Broker.
     *
     * 🔴 AND THAT PERSONA EXISTS. MEASURED IN THE ORG (`usman-dpeg`, `FieldPermissions`, 2026-08-21),
     * not read off the permission-set XML:
     *
     *   PERMISSION SET             BOV_Submission__c.Broker__c
     *   DPEG_Disposition_Edit      read + edit
     *   DPEG_Disposition_View      read
     *   DPEG_Junior_Analyst_PSG    read + edit
     *   DPEG_Principal_PSG         read
     *   DPEG_Admin_Access          🔴 **NO ROW AT ALL** — not granted.
     *
     * `DPEG_Admin_Access` DOES carry `NDA__c.Party_Role__c`, so it is a real, provisioned set that
     * simply does not include this field. Widening the method above would therefore have broken
     * Submit Selected Broker for anyone holding only that set, to add a field that caller does not
     * use. Keeping the reads separate confines that exposure to THIS caller, where it fails soft:
     * `DispositionOfferFormService` catches it narrowly and the modal renders "no broker appointed
     * yet" instead of taking the whole dialog down.
     * ⚠ The fix, if that persona ever needs the Log Offer dialog, is the PERMISSION SET. It is never
     * `SYSTEM_MODE` here — see `selectSelectedByDispositionId`'s own note on borrowing modes.
     *
     * ⚠ `Broker__r.Name` traverses to `Contact` and adds an OBJECT-level gate that no
     * `BOV_Submission__c` permission set grants; it comes from `DPEG_Contact_View` /
     * `DPEG_Contact_Edit`, separate members of the same permission-set GROUPS. The full argument is
     * on `NdaSelector.selectBuyerTimelineByDispositionId`. The name is selected rather than resolved
     * by a second Contact query because the modal DISPLAYS it — a broker Id with no name beside it is
     * an unreadable read-only field.
     *
     * 🔴 AN EMPTY LIST IS A FIRST-CLASS ANSWER AND MUST STAY ONE — the same contract, and for the
     * same reason, as `selectSelectedByDispositionId`. "No broker is Selected yet" is the NORMAL
     * state of an on-market disposition before `Broker_Finalize_Approval` has run, and an offer
     * logged in that window legitimately carries a null broker with nothing backfilling it later.
     * A fetch-for-use throw would turn a normal state into a dialog that refuses to open.
     * ⚠ `Broker__c` ITSELF CAN BE NULL ON A SELECTED ROW — the lookup was added later than the object
     * and legacy submissions carry only `Broker_Firm__c` / `Contact_Name__c`. The caller treats
     * "no row" and "row with a null broker" identically; do not assume a returned row implies a
     * broker.
     *
     * ⚠ NO `LIMIT`, and the `CreatedDate ASC, Id ASC` tie-break is deliberate. Exclusivity is a
     * SERVER invariant maintained by `BovSubmissionService.replaceSelectedBroker`, not a schema
     * constraint, so two `Selected` rows is a reachable data defect. A `LIMIT 1` would hide it and
     * pick arbitrarily; returning both lets the caller take `[0]` deterministically while a future
     * reader can still see the duplicate. ⚠ Unlike `selectSelectedByDispositionId` this does NOT sort
     * on `BOV_Score__c` — that field is heading for a formula that returns null with no asking price,
     * so every row ties and the leg decides nothing. Oldest-first is at least meaningful.
     *
     * @param dispositionId Disposition__c Id whose Selected submission to read; null-safe.
     * @return Every Selected BOV_Submission__c on that Disposition with Id, Broker__c,
     *         Broker__r.Name and Broker_Firm__c populated, oldest first; an EMPTY LIST when it has
     *         none, or when dispositionId is null (never null).
     * @throws System.QueryException when the running user lacks read on `BOV_Submission__c`, on
     *         `Contact`, or on `Broker__c` / `Broker_Firm__c` / `Submission_Status__c`. The caller
     *         catches it narrowly and degrades to "no broker resolved".
     * @example
     * List&lt;BOV_Submission__c&gt; selected =
     *     BovSubmissionSelector.selectSelectedBrokerByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectSelectedBrokerByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Broker__c, Broker__r.Name, Broker_Firm__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId AND Submission_Status__c = :STATUS_SELECTED
            WITH USER_MODE
            ORDER BY CreatedDate ASC, Id ASC
        ];
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
     * ⚠ THIS QUERY'S ORDER IS CONSUMED, NOT DECORATIVE, AND THAT IS WHY IT GAINED
     * `, CreatedDate ASC, Id ASC` ON 2026-08-21. `BovSubmissionService.replaceSelectedBroker` takes
     * the FIRST Selected row this returns as the history row's single `Outgoing` slot when a
     * disposition has somehow acquired two incumbents, and its own comment called that choice
     * "deterministic rather than arbitrary" on the strength of this ORDER BY. Score alone stops
     * being able to carry that claim once `BOV_Score__c` is a formula returning null without an
     * asking price: two null scores tie, and an untied SOQL sort may return either row first. The
     * tie-break restores it — highest score first, then the OLDEST submission — and the service's
     * comment has been corrected to name the second key rather than only the first.
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
            ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC
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
