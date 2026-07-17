/**
 * leaseAttention — Lease Activity Tracker dashboard widget.
 * WIRE-MOCK TEMPLATE 1 (@wire to Apex, no params) applied.
 *
 * Data source: @wire(getAttention) from LeaseInquiryController. The controller
 * .cls is NOT opened/edited — the DTO shape ({ id, days, tenant, stage, ball })
 * is derived solely from leaseAttention.js, which is authoritative.
 */
import { createElement } from 'lwc';
import LeaseAttention from 'c/leaseAttention';
import getAttention from '@salesforce/apex/LeaseInquiryController.getAttention';

jest.mock(
    '@salesforce/apex/LeaseInquiryController.getAttention',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// aging buckets: >14 red (#FDF0F0), >7 amber (#FDF5E6), else green (#EBF9F1)
const ROWS = [
    { id: 'a0L01', days: 20, tenant: 'Aster Dental', stage: 'LOI Negotiation', ball: 'Landlord' },
    { id: 'a0L02', days: 10, tenant: 'Blue Bottle', stage: 'Lease Drafting', ball: 'Legal' },
    { id: 'a0L03', days: 3, tenant: 'Cedar Yoga', stage: 'Inquiry Received', ball: 'Tenant' }
];

describe('c-lease-attention', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-lease-attention', { is: LeaseAttention });
        document.body.appendChild(element);
        return element;
    }

    function pillSpan(row) {
        return [...row.querySelectorAll('span')].find((s) =>
            (s.getAttribute('style') || '').includes('9999px')
        );
    }

    it('EMPTY BRANCH: shows the empty message before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.at-row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.at-empty').textContent).toBe(
            'Nothing needs a nudge right now.'
        );
    });

    it('DATA BRANCH: renders one row per inquiry with tenant + subline', async () => {
        const element = createComponent();

        getAttention.emit(ROWS);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.at-row');
        expect(rows.length).toBe(3);
        expect(element.shadowRoot.querySelector('.at-empty')).toBeNull();

        const names = [...element.shadowRoot.querySelectorAll('.at-name')].map(
            (el) => el.textContent
        );
        expect(names).toEqual(['Aster Dental', 'Blue Bottle', 'Cedar Yoga']);

        const subs = [...element.shadowRoot.querySelectorAll('.at-metasub')].map(
            (el) => el.textContent
        );
        expect(subs[0]).toBe('LOI Negotiation · ball with Landlord');

        // record link points at the Lease_Inquiry__c record page.
        expect(rows[0].getAttribute('href')).toBe(
            '/lightning/r/Lease_Inquiry__c/a0L01/view'
        );
    });

    it('DATA BRANCH: aging colour + days text follow the 14/7-day thresholds', async () => {
        const element = createComponent();

        getAttention.emit(ROWS);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.at-row');
        // 20d -> red
        expect(pillSpan(rows[0]).textContent).toBe('20d');
        expect(pillSpan(rows[0]).getAttribute('style')).toContain('#FDF0F0');
        // 10d -> amber
        expect(pillSpan(rows[1]).getAttribute('style')).toContain('#FDF5E6');
        // 3d -> green
        expect(pillSpan(rows[2]).getAttribute('style')).toContain('#EBF9F1');
    });

    it('DATA BRANCH: null days collapses to 0d (green) and missing tenant to a dash', async () => {
        const element = createComponent();

        getAttention.emit([
            { id: 'a0L09', days: null, tenant: null, stage: 'LOI Received', ball: 'Broker' }
        ]);
        await Promise.resolve();

        const row = element.shadowRoot.querySelector('.at-row');
        expect(element.shadowRoot.querySelector('.at-name').textContent).toBe('—');
        expect(pillSpan(row).textContent).toBe('0d');
        expect(pillSpan(row).getAttribute('style')).toContain('#EBF9F1');
    });

    it('ERROR BRANCH: keeps the empty state when the wire errors', async () => {
        const element = createComponent();

        getAttention.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.at-row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.at-empty')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getAttention.emit(ROWS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
