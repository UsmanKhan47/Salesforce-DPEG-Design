# Broker Protection — Change 1: Stop Creating Duplicate Leads for Competing Brokers

**Date:** 2026-07-31
**Author:** Documentation Agent
**Status:** Code-reviewed, APPROVED WITH WARNINGS. Deployed behavior described below; see "Known-Open
Items" for what the review left unresolved.
**Companion docs:** `docs/2026-07-24-broker-protection.md`, `docs/broker-protection-architecture.md`,
`docs/broker-protection-data-dictionary.md`, `docs/broker-protection-faq.md`,
`docs/broker-protection-operations.md`, `docs/broker-protection-overview.md` (all updated in this same
pass — see each doc's content for the specific edits), `ARCHITECTURE.md` §1/§2 (updated by the
implementing agent, not this pass).

---

## 📋 Overview

### Original Request

> Hand this document to an AI coding agent in a repo that already contains the Broker Protection
> module. Migrate the routing from "duplicate-flagged Lead per competing broker" to
> "submission-tracking entry only, NO Lead." A competing broker should receive **no Lead at all**: the
> claim is recorded as a `Competing_Broker_Submission__c` against the winner with `Source_Lead__c =
> null`, and the email is logged on the **winning** Lead instead. Outcome labels change from
> `Competing Duplicate` → `Competing Submission` and (new) `Competing Submission (race)`. A competing
> broker who re-emails the same property is a Repeat that lands on the winning Lead, since they have no
> Lead of their own. Both reasons for the change — Lead-table pollution and a `DUPLICATES_DETECTED`
> Savepoint-rollback failure class — matter and must be kept in code comments.
> *(Source: `agent-output/change-prompts-broker-protection-2026-07-31.md`, Change Prompt 1; the
> prompt's own code did not compile against this repo's layering — see "A note on the source prompt"
> below.)*

### Business Objective

Every competing broker who lost the first-broker-wins race used to get their own Lead, flagged
`Is_Duplicate_Property__c = true` and pointed at the winner via `Duplicate_Of_Lead__c`. Nothing in the
app ever displayed those fields, nothing ever worked those Leads, and — worse — a second Lead carrying
the same broker's email is exactly the shape an org's standard Lead duplicate rules on Email are built
to catch. When that rule fired, `DUPLICATES_DETECTED` rolled back the **entire transaction under the
Savepoint**, silently losing the inbound email's Task along with everything else the routing tree had
already decided. This change removes both problems structurally: a competing broker never gets a Lead,
so there is nothing to flag and nothing for a duplicate rule to reject.

### Summary

`ExtractAddressQueueable`'s branch (d) (a different broker already holds the property) and branch (e)'s
lost-race tail (a Lead was created, then a concurrent claim turned out to have won first) no longer
create or keep a Lead for the losing broker. Both now converge on the same outcome shape: a non-winning
`Competing_Broker_Submission__c` with `Source_Lead__c = null` against the winner, and the inbound
email's `Task` logged on the **winning** Lead (resolved through conversion). Branch (e)'s lost-race tail
additionally **deletes** the Lead it had already inserted, guarded by a new `ClaimOutcome.DUPLICATE_RACE`
enum member and a self-match check (`isLostRaceAgainst`) that must both agree before anything is
removed. `Lead.Is_Duplicate_Property__c` / `Duplicate_Of_Lead__c` are now LEGACY — retained for
historical rows, written by no code path. Outcome labels moved from `Competing Duplicate` (single label
for both the settled and race-recovered case) to two distinct labels, `Competing Submission` and
`Competing Submission (race)`, with the old label left un-back-filled on existing rows.

### A note on the source prompt

The change prompt handed to the implementing agent was written against a flatter, non-layered
`ExtractAddressQueueable` that owned its own `buildSubmission()` helper, its own `insert`/`delete` DML,
and returned a `RoutingResult` object — none of which exists in this repo. `ExtractAddressQueueable`'s
own class header states it "contains NO SOQL and NO DML of its own"; `buildSubmission()` is a private,
7-parameter method inside `PropertyClaimService`; and the lost-race `catch (DmlException)` lives in
`PropertyClaimService.registerWinner()`, not the queueable. The *behavior* the prompt specified was
implemented in full; the *code* was re-expressed against this repo's Service/Selector layering rather
than pasted verbatim. See `agent-output/design-requirements.md` §A/§B1 for the complete drift table if
you are ever comparing this repo's code against the original prompt text.

