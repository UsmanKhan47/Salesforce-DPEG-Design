/**
 * c-broker-listing — the listing card on the Active Listing stage of the Disposition record page.
 *
 * The traction badge and every offer-derived number come from ONE server computation
 * (`DispositionTractionService`, via `BrokerListingController.getListing`), shared with
 * `c-listing-alerts` on the same screen so the badge and the panel cannot contradict each other.
 * Since 2026-08-21 that badge reads "Week 4 — At Risk" (and its siblings) and the clock PAUSES at
 * the first offer — both server-side, both proven in `DispositionTractionServiceTest`. 🔴 NO
 * THRESHOLD AND NO BAND IS DERIVED IN THIS FILE.
 *
 * ── 🔴 THIS CARD IS NOW THE ONLY PLACE THAT LABEL RENDERS (UAT, 2026-08-21) ──
 * The user asked for the listing-traction display to go and for the automated alerts to stay, so
 * `c/listingAlerts` was cut back to the three-rung escalation schedule and lost its own copy of the
 * band pill. The label survived HERE and not there, deliberately: the comment on `.header-right` in
 * `brokerListing.html` is the reason — the label is why anyone presses the Replace Broker button
 * sitting next to it, and a Replace Broker button with no stated cause is worse than no label. It
 * also keeps `isAtRisk`'s amber icon tint from becoming the only surviving carrier of the state,
 * i.e. colour alone.
 * ⚠ SO THERE IS EXACTLY ONE COPY OF `tractionLabel` ON THE SCREEN. Do not re-add one to
 * `c/listingAlerts`, and do not delete this one without moving it — deleting it removes the one
 * string the user gave verbatim.
 *
 * ⚠ THE "Offers Received" TILE WENT IN THE SAME PASS ("No need to show count of disposition offers
 * as well"), and `BrokerListingController.ListingRow.offersReceived` went with it. The controller
 * still counts offers — the count decides the band and the pause — it just no longer ships the
 * number to this card.
 *
 * ── 🔴 THE REPLACE BROKER BUTTON, AND WHY IT IS NOT A DUPLICATE (2026-08-21) ─
 * `c/bovComparisonMatrix` already has a Replace Broker button — but `dispositionMain.html` renders
 * that matrix under `if:true={isBovOutreach}` and this listing cluster under
 * `if:true={isActiveListing}`, and the two are MUTUALLY EXCLUSIVE. So the existing button is
 * unreachable at Active Listing, which is the only stage the traction ladder operates in. This
 * button closes that gap; it does not fork anything:
 *
 *     c/brokerListing  ─┐
 *                        ├─> c/bovReplaceBrokerModal ─> BovController.replaceSelectedBroker
 *     c/bovComparisonMatrix ─┘                          ─> BovSubmissionService.replaceSelectedBroker
 *
 * 🔴 THE SERVER METHOD IS THE ONLY PLACE THE FOUR INVARIANTS LIVE — single-Selected exclusivity,
 * approval-status revocation, the savepoint, and the `BOV_Broker_Change__c` history row. A second
 * Apex path would be a fourth copy of them. Do not add one, and do not add a second modal bundle
 * either: that bundle's four non-obvious contracts (reason options sourced from `getPicklistValues`,
 * block-don't-degrade on a failed picklist read, "the returned message is the product, not a
 * receipt", stay-open-on-failure) would have to be duplicated verbatim and would drift.
 *
 * ── 🔴 WHAT THE BUTTON DOES ON AN OFF-MARKET DISPOSITION: IT DOES NOT RENDER ─
 * Off-market dispositions have no BOV submission at all — the broker is `Disposition__c.Broker__c`
 * directly, guarded by the `Broker_Lookup_Is_Off_Market_Only` validation rule — and
 * `BovSubmissionService.replaceSelectedBroker` swaps BOV_Submission__c rows, so it has nothing to
 * act on there. `canReplaceBroker` tests for a SELECTED SUBMISSION rather than for a record type,
 * so an off-market disposition (zero submissions, therefore no selected one) hides the button by
 * construction, with no record-type check to keep in step with the schema. ⚠ THE HONEST
 * CONSEQUENCE, STATED: replacing an off-market broker remains an edit to `Disposition__c.Broker__c`
 * on the record itself. This button does not offer to do it, rather than offering and failing.
 *
 * ⚠ `canReplaceBroker` MIRRORS `c/bovComparisonMatrix.canReplaceBroker` EXACTLY — "SOME row is
 * Selected", not "exactly one". Exclusivity is a SERVER invariant, so a second Selected row would
 * be a data defect, and hiding the very button that repairs it is the wrong response to one. Two
 * buttons, one visibility rule; do not "tighten" this one alone.
 *
 * ── 🔴 BOTH WIRES ARE HELD AS WHOLE RESULTS, NOT DESTRUCTURED ───────────────
 * `refreshApex` REQUIRES the un-destructured wire result object — it cannot re-provision a wire
 * from a `{ data, error }` pair. A "tidying" edit back to `wired({ data, error })` compiles, passes
 * every render test, and silently turns the post-replace refresh into a no-op, leaving the card
 * showing the OLD broker beside a toast announcing the new one.
 *
 * ⚠ THE LISTING WIRE IS REFRESHED TOO, NOT JUST THE SUBMISSIONS WIRE, and that is deliberate:
 * `Broker_Firm__c` / `Contact_Name__c` on this card come from `Broker_Listing__c`, which the
 * replacement does NOT rewrite (opening a new listing row on a broker change is a separate,
 * deferred decision). Refreshing it is what proves that on screen rather than assuming it.
 *
 * ── ⚠ RESIDUAL: TWO VALUES ON THIS CARD CAN LAG A JUST-LOGGED OFFER (review W1, 2026-08-10) ──
 * `getListing` is `@AuraEnabled(cacheable=true)`, and while this component now RETAINS its wire
 * result, nothing invalidates it when an offer is logged from `c-disposition-offer` in the SIDEBAR.
 * The traction badge can therefore lag — and since 2026-08-21 so can "Days On Market", because the
 * first offer pauses the clock. A page reload always shows the truth; the window itself was not
 * measured, so none is claimed.
 * ⚠ THIS USED TO SAY "TWO VALUES … the traction badge AND the Offers Received stat". The stat was
 * removed at UAT, so that third lagging surface no longer exists — the residual shrank with the
 * card rather than being fixed. Do not read the reduction as a fix.
 *
 * 🔴 A CustomEvent relay through `c-disposition-main` is NOT buildable, and that is measured rather
 * than assumed: per `flexipages/Disposition_Record_Page.flexipage-meta.xml`, `dispositionMain` is in
 * the `main` region while `dispositionSidebar` — the only renderer of `c-disposition-offer` — is in
 * the `sidebar` region, so the two share no ancestor for an event to travel through. Crossing
 * regions needs Lightning Message Service and this repo has no `messageChannels/` directory. If you
 * build it, use `refreshApex` on the retained result below, NOT `getRecordNotifyChange` — the band
 * is an Apex computation, not a field on the Disposition record.
 *
 * ── 🔴 THE CALL-FOR-OFFERS SECTION (2026-08-24) — THE ONE CLIENT-DERIVED BAND ON THIS CARD ──
 * Below a token-driven rule the card now carries three tiles derived from ONE field,
 * `Broker_Listing__c`/`Disposition__c`'s `callForOffersDate` as shipped by
 * `BrokerListingController`: the date itself (MOVED down from the top grid, not re-added), a
 * countdown, and a status pill. The ladder is in `_cfoState` and is stated in full there.
 *
 * ⚠ THIS IS THE EXCEPTION TO THIS FILE'S OWN "NO THRESHOLD AND NO BAND IS DERIVED IN THIS FILE"
 * RULE AT THE TOP, AND THE RULE IS NOT WEAKENED BY IT. That rule is about the TRACTION band, which
 * is a server rule a batch job and an alert also fire on — a second copy in JS would drift from the
 * copy that sends the email. Nothing server-side computes a disposition call-for-offers countdown
 * and nothing alerts on one; the field is a plain stored date. `_cfoState` records the full
 * argument, including the one that would move it to Apex.
 *
 * 🔴 EVERY LIVE DISPOSITION HAS A BLANK `Call_For_Offers_Date__c` TODAY, so the "Not Scheduled"
 * branch is not an edge case — it is what is on screen. It renders an em dash and the words "Not
 * Scheduled"; it must never render `0` (which reads as "due today") or `Overdue` (which accuses
 * someone of missing a deadline nobody set). Pinned in `brokerListing.test.js`.
 *
 * ⚠ THE PILL'S TREATMENT IS `c/callForOffersPanel`'s, NOT A NEW ONE — same geometry, same four
 * theme names, and `DUE_SOON_DAYS` is that module's own `APPROACHING_DAYS`. The stylesheet records
 * the ONE deliberate departure (the background token, which is a measured bug fix) and why it must
 * not be "restored".
 *
 * @see force-app/main/default/classes/BrokerListingController.cls
 * @see force-app/main/default/classes/DispositionTractionService.cls (the band ladder)
 * @see force-app/main/default/classes/BovSubmissionService.cls (replaceSelectedBroker)
 */
