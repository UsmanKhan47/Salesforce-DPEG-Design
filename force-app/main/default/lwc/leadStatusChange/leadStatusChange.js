import { updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';
import hasLeadActionAccess from '@salesforce/apex/LeadActionPermissionController.hasLeadActionAccess';

/**
 * leadStatusChange — shared helper for the headless Lead stage quick actions.
 *
 * This is a JS-only utility module (no template, isExposed=false), deliberately SEPARATE from
 * `c/utils`, which is contractually pure, stateless formatting only. All four Lead quick actions
 * (leadConvertAction / leadMarkUnderReview / leadMarkQualified / leadDisqualify) share the same
 * pre-flight sequence — permission check, then confirmation — and the three status actions are
 * additionally byte-identical bar the target Status they write, so both the guard and the LDS write
 * live here once.
 *
 * Why a status write needs no getRecordNotifyChange: `updateRecord` writes THROUGH the LDS cache,
 * so the Lead Path (pathAssistant) and highlights re-render reactively on their own — unlike the
 * imperative-Apex advanceDealStage bundle, which must call getRecordNotifyChange after its DML.
 *
 * ── WHY LightningConfirm AND NOT A TOAST ──────────────────────────────────────
 * A confirmation must be able to CANCEL the action, and `ShowToastEvent` is fire-and-forget — it
 * returns nothing, so it cannot carry a yes/no answer. `LightningConfirm.open()` returns a Promise
 * that resolves true/false and is the only supported confirmation dialog available to a HEADLESS
 * quick action (it renders into the platform's modal layer, not into the component's own — empty —
 * template). Toasts are still used here, for the success and error messages they are meant for.
 *
 * ── WHAT THE PERMISSION CHECK IS, AND IS NOT ──────────────────────────────────
 * `hasLeadActionAccess` is a UX gate: it stops the button doing anything and explains why. It is
 * NOT the security control. The three status buttons write via LDS `updateRecord`, so Apex is not
 * in their call path at all and CRUD/FLS on Lead.Status is the real enforcement — a user with Lead
 * edit rights can still change Status by inline edit, the Path, or the API. Convert is the one
 * action with real server-side enforcement (LeadConvertActionController asserts the same permission
 * before converting).
 */

const GENERIC_ERROR =
    'The lead status could not be updated. Please try again or contact your administrator.';

/** Shown when the running user lacks the Lead-action permission sets. */
export const NO_PERMISSION_MESSAGE =
    "You don't have permission to perform this action.";

/** Fallback confirmation prompt for a status change with no more specific wording. */
export const DEFAULT_CONFIRM_MESSAGE = 'Change lead status?';

/** Fallback dialog header. LightningConfirm requires a label when variant is 'header'. */
const DEFAULT_CONFIRM_LABEL = 'Confirm';

/**
 * Returns the first non-empty `message` string carried by an error entry, or a list of them.
 *
 * Accepts a single object or an array because the LDS error shape is not uniform: `output.errors`
 * is an array, each `output.fieldErrors` bucket is an array, and `body` itself is sometimes an
 * array. Anything that is not shaped like an error entry is skipped rather than thrown on.
 *
 * @param {*} entries an error entry, or an array of them
 * @returns {string|undefined} the first usable message, or undefined
 */
function firstMessage(entries) {
    if (!entries) {
        return undefined;
    }
    const list = Array.isArray(entries) ? entries : [entries];
    for (let i = 0; i < list.length; i++) {
        const entry = list[i];
        if (
            entry &&
            typeof entry.message === 'string' &&
            entry.message.trim() !== ''
        ) {
            return entry.message;
        }
    }
    return undefined;
}

/**
 * Extracts a user-safe message from an LDS/DML/Apex error, falling back to a fixed message so no
 * raw platform text or `undefined` ever leaks into the toast (ARCHITECTURE.md §5).
 *
 * ── WHY THIS READS body.output BEFORE body.message ────────────────────────────
 * When LDS `updateRecord` is refused by a VALIDATION RULE, the platform puts its own generic
 * "An error occurred while trying to update the record. Please try again." in `body.message` and
 * the RULE'S OWN TEXT in `body.output`:
 *
 *   body.output.errors     -> page-level errors: validation rules whose errorDisplayField is not
 *                             on the submitted field set, and Apex-thrown page errors.
 *   body.output.fieldErrors -> { <fieldApiName>: [ { message, ... } ] } — where a rule bound to a
 *                             specific field lands, and where a REQUIRED-field failure lands.
 *
 * Reading only `body.message` (the original implementation) therefore surfaced the generic text
 * and dropped the actionable one — the user was told "try again" for a problem that retrying can
 * never fix. Every Lead quick action shares this function, so the fix reaches all four.
 *
 * Ordering is deliberate: page-level first (a stage/status gate names the whole record's problem),
 * then the first field-level message, then `body.message`, then the caller's fallback.
 *
 * This runs on an error path and MUST NOT throw: every lookup is guarded and the whole walk is
 * wrapped, because an exception here would replace a bad message with no message at all.
 *
 * @param {*} error the error thrown by updateRecord or an imperative Apex call
 * @param {string} [fallback] message to use when the error carries no readable body
 * @returns {string} a user-safe message
 */
function messageFor(error, fallback) {
    try {
        const body = error && error.body;
        const bodies = Array.isArray(body) ? body : [body];

        // 1 + 2 — the rule's own text, wherever LDS chose to put it.
        for (let i = 0; i < bodies.length; i++) {
            const output = bodies[i] && bodies[i].output;
            if (!output || typeof output !== 'object') {
                continue;
            }

            const pageError = firstMessage(output.errors);
            if (pageError) {
                return pageError;
            }

            const fieldErrors = output.fieldErrors;
            if (fieldErrors && typeof fieldErrors === 'object') {
                const buckets = Array.isArray(fieldErrors)
                    ? fieldErrors
                    : Object.values(fieldErrors);
                for (let j = 0; j < buckets.length; j++) {
                    const fieldError = firstMessage(buckets[j]);
                    if (fieldError) {
                        return fieldError;
                    }
                }
            }
        }

        // 3 — the platform's summary line, or an Apex AuraHandledException message.
        for (let i = 0; i < bodies.length; i++) {
            const bodyMessage = firstMessage(bodies[i]);
            if (bodyMessage) {
                return bodyMessage;
            }
        }
    } catch (walkFailure) {
        // An unrecognised error shape must degrade to the fallback, never to a second exception.
    }
    return fallback || GENERIC_ERROR;
}

/**
 * Dispatches an error toast FROM the passed component (the toast must originate from a live element
 * on the DOM).
 *
 * @param {LightningElement} cmp the invoking quick-action component
 * @param {string} message the user-safe message to show
 */
export function showError(cmp, message) {
    cmp.dispatchEvent(
        new ShowToastEvent({ title: 'Error', message, variant: 'error' })
    );
}

/**
 * Dispatches a success toast FROM the passed component.
 *
 * @param {LightningElement} cmp the invoking quick-action component
 * @param {string} message the message to show
 */
export function showSuccess(cmp, message) {
    cmp.dispatchEvent(
        new ShowToastEvent({ title: 'Success', message, variant: 'success' })
    );
}

/**
 * Opens a modal confirmation dialog and resolves to the user's answer.
 *
 * A rejection from the modal itself is treated as "cancelled" rather than surfaced: the user has
 * not agreed to anything, so the only safe interpretation is not to proceed.
 *
 * @param {{message?: string, label?: string, theme?: string}} [options] dialog wording
 * @returns {Promise<boolean>} true only when the user explicitly confirmed
 */
export async function confirmAction(options) {
    const opts = options || {};
    try {
        const accepted = await LightningConfirm.open({
            message: opts.message || DEFAULT_CONFIRM_MESSAGE,
            label: opts.label || DEFAULT_CONFIRM_LABEL,
            theme: opts.theme || 'info',
            variant: 'header'
        });
        return accepted === true;
    } catch (error) {
        return false;
    }
}

/**
 * The shared pre-flight for every Lead quick action: check the running user's permission, then ask
 * them to confirm. The caller does its work only when this resolves `true`.
 *
 * Order matters — permission first. There is no point asking a user to confirm an action they are
 * not allowed to take, and doing so would imply the action was available.
 *
 * FAIL CLOSED: if the permission call rejects, the action is refused. The underlying message is
 * surfaced in that case rather than the permission wording, so a genuine system fault is not
 * disguised as a permissions problem.
 *
 * @param {LightningElement} cmp the invoking quick-action component (used to dispatch toasts)
 * @param {{message?: string, label?: string, theme?: string}} [options] confirmation dialog wording
 * @returns {Promise<boolean>} true when the user is permitted AND confirmed
 */
export async function guardLeadAction(cmp, options) {
    let allowed = false;
    try {
        allowed = (await hasLeadActionAccess()) === true;
    } catch (error) {
        showError(cmp, messageFor(error, NO_PERMISSION_MESSAGE));
        return false;
    }

    if (!allowed) {
        showError(cmp, NO_PERMISSION_MESSAGE);
        return false;
    }

    return confirmAction(options);
}

/**
 * Writes a new Lead Status via LDS updateRecord. On failure it dispatches an error ShowToastEvent
 * FROM the passed component and resolves `false`; on success it resolves `true` so the caller can
 * decide whether to show a success toast.
 *
 * This performs NO permission check or confirmation of its own — callers run `guardLeadAction`
 * first. Keeping the guard separate means the caller controls the wording of its own dialog.
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
        showError(cmp, messageFor(error, GENERIC_ERROR));
        return false;
    }
}
