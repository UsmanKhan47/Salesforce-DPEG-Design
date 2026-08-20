/**
 * c-disposition-buyer-timeline
 * ---------------------------------------------------------------------------
 * Read-only: a single @wire(getTimeline, { dispositionId: '$recordId' }).
 *
 * 🔴 THE TWO FALSIFIERS THAT MATTER MOST HERE ARE THE DECLINED-ROW ONES.
 *   1. A declined party must render EM-DASHES IN ALL FIVE VALUE COLUMNS. The
 *      payload below deliberately gives the declined row a real
 *      `ndaSignedDate`, because that is EXACTLY THE STATE THE PRODUCTION DATA
 *      IS IN: `NDA_Signed_Status_Sync` never clears `Date_Signed__c`, so a
 *      `Signed -> Declined` party keeps a non-null date forever. (The service
 *      suppresses it before it crosses the boundary; this test proves the
 *      component would not render it even if it arrived.)
 *   2. The word "Declined" must be present as READABLE TEXT, and the row must
 *      carry an aria-label naming the state. This repo has a measured incident
 *      of a text->badge swap deleting accessible content a test had pinned —
 *      these assertions are that pin. A colour-only state would pass a visual
 *      review and fail a screen reader.
 *
 * Also pinned: server ordering is preserved (the component must NOT sort), a
 * negative duration never renders (the service nulls it and raises
 * `hasDateAnomaly`, which surfaces as a "Check dates" badge), and the error
 * branch renders a visible alert with NO card rather than a silent blank.
 */
import { createElement } from 'lwc';
import DispositionBuyerTimeline from 'c/dispositionBuyerTimeline';
import getTimeline from '@salesforce/apex/DispositionBuyerTimelineController.getTimeline';

