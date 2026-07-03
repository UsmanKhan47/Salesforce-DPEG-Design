import { LightningElement, wire } from 'lwc';
import getAttention from '@salesforce/apex/LeaseRenewalController.getAttention';

const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

// Right-column widget: renewals that need a nudge — tenant gone quiet or lease
// expiring within 30 days.
export default class RenewalAttention extends LightningElement {
    _data = [];
    @wire(getAttention) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((q) => {
            const nonResp = q.nonResponsive;
            const d = q.daysToExpiry == null ? 0 : q.daysToExpiry;
            return {
                id: q.id,
                recordUrl: `/lightning/r/Lease_Renewal__c/${q.id}/view`,
                tenant: q.tenant || '—',
                sub: nonResp ? `Non-responsive · ${q.daysSinceContact}d silent` : `${q.stage} · expires soon`,
                pillText: d < 0 ? 'Expired' : `${d}d left`,
                pillWrap: nonResp ? pill('#FDECEC', '#B01818') : pill('#FDF0F0', '#8B1A1A'),
                pillDot: nonResp ? dot('#D42B2B') : dot('#D93636')
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}
