/**
 * c-transaction-phase-cards — LDS discriminator + TWO Apex @wire READS, no writes.
 *
 * The sidebar twin of `c-transaction-task-groups`: same dual-model contract, same shared
 * normaliser, so the same two things are pinned here.
 *
 * 🔴 THE PHASE LABELS. This component used to carry its OWN copy of the PHASES array, which is
 * how it drifted to `Closing` / `Post Closing` while `Transaction__c.Stage__c` said `Closing Prep`
 * / `Post-Closing` (design §2.12). The array now lives in `c/utilsTransactionChecklist` and the
 * assertions below are an absence pin on the old spellings WITH a presence control on the new
 * ones — an absence pin alone would pass just as happily against four cards that failed to render
 * at all.
 *
 * 🔴 `getLastConfig()`, NOT "nothing rendered". An Apex test wire adapter's `emit()` ignores its
 * config, so a component wiring BOTH models on every page view would render correctly and still
 * be wrong. The config assertions are the only honest check.
 */
import { createElement } from 'lwc';
import TransactionPhaseCards from 'c/transactionPhaseCards';
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

/** One group per phase, so all four cards carry a real number. */
const CHECKLIST_ROWS = [
    { id: 'g1', letter: 'A', name: 'Contract', stage: 'Open Contract', total: 6, complete: 6, pct: 100, items: [] },
    { id: 'g2', letter: 'C', name: 'Diligence', stage: 'Due Diligence', total: 7, complete: 2, pct: 29, items: [] },
    { id: 'g3', letter: 'I', name: 'Closing', stage: 'Closing Prep', total: 10, complete: 0, pct: 0, items: [] },
    { id: 'g4', letter: 'J', name: 'Post', stage: 'Post-Closing', total: 15, complete: 3, pct: 20, items: [] }
];

const LEGACY_ROWS = [
    { key: 'A. Contract', letter: 'A', name: 'Contract', total: 6, complete: 6, pct: 100, tasks: [] },
    { key: 'J. Post', letter: 'J', name: 'Post', total: 15, complete: 3, pct: 20, tasks: [] }
];

function transactionRecord(fannedOut) {
    return {
        id: RECORD_ID,
        apiName: 'Transaction__c',
        fields: { Checklist_Fanned_Out__c: { value: fannedOut, displayValue: null } }
    };
}

function createComponent() {
    const element = createElement('c-transaction-phase-cards', { is: TransactionPhaseCards });
    element.recordId = RECORD_ID;
    document.body.appendChild(element);
    return element;
}

async function flush() {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
}

function cards(element) {
    return [...element.shadowRoot.querySelectorAll('c-onboarding-card-child')];
}

describe('c-transaction-phase-cards', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('wires ONLY the checklist Apex on a migrated deal', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
        expect(getTaskGroups.getLastConfig()).toEqual({ transactionId: undefined });
        expect(cards(element)).toHaveLength(4);
    });

    it('wires ONLY the legacy Apex on an un-migrated deal', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(false));
        await flush();
        getTaskGroups.emit(LEGACY_ROWS);
        await flush();

        expect(getTaskGroups.getLastConfig()).toEqual({ transactionId: RECORD_ID });
        expect(getChecklist.getLastConfig()).toEqual({ transactionId: undefined });
        // Legacy fixture only fills two phases; the other two read 0 / 0 rather than vanishing.
        expect(cards(element).map((c) => c.value)).toEqual(['6 / 6', '0 / 0', '0 / 0', '3 / 15']);
    });

    it('labels the four cards the way the DATA spells the stages', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        const labels = cards(element).map((c) => c.label);
        // Presence control first, so the absence pin below cannot pass vacuously.
        expect(labels).toEqual(['Open Contract', 'Due Diligence', 'Closing Prep', 'Post-Closing']);
        expect(labels).not.toContain('Closing');
        expect(labels).not.toContain('Post Closing');
    });

    it('buckets a group by its STAGE, not by its letter', async () => {
        // Letter J would map to Post-Closing; the stage says Closing Prep and must win.
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit([
            { id: 'g9', letter: 'J', name: 'Odd', stage: 'Closing Prep', total: 4, complete: 1, pct: 25, items: [] }
        ]);
        await flush();

        const byLabel = {};
        cards(element).forEach((c) => {
            byLabel[c.label] = c.value;
        });
        expect(byLabel['Closing Prep']).toBe('1 / 4');
        expect(byLabel['Post-Closing']).toBe('0 / 0');
    });

    it('marks a phase done only when every item in it is complete', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        const done = cards(element).map((c) => c.done);
        expect(done).toEqual([true, false, false, false]);
    });

    it('passes a TOKEN-BACKED icon colour, never a bare hex', async () => {
        // The child interpolates this into a CSS custom property, so a literal hex here would be
        // invisible to the SLDS linter (which only reads .css) and would pin a colour an SLDS 2
        // palette override could not reach.
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        cards(element).forEach((c) => {
            expect(c.iconColor).toMatch(/^var\(--slds-g-color-/);
        });
    });

    it('renders an explicit empty message instead of four 0 / 0 cards', async () => {
        // "No checklist exists" and "a checklist exists with nothing done" are different
        // statements and must not look alike.
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit([]);
        await flush();

        expect(cards(element)).toHaveLength(0);
        expect(element.shadowRoot.querySelector('.kpi-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.kpi-error')).toBeNull();
    });

    it('renders an error and NO cards when the discriminator cannot be read', async () => {
        const element = createComponent();
        getRecord.error();
        await flush();
        // Pushed anyway — emit() ignores config — so this proves refusal, not absence.
        getChecklist.emit(CHECKLIST_ROWS);
        getTaskGroups.emit(LEGACY_ROWS);
        await flush();

        expect(element.shadowRoot.querySelector('.kpi-error')).not.toBeNull();
        expect(cards(element)).toHaveLength(0);
        expect(element.shadowRoot.querySelector('.kpi-empty')).toBeNull();
    });

    it('shows neither an error nor an empty message before the discriminator resolves', async () => {
        // ⚠ DELIBERATE BEHAVIOUR CHANGE FROM THE PRE-PHASE-3 SUITE, which asserted four `0 / 0`
        // cards in this state. Four zeroed cards read as "the checklist loaded and nothing is
        // done" — a factual claim the component cannot yet make, because it does not even know
        // which model the deal is on. Rendering nothing is the honest state.
        const element = createComponent();
        await flush();
        expect(element.shadowRoot.querySelector('.kpi-error')).toBeNull();
        expect(element.shadowRoot.querySelector('.kpi-empty')).toBeNull();
        expect(cards(element)).toHaveLength(0);
    });

    it('renders the error MESSAGE when the DATA read fails, not just an error container', async () => {
        // Carried over from the pre-Phase-3 suite. Asserting only that `.kpi-error` exists would
        // still pass if the component rendered an empty red box.
        const element = createComponent();
        getRecord.emit(transactionRecord(false));
        await flush();
        getTaskGroups.error({ message: 'Phase progress unavailable.' });
        await flush();

        expect(cards(element)).toHaveLength(0);
        const err = element.shadowRoot.querySelector('.kpi-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Phase progress unavailable.');
    });

    it('is accessible with data', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();
        await expect(element).toBeAccessible();
    });

    it('is accessible in the empty state', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit([]);
        await flush();
        await expect(element).toBeAccessible();
    });
});
