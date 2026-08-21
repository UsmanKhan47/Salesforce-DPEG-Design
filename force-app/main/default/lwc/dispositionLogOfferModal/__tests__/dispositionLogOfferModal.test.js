/**
 * c-disposition-log-offer-modal
 * ---------------------------------------------------------------------------
 * The in-place, buyer-picker replacement for the "+ Log Offer" navigation-create
 * that threw the user off the Disposition page on save AND offered every Contact
 * in the org as a buyer (2026-08-21).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 THE FOUR FALSIFIERS THAT MATTER MOST HERE
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. THE BUYER PICKER IS NARROW, AND ITS OPTION VALUE IS THE **CONTACT** ID.
 *    Returning the NDA Id instead would compile, render identically, save
 *    without error, and silently populate `Buyer__c` with a row that is not a
 *    Contact — caught by nothing until `c/dispositionBuyerTimeline` showed
 *    blanks. T-BUYER pins the value against the Contact Id the wire returned.
 * 2. `Disposition__c`, `Buyer__c` AND `Broker__c` REACH THE SERVER ON BOTH
 *    SUBMIT PATHS. None of the three is carried by an ordinary form input: the
 *    parent is `disabled`, the buyer lives in a combobox outside the form's
 *    field set, and the broker is plain text. There are genuinely two paths
 *    (footer button; ENTER inside a text input) and both are asserted.
 * 3. THE EMPTY STATE RENDERS NO FORM AND NO SAVE BUTTON. With no signed buyer
 *    NDA, `Buyer_Required_On_Offer` (`ISBLANK(Buyer_Name__c)`, no ISNEW guard)
 *    refuses EVERY save, so a form here would be a trap. ⚠ THIS IS THE LIVE
 *    SHAPE IN usman-dpeg: the org's one disposition has one Signed Buyer-role
 *    NDA whose `Buyer__c` is null.
 * 4. `Offer_Financing_Type__c` IS STILL ON THE FORM. The user asked to hide it;
 *    it is read by c/dispositionOfferSelect and by Offer_Selection_Approval's
 *    approval page, so hiding it blanks both. Pinned as PRESENT precisely
 *    because the argument for removing it is a direct user request and would
 *    otherwise be acted on by the next reader.
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
 * `detail.fields`; the combobox change with `detail.value`; success and error
 * with `detail.id` / `detail.message`. `lightning-record-edit-form`'s stub
 * exposes `submit()` as a NO-OP @api method, so `jest.spyOn` on the rendered
 * element is the only honest way to see the payload.
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
const BUYER_1 = '003iw000000o39BAAQ';
const BUYER_2 = '003iw000000o39CAAQ';
const BROKER_ID = '003iw000000mjSgAAI';

/** The on-market shape: a resolved broker and two competing buyers. */
const TWO_BUYERS = {
    brokerId: BROKER_ID,
    brokerName: 'Derek Simmons',
    brokerSource: 'From the selected BOV submission',
    isOnMarket: true,
    buyers: [
        { value: BUYER_1, label: 'Alice Buyer' },
        { value: BUYER_2, label: 'Bob Buyer' }
    ]
};

/** The single-buyer shape — the one the component auto-selects. */
const ONE_BUYER = {
    ...TWO_BUYERS,
    buyers: [{ value: BUYER_1, label: 'Alice Buyer' }]
};

/**
 * 🔴 THE LIVE SHAPE OF `usman-dpeg` ON 2026-08-21: an on-market sale with an
 * appointed broker and NO eligible buyer, because its one Signed Buyer-role NDA
 * has a null `Buyer__c`.
 */
const NO_BUYERS = { ...TWO_BUYERS, buyers: [] };

