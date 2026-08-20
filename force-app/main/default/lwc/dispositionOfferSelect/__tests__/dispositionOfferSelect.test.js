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

const RECORD_ID = 'a0D5g000000DispEAG';
const OFFER_A = 'a0O0000000000001';
const OFFER_B = 'a0O0000000000002';

const OFFERS = {
    records: [
        {
            id: OFFER_A,
            fields: {
                Buyer_Name__c: { value: 'Acme Holdings' },
                Offer_Amount__c: { value: 12500000 },
                Offer_Date__c: { value: '2026-08-12' },
                Offer_Financing_Type__c: { value: 'Cash' }
            }
        },
        {
            id: OFFER_B,
            fields: {
                Buyer_Name__c: { value: 'Northwind Capital' },
                Offer_Amount__c: { value: 11800000 },
                Offer_Date__c: { value: '2026-08-14' },
                Offer_Financing_Type__c: { value: 'Conventional' }
            }
        }
    ]
};

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

    it('DATA BRANCH: composes one radio option per offer, all four fields in the label', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        const options = radio(element).options;
        expect(options.length).toBe(2);
        expect(options[0]).toEqual({
            label: 'Acme Holdings — $12.5M · Aug 12, 2026 · Cash',
            value: OFFER_A
        });
        // A radio labelled with the buyer name ALONE would make two offers from
        // the same buyer indistinguishable — a real case in a re-bid.
        expect(options[1].label).toContain('Northwind Capital');
        expect(options[1].label).toContain('$11.8M');
        expect(options[1].label).toContain('Conventional');
    });

    it('DATA BRANCH: an offer missing every optional field still renders a usable label', async () => {
        const element = createComponent();

        getRelatedListRecords.emit({
            records: [{ id: OFFER_A, fields: {} }]
        });
        await Promise.resolve();

        const label = radio(element).options[0].label;
        expect(label).toBe('Unnamed buyer — — · — · Financing not stated');
        // The rendered markup must never contain the literal string "undefined".
        expect(element.shadowRoot.textContent).not.toContain('undefined');
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
