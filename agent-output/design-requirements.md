# 📋 DESIGN REQUIREMENTS — Broker Protection: LLM Field Extraction Enrichment

**Date:** 2026-07-31
**Source spec (read in full, decisions D1–D4 treated as FINAL):** `agent-output/llm-field-extraction-spec-2026-07-31.md`
**Supersedes:** the previous contents of this file (Broker Protection Change Prompts 1 & 2 — that work has shipped; commits `eaefa10`…, `docs/2026-07-31-competing-broker-no-lead.md`).

**Consulted, in the order instructed:** `ARCHITECTURE.md` (§1 naming + Broker Protection objects, §2 Apex layering + staging model + async-pipeline exemption, §3.3 direct-callout exception), `LLMExtractionCalloutService.cls`, `ExtractAddressQueueable.cls`, `EmailToLeadService.cls`, `PropertyClaimService.cls`, `PropertyMatchingService.cls`, `InboundEmailStagingService.cls`, `InboundEmailActivityService.cls` (incl. the 2026-07-31 `Task.Type` header), `InboundEmailFieldUtil.cls`, the prior `agent-output/design-requirements.md` (Change 1 context).
**Additionally verified in the repo because the design depends on it:** `EmailToLeadHandler.cls`, `LeadConvertService.cls`, `TaskSelector.cls`, `PropertyRegistrySelector.cls`, `CompetingBrokerSubmissionSelector.cls`, `objects/Lead/fields/*`, `objects/Property__c/fields/Asset_Type__c`, `objects/Activity/fields/Inbound_Message_Id__c`, `objects/Lead/{listViews,compactLayouts}/*`, `flexipages/Lead_Record_Page`, all 32 permission sets, `duplicateRules/Lead.*`.
**Rules applied:** `.claude/rules/apex-layering-rule.md`, `.claude/rules/bulk-test-rule.md`, `.claude/rules/salesforce-global-rule.md`.

---

## 🎯 WHAT WAS REQUESTED

Enrich the Broker Protection inbound-email pipeline with full LLM field extraction:

1. **19 new Lead fields** + 2 new `Asset_Type__c` picklist values + `Inbound_Email_Staging__c.Extracted_JSON__c`.
2. **A relevance gate** (D2, tiered) so non-acquisition email stops producing Leads.
3. **Multi-property support** (D1, one Lead per property).
4. A rewritten LLM prompt / JSON contract and the Apex parser behind it (D3 two-tier storage).
5. PDF/OM attachment parsing is **out of scope** (D4).

D1–D4 are final and are not re-litigated anywhere below. Everything below is *how*.

---

## ⚠️ HEADLINE FINDING

> **This is not a "add 19 fields" change. It is a redesign of the routing tree plus a rewrite of the contract the claim engine's two load-bearing inputs travel on.**
>
> The routing tree's arbitration depends on exactly two extracted values — `broker_email` (repeat detection + submission attribution) and `property_address` (the unique `Property_Key__c`). Both are produced by a **single, tight, in-production prompt that today asks for four keys**. The change replaces that prompt with one ~20× larger and adds a `properties` array, an email classifier, and ~25 new keys.
>
> **The field enrichment is the low-risk half. The high-risk half is that a prompt rewrite is a silent behaviour change to the first-broker-wins engine** — a slightly differently-worded `property_address` produces a different `Property_Key__c`, and the 0.6 Jaccard fuzzy threshold may or may not rescue it. The failure is invisible: a competing broker quietly *wins* a property they lost, or a repeat registers as a new claim. No exception, no error row, no test failure.
>
> Three further findings that change the shape of the work, all verified against the repo:
> - **The multi-property loop can DEADLOCK.** `claim()` takes a `FOR UPDATE` lock per property and Apex holds row locks to commit, so one queueable claiming N properties ends up holding N locks. Two concurrent multi-property emails sharing two properties are a textbook AB-BA cycle. Salesforce does not report deadlocks — it reports `UNABLE_TO_LOCK_ROW`, which `acquireClusterLock` already swallows into `ClaimOutcome.UNCLAIMED` with only a `System.debug`. **Broker protection would silently fail on exactly the blast emails it exists for.** §1.2 fixes this with deterministic lock ordering.
> - **The current degrade catch is too narrow for the new response size.** `ExtractAddressQueueable` catches only `CalloutException`. `MAX_TOKENS` is **512**, which is roughly 4–8× too small for the new contract. A truncated response throws `JSONException`, escapes the degrade path, and lands the email in `Status = 'Error'` with **no Lead at all** — strictly worse than today's behaviour. §3.3.
> - **`Asset_Type__c` = Hospitality / Medical Office is silently destroyed at Lead conversion.** `LeadConvertService.buildProperty` copies the Lead's asset type onto `Property__c` *only if the value exists on `Property__c.Asset_Type__c`'s restricted picklist* — and that picklist (verified) is `Retail, C-Store, Land, Industrial, Office, Multifamily, Storage, Mixed-Use`. No exception, no error. The answer to "does anything break at conversion?" is **not** "no". §5 R4.

---

## 🔍 §0 — PREMISE CORRECTIONS & VERIFIED FINDINGS

Recon before design, per standing practice. Each row is checked against the repo, not assumed.

| # | Spec / prompt statement | Repo reality (verified) | Consequence |
|---|---|---|---|
| 0.1 | "`Parse_Confidence__c` — field exists today, unused by the pipeline" | ✅ **True, and better than stated.** The field exists as a **restricted picklist HIGH / MEDIUM / LOW**, *and* `objects/Lead/listViews/Review_Queue.listView-meta.xml` **already exists and already filters `Parse_Confidence__c = LOW`**, with columns Property Address / Guidance Price / Broker First / Parse Confidence. | **D2's soft-gate output has a working destination with ZERO new metadata.** Do not build a second review list view. |
| 0.2 | "`Broker_Protection_Access` must add all 20 new fields" | ⚠️ **Incomplete.** `Broker_Protection_Access` grants FLS on only **5** Lead fields. The *sibling* deal-screening fields (`Asset_Type__c`, `Guidance_Price__c`, `Guidance_Cap_Rate__c`, `Deal_Notes__c`, `Deal_Type__c`, `Parse_Confidence__c`) live in **three other permission sets**: `DPEG_Acquisitions`, `DPEG_Acquisition_View`, `DPEG_Acquisition_Edit`. | FLS on **4** permission sets, not 1 — else the acquisitions personas who actually work these Leads cannot see the 19 fields, and **an admin smoke test will not reveal it** (profiles are `.forceignore`d). §4.4, C-13. |
| 0.3 | "restricted picklist — values must exist before code writes them: deployment ORDER matters" | ✅ **True, and the trap is nastier than stated.** Apex **compiles against a picklist regardless of its values**. A code-first deploy is *green* and then throws `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` at runtime on the first Hospitality email — rolling back the claim. The compile checker protects you on *fields* and does **not** protect you on *picklist values*. | Metadata-first deploy order **plus** a `Schema.describe` runtime guard in the parser (defence in depth). §4.2, §6, R3. |
| 0.4 | Multi-Task logging risk: can N Tasks share one Message-ID? | ✅ **Cleared — not a blocker.** `objects/Activity/fields/Inbound_Message_Id__c.field-meta.xml` is `<externalId>true</externalId>` with **no `<unique>` element**. It is a non-unique External Id. N Tasks may carry the same Message-ID. `TaskSelector.selectByInboundMessageId` is `LIMIT 1`, so idempotency still works. | One-Task-per-routed-record is **available**. §1.4, C-2. |
| 0.5 | Reply threading with N Tasks per email | ⚠️ **New ambiguity.** `TaskSelector.selectLatestByThreadOrMessageIds` is `ORDER BY CreatedDate DESC LIMIT 1`. N Tasks inserted in ONE bulk DML share a `CreatedDate` to the millisecond → the tie-break is undefined. | Add `, Id DESC` and insert in ascending-priority order so "newest" is deterministic and *sensible*. §1.4, C-3. |
| 0.6 | "`Occupancy_Pct__c` Percent(3,2)" | ❌ **Spec defect.** In `CustomField` metadata `<precision>` is TOTAL digits. (3,2) → **one** integer digit → max **9.99%**. It cannot hold 88.00. Sibling `Guidance_Cap_Rate__c` is Percent(5,2). | Percent(**5**,2). C-10. |
| 0.7 | "`Guidance_Price_Low__c` / `High__c` Currency(16,2)" | ⚠️ Existing sibling `Guidance_Price__c` is **Currency(18,2)**. | Use (18,2) for all three so a value that fits one fits the others. C-11. |
| 0.8 | "LLM outage → regex fallback path must still create" | ✅ **Already implemented and correct** (`ExtractAddressQueueable` DEGRADED EXTRACTION block + `OUTCOME_NO_PROPERTY_LLM_DOWN`). No change needed to that rule — only its *catch clause* widens. | §3.3, C-14. |
| 0.9 | "org gotcha: Task.Type does NOT exist in usman-dpeg" | ✅ **Confirmed and already handled.** `InboundEmailActivityService` sets `TaskSubtype` only, with a retraction-grade header explaining why. **No new Task field writes are proposed by this design** beyond the existing two anchors. | Nothing to do; do not "restore" `Task.Type`. |
| 0.10 | Lead duplicate rules (the `DUPLICATES_DETECTED` → Savepoint-rollback failure class documented in this module) | ✅ **Both are inactive in the repo:** `Lead.Standard_Lead_Duplicate_Rule` `isActive=false`, `Lead.Standard_Rule_for_Leads_with_Duplicate_Contacts` `isActive=false`. | Populating `Company` from the LLM (instead of the constant placeholder) is **low** risk, not medium. Still confirm status in `usman-dpeg` — duplicate-rule activation is an org toggle. R11. |
| 0.11 | "SF→acres conversion in Apex" | ⚠️ Under-specified. If the LLM only ever returns `lot_size_acres`, the model must convert — which directly violates the spec's own **"never derive one number from another"** anti-hallucination rule. | The contract carries **both** `lot_size_acres` and `lot_size_sf`. The LLM reports what the email said; **Apex converts** (÷ 43,560) only when acres is null. §3.1, §3.4. |
| 0.12 | Per-transaction-singleton bulk-test exemption | ⚠️ **It stops applying to most of the module.** `ARCHITECTURE.md` §2 / `bulk-test-rule.md` grant it to methods with "no trigger, **no loop over multiple records**, invoked **exactly once per async job**". After D1 the queueable *loops*, and `claim()` / `createLeadFromExtracted()` are invoked **N times per job**. | Exemption narrows to `LLMExtractionCalloutService` only. Replacement volume tests specified in §7. C-18. |

---

## 🧩 §1 — D1: THE MULTI-PROPERTY REDESIGN

### 1.1 The reshaped routing tree

Today `route()` is one linear pass. The new shape splits into an **email-level prologue**, a **per-property loop**, and an **email-level epilogue**. The order below is the design; every step is justified.

