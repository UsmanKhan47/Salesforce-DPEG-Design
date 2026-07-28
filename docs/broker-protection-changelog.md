# Broker Protection — Changelog

**Date:** 2026-07-28
**Author:** Documentation Agent

---

## Phase 1/2 — Initial Build (2026-07-24)

Commit: `0af56b8` "Broker Protection: race-safe first-broker-wins for inbound email-to-Lead"

- From-scratch build: `EmailToLeadHandler` inserted a Lead **synchronously** at the email boundary
  (`LeadSource='Email-to-Lead'`, `Status='New'`), then enqueued `ExtractAddressQueueable` to call
  OpenAI, backfill via regex, and run the claim engine.
- 3 custom objects (`Property_Registry__c`, `Competing_Broker_Submission__c`, `Property_Claim_Lock__c`),
  4 Lead fields, 1 permission set (`Broker_Protection_Access`), 1 Named Credential +
  1 External Credential (`OpenAI_API` / `OpenAI_Credential`).
- 10 production Apex classes + 1 `HttpCalloutMock` + 10 test classes, 1 LWC
  (`competingBrokerSubmissions`) + Jest, `Lead_Record_Page` FlexiPage edit.
- Race-safety: unique `Property_Key__c` index (exact-match backstop) plus a
  `Property_Claim_Lock__c` `FOR UPDATE` pessimistic lock on a coarse cluster key (fuzzy-match
  backstop) — closed the fuzzy dual-winner race identified in code review (W4).
- Code review: **APPROVED — deploy-ready** after a fix delta resolved W1 (image MIME normalization),
  W3 (`applyName` unsafe split), and W4 (fuzzy dual-winner race). W2 (async failures logged via
  `System.debug` only) was explicitly deferred, and remains open as of this writing — see
  `docs/broker-protection-limitations.md`.
- Full detail: `docs/2026-07-24-broker-protection.md`; `agent-output/broker-protection-code-review.md`
  (first-pass review + the Δ fix-delta re-review).
- Companion `ARCHITECTURE.md` updates: §1 (`Property_Registry__c` / `Competing_Broker_Submission__c` /
  `Property_Claim_Lock__c` under a new "Lead Intake / Broker Protection" module), §2 (the 4 new Apex
  services), §3.3 (the direct-OpenAI-callout exception).

---

## Phases 3–5 — Staging Model Rework (2026-07-28)

Per `ARCHITECTURE.md` §2 ("Broker Protection staging model, added 2026-07-28"), the pipeline was
reworked from insert-then-update to a **staging-first, deferred-Lead-creation** design:

### What changed

- **New object:** `Inbound_Email_Staging__c` (16 fields) — the new durable landing record, written
  synchronously by `EmailToLeadHandler` **before** any Lead exists. Replaces "insert a raw Lead
  immediately so the email can't be lost" with "the raw email + RFC headers are the thing that can't be
  lost," which is strictly more durable (a Lead could only ever hold what the envelope said; the
  staging row holds the whole body and every header).
- **New service classes:** `InboundEmailStagingService` (the only writer of
  `Inbound_Email_Staging__c`), `InboundEmailStagingSelector` (its selector), `InboundEmailActivityService`
  (the only writer of the pipeline's `Task`), `InboundEmailFieldUtil` (pure clip/sanitize utility).
- **`EmailToLeadHandler` no longer creates a Lead.** It now does parsing only (envelope, RFC headers,
  inline image), writes the staging row, and enqueues `ExtractAddressQueueable(stagingId, imageBase64,
  imageMimeType)`.
- **`EmailToLeadService` collapsed from insert-then-update to a single insert.** The old
  `createLeadAndEnqueue` / `applyExtractedDetails` pair is gone, replaced by one method,
  `createLeadFromExtracted`, called only after extraction — the Lead is now born complete.
- **`ExtractAddressQueueable` gained a five-branch routing tree** (Reply → Repeat → No-Property →
  Duplicate → Winner), evaluated in that strict order. Only three of the five branches
  ((c) No-Property, (d) Duplicate, (e) Winner) create a Lead; Reply and Repeat file the inbound email
  onto an existing record instead.
- **`PropertyMatchingService` gained four new read methods** to support the two new branches:
  `findRecordByReplyHeaders`, `findBrokerSubmission`, `computeThreadKey`, `resolveLiveRecord`.
- **`PropertyClaimService` gained `logRepeatSubmission`** — an audit-only insert (no registry write, no
  duplicate flag) for the Repeat branch.
- **2 new Task/Activity fields:** `Inbound_Message_Id__c` (idempotency) and `Thread_Key__c`
  (conversation-root threading key) — the mechanism that makes reply detection possible at all.
- **`Broker_Protection_Access` permission set expanded** to cover `Inbound_Email_Staging__c` (full
  object CRUD, private sharing) and the 2 new Activity fields, alongside the original grants.
- **Degraded-extraction handling refined**: an LLM `CalloutException` is now caught specifically at the
  callout site (not the outer handler) and produces a distinct, filterable outcome label
  (`New Lead (no property) — LLM unavailable`) rather than a generic error.

### Why

Deferring Lead creation until the routing tree has decided a Lead is actually warranted is what makes
three previously-impossible behaviors possible: recognizing a **reply** inside an existing conversation,
recognizing a **repeat** from a broker who already submitted, and suppressing a **redelivered** message
— all three previously produced a junk Lead under the old insert-first design, which then had to be
cleaned up by hand.

### Test suite

10 test classes, 119 test methods, covering all five routing-tree branches, the degraded-extraction
path, idempotency, orphan adoption, and volume/scale sanity checks. See
`docs/broker-protection-testing.md` for the full breakdown, including the one identified gap (no
dedicated test class yet for the four newest staging-model classes).

### Documentation produced in this pass

- `docs/broker-protection-overview.md`
- `docs/broker-protection-architecture.md`
- `docs/broker-protection-setup.md`
- `docs/broker-protection-operations.md`
- `docs/broker-protection-testing.md`
- `docs/broker-protection-limitations.md`
- `docs/broker-protection-data-dictionary.md`
- `docs/broker-protection-faq.md`
- `docs/broker-protection-changelog.md` (this file)

`ARCHITECTURE.md` §1 ("Lead Intake / Broker Protection" module table, including the
`Inbound_Email_Staging__c` row) and §2 (the staging-model service rows) both already carried same-day
entries for this rework at the time this documentation was written — no further `ARCHITECTURE.md` edit
was needed for doc-currency (§6).
