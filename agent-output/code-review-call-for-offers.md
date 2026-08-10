# Code Review — Tranche 4 (Call for Offers)

**Branch:** `feature/stage-by-stage-alignment` (work later committed as `3e798d2`)
**Date:** 2026-08-10 · **Files reviewed:** 7 (2 declarative, 5 Apex) · **Read-only**

> ⚠ **Provenance.** The reviewing agent's own operating instructions forbid it writing report
> files, so this report was persisted by the orchestrator from the agent's returned text. It is
> faithful to that text; the tables and file:line references are the agent's, not re-derived.

---

## Verdict: ⚠️ APPROVED WITH WARNINGS

| Severity | Count |
|---|---|
| 🔴 CRITICAL | **0** |
| 🟡 WARNING | 3 |
| 🟢 SUGGESTION | 6 |
| ✅ PASSED | all 6 mandated hard-look areas |

> "**This is ready to deploy.** The three things that could have made it dangerous — an escaping
> stamp exception costing the Message-ID, the file job switching on for campaign decks, and the
> multi-property label falling out of its own watch view — were all identified before code was
> written and are each pinned by a test that goes red if removed."

---

## The six hard-look areas — all passed, with mechanism

1. **`finish()` is unreachable-proof.** `ExtractAddressQueueable.cls:923-940` — `suppressFilePersist = true`
   is set *before* the `try`, so a throw cannot leave the flag unset; the `catch (Exception e)` (`:926`)
   is total, not typed; `routingErrors.add(...)` (`:928`) reaches `Error__c` via
   `finish()` → `markRouted(buildResult(routingErrorText()))`; the empty-outcomes fallback (`:933-938`)
   guarantees `Outcome__c` is never blank. Pinned by
   `callForOffers_stampThrows_stillReachesFinishAndLogsTheTask` (`ExtractAddressQueueableTest:4356`),
   which asserts the Task exists, `Status__c = 'Error'`, `Error__c` names the deal, **and**
   `Offer_Due_Date__c` is still null as a stated precondition — so it cannot pass vacuously.
2. **Carrier suppression correct, test non-vacuous.** `:1929-1934` sits above the `targets.isEmpty()`
   check at `:1935`; the flag is set at `:923` unconditionally on the only path in. The test (`:4132`)
   asserts `Result_Record_Id__c == dealId` **first** — the labelled precondition proving `targets` was
   non-empty (`:4164-4167`) — then `lastRunEnqueuedTargets` null, 0 carrier Attachments,
   `Attachment_Status__c = Not Saved`, 0 `ContentVersion`, 0 `AttachmentPersistQueueable` jobs.
3. **U2 suppression intact.** `isCallForOffersGated` (`:2807-2809`) byte-identical. `routeCallForOffers`
   calls neither `createLead` nor `PropertyClaimService`, so suppression is **structural, not
   conditional**. Four tests assert Lead / `Property_Registry__c` / `Competing_Broker_Submission__c` /
   `Property_Claim_Lock__c` counts unchanged — including on the **matched** path (`:4060-4069`), which is
   where it would have regressed.
4. **Stamp DML shape.** `CallForOffersStampService:229` is
   `Database.update(updates, false, AccessLevel.SYSTEM_MODE)`. `mergeByRecord` runs at `:192`, before the
   read and long before the DML; `updates` is built by iterating the *query result*, which cannot contain
   duplicate Ids, so `DUPLICATE_VALUE` is unreachable. Pinned by
   `stamp_twoPropertiesResolvingToOneDeal_isOneRowNotADuplicateIdFailure`. Refusals →
   `StampResult.refusals` → `routingErrors.addAll(...)` (`ExtractAddressQueueable:1339`) → `Error__c`.
   No static parking.
5. **Test seams.** Both `@TestVisible private static`; production cannot reach them.
   `simulateStampFailure` throws before any read or write; `simulateReadResult` replaces **only** the
   selector call at `:206-208`, leaving `Database.update`, the `SaveResult` loop, partial success and
   `describeRefusal` real. Apex statics do not survive across test methods, so neither can leak.
6. **Live-pipeline regression surface.** The branch returns before `routeProperties`, so
   winner/competing/repeat paths are untouched; the five pre-existing `callForOffers_*` tests are
   unmodified and all take the no-match path — the D3 regression guard.

---

