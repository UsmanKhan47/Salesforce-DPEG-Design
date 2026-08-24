import { LightningElement, api, wire } from 'lwc';

/**
 * 🔴 THE SAME ADAPTER AND THE SAME CONFIG AS `c/bovPreferredBrokerCard`, AND
 * THAT IS ONE SERVER READ RATHER THAN TWO. Lightning Data Service keys its cache
 * on (adapter, config); both cards pass `{ dispositionId: '$recordId' }` for the
 * same record, so the second subscriber is served from the same cache entry and
 * re-provisions from it whenever the data changes. No Apex class, selector or
 * permission set changed to split these cards apart — and the two cannot
 * disagree about the same broker, because they are rendering one payload.
 *
 * ⚠ SO DO NOT "OPTIMISE" THIS INTO A SHARED PARENT THAT WIRES ONCE AND PASSES
 * PROPS DOWN. Three separate cards is the design the user asked for; a parent
 * would reintroduce exactly the nesting that was reverted today, and it would
 * buy nothing — the duplicate wire costs zero server round trips.
 */
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

/**
 * The card's title, WITHOUT the count.
 *
 * ⚠ "BOV" IS THE USER'S WORD AND IS NOT AN ABBREVIATION TO EXPAND. Broker
 * Opinion of Value is the industry term and every other surface in this module
 * uses the initialism (`BOV_Submission__c`, "BOV Outreach", the BOV Comparison
 * Matrix). "Broker Opinions of Value (3)" would be a third name for one thing.
 */
const CARD_TITLE = 'BOV';

/**
 * The name shown for a submission carrying no firm name.
 *
 * 🔴 `Broker_Firm__c` IS LEGITIMATELY NULLABLE AND WAS NULL ON LIVE DATA THIS
 * WEEK — a preferred broker is recorded ahead of any quoted opinion of value, so
 * the thin row carrying the flag frequently carries nothing else. Without this,
 * an otherwise-correct row renders a blank first cell, which reads as a
 * rendering failure rather than as missing data.
 * ⚠ THE SAME WORDING AS `c/bovPreferredBroker`'s `UNNAMED` and
 * `c/bovBrokerPanel`'s `outgoingPreferredLabel`, deliberately: the preferred
 * card two places above this one can be showing the same nameless broker at the
 * same moment, and two placeholders for one missing value read as two different
 * states.
 */
const UNNAMED_BROKER = 'Unnamed broker';

/**
 * The status shown when `Submission_Status__c` is blank.
 *
 * ⚠ IT IS THE FIELD'S OWN DEFAULT, NOT A GUESS — `Submission_Status__c` is a
 * two-value picklist (Backup / Selected) and Backup carries
 * `<default>true</default>` in the field metadata. A blank therefore means "not
 * chosen", which is what this word says.
 * 🔴 THE VALUE ITSELF IS PASSED THROUGH, NEVER DERIVED FROM `isSelected`. If a
 * third value were ever added to that picklist, a derived two-way ternary would
 * silently relabel it "Backup"; passing it through renders whatever the record
 * actually says. Only the PILL'S COLOUR is derived, and only from `isSelected`.
 */
const STATUS_BACKUP = 'Backup';

/**
 * c-bov-responses-card — "BOV (n)", the third of three stacked broker cards on
 * the Disposition record page.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS BUNDLE EXISTS (2026-08-25)
 * ══════════════════════════════════════════════════════════════════════════════
 * `c/bovBrokerPanel` renders ONLY at BOV Outreach, so the moment a deal moves on
 * the broker outcome disappears from the record page. The user's design answers
 * that with THREE SEPARATE STACKED CARDS:
 *
 *   1. Preferred Broker        -> `c/bovPreferredBrokerCard`
 *   2. Broker Replace History  -> `c/bovBrokerChangeHistory`, ALREADY PLACED
 *                                 standalone on the FlexiPage. Nothing to build.
 *   3. BOV (n)                 -> THIS BUNDLE
 *
 * ⚠ EARLIER TODAY THESE WERE NESTED AS SECTIONS INSIDE
 * `c/dispositionBuyerTimeline`. The user clarified the design: separate cards.
 * The nesting has been reverted in full. Do not re-nest them.
 *
 * ── NO "VIEW ALL" FOOTER LINK, AND THE OMISSION IS DELIBERATE ───────────────
 * 🔴 The supplied design shows one. It was left out because there is nothing for
 * it to open, for three independent reasons, ANY ONE of which is disqualifying:
 *   1. THIS CARD IS NOT TRUNCATED. It renders every submission the wire returns,
 *      so "View All" would link to a superset of nothing.
 *   2. `Disposition__c-Disposition Layout` carries NO BOV Submissions related
 *      list (only Approval History, Activity and History), so a
 *      `standard__recordRelationshipPage` navigation to `BOV_Submissions__r` has
 *      no page to render.
 *   3. There is no `NavigationMixin` relationship-page precedent anywhere in
 *      this repo to copy.
 * If the link is wanted later, item 2 is the prerequisite and it is an ADMIN
 * change (add the related list to the page layout) — not a code change here.
 *
 * ── ORDERING ────────────────────────────────────────────────────────────────
 * 🔴 SERVER ORDER, NOT SORTED HERE. `BovSubmissionSelector.selectByDispositionId`
 * returns `BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC` — the ranking
 * the selection was actually made on. Sorting Selected to the top here would let
 * this card and the BOV Comparison Matrix disagree about the same rows on the
 * same sale.
 * ⚠ A CONSEQUENCE WORTH KNOWING: a preferred broker recorded before any BOV
 * carries a NULL score and therefore sorts LAST here. That is not a defect — the
 * Preferred Broker card names them at the top of the stack.
 */
