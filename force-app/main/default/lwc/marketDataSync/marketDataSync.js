import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import PROPERTY_OBJECT from '@salesforce/schema/Property__c';
import OPPORTUNITY_PROPERTY_FIELD from '@salesforce/schema/Opportunity.Property__c';

// ── Placer block (FSD §18.2) ─────────────────────────────────────────────────
import PLACER_URL_FIELD from '@salesforce/schema/Property__c.Placer_URL__c';
import PLACER_STATE_RANK_FIELD from '@salesforce/schema/Property__c.Placer_State_Rank__c';
import PLACER_STATE_PERCENTILE_FIELD from '@salesforce/schema/Property__c.Placer_State_Percentile__c';
import PLACER_MSA_RANK_FIELD from '@salesforce/schema/Property__c.Placer_MSA_Rank__c';
import PLACER_NATIONAL_RANK_FIELD from '@salesforce/schema/Property__c.Placer_National_Rank__c';
import MONTHLY_VISITS_FIELD from '@salesforce/schema/Property__c.Monthly_Visits__c';
import PLACER_FETCH_STATUS_FIELD from '@salesforce/schema/Property__c.Placer_Fetch_Status__c';
import PLACER_LAST_SYNCED_FIELD from '@salesforce/schema/Property__c.Placer_Last_Synced_DateTime__c';

// ── CoStar block (FSD §18.2) ─────────────────────────────────────────────────
import COSTAR_URL_FIELD from '@salesforce/schema/Property__c.CoStar_URL__c';
import COSTAR_PCT_LEASED_FIELD from '@salesforce/schema/Property__c.CoStar_Pct_Leased__c';
import COSTAR_LOCATION_SCORE_FIELD from '@salesforce/schema/Property__c.CoStar_Location_Score__c';
import COSTAR_ASKING_RENT_PSF_FIELD from '@salesforce/schema/Property__c.CoStar_Asking_Rent_PSF__c';
import MARKET_RENT_PSF_FIELD from '@salesforce/schema/Property__c.Market_Rent_PSF__c';
import COSTAR_EXIT_CAP_RATE_FIELD from '@salesforce/schema/Property__c.CoStar_Exit_Cap_Rate__c';
import MARKET_CAP_RATE_FIELD from '@salesforce/schema/Property__c.Market_Cap_Rate__c';
import COSTAR_FETCH_STATUS_FIELD from '@salesforce/schema/Property__c.CoStar_Fetch_Status__c';
import COSTAR_LAST_SYNCED_FIELD from '@salesforce/schema/Property__c.CoStar_Last_Synced_DateTime__c';

