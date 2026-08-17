# DPEG — Application Architecture

This document is the source of truth for **how the DPEG application is shaped**: domain model, Apex layering, integration boundaries, and LWC/UI patterns. It is separate from `CLAUDE.md` (which governs agent orchestration) and from `.claude/rules/` (which enforces _how_ metadata is generated).

**Client:** Dhanani Private Equity Group (DPEG) — Private equity group managing commercial real estate acquisitions, transactions, dispositions, investor relations and property management.

**Prepared by:** Avanza Solutions

**Audience:** Human contributors + Claude subagents (auto-loaded into `CLAUDE.md` via `@ARCHITECTURE.md`).

**API Version:** 67.0 (authoritative: `sfdx-project.json` → `sourceApiVersion`, which matches the org — verify with `sf org display`). Apex, triggers, Flows and LWC are uniformly 67.0; the sole exception is `lwc/leaseNegotiationLog`, held at 62.0 pending an in-flight feature merge.

**Reference document:** `docs/DPEG_Technical_Solution_Design_v1.3.docx`

---

## 0. System Overview

DPEG's Salesforce platform follows a **hub-and-spoke integration model**. Salesforce CRM acts as the central hub. External systems connect as spokes through the **Avanza Service Bus (ASB)** — Avanza's managed middleware and ETL platform. Salesforce is a read/display layer for external operational data — **no write-back to Yardi or Procore or any other external system**. Financial flows (contributions and distributions) run through Plaid's universal bank integration layer, also orchestrated via ASB.

---

## 1. Domain / Data Model

### Naming Conventions

Every example below is a real object or field in this org. Do not illustrate a rule with a name that
does not exist — an example nobody can find teaches nothing.

| Element                                      | Convention                                                                                                                     | Example                                                            |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| Custom object API name                       | `Title_Case_With_Underscores`, no prefix. Single-word objects carry no underscore.                                             | `Lease_Inquiry__c`, `Work_Order__c`, `Transaction__c`               |
| Custom field API name                        | `Title_Case_With_Underscores`, descriptive. Every underscore-separated segment starts with an uppercase letter or a digit; acronyms stay fully uppercase. | `Offer_Amount__c`, `Ball_In_Court__c`, `LOI_Status__c`, `NOI__c`    |
| Relationship fields (Lookup / Master-Detail) | The field name **is** the target object's name. **Exception:** role-named lookups to `User` / `Contact` take the role name — API names must be unique, so a second `User__c` cannot exist. | `Property__c`; roles: `Requested_By__c`, `Approved_By__c`           |
| Boolean fields                               | Prefix `Is_` or `Has_`, **or** `<Subject>_<PastParticiple>`. No other form.                                                    | `Is_Open__c`, `LOI_Signed__c`, `PSA_Executed__c`                    |
| Currency fields                              | The name must make the **unit** unambiguous — suffix `Amount` for a total, the unit for a rate, the period for a periodic amount. Established CRE/finance terms keep their industry name. Never a bare `Rent__c` / `Cost__c` / `Fee__c`. | `Offer_Amount__c`, `Rent_PSF__c`, `Monthly_Rent__c`, `Annual_NOI__c`, `NOI__c` |
| Date fields                                  | Suffix `Date` for date-only, `DateTime` for date+time. **Never** suffix a DateTime field with `Date`.                          | `Closing_Date__c`, `Verified_DateTime__c`                           |
| Status fields                                | A field expressing current state → suffix `Status__c`. A lifecycle field driving a Path → `Stage__c`. Other picklists are not status fields. | `LOI_Status__c`, `Stage__c`                                         |
| Masked display formula fields                | Suffix `_Masked__c`. **Dormant** — zero masked fields exist today (the IR module is unbuilt).                                  | _(none in org)_                                                     |

**Type-suffix discipline.** A field's name must not imply a type it does not have. A Text or Number
field must never be named identically to a custom object — the relationship rule above reserves that
name for a lookup, so such a field is camouflaged as a relationship by the convention itself. Use
`_Label__c` / `_Name__c` for Text carrying a human label, and `_Score__c` / `_Count__c` / `_Pct__c`
for a Number whose name would otherwise read Boolean or categorical.

**No team-wide field prefix in use.** Field API names are unprefixed past `__c`.

## 2. Apex Layering

DPEG follows the **Service / Selector / Domain / Trigger-handler** separation. Canonical templates exist in `.claude/skills/sf-apex/assets/` — reuse them rather than hand-rolling.

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
- **SOQL:** always in a selector. Never inline SOQL inside service or domain classes. Use `WITH USER_MODE` for a read the running user **asked for** — a throw there reports a real provisioning gap, and the fix is a permission set.
- **SOQL — the automation-path exception (`WITH SYSTEM_MODE`).** A read performed **on a principal's behalf** rather than at their request uses `WITH SYSTEM_MODE`, **justified at its own declaration in the selector's class header**. `USER_MODE` *throws, it does not degrade*: one inaccessible field raises `System.QueryException: No such column` — an FLS denial wearing a schema error — which inside a trigger escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the user's own save, or silently disables a batch/queueable. Every DPEG persona is on `Minimum Access`, and a Metadata-API-deployed custom field arrives with **no** FLS for any profile, System Administrator included — so this is the default case for automation, not an edge case. Applies to trigger-, batch-, queueable-, Finalizer- and guest-driven reads. **The mode is a property of the METHOD, never of the class** — selectors legitimately mix both; read the method.
  🔴 **`SYSTEM_MODE` bypasses CRUD/FLS ONLY — it does NOT bypass sharing.** Where a caller must escape sharing too, that is a **separate, separately justified** decision: a narrow `private without sharing` inner class holding only that query, never `without sharing` on a whole selector. Check sharing as its own question whenever a SYSTEM_MODE automation read hits a Private-OWD object whose rows are owned by someone other than the principal running the automation — and especially when the read backs an **idempotency guard**, where a sharing-filtered read does not disable the feature, it inverts it into a duplicate-maker.
  ⚠ The authoritative inventory of which methods escape, and why, is **the selector class headers** — not any list in this document.
