import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { formatMillions, formatDaysToMarket, formatCapRate } from 'c/utils';
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
 * ⚠ `formatDaysToMarket` AND `formatCapRate` JOINED IT ON 2026-08-25 and are NOT
 * new behaviour: they are the two inline ternaries that used to sit in `rows`,
 * moved to `c/utils` when `c/bovPreferredBroker` gained the same three columns
 * for the preferred broker in the row above this table. Same payload, same
 * strings, one implementation. Do not inline them again "to save an import".
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

/*
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 `PREFERRED_COLUMNS` WAS DELETED HERE ON 2026-08-24. DO NOT RE-DERIVE IT.
 * ══════════════════════════════════════════════════════════════════════════════
 * It was `COLUMNS.filter((c) => c.fieldName !== 'status')` — the same columns
 * minus Status — and it existed for exactly one consumer: the `preferredOnly`
 * instance of this bundle, which rendered the "Preferred Broker" card as a
 * one-row table. There is no such instance any more. The preferred broker is
 * rendered by `c/bovPreferredBroker`, which is not a table and therefore has no
 * columns to choose.
 *
 * The reasoning it carried is preserved because it explains a DECISION, not a
 * mechanism, and the decision still holds in the new panel: the Status pill was
 * dropped because it is CONSTANT on that card, and showing it would put a second
 * green "Selected" pill on the page for a disposition that has exactly ONE
 * appointed broker — which reads as the duplicate-Selected data defect the whole
 * exclusivity guard exists to prevent. `c/bovPreferredBroker` shows a "YES" pill
 * meaning *preferred*, not a Status pill, for that reason.
 */

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
 * ── 🔴 RETRACTED THE SAME DAY: THIS BUNDLE RENDERS **ONCE** ─────────────────
 * What stood here read: *"`c/bovBrokerPanel` mounts it once with `preferred-only`
 * (the 'Preferred Broker' card, above) and once bare (the matrix, below).
 * `@api preferredOnly` defaults `false`, so the bare instance is unchanged by
 * construction."*
 *
 * `@api preferredOnly` IS GONE. The preferred view became a hero panel, not a
 * one-row table, so it became its own bundle — `c/bovPreferredBroker` — and this
 * one went back to doing a single thing. The flag was driving FOUR things (the
 * row filter, the title, the column set, and whether the card rendered at all)
 * and three of the four were statements about a table; keeping it would have
 * meant one template selecting between two unrelated renderings.
 * ⚠ `@api hideActions` WAS DELETED EARLIER THE SAME DAY, for a different reason —
 * there is no action region left for it to suppress, and a flag that suppresses
 * nothing is a false reassurance. `NavigationMixin` survives for ONE reason only:
 * the "View All" footer link, which genuinely is a page transition.
 */
export default class BovComparisonMatrix extends NavigationMixin(LightningElement) {
    @api recordId;

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
     * The rows this card renders: every submission EXCEPT the preferred broker's.
     *
     * 🔴 UNCONDITIONAL SINCE 2026-08-24, AND THAT IS THE POINT. It used to be a ternary on
     * `preferredOnly` — `isPreferred === true` for the preferred card, `!== true` here. The
     * preferred card is now `c/bovPreferredBroker`, which reads a firm name handed down by
     * `c/bovBrokerPanel` and does not query at all, so only this half survives. Excluding the
     * preferred row is a fact about the MATRIX (it compares SCORED responses; the preferred
     * broker is shown above, in its own panel, precisely because it usually has no numbers to
     * compare) rather than a mode of it.
     *
     * 🔴 ONE WIRE, FILTERED HERE — NOT A SECOND APEX METHOD. `getSubmissions` already returns
     * every submission for the disposition, and `c/bovBrokerPanel` reads the SAME payload from
     * the same LDS cache entry to find the preferred row. A `matrixOnly` Apex method would cost
     * a second SOQL, a second cache entry, and a second chance for the two to disagree about the
     * same broker.
     *
     * ⚠ `!== true`, NOT `=== false` AND NOT TRUTHINESS. `isPreferred` is a `Boolean` on
     * `BovController.BovRow`, so an Apex `null` arrives as JS `null` — not `false` — and the key
     * is ABSENT entirely until `Is_Preferred_Broker__c` and its FLS grant are deployed. Under
     * `!== true` both land in the matrix, which is the safe side: an unflagged row is an ordinary
     * broker response, and the alternative silently empties this card.
     */
    get _visible() {
        return (this._data || []).filter((r) => r.isPreferred !== true);
    }

    /*
     * ══════════════════════════════════════════════════════════════════════════════
     * 🔴 `hasPreferredBroker` AND `isVisible` WERE DELETED HERE ON 2026-08-24.
     * ══════════════════════════════════════════════════════════════════════════════
     * `isVisible` was `preferredOnly !== true || hasPreferredBroker`, and it wrapped this whole
     * card in an `lwc:if`. Its entire job was letting the PREFERRED instance withhold itself when
     * no broker was flagged. On the matrix instance it evaluated `true` in every state, so
     * deleting it is behaviour-preserving for the card that survives — and `hasPreferredBroker`
     * had no other consumer left once it went.
     *
     * ⚠ THE "RENDERS NOTHING WHEN THERE IS NO PREFERRED BROKER" REQUIREMENT DID NOT GO WITH THEM.
     * It moved UP: `c/bovBrokerPanel` gates the `<c-bov-preferred-broker>` TAG with
     * `lwc:if={hasPreferredBroker}`. It has to be gated there rather than inside the child — a
     * child that renders nothing is still a flex item and still takes one step of the stack's
     * `gap`, which is the defect that arrangement exists to fix.
     *
     * 🔴 THIS CARD IS NOW VISIBLE IN EVERY STATE, INCLUDING THE TWO EMPTY ONES, AND THAT IS
     * DELIBERATE: on an empty disposition and on the wire's error branch its error banner is what
     * tells the user the read failed, and `c/bovBrokerPanel`'s "Add Broker Response" button —
     * which renders unconditionally, above it — is how they recover.
     */

    get cardTitle() {
        return `BOV Comparison Matrix (${this.count})`;
    }

    get columns() {
        return COLUMNS;
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
                // ⚠ SHARED HELPERS SINCE 2026-08-25, NOT INLINE TERNARIES. Both
                // were inline here with one caller each; `c/bovBrokerPanel` now
                // renders the same two fields for the PREFERRED broker in the row
                // directly above this table, off the same payload. The rendered
                // strings are unchanged — this suite pins '45d' and '6.25%'.
                daysLabel: formatDaysToMarket(r.daysToMarket),
                capRateLabel: formatCapRate(r.capRate),
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
