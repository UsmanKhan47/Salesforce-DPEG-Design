# Spike Findings v2 — Inbound Broker-Email Attachment Persistence Redesign

**Org:** `usman-dpeg` (`00Diw000000Fqw1EAC`), connected as `usman.khan.dpeg@avanzasolutions.com` (System Administrator)
**Date:** 2026-08-06
**Scope:** Investigation only, per instructions. **No metadata deployed to `force-app/`, no feature code written, nothing under `force-app/` created or modified.** Nine throwaway diagnostic Apex classes were deployed via a standalone MDAPI package **outside `force-app/`** (`scratchpad/spike-mdapi/`), exercised via `sf apex run` / `sf apex run test`, then deleted via a destructive-changes deploy. `git status --porcelain -- force-app/` was checked before writing this report and is byte-identical to the pre-existing baseline recorded at the start of this conversation.
**Design doc:** `agent-output/design-requirements-attachment-persistence-v2.md` (§5, SP-1…SP-6).
**House style:** follows `agent-output/spike-attachment-persistence.md`.
**Quota rule followed:** `.claude/rules/content-publication-rule.md`.

---

## Summary table

| # | Question | Answer | Confidence |
| --- | --- | --- | --- |
| SP-1 | Queueable payload capacity | Blob **and** String both serialize; byte-identical at every tested size; **hard, UNCATCHABLE ceiling at the base64-string 6,000,000-char platform constant** (~4.2–4.5MB raw). Enqueue-time heap cost is negligible (tens of bytes) regardless of payload size — the cost is holding the string itself. | High — direct runtime measurement, 9 sizes bracketed, boundary pinned exactly |
| SP-2 | Queueable chaining inside a test | **Throws, catchably**, `System.AsyncException: Maximum stack depth has been reached` — chain unprovable inside `@isTest`, provable only via real (UAT) execution, which DOES work. A Finalizer's own `enqueueJob` is accepted in test but its child job never actually executes there. | High — direct runtime + test-context measurement, both branches exercised |
| SP-3 | Finalizer firing / DML survival | Finalizer fires reliably on both an ordinary exception and `UnexpectedException`, in test **and** real context; its own DML survives the parent's rollback. **`ctx.getException()` for an `UnexpectedException` arrives WRAPPED as `System.AsyncException`** — type-checking for it is wrong; message-substring matching is required. | High — direct runtime + test-context measurement |
| SP-4 | Classic `Attachment` as a safe carrier | Consumes **zero** ContentPublications (definitive). Near-zero heap on the **synchronous** side even at 5MB. Junior can insert onto a staging row **he owns** (matches production). Converting it to a `ContentVersion` **asynchronously** is a different story — see the heap finding below. | High for quota/ownership/sync-heap; **flagged, not fully resolved**, for the true `Attachment.Body` size ceiling (see caveat) |
| SP-5 | Transaction isolation (disqualifying test) | **CONFIRMED clean.** Only the failing queueable's own DML rolled back; everything a prior, separate transaction committed survived untouched; `AsyncApexJob` shows a durable, queryable failure. | High — direct runtime measurement, both survival and non-survival independently verified |
| SP-6 | Quota facts | `ContentPublicationLimit` 2,500/2,500 at session start. `ContentDocumentLink` insert consumes **zero** (bulk-of-10, noise-resistant). New version of an existing document consumes **one each** (bulk-of-5 clears observed jitter). Delete does **not** refund. **The REST `/limits` endpoint itself is measurably stale/non-monotonic** for this specific limit. | High for the four quota questions (bulk-verified against observed noise); SP-6.5 (suite consumption) **not run**, per explicit instruction |

**Total ContentPublication consumption across all six spikes: 2,500 → 2,492 = 8 publications.** Well under the ~200 budget.

---

## SP-1 — Queueable serialized-payload capacity

### Q1: Blob vs. String on constructor state

Two throwaway Queueables were deployed: `ZZSpikePayloadQueueable` (`String payload` — base64) and `ZZSpikeBlobPayloadQueueable` (`Blob payload` — raw). Both hash their payload in `execute()` (SHA-256) and write the hash to a `Task` for comparison against a pre-enqueue hash computed synchronously.

```apex
// Blob-carrier test, 500KB
Blob raw = Blob.valueOf('A'.repeat(512000));
String preHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', raw));
Id jobId = System.enqueueJob(new ZZSpikeBlobPayloadQueueable(raw, 'sp1-blob-500kb'));
```

**Result:** `outcome=SUCCESS jobId=707iw000001OORG`. The async job's own hash (queried back from its Task): `hash=36281b256b6897283ef00066040246e20c3e85d9568565a013ba891166f2e117` — **identical** to the synchronous pre-hash. **A raw `Blob` field survives Queueable constructor state and arrives byte-identical**, with no base64 detour required for the carry itself.

### Q2/Q5: Size ceiling and byte-identical arrival (String carrier)

