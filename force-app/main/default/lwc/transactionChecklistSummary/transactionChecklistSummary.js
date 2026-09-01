import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import CHECKLIST_FANNED_OUT_FIELD from '@salesforce/schema/Transaction__c.Checklist_Fanned_Out__c';
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';
import {
    MODEL_CHECKLIST,
    MODEL_LEGACY,
    modelFor,
    normalizeChecklistGroups,
    normalizeLegacyGroups,
    percent
} from 'c/utilsTransactionChecklist';

/**
 * Sidebar card: overall completion across every checklist group on this Transaction.
 *
 * 🔴 SERVES BOTH CHECKLIST MODELS, discriminated on `Transaction__c.Checklist_Fanned_Out__c` read
 * via LDS `getRecord`. Only the selected model's Apex wire is provisioned. If the discriminator
 * cannot be read, NEITHER model renders — see `c/utilsTransactionChecklist` for why guessing
 * legacy is the worst of the three options.
 *
 * ⚠ THE PERCENTAGE IS COMPUTED FROM THE SAME NORMALISED GROUPS `transactionTaskGroups` RENDERS,
 * through the SAME `percent()` helper — not from `Transaction__c.Completion_Pct__c`. Both live on
 * a Transaction record page at the same time, and a summary card reading 41% above a checklist
 * showing 42% is the kind of contradiction that makes people stop trusting the whole screen.
 */
export default class TransactionChecklistSummary extends LightningElement {
    @api recordId;

    _modelResolved = false;
    _modelError;
    _fannedOut;
    _checklistData = [];
    _checklistError;
    _legacyData = [];
    _legacyError;

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
        } else if (error) {
            this._checklistError = error;
            this._checklistData = [];
        }
    }

    @wire(getTaskGroups, { transactionId: '$legacyTransactionId' })
    wiredLegacy({ data, error }) {
        if (data) {
            this._legacyData = data;
            this._legacyError = undefined;
        } else if (error) {
            this._legacyError = error;
            this._legacyData = [];
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
     * Named the model that produced the emptiness rather than saying "No checklist generated
     * yet" for both. On the new model, an empty checklist on a deal whose
     * `Checklist_Fanned_Out__c` is TRUE means the fan-out ran and produced nothing — a different
     * problem from a deal that was never fanned out at all, and one worth telling someone about.
     */
    get emptyLabel() {
        if (this.isChecklistModel) {
            return 'Checklist generated, but no items found';
        }
        if (this.isLegacyModel) {
            return 'No checklist generated yet';
        }
        return 'Loading…';
    }
}
