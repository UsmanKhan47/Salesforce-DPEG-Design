/**
 * c-broker-listing — @wire-to-Apex suite.
 * Pattern: bovComparisonMatrix template (createApexTestWireAdapter + emit/error, modal mocked
 * wholesale, `@salesforce/apex` mocked so `refreshApex` is a spy).
 *
 * Data sources: TWO wires now.
 *   @wire(getListing,     { dispositionId: '$recordId' }) -> the card's facts and traction badge
 *   @wire(getSubmissions, { dispositionId: '$recordId' }) -> whether Replace Broker may render
 *
 * ── 🔴 WHAT THIS SUITE PROVES ABOUT THE REPLACE BROKER BUTTON ───────────────
 * It is a SECOND ENTRY POINT to one server mechanism, not a second mechanism. The assertions that
 * carry that are:
 *   - the button opens `c/bovReplaceBrokerModal` (the same bundle `c/bovComparisonMatrix` opens),
 *     with `dispositionId` and `backupOptions`;
 *   - `isFirstAppointment` is NOT passed — the modal reads `=== true`, so absent means "replacement";
 *   - both wires are refreshed with the SAME objects the wires handed the component, which is the
 *     only assertion that catches a "tidying" edit back to a destructured wire handler;
 *   - the button is ABSENT when nothing is Selected — which is also the off-market case, since an
 *     off-market disposition has no BOV submissions at all.
 *
 * ⚠ THE FIXTURE MOVED OFF THE 30/40/60 CLOCK (user decision, 2026-08-21). It previously carried
 * `tractionBand: 'HARD_STOP'` / `'Day 71 — Hard Stop: no offers'`. The payload now carries the
 * Week 2/4/6 bands and a paused variant — computed server-side by DispositionTractionService. This
 * suite asserts that the card RENDERS what it is given and deliberately re-derives no threshold of
 * its own.
 *
 * ⚠ THE FIRST RUNG MOVED AGAIN ON 2026-09-02 (user decision A2: `WEEK_1`/day 7 -> `WEEK_2`/day 14)
 * AND THIS SUITE'S FIXTURES DID NOT NEED TO CHANGE — they carry `WEEK_4` and `ON_TRACK` only.
 * 🔴 THAT IS THE POINT, NOT AN OVERSIGHT: this card colours off the BOOLEAN `isAtRisk` and prints
 * `tractionLabel` verbatim, so it has no branch on any band literal to break. If a future edit
 * makes it switch on `tractionBand`, this paragraph stops being true and the fixtures become
 * threshold-sensitive.
 * ⚠ AND `DUE_SOON_DAYS = 7` IN THE COMPONENT IS UNRELATED AND DID NOT MOVE — it is
 * `CallForOffersService.APPROACHING_DAYS`, an ACQUISITIONS constant. Its equality with the old
 * first rung was a coincidence and is now gone; the component's own header records this.
 *
 * ── ⚠ THREE TILES, AND `offersReceived` IS GONE FROM THE FIXTURE (UAT, 2026-08-21) ──
 * The user asked for the disposition-offer count to be removed, so the fourth "Offers Received"
 * tile went and `BrokerListingController.ListingRow.offersReceived` went with it. The assertions
 * that read `tiles[3]` were DELETED rather than repointed — there is no tile there to assert on —
 * and the member was removed from both fixtures, because a fixture carrying a field the server no
 * longer sends is a suite testing a payload the org cannot produce.
 *
 * 🔴 THE `.risk-badge` ASSERTIONS BELOW ARE NOW LOAD-BEARING FOR THE WHOLE SCREEN, not just for this
 * card. `c/listingAlerts` lost its own copy of the band pill in the same UAT pass, so this is the
 * ONLY place "Week 4 — At Risk" — the one string the user gave verbatim — is rendered anywhere. If
 * these tests are ever deleted as redundant, nothing else fails when the label disappears.
 */
import { createElement } from 'lwc';
import BrokerListing from 'c/brokerListing';
import getListing from '@salesforce/apex/BrokerListingController.getListing';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';
import { refreshApex } from '@salesforce/apex';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';

jest.mock(
    '@salesforce/apex/BrokerListingController.getListing',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/BovController.getSubmissions',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock('c/bovReplaceBrokerModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

// ⚠ `refreshApex` IS NOT AUTO-MOCKED. `@salesforce/apex` resolves to a real module whose
// `refreshApex` is a plain function, so `expect(refreshApex).toHaveBeenCalled()` fails with
// "received value must be a mock or spy function" — which reads like a broken assertion rather
// than a missing mock.
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), {
    virtual: true
});

