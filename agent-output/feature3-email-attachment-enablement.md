# Feature 3 — Deal-Team Gmail Attachments via "Email to Salesforce"

**Target org:** `usman-dpeg` (`00Diw000000Fqw1EAC`), Google Workspace / Gmail, not Outlook.
**Status:** INVESTIGATION + RUNBOOK ONLY. **Nothing was deployed. Nothing in the org was changed.**
All findings below come from live reads against `usman-dpeg` on 2026-08-05 (Metadata API retrieve,
Tooling API queries, REST queries, and a source-code read of `EmailThreadGuardService.cls`), not
from the repo's `.forceignore`d local settings copy, which this session again proved to be stale
(see §1).

**What "Feature 3" is, precisely — and what it is NOT.** This is the native Salesforce **"Email to
Salesforce"** feature (per-user BCC/forward-to-log, Setup name unchanged since Classic), used as a
workaround because **Einstein Activity Capture (EAC) never syncs attachments, under any setting** —
that limitation is not configurable and is not something this runbook can fix. This is a **different
mechanism** from the Broker Protection inbound-email pipeline (`agent-output/design-requirements-
email-attachments.md`), which is custom Apex (`EmailToLeadHandler` / `InboundEmailAttachmentService`)
that ingests **broker submissions into Leads** via a dedicated Email Service address. Feature 3 is
about the **deal team's own Gmail** (sent and received correspondence) being logged onto whatever
Salesforce record it matches — no custom Apex is involved in the capture itself.

---

## 0. HEADLINE FINDINGS — read this before the runbook

1. **Email to Salesforce is ALREADY ENABLED org-wide.** `EmailAdministrationSettings.
   enableEmailToSalesforce = true` on the live org, confirmed twice independently (Metadata API
   retrieve + Tooling API query). The repo's committed copy of this file
   (`force-app/main/default/settings/EmailAdministration.settings-meta.xml`) says `false` — **it is
   wrong**, because `settings/**` is `.forceignore`d and has never actually deployed; this is the
   third time this exact drift pattern has been measured on this org (see also
   `PathAssistant`/`LeadConfig`, 2026-08-04). **There is nothing to enable at the org level.** §1/§4.1.
2. **The per-user pieces (acceptable addresses, attachment retention, association) are NOT
   automatable by any means found on this org.** Exhaustive search (global REST describe, Tooling
   API describe, `EntityDefinition` query) found zero API surface for them. Each deal-team member
   must configure their own Personal Settings page by hand. §3/§4.2.
3. **🔴 UNRESOLVED, MATERIAL RISK: the EAC Thread Guard may delete a human-logged attachment email
   within seconds, and this org's data does not rule it out.** The guard's only defense against
   deleting a legitimate log is checking whether the companion Task's `CreatedBy.UserType` is
   `'AutomatedProcess'` — and this org's own data proves that background/asynchronous mail capture
   (EAC, observed directly) stamps that exact value, distinct from the `EmailMessage`'s own
   `CreatedBy` (which shows the connected mailbox owner). Email-to-Salesforce is *also* an
   asynchronous, server-side capture mechanism, not a live user DML — whether it shares that same
   fingerprint **could not be determined from this org**, because no one has used the feature yet,
   and it can only be answered by an actual forwarded email, which this task's "change nothing"
   instruction correctly put out of scope. **This is flagged LOUDLY per instructions — see §5.**

---

## 1. CURRENT STATE — established from the org, not inferred

| Setting | Metadata field | Live org value (retrieved 2026-08-05) | Repo copy (stale) |
| --- | --- | --- | --- |
| Email to Salesforce master switch | `EmailAdministrationSettings.enableEmailToSalesforce` | **`true`** | `false` — wrong |
| Enhanced Email | `EmailAdministrationSettings.enableEnhancedEmailEnabled` | `true` (matches user-confirmed screenshot) | `true` — correct |
| Send via Gmail preference | `EmailAdministrationSettings.enableSendViaGmailPref` | `false` | `true` — wrong (unrelated drift, noted for completeness) |
| Gmail Integration | `EmailIntegrationSettings.enableGmailIntegration` | `true` | not in repo (no Metadata API surface retrieved for this type in-repo) |
| Keep Gmail connected | `EmailIntegrationSettings.doesGmailStayConnectedToSalesforce` | `true` | — |
| Contact/Event sync | `EmailIntegrationSettings.enableContactAndEventSync` | `true` | — |
| Salesforce Inbox / productivity features | `EmailIntegrationSettings.enableProductivityFeatures` | `false` | — |
| Outlook Integration | `EmailIntegrationSettings.enableOutlookIntegration` | `false` (Gmail-only org, confirmed) | — |

