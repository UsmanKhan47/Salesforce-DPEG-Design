import { LightningElement, wire } from 'lwc';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';

// Per-channel icon + accent color for the stat tiles.
const META = {
    'Email-to-Lead': { icon: 'utility:file', color: '#5BC6C3' },
    'Broker Portal': { icon: 'utility:user', color: '#B968C9' },
    'Manual Entry':  { icon: 'utility:edit', color: '#5DA8EC' }
};

export default class LeadChannels extends LightningElement {
    data;
    error;

    @wire(getFunnel)
    wired({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.data = undefined;
        }
    }

    get hasError() { return !!this.error; }
    get errorMessage() {
        return (this.error && this.error.body && this.error.body.message) || 'Unknown error';
    }

    get stats() {
        if (!this.data) {
            return [];
        }
        const tiles = this.data.channels.map((c) => {
            const m = META[c.label] || {};
            return {
                key: c.label,
                label: c.label,
                value: String(c.count),
                iconName: m.icon || 'utility:record',
                iconColor: m.color || '#90A4AE'
            };
        });
        tiles.push({
            key: 'review',
            label: 'Review Queue',
            value: String(this.data.reviewQueue || 0),
            iconName: 'utility:warning',
            iconColor: '#E6A23C'
        });
        return tiles;
    }
}