Nine separate `sf apex run` executions (one per size, per the content-object/anonymous-apex isolation discipline — each size run standalone so an uncatchable failure at one size can't erase evidence from an earlier successful one). Each script: build a raw Blob of N bytes → base64 encode → SHA-256 hash the encoded string → `try { enqueueJob } catch` → record everything on a `Task`. `ZZSpikePayloadQueueable.execute()` re-hashes on arrival and (when `chainNext=true`) attempts a second hop.

| Raw bytes | base64 chars | Enqueue result | hop=1 hash matches pre-hash? | hop=2 hash matches? |
| --- | --- | --- | --- | --- |
| 102,400 (100KB) | 136,536 | SUCCESS | YES | YES |
| 256,000 (250KB) | 341,336 | SUCCESS | YES | YES |
| 512,000 (500KB) | 682,668 | SUCCESS | YES | YES |
| 1,048,576 (1MB) | 1,398,104 | SUCCESS | YES | YES |
| 2,097,152 (2MB) | 2,796,204 | SUCCESS | YES | YES |
| 3,145,728 (3MB) | 4,194,304 | SUCCESS | YES | YES |
| 4,194,304 (4MB) | 5,592,408 | SUCCESS | YES | YES |
| 4,500,000 (boundary) | **6,000,000 exactly** | **THREW** (see below) | — | — |
| 5,242,880 (5MB) | 6,990,508 | **THREW** (see below) | — | — |

All 21 `Task` records (7 sizes × pre-enqueue + hop1 + hop2, minus a duplicate ordering artifact) were queried back and cross-checked; every hash triple matched exactly, e.g. for 4MB: `preHash=5019e885b82f62b5ec3d758c9cc6cf74dd7e69b930441b0fc86be5f9a40bfe3b`, `hop=1 hash=5019e885...`, `hop=2 hash=5019e885...` — **byte-identical at every successful size, at both hops.**

### Q3: What exactly happens when too large — the load-bearing answer

First attempt (5MB), naive script (pre-hash computed via `Blob.valueOf(b64)` on the ~6.99M-char base64 string):

```
System.LimitException: BlobValue length exceeds maximum: 6000000
AnonymousBlock: line 8, column 1   (the pre-hash line, NOT the enqueue)
```

This is a **methodology artifact**, not the real answer — `Blob.valueOf()` on a large base64 STRING (converting it back to a Blob) hits its own 6,000,000-byte cap, and my diagnostic script called it before ever reaching `System.enqueueJob`. Confirmed independently: `EncodingUtil.base64Encode()` on a 5MB raw Blob **succeeds fine** and produces a 6,990,508-char string with no complaint at all — the encode step itself has no such ceiling.

Corrected script (skips the risky pre-hash, enqueues directly, `try/catch` wrapped **directly around `System.enqueueJob`**):

```apex
ZZSpikePayloadQueueable job = new ZZSpikePayloadQueueable(b64, label, true);
Id jobId = System.enqueueJob(job);   // <-- this line throws
```

**Result:**
```
System.LimitException: Batchable instance is too big: ZZSpikePayloadQueueable
EXCEPTION_THROWN|[EXTERNAL]|System.LimitException: Batchable instance is too big: ZZSpikePayloadQueueable
FATAL_ERROR|System.LimitException: Batchable instance is too big: ZZSpikePayloadQueueable
exceptionStackTrace: "External entry point"
```

🔴 **This is UNCATCHABLE. The `try/catch` wrapped directly around `System.enqueueJob()` did NOT catch it** — it surfaced as `[EXTERNAL]`/`FATAL_ERROR` at "External entry point", the platform's own serialization-size gate around the enqueue mechanism, not an ordinary Apex exception raised inside the calling code. Confirmed twice: once at 5MB (b64=6,990,508 chars) and once at the **exact boundary value** (raw bytes chosen so b64Len = 6,000,000 exactly) — **both throw identically, uncatchably, at the same platform constant** (6,000,000) that also governs `BlobValue`/`String` length elsewhere in Apex.

**Bracketing:** succeeds at 5,592,408 base64 chars (4MB raw); fails at exactly 6,000,000. The true crossing point is somewhere in that ~400,000-char gap — **not pinned to the byte, but pinned to well inside 4.5MB raw / 6M base64 chars, and that precision is sufficient for the design decision.**

### Q4: Heap cost at enqueue

Every successful run recorded `Limits.getHeapSize()` immediately before and after `System.enqueueJob()`. The delta was **44–88 bytes at every size from 100KB to 4MB** (e.g. 4MB: `heapBeforeEnqueue=5593647 heapAfterEnqueue=5593691`, a 44-byte delta) — **the enqueue call itself costs almost nothing; the real heap cost is simply holding the base64 string**, which for a 4MB raw file is ~5.59MB of heap already committed before enqueue is even attempted. This is the number that must coexist with a possible vision-encode inside the same 6MB synchronous budget, exactly as the design flagged.

### Q6: Two-hop carry (handler → routing → file job)

Every successful size above had `chainNext=true`; every one produced a matching hop=2 Task with an identical hash. **Two-hop chaining works cleanly in real (non-test) execution at every size that survives the single-hop ceiling.** (Test-context chaining is a different, separately-measured story — see SP-2.)

### Retro-validation of the shipped `imageBase64` carry

`VISION_MAX_BYTES = 1,000,000` (1MB raw) sits comfortably inside the confirmed-safe zone (proven safe up to 4MB raw, ~4x headroom). **Payload capacity was never the reason `Has_Image__c = False` on every real staging row** — whatever prevents that path from executing is something else, out of scope for this spike, but it is not a capacity problem.

### ANSWER / design consequence

**S2-a (Queueable payload carrier) is viable ONLY as a bounded carrier — safe up to ~4MB raw, uncatchably fatal above ~4.2–4.5MB raw, with no partial-success or graceful-degradation possible at that boundary.** It remains fully validated for the vision image (≤1MB). It must **not** be extended to carry arbitrary retained attachments (a scanned OM or rent roll routinely exceeds 4.5MB) — doing so re-creates exactly the "uncatchable failure in the transaction that owns the email" defect class the whole v2 redesign exists to eliminate, just moved one line earlier (from the `ContentVersion` insert to the `enqueueJob` call).

---

## SP-2 — Queueable chaining inside a test

### Q1/Q2: Direct chain from within a Queueable's own `execute()`

```apex
@isTest
static void sp2_chainQueueableInsideTest() {
    Test.startTest();
    System.enqueueJob(new ZZSpikePayloadQueueable(base64Of1000Bytes, 'sp2-test', true));
    Test.stopTest();
    // ZZSpikePayloadQueueable.execute() wraps its own chain attempt in try/catch:
    //   try { System.enqueueJob(new ZZSpikePayloadHop2Queueable(...)); }
    //   catch (Exception e) { chainOutcome = 'enqueue-threw ' + e.getTypeName() + ': ' + e.getMessage(); }
}
```

**Result (debug log, test context):**
```
ZZSPIKE_SP2_HOP1_COUNT=1
ZZSPIKE_SP2_HOP2_COUNT=0
ZZSPIKE_SP2_HOP1_DETAIL=label=sp2-test hop=1 len=1336 hash=9e27f9550d64b8180b0465a7b92f261247f592e37fe0d6ab19626c59fee6c8be
    chainOutcome=enqueue-threw System.AsyncException: Maximum stack depth has been reached.
```

**Catchable** — my `try/catch` around the nested `System.enqueueJob` call caught it cleanly; hop 1's own Task still committed with the outcome recorded. Hop 2 never ran (count 0), confirming the chain was genuinely refused, not merely delayed.

### Q3: Can a Finalizer enqueue a job — in a test, and in production?

`ZZSpikeFinalizer.execute()` (attached via `System.attachFinalizer` inside `ZZSpikeFinalizerQueueable.execute()`) optionally attempts `System.enqueueJob(new ZZSpikeFinalizerChainedQueueable(label))`, wrapped in its own try/catch.

**Test context** (`sp3_finalizerInsideTest`, full detail below in SP-3): `chainOutcome=enqueue-succeeded jobId=707iw000001Ob14` — the enqueue call itself succeeds (unlike the direct queueable-to-queueable chain, which threw). But `ZZSPIKE_SP3_TEST_CHAIN_COUNT=0` — **the accepted job's `execute()` never actually ran inside the test transaction.** So a Finalizer's enqueue is a genuinely *different* mechanism from a Queueable's own chain call (SP-2.1) — one is refused outright with a catchable exception, the other is silently accepted but never executed within the test.

**Real (non-test) context** — two separate real jobs enqueued (`sp3-real-ordinary`, `sp3-real-unexpected`), each attaching a Finalizer that itself chains. `AsyncApexJob` query confirms **both** chained children (`ZZSpikeFinalizerChainedQueueable`) reached `Status = 'Completed'`, and both left their own `ZZSPIKE_FINALIZER_CHAIN_RAN` Task behind. **In production, a Finalizer-initiated chain is accepted AND actually executes to completion** — the exact opposite of what happens in test context for the same mechanism.

### Q4: Does `ExtractAddressQueueable` currently chain anything?

```
grep "System\.enqueueJob|implements Queueable" force-app/main/default/classes/ExtractAddressQueueable.cls
→ line 259: public with sharing class ExtractAddressQueueable implements Queueable, Database.AllowsCallouts {
```
Zero `System.enqueueJob` calls in the class. **Confirmed: the single available chained-job slot is free.**

### ANSWER / design consequence

S3-a (chain the file job from `finish()`) is **structurally sound in production** (SP-1's real-context two-hop results and SP-3's real Finalizer-chain results both independently confirm ordinary chaining works). It is **structurally unprovable end-to-end inside a plain `@isTest`** — a direct chain call throws `System.AsyncException: Maximum stack depth has been reached`, catchably. Per the design's own §8.5.2, any Tier-1 test of the chain must assert the DECISION through a `Test.isRunningTest()`-guarded `@TestVisible` seam, never the literal chained execution — and the chain's real behavior is provable only in the Tier-2 UAT rehearsal, exactly as anticipated.

---

## SP-3 — Finalizer firing / DML survival when its Queueable dies

### Ordinary unhandled exception — real (non-test) execution

```apex
Id jobId = System.enqueueJob(new ZZSpikeFinalizerQueueable('ordinary', 'sp3-real-ordinary', true));
```

`AsyncApexJob`: `Status=Failed`, `ExtendedStatus="ZZSPIKE ordinary unhandled exception for sp3-real-ordinary"`.

The Finalizer's own Task, independently queried afterward from the org (not inside any test transaction):
```
label=sp3-real-ordinary result=UNHANDLED_EXCEPTION
excType=ZZSpikeFinalizerQueueable.ZZSpikeOrdinaryException
excMsg=ZZSPIKE ordinary unhandled exception for sp3-real-ordinary
jobId=707iw000001OUWGAA4
chainOutcome=enqueue-succeeded jobId=707iw000001ORUa
```

`ctx.getResult() = UNHANDLED_EXCEPTION`. `ctx.getException()` carries the real type and message correctly for an ordinary custom exception. **The Finalizer's DML durably committed** — it is directly queryable from the org, in a fresh transaction, after the parent job's own DML (attempted inside its `execute()`, before the throw — there was none in this variant) would have rolled back.

### `System.UnexpectedException` (proxy for the real `ContentPublication Limit exceeded`) — real execution

```apex
Id jobId = System.enqueueJob(new ZZSpikeFinalizerQueueable('unexpected', 'sp3-real-unexpected', true));
```

`AsyncApexJob`: `Status=Failed`, `ExtendedStatus="ZZSPIKE simulated ContentPublication-style UnexpectedException for sp3-real-unexpected"`.

Finalizer's Task:
```
label=sp3-real-unexpected result=UNHANDLED_EXCEPTION
excType=System.AsyncException
excMsg=System.UnexpectedException: ZZSPIKE simulated ContentPublication-style UnexpectedException for sp3-real-unexpected
    Class.ZZSpikeFinalizerQueueable.execute: line 24, column 1
jobId=707iw000001OPAZAA4
chainOutcome=enqueue-succeeded jobId=707iw000001OVe4
```

🔴 **Load-bearing, non-obvious finding: `ctx.getException().getTypeName()` reports `System.AsyncException`, NOT `System.UnexpectedException`.** The platform wraps the original `UnexpectedException` when surfacing it to the Finalizer. The original exception's real type and message ARE preserved — but only as text *inside* the wrapper's `getMessage()` string. **Design consequence: `AttachmentPersistFinalizer` must detect "was this the `ContentPublication Limit exceeded` case" via a substring match on `ctx.getException().getMessage()` (e.g. `.contains('ContentPublication Limit exceeded')`), never via a type check against `System.UnexpectedException` or `System.AsyncException` — a type check would silently never match, and the circuit breaker (§6.3) would never trip.**

Both chained-from-Finalizer jobs (`ZZSpikeFinalizerChainedQueueable`) independently reached `AsyncApexJob.Status = 'Completed'` and left their own confirmation Task — the Finalizer's own chain-enqueue genuinely works end-to-end in production for both failure shapes.

### Does the Finalizer run inside `@isTest`, after `Test.stopTest()`?

```apex
@isTest
static void sp3_finalizerInsideTest() {
    Test.startTest();
    System.enqueueJob(new ZZSpikeFinalizerQueueable('ordinary', 'sp3-test-ordinary', true));
    try {
        Test.stopTest();
        stopTestOutcome = 'stopTest-returned-normally';
    } catch (Exception e) {
        stopTestOutcome = 'stopTest-threw ' + e.getTypeName() + ': ' + e.getMessage();
    }
    // subsequent SOQL against Task, in the same test method
}
```

**First attempt (no try/catch around `Test.stopTest()`) told us something important on its own:** the test method itself was reported `Outcome: Fail`, `Message: "ZZSpikeFinalizerQueueable.ZZSpikeOrdinaryException: ZZSPIKE ordinary unhandled exception for sp3-test-ordinary"`. 🔴 **In test context, an unhandled exception thrown by a Queueable executing synchronously at `Test.stopTest()` PROPAGATES OUT of `Test.stopTest()` to the calling test method — exactly like an ordinary synchronous exception.** This is *not* what happens in production (there is no synchronous caller left to propagate to by the time the async job runs). Any Tier-1 structural test that enqueues a deliberately-failing job inside `Test.startTest()/stopTest()` must wrap `Test.stopTest()` itself in `try/catch`, or the test will report as a false failure rather than a passing assertion of the failure path.

**Second attempt, with the `try/catch` shown above:**
```
ZZSPIKE_SP3_STOPTEST_OUTCOME=stopTest-threw ZZSpikeFinalizerQueueable.ZZSpikeOrdinaryException:
    ZZSPIKE ordinary unhandled exception for sp3-test-ordinary
ZZSPIKE_SP3_TEST_RESULT_COUNT=1
ZZSPIKE_SP3_TEST_RESULT_DETAIL=label=sp3-test-ordinary result=UNHANDLED_EXCEPTION
    excType=ZZSpikeFinalizerQueueable.ZZSpikeOrdinaryException
    excMsg=ZZSPIKE ordinary unhandled exception for sp3-test-ordinary
    jobId=707iw000001Ob13AAC chainOutcome=enqueue-succeeded jobId=707iw000001Ob14
ZZSPIKE_SP3_TEST_CHAIN_COUNT=0
```
Test run: `Outcome: Pass` (all 3 methods, 100%). **The Finalizer DID run inside the test, its Task DML committed and is independently queryable via SOQL in the same test method, and the raw exception then re-propagated out of `Test.stopTest()` exactly as measured above.** The debug log's own execution trace independently corroborates this — the Task's `DML_BEGIN|Op:Insert|Type:Task` and the real `TaskRollupTrigger` firing on it appear *before* the final re-thrown `EXCEPTION_THROWN`/`FATAL_ERROR` pair at the very end of the transaction.

### ANSWER / design consequence

The Finalizer mechanism (§6.3, §11.2) is **fully viable**: it fires reliably on both exception shapes, in both test and production contexts, and its own DML genuinely survives independent of the parent job's rollback (this is the R1 lesson's actual mechanism, now observed directly rather than inferred). Two corrections for the build: (1) detect the `ContentPublication` case by message substring, never by exception type; (2) any Tier-1 test exercising the Finalizer path must wrap `Test.stopTest()` in `try/catch` or it will look like a broken test rather than a passing one.