export default class BovResponsesCard extends LightningElement {
    /** The `Disposition__c` Id. Supplied by the record page. */
    @api recordId;

    /**
     * TWO FIELDS, AND THE SECOND ONE IS THE POINT.
     *
     * 🔴 "No BOV submissions" and "the read failed" must not collapse into one
     * empty `_rows`: the first is a fact about the SALE (render nothing at all)
     * and the second is a fact about this CARD (say so). `c/bovBrokerChangeHistory`
     * draws the identical distinction with `isEmpty` vs `isUnavailable`.
     *
     * ⚠ THERE IS NO `_loaded` FLAG, AND ONE WAS DELIBERATELY LEFT OUT rather
     * than kept "for symmetry" with that child. `_rows` starts EMPTY and the
     * error branch RE-EMPTIES it, so `length > 0` is already false in both the
     * pre-wire and the failed states — a loaded flag ANDed onto it could not
     * change any answer, and dead defensive code encodes a premise a future
     * reader will trust.
     * 🔴 THAT ARGUMENT DEPENDS ENTIRELY ON THE ERROR BRANCH CLEARING THE ROWS.
     * If you ever change it to keep the last good data, the guard has to come
     * back — otherwise a failed refresh leaves a full table on screen directly
     * above a line saying the responses could not be loaded, two contradictory
     * claims at once. There is a test pinning exactly that.
     */
    _rows = [];
    _failed = false;

    /**
     * Every BOV submission on this sale.
     *
     * ⚠ THE APEX MESSAGE IS DELIBERATELY DISCARDED. `BovController.getSubmissions`
     * has already replaced the underlying failure with one fixed generic sentence
     * ending "contact your administrator", which names nothing this card's own
     * line does not. Rendering it would put a second, longer, differently-worded
     * failure message on a page that also carries this card's.
     */
    @wire(getSubmissions, { dispositionId: '$recordId' })
    wiredSubmissions({ data, error }) {
        if (data) {
            this._rows = data;
            this._failed = false;
        } else if (error) {
            this._rows = [];
            this._failed = true;
        }
    }

    /**
     * The card's own visibility gate — see the template header.
     *
     * PRE-WIRE and EMPTY render nothing; ROWS and FAILED render the card.
     */
    get isVisible() {
        return this.hasRows || this._failed;
    }

    get hasRows() {
        return this._rows.length > 0;
    }

    /** True when the read FAILED — never merely when it returned nothing. */
    get isUnavailable() {
        return this._failed;
    }

    /**
     * "BOV (3)" with rows; a bare "BOV" on the failed read.
     *
     * 🔴 THE CARD KNOWS NO NUMBER WHEN THE READ FAILED, so it states none. "BOV
     * (0)" on a failure would say, in the same words it would use for a sale that
     * genuinely has no submissions, that nobody ever responded — which is the
     * confident wrong answer this card's whole three-state shape exists to avoid.
     * ⚠ A PREMATURE "(0)" IS UNREACHABLE HERE BY CONSTRUCTION rather than by a
     * guard: the count only ever renders from inside `hasRows`, because the card
     * itself does not render before then.
     */
    get cardTitle() {
        return this.hasRows ? `${CARD_TITLE} (${this._rows.length})` : CARD_TITLE;
    }

    /**
     * One row per BOV submission: the broker's firm, and its status.
     *
     * 🔴 PREFERRED ROWS ARE INCLUDED — see the template header. This card lists
     * the sale's BOV submissions; the preferred one is a submission.
     */
    get responseRows() {
        return this._rows.map((row) => {
            const selected = row.isSelected === true;
            // `.trim()` is part of the check, not tidying: '   ' is falsy nowhere
            // in JavaScript, so a bare `||` renders a blank cell for a hand-typed
            // spaces-only firm name — visually identical to the null case this
            // fallback exists to prevent, and reachable from a hand-typed record.
            const firm =
                typeof row.brokerFirm === 'string' ? row.brokerFirm.trim() : '';
            return {
                id: row.id,
                name: firm || UNNAMED_BROKER,
                status: row.status || STATUS_BACKUP,
                statusClass: selected
                    ? 'brc-badge brc-badge--selected'
                    : 'brc-badge brc-badge--backup'
            };
        });
    }
}
