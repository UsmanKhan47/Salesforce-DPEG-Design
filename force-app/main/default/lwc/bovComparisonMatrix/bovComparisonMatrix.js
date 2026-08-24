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
 * The same columns MINUS Status, for the preferred-broker card (2026-08-24).
 *
 * 🔴 DERIVED, NOT A SECOND HAND-WRITTEN ARRAY. A copied array is a second place to add
 * "Cap Rate" to and forget, and the two cards showing different columns for the same broker is
 * the exact class of disagreement that forced `brokerOptionLabel` out of this file and into
 * `c/utils`. Keyed on `fieldName`, not on the human `label`, so renaming the column header does
 * not silently reinstate the column here.
 *
 * ⚠ WHY STATUS GOES AT ALL: THE PILL IS A CONSTANT ON THAT CARD, so the column carries zero
 * information for the price of a column's width.
 * 🔴 THE DIRECTION OF THE CONSTANT FLIPPED ON 2026-08-24 AND THE CONCLUSION DID NOT — worth
 * recording, because a reader who checks the old reasoning will find it inverted and may assume
 * the decision inverted with it. It first read: *"a preferred broker is never Selected, so the
 * pill would read Backup on every row, forever."* The user then decided a preferred broker IS
 * the appointed broker, so it now reads SELECTED on every row, forever. Constant either way.
 * ⚠ AND IT WOULD BE ACTIVELY MISLEADING TO SHOW IT NOW: the same green "Selected" pill appears
 * in the matrix below to mean "this is the appointed broker among the scored field", and there
 * is exactly one appointed broker across BOTH cards. Two Selected pills on one page, one per
 * card, would read as the duplicate-Selected data defect the whole exclusivity guard exists to
 * prevent.
 */
