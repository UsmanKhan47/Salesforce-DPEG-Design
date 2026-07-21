/**
 * leaseStatusSummary — parameterised @wire to Apex + NavigationMixin.
 * ------------------------------------------------------------------
 * WIRE-MOCK TEMPLATE 1 (parameterised): `getLeaseSummary` is registered as a
 * shared test wire adapter; the `inquiryId: '$recordId'` reactive param is
 * satisfied by setting element.recordId before appendChild. NavigationMixin is
 * mocked so the Navigate call dispatches an assertable `navigate` CustomEvent on
 * the host (per lwc-wire-mock-templates memory). Lease Activity Tracker DASHBOARD
 * component — LeaseInquiryController.cls is NOT opened; the DTO shape is derived
 * only from this component's own getters ({ exists, leaseName, stage, legalOwner,
 * targetDate, executedDate, leaseId }). Date output uses UTC parts, so fixed
 * date strings render stably regardless of run day.
 */
import { createElement } from 'lwc';
import LeaseStatusSummary from 'c/leaseStatusSummary';
import getLeaseSummary from '@salesforce/apex/LeaseInquiryController.getLeaseSummary';

jest.mock(
    '@salesforce/apex/LeaseInquiryController.getLeaseSummary',
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
                return Promise.resolve('/url');
            }
        };
    NavigationMixin.Navigate = Navigate;
    NavigationMixin.GenerateUrl = GenerateUrl;
    return { NavigationMixin, CurrentPageReference: jest.fn() };
});

const INQUIRY_ID = 'a0X5g000000LiqAEAS';
const LEASE_ID = 'a0Y5g000000LeaAEAS';

const LEASE_LINKED = {
    exists: true,
    leaseName: 'Lease - 4820 Westheimer',
    stage: 'Prepare/Review',
    legalOwner: 'M. Alvarez',
    targetDate: '2025-08-01',
    executedDate: null,
    leaseId: LEASE_ID
};
const NO_LEASE = { exists: false };

describe('c-lease-status-summary', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: INQUIRY_ID }) {
        const element = createElement('c-lease-status-summary', {
            is: LeaseStatusSummary
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('EMPTY: shows the muted placeholder + guidance before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.doc-name--muted').textContent
        ).toBe('Lease');
        expect(element.shadowRoot.querySelector('a.doc-name')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.doc-meta--empty').textContent
        ).toBe('Created for legal once the inquiry reaches Lease Drafting');
    });

    it('DATA BRANCH (linked): renders the lease link, stage pill and meta line', async () => {
        const element = createComponent();

        getLeaseSummary.emit(LEASE_LINKED);
        await Promise.resolve();

        const link = element.shadowRoot.querySelector('a.doc-name');
        expect(link.textContent).toBe('Lease - 4820 Westheimer');

        const pill = element.shadowRoot.querySelector('.pill');
        expect(pill.textContent).toBe('Prepare/Review');
        expect(pill.className).toContain('pill--blue');

        expect(element.shadowRoot.querySelector('.doc-meta').textContent).toBe(
            'M. Alvarez  ·  Target Aug 1, 2025'
        );
    });

    it('DATA BRANCH (not linked): keeps the muted placeholder when no lease exists', async () => {
        const element = createComponent();

        getLeaseSummary.emit(NO_LEASE);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('a.doc-name')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.doc-name--muted').textContent
        ).toBe('Lease');
    });

    it('navigates to the Lease record when the lease name is clicked', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getLeaseSummary.emit(LEASE_LINKED);
        await Promise.resolve();

        element.shadowRoot.querySelector('a.doc-name').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(navHandler.mock.calls[0][0].detail).toEqual({
            type: 'standard__recordPage',
            attributes: {
                recordId: LEASE_ID,
                objectApiName: 'Lease__c',
                actionName: 'view'
            }
        });
    });

    it('ERROR BRANCH: shows an inline error (not the muted placeholder) when the wire errors', async () => {
        const element = createComponent();

        getLeaseSummary.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('a.doc-name')).toBeNull();
        expect(element.shadowRoot.querySelector('.doc-name--muted')).toBeNull();
        expect(element.shadowRoot.querySelector('.doc-error')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getLeaseSummary.emit(LEASE_LINKED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