/**
 * marketDataSync — one record-page card rendering ONE market-data source's FSD §18.2 block from the
 * deal's linked `Property__c`, a `Last Synced (manual)` row and a Sync button that stamps a DateTime
 * on that same Property record.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 1. SYNC CONTACTS NOTHING. READ THIS BEFORE CHANGING ANY LABEL IN THIS FILE.
 * ═════════════════════════════════════════════════════════════════════════════
 * There is no callout, no ASB spoke, no Named Credential, no data refresh and no Placer.ai or
 * CoStar connection of any kind. Pressing Sync writes ONE DateTime field and does nothing else.
 *
 * That is dangerous in a specific way: a user reading "Last Synced: today, 09:14" will reasonably
 * conclude the figures rendered immediately above it were retrieved today. They were TYPED BY HAND
 * (or seeded), possibly months ago.
 *
 * 🔴 THE RISK WENT UP WITH THE 2026-08-17 CHANGE, IT DID NOT GO DOWN. This card used to show four
 * fields. It now shows EIGHT or NINE, every one of them carrying an FSD-sanctioned provider name,
 * including a `Sync Status` picklist sitting directly beside a `Last Synced` timestamp. That is a
 * screen which looks far more like a working integration than the one it replaced, while still
 * contacting nothing. The three mitigations below are therefore MORE load-bearing than before, not
 * less — a bigger, more official-looking card is exactly the thing that makes a reader stop
 * questioning where the numbers came from.
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
 * 🔴 A FOURTH THING NOW CARRIES THE SAME WEIGHT AND IS NOT THIS COMPONENT'S TO ENFORCE: the seed
 * writes `Data Source = Manual` and `Sync Status = Not Synced` on every record, and leaves both
 * `*_Last_Synced_DateTime__c` NULL so this card renders `Never`. Those are the only in-record
 * signals that a number was never fetched. If a future change starts seeding `Success` or a
 * timestamp, mitigations (a)-(c) stop being sufficient on their own.
 *
 * ⚠ OF THOSE THREE SEED SIGNALS, THIS CARD SHOWS TWO: `Sync Status` and (as `Never`) the timestamp.
 * `Data Source` is seeded but deliberately NOT rendered here — user decision, 2026-08-17; see the
 * CONFIG_BY_SOURCE header. So the seed still matters more than the card does: a wrongly-seeded
 * `Data Source` would be invisible from this screen entirely.
 *
 * ── FORWARD PATH, when a real integration lands ───────────────────────────────
 * Do NOT rebuild this card from scratch. Four things change together, in one change:
 *   1. the write moves SERVER-SIDE to Apex (a callout must be Apex), and the timestamp becomes
 *      `System.now()` — the server clock — which closes residual R4 (a client-composed ISO string
 *      is only as correct as the user's own system clock);
 *   2. `getRecordNotifyChange` BECOMES REQUIRED, because imperative Apex DML happens behind LDS's
 *      back. See section 4 — today it is forbidden, and the two rules are exact opposites;
 *   3. `<source>_Fetch_Status__c` starts carrying `Success` / `Error` instead of the honest
 *      `Not Synced` it holds today. ⚠ That field ALREADY SHIPS ON THIS CARD, which is a change from
 *      the earlier design: it was argued then that a status field must not exist while the stub
 *      does, because a stub can only ever write `Success`. `Property__c.<source>_Fetch_Status__c`
 *      escapes that argument for one reason only — it carries a THIRD value, `Not Synced`, which is
 *      TRUE today. The field is honest because of that value, not because it is a status field;
 *   4. mitigations (a)-(c) above are re-read and relaxed only as far as the new truth allows.
 * Only `handleSync` and this header need to change. The rendering, the config map and the access
 * check are all independent of where the write goes.
 *
 * ── WHAT THIS WRITE CANNOT SET OFF (re-measured 2026-08-17) ───────────────────
 * The write no longer touches `Opportunity` at all, so the previous analysis here — that a stamp
 * cannot re-fire `PropertyAssetService` / `DealFolderService` because both gate on stage ENTRY
 * rather than stage VALUE — is now MOOT rather than merely still-true. It is retired, not carried
 * forward, because a reader would otherwise verify the wrong object.
 *
 * The current answer is simpler and was measured against the repo on 2026-08-17: `Property__c` has
 * NO Apex trigger (there is no `PropertyTrigger`, and the six triggers in `triggers/` are on
 * `Contract_Review__c`, `Disposition__c`, `EmailMessage`, `Lead`, `Opportunity` and `Task`) and NO
 * Flow references it. So a stamp on `Property__c` sets off nothing whatsoever. ⚠ That is a fact
 * about the repo on a date, not a structural guarantee — re-check it if this card ever writes
 * anything beyond the stamp.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 2. THE CARD RENDERS AND WRITES THE **PROPERTY**, NOT THE OPPORTUNITY (2026-08-17)
 * ═════════════════════════════════════════════════════════════════════════════
 * This is the substantive change of 2026-08-17 and the thing most likely to surprise the next
 * reader: `record-id` on the form below is NOT `this.recordId`. The component sits on an
 * `Opportunity` record page, resolves that deal's `Property__c` lookup, and then renders and writes
 * the PROPERTY.
 *
 * WHY the data lives there: FSD §18.1 puts the market layer "directly on the property record";
 * `MarketDataSnapshotService`'s own header argues the same, because a property is shared by every
 * deal targeting it and two deals must not see two market pictures; and ARCHITECTURE §5 already
 * declares the `Property__c` timestamps the authoritative freshness markers for this layer.
 *
 * ── HOW, and the shape that was REJECTED ──────────────────────────────────────
 * `lightning-record-form` CANNOT render `Property__r.*`: its `fields` are resolved against
 * `object-api-name`, and LDS does not accept a spanning path there. Two shapes were available:
 *
 *   (a) read `Opportunity.Property__r.X` as spanning fields and hand-render them with
 *       `lightning-formatted-*` in `slds-form-element` rows;
 *   (b) read ONE field — `Opportunity.Property__c`, the Id — then point the form at the Property.
 *
 * 🔴 (b), AND (a) IS SPECIFICALLY WRONG HERE RATHER THAN MERELY INFERIOR. Shape (a) is read-only,
 * and this bundle's own template comment already rejected `lightning-output-field` for exactly that
 * reason — "a functional regression, not a styling choice". Taking (a) would reintroduce the
 * regression that argument rejected, on seventeen fields instead of four, in the very change whose
 * purpose is to put MORE data on the card. Inline edit survives; that is not negotiable by
 * accident.
 *
 * (a) also loses the platform's own rendering of a Url field as a link and of a picklist as its
 * LABEL rather than its API value — five of the nine CoStar fields are one or the other.
 *
 * ── 🔴 WHAT (b) COSTS. STATE IT; DO NOT DISCOVER IT IN UAT ────────────────────
 *   1. THE CARD EDITS A SHARED RECORD FROM A PAGE THAT IS NOT ITS OWN. A user changing
 *      `CoStar_Pct_Leased__c` on Deal A's page changes the number every other deal on that property
 *      sees. That is CORRECT — it is the whole reason the market layer lives on `Property__c` — but
 *      it is not obvious from an Opportunity page. The only mitigation available is words, so the
 *      per-source `helpText` names the source record. Do not remove that sentence; it is the sole
 *      on-screen statement of a cross-deal side effect.
 *   2. TWO RECORD CONTEXTS ON ONE PAGE. A save in this card does not refresh Opportunity-level
 *      components and vice versa. Accepted: nothing on the Opportunity derives from these fields
 *      except `Market_Data_Snapshot__c`, which is written only at approval.
 *   3. THE `targetConfigs` RESTRICTION TO `Opportunity` IS NOW A STRONGER CLAIM, NOT A WEAKER ONE.
 *      The traversal `Opportunity.Property__c` is hard-coded here, so an instance on any other
 *      object genuinely cannot resolve a record at all. Keep the restriction.
 *   4. SHARING. `Property__c` OWD is Private and its one sharing rule is an OWNER rule scoped to the
 *      `Acquisition` queue, which a `LeadConvertService`-created Property does not reach. The card
 *      works only because all three relevant permission sets carry `viewAllRecords = true` on
 *      `Property__c` (measured 2026-08-17). ⚠ That is ORG state, not repo state. If it is ever
 *      removed the card shows an access error — it fails LOUDLY, which is the acceptable direction,
 *      but no test can catch it and no deploy will warn.
 *
 * ── 🔴 A DEAL WITH NO PROPERTY IS AN ORDINARY STATE, NOT AN ERROR ─────────────
 * Only `LeadConvertService` creates and links a `Property__c`, so a manually-created deal has none.
 * This is already a named residual on three other features (`PropertyAssetService` R1,
 * `DealFolderService` R1, `MarketDataSnapshotService` R1). The card must say so:
 *
 *   - a visible inline note, `role="status"` — 🔴 NOT `role="alert"`. `role="alert"` is reserved in
 *     this bundle for `configError`, which is an ADMINISTRATOR MISCONFIGURATION nothing else in the
 *     org would ever report. A missing Property is an expected state a user can fix by filling in a
 *     lookup. Collapsing the two would train users to ignore the alert that actually matters;
 *   - the form is NOT MOUNTED. A `lightning-record-form` with a null `record-id` must never render;
 *   - the button is rendered and DISABLED WITH A REASON, never hidden. Hiding a control from a user
 *     who is genuinely authorized is the defect that retired the `User.*_Driver__c` model;
 *   - and NOTHING IS SAID UNTIL THE OPPORTUNITY WIRE HAS ANSWERED. `_dealLoaded` exists for that and
 *     nothing else. "No property linked" asserted before the fact is in hand is the same
 *     confident-wrong-answer defect that `LOADING_LABEL`, `UNAVAILABLE_LABEL` and the three-state
 *     access gate each exist to prevent. Four instances of one rule: say nothing until you know.
 *
 * ── WHY TWO `getRecord` WIRES AND NOT ONE SPANNING READ ───────────────────────
 * The stamp could in principle be read as `Opportunity.Property__r.<stamp>` on the deal wire, saving
 * a wire. It is NOT, deliberately, and the reason is BLAST RADIUS — which is measurable and already
 * test-pinned, not a guess about platform behaviour.
 *
 * Folding the stamp onto the deal wire means WIDENING `DEAL_FIELDS`, and that constant's own comment
 * says why it must stay at one field: a `getRecord` refusal is all-or-nothing for the fields it
 * selects, so a user lacking FLS on the stamp would lose the PROPERTY ID too — and with it the form,
 * every metric, and the ability to tell "no property linked" from "could not read". The whole card
 * would degrade on a permission gap in ONE non-essential field.
 *
 * With two wires that same refusal costs exactly one row: the form stays mounted, the metrics still
 * render, and only the Last Synced row falls back to `Not available`. `J7 (cont)` pins precisely
 * that — it refuses the PROPERTY read and asserts the form is still there. One extra read buys a
 * bounded failure.
 *
 * ⚠ DO NOT restate this as "a spanning read might not re-emit after `updateRecord`". An earlier
 * draft of this header did, and it was the weakest available ground: the LDS store is normalized by
 * record Id and `updateRecord` merges into it, so a spanning read very likely WOULD re-emit. Arguing
 * from an unknown that probably resolves against you invites the next reader to delete the second
 * wire the moment they check. The blast-radius argument does not depend on how LDS invalidates.
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
 * ⚠ The card is now 8-9 fields at `columns="2"`, i.e. four or five visual rows. If UAT finds that
 * too dense, the remedy is `_isOpen = false` by default — a one-line change — NOT dropping fields.
 * Every field on it is named in FSD §18.2's "Data Captured" table or was already rendered here.
 *
 * ── KNOWN INTERACTION, accepted (no code change available) ────────────────────
 * Pressing Sync while an inline edit is open in this card's own `lightning-record-form` may discard
 * the unsaved draft, because the write re-emits the record through the LDS cache and the form
 * re-renders from it. This is inherent to the `lightning-record-form` approach: the form exposes no
 * dirty state, so there is nothing for this component to gate the click on.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 3. ONE BUNDLE SERVES BOTH SOURCES — AND A SECOND ONE WAS BUILT AND DELETED
 * ═════════════════════════════════════════════════════════════════════════════
 * ARCHITECTURE.md §5 records that `c/transactionAdvanceStage` was created and DELETED the same day
 * (2026-08-12, code review W3, user decision) for being byte-identical to `c/advanceRecordStage`
 * below the comments, and states the governing rule: "a copy carrying only a different header is
 * not a split — it is a second file that must now receive every fix the first one gets, with
 * nothing but review to notice when it does not."
 *
 * Placer and CoStar differ in DATA (a title, a field list, a stamp field, help text). They do not
 * differ in BEHAVIOUR — and the 2026-08-17 change made them differ in MORE data and no more
 * behaviour, which strengthens the case rather than weakening it. So there is one bundle,
 * parameterised by the `source` design property and `CONFIG_BY_SOURCE` below — the same shape as
 * `advanceRecordStage`'s server-side `CONFIG_BY_TYPE`, moved to the client because here the
 * variation is presentational rather than transactional.
 *
 * A third vendor is ONE MAP ENTRY plus a component instance on the FlexiPage. If a future source
 * ever needs genuinely different BEHAVIOUR, split THAT one into its own bundle — and note that
 * "its own bundle" means a bundle that DIFFERS.
 *
 * ⚠ The field API names arrive as `@salesforce/schema/...` imports, never as free-form strings.
 * That is the load-bearing half of the decision: a renamed or deleted field becomes a BUILD-TIME
 * failure instead of a card that deploys green and renders empty. A `fieldNames` design property
 * taking comma-separated API names was considered and rejected for exactly that reason. It matters
 * more at nineteen imports than it did at six.
 *
 * ⚠ `Market_Rent_PSF__c` carries NO `CoStar_` prefix while its eight siblings do. It is the FSD's
 * CoStar "Market Rent (PSF)" and it is NOT a typo: ARCHITECTURE §1 rule 5 requires a per-unit rate
 * to suffix the unit, and the field predates the CoStar block. It is not renamed because an in-place
 * field rename is a Metadata-API no-op and the only mechanism is delete-and-recreate, against a
 * field referenced by `MarketDataSnapshotService`, three permission sets and probably reports. The
 * live cost is that a prefix-based audit of "the CoStar block" MISSES IT; rendering it inside this
 * card's CoStar section is half the mitigation and its `<description>` is the other half. Do not
 * drop it from the list because a grep did not find it.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 4. THE WRITE IS LDS `updateRecord`, SO `getRecordNotifyChange` IS FORBIDDEN
 * ═════════════════════════════════════════════════════════════════════════════
 * `updateRecord` writes THROUGH the LDS cache, so this card, the record page and every other
 * component on it re-render on their own. Calling `getRecordNotifyChange` here would be redundant
 * at best. This is the `c/leadStatusChange` rule. ⚠ It is UNCHANGED by the move to `Property__c`:
 * the target record moved, the MECHANISM did not.
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
 * pull a Lead permission Apex dependency into a card that has no Apex at all.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 5. NO PERMISSION GATE — DELIBERATELY, AND `Property__c` FLS IS THE GATE
 * ═════════════════════════════════════════════════════════════════════════════
 * No custom permission and no FlexiPage `<visibilityRule>`. There is no privileged operation to
 * guard: the button's entire effect is writing one DateTime that any user with FLS edit can
 * already type by hand. Contrast the three stage-action gates, every one of which guards a record
 * moving through a business process under server-side logic.
 *
 * ⚠ THE GATE MOVED OBJECTS WITH THE WRITE. It is FLS edit on `Property__c.<source>_Last_Synced_
 * DateTime__c`, read from `getObjectInfo` for `Property__c` — NOT for `Opportunity`. A version of
 * this class still reading `Opportunity` object info would compile, deploy, render and gate on the
 * wrong object's field entirely. It is already modelled: `DPEG_Acquisition_Edit` grants these
 * fields editable, `DPEG_Acquisition_View` and `DPEG_Property_View` grant them read-only. So a View
 * persona gets a read-only card and an Edit persona a working button, at zero new metadata.
 *
 * What this class does instead of a gate: it reads the stamp field's `updateable` flag and renders
 * the button DISABLED WITH A REASON — never hidden silently, and never left to throw on click. It
 * FAILS CLOSED: until the object info has arrived the button is disabled.
 *
 * 🔴 A `<visibilityRule>` bound to a FIELD must never be used to hide this button. ARCHITECTURE
 * records it as measured twice: such a rule evaluates FALSE for anyone lacking FLS READ on that
 * field, with no error and no log, so the control vanishes for users who are genuinely authorized.
 * That defect is why the whole `User.*_Driver__c` model was retired.
 *
 * ⚠ `DPEG_Admin_Access` grants none of these fields, exactly as it granted none of the Opportunity
 * ones. A bare administrator therefore sees an access-restricted card. That is the EXPECTED result
 * of the sibling rule, not a defect — and it is why an admin smoke test proves nothing here.
 */

