# Multi-Property Email Package Grouping (`Property_Package__c`)

**Date:** 2026-08-17
**Author:** Documentation Agent
**Status:** Code complete on the current branch. Admin metadata, Apex, and both LWCs are present in `force-app/main/default` and pass the class-header/test evidence cited below. **No standalone `agent-output/*-code-review.md` file exists for this feature and no `salesforce-devops` deploy report was found in this pass** — this doc was written while `salesforce-devops` was deploying in parallel; org state on the target org is **not independently verified here**. Verify deployment and FLS assignment before relying on this as live.

---

## 📋 Overview

### Original Request

> From `agent-output/design-requirements-deal-portfolio.md`: when a broker forwards one email naming two or more properties (a package/portfolio listing), the existing Broker Protection pipeline (`ExtractAddressQueueable`) already routes each named property independently through its own claim/Lead-creation logic — but records no relationship between the resulting Leads. Build a way to group everything one email produced (Leads, and later the Opportunities and Properties they convert into) so the Acquisitions team can work a package deal as a package, without touching the existing, unrelated `Portfolio_Deal__c` manual-bundling concept already on `Opportunity`.

### Business Objective

Before this change, a broker's "here are three assets for sale" email produced three independent Leads with nothing in the data model saying they arrived together. An analyst working one of them had no way to discover the other two short of searching by broker or by memory. The pipeline had already computed the grouping correctly — it was sitting as delimited text (`Inbound_Email_Staging__c.Routed_Record_Ids__c`) on a backend, Private-visibility staging object the Acquisitions team cannot see — so the gap was **visibility and queryability**, not detection.

### Summary

A new custom object, `Property_Package__c`, is created once per multi-property email by the Broker Protection pipeline and linked (via lookup, never master-detail) to every Lead the email produced, and later to every Opportunity and `Property__c` those Leads convert into. Two LWCs surface it: the existing `recentLeads` component on the Lead Funnel homepage gained a "Package" link column, and a new, single, object-agnostic `c/packageSiblings` card was added to both the Lead and Opportunity record pages showing the other records that arrived on the same email. The feature is deliberately scoped as a **visibility surface over an already-correct derivation** — it changes no routing, claim, or Task-logging behavior in the pipeline.

---

## 🏗️ Components Created

### Admin Components (Declarative)

#### Custom Objects

| Object API Name | Label | Sharing Model | Description |
|---|---|---|---|
| `Property_Package__c` | Property Package | `ReadWrite` | One inbound broker email that named two or more properties. Groups the Leads, Opportunities and Properties created from that single email. Created only by the Broker Protection pipeline; never by hand. `enableActivities=false`, `enableHistory=false`, `enableReports=true`. |

`ReadWrite` OWD was a deliberate decision (Decision F1 in the design doc), matching the two existing pipeline-written Broker Protection objects, `Property_Registry__c` and `Competing_Broker_Submission__c` — see *Key Design Decisions* below.

#### Custom Fields

| Object | Field API Name | Type | Notes |
|---|---|---|---|
| `Property_Package__c` | `Name` (standard) | Text(80) | The email subject, clipped; falls back to `"Multi-Property Email"` when the subject is blank (Name is a required platform field). |
| `Property_Package__c` | `Property_Count__c` | Number(2,0) | The de-duplicated, addressable, capped property count the email produced (clamped to 99 at insert). |
| `Property_Package__c` | `Broker_Email__c` | Email | The pipeline's resolved broker email (post-U1 envelope arbitration), sanitized before storage. |
| `Property_Package__c` | `Broker_Name__c` | Text(255) | The resolved broker name, post-U1. |
| `Property_Package__c` | `Source_Staging_Id__c` | Text(18) | Plain text pointer to the `Inbound_Email_Staging__c` row this email landed on — mirrors the existing `Result_Record_Id__c` text-pointer precedent rather than a lookup. |
| `Property_Package__c` | `Received_DateTime__c` | DateTime | When the email was sent, as the pipeline parsed it. Named `_DateTime__c`, never `_Date__c`, per §1 rule 6. |
| `Property_Package__c` | `Routed_Outcomes__c` | Long Text Area(32768) | A copy of the pipeline's per-email routed-outcome audit text (Decision B2) — this is what lets a package show which named properties went to a *different*, competing broker. |

#### Relationship Fields (Lookups)