jest.mock(
    '@salesforce/apex/DispositionBuyerTimelineController.getTimeline',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a0Y0000000000001AAA';
const EM_DASH = '—';

/** Active, fully progressed: all three dates and both durations. */
const COMPLETE_ROW = {
    ndaId: 'a0Z0000000000001AAA',
    buyerName: 'Dana Reyes',
    status: 'Signed',
    isDeclined: false,
    ndaSignedDate: '2026-03-02',
    materialsReleasedDate: '2026-03-09',
    firstOfferDate: '2026-03-24',
    daysToRelease: 7,
    daysToRespond: 15,
    hasDateAnomaly: false
};

/** Active, mid-journey: signed but nothing released yet — the common early state. */
const IN_FLIGHT_ROW = {
    ndaId: 'a0Z0000000000002AAA',
    buyerName: 'Priya Raman',
    status: 'Sent',
    isDeclined: false,
    ndaSignedDate: null,
    materialsReleasedDate: null,
    firstOfferDate: null,
    daysToRelease: null,
    daysToRespond: null,
    hasDateAnomaly: false
};

/**
 * Active, dates out of order. The service has ALREADY suppressed the negative
 * duration to null and raised the flag — that is the contract this component
 * renders against, and it is why `daysToRelease` is null and not -4.
 */
const ANOMALY_ROW = {
    ndaId: 'a0Z0000000000003AAA',
    buyerName: 'Marcus Bell',
    status: 'Signed',
    isDeclined: false,
    ndaSignedDate: '2026-04-10',
    materialsReleasedDate: '2026-04-06',
    firstOfferDate: null,
    daysToRelease: null,
    daysToRespond: null,
    hasDateAnomaly: true
};

/**
 * 🔴 DECLINED, CARRYING A RETAINED `ndaSignedDate`. See the header — this is the
 * real production shape, not a contrived one, and it is the whole reason this
 * fixture is not simply all-nulls.
 */
const DECLINED_ROW = {
    ndaId: 'a0Z0000000000004AAA',
    buyerName: 'Toby Okonkwo',
    status: 'Declined',
    isDeclined: true,
    ndaSignedDate: '2026-02-14',
    materialsReleasedDate: '2026-02-20',
    firstOfferDate: null,
    daysToRelease: 6,
    daysToRespond: null,
    hasDateAnomaly: false
};

// Server order: actives first, declined last. The component must not re-sort.
const TIMELINE = [COMPLETE_ROW, IN_FLIGHT_ROW, ANOMALY_ROW, DECLINED_ROW];

describe('c-disposition-buyer-timeline', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-buyer-timeline', {
            is: DispositionBuyerTimeline
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    /** Data rows only — the static heading row shares `.dbt-row` and must be excluded. */
    function dataRows(element) {
        return [...element.shadowRoot.querySelectorAll('.dbt-row')].filter(
            (row) => !row.classList.contains('dbt-head')
        );
    }

    /** The five value columns of a row, in template order, as text. */
    function valueCells(row) {
        return [...row.querySelectorAll('.dbt-c')]
            .filter((cell) => !cell.classList.contains('dbt-c-buyer'))
            .map((cell) => cell.textContent.trim());
    }

    it('renders nothing before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.dbt-card')).toBeNull();
    });

    it('EMPTY BRANCH: an empty list renders an empty state, not an error', async () => {
        const element = createComponent();

        getTimeline.emit([]);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.dbt-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.dbt-error')).toBeNull();
        expect(dataRows(element).length).toBe(0);
    });

    it('DATA BRANCH: one row per buyer, in the order the server returned', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const names = [...element.shadowRoot.querySelectorAll('.dbt-buyer')].map((el) =>
            el.textContent.trim()
        );
        expect(names).toEqual([
            'Dana Reyes',
            'Priya Raman',
            'Marcus Bell',
            'Toby Okonkwo'
        ]);
        // Declined is last, and it is last because the SERVER put it last — the
        // component does not sort. Reordering the payload would reorder this.
        expect(names[names.length - 1]).toBe('Toby Okonkwo');
    });

    it('DATA BRANCH: a complete row shows all three dates and both durations', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        expect(valueCells(dataRows(element)[0])).toEqual([
            'Mar 2, 2026',
            'Mar 9, 2026',
            'Mar 24, 2026',
            '7 days',
            '15 days'
        ]);
    });

    it('DATA BRANCH: a mid-journey row em-dashes only the values it lacks', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        expect(valueCells(dataRows(element)[1])).toEqual([
            EM_DASH,
            EM_DASH,
            EM_DASH,
            EM_DASH,
            EM_DASH
        ]);
        // It is ACTIVE, so it must not be styled or announced as terminated.
        expect(dataRows(element)[1].classList.contains('dbt-row--declined')).toBe(false);
    });

    it('🔴 DECLINED: em-dashes in ALL FIVE value columns, including the retained signed date', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const declinedRow = dataRows(element)[3];
        expect(valueCells(declinedRow)).toEqual([
            EM_DASH,
            EM_DASH,
            EM_DASH,
            EM_DASH,
            EM_DASH
        ]);
        // The payload carried a real 2026-02-14 signature date and a real
        // 6-day duration. Neither may appear anywhere in the row.
        expect(declinedRow.textContent).not.toContain('Feb 14');
        expect(declinedRow.textContent).not.toContain('6 days');
    });

    it('🔴 DECLINED: the state is READABLE TEXT plus an aria-label, not colour alone', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const declinedRow = dataRows(element)[3];

        // 1. Visible text. A future text->badge->icon swap that deletes this word
        //    fails HERE rather than silently in production.
        const badge = declinedRow.querySelector('.dbt-badge--declined');
        expect(badge).not.toBeNull();
        expect(badge.textContent.trim()).toBe('Declined');

        // 2. Accessible name for the whole row group.
        expect(declinedRow.getAttribute('role')).toBe('group');
        expect(declinedRow.getAttribute('aria-label')).toContain('Toby Okonkwo');
        expect(declinedRow.getAttribute('aria-label')).toContain('declined');

        // 3. Colour/style is reinforcement only — present, but never the sole signal.
        expect(declinedRow.classList.contains('dbt-row--declined')).toBe(true);
    });

    it('ANOMALY: out-of-order dates render no duration and raise a visible flag', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const anomalyRow = dataRows(element)[2];
        const cells = valueCells(anomalyRow);
        // Columns 4 and 5 are the two durations. Never a negative, never a number.
        expect(cells[3]).toBe(EM_DASH);
        expect(cells[4]).toBe(EM_DASH);
        expect(anomalyRow.textContent).not.toContain('-4');

        const flag = anomalyRow.querySelector('.dbt-badge--anomaly');
        expect(flag).not.toBeNull();
        expect(flag.textContent.trim()).toBe('Check dates');
    });

    it('ANOMALY: an ordinary row carries no flag', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        expect(dataRows(element)[0].querySelector('.dbt-badge--anomaly')).toBeNull();
    });

    it('DURATION: 1 renders singular, so the card never says "1 days"', async () => {
        const element = createComponent();

        getTimeline.emit([{ ...COMPLETE_ROW, daysToRelease: 1, daysToRespond: 0 }]);
        await Promise.resolve();

        const cells = valueCells(dataRows(element)[0]);
        expect(cells[3]).toBe('1 day');
        // 🔴 ZERO IS A REAL, MEANINGFUL DURATION (same-day) AND MUST NOT FALL
        // INTO THE EM-DASH BRANCH. A truthiness check instead of an explicit
        // null/undefined test is exactly how that regression happens.
        expect(cells[4]).toBe('0 days');
    });

    it('DATE PARSING: an ISO date renders as the same calendar day, not UTC-shifted', async () => {
        const element = createComponent();

        // 2026-01-01 is the canonical off-by-one trap: `new Date('2026-01-01')`
        // is UTC midnight, which renders as Dec 31 for any viewer west of GMT.
        getTimeline.emit([{ ...COMPLETE_ROW, ndaSignedDate: '2026-01-01' }]);
        await Promise.resolve();

        expect(valueCells(dataRows(element)[0])[0]).toBe('Jan 1, 2026');
    });

    it('ERROR BRANCH: a visible alert and NO card — never a silent blank', async () => {
        const element = createComponent();

        getTimeline.error();
        await Promise.resolve();

        const alert = element.shadowRoot.querySelector('.dbt-error');
        expect(alert).not.toBeNull();
        expect(alert.getAttribute('role')).toBe('alert');
        // An empty timeline would be a confident wrong answer. Neither the rows
        // nor the "no buyers yet" empty state may appear on the error branch.
        expect(dataRows(element).length).toBe(0);
        expect(element.shadowRoot.querySelector('.dbt-empty')).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible on the empty state', async () => {
        const element = createComponent();

        getTimeline.emit([]);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
