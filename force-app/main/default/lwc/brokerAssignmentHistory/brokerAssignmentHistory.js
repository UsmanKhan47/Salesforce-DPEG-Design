import { LightningElement, api, wire } from 'lwc';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const STATUS_META = {
    'Active':       { bg: '#EBF9F1', fg: '#146830', dot: '#22A652' },
    'Fully Leased': { bg: '#E2E0DB', fg: '#3F3C38', dot: '#8A8680' },
    'Replaced':     { bg: '#FDF0F0', fg: '#B52020', dot: '#D93636' },
    'Terminated':   { bg: '#F9CECE', fg: '#8B1A1A', dot: '#B52020' }
};

const pillWrap = (m) => `display:inline-flex;align-items:center;gap:6px;background:${m.bg};color:${m.fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const pillDot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

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
        const rows = (this.d && this.d.history) || [];
        return rows.map((h) => {
            const m = STATUS_META[h.status] || STATUS_META['Active'];
            return {
                id: h.id,
                statusLabel: h.status || '—',
                brokerName: h.brokerName || '—',
                brokerFirm: h.brokerFirm || '—',
                reasonDisp: h.reason || '—',
                rangeDisp: `${this.fmt(h.startDate)} → ${h.endDate ? this.fmt(h.endDate) : 'present'}`,
                wrapStyle: pillWrap(m),
                dotStyle: pillDot(m.dot),
                rowStyle: h.current
                    ? 'display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 16px;margin-top:10px;border:1px solid #22A652;background:#F3FBF6;border-radius:8px'
                    : 'display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 16px;margin-top:10px;border:1px solid #E2E0DB;background:#fff;border-radius:8px'
            };
        });
    }
}
