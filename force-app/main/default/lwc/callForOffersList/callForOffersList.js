/**
 * c-call-for-offers-list — the call-for-offers table for the ACQUISITION app's Lead Funnel tab.
 *
 * Lists the MATCHED OPPORTUNITIES — deals that already carry a call-for-offers due date — with
 * received date, property name, due date and days remaining, property name linking to the deal.
 * It deliberately does NOT list gated `Inbound_Email_Staging__c` rows: those are emails the pipeline
 * declined to make a Lead from, and a table of them would answer a different question.
 *
 * ⚠ THE "RECEIVED" COLUMN CARRIES TWO DIFFERENT FACTS AND NAMES THE SECOND ONE IN WORDS — see the
 * `receivedLabel` helper below before touching it. Collapsing them is a one-line change that
 * reintroduces a defect nobody can see on screen.
 *
 * ── ⚠ IT LIVES ON THE LEAD FUNNEL TAB, NOT A HOME PAGE, AND THAT IS A SETTLED DECISION ───────
 * Requirements §9 C11 measured that the Acquisition app has NO home page at all: there is no
 * FlexiPage of type `HomePage` anywhere in `force-app`, and `Acquisition.app-meta.xml`'s tab list
 * carries no `standard-home`. Creating one would have edited the app file and changed every
 * acquisitions user's landing surface. The Lead Funnel tab (`flexipages/Lead_Funnel`) was chosen
 * instead, so `Acquisition.app-meta.xml` is NOT edited and nobody's landing surface moves.
 *
 * ── DATA ACCESS: APEX, NOT LDS, AND THE §5 EXCEPTION IS EXPLICIT ────────────
 * ARCHITECTURE.md §5 is LDS-first and this component takes the "business logic must be enforced
 * server-side" exception, for the same reason `lwc/listingAlerts` does. The urgency band is a RULE
 * (7 / 3 / 1 / 0 days) that `CallForOffersAlertBatch` also fires on and `c-call-for-offers-panel`
 * also paints. Computing "days remaining" in JS would put a second copy of that ladder in a second
 * language, and the first symptom of the drift would be a table calling a deal urgent while the
 * alert job disagreed. GraphQL cannot express it either — the band is a derivation, not a field.
 *
 * ── 🔴 ERRORS ARE SURFACED TWICE, ON PURPOSE ────────────────────────────────
 * The repo's house pattern for a `@wire` failure is a DISTINCT INLINE error state (rentRoll is the
 * reference), and the brief for this component additionally requires a TOAST. Both are rendered:
 * the inline banner is the durable, screen-reader-announced state (`role="alert"`) and survives a
 * dismissed toast; the toast is what makes the failure impossible to scroll past on a dashboard
 * where this is one card among several. Neither is optional.
 *
 * ⚠ THE TOAST IS FIRED ONCE PER DISTINCT ERROR, not once per wire delivery. A wire can re-deliver
 * the same error on every re-render, and a component that toasts each time turns one failure into a
 * stack of identical toasts — which is the same "stop reading them" failure the alert job's
 * idempotency marker exists to prevent, one layer up.
 *
 * 🔴 SILENTLY SWALLOWING THE ERROR BRANCH IS THE ONE THING THIS COMPONENT MUST NOT DO. That was a
 * real defect class found across eight components and fixed in the 2026-07-19 audit; do not
 * reintroduce it by "simplifying" `wiredDeals` down to `if (data)`.
 *
 * @see force-app/main/default/classes/CallForOffersController.cls
 * @see force-app/main/default/classes/CallForOffersService.cls (the one ladder)
 * @see force-app/main/default/lwc/callForOffersPanel/callForOffersPanel.js (the record-page twin)
 */
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getUpcoming from '@salesforce/apex/CallForOffersController.getUpcoming';

const FALLBACK_ERROR = 'Unable to load call for offers.';

/**
 * Urgency -> [background, dot] for the soft "days remaining" pill.
 * Keys are `CallForOffersService.Urgency` member NAMES. A miss falls through to FALLBACK, so a
 * stale key here degrades to a grey pill rather than an error — the `recentOpportunities` contract.
 */
const URGENCY = {
    NO_DUE_DATE: ['#eceff1', '#90a4ae'],
    SCHEDULED: ['#e8f5e9', '#43a047'],
    APPROACHING: ['#fff1e0', '#fb8c00'],
    CRITICAL: ['#fdeaea', '#e53935'],
    DUE_TODAY: ['#fdeaea', '#c62828'],
    OVERDUE: ['#fdeaea', '#b71c1c']
};
const FALLBACK = ['#eef1f4', '#94a3b8'];

