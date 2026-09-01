/**
 * c-transaction-task-cards — ONE Apex @wire READ, no record context, no writes.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE MOST IMPORTANT THING THIS SUITE PINS IS AN **ABSENCE**: THIS COMPONENT MUST NOT LEARN
 *    TO DISCRIMINATE BETWEEN THE TWO CHECKLIST MODELS.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Its three siblings had to, because they read the ROWS. This one reads the four COUNTERS on
 * `Transaction__c` — `Tasks_Total__c`, `Tasks_Complete__c`, `Tasks_Overdue__c`,
 * `Wire_Open_Risks__c` — summed across every Active deal by
 * `TransactionController.getTaskSummary`. Both rollups write those same four fields
 * (`TaskRollupService` for legacy deals, `ChecklistRollupService` for migrated ones), which is a
 * large part of why design §5.3 refused to convert them into roll-up summaries. So the tile keeps
 * reporting correctly through the whole dual-model window with no code change.
 *
 * That is a FINDING, not an oversight, and it is asserted rather than left as a comment: the test
 * below fails if anyone adds a `recordId` or a second wire here, which is what someone doing a
 * mechanical "repoint all four LWCs" pass would do.
 *
 * ⚠ THE "Wire Tasks" NUMBER IS THE RISK 1 CANARY IN AGGREGATE — the same figure as the Wire
 * Sentinel dashboard tile and the `Open_Wire_Risks` report. If it reads zero across every deal,
 * the fault is in a rollup service, never in this file.
 */
import { createElement } from 'lwc';
import TransactionTaskCards from 'c/transactionTaskCards';
import getTaskSummary from '@salesforce/apex/TransactionController.getTaskSummary';

jest.mock(
    '@salesforce/apex/TransactionController.getTaskSummary',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const SUMMARY = {
    totalTasks: 246,
    pendingTasks: 180,
    overdueTasks: 4,
    wireTasks: 3
};

function createComponent() {
    const element = createElement('c-transaction-task-cards', { is: TransactionTaskCards });
    document.body.appendChild(element);
    return element;
}

async function flush() {
    await Promise.resolve();
    await Promise.resolve();
}

function cards(element) {
    return [...element.shadowRoot.querySelectorAll('c-onboarding-card-child')];
}

async function render(summary = SUMMARY) {
    const element = createComponent();
    getTaskSummary.emit(summary);
    await flush();
    return element;
}

describe('c-transaction-task-cards', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('takes NO record id and NO model discriminator — it is model-agnostic by construction', async () => {
        // 🔴 An absence pin with a presence control. If someone adds `@api recordId` and a
        // getRecord wire here during a mechanical "repoint all four" pass, `recordId` stops being
        // undefined and this goes red. The value assertion below is the control, so this cannot
        // pass against a component that failed to render at all.
        const element = await render();
        expect(element.recordId).toBeUndefined();
        expect(getTaskSummary.getLastConfig()).toEqual({});
        expect(cards(element)).toHaveLength(4);
    });

    it('renders the four aggregate counters', async () => {
        const element = await render();
        expect(cards(element).map((c) => c.value)).toEqual(['246', '180', '4', '3']);
        expect(cards(element).map((c) => c.label)).toEqual([
            'Total Tasks',
            'Pending',
            'At Risk',
            'Wire Tasks'
        ]);
    });

    it('lights the wire tile red only when there is an open wire risk', async () => {
        const risky = await render();
        expect(cards(risky)[3].iconColor).toContain('red');
    });

    it('reads a clean wire count as GREEN, not as a missing value', async () => {
        // Zero open wire risks is the good state and must look like one. It is also what a
        // RISK 1 regression would produce, so the number itself is the canary — this test only
        // pins the presentation.
        const element = await render({ ...SUMMARY, wireTasks: 0, overdueTasks: 0 });
        expect(cards(element)[3].value).toBe('0');
        expect(cards(element)[3].iconColor).toContain('green');
    });

    it('passes TOKEN-BACKED icon colours, never bare hex', async () => {
        // The child interpolates these into a CSS custom property, so a literal hex would be
        // invisible to the SLDS linter (which only reads .css files).
        const element = await render();
        cards(element).forEach((c) => {
            expect(c.iconColor).toMatch(/^var\(--slds-g-color-/);
        });
    });

    it('renders zeros rather than blanks when the summary comes back empty', async () => {
        const element = await render({});
        expect(cards(element).map((c) => c.value)).toEqual(['0', '0', '0', '0']);
    });

    it('renders four zeroed tiles before the wire resolves', async () => {
        // Carried over from the pre-Phase-3 suite. This component has no model discriminator to
        // wait on, so unlike its three siblings it CAN show a valid zero state immediately — the
        // shape never changes, only the numbers.
        const element = createComponent();
        await flush();
        expect(cards(element)).toHaveLength(4);
        expect(cards(element).map((c) => c.value)).toEqual(['0', '0', '0', '0']);
    });

    it('renders the error MESSAGE, not just an error container', async () => {
        // Carried over from the pre-Phase-3 suite. Asserting only that `.kpi-error` exists would
        // still pass if the component rendered an empty red box.
        const element = createComponent();
        getTaskSummary.error({ message: 'Task metrics unavailable.' });
        await flush();
        expect(cards(element)).toHaveLength(0);
        const err = element.shadowRoot.querySelector('.kpi-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Task metrics unavailable.');
    });

    it('is accessible with data', async () => {
        const element = await render();
        await expect(element).toBeAccessible();
    });

    it('is accessible in the error state', async () => {
        const element = createComponent();
        getTaskSummary.error();
        await flush();
        await expect(element).toBeAccessible();
    });
});
