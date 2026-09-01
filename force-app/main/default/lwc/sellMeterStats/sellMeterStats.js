import { LightningElement, wire } from 'lwc';
import { formatMoney } from 'c/utils';
import getMeterSummary from '@salesforce/apex/SellMeterController.getMeterSummary';

export default class SellMeterStats extends LightningElement {
    data;
    error;

    @wire(getMeterSummary)
    wired({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }

    /**
     * The summary tiles, in render order.
     *
     * ── 🔴 FIVE TILES SINCE 2026-08-31, NOT FOUR, AND THAT IS A RECORDED DECISION ──
     * Story 9 asked for a green-band-only upside figure and its acceptance criteria describe FOUR
     * cards. The design recommended NARROWING `Portfolio Upside` to green-only and RENAMING it to
     * "Sell-Ready Upside", which would have kept the count at four. The user decided otherwise at
     * Gate 1 (2026-08-31): keep the portfolio-wide number exactly as it is, under its existing
     * label, and ADD the green-only number beside it.
     *
     * So this card deliberately diverges from story 9's four-card AC while satisfying its
     * substantive one (a green-only upside figure exists and is shown). Nothing shrank and nothing
     * was renamed — a headline number that quietly drops by ~75-80% under an unchanged label is
     * the shape that gets reported as a data bug, and showing both makes the relationship
     * ("of the total upside on the meter, this much is actionable today") legible instead.
     *
     * ⚠ DO NOT "FINISH" THE RECOMMENDED NARROWING LATER. It was declined, not deferred.
     *
     * ⚠ THE PLACEMENT IS DELIBERATE: Sell-Ready Upside sits immediately AFTER Portfolio Upside, so
     * the pair reads as subset-then-superset in one glance. Separating them, or putting the
     * green-only figure first, breaks the only thing that makes two money tiles comprehensible
     * next to each other.
     *
     * ⚠ THE HARD-CODED `iconColor` HEX VALUES ARE PRE-EXISTING AND ARE NOT IN THIS CHANGE'S SCOPE.
     * They are passed as an ATTRIBUTE to c-stat-card, not written in CSS, so an SLDS 2 token would
     * have to resolve in JS. The new tile introduces NO new colour — it reuses `#3fae5e`, already
     * on the "Sell now" tile above, which is exactly the band it counts. Adding a sixth colour
     * here would be a new deviation; reusing one is not.
     */
    get metrics() {
        const s = this.data || {};
        return [
            { key: 'green',  label: 'Sell now',          value: s.green != null ? String(s.green) : '0',   iconName: 'utility:check',    iconColor: '#3fae5e' },
            { key: 'yellow', label: 'Getting Close',     value: s.yellow != null ? String(s.yellow) : '0', iconName: 'utility:list',     iconColor: '#c98a33' },
            { key: 'red',    label: 'Hold - Not yet',    value: s.red != null ? String(s.red) : '0',       iconName: 'utility:pause',    iconColor: '#e0556b' },
            { key: 'up',     label: 'Portfolio Upside',  value: formatMoney(s.upside),                     iconName: 'utility:money',    iconColor: '#2BAFAC' },
            { key: 'ready',  label: 'Sell-Ready Upside', value: formatMoney(s.sellReadyUpside),            iconName: 'utility:trending', iconColor: '#3fae5e' }
        ];
    }
}