---

## 🔄 What Changed, and the Two Reasons (kept verbatim in code comments per the prompt's own instruction)

Both reasons are independently sufficient; neither alone was considered enough to drop the other from
the class headers:

1. **Lead-table pollution.** One junk Lead per competing broker per property, worked by nobody, and
   displayed nowhere in the app (verified during design: no list view, flexipage, compact layout, LWC,
   report, or validation rule anywhere in the repo reads `Is_Duplicate_Property__c` or
   `Duplicate_Of_Lead__c`).
2. **`DUPLICATES_DETECTED` / Savepoint rollback.** Orgs commonly run Lead duplicate rules on Email.
   Inserting a second Lead carrying the same broker's address throws `DUPLICATES_DETECTED`, and the
   surrounding Savepoint rolls back the **entire transaction** — not just the Lead insert — silently
   losing the inbound email's Task along with it. Not inserting a competing Lead removes this failure
   class structurally instead of defending against it case by case.

Both reasons are documented in the class headers of `ExtractAddressQueueable.cls` and
`PropertyClaimService.cls` under the heading "WHY A COMPETING BROKER GETS NO LEAD" / "NO LEAD IS
FLAGGED, AND NO LEAD IS TOUCHED."

---

## 🌳 The Routing Tree After the Change

`ExtractAddressQueueable.route(...)` still evaluates five branches strictly in order; only the shape of
branches (b), (d), and (e)'s tail changed:

