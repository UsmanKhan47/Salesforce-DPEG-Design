# Design Requirements — Inbound Broker-Email Attachments → Salesforce Files

**Module:** Broker Protection (inbound email-to-Lead pipeline)
**Date:** 2026-08-05 (revised 2026-08-05 after spike + Gate 1)
**Status:** ✅ **GATE 1 APPROVED — BUILD-READY. No unresolved blockers.**
**Conformance:** `ARCHITECTURE.md` §1 (naming), §2 (layering, `SYSTEM_MODE` automation path),
`.claude/rules/apex-layering-rule.md`, `.claude/rules/bulk-test-rule.md` (de-exempted class).
**Evidence base:** `agent-output/spike-attachment-persistence.md` (four in-org spikes, `usman-dpeg`,
2026-08-05; C1 and C3 independently re-verified by the coordinator).

> **What changed in this revision.** Three of the four spikes **removed work**: C3 deleted the
> Content permission-set task (Content is license-gated, not permission-gated); C1 deleted the
> cross-broker sharing fallback (`ViewAllRecords = true` on Lead and Opportunity); F0 deleted an
> entire service class, its selector method and its trigger wiring (the platform already carries
> files to Account, Contact **and** Opportunity on conversion). C2 **changed a recommendation**:
> the `FirstPublishLocationId` shortcut is rejected because it hardcodes `ShareType = 'V'` and
> creates a second, unbudgeted CDL row. Net effect: strictly less code than the pre-spike design.

---

## 0. WHAT THE USER REQUESTED

Capture attachments on inbound broker emails and persist them as Salesforce Files, linked to
the staging row and to every record the routing tree files the email on.

**Explicitly decided by the user; NOT re-opened here:**

| Decision | Value |
| --- | --- |
| Attachment scope | PDF, Office/Excel, image types. Everything else dropped — **but recorded** with a reason. |
| Link shape | ONE `ContentVersion` → `ContentDocument` → N `ContentDocumentLink`. |
| Link timing | Staging row **synchronously in the handler**; routed records in `ExtractAddressQueueable.finish()`, using the SAME ordered target list the N Tasks already use. |
| LLM extraction | **UNCHANGED.** No prompt change, no fixture re-pinning. Persistence only. |

**Approved at Gate 1, 2026-08-05 — settled, do not re-open:**

| Ref | Decision | Consequence |
| --- | --- | --- |
| **A1-a** | **Gate the base64 encode.** The user explicitly accepted that this crosses the "vision path unchanged" boundary, on the reasoning that inputs stay byte-identical below the threshold and this is a **bug fix**, not a behaviour change. | §4.4 step 3. |
| **A2** | `VISION_MAX_BYTES` = **1,000,000**. | §2 A. |
| **G3** | **Allow `.csv`; drop all other `textAttachments`.** A CSV rent roll is real deal data. | §4.8. |
| **B1** | **Accept + record + fix the bounce setting.** The `EmailServicesFunction` failure action is currently **`Discard`** and must become **`Bounce`**, so a rejected oversized email is at least visible to the sender. | §3.5 (Admin, in-org). |

**Explicitly OUT of scope:** any change to the prompt, the extraction contract, the routing
tree's branch logic, the claim/arbitration engine, or the Task-logging contract.

---

## 1. VERIFIED BASELINE (supplied, re-confirmed against the repo)

| # | Fact | Repo confirmation |
| --- | --- | --- |
| 1 | `Email To Lead` has `attachmentOption = All`; the `EmailServicesFunction` file is **not in the repo**. | No `email/` or `emailservices` metadata for it. Org-only truth. |
| 2 | Handler keeps only the FIRST image, base64-encodes it, `break`s, discards everything else. | `EmailToLeadHandler.cls:87-108`. |
| 3 | Staging stores `Has_Image__c` + `Image_Mime_Type__c` only — no bytes. | 19 fields under `objects/Inbound_Email_Staging__c/fields/`; no binary field. |
| 4 | No ContentVersion-**writing** code anywhere. | Only precedent `BrokerAssignmentService.addNote` (ContentNote + CDL, ShareType `'V'`, Savepoint). |
| 5 | Both real staging rows show `Has_Image__c = False`. | — |
| 6 | A custom `InboundEmailHandler` gets **no** automatic attachment saving. | — |
| 7 | 69,440 MB file storage, unused. | — |
| 8 | Email service runs as `junior.dhanani@usmandpeg.uat`. ~~Content-create rights unverified.~~ | **RESOLVED by spike C3 — see §1.2.** |
| 9 | No page layout for `Inbound_Email_Staging__c` in the repo. | Confirmed — no `layouts/Inbound_Email_Staging__c-*`. |

### 1.1 Two things the recon did NOT say

**A `ContentDocumentLinkSelector` ALREADY EXISTS** — `classes/ContentDocumentLinkSelector.cls`,
`with sharing`, `WITH USER_MODE`, one method `selectByLinkedEntityId(Id)`. Its header states
explicitly that **no `Set<Id>` overload was added because no consumer needed one**. That statement
**remains true after this feature** — see §4.3. Do not create a second CDL selector.

**Fact 5 is stronger than it looks.** `Has_Image__c = False` on every real row means the image
path — base64 encode, Queueable payload carry, vision call — **has never executed successfully in
this org.** So "the existing first-image→vision path stays exactly as-is" preserves a code path
that is *unproven in production*, not one that is *working*. This is why **A1-a** was approved, and
why the UAT checklist (§5.1) requires one real image email.

### 1.2 SPIKE-MEASURED FACTS (`usman-dpeg`, 2026-08-05)

| # | Measured | Consequence for this design |
| --- | --- | --- |
| **S1** | `ObjectPermissions` returns **ZERO rows org-wide** for `ContentVersion` / `ContentDocument` / `ContentDocumentLink` / `ContentNote` / `ContentWorkspace`. `FieldPermissions` likewise zero. Content is **license-gated, not permission-set-gated**. `junior.dhanani` is UserType `Standard` on a full **`Salesforce`** license (`LicenseDefinitionKey = SFDC`), and inserted a `ContentVersion` successfully. | **There is nothing to grant.** The Content permission-set task is **deleted** (§3.3). |
| **S2** | `DPEG_Junior_Analyst_PSG` grants **`PermissionsViewAllRecords = true` on BOTH `Lead` and `Opportunity`** — the only two object types this feature ever links to. A plain `with sharing` CDL insert onto any Lead/Opportunity in the org already succeeds. | **The branch-(d) sharing risk does not exist.** The fallback plan is **deleted** (§2 C). |
| **S3** | `ShareType` `'I'` and `'V'` both succeed on `Lead`, `Opportunity` and `Inbound_Email_Staging__c`. `'C'` is rejected everywhere: `INSUFFICIENT_ACCESS_OR_READONLY, Invalid sharing type C`. | ShareType split is confirmed legal — see §2 C. |
| **S4** | `ContentVersion.FirstPublishLocationId` auto-creates **TWO** CDLs — one to the target (`ShareType` hardcoded to **`'V'`**) and one to the creating user's personal library (`'I'`). | **D2 is REJECTED.** It removes ShareType control and adds an unbudgeted row. |
| **S5** | **Every `ContentVersion` insert auto-creates an owner-library CDL**, independent of `FirstPublishLocationId`. | Row arithmetic in §2 D must count it. It is platform-created, not ours. |
| **S6** | On a real `Database.convertLead`, a file linked to the Lead carries natively to **Account, Contact AND Opportunity** (all `ShareType='I'`), and **the Lead's own link is removed**. Zero custom code. | **F-2 is deleted entirely.** F1 resolves to **do nothing** — see §2 F. |