## 🟡 W1 — A campaign blast overwrites a live deal's real listing broker ✅ FIXED

**Files:** `ExtractAddressQueueable.cls:1296-1301`, `CallForOffersStampService.cls:303-315`

The comment at `:1281-1295` inverts U1 for a stated reason: *"a call-for-offers blast is precisely the
traffic that arrives from `listings@buildout.com` … envelope-first would write a PLATFORM address into a
field a human reads as 'who do I call'."* **The `: senderEmail` fallback then did exactly that** whenever
the model named no listing broker — the inversion was only half-delivered.

Combined with the unconditional overwrite in `buildChange` (`:304`, `:312`), a live deal already carrying
the **real** broker — copied from the winning broker's own email by `LeadConvertService` at conversion —
had `Listing_Broker_Name__c` / `Listing_Broker_Email__c` replaced by a blast platform's mailbox or by
whoever an unrelated marketing blast named.

**The distinction that matters:** a deadline is a fact about the campaign, so last-wins is right. **The
listing broker on a live deal is a fact about the transaction, and a third party's blast is not newer
information about it.**

Not critical because it fires only for converted winners (Q1 minority), the fields are display-only, and
the staging row reconstructs it — **but it is silent, unauthenticated-inbound-driven, and degrades a live
deal.** No test covered the fallback path, which is why it shipped.

✅ **Fixed before commit:** the fallback was dropped (`:1334` is now
`String listingBrokerEmail = extraction.listingBrokerEmail;`); `buildChange` already ignores nulls, so the
deal keeps the broker it knows and the deadline still lands. Three new tests cover the null-broker path.

---

## 🟡 W2 — The sharing argument was made about the write target, not the read that decides the match

**Files:** `OpportunitySelector.cls:318-337`, `ExtractAddressQueueable.cls:1383`,
`PropertyMatchingService.cls:462`, `LeadSelector.cls:229-240`

`selectCallForOffersTargetsByIds`'s header is the best sharing analysis in the tranche — mode and sharing
argued separately, OWD measured against the org, the Private-OWD residual named as *"the failure mode this
feature fails by."* That analysis covers the **`Opportunity` write target**.

The query that actually decides matched-vs-not is one link earlier:

```
Id live = PropertyMatchingService.resolveLiveRecord(winner.Winning_Lead__c);   // :1383
  └─ LeadSelector.selectConversionById   →  WITH USER_MODE, on a `with sharing` class
     └─ if (rows.isEmpty()) return recordId;   // ← reads as "unconverted winner"
```

If that read were ever **filtered** by sharing rather than refused, `rows.isEmpty()` is true,
`resolveLiveRecord` returns the Lead Id, `findLiveDealForProperty` sees a non-Opportunity and returns null
— **"no deal matched," silently, with no error and no failing test.** Exactly the failure shape the
Opportunity header warns about, one query upstream, unargued.

**Not believed broken:** branches (d) and (e) make the identical call (`:1646`, `:1711`) and are live in
production. The FLS half is safe — `IsConverted` / `ConvertedOpportunityId` / `ConvertedContactId` are not
FLS-controlled.

**Remedy (no code change):** extend post-deploy gate **G5** to assert, *as the pipeline principal*, that a
registry row whose winner has converted resolves to an Opportunity Id — not merely that the stamp writes.
Add a sentence to the selector header pointing at `resolveLiveRecord` as the other half of the chain.

---

## 🟡 W3 — The thread-anchor consequence list is incomplete: branch (a) returns **before the callout**

**File:** `ExtractAddressQueueable.cls:1250-1261`

The header flags two consequences of the new anchor (reply routing, EAC adoption) and calls both "arguably
desirable." **There is a third, and it has teeth.**

Before 4B a gated call-for-offers email logged an **unattached** Task, so `findRecordByReplyHeaders` had no
record to return and a follow-up ran the full pipeline. After 4B a *matched* email's Task carries a
`WhatId`, so a follow-up hits `routePrologueWithoutCallout` (`:984-993`): filed on the Opportunity, returns
`true` — **no callout, `Extracted_JSON__c = {"skipped":"reply"}`, no claim.**

Campaign threads are exactly where a follow-up says *"also available: 123 New St."* Under the new behaviour
that property is **never extracted, never claimed, and not even named in the audit field.**

