/**
 * c/leadStatusChange — shared JS-only util (no template, isExposed=false), unit-tested directly.
 * ---------------------------------------------------------------------------------------------
 * changeLeadStatus(cmp, recordId, statusValue) writes the Lead Status via LDS updateRecord and, on
 * failure, dispatches an error ShowToastEvent FROM the passed component. updateRecord is pre-mocked
 * as jest.fn().mockResolvedValue({}) in the sfdx-lwc-jest lightning/uiRecordApi stub; the error path
 * is driven with mockRejectedValueOnce. The "component" is a lightweight stub carrying only
 * dispatchEvent, so the util can be exercised without rendering an element (it renders no markup ->
 * no toBeAccessible() assertion here, unlike the four headless action bundles).
 */
import { changeLeadStatus } from 'c/leadStatusChange';
import { updateRecord } from 'lightning/uiRecordApi';

const RECORD_ID = '00Q5g00000AbCdEEAV';
const TARGET = 'Under Review';

function fakeComponent() {
    return { dispatchEvent: jest.fn() };
}

describe('c/leadStatusChange changeLeadStatus', () => {
    afterEach(() => {
        jest.clearAllMocks();
    });

    it('SUCCESS: calls updateRecord with the Status/Id fields, returns true, fires no toast', async () => {
        const cmp = fakeComponent();

        const result = await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(result).toBe(true);
        expect(updateRecord).toHaveBeenCalledTimes(1);
        expect(updateRecord).toHaveBeenCalledWith({
            fields: { Status: TARGET, Id: RECORD_ID }
        });
        // Success is silent at the util layer — the caller owns the success toast.
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });

    it('ERROR: dispatches an error toast from the component with the DML message, returns false', async () => {
        updateRecord.mockRejectedValueOnce({
            body: { message: 'This field is required.' }
        });
        const cmp = fakeComponent();

        const result = await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(result).toBe(false);
        expect(cmp.dispatchEvent).toHaveBeenCalledTimes(1);
        const toast = cmp.dispatchEvent.mock.calls[0][0];
        expect(toast.detail.variant).toBe('error');
        expect(toast.detail.title).toBe('Error');
        expect(toast.detail.message).toBe('This field is required.');
    });

    it('ERROR FALLBACK: uses the generic message when the error carries no body', async () => {
        updateRecord.mockRejectedValueOnce(new Error('network'));
        const cmp = fakeComponent();

        const result = await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(result).toBe(false);
        expect(cmp.dispatchEvent).toHaveBeenCalledTimes(1);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            'The lead status could not be updated. Please try again or contact your administrator.'
        );
    });
});
