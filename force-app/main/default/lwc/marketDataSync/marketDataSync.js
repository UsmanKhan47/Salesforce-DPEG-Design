import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import OPPORTUNITY_OBJECT from '@salesforce/schema/Opportunity';
import PLACER_URL_FIELD from '@salesforce/schema/Opportunity.Placer_URL__c';
import MONTHLY_VISITS_FIELD from '@salesforce/schema/Opportunity.Monthly_Visits__c';
import PLACER_LAST_SYNCED_FIELD from '@salesforce/schema/Opportunity.Placer_Last_Synced_DateTime__c';
import COSTAR_URL_FIELD from '@salesforce/schema/Opportunity.CoStar_URL__c';
import MARKET_CAP_RATE_FIELD from '@salesforce/schema/Opportunity.Market_Cap_Rate__c';
import COSTAR_LAST_SYNCED_FIELD from '@salesforce/schema/Opportunity.CoStar_Last_Synced_DateTime__c';

/**
 * marketDataSync — one record-page card rendering ONE market-data source's Opportunity fields, a
 * `Last Synced (manual)` row and a Sync button that stamps a DateTime on the record in context.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 1. SYNC CONTACTS NOTHING. READ THIS BEFORE CHANGING ANY LABEL IN THIS FILE.
 * ═════════════════════════════════════════════════════════════════════════════
 * There is no callout, no ASB spoke, no Named Credential, no data refresh and no Placer.ai or
 * CoStar connection of any kind. Pressing Sync writes ONE DateTime field and does nothing else.
 *
 * That is dangerous in a specific way: a user reading "Last Synced: today, 09:14" will reasonably
 * conclude the Monthly Visits / Market Cap Rate figures rendered immediately above it were
 * retrieved today. They were TYPED BY HAND, possibly months ago.
 *
 * The button is labelled `Sync` rather than the safer `Mark Synced` by an explicit user decision
 * (design Gate-1, 2026-08-16), and that decision is CONDITIONAL on all three mitigations below.
 * They are requirements, not polish. If any of them is ever removed, the label must change with it:
 *
 *   (a) the row is labelled `Last Synced (manual)`, never a bare `Last Synced`;
 *   (b) a lightning-helptext on that row states that no connection exists yet and the values above
 *       are entered by hand;
 *   (c) 🔴 NO SPINNER, NO "Syncing..." STATE, NO PROGRESS INDICATOR, NO ARTIFICIAL DELAY. The click
 *       stamps and toasts immediately. Animating a fetch that does not happen is precisely how a
 *       stub becomes a lie, and it is the one mitigation that a well-meaning "polish" pass is most
 *       likely to undo. There is deliberately no `isBusy` / `isSyncing` tracked property in this
 *       class at all, so there is nothing for a spinner to bind to. Do not add one: a busy flag is
 *       a progress indicator by another name, and the write is a last-wins single-field stamp for
 *       which a double click is harmless.
 *
 * ── FORWARD PATH, when a real integration lands ───────────────────────────────
 * Do NOT rebuild this card from scratch. Four things change together, in one change:
 *   1. the write moves SERVER-SIDE to Apex (a callout must be Apex), and the timestamp becomes
 *      `System.now()` — the server clock — which closes residual R4 (a client-composed ISO string
 *      is only as correct as the user's own system clock);
 *   2. `getRecordNotifyChange` BECOMES REQUIRED, because imperative Apex DML happens behind LDS's
 *      back. See section 3 — today it is forbidden, and the two rules are exact opposites;
 *   3. a status field modelled on `Property__c.Placer_Fetch_Status__c` ships in the same change.
 *      It is deliberately absent today because a stub that contacts nothing can only ever write
 *      `Success`, and a two-value restricted picklist with one reachable value is not a status —
 *      it is a constant with a picklist around it, and it is the single most effective way to make
 *      a stub look like a working integration;
 *   4. mitigations (a)-(c) above are re-read and relaxed only as far as the new truth allows.
 * Only `handleSync` and this header need to change. The rendering, the config map and the access
 * check are all independent of where the write goes.
 *
 * ── WHAT THIS WRITE CANNOT SET OFF (verified at code review, 2026-08-16) ──────
 * Putting a user-pressable write button on `Opportunity` raises one real question: does stamping a
 * field re-trigger the heavyweight Closed Won automation? It does not, and the reason is structural
 * rather than incidental — both consumers gate on stage ENTRY, not on stage VALUE.
 * `PropertyAssetService.createAssets` tests `prior == null || !CLOSED_WON.equals(prior.StageName)`,
 * and `DealFolderService` uses the identical semantics. A stamp-only update leaves `StageName`
 * unchanged, so neither fires: no second `Property_Asset__c`, and no second SharePoint folder — the
 * latter mattering most, because a duplicate folder is an EXTERNAL write no Salesforce transaction
 * can roll back. Recorded here so the next author does not have to re-derive it.
 *
 * ── THE HEADER IS THE SLDS EXPANDABLE-SECTION BLUEPRINT (2026-08-17) ──────────
 * The card header reproduces a native Dynamic Forms `fieldSection` exactly: a full-width grey bar
 * that IS the button, a `utility:switch` chevron SLDS rotates off `slds-is-open`, and a SENTENCE-CASE
 * title. The first version used `slds-section__title slds-text-title_caps` plus a source icon, which
 * rendered as small uppercase text ("PLACER") beside a coloured glyph — visibly a different construct
 * from the neighbouring native "Broker" section, which is the whole of "keep the design the same".
 * `slds-text-title_caps` is the utility-bar/caps treatment, not what a collapsible section renders.
 *
 * 🔴 THE SOURCE ICONS ARE GONE AND `iconName` WAS REMOVED FROM `CONFIG_BY_SOURCE` — user decision:
 * an exact match beats keeping them, because the native sections have no icon. Removed from the
 * config rather than left unused, so nothing invites a later reader to render it again.
 *
 * ⚠ STATED LIMITATION: the collapse state is NOT PERSISTED across page loads — see `_isOpen`.
 *
 * ── KNOWN INTERACTION, accepted (no code change available) ────────────────────
 * Pressing Sync while an inline edit is open in this card's own `lightning-record-form` may discard
 * the unsaved draft, because the write re-emits the record through the LDS cache and the form
 * re-renders from it. This is inherent to the `lightning-record-form` approach chosen in D9: the
 * form exposes no dirty state, so there is nothing for this component to gate the click on.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 2. ONE BUNDLE SERVES BOTH SOURCES — AND A SECOND ONE WAS BUILT AND DELETED
 * ═════════════════════════════════════════════════════════════════════════════
 * ARCHITECTURE.md §5 records that `c/transactionAdvanceStage` was created and DELETED the same day
 * (2026-08-12, code review W3, user decision) for being byte-identical to `c/advanceRecordStage`
 * below the comments, and states the governing rule: "a copy carrying only a different header is
 * not a split — it is a second file that must now receive every fix the first one gets, with
 * nothing but review to notice when it does not."
 *
 * Placer and CoStar differ in DATA (a title, an icon, a field list, a stamp field). They do not
 * differ in BEHAVIOUR. So there is one bundle, parameterised by the `source` design property and
 * `CONFIG_BY_SOURCE` below — the same shape as `advanceRecordStage`'s server-side `CONFIG_BY_TYPE`,
 * moved to the client because here the variation is presentational rather than transactional.
 *
 * A third vendor is ONE MAP ENTRY plus a component instance on the FlexiPage. If a future source
 * ever needs genuinely different BEHAVIOUR, split THAT one into its own bundle — and note that
 * "its own bundle" means a bundle that DIFFERS.
 *
 * ⚠ The field API names arrive as `@salesforce/schema/...` imports, never as free-form strings.
 * That is the load-bearing half of the decision: a renamed or deleted field becomes a BUILD-TIME
 * failure instead of a card that deploys green and renders empty. A `fieldNames` design property
 * taking comma-separated API names was considered and rejected for exactly that reason.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 3. THE WRITE IS LDS `updateRecord`, SO `getRecordNotifyChange` IS FORBIDDEN
 * ═════════════════════════════════════════════════════════════════════════════
 * `updateRecord` writes THROUGH the LDS cache, so this card, the record page and every other
 * component on it re-render on their own. Calling `getRecordNotifyChange` here would be redundant
 * at best. This is the `c/leadStatusChange` rule.
 *
 * It is the EXACT OPPOSITE of the `c/dealActionGuard` / `c/recordStageGuard` rule, which applies
 * only to IMPERATIVE APEX DML — that happens behind LDS's back, so those bundles MUST call it.
 * ARCHITECTURE.md §5's guard-util table documents that the two requirements are opposite and must
 * not be harmonised.
 *
 * ⚠ `marketDataSyncTest`'s J6 asserts `getRecordNotifyChange` is NEVER called. That test is the
 * PERMANENT FALSIFIER against someone later "fixing" this by analogy with the stage-action
 * bundles. Do not delete it. When the forward path above moves the write to Apex, that test
 * inverts — it does not disappear.
 *
 * ── ERROR HANDLING: the LDS error shape, not the Apex one ─────────────────────
 * `messageFor` below is ported from `c/leadStatusChange` and must NOT be replaced with
 * `c/dealActionGuard`'s `body.message`-only read. When LDS refuses a write (validation rule, FLS
 * refusal, required field) the platform puts its own generic "An error occurred while trying to
 * update the record. Please try again." in `body.message` and the ACTIONABLE text in `body.output`
 * — so a `body.message`-only read tells the user to retry a problem retrying can never fix.
 * `c/dealActionGuard`'s reader is correct for ITS Apex path and wrong here.
 *
 * ⚠ It is a local copy rather than an import: `c/leadStatusChange` is Lead-bound by contract (it
 * imports `Lead.Status` schema and `LeadActionPermissionController`), so importing from it would
 * pull a Lead permission Apex dependency into an Opportunity card that has no Apex at all.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 4. NO PERMISSION GATE — DELIBERATELY, AND FLS IS THE GATE
 * ═════════════════════════════════════════════════════════════════════════════
 * No custom permission and no FlexiPage `<visibilityRule>`. There is no privileged operation to
 * guard: the button's entire effect is writing one DateTime that any user with FLS edit can
 * already type by hand. Contrast the three stage-action gates, every one of which guards a record
 * moving through a business process under server-side logic.
 *
 * FLS edit on the stamp field IS the gate, and it is already modelled — `DPEG_Acquisition_Edit`
 * grants these fields editable, `DPEG_Acquisition_View` and `DPEG_Opportunity_View` grant them
 * read-only. So a View persona gets a read-only card and an Edit persona gets a working button, at
 * zero new metadata and with no layer-4/layer-5 placement decision to get wrong.
 *
 * What this class does instead: it reads the stamp field's `updateable` flag from `getObjectInfo`
 * and renders the button DISABLED WITH A REASON — never hidden silently, and never left to throw
 * on click. It FAILS CLOSED: until the object info has arrived the button is disabled.
 *
 * 🔴 A `<visibilityRule>` bound to a FIELD must never be used to hide this button. ARCHITECTURE
 * records it as measured twice: such a rule evaluates FALSE for anyone lacking FLS READ on that
 * field, with no error and no log, so the control vanishes for users who are genuinely authorized.
 * That defect is why the whole `User.*_Driver__c` model was retired.
 */

