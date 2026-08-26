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
 *   - BovSubmissionSelectionGuardService.enforceSelectionExclusivity, the before-context
 *     single-Selected trigger guard (2026-08-20,
 *     Tranche 2 Workstream A2)                        -> selectSelectedByDispositionIds
 *   - DispositionOfferFormService.getFormContext, the Log Offer modal's read-only
 *     broker on the ON-MARKET path (2026-08-21)       -> selectSelectedBrokerByDispositionId
 *   - DispositionStageEntryService.openBuyerNdas, stamping NDA__c.Broker__c on the
 *     auto-created buyer NDA, ON-MARKET path (2026-08-21)
 *                                                     -> selectSelectedBrokerByDispositionIds
 *   - BovAutoSelectionService.reselect, the automatic highest-score appointment
 *     (2026-08-24)                                    -> selectSelectionContextByDispositionIds
 *   - BovPreferredBrokerService.retireReplacedPreferred, the outgoing-preferred swap
 *     (2026-08-24)                                    -> selectPreferredByDispositionIds
 *   - BovBrokerChangeController.getHistory, the CURRENT SELECTION half of the
 *     "Broker Selection" card (2026-08-25)            -> selectSelectedSlotsByDispositionId
 *
 * ⚠ MIXED MODES SINCE 2026-08-19 — READ THE METHOD, NEVER THIS HEADER. ⚠ CORRECTED 2026-08-20: this
 * paragraph used to say "Two methods are `WITH USER_MODE`; `selectStatusesByDispositionId` is
 * `WITH SYSTEM_MODE`", which was a COUNT and counts decay. ⚠ RE-COUNTED 2026-08-21 (the Log Offer
 * modal added `selectSelectedBrokerByDispositionId`): it was then TWO of **FIVE**. ⚠ RE-COUNTED
 * AGAIN THE SAME DAY (the NDA broker stamp added `selectSelectedBrokerByDispositionIds`): THREE of
 * **SIX**. ⚠ RE-COUNTED AGAIN 2026-08-24 (auto-selection added
 * `selectSelectionContextByDispositionIds`): it is now **FOUR of SEVEN** —
 * `selectStatusesByDispositionId`, `selectSelectedByDispositionIds` (the trigger
 * guard's read), `selectSelectedBrokerByDispositionIds` (the NDA stamp's read) and
 * `selectSelectionContextByDispositionIds` (auto-selection's read) are
 * `WITH SYSTEM_MODE` under the ARCHITECTURE.md §2 automation-path exception, each justified at
 * its OWN declaration, which is where §2 says the authoritative inventory lives. ⚠ RE-COUNTED
 * AGAIN 2026-08-25 and IT HAD DECAYED TWICE UNNOTICED IN ONE DAY: `selectPreferredByDispositionIds`
 * (SYSTEM_MODE, the preferred-retirement read) landed on 2026-08-24 without this line being
 * touched, and `selectSelectedSlotsByDispositionId` (USER_MODE, the Broker Selection card) landed
 * on 2026-08-25. The count is now **FIVE SYSTEM_MODE of NINE**. 🔴 DO NOT TRUST A
 * NUMBER IN THIS HEADER — `NdaSelector`'s header records that this repo has already miscounted its
 * own SYSTEM_MODE inventory once, and this line has now decayed FIVE times, twice silently. This
 * is the fifth correction of the same sentence: the count is written down here only so a reader
 * knows to re-derive it, and the authoritative inventory is the METHOD DECLARATIONS. Re-count; do
 * not assert. ⚠ AND NOTE THE NEAR-IDENTICAL NAMES: `…ByDispositionId` (singular, USER_MODE, modal) and
 * `…ByDispositionIds` (plural, SYSTEM_MODE, trigger) differ by ONE CHARACTER and by their entire
 * justification. Read the parameter type before quoting either one's reasoning.
 * ⚠ AN EARLIER SENTENCE HERE WAS REASONING FROM THE WRONG TEST and is retracted verbatim so nobody
 * re-derives it: "There is no guest path for the Disposition module, so no SYSTEM_MODE appears
 * here." The exception is about reads the running user never asked for, and about fields the running
 * user may not hold — not about anonymous ones.
 *
 * MODE (the FOUR USER_MODE reads — `selectByDispositionId`, `selectSelectedByDispositionId`,
 * since 2026-08-21 `selectSelectedBrokerByDispositionId`, and since 2026-08-25
 * `selectSelectedSlotsByDispositionId`; the plural
 * `selectSelectedBrokerByDispositionIds` added later the same day is NOT one of them) —
 * BOV_Submission__c is a custom object;
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
     * ── 🔴 `Is_Preferred_Broker__c` WAS ADDED 2026-08-24 AND IT IS AN **FLS CHANGE** ───────────
     * `c/bovComparisonMatrix` renders TWICE on the Disposition page since the preferred-broker
     * work: a `preferredOnly` instance above the ranked one, both fed by THIS ONE READ and split
     * client-side (one wire, one cache entry, so the two instances cannot disagree about the same
     * broker's numbers). That is why the flag is on the query rather than in a second Apex method.
     *
     * 🔴 THIS READ IS `WITH USER_MODE`, SO EVERY ADDED FIELD IS ANOTHER WAY FOR IT TO THROW. One
     * persona without READ on `Is_Preferred_Broker__c` gets
     * `System.QueryException: No such column` — an FLS denial wearing a schema error — and
     * `BovController.getSubmissions` masks it as the generic read-failure message, so **THE ENTIRE
     * BOV COMPARISON MATRIX DISAPPEARS FOR THEM**. ⚠ THE PERMISSION-SET GRANT IS A HARD
     * DEPLOY-ORDER PREREQUISITE: `DPEG_Disposition_Edit` and `DPEG_Disposition_View` must be LIVE
     * before this class. A Metadata-API-deployed custom field arrives with NO FLS for anyone,
     * System Administrator included.
     * ⚠ CHECKED, NOT ASSUMED (2026-08-24): those two sets are the ONLY permission sets in the repo
     * carrying any `BOV_Submission__c` field permission at all, and both grant this field
     * `readable = true`. `DPEG_Admin_Access` carries ZERO BOV field grants, so it could not read
     * this query before the change either — the exposure is unchanged for that persona, not widened.
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
                   Cap_Rate__c, BOV_Score__c, Submission_Status__c,
                   Is_Preferred_Broker__c
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
     * ══════════════════════════════════════════════════════════════════════════════
     * 🔴 ⚠ AMENDED 2026-08-24 — "EVERY SELECTED ROW" NOW ROUTINELY MEANS **TWO**, AND size() > 1 IS
     *    NO LONGER AUTOMATICALLY AN ERROR. THE CALLER CHANGED WITH IT.
     * ══════════════════════════════════════════════════════════════════════════════
     * The paragraph above still describes the query correctly, and the reason it lost its `LIMIT 1`
     * is unchanged. What changed is the INVARIANT behind it: a disposition may now hold ONE Selected
     * PREFERRED broker AND ONE Selected non-preferred broker at the same time
     * (`BovSubmissionSelectionGuardService`'s header carries the retraction in full). So:
     *
     *   `Is_Preferred_Broker__c` WAS ADDED TO THE SELECT and it is the ROUTING KEY.
     *   `DispositionApprovalService`'s BOV Outreach branch submits the PREFERRED row when there is
     *   one and the non-preferred row otherwise, so this column is not decoration — without it the
     *   caller cannot tell the two Selected rows apart and would submit an arbitrary one.
     *
     *   `Is_Preferred_Broker__c DESC` WAS ADDED AS THE **FIRST** ORDER BY KEY, so the preferred row
     *   is row [0] whenever one exists. The caller does not depend on that (it partitions
     *   explicitly), but a reader debugging from a screenshot of the two rows should see them in
     *   routing order, and the sibling broker-resolution queries below rely on the same clause.
     *
     * ⚠ THE FLS QUESTION HAD TO BE ASKED AGAIN BECAUSE THIS IS THE `WITH USER_MODE` SIBLING, and
     * `USER_MODE` THROWS rather than degrades. `Is_Preferred_Broker__c` is granted READ on BOTH
     * `DPEG_Disposition_Edit` (read + edit) and `DPEG_Disposition_View` (read only) — measured in
     * the org 2026-08-24 and recorded again at `selectStatusesByDispositionId`. That grant is a
     * DEPLOY-ORDER PREREQUISITE for this line, exactly as it was for `selectByDispositionId`: on an
     * org where the field exists without FLS, this read fails with `No such column` for everyone and
     * Submit for Approval breaks at BOV Outreach. Do NOT add an ungranted column here.
     *
     * @param dispositionId Disposition__c Id whose Selected submissions to read; null-safe.
     * @return Every Selected BOV_Submission__c on that Disposition — PREFERRED FIRST, then
     *         highest-scoring, then oldest; an empty list when it has none (or when dispositionId
     *         is null). Up to TWO rows is now a NORMAL result, not a defect.
     * @example
     * List&lt;BOV_Submission__c&gt; selected =
     *     BovSubmissionSelector.selectSelectedByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectSelectedByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Broker_Firm__c, Contact_Name__c, Submission_Status__c,
                   Is_Preferred_Broker__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId AND Submission_Status__c = :STATUS_SELECTED
            WITH USER_MODE
            ORDER BY Is_Preferred_Broker__c DESC, BOV_Score__c DESC NULLS LAST,
                     CreatedDate ASC, Id ASC
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
     * 🔴 ⚠ `Is_Preferred_Broker__c DESC` BECAME THE FIRST ORDER BY KEY ON 2026-08-24, AND THE
     * CALLER'S "TAKE THE FIRST ROW WITH A BROKER" LOOP IS WHY IT HAD TO. A disposition may now hold
     * TWO Selected rows — one preferred, one scored — and `DispositionOfferFormService` takes the
     * first one that names a broker. Under the old `CreatedDate ASC` clause it would take whichever
     * happened to be older, so the offer form could name a DIFFERENT broker from the one
     * `DispositionApprovalService` routes the approval to. This clause makes the two agree by
     * construction rather than by coincidence. The added column is also SELECTED so a caller (or a
     * debugger) can see WHICH kind of row it got.
     *
     * @throws System.QueryException when the running user lacks read on `BOV_Submission__c`, on
     *         `Contact`, or on `Broker__c` / `Broker_Firm__c` / `Submission_Status__c` /
     *         `Is_Preferred_Broker__c`. The caller catches it narrowly and degrades to "no broker
     *         resolved".
     * @example
     * List&lt;BOV_Submission__c&gt; selected =
     *     BovSubmissionSelector.selectSelectedBrokerByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectSelectedBrokerByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Broker__c, Broker__r.Name, Broker_Firm__c, Is_Preferred_Broker__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId AND Submission_Status__c = :STATUS_SELECTED
            WITH USER_MODE
            ORDER BY Is_Preferred_Broker__c DESC, CreatedDate ASC, Id ASC
        ];
    }

    /**
     * THE APPOINTED BROKER CONTACT for a SET of ON-MARKET dispositions — the `Selected` submission's
     * `Broker__c`, for each of them, in ONE query. Backs
     * `DispositionStageEntryService.openBuyerNdas`, which stamps `NDA__c.Broker__c` on the NDA it
     * auto-creates when a disposition enters the `NDA` stage (2026-08-21).
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 IT TAKES A SET, AND IT IS A FOURTH METHOD RATHER THAN A REUSE OF EITHER NEIGHBOUR.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * Two obvious "simplifications" exist and both are wrong:
     *
     *   `selectSelectedBrokerByDispositionId` (the SINGULAR, one method up) — REJECTED. Its caller
     *       is a modal opening on ONE record. This caller runs inside an after-trigger chunk of up
     *       to 200 dispositions, so reusing it means SOQL in a loop and a blown 100-query limit at
     *       101 rows. Identical argument to `selectSelectedByDispositionIds` below; identical
     *       instruction not to fold them back together.
     *   `selectSelectedByDispositionIds` (the plural GUARD read, below) WIDENED BY ONE COLUMN —
     *       REJECTED, and this is the closer call of the two, because that method is already
     *       set-based and already `SYSTEM_MODE`, so `Broker__c` would add no FLS surface there
     *       (exactly the argument `selectStatusesByDispositionId` uses to justify ITS `Broker__c`).
     *       🔴 THE BLOCKER IS THE `WHERE`, NOT THE `SELECT`. This method carries
     *       `AND Broker__c != NULL` (see below), and that predicate is POISON in the guard: the
     *       guard COUNTS Selected rows in order to refuse a second one, so a `Broker__c != NULL`
     *       term would make a Selected-but-brokerless row invisible to it and turn the exclusivity
     *       guard into a silent permit. Two reads with different WHERE clauses are two reads.
     *
     * ── 🔴 `AND Broker__c != NULL` IS LOAD-BEARING, NOT TIDINESS ───────────────────────────────
     * `Broker__c` CAN BE NULL ON A `Selected` ROW — the lookup was added after the object and
     * legacy submissions carry only `Broker_Firm__c` / `Contact_Name__c` (the singular method's
     * header records the same fact). The caller builds a `Map<Id dispositionId, Id brokerId>` and
     * keeps the FIRST row per disposition. Without this predicate, a disposition that had somehow
     * acquired two `Selected` rows — the oldest brokerless, the newest carrying the real broker —
     * would resolve to NULL and the NDA would ship unstamped, which is the exact defect this
     * method exists to close. With it, "no usable row" and "no row at all" collapse into the same
     * answer, which is the answer the caller already handles.
     * ⚠ THIS IS A DELIBERATE DIVERGENCE FROM THE SINGULAR METHOD, WHICH HAS NO SUCH PREDICATE, AND
     * THE TWO CAN THEREFORE DISAGREE ON ONE (DEFECTIVE) SHAPE OF DATA. That is correct rather than
     * an inconsistency: the modal DISPLAYS whatever the Selected row holds, so "the Selected row,
     * broker or not" is the honest read there; this one STAMPS a value, so "the first Selected row
     * that actually names a broker" is the honest read here. Both are fully deterministic under the
     * same total order below.
     *
     * ── 🔴 WITH SYSTEM_MODE — BOTH THE CALLER **AND** THE FIELD FORCE IT, INDEPENDENTLY ────────
     * 1. THE CALLER. ARCHITECTURE.md §2's automation-path exception in its purest form, and the
     *    same argument `selectSelectedByDispositionIds` makes below: the running user asked to move
     *    a disposition to the `NDA` stage, not to read its BOV submissions. `USER_MODE` THROWS
     *    rather than degrades, and this read sits inside an AFTER-UPDATE trigger, so the throw
     *    escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and ROLLS BACK THE USER'S OWN STAGE
     *    CHANGE — a stamp that takes down the save it was decorating.
     * 2. THE FIELD, AND THIS LEG IS MEASURED RATHER THAN ARGUED. `BOV_Submission__c.Broker__c` is
     *    NOT granted on `DPEG_Admin_Access` — no `FieldPermissions` row at all, measured in
     *    `usman-dpeg` on 2026-08-21 and recorded in `selectSelectedBrokerByDispositionId`'s own
     *    header, which is precisely why THAT method was kept separate rather than widened. So the
     *    denial persona is not hypothetical: an administrator holding only that set who moved a
     *    disposition to `NDA` would have the move refused under `USER_MODE`.
     * ⚠ Do NOT read "the sibling three lines up is USER_MODE" as a precedent. That one is a read a
     *   human ASKED for (they opened the Log Offer dialog) and it fails soft because its caller
     *   catches the QueryException narrowly. This one is neither.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE — `SYSTEM_MODE` lifts CRUD
     * and FLS and NEVER sharing, and this class stays `with sharing`. A `Selected` submission the
     * running user cannot SEE is absent from this result, so the NDA is created with a NULL broker
     * rather than the wrong one. That degradation is bounded by measurement, not hope: both
     * `DPEG_Disposition_View` and `DPEG_Disposition_Edit` carry `viewAllRecords = true` on
     * `BOV_Submission__c` (read off the two permission-set files), and the running user just edited
     * the parent Disposition, so they can already see it. This is NOT the shape that needed a
     * `private without sharing` inner class — contrast `NdaSelector.ExpiryAlertReads`, whose rows
     * belong to a different principal than the one running the automation.
     *
     * 🔴 NO `Approval_Status__c` TERM, DELIBERATELY. A `Selected` submission on a disposition that
     * has reached the `NDA` stage has in practice been through `Broker_Finalize_Approval`, but
     * `Submission_Status__c = 'Selected'` is the SAME predicate `selectSelectedBrokerByDispositionId`
     * uses for the Log Offer modal's broker — so the NDA's broker and the offer form's broker are
     * the same person on the same disposition BY CONSTRUCTION. Adding an approval term here would
     * silently break that agreement on any disposition advanced by an admin ahead of the approval,
     * and would additionally drag `Approval_Status__c` into the SELECT. If the appointed broker
     * should ever mean "approved broker", that is one change to BOTH methods, not one to this one.
     *
     * ⚠ NO `Broker__r.Name`, UNLIKE THE SINGULAR METHOD. The caller stamps an Id into a lookup and
     * never renders a name, so the traversal would buy nothing and would materialise a child
     * sObject per row inside a trigger. (Under `SYSTEM_MODE` it would not add an FLS gate — the
     * reason to omit it is heap and honesty about what is used, not access.)
     *
     * ⚠ `ORDER BY CreatedDate ASC, Id ASC` — OLDEST FIRST, AND IT IS CONSUMED. Exclusivity is a
     * SERVER invariant maintained by `BovSubmissionService.replaceSelectedBroker`, not a schema
     * constraint, so two `Selected` rows is a reachable data defect and the caller's "first row
     * per disposition wins" is therefore a CHOICE. `Id ASC` makes the order total, so two rows
     * created in the same transaction still resolve identically on every run. ⚠ Deliberately does
     * NOT sort on `BOV_Score__c` — that field is becoming a formula returning null without an
     * asking price, so every row ties and the leg would decide nothing. Same reasoning, same
     * omission, as the singular method.
     *
     * @param dispositionIds Disposition__c Ids whose Selected submissions to read; null/empty-safe
     *                       and issues NO query when the set is null or empty.
     * 🔴 ⚠ `Is_Preferred_Broker__c DESC` BECAME THE FIRST ORDER BY KEY ON 2026-08-24, for the same
     * reason as its singular sibling above. `DispositionStageEntryService.openBuyerNdas` keeps the
     * FIRST row it sees per disposition (`if (!containsKey)`), and a sale may now have TWO Selected
     * rows — so without this clause the NDA would be stamped with the scored broker while the
     * approval was routed to the preferred one. Two features naming two different brokers for one
     * sale is exactly the ambiguity the selection guard exists to prevent, so it is closed HERE, in
     * the shared read, rather than in each caller.
     *
     * @return Every `Selected` submission on those dispositions that NAMES a broker, with Id,
     *         Disposition__c, Broker__c and Is_Preferred_Broker__c populated, PREFERRED FIRST then
     *         oldest; an EMPTY LIST when there are none (never null).
     * @example
     * List&lt;BOV_Submission__c&gt; selected =
     *     BovSubmissionSelector.selectSelectedBrokerByDispositionIds(dispositionIds);
     */
    public static List<BOV_Submission__c> selectSelectedBrokerByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Disposition__c, Broker__c, Is_Preferred_Broker__c
            FROM BOV_Submission__c
            WHERE Disposition__c IN :dispositionIds
              AND Submission_Status__c = :STATUS_SELECTED
              AND Broker__c != NULL
            WITH SYSTEM_MODE
            ORDER BY Is_Preferred_Broker__c DESC, CreatedDate ASC, Id ASC
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
     * ⚠ `Is_Preferred_Broker__c` WAS ADDED TO THIS SELECT ON 2026-08-24 AND IS NOT USED BY THE SWAP
     * EITHER — it backs `replaceSelectedBroker`'s SERVER-SIDE REFUSAL of a preferred submission
     * (design gate Q-5). Adding it here rather than issuing a second query keeps that caller's
     * budget at 1 SOQL, and it is FLS-free by construction because this read is already
     * `WITH SYSTEM_MODE` for `Approval_Status__c`. 🔴 THAT LAST CLAUSE IS LOAD-BEARING AND NOT
     * ROUTINE: `Is_Preferred_Broker__c` IS granted (read+edit on `DPEG_Disposition_Edit`, read on
     * `DPEG_Disposition_View`, measured in the org 2026-08-24), but adding a field to a
     * `WITH USER_MODE` sibling would still be an FLS change — see `selectByDispositionId`, which
     * took the same field and had to argue the deploy order for it.
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
     * @return All submissions with Id, Broker__c, Broker_Firm__c, Submission_Status__c,
     *         Approval_Status__c and Is_Preferred_Broker__c populated; an empty list when the
     *         Disposition has none or the input is null.
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
                   Approval_Status__c, Is_Preferred_Broker__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            WITH SYSTEM_MODE
            ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC
        ];
    }

    /**
     * Every COMMITTED `Selected` submission across a SET of Dispositions — the one query behind
     * `BovSubmissionSelectionGuardService.enforceSelectionExclusivity`, the before-context trigger guard
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
     * 🔴 ⚠ `Is_Preferred_Broker__c` WAS ADDED TO THIS SELECT ON 2026-08-24 AND THE GUARD CANNOT
     * WORK WITHOUT IT. Its invariant is no longer "at most one Selected row" but "at most one
     * Selected PREFERRED row and at most one Selected NON-PREFERRED row", so this column is what
     * decides WHICH counter a committed sibling increments. Removing it does not degrade the guard,
     * it INVERTS it: every row would fall into one bucket and legitimate two-row states would be
     * refused. It is FLS-free by construction because this read is already `WITH SYSTEM_MODE`.
     *
     * @return Every committed submission on those dispositions whose `Submission_Status__c` is
     *         'Selected', with Id, Disposition__c, Submission_Status__c and Is_Preferred_Broker__c
     *         populated; an empty list when there are none.
     * @example
     * List&lt;BOV_Submission__c&gt; selected =
     *     BovSubmissionSelector.selectSelectedByDispositionIds(dispositionIds);
     */
    public static List<BOV_Submission__c> selectSelectedByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Disposition__c, Submission_Status__c, Is_Preferred_Broker__c
            FROM BOV_Submission__c
            WHERE Disposition__c IN :dispositionIds AND Submission_Status__c = :STATUS_SELECTED
            WITH SYSTEM_MODE
        ];
    }

    /**
     * EVERY submission on a SET of Dispositions, carrying BOTH the RANKING KEY and the whole LOCK
     * STATE on each row — the ONE query behind `BovAutoSelectionService.reselect`, the automatic
     * "highest score becomes Selected" appointment added 2026-08-24.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 IT IS A SEVENTH METHOD RATHER THAN A WIDENING OF ANY OF THE SIX ABOVE, AND THE ONE THAT
     *    LOOKS CLOSEST IS THE ONE IT MUST NOT TOUCH.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `selectSelectedByDispositionIds` (immediately above) is already set-based and already
     * SYSTEM_MODE, so adding four columns to it would cost nothing on FLS grounds and is the
     * obvious "simplification". 🔴 THE BLOCKER IS THE `WHERE`, NOT THE `SELECT`. That method
     * carries `AND Submission_Status__c = 'Selected'` and it is `BovSubmissionSelectionGuardService`'s
     * COUNTING PREDICATE — the guard counts committed Selected siblings in order to refuse a second
     * one. Auto-selection needs the OPPOSITE population: every sibling including the Backup rows,
     * because the winner it is looking for is by definition NOT Selected yet. Relaxing that WHERE
     * to serve this caller would make the guard count every submission on the disposition and turn
     * an exclusivity guard into a blanket refusal. Two reads with different WHERE clauses are two
     * reads — the identical argument `selectSelectedBrokerByDispositionIds` records against the
     * same neighbour, from the other direction.
     *
     * `selectStatusesByDispositionId` has the right population but takes a SINGLE Id and its caller
     * is a human clicking Replace Broker on one record. This caller runs inside an after-trigger
     * chunk of up to 200 submissions spanning arbitrarily many dispositions, so reusing it means
     * SOQL in a loop and a blown 100-query limit at 101 rows.
     *
     * ── 🔴 WITH SYSTEM_MODE — TWO INDEPENDENT FORCES, EITHER SUFFICIENT ────────────────────────
     * 1. THE FIELD. `Approval_Pending__c` has NO `fieldPermissions` entry in ANY permission set,
     *    DELIBERATELY — both `DPEG_Disposition_View` and `DPEG_Disposition_Edit` carry an explicit
     *    "do not complete the set" instruction against it, because an approval process is its only
     *    writer. A `USER_MODE` read of that column raises
     *    `System.QueryException: No such column 'Approval_Pending__c'` — an FLS denial wearing a
     *    schema error — for LITERALLY EVERY USER INCLUDING SYSTEM ADMINISTRATOR. 🔴 DO NOT "FIX"
     *    THIS BY GRANTING FLS. `Approval_Status__c` forces the same conclusion for the same reason
     *    (`selectStatusesByDispositionId`'s header carries the argument in full), and
     *    `Is_Manually_Appointed__c` is granted READ-ONLY by design and would be a third.
     * 2. THE CALLER. ARCHITECTURE.md §2's automation-path exception in its purest form: the running
     *    user asked to SAVE A BOV RESPONSE, or to PRICE A SALE. They never asked to read the
     *    siblings. `USER_MODE` THROWS rather than degrades, and inside an AFTER-trigger that throw
     *    escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and ROLLS BACK THE USER'S OWN SAVE.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE HERE — `SYSTEM_MODE` lifts
     * CRUD and FLS and NEVER sharing, and this class stays `with sharing`. 🔴 THE ASYMMETRY IS
     * NAMED RATHER THAN HIDDEN: a Selected sibling the running user cannot SEE is absent from this
     * result, so auto-selection would promote a SECOND Selected row. The backstop is
     * `BovSubmissionSelectionGuardService`, whose own read is sharing-filtered in exactly the same
     * way, so the pair fails in the SAFE direction (a refusal, never a silent duplicate) only while
     * `viewAllRecords = true` holds on `BOV_Submission__c` in both disposition permission sets —
     * which was read off both files on 2026-08-24 and is the bound. ⚠ THE **WRITE** THAT CONSUMES
     * THIS READ DOES ESCAPE SHARING (`BovAutoSelectionService.SelectionWrites`) and that is a
     * SEPARATE, SEPARATELY JUSTIFIED decision — read it there. A read that succeeds is not evidence
     * a write will, and vice versa.
     *
     * ── 🔴 THE ORDER BY IS THE ALGORITHM, NOT PRESENTATION ─────────────────────────────────────
     * `BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC`. The caller takes the FIRST row that
     * is scoreable and non-preferred and appoints that broker, so this clause IS the tie-break rule
     * — there is no second sort in Apex, deliberately, because a re-sort could disagree with what
     * the matrix shows. `selectByDispositionId` (the matrix's own read) carries the identical
     * clause, which is what guarantees the green **Selected** pill lands on the TOP ROW of the table
     * the user is looking at. If the two ever diverge the feature reads as a bug and is
     * unfalsifiable from the UI.
     * ⚠ `NULLS LAST` is load-bearing and is NOT the same as "nulls are worst". The CALLER skips
     * null-scored rows entirely (a null score is not a rank — `BOV_Score__c` returns null until the
     * parent Disposition's PROPERTY ASSET has a `Target_Sale_Price__c`; ⚠ it said `Asking_Price__c`
     * on the Disposition until 2026-08-25, when that field was retired from the disposition flow and
     * the score's value basis moved two hops out to the asset); `NULLS LAST` merely keeps them from
     * crowding the front of
     * the list. `Id ASC` is not decoration either: `CreatedDate` alone ties for two rows created in
     * the same transaction — every bulk insert and every seed script — and SOQL promises no order
     * for a fully-tied sort.
     *
     * ── 🔴 `CreatedDate` IS SELECTED AND IT IS CONSUMED, NOT DECORATION (added 2026-08-24 with
     *      the preferred-broker-wins decision) ────────────────────────────────────────────────
     * `BovAutoSelectionService` ranks PREFERRED rows by `CreatedDate DESC, Id DESC` — NEWEST FIRST
     * — which is the exact REVERSE of this query's `ORDER BY`, so it cannot be read off the row
     * order and must be compared in memory. Two reasons it is not a second query with a second
     * sort: it would double this method's budget inside a trigger, and two ORDER BY clauses over
     * the same rows are two places for the appointment rule to drift apart.
     * ⚠ `CreatedDate` IS A SYSTEM FIELD AND CARRIES NO `FieldPermissions`, so adding it cannot take
     * this read down the way a custom field could — but this read is `WITH SYSTEM_MODE` anyway.
     *
     * ⚠ NO `Broker_Firm__c` AND NO `Broker__c`, DELIBERATELY, THOUGH THE DESIGN NOTE LISTED THE
     * FIRST. The caller writes `Submission_Status__c` and nothing else; it does NOT stamp the parent
     * and it does NOT write a `BOV_Broker_Change__c` history row (see that service's header for
     * why). Selecting a column nothing reads would be the only thing in this class that is not
     * consumed, and on `Broker__c` specifically it would materialise an unused lookup inside a
     * trigger. The parent stamp still happens — later, on APPROVAL, in
     * `BovSubmissionTriggerHandler.handleApprovedSelections`, from its own read.
     *
     * @param dispositionIds Disposition__c Ids whose submissions to rank; null/empty-safe and
     *                       issues NO query when the set is null or empty.
     * 🔴 ⚠ `Is_System_Selected__c` WAS ADDED TO THIS SELECT ON 2026-08-24 AND IT IS AN IDEMPOTENCY
     * KEY, NOT A REPORT COLUMN. The caller now writes that flag alongside `Submission_Status__c` on
     * the scored winner, so "is this row already correct?" is a TWO-field question. Without this
     * column the caller cannot see a Selected winner that is missing its flag (every row selected
     * before this field existed, and every row a data load promoted), so it would never repair one
     * — and `DispositionApprovalService` would then have no way to tell the two Selected rows apart.
     * ⚠ It is FLS-free by construction because this read is `WITH SYSTEM_MODE`; on a `USER_MODE`
     * sibling it would be a deploy-order prerequisite, since the field is granted READ-ONLY and a
     * missing grant reads as `No such column`.
     *
     * @return Every submission on those dispositions with Id, Disposition__c,
     *         Submission_Status__c, BOV_Score__c, Approval_Pending__c, Approval_Status__c,
     *         Is_Manually_Appointed__c, Is_Preferred_Broker__c, Is_System_Selected__c and
     *         CreatedDate populated, highest score first then oldest first then lowest Id; an EMPTY
     *         LIST when there are none (never null).
     * @example
     * List&lt;BOV_Submission__c&gt; ranked =
     *     BovSubmissionSelector.selectSelectionContextByDispositionIds(dispositionIds);
     */
    public static List<BOV_Submission__c> selectSelectionContextByDispositionIds(
        Set<Id> dispositionIds
    ) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Disposition__c, Submission_Status__c, BOV_Score__c,
                   Approval_Pending__c, Approval_Status__c,
                   Is_Manually_Appointed__c, Is_Preferred_Broker__c, Is_System_Selected__c,
                   CreatedDate
            FROM BOV_Submission__c
            WHERE Disposition__c IN :dispositionIds
            WITH SYSTEM_MODE
            ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC
        ];
    }
    /**
     * Every PREFERRED submission on a SET of Dispositions, carrying everything a
     * `BOV_Broker_Change__c` history row needs — the ONE query behind
     * `BovPreferredBrokerService.retireReplacedPreferred`, which deletes the outgoing preferred
     * broker when a new one is added and logs the swap. Added 2026-08-24 with the two-slot
     * selection model.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 AN EIGHTH METHOD RATHER THAN A WIDENING, AND THE TWO NEAREST NEIGHBOURS ARE BOTH WRONG
     * ══════════════════════════════════════════════════════════════════════════════════════════
     *   `selectSelectionContextByDispositionIds` is set-based, SYSTEM_MODE and already returns
     *   `Is_Preferred_Broker__c` and `CreatedDate` — so it looks like a two-column widening. It is
     *   not: its own header states in terms that it carries NO `Broker__c` and NO `Broker_Firm__c`
     *   *"deliberately... the caller writes `Submission_Status__c` and nothing else"*, and that
     *   its columns are all consumed. Adding a lookup to a hot trigger read to serve a rarer path
     *   would break the one property that header defends.
     *
     *   `selectStatusesByDispositionId` returns exactly the right COLUMNS — and takes a SINGLE
     *   disposition. Calling it per disposition from a trigger is SOQL in a loop.
     *
     * ── FILTERED IN THE `WHERE`, NOT IN APEX ────────────────────────────────────────────────────
     * `Is_Preferred_Broker__c = true` is part of the query because the caller only ever acts on
     * preferred rows. On a sale with twenty scored responses and two preferred ones this returns
     * two rows instead of twenty-two, and it makes the caller's zero-work case visible as an empty
     * list rather than as a loop that finds nothing.
     *
     * ── 🔴 THE ORDER BY IS THE RETIREMENT RULE, NOT PRESENTATION ────────────────────────────────
     * `CreatedDate DESC, Id DESC` — **NEWEST FIRST**, the exact REVERSE of every other ranked query
     * in this class, and it matches `BovAutoSelectionService.isNewer` deliberately. The caller takes
     * row [0] as the SURVIVOR and retires the rest, so the newest preferred broker is the one that
     * keeps the appointment. If this clause is ever "harmonised" with the `CreatedDate ASC` sort its
     * neighbours use, Add Preferred Broker would delete the row the user just created and keep the
     * old one. `Id DESC` is not decoration: two rows created in one transaction share a
     * `CreatedDate`, and SOQL promises no order for a fully-tied sort.
     *
     * ── WITH SYSTEM_MODE, ON AUTOMATION-PATH GROUNDS (ARCHITECTURE.md §2) ───────────────────────
     * The running user asked to ADD A PREFERRED BROKER; they did not ask to read its predecessor's
     * broker lookup. This read runs inside an after-insert trigger on their behalf, and `USER_MODE`
     * THROWS rather than degrades — one ungranted column would surface as
     * `System.QueryException: No such column`, escape the trigger as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and roll back the user's own save.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE — this class stays
     * `with sharing`, and `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing. A preferred row the
     * running user cannot SEE is absent here, so it is neither logged nor deleted, and the old
     * preferred broker simply survives. That fails SAFE (nothing is destroyed on the strength of a
     * read the user could not make) and is bounded by `viewAllRecords = true` on the disposition
     * child objects in both disposition permission sets. 🔴 The WRITE side is a different question
     * with a different answer — see `BovPreferredBrokerService.PreferredRetirementWrites`.
     *
     * @param dispositionIds Disposition__c Ids whose preferred submissions to read; null/empty-safe
     *                       and issues NO query when the set is null or empty.
     * @return Every preferred submission on those dispositions with Id, Disposition__c, Broker__c,
     *         Broker_Firm__c, Submission_Status__c, Is_Preferred_Broker__c and CreatedDate
     *         populated, NEWEST FIRST; an EMPTY LIST when there are none (never null).
     * @example
     * List&lt;BOV_Submission__c&gt; preferred =
     *     BovSubmissionSelector.selectPreferredByDispositionIds(dispositionIds);
     */
    public static List<BOV_Submission__c> selectPreferredByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Disposition__c, Broker__c, Broker_Firm__c, Submission_Status__c,
                   Is_Preferred_Broker__c, CreatedDate
            FROM BOV_Submission__c
            WHERE Disposition__c IN :dispositionIds AND Is_Preferred_Broker__c = TRUE
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }

    /**
     * THE CURRENT SELECTION, WITH ENOUGH CONTEXT TO SAY *WHY* EACH ROW HOLDS ITS SLOT — the read
     * behind the "Broker Selection" card on the Disposition record page
     * (`BovBrokerChangeController.getHistory` -> `c/bovBrokerChangeHistory`). Added 2026-08-25.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 A NINTH METHOD RATHER THAN A WIDENING OF `selectSelectedByDispositionId`, AND THAT IS THE
     *    HOUSE PRECEDENT IN THIS CLASS RATHER THAN A NEW OPINION
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `selectSelectedByDispositionId` has the exact WHERE, the exact ORDER BY and three of the six
     * columns, so it looks like a three-column widening. It is not, for the same reason
     * `selectSelectedBrokerByDispositionId` is a separate method rather than that one plus
     * `Broker__c`: THAT read backs **Submit for Approval**, the module's most business-critical
     * path, and under `WITH USER_MODE` every added column is another way for it to throw
     * `System.QueryException: No such column` — for every user at once — the moment an org is
     * missing one `FieldPermissions` row. Trading a new-throw surface onto Submit for Approval to
     * save a query on a read-only sidebar card is the wrong side of that trade. Two reads with
     * different column lists are two reads.
     *
     * ⚠ AND NOTE THE NAME. This class already carries four `selectSelected…` methods that differ by
     * one character or by one word (see the class header's warning). This one is named for its SLOT
     * vocabulary — `BovAutoSelectionService`'s "TWO SLOTS, NOT ONE" — precisely because it is NOT
     * interchangeable with them: it is the only one that returns the three flags that TELL THE TWO
     * SLOTS APART.
     *
     * ── WHY THE THREE FLAGS, AND WHY ALL THREE ─────────────────────────────────────────────────
     * The card prints one phrase per row saying why that broker is selected, and no single flag can
     * produce it. `Is_Preferred_Broker__c` names the preferred slot; `Is_System_Selected__c` names
     * the row `BovAutoSelectionService` picked on score; `Is_Manually_Appointed__c` names the row a
     * human promoted through Replace Broker, which sets NEITHER of the other two (that is the exact
     * hole `BovSubmissionSelectionGuardService`'s header records, from the other direction). A row
     * carrying none of the three is reachable — anything Selected before these fields existed, and
     * anything a data load promoted — and the controller answers it with a neutral phrase rather
     * than a blank.
     *
     * ── 🔴 `WITH USER_MODE`, AND IT IS THE ARCHITECTURE.md §2 DEFAULT CASE, NOT THE EXCEPTION ───
     * A human is looking at a Disposition record page and this card is on it: the read is one the
     * running user ASKED FOR, so an FLS throw here reports a real provisioning gap and the fix is a
     * permission set — exactly what §2 says `USER_MODE` is for. It is NOT the automation path: no
     * trigger, no batch and no queueable calls this, so a throw cannot roll back somebody's save.
     * The client renders the throw as its own muted "unavailable" state, distinct from empty.
     *
     * ⚠ THE FLS PREREQUISITE WAS MEASURED, NOT ASSUMED (2026-08-25, both disposition permission
     * sets): `Contact_Name__c`, `Broker_Firm__c`, `Is_Preferred_Broker__c`, `Is_System_Selected__c`
     * and `Is_Manually_Appointed__c` are all `readable = true` in `DPEG_Disposition_View` AND
     * `DPEG_Disposition_Edit` — the last two READ-ONLY by design, which is a grant, not a gap.
     * `LastModifiedDate` is a system field and carries no `FieldPermissions` at all. 🔴 DO NOT ADD
     * `Approval_Status__c` OR `Approval_Pending__c` HERE: neither is granted anywhere, deliberately,
     * and either one would take this read down for every user (see
     * `selectStatusesByDispositionId`).
     *
     * ── ORDER BY: THE PREFERRED SLOT FIRST, AND IT IS COPIED FROM `selectSelectedByDispositionId` ─
     * `Is_Preferred_Broker__c DESC, BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC` — the
     * same clause, deliberately identical so the card and Submit for Approval agree on which of two
     * Selected rows is "first". The card renders in this order and does NOT re-sort in JavaScript.
     * ⚠ `BOV_Score__c` is sorted on but NOT selected. That is legal SOQL and it is granted in both
     * permission sets (`selectByDispositionId` reads it under `USER_MODE` today), so it costs this
     * read no new throw surface.
     *
     * ── NOT-FOUND CONTRACT ─────────────────────────────────────────────────────────────────────
     * 🔴 AN EMPTY LIST IS THE NORMAL, MAJORITY ANSWER AND MUST NEVER BECOME A THROW. Most
     * dispositions have no Selected broker for most of their life; the card renders that as "No
     * broker selected yet". Same contract as every other method in this class.
     *
     * @param dispositionId Disposition__c Id whose Selected submissions to read; null-safe and
     *                      issues NO query when null.
     * @return Every Selected BOV_Submission__c on that Disposition with Id, Contact_Name__c,
     *         Broker_Firm__c, Is_Preferred_Broker__c, Is_System_Selected__c,
     *         Is_Manually_Appointed__c and LastModifiedDate populated — PREFERRED FIRST, then
     *         highest-scoring, then oldest. Up to TWO rows is a NORMAL result (one per slot); an
     *         EMPTY LIST when there are none (never null).
     * @throws System.QueryException when the running user lacks read on BOV_Submission__c or on any
     *         of the five custom columns above. The controller converts it to a fixed generic
     *         AuraHandledException; it never reaches the user as a schema error.
     * @example
     * List&lt;BOV_Submission__c&gt; slots =
     *     BovSubmissionSelector.selectSelectedSlotsByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectSelectedSlotsByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Contact_Name__c, Broker_Firm__c, Is_Preferred_Broker__c,
                   Is_System_Selected__c, Is_Manually_Appointed__c, LastModifiedDate
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId AND Submission_Status__c = :STATUS_SELECTED
            WITH USER_MODE
            ORDER BY Is_Preferred_Broker__c DESC, BOV_Score__c DESC NULLS LAST,
                     CreatedDate ASC, Id ASC
        ];
    }

    /**
     * The IDENTITY of every BOV submission on one Disposition — its Id, its `BOV-{0000}` number and
     * one human hint at whose submission it is. Backs `DispositionApprovalHistoryService.getHistory`,
     * which needs the Id SET to find approvals whose `TargetObjectId` is a submission rather than
     * the Disposition, and the Name/hint to LABEL those rows once found.
     * Added 2026-08-26 with the consolidated Approval History card.
     *
     * 🔴 IT RETURNS **EVERY** SUBMISSION, NOT ONLY THE `Selected` ONE, AND THAT IS LOAD-BEARING.
     * `Broker_Finalize_Approval`'s entry criterion is `Submission_Status__c = 'Selected'`, so it is
     * tempting to reuse `selectSelectedByDispositionId` here. That would DELETE HISTORY: a broker
     * who was selected, submitted, approved and later REPLACED is no longer `Selected`, and their
     * approval — a real, completed, audited decision — would vanish from the card the moment the
     * replacement landed. `BovSubmissionService.replaceSelectedBroker` makes that an ordinary
     * outcome, not an edge case. An approval-history read filters on nothing but parentage.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * ⚠ WHY THIS IS A SEPARATE METHOD RATHER THAN A REUSE OF `selectByDispositionId` ABOVE
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * That method returns the same ROWS and already carries `Name`, `Contact_Name__c` and
     * `Broker_Firm__c`, so functionally it fits. It selects ELEVEN fields, and under `WITH
     * USER_MODE` every selected field is an FLS gate — reusing it would give this card EIGHT extra
     * ways to fail for values it never reads. That matters more here than it would elsewhere on
     * this page because **the Approval History card carries NO FlexiPage visibility rule**: it
     * renders at every stage of every disposition, so it is the component most likely to be the
     * first to hit a missing grant. Same per-caller split, same reasoning, as
     * `DispositionSelector.selectBrokerContextById` vs `selectApprovalContextById`.
     *
     * ⚠ `Contact_Name__c` AND `Broker_Firm__c` ARE BOTH NULLABLE and are both stamped from the
     * `Broker__c` lookup, so a row can legitimately carry neither. The caller falls back to the
     * `BOV-{0000}` number, which the platform guarantees. This method does NOT traverse `Broker__r`
     * for a name: that would add OBJECT read on `Contact` as a gate — a grant that lives in a
     * DIFFERENT permission set from the disposition ones (see
     * `DispositionBuyerTimelineController`'s header) — for a hint the card can do without.
     *
     * ── NO `ORDER BY` ─────────────────────────────────────────────────────────────────────────
     * Nothing ranks these rows. They are folded into a `Map<Id, …>` and looked up by Id; the card's
     * ordering is the APPROVALS' (`ProcessInstanceSelector.selectHistoryByTargetIds`). Adding one
     * would imply a display order that does not exist.
     *
     * @param dispositionId Disposition__c Id whose submissions to identify; null-safe.
     * @return Id / Name / Contact_Name__c / Broker_Firm__c for every submission on the
     *         Disposition; an empty list when it has none or the input is null. Never null.
     * @example
     * List&lt;BOV_Submission__c&gt; targets =
     *     BovSubmissionSelector.selectApprovalTargetsByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectApprovalTargetsByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<BOV_Submission__c>();
        }
        return [
            SELECT Id, Name, Contact_Name__c, Broker_Firm__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
        ];
    }
}
