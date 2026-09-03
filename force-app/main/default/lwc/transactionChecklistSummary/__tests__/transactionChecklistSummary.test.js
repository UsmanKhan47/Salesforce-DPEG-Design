/**
 * c-transaction-checklist-summary — ONE Apex @wire READ plus an ADVISORY LDS read, no writes.
 *
 * The one-line sidebar card. The thing pinned here is that it computes its percentage from the
 * SAME normalised rows the checklist itself renders, through the SAME `percent()` helper — not
 * from `Transaction__c.Completion_Pct__c`. Both components sit on a Transaction record page
 * simultaneously, and a summary reading 41% above a checklist showing 42% is the kind of
 * contradiction that makes people stop trusting the screen.
 *
 * 🔴 AMENDED 2026-09-03 (M5) — THE SECOND MODEL AND ITS DISCRIMINATOR ARE GONE, AND ONE PAIRED
 * ASSERTION HAD TO BE REPLACED RATHER THAN HALVED.
 * The suite carried a matched pair: "wires ONLY the checklist Apex on a migrated deal" and
 * "wires ONLY the legacy Apex on an un-migrated deal", each asserting the OTHER model's
 * `getLastConfig()` was `{ transactionId: undefined }`. With `TransactionTaskController` deleted
 * the second half cannot exist, and the first half's negative clause has no subject — so it
 * would have degraded to "the checklist Apex was called", which is true of a component that
 * called it with the wrong argument or at the wrong time.
 * ⇒ The replacement asserts the config on BOTH flag values, which is the property that actually
 * matters now: the Apex read no longer depends on the flag at all.
 *
 * 🔴 THE LDS READ IS RETAINED AND IS NOW ADVISORY. It selects the wording of the empty state
 * ("fanned out and empty" vs "never fanned out"), nothing else. A FAILED LDS read is therefore
 * NO LONGER FATAL — the tests below pin that, because the old behaviour (blank the whole card)
 * would now be a regression: it would hide a checklist that loaded perfectly well.
 */
import { createElement } from 'lwc';
import TransactionChecklistSummary from 'c/transactionChecklistSummary';
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

/** 1 + 2 of 3 + 9 = 3 of 12 = 25%. */
const CHECKLIST_ROWS = [
    { id: 'g1', letter: 'A', name: 'Contract', stage: 'Open Contract', total: 3, complete: 1, pct: 33, items: [] },
    { id: 'g2', letter: 'C', name: 'Diligence', stage: 'Due Diligence', total: 9, complete: 2, pct: 22, items: [] }
];

/** A fully-complete checklist, for the 100% done-modifier case. */
const COMPLETE_ROWS = [
    { id: 'g1', letter: 'A', name: 'Contract', stage: 'Open Contract', total: 4, complete: 4, pct: 100, items: [] }
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

    it('wires the checklist Apex with the recordId, and totals across every group', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
        expect(pct(element)).toBe('25%');
        expect(count(element)).toBe('3 of 12 complete');
    });

    it.each([
        ['a fanned-out deal', true],
        ['a deal that was never fanned out', false]
    ])(
        'wires the checklist Apex on %s — the read no longer depends on the flag',
        async (_label, fannedOut) => {
            // 🔴 THE REPLACEMENT FOR THE DELETED DISCRIMINATOR PAIR (M5). Before M5 a `false`
            // flag meant the checklist Apex was NOT called at all and the legacy one was. If the
            // discriminator were ever reintroduced by accident — a stray `fannedOut ?` guard on
            // the wire parameter — the `false` row here goes red with
            // `{ transactionId: undefined }`. A single-flag test cannot see that.
            const element = createComponent();
            getRecord.emit(transactionRecord(fannedOut));
            await flush();
            getChecklist.emit(CHECKLIST_ROWS);
            await flush();

            expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
            expect(count(element)).toBe('3 of 12 complete');
        }
    );

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
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit(COMPLETE_ROWS);
        await flush();

        expect(element.shadowRoot.querySelector('.cs-bar').classList.contains('cs-bar--done')).toBe(
            true
        );
    });

    it('reads Loading… BEFORE the Apex data arrives, not a diagnosis', async () => {
        // 🔴 Ungated, this card renders "Checklist generated, but no items found" on every page
        // load of a healthy deal — a sentence whose entire purpose is to say something is WRONG.
        // The assertion has to sit BEFORE the Apex emit. (Pre-M5 it sat between the discriminator
        // emit and the Apex emit; the discriminator is gone, the hazard is not.)
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

    it('names the CAUSE in its empty text — a fanned-out empty checklist is a different problem', async () => {
        // Checklist_Fanned_Out__c is true, so the fan-out RAN and produced nothing. That is not
        // the same as a deal that was never fanned out, and the two must not read alike.
        // ⚠ This distinction used to fall out of the model discriminator. It now reads the flag
        // directly, which is the only reason the flag wire survives M5 — see the component header.
        const element = createComponent();
        getRecord.emit(transactionRecord(true));
        await flush();
        getChecklist.emit([]);
        await flush();

        expect(pct(element)).toBe('—');
        expect(count(element)).toBe('Checklist generated, but no items found');
    });

    it('uses the not-yet wording when the deal has never been fanned out', async () => {
        const element = createComponent();
        getRecord.emit(transactionRecord(false));
        await flush();
        getChecklist.emit([]);
        await flush();

        expect(count(element)).toBe('No checklist generated yet');
    });

    it('falls back to neutral empty copy — not an error — when the ADVISORY flag read fails', async () => {
        // 🔴 THE INVERTED ASSERTION (M5). This test previously read "renders an error and NO
        // progress line when the discriminator cannot be read", and that was CORRECT while the
        // flag chose the data model: without it the component could not know what to render.
        // The flag is now advisory, so blanking the card on its failure would HIDE a checklist
        // that loaded perfectly well. Renamed rather than edited in place so a reviewer reading
        // the diff cannot mistake this for a weakened assertion — the expectation is reversed on
        // purpose, and the component changed to match.
        const element = createComponent();
        getRecord.error();
        await flush();
        getChecklist.emit([]);
        await flush();

        expect(element.shadowRoot.querySelector('.cs-error')).toBeNull();
        expect(count(element)).toBe('No checklist items to show');
    });

    it('still renders the PROGRESS LINE when the advisory flag read fails but data arrives', async () => {
        // The presence control for the test above: proving the empty copy is neutral is only
        // meaningful if a failed flag read does not suppress real data either.
        const element = createComponent();
        getRecord.error();
        await flush();
        getChecklist.emit(CHECKLIST_ROWS);
        await flush();

        expect(element.shadowRoot.querySelector('.cs-error')).toBeNull();
        expect(pct(element)).toBe('25%');
        expect(count(element)).toBe('3 of 12 complete');
    });

    it('renders the error MESSAGE when the DATA read fails, not just an error container', async () => {
        // Carried over from the pre-Phase-3 suite, plus its point: the "—" / "no checklist" copy
        // must NOT show on a load failure, because it reads as a successful load of nothing.
        const element = createComponent();
        getRecord.emit(transactionRecord(false));
        await flush();
        getChecklist.error({ message: 'Checklist summary unavailable.' });
        await flush();

        expect(element.shadowRoot.querySelector('.cs-pct')).toBeNull();
        const err = element.shadowRoot.querySelector('.cs-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Checklist summary unavailable.');
    });

    it('shows a loading label, not a zero, before anything resolves', async () => {
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