Retrieval method (repeatable, read-only): `sf project retrieve start --metadata Settings:
EmailAdministration --target-metadata-dir <dir> -o usman-dpeg`, then unzip and read the raw
`.settings` file directly — **do not** trust `sf project retrieve start --source-dir` /
the committed `force-app/main/default/settings/` copy, both because `settings/**` is
`.forceignore`d (never actually deploys) and because a plain source-format retrieve silently drops
settings; only `--target-metadata-dir` (raw MDAPI zip) proves the org's true value. Cross-checked
independently via `sf api request rest '/services/data/v67.0/tooling/query?q=SELECT+FullName,
Metadata+FROM+EmailAdministrationSettings'` — both methods agree.

**Is "Always save email attachments" org-wide configurable, or strictly per-user?** Established as
**strictly per-user**, with high confidence, by three independent negative results against the live
org (not inferred from public docs, which is what the task asked me not to do):

1. `EmailAdministrationSettings` (the org-wide admin object, described via Tooling API) exposes
   **19 boolean fields** — compliance/SPF/DKIM/bounce-handling/HTML/international-address/etc. —
   **none of them govern attachment retention or per-user acceptable addresses.** Full list in
   §4.1's describe dump.
2. `EmailIntegrationSettings` (the Gmail/Outlook integration admin object) likewise has **no**
   attachment-retention or address-allowlist field — it governs sync/connection behavior only.
3. No third settings type exists for this. Both a full **global REST `sobjects` describe** and a
   full **Tooling API `sobjects` describe**, each filtered for every plausible name fragment
   (`Email`, `ToSalesforce`, `Acceptable`, `Attach`, `Preference`, `Gmail`), turned up nothing. A
   direct `EntityDefinition` query for `QualifiedApiName LIKE '%EmailToSalesforce%'` or
   `'%AcceptableAddress%'` returned **zero rows**. The generic `UserPreference` object (which *does*
   store some personal settings as key/value rows) exposes a **restricted picklist of ~26 valid
   `Preference` codes** to a describe call, and none of them are labelled anything resembling
   "Email to Salesforce" or "attachment."

**Conclusion, stated plainly:** "My Email to Salesforce" (Setup → Personal Settings) — the
acceptable-addresses list, the association mode, and the **"Always Save Email Attachments"**
checkbox — has **no Metadata API, Tooling API, or REST API surface on this org.** It cannot be
bulk-provisioned, scripted, or data-loaded. Each of the deal team's users must open their own
Personal Settings page and set it themselves. This matches Salesforce's long-standing, documented
behavior for this specific legacy personal-setting page (distinct from the newer admin-configurable
Email Administration/Integration settings, which *are* API-exposed, as shown above) — but the
authority for this runbook is the org search above, not the public docs.

---

## 2. AUTOMATABLE vs. MANUAL — summary table

| Item | Automatable? | Mechanism | Status on this org |
| --- | --- | --- | --- |
| Org-wide "Email to Salesforce" master switch | ✅ Yes | `EmailAdministrationSettings.enableEmailToSalesforce` (Metadata API `Settings`) | **Already `true` — nothing to deploy.** |
| Enhanced Email | ✅ Yes (same mechanism) | `EmailAdministrationSettings.enableEnhancedEmailEnabled` | Already `true` per user's screenshot; confirmed live. |
| Per-user acceptable email addresses | ❌ No | none found | Each user, manually, once. |
| Per-user "Always Save Email Attachments" | ❌ No | none found | Each user, manually, once. **This is the setting that actually matters for the stated goal.** |
| Per-user Email Association mode | ❌ No | none found | Each user, manually, once — and it is load-bearing (see §4.2, step 3): with the default (no auto-association), a forwarded email logs privately and never reaches the deal record's timeline at all. |

