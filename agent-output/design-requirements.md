# Design Requirements — Broker Protection (Inbound Email-to-Lead Pipeline)

Prepared by: salesforce-design agent
Date: 2026-07-24
Conformance basis: `ARCHITECTURE.md` (§1–§6), `CLAUDE.md` (orchestration + complexity routing), `.claude/rules/*`
Standing decision (user-approved): **DPEG-conformant** — same runtime behavior as the pasted POC spec, rebuilt to DPEG standards.

---

## 1. Overview

Multiple brokers independently email the same property to different internal people, who forward those emails into a Salesforce Email Service. This feature adds a **broker-protection layer** that:

1. Detects whether an inbound property already has a Lead (the "winner" = first broker to submit it).
2. Still creates a Lead per existing behavior, but marks a later duplicate submission dead and logs it for tracking only — never overwriting the winning Lead's data.
3. Surfaces the full submission history (winner + competing brokers) in an LWC on the winning Lead's record page.
4. Is **race-safe**: two emails for the same property within moments must never both win, enforced by a unique, case-insensitive external-ID key on a claim-ledger object, with a `DmlException` `DUPLICATE_VALUE` recovery path that re-reads the winner.

Runtime pipeline: an inbound-email handler creates a Lead synchronously and enqueues an async Queueable that calls an LLM (OpenAI gpt-4o-mini, text or image/vision) to extract broker name/email, property address, and the original "Sent:" datetime from the forwarded body, with a regex fallback on the first "From:" line. The Queueable then runs the claim logic.

This is a **from-scratch build** — none of the Apex, objects, or credentials exist yet (verified in-repo).

---

## 2. In Scope / Out of Scope

### In scope
- 4 new Lead custom fields (2 for capture, 2 for duplicate marking).
- 2 new backend custom objects: `Property_Registry__c` (claim ledger) and `Competing_Broker_Submission__c` (audit trail).
- 1 External Credential + 1 Named Credential for the direct OpenAI callout (documented §3 exception).
- 1 permission set (object/field access + external-credential principal access).
- Apex: inbound-email handler, mockable callout service, Queueable, matching/claim service, 2 selectors, thin `@AuraEnabled` controller.
- 1 LWC on the winning Lead record page + edit of the existing `Lead_Record_Page` FlexiPage.
- Apex test classes (TestDataFactory-based, HttpCalloutMock, 251-record bulk on DML services, 90%+ team-owned coverage).
- `ARCHITECTURE.md` updates in the **same PR** (§1, §2, §3).

### Out of scope (not requested / handled outside this metadata deploy)
- The Email Service + inbound routing address itself (Setup → Email Services). This is **org configuration** that points at `EmailToLeadHandler`; it is not part of the portable metadata bundle. See Open Question 4.
- The OpenAI API key value and the permission-set **assignment** — both are per-org, set **after** deploy, and do not travel with metadata (gotcha 8).
- Any ASB LLM-extraction endpoint (does not exist today; the direct OpenAI credential is the interim, documented exception).
- Write-back to any external system (§0 forbids it).
- Custom-object related lists on the Lead page layout — do NOT block the deploy on this (gotcha 3); the LWC is the primary view.
- Investor Relations / any object or field not in the component list.

---

## 3. Admin / Declarative Work

Routine declarative metadata. The schema is fully pre-designed below (no architecture decisions left open), which keeps it inside routine-admin scope.

### 3.1 Lead custom fields (4)
| API name | Type | Notes |
| --- | --- | --- |
| `Email_Subject__c` | Text(255) | Capture. §1-conformant. |
| `Forwarded_By__c` | Email | Capture — the internal forwarder's address. **See §1 naming flag, Open Question 5.** |
| `Is_Duplicate_Property__c` | Checkbox, default **false** | §1 rule 4 (`Is_` prefix). Duplicate marking. |
| `Duplicate_Of_Lead__c` | Lookup → Lead, deleteConstraint **SetNull** | Points a dead Lead at its winner. Lookup-to-Lead cannot be Restrict/Cascade (gotcha 1). |

`Lead.Property_Address__c` (Text 255) already exists — reuse, do not recreate.

