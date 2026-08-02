# Broker Protection — Operational Runbook

**Date:** 2026-07-28
**Author:** Documentation Agent
**Audience:** Admins and Acquisition-team leads monitoring the live pipeline.

---

## Monitoring

- **List view on `Inbound_Email_Staging__c` filtered by `Status__c = 'Error'`.** Every terminal state
  of the async job is written back to the staging row (`InboundEmailStagingService.markProcessed` /
  `markSkipped` / `markError`), so an `Error` row means the routing tree threw an exception *after* the
  staging row itself was successfully written — the raw email is never lost, only the routing/claim/Task
  step failed.
- **Check `Error__c`** on any Error-status row for the full exception type, message, line number, and
  stack trace (`ExtractAddressQueueable`'s catch-all builds this string before calling `markError`).
- **`Outcome__c`** on a `Processed` row tells you which routing branch fired — use the constants from
  `ExtractAddressQueueable` as your filter vocabulary:
  - `New Lead (winner)` / `New Lead (unclaimed)` — branch (e), claimed or fell back to unclaimed
    (lock-wait timeout or an unrecoverable duplicate key — rare).
  - `Competing Submission` — branch (d), no Lead (changed 2026-07-31; a competing broker gets only a
    `Competing_Broker_Submission__c` against the winner). `Competing Submission (race)` is the same
    outcome reached via branch (e)'s lost-race tail (a Lead was briefly created, then deleted). Rows
    processed before 2026-07-31 may instead carry the retired `Competing Duplicate` label — see
    "Duplicate Lead created" below and `docs/broker-protection-data-dictionary.md` "Outcome label
    history" for the full three-era mapping.
  - `Repeat` — branch (b), no new Lead. Lands on the broker's own Lead if they are the winner, or on
    the **winning** Lead if they are a competing broker (who has none of their own).
  - `Reply Thread` — branch (a), no new Lead.
  - `New Lead (no property)` — branch (c), address genuinely not found.
  - **`New Lead (no property) — LLM unavailable`** — branch (c) reached because the OpenAI callout
    failed (429/5xx/timeout), **not** because the email had no address. These are the Leads worth
    re-extracting once OpenAI recovers — filter on this label specifically to find them.
  - `Duplicate Delivery (skipped)` — the platform redelivered an already-processed Message-ID; nothing
    was reprocessed, by design.
  - **`Not Acquisition (gated)`** *(added 2026-07-31)* — the LLM classified the email
    `is_acquisition_related = false` at HIGH confidence (≥ 0.85). No Lead, no claim; the email is
    still logged as a Task and `Extracted_JSON__c` still holds the model's response.
  - **`Not Acquisition (pre-filtered)`** *(added 2026-07-31)* — the envelope From or a raw header
    matched a machine-sender/auto-reply pattern (`noreply`, `mailer-daemon`, `Auto-Submitted`, ...)
    and the email was rejected **before the LLM callout ever ran**. `Extracted_JSON__c` holds a
    `{"skipped":"pre-filter","reason":"..."}` marker, not a model response.
  - **`Multi-Property (N): ...`** *(added 2026-07-31)* — one email produced more than one routed
    result, e.g. `Multi-Property (3): 1 New Lead (winner), 1 Competing Submission, 1 Repeat`. See
    "Multi-property emails" below for how to read the full breakdown.
- **Two suffixes can append to any outcome** *(added 2026-07-31)*: `[truncated: 10 of M]` when an
  email pitched more properties than the `MAX_PROPERTIES` cap of 10 (the first 10, in a deterministic
  sorted order, were routed; the rest are described in the first Lead's `Deal_Notes__c` and preserved
  verbatim in `Extracted_JSON__c`), and `[unclaimed: lock timeout]` when at least one property in a
  multi-property email failed safe on lock contention rather than a genuine deadlock (rare; was
  previously invisible, logged only via `System.debug`).
- **A cluster of `New Lead (no property) — LLM unavailable` outcomes in a short window** is the
  signal that OpenAI is down or the API key is invalid/expired — check `Error__c` on a representative
  row for the HTTP status if present, and see "LLM extraction failed" below.
- **A cluster of `Not Acquisition (gated)` outcomes for emails you believe ARE real deals** is the
  signal to review the gate threshold or the prompt's classification instructions — see "Gated and
  pre-filtered emails" below before assuming it's a one-off.

---

## Troubleshooting

### Email not becoming a Lead

1. Confirm the email actually reached the Email Service — check whether an `Inbound_Email_Staging__c`
   row was created at all. If **no row exists**, the email never reached `EmailToLeadHandler` — check
   the monitored inbox's forwarding rule and the Email Service's routing address configuration
   (`docs/broker-protection-setup.md` §1), not the Apex.
2. If a staging row exists with `Status__c = 'Pending'` and stays that way, the async job either hasn't
   run yet (check Setup → Apex Jobs) or was hard-deleted before the queueable ran
   (`ExtractAddressQueueable.execute` logs and returns cleanly in that case — check debug logs for
   "staging record ... not found").
3. If `Status__c = 'Processed'` but `Result_Record_Id__c` is blank, check `Outcome__c` — this is
   expected for `Reply Thread` and `Repeat` (no new Lead by design), not a bug.
4. If `Status__c = 'Error'`, read `Error__c` for the exception detail (see Monitoring above).

### Reply not threading onto the existing record

1. Confirm the reply actually re-entered the monitored inbox / Email Service address — per
   `docs/broker-protection-setup.md` §4, a reply sent directly from a rep's own mailbox that never
   loops the monitored inbox back in will never reach this pipeline at all. This is the most common
   cause and is not a defect.
2. If the reply did re-enter the pipeline (a new staging row exists for it), check its
   `In_Reply_To__c` / `References__c` fields are populated — some mail clients/relays strip these
   headers, in which case `PropertyMatchingService.findRecordByReplyHeaders` has nothing to match
   against and the email is routed as if it were new (falls through to branch (b)/(c)/(d)/(e)).
3. Verify the *original* email's Task carries a `Thread_Key__c` — query
   `SELECT Id, Thread_Key__c, Inbound_Message_Id__c FROM Task WHERE WhoId = :leadId` (or `WhatId` for a
   converted Lead's Opportunity) and confirm it is populated, not blank.

### No Lead appeared for a broker's email — is it a Repeat or a Competing Submission?

**As of 2026-07-31, neither a Repeat nor a Competing Submission produces a new Lead — this replaces the
old "duplicate Lead created" question entirely.** A competing broker's email now only ever produces a
`Competing_Broker_Submission__c` row (never a Lead of their own), so "no Lead appeared" is the expected
shape for both branches, not a symptom to chase. Check `Outcome__c` on the staging row instead of any
Lead field:

- **`Competing Submission`** (or the pre-2026-07-31 retired label `Competing Duplicate`, on an older
  row) → branch (d) — a **different** broker already claimed this property. Query
  `Competing_Broker_Submission__c` where `Winning_Lead__c` = the record `Result_Record_Id__c` points at
  and `Source_Lead__c = null` to find the row; `Broker_Email__c` / `Broker_Name__c` on that row are the
  only record of who this broker was. This is correct, expected behavior, not a bug to fix.
- **`Competing Submission (race)`** → branch (e)'s lost-race tail — a Lead *was* briefly created for this
  broker, then deleted once the claim discovered a concurrent winner registered first. Also correct,
  expected behavior; the `Competing_Broker_Submission__c` row (again `Source_Lead__c = null`, cleared by
  the delete's `SetNull` constraint) is the only trace the Lead ever existed. See
  `docs/2026-07-31-competing-broker-no-lead.md` for the two-layer safety guard on this delete.
- **`Repeat`** → branch (b) — the same broker submitting the same property again. Filed on their own
  Lead if they are the winner, or on the **winning** Lead if they are a competing broker (who has none
  of their own) — either way, a `Competing_Broker_Submission__c` audit row is appended, never suppressed
  (see ARCHITECTURE.md §1's append-only contract for `Competing_Broker_Submission__c`).

**Historical rows only:** a Lead carrying `Is_Duplicate_Property__c = true` / a populated
`Duplicate_Of_Lead__c` is a duplicate-flagged Lead from before 2026-07-31 — both fields are now LEGACY
and unwritten by any code path. Do not expect to find one on a Lead created after that date.

If a Lead was created that you believe should have been a Repeat or a Reply, check whether the broker's
email address differs subtly between submissions (the repeat check matches on the LLM-extracted broker
email, then falls back to the envelope `From`) or whether the address wording differs enough to fall
below the 0.6 Jaccard similarity threshold — see `docs/broker-protection-limitations.md` for the
documented fuzzy-matching residual.

### Gated and pre-filtered emails (added 2026-07-31)

Use the `Gated_Not_Acquisition` list view on `Inbound_Email_Staging__c` (filters `Outcome__c
startsWith 'Not Acquisition'`) — **this is the only way to see what the gate rejected**, and checking
it periodically is what makes the gate trustworthy rather than a black box.

- **`Not Acquisition (pre-filtered)`** — a deterministic, envelope/header-only match (an automated
  sender or an RFC auto-reply header), which never reached the LLM. This filter is tuned for
  precision over recall and deliberately does **not** filter on `Precedence: bulk` — a legitimate
  broker blast platform (RCM, Crexi, Buildout) sets that header on a real listing, so bulk mail is
  intentionally routed to the LLM/gate instead of being silently discarded here. If a genuine broker
  email is pre-filtered, it will be an envelope/header match (check `Raw_Headers__c`), not a subject
  line — subject-keyword filtering was explicitly rejected by design.
- **`Not Acquisition (gated)`** — the LLM itself classified the email as confidently
  (`confidence ≥ 0.85`) not acquisition-related. If this looks wrong for a specific email, that is a
  prompt/threshold tuning question, not a bug — `Extracted_JSON__c` on the row holds the model's full
  response (including `email_category` and `confidence`) so you can see exactly what it decided and
  why.
- **A `Reply` into an existing thread is NEVER gated**, no matter what the classifier would have said
  about it in isolation — a header match on `In-Reply-To`/`References` is proof of an existing
  conversation and outranks a classifier's opinion. If a reply seems to have vanished, it did not go
  through the gate; see "Reply not threading" above instead.
- **Low-confidence "not acquisition" emails are NOT in this list view** — the soft tier (confidence
  below the hard-gate threshold) still creates a Lead and still claims; it surfaces instead as
  `Parse_Confidence__c = LOW` on the Review_Queue list view. See "Parse_Confidence__c and the Review
  Queue" below.

### Multi-property emails (added 2026-07-31)

One inbound email can now produce **up to 10** routed results (`ExtractAddressQueueable.MAX_PROPERTIES`),
one per distinct property the LLM extracted. This changes what "one staging row" means operationally:

- **`Result_Record_Id__c` still holds exactly one Id** — the PRIMARY result (the first new winning
  Lead, else the first competing-submission winner, else the first Reply/Repeat target). A
  single-property email is unaffected: this field means exactly what it always has.
- **`Routed_Record_Ids__c`** is the complete picture for a multi-property email: one line per routed
  property, in processing order, `<normalized address> | <outcome> | <recordId>`. This is the only
  place to see which specific property went where — query it directly, don't infer from
  `Outcome__c`'s summary alone.
- **`Property_Count__c`** is how many properties the extraction FOUND, before the 10-property cap and
  before de-duplication. Compare it against the number of lines in `Routed_Record_Ids__c`: a
  difference means either truncation (`Outcome__c` will say `[truncated: 10 of M]`) or the LLM
  repeating itself / returning an address-less entry (both are folded into
  `Deal_Notes__c` on the first Lead created, under "Additional properties in this email (not
  routed)").
- **One Task, not several, per DISTINCT record** — if two properties in the same email both resolve
  to the same record (e.g. two properties, same winner), that record gets exactly one Task for the
  email, not two.
- **Verifying the deadlock fix is working:** there is no direct signal that concurrency was avoided
  (it is a structural guarantee, not something a single staging row reports), but a
  `[unclaimed: lock timeout]` suffix on a *multi-property* row is worth investigating if it becomes
  frequent — see the suffix note under Monitoring above.

### Parse_Confidence__c and the Review Queue (added 2026-07-31)

`Parse_Confidence__c` (HIGH / MEDIUM / LOW) is Apex-derived from the LLM's numeric `confidence`
(≥ 0.85 → HIGH, 0.60–0.849 → MEDIUM, below 0.60 or missing/unparseable → LOW) and written on **every**
Lead this pipeline creates, not only the soft-gated ones. `LOW` is the operationally interesting value:
it is what the D2 soft-gate tier looks like on the Lead record — the email was uncertain enough that
the model was not sure it was acquisition-related, but not certain enough to hard-gate, so a Lead was
created and the property was still claimed (claiming a junk address costs one deletable registry row;
failing to claim a real one costs a broker their commission).

**`Review_Queue`** — the existing Lead list view filtering `Parse_Confidence__c = LOW` — is where this
surfaces; no new list view was built for it (it already existed before this change and needed no
modification). Working this queue periodically is the human-in-the-loop check on the gate's soft tier.

### LLM extraction failed

1. Check the staging row's `Error__c` (if `Status__c = 'Error'`) or the `Outcome__c` label
   `New Lead (no property) — LLM unavailable` on a `Processed` row.
2. A `CalloutException` (outage, timeout, non-200) **or, since 2026-07-31, a `JSONException`**
   (a malformed/truncated response) both degrade gracefully (see `docs/broker-protection-architecture.md`
   — Degraded Extraction) — the Lead is still created via the regex fallback, just without a property
   claim. A truncated response should now be rare — `MAX_TOKENS` was raised to 4096 and OpenAI JSON
   mode was enabled specifically to prevent it — but if it recurs, check `Extracted_JSON__c` on
   affected rows for a response that looks cut off mid-object.
3. If the error text mentions an invalid or missing API key (HTTP 401), reset the OpenAI API key on the
   `OpenAI_Credential` External Credential's `OpenAI_Principal` NamedPrincipal (Setup → Named
   Credentials → External Credentials).
4. If the error is a timeout or 5xx, this is likely a transient OpenAI-side outage — no action needed;
   affected Leads can be identified later via the `LLM unavailable` outcome label and re-extracted by
   hand if the property address is known.

---

## Manual Reprocessing

There is no built-in "retry" button. To manually reprocess a staging row (e.g. after fixing the OpenAI
API key, or after confirming an Error was transient):

1. Update the staging record: `Status__c = 'Pending'`, clear `Error__c`, and optionally clear
   `Outcome__c` / `Result_Record_Id__c` / `Processed_DateTime__c` if you want a clean slate for
   auditing (not required for reprocessing to work).
2. Manually enqueue the job via the Developer Console → Execute Anonymous:
   ```apex
   System.enqueueJob(new ExtractAddressQueueable(
       '<Inbound_Email_Staging__c Id>', null, null));
   ```
   Pass the staging record's original `Has_Image__c`/`Image_Mime_Type__c` image bytes only if you have
   them separately — the staging object does not persist the base64 image data itself (by design; see
   `docs/broker-protection-architecture.md`), so a manual reprocess of an email that originally carried
   an image will run text-only unless you have the image bytes on hand to pass in.
3. Confirm the job ran via Setup → Apex Jobs, then re-check the staging row's terminal state.

**Caution:** re-enqueueing a staging row whose `Status__c` you did **not** reset to `Pending` is a
no-op — `ExtractAddressQueueable.execute` checks for `STATUS_PROCESSED` at the top and returns
immediately rather than re-routing (this is the idempotency guard, not a bug).
