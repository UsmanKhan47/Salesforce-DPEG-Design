/**
 * c-release-materials-response-log
 * ---------------------------------------------------------------------------
 * The Release Materials response logger, and the ONLY route to creating a
 * `Release_Materials_Response__c` — the object ships with no tab and no list
 * view. Added 2026-08-24.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 THE FOUR TESTS THIS FILE EXISTS FOR
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. `saveResponse` IS CALLED WITH NO BROKER ARGUMENT. The appointed broker is
 *    resolved SERVER-SIDE at save time; a client-supplied Contact Id would be a
 *    forgeable attribution on a record whose entire purpose is attribution. The
 *    assertion is on the EXACT ARGUMENT KEYS, not `toHaveBeenCalled`, because a
 *    re-added `brokerId` would sail through a looser check.
 * 2. NO BROKER STILL LETS YOU LOG. User instruction 2026-08-24 — and it is the
 *    OPPOSITE of `c/dispositionLogOfferModal`, which refuses. The card explains
 *    the absence rather than blocking on it.
 * 3. `canLog = false` HIDES THE OPENER but keeps the list. A Save button that is
 *    always refused is worse than no button.
 * 4. THE ERROR BRANCH IS VISIBLE. The controller throws rather than returning an
 *    empty context precisely so a silent blank card is impossible.
 *
 * ⚠ EVERY ASSERTION IS ON A RENDERED ELEMENT, NEVER ON A GETTER. A getter-only
 * assertion has passed in this repo while the rendered output was wrong.
 * ⚠ AND WHERE A `lightning-*` STUB IS INVOLVED, THE ASSERTION IS ON A PROPERTY,
 * NOT ON `textContent`. sfdx-lwc-jest stubs render an EMPTY template, so a
 * `textContent` assertion against one is vacuously green whether or not the
 * value was ever passed. `lightning-formatted-date-time.value`,
 * `lightning-button.disabled` and `lightning-combobox.options` are read
 * directly for that reason.
 */
import { createElement } from 'lwc';
import ReleaseMaterialsResponseLog from 'c/releaseMaterialsResponseLog';
import getLogContext from '@salesforce/apex/ReleaseMaterialsResponseController.getLogContext';
import saveResponse from '@salesforce/apex/ReleaseMaterialsResponseController.saveResponse';

