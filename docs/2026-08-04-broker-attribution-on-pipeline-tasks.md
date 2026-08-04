# Broker Protection — Sender Attribution on Pipeline Email Tasks

**Date:** 2026-08-04
**Author:** Documentation Agent
**Status:** Code complete (2 production classes, 2 test classes — 22 new tests in
`InboundEmailActivityServiceTest`, 4 new tests + a header rewrite in `ExtractAddressQueueableTest`).
No dedicated `agent-output/*-code-review.md` or devops report exists for this specific pass — deploy
status is not evidenced in this document; confirm separately before treating this as live in
`usman-dpeg`.
**Companion docs:** `docs/2026-07-24-broker-protection.md` (the pipeline that inserts this Task in the
first place), `docs/broker-protection-architecture.md` (system-level reference, §"Task shape",
updated alongside this doc), `docs/broker-protection-data-dictionary.md` (Task field table, updated
alongside this doc), `ARCHITECTURE.md` §2 (`InboundEmailActivityService` row, updated in the same
change).
**Design source:** `agent-output/design-requirements.md` (2026-08-04 revision — "Show the broker's
identity on the pipeline email Task"; supersedes that file's previous contents, the completed
Danish/Transaction-access request).

---

## Overview

### Original request

> "I received new email from muhammad.haris@avanzasolutions.com and it didn't created a new lead
> which is the right behaviour. But I am able to view new email as well which was sent by him and
> also it is written that you sent an email however I didn't send email, he send me email instead.
> So we need to make it right. We need to show that broker's name so it must not confuse Junior."

The design doc decomposed this into two distinct defects and fixed only one of them:

| # | Symptom | In scope here? |
|---|---|---|
| D-A | The Task never says who sent the email — no name, no address, no direction | ✅ **Yes — this is the fix** |
| D-B | The Activity timeline chrome literally reads "You sent an email" | ⚠️ Assessed, priced, and **recommended against** — see "Why the `EmailMessage` route was rejected" below |

No new Lead was created for the reported email, and that was already correct — nothing in this
change touches routing, claim arbitration, or Lead creation.

### Business objective