/** Fallback when an LDS error carries nothing readable. Never let `undefined` reach a toast. */
const GENERIC_ERROR =
    'The sync timestamp could not be saved. Please try again or contact your administrator.';

/** Shown beside a disabled button when the running user cannot edit the stamp field. */
const NO_EDIT_ACCESS_MESSAGE =
    'You do not have edit access to this field, so it cannot be stamped.';

/**
 * Shown IN THE CARD BODY, and again beside the disabled button, when the deal has no linked
 * Property.
 *
 * 🔴 It states a FACT and a REMEDY, and it names neither a fault nor a cause. A deal without a
 * Property is what a manually-created deal looks like — only `LeadConvertService` links one — so the
 * user reading this has done nothing wrong and can fix it themselves.
 */
const NO_PROPERTY_MESSAGE =
    'No property is linked to this deal, so there is no market data to show. Link a property to the deal to see its Placer and CoStar data.';

/**
 * The SHORT form of the same fact, rendered beside the disabled button and in its tooltip.
 *
 * ⚠ A DELIBERATE, MINOR DIVERGENCE FROM THE DESIGN, which asked for "the same reason text beside
 * it". Rendering NO_PROPERTY_MESSAGE twice would print one 135-character sentence twice on a card
 * that, in this state, contains almost nothing else — the remedy sentence in particular reads as an
 * instruction the second time, not a reason. The requirement the design was protecting is that the
 * button is never HIDDEN and never refuses without saying why; both hold. The two strings say the
 * same thing at two lengths and must not drift apart.
 */