> ⚠ **Two caveats carried forward, both from the spike's own "not fully resolved" section.**
> **(i)** C1/C3's persona-specific results were measured in **test context** (`System.runAs` is a
> hard `@isTest`-only restriction), so they are a **signal corroborated by structural evidence**,
> not a runtime proof. **(ii)** The abstract question "does `without sharing` bypass a *genuine*
> access gap on this org" was **NOT isolated** — every path checked was confounded by
> `ViewAllRecords`. Do not cite this spike as proving that. Both are why §5.1 UAT is mandatory.

> **Out of scope, reported for the RBAC owner only:** `DPEG_Junior_Analyst_PSG` granting blanket
> `ViewAllRecords = true` on Lead / Opportunity / Contact / Onboarding / Transaction / Disposition
> is broader than the "Junior = edit Acq/Disp + view Txn/PM" persona description implies. It is
> precisely what makes C1 a non-issue. **Not a defect of this feature and not fixed here** — raise
> it with whoever owns the RBAC model. If it is ever tightened, re-read §2 C.

---

## 2. THE SIX PROBLEMS

### A. HEAP — the latent bug is real, and it is tighter than 3 MB

Email services run **synchronous** Apex: heap limit **6 MB**. Apex governor `LimitException` is
**not catchable**, so `EmailToLeadHandler`'s `catch (Exception e)` does **not** cover this. A heap
blow-out kills the whole transaction, rolls back the staging insert, and the platform bounces the
email — **no staging row, no Lead, no claim, no audit trail. The email is simply gone.**

#### Arithmetic

`EncodingUtil.base64Encode(att.body)` holds the source Blob (S bytes) **and** the encoded string
(`ceil(S/3) × 4` characters) simultaneously.

| String cost assumption | Peak from the encode alone | Crossing point |
| --- | --- | --- |
| 1 byte/char (base64 is ASCII — optimistic floor) | `S + 1.333S = 2.333S` | fails above **≈ 2.45 MB** |
| 2 bytes/char (UTF-16 internal — pessimistic) | `S + 2.667S = 3.667S` | fails above **≈ 1.63 MB** |

**The true threshold is between 1.6 MB and 2.5 MB — an ordinary phone photo of a property.** The
premise of "~3 MB" is optimistic.

#### The insight that changes the shape of the fix

The `Messaging.InboundEmail` object the platform hands the method **already holds every attachment
Blob in heap before the first line of our code runs.** So:

- `ContentVersion.VersionData = att.body` assigns a **reference to a Blob already resident**. It
  costs ≈ 0 additional heap. **Persisting files is not the heap risk.**
- A per-file or per-email byte cap on *retention* therefore **does not protect heap**. Saying it
  does would be a false sense of safety.
- The **only** heap lever available to this code is the base64 encode — i.e. the one path the user
  asked to leave alone.

#### Proposed guards (concrete numbers, all named constants)

| Constant | Value | What it actually buys |
| --- | --- | --- |
| `VISION_MAX_BYTES` | **1,000,000** | The real heap fix. Worst case `1.0 MB + 2.67 MB = 3.67 MB`, leaving 2.3 MB for the other blobs + body. At 750,000 it is `2.75 MB` / 3.25 MB free — pick one at Gate 1. Above the cap the image is **not** sent to the LLM and the skip is recorded. OpenAI downsamples to ≤ ~2000 px regardless, so 1 MB is ample. |
| `ATTACHMENT_MAX_BYTES` | **5,000,000** | Belt-and-braces per file. Should never fire — the email service rejects larger attachments upstream — but bounds the pathological case. |
| `MAX_ATTACHMENTS` | **10** | Count cap, mirroring `MAX_PROPERTIES = 10`. Bounds CDL rows at `10 files × 10 records = 100`. Overflow is **recorded, not silent** — same philosophy as the `[truncated: 10 of M]` suffix. |
| `HEAP_HEADROOM_FLOOR` | **4,000,000** | The only *dynamic* guard. Before each retention, if `Limits.getHeapSize() > 4,000,000`, stop retaining and record the remainder as dropped for `heap headroom`. This is the guard that reflects reality rather than a guess. |

> **✅ DECISION A1 — RESOLVED: A1-a, gate the encode.** Approved at Gate 1. The user explicitly
> accepted that this crosses the "vision path unchanged" boundary, on the reasoning that the vision
> call's *inputs are byte-identical for every image under the threshold* and that this is a **bug
> fix**, not a behaviour change. Above the threshold the image is **skipped and the skip is
> recorded**, rather than crashing the handler and losing the email.
> **✅ DECISION A2 — RESOLVED: `VISION_MAX_BYTES` = 1,000,000.**
>
> No prompt change, no extraction-contract change, no fixture re-pinning — the §0 boundary holds.
> The only observable difference is that an image over 1 MB is no longer sent, and
> `Dropped_Attachment_Notes__c` says so.

---

### B. SIZE vs BUSINESS VALUE — a real operational risk this feature cannot fix

#### What happens today to an oversized email

The rejection happens **at the email service, before Apex runs.** Consequently:

- `handleInboundEmail` is never invoked.
- **No `Inbound_Email_Staging__c` row is written.** The pipeline has no record the email existed.
- No Lead, no `Property_Registry__c` claim, no `Competing_Broker_Submission__c`, no Task.
- **The broker's first-come-first-served protection silently does not happen.** If a second broker
  later submits the same property with a smaller email, they win it outright.
- The only signal is a bounce (or a discard) to **DPEG's forwarding coordinator** — outside
  Salesforce entirely. Nobody looking at Salesforce can tell the difference between "no broker sent
  this" and "a broker sent this and it was rejected".

This is the same failure shape the `SENDER_CONTAINS` comment in `ExtractAddressQueueable` calls out
as unacceptable — *"a false positive here is a broker's LOST CLAIM, and the only signal that it
happened would be the broker telling us months later"* — except this one is imposed by the
platform, not by our filter.

#### Why it bites this pipeline specifically

Commercial-real-estate offering memoranda are routinely 10–50 MB. **This is not an edge case; it is
the normal shape of the highest-value email the module exists to capture.**

#### What the design CAN do

1. **Nothing in Apex.** State that plainly rather than implying a code fix exists.
2. **Change the email service's failure action from `Discard` to `Bounce`.** ✅ **Approved (B1).**
   It is currently **`Discard`** — the worst possible value here, because a rejected email then
   vanishes with **no notice to anyone, inside or outside Salesforce**. `Bounce` at least tells the
   forwarding coordinator, which is the only human in the loop who can act. **The
   `EmailServicesFunction` is NOT in the repo** (fact 1), so this is an **in-org Admin change**, not
   a deploy — see §3.5. Confirm the actual size ceilings while there; the "~5 MB / ~10 MB" figures
   are approximations and **must not be hard-coded anywhere in Apex**.
3. **Operational runbook (Admin/user process, not code):** when a bounce arrives, the coordinator
   re-forwards **with the attachment stripped or replaced by a link**. The claim is then taken
   correctly and only the file is missing — a recoverable failure instead of an unrecoverable one.
   This is the placeholder-vs-recoverable-failure principle: prefer the loss you can see.

#### What the design CANNOT do, and one way it makes things slightly worse

Once files appear on Lead and Opportunity records, **users will reasonably assume "no file = the
broker sent no file."** That inference is wrong for every bounced email. The design should therefore
make the *retained* file set explicit on the staging row (`Attachment_Count__c`,
`Dropped_Attachment_Notes__c`) so "we kept none, and here is why" is always answerable — but nothing
can make a bounced email visible, because no row is ever created for it.

