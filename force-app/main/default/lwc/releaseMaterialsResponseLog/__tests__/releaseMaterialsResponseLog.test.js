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
 * value was ever passed. `lightning-button.disabled` and
 * `lightning-combobox.options` are read directly for that reason.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 2026-08-25 — THE LOG BECAME `<c-list-datatable>`, AND THAT CHANGED WHAT
 *    THIS FILE IS ABLE TO ASSERT. READ THIS BEFORE "STRENGTHENING" ANYTHING.
 * ═══════════════════════════════════════════════════════════════════════════
 * The logged responses used to render as a `<ul>` of hand-rolled tiles, so the
 * old LIST tests read `.rmr-name`, `[data-method-badge]`, `.rmr-notes` and `dt`
 * TEXT out of this component's own shadow root. They are gone, and the reason
 * they could not simply be kept is measured, not assumed:
 *
 *   `c-list-datatable` extends `lightning/datatable`, and sfdx-lwc-jest stubs
 *   that base with an EMPTY TEMPLATE — its own test file says so in its header.
 *   Nothing inside the element renders. Every `textContent` assertion against it
 *   would be VACUOUSLY GREEN, passing identically if the component were deleted.
 *
 * So the list is now pinned the way the rest of this file already pins a stubbed
 * child — on the RENDERED ELEMENT'S PROPERTIES (`.data`, `.columns`, `.keyField`)
 * — plus an absence scan proving the tile markup is really gone rather than
 * duplicated. 🔴 DO NOT "IMPROVE" THESE BACK INTO textContent CHECKS; they would
 * all pass and none of them would mean anything.
 *
 * ⚠ TWO REAL COVERAGE LOSSES, STATED PLAINLY RATHER THAN PAPERED OVER:
 *   1. `@sa11y/jest` sees an empty stub where the table is, so the three
 *      accessibility tests below no longer cover the ROW markup at all. What
 *      they still cover — the card, the form, and the empty-log branch's
 *      chrome — is what this component actually authors; the table's
 *      semantics belong to the base component. The `is accessible with rows`
 *      test is KEPT anyway because it still proves the surrounding chrome
 *      survives a populated wire.
 *   2. The per-row accessible name (`rowLabel`) is gone with the tiles. A
 *      datatable names its rows from its column headers, which is the platform's
 *      job, not ours — so the getter that built it was deleted rather than left
 *      computing a string nothing reads.
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

/**
 * 🔴 THREE ROWS IN AN ORDER NO CLIENT-SIDE SORT CAN REPRODUCE. This fixture IS
 * the falsifier for "this component does not sort", and it exists because the
 * obvious two-row fixture is not one.
 *
 * MEASURED 2026-08-25: with `CONTEXT` (RMR-0007 then RMR-0008) a mutation that
 * added `.sort()` by responseName ascending produced the IDENTICAL rendered
 * order, so the order test — and the tile-era test it replaced — passed on a
 * component that had started sorting. The server's order and the sorted order
 * were the same sequence.
 *
 * The order below is deliberately NON-MONOTONIC IN BOTH plausible keys:
 *   by name  → 0008, 0009, 0010 (asc) / 0010, 0009, 0008 (desc) — neither matches
 *   by date  → 0009, 0008, 0010 (asc) / 0010, 0008, 0009 (desc) — neither matches
 * so any single-key sort in either direction reds the assertion. The real server
 * order is `Entry_DateTime__c DESC NULLS LAST, Name DESC`; this fixture is not
 * that sequence either, on purpose — the component's job is to preserve WHATEVER
 * arrives, not to re-derive the selector's rule.
 */
