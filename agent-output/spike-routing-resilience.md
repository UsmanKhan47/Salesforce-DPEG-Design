# Spike Findings — Routing Resilience (SP-R1, SP-R2)

**Org:** `usman-dpeg` (`00Diw000000Fqw1EAC`), connected as `usman.khan.dpeg@avanzasolutions.com` (System Administrator)
**Date:** 2026-08-08
**Scope:** Investigation only, per instructions. **No feature code written, no metadata deployed to `force-app/`.** Eight throwaway diagnostic Apex classes were deployed via a standalone MDAPI package **outside `force-app/`** (`<session-scratchpad>/rr-spike-mdapi/`), exercised via `sf apex run` (anonymous Apex to enqueue) and polled via `sf data query` against `AsyncApexJob`/`Task`, then deleted via a destructive-changes MDAPI deploy. `git status --porcelain -- force-app/` was checked before and after and shows **0 changed files** both times.
**Design doc:** `agent-output/design-requirements-routing-resilience.md` §7 (SP-R1, SP-R2 — both marked BLOCKING).
**House style:** follows `agent-output/spike-attachment-persistence-v2.md`.

---

## Summary table

| # | Question | Answer | Confidence |
| --- | --- | --- | --- |
| SP-R1 | Does a Finalizer fire on an uncatchable governor `LimitException` (heap, CPU)? | **YES, on both**, in real (non-test) execution. `ctx.getResult() == UNHANDLED_EXCEPTION` for both. `ctx.getException().getTypeName()` reports **`System.AsyncException`** for both (wrapped, exactly as SP-3 found for `UnexpectedException`) — message-substring detection is required, never a type check, and this generalizes beyond the `ContentPublication` case SP-3 measured. **Supplementary, decisive finding:** both LimitExceptions were also confirmed to **escape an ordinary `try/catch(Exception e)`** wrapped directly around the exhausting code — the catch block never ran in either case — which is the exact premise the design's F1 row depends on (ExtractAddressQueueable's own wrapping catch). | High — 4 real (non-test) runs: heap uncaught, heap caught-attempt, CPU uncaught, CPU caught-attempt; all independently queried back from `AsyncApexJob` and `Task` |
| SP-R2 | Does `System.attachFinalizer` work inside a `Database.AllowsCallouts` Queueable, and does the Finalizer still fire after a callout? | **YES to both.** `attachFinalizer` succeeded with no synchronous exception in a class shaped exactly like `ExtractAddressQueueable` (`implements Queueable, Database.AllowsCallouts`). A real HTTP callout was made (not mocked). On `ParentJobResult.SUCCESS` the Finalizer fired and recorded `calloutMade=true`. On a deliberate unhandled exception thrown **after** the callout, the Finalizer still fired, still correctly reported `calloutMade=true`, and its own DML (a Task) committed durably. | High — 2 real (non-test) runs (return-normally and throw-after-callout), a real callout to an existing active RemoteSiteSetting, both outcomes independently queried back |

**Net effect on the design:** both blocking spikes pass. The Finalizer mechanism §3 of the design doc relies on is confirmed to work for the primary failure shape it exists to catch (heap/CPU governor limits), and it is confirmed to work inside the exact interface shape `ExtractAddressQueueable` uses (`Queueable, Database.AllowsCallouts`), including after a real callout. Nothing here invalidates the design; §12's D1 gate can move to "measured, not assumed."

---

## SP-R1 — Does a Finalizer fire on an uncatchable governor `LimitException`?

### Classes deployed

- `RRSpikeGovernorFinalizer implements System.Finalizer` — records `ctx.getResult()`, `ctx.getException().getTypeName()`/`.getMessage()`, and `ctx.getAsyncApexJobId()` onto a throwaway `Task` (`Subject = 'RRSPIKE_SPR1_' + label`).
- `RRSpikeHeapQueueable implements Queueable` — first attempt: attaches the Finalizer, then builds 50 iterations of a SHARED base string (`'X'.repeat(1000000)`) concatenated with the loop index, uncaught.
- `RRSpikeHeapQueueable2 implements Queueable` — corrected attempt: attaches the Finalizer, then loops **unconditionally** (`while (true)`), each iteration building a genuinely unique ~1.28MB string (a fresh SHA-256 hash of the loop index, `.repeat(20000)`), uncaught.
- `RRSpikeHeapCatchTestQueueable implements Queueable` — identical logic to `RRSpikeHeapQueueable2`, but the whole loop is wrapped in `try { ... } catch (Exception e) { insert Task '_CAUGHT'; }`.
- `RRSpikeCpuQueueable implements Queueable` — attaches the Finalizer, then a tight, uncaught, unconditional CPU-burning loop.
- `RRSpikeCpuCatchTestQueueable implements Queueable` — identical CPU-burn loop, wrapped in the same `try/catch`.

