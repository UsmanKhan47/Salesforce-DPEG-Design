/**
 * c-transaction-task-groups — LDS discriminator + TWO Apex @wire READS + FOUR imperative WRITES.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE PREVIOUS VERSION OF THIS SUITE WOULD HAVE PASSED VACUOUSLY AGAINST THE REWRITE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Every "critical" fixture it carried ALSO ended in `(anti-fraud)` or `(CRITICAL)`, so a
 * component reading boolean fields and a component parsing subject text produced identical DOM
 * against it. It could not tell the two apart, which is exactly the blind spot design §6.2 warns
 * about. The fixtures below break that tie on purpose — see `MARKERLESS_CRITICAL` and
 * `MARKED_BUT_NOT_CRITICAL`, and the module-level suite in
 * `c/utilsTransactionChecklist/__tests__` which pins the same facts without a DOM.
 *
 * ── WHAT IS MOCKED AND WHY ──────────────────────────────────────────────────────────────────
 * `getRecord` (LDS) needs no `jest.mock()` — the sfdx-lwc-jest stub already exposes it as a test
 * wire adapter, and `getFieldValue` is a real implementation there. The four Apex modules are
 * `createApexTestWireAdapter` (reads) and plain `jest.fn()` (writes).
 *
 * 🔴 `emit()` ON AN APEX TEST WIRE ADAPTER IGNORES THE CONFIG. It delivers data to the component
 * whether or not the real adapter would have been called, so "the legacy wire rendered nothing"
 * is NOT evidence that the legacy Apex was skipped. The only honest check is
 * `getLastConfig()` — asserted on BOTH adapters in the discrimination tests below. A component
 * that wired both models unconditionally would render correctly and still be wrong (two Apex
 * round-trips per page view, and a legacy read against a migrated deal).
 *
 * ⚠ COMPLETION-DATE TEXT RUNS `new Date()` MATH and is timezone-drifting, so it is never
 * asserted. Structural DOM (subjects, flags, counts, phase labels, disabled state) is stable.
 */
