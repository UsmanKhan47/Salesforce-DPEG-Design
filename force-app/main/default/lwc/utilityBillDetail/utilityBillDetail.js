import { LightningElement, api, wire } from 'lwc';
import getBillDetail from '@salesforce/apex/UtilityBillController.getBillDetail';

/**
 * c-utility-bill-detail - the Utility Bill record page panel: readings, charge components
 * and the FSD 5.10.5 variance decomposition.
 *
 * ── WHY IMPERATIVE-SHAPED APEX AND NOT LDS ──────────────────────────────────
 * ARCHITECTURE.md section 5 is LDS-first, and this component is the documented exception:
 * "Imperative Apex only when LDS cannot express the query (complex joins, aggregates)". One
 * render needs THREE objects at once - the bill, its PRIOR bill's totals (a self-lookup
 * traversal), and every Charge_Line__c child - plus two derived figures. `getRecord` would
 * be three wires and a client-side join; GraphQL cannot express the derived percentage that
 * this feature must NOT read from the stored field (see below). One cacheable Apex call is
 * both fewer round-trips and the only place the percentage can be computed once.
 *
 * ── 🔴 THE PERCENTAGE COMES FROM APEX, NOT FROM THE FIELD ───────────────────
 * `Utility_Bill__c.Total_Variance_Pct__c` is currently 100x its true value: its formula ends
 * in `* 100` and the platform ALSO scales a Percent formula result, so the multiplication
 * happens twice (measured on `usman-dpeg` 2026-08-22: a rise from $100 to $200 returns
 * 10000). `UtilityBillController.variancePct` derives the honest figure from the two totals.
 * DO NOT swap this component onto `getRecord` for that field until the formula is corrected
 * AND re-measured.
 */
export default class UtilityBillDetail extends LightningElement {
    @api recordId;

    detail;
    error;

    @wire(getBillDetail, { billId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.detail = data;
            this.error = undefined;
        } else if (error) {
            // Never silently swallowed: an unhandled wire error renders as a permanently
            // empty panel, which is indistinguishable from a bill with no data.
            this.error = error;
            this.detail = undefined;
        }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load this utility bill.';
    }

    get hasDetail() {
        return !!this.detail;
    }

    /** True only when the bill loaded AND is empty of charge components. */
    get hasNoChargeLines() {
        return this.hasDetail && this.detail.chargeLines.length === 0;
    }

    get chargeLineCount() {
        return this.hasDetail ? this.detail.chargeLines.length : 0;
    }

    /**
     * The charge components, each with its share pre-formatted.
     *
     * `sharePct` is null when the bill totals zero, and `shareLabel` returns '' for that
     * rather than undefined: a getter bound to an element's attribute is written
     * UNCONDITIONALLY, so an undefined renders the literal string "undefined" on screen.
     */
    get chargeRows() {
        if (!this.hasDetail) {
            return [];
        }
        return this.detail.chargeLines.map((line) => ({
            ...line,
            shareLabel:
                line.sharePct === null || line.sharePct === undefined
                    ? ''
                    : `${line.sharePct}% of bill`
        }));
    }

    /** Caption naming the bill the variance is measured against; '' when there is none. */
    get priorBillLabel() {
        if (!this.hasDetail || !this.detail.hasPrior) {
            return '';
        }
        const name = this.detail.priorBillName || 'the prior bill';
        return this.detail.priorReadDate ? `${name} (read ${this.detail.priorReadDate})` : name;
    }

    get hasPrior() {
        return this.hasDetail && this.detail.hasPrior === true;
    }

    /**
     * Present when `UtilityBillDomain` REFUSED to compute a consumption because it could not
     * tell a register rollover from a meter swap. Not the same as "not filled in yet".
     */
    get consumptionWarning() {
        return this.hasDetail ? this.detail.consumptionWarning : undefined;
    }

    get hasConsumptionWarning() {
        return !!this.consumptionWarning;
    }

    /** Meter caption, '' rather than undefined for the attribute-stringification reason. */
    get meterLabel() {
        if (!this.hasDetail) {
            return '';
        }
        const parts = [this.detail.utilityType, this.detail.meterNumber].filter(Boolean);
        return parts.join(' · ');
    }

    get locationLabel() {
        if (!this.hasDetail) {
            return '';
        }
        const parts = [this.detail.propertyName, this.detail.unitLabel].filter(Boolean);
        return parts.join(' · ');
    }
}
