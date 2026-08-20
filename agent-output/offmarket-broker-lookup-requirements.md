# Off-Market Broker Lookup — Design Requirements

**Branch:** `feature/disposition-redesign`
**Date:** 2026-08-20
**Status:** Design decisions user-confirmed. This document converts them into admin/development work.
**API version:** 67.0 (`sfdx-project.json` → `sourceApiVersion`)

---

## §0. PREMISES CHECKED AGAINST LIVE METADATA — READ FIRST

Every line-level claim in the incoming brief was verified. Confirmed items are listed so downstream
agents do not re-verify them. **Three findings contradict or materially extend the brief.**

### 0.1 Confirmed exactly as briefed

| Claim | Verified at |
|---|---|
| No `Broker__c` OBJECT exists; `Broker__c` is a field name | `objects/` has no `Broker__c` directory |
| `Broker_Assignment__c.Broker__c` is a Contact lookup with an ACTIVE filter | `objects/Broker_Assignment__c/fields/Broker__c.field-meta.xml` lines 3-24 |
| `Lease_Inquiry__c.Broker__c` is a Contact lookup, same filter shape | `objects/Lease_Inquiry__c/fields/Broker__c.field-meta.xml:17-19` |
| `Disposition__c.Selected_Broker__c` is Text(255) | `objects/Disposition__c/fields/Selected_Broker__c.field-meta.xml:6,10` |
| On-market writer #1 | `BovSubmissionTriggerHandler.cls:150` (map build), `:163` (the stamp) |
| On-market writer #2 | `BovSubmissionService.cls:180` (`Selected_Broker__c = challenger.Broker_Firm__c`) |
| Off-market gate is a blank-check only | `DispositionApprovalService.cls:245` (`String.isBlank(...)`) |
| Reader — BOV outreach DTO | `BovController.cls:109` (`s.selectedBroker = d.Selected_Broker__c`) |
| Reader — approval page | `Disposition__c.Broker_Selection_Approval.approvalProcess-meta.xml:83` |
| Reader — off-market Path key field | `Disposition_Path_Off_Market.pathAssistant-meta.xml:76` |
| Reader — on-market Path key field (×2) | `Disposition_Path_On_Market.pathAssistant-meta.xml:98`, `:114` |
| Reader — Active Listing child copy | `DispositionStageEntryService.cls:870` → `Broker_Listing__c.Broker_Firm__c` |
| Cross-object formula on the child | `objects/BOV_Submission__c/fields/Selected_Broker__c.field-meta.xml:5` |
| Dynamic Forms field position | `Disposition_Record_Page.flexipage-meta.xml:523`, identifier `FieldSelectedBroker` |
| Seed script mass-deletes broker Contacts | `scripts/seed-broker-contacts.apex:4` |
| Approval file carries a recall-pending-instances warning | `Broker_Selection_Approval...xml:67-69` |
| `Disposition__c.Broker__c` API name is FREE in source | 25 field files under `Disposition__c/fields/`; no `Broker__c` |

### 0.2 🔴 CONTRADICTION 1 — the `.forceignore` citation is wrong

The brief states "`objects/Account/**` is force-ignored at `.forceignore:223`". **It is not.**

- Line 223 sits **inside a comment block** (lines 222-248) explaining that the blanket `Account/**`
  ignore was deliberately **NARROWED on 2026-08-10** after it silently dropped the entire Account
  tree — including the `Broker_Firm` and `Investor_Entity` record types — from every deploy with
  zero error or warning.
- The only live rule is **`.forceignore:249` → `force-app/main/default/objects/Account/fields/**`**.
  The comment also records that gitignore-style `!` negation was tried and **does not work** under a
  `dir/**` ignore.

**Consequence for this design (the scope decision does not change, its justification does):** a
lookup *to* Account would deploy without difficulty — the field file lives under
`Disposition__c/fields/`, which is not ignored. What is actually blocked is adding any new custom
field *on* Account. An Account/firm lookup stays out of scope on **product** grounds (the confirmed
target is Contact), not on force-ignore grounds. Do not repeat the incorrect justification.

### 0.3 🔴 CONTRADICTION 2 — the brief's FLS section covers only the WRITE. The larger exposure is a READ.

The brief did not name `DispositionSelector.selectApprovalContextById`
(`DispositionSelector.cls:467-476`). It is **`WITH USER_MODE`**, and it is the query that feeds the
gate being changed at `DispositionApprovalService.cls:245`:

```apex
SELECT Id, Disposition_Stage__c, RecordTypeId,
       Selected_Broker__c, Wire_Verification_Completed__c
FROM Disposition__c
WHERE Id = :dispositionId
WITH USER_MODE
LIMIT 1
```

Flipping the gate to the lookup **requires adding `Broker__c` to this SELECT**. That makes this an
FLS change first and a display change second: `WITH USER_MODE` **throws, it does not degrade**. One
unreadable field raises `System.QueryException: No such column 'Broker__c' on entity
'Disposition__c'` — an FLS denial wearing a schema error — and this method is a **fetch-for-use
single-row assignment**, so the throw is not softened. `DispositionApprovalService.submitForApproval`
is the entry point for **all four** approval branches, so a missing grant breaks **Submit for
Approval on every disposition at every stage on both record types**, not just the off-market broker
step.

🔴 **Whoever hits that `QueryException` will reach for `WITH SYSTEM_MODE`. That is the wrong turn and
is banned here by the method's own header** (`DispositionSelector.cls:444-456`), which argues
USER_MODE is *"the right answer rather than the default"* for this read because it is synchronous,
human-initiated, and every value it returns is used to author a message shown to that same human.
**The fix is the permission set, every time.** See §2.2.

### 0.4 EXTENSION — the measured FLS matrix (narrower than feared; the brief's two sets are correct and complete)

Exactly **four** permission sets grant any `Disposition__c.*` field:

| Permission set | `Disposition__c` grants | Grants `Selected_Broker__c`? | Must grant `Broker__c`? |
|---|---|---|---|
| `DPEG_Disposition_Edit` | 29 | ✅ editable (line 1360) | ✅ **editable + readable** |
| `DPEG_Disposition_View` | 27 | ✅ readable (line 682) | ✅ **readable only** |
| `DPEG_Admin_Access` | 7 | ❌ **no** | ❌ no — see below |
| `Disposition_Dashboard_Access` | 3 | ❌ no (only `BOV_Submission__c.Selected_Broker__c`, line 16) | ❌ no |

