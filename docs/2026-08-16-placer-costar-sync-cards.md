# Placer & CoStar Sync Cards (Opportunity Detail Tab)

**Date:** 2026-08-16
**Author:** Documentation Agent
**Status:** Code complete and verified in the working tree — three custom fields, three permission-set
grants, one FlexiPage edit, one LWC bundle (12 Jest test blocks / several `it.each` variants), all
present on disk and cross-checked against the design. No standalone `agent-output/*-code-review.md`
exists for this pass; the review record lives as W1–W3 / S1–S6 labels directly in the component's own
class header and test file comments (this repo's established convention — see `marketDataSync.js` and
`marketDataSync.test.js`). Deploy status to `usman-dpeg` is not evidenced in this document — verify
separately before treating this as live.
**Design source:** `agent-output/design-requirements-placer-costar-sync.md`.
**Related:** `ARCHITECTURE.md` §5 (three new subsections added in the same change — *Parameterised
record-page cards*, *The LDS-write / no-`getRecordNotifyChange` pairing extends to rendered cards*,
*FLS as the gate, where there is no privileged operation*).

---

## Overview

### Original request

> "Now we have to create placer and costar sections under detail, our existing sections of placer and
> costar will be removed. We need to keep the design same just like we have right now, but in lwc we
> need to show a button which will be a sync button. We will show last synced value as well along with
> the other fields."

### Business objective

The Opportunity Detail tab already showed two lonely single-field sections labelled "Placer" and
"CoStar" — one held only `OneDrive_Folder_URL__c` (a document link with nothing to do with Placer.ai),
the other held `CoStar_URL__c`. Deal teams wanted these turned into real vendor cards: a proper field
group per source, plus a visible "when was this last checked" marker and a button to refresh that
marker. No Placer.ai or CoStar integration exists anywhere in this application, so the request was
scoped, at Gate 1, to a UI and data-model change only — not a new integration.

### Summary

Two cards — **Placer** and **CoStar** — now render on the Opportunity record page's Detail tab,
replacing the two single-field sections. Both are rendered by **one** LWC bundle, `c/marketDataSync`,
parameterised by a `source` design property (`Placer` | `CoStar`). Each card shows its source's
fields, a `Last Synced (manual)` row, and a **Sync** button. Three new `Opportunity` DateTime/Number
fields back this, FLS is granted in the same three permission sets that already carry the sibling
Placer/CoStar/Market-Cap fields, and the FlexiPage's Detail tab was edited to remove the two old
sections, insert the two new component instances, and relocate two fields that were sitting in the
wrong place (`Market_Cap_Rate__c` into the CoStar card, `OneDrive_Folder_URL__c` back into
`Acquisition Deal Details`, where the page layout already puts it).

### 🔴 The single most important fact about this feature

**Pressing Sync contacts nothing.** It stamps a DateTime on the Opportunity and does nothing else — no
callout, no ASB spoke, no Named Credential, no data refresh. **There is no Placer.ai or CoStar
integration in this application, and this feature does not create one.**

This is a **deliberate Gate-1 decision by the user**, not an incomplete build. The design offered two
real alternatives — a callout through an ASB spoke, and a direct vendor callout — and both were
declined: the first because no ASB spoke for Placer/CoStar exists to route to, and the second because
it would have been the **third** standing exception to §3.1's ASB-only rule (after the OpenAI and
Microsoft Graph exceptions already recorded in `ARCHITECTURE.md` §3.3/§3.4), which the document already
flags as the point at which the rule itself, not another exception, is owed a review.

