# Code Review — Broker Protection Feature

**Date:** 2026-07-24
**Verdict:** APPROVED WITH WARNINGS (0 Critical · 4 Warnings · 3 Suggestions)
**Scope:** 9 Apex classes + 9 test classes + `LLMExtractionCalloutMock` + `TestDataFactory` additions; `competingBrokerSubmissions` LWC + Jest; 4 Lead fields; `Property_Registry__c` + `Competing_Broker_Submission__c` (13 fields, 2 validation rules); `Broker_Protection_Access` permission set; `OpenAI_Credential` / `OpenAI_API`; `Lead_Record_Page` flexipage edit.

No deploy-blocking issues. A demo deploy can proceed; Warnings 1–3 should be fixed before the pipeline carries real broker traffic.

## Rulings on the three flagged architectural questions

1. **read-USER_MODE / write-system-mode split — ACCEPTED.** Verified repo house style (all key services use plain DML; all selectors use `WITH USER_MODE`). Defensible for an automated/system async pipeline; justified in the class headers. **Caveat:** the backend claim-engine reads run under the email-service user in USER_MODE, so a *missing* `Broker_Protection_Access` assignment makes those reads **throw**, and the throw is swallowed (Warning 2) → the ledger silently no-ops. The perm-set assignment must be a **verified deploy gate**, not a nicety.
2. **Direct OpenAI callout vs §3 ASB-only — ACCEPTED.** Complete, honest §3-exception justification in `LLMExtractionCalloutService` header (no ASB LLM spoke exists; scoped/reversible; credentials externalized). Doc follow-up: amend ARCHITECTURE.md §3 to record the exception (Suggestion 1).
3. **Single-record signatures vs §2 "collections" / 251 bulk — ACCEPT single-record; do NOT require List signatures.** One-email-per-async-transaction; no trigger, no loops, no SOQL/DML in loops. A 251-record same-transaction test would itself break the 150-DML limit and test nothing real. Layering intent (bulk-safe, no SOQL/DML in loops) is satisfied.

## Warnings (fix before real broker traffic; demo deploy can proceed)

1. **CONFIRMED — malformed `data:` URL for bare-subtype image attachments.** `EmailToLeadHandler.cls:44-48` admits bare subtypes (`'jpeg'`/`'png'`) but forwards the raw `mimeTypeSubType`; `LLMExtractionCalloutService.cls:139` builds `data:png;base64,...` (missing `image/`), which OpenAI vision rejects (HTTP 400). Text path still works, Lead still created, exception caught. **Fix:** normalize in the handler — `imageMimeType = subtype.startsWith('image/') ? att.mimeTypeSubType : 'image/' + subtype;` and update `EmailToLeadHandlerTest.cls:101-102` to assert `data:image/png;base64,`.
2. **Async failures swallowed with no durable signal.** `ExtractAddressQueueable.cls:111-117` catches all exceptions and logs only via `System.debug` (ephemeral, off by default). Any callout/FLS/DML/claim failure silently drops the claim — invisible for a commission-protection feature. **Fix:** emit a durable signal — `Enrichment_Failed__c` flag, Platform Event, error-log SObject, or a `System.Finalizer` on the Queueable.
3. **`applyName` unsafe split.** `EmailToLeadService.cls:143-151`: `split(' ')` + `parts[1]` throws on trailing space (`'Jane '` → index out of bounds), blanks LastName on double space, drops the tail on 3+ tokens. Via `createLeadAndEnqueue` (email.fromName) the throw **bounces the email and loses the Lead**. **Fix:** `trim()`, split on `\\s+`, guard `parts.size()`; add tests for `'Jane '`, `'Jane  Broker'`, `'Mary Jane Watson'`.
4. **Fuzzy-match dual-winner race (documented).** `PropertyMatchingService.cls:19-31`: race-safety is exact-string only (the unique key); two simultaneous *differently-worded-but-similar* submissions can both win. Not a code defect — an accepted POC boundary. **Needs explicit sign-off.** Future fix: serialize claims behind a single-concurrency queue, or canonicalize before the uniqueness check.

