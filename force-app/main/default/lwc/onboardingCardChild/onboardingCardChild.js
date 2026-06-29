import { LightningElement, api } from 'lwc';

// Presentational stat card (grey variant): icon + value + caps label in a native SLDS card.
export default class OnboardingCardChild extends LightningElement {
    @api value;
    @api label;
    @api iconName;
    @api iconColor;
    // Optional: switches the card to a green "complete" background. Defaults to the grey card.
    @api done = false;

    get cardClass() {
        return this.done ? 'stat-card stat-card--done' : 'stat-card';
    }

    // Tints the (utility) icon foreground when a color is supplied.
    get iconStyle() {
        return this.iconColor
            ? `--slds-c-icon-color-foreground-default:${this.iconColor};--sds-c-icon-color-foreground-default:${this.iconColor}`
            : '';
    }
}