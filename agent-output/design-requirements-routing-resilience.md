# Design Requirements — Broker Protection **Routing Resilience**, LLM-Outage Claim Gap, and Pipeline Observability

**Module:** Broker Protection (inbound email-to-Lead pipeline)
**Date:** 2026-08-08
**Status:** 🚦 **GATE 1 — NOT BUILD-READY.** Two blocking spikes (SP-R1, SP-R2) and eleven open
decisions. Nothing below should be built until those are closed.
**Pattern followed:** `agent-output/design-requirements-attachment-persistence-v2.md` +
`agent-output/spike-attachment-persistence-v2.md` (the file pipeline solved the same class of
problem; this document deliberately reuses its shape, its vocabulary, and where possible its
machinery).
**Conformance:** `ARCHITECTURE.md` §1 (naming), §2 (layering, `WITH SYSTEM_MODE` automation path),
`.claude/rules/apex-layering-rule.md`, `.claude/rules/bulk-test-rule.md`,
`.claude/rules/content-publication-rule.md`.

> **THE ONE-LINE BRIEF.** The file transaction was made recoverable by giving it a Finalizer, a
> status field, a work queue and a sweeper. The **routing** transaction — which owns the Lead and
> the registry claim — has none of those, so its uncatchable death is invisible and permanent.
> This design gives routing the same four things. It does **not** invent a parallel mechanism; it
> applies the one that already works, and it derives the retry-safety rule from a fact the
> existing spike already measured.

> **THE FOUR THINGS THIS DOCUMENT ESTABLISHES THAT ARE NOT OBVIOUS**
> **(1)** The replay-safety line is not a judgement call — **`ParentJobResult.UNHANDLED_EXCEPTION`
> is a *proof* that nothing committed** (SP-5 measured it in this org), whereas `Status__c = 'Error'`
> is a proof that the catch ran and therefore that work *may* have committed. Retry the first,
> never the second. §3.3.
> **(2)** Moving a stranded row off `Status__c = 'Pending'` **silently breaks the file sweeper** —
> `AttachmentCarrierSweepBatch` skips `'Pending'` rows precisely because routing has not finished,
> and a new `'Failed'` value would let it convert and stamp `Saved` with **no routed targets**,
> permanently losing the links. §3.6.
> **(3)** The ordinary retry path **cannot fix the LLM-outage claim gap**, because an LLM-down email
> is a *successful* run by every existing measure (it logs its Task, so the Message-ID guard
> short-circuits any replay). That gap needs its own answer. §4.
> **(4)** A deterministic address regex is **not** a smaller version of the LLM — the highest-yield
> street address in a CRE broker email is the **broker's own office address in the signature
> block**, and a claim on it is irrevocable (`PropertyClaimService`'s own header forbids the third
> registry DML that a "provisional claim" would need). §4.3.

---

## 0. WHAT WAS REQUESTED

> Make the Broker Protection **routing** transaction as resilient as its **file** transaction
> already is, and close the outbound-attachment gap.

| # | Ask | Section | Verdict |
| --- | --- | --- | --- |
| 1 | Routing resilience: a Finalizer + a retry path; work out which failure states are safely replayable | §3 | Designed, 2 blocking spikes |
| 2 | An LLM outage silently disables first-broker-wins; propose a deterministic address fallback and assess honestly whether a wrong key beats no key | §4 | Designed; the regex option is **recommended against**, with a cheap falsifying spike offered |
| 3 | Minimum durable signal for the silent paths, declarative if possible | §5 | Designed; 5 list views, 0 Apex, one honest limitation |
| 4 | Outbound capture via BCC; assess whether branch (a) already does the right thing | §6 | **Its own cycle.** Branch (a) already handles replies correctly and for free; new outbound threads are actively dangerous; a naive guard would break the legitimate paste-forward path |

**Explicitly out of scope and not re-opened:** the LLM prompt and every fixture pin, the extraction
contract, branch logic inside the per-property loop, the claim/arbitration engine's decisions, the
Task-logging contract, `LeadConvertService` / `LeadConvertTrigger`, the EAC guard/adopter's delete
and adopt predicates, and the attachment classification rules.

---

## 1. VERIFIED BASELINE — read this before proposing anything

Confirmed by reading the working tree on 2026-08-08. Nothing here is assumed.

### 1.1 The asymmetry, restated precisely from the code

| | **File** transaction | **Routing** transaction |
| --- | --- | --- |
| Class | `AttachmentPersistQueueable` | `ExtractAddressQueueable` |
| Owns | files only — and under the carrier model, not even those | **the Lead, the `Property_Registry__c` claim, the `Competing_Broker_Submission__c` row, the Task** |
| Failure reporter | ✅ `AttachmentPersistFinalizer`, attached as the **first statement** of `execute()` | ❌ **none** |
| Durable state field | ✅ `Attachment_Status__c` (7-value restricted picklist) | `Status__c` — but only three values, and **the uncatchable-death case writes none of them** |
| Work queue | ✅ `InboundEmailStagingSelector.queryCarrierSweep()`, `WITH SYSTEM_MODE` | ❌ none |
| Retry engine | ✅ `AttachmentCarrierSweepBatch` (+ `AttachmentCarrierSweepSchedule`) | ❌ none |
| Defined exits | ✅ four — CONVERTED / RELEASED / RETRIED / EXPIRED | ❌ two (Processed, Error) plus **one undefined** (stranded `Pending`) |
| Evidence on failure | status + `Dropped_Attachment_Notes__c` note + `AsyncApexJob` | **a failed `AsyncApexJob`, and nothing else** |

🔴 **And `AttachmentCarrierSweepBatch` explicitly refuses to touch a stranded routing row** —
`ROUTING_STATUS_PENDING.equals(row.Status__c)` → `skipped++` → `continue`. The user's premise is
correct and is in the code. Worse than "it does not retry routing": a stranded row **with no
attachment** carries `Attachment_Status__c = 'None'`, which is not in the sweep's work queue at
all, so it is not merely skipped — it is never selected.

### 1.2 🔴 THE FAILURE TAXONOMY — the table this whole design turns on

Derived by tracing `ExtractAddressQueueable.execute()` line by line. "catch runs?" means
`execute()`'s own `catch (Exception e)` at line 765.

| # | Failure | catch runs? | Committed by this transaction | Staging row afterwards | Visible today? | Replayable? |
| --- | --- | --- | --- | --- | --- | --- |
| **F1** | Uncatchable platform failure *inside* the try — heap/CPU `LimitException`, `System.UnexpectedException` | **NO** | 🔴 **NOTHING** — total rollback | `Pending`, `Outcome__c` null, `Error__c` null | only a failed `AsyncApexJob` | ✅ **YES, cleanly** |
| **F2** | Failure *before* the try — `InboundEmailStagingService.getStaging(...)` throws. It is line 673, **outside** the try, and `InboundEmailStagingSelector.selectById` is `WITH USER_MODE`, which **throws rather than degrades** on any FLS gap | **NO** | **NOTHING** | `Pending`, everything null | failed `AsyncApexJob` | ✅ yes, but it will fail identically — deterministic |
| **F3** | Ordinary exception caught at line 765 | YES | whatever committed before the throw | `Error` + full `Error__c` | ✅ already visible | ⚠ **CONDITIONAL** — see §3.3 |
| **F4** | Per-property failure isolated by the loop catch (line 1004) | YES | the other properties' work; `finish()` still runs | `Error` + partial outcomes + Task logged | ✅ visible | ⚠ replay is a **no-op** (Message-ID guard) |
| **F5** | `InboundEmailStagingService.stamp()`'s own DML fails — it **swallows `DmlException` by design** | n/a | 🔴 **EVERYTHING**, including the Task | `Pending` — **indistinguishable from F1** | ❌ invisible | replay is a safe **no-op** *iff* `Message_Id__c` is non-blank |
| **F6** | The job never ran at all (async backlog, platform drop) | — | nothing | `Pending` | ❌ nothing, not even an `AsyncApexJob` failure | ✅ yes |

**Three consequences that shape everything below.**

1. **F1/F2/F6 are the target.** They are the only states with *zero* committed work, which is
   exactly what makes them replayable — and they are the only states with no durable record.
