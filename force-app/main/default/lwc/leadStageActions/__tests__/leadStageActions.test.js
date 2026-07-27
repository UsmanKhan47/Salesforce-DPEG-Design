/**
 * c-lead-stage-actions — LDS getRecord + LDS updateRecord + imperative Apex + NavigationMixin.
 *
 * Mock conventions mirror the repo's established suites:
 *   - LDS getRecord   -> sfdx-lwc-jest uiRecordApi stub, driven with .emit (no jest.mock needed;
 *                        getFieldValue is real). Fixture is UI-API shaped with the REAL field name.
 *   - LDS updateRecord-> pre-mocked jest.fn().mockResolvedValue({}) in the same stub; asserted
 *                        directly and given mockRejectedValueOnce for the error path.
 *   - imperative Apex -> convertLead via jest.fn + mockResolvedValue/Rejected ({ virtual: true }).
 *   - lightning/navigation -> module-mocked so [Navigate] dispatches a catchable 'navigate' event
 *     carrying the pageReference (matches c-recent-leads; an instance spy cannot capture it).
 *
 * sa11y's setup() runs globally via jest.setup.js — no per-file setup() here (only the assertion).
 */
import { createElement } from 'lwc';
import LeadStageActions from 'c/leadStageActions';
import { getRecord, updateRecord } from 'lightning/uiRecordApi';
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

// UI-API shaped record with the REAL field API name; getFieldValue reads fields.Status.value.
function leadRecord(status) {
    return {
        apiName: 'Lead',
        id: LEAD_ID,
        fields: { Status: { value: status } }
    };
}

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function labelsOf(element) {
    return [...element.shadowRoot.querySelectorAll('lightning-button')].map(
        (button) => button.label
    );
}

function buttonByLabel(element, label) {
    return [...element.shadowRoot.querySelectorAll('lightning-button')].find(
        (button) => button.label === label
    );
}

describe('c-lead-stage-actions', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-lead-stage-actions', {
            is: LeadStageActions
        });
        element.recordId = LEAD_ID;
        document.body.appendChild(element);
        return element;
    }

    it('NEW: renders exactly [Under Review] [Disqualified]', async () => {
        const element = createComponent();

        getRecord.emit(leadRecord('New'));
        await Promise.resolve();

        expect(labelsOf(element)).toEqual(['Under Review', 'Disqualified']);
    });

    it('UNDER REVIEW: renders exactly [Qualified] [Disqualified]', async () => {
        const element = createComponent();

        getRecord.emit(leadRecord('Under Review'));
        await Promise.resolve();

        expect(labelsOf(element)).toEqual(['Qualified', 'Disqualified']);
    });

    it('QUALIFIED: renders exactly [Convert] [Disqualified]', async () => {
        const element = createComponent();

        getRecord.emit(leadRecord('Qualified'));
        await Promise.resolve();

        expect(labelsOf(element)).toEqual(['Convert', 'Disqualified']);
    });

    it('DISQUALIFIED: renders no buttons (terminal)', async () => {
        const element = createComponent();

        getRecord.emit(leadRecord('Disqualified'));
        await Promise.resolve();

        expect(labelsOf(element)).toEqual([]);
    });

    it('CONVERTED: renders no buttons (terminal)', async () => {
        const element = createComponent();

        getRecord.emit(leadRecord('Converted'));
        await Promise.resolve();

        expect(labelsOf(element)).toEqual([]);
    });

    it('STATUS BUTTON: clicking Under Review writes Status via LDS updateRecord (no Apex)', async () => {
        const element = createComponent();

        getRecord.emit(leadRecord('New'));
        await Promise.resolve();

        buttonByLabel(element, 'Under Review').click();
        await flushPromises();

        expect(updateRecord).toHaveBeenCalledTimes(1);
        expect(updateRecord).toHaveBeenCalledWith({
            fields: { Id: LEAD_ID, Status: 'Under Review' }
        });
        // Status-only path must not touch the conversion Apex.
        expect(convertLead).not.toHaveBeenCalled();
    });

    it('CONVERT: calls convertLead then navigates to the new Opportunity', async () => {
        convertLead.mockResolvedValue(OPP_ID);

        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getRecord.emit(leadRecord('Qualified'));
        await Promise.resolve();

        buttonByLabel(element, 'Convert').click();
        await flushPromises();

        expect(convertLead).toHaveBeenCalledTimes(1);
        expect(convertLead).toHaveBeenCalledWith({ leadId: LEAD_ID });

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__recordPage');
        expect(pageRef.attributes.recordId).toBe(OPP_ID);
        expect(pageRef.attributes.objectApiName).toBe('Opportunity');
        expect(pageRef.attributes.actionName).toBe('view');

        // Convert is not a status write.
        expect(updateRecord).not.toHaveBeenCalled();
    });

    it('CONVERT ERROR: surfaces the AuraHandledException message as an error toast and does not navigate', async () => {
        convertLead.mockRejectedValue({
            body: { message: 'You do not have permission to convert leads.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getRecord.emit(leadRecord('Qualified'));
        await Promise.resolve();

        buttonByLabel(element, 'Convert').click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'You do not have permission to convert leads.'
        );
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('STATUS ERROR: surfaces an error toast when updateRecord rejects', async () => {
        updateRecord.mockRejectedValueOnce({
            body: { message: 'This field is required.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getRecord.emit(leadRecord('New'));
        await Promise.resolve();

        buttonByLabel(element, 'Disqualified').click();
        await flushPromises();

        expect(updateRecord).toHaveBeenCalledWith({
            fields: { Id: LEAD_ID, Status: 'Disqualified' }
        });
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'This field is required.'
        );
    });

    it('WIRE ERROR: emits an error toast and clears the stage buttons', async () => {
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        // First render a valid stage so we can prove the error branch actively clears it.
        getRecord.emit(leadRecord('New'));
        await Promise.resolve();
        expect(labelsOf(element)).toEqual(['Under Review', 'Disqualified']);

        // getRecord.error(body) re-emits { data: undefined, error }. The wire handler sets
        // status = undefined (no valid transitions -> no buttons) and shows an error toast.
        getRecord.error({ message: 'Lead could not be loaded.' });
        await Promise.resolve();

        expect(labelsOf(element)).toEqual([]);
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Lead could not be loaded.'
        );
    });

    it('BUSY GUARD: double-clicking Convert before it resolves calls convertLead only once', async () => {
        // A promise we hold open keeps busy = true across both clicks in the same tick, so the
        // second click hits the in-flight guard before the first conversion resolves.
        let resolveConvert;
        convertLead.mockImplementation(
            () =>
                new Promise((resolve) => {
                    resolveConvert = resolve;
                })
        );

        const element = createComponent();
        getRecord.emit(leadRecord('Qualified'));
        await Promise.resolve();

        const convertButton = buttonByLabel(element, 'Convert');
        convertButton.click();
        convertButton.click();
        await flushPromises();

        // The transient busy guard blocks the second click — only one conversion is attempted.
        expect(convertLead).toHaveBeenCalledTimes(1);

        // Let the held-open conversion settle so no pending promise leaks into the next test.
        resolveConvert(OPP_ID);
        await flushPromises();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecord.emit(leadRecord('New'));
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
