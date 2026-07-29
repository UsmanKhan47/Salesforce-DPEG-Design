import { LightningElement, api } from 'lwc';
import {
    changeLeadStatus,
    guardLeadAction,
    showSuccess
} from 'c/leadStatusChange';

const TARGET = 'Disqualified';
const CONFIRM = {
    message: 'Are you sure you want to disqualify this lead?',
    label: 'Disqualify Lead',
    theme: 'warning'
};

/**
 * leadDisqualify — headless one-click quick action that moves a Lead to 'Disqualified'.
 *
 * Renders no UI (empty template); the platform calls @api invoke() on click. Every click runs the
 * shared pre-flight in c/leadStatusChange first — permission check, then a LightningConfirm dialog
 * — and does nothing unless both pass. This one uses the 'warning' theme because disqualifying is
 * the off-ramp out of the funnel. The status write then goes through LDS updateRecord, which writes
 * THROUGH the LDS cache, so the Lead Path/highlights refresh reactively with NO
 * getRecordNotifyChange.
 *
 * This is the many→one off-ramp: valid from New OR Under Review OR Qualified, always writing
 * 'Disqualified'. It is shown on those three stages via a Dynamic Actions "Any" visibility rule the
 * admin configures in App Builder. Its hardcoded target is why the derive-from-current-stage bundle
 * model does not fit here.
 *
 * NOTE ON "DISABLING" THIS BUTTON: a headless quick action owns no button markup — the platform's
 * action bar renders it — so there is no `disabled` attribute this component can set. Graying the
 * button out for unauthorized users is a Dynamic Actions visibility rule (declarative, App
 * Builder); this component enforces the same rule at click time.
 */
export default class LeadDisqualify extends LightningElement {
    @api recordId;

    @api async invoke() {
        if (!(await guardLeadAction(this, CONFIRM))) {
            return;
        }
        const ok = await changeLeadStatus(this, this.recordId, TARGET);
        if (ok) {
            showSuccess(this, `Lead moved to ${TARGET}.`);
        }
    }
}