/** Fallback when an LDS error carries nothing readable. Never let `undefined` reach a toast. */
const GENERIC_ERROR =
    'The sync timestamp could not be saved. Please try again or contact your administrator.';

/** Shown beside a disabled button when the running user cannot edit the stamp field. */
const NO_EDIT_ACCESS_MESSAGE =
    'You do not have edit access to this field, so it cannot be stamped.';

/** Rendered when the Last Synced field has never been stamped on this record. */
const NEVER_SYNCED_LABEL = 'Never';

/**
 * Rendered when the record wire failed, most plausibly because the running user has no FLS READ on
 * the stamp field.
 *
 * ⚠ It is a SEPARATE state from `Never`, deliberately. Collapsing them would tell a user with no
 * read access that the deal has never been synced — a confident wrong answer, where "not available"
 * is a true one. That distinction is the whole reason the record wire's error branch is tracked at
 * all rather than being allowed to fall through to the empty case.
 */
const UNAVAILABLE_LABEL = 'Not available';

/**
 * Rendered in the Last Synced row while the record wire is still in flight: an em-dash, and
 * `aria-hidden` in the template so a screen reader is told nothing rather than told a dash.
 *
 * 🔴 IT MUST NOT BE `Never`. Before the first emit this component does not know whether the deal has
 * been synced, and `Never` is an ASSERTION — the same confident-wrong-answer defect that
 * `UNAVAILABLE_LABEL` exists to prevent on the error branch, and that the three-state access gate
 * below exists to prevent on the button. All three are the same rule: say nothing until you know.
 */