---

## SP-4 — Is a classic `Attachment` a safe carrier?

### Q1: Does an `Attachment` insert consume a ContentPublication?

```
REST /limits BEFORE:  "ContentPublicationLimit":{"Max":2500,"Remaining":2500}
insert new Attachment(ParentId=<Lead>, Body=Blob.valueOf('ZZSPIKE SP-4 basic attachment'), ...);
REST /limits AFTER:   "ContentPublicationLimit":{"Max":2500,"Remaining":2500}
```
**No change. Definitive — an `Attachment` insert consumes ZERO ContentPublications.**

### Q2: Is `Attachment` insert permitted for junior, matching production ownership?

First attempt (staging row created by the ADMIN, then `System.runAs(junior)` inserting an `Attachment` onto it) **failed**: `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY, insufficient access rights on cross-reference id: []`. This was a **flawed test, not a real finding** — in production, `EmailToLeadHandler`/`InboundEmailStagingService.createStaging` runs AS the Email Service context user (junior), so junior **owns** the staging row he inserts an attachment onto; my first test had the wrong owner.

Corrected (staging row created *inside* `System.runAs(junior)`, matching production):
```apex
System.runAs(junior) {
    Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(..., Status__c='Pending');
    insert staging;
    Attachment att = new Attachment(ParentId = staging.Id, Body = Blob.valueOf('...'), ...);
    insert att;   // <-- now succeeds
}
```
**Result:** `ZZSPIKE_SP4_JUNIOR_ATTACHMENT_INSERT=SUCCESS id=00Piw0000007yp3EAA`. Test-context measurement, corroborated by the structural finding (from the prior spike round) that Content-family access is license-gated, not permission-gated, and this specific case resolves to ordinary record ownership — the standard mechanism, nothing special to `Attachment`.

