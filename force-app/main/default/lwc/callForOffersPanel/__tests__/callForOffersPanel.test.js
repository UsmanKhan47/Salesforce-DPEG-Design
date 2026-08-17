/**
 * Jest for c-call-for-offers-panel.
 *
 * ⚠ Every error test passes an EXPLICIT body: `createApexTestWireAdapter.error()` defaults its body
 * to an OBJECT while the LDS adapter defaults to an ARRAY, so a no-arg `.error()` silently measures
 * the library's default string rather than the component's fallback.
 *
 * ── ⚠ 2026-08-17: THREE TESTS WERE REPLACED BY THEIR OWN FALSIFIERS, NOT DELETED ──
 * Sale process, Listing broker and the raw day count are no longer rendered, so the tests that
 * asserted their VALUES could not survive. Each was replaced by a test asserting the field is ABSENT
 * (`saleProcessAndListingBrokerAreNotRendered`, `theMailtoLinkIsGone`, `theRawDayCountIsNotRendered`)
 * — which is what makes a future re-add go red HERE rather than pass silently. The em-dash test went
 * with the two blankable rows it covered; the `daysRemaining: 0` test is discussed in the component
 * header, because the trap it guarded is now structurally unreachable rather than fixed.
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

/**
 * ⚠ `saleProcess`, `listingBrokerName` and `listingBrokerEmail` are STILL IN THIS FIXTURE ON PURPOSE.
 * The server still returns them (`c/callForOffersList` and `CallForOffersAlertBatch` share the DTO),
 * so the fixture must keep them for the absence tests below to mean anything: a payload that omitted
 * them would let a re-added row pass by rendering an em dash.
 */
