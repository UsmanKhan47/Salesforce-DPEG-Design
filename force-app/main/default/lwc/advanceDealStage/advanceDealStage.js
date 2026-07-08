import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, getRecordNotifyChange } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import STAGE_FIELD from '@salesforce/schema/Opportunity.StageName';
import advance from '@salesforce/apex/StageAdvanceController.advance';

// The "next step" button label per current stage. Stages not listed here
// (Development/Construction Review, Portfolio Deal, Closed Won, Dead/Pass)
// render no button, so the action only ever shows where it applies.
const NEXT_LABEL = {
    New: 'Begin Review',
    'Under Review': 'Initiate Underwriting',
    Underwriting: 'Initiate LOI',
    LOI: 'Advance to PSA',
    PSA: 'Close Deal'
};

export default class AdvanceDealStage extends LightningElement {
    @api recordId;
    stage;
    working = false;

    @wire(getRecord, { recordId: '$recordId', fields: [STAGE_FIELD] })
    wired({ data }) {
        if (data) {
            this.stage = getFieldValue(data, STAGE_FIELD);
        }
    }

    get hasAction() {
        return !!NEXT_LABEL[this.stage];
    }

    get label() {
        return NEXT_LABEL[this.stage];
    }

    async handleClick() {
        this.working = true;
        try {
            const message = await advance({ recordId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Success', message, variant: 'success' })
            );
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            const message =
                (error && error.body && error.body.message) ||
                'The deal could not be advanced.';
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Cannot advance the deal', message, variant: 'error' })
            );
        } finally {
            this.working = false;
        }
    }
}
