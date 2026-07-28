# Broker Protection — Known Limitations & Roadmap

**Date:** 2026-07-28
**Author:** Documentation Agent

---

## Current State

| # | Limitation | Detail | Source |
|---|---|---|---|
| 1 | **Async/lock-wait failures are logged via `System.debug` only** | `ExtractAddressQueueable`'s catch-all, plus `PropertyClaimService`'s two fail-safe swallow points (lock-wait timeout; "duplicate key but no live winner and no orphan"). `System.debug` is ephemeral and off by default in production — a silently dropped claim on a commission-protection feature is currently invisible outside the staging row's own `Error__c`/`Outcome__c` (which *does* capture most failures durably — see note below). **Still open** per code review (W2), recommended before the pipeline carries a high volume of real broker traffic. | Code review W2, `agent-output/broker-protection-code-review.md` |
| 2 | **Cross-cluster fuzzy residual** | `deriveClusterKey`'s "first alphabetic token" rule skips ordinal street names: `"123 5th street"` → `"123 street"` but `"123 5th st"` → `"123 st"` — two fuzzy-similar addresses deriving *different* cluster keys will not serialize against each other, and could theoretically both win in a true race. The common case (`"123 Main St"` vs `"123 Main Street"`) is unaffected and tested. Optional future refinement: include the ordinal token in `deriveClusterKey`, or lock on the street number alone. | `PropertyMatchingService` class header; code review Δ New Finding #2 |
| 3 | **`Property_Claim_Lock__c` rows are never purged** | `allowDelete=false`, no TTL. Growth is bounded by *distinct-property* count (idempotent get-or-create reuse), not claim volume — negligible today; note for a future housekeeping job if lock-row cardinality ever becomes material. | Code review Δ New Finding #3 |
| 4 | **`LLMExtractionCalloutService.MODEL = 'gpt-4o-mini'` is hardcoded** | Suggested (not required) follow-up: move to Custom Metadata so the model can be tuned without a deploy. | Code review Suggestion 3 |
| 5 | **No dedicated unit test class for the four staging-model classes** | `InboundEmailFieldUtil`, `InboundEmailStagingService`, `InboundEmailStagingSelector`, `InboundEmailActivityService` (all added 2026-07-28) have no class-specific test file. They are exercised indirectly through `ExtractAddressQueueableTest` / `EmailToLeadHandlerTest`, so their code paths run, but no test asserts their specific contracts (e.g. `clip`'s exact truncation boundary, the fail-soft swallow in `InboundEmailStagingService.stamp`) in isolation. **Identified during this documentation pass** — not previously flagged in a code review artifact. | This documentation pass, verified against the current test-class inventory |
| 6 | **No org-native list view or alert on `Inbound_Email_Staging__c` yet** | Monitoring today is ad hoc (build/save a list view filtered on `Status__c = 'Error'` as described in `docs/broker-protection-operations.md`). Recommended before go-live at scale. | This documentation pass |
| 7 | **Reply threading requires the reply to re-enter the same Email Service address** | This is a structural property of the design (Task-based RFC threading, not EAC — see `docs/broker-protection-setup.md` §4), not a bug, but is worth reiterating as a limitation: a rep's direct reply from their own mailbox client is invisible to this pipeline unless forwarded/looped back into the monitored inbox. | `InboundEmailActivityService` class header; this documentation pass |
| 8 | **Broker emails must not exist on any Salesforce User** | General Salesforce email-routing/matching caution (list-email matching, any future Enhanced Email/EAC configuration) — an address collision with a User can misroute correspondence away from the Lead/Contact. Not currently enforced by validation; an admin process gap. | This documentation pass |
| 9 | **Direct OpenAI callout is a deliberate, temporary §3 exception** | `LLMExtractionCalloutService` bypasses the org's ASB-only integration rule because no ASB LLM-extraction spoke exists yet. Scoped and reversible — only the endpoint constant and the Named Credential it targets change when ASB exposes one; the public `extract(...)` signature and every downstream caller stay identical. | `ARCHITECTURE.md` §3.3; class header of `LLMExtractionCalloutService.cls` |

---

## Roadmap / Recommended Future Work

1. **Durable async-failure signal (addresses limitation #1).** Add one of: an `Enrichment_Failed__c`
   flag, a Platform Event, a dedicated error-log SObject, or a `System.Finalizer` on the Queueable.
   When implemented, it should also cover the two `PropertyClaimService` swallow points, not just the
   top-level `ExtractAddressQueueable` catch.
2. **List view + dashboard for `Inbound_Email_Staging__c`** (addresses limitations #5/#6). A saved list
   view filtered on `Status__c = 'Error'`, plus a small dashboard tracking daily submission count,
   success rate, and count of `LLM unavailable` outcomes (a proxy for OpenAI availability), would turn
   the current ad hoc monitoring into something an admin can check at a glance.
3. **Dedicated unit tests for the four staging-model classes** (addresses limitation #5). Even with
   indirect coverage through the queueable/handler tests, direct tests of `InboundEmailFieldUtil.clip` /
   `sanitizeEmail` boundary conditions and `InboundEmailStagingService`'s fail-soft `stamp` behavior
   under a forced `DmlException` would close a real gap in what the suite actually asserts.
4. **Cross-cluster fuzzy residual fix** (addresses limitation #2). Either widen `deriveClusterKey` to
   include ordinal tokens, or lock on the street number alone (trading contention for correctness) —
   left for post-POC per the original code review.
5. **Migrate `LLMExtractionCalloutService.MODEL` to Custom Metadata** (addresses limitation #4).
6. **Route to an ASB LLM-extraction spoke once one exists** (addresses limitation #9). Per
   `ARCHITECTURE.md` §3.3, this is a one-constant change plus a Named Credential swap — no caller
   changes required.
7. **If/when EAC or Enhanced Email is licensed for this org** (relevant to limitation #7), evaluate
   whether it's worth bridging EAC-logged Activities into the `Thread_Key__c` / `Inbound_Message_Id__c`
   matching this pipeline already does for Task, so a direct reply from a rep's own mailbox could also
   be recognized without requiring it to loop back through the monitored inbox. No such integration
   exists today and none is planned as part of the current build.
8. **Validate/enforce no broker-email-on-User collisions** (addresses limitation #8) — could be a
   scheduled report or a validation rule warning, rather than a hard block, since a legitimate
   dual-purpose address is possible in principle.