### Attempt 1 (heap, shared-base-string, uncaught) — AMBIGUOUS, methodology flaw, reported not hidden

```apex
public void execute(QueueableContext ctx) {
    System.attachFinalizer(new RRSpikeGovernorFinalizer(label));
    List<String> hoard = new List<String>();
    String chunk = 'X'.repeat(1000000);
    for (Integer i = 0; i < 50; i++) {
        hoard.add(chunk + String.valueOf(i));
    }
    insert new Task(Subject = 'RRSPIKE_SPR1_' + label + '_UNEXPECTED_SUCCESS', ...);
}
```

Enqueued (`707iw000001WWehAAG`). Result: `AsyncApexJob.Status = Completed`, `ExtendedStatus = null`. Task recorded:
```
RRSPIKE_SPR1_heap_UNEXPECTED_SUCCESS: "Heap exhaustion loop completed without throwing — hoard size 50"
RRSPIKE_SPR1_heap:                    "label=heap result=SUCCESS excType=null excMsg=null jobId=707iw000001WWehAAG"
```
🔴 **This did NOT trip the heap ceiling** even though the nominal content (50 × ~1,000,006 chars ≈ 50MB) is over 4× the documented 12MB async ceiling. **This is stated as ambiguous, not concluded from:** the most likely explanation is that the platform recognized `chunk + String.valueOf(i)` as sharing the immutable `chunk` buffer across all 50 concatenations (a rope/copy-on-write-style optimization), so the real accounted heap never reflected 50 independent 1MB allocations. This was **not independently isolated** — the methodology was corrected instead of pursued further, since the design only needs a genuine trip, not an explanation of why this specific pattern failed to produce one. Recorded so nobody re-uses this exact code shape expecting it to reliably exhaust heap.

### Attempt 2 (heap, unique-content, uncaught) — DECISIVE

```apex
public void execute(QueueableContext ctx) {
    System.attachFinalizer(new RRSpikeGovernorFinalizer(label));
    List<String> hoard = new List<String>();
    Integer i = 0;
    while (true) {
        String seed = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf('rrspike-heap-seed-' + i)));
        String piece = seed.repeat(20000); // ~1,280,000 chars, unique content every iteration
        hoard.add(piece);
        i++;
    }
}
```

Enqueued (`707iw000001X0SFAA0`). Result:
```
AsyncApexJob: Status=Failed, ExtendedStatus="Apex heap size too large: 52481351"
```
Finalizer's own Task, queried back independently:
```
RRSPIKE_SPR1_heap2: "label=heap2 result=UNHANDLED_EXCEPTION excType=System.AsyncException
    excMsg=System.LimitException: Apex heap size too large: 52481351
    External entry point jobId=707iw000001X0SFAA0"
```
**The Finalizer fired.** `ctx.getResult() == UNHANDLED_EXCEPTION`. Note the exception arrived wrapped as `System.AsyncException`, exactly the SP-3 pattern, and the real message is preserved as text inside it (`Apex heap size too large: 52481351`, i.e. ~52.5MB — the loop ran well past the 12MB async ceiling before the platform intervened, consistent with the ceiling being checked periodically rather than after every single allocation). Also notable: the stack trace reads `External entry point`, not a line/column inside `RRSpikeHeapQueueable2` — this failure was raised by the platform/VM boundary itself, not at an ordinary Apex statement, which is a second, independent signal (beyond the message content) that this is a structurally different kind of failure from an application-thrown exception.

### Attempt 3 (heap, unique-content, WRAPPED in `try/catch(Exception e)`) — settles catchability

```apex
public void execute(QueueableContext ctx) {
    System.attachFinalizer(new RRSpikeGovernorFinalizer(label));
    try {
        List<String> hoard = new List<String>();
        Integer i = 0;
        while (true) {
            String seed = EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf('rrspike-heapcatch-seed-' + i)));
            hoard.add(seed.repeat(20000));
            i++;
        }
    } catch (Exception e) {
        insert new Task(Subject = 'RRSPIKE_SPR1_' + label + '_CAUGHT', ...);
    }
}
```