**Since the org-wide prerequisite is already satisfied, there is literally nothing for `salesforce-
devops` to deploy for this feature.** The entire remaining rollout is the per-user runbook below,
plus the risk in §5, which — if confirmed — becomes a `salesforce-developer` follow-up, not an
admin/config task.

---

## 3. WHAT THIS MEANS FOR ADOPTION COST

The user is deciding based on this — stated plainly: **every one of the deal team's users must
personally visit their own Setup → Personal Settings → Email → "My Email to Salesforce" page and
configure three things by hand.** There is no way to do this for them, in bulk, via any API, data
load, or Metadata deploy on this org. This is the single biggest adoption-cost fact in this
investigation, and it was verified rather than assumed (§1).

---

## 4. RUNBOOK

### 4.1 Admin steps, in order

1. **Verify (do not change) the org-wide switch.** Setup → Quick Find → **"Email to Salesforce"**.
   Confirm **Active** is checked. *(Already true on `usman-dpeg` — this step is a read-only
   confirmation, not an action, unless the live UI disagrees with the API read above, in which case
   stop and report the discrepancy before proceeding.)*
2. **Nothing else is required at the org level.** No Metadata deploy, no permission set, no profile
   change — every active human user on this org (`Aftab Ali`, `Danish Rehman`, `Junior Dhanani`,
   `Nikhil Dhanani`, `Usman Khan`) already holds a full **`Salesforce`** user license (confirmed by
   query), which is what "My Email to Salesforce" requires; no additional permission set grants
   access to it.
3. **Before telling the deal team to start using this feature, resolve §5 (the EAC Thread Guard
   risk) first.** Sending users to configure and use this feature before that risk is closed could
   mean their first logged attachment silently vanishes — worse than not having the feature, because
   nothing in the UI tells them it happened.

### 4.2 Per-user steps — paste to the deal team verbatim

> **Setting up "Email to Salesforce" (one-time, ~2 minutes)**
>
> 1. In Salesforce, click the **gear icon** → **Setup** (this opens your Personal Settings, not the
>    admin Setup menu — you don't need any special permission for this).
>    Alternatively: gear icon → **Personal Settings**.
> 2. In the Quick Find box, type **"My Email to Salesforce"** and click it.
> 3. At the top of the page you'll see your own unique forwarding address (something like
>    `yourname.xxxxx@[something].salesforce.com`). **Save this somewhere** — it's what you'll BCC or
>    forward emails to from Gmail.
> 4. **Check the box "Always Save Email Attachments."** *(Confirm this exact wording when the page
>    opens — Salesforce sometimes rewords this between releases. If it isn't there under that exact
>    name, look for the nearest equivalent attachment-retention checkbox on the same page and use
>    that. This checkbox is why the feature captures attachments at all — EAC/Gmail Integration
>    never will, regardless of any other setting.)*
> 5. **Set "Email Association"** to automatically associate emails with matching Salesforce records
>    (rather than "No Autoassociation," which is usually the default). Without this, a forwarded
>    email logs privately under your own Activities and never appears on the Lead/Opportunity at
>    all — the attachment technically exists in Salesforce, but nobody looking at the deal record
>    will ever see it.
> 6. **Add your Gmail address(es) to "My Acceptable Email Addresses."** Only mail *from* an address
>    on this list will be logged when you forward it — this is a spam/abuse guard, not optional.
> 7. Save.
> 8. **To log an email:** either **BCC** your forwarding address when sending, or **forward** a
>    received email to it from Gmail, exactly as you would forward to a colleague.

### 4.3 Verification — end to end

1. Send yourself (or have a broker/colleague send you) a test email with a small attachment (e.g. a
   1-page PDF).
2. Forward it to your "Email to Salesforce" address from Gmail.
3. Wait 1–2 minutes.
4. In Salesforce, open the Lead/Opportunity/Contact the email should have matched (per your
   Association setting) and check the **Activity/timeline**: you should see the logged email.
5. Open that email entry and confirm the **attachment is present and downloadable**.
6. **Do not skip this check: re-open the same record ~5 minutes later and confirm the email and its
   attachment are STILL there.** Per §5, this org has a background cleanup process
   (`EmailThreadGuardService`) that can delete an unanchored capture within seconds of it landing —
   if the entry from step 4 has vanished by the time you re-check, **stop using the feature and
   report it immediately** rather than assuming it was a one-off glitch.

