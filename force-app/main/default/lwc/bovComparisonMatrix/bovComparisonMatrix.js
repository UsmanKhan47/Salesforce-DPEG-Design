import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { formatMillions, brokerOptionLabel } from 'c/utils';
import BovAddResponseModal from 'c/bovAddResponseModal';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

const SELECTED_BAR = '#2e7d32';
const BACKUP_BAR = '#2BAFAC';
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

/**
 * ⚠ THE OPTION-LABEL FUNCTION MOVED TO `c/utils` ON 2026-08-21 AND ITS REASONING MOVED WITH IT.
 * It used to be a module-local `optionLabel` const here, with a long header explaining why it names
 * the firm, the contact, the amount, the score and the auto-number (this org has six duplicated
 * broker Contacts and seven non-brokers on the Broker record type). Read
 * `c/utils`'s `brokerOptionLabel` before shortening it.
 *
 * 🔴 WHY IT MOVED: `c/brokerListing` now opens the SAME `c/bovReplaceBrokerModal` from the Active
 * Listing stage, and the modal's contract is that it does no formatting *"so the modal and the
 * matrix behind it cannot disagree about the same broker's numbers"*. A second copy of the label
 * rule in that component would have reintroduced precisely that disagreement.
 */

const COLUMNS = [
    { label: 'Broker Firm', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'brokerFirm' }, target: '_self' } },
    { label: 'Contact', fieldName: 'contactName', type: 'text' },
    { label: 'Valuation', fieldName: 'bovAmountLabel', type: 'text' },
    { label: 'Days to Mkt', fieldName: 'daysLabel', type: 'text' },
    { label: 'Cap Rate', fieldName: 'capRateLabel', type: 'text' },
    {
        label: 'Score', fieldName: 'scoreText', type: 'progress',
        typeAttributes: {
            wrapStyle: 'display:flex;align-items:center;gap:10px;min-width:140px',
            trackStyle: 'width:90px;height:6px;background:#eef1f4;border-radius:4px;overflow:hidden',
            barStyle: { fieldName: 'scoreBar' },
            numStyle: 'font-weight:700;color:#181818;font-variant-numeric:tabular-nums',
            text: { fieldName: 'scoreText' }
        }
    },
    { label: 'Status', fieldName: 'status', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'statusWrap' }, dotStyle: { fieldName: 'statusDot' } } }
];

/**
 * c-bov-comparison-matrix — the BOV Outreach card on the Disposition record page.
 *
 * ── 🔴 THE WIRE IS HELD AS A WHOLE RESULT, NOT DESTRUCTURED ─────────────────
 * `wiredSubmissions(result)` keeps `result` in `_wired` because `refreshApex` REQUIRES the
 * un-destructured wire result object — it has no way to re-provision a wire from a `{ data, error }`
 * pair. This shape is load-bearing for EVERY header action below — add-response, select-broker and
 * replace-broker each end in `refreshApex(this._wired)` — and a "tidying" edit back to
 * `wired({ data, error })` compiles, passes every render test, and silently turns those refreshes
 * into no-ops, leaving the matrix stale until a page reload.
 *
 * ── 🔴 NO HEADER ACTION NAVIGATES (2026-08-21) ──────────────────────────────
 * All of them open a `LightningModal` over the disposition page and refresh this wire in place.
 * `NavigationMixin` survives on this class for ONE reason only: the "View All" footer link, which
 * genuinely is a page transition. See `handleAddResponse` for the UAT bug that made this the rule
 * rather than a preference.
 *
 * ── 🔴 TWO BROKER BUTTONS, ONE MECHANISM (2026-08-21) ───────────────────────
 * "Select Broker" (`canSelectBroker`) and "Replace Broker" (`canReplaceBroker`) are mutually
 * exclusive by construction — the second getter is the first's negation — and BOTH open
 * `c/bovReplaceBrokerModal` and reach `BovSubmissionService.replaceSelectedBroker`. There is no
 * appoint-only server path and there must not be one; the reasoning is in that service's javadoc.
 *
 * ── ⚠ AND A THIRD BUTTON EXISTS OFF THIS COMPONENT, ON THE SAME MECHANISM (2026-08-21) ──────
 * `c/brokerListing` carries a Replace Broker button beside its traction badge. It is NOT a
 * duplicate of the one above and it did not fork anything: `dispositionMain.html` renders this
 * matrix under `if:true={isBovOutreach}` and the listing cluster under `if:true={isActiveListing}`
 * — MUTUALLY EXCLUSIVE — so the button above is unreachable at Active Listing, which is the only
 * stage the traction ladder operates in. That component opens this same modal bundle and calls this
 * same Apex method. 🔴 DO NOT "CONSOLIDATE" BY GIVING EITHER COMPONENT ITS OWN SERVER PATH: the
 * four invariants (single-Selected exclusivity, approval revocation, the savepoint, the
 * `BOV_Broker_Change__c` history row) live in `BovSubmissionService` exactly once.
 */