Every inbound broker email the pipeline routes gets logged as a Task on whatever record it landed
on — a Lead, a Contact, or a converted Opportunity. Before this change that Task carried the subject
and the raw body and **nothing else**: no sender name, no sender address, no indication of direction.
Combined with the Lightning Activity timeline's own chrome (which renders every `TaskSubtype =
'Email'` row as "You sent an email" — direction is not a Task field, so the platform can't render it
any other way), a Junior working the Lead had no way to tell that an email had come *from* a broker
rather than been sent *by* DPEG. That is a real, reported confusion in a module whose entire premise
is protecting a broker's claim; it needed a fix that didn't touch the arbitration logic that makes the
pipeline safe.

### Summary

`Task.Subject` now carries a `From <sender>: ` prefix ahead of the original subject, and
`Task.Description` gains a three-line RFC-shaped header block (`From:` / `Subject:` / a 60-hyphen
rule) ahead of the raw body. Both `InboundEmailActivityService.logInboundEmail` overloads gained
`senderName`/`senderEmail` as trailing parameters, and the old sender-less (6-argument) overloads were
**removed outright**, not kept alongside — so no future caller can silently regress to a sender-less
Task. `ExtractAddressQueueable` resolves that sender identity once, at the point the staging row
loads (before any routing branch runs), and refines it fill-if-present after the module's own
sender-first-broker-identity rule (U1) — so the header always shows the *same* broker identity the
pipeline used for arbitration, never a second, independently-derived guess. Zero new metadata, zero
new fields, zero new SOQL, zero new DML.

This is a **mitigation, not a cure**, and the design doc, the code, and this document all say so in
the same words: it makes D-A fully visible, but D-B — the wrong "You sent an email" chrome — is
untouched, because direction is not a Task attribute and nothing on a Task can render it.

---

## Key Design Decisions and Rationale

### Why the Subject prefix, not just the Description

The collapsed Activity-timeline row renders `Subject` and nothing else. A sender recorded only in
`Description` is invisible until the row is expanded — precisely the moment the reader has already
been misled by the collapsed view. So `Subject` carries the prefix and `Description` carries the full
detail; they are complementary, not redundant.

### The composition, and why the sender goes first

```
composed = 'From ' + clip(senderLabel, 60) + ': ' + (isBlank(subject) ? '(no subject)' : subject)
Subject  = clip(composed, 255)
```

`InboundEmailFieldUtil.clip` is **head-preserving** (`value.substring(0, maxLength)` — verified
directly in the utility class), so whatever sits at the front of a composed string survives
truncation and the *tail* is what a length-limited field discards. Putting the sender first, and
clipping it to 60 characters **before** the whole string is clipped to 255, is what makes "the sender
can never be truncated away" true by construction rather than by luck:

- worst-case prefix cost: `5 ('From ') + 60 (name) + 2 (': ') = 67` characters;
- so **at least 188 characters of the original subject always survive** in `Subject`;
- typical broker subjects run 40–90 characters, so in practice nothing is lost at all;
- a pathological 300-character display name cannot eat the subject — it is clipped to 60 first.

`Description` carries the **full, untruncated** original subject on its own `Subject:` line
regardless of what happened to the `Subject` field — that line is the guarantee that the complete
subject survives somewhere even when the 255-character budget is exhausted by a long sender name plus
a long subject together.

Three fallbacks, all pinned by tests in `InboundEmailActivityServiceTest`:

1. **Name blank, address known** → the address becomes the sender label.
2. **Both blank** → **no prefix is emitted at all.** The Subject is then byte-identical to the
   pre-2026-08-04 behaviour — this is what keeps the change strictly additive rather than introducing
   a noisy `From (unknown): (no subject)` on every email the pipeline can't attribute.
3. **Subject blank, sender known** → the existing `(no subject)` fallback is substituted *inside* the
   composition, so the result reads `From Jane Broker: (no subject)`, never a dangling `From Jane
   Broker: `.

### The Description header block

```
From: Muhammad Haris <muhammad.haris@avanzasolutions.com>
Subject: Gordon Center - Jacksonville FL
------------------------------------------------------------