> **✅ DECISION B1 — RESOLVED: accept + record + fix the bounce setting.** Approved at Gate 1.
> The residual is accepted and documented; the `Discard` → `Bounce` change is the one concrete
> mitigation and is now an Admin task (§3.5). Oversized-OM handling (e.g. a coordinator-side
> link-extraction path) is **not** in this change — raise it separately if it recurs.
>
> 🚩 **FLAGGED, NOT FIXED — item 2 of 2.** This claim-loss path exists today, is unchanged by this
> feature, and is **not fixable in Apex**. Retained here deliberately so it is not mistaken for
> something this change addresses. See also §7.

---

### C. SHARING ON `ContentDocumentLink` INSERT

**✅ RESOLVED BY SPIKE — THE RISK DOES NOT EXIST AS SCOPED.**

A CDL insert does enforce access to the `LinkedEntityId` record. The design worried about **a
different broker's winning Lead on the competing-submission branch (branch d)**. Measured (S2):
`DPEG_Junior_Analyst_PSG` grants **`PermissionsViewAllRecords = true` on both `Lead` and
`Opportunity`** — and those are the **only two object types `orderedTaskTargets()` can ever
produce**. A plain `with sharing` CDL insert onto any Lead or Opportunity in the org, owned by
anyone, already succeeds today.

**The staging link is governed by ownership, not sharing:** it targets the row
`InboundEmailStagingService` created *microseconds earlier in the same transaction*, which the
running user owns by construction. `Broker_Protection_Access` having `viewAllRecords = false` on
`Inbound_Email_Staging__c` is therefore irrelevant to this path.

**🗑 The fallback plan is DELETED.** "Link only to the staging row and the winner's own Lead" is not
needed and must not be built.

#### The Task-precedent note is retained, because it is still true

`InboundEmailActivityService` is `with sharing` and does a plain `insert` — Task DML performs no
sharing check on the referenced `WhoId`/`WhatId`. **A CDL insert is a different mechanism with a real
access check on the linked entity.** Do not reason "the Tasks work, so the links will." That
reasoning is invalid; it merely happens not to matter here because of S2.

#### Approach

1. **`InboundEmailAttachmentService` is `without sharing` — as FUTURE-PROOFING ONLY.** It costs
   nothing and matches the `EmailThreadGuardService` / `EmailThreadAdopterService` precedent in this
   same module. **🔴 The class header must say plainly that it mitigates no present risk**, and must
   record the spike's own caveat: the abstract question *"does `without sharing` bypass a genuine
   access gap on this org?"* was **NOT independently isolated** — every path probed was confounded by
   `ViewAllRecords`, so both the `with sharing` and `without sharing` probes succeeded for the same
   reason. Required header wording, in substance:
   > *`without sharing` is defensive, not load-bearing. As of 2026-08-05 every target type
   > (`Lead`, `Opportunity`) is already fully visible to the Email Service user via
   > `DPEG_Junior_Analyst_PSG`'s `ViewAllRecords`, so `with sharing` would work identically today.
   > This declaration exists so that a future tightening of the RBAC model, or a new record type
   > entering `orderedTaskTargets()`, does not silently start dropping links. It has NOT been proven
   > to bypass a genuine access gap in this org — that experiment was confounded and is unrun.*
2. **`Database.insert(links, false)`** — one bulk statement, `allOrNone = false`. A refused link must
   never cost the other links, the staging link, the Task insert, or the claim.
3. **Refusals are RECORDED, not just logged.** This is the **R1 lesson** from the EAC adopter,
   written into `ARCHITECTURE.md`: a fail-soft write whose entire failure surface is
   `allOrNone = false` plus a `System.debug` produces **zero writes and no durable signal** — no
   exception, no failed job, nothing queryable. Append every refusal (record Id + StatusCode) to
   `Dropped_Attachment_Notes__c` on the staging row so "0 links across a period in which real emails
   arrived" is distinguishable from "nothing needed linking".
4. **`ShareType` per target — final, see C2 below.**

#### ✅ DECISION C2 — RESOLVED. Final `ShareType` per link target

| Link target | `ShareType` | `Visibility` | Why |
| --- | --- | --- | --- |
| Routed **`Lead`** / **`Opportunity`** | **`'I'`** (Inferred) | `AllUsers` | File access follows the record's own sharing — whoever can work the deal can read the OM. It is also **what the platform itself produces**: S6 measured all three post-conversion links as `'I'`, so our Lead link and the platform's carry-over agree rather than diverge. |
| **`Inbound_Email_Staging__c`** | **`'V'`** (Viewer) | `AllUsers` | The staging row is **evidence**. `Broker_Protection_Access` grants `allowEdit = true` on it, and under `'I'` an edit grant on the record confers **Collaborator** on the file — i.e. the right to replace or delete the broker's own submission from an audit row. `'V'` grants read and nothing more. This is a deliberate divergence from the routed-record choice, not an inconsistency. |
| `'C'` (Collaborator) | **never** | — | Measured rejected everywhere: `INSUFFICIENT_ACCESS_OR_READONLY, Invalid sharing type C`. |

Both `'I'` and `'V'` were measured legal on all three object types (S3), so nothing here is
speculative.

> **✅ DECISION C1 — RESOLVED: no fallback needed.** See the top of this section. Downgraded from
> blocking spike to closed.
> **✅ DECISION C3 — RESOLVED: nothing to grant.** Content is license-gated, not
> permission-set-gated (S1). The Email Service user holds a full `Salesforce` license and inserted a
> `ContentVersion` successfully. **§3.3's permission-set task is deleted.**

---

### D. GOVERNOR BUDGET

#### Current test-pinned budgets (`ExtractAddressQueueableTest`)

| Scenario | SOQL | DML |
| --- | --- | --- |
| Single property | `singlePropertyQueryBudget = 30` | `singlePropertyDmlBudget = 20` |
| 10 properties | `QUERY_BUDGET = 120` | `DML_BUDGET = 60` |

#### What the feature adds

**Handler (synchronous — separate limits: 100 SOQL / 150 DML; currently 0 SOQL / 1 DML):**

| Step | Cost |
| --- | --- |
| `insert contentVersions` (1 statement, F rows) | +1 DML |
| Re-query `ContentVersion` → `ContentDocumentId` (null on the inserted sObject) | +1 SOQL |
| `insert` staging CDLs (1 statement, F rows) | +1 DML |

→ Handler totals **1 SOQL / 3 DML** (staging insert + ContentVersion insert + CDL insert). Constant
regardless of file count, against caps of 100 / 150. Ample headroom.

> **🗑 ✅ DECISION D2 — RESOLVED: REJECT the `FirstPublishLocationId` shortcut.** The pre-spike
> design recommended it to save one DML in the heap-critical synchronous path. **Measured (S4), it
> fails on two counts:** it **hardcodes the target link's `ShareType` to `'V'`**, destroying the
> per-target choice C2 just made for routed records and for the staging row alike; and it creates
> **TWO** CDLs, not one — the second being an owner-personal-library link the row arithmetic never
> budgeted. It saves one statement and costs control of the security model. Use an **explicit
> `ContentDocumentLink` insert** instead, which is what the C2 table assumes.

> **⚠ S5 — every `ContentVersion` insert creates an owner-library CDL anyway**, independently of
> `FirstPublishLocationId`. It is platform-created, ours to count but not to control, and it is
> included in the row arithmetic below. Do not "clean it up".

**Queueable `finish()`:**

| Approach | SOQL | DML |
| --- | --- | --- |
| (i) re-read the docs via `ContentDocumentLinkSelector.selectByLinkedEntityId(stagingId)` | +1 (constant, not per-property) | +1 |
| **(ii) ✅ DECISION D1 — ADOPTED** — carry `List<Id> contentDocumentIds` on the Queueable constructor (it already carries `imageBase64` / `imageMimeType`) | **+0** | **+1** |

