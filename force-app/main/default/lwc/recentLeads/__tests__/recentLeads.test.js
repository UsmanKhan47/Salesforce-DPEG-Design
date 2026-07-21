/**
 * c-recent-leads — @wire-to-Apex suite WITH NavigationMixin.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1) + the lwc-recipes
 * navigation mock (matches c-broker-scorecard).
 *
 * Data source: @wire(getFunnel) from LeadFunnelController.getFunnel. The JS reads
 * `data.recent` and feeds the first 5 rows to a c-list-datatable, with the count in
 * the card title. connectedCallback resolves a "View All" URL via
 * NavigationMixin.GenerateUrl, and the footer link navigates to the Lead list view.
 *
 * lightning/navigation is mocked so [Navigate] dispatches a catchable 'navigate'
 * event carrying the PageReference (the sfdx-lwc-jest stub's Navigate is a no-op, and
 * the host element and component instance differ, so an instance override cannot
 * capture the call). Rows are asserted via the datatable's `data` @api — c-list-datatable
 * extends the stubbed lightning/datatable, so cell DOM is not rendered here.
 */
import { createElement } from 'lwc';
import RecentLeads from 'c/recentLeads';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';

jest.mock(
    'lightning/navigation',
    () => {
        const Navigate = Symbol('Navigate');
        const GenerateUrl = Symbol('GenerateUrl');
        const NavigationMixin = (Base) =>
            class extends Base {
                [Navigate](pageReference) {
                    this.dispatchEvent(
                        new CustomEvent('navigate', { detail: { pageReference } })
                    );
                }
                [GenerateUrl]() {
                    return Promise.resolve('https://example.com/lead-list');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/LeadFunnelController.getFunnel',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// 6 recent leads -> the JS slices to the first 5.
const FUNNEL = {
    recent: [
        { id: '00Q000000000001', name: 'Gateway Plaza', status: 'New', channel: 'Email-to-Lead', confidence: 'High', broker: 'Dana Reyes', priority: 'High', days: 2 },
        { id: '00Q000000000002', name: 'Harbor Point', status: 'Under Review', channel: 'Broker Portal', confidence: 'Medium', broker: 'Sam Okafor', priority: 'Normal', days: 5 },
        { id: '00Q000000000003', name: 'Cedar Commons', status: 'Qualified', channel: 'Manual Entry', confidence: 'Low', broker: 'Unknown', priority: 'Normal', days: 9 },
        { id: '00Q000000000004', name: 'Oak Ridge', status: 'Converted', channel: 'Email-to-Lead', confidence: 'High', broker: 'Jo Lin', priority: 'Normal', days: 12 },
        { id: '00Q000000000005', name: 'Pine Tower', status: 'Disqualified', channel: 'Broker Portal', confidence: null, broker: 'Unknown', priority: 'Normal', days: 30 },
        { id: '00Q000000000006', name: 'Maple Court', status: 'New', channel: 'Manual Entry', confidence: 'High', broker: 'Alex Kim', priority: 'High', days: 1 }
    ]
};

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

describe('c-recent-leads', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-recent-leads', { is: RecentLeads });
        document.body.appendChild(element);
        return element;
    }

    it('EMPTY: shows a zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Leads (0)');
        expect(datatable(element).data).toEqual([]);
    });

    it('DATA BRANCH: caps the datatable at the 5 most recent and counts them', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(5); // 6 emitted, sliced to 5
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Leads (5)');
    });

    it('DATA BRANCH: transforms a row (record URL, priority star, age suffix)', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        const first = datatable(element).data[0];
        expect(first.recordUrl).toBe('/lightning/r/Lead/00Q000000000001/view');
        expect(first.name).toBe('Gateway Plaza');
        expect(first.broker).toBe('⭐ Dana Reyes'); // priority High -> starred
        expect(first.days).toBe('2d');
        expect(first.channelIcon).toBe('utility:file');

        // Non-high priority + Unknown broker -> plain 'Unknown', no star.
        expect(datatable(element).data[2].broker).toBe('Unknown');
    });

    it('VIEW ALL: clicking the footer link navigates to the Lead list view', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        element.shadowRoot.querySelector('.view-all-footer a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__objectPage');
        expect(pageRef.attributes.objectApiName).toBe('Lead');
        expect(pageRef.attributes.actionName).toBe('list');
    });

    it('ERROR BRANCH: renders an inline error state and hides the datatable when the wire errors', async () => {
        const element = createComponent();

        getFunnel.error({ message: 'Lead feed unavailable.' });
        await Promise.resolve();

        // The datatable is replaced by a visible error message (not a silent blank).
        expect(datatable(element)).toBeNull();
        const err = element.shadowRoot.querySelector('.lv-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Lead feed unavailable.');
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Leads (0)');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
