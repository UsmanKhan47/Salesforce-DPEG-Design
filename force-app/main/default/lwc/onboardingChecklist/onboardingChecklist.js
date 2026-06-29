import { LightningElement, api, wire } from 'lwc';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const STATUS = {
    'Complete':       { fg:'#15625A', bg:'#E2F0EC', dot:'#1A7A6B', label:'Complete' },
    'In Progress':    { fg:'#8A5A00', bg:'#FBF1DA', dot:'#D4940A', label:'In Progress' },
    'Not Started':    { fg:'#4B5563', bg:'#ECEEF1', dot:'#6B7280', label:'Not Started' },
    'Blocked':        { fg:'#962518', bg:'#FAE6E2', dot:'#C0392B', label:'Blocked' },
    'Not Applicable': { fg:'#9CA3AF', bg:'#F1F2F4', dot:'#9CA3AF', label:'Not Applicable' }
};
const SYS = {
    'Yardi':      { fg:'#1B3A6B', bg:'#E8EDF6' },
    'Excel':      { fg:'#1B6E47', bg:'#E5EFE9' },
    'Salesforce': { fg:'#0E6E97', bg:'#E1F1F8' },
    'Email':      { fg:'#5B6470', bg:'#EEF0F2' }
};
const CTRL = {
    'Complete':       { bg:'#1A7A6B', border:'#1A7A6B', mark:'✓', mc:'#fff' },
    'In Progress':    { bg:'#fff',    border:'#D4940A', mark:'•', mc:'#D4940A' },
    'Not Started':    { bg:'#fff',    border:'#C7CBD1', mark:'',       mc:'#6B7280' },
    'Blocked':        { bg:'#FAE6E2', border:'#C0392B', mark:'!',      mc:'#C0392B' },
    'Not Applicable': { bg:'#F1F2F4', border:'#D1D5DB', mark:'–', mc:'#9CA3AF' }
};
const AVATAR = { 'Isha Patel':'#1B3A6B', 'Fernando Ruiz':'#1A7A6B', 'Endya Williams':'#D4940A', 'Accounting Queue':'#6B7280' };
const FILTERS = ['All','In Progress','Blocked','Not Applicable','Overdue'];

const initials = (n) => !n ? '?' : (n === 'Accounting Queue' ? 'AQ' : n.split(' ').map((w) => w[0]).join('').slice(0,2).toUpperCase());
const pctColor = (p) => (p >= 80 ? '#1A7A6B' : p >= 50 ? '#D4940A' : '#C0392B');

export default class OnboardingChecklist extends LightningElement {
    @api recordId;
    groups = [];
    selectedIndex = 0;
    filter = 'All';

    @wire(getChecklist, { onboardingId: '$recordId' })
    wired({ data }) { if (data) this.groups = data; }