<raw email body, verbatim>
```

The `From:` line is **always emitted**, in one of four shapes — name + address, name only, address
only, or `(sender not identified)` when neither is known — because "the pipeline could not identify a
sender" is itself information the reader needs; an omitted line would read as an oversight rather than
a fact. The address is shown **verbatim**, clipped to 80 characters, and is deliberately **not** run
through `InboundEmailFieldUtil.sanitizeEmail` — that helper returns `null` for anything malformed,
which here would hide information rather than protect anything (`Description` is a text field and
cannot throw `INVALID_EMAIL_ADDRESS`, so there is no DML risk to defend against).

The whole block is composed then clipped once, head-preserving, to 32,000 characters — so the header
always survives and a body that previously filled the entire field now loses roughly the header's
length (~150 characters) from its *tail*. Accepted: the raw body survives verbatim, unclipped, on
`Inbound_Email_Staging__c.Raw_Body__c`, which is the durable copy. A null or blank body used to yield
a null `Description`; it now yields a Description containing just the header — a deliberate
improvement, since the sender is now recorded even for an empty-bodied email.

### One broker identity, resolved once, shown everywhere it matters

The design's governing rule: **the Task shows the exact same broker identity the module already
resolved for arbitration.** A second, independently-derived notion of "who sent this" would be free to
disagree with the one that drove the claim — reintroducing the class of confusion this change exists
to remove.

Concretely, in `ExtractAddressQueueable.execute()`:

| Step | Where | Value |
|---|---|---|
| **Default** | immediately after `staging` loads, before *any* routing branch | `senderName := staging.From_Name__c`; `senderEmail := staging.From_Address__c` |
| **Refine** | immediately after `applySenderFirstBrokerIdentity(extraction)` (U1) | fill-if-present only — `if (isNotBlank(extraction.brokerName)) senderName = extraction.brokerName;` (and the same for email). **Never blanks the envelope default.** |

The placement of the default is load-bearing, not tidiness. `finish()` — the single call site that
hands the sender to `InboundEmailActivityService` — is reachable from **four** places, and the reply /
deterministic-pre-filter prologue **returns before the LLM callout runs**, so there is no `extraction`
to read a sender from on that path at all. Setting the default at the one point every path shares, and
refining it later, is what makes every branch correct *by construction* rather than by remembering to
thread the sender through each one individually.

The refine step is not redundant with the default — it is the entire reason this feature needed a
second step:

| Shape | U1 (`applySenderFirstBrokerIdentity`) | Header shows | Correct? |
|---|---|---|---|
| Normal auto-forward | applies — `brokerEmail := envelope`, `brokerName := From_Name__c` | envelope sender | ✅ identical to the default; refine is a no-op |
| **Paste-forward** (`From_Address__c == Forwarded_By__c`) | **stands down** — the envelope is DPEG's own coordinator | **body-extracted broker** wins over the coordinator | ✅ the branch that matters — without the refine step the header would read "From Junior Dhanani", reproducing the exact confusion reported |
| LLM degraded / no extraction | both values blank | envelope sender | ✅ default stands |

`execute_pasteForward_taskSubjectShowsTheBodyNamedBrokerNotTheCoordinator` in
`ExtractAddressQueueableTest` pins the paste-forward case directly, with an explicit precondition
assertion (the Lead really is the body-named broker) before trusting the Subject assertion — so the
test cannot pass by accident on the wrong code path.

### Both `logInboundEmail` overloads changed, and the sender-less forms were removed, not kept

```apex
public static Id logInboundEmail(Id recordId, String subject, String body,
                                 String messageId, String inReplyTo, String references,
                                 String senderName, String senderEmail)

public static List<Task> logInboundEmail(List<Id> recordIds, String subject, String body,
                                         String messageId, String inReplyTo, String references,
                                         String senderName, String senderEmail)
