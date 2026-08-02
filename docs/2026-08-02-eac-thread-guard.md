# Broker Protection — Change 2: EAC Thread Guard

**Date:** 2026-08-02
**Author:** Documentation Agent
**Status:** Deployed to `usman-dpeg`. Code-reviewed — Gate 2 returned APPROVED WITH WARNINGS, the one
warning (W1) was fixed same-day, and the re-verify diff pass returned APPROVED. See "Review History"
below for the full story.
**Companion docs:** `docs/2026-07-24-broker-protection.md` (the pipeline this guard protects),
`docs/2026-07-31-competing-broker-no-lead.md` (Change 1, the sibling change from the same change-prompt
document), `ARCHITECTURE.md` §2 ("EAC Thread Guard" subsection + the `EmailThreadGuardService` row in
Key Apex Services — both already current, not touched by this pass).

---

## 📋 Overview

### Original Request

> Hand this document to an AI coding agent in a repo that already contains the Broker Protection module
> and uses Einstein Activity Capture to capture the agent's outbound replies. EAC associates captured
> emails by address matching only — it is completely thread-blind, and attaches every email to every
> record whose address appears on it. When the agent sends a broker a brand-new, unrelated email, EAC
> staples it onto that broker's deal Lead, polluting the timeline. No EAC configuration can prevent
> this. Build a guard that runs *after* capture: let EAC materialize the email, then automatically
> delete it from the Lead when it does not belong to any thread the pipeline anchored there. Replies in
> a deal thread stay; new unrelated conversations vanish within seconds.
> *(Source: `agent-output/change-prompts-broker-protection-2026-07-31.md`, Change Prompt 2. As with
> Change 1, the prompt's own trigger/queueable code was re-expressed against this repo's Service /
> Selector / Trigger-handler layering rather than pasted verbatim — see "A note on the source prompt"
> below.)*

### Business Objective

Einstein Activity Capture was turned on so agent replies to brokers show up automatically on the
relevant Lead. But EAC has no concept of "relevant" — it matches purely on email address, so it staples
**every** email involving that address onto **every** record carrying it, including a brand-new,
unrelated conversation that has nothing to do with the deal. Left unguarded, every Lead's activity
timeline would slowly fill with off-topic correspondence, making the deal thread itself harder to find
and eroding trust in the timeline as a record of the deal's actual history. This guard restores
selectivity after the fact: it lets EAC do its address matching, then removes anything that isn't
actually part of a thread the pipeline recognizes.

### Summary

`EmailMessageTrigger` (new, standard-object `EmailMessage after insert`) enqueues
`EmailThreadGuardQueueable`, which hands the captured message Ids to `EmailThreadGuardService.run()`.
The service applies four scope guards — Lead-related, lives-nowhere-else, EAC-materialized, unanchored
— and deletes only captures that fail all four, taking their companion Task with them. Two new
selectors (`EmailMessageSelector`, `EmailMessageRelationSelector`) and two new `SYSTEM_MODE` methods on
`TaskSelector` back the reads. The guard is self-healing (a re-synced deletion is re-examined and
re-deleted) and is scoped to Leads only, by design.

### A note on the source prompt

