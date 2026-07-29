import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { changeLeadStatus } from 'c/leadStatusChange';

const TARGET = 'Qualified';

/**
 * leadMarkQualified — headless one-click quick action that moves a Lead to 'Qualified'.
 *
 * Renders no UI (empty template); the platform calls @api invoke() on click. The status write goes
 * through LDS updateRecord (in c/leadStatusChange), which writes THROUGH the LDS cache — so the
 * Lead Path/highlights refresh reactively with NO getRecordNotifyChange. Shown only on the
 * 'Under Review' stage via a Dynamic Actions visibility rule the admin configures in App Builder.
 */
export default class LeadMarkQualified extends LightningElement {
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
