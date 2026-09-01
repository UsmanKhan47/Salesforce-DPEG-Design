import { LightningElement, wire } from 'lwc';
import getTaskSummary from '@salesforce/apex/TransactionController.getTaskSummary';

/**
 * Overall checklist posture across ALL Active transactions (Total / Pending / At Risk / Wire).
 * App/Home-page component — it has no `recordId` and is not per-deal.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ✅ THIS COMPONENT IS MODEL-AGNOSTIC BY CONSTRUCTION AND NEEDED **NO** PHASE 3 REPOINT.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Its three siblings (`transactionTaskGroups`, `transactionPhaseCards`,
 * `transactionChecklistSummary`) had to learn to discriminate between the legacy `Task` model and
 * the new `Checklist__c` model, because they read the ROWS. This one does not: it sums the four
 * counters that live on `Transaction__c` itself — `Tasks_Total__c`, `Tasks_Complete__c`,
 * `Tasks_Overdue__c`, `Wire_Open_Risks__c` — via `TransactionController.getTaskSummary`.
 *
 * Both rollups write those SAME four fields:
 *   • legacy deals -> `TaskRollupService.recalc`      (fired from `TaskRollupTrigger`)
 *   • new deals    -> `ChecklistRollupService.recalc` (fired from `ChecklistItemTrigger`)
 * That is deliberate and is a large part of why design §5.3 refused to convert those counters into
 * roll-up summaries. The consequence here is that this tile keeps reporting correctly through the
 * entire dual-model migration window with no code change at all — including "Wire Tasks", which
 * `ChecklistRollupService` derives from `Is_Wire_Verification__c` (a real boolean field) rather
 * than from the subject-text parse the legacy service still uses on frozen `Task` subjects.
 *
 * ⚠ SO "IT WAS NOT CHANGED" IS A FINDING, NOT AN OVERSIGHT. The `Wire Tasks` number here is the
 * same figure as the Wire Sentinel dashboard metric and the `Open_Wire_Risks` report; if it ever
 * reads zero across every deal, the fault is in a rollup service, never in this file.
 */
const META = [
    { key: 'totalTasks',   label: 'Total Tasks', iconName: 'utility:task' },
    { key: 'pendingTasks', label: 'Pending',     iconName: 'utility:clock' },
    { key: 'overdueTasks', label: 'At Risk',     iconName: 'utility:warning', risk: 'amber' },
    { key: 'wireTasks',    label: 'Wire Tasks',  iconName: 'utility:shield',  risk: 'red', goodWhenZero: true }
];

export default class TransactionTaskCards extends LightningElement {
    summary;
    error;

    @wire(getTaskSummary)
    wired({ data, error }) {
        if (data) {
            this.summary = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get hasError() {
        return !!this.error;
    }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load task metrics.';
    }

    get stats() {
        const s = this.summary || {};
        return META.map((m) => {
            const value = s[m.key] != null ? s[m.key] : 0;
            // Risk icons only "light up" when there's something to act on; a clean wire count
            // reads green. Token-backed rather than bare hex: `c/onboardingCardChild`
            // interpolates this into a CSS custom property, so a `var(...)` string resolves and
            // an SLDS 2 palette override can reach it.
            const NEUTRAL = 'var(--slds-g-color-neutral-base-40, #5a6b7b)';
            let iconColor = 'var(--slds-g-color-palette-blue-40, #1565c0)';
            if (m.key === 'pendingTasks') iconColor = NEUTRAL;
            else if (m.risk === 'amber')
                iconColor = value > 0 ? 'var(--slds-g-color-palette-orange-40, #bf5d0a)' : NEUTRAL;
            else if (m.risk === 'red')
                iconColor =
                    value > 0
                        ? 'var(--slds-g-color-palette-red-40, #c23934)'
                        : 'var(--slds-g-color-palette-green-50, #2e7d32)';
            return {
                key: m.key,
                label: m.label,
                iconName: m.iconName,
                iconColor,
                value: String(value)
            };
        });
    }
}