export default class BovComparisonMatrix extends NavigationMixin(LightningElement) {
    @api recordId;
    columns = COLUMNS;
    _wired;
    _data;
    loadError;
    listUrl = '#';

    @wire(getSubmissions, { dispositionId: '$recordId' })
    wiredSubmissions(result) {
        this._wired = result;
        const { data, error } = result;
        if (data) {
            this._data = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = 'Couldn\'t load BOV submissions.';
            this._data = [];
        }
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'BOV_Submission__c', actionName: 'list' }
        };
    }

    get count() {
        return this._data ? this._data.length : 0;
    }

    get rows() {
        if (!this._data) return [];
        return this._data.map((r) => {
            const selected = !!r.isSelected;
            const score = r.bovScore;
            return {
                id: r.id,
                recordUrl: `/lightning/r/BOV_Submission__c/${r.id}/view`,
                brokerFirm: r.brokerFirm || '—',
                contactName: r.contactName || '—',
                bovAmountLabel: formatMillions(r.bovAmount),
                daysLabel: r.daysToMarket != null ? r.daysToMarket + 'd' : '—',
                capRateLabel: r.capRate != null ? parseFloat(r.capRate).toFixed(2) + '%' : '—',
                scoreText: score != null ? String(score) : '—',
                scoreBar: score != null
                    ? `width:${Math.min(100, score)}%;height:100%;background:${selected ? SELECTED_BAR : BACKUP_BAR};border-radius:4px`
                    : 'width:0%;height:100%',
                status: selected ? 'Selected' : 'Backup',
                statusWrap: selected ? pillWrap('#e9f5ec') : pillWrap('#e8f4f3'),
                statusDot: selected ? pillDot('#3fae5e') : pillDot('#2BAFAC')
            };
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Header actions
    // ─────────────────────────────────────────────────────────────────────────

    /** The currently Selected submission, or undefined. `isSelected` is BovController's DTO name. */
    get _selected() {
        return (this._data || []).find((r) => r.isSelected === true);
    }

    /**
     * "Replace Broker" renders only when there is something to replace.
     *
     * ⚠ THE TEST IS "SOME ROW IS SELECTED", NOT "EXACTLY ONE ROW IS SELECTED", and that is a
     * deliberate narrowing of the design wording. Exclusivity is a SERVER invariant —
     * `BovSubmissionService` demotes the incumbent in the same transaction it promotes the
     * successor — so a second Selected row would be a data defect, and hiding the very button that
     * repairs it is the wrong response to one.
     */
    get canReplaceBroker() {
        return this._selected !== undefined;
    }

    /**
     * "Select Broker" — the FIRST appointment on this disposition (2026-08-21).
     *
     * 🔴 EXACTLY ONE OF THE TWO HEADER BUTTONS EVER RENDERS, and this getter is what makes that
     * true: it is `canReplaceBroker`'s negation, so it inherits that getter's deliberate
     * "SOME row is Selected" test rather than an "exactly one" test. A disposition that has somehow
     * acquired two Selected rows therefore shows REPLACE — the button that repairs it — and not
     * this one.
     *
     * ⚠ `count > 0` IS AN ADDITION TO THE DESIGN'S WORDING AND IS NOT COSMETIC. `_selected` is
     * `undefined` before the wire has emitted anything and on a disposition with no submissions at
     * all, so the negation alone would render "Select Broker" on an empty matrix — opening a modal
     * whose only content is its own empty state. Neither button renders until there is something to
     * appoint. This also covers the wire's ERROR branch, which sets `_data = []`.
     *
     * ⚠ `c/bovAddResponseModal` defaults every new submission to `Backup` precisely so that
     * appointment goes through a deliberate path. THIS is that path — do not add a "make this one
     * Selected" shortcut to the add-response form.
     */
    get canSelectBroker() {
        return this.count > 0 && this._selected === undefined;
    }

    /**
     * The appointable submissions as ready-made radio options. Composed HERE, from the same payload
     * that draws the rows above, so the modal cannot show a different valuation for the same broker
     * than the matrix behind it does.
     *
     * ⚠ THE `isSelected !== true` FILTER SERVES BOTH BUTTONS WITHOUT A BRANCH. On a replace it
     * excludes the incumbent (promoting a broker to itself is not an operation, and the server
     * refuses it). On a first appointment nothing is Selected, so it excludes nothing — every
     * submission is offered, which is exactly right. The name kept its `_backup` prefix because
     * that is what the modal's `@api backupOptions` is called; both are about status, not intent.
     */
    get _backupOptions() {
        return (this._data || [])
            .filter((r) => r.isSelected !== true)
            .map((r) => ({ label: brokerOptionLabel(r), value: r.id }));
    }

    /**
     * "Add Broker Response" — opens `c/bovAddResponseModal` over this page and, on success,
     * refreshes THIS component's wire.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THIS USED TO NAVIGATE, AND THAT WAS THE BUG. DO NOT PUT IT BACK.
     * ══════════════════════════════════════════════════════════════════════════════════════
     * Until 2026-08-21 this method called
     *
     *     this[NavigationMixin.Navigate]({ type: 'standard__objectPage',
     *         attributes: { objectApiName: 'BOV_Submission__c', actionName: 'new' },
     *         state: { defaultFieldValues: encodeDefaultFieldValues({ Disposition__c: … }) } });
     *
     * The platform's post-save behaviour for a record created through `actionName: 'new'` is to
     * NAVIGATE TO THE NEW RECORD, so saving a response threw the user off the disposition they
     * were working on and onto a BOV Submission detail page. Reported in UAT as "once we save
     * broker response it redirects to that record page instead of staying on the same page".
     *
     * ⚠ THAT IS NOT A BUG IN THE CALL — IT IS WHAT `actionName: 'new'` DOES, and no state
     * parameter on `NavigationMixin` turns it off. `navigationLocation` belongs to the Aura
     * `force:createRecord` event, not here; `state.backgroundContext` at best swaps one full page
     * transition for another and would still rebuild this matrix from a page load rather than
     * refresh it in place. The only fix is to stop navigating.
     *
     * The modal is `await`ed for the same reason the replace flow is — see `handleReplaceBroker`
     * below: `LightningModal.open()` renders into the PLATFORM'S modal layer, so the dialog
     * shares no ancestor with this component and a bubbling `CustomEvent` has no path back here.
     * The promise IS the channel.
     */
    async handleAddResponse() {
        let result;
        try {
            result = await BovAddResponseModal.open({
                size: 'medium',
                label: 'Add Broker Response',
                description:
                    'Log a broker opinion of value against this disposition without leaving the page.',
                dispositionId: this.recordId
            });
        } catch (error) {
            this._toast(
                'Could not open the response dialog',
                (error && error.body && error.body.message) ||
                    'The add-response dialog could not be opened.',
                'error'
            );
            return;
        }

        // Cancelled or dismissed — nothing changed, so say nothing.
        // ⚠ A dismissed LightningModal resolves `undefined`, and the repo's Jest stub for it
        // resolves `null` (CustomEvent coerces an absent `detail` to null). Both are falsy and
        // both must take this branch.
        if (!result || !result.recordId) {
            return;
        }

        this._toast(
            'Broker response logged',
            result.name
                ? `${result.name} was added to this disposition.`
                : 'The response was added to this disposition.',
            'success'
        );
        // The record was created by a form this cacheable wire knows nothing about, so LDS has no
        // idea the submission list changed. Without this the matrix keeps showing the old set —
        // and the whole point of the rework is that the user is still looking at it.
        refreshApex(this._wired);
    }

    /**
     * "Replace Broker" — swap the appointed broker for one of the backups.
     *
     * 🔴 ONE SERVER MECHANISM, TWO CLIENT ENTRY POINTS. This and `handleSelectBroker` open the SAME
     * modal bundle, which calls the SAME Apex method (`BovController.replaceSelectedBroker` ->
     * `BovSubmissionService.replaceSelectedBroker`). They differ ONLY in the props below and in the
     * toast they raise. Do not fork either half: a second modal bundle would have to duplicate the
     * `getPicklistValues` sourcing, the block-don't-degrade rule on a failed picklist read, the
     * "the returned message is the product, not a receipt" contract and the stay-open-on-failure
     * behaviour, and a second Apex path would duplicate four invariants (exclusivity, approval
     * revocation, the savepoint, the history row).
     */
    async handleReplaceBroker() {
        await this._openBrokerModal({
            label: 'Replace Selected Broker',
            description:
                'Promote a backup BOV submission to Selected and demote the current broker.',
            isFirstAppointment: false,
            currentBroker: this._selected && this._selected.brokerFirm,
            openFailureTitle: 'Could not open the replace dialog',
            openFailureMessage: 'The replace-broker dialog could not be opened.',
            successTitle: 'Broker replaced',
            successVariant: 'warning'
        });
    }

    /**
     * "Select Broker" — the FIRST appointment on a disposition that has none (2026-08-21).
     *
     * ⚠ IT DOES NOT ANNOUNCE THE OUTCOME ITSELF. The toast TITLE says "Broker appointed" because
     * that is what the user just asked for, but the toast BODY is the server's returned sentence
     * verbatim — and the server chooses between "Broker appointed…" and "Broker replaced…" from
     * what it actually did inside the transaction. So if a colleague appointed a broker between
     * this component's last wire emit and this click, the body tells the truth even though the
     * title reflects the intent. Do not "fix" that by re-authoring the body here; see
     * `c/bovReplaceBrokerModal`'s header.
     *
     * ⚠ NO `currentBroker` PROP — there is no incumbent, which is the whole premise of the button.
     * The modal's `incumbentLabel` fallback is never reached on this path because the
     * first-appointment copy does not mention an incumbent at all.
     */
    async handleSelectBroker() {
        await this._openBrokerModal({
            label: 'Select Broker',
            description:
                'Appoint one of this disposition\'s BOV responses as the selected broker.',
            isFirstAppointment: true,
            currentBroker: undefined,
            openFailureTitle: 'Could not open the select dialog',
            openFailureMessage: 'The select-broker dialog could not be opened.',
            successTitle: 'Broker appointed',
            successVariant: 'success'
        });
    }

    /**
     * The one implementation behind both header buttons.
     *
     * 🔴 THE MODAL CANNOT REACH THIS COMPONENT WITH A BUBBLING DOM EVENT, so it does not try.
     * `LightningModal.open()` renders into the PLATFORM'S modal layer, not into this component's
     * template, so the modal shares no ancestor with the matrix and a `CustomEvent` — however
     * composed — has no path back here. The promise returned by `open()` is the channel, and this
     * component awaiting it is what keeps the wire's owner and its refresher the same object.
     *
     * 🔴 THE TOAST IS STICKY ON BOTH PATHS. The service's returned text carries "must be approved
     * before the sale can proceed" either way — `Approval_Status__c` is cleared on the challenger
     * whether or not there was an incumbent — and that is a consequence the user has to act on. An
     * auto-dismissing toast is exactly how it gets missed, which is why `mode` is passed
     * explicitly here rather than left to `_toast`'s variant-derived default (that default would
     * make the appointment's `success` variant dismissable).
     */
    async _openBrokerModal(config) {
        let result;
        try {
            result = await BovReplaceBrokerModal.open({
                size: 'small',
                label: config.label,
                description: config.description,
                dispositionId: this.recordId,
                backupOptions: this._backupOptions,
                currentBroker: config.currentBroker,
                isFirstAppointment: config.isFirstAppointment
            });
        } catch (error) {
            this._toast(
                config.openFailureTitle,
                (error && error.body && error.body.message) ||
                    config.openFailureMessage,
                'error'
            );
            return;
        }

        // Cancelled or dismissed — nothing changed, so say nothing.
        if (!result || !result.message) {
            return;
        }
        this._toast(
            config.successTitle,
            result.message,
            config.successVariant,
            'sticky'
        );
        // The swap is imperative Apex DML on records this cacheable wire already holds, so LDS has
        // no idea they changed. Without this the matrix keeps showing the old Selected broker —
        // and, on a first appointment, keeps offering "Select Broker" for a broker already chosen.
        refreshApex(this._wired);
    }

    /**
     * ⚠ `mode` IS OPTIONAL AND ITS DEFAULT IS THE ORIGINAL EXPRESSION, unchanged, so the
     * add-response call sites below behave exactly as they did. It exists because ONE caller needs
     * a `success` variant that does NOT auto-dismiss — see `_openBrokerModal`.
     */
    _toast(title, message, variant, mode) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant,
                mode: mode || (variant === 'success' ? 'dismissable' : 'sticky')
            })
        );
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
