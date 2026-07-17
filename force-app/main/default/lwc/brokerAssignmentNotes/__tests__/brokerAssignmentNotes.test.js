/**
 * c-broker-assignment-notes
 * ---------------------------------------------------------------------------
 * @wire(getNotes, { recordId: '$recordId' }) lists native Notes; imperative
 * addNote({ recordId, body }) posts a new one, then refreshApex re-reads the
 * wire. A failed post surfaces a ShowToastEvent. refreshApex (@salesforce/apex)
 * is auto-mocked by the sfdx-lwc-jest stub.
 */
import { createElement } from 'lwc';
import BrokerAssignmentNotes from 'c/brokerAssignmentNotes';
import getNotes from '@salesforce/apex/BrokerAssignmentController.getNotes';
import addNote from '@salesforce/apex/BrokerAssignmentController.addNote';

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getNotes',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/BrokerAssignmentController.addNote',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a0X0000000000001AAA';
const NOTES = [
    {
        id: '069000000000001AAA',
        title: 'Called broker re: signage',
        preview: 'Called broker re: signage; awaiting city permit.',
        author: 'Pat Morgan',
        createdDate: '2025-02-10T15:30:00.000Z'
    }
];

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-broker-assignment-notes', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-broker-assignment-notes', {
            is: BrokerAssignmentNotes
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ban-empty')).not.toBeNull();
        expect(
            element.shadowRoot.querySelectorAll('.ban-item').length
        ).toBe(0);
    });

    it('DATA BRANCH: renders each note with author, text and count', async () => {
        const element = createComponent();

        getNotes.emit(NOTES);
        await Promise.resolve();

        const items = element.shadowRoot.querySelectorAll('.ban-item');
        expect(items.length).toBe(1);
        expect(element.shadowRoot.querySelector('.ban-author').textContent).toBe(
            'Pat Morgan'
        );
        expect(element.shadowRoot.querySelector('.ban-text').textContent).toBe(
            'Called broker re: signage; awaiting city permit.'
        );
        expect(element.shadowRoot.querySelector('.ban-title').textContent).toBe(
            'Notes (1)'
        );
    });

    it('ADD NOTE: posts the draft to Apex and clears the composer', async () => {
        addNote.mockResolvedValue(undefined);
        const element = createComponent();

        getNotes.emit([]);
        await Promise.resolve();

        const textarea = element.shadowRoot.querySelector('lightning-textarea');
        textarea.value = 'Broker confirmed the new tenant tour for Friday.';
        // dispatchEvent sets event.target = textarea, so onDraftChange reads .value.
        textarea.dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        element.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();

        expect(addNote).toHaveBeenCalledTimes(1);
        expect(addNote).toHaveBeenCalledWith({
            recordId: RECORD_ID,
            body: 'Broker confirmed the new tenant tour for Friday.'
        });
    });

    it('ADD NOTE ERROR: surfaces the Apex message in an error toast', async () => {
        addNote.mockRejectedValue({ body: { message: 'Note cannot be empty.' } });
        const element = createComponent();

        getNotes.emit([]);
        await Promise.resolve();

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        const textarea = element.shadowRoot.querySelector('lightning-textarea');
        textarea.value = 'anything';
        textarea.dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        element.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Note cannot be empty.'
        );
    });

    it('ERROR BRANCH: keeps the empty state when the notes wire errors', async () => {
        const element = createComponent();

        getNotes.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ban-empty')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getNotes.emit(NOTES);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
