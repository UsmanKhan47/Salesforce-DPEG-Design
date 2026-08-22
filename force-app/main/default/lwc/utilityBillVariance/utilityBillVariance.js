import { LightningElement, api } from 'lwc';

/**
 * c-utility-bill-variance - the FSD 5.10.5 variance decomposition, as a read-only panel.
 *
 * PRESENTATIONAL. Props in, nothing out. No wire, no Apex, no fetch, no state beyond what it
 * is handed (ARCHITECTURE.md section 5: "Presentational components are stateless - props in,
 * events out"). Its owner, c-utility-bill-detail, does the reading.
 *
 * ── WHY THE DECOMPOSITION IS THE WHOLE POINT ────────────────────────────────
 * "The bill went up $145" is not actionable. "You used 50 more units at last month's price
 * (+$100) AND the price rose 30c on this month's volume (+$45)" is two different problems
 * with two different owners - one is a building question, the other is a contract question.
 * FSD 5.10.2 requires the split BEFORE any alert fires, and this panel is where a human
 * reads it.
 *
 * ── THE RECONCILIATION LINE IS A LIVE CHECK, NOT DECORATION ─────────────────
 * Usage + rate is exactly equal to the total change, with no residual:
 *   (C_B - C_P)R_P + (R_B - R_P)C_B = R_B.C_B - R_P.C_P = Total_B - Total_P
 * The panel states that equality on screen. If a future formula edit breaks it, the panel
 * shows the break rather than quietly displaying three numbers that no longer add up - which
 * is the only symptom a sign error would otherwise have.
 */
export default class UtilityBillVariance extends LightningElement {
    /** Change in consumption valued at the PRIOR unit rate, in dollars. */
    @api usageVariance;
    /** Change in unit rate valued at the CURRENT consumption, in dollars. */
    @api rateVariance;
    /** The raw dollar change against the prior bill. */
    @api totalVariance;
    /**
     * Percentage change against the prior bill, on the human scale (100 means +100%).
     *
     * ⚠ This must be the value derived in Apex by `UtilityBillController.variancePct`, NOT
     * `Utility_Bill__c.Total_Variance_Pct__c`. The stored formula field is currently 100x its
     * true value - see that controller's class header for the measurements.
     */
    @api totalVariancePct;
    /** Label for the bill being compared against, e.g. "UB-00012 (1 Jan 2026)". */
    @api priorBillLabel;
    /** False when there is no prior bill; the panel then explains rather than showing zeros. */
    @api hasPrior = false;

    /** True when there is something to decompose. */
    get showBreakdown() {
        return this.hasPrior === true && this.totalVariance !== null
            && this.totalVariance !== undefined;
    }

    /**
     * The two components, as rows.
     *
     * `direction` drives the CSS class, and it is computed from the SIGN rather than from a
     * "good/bad" judgement: a fall in consumption is not automatically good news (it can mean
     * a vacancy), so the panel colours by direction and lets the reader judge.
     */
    get rows() {
        return [
            {
                key: 'usage',
                label: 'Usage variance',
                hint: 'Change in consumption, priced at last month’s rate',
                value: this.usageVariance,
                amountClass: this.amountClass(this.usageVariance)
            },
            {
                key: 'rate',
                label: 'Rate variance',
                hint: 'Change in unit rate, on this month’s consumption',
                value: this.rateVariance,
                amountClass: this.amountClass(this.rateVariance)
            }
        ];
    }

    get totalClass() {
        return `ubv-total-amount ${this.amountClass(this.totalVariance)}`;
    }

    amountClass(value) {
        if (value === null || value === undefined || value === 0) {
            return 'ubv-amount ubv-amount_flat';
        }
        return value > 0 ? 'ubv-amount ubv-amount_up' : 'ubv-amount ubv-amount_down';
    }

    /**
     * The percentage, pre-formatted.
     *
     * Returns '' and never undefined. A getter bound to a custom element's ATTRIBUTE is
     * written unconditionally, so returning undefined renders the literal string "undefined"
     * on screen - a defect this repo has shipped before. Returning an empty string is the
     * only safe default, and the assertion that protects it must be on the RENDERED text,
     * not on the getter.
     */
    get percentLabel() {
        if (this.totalVariancePct === null || this.totalVariancePct === undefined) {
            return '';
        }
        const sign = this.totalVariancePct > 0 ? '+' : '';
        return `${sign}${this.totalVariancePct}%`;
    }

    /** Prior-bill caption, empty rather than undefined for the same reason as above. */
    get priorLabel() {
        return this.priorBillLabel || '';
    }

    /**
     * Whether the two components still add up to the total.
     *
     * A tolerance of half a cent absorbs the currency fields' own 2-decimal rounding without
     * hiding a real discrepancy - a sign error is off by twice the component, never by a
     * fraction of a cent.
     */
    get reconciles() {
        if (!this.showBreakdown) {
            return true;
        }
        const parts = (this.usageVariance || 0) + (this.rateVariance || 0);
        return Math.abs(parts - this.totalVariance) < 0.005;
    }

    get showReconciliationWarning() {
        return this.showBreakdown && !this.reconciles;
    }
}