`DPEG_Admin_Access` is the recurring casualty on changes of this shape, but **not here**: it grants
only `NDA_Count__c`, `Primary_NDA__c`, `Signed_NDA_Count__c` and `Wire_Verification_Completed__c`
(lines 150-165). A bare administrator holding no disposition persona set **already** cannot run
`selectApprovalContextById` today. Adding `Broker__c` creates **no new** admin regression, and
`DPEG_Admin_Access` must **not** be widened as part of this wave.

**Contact-side FLS needs no change.** `DPEG_Contact_Edit` (lines 21, 66) and `DPEG_Contact_View`
(lines 21, 66) already grant `Contact.Broker_Firm__c` and `Contact.Is_Broker__c`, and the persona
groups line up:

- `DPEG_Junior_Analyst_PSG` = `DPEG_Contact_Edit` + `DPEG_Disposition_Edit` → **the analyst who picks.**
- `DPEG_Principal_PSG` = `DPEG_Contact_View` + `DPEG_Disposition_View` → **the approver who reviews.**

### 0.5 EXTENSION — two of the five "existing readers" are structurally unreachable off-market

This sharpens what the retained Text field actually has to carry, and it is the fact that makes
"retain the text" a small honest carry rather than a large one.

| Reader | Reachable on an OFF-MARKET row? | Evidence |
|---|---|---|
| Off-market Path key field (`:76`) | ✅ **yes** | the step *is* `Broker Selection` |
| `Broker_Selection_Approval` approvalPageFields (`:83`) | ✅ **yes** | off-market-only process (`Is_On_Market__c = False`, line 112-115) |
| `DispositionApprovalService:245` gate | ✅ **yes** | the branch being changed |
| `reports/Dispositions/Listed_With_Broker` | ❌ **no** | filters `Disposition_Stage__c = 'Active Listing'` (report lines 6-14); `Active Listing` is **restricted out of the Off_Market value set** (`Disposition_Path_Off_Market...xml:14-18`) |
| `DispositionStageEntryService:870` → `Broker_Listing__c` | ❌ **no** | fires on entry to `Active Listing` only (`:852`, `LISTING_STAGE`) — same reason |
| `BovController:109` → `bovOutreach` LWC | ❌ **no** | BOV outreach is the on-market beauty parade; `bovOutreach` is not placed on `Disposition_Record_Page` at all |

**Net:** the denormalised Text stamp is genuinely required for exactly **three** off-market surfaces.
It is retained anyway, because the on-market chain writes and reads it and must not be touched.

### 0.6 EXTENSION — `TestDataFactory` already anticipated this exact field

`TestDataFactory.cls:572-594` provides `createBrokerContacts(count, accountId, doInsert)` and
`createBrokerContact(accountId, doInsert)`, documented verbatim as:

> *"Contacts flagged `Is_Broker__c = true`. **REQUIRED for any `Broker__c` lookup:** … active,
> non-optional lookup filter on `Contact.Is_Broker__c`."*

`createContacts` also stamps the `Contact.Broker` record type (`:556`). Tests **must** use these
helpers; a plain `createContacts()` will be refused by the lookup filter (`TestDataFactory.cls:120-121`).

---

## §1. SCOPE AND CONFIRMED DECISIONS

### 1.1 What is being built

An off-market analyst currently types a broker's name as free text into
`Disposition__c.Selected_Broker__c`, and the Broker Selection approval gate accepts any non-blank
string. This wave replaces that pick with a **validated Contact lookup**, so the broker on an
off-market disposition is a real record in the system rather than a string.

### 1.2 Confirmed decisions (do not re-litigate)

**D1 — Lookup target is `Contact`, filtered `Is_Broker__c = true`.** There is no `Broker__c` object.
All three precedents (`Broker_Assignment__c.Broker__c`, `Lease_Inquiry__c.Broker__c`,
`Opportunity.Broker__c`) are Contact lookups. Copy `Broker_Assignment__c.Broker__c`'s XML shape
exactly.

**D2 — Scope is OFF-MARKET ONLY.** The on-market BOV chain stays on free text this wave.

**D3 — Strictly additive. The Text field is NOT converted in place.** This is the structural
consequence, reasoned through in §1.3.

### 1.3 🔴 WHY THE EXISTING TEXT FIELD CANNOT BE CONVERTED — the load-bearing argument

`Disposition__c.Selected_Broker__c` is written by **both** paths:

- **On-market, automatically.** `BovSubmissionTriggerHandler.cls:163` stamps it from
  `BOV_Submission__c.Broker_Firm__c` — a **Text(255)** field — inside an after-update trigger, and
  `BovSubmissionService.cls:180` stamps the same String during a broker replacement.
- **Off-market, by hand.** A human types into it, and `DispositionApprovalService.cls:245` only
  checks `String.isBlank`.

An in-place conversion to `Lookup(Contact)` would leave both on-market writers **assigning a String
to an Id field**. That is a compile-time failure in Apex, and — worse if it somehow reached the org —
a `Broker_Firm__c` value like `'CBRE'` is not an Id, so the on-market broker appointment would fail
outright. The on-market chain is explicitly out of scope, so its writers cannot be changed to
compensate.

**Therefore: a NEW lookup field is added and the Text field survives.**

### 1.4 Approved shape (validated — I agree with the proposal, with two refinements)

| Element | Decision |
|---|---|
| New field | **`Disposition__c.Broker__c` — Lookup(Contact)** |
| Name justification | ARCHITECTURE.md:34 — a role-named lookup to `Contact` takes the role name. Matches all three precedents. `Selected_Broker__c` is taken by the Text field. ✅ **verified free** in source. |
| `Selected_Broker__c` | **Retained as the denormalised DISPLAY value.** Every existing reader keeps working unchanged. |
| Off-market stamp | When a Contact is chosen, the Text field is **stamped from it** so the two can never disagree. Format and location: §1.5, §1.6. |
| Gate | `DispositionApprovalService` off-market branch changes from *"text is non-blank"* to *"lookup is non-null"*, with an authored user-safe message. |
| Text fallback | **NOT kept.** Decided with evidence — §1.7. |

