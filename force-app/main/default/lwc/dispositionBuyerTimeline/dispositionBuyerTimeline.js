/**
 * c-disposition-buyer-timeline
 * ---------------------------------------------------------------------------
 * The card titled "Buyer Activity timeline" on the Disposition record page: ONE
 * CHRONOLOGICAL LIST MERGED FROM TWO SOURCES, newest first — buyer-role NDAs
 * (number, broker, the two journey dates and the duration between them) and
 * RELEASE MATERIALS RESPONSES (what came back after the materials went out).
 * Tranche 2 Workstream D
 * (agent-output/disposition-tranche-2-requirements.md §3 D6.3), retargeted
 * 2026-08-21, MERGED 2026-08-24.
 *
 * ==========================================================================
 * 🔴 THE MERGE (2026-08-24) — WHAT IT DID TO THIS COMPONENT
 * ==========================================================================
 * User decision: *"merge both sources into one chronological timeline"*.
 *   · `timelineRows` now branches on `row.kind` FIRST and hands a response to
 *     `responseRow`. The DTO is a FLAT UNION and the other kind's fields are
 *     NULL, so mapping a response through the NDA branch produces a tile of
 *     em-dashes with no heading.
 *   · 🔴 THE NDA BRANCH AND THE NDA TILE ARE UNCHANGED, BY INSTRUCTION — "a
 *     user should see new entries appear, not their existing ones change
 *     shape". The only addition to an NDA view-model is `isResponse: false`.
 *     Do not "harmonise" the two template branches.
 *   · 🔴 THIS COMPONENT STILL DOES NOT SORT. The interleaving is Apex's, and
 *     it is a statement about the data rather than a presentation preference —
 *     see `DispositionBuyerTimelineService.getTimeline`, which also records the
 *     rule the merge RETIRED ("declined parties sort last"). A declined NDA now
 *     takes its chronological place like everything else; only its POSITION
 *     changed, not its treatment.
 *   · The EMPTY STATE wording widened, because "No NDAs yet" became a false
 *     statement the moment a response could also produce a row.
 *   · ⚠ THE ICON STAYED `standard:contract`. It names the NDA half only, which
 *     is now a partial description — it was left alone because no icon in the
 *     standard set names "NDAs and broker responses", and changing it would
 *     trade one partial description for another while breaking a pinned test.
 *     Recorded as a known imperfection, not an oversight.
 *
 * ==========================================================================
 * 🔴 THREE NAMES, ALL DIFFERENT, ALL DELIBERATE. READ THIS BEFORE "FIXING" ANY.
 * ==========================================================================
 *   BUNDLE / APEX API NAME  ->  dispositionBuyerTimeline  (a BUYER concept)
 *   CARD TITLE ON SCREEN    ->  "Buyer Activity timeline" (2026-08-24)
 *   ONE ROW REPRESENTS      ->  ONE NDA
 * Nothing here agrees with anything else, and each disagreement has a reason:
 *
 * 0. 🔴 THE TITLE HAS NOW BEEN "NDA" -> "BROKER" -> "BUYER" IN FOUR DAYS. Full
 *    sequence: "NDA Activity Timeline" -> "Broker Activity Timeline"
 *    (2026-08-21) -> "Buyer Activity timeline" (2026-08-24). All three were
 *    explicit user instructions and the last one is the current one.
 *    ⚠ RECORDED AS A KNOWN INCONSISTENCY, NOT AS A SETTLED DESIGN: the
 *    2026-08-21 retarget removed the buyer concept from this module entirely —
 *    DPEG communicates only with the appointed listing broker, buyers sit behind
 *    them and are NOT TRACKED — so the card is now titled for a party this
 *    module does not model, over rows that name a BROKER. The rename was carried
 *    out as instructed and raised with the user rather than quietly "corrected"
 *    here. Do not resolve this by changing the DATA to match the title: the
 *    subtitle on every tile is `brokerName`, and there is no buyer identity on
 *    the DTO to put there.
 *
 * 1. THE BUNDLE NAME IS HISTORICAL AND IS NOT GOING TO BE CORRECTED. It now
 *    happens to agree with the title again, which is a coincidence of the
 *    2026-08-24 rename and NOT a reason to treat either as authoritative. The
 *    bundle is placed by `flexipages/Disposition_Record_Page` and its Apex
 *    (`DispositionBuyerTimelineController` / `Service` / `Test`) is compiled into
 *    the org under these names, so a rename is a FlexiPage edit PLUS a
 *    destructive Apex delete — a two-sided deploy that a check-only validation
 *    cannot prove and that leaves a dangling reference if either half lands
 *    alone. Only the user-visible strings have ever been changed, which costs
 *    nothing and is what anyone actually reads. Treat every "buyer" in an API
 *    name on this feature as historical.
 *
 * 2. 🔴 THE ROWS ARE NOT GROUPED BY ANYTHING, AND GROUPING THEM WOULD DESTROY
 *    THE CARD. There is ONE appointed broker per sale, so THE SAME BROKER NAME
 *    REPEATS ON EVERY TILE — that is the data being true, not duplication to be
 *    cleaned up. Group by broker and a three-NDA sale collapses to a single row,
 *    deleting the entire timeline this component exists to show. The broker is
 *    rendered as a per-tile SUBTITLE, never as the tile heading, and the title —
 *    whatever it currently says — has never been a grouping claim.
 *
 * 3. The row's identity is the NDA AutoNumber, the only per-row identity that is
 *    always present. The empty state still says "NDA" for that reason, and it is
 *    correct — it describes the rows. The title names a counterparty; the rows
 *    name the NDAs.
 *
 * ==========================================================================
 * 🔴 THE "FIRST OFFER" COLUMN WAS DELETED. THE OBVIOUS REPLACEMENT IS A LIE.
 * ==========================================================================
 * Each row used to carry the earliest offer made by THAT ROW'S BUYER on this
 * sale, joined on a Contact Id at both ends. With the buyer gone from the offer
 * form, NOTHING LINKS AN OFFER TO A SPECIFIC NDA, so no attribution this card
 * can make is true.
 * 🔴 DO NOT SUBSTITUTE THE DISPOSITION'S EARLIEST OFFER. It is one query away
 * and it would render the SAME DATE ON EVERY TILE, under a label that reads as a
 * per-row fact. This repo deleted a whole component three weeks ago on exactly
 * that ground — a component rendering a fixed lie is worse than an empty one.
 * The Apex selector method behind the column was deleted with it so the shortcut
 * has no one-liner to reach for.
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
 * the value shown once that gate passes. ⚠ THE 2026-08-21 RETARGET DID NOT
 * TOUCH ANY OF THIS — it is restated because a different column WAS deleted that
 * day, and the two must not be confused.
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
 * TERMINATED row: the NDA number, its broker, a `Declined` badge, and em-dashes
 * in both date columns and the duration. Sorted LAST.
 *
 * ⚠ ACCESSIBILITY: the `Declined` state is carried as READABLE TEXT inside the
 * badge, not by colour alone, and each terminated row's group carries an
 * `aria-label` naming the NDA and the state. A coloured pill on its own is
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
 * Apex rather than LDS/GraphQL because the payload carries a status gate and a
 * derived duration that no wire adapter can express (ARCHITECTURE.md §5,
 * "Imperative Apex only when LDS cannot express the query"). The controller is a
 * thin wrapper over the service.
 *
 * ── ERROR BRANCH ─────────────────────────────────────────────────────────
 * The controller throws `AuraHandledException` rather than returning an empty
 * list, because an empty timeline on a sale with three raised NDAs is a
 * confident wrong answer nothing on the page contradicts. This component
 * therefore renders a visible inline alert — never a silent blank.
 * ⚠ EXPECT THIS BRANCH IMMEDIATELY AFTER DEPLOY. `NDA__c.Broker__c` is a
 * 2026-08-21 field, and a Metadata-API-deployed field arrives with NO FLS for
 * anyone (System Administrator included), so the `WITH USER_MODE` read behind
 * this card throws until both disposition permission sets grant it. That is a
 * deploy-order dependency, not a defect.
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 🔴 DESIGNED FOR A ~340px SIDEBAR COLUMN. DO NOT REINTRODUCE COLUMNS.
 * ══════════════════════════════════════════════════════════════════════════
 * The rendered unit is a self-labelling TILE, not a row in a shared grid — see
 * the long note in the template. The three values below are produced in reading
 * order and flattened to em-dashes in exactly the same cases as before; the two
 * "step class" getters drive a decorative milestone rail and carry NO
 * information that is not already in the value cell beside them.
 */
