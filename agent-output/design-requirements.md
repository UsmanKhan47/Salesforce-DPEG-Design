# DESIGN REQUIREMENTS — Show the broker's identity on the pipeline email Task

**Date:** 2026-08-04
**Org:** `usman-dpeg`
**Module:** Broker Protection — inbound email-to-Lead pipeline
**Supersedes:** the previous contents of this file (Danish / Transaction Owner access — shipped).

---

## 1. WHAT THE USER REQUESTED (verbatim)

> "I received new email from muhammad.haris@avanzasolutions.com and it didn't created a new lead
> which is the right behaviour. But I am able to view new email as well which was sent by him and
> also it is written that you sent an email however I didn't send email, he send me email instead.
> So we need to make it right. We need to show that broker's name so it must not confuse Junior."

**Decomposed into two distinct defects, only one of which this change fixes:**

| # | Symptom | Cause | In scope here? |
|---|---|---|---|
| D-A | The activity does not say who sent the email | `InboundEmailActivityService` records **no sender at all** — not name, not address, not direction | ✅ **YES — this is the requested fix** |
| D-B | The timeline says "You sent an email" | Lightning chrome for `TaskSubtype = 'Email'`. A standalone Task has **no direction field**; only `EmailMessage.Incoming` drives "X sent you an email" | ⚠️ **Assessed and PRICED in §4 — recommended AGAINST doing now** |

**Explicitly NOT designed (per brief):** the timeline-duplicate problem (pipeline Task + EAC
companion Task for the same Message-ID). See §6.

**No new Lead was created — confirmed correct.** Nothing in this design touches routing, claim
arbitration, or Lead creation.

---

## 2. VERIFIED BASELINE (read from source this run — not assumed)

| Fact | Source |
|---|---|
| The Task is built with `Subject` (verbatim clipped subject), `Description` (raw body), `ActivityDate = today`, `Status = Completed`, `TaskSubtype = 'Email'`, `Inbound_Message_Id__c`, `Thread_Key__c`. **Nothing else.** | `InboundEmailActivityService.cls` L216-226 |
| `logInboundEmail` has two overloads (single-Id wrapper → `List<Id>` bulk) and **exactly one production caller**: `ExtractAddressQueueable.finish()` L1336 | grep across repo |
| `finish()` reads **only `staging.*`** — it has no access to the extraction, because `extraction` is a **local variable inside `execute()`**, not an instance field | `ExtractAddressQueueable.cls` L602, L1335-1338 |
| `finish()` is reached from **four** places: reply/pre-filter prologue (L598 — **no extraction exists**), D2 hard gate (L619), U2 call-for-offers gate (L627), and the normal routing path (L632) | `ExtractAddressQueueable.execute` |
| `staging.From_Name__c` (envelope display name) and `staging.From_Address__c` (envelope sender = the broker, per U1) are **already loaded** by `InboundEmailStagingSelector.selectById` | `InboundEmailStagingSelector.cls` L49-53 |
| `InboundEmailFieldUtil.clip` is **head-preserving** (`substring(0, maxLength)`) — the front of the string always survives truncation | `InboundEmailFieldUtil.cls` L45-50 |
| **No Broker Protection query matches on `Task.Subject`.** The two subject-matching selectors (`selectByWhatIdAndSubjects`, `selectOpenByWhatIdsAndSubjectPrefix`) belong to the Disposition closing checklist and the broker check-in reminder, match literal internal subjects scoped by `WhatId`, and cannot collide with pipeline Tasks | `TaskSelector.cls` L116-126, L321-331 |
| **`ExtractAddressQueueableTest` never asserts `Task.Subject` or `Task.Description`.** Every Task assertion reads `WhoId` / `Inbound_Message_Id__c` / `Thread_Key__c` / `COUNT()`. No existing test breaks on a Subject-format change | `ExtractAddressQueueableTest.cls` (all `FROM Task` sites) |
| **`InboundEmailActivityServiceTest` does not exist.** Documented gap | `docs/2026-07-31-llm-field-extraction.md` L521 |

---

## 3. (a) RECOMMENDED APPROACH — put the sender on the Task itself

**One-line statement:** the Task's `Subject` gains a sender prefix, and its `Description` gains a
three-line header block. No new fields, no `EmailMessage`, no change to any threading key.