**Refinement A — relationship name.** Use `<relationshipName>Dispositions</relationshipName>` /
`<relationshipLabel>Dispositions</relationshipLabel>`. Relationship names are unique **per parent
object**; `Dispositions` is currently used on `Property_Asset__c`
(`Disposition__c/fields/Property_Asset__c.field-meta.xml:7-8`), which is a *different* parent, so it
is free on `Contact`. `Broker_Assignment__c.Broker__c` uses `Broker_Assignments`,
`Lease_Inquiry__c.Broker__c` uses `Lease_Inquiries` — both follow "plural of the child object", and
`Dispositions` continues that. (`Primary_NDA__c.field-meta.xml:15,29` documents this same uniqueness
reasoning.)

**Refinement B — record-type visibility.** The proposed Dynamic Forms placement needs a
field-level visibility rule that the brief did not call for. See §2.3.

### 1.5 🔴 DECISION — exactly what string is stamped

**Stamped value:**

```
Broker_Firm__c blank  →  Contact.Name
otherwise             →  Contact.Name + ' - ' + Contact.Broker_Firm__c
```

Separator is **ASCII hyphen-minus with single spaces** (`' - '`), not an em dash.

**Length arithmetic — proven safe.** `Contact.Name` ≤ 121 (FirstName 40 + space + LastName 80).
`Contact.Broker_Firm__c` is **Text(120)** (`Contact/fields/Broker_Firm__c.field-meta.xml:7`).
Worst case `121 + 3 + 120 = 244` ≤ **255**. No truncation logic is needed, and none should be added.

**⚠ This deliberately diverges from the on-market format, and the divergence is stated rather than
hidden.** On-market stamps the **firm only** (`BOV_Submission__c.Broker_Firm__c`, Text(255) → Text(255),
an exact fit). Off-market will stamp **person - firm**. One field will therefore carry two formats.
That is correct because the two paths approve two different things: on-market approves a *firm's BOV
response*, whereas off-market approves a *named individual* — the approval file itself says
*"on this path that field IS the decision"* (`Broker_Selection_Approval...xml:63`). Stamping the firm
alone off-market would render the approval page and the Path step as `"CBRE"` for a decision that was
about a specific person, losing the identity of the very thing being signed off.

Note the existing off-market test fixtures already use this separator —
`DispositionApprovalServiceTest.cls:191` sets `'CBRE - Direct Pick'` and
`DispositionApprovalProcessesTest.cls:180` sets `'Cushman & Wakefield - Direct Pick'`.

**Clearing:** when `Broker__c` is set to null, `Selected_Broker__c` **must be cleared in the same
save**. Leaving a stale name behind would put a broker's name on the approval page and the Path step
for a disposition that has no broker.

**Unreadable Contact:** if the lookup Id resolves to no readable Contact row, **leave
`Selected_Broker__c` unchanged** rather than blanking it. Blanking is the more destructive direction
and this codebase consistently prefers the failure that is visible and self-healing.

### 1.6 🔴 DECISION — where the stamp happens: a SERVICE called from the EXISTING before-context trigger

**Not a Flow, not a post-save trigger, not the LWC layer.**

- The pick is a **Dynamic Forms inline field edit**, so there is no button click to hook. The only
  place that catches every writer — inline edit, API, Flow, data load, seed script — is a trigger.
- **Before-context**, so the stamp costs **zero extra DML** and cannot trip the approval lock.
  🔴 This matters: `Broker_Selection_Approval` carries `recordEditability = AdminOnly`
  (`...approvalProcess-meta.xml:127`), so a *post-save* update to the same Disposition while its own
  approval is pending would throw `ENTITY_IS_LOCKED` — the exact class of failure that forced
  `DispositionApprovalAdvanceQueueable` into existence.
- `DispositionTriggerHandler` **already has** `beforeInsert` and `beforeUpdate` overrides routing to
  `DispositionStageEntryService.stampListingDates` (`DispositionTriggerHandler.cls:81-90`). This is
  the established pattern on this object; extend it.

**Why a new service class rather than inline handler logic.** The stamp needs a **Contact SOQL read**,
and `.claude/rules/apex-layering-rule.md` prohibits SOQL in a TriggerHandler and prohibits SOQL in a
Domain. A Service that calls a Selector is the only conforming home. (`BovSubmissionTriggerHandler`'s
header sets a precedent for keeping trivial logic in the handler — that precedent explicitly does
**not** apply, because it depends on the logic having *"ZERO inline SOQL"*, which this does not.)

### 1.7 🔴 DECISION — the Text fallback is NOT kept, and here is the evidence

The brief asked whether `String.isBlank(Selected_Broker__c)` should be retained as an `OR` fallback
for pre-existing rows. **No.** The gate becomes a pure `Broker__c == null` check.

**There are no pre-existing rows to protect.** The off-market path was *rebuilt from scratch on
2026-08-19* (`Disposition_Path_Off_Market...xml:5`), and the org sweep recorded in
`Broker_Selection_Approval...approvalProcess-meta.xml:67-69` found **zero pending ProcessInstances on
`Disposition__c` and zero Off_Market rows**. The fallback would protect a population that does not
exist.

Worse, keeping it would **invert the purpose of the wave**: an `OR` fallback lets a hand-typed string
naming nobody in the system satisfy the very gate that exists to stop exactly that. And because the
stamp in §1.5 writes `Selected_Broker__c` on every off-market pick, the fallback would be satisfied
by the service's own output — a gate that can never fail.

⚠ **Re-verify the zero-row count at deploy time** (§4.1 step 0). If off-market rows have since been
created with hand-typed text, escalate before deploying rather than silently reinstating the fallback.

### 1.8 Explicitly OUT OF SCOPE

- ❌ Converting the on-market BOV chain (`BovSubmissionTriggerHandler`, `BovSubmissionService`,
  `BovController`, `bovOutreach`, `bovReplaceBrokerModal`) to the lookup.
- ❌ Retiring, deleting, or deprecating `Disposition__c.Selected_Broker__c`.
- ❌ Any Account / firm lookup. (Product decision — **not** a force-ignore constraint; see §0.2.)
- ❌ Changing `Disposition_Path_On_Market` lines 98 or 114.
- ❌ Widening `DPEG_Admin_Access` or `Disposition_Dashboard_Access`.
- ❌ Any change to `BOV_Submission__c.Selected_Broker__c` (the cross-object formula).
- ❌ New validation rules. None requested; the gate is Apex.