| Object | Field API Name | Points At | Delete Constraint | Relationship Name |
|---|---|---|---|---|
| `Lead` | `Property_Package__c` | `Property_Package__c` | `SetNull` | `Leads` |
| `Opportunity` | `Property_Package__c` | `Property_Package__c` | `SetNull` | `Opportunities` |
| `Property__c` | `Property_Package__c` | `Property_Package__c` | `SetNull` | `Properties` |

All three are `SetNull` on purpose — deleting a package must never cascade into deal records. Per §1 rule 3, the field name **is** the target object's name (a single lookup per object here, no role-naming needed).

#### Page Layout / FlexiPages

| Component | Change |
|---|---|
| `Property_Package__c-Property Package Layout.layout-meta.xml` | New. Two-column detail section (Name/Property_Count__c/Received_DateTime__c/Broker_Name__c/Broker_Email__c/Source_Staging_Id__c) plus a one-column "Routing Detail" section for `Routed_Outcomes__c` and `OwnerId`. Three related lists wired: `Lead.Property_Package__c`, `Opportunity.Property_Package__c`, `Property__c.Property_Package__c`, plus `RelatedNoteList`. **No `<fields>` column list is specified on any of the three custom related lists** (unprecedented elsewhere in this repo's 119+ other layouts) — see *Known Limitations*. |
| `Property_Package_Record_Page.flexipage-meta.xml` | New. Standard dynamic-highlights header + two-column detail + a related-lists tab (`force:relatedListContainer`, auto-detected). No custom LWC on this page — the three auto-generated standard related lists (Leads, Opportunities, Properties) fully satisfy the design's requirement; a fourth, custom LWC was explicitly considered and rejected (design §3, Item 3) as adding nothing the standard related lists don't already provide. Activities panel deliberately omitted (`enableActivities=false` on the object). |
| `Lead_Record_Page.flexipage-meta.xml` | Modified — added `c-packageSiblings` as a new `itemInstance`, with an inline XML comment explaining the one-bundle, object-agnostic placement. No existing `itemInstance` removed. |
| `Opportunity_Record_Page.flexipage-meta.xml` | Modified — added the identical `c-packageSiblings` placement, same comment. |
| `Lead_Funnel.flexipage-meta.xml` | **No change required.** `recentLeads` was already placed on this page; only its internal columns changed. |

#### Permission Sets (edited, no new sets)

| Permission Set | Change |
|---|---|
| `DPEG_Acquisition_Edit` | Object CRUD (Read/Create/Edit) + editable+readable FLS on all six `Property_Package__c` fields, plus editable+readable FLS on `Lead.Property_Package__c` / `Opportunity.Property_Package__c` / `Property__c.Property_Package__c`. |
| `DPEG_Acquisition_View` | Object Read + readable FLS on all six `Property_Package__c` fields, plus readable FLS on the three lookups. |
| `Broker_Protection_Access` | Object CRUD + editable+readable FLS on all six `Property_Package__c` fields (this is the permission set the pipeline itself effectively provisions for), plus editable+readable FLS on `Lead.Property_Package__c` — the field `EmailToLeadService.createLeadFromExtracted` stamps at insert. `viewAllRecords=true` on `Property_Package__c`. |
| `DPEG_Apex_Access` | Added `classAccesses` entry for `PropertyPackageController` (the only new class that needs one — `PropertyPackageService` and `PropertyPackageSelector` are invoked only from other Apex, not directly from an LWC). |

⚠ All grants were declared **in-file**, per this repo's standing lesson that a `PermissionSet` deploy **replaces** its entire `<fieldPermissions>`/`<objectPermissions>` set rather than merging — an org-side-only grant is silently wiped by the next unrelated deploy of the same file (this bit Broker Protection twice on 2026-08-05/06; see ARCHITECTURE.md §2). This is doubly load-bearing here because `LeadSelector.selectRecent` (the Lead Funnel homepage's read) is `WITH USER_MODE` and now selects `Lead.Property_Package__c` — a missing grant would throw the **entire homepage query**, not just hide the new column.

---

### Development Components (Code)

#### Apex Classes

