/**
 * c-broker-assignment-actions
 * ---------------------------------------------------------------------------
 * Mixed data access:
 *   - @wire(getDetail, { assignmentId: '$recordId' })  -> parameterised Apex wire
 *   - @wire(getBrokerOptions)                           -> no-param Apex wire
 *   - imperative logCheckIn({ assignmentId })           -> "Log Check-in" button
 *   - imperative replaceBroker({ assignmentId, ... })   -> "Replace Broker" modal
 *
 * Follows the P8 templates: wires registered with createApexTestWireAdapter and
 * driven via .emit()/.error(); imperatives are jest.fn() resolving/rejecting.
 * refreshApex (@salesforce/apex) and notifyRecordUpdateAvailable
 * (lightning/uiRecordApi) are auto-mocked by the sfdx-lwc-jest stubs.
 */
import { createElement } from 'lwc';
import BrokerAssignmentActions from 'c/brokerAssignmentActions';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import logCheckIn from '@salesforce/apex/BrokerAssignmentController.logCheckIn';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getDetail',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getBrokerOptions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/BrokerAssignmentController.logCheckIn',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/BrokerAssignmentController.replaceBroker',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a0X0000000000001AAA';
const BROKER_ID = '0035g00000AbCdEAAV';

const DETAIL_ACTIVE = {
    id: RECORD_ID,
    propertyName: 'Gateway Plaza',
    brokerName: 'Dana Reyes',
    status: 'Active'
};
const DETAIL_LEASED = {
    id: RECORD_ID,
    propertyName: 'Gateway Plaza',
    brokerName: 'Dana Reyes',
    status: 'Fully Leased'
};
const BROKER_OPTIONS = [
    { id: BROKER_ID, label: 'Sam Okafor · CBRE' },
    { id: '0035g00000AbCdFAAV', label: 'Jo Lin · JLL' }
];

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-broker-assignment-actions', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-broker-assignment-actions', {
            is: BrokerAssignmentActions
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders nothing before the detail wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ba-actioncard')).toBeNull();
    });

    it('DATA BRANCH: shows the action toolbar for an Active listing', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL_ACTIVE);
        await Promise.resolve();

        const card = element.shadowRoot.querySelector('.ba-actioncard');
        expect(card).not.toBeNull();
        const buttons = element.shadowRoot.querySelectorAll('.ba-toolbar .ba-btn');
        expect(buttons.length).toBe(2);
    });

    it('DATA BRANCH: hides the toolbar when the listing is not Active', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL_LEASED);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ba-actioncard')).toBeNull();
    });

    it('LOG CHECK-IN: calls Apex with the recordId and refreshes the record', async () => {
        logCheckIn.mockResolvedValue(undefined);
        const element = createComponent();

        getDetail.emit(DETAIL_ACTIVE);
        await Promise.resolve();

        const logBtn = element.shadowRoot.querySelectorAll('.ba-toolbar .ba-btn')[0];
        logBtn.click();
        await flushPromises();

        expect(logCheckIn).toHaveBeenCalledTimes(1);
        expect(logCheckIn).toHaveBeenCalledWith({ assignmentId: RECORD_ID });
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('REPLACE: opens the modal and lists broker options from the wire', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL_ACTIVE);
        getBrokerOptions.emit(BROKER_OPTIONS);
        await Promise.resolve();

        element.shadowRoot.querySelectorAll('.ba-toolbar .ba-btn')[1].click();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ba-overlay')).not.toBeNull();
        const combobox = element.shadowRoot.querySelector('lightning-combobox');
        expect(combobox.options.length).toBe(2);
        expect(combobox.options[0].value).toBe(BROKER_ID);
    });

    it('REPLACE: confirm calls Apex with the selected broker and effective date', async () => {
        replaceBroker.mockResolvedValue(RECORD_ID);
        const element = createComponent();

        getDetail.emit(DETAIL_ACTIVE);
        getBrokerOptions.emit(BROKER_OPTIONS);
        await Promise.resolve();

        element.shadowRoot.querySelectorAll('.ba-toolbar .ba-btn')[1].click();
        await Promise.resolve();

        const combobox = element.shadowRoot.querySelector('lightning-combobox');
        combobox.dispatchEvent(
            new CustomEvent('change', { detail: { value: BROKER_ID } })
        );
        await Promise.resolve();

        element.shadowRoot.querySelector('.ba-btn--primary').click();
        await flushPromises();

        expect(replaceBroker).toHaveBeenCalledTimes(1);
        expect(replaceBroker).toHaveBeenCalledWith({
            assignmentId: RECORD_ID,
            newBrokerId: BROKER_ID,
            effectiveDate: null
        });
        // Modal closes on success.
        expect(element.shadowRoot.querySelector('.ba-overlay')).toBeNull();
    });

    it('ERROR BRANCH: stays empty when the detail wire errors', async () => {
        const element = createComponent();

        getDetail.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ba-actioncard')).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL_ACTIVE);
        getBrokerOptions.emit(BROKER_OPTIONS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