import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { brokerOptionLabel } from 'c/utils';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';
import getListing from '@salesforce/apex/BrokerListingController.getListing';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

/**
 * The Due Soon window, in DAYS.
 *
 * 🔴 COPIED, NOT INVENTED. This is `CallForOffersService.APPROACHING_DAYS` (7) — the acquisition
 * module's existing "amber begins" rung for a call-for-offers deadline, the same concept this tile
 * measures on the disposition side. Copying it means the two modules cannot disagree about when an
 * offer deadline starts being urgent.
 *
 * ⚠ IT ALSO EQUALS `DispositionTractionService.WEEK_1_DAYS` (7), so it does not contradict the
 * traction pill sitting a few pixels away either. That is a COINCIDENCE OF VALUE, not a derivation:
 * do not "unify" the two by reading one from the other, and if acquisition changes
 * `APPROACHING_DAYS` this constant follows THAT, not the week ladder.
 */
const DUE_SOON_DAYS = 7;

/**
 * Whole days from local today to an ISO `yyyy-mm-dd`. Negative when the date has passed, `0` today,
 * and `null` when there is no parseable date at all.
 *
 * 🔴 `null` AND `0` ARE DIFFERENT ANSWERS AND THE CALLER MUST KEEP THEM APART. `0` is falsy in JS,
 * so a `value || '—'` collapses "due today" into "no date" on the one day it matters most —
 * `callForOffersPanel.js`'s header records that exact trap being hit in the acquisition module.
 *
 * ⚠ NO `new Date(isoString)`. That parses as UTC midnight and then renders/compares in the
 * browser's local zone, so west of Greenwich every date lands a day early — an off-by-one on the
 * only number this tile is about. Both operands are built as LOCAL midnights instead, and the
 * division is ROUNDED so a DST boundary (a 23- or 25-hour day) cannot shave or add a day.
 *
 * @param {string} isoDate `yyyy-mm-dd`, or null/undefined.
 * @param {Date} now The clock. Injected rather than read here so the caller owns "today".
 * @returns {number|null} Whole days, or null when there is no date.
 */
