import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { brokerOptionLabel } from 'c/utils';
import BovAddResponseModal from 'c/bovAddResponseModal';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

/*
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 THERE IS NO SECOND APEX IMPORT HERE, AND THAT IS THE AGREED CONTRACT.
 * ══════════════════════════════════════════════════════════════════════════════
 * An earlier draft of this file imported and called
 * `BovController.replacePreferredBroker(dispositionId, newSubmissionId,
 * outgoingSubmissionId)` after the replacement dialog closed. That method DOES
 * NOT EXIST and must not be added: the retirement is implemented TRIGGER-SIDE, in
 * `BovPreferredBrokerService.retireReplacedPreferred`, called from
 * `BovSubmissionTriggerHandler.afterInsert` (and `afterUpdate`).
 *
 * WHAT THAT MEANS FOR THIS COMPONENT, precisely:
 *   - The client's ENTIRE job on the replacement path is to create a second row
 *     with `Is_Preferred_Broker__c = true`. The dialog already does that.
 *   - The server then keeps the NEWEST preferred row, writes one
 *     `BOV_Broker_Change__c` history row for the outgoing one and deletes it —
 *     inside the same transaction as the insert.
 *   - So the operation is ATOMIC. There is no window in which the sale carries
 *     two preferred brokers, and no failure mode where the new row is created but
 *     the old one survives: a refused retirement throws out of the after-insert
 *     context and rolls the insert back, which `lightning-record-edit-form`
 *     surfaces INSIDE the still-open dialog through `<lightning-messages>`.
 *   - Consequently this component must NOT toast "replaced" from a `catch` and
 *     must NOT try to detect a partial outcome. There isn't one.
 *
 * ⚠ DO NOT ADD AN IMPERATIVE CALL "TO BE EXPLICIT". It would be a SECOND writer
 * of an invariant that lives in one place, and on the delete path it would race
 * the trigger that has already done the work.
 */

/**
 * The panel's own header. Deliberately NOT "Broker Selection": that is a literal
 * value of `Disposition__c.Disposition_Stage__c`, and a card headed with the name
 * of a DIFFERENT stage than the one it renders on (BOV Outreach) reads as a bug.
 */
const PANEL_TITLE = 'Brokers';

/**
 * The replacement toast's body, keyed on the outgoing broker.
 *
 * 🔴 CLIENT-AUTHORED HERE, UNLIKE THE BACKUP-PICKER PATH, AND THE DIFFERENCE IS
 * NOT AN INCONSISTENCY. `BovSubmissionService.replaceSelectedBroker` RETURNS a
 * sentence, so that path hands the server's own words through untouched — the
 * server is the only party that knows whether it appointed or replaced. The
 * preferred-broker retirement happens in an AFTER-INSERT TRIGGER, which returns
 * nothing to a client at all, so there is no server sentence to pass through.
 *
 * ⚠ IT ONLY CLAIMS WHAT THE TRANSACTION GUARANTEES. The retirement and the
 * history row are written in the same transaction as the insert, so if the user
 * is reading this toast at all, both happened. The wording must not drift into
 * claiming anything conditional on a second call — there is no second call.
 */
const replacedMessage = (outgoing) =>
    `${outgoing} was replaced as this disposition's preferred broker. The change is recorded in the broker change history.`;

