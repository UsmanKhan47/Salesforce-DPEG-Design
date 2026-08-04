/**
 * c/leadStatusChange — shared JS-only util (no template, isExposed=false), unit-tested directly.
 * ---------------------------------------------------------------------------------------------
 * Three exported concerns are covered here:
 *   - changeLeadStatus(cmp, recordId, statusValue): writes Lead Status via LDS updateRecord and, on
 *     failure, dispatches an error ShowToastEvent FROM the passed component. updateRecord is
 *     pre-mocked as jest.fn().mockResolvedValue({}) in the sfdx-lwc-jest lightning/uiRecordApi stub;
 *     the error path is driven with mockRejectedValueOnce.
 *   - guardLeadAction(cmp, options): the shared pre-flight — permission check THEN confirmation.
 *   - confirmAction / showError / showSuccess: the primitives the four action bundles reuse.
 *
 * lightning/confirm's real stub throws on .open() by design ("the LightningConfirm documentation
 * contains examples for mocking .open in Jest"), so the module is replaced with a plain object
 * exposing a jest.fn open(). The permission Apex is virtually mocked like any imperative call.
 *
 * The "component" is a lightweight stub carrying only dispatchEvent, so the util can be exercised
 * without rendering an element (it renders no markup -> no toBeAccessible() assertion here, unlike
 * the four headless action bundles).
 */
import {
    changeLeadStatus,
    confirmAction,
    guardLeadAction,
    showError,
    showSuccess,
    NO_PERMISSION_MESSAGE,
    DEFAULT_CONFIRM_MESSAGE
} from 'c/leadStatusChange';
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
const TARGET = 'Under Review';

function fakeComponent() {
    return { dispatchEvent: jest.fn() };
}

