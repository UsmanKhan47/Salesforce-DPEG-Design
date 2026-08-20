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
 * stage, so the terminal stage ('Sale Closes') renders no child — asserted below.
 * The accessibility check runs on the empty state (guaranteed axe-clean).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE OFFER-CARD STAGE SET WAS REBUILT BY THE DISPOSITION FLOW REDESIGN
 * ─────────────────────────────────────────────────────────────────────────────
 * c-disposition-offer now renders at 'Active Listing', 'Release Materials',
 * 'Offer Selection' and 'LOI'. 'Call for Offers' and 'Disposition Offer' were
 * REMOVED from Disposition_Stage__c entirely and existing rows migrated off them.
 *
 * 🔴 THE "DISJOINT VALUE SETS" JUSTIFICATION IS DEAD — DO NOT QUOTE IT. This
 * header used to say the two record types' stage value sets "are DISJOINT for
 * every path-specific stage — 'Call for Offers' is On_Market only and
 * 'Disposition Offer' is Off_Market only — so the stage alone identifies the
 * path". Both of those values are gone, AND the premise is now false in the
 * opposite direction: 'Broker Selection', 'Release Materials', 'Offer Selection'
 * and 'Sale Closes' are on BOTH record types. Only 'BOV Outreach' and 'Active
 * Listing' remain path-exclusive.
 *
 * ⚠ THERE IS STILL NO RECORD-TYPE WIRE, AND THAT IS STILL CORRECT — for a new
 * reason. The four offer stages render the SAME card with the SAME meaning on
 * both paths, so there is no per-path DIFFERENCE to express. A stage alone is
 * therefore still all these fixtures need. Add a getObjectInfo/RecordTypeId wire
 * only when a stage genuinely has to RENDER differently per record type.
 *
 * 🔴 RETIRED VALUES ARE ASSERTED TO ROUTE NOWHERE rather than simply dropped from
 * the suite. A fixture that stops mentioning a removed value proves nothing; one
 * that asserts the branch does NOT fire is a falsifier for anyone who re-adds it
 * "to be safe". (Passing tests are not evidence a removal sweep was complete —
 * an LWC fixture is the blind spot of a picklist retirement.)
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

    // ── The other offer stages. Each is asserted on its own rather than in a ──
    // ── loop, so a failure names the stage that broke.                        ──

    it('Release Materials renders the disposition-offer panel (off-market offers arrive here)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Release Materials'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).not.toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
    });

    it('Offer Selection renders the disposition-offer panel — a rejected offer parks here for a RE-PICK', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Offer Selection'));
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

    // ⚠ NDA IS NO LONGER OFF-MARKET-ONLY. The disposition flow redesign moved it
    // into the On-Market path too, so the "NDA is off-market only" doctrine that
    // this test title used to assert is dead. What survives is the real point: at
    // NDA there is no offer yet, on EITHER path.
    it('NDA (both record types) renders NO sidebar child — there is no offer yet', async () => {
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

    it('Sale Closes renders no sidebar child (the closing gate is Closing-only here)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Sale Closes'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).toBeNull();
    });

    // ── 🔴 RETIRED VALUES. These are FALSIFIERS, not leftovers: they red the ──
    // ── moment someone re-adds a removed value to isOfferStage.             ──

    it.each(['Call for Offers', 'Disposition Offer', 'Completed'])(
        'RETIRED VALUE %p routes NOWHERE — it was removed from Disposition_Stage__c',
        async (stage) => {
            const element = createComponent();

            getRecord.emit(recordForStage(stage));
            await Promise.resolve();

            expect(
                element.shadowRoot.querySelector('c-disposition-offer')
            ).toBeNull();
            expect(
                element.shadowRoot.querySelector('c-bov-outreach')
            ).toBeNull();
            expect(
                element.shadowRoot.querySelector('c-disposition-closing')
            ).toBeNull();
        }
    );

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