Consistent with the standing branch-(a) trade-off already argued at `:972-980` (*"the gate can only ever
suppress a NEW conversation, never an existing one"*), so **correctly accepted** — but it widens a
claim-loss vector to a new traffic class and was not written down.

**Remedy (no code change):** third bullet at `:1256-1258`, and a UAT case.

---

## 🟢 Suggestions

| # | File:line | Issue |
|---|---|---|
| **S1** | `ExtractAddressQueueable.cls:1902` | Javadoc names a test that does not exist (`…releasesAndNeverEnqueues`); the real name is `…releasesTheCarrierAndNeverEnqueues` (`:4132`). |
| **S2** | `:720-722` | `suppressFilePersist`'s Javadoc calls the empty-targets release *"decision 2"*; current numbering is **3**, and `:1897` says 3. Two docs, one path, two numbers. |
| **S3** | `ExtractAddressQueueableTest.cls:4416-4453` | `callForOffers_sameCampaignTwice_theSecondPassStampsNothingNew` selects `LastModifiedDate` (`:4440`) and never asserts on it — nothing distinguishes "skipped" from "rewrote the same value". Real proof is `CallForOffersStampServiceTest.stamp_replayedWithIdenticalValues_isAZeroDmlNoOp`. |
| **S4** | `CallForOffersStampService.cls:211-220` | A requested Id the selector does not return falls out of all three result populations while the outcome still reads `— deal updated`. Effectively unreachable in one transaction; a fourth `missing` list would make them exhaustive. |
| **S5** | `ExtractAddressQueueable.cls:91-93` | **Pre-existing, now load-bearing.** Header step 9b still says `finish()` performs *"ONE bulk DML linking … Salesforce Files"* — contradicted by `:215-216` and `:230` (routed linking left `finish()` 2026-08-06). |
| **S6** | `Gated_Call_For_Offers.listView-meta.xml:40-47` | The "KNOWN RESIDUAL" about clipping is over-stated — `buildMultiSummary` **groups by label**, so length is bounded by distinct labels (two), never by N, and `callForOffers_tenProperties…` measures it (`:4240`). |

---

## Good practices found

- **The read-only seam.** `simulateReadResult` seams the one thing the platform will not do
  (`ENTITY_IS_LOCKED` in `@isTest`) and leaves the entire write path real — better than a writer mock, and
  the Javadoc explains *why a deleted row needs a snapshot*.
- **The precondition-first carrier test** — asserting `Result_Record_Id__c` before the release is what stops
  the test degrading into a proof that the old empty-targets path still works.
- **`<=` ceilings where the count legitimately varies**, with the reason in the constant's Javadoc, plus
  `lastRunQueryCount > 0` as an anti-vacuity assertion (`:4259`).
- **Counters read from in-async statics, never `Limits.*` after `stopTest()`** — stated as the rule.
- **Mode and sharing argued separately**, with OWD **measured against the org** rather than read off the
  repo. The D25 lesson correctly applied.
- **The label's two list-view couplings pinned by a pure string test** (`:3942`) — no DML, no mock, cannot
  be vacuous, catches a rename that would break a deployed view with no compile error.
- 🏆 **4A ships in the same change as 4B.** The `Multi-Property` prefix trap would have made a two-property
  call-for-offers email vanish from its only watch surface. Catching it at design time and widening the view
  *in the same deploy* — **"the single best decision in this tranche."**

**Architecture conformance: clean.** All SOQL in selectors; the service holds no inline query;
`ExtractAddressQueueable` keeps its "no SOQL, no DML of its own" invariant; `with sharing` throughout with
`SYSTEM_MODE` justified per method; no `@future`; no hardcoded Ids; the 251-record rule correctly waived
with the structural reason (`MAX_PROPERTIES = 10` is the production ceiling) recorded in both test headers;
`content-publication-rule.md` not engaged — zero `ContentVersion` anywhere in the new tests, which is the
branch's whole point.

---

## Must reach the deploy runbook — no Apex test can prove either

1. **Post-deploy gate G5 must run as the pipeline principal, not as an admin** — and must cover the
   `resolveLiveRecord` Lead read (W2), not only the Opportunity stamp.
2. **A UAT case for the thread anchor (W3):** send a call-for-offers blast that matches a converted winner,
   reply in that thread, and confirm the reply lands where you want it — and that losing the extraction on
   that reply is acceptable.