| Class Name | Layer | Description |
|---|---|---|
| `PropertyPackageService` | Service | The **only** class that writes `Property_Package__c`. `createForEmail(...)` — zero SOQL (blind insert), one DML, `AccessLevel.SYSTEM_MODE`, `allOrNone=true` (throws on failure — the caller must decide what a failed grouping costs). `stampRoutedOutcomes(...)` — the second, later DML that copies the finished routing audit onto the package; deliberately fail-soft (`catch (Exception e)`, logs and swallows) because by the time it runs the canonical copy of that text is already durable on the staging row. |
| `PropertyPackageSelector` | Selector | The first and only `Property_Package__c` SOQL in the application. `selectWithMembersById(...)` returns one package plus **both** its member collections (open Leads, all Opportunities) via relationship subqueries in a single query. `WITH USER_MODE`, deliberately — see *Key Design Decisions*. |
| `PropertyPackageController` | Controller (`@AuraEnabled`) | Thin, no service layer (P6 read-only-controller precedent). `getSiblingRecords(Id recordId)` dispatches on `recordId.getSObjectType()` to resolve the anchor record's package, then returns the *other* Leads/Opportunities sharing it. This single method is what lets one LWC bundle serve both the Lead and Opportunity record pages. |
| `PropertyPackageServiceTest` | Test | 12 test methods. |
| `PropertyPackageSelectorTest` | Test | 7 test methods, including the converted-Lead double-count regression (see *Testing & Code Review*). |
| `PropertyPackageControllerTest` | Test | 10 test methods, including both-anchor-type dispatch and current-record exclusion. |

#### Apex Classes Modified

| Class | Change |
|---|---|
| `ExtractAddressQueueable` | Adds `createPackageIfMultiProperty(...)`, called **pre-loop**, outside the per-property `try/catch` (Decision C1) — gated on `workList.size() > 1` (Decision E: the de-duplicated, addressable, capped count). The resulting package Id is stamped onto each Lead as the per-property loop creates it. In `finish()`, `PropertyPackageService.stampRoutedOutcomes(...)` is called once the full routing audit exists, adding a **second** DML statement against the package that could not be avoided (see *Key Design Decisions*). The class's documented "no SOQL, no DML of its own" invariant for the routing engine is preserved by delegating both writes to `PropertyPackageService`. |
| `EmailToLeadService` | `LeadRequest` gained one additive, nullable field for the package Id, stamped onto the Lead at insert inside `createLeadFromExtracted`. No existing field or overload was changed or removed. |
| `LeadConvertService` | `applyDealFields` and `buildProperty` each gained one line carrying `l.Property_Package__c` onto the new Opportunity and the new `Property__c` respectively — both are in-memory assignments on records already being written, so the class's `2 SOQL / ≤5 DML` contract is unchanged (test-asserted, see *Testing*). |
| `LeadSelector` | New `selectPackageAnchorById(Id leadId)` — the Lead-rooted half of the `c/packageSiblings` reads (`WITH USER_MODE`). `selectRecent(...)` widened to also select `Property_Package__c` and the spanning `Property_Package__r.Name` for the `recentLeads` column — zero extra SOQL, since spanning fields ride the existing query. |
| `OpportunitySelector` | New `selectPackageAnchorById(Id opportunityId)` — the Opportunity-rooted twin of the `LeadSelector` method above (`WITH USER_MODE`). Originally also selected the spanning `Property_Package__r.Name`; that was **removed** during code review (see *Testing & Code Review*, finding W2) because nothing consumes it and a parent-object traversal under `WITH USER_MODE` is an extra way for this anchor read to throw. |
| `LeadFunnelController` | `LeadRow` DTO gained `packageId` / `packageName`, populated in the existing `for (Lead l : LeadSelector.selectRecent(...))` loop — no new query. |

#### Lightning Web Components

| Component | Change |
|---|---|
| `recentLeads` | **Extended, not replaced.** One new `type: 'url'` datatable column (`Package`), following the bundle's own existing link precedent rather than introducing per-cell `NavigationMixin`. A Lead with no package renders an empty cell (`packageUrl: null`), never a dead link to `.../Property_Package__c/null/view`. `totalLeads` and `leadChannels` (the homepage's other two bundles) were not touched. |
| `packageSiblings` | **New.** One object-agnostic bundle (`@api recordId`, `@api objectApiName` held but deliberately never branched on), placed on both `Lead_Record_Page` and `Opportunity_Record_Page`. Imports no object schema at all — the server does the dispatch. Renders **nothing** (not an empty card) when the anchor record has no package; renders a card with a package-name link and a list of sibling records (each navigable via `NavigationMixin`) otherwise, including the "no other members" case for a one-member package. |

#### Test Coverage

