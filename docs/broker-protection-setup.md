# Broker Protection — Setup Guide

**Date:** 2026-07-28
**Author:** Documentation Agent
**Audience:** Salesforce Admins provisioning or re-provisioning this feature in an org.

None of the four steps below travel with the metadata deploy — they are per-org configuration that
must be completed **after** the metadata bundle deploys, or the pipeline will not process real email.

---

## 1. Email Service Configuration

The pipeline's entry point is a Salesforce **Email Service** routed to `EmailToLeadHandler`
(`Messaging.InboundEmailHandler`). This is org configuration, not portable metadata.

1. **Setup → Email Services → New Email Service.**
2. Target Apex class: `EmailToLeadHandler`.
3. Configure "Failure Response Settings" per your monitoring preference (the handler itself always
   returns a result — failures inside `handleInboundEmail` are caught and reported on the result
   object rather than throwing, so bounces should be rare, but keep a failure notification address
   configured as a backstop).
4. Under the Email Service, **New Email Address** — this generates the actual inbound routing address
   (e.g. `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx@xxxxxx.in.salesforce.com` for a default domain, or a custom
   verified domain address if your org has one configured).
5. **Configure the monitored inbox's auto-forward rule** (e.g. a Gmail filter) to forward broker
   emails to this address. See the *Auto-forward vs. manual forward* note below — both work, but they
   arrive differently and the pipeline is written to distinguish them correctly, so no special
   configuration is needed on the Gmail side beyond a plain forward rule.
6. **Verify with a test email.** Send a test email (with a fake broker "From:", a property address in
   the body, ideally forwarded the way real broker emails will arrive) to the generated address, then
   confirm an `Inbound_Email_Staging__c` row appears with `Status__c = 'Processed'` and a Lead was
   created (check `Outcome__c` and `Result_Record_Id__c` on the staging row).

### Auto-forward vs. manual forward

Both arrive as ordinary inbound email but mean opposite things about the `From` address:

- **Auto-forward** (a mailbox rule on a monitored inbox) preserves the **broker** as `From` and records
  the forwarding inbox in `X-Forwarded-For` / `Delivered-To` headers.
- **Manual forward** (a person hitting "Fwd") puts the **internal forwarder** in `From`, and the broker
  survives only inside the quoted body — where the LLM extraction finds it later.

`EmailToLeadHandler.resolveMonitoredInbox` reads the forwarding headers first and falls back to `From`,
so `Forwarded_By_Email__c` always means "the monitored inbox this reached us through," in either shape.
No admin configuration differentiates the two paths — the code handles both automatically.

---

## 2. Permission Sets

Assign **`Broker_Protection_Access`** to:

- **The Email Service's configured context user (the "Automated Process" / running user for inbound
  email).** ⚠️ **This is a verified deploy gate, not a nicety.** All backend reads run
  `WITH USER_MODE` under this user. If the permission set is not assigned, those reads throw, and the
  pipeline's catch-all swallows the exception — the entire ledger silently no-ops (staging rows and,
  depending on where the failure lands, possibly Leads too, are still written up to that point, but
  nothing downstream succeeds) with **no visible error to an admin who only checks as themselves**.
  **Acceptance-test as a non-admin persona** — an admin tester will not see this failure mode because
  `System Administrator` bypasses FLS.
- **Junior, Nikhil, and any other Acquisition-team member** who needs to view the staging audit trail
  or the competing-submission history on Lead record pages.

The permission set grants: object CRUD + `viewAllRecords` on `Property_Registry__c`,
`Competing_Broker_Submission__c`, `Property_Claim_Lock__c`; object CRUD (no `viewAllRecords` — private
sharing) on `Inbound_Email_Staging__c` and `Task`; FLS (read/edit) on every custom field this pipeline
writes, including the 4 Lead fields and the 2 Task/Activity threading fields; and external-credential
principal access for `OpenAI_Credential`.

---

## 3. External Credentials (OpenAI)

Verify the two credential records exist post-deploy (they deploy as metadata, but the secret itself
does not):

1. **Setup → Named Credentials → External Credentials → `OpenAI_Credential`.**
2. Under its **Principals**, find `OpenAI_Principal` (a `NamedPrincipal`) and enter the live OpenAI API
   key as its authentication parameter value. **The key is never stored in metadata or source
   control** — this is the only place it lives.
3. Verify **Setup → Named Credentials → `OpenAI_API`** points at `https://api.openai.com`, has
   **`Allow Merge Fields in HTTP Header` = true** (required — without it, the
   `{!$Credential.OpenAI_Credential.API_Key}` merge field in the Authorization header is sent
   literally and OpenAI returns 401), and references `OpenAI_Credential` as its authentication source.
4. Send a test email (per step 1.6) and confirm the staging row's `Outcome__c` is **not**
   `New Lead (no property) — LLM unavailable` — that outcome label specifically means the OpenAI
   callout failed (commonly an unset or invalid API key).

---

## 4. Einstein Activity Capture (EAC) — Not Required, Not Currently Used

**This feature does not depend on EAC, and there is nothing to configure here for Broker Protection to
function.** This section exists to prevent a reasonable but incorrect assumption: reply threading in
this pipeline is built entirely on RFC email headers stored on standard `Task` records
(`Thread_Key__c` / `Inbound_Message_Id__c`), **not** on EAC or Enhanced Email (`EmailMessage`) —
`InboundEmailActivityService`'s class header states plainly that Enhanced Activities licensing is not
present in this org, and a completed `Task` was chosen specifically because it needs no such license.

**Practical implication for reps:** if Junior (or anyone) replies to a broker directly from their own
mailbox client, and that reply does **not** get forwarded/CC'd back into the monitored inbox / Email
Service address, this pipeline never sees it — there is no thread match, because no email ever reached
`EmailToLeadHandler`. To have a reply recognized and threaded, the reply (or a forward of it) must
travel back through the same monitored inbox that is auto-forwarding into the Email Service.

This org does have an `EAC.settings-meta.xml` present under `force-app/main/default/settings/` (visible
in the repo file tree), but `force-app/main/default/settings/**` is excluded from every deploy via
`.forceignore`, and this settings file predates and is unrelated to the Broker Protection build — it is
not part of this feature's metadata bundle and this documentation does not depend on it being enabled
or configured. If your org later licenses and enables EAC/Enhanced Email for an unrelated purpose (e.g.
general email tracking on Contacts), be aware it operates independently of — and will not automatically
populate — `Thread_Key__c` / `Inbound_Message_Id__c`; a future enhancement could bridge the two, but
none exists today. See `docs/broker-protection-limitations.md`.

---

## Broker Email / Salesforce User Address Collision — General Caution

Even though this pipeline does not use EAC, it is still good practice **not to register a broker's
email address on any Salesforce User record**. Standard Salesforce email-routing and matching features
(list-email matching, Case/Lead auto-response rules, and any future Enhanced Email/EAC configuration)
generally prefer matching an inbound address to an internal User over a Lead/Contact when both exist,
which can misroute correspondence. If an address collision is discovered, remove or change the
conflicting address on the User record.