---

## §2. ADMIN / DECLARATIVE WORK

Route: **`salesforce-admin`** (routine field + permission set + flexipage + path + approval edits;
no multi-object schema design, no security-model design).

### 2.1 New custom field

**File to CREATE:** `force-app/main/default/objects/Disposition__c/fields/Broker__c.field-meta.xml`

Copy the XML shape of `objects/Broker_Assignment__c/fields/Broker__c.field-meta.xml` **exactly**,
changing only `relationshipLabel` / `relationshipName`:

| Property | Value |
|---|---|
| `fullName` | `Broker__c` |
| `type` | `Lookup` |
| `referenceTo` | `Contact` |
| `label` | `Broker` |
| `deleteConstraint` | `SetNull` |
| `required` | `false` |
| `trackHistory` | `false` |
| `trackTrending` | `false` |
| `relationshipLabel` | `Dispositions` |
| `relationshipName` | `Dispositions` |
| `lookupFilter` → `active` | `true` |
| `lookupFilter` → `booleanFilter` | `1` |
| `lookupFilter` → `isOptional` | `false` |
| `lookupFilter` → `filterItems` | field `Contact.Is_Broker__c`, operation `equals`, value `True` |
| `lookupFilter` → `errorMessage` | `The selected Contact is not flagged as a broker (Is_Broker__c).` |

⚠ Verify in the target org that `Broker__c` is not a **soft-deleted** field name on `Disposition__c`.
A deleted API name stays reserved until it is **ERASED** from the field recycle bin; the deploy fails
with a duplicate-name error that reads like a source problem.

**File to CREATE (optional, matching the existing convention):**
`force-app/main/default/objectTranslations/Disposition__c-en_US/Broker__c.fieldTranslation-meta.xml`
— a sibling `Selected_Broker__c.fieldTranslation-meta.xml` already exists in that directory.

### 2.2 🔴 Permission sets — FLS. DEPLOY BEFORE OR WITH THE APEX.

A Metadata-API-deployed custom field arrives with **NO FLS for any profile, System Administrator
included**. Without these grants the field is invisible on the page **and** — per §0.3 — the widened
`WITH USER_MODE` selector throws for everyone, breaking Submit for Approval across the whole object.

`BovSubmissionService.cls:165-168` documents this exact class of failure biting on **2026-08-19**:

> *"It is a 2026-08-19 field: a Metadata-API-deployed custom field arrives with NO FLS for any
> profile, System Administrator included … A USER_MODE write would be refused for everyone."*

That class also records (`:173-181`) that its `Disposition__c` write uses a **plain `update`,
deliberately NOT `SYSTEM_MODE`**, so that it obeys the same rules as every other Disposition write in
the module. The stamp service in §3.2 follows the same choice — which means it too fails for every
user until FLS lands.

**Files to EDIT:**

| File | Change |
|---|---|
| `force-app/main/default/permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml` | ADD one `<fieldPermissions>`: `Disposition__c.Broker__c`, `editable=true`, `readable=true` |
| `force-app/main/default/permissionsets/DPEG_Disposition_View.permissionset-meta.xml` | ADD one `<fieldPermissions>`: `Disposition__c.Broker__c`, `editable=false`, `readable=true` |

🔴 **A `PermissionSet` deploy REPLACES the file's entire `fieldPermissions` set.** These edits must be
**strictly additive and diffed against `HEAD`** before deploying. Do not regenerate either file, do
not reorder it, and do not let a retrieve overwrite it. `DPEG_Disposition_Edit` currently holds 29
`Disposition__c` field grants and `DPEG_Disposition_View` holds 27; those counts must become 30 and 28
respectively, with nothing else changed.

⚠ Both files are **shared hub files**. Diff them against `HEAD` immediately before deploy — a
concurrent session working in this same tree has previously turned a hub permission set into a union
of two features and failed the deploy on the other feature's undeployed field.

**No other permission set changes.** Do **not** add `Broker__c` to `DPEG_Admin_Access` (§0.4) or to
`Disposition_Dashboard_Access`. **No Contact grants are needed** — already provisioned (§0.4).

### 2.3 Dynamic Forms — where the analyst picks the broker

**File to EDIT:** `force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml`

Add a new `<itemInstances><fieldInstance>` for `Record.Broker__c`, identifier `FieldBroker`,
`uiBehavior` = `none`, placed **immediately before** the existing `FieldSelectedBroker` instance at
line 523 (i.e. inside the same facet, `Facet-0a494558-fee1-4b32-a27e-d8a2546e161e`, which is the
right-hand column of the `Details` field section).

🔴 **AND IT NEEDS A FIELD-LEVEL VISIBILITY RULE THE BRIEF DID NOT CALL FOR.** The enclosing `Details`
field section already carries a `visibilityRule` (lines 633-655) that hides it at `BOV Outreach`,
`Active Listing`, `Closing` and `Sale Closes` — which means it **is** visible at `Broker Selection`,
**for both record types**. Dropping the lookup in unguarded would expose an empty, editable `Broker`
field on **on-market** dispositions sitting at `Broker Selection`, directly contradicting decision D2.

Add to the new `fieldInstance`:

```xml
<visibilityRule>
    <criteria>
        <leftValue>{!Record.Is_On_Market__c}</leftValue>
        <operator>EQUAL</operator>
        <rightValue>false</rightValue>
    </criteria>
</visibilityRule>
```

- `Is_On_Market__c` is a formula checkbox and is **already granted read** in both disposition sets
  (`DPEG_Disposition_Edit:1405`, `DPEG_Disposition_View:727`). Both set headers state it is
  *"LOAD-BEARING FOR THE UI, NOT DECORATIVE"* — four Dynamic Actions on this same page already test
  it — so the rule is safe.
- ⚠ **A visibility rule on an unreadable field evaluates FALSE and hides the element.** That is the
  safe direction here (the off-market-only field disappears), but it is another reason §2.2 must land
  first.
- ⚠ This is the **first `fieldInstance`-level `visibilityRule` in this file** — the existing rules are
  on `actionNames` (lines 223-398), on the `dispositionMain` component (592), and on the field section
  (633). Confirm the shape against `salesforce-api-context` for `FlexiPage` before writing.