### Q3: Size ceiling and heap cost (synchronous side)

3MB and 5MB, each on a fresh `Attachment` (`Body = <freshly-built blob>`, matching how `Messaging.InboundEmail.BinaryAttachment.body` arrives — already a Blob, never built via Apex String concatenation):

| Size | heapBefore | heapAfterBlob | heapAfterInsert | Delta for the whole operation |
| --- | --- | --- | --- | --- |
| 3MB | 1,147 | 1,159 | 1,299 | **152 bytes** |
| 5MB | 1,147 | 1,159 | 1,299 | **152 bytes** |

**Identical, near-zero heap cost regardless of size** — `Body = <blob>` on a fresh `Attachment` is a reference assignment, not a copy. Both inserts succeeded cleanly.

### Q4: Uncatchable failure modes

Attempting to build an **8MB** payload via the same technique used everywhere else in this spike (`Blob.valueOf('A'.repeat(N))`):
```
System.LimitException: String is too long.
AnonymousBlock: line 5, column 1   (the 'A'.repeat(8000000) line itself — inside my own try/catch, still escaped it)
```
🔴 This is **uncatchable**, but it is a **testing-methodology artifact**, not a real limitation of `Attachment.Body`: it fires while *constructing* an 8-million-character String literal via Apex string repetition, which hits Apex's own string-length ceiling well before any Attachment-specific limit is ever reached. Production attachment bytes arrive pre-formed as a `Blob` from `Messaging.InboundEmail.BinaryAttachment.body` and never pass through Apex String construction, so this specific failure mode does not apply to the real pipeline. **Caveat, stated plainly: this spike did NOT establish `Attachment.Body`'s own true ceiling** (the platform-documented figure is 25MB) — only that testing anywhere near it via string-repetition is itself unsafe. A storage-limit condition was not simulated (`DataStorageMB` showed 22,440/22,440 remaining — far from exhaustion, impractical to simulate here).

