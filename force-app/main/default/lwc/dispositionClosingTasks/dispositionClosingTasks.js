import { LightningElement, api } from 'lwc';
import getClosingTasks from '@salesforce/apex/DispositionTaskController.getClosingTasks';
import setTaskDone from '@salesforce/apex/DispositionTaskController.setTaskDone';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class DispositionClosingTasks extends LightningElement {
    @api recordId;
    _tasks = [];

    connectedCallback() {
        this.load();
    }

    load() {
        return getClosingTasks({ dispositionId: this.recordId })
            .then((data) => { this._tasks = data || []; })
            .catch(() => { this._tasks = []; });
    }

    get rows() {
        return this._tasks.map((t) => ({
            id: t.id,
            subject: t.subject,
            done: t.done,
            rowClass: t.done ? 'task-row task-row--done' : 'task-row',
            metaLabel: t.done && t.completedDate ? 'Completed ' + this._fmt(t.completedDate) : ''
        }));
    }

    get completeCount() {
        return this._tasks.filter((t) => t.done).length;
    }

    get total() {
        return this._tasks.length;
    }

    get badgeLabel() {
        return `${this.completeCount}/${this.total} complete`;
    }

    get badgeStyle() {
        return this.total > 0 && this.completeCount === this.total
            ? 'background:#e6f4ea;color:#2e7d32'
            : 'background:#fef3c7;color:#92400e';
    }

    handleToggle(event) {
        const taskId = event.target.dataset.id;
        const done = event.target.checked;
        setTaskDone({ taskId, done }).then(() => this.load());
    }

    _fmt(dt) {
        const d = new Date(dt);
        if (isNaN(d.getTime())) {
            return '';
        }
        return MONTHS[d.getMonth()] + ' ' + d.getDate() + ', ' + d.getFullYear();
    }
}
