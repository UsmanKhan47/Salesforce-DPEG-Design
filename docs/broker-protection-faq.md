# Broker Protection — FAQ

**Date:** 2026-07-28
**Author:** Documentation Agent

---

**Q: What happens if a broker emails the same property twice?**

A: This is the **Repeat** branch. No new Lead is created either way, but **which record it lands on
depends on who is repeating**: the property's **winner** re-emailing appends the audit row to their own
Lead; a **competing** broker re-emailing — who since 2026-07-31 has no Lead of their own — appends it to
the **winning Lead** instead (`PropertyClaimService.logRepeatSubmission`). Neither shape is (or ever was)
flagged `Is_Duplicate_Property__c` — that field is now LEGACY and unwritten by any code path (see
`docs/2026-07-31-competing-broker-no-lead.md`). Matching is done first on the LLM-extracted broker
email, then falls back to the envelope `From` address, within a 90-day lookback window.

---

**Q: What if OpenAI is down (or sends back a malformed response)?**

A: Graceful degradation either way. A `CalloutException` from the LLM callout (timeout, 429, 5xx) —
**or, since 2026-07-31, a `JSONException`** from a malformed/truncated response — is caught at the
callout boundary and treated as the absence of an optional input, not a pipeline failure. (The
`JSONException` catch was added deliberately: the enriched JSON contract is ~8× larger than the
original four-key one, so a truncated reply is a realistic event, not just a hypothetical one —
mitigated further by raising `MAX_TOKENS` to 4096 and enabling OpenAI JSON mode, which together make
truncation both rarer and, now, survivable.) The regex fallback still recovers the broker's name/email
from the raw `From:` line, and routing proceeds normally — but because the regex fallback never
recovers a property address, the email always lands in the **No-Property** branch (or the **Reply**
branch, if it's a reply to an existing thread, or gets filtered before any callout at all — see "Why
didn't my email create a Lead?" below). A normal Lead is still created; no claim is attempted. The
staging row records the distinct outcome label `New Lead (no property) — LLM unavailable` — filter on
this label to find Leads worth re-extracting once OpenAI recovers.

---

**Q: Why doesn't my reply appear on the broker's Lead?**

A: The most common cause: the reply never re-entered the monitored inbox / Email Service pipeline.
**This feature's reply threading is not built on Einstein Activity Capture (EAC) or Enhanced Email**
— by design, not because of a licensing gap (Enhanced Email is in fact now enabled in this org as of
2026-07-31; see the note below). It works by matching RFC `In-Reply-To` / `References` headers against a
`Task.Thread_Key__c` / `Task.Inbound_Message_Id__c` logged for the original email — but that match can
only happen for an email that actually flows through `EmailToLeadHandler` again. If you reply to a
broker directly from your own mailbox client without looping the monitored inbox back in (forward or
CC), the reply never reaches this pipeline at all, and nothing was "supposed to" happen — there is no
missing configuration to fix. If the reply *did* re-enter the pipeline, check that its `In-Reply-To`/
`References` headers survived the relay (some mail clients strip them) and that the original email's
Task actually carries a populated `Thread_Key__c`. See `docs/broker-protection-operations.md`
"Reply not threading" for the full checklist.

---

**Q: Can I manually process a failed email?**

A: Yes. Update the staging record: `Status__c = 'Pending'`, clear `Error__c`, then manually enqueue
`ExtractAddressQueueable(stagingId, null, null)` via Execute Anonymous (Developer Console). Full steps,
including the caveat about images not being reprocessable without the original base64 bytes on hand,
are in `docs/broker-protection-operations.md` "Manual Reprocessing."

---

**Q: Does this feature require Einstein Activity Capture (EAC) or Enhanced Email?**

A: No. Every inbound broker email is logged as a standard, completed `Task` — not an `EmailMessage`.
**Correction (2026-07-31):** an earlier version of this answer said Enhanced Activities/EAC licensing
is not present in this org — Enhanced Email **is** now enabled here (via EAC setup). The Task-based
design is unaffected by that: the thread-anchor fields this pipeline depends on
(`Inbound_Message_Id__c`, `Thread_Key__c`) are stamped on Task regardless, and migrating to
`EmailMessage` would be a separate, deliberate change. See `docs/broker-protection-setup.md` §4 for
the full explanation, and the `InboundEmailActivityService` class header for the related `Task.Type`
outage this correction surfaced alongside (Task.Type does not exist in this org and must never be
set — see `docs/2026-07-31-llm-field-extraction.md` for the operational summary).

---

**Q: How does the pipeline stop two brokers from both "winning" the same property if their emails
arrive within moments of each other?**

A: Two layered mechanisms. First, a unique, case-insensitive index on
`Property_Registry__c.Property_Key__c` rejects a second byte-identical claim at the database level.
Second — because two claims can be worded slightly differently (`"123 Main St"` vs `"123 Main
Street"`) and the unique index alone can't catch that — every claim first acquires a pessimistic
`FOR UPDATE` row lock on a coarse address-cluster partition (`Property_Claim_Lock__c`) before deciding a
winner, so a concurrent claim for the same (or fuzzy-similar) property is serialized and correctly sees
the first claim's committed result. See `docs/broker-protection-architecture.md` "Race-Safety Design"
for the full mechanism, including the one documented residual edge case.

---

**Q: A Lead was created but no property was claimed — what happened?**

A: This is the **No-Property** branch — either the email genuinely had no extractable address, or the
LLM callout was unavailable and the regex fallback (which never recovers an address) took over. Check
`Outcome__c` on the staging row: `New Lead (no property)` means a genuinely addressless email;
`New Lead (no property) — LLM unavailable` means the outage case specifically. (Prior to 2026-07-31 you
could also check `Is_Duplicate_Property__c = false` to rule out the Duplicate branch, but that field is
now LEGACY and no branch writes it any more — use `Outcome__c` instead.)

---

**Q: Why didn't my email create a Lead at all? (added 2026-07-31)**

A: This is almost certainly the **relevance gate** (or, less commonly, the deterministic pre-filter
that runs before it). Check `Outcome__c` on the staging row:

- `Not Acquisition (gated)` — the LLM read the email and confidently (`confidence ≥ 0.85`) decided it
  was not acquisition-related — a forwarding confirmation, a newsletter, an out-of-office reply, a
  system notification. `Extracted_JSON__c` holds the model's full classification so you can see why.
- `Not Acquisition (pre-filtered)` — the email never reached the LLM at all: the envelope From or a
  raw header matched an automated-sender/auto-reply pattern (`noreply@`, `mailer-daemon@`,
  `Auto-Submitted: auto-replied`, and similar). This is intentionally narrow — it does **not** filter
  on subject keywords, and it does **not** filter on `Precedence: bulk` (a legitimate broker blast
  platform sets that header on a real listing, so bulk mail is routed to the LLM/gate, not silently
  dropped here).

Both outcomes are visible on the `Gated_Not_Acquisition` list view on `Inbound_Email_Staging__c` — the
only place to audit what the gate has rejected. A **reply** into an existing thread is never gated,
regardless of what it says. If the email genuinely is a deal and got gated, that's a prompt/threshold
tuning question — see `docs/broker-protection-operations.md` "Gated and pre-filtered emails."
Also check whether the email is simply a **low-confidence** case rather than a gated one: those still
create a Lead (`Parse_Confidence__c = LOW`, visible on `Review_Queue`) — the gate only ever suppresses
a confident non-acquisition verdict, never an uncertain one.

---

**Q: Why did one email produce more than one Lead? (added 2026-07-31)**

A: The email pitched **multiple properties**, and since the D1 multi-property enrichment, one Lead is
created **per property**, not per email — the same address de-duplication, race-safe claim engine and
Repeat/Competing/Winner routing runs independently for each one. A three-property blast can therefore
produce one new winning Lead, one competing submission against someone else's Lead (no Lead of its
own), and one Repeat filed on an existing record, all from a single inbound email.