const LOADING_LABEL = '—';

/**
 * Everything that differs between the two cards. Nothing else in this class knows a vendor name.
 *
 * `helpText` is mitigation (b) of the stub warning in section 1 of the header and is NOT optional
 * decoration — it is the only place the UI states, in words, that the figures above it are
 * hand-entered. Keep it explicit per source rather than composing it from `title`, so that a source
 * whose truth changes (a real integration for one vendor and not the other) can say so on its own.
 */
const CONFIG_BY_SOURCE = {
    Placer: {
        title: 'Placer',
        fields: [PLACER_URL_FIELD, MONTHLY_VISITS_FIELD],
        stampField: PLACER_LAST_SYNCED_FIELD,
        helpText:
            'Recorded when a user pressed Sync. There is no connection to Placer.ai yet, so the values above are entered by hand and may be out of date.',
        successMessage: 'Placer marked as synced.'
    },
    CoStar: {
        title: 'CoStar',
        fields: [COSTAR_URL_FIELD, MARKET_CAP_RATE_FIELD],
        stampField: COSTAR_LAST_SYNCED_FIELD,
        helpText:
            'Recorded when a user pressed Sync. There is no connection to CoStar yet, so the values above are entered by hand and may be out of date.',
        successMessage: 'CoStar marked as synced.'
    }
};