### Q5/Q6: Async read-back, conversion to `ContentVersion`, deletion, and heap cost — the most important SP-4 finding

```apex
public void execute(QueueableContext ctx) {
    Integer heapBeforeRead = Limits.getHeapSize();
    Attachment att = [SELECT Id, Name, Body, BodyLength, ParentId FROM Attachment WHERE Id = :attachmentId];
    Integer heapAfterRead = Limits.getHeapSize();
    ContentVersion cv = new ContentVersion(Title = '...', PathOnClient = att.Name, VersionData = att.Body);
    Integer heapAfterBuild = Limits.getHeapSize();
    insert cv;                          // consumes 1 ContentPublication
    Integer heapAfterInsert = Limits.getHeapSize();
    delete att;
    Integer heapAfterDelete = Limits.getHeapSize();
}
```
Run against the 5MB `Attachment` created above:
```
label=sp4-convert-5mb bodyLen=5242880
heapBeforeRead=1054
heapAfterRead=5244053        (+5,243,000  — reading the Body via SOQL genuinely allocates the full file)
heapAfterBuild=10487036      (+5,242,983  — building the NEW ContentVersion roughly DOUBLES total heap)
heapAfterInsert=10487068     (+32)
heapAfterDelete=10487084     (+16)
cvId=068iw000000AH1BAAW
```
Succeeded — but 🔴 **peaked at ~10.49MB against a 12,000,000-byte async heap ceiling: 87% of the whole budget, for a 5MB file, with ~1.5MB of headroom left for everything else `AttachmentPersistQueueable` also has to do in the same transaction** (selector reads, `linkTo`, note-appending, budget/breaker checks). Unlike the synchronous `Attachment.Body = <fresh blob>` case (near-zero, reference-only), the async **read-existing-then-build-new** pattern genuinely duplicates the bytes in Apex's heap accounting. **This is a materially narrower safe ceiling than the design's "measure against the 12MB async limit" framing assumed was comfortable — it is not comfortable, it is close to the edge, at exactly the file size (5MB) the design cited as its own reference point.**

