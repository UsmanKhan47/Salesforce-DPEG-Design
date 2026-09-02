/**
 * c-transaction-checklist-summary — LDS discriminator + TWO Apex @wire READS, no writes.
 *
 * The one-line sidebar card. Same dual-model contract as its two siblings; the additional thing
 * pinned here is that it computes its percentage from the SAME normalised rows the checklist
 * itself renders, through the SAME `percent()` helper — not from `Transaction__c.Completion_Pct__c`.
 * Both components sit on a Transaction record page simultaneously, and a summary reading 41%
 * above a checklist showing 42% is the kind of contradiction that makes people stop trusting the
 * screen.
 *
 * 🔴 `getLastConfig()`, NOT "nothing rendered" — an Apex test wire adapter's `emit()` ignores its
 * config, so a component that wired both models would still render correctly.
 */
import { createElement } from 'lwc';
import TransactionChecklistSummary from 'c/transactionChecklistSummary';
import { getRecord } from 'lightning/uiRecordApi';
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';

jest.mock(
    '@salesforce/apex/ChecklistController.getChecklist',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TransactionTaskController.getTaskGroups',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a0V5g00000Txn99AAB';

/** 1 + 2 of 3 + 9 = 3 of 12 = 25%. */
const CHECKLIST_ROWS = [
    { id: 'g1', letter: 'A', name: 'Contract', stage: 'Open Contract', total: 3, complete: 1, pct: 33, items: [] },
    { id: 'g2', letter: 'C', name: 'Diligence', stage: 'Due Diligence', total: 9, complete: 2, pct: 22, items: [] }
];

const LEGACY_ROWS = [
    { key: 'A. Contract', letter: 'A', name: 'Contract', total: 4, complete: 4, pct: 100, tasks: [] }
];

function transactionRecord(fannedOut) {
    return {
        id: RECORD_ID,
        apiName: 'Transaction__c',
        fields: { Checklist_Fanned_Out__c: { value: fannedOut, displayValue: null } }
    };
}

function createComponent() {
    const element = createElement('c-transaction-checklist-summary', {
        is: TransactionChecklistSummary
    });
    element.recordId = RECORD_ID;
    document.body.appendChild(element);
    return element;
}

async function flush() {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
}

const pct = (el) => el.shadowRoot.querySelector('.cs-pct').textContent.trim();
const count = (el) => el.shadowRoot.querySelector('.cs-count').textContent.trim();

describe('c-transaction-checklist-summary', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('wires ONLY the checklist Apex on a migrated deal, and totals across every group', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
        expect(getTaskGroups.getLastConfig()).toEqual({ transactionId: undefined });
        expect(pct(element)).toBe('25%');
        expect(count(element)).toBe('3 of 12 complete');
    });

    it('wires ONLY the legacy Apex on an un-migrated deal', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(false));
        await flush();
        getTaskGroups.emit(LEGACY_ROWS);
        await flush();

        expect(getTaskGroups.getLastConfig()).toEqual({ transactionId: RECORD_ID });
        expect(getChecklist.getLastConfig()).toEqual({ transactionId: undefined });
        expect(pct(element)).toBe('100%');
        expect(count(element)).toBe('4 of 4 complete');
    });

    it('writes a WIDTH-ONLY bar style and moves the colour to a modifier class', async () => {
        // Two facts: the attribute exists at all (an undefined getter makes LWC omit it, the
        // silent form of the same bug), and no colour is built in JavaScript where the SLDS
        // linter cannot see it.
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        const bar = element.shadowRoot.querySelector('.cs-bar');
        expect(bar.getAttribute('style')).toMatch(/^width:\s*\d+%;?$/);
        // Carried over from the pre-Phase-3 suite: the width must be the PERCENTAGE, not merely
        // well-formed. A regex alone would pass on a bar stuck at 0%.
        expect(bar.style.width).toBe('25%');
        expect(bar.classList.contains('cs-bar--done')).toBe(false);
    });

    it('switches the bar to the done modifier at 100%', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(false));
        await flush();
        getTaskGroups.emit(LEGACY_ROWS);
        await flush();

        expect(element.shadowRoot.querySelector('.cs-bar').classList.contains('cs-bar--done')).toBe(
            true
        );
    });

    it('reads Loading… BETWEEN the discriminator and the data, not a diagnosis', async () => {
        // 🔴 Gated on the discriminator alone this card rendered "Checklist generated, but no
        // items found" on every page load of a healthy deal — a sentence whose entire purpose is
        // to say something is WRONG. The assertion has to sit BETWEEN the two emits.
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();

        expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
        expect(count(element)).toBe('Loading…');

        // Presence control — waiting, not wedged.
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();
        expect(count(element)).toBe('3 of 12 complete');
    });

    it('names the model in its empty text — an empty NEW checklist is a different problem', async () => {
        // Checklist_Fanned_Out__c is true, so the fan-out RAN and produced nothing. That is not
        // the same as a deal that was never fanned out, and the two must not read alike.
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit([]);
        await flush();

        expect(pct(element)).toBe('—');
        expect(count(element)).toBe('Checklist generated, but no items found');
    });

    it('uses the legacy wording when the deal has never been fanned out', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(false));
        await flush();
        getTaskGroups.emit([]);
        await flush();

        expect(count(element)).toBe('No checklist generated yet');
    });

    it('renders an error and NO progress line when the discriminator cannot be read', async () => {
        const element = createComponent();
        getRecord.error();
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        getTaskGroups.emit(LEGACY_ROWS);
        await flush();

        expect(element.shadowRoot.querySelector('.cs-error')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.cs-pct')).toBeNull();
    });

    it('renders the error MESSAGE when the DATA read fails, not just an error container', async () => {
        // Carried over from the pre-Phase-3 suite, plus its point: the "—" / "no checklist" copy
        // must NOT show on a load failure, because it reads as a successful load of nothing.
        const element = createComponent();
        getRecord.emit(transactionRecord(false));
        await flush();
        getTaskGroups.error({ message: 'Checklist summary unavailable.' });
        await flush();

        expect(element.shadowRoot.querySelector('.cs-pct')).toBeNull();
        const err = element.shadowRoot.querySelector('.cs-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Checklist summary unavailable.');
    });

    it('shows a loading label, not a zero, before the discriminator resolves', async () => {
        const element = createComponent();
        await flush();
        expect(element.shadowRoot.querySelector('.cs-error')).toBeNull();
        expect(count(element)).toBe('Loading…');
    });

    it('is accessible with data', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();
        await expect(element).toBeAccessible();
    });

    it('is accessible in the error state', async () => {
        const element = createComponent();
        getRecord.error();
        await flush();
        await expect(element).toBeAccessible();
    });
});
