/**
 * c-broker-assignment-list
 * ---------------------------------------------------------------------------
 * No-param @wire(getAssignments) feeding a c-list-datatable, with client-side
 * status-tab filtering and a "days idle" sort. NavigationMixin drives the
 * New Assignment button (lightning/navigation is auto-stubbed by sfdx-lwc-jest).
 *
 * Rows are asserted through the datatable's `data` @api rather than table DOM,
 * because c-list-datatable extends the stubbed lightning/datatable.
 */
import { createElement } from 'lwc';
import BrokerAssignmentList from 'c/brokerAssignmentList';
import getAssignments from '@salesforce/apex/BrokerAssignmentController.getAssignments';

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getAssignments',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const ASSIGNMENTS = [
    {
        id: 'a0X0000000000001AAA',
        propertyName: 'Gateway Plaza',
        brokerName: 'Dana Reyes',
        status: 'Active',
        startDate: '2025-01-15',
        lastCheckIn: '2025-02-01',
        daysIdle: 25
    },
    {
        id: 'a0X0000000000002AAA',
        propertyName: 'Harbor Point',
        brokerName: 'Sam Okafor',
        status: 'Active',
        startDate: '2024-11-01',
        lastCheckIn: '2025-02-20',
        daysIdle: 5
    },
    {
        id: 'a0X0000000000003AAA',
        propertyName: 'Cedar Commons',
        brokerName: 'Jo Lin',
        status: 'Fully Leased',
        startDate: '2024-03-01',
        lastCheckIn: '2024-09-01',
        daysIdle: null
    }
];

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

describe('c-broker-assignment-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-assignment-list', {
            is: BrokerAssignmentList
        });
        document.body.appendChild(element);
        return element;
    }

    it('shows an empty tracker (count 0) before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.hdr-title').textContent).toBe(
            'Broker Tracker (0)'
        );
        expect(datatable(element).data).toEqual([]);
    });

    it('DATA BRANCH: feeds every assignment to the datatable and counts them', async () => {
        const element = createComponent();

        getAssignments.emit(ASSIGNMENTS);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(3);
        expect(element.shadowRoot.querySelector('.hdr-title').textContent).toBe(
            'Broker Tracker (3)'
        );
        // Sorted by days idle desc by default: 25, 5, then null (-1).
        const props = datatable(element).data.map((r) => r.propertyName);
        expect(props[0]).toBe('Gateway Plaza');
    });

    it('STATUS TABS: counts per status and filters the datatable', async () => {
        const element = createComponent();

        getAssignments.emit(ASSIGNMENTS);
        await Promise.resolve();

        const tabs = element.shadowRoot.querySelectorAll('.tabs .sf-tab');
        // Tabs: All / Active / Leased / Disposed
        const counts = [...tabs].map(
            (t) => t.querySelector('.tab-count').textContent
        );
        expect(counts).toEqual(['3', '2', '1', '0']);

        // Click "Active" (data-key='Active') -> only the two Active rows remain.
        const activeTab = [...tabs].find((t) => t.dataset.key === 'Active');
        activeTab.click();
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(2);
        expect(
            datatable(element).data.every((r) => r.status === 'Active')
        ).toBe(true);
    });

    it('SORT: toggling sort direction re-orders days idle ascending', async () => {
        const element = createComponent();

        getAssignments.emit(ASSIGNMENTS);
        await Promise.resolve();

        datatable(element).dispatchEvent(
            new CustomEvent('sort', {
                detail: { sortDirection: 'asc', fieldName: 'daysText' }
            })
        );
        await Promise.resolve();

        // Ascending: null (-1) first, then 5, then 25.
        const props = datatable(element).data.map((r) => r.propertyName);
        expect(props).toEqual(['Cedar Commons', 'Harbor Point', 'Gateway Plaza']);
    });

    it('NEW ASSIGNMENT: the create button is present and clickable', async () => {
        const element = createComponent();

        getAssignments.emit(ASSIGNMENTS);
        await Promise.resolve();

        const btn = element.shadowRoot.querySelector('lightning-button');
        expect(btn.label).toBe('New Assignment');
        // NavigationMixin.Navigate is a no-op stub in jest; assert it does not throw.
        expect(() => btn.click()).not.toThrow();
    });

    it('ERROR BRANCH: shows an error banner and an empty tracker when the wire errors', async () => {
        const element = createComponent();

        getAssignments.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.hdr-title').textContent).toBe(
            'Broker Tracker (0)'
        );
        expect(datatable(element).data).toEqual([]);
        const banner = element.shadowRoot.querySelector('.lst-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toBe("Couldn't load broker assignments.");
    });

    it('is accessible', async () => {
        const element = createComponent();

        getAssignments.emit(ASSIGNMENTS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