---

## 5. 🔴 THE EAC THREAD GUARD RISK — the most important section of this document

### What the guard is, briefly

`force-app/main/default/classes/EmailThreadGuardService.cls` runs on **every** `EmailMessage`
insert, org-wide, no exceptions — `EmailMessageTrigger` fires unconditionally on `after insert` and
routes 100% of inserts through `EmailCaptureQueueable` → the adopter, then this guard. There is no
filter anywhere in the trigger/handler that distinguishes an EAC-materialized capture from an
Email-to-Salesforce-materialized one, a Lightning Email Composer send, or anything else — **that
distinction is made entirely inside the guard's own admissibility check.**

Five scope guards gate every delete (full detail in the class header, read directly for this
investigation):

1. related to at least one **Lead**,
2. related to **no record outside `{Lead, User}`**,
3. its companion Task was created by the **`'AutomatedProcess'`** user — the EAC fingerprint,
4. anchored **nowhere** it lives (no matching Broker Protection `Thread_Key__c`/
   `Inbound_Message_Id__c`), **or**
5. an exact duplicate of a pipeline Task **everywhere** it lives.

Guards 1–3 are admissibility (all three must hold before the guard will even consider deleting);
guards 4/5 are the two reasons to actually delete.

### Can a human-logged email be deleted? — The precise, honest answer

**Guard 3 is the ONLY thing in this code that would stop the guard from touching a human-logged
Email-to-Salesforce capture, and this org's own data proves the mechanism guard 3 checks for is
real — but not specifically for Email-to-Salesforce.**

I found and inspected the **only** `EmailMessage` currently in this org (`02siw0000006UMoAAM`,
subject "Gordon Center - Jacksonville FL", a genuine EAC capture of an inbound broker email). It
proves the exact discriminator the guard relies on:

| Record | `CreatedById` | `CreatedBy.UserType` |
| --- | --- | --- |
| The `EmailMessage` itself | Junior Dhanani (the connected mailbox owner) | `Standard` |
| Its companion **Task** (`00Tiw000000HSr8EAG`) | Automated Process | **`AutomatedProcess`** |

This confirms: (a) the `EmailMessage`'s own `CreatedBy` is **not** a reliable EAC fingerprint — it
shows the real mailbox owner, not a system identity; (b) the guard is right to check the **companion
Task's** `CreatedBy` instead, which genuinely does show `AutomatedProcess` for this org's real EAC
traffic; (c) this is a background, asynchronous, server-side capture — the same category of
operation as Email-to-Salesforce.

**What I could NOT determine, because no one has used Email-to-Salesforce on this org yet:**
whether a Task auto-created by Email-to-Salesforce's own server-side mail processing *also* shows
`CreatedBy.UserType = 'AutomatedProcess'`, or whether it is instead attributed to the real human
user (the way manual Composer/Agentforce sends are, per the class header's gotcha 5, which the guard
was explicitly designed to leave alone). **This genuinely cannot be answered from Salesforce
documentation, from reading the Apex, or from any query against this org — the only record that
could answer it does not exist yet, and creating one artificially (e.g. via anonymous Apex) would
not answer the question either**, because an Apex-inserted `EmailMessage` is attributed to whoever
ran the script, not to Email-to-Salesforce's actual backend identity. **A real forwarded email is
the only way to find out**, which is exactly why this was not done under this task's "change
nothing" instruction, and must instead be the very first live UAT step before rollout.

### Why this matters, worked through against the guard's actual logic

If a Task auto-created by Email-to-Salesforce **does** carry `CreatedBy.UserType = 'AutomatedProcess'`
(structurally plausible — not confirmed), here is exactly what happens to a deal-team member's
forwarded attachment email, guard by guard:

- **Guard 3 (admissibility) → PASSES** (same fingerprint as EAC).
- **Guard 1 (must relate to a Lead) → PASSES for any deal still at Lead stage** — i.e. exactly the
  early-stage OMs and broker correspondence this feature exists to capture attachments for, before
  conversion to Opportunity. (Post-conversion Opportunity-only correspondence would **fail** guard 1
  and be untouched — see the boundary note below.)