### 3.1 Subject format — DECIDED

```
From <Sender>: <original subject>
```

Worked example from the reported incident:

```
From Muhammad Haris: Gordon Center - Jacksonville FL
```

**Why a Subject prefix is mandatory and a Description-only fix is not sufficient:** the collapsed
Activity-timeline row renders **`Subject` only**. A sender recorded anywhere else is invisible until
Junior expands the row — which is precisely the moment he has already been misled.

**Alternative wording available at the gate (one-word change, same design):**
`Received from <Sender>: <subject>`. It contradicts the "You sent an email" chrome more directly, at
a cost of 9 extra leading characters in a narrow column. **Recommendation: `From ` — the name is the
thing the user asked for, and it should sit as close to the left edge as possible.**

### 3.2 The original subject must remain intact and searchable — DECIDED: yes, in two places

1. **In `Subject`**, after the prefix, verbatim — so SOSL / `LIKE` on the subject text still hits,
   provided the composed string fits 255.
2. **In `Description`**, on its own `Subject:` line, **unabridged** — this is the guarantee. It
   exists precisely because the prefix now shares the 255-char Subject budget, so a long subject can
   lose its tail there. `Description` is 32,000 characters and is searchable.

### 3.3 Truncation behaviour — stated explicitly (brief item)

New constant: `LEN_SUBJECT_SENDER = 60` (the sender label's own budget inside the Subject).

Composition order:

```
composed = 'From ' + clip(senderLabel, 60) + ': ' + (isBlank(subject) ? '(no subject)' : subject)
Subject  = clip(composed, 255)          // existing LEN_SUBJECT
```

Because `clip` is **head-preserving**:

- **The sender is NEVER truncated away.** It sits at the front; truncation eats the tail.
- **What gets lost when the total exceeds 255 is the tail of the ORIGINAL SUBJECT.** That is the
  correct trade: the sender is the information the user asked for, and the full subject is preserved
  in `Description`.
- **Worst-case arithmetic:** prefix cost ≤ `5 ('From ') + 60 (name) + 2 (': ') = 67`, so **at least
  188 characters of the original subject always survive in `Subject`**. Typical broker subjects are
  40–90 characters, so in practice nothing is lost at all.
- A pathological 300-character display name cannot eat the subject — it is clipped to 60 first.
- **Blank subject:** the existing `'(no subject)'` fallback is applied *inside* the composition, so
  the Subject is never left as a dangling `From X: `. Result: `From Muhammad Haris: (no subject)`.
- **No sender known at all** (both name and address blank): **emit no prefix.** The Subject is then
  byte-identical to today's behaviour. This keeps the change strictly additive and avoids a noisy
  `From (unknown): (no subject)`.

### 3.4 Description header block — DECIDED

```
From: Muhammad Haris <muhammad.haris@avanzasolutions.com>
Subject: Gordon Center - Jacksonville FL
------------------------------------------------------------

<raw email body, verbatim, exactly as today>
```

- `From:` line renders `name <address>` when both are known; `name` alone; `address` alone; or
  `(sender not identified)` when neither. The line is **always emitted** — "the pipeline could not
  identify a sender" is itself information Junior needs.
- `Subject:` line carries the **full** original subject (or `(no subject)`).
- Separator is a plain 60-hyphen ASCII rule + one blank line. No box-drawing characters, no
  non-ASCII — this text lands in a 32,000-char field that is also read by scripts and exports.
- **Compose-then-clip, same head-preserving rule:**
  `Description = clip(header + '\n' + body, 32000)`. The header therefore always survives; the
  **body's tail** is what is lost at the ceiling.
- **Accepted cost, stated:** a body that previously used all 32,000 characters now loses ~150 of them
  from the tail. Acceptable — the raw body also survives verbatim on
  `Inbound_Email_Staging__c.Raw_Body__c`, which is the durable copy.
- **Behaviour change worth noting:** a null/empty body used to produce a null `Description`. It will
  now produce a Description containing just the header. That is an improvement — the sender is
  recorded even for an empty-bodied email.

### 3.5 Source of the name and address — DECIDED

**Rule: the Task header shows the SAME broker identity the module already resolved for this email.**
One email, one broker identity. A second, independently-derived notion of "who sent this" would be
free to disagree with the one that drove arbitration — which is the exact class of confusion this
change exists to remove.

Concretely, in `ExtractAddressQueueable`:

| Step | Where | Value |
|---|---|---|
| **Default** | immediately after `staging` is loaded in `execute()` (before *any* branch) | `senderName := staging.From_Name__c`; `senderEmail := staging.From_Address__c` |
| **Refine** | immediately after `applySenderFirstBrokerIdentity(extraction)` (L613) | fill-if-present only: `if (isNotBlank(extraction.brokerName)) senderName = ...`; same for `brokerEmail`. **Never blank out the envelope default.** |

**Why the default must be set at load, not passed in from the routing path:** `finish()` is reached
from four places and **the reply / deterministic-pre-filter branch has no extraction at all** — it
returns before the callout. Deriving the sender only on the extraction path would ship a fix that is
silently absent from the highest-volume branch. Initialising the field at the single common point and
refining it later makes every branch correct *by construction*.

**Why the refine step is not redundant with the envelope default:**

| Shape | `applySenderFirstBrokerIdentity` (U1) | Resulting header | Correct? |
|---|---|---|---|
| Auto-forwarded broker email (the normal case) | U1 applies: `brokerEmail := envelope`, `brokerName := From_Name__c` | envelope sender | ✅ identical to the default; refine is a no-op |
| **Paste-forward** (`From_Address__c == Forwarded_By__c`) | U1 **stands down** — the envelope is DPEG's own coordinator | **body-extracted broker** wins over the coordinator | ✅ the branch that matters — without refine the header would read "From Junior Dhanani", reproducing the exact confusion reported |
| LLM degraded / no extraction | both extraction values blank | envelope sender | ✅ default stands |

**Fallback when unknown:** name blank → the prefix uses the **address**; both blank → **no prefix**
(§3.3) and `From: (sender not identified)` in the Description.

**Sanitisation — DECIDED: display verbatim, clipped to 80; do NOT run `sanitizeEmail`.** Rationale:
`sanitizeEmail` returns **null** for anything malformed, which would hide information. `Subject` and
`Description` are text fields and cannot throw `INVALID_EMAIL_ADDRESS`, so there is no DML risk to
defend against. `extraction.brokerEmail` travels unsanitised by contract, so on the rare
paste-forward path the address slot may hold a display name or a fragment — that is *information*
(it tells the reader the extraction is suspect), and it is bounded by the 80-char clip.

### 3.6 Method signatures — DECIDED: BOTH overloads change

```apex
public static Id logInboundEmail(Id recordId, String subject, String body,
                                 String messageId, String inReplyTo, String references,
                                 String senderName, String senderEmail)

public static List<Task> logInboundEmail(List<Id> recordIds, String subject, String body,
                                         String messageId, String inReplyTo, String references,
                                         String senderName, String senderEmail)
```

- The two `String` parameters are **appended** to both signatures.
- **The 6-argument forms are REMOVED, not retained as overloads.** Keeping them would let a future
  caller silently log a sender-less Task — reintroducing this exact defect. There are no other
  callers (verified) and no test calls either overload directly, so removal costs nothing.
- **What the caller must pass:** `senderName` and `senderEmail` from the two new instance fields
  described in §3.5. `finish()` becomes an 8-argument call; nothing else in `finish()` changes.
- Considered and rejected: an inner `SenderIdentity` DTO. Two appended Strings is the smaller diff
  for a single caller. Recorded here so code review does not re-litigate it.

### 3.7 Where the composition lives — DECIDED

Two new **private static** helpers (`buildSubject`, `buildDescription`) in
**`InboundEmailActivityService`**, alongside the existing `SUBJECT_FALLBACK` and the clip budgets it
already owns.

- **Not** in `ExtractAddressQueueable` — presentation belongs with the writer, and the queueable is
  already the largest class in the module.
- **Not** in `InboundEmailFieldUtil` — that class is deliberately a pure length/format utility with
  zero feature semantics.

New constants on `InboundEmailActivityService`: `SUBJECT_SENDER_PREFIX = 'From '`,
`SUBJECT_SENDER_SEPARATOR = ': '`, `LEN_SUBJECT_SENDER = 60`, `LEN_SENDER_EMAIL = 80`,
`SENDER_UNKNOWN = '(sender not identified)'`, `HEADER_RULE` (the 60-hyphen line).

---

## 4. (b) THE `EmailMessage` ALTERNATIVE — assessed, priced, RECOMMENDED AGAINST NOW

**What it would buy:** it is the **only** thing that removes the wrong "You sent an email" chrome.
The direction is not a Task attribute; it comes from `EmailMessage.Incoming`. The subject prefix in
§3 is therefore a **mitigation, not a cure** — the chrome line stays wrong, with the broker's name
now printed immediately beneath it.

**Three sub-options, all priced:**

| Option | Shape | Verdict |
|---|---|---|
| **B1** | `EmailMessage` **in addition to** the Task; anchors stay on the Task | ❌ **Does not solve the complaint.** The Task row still renders "You sent an email" — you have added a correct row next to the wrong one. It makes the §6 duplicate problem strictly worse, and is only viable *after* dedup, which is out of scope. |
| **B2** | `EmailMessage` **instead of** the Task; anchors relocated onto the platform-created companion Task | ❌ **The most dangerous idea in the space.** See §4.1. |
| **B3** | `EmailMessage` instead of the Task; anchors on a separate non-EmailMessage Task | ❌ Degenerates to B1 — two rows again. |

### 4.1 The collision with the EAC Thread Guard's structural-unreachability guarantee — stated plainly

Guard invariant #4 (`ARCHITECTURE.md`, EAC CAPTURE PIPELINE; class header
`EmailThreadGuardService.cls` L89-96): the guard's **only** route to a Task is
`EmailMessage.ActivityId`, and pipeline Tasks are linked to **no** `EmailMessage`, so
*"the thread anchors this whole feature depends on are OUT OF REACH BY CONSTRUCTION, not by
convention — there is no data state, no ordering, and no future EAC behavior that makes a pipeline
anchor a deletion candidate. If a future change ever adds a second way to reach a Task, that
guarantee dies with it."* Pinned by
`EmailThreadGuardServiceTest.pipelineAnchorTaskIsStructurallyUnreachable`.