Query `Routed_Record_Ids__c` on the staging row for the complete breakdown — one line per property,
`<normalized address> | <outcome> | <recordId>` — rather than trying to infer it from `Outcome__c`
alone, which for a multi-property email is only a summary (e.g. `Multi-Property (3): 1 New Lead
(winner), 1 Competing Submission, 1 Repeat`). There is a hard cap of **10** properties per email
(`MAX_PROPERTIES`); beyond that, the extra properties are described in the first Lead's
`Deal_Notes__c` and preserved verbatim in `Extracted_JSON__c`, but are not routed or claimed — the
outcome will say ` [truncated: 10 of M]`. See `docs/2026-07-31-llm-field-extraction.md` for the full
multi-property routing tree, including the deadlock-avoidance ordering that makes concurrent
multi-property emails safe.

---

**Q: Where do I see the full submission history for a property?**

A: On the **winning** Lead's record page — the `competingBrokerSubmissions` LWC on `Lead_Record_Page`
lists every `Competing_Broker_Submission__c` tied to that Lead, oldest first, with a Winner/Competing
badge. As of 2026-07-31 a competing broker has no Lead of their own to navigate from — their row appears
only on the winning Lead's timeline, identified by `Broker_Email__c` / `Broker_Name__c` on the
submission itself rather than a `Source_Lead__c`. (Pre-2026-07-31 duplicate-flagged Leads still carry
`Duplicate_Of_Lead__c` pointing at the winner, for historical rows only — that field is now LEGACY.)

---

**Q: What's the difference between `docs/2026-07-24-broker-protection.md` and the docs in this set?**

A: `docs/2026-07-24-broker-protection.md` documents the **original build** (Phases 1/2), where the
pipeline inserted a Lead synchronously at the email boundary and updated it after LLM extraction. The
docs in this set (`docs/broker-protection-*.md`, dated 2026-07-28) document the **current, deployed
staging-model rework** (Phases 3–5): Lead creation is deferred behind a durable
`Inbound_Email_Staging__c` landing record and a five-branch routing tree, which is what makes reply
threading and repeat detection possible. The race-safety design, credentials, and permission-set shape
from the original doc are still accurate and referenced here — only the Lead-creation timing and the
routing logic changed.