- Do **not** move, remove, or alter `FieldSelectedBroker`. It stays visible as the read-back of what
  was stamped.

⚠ **Do not enable Dynamic Actions on this page while editing it in App Builder** — doing so silently
empties the page's inherited action bar, and no automated check detects it. Edit the XML directly.

### 2.4 Path assistant — off-market ONLY

**File to EDIT:** `force-app/main/default/pathAssistants/Disposition_Path_Off_Market.pathAssistant-meta.xml`

In the `Broker Selection` step (lines 75-79):

- **Line 76:** change `<fieldNames>Selected_Broker__c</fieldNames>` → `<fieldNames>Broker__c</fieldNames>`.
- **Line 77:** rewrite the `<info>` text. It currently reads *"name the broker directly in Selected
  Broker"*, which becomes a wrong instruction. Replace with wording that names the **Broker** field —
  suggested: *"No BOV round runs on this path: choose the broker in the Broker field, then use Submit
  Broker Selection. Approval moves this deal to NDA on its own - there is no Advance button on this
  step."*

**Show the lookup ONLY — do not list both fields on the step.** A path step accepts multiple
`<fieldNames>`, but `Selected_Broker__c` is now *derived*, and displaying a derived echo next to its
own source invites a hand edit that would immediately disagree with the lookup. This is the same
argument both `DPEG_Disposition_*` headers make for withholding a derived field: it *"would sit as a
dead interlock on a user's screen and invite a hand edit."*

🔴 **`Disposition_Path_On_Market.pathAssistant-meta.xml` lines 98 and 114 MUST NOT CHANGE.**

### 2.5 Approval process — add the lookup, keep the text

**File to EDIT:** `force-app/main/default/approvalProcesses/Disposition__c.Broker_Selection_Approval.approvalProcess-meta.xml`

In `<approvalPageFields>` (lines 79-85), **ADD** `<field>Broker__c</field>` immediately **before** the
existing `<field>Selected_Broker__c</field>` at line 83.

**Both are kept, deliberately.** `Broker__c` renders the Contact as a clickable name — the actual
decision record the principal is approving. `Selected_Broker__c` carries the person-and-firm string
(§1.5) inline, so the approver sees the firm without navigating away. The file's own comment
(line 63) says *"approvalPageFields now leads with `Selected_Broker__c` - on this path that field IS
the decision"*; after this change the lookup leads, and that comment should be updated in place to
say so.

Also update the in-root comment block to record this change and its date, following the file's
existing "quoted and retracted rather than deleted" convention.

⚠ **RECALL ANY PENDING ProcessInstances BEFORE DEPLOYING** — the file carries this standing warning at
lines 67-69. The 2026-08-19 sweep found zero, but that sweep is now over a day old. **Re-run it at
deploy time** (§4.1 step 0). Note also the deploy-order constraint already recorded at lines 71-72
(`workflows/Disposition__c.workflow-meta.xml` and `Is_On_Market__c` must already exist — they do).

⚠ Keep `<description>` under 255 characters, per the file's own note (lines 8-12). The XML comment
must stay **inside** the root element — a comment above `<ApprovalProcess>` breaks `sf` at source
conversion with a misleading "unable to find matching parent xml file" error.

### 2.6 Seed script — mitigate the SetNull hazard

**File to EDIT:** `scripts/seed-broker-contacts.apex`

`scripts/seed-broker-contacts.apex:4` opens with:

```apex
delete [SELECT Id FROM Contact WHERE Is_Broker__c = true];
```

With `deleteConstraint=SetNull`, re-running this seed **silently nulls `Broker__c` on every
Disposition holding it** — no error, no warning, and the denormalised `Selected_Broker__c` text is
left behind still naming the vanished broker, so the two fields disagree and the record *looks*
fine. Mitigation in §5 R1.

**Minimum required change:** add a loud header comment at the top of the file naming
`Disposition__c.Broker__c` (and the three existing `Broker__c` lookups, which have the same exposure)
as collateral of line 4, and add a guard that **refuses to run** when any Disposition references a
broker Contact — for example, abort with a clear message if
`[SELECT COUNT() FROM Disposition__c WHERE Broker__c != null] > 0` unless an explicit
`FORCE = true` flag is set in the script.

---

## §3. DEVELOPMENT WORK

Route: **`salesforce-developer`** (standard selector + service + trigger-handler + gate change; no
integration, no LDV, no callouts).

All classes: `with sharing`, API 67.0, `.claude/rules/apex-layering-rule.md` enforced.

### 3.1 `ContactSelector` — new automation read

**File to EDIT:** `force-app/main/default/classes/ContactSelector.cls`

```apex
public static List<Contact> selectBrokerLabelsByIds(Set<Id> contactIds)
```

- Returns `Id, Name, Broker_Firm__c` for the given Contacts. Returns an empty list for a null/empty
  input (matches the existing `selectStagesByIds` / `selectStageAndTypeByIds` contract in
  `DispositionSelector`).
- 🔴 **`WITH SYSTEM_MODE`**, justified **at the method's own declaration** per ARCHITECTURE.md §2
  (*"the authoritative inventory … is the selector class headers"*). This is a textbook automation
  read: it happens **inside a before-trigger on `Disposition__c`**, on behalf of whoever saved the
  record, and nothing it returns is displayed — the caller derives a stamp from it. `USER_MODE` here
  **throws rather than degrades**: a principal without FLS on `Contact.Broker_Firm__c` would raise
  `QueryException`, which escapes the trigger as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolls
  back the user's own Disposition save** — a read added to make a feature safer must not be able to
  destroy the transaction it was added to.
- ⚠ **Sharing is a SEPARATE question and is deliberately left alone.** `SYSTEM_MODE` lifts CRUD and
  FLS, never sharing; `ContactSelector` stays `with sharing`, and the existing
  `GuestReads` inner class is **not** the pattern to copy here. A Contact the running user cannot see
  is simply absent from the result, and per §1.5 the service then leaves `Selected_Broker__c`
  unchanged — the correct failure direction. **Do not** add a `without sharing` inner class for this.
- Update the class header's per-method MODE inventory and Consumers list (lines 6-47), which is
  maintained per method in this file.

### 3.2 `DispositionBrokerStampService` — NEW class

**File to CREATE:** `force-app/main/default/classes/DispositionBrokerStampService.cls` (+ `-meta.xml`)
*(29 characters — under the 40-character class-name cap.)*

