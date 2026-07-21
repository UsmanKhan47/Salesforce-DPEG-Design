import { LightningElement, wire } from 'lwc';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';

export default class SellMeterHeader extends LightningElement {
    _rows;
    error;

    @wire(getPortfolio)
    wired({ data, error }) {
        if (data) {
            this._rows = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get assetCount() {
        return this._rows ? this._rows.length : 0;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }
}