import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import CHECKLIST_FANNED_OUT_FIELD from '@salesforce/schema/Transaction__c.Checklist_Fanned_Out__c';
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';
import { normalizeChecklistGroups, percent } from 'c/utilsTransactionChecklist';

/**
 * Sidebar card: overall completion across every checklist group on this Transaction.
 *
 * 🔴 AMENDED 2026-09-03 (M5) — THE MODEL DISCRIMINATOR IS GONE. This component used to serve TWO
 * checklist models, choosing between `ChecklistController.getChecklist` and
 * `TransactionTaskController.getTaskGroups` on `Transaction__c.Checklist_Fanned_Out__c`. The
 * legacy Task model is retired: its controller, service, fan-out, rollup and the script that could
 * re-arm it were all deleted, and a probe confirmed zero `Task` rows carry `Transaction_Deal__c`
 * org-wide, so NO DEAL CAN BE ON THE LEGACY MODEL ANY MORE. There is nothing left to discriminate
 * between, so `getChecklist` is now wired unconditionally on `recordId`.
 *
 * ⚠ THE `Checklist_Fanned_Out__c` LDS READ IS DELIBERATELY RETAINED, DEMOTED FROM DISCRIMINATOR TO
 * ADVISORY. It no longer chooses a data source; it distinguishes "the fan-out ran and produced
 * nothing" (a real problem worth naming) from "this deal has not been fanned out yet" (normal on
 * any deal with no executed contract). Dropping the wire entirely would have collapsed both into
 * one message and made the empty state WORSE than the legacy one it replaces — the specific
 * regression risk flagged as UI-4 in `agent-output/design-legacy-task-retirement.md` §3.3.
 * 🔴 BECAUSE IT IS ADVISORY, A FAILED FLAG READ IS NO LONGER FATAL. It used to blank the whole
 * card, correctly, because without it the component could not know which model to render. Now it
 * only degrades one sentence of empty-state copy, so the checklist still renders. Do not
 * re-promote it to a hard error without a reason of its own.
 *
 * ⚠ THE PERCENTAGE IS COMPUTED FROM THE SAME NORMALISED GROUPS `transactionTaskGroups` RENDERS,
 * through the SAME `percent()` helper — not from `Transaction__c.Completion_Pct__c`. Both live on
 * a Transaction record page at the same time, and a summary card reading 41% above a checklist
 * showing 42% is the kind of contradiction that makes people stop trusting the whole screen.
 */
export default class TransactionChecklistSummary extends LightningElement {
    @api recordId;

    _flagResolved = false;
    _fannedOut;
    _checklistData = [];
    _checklistError;
    _checklistLoaded = false;

    @wire(getRecord, { recordId: '$recordId', fields: [CHECKLIST_FANNED_OUT_FIELD] })
    wiredTransaction({ data, error }) {
        if (data) {
            this._fannedOut = getFieldValue(data, CHECKLIST_FANNED_OUT_FIELD);
            this._flagResolved = true;
        } else if (error) {
            // Advisory only — see the class header. The card still renders; only `emptyLabel`
            // loses its ability to tell "fanned out and empty" from "never fanned out".
            this._flagResolved = false;
            this._fannedOut = undefined;
        }
    }

    @wire(getChecklist, { transactionId: '$recordId' })
    wiredChecklist({ data, error }) {
        if (data) {
            this._checklistData = data;
            this._checklistError = undefined;
            this._checklistLoaded = true;
        } else if (error) {
            this._checklistError = error;
            this._checklistData = [];
            // Both branches: the round trip is over either way.
            this._checklistLoaded = true;
        }
    }

    get groups() {
        return normalizeChecklistGroups(this._checklistData);
    }

    get error() {
        return this._checklistError;
    }

    get hasError() {
        return !!this.error;
    }

    /**
     * Whether the Apex round trip has come back — with data or with an error.
     *
     * 🔴 STILL LOAD-BEARING AFTER M5, FOR A REASON THAT SURVIVED THE DISCRIMINATOR. Between mount
     * and the wire resolving, `groups` is legitimately empty. Without this gate EVERY page load
     * briefly rendered "Checklist generated, but no items found" on a healthy deal — a sentence
     * whose whole purpose is to say something is WRONG. It used to have a second half (waiting on
     * the discriminator); that half is gone, this one is not.
     */
    get dataLoaded() {
        return this._checklistLoaded;
    }

    /** The round trip is still outstanding. No empty-state copy may render while true. */
    get isLoading() {
        return !this.hasError && !this.dataLoaded;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load the checklist summary.';
    }

    /**
     * The single progress line.
     *
     * ⚠ EVERY MEMBER IS A NON-EMPTY STRING OR A CLASS NAME, NEVER `undefined`. `barStyle` and
     * `barClass` are bound to element ATTRIBUTES, and a getter bound to an attribute is written
     * UNCONDITIONALLY — an `undefined` here renders the literal text `undefined` into the DOM.
     */
    get overall() {
        const groups = this.groups;
        const total = groups.reduce((s, g) => s + (g.total || 0), 0);
        const complete = groups.reduce((s, g) => s + (g.complete || 0), 0);
        const pct = percent(complete, total);
        return {
            pctLabel: total ? `${pct}%` : '—',
            label: total
                ? `${complete} of ${total} complete`
                : this.emptyLabel,
            barStyle: `width:${pct}%`,
            barClass: pct >= 100 ? 'cs-bar cs-bar--done' : 'cs-bar'
        };
    }

    /**
     * Names the CAUSE of the emptiness rather than saying "No checklist generated yet" for both
     * cases. An empty checklist on a deal whose `Checklist_Fanned_Out__c` is TRUE means the
     * fan-out ran and produced nothing — a different problem from a deal that was never fanned out
     * at all, and one worth telling someone about.
     *
     * ⚠ AMENDED 2026-09-03 (M5). This distinction used to fall out of the model discriminator; it
     * now reads the flag directly, which is the same information without the retired branch. The
     * `undefined` case is new and is REACHABLE: it means the LDS flag read failed, so the honest
     * answer is the neutral one rather than either diagnosis.
     */
    get emptyLabel() {
        // ⚠ THE LOADING CHECK MUST COME FIRST. The strings below are diagnoses, and a diagnosis
        // rendered before the data arrives is a false one shown on every page load.
        if (this.isLoading) {
            return 'Loading…';
        }
        if (!this._flagResolved) {
            return 'No checklist items to show';
        }
        return this._fannedOut === true
            ? 'Checklist generated, but no items found'
            : 'No checklist generated yet';
    }
}
