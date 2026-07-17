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

    it('ERROR BRANCH: renders no sidebar child when the record wire errors', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-disposition-offer')
        ).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
