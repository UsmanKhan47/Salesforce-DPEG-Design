/**
 * c-broker-assignment-detail
 * ---------------------------------------------------------------------------
 * Rich record-page component. Same data sources as c-broker-assignment-actions
 *   - @wire(getDetail, { assignmentId: '$recordId' })
 *   - @wire(getBrokerOptions)
 *   - imperative logCheckIn / replaceBroker
 * plus tab state, a status/flag banner derived from daysIdle, and a history tab.
 *
 * @api warnDays / overdueDays default to 14 / 21; the fixture uses daysIdle=25 so
 * the deterministic "Overdue" flag path renders regardless of run date.
 */
import { createElement } from 'lwc';
import BrokerAssignmentDetail from 'c/brokerAssignmentDetail';
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

const DETAIL = {
    id: RECORD_ID,
    propertyName: 'Gateway Plaza',
    propertyType: 'Retail',
    propertyAddr: '400 Market St, Houston TX',
    grossSqFt: 42000,
    vacantArea: 8000,
    leasedArea: 34000,
    brokerName: 'Dana Reyes',
    brokerFirm: 'Colliers International',
    brokerEmail: 'dana@colliers.com',
    brokerPhone: '(713) 555-0142',
    status: 'Active',
    startDate: '2025-01-15',
    endDate: null,
    lastCheckIn: '2025-02-01',
    daysIdle: 25, // > overdueDays (21) -> Overdue flag
    reason: null,
    history: [
        {
            id: RECORD_ID,
            brokerName: 'Dana Reyes',
            brokerFirm: 'Colliers International',
            status: 'Active',
            startDate: '2025-01-15',
            endDate: null,
            reason: null,
            current: true
        },
        {
            id: 'a0X0000000000002AAA',
            brokerName: 'Sam Okafor',
            brokerFirm: 'CBRE',
            status: 'Replaced',
            startDate: '2024-06-01',
            endDate: '2025-01-14',
            reason: 'Performance Issue',
            current: false
        }
    ]
};
const BROKER_OPTIONS = [{ id: BROKER_ID, label: 'Sam Okafor · CBRE' }];

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-broker-assignment-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-broker-assignment-detail', {
            is: BrokerAssignmentDetail
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders nothing before the detail wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ba-tabcard')).toBeNull();
    });

    it('DATA BRANCH: renders the property, broker and status on the Details tab', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        const links = element.shadowRoot.querySelectorAll('.ba-link');
        // Property Asset link + Broker link.
        expect(links[0].textContent).toBe('Gateway Plaza');
        expect(links[1].textContent).toBe('Dana Reyes');

        const values = [...element.shadowRoot.querySelectorAll('.ba-fval')].map(
            (el) => el.textContent
        );
        expect(values).toContain('Retail');
        expect(values).toContain('Colliers International');
        expect(values).toContain('42,000 sq ft');
    });

    it('DATA BRANCH: shows the Overdue flag banner when daysIdle exceeds overdueDays', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        // The flag banner text is deterministic for daysIdle=25 (> overdueDays 21).
        const bannerText = [...element.shadowRoot.querySelectorAll('span')]
            .map((el) => el.textContent)
            .find((t) => t.startsWith('Check-in overdue'));
        expect(bannerText).toBe('Check-in overdue — 25 days since last contact.');
    });

    it('TABS: switching to History renders one entry per history row', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        const tabs = element.shadowRoot.querySelectorAll('.ba-tabstrip .ba-tab');
        // [0]=Details [1]=History [2]=Notes
        tabs[1].click();
        await Promise.resolve();

        const names = element.shadowRoot.querySelectorAll('.ba-histbody .ba-histname');
        expect(names.length).toBe(2);
        expect(names[0].textContent).toBe('Dana Reyes');
    });

    it('LOG CHECK-IN: calls Apex and notifies the record', async () => {
        logCheckIn.mockResolvedValue(undefined);
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        element.shadowRoot.querySelectorAll('.ba-toolbar .ba-btn')[0].click();
        await flushPromises();

        expect(logCheckIn).toHaveBeenCalledWith({ assignmentId: RECORD_ID });
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('REPLACE: confirm passes broker, reason and effective date to Apex', async () => {
        replaceBroker.mockResolvedValue(RECORD_ID);
        const element = createComponent();

        getDetail.emit(DETAIL);
        getBrokerOptions.emit(BROKER_OPTIONS);
        await Promise.resolve();

        element.shadowRoot.querySelectorAll('.ba-toolbar .ba-btn')[1].click();
        await Promise.resolve();

        const comboboxes = element.shadowRoot.querySelectorAll('lightning-combobox');
        // [0]=Incoming broker  [1]=Reason previous broker ended
        comboboxes[0].dispatchEvent(
            new CustomEvent('change', { detail: { value: BROKER_ID } })
        );
        await Promise.resolve();

        element.shadowRoot.querySelector('.ba-btn--primary').click();
        await flushPromises();

        expect(replaceBroker).toHaveBeenCalledWith({
            assignmentId: RECORD_ID,
            newBrokerId: BROKER_ID,
            effectiveDate: null,
            reason: 'Performance Issue'
        });
    });

    it('ERROR BRANCH: stays empty when the detail wire errors', async () => {
        const element = createComponent();

        getDetail.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ba-tabcard')).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