The consequence is real and is stated here in plain terms because it is the thing a future reader is
most likely to miss: **a user reading "Last Synced: today" will reasonably conclude the Monthly
Visits and Market Cap Rate figures beside it were retrieved today. They were typed by hand, possibly
months ago.** The button label `Sync` was accepted by the user **conditional on three mitigations
holding simultaneously** — see *Key Design Decisions* below. If any one of them is ever removed, the
label must change with it (the design's fallback recommendation is `Mark Synced`).

---

## Key Design Decisions and Rationale

### D1 — `Market_Cap_Rate__c` moves into the CoStar card; its old rendering is removed, not duplicated

`Opportunity.Market_Cap_Rate__c` is Percent(5,2). Its `Property__c` twin's description reads *"CoStar
via ASB (stub)"*, which is what made it the CoStar card's natural occupant. The design considered
leaving the old FlexiPage rendering in place (either editable, producing two editable controls for one
field on one screen, or read-only, which would read as "the integration owns this field" — false, and
worse than duplication) and rejected both.

**Why removing the duplicate matters more than it looks:** the Sync button and the `Last Synced` row
are an assertion *about the value in that card*. If the same field stayed editable elsewhere on the
tab with no freshness signal attached, a user could overwrite it in that other location and then read
a timestamp in the card describing a value they themselves just replaced. Removing the duplicate
rendering is what makes the card's claim about its own contents true.

**Scope was kept narrow on purpose:** only the *FlexiPage field instance* was removed. The field stays
on `Opportunity-Opportunity Layout.layout-meta.xml` (Classic, compact layout, any other consumer) and
none of its six existing `<fieldPermissions>` grants were touched. Confirmed in the working tree:
`Opportunity.Market_Cap_Rate__c` now has exactly one FlexiPage instance in the whole application — the
one implicit inside the CoStar `c/marketDataSync` component (rendered via `@salesforce/schema` import,
not a FlexiPage `fieldItem`).

**Stated cost:** the cap-rate comparison triple (`Guidance_Cap_Rate__c`, `My_Cap_Rate__c`,
`Market_Cap_Rate__c`) is now split across the tab — two stay in the deal-economics section, one moves
into the CoStar card. If a reviewer wants them side by side again, the design's guidance is to revisit
the Gate-1 field set, not to reintroduce a second rendering of the same field.

### D2 — `OneDrive_Folder_URL__c` goes back to `Acquisition Deal Details`

It was, incorrectly, the only field in the org's old "Placer" section — a document-folder link with no
relationship to Placer.ai. It has been moved into `Acquisition Deal Details`, exactly where the repo's
own page layout already places it, immediately above `Placer_URL__c`/`CoStar_URL__c`. It is **not
dropped** — confirmed present in the FlexiPage's `Acquisition Deal Details` field facet.

One flag carried over from the design and not addressed by this change: `Property__c.SharePoint_Folder_URL__c`
is the *automated* deal-folder URL written by `DealFolderService` (see `ARCHITECTURE.md` §1).
`Opportunity.OneDrive_Folder_URL__c` is a separate, hand-keyed legacy field with no writer. The two
will diverge over time; that is out of scope here.

### D3 — three new fields, and why the `_DateTime__c` suffix is not stylistic

All three fields live on `Opportunity` (Gate-1 decision). Naming follows `ARCHITECTURE.md` §1 exactly,
and two of its rules directly forbid the obvious shorter name:

- **Rule 6** bans a `Date` suffix on a DateTime field and requires `DateTime` for date+time fields.
- **Rule 4** reserves the `<Subject>_<PastParticiple>` form for **Booleans** — so
  `Placer_Last_Synced__c` would read as a checkbox, exactly the shape §1's own repair migrated away
  from elsewhere in this schema (`Untouched__c` → `Is_Untouched__c`, `Never_Expires__c` →
  `Is_Non_Expiring__c`).

`Placer_Last_Synced_Date__c` is therefore prohibited by rule 6, and `Placer_Last_Synced__c` is
prohibited by rule 4 — `Placer_Last_Synced_DateTime__c` is the only compliant form, and rule 9's
type-suffix-discipline prohibition ("a field name must not assert a type the field does not have") is
what resolves the collision between the two.

`Monthly_Visits__c` deliberately matches `Property__c.Monthly_Visits__c` (Number(18,0)) API-name for
API-name, rather than picking a different name to avoid confusion — the design judged that naming the
Opportunity twin differently would be a worse outcome than the two sharing a name (see Known
Limitations, "two `Monthly_Visits__c` fields").

| API name | Label | Type | Precision/Scale | Required |
|---|---|---|---|---|
| `Opportunity.Monthly_Visits__c` | Monthly Visits | Number | 18, 0 | false |
| `Opportunity.Placer_Last_Synced_DateTime__c` | Placer Last Synced | DateTime | n/a | false |
| `Opportunity.CoStar_Last_Synced_DateTime__c` | CoStar Last Synced | DateTime | n/a | false |

All three carry a `<description>` stating plainly that the field is manually entered and that no live
vendor connection exists — so a future report builder or developer reading the schema (not just the
UI) sees the same warning.

### 🔴 No status field — argued, not omitted

The brief invited a status field alongside the timestamp. The design recommends against building one,
and the recommendation was followed: `Property__c.Placer_Fetch_Status__c` is a **restricted** picklist
with values `{Success, Error}`, and a stub that contacts nothing can only ever write `Success`. A
restricted two-value picklist with exactly one reachable value is not a status — it is a constant
wearing a picklist, and its presence would be the single most effective way to make a stub look like a
working integration. There is also nothing genuine to record as `Error`: the only failure this
component can hit is an LDS write refusal, which is already surfaced as a toast and leaves the
timestamp unchanged — the unchanged timestamp *is* the signal. When a real callout eventually lands,
a status field modelled on the `Property__c` twin ships in the same change as the callout, never
ahead of it.

### D4 — one LWC bundle, not two, and why that rule exists in this repo already

`ARCHITECTURE.md` §5 already records that `c/transactionAdvanceStage` was built and **deleted the same
day** (2026-08-12, code review W3) for being byte-identical to `c/advanceRecordStage` below the
comments — "a copy carrying only a different header is not a split." Placer and CoStar differ in
**data** (a title, an icon, a field list, a stamp field) and not in **behaviour**, so this feature is
one bundle, `c/marketDataSync`, keyed by a `source` design property against a module-level
`CONFIG_BY_SOURCE` map — the client-side mirror of `advanceRecordStage`'s server-side `CONFIG_BY_TYPE`
precedent, extended for the first time from a headless quick action to a *rendered* component.

**Field API names arrive as `@salesforce/schema/...` imports, never as free-form strings.** A
comma-separated `fieldNames` design property was considered and rejected: a renamed or deleted field
under that approach would deploy green and simply render an empty card, whereas the schema-import
approach turns the same mistake into a **build-time** failure. It also keeps the component from being
droppable on any arbitrary object, which the design treats as a governance property worth keeping.

Because a `targetConfig` `<property>` cannot be constrained to an enum, the component validates
`source` against the map's own keys at runtime and renders a visible inline `role="alert"` naming the
accepted values when it misses — case-sensitive and exact. A silently empty card would be
indistinguishable from "this deal has no market data", which `ARCHITECTURE.md` names as the same trap
`DealFolderSweepBatch`'s all-zeros summary falls into. The Jest suite (`J3`) covers an unknown vendor,
a blank source, and — specifically — a case typo (`"placer"` vs `"Placer"`), since the lookup is exact.

### D5 — LDS `updateRecord`, not Apex, and the guard-rail this choice forces

The write is a single-record update of one field on the record already in view — exactly LDS's first
priority per `ARCHITECTURE.md` §5's *Data Access Priority*. Choosing Apex here would have required a
controller, a service (a controller may hold no logic per `.claude/rules/apex-layering-rule.md`), a
selector for any SOQL, an `AuraHandledException` boundary, a 90%+-covered test class, and a
`classAccesses` entry in a capability set — five artefacts to perform one field write the platform
already expresses in a single call. **Zero Apex was written for this feature.**

**The consequence this choice carries is the one place a future "fix" is most likely to introduce a
real regression, so it is stated twice (here and in the code):**

- `updateRecord` writes **through** the LDS cache, so the record page and every other component on it
  re-render on their own. `getRecordNotifyChange` **must not** be called — the `c/leadStatusChange`
  rule.
- This is the **exact opposite** of the `c/dealActionGuard` / `c/recordStageGuard` rule, which applies
  only to imperative Apex DML happening *behind* LDS's back, where `getRecordNotifyChange` **must** be
  called.

The Jest suite's `J6` is the permanent falsifier: it asserts `getRecordNotifyChange` is **never**
called, on both the success and error paths, and its own comment states it exists specifically because
"this repo has four bundles that MUST call it, and someone reading them will reasonably 'fix' this
component by analogy." When the real integration lands and the write moves to Apex, `J6` **inverts**
(asserts the call *is* made) rather than being deleted.

**Error handling copies `c/leadStatusChange`'s reducer, not `c/dealActionGuard`'s.** An LDS write
failure surfaces at `error.body.output.errors[]` and `error.body.output.fieldErrors{}`, and
`error.body.message` is frequently the platform's generic, unhelpful summary line — reading only
`body.message` (correct for `c/dealActionGuard`'s Apex path) would tell a user to retry a problem
retrying can never fix. The component's `messageFor()` walks `output.errors` → `output.fieldErrors` →
`body.message` → a fixed fallback constant, in that order, and does so as a local copy rather than an
import — `c/leadStatusChange` is Lead-bound by contract (it imports `Lead.Status` schema and
`LeadActionPermissionController`), so importing from it would have pulled a Lead-specific Apex
dependency into an Opportunity card with no Apex dependency at all. `ARCHITECTURE.md` §5 records that
this duplication was reviewed on 2026-08-16 and **deliberately deferred rather than rejected** — a
future shared `ldsErrorMessage` util in `c/utils` is the named remedy, to be done by whoever next edits
either reducer.

### D6 — no permission gate; FLS on the stamp field is the gate

No custom permission and no FlexiPage `<visibilityRule>` were added. The reasoning: there is no
privileged operation to guard. The button's entire effect is writing one field any user with FLS edit
could already type by hand — unlike the three stage-action gates
(`Acquisition_Deal_Actions`/`Disposition_Deal_Actions`/`Transaction_Stage_Actions`), every one of which
guards a record moving through a business process under server-side logic. FLS edit on the stamp field
is already exactly the right-shaped gate and is already modelled: `DPEG_Acquisition_Edit` grants
`editable=true`, `DPEG_Acquisition_View` and `DPEG_Opportunity_View` grant `editable=false` — so a View
persona gets a read-only card and an Edit persona gets a working button, with no new metadata and no
layer-4/layer-5 custom-permission placement decision to get wrong.

Instead, the component reads the stamp field's `updateable` flag off `getObjectInfo` and renders the
button **disabled with a visible reason** rather than hiding it or letting a click throw.
`ARCHITECTURE.md` records, twice, that a FlexiPage `<visibilityRule>` bound to a *field* evaluates
**false** for anyone lacking FLS read on that field — no error, no log, the control just silently
vanishes for a genuinely authorized user. That measured defect is why the whole
`User.*_Driver__c` model was retired elsewhere in this application, and this component was built to
avoid reproducing it.

**A finer point the code review sharpened (recorded as the general rule extracted into
`ARCHITECTURE.md` §5):** *a card must never assert a cause it has not established.* Three related
defects, all of that one shape, were found and fixed in this bundle during review:

1. A `getObjectInfo` **failure** was originally treated as "no edit access", which is not what a
   failed object-info read actually proves — it is more plausibly an object-access problem or a
   transient fault. Fixed: the access check is **three-state** (`true` / `false` / not-yet-known);
   the button *disables* for all three (fail closed), but the "you do not have edit access" reason
   text renders **only** for the confirmed-false state.
2. The `Last Synced` row rendered `Never` while the record wire was still loading — asserting, before
   the fact was known, that the deal had never been synced. Fixed (code review W2): a distinct
   loading placeholder (`—`, `aria-hidden`) renders until the wire answers; `Never` renders only once
   a real null value comes back.
3. A record-read failure (e.g. no FLS read on the stamp field) is rendered as `Not available`, kept
   deliberately distinct from `Never` — collapsing the two would tell a user with no read access that
   the deal has never been synced, a confident wrong answer where "not available" is the true one.

### D9 — "keep the design the same": the option chosen and its real cost

The design weighed three ways to satisfy "keep the design the same, but with a button and a Last
Synced value": read-only output fields (rejected — a functional regression, since every field here is
`behavior=Edit` on the layout today); `lightning-record-form mode="view"` with an explicit `fields`
list (**chosen** — renders platform-identical field rows *with* per-field inline-edit pencils, the
nearest available reproduction of a Dynamic Forms section, and preserves editing); and a hybrid of a
real `flexipage:fieldSection` plus a thin LWC strip for just the button (rejected — the only literally
pixel-identical option, but it contradicts "show last synced value along with the other fields" and
splits one card across two constructs).

**Stated cost of the chosen option:** the card's Save/Cancel bar belongs to the component, not to the
record page. A user editing a field in the card and a field in a neighbouring section sees two
separate Save affordances. This is inherent to any LWC built this way and is not treated as a defect.

Styling follows SLDS 2 tokens only (no hardcoded colours/spacing), the section heading mirrors a real
`fieldSection` header (`slds-section__title` / `slds-text-title_caps`), the `Last Synced` row renders
as a plain value via `lightning-formatted-date-time` — never a badge or coloured pill, because it is a
value and not a status — and the Sync button is `lightning-button variant="neutral"`, deliberately not
`brand`, because a brand button would assert a primacy this stub has not earned. The repo's `.lv-*`
list-view chrome convention was explicitly judged **not applicable** here — this is a field section,
not a list.

---

## Components Created

### Admin Components (Declarative)

#### Custom Fields

| Object | Field API Name | Type | Description |
|---|---|---|---|
| `Opportunity` | `Monthly_Visits__c` | Number(18,0) | Placer.ai monthly visit count for this deal. Manually entered — no live Placer.ai connection exists. Mirrors `Property__c.Monthly_Visits__c`; the two are not reconciled. |
| `Opportunity` | `Placer_Last_Synced_DateTime__c` | DateTime | Stamped by the Sync button on the Placer card. STUB — records when a user pressed the button, not when data was refreshed. |
| `Opportunity` | `CoStar_Last_Synced_DateTime__c` | DateTime | Stamped by the Sync button on the CoStar card. STUB — records when a user pressed the button, not when data was refreshed. |

No validation rules, no flows, no new permission sets, and no custom permissions were created.

#### Permission Sets (edited, not created)

| Permission Set | Change |
|---|---|
| `DPEG_Acquisition_Edit` | +3 `fieldPermissions`: all three new fields, `readable=true`, `editable=true` |
| `DPEG_Acquisition_View` | +3 `fieldPermissions`: all three new fields, `readable=true`, `editable=false` |
| `DPEG_Opportunity_View` | +3 `fieldPermissions`: all three new fields, `readable=true`, `editable=false` |

Confirmed in the working tree — all three grants present at the expected `readable`/`editable`
combinations.

**`DPEG_Admin_Access` was deliberately NOT touched.** Measured at design time: that set holds 49
`<fieldPermissions>` entries, of which 7 are Opportunity fields, and **none** of the existing
Placer/CoStar/Market-Cap sibling fields (`Placer_URL__c`, `CoStar_URL__c`, `Market_Cap_Rate__c`,
`OneDrive_Folder_URL__c`) is among them — so a bare System Administrator already could not see today's
Placer/CoStar fields before this change. Granting only the three *new* fields there would have made
the outcome strictly worse for that persona (a card showing a timestamp and nothing else), so the
sibling rule was followed instead: grant where the siblings already live, and nowhere else.

#### FlexiPage

| Page | Change |
|---|---|
| `Opportunity_Record_Page` | Detail tab: removed the `Placer` and `CoStar` `flexipage:fieldSection` blocks and their facet chains; removed the `Market_Cap_Rate__c` field instance; removed the `Placer_URL__c` field instance from `Acquisition Deal Details`; added two `marketDataSync` component instances (`placerSyncCard`, `costarSyncCard`); moved `OneDrive_Folder_URL__c` into `Acquisition Deal Details` |

Verified in the working tree: exactly two `marketDataSync` component instances exist (`source=Placer` /
`source=CoStar`), `Record.Market_Cap_Rate__c` no longer appears anywhere in the page as a `fieldItem`,
and `Record.OneDrive_Folder_URL__c` appears exactly once, inside `Acquisition Deal Details`. The 8
`{!$Permission.CustomPermission.Acquisition_Deal_Actions}` visibility criteria in the header region's
highlights panel — unrelated to this change and at risk only from a careless whole-file rewrite — are
still present and unchanged at 8.

### Development Components (Code)

#### Lightning Web Components

| Component | Location | Description |
|---|---|---|
| `c/marketDataSync` | `force-app/main/default/lwc/marketDataSync/` | One record-page card, parameterised by a `source` design property (`Placer` \| `CoStar`), rendering that source's fields, a `Last Synced (manual)` row, and a Sync button that stamps one DateTime field via LDS. Target: `lightning__RecordPage`, restricted to `Opportunity`. |

No Apex classes, triggers, or test classes were created — this feature has zero server-side code.

#### Jest Tests

| Test file | Coverage |
|---|---|
| `force-app/main/default/lwc/marketDataSync/__tests__/marketDataSync.test.js` | Both source configurations, the invalid-source alert state (including a case-typo variant), the write payload for each source, the `getRecordNotifyChange`-never-called falsifier (success and error paths), the success/error toast paths (validation-rule shape, field-error shape, array-body shape, unusable shape), the not-updateable / still-loading / failed-object-info access states, the stub-warning wording and no-spinner/no-busy-state guarantee, button variant, record-form mode, and four `@sa11y/jest` accessibility states |

`.claude/rules/bulk-test-rule.md`'s 251-record mandate is explicitly documented, in both the design and
the test file's own header, as **not applicable** — it governs triggers, batch jobs, DML-performing
services and queueables, and this feature has none of those (zero SOQL, zero server-side DML, zero
async context).

---

## Data Flow

### How it works

```
1. User opens an Opportunity record page → Detail tab.
2. Two c/marketDataSync instances render, one per source, each independently wired:
     - getObjectInfo(Opportunity)              → resolves the stamp field's `updateable` flag
     - getRecord(recordId, [stampField])       → resolves the current Last Synced value
3. lightning-record-form (mode="view") renders that source's field list directly from LDS —
   no wire code of this component's own; the platform's own inline-edit pencils remain live.
4. User clicks Sync (only reachable if the stamp field's `updateable` flag resolved true):
     - updateRecord({ fields: { Id, <stampField>: <client ISO timestamp> } })
     - NOTHING ELSE HAPPENS. No callout. No Apex. No ASB. No vendor contacted.
5. On success:
     - a success toast fires
     - updateRecord writes THROUGH the LDS cache, so getRecord's wire re-emits on its own
     - the Last Synced row re-renders from the REFRESHED RECORD, never from a locally-held
       "value I just sent" — this is what keeps the row honest if the server ever alters or
       rejects part of the write
6. On failure:
     - an error toast fires, built from output.errors -> output.fieldErrors -> body.message
       -> a fixed fallback, in that order
     - the Last Synced row is untouched (it still reflects whatever the record last held)
```

### Architecture diagram

```
┌───────────────────────────────┐
│  Opportunity Record Page       │
│  (Detail tab)                  │
└───────────────┬────────────────┘
                │  two instances, source="Placer" / source="CoStar"
                ▼
┌────────────────────────────────────────────────────────────┐
│                     c/marketDataSync                        │
│                                                              │
│   CONFIG_BY_SOURCE[source] → title, icon, fields, stampField │
│                                                              │
│  ┌─────────────────────┐   ┌───────────────────────────┐   │
│  │ lightning-record-form │   │  Last Synced (manual) row │   │
│  │ mode="view"            │   │  <- getRecord wire        │   │
│  │ fields = source fields │   │  helptext: hand-entered   │   │
│  └─────────────────────┘   └───────────────────────────┘   │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │  Sync button (disabled unless updateable=true)       │    │
│  │  <- getObjectInfo wire (FLS gate, no custom perm)     │    │
│  └───────────────────────┬───────────────────────────┘    │
└──────────────────────────┼────────────────────────────────┘
                            │ onclick
                            ▼
                  updateRecord({ Id, <stampField>: nowISO() })
                            │
                            ▼
              ┌─────────────────────────────┐
              │   LDS cache (client-side)    │
              │   — writes through, no Apex  │
              └───────────────┬──────────────┘
                               │ re-emits
                               ▼
              getRecord wire re-fires → Last Synced row updates

  🔴 NOTHING BELOW THIS LINE EXISTS FOR THIS FEATURE:
     no Apex controller · no service · no selector · no callout · no Named Credential
     no ASB spoke · no Placer.ai/CoStar connection · no data refresh of any kind
```

---

## File Locations

| Component Type | Path |
|---|---|
| Custom fields | `force-app/main/default/objects/Opportunity/fields/Monthly_Visits__c.field-meta.xml`, `Placer_Last_Synced_DateTime__c.field-meta.xml`, `CoStar_Last_Synced_DateTime__c.field-meta.xml` |
| Permission sets (edited) | `force-app/main/default/permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml`, `DPEG_Acquisition_View.permissionset-meta.xml`, `DPEG_Opportunity_View.permissionset-meta.xml` |
| FlexiPage (edited) | `force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml` |
| LWC | `force-app/main/default/lwc/marketDataSync/` (`.js`, `.html`, `.css`, `.js-meta.xml`) |
| Jest | `force-app/main/default/lwc/marketDataSync/__tests__/marketDataSync.test.js` |
| Design doc | `agent-output/design-requirements-placer-costar-sync.md` |
| Architecture reference | `ARCHITECTURE.md` §5 (three new subsections, see header) |

---

## Configuration Details

### Field details

- **`Monthly_Visits__c`** — Number(18,0), not required, not unique, no feed tracking. Mirrors
  `Property__c.Monthly_Visits__c` by name and type; the two are never reconciled by any code, flow, or
  formula in this application.
- **`Placer_Last_Synced_DateTime__c` / `CoStar_Last_Synced_DateTime__c`** — DateTime, not required.
  Written only by the Sync button's client-side `updateRecord` call today; each carries a
  `<description>` stating plainly that no external system is contacted.

### `c/marketDataSync` configuration (`marketDataSync.js`)

`CONFIG_BY_SOURCE` is the single source of truth for what each card renders:

| `source` | Title | Icon | Rendered fields | Stamp field |
|---|---|---|---|---|
| `Placer` | Placer | `standard:location` | `Placer_URL__c`, `Monthly_Visits__c` | `Placer_Last_Synced_DateTime__c` |
| `CoStar` | CoStar | `standard:metrics` | `CoStar_URL__c`, `Market_Cap_Rate__c` | `CoStar_Last_Synced_DateTime__c` |

`targetConfigs` restricts the component to `lightning__RecordPage` on `Opportunity` only, using the
`<objects><object>Opportunity</object></objects>` **element** form (the `objects=` attribute form is
rejected by the Metadata API — a previously recorded gotcha in this project). The `source` design
property defaults to `Placer` and is `required="true"`; because a `targetConfig` property cannot be
constrained to an enum, the component itself validates the value at connect time.

### Trigger/automation configuration

None. There is no trigger, no Flow, and no Apex on this feature's write path. The only side effect of
pressing Sync is the single-field `updateRecord` call described above.

**Confirmed at code review not to re-trigger Closed Won automation:** stamping the field does not
change `StageName`, and both consumers that matter (`PropertyAssetService.createAssets` and
`DealFolderService`) gate on stage *entry*, not stage *value* — so a Sync click cannot mint a second
`Property_Asset__c` or a second SharePoint deal folder (the latter mattering most, since a duplicate
SharePoint folder is an external write no Salesforce transaction can roll back).

---

## Testing

### Test coverage summary

| Layer | Status |
|---|---|
| Apex | N/A — no Apex was created |
| Jest (`c/marketDataSync`) | 12 named test groups (J1–J12) plus several unlabeled regression pins (loading-state, tooltip, disabled reason), all present in `marketDataSync.test.js` |

### Key test scenarios

- **J1/J2** — each `source` renders exactly its own field set (exact-list assertion, not
  containment — an extra field on the card is treated as a real defect).
- **J3** — an unrecognized, blank, or case-mismatched `source` renders a visible `role="alert"` naming
  the accepted values; never an empty card, never a thrown error, never a write.
- **J4/J5** — the Sync click writes exactly `{ Id, <stampField> }` and nothing else, for each source.
- **J6 (🔴 permanent falsifier, do not delete)** — `getRecordNotifyChange` is asserted **never** called,
  on both the success and error paths. This is the regression guard against a future "fix" applied by
  analogy with the stage-action bundles that legitimately do call it.
- **J7** — the Last Synced row is proven to re-render from the refreshed LDS record, not from a
  locally-assigned value — pinned by an assertion that the row still shows the *old* timestamp
  immediately after a successful write, until the wire re-emits.
- **J8/J9/J10** — the LDS error reducer is exercised against a validation-rule-shaped error, a
  field-error-shaped error, an array-bodied error, and a genuinely unusable error (each must not
  surface `undefined` or `[object Object]`).
- **J11** — a not-updateable field disables the button with a visible reason and a click writes
  nothing; a separate case (added at code review, W3) confirms a *failed* object-info read disables the
  button **without** claiming an FLS denial it hasn't established.
- **J12** — `@sa11y/jest` accessibility passes across all four render states (both configured sources,
  the misconfigured-source alert, and the disabled/no-access state).
- **Unlabeled regression pins worth naming explicitly:** the loading-state pin (W2) proves the Last
  Synced row never reads `Never` before the record wire has actually answered; the no-tooltip pin (S3)
  proves the button's `title` attribute is never the literal string `"undefined"` or `"null"` on a
  custom element (a measured Jest/base-component quirk, not merely a falsy-check); and the no-spinner
  pin proves the absence of any busy indicator — deliberately broader than a bare
  `lightning-spinner` query, checking for hand-rolled spinner divs and a disabled-during-write button
  state too, because this pin protects a *conditional user decision*, not a code convention.

---

## Security

### Sharing model

Not applicable in the usual sense — there is no Apex on this feature, so there is no `with sharing` /
`WITH USER_MODE` question to answer. Record visibility is governed entirely by the Opportunity's own
sharing model, unchanged by this feature.

### Required permissions

FLS edit on the three new fields (granted via `DPEG_Acquisition_Edit`) is what makes the Sync button
usable; FLS read-only (via `DPEG_Acquisition_View` / `DPEG_Opportunity_View`) renders the card
read-only with the button disabled and a visible reason. No custom permission exists or is needed —
see D6 above for the full argument against adding one. `DPEG_Admin_Access` was deliberately left
without these grants; see *Components Created* above.

---

## Known Limitations / Residuals

Carried forward, largely verbatim in substance, from the design document's residual list (R1–R10):

- **🔴 R1 — the timestamp asserts a freshness no data has.** The single most important residual;
  see the Overview above. Mitigated, not solved, by three requirements: the row label
  `Last Synced (manual)`, the helptext stating no connection exists, and the deliberate absence of any
  spinner/progress state. All three are required together for the `Sync` label to remain acceptable.
- **R2 — `Opportunity.Placer_URL__c` / `CoStar_URL__c` have no writer.** `LeadConvertService` (lines
  409–410) populates the **`Property__c`** twins only, never the Opportunity fields. Every
  lead-converted deal will show blank URL rows in both cards on day one — accepted at Gate 1 as-is;
  `LeadConvertService` is explicitly out of scope for this feature and must not be "fixed" as a side
  effect of implementing or reviewing this one. Pinned as UAT case U7 below.
- **R3 — two `Monthly_Visits__c` fields, nothing reconciling them.** `Property__c.Monthly_Visits__c`
  and the new `Opportunity.Monthly_Visits__c` share a name, a type, and a meaning; nothing keeps them
  in step. Two users looking at a deal and its property can read two different visit counts with no
  indication which is current.
- **R4 — the timestamp is composed on the client.** A user with a skewed system clock stamps a wrong
  time. Bounded and accepted: the value asserts nothing real today (R1), and the forward-path callout
  moves the stamp to `System.now()` on the server anyway.
- **R5 — no status field, correct only while nothing can fail.** See "No status field" above. The
  moment a real callout exists, this reverses and a status field ships in the same change.
- **R6 — nothing ages, sweeps, or expires the stamp.** A six-month-old "Last Synced" renders identically
  to one from this morning, in the same colour, with no warning. Deliberate: a staleness indicator on a
  value that was never fresh would compound R1 rather than mitigate it.
- **R9 — the card's Save bar is not the page's.** Inherent to any LWC built via
  `lightning-record-form`; not a defect.
- **R9a — pressing Sync while an inline edit is open in the same card can discard the unsaved draft.**
  Raised at code review (S6). The stamp write re-emits the record through LDS and the form may drop an
  in-progress edit; `lightning-record-form` exposes no dirty state for the button to gate on, so there
  is no clean code fix. Accepted as a documentation/UAT item.
- **R9b — the accessibility test count proves less than it suggests.** Raised at code review (S2).
  Every `lightning-*` base component is an sfdx-lwc-jest stub that renders nothing in jsdom, so
  `toBeAccessible()` validates only this bundle's own wrapper markup, not the base components'
  internals. The four green a11y assertions are still worth having; they are just not evidence about
  `lightning-button` or `lightning-record-form` themselves. The disabled-button reason text is adequate
  as built (it precedes the button in DOM order, reachable by a screen reader reading linearly) but is
  **not** programmatically associated with the button (`lightning-button` exposes no
  `aria-describedby`, and a disabled button is not focusable, so its `title` attribute will not be
  announced). Do **not** "fix" this by hiding the button instead — that reproduces the exact
  silent-denial defect that retired the `User.*_Driver__c` model elsewhere in this application.

---

## Manual UAT

The design's own U1–U7 test plan, since there is no Apex bulk-test obligation for this feature:

| # | As | Expect |
|---|---|---|
| U1 | User with `DPEG_Acquisition_Edit` | Both cards render, all fields populated/editable; Sync writes and the timestamp updates with no page refresh |
| U2 | User with `DPEG_Acquisition_View` only | Both cards render read-only; Sync is **disabled with a visible reason**, never missing, never throwing |
| U3 | User with `DPEG_Opportunity_View` only (Transactions persona) | Same as U2 |
| U4 | 🔴 A bare System Administrator, no acquisitions set | Card renders with **no fields**. This is the expected consequence of the sibling-rule grant decision, not a bug — do not add these fields to `DPEG_Admin_Access` to "fix" it. An admin smoke test proves nothing about this feature. |
| U5 | Any persona, after deploy | Retrieve the FlexiPage back; grep-assert exactly **8** `Acquisition_Deal_Actions` criteria; confirm all 9 tabs still render with their action bars intact |
| U6 | Any persona | 🔴 **Looks like it fails and does not — read before raising it.** A second row also labelled "Market Cap Rate" renders on the same tab: `Record.Primary_Underwriting__r.Market_Cap_Rate__c`, a *different field on `Underwriting__c`*, reached through the `Primary_Underwriting__c` lookup. `Opportunity.Market_Cap_Rate__c` itself has exactly one FlexiPage instance. Assert on the **field**, never on the label. |
| U7 | Any persona, on a lead-converted deal | Confirm R2: the Opportunity Placer/CoStar URL rows are blank while the linked `Property__c` holds both values. Not a build defect. |

---

## Forward Path — When a Real Integration Lands

This section exists so a future implementer extends the card rather than rebuilding it. When a real
Placer.ai/CoStar spoke (via ASB, per §3.1) becomes available, four things change **together, in one
change**, per the class header's own instructions:

1. The write moves **server-side to Apex** (a callout must be Apex) and the stamp becomes
   `System.now()` — closing R4.
2. `getRecordNotifyChange` **becomes required**, because imperative Apex DML happens behind LDS's back —
   the exact opposite of today's rule. `J6` inverts rather than being deleted.
3. A status field modelled on `Property__c.Placer_Fetch_Status__c` ships in the **same** change as the
   callout — closing R5, and only then, because only then does a genuine `Error` value exist.
4. The three R1 mitigations (label, helptext, no-spinner) are re-read and relaxed only as far as the
   new truth actually allows — not removed wholesale just because a connection now exists.

Only `handleSync()` and the class header's own documentation are expected to change; the rendering, the
`CONFIG_BY_SOURCE` map, and the FLS-based access check are all independent of where the write goes.

---

## Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-16 | Documentation Agent | Initial creation |