Enqueued (`707iw000001X0FVAA0`). Result:
```
AsyncApexJob: Status=Failed, ExtendedStatus="Apex heap size too large: 52481355"
```
**No `_CAUGHT` Task was ever created** (confirmed by a direct query for `Subject LIKE '%_CAUGHT'` — zero rows, see Cleanup Verification below). The Finalizer's Task instead shows:
```
RRSPIKE_SPR1_heapcatch: "label=heapcatch result=UNHANDLED_EXCEPTION excType=System.AsyncException
    excMsg=System.LimitException: Apex heap size too large: 52481355
    External entry point jobId=707iw000001X0FVAA0"
```
**The `catch (Exception e)` never ran.** The heap-size `LimitException` escaped a syntactic try/catch positioned directly around the exhausting code and was reported to the Finalizer as `UNHANDLED_EXCEPTION` exactly as in the uncaught attempt. This is the same shape as `ExtractAddressQueueable`'s own wrapping catch at line 765 — a heap-exceeded death inside that catch's scope would escape it in exactly this way.

### CPU — uncaught and caught-attempt, both decisive on the first try

```apex
public void execute(QueueableContext ctx) {
    System.attachFinalizer(new RRSpikeGovernorFinalizer(label));
    Long counter = 0;
    while (true) {
        for (Integer i = 0; i < 100000; i++) {
            counter += (Long) i * i;
        }
    }
}
```
Enqueued uncaught (`707iw000001WyfGAAS`). Result:
```
AsyncApexJob: Status=Failed, ExtendedStatus="Apex CPU time limit exceeded"
RRSPIKE_SPR1_cpu: "label=cpu result=UNHANDLED_EXCEPTION excType=System.AsyncException
    excMsg=System.LimitException: Apex CPU time limit exceeded
    Class.RRSpikeCpuQueueable.execute: line 21, column 1 jobId=707iw000001WyfGAAS"
```
Same loop wrapped in `try/catch(Exception e)` (`707iw000001WOrIAAW`):
```
AsyncApexJob: Status=Failed, ExtendedStatus="Apex CPU time limit exceeded"
```
No `_CAUGHT` Task created. Finalizer's Task:
```
RRSPIKE_SPR1_cpucatch: "label=cpucatch result=UNHANDLED_EXCEPTION excType=System.AsyncException
    excMsg=System.LimitException: Apex CPU time limit exceeded
    Class.RRSpikeCpuCatchTestQueueable.execute: line 21, column 1 jobId=707iw000001WOrIAAW"
```
Unlike the heap case, the CPU exception's stack trace names a real class/line (`Class.RRSpikeCpuCatchTestQueueable.execute: line 21, column 1`) rather than `External entry point` — a minor asymmetry between the two failure shapes, noted but not load-bearing to the answer: both are uncatchable and both are reported by the Finalizer identically in outcome shape.

### ANSWER — SP-R1

**YES.** A Finalizer attached to a Queueable fires reliably when that Queueable dies from a genuine, uncatchable governor `LimitException` — both heap-size and CPU-time were independently confirmed, each with two runs (uncaught, and wrapped in `try/catch(Exception e)` that never actually catches it). `ctx.getResult()` reports `UNHANDLED_EXCEPTION` in every case. `ctx.getException().getTypeName()` reports `System.AsyncException` in every case (never the real `System.LimitException`), confirming the design's message-substring-detection requirement (R3/SP-3) generalizes from the `ContentPublication` case to governor limits generally. **Additionally confirmed, beyond what was asked:** both LimitException shapes genuinely escape an ordinary `try/catch(Exception e)` positioned directly around the failing code — this was not previously measured in this repo and is the literal premise `ExtractAddressQueueable`'s F1 failure state depends on.

---

## SP-R2 — Does `attachFinalizer` work in a `Database.AllowsCallouts` Queueable, and still fire after a callout?

### Classes deployed

