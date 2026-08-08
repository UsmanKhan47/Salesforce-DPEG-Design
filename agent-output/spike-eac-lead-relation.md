# Spike: Can an outbound EAC-captured reply be put on its Lead via `EmailMessageRelation`?

**Org:** `usman-dpeg` (`usman.khan.dpeg@avanzasolutions.com`, `00Diw000000Fqw1EAC`)
**Date:** 2026-08-06
**Method:** Anonymous Apex (`sf apex run`) + SOQL against a **real** EAC capture. No feature code, no
metadata deploys, no repo changes.

## Record used

Real capture `02siw0000006jfBAAQ` — outbound reply "Re: Office/Warehouse with Additional Land For
Sale:" (`Incoming = false`). Candidate Lead: `00Qiw000000VhgbEAC` (its stated thread anchor).

**Baseline (verified before any DML):**
- `EmailMessage.RelatedToId` = `006iw000000KucLAAS` (Opportunity), `ActivityId` = `00Tiw000000IU2sEAG`
- Relations: User `005iw000000AJhJAAW` `FromAddress`, Contact `003iw000000bEtdAAE` `ToAddress`
- Companion Task `00Tiw000000IU2sEAG`: `WhoId` = the Contact, `WhatId` = the Opportunity,
  `CreatedBy.UserType` = `AutomatedProcess`, `Inbound_Message_Id__c`/`Thread_Key__c` both null
  (confirms it is an EAC-generated Task, not a Broker Protection pipeline anchor Task — safe to
  touch per the constraints).

I chose the real capture over a synthetic one because the prior finding this spike builds on
(`EmailThreadGuardServiceTest` bisect, 2026-08-02) was itself measured on real relation-insert
mechanics, and a synthetic `EmailMessage` risks reproducing the known "`RelatedToId` update refused
under `@isTest` against a test-created row, but commits at runtime against a real one — mechanism
undetermined" gap documented elsewhere in this repo. Using the real row removes that confound.

---

## Q1 — Does the insert succeed?

**Apex:**
```apex
EmailMessageRelation rel = new EmailMessageRelation(
    EmailMessageId = '02siw0000006jfBAAQ',
    RelationId = '00Qiw000000VhgbEAC',   // the Lead
    RelationType = 'ToAddress'
);
insert rel;
```

**Result:** `SUCCESS`, `relId = 0CZiw0000008WabGAE`. No exception. Notably, the debug log shows
`TaskRollupTrigger on Task trigger event AfterInsert` fired synchronously inside the same
transaction — i.e. the relation insert itself triggers a Task insert (the companion-Task
recreation), confirmed further under Q2.

**ANSWER: Yes.** A `Lead` / `'ToAddress'` `EmailMessageRelation` inserts cleanly on an outbound
capture that already carries a Contact `ToAddress` + User `FromAddress` relation. No
`LIMIT_EXCEEDED` or any other error — the sender-slot blocker from the prior finding is confirmed
irrelevant here, exactly as hypothesized (it only applies to a second **User** relation contending
for the single-sender slot).

---

## Q2 — THE DECISIVE ONE: does the recreated Task actually land on the Lead?

**Apex (re-query, never cached):**
```sql
SELECT Id, ActivityId FROM EmailMessage WHERE Id='02siw0000006jfBAAQ'
```
→ `ActivityId` changed from `00Tiw000000IU2sEAG` → `00Tiw000000IVyDEAW` (proves the companion Task
was destroyed and recreated, consistent with the prior finding).

```sql
SELECT Id, WhoId, Who.Type, WhatId, What.Type, CreatedBy.UserType,
       Inbound_Message_Id__c, Thread_Key__c
FROM Task WHERE Id='00Tiw000000IVyDEAW'
```
**Result:**
| Field | Value |
|---|---|
| `WhoId` / `Who.Type` | `003iw000000bEtdAAE` / **Contact** |
| `WhatId` / `What.Type` | `006iw000000KucLAAS` / **Opportunity** |
| `CreatedBy.UserType` | **`Standard`** (was `AutomatedProcess` on the pre-spike Task) |
| `Inbound_Message_Id__c` / `Thread_Key__c` | both null |

