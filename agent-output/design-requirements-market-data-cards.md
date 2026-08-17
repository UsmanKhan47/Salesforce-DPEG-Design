# Design Requirements — Placer & CoStar Market Data on the Opportunity Record Page

**Date:** 2026-08-17
**Design agent output.** No metadata, Apex or LWC was written by this pass.
**Supersedes nothing.** It EXTENDS `agent-output/design-requirements-placer-costar-sync.md` (the card's
original design). Read that document's D-numbers and R-numbers; this one reuses them where the
decision still stands and states explicitly where it reverses one.

---

## 🎯 WHAT THE USER REQUESTED (verbatim)

> "From the FSD fetch what fields are required from placer and costar, create them and populate their
> values in the existing record and show them under placer and costar lwc section on opportunity
> record page"

Four verbs: **fetch (the spec) → create (the fields) → populate (the values) → show (on the card).**

---

## 🔴 HEADLINE: ONE OF THE FOUR VERBS IS ALREADY DONE, AND SAYING SO IS THE MOST VALUABLE THING IN THIS DOCUMENT

**"Create them" requires creating nothing. Every field the FSD asks for already exists on
`Property__c`.** Verified against the working tree 2026-08-17 by direct file read, not by grep alone.

| FSD §18.2 "Data Captured" | Field | Type (measured) | Exists |
|---|---|---|---|
| **Placer — Layer 1 link** | `Property__c.Placer_URL__c` | Url | ✅ |
| Placer — State Rank | `Property__c.Placer_State_Rank__c` | Number(6,0) | ✅ |
| Placer — State Percentile | `Property__c.Placer_State_Percentile__c` | Percent(5,2) | ✅ |
| Placer — MSA Rank | `Property__c.Placer_MSA_Rank__c` | Number(6,0) | ✅ |
| Placer — National Rank | `Property__c.Placer_National_Rank__c` | Number(6,0) | ✅ |
| Placer — Data Source | `Property__c.Placer_Data_Source__c` | Picklist {Manual, Integrated} | ✅ |
| Placer — Last Synced | `Property__c.Placer_Last_Synced_DateTime__c` | DateTime | ✅ |
| Placer — Sync Status | `Property__c.Placer_Fetch_Status__c` | Picklist {**Not Synced**, Success, Error} | ✅ |
| **CoStar — Layer 1 link** | `Property__c.CoStar_URL__c` | Url | ✅ |
| CoStar — % Leased | `Property__c.CoStar_Pct_Leased__c` | Percent(5,2) | ✅ |
| CoStar — Location Score | `Property__c.CoStar_Location_Score__c` | Number(4,1) | ✅ |
| CoStar — Market Rent (PSF) | `Property__c.Market_Rent_PSF__c` | Currency(18,2) | ✅ |
| CoStar — Asking Rent (PSF) | `Property__c.CoStar_Asking_Rent_PSF__c` | Currency(18,2) | ✅ |
| CoStar — Cap Compression / Exit Cap | `Property__c.CoStar_Exit_Cap_Rate__c` | Percent(5,2) | ✅ |
| CoStar — Data Source | `Property__c.CoStar_Data_Source__c` | Picklist {Manual, Integrated} | ✅ |
| CoStar — Last Synced | `Property__c.CoStar_Last_Synced_DateTime__c` | DateTime | ✅ |
| CoStar — Sync Status | `Property__c.CoStar_Fetch_Status__c` | Picklist {**Not Synced**, Success, Error} | ✅ |