| # | Branch | What changed |
|---|---|---|
| (a) Reply | No change. |
| (b) Repeat | **New target-resolution logic.** The prior submission's `Source_Lead__c` (if populated) is the winner's own repeat, filed on their Lead. If `Source_Lead__c` is null — a **competing** broker repeating — the repeat now falls back to `Winning_Lead__c` (the property's winner), because the competing broker has no Lead of their own to file against (see branch (d)). An audit row is still appended either way — see "Decision C-4" below. |
| (c) No-Property | No change. |
| (d) **Competing Submission** (renamed from "Duplicate") | **No Lead is created.** `PropertyClaimService.markDuplicate(existing, null, ...)` inserts a non-winning `Competing_Broker_Submission__c` with `Source_Lead__c = null`; the routed record resolves to `PropertyMatchingService.resolveLiveRecord(existing.Winning_Lead__c)`. The registry read (`findMatchingRegistry`) still runs **before** any `createLead` call — this ordering was already correct pre-change and remains load-bearing: creating the Lead first and testing for a winner second would mint an orphan Lead on every competing email. |
| (e) Winner | **Gained a lost-race tail.** `claim()` can now return `ClaimOutcome.DUPLICATE_RACE` when a concurrent submission won between this job's pre-read and its cluster lock. On that outcome, the Lead already created is **deleted** and the email is re-routed exactly like branch (d) — see "The Destructive Lost-Race Path" below. |

Outcome-label mapping (`ExtractAddressQueueable.toOutcomeLabel`):

| `ClaimOutcome` | Label | Reached from |
|---|---|---|
| `WINNER` | `New Lead (winner)` | Branch (e), no race. |
| `DUPLICATE_RACE` | `Competing Submission (race)` | Branch (e)'s lost-race tail (`routeLostRace`). |
| `DUPLICATE` | `Competing Submission` | **Reserved — unreachable from `claim()` today.** See "Known-Open Items," S3. |
| `UNCLAIMED` | `New Lead (unclaimed)` | Lock-wait timeout, or a duplicate key with neither a live winner nor an adoptable orphan. |

Branch (d) reaches the `Competing Submission` label directly (it never calls `claim()` — it already
found `existing` via the cheap pre-read), which is why the table above shows two different code paths
converging on labels that read almost identically (`Competing Submission` vs. `Competing Submission
(race)`) but are reached completely differently: one from a **read that found the winner already
settled**, the other from a **Lead that briefly existed and was removed**.

---

## 💥 The Destructive Lost-Race Path, and Its Two-Layer Guard

Branch (e) creates a Lead optimistically and then asks `PropertyClaimService.claim()` to register it.
Under the pessimistic cluster lock, `claim()` can discover that a **different** Lead already won —
genuinely concurrent with this job's own pre-read — which makes this broker a competing broker *after
the fact*, and the Lead already inserted is not a record of anything. `routeLostRace` in
`ExtractAddressQueueable.cls` then deletes it via `EmailToLeadService.deleteLead(leadId)` and re-routes
the email onto the real winner, exactly like branch (d).

Because this is a `delete` of a record that a moment ago looked entirely legitimate, the implementation
carries **two independent, stacked guards**, both of which must agree before anything is removed:

1. **`ClaimOutcome.DUPLICATE_RACE`-only.** The delete is reachable from exactly one signal —
   `claimed == PropertyClaimService.ClaimOutcome.DUPLICATE_RACE` — and never from `UNCLAIMED`. An
   `UNCLAIMED` Lead is a legitimate broker submission that merely failed to take the lock (a lock-wait
   timeout); deleting it would destroy real work. This is enforced structurally: `routeLostRace` is
   called from exactly one call site, guarded by that exact comparison.
2. **`isLostRaceAgainst` self-match check.** `PropertyClaimService.isLostRaceAgainst(winner,
   sourceLeadId)` returns true **only** when `winner.Winning_Lead__c != sourceLeadId` — i.e. a
   registration held by *someone else*. This guard exists because two different code paths can hand
   `isLostRaceAgainst` a registration the current claimant **already owns**:
   - `registerWinner`'s duplicate-value catch block: there is no Savepoint around the try block, so a
     `DmlException` on the *submission* insert does not roll back the *registry* row inserted one
     statement earlier. The catch then re-runs `findMatchingRegistry`, which can find the claimant's own
     just-committed row. Without the self-match guard, this would report a lost race, the caller would
     delete the Lead that had in fact just **won**, and the registry row would be left permanently
     orphaned.
   - `claim()`'s in-lock check, via **fuzzy** matching: a claimant re-submitting a differently-worded
     variant of a property they already registered (`'123 main street'` then `'123 main street suite
     100'`) can match their own row on a different exact key. Unreachable today through
     `ExtractAddressQueueable` (branch (e) always claims with a freshly created Lead), but `claim()` is
     public, so the guard protects any future caller too.

Both callers fall through to ordinary, non-destructive handling when `isLostRaceAgainst` returns false —
`claim()` proceeds to `registerWinner` (registering the new key is correct), and `registerWinner`'s
catch continues to orphan-adoption and, failing that, a logged `UNCLAIMED` that leaves the Lead intact.

**A third, non-code safety property is worth naming:** the winner is re-read (`findMatchingRegistry`)
**before** the delete inside `routeLostRace`, so a Lead is never removed without a live record to route
its email to. If that re-read comes back empty, the Lead is kept and reported `UNCLAIMED` — see
"Known-Open Items," S4, for the one edge case this creates. Either way the email itself is never at
risk: the raw body and every RFC header live permanently on the `Inbound_Email_Staging__c` row, which is
never deleted.

Test coverage: `ExtractAddressQueueableTest.execute_forceClaimRaceSeam_deletesTheRacersLeadAndLogsSubmissionOnWinner`
asserts the Lead count returns to its pre-test value, the specific Lead is gone, the outcome label is
`Competing Submission (race)`, and the resulting submission's `Source_Lead__c` is null (cleared by the
lookup's `SetNull` delete constraint the instant the Lead is deleted).
`PropertyClaimServiceTest.claim_duplicateValueRace_returnsDuplicateRaceAndLogsCompetingSubmission`
covers the `PropertyClaimService` half directly.

---

## 🔁 Decision C-4: A Repeat Still Appends an Audit Row

The source change prompt's own test (§5.2) asserted that a competing broker's repeat should produce **no
new submission** — only "no new Lead, Task on the winning Lead." That was deliberately **not**
implemented as written: `ARCHITECTURE.md` §1 defines `Competing_Broker_Submission__c` as the
"append-only audit trail of **every** inbound broker email that matched a property," and suppressing the
second row would silently erase the evidence that the broker chased the property twice.

Instead, `PropertyClaimService.logRepeatSubmission` is called on **every** repeat — winner or competing
broker — and `sourceLeadId` is what distinguishes the two shapes on the resulting row: populated for the
winner's own repeat, null for a competing broker's. This is why `logRepeatSubmission` is deliberately
**not** the same method as `markDuplicate`, even though as of this change neither one writes to a Lead
any more — the distinction that remains is the outcome label and the routing target, not the DML.

Test coverage: `ExtractAddressQueueableTest.execute_competingBrokerRepeats_appendsAuditRowAndFilesOnWinningLead`
asserts the audit-row count under the winner goes from 1 to 2 (not 1 to 1), both rows carry a null
`Source_Lead__c`, the Task lands on the winning Lead, and the Lead count is unchanged.

---

## 🩹 The C1 Orphan-Adoption Regression Story — Why `Winning_Lead__c != null` Is Load-Bearing

`CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail` backs repeat detection
(`PropertyMatchingService.findBrokerSubmission`). This change **removed** its
`Source_Lead__c != null` filter — a competing broker's submission legitimately has no source Lead now,
and keeping the filter would have made every one of their follow-up emails invisible to repeat
detection, turning each re-send into a brand-new competing claim forever.

Removing that filter without adding a replacement created a genuine regression, caught by a dedicated
test (`ExtractAddressQueueableTest.execute_priorSubmissionWinnerLeadDeleted_adoptsOrphanInsteadOfErroring`,
labeled `C1 regression (2026-07-31)` in its own comment header):

**Both Lead lookups on `Competing_Broker_Submission__c` are `deleteConstraint=SetNull`.** Deleting a
winning Lead — merged away, cleaned up, whatever the reason — leaves rows with **both** `Winning_Lead__c`
and `Source_Lead__c` null. With only the `Source_Lead__c != null` filter removed and nothing added in
its place, such a row would be **admitted** into repeat detection. Branch (b) would then call
`logRepeatSubmission(null, null, ...)`, whose insert trips the `Winning_Lead_Required` validation rule,
and the resulting `DmlException` kills the email outright — `Status__c = 'Error'`, no Lead, no Task, and
critically, no chance for the module's actual designed recovery (orphan adoption) to ever run, because
the email never reaches branch (e) where `registerWinner` performs that adoption.

The fix was **adding** `Winning_Lead__c != null` to the selector's `WHERE` clause in the same change that
removed `Source_Lead__c != null` — not merely dropping a filter, but swapping which invariant the query
enforces. `CompetingBrokerSubmissionSelector`'s own Javadoc states the resulting invariant plainly: every
row this method returns has a non-null `Winning_Lead__c`; `Source_Lead__c` may legitimately be null. That
invariant is what lets a deleted-winner property fall through to orphan adoption instead of being
permanently poisoned — the same mechanism the pre-existing race-safety design already relied on for a
deleted winner's `Property_Registry__c` row, now extended to keep `Competing_Broker_Submission__c`
queries consistent with it.

`CompetingBrokerSubmissionSelectorTest.selectRecentByBrokerEmail_nullWinnerRows_areExcluded` and
`selectRecentByBrokerEmail_nullSourceLeadRows_areReturned` cover the selector in isolation (both were
previously **zero-coverage** methods, per the design doc's risk register R7); the end-to-end regression
is proven by `execute_priorSubmissionWinnerLeadDeleted_adoptsOrphanInsteadOfErroring` above.

---

## 📧 Envelope-Backfill Semantics (`applyEnvelopeEmailFallback`) and Its Residual Gaps

Because a competing submission may now be the **only** record of who a broker was, `Broker_Email__c` on
`Competing_Broker_Submission__c` had to gain a fallback: `ExtractAddressQueueable.applyEnvelopeEmailFallback`
backfills `broker_email` from the envelope `From` address when both the LLM and the regex "From:" line
scrape came back blank. This runs immediately after `applyRegexFallback`, so it only ever fills what both
of those left empty, and it changes nothing on the Lead-creating paths — `EmailToLeadService` already
fell back to the same From address for `Lead.Email`, so the observable result there is identical.

**The fallback is suppressed on a manual forward.** The envelope `From` is the broker on an
**auto**-forward (a mailbox rule preserves the original sender) but is the **internal DPEG employee** on
a **manual** forward (a person hitting Fwd puts themselves in `From`). The two shapes are told apart by
the module's own tell: `EmailToLeadHandler` sets `Forwarded_By__c` to the monitored inbox when a
forwarding header proves an auto-forward, and falls back to the envelope `From` when it cannot — so
`From == Forwarded_By` means "no forwarding evidence, i.e. a manual forward," and the fallback is
suppressed in that case. The reasoning: this row is an **adjudication record** — the evidence for who
submitted a property first — and a blank field invites a human to go read the raw email, while a wrong
value silently attributes a competing broker's claim to a DPEG employee and nothing downstream would
ever flag it. Blank beats wrong here.

**Two residual gaps are explicitly accepted, not fixed, in this change** (from the method's own
Javadoc):

1. **False negative — mis-attribution still possible.** A manual forward that happens to carry an
   `X-Forwarded-For` header (e.g. forwarding a message that had already been auto-forwarded once)
   resolves `Forwarded_By__c` to the monitored inbox, so `From != Forwarded_By` and the fallback still
   fires with the employee's address.
2. **False positive — a correct address discarded.** `EmailToLeadHandler` sets `Forwarded_By__c` to the
   envelope `From` whenever no forwarding header is found at all, which covers **two** different
   situations: a manual forward (the case this suppression targets) **and** a broker emailing the
   monitored inbox directly (`From` = the broker). The two are indistinguishable at this layer, so the
   direct-email case is suppressed too, and `Broker_Email__c` is left blank even though the envelope held
   the right address — but only when the LLM and the regex fallback *also* found nothing.

A documented, deliberately-not-implemented sharpening exists for gap 2: suppress only when
`applyRegexFallback` found a "From:" line that yielded no address (positive evidence of a forward,
which a direct email does not have). Left alone because it is a behavior change written up post-review;
it would need to be raised as its own change.

**Why the backfill lives in `ExtractAddressQueueable` and not threaded downstream:** the alternative was
passing `fromAddress` as a parameter through `claim()` → `registerWinner()` / `markDuplicate()` →
`logRepeatSubmission()` → `buildSubmission()` — five signature changes to deliver one value. The
queueable is the only layer that already holds the envelope, and every downstream consumer already reads
`broker_email` from the extracted-fields map.

---

## 🗄️ Legacy Field Status

`Lead.Is_Duplicate_Property__c` and `Lead.Duplicate_Of_Lead__c` are retained, not dropped, and both
`.field-meta.xml` descriptions and inline help text are stamped "LEGACY as of 2026-07-31 — no longer
written by any code path... Retained for historical data only." FLS on `Broker_Protection_Access`
permission set is unchanged (kept, so historical records remain readable). Dropping the fields was
considered and rejected: nothing displays them (verified — no list view, flexipage, compact layout, LWC,
report, or validation rule anywhere in the repo references either field), so keeping them costs nothing,
while dropping them would be irreversible and would destroy the historical duplicate-flag record on
Leads created before this change.

`PropertyClaimService.markDuplicate` no longer contains the `update new Lead(...)` statement that used
to stamp these fields — its class header documents the removal under "NO LEAD IS FLAGGED, AND NO LEAD IS
TOUCHED (changed 2026-07-31)."

---

## ⚠️ Known-Open Items From Code Review (not fixed in this change)

| # | Item | Detail |
|---|---|---|
| W3 | ✅ **CLOSED 2026-08-03 — and it was not merely a missing test, it was a live defect.** The gap below was accepted as documentation-only risk; it was not. Because no test ever wrote a Lead lookup while the Lead was converted, nobody discovered that **the platform REJECTS that write** (`CANNOT_UPDATE_CONVERTED_LEAD`, "cannot reference converted lead"). In production, the first broker follow-up on a property whose winner had been converted threw a `DmlException` inside branch (b), the per-property catch abandoned the property, and the email landed with no audit row and no Task target — staging row `a0aiw000000OCckAAG` on `usman-dpeg`. Fixed by splitting the winner anchor across `Winning_Lead__c` / `Winning_Opportunity__c` (exactly one populated), widening `CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail` to admit both, and adding converted-winner tests at the service, selector and end-to-end levels — including a falsifiability guard that pins the platform behaviour itself. **Residual, filed separately:** `selectByWinningLead` (the LWC read path) is still Lead-only, so a converted winner's trail has no UI surface. Original text follows. **No converted-winner test of `resolveLiveRecord`.** Every test that exercises the "route to the winning Lead" path uses an unconverted Lead as the winner. `PropertyMatchingService.resolveLiveRecord`'s conversion-following behavior (Opportunity → Contact → self, in that preference order) is covered directly by its own unit tests, but no Change-1 test proves that a **converted** winner correctly redirects a competing-broker submission's Task onto the live Opportunity/Contact rather than the husk Lead. |
| W6 | **The 251-decoy reply test cannot fail.** `ExtractAddressQueueableTest.execute_replyThreadedAmong251PriorTasks_stillFindsTheCorrectThread` inserts 250 noise Tasks plus the real thread root and asserts the reply still resolves correctly. Because `TaskSelector.selectLatestByThreadOrMessageIds` filters directly on the cited Message-IDs (a targeted `WHERE ... IN` match, not a scan), the volume of unrelated noise Tasks cannot actually perturb the result — the test would pass identically with 1 decoy or 250. It documents intent but does not exercise a code path that bulk volume could break. |
| S3 | **`ClaimOutcome.DUPLICATE`'s label mapping is unreachable in practice.** `ExtractAddressQueueable.toOutcomeLabel` maps `ClaimOutcome.DUPLICATE` to `OUTCOME_DUPLICATE` (`'Competing Submission'`) to keep the mapping a total function over the enum, but no path through `PropertyClaimService.claim()` returns plain `DUPLICATE` today — every duplicate reached through `claim()` is, by construction, a lost race and returns `DUPLICATE_RACE` instead. The reserved member and its mapping exist for a future caller that claims *without* a pre-read (for which "duplicate, but nothing to clean up" would be the correct answer), but that caller does not exist yet, so this branch of `toOutcomeLabel` has no live test path. |
| S4 | **`routeLostRace`'s `winner == null` fallback reports `UNCLAIMED` after a submission was already written.** If the re-read inside `routeLostRace` comes back empty (the winner it expected has since vanished), the Lead is kept and the outcome is reported `New Lead (unclaimed)` — correct and data-preserving for the Lead. But this can occur *after* `PropertyClaimService.markDuplicate` already inserted a `Competing_Broker_Submission__c` row earlier in the same claim attempt, in which case the staging row's outcome label (`UNCLAIMED`) would not fully describe that a submission row also exists. This is a narrow, hard-to-reach window (requires the winner to disappear between the `DUPLICATE_RACE` decision and this re-read) and was accepted rather than fixed in this change. |

None of these four are deploy-blocking; the review verdict was **APPROVED WITH WARNINGS**. They are
recorded here so a future change to the routing tree, the claim engine, or the reply-thread resolver
does not have to rediscover them.

---

## 🧱 Components Changed

| Class | Layer | What changed |
|---|---|---|
| `ExtractAddressQueueable.cls` | Queueable orchestrator | `OUTCOME_DUPLICATE` value renamed `'Competing Duplicate'` → `'Competing Submission'`; added `OUTCOME_DUPLICATE_RACE = 'Competing Submission (race)'`. Branch (b): added the `Source_Lead__c ?? Winning_Lead__c` target fallback. Branch (d): registry read now runs before `createLead`, and routes through `PropertyClaimService.markDuplicate(existing, null, ...)` with no Lead created. Branch (e): new `routeLostRace` tail on `DUPLICATE_RACE`. Added `applyEnvelopeEmailFallback`. Class-header Javadoc rewritten for the new routing tree and both WHY reasons. |
| `PropertyClaimService.cls` | Service (write side) | Added `ClaimOutcome.DUPLICATE_RACE`; `claim()`/`registerWinner()` return it on both lost-race paths (in-lock check and the duplicate-value-catch re-check). `markDuplicate` no longer performs any Lead DML (`sourceLeadId` may be null). Class header, `markDuplicate`, and `ClaimOutcome` Javadoc rewritten. |
| `EmailToLeadService.cls` | Service (Lead write side) | Added `deleteLead(Id)` — the only Lead-delete method in the pipeline, scoped to the `DUPLICATE_RACE` signal only. Class header documents both the insert and (newly) the delete DML models separately, since a destructive system-mode delete does not inherit the insert's justification. |
| `PropertyMatchingService.cls` | Service (read side) | `findBrokerSubmission`: removed the `if (candidate.Source_Lead__c == null) continue;` skip — null-source rows are now matched, not ignored. Method Javadoc rewritten. |
| `CompetingBrokerSubmissionSelector.cls` | Selector | `selectRecentByBrokerEmail`: removed `Source_Lead__c != null` from `WHERE`, added `Winning_Lead__c != null` in its place (see "The C1 Orphan-Adoption Regression Story" above). Method Javadoc rewritten to state the new invariant explicitly. |

### Tests

- `ExtractAddressQueueableTest` — rewrote the "different broker" test
  (`execute_propertyAlreadyClaimedByAnotherBroker_createsNoLeadAndLogsSubmissionOnWinner`), rewrote the
  lost-race test (`execute_forceClaimRaceSeam_deletesTheRacersLeadAndLogsSubmissionOnWinner`), added the
  competing-broker-repeat test (`execute_competingBrokerRepeats_appendsAuditRowAndFilesOnWinningLead`),
  and added the C1 regression test
  (`execute_priorSubmissionWinnerLeadDeleted_adoptsOrphanInsteadOfErroring`).
- `PropertyClaimServiceTest` — rewrote the race test
  (`claim_duplicateValueRace_returnsDuplicateRaceAndLogsCompetingSubmission`) to assert
  `DUPLICATE_RACE` and the legacy flags staying unwritten.
- `PropertyMatchingServiceTest` — added direct coverage for `findBrokerSubmission` (previously
  zero-coverage): null-source match, exact-vs-fuzzy, oldest-first ordering, blank inputs.
- `CompetingBrokerSubmissionSelectorTest` — added direct coverage for `selectRecentByBrokerEmail`
  (previously zero-coverage): null-source rows returned, null-winner rows excluded, `Broker_Email__c`
  vs. `Source_Lead__r.Email` matching, cutoff window, and a `bulk251` test matching the existing
  `selectByWinningLead_bulk251_returnsAll251` convention.

The module's existing per-transaction-singleton bulk-test exemption (`.claude/rules/bulk-test-rule.md`,
`ARCHITECTURE.md` §2) still applies to all four production classes above — none of them gained a
trigger or a loop over multiple records.

---

## 📁 File Locations

| Component | Path |
|---|---|
| Queueable | `force-app/main/default/classes/ExtractAddressQueueable.cls` |
| Claim service | `force-app/main/default/classes/PropertyClaimService.cls` |
| Lead write service | `force-app/main/default/classes/EmailToLeadService.cls` |
| Matching service | `force-app/main/default/classes/PropertyMatchingService.cls` |
| Selector | `force-app/main/default/classes/CompetingBrokerSubmissionSelector.cls` |
| Test classes | `force-app/main/default/classes/{ExtractAddressQueueableTest,PropertyClaimServiceTest,PropertyMatchingServiceTest,CompetingBrokerSubmissionSelectorTest}.cls` |
| Legacy field metadata | `force-app/main/default/objects/Lead/fields/{Is_Duplicate_Property__c,Duplicate_Of_Lead__c}.field-meta.xml` |
| Outcome field metadata | `force-app/main/default/objects/Inbound_Email_Staging__c/fields/Outcome__c.field-meta.xml` |

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-07-31 | Documentation Agent | Initial creation — documents Change 1 (stop creating duplicate Leads for competing brokers): the two-reason rationale, the post-change routing tree, the destructive lost-race path and its two-layer guard, decision C-4, the C1 orphan-adoption regression, envelope-backfill semantics, legacy-field status, and the four known-open code-review items (W3, W6, S3, S4). Companion edits landed the same pass in `docs/2026-07-24-broker-protection.md`, `docs/broker-protection-architecture.md`, `docs/broker-protection-data-dictionary.md`, `docs/broker-protection-faq.md`, `docs/broker-protection-operations.md`, and `docs/broker-protection-overview.md`. |
