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
- 🔴 **SOQL — the Custom Metadata long-text exception. `getInstance()` / `getAll()` SILENTLY TRUNCATE LongTextArea and Html fields to 255 characters.** The general rule is still "read `__mdt` with the built-in accessors, never SOQL" (`.claude/skills/sf-apex/SKILL.md`), and it is correct for every Number / Text / Picklist / Checkbox field. It is **wrong for long text**, and this org has already paid for that. Measured on `usman-dpeg` at API 67.0 on 2026-08-31, same row and same transaction: `getInstance('Default').Extraction_Prompt__c`.length() = **255**; SOQL on that field = **20,596**; `identical = false`. The clipped value is **non-blank**, so it passes every `String.isBlank()` guard and reaches the consumer looking healthy. In the incident that produced this bullet, the 255-character head lacked the token `json`, OpenAI refused `response_format: json_object` on every request, a degrade-on-exception boundary swallowed the `CalloutException` by design, and every inbound broker email reported SUCCESS while extracting nothing.
  ✅ **A `__mdt` type carrying a long-text field needs a selector for that field**, with the usual mode justification at the declaration. Two escape valves keep the cost near zero: **(i) select ONLY the long-text field** (plus `DeveloperName`) and leave the rest on `getInstance()`, so nothing else pays a query or enlarges the mode question; **(ii) cache in the CALLER, not the selector** — the read is not free on a governor-budgeted async path, and an internal cache would defeat any `overrideForTest`-style test seam. Reference: `BrokerProtectionConfigSelector` + `BrokerProtectionConfig.extractionPromptOverride()`.
  ⚠ **This was already written down and nobody connected it.** `TaskGroupDefProvider`, `TransactionTaskDefProvider` and `OnboardingTaskDefProvider` have all said for months that `getAll()` "populates every **non-long-text** field". Three headers knew; the knowledge lived in Transaction-task classes nobody reads while building Broker Protection. This bullet and the SKILL.md rule are the two places that *are* read every time.
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

**All external integrations route through ASB. No direct peer-to-peer integrations between Salesforce and external systems** — except the three standing, user-acknowledged exceptions in §3.3, §3.4 and §3.5 below, each of which exists only because the corresponding ASB spoke does not.

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

### 3.5 Standing exception — direct Cloudflare Turnstile callout (Broker Portal CAPTCHA)

The public DPEG Broker Portal verifies its CAPTCHA by calling Cloudflare Turnstile's
`/turnstile/v0/siteverify` **directly**, via the `Cloudflare_Turnstile` Named Credential +
`Turnstile_Credential` External Credential, bypassing §3.1. Same justification as §3.3 and §3.4:
**no ASB CAPTCHA-verification spoke exists**, so there is nothing on the bus to route to. Routing it
through ASB would also add a second network hop to a *synchronous* page interaction a broker is
waiting on, and Turnstile tokens are short-lived and single-use, so latency here is correctness, not
just comfort.

Scoped and reversible because **one class owns the boundary** — `TurnstileVerificationService`, which
holds the single `Http.send` and the single endpoint constant
(`callout:Cloudflare_Turnstile/turnstile/v0/siteverify`). Retiring the exception changes that constant
and the credential; the public `verify(String token, String remoteIp)` signature and its one caller
(`BrokerPortalService.submitDeal`) stay identical. The secret key lives only in the External
Credential's `Secret_Key` authentication parameter under the `Turnstile_Principal` named principal,
entered in Setup post-deploy — never in metadata or source. The **sitekey** is separate, public by
design, and set per-environment as an Experience Builder property on `brokerDealIntakeForm`.

⚠ **This exception is user-facing in a way the other two are not.** Verification **fails closed**: if
Cloudflare is unreachable, times out, or the credential is wrong, the submission is refused. A
Cloudflare outage therefore takes the public broker form down. That is deliberate — a CAPTCHA that
fails open is not a CAPTCHA — and is argued in full in `BrokerPortalService.verifyHuman`'s header,
which also explains why `LeadConvertMatchService` correctly fails *open* and is not inconsistent with
this.

