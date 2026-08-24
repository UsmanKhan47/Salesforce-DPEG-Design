/**
 * c-disposition-offer-select — LDS RELATED-LIST read + IMPERATIVE Apex write.
 *
 * Read: @wire(getRelatedListRecords, { parentRecordId, relatedListId: 'Disposition_Offers__r' }).
 * `lightning/uiRelatedListApi`'s shipped stub exposes it as an LDS test wire adapter, so it is
 * driven with `getRelatedListRecords.emit(payload)` / `.error()` — NO jest.mock() is needed for it.
 * The payload shape is the UI API's: `{ records: [{ id, fields: { X__c: { value } } }] }`.
 *
 * Write: DispositionApprovalController.selectOffer, mocked imperatively.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING FACTS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. The Apex parameters are `dispositionId` and `offerId`, verbatim. An imperative call binds by
 *    NAME — a mismatch is not a compile error on either side, it arrives null.
 * 2. notifyRecordUpdateAvailable IS called on success and is NOT called on failure. The service
 *    advances the Disposition's stage with imperative DML, so the Path would keep showing the
 *    pre-selection stage without it; and a failed write that notified would refresh the Path back
 *    to the same value and read as "the button did nothing".
 * 3. THREE distinct empty-ish states are separated, because collapsing them is the classic defect
 *    here: LOADING (wire has not answered), NO OFFERS (wire answered with an empty list — an
 *    explanation, not an empty table), and LOAD ERROR (wire rejected). A component that shows
 *    "no offers yet" on a failed wire is telling the user something false.
 * 4. A failed submission KEEPS THE PANEL OPEN, unlike c/sellMeterInitiateModal. The refusals
 *    reachable here can be answered by picking a DIFFERENT offer, so the form is still useful.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 2026-08-24 — THE PICKER BECAME A TABLE. WHAT THAT DID TO THIS FILE.
 * ═════════════════════════════════════════════════════════════════════════════
 * The `lightning-radio-group` is gone; four aligned columns (Broker / Amount / Offer Date / Offer
 * Number) plus a native `<input type="radio">` per row replace it, so a principal can compare bids
 * instead of reading four facts run together in one string.
 *
 * ⚠ 13 OF THE 18 TESTS IN THE PREVIOUS VERSION OF THIS FILE DIED LOUDLY when the radio group was
 * deleted (`TypeError: Cannot read properties of null`), which is the safe half. THREE SURVIVED
 * GREEN AND VACUOUS and are the reason this header exists — LOADING, NO OFFERS and LOAD ERROR each
 * asserted `expect(radio(element)).toBeNull()`, and after the deletion they passed **because the
 * radio group does not exist anywhere in this component any more**, exactly as they would pass if
 * the whole component had been deleted. All three are repointed below to assert the TABLE's
 * absence, and each keeps a guard-the-guard assertion proving the branch it is about actually
 * rendered. They were found by grepping the `radio()` helper, not by reading the runner's output —
 * a green test is invisible there.
 *
 * ⚠ THE MOVE MADE SEVERAL PINS *STRONGER*, WHICH IS THE REASON THE TABLE IS HAND-ROLLED MARKUP
 * RATHER THAN `lightning-datatable`. The four absence pins (T-NO-BUYER, T-NO-FINANCING,
 * T-NO-PROSE, and the "never renders the literal string undefined" clauses) read
 * `shadowRoot.textContent`. Under the old radio group the offer text lived in the STUB's
 * `options` property and never reached the DOM, so those clauses were only ever fencing the
 * surrounding markup. Against a real `<table>` they now read the actual rendered cells. Against a
 * `lightning-datatable` — whose sfdx-lwc-jest stub renders an EMPTY TEMPLATE — they would have
 * gone fully vacuous instead. Same for `@sa11y/jest`: axe can see this table's caption and its
 * five `<th scope="col">`; it can see nothing at all inside a stub.
 *
 * 🔴 THE UNIQUENESS CONTRACT DID NOT DISAPPEAR WITH THE COMPOSED LABEL — IT MOVED TO THE RADIO'S
 * `aria-label`, and it is asserted here as a RENDERED ATTRIBUTE (`getAttribute('aria-label')`),
 * never as a getter. A getter-only assertion has shipped a wrong rendered attribute in this repo
 * before.
 */
