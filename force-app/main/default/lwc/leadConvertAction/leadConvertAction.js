import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { guardLeadAction } from 'c/leadStatusChange';
import convertLead from '@salesforce/apex/LeadConvertActionController.convertLead';

const CONVERT_ERROR = 'Unable to convert this lead.';
const CONFIRM = {
    message: 'Are you sure you want to convert this lead?',
    label: 'Convert Lead',
    theme: 'warning'
};

/**
 * leadConvertAction — headless one-click quick action that converts a Qualified Lead.
 *
 * Renders no UI (empty template); the platform calls @api invoke() on click. Every click runs the
 * shared pre-flight in c/leadStatusChange first — permission check, then a LightningConfirm dialog
 * — and does nothing unless both pass. The 'warning' theme is used because conversion is
 * irreversible.
 *
 * Conversion itself runs Database.convertLead server-side, so this bundle REUSES the existing
 * LeadConvertActionController.convertLead(leadId) Apex (which delegates to LeadConvertActionService)
 * — it does not rebuild any convert logic. On success it navigates to the new Opportunity (the Lead
 * page auto-redirects to the converted Contact, so navigating away is the correct UX and no
 * source-record refresh is needed). On failure it surfaces the AuraHandledException message in an
 * error toast. Shown only on the 'Qualified' stage via a Dynamic Actions visibility rule the admin
 * configures in App Builder.
 *
 * DEFENCE IN DEPTH: the client-side permission check here is a UX gate only. The same permission is
 * asserted server-side by LeadConvertActionController before it converts anything, so a caller that
 * skips this component gains nothing.
 *
 * NOTE ON "DISABLING" THIS BUTTON: a headless quick action owns no button markup — the platform's
 * action bar renders it — so there is no `disabled` attribute this component can set. Graying the
 * button out for unauthorized users is a Dynamic Actions visibility rule (declarative, App
 * Builder); this component enforces the same rule at click time.
 */
export default class LeadConvertAction extends NavigationMixin(LightningElement) {
    @api recordId;

    @api async invoke() {
        if (!(await guardLeadAction(this, CONFIRM))) {
            return;
        }
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