### 3.2 Object `Property_Registry__c` — claim ledger (backend-only)
- AutoNumber name: `PR-{0000000}`; sharingModel **ReadWrite**.
- Fields:
  - `Property_Key__c` — Text(255), **unique, caseSensitive=false, externalId=true, required**. This is the race-safety key.
  - `Normalized_Address__c` — Text(255).
  - `Winning_Lead__c` — Lookup → Lead, **SetNull**.
  - `Registered_DateTime__c` — **DateTime** (§1 rule 6/9; NOT `_Date`).
- Validation rule `Winning_Lead_Required`: `AND(ISNEW(), ISBLANK(Winning_Lead__c))` — insert-scoped stand-in for "required" (a SetNull lookup cannot be required).

### 3.3 Object `Competing_Broker_Submission__c` — audit trail
- AutoNumber name: `CBS-{0000000}`; sharingModel **ReadWrite**.
- **Deliberately NOT master-detail** — cascade delete would wipe the audit trail. Use lookups.
- Fields:
  - `Winning_Lead__c` — Lookup → Lead, SetNull.
  - `Source_Lead__c` — Lookup → Lead, SetNull.
  - `Broker_Name__c` — Text(255).
  - `Property_Address_Raw__c` — Text(255).
  - `Email_Subject__c` — Text(255).
  - `Broker_Email__c` — Email.
  - `Forwarded_By__c` — Email. **Same §1 naming flag as the Lead field (Open Question 5).**
  - `Submitted_DateTime__c` — **DateTime** (§1 rule 6/9; NOT `_Date`).
  - `Is_Winning_Submission__c` — Checkbox, default false (§1 rule 4).
- Validation rule `Winning_Lead_Required`: same formula as 3.2.

### 3.4 Permission set `Broker_Protection_Access`
- `<description>` ≤ 255 chars (gotcha 7).
- Object perms (R/C/E + viewAll) on both new objects.
- FLS (read/edit) on every new custom field, **including the 4 Lead fields**.
- External-credential principal access for `OpenAI_Credential`.
- **Dependency:** the external-credential principal-access entry requires the External Credential (built in the integration stream, §4.1) to exist first — see Deploy Order.
- FLS/assignment caveat: deployed fields land with **no FLS** until this perm set is deployed AND **assigned** in-org (per-org, post-deploy). USER_MODE breakage is invisible to admin testers — acceptance-test as a non-admin persona.

### 3.5 FlexiPage edit
- Add the `competingBrokerSubmissions` LWC to the **existing** `Lead_Record_Page.flexipage-meta.xml` (verified present). This is an edit, not a create.

---

## 4. Developer / Programmatic Work

Layering per `ARCHITECTURE.md` §2 + `.claude/rules/apex-layering-rule.md`: SOQL only in Selectors (all `WITH USER_MODE`); DML/orchestration in a Service; handler and controller are thin. **No UnitOfWork class exists** (verified) → multi-object DML goes directly in the Service, bulkified, no UoW. API version **67.0** on every `.cls-meta.xml` and `.js-meta.xml`.

### 4.1 Integration credentials (declarative, but owned by the integration stream)
- `OpenAI_Credential` — **External Credential**, Custom protocol.
  - **AuthParameter is not valid under the Custom protocol** (gotcha 6) — store the key as a **NamedPrincipal** authentication parameter, referenced by an Authorization `AuthHeader` (`Bearer ...`).
  - Self-reference syntax is fully qualified: `{!$Credential.OpenAI_Credential.API_Key}` (gotcha 5).
- `OpenAI_API` — **Named Credential**, `SecuredEndpoint` → `https://api.openai.com`, **`allowMergeFieldsInHeader=true`** (else the `{!$Credential...}` header is sent literally → 401; gotcha 4).
- The API key value is set **post-deploy**, never in metadata (gotcha 8).