```
EMAIL-LEVEL PROLOGUE  (once)
 0. staging Status == 'Processed'?              -> skip          [unchanged]
 1. Message-ID already on a Task?               -> skip          [unchanged]
 2. (a) REPLY — RFC In-Reply-To / References    -> route, NO LEAD, NO CALLOUT   ** MOVED UP **
 3. DETERMINISTIC PRE-FILTER (noreply/daemon)   -> gated, NO LEAD, NO CALLOUT   ** NEW **
 4. LLM CALLOUT (single, unchanged: 1 per job)
 5. Store Extracted_JSON__c VERBATIM             ** NEW, D3 — before any routing decision **
 6. Parse -> LLMExtractionResult (typed DTO)
 7. Regex + envelope broker fallbacks           [unchanged, email-level]
 8. RELEVANCE GATE (tiered, D2)                 ** NEW **
      hard gate -> stamp outcome, NO LEAD, NO CLAIM, log Task, done
      soft gate -> continue, Parse_Confidence__c = LOW
 9. Build the property work-list:
      - drop entries whose normalizeAddress() is blank -> "unaddressed" bucket
      - de-duplicate on normalized address (LLM repeats itself)
      - SORT by (clusterKey ASC, normalizedAddress ASC)      ** LOAD-BEARING — §1.2 **
      - truncate to MAX_PROPERTIES (10)                       ** §1.5 **
      - if the work-list is EMPTY -> branch (c) NO-PROPERTY, ONE Lead, done

PER-PROPERTY LOOP  (for each property, in the sorted order)
 (b) REPEAT      -> audit row, NO Lead, target = prior record
 (d) COMPETING   -> submission vs winner, NO Lead, target = winner's live record
 (e) WINNER      -> Lead + claim; DUPLICATE_RACE -> delete Lead, re-route as (d)
   ... each iteration appends a RoutingOutcome {outcome, recordId} to a list

EMAIL-LEVEL EPILOGUE  (once)
 10. Log ONE Task per DISTINCT routed record, in ONE bulk DML, ascending priority   ** §1.4 **
 11. Stamp staging: Outcome__c (summary), Result_Record_Id__c (primary),
     Routed_Record_Ids__c (all N), Property_Count__c, Processed_DateTime__c        ** §1.6 **
```

**Why (a) REPLY moves above the callout.** Branch (a) reads only `staging.In_Reply_To__c` / `References__c` and calls `resolveLiveRecord` — verified: it does **not** touch `extracted` at all. Moving it above the callout is therefore behaviour-preserving *and* removes an OpenAI call from the highest-volume branch once threading is working. Interaction with D3 is a genuine (small) conflict — see **C-6**.

**Why branch (c) NO-PROPERTY becomes email-level.** Today it is per-email by construction. If it stayed per-property, a 3-property email with one name-only entry would mint a junk unclaimable Lead — exactly the Lead-table pollution the 2026-07-31 change removed. So: (c) fires **once**, only when the *whole* work-list is empty. Unaddressed entries when others *are* addressable are handled by **C-1**.

### 1.2 🔴 Cluster-lock ordering — the deadlock fix

**The hazard.** `PropertyClaimService.claim()` calls `acquireClusterLock(clusterKey)`, which `FOR UPDATE`-locks a `Property_Claim_Lock__c` row. **Apex cannot release a row lock before commit.** A queueable claiming properties in clusters `{X, Y}` therefore holds *both* locks from the moment it takes the second one until the transaction ends.

```
Job A (email 1: Royal Inn, Bass Inn)   Job B (email 2: Bass Inn, Royal Inn)
  lock "1400 royal"      ✔                lock "220 bass"       ✔
  lock "220 bass"     ...blocked          lock "1400 royal"  ...blocked
```

Salesforce does not detect or report this as a deadlock. Both sides hit the ~10 s lock-wait, `acquireClusterLock` retries once, both time out, both return `false`, and `claim()` **fails safe to `ClaimOutcome.UNCLAIMED`** — which for branch (e) means *the Lead exists but holds no claim*. The only trace is a `System.debug`. **First-broker-wins silently does not protect, on precisely the multi-property blasts D1 exists to support.**

**The fix — total ordering, no new locking API.**

Process properties in **ascending `deriveClusterKey` order** (ties broken by normalized address). Because every transaction visits shared clusters in the *same relative order*, no wait-for cycle can form; the loser simply blocks on the first shared key and proceeds once the winner commits. This is the standard lock-hierarchy result and it costs **nothing**: no batch-lock method, no change to `claim()`, no extra lock hold time versus today.

Design points the implementer must not get wrong:

- The sort key must be derived **only** from the address (`deriveClusterKey(normalizeAddress(raw))`) — **never** from the LLM's array order, which is not stable across transactions.
- `deriveClusterKey` is deliberately coarse (`'<number> <firstAlphaToken>'`), so two *different* properties in one email can share a cluster key (`123 Main St, Dallas` and `123 Main St, Houston` → both `123 main`). Re-locking the same row inside one transaction is a no-op, so this is safe; do **not** de-duplicate on cluster key.
- De-duplicate on **normalized address** (`Property_Key__c`), keeping the first occurrence — the LLM does repeat itself.
- A `deriveClusterKey` of `''` cannot happen here: the work-list only contains properties whose `normalizeAddress` is non-blank, and `deriveClusterKey` falls back to the full normalized string.
- **Hoisting all locks up front is explicitly rejected.** It would lengthen the hold time of the *last* cluster's lock across the whole loop, increasing contention with no correctness gain — sorted lazy acquisition already removes the cycle.
- A per-property lock timeout is now **genuine contention, not a deadlock**, and must stop being invisible: append ` [unclaimed: lock timeout]` to the staging `Outcome__c` when any property fails safe. That single suffix is what turns an unobservable failure into a filterable one.

**Testability.** True concurrency is not reproducible in Apex. The honest, achievable coverage is: (i) direct unit tests on the ordering function (pure, no platform dependency, same category as the existing `deriveClusterKey` tests); (ii) an end-to-end assertion that `Routed_Record_Ids__c` lines come back in cluster-key order for a scrambled input array. Say so in the test class header rather than claiming the deadlock itself is tested.

### 1.3 Property A wins while property B is a duplicate — the mixed-outcome case

This is the normal case, not an edge case, and the pipeline must carry it end to end:

| Property | Branch | Lead? | Registry | Submission | Routed record |
|---|---|---|---|---|---|
| A — unclaimed | (e) WINNER | ✅ new Lead A | ✅ new row | ✅ winning, `Source_Lead__c` = A | Lead A |
| B — claimed by another broker | (d) COMPETING | ❌ **none** | — | ✅ non-winning, `Source_Lead__c` = **null** | B's winner (live record) |
| C — this broker already submitted | (b) REPEAT | ❌ none | — | ✅ audit row | C's prior record |

Each iteration is **independent**: an exception inside one property must not lose the others. Recommended shape — the loop body is wrapped so a per-property failure records `RoutingOutcome{outcome:'Error', recordId:null, error:'…'}` and the loop continues; the staging row then stamps `Status = 'Error'` **plus** the outcomes that did succeed (this exactly matches the existing "partial success" contract that `routedRecordId`/`routedOutcome` members were introduced for). Without this, one bad property rolls back a legitimate claim on another.

