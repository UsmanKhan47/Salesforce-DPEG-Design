# Design Requirements — Inbound Broker-Email Attachment Persistence **v2**

**Module:** Broker Protection (inbound email-to-Lead pipeline)
**Date:** 2026-08-06
**Supersedes:** `agent-output/design-requirements-email-attachments.md` (v1, Gate 1 approved
2026-08-05, **shipped 2026-08-05, caused a live outage, reverted 2026-08-06**)
**Status:** ✅ **BUILD-READY — all six spikes complete, every decision resolved, no open blockers.**
**Evidence base:** `agent-output/spike-attachment-persistence-v2.md` (SP-1…SP-6, `usman-dpeg`,
2026-08-06) and `agent-output/spike-attachment-persistence.md` (S1…S6, 2026-08-05).
**Conformance:** `ARCHITECTURE.md` §1 (naming), §2 (layering, `SYSTEM_MODE` automation path),
`.claude/rules/apex-layering-rule.md`, `.claude/rules/bulk-test-rule.md`,
**`.claude/rules/content-publication-rule.md` (new, 2026-08-06)**.

> **THE ONE-LINE BRIEF.** v1 put a `ContentVersion` insert inside the transaction that owns the
> broker email. That insert can kill its transaction in a way no `try/catch` and no
> `allOrNone = false` can intercept. v2 does not make that insert safer — **it moves it into a
> transaction that owns nothing, and carries the bytes there in a form that costs no quota and
> survives every failure.** Everything else in this document follows from that.

> **WHAT THE SPIKES CHANGED versus the pre-spike draft of this document.**
> **(1)** The Queueable payload is **dead as a carrier for attachments** — SP-1 found an
> **uncatchable** ceiling at ~4.2–4.5 MB raw, thrown at `System.enqueueJob` itself. Carrying bytes
> that way would have relocated the outage one call earlier instead of removing it. It stays exactly
> where it already is: the ≤1 MB vision image.
> **(2)** The carrier is the **classic `Attachment`** — zero ContentPublications, ~0 synchronous
> heap at 5 MB, and the only mechanism that survives a downstream quota failure with **zero
> permanent loss**.
> **(3)** The real new risk is **heap on the async conversion**, not on the boundary: a 5 MB file
> peaked at **10.49 MB of the 12 MB async budget**. §6.2 gates it with a *pre*-check, not an
> assumption.
> **(4)** `MAX_ATTACHMENTS` is **3**, not 10 (user decision).
> **(5)** Retry/replay becomes a **designed capability**, because a failed conversion now leaves the
> bytes intact on the staging row.

---

## 0. WHAT WAS REQUESTED

> Redesign inbound broker-email attachment persistence so that saving a file can NEVER destroy the
> email, the Lead, or the registry claim.

Plus four explicit sub-asks, each answered in its own section:

| Ask | Section |
| --- | --- |
| Evaluate at least five named mechanisms; weigh them on the disqualifying question | §3 |
| Identify what cannot be answered from documentation, as blocking spikes | §5 — **all six now answered** |
| Graceful degradation as the quota depletes — "never hit our quota at any cost" | §6 |
| What `Dropped_Attachment_Notes__c` says in each degraded mode | §7 |
| How the design is TESTED so a green suite means something | §8 |
| The carrier is temporary — what cleans it up | §6.4 (four exits), §11.4 (the sweeper) |
| Every remaining decision resolved with a stated answer | §12 |
| UAT checklist | §14 |

**Explicitly out of scope, unchanged from v1 and not re-opened here:** the LLM prompt, the
extraction contract, the routing tree's branch logic, the claim/arbitration engine, the Task-logging
contract, `LeadConvertService` / `LeadConvertTrigger` (spike S6 stands — the platform carries files
on conversion for free), and the classification rules G1 / G2 / G3 (allow-list, image floor, CSV).
**Classification is not implicated in the outage and is currently running correctly in production.**

---

## 1. VERIFIED BASELINE — read this before proposing anything

Confirmed against the working tree on 2026-08-06, not assumed.

### 1.1 What is deployed and running right now

| Component | State |
| --- | --- |
| `EmailToLeadHandler` | **Live, healthy.** Marshals → classifies → gates the vision encode → `createStaging` → enqueues `ExtractAddressQueueable(stagingId, imageBase64, imageMimeType, new List<Id>())`. **`persist(...)` is NOT called.** Class header carries the full outage writeup. |
| `InboundEmailAttachmentService` | **Deployed, partially used.** `classify()`, `isImageAttachment()`, `describeDrop()` are called by the handler. **`persist()` and `linkTo()` are deployed and correct in isolation, and are called by nobody in production.** |
| `ContentVersionSelector` | **Deployed, unused.** One method, `selectByIds(Set<Id>)`, `WITH SYSTEM_MODE`. Correct as written. |
| `ExtractAddressQueueable` | **Live.** Constructor still takes the 4th argument `List<Id> contentDocumentIds`; `finish()` still calls `linkAttachments(targets)`, which short-circuits on the empty list the handler now passes. **The linking half is intact and still under test** (`execute_singlePropertyEmailWithOneAttachment_...` passes pre-created document Ids in directly). |
| `InboundEmailStagingService` | **Live.** `createStaging` stamps the three attachment fields; `appendDroppedNote(Id, String)` exists and is fail-soft. |
| Three staging fields | **Deployed**, with FLS on `Broker_Protection_Access` (22 field permissions). `Attachment_Count__c`, `Attachment_Bytes__c`, `Dropped_Attachment_Notes__c`. |
| `EmailToLeadHandler.persistenceDisabledNotes()` + `PERSISTENCE_DISABLED_BANNER` | **Live.** Writes an explicit "NO FILE WAS SAVED" banner plus one line per unsaved file. Its own Javadoc says **delete it when persistence is restored** — a stale DISABLED banner on rows whose files exist would be worse than none. |

**Net:** the counts on the staging row are honest today (they describe what *arrived*), and every
row says plainly that nothing was saved. The pipeline is healthy and verified end-to-end with a
real email.

### 1.2 Two documentation defects this change must fix

1. 🔴 **`ARCHITECTURE.md` is stale and currently states a FALSEHOOD as an invariant.** §2's
   `InboundEmailAttachmentService` row still reads *"`persist(...)` AND `linkTo(...)` MUST NOT
   THROW, under any input"* and pins the handler at *"1 SOQL / 3 DML"*. Both were falsified by the
   outage (the handler is back to 0 SOQL / 1 DML, and `persist` demonstrably *can* fail in a way
   that escapes its own catch). Per §6 of that document, correcting it is part of this change, not
   a follow-up.
2. `docs/2026-08-05-inbound-email-attachments.md` describes the feature as shipped and flags the
   `ContentPublication` limit only as a "newly discovered operational risk … `System.UnexpectedException`
   **is catchable**". **That sentence is now known to be wrong** and must be corrected in the same pass.

### 1.3 The measured facts, restated as constraints (treat as given, do not re-litigate)

| # | Measured fact | Design consequence |
| --- | --- | --- |
| M1 | `Database.insert(versions, false)` throws `System.UnexpectedException: ContentPublication Limit exceeded` when the org quota is exhausted | A `ContentVersion` insert is not an ordinary DML |
| M2 | It **ignores `allOrNone = false`** | Partial-success patterns give no protection |
| M3 | It **escapes `catch (Exception e)` through two nested layers**, arriving as `FATAL_ERROR` | 🔴 **"Catch it better" is measured-dead. Do not propose it.** |
| M4 | Apex `Limits` exposes no `ContentPublicationLimit` | No pre-check is possible in Apex |
| M5 | `InboundEmailResult.success = false` rolls back **all** handler DML, including the already-inserted staging row | The email, Lead, claim, Task and audit all die together |
| M6 | Attachment SIZE was irrelevant — 100 KB / 1 MB / 5 MB failed identically, heap peaked at 4,262 bytes | This is **not** the heap failure. `VISION_MAX_BYTES` / `TEXT_MAX_BYTES` remain correct and unchanged, and neither is a mitigation here |
| M7 | Test rollback does **not** refund the quota | Tests and production share one 2,500/24h counter |

**THE DESIGN RULE, stated once:** *a `ContentVersion` insert must never sit inside a transaction
whose rollback would lose something irreplaceable.*

### 1.4 The irreplaceable-things inventory — the table the whole design turns on

| Transaction | What it owns | Loss on rollback | May it contain a `ContentVersion` insert? |
| --- | --- | --- | --- |
| **Sync handler** (`handleInboundEmail`) | the staging row = the raw body, every RFC header, the ONLY record the email existed | **THE EMAIL.** Unrecoverable — the bytes live only in `Messaging.InboundEmail` | 🔴 **NO** |
| **Routing job** (`ExtractAddressQueueable`) | the Lead, the `Property_Registry__c` claim, the `Competing_Broker_Submission__c` row, the Task | **THE CLAIM.** Recoverable only by manual registry surgery | 🔴 **NO** |
| **A dedicated file job** | files, and nothing else | the file — **and under this design not even that**, because the bytes remain on the staging row as a classic `Attachment` and the work is retryable | ✅ **YES — this is the only admissible home** |

**SP-5 confirmed this table is not a theory.** A deliberately-failing Queueable rolled back only its
own DML; a Lead, Task and staging row committed by an earlier transaction survived byte-for-byte,
and `AsyncApexJob` carried a durable, queryable `ExtendedStatus`. This is the core structural bet of
the redesign and it holds without qualification.

**A `ContentDocumentLink` insert costs ZERO publications** (SP-6, bulk-of-10, noise-resistant). So
linking was never the quota risk, and `ExtractAddressQueueable.linkAttachments()` was never
quota-unsafe. Routed linking still moves into the file job — but on **cohesion** grounds (one place
owns the whole file lifecycle, one place to retry), not on a quota risk that does not exist.

---

## 2. WHAT DOES *NOT* CHANGE

Stated up front so the change stays as small as the problem allows.

- **Classification stays exactly where it is**, in the synchronous handler. It is pure, it cannot
  throw, it costs no DML, and it is the reason today's staging rows are honest about what arrived.
  Two of its constants change value (§2.1); none of its rules change.
- **`VISION_MAX_BYTES` = 1,000,000 and the gated base64 encode stay, unchanged.** M6 makes clear
  this was never the outage's cause, and SP-1 retro-validated it: 1 MB raw sits ~4× inside the
  confirmed-safe payload zone. It remains the only defence against the *separate*, uncatchable heap
  `LimitException`.
- **`InboundEmailAttachmentService.persist(...)` and `.linkTo(...)` are reused, not rewritten.**
  What changes is **who calls them and in which transaction**, plus a heap gate and a budget guard
  ahead of `persist`.
- **`ContentVersionSelector` is reused unchanged** (header venue only — §11.6).
- **`ShareType` `'I'` routed / `'V'` staging, never `'C'`** (S3) — unchanged.
- **No Content permission-set grant** (S1: license-gated) — unchanged.
- **No `LeadFileCarryOverService`** (S6) — unchanged. `LeadConvertService`'s 2 SOQL / 3 DML contract
  is untouched, and `LeadConvertTrigger` is not modified.
- **The routing tree, the claim engine, the Task contract and every LLM prompt/fixture** —
  untouched.

### 2.1 The three constants that DO change, and why

| Constant | Was | Now | Reason |
| --- | --- | --- | --- |
| `InboundEmailAttachmentService.MAX_ATTACHMENTS` | 10 | **3** | User decision. Caps publications at 3/email and `ContentDocumentLink` rows at 3 × 10 targets = 30. Anything beyond the third retained file is **dropped and named** in `Dropped_Attachment_Notes__c` exactly as today (`REASON_COUNT_CAP`), so the cap is visible, never silent. |
| `InboundEmailAttachmentService.ATTACHMENT_MAX_BYTES` | 5,000,000 | **4,000,000** | Aligns retention with what the async conversion can provably do (§6.2). Above it, a file is never retained, so the carrier can never hold a file that is structurally unconvertible. |
| `InboundEmailAttachmentService.TEXT_MAX_BYTES` | 1,000,000 | **1,000,000 — value unchanged, VENUE MOVES** | The `Blob.valueOf(textBody)` allocation moves from `persist()` (async) into `stageBytes()` (synchronous), so this constant is now guarding the 6 MB synchronous budget rather than the 12 MB async one. **Its justification comment must be rewritten, not copied.** |

