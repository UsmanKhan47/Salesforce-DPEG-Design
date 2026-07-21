/**
 * WIRE-MOCK TEMPLATE — @wire to LDS (getRelatedListRecords) + NavigationMixin
 * --------------------------------------------------------------------------
 * Variant of the LDS template for RELATED-LIST reads. The sfdx-lwc-jest
 * `lightning/uiRelatedListApi` stub already exports getRelatedListRecords as an
 * LDS test wire adapter, so — as with getRecord — there is NO jest.mock() for
 * it. Drive it with getRelatedListRecords.emit({ records: [...] }); each record
 * is a UI-API record: { id, fields: { Field__c: { value } } } using the REAL
 * Disposition_Offer__c field API names the component reads.
 *
 * NavigationMixin is mocked (per the project convention) so the "+ Log Offer"
 * button's Navigate call DISPATCHES an assertable 'navigate' event.
 */
import { createElement } from 'lwc';
import DispositionOffer from 'c/dispositionOffer';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';

jest.mock('lightning/navigation', () => {
    const Navigate = Symbol('Navigate');
    const GenerateUrl = Symbol('GenerateUrl');
    const NavigationMixin = (Base) =>
        class extends Base {
            [Navigate](pageRef) {
                this.dispatchEvent(
                    new CustomEvent('navigate', { detail: pageRef })
                );
            }
            [GenerateUrl]() {
                return Promise.resolve('/');
            }
        };
    NavigationMixin.Navigate = Navigate;
    NavigationMixin.GenerateUrl = GenerateUrl;
    return { NavigationMixin, CurrentPageReference: jest.fn() };
});

const OFFERS = {
    records: [
        {
            id: 'a0E01',
            fields: {
                Buyer_Name__c: { value: 'Blackstone RE' },
                Offer_Amount__c: { value: 2500000 },
                Offer_Date__c: { value: '2026-03-15' }
            }
        },
        {
            id: 'a0E02',
            fields: {
                Buyer_Name__c: { value: 'Brookfield' },
                Offer_Amount__c: { value: 2350000 },
                Offer_Date__c: { value: '2026-03-20' }
            }
        }
    ]
};

describe('c-disposition-offer', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-disposition-offer', {
            is: DispositionOffer
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty message and clock note before any offers load', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.offer-row').length).toBe(0);
        expect(
            element.shadowRoot.querySelector('.empty-msg').textContent
        ).toBe('No offers yet. 6-week clock active.');
    });

    it('DATA BRANCH: renders one row per related offer with formatted money + date', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.offer-row');
        expect(rows.length).toBe(2);

        expect(
            element.shadowRoot.querySelector('.offer-buyer').textContent
        ).toBe('Blackstone RE');
        expect(
            element.shadowRoot.querySelector('.offer-amount').textContent
        ).toBe('$2.50M');
        expect(
            element.shadowRoot.querySelector('.offer-date').textContent
        ).toBe('Mar 15, 2026');

        expect(element.shadowRoot.querySelector('.empty-msg')).toBeNull();
    });

    it('navigates to a new Disposition Offer when "+ Log Offer" is clicked', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        await Promise.resolve();

        element.shadowRoot.querySelector('.log-btn').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail;
        expect(pageRef.type).toBe('standard__objectPage');
        expect(pageRef.attributes.objectApiName).toBe('Disposition_Offer__c');
        expect(pageRef.attributes.actionName).toBe('new');
        expect(pageRef.state.defaultFieldValues).toBe(
            'Disposition__c=a0D5g000000DispEAG'
        );
    });

    it('ERROR BRANCH: shows an inline error (not the empty note) when the related-list wire errors', async () => {
        const element = createComponent();

        getRelatedListRecords.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.offer-row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.empty-msg')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.wire-error')
        ).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