const LISTING = {
    assetName: 'Sugar Land Town Center',
    brokerFirm: 'CBRE',
    contactName: 'Jane Doe',
    tractionBand: 'WEEK_4',
    tractionLabel: 'Week 4 — At Risk',
    tractionDetail:
        'Four weeks on the market with no offers, and 14 days of the marketing period remain.',
    daysOnMarket: 30,
    daysWithThisBroker: 9,
    isAtRisk: true,
    listDate: '2026-03-15',
    callForOffersDate: '2026-04-10'
};

/** The paused variant — an offer stopped the clock, so the card must show the FROZEN day count. */
const PAUSED_LISTING = {
    ...LISTING,
    tractionBand: 'ON_TRACK',
    tractionLabel: 'Day 12 — Offer received, clock paused',
    tractionDetail:
        '2 offers received, so the marketing clock stopped at day 12 and no week check-in is due.',
    daysOnMarket: 12,
    isAtRisk: false
};

const SUBMISSIONS = [
    {
        id: 'a0X010000000001',
        name: 'BOV-0001',
        isSelected: true,
        bovScore: 88,
        brokerFirm: 'Colliers International',
        contactName: 'Jane Doe',
        bovAmount: 12500000
    },
    {
        id: 'a0X010000000002',
        name: 'BOV-0002',
        isSelected: false,
        bovScore: 71,
        brokerFirm: 'JLL',
        contactName: 'John Roe',
        bovAmount: 11000000
    }
];

/** No broker appointed yet — and, identically in shape, the off-market case of NO submissions. */
const NONE_SELECTED = SUBMISSIONS.map((s) => ({ ...s, isSelected: false }));