`IMAGE_MIN_BYTES` (20,000) and `HEAP_HEADROOM_FLOOR` (4,000,000) keep both their values and their
meanings. Every `REASON_*` string that embeds a number must be updated to match.

---

## 3. THE SETTLED ARCHITECTURE

The disqualifying question was applied to every option: **can a file failure still cost an email or
a claim?** Anything answering "yes, in any circumstance" was rejected however attractive otherwise.
The spikes have now answered every remaining question, so this section records the outcome rather
than the deliberation.

### 3.1 The problem decomposed into three decisions — all now closed

| | Decision | Answer | Settled by |
| --- | --- | --- | --- |
| **S-1** | **WHERE** does the `ContentVersion` insert run? | **S1-d** — a dedicated Queueable that owns nothing else | SP-5 |
| **S-2** | **HOW** do the bytes reach it? | **S2-b** — a classic `Attachment` parented to the staging row. **Never a Queueable payload.** | SP-4 (viable) + SP-1 (payload is uncatchably fatal above ~4.2–4.5 MB) |
| **S-3** | **WHEN** does it start, and how does it learn the routed targets? | **S3-a** — chained from `ExtractAddressQueueable.finish()`, receiving **Ids only** | SP-2 (works in production; unprovable in `@isTest`) |

### 3.2 The record of what died, so it is not re-proposed

| Option | Verdict | Basis |
| --- | --- | --- |
| **S1-a** catch it better | 🔴 **DEAD** | M3 — measured; escapes `catch (Exception e)` through two layers |
| **S1-b** pre-check the quota in Apex or over REST | 🔴 **DEAD, twice over** | M4 (no Apex counter) + §3.1 ASB-only + **SP-6: the REST `/limits` value is measurably stale and non-monotonic** — a single insert's cost did not appear across four consecutive settled reads, and two reads once moved *upward* with no publish between them. Even an advisory check would be actively misleading. |
| **S1-c** insert inside `ExtractAddressQueueable` | 🔴 **DEAD** | takes the Lead and the claim with it |
| **S2-a** Queueable payload as a general attachment carrier | 🔴 **DEAD** | SP-1: `System.LimitException: Batchable instance is too big`, thrown at `System.enqueueJob` itself, **uncatchable** (`[EXTERNAL]` / `FATAL_ERROR`), at the platform's 6,000,000-char constant ≈ 4.2–4.5 MB raw. A scanned OM routinely exceeds it. This would have moved the outage one call earlier, not removed it. **Retained ONLY for the existing ≤1 MB vision image, which SP-1 proved safe with ~4× headroom.** |
| **S2-c** `EventBus` immediate-publish as a carrier | 🔴 **DEAD** | 1 MB event cap / 131,072-char fields force chunking, and building the chunks re-creates the synchronous heap cost the design exists to avoid |
| **S2-d** base64 into Long Text fields | 🔴 **DEAD** | ~98 KB per field; cannot hold an OM |
| **S3-b** file job chains routing | 🔴 **DEAD** | would make the Lead and the claim downstream of the file |
| **S3-c** two independent jobs + `FOR UPDATE` rendezvous | **NOT NEEDED** | was the fallback if SP-2 killed chaining; SP-2 confirmed chaining works in production |
| **S3-d** Finalizer-initiated enqueue of the file job | **NOT USED for the happy path** | SP-2/SP-3 confirm it works in production but the child never executes in `@isTest`; a plain chain is simpler. The Finalizer is used for its real purpose — failure recording (§6.5) |

### 3.3 Why the classic `Attachment` carrier is the right answer, in one paragraph

The bytes exist only inside `Messaging.InboundEmail`, in the synchronous handler, and must survive
into a later transaction. A classic `Attachment` does that at **zero ContentPublication cost**
(SP-4.1, definitive) and at **~152 bytes of heap regardless of file size** (SP-4.3 — measured
identically at 3 MB and 5 MB, because `Body = <blob>` is a reference assignment on a fresh row, not
a copy). It is inserted by the same principal that owns the staging row it hangs off, which is the
ordinary record-ownership mechanism and nothing special (SP-4.2). And — the property that decides
it — **if every downstream step fails, the bytes are still there.** No other carrier has that. The
`Attachment` row is a *temporary carrier, not storage*: it is deleted only on confirmed conversion,
and §6.4 says what removes it when conversion never succeeds.

### 3.4 THE APPROVED SHAPE

```
Inbound broker email
   │
   ▼  ═══ TRANSACTION 1 — owns THE EMAIL. No ContentVersion. Ever. ═══
EmailToLeadHandler.handleInboundEmail
   ├─ marshalAttachments()                        unchanged, references only
   ├─ InboundEmailAttachmentService.classify()     unchanged rules; MAX_ATTACHMENTS 3, cap 4 MB
   ├─ vision gate at VISION_MAX_BYTES (1,000,000)  unchanged
   ├─ InboundEmailStagingService.createStaging()   + counts + notes + Attachment_Status__c
   ├─ InboundEmailAttachmentService.stageBytes(stagingId, retained)   ← CLASSIC ATTACHMENT CARRIER
   │        ONE bulk Database.insert(attachments, false). Zero publications. ~152 bytes heap.
   └─ System.enqueueJob(new ExtractAddressQueueable(stagingId, imageBase64, imageMimeType))
                                                   budget: 0 SOQL / 2 DML  (1 when no attachments)
   │
   ▼  ═══ TRANSACTION 2 — owns THE LEAD AND THE CLAIM. No ContentVersion. Ever. NO BYTES. ═══
ExtractAddressQueueable.execute → routing tree → finish()
   ├─ targets = orderedTaskTargets()               computed ONCE, unchanged
   ├─ InboundEmailActivityService.logInboundEmail(targets, …)       unchanged
   ├─ InboundEmailStagingService.markRouted(…)                      unchanged
   └─ enqueueAttachmentPersist(targets)            ← NEW, LAST, try/catch'd, Ids ONLY
          • skipped when Attachment_Status__c != 'Pending'  (no carrier → zero cost)
          • skipped when targets is empty (a gate) → releaseCarrier() instead
                                                   budget: 30 / 120 ceilings UNCHANGED
   │
   ▼  ═══ TRANSACTION 3 — owns ONLY FILES. Its rollback costs nothing permanent. ═══
AttachmentPersistQueueable.execute            (+ AttachmentPersistFinalizer attached FIRST)
   ├─ breaker + daily budget check              §6.5 / §6.6 — skip + record, never throw
   ├─ AttachmentSelector.selectMetadataByParentIds   NO Body — BodyLength only
   ├─ HEAP PRE-CHECK on BodyLength              §6.2 — choose the subset that provably fits
   ├─ AttachmentSelector.selectBodiesByIds           Body for exactly that subset
   ├─ InboundEmailAttachmentService.persist(stagingId, retained)     REUSED UNCHANGED
   ├─ InboundEmailAttachmentService.linkTo(documentIds, targets)     REUSED UNCHANGED
   ├─ delete the carrier rows that CONVERTED — only those, only on confirmed success
   └─ stamp Attachment_Status__c + notes on the staging row
                                                   budget: 3 SOQL / 5 DML (see §9)
   │
   ▼  on unhandled exception, in a NEW transaction AFTER the rollback (SP-3, measured)
AttachmentPersistFinalizer
   ├─ durable note on Dropped_Attachment_Notes__c   the R1 lesson's actual mechanism
   ├─ Attachment_Status__c = 'Failed'               → the sweeper will retry it
   └─ trip the breaker IF the message contains 'ContentPublication Limit exceeded'
          🔴 SUBSTRING, never a type check — SP-3 measured the wrapper as System.AsyncException
   │
   ▼  daily, and this is what makes the carrier temporary rather than permanent
AttachmentCarrierSweepBatch (scheduled)
   └─ retries 'Pending' / 'Partial' / 'Failed' rows; expires carriers older than 14 days
```

---

## 4. WHAT THIS DESIGN DOES *NOT* FIX

Carried forward from v1 so it is not mistaken for something this change addresses.

| # | Item | Status |
| --- | --- | --- |
| 1 | **The oversized-email claim loss.** An email above the Email Service's own ceiling is rejected **above Apex** — no staging row, no Lead, no claim, no audit, and a later broker with a smaller email wins the property outright. | **Not fixable in Apex.** ✅ The one available mitigation is **DONE**: `overLimitAction` reads **`Bounce`** in the org, verified twice (§10.1). The residual — a bounced email leaves no row — stands, and the coordinator runbook is the only remedy. |
| 1b | 🔴 **No Email Service setting covers a HANDLER-FAILURE path.** The five configurable actions govern *sender/rate/deactivation/inactive-service* rejections. When the Apex handler dies with an uncaught `FATAL_ERROR`, `InboundEmailResult` is never returned at all and none of those settings applies. **Configuration was therefore never the remedy for the outage's invisibility** — do not read the `Bounce` change as having addressed it. Only §3.4's transaction structure does. | **By design, permanent.** State it wherever someone might reach for a setting instead. |
| 2 | **The vision candidate may be a signature logo over 20 KB.** | Unchanged, open, out of scope. |
| 3 | **`Dropped_Attachment_Notes__c` being blank never means "the broker sent no attachment".** | Unchanged standing caveat. |

---

## 5. SPIKE RESULTS — ALL SIX COMPLETE, ALL BLOCKERS CLEARED

Full writeup: **`agent-output/spike-attachment-persistence-v2.md`** (`usman-dpeg`, 2026-08-06, nine
throwaway classes deployed outside `force-app/` and destructively removed; total quota cost of the
whole investigation: **8 publications**, 2,500 → 2,492).

Only the findings that **constrain the build** are restated here. Everything below is a measurement,
not an inference.

### SP-1 — Queueable payload capacity 🔴 THE FINDING THAT CHANGED THE DESIGN

| Measured | Value |
| --- | --- |
| `Blob` member on constructor state | **Serializes.** Arrives byte-identical (SHA-256 verified) — no base64 detour needed |
| Byte-identical arrival, one hop and two hops | ✅ at 100 KB, 250 KB, 500 KB, 1 MB, 2 MB, 3 MB, 4 MB |
| Largest success | 4,194,304 raw / 5,592,408 base64 chars |
| First failure | **6,000,000 base64 chars exactly** (≈4.5 MB raw), and again at 5 MB |
| The failure | `System.LimitException: Batchable instance is too big`, thrown **at `System.enqueueJob` itself** |
| Catchable? | 🔴 **NO.** A `try/catch` wrapped directly around the enqueue did not catch it — `[EXTERNAL]` / `FATAL_ERROR` at "External entry point" |
| Heap cost of the enqueue call | **44–88 bytes at every size.** The real cost is *holding* the string (a 4 MB file is ~5.59 MB of heap before enqueue is even attempted) |

**Consequence — this is why S2-a is dead as an attachment carrier.** An uncatchable throw at
`enqueueJob` sits in **Transaction 1**, which owns the email. Carrying attachments that way would
have reproduced the outage exactly, one call earlier, for every OM above ~4.2 MB. The payload
carrier is retained **only** for the ≤1 MB vision image, where SP-1 measured ~4× headroom.

> **Retro-validation:** `VISION_MAX_BYTES = 1,000,000` is comfortably inside the proven-safe zone.
> **Payload capacity was never why `Has_Image__c = False` on every real staging row** — that remains
> unexplained and out of scope, but it is not a capacity problem. Carry that into UAT step U5.

### SP-2 — Queueable chaining: works in production, unprovable in `@isTest`

- A queueable chaining another from its own `execute()` **works cleanly in real execution**
  (SP-1's two-hop results and SP-3's real Finalizer chains both confirm it independently).
- Inside `@isTest` it throws `System.AsyncException: Maximum stack depth has been reached` — and it
  is **catchable**, so a guarded call degrades cleanly rather than failing the test.
