import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import hasDealActionAccess from '@salesforce/apex/OpportunityActionPermissionController.hasDealActionAccess';

/**
 * dealActionGuard — shared pre-flight for the headless Opportunity stage quick actions.
 *
 * A JS-only utility module (no template, isExposed=false), deliberately SEPARATE from `c/utils`,
 * which is contractually pure, stateless formatting only. All five Opportunity quick-action bundles
 * (advanceDealStage, dealSendToDevelopmentReview, dealSendToConstructionReview,
 * dealMoveToAboutToClose, submitForApproval) share the same pre-flight — permission check, then
 * confirmation — so it lives here once.
 *
 * ── WHY THIS IS NOT c/leadStatusChange ────────────────────────────────────────
 * The Lead feature's `c/leadStatusChange` implements the same permission -> confirm sequence, but it
 * cannot be imported here: it is Lead-bound by contract, importing `Lead.Status` schema and
 * `LeadActionPermissionController`. This module is the guard/confirm HALF of that util, extracted
 * object-agnostically, and deliberately carries NO write helper at all —
 *
 *   Opportunity actions write through IMPERATIVE APEX (StageAdvanceController /
 *   OpportunityApprovalController), not LDS `updateRecord`.
 *
 * That difference is load-bearing and is why the two features must not be "harmonized":
 *   - `updateRecord` writes THROUGH the LDS cache, so the Lead bundles must NOT call
 *     getRecordNotifyChange.
 *   - Apex DML happens behind LDS's back, so the Opportunity bundles MUST call
 *     getRecordNotifyChange after a successful write, or the Path and highlights show a stale stage.
 * Each bundle therefore keeps ownership of its own Apex call, its own toasts, and its own
 * getRecordNotifyChange. This module only decides whether the click may proceed.
 *
 * ── WHY LightningConfirm AND NOT A TOAST ──────────────────────────────────────
 * A confirmation must be able to CANCEL the action, and `ShowToastEvent` is fire-and-forget — it
 * returns nothing, so it cannot carry a yes/no answer. `LightningConfirm.open()` returns a Promise
 * resolving true/false and is the only supported confirmation available to a HEADLESS quick action
 * (it renders into the platform's modal layer, not into the component's own — empty — template).
 * Toasts are still used, for the success and error messages they are meant for.
 *
 * ── WHAT THE PERMISSION CHECK IS, AND IS NOT ──────────────────────────────────
 * `hasDealActionAccess` is a UX gate: it stops the button doing anything and explains why. Unlike
 * the Lead status buttons — whose writes bypass Apex entirely, leaving CRUD/FLS as the only real
 * control — EVERY Opportunity action here routes through Apex, and each of those Apex entry points
 * asserts the SAME permission server-side (OpportunityActionPermissionService.assertDealActionAccess
 * in StageAdvanceController.advance / .advanceTo and
 * OpportunityApprovalController.submitForApproval). So this check is a courtesy that produces a
 * better message; removing it would degrade UX but not open a hole.
 *
 * The question it asks is `Deal_Driver__c = true` on the running user (plus the documented Modify
 * All Data bypass) — identical to the `{!$User.Deal_Driver__c}` Dynamic Actions visibility rules on
 * Opportunity_Record_Page. Hiding the button and enforcing at click time are COMPLEMENTARY, not
 * alternatives (ARCHITECTURE.md §5): a headless quick action owns no button markup, so there is no
 * `disabled` attribute any of these components could set.
 */

/** Shown when the running user is not a deal driver. Identical wording to the Apex denial. */
export const NO_PERMISSION_MESSAGE =
    "You don't have permission to perform this action.";

/** Fallback confirmation prompt for an action that supplies no more specific wording. */
export const DEFAULT_CONFIRM_MESSAGE = 'Continue with this action?';

/** Fallback dialog header. LightningConfirm requires a label when variant is 'header'. */
const DEFAULT_CONFIRM_LABEL = 'Confirm';

/** Last-resort message so no raw platform text or `undefined` ever reaches a toast. */
const GENERIC_ERROR =
    'The action could not be completed. Please try again or contact your administrator.';

/**
 * Extracts a user-safe message from an Apex/LDS error, falling back to a fixed message so no raw
 * platform text or `undefined` ever leaks into the toast (ARCHITECTURE.md §5).
 *
 * @param {*} error the error thrown by an imperative Apex call
 * @param {string} [fallback] message to use when the error carries no readable body
 * @returns {string} a user-safe message
 */
function messageFor(error, fallback) {
    return (
        (error && error.body && error.body.message) || fallback || GENERIC_ERROR
    );
}

/**
 * Dispatches an error toast FROM the passed component (a toast must originate from a live element
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
 * A rejection from the modal itself is treated as "cancelled" rather than surfaced: the user has not
 * agreed to anything, so the only safe interpretation is not to proceed.
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
 * The shared pre-flight for every Opportunity stage quick action: check the running user's
 * permission, then ask them to confirm. The caller does its work only when this resolves `true`.
 *
 * Order matters — permission FIRST. There is no point asking a user to confirm an action they are
 * not allowed to take, and doing so would imply the action was available to them.
 *
 * FAIL CLOSED: if the permission call rejects, the action is refused. The underlying message is
 * surfaced in that case rather than the permission wording, so a genuine system fault is not
 * disguised as a permissions problem. A non-boolean answer (e.g. `undefined` from a short-circuited
 * call) is also treated as denied — `=== true` is required, never a truthiness test.
 *
 * @param {LightningElement} cmp the invoking quick-action component (used to dispatch toasts)
 * @param {{message?: string, label?: string, theme?: string}} [options] confirmation dialog wording
 * @returns {Promise<boolean>} true when the user is permitted AND confirmed
 */
export async function guardDealAction(cmp, options) {
    let allowed = false;
    try {
        allowed = (await hasDealActionAccess()) === true;
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