| Test Area | Coverage |
|---|---|
| `PropertyPackageService` / `PropertyPackageSelector` / `PropertyPackageController` | Dedicated new test classes, 12 / 7 / 10 methods respectively. |
| `ExtractAddressQueueableTest` | 6 new methods: exactly-one-package-linking-every-winner-Lead, single-property-email-creates-no-package, duplicate-addresses-create-no-package (dedup gate), mixed-outcome audit text, per-property-failure-does-not-orphan-or-duplicate, reply-branch-creates-no-package. The pre-existing N=10 exact-equality DML budget assertion moved `43 → 45` (not the `44` the design doc originally projected — see *Key Design Decisions*); the single-property DML budget assertions (`≤20`, and a separate `==7` equality) were **left unchanged and are the permanent falsifier for Decision E** — the multi-property gate does not fire for one property under any circumstance. |
| `LeadConvertServiceTest` | 3 new methods: package carried to both the Opportunity and the `Property__c`; a Lead with no package leaves both lookups blank; the carry-forward adds zero SOQL and zero DML (asserted by comparing paired conversions with and without a package). |
| `recentLeads.test.js` | 3 new `it()` blocks: package link renders correctly; a Lead with no package renders an empty cell (not a dead link); the column is a `type: 'url'` datatable column labelled from `packageName`, not a custom type. |
| `packageSiblings.test.js` | New suite, 18 `it()` blocks, including `@sa11y/jest` accessibility assertions, the null-`packageId` invisible-card case, sibling navigation, and the error path. |

---

## 🔄 Data Flow

### How It Works

```
1. Broker forwards ONE email naming 2+ properties.
2. EmailToLeadHandler stages it (Inbound_Email_Staging__c) and enqueues ExtractAddressQueueable.
3. ExtractAddressQueueable's prologue runs: LLM extraction, relevance gate, dedup/sort/cap the
   property work-list.
4. workList.size() > 1  ─────────────────────────────────────────────────►  YES
                              │                                              │
                              NO                                             ▼
                              │                              PropertyPackageService.createForEmail()
                              │                              (pre-loop, outside per-property try/catch)
                              ▼                                              │
                    (existing single-property                                ▼
                     routing, unchanged)                       Property_Package__c row created
                                                                              │
                                                                              ▼
                                              For each property in the work-list (per-property loop,
                                              unchanged routing/claim logic):
                                                winner   -> Lead created, stamped with
                                                            Property_Package__c AT INSERT
                                                competing -> no Lead; recorded against the winner
                                                repeat    -> filed on the existing record
                                                              │
                                                              ▼
                                        finish() epilogue: routing audit text built, then
                                        PropertyPackageService.stampRoutedOutcomes() copies it
                                        onto Routed_Outcomes__c (2nd DML on the package).
                                                              │
                                                              ▼
                          Later, at conversion: LeadConvertService.applyDealFields /
                          .buildProperty carry Property_Package__c onto the new Opportunity
                          and Property__c (in-memory, 0 extra SOQL/DML).
```

### Read side (record pages)

```
┌────────────────────────┐        ┌───────────────────────────┐
│  Lead / Opportunity     │        │  Lead Funnel homepage      │
│  record page            │        │  (recentLeads LWC)         │
│                         │        │                             │
│  c/packageSiblings      │        │  "Package" column           │
│    │                    │        │    └─ type:'url' link to    │
│    └─ PropertyPackage-  │        │       /lightning/r/          │
│       Controller        │        │       Property_Package__c/  │
│       .getSiblingRecords│        │       {id}/view              │
└──────────┬──────────────┘        └───────────────────────────┘
           │
           │ query 1 (anchor): LeadSelector.selectPackageAnchorById /
           │                   OpportunitySelector.selectPackageAnchorById
           ▼
   Property_Package__c Id
           │
           │ query 2: PropertyPackageSelector.selectWithMembersById
           │   (one query, two relationship subqueries: Leads__r, Opportunities__r)
           ▼
   { packageId, packageName, siblings[] }  ──►  rendered on the card, current record excluded
```

### Architecture Diagram — relationship model

```
                    Property_Package__c   (1)
                    /        |         \
                   /         |          \
              Lead (N)  Opportunity (N)  Property__c (N)
         [pipeline, at   [LeadConvertService  [LeadConvertService
          insert, C1]     .applyDealFields,     .buildProperty,
                           at conversion]        at conversion]

  All three lookups: deleteConstraint = SetNull
  (deleting a package never cascades into deal records)
```

---

## 📁 File Locations

