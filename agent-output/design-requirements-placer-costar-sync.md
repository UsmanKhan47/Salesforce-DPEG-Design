# Design Requirements — Placer & CoStar Sync Cards (Opportunity Detail tab)

**Date:** 2026-08-16
**Requested by:** user (verbatim request reproduced below)
**Design agent output.** No metadata, Apex or LWC was written by this pass.

---

## 🎯 WHAT THE USER REQUESTED (verbatim)

> "Now we have to create placer and costar sections under detail, our existing sections of placer and costar will be removed. We need to keep the design same just like we have right now, but in lwc we need to show a button which will be a sync button. We will show last synced value as well along with the other fields."

---

## ✅ GATE G0 — CLOSED. The brief's premise was correct; this section previously said otherwise.

**Read this before trusting any earlier draft of this document.** The design pass originally opened
with a "PREMISE CORRECTION" asserting that the working-tree
`Opportunity_Record_Page.flexipage-meta.xml` still held `force:detailPanel` on its Detail tab and
that the strings `Placer` / `CoStar` appeared in no Opportunity FlexiPage. **That assertion was
wrong, and it has been removed rather than left standing.**

What actually happened, established 2026-08-16 by re-measurement:

1. The FlexiPage **was** retrieved from `usman-dpeg` into the working tree before the design pass
   began. Measured then: `SECTION [Placer]` → `Record.OneDrive_Folder_URL__c`, `SECTION [CoStar]` →
   `Record.CoStar_URL__c`, plus `Opportunity Information` / `Broker` / `Acquisition Deal Details`,
   and `force:detailPanel` deleted from `detailContent`. `git status` showed the file modified.
2. **The retrieve was then reverted out of the working tree mid-design-pass** (file mtime 19:57,
   inside the design run; `git status` afterwards showed the FlexiPage clean at HEAD). The design
   agent read the reverted file and reported, accurately for what it saw, that the sections did not
   exist.
3. The FlexiPage was re-retrieved and the org state re-confirmed: `<value>Placer</value>` and
   `<value>CoStar</value>` section labels present, `force:detailPanel` absent.

⇒ **G0's four steps are satisfied. Do not stop on it, and do not hand-author a Dynamic Forms
conversion** — the org's Dynamic Forms version is in the working tree now.

### 🔴 THE ONE THING TO CARRY FORWARD FROM THIS

The revert is unexplained and it happened silently, mid-run, to an uncommitted retrieve. **Commit the
retrieved FlexiPage as its own change BEFORE any edit is made to it** — that was G0 step 3 and it is
the step that would have prevented this entirely. Re-verify the file's content immediately before
editing rather than trusting that an earlier retrieve is still on disk. This is the practical form of
**Residual R7**.

### Confirmed regardless

| Fact | Verdict |
|---|---|
| 8 × `{!$Permission.CustomPermission.Acquisition_Deal_Actions}` on the page | ✅ **CONFIRMED**, all live `<criteria>`, no comment prose |
| `Market_Cap_Rate__c` also sits in the page layout `Opportunity-Opportunity Layout`, section `Acquisition Deal Details` | ✅ **CONFIRMED** — which is why D1 removes only the FlexiPage rendering and leaves the layout alone |

Everything else in this design (fields, LWC, FLS, tests, residuals) was never affected by this.

---

## 🔎 SECOND CORRECTION — `Opportunity.Placer_URL__c` and `Opportunity.CoStar_URL__c` HAVE NO WRITER

Measured by grep across `classes/`:

```
LeadConvertService.cls:409:        p.Placer_URL__c  = l.Placer_AI_Link__c;
LeadConvertService.cls:410:        p.CoStar_URL__c  = l.CoStar_Link__c;
```

`p` is the **`Property__c`** record built at line 400, not the Opportunity. Those are the only two
writes to a `Placer_URL__c` / `CoStar_URL__c` field anywhere in the codebase, and both target the
Property twin. `LeadConvertServiceTest` lines 244–252 pin exactly that.

**Consequence:** on every deal created by lead conversion, `Opportunity.Placer_URL__c` and
`Opportunity.CoStar_URL__c` are **permanently blank** unless a human types them, while the linked
`Property__c` — created in the same transaction — already holds both values. So the two cards this
design builds will render empty URL rows on converted deals, next to a Sync button, on day one.

This is **not fixed by this design** (it is out of the requested scope) but it must be visible before
build, because it changes what a reviewer will see in UAT. It is recorded as **Residual R2**, and a
named remedy is offered there.

---

## 📐 DESIGN DECISIONS

### D1 — `Market_Cap_Rate__c` duplication

`Opportunity.Market_Cap_Rate__c` is Percent(5,2), no `<description>`. Its `Property__c` twin carries
the description **"CoStar via ASB (stub)"**, which is what makes it the CoStar card's natural
occupant. Gate-1 already placed it in the CoStar card. The question is what happens to the rendering
it already has elsewhere on the Detail tab.

| Option | Effect | Assessment |
|---|---|---|
| **(a) Remove the existing rendering; the CoStar card is its only home on this tab** | One editable control, one freshness signal | ✅ **RECOMMENDED** |
| (b) Keep it editable where it is, render it **read-only** in the CoStar card | Two controls, one of which refuses input | ❌ Worse than duplication — a read-only field inside a card with a Sync button reads as "the integration owns this", which is false; the user will ask why they cannot edit it |
| (c) Accept the duplication, both editable | Two editable controls for one field on one screen | ❌ See below |

**Why (a), and why the harm in (c) is specific rather than cosmetic.** LDS keeps two renderings of
one field consistent, so this is not a data-integrity bug. The harm is that the Sync button and the
`Last Synced` row are an assertion *about the value in that card*. If the same field is editable
elsewhere on the same tab, a user can overwrite it in a place that carries no freshness signal and
then read a timestamp, in the card, describing a value they themselves just replaced. Removing the
duplicate rendering is what makes the card's claim about its own contents true.

**Scope of the removal — stated precisely, because it is easy to overreach.** Remove the *field
instance from the FlexiPage section only*. Do **not** remove `Market_Cap_Rate__c` from
`Opportunity-Opportunity Layout.layout-meta.xml` — the layout still backs Salesforce Classic, the
compact layout, and any other page or persona rendering through `force:detailPanel`. Do not delete
the field, and do not touch its six existing `<fieldPermissions>` grants.

