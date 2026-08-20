import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import SellMeterInitiateModal from 'c/sellMeterInitiateModal';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';

/** Last-resort text when a thrown error carries no readable body (e.g. transport failure). */
const GENERIC_CREATE_ERROR = 'Unexpected error creating the disposition.';

/** Shown when a row action throws before it can raise its own, more specific message. */
const GENERIC_ACTION_ERROR = 'Something went wrong handling that action. Please try again.';

// [background, dot, label, textColor, fontWeight] per band.
const METER = {
    GREEN:  ['#e9f5ec', '#3fae5e', 'Sell now',       '#3e3e3e', 600],
    YELLOW: ['#fdf0e1', '#c98a33', 'Getting Close',  '#3e3e3e', 600],
    RED:    ['#fdeaea', '#e0556b', 'Hold - Not yet', '#c23934', 700]
};
const METER_ORDER = { GREEN: 0, YELLOW: 1, RED: 2 };
const PAGE_SIZE = 5;
const pillWrap = (bg, color = '#3e3e3e', weight = 600) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:${weight};color:${color};background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Property', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'NOI', fieldName: 'noiLabel', type: 'text' },
    { label: 'Mkt Cap', fieldName: 'capRateLabel', type: 'text' },
    { label: 'Target Price', fieldName: 'targetLabel', type: 'text' },
    { label: 'Peak Sell Date', fieldName: 'peakDateLabel', type: 'text' },
    { label: 'Projected Value at Peak', fieldName: 'peakValueLabel', type: 'text' },
    { label: 'Sell Meter', fieldName: 'sellMeter', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'meterWrap' }, dotStyle: { fieldName: 'meterDot' } } },
    {
        label: 'Action', type: 'button', initialWidth: 130,
        typeAttributes: {
            label: { fieldName: 'actionLabel' },
            name: { fieldName: 'actionName' },
            variant: { fieldName: 'actionVariant' },
            disabled: { fieldName: 'actionDisabled' }
        }
    }
];