- `RRSpikeCalloutFinalizer implements System.Finalizer` — a shared, mutable instance. `calloutMade` / `calloutStatusCode` / `calloutError` fields are set by the parent Queueable's `execute()` **before** it returns or throws, so the Finalizer's own `execute()` can report the callout outcome from the same instance later.
- `RRSpikeCalloutQueueable implements Queueable, Database.AllowsCallouts` — the exact interface shape `ExtractAddressQueueable` uses. Guards the `attachFinalizer` call in its own `try/catch` (to independently detect a synchronous rejection); if attach succeeds, makes a real HTTP callout to the existing, already-active `ApexDevNet` RemoteSiteSetting (`http://www.apexdevnet.com`, no `HttpCalloutMock`); then either returns normally or throws, per a constructor flag.

### Exact Apex

```apex
public void execute(QueueableContext ctx) {
    RRSpikeCalloutFinalizer fin = new RRSpikeCalloutFinalizer(label);
    Boolean attachThrew = false;
    String attachErr = null;
    try {
        System.attachFinalizer(fin);
    } catch (Exception e) {
        attachThrew = true;
        attachErr = e.getTypeName() + ': ' + e.getMessage();
    }
    if (attachThrew) {
        insert new Task(Subject = 'RRSPIKE_SPR2_' + label + '_ATTACH_THREW', ...);
        return;
    }

    Http h = new Http();
    HttpRequest req = new HttpRequest();
    req.setEndpoint('http://www.apexdevnet.com');
    req.setMethod('GET');
    req.setTimeout(20000);
    try {
        HttpResponse res = h.send(req);
        fin.calloutMade = true;
        fin.calloutStatusCode = res.getStatusCode();
    } catch (Exception e) {
        fin.calloutMade = false;
        fin.calloutError = e.getTypeName() + ': ' + e.getMessage();
    }

    if (throwAfterCallout) {
        throw new RRSpikeCalloutException('RRSPIKE deliberate unhandled exception after callout for ' + label);
    }
}
```

### Run A — attach + callout + return normally (`707iw000001WyVPAA0`)

```
AsyncApexJob: Status=Completed, ExtendedStatus=null
RRSPIKE_SPR2_r2a-success: "label=r2a-success result=SUCCESS calloutMade=true calloutStatusCode=404
    calloutError=null excType=null excMsg=null jobId=707iw000001WyVPAA0"
```
`System.attachFinalizer` succeeded with no synchronous exception. The real callout completed (`calloutStatusCode=404` — apexdevnet.com's root path returns a 404, which is itself proof a real HTTP round-trip happened, not evidence of failure to callout). The Finalizer fired on `ParentJobResult.SUCCESS` too, confirming Finalizers run on the success path as well as the failure path.

### Run B — attach + callout + throw AFTER the callout (`707iw000001WxDQAA0`)

```
AsyncApexJob: Status=Failed, ExtendedStatus="RRSPIKE deliberate unhandled exception after callout for r2b-throw"
RRSPIKE_SPR2_r2b-throw: "label=r2b-throw result=UNHANDLED_EXCEPTION calloutMade=true calloutStatusCode=404
    calloutError=null excType=RRSpikeCalloutQueueable.RRSpikeCalloutException
    excMsg=RRSPIKE deliberate unhandled exception after callout for r2b-throw jobId=707iw000001WxDQAA0"
```
**The Finalizer fired after a real callout was made and the job then died.** `calloutMade=true` proves the callout completed before the throw. Note the exception type here is **NOT** wrapped as `System.AsyncException` — it arrives as the real, ordinary custom exception type (`RRSpikeCalloutQueueable.RRSpikeCalloutException`). This is a useful additional data point: the wrapping-to-`AsyncException` behavior SP-3/SP-R1 measured appears specific to `UnexpectedException`/`LimitException`-class failures, not universal to every unhandled exception a Finalizer observes — an ordinary custom exception's real type survives intact. Detection logic that needs to work across both cases (as `AttachmentPersistFinalizer`'s does) is still correctly designed around message-substring matching, since that works regardless of which of the two behaviors applies.

### Attach-failure check

A direct query for `Subject LIKE '%ATTACH_THREW%'` returned **zero rows** across both runs — `System.attachFinalizer` never threw synchronously in this `Database.AllowsCallouts` Queueable, in either the success-path or the throw-after-callout-path run.

### ANSWER — SP-R2

**YES to both questions.** `System.attachFinalizer` succeeds without incident inside a `Queueable, Database.AllowsCallouts` class shaped identically to `ExtractAddressQueueable`. The attached Finalizer still fires after a real callout has been made and the job subsequently dies from an unhandled exception, and its own DML (the Task) commits durably and is independently queryable afterward — the same survival property SP-3/SP-5 established for plain Queueables.