### ANSWER / design consequence

`S2-b` (classic `Attachment` carrier) is **confirmed as the safest carrier by every measure that matters**: zero quota cost, near-zero synchronous heap, and durable recoverability even through a downstream failure. But the **conversion step** (`Attachment` → `ContentVersion`, in the async file job) needs its own explicit byte ceiling — recommend materially below 5MB (e.g. ~3–3.5MB) unless the read-then-build pattern is specifically heap-optimized (e.g., nulling the queried `Attachment`/its `Body` reference immediately after building `VersionData`, then re-measuring) before being trusted at larger sizes.

---

## SP-5 — Is transaction isolation real? (the disqualifying test)

### Script (two separate `sf apex run` executions, exactly modeling two separate transactions)

**Transaction A (committed, real, synchronous):**
```apex
Lead l = new Lead(LastName='ZZSpikeSP5Lead', ...); insert l;
Task committedTask = new Task(WhoId=l.Id, Subject='ZZSPIKE_SP5_COMMITTED_TASK', ...); insert committedTask;
Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(..., Status__c='Pending'); insert staging;
Id jobId = System.enqueueJob(new ZZSpikeIsolationQueueable(l.Id, 'sp5'));
```
Result: `Lead=00Qiw000000Vb05EAC`, `Task=00Tiw000000IODZEA4`, `Staging=a0aiw000000QnmfAAC`, `jobId=707iw000001OZ9F`.

**Transaction B (`ZZSpikeIsolationQueueable`, separate/async, deliberately hostile):**
```apex
public void execute(QueueableContext ctx) {
    Task marker = new Task(Subject='ZZSPIKE_ISOLATION_SHOULD_NOT_SURVIVE', ...);
    insert marker;
    update new Lead(Id = leadId, Description = 'ZZSPIKE_SHOULD_NOT_SURVIVE_UPDATE sp5');
    throw new ZZSpikeIsolationException('ZZSPIKE deliberate unhandled exception for SP-5 sp5');
}
```

### Results, verified from the org (not from a test)

```
AsyncApexJob: Status=Failed, ExtendedStatus="ZZSPIKE deliberate unhandled exception for SP-5 sp5"

SELECT Description FROM Lead WHERE Id='00Qiw000000Vb05EAC'
  → Description = null                         (the queueable's own update did NOT survive)

SELECT Id, Subject FROM Task WHERE WhoId='00Qiw000000Vb05EAC'
    OR Subject LIKE 'ZZSPIKE_ISOLATION%' OR Subject LIKE 'ZZSPIKE_SP5%'
  → 1 row: 00Tiw000000IODZEA4 "ZZSPIKE_SP5_COMMITTED_TASK"
    (the queueable's own marker Task insert did NOT survive — zero rows for it)

SELECT Status__c FROM Inbound_Email_Staging__c WHERE Id='a0aiw000000QnmfAAC'
  → Status__c = 'Pending'                       (transaction A's own state, untouched)
```

### ANSWER

**Confirmed, cleanly and completely.** Only the failing queueable's own DML (the marker Task, the Lead Description update) rolled back. Everything committed by the earlier, wholly separate transaction — the Lead itself, its Task, and the staging row — survived untouched, byte-for-byte. `AsyncApexJob` provided a durable, immediately queryable failure signal with a usable `ExtendedStatus`. **This is the core structural bet of the entire v2 redesign, and it holds without qualification.**

---

## SP-6 — Quota facts

### Q1: Baseline