```apex
public with sharing class DispositionBrokerStampService {
    public static void stampSelectedBrokerLabel(
        List<Disposition__c> dispositions,
        Map<Id, Disposition__c> priorById   // null on insert
    );
}
```

**Contract:**

1. **Before-context only.** Mutates `dispositions` in place. Performs **zero DML**. Returns `void`.
2. **Detects a change in `Broker__c`**: on insert, any non-null `Broker__c`; on update, `Broker__c`
   differing from `priorById.get(id).Broker__c`. Records whose `Broker__c` did not change are skipped
   entirely — this is what stops the stamp from fighting the on-market writers, which never touch
   `Broker__c`.
3. **Cleared to null** → set `Selected_Broker__c = null` on that record (§1.5).
4. **Set to a Contact** → one bulk call to `ContactSelector.selectBrokerLabelsByIds` for the whole
   collection, then compose per §1.5:
   `Name` when `Broker_Firm__c` is blank, else `Name + ' - ' + Broker_Firm__c`.
5. **Contact not returned** (unreadable / deleted) → leave `Selected_Broker__c` **unchanged** (§1.5).
6. **Bulk-safe:** exactly **one** SOQL for the whole collection, **zero** DML, no SOQL or DML in any
   loop. A chunk in which no record changed `Broker__c` costs **zero** queries.
7. Class header must state the layer, the SOQL/DML budget, the bulk posture, and — explicitly — that
   the 251-record mandate **applies** (§3.5).

⚠ **No record-type guard inside the service.** The stamp is keyed on `Broker__c` changing, and
`Broker__c` is only exposed on off-market rows (§2.3), so the scoping is structural. Adding a
`Is_On_Market__c` test here would be a second, drifting copy of the same rule.

### 3.3 `DispositionTriggerHandler` — wire it up

**File to EDIT:** `force-app/main/default/classes/DispositionTriggerHandler.cls`

```apex
protected override void beforeInsert() {
    DispositionStageEntryService.stampListingDates((List<Disposition__c>) newList, null);
    DispositionBrokerStampService.stampSelectedBrokerLabel((List<Disposition__c>) newList, null);
}

protected override void beforeUpdate() {
    DispositionStageEntryService.stampListingDates(
        (List<Disposition__c>) newList, (Map<Id, Disposition__c>) oldMap);
    DispositionBrokerStampService.stampSelectedBrokerLabel(
        (List<Disposition__c>) newList, (Map<Id, Disposition__c>) oldMap);
}
```

Two added lines. **No logic and no SOQL in the handler** — layering rule enforced. Update the class
header's routing summary.

### 3.4 `DispositionSelector` — widen the approval-context read

**File to EDIT:** `force-app/main/default/classes/DispositionSelector.cls`

In `selectApprovalContextById` (lines 467-476), add `Broker__c` to the SELECT:

```apex
SELECT Id, Disposition_Stage__c, RecordTypeId,
       Selected_Broker__c, Broker__c, Wire_Verification_Completed__c
FROM Disposition__c
WHERE Id = :dispositionId
WITH USER_MODE
LIMIT 1
```

- **Keep `WITH USER_MODE`.** The method's own header (lines 444-456) argues at length that USER_MODE
  is *"the right answer rather than the default"* here. 🔴 **Do not flip this to `SYSTEM_MODE`** when
  the `QueryException` appears — the fix is §2.2.
- **Keep `Selected_Broker__c` in the SELECT.** It is no longer read by the gate, but removing it is
  out of scope and the field is still displayed downstream.
- Update the method's four-field inventory ApexDoc (lines 429-442), which enumerates *"exactly the
  four inputs to that decision and nothing else"* — it becomes five, and the entry for
  `Selected_Broker__c` must be re-labelled from "the Off-market `Broker Selection` pre-check" to a
  display-only carry, with `Broker__c` taking over the pre-check role. That block explicitly warns
  that *"deleting either field from this SELECT does not break the submit; it silently restores the
  opaque error"* — the same warning now attaches to `Broker__c`.

### 3.5 `DispositionApprovalService` — flip the gate

**File to EDIT:** `force-app/main/default/classes/DispositionApprovalService.cls`

**Line 245:**

```apex
// was:  if (String.isBlank(disposition.Selected_Broker__c)) {
if (disposition.Broker__c == null) {
    throw new ApprovalException(NO_SELECTED_BROKER_MESSAGE);
}
```

**Lines 132-134 — re-author the message.** Current text says *"Set the Selected Broker"*, which now
names the wrong field:

```apex
private static final String NO_SELECTED_BROKER_MESSAGE =
    'No broker has been selected on this disposition yet. Choose a broker in the Broker '
    + 'field, then submit for approval.';
```

Authored, user-safe, names the on-screen label rather than an API name — matching this class's
stated convention (*"Authored, user-safe messages. No platform text, no field API names."*, line 124).

**Update the class header at line 31**, which documents the pre-check table:

```
*   `Broker Selection` (off-market)  `Selected_Broker__c` must be non-blank
```

becomes `` `Broker__c` must be non-null ``.

**No fallback `||` clause** — §1.7.

### 3.6 Test requirements

Route: **`salesforce-unit-testing`** after §3.1-3.5 land. Coverage target 90%+ per class.
All test data via `TestDataFactory`; **`createBrokerContacts` / `createBrokerContact` are mandatory**
for anything setting `Broker__c` (§0.6) — a plain `createContacts()` Contact will be refused by the
active, non-optional lookup filter.

**NEW — `DispositionBrokerStampServiceTest`:**

1. Insert with `Broker__c` set → `Selected_Broker__c` == `'Name - Firm'`.
2. Contact with blank `Broker_Firm__c` → `Selected_Broker__c` == `Name` (no trailing separator).
3. Update `Broker__c` from Contact A to Contact B → text re-stamps to B.
4. Clear `Broker__c` to null → `Selected_Broker__c` becomes null.
5. Update that does **not** touch `Broker__c` → `Selected_Broker__c` unchanged (**the regression
   guard for the on-market chain** — this is the test that proves the two paths do not collide).