- **B1/B3 do not break it** — the anchors stay on a Task no `EmailMessage.ActivityId` names.
- **B2 breaks it outright.** The anchors would live on exactly the row `ActivityId` points at. The
  only thing then standing between them and deletion is guard 3, the
  `CreatedBy.UserType == 'AutomatedProcess'` fingerprint — **a value the pipeline does not own and
  cannot set**.
- **Worse, and measured:** any `EmailMessageRelation` insert **deletes and recreates the companion
  Task with a new Id**, created by the DML user. A platform-owned, platform-recreated row is not
  somewhere `Inbound_Message_Id__c` and `Thread_Key__c` can safely live. Losing
  `Inbound_Message_Id__c` **silently breaks idempotency** — a platform redelivery would re-run the
  entire routing tree and can re-mint Leads — and breaks reply threading with it. Neither failure
  raises an error; both are invisible until a duplicate Lead appears.

**Can B2 be made safe?** Only by adding a fourth guard whose predicate the pipeline controls (e.g.
"never delete a Task carrying `Inbound_Message_Id__c`"). That converts a *structural* guarantee into
a *conditional* one enforced by guard code — strictly weaker, and exactly the trade the guard's own
header warns against. **Not worth it for a chrome fix.**

### 4.2 An independent, measured blocker: EmailMessage cannot reliably reach a Lead

