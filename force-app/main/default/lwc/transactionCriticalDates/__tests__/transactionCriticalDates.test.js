/**
 * WIRE-MOCK TEMPLATE 3 of 3 — @wire to LDS (getRecord)
 * ----------------------------------------------------
 * Copy this shape for any component that reads a record through Lightning Data
 * Service: `@wire(getRecord, { recordId: '$recordId', fields: [...] })` and
 * pulls values with `getFieldValue`.
 *
 * Demonstrated here on c-transaction-critical-dates.
 *
 * KEY TECHNIQUE — the sfdx-lwc-jest `lightning/uiRecordApi` stub already exports
 * `getRecord` as an LDS test wire adapter (createLdsTestWireAdapter) and a REAL
 * `getFieldValue` implementation. So there is NO jest.mock() here — just:
 *   - `getRecord.emit(mockRecord)` -> drives the data branch
 *   - `getRecord.error()`          -> drives the error branch
 *
 * MOCK-DATA SHAPE — getFieldValue reads `record.fields['<Field>'].value`, so the
 * fixture (./data/getRecord.json) is a UI-API record: { apiName, id, fields: {
 * Field__c: { value } } } using this object's REAL field API names. Dates in the
 * fixture are set far in the past / terminal (Feasibility_Missed__c = true,
 * Status__c = 'Closed') so the rendered status pills are stable regardless of the
 * day the suite runs — LDS date components otherwise drift against `new Date()`.
 *
 * A simpler single-field variant of this same template is c-disposition-sidebar
 * (one field, boolean getters, no fixture needed).
 *
 * Conventions inherited from the canonical c-stat-card template:
 *   createElement -> Object.assign props -> appendChild -> await a microtask ->
 *   query shadowRoot; afterEach clears the DOM + jest.clearAllMocks().
 */
import { createElement } from 'lwc';
import TransactionCriticalDates from 'c/transactionCriticalDates';
import { getRecord } from 'lightning/uiRecordApi';

const MOCK_RECORD = require('./data/getRecord.json');

describe('c-transaction-critical-dates', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0A5g000000TxnAEAS' }) {
        const element = createElement('c-transaction-critical-dates', {
            is: TransactionCriticalDates
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state until the record wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.cd-empty').textContent
        ).toBe('No critical dates on this deal yet.');
        expect(element.shadowRoot.querySelectorAll('.cd-row').length).toBe(0);
    });

    it('DATA BRANCH: renders one row per milestone from the LDS record', async () => {
        const element = createComponent();

        getRecord.emit(MOCK_RECORD);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.cd-row');
        expect(rows.length).toBe(4);

        const labels = [...element.shadowRoot.querySelectorAll('.cd-label')].map(
            (el) => el.textContent
        );
        expect(labels).toEqual([
            'Contract Executed',
            'Earnest Money',
            'Feasibility End',
            'Closing'
        ]);
    });

    it('DATA BRANCH: derives status pills + money via getFieldValue', async () => {
        const element = createComponent();

        getRecord.emit(MOCK_RECORD);
        await Promise.resolve();

        // Status pills computed from terminal field values in the fixture.
        const pills = [
            ...element.shadowRoot.querySelectorAll('.cd-pill')
        ].map((el) => el.textContent);
        expect(pills).toEqual(['Executed', 'Funded', 'Missed', 'Closed']);

        // Feasibility_Missed__c = true -> red tone class on that row's pill.
        const missedPill = element.shadowRoot.querySelectorAll('.cd-pill')[2];
        expect(missedPill.className).toContain('cd-pill--red');

        // Earnest_Money__c = 500000 -> formatted as $500k.
        const amount = element.shadowRoot.querySelector('.cd-amount');
        expect(amount.textContent).toBe('$500k');
    });

    it('ERROR BRANCH: surfaces a distinct error message when the record wire errors', async () => {
        const element = createComponent();

        // getRecord.error(body) emits { data: undefined, error }. The component now
        // shows a distinct, announced error state instead of the benign empty copy.
        getRecord.error({ message: 'Critical dates unavailable.' });
        await Promise.resolve();

        const state = element.shadowRoot.querySelector('.cd-empty');
        expect(state).not.toBeNull();
        expect(state.textContent).toBe('Critical dates unavailable.');
        expect(state.getAttribute('role')).toBe('alert');
        expect(element.shadowRoot.querySelectorAll('.cd-row').length).toBe(0);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecord.emit(MOCK_RECORD);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