### 4.2 Apex
| Class | Layer | Responsibility / notes |
| --- | --- | --- |
| `EmailToLeadHandler` | Inbound handler (`Messaging.InboundEmailHandler`) | **Thin.** Build Lead + enqueue the Queueable via a service. From/name parsing, plaintext-vs-html body, image-attachment base64 extraction. No inline SOQL/DML business logic. |
| `LLMExtractionCalloutService` | Service (callout wrapper) | Mockable OpenAI callout (vision + text); returns extracted map. **Class header must carry a written §3-exception justification** (direct OpenAI pending a future ASB extraction endpoint). No raw `Http().send()` in the Queueable. Mockable via `HttpCalloutMock`. |
| `ExtractAddressQueueable` | Queueable (`Database.AllowsCallouts`) | Orchestrates: callout service → regex fallback → update Lead → claim logic via service. `@TestVisible` seam to force the race path. **No inline SOQL/DML** — delegate to service/selectors. |
| `PropertyMatchingService` (+ claim-service split) | Service | `normalizeAddress`, Jaccard `calculateSimilarity`, `findMatchingRegistry` (exact on unique key + fuzzy ≥0.6 within 90-day lookback, **ignoring null-winner rows**), `findOrphanedRegistry` (adopt SetNull-orphaned claims), and the claim/duplicate/orphan-adopt DML orchestration (via selectors, no inline SOQL). **Race recovery on `DUPLICATE_VALUE` / `DUPLICATE_EXTERNAL_ID`** → re-read the winner. Methods accept collections; bulkified. |
| `PropertyRegistrySelector` | Selector | All `Property_Registry__c` SOQL, `WITH USER_MODE`. Bind **Datetime** (not Date) for `Registered_DateTime__c` (gotcha 10). |
| `CompetingBrokerSubmissionSelector` | Selector | All `Competing_Broker_Submission__c` SOQL, `WITH USER_MODE`. Order by `Submitted_DateTime__c`. |
| `CompetingSubmissionController` | Controller (`@AuraEnabled cacheable`) | **Thin.** Delegates to selector/service; `WITH USER_MODE`; every failure → `AuraHandledException` via a private `ahe(String)` helper (repo-standard pattern, see `BrokerPortalController`). |

### 4.3 LWC
- `competingBrokerSubmissions` — on the winning Lead record page.
  - Imperative Apex (justified: cross-object aggregate not expressible via LDS — allowed by §5 exception).
  - Winner / Competing badge; ordered by `Submitted_DateTime__c`.
  - SLDS 2 design tokens (no hardcoded hex); SLDS linter before deploy.
  - `apiVersion` **67.0**.
  - Jest + `@sa11y/jest` accessibility test required.
  - Toast on error (`lightning/platformShowToastEvent`).

### 4.4 Tests (salesforce-unit-testing agent)
- Extend the org-wide `TestDataFactory` (`force-app/main/default/classes/TestDataFactory.cls`) — **do not fork** or stand up a competing factory.
- `Assert` class for all assertions.
- `HttpCalloutMock` for `LLMExtractionCalloutService`.
- `Test.startTest()/stopTest()` around the Queueable.
- **251-record bulk coverage** for any service method that does DML (per `.claude/rules/bulk-test-rule.md`); assertion counts must match 251.
- 90%+ per team-owned class.
- Carry gotcha 9 into test design: do not call `queueable.execute(null)` immediately after an insert in the same anon-Apex/test block (uncommitted work pending, DML-before-callout) — enqueue or split executions.

---

## 5. Complexity-Routing Recommendation

Per `CLAUDE.md` complexity-routing gate:

| Work bundle | Route to | Why |
| --- | --- | --- |
| **Declarative** — 4 Lead fields, 2 objects + fields + validation rules, permission set (object/field FLS), FlexiPage edit | 🔵 `salesforce-admin` | Routine field/object/validation-rule/permission-set/FlexiPage work; 2 objects is below the "5+ related objects / multi-object schema" solution-architect threshold; no OWD/sharing strategy to design. Schema is pre-specified. |
| **Integration + programmatic** — External + Named Credential, `LLMExtractionCalloutService`, `EmailToLeadHandler`, `ExtractAddressQueueable`, `PropertyMatchingService` + claim service, 2 selectors, `CompetingSubmissionController` | ⚫ `salesforce-technical-architect` | External LLM callout, Named/External Credentials, async Queueable, race-safe DML with duplicate-key recovery, §3 integration-exception justification — all in the technical-architect list. |
| **LWC** — `competingBrokerSubmissions` (+ Jest/sa11y) | ⚫ `salesforce-technical-architect` (per user framing) — *or* 🟢 `salesforce-developer` if parallelizing | The user grouped the LWC with the programmatic bundle → technical-architect owns it end-to-end. Routing note: a plain record-page LWC with a thin controller is standard complexity and **could** be delegated to `salesforce-developer`; if so, sequence it after the architect delivers `CompetingSubmissionController` + the selector it wires to. |
| Test classes (all Apex) | 🟡 `salesforce-unit-testing` | Standard post-Apex step. |