/**
 * The accepted `source` values, derived from the map so the error message can never drift from
 * what the component actually supports.
 */
const ACCEPTED_SOURCES = Object.keys(CONFIG_BY_SOURCE).join(', ');

/**
 * Returns the first non-empty `message` string carried by an error entry, or a list of them.
 *
 * Accepts a single object or an array because the LDS error shape is not uniform: `output.errors`
 * is an array, each `output.fieldErrors` bucket is an array, and `body` itself is sometimes an
 * array. Anything not shaped like an error entry is skipped rather than thrown on.
 *
 * @param {*} entries an error entry, or an array of them
 * @returns {string|undefined} the first usable message, or undefined
 */
function firstMessage(entries) {
    if (!entries) {
        return undefined;
    }
    const list = Array.isArray(entries) ? entries : [entries];
    for (let i = 0; i < list.length; i++) {
        const entry = list[i];
        if (
            entry &&
            typeof entry.message === 'string' &&
            entry.message.trim() !== ''
        ) {
            return entry.message;
        }
    }
    return undefined;
}

/**
 * Extracts a user-safe message from an LDS write error, falling back to a fixed message so no raw
 * platform text or `undefined` ever reaches a toast (ARCHITECTURE.md §5).
 *
 * Ordering is deliberate and is the whole point of this function:
 *   1. `body.output.errors`      — page-level errors: validation rules whose errorDisplayField is
 *                                  not on the submitted field set, and Apex-thrown page errors.
 *   2. `body.output.fieldErrors` — { <fieldApiName>: [ { message } ] }: where a rule bound to a
 *                                  specific field lands, and where a REQUIRED-field failure lands.
 *   3. `body.message`            — the platform's generic summary line.
 *   4. the caller's fallback.
 *
 * Reading only `body.message` surfaces the generic text and DROPS the actionable one. See section 3
 * of the class header.
 *
 * This runs on an error path and MUST NOT throw: every lookup is guarded and the whole walk is
 * wrapped, because an exception here would replace a bad message with no message at all.
 *
 * @param {*} error the error thrown by updateRecord
 * @param {string} [fallback] message to use when the error carries no readable body
 * @returns {string} a user-safe message
 */
