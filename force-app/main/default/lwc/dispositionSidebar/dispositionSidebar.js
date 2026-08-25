import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import STAGE_FIELD from '@salesforce/schema/Disposition__c.Disposition_Stage__c';
import RECORD_TYPE_FIELD from '@salesforce/schema/Disposition__c.RecordType.DeveloperName';

/**
 * ── THE STAGE LITERALS, NAMED ONCE (2026-08-24; EXTENDED 2026-08-25) ────────────────────────────
 *
 * Every stage value this component tests against is named here and nowhere else. Two getters read
 * them — `isOfferStage` (does the offers card render at all?) and `isSelectedOfferOnlyStage`
 * (which MODE does it render in?) — and a second literal would let the two drift apart. The
 * failure mode of that drift is silent in both directions: the mode flag set at a stage the card
 * does not render at does nothing at all, and a selected-only stage that loses the flag simply
 * lists every offer with "+ Log Offer" back on it, which looks entirely normal.
 *
 * ⚠ EXACT MATCH ON EACH PICKLIST'S OWN API VALUE — spaces, not underscores, and title case. All of
 * them are values of `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml`.
 */
const STAGE_OFFER_SELECTION = 'Offer Selection';
const STAGE_LOI = 'LOI';
const STAGE_PSA = 'PSA';
const STAGE_CLOSING = 'Closing';
const STAGE_ACTIVE_LISTING = 'Active Listing';

/**
 * 🔴 `Release Materials` EXISTS ON BOTH RECORD TYPES BUT ONLY MEANS "offers arrive here" ON ONE OF
 * THEM, which is why it is deliberately NOT a member of `OFFER_STAGES` below: it is the one stage
 * tested WITH a record type, in its own branch of `isOfferStage`. `STAGE_ACTIVE_LISTING` is tested
 * WITHOUT one. The asymmetry is verified — do not "tidy" the two into one list.
 */
const STAGE_RELEASE_MATERIALS = 'Release Materials';

/**
 * ── THE SUBSET INVARIANT, ENFORCED BY CONSTRUCTION (2026-08-25) ─────────────────────────────────
 *
 * `SELECTED_OFFER_ONLY_STAGES` is the set of stages at which the card shows ONLY the selected
 * offer. `OFFER_STAGES` — the record-type-UNSCOPED stages at which the card renders at all — is
 * BUILT FROM it by spreading it.
 *
 * 🔴 THAT SPREAD *IS* THE ENFORCEMENT, AND IT IS STRUCTURAL RATHER THAN A TEST OR A RUNTIME GUARD.
 * There is exactly ONE array literal for the selected-only stages, and the render set is derived
 * from it, so a stage cannot enter the narrower set without simultaneously entering the wider one.
 * "A NARROWING OF `isOfferStage`, NOT A PARALLEL LIST" is therefore now true BY CONSTRUCTION —
 * previously it was true only by convention, held by a sweep test, over a single hard-coded value.
 * Do not re-spell `OFFER_STAGES` as its own flat literal: that is the one edit that would restore
 * the drift this block exists to prevent, and nothing on screen would show it.
 *
 * ⚠ THE TWO STAGES OUTSIDE THE NARROWING ARE THE "offers ARRIVE here" ONES — `Active Listing`
 * (on-market) and `Release Materials` (off-market). They list every offer with "+ Log Offer"
 * available, so `Active Listing` is added to `OFFER_STAGES` on top of the spread, and
 * `Release Materials` is not in the array at all because it is record-type-scoped.
 *
 * ⚠ ALL FOUR SELECTED-ONLY STAGES ARE ON BOTH RECORD TYPES — VERIFIED LIVE 2026-08-25 against the
 * org's UI API picklist-values endpoint for BOTH record type Ids (`012iw0000009yeWAAQ` On_Market,
 * `012iw0000009yeVAAQ` Off_Market): 'Offer Selection', 'LOI', 'PSA' and 'Closing' are active on
 * both. None of them therefore needs the record-type test that `Release Materials` needs. The
 * repo's `recordTypes/*.recordType-meta.xml` agrees — but a record type's value set can drift from
 * the repo file silently, and only the UI API reads the truth back, so the endpoint is the source
 * cited here.
 */