/**
 * c-bov-broker-panel — the BOV Outreach broker workspace.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS BUNDLE EXISTS, AND WHY IT OWNS THE DATA.
 * ══════════════════════════════════════════════════════════════════════════════
 * `dispositionMain.html` used to mount `c/bovComparisonMatrix` TWICE as siblings
 * and the three broker buttons lived on the matrix instance's own card header.
 * The user asked for one header and one action bar above both cards. That is a
 * composition change in markup — `c/bovComparisonMatrix` is `isExposed=false`
 * with no `targetConfigs`, so it is not placeable in App Builder and never was.
 *
 * ⚠ THIS COMPONENT WIRES `getSubmissions` ITSELF, AND THAT IS NOT A THIRD SERVER
 * ROUND TRIP. BOTH wires (this one and the matrix child's) call the SAME
 * `cacheable=true` method with the SAME parameter, so LDS serves them from ONE
 * cache entry — the property `dispositionMain.html` already relied on and
 * documented when the two children were siblings.
 *
 * 🔴 IT HAS TO HOLD THE DATA, BECAUSE THE BUTTONS' RULES ARE DATA RULES. "Replace
 * Broker" renders only when some row is Selected; "Add Preferred Broker" hides
 * once one exists; and "Replace Broker" now BRANCHES on whether a preferred
 * broker exists. Pushing those facts up from the children through events would
 * make the buttons' correctness depend on render ordering.
 * ⚠ AND IT IS WHAT LETS THE PREFERRED PANEL BE GATED FROM HERE — see the template
 * for why that is the fix to the accepted `gap` defect, not a refactor.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 THE WIRE IS HELD AS A WHOLE RESULT, NOT DESTRUCTURED.
 * ══════════════════════════════════════════════════════════════════════════════
 * `wiredSubmissions(result)` keeps `result` in `_wired` because `refreshApex`
 * REQUIRES the un-destructured wire result object — it has no way to re-provision
 * a wire from a `{ data, error }` pair. Every action below ends in a refresh, and
 * a "tidying" edit back to `wired({ data, error })` compiles, passes every render
 * test, and silently turns those refreshes into no-ops.
 * ⚠ THE MATRIX CHILD IS REFRESHED EXPLICITLY TOO (`_refreshAll` below). Invalidating
 * the shared LDS cache entry SHOULD re-provision it, but that is an assumption
 * about LDS internals that no Jest stub models; calling its
 * `@api refreshData()` makes the outcome true by construction and observable.
 * ⚠ `c/bovPreferredBroker` HAS NO WIRE AND SO HAS NO `refreshData()`. It renders
 * `preferredBrokerFirm`, derived from this component's own `_data`, so the
 * `refreshApex` above IS its refresh path.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 NOTHING HERE NAVIGATES.
 * ══════════════════════════════════════════════════════════════════════════════
 * Every action opens a `LightningModal` over the disposition page and refreshes
 * in place. That is the 2026-08-21 UAT fix ("once we save broker response it
 * redirects to that record page instead of staying on the same page") and it is
 * the reason this class does NOT mix in `NavigationMixin` at all. The matrix child
 * keeps it for its own "View All" footer link, which genuinely is a page
 * transition.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 THE SERVER CONTRACT THIS COMPONENT DEPENDS ON.
 * ══════════════════════════════════════════════════════════════════════════════
 *   - `BovController.getSubmissions(dispositionId)` — existing, unchanged.
 *   - `BovController.replaceSelectedBroker(...)` — existing; called by
 *     `c/bovReplaceBrokerModal`, not from here.
 *   - 🔴 NOTHING ELSE. The preferred-broker REPLACEMENT is server-side only:
 *     `BovSubmissionTriggerHandler.afterInsert` ->
 *     `BovPreferredBrokerService.retireReplacedPreferred`, triggered by the
 *     flagged row the dialog inserts. This component calls no Apex for it, which
 *     is also why it has no undeployed Apex dependency: it imports exactly one
 *     method, and that method already exists.
 *
 * ⚠ THE CLIENT'S HALF OF THAT CONTRACT IS ONE FACT, AND IT IS EASY TO BREAK
 * SILENTLY: the replacement dialog must be opened with `isPreferred: true`. The
 * flag is what the trigger keys on. Opened without it the dialog creates an
 * ordinary unflagged response under a "Replace Preferred Broker" header, nothing
 * is retired, nothing errors, and the outgoing broker stays appointed.
 */
export default class BovBrokerPanel extends LightningElement {
    @api recordId;