function daysUntil(isoDate, now) {
    if (!isoDate) {
        return null;
    }
    const parts = String(isoDate).split('-');
    if (parts.length !== 3) {
        return null;
    }
    const year = parseInt(parts[0], 10);
    const month = parseInt(parts[1], 10);
    const day = parseInt(parts[2], 10);
    if (!year || !month || !day) {
        return null;
    }
    const target = new Date(year, month - 1, day);
    if (isNaN(target.getTime())) {
        return null;
    }
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    return Math.round((target.getTime() - today.getTime()) / 86400000);
}


export default class BrokerListing extends LightningElement {
    @api recordId;
    listing;
    error;

    _listingWire;
    _submissionsWire;
    _submissions;

    @wire(getListing, { dispositionId: '$recordId' })
    wired(result) {
        this._listingWire = result;
        const { data, error } = result;
        if (data) {
            this.listing = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.listing = undefined;
        }
    }

    /**
     * The BOV submissions behind the Replace Broker button.
     *
     * ⚠ A FAILURE HERE HIDES THE BUTTON AND NOTHING ELSE. `_submissions` falls back to an empty
     * array, so `canReplaceBroker` reads false and the card renders exactly as it did before this
     * button existed. The listing facts are the card's job; a broken submissions read must not take
     * them down or raise a toast about a button the user never pressed.
     */
    @wire(getSubmissions, { dispositionId: '$recordId' })
    wiredSubmissions(result) {
        this._submissionsWire = result;
        const { data, error } = result;
        if (data) {
            this._submissions = data;
        } else if (error) {
            this._submissions = [];
        }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }
    get showEmpty() { return !this.listing && !this.error; }