| Component Type | Path |
|---|---|
| Custom Object | `force-app/main/default/objects/Property_Package__c/` |
| Lookup fields on existing objects | `force-app/main/default/objects/Lead/fields/Property_Package__c.field-meta.xml`, `objects/Opportunity/fields/Property_Package__c.field-meta.xml`, `objects/Property__c/fields/Property_Package__c.field-meta.xml` |
| Layout | `force-app/main/default/layouts/Property_Package__c-Property Package Layout.layout-meta.xml` |
| FlexiPages | `force-app/main/default/flexipages/Property_Package_Record_Page.flexipage-meta.xml`, `Lead_Record_Page.flexipage-meta.xml` (modified), `Opportunity_Record_Page.flexipage-meta.xml` (modified) |
| Permission Sets | `force-app/main/default/permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml`, `DPEG_Acquisition_View.permissionset-meta.xml`, `Broker_Protection_Access.permissionset-meta.xml`, `DPEG_Apex_Access.permissionset-meta.xml` |
| Apex Classes | `force-app/main/default/classes/PropertyPackageService.cls`, `PropertyPackageSelector.cls`, `PropertyPackageController.cls` (+ their `*Test.cls` siblings) |
| Apex Classes Modified | `ExtractAddressQueueable.cls`, `EmailToLeadService.cls`, `LeadConvertService.cls`, `LeadSelector.cls`, `OpportunitySelector.cls`, `LeadFunnelController.cls` (+ matching test classes) |
| LWC — new | `force-app/main/default/lwc/packageSiblings/` |
| LWC — modified | `force-app/main/default/lwc/recentLeads/` |
| Design record | `agent-output/design-requirements-deal-portfolio.md` |
| Architecture reference | `ARCHITECTURE.md` §1 (Lead Intake / Broker Protection object table), §2 (`PropertyPackageService` row + the `WITH SYSTEM_MODE` automation-path table's explicit contrast paragraph) |

---

## ⚙️ Configuration Details

### Object & Field Summary

`Property_Package__c` — `ReadWrite` sharing, no record types, `enableActivities=false`, `enableHistory=false`, `enableReports=true`. Seven stored fields total (`Name` + the six in the table above). No currency, no formula, no roll-up-summary fields — a rolled-up aggregate (total price, total SF) across the package was explicitly rejected in Decision D because a roll-up over a Lookup relationship is not available on the platform, and any Apex-computed alternative would mean either a new query on every read or a value that goes stale.

### Governor Impact (measured, test-pinned)

| Path | Before | After | Cap |
|---|---|---|---|
| `ExtractAddressQueueable`, N=10 properties | 43 DML (exact equality) | **45 DML** (+1 package insert, +1 audit stamp) | 150 |
| `ExtractAddressQueueable`, N=10 properties | ≤120 SOQL | Unchanged — the package insert is blind (zero SOQL) | 200 |
| `ExtractAddressQueueable`, N=1 property | ≤20 DML / exactly 7 DML (both asserted) | **Unchanged** — permanent falsifier for Decision E | 150 |
| `LeadConvertService` | 2 SOQL / ≤5 DML | **Unchanged** (0 added) — carry-forward is in-memory | — |

The design doc originally projected the multi-property DML delta as `43 → 44`. The shipped number is `43 → 45`, because the routing-outcomes audit text does not exist until *after* the per-property loop finishes, while the package must exist *before* the loop starts so each Lead can be stamped at insert (Decision C1). Those two requirements sit on opposite sides of the loop and cannot be satisfied by one DML statement, so a second, later `stampRoutedOutcomes` write was required. Both statements are constant in property count (2 total DML on the package whether N=2 or N=10).

### Permission Set FLS Detail

`Broker_Protection_Access` grants editable+readable FLS on all six `Property_Package__c` fields plus `Lead.Property_Package__c`, with `viewAllRecords=true` on the object — this is the permission set the pipeline effectively runs under for provisioning purposes (the actual DML uses `AccessLevel.SYSTEM_MODE`, so this grant matters for any human reading the object, not for the pipeline's own writes). `DPEG_Acquisition_Edit` / `DPEG_Acquisition_View` mirror the edit/view split already used for every other Acquisitions-module object.

---

## 🔑 Key Design Decisions and Rationale

*(Pulled directly from the shipped class-header Javadoc, which carries this repo's convention of embedding full design rationale in the code rather than only in the design doc.)*

**Why `ReadWrite` sharing (Decision F1), and why it deletes a whole class of defect.** `PropertyPackageService`'s header states this plainly: every `private without sharing` inner-class pattern elsewhere in this repo (`InboundEmailStagingSelector.RoutingReads`, `PropertyAssetSelector.AssetCreationReads`, `PropertySelector.FolderCreationReads`, `DispositionOfferSelector.TractionReads`) exists **because** a Private-OWD object made a pipeline read return zero rows for a principal who didn't own the row — failing silently, or worse, as a duplicate when the read backed an idempotency guard. Matching the object's OWD to its two sibling pipeline-written objects (`Property_Registry__c`, `Competing_Broker_Submission__c`) means no such read exists here and no `without sharing` inner class is needed anywhere in the feature. The header explicitly warns: narrowing this OWD later is not a settings change, it re-opens that whole failure class.

**Why the insert is `AccessLevel.SYSTEM_MODE`.** Every field on `Property_Package__c` is Metadata-API-deployed and therefore ships with **no field permissions for any profile, System Administrator included**. A bare `insert` would throw `System.TypeException` for every principal in the org on the very first multi-property email after deploy — the same measured reasoning already recorded for `PropertyAssetService` and `DealFolderService`.

**Why the insert throws but the caller decides what that costs.** `createForEmail` uses `allOrNone=true` — a half-created package (Lead stamped, no package row) would be worse than none at all. But the calling transaction (`ExtractAddressQueueable`) owns the Lead and the registry claim, which are irreplaceable in a way the package grouping is not, so the queueable wraps the call in its own `try/catch` and degrades to "no package" rather than losing the email. `stampRoutedOutcomes` takes the opposite posture on purpose — it is fail-soft, because by the time it runs, the canonical copy of the audit text is already durable on the staging row, so a failure here loses only a convenience copy.

**Why `PropertyPackageSelector` is `WITH USER_MODE`, deliberately, and is not in the `SYSTEM_MODE` automation-path table.** The class header argues this explicitly against both standard justifications for `SYSTEM_MODE` elsewhere in the codebase: (1) "USER_MODE throws rather than degrades, silently disabling a feature" doesn't apply, because the feature *is* the human's own page view — there is no automation to disable and no batch job failing silently at 3am; (2) "day-one no-FLS on a new custom field" doesn't argue for `SYSTEM_MODE` here either, because the correct remedy for a provisioning gap on a user-requested read is provisioning (the in-file FLS grants), not a selector that reads around the user.

**Why the server dispatches, rather than the client `@wire getRecord`-ing the lookup.** The design doc explicitly evaluated and rejected `@wire getRecord` with a per-object schema import (breaks object-agnosticism outright) and a dynamic `${objectApiName}.Property_Package__c` field reference (avoids the schema import but needs a second round trip and an awkward intermediate loading state). `PropertyPackageController.getSiblingRecords(Id recordId)` takes the same shape as the existing `RecordStageAdvanceController.hasStageActionAccess(recordId)` pattern — the controller is the *only* place in the whole feature that names `Lead` or `Opportunity`, which is what lets one LWC bundle serve both record pages with zero per-object branching on the client.

**Why the `IsConverted = false` filter was added to the Leads subquery (code review finding, tagged C3 in the selector's own header).** Without it, every converted package member rendered **twice** on the sibling card: `LeadConvertService.applyDealFields` carries `Property_Package__c` onto the Opportunity at conversion but nothing nulls it on the source Lead, so a converted Lead and its resulting Opportunity are simultaneously two rows in the same package — and the Lead's URL is unusable besides (Salesforce always redirects a converted Lead's record URL to the Contact). On the Opportunity record page specifically, the unfiltered query also defeated the controller's own current-record exclusion, because the deal's *former* Lead has a different Id from the Opportunity and so was never excluded by the `!= recordId` comparison — it appeared as a "sibling" of itself. `PropertyPackageSelectorTest.aConvertedMemberIsCountedOnceNotTwice` is the regression pin, and it deliberately runs a real `Database.convertLead` rather than an independently-built fixture, because only a real conversion produces the state that exposed the bug.

**Why `Property_Package__r.Name` was removed from `OpportunitySelector.selectPackageAnchorById` (tagged W2 in that class's header).** It was in the original SELECT and had no consumer — the card's heading is sourced from `PropertyPackageSelector.selectWithMembersById` one query later. A parent-object field traversal under `WITH USER_MODE` requires object-level READ on the parent as well as field-level FLS, so carrying it here was an unused way for this anchor read to throw. `LeadSelector.selectPackageAnchorById` was changed identically — the header notes the two methods are exact twins and must be changed together, never one without the other.

### Build process note

Per the task context for this documentation pass, this feature went through four rounds of code review before reaching its shipped state; two of the fixes described above (the `IsConverted` filter and the removed spanning field) carry review labels directly in their class headers (**C3** and **W2** respectively) that this doc could independently verify against the code. The broader four-round history — including an intermediate hand-authored page layout that briefly dropped the related lists the design relied on, and a compile-breaking missing `__r` relationship-suffix reference that survived two earlier passes — was reported as part of this task's own context rather than found in a standalone `agent-output/*-code-review.md` file; no such file exists for this feature in this repo. The general lesson it illustrates is grounded in the shipped code: `PropertyPackageSelector`'s header explicitly documents that a relationship subquery's name is the lookup's `relationshipName` **plus** `__r` regardless of whether the child object is standard (`Lead`, `Opportunity`) or custom, citing this repo's existing `Wire__c` → `Disposition__c` (`Wires__r`) precedent, and states that renaming either relationship breaks the query **at compile time** — deliberately "the good failure mode."

---

## 🧪 Testing & Code Review

### Test Coverage Summary

| Class / Suite | Tests | Notes |
|---|---|---|
| `PropertyPackageServiceTest` | 12 methods | New |
| `PropertyPackageSelectorTest` | 7 methods | New; includes the real-conversion regression pin for the `IsConverted` filter |
| `PropertyPackageControllerTest` | 10 methods | New; includes both-anchor-type dispatch and current-record exclusion |
| `ExtractAddressQueueableTest` | +6 methods | Multi-property package creation, single-property no-package, dedup gate, mixed-outcome audit, per-property failure isolation, reply-branch no-package |
| `LeadConvertServiceTest` | +3 methods | Package carried to Opportunity and Property; blank on no-package Leads; carry-forward costs zero SOQL/DML |
| `recentLeads.test.js` (Jest) | +3 `it()` blocks | Package link render; empty-cell-not-dead-link; `type:'url'` column shape |
| `packageSiblings.test.js` (Jest) | 18 `it()` blocks (new suite) | Includes `@sa11y/jest` accessibility assertions |

The N=10 DML equality assertion in `ExtractAddressQueueableTest` was updated `43 → 45`. The N=1 (single-property) DML assertions were **deliberately left unchanged** and are called out in the test class's own comments as the permanent falsifier for Decision E — proof that the package gate never fires for a single-property email.

### Code Review Findings (as evidenced in shipped code)

No standalone code-review markdown file exists for this feature; the following are grounded directly in class-header comments and test-method names, per this repo's convention of recording review findings inline:

| Finding | Location | Resolution |
|---|---|---|
| **C3** — a converted Lead double-counts its own package membership | `PropertyPackageSelector.selectWithMembersById` | Added `WHERE IsConverted = false` to the Leads subquery; regression-pinned by a test that runs a real `Database.convertLead`. |
| **W2** — an unused spanning field widens an anchor read's FLS/CRUD exposure for no benefit | `OpportunitySelector.selectPackageAnchorById` | Removed `Property_Package__r.Name` from the SELECT; `LeadSelector`'s twin method was changed identically. |

---

## 🔒 Security

### Sharing Model

- `Property_Package__c` OWD is `ReadWrite` (Decision F1). All three new Apex classes are `with sharing`, and none of them declares a `without sharing` inner class — the `ReadWrite` OWD makes that unnecessary anywhere in this feature.
- `PropertyPackageService.createForEmail` / `stampRoutedOutcomes` write via `Database.insert(..., AccessLevel.SYSTEM_MODE)` / `Database.update(..., AccessLevel.SYSTEM_MODE)` — required because the new fields ship with zero FLS for any profile on day one.
- `PropertyPackageSelector.selectWithMembersById`, `LeadSelector.selectPackageAnchorById`, and `OpportunitySelector.selectPackageAnchorById` are all `WITH USER_MODE` — a deliberate contrast with this codebase's automation-path `SYSTEM_MODE` pattern, because every one of these reads backs a card on a record page a human already has open, at their own request.

### Required Permissions

A user needs `DPEG_Acquisition_Edit` or `DPEG_Acquisition_View` (or `Broker_Protection_Access`, for the pipeline's own effective identity) to see `Property_Package__c` data, its record page, and the package link/card on Lead and Opportunity record pages. Because `LeadSelector.selectRecent` is `WITH USER_MODE` and now selects `Lead.Property_Package__c`, **a persona missing this FLS grant will find the entire Lead Funnel homepage throws**, not merely see a blank Package column — verify the grant is present before assuming the homepage is unaffected for any given profile/permission-set combination.

---

## 📝 Notes & Considerations

### Known Limitations / Residuals

Carried forward from the design doc's own residuals list (§7), restated here for a reader who wasn't in the design conversation:

| # | Residual | Status |
|---|---|---|
| **R1** | `Opportunity` now carries **two unrelated portfolio concepts**: this pipeline-derived `Property_Package__c` (one email → many Leads/Opportunities/Properties) and the pre-existing, dormant, **manual** `Portfolio_Deal__c` self-lookup / `Is_Portfolio_Parent__c` / `Bundle_LOI__c` / `Portfolio Deal` stage (one seller bundling several deals under a single LOI). They answer different questions, have no relationship, and must never be merged, cross-populated, or reported as one. **No automated test can detect a divergence between them** — this doc, ARCHITECTURE.md §1/§2, and the inline comment at `LeadConvertService.applyDealFields`'s assignment are the only control. This was a deliberate, user-directed decision (Decision A2) — the existing `Portfolio_Deal__c` model was found during design and left completely untouched: not merged, not retired, not wired. |
| **R2** | `LeadSelector.selectRecent`'s `WITH USER_MODE` widening is a single point of failure for the whole Lead Funnel homepage if the FLS grant on `Lead.Property_Package__c` is missing from any assigned permission set — see *Security* above. Mitigated by declaring the grant in-file in three permission sets; deploy order (admin metadata with/before Apex) matters. |
| **R3** | A follow-up reply naming additional properties never joins the package — the reply branch returns before the LLM callout (`routePrologueWithoutCallout`), consistent with this pipeline's existing branch-(a) trade-off. |
| **R4** | A call-for-offers-gated email creates no Leads at all, so it produces no package even if it names ten properties — consistent with the pipeline's existing U2 gate (no Lead, no claim). |
| **R5** | Historical multi-property emails received before this feature's deploy get no package. Out of scope unless requested — a backfill would be comparatively cheap since `Routed_Record_Ids__c` already holds the full historical mapping as text. |
| **R6** | A one-member package can occur when the other named properties fail to route after the package is created (Decision C1's pre-loop placement). This is visible and arguably correct — it records that a package arrived and some/all of its properties failed — and no cleanup was designed for it. The `packageSiblings` card explicitly handles this state ("No other records were created from this email"). |
| **R7** | `Routed_Outcomes__c` is raw audit text, not a parsed/structured table. Rendering it as a structured view was explicitly deferred as a separate request (a third LWC), not built here. |
| **R8** | (Doc-drift item, already corrected in ARCHITECTURE.md during this build) — the `LeadConvertService` row in ARCHITECTURE.md previously read "2 SOQL / 3 DML"; the class header already said "≤5 DML" as of an earlier 2026-08-10 change. Corrected to `≤5` in the same PR that introduced this feature. |

### Known-Open Items at Documentation Time

Per the task context, the following were open at the time this feature was built and may or may not be resolved by the time this doc is read — verify against a real deploy before assuming either way:

- **Related-list token direction was unverified against a live org until the actual deploy attempt.** This repo has no prior precedent for a *standard* object's child related list (`Lead`, `Opportunity`) declared on a *custom* object's page layout — the layout file declares `<relatedList>Lead.Property_Package__c</relatedList>` etc. (parent-object-dot-child-relationship form), which is the form used elsewhere in this repo, but this is the first custom-object-parent instance of it.
- **The three child related lists on the new layout carry no explicit `<fields>` column list** — every other related list definition elsewhere in this repo's 119+ layouts specifies one. This is not necessarily wrong (Salesforce will fall back to a default column set), but it is unprecedented in this codebase and worth a deliberate check against the deployed org rather than an assumption either way.

### Dependencies

- Depends on the existing Broker Protection pipeline (`ExtractAddressQueueable`, `EmailToLeadService`, `InboundEmailStagingService`, `LeadConvertService`) — no changes to the routing tree, the claim engine, or the Task-logging contract were made; this feature is additive at four specific points (pre-loop package creation, per-Lead stamp at insert, post-loop audit stamp, and conversion carry-forward).
- Depends on the Lead Funnel homepage (`Lead_Funnel.flexipage-meta.xml`, `recentLeads` LWC, `LeadFunnelController`) already existing and already placed — this feature required no new page and no new bundle for LWC #1.
- Depends on `Lead_Record_Page` and `Opportunity_Record_Page` FlexiPages already existing with Dynamic Actions / action bars intact — the admin change preserved every existing `itemInstance` and did not touch either page's `actionNames` list, per this repo's standing warning that doing so can silently empty a page's action bar.

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-17 | Documentation Agent | Initial creation |
