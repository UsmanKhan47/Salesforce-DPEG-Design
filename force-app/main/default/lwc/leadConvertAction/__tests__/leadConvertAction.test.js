/**
 * c-lead-convert-action — HEADLESS quick action (empty template), IMPERATIVE APEX + NavigationMixin.
 * --------------------------------------------------------------------------------------------------
 * @api invoke() awaits the EXISTING, unchanged controller:
 *   const opportunityId = await convertLead({ leadId: this.recordId });
 * then navigates to the new Opportunity. On failure it toasts the AuraHandledException message.
 *
 * Mock conventions mirror c-lead-stage-actions:
 *   - imperative Apex convertLead -> jest.fn via { virtual: true } mock, driven with
 *     mockResolvedValue / mockRejectedValue.
 *   - lightning/navigation -> module-mocked so [Navigate] dispatches a catchable 'navigate' event
 *     carrying the pageReference (an instance spy cannot capture it).
 * Observable output is the dispatched 'navigate' / ShowToastEvent (headless = no DOM).
 */
import { createElement } from 'lwc';
import LeadConvertAction from 'c/leadConvertAction';
import convertLead from '@salesforce/apex/LeadConvertActionController.convertLead';

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
                    return Promise.resolve('/url');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/LeadConvertActionController.convertLead',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const LEAD_ID = '00Q5g00000AbCdEEAV';
const OPP_ID = '0065g00000XyZaBAAV';

describe('c-lead-convert-action', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-lead-convert-action', {
            is: LeadConvertAction
        });
        element.recordId = LEAD_ID;
        document.body.appendChild(element);
        return element;
    }

    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS: calls convertLead then navigates to the new Opportunity', async () => {
        convertLead.mockResolvedValue(OPP_ID);

        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        await element.invoke();
        await flushPromises();

        expect(convertLead).toHaveBeenCalledTimes(1);
        expect(convertLead).toHaveBeenCalledWith({ leadId: LEAD_ID });

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__recordPage');
        expect(pageRef.attributes.recordId).toBe(OPP_ID);
        expect(pageRef.attributes.objectApiName).toBe('Opportunity');
        expect(pageRef.attributes.actionName).toBe('view');
    });

    it('ERROR: surfaces the AuraHandledException message as an error toast and does not navigate', async () => {
        convertLead.mockRejectedValue({
            body: { message: 'You do not have permission to convert leads.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Cannot convert the lead'
        );
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'You do not have permission to convert leads.'
        );
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('ERROR FALLBACK: uses the generic convert message when the error carries no body', async () => {
        convertLead.mockRejectedValue(new Error('network'));

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Unable to convert this lead.'
        );
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('is accessible', async () => {
        convertLead.mockResolvedValue(OPP_ID);

        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
