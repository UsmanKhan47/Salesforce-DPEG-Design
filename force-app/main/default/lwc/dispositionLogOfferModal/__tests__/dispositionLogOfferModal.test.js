/**
 * c-disposition-log-offer-modal
 * ---------------------------------------------------------------------------
 * The in-place replacement for the "+ Log Offer" navigation-create that threw
 * the user off the Disposition page on save (2026-08-21).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 REWRITTEN 2026-08-21 — THE BUYER PICKER WAS DELETED, AND SO WERE ITS TESTS
 * ═══════════════════════════════════════════════════════════════════════════
 * DPEG communicates only with the appointed listing broker; buyers sit behind
 * them and are not tracked. Four T-BUYER tests, both buyer fixtures and every
 * `Buyer__c` assertion inside T-INJECT-* were DELETED, not weakened into
 * `expect(...).toBeNull()` inside a test still named for the picker. What
 * replaces them is ONE deliberate absence pin (T-NO-BUYER), because deletion on
 * its own leaves nothing to fail if a well-meaning edit puts the picker back.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 THE FOUR FALSIFIERS THAT MATTER MOST HERE
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. `Disposition__c` AND `Broker__c` REACH THE SERVER ON BOTH SUBMIT PATHS.
 *    Neither is carried by an ordinary form input: the parent is `disabled` and
 *    the broker is plain text. There are genuinely two paths (footer button;
 *    ENTER inside a text input) and both are asserted.
 * 2. NO BROKER MEANS NO FORM AND NO SAVE BUTTON. This is the dialog's ONLY
 *    refusal path now, and it is a design decision rather than a platform
 *    constraint — nothing stops a broker-less offer saving. It is refused
 *    because with the buyer gone, `Broker__c` is the only party an offer names.
 *    ⚠ The old refusal ("no eligible buyer") was FORCED by an active validation
 *    rule; this one is not. The two are not interchangeable and the component
 *    header says so.
 * 3. THE REFUSAL COPY IS WORDED PER RECORD TYPE, because the two remedies sit
 *    on two different screens (the BOV comparison matrix; the Broker Selection
 *    stage). One generic sentence would misdirect half the users.
 * 4. `Offer_Financing_Type__c` IS STILL ON THE FORM. The user asked to hide it;
 *    it is read by c/dispositionOfferSelect and by Offer_Selection_Approval's
 *    approval page, so hiding it blanks both. Its value went UP when the buyer
 *    name left that radio label. Pinned as PRESENT precisely because the
 *    argument for removing it is a direct user request.
 *
 * ⚠ `LightningModal` HAS NO sfdx-lwc-jest STUB — this repo supplies its own at
 * jest-mocks/lightning/modal.js, wired in through jest.config.js's
 * moduleNameMapper. Its `close(result)` dispatches a catchable `close` event,
 * which is the ONLY handle a test has on the return value when the modal is
 * mounted directly. ⚠ STUB ARTEFACT: a bare `close()` arrives as
 * `detail === null`, not `undefined`.
 *
 * ⚠ NOTHING HERE FABRICATES AN EVENT SHAPE THE PLATFORM DOES NOT EMIT. The
 * native submit is driven with a real `submit` CustomEvent carrying
 * `detail.fields`; success and error with `detail.id` / `detail.message`.
 * `lightning-record-edit-form`'s stub exposes `submit()` as a NO-OP @api method,
 * so `jest.spyOn` on the rendered element is the only honest way to see the
 * payload.
 */
import { createElement } from 'lwc';
import DispositionLogOfferModal from 'c/dispositionLogOfferModal';
import getOfferFormContext from '@salesforce/apex/DispositionOfferFormController.getOfferFormContext';

