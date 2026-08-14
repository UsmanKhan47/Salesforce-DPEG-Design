/**
 * Service for the PSA version-log write workflow.
 *
 * Owns the business logic behind PsaVersionController.saveVersion (P6 controller
 * thinning): validate the version, append a PSA_Version__c to the Contract Review's
 * version history, then derive and stamp the parent's Ball_In_Court__c (who owes the next
 * move) and Latest_Version__c. Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2,
 * this DML and these business rules are Service work, not Controller work — the controller now
 * only marshals input, delegates here, and maps failures to an AuraHandledException at the LWC
 * boundary (ARCHITECTURE.md §5).
 *
 * ── 🔴 THE COUNTERPARTY LABEL INVERTS BETWEEN A PURCHASE AND A SALE (Tranche 3C fix pass) ──
 * On an ACQUISITION, DPEG is the buyer and the counterparty is the SELLER.
 * On a DISPOSITION, DPEG is the seller and the counterparty is the BUYER.
 *
 * 'Us' / 'Ours' therefore always mean DPEG and never invert. 'Seller' does:
 *
 *                                     Acquisition_PSA        Disposition_PSA
 *   PSA_Version__c.Direction__c
 *     DPEG sent the version           'Ours'                 'Ours'
 *     the counterparty sent it        'Seller'               'Buyer'
 *   Contract_Review__c.Ball_In_Court__c
 *     it is DPEG's turn               'Us'                   'Us'
 *     it is the counterparty's turn   'Seller'               'Buyer'
 *
 * Before this change the class hardcoded 'Us' / 'Seller' and REFUSED 'Buyer' outright, so on a
 * sale logging "Our redline" wrote `Ball_In_Court__c = 'Seller'` — and on a sale DPEG *is* the
 * seller, so the field claimed the ball was with us at the exact moment it passed to the buyer.
 * The field does not read oddly, it INVERTS. `Direction__c` fails more mildly ('Seller' merely
 * READS oddly next to a buyer's draft) but the two are given IDENTICAL treatment here on purpose:
 * they are written in one transaction and read side by side (the version table and the ball badge
 * sit in the same LWC card), so labelling one counterparty two different ways would make the
 * record contradict itself.
 *
 * 🔴 AND THE METADATA ALREADY ASSUMED THIS CODE EXISTED. Three files shipped in 3C naming this
 * class as the enforcement point: objects/Contract_Review__c/recordTypes/Disposition_PSA exposes
 * Ball_In_Court__c = {Us, Buyer} ONLY, and both objects/Contract_Review__c/fields/Ball_In_Court__c
 * and objects/PSA_Version__c/fields/Direction__c state in their own descriptions that record-type
 * picklist restriction is UI-only and that "PsaVersionService is the only writer and is where that
 * is actually enforced". Repo-wide grep confirms it IS the only writer of
 * Contract_Review__c.Ball_In_Court__c.
 *
 * ── THE SHAPE IS PORTED FROM CounterOfferService, NOT INVENTED ──────────────
 * CounterOfferService solved the IDENTICAL inversion for the LOI in Tranche 3B. Everything below
 * is the same design applied to this object: one derived counterparty label; isSaleSide() with
 * record-type-then-lookup precedence and constant-first String.equals; one label driving BOTH
 * fields; the 'Ours' / 'Seller' / 'Buyer' token contract; and the property that makes it work —
 * THE LABEL IS ALWAYS DERIVED FROM THE PARENT ROW AND NEVER TAKEN FROM THE CALLER, which is what
 * makes a cross-record-type picklist write structurally impossible rather than merely discouraged.
 * (Apex DML does not enforce record-type picklist restriction, so nothing else can.)
 *
 * ⚠ ONE DELIBERATE DIFFERENCE FROM CounterOfferService, and it is a difference in the OBJECT, not
 * in the design: `Contract_Review__c` has TWO record types that share ONE stage sequence, so its
 * selector split is `selectStageRequiredById` (Negotiation_Status__c + RecordTypeId, USER_MODE,
 * for the stage action) versus `selectNegotiationContextById` (RecordTypeId + Disposition__c,
 * SYSTEM_MODE, for this class). LOI__c's split is the same two methods for the same two callers.
 * Nothing else diverges.
 *
 * ── THE `direction` ARGUMENT IS A ROLE, NOT A LABEL. ────────────────────────
 *   'Ours'    -> DPEG sent the version.       Accepted on both record types.
 *   'Seller'  -> the counterparty sent it.    Accepted on both record types.
 *   'Buyer'   -> the counterparty sent it.    Accepted on a DISPOSITION PSA ONLY.
 *
 * ⚠ THAT ASYMMETRY IS DELIBERATE AND IS NOT AN OVERSIGHT. 'Seller' is the INCUMBENT WIRE TOKEN: it
 * is what the deployed lwc/psaVersionLog picker sends ("Seller sent us a version"), and it has
 * meant "the counterparty" since the feature shipped. Refusing it on a sale would leave the
 * deployed picker with a dead Save button. 'Buyer' is NEW and has never meant anything, so it can
 * be given one unambiguous meaning without breaking a caller — and it is refused on an acquisition
 * because there 'Buyer' would name DPEG, so accepting it would be a guess about which side the
 * caller meant. Guessing on the field that decides whose turn it is is exactly the defect this
 * change fixes.
 *
 * ⚠ THE PARENT READ IS `WITH SYSTEM_MODE`, DELIBERATELY. `Contract_Review__c.Disposition__c` is a
 * NEW field in this tranche, and a Metadata-API-deployed custom field arrives with no FLS for ANY
 * profile — so a USER_MODE read would have made the LIVE ACQUISITION Log Version path depend on an
 * FLS grant for a disposition-only lookup that acquisitions users have no reason to hold. Measured
 * on the sibling field, not anticipated: a check-only run on 2026-08-09 reproduced it as
 * `System.QueryException: No such column 'Disposition__c' on entity 'LOI__c'`. The full argument
 * (and the reason sharing is NOT relaxed with it) is at
 * ContractReviewSelector.selectNegotiationContextById.
 *
 * All SOQL is delegated to ContractReviewSelector (the parent read) and PsaVersionSelector (the
 * prior-version count) — this service holds no inline SOQL. It throws a typed PsaVersionException
 * for a user-actionable rule violation (surfaced verbatim) and the raw platform DmlException on a
 * save failure; the AuraHandledException boundary lives in the controller, NOT here, so the service
 * stays UI-agnostic (also callable from Flow / Apex).
 *
 * TRANSACTIONALITY: the append + parent stamp are two DML statements with no explicit
 * Savepoint — intentionally matching the pre-thinning behaviour. A failed stamp is rolled
 * back with the appended PSA_Version__c by the platform when the controller's
 * AuraHandledException goes unhandled at the @AuraEnabled entry point.
 *
 * GOVERNOR SHAPE: 2 SOQL + 2 DML per invocation, and it was 1 SOQL + 2 DML before this change. The
 * added read is the price of deriving the label server-side; saveVersion is a
 * per-transaction-singleton @AuraEnabled operation invoked once per LWC save, so it is paid once
 * per click and never in a loop.
 *
 * ⚠ ONE ORDERING CHANGE, AND IT IS THE SAME ONE Tranche 3B MADE TO saveCounterOffer. The direction
 * used to be validated BEFORE anything was read; it is now validated AFTER the parent load, because
 * the set of valid tokens is a property of the record type and the record type is a property of the
 * row. Visible consequence: saveVersion against a NON-EXISTENT Contract Review Id and a bad
 * direction now raises System.QueryException where it previously raised PsaVersionException. Both
 * land in PsaVersionController's generic clause and produce the same fixed message, so no
 * user-visible wording changes. The null-contractReviewId guard deliberately stays FIRST — it is
 * the one refusal that needs no row.
 *
 * ⚠ The acquisition-side refusal wording is BYTE-IDENTICAL to the pre-change message
 * ('Pick who sent this version (Seller or Ours).'). Only a disposition PSA says 'Buyer'.
 *
 * @see force-app/main/default/classes/PsaVersionController.cls (thin caller)
 * @see force-app/main/default/classes/ContractReviewSelector.cls (selectNegotiationContextById)
 * @see force-app/main/default/classes/PsaVersionSelector.cls (the prior-version count)
 * @see force-app/main/default/classes/CounterOfferService.cls (the LOI half of this same
 *      inversion — the design this class ports)
 */