import { LightningElement, api, wire } from 'lwc';
import getTimeline from '@salesforce/apex/DispositionBuyerTimelineController.getTimeline';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Rendered wherever a date or a duration cannot be stated truthfully. */
const EM_DASH = '—';

/**
 * `TimelineRow.kind` for a Release Materials response entry (2026-08-24).
 *
 * 🔴 THE TEST IS AGAINST THIS CONSTANT, NOT AGAINST "IS THERE A responseId". An
 * `=== undefined` probe on a half-populated union would classify a row by which
 * fields happened to be null, so a future NDA row that briefly lacked an ndaId
 * would render as a response. `kind` is the server's explicit answer and it is
 * never null — `DispositionBuyerTimelineService` sets it in both builders.
 * ⚠ IT MUST MATCH `DispositionBuyerTimelineService.KIND_RESPONSE` EXACTLY. The
 * pairing is not compile-checked; the Jest suite pins the string on this side
 * and the Apex suite pins it on the other.
 */
const KIND_RESPONSE = 'Response';

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
            // The fallback names the card the user is looking at ("buyer
            // activity timeline"), not the objects behind it — a message that
            // names a card the user cannot see on screen is not actionable.
            // ⚠ RETITLED WITH THE CARD ON 2026-08-24. This sentence is the only
            // user-visible string outside `cardTitle` that repeats the card's
            // name, so it has to move with it or the alert names a card that is
            // not on screen — which is the exact defect the wording avoids.
            this.loadError =
                result.error?.body?.message ||
                "Couldn't load the buyer activity timeline.";
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
     * The card's visible title, with the NDA count appended ONLY once the wire
     * has answered.
     *
     * 🔴 A PREMATURE "(0)" IS A CLAIM THIS CARD IS NOT ENTITLED TO MAKE. Before
     * the wire settles, `rows` is undefined and nothing is known about the sale;
     * "Buyer Activity timeline (0)" would state, in the same words it uses for a
     * genuinely empty sale, that no NDA has been raised. The same reasoning
     * keeps the EMPTY STATE out of the pre-wire render, and it has now survived
     * two re-titlings (2026-08-21, 2026-08-24) exactly as its wording said it
     * must.
     *
     * ⚠ SINCE THE 2026-08-24 MERGE THE COUNT IS A COUNT OF **ENTRIES** — NDAs
     * PLUS RESPONSES — NOT OF BROKERS AND NOT OF BUYERS. It counted NDAs only
     * until that day, so a sale whose number jumps is not a defect. On a sale
     * with one broker, two NDAs and three logged responses this reads "Buyer
     * Activity timeline (5)", which matches the number of tiles below it — and
     * matching the visible list is the only property a count on a card needs.
     * Do not "reconcile" it with the title by counting distinct counterparties;
     * that number is 1 on every disposition and tells the reader nothing, and
     * do not split it into "2 NDAs, 3 responses" either — a two-part count in a
     * card title is read as a ratio.
     *
     * ⚠ THE CAPITALISATION IS THE USER'S, VERBATIM: capital "A", lower-case "t"
     * ("Buyer Activity timeline", user instruction 2026-08-24). It is asymmetric
     * on purpose and is pinned by an exact-match assertion in the Jest suite —
     * "tidying" it to Title Case will red that test, which is the point.
     */
    get cardTitle() {
        return this.hasRows || this.isEmpty
            ? `Buyer Activity timeline (${this.rows.length})`
            : 'Buyer Activity timeline';
    }

    /**
     * The rendered rows, in SERVER ORDER (see the class header — no sort here).
     *
     * A declined row is flattened to em-dashes in ALL THREE value columns right
     * here, so the template has no per-column conditional to get wrong and the
     * "terminated rows show no dates" rule lives in exactly one place.
     */
    get timelineRows() {
        return (this.rows || []).map((row) => {
            // 🔴 KIND FIRST. The DTO is a FLAT UNION and the other kind's fields
            // are NULL, not empty — mapping a response row through the NDA
            // branch below produces a tile of em-dashes with no heading.
            if (row.kind === KIND_RESPONSE) {
                return this.responseRow(row);
            }
            const declined = row.isDeclined === true;
            const ndaSigned = declined
                ? EM_DASH
                : this.formatDate(row.ndaSignedDate);
            const materialsReleased = declined
                ? EM_DASH
                : this.formatDate(row.materialsReleasedDate);
            // ⚠ Never `undefined` anywhere below: a getter bound to a custom
            // element's attribute is written UNCONDITIONALLY, so `undefined`
            // would render the literal string "undefined" in the DOM.
            const ndaName = row.ndaName || EM_DASH;
            return {
                id: row.ndaId,
                // 🔴 THE ROW'S IDENTITY IS THE NDA NUMBER. It used to be the
                // buyer's name; buyers are no longer tracked, and the AutoNumber
                // is the only per-row identity that is always present.
                ndaName,
                brokerName: row.brokerName || EM_DASH,
                isDeclined: declined,
                // ⚠ FALSE, NOT UNDEFINED. `lwc:if` treats both as falsy, but an
                // explicit boolean is what makes a Jest assertion on the shape
                // of an NDA row meaningful rather than a test of `undefined`.
                isResponse: false,
                tileClass: declined ? 'dbt-tile dbt-tile--declined' : 'dbt-tile',
                // The accessible name for the whole tile group. Colour and the
                // badge are reinforcement; THIS is the state a screen reader
                // announces.
                rowLabel: declined
                    ? `${ndaName} — NDA declined; no dates recorded`
                    : `${ndaName} — ${row.status || 'in progress'}`,
                ndaSigned,
                materialsReleased,
                daysToRelease: declined ? EM_DASH : this.formatDays(row.daysToRelease),
                // ── Milestone rail (DECORATION ONLY — see the class header) ──
                // Derived from the RENDERED value, not from the raw payload, so
                // the marker and the text beside it cannot disagree: a declined
                // party's retained signature date is already em-dashed above, so
                // its marker is correctly hollow without a second `declined`
                // test here. `--end` suppresses the connector below the LAST
                // milestone; the duration row that follows is not a step.
                ndaSignedStepClass: stepClass(ndaSigned),
                materialsStepClass: `${stepClass(materialsReleased)} dbt-step--end`,
                // The anomaly flag is suppressed on a declined row too — it has
                // no dates to be inconsistent with, so a warning there would be
                // noise pointing at nothing.
                hasAnomaly: !declined && row.hasDateAnomaly === true
            };
        });
    }

    /**
     * ONE RELEASE MATERIALS RESPONSE -> ONE TILE (2026-08-24).
     *
     * ⚠ IT SHARES THE TILE CHROME AND NONE OF THE JOURNEY. `dbt-tile` and
     * `dbt-tile-head` / `dbt-facts` / `dbt-broker` are deliberately the same
     * classes the NDA tile uses — the two kinds sit in ONE list and must read as
     * one list — but the tile carries a `dbt-tile--response` modifier and its
     * heading takes its own class (`dbt-rmr`, not `dbt-nda`) so a selector can
     * always tell them apart. A shared `.dbt-nda` heading would have made the
     * existing "one row per NDA, headed by its NUMBER" assertion silently start
     * counting responses.
     *
     * 🔴 THERE IS NO MILESTONE RAIL ON A RESPONSE TILE. The rail's markers mean
     * "this milestone has happened / is still to come", which is a statement
     * about a JOURNEY. A response is a single event with one timestamp: a rail
     * beside it would be decoration that asserts something untrue.
     *
     * ⚠ `entryDateTime` IS PASSED THROUGH RAW, not formatted here. It is a
     * DATETIME (an unambiguous instant), so `lightning-formatted-date-time`
     * renders it in the viewer's own timezone, which is correct — the opposite
     * of the `formatDate` split-the-ISO-string treatment the NDA tile's bare
     * `YYYY-MM-DD` Apex Dates need to avoid a UTC-midnight off-by-one.
     *
     * @param {object} row A `TimelineRow` whose `kind` is `Response`.
     * @returns {object} The tile view-model.
     */
    responseRow(row) {
        const responseName = row.responseName || EM_DASH;
        const method = row.method || EM_DASH;
        const brokerName = row.brokerName || EM_DASH;
        return {
            id: row.responseId,
            isResponse: true,
            responseName,
            method,
            brokerName,
            // Notes are OPTIONAL on a response. An em-dash is the correct
            // rendering of "none entered" — never a blank cell, which reads as
            // a rendering failure rather than as missing data.
            notes: row.notes || EM_DASH,
            entryDateTime: row.entryDateTime,
            tileClass: 'dbt-tile dbt-tile--response',
            // The accessible name for the whole tile group. The badge and the
            // subtitle are reinforcement; THIS is what a screen reader
            // announces for the row, and it names the KIND so the two kinds are
            // distinguishable without sight.
            rowLabel: `${responseName} — release materials response, ${method}`
        };
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
