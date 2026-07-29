/**
 * c-lead-mark-qualified — HEADLESS quick action (empty template).
 * ---------------------------------------------------------------
 * @api invoke() calls the REAL shared util c/leadStatusChange, which writes the Lead Status via LDS
 * updateRecord. The suite uses the real util (does NOT mock it) so it can assert the actual
 * updateRecord call shape: updateRecord is pre-mocked as jest.fn().mockResolvedValue({}) in the
 * sfdx-lwc-jest lightning/uiRecordApi stub and asserted directly; the error path uses
 * mockRejectedValueOnce. Observable output is the dispatched ShowToastEvent (headless = no DOM).
 */
import { createElement } from 'lwc';
import LeadMarkQualified from 'c/leadMarkQualified';
import { updateRecord } from 'lightning/uiRecordApi';

const RECORD_ID = '00Q5g00000AbCdEEAV';
const TARGET = 'Qualified';

describe('c-lead-mark-qualified', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-lead-mark-qualified', {
            is: LeadMarkQualified
        });
        element.recordId = RECORD_ID;
        document.body.appendChild(element);
        return element;
    }

    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS: invoke writes Status via LDS updateRecord and toasts success', async () => {
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(updateRecord).toHaveBeenCalledTimes(1);
        expect(updateRecord).toHaveBeenCalledWith({
            fields: { Status: TARGET, Id: RECORD_ID }
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.title).toBe('Success');
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            `Lead moved to ${TARGET}.`
        );
    });

    it('ERROR: surfaces the DML message as an error toast and does NOT toast success', async () => {
        updateRecord.mockRejectedValueOnce({
            body: { message: 'This field is required.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(updateRecord).toHaveBeenCalledWith({
            fields: { Status: TARGET, Id: RECORD_ID }
        });
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'This field is required.'
        );
    });

    it('ERROR FALLBACK: uses the generic status message when the error carries no body', async () => {
        updateRecord.mockRejectedValueOnce(new Error('network'));

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The lead status could not be updated. Please try again or contact your administrator.'
        );
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
