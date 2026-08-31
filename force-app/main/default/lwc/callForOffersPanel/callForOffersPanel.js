/**
 * c-call-for-offers-panel — the single-deal call-for-offers panel for the Opportunity record page.
 *
 * Shows the offer deadline with a COLOUR-CODED URGENCY PILL, the date a call-for-offers email reached
 * DPEG (when one has), and the deal room link — as up to three compact rows in the same visual
 * grammar as `c/dealDocStatus`, the card directly above it in the sidebar (see the template header;
 * an earlier hero-date layout was rejected as off-theme). It is the record-page
 * twin of `c-call-for-offers-list`, and both render from `CallForOffersService` — so the pill here
 * and the pill in the table cannot disagree about whether a deal is urgent, and neither can disagree
 * with `CallForOffersAlertBatch` about whether it is owed an alert. That is the point of the shared
 * service, and it is why NO threshold appears in this file.
 *
 * ── ⚠ 2026-08-17: SALE PROCESS AND LISTING BROKER WERE REMOVED (user decision) ───
 * The panel used to render a four-row definition list — Offers due, Days remaining, Sale process,
 * Listing broker — plus an "Email listing broker" mailto. Sale process and the broker (BOTH the row
 * and the mailto link) were dropped as unwanted on this surface, and once they were gone the two
 * surviving rows were FULLY REDUNDANT: the badge already says "Due in 3 days" (= Days remaining) and
 * the `detail` sentence said "Offers are due Aug 20, 2026." (= Offers due). So the list went with
 * them rather than being restyled, and the due date became the deadline row's meta line.
 *
 * ── 🔴 2026-08-30: THE LISTING BROKER NAME IS BACK, AND `Offer Status` IS NEW ────
 * PARTIAL REVERSAL OF THE PARAGRAPH ABOVE, which is quoted rather than edited so the earlier
 * decision and its date survive. A later user decision (design Items 5(b) / 5(f), Q8) restored the
 * LISTING BROKER NAME. The reasoning is not "we changed our minds": Q8 refused to create a
 * `Source_Broker__c` field for the call-for-offers issuer on the grounds that
 * `Listing_Broker_Name__c` ALREADY HOLDS EXACTLY THAT — and that is only a valid refusal if the
 * existing field is surfaced somewhere. This panel is where.
 *
 * 🔴 THE REVERSAL IS NARROW AND THE REST OF THE 2026-08-17 DECISION STANDS UNCHANGED:
 *   • `saleProcess` is STILL NOT RENDERED.
 *   • The "Email listing broker" MAILTO is STILL GONE. The name is a plain label + value; it is
 *     not a link. `listingBrokerEmail` remains on the DTO and remains unrendered here.
 *   • `daysRemaining` is still never rendered as a bare number (see the next section).
 * `saleProcessAndTheMailtoStayRemoved` in the Jest suite is the surviving half of the original
 * absence test and is what makes re-adding either go red.
 *
 * `Offer Status` (`Offer_Status__c`) is a NEW field on the same change. Both new rows follow the
 * existing "absent, not blank" grammar: they render only when the server sends a value, because
 * every deal created before 2026-08-30 legitimately has no offer status (a picklist `<default>`
 * applies on insert and does not backfill) and plenty of deals have no listing broker recorded.
 * ⚠ THE STATUS IS DISPLAY ONLY. The alert suppression it describes is a WHERE clause in
 * `OpportunitySelector.queryCallForOffersAlerts`; no client logic keys on this string.
 *
 * 🔴 THE SERVER CONTRACT DID NOT CHANGE AND MUST NOT BE "TIDIED" TO MATCH. `CallForOffersService`
 * still returns `saleProcess` and `listingBrokerEmail` (and, since 2026-08-30, `offerStatus`), and
 * `OpportunitySelector.selectCallForOffersById` still selects them — because `c/callForOffersList`
 * and `CallForOffersAlertBatch` share that DTO and that query. Removing a field from either because
 * THIS component stopped reading it would break the other two surfaces. This was a client-only
 * change: no Apex, no permission set, no FlexiPage.
 *
 * ── ⚠ `daysRemaining` IS NO LONGER FORMATTED BY THIS COMPONENT AT ALL ───────
 * It used to be rendered as a bare number, which carried a real trap: `0` is falsy in JS, so a naive
 * `value || '—'` showed a deal that is DUE TODAY as having no countdown — on the one day it matters
 * most. The count now reaches the user ONLY through the server's own `label`, so that trap is
 * STRUCTURALLY GONE rather than fixed, and its regression test went with the number it guarded.
 * Anyone re-adding a raw day count must re-add the zero test with it.
 *
 * ── ✅ PLACED ON THE PAGE ────────────────────────────────────────────────────
 * `Opportunity_Record_Page` carries this bundle in the `sidebar` region at position 3 — after
 * `brokerFirmCard` and `dealDocStatus`, and directly above the tabset whose first tab is Activity.
 *
 * The RISK PARAGRAPH belongs to the runbook rather than to this bundle, and still governs the NEXT
 * page edit: that page is the highest-risk declarative surface in the pack — it carries
 * custom-permission visibility rules and a heavily-ordered region, a FlexiPage deploy can roll back
 * with a design-time error that REPORTS AS SUCCESS, and enabling Dynamic Actions on it silently
 * discards the inherited layout action list. Retrieve the live page, edit, deploy, and READ THE
 * DEPLOYED RESULT BACK. ⚠ The 2026-08-17 change did NOT touch the FlexiPage, so none of that was
 * exercised here.
 *
 * ── DATA ACCESS: APEX, NOT LDS — THE §5 EXCEPTION, STATED ───────────────────
 * ARCHITECTURE.md §5 is LDS-first. `getRecord` could fetch `Offer_Due_Date__c` and the other stored
 * fields, but it cannot supply the BAND, the countdown or the label — those are a server-side rule.
 * Fetching the fields with LDS and computing the ladder here would put a second copy of it in JS,
 * where it would drift from the one the alert job fires on. Same exception, same reason, as
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
 * @see force-app/main/default/classes/CallForOffersService.cls (the one ladder; header §4 governs
 *      the received date rendered here)
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
 *
 * ── ⚠ AMENDED 2026-08-17 — CRITICAL IS AMBER, NOT RED (user request) ────────
 * RETRACTED, verbatim: `CRITICAL: 'red'`. The complaint was raised against the TABLE twin, where
 * "Due in 2 days" and "Overdue by 2 days" rendered in the same pale red and read as the same state;
 * the fix is applied here too because the misstatement is the same one either way — a deadline still
 * two days AWAY should not be painted in the colour this card reserves for one already missed. Only
 * CRITICAL moved. DUE_TODAY and OVERDUE stay `red`, where "you have run out of time" is what red
 * should say.
 *
 * 🔴 THIS MAP IS COARSER THAN THE TABLE'S AND THAT IS THE EXISTING, DELIBERATE DESIGN — NOT DRIFT.
 * `c/callForOffersList` gives all six bands a distinct hex pair; this card has four themes, because
 * DUE_TODAY and OVERDUE have ALWAYS shared `red` here. Two reasons, and they are why CRITICAL takes
 * the EXISTING `amber` rather than a fifth deeper-orange modifier being invented for it:
 *
 *   • A record page renders EXACTLY ONE band at a time. The table's finer palette earns its keep by
 *     letting adjacent ROWS be compared; there is nothing here to compare against, so a shade that
 *     differs from APPROACHING's would carry no information a reader could act on. What DOES carry
 *     information is which FAMILY the badge is in — warning or error — and that is now correct.
 *   • The stylesheet's own header records that a `var(--slds-g-*, <literal>)` fallback describes only
 *     what renders when the hook is UNDEFINED, that its literals are otherwise unverified against a
 *     browser, and that NO gate in this pipeline catches a hook resolving to something unexpected
 *     (Jest asserts class names; the SLDS linter checks only that a hook was used). Adding a fifth
 *     theme means guessing at a "deeper warning" token nobody can verify from here — real risk, for
 *     the benefit ruled out above. `--slds-g-color-warning-*` is already in the file and already the
 *     right family.
 *
 * ⚠ The label text is what actually distinguishes the two amber bands, and it always has been: the
 * badge reads the SERVER's own words ("Due in 6 days" vs "Due in 2 days"), which is also why this
 * card stays readable without colour vision. Colour is reinforcement here, never the only carrier.
 */
