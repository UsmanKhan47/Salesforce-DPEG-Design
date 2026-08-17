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

// ⚠ `receivedDate` / `dealArrivedDate` ARE STILL ON THE SERVER DTO AND ARE DELIBERATELY KEPT HERE,
// even though the "Received" column that rendered them was removed on 2026-08-17. The fixture's job
// is to mirror what `CallForOffersController.getUpcoming` actually returns; trimming it to only the
// fields the table happens to paint today would hide a future contract change. See
// `CallForOffersService` header §4 — the two dates remain separate facts server-side.
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
    });

    it('shows an em dash rather than a broken date when a date is missing', async () => {
        const element = build();
        getUpcoming.emit([{ ...DEALS[0], dueDate: null }]);
        await flush();

        const rows = element.shadowRoot.querySelector('c-list-datatable').data;
        expect(rows[0].dueLabel).toBe('—');
    });

    it('renders exactly three columns and no "Received" column', async () => {
        // 🔴 THE PIN FOR THE 2026-08-17 REMOVAL. "Received" was dropped at the user's request; the
        // date it rendered is not shown anywhere in this table any more. This asserts the whole
        // column SET rather than just the absence, so a silent re-add fails here — and so does a
        // reordering that quietly reintroduces the cell under a different heading.
        //
        // ⚠ The server still sends `receivedDate` and `dealArrivedDate` as separate facts and its
        // own tests still enforce that split (`CallForOffersService` header §4). This assertion is
        // about what the TABLE paints, not about the DTO, and must not be read as licence to
        // collapse the two fields in Apex.
        const element = build();
        getUpcoming.emit(DEALS);
        await flush();

        const labels = element.shadowRoot
            .querySelector('c-list-datatable')
            .columns.map((c) => c.label);
        expect(labels).toEqual(['Property', 'Due Date', 'Urgency']);
        expect(labels).not.toContain('Received');
        // The two 2026-08-17 renames were LABEL-ONLY. Pinning the old headings as ABSENT is what
        // makes the rename visible here rather than silently reversible.
        expect(labels).not.toContain('Offers Due');
        expect(labels).not.toContain('Days Remaining');
    });

    it('the renamed "Urgency" column still reads the SERVER label and pill styles, unchanged', async () => {
        // 🔴 THE HALF OF THE RENAME THAT NEEDS PINNING. 'Days Remaining' -> 'Urgency' is a heading
        // change, and the risk is that a future reader takes the new heading as a cue to compute a
        // band client-side. This asserts the cell is still wired to `countdown` (the server's own
        // `CallForOffersService` label) as a `pill` with both style attributes — so re-deriving the
        // ladder in JS, or swapping the column to `type: 'text'`, reds here.
        const element = build();
        getUpcoming.emit(DEALS);
        await flush();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        const urgency = table.columns.find((c) => c.label === 'Urgency');
        expect(urgency.fieldName).toBe('countdown');
        expect(urgency.type).toBe('pill');
        expect(urgency.typeAttributes.wrapStyle).toEqual({ fieldName: 'pillWrap' });
        expect(urgency.typeAttributes.dotStyle).toEqual({ fieldName: 'pillDot' });
        // The value is the server's string verbatim, never a locally counted number of days.
        expect(table.data[0].countdown).toBe(DEALS[0].label);
    });

    it('🔴 a deadline still AHEAD never wears the same pill colour as one already missed', async () => {
        // THE FALSIFIER FOR THE 2026-08-17 RECOLOUR, AND THE COVERAGE GAP THAT LET THE DEFECT SHIP.
        // Until now this suite asserted the pill's WIRING (fieldName / type / typeAttributes) and never
        // its VALUES, so `CRITICAL` and `OVERDUE` shared the background `#fdeaea` for as long as the
        // component existed and every test here passed. "Due in 2 days" and "Overdue by 2 days" sat
        // adjacent in this table in the same pale pink — opposite facts, one appearance.
        //
        // ⚠ IT ASSERTS THE PARTITION, NOT THE HEXES. The rule is that ahead-of-you bands (APPROACHING,
        // CRITICAL) must not share a background with hit-or-passed ones (DUE_TODAY, OVERDUE); a future
        // retune of any individual colour stays green, while collapsing the two families again reds
        // here whatever the new values are. Pinning literal hexes instead would fail on every harmless
        // tweak and would still not say what the colours are FOR.
        const paint = async (urgency) => {
            const element = build();
            getUpcoming.emit([{ ...DEALS[0], urgency }]);
            await flush();
            const [row] = element.shadowRoot.querySelector('c-list-datatable').data;
            expect(row.pillWrap).toContain('background:');
            const background = row.pillWrap.split('background:')[1];
            document.body.removeChild(element);
            return background;
        };

        const [approaching, critical, dueToday, overdue] = [
            await paint('APPROACHING'),
            await paint('CRITICAL'),
            await paint('DUE_TODAY'),
            await paint('OVERDUE')
        ];

        // Across the line: no ahead-of-you band may look like a missed one. `CRITICAL` vs `OVERDUE` is
        // the exact pair the user reported.
        expect(critical).not.toBe(overdue);
        expect(critical).not.toBe(dueToday);
        expect(approaching).not.toBe(overdue);
        expect(approaching).not.toBe(dueToday);

        // Within the line: the two ahead-of-you bands are distinguishable from each other too, so the
        // 1-3 day window still reads as more pressed than the 4-7 day one...
        expect(critical).not.toBe(approaching);
        // ...while the two out-of-time bands legitimately SHARE a background (they differ only in dot
        // saturation), which is what stops the assertions above passing because nothing matches
        // anything.
        expect(dueToday).toBe(overdue);
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