const NO_PROPERTY_REASON = 'There is no linked property to stamp.';

/** Rendered when the Last Synced field has never been stamped on this Property. */
const NEVER_SYNCED_LABEL = 'Never';

/**
 * Rendered when a record wire failed, most plausibly because the running user has no FLS READ on
 * the stamp field, or no access to the Property at all.
 *
 * ⚠ It is a SEPARATE state from `Never`, deliberately. Collapsing them would tell a user with no
 * read access that the property has never been synced — a confident wrong answer, where "not
 * available" is a true one. That distinction is the whole reason both record wires' error branches
 * are tracked at all rather than being allowed to fall through to the empty case.
 *
 * ⚠ It is ALSO a separate state from "no property linked" — see NO_PROPERTY_MESSAGE. A failed read
 * means we do not know whether a property exists; a null lookup means we know one does not.
 */
const UNAVAILABLE_LABEL = 'Not available';

/**
 * Rendered in the Last Synced row while a record wire is still in flight: an em-dash, and
 * `aria-hidden` in the template so a screen reader is told nothing rather than told a dash.
 *
 * 🔴 IT MUST NOT BE `Never`. Before the first emit this component does not know whether the property
 * has been synced, and `Never` is an ASSERTION — the same confident-wrong-answer defect that
 * `UNAVAILABLE_LABEL` exists to prevent on the error branch, that the three-state access gate
 * prevents on the button, and that `_dealLoaded` prevents on the no-property note. All four are the
 * same rule: say nothing until you know.
 */
