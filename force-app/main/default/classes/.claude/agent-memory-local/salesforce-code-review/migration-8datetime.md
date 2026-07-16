---
name: migration-8datetime
description: The 8-DateTime migration (D1-D4) — DateTimeBackfillBatch (D2), the Work_Order_Touch_Sync canary gate, and review stances that recur for backfill batches
metadata:
  type: project
---

# 8-DateTime migration (ARCHITECTURE.md §1 rule 9)

Renames 8 mis-typed `*_Date__c` DateTime fields to correctly-named `*_DateTime__c` twins across
Work_Order__c (Reported/Completed/First_Touched) and Entry_Date__c on Deal_Message__c /
Lease_Activity__c / Renewal_Activity__c / Work_Order_Activity__c. Phased: **D1** dual-write both
fields (TestDataFactory + flows write both); **D2** backfill historical rows (`DateTimeBackfillBatch`);
**D3** repoint readers to the new field; **D4** retire the legacy `*_Date__c` fields (made required, dropped).

**Why:** the `_Date` suffix asserted a date-only type these fields never had; they always stored date+time.

**How to apply when reviewing D3/D4 (or any similar backfill):**
- The load-bearing hazard is `Work_Order_Touch_Sync` — a **before-save, CreateAndUpdate, NO-entry-criteria**
  flow on Work_Order__c. It stamps NOW() into First_Touched (when Status!='New' AND old First_Touched null)
  and Completed (when Status IN Completed/Closed AND old Completed null). Any UPDATE to a Work Order re-fires it.
  A backfill is only safe if those stamp preconditions are empty. `DateTimeBackfillBatch.run()` proves that with
  two pre-flight canaries that are the exact negation of the flow's two rules, and aborts before DML if either is >0.
- Only Work_Order__c has update-firing automation among the 5 backfilled objects. Verified: no Apex triggers on any
  of the 5; the only flow touching Lease_Activity__c (`Lease_Inquiry_Open_Log`) is after-save on Lease_Inquiry__c and
  merely *creates* an activity — it does not fire on Lease_Activity__c updates. So a Work_Order-only canary gate is correct.
- `Resolution_Days__c` / `Hours_Open__c` / `SLA_Health__c` are formulas over the OLD Work_Order fields — that is why an
  accidental NOW() stamp would silently collapse SLA math. Backfill must be read-old / write-new ONLY.

## Review stances raised in the D2 review (not yet ratified by user)

- **Sharing on a system backfill:** D2 uses `with sharing`. With sharing, both start()'s QueryLocator and finish()'s
  remaining-count run in the runner's visibility, so finish()'s "loud fail on partial copy" guarantee is only as complete
  as the runner's record access — records the runner can't see are skipped AND uncounted, so finish() can pass while they
  remain unbackfilled. Recommended `without sharing` + a documented justification in the class header (ARCHITECTURE.md §2
  explicitly permits that), or at minimum document that it must run as an admin with Modify All Data.
- **Inline SOQL in a migration batch:** apex-layering-rule.md says "all SOQL in selectors, no exceptions," but
  ARCHITECTURE.md scopes the hard prohibition to service/domain classes and lists Batch as its own layer. A batch start()
  QueryLocator is idiomatic, and WITH USER_MODE selectors are actively wrong for a system migration (would hide rows).
  Treated as an accepted deviation that should be **documented in the class header**, not a CHANGES-REQUIRED violation.
- **finish() throw is effectively uncoverable & untested:** start() and finish() share the same predicate, so after a
  normal run finish() never sees remaining>0. The single most important safety branch has no test. Recommended a
  `@TestVisible` seam so a test can prove finish() throws on a reconstructed partial-copy state.
- The canary-abort branch in run() is genuinely uncoverable in Apex (an active before-save flow prevents the precondition
  from ever persisting). That reasoning is correct. NOTE: the test comment's claim that "Bulk API bypasses before-save flows"
  is wrong — before-save flows fire on Bulk API; the real bypass is data that predates the flow / was loaded while inactive.
