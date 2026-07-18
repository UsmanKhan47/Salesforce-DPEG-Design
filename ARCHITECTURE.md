# DPEG — Application Architecture

This document is the source of truth for **how the DPEG application is shaped**: domain model, Apex layering, integration boundaries, and LWC/UI patterns. It is separate from `CLAUDE.md` (which governs agent orchestration) and from `.claude/rules/` (which enforces _how_ metadata is generated).

**Client:** Dhanani Private Equity Group (DPEG) — Private equity group managing commercial real estate acquisitions, transactions, dispositions, investor relations and property management.

**Prepared by:** Avanza Solutions

**Audience:** Human contributors + Claude subagents (auto-loaded into `CLAUDE.md` via `@ARCHITECTURE.md`).

**API Version:** 67.0 (authoritative: `sfdx-project.json` → `sourceApiVersion`, which matches the org's own API version — verify with `sf org display`).

> ⚠️ **The repo is deliberately mixed-version. This is not an oversight — do not "fix" it.**
>
> | Metadata | Version | Status |
> | --- | --- | --- |
> | Apex classes, triggers, Flows, VF pages/components | **67.0** | Uplifted. Matches the org. |
> | **LWC (`.js-meta.xml`)** | **62.0 / 59.0** | ⚠️ **Intentionally held back.** |
>
> LWC `apiVersion` gates rendering behaviour (shadow DOM). This repo has **no Jest suite** — it is stood up from zero in Phase 8 — and `RunLocalTests` covers Apex only, so bumping the 82 LWC bundles today would ship a rendering-behaviour change with **zero automated verification** (10 of them span seven releases, 59.0 → 67.0). The LWC uplift is therefore split into its own PR, gated on Phase 8 delivering the Jest net. Until then, **leave LWC `apiVersion` values alone.**

**Reference document:** `docs/DPEG_Technical_Solution_Design_v1.3.docx`

---

## 0. System Overview

DPEG's Salesforce platform follows a **hub-and-spoke integration model**. Salesforce CRM acts as the central hub. External systems connect as spokes through the **Avanza Service Bus (ASB)** — Avanza's managed middleware and ETL platform. Salesforce is a read/display layer for external operational data — **no write-back to Yardi or Procore or any other external system**. Financial flows (contributions and distributions) run through Plaid's universal bank integration layer, also orchestrated via ASB.

---

## 1. Domain / Data Model

> ### ⚠️ §1 was amended 2026-07-15 — a deliberate, evidenced reversal. Read this before citing §1.
>
> **This program's standing rule is "code bends to the doc." §1 is a scoped exception to that rule.** An audit of all 463 custom fields across the 33 custom objects found that several rules below were not merely *unmet* — they were **self-contradictory or unfalsifiable as written**, and could not be conformed to at any price.
>
> **The decisive evidence:** conformance across the 463 fields measured **19.0% or 92.7% depending only on how the field-naming rule was read.** The schema was identical under both readings. The literal reading condemned 369 of 463 fields, and satisfying it would have cost roughly 2,300 file edits to produce names like `NOI_Amount__c` and `Rent_PSF_Amount__c`. Meanwhile §1's own eight examples were counter-examples to the rule they illustrated — the doc broke its own rule in the same table that stated it. Fixing the sentence retired ~341 of 375 "violations" at a cost of zero org changes.
>
> **Amended:** object naming, field naming, boolean, currency, relationship, status. **Added:** rule 9, type-suffix discipline. **Replaced:** examples referencing `Investment__c` / `Investor__c` / `ACH_Status__c` — the IR module was never built, so §1 illustrated a data model nobody could find. Examples are now real fields in this org unless marked _(proposed)_; see the note under _Naming Conventions_.
>
> **Formerly "not amended — a rule that was merely unmet stays unmet." ✅ NOW RESOLVED — the repair ran 2026-07-17/18 on DPEG-Acq-5, deployed and verified (RunLocalTests green), commits `319d7e9`→`35c6cf5`.** All items below are fixed; retained here as the record of what changed and why.
>
> - **Rule 2 — ✅ done.** `Days_on_Market__c`→`Days_On_Market__c` (Disposition), `Projected_Value_at_Peak__c`→`Projected_Value_At_Peak__c` (Property_Asset), `Cash_on_Cash_Return__c`→`Cash_On_Cash_Return__c` (Underwriting **and** the Opportunity twin the original list missed). **Finding:** in-place case-only re-casing is a **Metadata-API no-op** — the API diffs field API names case-insensitively, so the change is invisible and old/new can't coexist. The only mechanism is destructive **delete-and-recreate**; all four had 0 stored rows, so no data was lost. Apex/FlexiPage references block deletion by field-ID (not name), so blocked fields needed a remove-refs→delete→recreate→re-add-refs pass.
> - **Rule 6 — ✅ done (earlier phase).** All 8 `_Date`-suffixed DateTime fields already migrated to `..._DateTime__c` before this program; verified absent.
> - **Rule 4 — ✅ done.** `Untouched__c`→`Is_Untouched__c` (WO), `Non_Responsive__c`→`Is_Non_Responsive__c` (Lease_Renewal) were **formula** checkboxes (no data, additive rename); `Past_Target__c`→`Is_Past_Target__c` (Onboarding), `Never_Expires__c`→`Is_Non_Expiring__c` (NDA), `Renewal_Option__c`→`Has_Renewal_Option__c` (Lease_Renewal), `Earnest_At_Risk__c`→`Is_Earnest_At_Risk__c`, `Wire_Approval_Due__c`→`Is_Wire_Approval_Due__c` (Transaction) were **stored** checkboxes (backfilled `new=old` per record before retire).
> - **Rule 9 (Unit) — ✅ done (earlier phase).** `Unit__c` Text→`Unit_Label__c` on `Lease_Renewal__c`/`Work_Order__c`; `Rent_Step__c.Unit__c` remains the real MasterDetail.
> - **Rule 9 (formula) — ✅ done.** `Is_Ready__c`→`Readiness_Score__c` (Property_Asset); `Occupied_Flag__c`→**`Occupied_Pct__c`** (Unit) — renamed to `_Pct__c`, **not** `_Count__c`, because the formula returns 100/0 (a percentage the occupancy report averages), which a "Count" name would misdescribe.
> - **Rule 9 (scalar-in-Text) — ✅ done.** `Lease_Inquiry__c.Lease_Term__c`→`Lease_Term_Months__c` and `Free_Rent__c`→`Free_Rent_Months__c` (Text→Number, months-canonical, parse-backfill: `'7 years'`→84, `'N months'`→N, bare→months; 0 unparseable). An **active pathAssistant** referenced these as key fields — pathAssistants (like reports/dashboards) name fields directly and block/silently-break on deletion; repointed before retire.
>
> ~123 `<fieldPermissions>` stubs for these now-deleted fields remain in `profiles/*.profile-meta.xml`, but profiles are `.forceignore`d (never deploy) — harmless; a bulk profile-stub sweep is the one remaining tidy-up.
>
> **Known-good exceptions, deliberately not "fixed":** `Lease_Inquiry__c.Base_Rent__c` / `.TI_Allowance__c` and `Lease_Renewal__c.Current_Rent__c` are **Text on purpose** — they hold quoted deal terms like `'$34.00 / sq ft NNN'`. Currency cannot carry the NNN qualifier, and NNN-vs-gross changes the economics entirely. Do not "correct" these to Currency. `Lease_Renewal__c` already pairs `Current_Rent__c` (Text display term) with `Proposed_Rate__c` (Number, computable) — that split is the intended pattern.

### Naming Conventions

Every example below is a **real field or object in this org** — verified against the metadata 2026-07-15 — unless it is marked _(proposed)_, meaning a name scheduled as a fix target, or is explicitly shown as a counter-example of what **not** to do. The old §1 failed this test: it illustrated its rules with `Investment__c` / `Investor__c` / `ACH_Status__c`, none of which exist. An example nobody can find teaches nothing.

| Element                                      | Convention                                                                                                                                                                                | Example                                                                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| **1.** Custom object API name                | `Title_Case_With_Underscores`, no prefix. Single-word objects carry no underscore.                                                                                                         | `Lease_Inquiry__c`, `Work_Order__c`, `Transaction__c`                                 |
| **2.** Custom field API name                 | `Title_Case_With_Underscores`, descriptive. Every underscore-separated segment begins with an uppercase letter or a digit. Acronyms stay fully uppercase.                                  | `Offer_Price__c`, `Ball_In_Court__c`, `LOI_Status__c`, `NOI__c`                       |
| **3.** Relationship fields (Lookup / MD)     | Suffix with the related object, singular — for a single lookup the field name **is** the target object's name. **Exception:** role-named lookups to `User` / `Contact` take the role name.  | `Property__c`, `Lease_Inquiry__c`; roles: `Requested_By__c`, `Approved_By__c`, `Handling_Person__c`, `Broker__c` |
| **4.** Boolean fields                        | Prefix `Is_` or `Has_`, **or** `<Subject>_<PastParticiple>`. No other form is permitted.                                                                                                   | `Is_Open__c`, `Is_Escalation__c`, `LOI_Signed__c`, `PSA_Executed__c`, `SLA_Breached__c` |
| **5.** Currency fields                       | The name must make the **unit** unambiguous. See rule 5 below.                                                                                                                             | `Offer_Amount__c`, `Rent_PSF__c`, `Monthly_Rent__c`, `Annual_NOI__c`                  |
| **6.** Date fields                           | Suffix `Date` for date-only, `DateTime` for date+time. **Never** suffix a DateTime field with `Date`.                                                                                      | `Closing_Date__c`, `Verified_DateTime__c`                                             |
| **7.** Status fields                         | A field expressing a record's current state → suffix `Status__c`. A lifecycle field that drives a Path → `Stage__c`. Other picklists are **not** status fields.                            | `LOI_Status__c`, `Offer_Status__c`, `Stage__c`                                        |
| **8.** Masked display formula fields         | Suffix `_Masked__c`.                                                                                                                                                                      | `SSN_Masked__c` _(proposed)_ — **dormant rule**: zero masked fields exist; IR module unbuilt |
| **9.** Type-suffix discipline                | A field's name must not imply a type it does not have. See rule 9 below.                                                                                                                   | `Verified_DateTime__c`; `Unit_Label__c`, `Readiness_Score__c` |

**No team-wide field prefix in use.** Field API names are unprefixed past `__c`.

#### Rule 3 — why role-named lookups are exempt

The base rule ("the field name is the target object name") is **impossible to follow** for any object needing two lookups to the same target: API names must be unique on an object, so a second `User__c` cannot exist. It also produces worse names — `Requested_By_User__c` says less than `Requested_By__c`, because *who did this* is the useful fact, not *which object it points at*. All 10 relationship fields that "violated" the old rule were role-named lookups to `User` / `Contact`; they are correct and are now the documented convention.

#### Rule 5 — Currency naming (unit must be explicit)

The old rule ("suffix with `Amount`") was applied to the Currency **type**, which demanded `NOI_Amount__c`, `Rent_PSF_Amount__c`, `NNN_Property_Tax_Amount__c` — 46 of 50 Currency fields "violated" it, and complying would have made every name worse. The intent was *amount fields* (a semantic class), not *all Currency fields*. The real failure mode is an ambiguous **unit**, so that is what this rule now governs:

| Money field is… | Name it | Example |
| --- | --- | --- |
| a total sum with no established domain term | suffix `Amount` | `Offer_Amount__c`, `Confirmed_Wire_Amount__c`, `BOV_Amount__c` |
| a per-unit rate | suffix the unit | `Rent_PSF__c`, `Market_Rent_PSF__c` |
| a periodic amount | name the period | `Monthly_Rent__c`, `Annual_NOI__c` |
| an established CRE / finance term | keep the industry name | `NOI__c`, `Balance__c`, `Earnest_Money__c`, `*_Price__c`, `*_Cost__c` |

**Prohibited:** a bare money noun with no unit and no period — `Rent__c`, `Cost__c`, `Fee__c`. A renamed `NOI_Amount__c` is *less* legible to a CRE analyst than `NOI__c`; industry terms win over the suffix.

#### Rule 9 — Type-suffix discipline (new)

**This is the only rule in §1 that prevents future defects rather than reclassifying past ones.** Every type-vs-name trap found in the 2026-07-15 audit came from the *absence* of this rule, not from breaking an existing one.

Where a name is ambiguous about its type, the suffix resolves it:

| Suffix | Required for | Example |
| --- | --- | --- |
| `_DateTime__c` | DateTime fields | `Verified_DateTime__c` |
| `_Date__c` | Date (date-only) fields | `Closing_Date__c` |
| `_Label__c` / `_Name__c` | Text carrying a human label for something that also exists as a record | `Property_Name__c`, `Unit_Label__c` |
| `_Score__c` / `_Count__c` / `_Pct__c` | Number fields whose name would otherwise read Boolean or categorical | `Tasks_Open__c`, `Completion_Pct__c`, `Readiness_Score__c`, `Occupied_Pct__c` |
| `_Masked__c` | masked display formula | `SSN_Masked__c` _(proposed)_ |

**Hard prohibitions:**

1. **A Text or Number field must never be named identically to a custom object.** Rule 3 reserves that exact name for a lookup to that object, so such a field is camouflaged as a relationship by the convention itself. This produced the worst defect in the original audit: `Unit__c` was **MasterDetail** on `Rent_Step__c` but **Text** on `Lease_Renewal__c` and `Work_Order__c` — `Unit__r.Name` failing to compile, `Unit__c = unitId` silently storing an Id in a string. **✅ Fixed:** the two Text instances are now `Unit_Label__c`; `Rent_Step__c.Unit__c` remains the real MasterDetail.
2. **A field name must not assert a type the field does not have.** `Package_Sent__c` is a Date named like a past-participle boolean (still open — not in the §1 repair scope). **✅ Fixed in the §1 repair:** `Is_Ready__c` (a Number wearing rule 4's Boolean marker) → `Readiness_Score__c`; `Wire_Approval_Due__c` (a Checkbox) → `Is_Wire_Approval_Due__c`.
3. **A scalar quantity must not be stored as Text.** Text with no validation drifts: `Lease_Term__c` used to hold both `'7 years'` (seed scripts) and `'60'` (TestDataFactory) — two incompatible unit conventions in one field. **✅ Fixed:** now `Lease_Term_Months__c` (Number, months-canonical); this was never hypothetical.

Exception to (3): a field holding a **quoted deal term** whose qualifier a typed field cannot carry (`'$34.00 / sq ft NNN'`) is legitimately Text — but it must say so in its `<description>`, and any computable counterpart belongs in a separate typed field (see `Current_Rent__c` / `Proposed_Rate__c`).

### Current objects

33 custom objects. Grouped by the module that owns them. `Parent (lookup)` is the object's own relationship graph and is authoritative. Per §6, **add a row here whenever a custom object is created.**

A `—` in _Purpose_ means the object's `<description>` in its `.object-meta.xml` is unset. **22 of 33 are unset** — verified against the filesystem 2026-07-15; the previous count of 21 was wrong against every measure. Where a description exists it is the authoritative source and is condensed here.

**†** marks a row that carries _Purpose_ prose despite the object having **no `<description>`**. That text is **authored inference, not condensed source** — do not cite it as authoritative; write the `<description>` and then condense it here. The arithmetic reconciles: 20 dashed rows + 2 inferred rows (†) = the 22 unset.

**Acquisitions** — the deal tree, rooted on `Opportunity` / `Property__c`

| Object                               | Parent (lookup)                                   | Purpose                                                                                             |
| ------------------------------------ | ------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `Property__c` **†**                  | — (graph root)                                    | The acquisition target. Created on lead conversion by `LeadConvertService`.                          |
| `LOI__c`                             | `Opportunity`, `Property__c`                      | —                                                                                                     |
| `Counter_Offer__c`                   | `LOI__c`                                          | —                                                                                                     |
| `Underwriting__c`                    | `Opportunity`                                     | —                                                                                                     |
| `Development_Feasibility_Review__c`  | `Opportunity`, `Property__c`                      | —                                                                                                     |
| `Construction_Feasibility_Review__c` | `Opportunity`, `Property__c`                      | —                                                                                                     |
| `Contract_Review__c`                 | `Opportunity`                                     | —                                                                                                     |
| `PSA_Version__c`                     | `Contract_Review__c`                              | One PSA draft/counter exchanged during negotiation; the full set is the version history.             |
| `Deal_Message__c`                    | `LOI__c`, `Underwriting__c`, `Contract_Review__c` | Append-only logged communication in a deal negotiation. Child of exactly one of the three parents.   |
| `Offering__c`                        | `Opportunity`                                     | —                                                                                                     |
| `NDA__c` **†**                       | `Opportunity`, `Disposition__c`                   | Spans Acquisitions **and** Disposition.                                                              |

**Transactions**

| Object            | Parent (lookup)              | Purpose                                                                                                                 |
| ----------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `Transaction__c`  | `Opportunity`, `Property__c` | —                                                                                                                        |
| `Critical_Date__c`| `Transaction__c`             | One upcoming critical deadline (Closing, Feasibility End, Insurance Binding, Loan Commitment, Earnest Money).            |

**Disposition**

| Object                 | Parent (lookup)     | Purpose |
| ---------------------- | ------------------- | ------- |
| `Disposition__c`       | `Property_Asset__c` | —       |
| `Disposition_Offer__c` | `Disposition__c`    | —       |
| `BOV_Submission__c`    | `Disposition__c`    | —       |
| `Broker_Listing__c`    | `Disposition__c`    | —       |
| `Wire__c`              | `Disposition__c`    | —       |

**Property Management** — rooted on `Property__c` → `Property_Asset__c`

| Object                   | Parent (lookup)                   | Purpose                                                                                                     |
| ------------------------ | --------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `Property_Asset__c`      | `Property__c`                     | —                                                                                                            |
| `Unit__c`                | `Property_Asset__c`               | —                                                                                                            |
| `Rent_Step__c`           | `Unit__c`                         | —                                                                                                            |
| `Onboarding__c`          | `Property_Asset__c`               | —                                                                                                            |
| `CAM_Reconciliation__c`  | `Property_Asset__c`               | —                                                                                                            |
| `Delinquency__c`         | `Property_Asset__c`               | —                                                                                                            |
| `Insurance_Policy__c`    | `Property_Asset__c`               | —                                                                                                            |
| `Broker_Assignment__c`   | `Property_Asset__c`, `Contact`    | One broker-to-property listing assignment. Never deleted; closing a listing changes Status.                  |
| `Lease_Inquiry__c`       | `Property_Asset__c`, `Contact`    | One leasing inquiry from a broker-introduced prospect, inquiry → signed lease. Never deleted.                |
| `Lease_Activity__c`      | `Lease_Inquiry__c`                | Append-only negotiation log entry. Never edited or deleted.                                                  |
| `Lease__c`               | `Lease_Inquiry__c`                | The lease document worked by legal, created from a Lease Inquiry once drafting begins.                       |
| `Lease_Renewal__c`       | `Property_Asset__c`               | One renewal conversation, Yardi-flagged expiry → signed amendment or lost tenant. Never deleted.             |
| `Renewal_Activity__c`    | `Lease_Renewal__c`                | Append-only timeline entry. Never edited or deleted.                                                         |
| `Work_Order__c`          | `Property_Asset__c`               | Maintenance work order mirrored **read-only** from Yardi. No write-back except the Delay Reason flag.        |
| `Work_Order_Activity__c` | `Work_Order__c`                   | Read-only status/activity history from the Yardi sync. Never edited in Salesforce.                           |

## 2. Apex Layering

DPEG follows the **Service / Selector / Domain / Trigger-handler** separation. Canonical templates exist in `.claude/skills/sf-apex/assets/` — reuse them rather than hand-rolling.

### Scope: team-owned classes only

The layering contract and the **90%+ coverage target apply to team-owned classes only.** Salesforce-generated Site/Communities boilerplate is **exempt**.

**The 10 exempt classes** (and their generated `*Test` counterparts):

`MicrobatchSelfRegController`, `ForgotPasswordController`, `ChangePasswordController`, `SiteRegisterController`, `SiteLoginController`, `CommunitiesSelfRegConfirmController`, `CommunitiesSelfRegController`, `CommunitiesLandingController`, `CommunitiesLoginController`, `MyProfilePageController`

**Rationale:** the platform generates these classes and **may regenerate them at any time — the team does not own them.** Refactoring them into Selector/Domain, or writing tests to reach 90% on Salesforce's own code, churns code the platform can overwrite.

This is observable, not theoretical: the platform generated these classes at **the org's** API version, not the project's — they were already at 67.0 while the rest of the codebase was still at 62.0. Expect them to be silently rewritten at the org's version again.

**Scope of the exemption:** it covers **layering and coverage only.** It is *not* a carve-out from project-wide settings such as `apiVersion` — these classes sit at 67.0 like all other Apex, and are deployed and versioned normally.

### Layer Responsibilities

| Layer                               | File pattern                 | Responsibility                                                                              |
| ----------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------- |
| **Trigger**                         | `<Object>Trigger.trigger`    | Thin — delegates to a handler only. No logic.                                               |
| **Trigger Handler**                 | `<Object>TriggerHandler.cls` | Routes `before/after insert/update/delete/undelete` to domain methods. Bulk-safe.           |
| **Domain**                          | `<Object>Domain.cls`         | Per-object business rules and state transitions. Operates on collections (`List<SObject>`). |
| **Service**                         | `<Feature>Service.cls`       | Cross-object orchestration, transactional workflows, invoked from LWC/Flow/Trigger.         |
| **Selector**                        | `<Object>Selector.cls`       | All SOQL for that object. Nothing else queries it. Uses `WITH USER_MODE`.                   |
| **DTO**                             | `<Feature>DTO.cls`           | Structured input/output for REST endpoints and LWC `@AuraEnabled` methods.                  |
| **Batch / Queueable / Schedulable** | `<Feature>Batch.cls` etc.    | Async processing. One job class per feature.                                                |

### Standards (Non-Negotiable)

- **Sharing:** `with sharing` on every service, selector, domain, and controller class. `without sharing` only with written justification in the class header Javadoc.
- **SOQL:** always in a selector. Use `WITH USER_MODE`. Never inline SOQL inside service or domain classes.
- **Bulkification:** every public method accepts collections, not single records. No SOQL/DML inside loops. Bulk tests insert 251+ records.
- **Callouts:** all ASB/Plaid callouts wrapped in a dedicated service class (`PlaidCalloutService`) so they can be mocked via `HttpCalloutMock`. all other callouts will use ASB.
- **Error handling at LWC boundary:** `@AuraEnabled` methods throw `AuraHandledException` with user-safe messages.
- **Test data:** always use `TestDataFactory` (`force-app/main/default/classes/TestDataFactory.cls` — **it exists and is the org-wide factory**; do not stand up a competing per-feature factory). Never `@isTest(SeeAllData=true)`.
- **Coverage target:** 90%+ per class, **team-owned classes only** (see _Scope_ above).

### Key Apex Services

The 7 services currently in `force-app/main/default/classes/`. Per §6, **add a row here whenever a new Apex service is introduced.**

| Service                       | Invoked from                                       | Responsibility                                                                                                                                          |
| ----------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LeadConvertService`          | `LeadConvertTrigger`                               | Lead conversion: carries Deal Type onto the Opportunity and sets the matching record type (Land/Commercial); stamps Lead Approved By; creates the `Property__c` and links it to the Opportunity. |
| `OpportunityReviewService`    | `OpportunityReviewTrigger`                         | Creates review children (Development / Construction / Contract Review) on stage entry or an Input-Needed flip. Idempotent — never a second review of one type. |
| `ContractExecutionService`    | `ContractReviewTrigger`                            | PSA execution handoff: stamps the Opportunity (Contract Signed, Day 0), creates the `Transaction__c` (idempotent), notifies Transactions / IR / Due Diligence. |
| `TaskFanoutService`           | `Transaction_Task_Fanout` Flow (`@InvocableMethod`) | Day-0 fan-out: creates the ~75-task Transaction checklist from `Task_Group_Def__mdt` + `Transaction_Task_Def__mdt`.                                      |
| `TaskRollupService`           | `TaskRollupTrigger`                                | Rolls completed/overdue Task counts up to `Transaction__c` — drives the "N / 75" highlights tile.                                                        |
| `OnboardingTaskRollupService` | Onboarding checklist Tasks                         | Recomputes `Onboarding__c` checklist rollups (total / complete / overdue / stalled / completion %).                                                      |
| `ApprovalAuditService`        | after-save Flow (`@InvocableMethod`)               | Stamps approver identity and date from `ProcessInstanceStep` onto the Underwriting / LOI gates. `without sharing`.                                       |

### Reference Implementations

- Selector pattern: `.claude/skills/sf-apex/references/AccountSelector.cls`
- Service pattern: `.claude/skills/sf-apex/references/AccountService.cls`
- Batch pattern: `.claude/skills/sf-apex/references/AccountDeduplicationBatch.cls`
- Test factory: `force-app/main/default/classes/TestDataFactory.cls` — **exists; the org-wide test-data factory. Use it.**
- Test guidance: `.claude/skills/sf-apex-test/references/{assertion-patterns,mocking-patterns,async-testing,test-data-factory}.md`

**Referenced skills:** `.claude/skills/sf-apex/`, `.claude/skills/sf-apex-test/`, `.claude/skills/trigger-refactor-pipeline/`.

---

## 3. Integration Architecture

### 3.1 Avanza Service Bus (ASB) — Central Integration Hub

**All external integrations route through ASB. No direct peer-to-peer integrations between Salesforce and external systems.**

Salesforce holds a **single Named Credential pointing to the ASB endpoint only** — not to Plaid, Yardi, CoStar, or any external system directly. All external API credentials (Yardi, Plaid, CoStar, Placer.ai) are stored in ASB's secrets vault.

### 3.2 Named Credentials Policy

All external API credentials stored in Named Credentials (or ASB secrets vault for external-system credentials). Never in custom fields, custom metadata, or hardcoded Apex. Named Credentials are:

- Not visible in the UI — only accessible to Apex callouts
- Managed by System Administrators only
- Rotatable without code changes
- Audited in Setup Audit Trail

---

## 4. Experience Cloud Portal (Investor Portal)

- OWD Private on all financial objects — investors access only their own records
- Experience Cloud profile restricts object and field access to investor-relevant data only
- Salesforce Files served via `ContentDocumentLink` — investors can only download files linked to their Account or Investment records
- Session timeout: 2 hours (configurable); re-authentication required after timeout
- Field History Tracking enabled on all financial state-change fields

**IR portal features:** My Investments, My Distributions, My Documents (K-1, reports, statements), Bank Account Linking (Plaid Link component), Commitment portal form, Share Transfer notification

**Portal user type:** Authenticated Experience Cloud user; provisioned automatically on Investor\_\_c creation (Conversion 7)

---

## 5. LWC / UI Architecture

> ⚠️ **LWC `apiVersion` is intentionally behind the rest of the repo (62.0 / 59.0 vs 67.0).** Do not bump it as a drive-by cleanup — see the mixed-version table at the top of this document. The uplift is its own PR, gated on the Phase 8 Jest net, because LWC `apiVersion` gates rendering behaviour and there is currently no automated test that would catch a regression.

### Component Hierarchy

- **Pages** (FlexiPages) assemble features; minimal markup.
- **Feature components** (`lwc/<feature>*/`) coordinate data + child UI. Hold state, wire Apex/LDS, dispatch events.
- **Presentational components** are stateless — props in, events out. No Apex calls.
- **Shared utilities** live in `lwc/utils*` (lowerCamelCase JS modules, no `.html`).

### Data Access Priority

1. **LDS wire adapters** (`lightning/uiRecordApi`, `getRecord`, `getRelatedListRecords`) for single-record reads/writes.
2. **LDS GraphQL** (`lightning/uiGraphQLApi`) for structured multi-object reads.
3. **Imperative Apex** only when LDS cannot express the query (complex joins, aggregates, Plaid callout results). Controllers must be thin wrappers around a Service class.

### Error Handling

- Apex methods throw `AuraHandledException` (never raw exceptions).
- LWC catches, displays user-safe message via toast (`lightning/platformShowToastEvent`).

### Styling

- **SLDS 2** is the target design system. Use design tokens (`--slds-g-*`), not hardcoded colours/spacing.
- Run the SLDS linter before deploying any LWC. Migration/uplift: `.claude/skills/uplifting-components-to-slds2/`.

### Testing

- Jest tests required for every LWC (`__tests__/<component>.test.js`).
- Accessibility tests via `@sa11y/jest` matchers.

**Referenced skills:** `.claude/skills/sf-fragment/`, `.claude/skills/sf-flexipage/`, `.claude/skills/uplifting-components-to-slds2/`.

---

## 6. Keeping This Document Current

- When a subagent (design / developer / admin) establishes a new convention, update the relevant section here **in the same PR**.
- When a custom object is added, populate its entry under **§1 → _Current objects_**.
- When an external integration is wired, document it under **§3 Integration Architecture**.
- When a new Apex service is introduced, add it to the **§2 → _Key Apex Services_** table.
- Breaking changes to these conventions require updating `.claude/agents/*.md` to match.
