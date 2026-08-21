/**
 * c-disposition-buyer-timeline
 * ---------------------------------------------------------------------------
 * The buyer activity timeline on the Disposition record page: one row per
 * buyer-role NDA, showing the three dates of the buyer journey
 * (NDA signed -> materials released -> first offer) and the two durations
 * between them. Tranche 2 Workstream D
 * (agent-output/disposition-tranche-2-requirements.md §3 D6.3).
 *
 * ==========================================================================
 * 🔴 🔴 THIS COMPONENT MUST NOT READ `NDA_Signed__c`. IT DOES NOT. DO NOT ADD IT.
 * ==========================================================================
 * That checkbox LATCHES: it is only ever cleared on `Declined`, it stays true
 * through `Sent`, and it stayed true forever for any counterparty who walked
 * away before Workstream A3 landed. Rendering it would show a SIGNED NDA FOR A
 * COUNTERPARTY WHO REFUSED — beside the NDAs related list on this same page,
 * which would say `Declined`.
 *
 * ⚠ And `Date_Signed__c` alone is not sufficient either — the sharper half of
 * the same trap. The before-save flow `NDA_Signed_Status_Sync` NEVER CLEARS
 * `Date_Signed__c`, by explicit design, so a `Signed -> Declined` party keeps a
 * non-null date forever. THE GATE IS `Status__c = 'Signed'`; the date is only
 * the value shown once that gate passes.
 *
 * 🔴 Neither field is decided HERE. `DispositionBuyerTimelineService` applies
 * the gate server-side and a declined party's retained date NEVER CROSSES THE
 * `@AuraEnabled` BOUNDARY — there is no `rawStatus`/`isSigned` field on the DTO
 * to reach for. That is deliberate: no template change in this file can leak it.
 *
 * ── DECLINED PARTIES ─────────────────────────────────────────────────────
 * Included, never hidden — they are audit evidence (`NDA__c.allowDelete` is
 * false by decision D20), and hiding them would make this card disagree with
 * the NDAs related list on the same page. Rendered as a visually distinct
 * TERMINATED row: the buyer name, a `Declined` badge, and em-dashes in all
 * three date columns and both duration columns. Sorted LAST.
 *
 * ⚠ ACCESSIBILITY: the `Declined` state is carried as READABLE TEXT inside the
 * badge, not by colour alone, and each terminated row's group carries an
 * `aria-label` naming the buyer and the state. A coloured pill on its own is
 * not an accessible state, and this repo has a measured incident of a
 * text->badge swap deleting accessible content a test had pinned. The Jest
 * suite asserts on the rendered TEXT, so that regression fails loudly here.
 *
 * ── ORDERING IS THE SERVER'S ─────────────────────────────────────────────
 * This component DOES NOT SORT. `DispositionBuyerTimelineService.getTimeline`
 * returns active parties first (in NDA creation order — it is a timeline) and
 * declined parties last, and that ordering is a statement about the data, not a
 * presentation preference. Re-sorting here would let the two disagree. (This
 * deliberately differs from `c/brokerAssignmentHistory`, which sorts in JS.)
 *
 * ── DATA ACCESS ──────────────────────────────────────────────────────────
 * Imperative-free: a single `@wire(getTimeline, { dispositionId: '$recordId' })`.
 * Apex rather than LDS/GraphQL because the payload is a cross-object
 * computation — NDAs joined to their earliest matching offer, with a status
 * gate and two derived durations — which no wire adapter can express
 * (ARCHITECTURE.md §5, "Imperative Apex only when LDS cannot express the
 * query"). The controller is a thin wrapper over the service.
 *
 * ── ERROR BRANCH ─────────────────────────────────────────────────────────
 * The controller throws `AuraHandledException` rather than returning an empty
 * list, because an empty timeline on a sale with three engaged buyers is a
 * confident wrong answer nothing on the page contradicts. This component
 * therefore renders a visible inline alert — never a silent blank.
 *
 * ⚠ AMENDED 2026-08-21. This paragraph used to end "...and NO card". That was
 * literally true of the old markup, which had no card chrome at all and emitted
 * a bare <div> per branch. The card chrome is now UNCONDITIONAL and the alert
 * renders inside it. The requirement the sentence was protecting is unchanged
 * and is still pinned by the tests: on the error branch there are NO TILES and
 * NO EMPTY STATE. What has changed is that the failing panel now says which
 * panel it is.
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 🔴 DESIGNED FOR A ~340px SIDEBAR COLUMN. DO NOT REINTRODUCE COLUMNS.
 * ══════════════════════════════════════════════════════════════════════════
 * The rendered unit is a self-labelling TILE, not a row in a shared grid — see
 * the long note in the template. The five values below are still produced in
 * the same order and still flattened to em-dashes in exactly the same cases;
 * only their arrangement changed. The three "step class" getters added below
 * drive a decorative milestone rail and carry NO information that is not
 * already in the value cell beside them.
 */
import { LightningElement, api, wire } from 'lwc';
import getTimeline from '@salesforce/apex/DispositionBuyerTimelineController.getTimeline';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Rendered wherever a date or a duration cannot be stated truthfully. */
const EM_DASH = '—';

export default class DispositionBuyerTimeline extends LightningElement {
    @api recordId;

    rows;
    loadError;

    @wire(getTimeline, { dispositionId: '$recordId' })
    wiredTimeline(result) {
        if (result.data) {
            this.rows = result.data;
            this.loadError = undefined;
        } else if (result.error) {
            this.loadError =
                result.error?.body?.message || "Couldn't load the buyer timeline.";
            this.rows = undefined;
        }
    }

