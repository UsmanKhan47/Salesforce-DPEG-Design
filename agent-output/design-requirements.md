# DESIGN REQUIREMENTS — ARCHITECTURE.md Full Conformance Program

**Date:** 2026-07-15
**Request type:** Migration / remediation program over existing code (NOT a new feature)
**Scope decision:** MAXIMAL — "Full conformance, straight through" (user-accepted, with costs shown)
**Authority:** `ARCHITECTURE.md`, `.claude/rules/apex-layering-rule.md`, `.claude/rules/bulk-test-rule.md`, `.claude/rules/invocable-rule.md`

---

## 🎯 WHAT USER REQUESTED

Full conformance of the existing DPEG codebase to `ARCHITECTURE.md`. Four binding decisions (not re-litigated here):

1. **Scope** = everything in the doc: Service/Selector/Domain/Trigger-handler layering, `WITH USER_MODE` on all queries, Jest for all LWC bundles, SLDS 2 tokens, 251-record bulk tests, 90%+ coverage per class.
2. **Doc defects** = make code match the doc: CREATE `TestDataFactory.cls`; BUMP `sourceApiVersion` 62.0 → 67.0 as its own task with its own deploy + full test run.
3. **Jest** = all LWC bundles, no exemptions.
4. **FLS** = full FLS audit first, then the `WITH USER_MODE` sweep.

**Imposed sequencing constraint (does not reduce scope):** the test safety net lands before the refactor that depends on it. Every phase independently deployable, org left working.

---

## ⚠️ INVENTORY CORRECTIONS (verified against the codebase this run)

The inbound inventory was largely accurate, but **five figures are wrong or misleading** and they change scope, sequencing, and cost. Each is verified below.

| # | Claim | Verified reality | Impact |
|---|-------|------------------|--------|
| 1 | "45 non-test classes" to migrate | **35 team-owned.** 89 `.cls` total − 44 test = 45 non-test; **10 of those are Salesforce-generated Communities/Site boilerplate** (`MicrobatchSelfRegController`, `ForgotPasswordController`, `ChangePasswordController`, `SiteRegisterController`, `SiteLoginController`, `CommunitiesSelfRegConfirmController`, `CommunitiesSelfRegController`, `CommunitiesLandingController`, `CommunitiesLoginController`, `MyProfilePageController`). The inbound brief already declares boilerplate out of scope but applied the 45 figure anyway. Team-owned = 25 controllers + 7 services + 3 notifier/schedulable = **35**. | Layering scope −22% |
| 2 | "The 4 triggers ARE already thin" | **3 of 4.** `LeadConvertTrigger`, `ContractReviewTrigger`, `OpportunityReviewTrigger` are thin. **`TaskRollupTrigger` is NOT** — lines 7–24 contain two `for` loops and null-filtering logic in the trigger body before calling `TaskRollupService.recalc`. | One trigger needs logic extraction, not just a handler interposed |
| 3 | "85 SOQL queries" | **109 `SELECT` keywords across 36 non-test classes** (2 of them in boilerplate → ~107 in team code). The 85 figure is plausibly *query statements*; 109 counts subqueries separately. | Define the sweep unit before estimating; ~107 is the upper bound |
| 4 | "33 objects" for the FLS matrix | **33 custom objects confirmed** ✅ — but they carry **463 custom fields**, and the repo contains **322 object folders** (mostly standard). The FLS matrix is 463 custom fields × 7 team permission sets, plus standard-object fields in use. | FLS phase is field-scale, not object-scale |
| 5 | "10 permission sets"; "`DPEG_Admin_Access` is the likely home for gap closure" | **8 team permission sets** (2 are `sfdcInternalInt__*`, Salesforce-generated); **7 carry FLS**. `DPEG_Admin_Access` grants FLS on **exactly one field** (`Lease_Inquiry__c.OneDrive_URL__c`). It is a *tab-visibility* permission set, not an FLS home. | See the FLS finding below — it reshapes Phase 3 |

### 🔴 The FLS finding that reshapes the program

The inbound brief correctly flags the FLS risk but **misidentifies the mechanism**. Evidence:

- `force-app/main/default/profiles/**` is **`.forceignore`d** (`.forceignore` line 28). The stated reason: profiles are unportable; excluding them eliminates 394 deploy errors.
- `Admin.profile-meta.xml` grants **1,537 `<fieldPermissions>`**.
- All 7 team permission sets combined grant **590 `<field>` entries**.
- `DPEG_Admin_Access`'s own description states it exists to restore *"tab visibility and FLS the Admin profile granted (Profiles excluded from deployment)"* — and it restores exactly **one** field.

**Therefore: FLS in this org is overwhelmingly profile-granted, and profiles are not in source control and are not deployable from this repo.** Three consequences the plan must design around:

