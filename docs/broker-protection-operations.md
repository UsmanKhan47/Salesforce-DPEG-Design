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
  - `Competing Duplicate` — branch (d).
  - `Repeat` — branch (b), no new Lead.
  - `Reply Thread` — branch (a), no new Lead.
  - `New Lead (no property)` — branch (c), address genuinely not found.
  - **`New Lead (no property) — LLM unavailable`** — branch (c) reached because the OpenAI callout
    failed (429/5xx/timeout), **not** because the email had no address. These are the Leads worth
    re-extracting once OpenAI recovers — filter on this label specifically to find them.
  - `Duplicate Delivery (skipped)` — the platform redelivered an already-processed Message-ID; nothing
    was reprocessed, by design.
- **A cluster of `New Lead (no property) — LLM unavailable` outcomes in a short window** is the
  signal that OpenAI is down or the API key is invalid/expired — check `Error__c` on a representative
  row for the HTTP status if present, and see "LLM extraction failed" below.

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

### Duplicate Lead created — is it a Repeat or a Competing Duplicate?

Check `Lead.Is_Duplicate_Property__c` on the new Lead:

- **`true`** → this is a genuine **Competing Duplicate** (branch (d)) — a different broker already
  claimed this property. Check `Duplicate_Of_Lead__c` for the winner. This is correct, expected
  behavior, not a bug to fix.
- **`false`**, but no new Lead appears and instead a `Competing_Broker_Submission__c` audit row was
  appended to an *existing* Lead → this was a **Repeat** (branch (b)) — the same broker submitting the
  same property again. Also correct, expected behavior.

If a Lead was created that you believe should have been a Repeat or a Reply, check whether the broker's
email address differs subtly between submissions (the repeat check matches on the LLM-extracted broker
email, then falls back to the envelope `From`) or whether the address wording differs enough to fall
below the 0.6 Jaccard similarity threshold — see `docs/broker-protection-limitations.md` for the
documented fuzzy-matching residual.

### LLM extraction failed

1. Check the staging row's `Error__c` (if `Status__c = 'Error'`) or the `Outcome__c` label
   `New Lead (no property) — LLM unavailable` on a `Processed` row.
2. A `CalloutException` degrades gracefully (see `docs/broker-protection-architecture.md` — Degraded
   Extraction) — the Lead is still created via the regex fallback, just without a property claim.
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