import { createElement } from 'lwc';
import DispositionOfferSelect from 'c/dispositionOfferSelect';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import selectOffer from '@salesforce/apex/DispositionApprovalController.selectOffer';

// lightning/actions has NO sfdx-lwc-jest stub, so CloseActionScreenEvent is supplied by a virtual
// mock — a CustomEvent subclass the suite can listen for. Copied verbatim from
// c/brokerReplaceQuickAction's suite, including the 'closeactionscreen' event name, so the two
// ScreenAction suites assert the same thing the same way.
jest.mock(
    'lightning/actions',
    () => ({
        CloseActionScreenEvent: class extends CustomEvent {
            constructor() {
                super('closeactionscreen');
            }
        }
    }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/DispositionApprovalController.selectOffer',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a0Ciw000004C4ngEAC';

// ─────────────────────────────────────────────────────────────────────────────
// 🔴 THE FIXTURE IS THE ORG'S TWO REAL OFFERS, VERBATIM (queried from
//    `usman-dpeg` 2026-08-21). These are the exact rows UAT reported on:
//
//      OFFER-0005   1,850,000   2026-08-21   Broker__c = null
//      OFFER-0006   1,860,000   2026-08-20   Broker__c = null
//
//    Both rendered `$1.9M` under `formatMillions` — one string for two
//    different bids, on the screen that chooses between them. Invented round
//    numbers ($12.5M / $11.8M, which is what this fixture used to hold) do not
//    collide under ANY formatter, so the old fixture could not have caught the
//    defect and must not come back.
// ─────────────────────────────────────────────────────────────────────────────
const OFFER_A = 'a0Biw000000qWgXEAU'; // OFFER-0005
const OFFER_B = 'a0Biw000000qWi9EAE'; // OFFER-0006

/**
 * 🔴 THE PAYLOAD SHAPES BELOW ARE MEASURED, NOT INVENTED — this is the single
 * most falsifiable thing in this file. Against the live
 * `/ui-api/related-list-records/{id}/Disposition_Offers__r` endpoint:
 *
 *   - a request for `Disposition_Offer__c.Broker__c` returns
 *     `{ displayValue: null, value: '003…' }` — THE NAME IS NOT THERE;
 *   - a request for `Disposition_Offer__c.Broker__r.Name` returns it under a
 *     `Broker__r` KEY, as `{ displayValue: 'Derek Simmons', value: { id,
 *     fields: { Name: { value: 'Derek Simmons' } } } }`;
 *   - an offer with no broker returns `{ displayValue: null, value: null }`.
 *
 * A hand-invented fixture that puts a name in `Broker__c.displayValue` would
 * make a component that renders nothing in the org pass here.
 */
const NO_BROKER_FIELD = { displayValue: null, value: null };
const brokerField = (id, name) => ({
    displayValue: name,
    value: {
        apiName: 'Contact',
        id,
        fields: { Name: { displayValue: null, value: name } }
    }
});

const offerRecord = (id, name, amount, date, brokerFieldValue) => ({
    id,
    fields: {
        Name: { displayValue: null, value: name },
        Broker__r: brokerFieldValue,
        Offer_Amount__c: { displayValue: null, value: amount },
        Offer_Date__c: { displayValue: null, value: date }
    }
});

/** The org's live state TODAY: two offers, neither carrying a broker. */
const OFFERS = {
    records: [
        offerRecord(OFFER_A, 'OFFER-0005', 1850000, '2026-08-21', NO_BROKER_FIELD),
        offerRecord(OFFER_B, 'OFFER-0006', 1860000, '2026-08-20', NO_BROKER_FIELD)
    ]
};

/**
 * The same two offers once `c/dispositionLogOfferModal` has stamped the broker.
 * ⚠ THE SAME BROKER ON BOTH ROWS, DELIBERATELY — there is one appointed broker
 * per disposition, so this is the only shape this fixture can honestly take.
 */
const OFFERS_BROKERED = {
    records: [
        offerRecord(
            OFFER_A,
            'OFFER-0005',
            1850000,
            '2026-08-21',
            brokerField('003iw000000o39BAAQ', 'Derek Simmons')
        ),
        offerRecord(
            OFFER_B,
            'OFFER-0006',
            1860000,
            '2026-08-20',
            brokerField('003iw000000o39BAAQ', 'Derek Simmons')
        )
    ]
};

/**
 * The adversarial case the picker must survive: same broker, same exact amount,
 * SAME DAY. One broker re-logging a revised bid at the same price on the same
 * day is a real sequence, so every column except the Offer Number is identical.
 */
const OFFERS_COLLIDING = {
    records: [
        offerRecord(
            OFFER_A,
            'OFFER-0005',
            1850000,
            '2026-08-21',
            brokerField('003iw000000o39BAAQ', 'Derek Simmons')
        ),
        offerRecord(
            OFFER_B,
            'OFFER-0006',
            1850000,
            '2026-08-21',
            brokerField('003iw000000o39BAAQ', 'Derek Simmons')
        )
    ]
};

/** The `fields` the component actually asked LDS for, on its last wire call. */
const getLastFields = () => getRelatedListRecords.getLastConfig().fields;

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-disposition-offer-select', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-offer-select', {
            is: DispositionOfferSelect
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    // ── Rendered-DOM accessors. Every one of these reads real markup, not a stub property. ──
    const table = (el) => el.shadowRoot.querySelector('table.qa-offer-table');
    const bodyRows = (el) => Array.from(el.shadowRoot.querySelectorAll('tbody tr'));
    const radios = (el) =>
        Array.from(el.shadowRoot.querySelectorAll('input.qa-offer-radio'));
    const confirmBtn = (el) => el.shadowRoot.querySelector('.qa-confirm');

    /** One column's rendered text, top to bottom, in document order. */
    const columnText = (el, cellSelector) =>
        bodyRows(el).map((tr) => tr.querySelector(cellSelector).textContent);

    /**
     * The radios' RENDERED `aria-label` attributes — the composed one-line description that used
     * to be the radio-group option label. Read off the DOM with `getAttribute`, never off a
     * getter: a getter-only assertion has passed in this repo while the rendered attribute was
     * wrong (`title="undefined"` shipped that way).
     */
    const ariaLabels = (el) =>
        radios(el).map((input) => input.getAttribute('aria-label'));

    /**
     * Chooses an offer the way a user does — a real click on the real radio. jsdom implements the
     * radio activation behaviour (checked flips, same-`name` siblings uncheck, `change` fires), so
     * this exercises the component's actual `onchange` -> `dataset.id` path rather than a
     * hand-shaped event this component would never receive.
     */
    function chooseOffer(element, value) {
        element.shadowRoot
            .querySelector(`input.qa-offer-radio[data-id="${value}"]`)
            .click();
        return Promise.resolve();
    }

    it('LOADING: spinner only — no table and no "no offers" copy yet', async () => {
        const element = createComponent();

        await Promise.resolve();

        // Guard the guard: this branch genuinely rendered something.
        expect(
            element.shadowRoot.querySelector('lightning-spinner')
        ).not.toBeNull();
        // ⚠ REPOINTED 2026-08-24. This clause read `expect(radio(element)).toBeNull()` and became
        // VACUOUS when the radio group was deleted — it would have passed for a deleted component.
        expect(table(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.qa-close')).toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 THE TABLE ITSELF (2026-08-24). These are the tests that fail if the
    //    picker regresses to one run-on string per offer.
    // ─────────────────────────────────────────────────────────────────────────

    it('TABLE: one row per offer, with broker, amount, date and offer number in SEPARATE cells', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        const rows = bodyRows(element);
        expect(rows.length).toBe(2);

        // 🔴 EACH FACT IS ITS OWN CELL, ASSERTED WITH `toBe` — not `toContain`. An implementation
        // that puts the whole composed string back into one cell and leaves the others blank
        // passes a `toContain`, and fails this.
        expect(rows[0].querySelector('.qa-cell-broker').textContent).toBe('Derek Simmons');
        expect(rows[0].querySelector('.qa-cell-amount').textContent).toBe('$1,850,000');
        expect(rows[0].querySelector('.qa-cell-date').textContent).toBe('Aug 21, 2026');
        expect(rows[0].querySelector('.qa-cell-ref').textContent).toBe('OFFER-0005');

        expect(rows[1].querySelector('.qa-cell-broker').textContent).toBe('Derek Simmons');
        expect(rows[1].querySelector('.qa-cell-amount').textContent).toBe('$1,860,000');
        expect(rows[1].querySelector('.qa-cell-date').textContent).toBe('Aug 20, 2026');
        expect(rows[1].querySelector('.qa-cell-ref').textContent).toBe('OFFER-0006');

        // The row is addressable by the offer it represents — this is what the selection handler
        // and the selected-row styling hang off.
        expect(rows.map((tr) => tr.dataset.row)).toEqual([OFFER_A, OFFER_B]);
    });

    /**
     * 🔴 T-NO-RUNON — THE ABSENCE PIN FOR THE THING THAT WAS REPLACED (2026-08-24).
     *
     * Every assertion about the old composed label was RETARGETED onto the columns, so nothing
     * above would fail if the four facts were run back together into one visible string. This is
     * that pin. The separators are the tell: ' — ' between broker and amount, ' · ' between the
     * rest. They are still legitimately present in the radios' `aria-label` ATTRIBUTE — which is
     * the point of asserting rendered TEXT here and not `innerHTML`.
     */
    it('🔴 T-NO-RUNON: the four facts never render as one run-on string in a cell', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        // Guard the guard: two real rows rendered.
        expect(bodyRows(element).length).toBe(2);

        const text = element.shadowRoot.textContent;
        expect(text).not.toContain(' · ');
        expect(text).not.toContain(' — ');
        // ...and the retired component is gone, not merely unrendered.
        expect(element.shadowRoot.querySelector('lightning-radio-group')).toBeNull();
        // The separators ARE still in the accessible name, which is where they belong.
        expect(ariaLabels(element)[0]).toContain(' · ');
    });

    it('TABLE: five column headers, every one scoped, in the asked-for order', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        const headers = Array.from(
            element.shadowRoot.querySelectorAll('thead th')
        );
        // `toEqual` on an ordered array pins the ORDER and the COUNT together, so a sixth column
        // or a reshuffle reds here rather than in UAT.
        expect(headers.map((th) => th.textContent.trim())).toEqual([
            'Choose',
            'Broker',
            'Amount',
            'Offer Date',
            'Offer Number'
        ]);
        // 🔴 A RENDERED ATTRIBUTE, on every header. Without `scope` a screen reader does not
        // associate a cell with its column, which is most of what makes this a table rather than
        // a grid of unlabelled strings.
        headers.forEach((th) => {
            expect(th.getAttribute('scope')).toBe('col');
        });
        // The Choose header carries assistive-only text: a `<th>` with no discernible text fails
        // axe's empty-table-header rule, and a visible word above a radio column is noise.
        expect(
            headers[0].querySelector('.slds-assistive-text')
        ).not.toBeNull();
    });

    it('TABLE: the accessible name is the caption the radio group used to carry as its label', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        const caption = element.shadowRoot.querySelector('table.qa-offer-table > caption');
        expect(caption).not.toBeNull();
        expect(caption.textContent).toBe('Offer to put forward');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 SINGLE-SELECT IS THE APEX CONTRACT. `selectOffer(dispositionId, offerId)`
    //    takes ONE Id, and the service flips `Is_Selected__c` EXCLUSIVELY.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 SINGLE-SELECT: one shared radio name, and choosing a second offer releases the first', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        const inputs = radios(element);
        expect(inputs.length).toBe(2);
        // 🔴 THE SHARED `name` IS WHAT MAKES THIS SINGLE-SELECT — it is not decoration, it is the
        // mechanism. Split it per row (or switch the type to checkbox) and the browser will happily
        // let a principal tick both bids while only one Id can ever reach Apex.
        inputs.forEach((input) => {
            expect(input.getAttribute('type')).toBe('radio');
            expect(input.getAttribute('name')).toBe('dispositionOffer');
        });
        expect(new Set(inputs.map((i) => i.getAttribute('name'))).size).toBe(1);

        await chooseOffer(element, OFFER_A);
        expect(radios(element).map((i) => i.checked)).toEqual([true, false]);
        expect(
            bodyRows(element).map((tr) => tr.className.includes('qa-row_selected'))
        ).toEqual([true, false]);

        await chooseOffer(element, OFFER_B);
        expect(radios(element).map((i) => i.checked)).toEqual([false, true]);
        expect(
            bodyRows(element).map((tr) => tr.className.includes('qa-row_selected'))
        ).toEqual([false, true]);
        // Whatever the DOM did, exactly one row is selected at any moment.
        expect(radios(element).filter((i) => i.checked).length).toBe(1);
    });

    it('DATA BRANCH: the org’s live rows — no broker stamped — say so rather than showing a blank', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        // ⚠ THIS IS THE STATE UAT IS LOOKING AT RIGHT NOW: `Broker__c` landed the
        // same day, so neither live offer carries one. The placeholder is a
        // sentence precisely so it cannot be mistaken for a broker's name.
        expect(columnText(element, '.qa-cell-broker')).toEqual([
            'Broker not recorded',
            'Broker not recorded'
        ]);
        // Neither "undefined" nor a bare "null" may reach the screen — the broker
        // arrives as `{ displayValue: null, value: null }`, and both of those
        // stringify into something that looks like data.
        // ⚠ THIS CLAUSE ONLY BECAME REAL ON 2026-08-24. Under the radio group the offer text lived
        // in the stub's `options` property and never reached the DOM at all.
        const rendered = element.shadowRoot.textContent;
        expect(rendered).toContain('Broker not recorded');
        expect(rendered).not.toContain('undefined');
        expect(rendered).not.toContain('null');
    });

    it('DATA BRANCH: an offer missing every optional field still renders a usable, unique row', async () => {
        const element = createComponent();

        getRelatedListRecords.emit({
            records: [{ id: OFFER_A, fields: {} }]
        });
        await Promise.resolve();

        const row = bodyRows(element)[0];
        expect(row.querySelector('.qa-cell-broker').textContent).toBe('Broker not recorded');
        expect(row.querySelector('.qa-cell-amount').textContent).toBe('—');
        expect(row.querySelector('.qa-cell-date').textContent).toBe('—');
        // ⚠ A ROW WITH NO `Name` IS UNREACHABLE IN PRACTICE — it is an AutoNumber
        // the platform assigns on insert. The fallback is THE RECORD ID rather
        // than a friendly constant such as 'Unnumbered offer' (which is what this
        // asserted until 2026-08-21) for one reason: the Id is unique by
        // definition, so the uniqueness invariant survives even here, whereas two
        // nameless rows sharing a friendly constant would announce identically.
        expect(row.querySelector('.qa-cell-ref').textContent).toBe(OFFER_A);
        expect(ariaLabels(element)[0]).toBe(
            `Broker not recorded — — · — · ${OFFER_A}`
        );
        // The rendered markup must never contain the literal string "undefined".
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-EXACT / T-UNIQUE — THE 2026-08-21 UAT DEFECT AND ITS INVARIANT
    //
    // Reported from live UAT: the org's two offers, $1,850,000 and $1,860,000,
    // BOTH rendered `$1.9M`. These are the tests that fail if any form of
    // abbreviation returns to this screen. ⚠ THE MOVE TO A TABLE DID NOT RETIRE
    // THEM — a currency-formatted `lightning-datatable` column or a
    // `lightning-formatted-number` would put the rounding right back, one step
    // further from anything Jest can read.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-EXACT: the two REAL offers render two DIFFERENT amounts, and never "$1.9M"', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        const amounts = columnText(element, '.qa-cell-amount');
        expect(amounts.length).toBe(2);

        // 1. The exact figures, stated positively, as RENDERED CELL TEXT.
        expect(amounts).toEqual(['$1,850,000', '$1,860,000']);

        // 2. 🔴 THE ROUNDED FORM THE DEFECT PRODUCED. Restoring `formatMillions`
        //    here — or "fixing" it with more decimals, which only moves the
        //    collision distance from $100k to $10k — fails this line.
        amounts.forEach((amount) => {
            expect(amount).not.toContain('$1.9M');
            expect(amount).not.toMatch(/\$[\d.]+M\b/);
        });
        expect(element.shadowRoot.textContent).not.toMatch(/\$[\d.]+M\b/);

        // 3. And the invariant the two figures exist to serve.
        expect(new Set(amounts).size).toBe(2);
    });

    it('🔴 T-UNIQUE: two offers stay distinguishable — same broker, same amount, SAME DAY', async () => {
        const element = createComponent();

        // Every column identical except the Offer Number. This is what a conditional
        // "only disambiguate when needed" implementation gets wrong.
        getRelatedListRecords.emit(OFFERS_COLLIDING);
        await Promise.resolve();

        expect(bodyRows(element).length).toBe(2);

        // 1. THE SIGHTED USER'S VERSION: three columns match exactly, and the fourth is what
        //    tells the two rows apart. The Offer Number column is therefore not optional chrome.
        expect(columnText(element, '.qa-cell-broker')).toEqual([
            'Derek Simmons',
            'Derek Simmons'
        ]);
        expect(columnText(element, '.qa-cell-amount')).toEqual([
            '$1,850,000',
            '$1,850,000'
        ]);
        expect(columnText(element, '.qa-cell-date')).toEqual([
            'Aug 21, 2026',
            'Aug 21, 2026'
        ]);
        const refs = columnText(element, '.qa-cell-ref');
        expect(refs).toEqual(['OFFER-0005', 'OFFER-0006']);
        expect(new Set(refs).size).toBe(2);

        // 2. THE SCREEN-READER USER'S VERSION, on the RENDERED attribute. Without this the table
        //    would be a regression for them: five radios announced with no name at all.
        const labels = ariaLabels(element);
        expect(new Set(labels).size).toBe(2);
        expect(labels[0]).toBe('Derek Simmons — $1,850,000 · Aug 21, 2026 · OFFER-0005');
        expect(labels[1]).toBe('Derek Simmons — $1,850,000 · Aug 21, 2026 · OFFER-0006');

        // 3. 🔴 The broker discriminates NOTHING — one appointed broker per sale, so
        //    it is the same value in both rows. Stated as an assertion so a future
        //    edit cannot start treating it as the discriminator.
        expect(labels[0].split(' — ')[0]).toBe(labels[1].split(' — ')[0]);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-BUYER — THE DELIBERATE ABSENCE PIN (2026-08-21)
    //
    // Buyer identity was retired from this feature. The column assertions above
    // were RETARGETED, so nothing in this file would fail if a buyer name were
    // put back beside the offer number. This is that pin.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-BUYER: no buyer column, no buyer text, and no buyer field requested', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        // Guard the guard: two real rows rendered.
        expect(bodyRows(element).length).toBe(2);

        // 1. 🔴 THE RENDERED TABLE. This is what a human reads when choosing the
        //    winning bid — headers, cells and the radios' accessible names.
        expect(element.shadowRoot.textContent.toLowerCase()).not.toContain('buyer');
        ariaLabels(element).forEach((label) => {
            expect(label.toLowerCase()).not.toContain('buyer');
        });
        // A buyer arriving as a fifth COLUMN rather than as a token is the likelier
        // shape now, so the column count is pinned too.
        expect(element.shadowRoot.querySelectorAll('thead th').length).toBe(5);

        // 2. 🔴 THE WIRE REQUEST ITSELF. This catches the field returning to the
        //    LDS `fields` list — which re-adds an FLS gate on `Buyer_Name__c` for
        //    every user of this quick action even if nothing renders it.
        const config = getLastFields();
        expect(config).not.toContain('Disposition_Offer__c.Buyer_Name__c');
        expect(config).toContain('Disposition_Offer__c.Name');
        // ⚠ THIS PIN USED TO CARRY A THIRD CLAUSE — `expect(config)
        // .not.toContain('Disposition_Offer__c.Broker__c')` — on the grounds that
        // the broker discriminates nothing. THE PREMISE IS STILL TRUE (see
        // T-UNIQUE) but the conclusion was overturned by UAT: the broker is now
        // requested and leads the table, made safe by an exact amount and an
        // unconditional offer number. The clause was DELETED rather than left
        // standing, because it would now be asserting the opposite of the
        // component's contract — and note it would have passed anyway, vacuously,
        // since the request is for `Broker__r.Name`, not `Broker__c`.
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-FINANCING — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT:
    //    "No need to show financing not started")
    //
    // The financing token was the 4th token in the old label. Deleting it deleted
    // every assertion that mentioned it, so nothing here would fail if it came
    // back — now most plausibly as a fifth COLUMN. Emitted on a POPULATED
    // fixture — an absence assertion against an empty table passes for the wrong
    // reason.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-FINANCING: no financing anywhere in the table, and the field is not requested', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        // Guard the guard: two real rows rendered.
        expect(bodyRows(element).length).toBe(2);

        // 1. Not the fallback string, and not a real picklist value either — the
        //    ask was to drop the FACT, not to improve the empty case.
        const rendered = element.shadowRoot.textContent.toLowerCase();
        expect(rendered).not.toContain('financing');
        expect(rendered).not.toContain('cash');
        expect(rendered).not.toContain('conventional');
        ariaLabels(element).forEach((label) => {
            expect(label.toLowerCase()).not.toContain('financing');
        });

        // 2. And the wire request, so the field cannot return silently as an
        //    unrendered FLS gate on every user of this quick action.
        expect(getLastFields()).not.toContain(
            'Disposition_Offer__c.Offer_Financing_Type__c'
        );
        // 🔴 THE FIELD ITSELF IS NOT RETIRED. It is still on the offer layout, on
        // `c/dispositionLogOfferModal`'s form (whose suite PINS its presence) and
        // on the approval page. This pin is about THIS picker only.
    });

    it('🔴 T-BROKER-SPAN: requests `Broker__r.Name`, NOT the bare `Broker__c` lookup', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        // Measured against `usman-dpeg`: a bare `Broker__c` request returns
        // `{ displayValue: null, value: '003…' }` — the Id with NO name — so a
        // component built on it renders an empty Broker column on every row. Only
        // the traversal carries the name. This assertion is the reason that cannot
        // be "simplified" back without a test failing.
        expect(getLastFields()).toContain('Disposition_Offer__c.Broker__r.Name');
        expect(getLastFields()).not.toContain('Disposition_Offer__c.Broker__c');
        expect(columnText(element, '.qa-cell-broker')[0]).toBe('Derek Simmons');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // The `.qa-note` panel above the picker was removed at the user's request.
    // It is THE string they quoted:
    //
    //   "Selecting an offer moves this disposition to Offer Selection and sends
    //    the offer for principal approval. It does not accept the offer — the
    //    approval does that."
    //
    // Nothing in this file asserted it, so its deletion left no failing test and
    // therefore nothing standing between the repo and its return. This is that
    // pin. It runs on the FULL two-offer fixture so every absence below is a
    // real absence rather than an unrendered component.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PROSE: no explanatory note above the offer table — the removal must not come back', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        // Guard the guard: the data branch genuinely rendered.
        expect(bodyRows(element).length).toBe(2);
        expect(confirmBtn(element)).not.toBeNull();

        // 1. THE OLD SELECTOR.
        expect(element.shadowRoot.querySelector('.qa-note')).toBeNull();

        // 2. 🔴 THE RENDERED WORDS. A re-added paragraph usually arrives under a
        //    new class name, so the selector assertion alone would stay green.
        //    These phrases are what a human actually reads.
        const text = element.shadowRoot.textContent.toLowerCase();
        expect(text).not.toContain('moves this disposition to');
        expect(text).not.toContain('does not accept the offer');
        expect(text).not.toContain('principal approval');

        // 3. 🔴 WHAT MUST SURVIVE. The behaviour the note described is now stated
        //    ONLY by the button label, so this half of the pin is what stops a
        //    future edit shortening it to "Accept" and leaving the screen with no
        //    statement of the consequence at all.
        //    ⚠ Read off the `label` PROPERTY, not `textContent` — sfdx-lwc-jest's
        //    `lightning-button` stub renders an EMPTY template, so a text-node
        //    assertion here would be vacuously green in both directions.
        expect(confirmBtn(element).label).toBe('Select and send for approval');
    });

    it('GATE: confirm is disabled until an offer is chosen, and clicking it calls no Apex', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        expect(confirmBtn(element).disabled).toBe(true);
        // Nothing is pre-selected — a picker that opens with a bid already chosen is a decision
        // made for the principal.
        expect(radios(element).filter((i) => i.checked).length).toBe(0);
        confirmBtn(element).click();
        await flushPromises();
        expect(selectOffer).not.toHaveBeenCalled();

        await chooseOffer(element, OFFER_A);
        expect(confirmBtn(element).disabled).toBe(false);
    });

    it('SUCCESS: calls Apex by NAME, toasts the server message, notifies LDS, closes the action', async () => {
        selectOffer.mockResolvedValue(
            'Acme Holdings selected and sent for approval.'
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        const closeHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('closeactionscreen', closeHandler);

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();
        await chooseOffer(element, OFFER_B);
        confirmBtn(element).click();
        await flushPromises();

        expect(selectOffer).toHaveBeenCalledTimes(1);
        // 🔴 EXACTLY ONE offerId, and it is the row the user clicked. This is the whole payload
        // contract the table had to preserve.
        expect(selectOffer).toHaveBeenCalledWith({
            dispositionId: RECORD_ID,
            offerId: OFFER_B
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        // The service's returned text is authored — it names the offer and says an
        // approval was raised. Shown, not re-authored.
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Acme Holdings selected and sent for approval.'
        );

        // 🔴 The stage write is imperative Apex DML — without this the Path keeps
        // showing the pre-selection stage.
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledTimes(1);
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);

        expect(closeHandler).toHaveBeenCalledTimes(1);
    });

    it('FAILURE: shows the refusal inline, STAYS OPEN, notifies nothing', async () => {
        selectOffer.mockRejectedValue({
            body: {
                message:
                    'An offer can only be selected while the disposition is at Active Listing or Release Materials.'
            }
        });

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('closeactionscreen', closeHandler);

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();
        await chooseOffer(element, OFFER_A);
        confirmBtn(element).click();
        await flushPromises();

        const banner = element.shadowRoot.querySelector('.lv-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toContain('Active Listing or Release Materials');
        expect(banner.getAttribute('role')).toBe('alert');

        // Nothing was written, so LDS must not be told the record changed; and the
        // panel stays open because picking a different offer is a real remedy —
        // which means the table, and the row already chosen, must both survive.
        expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();
        expect(closeHandler).not.toHaveBeenCalled();
        expect(table(element)).not.toBeNull();
        expect(radios(element).filter((i) => i.checked).length).toBe(1);
    });

    it('FAILURE: falls back to a generic message when the error carries no body', async () => {
        selectOffer.mockRejectedValue(new Error('network'));

        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();
        await chooseOffer(element, OFFER_A);
        confirmBtn(element).click();
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.lv-error').textContent
        ).toContain('The offer could not be selected.');
    });

    it('NO OFFERS: explains rather than showing an empty table', async () => {
        const element = createComponent();

        getRelatedListRecords.emit({ records: [] });
        await Promise.resolve();

        // ⚠ REPOINTED 2026-08-24 from `expect(radio(element)).toBeNull()`, which survived the
        // radio group's deletion GREEN AND VACUOUS.
        expect(table(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.qa-close')).not.toBeNull();
        expect(element.shadowRoot.textContent).toContain(
            'No offers have been logged'
        );
        // Not an error state — nothing failed.
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('LOAD ERROR: shows the load banner and NOT the "no offers yet" copy', async () => {
        const element = createComponent();

        getRelatedListRecords.error();
        await Promise.resolve();

        const banner = element.shadowRoot.querySelector('.lv-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toContain('could not be loaded');
        // 🔴 The separation is the point: telling a user "no offers yet" when the
        // read actually FAILED is telling them something false.
        expect(element.shadowRoot.textContent).not.toContain(
            'No offers have been logged'
        );
        // ⚠ REPOINTED 2026-08-24 from `expect(radio(element)).toBeNull()` — vacuous survivor.
        expect(table(element)).toBeNull();
    });

    it('CANCEL: closes the action without calling Apex', async () => {
        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('closeactionscreen', closeHandler);

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        element.shadowRoot.querySelector('.qa-cancel').click();
        await flushPromises();

        expect(selectOffer).not.toHaveBeenCalled();
        expect(closeHandler).toHaveBeenCalledTimes(1);
    });

    /**
     * ⚠ THIS MATTERS MORE SINCE 2026-08-24 THAN IT DID BEFORE. axe is now looking at a real
     * `<table>` — its `<caption>` accessible name, five `<th scope="col">`, a `<th scope="row">`
     * per row and five named radios. Under a `lightning-datatable` it would have been looking at
     * an empty stub and passing for the same reason a deleted component passes.
     */
    it('is accessible', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible with a row selected', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();
        await chooseOffer(element, OFFER_A);

        await expect(element).toBeAccessible();
    });
});
