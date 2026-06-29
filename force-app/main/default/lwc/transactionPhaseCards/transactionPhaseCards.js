import { LightningElement, api, wire } from 'lwc';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';

// The four deal phases and the task-group letters that roll up into each (mirrors transactionTaskGroups).
const PHASES = [
    { key: 'open',  name: 'Open Contract', letters: ['A', 'B'], icon: 'utility:contract' },
    { key: 'dd',    name: 'Due Diligence', letters: ['C', 'D', 'E', 'F', 'G', 'H', 'H2'], icon: 'utility:search' },
    { key: 'close', name: 'Closing',       letters: ['I'], icon: 'utility:money' },
    { key: 'post',  name: 'Post Closing',  letters: ['J'], icon: 'utility:success' }
];
const PHASE_BY_LETTER = {};
PHASES.forEach((p) => p.letters.forEach((l) => { PHASE_BY_LETTER[l] = p.key; }));

export default class TransactionPhaseCards extends LightningElement {
    @api recordId;
    _data = [];

    @wire(getTaskGroups, { transactionId: '$recordId' })
    wired({ data }) {
        if (data) {
            this._data = data;
        }
    }

    // One card per phase: complete/total progress, green once every task in the phase is done.
    get cards() {
        const acc = {
            open: { c: 0, t: 0 },
            dd: { c: 0, t: 0 },
            close: { c: 0, t: 0 },
            post: { c: 0, t: 0 }
        };
        this._data.forEach((g) => {
            const pk = PHASE_BY_LETTER[g.letter];
            if (pk && acc[pk]) {
                acc[pk].c += g.complete || 0;
                acc[pk].t += g.total || 0;
            }
        });
        return PHASES.map((p) => {
            const { c, t } = acc[p.key];
            const done = t > 0 && c >= t;
            return {
                key: p.key,
                label: p.name,
                value: `${c} / ${t}`,
                iconName: p.icon,
                iconColor: done ? '#2e7d32' : '#1565c0',
                done
            };
        });
    }
}