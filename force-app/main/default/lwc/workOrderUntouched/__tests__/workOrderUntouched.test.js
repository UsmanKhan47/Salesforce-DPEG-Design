/**
 * c-work-order-untouched — @wire-to-Apex (no-param) right-column widget listing
 * open work orders nobody has acted on yet.
 *
 * Data source: @wire(getUntouched) on WorkOrderController. The wired wrapper
 * mirrors Work_Order__c fields: subject, property, priority, slaHealth
 * (SLA_Health__c formula). The SLA pill label is derived purely from the
 * slaHealth string (indexOf checks) — NO date math — so it is deterministic.
 */
import { createElement } from 'lwc';
import WorkOrderUntouched from 'c/workOrderUntouched';
import getUntouched from '@salesforce/apex/WorkOrderController.getUntouched';

jest.mock(
    '@salesforce/apex/WorkOrderController.getUntouched',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const UNTOUCHED = [
    {
        id: 'a1O5g000000W0AaEAK',
        subject: 'Rooftop HVAC compressor failure',
        property: 'Northgate Commons',
        priority: 'Critical',
        slaHealth: 'Breached SLA'
    },
    {
        id: 'a1O5g000000W0AbEAK',
        subject: 'Suite 210 thermostat unresponsive',
        property: 'Midtown Tower',
        priority: 'Medium',
        slaHealth: 'Due Soon'
    },
    {
        id: 'a1O5g000000W0AcEAK',
        subject: 'Garage gate sensor recalibration',
        property: 'Harbor Point Plaza',
        priority: 'Low',
        slaHealth: 'On Track'
    }
];

describe('c-work-order-untouched', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-work-order-untouched', {
            is: WorkOrderUntouched
        });
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ut-empty').textContent).toBe(
            'Everything has been picked up.'
        );
        expect(element.shadowRoot.querySelectorAll('.ut-row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.ut-title').textContent).toBe(
            'Untouched'
        );
    });

    it('DATA BRANCH: renders a row with a derived SLA label per work order', async () => {
        const element = createComponent();

        getUntouched.emit(UNTOUCHED);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.ut-row');
        expect(rows.length).toBe(3);

        const names = [...element.shadowRoot.querySelectorAll('.ut-name')].map(
            (el) => el.textContent
        );
        expect(names).toEqual([
            'Rooftop HVAC compressor failure',
            'Suite 210 thermostat unresponsive',
            'Garage gate sensor recalibration'
        ]);

        // slaHealth string -> pill label.
        const pills = [
            ...element.shadowRoot.querySelectorAll('.ut-row span[style]')
        ].map((el) => el.textContent);
        expect(pills).toEqual(['Breached', 'Due Soon', 'On Track']);

        expect(rows[0].getAttribute('href')).toBe(
            '/lightning/r/Work_Order__c/a1O5g000000W0AaEAK/view'
        );
        expect(element.shadowRoot.querySelector('.ut-empty')).toBeNull();
    });

    it('ERROR BRANCH: keeps the empty state and surfaces an inline alert without throwing', async () => {
        const element = createComponent();

        getUntouched.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ut-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelectorAll('.ut-row').length).toBe(0);
        // Additive error banner appears alongside the existing empty content.
        expect(
            element.shadowRoot.querySelector('[role="alert"]')
        ).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getUntouched.emit(UNTOUCHED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
