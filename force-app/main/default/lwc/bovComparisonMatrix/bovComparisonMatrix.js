import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { formatMillions } from 'c/utils';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

/*
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 FOUR IMPORTS WERE DELETED FROM ABOVE ON 2026-08-24, AND NOT BY TIDYING.
 * ══════════════════════════════════════════════════════════════════════════════
 *   - `ShowToastEvent`      — this component no longer raises a toast at all.
 *   - `BovAddResponseModal` — "Add Broker Response" / "Add Preferred Broker".
 *   - `BovReplaceBrokerModal` — "Replace Broker".
 *   - `brokerOptionLabel` from `c/utils` — it built `_backupOptions`, the radio
 *     labels for the replace picker.
 * All four moved WITH the three buttons to `c/bovBrokerPanel`. If you find
 * yourself re-adding any of them here, the button came back with it — read the
 * template header first.
 * ⚠ `refreshApex` STAYED, and `formatMillions` stayed. The first backs
 * `@api refreshData()` (the panel calls it after every write); the second formats
 * the Valuation column.
 */

const SELECTED_BAR = '#2e7d32';
const BACKUP_BAR = '#2BAFAC';
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

/**
 * ⚠ THE OPTION-LABEL FUNCTION MOVED TO `c/utils` ON 2026-08-21 AND ITS REASONING MOVED WITH IT.
 * It used to be a module-local `optionLabel` const here, with a long header explaining why it names
 * the firm, the contact, the amount, the score and the auto-number (this org has six duplicated
 * broker Contacts and seven non-brokers on the Broker record type). Read
 * `c/utils`'s `brokerOptionLabel` before shortening it.
 *
 * 🔴 WHY IT MOVED: `c/brokerListing` now opens the SAME `c/bovReplaceBrokerModal` from the Active
 * Listing stage, and the modal's contract is that it does no formatting *"so the modal and the
 * matrix behind it cannot disagree about the same broker's numbers"*. A second copy of the label
 * rule in that component would have reintroduced precisely that disagreement.
 */

const COLUMNS = [
    { label: 'Broker Firm', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'brokerFirm' }, target: '_self' } },
    { label: 'Contact', fieldName: 'contactName', type: 'text' },
    { label: 'Valuation', fieldName: 'bovAmountLabel', type: 'text' },
    { label: 'Days to Mkt', fieldName: 'daysLabel', type: 'text' },
    { label: 'Cap Rate', fieldName: 'capRateLabel', type: 'text' },
    {
        label: 'Score', fieldName: 'scoreText', type: 'progress',
        typeAttributes: {
            wrapStyle: 'display:flex;align-items:center;gap:10px;min-width:140px',
            trackStyle: 'width:90px;height:6px;background:#eef1f4;border-radius:4px;overflow:hidden',
            barStyle: { fieldName: 'scoreBar' },
            numStyle: 'font-weight:700;color:#181818;font-variant-numeric:tabular-nums',
            text: { fieldName: 'scoreText' }
        }
    },
    { label: 'Status', fieldName: 'status', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'statusWrap' }, dotStyle: { fieldName: 'statusDot' } } }
];

/**
 * The same columns MINUS Status, for the preferred-broker card (2026-08-24).
 *
 * 🔴 DERIVED, NOT A SECOND HAND-WRITTEN ARRAY. A copied array is a second place to add
 * "Cap Rate" to and forget, and the two cards showing different columns for the same broker is
 * the exact class of disagreement that forced `brokerOptionLabel` out of this file and into
 * `c/utils`. Keyed on `fieldName`, not on the human `label`, so renaming the column header does
 * not silently reinstate the column here.
 *
 * ⚠ WHY STATUS GOES AT ALL: THE PILL IS A CONSTANT ON THAT CARD, so the column carries zero
 * information for the price of a column's width.
 * 🔴 THE DIRECTION OF THE CONSTANT FLIPPED ON 2026-08-24 AND THE CONCLUSION DID NOT — worth
 * recording, because a reader who checks the old reasoning will find it inverted and may assume
 * the decision inverted with it. It first read: *"a preferred broker is never Selected, so the
 * pill would read Backup on every row, forever."* The user then decided a preferred broker IS
 * the appointed broker, so it now reads SELECTED on every row, forever. Constant either way.
 * ⚠ AND IT WOULD BE ACTIVELY MISLEADING TO SHOW IT NOW: the same green "Selected" pill appears
 * in the matrix below to mean "this is the appointed broker among the scored field", and there
 * is exactly one appointed broker across BOTH cards. Two Selected pills on one page, one per
 * card, would read as the duplicate-Selected data defect the whole exclusivity guard exists to
 * prevent.
 */
const PREFERRED_COLUMNS = COLUMNS.filter((c) => c.fieldName !== 'status');