export default class SellMeterList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data;
    _page = 1;
    listUrl = '#';
    error;

    @wire(getPortfolio)
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Property_Asset__c', actionName: 'list' }
        };
    }

    get count() {
        return this._data ? this._data.length : 0;
    }

    // Full sorted + formatted list; the visible page is sliced from this in `rows`.
    get allRows() {
        if (!this._data) return [];
        const sorted = [...this._data].sort(
            (a, b) => (METER_ORDER[a.sellMeter] ?? 3) - (METER_ORDER[b.sellMeter] ?? 3)
        );
        // Holds (RED) sort last, so they'd never appear on page 1. Pull the first Hold up into
        // the last visible slot of page 1 so the opening screen showcases all three states.
        if (!sorted.slice(0, PAGE_SIZE).some((r) => r.sellMeter === 'RED')) {
            const idx = sorted.findIndex((r) => r.sellMeter === 'RED');
            if (idx >= PAGE_SIZE) {
                const [hold] = sorted.splice(idx, 1);
                sorted.splice(PAGE_SIZE - 1, 0, hold);
            }
        }
        return sorted.map((r) => {
            const meter = r.sellMeter || 'RED';
            const [bg, dot, label, textColor, weight] = METER[meter] || METER.RED;
            const countdown = this._countdown(r.peakSellDate);
            return {
                id: r.id,
                name: r.name,
                recordUrl: `/lightning/r/Property_Asset__c/${r.id}/view`,
                noiLabel: this._fmtM(r.noi),
                capRateLabel: r.mktCapRate != null ? parseFloat(r.mktCapRate).toFixed(1) + '%' : '—',
                targetLabel: this._fmtM(r.targetPrice),
                peakDateLabel: this._fmtFullDate(r.peakSellDate),
                peakValueLabel: this._fmtM(r.projectedValueAtPeak),
                sellMeter: countdown ? `${label} | ${countdown}` : label,
                meterWrap: pillWrap(bg, textColor, weight),
                meterDot: pillDot(dot),
                actionLabel: meter === 'GREEN' ? 'Initiate' : (meter === 'YELLOW' ? 'Override' : 'Hold'),
                actionName: meter === 'GREEN' ? 'initiate' : (meter === 'YELLOW' ? 'override' : 'hold'),
                actionVariant: meter === 'GREEN' ? 'brand' : (meter === 'YELLOW' ? 'neutral' : 'base'),
                actionDisabled: meter === 'RED'
            };
        });
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.count / PAGE_SIZE));
    }

    // Clamped current page (guards against data shrinking under the active page).
    get page() {
        return Math.min(Math.max(1, this._page), this.totalPages);
    }

    get rows() {
        const start = (this.page - 1) * PAGE_SIZE;
        return this.allRows.slice(start, start + PAGE_SIZE);
    }

    get showPager() {
        return this.count > PAGE_SIZE;
    }

    get rangeLabel() {
        if (!this.count) return '0 of 0';
        const start = (this.page - 1) * PAGE_SIZE + 1;
        const end = Math.min(this.page * PAGE_SIZE, this.count);
        return `${start}–${end} of ${this.count}`;
    }

    get pageLabel() {
        return `Page ${this.page} of ${this.totalPages}`;
    }

    get isFirstPage() {
        return this.page <= 1;
    }

    get isLastPage() {
        return this.page >= this.totalPages;
    }

    prevPage() {
        if (!this.isFirstPage) this._page = this.page - 1;
    }

    nextPage() {
        if (!this.isLastPage) this._page = this.page + 1;
    }

    /**
     * Row-button dispatcher for the three sell-meter actions.
     *
     * - `initiate` (GREEN)   opens the initiate modal immediately.
     * - `override` (YELLOW)  confirms FIRST, then opens the identical modal.
     * - `hold`     (RED)     returns early. The button is already `disabled`, and the server
     *                        refuses a RED asset too — the client early-return is the
     *                        outermost of three defences, not the only one.
     *
     * ⚠ `override` was previously unhandled, so the yellow row's ENABLED button was a
     * silent no-op — a live defect this restores. Do not narrow the guard back to
     * `!== 'initiate'`.
     *
     * ── 🔴 THE BAND GATE DID NOT MOVE WHEN THE MODAL ARRIVED ────────────────
     * The modal is inserted AFTER this dispatcher and AFTER the yellow-band confirmation,
     * not in place of either. RED still never reaches it; YELLOW still answers the override
     * question before it appears. Opening the modal first and asking the override question
     * inside it would let a user fill in a record type before being told the property is not
     * at peak — the confirmation exists to be the FIRST thing they see.
     */
    handleRowAction(event) {
        // An exception thrown inside a datatable row-action handler is swallowed by the
        // datatable with NO UI signal at all, which is indistinguishable from "the click did
        // nothing" — exactly the symptom that hid the defect below for as long as it existed.
        // This catch is permanent for that reason: a broken action must always say so.
        try {
            const detail = (event && event.detail) || {};
            const row = detail.row || {};
            const name = this._resolveActionName(detail.action, row);
            if (name !== 'initiate' && name !== 'override') {
                // Includes 'hold' (RED) — inert by design, see the band note above.
                return;
            }
            const assetId = row.id;
            if (!assetId) {
                this._toast('Could not initiate', 'No property asset is linked to this row.', 'error');
                return;
            }
            if (name === 'override') {
                this._confirmOverride(row).then((confirmed) => {
                    // A cancel does nothing and says nothing — the user already knows they cancelled.
                    if (confirmed === true) {
                        this._openInitiateModal(row, true);
                    }
                });
                return;
            }
            this._openInitiateModal(row, false);
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('Sell Meter row action failed', error);
            this._toast('Could not complete that action', this._errorText(error, GENERIC_ACTION_ERROR), 'error');
        }
    }

    /**
     * Resolves the button's action name for the clicked row.
     *
     * 🔴 READ THIS BEFORE "SIMPLIFYING" IT BACK TO `event.detail.action.name`.
     *
     * `lightning-datatable` does NOT resolve `fieldName` references inside a column's
     * `typeAttributes` when it builds the `rowaction` event payload — it passes the RAW COLUMN
     * DEFINITION through as `detail.action`. Because the Action column declares
     * `name: { fieldName: 'actionName' }`, `detail.action.name` is the OBJECT
     * `{ fieldName: 'actionName' }`, never the string `'initiate'`. Stringified into the
     * handler's guard it becomes `'[object Object]'`, which matches neither accepted name, so
     * EVERY click returned early and silently.
     *
     * Measured in the live org on 2026-08-20 (Copperfield Town Center, a GREEN row):
     *   detail.action = {"label":{"fieldName":"actionLabel"},"name":{"fieldName":"actionName"},
     *                    "variant":{...},"disabled":{...}}
     *   resolved name = '[object Object]'  →  "Ignored action" → returned
     *
     * ⚠ THIS IS NOT A REDESIGN REGRESSION. The pre-redesign code used the same
     * `!== 'initiate'` guard against the same unresolved payload, so the button had never
     * worked; every disposition in the org was created by a seed script, which is why nobody
     * hit it sooner.
     *
     * `detail.row` IS fully resolved and already carries the per-row `actionName` built in
     * `allRows`, so the row is the reliable source. The `action.name` string branch is kept
     * because a static (non-`fieldName`) column definition — or a future platform version that
     * does resolve typeAttributes — legitimately sends a real string, and that must still win.
     *
     * @param {object} action `event.detail.action`; may be an unresolved column definition
     * @param {object} row    `event.detail.row`; always the resolved row from `allRows`
     * @returns {string|undefined} the action name, or undefined when neither source has one
     */
    _resolveActionName(action, row) {
        const fromAction = action && action.name;
        if (typeof fromAction === 'string' && fromAction) {
            return fromAction;
        }
        return row && row.actionName;
    }

    /**
     * Yellow-band confirmation (Gate 1 Q2 = confirm-then-create).
     *
     * Uses `lightning/confirm` directly and NOT c/dealActionGuard: that util imports an
     * Opportunity permission controller at module scope, which would give the Disposition
     * dashboard a hard dependency on an Opportunity gate for ten lines of code.
     * ARCHITECTURE.md §5 already records that the guard utils must not be merged.
     *
     * A toast cannot be used here — it is fire-and-forget and returns nothing, so it cannot
     * carry a yes/no answer. LightningConfirm.open() returns Promise<boolean>.
     *
     * ⚠ THIS COMMENT USED TO END "There is deliberately NO override reason field and NO
     * approval: the source document asks for neither." HALF OF THAT IS NOW FALSE and must not
     * be quoted: the disposition flow redesign routes EVERY initiate — override included —
     * into `Sale_Decision_Approval`, submitted server-side by
     * `DispositionService.initiateAndSubmit`. What survives is the OTHER half: there is still
     * no override REASON field. The override is recorded only by this dialog having been
     * answered and by the distinct success-toast title below, which is a deliberate scope
     * decision, not an oversight.
     */
    _confirmOverride(row) {
        const property = row.name || 'this property';
        return LightningConfirm.open({
            variant: 'header',
            label: 'Override the sell meter?',
            theme: 'warning',
            message:
                `${property} is not at peak yet — its peak sell date is 31 to 90 days away. ` +
                'Initiating a disposition now overrides the sell meter. Continue?'
        }).catch(() => false);
    }

    /**
     * The single entry point shared by Initiate and Override — deliberately identical apart
     * from the toast title, so an override can never diverge from an initiate.
     *
     * ⚠ THIS REPLACED A DIRECT `DispositionController.findOrCreate` CALL. That method still
     * exists and is deliberately untouched (design §1.4), but it creates WITHOUT a record type
     * choice and WITHOUT submitting an approval, which is no longer what this button means.
     * `initiateAndSubmit` — invoked inside the modal — does both. Do not "simplify" this back
     * into a direct `findOrCreate` call: it would silently create Off-Market-defaulted
     * dispositions that no approval ever sees.
     *
     * All messaging lives HERE rather than in the modal, because a toast raised from inside a
     * modal that is closing in the same tick is a race; this component outlives the modal.
     *
     * @param {object} row the sell-meter row the button was pressed on
     * @param {boolean} isOverride true when the yellow-band override path opened the modal
     */
    async _openInitiateModal(row, isOverride) {
        let result;
        try {
            result = await SellMeterInitiateModal.open({
                size: 'small',
                label: 'Initiate Disposition',
                description:
                    'Review the property summary, choose On Market or Off Market, and send the disposition for approval.',
                assetId: row.id,
                propertyName: row.name,
                // Pre-formatted by `allRows` — the modal does no formatting of its own, so the
                // popup and the row it opened from cannot show different numbers.
                noiLabel: row.noiLabel,
                capRateLabel: row.capRateLabel,
                targetLabel: row.targetLabel,
                peakDateLabel: row.peakDateLabel
            });
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('Sell Meter initiate modal failed to open', error);
            // The modal failed to OPEN. Nothing was created and nothing was attempted, so this
            // is not the server-refusal path — say so plainly rather than reusing that wording.
            this._toast('Could not open the initiate dialog', this._errorText(error), 'error');
            return;
        }

        // Cancelled or dismissed: nothing was created, so say nothing.
        if (!result) {
            return;
        }
        if (result.error) {
            // A designed server refusal (the sell-meter gate) arrives as an AuraHandledException
            // whose message is AUTHORED TO BE SHOWN — surface it verbatim rather than replacing
            // it with generic wording. Sticky, because it is the whole answer to the click.
            this._toast('Could not create disposition', this._errorText(result.error), 'error');
            // eslint-disable-next-line no-console
            console.error('Sell Meter initiate failed', result.error);
            return;
        }
        this._handleOutcome(result.outcome, row, isOverride);
    }

    /**
     * Acts on `DispositionService.InitiateOutcome`.
     *
     * 🔴 THE MEMBER NAMES BELOW ARE THE SERVER'S, COPIED VERBATIM FROM
     * `DispositionService.InitiateOutcome`: `dispositionId`, `submitted`, `message`. A Jest
     * fixture DEFINES this payload locally, so a rename on the Apex side leaves this file
     * reading `undefined` with a GREEN suite and a clean deploy. If the Apex DTO changes, this
     * block is the only place to change — keep the mapping in one place for that reason.
     *
     * 🔴 `submitted === false` IS A SUCCESS PATH. `dispositionId` is always populated on a
     * non-throwing return, so the record EXISTS; only the approval submission did not take.
     * Navigate regardless, and let the toast VARIANT carry the difference. Treating false as a
     * failure would tell the user nothing was created about a record that is sitting there.
     */
    _handleOutcome(outcome, row, isOverride) {
        const dispositionId = outcome && outcome.dispositionId;
        if (!dispositionId) {
            // Contractually unreachable — a non-throwing return always carries an Id. Handled
            // anyway so a future contract change surfaces as a message rather than as a
            // navigation to `undefined`.
            this._toast('Could not create disposition', GENERIC_CREATE_ERROR, 'error');
            return;
        }
        const submitted = outcome.submitted === true;
        const property = row.name || 'this property';
        const title = submitted
            ? isOverride
                ? 'Disposition initiated (override)'
                : 'Disposition sent for approval'
            : 'Disposition created — not submitted';
        const fallback = submitted
            ? `Opened the disposition for ${property}.`
            : `The disposition for ${property} was created but could not be submitted for approval.`;
        this._toast(title, outcome.message || fallback, submitted ? 'success' : 'warning');
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: dispositionId, actionName: 'view' }
        });
    }

    /**
     * Extracts user-safe text from a thrown error; never lets `undefined` reach a toast.
     * `fallback` defaults to the create-path wording because that is the overwhelming majority
     * of callers; the row-action catch passes its own, since nothing was created there.
     */
    _errorText(error, fallback = GENERIC_CREATE_ERROR) {
        return (
            (error && error.body && error.body.message) ||
            (error && error.message) ||
            fallback
        );
    }

    /**
     * ⚠ `warning` IS STICKY ALONGSIDE `error`. The created-but-not-submitted toast is the only
     * notice the user gets that an approval still has to be raised by hand; a 3-second
     * auto-dismiss would routinely lose it behind the page navigation that follows it in the
     * same tick.
     */
    _toast(title, message, variant) {
        const sticky = variant === 'error' || variant === 'warning';
        this.dispatchEvent(
            new ShowToastEvent({ title, message, variant, mode: sticky ? 'sticky' : 'dismissable' })
        );
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }

    _fmtM(val) {
        if (val == null) return '—';
        return '$' + (parseFloat(val) / 1000000).toFixed(1) + 'M';
    }

    // 'YYYY-MM-DD' → 'Aug 12, 2027' (manual parse to avoid timezone shifts).
    _fmtFullDate(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length < 3) return '—';
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return months[parseInt(p[1], 10) - 1] + ' ' + parseInt(p[2], 10) + ', ' + p[0];
    }

    // Time remaining until the peak sell date, as 'Xm Yd' (e.g. '5m 6d'); 'Now' if already at/past peak.
    _countdown(d) {
        if (!d) return '';
        const p = String(d).split('-').map((n) => parseInt(n, 10));
        if (p.length < 3 || p.some(isNaN)) return '';
        const peak = new Date(p[0], p[1] - 1, p[2]);
        const now = new Date();
        now.setHours(0, 0, 0, 0);
        if (peak <= now) return 'Now';
        let months = (peak.getFullYear() - now.getFullYear()) * 12 + (peak.getMonth() - now.getMonth());
        let days = peak.getDate() - now.getDate();
        if (days < 0) {
            months -= 1;
            days += new Date(peak.getFullYear(), peak.getMonth(), 0).getDate(); // days in the month before peak
        }
        return months > 0 ? `${months}m ${days}d` : `${days}d`;
    }
}