6. **🔴 BULK: 251 records.** `.claude/rules/bulk-test-rule.md`'s 251-record mandate **APPLIES in
   full** — this is a trigger path, it loops over a collection, and there is **no exemption to
   claim**. The per-transaction-singleton exemption does not apply, and neither does the
   ContentPublication carve-out (no content objects involved). Assert all 251 stamped **and** assert
   the SOQL budget is **constant** (exactly 1 query for the whole chunk), which is the property that
   makes a future "one query per record" regression fail here rather than in production.
7. Maximum-length case: 40-char FirstName + 80-char LastName + 120-char firm → 244 chars, saves
   without truncation.

**MODIFIED — `DispositionApprovalServiceTest`:**

⚠ **These tests will fail as written and must be updated:**
- **`:170-176`** — the "blank broker refuses the submit" test. Retarget from a blank
  `Selected_Broker__c` to a null `Broker__c`, and assert the **new** message text.
- **`:191`** — sets `d.Selected_Broker__c = 'CBRE - Direct Pick'` to pass the gate. Must become a
  `Broker__c` assignment using `TestDataFactory.createBrokerContact(...)`.

Add: a record with `Selected_Broker__c` populated but `Broker__c` **null** must now be **REFUSED** —
this is the test that pins the §1.7 no-fallback decision so a later change cannot quietly restore it.

**MODIFIED — `DispositionApprovalProcessesTest`:**
- **`:180`** sets `d.Selected_Broker__c = 'Cushman & Wakefield - Direct Pick'` — same retarget.
- **`:148-151`** asserts the on-market stamp `'CBRE - Principal Approved'`. **Should still pass
  unchanged** — verify it does. If it fails, the stamp service is firing on the on-market path and
  test 5 above was wrong.

**MODIFIED — `DispositionSelectorTest`:** assert `selectApprovalContextById` returns `Broker__c`.

**NEW — `ContactSelectorTest`:** a case for `selectBrokerLabelsByIds`, including the null/empty-input
contract. Follow the existing `runAs` fixture in that test class, which already assigns both
`DPEG_Contact_Edit` and `DPEG_Contact_View`.

**Jest:** none. No LWC is created or modified in this wave.

---

## §4. EXECUTION ORDER AND ACCEPTANCE CRITERIA

### 4.1 Ordering — dependencies are load-bearing

| # | Step | Depends on / why |
|---|---|---|
| **0** | **PRE-FLIGHT (blocking).** Query the org for (a) pending `ProcessInstance` rows on `Disposition__c`, (b) the count of Off_Market `Disposition__c` rows, (c) any Off_Market row with non-blank `Selected_Broker__c`. Confirm `Broker__c` is not a soft-deleted name on `Disposition__c`. | (a) recalls required before §2.5; (b)+(c) re-verify the §1.7 no-fallback decision; (d) deploy would fail on a reserved name |
| **0b** | **`git diff HEAD`** on both permission sets and the flexipage. | Shared hub files; a concurrent session in this tree has previously merged two features into them silently |
| **1** | §2.1 field (+ translation) | **Everything** references `Broker__c` |
| **2** | §2.2 permission sets (surgical, additive) | 🔴 **Must land before or with step 5.** A Metadata-deployed field has no FLS; the widened USER_MODE selector throws for everyone until this lands |
| **3** | §2.3 flexipage | needs the field (1) and its FLS (2) to be visible/editable |
| **4** | §2.4 path assistant | needs the field (1); an active path step on an unreadable field renders blank |
| **5** | §3.1-3.5 Apex, deployed together | 3.5's gate needs 3.4's selector; 3.3 needs 3.2 needs 3.1 |
| **6** | §2.5 approval process | after step 0's recall sweep; needs the field (1) + FLS (2) |
| **7** | §2.6 seed-script guard | needs the field (1) to compile the guard query |
| **8** | §3.6 tests | after 5 |
| **9** | `salesforce-code-review`, then devops + docs | per `CLAUDE.md` workflow |

⚠ Steps 1, 2 and 5 are **one atomic change in effect**. If they must be split across deploys, the
order is field → permission sets → Apex, and **never** Apex first.

### 4.2 Acceptance criteria — off-market walk-through

Perform as a user holding **`DPEG_Junior_Analyst_PSG`** (the picker), then repeat the read-only steps
as **`DPEG_Principal_PSG`** (the approver).

1. Open an **Off_Market** `Disposition__c` at `Disposition Readiness`. The `Broker` field is visible
   in the `Details` section; `Selected Broker` is visible and empty.
2. Submit the Sale Decision approval; approve it. The stage auto-advances to `Broker Selection`.
3. **The Path step for `Broker Selection` shows `Broker` (not `Selected Broker`)**, with the rewritten
   guidance text.
4. Click **Submit Broker Selection** with `Broker` empty → refused with *"No broker has been selected
   on this disposition yet. Choose a broker in the Broker field, then submit for approval."*
   **Not** a platform "no applicable approval process was found" error.
5. Open the `Broker` lookup. **Only Contacts with `Is_Broker__c = true` appear.** Attempting to set a
   non-broker Contact (via API or a data load) is refused with *"The selected Contact is not flagged
   as a broker (Is_Broker__c)."*
6. Pick a broker Contact and save. **`Selected Broker` immediately reads `Firstname Lastname - Firm`**
   without a second save and without a page refresh action.
7. Change `Broker` to a different broker → `Selected Broker` re-stamps to the new person.
8. Clear `Broker` → `Selected Broker` clears too. Submit is refused again (step 4).
9. Re-pick a broker, click **Submit Broker Selection** → accepted.
10. **As the approver:** the approval request page shows **`Broker`** (a clickable Contact link)
    **above** `Selected Broker` (the person-and-firm string), plus Name, Owner, Stage, Property Asset.
11. ⚠ While the approval is **pending**, the record is `AdminOnly`-locked — confirm that editing
    `Broker` is refused with the platform's *"This record is locked"* text, and that recalling the
    approval restores editability. **This is expected behaviour, not a defect.**
12. Approve → the semaphore fires, the Queueable advances the stage to `NDA`, and **both** `Broker`
    and `Selected Broker` still hold the approved broker.
13. **🔴 ON-MARKET REGRESSION CHECK (mandatory).** Take an **On_Market** disposition through
    `BOV Outreach` → mark a submission Selected → `Broker_Finalize_Approval` → approve. The parent
    advances to `Broker Selection` and `Selected_Broker__c` is stamped with the **firm** from
    `BOV_Submission__c.Broker_Firm__c`, exactly as before. **`Broker__c` remains null and the `Broker`
    field is NOT rendered on the page.** Then exercise **Replace Broker** via `bovReplaceBrokerModal`
    and confirm `Selected_Broker__c` re-stamps to the new firm and `Broker__c` is still null.
