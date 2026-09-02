import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import CHECKLIST_FANNED_OUT_FIELD from '@salesforce/schema/Transaction__c.Checklist_Fanned_Out__c';
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';
import {
    MODEL_CHECKLIST,
    MODEL_LEGACY,
    PHASES,
    modelFor,
    normalizeChecklistGroups,
    normalizeLegacyGroups
} from 'c/utilsTransactionChecklist';

/**
 * Sidebar 2x2 grid: checklist progress for each of the four deal phases.
 *
 * 🔴 SERVES BOTH CHECKLIST MODELS, discriminated on `Transaction__c.Checklist_Fanned_Out__c` read
 * via LDS `getRecord`. Only the selected model's Apex wire is provisioned — the other's
 * `transactionId` resolves to `undefined` and the adapter is never called. If the discriminator
 * cannot be read, NEITHER model renders and an error is shown: a migrated deal still carries its
 * old `Task` rows, so guessing legacy would show plausible, silently stale numbers. Full argument
 * in `c/utilsTransactionChecklist`.
 *
 * ⚠ THE PHASE LABELS COME FROM `c/utilsTransactionChecklist.PHASES` AND ARE NO LONGER DECLARED
 * HERE. This component used to carry its own copy of the array, which is how it drifted to
 * `Closing` / `Post Closing` while the data said `Closing Prep` / `Post-Closing` (design §2.12).
 * The labels now match `Transaction__c.Stage__c` byte for byte, including the hyphen, and there is
 * one place to change them.
 */
export default class TransactionPhaseCards extends LightningElement {
    @api recordId;

    _modelResolved = false;
    _modelError;
    _fannedOut;
    _checklistData = [];
    _checklistError;
    _checklistLoaded = false;
    _legacyData = [];
    _legacyError;
    _legacyLoaded = false;

    @wire(getRecord, { recordId: '$recordId', fields: [CHECKLIST_FANNED_OUT_FIELD] })
    wiredTransaction({ data, error }) {
        if (data) {
            this._fannedOut = getFieldValue(data, CHECKLIST_FANNED_OUT_FIELD);
            this._modelResolved = true;
            this._modelError = undefined;
        } else if (error) {
            this._modelError = error;
            this._modelResolved = false;
            this._fannedOut = undefined;
        }
    }

    get model() {
        return this._modelResolved ? modelFor(this._fannedOut) : undefined;
    }
    get isChecklistModel() {
        return this.model === MODEL_CHECKLIST;
    }
    get isLegacyModel() {
        return this.model === MODEL_LEGACY;
    }
    get checklistTransactionId() {
        return this.isChecklistModel ? this.recordId : undefined;
    }
    get legacyTransactionId() {
        return this.isLegacyModel ? this.recordId : undefined;
    }

    @wire(getChecklist, { transactionId: '$checklistTransactionId' })
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

    @wire(getTaskGroups, { transactionId: '$legacyTransactionId' })
    wiredLegacy({ data, error }) {
        if (data) {
            this._legacyData = data;
            this._legacyError = undefined;
            this._legacyLoaded = true;
        } else if (error) {
            this._legacyError = error;
            this._legacyData = [];
            this._legacyLoaded = true;
        }
    }

    get groups() {
        if (this.isChecklistModel) {
            return normalizeChecklistGroups(this._checklistData);
        }
        if (this.isLegacyModel) {
            return normalizeLegacyGroups(this._legacyData);
        }
        return [];
    }

    get error() {
        if (this._modelError) {
            return this._modelError;
        }
        if (this.isChecklistModel) {
            return this._checklistError;
        }
        if (this.isLegacyModel) {
            return this._legacyError;
        }
        return undefined;
    }

    get hasError() {
        return !!this.error;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load phase progress.';
    }

    /** The DISCRIMINATOR has not resolved and has not failed. Only the first half of loading. */
    get isResolvingModel() {
        return !this._modelResolved && !this._modelError;
    }

    /**
     * Whether the ACTIVE model's Apex round trip has come back — with data or with an error.
     *
     * 🔴 THE SECOND HALF OF "LOADING". Resolving the discriminator only says WHICH Apex method
     * to call; the call is a separate round trip, and between the two `groups` is legitimately
     * `[]`. Gated on the discriminator alone, the empty state fired on EVERY page load for a
     * healthy deal. See `c/transactionTaskGroups` for the full writeup.
     */
    get dataLoaded() {
        if (this.isChecklistModel) {
            return this._checklistLoaded;
        }
        if (this.isLegacyModel) {
            return this._legacyLoaded;
        }
        return false;
    }

    /** Either half still outstanding. Neither an error nor an empty state may render while true. */
    get isLoading() {
        return this.isResolvingModel || (!this.hasError && !this.dataLoaded);
    }

    /**
     * True when the model resolved, nothing errored, and there is no checklist at all.
     * Rendered as an explicit message: four `0 / 0` cards look like a load that worked and found
     * nothing done, which is a different and much less alarming statement than "no checklist
     * exists on this deal".
     */
    get isEmpty() {
        return !this.hasError && !this.isLoading && this.groups.length === 0;
    }

    /**
     * 🔴 NOTHING RENDERS WHILE THE MODEL IS STILL RESOLVING, AND THAT IS A DELIBERATE CHANGE.
     * Before Phase 3 this component painted four `0 / 0` cards immediately — which was harmless
     * when there was one data source and one wire, and is not harmless now: it states "the
     * checklist loaded and nothing is done" at a moment when the component does not yet know
     * which of TWO models the deal is even on. A `transactionPhaseCards` regression test caught
     * exactly this during the rewrite.
     */
    get showCards() {
        return !this.hasError && !this.isEmpty && !this.isLoading;
    }

    get emptyMessage() {
        return this.isChecklistModel
            ? 'No checklist has been generated for this deal yet.'
            : 'No tasks have been generated for this deal yet.';
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
