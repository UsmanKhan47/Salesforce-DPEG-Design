/**
 * Service for the LOI counter-offer write workflow.
 *
 * Owns the business logic behind CounterOfferController.saveCounterOffer (P6 controller
 * thinning): validate the counter, append a Counter_Offer__c to the LOI's negotiation
 * history, then stamp the latest terms onto the parent LOI and flip Ball_In_Court__c. Per
 * .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2, this DML and these business
 * rules are Service work, not Controller work — the controller now only marshals input,
 * delegates here, and maps failures to an AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5).
 *
 * ── 🔴 THE COUNTERPARTY LABEL INVERTS BETWEEN A PURCHASE AND A SALE (Tranche 3B) ──
 * On an ACQUISITION, DPEG is the buyer and the counterparty is the SELLER.
 * On a DISPOSITION, DPEG is the seller and the counterparty is the BUYER.
 *
 * 'Us' / 'Ours' therefore always mean DPEG and never invert. 'Seller' does:
 *
 *                                     Acquisition_LOI        Disposition_LOI
 *   Counter_Offer__c.Direction__c
 *     DPEG countered                  'Ours'                 'Ours'
 *     the counterparty countered      'Seller'               'Buyer'
 *   LOI__c.Ball_In_Court__c
 *     it is DPEG's turn               'Us'                   'Us'
 *     it is the counterparty's turn   'Seller'               'Buyer'
 *
 * Before this change the class hardcoded 'Us' / 'Seller', so EVERY disposition counter would
 * have written the OPPOSITE of what happened: `Ball_In_Court__c = 'Seller'` on a sale names
 * DPEG, so a counter that put the ball in the BUYER's court would have displayed as ours, and
 * vice versa. `Direction__c` fails more mildly — 'Seller' merely READS oddly next to a buyer's
 * counter — but the two are given IDENTICAL treatment here on purpose: they are written in one
 * transaction and read side by side (the history table and the ball badge sit in the same LWC
 * card), so labelling one counterparty two different ways would make the record contradict
 * itself. Fixing only the urgent one is the worse outcome, not the smaller one.
 *
 * ── HOW THE SIDE IS DECIDED: isSaleSide(), AUTHORITATIVE-THEN-FALLBACK ──────
 * The label is ALWAYS derived from the parent LOI and NEVER taken from the caller. That is
 * what makes a cross-record-type picklist write structurally impossible here — the same
 * property RecordStageAdvanceService's per-record-type allow-list gives the stage field, and
 * necessary for the same reason: Apex DML does not enforce record-type picklist restriction.
 *
 * ── THE `direction` ARGUMENT IS A ROLE, NOT A LABEL. ────────────────────────
 *   'Ours'    -> DPEG countered.             Accepted on both record types.
 *   'Seller'  -> the counterparty countered. Accepted on both record types.
 *   'Buyer'   -> the counterparty countered. Accepted on a DISPOSITION LOI ONLY.
 *
 * ⚠ THAT ASYMMETRY IS DELIBERATE AND IS NOT AN OVERSIGHT. 'Seller' is the INCUMBENT WIRE
 * TOKEN: it is what the deployed lwc/loiCounterOffer picker sends ("Seller countered us"), and
 * it has meant "the counterparty" since the feature shipped. Refusing it on a sale would leave
 * the deployed picker with a dead Save button until the UI wave lands. 'Buyer' is NEW and has
 * never meant anything, so it can be given one unambiguous meaning without breaking a caller —
 * and it is refused on an acquisition because there 'Buyer' would name DPEG, so accepting it
 * would be a guess about which side the caller meant. Guessing on the field that decides whose
 * turn it is is exactly the defect this change fixes.
 *
 * ⚠ KNOWN, DELIBERATELY OUT OF SCOPE — lwc/loiCounterOffer STILL RENDERS SELL-SIDE VALUES WITH
 * BUY-SIDE WORDING. Its DIRECTION pill map has no 'Buyer' key so a Buyer counter falls through
 * to the Seller pill, and ballBadgeLabel returns 'Ball: seller court' for anything that is not
 * 'Us'. Both are DISPLAY defects sitting on top of a now-correct record, which is strictly
 * better than the previous state (a wrong record), and both belong to the 3B UI wave.
 *
 * ⚠ THE PARENT READ IS `WITH SYSTEM_MODE`, DELIBERATELY. `Disposition__c` is a NEW field in this
 * tranche, and a Metadata-API-deployed custom field arrives with no FLS for ANY profile — so a
 * USER_MODE read would have made the LIVE ACQUISITION counter-offer save depend on an FLS grant for
 * a disposition-only lookup that acquisitions users have no reason to hold. Measured, not
 * anticipated: a check-only run on 2026-08-09 reproduced it as
 * `System.QueryException: No such column 'Disposition__c' on entity 'LOI__c'`. The full argument
 * (and the reason sharing is NOT relaxed with it) is at LoiSelector.selectNegotiationContextById.
 *
 * All SOQL is delegated to LoiSelector / CounterOfferSelector — this service holds no inline
 * SOQL. It throws a typed CounterOfferException for a user-actionable rule violation (surfaced
 * verbatim) and the raw platform DmlException on a save failure; the AuraHandledException
 * boundary lives in the controller, NOT here, so the service stays UI-agnostic (also callable
 * from Flow / Apex).
 *
 * TRANSACTIONALITY: the append + parent stamp are two DML statements with no explicit
 * Savepoint — intentionally matching the pre-thinning behaviour. If the stamp fails, the
 * AuraHandledException the controller re-throws is unhandled at the @AuraEnabled entry
 * point, so the platform rolls back the whole transaction (including the appended
 * Counter_Offer__c). No orphan child survives a failed stamp.
 *
 * GOVERNOR SHAPE: 1 SOQL + 2 DML per invocation, and it was 0 SOQL + 2 DML before Tranche 3B.
 * The added read is the price of deriving the label server-side; saveCounterOffer is a
 * per-transaction-singleton @AuraEnabled operation invoked once per LWC save, so it is paid
 * once per click and never in a loop.
 *
 * ⚠ ONE ORDERING CHANGE, AND IT IS THE SAME ONE Tranche 3A MADE TO advanceTo(). The direction
 * used to be validated BEFORE anything was read; it is now validated AFTER the parent load,
 * because the set of valid tokens is a property of the record type and the record type is a
 * property of the row. Visible consequence: saveCounterOffer against a NON-EXISTENT LOI Id and
 * a bad direction now raises System.QueryException where it previously raised
 * CounterOfferException. Both land in CounterOfferController's generic clause and produce the
 * same fixed message, so no user-visible wording changes. The null-loiId guard deliberately
 * stays FIRST — it is the one refusal that needs no row.
 *
 * ⚠ The acquisition-side refusal wording is BYTE-IDENTICAL to the pre-3B message
 * ('Pick who made this counter (Seller or Ours).'). Only a disposition LOI says 'Buyer'.
 *
 * @see force-app/main/default/classes/CounterOfferController.cls (thin caller)
 * @see force-app/main/default/classes/LoiSelector.cls (selectNegotiationContextById)
 * @see force-app/main/default/classes/CounterOfferSelector.cls (history read)
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls (the other per-record-type
 *      LOI behaviour — stage sequence, allow-list and permission gate)
 */