Option (ii) is a handful of 18-char Ids on a payload that already carries a base64 image. It costs
nothing, keeps the query budget **completely unchanged**, and leaves `ContentDocumentLinkSelector`
untouched (§4.3).

#### ✅ FINAL BUDGETS TO PIN — exact numbers, stated as deltas, never re-baselined

| Scenario | SOQL | DML | Why |
| --- | --- | --- | --- |
| **`ExtractAddressQueueable`, single property** | **30** — *unchanged* | **21** *(was 20)* | exactly one bulk CDL statement |
| **`ExtractAddressQueueable`, 10 properties** | **120** — *unchanged* | **61** *(was 60)* | the same one statement — **it must not scale with N** |
| **`EmailToLeadHandler`** (synchronous, previously unpinned) | **1** *(was 0)* | **3** *(was 1)* | caps are 100 / 150 |

**Query budgets do not move at all.** Any test failure on a query budget means someone reverted D1
and reintroduced the re-query — fix that, do not raise the number.

**The highest-value assertion is that the DML delta is `+1` at N=1 AND at N=10.** That makes a
future per-property or per-file CDL insert fail *here* rather than in production. Per
`.claude/rules/bulk-test-rule.md`, this class is **de-exempted** from the 251 rule — volume tests
replace it. The test comment must say **why** the budget moved, so a later reader does not read it
as drift.

**Row arithmetic (worst case, `MAX_ATTACHMENTS = 10` files × `MAX_PROPERTIES = 10` records):**

| Rows | Source | Count |
| --- | --- | --- |
| Owner-library CDLs | **platform** (S5, one per `ContentVersion`) | 10 |
| Staging CDLs | ours, handler | 10 |
| Routed-record CDLs | ours, `finish()` | 10 × 10 = 100 |
| **Total** | | **120** rows against a 10,000-row cap |

Non-issue — but note the platform's 10 are **not** in our DML statements and must not be asserted
against as if they were.

---

### E. IDEMPOTENCY — duplicates are created, and it does not matter, for a structural reason

**Determination:** a platform redelivery **does** create duplicate `ContentVersion`s. It **does
not** create duplicate files on any business record.

The chain, from the code:

1. `createStaging` inserts unconditionally → a redelivery yields a **second staging row**. This is
   already true today for `Raw_Body__c` / `Raw_Headers__c`; file duplication is exactly parallel to
   body duplication that already exists. **No new failure class.**
2. New ContentVersions + CDLs are written against **that new staging row**.
3. `ExtractAddressQueueable.execute` reaches
   `if (InboundEmailActivityService.isAlreadyLogged(...)) { markSkipped(...); return; }` —
   **it returns WITHOUT calling `finish()`** (`ExtractAddressQueueable.cls:638-641`).
4. Routed-record CDLs are created **only inside `finish()`**. They are therefore never reached on a
   redelivery.

**Net cost:** one orphaned duplicate `ContentDocument` per redelivery, on a duplicate staging row,
against 69,440 MB of unused storage (fact 7).

> **✅ DECISION E1 — RESOLVED: NO DEDUPE.** Add none. A content hash or a custom External Id on
> `ContentVersion` would buy nothing (the duplicates never reach a business record) and would cost a
> per-file query — the exact per-file cost the §2 D budget exists to prevent.

> ⚠ **The load-bearing dependency to write into the class header:** this conclusion holds *only*
> because the duplicate-delivery branch returns before `finish()`. Anyone who later moves file
> linking out of `finish()`, or makes the skip path call `finish()`, silently re-opens duplicate
> files on live Leads. Note it where it can be found.

---

### F. LEAD CONVERSION CARRY-OVER

### ✅ DECISION F1 — RESOLVED: **F-1, DO NOTHING. The platform already does it.**

**Measured (S6), at runtime, via a real `Database.convertLead`** — not in a unit test, and with this
org's real `Property_And_Email_Required_To_Convert` validation rule firing correctly along the way,
which is itself independent evidence the execution was genuine and not degraded:

```
F0_POSTCONVERT_CDL_COUNT=4
  LinkedEntityId=001…  Type=Account       ShareType=I
  LinkedEntityId=003…  Type=Contact       ShareType=I
  LinkedEntityId=006…  Type=Opportunity   ShareType=I
  LinkedEntityId=005…  Type=User          ShareType=I   (owner library, pre-existing)
```

**A file linked to a Lead carries natively to Account, Contact AND Opportunity, with zero custom
code — and the Lead's own link is REMOVED.**

#### What this falsifies

The pre-spike design rejected F-1 on the premise that files might reach only the Contact, invoking
`ARCHITECTURE.md`'s *"one Contact fronts many deals"*. **That premise is empirically false on this
org.** The reasoning was sound; the fact it rested on was wrong. The file reaches the Opportunity —
the deal — by itself.

| Option | Status |
| --- | --- |
| **F-1 — do nothing** | ✅ **ADOPTED.** |
| F-2 — `LeadFileCarryOverService` | 🗑 **DELETED.** Pure redundant work, and *worse than redundant*: without a pre-check it would insert a **second** link the platform already created. §4.7 is removed. |
| F-3 — fold into `LeadConvertService` | Still correctly rejected, on separation-of-concerns grounds, independently of this finding. |
| F-4 — defer | 🗑 Moot, and its stated rationale was also wrong: files do **not** "sit on the Lead" — the Lead link is removed at conversion. |

#### Consequences to state explicitly, so nobody re-opens this

- **`LeadConvertService`'s documented `2 SOQL / 3 DML` contract is UNTOUCHED by this feature.** No
  new selector call, no new DML, no new trigger wiring, no amendment to its class header.
- **`LeadConvertTrigger` is not modified.**
- **`ContentDocumentLinkSelector` gains no `Set<Id>` overload** — its header's stated reason for not
  having one remains true (§4.3).
- **No new service class is created for conversion.** `LeadFileCarryOverService` does not exist and
  must not be built.

> ⚠ **CAVEAT — CARRY THIS TO UAT (§5.1), DO NOT TREAT AS SETTLED FOREVER.** S6 was measured at
> runtime in an admin session. This repo has **two independently measured precedents of platform DML
> behaving differently by context** — `EmailMessage.RelatedToId` (commits at runtime, refused in
> `@isTest`) and a Lead lookup to a converted Lead (throws at runtime, unenforced in `@isTest`).
> Content and conversion DML are the same family. **Record F0 as measured-at-runtime and
> to-be-reconfirmed-at-UAT**, and treat a future Salesforce release or an org setting change as
> capable of altering it. If UAT contradicts S6, F-2 comes back — but as an **idempotent
> verification/repair** step that checks for the platform's own link first, which is materially
> smaller and different code from what §4.7 originally described.

---

## 3. 🔵 ADMIN WORK (`salesforce-admin`)

### 3.1 New fields on `Inbound_Email_Staging__c`

| API name | Type | Notes |
| --- | --- | --- |
| `Attachment_Count__c` | Number(3, 0) | Files **retained**. Rule 9 `_Count__c` suffix. |
| `Dropped_Attachment_Notes__c` | Long Text Area (32,768) | One line per dropped item: `filename \| mime \| bytes \| reason`. Also carries CDL refusals (decision C, point 3). |
| `Attachment_Bytes__c` | Number(12, 0) | Total retained bytes. **✅ DECISION H1 — RESOLVED: yes, build it.** It is what makes the §2 B size risk *reportable* — without it there is no way to ask "how close are our real emails to the ceiling?" before a broker's claim is lost. |

