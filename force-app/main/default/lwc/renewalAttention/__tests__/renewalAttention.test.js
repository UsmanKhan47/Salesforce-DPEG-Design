/**
 * c-renewal-attention — @wire-to-Apex (no-param) right-column widget listing
 * renewals that need a nudge (tenant gone quiet, or lease expiring within 30d).
 *
 * Data source: @wire(getAttention) on LeaseRenewalController. The wired wrapper
 * exposes { id, tenant, stage, nonResponsive, daysToExpiry, daysSinceContact }.
 * daysToExpiry is a pre-computed integer from Apex (not derived from new Date()
 * in the JS), so the pill text is deterministic; the fixture uses a negative
 * value to exercise the "Expired" branch stably.
 */
import { createElement } from 'lwc';
import RenewalAttention from 'c/renewalAttention';
import getAttention from '@salesforce/apex/LeaseRenewalController.getAttention';

jest.mock(
    '@salesforce/apex/LeaseRenewalController.getAttention',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const ATTENTION = [
    {
        id: 'a2R5g000000RnwAEAS',
        tenant: 'Blue Bottle Coffee',
        stage: 'Negotiating',
        nonResponsive: true,
        daysToExpiry: 18,
        daysSinceContact: 21
    },
    {
        id: 'a2R5g000000RnwBEAS',
        tenant: 'Sunbelt Rentals',
        stage: 'Awaiting Tenant Response',
        nonResponsive: false,
        daysToExpiry: 12,
        daysSinceContact: 4
    },
    {
        id: 'a2R5g000000RnwCEAS',
        tenant: 'Peak Physical Therapy',
        stage: 'Notice Sent',
        nonResponsive: false,
        daysToExpiry: -3,
        daysSinceContact: 9
    }
];

describe('c-renewal-attention', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-renewal-attention', {
            is: RenewalAttention
        });
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ra-empty').textContent).toBe(
            'Every renewal is on track.'
        );
        expect(element.shadowRoot.querySelectorAll('.ra-row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.ra-title').textContent).toBe(
            'Needs Attention'
        );
    });

    it('DATA BRANCH: renders a row per renewal with the right sub-line + pill', async () => {
        const element = createComponent();

        getAttention.emit(ATTENTION);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.ra-row');
        expect(rows.length).toBe(3);

        const tenants = [
            ...element.shadowRoot.querySelectorAll('.ra-name')
        ].map((el) => el.textContent);
        expect(tenants).toEqual([
            'Blue Bottle Coffee',
            'Sunbelt Rentals',
            'Peak Physical Therapy'
        ]);

        const subs = [
            ...element.shadowRoot.querySelectorAll('.ra-metasub')
        ].map((el) => el.textContent);
        // Non-responsive tenants read "Non-responsive · Nd silent"; others
        // read "<stage> · expires soon".
        expect(subs[0]).toBe('Non-responsive · 21d silent');
        expect(subs[1]).toBe('Awaiting Tenant Response · expires soon');

        // daysToExpiry: positive -> "Nd left"; negative -> "Expired".
        const pills = [
            ...element.shadowRoot.querySelectorAll('.ra-row > span[style]')
        ].map((el) => el.textContent);
        expect(pills).toEqual(['18d left', '12d left', 'Expired']);

        expect(rows[0].getAttribute('href')).toBe(
            '/lightning/r/Lease_Renewal__c/a2R5g000000RnwAEAS/view'
        );
    });

    it('ERROR BRANCH: degrades to the empty state without throwing', async () => {
        const element = createComponent();

        getAttention.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ra-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelectorAll('.ra-row').length).toBe(0);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getAttention.emit(ATTENTION);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
