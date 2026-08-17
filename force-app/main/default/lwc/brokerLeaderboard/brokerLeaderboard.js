import { LightningElement, api, wire } from 'lwc';
import getLeaderboard from '@salesforce/apex/BrokerLeaderboardController.getLeaderboard';

/**
 * c-broker-leaderboard  (Broker Protection — FSD §27.3 / §27.4)
 * ---------------------------------------------------------------------------
 * Read-only ranking of the brokers sending DPEG inbound deals, computed live from
 * the Competing_Broker_Submission__c ledger. Designed for the Acquisitions
 * Broker Hub, alongside c-brokers-list and c-top-brokers.
 *
 * Data access: one reactive `@wire(getLeaderboard, { maxRows: '$maxRows' })`. The
 * controller method is `@AuraEnabled(cacheable=true)`, so a wire is the idiomatic
 * consumer — LDS-first per ARCHITECTURE.md §5, and LDS cannot express a GROUP BY
 * aggregate, which puts this at the correct next tier. No imperative Apex, no DML,
 * no row actions.
 *
 * 🔴 THE COMPONENT COMPUTES NOTHING ABOUT THE RANKING. Rank, win rate, counts and
 * the tie-break order are all decided by BrokerLeaderboardService and arrive
 * finished. That is deliberate: a second copy of the ranking rule in JavaScript is
 * how two surfaces end up disagreeing about who is top. Everything below is pure
 * presentation — formatting, an em dash for nulls, and the pill colouring.
 *
 * ⚠ "Properties Won" MEANS THE BROKER WON THE PROPERTY CLAIM (first-broker-wins),
 * NOT that DPEG closed the deal. Deal outcome is a different, deliberately
 * unbuilt metric — see BrokerLeaderboardService's header. Do not relabel it.
 */

// Win-rate pill: [background, dot]. Bands are presentational only — nothing
// downstream reads them and no threshold in Apex corresponds to them.
const RATE_BANDS = [
    { min: 50, style: ['#e8f5e9', '#43A047'] },
    { min: 20, style: ['#fff8e1', '#F9A825'] },
    { min: 0, style: ['#eceff1', '#90A4AE'] }
];
const pillWrap = (bg) =>
    `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) =>
    `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const EM_DASH = '—';

const COLUMNS = [
    { label: '#', fieldName: 'rank', type: 'text', initialWidth: 48 },
    { label: 'Broker', fieldName: 'brokerLabel', type: 'text', wrapText: true },
    { label: 'Email', fieldName: 'brokerEmail', type: 'email' },
    { label: 'Submissions', fieldName: 'submissions', type: 'text' },
    { label: 'Properties Won', fieldName: 'propertiesWon', type: 'text' },
    {
        label: 'Win Rate',
        fieldName: 'winRateLabel',
        type: 'pill',
        typeAttributes: {
            wrapStyle: { fieldName: 'rateWrap' },
            dotStyle: { fieldName: 'rateDot' }
        }
    },
    {
        label: 'First Submission',
        fieldName: 'firstSubmitted',
        type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' }
    },
    {
        label: 'Last Submission',
        fieldName: 'lastSubmitted',
        type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' }
    }
];

export default class BrokerLeaderboard extends LightningElement {
    /**
     * How many rows to request. Exposed so App Builder can shorten the card in a
     * narrow region; the server clamps it (BrokerLeaderboardService.MAX_ROWS_CEILING),
     * so a bad value cannot widen the read.
     */
    @api maxRows = 10;

    columns = COLUMNS;
    _data;
    error;

    @wire(getLeaderboard, { maxRows: '$maxRows' })
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this.error = undefined;
        } else if (error) {
            // Clear the list rather than leaving stale rows beside an error banner —
            // a ranking shown next to "could not be loaded" is worse than no ranking.
            this._data = undefined;
            this.error = error;
        }
    }

    /** Display rows. Server values pass through untouched; only labels are built. */
    get rows() {
        return (this._data || []).map((r) => {
            const rate = r.winRatePct == null ? 0 : r.winRatePct;
            const [bg, dot] = this.bandFor(rate);
            return {
                brokerEmail: r.brokerEmail,
                brokerLabel: r.brokerName || EM_DASH,
                rank: r.rank,
                submissions: r.submissions,
                propertiesWon: r.propertiesWon,
                winRateLabel: `${rate}%`,
                rateWrap: pillWrap(bg),
                rateDot: pillDot(dot),
                firstSubmitted: r.firstSubmitted,
                lastSubmitted: r.lastSubmitted
            };
        });
    }

    /** Presentational band for a win-rate percentage. */
    bandFor(rate) {
        const band = RATE_BANDS.find((b) => rate >= b.min);
        return band ? band.style : RATE_BANDS[RATE_BANDS.length - 1].style;
    }

    get count() {
        return this.rows.length;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get hasError() {
        return !!this.error;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }
}