2. **A stranded `Pending` row is ambiguous** — it is F1, F2, F5 or F6, and the row cannot tell you
   which. A Finalizer resolves that ambiguity for F1/F2 **by construction** (it only fires on
   `UNHANDLED_EXCEPTION`), which is the single strongest argument for using one.
3. **F5 is a false alarm that must not be "fixed".** `stamp()`'s swallow is deliberate and correct
   (its Javadoc: a status-stamp failure must not misreport a successful claim as an async failure).
   The retry design must simply be safe in its presence.

### 1.3 The measured facts already in hand — treat as given, do not re-litigate

| # | Fact | Source | Consequence here |
| --- | --- | --- | --- |
| **R1** | An unhandled exception in a Queueable rolls back **that queueable's own DML** — a marker `Task` insert and a `Lead` update both vanished; an earlier transaction's Lead, Task and `Pending` staging row survived byte-for-byte | **SP-5**, `usman-dpeg` | 🔴 This *is* the replay-safety proof. `UNHANDLED_EXCEPTION` ⟹ nothing committed ⟹ replay is a first run |
| **R2** | A Finalizer fires on `UNHANDLED_EXCEPTION` in test **and** production, and **its own DML commits durably in a fresh transaction after the parent's rollback** | SP-3 | The only mechanism that can make a routing death durable |
| **R3** | `ctx.getException().getTypeName()` reports **`System.AsyncException`**, not the real type — the platform wraps it, preserving type and message only as *text* | SP-3 | Any classification of the failure must be a **message substring**, never a type check |
| **R4** | A **Finalizer's** `System.enqueueJob` is accepted *and executes to completion* in production; inside `@isTest` it is accepted but **never runs** | SP-2 Q3 | A Finalizer-initiated retry is viable but structurally untestable in Apex |
| **R5** | A Queueable's own direct chain throws `System.AsyncException: Maximum stack depth has been reached` inside `@isTest`, **catchably** | SP-2 Q1 | Already handled by `ExtractAddressQueueable`'s `Test.isRunningTest()` seam; any new chain needs the same |
| **R6** | An unhandled exception from a Queueable running at `Test.stopTest()` **propagates out of `stopTest()`** | SP-3 | Every new Finalizer test must wrap `Test.stopTest()` in try/catch or report a false failure |

### 1.4 The governor budgets this change must not move

Every one is currently asserted. Any proposal that changes a number here must say so explicitly.

| Budget | Value | Where | Assertion type |
| --- | --- | --- | --- |
| N=1 SOQL | **30** | `ExtractAddressQueueableTest.cls:2672`, `:3474` | ceiling (`<=`) |
| N=1 DML | **20** | `:2673`, `:3475` | ceiling (`<=`) |
| N=1 DML (tight) | **7** | `:3690` | ceiling (`<=`) |
| N=10 SOQL | **120** | `:1206` | ceiling (`<=`) |
| N=10 DML | **43** | `:1214` | 🔴 **EQUALITY** — `Assert.areEqual`. Any DML added to `execute()` fails this test, which is the point |

✅ **This design adds ZERO SOQL and ZERO DML to `ExtractAddressQueueable.execute()`.** All five
numbers are unchanged, and §8 states why.

### 1.5 Documentation defects found while reading — fix in the same PR

1. `ExtractAddressQueueable`'s class header (ATTACHMENT HANDOFF section) states
   *"`singlePropertyDmlBudget` 8 -> 7 and `DML_BUDGET` 44 -> 43"*. The test class carries **three**
   single-property DML literals — `20` (×2) and `7` (×1) — so the header describes one of the three
   as if it were the only one. Correct the header to name all three, or the next reader will
   "verify" against a number that is not the one their test uses.
2. `ARCHITECTURE.md` §2's `WITH SYSTEM_MODE` table is authoritative-by-header, not by table, and
   already says so — but it will need the new selector method added (§11.4) per §6 of that
   document.

---

## 2. WHAT DOES *NOT* CHANGE

Stated up front so the change stays as small as the problem allows.

- **The routing tree, every branch predicate, the ordering, the cluster-key sort and the deadlock
  fix.** Untouched.
- **`PropertyClaimService`, `PropertyMatchingService`, `EmailToLeadService`,
  `InboundEmailActivityService`, `LLMExtractionCalloutService`, `InboundEmailFieldUtil`,
  `InboundEmailAttachmentService`, `AttachmentPersistQueueable`, `AttachmentPersistFinalizer`.**
  Not modified. (`AttachmentCarrierSweepBatch` *is* modified — one predicate, §3.6.)
- **The prompt, `LEGACY_EXTRACTION_RULES`, `LEGACY_RESPONSE_FORMAT`, and every regression fixture.**
  Untouched. The one-line rollback lever still works.
- **`InboundEmailStagingSelector.selectById`'s field set.** 🔴 Deliberately not widened — its own
  Javadoc warns that adding a new custom field there makes *every inbound email* depend on that
  field's FLS, because it is `WITH USER_MODE` and on the critical path. §3.5 explains how the
  retry cap is enforced without touching it.
- **`stamp()`'s fail-soft swallow.** Correct as written; §1.2 F5 explains why.
- **The two existing list views** (`Gated_Not_Acquisition`, `Gated_Call_For_Offers`) and the
  `Outcome__c` prefix contracts they depend on.
- **`Property_Registry__c` DML.** Still exactly two statements in the codebase. `PropertyClaimService`'s
  header prohibits a third; §4.3 shows why that prohibition kills the obvious "provisional claim"
  design.

---

## 3. DELIVERABLE 1 — ROUTING RESILIENCE

### 3.1 The shape

```
EmailToLeadHandler                 owns THE EMAIL      (sync; unchanged)
  └─ ExtractAddressQueueable       owns THE LEAD + THE CLAIM
       ├─ System.attachFinalizer(new RoutingFailureFinalizer(stagingId))   ← NEW, FIRST STATEMENT
       ├─ … routing tree … (unchanged)
       └─ AttachmentPersistQueueable   owns only FILES   (unchanged)

  RoutingFailureFinalizer        ← NEW. Fires ONLY on UNHANDLED_EXCEPTION.
     stamps Status__c = 'Failed', increments Routing_Attempt_Count__c,
     appends the wrapped message + AsyncApexJob Id to Error__c. Records; does not retry.

  RoutingRetrySweepBatch         ← NEW. Work queue = Status__c = 'Failed'.
  RoutingRetrySweepSchedule      ← NEW. Hourly.
     Re-enqueues ExtractAddressQueueable for rows under the attempt cap and under the age cap.
```

Four defined exits for a routing row, mirroring the carrier's four:

| Exit | Written by | Meaning |
| --- | --- | --- |
| **PROCESSED** | `markRouted` / `markSkipped` | terminal, success |
| **ERROR** | `markRouted` with `errorText` | terminal, **human queue** — work may have committed, so it is never auto-retried |
| **FAILED** | `RoutingFailureFinalizer` | 🔴 nothing committed → **RETRIED** by the sweeper |
| **ABANDONED** | `RoutingRetrySweepBatch` at the attempt or age cap | terminal; stamps `Error` with a note naming the cap |

### 3.2 Why a Finalizer, and why it is the *only* mechanism

R2 measured it: a Finalizer fires on `UNHANDLED_EXCEPTION` and its DML commits durably **after the
parent's rollback**. Nothing else can write a record of a transaction that rolled itself back. This
is the same reasoning `AttachmentPersistFinalizer`'s header carries, and — importantly — the same
reasoning `EmailCaptureQueueable`'s header uses to justify *not* having one. Those two classes made
opposite decisions correctly; `ExtractAddressQueueable` belongs unambiguously with the first,
because its failure destroys the only record of itself and its work is **not** convergent.

🔴 **`System.attachFinalizer` must be the FIRST statement of `execute()`, above the
`getStaging(...)` call** — which currently sits outside the try block. That placement is what makes
**F2 reportable at all**. Today an FLS gap on one field of `selectById` kills the job before any
code that could record it runs.