**Stated cost of (a):** the cap-rate comparison triple — `Guidance_Cap_Rate__c` (the seller's),
`My_Cap_Rate__c` (ours), `Market_Cap_Rate__c` (CoStar's) — is split across the tab: two stay in the
deal-economics section and one moves into the CoStar card. A reviewer may reasonably prefer the three
side by side. If they do, the correct response is to revisit the Gate-1 field set, **not** to
reintroduce a second rendering.

### D2 — Where `OneDrive_Folder_URL__c` goes

Per the brief it is currently the only field in the org's Placer section, which is wrong on its face —
it is a document-folder link with no relationship to Placer.ai.

**Decision: move it into `Acquisition Deal Details`**, which is exactly where the repo's page layout
already puts it (line 121), immediately above `Placer_URL__c` and `CoStar_URL__c`. This restores the
layout's own grouping rather than inventing a new home. **It is not dropped.**

⚠ Flag, not scope: `Property__c.SharePoint_Folder_URL__c` is the *automated* deal-folder URL written
by `DealFolderService` (ARCHITECTURE §1). `Opportunity.OneDrive_Folder_URL__c` is a hand-keyed legacy
twin with no writer. The two will diverge. Not addressed here; raise separately.

### D3 — New fields

All three on **`Opportunity`** (Gate-1 decision 3).

#### Naming — ARCHITECTURE §1 compliance, argued

- **§1 rule 6** — `Date` suffix for date-only, `DateTime` for date+time, and *never* `Date` on a
  DateTime field. These are date+time ⇒ `_DateTime__c`.
- **§1 rule 4** — `<Subject>_<PastParticiple>` is a **Boolean** form. `Placer_Last_Synced__c` would
  therefore assert a checkbox. This is not hypothetical for this repo: rule 4 is why
  `Untouched__c` → `Is_Untouched__c` and `Never_Expires__c` → `Is_Non_Expiring__c` were migrated in
  the §1 repair.
- **§1 rule 9 prohibition 2** — "a field name must not assert a type the field does not have". The
  `_DateTime__c` suffix is what resolves the rule-4 collision. It is required, not decorative.

⇒ `Placer_Last_Synced_Date__c` is **prohibited** (rule 6). `Placer_Last_Synced__c` is **prohibited**
(rule 4). `Placer_Last_Synced_DateTime__c` is the only compliant form.

`Monthly_Visits__c` — a plural count noun; rule 9's `_Count__c` suffix governs Numbers "whose name
would otherwise read Boolean or categorical", which "Monthly Visits" does not. Decisively, the
existing `Property__c.Monthly_Visits__c` is Number(18,0) with this exact API name, and naming the
Opportunity twin differently would be worse than matching it. Rule 9 prohibition 1 (never name a
Text/Number field identically to a custom object) is not engaged — there is no `Monthly_Visits__c`
object.

#### Exact field table

| API name | Label | Type | Precision / Scale | `required` | Description (`<description>`) |
|---|---|---|---|---|---|
| `Opportunity.Monthly_Visits__c` | `Monthly Visits` | `Number` | precision 18, scale 0 | false | `Placer.ai monthly visit count for this deal. Manually entered - no live Placer.ai connection exists. Mirrors Property__c.Monthly_Visits__c; the two are not reconciled.` |
| `Opportunity.Placer_Last_Synced_DateTime__c` | `Placer Last Synced` | `DateTime` | n/a | false | `Stamped by the Sync button on the Placer card. STUB: no external system is contacted, so this records when a user pressed the button, not when data was refreshed.` |
| `Opportunity.CoStar_Last_Synced_DateTime__c` | `CoStar Last Synced` | `DateTime` | n/a | false | `Stamped by the Sync button on the CoStar card. STUB: no external system is contacted, so this records when a user pressed the button, not when data was refreshed.` |

All three: `trackFeedHistory` false, `trackTrending` false, `externalId` false, `unique` false.
Descriptions are within the 255-char cap — verify at authoring time; if any overruns, use the repo's
XML-comment-inside-the-root workaround, **never** a comment above the root (it breaks `sf` at source
conversion).

#### 🔴 No status field — argued, not omitted

The brief invited a status field alongside the timestamp. **Recommendation: do not build one.**

`Property__c.Placer_Fetch_Status__c` is a **restricted** picklist with values `{Success, Error}`. A
stub that contacts nothing can only ever write `Success`. A restricted two-value picklist with one
reachable value is not a status — it is a constant with a picklist around it, and its presence on the
card is the single most effective way to make a stub look like a working integration. There is also
nothing to record: `Error` requires a failure, and the only failure available (an LDS write refusal)
is already surfaced as a toast and leaves the timestamp unchanged, which *is* the signal.

When a real callout lands, add the status field then, modelled on the Property twin, in the same
change as the callout. Named in **Residual R5**.

### D4 — ONE LWC bundle, not two

ARCHITECTURE §5 records that `transactionAdvanceStage` was built and **deleted the same day**
(2026-08-12, code review W3) because it was byte-identical to `advanceRecordStage` below the
comments, and states the governing rule: *"a bundle that DIFFERS" earns its own file; "a copy
carrying only a different header is not a split — it is a second file that must now receive every fix
the first one gets, with nothing but review to notice when it does not."*

Placer and CoStar differ in **data** — a title, an icon, a field list, a stamp field. They do not
differ in **behaviour**: both render a titled section of Opportunity fields, a `Last Synced` row and a
button that writes one DateTime to the record already in context. Two bundles would be identical
below their constants — precisely the deleted shape.

**Decision: one bundle, `c/marketDataSync`.**

#### Parameterisation — `source`, not a free-form field list

Two mechanisms were considered:

| Mechanism | Assessment |
|---|---|
| **`source` design property (`Placer` \| `CoStar`) + a `CONFIG_BY_SOURCE` map in the JS holding title, icon, field list and stamp field** | ✅ **RECOMMENDED** — mirrors `advanceRecordStage`'s `CONFIG_BY_TYPE` precedent exactly; field API names arrive as `@salesforce/schema/...` imports, so a renamed or deleted field is a **build-time** failure; adding a third vendor is one map entry |
| Free-form `fieldNames` design property (comma-separated API names) + `lastSyncedFieldName` | ❌ Rejected — field names become untyped runtime strings, so a rename deploys green and renders an empty card; and it makes the component droppable on any object, which is a governance loss for no gain |

`targetConfigs` (target `lightning__RecordPage`, `<objects><object>Opportunity</object></objects>` —
note the **element** form; the `objects=` attribute form is rejected by the API, a trap already
recorded in this project's memory):

```
<property name="source" type="String" label="Data source" default="Placer"
          description="Placer or CoStar. Selects the card title, icon, fields and Last Synced field." required="true"/>
```

Because `targetConfig` properties cannot be constrained to an enum, **the component must validate
`source` against the map keys on connect and render a visible inline error** (`role="alert"`) naming
the accepted values when it misses. A silent empty card is the failure mode to design out — it is
indistinguishable from "no data", which is exactly the trap ARCHITECTURE records for
`DealFolderSweepBatch`'s all-zeros summary.

### D5 — LDS `updateRecord`, not Apex

**Decision: LDS.** ARCHITECTURE §5 *Data Access Priority* puts LDS wire adapters first, and this is
its exact case — a single-record write of one field on the record the user is already viewing. There
is no join, no aggregate, no callout and no cross-object orchestration.

**Cost avoided, stated:** an Apex path would require a controller + a service (per
`.claude/rules/apex-layering-rule.md`, a controller may hold no logic), a selector for any SOQL, an
`AuraHandledException` boundary, a test class at **90%+ coverage**, and a `classAccesses` entry in
`DPEG_Apex_Access` plus the capability set — five artefacts and a coverage obligation to perform one
field write the platform already expresses in one call.

#### 🔴 The consequence this choice carries — get this right

ARCHITECTURE §5's guard-util table makes this load-bearing and the two rules are **opposites**:

- `updateRecord` writes **through** the LDS cache, so the record page and every other component on it
  re-render on their own. ⇒ **`getRecordNotifyChange` MUST NOT be called.** This is the
  `c/leadStatusChange` rule.
- Imperative Apex DML happens **behind LDS's back**. ⇒ `getRecordNotifyChange` **must** be called.
  This is the `c/dealActionGuard` / `c/recordStageGuard` rule.

**We are on the first rule.** A Jest test asserting `getRecordNotifyChange` was **never** called is
specified in the test plan below, as the permanent falsifier against someone "fixing" this later by
analogy with the stage-action bundles.

#### 🔴 Error handling — read the LDS error shape, not the Apex one

An LDS write failure (validation rule, FLS refusal, required-field) surfaces at
`error.body.output.errors[]` and `error.body.output.fieldErrors{}` — **`error.body.message` is often
empty for these**, which renders as a blank or generic toast that hides the real reason. This repo has
already paid for it: `c/leadStatusChange` was fixed for exactly this, while `c/dealActionGuard`'s
`body.message`-only read is **correct for its Apex path** and must not be copied here.

⇒ **Copy `c/leadStatusChange`'s error reducer, not `c/dealActionGuard`'s.** Read `body.output.errors`,
then `body.output.fieldErrors`, then `body.message`, then a fallback constant.

#### Forward path when the real integration lands

The write moves server-side (a callout must be Apex). At that point: the stamp becomes `System.now()`
(server clock), the component calls `getRecordNotifyChange`, the status field of D3 is added, and this
component's `syncClicked` handler swaps its LDS call for an imperative Apex call. Nothing else in the
card changes. Say so in the class header so the next author does not rebuild it.

### D6 — No permission gate

**Decision: the Sync button needs no custom permission and no `<visibilityRule>`.**

Argued rather than assumed:

- **There is no privileged operation to gate.** The button's entire effect is writing one DateTime
  field that any user with FLS edit can already write by hand. Contrast the three stage-action gates
  (`Acquisition_Deal_Actions`, `Disposition_Deal_Actions`, `Transaction_Stage_Actions`), every one of
  which guards a *record moving through a business process* under server-side logic. Nothing here
  drives anything.
- **FLS edit on the stamp field is already the correct gate, and it is already modelled.**
  `DPEG_Acquisition_Edit` grants these fields `editable=true`; `DPEG_Acquisition_View` and
  `DPEG_Opportunity_View` grant `editable=false`. So a View persona gets a read-only card and an Edit
  persona gets a working button — the exact distinction wanted, at zero new metadata, with no
  layer-4/layer-5 placement decision to get wrong (ARCHITECTURE: *"which layer carries a custom
  permission is the whole security question"*).
- Adding a gate would introduce a **capability/authorization split** that this feature has no second
  population to justify, plus a two-phase deploy (a `CustomPermission` and a FlexiPage referencing it
  cannot ship together — the FlexiPage validator resolves against already-committed org metadata).

#### 🔴 What the component MUST do instead

- Read `getObjectInfo` (or the `getRecord` field metadata) and check the stamp field's `updateable`
  flag. When false, **render the button disabled with a reason** ("You do not have edit access to
  this field") rather than hiding it silently or letting the click throw.
- **Never bind a `<visibilityRule>` to a FIELD.** ARCHITECTURE records this as measured, twice: a
  flexipage `<visibilityRule>` referencing a field evaluates **FALSE** for any user lacking FLS READ
  on it — no error, no log, the control simply vanishes for users who are genuinely authorized. It is
  why the whole `User.*_Driver__c` model was retired. If a gate is ever added here it must be a
  custom permission with the three-segment token `{!$Permission.CustomPermission.<Name>}` (both
  shorter spellings are rejected at deploy).

### D7 — FLS

Every field deployed by the Metadata API arrives with **no** field permissions for **any** profile,
System Administrator included. The three new fields are invisible to everyone until declared.

**Grant where the SIBLING fields already live.** Measured across `permissionsets/`, the existing
Placer/CoStar/Market-Cap siblings on Opportunity are declared in exactly three sets:

| Permission set | `Opportunity.Placer_URL__c` | `Opportunity.CoStar_URL__c` | `Opportunity.Market_Cap_Rate__c` | `Opportunity.OneDrive_Folder_URL__c` |
|---|---|---|---|---|
| `DPEG_Acquisition_Edit` | 1189 `editable=true` | 990 `editable=true` | 1135 `editable=true` | 1179 `editable=true` |
| `DPEG_Acquisition_View` | 1163 `editable=false` | 974 `editable=false` | 1119 `editable=false` | 1153 `editable=false` |
| `DPEG_Opportunity_View` | 276 `editable=false` | 86 `editable=false` | 211 `editable=false` | 246 `editable=false` |

⇒ **Required edits:**

| Set | `Monthly_Visits__c` | `Placer_Last_Synced_DateTime__c` | `CoStar_Last_Synced_DateTime__c` |
|---|---|---|---|
| `DPEG_Acquisition_Edit` | `readable=true`, `editable=true` | `readable=true`, `editable=true` | `readable=true`, `editable=true` |
| `DPEG_Acquisition_View` | `readable=true`, `editable=false` | `readable=true`, `editable=false` | `readable=true`, `editable=false` |
| `DPEG_Opportunity_View` | `readable=true`, `editable=false` | `readable=true`, `editable=false` | `readable=true`, `editable=false` |

#### ⚠ Correction to the brief — `DPEG_Admin_Access` should NOT receive these

The brief lists `DPEG_Admin_Access` as one of four relevant sets and says all of
`DPEG_Acquisition_Edit`/`_View`/`DPEG_Opportunity_View` "already carry Placer/CoStar grants". The
first three are confirmed above. `DPEG_Admin_Access` is not: it holds **49** `<fieldPermissions>`, of
which exactly **7** are Opportunity fields — `Call_For_Offers_Received_Date__c`,
`Extraction_Score_Pct__c`, `Fields_Captured_Count__c`, `Fields_Missing_Count__c`,
`Listing_Status__c`, `Offer_Alert_Due_Date__c`, `Offer_Alert_Last_Interval__c` — and **none** of the
Placer / CoStar / Market-Cap siblings is among them.

So a bare administrator **already cannot see today's Placer and CoStar fields**. Granting only the
three *new* fields there would produce, for that persona, a card showing a `Last Synced` timestamp and
nothing else — strictly worse than not granting them. The choice is therefore **all six or none**:

- ✅ **Recommended: none.** Follow the sibling rule; `DPEG_Admin_Access` is a layer-7 profile-restoration
  set, not an FLS home for acquisitions data. An administrator who needs the card should be assigned
  an acquisitions set, which is how every other acquisitions field on this page already works.
- Alternative (admin's call): add all six (`Placer_URL__c`, `CoStar_URL__c`, `Market_Cap_Rate__c`,
  `Monthly_Visits__c`, and the two `_Last_Synced_DateTime__c` fields) in one change. Note this is a
  new precedent for the set, not a match to one.

#### 🔴 REPLACE-not-merge — reconcile before deploying

A `PermissionSet` deploy **replaces** that set's entire `<fieldPermissions>` list with exactly what the
file declares. An org-side-only grant absent from the file is silently wiped by the next deploy of that
file, **even one made for an unrelated reason**. This repo was bitten twice (2026-08-05 and 2026-08-06;
`Broker_Protection_Access`'s own XML comment carries the writeup) — a hand-made `Task.WhoId` grant was
wiped by a later deploy for a field-casing fix, and every inbound email routing to a Lead or Contact
threw until the field was declared in-file.

⇒ **Retrieve all three permission sets from `usman-dpeg` and diff against the repo copies before
adding anything.** `profiles/**` is `.forceignore`d, so there is no profile-level fallback if a
retirement or a replace removes access a set was silently the only source of.

### D8 — The FlexiPage edit

**Gated on G0.** Once the org's Dynamic Forms version is in the working tree:

**Remove:**
1. The `flexipage:fieldSection` `componentInstance` labelled **Placer**, *and* the facet chain it
   references. A field section is not one block: `fieldSection` → `columns` facet → one or more
   `flexipage:column` instances → one field facet each. Expect **3–4** `<flexiPageRegions>` blocks per
   section, not one. Deleting the `fieldSection` and orphaning its facets leaves unreferenced regions
   that survive a deploy and confuse the next reader.
2. The `flexipage:fieldSection` `componentInstance` labelled **CoStar**, and its facet chain.
3. The `fieldInstance` for `Record.Market_Cap_Rate__c` from whichever section holds it (D1).
4. The `fieldInstance` for `Record.Placer_URL__c` from `Acquisition Deal Details` (it is now rendered
   by the Placer card).

**Add:**
5. Two `componentInstance` blocks in the Detail tab facet, in the ordinal positions the removed
   sections occupied:

```
<componentInstance>
    <componentInstanceProperties>
        <name>source</name>
        <value>Placer</value>
    </componentInstanceProperties>
    <componentName>marketDataSync</componentName>
    <identifier>placerSyncCard</identifier>
</componentInstance>
```

...and the CoStar twin (`<value>CoStar</value>`, `<identifier>costarSyncCard</identifier>`).

**Move:**
6. `Record.OneDrive_Folder_URL__c` into the `Acquisition Deal Details` field facet (D2).

#### Invariants to verify after the edit

- 🔴 **The 8 `{!$Permission.CustomPermission.Acquisition_Deal_Actions}` rules must survive unchanged.**
  Measured: all 8 live in the **`header` region**, inside `force:highlightsPanel`'s `actionNames`
  `valueList` — a region this edit does not touch. They are at risk only from a careless whole-file
  rewrite. All 8 are live `<criteria>`; **none** is comment prose (a real distinction in this repo —
  a 2026-08-12 count of "31 rules" was 24 live + 7 comments). Re-grep the syntactic form
  `\$Permission\.CustomPermission\.Acquisition_Deal_Actions` after the edit and assert **8**.
- The two `<visibilityRule>` blocks on the `developmentTab` / `constructionTab` tabs
  (`Record.Deal_Type__c` = `Land` / `Retail`) are untouched.
- 🔴 **A FlexiPage deploy can roll back with a design-time error and REPORT AS SUCCESS.** Retrieve the
  page back after deploying and read the deployed result. A green deploy is not evidence.
- 🔴 **Do not enable or re-enable Dynamic Actions in App Builder as part of this work.** Doing so
  silently discards the page's inherited layout action list — three of five pages were left with zero
  buttons the last time. No automated check can see it; readback is the only proof.

### D9 — "Keep the design the same"

The literal reading is that the cards must be visually indistinguishable from the SLDS field sections
they replace. **There is a real platform limit here that must be stated before build:** no LWC can
join the record page's own inline-edit / Save-bar mechanism. Three options, and the difference is
functional, not cosmetic:

| Option | Rendering | Editing | Assessment |
|---|---|---|---|
| (a) `lightning-record-view-form` + `lightning-output-field` | Platform-identical in view mode; URL fields render as links | **Lost** — fields become read-only | ❌ Functional regression: all four fields are `behavior=Edit` on the layout today |
| **(b) `lightning-record-form` `mode="view"`, `columns="2"`, explicit `fields`** | Platform-identical field rows **with per-field inline-edit pencils** and an auto Save/Cancel bar inside the component | Preserved | ✅ **RECOMMENDED** — nearest available reproduction of a Dynamic Forms section |
| (c) Leave the fields in a real `flexipage:fieldSection` and put only the button + `Last Synced` in a thin LWC strip beneath | Byte-identical, by construction | Untouched | ⚠ The only literally-identical option, but it contradicts the request ("show last synced value **along with the other fields**") and splits one card across two constructs |

**Recommend (b).** Present (c) to the user only if pixel-identity turns out to matter more than the
fields living in the component.

**Stated cost of (b):** the card's Save/Cancel bar is the component's own, not the record page's. A
user editing a field in the card and a field in a neighbouring section has two Save affordances. This
is unavoidable for any LWC and is not a defect in the implementation.

#### Styling requirements

- **SLDS 2 design tokens only** (`--slds-g-*`). No hardcoded colours, hex values or pixel spacing.
  Run the SLDS linter before deploying (`.claude/skills/uplifting-components-to-slds2/`).
- Section heading: `slds-section__title` / `slds-text-title_caps` so it matches a `fieldSection`
  header. Two-column body via `slds-grid slds-wrap` + `slds-size_1-of-2`.
- `Last Synced` renders as a normal field row via `lightning-formatted-date-time`, **not** as a badge
  or a coloured pill — it is a value, not a status (see R1 for the qualifier it must carry).
- The Sync button is `lightning-button variant="neutral"`, right-aligned in a
  `slds-card__footer`-style row alongside the form's own Save. Not `brand` — a brand button asserts
  primacy this stub has not earned.
- ⚠ **The `.lv-*` list-view chrome convention is NOT relevant here and must not be applied.** Measured:
  the `.lv-*` table classes (`lv-table`, `lv-scroll`, `lv-cell`) exist in **one** bundle; only
  `.lv-error` is genuinely cross-bundle. This is a field section, not a list.
- `apiVersion` **67.0** in the `.js-meta.xml` (repo is uniformly 67.0; the sole exception is
  `lwc/leaseNegotiationLog` at 62.0).

---

## 📦 COMPONENT INVENTORY

### 🔵 Admin (declarative)

| # | Artefact | Path | Action |
|---|---|---|---|
| A1 | `Opportunity.Monthly_Visits__c` | `objects/Opportunity/fields/Monthly_Visits__c.field-meta.xml` | **NEW** |
| A2 | `Opportunity.Placer_Last_Synced_DateTime__c` | `objects/Opportunity/fields/Placer_Last_Synced_DateTime__c.field-meta.xml` | **NEW** |
| A3 | `Opportunity.CoStar_Last_Synced_DateTime__c` | `objects/Opportunity/fields/CoStar_Last_Synced_DateTime__c.field-meta.xml` | **NEW** |
| A4 | `DPEG_Acquisition_Edit` | `permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml` | **EDIT** — +3 `fieldPermissions` (editable) |
| A5 | `DPEG_Acquisition_View` | `permissionsets/DPEG_Acquisition_View.permissionset-meta.xml` | **EDIT** — +3 `fieldPermissions` (read-only) |
| A6 | `DPEG_Opportunity_View` | `permissionsets/DPEG_Opportunity_View.permissionset-meta.xml` | **EDIT** — +3 `fieldPermissions` (read-only) |
| A7 | `Opportunity_Record_Page` | `flexipages/Opportunity_Record_Page.flexipage-meta.xml` | **EDIT** — gated on G0 |

**Not touched:** `Opportunity-Opportunity Layout.layout-meta.xml`, all `Property__c` fields, all other
permission sets, `DPEG_Admin_Access`, every `customPermissions/` file.

### 🟢 Development (programmatic)

| # | Artefact | Path | Action |
|---|---|---|---|
| D1 | `c/marketDataSync` bundle (`.html`, `.js`, `.css`, `.js-meta.xml`) | `lwc/marketDataSync/` | **NEW** |
| D2 | Jest suite | `lwc/marketDataSync/__tests__/marketDataSync.test.js` | **NEW** |

**Zero Apex.** No controller, no service, no selector, no trigger, no test class.

---

## 🔗 EXECUTION ORDER

1. **G0** — retrieve `Opportunity_Record_Page` into the working tree and commit. *(Blocks A7 only.)*
2. **A1–A3** — create the three fields. *(Blocks A4–A6: a permission set cannot grant FLS on a field
   that does not exist.)*
3. **A4–A6** — reconcile each set against the org, then add the grants. *(Blocks UAT: without these
   the card is blank for every non-admin, including the one testing it.)*
4. **D1–D2** — build the LWC and its Jest suite. *(Independent of 1–3; can run in parallel. Blocks A7:
   a FlexiPage referencing an undeployed component fails validation.)*
5. **A7** — the FlexiPage edit. *(Requires G0 and D1.)*
6. Deploy → **read the FlexiPage back** → UAT as three personas.

---

## 🧭 COMPLEXITY ROUTING RECOMMENDATION

| Stream | Agent | Reason |
|---|---|---|
| Admin | 🔵 **`salesforce-admin`** | Three custom fields, three permission-set field-grant additions, one FlexiPage edit. No multi-object schema design, no OWD/sharing/FLS *strategy*, no subflow architecture, no ERD — none of `salesforce-solution-architect`'s triggers is present. ⚠ Route with the G0 gate and the REPLACE-not-merge reconciliation stated up front; the FlexiPage is the highest-risk declarative surface in this repo, but risk is not the routing criterion — architectural scope is. |
| Development | 🟢 **`salesforce-developer`** | One LWC bundle plus its Jest suite. Zero Apex, zero SOQL, zero DML, no callout, no Named Credential, no LDV, no Platform Events. Gate-1 decision 1 explicitly removed the entire integration surface, which is what would otherwise route this to `salesforce-technical-architect`. |
| Testing | ⛔ **Skip `salesforce-unit-testing`** | No Apex is created, so there is nothing for it to test. Jest is the developer agent's own deliverable per ARCHITECTURE §5. |
| Review | 🟣 `salesforce-code-review` | Normal. |

---

## 🧪 TEST PLAN

### Jest (`lwc/marketDataSync/__tests__/marketDataSync.test.js`)

| # | Test | Asserts |
|---|---|---|
| J1 | Renders with `source = "Placer"` | Title "Placer"; the rendered field set is `Placer_URL__c` + `Monthly_Visits__c` + the Last Synced row; `CoStar_URL__c` absent |
| J2 | Renders with `source = "CoStar"` | Title "CoStar"; field set is `CoStar_URL__c` + `Market_Cap_Rate__c` + Last Synced; `Monthly_Visits__c` absent |
| J3 | Invalid `source` (`""`, `"Yardi"`) | An inline `role="alert"` naming the accepted values; **no** empty card, **no** thrown error |
| J4 | Sync click, Placer | `updateRecord` called once with `{ fields: { Id: recordId, Placer_Last_Synced_DateTime__c: <ISO> } }` and **no other field** |
| J5 | Sync click, CoStar | Same, targeting `CoStar_Last_Synced_DateTime__c` |
| J6 | 🔴 **`getRecordNotifyChange` is NEVER called** | Module-mock the adapter and assert zero invocations. **This is the permanent falsifier for D5** — it goes red if someone later "fixes" this by analogy with `c/dealActionGuard`. Do not delete it |
| J7 | Success path | A success toast fires; the Last Synced row re-renders from the LDS-refreshed record (not from local state) |
| J8 | Error path — validation-rule shape | Given `{ body: { output: { errors: [{ message: 'X' }] } } }`, the toast message is `X` — **not** a fallback. The regression pin for the `body.message`-only read |
| J9 | Error path — field-error shape | Given `body.output.fieldErrors`, the message is extracted, not swallowed |
| J10 | Error path — nothing usable | Falls back to the module's constant; never toasts `undefined` or `[object Object]` |
| J11 | Field not updateable | Button rendered **disabled** with a reason; clicking dispatches nothing |
| J12 | Accessibility | `@sa11y/jest` matcher passes in both `source` configurations and in the error state. Remember `sa11y` v8 requires the explicit `setup()` call |

**Mock `lightning/uiRecordApi` at module level**, not by instance-spy — a repo-recorded Jest gotcha.

### Apex tests — none, and why

There is no Apex. **`.claude/rules/bulk-test-rule.md`'s 251-record mandate does not apply** and must
not be demanded at review: it governs triggers, batch jobs, DML-performing services and queueables.
This feature has none. Recording this here so the point is settled in the design rather than argued in
review.

### Manual UAT — the only control that exists for the declarative half

| # | As | Expect |
|---|---|---|
| U1 | A user with `DPEG_Acquisition_Edit` | Both cards render with all fields populated/editable; Sync writes and the timestamp updates without a page refresh |
| U2 | A user with `DPEG_Acquisition_View` only | Both cards render read-only; the Sync button is **disabled with a reason**, not missing and not throwing |
| U3 | A user with `DPEG_Opportunity_View` only (Transactions persona) | Same as U2 |
| U4 | 🔴 A **bare System Administrator** with no acquisitions set | Per D7, the card renders with no fields — this is the **expected** consequence of the sibling-rule grant, not a bug. Recorded so it is not "fixed" by adding the fields to `DPEG_Admin_Access` piecemeal. **An admin smoke test proves nothing about this feature** |
| U5 | Any persona, after the FlexiPage deploy | Retrieve the page back; grep-assert **8** `Acquisition_Deal_Actions` criteria; confirm all 9 tabs still render and the header action bar still shows its buttons |
| U6 | Any persona | Confirm `OneDrive_Folder_URL__c` appears in `Acquisition Deal Details` and **nowhere else**; confirm `Opportunity.Market_Cap_Rate__c` appears **only** in the CoStar card on this tab. 🔴 **THIS CASE LOOKS LIKE IT FAILS AND DOES NOT — read this before raising it.** A SECOND row labelled "Market Cap Rate" renders on the same tab: `Record.Primary_Underwriting__r.Market_Cap_Rate__c`, which is a **different field, on `Underwriting__c`**, reached through the `Primary_Underwriting__c` lookup. Verified 2026-08-16: `Opportunity.Market_Cap_Rate__c` itself has exactly ONE FlexiPage instance. The duplicate LABEL is pre-existing, out of scope, and has no cheap remedy — Dynamic Forms offers no per-instance label override. Assert on the FIELD, never on the label |
| U7 | Any persona, on a lead-converted deal | Confirm the observation in **R2** — the Opportunity Placer/CoStar URL rows are blank while `Property__c` holds both values. Not a build defect |

---

## ⚠ RESIDUALS — what this design does NOT do

**R1 — 🔴 SYNC CONTACTS NOTHING. THE TIMESTAMP ASSERTS A FRESHNESS NO DATA HAS.**
This is the single most important residual and the one the UI must actively work against. Pressing
Sync writes a DateTime and does nothing else: no callout, no ASB spoke, no Named Credential, no data
refresh. A user reading "Last Synced: today, 09:14" will reasonably conclude the Monthly Visits and
Market Cap Rate figures beside it were retrieved today. **They were typed by hand, possibly months
ago.**

Mandatory UI mitigations — these are requirements, not suggestions:

- Label the row **`Last Synced (manual)`**, not `Last Synced`.
- Attach a `lightning-helptext` to that row reading, in substance: *"Recorded when a user pressed
  Sync. No connection to Placer.ai / CoStar exists yet — the values above are entered by hand."*
- 🔴 **No spinner, no "Syncing…" state, no progress indicator, and no delay.** Animating a fetch that
  does not happen is precisely how a stub becomes a lie. The click should stamp and toast immediately.
- Button label `Sync` is acceptable **only** with the two mitigations above; **`Mark Synced` is the
  safer label** and is the recommendation if the user will accept it.
- The `<description>` on both DateTime fields carries the same warning (D3), so a report builder or a
  future developer reading the schema sees it too.

**R2 — `Opportunity.Placer_URL__c` / `CoStar_URL__c` have no writer.** Measured: `LeadConvertService`
lines 409–410 populate the `Property__c` twins only. Every lead-converted deal will show blank URL
rows in these cards while the linked Property holds both values. **Named remedy (out of scope):**
either extend `LeadConvertService` to carry the two links onto the Opportunity as well — noting its
pinned **2 SOQL / 3 DML** contract, which a same-object field assignment does not move — or render the
Property values through `Record.Property__r.Placer_URL__c` instead and drop the Opportunity fields
entirely. That second option contradicts Gate-1 decision 3 and is offered only for the record.

**R3 — Two `Monthly_Visits__c` fields, nothing reconciling them.** `Property__c.Monthly_Visits__c` and
the new `Opportunity.Monthly_Visits__c` share a name, a type and a meaning, and no code, flow or
formula keeps them in step. Two users looking at a deal and its property can read two different visit
counts with no indication which is current. Accepted under Gate-1 decision 3.

**R4 — Client-clock timestamp.** LDS `updateRecord` sends a value composed in the browser, so a user
with a skewed system clock stamps a wrong time. Bounded and accepted: the value asserts nothing real
today (R1), and when the real callout lands the write moves server-side to `System.now()` anyway
(D5, forward path).

**R5 — No status, so a failure has nowhere to be recorded.** Correct only while nothing can fail. The
moment a callout exists, the D3 argument reverses and a status field modelled on
`Property__c.Placer_Fetch_Status__c` must ship in the same change.

**R6 — Nothing ages, sweeps or expires the stamp.** A `Last Synced` of six months ago renders exactly
like one from this morning, in the same colour, with no warning. No batch, no schedule, no formula
band. Deliberate — a staleness indicator on a value that was never fresh would compound R1 rather
than mitigate it.

**R7 — The org's FlexiPage state is not COMMITTED to source control, and an uncommitted retrieve of it
was silently reverted once.** The Dynamic Forms conversion of `Opportunity_Record_Page` was made
directly in `usman-dpeg`; it is now in the working tree but **uncommitted**, and it was already lost
once mid-task without explanation (see G0). Until it is committed, every consumer of this document is
one silent revert away from reading a file that describes a page the org no longer has — which is
exactly what happened to the design pass that wrote this document, and is why an earlier draft
carried a false blocking gate. **Commit the retrieve before editing.** The general lesson: a retrieve
is not a durable fact until it is a commit.

**R8 — `Market_Cap_Rate__c` remains on four objects.** Opportunity, `Property__c`, `Underwriting__c`
and `Property_Asset__c` each carry a field of that name, with grants across six permission sets. This
design changes only *where the Opportunity one is rendered* on one tab. No consolidation is attempted.

**R9 — The card's Save bar is not the page's.** Per D9 option (b). Unavoidable for any LWC.

**R9a — Pressing Sync with an inline edit open in the same card can discard the unsaved draft.**
Raised at code review 2026-08-16 (S6). The stamp writes through the LDS cache, the record re-emits,
and `lightning-record-form` may drop an in-progress edit. Inherent to D9 option (b) and **there is no
clean fix**: the form exposes no dirty state, so the button cannot be gated on it. Accepted as a
documentation-and-UAT item rather than code — add a UAT step confirming the behaviour is tolerable
rather than surprising.

**R9b — The a11y tests prove less than their count suggests.** Raised at code review (S2). Every
`lightning-*` base component is an sfdx-lwc-jest stub rendering nothing in jsdom, so `toBeAccessible()`
validates only this bundle's own wrapper markup (`h3`, spans, `p[role=alert]`, `p[role=note]`). Four
green a11y assertions across four states are still worth having — just do not cite them about the
button. ⚠ The disabled-button reason IS adequate as built (the `<p role="note">` precedes the button in
DOM order, so a screen reader reading linearly reaches it) but is **not programmatically associated** —
`lightning-button` exposes no `aria-describedby`, and a disabled button is not focusable, so its
`title` will not be heard. 🔴 **Do not "improve" this by hiding the button instead** — that is the
silent-denial defect that retired the `User.*_Driver__c` model.

**R10 — ARCHITECTURE.md is not updated by this design.** Per §6, a new convention must be recorded in
the same PR. Two candidates: the `source` + `CONFIG_BY_SOURCE` parameterisation as the house pattern
for a multi-instance record-page card (extending the `advanceRecordStage` precedent from headless
actions to rendered components), and the LDS-write / no-`getRecordNotifyChange` pairing for
record-page cards. The implementing agent should propose the §5 amendment; this design does not
pre-write it.

---

## 📝 PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md §1 (naming rules 4, 6 and 9) and the Permission Set Architecture subsection
before starting. Follow .claude/rules/salesforce-global-rule.md's per-type skill + API-context loop.
Do not deploy — create and edit metadata files only. API version 67.0.

✅ GATE G0 IS CLOSED - the org's Dynamic Forms version of
force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml IS in the working tree,
re-verified 2026-08-16 (section labels `Placer` and `CoStar` present, force:detailPanel absent).
An earlier draft of this document claimed the opposite; that claim was wrong and has been removed.
Do NOT stop on G0 and do NOT hand-author a Dynamic Forms conversion.

🔴 BUT DO THIS FIRST: an uncommitted retrieve of this file was silently reverted out of the working
tree once already, mid-task. Before you edit it, (a) re-confirm the `Placer` and `CoStar` section
labels are still present in the file on disk, and (b) commit the retrieved file as its own change so
the diff of YOUR edit is readable against it. If the sections are missing, re-retrieve rather than
authoring them.

── TASK 1: create three custom fields on Opportunity ────────────────────────────
  a) Monthly_Visits__c
     Label: Monthly Visits | Type: Number | precision 18 | scale 0 | required false
     Description: "Placer.ai monthly visit count for this deal. Manually entered - no live
     Placer.ai connection exists. Mirrors Property__c.Monthly_Visits__c; the two are not reconciled."
  b) Placer_Last_Synced_DateTime__c
     Label: Placer Last Synced | Type: DateTime | required false
     Description: "Stamped by the Sync button on the Placer card. STUB: no external system is
     contacted, so this records when a user pressed the button, not when data was refreshed."
  c) CoStar_Last_Synced_DateTime__c
     Label: CoStar Last Synced | Type: DateTime | required false
     Description: "Stamped by the Sync button on the CoStar card. STUB: no external system is
     contacted, so this records when a user pressed the button, not when data was refreshed."
  All three: trackFeedHistory false, trackTrending false, externalId false, unique false.
  🔴 The _DateTime__c suffix is MANDATORY and is not stylistic. ARCHITECTURE §1 rule 6 forbids a
  `Date` suffix on a DateTime field, and rule 4 reserves the `<Subject>_<PastParticiple>` form
  (`Placer_Last_Synced__c`) for Booleans. Do not shorten either name.
  If a description exceeds 255 chars, use an XML comment INSIDE the root element - never above it,
  which breaks `sf` at source conversion.

── TASK 2: FLS on the three new fields, in THREE permission sets ────────────────
  🔴 BEFORE EDITING: retrieve all three sets from usman-dpeg and diff against the repo copies. A
  PermissionSet deploy REPLACES its entire <fieldPermissions> list, so any org-side-only grant absent
  from the file is silently wiped by this deploy. This repo was bitten by exactly that twice
  (2026-08-05 and 2026-08-06). profiles/** is .forceignore'd, so there is no fallback.
    - DPEG_Acquisition_Edit  -> all three, readable=true  editable=true
    - DPEG_Acquisition_View  -> all three, readable=true  editable=false
    - DPEG_Opportunity_View  -> all three, readable=true  editable=false
  ⚠ Do NOT add these to DPEG_Admin_Access. Measured: it holds 49 fieldPermissions, of which 7 are
  Opportunity fields, and none of Placer_URL__c / CoStar_URL__c / Market_Cap_Rate__c /
  OneDrive_Folder_URL__c is among them - so a bare admin already cannot see today's Placer/CoStar
  fields. Granting only the three NEW ones there would give an admin a card showing a timestamp and
  nothing else. Grant where the SIBLING fields live: the three sets above.

── TASK 3 (requires G0 and the deployed c/marketDataSync): edit the FlexiPage ───
  REMOVE:
    - the flexipage:fieldSection componentInstance labelled `Placer`, AND its whole facet chain
      (fieldSection -> `columns` facet -> flexipage:column instances -> field facets). Expect 3-4
      <flexiPageRegions> blocks, not one. Do not orphan facets.
    - the same for the `CoStar` section.
    - the fieldInstance for Record.Market_Cap_Rate__c from whichever section holds it (it is now
      rendered inside the CoStar card).
    - the fieldInstance for Record.Placer_URL__c from `Acquisition Deal Details` (now in the card).
  ADD, in the ordinal positions the removed sections occupied:
    <componentInstance>
        <componentInstanceProperties><name>source</name><value>Placer</value></componentInstanceProperties>
        <componentName>marketDataSync</componentName>
        <identifier>placerSyncCard</identifier>
    </componentInstance>
    ...and the CoStar twin (<value>CoStar</value>, <identifier>costarSyncCard</identifier>).
  MOVE:
    - Record.OneDrive_Folder_URL__c into the `Acquisition Deal Details` field facet. It is a
      document-folder link with no relationship to Placer and must NOT be dropped.
  VERIFY AFTER THE EDIT:
    - grep `\$Permission\.CustomPermission\.Acquisition_Deal_Actions` and assert exactly 8. All 8
      live in the `header` region's force:highlightsPanel actionNames valueList and must survive
      byte-identical. All 8 are live <criteria>; none is comment prose.
    - the developmentTab / constructionTab Deal_Type__c visibility rules are untouched.
    - all 9 tabs still present.
  🔴 A FlexiPage deploy can roll back with a design-time error and REPORT AS SUCCESS. After deploy,
  retrieve the page back and read the deployed result. A green deploy is not evidence.
  🔴 Do NOT enable or re-enable Dynamic Actions in App Builder as part of this work - it silently
  discards the page's inherited layout action list.

── TASK 4: do NOT touch ─────────────────────────────────────────────────────────
  Opportunity-Opportunity Layout.layout-meta.xml (Market_Cap_Rate__c stays on it - the layout still
  backs Classic and the compact layout); any Property__c field; DPEG_Admin_Access; any
  customPermissions/ file. Create no validation rules, no flows, no permission sets, no custom
  permissions - none was requested.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md §5 (LWC/UI - especially the guard-util table and the confirmation-dialog
subsection) before starting. Build ONE LWC bundle and its Jest suite. Write NO Apex - this feature
has no controller, no service, no selector and no test class. API version 67.0.

── BUILD: force-app/main/default/lwc/marketDataSync/ ────────────────────────────
A record-page card that renders one market-data source's fields on an Opportunity, plus a
`Last Synced (manual)` row and a Sync button that stamps a DateTime on the record.

ONE bundle, not two. ARCHITECTURE §5 records that `transactionAdvanceStage` was built and DELETED
the same day (2026-08-12, review W3) for being byte-identical to `advanceRecordStage` below the
comments: "a copy carrying only a different header is not a split". Placer and CoStar differ in DATA
(title, icon, field list, stamp field), not in BEHAVIOUR.

PARAMETERISATION - mirror advanceRecordStage's CONFIG_BY_TYPE precedent:
  - targetConfigs: target lightning__RecordPage, <objects><object>Opportunity</object></objects>
    (the ELEMENT form; the `objects=` attribute form is rejected by the API).
  - One design property: `source` (String, required, default "Placer").
  - A CONFIG_BY_SOURCE map in the JS keyed "Placer" / "CoStar", each holding: title, SLDS icon name,
    the field list, and the stamp field name. Field API names arrive as @salesforce/schema imports
    (e.g. @salesforce/schema/Opportunity.Placer_Last_Synced_DateTime__c) so a rename is a BUILD
    failure, never a silently empty card.
      Placer  -> fields [Placer_URL__c, Monthly_Visits__c], stamp Placer_Last_Synced_DateTime__c
      CoStar  -> fields [CoStar_URL__c, Market_Cap_Rate__c], stamp CoStar_Last_Synced_DateTime__c
  - A `source` value not in the map MUST render a visible inline role="alert" naming the accepted
    values. A silently empty card is indistinguishable from "no data" and is the failure to design out.

WRITE PATH - LDS, NOT APEX:
  Use updateRecord from lightning/uiRecordApi: { fields: { Id: this.recordId, [stampField]: iso } }.
  🔴 DO NOT CALL getRecordNotifyChange. updateRecord writes THROUGH the LDS cache, so the page
  re-renders on its own - this is the c/leadStatusChange rule, and it is the OPPOSITE of the
  c/dealActionGuard / c/recordStageGuard rule, which applies only to imperative Apex DML. A Jest test
  asserting zero invocations is required (see J6) and must not be deleted.
  🔴 ERROR HANDLING: copy c/leadStatusChange's error reducer, NOT c/dealActionGuard's. An LDS write
  failure surfaces at error.body.output.errors[] and error.body.output.fieldErrors{}; body.message is
  often EMPTY for these, so a body.message-only read renders a blank or generic toast that hides the
  real reason. Read output.errors -> output.fieldErrors -> body.message -> a fallback constant.

PERMISSION GATING - NONE, deliberately:
  No custom permission, no <visibilityRule>. The button writes one field the user can already type by
  hand; FLS edit on the stamp field IS the gate and is already modelled across the three permission
  sets. Instead: read the stamp field's `updateable` flag (getObjectInfo or getRecord field metadata)
  and render the button DISABLED with a reason when it is false - never hidden silently, never left to
  throw on click.
  🔴 Never bind a visibility rule to a FIELD - it evaluates FALSE for anyone lacking FLS READ, with no
  error and no log. That defect is why the User.*_Driver__c model was retired.

RENDERING - "keep the design the same":
  Use lightning-record-form mode="view" columns="2" with an explicit `fields` list. It renders
  platform-identical field rows WITH per-field inline-edit pencils - the nearest available reproduction
  of a Dynamic Forms field section, and it preserves editability (all four fields are behavior=Edit on
  the layout today, so a read-only card would be a functional regression).
  Around it: an slds-section__title / slds-text-title_caps heading matching a fieldSection header; a
  slds-grid slds-wrap + slds-size_1-of-2 two-column body; the Last Synced row via
  lightning-formatted-date-time as a NORMAL field row (not a badge, not a coloured pill); the Sync
  button as lightning-button variant="neutral" (NOT brand) in a footer row.
  SLDS 2 design tokens only (--slds-g-*). No hardcoded colours, hex or px. Run the SLDS linter.
  ⚠ Do NOT apply the .lv-* list-view chrome - measured, those classes live in one bundle and this is a
  field section, not a list.

🔴 THE STUB WARNING IS A REQUIREMENT, NOT A NICETY:
  Sync contacts NOTHING - no callout, no ASB spoke, no data refresh. A user reading a fresh timestamp
  will conclude the values beside it were just retrieved; they were typed by hand. Therefore:
    - label the row "Last Synced (manual)", never bare "Last Synced";
    - attach a lightning-helptext saying no connection to Placer.ai / CoStar exists yet and the values
      above are entered by hand;
    - NO spinner, NO "Syncing..." state, NO progress indicator, NO artificial delay. Animating a fetch
      that does not happen is how a stub becomes a lie. Stamp and toast immediately.
  Record all of this in the bundle's class header, together with the forward path: when the real
  callout lands the write moves to Apex (System.now()), getRecordNotifyChange BECOMES required, and a
  status field modelled on Property__c.Placer_Fetch_Status__c ships in the same change.

── JEST: lwc/marketDataSync/__tests__/marketDataSync.test.js ────────────────────
  J1 Placer config renders the right title and field set; CoStar_URL__c absent.
  J2 CoStar config renders the right title and field set; Monthly_Visits__c absent.
  J3 Invalid/blank `source` renders an inline role="alert" naming accepted values; no throw.
  J4 Sync (Placer) calls updateRecord once with Id + Placer_Last_Synced_DateTime__c and no other field.
  J5 Sync (CoStar) targets CoStar_Last_Synced_DateTime__c.
  J6 🔴 getRecordNotifyChange is NEVER called. Permanent falsifier - do not delete.
  J7 Success toast fires; the Last Synced row re-renders from the refreshed record, not local state.
  J8 Error body.output.errors[0].message is surfaced verbatim, not a fallback.
  J9 Error body.output.fieldErrors is extracted, not swallowed.
  J10 Unusable error falls back to the module constant; never "undefined" or "[object Object]".
  J11 Field not updateable -> button disabled with a reason; click dispatches nothing.
  J12 @sa11y/jest passes in both configs and in the error state (sa11y v8 needs the explicit setup()).
  Mock lightning/uiRecordApi at MODULE level, not by instance-spy.
  ⚠ .claude/rules/bulk-test-rule.md's 251-record mandate does NOT apply - it governs triggers, batch
  jobs, DML-performing services and queueables, and this feature has none. Note that in the test
  header so it is not raised at review.

── ARCHITECTURE.md §6 ───────────────────────────────────────────────────────────
Propose the §5 amendment in the same PR: the `source` + CONFIG_BY_SOURCE pattern as the house shape
for a multi-instance record-page card, and the LDS-write / no-getRecordNotifyChange pairing.
```

---

## ✅ GATE-1 ANSWERS — settled 2026-08-16, do not re-open

**Button label: `Sync`.** The user chose `Sync` over the design's preferred `Mark Synced`. That
choice is conditional and the condition is not negotiable: **`Sync` is only acceptable WITH all three
R1 mitigations** — the row labelled `Last Synced (manual)`, the helptext stating that no Placer.ai /
CoStar connection exists and the values are hand-entered, and **no spinner, no "Syncing…" state, no
progress indicator, no artificial delay**. Dropping any of them turns the label into a claim the
feature cannot support. If a future change removes the mitigations, the label must change with them.

**R2 (blank URL rows): accepted as-is.** The user chose to leave `Opportunity.Placer_URL__c` /
`CoStar_URL__c` unpopulated and hand-typed, over extending `LeadConvertService` or rendering the
`Property__r` twins. ⇒ **`LeadConvertService` is OUT OF SCOPE and must not be touched.** Both cards
will render an empty URL row on every lead-converted deal on day one; that is the expected state, is
pinned as UAT case **U7**, and is not a build defect. Do not "fix" it during implementation or flag it
as one at code review.

Everything else in this document was already decided.
