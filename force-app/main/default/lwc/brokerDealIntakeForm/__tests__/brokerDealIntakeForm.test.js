/**
 * c-broker-deal-intake-form — HYBRID suite (@wire metadata + IMPERATIVE submit).
 * Combines two templates:
 *   - brokerFirmCard: @wire(getFormMetadata) via createApexTestWireAdapter.emit
 *   - submitForApproval: imperative submitDeal() via jest.fn + resolve/reject.
 *
 * The public guest form loads its asset-type options from getFormMetadata, then
 * POSTs the captured fields through submitDeal. On success it swaps to a
 * confirmation panel; a business failure ({success:false}) or a thrown Apex error
 * surfaces an inline error message.
 *
 * Note: the sfdx-lwc-jest lightning-input/combobox stubs' reportValidity()
 * returns undefined (falsy), so the submit tests shadow it with a truthy stub to
 * clear the component's client-side validate() gate.
 */
import { createElement } from 'lwc';
import BrokerDealIntakeForm from 'c/brokerDealIntakeForm';
import getFormMetadata from '@salesforce/apex/BrokerPortalController.getFormMetadata';
import submitDeal from '@salesforce/apex/BrokerPortalController.submitDeal';

jest.mock(
    '@salesforce/apex/BrokerPortalController.getFormMetadata',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/BrokerPortalController.submitDeal',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const METADATA = {
    assetTypes: [
        { label: 'Office', value: 'Office' },
        { label: 'Retail', value: 'Retail' },
        { label: 'Industrial', value: 'Industrial' }
    ]
};

const FORM_VALUES = {
    firstName: 'Ava',
    lastName: 'Broker',
    brokerageFirm: 'CBRE',
    email: 'ava@cbre.com',
    propertyAddress: '123 Main St, Sugar Land TX',
    assetType: 'Office'
};

// Flush the microtask + macrotask queue so an awaited Apex promise, its .then/
// .catch chain, and the follow-up re-render all settle before asserting.
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-broker-deal-intake-form', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-deal-intake-form', {
            is: BrokerDealIntakeForm
        });
        document.body.appendChild(element);
        return element;
    }

    // Populate every field the component reads and clear the validity gate.
    function fillForm(element, values = FORM_VALUES) {
        element.shadowRoot
            .querySelectorAll('.validate')
            .forEach((el) => {
                el.reportValidity = () => true;
            });
        Object.entries(values).forEach(([field, val]) => {
            const el = element.shadowRoot.querySelector(
                `[data-field="${field}"]`
            );
            el.value = val;
            el.dispatchEvent(new CustomEvent('change'));
        });
    }

    function clickSubmit(element) {
        element.shadowRoot.querySelector('lightning-button').click();
    }

    it('WIRE BRANCH: populates the asset-type combobox from getFormMetadata', async () => {
        const element = createComponent();

        getFormMetadata.emit(METADATA);
        await Promise.resolve();

        const combobox = element.shadowRoot.querySelector(
            '[data-field="assetType"]'
        );
        expect(combobox.options).toEqual([
            { label: 'Office', value: 'Office' },
            { label: 'Retail', value: 'Retail' },
            { label: 'Industrial', value: 'Industrial' }
        ]);
    });

    it('WIRE ERROR BRANCH: shows a load error when getFormMetadata errors', async () => {
        const element = createComponent();

        getFormMetadata.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.form__error').textContent
        ).toBe('Could not load the form. Please refresh and try again.');
    });

    it('SUCCESS BRANCH: submits captured fields and shows the confirmation panel', async () => {
        submitDeal.mockResolvedValue({ success: true });

        const element = createComponent();
        getFormMetadata.emit(METADATA);
        await Promise.resolve();

        fillForm(element);
        clickSubmit(element);
        await flushPromises();

        expect(submitDeal).toHaveBeenCalledTimes(1);
        const passedInput = submitDeal.mock.calls[0][0].input;
        expect(passedInput.firstName).toBe('Ava');
        expect(passedInput.lastName).toBe('Broker');
        expect(passedInput.brokerageFirm).toBe('CBRE');
        expect(passedInput.email).toBe('ava@cbre.com');
        expect(passedInput.propertyAddress).toBe(
            '123 Main St, Sugar Land TX'
        );
        expect(passedInput.assetType).toBe('Office');

        // Confirmation panel replaces the form.
        expect(element.shadowRoot.querySelector('.confirmation')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.form')).toBeNull();
    });

    it('BUSINESS-FAILURE BRANCH: shows the returned message when success is false', async () => {
        submitDeal.mockResolvedValue({
            success: false,
            message: 'A deal with this address was already submitted.'
        });

        const element = createComponent();
        getFormMetadata.emit(METADATA);
        await Promise.resolve();

        fillForm(element);
        clickSubmit(element);
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.form__error').textContent
        ).toBe('A deal with this address was already submitted.');
        // Stays on the form (no confirmation).
        expect(element.shadowRoot.querySelector('.confirmation')).toBeNull();
    });

    it('THROWN-ERROR BRANCH: surfaces the Apex error body message', async () => {
        submitDeal.mockRejectedValue({
            body: { message: 'Portal is temporarily unavailable.' }
        });

        const element = createComponent();
        getFormMetadata.emit(METADATA);
        await Promise.resolve();

        fillForm(element);
        clickSubmit(element);
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.form__error').textContent
        ).toBe('Portal is temporarily unavailable.');
    });

    it('does NOT call Apex when client-side validation fails', async () => {
        const element = createComponent();
        getFormMetadata.emit(METADATA);
        await Promise.resolve();

        // reportValidity stays falsy (stub default) -> validate() returns false.
        clickSubmit(element);
        await flushPromises();

        expect(submitDeal).not.toHaveBeenCalled();
    });

    it('RESET: returns to a blank form after a successful submission', async () => {
        submitDeal.mockResolvedValue({ success: true });

        const element = createComponent();
        getFormMetadata.emit(METADATA);
        await Promise.resolve();

        fillForm(element);
        clickSubmit(element);
        await flushPromises();

        // "Submit another deal" lives in the confirmation panel.
        element.shadowRoot
            .querySelector('.confirmation lightning-button')
            .click();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.form')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.confirmation')).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();
        getFormMetadata.emit(METADATA);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
