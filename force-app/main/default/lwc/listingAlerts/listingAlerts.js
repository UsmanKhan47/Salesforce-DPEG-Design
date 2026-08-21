/**
 * c-listing-alerts — the AUTOMATED ALERTS card on the Disposition record page's Active Listing
 * stage. It renders the three-rung escalation schedule (Week 1 / Week 4 / Week 6) with each rung's
 * real Passed / Current / Ahead state, and nothing else.
 *
 * ── 🔴 IT WAS THE "LISTING TRACTION" MONITOR UNTIL 2026-08-21. UAT REMOVED THAT ──
 * The user's words: *"we don't need listing traction. We just need automated alerts thats' it. No
 * need to show count of disposition offers as well."* Four surfaces were deleted from this card:
 *
 *     .band-badge     the band pill ("Week 4 — At Risk", "Day 12 — Offer received, clock paused")
 *     .band-detail    the one-sentence explanation under it
 *     .clock-track    the marketing-period progress bar
 *     .milestone-list "Days on market: 30 of 42" and "Offers received: 2 offers"
 *
 * 🔴 THE LABEL ITSELF WAS **NOT** DELETED, AND THAT IS THE WHOLE JUDGEMENT CALL. "Week 4 — At Risk"
 * is the one string the user gave verbatim (see `DispositionTractionService`'s §1), and it survives
 * on `c/brokerListing`, in the header beside the Replace Broker button — which is where
 * `brokerListing.html`'s own comment says it belongs, *"because the label is the reason anyone
 * presses the button"*. Removing it there would leave a Replace Broker button with no stated cause
 * and would make `isAtRisk`'s amber icon tint the only surviving carrier, i.e. colour alone.
 * ⚠ SO THERE IS EXACTLY ONE COPY OF THAT STRING ON THE SCREEN NOW. Do not add a second one back
 * here "for context": one server computation, one rendering, is the property this design has.
 *
 * ⚠ WHAT IS **NOT** GONE: `DispositionTractionService` and `DispositionTractionController`. The
 * rungs ARE the ladder — their labels, due dates, states and notes are all computed server-side by
 * that service — so deleting it would delete the alerts the user asked to keep. This card reads
 * fewer members of the same payload; it does not read a different one.
 *
 * ── 🔴 READ THIS BEFORE CHANGING THE PANEL: IT ONCE SHIPPED AS A MOCK ───────
 * The version before 2026-08-10 had a two-line `.js` and a hardcoded 22-line `.html` that rendered
 * four rows AS FACT:
 *
 *     Day 21   ->  No offers -> email to Junior
 *     Week 4   ->  YELLOW flag on Junior dashboard
 *     Week 6   ->  Hard prompt + alert to Junior + Ali
 *     Offer in ->  Clock PAUSES - Disposition Offer created
 *
 * It was deleted because *"a component rendering a fixed lie is worse than an empty one, because
 * nothing looks broken"* — four rows shown as fact with nothing behind them.
 *
 * ── ⚠ THE 2026-08-21 REVISION BROUGHT THREE OF THOSE FOUR ROWS BACK AS DATA ──
 * The user settled the questions the deletion note raised, and the note's four objections are now
 * in three different states. Quoting it so a reader can see which:
 *
 *   RETRACTED — *"Rows 1-3 advertised the 6-WEEK CLOCK that D27.1 overturned (the document allows
 *   ~2 months with a month-1 check)."* The user settled the third dispute over these thresholds on
 *   2026-08-21 in favour of WEEK 1 / WEEK 4 / WEEK 6 (days 7/28/42), overriding the document. The
 *   six-week clock is now the real one.
 *
 *   RETRACTED — *"Row 4 asserted a 'Clock PAUSES' rule that appears in NO document, NO decision and
 *   NO code."* It is now a decision (user, 2026-08-21) and it is now code
 *   (`DispositionTractionService.evaluate` measures the clock to `min(today, firstOfferDate)`).
 *   ⚠ THE PAUSE IS STILL COMPUTED AND STILL DRIVES THE RUNG NOTES ("Clock paused.", "Passed before
 *   the clock paused.") — the UAT removal took away the badge that ANNOUNCED it, not the rule.
 *
 *   🔴 STANDS, AND IS THE REASON THIS FILE STILL PROMISES NOTHING — *"Rows 1 and 3 promised
 *   NOTIFICATIONS that D9 defers and that nothing in this org sends."* Still true, and the user
 *   deferred emails AND the dashboard flag AGAIN in the same 2026-08-21 conversation. ⚠ THE CARD IS
 *   NOW TITLED "Automated Alerts", WHICH MAKES THIS BAN SHARPER, NOT LOOSER: the title names a
 *   schedule of check-ins, and no string below says anyone is emailed, alerted or flagged.
 *   `listingAlerts.test.js` asserts it.
 *
 *   🔴 STANDS ABSOLUTELY — the ban on a FIXED list. The three rungs below are rendered from
 *   `traction.rungs`, computed per record by the server, each carrying its own Passed / Current /
 *   Ahead state and its own due date. The same three keys render differently on two different
 *   dispositions, which is the whole difference between this and what was deleted. **Do not
 *   hardcode a row here, and do not derive a threshold in JS** — no number in this bundle is a
 *   threshold; every one arrives in the payload.
 *
 * ── DATA ACCESS: APEX, NOT LDS, AND THE REASON IS THE §5 EXCEPTION ──────────
 * ARCHITECTURE.md §5 is LDS-first, and this component deliberately takes the "business logic must
 * be enforced server-side" exception. The ladder is a RULE (six-week clock, three rungs, offers
 * only, pause at the first offer) whose current level `lwc/brokerListing` renders the label of on
 * the SAME screen. Computing it in JS would put a second copy of that ladder in a second language
 * where it would drift, and the first symptom would be a badge and a schedule contradicting each
 * other about whether to replace a broker. LDS also cannot supply the input:
 * `getRelatedListRecords` returns a PAGE of offers, not a count and not a MIN of their dates.
 *
 * ── ⚠ RESIDUAL: THIS PANEL CAN LAG A JUST-LOGGED OFFER (review W1, 2026-08-10) ──────────────
 * `getTraction` is `@AuraEnabled(cacheable=true)` and this component holds no wire result and calls
 * no `refreshApex`, so after a user logs an offer from `c-disposition-offer` in the SIDEBAR, that
 * card's LDS related-list wire refreshes while this panel may keep rendering the payload it already
 * has. ⚠ THE UAT REMOVAL NARROWED THIS RESIDUAL BUT DID NOT CLOSE IT: the day count and the band
 * pill are gone, so a stale card can no longer be wrong about those — but the first offer PAUSES
 * the clock, and a stale card can still show "Current — no offers." on a rung that has since been
 * suspended. A page reload always shows the true state; the window itself was not measured, so none
 * is claimed.
 *
 * 🔴 THE OBVIOUS FIX IS NOT AVAILABLE HERE, AND THAT IS MEASURED, NOT ASSUMED. A CustomEvent from
 * `c-disposition-offer` relayed by `c-disposition-main` cannot reach this component: per
 * `flexipages/Disposition_Record_Page.flexipage-meta.xml`, `dispositionMain` is in the `main` region
 * and `dispositionSidebar` — the only renderer of `c-disposition-offer` — is in the `sidebar`
 * region, so there is no shared ancestor for an event to travel through. Crossing regions needs
 * Lightning Message Service, and this repo has no `messageChannels/` directory at all. If you build
 * it: `refreshApex` on a retained wire result is the tool, NOT `getRecordNotifyChange` — the rungs
 * are an Apex computation, not a field on the Disposition record. Full reasoning and the accepted-
 * residual decision are in `DispositionTractionService`'s §4 header block.
 *
 * ── 🔴 THE BUNDLE NAME IS STILL `listingAlerts`, AND NOW IT FINALLY FITS ────
 * It was kept through the traction-monitor era because renaming means deleting a bundle
 * `dispositionMain.html` references and creating another in the same deploy. The card is now
 * literally the alerts schedule, so the name and the content agree; there is even less reason to
 * churn it. `listingAlerts` still raises no alert — see the notification ban above.
 *
 * @see force-app/main/default/classes/DispositionTractionController.cls
 * @see force-app/main/default/classes/DispositionTractionService.cls (the rung ladder)
 * @see force-app/main/default/lwc/brokerListing/brokerListing.js (the surviving label)
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

/** Rung state -> its CSS modifier. The state text itself is always rendered, never colour alone. */
const STATE_THEME = {
    Passed: 'passed',
    Current: 'current',
    Ahead: 'ahead'
};