    get listDateLabel() { return this._fmtDate(this.listing?.listDate); }
    get cfoDateLabel()  { return this._fmtDate(this.listing?.callForOffersDate); }

    /**
     * ── THE CALL-FOR-OFFERS SECTION: ONE STATE OBJECT, THREE RENDERED FACTS ──
     *
     * 🔴 ONE GETTER DERIVES THE BAND; the three below only read from it. Splitting the ladder across
     * `cfoCountdownLabel` / `cfoStatusLabel` / `cfoStatusClass` would let a future edit change the
     * threshold in one of them, producing a GREEN pill beside the words "Due Soon" — a card that
     * contradicts itself and that no single assertion catches.
     *
     * ── THE LADDER, STATED IN FULL ──────────────────────────────────────────
     *   no date        countdown `—`          status `Not Scheduled`  neutral grey
     *   in the past    countdown `N days ago` status `Overdue`        error red
     *   today          countdown `Today`      status `Due Soon`       warning amber
     *   1..7 days      countdown `N days`     status `Due Soon`       warning amber
     *   8+ days        countdown `N days`     status `On Track`       success green
     *
     * ── 🔴 WHY THIS IS COMPUTED HERE AND NOT IN APEX ────────────────────────
     * `c/listingAlerts` and `c/callForOffersPanel` both carry a rule saying the OPPOSITE — no
     * threshold in JS — and both are right for what they render: the traction band and the
     * acquisition urgency band are SERVER rules that a batch job and an alert also fire on, so a
     * second copy in JS would drift from the copy that sends the email. THIS is not that. Nothing
     * server-side computes a disposition call-for-offers countdown, nothing alerts on one, and
     * `Call_For_Offers_Date__c` is a plain stored date that `BrokerListingController` already ships.
     *
     * ⚠ AND THE CACHE IS A POSITIVE REASON, not just an absence of one. `getListing` is
     * `cacheable=true` and this card is documented above as able to serve a stale payload; a
     * server-computed countdown would go stale with it and be wrong about TODAY. Derived in the
     * browser from the stored date, it is right on every render whatever the cache holds. The tile
     * beside it, "Days On Market", is server-computed and does carry that staleness — deliberately,
     * because the pause that freezes it is a server rule.
     *
     * 🔴 IF AN ALERT OR A ROLL-UP IS EVER BUILT ON THIS DATE, THIS LADDER MOVES TO APEX AND THIS
     * GETTER BECOMES A READER OF THE PAYLOAD — exactly as `badgeLabel` is in `c/callForOffersPanel`.
     * Do not leave two copies.
     *
     * @returns {{days: (number|null), countdown: string, status: string, theme: string}}
     */
    get _cfoState() {
        const days = daysUntil(this.listing?.callForOffersDate, new Date());

        // 🔴 NOT SCHEDULED — the live-data case today, and the one this card must not lie about.
        // Every disposition in the org currently has a blank Call_For_Offers_Date__c, so this is
        // what is actually on screen. A `0` here would read as "due today" and an `Overdue` here
        // would accuse someone of missing a deadline that was never set.
        if (days === null) {
            return {
                days: null,
                countdown: '—',
                status: 'Not Scheduled',
                theme: 'muted'
            };
        }

        if (days < 0) {
            const past = -days;
            return {
                days,
                countdown: past === 1 ? '1 day ago' : `${past} days ago`,
                status: 'Overdue',
                theme: 'red'
            };
        }

        // ⚠ `days === 0` IS "Due Soon", NOT A FIFTH BAND. `CallForOffersService` splits DUE_TODAY
        // out and paints it red; that split is not reproduced here because the countdown tile
        // BESIDE this pill already reads "Today" in words, so a fifth colour would add a
        // distinction with no information behind it. This is the same argument
        // `callForOffersPanel.js`'s BAND_THEME uses for collapsing CRITICAL into amber, applied to
        // a card that likewise renders exactly one band at a time.
        if (days === 0) {
            return { days, countdown: 'Today', status: 'Due Soon', theme: 'amber' };
        }

        const countdown = days === 1 ? '1 day' : `${days} days`;
        return days <= DUE_SOON_DAYS
            ? { days, countdown, status: 'Due Soon', theme: 'amber' }
            : { days, countdown, status: 'On Track', theme: 'green' };
    }