```

The two String parameters are appended, not inserted mid-signature. The previous 6-argument forms
were **deleted**, not retained as overloads — keeping them would let a future caller silently produce
a sender-less Task again, which is exactly the defect this change fixes. There were no other callers
(verified across the repo) and no test called either overload directly, so removal cost nothing. An
inner `SenderIdentity` DTO was considered and rejected — two appended Strings is the smaller diff for
a single caller.

### Sanitisation policy for the display-only address

Per the design decision, the sender address is shown **verbatim, clipped to 80 characters** and is
explicitly *not* passed through `InboundEmailFieldUtil.sanitizeEmail`. On the paste-forward path,
`extraction.brokerEmail` travels unsanitised by contract, so this slot may occasionally hold a display
name or a fragment rather than a clean address — that is treated as useful information (it signals the
extraction is suspect) rather than something to hide, and it is bounded by the clip either way.

---

## Why the `EmailMessage` Alternative Was Rejected

The design doc assessed and priced replacing the Task with an `EmailMessage` — the only mechanism that
would actually cure D-B, because `EmailMessage.Incoming` is the one field the timeline chrome reads
for direction; a standalone Task has no counterpart. It was **recommended against now**, on two
independent grounds, either of which alone would have been sufficient:

**1. It collides with the EAC Thread Guard's structural-unreachability guarantee.** The deployed guard
(`EmailThreadGuardService`, `ARCHITECTURE.md` §2, "EAC CAPTURE PIPELINE") depends on pipeline Tasks
being reachable through **no** `EmailMessage.ActivityId` — that is a *structural* guarantee, not a
convention, and it's what keeps the guard's deletion sweep from ever touching a Broker Protection
anchor Task. Moving the anchors onto an `EmailMessage`-linked Task would put them exactly where the
guard's deletion logic looks, leaving only its `CreatedBy.UserType == 'AutomatedProcess'` fingerprint
guard standing between them and deletion — a fingerprint the pipeline does not own and cannot set.
Worse, and independently fatal: an `EmailMessageRelation` insert **deletes and recreates the companion
Task with a new Id**, created by the DML user. `Inbound_Message_Id__c` and `Thread_Key__c` cannot
safely live on a row the platform silently discards and rebuilds — losing `Inbound_Message_Id__c`
breaks idempotency invisibly, so a platform redelivery would re-run the entire routing tree and could
re-mint Leads.

**2. Measured (2026-08-02, `usman-dpeg`): an `EmailMessage` cannot reliably reach a Lead at all for a
known broker.** To appear on a Lead's timeline, an `EmailMessage` needs an `EmailMessageRelation`
(Leads are people-side; `RelatedToId` is record-side and does not take a Lead). The sender slot on
that relation is **address-derived**, and when the `FromAddress` already belongs to a **Contact**, no
relation to a same-address **Lead** can be created — every `RelationType` fails with `LIMIT_EXCEEDED`,
*"An email can't have more than 1 sender."* Broker Protection's entire population is repeat brokers who
become Contacts on conversion — that is the module's premise — so this failure mode is systematic, not
an edge case, and it is the exact shape of the incident that triggered this change.

Both blockers are recorded directly in `InboundEmailActivityService`'s class header so a future reader
does not re-litigate the idea without reading them first.

---

## The Adjacent Open Decision: Timeline Duplication

Explicitly out of scope for this change, but directly relevant to it: a Lead's Activity timeline can
carry **two** Tasks for the same inbound message — one written by this pipeline, one written by EAC as
a companion capture Task for the same `EmailMessage`. Deduping them is an **open decision awaiting the
user**, and it is a **hard prerequisite** for the `EmailMessage` route above, not something to decide
independently of it.

Measured evidence (Lead `00Qiw000000SxgHEAS`) shows the shape concretely — four Tasks logged for what
is really a two-message exchange:

| Task Id | Source | Time | What it is |
|---|---|---|---|
| `00Tiw000000G3tBEAS` | Broker Protection pipeline | 05:18 | The inbound broker email, logged by this module |
| `00Tiw000000G3unEAC` | EAC companion capture | 05:19 | The same inbound message, captured separately by EAC |
| `00Tiw000000G4ajEAC` | EAC companion capture | 05:39 | The outbound reply, captured by EAC (the pipeline has no outbound visibility at all) |
| `00Tiw000000G5wbEAC` | Broker Protection pipeline | 06:14 | Haris's follow-up email, logged by this module |

This change makes the pipeline's own rows **easier to tell apart** from the EAC rows (`From <Broker>:
...` vs. EAC's own `Email: ...`-shaped subject) — a small improvement to the duplicate symptom, but
not a fix for it.

---

## Known Follow-Up (Deliberately Deferred)

**Review suggestion S2 — the sender name is unbounded in `buildDescription`.** `buildSubject` bounds
the sender label to 60 characters before composing. `buildDescription` clips the sender **address** to
80 characters but leaves the sender **name** unbounded — and `extraction.brokerName` travels unclipped
by contract, so a model returning a very long `broker_name` could displace part of the body in the
header block. This is bounded and cosmetic, not a correctness or DML risk: the final 32,000-character
clip on the whole composed string prevents any insert failure, and the raw body survives verbatim on
`Inbound_Email_Staging__c.Raw_Body__c` regardless. It should still be fixed — tracked here rather than
folded silently into this change.

---

## What This Change Deliberately Does Not Touch

Every item below was an explicit invariant in the design and is unchanged by this build:

- `Inbound_Message_Id__c` — same value, same line, same clip.
- `Thread_Key__c` — same `PropertyMatchingService.computeThreadKey` call, computed once per email.
- Idempotency (`isAlreadyLogged` → `TaskSelector.selectByInboundMessageId`) — reads neither Subject nor
  Description.
- Reply threading (`TaskSelector.selectLatestByThreadOrMessageIds`) — matches on the two anchor fields
  only.
- The C-3 ascending-priority Task insert order and the `Id DESC` reply tie-break.
- One bulk DML of N Tasks per email — query and DML counts are unchanged, so
  `ExtractAddressQueueable.lastRunQueryCount` / `lastRunDmlCount` budget assertions stay green.
- `TaskSubtype = 'Email'`, and never `Task.Type` (which does not exist in this org's `FieldDefinition`
  — see the class header's 2026-07-31 outage writeup).
- The EAC guard's structural-unreachability guarantee — no `EmailMessage` is created anywhere in this
  change, so `EmailMessage.ActivityId` still cannot reach a pipeline Task.
- Arbitration inputs — `Property_Key__c`, `Competing_Broker_Submission__c.Broker_Email__c`,
  `Lead.Email`, `Lead.Company` — nothing is re-keyed. The sender fields are display-only: they read
  the already-resolved identity, and never write it back anywhere.
- The two existing Subject-matching `TaskSelector` methods (`selectByWhatIdAndSubjects`,
  `selectOpenByWhatIdsAndSubjectPrefix`) — both belong to the Disposition closing checklist and the
  broker check-in reminder, match literal internal subjects scoped by `WhatId`, and cannot collide with
  a `From `-prefixed email subject.

---

## Components Modified

No metadata, no fields, no FlexiPage, no layout, no permission set, no validation rule, no picklist
value. Two production classes, two test classes.

### Apex Classes — modified (2)

| Class | Layer | Change |
|---|---|---|
| `InboundEmailActivityService` | Service (Task write side), `with sharing` | Both `logInboundEmail` overloads gained trailing `senderName`/`senderEmail` parameters; the 6-argument sender-less overloads were removed. Added two private static composers, `buildSubject` and `buildDescription`, and six new constants (`SUBJECT_SENDER_PREFIX`, `SUBJECT_SENDER_SEPARATOR`, `LEN_SUBJECT_SENDER`, `LEN_SENDER_EMAIL`, `SENDER_UNKNOWN`, `HEADER_RULE`). Composition happens once per batch, outside the per-record loop, exactly as the pre-existing clipped values already were. No SOQL, no DML changes — still delegates all reads to `TaskSelector`. |
| `ExtractAddressQueueable` | Queueable orchestrator, `with sharing` | Two new private instance fields, `senderName`/`senderEmail`. Set immediately after the staging row loads in `execute()`, before any routing branch. Refined fill-if-present immediately after `applySenderFirstBrokerIdentity(extraction)`. Passed as the two new trailing arguments at the `finish()` call site. No new SOQL, no new DML — `lastRunQueryCount`/`lastRunDmlCount` budgets are unchanged by design and proven unchanged by test. |

### Test Classes — new / extended (2)

| Class | Change |
|---|---|
| `InboundEmailActivityServiceTest` | **New** (22 test methods) — no dedicated test class existed for this service before this change; it was previously covered only indirectly through `ExtractAddressQueueableTest`'s end-to-end Task assertions. Covers every `buildSubject`/`buildDescription`/`attachTo` branch directly: all five sender-label fallback shapes, the 255-char truncation guarantee (head-preserving, sender intact, subject tail dropped, ≥188 chars surviving), all four `From:` line shapes in the Description, the untruncated-subject guarantee, null/blank-body handling with no literal `"null"` text, the 32,000-char clip, `isAlreadyLogged`, the multi-target bulk-insert ordering contract (C-3), and a 10-target (`MAX_PROPERTIES`-scale) volume test asserting exactly one DML statement and zero added SOQL. |
| `ExtractAddressQueueableTest` | **Extended** — 4 new tests plus a header addendum. Covers: the winner branch showing the envelope sender's name on the Task Subject; the paste-forward shape showing the body-named broker rather than DPEG's own coordinator (the case that matters most, with an explicit precondition check); the reply branch showing the envelope-default sender with **no callout configured at all**, proving the sender comes from the staging-load default and not from an extraction that doesn't exist on that path; and a governor-headroom test reusing the exact same query/DML budget ceiling as the pre-existing U1 envelope-broker test, to prove the sender fields add zero queries and zero DML. |

### Documentation touched in this same pass

`ARCHITECTURE.md` §2 (`InboundEmailActivityService` row — records the Subject prefix, the Description
header block, the overload removal, and relocates the "`Task.Subject` is not a matching key" contract
note out of the Apex class header and into ARCHITECTURE.md so a future agent planning a Subject-based
probe actually finds it); `docs/broker-protection-architecture.md` and
`docs/broker-protection-data-dictionary.md` (Task-shape references updated to note the new
composition, without restructuring either document).

---

## Data Flow

```
Inbound broker email
        │
        ▼
