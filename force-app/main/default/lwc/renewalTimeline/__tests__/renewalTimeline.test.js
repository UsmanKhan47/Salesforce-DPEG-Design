/**
 * c-renewal-timeline — MIXED: @wire read + IMPERATIVE write.
 *
 * Reads:  @wire(getTimeline, { renewalId: '$recordId' }) -> registered as an
 *         Apex test wire adapter; .emit()/.error() drive the branches.
 * Writes: addUpdate({ renewalId, method, details }) -> mocked as a plain
 *         jest.fn and driven with mockResolvedValue / mockRejectedValue, exactly
 *         like the c-submit-for-approval imperative template.
 *
 * The Log Follow-Up composer is exercised through the DOM the way a user drives
 * it: click the header button -> combobox/textarea change events -> Save. Both
 * inputs are mandatory, so the empty-Save path asserts client-side validation
 * fires BEFORE any Apex call. On success the component calls
 * notifyRecordUpdateAvailable + refreshApex (both stubbed by sfdx-lwc-jest) and
 * toasts — captured via a lightning__showtoast listener.
 *
 * entryDate values are fixed past ISO strings so rendering stays stable.
 */
import { createElement } from 'lwc';
import RenewalTimeline from 'c/renewalTimeline';
import getTimeline from '@salesforce/apex/LeaseRenewalController.getTimeline';
import addUpdate from '@salesforce/apex/LeaseRenewalController.addUpdate';

jest.mock(
    '@salesforce/apex/LeaseRenewalController.getTimeline',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/LeaseRenewalController.addUpdate',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a2R5g000000RnwAEAS';

const TIMELINE = {
    canLog: true,
    nonResponsive: false,
    daysSinceContact: 4,
    entries: [
        {
            id: 'a2S5g000000AAaEAK',
            details: 'Tenant confirmed interest, requested revised terms.',
            enteredBy: 'M. Alvarez',
            method: 'Call',
            entryDate: '2026-03-14T09:30:00.000Z'
        },
        {
            id: 'a2S5g000000AAbEAK',
            details: 'Sent renewal notice with proposed rate.',
            enteredBy: 'M. Alvarez',
            method: 'Email',
            entryDate: '2026-03-10T15:05:00.000Z'
        }
    ]
};

const TIMELINE_NONRESP = {
    canLog: true,
    nonResponsive: true,
    daysSinceContact: 21,
    entries: []
};

describe('c-renewal-timeline', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-renewal-timeline', {
            is: RenewalTimeline
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    function button(element, label) {
        return [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === label);
    }

    async function flush() {
        for (let i = 0; i < 5; i++) {
            // eslint-disable-next-line no-await-in-loop
            await Promise.resolve();
        }
    }

    it('DATA BRANCH: renders entries newest-first with the Log Follow-Up button', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const entries = element.shadowRoot.querySelectorAll('.rt-entry');
        expect(entries.length).toBe(2);

        expect(element.shadowRoot.querySelector('.rt-sub').textContent).toBe(
            '2 entries · append-only, never overwritten'
        );

        const details = [
            ...element.shadowRoot.querySelectorAll('.rt-details')
        ].map((el) => el.textContent);
        expect(details[0]).toBe(
            'Tenant confirmed interest, requested revised terms.'
        );

        expect(button(element, 'Log Follow-Up')).toBeTruthy();
        // Not opened yet -> no composer.
        expect(element.shadowRoot.querySelector('.rt-composer')).toBeNull();
    });

    it('DATA BRANCH: surfaces the non-responsive header pill', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE_NONRESP);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.rt-nonresp').textContent).toBe(
            'Non-responsive · 21d silent'
        );
    });

    it('VALIDATION: empty Save shows an error and never calls Apex', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        button(element, 'Log Follow-Up').dispatchEvent(
            new CustomEvent('click')
        );
        await Promise.resolve();

        // Composer open, save with nothing entered.
        button(element, 'Save to timeline').dispatchEvent(
            new CustomEvent('click')
        );
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.rt-error').textContent).toBe(
            'Choose how the tenant was contacted.'
        );
        expect(addUpdate).not.toHaveBeenCalled();
    });

    it('SUCCESS BRANCH: logs a follow-up through Apex and toasts success', async () => {
        addUpdate.mockResolvedValue();

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        button(element, 'Log Follow-Up').dispatchEvent(
            new CustomEvent('click')
        );
        await Promise.resolve();

        // Drive the mandatory inputs the way lightning-combobox/textarea do.
        element.shadowRoot
            .querySelector('lightning-combobox')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Call' } }));
        element.shadowRoot
            .querySelector('lightning-textarea')
            .dispatchEvent(
                new CustomEvent('change', {
                    detail: { value: 'Left a voicemail; tenant will call back.' }
                })
            );

        button(element, 'Save to timeline').dispatchEvent(
            new CustomEvent('click')
        );
        await flush();

        expect(addUpdate).toHaveBeenCalledTimes(1);
        expect(addUpdate).toHaveBeenCalledWith({
            renewalId: RECORD_ID,
            method: 'Call',
            details: 'Left a voicemail; tenant will call back.'
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');

        // Composer closes on success.
        expect(element.shadowRoot.querySelector('.rt-composer')).toBeNull();
    });

    it('ERROR BRANCH: surfaces the Apex error message in the composer', async () => {
        addUpdate.mockRejectedValue({
            body: { message: 'Renewal is already closed.' }
        });

        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        button(element, 'Log Follow-Up').dispatchEvent(
            new CustomEvent('click')
        );
        await Promise.resolve();

        element.shadowRoot
            .querySelector('lightning-combobox')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Email' } }));
        element.shadowRoot
            .querySelector('lightning-textarea')
            .dispatchEvent(
                new CustomEvent('change', { detail: { value: 'Sent follow-up email.' } })
            );

        button(element, 'Save to timeline').dispatchEvent(
            new CustomEvent('click')
        );
        await flush();

        expect(addUpdate).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('.rt-error').textContent).toBe(
            'Renewal is already closed.'
        );
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
