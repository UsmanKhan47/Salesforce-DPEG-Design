/**
 * c-loi-counter-offer — HYBRID suite.
 * -----------------------------------
 * The LOI counter-offer card records the full negotiation history. It works in
 * two placements:
 *   - On an Opportunity page: reads the Opp's Primary_LOI__c (+ the LOI's
 *     Ball_In_Court__c spanning field) via LDS getRecord, then tracks that LOI.
 *   - On an LOI record page: tracks the record directly (recordId is the LOI).
 * The history itself comes from an @wire Apex read (getCounterOffers), and a new
 * counter is committed through an imperative Apex write (saveCounterOffer).
 *
 * Combines THREE mocking techniques (mirrors c-broker-replace-quick-action):
 *   - LDS getRecord  -> sfdx-lwc-jest uiRecordApi stub, driven with .emit
 *     (Primary_LOI__c + the nested Primary_LOI__r.Ball_In_Court__c spanning field
 *     — getFieldValue traverses record.fields.Primary_LOI__r.value.fields...).
 *   - @wire Apex     -> getCounterOffers via createApexTestWireAdapter.emit/.error.
 *   - imperative Apex-> saveCounterOffer via jest.fn + mockResolvedValue/Rejected.
 *
 * notifyRecordUpdateAvailable (lightning/uiRecordApi) is a jest.fn in the stub and
 * is asserted. refreshApex (@salesforce/apex) is a plain resolved-promise fallback
 * in the transform — NOT a jest.fn — so it is exercised but never asserted on.
 */
