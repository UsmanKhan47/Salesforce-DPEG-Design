/**
 * c-transaction-phase-cards — ONE Apex @wire READ plus an ADVISORY LDS read, no writes.
 *
 * The sidebar twin of `c-transaction-task-groups`: same shared normaliser, so the same things
 * are pinned here.
 *
 * 🔴 AMENDED 2026-09-03 (M5) — THE SECOND MODEL AND ITS DISCRIMINATOR ARE GONE.
 * The suite carried a matched pair — "wires ONLY the checklist Apex on a migrated deal" and
 * "wires ONLY the legacy Apex on an un-migrated deal" — each asserting the OTHER model's
 * `getLastConfig()` was `{ transactionId: undefined }`. With `TransactionTaskController`
 * deleted the second half cannot exist, and the first half's negative clause has no subject.
 * ⇒ Replaced by a parameterised test that asserts the config on BOTH flag values, which is the
 * property that matters now: the Apex read no longer depends on the flag at all. A stray
 * `fannedOut ?` guard reintroduced on the wire parameter reds the `false` row.
 *
 * 🔴 THE LDS READ SURVIVES, DEMOTED TO ADVISORY — it now only selects the wording of
 * `emptyMessage`. A failed flag read is therefore NO LONGER FATAL, and the test below pins the
 * inversion: blanking the cards on that failure would hide data that loaded perfectly well.
 *
 * 🔴 THE PHASE LABELS. This component used to carry its OWN copy of the PHASES array, which is
 * how it drifted to `Closing` / `Post Closing` while `Transaction__c.Stage__c` said `Closing Prep`
 * / `Post-Closing` (design §2.12). The array now lives in `c/utilsTransactionChecklist` and the
 * assertions below are an absence pin on the old spellings WITH a presence control on the new
 * ones — an absence pin alone would pass just as happily against four cards that failed to render
 * at all.
 *
 * 🔴 `getLastConfig()`, NOT "nothing rendered". An Apex test wire adapter's `emit()` ignores its
 * config, so a component that called Apex with the wrong argument would still render correctly
 * and still be wrong. The config assertions are the only honest check.
 */
import { createElement } from 'lwc';
import TransactionPhaseCards from 'c/transactionPhaseCards';
import { getRecord } from 'lightning/uiRecordApi';
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';

jest.mock(
    '@salesforce/apex/ChecklistController.getChecklist',
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

/**
 * A checklist filling only TWO of the four phases, so the other two must read `0 / 0` rather
 * than vanishing. (Was `LEGACY_ROWS` until M5; the retired legacy fixture was the only place
 * this partial-coverage case was exercised, so it was re-expressed on the surviving model
 * rather than dropped with it.)
 */
const PARTIAL_ROWS = [
    { id: 'g1', letter: 'A', name: 'Contract', stage: 'Open Contract', total: 6, complete: 6, pct: 100, items: [] },
    { id: 'g4', letter: 'J', name: 'Post', stage: 'Post-Closing', total: 15, complete: 3, pct: 20, items: [] }
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

    it.each([
        ['a fanned-out deal', true],
        ['a deal that was never fanned out', false]
    ])(
        'wires the checklist Apex with the recordId on %s — the read no longer depends on the flag',
        async (_label, fannedOut) => {
            // 🔴 THE REPLACEMENT FOR THE DELETED DISCRIMINATOR PAIR (M5). Before M5 a `false`
            // flag meant the checklist Apex was NOT called at all. A single-flag test cannot
            // distinguish "the flag is ignored" from "the flag happens to be true".
            const element = createComponent();
            getRecord.emit(transactionRecord(fannedOut));
            await flush();
            getChecklist.emit(CHECKLIST_ROWS);
            await flush();

            expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
            expect(cards(element)).toHaveLength(4);
        }
    );

    it('renders 0 / 0 for a phase with no groups rather than dropping the card', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(PARTIAL_ROWS);
        await flush();

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

    it('shows NEITHER the empty message NOR cards BEFORE the Apex data arrives', async () => {
        // 🔴 See the matching test in c-transaction-task-groups. Ungated, this component renders
        // "No checklist has been generated for this deal yet" on every page load of a healthy
        // deal. The assertion has to sit BEFORE the Apex emit. (Pre-M5 it sat between the
        // discriminator emit and the Apex emit; the discriminator is gone, the hazard is not.)
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();

        expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
        expect(element.shadowRoot.querySelector('.kpi-empty')).toBeNull();
        expect(element.shadowRoot.querySelector('.kpi-error')).toBeNull();
        expect(cards(element)).toHaveLength(0);

        // Presence control — waiting, not wedged.
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();
        expect(cards(element)).toHaveLength(4);
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

    it('still renders the CARDS when the ADVISORY flag read fails but data arrives', async () => {
        // 🔴 THE INVERTED ASSERTION (M5). This test previously read "renders an error and NO
        // cards when the discriminator cannot be read", and that was CORRECT while the flag
        // chose the data model. The flag is now advisory — it only picks the wording of
        // emptyMessage — so blanking the grid on its failure would HIDE data that loaded
        // perfectly well. Renamed rather than edited in place so a reviewer reading the diff
        // cannot mistake a reversed expectation for a weakened one.
        const element = createComponent();
        getRecord.error();
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        expect(element.shadowRoot.querySelector('.kpi-error')).toBeNull();
        expect(cards(element)).toHaveLength(4);
    });

    it('falls back to neutral empty copy when the advisory flag read fails and there is no data', async () => {
        // The empty-state half of the test above. The component cannot say WHY it is empty
        // without the flag, so it must say only what is certainly true.
        const element = createComponent();
        getRecord.error();
        await flush();
        getChecklist.emit([]);
        await flush();

        expect(element.shadowRoot.querySelector('.kpi-error')).toBeNull();
        const empty = element.shadowRoot.querySelector('.kpi-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toBe('No checklist items to show for this deal.');
    });

    it('shows neither an error nor an empty message before anything resolves', async () => {
        // ⚠ DELIBERATE BEHAVIOUR CHANGE FROM THE PRE-PHASE-3 SUITE, which asserted four `0 / 0`
        // cards in this state. Four zeroed cards read as "the checklist loaded and nothing is
        // done" — a factual claim the component cannot yet make, because nothing has loaded.
        // Rendering nothing is the honest state.
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
        getChecklist.error({ message: 'Phase progress unavailable.' });
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