const CRITICAL = {
    opportunityId: '006000000000001AAA',
    propertyName: 'Magnolia Crossing',
    recordUrl: '/lightning/r/Opportunity/006000000000001AAA/view',
    receivedDate: '2026-07-01',
    dealArrivedDate: '2026-01-15',
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

/** Everything the panel renders, as one trimmed string — used by the absence tests. */
const textOf = (element) => element.shadowRoot.textContent.replace(/\s+/g, ' ').trim();

describe('c-call-for-offers-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders the deadline row: label, urgency pill and the date beneath', async () => {
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        expect(element.shadowRoot.querySelector('.row-name').textContent.trim()).toBe(
            'Offer Deadline'
        );
        expect(element.shadowRoot.querySelector('.cfo-badge').textContent.trim()).toBe(
            'Due in 3 days'
        );
        expect(element.shadowRoot.querySelector('.cfo-date').textContent.trim()).toBe(
            'Aug 17, 2026'
        );
    });

    it('matches the sibling card grammar: body rule, rows, chips, dividers', async () => {
        // `c/dealDocStatus` sits directly above this card and this is its structure. A hero block or
        // a bare card with no `.body` border-top is what read as off-theme before.
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        expect(element.shadowRoot.querySelector('.body')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.card-title').textContent.trim()).toBe(
            'Call for Offers'
        );
        // Three rows here (deadline + received + deal room), each with an icon chip.
        expect(element.shadowRoot.querySelectorAll('.row')).toHaveLength(3);
        expect(element.shadowRoot.querySelectorAll('.row-icon')).toHaveLength(3);
        // A divider BETWEEN rows, never trailing: rows - 1.
        expect(element.shadowRoot.querySelectorAll('.divider')).toHaveLength(2);
    });

    it('never ends on a trailing divider when the optional rows are absent', async () => {
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, receivedDate: null, dealRoomLink: null });
        await flush();

        expect(element.shadowRoot.querySelectorAll('.row')).toHaveLength(1);
        expect(element.shadowRoot.querySelectorAll('.divider')).toHaveLength(0);
    });

    it('renders NO definition list — the four rows are gone, not restyled', async () => {
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        expect(element.shadowRoot.querySelectorAll('dl')).toHaveLength(0);
        expect(element.shadowRoot.querySelectorAll('dt')).toHaveLength(0);
        expect(element.shadowRoot.querySelectorAll('dd')).toHaveLength(0);
    });

    it('does NOT render the sale process or the listing broker name', async () => {
        // The falsifier for re-adding either field to this panel. Both are present in the payload.
        //
        // ⚠ `saleProcess` is overridden to a DISTINCTIVE value here on purpose: the fixture's real
        // value is the literal string "Call for Offers", which is also the card's own title, so
        // asserting THAT string is absent would prove nothing (or fail for the wrong reason).
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, saleProcess: 'Sealed Bid Auction' });
        await flush();

        const text = textOf(element);
        expect(text).not.toContain('Sealed Bid Auction');
        expect(text).not.toContain('Sale process');
        expect(text).not.toContain('Jane Broker');
        expect(text).not.toContain('Listing broker');
    });

    it('does NOT render an "Email listing broker" mailto link', async () => {
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        expect(element.shadowRoot.querySelector('a[href^="mailto:"]')).toBeNull();
        expect(textOf(element)).not.toContain('Email listing broker');
    });

    it('does NOT render the raw day count — the countdown reaches the user only via the badge', async () => {
        // `daysRemaining` is 3 here and the badge says "Due in 3 days". A bare "3" would mean the
        // number is being formatted client-side again, which is what reopens the falsy-zero trap.
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        expect(textOf(element)).not.toContain('Days remaining');
        expect(element.shadowRoot.querySelector('.cfo-badge').textContent).toContain('3 days');
    });

    it('does NOT repeat the detail sentence beside the hero date', async () => {
        // "Offers are due Aug 17, 2026." is the date already in the hero. Rendering both is the
        // redundancy this layout removed.
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        expect(element.shadowRoot.querySelector('.cfo-detail')).toBeNull();
        expect(textOf(element)).not.toContain('Offers are due');
    });

    it('shows the received date when the email was stamped', async () => {
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        expect(element.shadowRoot.querySelector('.cfo-received').textContent.trim()).toBe(
            'Jul 1, 2026'
        );
        expect(textOf(element)).toContain('Call for Offers Received');
    });

    it('OMITS the received line when no call-for-offers email was stamped', async () => {
        // Absent, never blank and never an em dash. This is the COMMON case: the stamp only lands
        // when such an email matches an already-converted winner.
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, receivedDate: null });
        await flush();

        expect(element.shadowRoot.querySelector('.cfo-received')).toBeNull();
        expect(textOf(element)).not.toContain('Received');
        expect(textOf(element)).not.toContain('Jul 1, 2026');
    });

    it('NEVER falls back to dealArrivedDate for the received line', async () => {
        // CallForOffersService header §4: the two answer different questions and coalescing them is
        // the defect that section exists to prevent. `dealArrivedDate` is Jan 15, 2026 here.
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, receivedDate: null });
        await flush();

        const text = textOf(element);
        expect(text).not.toContain('Jan 15, 2026');
        expect(text).not.toContain('Deal arrived');
    });

    it('colour-codes the badge from the SERVER urgency, and every band maps to a theme', async () => {
        // The mapping is the only place the client interprets the band, so every member is walked.
        //
        // ⚠ CRITICAL EXPECTS `amber` AS OF 2026-08-17 (was `red`). See the next test for why that is
        // the assertion that carries the user's actual complaint — this one only proves the map is
        // total, and would stay green if CRITICAL were quietly put back into the red family by way of
        // some third theme.
        const expected = {
            NO_DUE_DATE: 'cfo-badge--muted',
            SCHEDULED: 'cfo-badge--green',
            APPROACHING: 'cfo-badge--amber',
            CRITICAL: 'cfo-badge--amber',
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

    it('🔴 a deadline still AHEAD is never painted in the missed-deadline colour', async () => {
        // THE FALSIFIER FOR THE 2026-08-17 CHANGE, and it is deliberately written as the boundary
        // rather than as a list of theme names. CRITICAL used to be `red`, so "Due in 2 days" wore the
        // same colour as "Overdue by 2 days" — a deal two days OUT reported at a glance as a deal
        // already missed. The rule that replaced it is a partition, not a palette: ahead-of-you bands
        // (APPROACHING, CRITICAL) are warning-coloured; hit-or-passed bands (DUE_TODAY, OVERDUE) are
        // error-coloured.
        //
        // Asserting the ABSENCE of `--red` on the ahead bands is what makes any future re-tune go red
        // HERE: renaming or resplitting the warning themes leaves this test green (correctly — the
        // partition still holds), while moving CRITICAL back across the line fails it whatever the new
        // theme is called.
        const aheadOfYou = ['APPROACHING', 'CRITICAL'];
        for (const urgency of aheadOfYou) {
            const element = build();
            getForOpportunity.emit({ ...CRITICAL, urgency });
            // eslint-disable-next-line no-await-in-loop
            await flush();
            const cls = element.shadowRoot.querySelector('.cfo-badge').className;
            expect(cls).not.toContain('cfo-badge--red');
            document.body.removeChild(element);
        }

        // The other side of the partition, so the assertion above cannot pass because NOTHING is red.
        const outOfTime = ['DUE_TODAY', 'OVERDUE'];
        for (const urgency of outOfTime) {
            const element = build();
            getForOpportunity.emit({ ...CRITICAL, urgency });
            // eslint-disable-next-line no-await-in-loop
            await flush();
            expect(element.shadowRoot.querySelector('.cfo-badge').className).toContain(
                'cfo-badge--red'
            );
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
        // The `detail` sentence IS still rendered here — it is the only text this branch has.
        const element = build();
        getForOpportunity.emit(NO_DEADLINE);
        await flush();

        expect(element.shadowRoot.querySelector('.cfo-empty').textContent).toContain(
            'no call-for-offers due date'
        );
        expect(element.shadowRoot.querySelector('.cfo-badge')).toBeNull();
        expect(element.shadowRoot.querySelector('.cfo-date')).toBeNull();
    });

    it('hides the deal-room link when the deal carries none', async () => {
        const element = build();
        getForOpportunity.emit({ ...CRITICAL, dealRoomLink: null });
        await flush();
        expect(element.shadowRoot.querySelector('.cfo-dealroom')).toBeNull();
    });

    it('renders the deal room as a row-styled anchor with a safe external target', async () => {
        const element = build();
        getForOpportunity.emit(CRITICAL);
        await flush();

        const links = [...element.shadowRoot.querySelectorAll('a')];
        expect(links).toHaveLength(1);
        expect(links[0].textContent.trim()).toBe('Deal Room');
        expect(links[0].getAttribute('href')).toBe('https://example.invalid/dealroom');
        expect(links[0].getAttribute('target')).toBe('_blank');
        expect(links[0].getAttribute('rel')).toBe('noopener noreferrer');
        // It wears the SIBLING CARD's record-link styling, not a button's. A `lightning-button` here
        // is what made the previous layout read as foreign, so its absence is asserted.
        expect(links[0].className).toContain('row-name');
        expect(links[0].className).not.toContain('slds-button');
        expect(element.shadowRoot.querySelector('lightning-button')).toBeNull();
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
        expect(element.shadowRoot.querySelector('.cfo-date')).toBeNull();
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