jest.mock(
    '@salesforce/apex/DispositionOfferFormController.getOfferFormContext',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const DISPOSITION_ID = 'a0Ciw000004C4ngEAC';
const NEW_RECORD_ID = 'a0Biw000000009AAA';
const BROKER_ID = '003iw000000mjSgAAI';

/** The on-market happy path: a broker resolved from the Selected BOV submission. */
const ON_MARKET_WITH_BROKER = {
    brokerId: BROKER_ID,
    brokerName: 'Derek Simmons',
    brokerSource: 'From the selected BOV submission',
    isOnMarket: true
};

/** Off-market, with the broker picked at the Broker Selection stage. */
const OFF_MARKET_WITH_BROKER = {
    brokerId: BROKER_ID,
    brokerName: 'Derek Simmons',
    brokerSource: 'From the broker picked on this disposition',
    isOnMarket: false
};

/**
 * 🔴 THE LIVE SHAPE OF `usman-dpeg`'s OFF-MARKET PATH: `Disposition__c.Broker__c`
 * is null until the Broker Selection stage. This is now the REFUSAL state.
 */
const OFF_MARKET_NO_BROKER = {
    brokerId: null,
    brokerName: '',
    brokerSource: 'From the broker picked on this disposition',
    isOnMarket: false
};

/** On-market before `Broker_Finalize_Approval` has approved a submission. */
const ON_MARKET_NO_BROKER = {
    brokerId: null,
    brokerName: '',
    brokerSource: 'From the selected BOV submission',
    isOnMarket: true
};

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-disposition-log-offer-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    /**
     * Mounts the modal WITHOUT letting the wire answer — the pre-answer frame.
     *
     * 🔴 IT IS A SEPARATE HELPER RATHER THAN `createComponent(undefined)`, AND THAT IS NOT
     * STYLE. The first version of this suite passed `undefined` to a helper whose parameter was
     * `context = <default>`; JavaScript's default-parameter rule substitutes the default for an
     * explicit `undefined`, so the wire DID answer, the form DID render, and the test that was
     * supposed to prove "the refusal panel does not flash" was asserting against a fully-loaded
     * component. It failed for the right reason by luck. A sentinel-free helper cannot be got
     * wrong that way.
     */
    function createUnansweredComponent() {
        const element = createElement('c-disposition-log-offer-modal', {
            is: DispositionLogOfferModal
        });
        element.dispositionId = DISPOSITION_ID;
        document.body.appendChild(element);
        return element;
    }

    async function createComponent(context) {
        const element = createUnansweredComponent();
        getOfferFormContext.emit(context);
        await flushPromises();
        return element;
    }

    const form = (el) => el.shadowRoot.querySelector('lightning-record-edit-form');
    const inputs = (el) => [...el.shadowRoot.querySelectorAll('lightning-input-field')];
    const fieldNames = (el) => inputs(el).map((i) => i.fieldName);
    const saveButton = (el) => el.shadowRoot.querySelector('.lom-save');

    // ─────────────────────────────────────────────────────────────────────────
    // T-FIELDS — the form is not an empty shell, and the exclusions are pinned
    // ─────────────────────────────────────────────────────────────────────────

    it('T-FIELDS: renders exactly the offer fields an analyst enters, in reading order', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        expect(fieldNames(element)).toEqual([
            'Disposition__c',
            'Offer_Amount__c',
            'Offer_Date__c',
            'Offer_Financing_Type__c',
            'Earnest_Money_Proposed__c',
            'Due_Diligence_Days__c',
            'Closing_Period_Days__c'
        ]);

        expect(form(element).objectApiName).toBe('Disposition_Offer__c');
        // 🔴 CREATE ONLY. A `record-id` would turn this into an edit form against
        // whatever Id leaked in.
        expect(form(element).recordId).toBeUndefined();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // `.lom-intro` ("Log an offer against this sale. It is saved here on the
    // disposition — you stay on this page and the offers card refreshes behind
    // this dialog.") was removed at the user's request. Nothing in this file
    // asserted it, so its deletion left nothing to fail if it comes back.
    //
    // 🔴 THIS PIN IS NARROW ON PURPOSE. The REFUSAL panel in this same bundle was
    // explicitly KEPT — it is the only surface explaining a dialog that renders
    // no form and no Save button — and T-REFUSAL below still asserts its wording
    // positively. A broader "no explanatory copy anywhere" assertion here would
    // fight that test. Run on the FORM state, where the intro used to live.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PROSE: no intro paragraph above the form — the removal must not come back', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        // Guard the guard: the form branch genuinely rendered.
        expect(form(element)).not.toBeNull();
        expect(inputs(element).length).toBeGreaterThan(0);

        // 1. THE OLD SELECTOR.
        expect(element.shadowRoot.querySelector('.lom-intro')).toBeNull();

        // 2. 🔴 THE RENDERED WORDS — a re-added paragraph usually arrives under a
        //    new class name, so the selector assertion alone would stay green.
        const text = element.shadowRoot.textContent.toLowerCase();
        expect(text).not.toContain('you stay on this page');
        expect(text).not.toContain('refreshes behind this dialog');
        expect(text).not.toContain('log an offer against this sale');
    });

    it('🔴 T-FIELDS: `Offer_Financing_Type__c` IS PRESENT — the user asked to hide it and it must not be', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        // c/dispositionOfferSelect renders it into the Select Offer radio label,
        // and Offer_Selection_Approval carries it as an approvalPageField. This
        // dialog is the only entry point, so removing it blanks BOTH surfaces on
        // every offer created afterwards, permanently and silently — and with the
        // buyer name gone from that label it is now one of only three things
        // telling two offers on one sale apart.
        expect(fieldNames(element)).toContain('Offer_Financing_Type__c');
    });

    it('🔴 T-FIELDS: the machine-written and negotiation fields are NOT offered', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const rendered = fieldNames(element);

        // User-requested removals.
        expect(rendered).not.toContain('NDA_Status__c');
        expect(rendered).not.toContain('Offer_Status__c');

        // Machine-written, and both editable=false in DPEG_Disposition_Edit —
        // rendering either raises an FLS error inside the form.
        expect(rendered).not.toContain('Is_Selected__c');
        expect(rendered).not.toContain('Approval_Status__c');

        // An offer being LOGGED has not been countered or closed yet.
        expect(rendered).not.toContain('Buyer_Counter_Price__c');
        expect(rendered).not.toContain('DPEG_Counter_Price__c');
        expect(rendered).not.toContain('DPEG_Counter_Date__c');
        expect(rendered).not.toContain('Final_Agreed_Price__c');

        // AutoNumber.
        expect(rendered).not.toContain('Name');
        // 🔴 NOT AN INPUT FIELD AT ALL — the broker is read-only text. If this
        // ever fails, someone has made the broker hand-pickable on an offer.
        expect(rendered).not.toContain('Broker__c');
    });

    it('T-FIELDS: the validation-rule field is marked required on the client', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const required = inputs(element)
            .filter((i) => i.required)
            .map((i) => i.fieldName);

        // Offer_Amount_Required_On_Offer refuses the save server-side. Marking it
        // here turns a round trip into an inline message.
        expect(required).toEqual(['Offer_Amount__c']);
    });

    it('PARENT: the disposition is shown, and shown LOCKED', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const parent = element.shadowRoot.querySelector('.lom-field-disposition');

        expect(parent.value).toBe(DISPOSITION_ID);
        // Disabled so a dialog opened on one sale cannot log an offer against
        // another. (The value still reaches the server — see T-INJECT-*.)
        expect(parent.disabled).toBe(true);
    });

    it('surfaces platform field errors through lightning-messages', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        // Six validation rules are active on this object and each carries an
        // authored message naming its own field. Hand-parsing
        // error.detail.output.fieldErrors to rebuild a banner loses that.
        // ⚠ ONE OF THE SIX IS `Buyer_Required_On_Offer`, WHICH THIS FORM CANNOT
        // SATISFY UNTIL IT IS DEACTIVATED — this element is where that refusal
        // lands. See the component header.
        expect(element.shadowRoot.querySelector('lightning-messages')).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-BUYER — THE DELIBERATE ABSENCE PIN (2026-08-21)
    //
    // The buyer picker's own tests were DELETED. This is the one thing standing
    // between the repo and a well-meaning edit that puts a buyer back on this
    // form, and it runs against the FULLY-LOADED happy-path fixture so it cannot
    // pass merely because nothing rendered.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-BUYER: no buyer picker, no buyer field and no buyer WORD — the removal must not come back', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        // Guard the guard: this fixture renders the whole form, so every
        // assertion below is about an element that is genuinely absent rather
        // than about an empty component.
        expect(form(element)).not.toBeNull();
        expect(inputs(element).length).toBeGreaterThan(0);

        // 1. THE CONTROL. The picker was a `lightning-combobox`, the only one
        //    this component ever rendered.
        expect(element.shadowRoot.querySelector('lightning-combobox')).toBeNull();
        expect(element.shadowRoot.querySelector('.lom-field-buyer')).toBeNull();

        // 2. THE FIELDS, in either shape — a lookup or the derived text.
        expect(fieldNames(element)).not.toContain('Buyer__c');
        expect(fieldNames(element)).not.toContain('Buyer_Name__c');

        // 3. 🔴 THE RENDERED WORD. A re-added surface usually arrives under a new
        //    class name and a new control, so the two assertions above would stay
        //    green while a "Buyer" label sat on the form. This is the one that
        //    catches that.
        expect(element.shadowRoot.textContent.toLowerCase()).not.toContain('buyer');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // T-INJECT — the two non-input values reach the server on BOTH paths
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-INJECT-BUTTON: the footer Save forces Disposition__c and Broker__c onto the payload', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const submit = jest.spyOn(form(element), 'submit');

        saveButton(element).click();

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];
        // 🔴 THE CENTRAL ASSERTION OF THIS FILE. Neither is carried by an
        // ordinary form input — the parent is `disabled` (and a disabled control
        // is conventionally excluded from a submission) and the broker is plain
        // text.
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        expect(payload.Broker__c).toBe(BROKER_ID);
        // 🔴 AND NOTHING BUYER-SHAPED RIDES ALONG. `Buyer__c` used to be forced
        // onto this payload too; sending it now would be writing a lookup no
        // control on this form can set.
        expect(Object.prototype.hasOwnProperty.call(payload, 'Buyer__c')).toBe(false);
        expect(Object.prototype.hasOwnProperty.call(payload, 'Buyer_Name__c')).toBe(
            false
        );
    });

    it('🔴 T-INJECT-ENTER: a native submit (ENTER in a field) forces both too', async () => {
        const element = await createComponent(OFF_MARKET_WITH_BROKER);
        const submit = jest.spyOn(form(element), 'submit');

        // The REAL shape the platform dispatches: a `submit` event carrying the
        // form's own field map in `detail.fields`.
        form(element).dispatchEvent(
            new CustomEvent('submit', {
                detail: { fields: { Offer_Amount__c: 26900000 } }
            })
        );

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];
        // ⚠ THIS PATH EXISTS AND THE FOOTER BUTTON NEVER TOUCHES IT. Pressing
        // ENTER inside a text input submits the form natively and fires
        // `onsubmit`; the footer button's `submit(fields)` does NOT fire it.
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        expect(payload.Broker__c).toBe(BROKER_ID);
        // The typed values ride along untouched.
        expect(payload.Offer_Amount__c).toBe(26900000);
    });

    it('VALIDITY: an invalid input aborts the save before any round trip', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const submit = jest.spyOn(form(element), 'submit');

        // ⚠ THE STUB'S `reportValidity()` RETURNS UNDEFINED, so the component
        // aborts only on an explicit `false` — a truthiness test there would
        // abort every save in Jest and leave the whole submit path unexercised
        // (a green suite proving nothing). This overrides one field's return
        // value to prove the branch is live rather than decorative.
        jest.spyOn(
            element.shadowRoot.querySelector('.lom-field-amount'),
            'reportValidity'
        ).mockReturnValue(false);

        saveButton(element).click();

        expect(submit).not.toHaveBeenCalled();
        expect(form(element)).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // T-BROKER — resolved, read-only, and never typed
    // ─────────────────────────────────────────────────────────────────────────

    it('T-BROKER: the resolved broker is shown read-only with its source', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        expect(
            element.shadowRoot.querySelector('.lom-readonly-value').textContent
        ).toContain('Derek Simmons');
        expect(
            element.shadowRoot.querySelector('.lom-readonly-help').textContent
        ).toContain('selected BOV submission');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // T-REFUSAL — no broker means no form and no Save button
    //
    // ⚠ THIS BLOCK REPLACES THE OLD T-EMPTY BLOCK, WHICH WAS ABOUT THE BUYER.
    // The assertions are structurally the same because the SHAPE of the refusal
    // is the same; the SUBJECT and the justification are not. The old refusal
    // was forced by an active validation rule, this one is a design decision.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-REFUSAL: with no appointed broker there is NO FORM and NO SAVE BUTTON', async () => {
        const element = await createComponent(OFF_MARKET_NO_BROKER);

        // With the buyer gone, `Broker__c` is the only party an offer names. An
        // offer naming nobody cannot be attributed, cannot be told apart from
        // another offer on the same sale, and is what
        // DispositionApprovalService.selectOffer would be choosing between.
        expect(form(element)).toBeNull();
        // 🔴 ABSENT, not disabled. A disabled Save invites a click and then
        // explains nothing.
        expect(saveButton(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.lom-empty')).not.toBeNull();
    });

    it('🔴 T-REFUSAL: the copy leads with the cause and carries the off-market remedy', async () => {
        const element = await createComponent(OFF_MARKET_NO_BROKER);
        const heading = element.shadowRoot.querySelector(
            '.lom-empty-heading'
        ).textContent;
        const copy = element.shadowRoot
            .querySelector('.lom-empty-copy')
            .textContent.replace(/\s+/g, ' ')
            .trim();

        expect(heading).toBe('No broker appointed');
        // THE CAUSE, first and in the reader's own terms.
        expect(copy).toContain('No broker is appointed on this sale yet');
        // 🔴 THE REMEDY, AND IT IS THE OFF-MARKET ONE. The two remedies are on
        // two different screens, so a generic sentence would send half the users
        // to the wrong place.
        expect(copy).toContain('Broker Selection stage');
        expect(copy).not.toContain('comparison matrix');

        // 🔴 A LENGTH BUDGET, NOT A STYLE PREFERENCE. The defect being guarded is
        // "the user read the first sentence and stopped" — measured on the panel
        // this one replaced, which was correct in five sentences and abandoned
        // after one. It regrows one well-meaning clarification at a time and no
        // other assertion here can see it. The panel is ~108 characters today;
        // the ceiling leaves room for a rewording and none for a third sentence.
        expect(copy.length).toBeLessThanOrEqual(160);
    });

    it('🔴 T-REFUSAL: on-market points at the BOV comparison matrix instead', async () => {
        const element = await createComponent(ON_MARKET_NO_BROKER);
        const copy = element.shadowRoot
            .querySelector('.lom-empty-copy')
            .textContent.replace(/\s+/g, ' ')
            .trim();

        expect(copy).toContain('comparison matrix');
        expect(copy).not.toContain('Broker Selection stage');
        expect(copy.length).toBeLessThanOrEqual(160);
    });

    it('T-REFUSAL: the remaining button reads Close, not Cancel', async () => {
        const element = await createComponent(ON_MARKET_NO_BROKER);

        // There is nothing to cancel — the dialog is only informing.
        expect(element.shadowRoot.querySelector('.lom-cancel').label).toBe('Close');
    });

    it('🔴 T-REFUSAL: neither the panel NOR the form renders before the wire answers', async () => {
        const element = createUnansweredComponent();
        await flushPromises();

        // Without the `_loaded` gate this would render "No broker appointed" for
        // one frame on EVERY open, on the happy path, to every user.
        expect(element.shadowRoot.querySelector('.lom-empty')).toBeNull();
        // 🔴 AND NOT THE FORM EITHER. MEASURED: the first version of this
        // template branched to the form with `lwc:else`, so the whole form
        // rendered underneath the spinner on every open. The chain now ends at
        // `lwc:elseif={canSave}` with no `lwc:else`, so the loading state renders
        // the spinner alone.
        expect(form(element)).toBeNull();
        expect(element.shadowRoot.querySelector('lightning-spinner')).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Load failure
    // ─────────────────────────────────────────────────────────────────────────

    it('LOAD ERROR: surfaces the authored server message and offers no Save', async () => {
        const element = createUnansweredComponent();

        // ⚠ `createApexTestWireAdapter.error(body, status, statusText)` takes the
        // BODY as its first argument and wraps it — it does not take a whole
        // pre-built `{ body, ok, status, statusText }`. Passing one nests it as
        // `error.body.body.message`, the component's `error.body.message` reads
        // undefined, and the test then asserts against the component's GENERIC
        // fallback while looking like it proves the authored message survives.
        // Measured here on 2026-08-21.
        getOfferFormContext.error(
            {
                message:
                    'You do not have access to the broker information on this disposition.'
            },
            400,
            'Bad Request'
        );
        await flushPromises();

        expect(element.shadowRoot.querySelector('.lom-error').textContent).toContain(
            'do not have access'
        );
        // 🔴 A LOAD FAILURE IS AN ADMINISTRATOR'S PROBLEM; THE REFUSAL PANEL IS
        // THE ANALYST'S. They must not render as the same screen — the error
        // branch is checked FIRST in the template for exactly this reason, so an
        // unreadable broker is never reported as an unappointed one.
        expect(element.shadowRoot.querySelector('.lom-empty')).toBeNull();
        expect(saveButton(element)).toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome handling
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 SUCCESS: closes with the new record Id and NEVER navigates', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const closed = jest.fn();
        element.addEventListener('close', closed);

        form(element).dispatchEvent(
            new CustomEvent('success', {
                detail: { id: NEW_RECORD_ID, fields: { Name: { value: 'OFFER-0007' } } }
            })
        );
        await flushPromises();

        expect(closed).toHaveBeenCalledTimes(1);
        // 🔴 The Id is the product: the opener uses it to decide whether anything
        // actually happened, then refreshes its own wire.
        expect(closed.mock.calls[0][0].detail).toEqual({
            recordId: NEW_RECORD_ID,
            name: 'OFFER-0007'
        });
    });

    it('SUCCESS: a missing Name still returns a usable result', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const closed = jest.fn();
        element.addEventListener('close', closed);

        form(element).dispatchEvent(
            new CustomEvent('success', { detail: { id: NEW_RECORD_ID } })
        );
        await flushPromises();

        // ⚠ Never `undefined` for the name — the opener interpolates it into a
        // toast, and an undefined there renders the literal string "undefined".
        expect(closed.mock.calls[0][0].detail).toEqual({
            recordId: NEW_RECORD_ID,
            name: ''
        });
    });

    it('🔴 ERROR: the dialog STAYS OPEN and keeps what the user entered', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const closed = jest.fn();
        element.addEventListener('close', closed);

        saveButton(element).click();
        form(element).dispatchEvent(
            new CustomEvent('error', {
                detail: { message: 'Enter the Offer Amount.' }
            })
        );
        await flushPromises();

        // 🔴 Every realistic refusal here is about WHAT WAS ENTERED. Closing would
        // throw away both the message lightning-messages just rendered and the
        // user's other values.
        // ⚠ Until `Buyer_Required_On_Offer` is deactivated this is the path EVERY
        // save takes — which is exactly why staying open matters more now, not
        // less.
        expect(closed).not.toHaveBeenCalled();
        expect(form(element)).not.toBeNull();
        // The spinner is released, so Save is usable again.
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        expect(saveButton(element).disabled).toBe(false);
    });

    it('SAVING: the spinner appears and Save is disabled while in flight', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();

        saveButton(element).click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-spinner')).not.toBeNull();
        expect(saveButton(element).disabled).toBe(true);
    });

    it('SAVING: a second click while in flight does not submit twice', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const submit = jest.spyOn(form(element), 'submit');

        saveButton(element).click();
        await flushPromises();
        saveButton(element).click();

        expect(submit).toHaveBeenCalledTimes(1);
    });

    it('CANCEL: closes with nothing, so the opener says nothing', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);
        const closed = jest.fn();
        element.addEventListener('close', closed);

        element.shadowRoot.querySelector('.lom-cancel').click();
        await flushPromises();

        expect(closed).toHaveBeenCalledTimes(1);
        // ⚠ STUB ARTEFACT: `close()` with no argument arrives as `detail === null`,
        // not `undefined` — CustomEvent's own coercion. The real LightningModal
        // resolves `undefined`. The opener treats both alike.
        expect(closed.mock.calls[0][0].detail).toBeFalsy();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Styling + accessibility
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 STYLING: no inline style attribute anywhere in the template', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        // The SLDS linter is a separate command a reviewer can forget; this is
        // the fence that runs on every commit.
        expect(element.shadowRoot.innerHTML).not.toMatch(/\sstyle\s*=/);
    });

    it('is accessible (form)', async () => {
        const element = await createComponent(ON_MARKET_WITH_BROKER);

        await expect(element).toBeAccessible();
    });

    it('is accessible (refusal panel)', async () => {
        const element = await createComponent(ON_MARKET_NO_BROKER);

        await expect(element).toBeAccessible();
    });
});
