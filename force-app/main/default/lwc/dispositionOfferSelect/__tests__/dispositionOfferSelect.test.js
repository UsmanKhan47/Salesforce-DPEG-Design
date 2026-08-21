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
 *    explanation, not an empty radio group), and LOAD ERROR (wire rejected). A component that
 *    shows "no offers yet" on a failed wire is telling the user something false.
 * 4. A failed submission KEEPS THE PANEL OPEN, unlike c/sellMeterInitiateModal. The refusals
 *    reachable here can be answered by picking a DIFFERENT offer, so the form is still useful.
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
 * The adversarial case the label must survive: same broker, same exact amount,
 * SAME DAY. One broker re-logging a revised bid at the same price on the same
 * day is a real sequence, so every token except the AutoNumber is identical.
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

const labelsOf = (element) =>
    element.shadowRoot
        .querySelector('lightning-radio-group')
        .options.map((o) => o.label);

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

    const radio = (el) => el.shadowRoot.querySelector('lightning-radio-group');
    const confirmBtn = (el) => el.shadowRoot.querySelector('.qa-confirm');

    function chooseOffer(element, value) {
        radio(element).dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        return Promise.resolve();
    }

    it('LOADING: spinner only — no radio group and no "no offers" copy yet', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('lightning-spinner')
        ).not.toBeNull();
        expect(radio(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.qa-close')).toBeNull();
    });

    it('DATA BRANCH: composes one radio option per offer — broker, exact amount, date, offer number', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        const options = radio(element).options;
        expect(options.length).toBe(2);
        // 🔴 THE BROKER LEADS AND THE OFFER NUMBER TRAILS (2026-08-21 UAT). The
        // broker is what the user asked to see; the AutoNumber is what actually
        // guarantees two rows differ, and it is appended UNCONDITIONALLY — see
        // T-UNIQUE below.
        expect(options[0]).toEqual({
            label: 'Derek Simmons — $1,850,000 · Aug 21, 2026 · OFFER-0005',
            value: OFFER_A
        });
        expect(options[1]).toEqual({
            label: 'Derek Simmons — $1,860,000 · Aug 20, 2026 · OFFER-0006',
            value: OFFER_B
        });
    });

    it('DATA BRANCH: the org’s live rows — no broker stamped — say so rather than showing a blank', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        // ⚠ THIS IS THE STATE UAT IS LOOKING AT RIGHT NOW: `Broker__c` landed the
        // same day, so neither live offer carries one. The placeholder is a
        // sentence precisely so it cannot be mistaken for a broker's name.
        expect(labelsOf(element)).toEqual([
            'Broker not recorded — $1,850,000 · Aug 21, 2026 · OFFER-0005',
            'Broker not recorded — $1,860,000 · Aug 20, 2026 · OFFER-0006'
        ]);
        // Neither "undefined" nor a bare "null" may reach the screen — the broker
        // arrives as `{ displayValue: null, value: null }`, and both of those
        // stringify into something that looks like data.
        const rendered = element.shadowRoot.textContent;
        expect(rendered).not.toContain('undefined');
        expect(rendered).not.toContain('null');
    });

    it('DATA BRANCH: an offer missing every optional field still renders a usable, unique label', async () => {
        const element = createComponent();

        getRelatedListRecords.emit({
            records: [{ id: OFFER_A, fields: {} }]
        });
        await Promise.resolve();

        const label = radio(element).options[0].label;
        // ⚠ A ROW WITH NO `Name` IS UNREACHABLE IN PRACTICE — it is an AutoNumber
        // the platform assigns on insert. The fallback is THE RECORD ID rather
        // than a friendly constant such as 'Unnumbered offer' (which is what this
        // asserted until 2026-08-21) for one reason: the Id is unique by
        // definition, so the uniqueness invariant survives even here, whereas two
        // nameless rows sharing a friendly constant would render identically.
        expect(label).toBe(`Broker not recorded — — · — · ${OFFER_A}`);
        // The rendered markup must never contain the literal string "undefined".
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-EXACT / T-UNIQUE — THE 2026-08-21 UAT DEFECT AND ITS INVARIANT
    //
    // Reported from live UAT: the org's two offers, $1,850,000 and $1,860,000,
    // BOTH rendered `$1.9M`. These are the tests that fail if any form of
    // abbreviation returns to this label.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-EXACT: the two REAL offers render two DIFFERENT amounts, and never "$1.9M"', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        const labels = labelsOf(element);
        expect(labels.length).toBe(2);

        // 1. The exact figures, stated positively.
        expect(labels[0]).toContain('$1,850,000');
        expect(labels[1]).toContain('$1,860,000');

        // 2. 🔴 THE ROUNDED FORM THE DEFECT PRODUCED. Restoring `formatMillions`
        //    here — or "fixing" it with more decimals, which only moves the
        //    collision distance from $100k to $10k — fails this line.
        labels.forEach((label) => {
            expect(label).not.toContain('$1.9M');
            expect(label).not.toMatch(/\$[\d.]+M\b/);
        });

        // 3. And the invariant the two figures exist to serve.
        expect(new Set(labels).size).toBe(2);
    });

    it('🔴 T-UNIQUE: no two options share a label — same broker, same amount, SAME DAY', async () => {
        const element = createComponent();

        // Every token identical except the AutoNumber. This is what a conditional
        // "only disambiguate when needed" implementation gets wrong.
        getRelatedListRecords.emit(OFFERS_COLLIDING);
        await Promise.resolve();

        const labels = labelsOf(element);
        expect(labels.length).toBe(2);
        expect(new Set(labels).size).toBe(2);
        expect(labels[0]).toBe(
            'Derek Simmons — $1,850,000 · Aug 21, 2026 · OFFER-0005'
        );
        expect(labels[1]).toBe(
            'Derek Simmons — $1,850,000 · Aug 21, 2026 · OFFER-0006'
        );
        // 🔴 The broker discriminates NOTHING — one appointed broker per sale, so
        // it is the same leading token on both rows. Stated as an assertion so a
        // future edit cannot start treating it as the discriminator.
        expect(labels[0].split(' — ')[0]).toBe(labels[1].split(' — ')[0]);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-BUYER — THE DELIBERATE ABSENCE PIN (2026-08-21)
    //
    // Buyer identity was retired from this feature. The label assertions above
    // were RETARGETED, so nothing in this file would fail if a buyer name were
    // put back into the label beside the offer number. This is that pin.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-BUYER: no buyer in any radio label, and no buyer field requested', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        // Guard the guard: two real options rendered.
        expect(radio(element).options.length).toBe(2);

        // 1. 🔴 THE COMPOSED LABELS. These are the strings a human reads when
        //    choosing the winning bid.
        radio(element).options.forEach((option) => {
            expect(option.label.toLowerCase()).not.toContain('buyer');
        });
        // ...and the rendered markup, which is where a separate buyer element
        // would show up even if the label stayed clean.
        expect(element.shadowRoot.textContent.toLowerCase()).not.toContain('buyer');

        // 2. 🔴 THE WIRE REQUEST ITSELF. This catches the field returning to the
        //    LDS `fields` list — which re-adds an FLS gate on `Buyer_Name__c` for
        //    every user of this quick action even if nothing renders it.
        const config = getLastFields();
        expect(config).not.toContain('Disposition_Offer__c.Buyer_Name__c');
        expect(config).toContain('Disposition_Offer__c.Name');
        // ⚠ THIS PIN USED TO CARRY A THIRD CLAUSE — `expect(config.fields)
        // .not.toContain('Disposition_Offer__c.Broker__c')` — on the grounds that
        // the broker discriminates nothing. THE PREMISE IS STILL TRUE (see
        // T-UNIQUE) but the conclusion was overturned by UAT: the broker is now
        // requested and leads the label, made safe by an exact amount and an
        // unconditional offer number. The clause was DELETED rather than left
        // standing, because it would now be asserting the opposite of the
        // component's contract — and note it would have passed anyway, vacuously,
        // since the request is for `Broker__r.Name`, not `Broker__c`.
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-FINANCING — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT:
    //    "No need to show financing not started")
    //
    // The financing token was the 4th token in this label. Deleting it deleted
    // every assertion that mentioned it, so nothing here would fail if it came
    // back. This is that pin. Emitted on a POPULATED fixture — an absence
    // assertion against an empty radio group passes for the wrong reason.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-FINANCING: no financing token in any label, and the field is not requested', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        // Guard the guard: two real options rendered.
        const labels = labelsOf(element);
        expect(labels.length).toBe(2);

        // 1. Not the fallback string, and not a real picklist value either — the
        //    ask was to drop the TOKEN, not to improve the empty case.
        const rendered = element.shadowRoot.textContent.toLowerCase();
        expect(rendered).not.toContain('financing');
        expect(rendered).not.toContain('cash');
        expect(rendered).not.toContain('conventional');
        labels.forEach((label) => {
            expect(label.toLowerCase()).not.toContain('financing');
        });

        // 2. And the wire request, so the field cannot return silently as an
        //    unrendered FLS gate on every user of this quick action.
        expect(getLastFields()).not.toContain(
            'Disposition_Offer__c.Offer_Financing_Type__c'
        );
        // 🔴 THE FIELD ITSELF IS NOT RETIRED. It is still on the offer layout, on
        // `c/dispositionLogOfferModal`'s form (whose suite pins its presence) and
        // on the approval page. This pin is about THIS label only.
    });

    it('🔴 T-BROKER-SPAN: requests `Broker__r.Name`, NOT the bare `Broker__c` lookup', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_BROKERED);
        await Promise.resolve();

        // Measured against `usman-dpeg`: a bare `Broker__c` request returns
        // `{ displayValue: null, value: '003…' }` — the Id with NO name — so a
        // component built on it renders an empty broker on every row. Only the
        // traversal carries the name. This assertion is the reason that cannot be
        // "simplified" back without a test failing.
        expect(getLastFields()).toContain('Disposition_Offer__c.Broker__r.Name');
        expect(getLastFields()).not.toContain('Disposition_Offer__c.Broker__c');
        expect(labelsOf(element)[0].startsWith('Derek Simmons — ')).toBe(true);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // The `.qa-note` panel above the radio group was removed at the user's
    // request. It is THE string they quoted:
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

    it('🔴 T-NO-PROSE: no explanatory note above the offer list — the removal must not come back', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        // Guard the guard: the data branch genuinely rendered.
        expect(radio(element).options.length).toBe(2);
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
        expect(confirmBtn(element).label).toBe('Select and send for approval');
    });

    it('GATE: confirm is disabled until an offer is chosen, and clicking it calls no Apex', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        expect(confirmBtn(element).disabled).toBe(true);
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
        // panel stays open because picking a different offer is a real remedy.
        expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();
        expect(closeHandler).not.toHaveBeenCalled();
        expect(radio(element)).not.toBeNull();
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

    it('NO OFFERS: explains rather than showing an empty radio group', async () => {
        const element = createComponent();

        getRelatedListRecords.emit({ records: [] });
        await Promise.resolve();

        expect(radio(element)).toBeNull();
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
        expect(radio(element)).toBeNull();
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

    it('is accessible', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
