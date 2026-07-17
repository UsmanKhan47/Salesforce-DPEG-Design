/**
 * leaseInquiryList — @wire to Apex (no-param) + NavigationMixin + c-list-datatable.
 * --------------------------------------------------------------------------------
 * WIRE-MOCK TEMPLATE 1: `getRecentInquiries` is registered as a shared test wire
 * adapter and driven with .emit / .error. Rows are asserted via the child
 * c-list-datatable's `.data` @api property (a LightningDatatable subclass renders
 * no queryable cell DOM in jest — read the assigned rows off the element).
 *
 * NavigationMixin is mocked so Navigate dispatches an assertable `navigate`
 * CustomEvent on the host, and GenerateUrl returns a resolved promise (the
 * component awaits it in connectedCallback to populate the "View All" href).
 *
 * Lease Activity Tracker DASHBOARD component — LeaseInquiryController.cls is NOT
 * opened; the DTO shape ({ id, tenant, property, broker, received, stage, ball,
 * days, closed }) is derived only from this component's own `rows` getter.
 * Aging pills are driven by the server `days` value (not `new Date()`), so the
 * fixture is deterministic.
 */
import { createElement } from 'lwc';
import LeaseInquiryList from 'c/leaseInquiryList';
import getRecentInquiries from '@salesforce/apex/LeaseInquiryController.getRecentInquiries';

jest.mock(
    '@salesforce/apex/LeaseInquiryController.getRecentInquiries',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock('lightning/navigation', () => {
    const Navigate = Symbol('Navigate');
    const GenerateUrl = Symbol('GenerateUrl');
    const NavigationMixin = (Base) =>
        class extends Base {
            [Navigate](ref) {
                this.dispatchEvent(new CustomEvent('navigate', { detail: ref }));
            }
            [GenerateUrl]() {
                return Promise.resolve('/lightning/o/Lease_Inquiry__c/list');
            }
        };
    NavigationMixin.Navigate = Navigate;
    NavigationMixin.GenerateUrl = GenerateUrl;
    return { NavigationMixin, CurrentPageReference: jest.fn() };
});

const INQUIRIES = [
    {
        id: 'a0Q000000000001',
        tenant: 'Sweetgreen',
        property: '4820 Westheimer',
        broker: 'CBRE',
        received: '2025-05-01',
        stage: 'LOI Negotiation',
        ball: 'Legal',
        days: 20, // > 14 -> red aging pill
        closed: false
    },
    {
        id: 'a0Q000000000002',
        tenant: 'Chipotle',
        property: '900 Congress',
        broker: 'JLL',
        received: '2025-05-10',
        stage: 'Lease Signed',
        ball: 'Landlord',
        days: 4,
        closed: true // -> daysText 'Signed'
    }
];

describe('c-lease-inquiry-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-lease-inquiry-list', {
            is: LeaseInquiryList
        });
        document.body.appendChild(element);
        return element;
    }

    function datatable(element) {
        return element.shadowRoot.querySelector('c-list-datatable');
    }

    it('EMPTY: header count is 0 and the datatable has no rows before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Recent Inquiries (0)');
        expect(datatable(element).data).toEqual([]);
    });

    it('DATA BRANCH: maps each inquiry into a datatable row with derived aging text', async () => {
        const element = createComponent();

        getRecentInquiries.emit(INQUIRIES);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Recent Inquiries (2)');

        const rows = datatable(element).data;
        expect(rows.length).toBe(2);

        // Row 0: open, 20 days -> "20d"; row link points at the record.
        expect(rows[0].daysText).toBe('20d');
        expect(rows[0].recordUrl).toBe(
            '/lightning/r/Lease_Inquiry__c/a0Q000000000001/view'
        );
        expect(rows[0].tenant).toBe('Sweetgreen');

        // Row 1: closed -> "Signed".
        expect(rows[1].daysText).toBe('Signed');
    });

    it('DATA BRANCH: falls back to an em dash for missing text values', async () => {
        const element = createComponent();

        getRecentInquiries.emit([
            {
                id: 'a0Q000000000003',
                tenant: null,
                property: null,
                broker: null,
                received: '2025-05-15',
                stage: 'Inquiry Received',
                ball: null,
                days: 2,
                closed: false
            }
        ]);
        await Promise.resolve();

        const row = datatable(element).data[0];
        expect(row.tenant).toBe('—');
        expect(row.property).toBe('—');
        expect(row.broker).toBe('—');
        expect(row.ball).toBe('—');
        expect(row.daysText).toBe('2d');
    });

    it('navigates to a new Lease Inquiry when "New Inquiry" is clicked', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        await Promise.resolve();

        const newBtn = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === 'New Inquiry');
        newBtn.click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(navHandler.mock.calls[0][0].detail).toEqual({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Lease_Inquiry__c',
                actionName: 'new'
            }
        });
    });

    it('navigates to the filtered list view when "View All" is clicked', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        await Promise.resolve();

        element.shadowRoot.querySelector('.view-all-footer a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(navHandler.mock.calls[0][0].detail).toEqual({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Lease_Inquiry__c',
                actionName: 'list'
            },
            state: { filterName: 'Active_Pipeline' }
        });
    });

    it('ERROR BRANCH: keeps an empty datatable when the wire errors', async () => {
        const element = createComponent();

        getRecentInquiries.error();
        await Promise.resolve();

        expect(datatable(element).data).toEqual([]);
        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Recent Inquiries (0)');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecentInquiries.emit(INQUIRIES);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
