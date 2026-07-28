# Broker Protection — Testing Guide

**Date:** 2026-07-28
**Author:** Documentation Agent

> **Note on scope.** The design/build task that introduced this feature originally estimated "48 tests
> across 3 classes." The actual, currently-deployed test suite is materially larger and spread across
> more classes — the counts below were obtained by reading the deployed test files directly
> (`grep -c "static void"` per class), not carried over from the earlier estimate. Document the real
> count, not the original estimate.

---

## Test Coverage Summary

| Test Class | Tests For | Method Count |
|---|---|---|
| `ExtractAddressQueueableTest` | `ExtractAddressQueueable` (the routing tree end-to-end) | 21 |
| `PropertyMatchingServiceTest` | `PropertyMatchingService` | 22 |
| `EmailToLeadServiceTest` | `EmailToLeadService` | 18 |
| `EmailToLeadHandlerTest` | `EmailToLeadHandler` | 14 |
| `PropertyRegistrySelectorTest` | `PropertyRegistrySelector` | 12 |
| `PropertyClaimServiceTest` | `PropertyClaimService` | 10 |
| `LLMExtractionCalloutServiceTest` | `LLMExtractionCalloutService` | 7 |
| `PropertyClaimLockSelectorTest` | `PropertyClaimLockSelector` | 6 |
| `CompetingBrokerSubmissionSelectorTest` | `CompetingBrokerSubmissionSelector` | 5 |
| `CompetingSubmissionControllerTest` | `CompetingSubmissionController` | 4 |
| **Total** | **10 test classes** | **119 test methods** |

`TestDataFactory` (the org-wide factory — `force-app/main/default/classes/TestDataFactory.cls`) was
extended, not forked, with `createPropertyRegistry(String, Id, Boolean)` and
`createPropertyClaimLock(String, Boolean)` helpers, per the org-wide convention.

### Coverage gap — no dedicated test class for the four newest (staging-model) classes

`InboundEmailFieldUtil`, `InboundEmailStagingService`, `InboundEmailStagingSelector`, and
`InboundEmailActivityService` — all four introduced by the 2026-07-28 staging-model rework — have **no
class-specific test file of their own** as of this writing. They are exercised **indirectly**: every
`ExtractAddressQueueableTest` and `EmailToLeadHandlerTest` scenario runs through real (unmocked)
instances of these four classes as collaborators, so their code paths do get executed by the existing
suite, but there is no test asserting their specific contracts in isolation (e.g. `clip`'s exact
truncation boundary, `sanitizeEmail`'s regex edge cases, `markProcessed`'s fail-soft swallow behavior
under a forced `DmlException`). See `docs/broker-protection-limitations.md`.

---

## Test Scenarios

### `ExtractAddressQueueableTest` — the routing tree, end-to-end

The most important test class in the suite; each method exercises one full pass through
`ExtractAddressQueueable.execute` against a mocked OpenAI callout:

- `execute_newUnclaimedProperty_createsWinnerLeadAndRegistersClaim` — branch (e), the base winner case.
- `execute_propertyAlreadyClaimed_marksNewLeadAsDuplicateNotSecondWinner` — branch (d).
- `execute_sameBrokerSameProperty_viaLlmEmail_filesOnExistingLeadAsRepeat` — branch (b), matched via
  the LLM-extracted broker email.
- `execute_sameBrokerSameProperty_viaEnvelopeFromFallback_filesOnExistingLeadAsRepeat` — branch (b),
  matched via the envelope `From` fallback (covers rows written before `Broker_Email__c` was populated).
- `execute_replyToExistingThread_filesOnThatRecordWithoutCreatingNewLead` — branch (a).
- `execute_noExtractableAddress_createsPlainLeadWithoutClaimingAnything` — branch (c), genuine no-address.
- `execute_llmCalloutFails_stillCreatesLeadFromRegexFallbackAndNeverErrors` — Degraded Extraction,
  landing in branch (c) with the `LLM unavailable` outcome label.
- `execute_llmCalloutFails_onAReplyThread_stillFilesOnThatRecordWithoutANewLead` — proves the outage
  degradation does not break reply detection (branch (a) still wins even when the LLM is down).
- `execute_duplicateMessageIdRedelivery_isSkippedNotReprocessed` — the idempotency guard.
- `execute_nullMessageId_processesNormallyWithoutIdempotencyCheck` — the deliberate "blank Message-ID
  skips the idempotency check but still routes normally" behavior.