- A **Finalizer's** enqueue is a *different* mechanism: accepted in test but the child never
  executes there; in production it is accepted **and runs to completion**.
- `ExtractAddressQueueable` contains zero `System.enqueueJob` calls today — **the single chained-job
  slot is free.** ⚠ A future 11+-property chaining feature (deferred in `MAX_PROPERTIES`'s own
  comment) would contend for it; record that in the class header.

**Consequence:** S3-a is adopted. The chain is guarded with `Test.isRunningTest()` and asserted
through a `@TestVisible` decision seam (§8.5.2); its real firing is proven only by the UAT rehearsal
(§14). This is a testability constraint, not an architectural one.

### SP-3 — Finalizer fires, and its DML survives the parent's rollback

- Fires on **both** an ordinary unhandled exception and a `System.UnexpectedException`, in **both**
  test and production contexts. `ctx.getResult() == UNHANDLED_EXCEPTION` in every case.
- **Its own DML durably commits** and is queryable from the org afterwards, independent of the
  parent's rollback. This is the R1 lesson's actual mechanism, now observed rather than inferred.
- 🔴 **`ctx.getException().getTypeName()` reports `System.AsyncException`, NOT
  `System.UnexpectedException`** — the platform wraps it, preserving the original type and message
  only as *text inside* the wrapper's `getMessage()`. **Detection must be a substring match on the
  message; a type check would silently never match and the breaker would never trip.**
- 🔴 **In test context an unhandled exception from a Queueable running at `Test.stopTest()`
  PROPAGATES OUT of `Test.stopTest()`** to the calling test method — unlike production, where there
  is no synchronous caller left. **Any test that deliberately fails the job must wrap
  `Test.stopTest()` itself in `try/catch`**, or it reports as a broken test instead of a passing
  assertion of the failure path. The Finalizer's DML still commits and is queryable in the same test
  method afterwards.

### SP-4 — The classic `Attachment` carrier is safe; the CONVERSION is the new risk

| Measured | Value |
| --- | --- |
| `Attachment` insert → ContentPublications | **ZERO.** `/limits` unchanged, 2500 → 2500. Definitive |
| Insert as the Email Service persona onto a staging row **he owns** | ✅ SUCCESS. (A first attempt failed only because the *admin* owned the row — a flawed test, not a finding; production always has junior owning it) |
| Synchronous heap, `Body = <fresh blob>` | **152 bytes at 3 MB and at 5 MB — identical.** A reference assignment, not a copy |
| 🔴 **Async conversion heap, 5 MB file** | `heapAfterRead = 5,244,053` → `heapAfterBuild = **10,487,036**` → insert + delete add 48 bytes. **87% of the 12 MB async budget for ONE file** |

🔴 **The conversion pattern genuinely duplicates the bytes:** the SOQL read allocates the full body,
and constructing `ContentVersion.VersionData = att.Body` allocates it again. Peak ≈ **2× BodyLength**.
This is materially tighter than "measure against 12 MB" implies, and §6.2 gates it.

**Two things SP-4 did NOT establish, stated rather than glossed:**

1. **`Attachment.Body`'s own true ceiling.** Probing near the documented 25 MB via Apex string
   repetition hits an unrelated, uncatchable `String is too long` first — a *methodology* limit, not
   an `Attachment` limit, and one the real pipeline never touches (production bytes arrive
   pre-formed as a `Blob`). Our own `ATTACHMENT_MAX_BYTES` of 4,000,000 sits far below any plausible
   ceiling, so this does not block; **do not cite the spike as proving 25 MB works.**
2. **A storage-exhaustion condition** was not simulated (`DataStorageMB` 22,440/22,440 remaining).

### SP-5 — Transaction isolation: CONFIRMED, cleanly and completely

A Lead, Task and staging row committed in Transaction A; a separate Queueable then inserted a marker
Task, updated the Lead, and threw. Verified from the org afterwards: the marker Task **does not
exist**, `Lead.Description` is **null**, and the Lead, its Task and the staging row are **untouched**.
`AsyncApexJob` shows `Status = Failed` with a usable `ExtendedStatus`.

**The disqualifying question is answered: a file failure cannot cost an email or a claim.**

### SP-6 — Quota facts