jest.mock(
    '@salesforce/apex/ReleaseMaterialsResponseController.getLogContext',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/ReleaseMaterialsResponseController.saveResponse',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a0Y0000000000001AAA';
const EM_DASH = '—';

/** A response WITH notes and a broker — the ordinary logged shape. */
const OFFER_ROW = {
    responseId: 'a1A0000000000001AAA',
    responseName: 'RMR-0007',
    method: 'Offer',
    brokerName: 'Derek Simmons',
    notes: 'Verbal at 4.2m, 6.1 cap.',
    entryDateTime: '2026-03-11T14:05:00.000Z'
};

/** A response with NO notes and NO broker — both reachable and both normal. */
const BARE_ROW = {
    responseId: 'a1A0000000000002AAA',
    responseName: 'RMR-0008',
    method: 'More questions',
    // The service's fixed placeholder, never a blank — a blank cell reads as a
    // rendering failure rather than as missing data.
    brokerName: 'No broker recorded',
    notes: null,
    entryDateTime: '2026-03-05T09:30:00.000Z'
};

/** Broker resolved, may log, two rows already recorded (newest first). */
const CONTEXT = {
    brokerId: '003000000000001AAA',
    brokerName: 'Derek Simmons',
    brokerSource: 'From the selected BOV submission',
    isOnMarket: true,
    canLog: true,
    responses: [OFFER_ROW, BARE_ROW]
};

/** No broker appointed yet — `brokerId` null, `brokerName` '' (NEVER null). */
const NO_BROKER_CONTEXT = {
    ...CONTEXT,
    brokerId: null,
    brokerName: '',
    responses: []
};

/** A read-only persona: sees the log, is offered no way to add to it. */
const READ_ONLY_CONTEXT = { ...CONTEXT, canLog: false };

/** Nothing logged yet — the ordinary state the day materials go out. */
const EMPTY_CONTEXT = { ...CONTEXT, responses: [] };

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-release-materials-response-log', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-release-materials-response-log', {
            is: ReleaseMaterialsResponseLog
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const q = (element, selector) => element.shadowRoot.querySelector(selector);
    const all = (element, selector) => [...element.shadowRoot.querySelectorAll(selector)];
    const title = (element) => q(element, 'span[slot="title"]').textContent.trim();
    const tiles = (element) => all(element, '.rmr-tile');

    /** Opens the inline form and waits for the re-render. */
    async function openForm(element) {
        q(element, '[data-open]').click();
        await Promise.resolve();
    }

    /** Picks a method on the combobox stub the way the real component does. */
    async function chooseMethod(element, value) {
        q(element, '[data-method]').dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        await Promise.resolve();
    }

    async function typeNotes(element, value) {
        q(element, '[data-notes]').dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        await Promise.resolve();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // CHROME AND BRANCHES
    // ═════════════════════════════════════════════════════════════════════════

    it('BEFORE THE WIRE ANSWERS: the titled card renders, but it claims nothing', async () => {
        const element = createComponent();

        await Promise.resolve();

        // 🔴 A PREMATURE "(0)" WOULD STATE, IN THE SAME WORDS IT USES FOR A
        // GENUINELY EMPTY SALE, THAT NOBODY HAS RESPONDED. Nothing is known yet.
        expect(title(element)).toBe('Release materials responses');
        expect(q(element, '.rmr-empty')).toBeNull();
        expect(q(element, '[data-open]')).toBeNull();
        expect(tiles(element)).toHaveLength(0);
    });

    it('HEADER: the count appears once the wire answers, and it counts the logged rows', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        expect(title(element)).toBe('Release materials responses (2)');
        expect(q(element, 'lightning-card').iconName).toBe('standard:feedback');
        expect(tiles(element)).toHaveLength(2);
    });

    it('EMPTY BRANCH: an empty log renders an empty STATUS, not an error', async () => {
        const element = createComponent();

        getLogContext.emit(EMPTY_CONTEXT);
        await Promise.resolve();

        const empty = q(element, '.rmr-empty');
        expect(empty).not.toBeNull();
        // `status`, not `alert`: nothing having come back yet is the ordinary
        // state of a sale the day materials go out, not a problem.
        expect(empty.getAttribute('role')).toBe('status');
        expect(q(element, '.rmr-empty-text').textContent.trim()).toBe('No responses yet');
        expect(q(element, '.lv-error')).toBeNull();
        // The opener is still there — an empty log is exactly when you log one.
        expect(q(element, '[data-open]')).not.toBeNull();
    });

    it('🔴 ERROR BRANCH: a visible alert — never a silent blank card', async () => {
        const element = createComponent();

        getLogContext.error();
        await Promise.resolve();

        const alert = q(element, '.rmr-error');
        expect(alert).not.toBeNull();
        expect(alert.getAttribute('role')).toBe('alert');
        // Uses the cross-bundle banner class shared with recentLeads /
        // renewalList / competingBrokerSubmissions / dispositionBuyerTimeline.
        expect(alert.classList.contains('lv-error')).toBe(true);
        // 🔴 AN EMPTY LOG ON A SALE WITH THREE LOGGED RESPONSES IS A CONFIDENT
        // WRONG ANSWER. Neither the tiles, the empty state, nor the form may
        // appear on the error branch.
        expect(tiles(element)).toHaveLength(0);
        expect(q(element, '.rmr-empty')).toBeNull();
        expect(q(element, '[data-open]')).toBeNull();
        expect(q(element, '[data-broker]')).toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 "RESPONSE FROM" — RESOLVED, DISPLAYED, NEVER PICKED
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 BROKER: rendered read-only with its source line — and there is NO picker', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);

        const broker = q(element, '[data-broker]');
        expect(broker.querySelector('.rmr-readonly-label').textContent.trim()).toBe(
            'Response from'
        );
        expect(broker.querySelector('.rmr-readonly-value').textContent.trim()).toBe(
            'Derek Simmons'
        );
        // The source line tells the analyst WHY that name is there — two record
        // types, two sources, two different screens to go and change it on.
        expect(broker.querySelector('.rmr-readonly-help').textContent.trim()).toBe(
            'From the selected BOV submission'
        );
        expect(q(element, '[data-no-broker]')).toBeNull();

        // 🔴 NO CONTROL OF ANY KIND FOR THE BROKER. A disabled lookup still
        // looks like something somebody may enable, and there is exactly one
        // correct answer per sale.
        expect(q(element, 'lightning-record-picker')).toBeNull();
        expect(q(element, 'lightning-input-field')).toBeNull();
        expect(all(element, 'lightning-combobox')).toHaveLength(1);
    });

    it('🔴 THE FIELD ORDER IS Method, Response from, Notes — asserted in DOCUMENT order', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);

        // ⚠ ASSERTED BY WALKING THE RENDERED TREE, not by reading the template.
        // "Response from" is the read-only block and is second in READING order
        // even though it is not a control — that is the requirement, and a
        // per-element querySelector could not express it.
        const labelled = all(
            element,
            '.rmr-readonly-label, lightning-combobox, lightning-textarea'
        ).map((el) => el.label || el.textContent.trim());
        expect(labelled).toEqual(['Method', 'Response from', 'Notes']);
    });

    /**
     * 🔴 THE 2026-08-24 INSTRUCTION: *"If no broker is resolvable, still allow
     * the entry with a blank broker rather than blocking the log; say so."*
     * This is the OPPOSITE of `c/dispositionLogOfferModal`, which renders a
     * refusal panel with no form at all.
     */
    it('🔴 NO BROKER: the card SAYS SO before you open the form, and still lets you log', async () => {
        const element = createComponent();

        getLogContext.emit(NO_BROKER_CONTEXT);
        await Promise.resolve();

        // 1. THE CARD-LEVEL NOTICE — "say so in the header". The user needs to
        //    know BEFORE deciding to log, not after opening the form.
        const notice = q(element, '[data-no-broker-notice]');
        expect(notice).not.toBeNull();
        expect(notice.textContent.replace(/\s+/g, ' ').trim()).toBe(
            'No broker is appointed on this sale yet. Responses logged now are recorded without one.'
        );
        // `status`, not `alert` — a sale with no appointed broker yet is a
        // normal stage, not a problem.
        expect(notice.getAttribute('role')).toBe('status');

        // 2. 🔴 AND IT DOES NOT BLOCK. The opener is present and the form opens —
        //    the OPPOSITE of c/dispositionLogOfferModal, which renders a refusal
        //    panel with no form at all.
        expect(q(element, '[data-open]')).not.toBeNull();
        await openForm(element);
        expect(q(element, '[data-form]')).not.toBeNull();
        expect(q(element, '[data-method]')).not.toBeNull();

        // 3. INSIDE THE FORM, the absence is stated in words in the "Response
        //    from" slot. A blank value under that label is indistinguishable
        //    from a rendering failure.
        const absent = q(element, '[data-no-broker]');
        expect(absent).not.toBeNull();
        expect(absent.textContent.trim()).toBe('No broker appointed yet');
        // and it still names WHERE a broker would come from, which is what
        // makes the message actionable rather than merely honest.
        expect(q(element, '.rmr-readonly-help').textContent).toContain(
            'From the selected BOV submission'
        );

        // 4. ⚠ AND THE TWO NEVER RENDER TOGETHER. The same sentence twice on one
        //    small card reads as an error rather than as emphasis.
        expect(q(element, '[data-no-broker-notice]')).toBeNull();
    });

    it('NO BROKER: the card-level notice is not shown to a persona who cannot log', async () => {
        const element = createComponent();

        getLogContext.emit({ ...NO_BROKER_CONTEXT, canLog: false });
        await Promise.resolve();

        // The line warns someone about to RECORD something. A read-only viewer
        // is not, so for them it is noise about a decision they cannot take.
        expect(q(element, '[data-no-broker-notice]')).toBeNull();
        expect(q(element, '[data-open]')).toBeNull();
    });

    it('BROKER RESOLVED: no card-level notice at all', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        expect(q(element, '[data-no-broker-notice]')).toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // THE FORM AND THE SAVE
    // ═════════════════════════════════════════════════════════════════════════

    it('FORM: closed by default, opens on the button, closes on Cancel', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        expect(q(element, '[data-form]')).toBeNull();

        await openForm(element);
        expect(q(element, '[data-form]')).not.toBeNull();
        // The opener is replaced by the form, not shown beside it.
        expect(q(element, '[data-open]')).toBeNull();

        q(element, '[data-cancel]').click();
        await Promise.resolve();
        expect(q(element, '[data-form]')).toBeNull();
        expect(q(element, '[data-open]')).not.toBeNull();
    });

    it('FORM: the method combobox offers exactly the three restricted values', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);

        // 🔴 THESE MUST MATCH Method__c's value set EXACTLY, including the space
        // and the lower-case "q" in "More questions". The value set is
        // `restricted` and Apex DML enforces it, so a typo here does not corrupt
        // data — it produces a Save button that always fails.
        expect(q(element, '[data-method]').options.map((o) => o.value)).toEqual([
            'More questions',
            'Decision',
            'Offer'
        ]);
        expect(q(element, '[data-method]').required).toBe(true);
    });

    it('FORM: Save is disabled until a method is chosen', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);

        // ⚠ ASSERTED ON THE RENDERED STUB'S `disabled` PROPERTY, not on the
        // getter — a getter-only assertion has passed in this repo while the
        // rendered output was wrong.
        expect(q(element, '[data-save]').disabled).toBe(true);

        await chooseMethod(element, 'Decision');
        expect(q(element, '[data-save]').disabled).toBe(false);
    });

    /**
     * 🔴 THE HEADLINE TEST OF THIS FILE. The payload carries the disposition,
     * the method and the notes — AND NOTHING ELSE.
     * ⚠ THE ASSERTION IS ON THE EXACT ARGUMENT OBJECT, NOT `toHaveBeenCalled`.
     * A re-added `brokerId` — the single most likely "helpful" edit to this
     * component — would sail through any looser check, and it would reopen the
     * forgeable-attribution hole the server-side resolution exists to close.
     */
    it('🔴 SAVE: sends dispositionId, method and notes — and NO broker', async () => {
        saveResponse.mockResolvedValue(undefined);
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);
        await chooseMethod(element, 'Offer');
        await typeNotes(element, 'Verbal at 4.2m.');

        q(element, '[data-save]').click();
        await flushPromises();

        expect(saveResponse).toHaveBeenCalledTimes(1);
        expect(saveResponse).toHaveBeenCalledWith({
            dispositionId: RECORD_ID,
            method: 'Offer',
            notes: 'Verbal at 4.2m.'
        });
        // Belt and braces, stated as its own claim so a failure names the cause:
        // the payload has exactly three keys and none of them is a broker.
        const payload = saveResponse.mock.calls[0][0];
        expect(Object.keys(payload).sort()).toEqual([
            'dispositionId',
            'method',
            'notes'
        ]);
    });

    it('SAVE: notes are optional — an untouched textarea still saves', async () => {
        saveResponse.mockResolvedValue(undefined);
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);
        await chooseMethod(element, 'Decision');

        q(element, '[data-save]').click();
        await flushPromises();

        expect(saveResponse).toHaveBeenCalledWith({
            dispositionId: RECORD_ID,
            method: 'Decision',
            notes: ''
        });
    });

    it('SAVE: success closes the form and raises a success toast', async () => {
        saveResponse.mockResolvedValue(undefined);
        const element = createComponent();
        const toasts = [];
        element.addEventListener('lightning__showtoast', (e) => toasts.push(e.detail));

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);
        await chooseMethod(element, 'Offer');

        q(element, '[data-save]').click();
        await flushPromises();

        expect(toasts).toHaveLength(1);
        expect(toasts[0].variant).toBe('success');
        expect(toasts[0].title).toBe('Response logged');
        expect(q(element, '[data-form]')).toBeNull();
        expect(q(element, '[data-open]')).not.toBeNull();
    });

    /**
     * 🔴 THE SERVER'S OWN MESSAGE REACHES THE USER. The controller surfaces an
     * authored, user-fixable sentence VERBATIM for an input problem and a fixed
     * generic sentence for anything else — swallowing either into a house string
     * throws away the only actionable half.
     */
    it('🔴 SAVE: a failure surfaces the SERVER message and leaves the form open', async () => {
        saveResponse.mockRejectedValue({
            body: { message: 'Pick how this response arrived: More questions, Decision, or Offer.' }
        });
        const element = createComponent();
        const toasts = [];
        element.addEventListener('lightning__showtoast', (e) => toasts.push(e.detail));

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);
        await chooseMethod(element, 'Offer');

        q(element, '[data-save]').click();
        await flushPromises();

        expect(toasts).toHaveLength(1);
        expect(toasts[0].variant).toBe('error');
        expect(toasts[0].message).toBe(
            'Pick how this response arrived: More questions, Decision, or Offer.'
        );
        // 🔴 THE FORM STAYS OPEN. Closing it on failure would throw away what
        // the user typed AND leave them looking at a card that shows no sign of
        // the attempt.
        expect(q(element, '[data-form]')).not.toBeNull();
        expect(q(element, '[data-method]').value).toBe('Offer');
    });

    it('SAVE: a save in flight disables both buttons, so a double click cannot log twice', async () => {
        let release;
        saveResponse.mockReturnValue(new Promise((resolve) => {
            release = resolve;
        }));
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);
        await chooseMethod(element, 'Offer');

        q(element, '[data-save]').click();
        await Promise.resolve();

        expect(q(element, '[data-save]').disabled).toBe(true);
        expect(q(element, '[data-cancel]').disabled).toBe(true);

        release(undefined);
        await flushPromises();
        expect(saveResponse).toHaveBeenCalledTimes(1);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 canLog — AN AFFORDANCE, NOT A GUARD
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 READ-ONLY PERSONA: no opener, but the log itself still renders', async () => {
        const element = createComponent();

        getLogContext.emit(READ_ONLY_CONTEXT);
        await Promise.resolve();

        // A Save button that is always refused is worse than no button.
        expect(q(element, '[data-open]')).toBeNull();
        expect(q(element, '[data-form]')).toBeNull();
        // 🔴 BUT THE LOG IS NOT HIDDEN. A view persona holds viewAllRecords on a
        // Private object and is entitled to read every row.
        expect(tiles(element)).toHaveLength(2);
        // ⚠ AND NO "Response from" BLOCK EITHER — it lives inside the form,
        // which this persona never gets. The broker is a property of the entry
        // being composed, and they are not composing one.
        expect(q(element, '[data-broker]')).toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // THE LOGGED ROWS
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 LIST: rows render in SERVER order — newest first — and this component does not sort', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        expect(all(element, '.rmr-name').map((el) => el.textContent.trim())).toEqual([
            'RMR-0007',
            'RMR-0008'
        ]);
        // Reversing the payload reverses the render — which is what "does not
        // sort" means, and is why this fixture's order is not alphabetical by
        // accident.
        expect(q(element, '.rmr-list').getAttribute('role')).toBe('list');
        expect(q(element, '.rmr-list').getAttribute('aria-label')).toBe('Logged responses');
    });

    it('LIST: a row shows its number, method, broker, timestamp and notes', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const tile = tiles(element)[0];
        expect(tile.querySelector('.rmr-name').textContent.trim()).toBe('RMR-0007');
        // ⚠ THE METHOD TRAVELS AS READABLE TEXT INSIDE THE BADGE, never as a
        // colour alone. A text->badge->icon swap that deletes this word fails
        // HERE rather than silently in production.
        expect(tile.querySelector('[data-method-badge]').textContent.trim()).toBe('Offer');
        expect(tile.querySelector('.rmr-broker-line').textContent.trim()).toBe(
            'Derek Simmons'
        );
        expect(tile.querySelector('.rmr-notes').textContent.trim()).toBe(
            'Verbal at 4.2m, 6.1 cap.'
        );

        // 🔴 ASSERTED ON THE STUB'S `value` PROPERTY. The sfdx-lwc-jest stub for
        // a lightning base component renders an EMPTY template, so a
        // `textContent` assertion here would be vacuously green whether or not
        // the timestamp was passed through at all.
        expect(tile.querySelector('[data-received]').value).toBe(
            '2026-03-11T14:05:00.000Z'
        );

        const labels = [...tile.querySelectorAll('dt')].map((d) => d.textContent.trim());
        expect(labels).toEqual(['Received', 'Notes']);
    });

    it('LIST: a row with no notes renders an em-dash, never a blank cell', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const bare = tiles(element)[1];
        expect(bare.querySelector('.rmr-notes').textContent.trim()).toBe(EM_DASH);
        expect(bare.querySelector('.rmr-broker-line').textContent.trim()).toBe(
            'No broker recorded'
        );
    });

    it('LIST: each row carries an accessible name naming the response, method and broker', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const tile = tiles(element)[0];
        // ⚠ role="group" SITS ON THIS INNER DIV, NOT ON THE <li>. On the <li> it
        // would REPLACE the implicit `listitem` role and axe's `list` rule would
        // then report the <ul> as having a disallowed child.
        expect(tile.getAttribute('role')).toBe('group');
        expect(tile.tagName.toLowerCase()).toBe('div');
        expect(tile.parentElement.tagName.toLowerCase()).toBe('li');
        const label = tile.getAttribute('aria-label');
        expect(label).toContain('RMR-0007');
        expect(label).toContain('Offer');
        expect(label).toContain('Derek Simmons');
    });

    // ═════════════════════════════════════════════════════════════════════════
    // ACCESSIBILITY
    // ═════════════════════════════════════════════════════════════════════════

    it('is accessible with rows', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible with the form open', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);

        await expect(element).toBeAccessible();
    });

    it('is accessible on the empty state', async () => {
        const element = createComponent();

        getLogContext.emit(EMPTY_CONTEXT);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