⚠️ **Savepoint note.** There is deliberately **no** `Savepoint` in this module today (`PropertyClaimService.isLostRaceAgainst`'s Javadoc depends on there being none). Do not introduce one to isolate loop iterations — it would change the self-match reasoning that guards the destructive Lead delete. Per-property `try/catch` + continue is the correct isolation primitive here.

### 1.4 Task logging shape — one Task per DISTINCT routed record

**Recommendation: one Task per distinct routed record (de-duplicated by record Id), all carrying the same `Inbound_Message_Id__c` and the same `Thread_Key__c`, inserted in ONE bulk DML.** (C-2.)

Why not one Task per email: a competing submission on property B would leave **no activity at all** on B's winning Lead. The module's whole premise is that "the property's whole story lives in one place" — a submission row with no email behind it is a claim nobody can audit.

Why not one Task per *property*: two properties routing to the same record would double-log the same email on that record.

What makes it safe (all verified, §0.4/§0.5):

- `Inbound_Message_Id__c` is a **non-unique** External Id → N rows with one Message-ID insert cleanly. `isAlreadyLogged` is `LIMIT 1` → idempotency is unaffected.
- `Thread_Key__c` is the **conversation root**, shared by design across every message in a thread — identical on all N is correct, not a bug.
- **Reply-resolution tie-break (C-3):** `selectLatestByThreadOrMessageIds` must become `ORDER BY CreatedDate DESC, Id DESC LIMIT 1`, and the Task list must be inserted in **ascending priority** so the highest-priority record's Task gets the highest Id: `NO-PROPERTY < REPEAT < COMPETING < WINNER`. A later reply into a multi-property thread then lands on the deal **we actually own**, deterministically, instead of on an arbitrary row.
- `attachTo` already picks `WhoId` vs `WhatId` from the Id's SObjectType, so a mixed Lead/Opportunity target set needs no caller change.
- **Change 2 (EAC Thread Guard) interaction:** more Leads now carry anchors for the same thread, so the guard **keeps** EAC copies on more Leads. That is a widening of "keep", never of "delete" — consistent with the C-10 note in the previous design. Worth one test.

`InboundEmailActivityService.logInboundEmail` therefore gains a **bulk sibling**: `logInboundEmail(List<Id> recordIds, …)` doing one `insert` of N Tasks and returning the inserted list. The existing single-Id method stays as a one-element wrapper so no existing caller or test changes.

### 1.5 Governor arithmetic and the realistic ceiling for N

Measured against the code, per property, worst realistic path (branch (e) WINNER):

| Step | SOQL | DML |
|---|---|---|
| `findBrokerSubmission` (repeat detection, ×2 when envelope ≠ LLM address) | 1–2 | — |
| `findMatchingRegistry` pre-read (exact + recent fuzzy) | 1–2 | — |
| `createLead` | — | 1 |
| `acquireClusterLock` → `ensureLockRow` + `selectByClusterKeyForUpdate` (×2 on retry) | 2–4 | 0–1 |
| `findMatchingRegistry` under the lock | 1–2 | — |
| `registerWinner` (registry + submission) | — | 2 |
| duplicate-key reconciliation (`findMatchingRegistry` + `findOrphanedRegistry`) | 0–3 | 0–2 |
| `resolveLiveRecord` (branches b/d only) | 0–1 | — |
| **Typical** | **~8** | **~4** |
| **Worst** | **~14** | **~6** |

Email-level: 1 staging read + 1 reply lookup + 1 callout; epilogue 1 bulk Task DML + 1 staging DML.

Async (Queueable) limits and the binding constraint:

| Limit | Async cap | Consumption | Ceiling for N |
|---|---|---|---|
| **SOQL queries** | **200** | ~8N + 2 (typ.) / ~14N + 2 (worst) | **~24 typ. / ~14 worst 🔴 BINDING** |
| DML statements | 150 | ~4N + 2 | ~37 |
| Query rows | 50,000 | ≤ 400/property (two `LIMIT 200` scans) | ~125 |
| DML rows | 10,000 | ~4N + N | not binding |
| CPU | 60,000 ms | ~400 Jaccard comparisons/property | not binding at N ≤ 25 |
| Heap | 12 MB | 131 KB body + ≤131 KB JSON + image base64 | not binding |
| Callouts | 100 | **1** | not binding |

**Recommendation: `MAX_PROPERTIES = 10`** (C-4). That is >2× headroom on the binding SOQL limit even in the worst path, and comfortably above any real broker blast (the motivating Bracket email carries 2).

**Above 10 — truncate, visibly, never silently:**
- process the first 10 **in the sorted order** (deterministic, not "whatever the model listed first");
- `Extracted_JSON__c` holds **all** M verbatim, so nothing is lost;
- `Property_Count__c` records M while `Routed_Record_Ids__c` has 10 lines — the discrepancy *is* the signal;
- append ` [truncated: 10 of M]` to the staging `Outcome__c`;
- append an "Additional properties in this email (not routed)" block to the first Lead's `Deal_Notes__c`.

**Queueable chaining for 11+ is explicitly deferred, not rejected.** It is feasible (the callout is already done and the JSON is on staging, so a child job needs no second callout; the parent commits and releases its locks before the child starts, so the two halves of one email cannot deadlock with each other). It is deferred because it doubles the state machine for a case with no observed occurrences. `MAX_PROPERTIES` must be a named constant so raising it — or wiring chaining later — is a small, local change.

### 1.6 Staging semantics for N results

`Result_Record_Id__c` is **Text(18)** — one Id. Widening it would break every existing consumer and the operations runbook. Recommendation (C-16):

| Field | Change | Semantics for N |
|---|---|---|
| `Result_Record_Id__c` | **unchanged** | The **primary** routed record, by the same priority as §1.4: first WINNER Lead → else first COMPETING winner → else REPLY/REPEAT target → else null. Single-property emails are byte-identical to today. |
| `Outcome__c` | unchanged metadata (free Text 255); `<description>` updated | **N = 1 → today's labels, unchanged** (backward compatible, no sweep needed). **N > 1 → a summary with a stable, filterable prefix:** `Multi-Property (3): 1 New Lead (winner), 1 Competing Submission, 1 Repeat`. Constant `OUTCOME_MULTI_PREFIX = 'Multi-Property'`. Suffixes ` [truncated: X of M]` / ` [unclaimed: lock timeout]` append when applicable. |
| `Routed_Record_Ids__c` | 🆕 LongTextArea(32768) | One line per routed property, **in processing order**: `<normalized address> | <outcome> | <recordId>`. The complete N-result audit; the only place the full mapping exists. |
| `Property_Count__c` | 🆕 Number(3,0) | Properties the extraction **found** (M, pre-truncation). |
| `Extracted_JSON__c` | 🆕 LongTextArea(131072) | The raw LLM response **verbatim**, written at step 5 — before any routing decision, so it survives every branch including the hard gate (D3). Must be written through `InboundEmailFieldUtil.clip(..., 131072)`; an over-long response would otherwise throw. |

`Outcome__c` remains free Text, so **no picklist work and no value sweep** — the standing "grep repo + query org before touching a picklist value" rule does not bite here (it *does* bite on `Asset_Type__c`; see §4.2).

### 1.7 `EmailToLeadService`'s contract change

The class header states the invariant *"one inbound email == at most one Lead"* and justifies plain single-record DML on it. That invariant **is now false**.

**Recommendation (C-5): keep `createLeadFromExtracted` single-record-shaped and call it N times. Do not bulkify the claim engine.** Restate the invariant as *"one PROPERTY == at most one Lead; one email can produce N."*

Both bulkification routes were considered and are rejected for concrete reasons:

- **Bulk-insert all N Leads up front** — breaks branch (d)'s load-bearing ordering rule ("the registry read runs BEFORE createLead… creating the Lead first would mint an orphan Lead on every competing email"). It re-introduces exactly the pollution the 2026-07-31 change removed.
- **Two-pass decide-then-commit** (`decide()` + `commitClaims()`) — genuinely bulk-shaped, but requires splitting `claim()`, and `registerWinner` needs the Lead Id *before* inserting the registry row (a null `Winning_Lead__c` means "orphan" in this schema). The unique-index backstop, orphan adoption, and the `isLostRaceAgainst` self-match guard would all have to be re-derived against `Database.insert(list, false)` partial success. That is the most subtle code in the module and the payoff is zero: N is 1–5 in production, and the governor budget (§1.5) is not close to binding at N ≤ 10.

**The rule this does NOT relax:** no SOQL/DML *inside* an inner loop. Every statement stays one-per-property, and the Task insert is bulked into one DML.

Additions to `EmailToLeadService`:
- a **`LeadRequest` DTO** carrying the 19 typed values + the legacy four (following the in-repo `InboundEmailStagingService.StagingRequest` precedent, whose Javadoc already gives the reason: *"a DTO rather than a twelve-parameter method signature… positional arguments would be trivially transposable"*). This avoids a ~25-parameter method.
- `deleteLead(Id)` is **unchanged** — the lost race is still per-property, one at a time.
- `Company` fallback: `broker_company` when non-blank, **else the existing `COMPANY_PLACEHOLDER`**. `Company` is required; never write blank.

---

## 🚪 §2 — D2: THE TIERED RELEVANCE GATE

### 2.1 Placement relative to Reply detection — **Reply wins, always**

**Recommendation: (a) REPLY is evaluated BEFORE the gate, and a reply is filed as a Reply even if the classifier says the reply itself is not acquisition-related.**

Three independent justifications:

1. **Deterministic evidence beats a probabilistic opinion.** An In-Reply-To / References match is *proof* this message continues a thread this pipeline already routed. A classifier's read of the message body cannot outrank an identity match on the transport layer.
2. **The failure modes are wildly asymmetric.** Gate a genuine reply out → the reply is lost from the deal record; a human wrote it, it belongs there, and nobody reads staging rows. File a non-acquisition reply as a Reply → one extra Task on a record it is already threaded to. Cost ≈ zero.
3. **Replies systematically *look* non-acquisition.** "Thanks." / "Will do." / "Can you resend the OM?" / an out-of-office auto-reply inside a live thread. A classifier reading only that text will confidently answer `is_acquisition_related = false`. Gating on it would discard exactly the conversational tail the thread anchors were built to capture.

Consequence, stated plainly: **the gate can only ever suppress a NEW conversation, never an existing one.** That is the property that makes it safe to ship.

### 2.2 The deterministic pre-filter — **recommend YES, narrowly** (C-7)

Runs **after** reply detection and **before** the LLM callout.

**Scope — envelope + header only, high precision:**
- `From` local-part (case-insensitive, exact or prefix): `noreply@`, `no-reply@`, `donotreply@`, `do-not-reply@`, `mailer-daemon@`, `postmaster@`, `bounce@`, `bounces@`.
- RFC 3834 `Auto-Submitted: auto-replied` / `auto-generated`; `X-Autoreply` present; `Precedence: bulk` / `auto_reply`. (All available — `EmailToLeadHandler` already persists **every** header verbatim into `Raw_Headers__c` for exactly this class of question.)

**Why yes:**
1. **Cost and latency.** The callout is the only expensive step; this is the highest-volume junk class. Every skip saves tokens, a 30 s timeout risk, and a callout.
2. **Precision, not recall.** A broker never emails from `mailer-daemon@`. These patterns are ~100% precise for "not a human pitching a property".
3. **It is the fix for the actual observed defect.** The spec names "today's two Gmail forwarding-confirmation junk Leads" as the canonical case — those arrive from `forwarding-noreply@google.com`. A deterministic filter kills that class outright instead of depending on the classifier getting it right every time.

**Why narrow:**
- **No subject-keyword filtering** ("Out of Office", "Undeliverable", "Newsletter"). Low precision; a broker's subject line can contain anything. Explicitly rejected.
- **A hit is not a discard.** Staging `Outcome__c = 'Not Acquisition (pre-filtered)'`, `Extracted_JSON__c = {"skipped":"pre-filter","reason":"<pattern>"}`, the Task is still logged (Message-ID idempotency **must** be recorded or a redelivery re-runs the whole pipeline), no Lead, no claim. The raw email lives on the staging row forever and is fully recoverable.
- **A static `Set<String>` constant in Apex, not a Custom Metadata Type.** A CMDT is scope the user did not ask for; note it as a clean future upgrade.

### 2.3 Confidence values and thresholds (C-8, C-9)

**`confidence` is a NUMBER 0.00–1.00 from the model; Apex derives the picklist band.** Reasons: a number is thresholdable and tunable without touching the prompt; models are more consistent producing a number than a self-assessed label; and Apex owning the mapping makes it **impossible** to write an out-of-set value into the **restricted** `Parse_Confidence__c` picklist (which would throw and roll back the claim).

Bands — Apex constants, one place to tune:

| `confidence` | `Parse_Confidence__c` |
|---|---|
| ≥ 0.85 | `HIGH` |
| 0.60 – 0.849 | `MEDIUM` |
| < 0.60 | `LOW` |
| missing / unparseable / LLM outage | `LOW` |

Gate:

| Condition | Action | Lead? | Claim? | Staging `Outcome__c` |
|---|---|---|---|---|
| `is_acquisition_related = false` **AND** `confidence ≥ 0.85` | **HARD GATE** | ❌ | ❌ | 🆕 `Not Acquisition (gated)` |
| `is_acquisition_related = false` **AND** `confidence < 0.85` | **SOFT** | ✅ | ✅ | the normal routing outcome |
| `is_acquisition_related = true` | normal | ✅ | ✅ | the normal routing outcome |
| pre-filter hit (§2.2) | **HARD** | ❌ | ❌ | 🆕 `Not Acquisition (pre-filtered)` |
| LLM outage | **create** (standing rule) | ✅ | ❌ (no address) | `New Lead (no property) — LLM unavailable` (existing) |

**The soft gate still CLAIMS.** This is deliberate and asymmetric on purpose: claiming a junk address costs one registry row that a human can delete; *not* claiming a real one costs a broker their commission and DPEG its protection. Generosity is the correct bias for a first-come-first-served ledger.

**The soft tier gets NO dedicated staging label.** It is expressed by `Parse_Confidence__c = LOW` on the Lead, which flows straight into the **already-existing `Review_Queue` list view** (§0.1). Giving it its own `Outcome__c` value would multiply against every routing outcome for no gain.

**Net new label constants: two** — `OUTCOME_NOT_ACQUISITION = 'Not Acquisition (gated)'` and `OUTCOME_PRE_FILTERED = 'Not Acquisition (pre-filtered)'`, plus the `OUTCOME_MULTI_PREFIX` from §1.6. Keeping them distinct matters operationally: "the classifier rejected it" and "a regex rejected it before we ever asked" need different follow-up.

`email_category` is validated against its closed set and stored **only inside `Extracted_JSON__c`** — no new picklist field this iteration. It drives nothing except the gate's explainability.

---

## 📜 §3 — THE JSON CONTRACT AND THE APEX PARSER

### 3.1 Full schema

```jsonc
{
  // ── email level ──────────────────────────────────────────────
  "email_category": "acquisition_deal|call_for_offers|reply|system_notification|newsletter|out_of_office|other",
  "is_acquisition_related": true,
  "confidence": 0.92,                 // 0.00–1.00

  "broker_name": "",                  // LEGACY KEY — the FORWARDING/original broker. Claim engine input.
  "broker_email": "",                 // LEGACY KEY — claim engine input. DO NOT REPURPOSE.
  "broker_company": "",
  "broker_phone": "",
  "broker_mobile": "",
  "broker_title": "",
  "listing_broker_name": "",          // blast platforms: sender != listing broker
  "listing_broker_email": "",
  "sent_datetime": "yyyy-MM-dd HH:mm:ss",   // LEGACY KEY — UTC
  "deal_summary": "",                 // <= 800 chars; narrative + spillover + reported-vs-adjusted NOI

  // ── per property ─────────────────────────────────────────────
  "properties": [
    {
      "property_name": "",
      "property_address": "",         // LEGACY KEY (was top-level) — the claim key
      "asset_type": null,             // closed set incl. Hospitality, Medical Office
      "deal_type": null,              // Land | Commercial
      "sale_process": null,           // Off-Market | On-Market Listing | Call for Offers | Auction
      "guidance_price": null,
      "guidance_price_low": null,
      "guidance_price_high": null,
      "cap_rate": null,               // percentage number, e.g. 6.75 (NOT 0.0675)
      "noi": null,
      "occupancy_pct": null,          // percentage number, e.g. 88.0
      "building_sf": null,
      "lot_size_acres": null,         // report ONLY if the email states acres
      "lot_size_sf": null,            // report ONLY if the email states square feet — Apex converts
      "unit_count": null,             // units OR hotel keys
      "year_built": null,
      "year_renovated": null,
      "walt_years": null,
      "adr": null,
      "zoning": "",
      "seller_entity": "",
      "deal_room_link": "",
      "offer_due_date": "yyyy-MM-dd"
    }
  ]
}
```

**`broker_*` vs `listing_broker_*` is a hard boundary.** The claim engine reads `broker_email` and nothing else. Repointing it at `listing_broker_email` would re-attribute every claim. Say this in the prompt *and* in the class Javadoc.

### 3.2 Backward compatibility during rollout

**Recommendation: the claim path's `Map<String,String>` contract does not change at all.**

- `LLMExtractionCalloutService.extract(...)` returns a new typed DTO `LLMExtractionResult { emailLevel…, List<PropertyExtraction> properties, String rawJson }`.
- It exposes `Map<String,String> toLegacyMap(PropertyExtraction p)` producing **exactly** the four keys `{broker_name, broker_email, property_address, sent_datetime}`, empty-string-for-absent, per property.
- **`PropertyClaimService` and `PropertyMatchingService` signatures are untouched.** They keep receiving a four-key map. Zero churn in the race-safety code, zero risk to the hardest-won logic in the module, and every existing test of those classes still compiles.
- Only `EmailToLeadService` grows — via the `LeadRequest` DTO (§1.7), not by widening the map.

**Parser tolerance both ways (the rollback lever):**
- Response has **no** `properties` array but a top-level `property_address` → synthesize `properties = [ { property_address: <top-level> } ]`. **This is the legacy 4-key shape**, so reverting `EXTRACTION_INSTRUCTION` to today's constant is a **one-line rollback with no code change**.
- Response has `properties` but no top-level `property_address` → normal new shape.
- `confidence` arriving as the string `'HIGH'`/`'MEDIUM'`/`'LOW'` is also accepted and mapped straight through (tolerance during prompt iteration).

### 3.3 🔴 Response size, model, and the truncation failure

**Current, verified:** `MODEL = 'gpt-4o-mini'`, `TIMEOUT_MS = 30000`, **`MAX_TOKENS = 512`**, `temperature = 0`.

Sizing the new contract: email-level block ≈ 150 tokens; each property object (23 keys) ≈ 200–260 tokens; `deal_summary` 150–400. **3 properties ≈ 1,150 tokens. 10 properties ≈ 2,900.** 512 is 4–8× short.

**Why this is the most dangerous line in the change.** A truncated response is cut mid-object → `JSON.deserializeUntyped` throws `JSONException` → and the degrade `catch` in `ExtractAddressQueueable` is **deliberately narrowed to `CalloutException`** ("a parsing/JSON failure inside extract() is a defect in our own contract and still escapes to the error handler below"). So a truncation lands the email in `Status = 'Error'` with **no Lead, no Task, no claim** — the exact "indistinguishable-from-lost broker submission" outcome the DEGRADED EXTRACTION design was written to prevent.

**Recommendations (C-14), all four together:**

| # | Change | Why |
|---|---|---|
| 1 | `MAX_TOKENS` **512 → 4096** | Headroom for 10 properties + prose; well inside gpt-4o-mini's 16k output ceiling. |
| 2 | Add `"response_format": {"type": "json_object"}` to the request body | OpenAI JSON mode **guarantees syntactically valid JSON**. One line; the single strongest mitigation. Also lets `stripCodeFences` become belt-and-braces rather than load-bearing. |
| 3 | Prompt-level caps: `deal_summary` ≤ 800 chars; **at most 10 property objects** (describe any remainder in `deal_summary`) | Bounds the response before the token limit has to. |
| 4 | **Widen the degrade catch to `JSONException`** (and a defensive `Exception` around the parse) | Deliberate, documented **reversal** of the current narrow-catch decision. Justification: with an 8× larger response, a malformed reply is no longer "a defect in our own contract" — it is the same category of event as an outage, an *absent optional input*. Degrading to the regex fallback loses the address; erroring loses the email. Mark it clearly in the class header as a reversal so a future reader does not "restore" the old comment. |

**Also recommended:**
- `TIMEOUT_MS` **30000 → 60000** — a 10-property extraction is materially slower. (Per-callout max is 120 s; safe.)
- **Clip the text sent to the LLM** to a constant (recommend 40,000 chars) — `Raw_Body__c` can be 131,072 (~33k tokens) and the tail of a forward is quoted history. ⚠️ This touches the *existing* four fields: the outermost `From:`/`Sent:` lines are at the **top** of a forward so it is safe in principle, but it must be covered by the §3.5 regression fixtures before shipping (C-15).
- **`MODEL` and `temperature = 0` do not change.** Changing the model at the same time as the prompt would make a regression impossible to attribute.

**Cost per email (gpt-4o-mini @ ~$0.15/1M in, ~$0.60/1M out):** ~10k input + ~1.5k output ≈ **$0.0024**. With a vision image (1,000–2,500 extra input tokens) still sub-cent. At 500 emails/day ≈ **$36/month**. **Cost is not a constraint on this design; response truncation is.** Stating that honestly matters — the temptation to shrink the prompt "for cost" would trade a $30/month saving for the failure mode above.

### 3.4 The Apex parser — a NEW class

**Recommendation (C-17): a new `LLMExtractionParser` (utility layer). Do NOT extend `InboundEmailFieldUtil`.**

1. `InboundEmailFieldUtil`'s documented charter is exactly two functions, and its value is that it is small and obviously correct — it is *the chokepoint* for field-length/format safety across five writers. Adding ~15 typed coercions dilutes that.
2. The parser has a different contract: **never throws**, returns typed nulls, and *accumulates* human-readable notes for unparseable values.
3. Layering stays clean: **parser = coercion (String/Object → typed), util = field safety (typed → DML-safe)**. `EmailToLeadService` still clips and sanitizes through `InboundEmailFieldUtil` on the way out. Pure functions, no SOQL/DML, directly unit-testable.

**Strict validation rules — the parser is the contract; the prompt is only a hint.**

| Target type | Rule | On failure |
|---|---|---|
| Currency (`noi`, `guidance_price*`, `adr`) | accept JSON number **or** String; strip `$`, `,`, spaces; expand suffixes `K`→×10³, `M`/`MM`→×10⁶, `B`→×10⁹ (**this is where `"$7.1M"` is handled — Apex owns it, not the model**); reject negatives; reject > 10¹³ (Currency(18,2)); round to 2 dp | `null` + note |
| Percent (`cap_rate`, `occupancy_pct`) | accept number or String with `%`; **require a percentage number (88.0, not 0.88)** — stated in the prompt; reject < 0 or > 100. Deliberately **no** "if ≤ 1 assume a fraction" heuristic: a 0.9% cap rate is implausible but an 0.9 occupancy fraction is not, and guessing silently corrupts. | `null` + note |
| Integer (`building_sf`, `unit_count`) | strip commas; non-negative; round decimals; ≤ 999,999,999 | `null` + note |
| `year_built` / `year_renovated` | **Apex owns 2-digit normalization**: `88`→1988, `22`→2022 (pivot at the current 2-digit year); reject outside `1700 … currentYear + 5` | `null` + note |
| `lot_size_acres` | number ≥ 0, ≤ 99,999,999.99. **If null and `lot_size_sf` present → `sf / 43560`, 2 dp.** Apex owns the conversion; the model never converts (§0.11) | `null` + note |
| `walt_years` | 0 ≤ x ≤ 999.9, 1 dp | `null` + note |
| Date (`offer_due_date`) | strict `yyyy-MM-dd` via `Date.valueOf`; reject > 2 years future or > 1 year past. **Relative phrases ("offers due TODAY") are resolved by the PROMPT against `sent_datetime`, never by Apex** — Apex has no reliable notion of the email's local day | `null` + note |
| Closed-set picklists (`asset_type`, `deal_type`, `sale_process`) | 🔴 **Must be a member of the value set read from `Schema.describe` AT RUNTIME**, exact match after trim. Never write an unvalidated value to a **restricted** picklist — `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` rolls back the claim. Follow the existing `LeadConvertService.assetTypePicklistValues()` precedent, which does exactly this. **This is also the runtime half of the deploy-order defence (§0.3).** | `null` + note |
| Email (`listing_broker_email`) | `InboundEmailFieldUtil.sanitizeEmail` (80 chars + shape) | `null` |
| URL (`deal_room_link`) | must start `http://`/`https://`; length ≤ 255. **Do NOT clip** — a clipped URL is a broken URL that looks valid | `null` + note |
| Text (`property_name`, `zoning`, `seller_entity`, `listing_broker_name`, `broker_company`, `broker_title`) | `InboundEmailFieldUtil.clip` to the destination length | clipped |
| Phone (`broker_phone`, `broker_mobile`) | clip to 40 (standard Lead Phone length); no format enforcement | clipped |
| `confidence` | number 0–1 → band; `'HIGH'`/`'MEDIUM'`/`'LOW'` accepted → passthrough | `LOW` |
| `email_category` | member of the closed set, else `other` | `other` |

**Notes are not discarded.** The parser returns `List<String> notes`; the writer appends them to `Deal_Notes__c` under a `-- Extraction notes --` header. That converts silent data loss into something a human sees on the record — which is the entire point of validating rather than trusting.

### 3.5 🔴 The regression fixture set (the prompt-quality guard)

This is the single most valuable test in the change and it is **available for free**: `Inbound_Email_Staging__c` rows are *never deleted* (the object is the pipeline's audit trail), so `usman-dpeg` already holds the raw body + headers of every email the pipeline has processed.

**Requirement:** capture those raw bodies as static test fixtures and assert, for every one, that the **new** prompt/parser returns:
- the **same `broker_email`**, and
- the **same `PropertyMatchingService.normalizeAddress(property_address)`**

as the current 4-key contract does. Not "a similar address" — the *same normalized key*, because that key **is** the claim identity. Any drift is a claim-engine regression, and this is the only mechanism that will catch it before a broker does. (C-19.)

---

## 🧱 §4 — METADATA INVENTORY

### 4.1 Lead — 19 new fields

All API names verified against `ARCHITECTURE.md` §1: every underscore-separated segment starts with an uppercase letter or digit; acronyms (`NOI`, `SF`, `ADR`, `WALT`) fully uppercase; rule 9 type suffixes (`_Pct__c`, `_Count__c`, `_Date__c`, `_Name__c`) applied; no Text/Number field named identically to a custom object (checked against `Property__c`, `Unit__c`, `Lease__c` — `Property_Name__c` is in fact rule 9's own canonical example, and `Unit_Count__c` is distinct from `Unit__c`).

| Field | Type | LLM key | Note |
|---|---|---|---|
| `Property_Name__c` | Text(255) | `property_name` | rule 9 `_Name__c` |
| `NOI__c` | Currency(18,2) | `noi` | rule 5: industry term wins over `_Amount` |
| `Occupancy_Pct__c` | **Percent(5,2)** | `occupancy_pct` | ⚠️ **not (3,2)** — see §0.6 / C-10 |
| `Building_SF__c` | Number(18,0) | `building_sf` | |
| `Unit_Count__c` | Number(18,0) | `unit_count` | help text: "Units, or hotel keys for hospitality" |
| `Offer_Due_Date__c` | Date | `offer_due_date` | rule 6 `_Date__c` |
| `Sale_Process__c` | Picklist, **restricted** | `sale_process` | Off-Market / On-Market Listing / Call for Offers / Auction — new field, values ship with it |
| `Guidance_Price_Low__c` | **Currency(18,2)** | `guidance_price_low` | ⚠️ match existing sibling — C-11 |
| `Guidance_Price_High__c` | **Currency(18,2)** | `guidance_price_high` | ⚠️ same |
| `Year_Built__c` | Number(4,0) | `year_built` | |
| `Year_Renovated__c` | Number(4,0) | `year_renovated` | |
| `Lot_Size_Acres__c` | Number(10,2) | `lot_size_acres` / `lot_size_sf` | unit in the name — same pattern as the fixed `Lease_Term_Months__c` |
| `WALT_Years__c` | Number(4,1) | `walt_years` | |
| `ADR__c` | Currency(10,2) | `adr` | hospitality only |
| `Zoning__c` | Text(100) | `zoning` | |
| `Seller_Entity__c` | Text(255) | `seller_entity` | |
| `Deal_Room_Link__c` | URL | `deal_room_link` | matches existing `CoStar_Link__c` / `Placer_AI_Link__c` convention |
| `Listing_Broker_Name__c` | Text(120) | `listing_broker_name` | |
| `Listing_Broker_Email__c` | Email | `listing_broker_email` | Email fields are always 80 chars regardless of metadata |

**Every field must carry a populated `<description>` and inline help text.** `ARCHITECTURE.md` §1 treats unset descriptions as a defect it is still paying down (22 of 33 objects); do not add 19 more. Also `trackFeedHistory=false`, `required=false`, matching sibling files.

**Existing Lead fields the extraction newly populates** (no metadata change): `Company`, `Phone`, `MobilePhone`, `Title`, `Guidance_Price__c`, `Guidance_Cap_Rate__c`, `Asset_Type__c`, `Deal_Type__c`, `Deal_Notes__c`, `Parse_Confidence__c`.

### 4.2 🔴 Picklist values — and the deploy-order trap

**`Lead.Asset_Type__c`** (restricted; currently Retail, Land, Industrial, Office, Multifamily, Mixed-Use) → **add `Hospitality` and `Medical Office`.**

Two things the implementer must do, not one:

1. **Deploy order.** Values first, code second. Apex compiles against a picklist *regardless of its values*, so a code-first deploy is green and fails at runtime. (Fields are safer — Apex referencing a missing field will not compile.)
2. **Sweep before adding.** This repo's standing rule ("grep the repo + query the org before touching a picklist value") was written for removals but applies here too: confirm nothing constrains `Asset_Type__c` downstream — validation rules, flows, report filters, list-view filters, `Property__c` mapping.

That sweep is what surfaces the real problem:

> ⚠️ **`Property__c.Asset_Type__c` does NOT contain Hospitality or Medical Office** (verified: Retail, C-Store, Land, Industrial, Office, Multifamily, Storage, Mixed-Use). `LeadConvertService.buildProperty` copies the Lead's value **only if `allowedAssetTypes.contains(...)`** — so a Hospitality Lead converts with the asset type **silently dropped** onto the Property. No exception, no log.
>
> **Recommendation (C-12): add both values to `Property__c.Asset_Type__c` in the same change.** Two lines of metadata; keeps the pair aligned; costs nothing. The alternative — accepting the drop — is a data-quality bug that will be discovered months later by someone asking why the hotel deal has no asset type.

### 4.3 `Inbound_Email_Staging__c` — 3 new fields

| Field | Type | Purpose |
|---|---|---|
| `Extracted_JSON__c` | LongTextArea(131072), visibleLines 10 | D3 tier 1: the raw LLM response **verbatim** |
| `Routed_Record_Ids__c` | LongTextArea(32768), visibleLines 5 | §1.6: the full N-result audit, one line per property |
| `Property_Count__c` | Number(3,0) | §1.6: properties **found** (pre-truncation) |

`Outcome__c` — **no metadata change** (free Text 255). Update its `<description>` to add `'Not Acquisition (gated)'`, `'Not Acquisition (pre-filtered)'`, and the `'Multi-Property (N): …'` shape.

### 4.4 🔴 FLS — four permission sets, not one

Verified placement of the *sibling* deal-screening fields (§0.2). New fields must follow them or the people who work these Leads cannot see them, and **an admin tester will not notice** (profiles are `.forceignore`d; admins pass on profile FLS).

| Permission set | Fields | Access |
|---|---|---|
| `DPEG_Acquisition_View` | the 19 new Lead fields | readable ✅ / editable ❌ |
| `DPEG_Acquisition_Edit` | the 19 new Lead fields | readable ✅ / editable ✅ |
| `DPEG_Acquisitions` | the 19 new Lead fields | readable ✅ / editable ✅ (matches its siblings) |
| `Broker_Protection_Access` | the 19 new Lead fields **+ the 3 new staging fields** | readable ✅ / editable ✅ |

⚠️ **The pipeline itself is unaffected by FLS** — `EmailToLeadService` does a plain `insert` in system mode (`AccessLevel.USER_MODE` is deliberately not applied). FLS governs **human visibility and flexipage rendering only**. Say so, or someone will "fix" a non-existent write problem.

**UAT requirement:** acceptance-test as a **real acquisitions persona**, not as an administrator.

### 4.5 Lead record page — a "Deal Screening" section

`flexipages/Lead_Record_Page.flexipage-meta.xml` is **Dynamic Forms**: `Details` tab → `Lead Info` (2-col) + `Deal Intake` (2-col).

**Recommendation:** a **third `flexipage:fieldSection` labelled `Deal Screening`**, 2 columns, placed after `Deal Intake` inside `Facet-detailsTabContent`. Needs three new facets: `Facet-dealScreeningCol1`, `Facet-dealScreeningCol2`, `Facet-dealScreeningCols`.

- **Column 1 — the asset:** `Property_Name__c`, `Building_SF__c`, `Unit_Count__c`, `Year_Built__c`, `Year_Renovated__c`, `Lot_Size_Acres__c`, `Zoning__c`, `Seller_Entity__c`
- **Column 2 — the deal:** `Sale_Process__c`, `Offer_Due_Date__c`, `Guidance_Price_Low__c`, `Guidance_Price_High__c`, `NOI__c`, `Occupancy_Pct__c`, `WALT_Years__c`, `ADR__c`, `Deal_Room_Link__c`, `Listing_Broker_Name__c`, `Listing_Broker_Email__c`

Do **not** re-add `Asset_Type__c` / `Guidance_Price__c` / `Guidance_Cap_Rate__c` / `Deal_Notes__c` / `Parse_Confidence__c` — all already on `Deal Intake`.

⚠️ Known repo gotcha: **each `fieldInstance` needs its own `<itemInstances>` wrapper** (one item per component); batching them silently drops fields.

**Recommendation (C-21): flexipage only — do NOT add the 19 fields to the four `Lead-*.layout-meta.xml` files.** With Dynamic Forms the flexipage is authoritative for the record page, and touching four layouts is churn with a real chance of breaking the `platformActionList` (this repo has been bitten by activity-composer actions living in layout metadata).

### 4.6 Compact layout

`Lead_Highlights` currently holds 4 of a possible 10: `Guidance_Price__c`, `My_Cap_Rate__c`, `BP_Expiry__c`, `Days_in_System__c`.

**Recommendation (C-22): add `Offer_Due_Date__c` and `Asset_Type__c`** (→ 6 fields). A submission deadline in the highlights panel is the single highest-value addition — it is the field that makes a Lead *urgent*. Stop at 6; the panel truncates on narrow viewports.

### 4.7 List views

| List view | Status | Action |
|---|---|---|
| `Review_Queue` (`Parse_Confidence__c = LOW`) | ✅ **ALREADY EXISTS** | **No work.** D2's soft tier flows into it as-is. Consider adding `Property_Name__c` as a column. |
| 🆕 `Offers_Due_Soon` on **Lead** | new | **The `Offer_Due_Date__c` view the user called for.** Columns: LastName, Company, `Property_Address__c`, `Property_Name__c`, `Offer_Due_Date__c`, `Guidance_Price__c`, `Asset_Type__c`, Status. Filters: `Offer_Due_Date__c greaterOrEqual TODAY` **AND** `Offer_Due_Date__c lessOrEqual NEXT_N_DAYS:14` **AND** `Status notEqual Disqualified,Converted`. Sort `Offer_Due_Date__c` ASC. ⚠️ `<sortColumn>` element placement in ListView XML has broken deploys in this repo before — check it. |
| 🆕 `Gated_Not_Acquisition` on **Inbound_Email_Staging__c** | new | `Outcome__c startsWith 'Not Acquisition'`. Columns: Name, `From_Address__c`, `Subject__c`, `Outcome__c`, `Processed_DateTime__c`. **This is the only way anyone sees what the gate rejected** — without it the gate is unauditable. Small, and it is what makes the gate safe to trust. |

---

## ⚠️ §5 — RISK REGISTER

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| **R1** | 🔴 **Prompt-quality regression on the existing 4 fields.** The claim engine's two inputs (`broker_email`, `property_address`) come from a prompt being replaced wholesale. A subtly different address → a different `Property_Key__c` → a competing broker silently *wins*, or a repeat registers as a new claim. A broker-identity dilution → claims attributed to the **DPEG employee who forwarded the email**. **No exception, no error row, no failing test.** | 🔴 | (1) Keep the four legacy instructions **verbatim and FIRST**, in a delimited block, ahead of every new instruction — do not paraphrase. (2) **The §3.5 regression fixture set** — same `broker_email`, same `normalizeAddress(property_address)` for every historical staging row. (3) `MODEL` and `temperature=0` unchanged. (4) Prompt lives behind one constant + the parser accepts the legacy 4-key shape → **rollback is one line, no code change**. |
| **R2** | 🔴 **Response truncation → `JSONException` → email lands in `Error` with no Lead.** `MAX_TOKENS=512` is 4–8× too small and the degrade catch is `CalloutException`-only. | 🔴 | The four-part C-14 fix: `MAX_TOKENS` 4096, `response_format: json_object`, prompt-level caps, and **widen the degrade catch to `JSONException`** (documented reversal). |
| **R3** | 🟠 **Restricted-picklist deploy-order trap.** Apex compiles against a picklist regardless of its values → a code-first deploy is green and fails at runtime, rolling back the claim. | 🟠 | Metadata-first deploy order (§6) **plus** the runtime `Schema.describe` guard in the parser (§3.4). Belt and braces — either alone leaves a hole. |
| **R4** | 🟠 **`LeadConvertService` silently drops Hospitality / Medical Office.** Answering the user's question precisely: **18 of the 19 new fields are genuinely inert at conversion** — `buildProperty` reads a fixed field list, `stampConvertedOpportunities` reads only `Deal_Type__c`, and unmapped custom Lead fields are dropped by standard conversion anyway (which is what D4 defers). **`Asset_Type__c` is the exception**: it *is* mapped, and the `allowedAssetTypes.contains(...)` guard drops the two new values without error. | 🟠 | **C-12** — add both values to `Property__c.Asset_Type__c` too. |
| **R5** | 🟠 **Multi-property lock deadlock** (§1.2). Invisible today: `UNABLE_TO_LOCK_ROW` → `UNCLAIMED` → `System.debug` only. | 🟠 | Sorted cluster-key iteration + surface the fail-safe in `Outcome__c` (` [unclaimed: lock timeout]`). |
| **R6** | 🟠 **Governor ceiling.** SOQL is binding at ~14–24 properties. | 🟠 | `MAX_PROPERTIES = 10` + visible truncation + **`Limits.getQueries()` / `getDmlStatements()` headroom assertions in the tests** (§7) so a future change that adds a query per property fails a test instead of failing in production. |
| **R7** | 🟠 **Reply-thread ambiguity** once N Tasks share a `Thread_Key__c` (`ORDER BY CreatedDate DESC LIMIT 1`, identical CreatedDate). | 🟠 | `, Id DESC` + ascending-priority insertion (C-3). |
| **R8** | 🟢 ~~N Tasks with one Message-ID collide on a unique index~~ | 🟢 | **Cleared** — `Inbound_Message_Id__c` is `externalId` but **not unique** (§0.4). |
| **R9** | 🟠 **FLS granted on only one permission set** → invisible to the acquisitions personas and invisible to an admin tester. | 🟠 | Four permission sets (§4.4) + UAT as a real persona. |
| **R10** | 🟢 **Callout size / cost.** ~$0.0024/email, ~$36/month at 500/day; input is well inside the 128k context. | 🟢 | `TIMEOUT_MS` → 60000; clip the LLM input body to 40,000 chars (**C-15** — must be covered by the R1 fixtures because it touches the existing four fields). |
| **R11** | 🟢 **`Company` stops being a constant.** It becomes LLM-derived, and `Company` is a common Lead duplicate-rule / matching-rule key — and this module's history includes the `DUPLICATES_DETECTED` → Savepoint-rollback failure class. | 🟢 | Verified: **both** Lead duplicate rules are `isActive=false` in the repo. Keep `COMPANY_PLACEHOLDER` as the fallback (never blank — `Company` is required). Confirm rule status in `usman-dpeg` at deploy. |
| **R12** | 🟠 **The bulk-test exemption silently stops applying** and nobody notices, so the reshaped loop ships with single-property tests only. | 🟠 | **C-18** — narrow the exemption in `ARCHITECTURE.md` §2 **and** `.claude/rules/bulk-test-rule.md` in the same PR, and specify the replacement volume tests explicitly (§7). |
| **R13** | 🟢 `Extracted_JSON__c` at 131,072 chars is not filterable/indexable and renders as a blob. | 🟢 | It is an audit/queryable store, not a UI field — keep it off the record page. Mandatory `InboundEmailFieldUtil.clip(..., 131072)`; an over-long response would otherwise throw at DML. |

---

## 🧭 §6 — COMPLEXITY ROUTING & BUILD / DEPLOY ORDER

### Routing recommendation — stated explicitly, as requested

| Work | Agent | Why |
|---|---|---|
| **All metadata** — 19 Lead fields, 2+2 picklist values, 3 staging fields, FLS on 4 permission sets, the `Deal Screening` flexipage section, compact layout, 2 list views | 🔵 **`salesforce-admin`** | Routine declarative work. No multi-object schema design, no org-wide security model, no subflow architecture — none of `salesforce-solution-architect`'s triggers apply. |
| **All code** — prompt/JSON contract, `LLMExtractionParser`, the queueable restructure, lock ordering, gate, service changes, tests | ⚫ **`salesforce-technical-architect`** | Per `CLAUDE.md`'s routing guide this clears the "complex" bar several times over: it is an **external LLM integration contract redesign** at the §3.3 callout boundary; an **async pipeline restructure**; a **concurrency / pessimistic-locking** change (deadlock avoidance via lock ordering); and an explicit **governor-limit budgeting** exercise. It spans queueable → 5 services → 4 selectors. This is emphatically not "write an Apex service / build an LWC". |

Then: 🟡 `salesforce-unit-testing` → 🟣 `salesforce-code-review` → 🔴 `salesforce-devops` + 🔷 `salesforce-documentation` (parallel).

*Override available: "use admin not architect" / "use developer not architect".*

### Build / deploy order — metadata first, and why

1. **Decisions C-1 … C-22 confirmed.** *Gates everything.*
2. **🔵 Admin: create ALL metadata** (fields, picklist values, FLS, flexipage, compact layout, list views).
3. **🔴 Deploy metadata AND VERIFY IN ORG.** Not optional and not deferrable to the end:
   - `Lead.Asset_Type__c` and `Property__c.Asset_Type__c` both contain `Hospitality` + `Medical Office` (describe / `PicklistValueInfo`);
   - all 19 Lead fields + 3 staging fields exist;
   - FLS is visible **to a non-admin acquisitions persona**, not just to the deploying admin.
   > **Why metadata cannot follow code:** Apex referencing `Lead.Property_Name__c` will not compile until the field exists (safe — the deploy blocks). But Apex **compiles fine against a picklist whose values do not exist yet**, so a code-first deploy goes green and then throws at runtime on the first Hospitality email — rolling back a real claim. The compile checker protects the fields and not the values.
4. **⚫ Dev, in dependency order:** `LLMExtractionParser` + the DTOs → `LLMExtractionCalloutService` (prompt, `MAX_TOKENS`, `response_format`, typed return + `toLegacyMap`) → `EmailToLeadService` (`LeadRequest`) → `InboundEmailActivityService` (bulk Task) → `InboundEmailStagingService` (new stamps) → `TaskSelector` (`, Id DESC`) → `ExtractAddressQueueable` (the restructured tree) last, since it consumes all of the above.
5. **🟡 Tests**, including the §3.5 regression fixtures and the §7 volume tests. `RunLocalTests` green.
6. **🟣 Code review.**
7. **🔴 Deploy code + 🔷 docs** (parallel). Docs: `ARCHITECTURE.md` §1 (3 new staging fields), §2 (routing tree, the narrowed exemption, `LLMExtractionParser` in the services table), plus `docs/broker-protection-{architecture,data-dictionary,operations,faq,overview,limitations}.md` and a new dated feature doc.

---

## 🧪 §7 — TESTING (what replaces the 251 rule)

**The per-transaction-singleton exemption is narrowed to `LLMExtractionCalloutService` only** (still exactly one callout per job). It no longer covers `ExtractAddressQueueable.route`, `PropertyClaimService.claim`, or `EmailToLeadService.createLeadFromExtracted`, all of which are now invoked N times per transaction. **`ARCHITECTURE.md` §2 and `.claude/rules/bulk-test-rule.md` must be edited in the same PR** or the next reader will apply a stale exemption.

**A literal 251 remains both impossible and meaningless here**, and the reason must be recorded so code review does not demand it: `System.enqueueJob` caps at 50 per transaction (the existing `ExtractAddressQueueableTest` header already documents this), *and* 251 properties in one email would exhaust SOQL at ~14–24 (§1.5). Testing at a volume production cannot reach is the anti-pattern the exemption exists to prevent.

**Required replacements:**

1. **`MAX_PROPERTIES`-volume test** — one email carrying 10 properties; assert 10 correct routings, 10 lines in `Routed_Record_Ids__c`, and the correct `Multi-Property (10): …` summary.
2. **Truncation test** — 15 properties; assert exactly 10 routed, `Property_Count__c = 15`, ` [truncated: 10 of 15]` in the outcome, and the spillover note on `Deal_Notes__c`.
3. **🔴 Governor-headroom assertions** — after `Test.stopTest()`, assert `Limits.getQueries()` and `Limits.getDmlStatements()` at 10 properties are below a named budget. **This is the highest-value new test**: it makes any future change that adds a query per property fail here instead of in production at N=8.
4. **Mixed-outcome test** — one email producing WINNER + COMPETING + REPEAT; assert 1 Lead, the right submissions, one Task per *distinct* record, and the correct primary `Result_Record_Id__c`.
5. **Lock-ordering test** — the sort is a pure function: assert it directly, and assert end-to-end that `Routed_Record_Ids__c` comes back in cluster-key order for a scrambled input array. State plainly in the header that true concurrency is untestable in Apex and this is the achievable proxy.
6. **Reply tie-break test** — a reply into a thread anchored on 3 records resolves to the **WINNER's** record, deterministically.
7. **Gate tests** — hard gate (no Lead, no claim, Task still logged, JSON stored); soft gate (Lead created, `Parse_Confidence__c = LOW`, **claim still attempted**); pre-filter hit; LLM outage still creates.
8. **Parser unit tests** — one per validation rule in §3.4, including `"$7.1M"`, `"88"`→1988, SF→acres, an out-of-set `asset_type` coerced to null, a 300-char URL nulled (not clipped), and `Occupancy_Pct__c = 88.0` (which fails outright if C-10 is not applied).
9. **🔴 Regression fixtures** (§3.5) — same `broker_email` and same normalized address for every historical staging body.
10. **Backward-compat test** — a legacy 4-key response (no `properties` array) still routes correctly. This is what makes the rollback lever real rather than theoretical.
11. Existing `execute_replyThreadedAmong251PriorTasks_…` and `execute_manyConcurrentEmails_…` — **keep unchanged**; both remain valid.

---

## 🔵 ADMIN WORK (`salesforce-admin`)

- **19 new `Lead` custom fields** per §4.1 (note the two corrected precisions), each with `<description>` + inline help text, `required=false`, `trackFeedHistory=false`.
- **`Lead.Asset_Type__c`** — add restricted values `Hospitality`, `Medical Office`.
- **`Property__c.Asset_Type__c`** — add the same two values *(C-12)*.
- **3 new `Inbound_Email_Staging__c` fields** per §4.3; update `Outcome__c`'s `<description>`.
- **FLS on four permission sets** per §4.4: `DPEG_Acquisition_View` (read-only), `DPEG_Acquisition_Edit`, `DPEG_Acquisitions`, `Broker_Protection_Access` (+ the 3 staging fields).
- **`Lead_Record_Page.flexipage`** — new `Deal Screening` field section + 3 facets per §4.5 (one `<itemInstances>` per field).
- **`Lead_Highlights` compact layout** — add `Offer_Due_Date__c`, `Asset_Type__c`.
- **2 new list views** per §4.7 (`Offers_Due_Soon` on Lead, `Gated_Not_Acquisition` on staging). **Do not touch `Review_Queue` beyond an optional column.**
- **Pre-work sweep:** grep the repo and query the org for anything constraining `Asset_Type__c` (validation rules, flows, report/list-view filters) before adding values.

**Not in scope:** the four `Lead-*.layout-meta.xml` files (C-21); any new object; any validation rule; any new permission set; any `Outcome__c` picklist conversion.

## ⚫ DEVELOPMENT WORK (`salesforce-technical-architect`)

**New:** `LLMExtractionParser.cls` (+ test) — pure coercion/validation, never throws, returns typed values + notes. `LLMExtractionResult` / `PropertyExtraction` / `EmailToLeadService.LeadRequest` DTOs.

**Modified:**

| Class | Change |
|---|---|
| `LLMExtractionCalloutService` | New prompt (legacy 4-key block **verbatim and first**); `MAX_TOKENS` 512→4096; `TIMEOUT_MS` 30000→60000; `response_format: json_object`; input-body clip; typed return + `toLegacyMap(PropertyExtraction)`; legacy-shape tolerance. `MODEL`/`temperature` unchanged. |
| `ExtractAddressQueueable` | The restructured tree (§1.1): REPLY + pre-filter above the callout; `Extracted_JSON__c` written pre-routing; the tiered gate; the sorted, capped, de-duplicated per-property loop with per-property `try/catch`; outcome accumulation; bulk Task logging; new staging stamps. **Widen the degrade catch to `JSONException`** with a documented reversal note. New outcome constants. **Rewrite the class-header routing tree** — it is the module's primary documentation and every branch description changes. |
| `EmailToLeadService` | `LeadRequest` DTO + the 19 typed fields; `Company` fallback chain; **restate the "one email == one Lead" invariant**. `deleteLead` unchanged. |
| `InboundEmailActivityService` | Bulk `logInboundEmail(List<Id>, …)`; single-Id method becomes a wrapper. **Never set `Task.Type`.** |
| `InboundEmailStagingService` | Write `Extracted_JSON__c` (clipped); stamp `Routed_Record_Ids__c` / `Property_Count__c`; keep the fail-soft contract. |
| `TaskSelector` | `selectLatestByThreadOrMessageIds` → `ORDER BY CreatedDate DESC, Id DESC`. |
| `PropertyClaimService` / `PropertyMatchingService` | ⚠️ **Signatures unchanged.** Javadoc updates only, to record that `claim()` is now called N times per transaction and that ordered acquisition (not the class itself) is what prevents deadlock. |

---

## ❓ §8 — DECISIONS REQUIRED (C-series, new for this change)

Recommendation given for each; **please confirm or override.** 🔴 marks the ones that change scope, cost, or risk materially.

| # | Decision | Recommendation |
|---|---|---|
| **C-1** | Properties with no usable address when *others* in the same email do have one | **No Lead, no claim.** Preserved verbatim in `Extracted_JSON__c` and appended as an "Additional properties" block to the **first** Lead's `Deal_Notes__c`. Minting an unclaimable Lead per entry re-creates the Lead-table pollution removed on 2026-07-31. |
| **C-2** | Task logging shape | **One Task per DISTINCT routed record** (de-duped by Id), one bulk DML, shared Message-ID + Thread-Key. Verified safe (§0.4). One-per-email would leave a competing submission with no email behind it. |
| **C-3** | Reply tie-break with N Tasks per thread | `ORDER BY CreatedDate DESC, **Id DESC**` + insert ascending-priority (`NO-PROPERTY < REPEAT < COMPETING < WINNER`) so a reply lands on the deal we own. |
| **C-4** 🔴 | `MAX_PROPERTIES` and overflow | **10**, with visible truncation. Queueable chaining for 11+ explicitly **deferred** (feasible, no second callout needed, no cross-deadlock — but doubles the state machine for an unobserved case). |
| **C-5** 🔴 | Bulkify the claim engine? | **No.** Keep per-property `claim()`. Both bulk routes break a documented invariant (orphan-Lead ordering / registry-needs-Lead-Id) and would force re-deriving the unique-index backstop, orphan adoption, and the self-match guard. Payoff zero at N ≤ 10. |
| **C-6** | Reply + pre-filter skip the LLM callout entirely | **Yes** — a literal reading of D3 ("extraction survives for branches that create no Lead") would mandate a callout on every reply, the highest-volume branch. Branch (a) provably never reads `extracted`, so nothing is lost functionally. Store `{"skipped":"reply"}` so `Extracted_JSON__c` is never ambiguously empty. **Largest single cost lever — confirm.** |
| **C-7** | Deterministic pre-filter | **Yes**, envelope/header patterns only, static Apex constant (not CMDT), a hit is a recorded gate not a discard. **No subject-keyword filtering.** |
| **C-8** | Confidence shape | LLM returns a **number 0–1**; Apex derives HIGH/MEDIUM/LOW. Protects the *restricted* picklist and makes thresholds tunable without a prompt change. |
| **C-9** | Gate thresholds & does the soft tier still claim? | Hard gate at `is_acquisition_related=false AND confidence ≥ 0.85`; bands 0.85 / 0.60. **The soft tier DOES still claim** — an unclaimed real property costs a commission; a claimed junk address costs one deletable row. |
| **C-10** 🔴 | `Occupancy_Pct__c` precision | **Percent(5,2), not (3,2).** (3,2) caps at 9.99% and cannot store 88.00 — a spec defect that would ship as silent nulls. |
| **C-11** | `Guidance_Price_Low/High__c` precision | **Currency(18,2)** to match the existing `Guidance_Price__c`. |
| **C-12** 🔴 | Add Hospitality + Medical Office to **`Property__c.Asset_Type__c`** too | **Yes** — 2 lines. Otherwise `LeadConvertService` silently drops the asset type at conversion for exactly the two new values. |
| **C-13** 🔴 | FLS scope | **Four permission sets**, not just `Broker_Protection_Access` (§0.2/§4.4). Otherwise invisible to the acquisitions personas *and* invisible to an admin tester. |
| **C-14** 🔴 | Callout limits + widening the degrade catch | `MAX_TOKENS` **4096**, `response_format: json_object`, prompt-level caps, `TIMEOUT_MS` 60000, and **catch `JSONException` at the degrade point**. The last item **reverses a decision documented in the current class header** — flag it as deliberate, do not let a reviewer "restore" the old comment. |
| **C-15** | Clip the LLM input body to 40,000 chars | **Yes**, but it touches the existing four fields, so it ships **only** behind green §3.5 fixtures. |
| **C-16** | New staging fields beyond the spec's one | Add **`Routed_Record_Ids__c`** + **`Property_Count__c`**. `Result_Record_Id__c` is Text(18) and cannot express N; widening it breaks every existing consumer and the runbook. |
| **C-17** | Parser location | **New `LLMExtractionParser`**, not an extension of `InboundEmailFieldUtil` (different contract; keep the field-safety chokepoint small and obviously correct). |
| **C-18** 🔴 | Bulk-test exemption | **Narrow it to `LLMExtractionCalloutService` only**, and edit `ARCHITECTURE.md` §2 + `.claude/rules/bulk-test-rule.md` in the same PR. Replace the 251 mandate with the §7 volume + governor-headroom tests. |
| **C-19** 🔴 | Regression fixtures from live staging rows | **Yes — treat as mandatory.** Existing `Inbound_Email_Staging__c` rows are a free corpus (never deleted). Assert identical `broker_email` and identical `normalizeAddress(property_address)`. This is the only guard against R1. |
| **C-20** | List views | Build `Offers_Due_Soon` (Lead) + `Gated_Not_Acquisition` (staging). **`Review_Queue` already exists — do not rebuild it.** |
| **C-21** | Page layouts | **Flexipage only.** Do not add the 19 fields to the four `Lead-*.layout` files. |
| **C-22** | Compact layout | Add `Offer_Due_Date__c` + `Asset_Type__c` to `Lead_Highlights` (4 → 6 of 10). |

---

## 📝 §9 — PROMPTS FOR SPECIALIST AGENTS

*(Do not dispatch until Gate 1 confirmation and C-1 … C-22 are settled.)*

### 🔵 PROMPT FOR `salesforce-admin`

```
Broker Protection LLM field extraction — METADATA ONLY. Do NOT deploy; create/modify
metadata files only. API version 67.0. Read ARCHITECTURE.md §1 (naming) first, then
agent-output/design-requirements.md §4 and the C-series decisions.

BEFORE creating anything: sweep the repo AND ask devops to query the org for anything that
constrains Lead.Asset_Type__c or Property__c.Asset_Type__c (validation rules, flows, report
filters, list-view filters). Report findings before proceeding — this repo has a standing
rule about picklist sweeps.

1. objects/Lead/fields/ — 19 NEW custom fields exactly per design §4.1. Note two CORRECTED
   precisions vs the source spec: Occupancy_Pct__c is Percent(5,2) NOT (3,2) — (3,2) caps at
   9.99% and cannot hold 88.00; Guidance_Price_Low__c / Guidance_Price_High__c are
   Currency(18,2) to match the existing Guidance_Price__c. Every field needs a populated
   <description> AND inline help text (ARCHITECTURE §1 treats unset descriptions as a defect
   being paid down — do not add 19 more). required=false, trackFeedHistory=false.
   Unit_Count__c help text must say "Units, or hotel keys for hospitality".

2. objects/Lead/fields/Asset_Type__c.field-meta.xml — ADD restricted values
   'Hospitality' and 'Medical Office'. Keep restricted=true. Do not reorder or remove.

3. objects/Property__c/fields/Asset_Type__c.field-meta.xml — ADD THE SAME TWO VALUES.
   This is decision C-12 and it is NOT optional: LeadConvertService.buildProperty copies the
   Lead's asset type onto Property__c only if the value exists on Property__c's restricted
   picklist, so without this a Hospitality Lead converts with the asset type SILENTLY DROPPED.

4. objects/Inbound_Email_Staging__c/fields/ — 3 NEW fields:
   Extracted_JSON__c    LongTextArea(131072), visibleLines 10
   Routed_Record_Ids__c LongTextArea(32768),  visibleLines 5
   Property_Count__c    Number(3,0)
   Also update Outcome__c's <description> ONLY (it is free Text 255 — do NOT convert it to a
   picklist) to add 'Not Acquisition (gated)', 'Not Acquisition (pre-filtered)', and the
   'Multi-Property (N): ...' summary shape.

5. FLS — FOUR permission sets, not one. This is decision C-13 and the source spec understates
   it. The 19 new Lead fields go into ALL of:
     DPEG_Acquisition_View   (readable=true, editable=false)
     DPEG_Acquisition_Edit   (readable=true, editable=true)
     DPEG_Acquisitions       (readable=true, editable=true)
     Broker_Protection_Access(readable=true, editable=true)
   The 3 new Inbound_Email_Staging__c fields go into Broker_Protection_Access ONLY.
   Reason: the SIBLING deal-screening Lead fields (Asset_Type__c, Guidance_Price__c,
   Guidance_Cap_Rate__c, Deal_Notes__c, Deal_Type__c, Parse_Confidence__c) live in the three
   DPEG_Acquisition* sets, NOT in Broker_Protection_Access. Granting only Broker_Protection_Access
   would leave the people who actually work these Leads unable to see the fields — and profiles
   are .forceignore'd, so an ADMIN TEST WOULD NOT REVEAL IT.

6. flexipages/Lead_Record_Page.flexipage-meta.xml — add a THIRD flexipage:fieldSection
   labelled 'Deal Screening', 2 columns, placed AFTER the existing 'Deal Intake' section
   inside Facet-detailsTabContent. Create Facet-dealScreeningCol1 / Col2 / Cols.
   Field split is in design §4.5. Do NOT re-add Asset_Type__c, Guidance_Price__c,
   Guidance_Cap_Rate__c, Deal_Notes__c or Parse_Confidence__c — already on 'Deal Intake'.
   ⚠ Each fieldInstance needs its OWN <itemInstances> wrapper (one item per component);
   batching them silently drops fields in this repo.

7. objects/Lead/compactLayouts/Lead_Highlights — add Offer_Due_Date__c and Asset_Type__c
   (4 -> 6 fields).

8. TWO new list views per design §4.7:
   objects/Lead/listViews/Offers_Due_Soon
   objects/Inbound_Email_Staging__c/listViews/Gated_Not_Acquisition
   ⚠ <sortColumn> element placement in ListView XML has broken deploys in this repo — verify it.
   Do NOT create a "low confidence review" list view: objects/Lead/listViews/Review_Queue
   ALREADY EXISTS and already filters Parse_Confidence__c = LOW.

DO NOT: touch any Lead-*.layout-meta.xml (decision C-21 — the record page uses Dynamic Forms);
create objects, validation rules, or permission sets; convert Outcome__c to a picklist;
change any existing field's type or precision.
```

### ⚫ PROMPT FOR `salesforce-technical-architect`

```
Implement the Broker Protection LLM field-extraction enrichment.

READ FIRST, IN THIS ORDER:
  1. agent-output/llm-field-extraction-spec-2026-07-31.md (D1-D4 are FINAL)
  2. agent-output/design-requirements.md — ALL of it; §0 (premise corrections), §1 (multi-
     property), §2 (gate), §3 (JSON contract + parser), §5 (risks), §7 (testing)
  3. ARCHITECTURE.md §1, §2 (Broker Protection services + staging model + the async-pipeline
     exemption), §3.3 (the direct-OpenAI exception)
  4. .claude/rules/apex-layering-rule.md and .claude/rules/bulk-test-rule.md

PRECONDITION — do not start until the admin metadata is DEPLOYED AND VERIFIED IN THE ORG.
Apex compiles against a picklist regardless of its values, so a code-first deploy goes green
and then throws INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST at runtime, rolling back a real claim.

⚠ THE SINGLE BIGGEST RISK IS NOT THE NEW FIELDS. The routing tree's arbitration depends on
exactly two extracted values, broker_email and property_address. Rewriting the prompt is a
silent behaviour change to the first-broker-wins claim engine. Therefore:
  - keep the four legacy instructions VERBATIM AND FIRST in the new prompt, in a delimited
    block, ahead of every new instruction. Do NOT paraphrase them.
  - MODEL ('gpt-4o-mini') and temperature (0) do NOT change.
  - build the regression fixture set from existing Inbound_Email_Staging__c raw bodies and
    assert the new prompt returns the SAME broker_email and the SAME
    PropertyMatchingService.normalizeAddress(property_address) for every one. Not "similar" —
    the same normalized key, because that key IS the claim identity.
  - keep the prompt behind ONE constant and make the parser accept the legacy 4-key shape
    (no `properties` array -> synthesize a one-element array), so rollback is one line.

APPROVED DESIGN DECISIONS (do not re-litigate — see the C-series for the full reasoning):
  C-2/C-3  ONE Task per DISTINCT routed record, one bulk DML, ascending priority
           (NO-PROPERTY < REPEAT < COMPETING < WINNER); TaskSelector gets ", Id DESC".
           Inbound_Message_Id__c is externalId but NOT unique — verified, N rows are fine.
  C-4      MAX_PROPERTIES = 10, named constant. Overflow truncates VISIBLY (Property_Count__c
           vs Routed_Record_Ids__c line count, ' [truncated: X of M]' suffix, spillover note
           on Deal_Notes__c). Queueable chaining is DEFERRED, not rejected.
  C-5      DO NOT bulkify the claim engine. Keep per-property claim(). PropertyClaimService
           and PropertyMatchingService SIGNATURES ARE UNCHANGED — Javadoc updates only.
  C-6      REPLY detection and the deterministic pre-filter run BEFORE the LLM callout.
           Branch (a) provably never reads `extracted`, so this is behaviour-preserving.
  C-8/C-9  confidence is a NUMBER 0-1 from the model; Apex derives HIGH/MEDIUM/LOW
           (0.85 / 0.60). Hard gate only at is_acquisition_related=false AND conf >= 0.85.
           The SOFT tier still creates AND STILL CLAIMS.
  C-14     MAX_TOKENS 512 -> 4096; add "response_format": {"type":"json_object"};
           TIMEOUT_MS -> 60000; and WIDEN THE DEGRADE CATCH TO JSONException. That last item
           REVERSES a decision documented in ExtractAddressQueueable's current header — mark
           it explicitly as a deliberate reversal with its reasoning so nobody "restores" the
           old comment. With an 8x larger response, a truncated reply is an absent optional
           input, not a defect in our own contract; erroring loses the email.
  C-17     NEW class LLMExtractionParser. Do NOT extend InboundEmailFieldUtil — parser =
           coercion, util = field safety. The util stays the last step before DML.

🔴 THE LOCK-ORDERING REQUIREMENT IS LOAD-BEARING AND IS NOT OPTIONAL.
claim() takes a FOR UPDATE lock per property and Apex holds row locks until commit, so a
queueable claiming N properties holds N locks. Two concurrent multi-property emails sharing
two properties are an AB-BA deadlock. Salesforce does not report deadlocks — it reports
UNABLE_TO_LOCK_ROW, which acquireClusterLock already swallows into ClaimOutcome.UNCLAIMED with
only a System.debug, so broker protection would SILENTLY FAIL on exactly the blast emails D1
exists for. FIX: process properties in ascending deriveClusterKey order (ties by normalized
address), derived ONLY from the address and never from the LLM's array order. De-duplicate on
NORMALIZED ADDRESS, never on cluster key (two different buildings can share a coarse key, and
re-locking the same row in one transaction is a no-op). Do NOT hoist all locks up front —
sorted lazy acquisition removes the cycle at zero extra hold time. Surface a fail-safe as
' [unclaimed: lock timeout]' on the staging Outcome so it stops being invisible.

Per-property try/catch + continue for isolation. Do NOT introduce a Savepoint — there is
deliberately none in this module and PropertyClaimService.isLostRaceAgainst's Javadoc depends
on that.

FILES — new: LLMExtractionParser.cls (+ DTOs LLMExtractionResult / PropertyExtraction /
EmailToLeadService.LeadRequest). Modified: LLMExtractionCalloutService, ExtractAddressQueueable,
EmailToLeadService, InboundEmailActivityService, InboundEmailStagingService, TaskSelector,
plus Javadoc-only updates to PropertyClaimService and PropertyMatchingService.

REWRITE ExtractAddressQueueable's class-header routing tree. It is the module's primary
documentation and every branch description changes. Restate EmailToLeadService's
"one inbound email == at most one Lead" invariant as "one PROPERTY == at most one Lead".
Never set Task.Type (it does not exist in this org, compiles anyway, throws at runtime).

TESTS — the per-transaction-singleton exemption now covers LLMExtractionCalloutService ONLY.
A literal 251 is impossible (enqueueJob caps at 50) AND meaningless (SOQL exhausts at ~14-24
properties) — record that reasoning in the test header. Write the 11 items in design §7,
including the governor-headroom assertions (Limits.getQueries/getDmlStatements after
Test.stopTest at 10 properties, against a named budget) and the regression fixtures.
Update ARCHITECTURE.md §2 AND .claude/rules/bulk-test-rule.md to narrow the exemption IN THE
SAME CHANGE, or the next reader will apply a stale one.

Do not deploy.
```

---

## ✅ SUMMARY FOR GATE 1

| | |
|---|---|
| **The spec is implementable in full.** D1–D4 are respected exactly as decided; nothing is dropped and nothing is expanded beyond what the spec asked for. | ✅ |
| **🔴 The real risk is not the 19 fields — it is that rewriting the prompt silently changes the claim engine.** `broker_email` and `property_address` are the arbitration inputs. A drifted address produces a different `Property_Key__c` and a competing broker quietly *wins*. No error, no failing test. Mitigated by keeping the legacy instructions verbatim-and-first + a regression fixture set built from the staging rows we already have (**C-19**). | 🔴 |
| **🔴 The multi-property loop can DEADLOCK, invisibly.** N properties = N `FOR UPDATE` locks held to commit; two overlapping blasts are an AB-BA cycle; the existing code swallows the timeout into `UNCLAIMED` with a `System.debug`. **Fix: process properties in sorted cluster-key order** — zero cost, no new API. | 🔴 |
| **🔴 `MAX_TOKENS` is 512 and the degrade catch is `CalloutException`-only.** A truncated response throws `JSONException` and lands the email in `Error` with **no Lead** — worse than today. Needs 4096 + JSON mode + a widened catch (**C-14**, which deliberately reverses a documented decision). | 🔴 |
| **🔴 "Nothing breaks at conversion" is NOT the correct answer.** 18 of 19 fields are genuinely inert, but `LeadConvertService` **silently drops** Hospitality / Medical Office because `Property__c.Asset_Type__c` lacks them. Two lines of metadata fix it (**C-12**). | 🔴 |
| **🔴 FLS on one permission set is not enough.** The sibling deal-screening fields live in three `DPEG_Acquisition*` sets. Granting only `Broker_Protection_Access` hides the fields from the people who work the Leads — and an admin test would not reveal it (**C-13**). | 🔴 |
| **Premise correction: the low-confidence review queue already exists.** `Review_Queue` already filters `Parse_Confidence__c = LOW`. D2's soft tier needs zero new metadata. | ✅ |
| **Realistic ceiling for N is ~14–24 properties (SOQL-bound). Recommend a cap of 10** with visible truncation; chaining deferred. Governor-headroom assertions in the tests are the durable guard (**C-4**). | ⚠️ |
| **Two spec precision defects found:** `Occupancy_Pct__c` at Percent(3,2) caps at **9.99%** and cannot store 88.00 (**C-10**); price low/high should be Currency(18,2) to match the existing sibling (**C-11**). | ⚠️ |
| **The bulk-test exemption stops applying** to the reshaped classes (the queueable now loops; `claim()` is called N times). Narrow it to `LLMExtractionCalloutService` and replace 251 with volume + governor tests, editing `ARCHITECTURE.md` and the rule file in the same PR (**C-18**). | ⚠️ |
| **Recommended: a deterministic noreply/mailer-daemon pre-filter that skips the LLM entirely** — highest-precision, highest-volume junk class, and it is the exact fix for the two Gmail forwarding-confirmation Leads. Envelope/headers only; **no subject keywords** (**C-7**). | ✅ |
| **Routing: 🔵 `salesforce-admin` for ALL metadata; ⚫ `salesforce-technical-architect` for ALL code** (LLM integration contract + async pipeline restructure + concurrency/lock ordering + governor budgeting). Metadata deploys and is **verified in org** before any Apex. | ➡️ |
| **22 decisions need confirmation (C-1 … C-22); 8 are marked 🔴** as materially affecting scope, cost, or risk. The one I would most want an explicit answer on is **C-6** (letting Reply and pre-filter skip the LLM callout) — it is the largest cost lever and is the only place I read D3 more loosely than its literal wording. | ❓ |
