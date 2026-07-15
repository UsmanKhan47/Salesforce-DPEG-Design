import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import logCheckIn from '@salesforce/apex/BrokerAssignmentController.logCheckIn';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const STATUS_META = {
    'Active':       { bg: '#EBF9F1', fg: '#146830', dot: '#22A652' },
    'Fully Leased': { bg: '#E2E0DB', fg: '#3F3C38', dot: '#8A8680' },
    'Replaced':     { bg: '#FDF0F0', fg: '#B52020', dot: '#D93636' },
    'Terminated':   { bg: '#F9CECE', fg: '#8B1A1A', dot: '#B52020' }
};
const REASONS = ['Leased Up', 'Performance Issue', 'Company Decision', 'Other'];

const pillWrap = (m) => `display:inline-flex;align-items:center;gap:6px;background:${m.bg};color:${m.fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const pillDot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

export default class BrokerAssignmentDetail extends LightningElement {
    @api recordId;
    @api warnDays = 14;
    @api overdueDays = 21;
    d;
    _wire;
    @track tab = 'details';
    @track replacing = false;
    @track repBrokerId;
    @track repReason = 'Performance Issue';
    @track repDate;
    _saving = false;

    @wire(getDetail, { assignmentId: '$recordId' })
    wired(result) {
        this._wire = result;
        if (result.data) {
            this.d = result.data;
        }
    }
    @wire(getBrokerOptions) brokerOpts;

    // ---------- formatting helpers ----------
    fmt(v) {
        if (!v) return '—';
        const p = String(v).split('-').map(Number);
        return `${MONTHS[p[1] - 1]} ${p[2]}, ${p[0]}`;
    }
    area(v) {
        return v == null ? '—' : `${Number(v).toLocaleString()} sq ft`;
    }
    flagFor() {
        if (!this.d || this.d.status !== 'Active') return null;
        const dd = this.d.daysIdle;
        if (dd != null && dd > this.overdueDays) return { label: 'Overdue', m: { bg: '#FDF0F0', fg: '#8B1A1A', dot: '#D93636' } };
        if (dd != null && dd >= this.warnDays) return { label: 'Follow up', m: { bg: '#FDF5E6', fg: '#7A4A00', dot: '#C88010' } };
        return { label: 'On track', m: { bg: '#EBF9F1', fg: '#146830', dot: '#22A652' } };
    }

    // ---------- header / status getters ----------
    get hasData() { return !!this.d; }
    get propertyName() { return (this.d && this.d.propertyName) || '—'; }
    get propertyType() { return (this.d && this.d.propertyType) || '—'; }
    get propertyAddr() { return (this.d && this.d.propertyAddr) || '—'; }
    get brokerName() { return (this.d && this.d.brokerName) || '—'; }
    get brokerFirm() { return (this.d && this.d.brokerFirm) || '—'; }
    get brokerEmail() { return (this.d && this.d.brokerEmail) || '—'; }
    get brokerPhone() { return (this.d && this.d.brokerPhone) || '—'; }
    get statusLabel() { return (this.d && this.d.status) || '—'; }
    get startDisp() { return this.fmt(this.d && this.d.startDate); }
    get endDisp() { return this.fmt(this.d && this.d.endDate); }
    get checkInDisp() { return this.fmt(this.d && this.d.lastCheckIn); }
    get reasonDisp() { return (this.d && this.d.reason) || '—'; }
    get grossSqFtDisp() { return this.area(this.d && this.d.grossSqFt); }
    get vacantAreaDisp() { return this.area(this.d && this.d.vacantArea); }
    get leasedAreaDisp() { return this.area(this.d && this.d.leasedArea); }
    get daysDisp() {
        const dd = this.d && this.d.daysIdle;
        return dd == null ? '—' : `${dd}d`;
    }
    get meta() { return STATUS_META[this.d ? this.d.status : 'Active'] || STATUS_META['Active']; }
    get statusBadgeStyle() { return pillWrap(this.meta); }
    get statusDotStyle() { return pillDot(this.meta.dot); }
    get daysHlStyle() {
        const flag = this.flagFor();
        const fg = flag ? flag.m.fg : '#524F4A';
        return `font-size:14px;font-weight:700;color:${fg};font-variant-numeric:tabular-nums`;
    }

    // ---------- flag banner ----------
    get showFlag() {
        const flag = this.flagFor();
        return !!(flag && (flag.label === 'Overdue' || flag.label === 'Follow up'));
    }
    get flagBanner() {
        const flag = this.flagFor();
        if (!flag) return '';
        const dd = this.d.daysIdle;
        return flag.label === 'Overdue'
            ? `Check-in overdue — ${dd} days since last contact.`
            : `Follow up soon — ${dd} days since last contact.`;
    }
    get flagBannerStyle() {
        const flag = this.flagFor();
        const m = flag ? flag.m : STATUS_META['Active'];
        return `display:flex;align-items:center;gap:8px;margin-top:16px;padding:11px 14px;background:${m.bg};border:1px solid ${m.bg};border-radius:6px;color:${m.fg};font-size:13px;font-weight:500`;
    }

    // ---------- tab state ----------
    get showDetails() { return this.tab === 'details'; }
    get showHistory() { return this.tab === 'history'; }
    get showNotes() { return this.tab === 'notes'; }
    get tabDetailsClass() { return this.tab === 'details' ? 'ba-tab ba-tab--on' : 'ba-tab'; }
    get tabHistoryClass() { return this.tab === 'history' ? 'ba-tab ba-tab--on' : 'ba-tab'; }
    get tabNotesClass() { return this.tab === 'notes' ? 'ba-tab ba-tab--on' : 'ba-tab'; }
    selectDetails() { this.tab = 'details'; }
    selectHistory() { this.tab = 'history'; }
    selectNotes() { this.tab = 'notes'; }

    // ---------- action gating ----------
    get canReplace() { return !!(this.d && this.d.status === 'Active'); }

    // ---------- history rows ----------
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
    get historyIntro() { return `Every broker ever assigned to ${this.propertyName} — nothing is deleted.`; }

    // ---------- refresh after mutations ----------
    async refresh() {
        await refreshApex(this._wire);
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
    }

    // ---------- actions ----------
    async handleLogCheckIn() {
        if (this._saving) return;
        this._saving = true;
        try {
            await logCheckIn({ assignmentId: this.recordId });
            await this.refresh();
        } finally {
            this._saving = false;
        }
    }
    openReplace() {
        this.replacing = true;
        this.repBrokerId = null;
        this.repReason = 'Performance Issue';
        this.repDate = null;
    }
    closeReplace() { this.replacing = false; }
    async confirmReplace() {
        if (this._saving) return;
        this._saving = true;
        try {
            await replaceBroker({
                assignmentId: this.recordId,
                newBrokerId: this.repBrokerId,
                effectiveDate: this.repDate,
                reason: this.repReason
            });
            this.replacing = false;
            await this.refresh();
        } finally {
            this._saving = false;
        }
    }

    // ---------- modal option lists & handlers ----------
    get reasonOptions() { return REASONS.map((r) => ({ label: r, value: r })); }
    get brokerOptionList() {
        return ((this.brokerOpts && this.brokerOpts.data) || []).map((o) => ({ label: o.label, value: o.id }));
    }
    onRepBroker(e) { this.repBrokerId = e.detail.value; }
    onRepReason(e) { this.repReason = e.detail.value; }
    onRepDate(e) { this.repDate = e.target.value; }
    get replaceNote() {
        return `${this.brokerName}'s listing is closed as Replaced — the full record stays visible — and a new Active listing opens for the incoming broker.`;
    }
}