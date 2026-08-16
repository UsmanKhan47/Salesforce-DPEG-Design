/**
 * Jest for c-call-for-offers-panel.
 *
 * ⚠ Every error test passes an EXPLICIT body: `createApexTestWireAdapter.error()` defaults its body
 * to an OBJECT while the LDS adapter defaults to an ARRAY, so a no-arg `.error()` silently measures
 * the library's default string rather than the component's fallback.
 */
import { createElement } from 'lwc';
import CallForOffersPanel from 'c/callForOffersPanel';
import getForOpportunity from '@salesforce/apex/CallForOffersController.getForOpportunity';

jest.mock(
    '@salesforce/apex/CallForOffersController.getForOpportunity',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const CRITICAL = {
    opportunityId: '006000000000001AAA',
    propertyName: 'Magnolia Crossing',
    recordUrl: '/lightning/r/Opportunity/006000000000001AAA/view',
    receivedDate: '2026-07-01',
    dueDate: '2026-08-17',
    daysRemaining: 3,
    urgency: 'CRITICAL',
    label: 'Due in 3 days',
    detail: 'Offers are due Aug 17, 2026.',
    isUrgent: true,
    hasDueDate: true,
    dueInterval: 3,
    saleProcess: 'Call for Offers',
    listingBrokerName: 'Jane Broker',
    listingBrokerEmail: 'jane.broker@example.invalid',
    dealRoomLink: 'https://example.invalid/dealroom'
};

const NO_DEADLINE = {
    opportunityId: '006000000000001AAA',
    urgency: 'NO_DUE_DATE',
    label: 'No offer deadline',
    detail: 'This deal has no call-for-offers due date.',
    isUrgent: false,
    hasDueDate: false,
    dueInterval: null
};

function build(recordId = '006000000000001AAA') {
    const element = createElement('c-call-for-offers-panel', { is: CallForOffersPanel });
    element.recordId = recordId;
    document.body.appendChild(element);
    return element;
}

const flush = async () => {
    for (let i = 0; i < 5; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
};

describe('c-call-for-offers-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders the badge, the detail and the four rows for a live deadline', async () => {
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        expect(element.shadowRoot.querySelector('.cfo-badge').textContent.trim()).toBe(
            'Due in 3 days'
        );
        expect(element.shadowRoot.querySelector('.cfo-detail').textContent).toContain(
            'Offers are due Aug 17, 2026.'
        );

        const terms = [...element.shadowRoot.querySelectorAll('dt')].map((n) =>
            n.textContent.trim()
        );
        const values = [...element.shadowRoot.querySelectorAll('dd')].map((n) =>
            n.textContent.trim()
        );
        expect(terms).toEqual([
            'Offers due',
            'Days remaining',
            'Sale process',
            'Listing broker'
        ]);
        expect(values).toEqual(['Aug 17, 2026', '3', 'Call for Offers', 'Jane Broker']);
    });

    it('colour-codes the badge from the SERVER urgency, and every band maps to a theme', async () => {
        // The mapping is the only place the client interprets the band, so every member is walked.
        const expected = {
            NO_DUE_DATE: 'cfo-badge--muted',
            SCHEDULED: 'cfo-badge--green',
            APPROACHING: 'cfo-badge--amber',
            CRITICAL: 'cfo-badge--red',
            DUE_TODAY: 'cfo-badge--red',
            OVERDUE: 'cfo-badge--red'
        };
        for (const [urgency, cls] of Object.entries(expected)) {
            const element = build();
            getForOpportunity.emit({ ...CRITICAL, urgency });
            // eslint-disable-next-line no-await-in-loop
            await flush();
            expect(element.shadowRoot.querySelector('.cfo-badge').className).toContain(cls);
            document.body.removeChild(element);
        }
    });

    it('falls back to a muted badge for an unrecognised band rather than failing', async () => {
        // A stale key must degrade to grey, never throw — the recentOpportunities contract.
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, urgency: 'SOMETHING_NEW' });
        await flush();
        expect(element.shadowRoot.querySelector('.cfo-badge').className).toContain(
            'cfo-badge--muted'
        );
    });

    it('the badge label carries the state in WORDS, not colour alone', async () => {
        // Accessibility: the badge is colour-coded, so its meaning must also be readable as text.
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, urgency: 'OVERDUE', label: 'Overdue by 2 days' });
        await flush();
        expect(element.shadowRoot.querySelector('.cfo-badge').textContent).toContain('Overdue by 2');
    });

    it('renders a no-deadline state rather than an empty box', async () => {
        const element = build();
        getForOpportunity.emit(NO_DEADLINE);
        await flush();

        expect(element.shadowRoot.querySelector('.cfo-empty').textContent).toContain(
            'no call-for-offers due date'
        );
        expect(element.shadowRoot.querySelector('.cfo-badge')).toBeNull();
        expect(element.shadowRoot.querySelectorAll('dt')).toHaveLength(0);
    });

    it('shows an em dash for a blank sale process, broker or day count', async () => {
        const element = build();
        getForOpportunity.emit({
            ...CRITICAL,
            saleProcess: null,
            listingBrokerName: null,
            daysRemaining: null
        });
        await flush();

        const values = [...element.shadowRoot.querySelectorAll('dd')].map((n) =>
            n.textContent.trim()
        );
        expect(values).toEqual(['Aug 17, 2026', '—', '—', '—']);
    });

    it('shows zero days remaining as 0, not as an em dash', async () => {
        // `0` is falsy in JS, so a naive `value || '—'` renders a deal that is DUE TODAY as if it
        // had no countdown at all — the one day it matters most.
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, daysRemaining: 0, urgency: 'DUE_TODAY' });
        await flush();

        const values = [...element.shadowRoot.querySelectorAll('dd')].map((n) =>
            n.textContent.trim()
        );
        expect(values[1]).toBe('0');
    });

    it('hides the broker and deal-room links when the deal carries neither', async () => {
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, listingBrokerEmail: null, dealRoomLink: null });
        await flush();
        expect(element.shadowRoot.querySelectorAll('.cfo-link')).toHaveLength(0);
    });

    it('renders both links when the deal carries them, with a safe external target', async () => {
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        const links = [...element.shadowRoot.querySelectorAll('.cfo-link')];
        expect(links).toHaveLength(2);
        expect(links[0].getAttribute('href')).toBe('mailto:jane.broker@example.invalid');
        expect(links[1].getAttribute('href')).toBe('https://example.invalid/dealroom');
        expect(links[1].getAttribute('rel')).toBe('noopener noreferrer');
    });

    it('replaces the panel with an inline role=alert banner on a wire error', async () => {
        const element = build();
        getForOpportunity.error({ message: 'The offer deadline could not be loaded.' });
        await flush();

        const banner = element.shadowRoot.querySelector('.cfo-error');
        expect(banner).not.toBeNull();
        expect(banner.getAttribute('role')).toBe('alert');
        expect(banner.textContent).toContain('The offer deadline could not be loaded.');
        expect(element.shadowRoot.querySelector('.cfo-badge')).toBeNull();
    });

    it('ALSO fires an error toast — the failure must not be silently swallowed', async () => {
        const element = build();
        const handler = jest.fn();
        element.addEventListener('lightning__showtoast', handler);

        getForOpportunity.error({ message: 'The offer deadline could not be loaded.' });
        await flush();

        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.variant).toBe('error');
    });

    it('toasts ONCE per distinct error even when the wire re-delivers it', async () => {
        const element = build();
        const handler = jest.fn();
        element.addEventListener('lightning__showtoast', handler);

        getForOpportunity.error({ message: 'Same failure' });
        await flush();
        getForOpportunity.error({ message: 'Same failure' });
        await flush();

        expect(handler).toHaveBeenCalledTimes(1);
    });

    it('falls back to its own message when the error carries no body message', async () => {
        const element = build();
        getForOpportunity.error({});
        await flush();
        expect(element.shadowRoot.querySelector('.cfo-error').textContent).toContain(
            'Unable to load the offer deadline.'
        );
    });

    it('is accessible with a live deadline', async () => {
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();
        await expect(element).toBeAccessible();
    });

    it('is accessible in its error state', async () => {
        const element = build();
        getForOpportunity.error({ message: 'The offer deadline could not be loaded.' });
        await flush();
        await expect(element).toBeAccessible();
    });
});