| Question | Measured |
| --- | --- |
| `ContentPublicationLimit` | **2,500 / 2,500** at session start (the outage's `−69` had rolled off) |
| `ContentDocumentLink` insert | **ZERO** publications, verified at N=10 in one statement |
| New **version** of an existing document | **ONE each**, verified at N=5 (the delta was exactly 6, which also retro-confirmed an earlier single insert) |
| **Delete** | **No refund.** Four settled readings, unchanged. "Permanent cost" confirmed |
| Full-suite consumption | **NOT RUN** — deliberately, per instruction. Measure it during the build per `.claude/rules/content-publication-rule.md` (§13 step 7) |

🔴 **The REST `/limits` reading for this limit is measurably stale and non-monotonic** — a single
insert's cost was invisible across four consecutive settled reads, and two reads once moved *upward*
with no publish between them. Beyond spike methodology, this is an **independent, empirical** reason
never to build any check on it, advisory or otherwise: the number can be stale by an unknown,
multi-read margin.

---

## 6. DEGRADATION, HEAP AND QUOTA — the guards, with their arithmetic

The user's instruction is *"make sure we never hit our quota limit at any cost."* This section is
honest about what is achievable, and it now carries two guards, not one: **heap** (the new risk the
spikes surfaced) and **quota** (the old one).

### 6.1 The layers, ranked by what they actually buy

**Nothing in Apex can *guarantee* the quota is never hit.** M4 means there is no counter to read;
SP-6 means the REST reading is stale; the quota is org-wide and shared with every test run and
deploy. A self-maintained counter cannot see those and will always undercount. So:

| Layer | What it buys | Strength |
| --- | --- | --- |
| **L1 — isolation (§3)** | The quota being hit stops mattering: it costs a *deferred* file, not an email | 🥇 **Structural. This is the real answer, and SP-5 proved it.** |
| **L2 — recoverability** | Even a total failure loses nothing permanently — the bytes stay on the staging row and are retried | 🥇 **Structural.** New in v2; SP-4 is what makes it possible |
| **L3 — consume less** | ≤3 publications per email; **zero** on redelivery, on a gate, or on a re-run | 🥈 Deterministic |
| **L4 — reactive circuit breaker** | After the first real refusal, stop trying for a stated period | 🥉 Ground-truth driven (SP-3) |
| **L5 — predictive daily budget** | Stop before a self-imposed line well short of the cap | Probabilistic; undercounts by the test suite's usage |
| **L6 — test discipline** | `.claude/rules/content-publication-rule.md` | Already in force |

### 6.2 🔴 THE HEAP GATE ON THE CONVERSION — measured, not reasoned

**This is the guard the whole outage teaches us to get right: the last one was an unguarded heap
assumption.** So this gate is derived from a measurement, checked against a *pre*-read quantity, and
re-verified dynamically at the moment of allocation.

**The measurement (SP-4.5).** Converting one 5 MB `Attachment`:

```
heapBeforeRead   =      1,054
heapAfterRead    =  5,244,053     +5,243,000   the SOQL read allocates the full body
heapAfterBuild   = 10,487,036     +5,242,983   VersionData = att.Body allocates it AGAIN
heapAfterInsert  = 10,487,068     +32
heapAfterDelete  = 10,487,084     +16
```

**Peak ≈ 2 × total converted bytes**, plus a negligible base. Async ceiling is **12,000,000**.

**The constants, and the arithmetic that produced them:**

| Constant | Value | Derivation |
| --- | --- | --- |
| `CONVERT_MAX_TOTAL_BYTES` | **4,000,000** | 2 × 4,000,000 = **8.0 MB peak = 67% of 12 MB**, leaving 4 MB for the selector reads, the link list, the notes and any platform overhead. The spike's own recommendation was "materially below 5 MB (~3–3.5 MB)"; 4 MB is chosen because `ATTACHMENT_MAX_BYTES` is also 4 MB, so **any single retained file always fits one transaction by itself** and nothing can become permanently stuck. |
| `CONVERT_HEAP_CEILING` | **9,000,000** | The dynamic guard: 75% of 12 MB. Checked immediately before **each** `VersionData` assignment. Crossing it stops conversion and defers the remainder. |
| `ATTACHMENT_MAX_BYTES` | **4,000,000** (was 5,000,000) | Retention is aligned to convertibility, so the carrier can never hold a structurally unconvertible file. |

**🔴 THE MECHANISM THAT MAKES THIS A PRE-CHECK RATHER THAN A HOPE.** `Attachment.BodyLength` is
queryable **without** selecting `Body`. So `AttachmentPersistQueueable` reads metadata first
(`Id, Name, ContentType, BodyLength, ParentId` — no bytes in heap), decides which subset fits
`CONVERT_MAX_TOTAL_BYTES`, and only then issues a second query for the bodies of exactly that
subset. **The gate operates on the real byte counts before a single byte is allocated.** Two SOQL
instead of one is the price, and it is worth it.

**How the gate is verified, not assumed** (§8 and §14):
- an Apex test drives the subset selection with fabricated `BodyLength` values through a
  `@TestVisible` seam and asserts exactly which files are chosen and which are deferred — pure, no
  bytes, no quota;
- an Apex test asserts the job's own `lastRunHeapPeak` (recorded **inside** the async context) stays
  under `CONVERT_HEAP_CEILING` for a realistic multi-file fixture;
- 🔴 **UAT step U6 sends a real ~3.9 MB PDF and the recorded peak is read back from the debug log**,
  because only a real file exercises the real allocation. A green Apex suite does not establish this
  number.

### 6.3 L3 — consume less

1. 🔴 **Redelivery costs zero publications.** The file job is enqueued only from `finish()`, and the
   duplicate-delivery branch returns *without* calling `finish()`. v1 created a full duplicate set
   every time. **This is structural and fragile** — anyone who moves the enqueue out of `finish()`,
   or makes the skip path call `finish()`, re-opens it. The duplicate's own carrier rows are
   released on the skip path (§11.5) so they cannot accumulate.
2. **A gated email costs zero publications.** D2's hard gate and U2's call-for-offers gate produce
   no routed record, so `finish()` releases the carrier instead of enqueueing. That is the
   highest-volume junk in the pipeline and it now costs nothing.
3. ✅ **`MAX_ATTACHMENTS = 3`** (user decision, was 10). Ceiling per email is 3 publications and
   3 × 10 = 30 `ContentDocumentLink` rows. **The fourth and later retained files are dropped and
   NAMED** in `Dropped_Attachment_Notes__c` via the existing `REASON_COUNT_CAP` line — the cap is
   visible, never silent, exactly like the `[truncated: 10 of M]` property suffix.
4. Images are floored at 20 KB (G2) and non-CSV text attachments are dropped (G3) — unchanged.

**Working figure:** at 3/email, 100 broker emails a day costs **300** of 2,500.

### 6.4 🔴 THE CARRIER IS TEMPORARY — what removes it

An `Attachment` row on a staging row is a **carrier, not storage**. It is deleted **only** on
confirmed conversion, which is what makes failure loss-free — and which is exactly why something
must guarantee it does not linger forever.

**Four exits, and every carrier row takes one of them:**

| Exit | When | Who |
| --- | --- | --- |
| **Converted** | the file became a `ContentVersion` and its links committed | `AttachmentPersistQueueable` — deletes **only** the rows that converted, in the same transaction as the conversion |
| **Released** | the email was gated or was a duplicate delivery — there is no record to file a file on, and there never will be | `ExtractAddressQueueable.releaseCarrier()` on the gate/skip paths |
| **Retried** | conversion was deferred (heap subset), skipped (budget/breaker), or the job died | `AttachmentCarrierSweepBatch`, daily |
| **Expired** | still unconverted after `CARRIER_MAX_AGE_DAYS = 14` | `AttachmentCarrierSweepBatch` deletes it and stamps a terminal note |

**`AttachmentCarrierSweepBatch` (daily, scheduled) is the designed retry/replay capability**, not a
cleanup afterthought:

- **Scope 1 staging row per `execute()`**, so each row gets its own 12 MB async heap budget and the
  §6.2 gate applies unchanged.
- Selects `Inbound_Email_Staging__c` where `Attachment_Status__c IN ('Pending','Partial','Failed')`.
  This is precisely why `Attachment_Status__c` is **required**, not optional (§10.2): a Long Text
  notes field cannot be a work queue.
- Honours the breaker and the daily budget exactly as the live job does, so a sweep during an
  exhausted window defers rather than hammers.
- At `CARRIER_MAX_AGE_DAYS`, deletes and stamps `Attachment_Status__c = 'Expired'` plus a note. **14
  days** is chosen because it is longer than any quota window (24 h) or plausible outage, and short
  enough that carriers cannot silently become the org's file-storage strategy.
- **Idempotent and convergent by construction**: it only ever acts on rows whose status says work
  remains, and a successful pass moves the status. Re-running it is free.

### 6.5 L4 — the reactive circuit breaker (SP-3 confirmed the mechanism)

When `AttachmentPersistQueueable` dies, `AttachmentPersistFinalizer` runs **in a fresh transaction
after the rollback** (SP-3, measured) and:

1. appends the durable failure note to `Dropped_Attachment_Notes__c` (§7);
2. sets `Attachment_Status__c = 'Failed'`, which is what puts the row back in the sweeper's queue;
3. **trips the breaker if — and only if —**
   `ctx.getException().getMessage().contains('ContentPublication Limit exceeded')`.

🔴 **Substring, never a type check.** SP-3 measured the platform wrapping the original
`UnexpectedException` as `System.AsyncException`, with the real type and message preserved only as
text inside the wrapper. A `instanceof System.UnexpectedException` test would silently never match
and the breaker would never trip. **The substring test lives in its own pure static method so it can
be unit-tested against the verbatim message from the 2026-08-06 outage log** — that test is the only
Apex-provable part of the breaker.

While tripped, the file job and the sweeper record "suspended until X" and issue **no**
`ContentVersion` DML. `BREAKER_SUSPEND_HOURS = 24`, matching the rolling quota window; it clears
automatically at expiry and can be cleared manually by editing the setting.

### 6.6 L5 — the predictive daily budget

A counter incremented **after** a successful publish; the job stops when the line is reached.

- **`DAILY_PUBLICATION_BUDGET = 1,000`.** The quota window is rolling-24h, so a per-calendar-day
  budget of 1,000 bounds any rolling window at ≤ 2,000 < 2,500, leaving ≥ 500 for test runs and
  deploys. At `MAX_ATTACHMENTS = 3` this is ~333 attachment-bearing emails a day — far above real
  volume, which is the point: it is a backstop, not a throttle.
- **Storage: a hierarchy Custom Setting, `Content_Publication_Budget__c`.** Reads cost **zero SOQL**,
  which is why it is preferred over a custom object. ⚠ **There is no Custom Setting anywhere in this
  repo today**, so this introduces a metadata type the project has not used; and **custom-setting
  DATA is not deployable**, so the Apex must create the org-default row on first use.
- **Concurrency:** two concurrent jobs will undercount (last-write-wins). **Accepted deliberately** —
  that is why the line sits 1,500 below the cap. Do **not** add a `FOR UPDATE` lock; row locks are
  held to commit and this one would serialise unrelated emails.
- **The counter always undercounts by the test suite's usage** (M7 — rollback does not refund), which
  is the second reason for the headroom.
- 🔴 **Naming trap, the same one v1 caught.** `Publications_Used__c` matches
  `<Subject>_<PastParticiple>`, which §1 rule 4 **reserves for Booleans**. Use
  **`Publication_Count__c`**. Companions: `Window_Start_DateTime__c` (rule 9), `Is_Suspended__c`
  (rule 4), `Suspended_Until_DateTime__c`.

### 6.7 Considered and rejected

- **`EventBus.publish` immediate-publish as a failure signal.** SP-3 made the Finalizer the direct
  answer, so the dead-man's-switch pattern is not needed. Rejected — it would cost a platform-event
  definition, a subscriber trigger and daily allocations to answer a question already answered.
- **Any `/limits` check, even advisory.** Rejected on three independent grounds now: §3.1 ASB-only,
  `.claude/rules/content-publication-rule.md`'s explicit prohibition, and **SP-6's measurement that
  the value is stale and non-monotonic**.

---

## 7. `Dropped_Attachment_Notes__c` — what it says in each mode

The field's existing format is `filename | mime | bytes | reason`, one line per item, and it already
carries the refusal lines from `linkTo`. Below, only the **reason** column changes.

Every mode writes **both** a `Dropped_Attachment_Notes__c` line and an `Attachment_Status__c` value.
The status is what the sweeper queries; the note is what a human reads.

| Mode | Written by | `Attachment_Status__c` | Note text (substance; exact strings are named constants) |
| --- | --- | --- | --- |
| No attachments at all | handler | `None` | *(no note)* |
| Classification drops — type, size, image floor, **count cap (now 3)**, heap floor, non-CSV text | handler, rules unchanged | unaffected | existing `REASON_*` constants, with the two changed numbers |
| Vision skip | handler, unchanged | unaffected | `not sent to the LLM: exceeds VISION_MAX_BYTES (1000000)` |
| Carrier written, conversion not yet attempted | handler | **`Pending`** | *(no note — this is the normal state for a few seconds)* |
| 🔴 **Carrier insert refused** (ordinary, catchable) | `stageBytes` | `Not Saved` | `carrier not written | <STATUSCODE>: <message>` — the bytes are gone; say so plainly |
| **All files converted** | file job | **`Saved`** | *(no note)* |
| **Deferred by the heap gate** (§6.2 subset) | file job | **`Partial`** | `not yet saved: deferred by the conversion heap budget (CONVERT_MAX_TOTAL_BYTES 4000000); the file is still attached to this staging row and will be retried` |
| **Daily budget reached** (§6.6) | file job | **`Partial`** or `Failed` | `not yet saved: daily publication budget reached (N of 1000); the file is still attached to this staging row and will be retried` |
| **Breaker tripped** (§6.5) | file job | **`Failed`** | `not yet saved: ContentPublication limit reached, persistence suspended until <ts>; the file is still attached to this staging row and will be retried` |
| **Individual `ContentVersion` refused** (ordinary) | `persist`, unchanged | `Partial` | `file not saved: <STATUSCODE>: <message>` |
| **Link refused** | `linkTo` → `appendDroppedNote`, unchanged | `Partial` | `link refused | <recordId> | <STATUSCODE>: <message>` |
| 🔴 **The file job died with an unhandled exception** | **Finalizer**, in a fresh transaction | **`Failed`** | `NOT SAVED: the file job failed — <wrapped message>. The Lead, the claim, this row AND THE ATTACHED FILE BYTES are all intact; it will be retried. AsyncApexJob <id>.` |
| **Released — gated email or duplicate delivery** | `ExtractAddressQueueable.releaseCarrier()` | **`Not Saved`** | `not saved: the email was gated or was a duplicate delivery — there is no record to file it on. The file exists only in the original email.` |
| **Expired after 14 days** | sweeper | **`Expired`** | `NOT SAVED: the carrier expired after CARRIER_MAX_AGE_DAYS (14) without a successful conversion. The file exists only in the original email.` |
| Persistence disabled entirely | handler, existing | — | `PERSISTENCE_DISABLED_BANNER` + `REASON_PERSISTENCE_DISABLED` — 🔴 **DELETE BOTH** as part of this change, per their own Javadoc |

**Three rules for every line above:**

1. 🔴 **Distinguish "not yet saved, and recoverable" from "not saved, and gone."** This is the whole
   point of the carrier and the single most important thing the copy must convey. Only three modes
   are terminal — *carrier insert refused*, *released*, and *expired*. Everything else says
   **"the file is still attached to this staging row and will be retried."**
2. **Every terminal mode names where the file still exists** — the original email.
3. 🔴 **A blank `Dropped_Attachment_Notes__c` still never means "no attachment was sent"** — an
   oversized email is rejected above Apex and produces no row at all (§4 item 1).

---

## 8. TESTING — how a green suite is made to mean something

### 8.1 Why v1's acceptance test could not possibly have caught this

`EmailToLeadHandlerTest.handleInboundEmail_forcedPersistFailure_stillSucceedsAndRoutesNormally`
armed `InboundEmailAttachmentService.forcePersistFailure`, which threw
`AttachmentException` — **an ordinary, catchable Apex exception**. The test then asserted that
`persist`'s catch held and `result.success` stayed `true`. It passed throughout the outage.

The generalisable lesson, and it is the important sentence in this document:

> 🔴 **When the risk is "this transaction dies", no assertion written inside that transaction can
> observe it.** A test that proves *the catch works* is structurally incapable of detecting a
> failure that *bypasses the catch*. The seam has to model the real failure mode, and this one
> cannot be modelled in Apex at all.

A second, quieter trap: **inside a test, everything is one transaction.** So a test can never
demonstrate "the staging row committed by transaction 1 survives the rollback of transaction 3" —
the very property this design exists to provide. Any test claiming to prove isolation is lying.

### 8.2 Tier 1 — STRUCTURAL assertions (Apex; the primary control; deterministic)

Do not assert behaviour under failure. **Assert the absence of the dangerous operation from the
protected transactions.** The current reverted test suite already contains exactly this shape and
it should be promoted from a temporary "disabled" note to the permanent contract:

| # | Assertion | Where | Fails when |
| --- | --- | --- | --- |
| T1 | `[SELECT COUNT() FROM ContentVersion] == 0` after `handleInboundEmail` returns | `EmailToLeadHandlerTest` (exists today, lines ~392 / 430 / 485 / 510 / 537 / 661) | anyone re-introduces a `ContentVersion` insert at the boundary |
| T2 | handler DML count is **exactly 2** (staging + carrier), and **exactly 1** with zero attachments | `EmailToLeadHandlerTest` (extend the existing pin at line ~640) | a third statement appears at the boundary |
| T3 | `[SELECT COUNT() FROM ContentVersion] == 0` after `ExtractAddressQueueable.execute` | `ExtractAddressQueueableTest` | anyone moves the insert into routing |
| T4 | `lastRunDmlCount` equals the exact no-attachment baseline — **7** at N=1, **43** at N=10 | `ExtractAddressQueueableTest` | routing starts doing file DML |
| T5 | the file job's budget is **exactly 3 SOQL / 5 DML**, at 1 file × 1 target and at 3 files × 10 targets | new `AttachmentPersistQueueableTest` | a per-file or per-target loop appears |
| T6 | the heap-gate subset selection, driven by fabricated `BodyLength`s through a seam | `AttachmentPersistQueueableTest` | the gate stops being a pre-check |
| T7 | `isPublicationLimitFailure('<verbatim outage message>')` is `true`; a type check is not used | `AttachmentPersistFinalizerTest` | someone "tidies" the substring match into an `instanceof` |

**T1–T4 are the regression net.** They go red on the exact change that caused the outage and cost
nothing to run. **T7 is the only Apex-provable part of the circuit breaker** — pin it against the
verbatim message from the 2026-08-06 log, not a paraphrase.

### 8.3 What Apex CANNOT prove here — say it, do not paper over it

| Property | Apex-provable? | Why not, and what proves it instead |
| --- | --- | --- |
| The `ContentVersion` insert is absent from Transactions 1 and 2 | ✅ **Yes** | T1–T4 |
| The heap-gate arithmetic on real bytes | ⚠ **Partly** | T6 proves the *selection*; only a real multi-MB file exercises the real allocation → **UAT U6** |
| `finish()` actually chains the file job | ❌ **No** | SP-2: the chain throws inside `@isTest`. Assert the **decision** through the `Test.isRunningTest()`-guarded seam; the firing is proven by **UAT U1** |
| A file-job failure does not harm the Lead/claim/staging | ❌ **No** | Inside `@isTest` everything is one transaction. SP-5 proved the platform behaviour; **UAT U8** proves it for *this* pipeline |
| The breaker trips on the real exception | ⚠ **Partly** | T7 proves the detector. The real exception needs an exhausted quota → **optional UAT U9** |

### 8.4 Tier 2 — the ISOLATION REHEARSAL (in-org, cheap, MANDATORY)

Tier 1 proves the insert is not in the protected transactions. It cannot prove that a failure in the
file job is harmless *for this pipeline*. That requires a real, multi-transaction execution — **UAT
step U8** (§14): send a real broker email with a PDF, force the file job to die with an unhandled
exception via the `forcePersistFailure` seam, and verify **from the org** that the Lead, claim, Task
and staging row are intact, the carrier `Attachment` is **still there**, `AsyncApexJob` shows
`Failed`, the Finalizer's note landed, and the next sweeper pass converts it successfully.

This reproduces the rollback shape faithfully, costs **zero quota**, and additionally proves the
retry capability. **It is the acceptance test for the whole redesign.**

### 8.5 Tier 3 — the QUOTA REHEARSAL: ✅ RESOLVED as NOT REQUIRED before go-live

**Decision (Q-7): optional, run opportunistically. Tier 2 is sufficient.** The pre-spike draft
recommended requiring it; the spikes made it unnecessary, and this is a change of position taken on
evidence:

- **SP-5** measured transaction isolation directly — the property the rehearsal existed to confirm.
- **SP-3** measured the Finalizer firing, committing DML and preserving the message **on a
  `System.UnexpectedException` specifically**, which is the exact exception family.
- **T7** pins the substring detector against the verbatim outage message.
- Under the carrier design a quota failure is no longer a loss at all — it is a **deferral**, and
  the sweeper converts it later.

Running it would burn up to 2,500 publications and take 24 h to recover, to re-confirm three things
already measured separately. **If it is run** (UAT U9), do it at the end of a working day, announce
it, and never on a day with deploys planned.

### 8.6 Anti-vacuity rules for every new test — this program's THIRD instance

1. **Assert the precondition first.** Follow the existing exemplar: *"Precondition: the winner claim
   must succeed, or the budget assertions below prove nothing"* (`ExtractAddressQueueableTest`
   line ~3660). Every file test must first prove the file was created/linked before asserting
   anything about counts or budgets.
