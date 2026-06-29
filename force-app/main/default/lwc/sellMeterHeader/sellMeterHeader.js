import { LightningElement, wire } from 'lwc';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';

export default class SellMeterHeader extends LightningElement {
    _rows;

    @wire(getPortfolio)
    wired({ data }) {
        if (data) {
            this._rows = data;
        }
    }

    get assetCount() {
        return this._rows ? this._rows.length : 0;
    }
}