Not routed to `salesforce-solution-architect`: no multi-object OWD+sharing+FLS strategy, no ERD/subflow architecture, and the object count (2) is below the multi-object-schema threshold.

---

## 6. ARCHITECTURE.md Updates Required (same PR — §6)

1. **§1 → _Current objects_** — add both new objects under the **Acquisitions** module (they root on the Lead intake / deal tree):
   - `Property_Registry__c` — Parent (lookup): `Lead`. Purpose: race-safe claim ledger for inbound property submissions (unique case-insensitive `Property_Key__c`).
   - `Competing_Broker_Submission__c` — Parent (lookup): `Lead` (`Winning_Lead__c`, `Source_Lead__c`). Purpose: append-only audit trail of every broker submission for a property (winner + competitors); never cascade-deleted.
   - Confirm both `.object-meta.xml` files carry a real `<description>` so the table cites source, not inference.
2. **§2 → _Key Apex Services_** — add rows:
   - `PropertyMatchingService` (+ claim service if split) — invoked from `ExtractAddressQueueable` — property normalization/similarity, registry claim, duplicate marking, orphan adoption, `DUPLICATE_VALUE` race recovery.
   - `LLMExtractionCalloutService` — invoked from `ExtractAddressQueueable` — mockable OpenAI extraction callout wrapper (documented §3 exception).
3. **§3 → Integration Architecture** — add a note that a **direct OpenAI Named Credential (`OpenAI_API`) + External Credential (`OpenAI_Credential`)** is a **deliberate, temporary exception** to the ASB-only rule, pending a future ASB LLM-extraction endpoint. Reference the class-header justification on `LLMExtractionCalloutService`.

---

## 7. Open Questions (with verified findings)

1. **LeadSource value — RESOLVED (recommendation).** The org `LeadSource.standardValueSet` already contains **`Email-to-Lead`** and **`Broker Portal`**; there is **no `Email – Broker`**. **Recommend reusing the existing `Email-to-Lead`** value for the inbound pipeline (zero metadata change; the portal keeps `Broker Portal`). Only add a new `Email – Broker` value if broker-vs-generic email segmentation is a hard reporting requirement — confirm before adding.
2. **UnitOfWork — RESOLVED.** No `*UnitOfWork*` class exists in `force-app`. The layering rule is conditional ("when the project has a UnitOfWork class"). → multi-object DML lives directly in the Service, bulkified. No UoW to introduce. (The `TriggerHandler` base class exists, but this feature has no trigger, so it is not used.)
3. **Lead record page FlexiPage — RESOLVED.** `force-app/main/default/flexipages/Lead_Record_Page.flexipage-meta.xml` **exists** → the LWC is added to it (edit, not create). (`Lead_Funnel.flexipage-meta.xml` also exists but is the funnel app page, not the record page.)
4. **Email Service configuration — NEEDS DECISION.** `EmailToLeadHandler` is a `Messaging.InboundEmailHandler`, but the **inbound Email Service + its routing address** is org configuration (Setup → Email Services) that is not part of this portable metadata bundle. Confirm who provisions it and whether it should be scripted post-deploy. Flagged out-of-scope for the deploy above.
5. **`Forwarded_By__c` naming — NEEDS DECISION (§1 conformance).** In this org the `<Role>_By__c` pattern denotes **role-named lookups to User/Contact** (`Requested_By__c`, `Approved_By__c` — §1 rule 3). An **Email** field named `Forwarded_By__c` risks being read as a lookup (§1 rule 9, type-suffix discipline). The sibling field on `Competing_Broker_Submission__c` uses `Broker_Email__c` (with the `_Email` suffix), so the naming is also internally inconsistent. **Recommend `Forwarded_By_Email__c`** on both objects for §1 conformance and disambiguation. Confirm before build (the spec supplied `Forwarded_By__c`).