2. 🔴 **The chain is guarded, so assert the DECISION, not the effect** — a `@TestVisible` static
   recording that the enqueue was requested and with which targets. This is the
   `EmailThreadAdopterService` `AdoptionWriter` precedent: when the platform refuses an operation in
   test context, assert the decision through a seam and put the real proof in UAT. **Say so in the
   test's comment**, or a reviewer will "fix" it into something vacuous.
3. 🔴 **Any test that deliberately fails the job must wrap `Test.stopTest()` in `try/catch`** —
   SP-3 measured the unhandled exception propagating out of `stopTest()` in test context (it does
   not in production). Without the wrapper the test reports as broken rather than as a passing
   assertion of the failure path. **Put SP-3's finding in the test's comment**, because the wrapper
   looks like a mistake to anyone who has not read this.
4. **Counters come from the job's own `lastRun*` statics, never `Limits.*` after `Test.stopTest()`**
   — stopTest restores the pre-test counters and makes the obvious assertion silently vacuous.
5. 🔴 **`.claude/rules/content-publication-rule.md` governs every content-touching test.**
   `AttachmentPersistQueueableTest` becomes the **only** place in the suite that inserts
   `ContentVersion`; handler and routing tests insert **zero** (T1/T3 assert exactly that). Keep the
   class total **≤ 20 rows**, state the number in its header, and **re-measure the suite total**
   (SP-6.5, unrun) during the build — this change should reduce it further from 93.
6. **`.claude/rules/bulk-test-rule.md`:** state in the file job's test header why a literal 251 is
   not applied — it is per-transaction-singleton (one inbound email → one job) **and** content-capped
   by the rule above. Volume proof is `MAX_ATTACHMENTS` (3) files × `MAX_PROPERTIES` (10) targets,
   asserted as **one bulk statement**, not as a row count. The sweeper batch, being a genuine batch,
   is proven at 251 **staging rows** — which is free, because those rows carry no content.

---

### 8.7 THE FULL TEST LIST

**`AttachmentPersistQueueableTest` (NEW — the only class in the suite that inserts `ContentVersion`; ≤ 20 rows total)**

| # | Test | Proves |
| --- | --- | --- |
| 1 | `execute_oneCarrier_convertsLinksAndDeletesTheCarrier` | the happy path end to end; carrier gone, `Attachment_Status__c = 'Saved'` |
| 2 | `execute_pinsGovernorBudgetAtThreeSoqlFiveDml` | T5 at 1 file × 1 target |
| 3 | `execute_threeFilesTenTargets_stillThreeSoqlFiveDml` | T5 at the cap — one bulk statement each, never per file or per target |
| 4 | `execute_linksToStagingWithVAndToRoutedRecordsWithI` | the `ShareType` split survives the move |
| 5 | `heapGate_selectsTheSubsetThatFitsAndDefersTheRest` | T6, via the `BodyLength` seam — pure, no bytes |
| 6 | `heapGate_singleFileOverTotalBudget_isNeverPermanentlyStuck` | any file ≤ `ATTACHMENT_MAX_BYTES` fits one transaction alone |
| 7 | `execute_deferredFile_leavesTheCarrierAndStampsPartial` | deferral is recoverable, not a loss |
| 8 | `execute_budgetReached_convertsNothingAndStampsPartial` | §6.6, no `ContentVersion` DML at all |
| 9 | `execute_breakerTripped_convertsNothingAndRecordsSuspendedUntil` | §6.5 |
| 10 | `execute_missingCarrier_isANoOpAndThrowsNothing` | a released/expired row cannot break the job |
| 11 | `execute_partialRefusal_recordsItAndKeepsThatCarrier` | only converted rows are deleted |
| 12 | `execute_recordsHeapPeakForTheBudgetAssertion` | `lastRunHeapPeak` telemetry is captured inside the async context |

**`AttachmentPersistFinalizerTest` (NEW)**

| # | Test | Proves |
| --- | --- | --- |
| 13 | `isPublicationLimitFailure_verbatimOutageMessage_isTrue` | **T7** — pinned against the 2026-08-06 log text |
| 14 | `isPublicationLimitFailure_wrappedAsyncExceptionText_isTrue` | SP-3's wrapper shape, not a type check |
| 15 | `isPublicationLimitFailure_ordinaryDmlMessage_isFalse` | the breaker does not trip on unrelated failures |
| 16 | `finalizer_onUnhandledException_stampsFailedAndNotesIt` | ⚠ wraps `Test.stopTest()` in `try/catch` (§8.6.3) |

**`InboundEmailAttachmentServiceTest` (EXTEND)**

| # | Test | Proves |
| --- | --- | --- |
| 17 | `classify_fourthRetainableFile_isDroppedAndNamed` | `MAX_ATTACHMENTS = 3`, visibly |
| 18 | `classify_fileOverFourMillionBytes_isDroppedAndNamed` | the new `ATTACHMENT_MAX_BYTES` |
| 19 | `stageBytes_writesOneBulkAttachmentInsert` | one statement regardless of file count |
| 20 | `stageBytes_csvTextAttachment_convertsToBlobUnderTextMaxBytes` | the relocated `TEXT_MAX_BYTES` guard |
| 21 | `stageBytes_refusal_isRecordedAndDoesNotThrow` | a carrier refusal is terminal but harmless |
| 22 | *(existing `classify` table-driven tests)* | G1/G2/G3 unchanged |

**`EmailToLeadHandlerTest` (EXTEND — must still insert ZERO `ContentVersion`)**

| # | Test | Proves |
| --- | --- | --- |
| 23 | `handleInboundEmail_pdf_writesCarrierAndStampsPending` | the boundary's new job |
| 24 | `handleInboundEmail_pinsGovernorBudgetAtZeroSoqlTwoDml` | **T2** |
| 25 | `handleInboundEmail_zeroAttachments_pinsZeroSoqlOneDml` | additive-cost proof |
| 26 | `handleInboundEmail_createsNoContentVersion` | **T1**, retained verbatim from today |

**`ExtractAddressQueueableTest` (EXTEND / RE-PIN)**

| # | Test | Proves |
| --- | --- | --- |
| 27 | `finish_withCarrier_recordsTheEnqueueDecision` | the guarded-chain seam (§8.6.2) |
| 28 | `finish_noCarrier_recordsNoEnqueue` | zero cost when nothing is attached |
| 29 | `finish_gatedEmail_releasesTheCarrierAndEnqueuesNothing` | §6.3 item 2 |
| 30 | `execute_duplicateDelivery_releasesTheCarrierAndEnqueuesNothing` | §6.3 item 1 |
| 31 | *(re-pin)* `…singlePropertyDmlBudget = 7` | **T4** at N=1 |
| 32 | *(re-pin)* `…DML_BUDGET = 43` | **T4** at N=10 |
| 33 | `execute_createsNoContentVersion` | **T3** |

**`AttachmentCarrierSweepBatchTest` (NEW)**

| # | Test | Proves |
| --- | --- | --- |
| 34 | `sweep_pendingRow_convertsAndStampsSaved` | retry is real |
| 35 | `sweep_partialRow_convertsTheRemainderOnly` | multi-pass conversion converges |
| 36 | `sweep_rowOlderThanFourteenDays_expiresTheCarrierAndNotesIt` | carriers cannot accumulate |
| 37 | `sweep_breakerTripped_defersAndConvertsNothing` | the sweep cannot hammer an exhausted quota |
| 38 | `sweep_at251StagingRows_isBulkSafe` | `bulk-test-rule` at 251 **content-free** rows |
| 39 | `sweep_isConvergent_secondPassWritesNothing` | re-running is free |

**`AttachmentSelectorTest` (NEW)** — 40 `selectMetadataByParentIds_selectsNoBody`, 41
`selectBodiesByIds_nullOrEmpty_shortCircuits`, 42 `selectBodiesByIds_returnsOnlyTheRequestedSubset`.

---

## 9. GOVERNOR BUDGETS TO PIN

Stated as deltas from today's measured values. **Any change here is a Gate-2 review item.**

| Scenario | SOQL | DML | Note |
| --- | --- | --- | --- |
| `EmailToLeadHandler`, ≥1 retained attachment | **0** — unchanged | **2** *(was 1)* | staging insert + **one bulk** `Database.insert(attachments, false)`. 🔴 **Constant regardless of file count.** Caps are 100 / 150. |
| `EmailToLeadHandler`, zero attachments | **0** | **1** | the guard makes the feature provably zero-cost when nothing is attached |
| `ExtractAddressQueueable`, single property | **30** ceiling — unchanged | **7** exact | 🔴 **`singlePropertyDmlBudget` 8 → 7.** Routed linking has left `finish()`. |
| `ExtractAddressQueueable`, 10 properties | **120** ceiling — unchanged | **43** exact | 🔴 **`DML_BUDGET` 44 → 43.** Same reason. |
| `ExtractAddressQueueable`, **gate / duplicate-delivery path only** | unchanged | **+1** on that path | `releaseCarrier()`'s delete. It cannot move the two pinned budgets above, which are winner-path scenarios. |
| **`AttachmentPersistQueueable`** (NEW) | **3** exact | **5** exact | SOQL: metadata (no `Body`) + bodies-of-the-subset + `ContentVersionSelector`. DML: `ContentVersion` insert + staging links + routed links + carrier delete + budget-counter update. 🔴 **Constant regardless of file count AND target count** — that is the load-bearing property. |
| **`AttachmentCarrierSweepBatch`**, per `execute()` (scope 1) | **3** | **5** | identical to the job it replays; scope 1 keeps the §6.2 heap gate valid per transaction |

**Outside every pinned success-path budget, as today:** the failure-path
`InboundEmailStagingService.appendDroppedNote` (+1 SOQL / +1 DML) and the Finalizer's own writes
(a separate transaction entirely). Say so in the Javadoc, or a reader will score the budget as
violated.

**`System.enqueueJob` is not DML** and moves no budget — but it consumes the routing job's single
chained-job slot (SP-2). **The hierarchy Custom Setting read is 0 SOQL**, which is why it was chosen
over a custom object.

**Two heap numbers are pinned as well, and they matter more than the statement counts:**

