/**
 * c-work-order-list — @wire-to-Apex (no-param) list on the Work Orders home.
 *
 * Data source: @wire(getRecentWorkOrders) on WorkOrderController. The component
 * also mixes in NavigationMixin; the sfdx-lwc-jest stub resolves
 * GenerateUrl() to a resolved Promise, so connectedCallback settles cleanly.
 *
 * The wired wrapper mirrors Work_Order__c fields the JS reads: subject, property,
 * unit, priority, status, slaHealth (SLA_Health__c formula), hoursOpen
 * (Hours_Open__c). Every derived value (SLA pill text, Days Open) is computed
 * from those strings/numbers — NO new Date() — so results are date-stable.
 * The derived `rows` are handed to the shared c-list-datatable, which this test
 * inspects via its public `data`/`columns` properties.
 */
import { createElement } from 'lwc';
import WorkOrderList from 'c/workOrderList';
import getRecentWorkOrders from '@salesforce/apex/WorkOrderController.getRecentWorkOrders';

jest.mock(
    '@salesforce/apex/WorkOrderController.getRecentWorkOrders',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const WORK_ORDERS = [
    {
        id: 'a1O5g000000W0AaEAK',
        subject: 'Rooftop HVAC compressor failure',
        property: 'Northgate Commons',
        unit: 'Suite 400',
        priority: 'Critical',
        status: 'Open',
        slaHealth: 'Breached SLA',
        hoursOpen: 72
    },
    {
        id: 'a1O5g000000W0AbEAK',
        subject: 'Parking lot lighting outage',
        property: 'Midtown Tower',
        unit: '',
        priority: 'Medium',
        status: 'In Progress',
        slaHealth: 'On Track',
        hoursOpen: 12
    }
];

describe('c-work-order-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-work-order-list', {
            is: WorkOrderList
        });
        document.body.appendChild(element);
        return element;
    }

    it('renders a zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Open Work Orders (0)');

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table).not.toBeNull();
        expect(table.data.length).toBe(0);
    });

    it('DATA BRANCH: feeds derived rows into the datatable and updates the count', async () => {
        const element = createComponent();

        getRecentWorkOrders.emit(WORK_ORDERS);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Open Work Orders (2)');

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.length).toBe(2);

        // SLA health string -> pill label; hoursOpen -> whole days.
        expect(table.data[0].slaText).toBe('Breached');
        expect(table.data[0].daysOpen).toBe('3d'); // 72h / 24
        expect(table.data[0].propUnit).toBe('Northgate Commons · Suite 400');

        expect(table.data[1].slaText).toBe('On Track');
        expect(table.data[1].daysOpen).toBe('0d'); // 12h / 24
        // No unit -> property only, no separator.
        expect(table.data[1].propUnit).toBe('Midtown Tower');
    });

    it('ERROR BRANCH: keeps the empty datatable when the wire errors', async () => {
        const element = createComponent();

        getRecentWorkOrders.error();
        await Promise.resolve();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.length).toBe(0);
        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Open Work Orders (0)');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecentWorkOrders.emit(WORK_ORDERS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
