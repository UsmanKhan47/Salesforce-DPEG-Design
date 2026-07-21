import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getClosingTasks from '@salesforce/apex/DispositionTaskController.getClosingTasks';
import setTaskDone from '@salesforce/apex/DispositionTaskController.setTaskDone';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class DispositionClosingTasks extends LightningElement {
    @api recordId;
    _tasks = [];
    loadError;

    connectedCallback() {
        this.load();
    }

    load() {
        return getClosingTasks({ dispositionId: this.recordId })
            .then((data) => {
                this._tasks = data || [];
                this.loadError = undefined;
            })
            .catch((error) => {
                // A failed load must surface as an explicit error state — never
                // masquerade as a legitimately empty checklist (§5).
                this._tasks = [];
                this.loadError = this.errorText(error);
            });
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

    get hasLoadError() {
        return !!this.loadError;
    }

    handleToggle(event) {
        const taskId = event.target.dataset.id;
        const done = event.target.checked;
        setTaskDone({ taskId, done })
            .then(() => this.load())
            .catch((error) => {
                // Surface the write failure to the user and revert the optimistic
                // checkbox by reloading the true persisted state from the server.
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not update the task',
                        message: this.errorText(error),
                        variant: 'error'
                    })
                );
                return this.load();
            });
    }

    errorText(error) {
        return (error && error.body && error.body.message) || 'Unexpected error';
    }

    _fmt(dt) {
        const d = new Date(dt);
        if (isNaN(d.getTime())) {
            return '';
        }
        return MONTHS[d.getMonth()] + ' ' + d.getDate() + ', ' + d.getFullYear();
    }
}