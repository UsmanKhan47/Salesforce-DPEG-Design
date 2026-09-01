import { api } from 'lwc';
import LightningModal from 'lightning/modal';

/** Fallback when the caller did not supply a property name. Matches the retired confirm's wording. */
const FALLBACK_PROPERTY = 'this property';

/**
 * c-sell-meter-override-modal — the Sell Meter YELLOW-band override question, and the capture
 * point for the principal's override REASON.
 *
 * Added 2026-08-31 (Disposition BA gap closure, Tranche 2 item 5b, stories 12 and 14).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS BUNDLE EXISTS AT ALL — IT REPLACES `lightning/confirm`, IT DOES NOT DECORATE IT
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `c/sellMeterList` asked the override question with `LightningConfirm.open()` until 2026-08-31.
 * That API resolves `Promise<boolean>` and STRUCTURALLY CANNOT carry a reason back — there is no
 * field to put one in and no shape to return it in. Item 5b makes a written reason mandatory on
 * the override path, so the confirm had to be replaced rather than extended.
 *
 * ⚠ TWO INVARIANTS FROM THE COMPONENTS AROUND THIS ONE ARE PRESERVED BY ITS EXISTENCE, AND BOTH
 * WOULD HAVE BEEN BROKEN BY THE CHEAPER ALTERNATIVE (an override-only textarea inside
 * `c/sellMeterInitiateModal`):
 *
 *   1. THE OVERRIDE QUESTION IS STILL THE FIRST THING THE USER SEES. `c/sellMeterList`'s
 *      `handleRowAction` header states this in terms: opening the initiate modal first and asking
 *      the override question inside it would let a user fill in a record type before being told
 *      the property is not at peak. This dialog still runs BEFORE that one.
 *   2. `c/sellMeterInitiateModal` STAYS BYTE-IDENTICAL IN ITS UI ON BOTH PATHS. Its own header
 *      records that an override must never look different from an initiate — "deliberately
 *      identical apart from the toast title, so an override can never diverge from an initiate".
 *      An override-only textarea in that dialog would have reversed that recorded decision as a
 *      side effect of this change. Instead it gains a pass-through `@api overrideReason` that it
 *      forwards to Apex and renders nowhere.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE CLOSE CONTRACT — read this before changing `handleConfirm` or `handleCancel`
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `close()` is called with exactly one of two shapes, and the caller
 * (`c/sellMeterList._promptOverride`) branches on `confirmed === true`:
 *
 *   { confirmed: false }            Cancelled or dismissed. Nothing happens and nothing is said.
 *   { confirmed: true, reason }     Proceed. `reason` is the trimmed, non-empty text.
 *
 * ⚠ A DISMISS (the X, or Escape) RESOLVES `undefined`, NOT `{ confirmed: false }` — that is
 * `LightningModal`'s behaviour and this component cannot intercept it. The caller therefore tests
 * `answer && answer.confirmed === true` rather than `!answer.confirmed`, and that guard is why a
 * dismissed dialog is safe. Do not "simplify" the caller's check.
 *
 * ⚠ IT NEVER RESOLVES A BARE BOOLEAN, even though today's only consumer would accept one. Doing
 * so would recreate exactly the shape that had to be replaced, and the next reason-carrying field
 * would need this whole change again.
 *
 * ── THE REASON IS MANDATORY, AND THE GETTER IS WHAT ENFORCES IT ─────────────
 * `required` on a `lightning-textarea` draws the asterisk and NOTHING ELSE here: the attribute is
 * only enforced through `reportValidity()`, which nothing calls — this dialog has no
 * `lightning-record-edit-form` and no submit path other than the button. `confirmDisabled` is the
 * enforcement, exactly as `c/sellMeterInitiateModal.confirmDisabled` is for its Sell Type
 * picklist, and for the identical reason its header gives. Delete the getter and the asterisk
 * becomes decoration and a blank reason reaches Apex — reproducing the state this item exists to
 * fix, which is an override whose stated cause is nothing at all.
 */
export default class SellMeterOverrideModal extends LightningModal {
    /**
     * Display name of the property being overridden.
     *
     * 🔴 IT IS RENDERED, AND THAT IS LOAD-BEARING RATHER THAN COSMETIC. The retired
     * `LightningConfirm` put the property name in its message and `sellMeterList.test.js` pinned
     * it (`expect(confirmArgs.message).toContain('Harbor Point')`). A confirmation that does not
     * name its subject asks the user to confirm a word rather than a decision — and this dialog is
     * reached from a table where every row offers the same button.
     */
    @api propertyName;

    /** The principal's typed reason. Undefined until they type. */
    reason;

    get propertyLabel() {
        return this.propertyName || FALLBACK_PROPERTY;
    }

    /**
     * The override question, verbatim from the `LightningConfirm` it replaces.
     *
     * ⚠ THE WORDING IS DELIBERATELY UNCHANGED. It states the band rule in days ("31 to 90 days
     * away") rather than in colour, names the property, and says what pressing Continue means. It
     * was reviewed once; re-authoring it here would be an unreviewed copy of a reviewed string.
     */
    get message() {
        return (
            `${this.propertyLabel} is not at peak yet — its peak sell date is 31 to 90 days away. `
            + 'Initiating a disposition now overrides the sell meter. Continue?'
        );
    }

    /**
     * 🔴 THE ONLY REAL ENFORCEMENT OF THE MANDATORY REASON. See the class header for why the
     * markup's `required` is not it.
     *
     * ⚠ `trim()` MATTERS. A textarea full of spaces is not a reason, and the field it lands in is
     * read by an approving principal on the approval screen. `String.isBlank` on the Apex side
     * would not save us either — nothing on the server refuses a blank reason, by an explicitly
     * recorded decision in `DispositionService.initiateAndSubmit`'s header.
     */
    get confirmDisabled() {
        return !this.reason || this.reason.trim().length === 0;
    }

    handleReasonChange(event) {
        this.reason = event.detail.value;
    }

    /** Cancel resolves an explicit refusal. A dismiss resolves `undefined` — see the header. */
    handleCancel() {
        this.close({ confirmed: false });
    }

    /**
     * Confirm. The guard is not redundant with the disabled attribute: `handleConfirm` is a
     * handler and a disabled attribute is a rendering instruction, and this component's sibling
     * has a documented incident of a row-action payload diverging from what its column definition
     * said. Passing a blank reason through here would put an empty audit field in front of an
     * approver.
     */
    handleConfirm() {
        if (this.confirmDisabled) {
            return;
        }
        this.close({ confirmed: true, reason: this.reason.trim() });
    }
}
