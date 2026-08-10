/**
 * c-listing-alerts — the Active Listing TRACTION MONITOR on the Disposition record page.
 *
 * ── 🔴 WHAT THIS REPLACED, AND WHY THE REPLACEMENT WAS MANDATORY (D28/Q4) ───
 * The previous version's `.js` was a two-line stub, but its `.html` was a hardcoded 22-line mock
 * that rendered four rows AS FACT:
 *
 *     Day 21   ->  No offers -> email to Junior
 *     Week 4   ->  YELLOW flag on Junior dashboard
 *     Week 6   ->  Hard prompt + alert to Junior + Ali
 *     Offer in ->  Clock PAUSES - Disposition Offer created
 *
 * Every one of those four rows was wrong in its own way. Rows 1-3 advertised the 6-WEEK CLOCK that
 * D27.1 overturned (the document allows ~2 months with a month-1 check). Rows 1 and 3 promised
 * NOTIFICATIONS that D9 defers and that nothing in this org sends — the module has zero
 * notification types and no flow referencing Disposition__c. Row 4 asserted a "Clock PAUSES" rule
 * that appears in NO document, NO decision and NO code. A component rendering a fixed lie is worse
 * than an empty one, because nothing looks broken.
 *
 * ── 🔴 IT STILL RAISES NO ALERT, AND THE NAME IS KEPT ON PURPOSE ────────────
 * D9 defers every notification in this programme including the month-1 traction alert. The
 * MECHANISM (compute the status, surface it) is in scope; an email, a custom notification or a
 * Chatter post is not. Nothing below promises anyone will be told, and the two deferred rows are
 * gone rather than reworded.
 *
 * The bundle keeps the name `listingAlerts` deliberately, rather than being renamed to something
 * like `listingTraction`: renaming means deleting a bundle that `dispositionMain.html` references
 * and creating another in the same deploy, for a cosmetic gain — and when D9's alert is eventually
 * built, THIS is the component it surfaces on, so the name becomes right again rather than
 * needing a second rename. The header text says what it actually shows.
 *
 * ── DATA ACCESS: APEX, NOT LDS, AND THE REASON IS THE §5 EXCEPTION ──────────
 * ARCHITECTURE.md §5 is LDS-first, and this component deliberately takes the "business logic must
 * be enforced server-side" exception. The band is a RULE (60-day clock, 30-day checkpoint, offers
 * only) that `lwc/brokerListing` renders the badge half of on the SAME screen. Computing it in JS
 * would put a second copy of that ladder in a second language where it would drift, and the first
 * symptom would be a badge and a panel contradicting each other about whether to replace a broker.
 * LDS also cannot supply the input: `getRelatedListRecords` returns a PAGE of offers, not a count.
 *
 * ── ⚠ RESIDUAL: THIS PANEL CAN LAG A JUST-LOGGED OFFER (review W1, 2026-08-10) ──────────────
 * `getTraction` is `@AuraEnabled(cacheable=true)` and this component holds no wire result and calls
 * no `refreshApex`, so after a user logs an offer from `c-disposition-offer` in the SIDEBAR, that
 * card's LDS related-list wire refreshes while this panel may keep rendering the payload it already
 * has — showing "Month one has passed with no offers…" beside a list containing an offer. A page
 * reload always shows the true band; the window itself was not measured, so none is claimed.
 *
 * 🔴 THE OBVIOUS FIX IS NOT AVAILABLE HERE, AND THAT IS MEASURED, NOT ASSUMED. A CustomEvent from
 * `c-disposition-offer` relayed by `c-disposition-main` cannot reach this component: per
 * `flexipages/Disposition_Record_Page.flexipage-meta.xml`, `dispositionMain` is in the `main` region
 * and `dispositionSidebar` — the only renderer of `c-disposition-offer` — is in the `sidebar`
 * region, so there is no shared ancestor for an event to travel through. Crossing regions needs
 * Lightning Message Service, and this repo has no `messageChannels/` directory at all. If you build
 * it: `refreshApex` on a retained wire result is the tool, NOT `getRecordNotifyChange` — the band is
 * an Apex computation, not a field on the Disposition record. Full reasoning and the accepted-
 * residual decision are in `DispositionTractionService`'s §3 header block.
 *
 * @see force-app/main/default/classes/DispositionTractionController.cls
 * @see force-app/main/default/classes/DispositionTractionService.cls (the band ladder)
 */
