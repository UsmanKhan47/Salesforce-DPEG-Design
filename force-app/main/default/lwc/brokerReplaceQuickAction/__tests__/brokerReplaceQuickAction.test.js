/**
 * c-broker-replace-quick-action — HYBRID suite.
 * A screen-action quick action on Broker_Assignment__c that reads the live record
 * via LDS, offers a broker-swap form (gated to Active listings), and commits the
 * swap through an imperative Apex call.
 *
 * Combines THREE mocking techniques:
 *   - LDS getRecord   -> sfdx-lwc-jest uiRecordApi stub, driven with .emit/.error
 *     (Status__c + Broker_Name__c on Broker_Assignment__c).
 *   - @wire Apex       -> getBrokerOptions via createApexTestWireAdapter.emit.
 *   - imperative Apex  -> replaceBroker via jest.fn + mockResolvedValue/Rejected.
 *
 * lightning/actions has no sfdx-lwc-jest stub, so CloseActionScreenEvent is
 * provided by a virtual mock (a CustomEvent subclass) — the component dispatches
 * it to close the panel, and the suite listens for that native event.
 */
import { createElement } from 'lwc';
import BrokerReplaceQuickAction from 'c/brokerReplaceQuickAction';
import { getRecord, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

jest.mock(
    'lightning/actions',
    () => ({
        CloseActionScreenEvent: class extends CustomEvent {
            constructor() {
                super('closeactionscreen');
            }
        }
    }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getBrokerOptions',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.replaceBroker',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a075g000000BAsgAAG';

const BROKER_OPTIONS = [
    { id: 'b1', label: 'Ava Broker — CBRE' },
    { id: 'b2', label: 'John Roe — JLL' }
];

function record(status, brokerName = 'Jane Doe') {
    return {
        apiName: 'Broker_Assignment__c',
        id: RECORD_ID,
        fields: {
            Status__c: { value: status },
            Broker_Name__c: { value: brokerName }
        }
    };
}

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-broker-replace-quick-action', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-broker-replace-quick-action', {
            is: BrokerReplaceQuickAction
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the loading spinner until the record wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.qa-loading')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('lightning-combobox')
        ).toBeNull();
    });

    it('ACTIVE BRANCH: renders the swap form with the outgoing broker in the note', async () => {
        const element = createComponent();

        getRecord.emit(record('Active'));
        getBrokerOptions.emit(BROKER_OPTIONS);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.qa-note').textContent).toContain(
            'Jane Doe'
        );

        // Incoming-broker combobox is the first of the two comboboxes.
        const incoming = element.shadowRoot.querySelectorAll(
            'lightning-combobox'
        )[0];
        expect(incoming.options).toEqual([
            { label: 'Ava Broker — CBRE', value: 'b1' },
            { label: 'John Roe — JLL', value: 'b2' }
        ]);

        // Confirm is disabled until an incoming broker is chosen.
        const confirmBtn = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === 'Confirm replacement');
        expect(confirmBtn.disabled).toBe(true);
    });

    it('INACTIVE BRANCH: explains that only Active listings can be replaced', async () => {
        const element = createComponent();

        getRecord.emit(record('Fully Leased'));
        await Promise.resolve();

        // No replace form for a non-active listing.
        expect(
            element.shadowRoot.querySelector('lightning-textarea')
        ).toBeNull();
        const body = element.shadowRoot.querySelector('.qa-body').textContent;
        expect(body).toContain('Only');
        expect(body).toContain('Fully Leased');
    });

    it('CONFIRM SUCCESS: calls replaceBroker, refreshes LDS, toasts, and closes', async () => {
        replaceBroker.mockResolvedValue();

        const element = createComponent();
        const toastHandler = jest.fn();
        const closeHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('closeactionscreen', closeHandler);

        getRecord.emit(record('Active'));
        getBrokerOptions.emit(BROKER_OPTIONS);
        await Promise.resolve();

        // Fill the form: incoming broker + reason via detail.value; date + notes
        // via target.value (matching each handler in the component).
        const comboboxes = element.shadowRoot.querySelectorAll(
            'lightning-combobox'
        );
        comboboxes[0].dispatchEvent(
            new CustomEvent('change', { detail: { value: 'b2' } })
        );
        comboboxes[1].dispatchEvent(
            new CustomEvent('change', { detail: { value: 'Performance Issue' } })
        );
        const dateInput = element.shadowRoot.querySelector('lightning-input');
        dateInput.value = '2026-08-01';
        dateInput.dispatchEvent(new CustomEvent('change'));
        const notes = element.shadowRoot.querySelector('lightning-textarea');
        notes.value = 'Broker handover complete.';
        notes.dispatchEvent(new CustomEvent('change'));

        const confirmBtn = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === 'Confirm replacement');
        confirmBtn.click();
        await flushPromises();

        expect(replaceBroker).toHaveBeenCalledTimes(1);
        expect(replaceBroker).toHaveBeenCalledWith({
            assignmentId: RECORD_ID,
            newBrokerId: 'b2',
            effectiveDate: '2026-08-01',
            reason: 'Performance Issue',
            notes: 'Broker handover complete.'
        });

        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(closeHandler).toHaveBeenCalledTimes(1);
    });

    it('CONFIRM ERROR: surfaces the Apex error and does NOT close', async () => {
        replaceBroker.mockRejectedValue({
            body: { message: 'Incoming broker is inactive.' }
        });

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('closeactionscreen', closeHandler);

        getRecord.emit(record('Active'));
        getBrokerOptions.emit(BROKER_OPTIONS);
        await Promise.resolve();

        element.shadowRoot
            .querySelectorAll('lightning-combobox')[0]
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'b1' } }));

        const confirmBtn = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === 'Confirm replacement');
        confirmBtn.click();
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.slds-text-color_error').textContent
        ).toBe('Incoming broker is inactive.');
        expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();
        expect(closeHandler).not.toHaveBeenCalled();
    });

    it('WIRE ERROR: surfaces a load error instead of a perpetual spinner', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.qa-loading')).toBeNull();
        const err = element.shadowRoot.querySelector('.qa-load-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecord.emit(record('Active'));
        getBrokerOptions.emit(BROKER_OPTIONS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
