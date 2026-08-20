/**
 * Selector for Disposition_Offer__c — THE FIRST AND ONLY Disposition_Offer__c SOQL IN THIS
 * APPLICATION. Verified 2026-08-10: `grep "FROM Disposition_Offer__c" classes/` returned nothing
 * before this file existed. Every future Disposition_Offer__c read belongs here
 * (ARCHITECTURE.md §2, .claude/rules/apex-layering-rule.md).
 *
 * ⚠ THE LWC `dispositionOffer` DOES NOT USE THIS CLASS AND MUST NOT BE MIGRATED ONTO IT AS
 * "TIDYING". It reads its rows through the LDS `getRelatedListRecords` adapter, which is the
 * ARCHITECTURE.md §5 LDS-first default and is correct for a list a human asked to see. This
 * selector exists for the one thing LDS cannot express: a COUNT that must be the same number for
 * every viewer.
 *
 * ── 🔴 WHY THE COUNT LIVES IN A `private without sharing` INNER CLASS ────────
 * `Disposition_Offer__c` is `sharingModel = Private` (measured in the object file). The count this
 * class returns feeds `DispositionTractionService`, which turns "zero offers at day 30" into a
 * displayed instruction to discuss changing the broker (decision D28/Q1 — offers only). So an
 * UNDER-count does not degrade the feature, it CORRUPTS it: a listing with three offers the running
 * user cannot see would be reported as having no traction, and a real broker would be replaced on
 * the strength of a number that was only ever true for one viewer.
 *
 * That is the failure shape ARCHITECTURE.md §2 records for a sharing-filtered aggregate: it fails
 * as a WRONG ANSWER, not as an error, so nothing anywhere would notice. `SYSTEM_MODE` alone does
 * NOT close it — SYSTEM_MODE lifts CRUD and FLS and never sharing — so the query lives in
 * `TractionReads`, mirroring `LeadSelector.GuestReads` and `InboundEmailStagingSelector.RoutingReads`.
 * The OUTER class stays `with sharing` so a future row-returning read is user-scoped by default.
 *
 * ⚠ THE EXPOSURE, STATED RATHER THAN BURIED: a principal who cannot see an offer row can now learn
 * that it EXISTS, as part of a count, on a Disposition record page they are already viewing. It is
 * a count and never a row — no buyer, no amount, no date crosses this boundary. And for the two
 * personas this feature is actually for it is NOT a widening at all: `DPEG_Disposition_Edit` and
 * `DPEG_Disposition_View` both already carry `viewAllRecords = true` on `Disposition_Offer__c`
 * (measured in the permission-set files), so they could already see every row.
 *
 * ⚠ "THE ONLY CONSUMER" WAS TRUE UNTIL 2026-08-19 AND IS NO LONGER. The disposition flow redesign
 * added `selectSelectionStateByDispositionId`, backing `DispositionApprovalService.selectOffer`;
 * Tranche 2 Workstream A2 added `selectSelectedByDispositionIds` on 2026-08-20, backing
 * `DispositionOfferSelectionGuardService.enforceSingleSelected` (the before-context single-selected
 * trigger guard).
 * 🔴 NEITHER USES `TractionReads`, AND THAT IS A DECISION, NOT AN OVERSIGHT — the argument for
 * `without sharing` above is specific to an AGGREGATE feeding an automated verdict, and it does not
 * transfer to a row read backing a click, nor to a guard that fails OPEN when a row is invisible.
 * The reasoning is re-derived at each method rather than inherited; read it there.
 *
 * @see force-app/main/default/classes/DispositionTractionService.cls (the count consumer)
 * @see force-app/main/default/classes/DispositionApprovalService.cls (the selection consumer)
 * @see force-app/main/default/classes/LeadSelector.cls (the GuestReads inner-class precedent)
 */