To appear on a **Lead**'s timeline, an `EmailMessage` needs an `EmailMessageRelation` (Leads are
people-side; `RelatedToId` is the record-side field and does not take a Lead).

Measured in `usman-dpeg` on 2026-08-02: **the sender slot is address-derived, not
RelationType-derived.** An **Incoming** message whose `FromAddress` equals a **Contact's** email
cannot take a relation to a same-address **Lead** — the platform re-derives the slot from the
relation's address, the Contact holds the single sender slot, and **every** `RelationType` fails with
`LIMIT_EXCEEDED`, *"An email can't have more than 1 sender."*

Broker Protection's population is **repeat brokers who become Contacts on conversion** — that is the
module's entire premise, and it is the shape of the very incident reported here. So
EmailMessage-on-a-Lead is **systematically impossible for any known/converted broker**, and it fails
at DML time inside a transaction that may already hold a committed registry claim.

### 4.3 Verdict and effort

**RECOMMENDATION: do NOT do this now.**

| | Recommended (§3) | EmailMessage route |
|---|---|---|
| Production classes touched | 2 | 4–6 (new selector + service surface, guard scope re-derivation, queueable) |
| New DML objects | 0 | `EmailMessage` + `EmailMessageRelation` |
| Hard prerequisite | none | §6 dedup must land first |
| Live-org verification required | none beyond normal UAT | a real two-way thread, plus a measured test of the sender-slot blocker against a Lead whose broker already exists as a Contact |
| Risk to a deployed destructive feature | none | direct |
| Order of magnitude | one dev change | comparable to the guard/adopter change itself |