describe('c/leadStatusChange', () => {
    beforeEach(() => {
        // Default happy state: permitted and confirmed.
        hasLeadActionAccess.mockResolvedValue(true);
        LightningConfirm.open.mockResolvedValue(true);
    });

    afterEach(() => {
        jest.clearAllMocks();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // changeLeadStatus
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // messageFor() — the body.output shapes an LDS validation-rule failure uses.
    //
    // When updateRecord is refused by a VALIDATION RULE, LDS puts its own generic line in
    // body.message and the RULE'S OWN TEXT in body.output. Reading only body.message (the
    // original implementation) told the user to "try again" for a problem retrying cannot fix,
    // which would have made the Lead half of the stage-gate feature indistinguishable from a bug.
    // ─────────────────────────────────────────────────────────────────────────

    const LDS_GENERIC =
        'An error occurred while trying to update the record. Please try again.';
    const RULE_TEXT =
        'Property Address and Email are both required before this lead can move forward. ' +
        'Fill them in on the lead first.';

    it('VALIDATION RULE: surfaces body.output.errors[0].message, not the LDS generic line', async () => {
        // The exact shape LDS returns when a page-level validation rule blocks updateRecord.
        updateRecord.mockRejectedValueOnce({
            body: {
                message: LDS_GENERIC,
                output: {
                    errors: [
                        {
                            constituentField: null,
                            duplicateRecordError: null,
                            errorCode: 'FIELD_CUSTOM_VALIDATION_EXCEPTION',
                            field: 'Status',
                            fieldLabel: 'Lead Status',
                            message: RULE_TEXT
                        }
                    ],
                    fieldErrors: {}
                }
            }
        });
        const cmp = fakeComponent();

        const result = await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(result).toBe(false);
        expect(cmp.dispatchEvent).toHaveBeenCalledTimes(1);
        const toast = cmp.dispatchEvent.mock.calls[0][0];
        expect(toast.detail.variant).toBe('error');
        // The whole point: the rule's own wording reaches the user.
        expect(toast.detail.message).toBe(RULE_TEXT);
        expect(toast.detail.message).not.toBe(LDS_GENERIC);
    });

    it('FIELD ERROR: surfaces the first body.output.fieldErrors message when there is no page error', async () => {
        // Where a REQUIRED-field failure lands, and where a rule bound to a submitted field lands.
        updateRecord.mockRejectedValueOnce({
            body: {
                message: LDS_GENERIC,
                output: {
                    errors: [],
                    fieldErrors: {
                        Status: [
                            {
                                constituentField: null,
                                errorCode: 'FIELD_CUSTOM_VALIDATION_EXCEPTION',
                                field: 'Status',
                                fieldLabel: 'Lead Status',
                                message: RULE_TEXT
                            }
                        ]
                    }
                }
            }
        });
        const cmp = fakeComponent();

        await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(RULE_TEXT);
    });

    it('PRIORITY: a page-level error wins over a field-level one, and both win over body.message', async () => {
        updateRecord.mockRejectedValueOnce({
            body: {
                message: LDS_GENERIC,
                output: {
                    errors: [{ message: 'page level' }],
                    fieldErrors: { Status: [{ message: 'field level' }] }
                }
            }
        });
        const cmp = fakeComponent();

        await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            'page level'
        );
    });

    it('UNCHANGED BEHAVIOUR: an empty output still falls through to body.message', async () => {
        // Every error shape that worked before must keep working — output is present but carries
        // nothing, which is what a plain DML/Apex failure looks like through LDS.
        updateRecord.mockRejectedValueOnce({
            body: {
                message: 'This field is required.',
                output: { errors: [], fieldErrors: {} }
            }
        });
        const cmp = fakeComponent();

        await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            'This field is required.'
        );
    });

    it('ARRAY BODY: reads output out of an array-shaped error body', async () => {
        // Some LDS/wire error payloads arrive as an array of bodies rather than one object.
        updateRecord.mockRejectedValueOnce({
            body: [{ message: LDS_GENERIC, output: { errors: [{ message: RULE_TEXT }] } }]
        });
        const cmp = fakeComponent();

        await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(RULE_TEXT);
    });

    it('TWO-PASS: an earlier body.message must not win over a later body.output.errors message', async () => {
        // Every body is searched for output text BEFORE any body.message is accepted (two
        // separate loops over `bodies`), not "check output-then-message per body, in one pass".
        // The pre-existing ARRAY BODY test above cannot discriminate this: its single-element
        // array carries both keys on the SAME body, so a naive single-loop rewrite (check output,
        // fall back to message, per body, in one loop) would return the identical result. Here the
        // two keys are split across DIFFERENT array elements, with the message-only body FIRST:
        // a single-pass implementation would accept body[0].message before ever reaching
        // body[1].output, and return the generic LDS line instead of the rule's own text.
        updateRecord.mockRejectedValueOnce({
            body: [
                { message: LDS_GENERIC },
                { output: { errors: [{ message: RULE_TEXT }] } }
            ]
        });
        const cmp = fakeComponent();

        await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(RULE_TEXT);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).not.toBe(LDS_GENERIC);
    });

    it('NEVER THROWS: a malformed output degrades to the generic message', async () => {
        // messageFor runs on the error path, so a shape it does not recognise must produce the
        // fallback — not a second exception that would leave the user with no toast at all.
        updateRecord.mockRejectedValueOnce({
            body: { output: { errors: 'not-an-array', fieldErrors: 7 } }
        });
        const cmp = fakeComponent();

        const result = await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(result).toBe(false);
        expect(cmp.dispatchEvent).toHaveBeenCalledTimes(1);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            'The lead status could not be updated. Please try again or contact your administrator.'
        );
    });

    it('guardLeadAction also gets the body.output treatment (Apex page-level errors)', async () => {
        hasLeadActionAccess.mockRejectedValue({
            body: {
                message: LDS_GENERIC,
                output: { errors: [{ message: 'Apex class access is not enabled.' }] }
            }
        });
        const cmp = fakeComponent();

        const proceed = await guardLeadAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(false);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            'Apex class access is not enabled.'
        );
    });

    it('changeLeadStatus performs NO permission check of its own (the caller guards)', async () => {
        const cmp = fakeComponent();

        await changeLeadStatus(cmp, RECORD_ID, TARGET);

        expect(hasLeadActionAccess).not.toHaveBeenCalled();
        expect(LightningConfirm.open).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // toast primitives
    // ─────────────────────────────────────────────────────────────────────────

    it('showError / showSuccess dispatch the right toast variants from the component', () => {
        const cmp = fakeComponent();

        showError(cmp, 'boom');
        showSuccess(cmp, 'yay');

        expect(cmp.dispatchEvent).toHaveBeenCalledTimes(2);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail).toEqual(
            expect.objectContaining({
                title: 'Error',
                message: 'boom',
                variant: 'error'
            })
        );
        expect(cmp.dispatchEvent.mock.calls[1][0].detail).toEqual(
            expect.objectContaining({
                title: 'Success',
                message: 'yay',
                variant: 'success'
            })
        );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // confirmAction
    // ─────────────────────────────────────────────────────────────────────────

    it('confirmAction opens a header-variant dialog with the supplied wording and returns the answer', async () => {
        const accepted = await confirmAction({
            message: 'Really?',
            label: 'Do It',
            theme: 'warning'
        });

        expect(accepted).toBe(true);
        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: 'Really?',
            label: 'Do It',
            theme: 'warning',
            variant: 'header'
        });
    });

    it('confirmAction falls back to the default wording when no options are supplied', async () => {
        await confirmAction();

        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: DEFAULT_CONFIRM_MESSAGE,
            label: 'Confirm',
            theme: 'info',
            variant: 'header'
        });
    });

    it('confirmAction returns false when the user cancels', async () => {
        LightningConfirm.open.mockResolvedValueOnce(false);

        await expect(confirmAction({ message: 'x' })).resolves.toBe(false);
    });

    it('confirmAction treats a modal failure as "cancelled" rather than as consent', async () => {
        LightningConfirm.open.mockRejectedValueOnce(new Error('modal blew up'));

        await expect(confirmAction({ message: 'x' })).resolves.toBe(false);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // guardLeadAction — the shared pre-flight
    // ─────────────────────────────────────────────────────────────────────────

    it('guardLeadAction returns true and fires no toast when permitted and confirmed', async () => {
        const cmp = fakeComponent();

        const proceed = await guardLeadAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(true);
        expect(hasLeadActionAccess).toHaveBeenCalledTimes(1);
        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });

    it('guardLeadAction DENIES without confirming when the user lacks permission', async () => {
        hasLeadActionAccess.mockResolvedValue(false);
        const cmp = fakeComponent();

        const proceed = await guardLeadAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(false);
        // Permission is checked FIRST — an unauthorized user is never asked to confirm.
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(cmp.dispatchEvent).toHaveBeenCalledTimes(1);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            NO_PERMISSION_MESSAGE
        );
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.variant).toBe('error');
    });

    it('guardLeadAction FAILS CLOSED and surfaces the real message when the check throws', async () => {
        hasLeadActionAccess.mockRejectedValue({
            body: { message: 'Apex class access is not enabled.' }
        });
        const cmp = fakeComponent();

        const proceed = await guardLeadAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(false);
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            'Apex class access is not enabled.'
        );
    });

    it('guardLeadAction falls back to the permission message when the thrown check has no body', async () => {
        hasLeadActionAccess.mockRejectedValue(new Error('network'));
        const cmp = fakeComponent();

        await guardLeadAction(cmp, { message: 'Sure?' });

        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            NO_PERMISSION_MESSAGE
        );
    });

    it('guardLeadAction returns false silently when the user cancels the confirmation', async () => {
        LightningConfirm.open.mockResolvedValue(false);
        const cmp = fakeComponent();

        const proceed = await guardLeadAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(false);
        // Cancelling is not an error — the user already knows what they did.
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });

    it('guardLeadAction treats a non-boolean permission answer as DENIED', async () => {
        // An un-mocked/short-circuited Apex call resolves undefined; that must never read as a grant.
        hasLeadActionAccess.mockResolvedValue(undefined);
        const cmp = fakeComponent();

        const proceed = await guardLeadAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(false);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            NO_PERMISSION_MESSAGE
        );
    });
});