## Suggestions

1. Amend ARCHITECTURE.md §3 to record the accepted direct-OpenAI exception (§6 doc-currency).
2. Add a `bulk-test-rule.md` / §2 carve-out for per-transaction-singleton async pipelines (inbound email + single-record Queueable), exempting them from the 251-record mandate.
3. Move `LLMExtractionCalloutService.MODEL = 'gpt-4o-mini'` to Custom Metadata so the model tunes without a deploy.

## Acknowledged good practices

Clean layer purity (all SOQL in selectors, USER_MODE; no SOQL/DML in queueable/handler/controller); Queueable+AllowsCallouts (no `@future`); full §1 naming conformance; correct SetNull + insert-scoped validation-rule "required" pattern; exemplary credentials (`allowMergeFieldsInHeader`, fully-qualified `{!$Credential...}`, NamedPrincipal, no key in metadata); LWC single `@wire` on cacheable with real error toast + accessible markup; high-quality tests (`Assert`, no SeeAllData, `HttpCalloutMock`, `Test.start/stopTest`, `forceClaimRace` covers the race-recovery branch).

## Action list

- **Critical:** none.
- **Warnings:** (1) mime data-URL fix + test update; (2) durable async-failure signal; (3) harden `applyName`; (4) sign off the fuzzy dual-winner race + make the perm-set assignment a verified deploy gate.
- **Suggestions:** §3 doc amendment; bulk-rule carve-out; model to Custom Metadata.

---

# Δ Re-review — Fix Delta (W1 / W3 / W4)

**Date:** 2026-07-24
**Scope:** ONLY the fix delta applied after the first review. Files re-read: `EmailToLeadHandler.cls`, `EmailToLeadHandlerTest.cls`, `LLMExtractionCalloutService.cls` (buildRequestBody), `EmailToLeadService.cls` + test, `PropertyClaimService.cls`, `PropertyMatchingService.cls`, `PropertyClaimLockSelector.cls` + test, `PropertyClaimServiceTest.cls`, `PropertyMatchingServiceTest.cls`, `ExtractAddressQueueable.cls`, `Property_Claim_Lock__c` object + `Cluster_Key__c`, `Broker_Protection_Access` perm set, `TestDataFactory` additions.
**Delta verdict:** ✅ **APPROVED — deploy-ready.** All three warnings correctly and completely resolved; no new defect introduced. The only open item is the pre-existing, explicitly-deferred **W2** (durable async-failure signal).

## Per-fix confirmation

| Fix | Correct & complete? |
|-----|---------------------|
| **W1 — image MIME normalization** | ✅ YES |
| **W3 — `applyName` hardening** | ✅ YES |
| **W4 — serialized claim (FOR UPDATE cluster lock)** | ✅ YES |

### W1 — CONFIRMED correct & complete
`EmailToLeadHandler.cls:52-54` ternary keys off the already-lowercased `subtype`: bare `png`/`jpeg` → `image/png`/`image/jpeg`; an already-qualified `image/png` matches `startsWith('image/')` and passes through **unchanged** (no double-prefix). `LLMExtractionCalloutService.cls:139` (unchanged — correctly untouched, since the defect was the upstream `imageMimeType` value) then builds a valid `data:image/…;base64,`. Tests assert all three shapes: `data:image/png;base64,` for bare `png` (`EmailToLeadHandlerTest:99-100`), `data:image/jpeg;base64,` for bare `jpeg` (`:160-161`), and single-prefixed + explicit NOT-`data:image/image/png` for the already-qualified case (`:131-134`).

### W3 — CONFIRMED correct & complete
`EmailToLeadService.applyName:151-167`: `trim()` → `isBlank` guard → `split('\\s+')` → `size()==1` LastName-only → else `FirstName=parts[0]`, `remove(0)`, `LastName=String.join(tail,' ')`. Every index guarded; the tail is joined not dropped. `'Jane '`→LastName `Jane` (no IOOB); `'Jane  Broker'`→`Jane`/`Broker` (no blank LastName); `'Mary Jane Watson'`→`Mary`/`Jane Watson`; blank/null→`Unknown`. Both call sites safe: `createLeadAndEnqueue` (null-guarded at :74-78, blank handled inside `applyName`) and `applyExtractedDetails` (`isNotBlank`-guarded at :112). Tests exercise trailing-space, double-space, 3-token, and whitespace-only through **both** entry points (`EmailToLeadServiceTest:98-159, 225-266`).

