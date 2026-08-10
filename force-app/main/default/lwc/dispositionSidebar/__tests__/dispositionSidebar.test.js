/**
 * WIRE-MOCK TEMPLATE — @wire to LDS (getRecord), single-field variant
 * ------------------------------------------------------------------
 * Follows the c-transaction-critical-dates LDS template. c-disposition-sidebar
 * is the simplest getRecord case: one field (Disposition__c.Disposition_Stage__c),
 * boolean getters, no fixture file needed — the record is built inline. NO
 * jest.mock() for LDS; getRecord.emit(record) drives the branch and getRecord
 * .error() the fallback.
 *
 * Note: unlike c-disposition-main, isClosing here is true ONLY for the 'Closing'
 * stage (not 'Completed'), so 'Completed' renders no child — asserted below.
 * The accessibility check runs on the empty state (guaranteed axe-clean).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE OFFER CARD NOW SPANS FOUR STAGES (was 'Active Listing' only)
 * ─────────────────────────────────────────────────────────────────────────────
 * With the new stage values the sidebar was empty at exactly the stages where
 * offers are being taken. c-disposition-offer now renders at 'Active Listing',
 * 'Call for Offers', 'Disposition Offer' and 'LOI'.
 *
 * ⚠ NO RECORD-TYPE WIRE ANYWHERE, DELIBERATELY. The two record types' stage value
 * sets are DISJOINT for every path-specific stage — 'Call for Offers' is On_Market
 * only and 'Disposition Offer' is Off_Market only — so the stage alone identifies
 * the path. That is also why this suite still emits nothing but a stage: if a
 * getObjectInfo/RecordTypeId wire ever appears here, these fixtures stop being
 * sufficient, which is the signal that the disjointness assumption was broken.
 *
 * 🔴 'PSA' is asserted to render NOTHING, on purpose (Gate 1 Q5 = no placeholder).
 * At PSA the only marker is PSA_Executed__c on the Disposition itself and the
 * record page falls back to its Details section. That is a decision, not a gap.
 */
import { createElement } from 'lwc';
import DispositionSidebar from 'c/dispositionSidebar';
import { getRecord } from 'lightning/uiRecordApi';

const RECORD_ID = 'a0D5g000000DispEAG';

function recordForStage(stage) {
    return {
        apiName: 'Disposition__c',
        id: RECORD_ID,
        fields: { Disposition_Stage__c: { value: stage } }
    };
}

describe('c-disposition-sidebar', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-sidebar', {
            is: DispositionSidebar
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders no sidebar child before the record wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(element.shadowRoot.querySelector('c-disposition-offer')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
    });

    it('BOV Outreach stage renders the outreach panel only', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('BOV Outreach'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-outreach')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).toBeNull();
    });

    it('Active Listing stage renders the disposition-offer panel only', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Active Listing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).not.toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
    });

    // ── The three stages added to the offer branch. Each is asserted on its own ──
    // ── rather than in a loop, so a failure names the stage that broke.         ──

    it('Call for Offers (on-market) renders the disposition-offer panel', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Call for Offers'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).not.toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
    });

    it('Disposition Offer (off-market) renders the disposition-offer panel', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Disposition Offer'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).not.toBeNull();
    });

    it('LOI renders the disposition-offer panel — the negotiation still lives on the offer', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('LOI'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).not.toBeNull();
    });

    it('PSA renders NO sidebar child — deliberately no placeholder (Gate 1 Q5)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('PSA'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
    });

    it('Disposition Readiness renders NO sidebar child (the record page shows Details)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Disposition Readiness'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
    });

    it('NDA (off-market) renders NO sidebar child — the NDA stage has no offer yet', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('NDA'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
    });

    it('Closing stage renders the closing panel only', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Closing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).not.toBeNull();
    });

    it('Completed stage renders no sidebar child (closing gate is Closing-only)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Completed'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).toBeNull();
    });

    it('ERROR BRANCH: renders an inline error state and no sidebar child when the record wire errors', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('.wire-error')
        ).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