const BAND_THEME = {
    NO_DUE_DATE: 'muted',
    SCHEDULED: 'green',
    APPROACHING: 'amber',
    CRITICAL: 'amber',
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

    /** Rendered in the NO-DEADLINE branch only; see the template for why. */
    get detail() {
        return (this.state && this.state.detail) || '';
    }

    /** The hero. `hasDueDate` gates the branch, so this is only read when a date exists. */
    get dueDateFormatted() {
        return formatDate(this.state && this.state.dueDate);
    }

    /**
     * `Call_For_Offers_Received_Date__c` VERBATIM.
     *
     * 🔴 NO FALLBACK. `dealArrivedDate` answers a different question and coalescing them is the
     * defect `CallForOffersService` header §4 exists to prevent.
     */
    get hasReceivedDate() {
        return !!(this.state && this.state.receivedDate);
    }

    get receivedDateFormatted() {
        return formatDate(this.state && this.state.receivedDate);
    }

    /**
     * `Opportunity.Offer_Status__c` — `Open` / `Submitted` / `Closed`, or nothing at all.
     *
     * 🔴 NO DEFAULT TO 'Open'. A picklist `<default>` applies on INSERT ONLY, so every deal that
     * predates the field carries null and always will. Substituting "Open" here would assert a
     * campaign state the record does not hold, on the one screen a human might use to notice the
     * gap. Absent, not blank, and not guessed.
     *
     * @returns {boolean} True when the server sent a status.
     */
    get hasOfferStatus() {
        return !!(this.state && this.state.offerStatus);
    }

    /** @returns {string} The status verbatim, or '' so nothing can render the word "undefined". */
    get offerStatus() {
        return (this.state && this.state.offerStatus) || '';
    }

    /**
     * `Opportunity.Listing_Broker_Name__c` — the broker who ISSUED this call for offers.
     *
     * ⚠ NOT the submitting broker. `LeadConvertService` states the distinction explicitly ("This is
     * the SUBMITTING broker; the OM's listing broker is a different person … Do not merge the
     * two"), and this panel is about the CAMPAIGN, so the listing broker is the right one here.
     *
     * 🔴 IT IS RENDERED AS TEXT, NEVER AS A MAILTO. The "Email listing broker" link was removed on
     * 2026-08-17 and that half of the decision was NOT reversed — see the class header.
     *
     * @returns {boolean} True when the deal records a listing broker.
     */
    get hasListingBroker() {
        return !!(this.state && this.state.listingBrokerName);
    }

    /** @returns {string} The listing broker's name, or '' rather than undefined. */
    get listingBrokerName() {
        return (this.state && this.state.listingBrokerName) || '';
    }

    get dealRoomLink() {
        return (this.state && this.state.dealRoomLink) || null;
    }

    get hasDealRoomLink() {
        return !!this.dealRoomLink;
    }
}