public with sharing class PsaVersionService {

    /**
     * Raised for a user-actionable business-rule violation whose message is user-safe
     * and surfaced verbatim to the LWC: no Contract Review linked, or a version direction
     * that is not valid for this Contract Review's side of the deal. Distinct from an unexpected
     * platform DmlException, which the controller maps to a fixed generic message instead.
     */
    public class PsaVersionException extends Exception {}

    /**
     * Contract_Review__c record type developer names (Tranche 3C). Case must match
     * objects/Contract_Review__c/recordTypes/ exactly — getRecordTypeInfosById() reports the
     * metadata casing and the describe maps are keyed case-SENSITIVELY.
     */
    @TestVisible
    private static final String RT_ACQUISITION_PSA = 'Acquisition_PSA';
    @TestVisible
    private static final String RT_DISPOSITION_PSA = 'Disposition_PSA';

    /** The DPEG side. Never inverts, so it is one constant for both record types. */
    private static final String DIRECTION_OURS = 'Ours';
    private static final String BALL_US = 'Us';

    /** The counterparty, named from DPEG's side of THIS deal. These are what invert. */
    private static final String COUNTERPARTY_ACQUISITION = 'Seller';
    private static final String COUNTERPARTY_DISPOSITION = 'Buyer';

    /**
     * Records one PSA version against a Contract Review and reflects it on the parent.
     *
     * @param contractReviewId the parent Contract_Review__c (required)
     * @param direction        who sent the version — see the class header's token table:
     *                         'Ours' (DPEG) or 'Seller' (the counterparty) on either record type,
     *                         or 'Buyer' (the counterparty) on a disposition PSA only
     * @param versionDate      the version date; defaults to today when null
     * @param summary          the version summary/notes
     * @param documentUrl      link to the PSA document
     * @throws PsaVersionException when contractReviewId is null, or direction is not a token valid
     *         for this Contract Review's record type
     * @throws System.QueryException when contractReviewId matches no Contract Review
     * @throws System.DmlException on a platform save failure
     */
    public static void saveVersion(Id contractReviewId, String direction, Date versionDate,
            String summary, String documentUrl) {
        if (contractReviewId == null) {
            throw new PsaVersionException('No Contract Review is linked to this deal yet.');
        }
        // FETCH-FOR-USE. The labels written below are a function of this row and of nothing the
        // caller supplied; reading it is the whole mechanism.
        Contract_Review__c parent =
            ContractReviewSelector.selectNegotiationContextById(contractReviewId);
        String counterparty = isSaleSide(parent)
            ? COUNTERPARTY_DISPOSITION
            : COUNTERPARTY_ACQUISITION;
        Boolean fromCounterparty = isFromCounterparty(direction, counterparty);

        Integer priorCount = PsaVersionSelector.countByContractReviewId(contractReviewId);

        insert new PSA_Version__c(
            Contract_Review__c = contractReviewId,
            // ⚠ The stored value is the DERIVED label, never the caller's token. A caller sending
            // 'Seller' on a sale gets 'Buyer' stored, which is the correction this change exists
            // to make.
            Direction__c = fromCounterparty ? counterparty : DIRECTION_OURS,
            Version_Date__c = (versionDate == null) ? Date.today() : versionDate,
            Summary__c = summary,
            Document_URL__c = documentUrl
        );

        // 🔴 THIS METHOD NO LONGER TOUCHES Negotiation_Status__c (2026-08-05, user decision).
        // It used to derive it: first seller version -> 'Initial Draft', every later version ->
        // 'Seller Counter' / 'Buyer Counter'. Those two counter values were REMOVED from the
        // restricted picklist, so writing either would now throw
        // INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and fail the Log Version button outright.
        //
        // The status is now moved ONLY by the deal driver, through the Advance Stage quick action
        // (RecordStageAdvanceService: Initial Draft -> Revised -> Ready for Execution -> Executed).
        // Logging a version is a RECORD of an exchange, not a state transition — a distinction the
        // old code collapsed, which is why every redline silently re-drove the parent's status and
        // the Path could jump backwards while the deal driver was mid-negotiation.
        //
        // Ball_In_Court__c IS still stamped here, deliberately: it is the log's own output (who owes
        // the next move) and nothing else derives it. Direction therefore survives the change —
        // between Ball In Court and the PSA_Version__c rows, who countered and when is fully
        // recoverable without a counter STATUS.
        update new Contract_Review__c(
            Id = contractReviewId,
            // A counterparty version puts the ball in OUR court, ours in theirs. 'Us' never
            // inverts; the counterparty token does.
            Ball_In_Court__c = fromCounterparty ? BALL_US : counterparty,
            Latest_Version__c = priorCount + 1
        );
    }

    /**
     * Whether this Contract Review is on the SELL side, i.e. whether the counterparty is the buyer.
     *
     * AUTHORITATIVE FIRST, FALLBACK SECOND — the two clauses answer different questions and the
     * order matters:
     *
     *  1. THE RECORD TYPE IS AUTHORITATIVE. A row explicitly on Acquisition_PSA is buy-side even if
     *     someone populated Disposition__c by mistake, and the reverse. Comparing with
     *     constant-first String.equals is REQUIRED, not stylistic: Apex `==` on String is
     *     case-INSENSITIVE while getRecordTypeInfosById() reports the metadata casing, so `==`
     *     would silently accept a mis-cased developer name that the describe map never produced —
     *     the identical trap TestDataFactory.contractReviewRecordTypeId documents at length.
     *  2. THE Disposition__c LOOKUP IS THE FALLBACK, and it is load-bearing rather than defensive.
     *     Until post-deploy gates T-A1/T-B run, every Contract Review in the org sits on the MASTER
     *     record type (or has no RecordTypeId at all), so clause 1 yields nothing — and a
     *     disposition PSA created in that window would otherwise be labelled with buy-side
     *     vocabulary, which is the exact bug being fixed. A sell-side PSA hangs off a
     *     Disposition__c by construction, so the lookup identifies the side with no record type
     *     at all.
     *
     * 🔴 CLAUSE 2 IS LOAD-BEARING, BUT NOT FOR THE REASON THIS BLOCK USED TO GIVE. ⚠ RETRACTED
     * 2026-08-14 (observation 7 / review C9), verbatim: "THE FALLBACK MATTERS MORE ON THIS OBJECT
     * THAN IT DID ON LOI__c ... A mis-typed or Master-type disposition LOI is at least visible — the
     * two LOI stage value sets are disjoint, so the row's own stage looks wrong. Both PSA record
     * types expose the IDENTICAL four Negotiation_Status__c values, so a Master-type disposition PSA
     * walks its path PERFECTLY and is wrong only about vocabulary. Without clause 2 that would be
     * silent." The CONCLUSION survives — clause 2 stays — but the symptom is now the OPPOSITE of
     * what that read, so it is corrected rather than softened.
     *
     * Observation 7 split the two PSA sequences (acquisition `Draft -> Negotiation -> Signed ->
     * Executed`; disposition `Initial Draft -> Revised -> Ready for Execution -> Executed`, sharing
     * only the terminal 'Executed'). A Master-type disposition PSA therefore does NOT walk its path
     * perfectly any more: it falls to RecordStageAdvanceService's acquisition default, finds no
     * entry for 'Initial Draft', and is REFUSED LOUDLY on its first Advance Stage click. The
     * comparison with LOI__c collapses too — observation 5 gave the two LOI sets a shared value
     * ('Under Review'), while their STARTING values still differ, so a Master-type disposition LOI
     * parked on 'Received' is refused by the acquisition map in exactly the same way. Neither object
     * is the quiet one now.
     *
     * ⚠ WHAT IS STILL SILENT IS THIS CLASS'S OWN PATH, WHICH IS WHY CLAUSE 2 DOES NOT MOVE. That
     * refusal happens in a DIFFERENT class on a DIFFERENT action; logging a version refuses nothing.
     * Without clause 2 a Master-type disposition PSA would take buy-side vocabulary into
     * Ball_In_Court__c with no error anywhere — the original defect, unchanged. The split only
     * shortens the window in which it goes unnoticed, because the row now announces itself the first
     * time anyone clicks Advance Stage on it.
     *
     * The default is ACQUISITION (neither signal present), matching CounterOfferService.isSaleSide
     * and RecordStageAdvanceService's defaultTypeKey, and correct for the same reason: every
     * Contract Review in the org today is buy-side by construction, because the Disposition__c
     * lookup arrives in this same tranche.
     *
     * ⚠ An unknown, NAMED record type falls through to the lookup rather than throwing — unlike
     * RecordStageAdvanceService, which refuses. The two are not inconsistent: refusing there
     * prevents writing an off-set STAGE, while refusing here would block a version from being
     * recorded at all over a naming question, and the lookup still answers correctly.
     */
    @TestVisible
    private static Boolean isSaleSide(Contract_Review__c parent) {
        String developerName = recordTypeDeveloperNameOf(parent);
        if (RT_DISPOSITION_PSA.equals(developerName)) {
            return true;
        }
        if (RT_ACQUISITION_PSA.equals(developerName)) {
            return false;
        }
        return parent.Disposition__c != null;
    }

    /**
     * The Contract Review's record type developer name, or null when it has none, sits on Master,
     * or the record type has been deleted from under the row.
     *
     * ⚠ `parent.RecordTypeId` is a DIRECT typed field read, which throws System.SObjectException
     * if the field was not SELECTED. That is intentional here and is why
     * ContractReviewSelector.selectNegotiationContextById carries a DO-NOT-NARROW note: a loud
     * failure beats RecordStageAdvanceService's getPopulatedFieldsAsMap() approach, which cannot
     * tell "not selected" from "selected and null" and therefore degrades in silence. That class
     * needs the quiet form because it dispatches over six objects, five of whose selectors do not
     * select the field; this one has exactly one selector method and owns it.
     */
    private static String recordTypeDeveloperNameOf(Contract_Review__c parent) {
        Id recordTypeId = parent.RecordTypeId;
        if (recordTypeId == null) {
            return null;
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosById()
            .get(recordTypeId);
        return (info == null || info.isMaster()) ? null : info.getDeveloperName();
    }

    /**
     * Resolves the supplied direction token to a role: true when the COUNTERPARTY sent the version,
     * false when DPEG did.
     *
     * @throws PsaVersionException naming this Contract Review's own valid choices when the token is
     *         not one of them. The message names the counterparty label rather than echoing the
     *         supplied value — the caller is a picker with fixed options, so a bad token means a
     *         hand-crafted call, and reflecting attacker-supplied text into a toast has no upside.
     *         Same wording policy as CounterOfferService and RecordStageAdvanceService.
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
        throw new PsaVersionException(
            'Pick who sent this version (' + counterparty + ' or ' + DIRECTION_OURS + ').');
    }
}