14. **🔴 ADMIN CHECK.** Repeat steps 1-12 as a **System Administrator who also holds a disposition
    persona set**. A bare admin holding no disposition set cannot use this feature today and is not
    expected to after this change (§0.4) — confirm the behaviour is unchanged, not newly broken.
15. `sf apex run test --test-level RunLocalTests` passes, with the §3.6 classes at 90%+.

---

## §5. RISKS

### R1 🔴 `scripts/seed-broker-contacts.apex` silently nulls every broker lookup

`scripts/seed-broker-contacts.apex:4` — `delete [SELECT Id FROM Contact WHERE Is_Broker__c = true];`

With `deleteConstraint=SetNull`, re-running this seed **nulls `Broker__c` on every Disposition that
holds it, with no error**. The damage is invisible: `Selected_Broker__c` still displays the old
broker's name, so a corrupted record looks healthy on the page, in the Path step and on any report —
while the approval gate now refuses. **This is the highest-severity item in this document.**

Blast radius is wider than this wave: `Broker_Assignment__c.Broker__c`, `Lease_Inquiry__c.Broker__c`
and `Opportunity.Broker__c` all point at the same Contacts with the same `SetNull` semantics and are
equally exposed today.

**Mitigation (all three):** (1) the §2.6 guard that aborts the seed when any Disposition references a
broker Contact; (2) a loud header comment on the script naming all four dependent lookups; (3) treat
`seed-broker-contacts.apex` as a **rebuild-only** script — never run it against an org holding real
disposition data. Do **not** switch the field to `Restrict`: that would make the seed fail *loudly*
but would also block legitimate Contact deletion.

### R2 🔴 FLS gap breaks Submit for Approval org-wide, not just off-market

Per §0.3, `Broker__c` joins a `WITH USER_MODE` fetch-for-use read that backs **all four** approval
branches. Missing FLS ⇒ `QueryException: No such column` ⇒ the controller masks it as a generic
save failure that names nothing. **Mitigation:** §2.2 deployed before or with the Apex; acceptance
step 14. **The wrong turn is `WITH SYSTEM_MODE`** — banned by that method's own header.

### R3 Pending approval instances under a changed approval definition

`Broker_Selection_Approval` gains an `approvalPageField`. The file's standing warning (lines 67-69)
requires recalling pending instances first. The 2026-08-19 sweep found zero — **that measurement has
aged and must be re-run** (§4.1 step 0).

### R4 One field, two stamp formats

`Selected_Broker__c` will read `Firm` on on-market rows and `Person - Firm` on off-market rows.
Deliberate and justified (§1.5), but it means **no consumer may parse this field**. It is a display
string only. Nothing parses it today; keep it that way.

### R5 🔴 `BOV_Submission__c.Selected_Broker__c` keeps returning the TEXT field forever

`objects/BOV_Submission__c/fields/Selected_Broker__c.field-meta.xml:5` is the cross-object formula
`Disposition__r.Selected_Broker__c`. It feeds `reports/Dispositions/BOV_Tracker.report-meta.xml:31`,
where it is a **grouping**, not merely a column.

**This is acceptable this wave** — the text field is retained deliberately, so the formula keeps
resolving and the report keeps grouping correctly. **It is recorded here so a future retirement wave
does not miss it:** deleting `Disposition__c.Selected_Broker__c` would break this formula, and a
broken grouping field degrades a report *silently* (reports do not block field deletion). Any
retirement must repoint this formula (e.g. to `Disposition__r.Broker__r.Name`) **first**.

### R6 Active Path steps will block a future retirement of the Text field

After §2.4, `Selected_Broker__c` is still pinned by **`Disposition_Path_On_Market` lines 98 and 114**,
both on an **active** path. An active path step referencing a field **blocks that field's deletion**.
A future retirement wave must remove those steps before attempting the delete. (§2.4 removes the
off-market pin, which is progress in that direction.)

### R7 The lookup would appear on on-market records without a field-level visibility rule

The `Details` section is visible at `Broker Selection` for **both** record types (flexipage 633-655).
Mitigated by §2.3. If that rule is omitted or silently dropped, an on-market analyst sees an empty
`Broker` field and may fill it — creating a record where the lookup and the BOV-stamped text disagree,
with no automation reconciling them.

### R8 The record is locked while its own approval is pending

`recordEditability = AdminOnly` (approval file line 127) means the broker cannot be corrected between
submission and decision — the approval must be recalled first. Expected and correct (the same
reasoning `BovSubmissionService.cls:43-48` records for refusing a replacement under a pending
approval), but it is a workflow constraint users must be told about. Acceptance step 11.

### R9 Shared hub files and concurrent sessions

This change edits **2 permission sets + 1 flexipage** — precisely the hub-file set that has
previously been silently merged into a union of two features by a concurrent session in this same
working tree, failing the deploy on the other feature's undeployed field. **Diff all three against
`HEAD` immediately before deploying** (§4.1 step 0b). Commit any retrieve on its own.

### R10 `Broker__c` may be a reserved (soft-deleted) API name on `Disposition__c`

Free in source (verified), but a previously deleted field keeps its API name reserved until it is
**ERASED** from the field recycle bin. The deploy would fail with a duplicate-name error that reads
like a source defect. Checked in §4.1 step 0.

---

## §6. OPEN ITEMS (flagged, not invented)

1. **`ContactSelector.selectBrokerLabelsByIds`** — suggested spelling. If the implementing agent
   prefers a different name, pick one and use it consistently across the selector, the service, the
   class headers and the tests.
2. **`DispositionBrokerStampService`** — suggested class name (29 chars, under the 40-char cap).
   Same instruction.
3. **`FieldBroker`** — suggested flexipage `identifier`, following the existing `FieldSelectedBroker`
   / `FieldDispositionStage` convention in that file.
4. **The `<info>` text at `Disposition_Path_Off_Market:77`** — suggested wording in §2.4. Final
   copy is the admin agent's call, provided it names the **Broker** field and no longer says
   "Selected Broker".
