import { LightningElement, api, wire } from 'lwc';
import getRentRoll from '@salesforce/apex/RentRollController.getRentRoll';

const MS_PER_MONTH = 1000 * 60 * 60 * 24 * 30.44;
const DOT_GREEN = '#1A7A6B';
const DOT_AMBER = '#D4940A';
const DOT_RED = '#C0392B';

const money = (n) =>
    '$' + Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const psf = (n) => '$' + Number(n).toFixed(2);
// Apex Date arrives as 'YYYY-MM-DD'
const mdy = (iso) => {
    if (!iso) return '';
    const p = String(iso).split('-');
    return `${parseInt(p[1], 10)}/${parseInt(p[2], 10)}/${p[0]}`;
};
const dateVal = (iso) => (iso ? new Date(iso + 'T00:00:00') : null);

export default class RentRoll extends LightningElement {
    @api recordId;
    data;
    error;
    expanded = {};
    sortKey = null;
    sortDir = 1;
    tip = null;

    @wire(getRentRoll, { propertyAssetId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.data = undefined;
        }
    }

    get isLoading() {
        return !this.data && !this.error;
    }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }
    get hasUnits() {
        return !!this.data && this.data.units.length > 0;
    }
    get isEmpty() {
        return !!this.data && this.data.units.length === 0;
    }
    get unitCount() {
        return this.data ? this.data.units.length : 0;
    }

    get summary() {
        const s = this.data.summary;
        return {
            totalSqFt: Number(s.totalSqFt || 0).toLocaleString('en-US'),
            occupiedSqFt: Number(s.occupiedSqFt || 0).toLocaleString('en-US'),
            vacantSqFt: Number(s.vacantSqFt || 0).toLocaleString('en-US'),
            occupiedPct: s.occupiedPct == null ? '' : s.occupiedPct + '%',
            vacantPct: s.vacantPct == null ? '' : s.vacantPct + '%',
            monthlyRent: money(s.monthlyRent || 0),
            occupiedLabel: s.occupiedCount + ' occupied unit' + (s.occupiedCount === 1 ? '' : 's'),
            occBarStyle: 'width:' + (s.occupiedPct || 0) + '%',
            vacBarStyle: 'width:' + (s.vacantPct || 0) + '%',
            lastSynced: s.lastSynced
                ? 'Last synced: ' +
                  new Date(s.lastSynced).toLocaleString('en-US', {
                      month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
                  })
                : 'Not yet synced'
        };
    }

    get headers() {
        const arrow = (k) => (this.sortKey === k ? (this.sortDir === 1 ? ' ▲' : ' ▼') : '');
        return {
            suite: 'Suite #' + arrow('suite'),
            sqft: 'Sq Ft' + arrow('sqft'),
            rent: 'Monthly Rent' + arrow('rent'),
            end: 'Lease Start → End' + arrow('end')
        };
    }

    get totals() {
        const s = this.data.summary;
        return {
            occLabel: s.occupiedCount + ' occupied · ' + s.vacantCount + ' vacant',
            sqftSplit:
                Number(s.occupiedSqFt || 0).toLocaleString('en-US') + ' occ · ' +
                Number(s.vacantSqFt || 0).toLocaleString('en-US') + ' vac',
            blendedPsf: s.blendedPsf == null ? '—' : psf(s.blendedPsf),
            nnnTotal: money(s.nnnMonthlyTotal || 0)
        };
    }

    sortValue(u) {
        const k = this.sortKey;
        if (k === 'suite') {
            const n = parseInt(u.suite, 10);
            return Number.isNaN(n) ? Infinity : n;
        }
        if (k === 'sqft') return u.squareFeet == null ? Infinity : u.squareFeet;
        if (k === 'rent') return u.currentRent == null ? Infinity : u.currentRent;
        if (k === 'end') {
            const d = dateVal(u.leaseEnd);
            return d ? d.getTime() : Infinity;
        }
        return 0;
    }

    get rows() {
        let units = [...this.data.units];
        if (this.sortKey) {
            units.sort((a, b) => {
                const av = this.sortValue(a);
                const bv = this.sortValue(b);
                if (av === bv) return 0;
                if (av === Infinity) return 1;   // nulls/vacant always last
                if (bv === Infinity) return -1;
                return (av - bv) * this.sortDir;
            });
        }
        const today = new Date();
        today.setHours(0, 0, 0, 0); // date-pure compare: steps stay Active through their final day
        return units.map((u) => {
            const occupied = u.status === 'Occupied';
            const isExpanded = occupied && !!this.expanded[u.unitId];

            let dot = null;
            const end = dateVal(u.leaseEnd);
            if (occupied && end) {
                const months = (end.getTime() - today.getTime()) / MS_PER_MONTH;
                const color = months > 12 ? DOT_GREEN : months >= 6 ? DOT_AMBER : DOT_RED;
                dot = {
                    style: 'background:' + color,
                    title: 'Lease ends ' + mdy(u.leaseEnd) + ' — about ' +
                        Math.max(0, Math.round(months)) + ' months out'
                };
            }

            let psfDisp = '—';
            let psfClass = 'mono';
            if (u.currentRentPsf != null) {
                psfDisp = psf(u.currentRentPsf);
            } else if (u.askingRentPsf != null) {
                psfDisp = psf(u.askingRentPsf) + ' asking';
                psfClass = 'mono asking';
            }

            const hasNnn = u.nnnMonthlyTotal != null;
            let nnnDisp = '—';
            let nnnClass = 'mono';
            if (hasNnn) {
                nnnDisp = money(u.nnnMonthlyTotal);
                nnnClass = 'mono nnn-val';
            } else if (u.estimatedNnnPsf != null) {
                nnnDisp = psf(u.estimatedNnnPsf) + '/SF est.';
                nnnClass = 'mono nnn-est';
            }

            return {
                id: u.unitId,
                panelKey: u.unitId + '-panel',
                occupied,
                isExpanded,
                rowClass: occupied ? 'occ' : 'vac',
                chevStyle: isExpanded ? 'transform:rotate(180deg)' : '',
                suiteDisp: u.suite || '—',
                tenantDisp: u.tenant || '— Vacant —',
                tenantClass: u.tenant ? 'tenant' : 'tenant vacant',
                sqftDisp: u.squareFeet == null ? '—' : Number(u.squareFeet).toLocaleString('en-US'),
                rentDisp: u.currentRent == null ? '—' : money(u.currentRent),
                psfDisp, psfClass,
                termDisp: occupied && u.leaseStart ? mdy(u.leaseStart) + ' → ' + mdy(u.leaseEnd) : '—',
                dot,
                nnnDisp, nnnClass,
                panelTitle: 'Suite ' + (u.suite || '—') + (u.tenant ? ' · ' + u.tenant : ''),
                nnnTaxDisp: u.nnnTax == null ? '—' : money(u.nnnTax),
                nnnInsDisp: u.nnnInsurance == null ? '—' : money(u.nnnInsurance),
                nnnCamDisp: u.nnnCam == null ? '—' : money(u.nnnCam),
                nnnTotDisp: hasNnn ? money(u.nnnMonthlyTotal) : '—',
                nnnPsfDisp: u.nnnPsf == null ? '—' : psf(u.nnnPsf),
                steps: (u.steps || []).map((s, i) => {
                    const start = dateVal(s.periodStart);
                    const stepEnd = dateVal(s.periodEnd);
                    const active = !!(start && stepEnd && today >= start && today <= stepEnd);
                    const noRent = s.monthlyRent == null;
                    return {
                        key: u.unitId + '-s' + i,
                        period: s.periodLabel || mdy(s.periodStart) + ' – ' + mdy(s.periodEnd),
                        active,
                        rowClass: active ? 'srow active' : 'srow',
                        rentDisp: noRent ? (s.note || '—') : money(s.monthlyRent),
                        rentClass: noRent ? 'snote' : active ? 'srent srent-bold' : 'srent',
                        psfDisp: s.rentPsf == null ? '—' : psf(s.rentPsf),
                        typeLabel: s.stepType || '',
                        tagClass: s.stepType === 'Renewal Option' ? 'tag gold' : 'tag navy'
                    };
                })
            };
        });
    }

    toggleRow(event) {
        const id = event.currentTarget.dataset.id;
        const u = this.data.units.find((x) => x.unitId === id);
        if (!u || u.status !== 'Occupied') return;
        this.expanded = { ...this.expanded, [id]: !this.expanded[id] };
    }

    sortBy(event) {
        const key = event.currentTarget.dataset.key;
        if (this.sortKey !== key) {
            this.sortKey = key;
            this.sortDir = 1;
        } else if (this.sortDir === 1) {
            this.sortDir = -1;
        } else {
            this.sortKey = null;
            this.sortDir = 1;
        }
    }

    tipEnter(event) {
        const id = event.currentTarget.dataset.id;
        const u = this.data.units.find((x) => x.unitId === id);
        if (!u || u.nnnMonthlyTotal == null) return;
        const r = event.currentTarget.getBoundingClientRect();
        this.tip = {
            style: 'left:' + Math.round(r.right) + 'px; top:' + Math.round(r.top - 8) + 'px',
            suite: 'Suite ' + (u.suite || '—'),
            tax: u.nnnTax == null ? '—' : money(u.nnnTax),
            ins: u.nnnInsurance == null ? '—' : money(u.nnnInsurance),
            cam: u.nnnCam == null ? '—' : money(u.nnnCam),
            total: money(u.nnnMonthlyTotal),
            psf: u.nnnPsf == null ? '—' : psf(u.nnnPsf)
        };
    }

    tipLeave() {
        this.tip = null;
    }
}