1. **The FLS audit cannot be performed from the repo.** The repo does not contain the org's effective FLS. The audit must run against the **live org** (Tooling/Metadata API or `sf` FLS extract per profile + permission set), then be materialised into deployable permission sets.
2. **`WITH USER_MODE` breakage will be invisible to admin smoke tests.** The dashboards work today for Admins because the Admin *profile* grants 1,537 field permissions. `USER_MODE` enforces FLS against the **running user**. Non-admin users (Property Management, Transactions, Acquisitions) rely on the 590 permission-set grants. **The dashboards will break for end users while continuing to work for whoever is testing.** Phase 3 acceptance MUST include verification as each non-admin persona, not as Admin.
3. **The delta (1,537 profile grants vs 590 permission-set grants) is the FLS gap surface** — not zero, and not small. This is the quantified form of the documented "no FLS on sf-deployed custom fields" gotcha.

---

## 🚧 WHERE FULL CONFORMANCE IS IMPOSSIBLE OR SELF-DEFEATING

The user has decided; scope is not softened. These are cases where a rule **cannot be satisfied** (not merely expensive), with evidence and the minimum amendment.

### 1. `TaskFanoutService` cannot pass a 251-record bulk test — and it *should* fail

- **Rule:** `bulk-test-rule.md` — "Service method with DML | **251** minimum".
- **Evidence:** `TaskFanoutService.cls:49–98` accumulates `toInsert` across **every** Transaction in the batch and performs a single `insert toInsert;` at **line 94**. The fan-out is the Day-0 checklist (~75 Tasks per Transaction, CMDT-driven).
- **Arithmetic:** 251 × 75 = **18,825 Task rows in one DML** vs the **10,000 DML rows/transaction** governor limit. Ceiling is ~133 Transactions.
- **Verdict — NOT a doc defect.** This is the rule doing its job: it surfaces a genuine architectural defect (the already-flagged "unguarded DML volume"). **Do not amend the rule.** Fix the service: chunk the fan-out into a Queueable (`System.Finalizer` per the layering rule's anti-`@future` stance).
- **Trap to avoid:** `TaskFanoutService` exposes `@TestVisible taskDefsOverride`. A test *can* inject a 2-def list and pass 251 Transactions — **artificially green while hiding the production limit break.** The bulk test must exercise production-representative def counts.
- **⚠️ Sequencing consequence:** the TaskFanout re-architecture (Phase 7) must land **before or with** its 251-record bulk test (Phase 2). This is the one place the "tests before refactor" constraint inverts, and it is unavoidable.

### 2. Guest portal vs `WITH USER_MODE` — the fix is not deployable from this repo

- **Rule:** §2 — all SOQL in Selectors, `WITH USER_MODE`.
- **Evidence:** `BrokerPortalController.cls:1` is `without sharing` and correct (public LWR guest site). Guest FLS lives on the **Guest User Profile** — and `.forceignore` lines 20–28 exclude all profiles, *explicitly naming* "DPEG Broker Portal Profile / Guest License User" as causing userLicense errors.
- **Conflict:** routing broker-portal queries through a `WITH USER_MODE` Selector enforces FLS against the guest user, whose FLS is intentionally minimal, **cannot be granted from this repo**, and is manual org config.
- **Minimum doc amendment:** §2 gains a narrow clause — *"Selectors serving the public/guest portal may use `AccessLevel.SYSTEM_MODE` with written justification in the class header, because guest FLS is managed on the Guest User Profile outside this repo. Guest-facing writes must field-allow-list explicitly."* Alternative (no amendment): grant guest FLS via a permission set assigned to the site guest user — must be **proven in the org first**; treat as a spike, not an assumption.

### 3. 90% coverage + layering on Salesforce-generated boilerplate — self-defeating

- 10 of the 45 non-test classes are platform-generated Site/Communities controllers. Refactoring them into Selector/Domain, or writing tests to hit 90% on Salesforce's own code, churns code the team does not own and the platform may regenerate.
- **Minimum doc amendment:** §2 states coverage/layering targets apply to **team-owned** classes; Salesforce-generated Site/Communities boilerplate is exempt. (This also formalises the 45 → 35 correction and is consistent with the brief's own stance.)

### 4. "0 LDS GraphQL" is **not** a defect by default — converting the 72 would violate the doc

- §5 sets a data-access **priority**, and names imperative Apex as **correct** "when LDS cannot express the query (**complex joins, aggregates**, Plaid callout results)".
- The KPI dashboards are `COUNT()` / `GROUP BY` aggregates — the doc's own listed exception. Converting them is self-defeating and would lose functionality.
- **Genuine candidates are narrow:** multi-object *record* reads (`rentRoll`, `dispositionOffer`). Conformance target ≈ **2–8 components, not 72**.
- ⚠️ **Uncertainty flagged:** UI-API GraphQL aggregate support is limited and version-dependent. **Validate per component with a spike before converting.** Do not mass-convert.

### 5. Doc internal cross-references are broken (cheap, fold into the §2 doc PR)

`ARCHITECTURE.md` §6 instructs contributors to update sections that **do not exist**:
- "populate its entry under **§1 Current objects**" — §1 has no *Current objects* subsection.
- "document it under **§4 Integration Architecture**" — Integration is **§3**; §4 is Experience Cloud Portal.
- "add it to the **§2 Key Apex Services** table" — §2 has no *Key Apex Services* table.
- §2 lists `TestDataFactory.cls` under *Reference Implementations* as though it exists; it does not (user already decided: create it).

**Minimum amendment:** fix the section numbers and add the missing `§1 Current objects` / `§2 Key Apex Services` subsections (or delete the references). Bundle with the API-version fix.

### 6. `UnitOfWork` is explicitly OUT of scope

`apex-layering-rule.md` mandates UoW **"when the project has a `UnitOfWork` class"**. Verified: **none exists**. The rule is conditional, so conformance does **not** require creating one. Introducing UoW would be scope creep and is excluded. **A `TriggerHandler` base class, by contrast, IS required** — the rule mandates the one-line trigger form `new <Object>TriggerHandler().run();`, and no base class exists in `force-app` (only pattern docs in `.claude/skills/`). Creating it is a Phase 5 prerequisite.

### 7. Minor: `@InvocableMethod` conformance is not quite clean

The brief lists invocables as conformant. Strictly per `invocable-rule.md` (binding), `TaskFanoutService.fanOut(List<Id>)` is bulk-safe (List param ✅, `void` return ✅) but has **no `InputDTO` inner class with `@InvocableVariable` fields**, which the rule requires. Small and cheap — folded into Phase 7 with the fan-out re-architecture.

---

## 📊 PHASED PROGRAM PLAN

Dependency-ordered. Every phase independently deployable and leaves the org working.

```
P0 API uplift ──┬── P1 TestDataFactory ── P2 Bulk tests + coverage ──┐
                │                              ▲                      │
                │                              └── P7 LDV/DML fixes ──┤ (TaskFanout inverts)
                │                                                     ▼
                └── P3 FLS audit + permsets ───────────────► P4 Selectors + USER_MODE
                    (parallel; ADMIN track)                           │
                                                                      ▼
                                                    P5 TriggerHandler + Domain
                                                                      │
                                                                      ▼
                                              P6 Controllers + Service + error boundary
                                                                      │
                    P8 Jest ── P9 SLDS 2 ── P10 utils  (UI track, parallelisable) ◄──┘
```

---

### PHASE 0 — API version uplift 62.0 → 67.0 ✅ BUILT (not yet deployed)
**Why first:** the doc's cited authority must agree with the repo before anything is measured against it. Re-versions all metadata.

> **⚠️ AMENDED AFTER GATE 1 — this section is corrected, not as originally approved.** Three deviations, all user-approved:
> 1. **Target is 67.0, not 66.0.** The org (`DPEG-Acq-5`) runs **67.0**; ARCHITECTURE.md's declared 66.0 was one release stale the day it was written. Corroborating evidence: 20 Salesforce-generated boilerplate files were *already* at 67.0 — the platform stamps at the org's version. Matching the org beats matching a stale doc.
> 2. **The 82 LWC `.js-meta.xml` are EXCLUDED and deferred until after Phase 8 (Jest).** `RunLocalTests` is Apex-only; Jest starts from zero tooling; 10 components span 59.0→67.0 (eight releases); LWC `apiVersion` gates shadow-DOM rendering. They would have shipped with zero automated verification — violating this plan's own "safety net before the change" constraint. **The repo is therefore deliberately mixed-version. Do not "fix" it.**
> 3. **The 23 Flows are INCLUDED** (missing from the original enumeration). They carry the same no-verification exposure as the LWC and more blast radius; the user accepted this knowingly. **Mandatory: written manual exercise script at deploy — `Transaction_Task_Fanout` first** (drives the ~75-task Day-0 fan-out via `TaskFanoutService`). `RunLocalTests` proves nothing about Flow behaviour.

- 🔵 **ADMIN:** none.
- 🟢 **DEV:** bump `sfdx-project.json` `sourceApiVersion` 62.0 → 67.0; align `<apiVersion>` in **69** `.cls-meta.xml`, **4** `.trigger-meta.xml`, **23** `.flow-meta.xml` — **99 files total** (96 metadata + `sfdx-project.json` + 2 root docs). LWC excluded per above; 20 boilerplate files left at 67.0 untouched. Full `RunLocalTests` run. Own deploy.
- **🎯 Manual regression concentrates on ONE module — Disposition.** The 8 classes that jumped 59.0→67.0 (eight releases, double everything else) are `BovController`, `BrokerListingController`, `DispositionController`, `WireController` + their 4 tests — and the 10 highest-risk deferred LWCs are the *same feature*. Exercise Disposition hard.
- **Verified post-build:** `git diff --numstat -- force-app` → every file exactly `1 1`; `git diff -U0` → zero non-`apiVersion` lines in `force-app`. The 23 Flow bodies are provably untouched.
- **Complexity:** `salesforce-developer` (mechanical), **but** the 62→66 span is 4 releases — behaviour-change regression is real. Escalate to `salesforce-technical-architect` if the full test run surfaces platform-behaviour breaks.
- **Risk:** this is the phase most likely to break something invisibly. Deploy alone, nothing else in the same PR.
- **Effort: 4–6 days**

### PHASE 1 — `TestDataFactory.cls`
**Why here:** ARCHITECTURE.md §2 mandates it; every later test phase depends on it.

- 🔵 **ADMIN:** none.
- 🟢 **DEV:** create `force-app/main/default/classes/TestDataFactory.cls` covering 33 custom objects (463 fields — required-field graphs, relationship chains: Property → Property_Asset → Unit → Rent_Step; Opportunity → LOI → Counter_Offer; Transaction → Task) plus standard Account/Contact/Lead/Opportunity/Task. Guidance: `.claude/skills/sf-apex-test/references/test-data-factory.md`.
- **Complexity:** `salesforce-technical-architect` — this is a cross-object schema design problem across 33 objects, not a code-typing task. A weak factory here poisons every later phase.
- **Effort: 8–12 days**

### PHASE 2 — Test safety net: factory migration, 251-record bulk tests, 90% coverage
**Why here:** the imposed constraint — the net must exist before the layering refactor.

- 🔵 **ADMIN:** none.
- 🟢 **DEV:**
  - Migrate all **44** existing test classes onto `TestDataFactory` (12–18d).
  - **251-record bulk tests** per `bulk-test-rule.md`: 4 triggers (`TaskRollupTrigger` needs insert/update/delete/undelete), 7 services with DML, 1 schedulable (10–14d). ⚠️ `TaskFanoutService`'s bulk test depends on **P7** (see impossibility #1) — and must not be faked via `taskDefsOverride`.
  - Lift coverage to **90%+ per class** across the **35 team-owned** classes (15–22d).
- **Complexity:** `salesforce-unit-testing` for authoring; `salesforce-technical-architect` to adjudicate bulk tests that fail on governor limits — those failures are **findings, not test bugs**, and each needs a real architectural call.
- **Effort: 37–54 days** ← largest Apex-side item

### PHASE 3 — FLS audit + permission-set remediation ⭐ ADMIN TRACK, RUNS PARALLEL TO P1–P2
**Why before P4:** two reviewers warned; the user chose audit-first. This is the phase that protects the working dashboards.

- 🔵 **ADMIN (this is the bulk):**
  - Extract effective FLS **from the live org** (not the repo — profiles are `.forceignore`d and the repo does not contain FLS truth).
  - Produce a verifiable **per-object/per-field FLS matrix**: 463 custom fields × 7 team permission sets, plus standard-object fields in use. Reconcile against the **1,537 Admin-profile grants vs 590 permission-set grants** delta.
  - Close every gap in deployable **permission sets** — distributed across `DPEG_Acquisitions` (346), `Property_Management_Access` (183), `Transaction_App_Access` (44), etc. **Not** `DPEG_Admin_Access` (it is a tab-visibility set with 1 field grant; the inbound brief's assumption is wrong).
  - Decide and document the **guest-user FLS strategy** (impossibility #2) — spike whether a permission set on the site guest user works, since the Guest Profile is not deployable.
- 🟢 **DEV:** none (permission-set metadata only).
- **Complexity:** 🟤 **`salesforce-solution-architect`** — explicitly. 463 fields × 7 sets is a security-model design problem (§ "OWD+sharing+FLS strategy", "permission set group strategy"), not field-by-field admin ticking.
- **🔴 Acceptance gate (non-negotiable):** verify as **each non-admin persona**, never as Admin. Admin passes regardless and proves nothing. Every KPI dashboard renders correct non-zero values for PM / Transactions / Acquisitions users **before** P4 begins.
- **Effort: 12–18 days**

### PHASE 4 — Selector extraction + `WITH USER_MODE` sweep
**Depends on:** P2 (safety net) **and** P3 (FLS closed + persona-verified).

- 🔵 **ADMIN:** none (but P3's permission sets must be deployed and verified first).
- 🟢 **DEV:** create ~33 custom + ~5 standard Selectors (`.claude/skills/sf-apex/assets/selector.cls`, reference `AccountSelector.cls`). Move ~85 query statements / ~107 `SELECT` keywords out of 25 controllers + 7 services. Add `WITH USER_MODE`. **Dynamic queries** (`WorkOrderController.ROW_QUERY`, `LeaseRenewalController.ROW_QUERY`, `TaskFanoutService.cls:46`) use `Database.query(q, AccessLevel.USER_MODE)`. Re-point all callers. Guest-portal selectors per the P3 decision.
- **Complexity:** ⚫ **`salesforce-technical-architect`** — selector granularity/method design across 38 objects is architecture; it sets the shape of the codebase for years.
- **Effort: 20–28 days**

### PHASE 5 — `TriggerHandler` base + handlers + Domain layer
- 🔵 **ADMIN:** none.
- 🟢 **DEV:** create the **`TriggerHandler` base class** (mandated, does not exist — see #6). Reduce all 4 triggers to `new <Object>TriggerHandler().run();` — **`TaskRollupTrigger` needs its loop/filter logic extracted** into handler/domain, the other 3 need handlers interposed only. Create Domain classes (~8–10 objects with real state rules: Opportunity, Contract_Review, Lease_Renewal, Lease_Inquiry, Work_Order, Onboarding, Transaction, LOI). Domain purity: zero SOQL, zero DML.
- **Complexity:** ⚫ **`salesforce-technical-architect`** (domain boundary decisions). **No `UnitOfWork`** — out of scope per #6.
- **Effort: 12–16 days**

### PHASE 6 — Controller thinning + Service adoption + error boundary (paired)
**Pair the two ends of the same wire**, per the brief's own observation.

- 🔵 **ADMIN:** none.
- 🟢 **DEV:** thin all 25 controllers to Service wrappers (§5: "Controllers must be thin wrappers around a Service class"); wire the LWC path through the 7 existing Services (currently bypassed). Add `AuraHandledException` to the ~54 of 75 `@AuraEnabled` methods lacking it, **and** in the same module add the missing `error` handling to the **57 of 82** components that destructure `{ data }` only — today a failed query silently renders `0` on KPI dashboards. Toast via `lightning/platformShowToastEvent`.
- **Complexity:** `salesforce-developer` (pattern is settled by P4/P5).
- **Effort: 18–25 days**

### PHASE 7 — LDV + discrete defects ⚠️ PARTIALLY INVERTS AHEAD OF P2
- 🔵 **ADMIN:** none.
- 🟢 **DEV:**
  - **`TaskFanoutService`** re-architecture: chunked Queueable + `System.Finalizer`; removes the unguarded `insert` at line 94. Add the `InputDTO`/`@InvocableVariable` inner class (#7). **Must precede/accompany its P2 bulk test.**
  - **Unbounded full-table scans** — confirmed exactly as reported: `WorkOrderController.cls:22` and `LeaseRenewalController.cls:24` both `SELECT ... FROM <obj>` with **no WHERE/LIMIT** and count in an Apex loop. `Work_Order__c` is a Yardi mirror — row count is set externally. Convert to aggregate `COUNT()`/`GROUP BY` in Selectors.
  - `ApprovalAuditService` silent-failure swallowing.
- **Complexity:** ⚫ **`salesforce-technical-architect`** (LDV + async re-architecture).
- **Effort: 5–8 days**

### PHASE 8 — Jest from zero + `@sa11y` + accessibility fixes
**Reality check: there is no `package.json` in this repo.** The toolchain is at absolute zero — not "0 tests", but 0 tests *and* 0 tooling.

- 🔵 **ADMIN:** none.
- 🟢 **DEV:** stand up `package.json` + `@salesforce/sfdx-lwc-jest` + `@sa11y/jest` + CI wiring (2–3d). Author **82 suites** (~0.5–1d each). Fix the **12 keyboard-inaccessible elements** (`rentRoll.html:55–67` `<th onclick>`/`<tr onclick>`; `dealDocStatus.html` 6× `<a onclick>` with no `href`) **in this phase**, so the `@sa11y` matchers pass rather than landing red.
- **Note:** `.forceignore:9` excludes `**/__tests__/**` — Jest tests correctly never deploy; CI must run them separately from `sf project deploy`.
- **Complexity:** `salesforce-developer` (volume, not architecture).
- **Effort: 45–88 days** ← largest single item; user accepted ~6–10 weeks (30–50d), **true range is higher because tooling starts at zero**

### PHASE 9 — SLDS 2 token migration
- 🔵 **ADMIN:** none.
- 🟢 **DEV:** replace **1,088 hardcoded hex across 137 files** with `--slds-g-*` tokens (today: 19 tokens in 9 bundles ≈ 11%). Run the SLDS linter; skill `.claude/skills/uplifting-components-to-slds2/`.
- **⚠️ Not purely mechanical:** hex also lives in **`.js`** (e.g. `activeTransactionsList.js` ×15, `brokerAssignmentKpis.js` ×3, `brokerListing.js` ×4) — chart/donut colours computed in JS cannot consume CSS custom properties directly and need a real per-component approach. The "right mechanism, wrong value" mitigation holds for `.css` only.
- **Complexity:** `salesforce-developer`; needs visual regression per component.
- **Effort: 25–40 days**

### PHASE 10 — `lwc/utils*` shared module
- 🔵 **ADMIN:** none.
- 🟢 **DEV:** create `lwc/utils*` (lowerCamelCase JS, no `.html`) per §5; consolidate the ~5 duplicated local formatters (`fmtMoney`, `money`, `fmtDate`) and re-point consumers.
- **Complexity:** `salesforce-developer`.
- **Effort: 3–5 days**

---

## 💰 EFFORT SUMMARY — NOT FLATTERED

| Phase | Work | Track | Agent | Days |
|-------|------|-------|-------|------|
| P0 | API 62→66 uplift | Dev | developer (→ tech-arch on regression) | 4–6 |
| P1 | TestDataFactory | Dev | **technical-architect** | 8–12 |
| P2 | Factory migration + 251 bulk + 90% cov | Dev | unit-testing + **technical-architect** | 37–54 |
| P3 | FLS audit + permsets | **Admin** | **solution-architect** | 12–18 |
| P4 | Selectors + USER_MODE | Dev | **technical-architect** | 20–28 |
| P5 | TriggerHandler + Domain | Dev | **technical-architect** | 12–16 |
| P6 | Controllers + error boundary | Dev | developer | 18–25 |
| P7 | LDV + discrete defects | Dev | **technical-architect** | 5–8 |
| P8 | Jest ×82 + sa11y + a11y fixes | Dev | developer | 45–88 |
| P9 | SLDS 2 tokens | Dev | developer | 25–40 |
| P10 | utils module | Dev | developer | 3–5 |
| | | | **TOTAL** | **189–300 engineer-days** |

### 🔴 The estimate does not match what was accepted

- **189–300 engineer-days ≈ 38–60 engineer-weeks ≈ 9–14 engineer-months.**
- The user accepted **"~2–3 months"**. For one engineer, 2–3 months ≈ 44–66 days — the program is **3–5× that**.
- 2–3 months **elapsed** is only reachable with **~4 engineers working genuinely in parallel**, and even then it is tight: the Apex critical path (P0→P1→P2→P4→P5→P6) is **99–141 days** and is largely **serial by dependency** — it does not compress by adding people.
- **What actually parallelises:** the UI track (P8/P9/P10 — 73–133d) is independent of the Apex track after P0, and P3 (Admin) runs alongside P1–P2. Staffing an LWC engineer + a solution architect from day 1 is what makes the calendar work.
- **Honest read: 3–5 months elapsed with 4 engineers**, not 2–3. The user asked for an accurate number for planning; this is it.

---

## 🔗 EXECUTION ORDER (dependency-critical)

1. **P0** — alone, own deploy, full test run. Nothing else in the PR.
2. **P1** — TestDataFactory. Blocks all test work.
3. **P3** — *start now, parallel*, Admin/solution-architect track. Blocks P4.
4. **P2** — safety net. Blocks P4. ⚠️ `TaskFanoutService`'s bulk test blocked by **P7**.
5. **P7 (TaskFanout slice)** — must land before/with its P2 bulk test. **The one justified inversion.**
6. **P4** — requires P2 green **and** P3 persona-verified. Never before both.
7. **P5** → **P6** — sequential.
8. **P7 (remainder)**, **P8**, **P9**, **P10** — UI track parallelisable from P0.

**Hard gates:**
- ❌ No `WITH USER_MODE` on any query until P3's FLS matrix is deployed **and verified as a non-admin persona**.
- ❌ No layering refactor until P2 is green.
- ❌ No `TaskFanoutService` bulk test using a shrunken `taskDefsOverride` to dodge the DML limit.

---

## 📝 PROMPTS FOR SPECIALIST AGENTS

Each phase is a separate invocation. Do not batch.

### 🟤 PROMPT FOR salesforce-solution-architect (PHASE 3 — run early, parallel)
```
Design and implement the FLS remediation for DPEG ahead of a WITH USER_MODE sweep.

CRITICAL CONTEXT — the repo does NOT contain the org's FLS truth:
- force-app/main/default/profiles/** is .forceignore'd (line 28); profiles are not deployable here.
- Admin.profile-meta.xml grants 1,537 <fieldPermissions>.
- The 7 team permission sets grant 590 <field> entries combined.
- DPEG_Admin_Access grants FLS on exactly ONE field (Lease_Inquiry__c.OneDrive_URL__c) — it is a
  tab-visibility set. Do NOT treat it as the FLS home.
- Real FLS homes: DPEG_Acquisitions (346), Property_Management_Access (183),
  Transaction_App_Access (44), Disposition_Dashboard_Access (12), Acquisitions_Dashboard_Access (3),
  Acquisition_Deal_Driver (1).

Deliver:
1. A per-object/per-field FLS matrix extracted from the LIVE org (not the repo): 463 custom fields
   across 33 custom objects × 7 team permission sets, plus standard-object fields used by the 25
   controllers. Reconcile the 1,537-vs-590 delta.
2. Permission-set updates closing every gap, routed to the correct existing set.
3. A guest-user FLS decision for the broker portal: the Guest User Profile is NOT deployable
   (.forceignore lines 20-28 name it). Spike whether a permission set assigned to the site guest
   user can carry guest FLS. Report the result — do not assume it works.

ACCEPTANCE (non-negotiable): verify every KPI dashboard renders correct non-zero values as EACH
non-admin persona (Property Management, Transactions, Acquisitions). Admin passes regardless and
proves nothing — USER_MODE enforces FLS against the running user, and Admins are covered by
profile grants that non-admins do not have.

Use project conventions (ARCHITECTURE.md, API 67.0 after Phase 0). Do not deploy — create metadata
files only. Do not add validation rules, new fields, or sharing rules; FLS + permission sets only.
```

### ⚫ PROMPT FOR salesforce-technical-architect (PHASE 1 — TestDataFactory)
```
Create force-app/main/default/classes/TestDataFactory.cls per ARCHITECTURE.md §2 (mandated as
non-negotiable; the file does not currently exist).

Cover the 33 custom objects (463 custom fields) plus standard Account/Contact/Lead/Opportunity/Task.
Honour required-field graphs and relationship chains, including:
  Property__c -> Property_Asset__c -> Unit__c -> Rent_Step__c
  Opportunity -> LOI__c -> Counter_Offer__c
  Transaction__c -> Task (via Transaction_Deal__c lookup, NOT WhatId)
  Lease_Inquiry__c / Lease_Renewal__c / Work_Order__c (Yardi mirrors)

Must support bulk creation of 251+ records per bulk-test-rule.md. Never @isTest(SeeAllData=true).
Follow .claude/skills/sf-apex-test/references/test-data-factory.md and the templates in
.claude/skills/sf-apex/assets/.

Scope limit: the factory only. Do not refactor existing tests in this phase (that is Phase 2).
Do not deploy — create the file only.
```

### ⚫ PROMPT FOR salesforce-technical-architect (PHASE 4 — Selectors + USER_MODE)
```
PRECONDITION — confirm before starting: Phase 3's FLS permission sets are DEPLOYED and verified as
each non-admin persona, and Phase 2's tests are green. If either is unconfirmed, STOP and report.

Extract all SOQL from 25 controllers + 7 services into Selector classes per
.claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2.

- ~33 custom + ~5 standard Selectors. One object per selector; nothing else queries that object.
- Method naming: selectByIds(Set<Id>), selectByStatus(String), etc.
- Every query uses WITH USER_MODE.
- Dynamic queries must use Database.query(q, AccessLevel.USER_MODE). Known dynamic sites:
  WorkOrderController.ROW_QUERY, LeaseRenewalController.ROW_QUERY, TaskFanoutService.cls:46.
- Guest-portal selectors (BrokerPortalController, without sharing, correct as-is) follow Phase 3's
  guest-FLS decision — do not blanket-apply USER_MODE there without it.
- Scope: 35 team-owned classes ONLY. The 10 Salesforce-generated Site/Communities boilerplate
  classes (MicrobatchSelfReg, ForgotPassword, ChangePassword, SiteRegister, SiteLogin,
  CommunitiesSelfRegConfirm, CommunitiesSelfReg, CommunitiesLanding, CommunitiesLogin,
  MyProfilePage) are OUT OF SCOPE — do not touch.

Templates: .claude/skills/sf-apex/assets/selector.cls; reference
.claude/skills/sf-apex/references/AccountSelector.cls. API 67.0. Do NOT create a UnitOfWork —
explicitly out of scope. Do not deploy.
```

### ⚫ PROMPT FOR salesforce-technical-architect (PHASE 7 — LDV + discrete defects)
```
Fix three confirmed defects. Note the TaskFanout item BLOCKS its Phase 2 bulk test — do it first.

1. TaskFanoutService.cls:49-98 accumulates toInsert across every Transaction and does a single
   `insert toInsert;` at line 94. At ~75 Tasks/Transaction, a 251-record bulk test = 18,825 DML rows
   vs the 10,000/transaction limit. Re-architect to a chunked Queueable with System.Finalizer
   (NOT @future, per apex-layering-rule.md). The bulk test must then pass at production-representative
   CMDT def counts — do NOT shrink taskDefsOverride to dodge the limit; that hides the real break.
   Also add the InputDTO inner class with @InvocableVariable fields per .claude/rules/invocable-rule.md
   (fanOut currently takes a bare List<Id> with no DTO).

2. Unbounded full-table scans — convert to aggregate COUNT()/GROUP BY inside Selectors:
   - WorkOrderController.cls:22 — SELECT ... FROM Work_Order__c with no WHERE/LIMIT, counted in an
     Apex loop. Work_Order__c is a Yardi mirror; row count is set externally and will hard-fail at scale.
   - LeaseRenewalController.cls:24 — same pattern on Lease_Renewal__c.

3. ApprovalAuditService — silent failure swallowing. It is `without sharing` (line 15); per
   ARCHITECTURE.md §2 that is permitted only WITH written justification in the class header Javadoc.
   Add the justification or change it.

Also add justification Javadoc headers to the other unjustified `without sharing` classes:
BrokerPortalNotifier.cls:1, GroupNotifier.cls:11. BrokerPortalController.cls:1 is `without sharing`
and CORRECT (public guest portal) — it needs a justification header, NOT a change.

API 67.0. Do not deploy.
```

### 🟢 PROMPT FOR salesforce-developer (PHASE 0 — API uplift)
```
Bump the project API version 62.0 -> 67.0 so ARCHITECTURE.md's cited authority agrees with the repo.

- sfdx-project.json: sourceApiVersion 62.0 -> 67.0
- Align <apiVersion> in ~89 .cls-meta.xml, 4 .trigger-meta.xml, and 82 LWC .js-meta.xml (~175 files).

This is its own task with its own deploy and a full RunLocalTests run — nothing else in this PR.
The 62->66 span is 4 releases; if the test run surfaces platform behaviour changes, STOP and report
rather than patching around them. Do not deploy — prepare the change; devops handles deployment.
```

### 🟢 PROMPT FOR salesforce-developer (PHASE 8 — Jest)
```
Stand up LWC Jest testing from zero and author suites for all 82 LWC bundles per ARCHITECTURE.md §5.

There is NO package.json in this repo — the toolchain does not exist yet. Create it:
@salesforce/sfdx-lwc-jest + @sa11y/jest + CI wiring. Note .forceignore:9 excludes **/__tests__/**,
so tests correctly never deploy; CI must run them separately from `sf project deploy`.

Author __tests__/<component>.test.js for all 82 bundles, with @sa11y/jest accessibility matchers.

Fix these 12 confirmed keyboard-accessibility defects IN THIS PHASE so the sa11y matchers pass
rather than landing red:
  - rentRoll.html:55-67 — <th onclick> and <tr onclick>
  - dealDocStatus.html — 6x <a onclick> with no href

Do not restyle components (that is Phase 9). Do not change Apex. Do not deploy.
```

### 🟢 PROMPT FOR salesforce-developer (PHASE 9 — SLDS 2)
```
Migrate LWC styling to SLDS 2 design tokens per ARCHITECTURE.md §5.

Current: 1,088 hardcoded hex values across 137 files; only 19 --slds-g-* tokens in 9 bundles (~11%).
Replace hex with --slds-g-* tokens. Run the SLDS linter before finishing.
Skill: .claude/skills/uplifting-components-to-slds2/

NOT purely mechanical — hex also appears in .js files (activeTransactionsList.js x15,
brokerAssignmentKpis.js x3, brokerListing.js x4, and others), where chart/donut colours are computed
in JS and cannot consume CSS custom properties directly. Those need a per-component approach; report
any component where the token cannot be applied without changing rendered output.

Most .css hex is already passed through correct SLDS hooks (right mechanism, wrong value) — preserve
the hook, change the value. Visual regression per component. Do not change markup structure or Apex.
Do not deploy.
```

*(Prompts for P2, P5, P6, P10 to be issued at their gates — each depends on the shape produced by its predecessor. Issuing them now would bake in assumptions that P1/P3/P4 have not yet settled.)*

---

## ✅ EXPLICITLY OUT OF SCOPE (guarding against creep)

- **`UnitOfWork`** — the layering rule is conditional ("if one exists"); none exists. Not required.
- **The 10 Salesforce-generated Site/Communities boilerplate classes** — layering, coverage, `SeeAllData`/`without sharing` hits.
- **Converting the 72 imperative-Apex LWCs to LDS/GraphQL** — the doc names aggregates as a legitimate Apex exception. Only ~2–8 genuine multi-object read candidates, spike-gated.
- **Already-conformant items — do NOT churn:** zero SOQL/DML in loops; zero `@future`; triggers bulk-safe; no SOQL injection (bind variables throughout); `with sharing` on all 25 team controllers; zero clickable `<div>`s; zero `console.log`; presentational components genuinely stateless.
- **New features, validation rules, sharing rules, objects, or fields** of any kind.

---

## ❓ DECISIONS NEEDED BEFORE P3/P4 START

1. **Guest-user FLS** (impossibility #2) — spike outcome determines whether broker-portal selectors get `USER_MODE` or a justified `SYSTEM_MODE` exemption. **Blocks P4's guest slice.**
2. **Doc amendments** — approve the four minimum amendments (boilerplate exemption; guest-portal selector clause; §6 cross-reference fixes; `TestDataFactory` reference). ARCHITECTURE.md §6 requires doc updates in the same PR as the convention change.
3. **Staffing** — 189–300 engineer-days vs the accepted "2–3 months". Confirm the 4-engineer parallel shape (Apex critical path 99–141d is serial and will not compress), or re-cut scope. **This is a planning fact surfaced for a decision, not a scope challenge.**