**ANSWER: NO — the Task does not surface on the Lead.** `WhoId` is a single polymorphic slot and it
stayed pinned to the pre-existing Contact relation; the newly added Lead relation had no effect on
which record the recreated Task's `WhoId` resolves to. The Lead gained an `EmailMessageRelation` row,
but nothing that renders on its Activity Timeline — no Task references the Lead by `WhoId` or
`WhatId` anywhere in this record's data. **Per the stated criterion, this alone kills the mechanism:
the goal was the reply appearing on the Lead's timeline, and it does not.**

**Second finding, independently costly:** the companion Task's `CreatedBy.UserType` flipped from
`AutomatedProcess` to `Standard` (the DML-committing user) the instant the relation set changed —
confirming the capture **permanently loses its EAC fingerprint** the moment any relation DML touches
it, which would make `EmailThreadGuardService`'s guard-3 fingerprint check treat a re-guarded capture
as human-originated thereafter. This is not a hypothetical: it happened on the very first insert, and
(see Q3) recurs on every subsequent relation DML including the cleanup delete — there is no way to
add or remove a relation on this EmailMessage without paying this cost.

---

## Q3 — Idempotency

**Apex:** inserted the identical `Lead`/`'ToAddress'` relation a second time.

**Result:** `SUCCESS` again — but **not** a no-op and **not** a duplicate. `COUNT()` of Lead relations
immediately after was `1` (not 2), yet the returned `Id` (`0CZiw0000008WdpGAE`) differed from the
first insert's `Id` (`0CZiw0000008WabGAE`). Re-querying confirmed: the first Lead relation row was
gone; a second, different-Id row with identical logical content had replaced it. The User and Contact
relation rows (`0CZiw0000008WKTGA2` / `0CZiw0000008WKUGA2`) were untouched — same `Id`, same
`CreatedDate` as baseline, across both inserts.

`EmailMessage.ActivityId` also changed again on this second insert (`00Tiw000000IVyDEAW` →
`00Tiw000000IW33EAG`), confirming a **second full companion-Task recreation cycle**, even though the
relation being inserted was logically identical to one that already existed.

**ANSWER: Partially convergent, but NOT free.** The *logical relation set* converges (still exactly
one Lead/ToAddress row, no duplication) — in that narrow sense it behaves like the adopter's
convergent design. But the underlying mechanism is delete-old-row + insert-new-row, not a true no-op:
every insert (even of an "already true" relation) re-triggers full Task destruction/recreation, with
a new Task `Id` and a fresh `CreatedBy.UserType` = the DML user each time. A future implementation
that re-runs idempotently (e.g. a sweep, or a retry after a partial failure) would churn the
companion Task on every pass, not just the first — this is a real cost, not a curiosity.

---

## Q4 — Does it disturb existing associations?

Checked immediately after Q1's insert, before Q3:

```sql
SELECT Id, RelationId, RelationType, RelationObjectType
FROM EmailMessageRelation WHERE EmailMessageId='02siw0000006jfBAAQ'
```
→ 3 rows: original User `FromAddress` (unchanged `Id`), original Contact `ToAddress` (unchanged
`Id`), plus the new Lead `ToAddress` row. All three original values intact.

```sql
SELECT Id, RelatedToId FROM EmailMessage WHERE Id='02siw0000006jfBAAQ'
```
→ `RelatedToId` still `006iw000000KucLAAS` (the Opportunity) — unchanged.

**ANSWER: Yes, clean.** The Contact relation and `RelatedToId` (the Opportunity anchor) are both
fully intact after adding the Lead relation. The mechanism is additive at the relation-row level, as
hoped — the cost is confined to the Task-recreation side effect (Q2/Q3), not to the other
associations.

---

## Cleanup performed and verified