const LOADING_LABEL = '—';

/**
 * The ONE field read from the Opportunity: the Property lookup Id.
 *
 * 🔴 A module-level constant, not a getter. A wire config rebuilt on every render re-invokes the
 * adapter; a stable array reference does not. It is also deliberately ONE field — widening this
 * list would make every deal's card depend on FLS for whatever was added, and a `WITH USER_MODE`-
 * style refusal here disables the whole card rather than one row.
 */
const DEAL_FIELDS = [OPPORTUNITY_PROPERTY_FIELD];

/**
 * Everything that differs between the two cards. Nothing else in this class knows a vendor name.
 *
 * 🔴 THE FIELD ORDER IS THE FSD §18.2 ORDER — Layer 1 link, then the Layer 2 metrics, then the
 * control fields — with the one INCUMBENT field of each card slotted in beside its own kind
 * (`Monthly_Visits__c` after the Placer ranks, `Market_Cap_Rate__c` beside the exit cap). Both
 * incumbents are what the DEPLOYED cards render today; dropping either inside a change whose stated
 * purpose is to show MORE data would be a silent regression. Rendering `metricFields` then
 * `controlFields` reproduces that one FSD order across the two forms, which is why the split below
 * costs nothing visually.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 WHY `metricFields` AND `controlFields` ARE TWO LISTS AND NOT ONE (2026-08-17, code review C2)
 * ═══════════════════════════════════════════════════════════════════════════
 * `metricFields` render in a `mode="view"` form — inline-editable, because a human typing the
 * numbers IS the data entry mechanism until an ASB spoke exists. `controlFields` renders in a SECOND
 * form at `mode="readonly"`, so its contents are VISIBLE and NOT hand-editable.
 *
 * ⚠ `controlFields` HOLDS EXACTLY ONE FIELD PER SOURCE — `<source>_Fetch_Status__c`. A list of one
 * is not an accident and must not be "simplified" into a scalar or folded back into `metricFields`:
 * it is the seam the second form binds to, and the C2 argument below applies to whatever is in it.
 *
 * THE REASON, AND IT IS ABOUT THE FIELD THAT REMAINS:
 *
 *   🔴 A HAND-EDITABLE `Sync Status` CONTRADICTS THE BUTTON DIRECTLY BELOW IT. Press Sync → the
 *   toast says "marked as synced" → `Last Synced (manual)` updates → and `Sync Status` ONE ROW AWAY
 *   still reads `Not Synced`, because nothing writes it and nothing should. A user will very
 *   reasonably "correct" that to `Success` — and `Not Synced` is the ONLY truthful in-record signal
 *   that no fetch ever happened, which is precisely why the seed writes it and refuses to write
 *   `Success`. An editable picklist there does not merely permit the lie; it INVITES it, and the
 *   person who types it will believe they are fixing a bug.
 *
 * ⚠ `mode="readonly"` is NOT a permission control and must not be described as one. FLS is still the
 * only real gate; a user with edit access can change this field from the Property record page or a
 * list view. What this removes is the INVITATION — the pencil sitting beside a value that contradicts
 * the button — which is the actual failure mode. Do not "simplify" the two forms back into one.
 *
 * ── 🔴 `<source>_Data_Source__c` IS DELIBERATELY *NOT* ON THESE CARDS (user decision, 2026-08-17) ──
 * Both `*_Data_Source__c` fields WERE rendered here, in this same readonly form, for part of one day.
 * The user removed them after seeing the cards: *"there is no need to add datasource field."*
 * **The FIELDS still exist on `Property__c` and are untouched** — no metadata change, no FLS change;
 * they are owned by another workstream and ARCHITECTURE §1 describes them as PROVENANCE LABELS whose
 * flip to `Integrated` is post-deploy gate G9. Only the RENDERING is gone.
 *
 * ⚠ So "every FSD §18.2 field appears on the card" — true earlier today — is NO LONGER TRUE, and the
 * exception is exactly these two. Do not re-add them to "complete the block": their absence is a
 * decision, and the second reason C2 originally gave for the readonly form (that an editable
 * `Data_Source__c` puts gate G9 one inline edit away) is now moot HERE because the field is not
 * rendered at all — a stronger outcome than read-only, not a weaker one.
 *
 * ⚠ `<source>_Fetch_Status__c` STAYS, and the asymmetry is the point: Data Source describes where a
 * value CAME FROM, which nobody is asking this card, while Sync Status is the one honest in-record
 * statement that nothing has actually synced — sitting beside a button that says it did.
 *
 * 🔴 THE STAMP FIELD IS IN NEITHER LIST. It is rendered by this component as the bespoke
 * "Last Synced (manual)" row, which carries mitigation (a), mitigation (b) and the three-state
 * Never / Not available / em-dash rendering. A `lightning-record-form` field would render a bare
 * timestamp under the field's own label and silently delete all three.
 *
 * `helpText` is mitigation (b) of the stub warning in section 1 and is NOT optional decoration — it
 * is the only place the UI states, in words, that the figures above it are hand-entered, that they
 * live on a shared Property record (section 2's cost 1), AND — since code review C2 — that Sync
 * Status describes an integration that does not exist and that Sync does not touch it. That last
 * clause is the other half of remedy C2: the readonly form stops the edit, the sentence explains why
 * the row does not move. ⚠ IT NAMES SYNC STATUS ONLY. It named Data Source too until that field was
 * dropped from the card the same day; help text describing a field the reader cannot see is the
 * stale-text defect this bundle has already been bitten by twice. Keep it explicit per source rather
 * than composing it from `title`, so that a source whose truth changes (a real integration for one
 * vendor and not the other) can say so on its own.
 */