**All three are required. Three fields, no more.**

> **⚠ NAMING — an ARCHITECTURE §1 trap that was caught and avoided.** The obvious name
> `Attachments_Dropped__c` **must not be used.** ARCHITECTURE §1 rule 4 defines
> `<Subject>_<PastParticiple>` as a **Boolean** form (`LOI_Signed__c`, `PSA_Executed__c`), so a Long
> Text Area with that name asserts a type it does not have — precisely rule 9's hard prohibition 2,
> the one that produced the `Unit__c` MasterDetail-vs-Text defect. `Dropped_Attachment_Notes__c`
> follows the existing `Deal_Notes__c` precedent instead.

### 3.2 FLS for the three new fields — REQUIRED

**Grant read + edit on `Broker_Protection_Access`** — all 19 sibling `Inbound_Email_Staging__c`
field permissions already live there. (Standing rule: *grant FLS where the SIBLING fields live, not
where the feature lives*. Here they coincide — verified against the file, not assumed.)

> ⚠ **This is unrelated to C3 and is NOT removed by it.** C3 says the *Content objects* need no
> grant. These three are **custom fields on a custom object** and follow the ordinary rule: a
> Metadata-API-deployed field arrives with **no FLS for anybody**, so without this step the values
> are written correctly and are invisible to every human.

**Also update the XML comment block in `Broker_Protection_Access.permissionset-meta.xml`.** It
carries the post-deploy verification query and the expected per-object counts:

```
Inbound_Email_Staging__c 19  →  22
```

That comment is operationally load-bearing — a stale count makes the verification query useless.
**Do not put this note in `<description>`** (255-char cap; it has already made this file
undeployable once) and **keep any XML comment inside the root element** (a comment above the root
breaks `sf` deploy with a misleading "unable to find matching parent xml file").

### 3.3 ~~Content object permissions~~ — 🗑 **DELETED. NOTHING TO DO.**

**✅ Resolved by spike C3/S1.** `ObjectPermissions` returns **zero rows org-wide** for
`ContentVersion` / `ContentDocument` / `ContentDocumentLink` / `ContentNote` / `ContentWorkspace`,
and `FieldPermissions` likewise. Basic Salesforce Files access is **license-gated, not
permission-set-gated**; `junior.dhanani@usmandpeg.uat` holds a full **`Salesforce`** license
(`LicenseDefinitionKey = SFDC`, UserType `Standard`) and inserted a `ContentVersion` successfully.

**There is no permission to grant, so no permission-set change is made for Content.** Do not add
speculative `<objectPermissions>` for these objects — they would be meaningless entries in a file
whose count comment is used for verification.

### 3.4 Layout / related list (fact 9)

`Inbound_Email_Staging__c` uses the org default layout — **no layout exists in the repo.** Verify
in-org whether the **Files** related list is present; if not, author and deploy the layout. Also add
the three new fields, or they are invisible even with FLS granted.

### 3.5 Email service failure action: `Discard` → `Bounce` — ✅ APPROVED (B1)

**In-org change to the `Email To Lead` `EmailServicesFunction`.** The failure/over-limit action is
currently **`Discard`**; set it to **`Bounce`** so a rejected oversized email is at least visible to
the sender. While there, record the actual attachment/message size ceilings for the runbook.

> 🔴 **This file is NOT in the repo and must stay that way.** Do **not** retrieve-and-commit the
> `EmailServicesFunction` as a side effect. It is an in-org configuration change, verified in-org.
> The repo carries no record of it, so note the change in the deployment log instead.

### 3.6 Explicitly NOT included

No validation rules, no new permission sets, no flows, no reports, no list views, no Content object
permissions — none were requested or are required.

---

## 4. 🟢 DEVELOPMENT WORK (`salesforce-developer`)

Layering per `.claude/rules/apex-layering-rule.md`: **all SOQL in a selector, the service owns the
DML, the handler marshals only.**

### 4.0 FILE-BY-FILE WORK LIST

| # | File | New / Modified | Layer |
| --- | --- | --- | --- |
| 4.1 | `classes/InboundEmailAttachmentService.cls` (+ `.cls-meta.xml`) | **NEW** | Service |
| 4.2 | `classes/ContentVersionSelector.cls` (+ `.cls-meta.xml`) | **NEW** | Selector |
| 4.3 | `classes/ContentDocumentLinkSelector.cls` | **UNTOUCHED** | — |
| 4.4 | `classes/EmailToLeadHandler.cls` | MODIFIED | Boundary |
| 4.5 | `classes/ExtractAddressQueueable.cls` | MODIFIED | Queueable orchestrator |
| 4.6 | `classes/InboundEmailStagingService.cls` | MODIFIED | Service |
| 4.7 | ~~`LeadFileCarryOverService`~~ | 🗑 **NOT BUILT** | — |
| 4.9 | `classes/InboundEmailAttachmentServiceTest.cls` | **NEW** | Test |
| 4.9 | `classes/ExtractAddressQueueableTest.cls`, `EmailToLeadHandlerTest.cls` | MODIFIED | Test |

**Not modified, and deliberately so:** `LeadConvertService`, `LeadConvertTrigger`,
`InboundEmailActivityService`, `LLMExtractionCalloutService`, `PropertyClaimService`,
`PropertyMatchingService`, `InboundEmailFieldUtil`, and every LLM prompt/fixture.

### 4.1 `InboundEmailAttachmentService` (NEW — Service, `without sharing`)

The **only** class in the app that writes `ContentVersion` or `ContentDocumentLink` for this module.
Add it to the `ARCHITECTURE.md` §2 Key Apex Services table **in the same PR** (§6 requirement).

`without sharing` is **future-proofing only** — see §2 C point 1 for the exact header wording
required, including the statement that the abstract bypass was never isolated.

#### Constants (final values)

| Constant | Value | Purpose |
| --- | --- | --- |
| `VISION_MAX_BYTES` | `1000000` | ✅ A2. Above this, no base64, no vision — recorded as dropped-for-vision. Lives on the **handler** (§4.4), not here. |
| `ATTACHMENT_MAX_BYTES` | `5000000` | Per-file retention ceiling. Should never fire; bounds the pathological case. |
| `MAX_ATTACHMENTS` | `10` | Per-email count cap, mirroring `MAX_PROPERTIES`. Overflow recorded, never silent. |
| `HEAP_HEADROOM_FLOOR` | `4000000` | Dynamic guard: stop retaining once `Limits.getHeapSize()` exceeds this. |
| `IMAGE_MIN_BYTES` | `20000` | ✅ G2. Signature-logo floor; applies to **images only**. |
| `LEN_DROPPED_NOTES` | `32768` | `Dropped_Attachment_Notes__c` length. |
| `SHARE_TYPE_INFERRED` | `'I'` | Routed Lead / Opportunity links (C2). |
| `SHARE_TYPE_VIEWER` | `'V'` | Staging link (C2). |
| `VISIBILITY_ALL_USERS` | `'AllUsers'` | Both. |
| `ALLOWED_EXTENSIONS` | `pdf, doc, docx, xls, xlsx, ppt, pptx, csv, png, jpg, jpeg, gif, webp, tif, tiff` | ✅ G1/G3. |
| `ALLOWED_MIME_SUBTYPES` | the MIME equivalents of the above | ✅ G1 — matched as a **union** with the extension, never alone. |

#### Signatures

