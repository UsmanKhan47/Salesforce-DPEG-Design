import { LightningElement, wire, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getAssignments from '@salesforce/apex/BrokerAssignmentController.getAssignments';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const STATUS_META = {
    'Active':       { bg:'#EBF9F1', fg:'#146830', dot:'#22A652' },
    'Fully Leased': { bg:'#E2E0DB', fg:'#3F3C38', dot:'#8A8680' },
    'Disposed':     { bg:'#EEF1F5', fg:'#475569', dot:'#64748B' }
};
const pillWrap = (m) => `display:inline-flex;align-items:center;gap:6px;background:${m.bg};color:${m.fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const pillDot  = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

const STATUS_TABS = [
    { key:'all', label:'All' }, { key:'Active', label:'Active' },
    { key:'Fully Leased', label:'Leased' }, { key:'Disposed', label:'Disposed' }
];

const COLUMNS = [
    { label:'Property', fieldName:'recordUrl', type:'url', typeAttributes:{ label:{ fieldName:'propertyName' }, target:'_self' } },
    { label:'Broker', fieldName:'brokerName', type:'text' },
    { label:'Status', fieldName:'status', type:'pill', typeAttributes:{ wrapStyle:{ fieldName:'statusWrap' }, dotStyle:{ fieldName:'statusDot' } } },
    { label:'Listed', fieldName:'startLabel', type:'text', initialWidth:120 },
    { label:'Last check-in', fieldName:'checkInLabel', type:'text', initialWidth:130 },
    { label:'Days idle', fieldName:'daysText', type:'progress', initialWidth:160, sortable:true,
      typeAttributes:{ wrapStyle:'display:flex;align-items:center;gap:9px;min-width:120px',
        trackStyle:'width:60px;height:6px;background:#E2E0DB;border-radius:9999px;overflow:hidden',
        barStyle:{ fieldName:'daysBar' }, numStyle:{ fieldName:'daysNumStyle' }, text:{ fieldName:'daysText' } } },
    { label:'Follow-up', fieldName:'flagLabel', type:'pill', typeAttributes:{ wrapStyle:{ fieldName:'flagWrap' }, dotStyle:{ fieldName:'flagDot' } } }
];

export default class BrokerAssignmentList extends NavigationMixin(LightningElement) {
    @api warnDays = 14;
    @api overdueDays = 21;
    columns = COLUMNS;
    _data = [];
    @track statusFilter = 'all';
    @track sortDesc = true;

    @wire(getAssignments) wired({ data }) { if (data) this._data = data; }

    fmt(d) { if (!d) return '—'; const p = String(d).split('-').map(Number); return `${MONTHS[p[1]-1]} ${p[2]}, ${p[0]}`; }
    flagFor(r) {
        if (r.status !== 'Active') return null;
        const d = r.daysIdle;
        if (d != null && d > this.overdueDays) return { label:'Overdue', m:{bg:'#FDF0F0',fg:'#8B1A1A',dot:'#D93636'}, bar:'#D93636' };
        if (d != null && d >= this.warnDays)  return { label:'Follow up', m:{bg:'#FDF5E6',fg:'#7A4A00',dot:'#C88010'}, bar:'#C88010' };
        return { label:'On track', m:{bg:'#EBF9F1',fg:'#146830',dot:'#22A652'}, bar:'#22A652' };
    }
    get statusTabs() {
        return STATUS_TABS.map(t => {
            const count = t.key === 'all' ? this._data.length : this._data.filter(a => a.status === t.key).length;
            const active = this.statusFilter === t.key;
            return { key:t.key, label:t.label, count, value:t.key,
                cls: active ? 'sf-tab sf-tab--active' : 'sf-tab' };
        });
    }
    get rows() {
        let rows = this._data.filter(a =>
            (this.statusFilter === 'all' || a.status === this.statusFilter));
        rows = rows.map(a => {
            const m = STATUS_META[a.status] || STATUS_META['Active'];
            const flag = this.flagFor(a);
            const d = a.daysIdle;
            const barColor = a.status === 'Active' ? (flag ? flag.bar : '#22A652') : '#C8C4BE';
            const barW = Math.max(4, Math.min((d || 0) / this.overdueDays, 1) * 100);
            return {
                id: a.id, propertyName: a.propertyName || '—',
                recordUrl: `/lightning/r/Broker_Assignment__c/${a.id}/view`,
                brokerName: a.brokerName || '—',
                status: a.status, statusWrap: pillWrap(m), statusDot: pillDot(m.dot),
                startLabel: this.fmt(a.startDate),
                checkInLabel: this.fmt(a.lastCheckIn),
                _days: d == null ? -1 : d,
                daysText: d == null ? '—' : `${d}d`,
                daysBar: `width:${barW}%;height:100%;background:${barColor};border-radius:9999px`,
                daysNumStyle: `font-weight:700;font-size:12px;color:${a.status==='Active' && flag ? flag.m.fg : '#524F4A'};font-variant-numeric:tabular-nums`,
                flagLabel: (a.status === 'Active' && flag) ? flag.label : '—',
                flagWrap: (a.status === 'Active' && flag) ? pillWrap(flag.m) : 'color:#8A8680',
                flagDot: (a.status === 'Active' && flag) ? pillDot(flag.m.dot) : ''
            };
        });
        rows.sort((x,y) => this.sortDesc ? (y._days - x._days) : (x._days - y._days));
        return rows;
    }
    get count() { return this.rows.length; }
    get sortedBy() { return 'daysText'; }
    get sortDirection() { return this.sortDesc ? 'desc' : 'asc'; }

    handleStatus(e) { this.statusFilter = e.currentTarget.dataset.key; }
    handleSort(e) { this.sortDesc = e.detail.sortDirection === 'desc'; }
    newAssignment() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Broker_Assignment__c', actionName: 'new' }
        });
    }
}