describe('c-broker-listing', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-broker-listing', {
            is: BrokerListing
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    /** Emit both wires and settle. */
    async function emitAll(listing, submissions) {
        getListing.emit(listing);
        getSubmissions.emit(submissions);
        await Promise.resolve();
        await Promise.resolve();
    }

    function replaceButton(element) {
        return element.shadowRoot.querySelector('.replace-btn');
    }

    it('shows the empty card until the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.empty-card').textContent
        ).toBe('No broker listing on record.');
    });

    it('DATA BRANCH: renders the listing header and the two top stat tiles', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.card-title').textContent
        ).toBe('Sugar Land Town Center');
        expect(
            element.shadowRoot.querySelector('.card-sub').textContent
        ).toBe('CBRE · Jane Doe');

        // ⚠ THREE TILES IN THE TOP GRID SINCE 2026-09-01 (Tranche 4 item 5). It said TWO until
        // then, and the paragraph below is unchanged and still correct: the Call For Offers Date
        // tile MOVED below the rule into the call-for-offers section — it was not deleted — so it
        // is asserted there rather than here. A bare count assertion would stay green if the date
        // had been dropped altogether, which is why the move is pinned in its own test below.
        //
        // 🔴 THE ORDER IS ASSERTED, NOT JUST THE COUNT, AND THE ORDER IS THE DESIGN: the two CLOCKS
        // sit side by side on row 1 of a two-column grid, with List Date beneath them. A change
        // that appended the broker clock after List Date would keep the count at 3 and would split
        // the pair the user is meant to compare.
        const tiles = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(tiles.length).toBe(3);
        expect(tiles[0].value).toBe('30 days'); // Days On Market — the MARKETING clock
        expect(tiles[1].value).toBe('9 days'); //  Days with this broker — the BROKER clock
        expect(tiles[2].value).toBe('Mar 15, 2026'); // List Date
    });

    /**
     * 🔴 THE TWO CLOCKS ARE LABELLED AND ARE DIFFERENT NUMBERS (Tranche 4 item 5, decision D-17).
     *
     * The fixture deliberately carries 30 and 9. A card that rendered the same number twice, or
     * that mislabelled either tile, is exactly the confusion this feature exists to remove — the
     * user has to be able to see that the property has been on the market for 30 days while the
     * current broker has had it for 9.
     *
     * ⚠ THE LABELS ARE ASSERTED BECAUSE THE VALUES ALONE CANNOT CARRY THE MEANING. Two tiles both
     * reading "N days" are indistinguishable without them, and "Days with this broker" is the
     * wording the second one has to keep: a shortened "Broker Days" would leave the reader guessing
     * whether it counts days or brokers.
     */
    it('🔴 DATA BRANCH: shows the marketing clock and the broker clock as two labelled tiles', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll('c-onboarding-card-child');
        expect(tiles[0].label).toBe('Days On Market');
        expect(tiles[0].value).toBe('30 days');
        expect(tiles[1].label).toBe('Days with this broker');
        expect(tiles[1].value).toBe('9 days');
        expect(tiles[0].value).not.toBe(tiles[1].value);
    });

    /**
     * 🔴 THE BROKER CLOCK NEVER TURNS AMBER, AND THIS IS THE PIN FOR
     * `Broker_Listing__c.Days_On_Market_Live__c`'s OWN PROHIBITION: "NOTHING MAY READ THIS FORMULA
     * TO DRIVE AN ALERT OR ESCALATION."
     *
     * `LISTING` is `isAtRisk: true`, so the MARKETING tile is amber. If someone wires the broker
     * tile to the same flag — or worse, derives a second at-risk rule from its own value — this
     * assertion fails. Colour is the only channel through which a display-only number could start
     * behaving like an escalation on this card.
     */
    it('🔴 DATA BRANCH: only the marketing clock carries the at-risk colour', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll('c-onboarding-card-child');
        expect(tiles[0].iconColor).toBe('#b45309'); // amber — the band said WEEK_4
        expect(tiles[1].iconColor).toBe('#5a6b7b'); // neutral, unconditionally
    });

    /**
     * A null broker clock renders a dash, exactly as a null marketing clock does — and for a
     * DIFFERENT reason, which is why it needs its own test.
     *
     * `daysOnMarket: null` means the PROPERTY has no listing date. `daysWithThisBroker: null` means
     * THIS LISTING ROW has no `List_Date__c`. Collapsing either to "0 days" would resurrect the
     * clock-that-looks-healthy-and-never-ticks defect on a second surface.
     *
     * ⚠ THE MARKETING CLOCK IS DELIBERATELY LEFT RUNNING HERE (30 days), so the dash below cannot
     * have been inherited from a not-listed parent.
     */
    it('DATA BRANCH: a null broker clock renders a dash, never "0 days"', async () => {
        const element = createComponent();

        getListing.emit({ ...LISTING, daysWithThisBroker: null });
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll('c-onboarding-card-child');
        expect(tiles[0].value).toBe('30 days');
        expect(tiles[1].value).toBe('—');
    });

    /**
     * 🔴 THE UAT REMOVAL, PINNED AS AN ASSERTION ABOUT ABSENCE. The count assertions were deleted,
     * which leaves nothing to fail if an offer-count tile comes back. `PAUSED_LISTING` is used
     * because it is the fixture with a non-zero count in the underlying data — a re-added tile
     * would render "2" and be caught by the text check as well as by the tile count.
     *
     * ⚠ THE EXPECTED COUNT MOVED FROM 2 TO 3 ON 2026-09-01 AND THAT IS THE HAZARD THIS NOTE
     * EXISTS FOR. An absence pin expressed as a COUNT is weakened every time a legitimate tile is
     * added: the number now has to be re-derived rather than trusted, and a future editor bumping
     * it to 4 to "make the suite pass" would silently readmit the very tile this test forbids. The
     * `not.toContain('offers received')` assertion below is the half that does not decay — it names
     * the thing that must not come back, so keep BOTH. The tile added in Tranche 4 item 5 is
     * 'Days with this broker', and it is pinned by name in its own test above.
     */
    it('🔴 renders no offer count — the UAT removal must not come back', async () => {
        const element = createComponent();

        getListing.emit(PAUSED_LISTING);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelectorAll('c-onboarding-card-child').length
        ).toBe(3);
        expect(
            element.shadowRoot.textContent.toLowerCase()
        ).not.toContain('offers received');
    });

    /**
     * 🔴 THE ESCALATION LABEL, WHERE THE USER ASKED FOR IT: beside the listing facts, as TEXT. The
     * exact string is the one the user gave verbatim, and it is produced entirely server-side.
     */
    it('DATA BRANCH: renders the escalation label beside the listing facts', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        const badge = element.shadowRoot.querySelector('.risk-badge');
        expect(badge.textContent).toContain('Week 4 — At Risk');
        expect(badge.getAttribute('title')).toBe(LISTING.tractionDetail);
    });

    it('DATA BRANCH: shows the risk badge only when a traction label is present', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();
        expect(
            element.shadowRoot.querySelector('.risk-badge').textContent
        ).toContain('Week 4 — At Risk');

        // Re-emit the same listing without a traction label.
        getListing.emit({ ...LISTING, tractionLabel: null });
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('.risk-badge')).toBeNull();
    });

    /**
     * 🔴 THE PAUSE, ON THIS CARD. The Days On Market tile shows the FROZEN number, not the elapsed
     * one, because the server computed it that way — and the badge says why in words.
     */
    it('DATA BRANCH: a paused clock shows the frozen day count and says so', async () => {
        const element = createComponent();

        getListing.emit(PAUSED_LISTING);
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(tiles[0].value).toBe('12 days');
        // ⚠ THE `tiles[3].value === '2'` ASSERTION THAT SAT HERE WAS DELETED, NOT MOVED. The offer
        // count tile is gone (UAT, 2026-08-21); the pause is still proven by the FROZEN day count
        // above and by the badge below, which are what the pause actually changes on this card.
        expect(
            element.shadowRoot.querySelector('.risk-badge').textContent
        ).toContain('clock paused');
    });

    /**
     * 🔴 THE CLOCK-NEVER-TICKED REGRESSION, PINNED. The retired controller read the hand-keyed
     * Broker_Listing__c.Days_On_Market__c and defaulted a null to 0, so a listing with no
     * marketing clock rendered "0 days" — indistinguishable from "listed today" and the reason
     * a dead clock looked healthy. A null must now render as a dash.
     */
    it('DATA BRANCH: a null days-on-market renders a dash, never "0 days"', async () => {
        const element = createComponent();

        getListing.emit({
            ...LISTING,
            daysOnMarket: null,
            tractionBand: 'NOT_LISTED',
            tractionLabel: 'Not listed yet',
            isAtRisk: false
        });
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(tiles[0].value).toBe('—');
    });

    it('ERROR BRANCH: renders an inline error state (not the data card) when the wire errors', async () => {
        const element = createComponent();

        getListing.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        const err = element.shadowRoot.querySelector('.bl-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // REPLACE BROKER
    // ─────────────────────────────────────────────────────────────────────────

    it('REPLACE: the button renders beside the label when a broker is Selected', async () => {
        const element = createComponent();

        await emitAll(LISTING, SUBMISSIONS);

        const btn = replaceButton(element);
        expect(btn).not.toBeNull();
        expect(btn.textContent).toBe('Replace Broker');
        // Beside the label, not somewhere else on the card.
        expect(
            element.shadowRoot.querySelector('.header-right .replace-btn')
        ).not.toBeNull();
    });

    /**
     * 🔴 ABSENCE, ASSERTED IN THREE WAYS — because "the button appears when it should" would stay
     * green if it ALSO appeared when it should not, offering a replacement the server would refuse.
     */
    it('REPLACE: the button is absent with no Selected broker, no submissions, or a failed read', async () => {
        const element = createComponent();

        await emitAll(LISTING, NONE_SELECTED);
        expect(replaceButton(element)).toBeNull();

        // 🔴 THE OFF-MARKET CASE. An off-market disposition has NO BOV submissions — its broker is
        // Disposition__c.Broker__c, which replaceSelectedBroker does not touch — so the button
        // hides by construction, with no record-type check to keep in step with the schema.
        getSubmissions.emit([]);
        await Promise.resolve();
        expect(replaceButton(element)).toBeNull();

        // A failed submissions read hides the button and takes nothing else down with it.
        getSubmissions.error();
        await Promise.resolve();
        expect(replaceButton(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.card')).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.risk-badge').textContent
        ).toContain('Week 4 — At Risk');
    });

    /**
     * 🔴 CONVERGENCE. The button opens the SAME modal bundle `c/bovComparisonMatrix` opens, which
     * reaches the SAME `BovSubmissionService.replaceSelectedBroker`. The incumbent is excluded from
     * the options (promoting a broker to itself is not an operation) and the labels come from
     * `c/utils`'s shared `brokerOptionLabel`, so the same broker cannot read differently on the two
     * surfaces that can open this modal.
     */
    it('REPLACE: opens the shared modal with the incumbent excluded and no first-appointment flag', async () => {
        BovReplaceBrokerModal.open.mockResolvedValue(undefined);
        const element = createComponent();
        await emitAll(LISTING, SUBMISSIONS);

        replaceButton(element).click();
        await Promise.resolve();

        expect(BovReplaceBrokerModal.open).toHaveBeenCalledTimes(1);
        const args = BovReplaceBrokerModal.open.mock.calls[0][0];
        expect(args.dispositionId).toBe('a0D5g000000DispEAG');
        expect(args.currentBroker).toBe('Colliers International');
        expect(args.backupOptions).toEqual([
            {
                value: 'a0X010000000002',
                label: 'JLL — John Roe · $11.0M · Score 71 · BOV-0002'
            }
        ]);
        // ⚠ ABSENT, not false: the modal's getter reads `=== true`, so absent means "replacement".
        expect(args.isFirstAppointment).toBeUndefined();
    });

    /**
     * 🔴 THE REFRESH ASSERTION IS ON THE WIRE RESULT OBJECTS THEMSELVES. That is what catches a
     * "tidying" edit back to `wired({ data, error })`, which compiles, passes every render test
     * above, and silently turns these refreshes into no-ops.
     */
    it('REPLACE: on success raises a sticky toast carrying the SERVER text and refreshes BOTH wires', async () => {
        const message =
            'Broker replaced. JLL must be approved before the sale can proceed.';
        BovReplaceBrokerModal.open.mockResolvedValue({ message });
        const element = createComponent();
        const toast = jest.fn();
        element.addEventListener('lightning__showtoast', toast);
        await emitAll(LISTING, SUBMISSIONS);

        replaceButton(element).click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toast).toHaveBeenCalledTimes(1);
        expect(toast.mock.calls[0][0].detail.title).toBe('Broker replaced');
        expect(toast.mock.calls[0][0].detail.message).toBe(message);
        expect(toast.mock.calls[0][0].detail.mode).toBe('sticky');
        expect(refreshApex).toHaveBeenCalledTimes(2);
    });

    it('REPLACE: a dismissed modal changes nothing — no toast and no refresh', async () => {
        BovReplaceBrokerModal.open.mockResolvedValue(null);
        const element = createComponent();
        const toast = jest.fn();
        element.addEventListener('lightning__showtoast', toast);
        await emitAll(LISTING, SUBMISSIONS);

        replaceButton(element).click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toast).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('REPLACE: a modal that fails to open raises an error toast and refreshes nothing', async () => {
        BovReplaceBrokerModal.open.mockRejectedValue({
            body: { message: 'boom' }
        });
        const element = createComponent();
        const toast = jest.fn();
        element.addEventListener('lightning__showtoast', toast);
        await emitAll(LISTING, SUBMISSIONS);

        replaceButton(element).click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toast).toHaveBeenCalledTimes(1);
        expect(toast.mock.calls[0][0].detail.variant).toBe('error');
        expect(toast.mock.calls[0][0].detail.message).toBe('boom');
        expect(refreshApex).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // THE CALL-FOR-OFFERS SECTION
    //
    // 🔴 EVERY ASSERTION BELOW READS A RENDERED ELEMENT — `querySelector(...).textContent` and
    // `.className` — NEVER a getter off the element. `element.cfoStatusLabel` is undefined anyway
    // (getters are not `@api`), but the deeper reason is that this repo has shipped a getter-only
    // assertion that stayed green while the template rendered nothing at all.
    //
    // ⚠ DATES ARE BUILT RELATIVE TO THE REAL CLOCK, NOT FAKED. `jest.useFakeTimers()` was not used
    // deliberately: it fakes `Date` for the a11y matcher too, and the component's whole job here is
    // to compare a stored date against the machine's own today. Constructing the fixture date by
    // walking `Date` forward N days is an INDEPENDENT computation from the component's
    // millisecond-difference arithmetic, so the assertions are not tautological.
    // ─────────────────────────────────────────────────────────────────────────

    /** ISO `yyyy-mm-dd` for local today + `offset` days. Negative offsets are in the past. */
    function isoOffset(offset) {
        const d = new Date();
        d.setDate(d.getDate() + offset);
        const pad = (n) => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    }

    function cfoTiles(element) {
        return element.shadowRoot.querySelectorAll('.cfo-grid .cfo-tile');
    }

    /** The rendered text of the countdown tile — the SECOND tile in the section. */
    function countdownText(element) {
        return cfoTiles(element)[1]
            .querySelector('.cfo-tile-value')
            .textContent.trim();
    }

    function pill(element) {
        return element.shadowRoot.querySelector('.cfo-grid .cfo-pill');
    }

    /** Emit a listing whose only interesting property is its call-for-offers date. */
    async function emitWithCfoDate(element, callForOffersDate) {
        getListing.emit({ ...LISTING, callForOffersDate });
        await Promise.resolve();
        return element;
    }

    /**
     * 🔴 THE STRUCTURE, AND THE MOVE. The Call For Offers Date tile left the top grid in this
     * change; without this test, deleting it outright would look identical to moving it — the top
     * grid's tile-count assertion (2 then, 3 since Tranche 4 item 5) would pass either way.
     */
    it('CFO: a rule, then a headed section of three tiles in a fixed order', async () => {
        const element = createComponent();
        await emitWithCfoDate(element, isoOffset(9));

        const rule = element.shadowRoot.querySelector('.cfo-rule');
        expect(rule).not.toBeNull();

        const section = element.shadowRoot.querySelector('.cfo-section');
        expect(section).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.cfo-heading').textContent.trim()
        ).toBe('Call for Offers');

        // The rule is BEFORE the section, not after it and not somewhere else on the card.
        // eslint-disable-next-line no-bitwise
        expect(
            rule.compareDocumentPosition(section) &
                Node.DOCUMENT_POSITION_FOLLOWING
        ).toBeTruthy();

        const tiles = cfoTiles(element);
        expect(tiles.length).toBe(3);
        expect(
            Array.from(tiles).map((t) =>
                t.querySelector('.cfo-tile-label').textContent.trim()
            )
        ).toEqual([
            'Call For Offers Date',
            'Days to Call for Offers',
            'Status'
        ]);

        // The date itself renders in the section — this is the assertion that proves the tile
        // MOVED rather than being deleted.
        expect(
            tiles[0].querySelector('.cfo-tile-value').textContent.trim()
        ).toBe(
            new Date(isoOffset(9) + 'T00:00:00').toLocaleDateString('en-US', {
                month: 'short',
                day: 'numeric',
                year: 'numeric'
            })
        );
    });

    it('CFO: a date well in the future counts down and reads On Track (green)', async () => {
        const element = createComponent();
        await emitWithCfoDate(element, isoOffset(21));

        expect(countdownText(element)).toBe('21 days');
        expect(pill(element).textContent.trim()).toBe('On Track');
        expect(pill(element).className).toContain('cfo-pill--green');
    });

    /**
     * 🔴 THE THRESHOLD, PINNED ON BOTH SIDES OF THE BOUNDARY. `DUE_SOON_DAYS` is 7 —
     * `CallForOffersService.APPROACHING_DAYS`. Day 8 is the last On Track day and day 7 the first
     * Due Soon day; asserting only one side would stay green for an off-by-one.
     */
    it('CFO: the Due Soon window opens at exactly 7 days, not 8 and not 6', async () => {
        const element = createComponent();

        await emitWithCfoDate(element, isoOffset(8));
        expect(pill(element).textContent.trim()).toBe('On Track');
        expect(pill(element).className).toContain('cfo-pill--green');

        await emitWithCfoDate(element, isoOffset(7));
        expect(countdownText(element)).toBe('7 days');
        expect(pill(element).textContent.trim()).toBe('Due Soon');
        expect(pill(element).className).toContain('cfo-pill--amber');

        await emitWithCfoDate(element, isoOffset(6));
        expect(pill(element).textContent.trim()).toBe('Due Soon');
    });

    it('CFO: one day out is singular — "1 day", never "1 days"', async () => {
        const element = createComponent();
        await emitWithCfoDate(element, isoOffset(1));

        expect(countdownText(element)).toBe('1 day');
        expect(pill(element).textContent.trim()).toBe('Due Soon');
    });

    /**
     * 🔴 DUE TODAY. `0` is falsy in JS, so the naive `value || '—'` collapses this into the
     * no-date case on the one day it matters most — the trap `callForOffersPanel.js` records
     * having been hit in the acquisition module. The countdown must say "Today" in words, and the
     * pill must NOT say Overdue: nothing has been missed yet.
     */
    it('CFO: a date of today reads "Today" / Due Soon — never "0", never Overdue, never a dash', async () => {
        const element = createComponent();
        await emitWithCfoDate(element, isoOffset(0));

        const countdown = countdownText(element);
        expect(countdown).toBe('Today');
        expect(countdown).not.toBe('—');
        expect(countdown).not.toMatch(/\b0\b/);

        expect(pill(element).textContent.trim()).toBe('Due Soon');
        expect(pill(element).className).toContain('cfo-pill--amber');
        expect(element.shadowRoot.textContent).not.toContain('Overdue');
    });

    it('CFO: a date in the past reads N days ago / Overdue (red), with no minus sign', async () => {
        const element = createComponent();

        await emitWithCfoDate(element, isoOffset(-5));
        expect(countdownText(element)).toBe('5 days ago');
        expect(countdownText(element)).not.toMatch(/-/);
        expect(pill(element).textContent.trim()).toBe('Overdue');
        expect(pill(element).className).toContain('cfo-pill--red');

        // Singular, and the first overdue day is day -1 — not day 0.
        await emitWithCfoDate(element, isoOffset(-1));
        expect(countdownText(element)).toBe('1 day ago');
        expect(pill(element).textContent.trim()).toBe('Overdue');
    });

    /**
     * 🔴 THE CASE THAT IS ACTUALLY ON SCREEN TODAY. Every live Disposition record has a blank
     * `Call_For_Offers_Date__c`, so this is the branch a user sees right now — and the one where a
     * wrong answer is a lie rather than a rounding error. "0 days" would read as "due today" and
     * "Overdue" would accuse someone of missing a deadline nobody set.
     */
    it('🔴 CFO: a BLANK date renders an em dash and "Not Scheduled" — never 0, never Overdue', async () => {
        const element = createComponent();
        await emitWithCfoDate(element, null);

        // The date tile itself.
        expect(
            cfoTiles(element)[0].querySelector('.cfo-tile-value').textContent.trim()
        ).toBe('—');

        // The countdown: an em dash, and provably not a number of any sign.
        const countdown = countdownText(element);
        expect(countdown).toBe('—');
        expect(countdown).not.toMatch(/\d/);
        expect(countdown).not.toBe('0');
        expect(countdown).not.toBe('0 days');

        // The status: neutral, and unmistakable in WORDS rather than by its grey alone.
        expect(pill(element).textContent.trim()).toBe('Not Scheduled');
        expect(pill(element).className).toContain('cfo-pill--muted');

        // 🔴 The whole card, not just the pill — nothing anywhere may claim a missed deadline.
        expect(element.shadowRoot.textContent).not.toContain('Overdue');
        expect(element.shadowRoot.textContent).not.toContain('Due Soon');
    });

    /**
     * ⚠ ABSENT AND NULL ARE THE SAME ANSWER. `BrokerListingController` omits the member entirely
     * rather than sending null in some payload shapes, and a check written only against `null`
     * would let `undefined` fall through to `NaN days`.
     */
    it('CFO: an ABSENT callForOffersDate behaves exactly like a null one', async () => {
        const element = createComponent();
        const { callForOffersDate, ...withoutDate } = LISTING;
        expect(callForOffersDate).toBeDefined(); // the fixture really did carry one

        getListing.emit(withoutDate);
        await Promise.resolve();

        expect(countdownText(element)).toBe('—');
        expect(pill(element).textContent.trim()).toBe('Not Scheduled');
        expect(element.shadowRoot.textContent).not.toContain('NaN');
    });

    /**
     * 🔴 THE PILL IS ONE SOURCE, SO ITS COLOUR AND ITS WORDS CANNOT DISAGREE. This is the
     * assertion that catches a future edit changing the threshold in only one of the two getters —
     * a green pill reading "Due Soon", which every test above would still pass individually.
     */
    it('CFO: the pill theme and the pill text agree on every band', async () => {
        const element = createComponent();
        const expected = [
            [null, 'Not Scheduled', 'muted'],
            [isoOffset(-1), 'Overdue', 'red'],
            [isoOffset(0), 'Due Soon', 'amber'],
            [isoOffset(7), 'Due Soon', 'amber'],
            [isoOffset(8), 'On Track', 'green']
        ];

        for (const [date, text, theme] of expected) {
            // eslint-disable-next-line no-await-in-loop
            await emitWithCfoDate(element, date);
            expect(pill(element).textContent.trim()).toBe(text);
            expect(pill(element).className).toBe(`cfo-pill cfo-pill--${theme}`);
        }
    });

    it('CFO: the section is accessible with a blank date (the live shape)', async () => {
        const element = createComponent();
        getListing.emit({ ...LISTING, callForOffersDate: null });
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // THE STYLESHEET, ASSERTED AS SOURCE TEXT
    //
    // 🔴 jsdom PERFORMS NO LAYOUT AND RESOLVES NO CUSTOM PROPERTIES, so `getComputedStyle` cannot
    // see a missing `gap`, a grid that stopped wrapping, or a token that resolves to an unreadable
    // colour. Every one of those is a REQUIREMENT of this section, and reading the stylesheet as
    // text is the only automated gate available for them. The alternative — asserting nothing — is
    // how three of these regressions have shipped in this repo before.
    // ─────────────────────────────────────────────────────────────────────────
    describe('the call-for-offers stylesheet', () => {
        const CSS = require('fs')
            .readFileSync(
                require('path').join(__dirname, '..', 'brokerListing.css'),
                'utf8'
            )
            // Strip comments first — otherwise the prose ABOUT a forbidden token matches the
            // search for that token and every absence assertion below is vacuously green.
            .replace(/\/\*[\s\S]*?\*\//g, '');

        /**
         * The declarations of one rule, by selector.
         *
         * ⚠ STRING SEARCH, NOT A BUILT REGEX. Every selector here starts with `.` and several
         * contain `--`, so a hand-built `new RegExp(selector + ...)` needs escaping that is easy
         * to get subtly wrong — and a regex that silently fails to match makes every assertion in
         * this block vacuous rather than red. Matching on `selector + ' {'` also stops `.cfo-tile`
         * from matching `.cfo-tile-icon`.
         */
        function rule(selector) {
            const at = CSS.indexOf(`${selector} {`);
            expect(at).toBeGreaterThan(-1); // the rule must exist at all
            const open = CSS.indexOf('{', at);
            const close = CSS.indexOf('}', open);
            expect(close).toBeGreaterThan(open);
            return CSS.slice(open + 1, close);
        }

        /**
         * 🔴 THE `gap` IS MARKUP, NOT POLISH. The LWC template compiler discards the whitespace
         * between sibling elements, so with these removed the tiles butt against one another and
         * each tile's value runs into its own label.
         */
        it('keeps the load-bearing gaps that replace the compiler-stripped whitespace', () => {
            expect(rule('.cfo-grid')).toMatch(/\bgap\s*:/);
            expect(rule('.cfo-tile')).toMatch(/\bgap\s*:/);
            expect(rule('.cfo-tile-value')).toMatch(/\bmargin-bottom\s*:/);
        });

        /** The tiles must reflow, not sit at a fixed three-across. */
        it('wraps: auto-fit + minmax, never a fixed three-column track', () => {
            const grid = rule('.cfo-grid');
            expect(grid).toMatch(/auto-fit/);
            expect(grid).toMatch(/minmax\(/);
            expect(grid).not.toMatch(/repeat\(\s*3\s*,/);
        });

        /** The divider is a token-driven rule, not a hardcoded border colour. */
        it('draws the divider from a token, not a literal colour', () => {
            const r = rule('.cfo-rule');
            expect(r).toMatch(/background:\s*var\(--slds-g-color-/);
            expect(r).not.toMatch(/background:\s*#[0-9a-fA-F]{3,8}\s*;/);
        });

        /**
         * 🔴 THE DARK-ON-DARK TRAP, PINNED. `--slds-g-color-<semantic>-container-1` is a SOLID DARK
         * fill in the SLDS 2 base theme (success is #2e844a), so pairing it with `-base-30` text
         * yields an unreadable pill — and no other gate in this pipeline sees it (the linter only
         * checks that a hook was used; axe's contrast rule is inert in jsdom). The pills must use
         * the `-base-95` tint, which is pale in light and near-black in dark.
         */
        it('tints the pills from *-base-95, never from *-container-1', () => {
            for (const theme of ['green', 'amber', 'red', 'muted']) {
                const r = rule(`.cfo-pill--${theme}`);
                expect(r).not.toMatch(/container-1/);
                expect(r).toMatch(/background:\s*var\(--slds-g-color-/);
                expect(r).toMatch(/color:\s*var\(--slds-g-color-/);
            }
            expect(rule('.cfo-pill--green')).toMatch(/success-base-95/);
            expect(rule('.cfo-pill--amber')).toMatch(/warning-base-95/);
            expect(rule('.cfo-pill--red')).toMatch(/error-base-95/);
        });

        /**
         * ⚠ EVERY COLOUR IN THE NEW SECTION IS A HOOK. A literal survives the theme switch
         * unchanged and so reads correctly in exactly one of light and dark.
         */
        it('uses no raw colour literal outside a var() fallback in the new section', () => {
            const section = CSS.slice(CSS.indexOf('.cfo-rule'));
            // Remove every `var(--hook, <fallback>)` — a fallback is allowed and required.
            const withoutFallbacks = section.replace(/var\([^)]*\)/g, 'VAR');
            expect(withoutFallbacks).not.toMatch(/#[0-9a-fA-F]{3,8}/);
            expect(withoutFallbacks).not.toMatch(/\b(rgb|rgba|hsl)\(/);
        });
    });

    it('is accessible', async () => {
        const element = createComponent();

        await emitAll(LISTING, SUBMISSIONS);

        await expect(element).toBeAccessible();
    });
});
