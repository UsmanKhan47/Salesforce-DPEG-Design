import { LightningElement, api } from 'lwc';

// Presentational stat card: an icon + a value + a caps label, in a native SLDS card.
export default class StatCard extends LightningElement {
    @api value;
    @api label;
    @api iconName;
    @api iconColor;

    // Tints the (utility) icon foreground when a color is supplied.
    get iconStyle() {
        return this.iconColor
            ? `--slds-c-icon-color-foreground-default:${this.iconColor};--sds-c-icon-color-foreground-default:${this.iconColor}`
            : '';
    }
}