ExtractAddressQueueable.execute()
        │
        ├─ staging = InboundEmailStagingService.getStaging(stagingId)
        │
        ├─ senderName  := staging.From_Name__c     ◄── DEFAULT, set BEFORE any branch
        │  senderEmail := staging.From_Address__c      (finish() is reachable from 4 places;
        │                                                the reply/pre-filter path has no
        │                                                extraction at all)
        │
        ├─ [routing tree runs: reply / pre-filter / callout / gates / per-property loop]
        │
        ├─ applySenderFirstBrokerIdentity(extraction)   ◄── U1: envelope IS the broker,
        │                                                     UNLESS paste-forward
        │
        ├─ REFINE (fill-if-present, never blanks the default):
        │     if isNotBlank(extraction.brokerName)  senderName  = extraction.brokerName
        │     if isNotBlank(extraction.brokerEmail) senderEmail = extraction.brokerEmail
        │
        ▼
finish()
        │
        ▼
InboundEmailActivityService.logInboundEmail(recordIds, subject, body,
    messageId, inReplyTo, references, senderName, senderEmail)
        │
        ├─ composedSubject     = buildSubject(senderName, senderEmail, subject)
        │      "From <sender>: <subject>"  — head-preserving clip to 255
        │
        ├─ composedDescription = buildDescription(senderName, senderEmail, subject, body)
        │      "From: ...\nSubject: ...\n------\n\n<body>"  — head-preserving clip to 32000
        │
        └─ insert Task(Subject=composedSubject, Description=composedDescription,
                        TaskSubtype='Email', Inbound_Message_Id__c=..., Thread_Key__c=...)
                        [ONE bulk DML for all N routed records]
                │
                ▼
        Lead / Contact / Opportunity Activity timeline
        — collapsed row now reads "From Muhammad Haris: Gordon Center - Jacksonville FL"
        — expanded Description shows the full From:/Subject: header + raw body
        — "You sent an email" chrome line is UNCHANGED (see "Why EmailMessage was rejected")
