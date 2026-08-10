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
 * @see force-app/main/default/classes/DispositionTractionService.cls (the only consumer)
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