⚠ **The Finalizer must classify by MESSAGE SUBSTRING, never by exception type** (R3). Reuse the
shape of `AttachmentPersistFinalizer.isPublicationLimitFailure` — a pure static, unit-testable at
zero cost — for whatever classification is wanted (heap vs CPU vs other). If no classification is
wanted, record the raw message and skip the predicate entirely.

### 3.3 🔴 WHICH FAILURE STATES ARE SAFELY REPLAYABLE — the exact answer

**The rule, in one sentence: retry `Failed`, never `Error`, and treat stale `Pending` as a separate
and more conservative question.**

**Why `Failed` is provably safe.** `ParentJobResult.UNHANDLED_EXCEPTION` can only occur on a
transaction that rolled back (R1/SP-5, measured in this org: the failing queueable's own insert
*and* its own update both vanished). So a `Failed` row has **no Lead, no registry row, no
submission, no Task and no staging stamp** from that attempt. A replay is byte-for-byte a first
run. `Failed` is therefore not a label — **it is the proof**.

**Why `Error` is not safe.** `Status__c = 'Error'` means `execute()`'s catch ran, which means the
transaction *committed*. Walking the branches:

| What committed before the throw | What a blind replay does | Verdict |
| --- | --- | --- |
| `finish()` reached `logInboundEmail` (every F4, and any F3 thrown after it) | guard 2 `isAlreadyLogged(Message_Id__c)` → `markSkipped` → total no-op | harmless, but pointless |
| Lead **and** claim committed, Task not logged | branch (b) REPEAT — `findBrokerSubmission` matches the winning submission on broker email + normalized `Property_Address_Raw__c` — files on the broker's own Lead, appends **one spurious audit row** | tolerable, still wrong |
| Registry committed, winning submission **not** (the loop catch can swallow a `DmlException` between the two inserts in `registerWinner`) | branch (b) misses → branch (d) → **the winning broker is filed as a COMPETING submission against their own Lead** | 🔴 corrupts the adjudication trail |
| Lead committed, claim returned `UNCLAIMED` (lock timeout) | branch (e) → **a SECOND Lead, which takes the claim; the first Lead is orphaned and unclaimed** | 🔴 duplicate Lead |

The last two are why `Error` is a **human queue, not a retry queue**. A future change could make it
retryable by having `markRouted` record *what committed* in a machine-readable form; that is a
larger change and is deliberately not proposed here.

**Stale `Pending` (F5/F6).** Ambiguous by construction, and the Finalizer does not cover it — F6
produces no exception at all. It is *conditionally* safe:

- **F5** (everything committed, only the stamp failed) → guard 2 catches it **iff `Message_Id__c` is
  non-blank**. The pipeline explicitly tolerates a blank Message-ID ("some forwarding paths strip
  the header, and refusing those emails would be far worse"), so blank rows exist.
- 🔴 **Therefore any stale-`Pending` sweep MUST skip rows with a blank `Message_Id__c`** and leave
  them for a human. That single filter is what makes the second queue safe.
- Cosmetic residual, stated: an F5 row that is re-run stamps `Outcome__c = 'Duplicate Delivery
  (skipped)'`, which is a slightly wrong label for "we re-ran a row that was already complete".
  Decision **D6**.

### 3.4 Why the Finalizer RECORDS but does not RETRY (recommended)

R4 measured that a Finalizer's enqueue works in production. It is nonetheless the wrong place for
the retry:

1. **An uncatchable failure is usually deterministic, not transient.** Heap and CPU depend on the
   email's own size and shape, so an immediate re-run of the identical input fails identically —
   and burns a real LLM callout doing it.
2. **It would be untestable.** R4 also measured that a Finalizer's enqueue is accepted but *never
   executes* inside `@isTest`. That is a second untestable seam in a module that already carries
   two (`lastRunEnqueuedTargets`, `AdoptionWriter`) and documents both as costs.
3. **Two retry mechanisms cannot share one cap.** The attempt counter would be incremented in one
   place and consulted in two.

**Recommendation:** record-only Finalizer + an **hourly** sweeper. Hourly rather than daily because
a claim is time-ordered and latency is not free (§4.2). Decision **D3** if the user wants the
immediate retry as well.

### 3.5 How the attempt cap is enforced without touching the critical path

🔴 **Do not add `Routing_Attempt_Count__c` to `InboundEmailStagingSelector.selectById`.** That
method is `WITH USER_MODE` and is the first thing every inbound email does; its own Javadoc names
this exact hazard. Adding a brand-new custom field there makes every email depend on that field's
FLS having been granted.

Instead the cap is enforced **only by the two components that decide whether to retry**, each of
which reads the row in its own transaction, outside every pinned budget:

- `RoutingFailureFinalizer` — reads and increments (1 SOQL + 1 DML, its own transaction).
- `RoutingRetrySweepBatch` — reads it in the batch locator.

Both reads go through a **new, narrow, `WITH SYSTEM_MODE`** selector method (§11.4), justified at
its declaration exactly as `queryCarrierSweep()` is: these are automation paths, `USER_MODE` throws
rather than degrades, and a Metadata-API-deployed field arrives with no FLS for **any** profile
including System Administrator — so `USER_MODE` here would break the retry engine for the very
administrator who deployed it.

`ExtractAddressQueueable.execute()` never reads the counter. It does not need to: the sweeper
refuses to dispatch a capped row, and the Finalizer refuses to keep counting past it.

### 3.6 🔴 THE CROSS-FEATURE DEFECT THIS CHANGE WOULD OTHERWISE INTRODUCE

`AttachmentCarrierSweepBatch.execute()` contains:

```
if (ROUTING_STATUS_PENDING.equals(row.Status__c)) { skipped++; continue; }
```

with the comment *"Routing has not finished. Converting now would create files with no routed
record to link them to."* — **which is exactly as true of a `Failed` row as of a `Pending` one.**

If `Status__c = 'Failed'` ships without widening that predicate, then for every email that carries
an attachment *and* whose routing died:

1. the file sweeper stops skipping the row;
2. `routedTargets(row)` returns **empty** (nothing was routed);
3. the files convert and are linked **only to the staging row**;
4. `Attachment_Status__c` is stamped `Saved` — **removing the row from the file work queue**;
5. routing later retries and succeeds — and **the files are never linked to the Lead**, permanently,
   with no error anywhere.

**REQUIRED:** widen the skip to `Status__c IN ('Pending', 'Failed')`. One line, one new constant,
and the class comment must say *why* — that a routing-failed row is a routing-**unfinished** row.
This is precisely the "mirror features share a decision" shape: two sweepers keyed on two fields of
one row, where the new half's state changes the live half's behaviour.

⚠ Note the second-order consequence, which is correct and should be stated: a row whose routing
never succeeds now takes the **EXPIRED** exit at `CARRIER_MAX_AGE_DAYS` (14) instead of converting
into an orphan. That is the right answer and it argues for aligning the routing age cap to 14 days
(§12 D5).

### 3.7 What the Finalizer does NOT fix

Stated plainly so it is not discovered later:

- **F6** (the job never ran) produces no `UNHANDLED_EXCEPTION` and therefore no Finalizer. Only the
  stale-`Pending` queue (D4) covers it.
- **The email-service rejection path.** An email above the service's own ceiling is rejected *above
  Apex* — no staging row, no Lead, no claim, no audit. No Apex fix exists; the levers remain the
  in-org `Bounce` setting (already applied) plus a coordinator runbook. 🔴 **A blank
  `Dropped_Attachment_Notes__c` still must never be read as "the broker sent no attachment."**
- **The claim race.** A retry restores the claim; it does not restore the *ordering*. A broker whose
  email died and was retried an hour later loses to a broker who submitted later but routed cleanly
  in between. Today they lose outright, so this is strictly better — but it is not a guarantee.
- **A deterministic failure** (F2, or a body that always blows heap) will exhaust its attempts and
  land in `Error`. That is correct: it needs a human, and the point of the design is that it now
  *reaches* one.

---

## 4. DELIVERABLE 2 — AN LLM OUTAGE SILENTLY DISABLES FIRST-BROKER-WINS

### 4.1 The gap, confirmed from the code

`extractOrDegrade()` catches `CalloutException`, `JSONException` and `Exception`, and returns
`LLMExtractionResult.emptyResult()` with `rawJson = {"skipped":"llm-unavailable"}`. The regex
fallback recovers only broker name and email — **never an address** — so `buildWorkList` returns
empty, `routeNoProperty` fires, a Lead is created and **no claim is attempted**. The staging label
is `OUTCOME_NO_PROPERTY_LLM_DOWN`.

`routeNoProperty`'s own Javadoc states the reason: *"claiming on an address nobody actually read
would be a guess written to a permanent, unique-keyed ledger."* **The code already considered this
question and decided it, with a stated reason.** Any proposal here is a reversal of a documented
decision and must be argued as one.

🔴 **The ordinary retry path from §3 cannot help.** An LLM-down email is a *successful* run by every
existing measure: `finish()` runs, the Task is logged, `markRouted` stamps `Processed`. A replay
short-circuits at guard 2. So this gap needs its own answer or none.

### 4.2 Three options

| | Option | Claim taken? | New machinery | Recommendation |
| --- | --- | --- | --- | --- |
| **O1** | Deterministic address regex feeding `properties[0].propertyAddress` | during the outage | small | 🔴 **Recommend against** — §4.3 |
| **O2** | Defer and re-extract: keep today's Lead, mark the row for re-extraction, claim against the *same* Lead when the LLM returns | after the outage | moderate — a claim-completion path that bypasses guard 2 | ✅ **The designed answer**, if a claim is wanted |
| **O3** | Take no claim; make the outage **loud** — a list view on the existing label plus the runbook | never (human hand-claims) | **zero** | ✅ **Ship regardless** — it is free and already in §5 |

**O2 mechanics, in outline.** `PropertyClaimService.claim(sourceLeadId, normalized, …)` already
accepts an arbitrary Lead Id, so a later pass *can* claim for a Lead that already exists — no
change to the claim engine. What is new is a narrow re-extraction path that (a) selects rows where
`Outcome__c` names the LLM-down label and `Result_Record_Id__c` holds a Lead, (b) re-runs the
callout, (c) if an address now comes back, claims against that Lead and stamps the result. It must
**not** re-run the routing tree (that would re-log the Task and could mint a second Lead) and it
must **not** create a Lead. Sizing and full design deferred to Gate 1 approval — decision **D8**.

**O2's honest cost:** the claim is taken late, so it can lose to a broker who submitted *later* but
routed while the LLM was up. Today it loses to everyone, forever.

### 4.3 🔴 Why the regex fallback is recommended against — three independent reasons

**(a) The highest-yield street address in a CRE broker email is the broker's own office.**
Every brokerage signature block contains one. The prompt itself instructs the model to read the
signature block and the footer. A precision-tuned regex has no way to prefer "1400 Royal Lane,
Dallas TX" (the asset) over "2001 Ross Ave Suite 400, Dallas TX" (JLL's office) — and
`deriveClusterKey` reduces both to `number + first alpha token`, so both are perfectly valid claim
keys. During an outage this would systematically register **brokerage office addresses** as
properties. The first such email wins that key; **every subsequent email from that firm then routes
branch (d) and receives no Lead at all.** That is the module's worst failure, inflicted by us, at
firm scale.

**(b) A wrong key is asymmetrically worse than no key, and the asymmetry crosses parties.**

| | No key (today) | Wrong key |
| --- | --- | --- |
| This broker | unprotected for this email | unprotected for this email |
| A *different* broker | unaffected | 🔴 if the wrong key fuzzy-matches (Jaccard ≥ 0.6) their real property, **they** route branch (d) and get **no Lead** |
| The ledger | clean | permanently polluted with a key removable only by hand |
| Recoverability | a human re-forwards the email | manual registry surgery |

This is the same rule as `EmailToLeadService.COMPANY_PLACEHOLDER`: a value meaning *"we don't know"*
must never be a match key, and the preferred failure direction is the recoverable one.

**(c) "Claim provisionally and upgrade later" is structurally forbidden.**
`PropertyClaimService.registerWinner`'s header contains an explicit prohibition: the insert and the
orphan update are *"the ONLY DML against this object in the entire codebase … **DO NOT ADD A
THIRD**"*, because any update of a merely-*live* registry row may touch a lookup holding a converted
Lead and be rejected wholesale. A provisional-then-upgrade design needs exactly that third
statement. **So a guessed claim is irrevocable by design.**

### 4.4 If the user wants O1 anyway — the guards it would need, and the spike that settles it

Do not build it on my reasoning. **SP-R4 (non-blocking, cheap, high-value):** score a candidate
regex against historical `Inbound_Email_Staging__c` rows. The org already holds `Raw_Body__c` **and**
`Extracted_JSON__c` for every email ever processed, so the LLM's own answer is free ground truth.
Measure: over N rows, how often does the regex return an address whose
`normalizeAddress` equals the model's, how often does it return a *different* address, and how often
is that different address the broker's office? **If "different address" is not near zero, O1 is
dead on measurement rather than on argument.**

Minimum guards if it proceeds regardless:

1. **Positional narrowing** — accept only from the subject line or the first N characters of the
   body; reject anything after a signature-block marker (`--`, a phone-number cluster, a second
   `From:` line).
2. **Full-shape requirement** — number + street token + street-type token + (city, ST | ZIP).
   Anything less is not an address, it is a fragment.
3. 🔴 **Refuse on any registry match.** If the derived key exactly or fuzzily matches an existing
   `Property_Registry__c` row, **abandon the guess and degrade to today's behaviour.** This makes a
   guess able only to create a *new* claim, never to lose an existing property to someone else's
   guess. It does not stop a wrong new claim from later blocking the real broker — nothing does
   (reason (c)) — which is why this is a mitigation, not a fix.
4. **A distinct outcome label** so the population is listable and hand-correctable while the
   property is still contested.

---

## 5. DELIVERABLE 3 — OBSERVABILITY FOR THE SILENT PATHS

**Declarative, zero Apex.** No custom report type exists for `Inbound_Email_Staging__c` (verified:
`force-app/main/default/reportTypes/` contains none), so a *report* would require authoring one.
List views need nothing.

| # | List view | Filter | Answers |
| --- | --- | --- | --- |
| **L1** | `Routing: Pending` | `Status__c equals Pending`, sorted `CreatedDate` ascending | 🔴 **The stranded-row detector.** A healthy pipeline routes within seconds, so a non-trivial `Pending` population *is* the signal. No age filter is needed and none should be added — list-view relative-date operators cannot express "older than 2 hours", and the sort does the job |
| **L2** | `Routing: Failed (retrying)` | `Status__c equals Failed` (new value) | The retry queue. Empty in health |
| **L3** | `Routing: Errors` | `Status__c equals Error` | 🔴 **The human queue — and it does not exist today.** F3/F4 rows have been landing here since the module shipped with no surface at all |
| **L4** | `Files: Retry Outstanding` | `Attachment_Status__c equals Pending, Partial, Failed` | Mirrors `queryCarrierSweep()`'s own work queue exactly, so it answers "is the file sweeper keeping up?" — **and it is the circuit breaker's observable proxy** (see below) |
| **L5** | `LLM Unavailable` | `Outcome__c contains LLM unavailable` | The §4 population — the Leads worth re-extracting or hand-claiming |

**Columns for all five:** `NAME`, `From_Address__c`, `Subject__c`, `Status__c`, `Outcome__c`,
`CreatedDate`, plus `Routing_Attempt_Count__c` on L2 and `Attachment_Status__c` on L4. Match the
existing `Gated_Call_For_Offers` shape.

**Three honest limitations, stated rather than papered over.**

1. 🔴 **The circuit breaker cannot be surfaced declaratively.** `Content_Publication_Budget__c` is a
   **hierarchy Custom Setting**, and custom settings back neither list views nor standard reports.
   **The minimum durable signal already exists and needs nothing new:** when the breaker trips,
   `AttachmentPersistFinalizer` stamps `Attachment_Status__c = 'Failed'` and writes the reason into
   `Dropped_Attachment_Notes__c` — so **L4 is the breaker's proxy**, and the note names the cause.
   Direct inspection is Setup → Custom Settings → Manage → one row. Put that in the runbook.
   Anything better (an LWC on a home page, a scheduled health check with a custom notification) is
   real Apex work and is **not** proposed here — decision **D9**.
2. 🔴 **L5 creates a THIRD `Outcome__c` string coupling.** The codebase already carries two loud
   warnings that `Gated_Not_Acquisition` and `Gated_Call_For_Offers` filter on label prefixes and
   that renaming a constant breaks a deployed view **with no compile error and no failing test**.
   L5 must therefore (a) filter on `contains 'LLM unavailable'`, **not** on the full label — the
   constant contains an em-dash, which is needless fragility — and (b) the Javadoc on
   `OUTCOME_NO_PROPERTY_LLM_DOWN` must gain the same 🔴 warning its two siblings carry, in the same
   PR.
3. **A list view is a durable, queryable record — it is not an alert.** Someone must look. The module
   already accepts this model explicitly (`Gated_Call_For_Offers` is documented as *"an ACTIVE
   WATCH, not an archive"*). If an alert is wanted, say so and it becomes its own scope.

⚠ **FLS.** List-view filter and column fields must be readable by the persona. Grant on
`Broker_Protection_Access`, where all 23 sibling `Inbound_Email_Staging__c` field permissions
already live — and remember that a `PermissionSet` deploy **replaces** its `<fieldPermissions>` set,
so an org-side-only grant will be wiped by the next deploy of that file. Declare it in-file.

---

## 6. DELIVERABLE 4 — OUTBOUND CAPTURE VIA BCC

### 6.1 ✅ The premise is correct: branch (a) ALREADY does the right thing — for replies

`routePrologueWithoutCallout()` calls `PropertyMatchingService.findRecordByReplyHeaders(In_Reply_To__c,
References__c)`, which mines **both** headers for Message-IDs and probes **both** Task threading
fields (`Thread_Key__c` and `Inbound_Message_Id__c`). A BCC'd outbound *reply* carries
`In-Reply-To` = the broker's original Message-ID, which the pipeline stamped on its Task. So it
matches, and the email is filed on the routed record with **no Lead, no claim, and no LLM callout** —
branch (a) runs *before* the callout by design.

That is the desired behaviour, already built, at zero marginal cost. It also does fix the
wrong-deal misfiling EAC causes, for the same reason the adopter does: header identity beats
address inference.

### 6.2 🔴 But a NEW outbound thread is actively dangerous

An outbound email that starts a conversation carries no `In-Reply-To` and no `References`:

1. branch (a) misses;
2. the deterministic pre-filter misses — a DPEG employee address matches none of `SENDER_CONTAINS`
   / `SENDER_EXACT`, and there is deliberately no subject-keyword filtering;
3. → **LLM callout → branch (e) WINNER → a Lead, and a `Property_Registry__c` claim, for a property
   DPEG was merely asking about.**

The real broker's later email then routes branch (d): **no Lead at all.** This is the module's worst
outcome, self-inflicted. **A guard is mandatory before BCC is enabled — it is not an optimisation.**

⚠ There is a second-order identity problem too. For a BCC'd copy, `resolveMonitoredInbox` will
almost certainly find nothing usable (`Delivered-To` carries the email-service address, which
`firstNonServiceAddress` excludes), so `forwardedBy` falls back to `email.fromAddress` — making
`senderIsOurOwnForwarder()` **true**, standing U1 down, and letting the *body-extracted* (quoted
broker) identity take the claim. Different wrong answer, same wrongness.

### 6.3 🔴 And the obvious guard would break a legitimate, supported path

"If the envelope From is a DPEG address, do not create a Lead" is wrong: **the paste-forward shape
is exactly that** — a coordinator composes/pastes a forward, `From == Forwarded_By`, and that email
legitimately produces a Lead today. A blanket domain rule would kill the pipeline's normal traffic.

The real discriminator is **where the service address appears**: a forward has it in **To**; a BCC'd
copy has it in neither `To` nor `Cc` (that is what BCC means) and only in `Delivered-To`. The handler
does not persist `To`/`Cc` at all today — it persists `Raw_Headers__c` wholesale, so the fact is
*recoverable* but only by regex-on-headers, which is the wrong shape for a routing predicate. Doing
this properly means new staging fields and a handler change.

### 6.4 Verdict: ITS OWN CYCLE

| Reason | Detail |
| --- | --- |
| It needs an in-org change | A Google Workspace routing rule is not deployable metadata, and what headers it actually delivers is **unmeasured** (SP-R5) |
| It touches the same code §3 is restructuring | Both change `execute()`'s prologue. Shipping together means two candidate causes for any regression — the exact reasoning `applyEnvelopeEmailFallback`'s header uses for not stacking a cosmetic change on a claim-key path |
| 🔴 It collides with a deployed, destructive feature | EAC also captures outbound mail. `EmailThreadGuardService`'s guard 5 deletes a redundant capture only when `Incoming == true`; an **outbound** capture has `Incoming == false`, so it survives **alongside** the new pipeline Task. Result: **every outbound deal email on the timeline twice.** Deciding whether to widen guard 5 is a change to a live delete predicate and must not be a rider |
| It needs new fields | `To_Addresses__c` / `Cc_Addresses__c` (or equivalent) plus a handler change, to express the discriminator in §6.3 |

**Recommended split:** ship **nothing** for BCC in this cycle. Open the next cycle with SP-R5 (a
single real BCC'd email through the service, `Raw_Headers__c` read back), then design the guard, the
duplicate-timeline decision and the enablement together.

---

## 7. SPIKES

Marked per the standing rule: anything not establishable from the code is a spike, and nothing is
designed on top of an unmeasured assumption.

| # | Question | Blocking? | Method | Why it matters |
| --- | --- | --- | --- | --- |
| **SP-R1** | 🔴 Does a Finalizer fire when a Queueable dies from an **uncatchable governor `LimitException`** (heap or CPU), as opposed to a thrown exception? And what do `getResult()` / `getException().getMessage()` report? | **YES — BLOCKING** | Anonymous Apex in `usman-dpeg`: a Queueable that attaches a Finalizer then deliberately exhausts heap, and a second that exhausts CPU. Query the Finalizer's own committed record | 🔴 **SP-3 measured an ordinary exception and an `UnexpectedException` — NOT a governor limit.** Heap/CPU is the *primary* F1 shape this design targets. If the Finalizer does not fire there, §3 is built on sand and the answer collapses to the sweeper alone |
| **SP-R2** | 🔴 Does `System.attachFinalizer` work inside a Queueable that also implements `Database.AllowsCallouts`, and does it still fire **after a callout has been made**? | **YES — BLOCKING** | Anonymous Apex: a callout-capable Queueable that attaches a Finalizer, makes a real callout, then throws | Every Finalizer measured so far (`AttachmentPersistQueueable`, the SP-3 probes) was a **plain** `Queueable`. `ExtractAddressQueueable` is `Queueable, Database.AllowsCallouts`. Assuming parity is exactly the class of claim this project has been burned by four times |
| **SP-R3** | Does re-enqueueing `ExtractAddressQueueable` from a **Batch** `execute()` behave normally (job created, callout permitted in the child)? | No — high confidence, cheap | The sweeper enqueues; the child makes the callout in its own transaction. Confirm during the build's own test pass | A batch cannot make the callout itself; the design already routes around this by enqueueing |
| **SP-R4** | How often does a candidate address regex return an address that **differs** from the model's, and how often is that difference the broker's office? | No — but it **settles §4** | Score the regex offline against historical `Raw_Body__c` + `Extracted_JSON__c` pairs. Free: the org already holds both | Turns §4.3's argument into a measurement. If the user wants O1, this is the gate |
| **SP-R5** | What headers does a Google Workspace BCC routing rule actually deliver — `Delivered-To`, `To`, `Cc`, `X-Forwarded-For`? | No — **gates §6's next cycle** | Send one real BCC'd email through the service; read `Raw_Headers__c` back | §6.2's identity analysis is inference from `resolveMonitoredInbox`, not measurement |
| **SP-R6** | What fraction of live staging rows carry a **blank `Message_Id__c`**? | No — sizes D4 | One SOQL count against `usman-dpeg` | It is the population for which a stale-`Pending` retry is *not* safe (§3.3). If it is zero, D4 gets simpler; if it is large, the skip filter is load-bearing |

---

## 8. GOVERNOR BUDGETS

✅ **All five pinned budgets are UNCHANGED. This is a design constraint, not an outcome.**

| Addition | Where it runs | Cost to `ExtractAddressQueueable.execute()` |
| --- | --- | --- |
| `System.attachFinalizer(...)` | first statement of `execute()` | **0 SOQL, 0 DML.** Not a governed statement; the one-finalizer-per-queueable cap is unaffected (the class has none today) |
| `RoutingFailureFinalizer` — read + stamp | **its own transaction**, after the parent's rollback | **0** — structurally outside every pinned budget, exactly as `AttachmentPersistFinalizer` is |
| `RoutingRetrySweepBatch` | its own transactions | **0** |
| `Routing_Attempt_Count__c` | **not** added to `selectById` (§3.5) | **0** |
| `AttachmentCarrierSweepBatch` predicate widening | in-memory string compare | **0** |

🔴 **The N=10 `DML_BUDGET = 43` is an `Assert.areEqual`.** Any DML added to `execute()` fails that
test. Treat a failure as the design working, not as a number to raise.

**New budgets to pin** (the file pipeline's precedent — a job with no pinned budget is a job whose
cost can drift silently):

| Component | Proposed pin |
| --- | --- |
| `RoutingFailureFinalizer.execute` | **1 SOQL / ≤ 2 DML**, constant |
| `RoutingRetrySweepBatch.execute` (per scope chunk) | **0 SOQL of its own** (locator only) / **≤ 1 DML per row** / **1 enqueue per row** |

---

## 9. TESTING — how a green suite is made to mean something

The recurring trap in this repo is a test that passes **vacuously**. Three rules, each from a real
prior incident:

1. 🔴 **Wrap `Test.stopTest()` in try/catch** in any test that enqueues a deliberately-failing job
   (R6) — otherwise the test reports as broken rather than as a passing assertion of the failure
   path.
2. 🔴 **Assert governor counts from statics captured INSIDE the async context**, never
   `Limits.*` after `Test.stopTest()` (which restores pre-test counters and makes the obvious
   assertion silently vacuous). `ExtractAddressQueueable.lastRunQueryCount` is the precedent.
3. 🔴 **Every test must assert its own precondition.** A retry test that silently never triggered
   the retry passes. Assert that the Finalizer *fired* before asserting what it wrote.

**Bulk-test rule.** `.claude/rules/bulk-test-rule.md`'s 251 mandate applies to
`RoutingRetrySweepBatch` (a batch), and it is **cheap and meaningful here** — 251 staging rows carry
no content and cost no `ContentPublication` (contrast the content rule's 20-row ceiling, which does
not apply because nothing here touches `ContentVersion`/`ContentNote`). `ExtractAddressQueueable`
keeps its existing narrowed-exemption replacements (volume, truncation, governor-headroom,
mixed-outcome, ordering) unchanged.

**The minimum test list:**

| # | Test | Asserts |
| --- | --- | --- |
| T1 | Finalizer fires on an unhandled exception → row moves `Pending` → `Failed`, counter 0 → 1, `Error__c` names the message and the job Id | the core mechanism |
| T2 | Finalizer does **nothing** on `ParentJobResult.SUCCESS` | it cannot disagree with a job's own stamp |
| T3 | Message classification is a **pure static substring** test, pinned against a verbatim message | R3 — a type check would silently never match |
| T4 | Sweeper dispatches a `Failed` row under the cap; does **not** dispatch at the cap; does **not** dispatch an `Error` row; does **not** dispatch a `Processed` row | 🔴 the §3.3 safety rule, expressed as four assertions |
| T5 | Sweeper at **251 rows** — constant per-row cost, no SOQL/DML in a loop | bulk rule |
| T6 | `AttachmentCarrierSweepBatch` **skips a `Failed` row** | 🔴 §3.6 — this test is the regression guard for the cross-feature defect |
| T7 | A replayed `Failed` row whose Task was never logged routes as a clean first run | replay safety, positively |
| T8 | A replayed row whose Task **was** logged short-circuits at guard 2 and writes nothing | F5 safety |
| T9 | The five pinned budgets, re-run unchanged | §8 |

**What Apex cannot prove here — say it, do not paper over it.** SP-R1's governor-limit case and
SP-R2's callout-capable attach are **not** unit-testable; they are anonymous-Apex measurements. The
Finalizer-initiated enqueue (if D3 selects it) is accepted-but-never-executed in `@isTest` (R4), so
it would need a decision seam and a UAT step, never an assertion on a chained job's effects.

---

## 10. 🔵 ADMIN WORK (`salesforce-admin`)

| # | Item | Notes |
| --- | --- | --- |
| **A1** | **`Inbound_Email_Staging__c.Status__c`** — add a fourth restricted value **`Failed`** (label `Failed`, `fullName` `Failed` — identical, so the `Not_Saved` underscore trap does not recur) | Additive to a restricted, `sorted=true` value set. Verified safe: no class enumerates `Status__c` exhaustively; the only literal comparisons are `Processed` (guard 1), `Pending` / `Processed` / `Error` in `InboundEmailStagingService`, and `Pending` in `AttachmentCarrierSweepBatch` — the last of which §3.6 changes deliberately |
| **A2** | **`Inbound_Email_Staging__c.Routing_Attempt_Count__c`** — Number(2,0) | §1 rule 9 requires the `_Count__c` suffix for a Number whose name would otherwise read categorical. ⚠ Rule 4 reserves past-participle names for Booleans, so **not** `Routing_Retried__c` |
| **A3** | **FLS** for `Routing_Attempt_Count__c` on **`Broker_Protection_Access`**, and update the in-file verification comment **`Inbound_Email_Staging__c 23 → 24`** | 🔴 The count is **23 today** — verified by reading the file. Declare the grant **in the file**: a `PermissionSet` deploy **replaces** its `<fieldPermissions>` set, so an org-side-only grant is wiped by the next deploy of that file, for any reason. Keep the verification comment **inside the root element** and never in `<description>` |
| **A4** | **Five list views** on `Inbound_Email_Staging__c` — L1…L5 per §5 | Mirror `Gated_Call_For_Offers`'s shape. L5's filter is `Outcome__c contains 'LLM unavailable'` — 🔴 **not** the full label (em-dash) |
| **A5** | **Page layout** — add `Status__c` (if absent) and `Routing_Attempt_Count__c` | The object still has no layout in the repo and uses the org default; verify in-org |
| **A6** | 🔴 **Schedule `RoutingRetrySweepSchedule`** — hourly | Scheduled-job *instances* are not deployable metadata. **A deploy that skips this silently disables every routing retry in this design** — a verified post-deploy gate, exactly as A5 is for the carrier sweep. Record it in the deployment log |

**Explicitly NOT included** (nothing requested, nothing required): no validation rules, no new
permission sets, no flows, no reports, no custom report type, no email alerts, no Lightning page
changes. If a report or an alert is wanted, that is decision **D9/D10** and adds scope.

---

## 11. 🟢 DEVELOPMENT WORK (`salesforce-developer`)

Layering per `.claude/rules/apex-layering-rule.md`: all SOQL in a selector, the service owns the
DML, the queueable/finalizer/batch orchestrate and hold neither. API version **67.0**.

| # | File | Change | Layer |
| --- | --- | --- | --- |
| 11.1 | `classes/RoutingFailureFinalizer.cls` | **NEW** | Finalizer |
| 11.2 | `classes/RoutingRetrySweepBatch.cls` | **NEW** | Batch |
| 11.3 | `classes/RoutingRetrySweepSchedule.cls` | **NEW** | Schedulable |
| 11.4 | `classes/InboundEmailStagingSelector.cls` | MODIFIED — one narrow `WITH SYSTEM_MODE` read + one `QueryLocator` | Selector |
| 11.5 | `classes/InboundEmailStagingService.cls` | MODIFIED — `markRoutingFailed(...)`, `markRoutingAbandoned(...)`; add `Failed` to the status constants | Service |
| 11.6 | `classes/ExtractAddressQueueable.cls` | MODIFIED — **one line**: `System.attachFinalizer(...)` as the FIRST statement, above `getStaging` | Queueable orchestrator |
| 11.7 | `classes/AttachmentCarrierSweepBatch.cls` | 🔴 MODIFIED — widen the routing-skip predicate to `Pending` **or** `Failed` (§3.6) | Batch |
| 11.8 | Tests — §9 | NEW + MODIFIED | Test |
| 11.9 | `ARCHITECTURE.md`, `docs/` | **MODIFIED — same PR, mandatory** (§6 of that document) | Docs |

**11.4 detail.** Two additions, each justified at its own declaration:

- `selectRoutingStateById(Id)` — `Id, Status__c, Error__c, Routing_Attempt_Count__c, Message_Id__c`,
  **`WITH SYSTEM_MODE`**. Same reasoning as `queryCarrierSweep()`: an automation path where
  `USER_MODE` throws rather than degrades, and where a Metadata-API-deployed field arrives with no
  FLS for any profile including System Administrator. 🔴 **Deliberately a separate narrow method
  rather than fields added to `selectById`** — the same reasoning `selectDroppedNotesById`'s Javadoc
  already carries.
- `queryRoutingRetrySweep()` — `QueryLocator` over `Status__c = 'Failed'`, ordered `CreatedDate ASC`,
  **`WITH SYSTEM_MODE`**. No age filter in the query — the batch must *see* old rows in order to
  abandon them (the identical reasoning `queryCarrierSweep`'s "THERE IS DELIBERATELY NO AGE FILTER"
  note carries).

**11.5 detail.** `markRoutingFailed` reads once, then writes `Status__c`, the incremented counter and
an appended `Error__c` in **one** update. Fail-soft catching `Exception` (not `DmlException`) — it
both reads and writes, and a `WITH SYSTEM_MODE` `QueryException` is not a `DmlException`; and its
caller is a Finalizer whose whole job is to report a failure that has already happened. **A failure
to record a failure must not become a second failure.**

**11.6 detail — the whole `ExtractAddressQueueable` change is one statement.** That is deliberate:
this class is the module's most complex and most load-bearing, and the design is worth nothing if it
introduces a regression in the thing it is protecting.

**Not modified, deliberately:** `PropertyClaimService`, `PropertyMatchingService`,
`EmailToLeadService`, `InboundEmailActivityService`, `LLMExtractionCalloutService`,
`InboundEmailAttachmentService`, `AttachmentPersistQueueable`, `AttachmentPersistFinalizer`,
`ContentPublicationBudget`, `EmailToLeadHandler`, every LLM prompt and fixture.

---

## 12. ⛔ OPEN DECISIONS — ALL REQUIRE GATE 1 ANSWERS

| # | Decision | Options | Recommendation |
| --- | --- | --- | --- |
| **D1** | Proceed at all before SP-R1 and SP-R2 land? | (a) run the spikes first (b) build on the assumption | 🔴 **(a).** SP-R1 tests the exact failure shape the feature targets and has never been measured |
| **D2** | New `Status__c` value `Failed`, or reuse `Error`? | (a) new value (b) reuse `Error` + a marker | **(a).** §3.3 shows the two states have opposite replay-safety properties; conflating them makes the retry queue unsafe |
| **D3** | Does the Finalizer also **re-enqueue** immediately? | (a) record-only + sweeper (b) record + one immediate retry + sweeper | **(a)** — §3.4. (b) is viable (R4) but untestable and mostly re-fails |
| **D4** | Build the **stale-`Pending`** queue (F5/F6) as well as the `Failed` queue? | (a) both, with the blank-`Message_Id__c` skip (b) `Failed` only now | **(a)**, gated on SP-R6. F6 leaves no Finalizer, so `Failed` alone does not cover everything |
| **D5** | Retry caps | attempts **3** (initial + 2)? age **14 days** (aligned to `CARRIER_MAX_AGE_DAYS`)? | 3 / 14 — 14 aligns the two sweepers so a row cannot outlive its own carrier |
| **D6** | Label for a re-run row that turns out already complete (F5) | (a) accept `'Duplicate Delivery (skipped)'` (b) a new label | (b) is one constant and removes a misleading audit entry; (a) is free |
| **D7** | Sweeper cadence | hourly / every 4h / daily | **hourly** — a claim is time-ordered; latency has a cost |
| **D8** | The **LLM-outage claim gap** — which option? | O1 regex / **O2 defer-and-re-extract** / O3 make it loud only | **O3 now (free, in §5) + O2 as its own scoped design.** O1 recommended against (§4.3); SP-R4 if the user wants it anyway |
| **D9** | Circuit-breaker visibility beyond L4's proxy | (a) L4 + runbook (b) an LWC or scheduled health check | **(a)** — (b) is real Apex work nobody asked for |
| **D10** | Any **reports** (needs a custom report type authored) | (a) list views only (b) + report type | **(a)** |
| **D11** | Outbound BCC | (a) its own cycle (b) fold in the guard now | **(a)** — §6.4, three independent reasons |

---

## 13. 🔗 EXECUTION ORDER

1. 🔴 **SP-R1 + SP-R2** (anonymous Apex, `usman-dpeg`). If either fails, return to Gate 1 — the
   Finalizer half of §3 may not be buildable and the answer collapses to the sweeper alone.
2. **SP-R6** (one SOQL count) — sizes D4.
3. **Admin A1 + A2 + A3** — the picklist value and the field must exist before any Apex references
   them. FLS in the same deploy.
4. **Dev 11.4 → 11.5 → 11.1 → 11.2 → 11.3** — selector, then service, then the Finalizer, then the
   batch and its schedule. Bottom-up so each layer compiles against a real dependency.
5. 🔴 **Dev 11.7 in the SAME deploy as A1** — the moment `Failed` can be written, the file sweeper
   must already know to skip it. Deploying A1 without 11.7 opens §3.6's defect.
6. **Dev 11.6** — the one-line attach, last, so a regression in it is unambiguous.
7. **Tests (§9), then code review.**
8. **Admin A4 + A5** — list views and layout (they can land any time after A1/A2).
9. **Post-deploy gate A6** — schedule `RoutingRetrySweepSchedule` and **verify it in-org**. Record it.
10. **Post-deploy verification** — re-run the FLS count query; `Inbound_Email_Staging__c` must read
    **24**.
11. **Docs (11.9)** in the same PR.

---

## 14. UAT — a green Apex suite does not prove this works

| # | Case | Expected |
| --- | --- | --- |
| **U1** | Force a real routing death in-org (anonymous Apex: enqueue against a staging row with a deliberately fatal condition) | `AsyncApexJob` Failed **and** the staging row reads `Status__c = 'Failed'`, counter 1, `Error__c` naming the message and the job Id. 🔴 This is the only proof the Finalizer fires on a real callout-capable job |
| **U2** | Wait for the hourly sweep | The row re-routes, produces a Lead **and a registry claim**, and lands `Processed` |
| **U3** | Force the same death 3 times | The row lands `Error` with a note naming the attempt cap — it does not loop |
| **U4** | A routing-failed email **carrying an attachment** | The carrier survives; the file sweeper **skips** the row while it is `Failed`; after U2's successful retry the files link to the **Lead**, not only to the staging row. 🔴 §3.6's regression, verified end to end |
| **U5** | An `Error` row (force a per-property failure via the existing seam) | The sweeper **never** dispatches it; it appears in L3 |
| **U6** | Open L1…L5 as the real Broker-Protection persona, not as an admin | All five render with all columns. 🔴 An admin smoke test proves nothing about FLS |
| **U7** | Simulate an LLM outage (revoke/expire the credential) and send a real email | Lead created, no claim, `Outcome__c` LLM-down label, and the row **appears in L5** |
| **U8** | Re-send a previously processed email | Still `Duplicate Delivery (skipped)`; still zero files; the retry engine must not have changed redelivery behaviour |

---

## 15. SCOPE STATEMENT

**In scope:** a Finalizer on the routing transaction; one new `Status__c` value; one new counter
field; a retry sweeper and its schedule; one predicate widening on the existing file sweeper; five
list views; the FLS grant and its verification-count update; docs.

**Deliberately excluded and named:** the regex address fallback (§4.3, recommended against — needs
SP-R4 to reopen); the defer-and-re-extract claim path (O2 — its own design if D8 selects it);
outbound BCC in every form (§6.4); alerts or notifications of any kind; reports and a custom report
type; any change to the prompt, the claim engine, the routing branches, the EAC guard/adopter, or
the file pipeline beyond the one predicate.

**Nothing in this document has been built.** No file under `force-app/` was modified.

---

## 16. 📝 PROMPTS FOR SPECIALIST AGENTS

> **Do not dispatch either prompt until Gate 1 approves §12 and SP-R1/SP-R2 have landed.**

### 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md first. Create metadata only — do not deploy.

On Inbound_Email_Staging__c:
1. Status__c — add a FOURTH restricted picklist value: fullName "Failed", label "Failed"
   (identical, deliberately). Do not alter the existing Pending / Processed / Error values,
   and keep sorted=true.
2. NEW field Routing_Attempt_Count__c — Number, length 2, decimal places 0, not required.
   Description: how many times the routing queueable has died with an unhandled exception for
   this row; written only by RoutingFailureFinalizer and read only by the retry sweeper.
   The _Count__c suffix is required by ARCHITECTURE.md §1 rule 9; do NOT name it with a
   past-participle form (rule 4 reserves that for Booleans).
3. Broker_Protection_Access.permissionset-meta.xml — add read+edit fieldPermissions for
   Routing_Attempt_Count__c, DECLARED IN THE FILE (a PermissionSet deploy REPLACES its
   fieldPermissions set, so an org-side-only grant is wiped by the next deploy of this file).
   Update the in-file verification comment: Inbound_Email_Staging__c 23 -> 24. Keep the comment
   INSIDE the root element and never in <description>.
4. FIVE list views on Inbound_Email_Staging__c, matching Gated_Call_For_Offers' shape
   (filterScope Everything; columns NAME, From_Address__c, Subject__c, Status__c, Outcome__c,
   CreatedDate):
   - Routing_Pending          Status__c equals Pending          (sort CreatedDate ascending)
   - Routing_Failed           Status__c equals Failed           (+ column Routing_Attempt_Count__c)
   - Routing_Errors           Status__c equals Error
   - Files_Retry_Outstanding  Attachment_Status__c equals Pending,Partial,Failed
                                                               (+ column Attachment_Status__c)
   - LLM_Unavailable          Outcome__c contains "LLM unavailable"
     ^ MUST be `contains "LLM unavailable"`, NOT the full outcome label — that constant contains
       an em-dash and matching it exactly is needless fragility.
5. Page layout for Inbound_Email_Staging__c: ensure Status__c and Routing_Attempt_Count__c are
   present. The object has no layout in the repo today and uses the org default — verify in-org.

NOT in scope: validation rules, permission sets, flows, reports, custom report types,
notifications, or any other object. Do not add anything not listed above.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md and agent-output/design-requirements-routing-resilience.md first.
API version 67.0. Layering per .claude/rules/apex-layering-rule.md.

Build, in this order:

1. InboundEmailStagingSelector (MODIFIED) — two additions, each justified at its own declaration:
   - selectRoutingStateById(Id): Id, Status__c, Error__c, Routing_Attempt_Count__c, Message_Id__c.
     WITH SYSTEM_MODE (automation path; USER_MODE throws rather than degrades, and a
     Metadata-API-deployed field has no FLS for ANY profile including System Administrator).
   - queryRoutingRetrySweep(): Database.QueryLocator over Status__c = 'Failed',
     ORDER BY CreatedDate ASC, WITH SYSTEM_MODE. NO age filter — the batch must see old rows in
     order to abandon them (same reasoning as queryCarrierSweep's own note).
   🔴 DO NOT add any field to selectById. Its Javadoc explains why: it is WITH USER_MODE and on
   the critical path, so a new field there makes every inbound email depend on that field's FLS.

2. InboundEmailStagingService (MODIFIED) — add STATUS_FAILED = 'Failed', plus:
   - markRoutingFailed(Id stagingId, String note): ONE read (selectRoutingStateById) then ONE
     update writing Status__c='Failed', Routing_Attempt_Count__c = existing+1, and `note` appended
     to Error__c. Fail-soft catching Exception (NOT DmlException) — it reads as well as writes, and
     a SYSTEM_MODE QueryException is not a DmlException. Same reasoning as appendDroppedNote.
   - markRoutingAbandoned(Id stagingId, String note): Status__c='Error' + appended note.

3. RoutingFailureFinalizer (NEW, implements System.Finalizer, with sharing) — model it on
   AttachmentPersistFinalizer:
   - returns immediately unless ctx.getResult() == ParentJobResult.UNHANDLED_EXCEPTION;
   - calls markRoutingFailed with a note naming ctx.getException().getMessage() and
     ctx.getAsyncApexJobId();
   - stops incrementing / stops requesting retry past the attempt cap;
   - 🔴 any classification of the failure is a MESSAGE SUBSTRING on a pure @TestVisible static,
     NEVER a type check — SP-3 measured getTypeName() reporting System.AsyncException, not the
     real type;
   - every step independently wrapped: a failure to record a failure must not become a second
     failure;
   - NO SOQL and NO DML of its own — delegate to InboundEmailStagingService.

4. RoutingRetrySweepBatch (NEW, Database.Batchable + Database.Stateful, with sharing) +
   RoutingRetrySweepSchedule (NEW, Schedulable):
   - start() delegates to queryRoutingRetrySweep() — no SOQL in the class;
   - per row: abandon if attempts >= cap or age >= cap; otherwise
     System.enqueueJob(new ExtractAddressQueueable(row.Id, null, null));
   - fail-soft per row (a batch has no Finalizer, so a failure is recorded here or nowhere);
   - 🔴 NEVER dispatch a row whose Status__c is 'Error' or 'Processed'. Only 'Failed' is provably
     free of committed side effects (SP-5: an unhandled exception rolls back the queueable's own
     DML). Put that reasoning in the class header.

5. AttachmentCarrierSweepBatch (MODIFIED) — 🔴 REQUIRED, NOT OPTIONAL. Widen the routing-skip
   predicate from Status__c == 'Pending' to Status__c IN ('Pending','Failed'), and say why in the
   comment: a routing-FAILED row is a routing-UNFINISHED row, so converting it would link files to
   nothing and stamp 'Saved', permanently losing the routed links once routing retries.

6. ExtractAddressQueueable (MODIFIED) — EXACTLY ONE STATEMENT:
   System.attachFinalizer(new RoutingFailureFinalizer(stagingId)) as the FIRST statement of
   execute(), ABOVE the existing getStaging(...) call (which is currently outside the try block —
   that placement is what makes a getStaging failure reportable at all). Change nothing else in
   this class.

7. Tests — see §9 of the design doc for the list (T1-T9) and the three anti-vacuity rules:
   wrap Test.stopTest() in try/catch for any deliberately-failing job; read governor counts from
   statics captured inside the async context, never Limits.* after stopTest(); assert the
   precondition before asserting the effect. RoutingRetrySweepBatch needs a 251-row bulk test
   (cheap here — staging rows consume no ContentPublication).

8. ARCHITECTURE.md + docs/ in the SAME PR (§6 of that document): add the two new SYSTEM_MODE
   selector methods to the §2 automation-path table, add the new classes to §2, and correct the
   ExtractAddressQueueable header's stale claim about the single-property DML budget (the test
   class carries THREE literals: 20, 20 and 7).

🔴 GOVERNOR BUDGETS — ExtractAddressQueueable's five pinned budgets MUST NOT MOVE:
   N=1 SOQL 30, N=1 DML 20 (x2) and 7, N=10 SOQL 120, N=10 DML 43 (an Assert.areEqual).
   Everything above runs in its own transaction or costs no governed statement. If any of those
   assertions moves, stop and report it rather than raising the number.

NOT in scope: the LLM prompt or any fixture; PropertyClaimService; PropertyMatchingService;
EmailToLeadService; InboundEmailActivityService; InboundEmailAttachmentService;
AttachmentPersistQueueable / Finalizer; EmailToLeadHandler; the EAC guard/adopter; any regex
address fallback; any outbound/BCC handling. Do not deploy.
```