const SELECTED_OFFER_ONLY_STAGES = Object.freeze([
    STAGE_OFFER_SELECTION,
    STAGE_LOI,
    STAGE_PSA,
    STAGE_CLOSING
]);
const OFFER_STAGES = Object.freeze([STAGE_ACTIVE_LISTING, ...SELECTED_OFFER_ONLY_STAGES]);

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
    /**
     * ⚠ 'Closing' IS NOW ALSO AN OFFER STAGE (2026-08-25), so this getter and `isOfferStage` are
     * both true there and the sidebar renders TWO cards: the closing card, plus the offers card in
     * its selected-only mode showing which offer the sale is closing on. That is the requested
     * behaviour, not a double-render bug — the two `<template>` branches in the HTML are
     * independent and were never mutually exclusive.
     */
    get isClosing()       { return this._stage === STAGE_CLOSING; }

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
     * negotiation happens here". That reason — WHICH offer, not WHICH OF the offers — is exactly
     * why 'LOI' became selected-only on 2026-08-25 rather than continuing to list them all.
     *
     * ── 🔴 "'PSA' IS EXCLUDED" IS RETRACTED (2026-08-25). DO NOT QUOTE IT. ───
     * This block used to end: *"'PSA' is excluded because at that stage the only marker is
     * PSA_Executed__c on the Disposition itself and the record page falls back to the Details
     * section."* That was an argument about there being nothing to SHOW at PSA, and it was
     * answered by the user directly: what there is to show at PSA — and at Closing — is WHICH
     * OFFER the deal is on. Both stages are now in the list, and both are selected-only.
     *
     * `PSA` and `Closing` — BOTH PATHS, SELECTED-ONLY. By these stages the pick is made and the
     * side-by-side comparison is over; showing the losing offers again would invite a re-pick that
     * the executed PSA has foreclosed. The card therefore renders in the same mode as at Offer
     * Selection: one offer, and no "+ Log Offer". At `Closing` this sits ALONGSIDE
     * `c-disposition-closing` — see `isClosing`.
     */
    get isOfferStage() {
        if (this._stage === STAGE_RELEASE_MATERIALS) {
            return !this.isOnMarket;
        }
        return OFFER_STAGES.includes(this._stage);
    }

    /**
     * Whether the offers card renders in its SELECTED-ONLY mode.
     *
     * ── 🔴 "OFFER SELECTION IS THE ONLY SELECTED-ONLY STAGE" IS RETRACTED (2026-08-25) ──────
     * The original request (2026-08-24) was *"at Offer Selection show only the offer going for
     * approval, and hide Log Offer"*, and this getter was named `isOfferSelection` after the single
     * stage it tested. The user has since extended the mode to 'LOI', 'PSA' and 'Closing' — on
     * every stage from the pick onwards, the question is WHICH offer, not WHICH OF the offers.
     * Every sentence in this file that reasoned from "the one selected-only stage", "the other
     * three offer stages" or "a bare comparison" is retracted in place; do not quote them from an
     * older revision.
     *
     * 🔴 AND THE GETTER WAS RENAMED WITH IT. `isOfferSelection` returning true at Closing would be
     * a lie that reads as a stage test, and the next reader would act on it — the rename is the
     * point, not tidying.
     *
     * 🔴 THE DECISION LIVES HERE, NOT IN THE CARD AND NOT ON THE SERVER. This component already
     * holds the stage — it is the only reason it exists — so the card is told the answer instead
     * of working it out. Putting the test inside `c/disposition-offer` would give an offers card
     * its own stage wire and a second, drift-prone copy of the stage list; putting it in Apex
     * would mean inventing a controller for a card that has none, purely to express a rendering
     * choice, and a related-list read whose contents depend on a picklist value. See that
     * component's class header for the full argument.
     *
     * ⚠ THIS IS STILL A NARROWING OF `isOfferStage`, NOT A PARALLEL LIST — AND THE RELATIONSHIP IS
     * NOW HELD BY THE CODE ITSELF. It reads the SAME `SELECTED_OFFER_ONLY_STAGES` array that
     * `OFFER_STAGES` is spread from, so the four stages below are members of the render set by
     * construction; there is no second list to keep in step. See that constant's block for why the
     * spread is the enforcement mechanism. All four are on BOTH record types (verified live), so
     * the answer is identical on the on- and off-market paths.
     *
     * 🔴 AND IT IS STILL NOT `isOfferStage && …`. That guard was written, measured and REMOVED at
     * the previous revision, and the reasoning survives the extension unchanged: every member of
     * `SELECTED_OFFER_ONLY_STAGES` is a member of `OFFER_STAGES`, and none of them is the
     * record-type-scoped `Release Materials`, so `isOfferStage` is true wherever the right-hand
     * side is. The `&&` would be a condition that can never be false — dead code that reads like a
     * safety net, the same test that keeps a record-type check off 'Active Listing' above, and
     * mutation-testing confirmed it: deleting it reddened nothing. The subset property is now
     * guaranteed one level up, by the spread, instead of being re-asserted here at runtime.
     *
     * ⚠ THE JEST SWEEP TEST NAMED IN THE PREVIOUS REVISION IS NOW WRONG BY ITS OWN TITLE:
     * *"NARROWING: selected-only is true for EXACTLY Offer Selection, on both paths, and nowhere
     * else"* walks the whole stage × record-type grid and will red on 'LOI', 'PSA' and 'Closing'.
     * Its expected set must become the four stages above. That sweep is still the falsifier of
     * record — keep it, do not delete it, and keep it derived from the record types' own value
     * sets so a new stage arrives in the grid automatically.
     *
     * ⚠ `Array.prototype.includes` RETURNS A REAL BOOLEAN, INCLUDING FOR `undefined` BEFORE THE
     * WIRE EMITS, so the value bound into `selected-only={isSelectedOfferOnlyStage}` is `false`
     * — not `undefined` — at 'Active Listing' and 'Release Materials'. The child reads `=== true`,
     * so a stray `undefined` would take the same (correct) branch, but a real boolean is what the
     * Jest assertions can pin with `toBe(false)`.
     */
    get isSelectedOfferOnlyStage() {
        return SELECTED_OFFER_ONLY_STAGES.includes(this._stage);
    }
}
