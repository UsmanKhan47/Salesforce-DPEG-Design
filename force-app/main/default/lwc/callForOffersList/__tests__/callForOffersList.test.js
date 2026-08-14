/**
 * Jest for c-call-for-offers-list.
 *
 * ⚠ `.error()` DEFAULT BODY SHAPES DIFFER BETWEEN ADAPTERS, so every error test here passes an
 * EXPLICIT body. `createApexTestWireAdapter.error()` defaults its body to an OBJECT
 * (`{ message: 'An internal server error has occurred' }`), while the LDS adapter defaults to an
 * ARRAY — so a no-arg `.error()` test that asserts a component's hardcoded fallback passes for LDS
 * and fails for Apex, having silently measured the library's default string instead.
 */
import { createElement } from 'lwc';
import CallForOffersList from 'c/callForOffersList';
import getUpcoming from '@salesforce/apex/CallForOffersController.getUpcoming';

jest.mock(
    '@salesforce/apex/CallForOffersController.getUpcoming',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock('lightning/navigation', () => {
    const Navigate = Symbol('Navigate');
    const GenerateUrl = Symbol('GenerateUrl');
    const NavigationMixin = (Base) =>
        class extends Base {
            [Navigate](ref) {
                this.dispatchEvent(new CustomEvent('navigate', { detail: ref }));
            }
            [GenerateUrl]() {
                return Promise.resolve('/lightning/o/Opportunity/list');
            }
        };
    NavigationMixin.Navigate = Navigate;
    NavigationMixin.GenerateUrl = GenerateUrl;
    return { NavigationMixin, CurrentPageReference: jest.fn() };
});

const DEALS = [
    {
        opportunityId: '006000000000001AAA',
        propertyName: 'Magnolia Crossing',
        recordUrl: '/lightning/r/Opportunity/006000000000001AAA/view',
        receivedDate: '2026-07-01',
        dealArrivedDate: '2026-02-10',
        dueDate: '2026-08-17',
        daysRemaining: 3,
        urgency: 'CRITICAL',
        label: 'Due in 3 days',
        detail: 'Offers are due Aug 17, 2026.',
        isUrgent: true,
        hasDueDate: true,
        dueInterval: 3
    },
    {
        opportunityId: '006000000000002AAA',
        propertyName: 'Cedar Park Plaza',
        recordUrl: '/lightning/r/Opportunity/006000000000002AAA/view',
        receivedDate: '2026-06-15',
        dealArrivedDate: '2026-01-05',
        dueDate: '2026-08-30',
        daysRemaining: 16,
        urgency: 'SCHEDULED',
        label: 'Due in 16 days',
        detail: 'Offers are due Aug 30, 2026.',
        isUrgent: false,
        hasDueDate: true,
        dueInterval: null
    }
];

function build() {
    const element = createElement('c-call-for-offers-list', { is: CallForOffersList });
    document.body.appendChild(element);
    return element;
}

const flush = async () => {
    for (let i = 0; i < 5; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
};

describe('c-call-for-offers-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders one row per deal with the title count', async () => {
        const element = build();
        getUpcoming.emit(DEALS);
        await flush();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table).not.toBeNull();
        expect(table.data).toHaveLength(2);
        expect(element.shadowRoot.querySelector('span[slot="title"]').textContent).toBe(
            'Call for Offers (2)'
        );
    });

    it('renders the SERVER label as the countdown rather than counting days itself', async () => {
        // 🔴 THE ASSERTION THAT PROTECTS THE SHARED LADDER. If a future change computes the day count
        // in JS, this fails — and a JS ladder would drift from the one CallForOffersAlertBatch fires
        // on, so a deal could be red in the table and unalerted in the queue.
        const element = build();
        getUpcoming.emit(DEALS);
        await flush();

        const rows = element.shadowRoot.querySelector('c-list-datatable').data;
        expect(rows[0].countdown).toBe('Due in 3 days');
        expect(rows[1].countdown).toBe('Due in 16 days');
    });

    it('formats dates without new Date(), so they cannot shift a day by time zone', async () => {
        // `new Date('2026-08-17')` parses as UTC midnight and renders as Aug 16 west of Greenwich —
        // an off-by-one on the one number this component is about.
        const element = build();
        getUpcoming.emit(DEALS);
        await flush();

        const rows = element.shadowRoot.querySelector('c-list-datatable').data;
        expect(rows[0].dueLabel).toBe('Aug 17, 2026');
        expect(rows[0].receivedLabel).toBe('Jul 1, 2026');
    });

    it('shows an em dash rather than a broken date when a date is missing', async () => {
        const element = build();
        getUpcoming.emit([
            { ...DEALS[0], receivedDate: null, dealArrivedDate: null, dueDate: null }
        ]);
        await flush();

        const rows = element.shadowRoot.querySelector('c-list-datatable').data;
        expect(rows[0].receivedLabel).toBe('—');
        expect(rows[0].dueLabel).toBe('—');
    });

    it('renders the STAMPED received date and never the deal-arrival proxy', async () => {
        // 🔴 THE CLIENT HALF OF THE 2026-08-14 CHANGE. Until then this column showed
        // `Broker_First_Seen__c ?? CreatedDate` — when the DEAL arrived — under the heading
        // "Received". The fixture makes the two disagree by five months so a coalesce cannot
        // pass: `formatDate(r.receivedDate || r.dealArrivedDate)` would still print a plausible
        // date, which is exactly why this needs a test rather than review.
        const element = build();
        getUpcoming.emit(DEALS);
        await flush();

        const rows = element.shadowRoot.querySelector('c-list-datatable').data;
        expect(rows[0].receivedLabel).toBe('Jul 1, 2026');
        expect(rows[0].receivedLabel).not.toContain('Feb');
        expect(rows[0].receivedLabel).not.toContain('Deal arrived');
    });

    it('LABELS the deal-arrival fallback in words when nothing has been stamped yet', async () => {
        // The migration affordance. The stamped field only exists on deals a call-for-offers email
        // has actually matched, so a long-lived population arrives here with a deadline and no
        // received date. It still shows the deal's arrival — but the cell SAYS SO, because a bare
        // date in this column is read as an email timestamp.
        //
        // ⚠ A "~" or a tooltip would not do: both are scanned past in a dense table. If this
        // assertion is ever relaxed to a symbol, the distinction has been given up.
        const element = build();
        getUpcoming.emit([{ ...DEALS[0], receivedDate: null }]);
        await flush();

        const rows = element.shadowRoot.querySelector('c-list-datatable').data;
        expect(rows[0].receivedLabel).toBe('Deal arrived Feb 10, 2026');
    });

    it('keeps the Received column wide enough for the labelled fallback', async () => {
        // ⚠ THIS ASSERTS THE CONFIGURED WIDTH, NOT THE RENDERED FIT, AND CANNOT ASSERT MORE:
        // jsdom performs no layout, so scrollWidth/clientWidth are 0 here and the obvious
        // overflow test would be vacuously green. What it does catch is someone restoring the
        // pre-change 130px — at which point the "Deal arrived" caveat, not the date, is what the
        // ellipsis eats. The rendered fit is a UAT check.
        const element = build();
        getUpcoming.emit(DEALS);
        await flush();

        const received = element.shadowRoot
            .querySelector('c-list-datatable')
            .columns.find((c) => c.label === 'Received');
        expect(received.initialWidth).toBeGreaterThanOrEqual(190);
    });

    it('renders an empty state instead of a table when nothing matches', async () => {
        const element = build();
        getUpcoming.emit([]);
        await flush();

        expect(element.shadowRoot.querySelector('c-list-datatable')).toBeNull();
        expect(element.shadowRoot.querySelector('.lv-empty').textContent).toContain(
            'No deals have a call-for-offers deadline'
        );
    });

    it('replaces the table with an inline role=alert banner on a wire error', async () => {
        const element = build();
        getUpcoming.error({ message: 'Call for offers could not be loaded.' });
        await flush();

        const banner = element.shadowRoot.querySelector('.lv-error');
        expect(banner).not.toBeNull();
        expect(banner.getAttribute('role')).toBe('alert');
        expect(banner.textContent).toContain('Call for offers could not be loaded.');
        expect(element.shadowRoot.querySelector('c-list-datatable')).toBeNull();
    });

    it('ALSO fires an error toast — the failure must not be silently swallowed', async () => {
        // 🔴 The 2026-07-19 audit found eight components swallowing their @wire error branch. This is
        // the assertion that stops this one joining them.
        const element = build();
        const handler = jest.fn();
        element.addEventListener('lightning__showtoast', handler);

        getUpcoming.error({ message: 'Call for offers could not be loaded.' });
        await flush();

        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.variant).toBe('error');
        expect(handler.mock.calls[0][0].detail.message).toBe('Call for offers could not be loaded.');
    });

    it('toasts ONCE per distinct error even when the wire re-delivers it', async () => {
        // A wire can re-deliver the same error on every re-render. Toasting each time turns one
        // failure into a stack of identical toasts nobody reads.
        const element = build();
        const handler = jest.fn();
        element.addEventListener('lightning__showtoast', handler);

        getUpcoming.error({ message: 'Same failure' });
        await flush();
        getUpcoming.error({ message: 'Same failure' });
        await flush();

        expect(handler).toHaveBeenCalledTimes(1);

        // A DIFFERENT error is a new fact and must be toasted.
        getUpcoming.error({ message: 'A different failure' });
        await flush();
        expect(handler).toHaveBeenCalledTimes(2);
    });

    it('falls back to its own message when the error carries no body message', async () => {
        const element = build();
        getUpcoming.error({});
        await flush();

        expect(element.shadowRoot.querySelector('.lv-error').textContent).toContain(
            'Unable to load call for offers.'
        );
    });

    it('navigates to the Opportunity list from View All', async () => {
        const element = build();
        const handler = jest.fn();
        element.addEventListener('navigate', handler);
        getUpcoming.emit(DEALS);
        await flush();

        element.shadowRoot.querySelector('.view-all-footer a').click();
        await flush();

        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.attributes.objectApiName).toBe('Opportunity');
    });

    it('is accessible in its populated state', async () => {
        const element = build();
        getUpcoming.emit(DEALS);
        await flush();
        await expect(element).toBeAccessible();
    });

    it('is accessible in its error state', async () => {
        const element = build();
        getUpcoming.error({ message: 'Call for offers could not be loaded.' });
        await flush();
        await expect(element).toBeAccessible();
    });
});
