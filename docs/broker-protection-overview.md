# Broker Protection: Race-Safe First-Broker-Wins Email-to-Lead Pipeline

**Date:** 2026-07-28
**Author:** Documentation Agent
**Status:** Deployed to org (Phases 1–5 complete — staging model, race-safe claim engine, reply threading)

---

## 📋 Overview

### Original Request

> Multiple brokers independently email the same property to different internal DPEG people, who
> forward those emails into a Salesforce Email Service. Build a race-safe "broker protection" layer
> over the inbound email→Lead pipeline: the first broker to submit a property wins; later submissions
> for the same property are marked duplicate and logged for tracking only — never overwriting the
> winning Lead's data. The full submission history must be visible on the winning Lead's record page.
> The pipeline uses an LLM (OpenAI, text or image/vision) to extract the broker's name/email, the
> property address, and the original send time from the forwarded email, with a regex fallback.
> Race-safety must hold even when two emails for the same property arrive within moments of each
> other. A later iteration (Phases 3–5) added a durable staging record for every inbound email, RFC
> reply threading so a follow-up email is filed on the existing conversation instead of creating a
> new Lead, and repeat-submission detection so a broker chasing their own earlier submission does not
> get flagged as competing with themselves.

### Business Objective

DPEG's deal flow starts when brokers email properties to whichever internal contact they know. The
same property routinely gets forwarded into the pipeline by more than one broker — sometimes the same
broker following up, sometimes a competitor — and because the forwards land at different times from
different internal people, nothing previously stopped each one from becoming its own, uncoordinated
Lead. Broker Protection turns that into a deterministic model: exactly one Lead per property carries
the live opportunity, every later submission is preserved as an auditable record (who else submitted
it, when, via whom), reply/follow-up emails are recognized and filed on the correct existing record
instead of spawning noise, and reviewers get a single place — a component on the winning Lead — to
see the whole submission history.

### Summary

An inbound Salesforce Email Service routes every forwarded broker email to `EmailToLeadHandler`, which
parses the envelope, RFC headers (`Message-ID`, `In-Reply-To`, `References`) and any inline image, and
writes a durable `Inbound_Email_Staging__c` row **before anything else happens** — this is the record
that "cannot be lost," not a Lead. An async `ExtractAddressQueueable` job then calls OpenAI
(vision-capable, text or image) to extract the broker's name/email, the property address and the
original send time, with a regex fallback on the raw `From:` line, and runs a five-branch **routing
tree** that decides what the email actually is: a **reply** to a thread already logged, a **repeat**
submission from a broker who already claimed this property, an email with **no usable address**, a
**duplicate** claim on a property someone else already won, or a new **winner**. A Lead is created only
by the three branches that need one (no-property / duplicate / winner) — replies and repeats file
their email onto the existing record instead. Concurrent same-property claims are serialized behind a
pessimistic row lock (`Property_Claim_Lock__c`) so two near-simultaneous submissions cannot both win,
backstopped by a unique index on the claim ledger (`Property_Registry__c.Property_Key__c`). Every
submission — winning or not — is logged to an append-only audit object,
`Competing_Broker_Submission__c`, rendered as a timeline on the winning Lead's record page by the
`competingBrokerSubmissions` LWC. Every inbound email is also logged as a completed `Task` carrying two
RFC threading keys, which is what makes the reply/repeat detection on the *next* email possible.

### Key Outcomes

| Outcome | How it's achieved |
|---|---|
| **First broker to submit a property wins** | `PropertyClaimService.claim` under a `FOR UPDATE` cluster lock + the unique `Property_Registry__c.Property_Key__c` index. |
| **Later brokers for the same property get a flagged duplicate Lead + audit trail** | `Lead.Is_Duplicate_Property__c` / `Duplicate_Of_Lead__c` are stamped, and a non-winning `Competing_Broker_Submission__c` row is logged against the winner — the winning Lead itself is never written to. |
| **Same broker re-submitting doesn't create a second Lead or a false duplicate flag** | `PropertyMatchingService.findBrokerSubmission` recognizes the repeat and `PropertyClaimService.logRepeatSubmission` appends an audit-only row to their *existing* Lead — no new Lead, no `Is_Duplicate_Property__c` flag. |
| **A reply/follow-up in an existing email thread is filed on the correct record, not a new Lead** | RFC `In-Reply-To` / `References` headers are matched against `Task.Thread_Key__c` / `Task.Inbound_Message_Id__c`; a hit resolves to the record (following a converted Lead through to its live Opportunity) and no Lead is created. **This works only for email that re-enters the same Salesforce Email Service address** — see the note on EAC below. |
| **Redelivered emails are never double-processed** | The staging row's terminal `Status__c` and the Message-ID-on-Task idempotency check both guard against re-running the routing tree for a message already handled. |

### A note on reply threading and Einstein Activity Capture (EAC)

This pipeline's reply threading is **not** built on Einstein Activity Capture (EAC) or Enhanced Email
(`EmailMessage`) — neither is licensed in this org (confirmed in `InboundEmailActivityService`'s class
header). Every inbound broker email is logged as a standard, completed **`Task`** carrying two custom
External-Id text fields (`Inbound_Message_Id__c`, `Thread_Key__c`), and a reply is recognized only when
it **re-enters the same monitored inbox / Email Service address** and is matched against those Task
fields via RFC headers. If a rep replies directly to a broker from their own mailbox without looping
the monitored inbox back in, this pipeline never sees that reply — that is a separate question from
whether EAC (if licensed in the future) would independently log the reply as an Activity, which it does
not currently and would not automatically integrate with `Thread_Key__c` matching even if enabled. See
`docs/broker-protection-setup.md` for the full implication of this.

### User Personas

- **Acquisition team (Junior, Nikhil)** — the primary consumers. They forward broker emails into the
  monitored inbox / Email Service address and review the resulting Leads and the competing-submission
  history on the winning Lead's record page.
- **Admins** — provision the Email Service + routing address, assign `Broker_Protection_Access`, set the
  OpenAI API key, and monitor `Inbound_Email_Staging__c` for errors.

### Related Documentation

- `docs/broker-protection-architecture.md` — data model, routing tree, race-safety design.
- `docs/broker-protection-setup.md` — required post-deploy manual steps.
- `docs/broker-protection-operations.md` — monitoring and troubleshooting runbook.
- `docs/broker-protection-testing.md` — test coverage and how to run it.
- `docs/broker-protection-limitations.md` — known limitations and roadmap.
- `docs/broker-protection-data-dictionary.md` — full field reference.
- `docs/broker-protection-faq.md` — frequently asked questions.
- `docs/broker-protection-changelog.md` — phase-by-phase build history.
- `docs/2026-07-24-broker-protection.md` — the original Phase 1/2 feature doc (pre-staging model; superseded in behavior by the 2026-07-28 staging rework described here, but still accurate on the race-safety design, credentials, and permission-set shape).
- `ARCHITECTURE.md` §1 (Lead Intake / Broker Protection), §2 (Key Apex Services), §3.3 (OpenAI direct-callout exception).