```
public class AttachmentRequest {
    public String  fileName;
    public String  mimeSubType;
    public Blob    body;         // binaryAttachments
    public String  textBody;     // textAttachments (.csv only)
    public Integer byteSize;
    public Boolean isImage;
}

public class ClassificationResult {
    public List<AttachmentRequest> retained;
    public String  droppedNotes;      // newline-joined, clipped to LEN_DROPPED_NOTES
    public Integer retainedCount;
    public Integer retainedBytes;
}

public static ClassificationResult classify(List<AttachmentRequest> candidates)
    // PURE. No SOQL, no DML, no Blob copies. Applies G1/G2/G3 + all four caps.

public static List<Id> persist(Id stagingId, List<AttachmentRequest> retained)
    // 1 SOQL (ContentVersionSelector) + 2 DML. Returns ContentDocumentIds.
    // 🔴 MUST NOT THROW — see the boundary note in §4.4.

public static Integer linkTo(List<Id> contentDocumentIds, List<Id> recordIds)
    // EXACTLY 1 DML: Database.insert(links, false). Returns links created.
    // 🔴 MUST NEVER be called per property or per file.

@TestVisible private static List<String> lastRunLinkFailures;
    // In-transaction only, for tests/debugging — NOT monitoring (the R1 lesson).
```

Refusals from `linkTo` are appended to `Dropped_Attachment_Notes__c` via
`InboundEmailStagingService.appendDroppedNote` (§4.6) — **failure path only**, so it sits outside the
pinned success-path budget.

### 4.2 `ContentVersionSelector` (NEW — Selector)

The **first `ContentVersion` SOQL in the application** — every future ContentVersion read belongs
here. Same framing as `AccountSelector` (2026-08-02) and `OpportunityContactRoleSelector`
(2026-08-03).

- **One method only:** `public static List<ContentVersion> selectByIds(Set<Id> ids)` — selecting
  `Id, ContentDocumentId`. Null/empty input short-circuits to an empty list.
- **`WITH SYSTEM_MODE`**, justified at the declaration per ARCHITECTURE §2. This is a textbook
  automation-path read: the Email Service user is on `Minimum Access`, `USER_MODE` **throws rather
  than degrades**, and a throw here kills the handler and **loses the email** (currently to
  `Discard`). Same reasoning as the EAC capture pipeline and `LeadSelector.GuestReads`.
- `with sharing` on the class (SYSTEM_MODE lifts FLS/CRUD only, never sharing — state this).
- Add the method to the ARCHITECTURE §2 automation-path table, taking the repo from **16 → 17**
  `SYSTEM_MODE` queries across **11 → 12** selector classes. That table is a record of decisions,
  not a closed list; the authoritative inventory is the class header.

### 4.3 `ContentDocumentLinkSelector` — 🗑 **UNTOUCHED. NO CHANGE.**

The pre-spike design added `selectByLinkedEntityIds(Set<Id>)` for `LeadFileCarryOverService`. **F0
deleted that service, and D1 (carry the Ids on the constructor) means the queueable never queries
CDLs either.** Nothing in this feature reads `ContentDocumentLink`.

**Consequence: the existing class-header paragraph — "no `Set<Id>` overload is added because no
consumer queries links for many parents at once" — REMAINS TRUE and must NOT be edited.** Leave the
file alone entirely.

### 4.4 `EmailToLeadHandler` (MODIFY — marshalling only)

Order matters and is load-bearing:

1. Marshal `email.binaryAttachments` **and** `email.textAttachments` into `AttachmentRequest` DTOs
   (references, **no Blob copies**).
2. `InboundEmailAttachmentService.classify(...)` → retained + dropped notes + counts.
3. **Size-gated base64** of the first **retained** image (✅ A1-a / A2). The candidate is chosen from
   the *retained* list — never by re-scanning `email.binaryAttachments` — so the `IMAGE_MIN_BYTES`
   floor and the type filter both apply to it. Skip and record when `byteSize > VISION_MAX_BYTES`.
4. `InboundEmailStagingService.createStaging(request)` — now carrying `attachmentCount`,
   `attachmentBytes`, `droppedNotes`.
5. `InboundEmailAttachmentService.persist(stagingId, retained)` → `contentDocumentIds`.
6. `System.enqueueJob(new ExtractAddressQueueable(stagingId, imageBase64, imageMimeType, contentDocumentIds))`.

`VISION_MAX_BYTES` lives here, next to the encode it gates.

> 🔴 **THE FAILURE BOUNDARY — THE MOST IMPORTANT RULE IN THIS FILE.** `handleInboundEmail`'s
> `catch (Exception e)` sets `result.success = false`, and the platform then applies the email
> service's failure action — **which is `Discard` today (§3.5)**. So **any exception escaping step 5
> silently destroys a valid broker email.** Therefore:
> - `persist(...)` must wrap its own DML in `try/catch` and **never throw**. A file that cannot be
>   saved is recorded in `Dropped_Attachment_Notes__c`; it is never allowed to cost the email.
> - `Database.insert(versions, false)` — never all-or-none. One malformed file must not take the
>   other nine, nor the staging row, nor the Lead, nor the claim.
> - This rule holds **even after** the `Discard` → `Bounce` change. Bounce is better than Discard;
>   neither is acceptable for a file problem.

> ⚠ **Do not claim step 4-before-5 protects the staging row from a heap death.** It does not — an
> uncatchable `LimitException` rolls back the entire transaction including the insert. The ordering
> is correct for *ordinary* failures; the **only** protection against heap is the gate in step 3.

### 4.5 `ExtractAddressQueueable` (MODIFY — minimal)

- Constructor gains a 4th argument: `ExtractAddressQueueable(Id stagingId, String imageBase64,
  String imageMimeType, List<Id> contentDocumentIds)` (✅ D1). Held as a `private final` member
  alongside the existing three.
- `finish()` computes `orderedTaskTargets()` **ONCE** into a local, passes it to
  `InboundEmailActivityService.logInboundEmail(...)` **and** to
  `InboundEmailAttachmentService.linkTo(contentDocumentIds, targets)` — **the SAME ordered list**,
  per the user's decision. Do not call `orderedTaskTargets()` twice.