const pillWrap = (bg) =>
    `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    {
        label: 'Property',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'propertyName' }, target: '_self' }
    },
    // ⚠ WIDER THAN ITS SIBLING ON PURPOSE. This cell renders either a bare date ("Jul 1, 2026")
    // or the labelled fallback "Deal arrived Jul 1, 2026" (see `receivedLabel`) — roughly 13
    // characters longer, and a datatable text cell truncates with an ellipsis. Left at the 130px
    // the bare date needed, the caveat is the part that disappears, leaving the reader looking at
    // a date whose qualification has been cut off — worse than either alternative.
    // ⚠ NOT MEASURED IN A BROWSER, and it cannot be from the Jest suite: jsdom performs no layout,
    // so every width and overflow read is 0 there. The suite asserts the CONFIGURED width only;
    // the rendered fit is a UAT check.
    { label: 'Received', fieldName: 'receivedLabel', type: 'text', initialWidth: 190 },
    { label: 'Offers Due', fieldName: 'dueLabel', type: 'text', initialWidth: 130 },
    {
        label: 'Days Remaining',
        fieldName: 'countdown',
        type: 'pill',
        initialWidth: 170,
        typeAttributes: { wrapStyle: { fieldName: 'pillWrap' }, dotStyle: { fieldName: 'pillDot' } }
    }
];

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * `Aug 20, 2026` from an ISO date string, WITHOUT `new Date(...)`.
 *
 * ⚠ `new Date('2026-08-20')` parses as UTC MIDNIGHT and then renders in the browser's local zone,
 * so west of Greenwich it displays as Aug 19 — an off-by-one on the one number this whole component
 * is about. Splitting the string has no time zone at all. The server sends the same format from
 * `CallForOffersService.formatDate`, and both are deliberately fixed rather than locale-derived.
 *
 * @param {string} value ISO `yyyy-mm-dd`, or null.
 * @returns {string} The formatted date, or an em dash.
 */
const formatDate = (value) => {
    if (!value) {
        return '—';
    }
    const parts = String(value).split('-');
    if (parts.length !== 3) {
        return '—';
    }
    return `${MONTHS[parseInt(parts[1], 10) - 1]} ${parseInt(parts[2], 10)}, ${parts[0]}`;
};

/**
 * What goes in the "Received" column.
 *
 * 🔴 TWO SOURCES, AND THE CELL SAYS WHICH ONE IT IS IN WORDS. `receivedDate` is
 * `Call_For_Offers_Received_Date__c` — the day a call-for-offers email for this deal actually
 * reached DPEG. `dealArrivedDate` is when the DEAL arrived (`Broker_First_Seen__c` / the
 * Opportunity's created date), which is a DIFFERENT FACT and was, until 2026-08-14, silently
 * rendered here as if it were the first one — months adrift on any deal whose broker relationship
 * predates the campaign.
 *
 * ⚠ THE PREFIX IS THE WHOLE POINT AND MUST NOT BECOME A GLYPH. A "~", an asterisk or a tooltip is
 * scanned past in a dense table; "Deal arrived" is read. Do not "clean this up" into
 * `formatDate(r.receivedDate || r.dealArrivedDate)` — that single expression IS the defect this
 * change removed, and it would be invisible in review because the column would still look right.
 * The server keeps the two apart for the same reason (`CallForOffersService` header §4).
 *
 * @param {object} row A `CallForOffersService.CallForOffers` row.
 * @returns {string} The cell text: a date, a labelled deal-arrival date, or an em dash.
 */
const receivedLabel = (row) => {
    if (row.receivedDate) {
        return formatDate(row.receivedDate);
    }
    if (row.dealArrivedDate) {
        return `Deal arrived ${formatDate(row.dealArrivedDate)}`;
    }
    return '—';
};

export default class CallForOffersList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    error;
    listUrl = '#';

    /** The message already toasted, so a re-delivered error does not toast twice. */
    _toastedMessage;

    @wire(getUpcoming)
    wiredDeals({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
            this._toastedMessage = undefined;
        } else if (error) {
            this.error = error;
            this.data = undefined;
            this.surfaceError();
        }
    }

    /** Toast the current error once. See the class header for why "once" matters. */
    surfaceError() {
        const message = this.errorMessage;
        if (this._toastedMessage === message) {
            return;
        }
        this._toastedMessage = message;
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Call for offers',
                message,
                variant: 'error',
                mode: 'sticky'
            })
        );
    }

    get hasError() {
        return !!this.error;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || FALLBACK_ERROR;
    }

    /** True only while the wire has produced neither data nor an error. */
    get isLoading() {
        return !this.data && !this.error;
    }

    get isEmpty() {
        return !!this.data && this.data.length === 0;
    }

    get rows() {
        if (!this.data) {
            return [];
        }
        return this.data.map((r) => {
            const [bg, dot] = URGENCY[r.urgency] || FALLBACK;
            return {
                id: r.opportunityId,
                recordUrl: r.recordUrl,
                propertyName: r.propertyName,
                receivedLabel: receivedLabel(r),
                dueLabel: formatDate(r.dueDate),
                // The SERVER's label, never a client-side day count — see the class header.
                countdown: r.label,
                pillWrap: pillWrap(bg),
                pillDot: pillDot(dot)
            };
        });
    }

    get count() {
        return this.rows.length;
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Opportunity', actionName: 'list' },
            state: { filterName: '__Recent' }
        };
    }

    handleViewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