The change prompt specified a single trigger (`triggers/EmailMessageThreadGuard.trigger`) that itself
built the SOQL and DML inline, plus one queueable class doing everything. This repo's Apex layering
(ARCHITECTURE.md §2 / `.claude/rules/apex-layering-rule.md`) does not allow a trigger to contain logic
or a queueable to contain SOQL/DML, so the shipped shape is: a one-line `EmailMessageTrigger` →
`EmailMessageTriggerHandler` (routes + enqueue-limit guard, extends the repo's `TriggerHandler` base) →
`EmailThreadGuardQueueable` (thin async wrapper, no SOQL/DML) → `EmailThreadGuardService` (the decision
and the only DML) → `EmailMessageSelector` / `EmailMessageRelationSelector` / `TaskSelector` (all SOQL).
The prompt's own trigger was also named for the *feature* (`EmailMessageThreadGuard`); the shipped
trigger is named for the *object* (`EmailMessageTrigger`), matching this org's one-trigger-per-object
rule — a second `EmailMessage` concern in the future belongs in the same handler, not a second trigger.
The prompt's meta XML specified `apiVersion 63.0`; all three deployed components are `67.0`, matching
the rest of the repo (ARCHITECTURE.md's uniform-67.0 note). The *behavior* is unchanged; only the code
shape differs.

---

## 🧩 The Problem

Einstein Activity Capture materializes a captured email as an `EmailMessage`, a companion `Task` (auto-
created by the platform, which is what renders it on a record's Activity Timeline), and one
`EmailMessageRelation` row per record it matched — Lead, Contact, User, whatever address-matched. That
matching is **address-based only**. There is no per-thread setting, no relevance filter, no way to tell
EAC "only attach this if it's a reply in an existing conversation" — it is all-or-nothing per address.

Concretely: an agent working a deal sends a broker a completely unrelated, brand-new email from the
connected mailbox (a different property, a scheduling question, anything). EAC captures it, sees the
broker's address, and staples it onto **every** record carrying that address — including the broker's
deal Lead, where it now sits indistinguishable from the real negotiation thread. **No EAC configuration
can prevent this**, so the fix has to run after capture rather than try to configure it away: let EAC do
its address matching, then delete the email from Salesforce entirely if it turns out not to belong to
any thread the Broker Protection pipeline actually anchored on that Lead.

The pipeline already gives the guard something reliable to check against. Every inbound broker email is
logged as a Task on the Lead by `InboundEmailActivityService`, stamped with `Thread_Key__c` (the
conversation root's RFC Message-ID) and `Inbound_Message_Id__c` (that specific message's own Message-
ID) — see `docs/2026-07-24-broker-protection.md`. Those two fields are the **thread anchors**. EAC's own
`EmailMessage.ThreadIdentifier` (the thread root's Message-ID) and `.MessageIdentifier` (the message's
own) carry the same values for a genuine reply, so matching either against a Lead's anchors is exactly
the "does this belong to a thread we recognize?" check the feature needs.

---

## 🔀 Architecture — Why the Work Is Async

```
EAC captures an email
        │
        ▼
 EmailMessage inserted  ──────────────────────────────────────────┐
        │                                                          │
        ▼                                                          │
 EmailMessageTrigger (after insert, one line)                      │
        │                                                          │
        ▼                                                          │
 EmailMessageTriggerHandler.afterInsert()                          │
   • queueable-slot check (see "Queueable Cap" below)               │
        │                                                          │
        ▼                                                          │
 System.enqueueJob(EmailThreadGuardQueueable)                      │
        │                                                          │
        │             EmailMessageRelation rows inserted ◄─────────┘
        │             (AFTER the EmailMessage, same transaction)
        ▼
  ── transaction commits ──
        │
        ▼
 EmailThreadGuardQueueable.execute() (post-commit)
        │
        ▼
 EmailThreadGuardService.run(messageIds)
   1. EmailMessageSelector.selectByIds            (SYSTEM_MODE)
   2. EmailMessageRelationSelector.selectByMessageIds (SYSTEM_MODE)
   3. TaskSelector.selectByIds                    (SYSTEM_MODE, EAC fingerprint)
   4. TaskSelector.selectThreadAnchorsByWhoIds     (SYSTEM_MODE, pipeline anchors)
   5. apply the four scope guards, per message
        │
        ▼
 Database.delete(doomedTasks, false); Database.delete(doomedMessages, false)
```

The queueable hop is not a performance choice — it is load-bearing. EAC inserts the
`EmailMessageRelation` rows (which record *which* Leads a capture landed on) **after** the `EmailMessage`
itself, within the same transaction. A synchronous `after insert` check on `EmailMessage` would query
those relations and legitimately find none yet, concluding "not Lead-related" for every single capture —
making the guard a permanent no-op. Only post-commit execution sees the true association. This is
gotcha 4 in both the change prompt and the shipped class headers, and it is called out explicitly in
three places (`EmailMessageTriggerHandler`, `EmailThreadGuardQueueable`, `EmailMessageRelationSelector`)
so nobody "optimizes" the hop away in a future diff.

---

## 🛡️ The Four Scope Guards

`EmailThreadGuardService.run()` deletes a captured email **only when all four** of the following hold —
anything ambiguous falls through to "keep," never to "maybe delete":

| # | Guard | What it checks | Fails closed by... |
|---|---|---|---|
| 1 | **Lead-related** | The `EmailMessage` has at least one `EmailMessageRelation` with `RelationObjectType = 'Lead'`. | ...keeping anything the guard can't tie to a Lead at all — user-to-user mail, Contact-only correspondence, Case emails all exit here untouched. |
| 2 | **Lives nowhere else** | The message is related to no record outside `{Lead, User}` (see the W1 story below). | ...keeping a capture that also lives on a Contact, Account, Opportunity, Case, etc. — deleting it would prune a timeline this feature has no mandate over. |
| 3 | **EAC-materialized** | The companion Task (via `EmailMessage.ActivityId`) was created by the **Automated Process** user. | ...never treating a message with no companion Task, or a companion created by a real user, as a deletion candidate — a deliberate composer/Agentforce send is never touched. |
| 4 | **Unanchored** | No related Lead carries a `Thread_Key__c` or `Inbound_Message_Id__c` matching the message's `ThreadIdentifier` or `MessageIdentifier`. | ...keeping the message the moment **any one** related Lead anchors it — one legitimate Lead is enough to save it everywhere, because the delete is global (see below). |

Guards 1 and 4 are the "does this belong to a thread we recognize?" question the feature exists to
answer. Guards 2 and 3 exist to keep the blast radius of a destructive, system-mode delete tightly
bounded — guard 3 to platform-materialized rows only, guard 2 to rows that don't also serve another
record's legitimate timeline.

Guard 4 is also what makes the guard correct **after Change 1** (competing brokers get no Lead of their
own — see `docs/2026-07-31-competing-broker-no-lead.md`): a winning Lead now accumulates thread anchors
for *several* different brokers, one per competing submission logged against it, plus its own broker's
thread. A reply in any one of those threads is legitimate on that Lead even though it isn't the winning
broker's own conversation, and guard 4 keeps it correctly — while an unrelated new conversation on the
very same Lead is still removed. `EmailThreadGuardServiceTest.competingBrokerThreadReplyIsKeptOnTheWinningLead`
proves both halves of that contrast in a single decision pass.

---

## 🔴 The W1 Story: Guard 2, and Why `User` Must Be Excluded From It

The guard's **trigger condition** was always Lead-scoped ("is this related to a Lead?"), but its
**remedy is not** — deleting an `EmailMessage` removes it from Salesforce entirely, off every record it
was ever associated with, not just off the Lead. Before the fix, a capture EAC stapled to *both* a
Contact and a Lead was judged solely by whether the Lead anchored it; if not, the whole message was
deleted, silently pruning it off the Contact's timeline too — a record this feature never claimed any
authority over. That is not a hypothetical edge case in this org: the same brokers who show up as Leads
(Broker Protection) also exist as Contacts (`Broker_Assignment__c`, `Lease_Inquiry__c`), and EAC matches
purely by address, so one captured email routinely lands on both.

The header of `EmailThreadGuardService.cls` states the correction plainly: **"DELETE IT FROM
SALESFORCE," not "REMOVE IT FROM THE LEAD"** — the wording matters, and getting it wrong is exactly what
produced the defect. The fix is guard 2: **only delete captures that live nowhere else.** That required
widening what the guard could even see. `EmailMessageRelationSelector.selectByMessageIds` used to filter
`RelationObjectType = 'Lead'` in SOQL (it was even named `selectLeadRelationsByMessageIds`); it now
returns *every* relation type EAC wrote, and the Lead-vs-not classification moved into explicit,
documented Apex in `EmailThreadGuardService` where the decision itself lives.

That classification is an **allow-list of ignorable types**, not a deny-list of protected ones, and the
two members in it are:

- **`Lead`** — the in-scope object. It never counts as "living elsewhere" — deciding about Leads *is*
  this guard's job.
- **`User`** — excluded, and the exclusion is load-bearing. EAC writes a `User` relation for the mailbox
  participants (sender and internal recipients) on essentially every capture, EAC or not. If `User`
  counted as "lives elsewhere," guard 2 would be true for every message the guard ever examines, and the
  feature would delete **nothing, ever** — a dead guard that would still pass a naive smoke test (send
  one unrelated email, watch it *not* disappear, assume the feature is broken for an unrelated reason
  and move on). A `User` relation also isn't a curated CRM timeline in the first place; it just records
  who sent or received the mail.

Anything else — Contact, Account, Opportunity, Case, or any object type nobody anticipated — falls
through to "lives elsewhere" and the capture is **kept**. That direction is deliberate: an allow-list
fails safe (an unknown type defaults to *protected*), where a deny-list naming Contact specifically would
fail open (a future Account or Opportunity association would silently become deletable the day someone
adds a new capture path).

Two tests in `EmailThreadGuardServiceTest` are a matched pair proving both directions and are described
in the class as meaningless without each other:

- `captureAlsoLivingOnAContactIsKept` — goes red if guard 2 is ever removed (the capture would be
  deleted off the Contact too).
- `captureLivingOnlyOnLeadAndUserIsStillDeleted` — goes red if `User` is ever admitted into the "lives
  elsewhere" set (the capture, and every future capture, would stop being deletable at all — a silent,
  permanent disablement that the Contact test alone would never catch).

---

## 🧱 Why Broker Protection's Own Anchor Tasks Can Never Be Deleted

This is a structural guarantee, not a behavioral one, and it is the safety property the whole feature
stands on: **the guard has exactly one route to any Task — the Id stamped on `EmailMessage.ActivityId`**,
read through `TaskSelector.selectByIds`. It never queries Task by `WhoId`, `Subject`, or anchor value for
deletion purposes; the anchor read (`selectThreadAnchorsByWhoIds`) only ever feeds the *keep* decision,
and its rows are never added to a delete list.

Broker Protection's pipeline Tasks are created directly by `InboundEmailActivityService` and are linked
to **no `EmailMessage` at all**, so no `EmailMessage.ActivityId` can ever point at one. The anchors this
whole feature (and Change 1's competing-broker reply-keep behavior) depends on are therefore out of the
guard's reach **by construction**, not by convention — there is no data state, ordering, or future EAC
behavior that makes a pipeline anchor Task a deletion candidate.
`EmailThreadGuardServiceTest.pipelineAnchorTaskIsStructurallyUnreachable` proves this directly: it runs a
real deletion pass on a Lead whose only other activity is a pipeline anchor Task, and asserts the
unanchored capture and its companion are removed while the anchor survives untouched. If a future change
ever adds a second way to reach a Task from this guard, that guarantee — and this test — breaks.

---

## 🔒 Why the Reads Are `SYSTEM_MODE` and the Service Is `without sharing`

The guard's entire execution context is automated, never human: an EAC capture inserts the
`EmailMessage`, the trigger enqueues the queueable, and the queueable runs as whichever principal EAC
committed under (the connected-mailbox user, or Automated Process). That principal is **not provisioned
with any of this repo's permission sets** and has no guaranteed field-level security on the fields the
guard needs — `Thread_Key__c`, `Inbound_Message_Id__c`, `CreatedBy.UserType`, `ThreadIdentifier`,
`MessageIdentifier`, `ActivityId`.

Under `WITH USER_MODE`, an inaccessible field does not degrade the query — it **throws**. That would
kill the queueable outright, and the failure would be silent to any human: no error surfaces anywhere a
person looks, while EAC keeps stapling unrelated conversations onto deal Leads exactly as before. That
inverse failure mode is worse than the alternative it's guarding against — a query that returned zero
anchors instead of throwing would make every genuine reply look unanchored and delete it. `SYSTEM_MODE`
is therefore the only mode under which these reads are reliable, matching the established automation-
path precedent already in this repo (`LeadSelector.GuestReads`, `ContactSelector.GuestReads`,
`GroupMemberSelector`, `ProcessInstanceStepSelector.AuditReads`). `TaskSelector`'s header was amended in
place on 2026-08-02 to record this: its long-standing claim "there is NO guest/automation path on Task"
is no longer true, and the class now deliberately mixes `USER_MODE` (every pre-existing method) with
`SYSTEM_MODE` (the two new EAC-guard methods) — the two groups answer questions for different
principals and must not be "harmonized."

The exposure this accepts is narrow by design: the fields read are RFC routing identifiers and an
activity pointer on rows the platform itself created seconds earlier, read solely to decide whether the
platform's own over-association should be undone. No business data crosses this boundary and nothing is
returned to a user.

`EmailThreadGuardService` itself is declared `without sharing` for the same reason (precedent:
`ApprovalAuditService`, `BrokerPortalService`) — it must remove EAC's over-association from **every**
Lead the capture landed on, not just the subset the automated principal happens to have sharing to.
Under `with sharing`, a Lead outside that principal's sharing would silently keep its polluted timeline
entry, producing exactly the half-cleaned, unauditable state the feature exists to prevent. The elevated
scope is one-directional and narrow: it can only delete platform-created EAC artifacts that already
satisfy all four scope guards, and it reads no business data. DML is plain `Database.delete` (system
mode, not `USER_MODE`) for the identical reason — there is no interactive user whose FLS/CRUD is
meaningful to enforce, and the blast radius is closed by the four scope guards rather than by
permissions.

---

## 🚦 The Queueable-Cap Guard

`EmailMessageTriggerHandler.afterInsert()` checks `Limits.getQueueableJobs() <
Limits.getLimitQueueableJobs()` before enqueueing, and **skips silently** (does not throw) when no slot
is available. This is not defensive boilerplate — it protects EAC's own insert. Apex caps
`System.enqueueJob` at 50 calls per transaction, and the handler's enqueue count is proportional to
**EAC's batch size**, which nothing in this org controls: triggers fire in chunks of 200, so a
10,001-row EAC capture batch would run `afterInsert` 51 times, and an unconditional 51st `enqueueJob`
call would throw `System.LimitException: Too many queueable jobs added to the queue`. Because that
exception is uncaught in a trigger context, it would **roll back EAC's own insert** — the guard would
take the very captures it exists to police down with it. Skipping is always safe; throwing never is,
because the guard is self-healing (a missed capture is examined again the next time EAC re-syncs it) and
the one-off sweep (below) is the documented remedy for any tail the cap truncates.

The 50-per-transaction cap is measured, not assumed, in this org: the legacy "only one queueable per
test transaction" assumption does **not** hold here — `EmailMessageTriggerHandlerTest`'s
`afterInsertWhenQueueableSlotsAreExhausted_skipsInsteadOfThrowing` deliberately fills all available slots
and asserts the handler skips rather than throws once they're gone, and `ExtractAddressQueueableTest`
elsewhere in the repo already enqueues 25 jobs in a single test transaction successfully.

---

## 🧱 Components

### Apex — production

| Class / Trigger | Layer | Responsibility |
|---|---|---|
| `EmailMessageTrigger.trigger` | Trigger | One line: `EmailMessage after insert` → delegates to the handler. Named for the object (`EmailMessage`), not the feature, per this org's one-trigger-per-object rule. |
| `EmailMessageTriggerHandler.cls` | Trigger handler | Extends the repo's `TriggerHandler` base. Enqueues `EmailThreadGuardQueueable` for the trigger chunk's message Ids, gated by the queueable-slot check above. No SOQL, no DML, no business logic. |
| `EmailThreadGuardQueueable.cls` | Queueable (async wrapper) | Thin post-commit hop carrying message Ids to `EmailThreadGuardService.run()`. No decision, no query, no DML. Not `Database.AllowsCallouts` (makes none) and deliberately not a `System.Finalizer` (the job is self-healing and has no compensating work to protect). |
| `EmailThreadGuardService.cls` | Service | Owns the keep/delete decision and the only DML in the feature. `without sharing`. Applies the four scope guards and deletes doomed Tasks then doomed EmailMessages via `Database.delete(..., false)`. |
| `EmailMessageSelector.cls` | Selector (new) | `selectByIds` — captured/composer-logged emails with `ThreadIdentifier`, `MessageIdentifier`, `ActivityId`. `WITH SYSTEM_MODE`. First-ever `EmailMessage` selector in this repo — no prior code queried the object. |
| `EmailMessageRelationSelector.cls` | Selector (new) | `selectByMessageIds` — every association EAC wrote for a set of messages, **every** `RelationObjectType`, not just Lead (widened by W1). `WITH SYSTEM_MODE`. |
| `TaskSelector.cls` | Selector (amended) | Two new methods appended, both `WITH SYSTEM_MODE` (every pre-existing method on this class stays `WITH USER_MODE`): `selectByIds` (companion Tasks + `CreatedBy.UserType` fingerprint) and `selectThreadAnchorsByWhoIds` (pipeline anchors on a set of Leads matching a set of RFC identifiers). |

### Apex — tests

| Test class | Methods | What it proves |
|---|---|---|
| `EmailThreadGuardServiceTest.cls` | 12 | The decision layer: all four scope guards, the W1 matched pair, the competing-broker-thread keep case, structural Task unreachability, a literal 251-message bulk pass, and idempotent re-run safety. |
| `EmailMessageTriggerHandlerTest.cls` | 4 | The async plumbing end-to-end: a real `EmailMessage` insert fires the trigger → handler → queueable → deletion (proves the wiring, not just the decision logic), the queueable's own `execute()` contract, the empty-context no-op, and the queueable-cap skip-not-throw guard. |
| `EmailMessageSelectorTest.cls` | 2 | `selectByIds` returns `ActivityId` populated (the guard's only Task handle) plus the null/empty short-circuit. |
| `EmailMessageRelationSelectorTest.cls` | 3 | `selectByMessageIds` returns every relation type with its `RelationObjectType` (the W1 contract), the no-relations case, and the null/empty short-circuit. |
| `TaskSelectorTest.cls` (4 of 35 methods) | 4 | The two new `SYSTEM_MODE` methods' selector-level contracts: the `CreatedBy.UserType` fingerprint is returned, and `selectThreadAnchorsByWhoIds` matches on either threading key while staying scoped to the Leads it was handed. (`TaskSelector` is a pre-existing, cross-module selector; the other 31 methods predate this feature.) |

**25 test methods** are dedicated to this feature across 5 files (4 new + 1 amended). Assertion style is
`Assert.*` throughout, matching the sibling Broker Protection test classes.

---

## 🔍 Review History

Reviewed against Gate 2 (`salesforce-code-review`) after the initial build. Verdict: **APPROVED WITH
WARNINGS**, with one warning (W1) — the scope-guard-2 defect described above, where a Lead-scoped trigger
condition paired with a Salesforce-wide delete could prune a capture off a Contact's own timeline. The
fix landed the same day (2026-08-02): `EmailMessageRelationSelector` was widened from a Lead-filtered
query to an every-relation-type query (and renamed off its old `selectLeadRelationsByMessageIds` name,
since a method still called that but no longer filtering to Lead would itself be a trap for the next
reader), and `EmailThreadGuardService` gained the `RELATION_TYPES_NOT_LIVING_ELSEWHERE` allow-list and
guard 2. A diff re-verify pass against the fix returned **APPROVED**.

Separately, a **unit-testing agent pass** (also 2026-08-02) closed a coverage gap in
`EmailThreadGuardServiceTest`: every test proving a *keep* decision up to that point did so via the
`ThreadIdentifier` half of guard 4's `OR` alone (in each, `ThreadIdentifier` equals the anchor and
`MessageIdentifier` does not) — so deleting the `|| anchors.contains(message.MessageIdentifier)` term
outright would not have failed a single existing test. `anchorMatchViaMessageIdentifierAloneIsKept` was
added to isolate the second half of that OR: a capture whose `ThreadIdentifier` matches nothing anchored
but whose `MessageIdentifier` matches a value the pipeline anchored under `Inbound_Message_Id__c` (the
shape a reply-to-a-reply produces) must still be kept.

---

## ⚙️ Operational Notes

- **The trigger is live from the moment of deploy.** `EmailMessageTrigger` fires on every future
  `EmailMessage after insert` with no additional activation step — there is no custom setting or feature
  flag gating it. Once deployed, any EAC capture landing on a Lead is subject to the guard immediately.
- **No permission-set provisioning was needed for this feature**, and that is a deliberate consequence of
  the `SYSTEM_MODE` / `without sharing` design above, not an oversight: because the guard's reads bypass
  FLS and its deletes bypass CRUD/sharing by design, there is no principal to grant access to — EAC's own
  automated identity is exactly who the guard is built to run as, unprovisioned. No new permission set,
  and no change to an existing one, ships with this feature.
- **The §5.3 one-off backfill sweep is GATED — do not run it unchunked.** The change prompt's install
  step 3 is a one-off anonymous-Apex sweep of already-materialized noise:
  `EmailThreadGuardService.run(new Map<Id, EmailMessage>([SELECT Id FROM EmailMessage WHERE CreatedDate
  = LAST_N_DAYS:N]).keySet())`. Post-W1, `EmailMessageRelationSelector.selectByMessageIds` returns
  **every** relation type per message rather than Lead-only — roughly 3× the relation rows for the same
  message set (Lead + User on nearly every capture, plus Contact/other on some), since the query widened
  from a single filtered `RelationObjectType` to all of them. Salesforce's per-transaction SOQL row
  budget is 50,000 rows; at roughly 3 relation rows per message, that ceiling is reached with as few as
  **~16,000–17,000 `EmailMessage` Ids in one `run()` call** — well within range of a multi-week
  `LAST_N_DAYS` window in an active org. **Start the sweep narrow — `LAST_N_DAYS:1` — verify the batch
  completes and the outcome looks right, then widen incrementally** rather than reaching for a wide
  window on the first run. This is the same anonymous-Apex entry point `EmailThreadGuardQueueable` uses
  live, so a properly sized sweep is safe to re-run over an overlapping window
  (`reRunOverAlreadyDeletedRows_isASilentNoOp` covers exactly that idempotency).
- **The guard is scope-limited to Leads by design.** Extending it to Contacts or Opportunities requires
  giving those objects thread anchors *first*, then admitting their `RelationObjectType` into the judged
  set — doing it in the other order makes every capture on those objects look unanchored and deletes
  legitimate correspondence.

---

## ⚠️ Known Limitations / Open Items

| # | Item | Detail |
|---|---|---|
| S1 | **A partial purge produces a permanently unreachable capture.** If a companion Task (`EmailMessage.ActivityId`) is ever deleted independently of its `EmailMessage` — by anything outside this guard's own paired delete, e.g. a manual cleanup, a different automation, or a partially failed prior run — the orphaned `EmailMessage` is left with an `ActivityId` pointing at a Task that no longer exists. `TaskSelector.selectByIds` then returns nothing for that Id, `companionFor()` resolves to `null`, and `isEacMaterialized(null)` returns `false` by design (guard 3 fails closed on an absent companion, per the "never delete on a maybe" posture the whole service follows). The message is therefore judged "not EAC-materialized" and kept — forever, since nothing about its state will ever change on a later re-run. This is a narrow, hard-to-reach window (it requires the Task and message to be split apart by something other than this guard's own atomic-enough paired delete) and was accepted rather than fixed. |

Not deploy-blocking — the shipped code passed Gate 2 (APPROVED after the W1 fix). Recorded here so a
future change to the guard's scope guards, or to the deletion order, doesn't have to rediscover it.

---

## 📁 File Locations

| Component | Path |
|---|---|
| Trigger | `force-app/main/default/triggers/EmailMessageTrigger.trigger` |
| Trigger handler | `force-app/main/default/classes/EmailMessageTriggerHandler.cls` |
| Queueable | `force-app/main/default/classes/EmailThreadGuardQueueable.cls` |
| Service (decision + DML) | `force-app/main/default/classes/EmailThreadGuardService.cls` |
| Selector — EmailMessage | `force-app/main/default/classes/EmailMessageSelector.cls` |
| Selector — EmailMessageRelation | `force-app/main/default/classes/EmailMessageRelationSelector.cls` |
| Selector — Task (amended, 2 new methods) | `force-app/main/default/classes/TaskSelector.cls` |
| Test classes | `force-app/main/default/classes/{EmailThreadGuardServiceTest,EmailMessageTriggerHandlerTest,EmailMessageSelectorTest,EmailMessageRelationSelectorTest}.cls`, plus the 4 EAC-guard methods appended to `TaskSelectorTest.cls` |
| Thread anchors the guard matches against (written by an earlier feature, read-only here) | `force-app/main/default/objects/Activity/fields/{Thread_Key__c,Inbound_Message_Id__c}.field-meta.xml` |
| Change spec | `agent-output/change-prompts-broker-protection-2026-07-31.md` (Change Prompt 2) |

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-02 | Documentation Agent | Initial creation — documents the EAC Thread Guard (Broker Protection Change 2): the thread-blind over-association problem, the async trigger→handler→queueable→service architecture and why the work must be post-commit, the four scope guards, the W1 defect and fix (Lead-scoped condition vs. Salesforce-wide remedy, the `{Lead, User}` allow-list and why `User` must be excluded), the structural unreachability of pipeline anchor Tasks, the `SYSTEM_MODE`/`without sharing` security model, the queueable-cap guard protecting EAC's own insert, all 25 dedicated test methods across 5 files, the Gate 2 review history (APPROVED WITH WARNINGS → W1 fix → APPROVED, plus the unit-testing agent's `MessageIdentifier`-alone coverage gap closure), operational notes (no permission-set provisioning needed, the gated §5.3 backfill sweep and its chunking math), and the one known-open item (S1, partial-purge orphan skipped permanently). |
