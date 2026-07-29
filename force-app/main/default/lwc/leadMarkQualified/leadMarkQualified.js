import { LightningElement, api } from 'lwc';
import {
    changeLeadStatus,
    guardLeadAction,
    showSuccess
} from 'c/leadStatusChange';

const TARGET = 'Qualified';
const CONFIRM = {
    message: 'Mark this lead as Qualified?',
    label: 'Mark Qualified',
    theme: 'info'
};

/**
 * leadMarkQualified — headless one-click quick action that moves a Lead to 'Qualified'.
 *
 * Renders no UI (empty template); the platform calls @api invoke() on click. Every click runs the
 * shared pre-flight in c/leadStatusChange first — permission check, then a LightningConfirm dialog
 * — and does nothing unless both pass. The status write then goes through LDS updateRecord, which
 * writes THROUGH the LDS cache, so the Lead Path/highlights refresh reactively with NO
 * getRecordNotifyChange. Shown only on the 'Under Review' stage via a Dynamic Actions visibility
 * rule the admin configures in App Builder.
 *
 * NOTE ON "DISABLING" THIS BUTTON: a headless quick action owns no button markup — the platform's
 * action bar renders it — so there is no `disabled` attribute this component can set. Graying the
 * button out for unauthorized users is a Dynamic Actions visibility rule (declarative, App
 * Builder); this component enforces the same rule at click time.
 */
export default class LeadMarkQualified extends LightningElement {
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