| Where | Pin | Asserted by |
| --- | --- | --- |
| `AttachmentPersistQueueable.lastRunHeapPeak` | **< `CONVERT_HEAP_CEILING` (9,000,000)** | test 12; read back from the log at UAT U6 |
| `EmailToLeadHandler`, synchronous | worst case ≈ 3.67 MB (vision) + 2 MB (a 1 MB CSV and its Blob copy) ≈ **5.67 MB of 6 MB** | unchanged from today; `HEAP_HEADROOM_FLOOR` is the dynamic guard |

🔴 **Every re-pinned constant needs an inline comment saying why it moved** — e.g. *"−1 = routed
linking moved out of `finish()` into `AttachmentPersistQueueable`, 2026-08-06"*. A budget that moves
without an explanation is indistinguishable from a regression that was accommodated.

---

## 10. 🔵 ADMIN WORK (`salesforce-admin`)

### 10.1 ✅ DONE — `Email To Lead` over-limit action reads `Bounce`

Verified twice in-org. The `EmailServicesFunction` is **not in the repo and must stay that way**;
record the change in the deployment log only. While in Setup, record the actual attachment/message
size ceilings for the coordinator runbook — **do not hard-code them anywhere in Apex.**

**Two things to write down rather than assume:**

1. **The other three failure actions remain `Discard`, deliberately.** Bouncing an *authentication*
   or *unauthorized-sender* failure emits backscatter to a spoofed sender, which is worse than
   silence. Only the over-limit action benefits from `Bounce`.
2. 🔴 **No Email Service setting covers a handler-failure path** (§4 item 1b). When the handler dies
   with an uncaught `FATAL_ERROR`, `InboundEmailResult` is never returned and none of the five
   actions applies. **Configuration was never the remedy for the outage's invisibility** — §3.4's
   transaction structure is.

### 10.2 REQUIRED metadata — all approved, build all of it

| # | Item | Notes |
| --- | --- | --- |
| A1 | **`Inbound_Email_Staging__c.Attachment_Status__c`** — Picklist, values `None`, `Pending`, `Saved`, `Partial`, `Failed`, `Not Saved`, `Expired` | §1 rule 7 (`Status__c` suffix). 🔴 **Required, not optional** — it is the sweeper's work queue (§6.4); a Long Text notes field cannot be one. Default blank; the handler always stamps it. |
| A2 | **`Content_Publication_Budget__c`** — **hierarchy Custom Setting**, fields `Publication_Count__c` (Number 18,0), `Window_Start_DateTime__c` (DateTime), `Is_Suspended__c` (Checkbox), `Suspended_Until_DateTime__c` (DateTime) | 🔴 **Not `Publications_Used__c`** — §1 rule 4 reserves the past-participle form for Booleans (the same trap `Attachments_Dropped__c` was caught by in v1). **First Custom Setting in this repo.** Custom-setting *data* is not deployable, so the Apex creates the org-default row on first use — do not hand-create it and do not expect it in source control. |
| A3 | **FLS** for `Attachment_Status__c` on `Broker_Protection_Access`, and update the in-file verification comment **`Inbound_Email_Staging__c 22 → 23`** | Custom Settings need no FLS grant for Apex access. |
| A4 | **`Inbound_Email_Staging__c` page layout** — ensure **both** the **Files** related list and the **Notes & Attachments** related list are present, and add `Attachment_Status__c` | No layout exists in the repo; the object uses the org default, so this must be authored and deployed or verified in-org. 🔴 **Notes & Attachments is newly load-bearing** — it is where a human recovers the bytes of a file that never converted. Without it the carrier is invisible and the whole recoverability story is theoretical. |
| A5 | **Schedule `AttachmentCarrierSweepSchedule`** — daily, off-peak | Scheduled-job *instances* are not deployable metadata; schedule it in-org (or via anonymous Apex) after deploy and record it in the deployment log. **A deploy that skips this silently disables all retry.** |

### 10.3 FLS rule for anything new

Grant read + edit on **`Broker_Protection_Access`**, where all 22 sibling
`Inbound_Email_Staging__c` field permissions already live, and **update the XML verification-comment
counts in the same file**. Keep the comment **inside the root element** (a comment above the root
breaks `sf` deploy with a misleading "unable to find matching parent xml file") and **never** put it
in `<description>` (255-char cap; it has made this file undeployable once).

### 10.4 Explicitly NOT included

No validation rules, no new permission sets, no flows, no reports, no list views, and **no
Content-object permissions** (S1: Content is license-gated — there is nothing to grant, and a
speculative `<objectPermissions>` entry would corrupt the permission set's own verification counts).
None were requested and none are required.

**Two items that look like admin work but are not deployable metadata**, so they live in the
post-deploy checklist (§13 step 6) rather than in a package: the `Content_Publication_Budget__c`
**org-default row** (custom-setting data is created by Apex on first use) and the
`AttachmentCarrierSweepSchedule` **schedule** (job instances are in-org). 🔴 Missing the second one
silently disables every retry path in this design, which is exactly the class of silent gap the
feature exists to remove — so it is a recorded, verified deploy gate, not a note.

---

## 11. 🟢 DEVELOPMENT WORK (`salesforce-developer`)

Layering per `.claude/rules/apex-layering-rule.md`: all SOQL in a selector, the service owns the DML,
the queueable orchestrates and holds neither. API version **67.0** for every new class.

### 11.0 File-by-file work list

| # | File | Change | Layer |
| --- | --- | --- | --- |
| 11.1 | `classes/AttachmentSelector.cls` (+ meta) | **NEW** | Selector |
| 11.2 | `classes/AttachmentPersistQueueable.cls` (+ meta) | **NEW** | Queueable orchestrator |
| 11.3 | `classes/AttachmentPersistFinalizer.cls` (+ meta) | **NEW** | Finalizer |
| 11.4 | `classes/AttachmentCarrierSweepBatch.cls` (+ meta) | **NEW** | Batch |
| 11.5 | `classes/AttachmentCarrierSweepSchedule.cls` (+ meta) | **NEW** | Schedulable |
| 11.6 | `classes/ContentPublicationBudget.cls` (+ meta) | **NEW** | Service (budget + breaker) |
| 11.7 | `classes/InboundEmailAttachmentService.cls` | MODIFIED — `stageBytes`, constants, header rewrite | Service |
| 11.8 | `classes/EmailToLeadHandler.cls` | MODIFIED — call `stageBytes`, drop the DISABLED banner, 3-arg enqueue | Boundary |
| 11.9 | `classes/ExtractAddressQueueable.cls` | MODIFIED — 3-arg constructor, `enqueueAttachmentPersist`, `releaseCarrier` | Queueable orchestrator |
| 11.10 | `classes/InboundEmailStagingService.cls` | MODIFIED — `attachmentStatus` on the request; `markAttachmentStatus` | Service |
| 11.11 | `classes/InboundEmailStagingSelector.cls` | MODIFIED — select `Attachment_Status__c` | Selector |
| 11.12 | `classes/ContentVersionSelector.cls` | MODIFIED — **header only** | Selector |
| 11.13 | Tests — the full list is §8.7 | NEW + MODIFIED | Test |
| 11.14 | `ARCHITECTURE.md`, `docs/2026-08-05-inbound-email-attachments.md` | **MODIFIED — same PR, mandatory** | Docs |

**Not modified, deliberately:** `LeadConvertService`, `LeadConvertTrigger`,
`InboundEmailActivityService`, `LLMExtractionCalloutService`, `PropertyClaimService`,
`PropertyMatchingService`, `InboundEmailFieldUtil`, `ContentDocumentLinkSelector`, and every LLM
prompt/fixture. **`InboundEmailAttachmentService.persist(...)` and `.linkTo(...)` keep their bodies
and signatures unchanged** — only their caller moves.

### 11.1 `AttachmentSelector` (NEW — Selector, `with sharing`)

The **first `Attachment` SOQL in the application** (same framing as `AccountSelector`,
`OpportunityContactRoleSelector`, `ContentVersionSelector`). Every future `Attachment` read belongs
here. Add it to `ARCHITECTURE.md` §2's `SYSTEM_MODE` automation-path table.

```apex
// NO Body — this is what makes the §6.2 heap gate a PRE-check. Never add Body here.
public static List<Attachment> selectMetadataByParentIds(Set<Id> parentIds)
    // SELECT Id, Name, ContentType, BodyLength, ParentId FROM Attachment
    // WHERE ParentId IN :parentIds ORDER BY BodyLength ASC WITH SYSTEM_MODE
    // null/empty -> empty list.

public static List<Attachment> selectBodiesByIds(Set<Id> ids)
    // SELECT Id, Name, ContentType, BodyLength, ParentId, Body FROM Attachment
    // WHERE Id IN :ids WITH SYSTEM_MODE     <- allocates BodyLength bytes PER ROW
    // null/empty -> empty list.
```

🔴 **The two-method split is load-bearing, not tidiness.** Selecting `Body` allocates the bytes; the
gate must decide *before* that. A future editor who merges them re-opens the heap risk. Say so at
both declarations. `ORDER BY BodyLength ASC` makes the deferral deterministic — small files convert
first, so one oversized file cannot starve three small ones.

`WITH SYSTEM_MODE`, justified at each declaration: the job runs as whichever principal the chain
executes under, on `Minimum Access`; `USER_MODE` throws rather than degrades and would disable
conversion silently. SYSTEM_MODE lifts FLS/CRUD only — the class's `with sharing` still governs
record visibility.

### 11.2 `AttachmentPersistQueueable` (NEW — Queueable orchestrator, `with sharing`)

The transaction that owns nothing else. Naming follows the repo's `<Feature>Queueable` convention.

```apex
public with sharing class AttachmentPersistQueueable implements Queueable {

    @TestVisible private static final Integer CONVERT_MAX_TOTAL_BYTES = 4000000;
    @TestVisible private static final Integer CONVERT_HEAP_CEILING    = 9000000;

    @TestVisible private static Integer lastRunQueryCount;
    @TestVisible private static Integer lastRunDmlCount;
    @TestVisible private static Integer lastRunHeapPeak;
    @TestVisible private static Integer lastRunConvertedCount;
    @TestVisible private static Integer lastRunDeferredCount;
    @TestVisible private static Integer heapSizeOverride;      // TEST-ONLY, never set in production

    private final Id stagingId;
    private final List<Id> targets;      // Ids ONLY. NEVER bytes. See SP-1.

    public AttachmentPersistQueueable(Id stagingId, List<Id> targets)
    public void execute(QueueableContext ctx)

    /** PURE. The §6.2 gate. Chooses the largest prefix of `rows` (ascending BodyLength)
     *  whose BodyLength sum is <= CONVERT_MAX_TOTAL_BYTES. Returns the chosen Ids. */
    @TestVisible private static Set<Id> chooseConvertibleSubset(List<Attachment> rows)
}
```

`execute()`, in this exact order:

1. `System.attachFinalizer(new AttachmentPersistFinalizer(stagingId))` — **FIRST STATEMENT**, before
   anything that can fail, or a failure has no reporter.
2. `ContentPublicationBudget.check(n)` → suspended or over budget ⇒ record, stamp, **return**. Never
   throw.
3. `AttachmentSelector.selectMetadataByParentIds` → `chooseConvertibleSubset(...)`.
4. `AttachmentSelector.selectBodiesByIds(chosen)`; build `AttachmentRequest` DTOs from the rows.
5. Re-read `Limits.getHeapSize()` before **each** `VersionData` assignment inside `persist` (that
   re-check already exists in `persist`'s CSV branch — extend it to every row and raise its
   comparand to `CONVERT_HEAP_CEILING`).
6. `InboundEmailAttachmentService.persist(stagingId, retained)` — **unchanged**.
7. `InboundEmailAttachmentService.linkTo(documentIds, targets)` — **unchanged**, once, bulk.
8. `Database.delete(convertedCarriers, false)` — **only the rows that converted**.
9. `ContentPublicationBudget.record(convertedCount)`.
10. `InboundEmailStagingService.markAttachmentStatus(stagingId, status, note)`.
11. `finally { lastRunQueryCount = Limits.getQueries(); lastRunDmlCount = Limits.getDmlStatements(); }`

Class header must carry: the outage in one paragraph; the design rule; **SP-4's 10.49 MB
measurement** and the arithmetic behind both constants; the invariant that `linkTo` is called
**once**, never per file or per target; and the note that the redelivery guarantee lives in
`ExtractAddressQueueable.finish()`, not here. **Not `Database.AllowsCallouts`** — it makes none.

### 11.3 `AttachmentPersistFinalizer` (NEW — Finalizer)

```apex
public with sharing class AttachmentPersistFinalizer implements System.Finalizer {
    @TestVisible private static final String PUBLICATION_LIMIT_TOKEN = 'ContentPublication Limit exceeded';
    private final Id stagingId;
    public AttachmentPersistFinalizer(Id stagingId)
    public void execute(System.FinalizerContext ctx)

    /** 🔴 SUBSTRING, NEVER A TYPE CHECK. SP-3 measured the platform WRAPPING an
     *  UnexpectedException as System.AsyncException, preserving the original type and
     *  message only as text inside getMessage(). An `instanceof` test silently never
     *  matches and the breaker never trips. Pinned by test 13 against the verbatim
     *  2026-08-06 outage message. */
    @TestVisible private static Boolean isPublicationLimitFailure(String message)
}
```

On `ParentJobResult.UNHANDLED_EXCEPTION`: append the §7 note, stamp
`Attachment_Status__c = 'Failed'` (which re-queues the row for the sweeper), and trip the breaker
when `isPublicationLimitFailure(...)`. Everything it does is itself wrapped — **a failure to record
a failure must not become a second failure.**

> `EmailCaptureQueueable`'s header explains why *it* deliberately has no Finalizer (self-healing,
> convergent work with nothing to compensate). **That reasoning does not transfer**, and the header
> must say so: this job's failure would otherwise destroy the only record of itself. Two classes,
> opposite decisions, both correct.

