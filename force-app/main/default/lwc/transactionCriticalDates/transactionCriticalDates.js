import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import CED from '@salesforce/schema/Transaction__c.Contract_Executed_Date__c';
import EM from '@salesforce/schema/Transaction__c.Earnest_Money__c';
import EMD from '@salesforce/schema/Transaction__c.EM_Wired_Date__c';
import EAR from '@salesforce/schema/Transaction__c.Is_Earnest_At_Risk__c';
import FEAS from '@salesforce/schema/Transaction__c.Feasibility_Deadline__c';
import FMISS from '@salesforce/schema/Transaction__c.Feasibility_Missed__c';
import CLOSE from '@salesforce/schema/Transaction__c.Target_Close_Date__c';
import STATUS from '@salesforce/schema/Transaction__c.Status__c';
import STAGE from '@salesforce/schema/Transaction__c.Stage__c';

const FIELDS = [CED, EM, EMD, EAR, FEAS, FMISS, CLOSE, STATUS, STAGE];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class TransactionCriticalDates extends LightningElement {
    @api recordId;
    _rec;
    error;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wired({ data, error }) {
        if (data) {
            this._rec = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get hasData() {
        return !!this._rec;
    }

    get hasError() {
        return !!this.error;
    }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load critical dates.';
    }
    // The genuine "nothing scheduled yet" empty state — not a failed record load.
    get showEmpty() {
        return !this.error && !this._rec;
    }

    get rows() {
        if (!this._rec) return [];
        const f = (field) => getFieldValue(this._rec, field);

        const emDate = f(EMD);
        const feas = f(FEAS);
        const close = f(CLOSE);
        const closed = f(STATUS) === 'Closed' || f(STAGE) === 'Closed Won';

        return [
            this.buildRow({
                key: 'contract', label: 'Contract Executed', icon: 'utility:contract',
                date: f(CED),
                terminal: this.isPastOrToday(f(CED)) ? 'done' : null, terminalLabel: 'Executed'
            }),
            this.buildRow({
                key: 'em', label: 'Earnest Money', icon: 'utility:money',
                date: emDate, amount: f(EM), atRisk: f(EAR),
                terminal: this.isPastOrToday(emDate) ? 'good' : null, terminalLabel: 'Funded'
            }),
            this.buildRow({
                key: 'feas', label: 'Feasibility End', icon: 'utility:event',
                date: feas, warnWithin: 5,
                terminal: f(FMISS) ? 'bad' : (this.isPast(feas) ? 'ended' : null),
                terminalLabel: f(FMISS) ? 'Missed' : 'Ended'
            }),
            this.buildRow({
                key: 'close', label: 'Closing', icon: 'utility:success',
                date: close, warnWithin: 7,
                terminal: closed ? 'good' : (this.isPast(close) ? 'bad' : null),
                terminalLabel: closed ? 'Closed' : 'Overdue'
            })
        ];
    }

    // Builds one milestone row: formats the date/amount and resolves the status pill + countdown.
    buildRow({ key, label, icon, date, amount, atRisk, warnWithin, terminal, terminalLabel }) {
        let statusLabel;
        let tone; // green | red | grey | amber | blue
        if (terminal === 'done' || terminal === 'good') {
            statusLabel = terminalLabel;
            tone = 'green';
        } else if (terminal === 'bad') {
            statusLabel = terminalLabel;
            tone = 'red';
        } else if (terminal === 'ended') {
            statusLabel = 'Ended';
            tone = 'grey';
        } else if (date == null) {
            statusLabel = '—';
            tone = 'grey';
        } else {
            const days = this.daysUntil(date);
            statusLabel = this.countdownLabel(days);
            tone = warnWithin != null && days <= warnWithin ? 'amber' : 'blue';
        }
        const color = { green: '#1d7a3f', red: '#ba0517', amber: '#a85a08', blue: '#1565c0', grey: '#969492' }[tone];
        const amountLabel = amount != null ? this.fmtMoney(amount) : null;
        const atRiskFlag = !!atRisk && (terminal === 'good' || terminal == null);
        return {
            key,
            label,
            icon,
            dateLabel: this.fmtDate(date),
            amountLabel,
            atRisk: atRiskFlag,
            hasSub: amountLabel != null || atRiskFlag,
            statusLabel,
            statusClass: `cd-pill cd-pill--${tone}`,
            iconStyle: `background:${color}1f;--icon:${color}`
        };
    }

    countdownLabel(days) {
        if (days == null) return '—';
        if (days === 0) return 'Today';
        if (days === 1) return 'in 1 day';
        if (days > 1) return `in ${days} days`;
        if (days === -1) return '1 day ago';
        return `${-days} days ago`;
    }

    // ---- date helpers (parse YYYY-MM-DD as local midnight to avoid TZ drift) ----
    daysUntil(d) {
        if (!d) return null;
        const p = String(d).split('-');
        if (p.length !== 3) return null;
        const target = new Date(+p[0], +p[1] - 1, +p[2]);
        const now = new Date();
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        return Math.round((target - today) / 86400000);
    }
    isPast(d) {
        const n = this.daysUntil(d);
        return n != null && n < 0;
    }
    isPastOrToday(d) {
        const n = this.daysUntil(d);
        return n != null && n <= 0;
    }
    fmtDate(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length !== 3) return '—';
        return MONTHS[+p[1] - 1] + ' ' + +p[2] + ', ' + p[0];
    }
    fmtMoney(v) {
        const n = parseFloat(v);
        if (isNaN(n) || n === 0) return '$0';
        const a = Math.abs(n);
        if (a >= 1e6) {
            const m = n / 1e6;
            return '$' + (m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)) + 'M';
        }
        if (a >= 1e3) {
            const t = n / 1e3;
            return '$' + (t % 1 === 0 ? t.toFixed(0) : t.toFixed(1)) + 'k';
        }
        return '$' + n.toFixed(0);
    }
}