**Revisit trigger:** only when bundled with the §6 dedup decision **and** after the sender-slot
blocker has been measured against a converted-broker Lead. Until then, §3 delivers the requested
outcome (the broker's name is visible) at a fraction of the cost and zero risk.

---

## 5. WHAT THIS CHANGE DOES *NOT* TOUCH — invariants confirmed intact

| Invariant | Status |
|---|---|
| `Inbound_Message_Id__c` — same value, same line, same clip | ✅ untouched |
| `Thread_Key__c` — same `computeThreadKey` call, computed once | ✅ untouched |
| Idempotency (`isAlreadyLogged` → `selectByInboundMessageId`) | ✅ reads neither Subject nor Description |
| Reply threading (`selectLatestByThreadOrMessageIds`) | ✅ matches on the two anchor fields only |
| C-3 ascending-priority insert order and the `Id DESC` tie-break | ✅ untouched |
| ONE bulk DML of N Tasks | ✅ untouched — **query and DML counts are unchanged**, so `lastRunQueryCount` / `lastRunDmlCount` budget assertions stay green |
| `TaskSubtype = 'Email'`, and **never** `Task.Type` | ✅ untouched (portability rule) |
| EAC guard: no `EmailMessage` is created ⇒ `ActivityId` still cannot reach a pipeline Task | ✅ `pipelineAnchorTaskIsStructurallyUnreachable` still holds |
| EAC adopter / `EmailThreadAnchorService` (read the two anchor fields only) | ✅ untouched |
| **Arbitration inputs** — `Property_Key__c`, `Competing_Broker_Submission__c.Broker_Email__c`, `Lead.Email`, `Lead.Company` | ✅ **nothing is re-keyed.** Display-only: it reads the resolved identity, never writes it |
| Subject-matching selectors (`selectByWhatIdAndSubjects`, `selectOpenByWhatIdsAndSubjectPrefix`) | ✅ checked — Disposition / check-in scoped by `WhatId` with literal internal subjects; no collision with a `From `-prefixed email subject |

---

## 6. (c) ADJACENT, NOT DESIGNED HERE

**Timeline duplication.** Lead `00Qiw000000SxgHEAS` carries both a pipeline Task and an EAC companion
Task for the same inbound message (`00Tiw000000G3tBEAS` and `00Tiw000000G3unEAC`). Deduping them is
an **open decision awaiting the user** and is deliberately out of scope. Two notes for whoever picks
it up:

- This change makes the pipeline row **easier to tell apart** from the EAC row
  (`From <Broker>: ...` vs `Email: ...`) — a small improvement to the duplicate symptom, not a fix.
- The dedup decision is a **hard prerequisite** for §4's EmailMessage route. They should be decided
  together, not sequentially.

---

## 7. (d) BLAST RADIUS

### 7.1 Production code — 2 classes

| File | Change |
|---|---|
| `force-app/main/default/classes/InboundEmailActivityService.cls` | Both `logInboundEmail` overloads gain `senderName` / `senderEmail`; 2 new private static composers (`buildSubject`, `buildDescription`); ~6 new constants; class-header + Javadoc updates |
| `force-app/main/default/classes/ExtractAddressQueueable.cls` | 2 new instance fields (`senderName`, `senderEmail`); 1 initialisation after the `staging` load in `execute()`; 1 fill-if-present refine block after `applySenderFirstBrokerIdentity` (L613); the `finish()` call site (L1336); class-header note |

**Layering:** unchanged and conformant. `InboundEmailActivityService` stays a Service (all SOQL still
delegated to `TaskSelector`; the composers are pure string functions). `ExtractAddressQueueable` stays
a Queueable. No new SOQL, no new DML.

### 7.2 Tests

| File | Change |
|---|---|
| `force-app/main/default/classes/ExtractAddressQueueableTest.cls` | **Compiles unchanged** — no test calls `logInboundEmail` directly and **no test asserts `Task.Subject` or `Task.Description`** (verified across every `FROM Task` site). New assertions are needed to cover the sender on all four `finish()` paths — in particular the **reply / pre-filter branch**, which has no extraction |
| `force-app/main/default/classes/InboundEmailActivityServiceTest.cls` | **NEW.** Does not exist today (a documented gap). The signature change is the natural moment to create it: subject composition, the 255 truncation contract, the 32,000 description contract, and every sender fallback are pure functions and cheap to pin |

These are the standing Step-4 unit-testing workflow, not added scope. On
`.claude/rules/bulk-test-rule.md`: `ExtractAddressQueueable` is **de-exempt** and already carries its
volume / truncation / governor-headroom tests — this change adds no loop and no per-record query, so
those budgets are unaffected and the existing tests continue to enforce them.

### 7.3 Metadata — **NONE. No new fields.**

Justification against a `Task`-side sender field (e.g. `From_Address__c` on `Activity`), considered
and rejected:

1. **It would not fix the reported symptom.** The collapsed timeline row renders `Subject` only. A
   custom field is invisible there.
2. **FLS.** Custom Task fields live under `objects/Activity/fields/` (shared namespace with `Event`)
   and arrive from a Metadata-API deploy with **no field permissions for any profile**. Profiles are
   `.forceignore`d in this repo, so the grant would have to be added to `Broker_Protection_Access`
   and to every persona permission set — and the field would read blank for Junior until it is. The
   pipeline writes in system mode, so the value would land and simply be invisible.
3. **`Description` costs nothing and is already sufficient.** 32,000 characters, already rendered,
   already searchable, already visible to anyone who can see the Task.
4. **When a field would earn its place:** if the sender must be **reported on** or **queried** (e.g.
   "all inbound emails from broker X this month"). That is a different requirement; raise it
   separately.

Also unchanged: no FlexiPage, no layout, no permission set, no validation rule, no picklist value.

### 7.4 Documentation (Step 7 agent)

- `ARCHITECTURE.md` §2 — one sentence on the `InboundEmailActivityService` row (§6 keep-current rule).
- `docs/broker-protection-architecture.md` (L198) and `docs/broker-protection-data-dictionary.md`
  describe the Task shape and should note the new Subject/Description composition.

### 7.5 Residual risks — recorded, accepted

| # | Risk | Mitigation |
|---|---|---|
| R1 | The Subject text is not part of any matching contract **today**. A future Subject-based probe on pipeline Tasks would now have to account for the prefix | Record it in the `InboundEmailActivityService` class header as a contract note |
| R2 | The `Description` budget shrinks by the header length (~150 chars); bodies at the 32,000 ceiling lose that much more from the tail | Accepted — the raw body survives verbatim on `Inbound_Email_Staging__c.Raw_Body__c` |
| R3 | On the paste-forward shape the header shows an **LLM-extracted** broker, which can be wrong | Bounded: a labelled `From:` line on a Task, not an arbitration key. No `Property_Key__c`, no `Broker_Email__c`, no `Lead.Email` is affected |
| R4 | The "You sent an email" chrome remains wrong | **Known and deliberate** — §4. The user must be told the prefix mitigates but does not remove it |

---

## 8. EXECUTION ORDER

No cross-agent dependency. This is **one developer change** — the service and its single caller
compile together and must ship in one commit.

1. 🟢 `salesforce-developer` — §3 (both classes)
2. 🟡 `salesforce-unit-testing` — §7.2 (extend `ExtractAddressQueueableTest`; create `InboundEmailActivityServiceTest`)
3. 🟣 `salesforce-code-review`
4. 🔴 `salesforce-devops` + 🔷 `salesforce-documentation` (parallel)

**No admin work.** No metadata is created or changed.

**Complexity routing:** standard Apex service + caller work → `salesforce-developer` (not
technical-architect). No integration, no callout, no LDV, no new architectural layer.

---

## 9. PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR salesforce-admin

```
No admin work required for this request. No metadata is created or changed —
no fields, no layouts, no permission sets, no FlexiPages.
```

### 🟢 PROMPT FOR salesforce-developer

```
Make the inbound broker email's SENDER visible on the pipeline Task, so Junior is not
misled by the platform's "You sent an email" timeline chrome. Display-only change:
create no new fields, no EmailMessage, and change no routing, claim or arbitration logic.

Read ARCHITECTURE.md (§2 Key Apex Services, Broker Protection staging model, INTAKE
RULES V2 / U1, EAC CAPTURE PIPELINE) and the class headers of
InboundEmailActivityService.cls and ExtractAddressQueueable.cls before starting.

FILE 1 — force-app/main/default/classes/InboundEmailActivityService.cls

1. Append two parameters to BOTH logInboundEmail overloads:
       ..., String senderName, String senderEmail
   REMOVE the 6-argument forms; do not keep them as overloads. There are no other
   callers, and keeping them would let a future caller silently log a sender-less Task.

2. Add constants: SUBJECT_SENDER_PREFIX = 'From ', SUBJECT_SENDER_SEPARATOR = ': ',
   LEN_SUBJECT_SENDER = 60, LEN_SENDER_EMAIL = 80,
   SENDER_UNKNOWN = '(sender not identified)', and HEADER_RULE (a 60-hyphen ASCII line).

3. Add a private static buildSubject(String senderName, String senderEmail, String subject):
     - senderLabel = senderName if non-blank, else senderEmail if non-blank, else null.
     - baseSubject = subject if non-blank, else the existing SUBJECT_FALLBACK '(no subject)'.
     - If senderLabel is null -> return clip(baseSubject, LEN_SUBJECT). This keeps the
       Subject byte-identical to today when no sender is known.
     - Else return clip('From ' + clip(senderLabel, LEN_SUBJECT_SENDER) + ': ' + baseSubject,
       LEN_SUBJECT).
     - InboundEmailFieldUtil.clip is head-preserving, so the sender can never be truncated
       away; the ORIGINAL SUBJECT'S TAIL is what is lost. Worst case the prefix costs 67
       chars, leaving >= 188 chars of the subject. Document this in the Javadoc.

4. Add a private static buildDescription(String senderName, String senderEmail,
   String subject, String body) producing:

       From: <name> <<address>>
       Subject: <full original subject>
       ------------------------------------------------------------
       <blank line>
       <body verbatim>

     - From line: 'name <address>' when both known; the name alone; the address alone;
       or SENDER_UNKNOWN when neither. Always emit the line.
     - Address is clipped to LEN_SENDER_EMAIL (80) and shown VERBATIM. Do NOT call
       InboundEmailFieldUtil.sanitizeEmail on it - sanitizeEmail returns null for anything
       malformed, which would hide information, and neither Subject nor Description is an
       Email-type field so there is no DML risk.
     - Subject line carries the FULL original subject (or '(no subject)'). This is the
       guarantee that the untruncated subject survives even when the composed Subject
       field is clipped.
     - Compose header + '\n' + body, then clip the WHOLE thing to LEN_DESCRIPTION (32000).
       Head-preserving clip means the header always survives and the body's tail is lost.
     - A null/blank body yields a Description containing just the header - that is correct
       and intentional.
     - ASCII only; no box-drawing characters.

5. Use both composers in the bulk logInboundEmail. Compose ONCE outside the loop, exactly
   as the existing clipped values are, since every Task in the batch shares them.

FILE 2 — force-app/main/default/classes/ExtractAddressQueueable.cls

6. Add two private instance fields: String senderName; String senderEmail;

7. In execute(), IMMEDIATELY after `staging = InboundEmailStagingService.getStaging(stagingId);`
   and its null check, set:
       senderName  = staging.From_Name__c;
       senderEmail = staging.From_Address__c;
   This placement is load-bearing: finish() is reached from FOUR paths, and the
   reply / deterministic-pre-filter branch (routePrologueWithoutCallout) returns BEFORE
   any extraction exists. Defaulting at the single common point is what makes every
   branch correct by construction.

8. IMMEDIATELY after the existing applySenderFirstBrokerIdentity(extraction) call, add a
   FILL-IF-PRESENT refine (never blank out the envelope default):
       if (String.isNotBlank(extraction.brokerName))  { senderName  = extraction.brokerName; }
       if (String.isNotBlank(extraction.brokerEmail)) { senderEmail = extraction.brokerEmail; }
   Rationale to put in a comment: on the normal auto-forward path U1 has already made these
   equal to the envelope, so this is a no-op. It matters on the PASTE-FORWARD shape, where
   U1 stands down because From_Address__c == Forwarded_By__c - there the envelope sender is
   DPEG's own coordinator, and showing that name would reproduce the exact confusion this
   change fixes.

9. In finish(), pass senderName and senderEmail as the two new trailing arguments. Nothing
   else in finish() changes.

MUST NOT CHANGE — confirm each in your summary:
   - Inbound_Message_Id__c and Thread_Key__c: same values, same lines, same clip.
   - The ascending-priority insert order and the single bulk DML of N Tasks.
   - SOQL and DML counts (lastRunQueryCount / lastRunDmlCount budgets must stay identical).
   - TaskSubtype = 'Email'; NEVER set Task.Type (it does not exist in this org, compiles
     anyway, and throws at runtime).
   - No EmailMessage is created anywhere. The EAC guard's structural-unreachability
     guarantee (EmailMessage.ActivityId can never point at a pipeline Task) must remain true.
   - No routing, claim, arbitration or Lead-creation logic.

Update the class headers of both files: InboundEmailActivityService gains a short section on
the sender header and a contract note that the Subject now carries a 'From <name>: ' prefix
(no query in this repo matches on Task.Subject today - keep it that way).

Project conventions: API 67.0, with sharing, all SOQL in selectors, no SOQL/DML in loops.
Do not deploy.
```

### 🟡 PROMPT FOR salesforce-unit-testing

```
Create/extend tests for the sender-on-Task change.

NEW: force-app/main/default/classes/InboundEmailActivityServiceTest.cls
(no test class exists for this service today). Cover the composition contracts:
  - Subject = 'From <name>: <subject>' when a name is known.
  - Subject falls back to the ADDRESS when the name is blank.
  - Subject carries NO prefix at all when both name and address are blank
    (byte-identical to the pre-change behaviour).
  - Blank subject yields 'From <name>: (no subject)'.
  - TRUNCATION: a 60+ char name and a 300 char subject -> Subject is exactly 255, the
    sender survives at the front, the subject's TAIL is what is lost, and at least 188
    chars of the subject remain.
  - Description begins with the From/Subject/rule header, the FULL untruncated original
    subject is present on the Subject line, and the body follows verbatim.
  - A null body still produces a Description containing the header.
  - A 32000-char body composed with a header is clipped to exactly 32000 with the header intact.
  - Both threading keys are still stamped, and isAlreadyLogged still finds the row.

EXTEND: force-app/main/default/classes/ExtractAddressQueueableTest.cls
  - Assert the sender lands on the Task for ALL FOUR finish() paths, especially the
    REPLY / pre-filter branch (which has no extraction and must fall back to the envelope
    From_Name__c / From_Address__c).
  - Assert the PASTE-FORWARD shape (From_Address__c == Forwarded_By__c) shows the
    BODY-EXTRACTED broker, not DPEG's coordinator.
  - Assert the normal auto-forward path shows the envelope sender.
  - Assert Inbound_Message_Id__c, Thread_Key__c, the Task count, and the insert ORDER
    (highest-priority record gets the highest Id) are all unchanged.
  - Assert the lastRunQueryCount / lastRunDmlCount budgets are unchanged.

Use TestDataFactory. Never @isTest(SeeAllData=true). Target 90%+ on both touched classes.
Note in the InboundEmailActivityServiceTest header that the .claude/rules/bulk-test-rule.md
251-record mandate is satisfied at the queueable level (ExtractAddressQueueable is
de-exempt and already carries volume/truncation/governor tests); this change adds no loop
and no per-record query.
```

---

## 10. ONE ITEM FOR THE USER AT THE GATE

The subject prefix wording is the single cosmetic choice in this design:

- **Recommended (default):** `From Muhammad Haris: Gordon Center - Jacksonville FL`
- Alternative, if you want to contradict the "You sent an email" line more forcefully:
  `Received from Muhammad Haris: Gordon Center - Jacksonville FL`

And one expectation to set explicitly: **this change makes the broker's name visible, but the
"You sent an email" line itself will still be wrong.** Removing that line requires the
`EmailMessage` route in §4, which is recommended against for now.