/**
 * c-bov-comparison-matrix — the BOV Outreach broker table on the Disposition record page.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 RETRACTED WHOLESALE 2026-08-24: THIS COMPONENT NO LONGER HAS HEADER ACTIONS.
 * ══════════════════════════════════════════════════════════════════════════════
 * Five paragraphs stood here describing the three buttons this card carried —
 * "Add Broker Response", "Replace Broker", "Add Preferred Broker" — their order,
 * their modals, their toasts and the `hideActions` flag that silenced them on the
 * preferred instance. ALL OF IT MOVED, unchanged in behaviour, to
 * `c/bovBrokerPanel`, which now wraps BOTH cards under ONE header so the three
 * buttons sit above both instead of on one of them.
 *
 * The reasoning that moved with them and MUST NOT be re-derived here:
 *   - No action navigates. They open a `LightningModal` over the disposition page
 *     and refresh in place. That is the 2026-08-21 UAT fix.
 *   - "Add Preferred Broker" is the SAME `c/bovAddResponseModal` bundle as "Add
 *     Broker Response" with `isPreferred: true` — not a second bundle.
 *   - "Replace Broker" is the ONE client route into
 *     `BovSubmissionService.replaceSelectedBroker`, whose four invariants
 *     (exclusivity, approval revocation, the savepoint, the
 *     `BOV_Broker_Change__c` history row) live there exactly once.
 *
 * ⚠ `c/brokerListing` STILL CARRIES ITS OWN Replace Broker button, and it is
 * still not a duplicate: it renders at Active Listing, this card renders at BOV
 * Outreach, and the two stages are mutually exclusive. Do not "consolidate" by
 * giving either component its own server path.
 *
 * ── 🔴 THE WIRE IS HELD AS A WHOLE RESULT, NOT DESTRUCTURED ─────────────────
 * `wiredSubmissions(result)` keeps `result` in `_wired` because `refreshApex`
 * requires the un-destructured wire result object. The reason survives the button
 * move intact — it now backs `@api refreshData()`, which the panel calls after
 * every write. See that method for the full argument.
 *
 * ── 🔴 THIS BUNDLE RENDERS TWICE ON THE PAGE (2026-08-24) ───────────────────
 * `c/bovBrokerPanel` mounts it once with `preferred-only` (the "Preferred Broker"
 * card, above) and once bare (the matrix, below). `@api preferredOnly` defaults
 * `false`, so the bare instance is unchanged by construction.
 * ⚠ `@api hideActions` WAS DELETED IN THE SAME CHANGE — there is no action region
 * left for it to suppress, and a flag that suppresses nothing is a false
 * reassurance. `NavigationMixin` survives for ONE reason only: the "View All"
 * footer link, which genuinely is a page transition.
 */
export default class BovComparisonMatrix extends NavigationMixin(LightningElement) {
    @api recordId;

    /**
     * Renders the PREFERRED-BROKER card instead of the comparison matrix (2026-08-24).
     *
     * Changes four things and nothing else: which rows are shown (`isPreferred === true` instead
     * of `!== true`), the card title, the column set (no Status) and whether the card renders at
     * all (it does not, when there is no preferred broker).
     *
     * ⚠ DEFAULT `false` IS THE WHOLE SAFETY ARGUMENT. Every branch below reads
     * `this.preferredOnly === true`, so the existing bare `<c-bov-comparison-matrix>` tag in
     * `c/bovBrokerPanel` takes the same path it always did.
     */
    @api preferredOnly = false;

    _wired;
    _data;
    loadError;
    listUrl = '#';

