/**
 * WIRE-MOCK TEMPLATE — @wire to LDS (getRecord)
 * ---------------------------------------------
 * Follows the c-transaction-critical-dates LDS template. c-disposition-main is a
 * single-field router: it reads Disposition__c.Disposition_Stage__c via
 * getRecord + getFieldValue and swaps which feature child renders. So there is
 * NO jest.mock() for LDS — just getRecord.emit(record) with a UI-API record whose
 * fields use the REAL Disposition__c field API name.
 *
 * ⚠ THE TERMINAL STAGE IS 'Sale Closes', NOT 'Completed'. The disposition flow
 * redesign RETIRED 'Completed' (along with 'Call for Offers' and 'Disposition
 * Offer'), so this suite no longer emits it. A fixture that kept emitting a
 * retired value would keep PASSING while proving nothing — the branch simply
 * never fires for a value the org can no longer produce.
 *
 * The child feature components (bov matrix, broker listing, wire verification,
 * closing tasks, ...) render idle: their un-mocked Apex resolves to the
 * transformer's default Promise.resolve() stub, so they mount in an empty state
 * rather than throwing. Assertions check WHICH child slot appears per stage.
 * The accessibility assertion runs against the empty (no-stage) state, which is a
 * guaranteed axe-clean target (matches the headless c-submit-for-approval
 * precedent) and does not depend on grandchild markup.
 */
import { createElement } from 'lwc';
import DispositionMain from 'c/dispositionMain';
import { getRecord } from 'lightning/uiRecordApi';

const RECORD_ID = 'a0D5g000000DispEAG';

function recordForStage(stage) {
    return {
        apiName: 'Disposition__c',
        id: RECORD_ID,
        fields: { Disposition_Stage__c: { value: stage } }
    };
}

describe('c-disposition-main', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-main', {
            is: DispositionMain
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders no feature child before the record wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
    });

    it('BOV Outreach stage renders the comparison matrix only', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('BOV Outreach'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).toBeNull();
    });

    it('Active Listing stage renders the broker-listing cluster', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Active Listing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-backup-brokers')
        ).not.toBeNull();
        // The disposition-scoped call-for-offers card. ⚠ NOT c-call-for-offers-list
        // / c-call-for-offers-panel — those are OPPORTUNITY-scoped (acquisitions
        // buy-side) and are explicitly out of scope for this module.
        expect(
            element.shadowRoot.querySelector('c-disposition-call-for-offers')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).toBeNull();
    });

    it('Closing stage renders wire verification + the closing checklist', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Closing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing-tasks')
        ).not.toBeNull();
    });

    it('Sale Closes stage still shows the closing cards (finished-deal view)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Sale Closes'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing-tasks')
        ).not.toBeNull();
    });

    it('RETIRED VALUE: the old terminal stage routes NOWHERE', async () => {
        // 'Completed' was removed from Disposition_Stage__c and existing rows
        // migrated off it. This is the falsifier for the isClosing rewrite: if
        // someone re-adds it to the getter "to be safe", this test reds. A test
        // that merely stopped mentioning it would not.
        const element = createComponent();

        getRecord.emit(recordForStage('Completed'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing-tasks')
        ).toBeNull();
    });

    it('ERROR BRANCH: renders an inline error state and no feature child when the record wire errors', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-wire-verification')
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