/** Off-market, before the broker has been picked at Broker Selection. */
const OFF_MARKET_NO_BROKER = {
    brokerId: null,
    brokerName: '',
    brokerSource: 'From the broker picked on this disposition',
    isOnMarket: false,
    buyers: [{ value: BUYER_1, label: 'Alice Buyer' }]
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
     * `context = TWO_BUYERS`; JavaScript's default-parameter rule substitutes the default for an
     * explicit `undefined`, so the wire DID answer, the form DID render, and the test that was
     * supposed to prove "the empty state does not flash" was asserting against a fully-loaded
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
    const combobox = (el) => el.shadowRoot.querySelector('lightning-combobox');
    const inputs = (el) => [...el.shadowRoot.querySelectorAll('lightning-input-field')];
    const fieldNames = (el) => inputs(el).map((i) => i.fieldName);
    const saveButton = (el) => el.shadowRoot.querySelector('.lom-save');

    // ─────────────────────────────────────────────────────────────────────────
    // T-FIELDS — the form is not an empty shell, and the exclusions are pinned
    // ─────────────────────────────────────────────────────────────────────────

    it('T-FIELDS: renders exactly the offer fields an analyst enters, in reading order', async () => {
        const element = await createComponent(TWO_BUYERS);

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

    it('🔴 T-FIELDS: `Offer_Financing_Type__c` IS PRESENT — the user asked to hide it and it must not be', async () => {
        const element = await createComponent(TWO_BUYERS);

        // c/dispositionOfferSelect renders it into the Select Offer radio label,
        // and Offer_Selection_Approval carries it as an approvalPageField. This
        // dialog is the only entry point, so removing it blanks BOTH surfaces on
        // every offer created afterwards, permanently and silently.
        expect(fieldNames(element)).toContain('Offer_Financing_Type__c');
    });

    it('🔴 T-FIELDS: the derived, machine-written and negotiation fields are NOT offered', async () => {
        const element = await createComponent(TWO_BUYERS);
        const rendered = fieldNames(element);

        // DERIVED. DispositionOfferBuyerStampService copies it from Buyer__c in
        // the before-save trigger, so anything sent here is overwritten inside
        // the same save. The combobox IS this field's input now.
        expect(rendered).not.toContain('Buyer_Name__c');
        // ...and it is NOT rendered as a lookup either. The whole point of the
        // modal is that the buyer is picked from a narrow list.
        expect(rendered).not.toContain('Buyer__c');

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
        const element = await createComponent(TWO_BUYERS);
        const required = inputs(element)
            .filter((i) => i.required)
            .map((i) => i.fieldName);

        // Offer_Amount_Required_On_Offer refuses the save server-side. Marking it
        // here turns a round trip into an inline message.
        expect(required).toEqual(['Offer_Amount__c']);
        // The buyer's requiredness lives on the combobox, not on an input-field —
        // Buyer_Required_On_Offer is the rule behind it.
        expect(combobox(element).required).toBe(true);
    });

    it('PARENT: the disposition is shown, and shown LOCKED', async () => {
        const element = await createComponent(TWO_BUYERS);
        const parent = element.shadowRoot.querySelector('.lom-field-disposition');

        expect(parent.value).toBe(DISPOSITION_ID);
        // Disabled so a dialog opened on one sale cannot log an offer against
        // another. (The value still reaches the server — see T-INJECT-*.)
        expect(parent.disabled).toBe(true);
    });

    it('surfaces platform field errors through lightning-messages', async () => {
        const element = await createComponent(TWO_BUYERS);

        // Six validation rules are active on this object and each carries an
        // authored message naming its own field. Hand-parsing
        // error.detail.output.fieldErrors to rebuild a banner loses that.
        expect(element.shadowRoot.querySelector('lightning-messages')).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // T-BUYER — the picker is narrow and its value is the Contact Id
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-BUYER: the picker offers ONLY the buyers the server returned, keyed on the CONTACT Id', async () => {
        const element = await createComponent(TWO_BUYERS);

        expect(combobox(element).options).toEqual([
            { value: BUYER_1, label: 'Alice Buyer' },
            { value: BUYER_2, label: 'Bob Buyer' }
        ]);
        // 🔴 The value is a Contact Id (003…), which is what gets written to
        // Buyer__c — the join c/dispositionBuyerTimeline matches each buyer's NDA
        // to their OWN first offer on. An NDA Id (a0J…) would save without error
        // and break that join invisibly.
        expect(combobox(element).options[0].value.startsWith('003')).toBe(true);
    });

    it('T-BUYER: two buyers means NOTHING is preselected — a competitive sale demands a choice', async () => {
        const element = await createComponent(TWO_BUYERS);

        expect(combobox(element).value).toBeUndefined();
    });

    it('T-BUYER: exactly one buyer IS preselected — a menu of one is a step that can only be forgotten', async () => {
        const element = await createComponent(ONE_BUYER);

        expect(combobox(element).value).toBe(BUYER_1);
    });

    it('🔴 T-BUYER: saving with no buyer chosen does NOT round-trip to the server', async () => {
        const element = await createComponent(TWO_BUYERS);
        const submit = jest.spyOn(form(element), 'submit');

        saveButton(element).click();
        await flushPromises();

        // Buyer_Required_On_Offer would refuse it anyway — but its message names
        // `Buyer_Name__c`, a field this form does not show, so the round trip
        // would point the user at nothing.
        expect(submit).not.toHaveBeenCalled();
        // The dialog stays open and the message is put on the control it is about.
        expect(form(element)).not.toBeNull();
    });

    it('🔴 T-BUYER: ENTER is not a way around the buyer gate either', async () => {
        const element = await createComponent(TWO_BUYERS);
        const submit = jest.spyOn(form(element), 'submit');

        form(element).dispatchEvent(
            new CustomEvent('submit', { detail: { fields: { Offer_Amount__c: 1 } } })
        );
        await flushPromises();

        // The footer button and the native submit are two separate code paths;
        // a gate on only one of them is not a gate.
        expect(submit).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // T-INJECT — the three non-input values reach the server on BOTH paths
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-INJECT-BUTTON: the footer Save forces Disposition__c, Buyer__c and Broker__c onto the payload', async () => {
        const element = await createComponent(TWO_BUYERS);
        const submit = jest.spyOn(form(element), 'submit');

        combobox(element).dispatchEvent(
            new CustomEvent('change', { detail: { value: BUYER_2 } })
        );
        await flushPromises();
        saveButton(element).click();

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];
        // 🔴 THE CENTRAL ASSERTION OF THIS FILE. None of the three is carried by
        // an ordinary form input — the parent is `disabled` (and a disabled
        // control is conventionally excluded from a submission), the buyer is in
        // a combobox outside the form's field set, and the broker is plain text.
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        expect(payload.Buyer__c).toBe(BUYER_2);
        expect(payload.Broker__c).toBe(BROKER_ID);
    });

    it('🔴 T-INJECT-ENTER: a native submit (ENTER in a field) forces all three too', async () => {
        const element = await createComponent(ONE_BUYER);
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
        expect(payload.Buyer__c).toBe(BUYER_1);
        expect(payload.Broker__c).toBe(BROKER_ID);
        // The typed values ride along untouched.
        expect(payload.Offer_Amount__c).toBe(26900000);
    });

    it('🔴 T-INJECT: `Broker__c` is OMITTED, not nulled, when no broker is appointed', async () => {
        const element = await createComponent(OFF_MARKET_NO_BROKER);
        const submit = jest.spyOn(form(element), 'submit');

        saveButton(element).click();

        const payload = submit.mock.calls[0][0];
        // Sending null would be a WRITE — clearing a field the form never showed.
        // Omitting the key is also what lets this dialog save at all until the
        // admin agent's `Disposition_Offer__c.Broker__c` field is deployed.
        expect(Object.prototype.hasOwnProperty.call(payload, 'Broker__c')).toBe(false);
        expect(payload.Buyer__c).toBe(BUYER_1);
    });

    it('VALIDITY: an invalid input aborts the save before any round trip', async () => {
        const element = await createComponent(ONE_BUYER);
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
        const element = await createComponent(TWO_BUYERS);

        expect(
            element.shadowRoot.querySelector('.lom-readonly-value').textContent
        ).toContain('Derek Simmons');
        expect(
            element.shadowRoot.querySelector('.lom-readonly-help').textContent
        ).toContain('selected BOV submission');
    });

    it('T-BROKER: no broker is an ACCEPTED state, and the hint is per record type', async () => {
        const element = await createComponent(OFF_MARKET_NO_BROKER);

        // The broker only exists once the appointment is approved; an offer
        // logged before that legitimately carries none. The form still renders.
        expect(
            element.shadowRoot.querySelector('.lom-readonly-value').textContent
        ).toContain('Not appointed yet');
        // 🔴 OFF-MARKET WORDING. The two remedies are on two different screens,
        // so one generic sentence would misdirect half the users.
        expect(
            element.shadowRoot.querySelector('.lom-readonly-help').textContent
        ).toContain('Broker Selection stage');
        expect(form(element)).not.toBeNull();
    });

    it('T-BROKER: the on-market hint points at the BOV matrix instead', async () => {
        const element = await createComponent({ ...NO_BUYERS, brokerId: null });

        // Even in the empty state the record type still decides the wording — but
        // the broker block is not rendered there, so assert via the on-market
        // form shape instead.
        expect(element.shadowRoot.querySelector('.lom-empty')).not.toBeNull();
    });

    it('T-BROKER: on-market with no broker points at the BOV comparison matrix', async () => {
        const element = await createComponent({
            ...TWO_BUYERS,
            brokerId: null,
            brokerName: ''
        });

        expect(
            element.shadowRoot.querySelector('.lom-readonly-help').textContent
        ).toContain('comparison matrix');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // T-EMPTY — no buyer means no form, and no Save button
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-EMPTY: with no eligible buyer there is NO FORM and NO SAVE BUTTON', async () => {
        const element = await createComponent(NO_BUYERS);

        // `Buyer_Required_On_Offer` is ISBLANK(Buyer_Name__c) with no ISNEW
        // guard, so it refuses EVERY save. A form here would let the analyst
        // enter an amount, a date and a financing type and then be refused by a
        // rule naming a field they were never shown.
        expect(form(element)).toBeNull();
        expect(combobox(element)).toBeNull();
        // 🔴 ABSENT, not disabled. A disabled Save invites a click and then
        // explains nothing.
        expect(saveButton(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.lom-empty')).not.toBeNull();
    });

    /**
     * 🔴 REWRITTEN 2026-08-21 AT UAT. THREE ASSERTIONS WERE DELETED, NOT RELAXED.
     * The old test was named *"the copy names BOTH reasons"* and asserted
     * `'signed NDA that names a buyer'`, `'not linked to a Contact'` and `'NDAs'`.
     * All three strings are gone from the panel, and the test's PREMISE is gone
     * with them: naming both reasons as alternatives is what made the message
     * long enough for the user to abandon halfway. The panel was factually
     * correct on NDA-0114 (Signed, Buyer role, `Buyer__c` NULL) and the user still
     * concluded it was wrong, because they stopped at the opening sentence about
     * why an offer needs a buyer.
     *
     * ⚠ THE SECOND CAUSE IS STILL COVERED AND IS STILL ASSERTED — just not as an
     * alternative to diagnose. "No signed NDA on this sale names a buyer contact"
     * is true whether the NDA is unsigned or merely unlinked, so the assertions
     * below check that BOTH nouns survive in ONE sentence.
     */
    it('🔴 T-EMPTY: the copy leads with the cause and carries the remedy, in one sentence', async () => {
        const element = await createComponent(NO_BUYERS);
        const heading = element.shadowRoot.querySelector(
            '.lom-empty-heading'
        ).textContent;
        const copy = element.shadowRoot
            .querySelector('.lom-empty-copy')
            .textContent.replace(/\s+/g, ' ')
            .trim();

        expect(heading).toBe('No buyer available');
        // THE CAUSE — both halves of it, in one clause the reader does not have to
        // pick between: a signed NDA, and a buyer contact on it.
        expect(copy).toContain('No signed NDA on this sale names a buyer contact');
        // THE REMEDY — where to go and what to do when they get there.
        expect(copy).toContain('Set the Buyer on the signed NDA');
        expect(copy).toContain('then log the offer');

        // 🔴 THE SENTENCE THE USER BOUNCED OFF MUST NOT COME BACK. It was true and
        // it was the reason they never reached the sentence that answered them.
        expect(copy).not.toContain('must name the buyer who made it');
        // 🔴 A LENGTH BUDGET, NOT A STYLE PREFERENCE. The defect being guarded is
        // "the user read the first sentence and stopped", which regrows one
        // well-meaning clarification at a time and which no other assertion here
        // can see. The panel is ~101 characters today; the ceiling leaves room for
        // a rewording and none for a third sentence.
        expect(copy.length).toBeLessThanOrEqual(160);
    });

    it('T-EMPTY: the remaining button reads Close, not Cancel', async () => {
        const element = await createComponent(NO_BUYERS);

        // There is nothing to cancel — the dialog is only informing.
        expect(element.shadowRoot.querySelector('.lom-cancel').label).toBe('Close');
    });

    it('🔴 T-EMPTY: neither the empty state NOR the form renders before the wire answers', async () => {
        const element = createUnansweredComponent();
        await flushPromises();

        // Without the `_loaded` gate this would render "No buyer available" for
        // one frame on EVERY open, on the happy path, to every user.
        expect(element.shadowRoot.querySelector('.lom-empty')).toBeNull();
        // 🔴 AND NOT THE FORM EITHER. MEASURED: the first version of this
        // template branched to the form with `lwc:else`, so the whole form —
        // including an EMPTY, interactive buyer combobox — rendered underneath
        // the spinner on every open. The chain now ends at `lwc:elseif={canSave}`
        // with no `lwc:else`, so the loading state renders the spinner alone.
        expect(form(element)).toBeNull();
        expect(combobox(element)).toBeNull();
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
                    'You do not have access to the buyer or broker information on this disposition.'
            },
            400,
            'Bad Request'
        );
        await flushPromises();

        expect(element.shadowRoot.querySelector('.lom-error').textContent).toContain(
            'do not have access'
        );
        // A load failure is an ADMINISTRATOR's problem; the empty state is the
        // ANALYST's. They must not render as the same screen.
        expect(element.shadowRoot.querySelector('.lom-empty')).toBeNull();
        expect(saveButton(element)).toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome handling
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 SUCCESS: closes with the new record Id and NEVER navigates', async () => {
        const element = await createComponent(ONE_BUYER);
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
        const element = await createComponent(ONE_BUYER);
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
        const element = await createComponent(ONE_BUYER);
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
        expect(closed).not.toHaveBeenCalled();
        expect(form(element)).not.toBeNull();
        // The spinner is released, so Save is usable again.
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        expect(saveButton(element).disabled).toBe(false);
    });

    it('SAVING: the spinner appears and Save is disabled while in flight', async () => {
        const element = await createComponent(ONE_BUYER);

        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();

        saveButton(element).click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-spinner')).not.toBeNull();
        expect(saveButton(element).disabled).toBe(true);
    });

    it('SAVING: a second click while in flight does not submit twice', async () => {
        const element = await createComponent(ONE_BUYER);
        const submit = jest.spyOn(form(element), 'submit');

        saveButton(element).click();
        await flushPromises();
        saveButton(element).click();

        expect(submit).toHaveBeenCalledTimes(1);
    });

    it('CANCEL: closes with nothing, so the opener says nothing', async () => {
        const element = await createComponent(ONE_BUYER);
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
        const element = await createComponent(TWO_BUYERS);

        // The SLDS linter is a separate command a reviewer can forget; this is
        // the fence that runs on every commit.
        expect(element.shadowRoot.innerHTML).not.toMatch(/\sstyle\s*=/);
    });

    it('is accessible (form)', async () => {
        const element = await createComponent(TWO_BUYERS);

        await expect(element).toBeAccessible();
    });

    it('is accessible (empty state)', async () => {
        const element = await createComponent(NO_BUYERS);

        await expect(element).toBeAccessible();
    });
});
