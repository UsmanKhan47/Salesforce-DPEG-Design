/**
 * WIRE-MOCK TEMPLATE — @wire to LDS (getRecord)
 * ---------------------------------------------
 * Follows the c-transaction-critical-dates LDS template. c-disposition-main is a
 * single-field router: it reads Disposition__c.Disposition_Stage__c via
 * getRecord + getFieldValue and swaps which feature child renders. So there is
 * NO jest.mock() for LDS — just getRecord.emit(record) with a UI-API record whose
 * fields use the REAL Disposition__c field API name.
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

    it('Completed stage still shows the closing cards (finished-deal view)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Completed'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing-tasks')
        ).not.toBeNull();
    });

    it('ERROR BRANCH: renders no feature child when the record wire errors', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