    _wired;
    _data;

    @wire(getSubmissions, { dispositionId: '$recordId' })
    wiredSubmissions(result) {
        this._wired = result;
        const { data } = result;
        if (data) {
            this._data = data;
        } else if (result.error) {
            // ⚠ NO ERROR BANNER HERE, DELIBERATELY. The matrix child renders its
            // own — it is the card the user is looking at — and two banners for
            // one failed read is noise. What this branch DOES do is empty the
            // button rules, so "Replace Broker" cannot be offered against rows
            // this component could not read.
            this._data = [];
        }
    }

    get panelTitle() {
        return PANEL_TITLE;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Facts about the disposition's brokers (all derived from the ONE wire)
    // ─────────────────────────────────────────────────────────────────────────

    get _all() {
        return this._data || [];
    }

    /**
     * The submission flagged preferred, or `undefined`.
     *
     * ⚠ `=== true`, NOT TRUTHINESS. `isPreferred` is a `Boolean` on
     * `BovController.BovRow`, so an Apex `null` arrives as JS `null` — not
     * `false`. Under `=== true` a null row can never be treated as the preferred
     * broker, which is the safe side for a flag whose whole meaning is "flagged".
     */
    get _preferredRow() {
        return this._all.find((r) => r.isPreferred === true);
    }

    get hasPreferredBroker() {
        return this._preferredRow !== undefined;
    }

    /**
     * The preferred broker's firm name, handed to `c/bovPreferredBroker`.
     *
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 RETURNS `''`, NEVER `undefined` OR `null`.
     * ══════════════════════════════════════════════════════════════════════════
     * This value is bound to an attribute on a custom element. A getter bound to
     * an attribute is written UNCONDITIONALLY, so `undefined` is capable of
     * reaching the DOM as the literal string "undefined" — measured in this repo
     * on a different component, and the same reason `outgoingPreferredLabel`
     * below returns `''`. Returning a string in every branch removes the
     * question rather than relying on the child to answer it.
     *
     * ⚠ THE *USER-FACING* FALLBACK IS THE CHILD'S, NOT THIS ONE. `''` here means
     * "there is no firm name"; `c/bovPreferredBroker.displayName` turns that into
     * "Unnamed broker". Splitting it that way keeps the child safe to mount from
     * anywhere instead of making every future caller remember the placeholder —
     * and `Broker_Firm__c` is legitimately nullable, so this is a live path, not
     * a defensive one.
     */
    get preferredBrokerFirm() {
        const row = this._preferredRow;
        return (row && row.brokerFirm) || '';
    }

    /**
     * The currently Selected submission, or `undefined`.
     *
     * 🔴 READS EVERY ROW, INCLUDING PREFERRED ONES. A preferred broker IS the
     * appointed broker under the 2026-08-24 decision — it holds the single
     * `Selected` slot and the scored winner is demoted — so narrowing this to the
     * scored rows would make `canReplaceBroker` false in exactly the steady state
     * where replacing matters, and the button would silently vanish.
     */
    get _selected() {
        return this._all.find((r) => r.isSelected === true);
    }

    /**
     * "Replace Broker" renders only when there is something to replace.
     *
     * ⚠ "SOME ROW IS SELECTED", NOT "EXACTLY ONE ROW IS SELECTED". Exclusivity is
     * a SERVER invariant; a second Selected row would be a data defect, and hiding
     * the button that repairs it is the wrong response to one.
     */
    get canReplaceBroker() {
        return this._selected !== undefined;
    }

    /**
     * "Add Preferred Broker" — offered until this disposition HAS one.
     *
     * ⚠ IT DOES NOT DEPEND ON THE ROW COUNT. Adding a preferred broker to an
     * empty disposition is exactly what a user with no responses yet would want to
     * record, so an empty matrix still offers it.
     */
    get canAddPreferredBroker() {
        return !this.hasPreferredBroker;
    }

    /**
     * The appointable submissions as ready-made radio options for the ordinary
     * replace picker.
     *
     * ⚠ ONE FILTER. `isSelected !== true` excludes the incumbent — promoting a
     * broker to itself is not an operation and the server refuses it.
     *
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 A SECOND FILTER (`isPreferred !== true`) WAS WRITTEN HERE AND REMOVED THE
     * SAME DAY, BECAUSE IT WAS PROVABLY DEAD — AND MEASURED TO BE.
     * ══════════════════════════════════════════════════════════════════════════
     * It came across from `c/bovComparisonMatrix`, where it was live: that
     * component filtered preferred rows out of the card it drew, and the picker
     * was built from the same narrowed list.
     *
     * It cannot fire HERE. This getter is read by `_openBrokerModal`, which is
     * reached only from `handleReplaceBroker`'s ELSE branch — i.e. only when
     * `hasPreferredBroker` is false — and `hasPreferredBroker` is derived from
     * this same `_all` with the same `=== true` test, in the same tick. So there
     * is never a preferred row for it to remove.
     *
     * 🔴 IT WAS DELETED RATHER THAN KEPT "DEFENSIVELY" BECAUSE A MUTATION PROVED
     * IT UNFALSIFIABLE: removing the line reddened ZERO tests, and no fixture can
     * be built that reaches it. A line no test can break is not defence, it is a
     * claim nobody can check — and worse here, it encoded a premise that is now
     * FALSE (that the picker can be opened on a sale that has a preferred
     * broker). The live version of that rule is the branch in
     * `handleReplaceBroker`, which IS pinned, in both directions.
     *
     * ⚠ Composed HERE from the same payload that draws the rows, so the modal
     * cannot show a different valuation for the same broker than the card behind
     * it does. That is why `brokerOptionLabel` lives in `c/utils`.
     */
    get _backupOptions() {
        return this._all
            .filter((r) => r.isSelected !== true)
            .map((r) => ({ label: brokerOptionLabel(r), value: r.id }));
    }

    /**
     * The outgoing preferred broker, as a read-only identity label for the
     * replacement dialog.
     *
     * 🔴 NOT `brokerOptionLabel`, AND THAT IS DELIBERATE. That helper appends the
     * BOV amount, the score and the auto-number because it labels OPTIONS a user
     * must tell apart. A preferred broker is a thin row — typically no amount and
     * no score — so the same helper renders "Firm — Contact · — · Score — ·
     * BOV-0003" for the one broker on screen: three placeholders and an
     * auto-number, in a field whose only job is to say who is being replaced.
     *
     * ⚠ RETURNS `''`, NEVER `undefined`. This value is bound to an attribute on a
     * custom element, and a getter bound to an attribute is written
     * UNCONDITIONALLY — `undefined` renders the literal string "undefined" in the
     * dialog. Measured in this repo.
     */
    get outgoingPreferredLabel() {
        const row = this._preferredRow;
        if (!row) {
            return '';
        }
        return (
            [row.brokerFirm, row.contactName].filter(Boolean).join(' — ') ||
            'Unnamed broker'
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Header actions
    // ─────────────────────────────────────────────────────────────────────────

    /** "Add Broker Response" — logs an ordinary BOV response in place. */
    async handleAddResponse() {
        await this._openAddModal({
            label: 'Add Broker Response',
            description:
                'Log a broker opinion of value against this disposition without leaving the page.',
            isPreferred: false,
            openFailureTitle: 'Could not open the response dialog',
            openFailureMessage: 'The add-response dialog could not be opened.',
            successTitle: 'Broker response logged',
            successNamed: (name) => `${name} was added to this disposition.`,
            successUnnamed: 'The response was added to this disposition.'
        });
    }

    /**
     * "Add Preferred Broker" — records a broker DPEG would like to use on this
     * sale, ahead of (or instead of) a quoted opinion of value.
     *
     * 🔴 THE SAME MODAL BUNDLE AS "ADD BROKER RESPONSE", DIFFERING ONLY IN
     * `isPreferred`. The field set, both submit paths, the validation-rule error
     * surface and the create-only contract are shared rather than forked.
     *
     * ⚠ WHAT THIS DOES *NOT* DO: SET THE STATUS. The row is created at the
     * picklist default (`Backup`) and `BovAutoSelectionService` promotes it. The
     * dialog cannot write `'Selected'` — `BovSubmissionSelectionGuardService`
     * refuses an insert-as-Selected while a committed Selected sibling exists.
     * Flag is the INPUT, status is the OUTPUT.
     */
    async handleAddPreferredBroker() {
        await this._openAddModal({
            label: 'Add Preferred Broker',
            description:
                'Record a preferred broker for this disposition without leaving the page.',
            isPreferred: true,
            openFailureTitle: 'Could not open the preferred broker dialog',
            openFailureMessage:
                'The add-preferred-broker dialog could not be opened.',
            successTitle: 'Preferred broker added',
            successNamed: (name) =>
                `${name} was added as this disposition's preferred broker.`,
            successUnnamed:
                'The preferred broker was added to this disposition.'
        });
    }

    /**
     * "Replace Broker" — ONE button, TWO destinations (2026-08-24, user decision).
     *
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 THE BRANCH IS ON `hasPreferredBroker`, AND ONLY THE NEW LEG IS NEW.
     * ══════════════════════════════════════════════════════════════════════════
     * WITH a preferred broker: the ordinary picker is the wrong dialog. Its list
     * is the scored BACKUP responses, and swapping a manually-appointed broker for
     * a scored one is not what "replace this preferred broker" means — the
     * successor is usually a broker who has not submitted a BOV at all, and so has
     * no row to pick. This leg therefore opens the ADD PREFERRED BROKER dialog in
     * replacement mode: the outgoing broker is shown read-only and the `Broker__c`
     * lookup is the control that chooses the incoming one.
     *
     * WITHOUT a preferred broker: BYTE-FOR-BYTE THE PATH THAT ALWAYS RAN. Same
     * modal, same config object, same server method. The `if` above it is the only
     * thing between it and the click.
     */
    async handleReplaceBroker() {
        if (this.hasPreferredBroker) {
            await this._openReplacePreferredModal();
            return;
        }
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
     * The replacement leg of "Replace Broker".
     *
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 THE CLIENT CREATES. THE SERVER RETIRES. ONE TRANSACTION, NO SECOND CALL.
     * ══════════════════════════════════════════════════════════════════════════
     * All this method does is open the ADD PREFERRED BROKER dialog in replacement
     * mode. The dialog inserts a second row carrying
     * `Is_Preferred_Broker__c = true`, and `BovSubmissionTriggerHandler.afterInsert`
     * hands that insert to `BovPreferredBrokerService.retireReplacedPreferred`,
     * which keeps the NEWEST preferred row, writes one `BOV_Broker_Change__c`
     * history row for the outgoing one and deletes it.
     *
     * ⚠ THERE IS THEREFORE NO PARTIAL OUTCOME TO HANDLE, AND NO IMPERATIVE APEX
     * CALL HERE. A refused retirement throws out of the after-insert context and
     * ROLLS THE INSERT BACK, which the dialog surfaces through
     * `<lightning-messages>` while staying open. If this component ever reaches
     * the success branch below, both halves happened.
     * 🔴 That is why the failure branch this method used to carry is gone rather
     * than merely unused — see the import block at the top of this file for the
     * draft contract it belonged to, kept so nobody re-derives it.
     *
     * ⚠ THE OUTGOING BROKER IS CAPTURED BEFORE THE AWAIT. After the dialog
     * resolves, this component's wire has not refreshed yet — but capturing it up
     * front makes the toast independent of that timing rather than dependent on
     * it, and it is the same row the dialog was told to display.
     */
    async _openReplacePreferredModal() {
        const outgoing = this.outgoingPreferredLabel;
        let result;
        try {
            result = await BovAddResponseModal.open({
                size: 'medium',
                label: 'Replace Preferred Broker',
                description:
                    'Choose the broker that takes over from the current preferred broker.',
                dispositionId: this.recordId,
                isPreferred: true,
                isReplacement: true,
                outgoingBrokerLabel: outgoing
            });
        } catch (error) {
            this._toast(
                'Could not open the replace dialog',
                (error && error.body && error.body.message) ||
                    'The replace-preferred-broker dialog could not be opened.',
                'error'
            );
            return;
        }

        // Cancelled or dismissed — nothing was created, so the outgoing broker is
        // untouched and there is nothing to say. (A dismissed LightningModal
        // resolves `undefined`; this repo's Jest stub resolves `null`. Both are
        // falsy and both land here.)
        if (!result || !result.recordId) {
            return;
        }

        // 🔴 STICKY, AND `warning`, MATCHING THE BACKUP-PICKER PATH. A broker
        // change on a live sale is a consequence the user has to act on — the
        // outgoing submission is GONE, not archived — and an auto-dismissing
        // toast is exactly how that gets missed.
        this._toast(
            'Preferred broker replaced',
            replacedMessage(outgoing),
            'warning',
            'sticky'
        );
        this._refreshAll();
    }

    /** The one implementation behind both add buttons. */
    async _openAddModal(config) {
        let result;
        try {
            result = await BovAddResponseModal.open({
                size: 'medium',
                label: config.label,
                description: config.description,
                dispositionId: this.recordId,
                isPreferred: config.isPreferred
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

        if (!result || !result.recordId) {
            return;
        }

        this._toast(
            config.successTitle,
            result.name
                ? config.successNamed(result.name)
                : config.successUnnamed,
            'success'
        );
        this._refreshAll();
    }

    /**
     * The ordinary backup-picker swap.
     *
     * 🔴 THE TOAST IS STICKY. The service's returned text carries "must be approved
     * before the sale can proceed" either way, and that is a consequence the user
     * has to act on. An auto-dismissing toast is how it gets missed.
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

        if (!result || !result.message) {
            return;
        }
        this._toast(
            config.successTitle,
            result.message,
            config.successVariant,
            'sticky'
        );
        this._refreshAll();
    }

    /**
     * Re-provision this component's wire AND the matrix child's.
     *
     * ⚠ THE CHILD CALL IS NOT REDUNDANT BELT-AND-BRACES FOR ITS OWN SAKE. Both
     * wires share one LDS cache entry, so invalidating it here *should*
     * re-provision the child — but that is an assumption about LDS internals
     * which no Jest stub models and which nothing on this page would report if it
     * became false. `@api refreshData()` makes it true by construction.
     *
     * 🔴 THERE IS NOTHING TO CALL ON `c/bovPreferredBroker`, AND THAT IS NOT AN
     * OMISSION. It has no wire: it renders `preferredBrokerFirm`, which is
     * derived from THIS component's `_data`, so the `refreshApex` on the line
     * below is already its whole refresh path. It used to be a second
     * `c-bov-comparison-matrix` with a wire of its own, which is why the loop
     * below still reads as though it might match more than one element — it is
     * `querySelectorAll` because the selector is a class of child, not because
     * two are expected.
     */
    _refreshAll() {
        refreshApex(this._wired);
        this.template
            .querySelectorAll('c-bov-comparison-matrix')
            .forEach((child) => {
                if (typeof child.refreshData === 'function') {
                    child.refreshData();
                }
            });
    }

    /**
     * ⚠ `mode` IS OPTIONAL and its default is the original variant-derived
     * expression, so the add call sites behave exactly as they did on the matrix.
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
}