import { LightningElement, api, wire } from 'lwc';
import getTraction from '@salesforce/apex/DispositionTractionController.getTraction';

const MONTHS = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
];

/** Band -> the CSS modifier the badge and the clock bar carry. */
const BAND_THEME = {
    NOT_LISTED: 'muted',
    ON_TRACK: 'green',
    CHECKPOINT_DUE: 'yellow',
    REVIEW_OVERDUE: 'yellow',
    HARD_STOP: 'red'
};

export default class ListingAlerts extends LightningElement {
    /**
     * ⚠ REQUIRED, AND IT WAS NOT BEING PASSED. `dispositionMain.html` rendered
     * `<c-listing-alerts>` with no attributes while both of its siblings on the same row received
     * `record-id={recordId}` — harmless while the component was a static mock, fatal the moment it
     * reads anything. That template gains the attribute in the same change.
     */
    @api recordId;

    traction;
    error;

    @wire(getTraction, { dispositionId: '$recordId' })
    wiredTraction({ data, error }) {
        if (data) {
            this.traction = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.traction = undefined;
        }
    }

    get hasError() {
        return !!this.error;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }

    /** True only while the wire has produced neither data nor an error. */
    get isLoading() {
        return !this.traction && !this.error;
    }

    get hasTraction() {
        return !!this.traction && !this.error;
    }

    get badgeClass() {
        const theme = BAND_THEME[this.traction && this.traction.band] || 'muted';
        return `band-badge band--${theme}`;
    }

    /**
     * Percentage of the 60-day marketing period elapsed, clamped to 0-100, as an inline width.
     * Purely decorative — the numbers beside it are the accessible representation.
     */
    get clockBarStyle() {
        const t = this.traction;
        if (!t || !t.isListed || !t.marketingPeriodDays) {
            return 'width: 0%;';
        }
        const pct = Math.min(
            100,
            Math.max(0, Math.round((t.daysOnMarket / t.marketingPeriodDays) * 100))
        );
        return `width: ${pct}%;`;
    }

    get clockBarClass() {
        const theme = BAND_THEME[this.traction && this.traction.band] || 'muted';
        return `clock-fill clock--${theme}`;
    }

    /**
     * The milestone rows. Built here rather than in the template so the template stays a list
     * render and every string that names a threshold comes from the server-computed payload —
     * no component in this bundle hardcodes 30 or 60.
     */
    get milestones() {
        const t = this.traction;
        if (!t) {
            return [];
        }
        if (!t.isListed) {
            return [
                {
                    key: 'clock',
                    term: 'Marketing clock',
                    value: 'Not started',
                    note: `Starts when a listing date is set (${t.marketingPeriodDays} days).`
                }
            ];
        }
        const offersLabel =
            t.offerCount === 1 ? '1 offer' : `${t.offerCount} offers`;
        return [
            {
                key: 'elapsed',
                term: 'Days on market',
                value: `${t.daysOnMarket} of ${t.marketingPeriodDays}`,
                note: `Listed ${this.formatDate(t.listingDate)}.`
            },
            {
                key: 'checkpoint',
                term: `Day ${t.checkpointDays} traction check`,
                value: this.formatDate(t.checkpointDate),
                note:
                    t.daysOnMarket >= t.checkpointDays
                        ? 'Reached.'
                        : `In ${t.checkpointDays - t.daysOnMarket} days.`
            },
            {
                key: 'hardstop',
                term: `Day ${t.marketingPeriodDays} marketing period ends`,
                value: this.formatDate(t.hardStopDate),
                note:
                    t.daysRemaining > 0
                        ? `${t.daysRemaining} days remaining.`
                        : 'Elapsed.'
            },
            {
                key: 'offers',
                term: 'Offers received',
                value: offersLabel,
                // The whole traction rule in one line, so the panel explains itself rather than
                // relying on the reader knowing D28/Q1.
                note:
                    t.offerCount > 0
                        ? 'An offer counts as traction.'
                        : 'No offers logged against this disposition.'
            }
        ];
    }

    formatDate(value) {
        if (!value) {
            return '—';
        }
        const parts = String(value).split('-');
        return `${MONTHS[parseInt(parts[1], 10) - 1]} ${parseInt(parts[2], 10)}, ${
            parts[0]
        }`;
    }
}