---

## Cleanup verification

**Task records** (all `RRSPIKE_*`, throwaway, standard Subject/Description/Status/ActivityDate fields only — never any Broker Protection object, never `Inbound_Message_Id__c`/`Thread_Key__c`, never a Lead):
```
Before delete: 8 rows (RRSPIKE_SPR1_heap, RRSPIKE_SPR1_heap_UNEXPECTED_SUCCESS,
    RRSPIKE_SPR2_r2a-success, RRSPIKE_SPR2_r2b-throw, RRSPIKE_SPR1_cpu, RRSPIKE_SPR1_heap2,
    RRSPIKE_SPR1_heapcatch, RRSPIKE_SPR1_cpucatch)
Deleted via anonymous Apex bulk delete: RRCLEANUP_TASK_DELETED_COUNT=8
Re-query (not retrieve): RRCLEANUP_TASK_REMAINING=0
```

**Apex classes** — destructive-changes MDAPI deploy (`0Afiw000000H0jZCAS`), all 8 confirmed `state=Deleted`, `numberComponentErrors=0`:
```
RRSpikeGovernorFinalizer, RRSpikeHeapQueueable, RRSpikeHeapQueueable2, RRSpikeCpuQueueable,
RRSpikeHeapCatchTestQueueable, RRSpikeCpuCatchTestQueueable, RRSpikeCalloutFinalizer,
RRSpikeCalloutQueueable
```
Re-query confirmation (direct SOQL, not retrieve):
```
SELECT COUNT(Id) FROM ApexClass WHERE Name LIKE 'RRSpike%' → 0
```

**`force-app/` confirmation:** `git status --porcelain -- force-app/` returns 0 lines both before and after this session's work — no file under `force-app/` was created, modified, or touched at any point.

**Explicitly protected records:** no `Property_Registry__c`, `Inbound_Email_Staging__c`, `Lead`, or `Inbound_Message_Id__c`/`Thread_Key__c`-bearing `Task` was created, read, or modified by any script in this spike.

---

## Verdict

**YES — a Finalizer on `ExtractAddressQueueable` can catch the failures this design targets.**

Both blocking spikes pass cleanly, with no ambiguity in the load-bearing results (the one ambiguous result — the first heap-exhaustion attempt — was a methodology artifact that was identified, explained, and superseded by a corrected measurement, not left standing as evidence). Specifically:

1. **SP-R1:** a Finalizer fires on both heap-size and CPU-time `LimitException`s, the two governor-limit shapes the design's F1 failure state names as its primary target — and, going further than asked, both shapes are confirmed to genuinely escape an ordinary `try/catch(Exception e)` positioned directly around the failing code, which is the literal condition under which `ExtractAddressQueueable`'s own wrapping catch (line 765) would fail to help and the Finalizer becomes the only recording mechanism.
2. **SP-R2:** `System.attachFinalizer` works without incident in a `Queueable, Database.AllowsCallouts` class, and the attached Finalizer still fires — and its DML still commits durably — after a real callout has completed and the job subsequently dies. `ExtractAddressQueueable` makes exactly one callout (the LLM extraction) per execution, so this directly clears the concrete risk the design doc named: that every previously-measured Finalizer (SP-3, `AttachmentPersistQueueable`) was on a plain `Queueable` and parity with a callout-enabled one was unproven.

One correction for the eventual build, beyond what was already known from SP-3: **the exception-wrapping behavior is not universal.** SP-3 and this spike's heap/CPU cases show the platform wrapping the real exception as `System.AsyncException` (message-substring detection required, exactly as the design already specifies). But SP-R2's ordinary custom exception (thrown after a callout) arrived at the Finalizer with its **real, unwrapped type** (`RRSpikeCalloutQueueable.RRSpikeCalloutException`). This does not change the recommended design (message-substring matching still works in both cases, and is still the only approach that works in all cases), but it means a future reader should not assume every `ctx.getException()` a Finalizer sees is wrapped — only `UnexpectedException`/`LimitException`-class failures were observed to be.

Nothing measured here invalidates any part of §3 of the design document. §12 D1 ("run the spikes first") is satisfied; the design may proceed to Gate 1 approval on this point without further measurement.