- Guard: skip `linkTo` entirely when `contentDocumentIds` is null/empty **or** `targets` is empty, so
  a no-attachment email spends **zero** DML and the compatibility test (§4.9 #3) holds.
- **The class keeps its invariant of holding NO SOQL and NO DML of its own.** Its header states this
  explicitly. Every write goes through the owning service.
- Add one paragraph to the class header covering the **E** dependency: the duplicate-delivery branch
  returns before `finish()`, and that is the *only* reason redelivery cannot duplicate files on live
  records. Anyone moving file linking out of `finish()`, or making the skip path call `finish()`,
  re-opens it.

### 4.6 `InboundEmailStagingService` (MODIFY)

- `StagingRequest` gains `Integer attachmentCount`, `Integer attachmentBytes`, `String droppedNotes`.
- `createStaging` stamps `Attachment_Count__c`, `Attachment_Bytes__c`,
  `Dropped_Attachment_Notes__c` — every string through `InboundEmailFieldUtil.clip`.
- **NEW:** `public static void appendDroppedNote(Id stagingId, String note)` — read-then-append
  (1 SOQL + 1 DML), **fail-soft**, swallowing its own `DmlException` exactly like `storeExtractedJson`
  and the `mark*` methods. **Failure path only**, so it is outside the pinned success-path budget;
  say so in its Javadoc or a future reader will read the budget as violated.

### 4.7 ~~`LeadFileCarryOverService`~~ — 🗑 **DELETED. DO NOT BUILD.**

**✅ Resolved by spike F0/S6:** the platform already carries Lead files to Account, Contact **and**
Opportunity on `Database.convertLead`. Building this would be redundant at best and would insert a
**duplicate** link at worst. See §2 F for the measurement and the UAT caveat.

**`LeadConvertService`'s `2 SOQL / 3 DML` contract is untouched. `LeadConvertTrigger` is untouched.**

### 4.8 The MIME / extension allow-list

> **✅ DECISION G1 — RESOLVED: UNION of MIME and extension.** Keep the file if **EITHER** the
> normalized MIME subtype **OR** the filename extension is in the allow-list. A MIME-only filter is
> rejected: `EmailToLeadHandler.cls:89-93` already shows `mimeTypeSubType` arriving inconsistently
> (bare `'png'` vs qualified `'image/png'`), and **forwarded attachments routinely arrive as
> `application/octet-stream`** — a MIME-only list would drop the OM, the exact silent loss this
> feature exists to prevent.
>
> Final set: `pdf`, `doc`, `docx`, `xls`, `xlsx`, `ppt`, `pptx`, **`csv`**, `png`, `jpg`, `jpeg`,
> `gif`, `webp`, `tif`, `tiff`.
>
> **✅ DECISION G2 — RESOLVED: `IMAGE_MIN_BYTES` = 20,000, images only.** The user's two rules
> ("keep images" / "drop signature logos") need a discriminator, and a size floor is the one that
> works without unverified platform surface: a property photo or OM render is far above 20 KB, a
> logo far below. The `Content-Disposition: inline` / `Content-ID` alternative is **not adopted** —
> it depends on `Messaging.InboundEmail.BinaryAttachment.headers` being populated at API 67, which
> was never verified, and designing around an unverified property is how the `Task.Type` outage
> happened. Every drop is **recorded**.
>
> **✅ DECISION G3 — RESOLVED: allow `.csv`, drop all other `textAttachments`.** Approved at Gate 1
> — a CSV rent roll is real deal data. Everything else in `textAttachments` (vCards, calendar
> invites, plain-text signatures) is dropped **and recorded**. `.csv` arrives as a `String`, so it is
> converted with `Blob.valueOf(...)` for `VersionData`; note this is the one retention path that
> **does** allocate new heap, and it is bounded by `ATTACHMENT_MAX_BYTES`.
>
> 🚩 **FLAGGED, NOT FIXED — item 1 of 2. The first image may be a signature logo.** The existing
> vision path takes the **FIRST image in list order**, so the LLM may be reading a company logo
> instead of the offering flyer. Fact 5 means this has never actually run in production, so it is
> unproven either way. It sits inside the "LLM extraction is UNCHANGED" boundary and is **not fixed
> here**.
> **However — G2 closes it as a side effect, and that is deliberate:** §4.4 step 3 selects the vision
> candidate from the **retained** list, and retention already applies `IMAGE_MIN_BYTES`, so a
> sub-20 KB logo is no longer eligible. This is a *consequence* of an approved decision, not a
> separate change, and the residual (a logo **over** 20 KB still winning first place) remains open
> and is called out in §7.

### 4.9 Tests

Per `.claude/rules/bulk-test-rule.md`, `ExtractAddressQueueable` is **de-exempted** from the 251
rule; volume + governor-headroom tests replace it.

#### A. The five de-exemption tests the rule REQUIRES (existing — must stay green, two re-pinned)

| # | Test | Change |
| --- | --- | --- |
| 1 | **`MAX_PROPERTIES` volume** — one email, 10 properties, all routed | extend: + 3 attachments; assert 30 routed links from **ONE** DML statement |
| 2 | **Truncation** — 15 properties, exactly 10 routed, `[truncated: 10 of 15]` visible | unchanged; assert files still link to exactly the 10 routed records |
| 3 | **Governor headroom** — named budgets | 🔴 **RE-PIN: `DML_BUDGET` 60 → 61.** `QUERY_BUDGET` stays **120** |
| 4 | **Mixed outcome** — winner + competing + repeat in one email | extend: the same file set links to all three distinct records, still ONE DML |
| 5 | **Ordering determinism** — `Routed_Record_Ids__c` in cluster-key order | unchanged; file links must follow the **same** ordered target list |

Plus the single-property budget test: 🔴 **RE-PIN `singlePropertyDmlBudget` 20 → 21**;
`singlePropertyQueryBudget` stays **30**.

> Every re-pinned constant needs an inline comment saying **why it moved** ("+1 = the single bulk
> `ContentDocumentLink` insert added by attachment capture, 2026-08-05"), so a later reader does not
> read it as drift. A budget that moves without an explanation is indistinguishable from a
> regression that was accommodated.

#### B. New tests

6. **🔴 THE LOAD-BEARING ASSERTION — the DML delta is `+1` at N=1 AND at N=10.** Assert against a
   no-attachment control run in the same test class so the delta is measured, not assumed. This is
   the test that makes a future per-property or per-file CDL insert fail **here** instead of in
   production. If only one test survives review, it is this one.
7. **Compatibility:** a zero-attachment email behaves **byte-identically** to today — zero
   ContentVersions, zero links, **zero extra DML**, staging fields null/0. Mirror the existing
   `buildLlmText_blankSubject_returnsTheBodyByteIdentically` precedent; it is what makes an additive
   change provably additive.
8. **Classification (pure, no DML)** — table-driven over `classify(...)`:
   PDF kept · `application/octet-stream` + `.pdf` kept (**pins G1's union**) · `.xlsx` kept ·
   `.csv` text attachment kept (**pins G3**) · `.vcf` / `.ics` dropped · 19 KB PNG dropped
   (**pins G2**) · 21 KB PNG kept · file > `ATTACHMENT_MAX_BYTES` dropped · 11th file dropped
   (**pins `MAX_ATTACHMENTS`**). Every drop carries a reason in `droppedNotes`.
9. **Vision gate (pins A1-a/A2):** an image of `VISION_MAX_BYTES + 1` is **not** encoded, is
   recorded, and the queueable still runs; an image just under is encoded exactly as before.
10. **Redelivery (pins E):** duplicate staging row, duplicate ContentVersion, and **ZERO** duplicate
    links on the routed record — because the skip path returns before `finish()`.
11. **Refusal (pins C):** a failed CDL insert is recorded in `Dropped_Attachment_Notes__c`, does not
    throw, and costs neither the Task nor the claim.
12. **🔴 Boundary (pins §4.4's most important rule):** a forced failure inside `persist(...)` must
    leave `result.success == true` and the staging row intact. **A file problem must never bounce or
    discard a broker email.**
13. **`InboundEmailAttachmentServiceTest`** — ≥ 90% on the new class per ARCHITECTURE §2.

> **Bulk-rule note for the test header:** a literal 251 remains impossible and meaningless here for
> the reasons already recorded in `.claude/rules/bulk-test-rule.md` (the enqueue cap is 50; 251
> properties would exhaust SOQL at ~14–24). Restate that in the header so review does not demand it.

> ⚠ **Counters come from `ExtractAddressQueueable.lastRunQueryCount` / `lastRunDmlCount`, never from
> `Limits.*` after `Test.stopTest()`** — stopTest restores the pre-test counters, making the obvious
> assertion silently vacuous. The existing tests already do this correctly; follow them.
>
> 🔴 **A GREEN TEST SUITE WILL NOT PROVE THIS FEATURE WORKS.** Two independently measured precedents
> in this repo say so: `EmailMessage.RelatedToId` **commits at runtime but is refused from
> `@isTest`**, and a Lead lookup to a converted Lead **throws at runtime but succeeds inside
> `@isTest`**. Content DML has every hallmark of the same class of behaviour. **A live UAT step as
> the Email Service persona is mandatory** — send one real email with a PDF and one with a large
> image, and read the results back. Do not accept an admin smoke test as evidence.

---

## 5. 🔗 EXECUTION ORDER

✅ **Spikes complete (C1 / C2 / C3 / F0). No blocking prerequisites remain.**

1. **Admin:** three staging fields → FLS on `Broker_Protection_Access` (19 → 22) → update the
   verification comment → layout / Files related list → **`Discard` → `Bounce`** (in-org, §3.5).
2. **Developer:** `ContentVersionSelector` → `InboundEmailAttachmentService` → `EmailToLeadHandler`
   → `InboundEmailStagingService` → `ExtractAddressQueueable`.
3. **Unit tests** (§4.9) → **code review** → deploy.
4. **UAT as the Email Service persona (§5.1) — MANDATORY, not optional.**
5. **`ARCHITECTURE.md` update in the SAME PR** (§6 requirement): `InboundEmailAttachmentService` in
   the §2 Key Apex Services table; `ContentVersionSelector.selectByIds` in the automation-path
   `SYSTEM_MODE` table (16 → 17 queries, 11 → 12 classes); and the file-capture step added to the
   Broker Protection staging-model narrative.

---

### 5.1 ⚠ UAT CHECKLIST — A GREEN APEX SUITE DOES NOT PROVE THIS WORKS

**Why this section is not optional.** This repo has **two independently measured precedents of
platform DML behaving differently by context**: `EmailMessage.RelatedToId` commits at runtime but is
refused from `@isTest`; a Lead lookup to a converted Lead throws at runtime but is unenforced in
`@isTest`. Content and conversion DML are the same family. Additionally, the spike's own C1/C3
persona results were **test-context measurements** (`System.runAs` is `@isTest`-only), and its C1
mechanism was **confounded by `ViewAllRecords`**.

**Run every step as / through the real pipeline, never as an admin.** An admin smoke test proves
nothing here — the same lesson as the Deal-Driver gate, where a bare System Administrator lacked FLS
on a field they had just deployed.

| # | Step | Pass criterion |
| --- | --- | --- |
| U1 | Forward a real broker email with a **PDF OM** | Staging row: `Attachment_Count__c = 1`, `Attachment_Bytes__c` > 0, `Dropped_Attachment_Notes__c` blank. File visible on the staging row **and** on the routed Lead. |
| U2 | Forward one with **PDF + XLSX + a signature logo** | Two files kept, logo dropped **with a recorded reason**. |
| U3 | Forward one with a **`.csv` rent roll** | Kept (pins G3 in the real transport, where the `String`→`Blob` path actually runs). |
| U4 | Forward one with a **> 1 MB image** | **No heap error**, email routes normally, vision skip recorded. This is the A1-a acceptance test. |
| U5 | Forward one with a **~2 MB image** | Handler survives. Directly exercises the old latent crash (~1.6–2.5 MB). |
| U6 | **Multi-property email** (2+ properties, mixed outcomes) | One file set appears on **every** routed record, once each. |
| U7 | **Competing-submission branch (d)** — a second broker on a claimed property | File links onto the **other broker's winning Lead**. **Pins C1 in the only way that counts** — the spike's own caveat says this was never isolated. |
| U8 | 🔴 **Convert a Lead that carries a file** | File reaches **Account, Contact AND Opportunity**; the Lead link is gone. **This reconfirms F0/S6 at runtime. If it fails, F-2 comes back as an idempotent repair step (§2 F).** |
| U9 | **Redelivery** — re-send the same Message-ID | No duplicate link on the routed record (pins E). |
| U10 | Read back as a **non-admin deal persona** | The three new staging fields are visible (pins the §3.2 FLS grant) and the file opens from the Opportunity. |
| U11 | Confirm the email-service failure action | Reads **`Bounce`**, not `Discard`. |

**Record the results.** U8's outcome in particular should be written back into §2 F, because the
whole of F-1 rests on it.

---

## 6. ✅ DECISIONS — ALL RESOLVED. NO OPEN BLOCKERS.

| # | Resolution | Basis | Where |
| --- | --- | --- | --- |
| **A1** | ✅ **A1-a — gate the base64 encode.** | User, Gate 1 | §2 A, §4.4 step 3 |
| **A2** | ✅ **`VISION_MAX_BYTES` = 1,000,000.** | User, Gate 1 | §4.1 constants |
| **B1** | ✅ **Accept + record + `Discard` → `Bounce`.** | User, Gate 1 | §2 B, §3.5 |
| **C1** | ✅ **No fallback needed — the risk does not exist.** `ViewAllRecords = true` on Lead + Opportunity. `without sharing` kept as future-proofing only. | Spike S2 | §2 C |
| **C2** | ✅ **`'I'` routed records, `'V'` staging, never `'C'`.** | Spike S3 | §2 C table |
| **C3** | ✅ **Nothing to grant** — Content is license-gated. Permission-set task deleted. | Spike S1 | §3.3 |
| **D1** | ✅ **Carry `contentDocumentIds` on the constructor** (0 SOQL). | Design, adopted | §2 D, §4.5 |
| **D2** | ✅ **REJECT `FirstPublishLocationId`** — hardcodes `'V'`, creates 2 CDLs. | Spike S4 | §2 D |
| **E1** | ✅ **No dedupe.** Bounded, storage-only, structurally contained. | Design, adopted | §2 E |
| **F1** | ✅ **F-1: do nothing.** Platform carries files to Account + Contact + Opportunity. `LeadFileCarryOverService` deleted. | Spike S6 | §2 F, §4.7 |
| **G1** | ✅ **Union of MIME and extension.** | Design, adopted | §4.8 |
| **G2** | ✅ **`IMAGE_MIN_BYTES` = 20,000, images only.** `Content-Disposition` not adopted (unverified surface). | Design, adopted | §4.8 |
| **G3** | ✅ **Allow `.csv`; drop all other `textAttachments`.** | User, Gate 1 | §4.8 |
| **H1** | ✅ **Yes — build `Attachment_Bytes__c`.** | Design, adopted | §3.1 |

---

## 7. SCOPE STATEMENT

This document adds **nothing** beyond persistence of attachments plus the guards required to make
persistence safe. It does **not** change the LLM prompt, the extraction contract, the routing tree's
branch logic, the claim engine, the Task contract, or any arbitration input. No fixture is re-pinned.

**One approved boundary crossing, consciously taken:** A1-a adds a size gate to the base64 encode
inside the "vision path unchanged" boundary. The vision call's inputs remain byte-identical for
every image under 1 MB; above it, the image is skipped and recorded instead of crashing the handler.
The user approved this at Gate 1 as a **bug fix**.

**Net effect of the spikes: strictly less code than the pre-spike design.** One service class, one
selector method, one trigger wiring and one permission-set task were **removed** by measurement, not
added.

### 🚩 The two flagged-not-fixed items (retained deliberately)

| # | Item | Status |
| --- | --- | --- |
| **1** | **The first image may be a signature logo** (§4.8). The vision path takes the first image in list order, so the LLM may be reading a company logo rather than the offering flyer. Never observed, because fact 5 shows the path has never run in production. | **Not fixed.** G2's 20 KB floor closes it for logos **under** 20 KB as a side effect of an approved decision. A logo **over** 20 KB arriving before the flyer would still win — that residual is **open** and belongs to a future extraction change, not this one. |
| **2** | **The oversized-email claim loss** (§2 B). Emails above the service ceiling are rejected **above Apex** — no staging row, no Lead, no registry claim, no audit. A later broker with a smaller email wins the property outright. | **Not fixable in Apex.** Mitigated only by `Discard` → `Bounce` (§3.5) plus a coordinator runbook. Exists today, unchanged by this feature. Do not mistake this feature for a fix. |

Both are recorded here so a future reader can tell a **known, priced residual** from an oversight.