---

## 8. Platform Gotchas (carry into implementation prompts)

1. A lookup to Lead **cannot** use Restrict/Cascade delete → deploy rejected. Use **SetNull** lookups + the insert-scoped `Winning_Lead_Required` validation rule as the "required" stand-in.
2. SetNull means a deleted winner leaves a registry row with **null `Winning_Lead__c`** → the matching service must **ignore null-winner rows** (else the property is permanently unclaimable) and the Queueable must **adopt** such orphans.
3. Custom-object related lists may fail to deploy onto standard-object layouts — **do not block the deploy** on it; the LWC is the primary view.
4. Named Credential merge fields in headers require **`allowMergeFieldsInHeader=true`**, else `{!$Credential...}` is sent literally → 401.
5. External-credential self-reference is fully qualified: `{!$Credential.OpenAI_Credential.API_Key}`.
6. `AuthParameter` is **not valid** under the Custom external-credential protocol → store the key as a **NamedPrincipal** authentication parameter, referenced by the Authorization `AuthHeader` (`Bearer ...`).
7. PermissionSet `<description>` max **255 chars**.
8. The API key value **and** the permission-set **assignment** do **not** travel with metadata — per-org, set **after** deploy. (Also: deployed fields land with no FLS until the perm set is deployed and assigned; USER_MODE breakage is invisible to admin testers — acceptance-test as a non-admin persona.)
9. Calling `queueable.execute(null)` right after an insert in the same anon-Apex/test block throws **"uncommitted work pending"** (DML before callout) → enqueue and let it run, or split executions.
10. `Registered_DateTime__c` / `Submitted_DateTime__c` are **DateTime** → bind **Datetime** (not Date) in SOQL.

---

## 9. Proposed Component / Deploy Order

Dependency-ordered. Steps 1–5 are the metadata build; 6–8 follow the standard `CLAUDE.md` workflow.

1. **Lead fields** (`Email_Subject__c`, `Forwarded_By__c`/`Forwarded_By_Email__c`, `Is_Duplicate_Property__c`, `Duplicate_Of_Lead__c`) — referenced by objects' FLS, Apex, and perm set. *(admin)*
2. **New objects** `Property_Registry__c` + `Competing_Broker_Submission__c` (fields + validation rules) — referenced by selectors, service, controller, perm set. *(admin)*
3. **External Credential `OpenAI_Credential` → Named Credential `OpenAI_API`** — required by the callout service and the perm set's principal access. *(technical-architect)*
4. **Permission set `Broker_Protection_Access`** — references the new objects, new fields, and the External Credential (from step 3). Must come after 1–3. *(admin)*
5. **Apex, in layer order** — DTOs/selectors (`PropertyRegistrySelector`, `CompetingBrokerSubmissionSelector`) → `LLMExtractionCalloutService` → `PropertyMatchingService`/claim service → `ExtractAddressQueueable` → `EmailToLeadHandler` → `CompetingSubmissionController`. *(technical-architect)*
6. **Test classes** for all Apex (TestDataFactory, HttpCalloutMock, `Test.start/stopTest`, 251-record bulk on DML services, 90%+). *(unit-testing)*
7. **LWC `competingBrokerSubmissions`** (+ Jest/sa11y) → then **edit `Lead_Record_Page` FlexiPage** to add it. Depends on `CompetingSubmissionController` (step 5). *(technical-architect, or developer if split)*
8. **`ARCHITECTURE.md` update** (§1, §2, §3) — **same PR** as the build.

Then the standard workflow: code-review → (devops deploy ‖ documentation).

**Post-deploy, per-org manual steps (not in the metadata bundle):** set the OpenAI API key on the NamedPrincipal; assign `Broker_Protection_Access` to the relevant users; provision the inbound Email Service + routing address pointing at `EmailToLeadHandler` (Open Question 4); acceptance-test as a non-admin persona.