    /**
     * `2026-08-20` -> `Aug 20, 2026`, or an em-dash.
     *
     * ⚠ Parsed by SPLITTING THE ISO STRING, never with `new Date(value)`. An
     * Apex `Date` serialises as a bare `YYYY-MM-DD`, which `Date` parses as
     * UTC MIDNIGHT — so a viewer west of Greenwich renders the DAY BEFORE. This
     * card's whole job is to be right about days, and an off-by-one that only
     * appears for some users in some timezones is the worst possible shape of
     * wrong. Same technique, for the same reason, as `c/brokerAssignmentHistory`.
     */
    formatDate(value) {
        if (!value) {
            return EM_DASH;
        }
        const parts = String(value).split('-').map(Number);
        return `${MONTHS[parts[1] - 1]} ${parts[2]}, ${parts[0]}`;
    }

    /**
     * A whole-day count as `N days`, or an em-dash.
     *
     * 🔴 A NEGATIVE NEVER REACHES HERE — the service suppresses it to null and
     * raises `hasDateAnomaly` instead. This function does not re-test for one,
     * deliberately: two places deciding what a negative duration means is how
     * they start disagreeing. If a negative ever DID arrive it would render, and
     * that is the correct place for the bug to be visible — in the service's
     * tests, which pin the suppression.
     */
    formatDays(value) {
        if (value === null || value === undefined) {
            return EM_DASH;
        }
        return value === 1 ? '1 day' : `${value} days`;
    }

    get hasError() {
        return !!this.loadError;
    }

    get hasRows() {
        return Array.isArray(this.rows) && this.rows.length > 0;
    }

    /** True only once the wire has answered AND there is genuinely nothing. */
    get isEmpty() {
        return !this.loadError && Array.isArray(this.rows) && this.rows.length === 0;
    }

    /**
     * The card's visible title, with the buyer count appended ONLY once the wire
     * has answered.
     *
     * 🔴 A PREMATURE "(0)" IS A CLAIM THIS CARD IS NOT ENTITLED TO MAKE. Before
     * the wire settles, `rows` is undefined and nothing is known about the sale;
     * "Buyer Activity Timeline (0)" would state, in the same words it uses for a
     * genuinely empty sale, that no buyer has been engaged. The same reasoning
     * keeps the EMPTY STATE out of the pre-wire render, and it is the one thing
     * that must survive any future re-titling of this card.
     */
    get cardTitle() {
        return this.hasRows || this.isEmpty
            ? `Buyer Activity Timeline (${this.rows.length})`
            : 'Buyer Activity Timeline';
    }

    /**
     * The rendered rows, in SERVER ORDER (see the class header — no sort here).
     *
     * A declined row is flattened to em-dashes in ALL FIVE value columns right
     * here, so the template has no per-column conditional to get wrong and the
     * "terminated rows show no dates" rule lives in exactly one place.
     */
    get timelineRows() {
        return (this.rows || []).map((row) => {
            const declined = row.isDeclined === true;
            const ndaSigned = declined
                ? EM_DASH
                : this.formatDate(row.ndaSignedDate);
            const materialsReleased = declined
                ? EM_DASH
                : this.formatDate(row.materialsReleasedDate);
            const firstOffer = declined
                ? EM_DASH
                : this.formatDate(row.firstOfferDate);
            return {
                id: row.ndaId,
                buyerName: row.buyerName || EM_DASH,
                isDeclined: declined,
                // ⚠ Never `undefined`: a getter bound to a custom element's
                // attribute is written UNCONDITIONALLY, so `undefined` would
                // render the literal string "undefined" in the DOM.
                tileClass: declined ? 'dbt-tile dbt-tile--declined' : 'dbt-tile',
                // The accessible name for the whole tile group. Colour and the
                // badge are reinforcement; THIS is the state a screen reader
                // announces.
                rowLabel: declined
                    ? `${row.buyerName} — NDA declined; no dates recorded`
                    : `${row.buyerName} — ${row.status || 'in progress'}`,
                ndaSigned,
                materialsReleased,
                firstOffer,
                daysToRelease: declined ? EM_DASH : this.formatDays(row.daysToRelease),
                daysToRespond: declined ? EM_DASH : this.formatDays(row.daysToRespond),
                // ── Milestone rail (DECORATION ONLY — see the class header) ──
                // Derived from the RENDERED value, not from the raw payload, so
                // the marker and the text beside it cannot disagree: a declined
                // party's retained signature date is already em-dashed above, so
                // its marker is correctly hollow without a second `declined`
                // test here. `--end` suppresses the connector below the third
                // milestone; the two duration rows that follow are not steps.
                ndaSignedStepClass: stepClass(ndaSigned),
                materialsStepClass: stepClass(materialsReleased),
                firstOfferStepClass: `${stepClass(firstOffer)} dbt-step--end`,
                // The anomaly flag is suppressed on a declined row too — it has
                // no dates to be inconsistent with, so a warning there would be
                // noise pointing at nothing.
                hasAnomaly: !declined && row.hasDateAnomaly === true
            };
        });
    }
}

/**
 * The CSS class for one milestone label in the vertical rail.
 *
 * ⚠ Takes the FORMATTED value, deliberately. "Has this milestone happened?" must
 * mean exactly "does the cell beside it show a date?" — deriving it from the raw
 * DTO instead would give the declined-party case two independent answers, and
 * the one on screen would be the wrong one.
 */
function stepClass(formattedValue) {
    return formattedValue === EM_DASH
        ? 'dbt-label dbt-step dbt-step--pending'
        : 'dbt-label dbt-step dbt-step--done';
}