import { createElement } from 'lwc';
import TransactionTaskGroups from 'c/transactionTaskGroups';
import { getRecord, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';
import completeItem from '@salesforce/apex/ChecklistController.completeItem';
import recordWireVerification from '@salesforce/apex/ChecklistController.recordWireVerification';
import getCaptureContext from '@salesforce/apex/ChecklistController.getCaptureContext';
import linkCaptureDocuments from '@salesforce/apex/ChecklistController.linkCaptureDocuments';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';
import completeTask from '@salesforce/apex/TransactionTaskController.completeTask';
import completeWireVerification from '@salesforce/apex/TransactionTaskController.completeWireVerification';

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
jest.mock(
    '@salesforce/apex/ChecklistController.completeItem',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/ChecklistController.recordWireVerification',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
// Phase 5. Both are imperative — `getCaptureContext` performs DML (it provisions the Loan__c /
// Insurance_Binder__c), so it is deliberately NOT a cacheable wire and is mocked as a plain fn.
jest.mock(
    '@salesforce/apex/ChecklistController.getCaptureContext',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/ChecklistController.linkCaptureDocuments',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TransactionTaskController.completeTask',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TransactionTaskController.completeWireVerification',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a0V5g00000Txn99AAB';

/**
 * 🔴 THE CANARY SUBJECT. Contains NEITHER `(anti-fraud)` NOR `(CRITICAL)`, but the record's
 * `isCritical` / `isWireVerification` are true. A component that still parses subjects renders
 * this row plain, and the assertions on it fail.
 */
const MARKERLESS_CRITICAL = 'Confirm wiring instructions verbally with the escrow officer';

/** 🔴 THE CONVERSE CANARY. Carries the marker, but the booleans say it is an ordinary step. */
const MARKED_BUT_NOT_CRITICAL = 'Order the ALTA survey (anti-fraud)';

/** New-model payload: `ChecklistController.ChecklistRow[]`. Member names are the wire contract. */
const CHECKLIST_ROWS = [
    {
        id: 'a1Y000000000AAA',
        letter: 'B',
        name: 'Earnest Money & Wires',
        ownerLabel: 'Danish',
        conditional: false,
        stage: 'Open Contract',
        total: 4,
        complete: 1,
        pct: 25,
        items: [
            {
                id: 'i-wire',
                subject: MARKERLESS_CRITICAL,
                ownerLabel: 'Danish',
                sequence: 2,
                flag: 'CRITICAL',
                done: false,
                isCritical: true,
                isWireVerification: true,
                verifyComplete: false,
                verifiedByName: null,
                phone: null,
                verifiedAt: null,
                comment: null,
                dueDate: '2026-09-10',
                completedByName: null,
                completedDateTime: null,
                blocked: false
            },
            {
                id: 'i-plain',
                subject: MARKED_BUT_NOT_CRITICAL,
                ownerLabel: 'Danish',
                sequence: 3,
                flag: 'None',
                done: false,
                isCritical: false,
                isWireVerification: false,
                verifyComplete: false,
                blocked: false
            },
            {
                id: 'i-blocked',
                subject: 'Send wire request to accounting with verified instructions',
                ownerLabel: 'Accounting',
                sequence: 4,
                flag: 'None',
                done: false,
                isCritical: false,
                isWireVerification: false,
                verifyComplete: false,
                blocked: true
            },
            {
                id: 'i-done',
                subject: 'Fully execute PSA',
                ownerLabel: 'Legal',
                sequence: 1,
                flag: 'Completed',
                done: true,
                isCritical: false,
                isWireVerification: false,
                verifyComplete: false,
                comment: 'Executed via DocuSign',
                // ⚠ DELIBERATELY DIFFERENT FROM ownerLabel ('Legal'). Pairing the static ROLE with
                // a completion date was the 2026-08-28 defect; a regression that reverts to
                // ownerLabel goes red here instead of passing on identical strings.
                completedByName: 'Usman Khan',
                completedDateTime: '2026-08-20T14:04:00.000Z',
                blocked: false
            }
        ]
    },
    {
        id: 'a1Y000000000BBB',
        letter: 'I',
        name: 'Closing',
        ownerLabel: 'Danish',
        conditional: false,
        stage: 'Closing Prep',
        total: 1,
        complete: 0,
        pct: 0,
        items: [
            {
                id: 'i-close',
                subject: 'Send closing wire to title company',
                sequence: 8,
                flag: 'None',
                done: false,
                isCritical: false,
                isWireVerification: false,
                verifyComplete: false,
                blocked: false
            }
        ]
    }
];

/** Legacy payload: `TransactionTaskController.GroupRow[]`. */
const LEGACY_ROWS = [
    {
        key: 'B. Earnest Money & Wires',
        letter: 'B',
        name: 'Earnest Money & Wires',
        ownerLabel: 'Danish',
        conditional: false,
        total: 2,
        complete: 0,
        pct: 0,
        tasks: [
            {
                id: 't-wire',
                subject: 'Call title company to verbally verify wiring instructions (anti-fraud)',
                done: false,
                verifyComplete: false,
                verifiedBy: null,
                notes: null,
                ownerLabel: 'Danish',
                completedByName: null,
                completedDate: null,
                phone: null,
                verifiedAt: null
            },
            {
                id: 't-plain',
                subject: 'Open escrow',
                done: false,
                verifyComplete: false,
                notes: null,
                ownerLabel: 'Danish'
            }
        ]
    }
];

/** The LDS record carrying the discriminator. */
function transactionRecord(fannedOut) {
    return {
        id: RECORD_ID,
        apiName: 'Transaction__c',
        fields: {
            Checklist_Fanned_Out__c: { value: fannedOut, displayValue: null }
        }
    };
}

function createComponent(phase) {
    const element = createElement('c-transaction-task-groups', {
        is: TransactionTaskGroups
    });
    element.recordId = RECORD_ID;
    if (phase) {
        element.phase = phase;
    }
    document.body.appendChild(element);
    return element;
}

/** Settles the wire -> getter -> re-render chain. Two ticks: model resolves, then data renders. */
async function flush() {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
}

/** Mounts on the NEW model with the standard fixture. */
async function renderChecklist(rows = CHECKLIST_ROWS, phase) {
    const element = createComponent(phase);
    getRecord.emit(transactionRecord(true));
    await flush();
    getChecklist.emit(rows);
    await flush();
    return element;
}

/** Mounts on the LEGACY model with the standard fixture. */
async function renderLegacy(rows = LEGACY_ROWS, phase) {
    const element = createComponent(phase);
    getRecord.emit(transactionRecord(false));
    await flush();
    getTaskGroups.emit(rows);
    await flush();
    return element;
}

function textOf(element, selector) {
    return [...element.shadowRoot.querySelectorAll(selector)].map((n) => n.textContent.trim());
}

describe('c-transaction-task-groups', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Model discrimination — the migration-window contract.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    describe('model discrimination', () => {
        it('wires ONLY the checklist Apex when Checklist_Fanned_Out__c is true', async () => {
            await renderChecklist();
            expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
            // 🔴 The legacy adapter must be provisioned with an UNDEFINED parameter, which is what
            // stops LWC calling it at all. Asserting only "no legacy rows rendered" would pass
            // even if both models were queried on every page view.
            expect(getTaskGroups.getLastConfig()).toEqual({ transactionId: undefined });
        });

        it('wires ONLY the legacy Apex when Checklist_Fanned_Out__c is false', async () => {
            await renderLegacy();
            expect(getTaskGroups.getLastConfig()).toEqual({ transactionId: RECORD_ID });
            expect(getChecklist.getLastConfig()).toEqual({ transactionId: undefined });
        });

        it('renders an error and NEITHER model when the discriminator cannot be read', async () => {
            const element = createComponent();
            getRecord.error();
            await flush();
            // Both payloads are pushed anyway — emit() ignores the config — so this proves the
            // component refuses to render EITHER, rather than proving nothing arrived.
            getChecklist.emit(CHECKLIST_ROWS);
            getTaskGroups.emit(LEGACY_ROWS);
            await flush();

            expect(element.shadowRoot.querySelector('.tg-error')).not.toBeNull();
            expect(element.shadowRoot.querySelectorAll('.tg-task')).toHaveLength(0);
            expect(element.shadowRoot.querySelector('.tg-empty')).toBeNull();
        });

        it('renders neither an error nor an empty state before the discriminator resolves', async () => {
            // The loading state must not look like "this deal has no checklist".
            const element = createComponent();
            await flush();
            expect(element.shadowRoot.querySelector('.tg-error')).toBeNull();
            expect(element.shadowRoot.querySelector('.tg-empty')).toBeNull();
        });
    });

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // RISK 1 — criticality and wire status come from BOOLEAN FIELDS on the new model.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    describe('RISK 1 — the subject-text coupling is gone from the new model', () => {
        it('renders the Critical pill for a MARKERLESS item whose isCritical is true', async () => {
            const element = await renderChecklist();
            const rows = [...element.shadowRoot.querySelectorAll('.tg-task')];
            const canary = rows.find((r) =>
                r.querySelector('.tg-subject').textContent.includes('escrow officer')
            );
            expect(canary).toBeDefined();
            expect(canary.querySelector('.tg-flag')).not.toBeNull();
            expect(canary.classList.contains('tg-task--critical')).toBe(true);
        });

        it('routes a MARKERLESS wire item to the verification dialog, not the confirm dialog', async () => {
            // The wire routing must follow isWireVerification too — otherwise an item could be
            // ticked off with no anti-fraud evidence captured.
            const element = await renderChecklist();
            const checkbox = element.shadowRoot.querySelector('input[data-id="i-wire"]');
            expect(checkbox.dataset.wire).toBe('true');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();
            expect(element.shadowRoot.querySelector('.tg-modal--wire')).not.toBeNull();
            expect(element.shadowRoot.querySelector('.tg-modal--confirm')).toBeNull();
        });

        it('does NOT render the Critical pill for a MARKED item whose booleans are false', async () => {
            const element = await renderChecklist();
            const rows = [...element.shadowRoot.querySelectorAll('.tg-task')];
            const marked = rows.find((r) =>
                r.querySelector('.tg-subject').textContent.includes('ALTA survey')
            );
            expect(marked).toBeDefined();
            expect(marked.querySelector('.tg-flag')).toBeNull();
            expect(marked.classList.contains('tg-task--critical')).toBe(false);
            // ...and it routes to the plain confirm dialog, not the wire dialog.
            expect(marked.querySelector('input').dataset.wire).toBe('false');
        });

        it('still strips the marker for DISPLAY — cosmetic, and independent of meaning', async () => {
            const element = await renderChecklist();
            expect(textOf(element, '.tg-subject')).toContain('Order the ALTA survey');
        });

        it('still derives critical/wire from the subject on the LEGACY model', async () => {
            // Task carries no boolean fields, so the parse is correct there and must survive.
            const element = await renderLegacy();
            const rows = [...element.shadowRoot.querySelectorAll('.tg-task')];
            const wireRow = rows.find((r) =>
                r.querySelector('.tg-subject').textContent.includes('verbally verify')
            );
            expect(wireRow.querySelector('.tg-flag')).not.toBeNull();
            expect(wireRow.querySelector('input').dataset.wire).toBe('true');
        });
    });

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Labels (design §2.12)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    describe('phase labels', () => {
        it('renders the four phase names as the data spells them', async () => {
            const element = await renderChecklist();
            expect(textOf(element, '.tg-phase-name')).toEqual([
                'Open Contract',
                'Due Diligence',
                'Closing Prep',
                'Post-Closing'
            ]);
        });

        it('never renders the pre-Phase-3 spellings', async () => {
            // Absence pin with a presence control: the two names above prove the list rendered at
            // all, so this cannot pass vacuously against an empty phase row.
            const element = await renderChecklist();
            const names = textOf(element, '.tg-phase-name');
            expect(names).not.toContain('Closing');
            expect(names).not.toContain('Post Closing');
            expect(names).toContain('Closing Prep');
        });

        it('places a Closing Prep group under the "close" phase by its STAGE', async () => {
            const element = await renderChecklist(CHECKLIST_ROWS, 'close');
            // Pinned to the close tab: only group I is on the rail.
            expect(textOf(element, '.tg-ring-inner')).toEqual(['I']);
            expect(element.shadowRoot.querySelector('.tg-phases')).toBeNull();
        });
    });

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Empty states
    // ═══════════════════════════════════════════════════════════════════════════════════════

    describe('empty states', () => {
        it('shows NEITHER the empty message NOR content BETWEEN the discriminator and the data', async () => {
            // 🔴 THE REGRESSION THIS FILE MISSED THE FIRST TIME, AND THE REASON IT MISSED IT.
            // `renderChecklist()` emits getRecord AND the Apex wire before asserting, so this
            // intermediate state was never observed. In it — with the empty state gated on the
            // DISCRIMINATOR alone rather than on the data — the component rendered "no checklist
            // items have been generated… the fan-out may not have completed" on EVERY page load of
            // a perfectly healthy deal. An alarming, false diagnosis shown to everyone, every time.
            //
            // ⚠ THE ASSERTION MUST BE TAKEN BETWEEN THE TWO EMITS. Any helper that settles both
            // wires before asserting is structurally blind to it.
            const element = createComponent();
            getRecord.emit(transactionRecord(true));
            await flush();

            // Discriminator resolved (the Apex adapter is provisioned), round trip still in flight.
            expect(getChecklist.getLastConfig()).toEqual({ transactionId: RECORD_ID });
            expect(element.shadowRoot.querySelector('.tg-empty')).toBeNull();
            expect(element.shadowRoot.querySelector('.tg-error')).toBeNull();
            expect(element.shadowRoot.querySelectorAll('.tg-task')).toHaveLength(0);

            // Presence control: the component is WAITING, not wedged. Without this the assertions
            // above would also pass against a component that never renders anything at all.
            getChecklist.emit(CHECKLIST_ROWS);
            await flush();
            expect(element.shadowRoot.querySelectorAll('.tg-task').length).toBeGreaterThan(0);
        });

        it('does the same on the LEGACY model', async () => {
            const element = createComponent();
            getRecord.emit(transactionRecord(false));
            await flush();
            expect(element.shadowRoot.querySelector('.tg-empty')).toBeNull();
            getTaskGroups.emit(LEGACY_ROWS);
            await flush();
            expect(element.shadowRoot.querySelectorAll('.tg-task').length).toBeGreaterThan(0);
        });

        it('shows a NEW-MODEL empty message that names the fan-out, not a blank panel', async () => {
            const element = await renderChecklist([]);
            const empty = element.shadowRoot.querySelector('.tg-empty');
            expect(empty).not.toBeNull();
            expect(empty.textContent).toContain('fan-out');
            expect(element.shadowRoot.querySelector('.tg-error')).toBeNull();
        });

        it('shows the LEGACY empty message, which is different text', async () => {
            const element = await renderLegacy([]);
            const empty = element.shadowRoot.querySelector('.tg-empty');
            expect(empty.textContent).toContain('Contract Executed Date');
        });

        it('shows an error, not an empty state, when the checklist read fails', async () => {
            const element = createComponent();
            getRecord.emit(transactionRecord(true));
            await flush();
            getChecklist.error();
            await flush();
            expect(element.shadowRoot.querySelector('.tg-error')).not.toBeNull();
            expect(element.shadowRoot.querySelector('.tg-empty')).toBeNull();
        });
    });

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Writes
    // ═══════════════════════════════════════════════════════════════════════════════════════

    describe('completion', () => {
        it('calls the CHECKLIST controller with the checklist parameter names', async () => {
            // ⚠ Parameter names are the wire contract. `completeItem({itemId, comment})` and
            // `completeTask({taskId, notes})` are NOT interchangeable; passing the wrong shape
            // reaches Apex as nulls and completes nothing.
            completeItem.mockResolvedValue();
            const element = await renderChecklist();
            const checkbox = element.shadowRoot.querySelector('input[data-id="i-plain"]');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();

            element.shadowRoot
                .querySelector('lightning-textarea')
                .dispatchEvent(new CustomEvent('change', { detail: { value: 'ordered' } }));
            // lightning-textarea's stub carries `value`, so set it directly for the handler.
            const textarea = element.shadowRoot.querySelector('lightning-textarea');
            textarea.value = 'ordered';
            textarea.dispatchEvent(new CustomEvent('change'));
            await flush();

            element.shadowRoot.querySelector('.slds-button_brand').click();
            await flush();

            expect(completeItem).toHaveBeenCalledWith({ itemId: 'i-plain', comment: 'ordered' });
            expect(completeTask).not.toHaveBeenCalled();
        });

        it('calls the LEGACY controller with the legacy parameter names', async () => {
            completeTask.mockResolvedValue();
            const element = await renderLegacy();
            const checkbox = element.shadowRoot.querySelector('input[data-id="t-plain"]');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();
            element.shadowRoot.querySelector('.slds-button_brand').click();
            await flush();

            expect(completeTask).toHaveBeenCalledWith({ taskId: 't-plain', notes: '' });
            expect(completeItem).not.toHaveBeenCalled();
        });

        it('notifies LDS after a successful write so the highlights panel is not stale', async () => {
            // ⚠ The DML was imperative Apex and the rollup then wrote Transaction__c counters —
            // all behind LDS's back. Without this the Path and highlights panel keep showing
            // pre-click numbers until a full page reload.
            completeItem.mockResolvedValue();
            const element = await renderChecklist();
            const checkbox = element.shadowRoot.querySelector('input[data-id="i-plain"]');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();
            element.shadowRoot.querySelector('.slds-button_brand').click();
            await flush();

            expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([{ recordId: RECORD_ID }]);
        });

        it('surfaces a refusal message verbatim and keeps the dialog open', async () => {
            // The wire-fraud prerequisite gate's message NAMES the blocking step. A generic
            // "refresh and try again" would be advice that can never work.
            const refusal =
                'Complete "Call title company to verbally verify wiring instructions" first.';
            completeItem.mockRejectedValue({ body: { message: refusal } });
            const element = await renderChecklist();
            const toasts = [];
            element.addEventListener('lightning__showtoast', (e) => toasts.push(e.detail));

            const checkbox = element.shadowRoot.querySelector('input[data-id="i-plain"]');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();
            element.shadowRoot.querySelector('.slds-button_brand').click();
            await flush();

            expect(toasts).toHaveLength(1);
            expect(toasts[0].message).toBe(refusal);
            expect(toasts[0].variant).toBe('error');
            // The dialog stays open so the user does not lose the comment they typed.
            expect(element.shadowRoot.querySelector('.tg-modal--confirm')).not.toBeNull();
            expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();
        });

        it('strips the raw subject marker out of the refusal toast', async () => {
            // The server interpolates the blocking item's RAW Subject__c into the refusal text.
            // Shown unstripped, the toast reads … (anti-fraud) while the row directly above it
            // reads the same subject WITHOUT the marker — the same step spelled two ways, in one
            // viewport, at the exact moment the user is confused about why their click failed.
            // Only the DECORATION is removed; the server still owns the wording.
            completeItem.mockRejectedValue({
                body: {
                    message:
                        'Complete "Call title company to verbally verify wiring instructions (anti-fraud)" first.'
                }
            });
            const element = await renderChecklist();
            const toasts = [];
            element.addEventListener('lightning__showtoast', (e) => toasts.push(e.detail));

            const checkbox = element.shadowRoot.querySelector('input[data-id="i-plain"]');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();
            element.shadowRoot.querySelector('.slds-button_brand').click();
            await flush();

            expect(toasts).toHaveLength(1);
            expect(toasts[0].message).not.toContain('anti-fraud');
            // Presence control: the SENTENCE survives — only the parenthetical is gone. Without
            // this, an implementation that blanked the message entirely would also pass.
            expect(toasts[0].message).toContain('Complete');
            expect(toasts[0].message).toContain('verify wiring instructions');
        });

        it('disables a BLOCKED row rather than letting the user type a comment and be refused', async () => {
            const element = await renderChecklist();
            const blocked = element.shadowRoot.querySelector('input[data-id="i-blocked"]');
            expect(blocked.disabled).toBe(true);
            const row = blocked.closest('.tg-task');
            expect(row.querySelector('.tg-blocked')).not.toBeNull();
            // ⚠ It is NOT styled as critical — "cannot start yet" and "deal-sinking" are
            // different statements and must not look alike.
            expect(row.classList.contains('tg-task--critical')).toBe(false);
        });

        it('disables a completed row', async () => {
            const element = await renderChecklist();
            expect(element.shadowRoot.querySelector('input[data-id="i-done"]').disabled).toBe(true);
        });
    });

    describe('wire verification', () => {
        it('refuses to submit without a name and phone, and never calls Apex', async () => {
            const element = await renderChecklist();
            const checkbox = element.shadowRoot.querySelector('input[data-id="i-wire"]');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();
            element.shadowRoot.querySelector('.slds-button_brand').click();
            await flush();

            expect(recordWireVerification).not.toHaveBeenCalled();
            expect(element.shadowRoot.querySelector('.tg-modal-error')).not.toBeNull();
        });

        it('calls the CHECKLIST controller with its parameter names', async () => {
            recordWireVerification.mockResolvedValue();
            const element = await renderChecklist();
            const checkbox = element.shadowRoot.querySelector('input[data-id="i-wire"]');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();

            const inputs = element.shadowRoot.querySelectorAll('lightning-input');
            inputs[0].value = ' Jane Doe ';
            inputs[0].dispatchEvent(new CustomEvent('change'));
            inputs[1].value = ' 713-555-0142 ';
            inputs[1].dispatchEvent(new CustomEvent('change'));
            await flush();

            element.shadowRoot.querySelector('.slds-button_brand').click();
            await flush();

            expect(recordWireVerification).toHaveBeenCalledWith({
                itemId: 'i-wire',
                verifiedByName: 'Jane Doe',
                phone: '713-555-0142',
                comment: ''
            });
            expect(completeWireVerification).not.toHaveBeenCalled();
        });

        it('calls the LEGACY controller with its parameter names', async () => {
            completeWireVerification.mockResolvedValue();
            const element = await renderLegacy();
            const checkbox = element.shadowRoot.querySelector('input[data-id="t-wire"]');
            checkbox.checked = true;
            checkbox.dispatchEvent(new CustomEvent('change'));
            await flush();

            const inputs = element.shadowRoot.querySelectorAll('lightning-input');
            inputs[0].value = 'Jane Doe';
            inputs[0].dispatchEvent(new CustomEvent('change'));
            inputs[1].value = '713-555-0142';
            inputs[1].dispatchEvent(new CustomEvent('change'));
            await flush();

            element.shadowRoot.querySelector('.slds-button_brand').click();
            await flush();

            expect(completeWireVerification).toHaveBeenCalledWith({
                taskId: 't-wire',
                verifiedBy: 'Jane Doe',
                phone: '713-555-0142',
                comments: ''
            });
            expect(recordWireVerification).not.toHaveBeenCalled();
        });
    });

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Attribute hygiene + accessibility
    // ═══════════════════════════════════════════════════════════════════════════════════════

    describe('rendered attributes', () => {
        it('never writes the literal string "undefined" into the NATIVE markup', async () => {
            // ⚠ A getter bound to an element ATTRIBUTE is written UNCONDITIONALLY, so a getter
            // that returns undefined renders title="undefined". Asserted on the RENDERED markup,
            // not on the getters — the getters are exactly what this is checking.
            //
            // 🔴 THIS SWEEP COVERS NATIVE ELEMENTS ONLY, AND THAT LIMIT WAS MEASURED, NOT ASSUMED.
            // Mutating `icon: p.icon` to an undefined property left this assertion GREEN: the
            // `lightning-icon` Jest stub holds `icon-name` as a public PROPERTY and never reflects
            // it into markup, so jsdom's innerHTML cannot see it. Do not read a pass here as
            // proof that every attribute in the template is safe — the two assertions below are
            // the ones with real falsifying power, and they were both verified to go red.
            const element = await renderChecklist();
            expect(element.shadowRoot.innerHTML).not.toContain('undefined');
        });

        it('writes a well-formed width-only style on every progress bar', async () => {
            // Two facts in one assertion, both load-bearing:
            //   1. The attribute EXISTS — an undefined getter makes LWC omit it entirely, which is
            //      the silent form of the same bug and is invisible to an innerHTML sweep.
            //   2. It carries WIDTH ONLY. Phase 3 moved every colour out of these JS-built style
            //      strings and into token-backed CSS classes; a hex creeping back in here would be
            //      invisible to the SLDS linter, which only reads .css files.
            const element = await renderChecklist();
            const bars = [
                ...element.shadowRoot.querySelectorAll('.tg-phase-fill, .tg-bar')
            ];
            expect(bars.length).toBeGreaterThan(0);
            bars.forEach((bar) => {
                expect(bar.getAttribute('style')).toMatch(/^width:\s*\d+%;?$/);
            });
        });

        it('gives every checkbox an accessible name', async () => {
            const element = await renderChecklist();
            const boxes = [...element.shadowRoot.querySelectorAll('input.tg-check')];
            expect(boxes.length).toBeGreaterThan(0);
            boxes.forEach((box) => {
                expect(box.getAttribute('aria-label')).toBeTruthy();
            });
        });

        it('is accessible with data rendered', async () => {
            const element = await renderChecklist();
            await expect(element).toBeAccessible();
        });

        it('is accessible in the empty state', async () => {
            const element = await renderChecklist([]);
            await expect(element).toBeAccessible();
        });

        it('is accessible in the error state', async () => {
            const element = createComponent();
            getRecord.error();
            await flush();
            await expect(element).toBeAccessible();
        });
    });

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Phase 5 — the capture dialog.
    //
    // 🔴 WHAT THIS BLOCK CAN AND CANNOT PROVE, STATED UP FRONT SO A GREEN RUN IS NOT READ AS
    //    MORE THAN IT IS.
    //   ✅ Can prove: which dialog a click opens; that `getCaptureContext` is called with the
    //      item id; that the form is bound to the SERVER-SUPPLIED object and record id; that the
    //      upload targets the DEAL; that `linkCaptureDocuments` receives the uploaded ids; that
    //      Confirm does NOT complete the item directly on a field capture; that `onsuccess` DOES.
    //   ❌ Cannot prove: that `lightning-record-edit-form.submit()` was called. The sfdx-lwc-jest
    //      stub is a bare custom element with no `submit()` method, so the component guards the
    //      call with a `typeof` check and Jest exercises the guarded branch, not the real one.
    //      Nor can it prove anything about `lightning-file-upload`'s own behaviour — the stub
    //      never uploads and never emits `uploadfinished` on its own, so that event is dispatched
    //      by hand below. Both gaps are BROWSER checks, not test gaps that more mocking closes.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    describe('Phase 5 capture dialog', () => {
        /**
         * A group whose items RECORD SOMETHING. `hasCapture` is server-derived from the item
         * coordinate, so the fixture sets it as data rather than implying it from the subject —
         * the same discipline as `isCritical` / `isWireVerification` above.
         */
        const CAPTURE_ROWS = [
            {
                id: 'a1Y000000000FFF',
                letter: 'F',
                name: 'Financing',
                ownerLabel: 'Danish',
                conditional: true,
                stage: 'Due Diligence',
                total: 3,
                complete: 0,
                pct: 0,
                items: [
                    {
                        id: 'i-f9',
                        subject: 'Select bank account type',
                        ownerLabel: 'Accounting',
                        sequence: 9,
                        flag: 'None',
                        done: false,
                        isCritical: false,
                        isWireVerification: false,
                        verifyComplete: false,
                        blocked: false,
                        hasCapture: true
                    },
                    {
                        id: 'i-c7',
                        subject: 'Upload PCR to deal document folder',
                        ownerLabel: 'Danish',
                        sequence: 7,
                        flag: 'None',
                        done: false,
                        isCritical: false,
                        isWireVerification: false,
                        verifyComplete: false,
                        blocked: false,
                        hasCapture: true
                    },
                    {
                        // 🔴 THE NEGATIVE CONTROL. Same group, same shape, `hasCapture` false —
                        // so a component that opened the capture dialog for EVERY row would fail
                        // here rather than passing every positive assertion above it.
                        id: 'i-plainf',
                        subject: 'Follow up with bankers - confirm receipt of package',
                        ownerLabel: 'Danish',
                        sequence: 3,
                        flag: 'None',
                        done: false,
                        isCritical: false,
                        isWireVerification: false,
                        verifyComplete: false,
                        blocked: false,
                        hasCapture: false
                    }
                ]
            }
        ];

        const FIELD_CONTEXT = {
            itemId: 'i-f9',
            captureMode: 'TARGET_FIELDS',
            objectApiName: 'Loan__c',
            targetRecordId: 'a2L000000000LOAN',
            captureFields: ['Bank_Account_Type__c'],
            requiredField: 'Bank_Account_Type__c',
            requirementMessage: 'Select the bank account type before completing this item.',
            satisfied: false
        };

        const DOCUMENT_CONTEXT = {
            itemId: 'i-c7',
            captureMode: 'DOCUMENT',
            objectApiName: null,
            targetRecordId: RECORD_ID,
            captureFields: [],
            requiredField: null,
            requirementMessage: 'Attach the Property Condition Report before completing this item.',
            satisfied: false
        };

        function checkboxFor(element, itemId) {
            return [...element.shadowRoot.querySelectorAll('input.tg-check')].find(
                (box) => box.dataset.id === itemId
            );
        }

        async function tick(element, itemId) {
            const box = checkboxFor(element, itemId);
            box.checked = true;
            box.dispatchEvent(new CustomEvent('change'));
            await flush();
            return box;
        }

        it('opens the CAPTURE dialog for a capture item, not the confirm dialog', async () => {
            getCaptureContext.mockResolvedValue(FIELD_CONTEXT);
            const element = await renderChecklist(CAPTURE_ROWS);

            await tick(element, 'i-f9');

            expect(getCaptureContext).toHaveBeenCalledWith({ itemId: 'i-f9' });
            expect(element.shadowRoot.querySelector('.tg-modal--capture')).not.toBeNull();
            expect(element.shadowRoot.querySelector('.tg-modal--confirm')).toBeNull();
        });

        it('leaves an ordinary item on the confirm dialog and never asks for a context', async () => {
            // The negative control for the test above. Without it, a component that opened the
            // capture dialog unconditionally would pass every positive assertion in this block.
            const element = await renderChecklist(CAPTURE_ROWS);

            await tick(element, 'i-plainf');

            expect(getCaptureContext).not.toHaveBeenCalled();
            expect(element.shadowRoot.querySelector('.tg-modal--confirm')).not.toBeNull();
            expect(element.shadowRoot.querySelector('.tg-modal--capture')).toBeNull();
        });

        it('holds the checkbox unticked until the capture is saved', async () => {
            getCaptureContext.mockResolvedValue(FIELD_CONTEXT);
            const element = await renderChecklist(CAPTURE_ROWS);

            const box = await tick(element, 'i-f9');

            expect(box.checked).toBe(false);
            expect(completeItem).not.toHaveBeenCalled();
        });

        it('binds the form to the SERVER-SUPPLIED object and record, and its named fields', async () => {
            // 🔴 THE RECORD ID IS THE POINT. A `lightning-record-edit-form` rendered with an
            // undefined `record-id` silently becomes a CREATE form, which would make a second
            // Loan__c every time the dialog opened.
            getCaptureContext.mockResolvedValue(FIELD_CONTEXT);
            const element = await renderChecklist(CAPTURE_ROWS);

            await tick(element, 'i-f9');

            const form = element.shadowRoot.querySelector('lightning-record-edit-form');
            expect(form).not.toBeNull();
            expect(form.objectApiName).toBe('Loan__c');
            expect(form.recordId).toBe('a2L000000000LOAN');
            const fields = [...element.shadowRoot.querySelectorAll('lightning-input-field')];
            expect(fields.map((f) => f.fieldName)).toEqual(['Bank_Account_Type__c']);
            // No file upload on a field capture, and no form on a document capture — the two modes
            // are mutually exclusive, not both rendered and one hidden.
            expect(element.shadowRoot.querySelector('lightning-file-upload')).toBeNull();
        });

        it('shows the server requirement text up front rather than only on refusal', async () => {
            getCaptureContext.mockResolvedValue(FIELD_CONTEXT);
            const element = await renderChecklist(CAPTURE_ROWS);

            await tick(element, 'i-f9');

            const note = element.shadowRoot.querySelector('.tg-modal--capture .tg-modal-note');
            expect(note.textContent).toContain('Select the bank account type');
        });

        it('does not complete the item directly from Confirm on a field capture', async () => {
            // The completion must wait for LDS to confirm the write. Completing first would tick an
            // item whose output then failed to save.
            getCaptureContext.mockResolvedValue(FIELD_CONTEXT);
            const element = await renderChecklist(CAPTURE_ROWS);
            await tick(element, 'i-f9');

            element.shadowRoot
                .querySelector('.tg-modal--capture .slds-button_brand')
                .click();
            await flush();

            expect(completeItem).not.toHaveBeenCalled();
        });

        it('completes the item once the record-edit-form reports success', async () => {
            getCaptureContext.mockResolvedValue(FIELD_CONTEXT);
            completeItem.mockResolvedValue(undefined);
            const element = await renderChecklist(CAPTURE_ROWS);
            await tick(element, 'i-f9');

            element.shadowRoot
                .querySelector('lightning-record-edit-form')
                .dispatchEvent(new CustomEvent('success'));
            await flush();

            expect(completeItem).toHaveBeenCalledWith({ itemId: 'i-f9', comment: null });
            // The parent Transaction's counters and Is_Earnest_At_Risk__c were written by Apex
            // behind LDS's back, so the Path and highlights panel need telling.
            expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([{ recordId: RECORD_ID }]);
        });

        it('points the file upload at the DEAL, not at the checklist item', async () => {
            // "Upload PCR to deal document folder" — the file belongs to the deal. The per-item
            // link is added afterwards by `linkCaptureDocuments`.
            getCaptureContext.mockResolvedValue(DOCUMENT_CONTEXT);
            const element = await renderChecklist(CAPTURE_ROWS);

            await tick(element, 'i-c7');

            const upload = element.shadowRoot.querySelector('lightning-file-upload');
            expect(upload).not.toBeNull();
            expect(upload.recordId).toBe(RECORD_ID);
            expect(element.shadowRoot.querySelector('lightning-record-edit-form')).toBeNull();
        });

        it('disables Confirm on a document capture until a file is on file', async () => {
            getCaptureContext.mockResolvedValue(DOCUMENT_CONTEXT);
            const element = await renderChecklist(CAPTURE_ROWS);

            await tick(element, 'i-c7');

            const confirm = element.shadowRoot.querySelector(
                '.tg-modal--capture .slds-button_brand'
            );
            expect(confirm.disabled).toBe(true);
        });

        it('files uploaded documents against the item and then enables Confirm', async () => {
            getCaptureContext.mockResolvedValue(DOCUMENT_CONTEXT);
            linkCaptureDocuments.mockResolvedValue(1);
            const element = await renderChecklist(CAPTURE_ROWS);
            await tick(element, 'i-c7');

            element.shadowRoot.querySelector('lightning-file-upload').dispatchEvent(
                new CustomEvent('uploadfinished', {
                    detail: { files: [{ documentId: '069000000000001' }] }
                })
            );
            await flush();

            expect(linkCaptureDocuments).toHaveBeenCalledWith({
                itemId: 'i-c7',
                contentDocumentIds: ['069000000000001']
            });
            const confirm = element.shadowRoot.querySelector(
                '.tg-modal--capture .slds-button_brand'
            );
            expect(confirm.disabled).toBe(false);
        });

        it('explains a failed filing in the dialog and keeps Confirm disabled', async () => {
            // The file IS uploaded — the platform published it against the deal before any Apex ran
            // — but it is NOT filed against this item, so the server guard will keep refusing. An
            // earlier version CLEARED the dialog message here, removing the only explanation at the
            // exact moment one was needed.
            getCaptureContext.mockResolvedValue(DOCUMENT_CONTEXT);
            linkCaptureDocuments.mockRejectedValue({
                body: { message: 'This checklist item is no longer available to you.' }
            });
            const element = await renderChecklist(CAPTURE_ROWS);
            await tick(element, 'i-c7');

            element.shadowRoot.querySelector('lightning-file-upload').dispatchEvent(
                new CustomEvent('uploadfinished', {
                    detail: { files: [{ documentId: '069000000000001' }] }
                })
            );
            await flush();

            const dialog = element.shadowRoot.querySelector('.tg-modal--capture');
            expect(dialog.textContent).toContain('no longer available');
            expect(
                dialog.querySelector('.slds-button_brand').disabled
            ).toBe(true);
        });

        it('completes a document capture directly from Confirm', async () => {
            // No LDS write to wait for here — the file already exists.
            getCaptureContext.mockResolvedValue({ ...DOCUMENT_CONTEXT, satisfied: true });
            completeItem.mockResolvedValue(undefined);
            const element = await renderChecklist(CAPTURE_ROWS);
            await tick(element, 'i-c7');

            element.shadowRoot
                .querySelector('.tg-modal--capture .slds-button_brand')
                .click();
            await flush();

            expect(completeItem).toHaveBeenCalledWith({ itemId: 'i-c7', comment: null });
        });

        it('falls back to the confirm dialog when the server says the item captures nothing', async () => {
            // A definition changed under a page that was already open. An empty capture form would
            // be a dead end with no fields and no upload.
            getCaptureContext.mockResolvedValue(null);
            const element = await renderChecklist(CAPTURE_ROWS);

            await tick(element, 'i-f9');

            expect(element.shadowRoot.querySelector('.tg-modal--capture')).toBeNull();
            expect(element.shadowRoot.querySelector('.tg-modal--confirm')).not.toBeNull();
        });

        it('closes the dialog and surfaces the reason when the context cannot be built', async () => {
            getCaptureContext.mockRejectedValue({
                body: { message: 'This checklist item is no longer available to you.' }
            });
            const element = await renderChecklist(CAPTURE_ROWS);
            const toast = jest.fn();
            element.addEventListener('lightning__showtoast', toast);

            await tick(element, 'i-f9');

            expect(element.shadowRoot.querySelector('.tg-modal--capture')).toBeNull();
            expect(toast).toHaveBeenCalled();
            expect(toast.mock.calls[0][0].detail.message).toContain('no longer available');
        });

        it('keeps a server refusal in the dialog, where the fix is', async () => {
            // A `CaptureRequiredException` can still arrive after the form saved — the user could
            // have cleared the required field. The refusal text belongs beside the field, not only
            // in a toast that disappears.
            getCaptureContext.mockResolvedValue({ ...DOCUMENT_CONTEXT, satisfied: true });
            completeItem.mockRejectedValue({
                body: { message: 'Attach the Property Condition Report before completing this item.' }
            });
            const element = await renderChecklist(CAPTURE_ROWS);
            await tick(element, 'i-c7');

            element.shadowRoot
                .querySelector('.tg-modal--capture .slds-button_brand')
                .click();
            await flush();

            const dialog = element.shadowRoot.querySelector('.tg-modal--capture');
            expect(dialog).not.toBeNull();
            expect(dialog.textContent).toContain('Attach the Property Condition Report');
        });

        it('never offers a capture dialog on the LEGACY model', async () => {
            // 🔴 `Loan__c` and `Insurance_Binder__c` hang off the CHECKLIST model. An un-migrated
            // deal must behave exactly as it did before Phase 5 — that is the point of the
            // dual-model window. `normalizeLegacyGroups` hard-codes `hasCapture` false, and this
            // asserts the component does not reintroduce it from anywhere else.
            const element = await renderLegacy();

            const box = [...element.shadowRoot.querySelectorAll('input.tg-check')].find(
                (b) => b.dataset.id === 't-plain'
            );
            box.checked = true;
            box.dispatchEvent(new CustomEvent('change'));
            await flush();

            expect(getCaptureContext).not.toHaveBeenCalled();
            expect(element.shadowRoot.querySelector('.tg-modal--capture')).toBeNull();
        });

        it('is accessible with the capture dialog open', async () => {
            getCaptureContext.mockResolvedValue(FIELD_CONTEXT);
            const element = await renderChecklist(CAPTURE_ROWS);
            await tick(element, 'i-f9');
            await expect(element).toBeAccessible();
        });
    });
});
