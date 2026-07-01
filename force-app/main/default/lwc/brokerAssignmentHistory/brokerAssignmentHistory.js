import { LightningElement, api, wire } from 'lwc';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class BrokerAssignmentHistory extends LightningElement {
    @api recordId;
    d;

    @wire(getDetail, { assignmentId: '$recordId' })
    wired(result) {
        if (result.data) {
            this.d = result.data;
        }
    }

    fmt(v) {
        if (!v) return '—';
        const p = String(v).split('-').map(Number);
        return `${MONTHS[p[1] - 1]} ${p[2]}, ${p[0]}`;
    }

    get hasData() { return !!this.d; }
    get propertyName() { return (this.d && this.d.propertyName) || '—'; }
    get historyIntro() { return `Every broker ever assigned to ${this.propertyName} — nothing is deleted.`; }

    get historyRows() {
        const rows = [...((this.d && this.d.history) || [])];
        // Active rows first, then the rest by startDate descending (most recent next).
        rows.sort((a, b) => {
            const aActive = a.status === 'Active' ? 0 : 1;
            const bActive = b.status === 'Active' ? 0 : 1;
            if (aActive !== bActive) return aActive - bActive;
            return String(b.startDate || '').localeCompare(String(a.startDate || ''));
        });
        return rows.map((h) => ({
            id: h.id,
            brokerName: h.brokerName || '—',
            brokerFirm: h.brokerFirm || '—',
            reasonDisp: h.reason || '—',
            rangeDisp: `${this.fmt(h.startDate)} → ${h.endDate ? this.fmt(h.endDate) : 'present'}`,
            rowStyle: h.current
                ? 'display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 16px;margin-top:10px;border:1px solid #22A652;background:#F3FBF6;border-radius:8px'
                : 'display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 16px;margin-top:10px;border:1px solid #E2E0DB;background:#fff;border-radius:8px'
        }));
    }
}
