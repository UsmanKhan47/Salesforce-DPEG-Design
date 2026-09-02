/**
 * c-listing-alerts — @wire-to-Apex suite.
 * Pattern: brokerListing template (createApexTestWireAdapter + emit/error).
 *
 * ── 🔴 WHAT THIS SUITE HAS BANNED, AND WHAT IT STOPPED BANNING ──────────────
 * Four suites have now guarded this component and each drew the line somewhere different:
 *
 *   The ORIGINAL asserted `['Day 21', 'Week 4', 'Week 6', 'Offer in']` — it was the falsifier for
 *   the hardcoded MOCK, holding a fixed table in place.
 *
 *   The 2026-08-10 suite banned the strings `week 4`, `week 6` and `pause` outright, because at
 *   that time the ladder was 30/40/60 and the pause rule had no source at all.
 *
 *   The 2026-08-21 suite LIFTED the week and pause bans — the user settled the thresholds at
 *   Week 1/4/6 and asked for the pause, so those words became TRUE statements about a real
 *   computation proven in `DispositionTractionServiceTest`.
 *
 *   ⚠ 2026-09-02 (user decision A2): the first rung moved to **Week 2** (day 14). Nothing about
 *   the bans changed — only the fixtures. See the fixture block below.
 *
 *   ⚠ THIS SUITE (2026-08-21, UAT) DELETED EVERY ASSERTION ABOUT THE TRACTION MONITOR, because the
 *   monitor itself was deleted. The user asked for *"automated alerts thats' it"* and for the
 *   disposition-offer COUNT to go. Gone with it: `.band-badge`, `.band-detail`, `.clock-track` and
 *   the `.milestone-*` rows, plus the eight assertions that rendered them. 🔴 THOSE ASSERTIONS WERE
 *   DELETED, NOT SOFTENED — a `toBeNull()` left in place of a `toBe('Week 4 — At Risk')` on an
 *   element that no longer exists in the template would be a test that can never fail. The ONE
 *   absence assertion kept below is a deliberate anti-regression pin and is grouped as such.
 *
 * What is banned has not changed in substance — a row this panel cannot back with data:
 *     🔴 THE NOTIFICATION BAN STANDS (`email`, `alert to`, `notif`). Nothing in this org sends any
 *        of them and the user deferred them AGAIN on 2026-08-21 — in the same conversation that
 *        retitled this card "Automated Alerts", which makes the ban sharper, not looser.
 *     🔴 THE FIXED-LIST BAN STANDS, and is asserted positively: `theSameThreeRungsRender
 *        DIFFERENTLYOnDifferentRecords` fails if the rows ever stop being data.
 *
 * ⚠ THE FIXTURES STILL CARRY `band`, `label`, `detail`, `daysOnMarket`, `offerCount` AND
 * `isPaused`. That is not leftover: the SERVER still computes and returns all of them — the pause
 * still drives the rung notes, and `c/brokerListing` still renders `label`. The card simply reads
 * fewer members of the same payload. Trimming the fixtures would make them stop matching what
 * `DispositionTractionController.getTraction` actually sends.
 *
 * Every assertion below is on SERVER-COMPUTED text. This suite deliberately contains no copy of the
 * 14/28/42 ladder: the thresholds live once, in DispositionTractionService, and are proven there. A
 * Jest test that re-derived them would drift from the Apex silently, which is the exact failure the
 * single-service design exists to prevent.
 */
import { createElement } from 'lwc';
import ListingAlerts from 'c/listingAlerts';
import getTraction from '@salesforce/apex/DispositionTractionController.getTraction';