```

---

## File Locations

| Component | Path |
|---|---|
| `InboundEmailActivityService.cls` | `force-app/main/default/classes/InboundEmailActivityService.cls` |
| `InboundEmailActivityServiceTest.cls` (new) | `force-app/main/default/classes/InboundEmailActivityServiceTest.cls` |
| `ExtractAddressQueueable.cls` | `force-app/main/default/classes/ExtractAddressQueueable.cls` |
| `ExtractAddressQueueableTest.cls` | `force-app/main/default/classes/ExtractAddressQueueableTest.cls` |
| Design source | `agent-output/design-requirements.md` |
| Architecture reference | `ARCHITECTURE.md` §2 — `InboundEmailActivityService` row |

---

## Testing

### Volume

- `InboundEmailActivityServiceTest` — 22 test methods, all new.
- `ExtractAddressQueueableTest` — 4 new test methods added to an existing 77-method file (81 total),
  plus a header addendum documenting the change.

### Bulk-test-rule application

Neither class takes the literal 251-record mandate. `InboundEmailActivityService` is a plain
synchronous service with exactly one call site (`ExtractAddressQueueable.finish()`), which can never
pass more than `ExtractAddressQueueable.MAX_PROPERTIES` (10) distinct routed records for a single
email — so a fabricated 251-element target list would prove nothing about a shape production can never
produce. The replacement is a `MAX_PROPERTIES`-scale (10-target) test asserting exactly one DML
statement and zero added SOQL — the actual invariant a future regression could break.
`ExtractAddressQueueable` itself is already de-exempt from the 251 mandate under the narrowed
per-transaction-singleton exception (`.claude/rules/bulk-test-rule.md`) and already carries its own
volume/truncation/governor-headroom tests; this change adds no loop and no per-record query, so those
existing budgets are the correct proof and are reused rather than duplicated.

### What the tests specifically prove

- The sender survives truncation intact at the head of `Subject`, and what is lost above 255
  characters is provably the *tail* of the original subject, not its head or middle (the test uses a
  `HEAD_...TAIL`-marked string specifically so a non-head-preserving clip would fail the assertion —
  a uniform-character string would have passed vacuously).
- A null or blank body never renders the literal text `"null"` in `Description`.
- The 32,000-character clip is head-preserving and exact.
- The sender identity reaching the Task is correct on all three identity shapes (normal auto-forward,
  paste-forward, LLM-degraded/no-extraction) and on the reply branch specifically, which has no
  extraction available at all because it returns before the callout.
- Governor headroom: `lastRunQueryCount`/`lastRunDmlCount` after this change are asserted against the
  *same* budget ceiling the pipeline had before it (reusing the pre-existing U1 test's numbers
  deliberately, so a regression in either change shows up against an unchanged number rather than one
  invented fresh for this test).

---

## Security

- Both touched classes remain `with sharing`, per `ARCHITECTURE.md` §2. `InboundEmailActivityService`
  still delegates every read to `TaskSelector`; this change adds no SOQL.
- The Task insert is plain `insert` (system mode), unchanged — the module pattern is that the
  automated pipeline context owns the Task, and a missing FLS grant on the sender fields is a
  non-issue because there are no new fields at all; `Subject` and `Description` are standard fields
  visible to anyone who can already see the Task.
- Nothing added here is an arbitration input. The sender identity is read from already-resolved values
  and written only to display fields (`Subject`, `Description`) — never to `Property_Key__c`,
  `Broker_Email__c`, `Lead.Email`, or any other field the claim engine reads.

---

## Notes & Considerations

### Known Limitations

- **The "You sent an email" chrome is not fixed, and nothing on a Task can fix it.** This is stated
  plainly and repeatedly (design doc, class header, this document) because it is the single most
  likely point of future confusion: a reader seeing the broker's name now sitting directly beneath a
  wrong "you sent" line might assume the whole defect was resolved. It was not. Removing that line
  requires migrating this module to `EmailMessage`, which is assessed above and recommended against
  until the timeline-duplication decision (see below) is made first.
- **Sender-name length is unbounded in `Description`** (review suggestion S2, deferred) — see "Known
  Follow-Up" above.
- **Timeline duplication is unresolved** — a Lead can show both a pipeline Task and an EAC companion
  Task for the same message. This change makes the two easier to visually distinguish but does not
  deduplicate them.

### Dependencies

- Depends on `staging.From_Name__c` / `staging.From_Address__c` already being loaded by
  `InboundEmailStagingSelector.selectById` — no new selector method or query was needed.
- Depends on `InboundEmailFieldUtil.clip`'s head-preserving behaviour, which this change relies on for
  its core truncation guarantee and does not modify.
- The EAC Thread Guard's structural-unreachability guarantee (`EmailThreadGuardService`,
  `ARCHITECTURE.md` §2) is a hard dependency of the decision **not** to use `EmailMessage` here — any
  future change to that guarantee should re-open this decision, not just the guard's own tests.

---

## Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-04 | Documentation Agent | Initial creation — documents the sender-attribution fix (Subject prefix, Description header block, overload signature change), the rejected `EmailMessage` alternative with both independent blockers, the adjacent open timeline-duplication decision with measured Task evidence, and the deferred S2 follow-up. `ARCHITECTURE.md` §2 and the companion Broker Protection docs updated in the same pass. |
