/**
 * c-call-for-offers-list — the call-for-offers table for the ACQUISITION app's Lead Funnel tab.
 *
 * Lists the MATCHED OPPORTUNITIES — deals that already carry a call-for-offers due date — with
 * property name, due date and days remaining, property name linking to the deal.
 * It deliberately does NOT list gated `Inbound_Email_Staging__c` rows: those are emails the pipeline
 * declined to make a Lead from, and a table of them would answer a different question.
 *
 * ── ⚠ SUPERSEDED 2026-08-17 — THE "RECEIVED" COLUMN WAS REMOVED (user request) ───────────────
 * RETRACTED, verbatim: "⚠ THE 'RECEIVED' COLUMN CARRIES TWO DIFFERENT FACTS AND NAMES THE SECOND
 * ONE IN WORDS — see the `receivedLabel` helper below before touching it. Collapsing them is a
 * one-line change that reintroduces a defect nobody can see on screen."
 *
 * That warning guarded a column this table no longer renders, so the `receivedLabel` helper it
 * pointed at is gone too. 🔴 IT IS NOT A LICENCE TO COLLAPSE THE SERVER'S TWO FIELDS. The DTO still
 * carries `receivedDate` (the stamped `Call_For_Offers_Received_Date__c` — when a call-for-offers
 * email actually reached DPEG) and `dealArrivedDate` (when the DEAL arrived) as SEPARATE facts, and
 * `CallForOffersService` header §4 plus `receivedDateIsTheStampedFieldAndNeverTheProxy` still
 * enforce the split. Removing a column is not evidence the distinction died — this component simply
 * stopped displaying it. Anything reinstating a received/arrival cell must re-read that §4 first.
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
 *
 * ── 🔴 THE PALETTE HAS TWO FAMILIES, AND THE BOUNDARY BETWEEN THEM CARRIES MEANING ──────────
 * ORANGE = a deadline still ahead of you (APPROACHING, CRITICAL). RED = a deadline you have hit or
 * passed (DUE_TODAY, OVERDUE). That line is the whole point of the map, and it is the one thing not
 * to blur when adding or retuning a band.
 *
 * ⚠ AMENDED 2026-08-17 — CRITICAL MOVED OUT OF THE RED FAMILY (user request, after seeing it live).
 * RETRACTED, verbatim: `CRITICAL: ['#fdeaea', '#e53935']`. It shared OVERDUE's and DUE_TODAY's
 * `#fdeaea` background, so "Due in 2 days" and "Overdue by 2 days" rendered as the same pale pink
 * cell — two rows sitting adjacent in this table, saying opposite things, looking identical. Colour
 * is the fast read on a table this size, so a deal two days OUT was being reported at a glance as a
 * deal already missed. Only CRITICAL was flagged and only CRITICAL moved: DUE_TODAY and OVERDUE stay
 * red, because for them "you have run out of time" is exactly what red should say.
 *
 * ⚠ CRITICAL IS DELIBERATELY DEEPER THAN APPROACHING RATHER THAN A SECOND SHADE OF IT — the 1-3 day
 * window has to read as more pressed than the 4-7 day one, or the two thirds of the map that are
 * still "ahead of you" collapse into one indistinguishable band and the ladder stops being visible.
 * The two are one step apart in both channels (background #fff1e0 -> #ffe8cc, dot #fb8c00 -> #e65100).
 *
 * 🔴 NO THRESHOLD APPEARS IN THIS FILE AND NONE MAY BE ADDED. These are the six
 * `CallForOffersService.Urgency` members, recoloured; the DAY COUNTS that decide which member a deal
 * gets (7 / 3 / 1 / 0) live in that service, which `CallForOffersAlertBatch` also fires on. Retuning
 * a colour here is a display change. Retuning a boundary is a server change.
 */
const URGENCY = {
    NO_DUE_DATE: ['#eceff1', '#90a4ae'],
    SCHEDULED: ['#e8f5e9', '#43a047'],
    APPROACHING: ['#fff1e0', '#fb8c00'],
    CRITICAL: ['#ffe8cc', '#e65100'],
    DUE_TODAY: ['#fdeaea', '#c62828'],
    OVERDUE: ['#fdeaea', '#b71c1c']
};
const FALLBACK = ['#eef1f4', '#94a3b8'];

const pillWrap = (bg) =>
    `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    {
        label: 'Deal',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'propertyName' }, target: '_self' }
    },
    { label: 'Due Date', fieldName: 'dueLabel', type: 'text', initialWidth: 130 },
    // ⚠ LABEL-ONLY RENAME 2026-08-17 ('Days Remaining' -> 'Urgency', 'Offers Due' -> 'Due Date').
    // NOTHING BELOW THE LABEL CHANGED, AND THAT IS THE WHOLE POINT: `fieldName`, `type: 'pill'` and
    // both `typeAttributes` are untouched, so the cell still renders `CallForOffersService`'s OWN
    // label ("Due in 21 days" / "Overdue by 3 days") coloured by that service's six-state `Urgency`
    // ladder via the `URGENCY` map above.
    //
    // 🔴 THE NEW HEADER NAMES A DERIVED BAND, WHICH IS EXACTLY WHAT THE CELL ALREADY SHOWS — SO DO
    // NOT READ 'Urgency' AS AN INVITATION TO COMPUTE ONE HERE. The class header's §"DATA ACCESS"
    // note stands unchanged: the ladder is a RULE that `CallForOffersAlertBatch` also fires on and
    // `c-call-for-offers-panel` also paints, so a client-side day count would put a second copy of
    // it in a second language, and the first symptom of the drift would be this table calling a deal
    // urgent while the alert job disagreed.
    {
        label: 'Urgency',
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