const CONFIG_BY_SOURCE = {
    Placer: {
        title: 'Placer',
        metricFields: [
            PLACER_URL_FIELD,
            PLACER_STATE_RANK_FIELD,
            PLACER_STATE_PERCENTILE_FIELD,
            PLACER_MSA_RANK_FIELD,
            PLACER_NATIONAL_RANK_FIELD,
            MONTHLY_VISITS_FIELD
        ],
        controlFields: [PLACER_FETCH_STATUS_FIELD],
        stampField: PLACER_LAST_SYNCED_FIELD,
        helpText:
            'Recorded when a user pressed Sync. There is no connection to Placer.ai yet, so the values above are entered by hand and may be out of date. They are stored on the linked Property record, so every deal on that property shares them. Sync Status describes an integration that does not exist yet; Sync does not change it.',
        successMessage: 'Placer marked as synced.'
    },
    CoStar: {
        title: 'CoStar',
        metricFields: [
            COSTAR_URL_FIELD,
            COSTAR_PCT_LEASED_FIELD,
            COSTAR_LOCATION_SCORE_FIELD,
            COSTAR_ASKING_RENT_PSF_FIELD,
            MARKET_RENT_PSF_FIELD,
            COSTAR_EXIT_CAP_RATE_FIELD,
            MARKET_CAP_RATE_FIELD
        ],
        controlFields: [COSTAR_FETCH_STATUS_FIELD],
        stampField: COSTAR_LAST_SYNCED_FIELD,
        helpText:
            'Recorded when a user pressed Sync. There is no connection to CoStar yet, so the values above are entered by hand and may be out of date. They are stored on the linked Property record, so every deal on that property shares them. Sync Status describes an integration that does not exist yet; Sync does not change it.',
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
 * Reading only `body.message` surfaces the generic text and DROPS the actionable one. See section 4
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
    /**
     * The OPPORTUNITY Id, set by the record page.
     *
     * ⚠ It is NOT what the form renders and NOT what the Sync button writes — both target the
     * PROPERTY resolved from it. See header section 2.
     */
    @api recordId;

    /**
     * Which market-data source this instance renders. Design property; one of the CONFIG_BY_SOURCE
     * keys. Defaults to `Placer` so a component dropped in App Builder renders something real
     * rather than an error, matching the default declared in the .js-meta.xml.
     */
    @api source = 'Placer';

    /** The deal's `Property__c` lookup value, once the Opportunity wire has answered. */
    _propertyId;

    /** True once the Opportunity wire has answered AT ALL — data or error. */
    _dealLoaded = false;

    /** True once the Opportunity wire has reported a failure. */
    _dealWireFailed = false;

    /** The last Property `getRecord` payload. The Last Synced row is derived from THIS, never from a
     * local copy written after a successful save — see `lastSynced`. */
    _propertyRecord;

    /** True once the Property wire has reported a failure (e.g. no FLS read on the stamp field). */
    _propertyWireFailed = false;

    /**
     * True once the Property wire has answered AT ALL — data or error.
     *
     * Distinct from `_propertyRecord` being set, because "no record yet" and "a record with a null
     * stamp" are different facts that would otherwise render identically. See LOADING_LABEL.
     */
    _propertyLoaded = false;

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
     *
     * ⚠ `role="alert"` is reserved for THIS state. The no-property note is `role="status"` — see
     * NO_PROPERTY_MESSAGE and header section 2.
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
     * `getObjectInfo` wire uses, rather than a `"Property__c"` string literal in the template.
     *
     * Consistent with this bundle's own stated reason for importing schema at all: a compile-time
     * reference cannot silently disagree with the wire beside it. `lightning-record-form` accepts an
     * object reference as well as a string.
     *
     * ⚠ It is `Property__c`, NOT `Opportunity` — see header section 2 and section 5.
     */
    get objectApiName() {
        return PROPERTY_OBJECT;
    }

    /**
     * The FSD Layer-1/Layer-2 metrics, rendered in the `mode="view"` form and INLINE EDITABLE — a
     * human typing them is the data entry mechanism until an ASB spoke exists.
     *
     * Excludes the stamp field, which this component renders itself as the Last Synced row.
     */
    get metricFields() {
        return this.config ? this.config.metricFields : [];
    }

    /**
     * The provider CONTROL field — `<source>_Fetch_Status__c`, and since 2026-08-17 that is the ONLY
     * one — rendered in a SECOND form at `mode="readonly"`: visible, not hand-editable.
     *
     * See the CONFIG_BY_SOURCE header for the argument; the short version is that an editable
     * `Sync Status` contradicts the Sync button beside it, and `Not Synced` is the only truthful
     * in-record signal that no fetch has ever happened.
     *
     * ⚠ It stays a LIST although it holds one entry. The form binds `fields`, so a scalar would need
     * the template to wrap it; and `<source>_Data_Source__c` was in here earlier today, so a future
     * change adding or removing a control field is a one-line edit to config rather than a reshape.
     */
    get controlFields() {
        return this.config ? this.config.controlFields : [];
    }

    /**
     * The `fields` config for the Property record wire. `undefined` when unconfigured, which is how
     * an LWC wire is told not to fetch — LDS treats an incomplete config as invalid and emits
     * nothing.
     */
    get stampFieldList() {
        return this.config ? [this.config.stampField] : undefined;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The linked Property (header section 2)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The Id the form renders and the Sync button writes. `undefined` until the Opportunity wire has
     * answered, and permanently `undefined` for a deal with no Property.
     */
    get propertyId() {
        return this._propertyId;
    }

    /** True once a Property Id is in hand. Everything that reads the Property is gated on this. */
    get hasProperty() {
        return !!this._propertyId;
    }

    /**
     * True ONLY when the Opportunity wire has answered SUCCESSFULLY and carried a null lookup.
     *
     * 🔴 THREE TERMS, ALL LOAD-BEARING. `_dealLoaded` keeps the note silent while the wire is in
     * flight; `!_dealWireFailed` keeps it silent when the read was REFUSED (a refusal is not
     * evidence that no property exists — that branch degrades to `Not available` instead); and
     * `!_propertyId` is the fact itself. A `!this.propertyId` check written without the other two
     * would flash "no property linked" on every page load of every deal, and would state it
     * permanently for any user who cannot read the lookup.
     */
    get showNoProperty() {
        return this._dealLoaded && !this._dealWireFailed && !this._propertyId;
    }

    get noPropertyMessage() {
        return NO_PROPERTY_MESSAGE;
    }

    /**
     * The form is mounted ONLY with a real Id. `lightning-record-form` with a null `record-id`
     * renders a broken or empty form rather than nothing, so this is a guard against a visible
     * defect, not a tidiness rule.
     */
    get showForm() {
        return this.hasProperty;
    }

    /**
     * The Last Synced row is suppressed only in the no-property state, where there is no field to
     * read and `Never` would be an assertion about a record that does not exist.
     *
     * It IS rendered while the wires are in flight (as the em-dash) and when a read was refused (as
     * `Not available`) — in both of those states the row's own three-way rendering is the honest
     * answer.
     */
    get showLastSynced() {
        return !this.showNoProperty;
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

    /**
     * The Opportunity read, for ONE field: the `Property__c` lookup Id.
     *
     * Everything else this card does hangs off the Id this produces, which is why the read is kept
     * as narrow as it can possibly be — one field, so the smallest possible FLS surface.
     */
    @wire(getRecord, { recordId: '$recordId', fields: DEAL_FIELDS })
    wiredDeal({ data, error }) {
        if (data) {
            const resolved = getFieldValue(data, OPPORTUNITY_PROPERTY_FIELD);
            // 🔴 RESET THE PROPERTY STATE WHEN THE ID MOVES. The second wire refetches on its own,
            // but until it answers `_propertyRecord` still holds the PREVIOUS property's stamp —
            // which would render one property's Last Synced beside another's data. Clearing here
            // returns the row to the em-dash, i.e. to "we do not know yet", which is true.
            if (resolved !== this._propertyId) {
                this._propertyRecord = undefined;
                this._propertyLoaded = false;
                this._propertyWireFailed = false;
            }
            this._propertyId = resolved;
            this._dealWireFailed = false;
            this._dealLoaded = true;
        } else if (error) {
            // 🔴 The Id is NOT cleared to `undefined` here on purpose — `_dealWireFailed` is what
            // downstream getters read, and it keeps `showNoProperty` false. A refused read is not
            // evidence that the deal has no property.
            this._dealWireFailed = true;
            // Set on BOTH branches: the flag means "the wire has answered", not "the wire succeeded".
            this._dealLoaded = true;
        }
    }

    /**
     * The PROPERTY read, for the stamp field only.
     *
     * ⚠ `recordId: '$propertyId'` is undefined until the deal wire answers, which LDS treats as an
     * incomplete config — so nothing is fetched and nothing is emitted until there is an Id.
     */
    @wire(getRecord, { recordId: '$propertyId', fields: '$stampFieldList' })
    wiredProperty({ data, error }) {
        if (data) {
            this._propertyRecord = data;
            this._propertyWireFailed = false;
            this._propertyLoaded = true;
        } else if (error) {
            this._propertyRecord = undefined;
            this._propertyWireFailed = true;
            this._propertyLoaded = true;
        }
    }

    /**
     * ⚠ `Property__c`, not `Opportunity`. The FLS gate moved with the write — header section 5.
     */
    @wire(getObjectInfo, { objectApiName: PROPERTY_OBJECT })
    objectInfo;

    // ─────────────────────────────────────────────────────────────────────────
    // Last Synced
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The stamp value, read from the LDS Property record.
     *
     * 🔴 IT IS DERIVED FROM THE WIRE, NOT FROM LOCAL STATE, AND THAT IS THE POINT. `handleSync`
     * deliberately does not assign the value it just wrote. Because `updateRecord` writes THROUGH
     * the LDS cache, the wire re-emits and this getter picks the new value up on its own — so what
     * the user reads is what the RECORD holds, not what the client believes it sent. Assigning it
     * locally would make the row show a timestamp even on a write the server silently altered or a
     * cache the platform later corrected, and would hide the very failure the error toast reports.
     * Pinned by J7.
     *
     * ⚠ The record this reads is the PROPERTY, which is also the record `handleSync` writes — so the
     * re-emit is the ordinary same-record one, with no spanning link in the path. The reason there
     * are two wires at all is blast radius, not invalidation; see the "WHY TWO getRecord WIRES" note
     * in header section 2 before deleting one.
     */
    get lastSynced() {
        if (!this.config || !this._propertyRecord) {
            return undefined;
        }
        return getFieldValue(this._propertyRecord, this.config.stampField);
    }

    get hasLastSynced() {
        const value = this.lastSynced;
        return value !== undefined && value !== null && value !== '';
    }

    /**
     * True when EITHER record could not be read — see UNAVAILABLE_LABEL.
     *
     * Both wires count: a refused Opportunity read and a refused Property read are equally "we do
     * not know", and neither is evidence that the property has never been synced.
     */
    get lastSyncedUnavailable() {
        return this._dealWireFailed === true || this._propertyWireFailed === true;
    }

    /**
     * True while the Property wire has not answered yet — see LOADING_LABEL. Covers the window
     * before the deal wire answers too, since the Property wire cannot even be configured until then.
     *
     * The `!lastSyncedUnavailable` term states the intended precedence, so a future edit that stops
     * setting a loaded flag on an error branch degrades to "unknown" rather than silently back to
     * "Never".
     */
    get lastSyncedPending() {
        return !this._propertyLoaded && !this.lastSyncedUnavailable;
    }

    get loadingLabel() {
        return LOADING_LABEL;
    }

    get emptyLastSyncedLabel() {
        return this.lastSyncedUnavailable ? UNAVAILABLE_LABEL : NEVER_SYNCED_LABEL;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Access — FLS edit on the Property stamp field is the gate (header section 5)
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

    /**
     * FAIL CLOSED, on TWO independent grounds: anything other than a known-true `updateable`
     * disables the button, and so does the absence of a Property to write to.
     *
     * The second term also covers the in-flight window, where `hasProperty` is false because the
     * answer has not arrived — which is correct, since a click then would have nothing to write.
     */
    get syncDisabled() {
        return this.stampFieldUpdateable !== true || !this.hasProperty;
    }

    /**
     * A reason is rendered only for a KNOWN cause. Two exist, and no-property wins because it is the
     * one the user can act on — an FLS grant on a stamp field is moot while there is no record to
     * stamp.
     */
    get showDisabledReason() {
        return this.showNoProperty || this.stampFieldUpdateable === false;
    }

    get disabledReason() {
        return this.showNoProperty ? NO_PROPERTY_REASON : NO_EDIT_ACCESS_MESSAGE;
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
        return this.showDisabledReason ? this.disabledReason : '';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Action
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Stamps the source's Last Synced field ON THE PROPERTY. NOTHING ELSE HAPPENS — see header
     * section 1.
     *
     * 🔴 THE WRITE TARGET IS `this._propertyId`, NEVER `this.recordId`. Writing the Opportunity twin
     * would put the numbers and their freshness marker on two different records: two deals on one
     * property would then show ONE dataset under TWO different "Last Synced" values, and the card
     * would itself become the source of the confusion ARCHITECTURE §5 already warns about. It would
     * also permanently desynchronise the card from `MarketDataSnapshotService`, which freezes the
     * PROPERTY timestamp into the approval evidence.
     *
     * The guard is defence in depth, not decoration: `disabled` on a button is a UI affordance, and
     * a click can still reach a handler (it does in Jest, and it can through assistive tooling), so
     * the refusal is expressed in code as well as in markup.
     *
     * 🔴 No `getRecordNotifyChange` (header section 4). 🔴 No spinner and no busy state (section 1c).
     */
    async handleSync() {
        const config = this.config;
        if (!config || this.syncDisabled) {
            return;
        }

        const fields = {};
        fields.Id = this._propertyId;
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