### 11.4 `AttachmentCarrierSweepBatch` (NEW — Batch) and 11.5 `AttachmentCarrierSweepSchedule`

```apex
public with sharing class AttachmentCarrierSweepBatch
        implements Database.Batchable<SObject>, Database.Stateful {
    @TestVisible private static final Integer CARRIER_MAX_AGE_DAYS = 14;
    @TestVisible private static final Integer SCOPE = 1;   // one staging row per transaction
    public Database.QueryLocator start(Database.BatchableContext ctx)   // via the staging selector
    public void execute(Database.BatchableContext ctx, List<Inbound_Email_Staging__c> scope)
    public void finish(Database.BatchableContext ctx)
}
public with sharing class AttachmentCarrierSweepSchedule implements Schedulable {
    public void execute(SchedulableContext ctx)   // Database.executeBatch(new AttachmentCarrierSweepBatch(), 1);
}
```

- `start()` selects `Attachment_Status__c IN ('Pending','Partial','Failed')` — via a
  **selector method**, never inline SOQL, per the layering rule.
- 🔴 **`SCOPE = 1` is load-bearing**: it gives every staging row its own 12 MB async heap budget, so
  §6.2's gate remains valid unchanged. Say so where a reviewer will see it and be tempted to raise it.
- Rows older than `CARRIER_MAX_AGE_DAYS` are **expired**: carriers deleted, status `Expired`, note
  written. Everything younger is retried through the same code path the live job uses.
- Honours the breaker and the daily budget, so a sweep during an exhausted window defers.
- Convergent: a successful pass moves the status, so re-running is free (test 39).

### 11.6 `ContentPublicationBudget` (NEW — Service)

```apex
public with sharing class ContentPublicationBudget {
    @TestVisible private static final Integer DAILY_PUBLICATION_BUDGET = 1000;
    @TestVisible private static final Integer BREAKER_SUSPEND_HOURS    = 24;

    /** true when `count` more publications are permitted right now. 0 SOQL — the
     *  hierarchy Custom Setting read is cached. Rolls the window when a day has passed.
     *  NEVER throws; a failure to read the setting degrades to "permitted". */
    public static Boolean canPublish(Integer count)

    /** Increment after a SUCCESSFUL publish. 1 DML. Fail-soft. */
    public static void record(Integer count)

    /** Set Is_Suspended__c + Suspended_Until_DateTime__c = now + BREAKER_SUSPEND_HOURS.
     *  Called ONLY from the Finalizer, i.e. from a transaction that survived. 1 DML. */
    public static void trip()

    /** The human-readable reason for the §7 note. */
    public static String suspensionNote()
}
```

Creates the org-default row on first use (custom-setting data is not deployable). **Degrades to
"permitted" on any internal failure** — this is a backstop, and a backstop that blocks the feature
when it malfunctions is worse than no backstop, because L1/L2 already make a quota hit non-fatal.

### 11.7 `InboundEmailAttachmentService` (MODIFIED)

- 🔴 **Rewrite the FAILURE BOUNDARY header section.** Its current claim — *"persist(...) and
  linkTo(...) MUST NOT THROW, under any input"* — was **falsified in production**. Replace it with
  the measured truth (M1–M6) plus the new rule: *these methods may only ever be called from a
  transaction that owns nothing irreplaceable.* Keep the `try/catch` and `allOrNone = false` — they
  still handle every ordinary failure — and state plainly that they are **not** protection against M1.
- **NEW:** `public static List<Id> stageBytes(Id stagingId, List<AttachmentRequest> retained)` —
  builds one `Attachment` per retained file (`ParentId = stagingId`, `Name = safeFileName(att)`,
  `ContentType` from the MIME subtype, `Body = att.body` **by reference**, or
  `Blob.valueOf(att.textBody)` for the CSV path behind the relocated `TEXT_MAX_BYTES` +
  `HEAP_HEADROOM_FLOOR` guards), then **one** `Database.insert(attachments, false)`. Returns the
  Ids stored. Fully wrapped; records refusals via the existing `recordFailures` path.
- Constants: `MAX_ATTACHMENTS` 10 → **3**; `ATTACHMENT_MAX_BYTES` 5,000,000 → **4,000,000**;
  update `REASON_COUNT_CAP` and `REASON_TOO_LARGE` so their embedded numbers match; rewrite
  `TEXT_MAX_BYTES`'s justification for its new synchronous venue.
- Extend `persist`'s existing per-row heap re-check to **every** row (not only the CSV branch) and
  compare against `CONVERT_HEAP_CEILING`.
- `classify()`, `describeDrop()`, `isImageAttachment()`, `persist()`, `linkTo()` keep their
  signatures. Only `persist`'s heap re-check changes inside them.
- Keep the `forcePersistFailure` seam for UAT U8, and 🔴 **add the sentence its Javadoc is missing**:
  *"this throws a CATCHABLE exception and therefore models an ORDINARY failure, not the
  `ContentPublication` failure, which cannot be modelled in Apex at all."* That missing sentence is
  what made v1's acceptance test look sufficient.

### 11.8 `EmailToLeadHandler` (MODIFIED)

- After `createStaging`, call `InboundEmailAttachmentService.stageBytes(stagingId, classified.retained)`.
- Enqueue `new ExtractAddressQueueable(stagingId, imageBase64, imageMimeType)` — **3 arguments**.
- 🔴 **DELETE `persistenceDisabledNotes()`, `PERSISTENCE_DISABLED_BANNER` and
  `REASON_PERSISTENCE_DISABLED`** — mandated by their own Javadoc. A stale DISABLED banner on rows
  whose files exist is worse than no banner.
- 🔴 **Rewrite, do not delete, the "NOTHING THAT CAN THROW MAY SIT BETWEEN `createStaging` AND THIS
  RETURN" comment.** Something now does sit there. The replacement must name it, cite **SP-4's zero
  publications and 152-byte heap** as why it is admissible, and state that **nothing else may join
  it** — in particular never a `ContentVersion` insert and never a byte-carrying `enqueueJob` (SP-1).
- Stamp `request.attachmentStatus` = `'Pending'` when anything was retained, `'None'` otherwise.
- Update the budget comment to **0 SOQL / 2 DML** (1 when nothing is attached).

### 11.9 `ExtractAddressQueueable` (MODIFIED)

- **Constructor drops its 4th argument** → `(Id stagingId, String imageBase64, String imageMimeType)`.
  `contentDocumentIds` is now meaningless — document Ids do not exist until after routing — and a
  parameter that is always null is exactly the vestigial trap this codebase documents against.
  ⚠ **Mechanical churn: ~40 call sites in `ExtractAddressQueueableTest` plus one in the handler.**
- **`linkAttachments()` is removed.** 🔴 **Relocate its reasoning, do not delete it** — the
  redelivery-guarantee paragraph now attaches to the *enqueue*, and the "one bulk statement, never
  per property" paragraph moves to `AttachmentPersistQueueable`.
- **NEW `private void enqueueAttachmentPersist(List<Id> targets)`**, the last statement of
  `finish()`, after `markRouted`, in its **own try/catch**:
  - returns immediately when `staging.Attachment_Status__c != 'Pending'` (no carrier ⇒ zero cost);
  - when `targets.isEmpty()` (a gate) calls `releaseCarrier()` instead;
  - `if (Test.isRunningTest()) { lastRunEnqueuedTargets = targets; return; }` — SP-2 makes the real
    call throw inside `@isTest`. 🔴 **Add the `@TestVisible static List<Id> lastRunEnqueuedTargets`
    seam in the same edit** (§8.6.2), never the guard alone.
- **NEW `private void releaseCarrier(String reason)`** — one `Database.delete(carriers, false)` plus
  a status stamp, on the gate and duplicate-delivery paths only. Also called from the
  `isAlreadyLogged` short-circuit in `execute()`.
- The class keeps its "NO SOQL and NO DML of its own" invariant — the delete is delegated to
  `InboundEmailAttachmentService.releaseCarrier(stagingId, reason)`.
- Header: record that the **single chained-job slot is now consumed**, so a future 11+-property
  chaining feature must share this job rather than add a second enqueue.

### 11.10 `InboundEmailStagingService` / 11.11 `InboundEmailStagingSelector` (MODIFIED)

- `StagingRequest` gains `String attachmentStatus`; `createStaging` stamps `Attachment_Status__c`
  **in the same insert** (zero extra DML).
- **NEW** `public static void markAttachmentStatus(Id stagingId, String status, String note)` —
  fail-soft, catches `Exception` (it reads as well as writes), and appends the note through the
  existing `appendDroppedNote` path so there is one formatter, not two.
- `InboundEmailStagingSelector` must select `Attachment_Status__c` (the routing job's free
  predicate), and gains the sweeper's query method. **No `WITH` mode change.**

### 11.12 `ContentVersionSelector` (MODIFIED — header only, no code change)

Its `SYSTEM_MODE` justification currently reads *"a throw here … destroys a valid broker email"*.
That is no longer true — the caller is async and a throw now costs only a **deferred** file. **The
`SYSTEM_MODE` decision stands, for a different reason**: the job runs on `Minimum Access` and
`USER_MODE` throws rather than degrades, which would disable conversion silently. Update the wording
and the venue, not the mode. Mirror the change in `ARCHITECTURE.md` §2's automation-path table.

### 11.14 Documentation — mandatory, same PR

**`ARCHITECTURE.md`:**

1. 🔴 Correct the `InboundEmailAttachmentService` row in §2: **remove the falsified "persist(...) AND
   linkTo(...) MUST NOT THROW, under any input" invariant**, record the outage and the design rule,
   and restate the handler budget as **0 SOQL / 2 DML**.
2. Add `AttachmentPersistQueueable`, `AttachmentPersistFinalizer`, `AttachmentCarrierSweepBatch`,
   `AttachmentCarrierSweepSchedule` and `ContentPublicationBudget` to §2's Key Apex Services table.
3. Rewrite the Broker Protection staging-model narrative: file capture is now a **third transaction**
   after routing, with a classic-`Attachment` carrier, a heap gate, a Finalizer and a daily sweeper.
   State the "`MAX_ATTACHMENTS = 3`" and "carrier is temporary" facts there.