public with sharing class CounterOfferService {

    /**
     * Raised for a user-actionable business-rule violation whose message is user-safe
     * and surfaced verbatim to the LWC: no primary LOI on the deal, or a counter direction
     * that is not valid for this LOI's side of the deal. Distinct from an unexpected platform
     * DmlException, which the controller maps to a fixed generic message instead.
     */
    public class CounterOfferException extends Exception {}

    /** LOI__c record type developer names (D6). Case must match objects/LOI__c/recordTypes/. */
    @TestVisible
    private static final String RT_ACQUISITION_LOI = 'Acquisition_LOI';
    @TestVisible
    private static final String RT_DISPOSITION_LOI = 'Disposition_LOI';

    /** The DPEG side. Never inverts, so it is one constant for both record types. */
    private static final String DIRECTION_OURS = 'Ours';
    private static final String BALL_US = 'Us';

    /** The counterparty, named from DPEG's side of THIS deal. These are what invert. */
    private static final String COUNTERPARTY_ACQUISITION = 'Seller';
    private static final String COUNTERPARTY_DISPOSITION = 'Buyer';

    /**
     * Records one counter offer against an LOI and reflects it on the parent.
     *
     * @param loiId            the parent LOI__c (required)
     * @param direction        who made the counter — see the class header's token table:
     *                         'Ours' (DPEG) or 'Seller' (the counterparty) on either record
     *                         type, or 'Buyer' (the counterparty) on a disposition LOI only
     * @param counterPrice     the countered price
     * @param counterCapRate   the countered cap rate
     * @param counterDate      the counter date; defaults to today when null
     * @param counterResponse  the free-text response/notes
     * @param revisionNumber   the revision label (Text despite the "_Number" suffix)
     * @param subsequentVersion the subsequent-version label
     * @throws CounterOfferException when loiId is null, or direction is not a token valid for
     *         this LOI's record type
     * @throws System.QueryException when loiId matches no LOI
     * @throws System.DmlException   on a platform save failure
     */
    public static void saveCounterOffer(Id loiId, String direction, Decimal counterPrice,
            Decimal counterCapRate, Date counterDate, String counterResponse,
            String revisionNumber, String subsequentVersion) {
        if (loiId == null) {
            throw new CounterOfferException('No primary LOI is set on this deal.');
        }
        // FETCH-FOR-USE. The label written below is a function of this row and of nothing the
        // caller supplied; reading it is the whole mechanism.
        LOI__c parent = LoiSelector.selectNegotiationContextById(loiId);
        String counterparty = isSaleSide(parent)
            ? COUNTERPARTY_DISPOSITION
            : COUNTERPARTY_ACQUISITION;
        Boolean fromCounterparty = isFromCounterparty(direction, counterparty);

        Date effectiveDate = (counterDate == null) ? Date.today() : counterDate;
        insert new Counter_Offer__c(
            LOI__c = loiId,
            // ⚠ The stored value is the DERIVED label, never the caller's token. A caller
            // sending 'Seller' on a sale gets 'Buyer' stored, which is the correction this
            // change exists to make.
            Direction__c = fromCounterparty ? counterparty : DIRECTION_OURS,
            Counter_Price__c = counterPrice,
            Counter_Cap_Rate__c = counterCapRate,
            Counter_Date__c = effectiveDate,
            Counter_Response__c = counterResponse,
            Revision_Number__c = String.isBlank(revisionNumber) ? null : revisionNumber.trim(),
            Subsequent_Version__c = String.isBlank(subsequentVersion) ? null : subsequentVersion.trim()
        );

        // Reflect the latest counter on the parent LOI and flip whose turn it is: a counterparty
        // counter puts the ball in OUR court, ours in theirs.
        LOI__c stamp = new LOI__c(
            Id = loiId,
            Counter_Price__c = counterPrice,
            Counter_Cap_Rate__c = counterCapRate,
            Counter_Response__c = counterResponse,
            Ball_In_Court__c = fromCounterparty ? BALL_US : counterparty,
            // ⚠ LOI_Status__c is acquisition vocabulary and is stamped on a disposition counter
            // too. That is deliberate and is recorded in the Disposition_LOI record type file:
            // the value is excluded from the disposition LAYOUT, Is_Advance_Allowed__c reads the
            // field on EVERY LOI, and suppressing the write here would be a behaviour change
            // nobody asked for.
            LOI_Status__c = 'Countered'
        );
        if (fromCounterparty) {
            stamp.Counter_Received_Date__c = effectiveDate;
        }
        update stamp;
    }

    /**
     * Whether this LOI is on the SELL side, i.e. whether the counterparty is the buyer.
     *
     * AUTHORITATIVE FIRST, FALLBACK SECOND — the two clauses answer different questions and the
     * order matters:
     *
     *  1. THE RECORD TYPE IS AUTHORITATIVE (D6). A row explicitly on Acquisition_LOI is buy-side
     *     even if someone populated Disposition__c by mistake, and the reverse. Comparing with
     *     constant-first String.equals is REQUIRED, not stylistic: Apex `==` on String is
     *     case-INSENSITIVE while getRecordTypeInfosById() reports the metadata casing, so `==`
     *     would silently accept a mis-cased developer name that the describe map never produced —
     *     the identical trap TestDataFactory.dispositionRecordTypeId documents at length.
     *  2. THE Disposition__c LOOKUP IS THE FALLBACK, and it is load-bearing rather than
     *     defensive. Until post-deploy gates T-A1/T-A2 run, every LOI in the org sits on the
     *     MASTER record type (or has no RecordTypeId at all), so clause 1 yields nothing — and a
     *     disposition LOI created in that window would otherwise be labelled with buy-side
     *     vocabulary, which is the exact bug being fixed. A sell-side LOI hangs off a
     *     Disposition__c by construction, so the lookup identifies the side with no record type
     *     at all.
     *
     * The default is ACQUISITION (neither signal present), matching
     * RecordStageAdvanceService's defaultTypeKey and correct for the same reason: every LOI in
     * the org today is buy-side by construction, because the Disposition__c lookup arrives in
     * this same tranche.
     *
     * ⚠ An unknown, NAMED record type falls through to the lookup rather than throwing — unlike
     * RecordStageAdvanceService, which refuses. The two are not inconsistent: refusing there
     * prevents writing an off-set STAGE, while refusing here would block a counter from being
     * recorded at all over a naming question, and the lookup still answers correctly.
     */
    @TestVisible
    private static Boolean isSaleSide(LOI__c parent) {
        String developerName = recordTypeDeveloperNameOf(parent);
        if (RT_DISPOSITION_LOI.equals(developerName)) {
            return true;
        }
        if (RT_ACQUISITION_LOI.equals(developerName)) {
            return false;
        }
        return parent.Disposition__c != null;
    }

    /**
     * The LOI's record type developer name, or null when it has none, sits on Master, or the
     * record type has been deleted from under the row.
     *
     * ⚠ `parent.RecordTypeId` is a DIRECT typed field read, which throws System.SObjectException
     * if the field was not SELECTED. That is intentional here and is why
     * LoiSelector.selectNegotiationContextById carries a DO-NOT-NARROW note: a loud failure beats
     * RecordStageAdvanceService's getPopulatedFieldsAsMap() approach, which cannot tell "not
     * selected" from "selected and null" and therefore degrades in silence. That class needs the
     * quiet form because it dispatches over six objects, five of whose selectors do not select the
     * field; this one has exactly one selector method and owns it.
     */
    private static String recordTypeDeveloperNameOf(LOI__c parent) {
        Id recordTypeId = parent.RecordTypeId;
        if (recordTypeId == null) {
            return null;
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
            .getRecordTypeInfosById()
            .get(recordTypeId);
        return (info == null || info.isMaster()) ? null : info.getDeveloperName();
    }

    /**
     * Resolves the supplied direction token to a role: true when the COUNTERPARTY countered,
     * false when DPEG did.
     *
     * @throws CounterOfferException naming this LOI's own valid choices when the token is not
     *         one of them. The message names the counterparty label rather than echoing the
     *         supplied value — the caller is a picker with fixed options, so a bad token means a
     *         hand-crafted call, and reflecting attacker-supplied text into a toast has no
     *         upside. Same wording policy as RecordStageAdvanceService's allow-list refusal.
     */
    private static Boolean isFromCounterparty(String direction, String counterparty) {
        if (DIRECTION_OURS == direction) {
            return false;
        }
        // The incumbent wire token, valid on both sides — see the class header's asymmetry note.
        if (COUNTERPARTY_ACQUISITION == direction) {
            return true;
        }
        // 'Buyer' names the counterparty on a sale and would name DPEG on a purchase, so it is
        // accepted only where it is unambiguous.
        if (COUNTERPARTY_DISPOSITION == direction && COUNTERPARTY_DISPOSITION == counterparty) {
            return true;
        }
        throw new CounterOfferException(
            'Pick who made this counter (' + counterparty + ' or ' + DIRECTION_OURS + ').');
    }
}