    /** The countdown tile's value. Never `0`, never negative — see `_cfoState`. */
    get cfoCountdownLabel() {
        return this._cfoState.countdown;
    }

    /**
     * The pill's text.
     *
     * 🔴 THE STATE IS IN THE WORDS, NOT ONLY IN THE COLOUR. `.risk-badge` on this same card is
     * built that way for the same reason, and it is what keeps the card readable to a screen reader
     * and to anyone who cannot tell the amber and red pills apart.
     *
     * ⚠ `On Track` IS THE TRACTION LADDER'S OWN WORD, reused verbatim so the two pills on this card
     * agree about what "fine" looks like. `At Risk` and `Hard Stop` are deliberately NOT reused:
     * those are `DispositionTractionService`'s rungs about whether the LISTING is getting traction,
     * and wearing them here would read as a second copy of that ladder, which this is not.
     */
    get cfoStatusLabel() {
        return this._cfoState.status;
    }

    /** The pill's class. Colour is reinforcement only; the label above carries the meaning. */
    get cfoStatusClass() {
        return `cfo-pill cfo-pill--${this._cfoState.theme}`;
    }

    /**
     * ⚠ TWO TILES NOW, AND NEITHER REMOVAL WAS A TIDY-UP.
     *
     * The "Offers Received" tile went at UAT on 2026-08-21 ("No need to show count of disposition
     * offers as well"). `BrokerListingController.ListingRow` lost its `offersReceived` member in the
     * same change, so there is nothing left to render here; the controller still COUNTS offers,
     * because the count is an input to the traction band and to the clock pause, and it still
     * travels in the one aggregate that also yields `firstOfferDate`.
     *
     * 🔴 "Call For Offers Date" WAS NOT DELETED — IT MOVED. It now sits below the rule, in the
     * call-for-offers section of the template, beside the countdown and the status pill that are
     * derived from the same field. It is still rendered from `cfoDateLabel`, which is why that
     * getter is still here; a reader who greps for the tile and finds no `key: 'cfo'` must not
     * conclude the date stopped being shown.
     */
    get stats() {
        const l = this.listing || {};
        // ⚠ daysOnMarket is null (not 0) when the marketing clock has not started — the controller
        // computes it from Disposition__c.Listing_Date__c rather than reading the hand-keyed
        // Broker_Listing__c.Days_On_Market__c, so "no listing date" and "listed today" are finally
        // distinguishable. Render the honest dash instead of collapsing back to 0.
        const domValue = l.daysOnMarket == null ? '—' : `${l.daysOnMarket} days`;
        return [
            { key: 'dom',    label: 'Days On Market',       value: domValue,                      iconName: 'utility:clock', iconColor: l.isAtRisk ? '#b45309' : '#5a6b7b' },
            { key: 'list',   label: 'List Date',            value: this.listDateLabel,            iconName: 'utility:event', iconColor: '#1565c0' }
        ];
    }

    /**
     * ⚠ RENAMED FROM hasWeekLabel (Tranche 5B). The payload field is `tractionLabel`, not
     * `weekLabel`, and the getter must not assert anything about the string's shape: it has read
     * "Week 6", then "Day 34 — Traction checkpoint", and since 2026-08-21 "Week 4 — At Risk" or
     * "Day 12 — Offer received, clock paused". Whatever the server sends is what renders.
     */
    get hasTractionLabel() { return !!this.listing?.tractionLabel; }