    get headerLabel() {
        let total = 0, complete = 0;
        this.groups.forEach((g) => { total += g.total; complete += g.complete; });
        const pct = total ? Math.round((100 * complete) / total) : 0;
        return `${complete} of ${total} complete (${pct}%)`;
    }
    get tiles() {
        return this.groups.map((g, i) => {
            const sel = i === this.selectedIndex;
            return {
                key: g.category, letter: String.fromCharCode(65 + i), name: g.category,
                count: `${g.complete} / ${g.total}`, index: String(i),
                tileStyle: `display:flex;align-items:center;gap:11px;padding:10px 14px;border-radius:10px;cursor:pointer;min-width:200px;border:1px solid ${sel ? '#1B96FF' : '#E0E0E0'};background:${sel ? '#EAF5FE' : '#fff'}`,
                badgeStyle: `width:30px;height:30px;border-radius:50%;flex:none;display:inline-flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;${sel ? 'background:#1B96FF;color:#fff' : 'background:#fff;color:#706E6B;border:2px solid #C9C7C5'}`
            };
        });
    }
    get chips() {
        return FILTERS.map((f) => {
            const active = this.filter === f;
            return { key: f, label: f, name: f,
                chipStyle: `padding:5px 13px;border-radius:9999px;font-size:12px;font-weight:600;cursor:pointer;white-space:nowrap;background:${active ? '#1B3A6B' : '#fff'};color:${active ? '#fff' : '#5C5C5C'};border:1px solid ${active ? '#1B3A6B' : '#D7DAE0'}` };
        });
    }
    get selected() {
        const g = this.groups[this.selectedIndex];
        if (!g) return { letter: 'A', name: '', count: '0 / 0', fillStyle: 'width:0%;height:100%' };
        const pct = g.total ? Math.round((100 * g.complete) / g.total) : 0;
        return { letter: String.fromCharCode(65 + this.selectedIndex), name: g.category, count: `${g.complete} / ${g.total}`,
            fillStyle: `width:${pct}%;height:100%;background:${pctColor(pct)};border-radius:9999px` };
    }
    get items() {
        const g = this.groups[this.selectedIndex];
        if (!g) return [];
        return g.items.filter((it) => this.matches(it)).map((it) => this.enrich(it));
    }
    get isEmpty() { return this.items.length === 0; }

    matches(it) {
        const f = this.filter;
        if (f === 'All') return true;
        if (f === 'Overdue') return it.overdue;
        return it.status === f;
    }
    enrich(it) {
        const s = STATUS[it.status] || STATUS['Not Started'];
        const sys = SYS[it.sourceSystem] || SYS['Email'];
        const c = CTRL[it.status] || CTRL['Not Started'];
        const done = it.status === 'Complete' || it.status === 'Not Applicable';
        const color = AVATAR[it.owner] || '#6B7280';
        return {
            id: it.id, name: it.name,
            nameStyle: `font-size:13.5px;font-weight:500;color:${done ? '#9A9A9A' : '#181818'};text-decoration:${done ? 'line-through' : 'none'}`,
            isBlocked: it.status === 'Blocked', reason: it.reason || '',
            statusLabel: s.label,
            badgeStyle: `display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:9999px;font-size:11px;font-weight:600;background:${s.bg};color:${s.fg};white-space:nowrap`,
            dotStyle: `width:6px;height:6px;border-radius:50%;background:${s.dot};flex-shrink:0`,
            system: it.sourceSystem,
            sysStyle: `display:inline-flex;align-items:center;padding:2px 8px;border-radius:4px;font-size:10px;font-weight:700;letter-spacing:0.02em;background:${sys.bg};color:${sys.fg}`,
            controlStyle: `width:20px;height:20px;border-radius:5px;border:2px solid ${c.border};background:${c.bg};display:inline-flex;align-items:center;justify-content:center;font-size:${c.mark === '•' ? '15px' : '12px'};font-weight:700;color:${c.mc};flex:none;line-height:1`,
            controlMark: c.mark,
            initials: initials(it.owner),
            avatarStyle: `width:24px;height:24px;border-radius:50%;background:${color};color:#fff;font-size:9.5px;font-weight:700;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0`,
            ownerShort: it.owner === 'Accounting Queue' ? 'Accounting' : (it.owner ? it.owner.split(' ')[0] : ''),
            due: this.dateLabel(it.due),
            dueStyle: `font-size:12px;font-weight:${it.overdue ? '700' : '500'};color:${it.overdue ? '#C0392B' : '#5C5C5C'};white-space:nowrap`,
            notesColor: it.hasNotes ? '#1B3A6B' : '#CDD1D7'
        };
    }
    dateLabel(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length !== 3) return d;
        return MONTHS[parseInt(p[1], 10) - 1] + ' ' + p[2];
    }
    selectGroup(e) { this.selectedIndex = parseInt(e.currentTarget.dataset.index, 10); this.filter = 'All'; }
    selectFilter(e) { this.filter = e.currentTarget.dataset.name; }
}
