import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { changeLeadStatus } from 'c/leadStatusChange';

const TARGET = 'Disqualified';

/**
 * leadDisqualify — headless one-click quick action that moves a Lead to 'Disqualified'.
 *
 * Renders no UI (empty template); the platform calls @api invoke() on click. The status write goes
 * through LDS updateRecord (in c/leadStatusChange), which writes THROUGH the LDS cache — so the
 * Lead Path/highlights refresh reactively with NO getRecordNotifyChange. This is the many→one
 * off-ramp: valid from New OR Under Review OR Qualified, always writing 'Disqualified'. It is shown
 * on those three stages via a Dynamic Actions "Any" visibility rule the admin configures in App
 * Builder. Its hardcoded target is why the derive-from-current-stage bundle model does not fit here.
 */
export default class LeadDisqualify extends LightningElement {
    @api recordId;

    @api async invoke() {
        const ok = await changeLeadStatus(this, this.recordId, TARGET);
        if (ok) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: `Lead moved to ${TARGET}.`,
                    variant: 'success'
                })
            );
        }
    }
}
