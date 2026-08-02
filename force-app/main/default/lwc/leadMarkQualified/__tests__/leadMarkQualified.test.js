/**
 * c-lead-mark-qualified — HEADLESS quick action (empty template).
 * ---------------------------------------------------------------
 * @api invoke() runs the shared pre-flight in c/leadStatusChange (permission check -> confirmation)
 * and only then writes the Lead Status via LDS updateRecord.
 *
 * The suite uses the REAL c/leadStatusChange util (does NOT mock it) so it can assert the actual
 * updateRecord call shape: updateRecord is pre-mocked as jest.fn().mockResolvedValue({}) in the
 * sfdx-lwc-jest lightning/uiRecordApi stub and asserted directly; the error path uses
 * mockRejectedValueOnce. lightning/confirm's real stub throws on .open() by design, so the module is
 * replaced with a jest.fn; the permission Apex is virtually mocked. Observable output is the
 * dispatched ShowToastEvent (headless = no DOM).
 */
import { createElement } from 'lwc';
import LeadMarkQualified from 'c/leadMarkQualified';
import { updateRecord } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import hasLeadActionAccess from '@salesforce/apex/LeadActionPermissionController.hasLeadActionAccess';

jest.mock('lightning/confirm', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

jest.mock(
    '@salesforce/apex/LeadActionPermissionController.hasLeadActionAccess',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = '00Q5g00000AbCdEEAV';
const TARGET = 'Qualified';
const NO_PERMISSION = "You don't have permission to perform this action.";

describe('c-lead-mark-qualified', () => {
    beforeEach(() => {
        hasLeadActionAccess.mockResolvedValue(true);
        LightningConfirm.open.mockResolvedValue(true);
    });

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

    it('CONFIRM: asks the qualify question before writing', async () => {
        const element = createComponent();

        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: 'Mark this lead as Qualified?',
            label: 'Mark Qualified',
            theme: 'info',
            variant: 'header'
        });
    });

    it('CANCELLED: a declined confirmation writes nothing and toasts nothing', async () => {
        LightningConfirm.open.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(updateRecord).not.toHaveBeenCalled();
        expect(toastHandler).not.toHaveBeenCalled();
    });

    it('NO PERMISSION: toasts the denial, never confirms, never writes', async () => {
        hasLeadActionAccess.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(updateRecord).not.toHaveBeenCalled();
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(NO_PERMISSION);
    });

    it('PERMISSION CHECK FAILS: fails closed — surfaces the real message and writes nothing', async () => {
        hasLeadActionAccess.mockRejectedValue({
            body: { message: 'Apex class access is not enabled.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(updateRecord).not.toHaveBeenCalled();
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Apex class access is not enabled.'
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