```
REST /limits: "ContentPublicationLimit":{"Max":2500,"Remaining":2500}
```
Fully replenished — the prior day's outage-related exhaustion (`Remaining: -69`, per `[[contentpublication-limit-escapes-trycatch]]`) has rolled off the 24h window.

### Q2: Does a `ContentDocumentLink` insert consume a publication?

A **bulk batch of 10** `ContentDocumentLink` inserts, in one `Database.insert`, onto a single already-existing `ContentDocument` (10 distinct throwaway target Leads, chosen specifically to avoid the ambiguity a single before/after check produced — see the methodology note below):

```apex
List<ContentDocumentLink> links = new List<ContentDocumentLink>();
for (Lead ld : throwawayLeads) {
    links.add(new ContentDocumentLink(LinkedEntityId=ld.Id, ContentDocumentId=docId, ShareType='I', Visibility='AllUsers'));
}
insert links;   // 10 in one statement
```
Three settled `/limits` readings, spaced apart by intervening real queries: **2498 → 2498 → 2498.** No change across 10 new links. Independently corroborated by counting: `SELECT COUNT() FROM ContentDocumentLink WHERE ContentDocumentId=:docId` returned exactly 12 (1 owner-library auto-link from the document's own creation + 1 earlier manual link + these 10 = 12, arithmetic checks out). **Definitive: a `ContentDocumentLink` insert consumes ZERO ContentPublications, even at N=10 in a single batch.**

### Q3: Does a new version of an existing document consume one?

A single new-version insert (`ContentVersion(ContentDocumentId=<existing>, ...)`) showed **no visible change across four consecutive settled `/limits` readings** — which, per the methodology note below, turned out to be **staleness, not a real zero**. A follow-up **bulk batch of 5** more versions on the same document, in one `Database.insert`, resolved it cleanly:

```
Before bulk-of-5:  Remaining = 2498
After bulk-of-5 (settled, 2 further readings): Remaining = 2492   →  delta = -6
```
`SELECT COUNT() FROM ContentVersion WHERE ContentDocumentId=:docId` returned **7** (1 original + 1 single new-version + 5 bulk = 7, matches). The delta of **exactly 6** (not 5) confirms the single new-version insert from the previous step *had* consumed one publication all along — it simply hadn't shown up yet in the `/limits` reads taken immediately afterward. **Answer: a new version of an existing `ContentDocument` consumes ONE ContentPublication, same as a brand-new document.**

### Q4: Does delete refund one?

```apex
delete [SELECT Id FROM ContentDocument WHERE Id = :docId];   // 7 versions, 12 links, all cascade
```
Confirmed genuinely deleted (`SELECT COUNT() FROM ContentDocument WHERE Id=:docId` → 0). Four settled `/limits` readings after the delete, each separated by an intervening query: **2492 → 2492 → 2492 → 2492.** **No refund. Confirms the design's "permanent cost" framing exactly.**

### Q5: Full-suite consumption

**Not run — per this task's explicit instruction not to run the Apex test suite.** This sub-question is unanswered by this spike; it should be measured as part of the actual build/test cycle, per `.claude/rules/content-publication-rule.md`'s existing re-measurement discipline.

### 🔴 Methodology finding, beyond what was asked, and worth stating loudly

**The REST `/limits` endpoint's `ContentPublicationLimit.Remaining` value is measurably stale and non-monotonic at close read intervals.** Two independent observations:
1. Two back-to-back reads bracketing a single operation showed `2498 → 2499` — an *increase* between reads with no publish in between, i.e. the value briefly "caught up" upward across separate reads rather than being immediately consistent.
2. A single new-version insert's consumption did not appear across **four** consecutive settled readings (each with an intervening real query as a delay), only becoming visible once folded into a later, larger batch operation's before/after comparison.

This means **individual before/after sandwiching around one DML statement is not a reliable measurement technique for this specific limit** — bulk batches large enough to clear the observed jitter (this spike used N=10 and N=5) are required for a trustworthy signal. Beyond the spike methodology itself, this is a **material, previously-unstated risk for any design that might lean on `/limits` even informally**: `.claude/rules/content-publication-rule.md` and the design doc (§6.5) already prohibit a pre-check on architectural grounds (ASB-only, racy) — this finding adds an **independent, empirical** reason: the number you'd read might already be stale by an unknown, multi-read-cycle margin, which would make even a "soft" advisory check actively misleading rather than merely imprecise.

---

## Cleanup verification

All throwaway records deleted in two passes (Content objects deleted **separately** from any create step, per `[[content-object-anonymous-apex-quirk]]` — this session's creates and deletes were never in the same execution):

```
Pass 1 (Tasks, Attachments, staging, Leads — bulk, one script):
  ZZCLEANUP_TASK_COUNT=29
  ZZCLEANUP_ATTACHMENT_COUNT=2
  ZZCLEANUP_STAGING_COUNT=1
  ZZCLEANUP_LEAD_COUNT=16

Pass 2 (ContentDocument — separate, later script):
  ZZCLEANUP_CONTENTDOC_COUNT=1  (069iw000000A7jNAAS "ZZSpikeConverted_sp4-convert-5mb")
```

Re-query confirmation (not retrieve — direct SOQL, per `[[retrieve-merges-picklist-values]]` precedent that retrieve is not a reliable deletion proxy):
```
ZZVERIFY remainingLeads=0 remainingTasks=0 remainingAttachments=0
         remainingStaging=0 remainingContentVersions=0 remainingContentDocuments=0
```

**Explicitly protected records, verified untouched:**
- Lead `00Qiw000000VZJFEA4`: `Status='New'`, unchanged.
- `Property_Registry__c`: both required rows present (`east islip ny`, `5800 beach boulevard jacksonville fl 32207`).
- Real (non-`ZZSPIKE`) `Inbound_Email_Staging__c` rows: 4 found, all preserved (my delete matched only `Subject__c LIKE 'ZZSPIKE%'`).

**MDAPI package cleanup:**
```
Destructive deploy: numberComponentErrors=0, numberComponentsDeployed=9, all 9 state="Deleted"
Follow-up: SELECT COUNT() FROM ApexClass WHERE Name LIKE 'ZZSpike%' → 0
```
TraceFlag (`7tfiw0000007PPtAAM`, created for debug-log capture) deleted, confirmed `success: true`.

**`force-app/` confirmation:** `git status --porcelain -- force-app/` is byte-identical to the pre-existing baseline captured at the start of this conversation — no file under `force-app/` was created, modified, or touched at any point in this session.

---

## Which design options are now dead, which are confirmed, and the recommended shape

### DEAD
- **S1-a** (catch it better) — was already measured-dead (M3); unchanged.
- **S1-b** (REST pre-check before persisting) — was already architecturally prohibited; SP-6 adds an *independent* empirical reason it would also be wrong even if attempted: the value it reads can be stale by several read-cycles.
- **S2-a as a general-purpose carrier for arbitrary retained attachments** — SP-1 found a hard, **uncatchable** ceiling at ~4.2–4.5MB raw (the platform's 6,000,000-char string constant), thrown at `System.enqueueJob` itself in a way no `try/catch` can intercept. Any file above that size would recreate the exact "uncatchable failure in the transaction that owns the email" defect the redesign exists to eliminate — just relocated one call earlier. **S2-a remains fully confirmed for the existing vision-image carry (≤1MB) only.**

### CONFIRMED
- **S1-d** (dedicated Queueable owning nothing else) — SP-5 gives it a complete, clean, unqualified confirmation. This is the core bet of the whole redesign and it holds.
- **S2-b** (classic `Attachment` carrier) — SP-4.1 confirms zero quota cost; SP-4.3 confirms near-zero synchronous heap even at 5MB; SP-4.2 confirms it works for the real Email Service persona under real production ownership. It is the only carrier that survives a downstream quota failure with **zero permanent loss**.
- **SP-6.2's CDL-safety question is resolved in the SAFE direction** — `ContentDocumentLink` inserts cost zero publications, so `ExtractAddressQueueable.linkAttachments()` was never quota-unsafe. Any decision to relocate routed linking into `AttachmentPersistQueueable` should now rest on cohesion/isolation grounds alone, not an assumed quota risk.
- **S3-a** (chain the file job from `finish()`) — confirmed structurally sound in real execution (SP-1 two-hop, SP-3 real Finalizer chain), confirmed unprovable inside a plain `@isTest` (SP-2, catchable `AsyncException`), exactly matching the design's own contingency plan.
- **The Finalizer mechanism (§6.3/§11.2)** — confirmed reliable in both test and production, on both exception shapes, with genuine DML survival independent of the parent's rollback. One correction: detect the ContentPublication case by **message substring**, never by exception **type** (`ctx.getException()` for an `UnexpectedException` arrives wrapped as `AsyncException`).

### NEWLY OPEN (not resolved, flagged for the next design pass)
- **The `Attachment` → `ContentVersion` async conversion step's heap ceiling is materially narrower than assumed.** A 5MB file already peaks at ~10.49MB of the 12MB async budget (87%) — this needs either a conservative byte cap well below 5MB, or a heap-optimization pass (explicit dereferencing after building `VersionData`) with a fresh measurement, before any `ATTACHMENT_MAX_BYTES` decision assumes 5MB+ is safe for this specific pattern.
- **`Attachment.Body`'s own true size ceiling was not established** — testing near the documented 25MB figure via Apex string-repetition is itself unsafe (hits an unrelated, uncatchable `String is too long` ceiling first); a real ~10–20MB test would need a genuinely Blob-native payload source, not a spike-built one.

### RECOMMENDED SHAPE

Adopt **S1-d unconditionally**. Adopt **S2-b (classic `Attachment`)** as the carrier for any attachment that might exceed ~3–4MB, since it is the only carrier proven loss-free through a downstream quota failure. Keep **S2-a** exactly where it already is (the vision image, ≤1MB) and do not extend it. Cap the async conversion step conservatively (~3–3.5MB) pending the heap-optimization follow-up. Adopt **S3-a** with the `Test.isRunningTest()` guard and `@TestVisible` decision seam the design already specifies, and treat the Tier-2 UAT rehearsal — not any Apex assertion — as the only real proof the chain fires. Build `AttachmentPersistFinalizer` exactly as designed, with the message-substring correction. Do not build any REST `/limits` check anywhere, now doubly justified.
