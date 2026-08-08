# DPEG — Application Architecture

This document is the source of truth for **how the DPEG application is shaped**: domain model, Apex layering, integration boundaries, and LWC/UI patterns. It is separate from `CLAUDE.md` (which governs agent orchestration) and from `.claude/rules/` (which enforces _how_ metadata is generated).

**Client:** Dhanani Private Equity Group (DPEG) — Private equity group managing commercial real estate acquisitions, transactions, dispositions, investor relations and property management.

**Prepared by:** Avanza Solutions

**Audience:** Human contributors + Claude subagents (auto-loaded into `CLAUDE.md` via `@ARCHITECTURE.md`).

**API Version:** 67.0 (authoritative: `sfdx-project.json` → `sourceApiVersion`, which matches the org's own API version — verify with `sf org display`).

> ✅ **The repo is now uniformly 67.0 — the mixed-version state is resolved (2026-07-18).**
>
> | Metadata | Version | Status |
> | --- | --- | --- |
> | Apex classes, triggers, Flows, VF pages/components | **67.0** | Uplifted. Matches the org. |
> | **LWC (`.js-meta.xml`)** | **67.0** | ✅ Uplifted 2026-07-18 (commit `949e710`), once Phase 8 delivered the Jest net. |
>
> The LWC uplift was gated on Phase 8 because `apiVersion` governs shadow-DOM rendering and `RunLocalTests` is Apex-only. **Phase 8 landed the Jest net (82 suites / 439 tests), so the 82 bundles were bumped 59.0/62.0 → 67.0 and verified against that net (still 82/439 green) before deploying to the org.** **One deliberate exception remains:** `lwc/leaseNegotiationLog` was left at 62.0 because it is mid-flight in an active feature — bump it when that feature merges. Otherwise, LWC now matches the rest of the repo.

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

**Lead Intake / Broker Protection** — race-safe inbound email→Lead claim ledger, rooted on `Lead` rather than the Opportunity/Property deal tree (added 2026-07-24, see `docs/2026-07-24-broker-protection.md`)

| Object                          | Parent (lookup)                                      | Purpose                                                                                                                          |
| -------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `Property_Registry__c`           | `Lead` (`Winning_Lead__c`)                            | Backend-only claim ledger. One row per distinct property; the unique, case-insensitive `Property_Key__c` enforces race-safe first-come-first-served registration at the database level. |
| `Competing_Broker_Submission__c` | `Lead` (`Winning_Lead__c`, `Source_Lead__c`), `Opportunity` (`Winning_Opportunity__c`) | Append-only audit trail of every inbound broker email that matched a property, including the winning submission itself. Deliberately not master-detail — cascade delete would silently wipe this trail. **The lookups are not symmetric (2026-07-31):** `Source_Lead__c` is null BY DESIGN on a competing broker's row — they no longer receive a Lead, so this row plus `Broker_Email__c` is the only record of their claim. Only the winner's own row carries a source Lead. Every Lead lookup is `SetNull`, so deleting the winner's Lead can null both; `CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail` filters wholly unanchored rows out to keep the property re-claimable via orphan adoption. **⚠ THE WINNER ANCHOR IS SPLIT ACROSS TWO FIELDS (2026-08-03) — EXACTLY ONE IS POPULATED, NEVER BOTH, NEVER NEITHER.** `Winning_Lead__c` while the winning Lead is open; `Winning_Opportunity__c` once it has been converted, with BOTH Lead lookups null. This is a platform constraint, not a preference: **at runtime a Lead lookup cannot be SET to a converted Lead**, so a repeat or competing submission arriving after the winner converted threw a `DmlException` and cost the email its audit row and its Task target (production incident, staging row `a0aiw000000OCckAAG`). ⚠ Two caveats, both established 2026-08-03: the exact `StatusCode` was **never captured** (`Error__c` was null — the gap the same change closes), so the cause is established by elimination rather than by a captured message; and **the restriction is not enforced inside `@isTest`**, where the identical insert succeeds — so no Apex test in this org can falsify it, and `PropertyClaimServiceTest.platform_lookupToAConvertedLead_isNotEnforcedInTestContext` pins that quirk instead. The `Winning_Lead_Required` VR is now `AND(ISNEW(), ISBLANK(Winning_Lead__c), ISBLANK(Winning_Opportunity__c))`. **Any reader of this object must read BOTH anchors** — filtering or routing on `Winning_Lead__c` alone silently re-files a winning broker's own follow-ups as competing claims against themselves. Known open: `selectByWinningLead` (the LWC read path) is still Lead-only, so a converted winner's trail has no UI surface. |
| `Property_Claim_Lock__c`         | — (no lookup; concurrency partition, not a business object) | Pessimistic-lock partition object: one row per coarse address cluster, `FOR UPDATE`-locked to serialize concurrent same-property claims so the fuzzy match-then-insert is atomic. |
| `Inbound_Email_Staging__c`       | — (no lookup; `Result_Record_Id__c` is a plain Text pointer) | Durable landing record for every inbound broker email (added 2026-07-28). Written synchronously by `EmailToLeadHandler` BEFORE any Lead exists, so the raw body and every RFC header survive independently of routing. Deliberately not a lookup to Lead — the routing tree may resolve to a Lead, an Opportunity, a Contact, or nothing at all. Terminal state (`Status__c`, `Outcome__c`, `Result_Record_Id__c`, `Processed_DateTime__c`, `Error__c`) makes it both the pipeline's audit trail and its restart point. **Extended 2026-08-06 (file pipeline):** it also carries the attachment BYTE CARRIER — classic `Attachment` rows parented to it — and `Attachment_Status__c`, a SECOND, independent state machine (None / Pending / Saved / Partial / Failed / Not Saved / Expired) that is `AttachmentCarrierSweepBatch`'s WORK QUEUE, which is why it is a picklist rather than a line in the notes field. ⚠ Its **Notes & Attachments related list is load-bearing, not decoration** — it is where a human recovers the bytes of a file that never converted. **Extended 2026-08-08 (routing resilience):** `Status__c` gained a FOURTH value, **`Failed`**, and a new `Routing_Attempt_Count__c` Number(2,0) — together they make `Status__c` a WORK QUEUE too, for `RoutingRetrySweepBatch`. 🔴 **`Failed` and `Error` are NOT synonyms and must never be filtered, reported or retried as one**: `Failed` is written only by `RoutingFailureFinalizer` on `UNHANDLED_EXCEPTION`, which SP-5 proved means the transaction rolled back and committed NOTHING, so it is safely replayable; `Error` means the catch ran and work MAY have committed, so replaying one can mint a second Lead or corrupt the adjudication trail. The row therefore now carries **TWO independent state machines plus a counter** — `Status__c` (routing) and `Attachment_Status__c` (files) — and they are COUPLED in one direction: while routing reads `Pending` or `Failed`, `AttachmentCarrierSweepBatch` must skip the row entirely. |
| `Content_Publication_Budget__c` **(Custom Setting — NOT one of the 33 custom objects)** | — (hierarchy custom setting; org default only) | **The FIRST Custom Setting in this repo** (added 2026-08-06). Holds the file pipeline's daily publication counter and circuit-breaker state (`Publication_Count__c`, `Window_Start_DateTime__c`, `Is_Suspended__c`, `Suspended_Until_DateTime__c`). Chosen over a custom object because `getOrgDefaults()` costs **0 SOQL**, so consulting it does not move `AttachmentPersistQueueable`'s pinned query budget. ⚠ **Custom-setting DATA is not deployable** — there is no org-default row in source control and there never will be; `ContentPublicationBudget` creates it at runtime on first use. Only the ORG DEFAULT is ever read; a per-user override would split one org-wide counter into several partial ones. |

**Custom fields on `Task` live on `Activity`, not `Task`.** `Task` and `Event` share one custom-field namespace, so every custom Task field in this repo — including Broker Protection's `Inbound_Message_Id__c` and `Thread_Key__c` (both External Id text) — is defined under `objects/Activity/fields/`. A field file placed under `objects/Task/fields/` is rejected by the Metadata API with the misleading error `Entity Enumeration Or ID: bad value for restricted picklist field: Task`, which then cascades as "Dependent class is invalid" across every Apex class that touches `TaskSelector`. Apex still references the field as `Task.Inbound_Message_Id__c` — only the metadata folder differs.

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
- **SOQL:** always in a selector. Use `WITH USER_MODE`. Never inline SOQL inside service or domain classes. **Exception — AUTOMATION PATHS use `WITH SYSTEM_MODE`** (see below): a read the running user never asked for must not depend on the running user's FLS.
- **Bulkification:** every public method accepts collections, not single records. No SOQL/DML inside loops. Bulk tests insert 251+ records.
- **Callouts:** all ASB/Plaid callouts wrapped in a dedicated service class (`PlaidCalloutService`) so they can be mocked via `HttpCalloutMock`. all other callouts will use ASB.
- **Error handling at LWC boundary:** `@AuraEnabled` methods throw `AuraHandledException` with user-safe messages.
- **Test data:** always use `TestDataFactory` (`force-app/main/default/classes/TestDataFactory.cls` — **it exists and is the org-wide factory**; do not stand up a competing per-feature factory). Never `@isTest(SeeAllData=true)`.
- **Coverage target:** 90%+ per class, **team-owned classes only** (see _Scope_ above).
- **⚠ Permission set metadata deploys REPLACE, not merge, their `<fieldPermissions>` set.** A `PermissionSet` deploy overwrites the org's entire field-permission list for that set with exactly what the file declares — an org-side-only FLS grant that isn't represented in the file **will be silently wiped by the next deploy of that same file**, even one made for an unrelated reason. This bit Broker Protection twice, 2026-08-05 and again 2026-08-06 (`Broker_Protection_Access.permissionset-meta.xml`'s own XML comment carries the full incident writeup): an org-side-only `Task.WhoId` grant, created by hand to unblock the live pipeline, was wiped by a later deploy of the same file made for an unrelated field-casing fix, and every inbound email routing to a Lead or Contact then threw `System.DmlException | Operation failed due to fields being inaccessible on Sobject Task` until the field was declared in-file. **Any FLS grant that matters must be declared IN the permission set file** — "keep it org-side so a redeploy can't disturb it" is exactly backwards. This trap is especially sharp in this repo because `profiles/**` is `.forceignore`d, so a profile-level FLS gap is invisible to any file-based check and the only defensible place to declare a grant is a permission set that is actually in source.

#### `WITH SYSTEM_MODE` — the automation-path exception

`USER_MODE` **throws; it does not degrade.** The instant one selected field is inaccessible to the
running principal, the query raises `System.QueryException: No such column '<field>' on entity
'<object>'` — which is how the platform reports an **FLS denial**, not a missing field. On a read a
human requested that is the right outcome. On a read the platform performs *on the user's behalf* it
is a defect generator: one ungranted custom field breaks an unrelated write, or silently disables an
automation. Every DPEG persona is on `Minimum Access - Salesforce`, which grants no FLS at all, so
this is the default case here rather than an edge case.

A selector method therefore uses `WITH SYSTEM_MODE` — **justified at its own declaration** — when the
read is performed on a principal's behalf rather than at their request.

⚠ **This table records the decisions taken so far; it is NOT a closed list and NOT a conformance
test.** The authoritative inventory is the selector class headers, which is where each justification
actually lives. Do not read an unlisted `SYSTEM_MODE` selector as non-conformant — read its header.
As of 2026-08-08 the repo has **22 `WITH SYSTEM_MODE` queries across 13 selector classes** (up from
20 across 13 on 2026-08-06, which was itself up from 17 across 12: `AttachmentSelector` is new and
contributes two, and `InboundEmailStagingSelector.queryCarrierSweep` was the third). ⚠ **The two
added on 2026-08-08 — `InboundEmailStagingSelector.selectRoutingStateById` and
`.queryRoutingRetrySweep` — take that ONE class to three `SYSTEM_MODE` methods against two
`USER_MODE` ones**, so it is now the sharpest example in the repo of a class where the mode is a
property of the METHOD and never of the class. Read the method, not the class:

| Path | Principal | Selector methods | Why USER_MODE fails there |
| --- | --- | --- | --- |
| **Guest / unauthenticated** | Site guest user | `LeadSelector.GuestReads`, `ContactSelector.GuestReads`, `GroupMemberSelector` | guest has no FLS → Broker-Portal anti-abuse dedup reads throw |
| **Approval audit** | the approver, via `without sharing` `ApprovalAuditService` | `ProcessInstanceStepSelector` | reproduces the original no-`WITH`-clause read of approval history |
| **Notifier automation** | `BrokerPortalNotifier` background path | `NotificationTypeSelector`, `QueueGroupSelector`, `LeadSelector.selectByIdsSystem` | notification dispatch must not depend on the triggering user's FLS |
| **Permission-gate reads** (moved from USER_MODE **2026-08-03**) | the running user, reading their OWN grants | `PermissionSetAssignmentSelector`, `PermissionSetGroupComponentSelector` | a `Minimum Access` persona threw on the very read that decides whether they may act — **the closest prior art to the rollup entry below** |
| **EAC capture pipeline** (2026-08-02) | whichever principal EAC committed under | `TaskSelector.selectByIds`, `TaskSelector.selectThreadAnchorsByAnchorValues`, `EmailMessageSelector`, `EmailMessageRelationSelector` | the queueable dies → guard silently disabled while EAC keeps polluting timelines |
| **Rollup recompute — platform-driven, not user-requested** (2026-08-05) | the acting end user, on whose behalf a **trigger** recomputes | `TaskSelector.selectByTransactionDealIds` (← `TaskRollupService` ← `TaskRollupTrigger`) | **reproduced production failure** — see below |
| **Rollup recompute — prospective** (2026-08-05) | the acting end user; `recalc` is called directly, **no trigger** | `TaskSelector.selectByOnboardingIds` (← `OnboardingTaskRollupService.recalc` ← `OnboardingService.completeTask`) | **nothing today** — inert on the live path; applied for consistency and future callers |
| **Inbound-email file pipeline** (2026-08-05; ⚠ **VENUE CHANGED 2026-08-06 — the old justification is obsolete, not merely re-worded**) | whichever principal the file-job chain runs under, plus the scheduled sweep's own principal — both `Minimum Access` | `ContentVersionSelector.selectByIds`, **`AttachmentSelector.selectMetadataByParentIds`**, **`AttachmentSelector.selectBodiesByIds`** (all ← `AttachmentPersistQueueable` / `AttachmentCarrierSweepBatch`), and **`InboundEmailStagingSelector.queryCarrierSweep`** | ⚠ This row used to read *"a `USER_MODE` throw here destroys the whole broker email"*, because `persist` ran SYNCHRONOUSLY at the email boundary. **That is no longer true and must not be quoted** — the callers are now async transactions that own nothing irreplaceable, so a throw costs a DEFERRED file whose bytes remain on the staging row. The mode is retained on ORDINARY automation-path grounds: `USER_MODE` throws rather than degrades, which would **silently disable file conversion AND the daily retry sweep org-wide** — every email routing correctly while every file quietly failed, forever, with the only signal a failed `AsyncApexJob` nobody watches. The sweep locator is the sharper case: Metadata-API-deployed custom fields arrive with **no** field permissions for ANY profile, System Administrator included, so `Attachment_Status__c` under `USER_MODE` would break the sweep for the very administrator who deployed it. ⚠ Note the mixed modes inside `InboundEmailStagingSelector`: `selectById` and `selectDroppedNotesById` stay `USER_MODE` (they back reads a human's own email pipeline asked for); only the batch locator is `SYSTEM_MODE`. ⚠ **That last sentence was overtaken on 2026-08-08** — the class now holds THREE `SYSTEM_MODE` methods, not one; see the row below. |
| **Inbound-email ROUTING retry** (2026-08-08) | a **Finalizer** running after the routing job has already rolled itself back, under whichever principal the platform executed it as; plus the hourly sweep's own principal — both `Minimum Access` | **`InboundEmailStagingSelector.selectRoutingStateById`** (← `InboundEmailStagingService.markRoutingFailed` ← `RoutingFailureFinalizer`) and **`InboundEmailStagingSelector.queryRoutingRetrySweep`** (← `RoutingRetrySweepBatch.start`) | Both read the brand-new `Routing_Attempt_Count__c`, and a Metadata-API-deployed custom field arrives with **no** field permissions for ANY profile, System Administrator included — so `USER_MODE` would break the failure recorder and the retry engine for the very administrator who deployed them, on day one, silently. The Finalizer case is the sharper of the two and is a **new shape in this table**: its entire job is to report a failure that has already happened, so a `USER_MODE` throw there turns *a failure to record a failure into a second failure*, and the routing row strands on `Pending` exactly as it did before the feature existed. 🔴 **This is also why `Routing_Attempt_Count__c` was deliberately NOT added to `selectById`** (which is `WITH USER_MODE` and is the first thing every inbound email does): doing so would have made every broker email depend on the new field's FLS, i.e. the change made to protect the pipeline would have become its newest single point of failure. ⚠ **AND SHARING IS A SECOND, SEPARATE DECISION HERE — see the paragraph below this table, which these two are the first entries to actually exercise.** `SYSTEM_MODE` alone was NOT enough: `Inbound_Email_Staging__c` is `sharingModel = Private` with no sharing rules and `Broker_Protection_Access` sets `viewAllRecords = false`, while the rows are owned by the Email Service context user (`createStaging` sets no `OwnerId`). Under `with sharing` the sweep locator would have returned only the rows the SCHEDULING user owns — dispatching nothing while `finish()` logged all-zeros, **indistinguishable from a healthy pipeline** — and the counter read would have returned null, so the attempt counter would never increment and the row would be re-dispatched hourly forever. Both queries therefore live in a `private without sharing` inner class, `InboundEmailStagingSelector.RoutingReads`, mirroring `LeadSelector.GuestReads`; the outer selector stays `with sharing` and `selectById` / `selectDroppedNotesById` are untouched. The matching writes live in `InboundEmailStagingService.RoutingWrites` for the same reason (a Private-OWD `update` by a non-owner is refused, and both callers are fail-soft, so the refusal would have been swallowed). 🔴 **One leg is deliberately left open and is closed OPERATIONALLY:** the retried `ExtractAddressQueueable` loads its row through `selectById`, which is `with sharing` and out of scope, so **the schedule must be owned by a principal with View All on this object** — recorded as a deploy gate in `RoutingRetrySweepSchedule`'s header. ⚠ `AttachmentCarrierSweepBatch` / `queryCarrierSweep` carry the **identical pre-existing exposure**, noted in that class's header and queued as its own change. |

**Only the Transaction rollup rests on an observed failure; the Onboarding one does not, and the two
must not be cited as one.** A `Transaction__c` created with `Contract_Executed_Date__c` set ran the
Day-0 fan-out; `TaskFanoutQueueable` inserted its 82 checklist Tasks; `TaskRollupTrigger` fired
after-insert; `TaskRollupService` called `TaskSelector.selectByTransactionDealIds`; and its `USER_MODE`
query threw `No such column 'Transaction_Deal__c' on entity 'Task'` (the field exists — it is an FLS
denial). The exception escaped the trigger as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolled back
all 82 inserts, making the Day-0 checklist unbuildable by any non-admin.**

`selectByOnboardingIds` was moved in the same change but is **inert on today's live path**:
`OnboardingService.completeTask` reads `TaskSelector.selectForOnboardingCompletion` (`USER_MODE`,
selecting the same `Onboarding__c` + `Onboarding_Status__c` custom fields) *before* it calls `recalc`,
so a persona lacking that FLS throws at the first read and never reaches the rollup — and
`selectChecklistByOnboardingId` (also `USER_MODE`) gates the checklist UI the same way. Those two
reads remain the real Onboarding FLS gate and remain `USER_MODE`, correctly: both back reads a human
explicitly asked for. **Onboarding is therefore not "now non-admin-safe."** The move was still worth
making — its former justification ("the sole FLS-bearing standard field here is `ActivityDate`") was
wrong on both counts, ignoring the custom fields in the SELECT and assuming a Standard User profile —
but it buys safety only for a future caller that arrives without a `USER_MODE` read in front of it
(a batch recompute, a Yardi sync, a trigger).

⚠ **`SYSTEM_MODE` bypasses FLS and CRUD ONLY — it does NOT bypass sharing.** That is precisely what
makes this exception safe and why it is not a widening of access: the selector's sharing keyword still
governs record visibility, so `TaskSelector` (`with sharing`, all four methods) returns exactly the
rows the running user could already see. Where a caller genuinely needs to escape sharing too, that is
a **separate, separately justified decision** — `ApprovalAuditService`, `BrokerPortalService`,
`EmailThreadGuardService` and `EmailThreadAdopterService` are `without sharing` for reasons stated in
their own class headers, and `SYSTEM_MODE` neither implies nor grants it.
The exception removes a **field-level failure mode**, nothing else. It is not a licence to reach for
SYSTEM_MODE whenever USER_MODE is inconvenient — a user-initiated read that throws is telling you
about a real provisioning gap, and the fix for that is a permission set.

🔴 **AND THE WARNING ABOVE IS NOT THEORETICAL — IT WAS PAID ON 2026-08-08.** The routing-retry
selector methods were written `WITH SYSTEM_MODE` on a `with sharing` class and reviewed as correct,
and a `Private`-OWD object plus `viewAllRecords = false` would have made the entire retry engine
return zero rows for any scheduling principal but a `View All` one — **failing as silence, which is
the failure mode the feature existed to remove.** The lesson generalises: **whenever a SYSTEM_MODE
automation read is against an object whose OWD is Private and whose rows are owned by a DIFFERENT
principal than the one running the automation, check sharing as a separate question.** The remedy
in this repo is a narrow `private without sharing` inner class holding only that query
(`InboundEmailStagingSelector.RoutingReads`, `InboundEmailStagingService.RoutingWrites`, after
`LeadSelector.GuestReads`) — never `without sharing` on the whole selector, which would silently
widen the reads that legitimately belong to a human.

### Key Apex Services

The 7 services currently in `force-app/main/default/classes/`. Per §6, **add a row here whenever a new Apex service is introduced.**

| Service                       | Invoked from                                       | Responsibility                                                                                                                                          |
| ----------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LeadConvertService`          | `LeadConvertTrigger`                               | Lead conversion: carries Deal Type onto the Opportunity and sets the matching record type (Land/Commercial); stamps Lead Approved By; creates the `Property__c` and links it to the Opportunity. **Extended 2026-08-03 (Conversion Enrichment S1/S2):** it now also carries the LLM-extracted deal-screening field set off the Lead, **split by meaning** — deal-process facts (`Asking_Price__c` ← `Guidance_Price__c`, guidance low/high, `Guidance_Cap_Rate__c`, offer due date, sale process, deal room, listing broker name/email, parse confidence) to the **Opportunity**; physical property facts (SF, NOI, units, occupancy, year built/renovated, lot **acres**, WALT, ADR, zoning, seller entity) to the **`Property__c`** — names the deal and the Property after the property (marketing name → address) rather than after `Lead.Company`, and creates the primary **`Broker` `OpportunityContactRole`** for the converted Contact via **read-then-write** (standard conversion already makes that row with a blank Role, so a blind insert would duplicate the broker and the primary). Three invariants are load-bearing and test-pinned: **2 SOQL / 3 DML per invocation regardless of batch size** (the contact-role write is PARTITIONED into an `isEmpty()`-guarded update + insert rather than one `upsert`, so the worst case is 4 — but conversion always creates the role row, making the ordinary path all-updates and therefore exactly one statement; `upsert` was rejected because its support on this standard junction is unverified and a DML failure inside a Lead after-update trigger takes the whole conversion with it); every restricted-picklist write (`Sale_Process__c`, `Parse_Confidence__c`, `Asset_Type__c`, `OpportunityContactRole.Role`) is **describe-guarded** so one illegal value cannot roll back the all-or-none `update updates` and with it the structural `RecordTypeId`/`Property__c` link; and `Property__c.Lot_Size__c` (square feet, OM-entered) is **never written** — deriving SF from acres is forbidden. Its DML is **system mode** and `Trigger.new` is not FLS-filtered, so a missing FLS grant does **not** block the stamp — it only makes the value invisible to the persona. |
| `LeadConvertActionService`    | `LeadConvertActionController` (Lead "Convert" quick action) | **The ONLY class in the app that runs `Database.convertLead`.** Runs the standard conversion for one or more Leads and returns the new Opportunity Ids index-aligned to the input. Added to this table 2026-08-02 — its absence was a pre-existing §6 gap. Since 2026-08-02 it also (a) applies the `LeadConvertMatchService` decision via `setContactId`/`setAccountId` and (b) sets `setBypassContactDedupeCheck`/`setBypassAccountDedupeCheck` on **every** conversion — see the D4 note below. |
| `LeadConvertMatchService`     | `LeadConvertActionService.convert()`               | **Smart Lead Conversion** (2026-08-02): decides what a conversion should ATTACH to, so a repeat broker reuses their existing Contact + firm Account instead of minting duplicates. Read-only, zero DML, exactly **3 SOQL regardless of N** (lead keys / Contacts by email / Accounts by name) via `LeadSelector` + `ContactSelector` + the new `AccountSelector`. Contact matches on **`Email` alone** and WINS, dictating the Account (a Salesforce constraint); Account-name matching is reachable only when no Contact matched **and** `Company != EmailToLeadService.COMPANY_PLACEHOLDER`. Oldest-wins (`CreatedDate ASC, Id ASC`). **Fails soft**: a denied `USER_MODE` read degrades to no-match (`lastRunDegraded`) so conversion is never worse than before the feature. |
| `OpportunityReviewService`    | `OpportunityReviewTrigger`                         | Creates deal children on stage entry or an Input-Needed flip. Idempotent — never a second child of one type. **The list is SIX, not the three this row used to name:** Development FR, Construction FR, Contract Review (at PSA), Underwriting (at Underwriting), NDA (on insert), and **LOI (at LOI, added 2026-08-05)**. Each insert is paired with a `Primary_<X>__c` stamp on the Opportunity, and for LOI **that stamp is load-bearing, not bookkeeping** — `ApprovalAuditService`'s LOI gate resolves its target through `Primary_LOI__c` and swallows its own failures, so an LOI created without the stamp would silently stamp nothing at the next approval, reproducing the Underwriting-gate defect one stage later. ⚠ **The LOI block alone uses `AccessLevel.SYSTEM_MODE` DML and defers its back-stamp to `LoiPrimaryStampQueueable`; the other five deliberately do neither.** Every other child is created when a DEAL DRIVER moves the stage, and a deal driver has Edit; the LOI stage is the only one entered by the **approval process's own field update**, so that code runs as the APPROVER — read-only on Opportunity and `LOI__c` here — **while the deal is LOCKED by its own approval**. Those are TWO different obstacles and each needed its own fix: `SYSTEM_MODE` lifts CRUD/FLS but **does NOT lift an approval lock**, so the inline back-stamp still threw `ENTITY_IS_LOCKED` after the CRUD fix landed. The LOI insert stays synchronous (`LOI__c` is not the record under approval, so it is not locked and the user sees it immediately); only the `Primary_LOI__c` write is deferred, and it lands because both approval processes set `finalApprovalRecordLock=false`. Do not "harmonize" the six blocks in either direction, and do not inline the stamp back. |
| `ContractExecutionService`    | `ContractReviewTrigger`                            | PSA execution handoff: stamps the Opportunity (Contract Signed, Day 0), creates the `Transaction__c` (idempotent), notifies Transactions / IR / Due Diligence. |
| `TaskFanoutService`           | `Transaction_Task_Fanout` Flow (`@InvocableMethod`) | Day-0 fan-out: creates the ~75-task Transaction checklist from `Task_Group_Def__mdt` + `Transaction_Task_Def__mdt`.                                      |
| `TaskRollupService`           | `TaskRollupTrigger`                                | Rolls completed/overdue Task counts up to `Transaction__c` — drives the "N / 75" highlights tile.                                                        |
| `OnboardingTaskRollupService` | Onboarding checklist Tasks                         | Recomputes `Onboarding__c` checklist rollups (total / complete / overdue / stalled / completion %).                                                      |
| `ApprovalAuditService`        | after-save Flow (`@InvocableMethod`)               | Stamps approver identity and date from `ProcessInstanceStep` onto the Underwriting / LOI gates. `without sharing`. **⚠ ITS TWO CALLING FLOWS MUST DECLARE `<runInMode>SystemModeWithoutSharing</runInMode>` (added 2026-08-05).** An approval-triggered flow runs as **the APPROVER**, and in this org the approving principals are deliberately READ-ONLY on Opportunity (`DPEG Principal PSG` grants Read, not Edit — measured). With `runInMode` absent the flow takes DefaultMode = the running user's context, so the stamp's `update` threw `System.TypeException: DML operation UPDATE not allowed on Opportunity` and — because a `TypeException` is **not** a `DmlException` — escaped the class's own catch and **rolled back the whole approval**, so Nikhil could not approve at all. Two independent fixes were required and both are load-bearing: `runInMode` on `Opportunity_UW_Approved_Notify` + `LOI_Approval_Stamp`, and widening the catch from `DmlException` to `Exception`. 🔴 The widened catch alone would have been WORSE than the bug — the approval would succeed while `UW_Approved_By__c` stayed blank and the `Underwriting__c` child never reached `Approved`, silently. `with sharing`/`without sharing` is irrelevant here: it governs record sharing, never object CRUD. |
| `EmailToLeadService`          | `ExtractAddressQueueable` (routing tree)             | Broker Protection: the only class that inserts **or deletes** a Lead in the inbound email-to-Lead pipeline. Under the staging model (2026-07-28) it exposes a single `createLeadFromExtracted(...)` — the Lead is created ONCE, complete, and only by the routing branch that needs one. The old `createLeadAndEnqueue` / `applyExtractedDetails` insert-then-update pair is gone. **`deleteLead(Id)` was added 2026-07-31** for the lost-race path only: it must be called ONLY on `PropertyClaimService.ClaimOutcome.DUPLICATE_RACE` (never on `UNCLAIMED`, which is a legitimate Lead), and only with an Id this class minted earlier in the same transaction. `PropertyClaimService` now performs no Lead DML at all, so Lead writes in this module are wholly owned here. |
| `InboundEmailStagingService`  | `EmailToLeadHandler`, `ExtractAddressQueueable`      | Broker Protection: the only class that writes `Inbound_Email_Staging__c` — creates the durable landing row synchronously at the email boundary, then stamps its terminal state (Processed / Error, outcome label, routed record Id). Status writes are fail-soft by design. **Extended 2026-08-05 (attachment capture):** `createStaging` additionally stamps `Attachment_Count__c` / `Attachment_Bytes__c` / `Dropped_Attachment_Notes__c` in the SAME insert (zero extra DML), and the new `appendDroppedNote(Id, String)` is a fail-soft read-then-append (1 SOQL + 1 DML) used **on the failure path only**, so it sits outside every pinned success-path budget. It catches `Exception` rather than `DmlException` — deliberately wider than its siblings, because it is the only method here that also READS and a `WITH USER_MODE` `QueryException` is not a `DmlException`. |
| `InboundEmailAttachmentService` | `EmailToLeadHandler` (`classify` + **`stageBytes`** — the byte CARRIER, no Content DML); **`AttachmentPersistQueueable`** and **`AttachmentCarrierSweepBatch`** (`persist` + `linkTo` — the ONLY callers); `ExtractAddressQueueable` (`releaseCarrier`) | Broker Protection: the **only class in the app that writes `ContentVersion`, `ContentDocumentLink` or the classic `Attachment` byte carrier** for this module. 🔴 **2026-08-05/06 — v1 SHIPPED, CAUSED A LIVE OUTAGE, WAS REVERTED, AND WAS REDESIGNED (v2, 2026-08-06). THE INVARIANT THAT USED TO STAND IN THIS ROW — "`persist(...)` AND `linkTo(...)` MUST NOT THROW, under any input" — WAS FALSIFIED IN PRODUCTION AND HAS BEEN DELETED. Do not restore it and do not restore the call on the strength of a `try/catch`.** Measured on `usman-dpeg` via a four-case anonymous-Apex reproduction (full writeup in `EmailToLeadHandler`'s class header): `Database.insert(versions, false)` inside `persist()` threw `System.UnexpectedException: ContentPublication Limit exceeded` once the org's rolling **2,500-per-24h `ContentPublication` quota** was exhausted. That exception (a) **ignores `allOrNone = false`**, (b) **escapes `catch (Exception e)` through TWO nested layers**, arriving as `FATAL_ERROR`, and (c) triggers a **total rollback**, including the already-committed `Inbound_Email_Staging__c` insert — so **every inbound broker email carrying an attachment was silently destroyed**: no staging row, no Lead, no claim, no Task, no `AsyncApexJob`, no bounce, no error record. Attachment **size was irrelevant** (100 KB / 1 MB / 5 MB failed identically; heap peaked at 4,262 bytes), so this is categorically NOT the heap `LimitException` `VISION_MAX_BYTES` guards, and **"a better catch" is measured-dead, not a fix to propose.** **THE RULE THAT REPLACES THE OLD INVARIANT IS ABOUT CALLERS, NOT ABOUT CODE IN THIS CLASS: a `ContentVersion` insert must never sit inside a transaction whose rollback would lose something irreplaceable** — so `persist`/`linkTo` may be called ONLY from `AttachmentPersistQueueable` and `AttachmentCarrierSweepBatch`, never from `EmailToLeadHandler` (owns the email) and never from `ExtractAddressQueueable` (owns the Lead and the claim). **What the handler does instead (v2):** `stageBytes` parks each retained attachment on the staging row as a classic **`Attachment` byte carrier** — **zero ContentPublications (SP-4.1, `/limits` 2500 → 2500, definitive) and ~152 bytes of heap at ANY file size (SP-4.3, measured identically at 3 MB and 5 MB, because `Body = <blob>` is a reference assignment)** — in ONE bulk statement, pinning the handler at **0 SOQL / 2 DML (1 with no attachments)**. Constants moved with the redesign: `MAX_ATTACHMENTS` **10 → 3** (user decision) and `ATTACHMENT_MAX_BYTES` **5,000,000 → 4,000,000** (aligned to `CONVERT_MAX_TOTAL_BYTES` so any retained file always fits ONE conversion transaction by itself); `TEXT_MAX_BYTES` keeps its value but its **venue moved to the synchronous side**, so it now guards the 6 MB budget rather than the 12 MB one. `persist`'s per-row heap re-check was widened from the CSV branch to **every** row and re-based on `CONVERT_HEAP_CEILING`, because SP-4.5 measured `VersionData = att.body` on a SOQL-read body allocating the bytes a SECOND time (**peak ≈ 2 × converted bytes; one 5 MB file reached 10,487,036 of the 12,000,000 async ceiling**). Unchanged and still correct: `ShareType` `'I'` on routed **Lead / Opportunity / Contact** links and `'V'` on the staging link (an *edit* grant on an audit row must not confer the right to replace a broker's own submission); `'C'` is rejected by the platform everywhere; **no dedupe, deliberately** (decision E1) — a redelivery costs zero publications only because `ExtractAddressQueueable.execute` returns WITHOUT calling `finish()`, which is where the file job is enqueued, and that skip path now also RELEASES the duplicate's carrier; and **`LeadFileCarryOverService` still does NOT exist and must not be built** (spike S6 — the platform already carries a Lead's files to Account, Contact and Opportunity on `Database.convertLead`, so `LeadConvertService`'s `2 SOQL / 3 DML` contract and `LeadConvertTrigger` are untouched). ⚠ **The carrier is TEMPORARY, with four defined exits** — CONVERTED (`AttachmentPersistQueueable`, only on confirmed success), RELEASED (`ExtractAddressQueueable`, on a gate or duplicate), RETRIED and EXPIRED (both `AttachmentCarrierSweepBatch`). See `agent-output/design-requirements-attachment-persistence-v2.md` and `agent-output/spike-attachment-persistence-v2.md`. |
| `AttachmentPersistQueueable` | chained from `ExtractAddressQueueable.finish()`; replayed by `AttachmentCarrierSweepBatch` | Broker Protection: **the transaction that owns nothing else, and therefore the ONLY admissible home for a `ContentVersion` insert in this application.** It reads the carrier `Attachment` rows, converts the subset that provably fits, links the resulting files to the staging row and to every routed record, deletes ONLY the carriers that converted, and stamps `Attachment_Status__c`. 🔴 **The payload is IDS ONLY, never bytes** — SP-1 measured an **UNCATCHABLE** `System.LimitException: Batchable instance is too big` thrown at `System.enqueueJob` ITSELF at the platform's 6,000,000-char constant (~4.2–4.5 MB raw), surfacing as `[EXTERNAL]`/`FATAL_ERROR`; carrying bytes on a payload would have relocated the outage one call earlier, into the transaction that owns the email. 🔴 **The §6.2 heap gate is a PRE-CHECK, and the two-method `AttachmentSelector` split is its only mechanism**: `BodyLength` is queryable WITHOUT `Body`, so `chooseConvertibleSubset` (pure) picks the largest ascending-size prefix summing to ≤ `CONVERT_MAX_TOTAL_BYTES` (4,000,000 → 8 MB peak = 67% of 12 MB) *before a single byte enters heap*, and `CONVERT_HEAP_CEILING` (9,000,000 = 75%) is re-checked before each `VersionData` assignment. **Governor budget: 3 SOQL / 6 DML, CONSTANT IN BOTH FILE COUNT AND TARGET COUNT** — that constancy is the load-bearing property. ⚠ Design §9 pins "3 SOQL / **5** DML" and enumerates only five statements (ContentVersion insert, staging links, routed links, carrier delete, budget counter); it omits the `Attachment_Status__c` stamp its own §11.2 step 10 requires, and that stamp is not optional — without it the sweeper can never learn the row is done. The implemented, truthful number is **six**. `linkTo` is called ONCE, never per file or per target. Failure is reported by `AttachmentPersistFinalizer`, not by a `catch`. |
| `AttachmentPersistFinalizer` | attached as the FIRST statement of `AttachmentPersistQueueable.execute` | Broker Protection: the file job's failure reporter. On `UNHANDLED_EXCEPTION` it stamps `Attachment_Status__c = 'Failed'` (which re-queues the row for the sweeper), appends the durable §7 note naming the wrapped message and the `AsyncApexJob` Id, and trips the circuit breaker. SP-3 measured that a Finalizer fires on BOTH an ordinary exception and a `System.UnexpectedException`, in test AND production, and that **its own DML commits durably in a fresh transaction after the parent's rollback** — the R1 lesson's actual mechanism, observed rather than inferred. 🔴 **Detection of the ContentPublication case is a MESSAGE SUBSTRING, NEVER a type check:** SP-3 measured `ctx.getException().getTypeName()` reporting **`System.AsyncException`**, not `System.UnexpectedException` — the platform wraps it and preserves the real type and message only as text inside `getMessage()`, so an `instanceof` test would silently never match and the breaker would never trip. ⚠ `EmailCaptureQueueable`'s header explains why *it* deliberately has no Finalizer (self-healing, convergent work); **that reasoning does not transfer** — this job's failure would otherwise destroy the only record of itself. Two classes, opposite decisions, both correct. |
| `AttachmentCarrierSweepBatch` | `AttachmentCarrierSweepSchedule` (daily, off-peak) | Broker Protection: the RETRY/REPLAY engine, and the reason the carrier is temporary rather than permanent. Selects `Attachment_Status__c IN ('Pending','Partial','Failed')` via `InboundEmailStagingSelector.queryCarrierSweep()`, replays `AttachmentPersistQueueable.convert(...)` — the identical code path, so the heap gate cannot drift — and at `CARRIER_MAX_AGE_DAYS` (14) deletes the carrier and stamps `Expired`. 🔴 **`SCOPE = 1` is load-bearing**: one staging row per transaction gives each its own 12 MB async heap budget, which is what keeps the §6.2 gate valid unchanged; raising it re-opens an UNCATCHABLE heap failure. Idempotent and convergent — a successful pass moves the status out of the queue, so re-running is free. 🔴 **A deploy that does not SCHEDULE it silently disables every retry path in the design**, and job instances are not deployable metadata, so that is a verified post-deploy gate (§10.2 A5 / UAT U13). It is proven at **251 staging rows**, which is free because those rows carry no content. 🔴 **AMENDED 2026-08-08 — its routing-skip predicate is now `Status__c IN ('Pending','Failed')`, and that widening was NOT optional.** It skips a row whose ROUTING has not finished because converting then would link files to nothing; the new `'Failed'` value means routing DIED and is queued for retry, i.e. exactly as unfinished as `'Pending'`. Had `Failed` shipped without it, every attachment-bearing email whose routing died would have converted with EMPTY targets, linked only to the staging row, stamped `Saved` — dropping out of this queue — and then **permanently lost the Lead links** when `RoutingRetrySweepBatch` later succeeded, with no error anywhere. Two sweepers keyed on two fields of one row: the new half's state changes the live half's behaviour. |
| `RoutingFailureFinalizer` | attached as the **FIRST statement** of `ExtractAddressQueueable.execute` — **above** the `getStaging` load | Broker Protection: the ROUTING job's failure reporter, and the mirror of `AttachmentPersistFinalizer` for the transaction that owns **the Lead and the registry claim** rather than only files. On `UNHANDLED_EXCEPTION` it stamps `Status__c = 'Failed'` (which enqueues the row for `RoutingRetrySweepBatch`), increments `Routing_Attempt_Count__c` and APPENDS a durable note naming the wrapped message, an advisory classification and the `AsyncApexJob` Id. 🔴 **A `try/catch` cannot substitute for it, and that is measured:** SP-R1 (2026-08-08) ran heap- and CPU-exhausting Queueables with the failing code wrapped in `catch (Exception e)` positioned directly around it — **the catch never ran in either case**, which is the literal premise `ExtractAddressQueueable`'s own catch depended on. SP-R2 additionally measured `attachFinalizer` working inside a `Queueable, Database.AllowsCallouts` class and still firing after a real callout, closing the risk that every prior Finalizer measured in this repo was on a PLAIN Queueable. 🔴 **Detection is a MESSAGE SUBSTRING, never a type check** — SP-R1 generalised SP-3's finding beyond `ContentPublication`: heap and CPU `LimitException`s BOTH arrive wrapped as `System.AsyncException`. ⚠ **But the wrapping is not universal** — SP-R2 measured an ordinary custom exception arriving UNWRAPPED with its real type, so a type check is unreliable in a way that VARIES BY FAILURE FAMILY; substring matching is the only approach correct in both. **It RECORDS but never RETRIES** (design D3): an uncatchable failure is usually deterministic, a Finalizer's enqueue is accepted-but-never-executed in `@isTest`, and — decisively — the attempt counter must be incremented in one place and consulted in one place, so this class deliberately does **not** clamp it to the cap. Budget: **1 SOQL / 1 DML**, in its own transaction, outside every pinned `ExtractAddressQueueable` budget by construction. |
| `RoutingRetrySweepBatch` | `RoutingRetrySweepSchedule` (**hourly**) | Broker Protection: the RETRY/REPLAY engine for routing, giving the routing row the same four exits the carrier already had — PROCESSED / ERROR (human queue) / **FAILED (retried)** / **ABANDONED**. 🔴 **It dispatches `Failed` and nothing else, and that is a SAFETY PROOF rather than a preference.** `'Failed'` is written only by `RoutingFailureFinalizer`, which fires only on `UNHANDLED_EXCEPTION`, and SP-5 measured that an unhandled exception rolls back the queueable's OWN DML — so a `Failed` row provably carries no Lead, no claim, no submission, no Task and no stamp from that attempt, making a replay byte-for-byte a first run. 🔴 **`'Error'` has the OPPOSITE property and must never be dispatched:** the catch RAN, so work COMMITTED, and a blind replay either mints a **second Lead** (Lead committed, claim returned `UNCLAIMED` on a lock timeout) or files the **winning broker as a competing submission against their own Lead** (registry committed, submission not) — both recoverable only by manual registry surgery. The rule is enforced twice on purpose: in the locator and again in memory, so a test can falsify it and a future locator widening cannot silently break it. 🔴 **`SCOPE = 1` is load-bearing for a DIFFERENT reason than the carrier sweep's**: `Limits.getLimitQueueableJobs()` is **1** inside an asynchronous transaction, so a second `System.enqueueJob` in one chunk throws — one row per transaction is the only shape in which per-row dispatch is expressible at all. Caps: `MAX_ATTEMPTS = 3` (initial + 2) and `ROUTING_MAX_AGE_DAYS = 14`, the latter **aligned deliberately to `CARRIER_MAX_AGE_DAYS`** so a routing row can never outlive its own attachment carrier. Convergent: success stamps `Processed`, failure advances the counter toward the cap, so re-running is free and even a persistently undispatchable row terminates. ⚠ **A 251-row test proves the LOCATOR, not 251 `execute()` calls** — a test method runs only ONE chunk, and at SCOPE = 1 that is one row; 251 dispatches is unreachable in production anyway. Budget: **0 SOQL / ≤ 1 DML / ≤ 1 enqueue** per `execute()`. |
| `RoutingRetrySweepSchedule` | scheduled hourly, post-deploy | Broker Protection: the trigger for the routing retry sweep. 🔴 **A deploy that does not schedule it silently disables every routing retry in the design — and leaves a WORSE state than before the feature**, because a stranded row now reads `Failed` and appears in a list view, i.e. it LOOKS handled while nothing will ever touch it again. Job instances are not deployable metadata, so this is a verified post-deploy gate (design §10 A6 / UAT U2). ⚠ **Hourly, not daily** (contrast `AttachmentCarrierSweepSchedule`): a claim is TIME-ORDERED, so retry latency is paid by a real broker who can lose a property to someone who submitted later but routed cleanly in between — whereas a late file is merely late. |
| `ContentPublicationBudget` | `AttachmentPersistQueueable`, `AttachmentCarrierSweepBatch` (check + record), `AttachmentPersistFinalizer` (trip) | Broker Protection: the L4 circuit breaker and L5 daily budget of design §6 — **a backstop, explicitly NOT the answer to the outage** (that is structural: the file job owning nothing irreplaceable). Backed by `Content_Publication_Budget__c`, **the FIRST hierarchy Custom Setting in this repo**, chosen because `getOrgDefaults()` costs **0 SOQL** and so does not move the file job's pinned query budget. `DAILY_PUBLICATION_BUDGET = 1000` bounds any rolling 24 h window at ≤ 2,000 of 2,500; `BREAKER_SUSPEND_HOURS = 24` matches the rolling quota window and clears by the passage of time, with no reset job to forget. 🔴 **It degrades to "permitted" on any internal failure** — a backstop that blocks the feature when the backstop malfunctions is worse than none, because isolation and recoverability already make a quota hit non-fatal. ⚠ Concurrency is last-write-wins and the counter ALWAYS undercounts (test rollback does not refund the quota, M7); both are why the line sits 1,500 below the cap. **Do NOT add a `FOR UPDATE` lock** (it would serialise unrelated emails) and **do NOT read `/limits` anywhere, even advisorily** — prohibited by §3.1, by `.claude/rules/content-publication-rule.md`, and by SP-6's measurement that the value is stale and non-monotonic. ⚠ Custom-setting DATA is not deployable; the org-default row is created by this class on first use. |
| `InboundEmailActivityService` | `ExtractAddressQueueable`                            | Broker Protection: the only class that writes the inbound-email `Task` and the sole owner of RFC threading — stamps `Inbound_Message_Id__c` (idempotency) and `Thread_Key__c` (conversation root), and answers "has this Message-ID already been logged?". A Task is used rather than `EmailMessage`. **Corrected 2026-07-31 (twice — read the second):** the original reason ("Enhanced Email is not licensed in this org") is obsolete, since Enhanced Email is now enabled via Einstein Activity Capture setup. A first correction wrongly blamed Enhanced Email for reserving `TaskSubtype`; an in-org bisect falsified that — **`TaskSubtype = 'Email'` inserts fine here and is retained (it renders the email icon)**. The real defect was `Task.Type`, which **does not exist in Enhanced-Email-era org templates** (absent from FieldDefinition): it compiles in Apex but throws "fields being inaccessible on Sobject Task" at runtime, which is why the module's first-ever real executions in this org both failed. `Type` is now never set by this module and must not be re-added — classic-template orgs accept it, so a green run elsewhere proves nothing. The thread-anchor contract is unchanged, which matters because Change 2's EAC guard matches on those anchors. Migrating to EmailMessage-based logging is now possible but is deliberately a separate change. **Extended 2026-08-04 (sender attribution on the Task) — see `docs/2026-08-04-broker-attribution-on-pipeline-tasks.md`:** `Task.Subject` now carries a head-preserving `From <sender>: ` prefix ahead of the original subject (sender clipped to 60 chars first, so it can never be truncated away; at least 188 chars of the subject always survive the 255-char field), and `Task.Description` gains a `From:` / `Subject:` / 60-hyphen-rule header block ahead of the raw body, with the **full, untruncated** subject on its own line. Both `logInboundEmail` overloads gained trailing `senderName`/`senderEmail` parameters, and the prior 6-argument sender-less overloads were **removed outright**, not kept alongside, so a future caller cannot silently regress to a sender-less Task. `ExtractAddressQueueable` resolves the identity once — defaulted from the envelope (`staging.From_Name__c`/`From_Address__c`) before any routing branch runs, then refined fill-if-present after `applySenderFirstBrokerIdentity` (U1) — so the Task always shows the same broker identity the module used for arbitration, never a second independently-derived guess. Zero new fields, zero new SOQL, zero new DML. ⚠ **CONTRACT — `Task.Subject` IS NOT A MATCHING KEY, AND MUST STAY THAT WAY** (relocated here from the class header 2026-08-04 so a future Subject-based probe actually finds it): no query in this repo matches pipeline Tasks by Subject — the two Subject-matching `TaskSelector` methods (`selectByWhatIdAndSubjects`, `selectOpenByWhatIdsAndSubjectPrefix`) belong to the Disposition closing checklist and the broker check-in reminder, both scoped by `WhatId` with literal internal subjects, and cannot collide with a `From `-prefixed email subject. Idempotency and reply threading still match on `Inbound_Message_Id__c`/`Thread_Key__c` only. This does **not** fix the Lightning "You sent an email" chrome, and nothing on a Task can — direction lives on `EmailMessage.Incoming`, which a standalone Task has no counterpart for. An `EmailMessage`-based alternative was assessed and rejected on two independent grounds: it would destroy the EAC Thread Guard's structural-unreachability guarantee for pipeline anchor Tasks (an `EmailMessageRelation` insert deletes and recreates the companion Task, silently breaking `Inbound_Message_Id__c` idempotency), and an incoming message whose sender already exists as a Contact cannot relate to a same-address Lead at all (`LIMIT_EXCEEDED`, measured 2026-08-02) — exactly the shape of every repeat broker this module exists for. |
| `LLMExtractionCalloutService` | `ExtractAddressQueueable`                          | Broker Protection: mockable OpenAI callout wrapper extracting broker name/email, property address, and send time from a forwarded email (vision + text). Direct-callout §3 exception — see §3.3. **Its text input is the SUBJECT LINE + the body (+ image) since 2026-08-03** — `ExtractAddressQueueable.buildLlmText` prepends `Subject: <CR/LF collapsed>` and a blank line at the QUEUEABLE call site, so `extract(String, String, String)`, `buildRequestBody` and `MAX_INPUT_CHARS` are all unchanged and the §3.3 re-homing promise stays literally true. Composing before the callout is what makes the subject survive the 40,000-char clip (which preserves the head); a blank subject returns the body byte-identically. The matching enriched-block paragraph carries **body-over-subject precedence**, which is what prevents the widened address search from re-keying any claim that already exists. |
| `PropertyMatchingService`     | `ExtractAddressQueueable` (via `PropertyClaimService`) | Broker Protection: address normalization, Jaccard fuzzy matching, cluster-key derivation, and registry/orphan lookups behind the first-broker-wins claim decision. Read-only; no DML. |
| `PropertyClaimService`        | `ExtractAddressQueueable`                          | Broker Protection: owns all `Property_Registry__c` / `Competing_Broker_Submission__c` DML — acquires the `Property_Claim_Lock__c` FOR UPDATE lock, then registers a winner or marks a duplicate. **Sole owner of the WINNER ANCHOR rule (2026-08-03):** `buildSubmission` is the one place that decides Lead-vs-Opportunity anchoring, and `markDuplicate` / `logRepeatSubmission` take the caller's already-resolved live record so the rule costs no extra SOQL on the branches that fire. |
| `LeadActionPermissionService` | `LeadActionPermissionController`, `LeadConvertActionController` | Lead stage quick actions: the single source of truth for "may the running user drive Convert / Mark Under Review / Mark Qualified / Disqualify?". Accepts `Lead_Stage_Actions_Access` OR `Broker_Protection_Access`, resolves grants through permission set GROUPS as well as direct assignments, and bypasses for "Modify All Data". Exposes `hasLeadActionAccess()` (the cacheable UX gate) and `assertLeadActionAccess()` (the server-side enforcement used before `Database.convertLead`). Reads via `PermissionSetAssignmentSelector` + `PermissionSetGroupComponentSelector`; no DML. |
| `OpportunityActionPermissionService` | `OpportunityActionPermissionController`, `StageAdvanceController`, `OpportunityApprovalController` | Opportunity stage quick actions: the single source of truth for "may the running user drive the deal actions?". Exposes `hasDealActionAccess()` (the cacheable UX gate) and `assertDealActionAccess()` (the server-side enforcement now asserted by `advance` / `advanceTo` / `submitForApproval`). Reads via `UserSelector` + `PermissionSetAssignmentSelector`; no DML. **The gate is TWO-FACTOR and is deliberately NOT the Lead-style membership check** — see below. |
| `RecordStageAdvanceService` | `RecordStageAdvanceController` (the `advanceRecordStage` quick action on five objects) | **Generic stage advance for the five acquisitions CHILD objects whose Path is a straight line** (added 2026-08-04): `NDA__c` (`Status__c`), `LOI__c`, `Underwriting__c`, `Construction_Feasibility_Review__c`, `Development_Feasibility_Review__c` (`Stage__c`). ONE service, config-driven by a `Map<SObjectType, StageConfig>` holding label + stage field + ordered `NEXT_STAGE` map + permission gate — **Apex, deliberately NOT Custom Metadata** (an admin editing a stage map with no deploy and no review is the same class of hole this feature closes; CMDT *record* deploys also fail in this org). Zero SOQL of its own: `load()` dispatches on `Id.getSObjectType()` to each object's own `<Object>Selector.selectStageRequiredById`, all static and `WITH USER_MODE`, **no dynamic SOQL anywhere**. Write is plain `update` (system mode), matching `StageAdvanceService`; the FLS residual is documented in the class header. 🔴 **It exposes `advance(recordId)` ONLY — there is no generic `advanceTo`**, because all five paths are linear and a generic explicit target would re-open exactly the hole `StageAdvanceService.ALLOWED_EXPLICIT_TARGETS` closes. 🔴 **The Underwriting map deliberately OMITS `In Progress` → `Approved`** — that stage belongs to the principal approval process (`Submit_for_Approval` → `ApprovalAuditService`), and the refusal message names that route so the gap does not read as a bug. |
| `EmailThreadAnchorService` | `EmailCaptureQueueable`, `EmailThreadAdopterService`, `EmailThreadGuardService` | **The SHARED thread-anchor index** (added 2026-08-02 with the adopter): performs the ONE anchor read per queueable execution and the ONE bracket normalization, then hands both halves an `AnchorIndex` they consume with opposite polarity (`isAnchoredOn` for the guard, `resolveOpportunity` for the adopter). It exists so the two features normalize identifiers IDENTICALLY BY CONSTRUCTION rather than by convention. **A THIRD ACCESSOR was added 2026-08-04 for the guard's dedupe rule: `isMessageIdAnchoredOn(recordId, message)`, backed by a second per-record map holding `Task.Inbound_Message_Id__c` ONLY — deliberately NOT the union `isAnchoredOn` uses, and NOT first-wins.** ⚠ The two must never be collapsed: conversation-level identity (`Thread_Key__c`, shared by every message in a thread) is the right key for "is this relevant here?" and the WRONG key for "is this redundant here?" — substituting it would delete EAC's copy of every outbound reply, which is the only representation of outbound mail anywhere in Salesforce. The union is lossy, so the Message-ID half is retained separately as it is read rather than filtered back out. Same query, same loop, same single normalization: **zero new SOQL.** Read-only; no DML. Reads via `TaskSelector.selectThreadAnchorsByAnchorValues` + `EmailMessageSelector`. `with sharing`. |
| `EmailThreadAdopterService` | `EmailCaptureQueueable` (via `EmailMessageTrigger`), and a one-off DevOps sweep | **EAC Thread Adopter** (added 2026-08-02): the MIRROR of the guard. EAC is the only system that sees the OUTBOUND half of a deal thread, but it associates by address, so the reply lands on the broker's Lead/Contact rather than the deal. This service re-points `EmailMessage.RelatedToId` to the Opportunity the thread's own pipeline anchor names — an RFC-header IDENTITY match, which beats EAC's address inference. Owns the only `RelatedToId` DML (`Database.update(..., false)`, one bulk statement) and performs **ZERO Task DML, ever** — the platform propagates the value onto the companion Task's `WhatId` by itself (measured, E2), which is what preserves the guard's structural guarantee. Reads via `EmailMessageSelector` + `TaskSelector`. **`without sharing`** (same justification as the guard: it must adopt onto EVERY resolved Opportunity, not the subset the automated principal can see). |
| `EmailThreadGuardService` | `EmailCaptureQueueable` (via `EmailMessageTrigger`), and a one-off DevOps sweep | **EAC Thread Guard** (added 2026-08-02): undoes Einstein Activity Capture's address-based over-association on Leads. EAC is THREAD-BLIND — it staples every captured email onto every record whose address appears on it, so a brand-new unrelated conversation with a broker lands on that broker's deal Lead. No EAC setting can prevent it, so the guard runs *after* capture: an EAC-materialized email may stay on a Lead only if its `ThreadIdentifier`/`MessageIdentifier` matches a thread anchor the Broker Protection pipeline logged there (`Task.Thread_Key__c` / `Task.Inbound_Message_Id__c`). Anything unanchored is deleted with its companion timeline Task — **unless the capture also lives on a record outside `{Lead, User}`** (see the scope note below). Owns all DML in the feature (`Database.delete(..., false)` — the two deletes cascade into each other, so an already-gone row is SUCCESS). Reads via `EmailMessageSelector` + `EmailMessageRelationSelector` + `EmailThreadAnchorService`. **`without sharing`** (justified in the class header: it must clean EVERY Lead the capture landed on, not the subset the automated principal has sharing to). **Amended 2026-08-02 for the adopter:** it now runs SECOND (after the adopter, in the same job), consumes the shared anchor index, and its guard 4 is widened from "anchored on a related Lead" to "anchored on ANY record it lives on" — related Leads ∪ the `RelatedToId` record. Every one of those changes is KEEP-BIASED. **⚠ AMENDED 2026-08-04 — IT NOW DELETES FOR TWO REASONS AND HAS FIVE SCOPE GUARDS.** Guards 1–3 are admissibility (all must hold); guards 4 and 5 are the two delete reasons and exactly one must hold. Guard 5 (NEW): a capture ADDS NOTHING NEW when `Incoming == true` **and** its normalized `MessageIdentifier` equals a normalized `Task.Inbound_Message_Id__c` present on **EVERY** record in `relatedLeadIds ∪ {RelatedToId}` — EAC's duplicate copy of an inbound broker email the pipeline already logged. **The delete condition IS the safety invariant: a timeline goes 2 → 1, NEVER 1 → 0**, because a pipeline row must already exist on every record the capture is removed from; if that cannot be established for even one record the capture is KEPT. Universally quantified (`&&`), the exact opposite quantifier from guard 4's existential (`||`) — both fail safe toward keep. 4 and 5 are disjoint populations (an exact duplicate is by definition anchored), so they share the one bulk delete pair: **query budget stays 7, DML stays ≤2, enqueue stays 1, and `EmailCaptureQueueable` is untouched.** ⚠ THE SURVIVING ROW IS THE PIPELINE'S AND ITS CAPTION IS WRONG ("You sent an email", derived from `EmailMessage.Incoming`, which a standalone Task has no counterpart for) — that trade was a **user decision at Gate 1**, not a defect. Two stated boundaries: **converted deals keep their duplicates** (the pipeline files on the Opportunity, EAC relates to the Contact, so guard 2 declines — correct under W1) and **L1: the rule is one-shot at capture time** (a capture arriving before the pipeline's Task is kept and nothing re-examines it; the remedy is the `run(Set<Id>)` sweep, never a Task trigger, which would create a second route to a Task and destroy the structural-unreachability guarantee). |

**⚠ TWO STAGE-ADVANCE SERVICES — know which one you are editing (2026-08-04).**
`StageAdvanceService` is **Opportunity only**: its `advance()` BRANCHES into an approval submission,
and `advanceTo()` exists solely because Opportunity has parallel record-type branches (Land /
Commercial) plus an off-ramp — which is why it carries `ALLOWED_EXPLICIT_TARGETS`.
`RecordStageAdvanceService` covers the **five child objects**, all of whose paths are LINEAR, so it
has no branch, no off-ramp, and deliberately no explicit-target method. They were **not** merged: the
Opportunity service is live, gated and deployed, and folding it in would buy tidiness at the cost of
re-testing the approval hand-off. They DO share `OpportunityActionPermissionService` and the
guard/confirm shape on the client. Each class header carries this same map. Note also that
`RecordStageAdvanceService.setStage` guards `getDmlMessage(0)` behind `getNumDml() > 0` while
`StageAdvanceService.setStage` does not — a latent difference in the older class, not an oversight in
the newer one.

**⚠ THREE SIMILARLY-NAMED LEAD-CONVERSION CLASSES — know which one you are editing (2026-08-02).**
`LeadConvertActionService` **runs** `Database.convertLead`; `LeadConvertMatchService` **decides what
it attaches to** (before, read-only); `LeadConvertService` **stamps the Opportunity and creates the
`Property__c`** (after, via `LeadConvertTrigger`). Each class header carries this same map.
`AccountSelector` (new, 2026-08-02) is the **first and only Account SOQL in the application** — there
was none before it; every future Account read belongs there.
`OpportunityContactRoleSelector` (new, 2026-08-03) is likewise the **first `OpportunityContactRole`
SOQL — and the first `OpportunityContactRole` handling of any kind — in the application**; every
future read belongs there. Its single method `selectByOpportunityIds(Set<Id>)` is what makes
`LeadConvertService`'s broker-role write a read-then-write instead of a blind insert, and it is
called **once per invocation for the whole converted set** (it is SOQL 2 of that service's 2-SOQL
contract). Never call it per record.

**Broker Protection staging model (added 2026-07-28; file capture added 2026-08-05):** the pipeline
no longer creates a Lead at the
email boundary. `EmailToLeadHandler` parses the envelope, RFC headers and inline image, **marshals
and classifies every attachment, persists the retained ones as Salesforce Files and links them to
the staging row**, writes an
`Inbound_Email_Staging__c` row, and enqueues `ExtractAddressQueueable(stagingId, imageBase64,
imageMimeType, contentDocumentIds)`. The queueable then runs a five-branch ROUTING TREE — Reply → Repeat → No-Property →
Competing Submission → Winner. **Only branches (c) NO-PROPERTY and (e) WINNER create a Lead**
(amended 2026-07-31): Reply and Repeat file the email onto an existing record, and branch (d)
COMPETING SUBMISSION no longer creates one either — a competing broker gets no Lead at all, only a
`Competing_Broker_Submission__c` against the winner with `Source_Lead__c = null`, with the email
logged on the WINNING Lead (resolved through conversion). Branch (d) reads the registry BEFORE
calling `createLead`, so no orphan Lead is ever minted. Branch (e) can still discover the race late:
when `claim()` returns `DUPLICATE_RACE` the Lead it just created is DELETED via
`EmailToLeadService.deleteLead` and the email is re-routed onto the winner exactly like branch (d).
Staging outcome labels are `'Competing Submission'` (d) and `'Competing Submission (race)'` (e);
both replace the retired `'Competing Duplicate'`, and rows stamped before 2026-07-31 keep the old
label because `Outcome__c` is free Text and was deliberately not back-filled.
**Branch (c) now STAMPS the first property's deal block (2026-08-03, extraction-completeness FIX 2).**
It used to pass `property = null` into `createLead`, so on an email that named an asset the pipeline
could not address, every extracted deal fact — property name, unit count, price, NOI, offer due date,
asset type — died in `Extracted_JSON__c` and the Lead converted into an unnamed Property with no data.
It now passes `extraction.properties[0]` (the MODEL's own order — no ordering guarantee is claimed or
needed, since branch (c) takes no lock and derives no claim key) through the SAME
`LeadRequest.property` / `applyPropertyBlock` path the winner branch uses, so `EmailToLeadService` is
unchanged. The stamped property is excluded from the Deal-Notes "additional properties (not routed)"
footer, and a new outcome label `'New Lead (property, no address)'` (`OUTCOME_NO_ADDRESS`) separates
this population from the genuinely-nothing case — LLM-down still wins the label. ⚠ **Still NO claim:**
an addressless property cannot produce a `Property_Key__c`, so these Leads have no first-broker-wins
protection and a later broker submitting the same property WITH an address wins it outright; the label
exists so a human can list them and chase the address. `Lead.Property_Address__c` is held null by a
`claimableAddress()` guard rather than by luck — it encodes the invariant that **that field only ever
holds an address that could have produced a claim key** (a raw `'###'` is non-blank but normalizes to
empty). Branches (a)/(b)/(d)/(e) and the HARD relevance gate are untouched.
`Lead.Is_Duplicate_Property__c` / `Duplicate_Of_Lead__c` are now LEGACY — no code path writes them.
Every branch ends by logging a `Task` with both RFC threading keys and stamping the staging row. Deferring Lead creation is what makes reply threading, repeat detection and
redelivery suppression expressible at all — each of those must be able to decide that no new Lead
should exist. `InboundEmailFieldUtil` is a pure utility (not a service): it clips every externally
sourced value to its field length and sanitizes anything bound to an Email field, so an over-long LLM
answer cannot roll back a committed claim.

**ATTACHMENT CAPTURE (2026-08-05) → CARRIER-BASED FILE PIPELINE (REDESIGNED 2026-08-06, v2).**
🔴 **v1 shipped, destroyed every inbound broker email carrying an attachment, and was reverted.** The
cause and the five measured facts are in the `InboundEmailAttachmentService` row of §2 and in
`EmailToLeadHandler`'s class header; the governing rule that came out of it is one sentence: **a
`ContentVersion` insert must never sit inside a transaction whose rollback would lose something
irreplaceable.** The extraction contract, the routing tree, the claim engine, the Task contract and
the classification RULES are all unchanged by both versions.

File capture is therefore a **THIRD TRANSACTION**, after routing:

```
1. EmailToLeadHandler          owns THE EMAIL  →  classify + stageBytes (classic Attachment carrier)
2. ExtractAddressQueueable     owns THE CLAIM  →  routes, then CHAINS the file job with IDS ONLY
   └ RoutingFailureFinalizer     on failure: Status__c 'Failed', +1 attempt, durable note  ← 08-08
3. AttachmentPersistQueueable  owns only FILES →  converts, links, deletes converted carriers
   └ AttachmentPersistFinalizer  on failure: stamp 'Failed', durable note, trip the breaker
4. AttachmentCarrierSweepBatch daily  → retries 'Pending'/'Partial'/'Failed', expires at 14 days
                                        SKIPS any row whose ROUTING reads 'Pending' OR 'Failed'
5. RoutingRetrySweepBatch      hourly → re-enqueues (2) for 'Failed' rows only; abandons at 3
                                        attempts or 14 days                              ← 08-08
```

⚠ **ROUTING RESILIENCE (2026-08-08) ADDED LINES 2b AND 5, AND THEY ARE THE SAME FOUR MECHANISMS AS
THE FILE PIPELINE'S, APPLIED TO THE TRANSACTION THAT OWNS THE LEAD.** Until then the routing job
had no Finalizer, no failure status, no work queue and no retry engine, so an uncatchable death
(heap, CPU, or a `USER_MODE` FLS throw in `getStaging`, which runs *outside* the try) left the row
on `Pending` with `Error__c` null and nothing to recover it. 🔴 The coupling in line 4 is the part
most easily missed: a routing-`Failed` row is a routing-UNFINISHED row, so the FILE sweeper had to
learn to skip it **in the same change** — otherwise it converts with empty targets, stamps `Saved`,
drops out of its own queue, and the routed links are lost permanently when routing later retries.

Six things about it are easy to get wrong:

**(1) THE BYTES TRAVEL AS A CLASSIC `Attachment`, NEVER ON A PAYLOAD.** SP-4 measured the carrier at
**zero ContentPublications and ~152 bytes of synchronous heap at any file size**; SP-1 measured an
**UNCATCHABLE** `LimitException: Batchable instance is too big` thrown at `System.enqueueJob` itself
above ~4.2–4.5 MB, which would have relocated the outage one call earlier, into the transaction that
owns the email. The ≤ 1 MB vision image stays on the payload and is the ONE exception, because SP-1
proved ~4× headroom for that bound specifically.

**(2) THE VISION GATE IS UNCHANGED AND IS A DIFFERENT FAILURE ENTIRELY.** `VISION_MAX_BYTES`
= 1,000,000 (`EmailToLeadHandler`) remains the ONE approved crossing of the "vision path unchanged"
boundary, taken as a bug fix: `EncodingUtil.base64Encode` holds the source Blob and the encoded
String simultaneously, so the 6 MB synchronous heap limit is crossed somewhere between ~1.6 MB and
~2.5 MB — an ordinary phone photo — and an Apex `LimitException` is UNCATCHABLE. Inputs stay
byte-identical below the threshold; above it the image is skipped and the skip is recorded. The
ContentPublication outage was **not** a heap failure (heap peaked at 4,262 bytes), so lowering this
constant would have changed nothing.

**(3) THE HEAP RISK MOVED TO THE ASYNC CONVERSION, AND IT IS REAL.** At the boundary, persisting is
still ~free — `Messaging.InboundEmail` already holds every Blob in heap. But SP-4.5 measured the
CONVERSION duplicating the bytes (`heapAfterRead` 5,244,053 → `heapAfterBuild` 10,487,036 for one
5 MB file: **87% of the 12 MB async ceiling, peak ≈ 2 × converted bytes**). `CONVERT_MAX_TOTAL_BYTES`
(4,000,000) is applied as a **PRE-CHECK on `BodyLength` before any `Body` is selected** — which is
the entire reason `AttachmentSelector` is split into a no-`Body` metadata method and a bodies method,
a split that must never be merged — and `CONVERT_HEAP_CEILING` (9,000,000) is re-checked before each
`VersionData` assignment. **A green Apex suite does not establish this arithmetic; only UAT U6 does.**

**(4) `MAX_ATTACHMENTS = 3` (was 10) AND THE CARRIER IS TEMPORARY.** Three per email caps
publications at 3 and `ContentDocumentLink` rows at 3 × 10 = 30; the fourth and later retainable
files are dropped and NAMED via `REASON_COUNT_CAP`. Every carrier row takes exactly one of four
exits — CONVERTED, RELEASED, RETRIED, EXPIRED (14 days) — and 🔴 **a deploy that does not schedule
`AttachmentCarrierSweepSchedule` silently disables the last two**, i.e. every retry in the design.
`Inbound_Email_Staging__c`'s **Notes & Attachments related list is therefore a WORKING SURFACE, not
decoration**: it is where a human recovers the bytes of a file that never converted, and without it
the whole recoverability story is theoretical.

**(5) REDELIVERY AND GATE SAFETY ARE STRUCTURAL, AND STILL DEPEND ON ONE LOCATION.** The file job is
enqueued only from `ExtractAddressQueueable.finish()`, and the duplicate-delivery guard returns
WITHOUT calling `finish()` — so a redelivery costs **zero** publications. It now also RELEASES the
duplicate's carrier, and a gated email (D2 / U2) releases its carrier instead of enqueueing, so the
pipeline's highest-volume junk costs zero publications and leaves zero residual bytes. 🔴 Anyone who
moves that enqueue out of `finish()`, or makes the skip path call `finish()`, silently re-opens
duplicate files on live Leads; there is no dedupe to catch it (decision E1, unchanged).

**(6) 🚩 THE OVERSIZED-EMAIL CLAIM LOSS IS STILL NOT FIXED AND IS NOT FIXABLE IN APEX.** An email
above the Email Service's own ceiling is rejected **above Apex**: no staging row, no Lead, no registry
claim, no audit — and a later broker with a smaller email wins the property outright. The only
mitigations are the in-org `Discard` → `Bounce` change (applied) plus a coordinator runbook. ⚠ And
**no Email Service setting covers a HANDLER-FAILURE path at all** — when the handler dies with an
uncaught `FATAL_ERROR`, `InboundEmailResult` is never returned and none of the five configurable
actions applies, so the `Bounce` change did **not** address the outage's invisibility; only the
three-transaction structure above does. Consequently **a blank `Dropped_Attachment_Notes__c` must
never be read as "the broker sent no attachment"**, and "no file on the record" is not evidence that
none was sent.

**INTAKE RULES V2 (added 2026-08-03) — two unconditional email-level rules ahead of the loop.**
Both run once per email, before `routeProperties`. Neither adds a query, a DML or any
configuration read: there is no Custom Metadata, no toggle and no threshold anywhere in this
feature.

1. **THE ENVELOPE SENDER IS THE BROKER (U1) — `ExtractAddressQueueable.applySenderFirstBrokerIdentity`.**
   🔴 **This rule only makes sense once the actual workflow is understood, so state it first:**
   EVERY inbound email reaches this pipeline as broker → DPEG's coordinator → the Salesforce email
   service. `EmailToLeadHandler` already separates the two roles on every staging row —
   `From_Address__c` is the **ORIGINAL SENDER (the broker)** and `Forwarded_By__c` is the
   coordinator. So the broker's identity is a **transport fact** already on the row, while the
   model's `broker_email` is a guess read out of prose. **When they disagree, the envelope wins,**
   and whoever the body named is demoted to `Listing_Broker_Name__c` / `Listing_Broker_Email__c`
   (fill-if-blank, per field). That is the reported defect: an email whose body named an
   offer-submission contact at a large firm produced a Lead **and a claim** for that person rather
   than for the broker who sent it.
   **Three guards, each a reason not to override:** no usable envelope sender (blank or malformed —
   `sanitizeEmail` rejects it); the **paste-forward guard**; or the model already named the sender,
   in which case nothing is demoted and the contact block (including U3's footer-extracted firm)
   survives untouched.
   ⚠ **The paste-forward guard is `From_Address__c == Forwarded_By__c`, and it needs no
   configuration.** `EmailToLeadHandler` falls back to the envelope From for BOTH fields when no
   forwarding header proves an original sender, so equality is the module's own tell that the
   "sender" is really *our own forwarder* — a pasted-in forward, or a message the coordinator
   composed. Promoting that address would credit DPEG's own staff with a broker's claim. The
   identical test already governed `applyEnvelopeEmailFallback`, so it is now expressed **once**,
   in `senderIsOurOwnForwarder()`, and both callers share it.
   ⚠ **Do not reintroduce a body-shape test.** An earlier draft gated U1 on "does the body look
   like a forward?" (a quoted `From:` block or a client separator). On this workflow that is
   **always true**, so it would never have fired and would have fixed nothing — the mistake is
   recorded here because the reasoning looks compelling right up until you check the data.
   On demotion `brokerPhone` / `brokerMobile` / `brokerTitle` are cleared (a colleague shares no
   direct line or title) and so is `brokerCompany`, **except when the two addresses share a
   domain** — same firm, so the company is correct for both and clearing it would lose an Account
   match for nothing. 🔴 Cross-firm the clear is mandatory: `brokerCompany` reaches `Lead.Company`
   → `LeadConvertMatchService.collectMatchKeys` → `AccountSelector.selectByNames`, so keeping it
   would attribute the deal to the **body-named contact's firm's Account**; dropping to
   `COMPANY_PLACEHOLDER` is correct because D1b deliberately excludes it from matching. Every
   discarded value is named in one `Deal_Notes__c` note — the only route back for a human. It **is
   an arbitration change** (`broker_email` drives repeat detection and
   `Competing_Broker_Submission__c.Broker_Email__c`) but **re-keys nothing**: `property_address` is
   untouched, so no `Property_Key__c` moves.
   ⚠ **Branch (b)'s second `findBrokerSubmission` lookup is NOT dead code — do not delete it.**
   Its guard `!fromAddress.equalsIgnoreCase(brokerEmail)` is now an exact complement of U1's
   applicability: **false** precisely when U1 applied (it set `brokerEmail := fromAddress`, so the
   first lookup already searches the envelope address), and **true** precisely on the
   **paste-forward** shape, where guard 2 skipped U1 and `brokerEmail` is still the body-named
   value. It is therefore as alive as paste-forwards are, and removing it would silently strip the
   envelope lookup from the only branch that still needs one.
   🔴 **RESIDUAL — BLAST PLATFORMS. "The envelope IS the broker" is NOT unqualified.** A broker
   submitting through RCM / Crexi / Buildout can arrive with an envelope From of the **platform**
   (`listings@buildout.com`), so U1 keys every broker on that platform to one identity. Two
   concrete failures: (a) two DIFFERENT brokers blasting THE SAME property through it —
   `findBrokerSubmission(platformAddress, thatProperty)` matches the first broker's row, so the
   second broker's genuine competing submission is filed as the first's **repeat** and they lose
   their claim record; (b) `Competing_Broker_Submission__c.Broker_Email__c` holds the platform
   address for everyone, so the adjudication record cannot say who submitted. Partially mitigated
   — `noreply@`-shaped platform senders are caught by `SENDER_CONTAINS` pre-callout, and the
   per-property comparison prevents cross-property damage — but `listings@`-shaped senders reach
   U1 untouched. **This is expected traffic:** the `Precedence: bulk` ruling calls a blast
   platform's listing announcement the highest-value email this pipeline exists to capture. The
   eventual fix is a platform-sender list that stands U1 down, never a body-shape heuristic.
   **Residual (accepted) — sending on someone's behalf:** an assistant emailing for a broker
   becomes the Lead and that firm's submissions fragment across addresses. Accepted because for an
   arbitration key **deterministic beats accurate-on-average** — an always-the-envelope rule can be
   audited and corrected; "usually the sender unless the prose suggests otherwise" cannot.
2. **A CALL-FOR-OFFERS EMAIL PRODUCES NO LEAD (U2) — `ExtractAddressQueueable.isCallForOffersGated`.**
   One condition: `email_category == 'call_for_offers'`. DPEG does not work marketed
   call-for-offers campaigns, so a Lead for one is never wanted. It mirrors the D2 hard gate
   exactly — `finish()` still logs the Task (mandatory: an unlogged Message-ID means a platform
   redelivery re-runs the whole pipeline) and `Extracted_JSON__c` is already written verbatim
   beforehand.
   🔴 **The staging row preserves the EMAIL. It does not preserve the CLAIM.** The row is never
   deleted and keeps the raw body, every RFC header and the complete extraction — every property
   named, verbatim. But **no Lead means no registry claim**: if a genuinely exclusive listing is
   confidently misclassified as `call_for_offers`, that property stays unclaimed, and a second
   broker who later submits it under any other classification **wins it outright**. Restoring the
   first broker's protection is **manual registry surgery**, not a staging re-read. So
   `Gated_Call_For_Offers` is an **active watch, not an archive** — a wrong call is only visible
   there and only reversible while the property is still unclaimed.
   ⚠ **Policy inconsistency, recorded rather than hidden:** D2's HARD gate — the module's *primary*
   relevance signal — requires `is_acquisition_related = false` **AND** `confidence >= 0.85`, while
   U2 hard-gates on the category alone with no confidence requirement, i.e. **stricter than the
   module permits for a stronger signal**. Accepted on the user's explicit instruction ("if email
   is related to call for offers then we must not store it as a lead, simple") because the business
   rule is categorical. Written down so a future reader treats it as a decision, not a defect to
   quietly "fix".
   ⚠ **`category_confidence` is parsed and stored but NOTHING GATES ON IT.** It is a new
   enriched-block prompt key (legacy constants untouched; no fixture pin re-pinned) that rides
   along in `Extracted_JSON__c` at zero runtime cost, kept solely as **tuning data** in case the
   suppression later proves too aggressive. If a threshold is ever introduced, gate on **that**
   field and never on `confidence` — `confidence` measures certainty about
   `is_acquisition_related`, and a call-for-offers blast **is** acquisition-related, so it carries
   no discrimination here at all. That is the same failure shape recorded above for the
   Opportunity deal-action gate.
   **Fails open by construction:** the parser coerces any unrecognised `email_category` to
   `'other'`, and a legacy-shape response (the one-line prompt rollback) carries none at all — so
   reverting the prompt silently **disables** this rule rather than stranding it on.
   **No claim is taken, and that is not a trade-off:** `Property_Registry__c.Winning_Lead_Required`
   forbids inserting a registry row without a Lead, and registering a blast would make the *first
   blast* the winner, sending a later broker with a genuine exclusive to branch (d) with no Lead —
   inverting the module's purpose. Label `OUTCOME_CALL_FOR_OFFERS = 'Not Routed (call for offers)'`;
   🔴 it must **not** start with `'Not Acquisition'` (that list view's filter) and **must** start
   with `'Not Routed'` (the `Gated_Call_For_Offers` filter).
   ⚠ **Still deliberately POST-CALLOUT.** The `SENDER_CONTAINS` prohibition on `Precedence: bulk`
   stands for the pre-callout filter and was amended, not contradicted: bulk mail must reach the
   LLM and be judged there, where a wrong call is visible, rather than vanishing as an
   unobservable lost claim.

**EAC CAPTURE PIPELINE (guard + adopter) — the repo's FIRST standard-object trigger driven by an
external capture system (guard added 2026-08-02; adopter added the same day).**
`triggers/EmailMessageTrigger.trigger` is one line delegating to `EmailMessageTriggerHandler`, which
enqueues **`EmailCaptureQueueable`** (renamed from `EmailThreadGuardQueueable` when the adopter
landed — a class named "guard" that also adopts is a trap for the next reader). That one job does
three things, in this order and for these reasons:

```
EmailCaptureQueueable.execute
  ├─ EmailThreadAnchorService.index(messageIds)   ← ONE anchor read, ONE normalization
  ├─ EmailThreadAdopterService.run(ids, index)    ← 1st: RelatedToId writes (own try/catch)
  └─ EmailThreadGuardService.run(ids, index)      ← 2nd: deletes (unwrapped — failures must be loud)
```

1. **ONE INDEX, BUILT ONCE.** Both services ask the same question of the same anchor data with
   opposite polarity, so sharing the index is what makes them normalize identifiers identically **by
   construction** rather than by convention. `EmailThreadAnchorService.index(Set<Id>)` exists
   specifically so the queueable holds no SOQL of its own.
2. **ADOPTER BEFORE GUARD — always, live and in any sweep.** An Opportunity-anchored capture related
   only to an unrelated same-address Lead is unanchored *on every Lead it lives on*; running the
   guard first deletes it seconds before the adopter would have rescued it (finding P6), and a
   deleted `EmailMessage` is not recoverable in Salesforce. The guard re-reads the messages, so it
   observes the `RelatedToId` the adopter just wrote and keeps the row through its widened guard 4.
   Pinned by `EmailThreadAdopterServiceTest.adoptedCaptureSurvivesAFullAdopterThenGuardPass`.
3. **THE ADOPTER'S FAILURE IS ISOLATED; THE GUARD'S IS NOT.** The adopter call is wrapped in its own
   `try/catch` so a new feature can never regress the deployed, destructive one. The guard is
   deliberately unwrapped — its failure surfaces as a failed `AsyncApexJob`, and a silently disabled
   guard is the failure mode the whole feature exists to avoid.
4. **THE ENQUEUE COUNT STAYS AT EXACTLY ONE PER TRIGGER CHUNK.** Both halves share the job precisely
   so the handler's cap math is unchanged; a second enqueue would halve the throughput ceiling that
   protects EAC's own insert. A future third EmailMessage concern belongs inside that queueable.

**The `RelatedToId` contention policy (D4)** is the adopter's whole decision surface, and the
overwrite row is the point of the feature, not an oversight: EAC arrives having already inferred an
Opportunity *thread-blindly through a matched Contact* (measured on both live captures), and address
inference must lose to header identity exactly as it does in the inbound routing tree. Leaving a
wrong Opportunity in place is worse than showing nothing.

| current `RelatedToId` | anchor resolves an Opportunity | action |
| --- | --- | --- |
| `null` | yes | **write** |
| an Opportunity, different | yes | **overwrite** |
| an Opportunity, equal | yes | no-op (convergence) |
| a **non**-Opportunity (Account, Case, `Property__c`, …) | yes | **leave alone** |
| anything | no | **leave alone — never write null** |

Plus the EAC fingerprint gate (companion `Task.CreatedBy.UserType == 'AutomatedProcess'`, the same
test guard 3 makes): a composer/Agentforce send's `RelatedToId` was chosen by a human.

**Adoption is CONVERGENT, which is why this feature ships no rollback code, no "adopted" marker
field and no Finalizer.** The target state is a pure function of (anchors, identifiers); a second
pass writes zero DML (`adoptionIsConvergent_secondPassWritesNothing`). Two consequences are written
into the class header as invariants: **(a)** adoption churns the companion Task, so an adopted
capture permanently loses the EAC fingerprint and is **adopted once** — known limitation L2 if EAC
ever re-points `RelatedToId` in place, remedied by the sweep; **(b)** the adopter performs **no Task
DML ever**, because the platform propagates `RelatedToId` onto the companion's `WhatId` itself
(measured, E2) and because a Task write would destroy the guard's structural-unreachability
guarantee.

**🔴 The P4 bracket defect this closed.** The pipeline stores `Thread_Key__c` **unbracketed**
(every `computeThreadKey` return path runs through `stripAngleBrackets`) and `Inbound_Message_Id__c`
**bracketed** (the raw header), while EAC supplies bracketed identifiers — confirmed on both live
anchor rows in `usman-dpeg` (experiment E3). The deployed guard compared raw values, so its
`ThreadIdentifier ↔ Thread_Key__c` leg could never match and it was **running on one leg**: a reply
whose thread root was logged as a mid-thread Task was deleted as unanchored.
`EmailThreadAnchorService.normalize` is now the only bracket handling in either feature, and
`TaskSelector.selectThreadAnchorsByAnchorValues` binds BOTH forms. Do not re-implement bracket
handling anywhere else.

**Two design steps were retired by experiment, not by opinion.** E1 (`Database.convertLead` on a
Lead carrying an anchor Task) measured that standard conversion repoints `WhoId` to the Contact
**and** stamps `WhatId` with the converted Opportunity on the pre-existing anchor — so the planned
conversion-time carry-forward was dropped, and D2's chain step 2 ("WhoId is a Lead → resolve through
conversion") is unreachable and unimplemented: an unconverted Lead has no Opportunity to adopt onto
and must fail closed anyway. Failing closed on a Contact `WhoId` is retained and load-bearing — one
Contact fronts many deals. `PropertyMatchingService.resolveLiveRecord` is deliberately NOT called
per anchor; it reads per Id, which would be SOQL-in-a-loop.

**Sweep discipline (D6).** Both services expose `run(Set<Id>)` for anonymous-Apex backfill.
Order is **adopter sweep → guard sweep**, chunk at **≤ 1,000 message Ids**, and run `LAST_N_DAYS:1`
first before widening. Convergence makes re-runs free; a guard sweep run first is not recoverable.

**🔴 R1 — OPERATIONAL: the adopter FAILS SOFT, so watch for silence (added 2026-08-02).**
`EmailMessage.RelatedToId` is the adopter's only write, and **`describe.updateable` reports TRUE for
it and is WRONG** — that flag is what let the feature reach a deploy before the problem surfaced.
Do not re-describe the field and call it verified. What is established is a *correlation*, not a
mechanism: the write **commits at runtime** (twice on `usman-dpeg` 2026-08-02 against real capture
`02siw0000005prVAAQ` — spike experiment 3a, set + revert, each readback-confirmed) but is **refused
from `@isTest` against a test-created capture** (7 probes + the deploy fingerprint, always
`INSUFFICIENT_ACCESS_OR_READONLY … fields=(RelatedToId)`; independent of Status, independent of
relations, and not a whole-record lock — `Subject` updates fine). The two runs differ in more than
one variable at once (test context *and* row provenance), so **which one is the mechanism is
undetermined** and neither should be quoted as settled. Insert-time seeding does persist.

The operational consequence: the adopter's entire failure surface is `allOrNone = false` plus a
`System.debug`. If the runtime write is ever blocked the way the test context blocks it, the result
is **zero adoptions and no durable signal** — no exception, no failed `AsyncApexJob`, nothing
queryable. So:

- **The L-check is RECURRING, not a launch gate.** The runtime proof ran as an *admin*; production
  runs as whichever principal EAC committed under, and that residual is only closed by observing
  real adoptions in the live pipeline.
- **The symptom to watch is "adoptions = 0 across a period in which real EAC captures arrived."**
  That is indistinguishable, from outside, from "nothing needed adopting" — which is exactly why it
  has to be watched deliberately rather than waited for.
- `EmailThreadAdopterService.lastRunFailureCodes` records the refusals but is **in-transaction only**
  and does not survive the job; it exists for tests and debugging, not monitoring.
- Tests therefore assert the **decision** (which rows, which target) through the `AdoptionWriter`
  seam rather than committed state. `platformRefusesTheRelatedToIdUpdate_isTheDocumentedQuirk` is a
  **two-way canary**: it reds on a *different* error, and it reds if the platform ever starts
  permitting the update — at which point the seam can be dropped and committed-state assertions
  restored.

Five things about the trigger differ from every other trigger in this repo and are load-bearing:

1. **The rows are not ours.** Einstein Activity Capture inserts them, in bulk, on its own schedule,
   as a principal none of this repo's permission sets provision. The handler therefore keeps the
   `Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()` check: EAC's batch size sets the
   enqueue count, and an uncaught `LimitException` would roll back EAC's own insert. Skipping is
   always safe because the guard is self-healing; throwing never is.
2. **The work MUST be async.** `EmailMessageRelation` rows — the record of which Leads a capture
   landed on — are written AFTER the `EmailMessage` in the same transaction, so a synchronous
   after-insert check would find none and make the guard a permanent no-op. The queueable hop is
   not a performance choice.
3. **Every selector read on this path is `WITH SYSTEM_MODE`**, which for this feature is a
   correctness requirement rather than a convenience: `USER_MODE` THROWS (it does not degrade) the
   moment the automated principal lacks FLS, killing the queueable and silently disabling both
   halves while EAC keeps polluting timelines. Same automation-path reasoning as
   `LeadSelector.GuestReads` / `GroupMemberSelector`. ⚠ This makes the `TaskSelector` header's
   former claim "there is NO guest/automation path on Task" obsolete; it has been amended in place,
   and the class now mixes USER_MODE with SYSTEM_MODE deliberately. ⚠ **Amended 2026-08-05:** that
   mix is no longer "the two EAC methods vs. everything else" — the two rollup-recompute reads
   (`selectByTransactionDealIds`, `selectByOnboardingIds`) joined the SYSTEM_MODE group for the same
   automation-path reason, so the class carries **four** SYSTEM_MODE methods. Only the Transaction one
   is trigger-driven (`TaskRollupTrigger`) and only it fixes an observed failure; the Onboarding one is
   called directly and is prospective. The authoritative inventory is the `TaskSelector` class header;
   the reasoning is in the automation-path table under _Standards_ above.
   `selectThreadAnchorsByAnchorValues` **replaced `selectThreadAnchorsByWhoIds`** when the adopter
   landed: the guard could scope by the Leads a capture was related to, but the adopter asks the
   opposite question ("which record does this thread belong to?") and has no record set to scope by
   — the anchor is what NAMES the record. One query serves both; it stays selective because both
   anchor fields are indexed External Ids. It also selects `WhatId`, which is the adopter's entire
   resolution chain. `EmailMessageSelector.selectByIds` was widened with `RelatedToId` (the
   adopter's write target and contention input, and the guard's widened guard-4 input) — that field
   set carries a **DO NOT NARROW** contract.
4. **Broker Protection's own pipeline Tasks are structurally out of reach.** The guard has exactly
   one route to a Task — the Id on `EmailMessage.ActivityId` — and pipeline Tasks written by
   `InboundEmailActivityService` are linked to no `EmailMessage` at all. The anchors the module
   depends on therefore cannot be deleted by construction, not by convention
   (`EmailThreadGuardServiceTest.pipelineAnchorTaskIsStructurallyUnreachable` pins this). Anyone
   adding a second route to a Task destroys that guarantee. **The adopter does not weaken it:** the
   anchor read feeds keep/adopt decisions only, its rows never enter a delete list, and the adopter
   performs no Task DML at all.
5. **⚠ THE CONDITION IS LEAD-SCOPED; THE REMEDY IS ORG-WIDE.** Deleting an `EmailMessage` removes it
   from *every* record it was associated with, so "scope is Leads only" is a claim about what the
   guard JUDGES, not about what a delete TOUCHES. Reconciling the two is review finding W1
   (2026-08-02): the guard now deletes a capture only when it relates to **no record outside
   `{Lead, User}`**. `EmailMessageRelationSelector.selectByMessageIds` therefore returns *every*
   relation type (it is deliberately no longer Lead-filtered — the service must SEE a Contact
   relation to protect it), and the Lead scoping happens in explicit Apex.
   **`User` is excluded from "lives elsewhere" and that exclusion is load-bearing:** EAC writes a
   User relation for the mailbox participants on essentially every capture, so counting it would
   make the guard delete nothing, ever — a dead feature that still passes a smoke test. The
   classification is an allow-list of ignorable types, so an unanticipated object type fails safe
   (capture kept). Pinned by the matched pair
   `captureAlsoLivingOnAContactIsKept` / `captureLivingOnlyOnLeadAndUserIsStillDeleted`, which
   discriminate in opposite directions.

The `.claude/rules/bulk-test-rule.md` per-transaction-singleton exemption does **not** cover either
service: both are trigger-driven and EAC batch-inserts, so a literal 251-record bulk test exists for
each — `EmailThreadGuardServiceTest.guardAt251Captures_isBulkSafe` (one bulk `EmailMessage` insert,
one `run()` call) and `EmailThreadAdopterServiceTest.adopterAt251Captures_isBulkSafe` (one bulk
insert driven through the REAL trigger path, asserting all 251 adopted, all 251 surviving the guard,
a CONSTANT 7-query budget for the whole execution and exactly ONE adopter DML statement). Note also
that the legacy "only 1 queueable per test transaction" rule does not hold in this org — the cap is
50, as `ExtractAddressQueueableTest`'s 25-job test already demonstrates.

⚠ **Governor assertions read `EmailCaptureQueueable.lastRunQueryCount` /
`EmailThreadAdopterService.lastRun*`, never `Limits.*` after `Test.stopTest()`** (stopTest restores
the pre-test counters, making the obvious assertion silently vacuous) — the
`ExtractAddressQueueable.lastRunQueryCount` precedent. A second, subtler trap is recorded in
`EmailThreadAdopterServiceTest`'s header: inserting an `EmailMessage` in a test fires the real
trigger, so a real `EmailCaptureQueueable` runs at `stopTest()` and overwrites those statics with
its own convergent (zero) pass — counter assertions must snapshot into locals *inside* the test
block.

**Broker Protection async-pipeline exception — ⚠ NARROWED 2026-07-31 (design C-18).** It once
covered `EmailToLeadService`, `LLMExtractionCalloutService`, `PropertyMatchingService` and
`PropertyClaimService` on the premise that each is single-record-per-transaction — "one inbound
email produces exactly one Lead and one `ExtractAddressQueueable` execution, with no trigger and no
loop over multiple records" (code-review-approved 2026-07-24; see
`docs/2026-07-24-broker-protection.md`).

**That premise died with D1 multi-property extraction.** `ExtractAddressQueueable.execute` now
LOOPS, and `PropertyClaimService.claim` / `EmailToLeadService.createLeadFromExtracted` are invoked
**N times per transaction** (N ≤ `ExtractAddressQueueable.MAX_PROPERTIES` = 10). The exemption
therefore now applies to **`LLMExtractionCalloutService` ONLY** — still exactly one callout per job.

**What replaces it for the reshaped classes:** a literal 251 remains both impossible and
meaningless here — `System.enqueueJob` caps at 50 per transaction, and 251 properties in one email
would exhaust SOQL at ~14–24 — so the mandate is replaced by explicit **volume and
governor-headroom tests**: a 10-property email, a 15-property truncation case, a mixed-outcome
email, lock-order determinism, and assertions on the query/DML counters the queueable records at
the end of `execute()` (`lastRunQueryCount` / `lastRunDmlCount`). Those counters are captured
inside the async context on purpose: `Test.stopTest()` restores the pre-test limit counters, so a
`Limits.getQueries()` assertion written after it would be silently vacuous. See
`.claude/rules/bulk-test-rule.md` and `agent-output/design-requirements.md` §7.

The narrowed exemption still does not relax the "no SOQL/DML in loops" rule, which these classes
continue to satisfy — every statement is one-per-property and the Task insert is bulked into a
single DML. `CompetingSubmissionController`
(the Lead-record-page read surface for this feature) is a thin `@AuraEnabled(cacheable=true)` controller
over `CompetingBrokerSubmissionSelector` — no service layer was needed, per the P6 read-only-controller
precedent below.

**Opportunity deal-action gate is TWO-FACTOR — do not "align" it with the Lead gate (added
2026-07-30):** `OpportunityActionPermissionService` asks the identical question the six deployed
Dynamic Actions visibility rules on `Opportunity_Record_Page` ask — `{!$User.Deal_Driver__c} EQUAL
true` — which requires BOTH **(a)** FLS read on `User.Deal_Driver__c`, granted only by the
`Acquisition_Deal_Driver` permission set and enforced by `WITH USER_MODE` inside `UserSelector` (a
user without that FLS makes the query THROW, which the service converts to `false`), AND **(b)** the
field value `Deal_Driver__c = true` on the running user's own User record.

This is why it does **not** reuse `LeadActionPermissionService.hasAnyPermissionSet(...)`, tidy as
that would look: **membership and the flag are different questions.** A user holding
`Acquisition_Deal_Driver` with `Deal_Driver__c = false` is denied today and would be GRANTED by a
membership check — a silent widening of a live authorization boundary. Adding a permission-set name
to this gate does not "also" grant access, it REPLACES a two-factor condition with a one-factor one
for every holder. `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied`
exists to go red if anyone tries.

⚠ **The "Modify All Data" bypass is load-bearing, not a convenience, and its ORDER matters.**
Measured on `usman-dpeg` 2026-07-30: a **System Administrator has no FLS read on
`User.Deal_Driver__c`** — Metadata-API-deployed custom fields arrive with no field permissions for any
profile, and Modify All Data is an OBJECT permission that confers no FLS. The selector therefore
throws for a bare admin exactly as it does for a bare Standard User, so the Modify All Data check
MUST run before the flag read or every administrator is locked out of the feature they just deployed.
Corollary for UAT: **an admin smoke test proves nothing about this gate** — acceptance-test as a real
deal-driver persona, and remember FLS truth lives in the org, not this repo (profiles are
`.forceignore`d).

**`StageAdvanceService.advanceTo` now has an explicit-target allow-list (added 2026-07-30).** It
previously wrote any non-blank string handed to it, so a direct `@AuraEnabled` call could move a deal
to ANY stage — `Closed Won` included — skipping every hop in `NEXT_STAGE` and the signed-NDA gate with
it. Membership is limited to the branch/off-ramp targets that legitimately have no derivable
predecessor: `Development Review`, `Construction Review`, `About to Close`, and `Dead/Pass`
(pre-authorized for the future off-ramp action). Derivable forward hops stay out on purpose — they
belong to `advance()`, which reaches them through `NEXT_STAGE` and so cannot skip a step. Adding a new
explicit-target action means adding its stage to that set. Values are the **decoded** runtime strings:
`Dead/Pass` is `Dead%2FPass` in BusinessProcess/picklist metadata only.

### Controller-support services (P6, completed 2026-07-19)

The **P6 controller-thinning sweep** brought every `@AuraEnabled` controller into layering conformance: business logic and DML were extracted into a per-controller service, and each controller became thin (marshal → delegate → `catch` → `AuraHandledException` via the repo-standard `ahe()` helper). Read-only controllers with no logic to extract (`LeadFunnelController`, `OpportunityDocStatusController`, `OpportunityFunnelController`, `RentRollController`, `SellMeterController`, plus the `TransactionController` / `WorkOrderController` boundary-hardening) kept no service — they received only the `AuraHandledException` boundary. **These services own controller-invoked orchestration only; SOQL still lives in selectors and none of them holds cross-object trigger/flow logic** (that stays in the Key Apex Services above). Every touched class is ≥90% covered; the full suite is 636 tests / 0 failures on DPEG-Acq-5.

The 13 services introduced by P6, each invoked from its like-named controller:

`LeaseInquiryService`, `BrokerAssignmentService`, `DispositionService`, `DispositionTaskService`, `WireService`, `CounterOfferService`, `PsaVersionService`, `StageAdvanceService`, `TransactionTaskService`, `OnboardingService`, `LeaseRenewalService`, `DealMessageService`, `BrokerPortalService`.

**`BrokerPortalService` is `without sharing`** — it mirrors the guest `BrokerPortalController` so the public Broker-Portal Lead insert runs in the identical guest context; the anti-abuse dedup reads remain in `LeadSelector.GuestReads` / `ContactSelector.GuestReads` (`WITH SYSTEM_MODE`) and were not moved. Its `without sharing` is justified in the class header per the Standards rule above. All other P6 services are `with sharing`.

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

### 3.3 Deliberate, Temporary Exception — Direct OpenAI Callout (Broker Protection)

Broker Protection's LLM field-extraction step (`LLMExtractionCalloutService`) calls OpenAI **directly**
via an `OpenAI_API` Named Credential + `OpenAI_Credential` External Credential, bypassing §3.1's
ASB-only rule. This is intentional and temporary: **no ASB LLM-extraction spoke exists yet**, so there
is nothing on the bus to route to. The exception is scoped and reversible — only the endpoint constant
(and the Named Credential it targets) change when ASB exposes an LLM-extraction spoke; the public
`extract(...)` signature and every downstream caller stay identical. Credentials are never hardcoded —
the API key lives entirely in the `OpenAI_Credential` External Credential's `NamedPrincipal`
authentication parameter, entered in Setup **post-deploy**. Full justification is in the class header
of `LLMExtractionCalloutService.cls`; see `docs/2026-07-24-broker-protection.md` for the complete
feature writeup.

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

> ✅ **LWC `apiVersion` is now 67.0, matching the rest of the repo (uplifted 2026-07-18, commit `949e710`, verified against the Phase 8 Jest net).** The sole exception is `lwc/leaseNegotiationLog`, left at 62.0 pending its in-flight feature merge. New LWCs should be authored at 67.0.

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

### Confirmation dialogs and permission gating (headless quick actions)

Added 2026-07-29 with the Lead stage quick actions (`leadConvertAction`, `leadMarkUnderReview`,
`leadMarkQualified`, `leadDisqualify`, sharing `c/leadStatusChange`). Extended 2026-07-30 to the
Opportunity stage quick actions (`advanceDealStage`, `dealSendToDevelopmentReview`,
`dealSendToConstructionReview`, `dealMoveToAboutToClose`, `submitForApproval`, sharing
`c/dealActionGuard`). Extended again 2026-08-04 to the five stage-controlled acquisitions CHILD
objects — one bundle, `advanceRecordStage`, backing one quick action each on `NDA__c`, `LOI__c`,
`Underwriting__c`, `Construction_Feasibility_Review__c` and `Development_Feasibility_Review__c`,
sharing `c/recordStageGuard`.

**There are THREE guard utils and they must not be merged.** `c/leadStatusChange` is Lead-bound by
contract (it imports `Lead.Status` schema and `LeadActionPermissionController`);
`c/dealActionGuard` is the guard/confirm HALF of it, object-agnostic, and carries **no write helper at
all**; `c/recordStageGuard` (2026-08-04) is the same guard/confirm half again, but its permission
question is **PER-RECORD**. That asymmetry is deliberate and load-bearing:

| | Lead status actions | Opportunity stage actions | Child-object stage action |
| --- | --- | --- | --- |
| Write path | LDS `updateRecord` | imperative Apex (`StageAdvanceController` / `OpportunityApprovalController`) | imperative Apex (`RecordStageAdvanceController`) |
| `getRecordNotifyChange` | **MUST NOT** call it — `updateRecord` writes THROUGH the LDS cache, so the Path/highlights re-render on their own | **MUST** call it on success — Apex DML happens behind LDS's back, so without it the Path shows a stale stage | **MUST** call it on success — same reason |
| Server-side enforcement | Convert only; the three status writes have no Apex in their path, so CRUD/FLS on `Lead.Status` is the real control | **every** action asserts the permission server-side | asserts the permission server-side |
| Permission call shape | Lead-bound, no argument | **no argument** (`hasDealActionAccess()`) | **takes a `recordId`** (`hasStageActionAccess(recordId)`) — the server dispatches to the object's own gate |

Opposite requirements. Do not "harmonize" them. Each bundle keeps ownership of its own Apex call,
toasts, and `getRecordNotifyChange`; the guard only decides whether the click proceeds.

⚠ **The per-record permission signature is the concrete reason `c/recordStageGuard` cannot just reuse
`c/dealActionGuard`**, even though all five child objects currently answer to the *same* deal-driver
gate. `hasDealActionAccess()` takes no argument and so cannot express "which object's gate?". Putting
the dispatch on the server from day one is what makes a future differently-personed object a config
line rather than a rewrite of every bundle.

⚠ **Neither `advanceDealStage` nor `advanceRecordStage` can name its target stage in the prompt.**
Each backs several actions whose target is derived server-side (`StageAdvanceService.NEXT_STAGE` /
`RecordStageAdvanceService`'s per-object maps), so both confirmations are deliberately generic
("Advance this deal to the next stage?" / "Advance this record to the next stage?"). Do **not**
`@wire getRecord` the stage and compute a nicer label — that duplicates the Apex map in JS, where it
will drift. For `advanceRecordStage` it would be **five** maps, and the stage FIELD itself differs
per object (`NDA__c` uses `Status__c`), so the wire would need a per-object branch before the maps
even started drifting. If one action needs specific wording, split that action into its own bundle.

- **Confirmations use `lightning/confirm` (`LightningConfirm.open()`), never a toast.** A toast is
  fire-and-forget and returns nothing, so it cannot carry a yes/no answer. `LightningConfirm.open()`
  returns `Promise<boolean>` and renders into the platform's modal layer, which is what makes it the
  only confirmation available to a HEADLESS quick action (`actionType: Action`, empty template).
  Toasts remain correct for the success/error messages that follow.
- **A headless quick action cannot be visually disabled from its own code.** It owns no button
  markup — the platform's action bar renders the button — so there is no `disabled` attribute to
  set. Hiding or graying an action for unauthorized users is a **Dynamic Actions visibility rule**
  in App Builder (declarative), which needs a **Custom Permission** to bind to; the component
  enforces the same rule at click time. Treat the two as complementary, not alternatives.
- **Permission gating order is: check permission → confirm → act.** Never ask a user to confirm an
  action they are not permitted to take. The client-side check is a UX gate; any action with an Apex
  path must ALSO assert server-side (see `LeadConvertActionController`), because a client check is
  bypassed by calling the `@AuraEnabled` method directly. Actions that write via LDS `updateRecord`
  have no Apex in their path at all — CRUD/FLS is their only real enforcement.
- A failed permission lookup **fails closed** (treated as denied), never open.

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