import { createElement } from 'lwc';
import LoiCounterOffer from 'c/loiCounterOffer';
import { getRecord, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getCounterOffers from '@salesforce/apex/CounterOfferController.getCounterOffers';
import saveCounterOffer from '@salesforce/apex/CounterOfferController.saveCounterOffer';

jest.mock(
    '@salesforce/apex/CounterOfferController.getCounterOffers',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/CounterOfferController.saveCounterOffer',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const OPP_ID = '0065g00000AbCdEAAV';
const LOI_ID = 'a015g00000LoiXyAAK';

function oppRecord({ loiId = LOI_ID, ball } = {}) {
    return {
        apiName: 'Opportunity',
        id: OPP_ID,
        fields: {
            Primary_LOI__c: { value: loiId },
            Primary_LOI__r: ball
                ? { value: { fields: { Ball_In_Court__c: { value: ball } } } }
                : { value: null }
        }
    };
}

function offer(i, overrides = {}) {
    return {
        Id: `a025g0000000${i}AAA`,
        Name: `CO-${i}`,
        Direction__c: i % 2 === 0 ? 'Ours' : 'Seller',
        Counter_Price__c: 5000000 + i,
        Counter_Cap_Rate__c: 6.5,
        Counter_Response__c: `Response ${i}`,
        Revision_Number__c: `v${i}`,
        Subsequent_Version__c: null,
        Counter_Date__c: '2026-07-01',
        CreatedDate: '2026-07-01T00:00:00.000Z',
        ...overrides
    };
}

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-loi-counter-offer', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createOnOpportunity() {
        const element = createElement('c-loi-counter-offer', {
            is: LoiCounterOffer
        });
        Object.assign(element, {
            recordId: OPP_ID,
            objectApiName: 'Opportunity'
        });
        document.body.appendChild(element);
        return element;
    }

    function createOnLoiPage() {
        const element = createElement('c-loi-counter-offer', {
            is: LoiCounterOffer
        });
        Object.assign(element, {
            recordId: LOI_ID,
            objectApiName: 'LOI__c'
        });
        document.body.appendChild(element);
        return element;
    }

    it('NO PRIMARY LOI: prompts to set a Primary LOI and hides the Add button', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ loiId: null }));
        await Promise.resolve();

        const body = element.shadowRoot.textContent;
        expect(body).toContain('Set a Primary LOI');

        const addBtn = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === 'Add');
        expect(addBtn).toBeUndefined();
    });

    it('DATA BRANCH (Opportunity): renders the datatable, the count, and the ball badge', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ loiId: LOI_ID, ball: 'Us' }));
        getCounterOffers.emit([offer(1), offer(2)]);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-list-datatable')
        ).not.toBeNull();

        // Count is rendered in the card title slot.
        const title = element.shadowRoot.querySelector('[slot="title"]');
        expect(title.textContent).toContain('2');

        // Ball_In_Court__c = 'Us' -> warning-themed "our court" badge.
        const badge = element.shadowRoot.querySelector('.slds-badge');
        expect(badge).not.toBeNull();
        expect(badge.textContent).toContain('our court');
        expect(badge.className).toContain('slds-theme_warning');
    });

    it('DATA BRANCH (LOI page): tracks the record directly with no ball badge', async () => {
        const element = createOnLoiPage();

        // No getRecord emit needed — loiId is the record itself off the LOI page.
        getCounterOffers.emit([offer(1)]);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-list-datatable')
        ).not.toBeNull();
        // hasBall is Opportunity-only, so no badge on the LOI page.
        expect(element.shadowRoot.querySelector('.slds-badge')).toBeNull();
    });

    it('EMPTY BRANCH: shows the no-offers message when the Apex wire returns []', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ loiId: LOI_ID }));
        getCounterOffers.emit([]);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-list-datatable')
        ).toBeNull();
        expect(element.shadowRoot.textContent).toContain('No counter offers yet');
    });

    it('ERROR BRANCH: shows an inline error (not the empty note) when the Apex wire errors', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ loiId: LOI_ID }));
        getCounterOffers.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-list-datatable')
        ).toBeNull();
        expect(element.shadowRoot.textContent).toContain(
            'Counter offers could not be loaded'
        );
        expect(element.shadowRoot.textContent).not.toContain(
            'No counter offers yet'
        );
    });

    it('SAVE SUCCESS: submits the entered terms, refreshes the record, and toasts', async () => {
        saveCounterOffer.mockResolvedValue();

        const element = createOnOpportunity();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getRecord.emit(oppRecord({ loiId: LOI_ID }));
        await Promise.resolve();

        // Open the entry form.
        const addBtn = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === 'Add');
        addBtn.click();
        await Promise.resolve();

        // direction radio (e.detail.value) + the five inputs and the textarea
        // (all read via e.target.value in the component).
        element.shadowRoot
            .querySelector('lightning-radio-group')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Ours' } }));

        const inputs = element.shadowRoot.querySelectorAll('lightning-input');
        const setInput = (idx, value) => {
            inputs[idx].value = value;
            inputs[idx].dispatchEvent(new CustomEvent('change'));
        };
        setInput(0, '5000000'); // Counter Price
        setInput(1, '6.5'); // Cap Rate
        setInput(2, '2026-08-01'); // Counter Date
        setInput(3, 'v3'); // Revision Number
        setInput(4, 'v4'); // Subsequent Version

        const response = element.shadowRoot.querySelector('lightning-textarea');
        response.value = 'Seller pushed back on price.';
        response.dispatchEvent(new CustomEvent('change'));

        const saveBtn = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === 'Save');
        saveBtn.click();
        await flushPromises();

        expect(saveCounterOffer).toHaveBeenCalledTimes(1);
        expect(saveCounterOffer).toHaveBeenCalledWith({
            loiId: LOI_ID,
            direction: 'Ours',
            counterPrice: '5000000',
            counterCapRate: '6.5',
            counterDate: '2026-08-01',
            counterResponse: 'Seller pushed back on price.',
            revisionNumber: 'v3',
            subsequentVersion: 'v4'
        });

        // Refreshes the host Opportunity so the LOI tab's spanning fields update.
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
            { recordId: OPP_ID }
        ]);
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Counter offer added'
        );
    });

    it('SAVE ERROR: surfaces the Apex error, keeps the form open, and does not refresh', async () => {
        saveCounterOffer.mockRejectedValue({
            body: { message: 'Counter price is required.' }
        });

        const element = createOnOpportunity();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getRecord.emit(oppRecord({ loiId: LOI_ID }));
        await Promise.resolve();

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((b) => b.label === 'Add')
            .click();
        await Promise.resolve();

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((b) => b.label === 'Save')
            .click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Counter price is required.'
        );
        expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();

        // Editing state is retained on failure — the Save button is still present.
        expect(
            [...element.shadowRoot.querySelectorAll('lightning-button')].some(
                (b) => b.label === 'Save'
            )
        ).toBe(true);
    });

    it('is accessible', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ loiId: LOI_ID }));
        getCounterOffers.emit([]);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
