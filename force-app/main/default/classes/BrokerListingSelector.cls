/**
 * Selector for Broker_Listing__c. Encapsulates ALL SOQL against Broker_Listing__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumers:
 *   - BrokerListingController.getListing (the active listing card on the
 *     Disposition record page)                       -> selectMostRecentByDispositionId
 *   - DispositionStageEntryService.openBrokerListings (the Active Listing
 *     auto-create idempotency guard, Tranche 5B)      -> selectByDispositionIds
 *   - BovSubmissionService.replaceSelectedBroker (the "has this sale been listed
 *     yet?" gate on the broker-change listing APPEND, Tranche 4 item 5,
 *     2026-09-01)                                     -> selectByDispositionIds
 *
 * ⚠ MIXED MODES SINCE 2026-08-10 (Tranche 5B) — READ THE METHOD, NEVER THIS HEADER.
 * `selectMostRecentByDispositionId` stays `WITH USER_MODE`: it backs a card a human
 * asked to see. `selectByDispositionIds` is `WITH SYSTEM_MODE` under the
 * ARCHITECTURE.md §2 automation-path exception, justified at its own declaration.
 * The sentence this replaced — "There is no guest path here, so no SYSTEM_MODE
 * appears" — tested for the wrong thing: the exception is about reads the running
 * user never asked for, not about anonymous ones.
 *
 * MODE (the USER_MODE read) — Broker_Listing__c is a custom object; P3 proved the
 * custom-field FLS gap is 0, so USER_MODE is safe and enforces the running user's
 * sharing + FLS.
 *
 * NOT-FOUND CONTRACT — read-for-display: a Disposition may have no listing yet,
 * which is normal, so this returns SObject-or-null. The dispositionId is bound
 * straight into the WHERE clause, mirroring the exact query semantics of the
 * relocated getListing statement (which had no pre-query null guard).
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 */
public with sharing class BrokerListingSelector {

    /**
     * Most-recent Broker Listing for one Disposition — backs
     * BrokerListingController.getListing. A Disposition with no listing yet is a
     * normal state, so this returns null rather than throwing.
     *
     * ORDER BY is `CreatedDate DESC` only, preserving getListing's original
     * ordering verbatim (no Id tiebreak was present, so none is added).
     *
     * ⚠ `ORDER BY CreatedDate DESC LIMIT 1` IS ALREADY WRITTEN AS "the current
     * listing among several", which is what makes the broker-change history model
     * (append a second Broker_Listing__c rather than overwrite the first) work with
     * no schema change and no edit to this method. Do not narrow it to a
     * single-row assumption.
     *
     * 🔴 THE FIELD LIST IS A CONTRACT — DO NOT NARROW IT. It is the exact set
     * BrokerListingController.ListingRow maps, plus `Disposition__r.Listing_Date__c`,
     * added 2026-08-10 (Tranche 5B). That parent date is the marketing clock the
     * traction badge is computed from, and it rides the EXISTING grandparent path,
     * so the traction computation costs this query ZERO extra SOQL.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 REPOINTED 2026-08-31 (Tranche 1 item 6): `Days_On_Market__c` -> `Days_On_Market_Live__c`.
     *    The paragraph below is RETRACTED IN PLACE because it was a correct description of a
     *    field that is no longer in this SELECT, and its final sentence is now the thing that
     *    happened:
     *
     *        RETRACTED: "⚠ `Days_On_Market__c` (the Broker_Listing__c one) is still selected and
     *        is now LEGACY: it is a hand-keyed Number that nothing writes, and the controller no
     *        longer derives anything from it. It is retained so the field is still available to a
     *        caller that wants the stored value, and so removing it is a deliberate decision
     *        rather than a side effect of this change."
     *
     *    WHAT STAYS TRUE: every word about the STORED `Days_On_Market__c`. It is still a
     *    hand-keyed Number that nothing writes, it is still in the org, and it is NOT deleted —
     *    additive retirement, per this repo's standing rule; its removal is deferred and is
     *    blocked on a report that cannot be repointed without a report type that does not exist.
     *    Dropping it from this SELECT is the deliberate decision that sentence asked for.
     *
     * `Days_On_Market_Live__c` is a NUMBER FORMULA — `IF(ISBLANK(List_Date__c), null, TODAY() -
     * List_Date__c)` — so nothing writes it, it cannot go stale, and it cannot be seeded.
     *
     * 🔴 IT IS RAW ELAPSED DAYS AND IT IS **NOT** THE ESCALATION CLOCK (design decision D-3). The
     * marketing clock lives in `DispositionTractionService`, which computes days in Apex and is to
     * gain a PAUSE at the first offer. This formula keeps counting after an offer arrives, so the
     * two WILL disagree on the same card once that pause ships — by design, because they answer
     * different questions. NOTHING MAY READ THIS FIELD TO DRIVE AN ALERT. `BrokerListingController`
     * does not read it (it derives `daysOnMarket` from the raw date via the traction service) and
     * must not start.
     *
     * ⚠ ADDING IT HERE IS AN FLS CHANGE ON A `USER_MODE` READ, WHICH THROWS RATHER THAN DEGRADES.
     * The grant for `Broker_Listing__c.Days_On_Market_Live__c` must land in the SAME deploy wave as
     * this line or the Active Listing card red-banners for everyone. A formula field can only ever
     * be `editable=false`; `editable=true` on one is a deploy error, which is exactly what the
     * still-present `DPEG_Disposition_Edit` grant on the STORED field is allowed to remain.
     *
     * @param dispositionId Disposition__c Id to read the latest listing for.
     * @return The most recently created Broker_Listing__c for the Disposition
     *         (ORDER BY CreatedDate DESC LIMIT 1), or null when none exists.
     * @example
     * Broker_Listing__c bl =
     *     BrokerListingSelector.selectMostRecentByDispositionId(dispId);
     */
    public static Broker_Listing__c selectMostRecentByDispositionId(Id dispositionId) {
        List<Broker_Listing__c> listings = [
            SELECT Id, Disposition__r.Property_Asset__r.Name,
                   Disposition__r.Listing_Date__c,
                   Broker_Firm__c, Contact_Name__c, List_Date__c,
                   Call_For_Offers_Date__c, Days_On_Market_Live__c, Listing_Status__c,
                   Offers_Received__c
            FROM Broker_Listing__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return listings.isEmpty() ? null : listings[0];
    }

    /**
     * Existing listings for a set of Dispositions — the idempotency guard behind
     * `DispositionStageEntryService`'s Active Listing block (Tranche 5B, D28/Q3).
     *
     * ── 🔴 WITH SYSTEM_MODE — automation path, and the failure it prevents is a
     * ROLLED-BACK STAGE CHANGE, not a blank card ─────────────────────────────
     * This read happens inside an AFTER-UPDATE TRIGGER on `Disposition__c`, on
     * behalf of whoever moved the stage. Nobody asked for it and nothing it returns
     * is displayed. `USER_MODE` THROWS rather than degrades, so any principal
     * without `Broker_Listing__c` read — an administrator holding neither
     * `DPEG_Acquisitions` nor `DPEG_Disposition_Edit`, a data load, a future
     * Flow-driven stage change — would raise a `QueryException` that escapes
     * `DispositionTriggerHandler.afterUpdate` as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY
     * and roll back the stage change itself. That is the `TaskRollupService`
     * production incident verbatim (ARCHITECTURE.md §2: 82 Tasks rolled back by a
     * USER_MODE read inside a trigger), and a guard added to make auto-create safe
     * must not be able to destroy the transaction it guards.
     *
     * ⚠ SHARING IS LEFT USER-SCOPED and that is a decision, not an omission. The
     * class stays `with sharing`, so a listing the running user cannot SEE is
     * absent from the result and the guard would open a SECOND listing. That is the
     * safe direction here: a duplicate listing row is visible on the record and
     * removable by hand, whereas the alternative (`without sharing`) widens a read
     * for a case that cannot arise — both disposition permission sets carry
     * `viewAllRecords = true` on `Broker_Listing__c` (measured), and a principal
     * with no visibility of the listings has no visibility of the disposition
     * either, so they cannot have moved its stage.
     *
     * Bulk-safe: ONE query for the whole chunk, never one per record. Only the
     * parent lookup is selected — the guard asks "does one exist?", nothing more.
     *
     * ── ⚠ A SECOND CALLER SINCE 2026-09-01, AND ITS POLARITY IS THE OPPOSITE ────
     * `BovSubmissionService.replaceSelectedBroker` asks the same question to decide
     * whether to APPEND a listing for an incoming broker (Tranche 4 item 5, D-10).
     * The two callers read the same emptiness in opposite directions — the stage
     * entry creates when this returns NOTHING, the broker change appends when it
     * returns SOMETHING — and both are safe under the sharing note above for the
     * SAME reason, which is worth stating because it is not obvious that it
     * survives the inversion: a short read makes the stage entry open a duplicate
     * listing (visible, removable by hand) and makes the broker change skip an
     * append (visible on the card, repairable by hand). Neither direction produces
     * a silent wrong state. 🔴 IF THIS METHOD EVER GAINS `without sharing` FOR THE
     * FIRST CALLER, RE-READ THE SECOND: a read that starts seeing rows the running
     * user cannot would let a Replace Broker at BOV Outreach append a listing, and
     * THAT failure is silent and permanent (it turns the stage-entry auto-create
     * into a no-op forever). Read `replaceSelectedBroker`'s `saleIsListed` block.
     *
     * @param dispositionIds Disposition__c Ids; null/empty-safe.
     * @return Broker Listings on those dispositions, Id + Disposition__c only;
     *         empty when the input is null or empty.
     */
    public static List<Broker_Listing__c> selectByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<Broker_Listing__c>();
        }
        return [
            SELECT Id, Disposition__c
            FROM Broker_Listing__c
            WHERE Disposition__c IN :dispositionIds
            WITH SYSTEM_MODE
        ];
    }
}
