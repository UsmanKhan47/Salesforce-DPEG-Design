/**
 * c-work-order-escalations — @wire-to-Apex (no-param) right-column widget.
 *
 * Data source: @wire(getEscalations) on WorkOrderController — a parameterless
 * wire, so the adapter pattern from the c-broker-firm-card template applies
 * minus the reactive $recordId. getEscalations is registered as an Apex test
 * wire adapter (createApexTestWireAdapter); .emit() drives the data branch and
 * .error() drives the error branch.
 *
 * Work Orders are a READ-ONLY Yardi mirror, so the wrapper the JS reads mirrors
 * Work_Order__c fields: subject (Subject__c), property (Property_Asset__r.Name),
 * priority (Priority__c). Values are terminal/deterministic (no date math in
 * this component) so assertions never drift.
 */
import { createElement } from 'lwc';
import WorkOrderEscalations from 'c/workOrderEscalations';
import getEscalations from '@salesforce/apex/WorkOrderController.getEscalations';

jest.mock(
    '@salesforce/apex/WorkOrderController.getEscalations',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const ESCALATIONS = [
    {
        id: 'a1O5g000000W0AaEAK',
        subject: 'Rooftop HVAC compressor failure',
        property: 'Northgate Commons',
        priority: 'Critical'
    },
    {
        id: 'a1O5g000000W0AbEAK',
        subject: 'Elevator #2 stuck between floors',
        property: 'Midtown Tower',
        priority: 'High'
    },
    {
        id: 'a1O5g000000W0AcEAK',
        subject: 'Main lobby water intrusion',
        property: 'Harbor Point Plaza',
        priority: 'Critical'
    }
];

describe('c-work-order-escalations', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-work-order-escalations', {
            is: WorkOrderEscalations
        });
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.es-empty').textContent).toBe(
            'Nothing is on fire.'
        );
        expect(element.shadowRoot.querySelectorAll('.es-row').length).toBe(0);
        // Static header renders regardless of data.
        expect(element.shadowRoot.querySelector('.es-title').textContent).toBe(
            'Escalations'
        );
    });

    it('DATA BRANCH: renders one row per breached escalation', async () => {
        const element = createComponent();

        getEscalations.emit(ESCALATIONS);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.es-row');
        expect(rows.length).toBe(3);

        const names = [...element.shadowRoot.querySelectorAll('.es-name')].map(
            (el) => el.textContent
        );
        expect(names).toEqual([
            'Rooftop HVAC compressor failure',
            'Elevator #2 stuck between floors',
            'Main lobby water intrusion'
        ]);

        // Sub line is "<property> · <priority>".
        expect(
            element.shadowRoot.querySelector('.es-metasub').textContent
        ).toBe('Northgate Commons · Critical');

        // Record link points at the Work_Order__c view page.
        expect(rows[0].getAttribute('href')).toBe(
            '/lightning/r/Work_Order__c/a1O5g000000W0AaEAK/view'
        );
        expect(element.shadowRoot.querySelector('.es-empty')).toBeNull();
    });

    it('ERROR BRANCH: keeps the empty state and surfaces an inline alert without throwing', async () => {
        const element = createComponent();

        getEscalations.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.es-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelectorAll('.es-row').length).toBe(0);
        // Additive error banner appears alongside the existing empty content.
        expect(
            element.shadowRoot.querySelector('[role="alert"]')
        ).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getEscalations.emit(ESCALATIONS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
