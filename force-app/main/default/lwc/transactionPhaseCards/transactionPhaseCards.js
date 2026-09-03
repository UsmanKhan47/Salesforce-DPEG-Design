import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import CHECKLIST_FANNED_OUT_FIELD from '@salesforce/schema/Transaction__c.Checklist_Fanned_Out__c';
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';
import { PHASES, normalizeChecklistGroups } from 'c/utilsTransactionChecklist';

/**
 * Sidebar 2x2 grid: checklist progress for each of the four deal phases.
 *
 * 🔴 AMENDED 2026-09-03 (M5) — THE MODEL DISCRIMINATOR IS GONE. This component used to serve TWO
 * checklist models, choosing between `ChecklistController.getChecklist` and
 * `TransactionTaskController.getTaskGroups` on `Transaction__c.Checklist_Fanned_Out__c`. The
 * legacy Task model is retired — its controller, service, fan-out, rollup and the script that
 * could re-arm it were all deleted, and a probe confirmed zero `Task` rows carry
 * `Transaction_Deal__c` org-wide — so NO DEAL CAN BE ON THE LEGACY MODEL ANY MORE and there is
 * nothing left to discriminate between. `getChecklist` is now wired unconditionally on `recordId`.
 *
 * ⚠ THE `Checklist_Fanned_Out__c` LDS READ IS DELIBERATELY RETAINED, DEMOTED FROM DISCRIMINATOR TO
 * ADVISORY: it no longer chooses a data source, it only chooses the wording of `emptyMessage`.
 * Dropping it would have collapsed "the fan-out ran and produced nothing" into "no checklist yet"
 * and made the empty state WORSE than the legacy one it replaces — the UI-4 regression risk in
 * `agent-output/design-legacy-task-retirement.md` §3.3. A failed flag read is therefore no longer
 * fatal; it degrades one sentence, and the four cards still render.
 *
 * ⚠ THE PHASE LABELS COME FROM `c/utilsTransactionChecklist.PHASES` AND ARE NO LONGER DECLARED
 * HERE. This component used to carry its own copy of the array, which is how it drifted to
 * `Closing` / `Post Closing` while the data said `Closing Prep` / `Post-Closing` (design §2.12).
 * The labels now match `Transaction__c.Stage__c` byte for byte, including the hyphen, and there is
 * one place to change them.
 */
export default class TransactionPhaseCards extends LightningElement {
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
            // Advisory only — see the class header. The cards still render; only `emptyMessage`
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

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load phase progress.';
    }

    /**
     * Whether the Apex round trip has come back — with data or with an error.
     *
     * 🔴 STILL LOAD-BEARING AFTER M5. Between mount and the wire resolving, `groups` is
     * legitimately `[]`, and rendering the empty state then fires it on EVERY page load for a
     * healthy deal. This gate used to have a second half (waiting on the model discriminator);
     * that half is gone, this one is not.
     */
    get dataLoaded() {
        return this._checklistLoaded;
    }

    /** The round trip is still outstanding. Neither an error nor an empty state may render. */
    get isLoading() {
        return !this.hasError && !this.dataLoaded;
    }

    /**
     * True when the round trip finished, nothing errored, and there is no checklist at all.
     * Rendered as an explicit message: four `0 / 0` cards look like a load that worked and found
     * nothing done, which is a different and much less alarming statement than "no checklist
     * exists on this deal".
     */
    get isEmpty() {
        return !this.hasError && !this.isLoading && this.groups.length === 0;
    }

    /**
     * 🔴 NOTHING RENDERS WHILE THE DATA IS STILL LOADING, AND THAT IS A DELIBERATE CHANGE.
     * Before Phase 3 this component painted four `0 / 0` cards immediately, which states "the
     * checklist loaded and nothing is done" at a moment when nothing has loaded. A
     * `transactionPhaseCards` regression test caught exactly this during the rewrite.
     * ⚠ The gate is narrower after M5 (one wire, not two) but it is NOT redundant — the Apex
     * round trip is still asynchronous and `groups` is still `[]` until it returns.
     */
    get showCards() {
        return !this.hasError && !this.isEmpty && !this.isLoading;
    }

    /**
     * ⚠ AMENDED 2026-09-03 (M5). This used to name the MODEL that produced the emptiness; it now
     * names the CAUSE, read from the flag directly. The neutral third case is new and REACHABLE:
     * it means the advisory LDS flag read failed, so neither diagnosis can be asserted honestly.
     */
    get emptyMessage() {
        if (!this._flagResolved) {
            return 'No checklist items to show for this deal.';
        }
        return this._fannedOut === true
            ? 'A checklist was generated for this deal, but it contains no items.'
            : 'No checklist has been generated for this deal yet.';
    }

    /** One card per phase: complete/total progress, green once every item in the phase is done. */
    get cards() {
        const totals = {};
        PHASES.forEach((p) => {
            totals[p.key] = { complete: 0, total: 0 };
        });
        this.groups.forEach((g) => {
            const bucket = totals[g.phaseKey];
            if (bucket) {
                bucket.complete += g.complete || 0;
                bucket.total += g.total || 0;
            }
        });
        return PHASES.map((p) => {
            const { complete, total } = totals[p.key];
            const done = total > 0 && complete >= total;
            return {
                key: p.key,
                label: p.name,
                value: `${complete} / ${total}`,
                iconName: p.icon,
                // Token-backed, not a bare hex. `c/onboardingCardChild` interpolates this into a
                // CSS custom property, so a `var(...)` string resolves normally and the card
                // follows an SLDS 2 palette override instead of pinning a literal colour.
                iconColor: done
                    ? 'var(--slds-g-color-palette-green-50, #2e7d32)'
                    : 'var(--slds-g-color-palette-blue-40, #1565c0)',
                done
            };
        });
    }
}
