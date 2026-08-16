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

**†** marks a row that carries _Purpose_ prose despite the object having **no `<description>`**. That text is **authored inference, not condensed source** — do not cite it as authoritative; write the `<description>` and then condense it here. The arithmetic reconciles: 18 dashed rows + 4 inferred rows (†) = the 22 unset. (It was 20 + 2 until Tranche 5A gave `Property_Asset__c` an automated creator and therefore a † row, then 19 + 3 until FSD tranche 1 gave `Offering__c` one on 2026-08-16. In both cases the object's `<description>` is still unset and writing it is admin work, so the count of unset objects is unchanged at 22.)

**Acquisitions** — the deal tree, rooted on `Opportunity` / `Property__c`

| Object                               | Parent (lookup)                                   | Purpose                                                                                             |
| ------------------------------------ | ------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `Property__c` **†**                  | — (graph root)                                    | The acquisition target. Created on lead conversion by `LeadConvertService`. **Extended 2026-08-11 (SharePoint deal folder):** it carries the feature's ENTIRE result state in four new fields — `SharePoint_Folder_ID__c` (Text 255), `SharePoint_Folder_URL__c` (Url), `SharePoint_Folder_Status__c` (restricted Picklist: Pending / Created / Failed / Skipped) and `SharePoint_Folder_Error__c` (Long Text 4096). 🔴 **The state lives on the PROPERTY, not the Opportunity, and that is the idempotency key**: two deals closing against one property share one folder, matching `PropertyAssetService`. `SharePoint_Folder_ID__c` non-blank means ZERO callouts on every path. `SharePoint_Folder_Status__c` is a THIRD work queue in this repo, after `Inbound_Email_Staging__c`'s two — `Pending` and `Failed` are `DealFolderSweepBatch`'s queue, `Created` and `Skipped` are terminal and excluded by the locator. ⚠ A deal with a null `Property__c` has nowhere to record any of this and is skipped silently (`DealFolderService` residual R1), and a Property never claimed by the trigger has a NULL status, which is invisible to the sweeper (residual R5 — historical deals). |
| `LOI__c`                             | `Opportunity`, `Property__c`                      | —                                                                                                     |
| `Counter_Offer__c`                   | `LOI__c`                                          | —                                                                                                     |
| `Underwriting__c`                    | `Opportunity`                                     | —                                                                                                     |
| `Development_Feasibility_Review__c`  | `Opportunity`, `Property__c`                      | —                                                                                                     |
| `Construction_Feasibility_Review__c` | `Opportunity`, `Property__c`                      | —                                                                                                     |
| `Contract_Review__c`                 | `Opportunity`                                     | —                                                                                                     |
| `PSA_Version__c`                     | `Contract_Review__c`                              | One PSA draft/counter exchanged during negotiation; the full set is the version history.             |
| `Deal_Message__c`                    | `LOI__c`, `Underwriting__c`, `Contract_Review__c` | Append-only logged communication in a deal negotiation. Child of exactly one of the three parents.   |
| `Offering__c` **†**                  | `Opportunity`                                     | The Investor Relations handoff artifact for an acquisition. **Created automatically by `OfferingService` when an acquisition PSA is EXECUTED (FSD tranche 1, 2026-08-16).** 🔴 **Nothing created one before — measured repo-wide: zero Apex creators, zero Flow creators, and the object's only non-metadata reference was `TestDataFactory.createOfferings`.** IR was already notified at contract execution ("PSA executed — IR phase begins") and handed nothing to work from. Idempotent on `Opportunity__c` ALONE, with no `Status__c` filter. ⚠ **`IR_Owner__c` is left NULL and is not derivable** — it is a `User` lookup while `Investor_Relations` is a public GROUP, and nothing in the schema names "the IR owner"; picking a group member is non-deterministic and a custom-setting default is not deployable. 🔴 **IR VISIBILITY IS THEREFORE NOT A PROPERTY OF THE OBJECT'S OWNERSHIP AND WAS CLOSED SEPARATELY (Gate 1 Q1.2(b), 2026-08-16): `DPEG_IR_Edit` (Read + Edit, `allowCreate`/`allowDelete` deliberately FALSE so IR cannot bypass the one-shell idempotency), `DPEG_IR_View` (read-only twin), and — because object permissions alone grant no record access on a Private-OWD object — the `Offering_IR_Visibility` OWNER sharing rule, sharing rows owned by `roleAndSubordinates Acquisitions_Analyst` to the `Investor_Relations` group. Neither set carries `viewAllRecords`.** ⚠ **Its residual is a real path: an Offering created by a principal, an administrator running UAT, or anyone in the `Investor_Relations_Manager` / `Transactions_Coordinator` role branches is NOT shared to IR — silently.** That is a user decision with a named remedy (an always-true criteria rule), stated in the sharing-rules file's own comment. Post-deploy gate **G4** stands regardless: verify by opening one AS AN IR USER, never as an administrator, and remember group/role membership is not deployable metadata. ⚠ `Status__c` is set EXPLICITLY to `Draft`, never inherited from the picklist's own `<default>`. ⚠ **There is deliberately no `Opportunity.Primary_Offering__c` and one must not be added for symmetry with `Primary_LOI__c`** — nothing resolves an Offering, the `Offerings` child relationship already gives the related list, and a parent stamp would import the whole approval-lock / deferred-stamp analysis for no benefit. ⚠ **Nothing advances `Status__c` past `Draft`** — the object has no record page, no Path and no lifecycle automation; "the Offering never leaves Draft" is a named state of that tranche, not a defect in it. |
| `NDA__c` **†**                       | `Opportunity`, `Disposition__c`                   | Spans Acquisitions **and** Disposition.                                                              |
| `SharePoint_Config__c` **(Custom Setting — NOT one of the 33 custom objects)** | — (hierarchy custom setting; org default only) | **The SECOND Custom Setting in this repo** (added 2026-08-11), following `Content_Publication_Budget__c` exactly. Holds the deal-folder integration's destination and master switch (`Is_Enabled__c`, `Site_ID__c`, `Drive_ID__c`, `Parent_Folder_ID__c`). Chosen over a custom object for the same reason as its precedent — `getOrgDefaults()` costs **0 SOQL** — which matters more here, because `SharePointConfig` is consulted on the CLOSED WON path inside an after-update trigger. Custom Metadata was eliminated by MEASUREMENT, not preference: CMDT *record* deploys fail in this org with `UNKNOWN_EXCEPTION` and need an Apex loader (recorded in `RecordStageAdvanceService`'s header). ⚠ **Custom-setting DATA is not deployable** — there is no org-default row in source control and there never will be. 🔴 **Unlike `ContentPublicationBudget`, this class does NOT create one at runtime and MUST NOT**: an auto-created row would be disabled and site-less, i.e. exactly the state `isReady()` already reports without writing anything, and a silent site-id default is how production deal documents end up in a POC library. Populating it is a named POST-DEPLOY GATE. Only the ORG DEFAULT is ever read; a per-user override would let two users write deal folders into two different libraries with no reader able to tell. ⚠ Every reader is STATICALLY typed (`config.Site_ID__c`, never `config.get('Site_ID__c')`) — the reflection was removed 2026-08-11 because a renamed field would have compiled, returned null through the catch, and left `isReady()` reporting `true` while the feature made zero callouts. |

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
| `Property_Asset__c` **†** | `Property__c`                    | The ROOT of the whole Property Management module — every object below it, plus `Disposition__c`, parents to it. **Created automatically by `PropertyAssetService` when an acquisition deal enters `Closed Won` (Tranche 5A, 2026-08-10).** Before that nothing in the application created one: every asset in the org came from a seed script, which is why the behaviour looked automatic. |
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
- **⚠ Permission set metadata deploys REPLACE, not merge, their `<fieldPermissions>` set.** A `PermissionSet` deploy overwrites the org's entire field-permission list for that set with exactly what the file declares — an org-side-only FLS grant that isn't represented in the file **will be silently wiped by the next deploy of that same file**, even one made for an unrelated reason. This bit Broker Protection twice, 2026-08-05 and again 2026-08-06 (`Broker_Protection_Access.permissionset-meta.xml`'s own XML comment carries the full incident writeup): an org-side-only `Task.WhoId` grant, created by hand to unblock the live pipeline, was wiped by a later deploy of the same file made for an unrelated field-casing fix, and every inbound email routing to a Lead or Contact then threw `System.DmlException | Operation failed due to fields being inaccessible on Sobject Task` until the field was declared in-file. **Any FLS grant that matters must be declared IN the permission set file** — "keep it org-side so a redeploy can't disturb it" is exactly backwards. This trap is especially sharp in this repo because `profiles/**` is `.forceignore`d, so a profile-level FLS gap is invisible to any file-based check and the only defensible place to declare a grant is a permission set that is actually in source. **⚠ The identical hazard applies one layer up, to a `PermissionSetGroup`'s membership list, not only to a `PermissionSet`'s own grants — found during the 2026-08-10 permission set cleanup, one day after a clean 2026-08-09 reconciliation.** `DPEG_Admin_Access` carried six `recordTypeVisibilities` live in `usman-dpeg` and absent from the repo file; separately, a deployed group was found carrying a member the repo copy of that group does not list, which a deploy would have revoked for every user in the group. Reconcile group membership against the org before deploying a `PermissionSetGroup`, exactly as for a `PermissionSet`'s grants — see the Permission Set Architecture subsection below for the full model and both findings.

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
As of 2026-08-16 (FSD gap tranche 1) the repo has **34 `WITH SYSTEM_MODE` queries across 20 selector
classes.** Tranche 1 added two: `OfferingSelector.selectByOpportunityIds` (a brand-new class — the
FIRST and only `Offering__c` SOQL in the application, one method, `SYSTEM_MODE` only, and it also
needs `without sharing`) and `NdaSelector.queryExpiryAlerts` (taking that class to two `SYSTEM_MODE`
methods against **FIVE** `USER_MODE` ones — seven public methods in all — and giving it its FIRST
`private without sharing` inner class — `ExpiryAlertReads`, deliberately NOT shared with
`selectByDispositionIds`, which stays sharing-scoped and argues why at its own declaration).
⚠ **That `USER_MODE` figure read "four" until 2026-08-16 (code review W4) and was wrong, as was the
2026-08-09 sentence further down that first said it** — see the note below the 2026-08-09 entry. The
count matters more than it looks precisely because the paragraph above declares the selector class
headers, not this table, to be the authoritative inventory: a wrong count here is what a future
reviewer reconciles a correct header against, and then "fixes" the header. Verified by enumeration
against `NdaSelector`'s method list and its `WITH` clauses, not carried forward from this paragraph.
⚠ **THE THIRD OF THE THREE IS A CORRECTION, NOT AN ADDITION, AND IT IS RECORDED RATHER THAN QUIETLY
FOLDED IN: the 2026-08-14 call-for-offers alert added `OpportunitySelector.queryCallForOffersAlerts`
and never updated this paragraph.** So the arithmetic from the last recorded figure is 31 → 32 (that
un-recorded entrant) → 34 (tranche 1), and the CLASS count moved by one, not two, because
`OpportunitySelector` and `NdaSelector` were already here. Its row is added to the table below in
this change for the same reason. Do not reconcile a future count against 31.
🔴 **AND THE SAME TRANCHE LEFT A SECOND, LARGER §6 DEBT THAT IS **STILL OPEN** — recorded here on
2026-08-16 (code review S2) because it existed only in an agent report and would otherwise have died
with that conversation.** `CallForOffersService`, `CallForOffersAlertBatch` and
`CallForOffersAlertSchedule` are **absent from the _Key Apex Services_ table below** — all three, not
just the selector method above — even though `NdaExpiryService` / `NdaExpiryAlertBatch` /
`NdaExpiryAlertSchedule` were written as their deliberate mirror and cite them by name for `SCOPE`,
for the recipient group and for the send-then-stamp order. So the doc currently describes the COPY
and not the ORIGINAL, which is the worst way round: a reader following the NDA rows' citations lands
on three classes the table says nothing about. ⚠ **Deliberately OUT OF SCOPE for FSD tranche 1** —
back-filling three rows to this document's standard is its own change, and doing it inside a review
pass would have buried it. ⇒ Whoever next touches the call-for-offers feature adds those three rows
in the same PR, per §6.

🔴 **A THIRD §6 DEBT, FOUND THE SAME REVIEW PASS AND LEFT DELIBERATELY OUT OF SCOPE — recorded here
on 2026-08-16 (FSD gap tranche 1 code review) for the identical reason as the debt immediately above:
it exists only in the review record and would otherwise die with that conversation.** `LoiSelector`'s
own class header is **wrong about its own `SYSTEM_MODE` count, in two places, and contradicts
itself.** Verified against the file 2026-08-16: the class has **SEVEN** public methods —
`selectById`, `selectLatestByOpportunityId`, `selectOpportunityIdRequiredById`,
`selectStageRequiredById` and `selectByOpportunityIds` are `WITH USER_MODE` (**five**, not four);
`selectNegotiationContextById` and `selectByDispositionIds` are `WITH SYSTEM_MODE` (**two**, not
one, and not zero). Two sentences in the header are false as a result: the class-level summary
("USER_MODE … on four of the six methods") is wrong on *both* numbers — five of **seven**, not four
of six — and `selectNegotiationContextById`'s own doc comment ("WITH SYSTEM_MODE, AND IT IS THE ONLY
QUERY IN THIS CLASS THAT IS … the other four methods stay WITH USER_MODE") directly contradicts a
separate, correct sentence three lines above it in the *same header* ("MIXED MODES SINCE 2026-08-09:
`selectNegotiationContextById` and (since 2026-08-10) `selectByDispositionIds` are `WITH
SYSTEM_MODE`") — so the file disagrees with itself about whether it has one escaping method or two.
This is the identical failure shape `NdaSelector`'s header carried before the W4 fix earlier in this
same pass (a stale count copied forward into a class-level summary and never reconciled against the
method list), on a sibling selector nobody happened to be reading this time. **Deliberately OUT OF
SCOPE for FSD tranche 1** — it is a pure-comment fix (no Apex logic, no metadata, zero deploy risk),
found while reviewing an unrelated feature, and is not part of this tranche's ask. ⇒ Whoever next
touches `LoiSelector` corrects both false sentences to five `USER_MODE` / two `SYSTEM_MODE` across
seven methods, in the same PR, per §6.
As of 2026-08-11 (SharePoint deal folder) it was **31 `WITH SYSTEM_MODE` queries across 19
selector classes** — the count of QUERIES moved and the count of CLASSES did not, because both
entrants landed on the incumbent `PropertySelector`, taking it from one `SYSTEM_MODE` method to
three and giving it a SECOND `private without sharing` inner class (`FolderCreationReads`, alongside
`AssetCreationReads` — deliberately separate, so a future read cannot borrow whichever argument
happened to be written first). As of 2026-08-10 (Tranche 5B) it was **29 across 19**. Tranche 5B
added three across two new entrant classes and one incumbent:
`DispositionOfferSelector` (a brand-new class: the FIRST and only `Disposition_Offer__c` SOQL in the
application, one method, `SYSTEM_MODE` only, and the only one of the three that also needs
`without sharing`), `BrokerListingSelector.selectByDispositionIds` (its ONE `SYSTEM_MODE` method
against one `USER_MODE` one) and `DispositionSelector.selectListingClockByIds` (taking that class to
two `SYSTEM_MODE` against three `USER_MODE`). Earlier the same day (Tranche 5A) it was **26 across
17** — the entrants then were `PropertySelector` (a brand-new class: the FIRST and only
`Property__c` SOQL in the application, one method, `SYSTEM_MODE` only) and `PropertyAssetSelector`,
whose `selectByPropertyIds` is its ONE `SYSTEM_MODE` method against three `USER_MODE` ones. Earlier
still it was **24 across 15** — `OpportunitySelector` contributes exactly one
(`selectCallForOffersTargetsByIds`), the first `SYSTEM_MODE` query against `Opportunity` in this
table. As of 2026-08-09 it was **23 across 14** (`NdaSelector` was the newest entrant then,
contributing exactly one — `selectByDispositionIds` — against its **FIVE** `USER_MODE` methods, so
its A1-era header claim "no SYSTEM_MODE / guest path" is now false and has been amended in place).
⚠ **This sentence read "four" and was WRONG WHEN WRITTEN, not merely overtaken — corrected in place
2026-08-16 (code review W4) rather than left standing.** `NdaSelector` already held
`selectById`, `selectLatestByOpportunityId`, `selectLatestByDispositionId`, `selectByOpportunityIds`
and `selectStageRequiredById` on 2026-08-09 (verified against the committed file at that revision).
The wrong number was then copied forward into the tranche-1 paragraph above and into the class
header, which is the whole reason a stale count is worth correcting rather than tolerating: nobody
re-derives a number that three places agree on. As of
2026-08-08 it was **22 across 13** (up from
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
| **Permission-gate reads** (moved from USER_MODE **2026-08-03**) | the running user, reading their OWN grants | `PermissionSetAssignmentSelector` (all four gates, bypass path only), `PermissionSetGroupComponentSelector` (**the LEAD gate only** since 2026-08-12) | a `Minimum Access` persona threw on the very read that decides whether they may act — **the closest prior art to the rollup entry below**. ⚠ **`PermissionSetGroupComponentSelector`'s consumer set NARROWED on 2026-08-12**: the Transaction gate used to reach it through `LeadActionPermissionService.hasAnyPermissionSet`, which expands permission set GROUPS in Apex to answer a membership question. It now calls `FeatureManagement.checkPermission`, and **the platform resolves custom permissions through groups by itself**, so the expansion query disappears entirely rather than moving. `LeadActionPermissionService` is genuinely a membership check and still needs it — do not "clean up" this selector as unused. |
| **EAC capture pipeline** (2026-08-02) | whichever principal EAC committed under | `TaskSelector.selectByIds`, `TaskSelector.selectThreadAnchorsByAnchorValues`, `EmailMessageSelector`, `EmailMessageRelationSelector` | the queueable dies → guard silently disabled while EAC keeps polluting timelines |
| **Rollup recompute — platform-driven, not user-requested** (2026-08-05) | the acting end user, on whose behalf a **trigger** recomputes | `TaskSelector.selectByTransactionDealIds` (← `TaskRollupService` ← `TaskRollupTrigger`) | **reproduced production failure** — see below |
| **Rollup recompute — prospective** (2026-08-05) | the acting end user; `recalc` is called directly, **no trigger** | `TaskSelector.selectByOnboardingIds` (← `OnboardingTaskRollupService.recalc` ← `OnboardingService.completeTask`) | **nothing today** — inert on the live path; applied for consistency and future callers |
| **Inbound-email file pipeline** (2026-08-05; ⚠ **VENUE CHANGED 2026-08-06 — the old justification is obsolete, not merely re-worded**) | whichever principal the file-job chain runs under, plus the scheduled sweep's own principal — both `Minimum Access` | `ContentVersionSelector.selectByIds`, **`AttachmentSelector.selectMetadataByParentIds`**, **`AttachmentSelector.selectBodiesByIds`** (all ← `AttachmentPersistQueueable` / `AttachmentCarrierSweepBatch`), and **`InboundEmailStagingSelector.queryCarrierSweep`** | ⚠ This row used to read *"a `USER_MODE` throw here destroys the whole broker email"*, because `persist` ran SYNCHRONOUSLY at the email boundary. **That is no longer true and must not be quoted** — the callers are now async transactions that own nothing irreplaceable, so a throw costs a DEFERRED file whose bytes remain on the staging row. The mode is retained on ORDINARY automation-path grounds: `USER_MODE` throws rather than degrades, which would **silently disable file conversion AND the daily retry sweep org-wide** — every email routing correctly while every file quietly failed, forever, with the only signal a failed `AsyncApexJob` nobody watches. The sweep locator is the sharper case: Metadata-API-deployed custom fields arrive with **no** field permissions for ANY profile, System Administrator included, so `Attachment_Status__c` under `USER_MODE` would break the sweep for the very administrator who deployed it. ⚠ Note the mixed modes inside `InboundEmailStagingSelector`: `selectById` and `selectDroppedNotesById` stay `USER_MODE` (they back reads a human's own email pipeline asked for); only the batch locator is `SYSTEM_MODE`. ⚠ **That last sentence was overtaken on 2026-08-08** — the class now holds THREE `SYSTEM_MODE` methods, not one; see the row below. |
| **Disposition NDA auto-create** (2026-08-09) | the acting end user, on whose behalf an after-insert/after-update **trigger** opens the buyer's NDA | `NdaSelector.selectByDispositionIds` (← `DispositionStageEntryService` ← `DispositionTrigger`) | Identical shape to the Transaction rollup row above, and taken for the same reproduced reason rather than by analogy: the read selects **`Party_Role__c`, a field created in this same tranche**, and a Metadata-API-deployed custom field arrives with NO field permissions for ANY profile. Under `USER_MODE` that read THROWS inside an AFTER-UPDATE trigger, which does not merely disable auto-create — it **rolls back the user's own stage change** with `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`. ⚠ Sharing was checked as a SEPARATE question per the paragraph below and needs no `without sharing` inner class here: every disposition in the set was just edited by the running user, so the rows are already visible to them. The class stays `with sharing` and its other **FIVE** methods stayed `USER_MODE` — they back reads a human asked for. ⚠ **That read "four" and was wrong when written — corrected in place 2026-08-16 (code review W4), not left standing.** `NdaSelector` already held five `USER_MODE` methods on 2026-08-09 (verified against the committed file at that revision), and the wrong figure was then copied into two further places in this document and into the class header. ⚠ **The sentence is also now HISTORICAL in a second way**: since 2026-08-16 the class has SEVEN public methods, of which `queryExpiryAlerts` is a second `SYSTEM_MODE` one, so "its other methods" is no longer a synonym for "its `USER_MODE` methods". The class header is the authoritative enumeration. |
| **Disposition LOI / PSA auto-create** (2026-08-10) | the acting end user, on whose behalf the same after-insert/after-update **trigger** opens the sell-side LOI and PSA | `LoiSelector.selectByDispositionIds`, `ContractReviewSelector.selectByDispositionIds` (both ← `DispositionStageEntryService` ← `DispositionTrigger`) | **Identical shape and identical consequence to the Disposition NDA auto-create row above.** Both reads select `Disposition__c`, created in Tranches 3B/3C, and a Metadata-API-deployed custom field arrives with NO field permissions for ANY profile, System Administrator included — so under `USER_MODE` the read THROWS inside an AFTER-UPDATE trigger and **rolls back the user's own stage change** with `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`, rather than merely disabling auto-create. ⚠ Sharing was checked as a SEPARATE question and needs no `without sharing` inner class: every disposition in the set was just edited by the running user. Both classes stay `with sharing`. **⚠ `ContractReviewSelector` was, until this change, the class whose header asserted "USER_MODE on every method … no automation or guest path on this object" — that claim was REPLACED in place, not left standing.** |
| **Negotiation-side reads — deriving a label, not showing data** (`LoiSelector` 2026-08-09 / `ContractReviewSelector` 2026-08-10) | the acting end user, saving a counter offer or a PSA version | `LoiSelector.selectNegotiationContextById` (← `CounterOfferService`), `ContractReviewSelector.selectNegotiationContextById` (← `PsaVersionService`) | 🔴 **A NEW SHAPE IN THIS TABLE: the read exists so the SERVICE can decide a WORD.** `Ball_In_Court__c = 'Seller'` names the counterparty on a purchase and names **DPEG** on a sale, so the label must be derived from the parent's record type (falling back to its `Disposition__c` lookup) and never taken from the caller — which is what makes a cross-record-type picklist write structurally impossible, since Apex DML does not enforce record-type picklist restriction. The user asked to record a counter/version, not to read the parent, and nothing the read returns is shown to anyone. **MEASURED, not anticipated:** a check-only run on 2026-08-09 reproduced `System.QueryException: No such column 'Disposition__c' on entity 'LOI__c'` — an FLS denial — and it took down the **live ACQUISITION counter-offer path**, which has nothing to do with dispositions. The PSA twin is one field rename away from being that same query on the live Log Version path. ⚠ Sharing deliberately untouched: the caller is writing to this very row, so a sharing denial should still fail. ⚠ Contrast the sibling residual D25 pins on `PsaVersionSelector.countByContractReviewId`, where sharing genuinely corrupts a derived value — a filtered `COUNT()` is still a number, whereas these are single-row fetch-for-use reads that throw. |
| **Inbound-email ROUTING retry** (2026-08-08) | a **Finalizer** running after the routing job has already rolled itself back, under whichever principal the platform executed it as; plus the hourly sweep's own principal — both `Minimum Access` | **`InboundEmailStagingSelector.selectRoutingStateById`** (← `InboundEmailStagingService.markRoutingFailed` ← `RoutingFailureFinalizer`) and **`InboundEmailStagingSelector.queryRoutingRetrySweep`** (← `RoutingRetrySweepBatch.start`) | Both read the brand-new `Routing_Attempt_Count__c`, and a Metadata-API-deployed custom field arrives with **no** field permissions for ANY profile, System Administrator included — so `USER_MODE` would break the failure recorder and the retry engine for the very administrator who deployed them, on day one, silently. The Finalizer case is the sharper of the two and is a **new shape in this table**: its entire job is to report a failure that has already happened, so a `USER_MODE` throw there turns *a failure to record a failure into a second failure*, and the routing row strands on `Pending` exactly as it did before the feature existed. 🔴 **This is also why `Routing_Attempt_Count__c` was deliberately NOT added to `selectById`** (which is `WITH USER_MODE` and is the first thing every inbound email does): doing so would have made every broker email depend on the new field's FLS, i.e. the change made to protect the pipeline would have become its newest single point of failure. ⚠ **AND SHARING IS A SECOND, SEPARATE DECISION HERE — see the paragraph below this table, which these two are the first entries to actually exercise.** `SYSTEM_MODE` alone was NOT enough: `Inbound_Email_Staging__c` is `sharingModel = Private` with no sharing rules and `Broker_Protection_Access` sets `viewAllRecords = false`, while the rows are owned by the Email Service context user (`createStaging` sets no `OwnerId`). Under `with sharing` the sweep locator would have returned only the rows the SCHEDULING user owns — dispatching nothing while `finish()` logged all-zeros, **indistinguishable from a healthy pipeline** — and the counter read would have returned null, so the attempt counter would never increment and the row would be re-dispatched hourly forever. Both queries therefore live in a `private without sharing` inner class, `InboundEmailStagingSelector.RoutingReads`, mirroring `LeadSelector.GuestReads`; the outer selector stays `with sharing` and `selectById` / `selectDroppedNotesById` are untouched. The matching writes live in `InboundEmailStagingService.RoutingWrites` for the same reason (a Private-OWD `update` by a non-owner is refused, and both callers are fail-soft, so the refusal would have been swallowed). 🔴 **One leg is deliberately left open and is closed OPERATIONALLY:** the retried `ExtractAddressQueueable` loads its row through `selectById`, which is `with sharing` and out of scope, so **the schedule must be owned by a principal with View All on this object** — recorded as a deploy gate in `RoutingRetrySweepSchedule`'s header. ⚠ `AttachmentCarrierSweepBatch` / `queryCarrierSweep` carry the **identical pre-existing exposure**, noted in that class's header and queued as its own change. |
| **Closed Won → Property Asset creation** (Tranche 5A, 2026-08-10) | the acting end user on an after-insert/after-update **trigger** — **either a deal driver (`DPEG_Junior_Analyst_PSG`) or, via `Transaction_Complete_Close`, a TRANSACTIONS persona (`DPEG_Transaction_Team`)** | **`PropertyAssetSelector.selectByPropertyIds`** and **`PropertySelector.selectAssetSeedByIds`** (both ← `PropertyAssetService.ensureOnClosedWon` ← `OpportunityReviewTriggerHandler`) | 🔴 **BOTH HALVES ARE LOAD-BEARING AND EACH FAILS DIFFERENTLY — this is the first row where the SHARING half is the more dangerous one.** MODE: same shape as the Transaction-rollup row above — a `USER_MODE` throw inside an after-update trigger escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolls back the deal close itself**. And the exposure is CRUD, not merely FLS: `Transaction_Complete_Close` writes `StageName = 'Closed Won'` with **no `<runInMode>`**, i.e. as the Transactions persona, and `DPEG_Transaction_Team` grants **no `Property_Asset__c` permission of any kind** (measured 2026-08-10). SHARING: `Property__c` and `Property_Asset__c` are **both `sharingModel = Private`**; the single `Property__c` sharing rule is an OWNER rule scoped to rows owned by the `Acquisition` QUEUE (a `LeadConvertService`-created Property is owned by the converter, so it is not reached), and the single `Property_Asset__c` rule shares only to the `DPEG_Property_Mgmt_Team` group. Under `with sharing` the **idempotency read returns zero rows and the service creates a DUPLICATE asset** — silently, both rows sharing a Name, splitting the entire PM tree — and the seed read returning zero rows means no asset at all while the deal closes looking healthy, i.e. byte-identical to the bug the feature exists to fix. Both queries therefore live in `private without sharing` inner classes (`PropertyAssetSelector.AssetCreationReads`, `PropertySelector.AssetCreationReads`), mirroring `InboundEmailStagingSelector.RoutingReads`; both outer selectors stay `with sharing` and `PropertyAssetSelector`'s three user-requested Sell Meter reads are untouched and stay `USER_MODE`. ⚠ The matching **DML** is `AccessLevel.SYSTEM_MODE` for the CRUD reason above — a THIRD decision, not implied by either of these two. |
| **Active Listing auto-create + traction monitor** (Tranche 5B, 2026-08-10) | the acting end user, on an after-insert/after-update **trigger** for the guard; and any principal opening a Disposition record page for the two read paths | **`BrokerListingSelector.selectByDispositionIds`** (← `DispositionStageEntryService` ← `DispositionTrigger`), **`DispositionSelector.selectListingClockByIds`** and **`DispositionOfferSelector.countByDispositionIds`** (both ← `DispositionTractionService`) | 🔴 **THREE READS, ONE FEATURE, AND THEY REACH THREE DIFFERENT CONCLUSIONS — read the method, never the class.** (1) The GUARD is the Disposition-NDA row's shape exactly: a `USER_MODE` throw inside an after-update trigger escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the user's own stage change. ⚠ Note its SYSTEM_MODE reason is NOT the sibling blocks' "the persona has no create" — `DPEG_Disposition_Edit` grants `Broker_Listing__c` `allowCreate = true` and every written field `editable = true` (measured), so this is a genuine, bounded widening rather than a restoration, and it is argued that way at the method rather than borrowed. Sharing stays user-scoped: a filtered guard would open a DUPLICATE listing, but a principal who cannot see the listings cannot see the disposition either, so they cannot have moved its stage. (2) The CLOCK read is `SYSTEM_MODE` on the FLS leg only — `USER_MODE` throws rather than degrades, so a principal without FLS on `Listing_Date__c` (e.g. a bare administrator: `DPEG_Admin_Access` grants none of these fields) would blank the whole traction panel; sharing stays user-scoped because a principal who cannot see the disposition is not on its record page. 🔴 (3) **THE OFFER COUNT IS THE ONLY ONE THAT ALSO NEEDS `without sharing`, AND IT IS THE THIRD DISTINCT FAILURE MODE IN THIS TABLE.** `Disposition_Offer__c` is `sharingModel = Private`; the count decides whether the day-30 checkpoint fires, so an UNDER-count does not disable the feature and does not fail silently in the usual sense — it produces a **CONFIDENT WRONG ANSWER**, telling the team a listing with three invisible offers has no traction and should have its broker replaced. `SYSTEM_MODE` lifts CRUD/FLS and never sharing, so the query lives in `DispositionOfferSelector.TractionReads`, a `private without sharing` inner class after `LeadSelector.GuestReads`; the outer class stays `with sharing`. ⚠ The exposure is a COUNT and never a row, and for the two personas the feature is for it is no widening at all — both disposition sets already carry `viewAllRecords = true` on the object. |
| **Call-for-offers deal stamp** (2026-08-10) | the principal `ExtractAddressQueueable`'s call-for-offers branch runs as, via `CallForOffersStampService` — `Minimum Access` | `OpportunitySelector.selectCallForOffersTargetsByIds` | 🔴 **Mode and sharing read as two SEPARATE questions here — collapsing them is the D25 mistake.** MODE: `Broker_Protection_Access` declares six `objectPermissions` and no `Opportunity` entry of any kind, so `USER_MODE` would throw rather than degrade and abort the branch. SHARING: `Opportunity` OWD is **`ReadWrite`**, measured against the org 2026-08-10 via Tooling `EntityDefinition` — so `with sharing` is *sufficient*, not merely inherited, and a `without sharing` inner class would widen a boundary for no measured reason. 🔴 **Record the residual loudly:** OWD is org state, not repo state — if `Opportunity` is ever narrowed to Private, this read returns **zero rows** for a principal owning no deals, the service reports "nothing to stamp", and the branch becomes indistinguishable from "no deal matched": nothing throws, nothing logs, no test fails. The named remedy is a narrow `private without sharing` inner class holding only this query (the `InboundEmailStagingSelector.RoutingReads` shape), never `without sharing` on a class backing eleven user-facing reads. ⚠ Also note (review W2) that the other half of the chain is not covered by this analysis: `PropertyMatchingService.resolveLiveRecord` → `LeadSelector.selectConversionById` is `WITH USER_MODE` on a `with sharing` class, and if that read were ever *filtered* rather than refused it returns the Lead Id and the branch silently reports "no deal matched" — not broken today, since branches (d)/(e) make the identical call in production. |
| **SharePoint deal-folder creation and recovery** (2026-08-11) | the acting end user on an after-insert/after-update **trigger** — a deal driver (`DPEG_Junior_Analyst_PSG`) or, via `Transaction_Complete_Close`, a TRANSACTIONS persona (`DPEG_Transaction_Team`); plus the batch's own scheduling principal | **`PropertySelector.selectFolderStateByIds`** (← `DealFolderService.ensureOnClosedWon` / `.createFolders` / `.markFailed`) and **`PropertySelector.queryFolderSweep`** (← `DealFolderSweepBatch.start`) — both in a `private without sharing` inner class, `FolderCreationReads` | 🔴 **THIS IS ONLY THE SECOND ENTRY IN THIS TABLE WHERE A SHARING-FILTERED READ PRODUCES A *DUPLICATE* RATHER THAN A *SILENCE*, AND IT IS THE FIRST WHERE THAT DUPLICATE IS AN EXTERNAL, UNRECOVERABLE WRITE INTO ANOTHER SYSTEM.** Every entry above this one but the Tranche 5A pair fails as nothing-happens. Here both reads back an IDEMPOTENCY GUARD — `SharePoint_Folder_ID__c` non-blank means zero callouts — so a filtered read does not disable the feature, it INVERTS it: zero rows means "no folder exists", and the service creates a second one. ⚠ **And `conflictBehavior: rename` is what makes that silent**: Graph does not collide, it succeeds, returning "Magnolia Crossing 1" with a 201. Contrast the Tranche 5A duplicate, a `Property_Asset__c` row an administrator can merge or delete: **a duplicate SharePoint folder is outside Salesforce's transaction entirely**, so nothing rolls it back, no test can observe it, and the only remedy is a human in the SharePoint tenant. That single fact is why the sharing question was answered before the mode question here. MODE: same shape as the `PropertyAssetService` row above — a `USER_MODE` throw inside an after-update trigger escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolls back the deal close itself**, and the exposure is not merely FLS: all four `SharePoint_*` fields are Metadata-API-deployed customs, which arrive with NO field permissions for ANY profile, System Administrator included. The sweep locator is the sharper of the two — under `USER_MODE` it would break the recovery engine for the very administrator who deployed the fields, on day one, silently. SHARING: `Property__c` is `sharingModel = Private` and its single sharing rule is an OWNER rule scoped to rows owned by the `Acquisition` QUEUE, which a `LeadConvertService`-created Property (owned by the converter) does not reach; the batch's rows are owned by whoever converted the Lead, never by the scheduling principal, so under `with sharing` the sweep would return zero rows and log an all-zeros summary **indistinguishable from a healthy pipeline** — the exact failure mode recorded for `InboundEmailStagingSelector.RoutingReads`. ⚠ The matching **DML** is `AccessLevel.SYSTEM_MODE` with `allOrNone = false` — a THIRD decision, implied by neither of these two: no persona that reaches Closed Won holds Edit on these fields, and a stamp that fails after a successful callout is residual R3. ⚠ 🔴 **NEITHER OF THESE LIFTS THE CALLOUT LEG.** `SYSTEM_MODE` and `without sharing` govern the DATABASE only; the Graph call still runs as the enqueuing/scheduling user's External Credential grant, which is precisely why the `DPEG_Transaction_Team` gap fails LOUDLY on every affected row instead of returning an empty result set. |
| **Call-for-offers deadline alert** (2026-08-14 — ⚠ **BACK-FILLED 2026-08-16; the tranche that added it never recorded it here**) | the scheduling principal of `CallForOffersAlertSchedule` | `OpportunitySelector.queryCallForOffersAlerts` (← `CallForOffersAlertBatch.start`) | MODE: it selects `Offer_Alert_Last_Interval__c` and `Offer_Alert_Due_Date__c`, both created in that same change, and a Metadata-API-deployed custom field arrives with NO field permissions for ANY profile, System Administrator included — so `USER_MODE` would throw for the very administrator who deployed them, on day one, silently. SHARING: `with sharing` is *sufficient* here rather than merely inherited, because `Opportunity` internal OWD is **`ReadWrite`** (measured 2026-08-14). 🔴 **Its stated residual is the reason the NDA row below diverges:** OWD is org state, not repo state, so if `Opportunity` were ever narrowed to Private this locator returns zero rows for a principal owning no deals and `finish()` logs an all-zeros summary indistinguishable from a quiet week. |
| **NDA expiry reminder** (FSD tranche 1, 2026-08-16) | the scheduling principal of `NdaExpiryAlertSchedule` — and, on `Minimum Access`, no acquisitions grant is implied | **`NdaSelector.queryExpiryAlerts`** (← `NdaExpiryAlertBatch.start`), in the `private without sharing` inner class `ExpiryAlertReads`; plus the matching **WRITE**, `NdaExpiryAlertBatch.MarkerWrites` | 🔴 **THIS IS THE ROW WHERE THE PRECEDENT DIRECTLY ABOVE MUST NOT BE COPIED, AND THE DIFFERENCE IS ONE MEASURED FACT.** MODE: identical shape to the call-for-offers locator — it selects `NDA_Alert_Last_Interval__c` and `NDA_Alert_Expiry_Date__c`, both created in this same tranche, so `USER_MODE` breaks the job on day one for the deploying administrator. SHARING: **NOT sufficient, and the divergence is not stylistic.** `NDA__c` is `sharingModel = Private`, and its only two sharing rules (`NDA_Disposition_Team_RW`, `NDA_Disposition_Principals_R`) are criteria-scoped to `RecordTypeId = 'Disposition NDA'` — **there is NO sharing rule covering an acquisition NDA at all**; they are reachable only via `viewAllRecords` on an acquisitions permission set. So under `with sharing` the locator returns only the rows the SCHEDULING user owns, `finish()` logs all zeros, and that is **indistinguishable from "no NDA is expiring"** — the 2026-08-08 `InboundEmailStagingSelector.RoutingReads` incident, one module later. 🔴 **AND THE WRITE IS A SEPARATE HOLE THE READ FIX DOES NOT CLOSE:** `SYSTEM_MODE` lifts CRUD/FLS and never sharing, so a Private-OWD `update` by a non-owner is REFUSED — and because the stamp is `allOrNone = false`, that refusal arrives as a `SaveResult` rather than an exception, so the job would **re-remind the same NDA every single day, forever**, which is precisely the failure the marker exists to prevent. Hence a second `private without sharing` class on the write side, mirroring `InboundEmailStagingService.RoutingWrites`. 🔴 **AND A THIRD DECISION, ADDED 2026-08-16 (code review W2): `NdaExpiryAlertBatch` ITSELF IS `without sharing`, which is a DIVERGENCE from every precedent in this table and the only one of the three that widens NOTHING.** No file in this repo establishes whether the platform re-applies the BATCH CLASS's sharing context when it chunks a `QueryLocator` built inside a `without sharing` inner class — all three precedents leave the batch/caller `with sharing`, so none of them answers it — and the keyword removes that mechanism for free, because the class holds ZERO SOQL and ZERO direct DML and every callee declares its own keyword (`NdaSelector` / `NdaExpiryService` `with sharing`, `GroupNotifier` already `without sharing`). ⚠ It is an ARGUMENT, not a measurement: **post-deploy gate G2 is RETAINED**, and it does not make `MarkerWrites` redundant. ⚠ **The DISCRIMINATOR is `Opportunity__c != NULL`, deliberately NOT the record type** — until post-deploy gate T-A1/T-B every live NDA sits on Master, so a record-type filter returns zero rows and ships the feature INERT while looking healthy (the same migration-window reason `ContractExecutionService.handleExecution` gives). ⚠ **`NdaSelector`'s other FIVE methods stay `USER_MODE`, and `selectByDispositionIds` — which is `SYSTEM_MODE` — stays sharing-scoped: read the method, never the class.** ⚠ That clause read "`NdaSelector`'s other four methods stay `USER_MODE` and sharing-scoped, `selectByDispositionIds` included" until 2026-08-16 (code review W4) and was wrong TWICE over — the count is five, and `selectByDispositionIds` is not one of them, since it is the class's OTHER `SYSTEM_MODE` method and was only ever sharing-scoped, not user-mode. |
| **Offering shell at PSA executed** (FSD tranche 1, 2026-08-16) | the acting end user, on whose behalf a `Contract_Review__c` **after-update** trigger opens the IR Offering | **`OfferingSelector.selectByOpportunityIds`** (← `OfferingService.ensureOnPsaExecuted` ← `ContractExecutionService.stampOpportunities` ← `ContractReviewTrigger`), in the `private without sharing` inner class `ExecutionHandoffReads` | 🔴 **THE THIRD ENTRY IN THIS TABLE WHERE A SHARING-FILTERED READ PRODUCES A *DUPLICATE* RATHER THAN A *SILENCE*, after the Tranche 5A pair and the deal-folder pair.** The read backs an IDEMPOTENCY GUARD, so a filtered read does not disable the feature, it INVERTS it: zero rows means "no Offering exists" and the service creates a second shell. `Offering__c` is `sharingModel = Private`, and its ONE sharing rule (`Offering_IR_Visibility`) shares rows owned by the `Acquisitions_Analyst` role branch **to the `Investor_Relations` group** — 🔴 **so it grants the EXECUTING principal nothing and does not close this hole; read WHO a rule shares to before concluding a sharing question is settled.** The live shape is ordinary: user A executes a PSA and owns the shell, user B later re-executes the same PSA. MODE: automation path; a `USER_MODE` throw inside a `Contract_Review__c` after-update trigger escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolls back the PSA execution itself** — the `Executed` status, `Contract_Signed__c`, Day 0 and the three team notifications. ⚠ **The exposure is CRUD, not merely FLS, and the measurement DIFFERS from `Transaction__c`'s:** `DPEG_Acquisition_Edit` *does* grant `Offering__c` create/edit/read + `viewAllRecords` — but the persona that executes a PSA is defined by the `Acquisition_Deal_Actions` custom permission on the layer-5 `Acquisition_Deal_Driver` set, which does not imply that permission set, and `DPEG_Admin_Access` carries a `<tabSettings>` entry for `Offering__c` and **no `objectPermissions` entry at all**. ⚠ The matching **DML** is `AccessLevel.SYSTEM_MODE` with `allOrNone = false` — a THIRD decision, implied by neither of these two, argued in `OfferingService`'s header §3/§4. |

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
`LeadSelector.GuestReads`, and since Tranche 5A `PropertyAssetSelector.AssetCreationReads` /
`PropertySelector.AssetCreationReads`) — never `without sharing` on the whole selector, which would
silently widen the reads that legitimately belong to a human.

⚠ **AND THE TRANCHE 5A PAIR ADDS A THIRD FAILURE MODE THE RULE ABOVE DOES NOT NAME.** Every prior
entry fails as SILENCE — zero rows, nothing happens, nothing logs. An **IDEMPOTENCY GUARD** keyed on
a sharing-filtered read fails as a **DUPLICATE**: zero rows means "no asset exists", so the service
creates a second one. So the check widens: whenever a SYSTEM_MODE automation read against a
Private-OWD object is used to decide *whether something already exists*, sharing is not a
robustness question, it is a correctness one — a filtered read does not disable the feature, it
inverts it.

⚠ **AND THE 2026-08-11 DEAL-FOLDER PAIR ESCALATES THAT THIRD MODE ONE STEP FURTHER.** A duplicated
`Property_Asset__c` is a Salesforce row an administrator can merge or delete. A duplicated
SharePoint folder is a write into ANOTHER SYSTEM: it is outside the Apex transaction, so nothing
rolls it back, no test can observe it, and the remedy is a human in the Microsoft tenant. So the
check sharpens once more: **when the thing an idempotency guard prevents is an EXTERNAL side effect,
answer the sharing question BEFORE the mode question** — `SYSTEM_MODE` is about whether the read
throws, and a throw is recoverable; sharing is about whether the read is *wrong*, and an external
duplicate is not.

### Key Apex Services

The services currently in `force-app/main/default/classes/`. Per §6, **add a row here whenever a new Apex service is introduced.** (The "7" this line used to claim was already stale by many rows before Tranche 5A; the table itself is the inventory.)

| Service                       | Invoked from                                       | Responsibility                                                                                                                                          |
| ----------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LeadConvertService`          | `LeadConvertTrigger`                               | Lead conversion: carries Deal Type onto the Opportunity and sets the matching record type (Land/Commercial); stamps Lead Approved By; creates the `Property__c` and links it to the Opportunity. **Extended 2026-08-03 (Conversion Enrichment S1/S2):** it now also carries the LLM-extracted deal-screening field set off the Lead, **split by meaning** — deal-process facts (`Asking_Price__c` ← `Guidance_Price__c`, guidance low/high, `Guidance_Cap_Rate__c`, offer due date, sale process, deal room, listing broker name/email, parse confidence) to the **Opportunity**; physical property facts (SF, NOI, units, occupancy, year built/renovated, lot **acres**, WALT, ADR, zoning, seller entity) to the **`Property__c`** — names the deal and the Property after the property (marketing name → address) rather than after `Lead.Company`, and creates the primary **`Broker` `OpportunityContactRole`** for the converted Contact via **read-then-write** (standard conversion already makes that row with a blank Role, so a blind insert would duplicate the broker and the primary). Three invariants are load-bearing and test-pinned: **2 SOQL / 3 DML per invocation regardless of batch size** (the contact-role write is PARTITIONED into an `isEmpty()`-guarded update + insert rather than one `upsert`, so the worst case is 4 — but conversion always creates the role row, making the ordinary path all-updates and therefore exactly one statement; `upsert` was rejected because its support on this standard junction is unverified and a DML failure inside a Lead after-update trigger takes the whole conversion with it); every restricted-picklist write (`Sale_Process__c`, `Parse_Confidence__c`, `Asset_Type__c`, `OpportunityContactRole.Role`) is **describe-guarded** so one illegal value cannot roll back the all-or-none `update updates` and with it the structural `RecordTypeId`/`Property__c` link; and `Property__c.Lot_Size__c` (square feet, OM-entered) is **never written** — deriving SF from acres is forbidden. Its DML is **system mode** and `Trigger.new` is not FLS-filtered, so a missing FLS grant does **not** block the stamp — it only makes the value invisible to the persona. |
| `LeadConvertActionService`    | `LeadConvertActionController` (Lead "Convert" quick action) | **The ONLY class in the app that runs `Database.convertLead`.** Runs the standard conversion for one or more Leads and returns the new Opportunity Ids index-aligned to the input. Added to this table 2026-08-02 — its absence was a pre-existing §6 gap. Since 2026-08-02 it also (a) applies the `LeadConvertMatchService` decision via `setContactId`/`setAccountId` and (b) sets `setBypassContactDedupeCheck`/`setBypassAccountDedupeCheck` on **every** conversion — see the D4 note below. |
| `LeadConvertMatchService`     | `LeadConvertActionService.convert()`               | **Smart Lead Conversion** (2026-08-02): decides what a conversion should ATTACH to, so a repeat broker reuses their existing Contact + firm Account instead of minting duplicates. Read-only, zero DML, exactly **3 SOQL regardless of N** (lead keys / Contacts by email / Accounts by name) via `LeadSelector` + `ContactSelector` + the new `AccountSelector`. Contact matches on **`Email` alone** and WINS, dictating the Account (a Salesforce constraint); Account-name matching is reachable only when no Contact matched **and** `Company != EmailToLeadService.COMPANY_PLACEHOLDER`. Oldest-wins (`CreatedDate ASC, Id ASC`). **Fails soft**: a denied `USER_MODE` read degrades to no-match (`lastRunDegraded`) so conversion is never worse than before the feature. |
| `OpportunityReviewService`    | `OpportunityReviewTrigger`                         | Creates deal children on stage entry or an Input-Needed flip. Idempotent — never a second child of one type. **The list is SIX, not the three this row used to name:** Development FR, Construction FR, Contract Review (at PSA), Underwriting (at Underwriting), NDA (on insert), and **LOI (at LOI, added 2026-08-05)**. Each insert is paired with a `Primary_<X>__c` stamp on the Opportunity, and for LOI **that stamp is load-bearing, not bookkeeping** — `ApprovalAuditService`'s LOI gate resolves its target through `Primary_LOI__c` and swallows its own failures, so an LOI created without the stamp would silently stamp nothing at the next approval, reproducing the Underwriting-gate defect one stage later. ⚠ **The LOI block alone uses `AccessLevel.SYSTEM_MODE` DML and defers its back-stamp to `LoiPrimaryStampQueueable`; the other five deliberately do neither.** Every other child is created when a DEAL DRIVER moves the stage, and a deal driver has Edit; the LOI stage is the only one entered by the **approval process's own field update**, so that code runs as the APPROVER — read-only on Opportunity and `LOI__c` here — **while the deal is LOCKED by its own approval**. Those are TWO different obstacles and each needed its own fix: `SYSTEM_MODE` lifts CRUD/FLS but **does NOT lift an approval lock**, so the inline back-stamp still threw `ENTITY_IS_LOCKED` after the CRUD fix landed. The LOI insert stays synchronous (`LOI__c` is not the record under approval, so it is not locked and the user sees it immediately); only the `Primary_LOI__c` write is deferred, and it lands because both approval processes set `finalApprovalRecordLock=false`. Do not "harmonize" the six blocks in either direction, and do not inline the stamp back. |
| `ContractExecutionService`    | `ContractReviewTrigger`                            | PSA execution handoff: stamps the Opportunity (Contract Signed, Day 0), creates the `Transaction__c` (idempotent), notifies Transactions / IR / Due Diligence. ⚠ **THAT SUMMARY IS STALE IN TWO PLACES AND THE CLASS HEADER IS AUTHORITATIVE:** `Transaction__c` creation MOVED OUT on 2026-08-05 (it now lives in `openTransactionsOnAboutToClose`, keyed on the Opportunity stage, and the header says "Do not re-add Transaction creation to handleExecution"), and since 2026-08-16 `stampOpportunities` also opens the IR `Offering__c` shell via `OfferingService` as its LAST statement. |
| `OfferingService`             | `ContractExecutionService.stampOpportunities` (← `ContractReviewTrigger`) | **The Investor Relations handoff: opens an `Offering__c` shell when an ACQUISITION PSA is executed** (FSD tranche 1, 2026-08-16). 🔴 **Nothing created an `Offering__c` before this class** — measured repo-wide: zero Apex creators, zero Flow creators, `TestDataFactory` only — so IR was notified at execution and handed nothing. 🔴 **ACQUISITION-ONLY IS STRUCTURAL, NOT A GUARD, AND THERE IS NO RECORD-TYPE TEST ANYWHERE:** the single call sits inside `stampOpportunities(Set<Id>)`, whose Id set can only hold non-null `Contract_Review__c.Opportunity__c` parents, so a sell-side PSA never reaches it. Same discriminator, and the same migration-window reason, as `handleExecution` itself. Idempotent on `Opportunity__c` ALONE (no `Status__c` filter — existence, not lifecycle), via `OfferingSelector.selectByOpportunityIds`, whose guard read must escape sharing because a filtered read here does not disable the feature, it INVERTS it into a duplicate-maker. Sets `Status__c = 'Draft'` EXPLICITLY, never the picklist default; leaves `IR_Owner__c` NULL (not derivable — a `User` lookup against a public GROUP). 🔴 **DML is `Database.insert(..., false, AccessLevel.SYSTEM_MODE)` and the `allOrNone = false` is a DECIDED TRADE (Gate 1 Q1.1), with the repo precedent cutting BOTH ways:** `advanceDispositionsToClosing` chose false so a stage advance could not roll back a legal state, `PropertyAssetService` chose true "because its silent absence WAS the bug" — which is word for word this feature's situation. The deciding fact is that an executed PSA is irreplaceable and an Offering shell is thirty seconds of keying. ⚠ **STATE THE RESIDUAL: a failed insert leaves no Offering and NO SIGNAL — there is no sweeper, no status field and nothing re-examines an already-executed deal.** ⚠ SYSTEM_MODE's reason DIFFERS from `Transaction__c`'s: the acquisitions persona *does* hold Create here; what it does not cover is the whole executing population (the `Acquisition_Deal_Actions` custom permission on a layer-5 set implies no permission set) plus `DPEG_Admin_Access`, which has a tab entry and no `objectPermissions` at all. ⚠ **NO notification** (IR is already told in the same method) and **NO `Primary_Offering__c` stamp** — do not add one for symmetry with `Primary_LOI__c`. Budget: **1 SOQL / ≤1 DML per trigger chunk, CONSTANT in deal count**; a chunk executing no acquisition PSA costs zero of both. |
| `NdaExpiryService`            | `NdaExpiryAlertBatch` | **The PURE NDA expiry ladder and the PURE idempotency rule** (FSD tranche 1 / FSD §15.2, 2026-08-16) — the `CallForOffersService` shape, ladder for ladder. `evaluate(Date expiry, Date asOf)` and `shouldFire(...)` have zero SOQL and zero DML, and the clock is an ARGUMENT, so every band is reachable without a frozen-clock hack and the batch evaluates a whole chunk against ONE `asOf`. `ALERT_INTERVALS = {5, 2}` lives here and NOWHERE else. 🔴 **Hardcoded, deliberately NOT a Custom Setting (Gate 1 Q2.2):** custom-setting DATA is not deployable, so a config-driven ladder adds a post-deploy gate whose omission leaves it empty or silently defaulted; both existing Custom Settings in this repo exist for a `getOrgDefaults()`-is-0-SOQL reason on a HOT path, which a once-daily batch does not have; and an admin editing an alert ladder with no deploy and no review is the hole `RecordStageAdvanceService` cites for keeping its stage map in Apex. **Cost stated: changing 5/2 is a one-constant change plus a deploy.** ⚠ **The ladder has NO `0` rung, unlike the call-for-offers `{7,3,1,0}`** — the FSD asks for two reminders, not three; the consequence is that an expired NDA sits in the `2` rung and gets exactly ONE catch-up reminder. 🔴 **`shouldFire` reads TWO marker fields and the second is not polish:** without `NDA_Alert_Expiry_Date__c` (the snapshot), extending an NDA's expiry leaves the marker armed against a date that no longer exists, the strictly-smaller test can never pass again, and the NDA is **never reminded about again — silently, on exactly the NDAs someone cared enough to extend**. The snapshot is also what lets every writer of the expiry date stay ignorant of this feature. |
| `NdaExpiryAlertBatch`         | `NdaExpiryAlertSchedule` (daily) | **The daily NDA expiry reminder** — notifies the `Acquisition` queue (Gate 1 Q2.3, matching `CallForOffersAlertBatch.RECIPIENT_GROUP`) at 5 and 2 days before a SIGNED acquisition NDA's expiry, once per rung per expiry date. Work queue = `NdaSelector.queryExpiryAlerts`. 🔴 **SEND FIRST, STAMP SECOND**, via `GroupNotifier.notifyWithOutcome`, stamping only the rows whose send succeeded: a notification is not transactional, so stamp-then-send loses a reminder silently and forever while send-then-stamp merely repeats it tomorrow. `SCOPE = 200` is **INHERITED from `CallForOffersAlertBatch` with a citation, NOT re-measured** — legitimate because the measured `6.0 ms + 0.22 ms × |recipients|` cost model is a property of `Messaging.CustomNotification.send()` and not of the object being alerted on. 🔴 **TWO SEPARATE SHARING HOLES, TWO SEPARATE FIXES, NEITHER COVERING THE OTHER:** the READ escapes sharing in `NdaSelector.ExpiryAlertReads`, and the WRITE escapes it in this class's own `private without sharing` inner class `MarkerWrites` — `SYSTEM_MODE` lifts CRUD/FLS and NEVER sharing, and because the stamp is `allOrNone = false` a sharing refusal arrives as a `SaveResult` rather than an exception, so the job would re-remind the same NDA **every day forever**. 🔴 **AND THE CLASS ITSELF IS `without sharing` — A THIRD DECISION, TAKEN 2026-08-16 (code review W2), AND THE ONLY ONE IN THIS ROW THAT WIDENS NOTHING.** It is a divergence from all three in-repo precedents (`InboundEmailStagingSelector.RoutingReads`, `PropertyAssetSelector.AssetCreationReads`, `PropertySelector.FolderCreationReads`), every one of which leaves its batch/caller `with sharing` — which is precisely why none of them establishes whether the platform re-applies the BATCH CLASS's sharing context when it chunks a `QueryLocator` built inside a `without sharing` inner class. **Nothing in this repo answers that**, so rather than hand the unknown to a post-deploy gate the keyword removes the mechanism: this class holds **ZERO SOQL and ZERO direct DML** (its one `Database.update` is inside `MarkerWrites`) and **every callee declares its own sharing keyword** (`NdaSelector` and `NdaExpiryService` are `with sharing`; `GroupNotifier` is already `without sharing`), so nothing inherits it. ⚠ **It is an ARGUMENT, NOT A MEASUREMENT, and gate G2 is explicitly RETAINED rather than closed by it** — confirm as the scheduling principal that a real pass selects and stamps an NDA that principal does not own. ⚠ **It also does not make `MarkerWrites` redundant**: that inner class is where the write's escape is argued, and deleting it would make the escape an accidental side effect of a keyword added for a different reason. ⚠ **This is the general shape worth copying, not the keyword**: where a `without sharing` escape is free because the class owns no SOQL/DML and no keyword-less callee, prefer removing the ambiguity to watching it. Scoped to `Status__c = 'Signed'` AND `Is_Non_Expiring__c = false` (Gate 1 Q2.1) to match the deployed `Acquisitions/NDAs_Expiring_This_Month` report exactly, so the report and the reminder cannot disagree. One `asOf` per `execute()`; the marker is read as a **`Decimal`** and cast with `.intValue()` (`Number(2,0)`). Fail-soft per chunk — a batch has NO Finalizer. Budget: **0 SOQL of its own, ≤1 DML, ≤SCOPE notifications, all CONSTANT in chunk size**; a chunk owing nothing costs zero DML and zero notifications. ⚠ The marker update re-fires the two `NDA__c` flows and both were CHECKED: `NDA_Signed_Status_Sync` is before-save with no DML, and `NDA_Signed_Rollup`'s entry condition is `Disposition__c IS NOT NULL`, which no row this job touches satisfies. |
| `NdaExpiryAlertSchedule`      | scheduled daily, early, post-deploy | The trigger for the NDA expiry reminder. 🔴 **A deploy that does not schedule it leaves the class present, compiled, tested, covered and COMPLETELY INERT — and an unscheduled ALERT job leaves no trace at all**, unlike the sweepers it resembles (`DealFolderSweepBatch` and `RoutingRetrySweepBatch` both strand rows on a `Failed` status a human can list). "No reminder arrived" is indistinguishable from "no NDA was expiring". Job instances are not deployable metadata, so this is verified post-deploy gate G1: `System.schedule('DPEG NDA Expiry Alert', '0 0 7 * * ?', new NdaExpiryAlertSchedule());` — record the cron expression AND the owning user. 🔴 **WHO OWNS IT MATTERS MORE HERE THAN FOR `CallForOffersAlertSchedule`, and that is the one place the precedent must not be copied:** that job can be relaxed about its owner because `Opportunity` OWD is `ReadWrite`; `NDA__c` is Private with no acquisition sharing rule at all. The `without sharing` inner classes are the remedy — gate **G2** is confirming, as the scheduling principal, that a pass actually selects and stamps an acquisition NDA that principal does not own. |
| `PropertyAssetService`        | `OpportunityReviewTriggerHandler`                  | **Property Management handoff** (Tranche 5A, 2026-08-10, D27.3/D28): creates the `Property_Asset__c` when a deal ENTERS `Closed Won`. 🔴 **Nothing created one before — measured repo-wide: zero creators in Apex apart from `TestDataFactory`, zero in Flow (not one flow even REFERENCES the object), nine seed scripts.** Every asset in the org was seeded data, which is why it looked automatic; on a real deployment `Deal_Status__c` read "Asset Under Management" and the whole PM tree (Units, Rent Steps, Onboarding, CAM, Delinquency, Insurance, Broker Assignments, Lease Inquiries, Lease Renewals, Work Orders) had nothing to hang from. 🔴 **It is on the OPPORTUNITY TRIGGER, not in the `Transaction_Complete_Close` flow, and that is not a preference:** `StageAdvanceService.NEXT_STAGE` maps **both** `PSA ⇒ Closed Won` **and** `About to Close ⇒ Closed Won`, so a deal driver reaches Closed Won with no `Transaction__c` at all — building it in that flow would have missed half the closes, invisibly. Same precedent as `openTransactionsOnAboutToClose`, a stage-keyed handoff that lives on the same handler for the same reason. Field set = **`Name` (the property's, VERBATIM) + `Property__c` + `Status__c = 'Active'` + a MAPPED `Property_Type__c` + `Closing_Date__c` (← `Opportunity.CloseDate`)** — the first four derived from what the nine seed scripts populate, i.e. the working reference for an asset the PM module can actually use rather than a guess. ⚠ **`Closing_Date__c` is the one deliberate exception to "match the seeds" (added 2026-08-10, user decision), and the reason it is IN is the reason its three seed-absent neighbours stay OUT:** it has exactly ONE candidate source — a required standard field, semantically exact, already on `Trigger.new` (so no extra query) and the **same type on both sides** (both `Date`; contrast `Opportunity.Contract_Executed_Date__c`, a DateTime that forces `ContractExecutionService` to call `.date()`). By contrast `Final_Purchase_Price__c` has three candidates and `NOI__c` / `Market_Cap_Rate__c` each have two that are *semantically different numbers* (DPEG's underwriting vs. the seller's marketing figure), so choosing one unasked would store a plausible wrong number — the same class of defect as a mismapped `Property_Type__c`. When two deals close against one property in a chunk the **earliest** `CloseDate` wins (deterministic; a bare `put` would be last-in-`Trigger.new`-order, which is not a guarantee). 🔴 **`Property_Type__c` is MAPPED, never copied.** Source `Property__c.Asset_Type__c` is restricted with 10 values; the target is **NOT restricted** and has 5, so an off-list value **stores silently** — measured, not assumed (a falsification run with a blind copy stored `Land`, `C-Store` and a fabricated string with no error). Five values map (identity); `Land`, `Storage`, `Hospitality`, `C-Store` and `Medical Office` are **left blank on purpose** — the last two are the "nearly right" trap, and the source picklist carries them as values distinct from `Retail`/`Office`. A runtime describe guard re-checks every target against the live picklist, because on an unrestricted field a stale map entry would not throw, it would start producing orphans. Idempotent on `Property__c` ALONE, with no `Status__c` filter (a `Disposed` asset still counts — a second asset would split the PM history in two). Budget: **2 SOQL / 1 DML per trigger chunk, CONSTANT in deal count**; a chunk closing nothing costs zero of both. DML is `AccessLevel.SYSTEM_MODE` and all-or-none: **no persona that can reach Closed Won holds Create on `Property_Asset__c`** (measured — `DPEG_Junior_Analyst_PSG` reaches it read-only via `DPEG_PropertyMgmt_View`; `DPEG_Transaction_Team` holds nothing on it at all), so a bare `insert` throws `System.TypeException` exactly as `openTransactionsOnAboutToClose` measured on `Transaction__c`. ⚠ **A deal with a null `Property__c` is SKIPPED, and that residual is real** — only `LeadConvertService` creates a Property, so a manually built deal has none; throwing would make such a deal unclosable, and there is no runtime surface for the skip (a notification is D9-deferred). ⚠ **No record type is stamped** — `Property_Asset__c` has none, so `RecordTypeId` is not even a compilable field on it; the guarded-vs-unconditional question is deliberately NOT pre-decided, because D16.3's, 3B's and 3C's three arguments each turned on a different fact and none transfers. ⚠ **The new asset is invisible to the Sell Meter and that is CORRECT** (`PropertyAssetSelector` filters both meter queries on `Peak_Sell_Date__c != null`, which is Argus-derived) — recorded because the natural expectation is the opposite. |
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
| `CallForOffersStampService` | `ExtractAddressQueueable` (call-for-offers branch) | Broker Protection: **the module's only `Opportunity` writer** (added 2026-08-10). `stamp(List<StampRequest>) → StampResult{stamped, unchanged, refusals}`; 1 bulk read, ≤1 bulk `Database.update(..., false, AccessLevel.SYSTEM_MODE)`. **Last email wins per field** — a call-for-offers deadline is a fact that *changes* ("extended to Friday"), so fill-if-blank would freeze the first date and make an extension invisible. **A null incoming value is never written** — an email silent about the broker must not erase one the deal knows. **A date already present from conversion IS overwritten** — it came from this same pipeline, out of the winning broker's own earlier email, so a later call-for-offers email is newer information about the same deadline. 🔴 **But the LISTING BROKER fields are NOT last-wins by fallback.** The envelope fallback was removed (review W1): a deadline is a fact about the campaign; **the listing broker on a live deal is a fact about the transaction, and a third party's blast is not newer information about it.** Passing null preserves what the deal knows. **A record where nothing would change is dropped from the update list entirely** — zero DML, which is what makes replay a no-op. ⚠ Two properties in one email can fuzzy-match the same registry row, so the service **merges by `recordId` before the DML** — a duplicate Id in one `Database.update` throws `DUPLICATE_VALUE` for the **whole statement**, and `allOrNone = false` does **not** rescue that. |
| `LeadActionPermissionService` | `LeadActionPermissionController`, `LeadConvertActionController` | Lead stage quick actions: the single source of truth for "may the running user drive Convert / Mark Under Review / Mark Qualified / Disqualify?". Accepts `Lead_Stage_Actions_Access` OR `Broker_Protection_Access`, resolves grants through permission set GROUPS as well as direct assignments, and bypasses for "Modify All Data". Exposes `hasLeadActionAccess()` (the cacheable UX gate) and `assertLeadActionAccess()` (the server-side enforcement used before `Database.convertLead`). Reads via `PermissionSetAssignmentSelector` + `PermissionSetGroupComponentSelector`; no DML. |
| `OpportunityActionPermissionService` | `OpportunityActionPermissionController`, `StageAdvanceController`, `OpportunityApprovalController` | Opportunity stage quick actions: the single source of truth for "may the running user drive the deal actions?". Exposes `hasDealActionAccess()` (the cacheable UX gate) and `assertDealActionAccess()` (the server-side enforcement now asserted by `advance` / `advanceTo` / `submitForApproval`). No DML. **🔴 REWRITTEN 2026-08-12 — ONE FACTOR: the `Acquisition_Deal_Actions` CUSTOM PERMISSION**, granted by the layer-5 `Acquisition_Deal_Driver` set, plus the retained "Modify All Data" bypass. ⚠ **This row previously read "The gate is TWO-FACTOR and is deliberately NOT the Lead-style membership check" and listed `UserSelector` among its reads — both are now false.** The retired model required FLS read on `User.Deal_Driver__c` (a `WITH USER_MODE` throw being the denial signal) **AND** that flag `true`; it was retired because a flexipage `<visibilityRule>` referencing a FIELD evaluates FALSE for anyone lacking FLS on it — silently, no error, no log — so the button vanished for users who were genuinely authorized. A custom permission has **no FLS surface**, removing the whole failure class. Reads via `PermissionSetAssignmentSelector` ONLY, and only on the bypass path: `FeatureManagement.checkPermission` costs **0 SOQL**, so a holder pays nothing (was 2 queries). 🔴 **The "Modify All Data" check now runs AFTER the permission check — the old MUST-run-first ordering was a correctness constraint imposed by the FLS read and is GONE; do not restore it.** See the stage-action gate subsection below. |
| `RecordStageAdvanceService` | `RecordStageAdvanceController` (the `advanceRecordStage` quick action, plus the per-branch bundles) | **Generic stage advance for the SEVEN objects whose stage is button-driven, across THREE modules** (added 2026-08-04; `Contract_Review__c` joined 2026-08-05, the row said "five" until 2026-08-09 and "six acquisitions / disposition CHILD objects" until 2026-08-12): `NDA__c` (`Status__c`), `Contract_Review__c` (`Negotiation_Status__c`), `LOI__c`, `Underwriting__c`, `Construction_Feasibility_Review__c`, `Development_Feasibility_Review__c` (`Stage__c`), and **`Transaction__c` (`Stage__c`, added 2026-08-12)**. ⚠ **"CHILD objects" is no longer accurate and has been dropped from this row's title** — `Transaction__c` is the first entrant from the TRANSACTIONS module and is not a deal child; the common property is that the stage is button-driven and server-derived, not that the object hangs off a deal. ONE service, config-driven by a `Map<SObjectType, StageConfig>` — **Apex, deliberately NOT Custom Metadata** (an admin editing a stage map with no deploy and no review is the same class of hole this feature closes; CMDT *record* deploys also fail in this org). Zero SOQL of its own: `load()` dispatches on `Id.getSObjectType()` to each object's own `<Object>Selector.selectStageRequiredById`, all static and `WITH USER_MODE`, **no dynamic SOQL anywhere**. Write is plain `update` (system mode), matching `StageAdvanceService`; the FLS residual is documented in the class header. 🔴 **The Underwriting map deliberately OMITS `In Progress` → `Approved`** — that stage belongs to the principal approval process (`Submit_for_Approval` → `ApprovalAuditService`), and the refusal message names that route so the gap does not read as a bug. **⚠ AMENDED 2026-08-09 (Tranche 3A, D7 / D14.1) — THE MAPS ARE NOW PER RECORD TYPE, NOT PER OBJECT.** `StageConfig` keeps `label` / `stageField` / `gate` per object and delegates the sequence and the allow-list to a `StageTypeConfig` keyed by record-type **developer name**, with a `defaultTypeKey`. `NDA__c` is the first object to use it — `Acquisition_NDA` runs `Pending → Sent → Received → Signed` and `Disposition_NDA` runs `Not Sent → Sent → Signed` **plus the `Declined` off-ramp**. 🔴 **`Sent` and `Signed` are SHARED by both value sets, so the current stage alone does NOT identify the sequence** (from `Sent`, acquisition goes to `Received` and disposition goes to `Signed`) — that single fact is why an object-keyed map is inexpressible here. 🔴 **THE EXPLICIT-TARGET ALLOW-LIST HAD TO MOVE WITH IT, AND THAT IS THE SECURITY HALF:** record-type picklist restrictions are **UI-only and are not enforced by Apex DML**, so an object-level list holding `Declined` would let a hand-crafted `advanceTo(acquisitionNdaId, 'Declined')` write a disposition value onto an acquisition NDA. A `NEXT_STAGE`-only change compiles, passes every walk test and is a hole. ⚠ **This is a CALL-ORDER change, not a map swap** — `configFor()` still runs first (it proves the object is supported and supplies the stage field name), but the sequence is chosen *after* `load()`, which means **`advanceTo`'s allow-list check now runs after the load** and a non-existent Id raises `QueryException` where it used to raise `RecordStageAdvanceException` (both masked behind fixed generic messages at the controller). ⚠ **The null / Master fallback is load-bearing:** between the record-type deploy (T1) and the row migration (gate T-B) every live NDA is on Master, so `defaultTypeKey` points at the **acquisition** sequence; a real, *named* record type with no configured sequence is **refused**, never defaulted. Resolution is a **describe**, so this adds **zero SOQL** — but `NdaSelector.selectStageRequiredById` must select `RecordTypeId`, and since a custom object with zero record types has no such field, that is a **compile** dependency on the record-type metadata, not merely a runtime one. 🔴 **There is still no *generic* `advanceTo`** — it writes only what is on the allow-list **for that record type**, and five of the seven objects supply none at all (`Transaction__c` included — its sequence is linear, so it has no branch and no off-ramp). Adding `LOI__c`'s two record types (Tranche 3B) is a config addition, not another refactor. **⚠ AMENDED AGAIN 2026-08-09 — THE GATE IS NOW PER RECORD TYPE TOO, so the sentence that used to end this row ("the GATE is the one axis still per object") is FALSE and must not be quoted.** `D15/Q1`'s `DISPOSITION_DRIVER` value is wired, backed by the `Disposition_Deal_Driver` permission set + `DispositionActionPermissionService` (originally by `User.Disposition_Driver__c`, retired 2026-08-12); `gate` moved from `StageConfig` onto `StageTypeConfig`, so `Acquisition_NDA` answers to `DEAL_DRIVER` and `Disposition_NDA` to `DISPOSITION_DRIVER`. 🔴 That is a real boundary, not bookkeeping: one object serves both modules, and an acquisitions deal driver must not be able to drive a SALE's NDA. ⚠ The visible cost is that **`hasStageActionAccess()` now LOADS the row** for an object with more than one configured sequence (a `cacheable=true` path, one SOQL per record view); objects with a single sequence short-circuit on `byRecordType.size() == 1` and still pay nothing, and a non-existent Id now raises `QueryException` there where it previously returned the object-level answer (masked behind the controller's fixed message, so no wording changed). ⚠ **Tranche 3C must SPLIT `Contract_Review__c` even though its two record types share all four `Negotiation_Status__c` values** — sharing a SEQUENCE is not sharing a GATE. **🔴 AMENDED TWICE ON 2026-08-12 — READ THE SECOND AMENDMENT, IT SUPERSEDES THE FIRST.** A third gate arrived with `Transaction__c`, and later the same day **all three gates had their MECHANISM replaced with a single custom-permission check**. `StageActionGate`'s three members are now **one shape**: `DEAL_DRIVER` → `Acquisition_Deal_Actions`, `DISPOSITION_DRIVER` → `Disposition_Deal_Actions`, `TRANSACTION_STAGE_ACTIONS` → `Transaction_Stage_Actions`, each a `FeatureManagement.checkPermission` call plus the shared "Modify All Data" bypass. ⚠ **The amendment this replaces said the members were "not all the same shape" — TWO-FACTOR (`User.*_Driver__c` FLS **and** the flag `true`) for the first two and MEMBERSHIP-ONLY for the third — and warned "do not generalise from the first two". That warning is now OBSOLETE**: the `*_Driver__c` flag model was retired outright and the Transaction gate no longer tests membership. 🔴 **THE ONE ASYMMETRY THAT SURVIVES IS WHICH PERMISSION-SET LAYER CARRIES THE TOKEN, AND IT IS A REAL AUTHORIZATION DIFFERENCE:** the two deal permissions sit on directly-assigned **layer-5** sets (narrow, per-user revocable), while `Transaction_Stage_Actions` sits on the **layer-4** `Transaction_Stage_Actions_Access` inside `DPEG_Transaction_Team` — so that gate is **TEAM-WIDE with no per-user revocation**, exactly as under the membership check it replaced. That is a preserved policy, not a migration artefact. Moving either deal permission down to layer 4 would be a real WIDENING (`Opportunity_Stage_Actions_Access` is a member of `DPEG_Junior_Analyst_PSG`); moving the third up would be a real NARROWING. ⚠ **The enum VALUE NAMES were deliberately not renamed** — `DEAL_DRIVER` / `DISPOSITION_DRIVER` still read as if a `*_Driver__c` checkbox existed and it no longer does; they name the GATE (which persona drives this record type), not the mechanism. ⚠ **The member is still deliberately NOT named `TRANSACTION_DRIVER`**: a `*_DRIVER` name asserts a flag a reader would then go looking for. ⚠ **A NOTE FOR ANYONE READING THE GIT HISTORY:** this row argued at length that the two `*_DRIVER` members must not become permission-set MEMBERSHIP checks, because a set-holder with the flag `false` was denied and would have been granted — a silent widening. That argument is **moot, not overturned**: no flag remains to disagree with the set, and the custom permission is carried BY those same sets, so the population is preserved by construction. Do not resurrect it against a future change; the argument that still bites is the layer-4/layer-5 one. ⚠ The gate remains a property of the **record type**, not the object — `Transaction__c` names its gate exactly once because it has exactly one sequence. Full argument: `TransactionActionPermissionService`'s class header. |
| `DispositionStageEntryService` | `DispositionTrigger` → `DispositionTriggerHandler` | **Creates a Disposition's stage-entry child records — the disposition twin of `OpportunityReviewService`** (added 2026-08-09, Tranche 3A, decisions D15/Q3 · D16.2 · D19.1). ⚠ **AMENDED 2026-08-10 — the sentence "today it does exactly ONE thing … Tranches 3B/3C add the disposition LOI and PSA here" WAS TRUE AND IS NOW FALSE. All three stages are built.** Review C1 found that 3B and 3C had shipped everything downstream of a disposition LOI and Contract Review — Paths, quick actions, LWC bundles, record-type-scoped allow-lists, sharing rules, the gate split, `ContractExecutionService`'s disposition arm — while **nothing in the application could create either record, by any persona, including an administrator.** The three blocks now are: `NDA` → `NDA__c` (`Party_Role__c = 'Buyer'`, `Disposition_NDA`, `Status__c = 'Not Sent'`) **+ a deferred `Primary_NDA__c` stamp**; `LOI` → `LOI__c` (`Disposition_LOI`, `Stage__c = 'Received'`); `PSA` → `Contract_Review__c` (`Disposition_PSA`, **`Negotiation_Status__c = 'Initial Draft'` — never `Stage__c`, which `Contract_Review_Stage_Sync` recomputes, so a direct write commits and is silently discarded**). 🔴 **ALL THREE USE `SYSTEM_MODE` DML; ONLY THE NDA DEFERS A PARENT STAMP, AND THAT ASYMMETRY IS THE POINT.** `Disposition__c` has exactly one `Primary_*` lookup, so the LOI and PSA blocks have **no parent write and therefore nothing to defer** — a Queueable there would be a job that does nothing while asserting to the next reader that an approval-lock hazard exists. Their lock analysis was **re-argued from scratch rather than inherited** (the review W1 mistake): neither `LOI` nor `PSA` is any approval's entry stage (`Sale_Decision` = Readiness, `Broker_Selection` = BOV Outreach, `Closing` = Closing) and **none of the three approvals performs a field update at all**, so those stages are only ever entered by a human edit or a data load — never by an approval running as a read-only approver. `SYSTEM_MODE` is still required on both, twice over: `DPEG_Disposition_Edit` grants `allowCreate = false` on both objects (creation is this trigger's job, per D16.1's premise), **and** `Disposition__c` is a new field on both with no FLS for any profile — the second leg survives a later `allowCreate` grant. ⚠ Both new stages are on **BOTH** disposition record types, unlike `NDA`, so a broker-listed sale gets them too. Their idempotency key is **simple presence**, not the NDA's `Party_Role__c`. `DispositionStageEntryServiceTest.loiAndPsaAutoCreateEnqueueNothing` is the permanent falsifier for "add a Queueable for symmetry". 🔴 **IT FIRES ON A RECORD THAT THREE APPROVALS LOCK** (`Sale_Decision` at Readiness, `Broker_Selection` at BOV Outreach, `Closing` at Closing — all `recordEditability = AdminOnly`), so it reuses `OpportunityReviewService`'s LOI-block pattern rather than inventing one: **(1)** `AccessLevel.SYSTEM_MODE` DML for the child insert (the persona holds `allowEdit` and deliberately NOT `allowCreate` on `NDA__c` per D16.1, and the actor may be a read-only approver; `NDA__c` is not the record under approval, so it is not locked) and **(2)** the parent `Primary_NDA__c` stamp is **DEFERRED to `DispositionNdaStampQueueable`**, because **SYSTEM_MODE lifts CRUD/FLS but NOT an approval lock** and an inline write throws `ENTITY_IS_LOCKED`. ⚠ **No test in this repo runs a live approval, so the lock is NOT reproduced by the suite** — an inlined stamp passes every test and fails in production, exactly as it did on the LOI path. 🔴 **The idempotency key is `Party_Role__c = 'Buyer'`, NOT "has any NDA"** (D19.1: the broker NDA is added by hand, so "any NDA" would silently deny the user who added the broker's first the buyer's NDA — and the all-signed gate would then release on a signed broker NDA alone). It is also deliberately NOT scoped to the record type, because a pre-gate-T-A1 buyer NDA can legitimately sit on Master — and the same unscoped rule applies to the LOI and PSA blocks, most sharply to the PSA, where a Master-type row walks its path perfectly and is wrong only about which persona may drive it. Zero inline SOQL (`NdaSelector` / `LoiSelector` / `ContractReviewSelector` `.selectByDispositionIds`, all `WITH SYSTEM_MODE`). Trigger-driven, so the bulk-rule exemption does NOT apply: **1 SOQL / 1 DML PER STAGE ENTERED IN THE CHUNK (≤ 4 / ≤ 4 since Tranche 5B), plus ≤1 enqueue for the NDA block — CONSTANT in record count**, pinned at 251 per stage, with `aMixedChunkQueriesOncePerStageAndWritesNothingWhenAllChildrenExist` pinning the "one query per stage, never one per record" shape across three of them at once. A chunk entering none of the target stages — every ordinary Disposition save in the org — costs zero queries, zero DML and zero enqueues. **⚠ AMENDED AGAIN 2026-08-10 (Tranche 5B, D28/Q3) — THERE IS NOW A FOURTH BLOCK, AND IT IS THE ONLY ONE THAT ALSO USES A BEFORE-SAVE CONTEXT.** `Active Listing` → `Broker_Listing__c` (`List_Date__c` copied from the parent, `Broker_Firm__c` from `Selected_Broker__c`, `Listing_Status__c = 'On Track'`), plus `stampListingDates`, which writes **`Disposition__c.Listing_Date__c` IN MEMORY during the user's own save** — so `DispositionTrigger` gained `before insert, before update`. 🔴 **That is a PREREQUISITE, not an enhancement:** nothing in the application created a `Broker_Listing__c` or wrote `Listing_Date__c`, and `Days_On_Market__c` is `formulaTreatBlanksAs = BlankAsZero`, so an unset date reads **0 forever, not null** — a clock that looks healthy and never ticks. 🔴 **THE PARENT WRITE IS IN THE BEFORE CONTEXT SPECIFICALLY TO AVOID THE APPROVAL LOCK, AND A QUEUEABLE WOULD NOT HAVE WORKED.** Measured correction to the obvious premise: `Active Listing` is **NOT** `Broker_Selection_Approval`'s entry stage — that approval keys on `BOV Outreach` (read off the approvalProcess file), so no approval has `Active Listing` as an entry stage at all. The live hazard is the ADJACENCY: an admin can advance a still-locked record out of `BOV Outreach` (`recordEditability = AdminOnly` permits it), and an inline second `update` would then throw `ENTITY_IS_LOCKED` with `allOrNone = true` and roll back their own stage change. Deferring to a Queueable does **not** fix that — review D20/W1 established that `finalApprovalRecordLock = false` releases on FINAL APPROVAL, and here the triggering transaction is not the one releasing it, so a PENDING approval outlives the job. A before-save assignment issues no second statement at all. ⚠ **The option is available here and NOT to the NDA block for a structural reason:** `Primary_NDA__c`'s value is the child's Id, causally downstream of the insert; `Listing_Date__c` depends only on the transition, which is fully known in before-update. **Do not harmonise them.** The stamp is **fill-if-blank** (a re-entry must not restart the clock, and `TestDataFactory` seeds `Listing_Date__c = TODAY` on every fixture, so an unconditional stamp would destroy a real date — and a test that forgets to null it first asserts the fixture rather than the code). `Broker_Listing__c` has **no record types**, so this block carries no stamp and no `isAvailable()` guard. ⚠ The record-type stamp on the other three is `isAvailable()`-GUARDED (same shape as `DispositionService.onMarketRecordTypeId`); its degradation is worse here than on the acquisition side — a Master-type disposition NDA seeds at `Not Sent`, falls back to the ACQUISITION sequence, which has no `Not Sent` hop, so it can be neither advanced nor declined. The remedy is gate T-A1, and an unconditional read-back test names it. |
| `DispositionNdaStampQueueable` | chained from `DispositionStageEntryService` | The deferred `Disposition__c.Primary_NDA__c` back-stamp; the disposition twin of `LoiPrimaryStampQueueable`, whose header records the two failed attempts (bare DML → `TypeException`; `SYSTEM_MODE` → `ENTITY_IS_LOCKED`) that produced this pattern. `Database.update(..., true, AccessLevel.SYSTEM_MODE)` — `allOrNone = true` on purpose, so a failure surfaces as a failed `AsyncApexJob` rather than leaving a null lookup that downstream automation silently fails to resolve. ⚠ Its update RE-FIRES `DispositionTrigger`, and that is safe **by construction, twice over**: the stage is unchanged so the stage-ENTRY test short-circuits before any query, and the buyer-role idempotency read would suppress a second NDA anyway. That is why this feature carries **no recursion flag** — a static boolean's failure mode (left true across a batch chunk, silently disabling auto-create for the rest of the transaction) is worse than the problem. It also cannot trip `All_NDAs_Signed_Before_Progression`, which is `ISCHANGED(Disposition_Stage__c)`-scoped. |
| `DispositionTractionService` | `DispositionTractionController` (← `lwc/listingAlerts`) and `BrokerListingController.getListing` (← `lwc/brokerListing`) | **The Active Listing traction monitor** (added 2026-08-10, Tranche 5B, decisions D27.1 / D28-Q1 / D28-Q2). It is the ONE place in the application that decides whether a broker-listed property is getting traction, and it replaced a **21/28/42-day ladder hardcoded inside `BrokerListingController.getListing`** — the only executable copy of the 6-week clock, and wrong twice over: wrong duration, and reading `Broker_Listing__c.Days_On_Market__c`, a hand-keyed Number that **nothing writes**. 🔴 **THE CLOCK IS 60 DAYS WITH A 30-DAY CHECKPOINT, AND THE INTERMEDIATE BAND IS DERIVED, NOT GUESSED.** The retired rungs sat at exactly ½ / ⅔ / 1 of a 42-day clock; keeping those ratios against 60 gives **30 / 40 / 60**, and the ½ mark lands precisely on the checkpoint the document itself names. 30 and 60 are the document's numbers; **40 is the only derived threshold** and is the one a future revision may move without contradicting the source. ⚠ Configurable thresholds were offered at Gate 1 and NOT chosen (D28/Q2) — the numbers stay hardcoded; D28 notes this is the SECOND dispute, so a THIRD is the point to revisit. 🔴 **"NO TRACTION" MEANS ZERO OFFERS, NOTHING ELSE (D28/Q1)** — "real interest" stays the human judgement the document describes and is deliberately NOT modelled as a field (an unmaintained interest field reads as *zero* interest; a manual "there is interest" flag inverts the burden so silence becomes a positive assertion). **That offers branch is the substantive behaviour change, not the thresholds:** the old ladder ignored offers entirely and labelled a listing with five offers "Week 6 — Hard Stop". 🔴 **NEITHER STORED `Days_On_Market__c` IS READ.** The band is computed from the raw `Disposition__c.Listing_Date__c`, because the `Disposition__c` formula carries `formulaTreatBlanksAs = BlankAsZero` and so returns **0** for an unset date — indistinguishable from "listed today". Reading the date lets a blank return `NOT_LISTED`. The clock is the **PARENT's**, never `Broker_Listing__c.List_Date__c`, because the marketing period survives a broker change while a listing row is per-broker. **WHERE THE COMPUTATION LIVES — Apex at read time, argued rather than defaulted:** a formula is **impossible** (`Disposition_Offer__c.Disposition__c` is a Lookup, so no roll-up summary exists and no formula can count offers at any price); a Schedulable was **rejected** because D9 defers the alert, so its only product today would be a stored copy of a pure function of two stored facts — one that can go stale, that needs a post-deploy schedule, and whose absence would leave the UI showing a band nothing maintains, silently. ⚠ **The cost is stated: a computed band is not reportable or filterable**, so `Listing_Status__c` and the `Broker_Alert_Due` report cannot see it — which is exactly why `evaluate(Date, Integer)` is **PURE** (no SOQL, no DML, no `Date.today()` beyond its argument) and `listingStatusValue(Band)` exists with no caller today: they are the seam a deferred D9 job writes through so the stored value and the badge cannot derive from two different ladders. That job still needs a recipient population (D9 flags "Disposition team" as neither a queue nor a public group in this repo), a `notificationtypes/*` (the module has zero) and a post-deploy scheduling gate. Zero inline SOQL; `evaluateAll` is **2 SOQL / 0 DML for ANY number of dispositions**, pinned at 251. ⚠ **Two consumers, one derivation, on purpose** — the badge on the listing card and the traction panel beside it render from the same computation, the `EmailThreadAnchorService` shape, so they cannot contradict each other about whether to replace a broker. |
| `DispositionActionPermissionService` | `RecordStageAdvanceService` (via the per-record-type gate dispatch) | **The DISPOSITION stage-action gate — the sell-side twin of `OpportunityActionPermissionService`** (added 2026-08-09, D15/Q1; **rewritten 2026-08-12 with its twin — the two are ONE design, change both or neither**). ONE FACTOR: the `Disposition_Deal_Actions` CUSTOM PERMISSION, granted by the layer-5 `Disposition_Deal_Driver` set, plus the retained "Modify All Data" bypass. ⚠ **This row previously read "TWO-FACTOR: FLS read on `User.Disposition_Driver__c` … AND that flag `true`" and stated that the Modify All Data bypass "runs BEFORE the flag read, and reversing those two statements is a lockout" — every part of that is now false.** With no field read there is no statement that can throw an FLS denial, so the ordering constraint died and the code deliberately INVERTS it (cost: `checkPermission` is 0 SOQL, so only a non-driver pays the bypass read). 🔴 **This module is where the FLS defect actually landed, which is why it paid for the migration first:** `NDA__c.Is_Decline_Allowed__c`'s XML comment records that a disposition driver holds FLS on `Disposition_Driver__c` and NOT on `Deal_Driver__c`, so `{!$User.Deal_Driver__c}` could never evaluate true for them — precisely why this class and its field had to be invented in Tranche 3A (review C1). Of the three rejected shortcuts, two survive under the new token and still look like tidying: granting the ACQUISITIONS token to disposition users, and one shared `Deal_Actions` permission for both modules — both merge two authorization boundaries into one and make `RecordStageAdvanceService`'s per-record-type gate dispatch decorative. The third (a permission-set MEMBERSHIP check) is now **moot rather than rejected**: there is no flag left for membership to disagree with. Reads via `PermissionSetAssignmentSelector` ONLY; no DML. It reuses `OpportunityActionPermissionService.NO_PERMISSION_MESSAGE` rather than re-declaring it, so the two gates can never speak with two voices. ⚠ **`UserSelector` is no longer called from this class at all** — the note about keeping the two flag reads as separate queries described a real trap, but one that was a property of the flag model; see that class's header before carrying it forward. |
| `TransactionActionPermissionService` | `RecordStageAdvanceService` (via the per-record-type gate dispatch, `StageActionGate.TRANSACTION_STAGE_ACTIONS`) | **The TRANSACTION stage-action gate** (added 2026-08-12 with the Transaction Advance Stage action; **rewritten the SAME DAY** by the custom-permission migration). ONE FACTOR: the `Transaction_Stage_Actions` CUSTOM PERMISSION, granted by `Transaction_Stage_Actions_Access`, plus a "Modify All Data" bypass. ⚠ **This row previously read "IT IS MEMBERSHIP-ONLY, AND IT IS THE FIRST GATE IN THIS TABLE THAT IS NOT TWO-FACTOR" — that is now false in both halves**: it no longer tests set membership, and it is no longer the odd one out, because all three stage gates are now the same shape. 🔴 **THE SWAP IS A MECHANISM CHANGE, NOT A POLICY CHANGE, AND THE DISTINCTION IS THIS ROW'S MOST IMPORTANT CLAIM.** The permission is carried by the SAME set that previously WAS the token, so at the instant the deploy completes exactly the current holders hold it — custom-permission grants are deployable metadata even though `PermissionSetAssignment` is not, so the population is preserved **by construction** with no in-org step. 🔴 **What it BUYS is declarative hideability, not granularity:** a flexipage `<visibilityRule>` cannot test permission set membership (there is no `$PermissionSet` global), so until now this was the one stage action in the application whose button could not be hidden from a user who may not use it — `Transaction__c` appears in **zero** of the seven gated record pages, a CONSEQUENCE of the membership design rather than an oversight. 🔴 **THE TEAM-WIDE POLICY SURVIVES INTACT — do not read the swap as having fixed it.** `Transaction_Stage_Actions_Access` is a member of `DPEG_Transaction_Team` and a group's membership is the unit of assignment, so **per-user revocation is still not available**: denying one user means removing them from the group and losing its other ten sets with it. The remedy, when a real need appears, is to move the permission onto its OWN directly-assigned layer-5 set (the `Acquisition_Deal_Driver` shape) — argued from that need, never from symmetry with Opportunity. ⚠ **The permission sits on a LAYER-4 set here, a deliberate divergence from both siblings**, and is safe for two reasons: it preserves the existing population exactly (anywhere else would be the change), and it is not a tautology because `RecordStageAdvanceController` also sits in the broad `DPEG_Apex_Access` catch-all, so a non-holder still reaches the gate and gets a clean `false` instead of a raw "You do not have access to the Apex class named …" toast. ⇒ **If that class is ever removed from `DPEG_Apex_Access`, the divergence stops being safe** — and it fails LOUD (a bad message), so no test catches it. 🔴 **THE ADMIN BYPASS HAD TO BE RE-IMPLEMENTED EXPLICITLY, and a literal swap would have dropped it silently.** It used to come free from `LeadActionPermissionService.hasAnyPermissionSet`, which checks Modify All Data from the same rows it reads; custom permissions are **not** implied by Modify All Data, so a bare `checkPermission` would have NARROWED access for every administrator with nothing naming the cause. ⚠ **The class no longer touches `LeadActionPermissionService` at all** — it lost that shared grant cache (0–2 queries → 0 for a holder, 1 otherwise; the group-expansion query disappears because the platform resolves custom permissions through groups itself) and **the test seams MOVED**: a test must now call `TransactionActionPermissionService.clearCache()` and use this class's own `simulateLookupFailure`; the old `LeadActionPermissionService.clearCache()` call is now a silent NO-OP for this gate. ⚠ **The enum member is still deliberately NOT named `TRANSACTION_DRIVER`** — a `*_DRIVER` name would assert a flag a reader would then go looking for, and there has never been one here, which is also why this gate never had the sibling gates' admin-lockout hazard. Reads via `PermissionSetAssignmentSelector` (bypass path only); no DML. |
| `EmailThreadAnchorService` | `EmailCaptureQueueable`, `EmailThreadAdopterService`, `EmailThreadGuardService` | **The SHARED thread-anchor index** (added 2026-08-02 with the adopter): performs the ONE anchor read per queueable execution and the ONE bracket normalization, then hands both halves an `AnchorIndex` they consume with opposite polarity (`isAnchoredOn` for the guard, `resolveOpportunity` for the adopter). It exists so the two features normalize identifiers IDENTICALLY BY CONSTRUCTION rather than by convention. **A THIRD ACCESSOR was added 2026-08-04 for the guard's dedupe rule: `isMessageIdAnchoredOn(recordId, message)`, backed by a second per-record map holding `Task.Inbound_Message_Id__c` ONLY — deliberately NOT the union `isAnchoredOn` uses, and NOT first-wins.** ⚠ The two must never be collapsed: conversation-level identity (`Thread_Key__c`, shared by every message in a thread) is the right key for "is this relevant here?" and the WRONG key for "is this redundant here?" — substituting it would delete EAC's copy of every outbound reply, which is the only representation of outbound mail anywhere in Salesforce. The union is lossy, so the Message-ID half is retained separately as it is read rather than filtered back out. Same query, same loop, same single normalization: **zero new SOQL.** Read-only; no DML. Reads via `TaskSelector.selectThreadAnchorsByAnchorValues` + `EmailMessageSelector`. `with sharing`. |
| `EmailThreadAdopterService` | `EmailCaptureQueueable` (via `EmailMessageTrigger`), and a one-off DevOps sweep | **EAC Thread Adopter** (added 2026-08-02): the MIRROR of the guard. EAC is the only system that sees the OUTBOUND half of a deal thread, but it associates by address, so the reply lands on the broker's Lead/Contact rather than the deal. This service re-points `EmailMessage.RelatedToId` to the Opportunity the thread's own pipeline anchor names — an RFC-header IDENTITY match, which beats EAC's address inference. Owns the only `RelatedToId` DML (`Database.update(..., false)`, one bulk statement) and performs **ZERO Task DML, ever** — the platform propagates the value onto the companion Task's `WhatId` by itself (measured, E2), which is what preserves the guard's structural guarantee. Reads via `EmailMessageSelector` + `TaskSelector`. **`without sharing`** (same justification as the guard: it must adopt onto EVERY resolved Opportunity, not the subset the automated principal can see). |
| `EmailThreadGuardService` | `EmailCaptureQueueable` (via `EmailMessageTrigger`), and a one-off DevOps sweep | **EAC Thread Guard** (added 2026-08-02): undoes Einstein Activity Capture's address-based over-association on Leads. EAC is THREAD-BLIND — it staples every captured email onto every record whose address appears on it, so a brand-new unrelated conversation with a broker lands on that broker's deal Lead. No EAC setting can prevent it, so the guard runs *after* capture: an EAC-materialized email may stay on a Lead only if its `ThreadIdentifier`/`MessageIdentifier` matches a thread anchor the Broker Protection pipeline logged there (`Task.Thread_Key__c` / `Task.Inbound_Message_Id__c`). Anything unanchored is deleted with its companion timeline Task — **unless the capture also lives on a record outside `{Lead, User}`** (see the scope note below). Owns all DML in the feature (`Database.delete(..., false)` — the two deletes cascade into each other, so an already-gone row is SUCCESS). Reads via `EmailMessageSelector` + `EmailMessageRelationSelector` + `EmailThreadAnchorService`. **`without sharing`** (justified in the class header: it must clean EVERY Lead the capture landed on, not the subset the automated principal has sharing to). **Amended 2026-08-02 for the adopter:** it now runs SECOND (after the adopter, in the same job), consumes the shared anchor index, and its guard 4 is widened from "anchored on a related Lead" to "anchored on ANY record it lives on" — related Leads ∪ the `RelatedToId` record. Every one of those changes is KEEP-BIASED. **⚠ AMENDED 2026-08-04 — IT NOW DELETES FOR TWO REASONS AND HAS FIVE SCOPE GUARDS.** Guards 1–3 are admissibility (all must hold); guards 4 and 5 are the two delete reasons and exactly one must hold. Guard 5 (NEW): a capture ADDS NOTHING NEW when `Incoming == true` **and** its normalized `MessageIdentifier` equals a normalized `Task.Inbound_Message_Id__c` present on **EVERY** record in `relatedLeadIds ∪ {RelatedToId}` — EAC's duplicate copy of an inbound broker email the pipeline already logged. **The delete condition IS the safety invariant: a timeline goes 2 → 1, NEVER 1 → 0**, because a pipeline row must already exist on every record the capture is removed from; if that cannot be established for even one record the capture is KEPT. Universally quantified (`&&`), the exact opposite quantifier from guard 4's existential (`||`) — both fail safe toward keep. 4 and 5 are disjoint populations (an exact duplicate is by definition anchored), so they share the one bulk delete pair: **query budget stays 7, DML stays ≤2, enqueue stays 1, and `EmailCaptureQueueable` is untouched.** ⚠ THE SURVIVING ROW IS THE PIPELINE'S AND ITS CAPTION IS WRONG ("You sent an email", derived from `EmailMessage.Incoming`, which a standalone Task has no counterpart for) — that trade was a **user decision at Gate 1**, not a defect. Two stated boundaries: **converted deals keep their duplicates** (the pipeline files on the Opportunity, EAC relates to the Contact, so guard 2 declines — correct under W1) and **L1: the rule is one-shot at capture time** (a capture arriving before the pipeline's Task is kept and nothing re-examines it; the remedy is the `run(Set<Id>)` sweep, never a Task trigger, which would create a second route to a Task and destroy the structural-unreachability guarantee). |
| `DealFolderService` | `OpportunityReviewTriggerHandler` (sync claim), `DealFolderQueueable` and `DealFolderSweepBatch` (async create), `DealFolderFinalizer` (`markFailed`) | **The SharePoint deal folder — created when an acquisition deal ENTERS `Closed Won`** (added 2026-08-11). The orchestration half: stage-entry detection, folder naming, the callout budget, the result stamp and every skip decision. 🔴 **IT IS ON THE OPPORTUNITY TRIGGER FOR `PropertyAssetService`'s REASON, NOT BY ANALOGY** — `StageAdvanceService.NEXT_STAGE` maps **both** `PSA ⇒ Closed Won` **and** `About to Close ⇒ Closed Won`, so a deal driver reaches Closed Won with no `Transaction__c` at all and building this into `Transaction_Complete_Close` would have missed half the closes, invisibly. ⚠ That argument does **not** rule Flow out on its own; what rules Flow out is that a per-record interview would attempt 251 × 7 = 1,757 HTTP Callout actions against a hard limit of 100 per transaction, and Flow's callout action has no `HttpCalloutMock` seam at all. 🔴 **THREE GATE-1 DECISIONS OVERRIDE THE DESIGN DOCUMENT'S DEFAULTS AND THE DOCUMENT STILL READS THE OTHER WAY:** (i) VENUE is a **Queueable chained from the trigger** (D1 Option A), not the work-queue+sweeper Option B — under which the sweeper becomes MORE load-bearing, not less; (ii) STRUCTURE is the **six-subfolder LIFECYCLE TREE** (`01 - NDA` … `06 - Closing`; D2 recommended flat), which multiplies the callout cost per deal by **SEVEN** and is the decision that reshapes the whole build; (iii) LOCATION is the **library ROOT**. 🔴 **THE NEVER-THROW RULE IS THE HARDEST CONSTRAINT AND IT IS NOT ABSOLUTE — read it exactly as far as it goes.** `ensureOnClosedWon` cannot throw a **catchable** exception (a SharePoint problem must never roll back a deal close: the folder is recoverable by a sweep, the close is a human's work), and this is the deliberate OPPOSITE of `PropertyAssetService`, which is `allOrNone = true` and throws on purpose because its silent absence WAS the bug — do not harmonise them. But SP-R1 measured a `LimitException` escaping a `catch (Exception)` positioned directly around the failing statement, so the ONE uncatchable path — `System.enqueueJob` at the 50-job cap — is bounded by an explicit `Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()` guard, exactly as `EmailMessageTriggerHandler` does, and skipping is safe **because the rows were stamped `Pending` BEFORE the enqueue** so the sweep recovers them. ⚠ "Place the call last in the handler" is NOT a substitute for either mechanism — a throw anywhere in a trigger rolls back the whole transaction regardless of statement order. **THE CALLOUT ARITHMETIC:** 7 callouts/deal against 100/transaction gives a hard ceiling of 14 deals, but `MAX_PROPERTIES_PER_TRANSACTION = 10` is chosen against the **cumulative 120 s TIME limit**, not the count — 14 × 7 at a pessimistic 1.5 s each is 147 s, and both limits throw UNCATCHABLY. `hasBudgetForOneProperty` re-checks both before each property and DEFERS the remainder, so a slow tenant degrades into more chained links rather than dying. 🔴 **`createTree` has NO mid-tree budget check and that is correct** — abandoning halfway leaves a parent folder whose id IS the idempotency guard, so nothing would ever retry it; the price is that `SharePointCalloutService.TIMEOUT_MS` must be derived from the 30 s the 90 s budget leaves (see that class). **IDEMPOTENCY is `Property__c.SharePoint_Folder_ID__c`** — non-blank means zero callouts on every path, keyed on the PROPERTY (matching `PropertyAssetService`), re-evaluated inside the callout transaction so a concurrent close, a chained link and a sweep all converge on one folder. ⚠ `conflictBehavior: rename` guarantees a duplicate SUCCEEDS rather than colliding, which is what makes an under-read guard SILENT — and is the whole reason the guard read escapes sharing. Budget: **sync 0 callouts / 1 SOQL / ≤1 DML / ≤1 enqueue, CONSTANT in deal count** (a chunk closing nothing costs zero of all four; a re-save of already-foldered deals costs 1 SOQL and nothing else — the duplicate-folder falsifier); **async ≤70 callouts / 1 SOQL / ≤1 DML per link**. Residuals, stated rather than hidden: **R1** a null `Property__c` gets no folder and nothing says so (same decision as `PropertyAssetService`; all four result fields live on `Property__c`); **R2** a partial subfolder failure is TERMINAL, stamped `Created` with the missing names, because the parent id is the guard and a re-run under `rename` would produce "01 - NDA 1"; **R3** a stamp DML failure after a successful callout leaves a real folder Salesforce cannot name, and the next sweep creates "Name 1"; **R4** a `webUrl` over 255 chars is omitted, not truncated; 🔴 **R5 every deal ALREADY at `Closed Won` on deploy day is invisible to BOTH the trigger (stage-ENTRY semantics) and the sweeper (null status is not in the `Pending`/`Failed` locator) — permanently, with nothing erroring. USER DECISION 2026-08-11: OUT OF SCOPE. The feature applies to deals closing from the deploy forward; the named remedy is a one-off anonymous-Apex stamp of `Pending` (spelled out in the class header), never a code change.** |
| `DealFolderQueueable` | chained from `DealFolderService.ensureOnClosedWon`, ONCE per trigger chunk; and from itself | The ASYNC VENUE and the self-chain (Gate-1 decision (i)). Walks ≤10 properties and RE-ENQUEUES ITSELF for the remainder. 🔴 **ASYNC IS FORCED TWICE OVER and neither reason substitutes for the other:** a callout cannot be made with the deal close's uncommitted DML pending (`You have uncommitted work pending`), **and** 7 callouts/deal against 100 means a 251-deal bulk close cannot be done in one job at any batch size. 🔴 **EXACTLY ONE `System.enqueueJob` PER LINK — `Limits.getLimitQueueableJobs()` is 1 inside an async transaction, not 50**, so the deferred remainder is returned by the service as ONE list and dispatched by ONE call; `RoutingRetrySweepBatch`'s header records the same constraint from the other direction. Chaining itself escapes the 50-per-transaction cap because each link is its own transaction — which is what makes an unbounded deal count expressible at all. ⚠ **The chain is SUPPRESSED inside `@isTest`** (chaining a Queueable from a Queueable raises `System.AsyncException: Maximum stack depth has been reached` — a platform behaviour), so the enqueue is `Test.isRunningTest()`-guarded and the DECISION is exposed on `lastRunChainedIds`: same seam, and same reason, as `EmailThreadAdopterService`'s `AdoptionWriter`. ⚠ **THE RUNNING PRINCIPAL IS THE ENQUEUING USER — measured live** (`RAN AS USERNAME: usman.khan.dpeg@…`, not Automated Process), so per-user External Credential Principal Access applies to this job. That single fact is why the sweep below is load-bearing. No SOQL, no DML, no callouts of its own. |
| `DealFolderFinalizer` | attached as the FIRST statement of `DealFolderQueueable.execute` | The folder job's FAILURE REPORTER, and the third Finalizer in this repo after `AttachmentPersistFinalizer` and `RoutingFailureFinalizer`. On `UNHANDLED_EXCEPTION` it stamps `Failed` plus a durable reason through `DealFolderService.markFailed`. 🔴 **A `try/catch` cannot substitute, and that is MEASURED:** SP-R1 ran heap- and CPU-exhausting Queueables with `catch (Exception e)` positioned directly around the failing code and **the catch never ran**; SP-3 measured a Finalizer's own DML committing durably in a fresh transaction after the parent's total rollback. A job that walks 70 callouts is a genuine candidate for the callout-count, CPU and cumulative-callout-time limits — all uncatchable. **It RECORDS but never RETRIES** (`DealFolderSweepBatch` already sees these rows; a Finalizer's enqueue is accepted-but-never-executed in `@isTest`, and an uncatchable failure is usually deterministic). ⚠ **Only `UNHANDLED_EXCEPTION` is acted on** — a Finalizer fires on SUCCESS too, and acting then would overwrite the `Created` stamps the job just committed. ⚠ **No type check on the exception:** SP-3/SP-R1 measured the platform WRAPPING an uncatchable failure as `System.AsyncException` while SP-R2 measured an ordinary custom exception arriving UNWRAPPED, so this class records type and message verbatim and classifies nothing. 1 SOQL / ≤1 DML, in its own transaction. |
| `DealFolderSweepBatch` | `DealFolderSweepSchedule` (daily, off-peak) | The RETRY / RECOVERY engine — `Pending` or `Failed` → re-run the identical creation path. 🔴 **UNDER OPTION A THIS IS MORE LOAD-BEARING THAN THE DESIGN ANTICIPATED, AND THE REASON IS A MEASURED PROVISIONING FACT, NOT A HYPOTHETICAL:** a Queueable runs as the ENQUEUING USER (measured live), `SharePoint_Integration_Access` is granted to **`DPEG_Junior_Analyst_PSG` only — NOT `DPEG_Transaction_Team`**, and `Transaction_Complete_Close` writes `StageName = 'Closed Won'` with **no `<runInMode>`**, i.e. as the TRANSACTIONS persona. **So every deal closed through the Transactions route runs the folder job as a user with no credential grant and its callouts WILL be refused** — a whole ordinary closing route, expected to land here, failing visibly on `Failed` with `DealFolderService.HINT_CREDENTIAL` naming the gap. This batch, running as a granted scheduling principal, is the only thing that closes it. **`Pending` AND `Failed`, neither sufficient alone:** `Pending` is written synchronously before any callout exists, so it catches a job that died uncatchably, was never enqueued or lost its chain; `Failed` catches the credential gap and every transient Graph refusal. `Created`/`Skipped` are terminal and excluded BY THE QUERY, which is what makes re-running free. **Idempotent and convergent** — a populated folder id means zero callouts, so every pass strictly shrinks the queue. ⚠ **DELIBERATELY NO ATTEMPT CAP AND NO AGE CAP — a considered divergence from `RoutingRetrySweepBatch`, which has both.** There a replay could mint a second Lead; here a retry is a no-op once it has succeeded, and the failure is very often an ADMIN ACTION away (grant the credential, enable the config, fix the site id), so abandoning a row would silently cancel a folder the moment the admin fixed the cause. If a large permanently-failing population ever appears, add a cap THEN, with the population as evidence. 🔴 **`SCOPE = 10` is the CALLOUT BUDGET, not a throughput knob** — taken from `DealFolderService.MAX_PROPERTIES_PER_TRANSACTION` so the batch and the queueable cannot drift into two budgets for one unit of work. |
| `DealFolderSweepSchedule` | scheduled daily, off-peak, post-deploy | The trigger for the sweep. 🔴 **A deploy that does not schedule it does not ship a degraded feature — it ships a feature that DOES NOT WORK FOR AN ENTIRE PERSONA** (every Transactions-route close, per the row above), while nothing errors and the rows sit on `Failed` with a fully explanatory error, i.e. LOOKING handled. Job instances are not deployable metadata, so this is a verified post-deploy gate. 🔴 **WHO OWNS THE SCHEDULE IS PART OF THE GATE, not only that it exists** — a batch's callouts run as the scheduling user, so a schedule owned by a principal without `SharePoint_Integration_Access` reproduces the exact failure this job exists to absorb, and reproduces it on EVERY deal rather than only the Transactions ones. Record the owning user alongside the cron expression and re-verify when that user is deactivated. ⚠ The reads and writes are safe regardless (`SYSTEM_MODE` + `without sharing` inner class), so a mis-owned schedule fails LOUDLY on every row rather than returning an all-zero summary indistinguishable from a healthy pipeline. ⚠ **DAILY, not hourly** — the deliberate contrast with `RoutingRetrySweepSchedule`: a broker's registry claim is TIME-ORDERED and retry latency is paid by a real broker losing a property, whereas a deal folder that appears the morning after the close is merely late and the deal is already won. Re-running is free, so scheduling it more often is harmless; scheduling it less often is not. |
| `SharePointCalloutService` | `DealFolderService` (via its private `LibraryTarget`) — the ONLY caller | The dedicated Graph callout wrapper: creates ONE folder under a parent item and returns a typed `FolderResult`. Per §2 Standards the single `Http.send` in this feature lives here and NOWHERE else, so callers mock one boundary. No SOQL, no DML, no config reads — every value is a parameter. **It is the SECOND standing §3 exception (direct, non-ASB callout), accepted at the design gate; see §3.4.** 🔴 **ADDRESSING IS BY PARENT ITEM ID, NEVER BY PATH** — `EncodingUtil.urlEncode` emits `+` for a space (correct for a query string, WRONG for a path segment, which needs `%20`) and DPEG property names contain spaces constantly, so path addressing would create folders with literal `+` characters or 404 intermittently depending on the name. Item-id addressing has no encoding surface at all. 🔴 **`conflictBehavior` IS `rename` AND `replace` IS PROHIBITED** — `replace` on an existing folder DESTROYS ITS CONTENTS, which here means signed LOIs, executed PSAs and closing documents; `fail` was rejected (D3) because adopting on 409 needs a GET by PATH, re-opening the encoding trap. The cost of `rename` is a stated residual: two properties sharing a Name yield "Magnolia Crossing" and "Magnolia Crossing 1". 🔴 **IT NEVER THROWS** — transport failure, timeout, refused credential and malformed body all resolve to a result carrying `statusCode` (0 when no exchange completed, which is what a missing Principal Access looks like from Apex) and a human-readable message; that is what lets one bad property stay one bad property and what keeps the caller's never-throw contract expressible. ⚠ It cannot catch an uncatchable platform limit — those are bounded by the CALLER's budget guards. 🔴 **`TIMEOUT_MS` IS DERIVED, NOT ROUND: 4 000 ms** = (120 000 platform cumulative − 90 000 admitted by `CALLOUT_TIME_BUDGET_MS`) ÷ 7 `CALLOUTS_PER_PROPERTY`, rounded down. The former 15 000 gave a worst case of 7 × 15 s = 105 s ON TOP of a property admitted at 89.9 s ≈ 195 s — a breach of the cumulative ceiling that throws UNCATCHABLY and rolls back AFTER real folders exist but BEFORE their ids are stamped, i.e. residual R3 at scale. Raising the budget or growing the subfolder list invalidates this constant and it must be re-derived by hand. |
| `SharePointConfig` | `DealFolderService` (`isReady`/`unavailableReason` on the sync path; `LibraryTarget` on the async path) | Configuration accessor for the deal-folder feature — site, drive, optional parent folder, master switch. Backed by `SharePoint_Config__c`, the **SECOND** hierarchy Custom Setting in this repo, chosen because `getOrgDefaults()` costs **ZERO SOQL** and this accessor is consulted on the Closed Won path inside an after-update trigger. 🔴 **THERE IS NO FALLBACK AND ADDING ONE WOULD BE A DEFECT** — it is tempting to "helpfully" default the site id to the one the developer tested against; that is precisely the failure, because a silent default is indistinguishable from correct configuration until deal documents are discovered in the wrong tenant's library. ⚠ **IT DEGRADES TO DISABLED — THE OPPOSITE OF `ContentPublicationBudget`, DELIBERATELY.** That class fails OPEN because a malfunctioning backstop must not block a working feature; this one fails CLOSED because an INTEGRATION that cannot read WHERE to write must not guess. A `Skipped` stamp is recoverable by an admin; an external write to an unknown destination is not. ⚠ It also does NOT create an org-default row at runtime, unlike its precedent — that would only produce a disabled, site-less default, which is the state `isReady()` already reports without writing anything. Populating it is a post-deploy gate. ⚠ **Every field read is STATICALLY TYPED** (`config.Site_ID__c`): the dynamic `config.get('Site_ID__c')` reflection was removed 2026-08-11 because a renamed or mistyped field COMPILES, throws at runtime, is swallowed by the catch and returns null — while `isReady()`, which reads statically, would still report `true`, leaving the feature healthy-looking and making zero callouts. Static access turns that state into a compile failure. |

**⚠ TWO STAGE-ADVANCE SERVICES — know which one you are editing (2026-08-04).**
`StageAdvanceService` is **Opportunity only**: its `advance()` BRANCHES into an approval submission,
and `advanceTo()` exists solely because Opportunity has parallel record-type branches (Land /
Commercial) plus an off-ramp — which is why it carries `ALLOWED_EXPLICIT_TARGETS`.
`RecordStageAdvanceService` covers the **six child objects**. ⚠ The claim this paragraph used to
make — "all of whose paths are LINEAR, so it has no branch, no off-ramp, and deliberately no
explicit-target method" — has been **false since 2026-08-05**, when the LOI `Sent` branch added
`LOI_EXPLICIT_TARGETS` and `advanceTo`; the disposition NDA's `Declined` off-ramp (2026-08-09) is the
second case. The accurate statement is that it has **no *generic* explicit-target method**: every
explicit write is checked against an allow-list scoped to the record's own **record type**. They were
**not** merged: the
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
future read belongs there.
`OfferingSelector` (new, 2026-08-16) joins that list as the **first and only `Offering__c` SOQL in
the application** — there was none before it; every future `Offering__c` read belongs there rather
than inlined into whatever service needs it next. ⚠ Note it is a *different* kind of "first" from
the two above: those were reads a new feature happened to need, whereas this object had **no code of
any kind** touching it, which is why `OfferingService` and `OfferingSelector` arrived together. Its single method `selectByOpportunityIds(Set<Id>)` is what makes
`LeadConvertService`'s broker-role write a read-then-write instead of a blind insert, and it is
called **once per invocation for the whole converted set** (it is SOQL 2 of that service's 2-SOQL
contract). Never call it per record.

**🔴 `UserSelector` IS AN EMPTY SHELL AS OF 2026-08-12, AND IT WAS THE FIRST AND ONLY `User` SOQL IN
THE APPLICATION.** It held exactly two methods — `selectDealDriverFlagForCurrentUser()` and
`selectDispositionDriverFlagForCurrentUser()` — and both were removed when the `User.Deal_Driver__c` /
`User.Disposition_Driver__c` authorization-flag model was retired in favour of custom permissions.
Nothing calls it; the class body is now `{}`. **It is a DELETE CANDIDATE, not a keep** — retained only
so the two `User` fields, their `<fieldPermissions>` grants, this class and `UserSelectorTest` retire
as one reviewable change, per `docs/permission-set-retirement-runbook.md`'s
GRANT → VERIFY → REMOVE → SOAK → DELETE order (the fields are the rollback lever until then).
⚠ **THE CONSEQUENCE OF ITS DELETION IS LARGER THAN IT LOOKS, WHICH IS WHY IT IS RECORDED HERE RATHER
THAN ONLY IN THE CLASS:** once the file is gone, the next feature needing to read a `User` will find
no selector and will be tempted to inline the query, which `.claude/rules/apex-layering-rule.md`
forbids. **A future `User` read must RE-CREATE this selector**, exactly as `AccountSelector` and
`OpportunityContactRoleSelector` were created as the first reads of their objects.
⚠ **Restore its scope rule with it:** every method it ever held was hard-filtered to
`Id = UserInfo.getUserId()` and took no user parameter, which is what made it safe to reach
(indirectly) from an `@AuraEnabled` boundary — a user could never map out who in the org can drive
deals. A method accepting a `Set<Id>` of users is a security decision needing its own argument, not a
bulkification improvement. ⚠ **Do NOT carry forward its one-field-per-query rule**: that existed
because a `WITH USER_MODE` throw was half the gate, and it dies with the flags. The transferable part
is the general trap it was an instance of — a `USER_MODE` query throws on the WHOLE row for ONE
inaccessible field, so widening a selector's field list can break a caller unrelated to the new field
(see `InboundEmailStagingSelector.selectById`).

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

🔴 **Amended 2026-08-10 — U2 now releases the carrier UNCONDITIONALLY, on both match and
no-match, which is STRONGER than the design anticipated.** `finish()`'s last statement enqueues the
file job, and a matched deal gives it a non-null target, so **without an explicit suppression flag
consulted ABOVE the targets check**, call-for-offers traffic would start consuming
`ContentPublication` quota — the quota behind the 2026-08-06 outage. A flag is required rather than
simply calling `releaseCarrier()`, because that writes the **database** while the in-memory
`Attachment_Status__c` still reads `'Pending'`, so the enqueue check would pass anyway.

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
   ⚠ **Amended 2026-08-10 — the gate may now stamp a matched live deal.** `ExtractAddressQueueable`
   routes a gated call-for-offers email into `CallForOffersStampService` via the claim-pipeline
   registry route ONLY — **Opportunity only** (the stamp is inert for an unconverted winner; that is
   the decision, not a defect). **"Where no deal matches, nothing is created" is unchanged** — U2
   still produces no Lead and no claim.
   ⚠ **The misclassification risk sharpens, not lessens.** A genuinely exclusive listing
   misclassified as `call_for_offers` still leaves the property unclaimed and recoverable only by
   manual registry surgery, so `Gated_Call_For_Offers` is **more** load-bearing than before, not
   less. Its list-view filter was widened to `1 OR 2` so a `Multi-Property (N):`-prefixed summary
   still appears there.
   ⚠ **Best-and-final was deliberately NOT built.** The client document's *"best-and-final
   requirement … held alongside it"* is a **decided gap, not an oversight**.
   ⚠ **A third thread-anchor consequence (review W3).** A matched email's Task now carries a
   `WhatId`, so a follow-up in that thread hits `routePrologueWithoutCallout` — filed on the
   Opportunity, **no callout, no extraction, no claim**. Campaign threads are exactly where a
   follow-up names another property. Accepted, consistent with the standing branch-(a) trade-off,
   but it widens a claim-loss vector to a new traffic class.

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

**The stage-action gates are ONE-FACTOR: a CUSTOM PERMISSION (rewritten 2026-08-12; this subsection
was titled "Opportunity deal-action gate is TWO-FACTOR" from 2026-07-30 until then).**
`OpportunityActionPermissionService` asks the identical question the deployed Dynamic Actions
visibility rules on `Opportunity_Record_Page` ask — `{!$Permission.CustomPermission.Acquisition_Deal_Actions}`
— which is satisfied by holding the `Acquisition_Deal_Actions` custom permission, granted by the
layer-5 `Acquisition_Deal_Driver` permission set. `DispositionActionPermissionService`
(`Disposition_Deal_Actions` ← `Disposition_Deal_Driver`) and `TransactionActionPermissionService`
(`Transaction_Stage_Actions` ← the layer-4 `Transaction_Stage_Actions_Access`) are the same shape.
Every gate retains the "Modify All Data" bypass.

**The retired model, recorded because its rules are still quoted:** the gate required BOTH **(a)** FLS
read on `User.Deal_Driver__c`, enforced by `WITH USER_MODE` inside `UserSelector`, where a THROW was
the denial signal, AND **(b)** the field value `Deal_Driver__c = true` on the running user's own
record. Both factors are gone; no Apex in this repo reads either `*_Driver__c` field.

🔴 **WHY — MEASURED, NOT PREFERRED. A flexipage `<visibilityRule>` that references a FIELD evaluates
FALSE for any user lacking FLS READ on that field.** No error, no log, no warning — the button is
simply absent, which is indistinguishable from "this feature is not for me". This repo paid for that
twice: it is recorded on `NDA__c.Is_Decline_Allowed__c` (it is *why* the disposition persona needed
its own field and service at all, review C1), and it was re-demonstrated live on 2026-08-12 when
removing one permission-set assignment cost a System Administrator the ability even to QUERY the flag
— `No such column 'Deal_Driver__c' on entity 'User'` is the **FLS-denial signature**, not a schema
error. A custom permission has **no FLS surface at all**, so the entire failure class is REMOVED
rather than mitigated. That, not the query saving, is the justification.

🔴 **THE "Modify All Data" ORDERING CONSTRAINT IS DEAD, AND THE CODE NOW DELIBERATELY INVERTS IT — DO
NOT "FIX" IT BACK.** This subsection used to state that the Modify All Data check **MUST** run before
the flag read or every administrator is locked out of the feature they just deployed. That was
correct and load-bearing *while a `User` field was in the path*: a Metadata-API-deployed custom field
arrives with no field permissions for ANY profile, System Administrator included, and Modify All Data
is an OBJECT permission conferring no FLS, so the selector threw for a bare admin exactly as for a
bare Standard User — **before** the bypass was ever reached. With the field read gone **there is no
statement left that can throw an FLS denial**, so the order is no longer a correctness constraint.
All three services now test the custom permission FIRST, ordered on **cost**:
`FeatureManagement.checkPermission` costs **0 SOQL**, so a holder pays nothing and only a non-holder
pays the single `PermissionSetAssignment` read behind the bypass. Restoring the old order breaks
nothing but makes every driver pay a query for no reason; **re-adding any `User` field read re-opens
the lockout and must restore the ordering rule with it.**

⚠ **What did NOT change: capability and authorization are still separate, and the ARGUMENT for it
moved.** The old reason this gate did not reuse `LeadActionPermissionService.hasAnyPermissionSet(...)`
was that *membership and the flag are different questions* — a user holding the set with the flag
`false` was denied and a membership check would have GRANTED them. **That argument is now MOOT, not
overturned:** there is no flag left for membership to disagree with, and the custom permission is
carried BY those same sets, so the population is preserved by construction (zero migration window —
custom-permission grants are deployable metadata even though `PermissionSetAssignment` is not). The
argument that survives is about **which LAYER carries the token**: `Acquisition_Deal_Actions` must not
be moved onto the layer-4 `Opportunity_Stage_Actions_Access`, because that set is a member of
`DPEG_Junior_Analyst_PSG` — the move would grant deal-driving to that entire group in one deploy and
would make the gate a tautology (everyone able to CALL it would automatically PASS it).
`OpportunityActionPermissionServiceTest.capabilitySetWithoutTheAuthorizationSet_isStillDenied`
(renamed 2026-08-12 from `hasDealActionAccess_membershipWithoutTheFlag_isStillDenied`) exists to go
red if anyone tries.

⚠ **The bypass still makes an admin smoke test worthless, and that is unchanged.** An administrator
passes for a reason unrelated to holding the custom permission, so acceptance-test as a real
deal-driver persona. What HAS changed is that a bare admin is no longer LOCKED OUT — they are
bypassed.

⚠ **The boundary moved in NEITHER direction (measured 2026-08-12).** Only Junior Dhanani held either
`*_Driver__c` flag as `true`, and Junior holds `Acquisition_Deal_Driver`, which now carries
`Acquisition_Deal_Actions`; nobody holds `Disposition_Deal_Driver`, so nobody gained the disposition
actions. `FeatureManagement.checkPermission` costs **0 SOQL / 0 DML**, takes a runtime String (so
Apex compiles and deploys before the permission exists), returns `false` rather than throwing for an
unknown or unheld name — so the gate fails **closed** if the admin half is missing — and it DOES see
a `PermissionSetAssignment` inserted in the SAME transaction (probe-measured, so positive-path test
fixtures need no restructuring). It also resolves grants **through permission set groups itself**,
which is why no Apex group expansion is needed.

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

### ⚠ `CounterOfferService` and `PsaVersionService` are ONE design applied to TWO objects — change both or neither (2026-08-09 / 2026-08-10)

Both are negotiation LOGS that stamp a counterparty label onto their parent, and **the label inverts between a purchase and a sale**: `'Us'` / `'Ours'` always mean DPEG, while the counterparty is `'Seller'` on an acquisition and `'Buyer'` on a disposition. `Ball_In_Court__c = 'Seller'` on a SALE names DPEG — the field does not read oddly, it **inverts**, claiming the ball is with us at the moment it passed to the buyer.

3B fixed `CounterOfferService` (LOI). 3C then shipped **four metadata files naming `PsaVersionService` as the enforcement point** — `Disposition_PSA` exposes `Ball_In_Court__c` = {Us, Buyer} only, and both `Contract_Review__c.Ball_In_Court__c` and `PSA_Version__c.Direction__c` say so in their own descriptions — **and did not touch the class**, which still refused `'Buyer'` outright. Review C2. The 2026-08-10 fix pass ported the identical design rather than inventing a second one; the two now differ in nothing but object names.

Four properties are shared and load-bearing in both:

1. **The stored label is DERIVED from the parent row and NEVER taken from the caller.** A caller sending `'Seller'` on a sale gets `'Buyer'` stored. This is what makes a cross-record-type picklist write **structurally impossible** — necessary because record-type picklist restriction is UI-only and is not enforced by Apex DML, exactly as `RecordStageAdvanceService`'s per-record-type allow-list is for the stage field.
2. **`isSaleSide()` is record-type-first, `Disposition__c`-lookup-second**, with constant-first `String.equals` (Apex `==` on String is case-INSENSITIVE while the describe maps are case-SENSITIVE). The lookup leg is load-bearing, not defensive: until gate T-A1 every row sits on Master. 🔴 It matters MORE on `Contract_Review__c`, because both PSA record types expose the same four statuses, so a Master-type disposition PSA looks completely normal.
3. **`'Seller'` stays accepted on BOTH sides** — it is the incumbent wire token both deployed pickers send, and refusing it would leave their Save buttons dead. **`'Buyer'` is refused on an acquisition parent**, where it would name DPEG. The acquisition-side refusal wording is byte-identical to the pre-change message.
4. **The parent read is `WITH SYSTEM_MODE`** (see the automation-path table above) and the direction is validated **AFTER** the load, because the valid tokens are a property of the record type. Each service has a test pinning that a missing parent now raises `QueryException` rather than the typed refusal — the falsifier for a future "optimisation" that moves the check back in front of the load.

**Known, deliberately deferred (review S2):** neither `lwc/loiCounterOffer` nor `lwc/psaVersionLog` re-words its `directionOptions` picker on a sale. Both are functionally correct (the service rewrites the token); only the two labels read buy-side. The safe fix is a **server-supplied side flag on the existing read response** — never a client-side `Disposition__c` read, which would make the live acquisition cards depend on an FLS grant acquisitions personas deliberately lack. One shape serves both.

### Permission Set Architecture — the seven-layer model (added 2026-08-10)

The 2026-08-10 permission set cleanup — which added `Opportunity_Stage_Actions_Access`, the
Opportunity twin of `Lead_Stage_Actions_Access` — made explicit a layering model the split sets had
already followed **implicitly** since the 2026-07-22 RBAC build. This subsection is that model,
written down so a future reviewer can tell a deliberate structure from an accident before they "fix"
it. The one-time migration mechanics, the per-set residual arithmetic and the staged retirement
runbook live in `docs/permission-set-retirement-runbook.md` and `docs/2026-08-10-permission-set-
cleanup.md`; this section states the **standing rules**, not the migration itself.

**Seven layers, one job each:**

| # | Layer | Contains ONLY | Examples |
| --- | --- | --- | --- |
| 1 | Base | license-level `userPermissions` | `DPEG_Base_Access` |
| 2 | App visibility | `applicationVisibilities` + `tabSettings` | `DPEG_App_Acquisition`, `_Disposition`, `_Transaction`, `_PropertyMgmt` |
| 3 | Module data | `objectPermissions` + `fieldPermissions` + `recordTypeVisibilities`, for ONE module at ONE access level | `DPEG_Acquisition_Edit`/`_View`, `DPEG_Disposition_Edit`/`_View`, `DPEG_PropertyMgmt_Edit`/`_View`, `DPEG_Transaction_Edit`/`_View`, `DPEG_Contact_Edit`/`_View` |
| 3b | Module data, fine-grained | a deliberate SUBSET of a layer-3 set, existing so a persona can take one object without the whole module | `DPEG_Opportunity_View`, `DPEG_Property_View`, `DPEG_PropertyAsset_View`, `DPEG_Task_Edit`, `DPEG_TaskChecklist_View` |
| 4 | Capability | `classAccesses` + the platform `userPermissions` a named feature needs | `Lead_Stage_Actions_Access`, `Opportunity_Stage_Actions_Access`, `Transaction_Stage_Actions_Access`, `Broker_Protection_Access` |
| 5 | Authorization | the token that answers "is THIS user allowed" — since 2026-08-12 a `<customPermissions>` grant; formerly exactly ONE `fieldPermissions` entry on a `User.*` field read by a two-factor gate | `Acquisition_Deal_Driver` (carries `Acquisition_Deal_Actions`), `Disposition_Deal_Driver` (carries `Disposition_Deal_Actions`) |
| 6 | Persona group | a `PermissionSetGroup` composing layers 1–5 | `DPEG_Junior_Analyst_PSG`, `DPEG_Principal_PSG`, `DPEG_Transaction_Team`, `DPEG_Property_Management_Team` |
| 7 | Profile restoration | tabs / FLS / apps / record types the profile grants but that never deploy | `DPEG_Admin_Access` — exists ONLY because `profiles/**` is `.forceignore`d |

A user is assigned a **group** (layer 6), not a list of individual sets. The two deliberate exceptions
are layer-5 authorization sets and layer-4 capability sets whose population is narrower than any
group, which are assigned directly (`Acquisition_Deal_Driver`, `Disposition_Deal_Driver`).

**Custom permissions are the model's authorization TOKEN (added 2026-08-12).** The seven-layer model
previously had no vocabulary for them at all — layer 5 was defined as an FLS grant on a `User.*`
checkbox, which is the mechanism the stage-action gates retired. A `<customPermissions>` entry in a
`PermissionSet` is now the standard way a set says "the holder may do X", and Apex asks with
`FeatureManagement.checkPermission('X')` (0 SOQL, no FLS surface, resolves through permission set
groups by itself). Three exist: `Acquisition_Deal_Actions`, `Disposition_Deal_Actions`,
`Transaction_Stage_Actions`.

🔴 **WHICH LAYER CARRIES A CUSTOM PERMISSION IS THE WHOLE SECURITY QUESTION — the token is
layer-agnostic and the model is not.** A grant on a directly-assigned layer-5 set reaches a narrow,
per-user-revocable population; the identical grant on a layer-4 capability set inside a persona group
reaches that entire group and makes the gate a tautology, since everyone able to CALL it then PASSES
it. Both placements are live in this repo **on purpose**: the two deal permissions sit on layer 5,
while `Transaction_Stage_Actions` sits on the layer-4 `Transaction_Stage_Actions_Access` because that
set already WAS the gate's population under the membership check it replaced — so putting it anywhere
else would have been the change. Moving either deal permission down to layer 4 is a real WIDENING;
moving the Transaction one up to layer 5 is a real NARROWING. Neither is a tidy-up.
⚠ A layer-4 home is only defensible when the gate's controller ALSO sits in the broad
`DPEG_Apex_Access` catch-all, so a non-holder still reaches the gate and receives a clean `false`
instead of a raw "You do not have access to the Apex class named …" toast — see the class-access rule
below.

⚠ **Custom-permission GRANTS are deployable metadata even though `PermissionSetAssignment` is not.**
Putting a permission on an already-assigned set therefore preserves the population **by construction**
— zero migration window, zero in-org work. That is what made the 2026-08-12 migration a mechanism swap
rather than a policy change, and it is the property to preserve when introducing the next one.

#### Two measured platform facts about custom permissions — do not re-derive these

Both were established by deploy against `usman-dpeg` on 2026-08-12. They cost real time to discover
and neither is discoverable from a green local build.

**1. 🔴 THE FLEXIPAGE TOKEN HAS THREE SEGMENTS, AND THE PLATFORM REJECTS THE OTHER TWO SPELLINGS.**
A `<visibilityRule>`'s `<leftValue>` must read:

```
{!$Permission.CustomPermission.Acquisition_Deal_Actions}
```

Both `{!$Permission.Acquisition_Deal_Actions}` (dropping `CustomPermission`) and
`{!$CustomPermission.Acquisition_Deal_Actions}` (the plausible-looking global) were **REFUSED by the
Metadata API at deploy**. This fails loudly rather than silently, which is the good news — a rule
copied from a shortened form fails the deploy instead of quietly evaluating false — but it costs a
deploy cycle every time. All 24 live criteria and every written occurrence in Apex comments use the
three-segment form for exactly this reason; keep it that way, including in prose.

**2. 🔴 FLEXIPAGE VALIDATION RESOLVES A CUSTOM PERMISSION AGAINST ALREADY-COMMITTED ORG METADATA,
WHICH FORCES A TWO-PHASE DEPLOY.** A `CustomPermission` and a FlexiPage referencing it **cannot ship
in the same deploy** — the page is validated against the org as it stands *before* the deploy
commits, so the reference resolves against a permission that does not yet exist and the whole deploy
fails. Deploy the `customPermissions/` (and the permission sets granting them) **first**, then the
`flexipages/` in a second deploy. ⚠ This is a property of the FlexiPage validator, not of Apex:
`FeatureManagement.checkPermission` takes a runtime String, so **Apex compiles and deploys happily
against a permission that does not exist yet** and simply returns `false` — which is why the Apex
half can travel in either phase while the declarative half cannot.

**Subset ≠ duplicate.** `DPEG_Opportunity_View`, `DPEG_Property_View` and `DPEG_PropertyAsset_View`
are each a strict subset of a larger layer-3 set (`DPEG_Acquisition_View` for the first two,
`DPEG_PropertyMgmt_View` for the third) and are **correct, not redundant** — they exist so the
Transaction team can read Opportunity/Property without inheriting the rest of Acquisitions (LOI, NDA,
Underwriting, Counter Offer, PSA Version, Deal Message), and so any non-PM persona can read the
Property Asset (Sell Meter / Disposition surfaces) without pulling in the 15-object PM module.
Collapsing either pair to "remove duplication" forces over-granting. `DPEG_PropertyMgmt_Edit` /
`_View` overlapping on 13 of their 15 objects is the identical pattern one level up: `_View` alone
carries the read-only carve-out for the Yardi-mirrored `Work_Order__c` / `Work_Order_Activity__c`
(§1: "mirrored **read-only** from Yardi. No write-back except the Delay Reason flag"), which is why
`DPEG_Property_Management_Team` composes **both** — merging them would make the read-only mirror
editable. Name subset sets so a future reviewer finds the reason before they find the redundancy.

**The capability/authorization split, generalised.** The stage-action gate subsection above describes
one instance of a general pattern: a layer-4 capability set answers "can this code be reached at
all", and a layer-5 authorization set answers "is this specific user allowed".
`Opportunity_Stage_Actions_Access` (capability — Apex invoke on
`OpportunityActionPermissionController`, `StageAdvanceController`, `OpportunityApprovalController`,
`RecordStageAdvanceController`) and `Acquisition_Deal_Driver` (authorization — since 2026-08-12 the
`Acquisition_Deal_Actions` custom permission, formerly FLS read on `User.Deal_Driver__c`) are the two
halves of that one gate and **must never be merged in either direction** — moving the authorization
token into the capability set collapses two questions into one for the whole population of the set
that absorbs it, and makes the gate a tautology.
`OpportunityActionPermissionServiceTest.capabilitySetWithoutTheAuthorizationSet_isStillDenied` is the
falsifier; do not modify it. The disposition side follows the identical shape:
`Disposition_Deal_Driver` (carrying `Disposition_Deal_Actions`) is `RecordStageAdvanceController`'s
authorization half for the `Disposition_NDA` record type's gate, reached through
`DispositionActionPermissionService` — same two classes of set, same non-negotiable separation.

⚠ **The MECHANISM of the authorization half changed on 2026-08-12; the SPLIT did not.** Both halves
used to be described as FLS-on-a-`User`-field, and a third rejected option was a permission-set
MEMBERSHIP check. Neither description survives: the flags are retired, and membership is no longer a
distinct alternative because the custom permission is carried by those same sets. What survives
verbatim is the rule that a capability set and an authorization set answer **different questions** and
that one must not absorb the other.

**⚠ A LAYER-4 SET DOES NOT REQUIRE A LAYER-5 PARTNER (added 2026-08-12, rewritten the same day for
the custom-permission migration).** `Transaction_Stage_Actions_Access` is a layer-4 capability set
with **no layer-5 counterpart and deliberately none**: it carries the `Transaction_Stage_Actions`
custom permission itself, so it is simultaneously the capability set and the authorization token's
home. That is not a violation of the split; it is the split applied where only one of the two
populations exists. ⚠ The paragraph this replaces said the gate tested **MEMBERSHIP of that set**,
which was true only until 2026-08-12 — `TransactionActionPermissionService` now calls
`FeatureManagement.checkPermission`, and the set's role changed from *being* the token to *carrying*
it. The policy is identical either way, which is exactly why the swap was safe.

**The rule that actually governs is narrower than "always pair them":** a token that ALREADY drives
live access must not be replaced by one with a **broader** population, because that silently grants
every holder of the broader set. On the acquisition side this is concrete —
**24 `{!$Permission.CustomPermission.*}` visibility criteria across 7 record pages (18 acquisition +
6 disposition), verified 2026-08-12 against the committed originals** — every one of which would
start evaluating `true` for the whole of `DPEG_Junior_Analyst_PSG` if `Acquisition_Deal_Actions` were
moved onto the layer-4 set. ⚠ The figure this replaces, *"eight `{!$User.Deal_Driver__c}` references
on `Opportunity_Record_Page`"*, was right about that ONE page (it still has 8) and wrong repo-wide by
a factor of three, because it predated the disposition pages and the child-object pages. Where **no
narrower population exists**, there is nothing to widen, and inventing a layer-5 set so the shapes
match adds an undeployable org step (assign the set) whose omission fails silently. ⇒ **Pair a
capability set with a separate authorization set when a narrower population is being protected; do
not create one to satisfy symmetry.**

**⚠ A capability set placed inside a persona GROUP is TEAM-WIDE, and where it also carries the
authorization token that is the whole granularity — state it rather than let a reader infer per-user
control.** `Transaction_Stage_Actions_Access` is a member of `DPEG_Transaction_Team`, so the
Transaction stage gate answers "is this user on the Transactions team?" and **per-user revocation is
not available**: denying one user means removing them from the group and losing its other ten sets
with them. 🔴 **The 2026-08-12 migration did NOT change this and must not be read as having done so** —
moving from a set NAME to a custom permission carried by that same set buys a declarative
`<visibilityRule>` (there is no `$PermissionSet` global, so this button could not be hidden
declaratively before) and buys nothing at all in granularity. The placement is precedented —
`Opportunity_Stage_Actions_Access` sits inside `DPEG_Junior_Analyst_PSG` the same way. The difference
is that Opportunity's per-user granularity comes from `Acquisition_Deal_Driver`, a **directly
assigned** layer-5 set; the capability set's placement never provided it there either. A need to deny
one user while keeping them on the team is the concrete trigger to move `Transaction_Stage_Actions`
onto its own directly-assigned layer-5 set — and no edit to any existing permission set achieves it
without that move.

**🔴 A permission set cannot be narrowed below the population that must ask it a question — the
non-obvious rule this cleanup discovered, and the reason it belongs in this document rather than only
in a design doc.** Apex class access is granted PER-CLASS, not per-method, so a class holding both a
permission-QUESTION method and an ACTION method cannot be narrowed at all: `RecordStageAdvanceController`
holds the cacheable `hasStageActionAccess` (called by `c/recordStageGuard` for **any** user who clicks,
driver or not) alongside `advance`/`advanceTo`, so no edit to any permission set separates them — it
must stay in the broad `DPEG_Apex_Access` catch-all *and* in its capability set.
`OpportunityActionPermissionController` is the same shape for one method: its own class header states
that a non-driver must still be able to invoke `hasDealActionAccess()` so it can honestly answer
`false`. Narrowing either class's access does not fail open or closed cleanly — it fails **loud and
wrong**: `c/dealActionGuard` and `c/recordStageGuard` both push `error.body.message` straight into a
toast, so a non-authorized user would see raw platform text ("You do not have access to the Apex class
named …") instead of the clean denial §5 requires. **The gate still fails CLOSED, so no automated test
catches this** — it is a message-quality and diagnosability defect, not a security hole, which is
exactly what makes it worth writing down rather than trusting review to catch it a second time.
`DPEG_Apex_Access` therefore shed only the two ACTION-ONLY classes on 2026-08-10
(`StageAdvanceController`, `OpportunityApprovalController` — each reachable only after its guard has
already returned `true`), going from **28 classes to 26**, while `OpportunityActionPermissionController`
and `RecordStageAdvanceController` stay in both the catch-all and their capability set on purpose. The
identical, older precedent is `LeadActionPermissionController`, which has sat in both
`DPEG_Apex_Access` and `Lead_Stage_Actions_Access` since the original RBAC build for the same reason —
this is not a new exception, it is the second instance of an existing one.

**Residual analysis before retirement — pairwise overlap does NOT prove coverage.** The measured
proof: a repo-wide grep for the `standard-Task` tab returns exactly two files —
`Property_Management_Access` and `Transaction_App_Access` — both of which were on the 2026-08-10
retirement list. No `DPEG_App_*` set, no module set, and not `DPEG_Admin_Access` carries it. Retiring
both, as the pairwise overlap numbers alone suggested was safe, would have deleted the Salesforce
Tasks tab from the repo entirely, with no deploy error and no failing test. Measured residuals
(grants present in the doomed set and absent from the union of its named replacements, computed
against **deployed org state**, not repo files, because several repo files are ahead of the org):
`Acquisitions_Dashboard_Access` 0/3, `Acquisition_App_Access` 0/4, `Transaction_App_Access` 15/56,
`Property_Management_Access` 39/225, `DPEG_Acquisitions` 59/459. Only the first two are proven-zero;
the other three carry named, unresolved residuals — service-class access that needs verifying rather
than assuming (a class invoked only from a Flow/trigger may need no class access at all),
`Task`/`Event` field `editable` bits, `allowDelete` rights, and — for Property Management — a genuine
**policy** question about whether Work Order write access should be restored or the documented
read-only Yardi-mirror contract simply enforced by the retirement. Full per-set breakdown:
`docs/permission-set-retirement-runbook.md` §4.

**Retirement order is GRANT → VERIFY in-org → REMOVE assignment → DELETE — never delete first.** Every
step in between has an in-org half that no deploy performs or verifies: `PermissionSetAssignment` and
`PermissionSetGroup` membership are not deployable metadata, and `profiles/**` is `.forceignore`d, so
there is no profile-level fallback if a retirement removes access a doomed set was silently the only
source of. The full sequence this program runs (RECONCILE → CLOSE RESIDUAL → GRANT → VERIFY → REMOVE
→ SOAK → DELETE) and the staged retirements it governs are in
`docs/permission-set-retirement-runbook.md`; this subsection states the rule, that document runs it.

**Reconcile org → repo before editing ANY existing permission set — including a `PermissionSetGroup`.**
The Standards bullet above already states the per-set field-permission hazard and its general fix; two
2026-08-10 findings sharpen it (full writeup: `docs/2026-08-10-permission-set-cleanup.md`). First,
`DPEG_Admin_Access` carried six `recordTypeVisibilities` live in the org and absent from the repo file
one day after a 2026-08-09 reconciliation had recorded zero org-only grants in it — proof that a past
clean reconciliation is a snapshot, not a standing guarantee. Second, a deployed **`PermissionSetGroup`
was found carrying a member the repo copy of that group does not list** — the identical
REPLACE-not-merge hazard one layer up, on group membership rather than field permissions. A group
deploy replaces its member list wholesale, so deploying a repo copy that is missing a member silently
revokes that member's access for every user in the group. **Reconcile a `PermissionSetGroup`'s
membership against the org before deploying it, exactly as you would a `PermissionSet`'s grants.**

⚠ More generally, this org contains metadata that has no counterpart in this repo at all — permission
sets, groups and record types built directly in `usman-dpeg`. A green deploy against `usman-dpeg`
therefore does **not** establish that the same source deploys to a fresh scratch org, and the repo is
not a complete description of the org's access model.

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

### 3.4 Deliberate, Temporary Exception — Direct Microsoft Graph Callout (SharePoint)

Salesforce holds a `SharePoint` Named Credential pointing **directly** at
`https://graph.microsoft.com/v1.0`, authenticated by the `SharePoint_Credential` External Credential
(OAuth 2.0, client-credentials flow, Entra app registration in the DPEG tenant). This bypasses §3.1's
ASB-only rule and is the **second** such exception after §3.3. The user explicitly acknowledged and
accepted this exception at the design gate on 2026-08-10.

**Why:** no ASB SharePoint/Graph spoke exists, so there is nothing on the bus to route to — the same
condition that justified §3.3. Document storage for the acquisitions deal tree is a first-party
Microsoft 365 tenant DPEG already owns and administers, so no third-party secret is being spread
across systems: the only credential involved is DPEG's own Entra client secret.

**Scope and reversibility:** the exception is confined to one Named Credential and one External
Credential. Retiring it means repointing the Named Credential's URL at the ASB spoke and moving the
client secret into ASB's secrets vault; no Apex signature changes, because every future callout would
go through `callout:SharePoint/...`. **Retire this exception when ASB exposes a SharePoint/Graph
spoke.**

**⚠ APEX NOW EXERCISES THIS EXCEPTION, AND THE PARAGRAPH ABOVE IS ONLY TRUE BECAUSE OF WHERE ONE
CONSTANT LIVES (2026-08-11).** Until the SharePoint deal-folder feature shipped, §3.4 described a
credential with no code behind it and made no statement about Apex at all. It now has exactly one
consumer: **`SharePointCalloutService`, which holds the single `Http.send` in the feature and the
single endpoint constant behind it — `private static final String BASE = 'callout:SharePoint'`.**
Every path segment (`/sites/{siteId}`, the drive part, `/items/{parentId}/children`) is composed in
that one class from parameters; no caller passes a URL in and no other class builds one. That is
what makes "repoint the Named Credential, no Apex signature changes" literally true rather than
aspirational — **the retirement is a one-line change to `BASE` plus the credential, and it stays a
one-line change only while that remains the case.** Do not build a Graph URL anywhere else. The
mirror of §3.3's arrangement, where `LLMExtractionCalloutService` holds the OpenAI endpoint for the
identical reason. (Callers, budget and the never-throw contract are in §2's `SharePointCalloutService`
and `DealFolderService` rows.)

**Credentials are never hardcoded.** The client secret lives entirely in the `SharePoint_Credential`
External Credential's `SharePoint_Principal` authentication parameter, entered in Setup **post-deploy**,
and is never serialized into metadata or source control. The client ID
(`1d572fdf-ab40-4a45-ba61-97243274b6ee`) is a public application identifier and is not a secret.

⚠ **`SharePoint_Credential` itself is deliberately NOT shipped as metadata in this repo** — unlike
`OpenAI_Credential`. The OAuth 2.0 / client-credentials `ExternalCredential` XML shape could not be
confirmed via `salesforce-api-context` MCP at API 67.0 (the tool is unavailable in this environment),
and the one in-repo precedent, `OpenAI_Credential`, is `authenticationProtocol Custom` — a different
protocol with a different parameter shape that does not reliably transfer to OAuth. Per the design's
own fallback (`agent-output/design-requirements-sharepoint-credentials.md` §3 A1 / §10), a malformed
guess here fails at token-acquisition time with an opaque Azure error, which is worse than not
shipping the file — so the External Credential is created **by hand in Setup** (Authentication
Protocol = OAuth 2.0, Flow = Client Credentials with Client Secret, one Named Principal literally
named `SharePoint_Principal`), and only `SharePoint.namedCredential-meta.xml` +
`SharePoint_Integration_Access.permissionset-meta.xml` are deployed metadata. **The permission set
will not deploy until the hand-built External Credential exists in the org** — it references
`SharePoint_Credential-SharePoint_Principal` by name.

**Access:** granted by the `SharePoint_Integration_Access` permission set (External Credential
Principal Access + `UserExternalCredential` read — the latter required to invoke ANY Named
Credential, per the `Broker_Protection_Access` precedent found live 2026-08-01). ⚠
`PermissionSetAssignment` is not deployable metadata — assignment is an in-org step and is not
represented in this repo.

⚠ **This is the second direct-callout exception.** §3.1 still describes the intended architecture,
but two standing exceptions is the point at which a third should trigger a review of whether the rule
or the reality needs to change, rather than another exception block.

🔴 **AND THAT REVIEW IS NOW OWED, NOT MERELY ANTICIPATED (2026-08-11).** The trigger above was written
while §3.4 was a credential-layer entry with no code behind it; the SharePoint deal-folder feature is
the first Apex to actually exercise it, so the ASB-only rule of §3.1 now has **two live, exercised
exceptions and no implementations that obey it** — every external callout this application makes goes
direct. That is a statement about the rule's standing, and it is recorded here as an OPEN ITEM: the
review has **not** been taken, nothing in §3.1 has been changed or relaxed by this note, and a third
exception still requires the same explicit user acknowledgement §3.3 and §3.4 each carry.

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
`c/dealActionGuard`). Extended again 2026-08-04 to the stage-controlled child objects, and on
2026-08-12 to `Transaction__c` — **still ONE bundle, `advanceRecordStage`, which now backs one quick
action each on all SEVEN stage-controlled objects across THREE modules**: `NDA__c`, `LOI__c`,
`Contract_Review__c`, `Underwriting__c`, `Construction_Feasibility_Review__c`,
`Development_Feasibility_Review__c` and `Transaction__c`, all sharing `c/recordStageGuard`.

🔴 **ONE BUNDLE, NOT ONE PER OBJECT — AND A SECOND ONE WAS BUILT AND THEN DELETED, SO THE REASON IS
RECORDED RATHER THAN ASSUMED.** `advanceRecordStage` is object-agnostic by construction: it names no
object, imports no object's schema, holds no stage value, and the server dispatches on
`Id.getSObjectType()`. `Transaction__c` was therefore added with **zero changes to any client file**.
A dedicated `transactionAdvanceStage` bundle was nevertheless created on 2026-08-12 so the
Transactions module would "own its own component"; it was **byte-identical below the comments** — same
five imports, same `CONFIRM` object, same `GENERIC_ERROR`, same `invoke()` body — and was **DELETED
the same day (code review W3, user decision)**. ⚠ **The general rule this settles:** the existing
guidance ("if one object later needs specific wording, split THAT ONE action into its own bundle")
means a bundle that **DIFFERS**. A copy carrying only a different header is not a split — it is a
second file that must now receive every fix the first one gets, with nothing but review to notice
when it does not. Adding an eighth object is a `CONFIG_BY_TYPE` entry plus a quick action pointing at
`advanceRecordStage`.

The BRANCH targets get their own one-action bundles rather than a
parameterised one, each passing a HARDCODED constant to `RecordStageAdvanceController.advanceTo`:
`c/loiMarkCountered` and `c/loiMarkCompleted` (2026-08-05), and `c/ndaMarkDeclined` (2026-08-09,
`NDA__c.Mark_Declined`). 🔴 **The constant is the security-relevant part, not a convenience** — the
server validates it against an allow-list scoped to the record's own RECORD TYPE, and a bundle that
computed or accepted its own target would defeat that check. `Declined` is the sharpest case: it is
valid only on `Disposition_NDA`, its action keys on `Status__c = 'Sent'` which BOTH NDA record types
carry, and record-type picklist restriction is **UI-only** — Apex DML does not enforce it.

**There are THREE guard utils and they must not be merged.** `c/leadStatusChange` is Lead-bound by
contract (it imports `Lead.Status` schema and `LeadActionPermissionController`);
`c/dealActionGuard` is the guard/confirm HALF of it, object-agnostic, and carries **no write helper at
all**; `c/recordStageGuard` (2026-08-04) is the same guard/confirm half again, but its permission
question is **PER-RECORD**. That asymmetry is deliberate and load-bearing:

| | Lead status actions | Opportunity stage actions | Record stage action — all SEVEN objects |
| --- | --- | --- | --- |
| Guard util | `c/leadStatusChange` | `c/dealActionGuard` | `c/recordStageGuard` |
| Objects served | `Lead` | `Opportunity` | `NDA__c`, `LOI__c`, `Contract_Review__c`, `Underwriting__c`, `Construction_Feasibility_Review__c`, `Development_Feasibility_Review__c`, **`Transaction__c`** (2026-08-12) |
| Write path | LDS `updateRecord` | imperative Apex (`StageAdvanceController` / `OpportunityApprovalController`) | imperative Apex (`RecordStageAdvanceController`) |
| `getRecordNotifyChange` | **MUST NOT** call it — `updateRecord` writes THROUGH the LDS cache, so the Path/highlights re-render on their own | **MUST** call it on success — Apex DML happens behind LDS's back, so without it the Path shows a stale stage | **MUST** call it on success — same reason |
| Server-side enforcement | Convert only; the three status writes have no Apex in their path, so CRUD/FLS on `Lead.Status` is the real control | **every** action asserts the permission server-side | asserts the permission server-side |
| Permission call shape | Lead-bound, no argument | **no argument** (`hasDealActionAccess()`) | **takes a `recordId`** (`hasStageActionAccess(recordId)`) — the server dispatches to the object's own gate |
| Gate shape behind it | membership (`LeadActionPermissionService`) | custom permission `Acquisition_Deal_Actions` (+ Modify All Data bypass) | the same one shape, three times: `DEAL_DRIVER` → `Acquisition_Deal_Actions`, `DISPOSITION_DRIVER` → `Disposition_Deal_Actions`, `TRANSACTION_STAGE_ACTIONS` → `Transaction_Stage_Actions`. **The client still cannot tell which**, and that is the point |
| Which LAYER carries the token | n/a (set membership IS the token) | **layer 5** — `Acquisition_Deal_Driver`, assigned directly | **layer 5** for the two deal gates; **layer 4** for `Transaction_Stage_Actions_Access`, which sits inside `DPEG_Transaction_Team` ⇒ that gate is TEAM-WIDE with no per-user revocation |

⚠ **THE THREE STAGE GATES WERE THREE DIFFERENT MECHANISMS UNTIL 2026-08-12 AND THE ROW ABOVE USED TO
SAY SO.** It read "TWO-FACTOR — permission set AND `User.Deal_Driver__c`" for Opportunity and
"**MIXED, and the client cannot tell** … `TRANSACTION_STAGE_ACTIONS` is membership-only" for the
record stage action. All of that is now false: the `*_Driver__c` flag model was retired and the
Transaction gate no longer tests membership. 🔴 **The surviving distinction is not the mechanism, it
is WHICH LAYER carries the permission** (row above) — that is a real, live authorization difference
and the one to check before harmonising anything. ⚠ Note what this cost the old argument: the mixed
shapes were cited as proof the per-record signature earns its keep. The proof is now *stronger*, not
weaker — a third gate arrived AND all three had their mechanism replaced, and **no client file
changed either time**.

⚠ **`Transaction__c` is not a fourth guard and must not be given one.** It shares
`c/recordStageGuard` and `c/advanceRecordStage` unchanged; the only thing that differs is which gate
the SERVER dispatches to, which is precisely the axis the client was designed not to see.

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
  ⚠ **As of 2026-08-12 all three stage-action gates ARE custom permissions**
  (`Acquisition_Deal_Actions`, `Disposition_Deal_Actions`, `Transaction_Stage_Actions`), so the
  declarative and Apex halves finally ask one question. Before writing a rule, read §2's *Two measured
  platform facts about custom permissions*: the token is **three segments**
  (`{!$Permission.CustomPermission.<Name>}` — both shorter spellings are rejected at deploy), and a
  `CustomPermission` and a FlexiPage referencing it **cannot ship in the same deploy**.
  🔴 **Never bind a visibility rule to a FIELD** (`{!$User.Some_Flag__c}`): it evaluates FALSE for any
  user lacking FLS READ on that field, with no error and no log, so the button silently vanishes for
  users who are genuinely authorized. That defect is why the `*_Driver__c` model was retired.
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
