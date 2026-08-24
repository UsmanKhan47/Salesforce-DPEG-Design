import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import STAGE_FIELD from '@salesforce/schema/Disposition__c.Disposition_Stage__c';
import RECORD_TYPE_FIELD from '@salesforce/schema/Disposition__c.RecordType.DeveloperName';

/**
 * The picklist value, named ONCE (2026-08-24).
 *
 * ⚠ IT IS READ BY TWO GETTERS — `isOfferStage` (does the card render at all?) and
 * `isOfferSelection` (which MODE does it render in?). A second literal would let the two drift
 * apart, and the failure mode of that drift is silent in both directions: the mode flag set at a
 * stage the card does not render at does nothing at all, and the card rendering at Offer Selection
 * without the flag is simply the OLD behaviour, which looks entirely normal.
 *
 * ⚠ EXACT MATCH ON THE PICKLIST'S OWN API VALUE — a space, not an underscore, and title case. It
 * is a value of `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` and exists on
 * BOTH record types.
 */
const STAGE_OFFER_SELECTION = 'Offer Selection';

/**
 * The two path-specific offer-ARRIVAL stages, named once for the same reason as above.
 *
 * 🔴 `Release Materials` EXISTS ON BOTH RECORD TYPES BUT ONLY MEANS "offers arrive here" ON ONE OF
 * THEM. See `isOfferStage`: this constant is used WITH a record-type test and
 * `STAGE_ACTIVE_LISTING` WITHOUT one. The asymmetry is deliberate and verified — do not "tidy"
 * the two into one list.
 */
const STAGE_RELEASE_MATERIALS = 'Release Materials';
const STAGE_ACTIVE_LISTING = 'Active Listing';

/**
 * The On-Market record type's DEVELOPER NAME — `objects/Disposition__c/recordTypes/On_Market.
 * recordType-meta.xml`, `<fullName>On_Market</fullName>`.
 *
 * 🔴 THE DEVELOPER NAME. NOT THE LABEL, AND NOT THE ID.
 *   · The LABEL is "On Market" (a space). It is renameable in Setup by any admin, with no code
 *     change and no deploy, which would silently switch this guard off. MEASURED against the live
 *     org 2026-08-25: `getRecord`'s FREE `data.recordTypeInfo.name` returns "On Market" — the
 *     LABEL, not "On_Market". That zero-cost read is the brittle one, and it was not used.
 *   · The ID (`012iw0000009yeWAAQ` in usman-dpeg) is org-specific; hardcoding one is banned.
 */
const RECORD_TYPE_ON_MARKET = 'On_Market';

export default class DispositionSidebar extends LightningElement {
    @api recordId;
    _stage;
    _recordType;
    _error;

    /**
     * ONE wire, two fields. The record type joins the stage on the wire this component already
     * had — no second wire, no `getObjectInfo`, no Apex call for one field.
     *
     * ⚠ THE RECORD TYPE IS AN **optionalField** AND THE STAGE IS NOT — THAT IS THE FAIL-SAFE
     * DIRECTION, NOT AN OVERSIGHT. A field listed in `fields` that the running user cannot read
     * puts the WHOLE wire into its error branch, replacing every stage's sidebar with the error
     * banner. In `optionalFields` an unreadable value simply comes back undefined, `isOnMarket` is
     * then false, and `isOfferStage` degrades to exactly the behaviour that shipped before this
     * change (the card renders at Release Materials) rather than to a blank sidebar on the
     * OFF-market path — where that card is the only way to see the offers that arrive there.
     * Showing a card one stage early is a lesser failure than removing a working surface.
     * ⚠ SPANNING FIELD. `RecordType.DeveloperName` was verified against the live org's UI API on
     * 2026-08-25: the payload nests as
     * `fields.RecordType.value.fields.DeveloperName.value === 'On_Market'`. The Jest fixtures
     * mirror that nesting exactly — a flatter invented fixture would green a read that returns
     * `undefined` in production.
     */
    @wire(getRecord, {
        recordId: '$recordId',
        fields: [STAGE_FIELD],
        optionalFields: [RECORD_TYPE_FIELD]
    })
    wiredRecord({ data, error }) {
        if (data) {
            this._stage = getFieldValue(data, STAGE_FIELD);
            this._recordType = getFieldValue(data, RECORD_TYPE_FIELD);
            this._error = undefined;
        } else if (error) {
            this._error = error;
            this._stage = undefined;
            this._recordType = undefined;
        }
    }