### W4 — CONFIRMED correct & complete (rigorous findings below)

1. **Race actually closed.** `PropertyClaimService.claim:63-89` acquires the cluster lock (`acquireClusterLock`) **before** the authoritative `findMatchingRegistry` at :83. Two concurrent same-cluster claims serialize; the second reads the first's committed registry (exact or fuzzy) and routes to `markDuplicate`. The queueable's unlocked pre-check (`ExtractAddressQueueable:101-107`) is only a cheap short-circuit — the binding decision is the in-lock one.

2. **Get-or-create-then-lock is SOUND — no residual hole.** *(the ruling you asked for)* The safety invariant is structural: `acquireClusterLock` returns `true` **only** from inside `if (!selectByClusterKeyForUpdate(...).isEmpty())` (:181), i.e. only when a row was actually FOR UPDATE-locked. **There is no code path that proceeds "as if locked" without holding a lock.** Tracing the concurrent-creator gap: A and B both see no row, both `insert`; B's insert **blocks** on A's uncommitted unique `Cluster_Key__c` row. B's insert can only raise `DUPLICATE_VALUE` *after A commits* (lock row **and** registry commit together) — B catches it (`ensureLockRow:212-218`), then B's subsequent `selectByClusterKeyForUpdate` **reliably sees and locks the now-committed row**, because lock rows are **never deleted** (`allowDelete=false`, no delete code anywhere), so a row that caused a dup cannot then be missing. And even in the theoretical empty-FOR-UPDATE case, the code does **not** proceed unserialized — it loops once more, then returns `false` → the caller **fails safe** (aborts the claim, leaves a normal Lead). Net: the worst case is a false-negative abort, **never** an unserialized dual-proceed. The only residual is the documented **cross-cluster fuzzy** case (two similar addresses deriving *different* cluster keys), which is bounded by `deriveClusterKey`'s coarseness and honestly disclosed in `PropertyMatchingService:34-42`.

