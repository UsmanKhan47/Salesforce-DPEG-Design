import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import hasStageActionAccess from '@salesforce/apex/RecordStageAdvanceController.hasStageActionAccess';

/**
 * recordStageGuard — shared pre-flight for the headless stage quick actions on the SEVEN
 * stage-controlled objects, spanning THREE modules:
 *
 *   acquisitions            LOI__c, Underwriting__c, Construction_Feasibility_Review__c,
 *                           Development_Feasibility_Review__c
 *   acquisitions +          NDA__c, Contract_Review__c — one object serving BOTH modules, split by
 *   disposition             record type, each type answering to a different persona
 *   transactions            Transaction__c (2026-08-12)
 *
 * ⚠ THE COUNT HAS BEEN WRONG IN THIS HEADER TWICE, SO READ WHAT CHANGED RATHER THAN THE NUMBER.
 * It first said "the five ACQUISITIONS child objects"; Tranche 3A (2026-08-09) made NDA__c serve
 * the DISPOSITION module through its Disposition_NDA record type, answering to a different persona
 * (DISPOSITION_DRIVER, backed by User.Disposition_Driver__c). It then said "the SIX stage-controlled
 * child objects"; 2026-08-12 added Transaction__c, which is neither a child object nor an
 * acquisitions one, and whose gate is MEMBERSHIP-ONLY (TRANSACTION_STAGE_ACTIONS, backed by the
 * Transaction_Stage_Actions_Access permission set with NO User checkbox of any kind).
 *
 * 🔴 NONE of those three changes required an edit to the logic in this file — only to this
 * sentence. That is the payoff of the per-record signature described below: the server dispatches,
 * so this module has never learned an object's name, a module's name or a persona's name, and the
 * arrival of a THIRD gate shape did not reach it either.
 *
 * A JS-only utility module (no template, isExposed=false), deliberately SEPARATE from `c/utils`,
 * which is contractually pure, stateless formatting only.
 *
 * ── 🔴 WHY THIS IS A THIRD GUARD AND NOT A MERGE ─────────────────────────────
 * There are now three guard utils and they must not be merged. Each is bound to a different
 * permission question and a different WRITE mechanism, and the write mechanism is what dictates
 * whether `getRecordNotifyChange` is mandatory or forbidden (ARCHITECTURE.md §5):
 *
 *   c/leadStatusChange  Lead-bound by contract (imports Lead.Status schema +
 *                       LeadActionPermissionController). Writes via LDS `updateRecord`, which goes
 *                       THROUGH the cache -> must NOT call getRecordNotifyChange.
 *   c/dealActionGuard   Opportunity. Calls OpportunityActionPermissionController at module scope,
 *                       so its permission question takes NO recordId.
 *   c/recordStageGuard  THIS MODULE. All SEVEN objects listed above. Its permission question is
 *                       PER-RECORD — the server dispatches to the object's own gate — so it takes
 *                       a recordId that neither of the other two has. That is the concrete reason
 *                       it cannot simply reuse c/dealActionGuard, whose `hasDealActionAccess()`
 *                       takes NO argument and therefore cannot express "which object's gate?".
 *
 *                       🔴 THAT SIGNATURE HAS NOW PAID FOR ITSELF TWICE, WHICH IS WHY IT IS NOT
 *                       OVER-ENGINEERING. When it was written, all objects answered to the SAME
 *                       deal-driver gate and the argument looked speculative. Since then NDA__c and
 *                       Contract_Review__c gained a per-record-TYPE disposition persona (2026-08-09)
 *                       and Transaction__c arrived with a gate of an entirely different SHAPE —
 *                       membership-only, no User flag (2026-08-12). Both landed as server-side
 *                       config; neither touched a line of client code.
 *
 * Like c/dealActionGuard this module carries NO WRITE HELPER AT ALL. The stage write is imperative
 * Apex owned by the calling bundle, which is what keeps `getRecordNotifyChange` in that bundle's
 * hands — Apex DML happens behind LDS's back, so without it the Path shows a stale stage.
 *
 * ── WHY LightningConfirm AND NOT A TOAST ─────────────────────────────────────
 * A confirmation must be able to CANCEL the action, and `ShowToastEvent` is fire-and-forget — it
 * returns nothing, so it cannot carry a yes/no answer. `LightningConfirm.open()` returns a Promise
 * resolving true/false and is the only supported confirmation available to a HEADLESS quick action
 * (it renders into the platform's modal layer, not into the component's own — empty — template).
 * Toasts are still used, for the success and error messages they are meant for.
 *
 * ── WHAT THE PERMISSION CHECK IS, AND IS NOT ─────────────────────────────────
 * `hasStageActionAccess` is a UX gate: it stops the button doing anything and explains why.
 * `RecordStageAdvanceController.advance` asserts the SAME permission server-side, so this check is
 * a courtesy that produces a better message; removing it would degrade UX but not open a hole.
 *
 * A headless quick action owns no button markup, so there is no `disabled` attribute any component
 * here could set. Hiding the button for unauthorized users is a Dynamic Actions visibility rule
 * (declarative) — the two are COMPLEMENTARY, not alternatives (ARCHITECTURE.md §5).
 */

/** Shown when the running user may not drive this record's stage action. Matches the Apex denial. */
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
 * Extracts a user-safe message from an Apex error, falling back to a fixed message so no raw
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
 * The shared pre-flight for the stage quick action: check the running user's permission for THIS
 * record's object, then ask them to confirm. The caller does its work only when this resolves
 * `true`.
 *
 * Order matters — permission FIRST. There is no point asking a user to confirm an action they are
 * not allowed to take, and doing so would imply the action was available to them.
 *
 * FAIL CLOSED: if the permission call rejects, the action is refused. The underlying message is
 * surfaced in that case rather than the permission wording, so a genuine system fault is not
 * disguised as a permissions problem. A non-boolean answer (e.g. `undefined` from an un-mocked or
 * short-circuited call) is also treated as denied — `=== true` is required, never a truthiness test.
 *
 * @param {LightningElement} cmp the invoking quick-action component (used to dispatch toasts)
 * @param {string} recordId the record whose object decides which permission gate applies
 * @param {{message?: string, label?: string, theme?: string}} [options] confirmation dialog wording
 * @returns {Promise<boolean>} true when the user is permitted AND confirmed
 */
export async function guardStageAction(cmp, recordId, options) {
    let allowed = false;
    try {
        allowed = (await hasStageActionAccess({ recordId })) === true;
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
