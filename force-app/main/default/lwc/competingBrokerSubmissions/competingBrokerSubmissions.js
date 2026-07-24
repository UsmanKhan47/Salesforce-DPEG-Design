import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSubmissions from '@salesforce/apex/CompetingSubmissionController.getSubmissions';

/**
 * c-competing-broker-submissions  (Broker Protection — CHUNK 4)
 * ---------------------------------------------------------------------------
 * Read-only panel for a *winning* Lead: lists every Competing_Broker_Submission__c
 * routed for that lead — the winning entry plus any competing ones — so a reviewer
 * can see the full broker-submission history behind the winner.
 *
 * Data access: a single reactive `@wire(getSubmissions, { leadId: '$recordId' })`.
 * The controller method is `@AuraEnabled(cacheable=true)`, so a wire is the
 * idiomatic consumer (LDS-first per ARCHITECTURE.md §5 — LDS can't express this
 * child aggregate, so a cacheable Apex wire is the correct next tier). No
 * imperative Apex, no DML.
 */

// Winner vs. competing badge, per Is_Winning_Submission__c. `variant` maps to an
// SLDS badge theme class below so lightning-badge carries its own SLDS-2 styling.
const WINNER_BADGE = { label: 'Winner', variant: 'success' };
const COMPETING_BADGE = { label: 'Competing', variant: 'inverse' };
const BADGE_CLASS = {
    success: 'slds-theme_success',
    inverse: 'slds-badge_inverse'
};
const EM_DASH = '—';

export default class CompetingBrokerSubmissions extends LightningElement {
    @api recordId;

    _submissions = [];
    error;

    @wire(getSubmissions, { leadId: '$recordId' })
    wiredSubmissions({ data, error }) {
        if (data) {
            // On data: hold the raw rows; `rows` maps them to the display shape.
            this._submissions = data;
            this.error = undefined;
        } else if (error) {
            // On error: clear the list and surface a user-safe toast.
            this._submissions = [];
            this.error = error;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not load broker submissions',
                    message: this.errorMessageText,
                    variant: 'error'
                })
            );
        }
    }

    /** User-safe message: prefer the Apex-thrown message, else a generic fallback. */
    get errorMessageText() {
        return (
            (this.error && this.error.body && this.error.body.message) ||
            'The broker-submission history could not be loaded. Please refresh, or contact your administrator if it keeps happening.'
        );
    }

    /** Mapped display rows (broker, forwarded-by, address, submitted, badge). */
    get rows() {
        return (this._submissions || []).map((s) => {
            const badge = s.Is_Winning_Submission__c
                ? WINNER_BADGE
                : COMPETING_BADGE;
            return {
                id: s.Id,
                brokerName: s.Broker_Name__c || EM_DASH,
                brokerEmail: s.Broker_Email__c,
                forwardedByEmail: s.Forwarded_By_Email__c,
                propertyAddress: s.Property_Address_Raw__c || EM_DASH,
                submittedDateTime: s.Submitted_DateTime__c,
                isWinner: s.Is_Winning_Submission__c === true,
                badgeLabel: badge.label,
                badgeClass: BADGE_CLASS[badge.variant],
                rowClass: s.Is_Winning_Submission__c
                    ? 'lv-row lv-row_winner'
                    : 'lv-row'
            };
        });
    }

    get hasSubmissions() {
        return this.rows.length > 0;
    }

    get count() {
        return this.rows.length;
    }
}