const PREFERRED_COLUMNS = COLUMNS.filter((c) => c.fieldName !== 'status');

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
 * ── 🔴 RETRACTED 2026-08-24: "TWO BROKER BUTTONS, ONE MECHANISM" IS NO LONGER TRUE ──────────
 * The paragraph that stood here said: *"'Select Broker' (`canSelectBroker`) and 'Replace Broker'
 * (`canReplaceBroker`) are mutually exclusive by construction — the second getter is the first's
 * negation — and BOTH open `c/bovReplaceBrokerModal` and reach
 * `BovSubmissionService.replaceSelectedBroker`."* **THE SELECT BROKER BUTTON WAS DELETED ON
 * 2026-08-24** — button, getter (`canSelectBroker`) and handler (`handleSelectBroker`) — because
 * the FIRST appointment is now made automatically from `BOV_Score__c` on the server. There is no
 * longer a "first appointment" for a human to press.
 *
 * ⚠ THE SENTENCE THE RETRACTED PARAGRAPH ENDED ON IS STILL LIVE AND STILL LOAD-BEARING:
 * there is no appoint-only server path and there must not be one. `Replace Broker` remains the
 * ONE client route into `BovSubmissionService.replaceSelectedBroker` — the deliberate human
 * override the user kept when selection became automatic — and the four invariants that method
 * owns (exclusivity, approval revocation, the savepoint, the `BOV_Broker_Change__c` history row)
 * still live there exactly once.
 *
 * ── 🔴 THREE BUTTONS NOW, AND THE ORDER IS THE USER'S (2026-08-24) ──────────
 * Add Broker Response, Replace Broker, Add Preferred Broker — in that order in the template.
 * "Add Preferred Broker" opens the SAME `c/bovAddResponseModal` bundle as "Add Broker Response",
 * with `isPreferred: true`. It is NOT a second bundle: the field set, both submit paths, the
 * validation-rule error surface and the create-only contract are identical, and forking them
 * would be forking all four.
 *
 * ── 🔴 THIS BUNDLE RENDERS TWICE ON THE PAGE (2026-08-24) ───────────────────
 * `dispositionMain.html` mounts it once with `preferred-only hide-actions` (the "Preferred
 * Broker" card, above) and once bare (the matrix, below). `@api preferredOnly` and
 * `@api hideActions` both default `false`, so the bare instance is unchanged by construction.
 * ⚠ A WRAPPER BUNDLE WAS CONSIDERED AND REJECTED: it would have had to duplicate `COLUMNS`, the
 * `getSubmissions` wire and — decisively — the un-destructured `_wired` invariant above, which
 * is the one thing in this file that fails silently when copied wrong.
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

    /**
     * Renders the PREFERRED-BROKER card instead of the comparison matrix (2026-08-24).
     *
     * Changes four things and nothing else: which rows are shown (`isPreferred === true` instead
     * of `!== true`), the card title, the column set (no Status) and whether the card renders at
     * all (it does not, when there is no preferred broker).
     *
     * ⚠ DEFAULT `false` IS THE WHOLE SAFETY ARGUMENT. Every branch below reads
     * `this.preferredOnly === true`, so the existing bare `<c-bov-comparison-matrix>` tag in
     * `dispositionMain.html` takes the same path it always did.
     */
    @api preferredOnly = false;

    /** Suppresses the entire `slot="actions"` region. Default `false`; see `showActions`. */
    @api hideActions = false;

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

    // ─────────────────────────────────────────────────────────────────────────
    // Which rows this instance is about (2026-08-24)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The subset of the wire payload THIS instance renders.
     *
     * 🔴 ONE WIRE, FILTERED HERE — NOT A SECOND APEX METHOD. `getSubmissions` already returns
     * every submission for the disposition, so both cards are drawn from the SAME payload and
     * cannot disagree about the same broker's numbers. A `preferredOnly` Apex method would cost a
     * second SOQL, a second LDS cache entry, and a second chance to diverge.
     *
     * ⚠ `=== true` / `!== true`, NOT TRUTHINESS. `isPreferred` is a `Boolean` on
     * `BovController.BovRow`, so an Apex `null` arrives as JS `null` — not `false`. Under
     * `!== true` a null lands in the MATRIX, which is the safe side: an unflagged row is an
     * ordinary broker response. Under `=== true` it stays out of the preferred card, so a null
     * can never populate a card whose entire purpose is "this one is flagged".
     */
    get _visible() {
        const all = this._data || [];
        return this.preferredOnly === true
            ? all.filter((r) => r.isPreferred === true)
            : all.filter((r) => r.isPreferred !== true);
    }

    /**
     * Whether ANY submission on this disposition is flagged preferred.
     *
     * ⚠ READS `_data`, NOT `_visible`, AND THAT IS THE POINT. The matrix instance filters
     * preferred rows OUT of `_visible`, so a `_visible`-based test would always be false there —
     * and "Add Preferred Broker" would never hide, which is the one behaviour the user asked for
     * by name.
     */
    get hasPreferredBroker() {
        return (this._data || []).some((r) => r.isPreferred === true);
    }

    /**
     * 🔴 THE PREFERRED CARD DOES NOT RENDER AT ALL WHEN THERE IS NO PREFERRED BROKER.
     * Not an empty card with an empty-state line — nothing. (User decision, 2026-08-24.)
     * The matrix instance is always visible, including on an empty disposition and on the wire's
     * error branch, because its error banner and its "Add Broker Response" button are how the
     * user recovers from both.
     */
    get isVisible() {
        return this.preferredOnly !== true || this.hasPreferredBroker;
    }

    get cardTitle() {
        return this.preferredOnly === true
            ? 'Preferred Broker'
            : `BOV Comparison Matrix (${this.count})`;
    }

    get columns() {
        return this.preferredOnly === true ? PREFERRED_COLUMNS : COLUMNS;
    }

    /** `hideActions` inverted, because a template cannot negate. */
    get showActions() {
        return this.hideActions !== true;
    }

    get count() {
        return this._visible.length;
    }

    get rows() {
        return this._visible.map((r) => {
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

    /**
     * The currently Selected submission, or undefined. `isSelected` is BovController's DTO name.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 RETRACTED IN PLACE 2026-08-24 (LATER THE SAME DAY): THIS READS `_data`, NOT `_visible`.
     * ══════════════════════════════════════════════════════════════════════════════════════
     * It searched `_visible` for a few hours, justified as: *"a preferred row is never Selected,
     * so this is a no-op on the matrix instance; it matters on the PREFERRED instance, where
     * without the narrowing that card would see the matrix's incumbent."*
     *
     * 🔴 THE PREMISE — "a preferred row is never Selected" — IS NOW FALSE BY DESIGN. The user
     * decided a preferred broker BECOMES the appointed broker: it holds the single `Selected`
     * slot and the highest-scoring submission is demoted to `Backup`.
     *
     * ⚠ AND THE NARROWING WOULD HAVE SILENTLY REMOVED THE REPLACE BROKER BUTTON. Under that
     * decision the steady state of a disposition with a preferred broker is: preferred row
     * Selected, EVERY scored row Backup. `_visible` on the matrix instance is exactly the scored
     * rows — so `_selected` would be `undefined`, `canReplaceBroker` would be `false`, and the
     * button would vanish from the only card that has buttons. The appointed broker lives in the
     * preferred card, which by requirement has NO buttons, so there would be NO route anywhere in
     * the UI to replace an appointed broker. Nothing would error; the button would just stop
     * being there.
     *
     * ⚠ THE ORIGINAL WORRY IS REAL BUT HARMLESS. `canReplaceBroker` is indeed `true` on the
     * preferred instance now — and unreachable, because that instance renders with
     * `hideActions`, so the whole action region is absent. `PREFERRED CARD: NO BUTTONS AT ALL`
     * pins it. Guarding a getter that no template on that instance can reach was defence against
     * the wrong thing.
     */
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
     * "Add Preferred Broker" — offered until this disposition HAS one (2026-08-24).
     *
     * 🔴 EXACTLY ONE PREFERRED BROKER PER DISPOSITION (user decision). There is no server-side
     * uniqueness guard on `Is_Preferred_Broker__c` — no validation rule, no trigger — so this
     * getter is currently the ONLY thing enforcing it. Withdrawing the affordance is the honest
     * shape for that: a button that is always offered and sometimes refused teaches the user
     * nothing, and here it would not even be refused.
     *
     * ⚠ IT DOES NOT DEPEND ON `count`, UNLIKE THE BUTTON IT REPLACED. The retracted "Select
     * Broker" getter carried `count > 0` because appointing from an empty list is meaningless.
     * Adding a preferred broker to an empty disposition is the OPPOSITE — it is exactly what a
     * user with no responses yet would want to record — so an empty matrix still offers it.
     *
     * ⚠ Reads `hasPreferredBroker`, which reads `_data`. See that getter for why `_visible` would
     * make this always-true on the matrix instance.
     */
    get canAddPreferredBroker() {
        return !this.hasPreferredBroker;
    }

    /**
     * The appointable submissions as ready-made radio options. Composed HERE, from the same payload
     * that draws the rows above, so the modal cannot show a different valuation for the same broker
     * than the matrix behind it does.
     *
     * ⚠ THE `isSelected !== true` FILTER excludes the incumbent — promoting a broker to itself is
     * not an operation, and the server refuses it. The name kept its `_backup` prefix because that
     * is what the modal's `@api backupOptions` is called; both are about status, not intent.
     *
     * 🔴 IT READS `_visible`, SO PREFERRED ROWS ARE EXCLUDED — AND THE REASON CHANGED THE SAME
     * DAY IT WAS WRITTEN (2026-08-24). RETRACTED IN PLACE; the line is unchanged, its
     * justification is not.
     *
     * THE ORIGINAL REASON, NOW SPENT: *"a preferred submission offered here would be appointed,
     * would enter Broker_Finalize_Approval and would put a broker with NO BOV amount in front of
     * the principals — a server-side hazard closed on the client."* That was written while a
     * preferred row was forbidden from being Selected. The user has since decided the opposite:
     * a preferred broker IS the appointed broker.
     *
     * 🔴 THE REASON THAT APPLIES NOW: THE PREFERRED ROW ALREADY HOLDS THE SELECTED SLOT, so it is
     * the INCUMBENT — and the incumbent is exactly what this filter has always excluded.
     * Promoting a broker to itself is not an operation and
     * `BovSubmissionService.replaceSelectedBroker` refuses it. The exclusion is therefore no
     * longer a mitigation for a missing server guard; it is the ordinary, correct behaviour of a
     * replace picker, arrived at by the `_visible` filter rather than by the `isSelected !== true`
     * one. Both filters now point the same way for this row, which is why the picker keeps
     * behaving sensibly without a branch.
     *
     * ⚠ AND THE SERVER-SIDE HAZARD IS GONE WITH THE PREMISE, NOT MERELY UNGUARDED. There is no
     * longer anything wrong with a preferred row being Selected, so there is nothing left for
     * `replaceSelectedBroker` to refuse. The design's Q-5 ("should the service refuse a preferred
     * submission server-side?") is answered NO by this decision — do not add that refusal, it
     * would now block the intended state.
     */
    get _backupOptions() {
        return this._visible
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
     * "Add Preferred Broker" — records a broker DPEG would like to use on this sale, ahead of
     * (or instead of) a quoted opinion of value (2026-08-24).
     *
     * 🔴 THE SAME MODAL BUNDLE AS "ADD BROKER RESPONSE", DIFFERING ONLY IN `isPreferred`. It
     * creates the same `BOV_Submission__c` through the same `lightning-record-edit-form`, so the
     * field set, both submit paths, the validation-rule error surface and the create-only
     * contract are shared rather than forked. `isPreferred: true` is what makes the dialog set
     * `Is_Preferred_Broker__c` and relax the four response fields — see that bundle's header.
     *
     * ⚠ A PREFERRED ROW IS NOT A BOV RESPONSE, and the toast says so rather than reusing the
     * response wording. The two land in DIFFERENT cards on this page, and telling a user their
     * "broker response" was logged when it went to the card above is how a support ticket starts.
     *
     * ⚠ WHAT THIS BUTTON DOES *NOT* DO: SET THE STATUS. The row is created with the picklist
     * default (`Backup`) and `BovAutoSelectionService` then promotes it to `Selected`, demoting
     * the scored winner in the same bulk DML. The dialog cannot write `'Selected'` itself —
     * `BovSubmissionSelectionGuardService` refuses an insert-as-Selected while a committed
     * Selected sibling exists, which under automatic selection is every priced disposition. See
     * `c/bovAddResponseModal`'s `withParent()` for the full argument.
     *
     * ⚠ IT STILL FAILS QUIETLY FOR ANY PERSONA WITHOUT `editable` FLS ON `Is_Preferred_Broker__c`.
     * `lightning-record-edit-form` FLS-checks EVERY key in the payload including programmatic
     * ones and drops a non-editable field SILENTLY with a success toast, so such a user creates
     * an ordinary response that appears in the matrix below instead of the preferred card above.
     * 🔴 UPDATED 2026-08-24 — the field and its grants are now LIVE on usman-dpeg: a
     * FieldPermissions query shows `DPEG_Disposition_Edit` and `DPEG_Junior_Analyst_PSG` with
     * edit, and `DPEG_Principal_PSG` / `DPEG_Disposition_View` READ-ONLY. So the risk is
     * discharged for the analyst personas and LIVE for principals. There is no client-side
     * detection for it; it is a permission-set question, not a code branch.
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
     * The one implementation behind both add buttons.
     *
     * The modal is `await`ed for the same reason the replace flow is — see `_openBrokerModal`:
     * `LightningModal.open()` renders into the PLATFORM'S modal layer, so the dialog shares no
     * ancestor with this component and a bubbling `CustomEvent` has no path back here. The
     * promise IS the channel.
     */
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

        // Cancelled or dismissed — nothing changed, so say nothing.
        // ⚠ A dismissed LightningModal resolves `undefined`, and the repo's Jest stub for it
        // resolves `null` (CustomEvent coerces an absent `detail` to null). Both are falsy and
        // both must take this branch.
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
        // The record was created by a form this cacheable wire knows nothing about, so LDS has no
        // idea the submission list changed. Without this the matrix keeps showing the old set —
        // and the whole point of the rework is that the user is still looking at it.
        //
        // ⚠ ON THE PREFERRED PATH THIS REFRESH IS WHAT MAKES THE CARD APPEAR AT ALL. That card is
        // gated on `hasPreferredBroker`, which is derived from this very wire — so without the
        // refresh the user saves a preferred broker and watches nothing happen.
        refreshApex(this._wired);
    }

    /**
     * "Replace Broker" — swap the appointed broker for one of the backups.
     *
     * 🔴 RETRACTED 2026-08-24: THERE IS NOW ONE CLIENT ENTRY POINT, NOT TWO. This paragraph read
     * "ONE SERVER MECHANISM, TWO CLIENT ENTRY POINTS. This and `handleSelectBroker` open the SAME
     * modal bundle…". `handleSelectBroker` was deleted below on 2026-08-24 (automatic selection),
     * so this is the sole caller of `_openBrokerModal` today — which is why that method still
     * takes a config object rather than being inlined: `c/brokerListing` opens the same modal
     * bundle from the Active Listing stage, and collapsing the indirection here would make the
     * next second caller a re-write instead of a config.
     *
     * It calls `BovController.replaceSelectedBroker` ->
     * `BovSubmissionService.replaceSelectedBroker`. Do not fork either half: a second modal bundle
     * would have to duplicate the
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
     * ══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 DELETED 2026-08-24: `handleSelectBroker`. RETRACTION IN PLACE, NOT A SILENT REMOVAL.
     * ══════════════════════════════════════════════════════════════════════════════════════
     * A `handleSelectBroker()` stood here from 2026-08-21. It opened `c/bovReplaceBrokerModal`
     * with `isFirstAppointment: true`, `currentBroker: undefined` and the title "Broker
     * appointed", and it was the FIRST appointment on a disposition that had none.
     *
     * IT IS GONE BECAUSE THE FIRST APPOINTMENT IS NO LONGER A HUMAN ACT: the server now selects
     * the highest-scoring submission from `BOV_Score__c` automatically, and keeps re-selecting it
     * until the broker approval is sent. There is nothing left for the button to do that the save
     * has not already done.
     *
     * ⚠ THE SERVER PATH IT USED IS UNTOUCHED AND STILL REACHABLE.
     * `BovSubmissionService.replaceSelectedBroker` still accepts a first appointment (no
     * incumbent) and `c/bovReplaceBrokerModal` still supports `isFirstAppointment: true` — this
     * is a CLIENT removal only, which is what keeps it revertible in one file if automatic
     * selection is ever rolled back.
     *
     * ⚠ ITS TOAST CARRIED A NOTE WORTH KEEPING: the toast BODY on both broker paths is the
     * server's returned sentence VERBATIM, because the server chooses between "Broker appointed…"
     * and "Broker replaced…" from what it actually did inside the transaction. `_openBrokerModal`
     * below still does that. Do not re-author the body on the client.
     */

    /**
     * The one implementation behind the broker-swap button.
     *
     * 🔴 THE MODAL CANNOT REACH THIS COMPONENT WITH A BUBBLING DOM EVENT, so it does not try.
     * `LightningModal.open()` renders into the PLATFORM'S modal layer, not into this component's
     * template, so the modal shares no ancestor with the matrix and a `CustomEvent` — however
     * composed — has no path back here. The promise returned by `open()` is the channel, and this
     * component awaiting it is what keeps the wire's owner and its refresher the same object.
     *
     * 🔴 THE TOAST IS STICKY. The service's returned text carries "must be approved
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
        // no idea they changed. Without this the matrix keeps showing the old Selected broker.
        // (This comment used to add "and, on a first appointment, keeps offering 'Select Broker'
        // for a broker already chosen" — retracted 2026-08-24 with that button.)
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