export default class ListingAlerts extends LightningElement {
    /**
     * ⚠ REQUIRED, AND IT WAS NOT BEING PASSED. `dispositionMain.html` rendered
     * `<c-listing-alerts>` with no attributes while both of its siblings on the same row received
     * `record-id={recordId}` — harmless while the component was a static mock, fatal the moment it
     * reads anything.
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

    /**
     * 🔴 THE THREE RUNGS, AS REAL STATE — user decision 3, and the answer to the deleted mock. Since
     * the 2026-08-21 UAT pass this is the card's ENTIRE content.
     *
     * This getter DECIDES NOTHING. It adds a CSS class and formats a date; the label, the threshold,
     * the due date, the state and the note all arrive from `DispositionTractionService`. If a
     * reader is ever tempted to compute `state` here from `daysOnMarket`, that is the second copy of
     * the ladder this whole design exists to prevent — and it would be wrong immediately, because a
     * PAUSED listing has reached rungs and no current one, which no local day comparison can know.
     * ⚠ `daysOnMarket` IS NO LONGER EVEN RENDERED, so a local derivation would now be reading a
     * payload member nothing on this card displays — which is how a silent drift starts.
     */
    get rungs() {
        const t = this.traction;
        if (!t || !t.rungs) {
            return [];
        }
        return t.rungs.map((r) => ({
            key: r.key,
            label: r.label,
            state: r.state,
            note: r.note,
            dueLabel: this.formatDate(r.dueDate),
            rowClass: `rung rung--${STATE_THEME[r.state] || 'ahead'}`
        }));
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
