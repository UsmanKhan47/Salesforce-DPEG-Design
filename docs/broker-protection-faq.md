# Broker Protection — FAQ

**Date:** 2026-07-28
**Author:** Documentation Agent

---

**Q: What happens if a broker emails the same property twice?**

A: This is the **Repeat** branch. No new Lead is created. A `Competing_Broker_Submission__c` audit row
is appended to their **existing** Lead (`PropertyClaimService.logRepeatSubmission`), and — importantly —
the Lead is **not** flagged `Is_Duplicate_Property__c`, because a broker chasing their own earlier
submission is not a competing broker. Matching is done first on the LLM-extracted broker email, then
falls back to the envelope `From` address, within a 90-day lookback window.

---

**Q: What if OpenAI is down?**

A: Graceful degradation. A `CalloutException` from the LLM callout (timeout, 429, 5xx) is caught at the
callout boundary and treated as the absence of an optional input, not a pipeline failure. The regex
fallback still recovers the broker's name/email from the raw `From:` line, and routing proceeds
normally — but because the regex fallback never recovers a property address, the email always lands in
the **No-Property** branch (or the **Reply** branch, if it's a reply to an existing thread). A normal
Lead is still created; no claim is attempted. The staging row records the distinct outcome label
`New Lead (no property) — LLM unavailable` — filter on this label to find Leads worth re-extracting
once OpenAI recovers.

---

**Q: Why doesn't my reply appear on the broker's Lead?**

A: The most common cause: the reply never re-entered the monitored inbox / Email Service pipeline.
**This feature's reply threading is not built on Einstein Activity Capture (EAC) or Enhanced Email** —
it is not licensed in this org. It works by matching RFC `In-Reply-To` / `References` headers against a
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

A: No. Every inbound broker email is logged as a standard, completed `Task` — not an `EmailMessage` —
specifically because Enhanced Activities/EAC licensing is not present in this org. An
`EAC.settings-meta.xml` file does exist in the repo's `force-app/main/default/settings/` folder, but
`settings/**` is excluded from every deploy (`.forceignore`) and that file predates and is unrelated to
this feature. See `docs/broker-protection-setup.md` §4 for the full explanation.

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

**Q: A Lead was created but no property was claimed and `Is_Duplicate_Property__c` is `false` — what
happened?**

A: This is the **No-Property** branch — either the email genuinely had no extractable address, or the
LLM callout was unavailable and the regex fallback (which never recovers an address) took over. Check
`Outcome__c` on the staging row: `New Lead (no property)` means a genuinely addressless email;
`New Lead (no property) — LLM unavailable` means the outage case specifically.

---

**Q: Where do I see the full submission history for a property?**

A: On the **winning** Lead's record page — the `competingBrokerSubmissions` LWC on `Lead_Record_Page`
lists every `Competing_Broker_Submission__c` tied to that Lead, oldest first, with a Winner/Competing
badge. A duplicate (losing) Lead does not carry this component's data itself; navigate to its
`Duplicate_Of_Lead__c` to see the winner and the full history there.

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
