/**
 * dealDocStatus — parameterised @wire to Apex + NavigationMixin.
 * -------------------------------------------------------------
 * WIRE-MOCK TEMPLATE 1 (parameterised): `OpportunityDocStatusController.getDocStatus`
 * is registered as a shared test wire adapter; `opportunityId: '$recordId'` is
 * satisfied by setting element.recordId. NavigationMixin is mocked so Navigate
 * dispatches an assertable `navigate` CustomEvent on the host.
 *
 * The DTO shape is derived only from this component's getters. NDA / Underwriting
 * / LOI rows always render (3 `.doc` sections); Development / Construction /
 * Contract render only when their `has*` flag is true (6 `.doc` sections). Money
 * (fmtMoney) and dates (fmtDate, UTC parts) are deterministic, so fixed fixture
 * values render stably.
 *
 * ⚠ `ndaSignedCopyReturned` (was `ndaSent`) carries NDA__c.Date_Sent__c, which the
 * 2026-08-16 acquisition NDA reorder turned into the TERMINAL step — it now dates the
 * return of the signed copy to the broker. The NDA meta assertion below pins that exact
 * wording, and pins the ABSENCE of the previous "Received <date>" label, because
 * `Received` is now a distinct status in this sequence: a stale label there would read
 * as a plausible date for a different step rather than as an obvious defect.
 */
import { createElement } from 'lwc';
import DealDocStatus from 'c/dealDocStatus';
import getDocStatus from '@salesforce/apex/OpportunityDocStatusController.getDocStatus';