3. **Lock-wait timeout fails safe.** `acquireClusterLock:178-194` catches `QueryException` (UNABLE_TO_LOCK_ROW), retries in a **bounded** 2-iteration loop, then returns `false`; `claim:69-78` logs and returns, leaving a normal unclaimed Lead. No crash, no lost Lead, no infinite spin. (Durability of the signal is `System.debug` — see New Findings #1.)

4. **Cluster-key coarseness adequate.** `deriveClusterKey:109-131` = street number + first alphabetic token, so `'123 main street'` / `'123 main st'` / `'123 main street unit 4'` all → `'123 main'` (proven in `PropertyMatchingServiceTest:87-97`). Number-not-first handled (`'main street 123'`→`'123 main'`); fallback to full normalized string when no number/alpha token (:108-113). Reasonable.

5. **Layer purity held.** FOR UPDATE SOQL lives in `PropertyClaimLockSelector` (`WITH USER_MODE`, `LIMIT 1`, no `ORDER BY`, `FOR UPDATE` — legal with USER_MODE); lock-row `insert` DML is in the service (`ensureLockRow:211`); `PropertyMatchingService` holds zero SOQL. The only in-loop SOQL/DML is the **bounded** (2×) lock-acquire retry — single-record-per-transaction, well within limits.

6. **Perm set correct.** `Broker_Protection_Access:108-116` grants `Property_Claim_Lock__c` `allowRead` + `allowCreate` + `viewAllRecords=true` (global visibility for the lock). `Cluster_Key__c` needs no field-permission stub — it is `required`, so read FLS is implicitly granted, and the queries select only `Id` (filtering on `Cluster_Key__c` in WHERE). **Caveat (unchanged from original):** the perm set must be **assigned to the running Email-Service/Automated-Process user** or the USER_MODE FOR UPDATE reads throw — still a verified deploy gate, not new.

7. **§1 naming clean.** `Property_Claim_Lock__c` / `Cluster_Key__c` — Title_Case_With_Underscores, no object-name collision, no rule-9 type-suffix trap (Text "Key" bucket, not a masked Date/Number/Boolean).

8. **Tests meaningful; uncovered branches legitimately unreachable.** `claim_fuzzyVariantInSameCluster_stillRoutesToMarkDuplicateUnderLock` proves the in-lock recheck (Jaccard 3/5 = 0.6 at threshold) routes to `markDuplicate` with no second registry row; `claim_calledTwiceForSameCluster_createsOnlyOneLockRow` proves idempotent get-or-create; `claim_blankNormalizedAddress_failsSafeWithoutAnyDml` covers the fail-safe deterministically. The two documented-uncovered branches (real FOR UPDATE lock-wait retry; `registerWinner`'s live-winner re-check) are genuinely **not single-thread reproducible** (Apex tests are single-threaded; under serialization a live winner is always caught pre-insert) — accepted.

## New findings (from the delta) — none deploy-blocking

| # | Severity | File:line | Finding | Fix |
|---|----------|-----------|---------|-----|
| 1 | 🟢 Suggestion (extends open W2) | `PropertyClaimService.cls:73-77` and `:154-156` | The new W4 fail-safe paths (lock-wait timeout; "duplicate key but no live winner and no orphan") swallow with `System.debug` only — the same ephemeral-durability gap as the still-open **W2**. Not a new blocker (both fail *safe* and preserve the Lead), but they widen the surface W2's remediation must cover. | When W2 is addressed (durable flag / Platform Event / log SObject / `System.Finalizer`), include these two `PropertyClaimService` swallow points. |
| 2 | 🟢 Suggestion (within documented residual) | `PropertyMatchingService.deriveClusterKey:114-127` | "First **alphabetic** token" means an ordinal street name gets skipped: `'123 5th street'`→`'123 street'` but `'123 5th st'`→`'123 st'`, so those two fuzzy variants derive **different** cluster keys and would not serialize. Common case (`'123 Main St/Street'`) is unaffected and tested. | Optional future refinement (e.g. include the ordinal token, or lock on the number alone). The fuzzy match remains the within-run arbiter; leave for post-POC. |
| 3 | 🟢 Suggestion | `Property_Claim_Lock__c` (object) | Lock rows are never purged (`allowDelete=false`, no TTL). Growth is bounded by *distinct-property* count (idempotent reuse), not claim volume — negligible for the demo. | No action for POC; note for a future housekeeping job if lock cardinality ever matters. |

## Regression check — clean
- **W2 (async failures swallowed)** and **W4-old (fuzzy dual-winner race)** were the only deferred items; W4-old is now resolved, **W2 remains open** (`ExtractAddressQueueable:111-117` unchanged).
- No regression in `EmailToLeadHandler` (only W1 normalization changed), `EmailToLeadService` (only W3 `applyName` changed; call-site behavior preserved), `LLMExtractionCalloutService` (correctly untouched), or `ExtractAddressQueueable` (`forceClaimRace` seam + unlocked-pre-check short-circuit intact; the unlocked `markDuplicate` path is race-safe because it inserts no unique-key row).
- `TestDataFactory` provides the referenced helpers (`createPropertyClaimLock(String,Boolean)` :2165, `createPropertyRegistry(String,Id,Boolean)` :2067) — the added tests compile.

## Delta verdict
✅ **APPROVED — deploy-ready.** W1, W3, and W4 are each correct and complete, with no new defect above Suggestion level. The get-or-create-then-lock serialization is **sound** (no residual hole; failure modes fail safe, never dual-proceed). The feature's remaining open item is the single pre-existing, deferred **W2** (make the async/lock-wait failure signal durable) — recommended before real broker traffic, and its remediation should now also cover the two W4 `System.debug` swallow points (New Finding #1). Demo deploy can proceed.