const SCRAMBLED_CONTEXT = {
    ...CONTEXT,
    responses: [
        { ...BARE_ROW, responseId: 'a1B1', responseName: 'RMR-0008', entryDateTime: '2026-03-05T09:30:00.000Z' },
        { ...BARE_ROW, responseId: 'a1B2', responseName: 'RMR-0010', entryDateTime: '2026-03-11T09:30:00.000Z' },
        { ...BARE_ROW, responseId: 'a1B3', responseName: 'RMR-0009', entryDateTime: '2026-03-02T09:30:00.000Z' }
    ]
};

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

    /**
     * The rendered `<c-list-datatable>`, or null.
     *
     * ⚠ `[data-log]` AND NOT THE TAG NAME. The tag would also match a second
     * datatable added elsewhere in the card; the attribute names THIS one.
     */
    const logTable = (element) => q(element, '[data-log]');

    /** The rows the datatable was actually handed. `[]` when it is not rendered. */
    const logRows = (element) => {
        const table = logTable(element);
        return table ? table.data : [];
    };

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
        expect(q(element, '[data-open]')).toBeNull();
        // 🔴 AND SINCE 2026-08-25 THE GRID CARRIES THAT CLAIM TOO. The hardcoded
        // "No responses yet" block is gone, so an empty datatable is now HOW this
        // card says nothing has come back — which makes rendering one before the
        // wire answers the same premature claim as a "(0)" in the title.
        // `showTable` is `hasEntries || isEmpty`, both gated on `hasContext`.
        expect(logTable(element)).toBeNull();
    });

    it('HEADER: the count appears once the wire answers, and it counts the logged rows', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        expect(title(element)).toBe('Release materials responses (2)');
        expect(q(element, 'lightning-card').iconName).toBe('standard:feedback');
        expect(logRows(element)).toHaveLength(2);
    });

    /**
     * 🔴 REWRITTEN 2026-08-25 — THE HARDCODED EMPTY STATE WAS REMOVED ON USER
     * INSTRUCTION. This test used to pin the words "No responses yet" and their
     * explanatory second line. The contract it pins now is the replacement one:
     * an empty log renders THE DATATABLE ITSELF, with its columns and an empty
     * `data` array, so the card reads as empty the same way every other card on
     * this page does — column headers over no rows.
     *
     * ⚠ THE COLUMNS HALF IS LOAD-BEARING, not decoration. `data: []` alone is
     * also what a datatable handed nothing at all looks like; without the column
     * assertion this test would pass on a card that renders a blank grid with no
     * headers, which is the very "confident blank" the deleted text guarded
     * against.
     */
    it('EMPTY BRANCH: an empty log renders the TABLE — headers, no rows — and no error', async () => {
        const element = createComponent();

        getLogContext.emit(EMPTY_CONTEXT);
        await Promise.resolve();

        const table = logTable(element);
        expect(table).not.toBeNull();
        expect(logRows(element)).toEqual([]);
        // The headers are what state the emptiness, so they must be there.
        expect(table.columns.length).toBeGreaterThan(0);
        // The deleted block, pinned as an absence so it cannot quietly return.
        expect(q(element, '.rmr-empty')).toBeNull();
        expect(q(element, '.rmr-empty-text')).toBeNull();
        expect(q(element, '.rmr-empty-sub')).toBeNull();
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
        // WRONG ANSWER — and since 2026-08-25 an EMPTY TABLE is exactly how this
        // card states an empty log, so the table is the thing that must not
        // appear here. Nor may the form.
        expect(logTable(element)).toBeNull();
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
        expect(logRows(element)).toHaveLength(2);
        // ⚠ AND NO "Response from" BLOCK EITHER — it lives inside the form,
        // which this persona never gets. The broker is a property of the entry
        // being composed, and they are not composing one.
        expect(q(element, '[data-broker]')).toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // THE LOGGED ROWS — NOW `<c-list-datatable>`
    //
    // 🔴 ASSERTED ON THE RENDERED ELEMENT'S PROPERTIES, NOT ON ITS TEXT. The
    // sfdx-lwc-jest `lightning/datatable` stub renders an empty template and
    // `c-list-datatable` extends it, so `textContent` here is `''` whatever the
    // data is. See this file's header for the full note.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 LIST: the log renders through c-list-datatable — loiCounterOffer’s own history component', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const table = logTable(element);
        expect(table).not.toBeNull();
        expect(table.tagName.toLowerCase()).toBe('c-list-datatable');
        // The wiring loiCounterOffer uses, per attribute. `keyField` must name a
        // property that exists on every row or the datatable re-creates every row
        // on each re-render and loses selection/scroll state.
        expect(table.keyField).toBe('id');
        expect(logRows(element).every((r) => typeof r.id === 'string')).toBe(true);
        expect(table.hideCheckboxColumn).toBe(true);
        expect(table.showRowNumberColumn).toBe(true);
    });

    /**
     * 🔴 THE TILES ARE GONE — AN ABSENCE PIN WITH ITS OWN PRESENCE CONTROL.
     *
     * ⚠ A TAG/SELECTOR SCAN, NEVER A textContent CHECK. A child component's shadow
     * text never reaches this shadow root (measured in this repo: it returns ''),
     * so an absence assertion written as `not.toContain('RMR-0007')` would be
     * green whatever renders.
     * ⚠ AND THE PRESENCE HALF IS LOAD-BEARING. Without it this test passes on a
     * component that renders nothing at all — which is exactly what a broken
     * `showTable` would produce.
     */
    it('🔴 LIST: the hand-rolled tile markup is gone, not duplicated beside the table', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        // PRESENCE first, so the absences below cannot be satisfied by an empty card.
        expect(logRows(element)).toHaveLength(2);

        ['.rmr-list', '.rmr-tile', '.rmr-tile-head', '.rmr-name', '.rmr-broker-line',
         '.rmr-facts', '.rmr-notes', '[data-method-badge]', '[data-received]',
         'ul', 'li', 'dl', 'dt', 'dd'].forEach((selector) => {
            expect({ selector, found: all(element, selector).length }).toEqual({
                selector,
                found: 0
            });
        });
    });

    it('🔴 LIST: rows are handed over in SERVER order — newest first — and this component does not sort', async () => {
        const element = createComponent();

        getLogContext.emit(SCRAMBLED_CONTEXT);
        await Promise.resolve();

        // 🔴 THE ORDER ASSERTED HERE IS ONE NO CLIENT-SIDE SORT CAN PRODUCE. See
        // SCRAMBLED_CONTEXT: it is non-monotonic in BOTH plausible sort keys, so
        // adding `.sort()` on name or on date, ascending or descending, reds this
        // line. MEASURED: with the ordinary two-row CONTEXT (RMR-0007 then
        // RMR-0008) a `.sort()` by name ascending produced the IDENTICAL order and
        // this test — and the tile-era test it replaced — stayed GREEN AND
        // VACUOUS. The fixture is the assertion here; do not "simplify" it back.
        expect(logRows(element).map((r) => r.responseName)).toEqual([
            'RMR-0008',
            'RMR-0010',
            'RMR-0009'
        ]);
        // 🔴 AND NO COLUMN OFFERS A SORT. loiCounterOffer's columns are `sortable`
        // and it re-sorts client-side; copying that here would put a second sort
        // on rows the selector has already ordered, free to disagree with it.
        // There is also no `onsort` handler to honour one.
        expect(
            logTable(element).columns.filter((c) => c.sortable)
        ).toEqual([]);
        expect(logTable(element).sortedBy).toBeUndefined();
    });

    /**
     * 🔴 THE COLUMN DEFINITION IS THE RENDERED CONTRACT NOW.
     *
     * With the cells unrenderable under Jest, the columns array is where "the
     * same fields, in this order" lives. Asserted as ONE ordered list rather than
     * per-column, because a reorder is exactly the regression a set of individual
     * lookups cannot see.
     */
    it('🔴 LIST: the columns are Response, Method, Response from, Notes, Received — in that order', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const columns = logTable(element).columns;
        expect(columns.map((c) => c.label)).toEqual([
            'Response',
            'Method',
            'Response from',
            'Notes',
            'Received'
        ]);
        expect(columns.map((c) => c.fieldName)).toEqual([
            'responseName',
            'method',
            'brokerName',
            'notes',
            'entryDateTime'
        ]);

        const byField = Object.fromEntries(columns.map((c) => [c.fieldName, c]));

        // 🔴 THE NOTES COLUMN IS loiCounterOffer's "Counter Response" COLUMN,
        // COPIED. `Counter_Offer__c.Counter_Response__c` and
        // `Release_Materials_Response__c.Notes__c` are the same field definition —
        // LongTextArea, length 32768, visibleLines 3 — so the idiom that carries
        // one carries the other: wrapText, and NO initialWidth so the column
        // absorbs the remaining width in the datatable's fixed layout.
        expect(byField.notes.wrapText).toBe(true);
        expect(byField.notes.initialWidth).toBeUndefined();

        // ⚠ `date`, NOT `date-local`. Entry_DateTime__c is a DateTime — an
        // unambiguous instant, correctly rendered in the viewer's timezone.
        // `date-local` (which loiCounterOffer correctly uses for its Apex DATE)
        // would render the DAY BEFORE for any viewer west of Greenwich.
        expect(byField.entryDateTime.type).toBe('date');
        expect(byField.entryDateTime.typeAttributes).toEqual({
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        });

        // The method is the `pill` custom cell type c/listDatatable registers —
        // the datatable-native replacement for the tiles' `slds-badge`.
        expect(byField.method.type).toBe('pill');
        expect(byField.method.typeAttributes).toEqual({
            wrapStyle: { fieldName: 'methodWrap' },
            dotStyle: { fieldName: 'methodDot' }
        });
    });

    it('LIST: a row carries its number, method, broker, notes and raw timestamp', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const row = logRows(element)[0];
        expect(row.responseName).toBe('RMR-0007');
        // ⚠ THE METHOD TRAVELS AS THE READABLE WORD, never as a colour alone. The
        // `pill` template renders `{value}` beside the dot, so this string IS what
        // the user reads — a swap to a colour-only marker fails HERE.
        expect(row.method).toBe('Offer');
        expect(row.brokerName).toBe('Derek Simmons');
        expect(row.notes).toBe('Verbal at 4.2m, 6.1 cap.');
        // 🔴 PASSED RAW, NOT PRE-FORMATTED. The `date` column formats it; a
        // formatted string here would be formatted twice and render as NaN.
        expect(row.entryDateTime).toBe('2026-03-11T14:05:00.000Z');
    });

    it('LIST: a row with no notes carries an em-dash, never a blank', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const bare = logRows(element)[1];
        expect(bare.notes).toBe(EM_DASH);
        // The server's fixed placeholder for a response logged without a broker —
        // never a blank, which would read as a rendering failure.
        expect(bare.brokerName).toBe('No broker recorded');
    });

    /**
     * 🔴 DARK MODE, RELOCATED WITH THE BADGE.
     *
     * The method's colours used to live in the stylesheet, where the T-CSS test
     * below asserts every colour comes from a styling hook. Moving the badge into
     * the datatable moved those colours into INLINE STYLE STRINGS BUILT IN THE JS
     * — out of that test's reach — so the pin follows them here, onto the rendered
     * row data.
     * ⚠ NOTHING ELSE IN THIS PIPELINE CATCHES A DARK-MODE FAILURE: the SLDS linter
     * only checks CSS files, and axe's colour-contrast rule is inert in jsdom.
     * ⚠ AND THIS IS A DELIBERATE DEPARTURE FROM THE SIXTEEN OTHER `pillWrap`
     * HELPERS IN THIS REPO, loiCounterOffer's included — every one hardcodes raw
     * hex. A reviewer will read that as inconsistency; it is the bundle's existing
     * dark-mode claim being kept true.
     */
    it('🔴 LIST: every method pill colour is a styling hook, per method, not a raw hex', async () => {
        const element = createComponent();

        getLogContext.emit({
            ...CONTEXT,
            responses: [
                { ...OFFER_ROW, method: 'Offer' },
                { ...BARE_ROW, method: 'Decision' },
                { ...BARE_ROW, responseId: 'a1A3', method: 'More questions' },
                // A value this client does not know, and a null — both must still
                // produce a complete, hook-based pill rather than `undefined`.
                { ...BARE_ROW, responseId: 'a1A4', method: 'Carrier pigeon' },
                { ...BARE_ROW, responseId: 'a1A5', method: null }
            ]
        });
        await Promise.resolve();

        const rows = logRows(element);
        expect(rows).toHaveLength(5);
        // The unknown method and the null one are distinguishable in the DATA:
        // the word survives for the first, the em-dash stands in for the second.
        expect(rows.map((r) => r.method)).toEqual([
            'Offer',
            'Decision',
            'More questions',
            'Carrier pigeon',
            EM_DASH
        ]);

        rows.forEach((row) => {
            const declarations = `${row.methodWrap};${row.methodDot}`
                .split(';')
                .filter((d) => /^(background|color)\s*:/.test(d.trim()));
            // Two backgrounds (pill + dot) and one text colour on every row.
            expect(declarations).toHaveLength(3);
            declarations.forEach((declaration) => {
                expect(declaration.slice(declaration.indexOf(':') + 1).trim())
                    .toMatch(/^var\(--slds-/);
            });
        });

        // ⚠ AND THE FOUR PALETTES ARE ACTUALLY DIFFERENT. Without this the loop
        // above passes on a lookup that returned the neutral pill for everything —
        // a silent loss of the colour coding with every colour still "a hook".
        const backgrounds = rows.map((r) => r.methodWrap.split('background:')[1]);
        expect(new Set(backgrounds).size).toBe(4);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE loiCounterOffer IDIOM — ADDED BY THE 2026-08-24 THEMING PASS
    // ═════════════════════════════════════════════════════════════════════════
    // User instruction: *"make it the same as the LOI counter offers LWC"*. The
    // tests above this banner were ALL GREEN before and after that pass without a
    // single edit — which is the point of the ones below. Every structural fact
    // the pass established (where the opener lives, which button comes first,
    // which container class boxes the form, what the empty state is made of) was
    // invisible to the existing suite, so a later "tidy-up" could revert the
    // whole thing and stay green.
    // 🔴 UPDATED 2026-08-25, WHEN THE SECOND HALF OF THE INSTRUCTION LANDED: the
    // log itself became `<c-list-datatable>`. Two pins here changed with it — the
    // `slds-box` container test no longer has tiles to check, and the
    // `slds-badge` pin was REPLACED (not deleted) by the column-type and pill
    // colour assertions in the LIST section above. A retired pin has to be
    // replaced by the equivalent claim about the new shape, or the coverage
    // quietly leaves with the markup.
    // ⚠ EACH ONE WAS MUTATION-TESTED: the rule was broken, the test confirmed
    // RED, and the rule restored. A pin that never goes red is not a pin.

    it('🔴 IDIOM: the opener is a slot="actions" card button, not a button in the body', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const opener = q(element, '[data-open]');
        // 🔴 THE SLOT IS THE WHOLE POINT. loiCounterOffer puts its "Add" button
        // in the card header; this card used to put a full-width "Log a
        // response" button at the top of the body, which is the single loudest
        // "different component family" tell there was.
        expect(opener.getAttribute('slot')).toBe('actions');
        expect(opener.label).toBe('Add');
        expect(opener.iconName).toBe('utility:add');
        // ⚠ AND IT IS OUTSIDE THE PADDED BODY WRAPPER. Asserted by CONTAINMENT,
        // not by reading the template: a slot attribute on an element still
        // nested in the body would be ignored by lightning-card and the button
        // would render in the wrong place while the attribute assertion above
        // stayed green.
        const body = q(element, '.slds-p-horizontal_small');
        expect(body).not.toBeNull();
        expect(body.contains(opener)).toBe(false);
        expect(q(element, 'lightning-card').contains(opener)).toBe(true);
    });

    it('🔴 IDIOM: brand Save comes FIRST, neutral Cancel second, with an explicit right margin', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);

        // ⚠ ONE DOCUMENT-ORDER QUERY, not two querySelectors. Asserting each
        // button separately cannot express "Save is first" at all — and the old
        // markup had Cancel first, right-aligned, which is what this reverses.
        const buttons = all(element, '[data-save], [data-cancel]');
        expect(buttons.map((b) => b.label)).toEqual(['Save', 'Cancel']);
        expect(buttons[0].variant).toBe('brand');
        expect(buttons[1].variant).toBe('neutral');
        // 🔴 THE SEPARATION IS AN EXPLICIT MARGIN UTILITY, NOT RENDERED
        // WHITESPACE. The LWC compiler discards whitespace-only text nodes
        // between siblings, so without this class the two buttons touch.
        expect(buttons[0].classList.contains('slds-m-right_x-small')).toBe(true);
    });

    it('🔴 IDIOM: the entry form uses loiCounterOffer’s slds-box container', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);

        // The entry form is `slds-box slds-box_x-small` — the same container
        // class loiCounterOffer boxes its own entry form with. It replaced a
        // hand-rolled .rmr-form rule that re-implemented border, radius,
        // padding and background from raw styling hooks.
        const form = q(element, '[data-form]');
        expect(form.classList.contains('slds-box')).toBe(true);
        expect(form.classList.contains('slds-box_x-small')).toBe(true);
        expect(form.classList.contains('slds-m-bottom_small')).toBe(true);

        // ⚠ THE SECOND HALF OF THIS TEST IS GONE ON PURPOSE, NOT BY OVERSIGHT. It
        // asserted that every logged TILE carried the same box; the tiles were
        // replaced by `<c-list-datatable>` on 2026-08-25 and a datatable owns its
        // own row chrome. The claim that replaced it — that the log renders
        // through that component at all — is in the LIST section above, so the
        // "one family" fact is still pinned, just against the new shape.
        expect(logTable(element)).not.toBeNull();
    });

    it('🔴 IDIOM: form fields are separated by an explicit slds-m-top_x-small, never by whitespace', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();
        await openForm(element);

        // ⚠ THE FIRST FIELD MUST NOT HAVE IT (it would push the combobox off
        // the top of the box) and EVERY LATER ONE MUST. Measured four times
        // this week in this repo: two sibling tags render edge to edge because
        // the template compiler deletes the whitespace-only text node between
        // them, so this class IS the separation.
        expect(q(element, '[data-method]').classList.contains('slds-m-top_x-small')).toBe(
            false
        );
        expect(q(element, '[data-broker]').classList.contains('slds-m-top_x-small')).toBe(
            true
        );
        expect(q(element, '[data-notes]').classList.contains('slds-m-top_x-small')).toBe(
            true
        );
        // The read-only broker block is dressed as an SLDS form element so it
        // sits with the two controls around it rather than as loose text.
        expect(q(element, '[data-broker]').classList.contains('slds-form-element')).toBe(
            true
        );
    });

    /**
     * 🔴 THE SUCCESSOR TO THE RETIRED `slds-badge` PIN.
     *
     * Until 2026-08-25 this test read `[data-method-badge]` and asserted the
     * method rendered inside an `slds-badge` carrying its readable word. The badge
     * went with the tiles; loiCounterOffer's equivalent is the `pill` CUSTOM CELL
     * TYPE that `c/listDatatable` registers, and the word now travels as the
     * column's `value`.
     * ⚠ RETIRED, NOT DELETED. Both halves of the old claim are re-stated here
     * against the datatable — the method is a `pill` column, and the word is still
     * the data — because a pin that is removed along with its markup takes its
     * coverage with it and nothing says so.
     */
    it('🔴 IDIOM: the method is loiCounterOffer’s `pill` cell type, and the WORD is still the value', async () => {
        const element = createComponent();

        getLogContext.emit(CONTEXT);
        await Promise.resolve();

        const methodColumn = logTable(element).columns.find(
            (c) => c.fieldName === 'method'
        );
        expect(methodColumn.type).toBe('pill');
        // The pill template renders `{value}` beside the dot, so the row's
        // `method` string IS what the user reads. A colour-only marker fails here.
        expect(logRows(element)[0].method).toBe('Offer');
        // ⚠ AND THE STYLES THAT MAKE IT A PILL ARE ACTUALLY SUPPLIED. The custom
        // type resolves `wrapStyle`/`dotStyle` per row from the fieldNames above;
        // if the row data lacked them every pill would render unstyled and the
        // type assertion alone would still pass.
        expect(logRows(element)[0].methodWrap).toContain('border-radius');
        expect(logRows(element)[0].methodDot).toContain('border-radius');
    });

    /**
     * 🔴 THE HARDCODED EMPTY STATE IS GONE — A SOURCE-TEXT PIN, AND WHY IT HAS
     * TO BE ONE.
     *
     * Removed on user instruction 2026-08-25 (it had previously been kept, and
     * this test previously pinned its two muted lines). The absence cannot be
     * pinned on `textContent` alone the way the DOM assertions below it are: the
     * only remaining child in this branch is the stubbed datatable, whose shadow
     * text never reaches this root, so `not.toContain('No responses yet')` would
     * be green whatever the template said.
     *
     * ⚠ COMMENTS ARE STRIPPED FIRST, exactly as the T-CSS test strips the
     * stylesheet's. This template's own header NAMES the deleted strings in prose
     * to record what was removed and why — without the strip these assertions
     * would match that prose and fail for the wrong reason.
     * ⚠ AND THE DOM HALF IS THE GUARD-THE-GUARD: three absence assertions pass
     * perfectly on a component that renders NOTHING, so the table that replaced
     * the block is asserted present in the same test.
     */
    it('🔴 IDIOM: an empty log is the datatable itself — the hardcoded empty state is gone', async () => {
        const element = createComponent();

        getLogContext.emit(EMPTY_CONTEXT);
        await Promise.resolve();

        // PRESENCE first — this is what replaced the deleted block.
        expect(logTable(element)).not.toBeNull();
        expect(logRows(element)).toEqual([]);
        // ⚠ A TAG SCAN, NOT A textContent CHECK, for the old centred icon column.
        expect(all(element, 'lightning-icon')).toHaveLength(0);
        ['.rmr-empty', '.rmr-empty-text', '.rmr-empty-sub'].forEach((selector) => {
            expect({ selector, found: all(element, selector).length }).toEqual({
                selector,
                found: 0
            });
        });

        const HTML = require('fs')
            .readFileSync(
                require('path').join(__dirname, '..', 'releaseMaterialsResponseLog.html'),
                'utf8'
            )
            .replace(/<!--[\s\S]*?-->/g, '');

        expect(HTML).not.toContain('No responses yet');
        expect(HTML).not.toContain('Rows appear here as brokers respond');
        expect(HTML).not.toMatch(/rmr-empty/);
        // ⚠ THE STRIP ITSELF, PROVEN. If the regex above ever ate the whole file
        // the three assertions before it would be vacuously green.
        expect(HTML).toContain('c-list-datatable');
    });

    /**
     * 🔴 T-CSS — A SOURCE-TEXT PIN ON THE STYLESHEET.
     *
     * ⚠ `require`, NEVER an ESM `import { readFileSync } from 'fs'` — the LWC
     * compiler rejects that with LWC1702, which the editor surfaces as an error
     * with an EMPTY message. Every T-CSS file in this repo uses this form.
     * ⚠ COMMENTS ARE STRIPPED FIRST. This stylesheet's header NAMES every deleted
     * rule (.rmr-form, .rmr-badge, .rmr-list, .rmr-tile …) in prose to record what
     * moved to SLDS utilities or to the datatable — without the strip, the absence
     * assertions below would match that prose and fail for the wrong reason. This
     * has actually happened in this repo: a mutation string matched a header
     * comment instead of the markup and produced a fake green.
     * 🔴 DO NOT "IMPROVE" THIS INTO A MEASUREMENT: jsdom does no layout, so
     * getBoundingClientRect(), scrollWidth and clientWidth are all 0 and the
     * obvious assertion is `0 <= 0` — green whether or not the card overflows.
     *
     * 🔴 REWRITTEN 2026-08-25. The three `gap:` pins this test was built around
     * (.rmr-list, .rmr-tile-head, .rmr-facts) named rules that NO LONGER EXIST —
     * the tiles they spaced were replaced by `<c-list-datatable>`, which owns its
     * own row layout. Left as they were they would have failed; deleted silently
     * they would have taken a real claim with them. They are therefore INVERTED
     * into absence assertions: the ten tile rules must stay gone, because
     * re-adding any of them means somebody has put the hand-rolled list back
     * beside the datatable.
     */
    it('🔴 T-CSS: the tile rules stay deleted, and nothing re-implements an SLDS utility', () => {
        const CSS = require('fs')
            .readFileSync(
                require('path').join(__dirname, '..', 'releaseMaterialsResponseLog.css'),
                'utf8'
            )
            .replace(/\/\*[\s\S]*?\*\//g, '');

        // A selector-anchored slice, never a bare /margin:/ — an unanchored search
        // passes while any ONE copy survives, and a MISSING rule returns '' so
        // every assertion below it reds rather than silently matching somewhere
        // else in the file.
        // ⚠ indexOf, NOT a constructed RegExp: a `new RegExp('...\{...')` here
        // loses a backslash level depending on how the file is written and
        // silently matches NOTHING, which reads as "the rule is gone" — a green
        // absence assertion for the wrong reason.
        const rule = (selector) => {
            const at = CSS.indexOf(selector + ' {');
            return at < 0 ? '' : CSS.slice(at, CSS.indexOf('}', at));
        };

        // 🔴 THE TEN TILE RULES. Every one of them styled markup this component no
        // longer emits. Asserted as a named list so a failure says WHICH came
        // back, and with `\s*\{` so a mention inside a shorthand value cannot
        // match.
        [
            '.rmr-list', '.rmr-item', '.rmr-tile', '.rmr-tile-head', '.rmr-name',
            '.rmr-broker-line', '.rmr-facts', '.rmr-label', '.rmr-c', '.rmr-notes'
        ].forEach((selector) => {
            expect({ selector, present: new RegExp('\\' + selector + '\\s*\\{').test(CSS) })
                .toEqual({ selector, present: false });
        });

        // 🔴 AND THE RULES THE 2026-08-24 THEMING PASS DELETED MUST ALSO STAY
        // DELETED. Each one re-implemented an SLDS utility that the markup now
        // carries, and re-adding any of them re-creates the drift that made this
        // card read as a different component family.
        expect(CSS).not.toMatch(/\.rmr-form\s*\{/);
        expect(CSS).not.toMatch(/\.rmr-field\s*\{/);
        expect(CSS).not.toMatch(/\.rmr-actions\s*\{/);
        expect(CSS).not.toMatch(/\.rmr-badge\s*\{/);
        expect(CSS).not.toMatch(/\.rmr-body\s*\{/);

        // 🔴 AND THE EMPTY-STATE RULES, DELETED 2026-08-25 WITH THE MARKUP THEY
        // STYLED (the hardcoded "No responses yet" pair, removed on user
        // instruction). `.rmr-empty-sub`'s `max-width` measure used to be pinned
        // as a SURVIVING rule two blocks below; it is inverted here rather than
        // dropped, because a pin that disappears with its markup takes a real
        // claim with it and nothing says so.
        expect(CSS).not.toMatch(/\.rmr-empty/);

        // ⚠ THE GUARD-THE-GUARD. Twenty absence assertions in a row pass perfectly
        // on an EMPTY FILE, so the rules that must SURVIVE are named too — this is
        // what stops a future "the stylesheet is nearly empty, delete it" from
        // sailing through.
        expect(rule('.rmr-readonly-value')).toMatch(/font-weight:/);
        expect(rule('.rmr-readonly-value_empty')).toMatch(/font-style:\s*italic/);
        expect(rule('.rmr-readonly-help')).toMatch(/margin:/);
        expect(rule('.lv-error')).toMatch(/font-size:/);

        // No media query and no scroll container: a media query measures the
        // VIEWPORT, but the constraint on a card is its CONTAINER width. The
        // datatable handles its own horizontal overflow.
        expect(CSS).not.toMatch(/@media/);
        expect(CSS).not.toMatch(/overflow(-x)?\s*:\s*(auto|scroll)/);

        // 🔴 DARK MODE. NOTHING ELSE IN THIS PIPELINE CATCHES A DARK-MODE
        // FAILURE: the SLDS linter only checks that a hook was USED, Jest
        // asserts class names, and axe's colour-contrast rule is INERT in jsdom,
        // so toBeAccessible() passing is not evidence. A source-text assertion
        // on the comment-stripped stylesheet is the only automated falsifier.
        // Every colour must come from a global styling hook, which is what
        // makes it re-resolve under the dark theme; a raw literal does not.
        // ⚠ AND THIS FILE IS NO LONGER THE WHOLE STORY: the method pill's colours
        // moved into inline style strings in the JS when the badge became a
        // datatable cell. Their pin lives in the LIST section above — see
        // "every method pill colour is a styling hook". Deleting either half
        // leaves half the component's colour unchecked.
        const colourDecls = CSS.match(/(?:color|background|background-color|border-color):[^;]+;/g) || [];
        expect(colourDecls.length).toBeGreaterThan(0);
        colourDecls.forEach((decl) => {
            expect(decl.slice(decl.indexOf(':') + 1).trim()).toMatch(/^var\(--slds-/);
        });
        // ⚠ AND NOT `--slds-g-color-<semantic>-container-1`, WHICH IS A SOLID
        // DARK FILL, NOT A PALE TINT (#2e844a for success, #ba0517 for error).
        // The pale literal fallback written beside it describes only the
        // hook-UNDEFINED case, so a file using it reads as correct while
        // rendering dark-on-dark. The safe tint pairing is `-base-95` +
        // `-base-30`, which is exactly what the method pills use.
        expect(CSS).not.toMatch(/container-1/);

        // ⚠ :host CARRIES NO TOP MARGIN OR BORDER, despite loiCounterOffer's
        // :host rule having both. This card is a child of c/dispositionMain,
        // whose own :host owns the stack `gap` for every card at every stage and
        // whose stylesheet says in terms: do not add per-card margins on top of
        // it — they double up.
        expect(rule(':host')).not.toMatch(/margin/);
        expect(rule(':host')).not.toMatch(/border/);
        // Kept for the .lv-error banner, whose text is a SERVER message this
        // component cannot pre-wrap: only `anywhere` affects min-content sizing.
        expect(rule(':host')).toMatch(/overflow-wrap:\s*anywhere/);
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

    it('is accessible with an empty log', async () => {
        const element = createComponent();

        getLogContext.emit(EMPTY_CONTEXT);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