function messageFor(error, fallback) {
    try {
        const body = error && error.body;
        const bodies = Array.isArray(body) ? body : [body];

        // 1 + 2 — the rule's own text, wherever LDS chose to put it.
        for (let i = 0; i < bodies.length; i++) {
            const output = bodies[i] && bodies[i].output;
            if (!output || typeof output !== 'object') {
                continue;
            }

            const pageError = firstMessage(output.errors);
            if (pageError) {
                return pageError;
            }

            const fieldErrors = output.fieldErrors;
            if (fieldErrors && typeof fieldErrors === 'object') {
                const buckets = Array.isArray(fieldErrors)
                    ? fieldErrors
                    : Object.values(fieldErrors);
                for (let j = 0; j < buckets.length; j++) {
                    const fieldError = firstMessage(buckets[j]);
                    if (fieldError) {
                        return fieldError;
                    }
                }
            }
        }

        // 3 — the platform's summary line.
        for (let i = 0; i < bodies.length; i++) {
            const bodyMessage = firstMessage(bodies[i]);
            if (bodyMessage) {
                return bodyMessage;
            }
        }
    } catch (walkFailure) {
        // An unrecognised error shape must degrade to the fallback, never to a second exception.
    }
    return fallback || GENERIC_ERROR;
}

export default class MarketDataSync extends LightningElement {
    /** Set by the record page. */
    @api recordId;

    /**
     * Which market-data source this instance renders. Design property; one of the CONFIG_BY_SOURCE
     * keys. Defaults to `Placer` so a component dropped in App Builder renders something real
     * rather than an error, matching the default declared in the .js-meta.xml.
     */
    @api source = 'Placer';

    /** The last `getRecord` payload. The Last Synced row is derived from THIS, never from a local
     * copy written after a successful save — see `lastSynced`. */
    _record;

    /** True once the record wire has reported a failure (e.g. no FLS read on the stamp field). */
    _recordWireFailed = false;

    /**
     * True once the record wire has answered AT ALL — data or error.
     *
     * Distinct from `_record` being set, because "no record yet" and "a record with a null stamp"
     * are different facts that would otherwise render identically. See LOADING_LABEL.
     */
    _recordLoaded = false;

    /**
     * Whether the field section is expanded. Defaults to OPEN, matching a native Dynamic Forms field
     * section.
     *
     * ⚠ STATED LIMITATION: collapse state is NOT PERSISTED. Navigating away and back, or reloading
     * the page, returns the section to expanded. A native field section remembers its state per user
     * because the platform stores it server-side against the FlexiPage; an LWC has no equivalent, and
     * the alternatives (a user-level custom setting, localStorage) would each add a persistence
     * mechanism and a failure mode to a purely cosmetic preference. Deliberately not built.
     */
    _isOpen = true;

    // ─────────────────────────────────────────────────────────────────────────
    // Configuration
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The resolved config, or `undefined` when `source` names something this component does not
     * support.
     *
     * Matching is a TRIMMED, EXACT key lookup and is deliberately case-sensitive: `configError`
     * below enumerates the accepted spellings, so a case typo produces an actionable message rather
     * than silently succeeding under a spelling the map does not literally contain.
     */
    get config() {
        const key = typeof this.source === 'string' ? this.source.trim() : '';
        return CONFIG_BY_SOURCE[key];
    }

    get isConfigured() {
        return this.config !== undefined;
    }

    /**
     * The inline `role="alert"` text for an unsupported `source`.
     *
     * 🔴 A misconfigured instance MUST say so visibly. A silently empty card is indistinguishable
     * from "this deal has no market data", which is the failure mode this component exists to
     * design out — the same trap ARCHITECTURE records for a sweeper logging an all-zeros summary.
     * `targetConfig` properties cannot be constrained to an enum, so this runtime check is the only
     * mechanism available.
     */
    get configError() {
        const supplied =
            typeof this.source === 'string' && this.source.trim() !== ''
                ? '"' + this.source + '"'
                : 'a blank value';
        return (
            'Market Data Sync is not configured correctly: ' +
            supplied +
            ' is not a supported data source. Set the "Data source" property on this component to one of: ' +
            ACCEPTED_SOURCES +
            '.'
        );
    }

    get cardTitle() {
        return this.config ? this.config.title : '';
    }

    get helpText() {
        return this.config ? this.config.helpText : '';
    }

    /**
     * Bound to `lightning-record-form`'s `object-api-name` — the same `@salesforce/schema` import the
     * `getObjectInfo` wire uses, rather than a `"Opportunity"` string literal in the template.
     *
     * Consistent with this bundle's own stated reason for importing schema at all: a compile-time
     * reference cannot silently disagree with the wire beside it. `lightning-record-form` accepts an
     * object reference as well as a string.
     */
    get objectApiName() {
        return OPPORTUNITY_OBJECT;
    }

