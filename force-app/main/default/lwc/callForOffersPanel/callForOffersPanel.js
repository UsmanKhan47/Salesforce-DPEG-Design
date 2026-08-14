/**
 * c-call-for-offers-panel — the single-deal call-for-offers panel for the Opportunity record page.
 *
 * Shows the offer due date, the days remaining with a COLOUR-CODED URGENCY BADGE, the sale process,
 * the listing broker and the deal room link. It is the record-page twin of
 * `c-call-for-offers-list`, and both render from `CallForOffersService` — so the badge here and the
 * pill in the table cannot disagree about whether a deal is urgent, and neither can disagree with
 * `CallForOffersAlertBatch` about whether it is owed an alert. That is the point of the shared
 * service, and it is why NO threshold appears in this file.
 *
 * ── ✅ PLACED ON THE PAGE ────────────────────────────────────────────────────
 * ⚠ THIS BLOCK USED TO READ *"NOT YET PLACED ON THE PAGE … the user is holding it"* and that STATUS
 * IS SUPERSEDED, not merely reworded. `Opportunity_Record_Page` carries this bundle in the
 * `sidebar` region at position 3 — after `brokerFirmCard` and `dealDocStatus`, and directly above
 * the tabset whose first tab is Activity, which is the placement the held edit described.
 *
 * The RISK PARAGRAPH below is still true and still governs; it has simply moved from being a
 * warning about an upcoming edit to being a warning about the NEXT one, and it belongs to the
 * runbook rather than to this bundle. That page is the highest-risk declarative surface in the
 * pack: it carries custom-permission visibility rules and a heavily-ordered region, a FlexiPage
 * deploy can roll back with a design-time error that REPORTS AS SUCCESS, and enabling Dynamic
 * Actions on it silently discards the inherited layout action list. Retrieve the live page, edit,
 * deploy, and READ THE DEPLOYED RESULT BACK.
 *
 * ── DATA ACCESS: APEX, NOT LDS — THE §5 EXCEPTION, STATED ───────────────────
 * ARCHITECTURE.md §5 is LDS-first. `getRecord` could fetch `Offer_Due_Date__c` and the other four
 * stored fields, but it cannot supply the BAND, the countdown or the label — those are a server-side
 * rule. Fetching the fields with LDS and computing the ladder here would put a second copy of it in
 * JS, where it would drift from the one the alert job fires on. Same exception, same reason, as
 * `lwc/listingAlerts`.
 *
 * ── 🔴 ERRORS ARE SURFACED TWICE, ON PURPOSE ────────────────────────────────
 * An inline `role="alert"` banner (the repo's house pattern for a `@wire` failure — rentRoll is the
 * reference) AND a toast, fired ONCE per distinct message. The inline state is durable and
 * screen-reader-announced; the toast is what stops a failure being scrolled past on a long record
 * page. Silently swallowing the error branch is the defect class fixed across eight components in
 * the 2026-07-19 audit — do not reintroduce it by reducing `wiredState` to `if (data)`.
 *
 * ── ⚠ THE COUNTDOWN CAN BE STALE ON THE CLIENT, AND THAT IS ACCEPTED ────────
 * `getForOpportunity` is `cacheable=true` and nothing in this feature invalidates the client cache.
 * The exposure is bounded: the value changes at most once a day, no component on this page edits
 * `Offer_Due_Date__c`, and a reload always shows the truth. If an editor is ever added to this page,
 * `refreshApex` on a retained wire result is the tool — NOT `getRecordNotifyChange`, because the
 * band is an Apex computation and not a field on the record. (`DispositionTractionService`'s header
 * records the measured version of this trap.)
 *
 * @see force-app/main/default/classes/CallForOffersController.cls
 * @see force-app/main/default/classes/CallForOffersService.cls (the one ladder)
 * @see force-app/main/default/lwc/callForOffersList/callForOffersList.js (the tab twin)
 */
import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getForOpportunity from '@salesforce/apex/CallForOffersController.getForOpportunity';

const FALLBACK_ERROR = 'Unable to load the offer deadline.';

/**
 * Urgency -> the CSS modifier the badge carries. Keys are `CallForOffersService.Urgency` member
 * NAMES; a miss falls through to `muted`, so a stale key degrades to a grey badge rather than an
 * error. The colours themselves are SLDS 2 tokens in the stylesheet, not here.
 */
const BAND_THEME = {
    NO_DUE_DATE: 'muted',
    SCHEDULED: 'green',
    APPROACHING: 'amber',
    CRITICAL: 'red',
    DUE_TODAY: 'red',
    OVERDUE: 'red'
};

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * `Aug 20, 2026` from an ISO date string, WITHOUT `new Date(...)`.
 *
 * ⚠ `new Date('2026-08-20')` parses as UTC MIDNIGHT and then renders in the browser's local zone,
 * so west of Greenwich it displays as Aug 19 — an off-by-one on the one number this panel is about.
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

export default class CallForOffersPanel extends LightningElement {
    /** The Opportunity. Supplied by the record page. */
    @api recordId;

    state;
    error;

    /** The message already toasted, so a re-delivered error does not toast twice. */
    _toastedMessage;

    @wire(getForOpportunity, { opportunityId: '$recordId' })
    wiredState({ data, error }) {
        if (data) {
            this.state = data;
            this.error = undefined;
            this._toastedMessage = undefined;
        } else if (error) {
            this.error = error;
            this.state = undefined;
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
                title: 'Offer deadline',
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
        return !this.state && !this.error;
    }

    get hasState() {
        return !!this.state && !this.error;
    }

    /** True when the deal has no deadline — a real, renderable answer, not an empty box. */
    get hasNoDeadline() {
        return this.hasState && !this.state.hasDueDate;
    }

    get hasDeadline() {
        return this.hasState && !!this.state.hasDueDate;
    }

    get badgeClass() {
        const theme = BAND_THEME[this.state && this.state.urgency] || 'muted';
        return `cfo-badge cfo-badge--${theme}`;
    }

    /** The badge text. The SERVER's label — this component never counts days itself. */
    get badgeLabel() {
        return (this.state && this.state.label) || '';
    }

    get detail() {
        return (this.state && this.state.detail) || '';
    }

    /**
     * The panel's rows. Built here rather than in the template so the template stays a list render
     * and every value that could be blank is normalised in ONE place.
     */
    get rows() {
        const s = this.state;
        if (!s || !s.hasDueDate) {
            return [];
        }
        return [
            { key: 'due', term: 'Offers due', value: formatDate(s.dueDate) },
            {
                key: 'remaining',
                term: 'Days remaining',
                value: s.daysRemaining === null || s.daysRemaining === undefined
                    ? '—'
                    : String(s.daysRemaining)
            },
            { key: 'process', term: 'Sale process', value: s.saleProcess || '—' },
            { key: 'broker', term: 'Listing broker', value: s.listingBrokerName || '—' }
        ];
    }

    get brokerEmail() {
        return (this.state && this.state.listingBrokerEmail) || null;
    }

    get hasBrokerEmail() {
        return !!this.brokerEmail;
    }

    get brokerMailto() {
        return this.hasBrokerEmail ? `mailto:${this.brokerEmail}` : '#';
    }

    get dealRoomLink() {
        return (this.state && this.state.dealRoomLink) || null;
    }

    get hasDealRoomLink() {
        return !!this.dealRoomLink;
    }
}