jest.mock(
    '@salesforce/apex/OpportunityDocStatusController.getDocStatus',
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

const OPP_ID = '0065g00000AbCdEAAV';
const LOI_ID = 'a0L5g000000LoiAEAS';

const FULL_STATUS = {
    hasNda: true,
    ndaStatus: 'Signed',
    ndaSignedCopyReturned: '2025-03-10',
    ndaExpiry: '2026-03-10',
    ndaId: 'a0N5g000000NdaAEAS',

    hasUnderwriting: true,
    underwritingStage: 'Complete',
    underwritingPrice: 4500000,
    underwritingVerdict: 'Proceed',
    underwritingOpened: '2025-02-01',
    underwritingId: 'a0U5g000000UwAEAS',

    hasLoi: true,
    loiStatus: 'Submitted',
    loiOfferPrice: 5200000,
    loiCapRate: 6.5,
    loiSubmitted: '2025-04-15',
    loiId: LOI_ID,

    hasDevelopment: true,
    developmentStage: 'Site Visit',
    developmentOpened: '2025-02-20',
    developmentId: 'a0D5g000000DevAEAS',

    hasConstruction: true,
    constructionStage: 'Condition Assessment',
    constructionOpened: '2025-02-25',
    constructionId: 'a0C5g000000ConAEAS',

    hasContract: true,
    contractStage: 'PSA Drafting',
    contractValue: 5000000,
    contractDate: '2025-05-01',
    contractId: 'a0R5g000000CtrAEAS'
};

describe('c-deal-doc-status', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: OPP_ID }) {
        const element = createElement('c-deal-doc-status', {
            is: DealDocStatus
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('EMPTY: renders the 3 always-on rows with em-dash pills before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        // NDA / Underwriting / LOI only; Development / Construction / Contract hidden.
        expect(element.shadowRoot.querySelectorAll('.doc').length).toBe(3);

        const pills = [...element.shadowRoot.querySelectorAll('.pill')].map(
            (el) => el.textContent
        );
        expect(pills).toEqual(['—', '—', '—']);

        // Empty guidance is shown on the NDA row.
        expect(
            element.shadowRoot.querySelector('.doc-meta--empty').textContent
        ).toBe('No NDA on this deal yet');
    });

    it('DATA BRANCH: renders all six document rows with their status pills', async () => {
        const element = createComponent();

        getDocStatus.emit(FULL_STATUS);
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.doc').length).toBe(6);

        const pills = [...element.shadowRoot.querySelectorAll('.pill')].map(
            (el) => el.textContent
        );
        expect(pills).toEqual([
            'Signed',
            'Complete',
            'Submitted',
            'Site Visit',
            'Condition Assessment',
            'PSA Drafting'
        ]);
    });

    it('DATA BRANCH: labels the NDA date as the signed copy being RETURNED, not received', async () => {
        const element = createComponent();

        getDocStatus.emit(FULL_STATUS);
        await Promise.resolve();

        const ndaMeta = element.shadowRoot
            .querySelector('a[title="Open NDA"]')
            .closest('.doc')
            .querySelector('.doc-meta');

        // Date_Sent__c is the TERMINAL 'Sent' step: DPEG returned the signed copy.
        expect(ndaMeta.textContent).toBe(
            'Signed copy returned Mar 10, 2025  ·  Expires Mar 10, 2026'
        );

        // Falsifier for a revert to the pre-reorder label. 'Received' is now a real,
        // separate status on this sequence, so the old wording would not look wrong —
        // it would look like a correct date for the wrong step.
        expect(ndaMeta.textContent).not.toContain('Received');
    });

    it('DATA BRANCH: omits the returned-copy label entirely when the date is absent', async () => {
        const element = createComponent();

        getDocStatus.emit({ ...FULL_STATUS, ndaSignedCopyReturned: null });
        await Promise.resolve();

        const ndaMeta = element.shadowRoot
            .querySelector('a[title="Open NDA"]')
            .closest('.doc')
            .querySelector('.doc-meta');

        // Proves the assertion above is reading ndaSignedCopyReturned and not the expiry
        // date — a half-applied rename would leave this test passing and the one above red.
        expect(ndaMeta.textContent).toBe('Expires Mar 10, 2026');
    });

    it('DATA BRANCH: formats the LOI meta line (money, cap rate, date)', async () => {
        const element = createComponent();

        getDocStatus.emit(FULL_STATUS);
        await Promise.resolve();

        const loiPill = element.shadowRoot.querySelector('a[title="Open LOI"]')
            .closest('.doc-head')
            .querySelector('.pill');
        expect(loiPill.className).toContain('pill--blue');

        // fmtMoney(5.2M) -> $5.2M ; capRate 6.5 -> "6.5% cap" ; date -> "Apr 15, 2025"
        const metas = [...element.shadowRoot.querySelectorAll('.doc-meta')].map(
            (el) => el.textContent
        );
        expect(metas).toContain('$5.2M  ·  6.5% cap  ·  Apr 15, 2025');
    });

    it('DATA BRANCH: tones the reordered NDA "Received" stage as in-progress, not unknown', async () => {
        const element = createComponent();

        getDocStatus.emit({ ...FULL_STATUS, ndaStatus: 'Received' });
        await Promise.resolve();

        const ndaPill = element.shadowRoot
            .querySelector('a[title="Open NDA"]')
            .closest('.doc-head')
            .querySelector('.pill');

        expect(ndaPill.textContent).toBe('Received');
        // 'Received' entered the sequence with the 2026-08-16 reorder. Grey is this
        // component's fallback for an UNKNOWN status, so grey here would mean a live
        // stage is rendering as unrecognised.
        expect(ndaPill.className).toContain('pill--blue');
        expect(ndaPill.className).not.toContain('pill--grey');
    });

    it('navigates to the LOI record when the LOI link is clicked', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getDocStatus.emit(FULL_STATUS);
        await Promise.resolve();

        element.shadowRoot.querySelector('a[title="Open LOI"]').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(navHandler.mock.calls[0][0].detail).toEqual({
            type: 'standard__recordPage',
            attributes: {
                recordId: LOI_ID,
                objectApiName: 'LOI__c',
                actionName: 'view'
            }
        });
    });

    it('ERROR BRANCH: renders an inline error state (not the doc rows) on wire error', async () => {
        const element = createComponent();

        getDocStatus.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.doc').length).toBe(0);
        const err = element.shadowRoot.querySelector('.dds-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getDocStatus.emit(FULL_STATUS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