- `execute_forwardedByFromStaging_flowsThroughToLeadForwardedByEmail` — field plumbing correctness.
- `execute_orphanedRegistryKey_isAdoptedByNewWinnerNotDuplicated` — the orphan-adoption race-recovery
  path (a winner's registry row survives after the winning Lead is deleted).
- `execute_stagingHardDeletedBeforeAsyncRun_returnsGracefullyWithoutError` — the staging-row-missing
  guard.
- `execute_forceClaimRaceSeam_stillReconcilesAsDuplicateViaClaimsOwnPreCheck` — uses the
  `@TestVisible forceClaimRace` seam to force `PropertyClaimService`'s duplicate-value recovery path.
- `execute_blankBrokerFields_backfillsFromRawFromLineViaRegex` /
  `execute_onlyBrokerNameBlank_regexFallbackDoesNotOverwriteLlmEmail` — the regex fallback's
  fill-blanks-only contract.
- `execute_unparseableSentDatetime_fallsBackToNow` — `parseSentDatetime`'s defensive default.
- `execute_manyConcurrentEmails_noCrossContaminationBetweenJobs` /
  `execute_replyThreadedAmong251PriorTasks_stillFindsTheCorrectThread` — volume/scale sanity checks
  (see *Bulk-Test-Rule Applicability* below for why this is not the mandatory 251-record pattern).

### `PropertyMatchingServiceTest` — the pure matching + read logic

Covers `normalizeAddress`, `calculateSimilarity` (Jaccard — identical/disjoint/blank/partial-overlap/
order-and-duplicate-insensitivity), `deriveClusterKey` (including the documented ordinal-street-name
residual case, `deriveClusterKey_fuzzyVariants_mapToTheSameClusterKey`), `findMatchingRegistry` (exact,
fuzzy-above-threshold, below-threshold, orphan-rows-ignored), and `findOrphanedRegistry`
(exists / has-live-winner / unregistered).

### `EmailToLeadServiceTest` — Lead field marshalling

Extensively covers `applyName`'s whitespace-safe split (single/two/three-token names, trailing space,
double space, null/blank → `Unknown`), the LLM-vs-envelope precedence for name/email, malformed-email
fallback, property-address stamping, `Forwarded_By_Email__c` stamping, and clipping of over-long
subject/body so a `STRING_TOO_LONG` never rolls back a claim.

### `EmailToLeadHandlerTest` — the intake boundary

Covers staging-row creation, RFC header capture, `X-Forwarded-For` / `Delivered-To` monitored-inbox
resolution (including the service-address-exclusion case), all three image-MIME shapes (bare `png`,
bare `jpeg`, already-qualified `image/png` — proving no double-prefixing), an adversarial
over-long/malformed-input case proving field-safety holds, and confirms the async job is enqueued.

### Selector and controller tests

`PropertyRegistrySelectorTest`, `PropertyClaimLockSelectorTest`, `CompetingBrokerSubmissionSelectorTest`
cover each selector's not-found contracts (empty list, never null) and ordering guarantees.
`CompetingSubmissionControllerTest` covers the happy path and `AuraHandledException` wrapping.
`LLMExtractionCalloutServiceTest` covers request shaping (text-only and image+text), response parsing,
code-fence stripping, and non-200 handling via `LLMExtractionCalloutMock` (`HttpCalloutMock`).

### Documented, deliberately-unreachable branches (accepted by code review)

Two branches are documented as legitimately unreachable in single-threaded Apex tests: a real `FOR
UPDATE` lock-wait timeout, and `registerWinner`'s live-winner re-check under serialization (a live
winner is always caught pre-insert once serialized). See `agent-output/broker-protection-code-review.md`.

---

## Bulk-Test-Rule Applicability

Per `.claude/rules/bulk-test-rule.md`'s **Exemption: Per-Transaction-Singleton Async Pipelines**
(added specifically for this feature): `EmailToLeadService`, `LLMExtractionCalloutService`,
`PropertyMatchingService`, and `PropertyClaimService` are single-record-per-transaction by design — one
inbound email produces exactly one Lead and one `ExtractAddressQueueable` execution, with no trigger and
no loop over multiple records. The 251-record mandate does not apply to these classes; a 251-record
same-transaction test would itself risk tripping unrelated governor limits (150 DML statements) while
proving nothing. `InboundEmailStagingService` and `InboundEmailActivityService` (added 2026-07-28) are
the same shape and fall under the same exemption for the same reason.

The suite does still include volume/scale sanity tests
(`execute_manyConcurrentEmails_noCrossContaminationBetweenJobs`,
`execute_replyThreadedAmong251PriorTasks_stillFindsTheCorrectThread`) — these exist to prove the
reply-matching SOQL (`ORDER BY CreatedDate DESC LIMIT 1` against up to 251 prior Tasks) still finds the
correct thread at volume, which is a different concern from the bulk-DML-in-loop question the 251-record
rule targets.

---

## How to Run

```bash
sf apex run test --class-names EmailToLeadServiceTest,EmailToLeadHandlerTest,ExtractAddressQueueableTest,LLMExtractionCalloutServiceTest,PropertyMatchingServiceTest,PropertyClaimServiceTest,PropertyRegistrySelectorTest,PropertyClaimLockSelectorTest,CompetingBrokerSubmissionSelectorTest,CompetingSubmissionControllerTest --wait 10
```

Or run the full org-local test suite (includes everything above plus the rest of the codebase):

```bash
sf apex run test --test-level RunLocalTests --wait 10
```

Jest tests for the `competingBrokerSubmissions` LWC live at
`force-app/main/default/lwc/competingBrokerSubmissions/__tests__/competingBrokerSubmissions.test.js`
and run via the repo's standard Jest tooling (`npm run test:unit` or equivalent) — Jest is local-only
and never deploys, per `ARCHITECTURE.md` §5.
