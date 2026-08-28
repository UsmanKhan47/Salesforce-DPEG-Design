import { LightningElement, wire } from 'lwc';
import getStageBreakdown from '@salesforce/apex/TransactionController.getStageBreakdown';

// Colors mirror the stage dots used on the Active Transactions list.
// ⚠ Keys are Transaction__c.Stage__c API names, and STAGES below is the canonical ORDER. The
// terminal value was renamed in Setup on 2026-08-28 ('Closed Won' -> 'Closed', label AND API
// name). While these were stale the failure was silent, not loud: `allStages` kept a permanently
// zero 'Closed Won' row AND appended the real 'Closed' bucket as an out-of-order SIXTH row, and
// both the arc and the legend swatch fell back to the grey 'Unspecified' colour. Keep the two
// lists in step — a key here without an entry in STAGES loses only the colour.
const STAGE_COLOR = {
    'Open Contract': '#4b7fd6',
    'Due Diligence': '#7e3fc0',
    'Closing Prep':  '#c98a33',
    'Post-Closing':  '#5b6bb0',
    'Closed':        '#3fae5e',
    'Unspecified':   '#94a3b8'
};
// The full set of picklist stages — always shown, even at zero.
const STAGES = ['Open Contract', 'Due Diligence', 'Closing Prep', 'Post-Closing', 'Closed'];

const R = 64;            // ring radius
const CX = 90;           // center (viewBox is 180×180)
const C = 2 * Math.PI * R; // circumference

export default class TransactionStageDonut extends LightningElement {
    _data;
    error;

    @wire(getStageBreakdown)
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get total() {
        return (this._data || []).reduce((sum, s) => sum + (s.count || 0), 0);
    }

    get hasData() {
        return this.total > 0;
    }

    get hasError() {
        return !!this.error;
    }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load the stage breakdown.';
    }
    // The genuine "no deals" empty state — not a failed load.
    get showEmpty() {
        return !this.error && !this.hasData;
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