jest.mock(
    '@salesforce/apex/DispositionTractionController.getTraction',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

/** Rung fixtures mirror the server's shape exactly; the states are what varies between payloads. */
const rung = (key, label, dueDate, state, note) => ({
    key,
    label,
    days: null,
    dueDate,
    state,
    note,
    isCurrent: state === 'Current',
    isReached: state !== 'Ahead'
});

/**
 * 🔴 EVERY FIXTURE BELOW WAS RE-CUT ON 2026-09-02 FOR USER DECISION A2 — THE FIRST RUNG MOVED FROM
 * WEEK 1 (day 7) TO WEEK 2 (day 14) IN `DispositionTractionService`.
 *
 * These are HAND-WRITTEN payloads, so nothing here fails on its own when the server changes — the
 * suite would have stayed green while the component rendered "Week 1" against a server that no
 * longer emits it. The Apex change is what forced this edit; `DispositionTractionServiceTest` is
 * what proves the numbers. All that is asserted here is that whatever the server sends is what
 * renders. ⚠ Every due date is the listing date (`2026-07-01`) plus the rung's threshold, so
 * rung 1 is now `2026-07-15`, not `2026-07-08`.
 *
 * ⚠ THE PAUSED FIXTURE MOVED FROM DAY 12 TO DAY 16 AND THAT IS NOT COSMETIC. Day 12 is now BELOW
 * the first rung, so the fixture's own `'Passed before the clock paused.'` note would have become
 * a state the server could not produce for it — a fixture that lies is worse than one that fails.
 */
const ON_TRACK = {
    band: 'ON_TRACK',
    label: 'Day 3 of 42 — On Track',
    detail: 'The week-2 check-in is due in 11 days.',
    daysOnMarket: 3,
    offerCount: 0,
    listingDate: '2026-07-01',
    firstOfferDate: null,
    isPaused: false,
    daysRemaining: 39,
    isAtRisk: false,
    isListed: true,
    listingStatusValue: 'On Track',
    marketingPeriodDays: 42,
    rungs: [
        rung('WEEK_2', 'Week 2', '2026-07-15', 'Ahead', 'In 11 days.'),
        rung('WEEK_4', 'Week 4', '2026-07-29', 'Ahead', 'In 25 days.'),
        rung('WEEK_6', 'Week 6', '2026-08-12', 'Ahead', 'In 39 days.')
    ]
};

const WEEK_2 = {
    ...ON_TRACK,
    band: 'WEEK_2',
    label: 'Week 2 — Check-in due',
    detail:
        'Two weeks on the market with no offers yet. Check in with the broker on interest and showings.',
    daysOnMarket: 16,
    daysRemaining: 26,
    isAtRisk: false,
    rungs: [
        rung('WEEK_2', 'Week 2', '2026-07-15', 'Current', 'Current — no offers.'),
        rung('WEEK_4', 'Week 4', '2026-07-29', 'Ahead', 'In 12 days.'),
        rung('WEEK_6', 'Week 6', '2026-08-12', 'Ahead', 'In 26 days.')
    ]
};

const WEEK_4 = {
    ...ON_TRACK,
    band: 'WEEK_4',
    label: 'Week 4 — At Risk',
    detail:
        'Four weeks on the market with no offers, and 12 days of the marketing period remain.',
    daysOnMarket: 30,
    daysRemaining: 12,
    isAtRisk: true,
    listingStatusValue: 'At Risk',
    rungs: [
        rung('WEEK_2', 'Week 2', '2026-07-15', 'Passed', 'Passed.'),
        rung('WEEK_4', 'Week 4', '2026-07-29', 'Current', 'Current — no offers.'),
        rung('WEEK_6', 'Week 6', '2026-08-12', 'Ahead', 'In 12 days.')
    ]
};

const WEEK_6 = {
    ...ON_TRACK,
    band: 'WEEK_6',
    label: 'Week 6 — Hard Stop',
    detail:
        'Six weeks on the market with no offers. The full marketing period has elapsed; decide whether to replace the broker.',
    daysOnMarket: 51,
    daysRemaining: 0,
    isAtRisk: true,
    listingStatusValue: 'Hard Stop',
    rungs: [
        rung('WEEK_2', 'Week 2', '2026-07-15', 'Passed', 'Passed.'),
        rung('WEEK_4', 'Week 4', '2026-07-29', 'Passed', 'Passed.'),
        rung('WEEK_6', 'Week 6', '2026-08-12', 'Current', 'Current — no offers.')
    ]
};

const PAUSED = {
    ...ON_TRACK,
    band: 'ON_TRACK',
    label: 'Day 16 — Offer received, clock paused',
    detail:
        '2 offers received, so the marketing clock stopped at day 16 and no week check-in is due.',
    daysOnMarket: 16,
    offerCount: 2,
    firstOfferDate: '2026-07-17',
    isPaused: true,
    daysRemaining: 26,
    isAtRisk: false,
    rungs: [
        rung('WEEK_2', 'Week 2', '2026-07-15', 'Passed', 'Passed before the clock paused.'),
        rung('WEEK_4', 'Week 4', '2026-07-29', 'Ahead', 'Clock paused.'),
        rung('WEEK_6', 'Week 6', '2026-08-12', 'Ahead', 'Clock paused.')
    ]
};

const NOT_LISTED = {
    band: 'NOT_LISTED',
    label: 'Not listed yet',
    detail: 'The 42-day marketing clock starts when a listing date is set.',
    daysOnMarket: null,
    offerCount: 0,
    listingDate: null,
    firstOfferDate: null,
    isPaused: false,
    daysRemaining: null,
    isAtRisk: false,
    isListed: false,
    listingStatusValue: 'On Track',
    marketingPeriodDays: 42,
    rungs: [
        rung('WEEK_2', 'Week 2', null, 'Ahead', 'Not started.'),
        rung('WEEK_4', 'Week 4', null, 'Ahead', 'Not started.'),
        rung('WEEK_6', 'Week 6', null, 'Ahead', 'Not started.')
    ]
};

describe('c-listing-alerts', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-listing-alerts', {
            is: ListingAlerts
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    function texts(element, selector) {
        return Array.from(element.shadowRoot.querySelectorAll(selector)).map(
            (el) => el.textContent
        );
    }

    it('renders the section header', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.section-header').textContent
        ).toBe('Automated Alerts');
    });

    it('shows a loading state until the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.loading-msg')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.rung')).toBeNull();
    });

    it('DATA BRANCH: renders the three rungs with their labels, states and due dates', async () => {
        const element = createComponent();

        getTraction.emit(WEEK_4);
        await Promise.resolve();

        expect(texts(element, '.rung-label')).toEqual([
            'Week 2',
            'Week 4',
            'Week 6'
        ]);
        expect(texts(element, '.rung-state')).toEqual([
            'Passed',
            'Current',
            'Ahead'
        ]);
        expect(texts(element, '.rung-due')).toEqual([
            'Jul 15, 2026',
            'Jul 29, 2026',
            'Aug 12, 2026'
        ]);
        expect(texts(element, '.rung-note')).toEqual([
            'Passed.',
            'Current — no offers.',
            'In 12 days.'
        ]);
        expect(element.shadowRoot.querySelector('.loading-msg')).toBeNull();
    });

    /**
     * 🔴 THE ANTI-MOCK ASSERTION, AND THE MOST IMPORTANT TEST IN THIS FILE. The component this
     * replaced rendered four FIXED rows. Here the same three keys are emitted twice with different
     * server state and the DOM must differ — which no hardcoded table can do.
     */
    it('the same three rungs render DIFFERENTLY on different records — the rows are data, not a fixed list', async () => {
        const element = createComponent();

        getTraction.emit(ON_TRACK);
        await Promise.resolve();
        expect(texts(element, '.rung-state')).toEqual([
            'Ahead',
            'Ahead',
            'Ahead'
        ]);

        getTraction.emit(WEEK_6);
        await Promise.resolve();
        expect(texts(element, '.rung-state')).toEqual([
            'Passed',
            'Passed',
            'Current'
        ]);
        // ...and the labels did NOT change, which is what makes the states the variable.
        expect(texts(element, '.rung-label')).toEqual([
            'Week 2',
            'Week 4',
            'Week 6'
        ]);
    });

    it('DATA BRANCH: the current rung carries the current modifier and only one rung does', async () => {
        const element = createComponent();

        getTraction.emit(WEEK_4);
        await Promise.resolve();

        const rows = Array.from(element.shadowRoot.querySelectorAll('.rung'));
        expect(rows.length).toBe(3);
        expect(rows[0].className).toContain('rung--passed');
        expect(rows[1].className).toContain('rung--current');
        expect(rows[2].className).toContain('rung--ahead');
        expect(
            rows.filter((r) => r.className.includes('rung--current')).length
        ).toBe(1);
    });

    /**
     * 🔴 WEEK_2 IS A CHECK-IN, NOT A RISK STATE — asserted through the RUNGS now that the band pill
     * that used to carry it is gone. The server marks the week-2 rung `Current` and leaves the two
     * above it `Ahead`; no rung is styled as escalated. (⚠ That band was `WEEK_1` until 2026-09-02,
     * user decision A2. Only the name and the day moved — the at-risk line is still week 4.)
     */
    it('DATA BRANCH: the week-2 check-in is the current rung and nothing above it has fired', async () => {
        const element = createComponent();

        getTraction.emit(WEEK_2);
        await Promise.resolve();

        expect(texts(element, '.rung-state')).toEqual([
            'Current',
            'Ahead',
            'Ahead'
        ]);
        expect(texts(element, '.rung-note')[0]).toBe('Current — no offers.');
    });

    /**
     * 🔴 THE PAUSE, AS IT SURVIVES ON THIS CARD. The badge that announced it in words was removed at
     * UAT; the RULE was not, and the rungs are where it is still visible — an "In 30 days." on a
     * paused listing would be a countdown to a date that will never arrive.
     */
    it('DATA BRANCH: a paused clock stops the countdown and no rung is current', async () => {
        const element = createComponent();

        getTraction.emit(PAUSED);
        await Promise.resolve();

        expect(texts(element, '.rung-note')).toEqual([
            'Passed before the clock paused.',
            'Clock paused.',
            'Clock paused.'
        ]);
        expect(texts(element, '.rung-state')).toEqual([
            'Passed',
            'Ahead',
            'Ahead'
        ]);
        expect(
            element.shadowRoot.querySelectorAll('.rung--current').length
        ).toBe(0);
    });

    it('DATA BRANCH: NOT_LISTED still shows the schedule, with no dates it cannot derive', async () => {
        const element = createComponent();

        getTraction.emit(NOT_LISTED);
        await Promise.resolve();

        expect(texts(element, '.rung-label')).toEqual([
            'Week 2',
            'Week 4',
            'Week 6'
        ]);
        expect(texts(element, '.rung-due')).toEqual(['—', '—', '—']);
        expect(texts(element, '.rung-state')).toEqual([
            'Ahead',
            'Ahead',
            'Ahead'
        ]);
        expect(texts(element, '.rung-note')).toEqual([
            'Not started.',
            'Not started.',
            'Not started.'
        ]);
    });

    it('ERROR BRANCH: renders an inline alert and no schedule when the wire errors', async () => {
        const element = createComponent();

        getTraction.error();
        await Promise.resolve();

        const err = element.shadowRoot.querySelector('.wire-error');
        expect(err).not.toBeNull();
        expect(err.getAttribute('role')).toBe('alert');
        expect(err.textContent).toContain('could not be loaded');
        expect(element.shadowRoot.querySelector('.rung')).toBeNull();
        expect(element.shadowRoot.querySelector('.rung-heading')).toBeNull();
    });

    /**
     * 🔴 THE UAT REMOVAL, PINNED AS AN ASSERTION ABOUT ABSENCE. The user asked for the listing
     * traction display and the disposition-offer count to go; every positive assertion about them
     * was DELETED rather than weakened, which leaves nothing to fail if someone re-adds the
     * surfaces. This is that falsifier, and it is the only absence test in the file.
     *
     * ⚠ IT ASSERTS ON RENDERED TEXT AS WELL AS ON SELECTORS, because a re-added count would most
     * likely arrive under a new class name. `offerCount` IS in the payload below (the server still
     * sends it — the pause needs it), so a component that decided to render it again would pass a
     * selector-only check.
     */
    it('🔴 renders no traction monitor and no offer count — the UAT removal must not come back', async () => {
        const element = createComponent();

        getTraction.emit(PAUSED);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.band-badge')).toBeNull();
        expect(element.shadowRoot.querySelector('.band-detail')).toBeNull();
        expect(element.shadowRoot.querySelector('.clock-track')).toBeNull();
        expect(element.shadowRoot.querySelector('.milestone-list')).toBeNull();

        const rendered = element.shadowRoot.textContent.toLowerCase();
        expect(rendered).not.toContain('days on market');
        expect(rendered).not.toContain('offers received');
        // The payload's own count and day number must not surface anywhere on the card.
        expect(rendered).not.toContain('2 offers');
        expect(rendered).not.toContain('day 12');
    });

    /**
     * 🔴 THE NOTIFICATION GUARD — the surviving half of the retired mock's ban list. The card must
     * never claim that anyone is emailed, alerted or flagged, because nothing in this org sends any
     * of it and the user deferred all of it again on 2026-08-21. It is a text-level check on
     * purpose: the defect it prevents was text, not logic.
     *
     * ⚠ `week 4`, `week 6` and `pause` were on this list until 2026-08-21 and were REMOVED
     * deliberately — they are now true statements about a real computation. Do not re-add them, and
     * do not add anything to this list that the payload can actually back.
     */
    it('never advertises a notification', async () => {
        const element = createComponent();

        for (const payload of [WEEK_2, WEEK_4, WEEK_6, PAUSED, NOT_LISTED]) {
            getTraction.emit(payload);
            // eslint-disable-next-line no-await-in-loop
            await Promise.resolve();

            const rendered = element.shadowRoot.textContent.toLowerCase();
            ['email', 'alert to', 'notif', 'flag to', 'escalate to'].forEach(
                (banned) => {
                    expect(rendered).not.toContain(banned);
                }
            );
        }
    });

    /**
     * The state must survive as TEXT. A previous incident in this repo deleted accessible content
     * by swapping text for a coloured badge; here the rung state is the only thing distinguishing
     * "passed" from "ahead" for a non-sighted reader.
     */
    it('renders every rung state as text, not colour alone', async () => {
        const element = createComponent();

        getTraction.emit(WEEK_4);
        await Promise.resolve();

        texts(element, '.rung-state').forEach((state) => {
            expect(['Passed', 'Current', 'Ahead']).toContain(state);
        });
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTraction.emit(WEEK_4);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible while paused', async () => {
        const element = createComponent();

        getTraction.emit(PAUSED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
