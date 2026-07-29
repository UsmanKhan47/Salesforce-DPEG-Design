import { updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';

/**
 * leadStatusChange — shared helper for the headless Lead stage quick actions.
 *
 * This is a JS-only utility module (no template, isExposed=false), deliberately SEPARATE from
 * `c/utils`, which is contractually pure, stateless formatting only. The three status quick actions
 * (leadMarkUnderReview / leadMarkQualified / leadDisqualify) are byte-identical bar the target
 * Status they write, so the LDS write + error-toast normalization lives here once.
 *
 * Why a status write needs no getRecordNotifyChange: `updateRecord` writes THROUGH the LDS cache,
 * so the Lead Path (pathAssistant) and highlights re-render reactively on their own — unlike the
 * imperative-Apex advanceDealStage bundle, which must call getRecordNotifyChange after its DML.
 */

const GENERIC_ERROR =
    'The lead status could not be updated. Please try again or contact your administrator.';

/**
 * Extracts a user-safe message from an LDS/DML error, falling back to a fixed generic message so no
 * raw platform text or `undefined` ever leaks into the toast (ARCHITECTURE.md §5).
 *
 * @param {*} error the error thrown by updateRecord
 * @returns {string} a user-safe message
 */
function messageFor(error) {
    return (error && error.body && error.body.message) || GENERIC_ERROR;
}

/**
 * Writes a new Lead Status via LDS updateRecord. On failure it dispatches an error ShowToastEvent
 * FROM the passed component (the toast must originate from a live element on the DOM) and resolves
 * `false`; on success it resolves `true` so the caller can decide whether to show a success toast.
 *
 * @param {LightningElement} cmp the invoking headless quick-action component (used to dispatch the toast)
 * @param {string} recordId the Lead Id to update
 * @param {string} statusValue the target Lead Status picklist value (e.g. 'Under Review')
 * @returns {Promise<boolean>} true if the update succeeded, false if it failed (toast already fired)
 */
export async function changeLeadStatus(cmp, recordId, statusValue) {
    try {
        await updateRecord({
            fields: { [STATUS_FIELD.fieldApiName]: statusValue, Id: recordId }
        });
        return true;
    } catch (error) {
        cmp.dispatchEvent(
            new ShowToastEvent({
                title: 'Error',
                message: messageFor(error),
                variant: 'error'
            })
        );
        return false;
    }
}