    get hasError() { return !!this._error; }
    get errorMessage() {
        return (this._error && this._error.body && this._error.body.message) || 'Unknown error';
    }

    get isBovOutreach()   { return this._stage === 'BOV Outreach'; }
    get isClosing()       { return this._stage === 'Closing'; }

    /**
     * True only when the record type is POSITIVELY KNOWN to be On-Market.
     *
     * ⚠ STATED AS A POSITIVE, AND THE CALLER NEGATES IT RATHER THAN TESTING FOR 'Off_Market'.
     * `undefined` — before the wire answers, or if the optional field is unreadable — must not be
     * mistaken for either path, and of the two possible defaults "not On-Market" is the one that
     * keeps the off-market offer card on screen. See the wire's comment for why that is the side
     * to fail towards.
     */
    get isOnMarket() {
        return this._recordType === RECORD_TYPE_ON_MARKET;
    }

    /**
     * Stages at which the sidebar shows the disposition-offer card.
     *
     * ── 🔴 THE "DISJOINT VALUE SETS" ARGUMENT IS DEAD. DO NOT QUOTE IT. ──────
     * This block used to justify the absence of a record-type check like this:
     *
     *     "The two record types' stage value sets are DISJOINT for every path-specific
     *      stage: 'Call for Offers' exists only on On_Market and 'Disposition Offer' only
     *      on Off_Market, so the stage alone identifies the path."
     *
     * Both of the values that argument rested on were RETIRED by the disposition flow
     * redesign, and the premise itself is now false in the opposite direction: 'Broker
     * Selection', 'Release Materials', 'Offer Selection' and 'Sale Closes' are all on BOTH
     * record types. THE STAGE VALUE NO LONGER IDENTIFIES THE PATH.
     *
     * ── 🔴 AND ITS REPLACEMENT IS DEAD TOO (2026-08-25). ─────────────────────
     * The second argument said there was STILL no record-type check because "the four stages
     * below all render the SAME card with the SAME meaning on both paths". THAT WAS FALSE FOR
     * EXACTLY ONE OF THEM, and the very next paragraph of this comment said so without noticing:
     * *"'Active Listing' (On) and 'Release Materials' (Off) are where offers ARRIVE"* — one stage
     * per path. But `Release Materials` is on BOTH record types and the list was not scoped, so
     * an ON-MARKET sale showed the offers card at a stage where, on that path, the asset has not
     * been listed yet and no offer can have arrived. CONFIRMED LIVE: DISP-0023 is On_Market, sits
     * at Release Materials, and was showing the card.
     *
     * ── WHY EACH STAGE IS IN THE LIST, AND WHICH ONE IS SCOPED ───────────────
     * `Release Materials` — OFF-MARKET ONLY, and the one line of this getter that needed a record
     * type. Off-market, the materials go straight to a shortlist and the responses that come back
     * (see `c/releaseMaterialsResponseLog`) are where offers first appear. On the on-market path
     * this stage merely PRECEDES `Active Listing`, which is the listing itself.
     *
     * `Active Listing` — ON-MARKET ONLY, AND DELIBERATELY CARRIES NO RECORD-TYPE TEST. It is not
     * a value of the Off_Market record type's `Disposition_Stage__c` value set at all
     * (`objects/Disposition__c/recordTypes/Off_Market.recordType-meta.xml` — checked), the field
     * is `<restricted>true</restricted>`, and record-type value-set scoping is enforced by DML in
     * this org rather than only in the UI. An off-market disposition therefore cannot hold this
     * value, so `&& isOnMarket` here would be a condition that can never be false: dead code that
     * reads like a safety net and whose test would stay green if it were deleted. Verified
     * empirically as well — no Disposition__c row in the org holds 'Active Listing' off-market.
     *
     * `Offer Selection` — BOTH PATHS. An offer has been put forward and is sitting in
     * `Offer_Selection_Approval`; the stage is reached from either path and means the same thing
     * on both. The card is arguably most useful here, because a rejected offer parks the
     * disposition at this stage for a RE-PICK and the user needs the side-by-side list again.
     *
     * ⚠ 'LOI' — BOTH PATHS, AND INCLUDED FOR A DIFFERENT REASON THAN IT USED TO BE (corrected at
     * the Tranche 3B close-out, 2026-08-09). This comment previously said the negotiation "is
     * still recorded on Disposition_Offer__c's counter fields". THAT IS NO LONGER TRUE and must
     * not be quoted: decision D6 moved the sell-side negotiation onto LOI__c's Disposition_LOI
     * record type, where each round is a Counter_Offer__c shown by lwc/loiCounterOffer on the LOI
     * record page. Disposition_Offer__c is now CAPTURE AND COMPARISON ONLY. The stage stays in
     * this list anyway, and deliberately: at 'LOI' a disposition user still needs to see WHICH
     * offer the LOI came from. Read it as "the offers are still relevant here", not as "the
     * negotiation happens here".
     *
     * 'PSA' is excluded because at that stage the only marker is PSA_Executed__c on the
     * Disposition itself and the record page falls back to the Details section. Neither
     * stage gets a placeholder component (Gate 1 Q5).
     */
    get isOfferStage() {
        if (this._stage === STAGE_RELEASE_MATERIALS) {
            return !this.isOnMarket;
        }
        return (
            this._stage === STAGE_ACTIVE_LISTING ||
            this._stage === STAGE_OFFER_SELECTION ||
            this._stage === 'LOI'
        );
    }

