/**
 * c-listing-alerts — @wire-to-Apex suite.
 * Pattern: brokerListing template (createApexTestWireAdapter + emit/error).
 *
 * ── 🔴 WHAT THE PREVIOUS SUITE PINNED, AND WHY ITS DEATH IS THE POINT ───────
 * The retired suite asserted `['Day 21', 'Week 4', 'Week 6', 'Offer in']` — i.e. it was the
 * FALSIFIER FOR THE WRONG CLOCK, holding the 6-week ladder D27.1 overturned and the two D9-deferred
 * notification promises in place. Deleting those assertions is not "loosening a test"; keeping them
 * would have made the suite defend the defect.
 *
 * Every assertion below is on SERVER-COMPUTED text. This suite deliberately contains no copy of the
 * 30/60 ladder: the thresholds live once, in DispositionTractionService, and are proven there. A
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

const ON_TRACK = {
    band: 'ON_TRACK',
    label: 'Day 12 of 60 — On Track',
    detail: 'The day-30 traction check is due in 18 days.',
    daysOnMarket: 12,
    offerCount: 0,
    listingDate: '2026-07-01',
    checkpointDate: '2026-07-31',
    hardStopDate: '2026-08-30',
    daysRemaining: 48,
    isAtRisk: false,
    isListed: true,
    listingStatusValue: 'On Track',
    marketingPeriodDays: 60,
    checkpointDays: 30
};

const CHECKPOINT_DUE = {
    ...ON_TRACK,
    band: 'CHECKPOINT_DUE',
    label: 'Day 34 — Traction checkpoint: no offers',
    detail:
        'Month one has passed with no offers. Review the listing internally and decide whether to change the broker.',
    daysOnMarket: 34,
    daysRemaining: 26,
    isAtRisk: true,
    listingStatusValue: 'At Risk'
};

const HARD_STOP = {
    ...ON_TRACK,
    band: 'HARD_STOP',
    label: 'Day 71 — Hard Stop: no offers',
    detail: 'The 60-day marketing period has elapsed with no offers.',
    daysOnMarket: 71,
    daysRemaining: 0,
    isAtRisk: true,
    listingStatusValue: 'Hard Stop'
};

const WITH_OFFERS = {
    ...ON_TRACK,
    band: 'ON_TRACK',
    label: 'Day 44 of 60 — On Track',
    detail: '2 offers received, so the day-30 traction check does not apply.',
    daysOnMarket: 44,
    offerCount: 2,
    daysRemaining: 16,
    isAtRisk: false
};

const NOT_LISTED = {
    band: 'NOT_LISTED',
    label: 'Not listed yet',
    detail: 'The 60-day marketing clock starts when a listing date is set.',
    daysOnMarket: null,
    offerCount: 0,
    listingDate: null,
    checkpointDate: null,
    hardStopDate: null,
    daysRemaining: null,
    isAtRisk: false,
    isListed: false,
    listingStatusValue: 'On Track',
    marketingPeriodDays: 60,
    checkpointDays: 30
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

    function terms(element) {
        return Array.from(
            element.shadowRoot.querySelectorAll('.milestone-term')
        ).map((el) => el.textContent);
    }

    function values(element) {
        return Array.from(
            element.shadowRoot.querySelectorAll('.milestone-primary')
        ).map((el) => el.textContent);
    }

    it('renders the section header', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.section-header').textContent
        ).toBe('Listing Traction');
    });

    it('shows a loading state until the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.loading-msg')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.band-badge')).toBeNull();
    });

    it('DATA BRANCH: renders the server-computed band label and detail', async () => {
        const element = createComponent();

        getTraction.emit(ON_TRACK);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.band-badge').textContent
        ).toBe('Day 12 of 60 — On Track');
        expect(
            element.shadowRoot.querySelector('.band-detail').textContent
        ).toBe('The day-30 traction check is due in 18 days.');
        expect(element.shadowRoot.querySelector('.loading-msg')).toBeNull();
    });

    it('DATA BRANCH: renders the four milestone rows with the checkpoint still ahead', async () => {
        const element = createComponent();

        getTraction.emit(ON_TRACK);
        await Promise.resolve();

        expect(terms(element)).toEqual([
            'Days on market',
            'Day 30 traction check',
            'Day 60 marketing period ends',
            'Offers received'
        ]);
        expect(values(element)).toEqual([
            '12 of 60',
            'Jul 31, 2026',
            'Aug 30, 2026',
            '0 offers'
        ]);
        const notes = Array.from(
            element.shadowRoot.querySelectorAll('.milestone-note')
        ).map((el) => el.textContent);
        expect(notes[1]).toBe('In 18 days.');
        expect(notes[2]).toBe('48 days remaining.');
    });

    it('DATA BRANCH: the checkpoint row reads "Reached." once day 30 has passed', async () => {
        const element = createComponent();

        getTraction.emit(CHECKPOINT_DUE);
        await Promise.resolve();

        const notes = Array.from(
            element.shadowRoot.querySelectorAll('.milestone-note')
        ).map((el) => el.textContent);
        expect(notes[1]).toBe('Reached.');
        expect(
            element.shadowRoot.querySelector('.band-badge').className
        ).toContain('band--yellow');
    });

    it('DATA BRANCH: HARD_STOP colours red and reports the period elapsed', async () => {
        const element = createComponent();

        getTraction.emit(HARD_STOP);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.band-badge').className
        ).toContain('band--red');
        const notes = Array.from(
            element.shadowRoot.querySelectorAll('.milestone-note')
        ).map((el) => el.textContent);
        expect(notes[2]).toBe('Elapsed.');
    });

    it('DATA BRANCH: an offer is traction — day 44 still renders green', async () => {
        const element = createComponent();

        getTraction.emit(WITH_OFFERS);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.band-badge').className
        ).toContain('band--green');
        expect(values(element)[3]).toBe('2 offers');
        const notes = Array.from(
            element.shadowRoot.querySelectorAll('.milestone-note')
        ).map((el) => el.textContent);
        expect(notes[3]).toBe('An offer counts as traction.');
    });

    it('DATA BRANCH: NOT_LISTED shows one row and no clock bar — never a healthy-looking day 0', async () => {
        const element = createComponent();

        getTraction.emit(NOT_LISTED);
        await Promise.resolve();

        expect(terms(element)).toEqual(['Marketing clock']);
        expect(values(element)).toEqual(['Not started']);
        expect(element.shadowRoot.querySelector('.clock-track')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.band-badge').textContent
        ).toBe('Not listed yet');
    });

    it('ERROR BRANCH: renders an inline alert and no band when the wire errors', async () => {
        const element = createComponent();

        getTraction.error();
        await Promise.resolve();

        const err = element.shadowRoot.querySelector('.wire-error');
        expect(err).not.toBeNull();
        expect(err.getAttribute('role')).toBe('alert');
        expect(err.textContent).toContain('could not be loaded');
        expect(element.shadowRoot.querySelector('.band-badge')).toBeNull();
        expect(element.shadowRoot.querySelector('.loading-msg')).toBeNull();
    });

    /**
     * 🔴 THE D9 GUARD. This is the assertion that stops the retired mock creeping back: the panel
     * must never claim that anyone is emailed, alerted or flagged, and must never assert the
     * unsourced "Clock PAUSES" rule. It is a text-level check on purpose — the defect it prevents
     * was text, not logic.
     */
    it('never advertises a notification or the unsourced "clock pauses" rule', async () => {
        const element = createComponent();

        getTraction.emit(CHECKPOINT_DUE);
        await Promise.resolve();

        const rendered = element.shadowRoot.textContent.toLowerCase();
        ['email', 'alert to', 'notif', 'pause', 'week 4', 'week 6'].forEach(
            (banned) => {
                expect(rendered).not.toContain(banned);
            }
        );
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTraction.emit(CHECKPOINT_DUE);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
