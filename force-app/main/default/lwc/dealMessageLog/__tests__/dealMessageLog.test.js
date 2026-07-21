/**
 * dealMessageLog — @wire read (getMessages) + imperative post (addMessage).
 * ------------------------------------------------------------------------
 * Combines WIRE-MOCK TEMPLATE 1 (@wire adapter, .emit/.error) for the append-only
 * timeline read with TEMPLATE 2 (imperative jest.fn, mockResolvedValue /
 * mockRejectedValue) for the composer post. `refreshApex` (from '@salesforce/apex')
 * is pre-stubbed by the sfdx-lwc-jest lightning stubs — import it and assert it
 * was called on the success path.
 *
 * The DTO shape is derived only from this component's `entries` getter
 * ({ id, details, revision, enteredBy, entryDate, method, direction }) and the
 * addMessage argument object. save() does its own required-field check (it does
 * NOT call reportValidity), so no reportValidity stub is needed. The composer
 * textarea drives upDetails via its `change` event.
 */
import { createElement } from 'lwc';
import DealMessageLog from 'c/dealMessageLog';
import { refreshApex } from '@salesforce/apex';
import getMessages from '@salesforce/apex/DealMessageController.getMessages';
import addMessage from '@salesforce/apex/DealMessageController.addMessage';

jest.mock(
    '@salesforce/apex/DealMessageController.getMessages',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/DealMessageController.addMessage',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

// The default sfdx-lwc-jest '@salesforce/apex' stub exports refreshApex as a
// plain pass-through function (not a jest.fn), so it can't be asserted on. Mock
// it as a jest.fn that resolves, so save()'s .then chain still settles.
jest.mock(
    '@salesforce/apex',
    () => ({ refreshApex: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const RECORD_ID = 'a0L5g000000LoiAEAS';

const MESSAGES = [
    {
        id: 'a0M000000000001',
        details: 'Called broker re: LOI terms; they will counter by Friday.',
        revision: null,
        enteredBy: 'A. Khan',
        entryDate: '2025-05-01T14:30:00.000Z',
        method: 'Call',
        direction: 'Sent'
    },
    {
        id: 'a0M000000000002',
        details: 'Received counter at $5.2M.',
        revision: null,
        enteredBy: 'B. Lee',
        entryDate: '2025-04-28T10:00:00.000Z',
        method: 'Email',
        direction: 'Received'
    }
];

describe('c-deal-message-log', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-deal-message-log', {
            is: DealMessageLog
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    // save() chains addMessage().then().then().catch() — each link plus the LWC
    // re-render needs its own microtask tick, so flush several.
    async function flushPromises() {
        for (let i = 0; i < 10; i++) {
            // eslint-disable-next-line no-await-in-loop
            await Promise.resolve();
        }
    }

    function button(element, label) {
        return [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === label);
    }

    it('EMPTY: shows the empty-state message before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.dml-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelectorAll('.dml-entry').length).toBe(0);
    });

    it('DATA BRANCH: renders newest-first entries with a Latest badge on the first', async () => {
        const element = createComponent();

        getMessages.emit(MESSAGES);
        await Promise.resolve();

        const entries = element.shadowRoot.querySelectorAll('.dml-entry');
        expect(entries.length).toBe(2);

        // Only the first (newest) entry carries the "Latest" badge.
        const latest = element.shadowRoot.querySelectorAll('.dml-latest');
        expect(latest.length).toBe(1);

        const details = [
            ...element.shadowRoot.querySelectorAll('.dml-details')
        ].map((el) => el.textContent);
        expect(details[0]).toBe(
            'Called broker re: LOI terms; they will counter by Friday.'
        );
    });

    it('SUCCESS: posts a message, refreshes the wire and toasts success', async () => {
        addMessage.mockResolvedValue(undefined);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getMessages.emit(MESSAGES);
        await Promise.resolve();

        // Open the composer, then type into the textarea.
        button(element, 'Log Message').click();
        await Promise.resolve();

        const textarea = element.shadowRoot.querySelector('.dml-textarea');
        textarea.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'Followed up by email.' } })
        );

        button(element, 'Save to log').click();
        await flushPromises();
        await flushPromises();

        expect(addMessage).toHaveBeenCalledTimes(1);
        expect(addMessage).toHaveBeenCalledWith({
            recordId: RECORD_ID,
            method: 'Note',
            direction: 'Internal',
            details: 'Followed up by email.',
            revision: ''
        });
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
    });

    it('VALIDATION: blocks the post and shows an inline error when details are empty', async () => {
        const element = createComponent();

        getMessages.emit(MESSAGES);
        await Promise.resolve();

        button(element, 'Log Message').click();
        await Promise.resolve();

        // Save without typing anything.
        button(element, 'Save to log').click();
        await Promise.resolve();

        expect(addMessage).not.toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('.dml-error').textContent).toBe(
            'Enter what was communicated before saving.'
        );
    });

    it('ERROR: surfaces the Apex error message when the post is rejected', async () => {
        addMessage.mockRejectedValue({ body: { message: 'Record is locked.' } });

        const element = createComponent();

        getMessages.emit(MESSAGES);
        await Promise.resolve();

        button(element, 'Log Message').click();
        await Promise.resolve();

        element.shadowRoot
            .querySelector('.dml-textarea')
            .dispatchEvent(
                new CustomEvent('change', { detail: { value: 'Attempted post.' } })
            );

        button(element, 'Save to log').click();
        await flushPromises();
        await flushPromises();

        expect(element.shadowRoot.querySelector('.dml-error').textContent).toBe(
            'Record is locked.'
        );
    });

    it('WIRE ERROR: surfaces an inline load error (not the empty state) when getMessages errors', async () => {
        const element = createComponent();

        getMessages.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.dml-empty')).toBeNull();
        const err = element.shadowRoot.querySelector('.dml-load-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    it('respects the internalOnly / hideMethod @api flags (badges hidden)', async () => {
        const element = createComponent({
            recordId: RECORD_ID,
            internalOnly: true,
            hideMethod: true
        });

        getMessages.emit(MESSAGES);
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.dml-method').length).toBe(
            0
        );
        expect(element.shadowRoot.querySelectorAll('.dml-dir').length).toBe(0);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getMessages.emit(MESSAGES);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
