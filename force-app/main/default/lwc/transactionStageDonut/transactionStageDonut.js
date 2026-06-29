import { LightningElement, wire } from 'lwc';
import getStageBreakdown from '@salesforce/apex/TransactionController.getStageBreakdown';

// Colors mirror the stage dots used on the Active Transactions list.
const STAGE_COLOR = {
    'Open Contract': '#4b7fd6',
    'Due Diligence': '#7e3fc0',
    'Closing Prep':  '#c98a33',
    'Post-Closing':  '#5b6bb0',
    'Closed Won':    '#3fae5e',
    'Unspecified':   '#94a3b8'
};
// The full set of picklist stages — always shown, even at zero.
const STAGES = ['Open Contract', 'Due Diligence', 'Closing Prep', 'Post-Closing', 'Closed Won'];

const R = 64;            // ring radius
const CX = 90;           // center (viewBox is 180×180)
const C = 2 * Math.PI * R; // circumference

export default class TransactionStageDonut extends LightningElement {
    _data;

    @wire(getStageBreakdown)
    wired({ data }) {
        if (data) {
            this._data = data;
        }
    }

    get total() {
        return (this._data || []).reduce((sum, s) => sum + (s.count || 0), 0);
    }

    get hasData() {
        return this.total > 0;
    }

    // Stage -> count map from the apex breakdown.
    get countByStage() {
        const m = {};
        (this._data || []).forEach((s) => {
            m[s.stage] = (m[s.stage] || 0) + (s.count || 0);
        });
        return m;
    }

    // Every picklist stage in canonical order (zero-count included), plus any
    // unspecified/null bucket that actually has records.
    get allStages() {
        const m = this.countByStage;
        const rows = STAGES.map((stage) => ({ stage, count: m[stage] || 0 }));
        Object.keys(m).forEach((stage) => {
            if (!STAGES.includes(stage) && (m[stage] || 0) > 0) {
                rows.push({ stage, count: m[stage] || 0 });
            }
        });
        return rows;
    }

    // One <circle> arc per non-empty stage: a single dash of the stage's length, rotated to
    // start where the previous stage ended (first arc begins at 12 o'clock, hence −90°).
    // Zero-count stages draw no arc but still appear in the legend.
    get segments() {
        const total = this.total;
        if (!total) return [];
        let cumulative = 0;
        return this.allStages
            .filter((s) => s.count > 0)
            .map((s) => {
                const frac = s.count / total;
                const dash = frac * C;
                const startDeg = cumulative * 360 - 90;
                cumulative += frac;
                return {
                    key: s.stage,
                    color: STAGE_COLOR[s.stage] || STAGE_COLOR.Unspecified,
                    dashArray: `${dash} ${C}`,
                    transform: `rotate(${startDeg} ${CX} ${CX})`
                };
            });
    }

    get legend() {
        const total = this.total || 1;
        return this.allStages.map((s) => ({
            key: s.stage,
            stage: s.stage,
            count: s.count,
            pct: Math.round((s.count / total) * 100) + '%',
            swatchStyle: `background:${STAGE_COLOR[s.stage] || STAGE_COLOR.Unspecified}`
        }));
    }
}