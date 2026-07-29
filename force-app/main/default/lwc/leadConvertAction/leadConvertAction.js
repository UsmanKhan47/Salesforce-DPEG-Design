import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import convertLead from '@salesforce/apex/LeadConvertActionController.convertLead';

const CONVERT_ERROR = 'Unable to convert this lead.';

/**
 * leadConvertAction — headless one-click quick action that converts a Qualified Lead.
 *
 * Renders no UI (empty template); the platform calls @api invoke() on click. Conversion is
 * irreversible and runs Database.convertLead server-side, so it REUSES the existing
 * LeadConvertActionController.convertLead(leadId) Apex UNCHANGED (which delegates to
 * LeadConvertActionService) — this bundle does not rebuild any convert logic. On success it
 * navigates to the new Opportunity (the Lead page auto-redirects to the converted Contact, so
 * navigating away is the correct UX and no source-record refresh is needed). On failure it surfaces
 * the AuraHandledException message in an error toast. Shown only on the 'Qualified' stage via a
 * Dynamic Actions visibility rule the admin configures in App Builder.
 */
export default class LeadConvertAction extends NavigationMixin(LightningElement) {
    @api recordId;

    @api async invoke() {
        try {
            const opportunityId = await convertLead({ leadId: this.recordId });
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: opportunityId,
                    objectApiName: 'Opportunity',
                    actionName: 'view'
                }
            });
        } catch (error) {
            const message =
                (error && error.body && error.body.message) || CONVERT_ERROR;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Cannot convert the lead',
                    message,
                    variant: 'error'
                })
            );
        }
    }
}