    /**
     * Whether the offers card renders in its SELECTED-ONLY mode (2026-08-24, user request:
     * "at Offer Selection show only the offer going for approval, and disable Log Offer").
     *
     * 🔴 THE DECISION LIVES HERE, NOT IN THE CARD AND NOT ON THE SERVER. This component already
     * holds the stage — it is the only reason it exists — so the card is told the answer instead
     * of working it out. Putting the test inside `c/disposition-offer` would give an offers card
     * its own stage wire and a second, drift-prone copy of the stage list; putting it in Apex
     * would mean inventing a controller for a card that has none, purely to express a rendering
     * choice, and a related-list read whose contents depend on a picklist value. See that
     * component's class header for the full argument.
     *
     * ⚠ THIS IS A NARROWING OF `isOfferStage`, NOT A PARALLEL LIST, AND THE 2026-08-25 RECORD-TYPE
     * WORK LEFT THAT INTACT: the stage it narrows to, 'Offer Selection', is on BOTH record types
     * and is the one offer stage that was NOT scoped, so this getter's answer is unchanged on both
     * paths.
     * 🔴 AND IT IS STILL A BARE COMPARISON, NOT `isOfferStage && …`. That guard was written,
     * measured and REMOVED: with 'Offer Selection' unscoped, `isOfferStage` is true wherever the
     * right-hand side is, so the `&&` is a condition that can never be false — the same dead-code
     * test that keeps a record-type check off 'Active Listing' above, and mutation-testing
     * confirmed it: deleting the `&&` reddened nothing. What DOES protect the narrowing is a
     * falsifier rather than an unfalsifiable line of code: the sweep test
     * *"NARROWING: selected-only is true for EXACTLY Offer Selection, on both paths, and nowhere
     * else"* walks the whole stage × record-type grid, derived from the record types' own value
     * sets, and reds the moment either getter moves without the other. Scope 'Offer Selection'
     * itself one day and that test — not a silent `&&` — is what will tell you.
     *
     * ⚠ THE VALUE IS BOUND AS A BOOLEAN INTO `selected-only={isOfferSelection}`, so it is `false`
     * — not `undefined` — at the other three offer stages and before the wire emits. The child
     * reads `=== true`, so a stray `undefined` would take the same (correct) branch, but a real
     * boolean is what the Jest assertions can pin with `toBe(false)`.
     */
    get isOfferSelection() {
        return this._stage === STAGE_OFFER_SELECTION;
    }
}