4. Update the `SYSTEM_MODE` automation-path table: new rows for both `AttachmentSelector` methods;
   amend the `ContentVersionSelector` row's venue. The repo's `SYSTEM_MODE` count moves accordingly.
5. Add `Content_Publication_Budget__c` to §1's object inventory, flagged as a Custom Setting — the
   **first** in this repo.
6. Note in §5/§2 that `Inbound_Email_Staging__c` now uses **Notes & Attachments** as a working
   surface, not decoration.

**`docs/2026-08-05-inbound-email-attachments.md`:** correct the sentence *"`System.UnexpectedException`
**is catchable**"* — measured false — and add a change-history row pointing at this document and the
two spike reports.

---

## 12. ✅ DECISIONS — ALL RESOLVED. NO OPEN BLOCKERS.

| # | Decision | Resolution | Basis |
| --- | --- | --- | --- |
| **Q-1** | Build, or stay at "no persistence"? | ✅ **BUILD.** The user approved proceeding with the recommended solution. | User, post-spike |
| **Q-2** | Carrier | ✅ **Classic `Attachment` (S2-b).** Bytes are **never** carried in a Queueable payload. | SP-4 (zero quota, 152 bytes heap) + SP-1 (payload is uncatchably fatal ≈4.2–4.5 MB) |
| **Q-3** | `MAX_ATTACHMENTS` | ✅ **3** (was 10). Files beyond the third are dropped **and named** via `REASON_COUNT_CAP`. | User |
| **Q-4** | Predictive daily budget | ✅ **YES, `DAILY_PUBLICATION_BUDGET = 1000`.** Bounds any rolling 24 h window at ≤ 2,000 of 2,500. | §6.6 |
| **Q-5** | Budget storage | ✅ **Hierarchy Custom Setting `Content_Publication_Budget__c`** — 0 SOQL. First Custom Setting in this repo; its data is created at runtime, not deployed. | §6.6 |
| **Q-6** | `Attachment_Status__c` | ✅ **YES — now REQUIRED, not optional.** It is the sweeper's work queue; a Long Text field cannot be one. | §6.4 |
| **Q-7** | Tier-3 quota rehearsal before go-live | ✅ **NOT REQUIRED.** Optional, opportunistic (UAT U9). SP-5 + SP-3 + test T7 already cover what it would prove, and a quota hit is now a deferral rather than a loss. **This reverses the pre-spike recommendation, on evidence.** | §8.5 |
| **Q-8** | `Discard` → `Bounce` | ✅ **ALREADY APPLIED** — `overLimitAction` reads `Bounce`, verified twice. The other three actions stay `Discard` deliberately (backscatter). 🔴 And no email-service setting covers a handler-failure path at all. | §10.1 |
| **Q-9** | Heap gate on the conversion | ✅ **`CONVERT_MAX_TOTAL_BYTES = 4,000,000`, `CONVERT_HEAP_CEILING = 9,000,000`**, applied as a **pre-check on `BodyLength` before any `Body` is selected**. | SP-4's 10.49 MB measurement, §6.2 |
| **Q-10** | `ATTACHMENT_MAX_BYTES` | ✅ **4,000,000** (was 5,000,000), so retention and convertibility align and nothing can be permanently stuck. | §2.1 |
| **Q-11** | Carrier lifetime | ✅ **`CARRIER_MAX_AGE_DAYS = 14`**, enforced by the daily sweeper; four defined exits (converted / released / retried / expired). | §6.4 |
| **Q-12** | Breaker duration | ✅ **`BREAKER_SUSPEND_HOURS = 24`**, matching the rolling quota window; message-substring detection only. | SP-3, §6.5 |
| **Q-13** | Routed linking — stay in `finish()` or move? | ✅ **MOVE into the file job.** SP-6 proved CDL inserts are quota-free, so this is a **cohesion** decision — one class owns the file lifecycle and one retry path covers all of it — not a safety one. | SP-6, §1.4 |
| **Q-14** | Drop `ExtractAddressQueueable`'s 4th constructor argument? | ✅ **YES.** Document Ids do not exist until after routing; an always-null parameter is a vestigial trap. ~40 mechanical test call-site edits. | §11.9 |

---

## 13. 🔗 EXECUTION ORDER

✅ Spikes complete, decisions closed, `Bounce` applied. **No prerequisites remain.**

1. **Admin (`salesforce-admin`):** `Attachment_Status__c` → `Content_Publication_Budget__c` (Custom
   Setting definition) → FLS on `Broker_Protection_Access` + verification comment **22 → 23** →
   staging layout with **both** related lists (§10.2 A1–A4).
2. **Developer (`salesforce-developer`), in dependency order:**
   `AttachmentSelector` → `ContentPublicationBudget` → `AttachmentPersistFinalizer` →
   `AttachmentPersistQueueable` → `InboundEmailAttachmentService` →
   `InboundEmailStagingService` / `InboundEmailStagingSelector` → `EmailToLeadHandler` →
   `ExtractAddressQueueable` (including the ~40 test call-site edits for the 3-arg constructor) →
   `AttachmentCarrierSweepBatch` + `AttachmentCarrierSweepSchedule` → header corrections.
3. **Tests (§8.7).** 🔴 **Write T1–T4 FIRST and get them green before the feature is re-enabled** —
   they are what proves it is re-enabled *safely*, and they are the exact assertions that would have
   caught the outage.
4. **Code review**, with these as named review items: §9's budget table; §8.1's "a test inside the
   transaction cannot observe the transaction dying"; §6.2's heap arithmetic; and the two 🔴
   never-tidy-these items (the substring match, and the two-method `AttachmentSelector` split).
5. **Deploy** (`salesforce-devops`).
6. **Post-deploy, in-org, and a deploy is NOT done until these are recorded:**
   **(a)** schedule `AttachmentCarrierSweepSchedule` (§10.2 A5) — skipping it silently disables all
   retry; **(b)** run the FLS verification query and confirm **23**; **(c)** confirm the staging
   layout shows both related lists.
7. **Measure the suite's `ContentPublication` consumption** (SP-6.5, still unrun) and record it in
   `.claude/rules/content-publication-rule.md`'s terms. It should be **below** today's 93.
8. **UAT (§14) — U1–U8 are MANDATORY.** U8 is the acceptance test for the whole redesign.
9. **Docs in the same PR** (§11.14): `ARCHITECTURE.md` and the "is catchable" correction.

---

## 14. UAT CHECKLIST — a green Apex suite does not prove this works

**Why this is not optional.** §8.3 lists four properties Apex cannot prove: the chain firing (SP-2 —
it throws inside `@isTest`), cross-transaction isolation for *this* pipeline (everything in a test is
one transaction), the heap gate against real bytes, and the breaker against the real exception. Plus
this repo's two standing precedents of platform DML behaving differently by context
(`EmailMessage.RelatedToId`; converted-Lead lookups).

**Run every step through the real pipeline, never as an admin.** Record the results in this document.

| # | Step | Pass criterion | Mand. |
| --- | --- | --- | --- |
| **U1** | Forward a real broker email with a **PDF OM** | Staging row: `Attachment_Count__c = 1`, `Attachment_Bytes__c > 0`, `Attachment_Status__c = 'Saved'`, notes blank. File visible on the staging row **and** on the routed Lead. The carrier `Attachment` is **gone**. **Proves the chain actually fires** — the one thing no Apex test can. | ✅ |
| **U2** | Forward one with **PDF + XLSX + a signature logo** | Two files saved, the logo dropped with a recorded reason. | ✅ |
| **U3** | Forward one with **four allowed attachments** | Exactly **3** saved; the fourth is named in `Dropped_Attachment_Notes__c` via `REASON_COUNT_CAP`. Pins `MAX_ATTACHMENTS = 3` in the real transport. | ✅ |
| **U4** | Forward one with a **`.csv` rent roll** | Saved. Pins the relocated `Blob.valueOf` path where it now runs (synchronously, in `stageBytes`). | ✅ |
| **U5** | Forward one with a **~2 MB image** | Handler survives; the vision skip is recorded above 1 MB. ⚠ **Also check `Has_Image__c` on a sub-1 MB image** — SP-1 ruled out payload capacity as the cause of it always being `False`, so if it is still `False` there is a second, unexplained defect. Report it; do not fix it here. | ✅ |
| **U6** | 🔴 Forward one with a **~3.9 MB PDF** | It converts, and `AttachmentPersistQueueable.lastRunHeapPeak` read from the debug log is **< 9,000,000**. **This is the only real verification of §6.2's arithmetic** — a green Apex suite does not establish it. | ✅ |
| **U7** | **Multi-property email** (2+ properties, mixed outcomes) | One file set on **every** routed record, once each. One bulk statement — verify from the log, not by counting rows. | ✅ |
| **U8** | 🔴 **THE ACCEPTANCE TEST.** Send a real PDF email, force the file job to die (`forcePersistFailure`) | **All of:** the Lead exists; the `Property_Registry__c` claim exists; the Task exists with its `Inbound_Message_Id__c`; the staging row reads `Processed`; **the carrier `Attachment` is STILL THERE**; `Attachment_Status__c = 'Failed'`; the Finalizer's note is on `Dropped_Attachment_Notes__c`; `AsyncApexJob` shows `Failed` with a usable `ExtendedStatus`. **Then run the sweeper and confirm the file converts and the carrier is removed.** This proves isolation *and* retry in one pass, and costs zero quota. | ✅ |
| **U9** | *(optional, Q-7)* Drive `ContentPublicationLimit` to exhaustion, then send one attachment email | Same invariants as U8, **plus** the breaker trips and `Is_Suspended__c = true`. 🔴 Burns up to 2,500 publications and takes 24 h to recover — end of day only, announced, never on a deploy day. | ○ |
| **U10** | **Duplicate delivery** — re-send the same Message-ID | Zero new `ContentVersion`s, zero duplicate links, and the duplicate row's carrier is **released**, not left behind. | ✅ |
| **U11** | **A gated email** (call-for-offers) with an attachment | No conversion, carrier released, `Attachment_Status__c = 'Not Saved'` with the gate reason. | ✅ |
| **U12** | Read back as a **non-admin deal persona** | `Attachment_Status__c` is visible (pins the FLS grant), the file opens from the Opportunity, and **Notes & Attachments is visible on the staging row** (pins A4 — it is where bytes are recovered). | ✅ |
| **U13** | Confirm the schedule | `AttachmentCarrierSweepSchedule` appears in Scheduled Jobs. **Skipping this silently disables all retry.** | ✅ |

---

## 15. SCOPE STATEMENT

This document adds **nothing** beyond (a) relocating the `ContentVersion` insert out of every
transaction that owns something irreplaceable, (b) the carrier that makes that relocation possible
and loss-free, (c) the heap gate the spikes proved is necessary, (d) the quota degradation and
retry/replay the user explicitly asked for, and (e) the tests and documentation corrections that
make the result verifiable.

It does **not** change the LLM prompt, the extraction contract, the routing tree's branch logic, the
claim engine, the Task contract, the classification rules, or any arbitration input. No fixture is
re-pinned.

It does **not** change the LLM prompt, the extraction contract, the routing tree's branch logic, the
claim engine, the Task contract, the classification *rules*, or any arbitration input. No fixture is
re-pinned.

**Three deliberate deletions:** the `PERSISTENCE_DISABLED` banner and its helper (mandated by their
own Javadoc); `ExtractAddressQueueable.linkAttachments()`; and that class's 4th constructor argument.
In all three cases the **reasoning** relocates — only the code is removed.

**Four things this document deliberately refuses to do:**

1. **Propose a better `catch`.** M3 is measured. Answer any such review comment with this sentence.
2. **Carry bytes in a Queueable payload.** SP-1: uncatchable at ~4.2–4.5 MB, thrown at
   `enqueueJob` itself. That would move the outage one line earlier, not remove it.
3. **Read `/limits` anywhere, even advisorily.** Prohibited on three independent grounds, one of
   them SP-6's measurement that the value is stale and non-monotonic.
4. **Claim a green Apex suite proves the fix.** It cannot — §8.1, §8.3. **UAT U8 is the acceptance
   test, and it happens in the org.**