public with sharing class DispositionOfferSelector {

    /**
     * Offer count per Disposition — the objective half of the traction test.
     *
     * BULK BY CONSTRUCTION: one aggregate query for the whole set, never one per record. A
     * Disposition with no offers is ABSENT from the result map rather than present with 0, because
     * `GROUP BY` emits no row for an empty group; callers must default a miss to 0 and
     * `DispositionTractionService.evaluateAll` does exactly that.
     *
     * `WITH SYSTEM_MODE` for the FLS leg and `without sharing` (see the class header) for the
     * record leg — two separate decisions with two separate reasons, not one keyword doing both.
     * The FLS leg: `Disposition_Offer__c.Disposition__c` is granted on both disposition permission
     * sets today, but `USER_MODE` THROWS rather than degrades, so any principal outside those sets
     * — an administrator without `DPEG_Acquisitions`, an integration user, a future automated
     * caller — would blank the entire traction panel instead of reading a count.
     *
     * @param dispositionIds Disposition__c Ids to count offers for; null/empty safe.
     * @return Disposition__c Id -> offer count, omitting dispositions with zero offers.
     */
    public static Map<Id, Integer> countByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new Map<Id, Integer>();
        }
        Map<Id, Integer> counts = new Map<Id, Integer>();
        for (AggregateResult ar : new TractionReads().countRows(dispositionIds)) {
            counts.put((Id) ar.get('dispositionId'), (Integer) ar.get('offerCount'));
        }
        return counts;
    }

    /**
     * Every offer's SELECTION STATE for one Disposition — backs
     * `DispositionApprovalService.selectOffer`, which sets `Is_Selected__c = true` on the chosen
     * offer and `false` on every other offer of that Disposition in ONE DML.
     *
     * 🔴 IT MUST RETURN EVERY OFFER, NOT JUST THE SELECTED ONE, FOR THE SAME REASON THE BOV
     * EQUIVALENT DOES. `Offer_Selection_Approval`'s entry criterion is `Is_Selected__c = true`, so
     * "exactly one selected offer per disposition" is not tidiness — it is what keeps ONE record in
     * that approval. Reading only the currently-selected row would miss a second flag left behind
     * by an earlier partial failure and leave two offers approval-eligible. Reading all of them
     * makes the operation self-healing, and lets the caller build a CHANGE-ONLY update list (rows
     * already holding the right value are omitted, so a re-pick of the same offer costs no DML and
     * fires no trigger).
     *
     * ⚠ IT IS ALSO THE MEMBERSHIP CHECK. The caller supplies an offer Id from a client radio list;
     * this result is what proves that Id actually belongs to THIS Disposition, so a hand-crafted
     * call cannot select another sale's offer. Narrowing this to `WHERE Id = :offerId` would delete
     * that check as a side effect.
     *
     * ── WITH SYSTEM_MODE — the field again, exactly as on the BOV twin ────────
     * `Is_Selected__c` is a 2026-08-19 field and arrives with NO FLS for any profile, System
     * Administrator included; the permission sets then grant it READ ONLY (it is written by this
     * feature, never by hand). `USER_MODE` THROWS rather than degrades, so it would refuse the
     * whole Select Offer action for everyone in the deploy window with
     * `System.QueryException: No such column 'Is_Selected__c'`. The WRITE is `SYSTEM_MODE` for the
     * same reason, and a `USER_MODE` read feeding a `SYSTEM_MODE` write would be a shape where the
     * write is permitted and the read deciding what to write is not.
     *
     * ── 🔴 AND IT STAYS `with sharing` — THE `TractionReads` ARGUMENT DOES NOT REACH IT ──
     * The count above escapes sharing because an UNDER-count silently INVERTS an automated verdict
     * ("no traction, change the broker") that no human ever checks. This read is different in every
     * particular that mattered there: a human is looking at the offer list, they picked a row FROM
     * it, and an offer they cannot see is one they did not pick. The residual — a hidden offer's
     * stale `Is_Selected__c = true` surviving the exclusivity sweep — is bounded by the same
     * measured fact the class header records for the count: `DPEG_Disposition_View` and
     * `DPEG_Disposition_Edit` both carry `viewAllRecords = true` on `Disposition_Offer__c`, so for
     * the two personas this feature exists for there is nothing to hide. Widening a live
     * authorization boundary on speculation is what this repo declines to do elsewhere; if that
     * ever changes, the shape to reach for is a SECOND narrow `private without sharing` inner class
     * holding only this query — never widening `TractionReads` to carry both.
     *
     * @param dispositionId Disposition__c Id whose offers to read; null-safe.
     * @return All offers with Id and Is_Selected__c populated; an empty list when the Disposition
     *         has none or the input is null.
     * @example
     * List&lt;Disposition_Offer__c&gt; offers =
     *     DispositionOfferSelector.selectSelectionStateByDispositionId(dispId);
     */
    public static List<Disposition_Offer__c> selectSelectionStateByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return new List<Disposition_Offer__c>();
        }
        return [
            SELECT Id, Disposition__c, Is_Selected__c, Offer_Status__c
            FROM Disposition_Offer__c
            WHERE Disposition__c = :dispositionId
            WITH SYSTEM_MODE
            ORDER BY Offer_Amount__c DESC NULLS LAST
        ];
    }

    /**
     * Every COMMITTED selected offer across a SET of Dispositions — the one query behind
     * `DispositionOfferSelectionGuardService.enforceSingleSelected`, the before-context trigger
     * guard that refuses a save which would leave a disposition with two selected offers.
     *
     * 🔴 IT TAKES A SET, NOT AN ID, AND THAT IS THE WHOLE POINT. Its caller runs inside a trigger
     * chunk of up to 200 records spanning arbitrarily many dispositions. The single-Id sibling
     * `selectSelectionStateByDispositionId` would have to be called once per record — SOQL in a
     * loop, which blows the 100-query limit at 101 rows. Do not "simplify" the guard onto it.
     *
     * ⚠ IT DELIBERATELY RETURNS ROWS AND NOT A COUNT, EVEN THOUGH THE CALLER ONLY COUNTS THEM. The
     * guard must SUBTRACT the rows present in `Trigger.new` (their in-memory value supersedes their
     * committed one — that is what lets `DispositionApprovalService.selectOffer` de-select and
     * select in one DML without being refused). A `GROUP BY` aggregate cannot be filtered by Id
     * after the fact, so an aggregate here would silently count the de-selected incumbent and turn
     * the guard into a blanket refusal of the Select Offer action.
     *
     * ⚠ NO `ORDER BY` AND NO `LIMIT`. Nothing ranks these rows — they are counted, not displayed —
     * and a `LIMIT` would cap the count and under-report a pre-existing duplicate, which is the one
     * state this read must be able to see.
     *
     * ── 🔴 WITH SYSTEM_MODE — AND HERE BOTH ARGUMENTS APPLY AT ONCE ──────────────
     * THE FIELD: `Is_Selected__c` is a 2026-08-19 field granted READ ONLY on both disposition
     * permission sets and absent for every other principal, so `USER_MODE` would throw
     * `System.QueryException: No such column 'Is_Selected__c'` — exactly as it would for
     * `selectSelectionStateByDispositionId`.
     * THE CALLER: this read is performed ON THE RUNNING USER'S BEHALF, not at their request (they
     * asked to save an offer, not to read its siblings), and `USER_MODE` THROWS rather than
     * degrades. Inside a BEFORE trigger that throw escapes as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and ROLLS BACK THE USER'S OWN SAVE — a guard that takes
     * down the save it was meant to validate is worse than no guard. ARCHITECTURE.md §2's
     * automation-path exception, in its purest form.
     *
     * ── 🔴 AND IT STAYS `with sharing` — `TractionReads` DOES NOT REACH IT EITHER ──
     * The count above escapes sharing because an UNDER-count silently INVERTS an automated verdict
     * nobody checks. An under-count HERE makes the guard FAIL OPEN — it permits a second selected
     * offer rather than blocking a legitimate one — which is the safer direction, and it keeps this
     * class from telling a principal that a row they cannot see exists by refusing them because of
     * it. Bounded by the same measured fact the class header records: both `DPEG_Disposition_Edit`
     * and `DPEG_Disposition_View` carry `viewAllRecords = true` on `Disposition_Offer__c`.
     *
     * @param dispositionIds Disposition__c Ids whose selected offers to read; null/empty-safe and
     *                       issues NO query when the set is empty.
     * @return Every committed offer on those dispositions with `Is_Selected__c = true`, with Id,
     *         Disposition__c and Is_Selected__c populated; an empty list when there are none.
     * @example
     * List&lt;Disposition_Offer__c&gt; selected =
     *     DispositionOfferSelector.selectSelectedByDispositionIds(dispositionIds);
     */
    public static List<Disposition_Offer__c> selectSelectedByDispositionIds(
        Set<Id> dispositionIds
    ) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<Disposition_Offer__c>();
        }
        return [
            SELECT Id, Disposition__c, Is_Selected__c
            FROM Disposition_Offer__c
            WHERE Disposition__c IN :dispositionIds AND Is_Selected__c = true
            WITH SYSTEM_MODE
        ];
    }

    /**
     * The one query that must not be sharing-filtered. Narrow on purpose: it holds a single
     * aggregate and nothing else, so `without sharing` can never leak into a read that legitimately
     * belongs to a human.
     */
    private without sharing class TractionReads {
        private List<AggregateResult> countRows(Set<Id> dispositionIds) {
            return [
                SELECT Disposition__c dispositionId, COUNT(Id) offerCount
                FROM Disposition_Offer__c
                WHERE Disposition__c IN :dispositionIds
                WITH SYSTEM_MODE
                GROUP BY Disposition__c
            ];
        }
    }
}
