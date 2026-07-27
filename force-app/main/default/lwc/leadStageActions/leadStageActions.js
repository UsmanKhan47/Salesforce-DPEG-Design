import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';
import convertLead from '@salesforce/apex/LeadConvertActionController.convertLead';

// Lead Status picklist values (this org). Only 'Converted' is flagged converted=true.
const STATUS = {
    NEW: 'New',
    UNDER_REVIEW: 'Under Review',
    QUALIFIED: 'Qualified',
    DISQUALIFIED: 'Disqualified',
    CONVERTED: 'Converted'
};

// Sentinel action value distinguishing the Convert button (imperative Apex conversion) from the
// status-only buttons (whose value is the target Status they write via LDS).
const CONVERT = '__convert__';

// State machine: current Status -> the valid next-step buttons. Absent statuses (Disqualified,
// Converted, and any unknown/loading value) are terminal and render no buttons.
const TRANSITIONS = {
    [STATUS.NEW]: [
        { label: 'Under Review', value: STATUS.UNDER_REVIEW, variant: 'brand' },
        { label: 'Disqualified', value: STATUS.DISQUALIFIED, variant: 'destructive' }
    ],
    [STATUS.UNDER_REVIEW]: [
        { label: 'Qualified', value: STATUS.QUALIFIED, variant: 'brand' },
        { label: 'Disqualified', value: STATUS.DISQUALIFIED, variant: 'destructive' }
    ],
    [STATUS.QUALIFIED]: [
        { label: 'Convert', value: CONVERT, variant: 'brand' },
        { label: 'Disqualified', value: STATUS.DISQUALIFIED, variant: 'destructive' }
    ]
};

const GENERIC_ERROR =
    'Something went wrong. Please try again or contact your administrator.';

/**
 * leadStageActions — renders the valid next-step buttons for the current Lead Status.
 *
 * Reads Status reactively via LDS getRecord; the wire re-emitting after a status change is what
 * re-renders the button set (no refreshApex on the status-only path). Status-only transitions are
 * written with LDS updateRecord (no Apex). The Convert action calls imperative Apex
 * (LeadConvertActionController.convertLead) and navigates to the resulting Opportunity.
 */
export default class LeadStageActions extends NavigationMixin(LightningElement) {
    @api recordId;

    status;
    // Transient in-flight guard: disables the buttons while an LDS/Apex call is running so a
    // double-click cannot fire a second transition. This is NOT the stage-based hiding.
    busy = false;

    @wire(getRecord, { recordId: '$recordId', fields: [STATUS_FIELD] })
    wiredLead({ data, error }) {
        if (data) {
            this.status = getFieldValue(data, STATUS_FIELD);
        } else if (error) {
            this.status = undefined;
            this.showError(this.messageFor(error));
        }
    }

    // Buttons valid for the current Status, each carrying the transient in-flight disabled flag.
    get buttons() {
        const definitions = TRANSITIONS[this.status] || [];
        return definitions.map((definition) => ({
            ...definition,
            disabled: this.busy
        }));
    }

    get hasButtons() {
        return this.buttons.length > 0;
    }

    handleClick(event) {
        if (this.busy) {
            return;
        }
        const value = event.currentTarget.dataset.value;
        if (value === CONVERT) {
            this.convert();
            return;
        }
        this.setStatus(value);
    }

    // Status-only transition via LDS. The getRecord wire re-emits the new Status, so the buttons
    // re-render for the next stage automatically — no imperative Apex, no manual refresh.
    async setStatus(status) {
        this.busy = true;
        try {
            await updateRecord({ fields: { Id: this.recordId, Status: status } });
            this.showSuccess(`Lead moved to ${status}.`);
        } catch (error) {
            this.showError(this.messageFor(error));
        } finally {
            this.busy = false;
        }
    }

    // Irreversible conversion via imperative Apex, then navigate to the new Opportunity. The
    // Lead page auto-redirects to the converted Contact, so navigating away is the correct UX.
    async convert() {
        this.busy = true;
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
            this.showError(this.messageFor(error));
        } finally {
            this.busy = false;
        }
    }

    // Prefer the AuraHandledException / DmlException message (user-safe by construction here);
    // fall back to a generic message so no raw platform text leaks and nothing renders undefined.
    messageFor(error) {
        return (
            (error && error.body && error.body.message) ||
            (error && error.message) ||
            GENERIC_ERROR
        );
    }

    showSuccess(message) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Success',
                message,
                variant: 'success'
            })
        );
    }

    showError(message) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Error',
                message,
                variant: 'error'
            })
        );
    }
}