    @wire(getSubmissions, { dispositionId: '$recordId' })
    wiredSubmissions(result) {
        this._wired = result;
        const { data, error } = result;
        if (data) {
            this._data = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = 'Couldn\'t load BOV submissions.';
            this._data = [];
        }
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'BOV_Submission__c', actionName: 'list' }
        };
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Which rows this instance is about (2026-08-24)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The subset of the wire payload THIS instance renders.
     *
     * 🔴 ONE WIRE, FILTERED HERE — NOT A SECOND APEX METHOD. `getSubmissions` already returns
     * every submission for the disposition, so both cards are drawn from the SAME payload and
     * cannot disagree about the same broker's numbers. A `preferredOnly` Apex method would cost a
     * second SOQL, a second LDS cache entry, and a second chance to diverge.
     *
     * ⚠ `=== true` / `!== true`, NOT TRUTHINESS. `isPreferred` is a `Boolean` on
     * `BovController.BovRow`, so an Apex `null` arrives as JS `null` — not `false`. Under
     * `!== true` a null lands in the MATRIX, which is the safe side: an unflagged row is an
     * ordinary broker response. Under `=== true` it stays out of the preferred card, so a null
     * can never populate a card whose entire purpose is "this one is flagged".
     */
    get _visible() {
        const all = this._data || [];
        return this.preferredOnly === true
            ? all.filter((r) => r.isPreferred === true)
            : all.filter((r) => r.isPreferred !== true);
    }

    /**
     * Whether ANY submission on this disposition is flagged preferred.
     *
     * ⚠ READS `_data`, NOT `_visible`, AND THAT IS THE POINT. The matrix instance filters
     * preferred rows OUT of `_visible`, so a `_visible`-based test would always be false there —
     * and `isVisible` on the preferred instance would go false the moment it mattered.
     *
     * 🔴 RETRACTED IN PLACE 2026-08-24: this used to end *"and 'Add Preferred Broker' would never
     * hide, which is the one behaviour the user asked for by name."* THAT BUTTON IS NO LONGER
     * HERE — `c/bovBrokerPanel` owns it and derives its own `hasPreferredBroker` from its own
     * wire. This getter's remaining consumer is `isVisible` below. The `_data`-not-`_visible`
     * rule is unchanged and still load-bearing for that consumer; only the example moved.
     */
    get hasPreferredBroker() {
        return (this._data || []).some((r) => r.isPreferred === true);
    }

    /**
     * 🔴 THE PREFERRED CARD DOES NOT RENDER AT ALL WHEN THERE IS NO PREFERRED BROKER.
     * Not an empty card with an empty-state line — nothing. (User decision, 2026-08-24.)
     * The matrix instance is always visible, including on an empty disposition and on the wire's
     * error branch, because its error banner is what tells the user the read failed.
     *
     * ⚠ RETRACTED IN PLACE 2026-08-24: that sentence used to add "and its 'Add Broker Response'
     * button are how the user recovers from both". The button now lives on
     * `c/bovBrokerPanel`'s header — which renders unconditionally, ABOVE this card, so the
     * recovery affordance still sits beside the banner. The conclusion is unchanged; the
     * component that owns half of it is not.
     *
     * 🔴 THE PANEL ALSO GATES THE PREFERRED TAG WITH `lwc:if={hasPreferredBroker}`, so on that
     * instance this getter is now belt-and-braces rather than the only gate. Keep it: it is what
     * makes this bundle safe to mount from anywhere, and deleting it would make the card's
     * correctness depend on every future parent remembering to gate.
     */
    get isVisible() {
        return this.preferredOnly !== true || this.hasPreferredBroker;
    }

    get cardTitle() {
        return this.preferredOnly === true
            ? 'Preferred Broker'
            : `BOV Comparison Matrix (${this.count})`;
    }

    get columns() {
        return this.preferredOnly === true ? PREFERRED_COLUMNS : COLUMNS;
    }

    get count() {
        return this._visible.length;
    }

    get rows() {
        return this._visible.map((r) => {
            const selected = !!r.isSelected;
            const score = r.bovScore;
            return {
                id: r.id,
                recordUrl: `/lightning/r/BOV_Submission__c/${r.id}/view`,
                brokerFirm: r.brokerFirm || '—',
                contactName: r.contactName || '—',
                bovAmountLabel: formatMillions(r.bovAmount),
                daysLabel: r.daysToMarket != null ? r.daysToMarket + 'd' : '—',
                capRateLabel: r.capRate != null ? parseFloat(r.capRate).toFixed(2) + '%' : '—',
                scoreText: score != null ? String(score) : '—',
                scoreBar: score != null
                    ? `width:${Math.min(100, score)}%;height:100%;background:${selected ? SELECTED_BAR : BACKUP_BAR};border-radius:4px`
                    : 'width:0%;height:100%',
                status: selected ? 'Selected' : 'Backup',
                statusWrap: selected ? pillWrap('#e9f5ec') : pillWrap('#e8f4f3'),
                statusDot: selected ? pillDot('#3fae5e') : pillDot('#2BAFAC')
            };
        });
    }

    /**
     * Re-provision this instance's wire. Called by `c/bovBrokerPanel` after every
     * write it makes (add response, add preferred broker, replace broker).
     *
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 THIS IS WHY `wiredSubmissions(result)` IS NOT DESTRUCTURED.
     * ══════════════════════════════════════════════════════════════════════════
     * `refreshApex` REQUIRES the un-destructured wire result object — it has no
     * way to re-provision a wire from a `{ data, error }` pair. A "tidying" edit
     * back to `wired({ data, error })` compiles, passes every render test in this
     * bundle's suite, and silently turns this method into a no-op: the card would
     * keep showing the pre-save rows until a page reload, which is precisely the
     * bug the whole in-place-modal rework exists to prevent.
     *
     * ⚠ WHY THE PANEL CALLS THIS AT ALL, GIVEN IT ALSO REFRESHES ITS OWN WIRE.
     * All three wires (the panel's and both children's) hit the same
     * `cacheable=true` method with the same parameter, so LDS serves them from ONE
     * cache entry and invalidating it SHOULD re-provision every consumer. That is
     * an assumption about LDS internals that no Jest stub models and that nothing
     * on this page would report if it stopped holding. This method makes the
     * refresh true by construction and observable in a test.
     */
    @api refreshData() {
        return refreshApex(this._wired);
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