- **Bulkification:** every public method accepts collections, not single records. No SOQL/DML inside loops. Bulk tests insert 251+ records.
- **Callouts:** all ASB/Plaid callouts wrapped in a dedicated service class (`PlaidCalloutService`) so they can be mocked via `HttpCalloutMock`. all other callouts will use ASB.
- **Error handling at LWC boundary:** `@AuraEnabled` methods throw `AuraHandledException` with user-safe messages.
- **Test data:** always use `TestDataFactory` (`force-app/main/default/classes/TestDataFactory.cls`). Never `@isTest(SeeAllData=true)`.
- **Coverage target:** 90%+ per class.

### Reference Implementations

- Selector pattern: `.claude/skills/sf-apex/references/AccountSelector.cls`
- Service pattern: `.claude/skills/sf-apex/references/AccountService.cls`
- Batch pattern: `.claude/skills/sf-apex/references/AccountDeduplicationBatch.cls`
- Test factory: `force-app/main/default/classes/TestDataFactory.cls`
- Test guidance: `.claude/skills/sf-apex-test/references/{assertion-patterns,mocking-patterns,async-testing,test-data-factory}.md`

**Referenced skills:** `.claude/skills/sf-apex/`, `.claude/skills/sf-apex-test/`, `.claude/skills/trigger-refactor-pipeline/`.

---

## 3. Integration Architecture

### 3.1 Avanza Service Bus (ASB) — Central Integration Hub

**All external integrations route through ASB. No direct peer-to-peer integrations between Salesforce and external systems** — except the two standing, user-acknowledged exceptions in §3.3 and §3.4 below, each of which exists only because the corresponding ASB spoke does not.

Salesforce holds a **single Named Credential pointing to the ASB endpoint only** — not to Plaid, Yardi, CoStar, or any external system directly. All external API credentials (Yardi, Plaid, CoStar, Placer.ai) are stored in ASB's secrets vault.

### 3.2 Named Credentials Policy

All external API credentials stored in Named Credentials (or ASB secrets vault for external-system credentials). Never in custom fields, custom metadata, or hardcoded Apex. Named Credentials are:

- Not visible in the UI — only accessible to Apex callouts
- Managed by System Administrators only
- Rotatable without code changes
- Audited in Setup Audit Trail

### 3.3 Standing exception — direct OpenAI callout (Broker Protection)

Broker Protection's LLM field-extraction step calls OpenAI **directly** via the `OpenAI_API` Named
Credential + `OpenAI_Credential` External Credential, bypassing §3.1. Intentional and temporary:
**no ASB LLM-extraction spoke exists**, so there is nothing on the bus to route to.

Scoped and reversible because **one class owns the boundary** — `LLMExtractionCalloutService`, which
holds the single endpoint constant (`callout:OpenAI_API/v1/chat/completions`). Retiring the exception
changes that constant and the credential; the public `extract(...)` signature and every caller stay
identical. The API key lives only in the External Credential's authentication parameter, entered in
Setup post-deploy — never in metadata or source.

### 3.4 Standing exception — direct Microsoft Graph callout (SharePoint deal folders)

The `SharePoint` Named Credential points directly at `https://graph.microsoft.com/v1.0`, authenticated
by the `SharePoint_Credential` External Credential (OAuth 2.0 client-credentials, Entra app in DPEG's
own tenant). Same justification: no ASB Graph spoke exists, and the tenant is first-party, so no
third-party secret is being spread across systems.

Again one class owns the boundary — `SharePointCalloutService`, holding the single `Http.send` and the
single endpoint constant (`private static final String BASE = 'callout:SharePoint'`); every path
segment is composed there from parameters. **Do not build a Graph URL anywhere else** — that is what
keeps retirement a one-line change.

⚠ `SharePoint_Credential` is deliberately **not** shipped as metadata (the OAuth External Credential
XML shape could not be confirmed at 67.0, and a malformed guess fails at token acquisition with an
opaque Azure error). It is created by hand in Setup; only the Named Credential and
`SharePoint_Integration_Access` are deployed, and that permission set will not deploy until the
hand-built credential exists.

🔴 **Two exceptions is the review threshold.** Every external callout this application makes is
currently direct — there are no ASB-routed implementations. A **third** exception requires explicit
user acknowledgement, as §3.3 and §3.4 each received, and should instead trigger a review of whether
§3.1 or the reality needs to change.

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