🟢 **GATE B IS PROVEN — AND THIS IS THE FIRST WORKING PRECEDENT IN THIS REPO FOR A `$Credential`
MERGE FIELD IN A REQUEST *BODY*. Do not re-discover it.**
Turnstile authenticates by a form field in the POST body (`secret=...&response=...`), not by a
header, so neither §3.3's nor §3.4's shape transfers: `OpenAI_API` sets
`<allowMergeFieldsInBody>false</allowMergeFieldsInBody>` and authenticates via a custom `AuthHeader`.
The shape needed here — a `Custom` External Credential parameter referenced as
`{!$Credential.Turnstile_Credential.Secret_Key}` **inside the body**, with
`<allowMergeFieldsInBody>true</allowMergeFieldsInBody>` on the Named Credential — was exercised
nowhere in this repo. §3.4 records what happens when that kind of shape is guessed: the SharePoint
OAuth credential could not be confirmed at 67.0 and had to be hand-built in Setup.

It was therefore **measured, not assumed**, against `usman-dpeg` at API 67.0 on 2026-08-30, with a
control so the discriminator could not pass vacuously:

| Probe | Body | Result |
| --- | --- | --- |
| A — merge field | `secret={!$Credential.Turnstile_Credential.Secret_Key}&response=<invalid token>` | **HTTP 200** `{"success":true,...,"metadata":{"result_with_testing_key":true}}` — the merge field **resolved** |
| B — control, literal secret | `secret=this-is-not-a-real-turnstile-secret&response=<same invalid token>` | **HTTP 400** `{"success":false,"error-codes":["invalid-input-secret"]}` — an unresolved secret **is** detectable |

Consequences worth carrying forward:

- ✅ The External Credential **is** shipped as metadata here. The §3.4 hand-built fallback was
  pre-approved but is **not needed** and was not used.
- 🔴 **A green deploy proves nothing about this.** With the flag false, the literal merge string is
  sent as the secret and Cloudflare answers a well-formed `invalid-input-secret` — HTTP 400, no
  exception, nothing thrown — and every broker submission is refused with a message no log explains.
  Anyone changing `allowMergeFieldsInBody`, renaming `Secret_Key`, or re-homing the endpoint must
  re-run the two probes above. An `HttpCalloutMock` cannot substitute: it intercepts the request
  before substitution matters and answers identically either way.
- ⚠ Cloudflare returns **HTTP 400 with a parseable JSON body** for a bad secret, so response parsing
  must not be gated on a 2xx status or the one diagnostic field is discarded.
- ⚠ A running user with no External Credential Principal Access gets
  `System.CalloutException: We couldn't access the credential(s)... might not exist` — which names a
  missing credential as its first hypothesis and sends diagnosis down the wrong path. Measured here:
  the credential existed, the `Turnstile_Integration_Access` assignment did not.

⚠ **The browser half of this feature is NOT deployable and NOT verifiable from source (GATE C).** The
widget loads `https://challenges.cloudflare.com/turnstile/v0/api.js`, which needs both the deployable
`Cloudflare_Turnstile` `CspTrustedSite` record **and** the LWR site's own CSP/security level relaxed
in Experience Builder. The latter lives in `sites/**` + `networks/**`, excluded entirely by
`.forceignore` (lines 509-522) — the same class of trap as the `settings/**` one: a force-ignored tree
never reconciles, so a repo file describing it would be unverified fiction. It is a **manual
post-deploy step**, and this feature's acceptance criterion is a **browser check on the live guest
page**, never a deploy result. Runbook: `docs/runbooks/2026-08-30-turnstile-post-deploy.md`.

🔴 **THREE exceptions, and the threshold has now been crossed once. The next one is not routine.**
§3.4 previously read "two exceptions is the review threshold" and required explicit user
acknowledgement for a third. That acknowledgement **was given, for Turnstile, on 2026-08-30** — so the
rule worked as designed and this section is its record, not a bypass of it.

What has not changed is the underlying fact, which is now starker: **every external callout this
application makes is direct. There are still zero ASB-routed implementations — 3 of 3.** §3.1
describes an architecture the code does not yet have anywhere. A **fourth** exception should not be
sought and would not be a judgement call about that integration; it is the point at which §3.1 is
provably aspirational and the honest response is to change the document or build the bus, not to add
another row here. Anyone reaching for a fourth: raise the ASB-spoke question first, and treat "no
spoke exists" as the problem to fix rather than as the justification.

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