⚠ **One correction to the established facts, and it matters for the seed.** The two `*_Fetch_Status__c`
picklists carry **THREE** values — `Not Synced`, `Success`, `Error` — not the two (`Success` / `Error`)
that `design-requirements-placer-costar-sync.md` §D3 asserted when it argued against building a status
field on `Opportunity`. That older argument ("a stub can only ever write `Success`, so a two-value
restricted picklist with one reachable value is a constant with a picklist around it") is **now moot
for `Property__c`**, because `Not Synced` is a truthful, reachable third value. This is precisely what
lets the seed be honest rather than a lie (see D7). Do not carry the two-value claim forward.

⇒ **The deliverable is RENDER + SEED, not CREATE.** Anyone who builds `Opportunity` duplicates of
these seventeen fields will have done the opposite of what Gate-1 decided.

### 🔴 A SECOND THING IS ALREADY DONE: THE FLS

Measured across `permissionsets/`, 2026-08-17. All seventeen fields are already declared in three
permission sets with the correct editable flags, **and all three already carry object-level
`viewAllRecords = true` on `Property__c`** — which is what makes the whole "render the parent record"
approach viable at all (see D2).

| Permission set | `Property__c` object | The 17 fields | Effect on the card |
|---|---|---|---|
| `DPEG_Acquisition_Edit` | `allowRead` ✅ `allowEdit` ✅ `viewAllRecords` ✅ | `readable=true` `editable=true` | Editable card, Sync enabled |
| `DPEG_Acquisition_View` | `allowRead` ✅ `allowEdit` ❌ `viewAllRecords` ✅ | `readable=true` `editable=false` | Read-only card, Sync **disabled with a reason** |
| `DPEG_Property_View` (Transactions persona) | `allowRead` ✅ `allowEdit` ❌ `viewAllRecords` ✅ | `readable=true` `editable=false` | Read-only card, Sync disabled |

⇒ **This design requires ZERO permission-set edits.** That is not a convenience — it is the answer to
the undeployable-permission-set problem in the brief (see D6).

`DPEG_Admin_Access` holds none of them, exactly as it holds none of today's Opportunity Placer/CoStar
fields. That remains correct and is UAT case **U4**, not a bug.

### 🔴 A THIRD THING IS ALREADY DONE: THE FLEXIPAGE

`Opportunity_Record_Page.flexipage-meta.xml` **already carries both card instances** —
`placerSyncCard` (`source` = `Placer`) and `costarSyncCard` (`source` = `CoStar`) — and the
`Opportunity.Placer_URL__c` / `Opportunity.Market_Cap_Rate__c` field instances have already been
removed from the Detail tab. The only surviving `Market_Cap_Rate__c` instance is
`Record.Primary_Underwriting__r.Market_Cap_Rate__c`, which is a **different field on a different
object** (the pre-existing duplicate-LABEL trap recorded as U6 in the prior design).

⇒ **No FlexiPage edit is required by this change** (see D9). That removes the single highest-risk
declarative surface in this repo from the change set entirely.

---

## ⚠ CONCURRENT-SESSION COLLISION — READ BEFORE STARTING

Everything above was authored **today, 2026-08-17, by a different session working in this same
repo**, and much of it is **uncommitted**. `git status` at the start of this pass showed a modified
`.claude/agents/salesforce-devops.md` and an untracked
`agent-output/design-requirements-deal-portfolio.md`; the seventeen `Property__c` fields, the FLS
grants, `MarketDataSnapshotService`, `Property_Package__c` and the FlexiPage card instances are all
newer than the last commit shown (`027f73b`).

Three concrete consequences, none hypothetical — the prior design's **R7** records that an
uncommitted retrieve of this very FlexiPage was **silently reverted mid-task once already**:

1. **Re-verify before relying.** Every "already exists" claim in this document is a claim about the
   working tree at the time of writing. Re-read the field file, the permission set and the FlexiPage
   immediately before editing. A retrieve is not a durable fact until it is a commit.
2. **The other session may be about to surface the same data.** `MarketDataSnapshotService` already
   reads all seventeen fields and freezes them into `Opportunity.Market_Data_Snapshot__c`. If that
   session also adds a Property market panel or a Dynamic Forms section, the org gets two renderings
   of one dataset — which is exactly the harm the prior design's **D1** argued against for
   `Market_Cap_Rate__c`. **Ask before building.**
3. **Commit first.** Commit the concurrent session's `Property__c` fields, permission sets and
   FlexiPage as their own change **before** this change begins, so the diff of this work is readable
   against them.

---

## 📐 DESIGN DECISIONS

### D1 — Reframe the ask: this change RENDERS and SEEDS. It creates no field.

**Decision: create zero custom fields.**

Gate-1 decision 1 already settled that the cards read `Property__r.*` rather than Opportunity
duplicates, and it did so as an explicit **reversal** of the earlier decision (prior design D3) that
"fields live on Opportunity". That reversal is correct and is now doubly supported:

- `MarketDataSnapshotService`'s own class header, §1, argues the market layer belongs on `Property__c`
  because *"the market fields live on `Property__c`, which is shared by every deal targeting that
  property"* — the same reason `PropertyAssetService` and `DealFolderService` key idempotency on the
  Property. Two deals against one property must see one market picture.
- FSD §18.1 says the data belongs **"directly on the property record"**. Building Opportunity twins
  would contradict the spec the user asked us to read.
- ARCHITECTURE §5 (line ~1506) already declares the `Property__c` timestamps **"the authoritative
  freshness markers for the market layer"** and explicitly warns that the Opportunity ones "must not
  be read as the live sync markers".

⇒ Any request to "create the fields" is satisfied by the seventeen that exist. **Creating twins would
also create seventeen new reconciliation gaps** — the prior design's own **R3** already flags one such
gap (`Monthly_Visits__c` on two objects with nothing keeping them in step) as a residual it had to
accept. Do not manufacture sixteen more.

---

### D2 — 🔴 HOW TO RENDER PARENT FIELDS. This is the substantive engineering decision.

`lightning-record-form` **cannot** render `Property__r.*`: its `fields` are resolved against
`object-api-name`, and LDS does not accept a spanning path there. So the current card's shape does not
survive the switch unchanged. Two shapes are available.

| | **(a) Spanning read + formatted output** | **(b) Point the form at the Property record** |
|---|---|---|
| Mechanism | `@wire getRecord` on the Opportunity with `Opportunity.Property__r.X` fields, rendered with `lightning-formatted-*` in hand-built `slds-form-element` rows | `@wire getRecord` on the Opportunity for `Opportunity.Property__c` (the Id only), then `<lightning-record-form record-id={propertyId} object-api-name="Property__c" ...>` |
| Editing | ❌ **Read-only. Lost.** | ✅ **Preserved** — per-field inline-edit pencils and the form's own Save/Cancel bar |
| Visual fidelity | Hand-built rows approximating a field section | Platform-rendered field rows — the same construct the card renders today |
| Extra wires | 1 (a wide spanning read) | 1 (a one-field read) + 1 form |
| URL fields | Must hand-render an anchor via `lightning-formatted-url` | Rendered as a link by the platform, as today |
| Picklists | Render as raw API values unless separately resolved | Rendered with their labels, as today |
| Sharing dependency on `Property__c` | ✅ Yes — a spanning read is still subject to the parent's sharing | ✅ Yes — identically |
| FLS surface | `Property__c` FLS | `Property__c` FLS |

**Decision: (b).**

**Why, and why (a) is specifically wrong here rather than merely inferior.** The prior design's **D9**
chose `lightning-record-form mode="view"` over `lightning-record-view-form` + `lightning-output-field`
for one stated reason: the output-field shape *"would have been closer to pixel-identical but
READ-ONLY, and every field here is behavior=Edit on the layout today — so that would have been a
functional regression, not a styling choice."* That argument is recorded in the bundle's own template
comment (lines 85–91). **Shape (a) reintroduces exactly the regression that argument rejected**, on
seventeen fields instead of four, and it does so at the moment the user has asked for MORE data on the
card — i.e. it would make the card larger and less useful in one step. Choosing (a) would be
overturning a live, argued decision by accident.

Two further facts make (b) safe here where it might not have been:

- 🔴 **The Private-OWD sharing trap does NOT bite, and that was measured rather than assumed.**
  `Property__c` is `sharingModel = Private` and its only sharing rule is an OWNER rule scoped to the
  `Acquisition` queue, which a `LeadConvertService`-created Property (owned by the converter) does not
  reach — ARCHITECTURE §2 records exactly this, and it is why `PropertySelector.FolderCreationReads`
  had to escape sharing. **But all three relevant permission sets carry
  `viewAllRecords = true` on `Property__c`** (measured above), so every persona that opens an
  Opportunity record page can already read every Property. ⚠ This is org state, not repo state, in the
  same sense ARCHITECTURE flags for `Opportunity` OWD — if `viewAllRecords` were ever removed from one
  of these sets, the card would show an access error rather than data. It fails **loudly**, which is
  the acceptable direction.
- **`allowEdit` already discriminates the personas correctly.** `DPEG_Acquisition_Edit` has it;
  `DPEG_Acquisition_View` and `DPEG_Property_View` do not. So (b) delivers an editable card to the
  acquisitions persona and a read-only one to the two view personas **with zero new metadata**, which
  is the identical property the prior design's **D6** relied on to justify having no permission gate.

#### 🔴 WHAT (b) COSTS — state this in the class header, do not discover it in UAT

1. **THE CARD NOW EDITS A SHARED RECORD FROM A PAGE THAT IS NOT ITS OWN.** A user editing
   `CoStar_Pct_Leased__c` on Deal A's page changes the number every other deal on that property sees.
   That is *correct* under `MarketDataSnapshotService` §1 ("the live layer keeps moving on
   `Property__c`") — but it is not obvious from an Opportunity page, and nothing on the screen says
   so. **Mitigation (required, not optional):** the card's help text must name the source record. The
   existing `helpText` mechanism already exists per source; extend its wording, do not add a second
   mechanism.
2. **The form's `record-id` is not `this.recordId`.** Every existing assumption in the bundle that the
   two are the same must be re-read, including the Sync write (D3) and the FLS check (which must now
   read `getObjectInfo` for `Property__c`, not `Opportunity`).
3. **Two record contexts on one page** means a save in this card does not refresh Opportunity-level
   components, and vice versa. Acceptable: nothing on the Opportunity derives from these fields except
   `Market_Data_Snapshot__c`, which is written only at approval.
4. **The `targetConfigs` restriction to `Opportunity` becomes a stronger claim, not a weaker one.** The
   component now hard-codes the traversal `Opportunity.Property__c`, so it genuinely cannot work
   anywhere else. Keep the restriction and say why in the meta description.

#### The empty and loading states multiply — handle them with the bundle's existing discipline

The bundle already distinguishes three states on the Last Synced row (`Never` / `Not available` / `—`)
and three on the button (`true` / `false` / `undefined`), and its header argues at length that *"say
nothing until you know"* is the rule. The Property Id read is a **fourth** instance of that same rule:

| Opportunity wire state | `Property__c` | Render |
|---|---|---|
| in flight | unknown | the existing `—` / no assertion. **Never** "no property". |
| answered, `Property__c` non-null | resolved | the form, bound to the Property Id |
| answered, `Property__c` **null** | none | **D5's honest empty state** |
| errored | unknown | `Not available`, the existing branch |

---

### D3 — 🔴 WHAT THE SYNC BUTTON STAMPS NOW, AND WHAT THAT ORPHANS

**Decision: the Sync button stamps `Property__c.<source>_Last_Synced_DateTime__c`.** The card's Last
Synced row reads the same Property field.

**Argued.** The freshness marker must live with the data it claims freshness for. If the card renders
Property values and stamps an Opportunity timestamp, then two deals on one property show one set of
numbers under two different "Last Synced" values — a confident wrong answer of exactly the kind the
bundle's `UNAVAILABLE_LABEL` and `LOADING_LABEL` constants exist to prevent, and the kind
`DispositionTractionService` was rewritten to stop producing. Worse, ARCHITECTURE §5 **already**
records the Opportunity twins as a *different thing* from the Property ones and warns readers not to
confuse them; leaving the button on the Opportunity field would make the card itself the source of
that confusion.

Two further supports: the Property fields are what `MarketDataSnapshotService` freezes into the
approval evidence (it emits `Last Synced` from `p.Placer_Last_Synced_DateTime__c`), so stamping
anything else would put the snapshot and the card permanently out of step; and the FSD lists
Last Synced as a **control field of the provider block**, which lives on the property.

⚠ The write target changes but the **mechanism does not**: still LDS `updateRecord`, still
`{ fields: { Id: <propertyId>, [stampField]: iso } }`, still **no `getRecordNotifyChange`** (the
write goes through the LDS cache), still no spinner. All of `design-requirements-placer-costar-sync.md`
D5 and R1 carry over verbatim.

#### 🔴 THE ORPHANS — three fields, and they must not be silently stranded

| Field | Created | Reader after this change | Recommendation |
|---|---|---|---|
| `Opportunity.Placer_Last_Synced_DateTime__c` | 2026-08-16 | **none** | **RETIRE — but not in this change** |
| `Opportunity.CoStar_Last_Synced_DateTime__c` | 2026-08-16 | **none** | **RETIRE — but not in this change** |
| `Opportunity.Monthly_Visits__c` | 2026-08-16 | **none** (card reads `Property__c.Monthly_Visits__c`) | **RETIRE — but not in this change** |
| `Opportunity.Placer_URL__c` | pre-existing | **none** on this card | **KEEP** — already known to have no writer (prior design **R2**, a user-accepted state); retiring it is a separate conversation |
| `Opportunity.CoStar_URL__c` | pre-existing | **none** on this card | **KEEP** — same |
| `Opportunity.Market_Cap_Rate__c` | pre-existing | **`Opportunity-Opportunity Layout`**, and possibly reports | 🔴 **KEEP. DO NOT RETIRE.** It has live consumers outside this card |

**Why retire the first three, and why not now.**

*Why retire:* they were created yesterday for one consumer, that consumer is being repointed, and a
field with no reader is worse than absent — it is a plausible-looking value a future developer or
report builder will use, believing it means something. `Opportunity.Monthly_Visits__c` is the sharpest
case: it is a byte-for-byte duplicate of a Property field with nothing reconciling them, already
recorded as residual **R3**, and after this change it is a duplicate that nothing even displays.

*Why not in this change, and this is the more important half:*

1. **Field deletion is destructive and this repo has paid for that.** ARCHITECTURE §1's repair record
   shows an in-place rename is a Metadata-API no-op and the only mechanism is delete-and-recreate;
   memory records that reports do **not** block deletion and break silently. Deletion belongs in its
   own reviewable change with its own grep-for-readers pass — reports, dashboards, list views, page
   layouts, pathAssistants and Flows all name fields directly and none of them is caught by an Apex or
   LWC grep.
2. **A concurrent session created them today and may still be using them** in work this pass cannot
   see. Deleting another session's day-old field is how two sessions produce a broken org neither can
   explain.
3. The repo already has the correct precedent for this shape: `UserSelector` is *"a DELETE CANDIDATE,
   not a keep"*, retained deliberately so it retires with its fields as one reviewable change, per
   `docs/permission-set-retirement-runbook.md`'s GRANT → VERIFY → REMOVE → SOAK → DELETE order.

⇒ **In THIS change:** amend the three fields' `<description>` to say they are deprecated, name the
replacement (`Property__c.<same name>`) and name the date. That is cheap, non-destructive, and it is
the thing that stops the next reader adopting them. ⇒ **In a follow-up change:** grep reports,
dashboards, list views, layouts and Flows for all three, confirm zero stored non-null values in the
org, then delete the fields and their `<fieldPermissions>` together.

⚠ **Do not "retire" a field by removing only its `fieldPermissions`.** That leaves the field present
and invisible, which is a worse state than either keeping or deleting it — and a `PermissionSet`
deploy replaces the whole grant list anyway, so the removal would look like an accident to the next
reconciler.

---

### D4 — WHICH FIELDS EACH CARD SHOWS

**Decision: every field the FSD §18.2 table lists, plus the one incumbent per card that is already
rendered today.** Nothing else on `Property__c`.

**Placer card — 8 form fields + the bespoke Last Synced row**

| Order | Field | Why |
|---|---|---|
| 1 | `Placer_URL__c` | FSD Layer 1 |
| 2 | `Placer_State_Rank__c` | FSD Layer 2 |
| 3 | `Placer_State_Percentile__c` | FSD Layer 2 |
| 4 | `Placer_MSA_Rank__c` | FSD Layer 2 |
| 5 | `Placer_National_Rank__c` | FSD Layer 2 |
| 6 | `Monthly_Visits__c` | **INCUMBENT** — rendered on this card today; dropping it is a visible regression |
| 7 | `Placer_Data_Source__c` | FSD control |
| 8 | `Placer_Fetch_Status__c` | FSD control |
| — | `Placer_Last_Synced_DateTime__c` | FSD control — rendered as the **existing bespoke row**, not in the form (see below) |

**CoStar card — 9 form fields + the bespoke Last Synced row**

| Order | Field | Why |
|---|---|---|
| 1 | `CoStar_URL__c` | FSD Layer 1 |
| 2 | `CoStar_Pct_Leased__c` | FSD Layer 2 |
| 3 | `CoStar_Location_Score__c` | FSD Layer 2 |
| 4 | `CoStar_Asking_Rent_PSF__c` | FSD Layer 2 |
| 5 | `Market_Rent_PSF__c` | FSD Layer 2 — see the naming note below |
| 6 | `CoStar_Exit_Cap_Rate__c` | FSD Layer 2 ("Cap Compression / Exit Cap") |
| 7 | `Market_Cap_Rate__c` | **INCUMBENT** — rendered on this card today; a distinct fact from Exit Cap |
| 8 | `CoStar_Data_Source__c` | FSD control |
| 9 | `CoStar_Fetch_Status__c` | FSD control |
| — | `CoStar_Last_Synced_DateTime__c` | FSD control — the bespoke row |

**Why "a lot for a record-page card" is not the objection it looks like.** The card is
**collapsible** and the collapse is already built (`_isOpen`, the SLDS Expandable Section blueprint),
and the form is `columns="2"`, so eight fields is four visual rows. The FSD is the spec the user
explicitly asked us to read; omitting a listed field would require a rule for *which* omissions are
acceptable, and no such rule exists. If the density turns out to be wrong in UAT, the cheap remedy is
`_isOpen = false` by default — a one-line change — **not** dropping fields.

**Why Last Synced stays as the bespoke row and does NOT move into the form.** That row carries three
of the four stub mitigations the prior design made a *condition* of the `Sync` label: the
`(manual)` suffix, the `lightning-helptext`, and the three-state `Never` / `Not available` / `—`
rendering. A `lightning-record-form` field would render a bare timestamp with the field's own label
and no help text, silently deleting all three. This is a **hard constraint**, not a layout preference.

**Two incumbents kept, and why that is a decision rather than inertia.** `Monthly_Visits__c` and
`Market_Cap_Rate__c` are what the deployed cards render **today**. Dropping a rendering the user can
currently see, in a change whose stated purpose is to show them *more* data, is the kind of silent
regression this document exists to prevent. Both are genuine provider data (Placer visit counts;
`Property__c.Market_Cap_Rate__c` carries the description *"CoStar via ASB (stub)"*). ⚠ **The one
thing to watch:** the CoStar card will now show **two cap rates** — `CoStar_Exit_Cap_Rate__c` and
`Market_Cap_Rate__c`. They are different facts (the exit assumption vs. the prevailing market rate),
but a reader may not know that. **Required:** verify both fields carry a `<description>` distinguishing
them; if either is blank, that is admin work in this change.

**Deliberately EXCLUDED, and named so the omission is auditable:** `Trade_Area_Population__c`,
`Peak_Hour__c`, `YoY_Growth__c`, `Comp_Monthly_Visits__c`, `Comp_Sales__c`,
`Visitor_Demographics__c`, `Occupancy_Rate_Market__c`, `Days_On_Market_Avg__c`. All are pre-existing
`Property__c` market fields, all are read by `MarketDataSnapshotService`, and **none is in FSD §18.2's
"Data Captured" table**, which is the list the user asked us to fetch. The two `LongTextArea` fields
are additionally unsuited to a two-column card — `MarketDataSnapshotService` excludes those same two
from its frozen block for the same reason and *says so in the block itself*. If the user wants them,
that is a follow-up with its own layout question.

#### 🔴 `Market_Rent_PSF__c` has no `CoStar_` prefix. Does it matter?

**It matters in exactly one way, and the remedy is not a rename.**

*Why the name is not wrong:* ARCHITECTURE §1 rule 5 governs currency naming, and for a **per-unit
rate** the rule is "suffix the unit" — `Rent_PSF__c` is the rule's own worked example. `Market_Rent_PSF__c`
is fully §1-compliant. It also predates the CoStar block (it sits with the original `Property__c`
field set alongside `Market_Cap_Rate__c`, not with the 2026-08-17 additions), so the inconsistency is
chronological, not careless.

*Why a rename is the wrong remedy:* §1's own repair record establishes that an in-place field rename
is a **Metadata-API no-op** and the only mechanism is **delete-and-recreate**. This field is referenced
by `MarketDataSnapshotService.compose`, by three permission sets, and potentially by reports — which
do not block deletion and break silently. That is a multi-deploy destructive change to fix a prefix.

*Where it DOES matter:* **anyone auditing "the CoStar block" by grepping the `CoStar_` prefix will
miss it.** That is a real, recurring failure mode — it is how this pass nearly under-counted the field
set. Two cheap mitigations, both in scope:

1. The card renders it **inside the CoStar section**, so the UI carries the grouping the name does
   not. (Already the plan.)
2. Its `<description>` must state that it is the **CoStar** market rent and note the naming exception.
   Verify and amend if absent — this is the entire admin remedy.

---

### D5 — 🔴 A NULL `Property__c`. The card must be honest, not blank and not broken.

A manually-created deal has no Property: only `LeadConvertService` creates and links one. This is a
live, named residual on three separate features already (`PropertyAssetService` R1, `DealFolderService`
R1, `MarketDataSnapshotService` R1), and `MarketDataSnapshotService` resolves it by writing the literal
text *"No property linked to this deal - no market data to snapshot."* — because, in its own words, *"an
empty field is indistinguishable from 'the snapshot never ran'."*

**Decision: a distinct, visible, non-alarming empty state.**

| Requirement | Detail |
|---|---|
| Render | An inline note inside the card body: *"No property is linked to this deal, so there is no market data to show."* |
| Role | `role="status"`, **not** `role="alert"` |
| The form | Not rendered at all. `lightning-record-form` with a null `record-id` must never be mounted. |
| The Sync button | Rendered and **disabled**, with the same reason text beside it — never hidden |
| Last Synced row | Not rendered (there is no field to read) |
| Timing | Only after the Opportunity wire has answered. Before that, assert nothing. |

🔴 **`role="status"` and not `role="alert"`, and this is the same distinction the bundle already
draws twice.** `role="alert"` is reserved for `configError` — a **misconfiguration by an
administrator**, something that is *wrong* and that nobody else in the org will ever report. A deal
with no Property is an ordinary, expected state that a user can fix by filling in the lookup.
Collapsing the two would train users to ignore the alert that actually matters. This is the same rule
as `Never` vs `Not available` and as the three-state `stampFieldUpdateable`: *the message must not
assert a cause you have not established.*

⚠ **Do not hide the card when there is no Property.** A hidden card is indistinguishable from "this
org has no market data feature", and hiding a control from a user who is genuinely authorized is the
exact defect that retired the `User.*_Driver__c` model.

---

### D6 — FLS AND THE UNDEPLOYABLE PERMISSION SETS

**Decision: touch no permission set. The sequencing problem is solved by not having the dependency.**

The brief's constraint is real: `DPEG_Acquisition_Edit` and `DPEG_Acquisition_View` currently declare
`Property_Package__c` object permissions and six `Property_Package__c.*` field permissions (plus
`Lead.Property_Package__c`, `Opportunity.Property_Package__c`, `Property__c.Property_Package__c`) for
an object created **in the repo today** by the concurrent session. Until `Property_Package__c` is
deployed to the org, **both files fail to deploy**. `Broker_Protection_Access` carries the same
dependency.

Because D2's rendering approach requires no new field and no new grant, this change **has no reason to
deploy those files at all**. That is the whole answer.

**Two orders, depending on one fact you must check first.**

> **Check:** are the seventeen `Property__c` grants and `viewAllRecords` present **in the org**
> (`usman-dpeg`), or only in the working tree? Retrieve the three sets and compare. The concurrent
> session authored them today; if it has not deployed, the org does not have them.

| If the grants ARE in the org | If the grants are NOT in the org |
|---|---|
| ✅ **Deploy nothing from `permissionsets/`.** This change deploys only `lwc/` (and, if D3/D4 need them, `objects/*/fields/*` description amendments). The `Property_Package__c` blocker never engages. | ⚠ **This change is COUPLED to the concurrent session.** The permission sets cannot deploy until `Property_Package__c` (object + its six fields + its tab/layout, if any) deploys first. Sequence: `Property_Package__c` object → the three permission sets → this change's LWC. **Do not** work around it by stripping the `Property_Package__c` blocks out of the permission-set files: a `PermissionSet` deploy REPLACES its whole grant list, so a stripped file silently revokes the other session's grants the moment it lands. |

🔴 **The REPLACE-not-merge rule applies even though this change adds nothing.** ARCHITECTURE §2 records
that this repo was bitten twice (2026-08-05, 2026-08-06) by a permission-set deploy made *for an
unrelated reason* wiping an org-side-only grant. If any permission set is deployed as part of this
sequencing, **retrieve it from the org and diff first**. `profiles/**` is `.forceignore`d, so there is
no fallback.

**What FLS this change actually needs, stated in full so it can be verified rather than assumed:**

- `Property__c` object: `allowRead` for all three personas; `allowEdit` for `DPEG_Acquisition_Edit`
  only; `viewAllRecords` for all three (because `Property__c` OWD is Private and its one sharing rule
  does not reach a converter-owned Property).
- The 17 fields: `readable=true` for all three; `editable=true` for `DPEG_Acquisition_Edit` only.
- **All of the above is already declared.** Verify; do not re-author.

⚠ `DPEG_Admin_Access` receives nothing, per the sibling rule. A bare administrator sees an
access-restricted card. That is UAT case **U4** and it is the expected result, not a defect — and it
is why **an admin smoke test proves nothing about this feature**.

---

### D7 — THE SEED

**Decision: one idempotent, fill-if-blank anonymous-Apex script in `scripts/`, run once, after a
preview is shown to the user.**

#### Mechanism — anonymous Apex, not a data file

| Option | Assessment |
|---|---|
| **Anonymous Apex in `scripts/seed-*.apex`** | ✅ **RECOMMENDED** — 60+ existing precedents in this repo (`seed-fsd-01…07`, `seed-pipeline`, `seed-sell-meter`, …); can query-then-update so it never creates rows; can be fill-if-blank; can print a preview before writing |
| `sf data import` / a plan JSON | ❌ Rejected — record-oriented, so it wants Ids or external Ids for existing rows; no `Property__c` external Id exists; and it cannot express "only where blank" |
| A Flow / batch class | ❌ Rejected — a permanent artefact for a one-off backfill, needing tests and a post-deploy schedule |

#### 🔴 Four properties the script MUST have

1. **IT WRITES TO REAL, LIVE RECORDS.** These are production-shaped acquisition properties, some
   attached to live deals. This is not test data and there is no rollback.
2. **FILL-IF-BLANK, PER FIELD.** Never overwrite a non-null value. A human may already have typed a
   real CoStar figure; a seed that clobbers it destroys real data and leaves a plausible-looking fake
   in its place. This exact trap is recorded for `DispositionStageEntryService.stampListingDates`,
   where an unconditional stamp would have destroyed a real `Listing_Date__c`.
3. **PREVIEW BEFORE WRITE.** The script must run in a report-only mode first — print each Property
   Name and the values it *would* write — and the user must approve the values before the writing run.
   ⚠ Main-agent `sf apex run` is classifier-blocked in this environment; route execution through the
   devops agent or hand the script to the user.
4. **THE VALUES MUST BE LABELLED AS SAMPLE DATA.** `Placer_Data_Source__c` and
   `CoStar_Data_Source__c` = `Manual`, and `Placer_Fetch_Status__c` / `CoStar_Fetch_Status__c` =
   **`Not Synced`**. That last one is the honest value and it is available (the picklists have three
   values, not two — see the headline correction). 🔴 **Do not seed `Success`.** `Success` asserts that
   a fetch succeeded; nothing has ever fetched anything. And **leave both
   `*_Last_Synced_DateTime__c` NULL** — the card renders `Never`, which is true. Seeding a timestamp
   would manufacture the exact lie that the whole `Last Synced (manual)` / helptext / no-spinner
   mitigation set exists to prevent.

#### Value ranges — realistic, type-consistent, FSD-consistent

| Field | Type | Seed range / rule |
|---|---|---|
| `Placer_URL__c` | Url | A clearly-sample URL, e.g. `https://placer.ai/property/sample/<slug>` |
| `Placer_State_Rank__c` | Number(6,0) | Integer, 1–500 |
| `Placer_State_Percentile__c` | Percent(5,2) | 50.00–99.90 — **a percentage, not 0–1**; a rank of 12 should carry a HIGH percentile (consistency between the two matters more than either value) |
| `Placer_MSA_Rank__c` | Number(6,0) | Integer, 1–200, and **≤ State Rank is implausible** — MSA is a smaller pool, so MSA rank should generally be numerically smaller |
| `Placer_National_Rank__c` | Number(6,0) | Integer, 500–20000, and **> State Rank** |
| `Monthly_Visits__c` | Number(18,0) | Integer, 40,000–900,000, scaled with `Square_Footage__c` where present |
| `CoStar_URL__c` | Url | `https://costar.com/property/sample/<slug>` |
| `CoStar_Pct_Leased__c` | Percent(5,2) | 75.00–100.00 |
| `CoStar_Location_Score__c` | Number(4,1) | 1.0–10.0, one decimal (the field's scale is 1) |
| `CoStar_Asking_Rent_PSF__c` | Currency(18,2) | 18.00–65.00 |
| `Market_Rent_PSF__c` | Currency(18,2) | Within ±15% of Asking Rent — the two must be coherent |
| `CoStar_Exit_Cap_Rate__c` | Percent(5,2) | 5.00–8.50, and **≥ `Market_Cap_Rate__c`** where that is populated (an exit cap above the going-in cap is the ordinary underwriting assumption) |
| `Placer_Data_Source__c` / `CoStar_Data_Source__c` | Picklist | `Manual` |
| `Placer_Fetch_Status__c` / `CoStar_Fetch_Status__c` | Picklist | `Not Synced` |
| `*_Last_Synced_DateTime__c` | DateTime | **NULL — do not seed** |

⚠ **Internal consistency is the point, not the individual numbers.** A property ranked 4th in its
state with a 12th-percentile score is visibly fake and will be reported as a bug during UAT. Derive
the percentile from the rank; derive Market Rent from Asking Rent; derive visits from square footage.

⚠ **Do NOT write `Market_Cap_Rate__c`.** It is pre-existing, has other consumers, and is not part of
the FSD provider block being seeded.

#### Scope

All `Property__c` records (Gate-1 decision 2). Bulk-safe: one query, one `update`. `Database.update(…,
false)` so one bad row cannot roll back the batch, with failures printed by name. Print a final count
of rows written and rows skipped-because-already-populated.

---

### D8 — RECORD TYPE / PAGE PLACEMENT: NO CHANGE

Both `componentInstance` blocks already exist on the Detail tab with the correct `source` values and
identifiers (`placerSyncCard`, `costarSyncCard`). Nothing about placement, ordinal position, `source`
or `targetConfigs` changes.

`Opportunity` has Land and Commercial record types with one shared record page; these cards carry no
`<visibilityRule>` and should not gain one. 🔴 **Never bind a visibility rule to a FIELD** — measured
twice in this repo, it evaluates FALSE for anyone lacking FLS READ, silently.

⇒ **This change touches no FlexiPage.** Consequently none of the FlexiPage hazards apply: no
`Acquisition_Deal_Actions` re-count, no Dynamic Actions warning, no deploy-reports-success-then-rolls-back
readback. That is a substantial risk reduction and it should be preserved — if a later revision does
need a FlexiPage edit, the prior design's **D8** carries the full checklist.

---

### D9 — ONE BUNDLE, STILL

`c/marketDataSync` remains one bundle keyed by `source` + `CONFIG_BY_SOURCE`. Placer and CoStar still
differ only in **data** (title, field list, stamp field, help text), not in **behaviour** — and this
change makes them differ in *more* data and no more behaviour. ARCHITECTURE §5's "Parameterised
record-page cards" subsection is the governing rule; `transactionAdvanceStage` is the precedent for
what happens to a copy that differs only in its header.

Everything in the existing class header stays true and must be preserved verbatim except where D2/D3
require an edit:

- 🔴 Sync still contacts nothing → `Last Synced (manual)`, the helptext, **no spinner / no busy state /
  no `isBusy` property**. The `Sync` label remains conditional on all three.
- 🔴 `getRecordNotifyChange` still **forbidden** — the write is still LDS `updateRecord`. The J6 test
  is the permanent falsifier and must not be deleted.
- The `messageFor` LDS error reducer (`output.errors` → `output.fieldErrors` → `body.message` →
  fallback) stays. Do **not** swap in `c/dealActionGuard`'s `body.message`-only read.
- No permission gate, no custom permission, no `<visibilityRule>`. FLS is the gate — now
  `Property__c`'s.
- Field API names still arrive as `@salesforce/schema/Property__c.*` imports, never as strings.
- The collapsible SLDS Expandable Section header, sentence-case title, `utility:switch` chevron, no
  source icon — all unchanged.

---

## 📦 COMPONENT INVENTORY

### 🔵 ADMIN (declarative) — small, and mostly verification

| # | Artefact | Action |
|---|---|---|
| A1 | The 17 `Property__c` fields | ✅ **VERIFY ONLY — already exist.** Create nothing |
| A2 | `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Property_View` | ✅ **VERIFY ONLY** — all 17 grants + `Property__c` object perms + `viewAllRecords` already present. Retrieve from `usman-dpeg` and confirm they are in the **org**, not just the file |
| A3 | `Opportunity_Record_Page.flexipage-meta.xml` | ✅ **NO CHANGE** — both card instances already present |
| A4 | `Property__c.Market_Rent_PSF__c` | **EDIT** `<description>` — state it is the **CoStar** market rent and note the missing-prefix exception (D4) |
| A5 | `Property__c.CoStar_Exit_Cap_Rate__c` and `Property__c.Market_Cap_Rate__c` | **VERIFY / EDIT** `<description>` — each must distinguish itself from the other, since both now render on one card (D4) |
| A6 | `Opportunity.Placer_Last_Synced_DateTime__c`, `Opportunity.CoStar_Last_Synced_DateTime__c`, `Opportunity.Monthly_Visits__c` | **EDIT** `<description>` — mark DEPRECATED as of 2026-08-17, name the `Property__c` replacement. **DO NOT DELETE** (D3) |
| A7 | `Property_Package__c` object + fields | ⚠ **OUT OF SCOPE** — but it is the deploy blocker for A2 if the permission sets must be deployed. Sequence, do not edit |

**Explicitly not touched:** any permission set's grant list, `Opportunity-Opportunity Layout`, any
FlexiPage, any `customPermissions/` file, `DPEG_Admin_Access`. No new fields, validation rules,
flows, permission sets or custom permissions — none was requested.

### 🟢 DEVELOPMENT (programmatic)

| # | Artefact | Action |
|---|---|---|
| D1 | `lwc/marketDataSync/marketDataSync.js` | **EDIT** — Property-Id wire, `CONFIG_BY_SOURCE` repointed to `Property__c` schema imports, stamp target, `getObjectInfo` target, no-property state |
| D2 | `lwc/marketDataSync/marketDataSync.html` | **EDIT** — form bound to the Property record, no-property `role="status"` branch, field count |
| D3 | `lwc/marketDataSync/marketDataSync.js-meta.xml` | **EDIT** — `<description>` only (it currently says "Opportunity card"; it now renders Property data) |
| D4 | `lwc/marketDataSync/marketDataSync.css` | **LIKELY NO CHANGE** — verify the two-column form still reads correctly at 8–9 fields |
| D5 | `lwc/marketDataSync/__tests__/marketDataSync.test.js` | **EDIT** — existing suite repointed + new cases (see test plan) |
| D6 | `scripts/seed-market-data.apex` | **NEW** — the fill-if-blank seed, preview mode first |

**Zero Apex classes.** No controller, no service, no selector, no trigger, no Apex test class.
`MarketDataSnapshotService` is **not** touched.

---

## 🔗 EXECUTION ORDER

1. **Commit the concurrent session's work** (the 17 fields, the permission sets, the FlexiPage) as its
   own change. *Blocks everything — see R7 and the collision section.*
2. **Verify in the org**, not the file: the 17 fields exist, the three permission sets carry the
   grants and `viewAllRecords`. *Decides whether step 3 is needed at all.*
3. **(Conditional) Deploy `Property_Package__c`, then the three permission sets** — only if step 2
   shows the grants are missing from the org. Retrieve-and-diff each set first.
4. **A4–A6** — the description amendments. Independent of everything else.
5. **D1–D5** — the LWC edit and its Jest suite. Independent of 3–4; can run in parallel.
6. **D6** — author the seed script.
7. Deploy the LWC → **UAT as three personas** → then run the seed in **preview mode**, show the user,
   get approval → run it for real → re-verify the cards.

⚠ **Seed LAST, and after a preview.** Seeding before the card renders means the first sight of the
values is on a screen nobody has verified, and the values are being written to live records.

---

## 🧭 COMPLEXITY ROUTING

| Stream | Agent | Reason |
|---|---|---|
| Admin | 🔵 **`salesforce-admin`** | Six `<description>` amendments and a verification pass. No new objects, no schema design, no security-model design, no subflow architecture, no ERD — none of `salesforce-solution-architect`'s triggers is present. The one genuinely architectural question (where the market layer lives) was settled at Gate 1 and by `MarketDataSnapshotService` |
| Development | 🟢 **`salesforce-developer`** | One existing LWC bundle edited, its Jest suite extended, one anonymous-Apex seed script. Zero Apex classes, zero SOQL in a class, zero DML in a class, no callout, no Named Credential, no LDV, no Platform Events. Gate-1 removed the entire integration surface, which is the only thing that would route this to `salesforce-technical-architect` |
| Testing | ⛔ **Skip `salesforce-unit-testing`** | No Apex class is created or modified, so there is nothing for it to test. Jest is the developer agent's own deliverable per ARCHITECTURE §5 |
| Review | 🟣 `salesforce-code-review` | Normal. Ask it specifically to check the three orphaned Opportunity fields were deprecated-in-description and **not** deleted, and that the stub mitigations survived |
| Deploy / seed | 🔴 `salesforce-devops` | LWC deploy; and the seed script, which the main agent cannot execute (`sf apex run` is classifier-blocked) |

---

## 🧪 TEST PLAN

### Jest — `lwc/marketDataSync/__tests__/marketDataSync.test.js`

Existing cases J1–J12 are **repointed, not replaced**. New and changed cases:

| # | Test | Asserts |
|---|---|---|
| J1′ | Placer config | Title "Placer"; the form's `fields` are the 8 `Property__c` Placer fields; `object-api-name` is `Property__c`; no CoStar field present |
| J2′ | CoStar config | Title "CoStar"; the 9 `Property__c` CoStar fields; no Placer field present |
| J3 | Invalid / blank `source` | Inline `role="alert"` naming accepted values. **Unchanged** |
| J4′ | Sync click, Placer | `updateRecord` called once with `{ Id: <PROPERTY id>, Placer_Last_Synced_DateTime__c: <ISO> }` — 🔴 **assert the Id is the Property's, not the Opportunity's.** This is the single highest-value new assertion in the suite |
| J5′ | Sync click, CoStar | Same, `CoStar_Last_Synced_DateTime__c` |
| J6 | 🔴 `getRecordNotifyChange` **never** called | **Unchanged and must not be deleted.** ARCHITECTURE §5 records this test is **mutation-proved** — re-prove it after the edit by temporarily adding the call and confirming the test reds |
| J7′ | Success path | Toast fires; Last Synced re-renders **from the wire**, not from local state |
| J8–J10 | LDS error shapes | Unchanged — `output.errors`, `output.fieldErrors`, unusable-error fallback |
| J11′ | Property field not updateable | Button disabled with a reason. 🔴 `getObjectInfo` must be mocked for **`Property__c`**; a suite still mocking `Opportunity` would pass while the component read the wrong object |
| **J13** | 🔴 **Null `Property__c`** | The `role="status"` no-property note renders; **no `lightning-record-form` is mounted**; the button is present and disabled; no Last Synced row; nothing throws |
| **J14** | 🔴 **Opportunity wire in flight** | Neither the form nor the no-property note renders. The "say nothing until you know" rule — this is the test that catches a `!propertyId` check written without a loaded flag |
| **J15** | Opportunity wire **errors** | Degrades to `Not available`; does **not** claim "no property linked" |
| **J16** | Property Id changes | The form's `record-id` follows it (guards against a one-shot read cached in `connectedCallback`) |
| **J17** | Stub mitigations survive | The Last Synced label contains `(manual)`; a `lightning-helptext` is present; 🔴 **no element matching `lightning-spinner` exists in any state, and the class exposes no `isBusy`/`isSyncing` property.** This is the regression pin for the one mitigation a "polish" pass is most likely to undo |
| J12′ | Accessibility | `@sa11y/jest` in both configs, the error state **and the new no-property state**. sa11y v8 needs the explicit `setup()` |

⚠ Mock `lightning/uiRecordApi` and `lightning/uiObjectInfoApi` at **module** level, not by
instance-spy — a repo-recorded Jest gotcha.
⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does **not** apply: it governs triggers,
batch jobs, DML-performing services and queueables, and this feature has none. State that in the test
header so it is not raised at review.

### Seed script verification (not a Jest test — a procedure)

| # | Check |
|---|---|
| S1 | Preview run prints every Property and every proposed value; **writes nothing** |
| S2 | User approves the values before the writing run |
| S3 | Re-running the writing run writes **zero** rows (idempotence via fill-if-blank) |
| S4 | A Property with a hand-typed `CoStar_Pct_Leased__c` keeps it — the seed skips that field only |
| S5 | Every `*_Fetch_Status__c` is `Not Synced`; every `*_Data_Source__c` is `Manual`; every `*_Last_Synced_DateTime__c` is **still NULL** |
| S6 | Internal consistency spot-check on 3 properties: MSA rank ≤ state rank ≤ national rank; percentile high where rank is low; market rent within ±15% of asking rent |

### Manual UAT

| # | As | Expect |
|---|---|---|
| U1 | `DPEG_Acquisition_Edit` | Both cards render all Property fields; inline-edit pencils work; **a save changes the PROPERTY record** (open the Property directly and confirm); Sync stamps the Property timestamp and the row updates without a refresh |
| U2 | `DPEG_Acquisition_View` only | Both cards render **read-only**; Sync **disabled with a reason**, not missing, not throwing |
| U3 | `DPEG_Property_View` only (Transactions persona) | Same as U2 |
| U4 | 🔴 A bare System Administrator, no acquisitions set | Access-restricted / empty card. **Expected**, per the sibling rule. Do not "fix" by adding grants to `DPEG_Admin_Access`. **An admin smoke test proves nothing here** |
| U5 | 🔴 A deal with **no** `Property__c` | The honest no-property note, disabled Sync, no error, no blank card |
| U6 | 🔴 **Two deals on ONE property** | Both show identical values. Edit on deal A → deal B shows the change. **Confirm the user finds this acceptable** — it is the correct behaviour and the most surprising consequence of D2 |
| U7 | Any persona | The two cap rates on the CoStar card (`Exit Cap` vs `Market Cap Rate`) are distinguishable from their labels and help text alone |
| U8 | Any persona | Card density at 8–9 fields is acceptable; if not, the remedy is default-collapsed, **not** dropping fields |
| U9 | Any persona | Underwriting approval still stamps `Market_Data_Snapshot__c` and the frozen block matches what the card shows |

---

## ⚠ RESIDUALS

**R1 — 🔴 SYNC STILL CONTACTS NOTHING, AND THIS CHANGE MAKES THE LIE BIGGER.** No callout, no ASB
spoke, no Named Credential, no Placer.ai or CoStar connection. Pressing Sync writes one DateTime.
🔴 **The risk INCREASES with this change**, because the card now shows seventeen fields with
FSD-sanctioned provider names and a `Sync Status` picklist beside a timestamp — a screen that looks
far more like a working integration than the four-field card it replaces. **All three mitigations
therefore remain mandatory and are, if anything, more load-bearing than before:** the row labelled
`Last Synced (manual)`, the helptext stating no connection exists, and **no spinner / no busy state /
no artificial delay**. `Data Source = Manual` and `Sync Status = Not Synced` on every record are the
seed's contribution to the same honesty and must not be seeded to anything else. If any mitigation is
ever removed, the button label must change with it.

**R2 — The three orphaned Opportunity fields are deprecated in description only.** They still exist
and are still grantable. Deletion is a named follow-up (D3) requiring a reports / dashboards / list
views / layouts / Flows grep and an org data check first. Until then a report builder can still pick
`Opportunity.Monthly_Visits__c` and get a permanently-null column.

**R3 — `Opportunity.Placer_URL__c` / `CoStar_URL__c` still have no writer.** Prior design **R2**,
accepted by the user at Gate 1. This change removes their last rendering, so they are now unwritten
*and* unshown. Deliberately not retired — that was a user decision (`LeadConvertService` is out of
scope) and reversing it is a separate conversation.

**R4 — Editing on the Opportunity page mutates a SHARED Property record.** Correct per
`MarketDataSnapshotService` §1, surprising from an Opportunity page, and mitigated only by help text.
UAT case U6 exists to confirm the user accepts it. If they do not, the alternative is read-only
rendering (D2 shape (a)) with editing forced onto the Property page — a real option, at the cost of
the inline edit.

**R5 — `viewAllRecords` on `Property__c` is org state, not repo state.** It is present in all three
permission set files today. If it is ever removed, the card shows an access error for every persona
that loses it. It fails **loudly**, which is acceptable — but no test can catch it and no deploy will
warn.

**R6 — Nothing ages or expires the stamp.** A Last Synced of six months ago renders identically to
one from this morning. Deliberate: a staleness band on a value that was never fresh compounds R1.

**R7 — 🔴 CONCURRENT SESSION.** Every "already exists" fact here is a working-tree fact from
2026-08-17, much of it uncommitted, authored by another session. The prior design records that an
uncommitted retrieve of this exact FlexiPage was **silently reverted mid-task once already**.
Re-verify immediately before editing; commit first; and check whether that session is about to surface
the same seventeen fields somewhere else, which would produce two renderings of one dataset.

**R8 — `Market_Rent_PSF__c` keeps its non-`CoStar_` name.** A prefix-based audit of the CoStar block
will miss it, permanently. Mitigated by rendering it inside the CoStar card and by a `<description>`
amendment; not fixed, because a rename is delete-and-recreate against a field with Apex, permission-set
and probable report references.

**R9 — The card's Save bar is its own, not the page's**, and pressing Sync with an inline edit open in
the same card may discard the unsaved draft. Prior design **R9** / **R9a**. Inherent to
`lightning-record-form`; the form exposes no dirty state, so the click cannot be gated on it.
Unchanged by this design.

**R10 — Seeded values are fiction on live records.** Fill-if-blank protects real data, but every
blank field is filled with a plausible number that a user may later cite in a deal discussion.
`Data Source = Manual` and `Sync Status = Not Synced` are the only in-record signals that the value
was not fetched. Consider whether the user wants the seed limited to a demo subset rather than all
Properties — Gate 1 chose all; this residual is the cost of that choice.

**R11 — ARCHITECTURE.md is not updated by this design.** Per §6, two amendments are owed in the
implementing PR: §5's "Parameterised record-page cards" subsection must record that
`c/marketDataSync` now renders and writes to a **parent** record resolved through
`Opportunity.Property__c` (a new shape for that pattern, and the first card in this repo whose
`record-id` is not its page's `recordId`); and §5's existing note at line ~1506 about the Opportunity
vs Property `Last_Synced` fields must be updated to say the Opportunity ones are now **deprecated with
no reader**. This design does not pre-write them.

---

## 📝 PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md §1 (naming rules 5 and 9) and the Permission Set Architecture subsection before
starting. Follow .claude/rules/salesforce-global-rule.md's per-type skill + API-context loop.
Do not deploy - create and edit metadata files only. API version 67.0.

🔴 CREATE NO FIELDS. The user's request says "create them", but every field the FSD asks for ALREADY
EXISTS on Property__c - all 17, verified 2026-08-17. Creating Opportunity twins would reverse a Gate-1
decision and contradict FSD §18.1. If you find yourself authoring a *.field-meta.xml for a Placer or
CoStar field, stop and re-read this line.

🔴 BEFORE ANYTHING ELSE: much of what this task depends on was authored TODAY by a CONCURRENT SESSION
and may be uncommitted. A prior design records that an uncommitted retrieve of Opportunity_Record_Page
was SILENTLY REVERTED mid-task once already. So:
  (a) re-confirm on disk that the 17 Property__c fields exist;
  (b) re-confirm the three permission sets still carry their grants;
  (c) commit that work as its own change before you edit anything.

── TASK 1: VERIFY ONLY - create and change nothing ──────────────────────────────
  Confirm these exist on Property__c and record their types:
    Placer_URL__c, Placer_State_Rank__c, Placer_State_Percentile__c, Placer_MSA_Rank__c,
    Placer_National_Rank__c, Placer_Data_Source__c, Placer_Fetch_Status__c,
    Placer_Last_Synced_DateTime__c, CoStar_URL__c, CoStar_Pct_Leased__c, CoStar_Location_Score__c,
    CoStar_Asking_Rent_PSF__c, Market_Rent_PSF__c, CoStar_Exit_Cap_Rate__c, CoStar_Data_Source__c,
    CoStar_Fetch_Status__c, CoStar_Last_Synced_DateTime__c
  Note that BOTH *_Fetch_Status__c picklists have THREE values (Not Synced / Success / Error), not
  two. An older design document says two; it is wrong and the third value matters for the seed.

── TASK 2: VERIFY the FLS is in the ORG, not just in the file ───────────────────
  Retrieve DPEG_Acquisition_Edit, DPEG_Acquisition_View and DPEG_Property_View from usman-dpeg and
  compare against the repo copies. Expected (already present in the repo files):
    - all 17 fields readable=true in all three;
    - editable=true in DPEG_Acquisition_Edit only;
    - Property__c objectPermissions with allowRead=true and viewAllRecords=true in all three,
      allowEdit=true in DPEG_Acquisition_Edit only.
  🔴 IF THEY ARE ALREADY IN THE ORG: change NOTHING in permissionsets/ and deploy none of those files.
  🔴 IF THEY ARE NOT: the sets cannot deploy yet - they reference Property_Package__c, an object that
  exists in this repo (created 2026-08-17) but not in the org. Sequence Property_Package__c first,
  then the sets. DO NOT strip the Property_Package__c blocks out to make them deploy: a PermissionSet
  deploy REPLACES its entire grant list, so a stripped file silently revokes the other session's
  grants. This repo was bitten by that exact hazard twice (2026-08-05 and 2026-08-06).
  ⚠ Do NOT add anything to DPEG_Admin_Access. A bare admin seeing an empty card is the EXPECTED result
  of the sibling-fields rule, not a bug.

── TASK 3: <description> amendments only. No other field property changes. ──────
  a) Property__c.Market_Rent_PSF__c - state that it is the COSTAR market rent, and note that it
     deliberately lacks the CoStar_ prefix its siblings carry (the name is ARCHITECTURE §1 rule 5
     compliant - a per-unit rate suffixes the unit - and a rename would be delete-and-recreate against
     a field referenced by MarketDataSnapshotService, three permission sets and probably reports).
  b) Property__c.CoStar_Exit_Cap_Rate__c and Property__c.Market_Cap_Rate__c - each must say how it
     differs from the other. Both now render on the same card, so a reader must be able to tell the
     exit-cap assumption from the prevailing market rate without leaving the page.
  c) Opportunity.Placer_Last_Synced_DateTime__c, Opportunity.CoStar_Last_Synced_DateTime__c and
     Opportunity.Monthly_Visits__c - prefix each description with
     "DEPRECATED 2026-08-17 - no reader." and name the replacement (the Property__c field of the
     same name). 🔴 DO NOT DELETE THESE FIELDS in this change. Deletion is a separate reviewable
     change needing a reports/dashboards/list-views/layouts/Flows grep and an org data check first
     (reports do NOT block field deletion in this org and break silently), and a concurrent session
     created them today and may still be using them.
  If any description exceeds 255 chars, use an XML comment INSIDE the root element - never above it,
  which breaks `sf` at source conversion.

── TASK 4: do NOT touch ─────────────────────────────────────────────────────────
  Any FlexiPage (Opportunity_Record_Page ALREADY contains both marketDataSync instances with the right
  source values - there is no page edit in this change, and that is a deliberate risk reduction);
  any permission set's grant list; Opportunity-Opportunity Layout; DPEG_Admin_Access; any
  customPermissions/ file; MarketDataSnapshotService or its flow. Create no fields, validation rules,
  flows, permission sets or custom permissions - none was requested.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md §5 (LWC/UI - especially the guard-util table and the "Parameterised record-page
cards" subsection) and the ENTIRE class header of
force-app/main/default/lwc/marketDataSync/marketDataSync.js before starting. That header carries
argued decisions that must survive this edit. Write NO Apex classes. API version 67.0.

WHAT CHANGES: c/marketDataSync currently renders OPPORTUNITY fields. It must render the deal's
PROPERTY fields instead - the FSD §18.2 Placer and CoStar blocks, which already exist on Property__c.
Create no fields.

── 1. RENDER THE PARENT RECORD (the substantive change) ─────────────────────────
lightning-record-form CANNOT render Property__r.* - `fields` resolve against object-api-name and LDS
does not accept a spanning path there. So:
  - @wire getRecord on the Opportunity for ONE field: Opportunity.Property__c (the Id).
  - Bind <lightning-record-form record-id={propertyId} object-api-name="Property__c" ...>.
🔴 The REJECTED alternative and why: reading Opportunity.Property__r.X spanning fields and rendering
them with lightning-formatted-* makes the card READ-ONLY. The bundle's own template comment (lines
85-91) records that lightning-output-field was rejected for exactly that reason - "a functional
regression, not a styling choice". Do not reintroduce it on 17 fields.
⚠ Sharing is NOT a blocker: Property__c OWD is Private, but all three relevant permission sets carry
viewAllRecords=true on it (measured 2026-08-17).
⚠ record-id is now the PROPERTY's, not this.recordId. Re-read every place the bundle assumes they are
the same - the Sync write and the getObjectInfo check both move to Property__c.

── 2. THE FIELD SETS in CONFIG_BY_SOURCE (all @salesforce/schema/Property__c.* imports) ──
  Placer form fields (8), in order: Placer_URL__c, Placer_State_Rank__c, Placer_State_Percentile__c,
    Placer_MSA_Rank__c, Placer_National_Rank__c, Monthly_Visits__c, Placer_Data_Source__c,
    Placer_Fetch_Status__c
  Placer stamp field: Placer_Last_Synced_DateTime__c
  CoStar form fields (9), in order: CoStar_URL__c, CoStar_Pct_Leased__c, CoStar_Location_Score__c,
    CoStar_Asking_Rent_PSF__c, Market_Rent_PSF__c, CoStar_Exit_Cap_Rate__c, Market_Cap_Rate__c,
    CoStar_Data_Source__c, CoStar_Fetch_Status__c
  CoStar stamp field: CoStar_Last_Synced_DateTime__c
⚠ Market_Rent_PSF__c genuinely has no CoStar_ prefix. It is the FSD's CoStar "Market Rent (PSF)".
  Not a typo - do not "correct" it and do not omit it.
⚠ Monthly_Visits__c and Market_Cap_Rate__c are INCUMBENTS - the deployed cards render them today, so
  dropping them would be a silent regression inside a change that adds data.
🔴 The stamp field stays OUT of the form. It is rendered by the existing bespoke Last Synced row,
  which carries the "(manual)" suffix, the helptext and the three-state Never / Not available / em-dash
  rendering. A record-form field would render a bare timestamp and silently delete all three.

── 3. THE SYNC BUTTON NOW STAMPS THE PROPERTY ───────────────────────────────────
  updateRecord({ fields: { Id: <propertyId>, [stampField]: iso } }).
  The freshness marker must live with the data. ARCHITECTURE §5 already declares the Property__c
  timestamps "the authoritative freshness markers for the market layer" and warns the Opportunity
  twins are a different thing - a card showing Property values under an Opportunity timestamp would
  make itself the source of that confusion, and two deals on one property would show one dataset under
  two different "last synced" values.
  The FLS gate moves with it: read getObjectInfo for Property__c and check the PROPERTY stamp field's
  `updateable`. Keep the three-state fail-closed logic exactly as it is.
  🔴 STILL NO getRecordNotifyChange. The write is still LDS updateRecord, which goes THROUGH the LDS
  cache. This is the c/leadStatusChange rule and the OPPOSITE of c/dealActionGuard's. Test J6 asserts
  zero invocations and is mutation-proved - re-prove it after your edit.
  🔴 Keep the messageFor LDS error reducer (output.errors -> output.fieldErrors -> body.message ->
  fallback). Do NOT swap in c/dealActionGuard's body.message-only read.

── 4. A DEAL WITH NO PROPERTY - a new, required state ───────────────────────────
  Only LeadConvertService links a Property, so a manually-created deal has none.
  - Render an inline note: "No property is linked to this deal, so there is no market data to show."
  - role="status", NOT role="alert". role="alert" is reserved for configError - an ADMIN
    MISCONFIGURATION. A missing Property is an ordinary state a user can fix. Same discipline as
    Never vs Not available.
  - Do NOT mount lightning-record-form with a null record-id.
  - Render the Sync button, DISABLED, with the reason beside it. Never hide it - hiding a control from
    an authorized user is the defect that retired the User.*_Driver__c model.
  - 🔴 Assert nothing before the Opportunity wire has answered. Add a loaded flag, mirroring the
    existing _recordLoaded. "No property" said before you know is the same confident-wrong-answer
    defect LOADING_LABEL exists to prevent.

── 5. WHAT MUST NOT CHANGE ──────────────────────────────────────────────────────
  ONE bundle keyed by `source` + CONFIG_BY_SOURCE (ARCHITECTURE §5; transactionAdvanceStage was built
  and deleted the same day for being a copy differing only in its header).
  🔴 Sync still contacts NOTHING. Keep all three mitigations, and note the risk is now HIGHER because
  the card looks far more like a real integration: "Last Synced (manual)" (never bare), the helptext
  saying no connection exists and the values are hand-entered, and NO SPINNER / NO BUSY STATE / NO
  isBusy property / NO artificial delay.
  Keep: the collapsible SLDS Expandable Section header, sentence-case title, utility:switch chevron,
  no source icon, variant="neutral" button, the runtime `source` validation with a visible role="alert",
  targetConfigs restricted to Opportunity (now a STRONGER claim - the component hard-codes the
  Opportunity.Property__c traversal), SLDS 2 design tokens only, no .lv-* list-view chrome.
  Update the .js-meta.xml <description>: it currently says "Opportunity card"; it now renders the
  linked Property's market data.
  Update the class header to record: the parent-record rendering and why shape (a) was rejected; that
  the stamp target moved to Property__c and why; and 🔴 THE STATED COST - editing here mutates a SHARED
  Property record, so a change on deal A is visible on deal B. Extend the per-source helpText to name
  the source record.

── 6. JEST - lwc/marketDataSync/__tests__/marketDataSync.test.js ────────────────
  Repoint J1-J12; mock getObjectInfo for Property__c (a suite still mocking Opportunity would pass
  while the component read the wrong object). Then add:
  J4' 🔴 Sync calls updateRecord with the PROPERTY Id, not the Opportunity Id. Highest-value new test.
  J13 Null Property__c -> role="status" note, NO lightning-record-form mounted, button disabled.
  J14 Opportunity wire in flight -> neither the form nor the no-property note renders.
  J15 Opportunity wire errors -> "Not available"; does NOT claim "no property linked".
  J16 Property Id changes -> the form's record-id follows it.
  J17 🔴 No lightning-spinner in ANY state and no isBusy/isSyncing property on the class.
  J6  unchanged - getRecordNotifyChange NEVER called. Do not delete it.
  J12' sa11y in both configs, the error state AND the no-property state (v8 needs explicit setup()).
  Mock lightning/uiRecordApi and lightning/uiObjectInfoApi at MODULE level, not by instance-spy.
  ⚠ .claude/rules/bulk-test-rule.md's 251-record mandate does NOT apply - it governs triggers, batch
  jobs, DML-performing services and queueables. Note that in the test header.

── 7. SEED SCRIPT - scripts/seed-market-data.apex (NEW) ─────────────────────────
  Follow the existing scripts/seed-*.apex precedents. Populates the FSD market block on ALL
  Property__c records.
  🔴 IT WRITES TO REAL, LIVE RECORDS. There is no rollback. Therefore:
    - FILL-IF-BLANK, PER FIELD. Never overwrite a non-null value - a human may have typed a real
      figure, and a seed that clobbers it destroys real data and leaves a plausible fake.
    - A PREVIEW MODE FIRST (a boolean at the top, default preview). Print each Property Name and the
      values it WOULD write, write nothing, and stop. The user approves before the real run.
    - Bulk-safe: one query, one Database.update(..., false). Print rows written, rows skipped, and any
      failures by name.
  VALUES - realistic, type-consistent AND INTERNALLY CONSISTENT (a property ranked 4th in its state
  with a 12th-percentile score is visibly fake and will be reported as a bug):
    Placer_State_Rank__c        Number(6,0)   1-500
    Placer_State_Percentile__c  Percent(5,2)  50.00-99.90, DERIVED from the rank (low rank = high pct)
    Placer_MSA_Rank__c          Number(6,0)   1-200, generally <= state rank (smaller pool)
    Placer_National_Rank__c     Number(6,0)   500-20000, > state rank
    Monthly_Visits__c           Number(18,0)  40,000-900,000, scaled with Square_Footage__c if present
    CoStar_Pct_Leased__c        Percent(5,2)  75.00-100.00
    CoStar_Location_Score__c    Number(4,1)   1.0-10.0, ONE decimal (the field's scale is 1)
    CoStar_Asking_Rent_PSF__c   Currency      18.00-65.00
    Market_Rent_PSF__c          Currency      within +/-15% of asking rent
    CoStar_Exit_Cap_Rate__c     Percent(5,2)  5.00-8.50, >= Market_Cap_Rate__c where populated
    Placer_URL__c / CoStar_URL__c             clearly-SAMPLE URLs
    Placer_Data_Source__c / CoStar_Data_Source__c   = 'Manual'
    Placer_Fetch_Status__c / CoStar_Fetch_Status__c = 'Not Synced'
  🔴 SEED 'Not Synced', NEVER 'Success'. The picklists have THREE values (Not Synced / Success /
  Error) - an older design doc says two and is wrong. 'Success' asserts a fetch happened; nothing has
  ever fetched anything.
  🔴 LEAVE BOTH *_Last_Synced_DateTime__c NULL. The card renders "Never", which is true. Seeding a
  timestamp manufactures precisely the lie the (manual) label, the helptext and the no-spinner rule
  exist to prevent.
  🔴 Do NOT write Market_Cap_Rate__c - it is pre-existing, has other consumers, and is not part of the
  FSD provider block.
  ⚠ You cannot execute this script yourself and neither can the main agent (`sf apex run` is
  classifier-blocked). Hand it to the devops agent or the user, preview run first.

── 8. ARCHITECTURE.md §6 ────────────────────────────────────────────────────────
Propose two §5 amendments in the same PR:
  (a) the "Parameterised record-page cards" subsection must record that c/marketDataSync now renders
      and writes to a PARENT record resolved through Opportunity.Property__c - a new shape for the
      pattern, and the first card in this repo whose record-id is not its page's recordId;
  (b) the existing note that Opportunity.*_Last_Synced_DateTime__c "must not be read as the live sync
      markers" must be updated to say those fields are now DEPRECATED WITH NO READER.
```

---

## ❓ THE ONE THING WORTH CONFIRMING BEFORE BUILD

Everything above is decided. One consequence deserves an explicit yes/no because it is behavioural,
not cosmetic, and it is not obvious from the request:

> **Editing a market field on Deal A's page changes the number Deal B sees.** The fields live on the
> shared `Property__c`, which is what the FSD and `MarketDataSnapshotService` both require — but a user
> editing on an Opportunity page will not necessarily expect it. UAT case **U6** exists to confirm it
> is acceptable. If it is not, the fallback is read-only rendering on the Opportunity page with editing
> forced onto the Property record — which costs the inline edit and reverses D2.