Deleted the added Lead relation (`0CZiw0000008WdpGAE`) via a separate `sf apex run` call. Re-query
confirmed:
- Relations back to exactly 2: User `FromAddress` (`005iw000000AJhJAAW`), Contact `ToAddress`
  (`003iw000000bEtdAAE`) — same `Id`s as baseline throughout.
- `EmailMessage.RelatedToId` = `006iw000000KucLAAS` (unchanged throughout).
- Companion Task recreated a **third** time by the delete itself (`ActivityId` → `00Tiw000000IW4fEAG`)
  — confirms deletion of a relation, not just insertion, also triggers the recreation cycle.
- Final live Task (`00Tiw000000IW4fEAG`): `WhoId` = the Contact, `WhatId` = the Opportunity, same
  `Subject`, `Inbound_Message_Id__c`/`Thread_Key__c` both null — **logically identical shape** to the
  pre-spike Task.
- Confirmed via `ALL ROWS` query that the three intermediate Task rows
  (`00Tiw000000IU2sEAG`, `00Tiw000000IVyDEAW`, `00Tiw000000IW33EAG`) are soft-deleted
  (`IsDeleted = true`) — the platform itself recycled them as a side effect of each recreation; no
  orphaned live duplicates remain.

**What could NOT be restored, and is disclosed rather than hidden:** the live Task's
`CreatedBy.UserType` is now `Standard`, not the original `AutomatedProcess`. This is not an
oversight — `CreatedById` cannot be set via DML, and (per Q2/Q3) *every* relation-DML on this
EmailMessage, including the cleanup delete itself, recreates the Task under whichever principal ran
the DML. There is no sequence of operations that tests this mechanism on a real capture and leaves
its EAC fingerprint intact afterward. This capture's fingerprint change is a permanent, honest cost
of having run this spike at all — flagged per the instruction not to under-report ambiguity or cost.

Nothing on the "do not touch" list was modified: `Property_Registry__c` rows, `Inbound_Email_Staging__c`
rows, Leads `00Qiw000000VZJFEA4`/`00Qiw000000VhgbEAC` (Lead `00Qiw000000VhgbEAC` was read-only
queried, never written), and no pipeline Task carrying `Inbound_Message_Id__c`/`Thread_Key__c` was
touched — every Task involved in this spike had both fields null throughout, confirmed before and
after.

---

## Verdict

**Not viable, at any cost.** The `EmailMessageRelation` row itself inserts cleanly, is additive to
the existing Contact/Opportunity associations (Q4), and doesn't hit the sender-slot blocker that
ruled out a second User relation (Q1) — but none of that matters, because **the recreated companion
Task never re-points to the Lead** (Q2, the disqualifying result stated up front in the brief). `WhoId`
stayed on the pre-existing Contact both times a relation was added. The reply still does not appear
on the Lead's Activity Timeline by any route (no Task references the Lead via `WhoId` or `WhatId`) —
only an invisible `EmailMessageRelation` join row exists on the Lead, which carries no UI surface.

Even setting the disqualifying result aside, the mechanism has two costs that would matter to any
future design built on it: (1) **it is not truly idempotent** — every relation DML, including a
repeat of an identical relation, triggers a full Task destroy/recreate cycle (Q3); and (2) **every
such cycle permanently strips the capture's `AutomatedProcess` EAC fingerprint** (Q2), which would
disable `EmailThreadGuardService`'s guard-3 check on that capture from that point forward.

**One variable was deliberately left untested and should not be assumed either way:** whether `WhoId`
would resolve to the Lead if the pre-existing Contact `ToAddress` relation were removed first (i.e.
Lead-only, no competing Contact relation). Testing that would have meant deleting the real capture's
original Contact relation — outside what this spike was authorized to alter ("must ADD the Lead,
never move anything off the Opportunity" / restore exactly). If a future spike wants to test the
Lead-only case, it should use a synthetic EmailMessage, not this real capture, to avoid another
irreversible fingerprint cost on production data. This is not evidence that a Lead-only relation
*would* work — it is an explicitly unmeasured case, distinct from the disqualifying Q2 result above.