    /** The currently Selected submission, or undefined. `isSelected` is BovController's DTO name. */
    get _selected() {
        return (this._submissions || []).find((r) => r.isSelected === true);
    }

    /** See the class header: mirrors `c/bovComparisonMatrix.canReplaceBroker` deliberately. */
    get canReplaceBroker() {
        return this._selected !== undefined;
    }

    /**
     * The appointable submissions as ready-made radio options, labelled by `c/utils`'s shared
     * `brokerOptionLabel` — the SAME function `c/bovComparisonMatrix` uses, so the same broker
     * cannot read differently on the two surfaces that can open this modal.
     *
     * ⚠ THE `isSelected !== true` FILTER EXCLUDES THE INCUMBENT. Promoting a broker to itself is
     * not an operation, and the server refuses it.
     */
    get _backupOptions() {
        return (this._submissions || [])
            .filter((r) => r.isSelected !== true)
            .map((r) => ({ label: brokerOptionLabel(r), value: r.id }));
    }

    /**
     * "Replace Broker" — swap the appointed broker for one of the backups, from the Active Listing
     * stage.
     *
     * 🔴 THE MODAL CANNOT REACH THIS COMPONENT WITH A BUBBLING DOM EVENT, so it does not try.
     * `LightningModal.open()` renders into the PLATFORM'S modal layer, not into this component's
     * template, so a `CustomEvent` — however composed — has no path back here. The promise returned
     * by `open()` is the channel, and this component awaiting it is what keeps the wires' owner and
     * their refresher the same object.
     *
     * 🔴 THE TOAST IS STICKY. The service's returned text carries "must be approved before the sale
     * can proceed" — `Approval_Status__c` is cleared on the challenger — and that is a consequence
     * the user has to act on. An auto-dismissing toast is exactly how it gets missed.
     *
     * ⚠ THE BODY IS THE SERVER'S SENTENCE VERBATIM. The service chooses its wording from what it
     * actually did inside the transaction; re-authoring it here would produce a second copy that
     * keeps making a promise the day someone changes the service. Same contract as
     * `c/bovComparisonMatrix`.
     *
     * ⚠ NO `isFirstAppointment` PROP. The modal's getter reads `=== true`, so an absent prop means
     * "replacement" — the safer branch, and the only one reachable here: this button renders only
     * when a broker is already Selected.
     */
    async handleReplaceBroker() {
        let result;
        try {
            result = await BovReplaceBrokerModal.open({
                size: 'small',
                label: 'Replace Selected Broker',
                description:
                    'Promote a backup BOV submission to Selected and demote the current broker.',
                dispositionId: this.recordId,
                backupOptions: this._backupOptions,
                currentBroker: this._selected && this._selected.brokerFirm
            });
        } catch (error) {
            this._toast(
                'Could not open the replace dialog',
                (error && error.body && error.body.message) ||
                    'The replace-broker dialog could not be opened.',
                'error'
            );
            return;
        }

        // Cancelled or dismissed — nothing changed, so say nothing.
        // ⚠ A dismissed LightningModal resolves `undefined`, and the repo's Jest stub for it
        // resolves `null`. Both are falsy and both must take this branch.
        if (!result || !result.message) {
            return;
        }

        this._toast('Broker replaced', result.message, 'warning', 'sticky');
        // The swap is imperative Apex DML on records these cacheable wires already hold, so LDS has
        // no idea they changed. Without this the card keeps offering to replace a broker who has
        // already been replaced.
        refreshApex(this._submissionsWire);
        refreshApex(this._listingWire);
    }

    _toast(title, message, variant, mode) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant,
                mode: mode || (variant === 'success' ? 'dismissable' : 'sticky')
            })
        );
    }

    _fmtDate(d) {
        if (!d) return '—';
        const parts = String(d).split('-');
        return MONTHS[parseInt(parts[1], 10) - 1] + ' ' + parseInt(parts[2], 10) + ', ' + parts[0];
    }
}