- **Guard 2 (must not also live on a Contact/Account/Opportunity) → PASSES** for a still-unconverted
  Lead, since there is no Contact yet for the guard to see.
- **Guard 4 (anchored anywhere?) → FAILS to protect it.** A deal-team member's own forwarded email
  has its own Message-ID / Thread-Identifier — it is not a reply inside a thread the Broker
  Protection pipeline already logged, so it will not match any `Thread_Key__c` /
  `Inbound_Message_Id__c` anchor on that Lead.
- **Result: the guard deletes it — the `EmailMessage`, its companion Task, and everything they
  carried, including the attachment — within roughly the same window as the guard's normal
  self-healing re-delete cycle (seconds to low minutes), silently, with no notification to the user
  who just logged it.**

**The one meaningful boundary that limits (but does not eliminate) the exposure:** guard 1 only
fires for captures related to a **Lead**. Per `ARCHITECTURE.md`'s own EAC Thread Adopter writeup,
"majority of the discussion will happen in opportunity" — post-conversion correspondence relates to
a Contact/Opportunity, not a Lead, and would sail through untouched (this is the documented "guard 2
declines, duplicate survives" boundary already known for EAC). **The exposure is concentrated on
early-stage, pre-conversion Lead correspondence** — which is not a small population; it is exactly
where a broker first sends the OM this feature is meant to capture.

### What to do about it — recommended, not built (out of my remit)

1. **Run exactly one live test before telling anyone else to adopt the feature.** Have one user
   (e.g. Junior Dhanani) configure their own Email-to-Salesforce settings per §4.2, then forward one
   real email with an attachment to themselves against a **still-open Lead** (ideally a low-cost or
   disposable one — a real UAT record, not a fabricated one, since the whole point is to observe the
   platform's genuine attribution behavior). Query the resulting Task's `CreatedBy.UserType`
   immediately, then again after 5 minutes to see if it, and the email, survived.
2. **If it survives:** the risk is closed — Email-to-Salesforce and EAC are attributed differently on
   this org, guard 3 correctly excludes it, and the runbook in §4 can be rolled out as-is.
3. **If it is deleted:** this is a real defect that must be fixed **before** broader rollout, not
   after — per this task's own instructions. The fix is a code change to
   `EmailThreadGuardService`'s admissibility logic (a `salesforce-developer` task, following a
   `salesforce-design` pass first, per this repo's standard workflow) — **not something to build in
   this admin investigation.** One plausible direction worth flagging for that design conversation:
   the guard's own header states its purpose is narrowly "EAC's address-based over-association,"
   and Email-to-Salesforce logging is a *deliberate* human act, not an *inferred* one — so a second
   discriminator beyond `CreatedBy.UserType` (which this evidence suggests both mechanisms may
   share) would be needed, and should be identified from a real Email-to-Salesforce companion Task's
   full field set once one exists to inspect.
4. **Do not roll this out to the whole deal team before step 1 is run and passes.** A silently
   deleted attachment is worse than the status quo, because nothing in the Salesforce UI would tell
   the user it happened — they would simply, eventually, notice the file is "missing" and have no
   way to know why, exactly the failure mode the design doc for the *other* attachments feature
   independently flagged as the worst possible outcome for lost broker files.

---

## 6. Confidence summary

| Finding | Confidence | Basis |
| --- | --- | --- |
| Org-wide Email to Salesforce is already ON | **High** | Two independent live API reads, agreeing |
| Attachment retention / acceptable addresses are per-user-only, no API | **High** | Exhaustive negative search across REST, Tooling, EntityDefinition |
| EAC materializes captures under `AutomatedProcess` on this org | **High** | Direct, real record inspection |
| Whether Email-to-Salesforce shares that same fingerprint | **Unresolved — genuinely unverifiable without a live test** | No such record exists yet on this org; stated as such, not guessed |
| Guard 1 (Lead-only scope) limits but does not eliminate the exposure | **High** | Direct code read of `EmailThreadGuardService.cls` |

No claim in this document is inferred from public Salesforce documentation alone where an org-level
check was possible — every claim in §1–§3 was verified against `usman-dpeg` directly, and §5 states
plainly where verification was not possible and why.