    /** The source fields rendered by lightning-record-form. Excludes the stamp field, which this
     * component renders itself as the Last Synced row. */
    get formFields() {
        return this.config ? this.config.fields : [];
    }

    /**
     * The `fields` config for the record wire. `undefined` when unconfigured, which is how an LWC
     * wire is told not to fetch — LDS treats an incomplete config as invalid and emits nothing.
     */
    get stampFieldList() {
        return this.config ? [this.config.stampField] : undefined;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The collapsible field-section header (SLDS "Expandable Section" blueprint)
    // ─────────────────────────────────────────────────────────────────────────

    get isOpen() {
        return this._isOpen;
    }

    /**
     * `slds-is-open` is the ONLY thing that needs to change: SLDS itself rotates the chevron
     * (`.slds-is-open .slds-section__title-action-icon`) and reveals the content off this one class,
     * so neither is re-implemented here.
     */
    get sectionClass() {
        return this._isOpen ? 'slds-section slds-is-open' : 'slds-section';
    }

    /**
     * `slds-hide` is belt-and-braces alongside SLDS's own `.slds-section__content` display rule. The
     * real guarantee is that the body is UNMOUNTED when collapsed (see the template) — hiding by
     * stylesheet alone is not "hidden from assistive technology", and it would leave focusable
     * controls inside an `aria-hidden` container, which is itself an accessibility defect.
     */
    get sectionContentClass() {
        return this._isOpen
            ? 'slds-section__content'
            : 'slds-section__content slds-hide';
    }

    /** Strings, not booleans: ARIA state attributes are enumerated values, not boolean attributes. */
    get ariaExpanded() {
        return this._isOpen ? 'true' : 'false';
    }

    get ariaHidden() {
        return this._isOpen ? 'false' : 'true';
    }

    handleToggleSection() {
        this._isOpen = !this._isOpen;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Wires
    // ─────────────────────────────────────────────────────────────────────────

    @wire(getRecord, { recordId: '$recordId', fields: '$stampFieldList' })
    wiredRecord({ data, error }) {
        if (data) {
            this._record = data;
            this._recordWireFailed = false;
            this._recordLoaded = true;
        } else if (error) {
            this._record = undefined;
            this._recordWireFailed = true;
            // Set on BOTH branches: the flag means "the wire has answered", not "the wire succeeded".
            this._recordLoaded = true;
        }
    }

    @wire(getObjectInfo, { objectApiName: OPPORTUNITY_OBJECT })
    objectInfo;

    // ─────────────────────────────────────────────────────────────────────────
    // Last Synced
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The stamp value, read from the LDS record.
     *
     * 🔴 IT IS DERIVED FROM THE WIRE, NOT FROM LOCAL STATE, AND THAT IS THE POINT. `handleSync`
     * deliberately does not assign the value it just wrote. Because `updateRecord` writes THROUGH
     * the LDS cache, the wire re-emits and this getter picks the new value up on its own — so what
     * the user reads is what the RECORD holds, not what the client believes it sent. Assigning it
     * locally would make the row show a timestamp even on a write the server silently altered or a
     * cache the platform later corrected, and would hide the very failure the error toast reports.
     * Pinned by J7.
     */
    get lastSynced() {
        if (!this.config || !this._record) {
            return undefined;
        }
        return getFieldValue(this._record, this.config.stampField);
    }

    get hasLastSynced() {
        const value = this.lastSynced;
        return value !== undefined && value !== null && value !== '';
    }

    /** True when the record could not be read at all — see UNAVAILABLE_LABEL. */
    get lastSyncedUnavailable() {
        return this._recordWireFailed === true;
    }

    /**
     * True while the record wire has not answered yet — see LOADING_LABEL.
     *
     * The `!lastSyncedUnavailable` term is redundant today (the error branch sets `_recordLoaded`
     * too) and is kept deliberately: it states the intended precedence, so a future edit that stops
     * setting the flag on the error branch degrades to "unknown" rather than silently back to
     * "Never".
     */
    get lastSyncedPending() {
        return !this._recordLoaded && !this.lastSyncedUnavailable;
    }

    get loadingLabel() {
        return LOADING_LABEL;
    }

    get emptyLastSyncedLabel() {
        return this.lastSyncedUnavailable ? UNAVAILABLE_LABEL : NEVER_SYNCED_LABEL;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Access — FLS edit on the stamp field is the gate (header section 4)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * `true` / `false` once known, `undefined` while the object info is still in flight.
     *
     * Three states rather than two, so a still-loading card does not accuse the user of lacking
     * access. `syncDisabled` folds `undefined` into "disabled" (fail closed); `disabledReason`
     * does NOT, so no reason text is rendered during the sub-second load.
     */
    get stampFieldUpdateable() {
        if (!this.config) {
            return false;
        }
        if (this.objectInfo && this.objectInfo.error) {
            // 🔴 `undefined`, NOT `false`, and the distinction is the whole point of this branch.
            // Both answers disable the button (`syncDisabled` is `!== true`), so this costs nothing
            // in access terms — but `false` additionally renders "You do not have edit access to
            // this field", and an object-info read failure is NOT evidence of a field-level FLS
            // denial. It is more plausibly an object-access problem or a transient failure. Refusing
            // to act on an answer you do not have is correct; ASSERTING A CAUSE YOU HAVE NOT
            // ESTABLISHED is not, and a user told the wrong cause will chase the wrong fix.
            // Kept as an explicit branch rather than falling through to the `!info` case below,
            // because the two arrive at the same answer for different reasons and only one of them
            // is a decision.
            return undefined;
        }
        const info = this.objectInfo && this.objectInfo.data;
        if (!info || !info.fields) {
            return undefined;
        }
        const field = info.fields[this.config.stampField.fieldApiName];
        return !!(field && field.updateable === true);
    }

    /** FAIL CLOSED: anything other than a known-true `updateable` disables the button. */
    get syncDisabled() {
        return this.stampFieldUpdateable !== true;
    }

    get showDisabledReason() {
        return this.stampFieldUpdateable === false;
    }

    get disabledReason() {
        return NO_EDIT_ACCESS_MESSAGE;
    }

    /**
     * The button's tooltip, so the refusal reason is reachable on a narrow layout where the note
     * beside the button may have wrapped away.
     *
     * Empty when the button is enabled — a tooltip repeating the visible label adds nothing, and a
     * redundant `title` is noise for anyone hovering or using assistive tooling.
     *
     * 🔴 EMPTY STRING, NOT `undefined` AND NOT `null`. Both of those were tried and MEASURED to be
     * worse: a dynamic attribute bound on a CUSTOM ELEMENT is written unconditionally with the
     * STRINGIFIED value, so the enabled button rendered `title="undefined"` and then `title="null"`
     * — a user hovering it would be shown the word "undefined". That is strictly worse than the
     * redundant tooltip this change set out to remove.
     *
     * ⚠ That stringification is at least partly an artefact of the Jest environment (the
     * `lightning-button` stub does not declare `title` as `@api`, so LWC falls back to attribute
     * handling, whereas the real base component exposes it as a property). The empty string is
     * correct under BOTH readings and needs no caveat, which is why it is the value chosen rather
     * than arguing about which environment is authoritative. `title=""` produces no tooltip.
     *
     * Pinned by the S3 test, which asserts the RENDERED attribute rather than this getter's return
     * value — a getter-level assertion would have passed on both broken versions.
     */
    get syncButtonTitle() {
        return this.showDisabledReason ? NO_EDIT_ACCESS_MESSAGE : '';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Action
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Stamps the source's Last Synced field. NOTHING ELSE HAPPENS — see header section 1.
     *
     * The guard is defence in depth, not decoration: `disabled` on a button is a UI affordance, and
     * a click can still reach a handler (it does in Jest, and it can through assistive tooling), so
     * the refusal is expressed in code as well as in markup.
     *
     * 🔴 No `getRecordNotifyChange` (header section 3). 🔴 No spinner and no busy state (section 1c).
     */
    async handleSync() {
        const config = this.config;
        if (!config || this.syncDisabled) {
            return;
        }

        const fields = {};
        fields.Id = this.recordId;
        // Client clock — residual R4, accepted while the value asserts nothing real. It becomes
        // System.now() when the write moves server-side.
        fields[config.stampField.fieldApiName] = new Date().toISOString();

        try {
            await updateRecord({ fields });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: config.successMessage,
                    variant: 'success'
                })
            );
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: messageFor(error, GENERIC_ERROR),
                    variant: 'error'
                })
            );
        }
    }
}
