# TRANCHE 4 — Acquisition Call for Offers: deal matching + stamp

**Source document:** `spec-acquisition.md` lines 51–56 (`docs/DPEG-Stage-by-Stage.docx`, Part 1)
**Binding decisions:** D3 (extend the gate), D8 (claim-pipeline matching only), D9 (all notifications deferred)
**Target class:** `classes/ExtractAddressQueueable.cls` — two production incidents, five pinned governor budgets
**Date:** 2026-08-10 · **Status:** awaiting Gate 1

---

## 0. 🔴 GATE 1 — QUESTIONS WHOSE ANSWER CHANGES THE DESIGN

Nine. **Q1–Q4 change what gets built. Q5–Q9 change how much risk ships.** Every one has a
recommendation; none is a blocker if the recommendation is accepted as-is.

### Q1 — 🔴 Does the stamp apply to an unconverted Lead as well as an Opportunity? (COVERAGE)

**This is the largest question in the tranche and the brief does not raise it.**

D8 routes matching through `Property_Registry__c` → `PropertyMatchingService.resolveLiveRecord`.
That method returns `ConvertedOpportunityId` **only when the winning Lead has been converted**;
an unconverted winner comes back as the **Lead Id, unchanged** (`PropertyMatchingService.cls:454–471`).

Registry rows are created at the moment a Lead is minted — conversion happens later, only for
qualified deals. **So the majority of registry winners are unconverted Leads at any given time.**
"Opportunity only" therefore means the feature does nothing for most matched properties, and
does nothing at the point in the lifecycle where an offer deadline is most actionable (a property
you have not yet decided on).

| Option | Consequence |
|---|---|
| **(a) Opportunity only** | Literal reading of "our live deals". Smallest blast radius. **Silently inert for most matches.** |
| **(b) Opportunity + unconverted Lead** ⭐ | `Lead.Offer_Due_Date__c`, `Lead.Listing_Broker_Name__c` and `Lead.Listing_Broker_Email__c` **all already exist**, and the deployed `Offers_Due_Soon` **Lead** list view already surfaces the date. Costs one extra selector method and one extra DML statement; the best-and-final field needs a Lead twin. |

**Recommendation: (b).** The Lead half is close to free because every field and the only deployed
surface already exist, and (a) ships a feature that will look broken in UAT for reasons no test
will show. ⚠ Note (b) also makes `Offers_Due_Soon` genuinely load-bearing, which matters under D9
— see Q4.

### Q2 — 🔴 Do attachments on a matched call-for-offers email now convert to Files? (INVARIANT CHANGE)

`finish()`'s last statement is `enqueueAttachmentPersist(targets)` (`ExtractAddressQueueable.cls:1569`).
Today the U2 gate produces **no targets**, so decision 2 fires and the carrier is **released** —
zero `ContentPublication`s. The moment the branch produces a matched record Id, `targets` is
non-empty and the file job fires: up to `MAX_ATTACHMENTS = 3` publications per email, linked to
the matched deal.

🔴 **This silently repeals a stated invariant.** `ARCHITECTURE.md` names the U2 gate explicitly in
*"a gated email (D2 / U2) releases its carrier instead of enqueueing, so the pipeline's
highest-volume junk costs zero publications and leaves zero residual bytes."* This change makes
call-for-offers emails — which carry OM decks and are the module's bulkiest attachments — start
consuming a quota that has already caused one total outage.

| Option | Consequence |
|---|---|
| **(a) Let it fire** ⭐ | The OM lands on the deal, which is exactly the document the team needs at offer time. Bounded by the registry match (only claimed properties) and by `ContentPublicationBudget`'s 1,000/day breaker. |
| (b) Suppress — release the carrier on this branch regardless of targets | Preserves the invariant byte-for-byte. The OM is then recoverable only from the staging row's Notes & Attachments. |

**Recommendation: (a), with the change written into `ARCHITECTURE.md` in the same PR** so the
invariant reads "D2 releases; U2 releases only on no-match". Suppression is a one-line branch if
the user prefers (b).

### Q3 — What shape is "best-and-final", and how is it detected?

No field of any shape exists (repo-wide grep confirms the brief). Two separable sub-questions.

**Shape.** §1 rule 4 makes a past-participle/`Is_`/`Has_` name a **Boolean**, and the document
gives exactly one deadline ("The deadline is a date on the deal", singular) — so a second date
would duplicate `Offer_Due_Date__c`'s meaning with no rule for which one the deferred T-2
notification should read.
⭐ **Recommend a Checkbox, `Is_Best_And_Final__c`** on `Opportunity` (and `Lead`, if Q1 = b).
Rejected: `Best_And_Final_Date__c` (two deadlines, no precedence rule); `Best_And_Final__c` Text
(§1 rule 9 prohibition 2 — the name asserts a Boolean).

**Detection.** This is the higher-risk half.

| Option | Consequence |
|---|---|
| (a) New LLM prompt key `best_and_final` | Correct instrument, but 🔴 **any prompt edit is an arbitration change** — `broker_email` and `sent_datetime` drive claim keys and 90-day repeat detection, and a prompt rewrite has already perturbed both once. Needs regression fixtures replayed against stored `Extracted_JSON__c` before deploy. |
| **(b) Deterministic phrase test on `Subject__c` + `Raw_Body__c`** ⭐ | `'best and final'` / `'best & final'` is a term of art with near-zero false-positive rate. **Zero prompt change, zero arbitration exposure, zero callout cost, fully unit-testable.** Precedented by the class's own `SENDER_CONTAINS` deterministic pre-filter. |

**Recommendation: (b).** The prompt route can be added later from data if (b) proves to miss cases;
the reverse (unwinding a prompt change after an arbitration regression) is manual registry surgery.

### Q4 — Where does the stamped date actually surface? (D9 leaves this feature with no output)

D9 defers the T-2 notification and says *"the `Offers_Due_Soon` list view is the only surface."*
**That list view is on `Lead`, not `Opportunity`** (`objects/Lead/listViews/Offers_Due_Soon.listView-meta.xml`),
it filters `Lead.Offer_Due_Date__c`, and it explicitly **excludes `Converted` Leads**. So under
Q1 = (a) the feature would ship with **literally no surface at all** — a date written to a field
nobody looks at, with the notification deferred.

⭐ **Recommend a mirrored `Offers_Due_Soon` list view on `Opportunity`** (same 0–14 day window,
excluding `Closed Won` / `Dead/Pass`). One declarative file, no code, and it is the difference
between a shipped feature and an invisible one. This is **not** a notification and does not
contravene D9.

### Q5 — Does the stamp overwrite an existing value?

⭐ **Recommend: overwrite, per field, only when the incoming value is non-null.** A
call-for-offers deadline is a fact that *changes* ("deadline extended to Friday"), and the newest
email is the authority; fill-if-blank would freeze the first date and make an extension invisible
to the deferred T-2 notification. Never writing null mirrors U1's and `applyPropertyBlock`'s
established fill-if-present discipline.

⚠ **Named cost:** a value a human hand-edited is overwritten. Mitigation is the audit trail, not a
guard — every stamp is reconstructable from the `Inbound_Email_Staging__c` row (raw body, full
extraction, `Routed_Record_Ids__c`, outcome label). Field History Tracking would be stronger but
`Opportunity.enableHistory` is **`false`** today, so enabling it is an object-wide change on a live
standard object — offered as optional, not recommended inside this tranche.

### Q6 — Which broker is written to `Listing_Broker_Name__c` / `Listing_Broker_Email__c`?

The fields already exist on both objects and are described as *"the listing broker, often a
different person from the submitting broker"* — which on a marketed campaign is exactly the person
running it. **Reuse; add no new broker fields.**

⚠ But **do not take the U1 envelope identity here.** `ARCHITECTURE.md`'s U1 blast-platform residual
lands squarely on this branch: a call-for-offers blast is *the* traffic that arrives from
`listings@buildout.com` / RCM / Crexi, so envelope-first would write a platform address into a
field a human reads as "who do I call".
⭐ **Recommend: prefer `extraction.listingBrokerName` / `listingBrokerEmail` (read from the body
and signature block), fall back to `senderName` / `senderEmail`.** This deliberately inverts U1
**for a display field only** — U1's envelope-first rule exists for *arbitration*, and nothing on
this branch arbitrates anything.

### Q7 — Should the stamp be gated on `category_confidence`?

⭐ **Recommend: no gate.** Three reasons, and the third is the decisive one:

1. A registry match is itself strong evidence — the property is real and is already claimed by a
   live record in this pipeline. `category_confidence` guards against *misclassification*, and the
   damage from misclassification (a lost claim) is unaffected by the stamp either way.
2. A wrong date on a deal is **cheap and reversible**; a missing one is not. The asymmetry runs
   opposite to the Lead-creation decision the class header reasons about.
3. A threshold would create the "probably a call for offers, so we stamped anyway" population the
   class header already rejected once, with no data to set it from.

🔴 **If the user wants a gate anyway, gate on `category_confidence` and NEVER on `confidence`** —
`confidence` measures certainty about `is_acquisition_related`, and a call-for-offers blast *is*
acquisition-related, so it carries no discrimination here at all.

### Q8 — One outcome per matched deal, or one per email?

This decides whether a deployed list view breaks. See §5.3 — it is the subtlest defect in the
change and it has no compile error and no failing test outside this module.
⭐ **Recommend: one outcome per matched deal, AND widen the `Gated_Call_For_Offers` list-view
filter in the same deploy.**

### Q9 — Should this be split? (asked directly by the brief)

⭐ **Yes — two tranches, and the split is worth taking.** See §1.

---

## 1. 🔴 RECOMMENDED SPLIT

**4A — Declarative groundwork. Zero behaviour change, deployable and verifiable on its own.**
New field(s), FLS on the four permission sets that already carry the sibling fields, the
Opportunity-side `Offers_Due_Soon` list view, the matched-CFO list view, and the widened
`Gated_Call_For_Offers` filter. **Nothing reads or writes the new field yet.** If 4A is deployed
and read back correctly, every FLS/list-view/permission-set risk in this tranche is retired before
a single line of the riskiest class changes.

**4B — The branch. All Apex, all risk.**
`OpportunitySelector.RoutingReads`, the new `CallForOffersStampService`, the branch replacing the
`return` at `ExtractAddressQueueable.cls:829–835`, the new outcome label, and the tests.

**Why split here and not elsewhere:** the boundary is exactly the point where a failure changes
character. Everything in 4A fails **loudly** at deploy (a missing FLS grant, a bad filter value).
Everything in 4B fails **silently** — a `with sharing` read against a Private OWD returns zero rows
and is indistinguishable from "no deal matched", which is the shipped behaviour. Deploying them
together means a silent 4B failure is masked by a 4A that looks fine.

**Do not split 4B further.** The branch, the label and the service are one decision; a partial 4B
either creates an unreachable code path or an outcome label with nothing behind it.

---

## 2. 🎯 WHAT THE USER REQUESTED

> When a call-for-offers email arrives, read the property address from it and compare it against
> our live deals. On a match, take the offer due date from the email and stamp it on that deal.
> Where no deal matches, nothing is created. No stages. The broker, the best-and-final requirement
> and the email itself are held alongside the deadline. (Notification deferred — D9.)

Constrained by:
- **D3** — the U2 gate is unchanged. No Lead, no registry claim, ever, on this branch.
- **D8** — matching goes through `Property_Registry__c` only. **No address-based Opportunity query.**
- **D9** — the T-2 notification is not built. Only the match-and-stamp half ships.

---

## 3. VERIFIED PREMISE — corrections and additions to the brief

Everything in the brief's "what exists today" table checks out. Six things it does not say, all
verified against the files, and each changes the design.

**3.1 — `finish()` already does most of the work the brief lists as missing.**
`orderedTaskTargets()` (`:1717`) reads `outcomes` and drops null record Ids; `InboundEmailActivityService`
sets `WhatId` for anything that is not a Lead/Contact (`:465–478`). So **a non-null `recordId` on the
CFO `RoutingOutcome` is the entire mechanism for "the email held alongside it"** — the Task attaches,
`Result_Record_Id__c` is stamped by `primaryRecordId()`, and `Routed_Record_Ids__c` gets its audit
line. No change to `InboundEmailActivityService`, and the brief's design question 3 answers itself.

⚠ **Two consequences that are not free.** The logged Task carries `Thread_Key__c` and
`Inbound_Message_Id__c`, so it becomes a **thread anchor on the deal**: later replies in that
campaign thread will route to the Opportunity via `findRecordByReplyHeaders`, and the **EAC Thread
Adopter** will begin re-pointing captured replies' `RelatedToId` onto it. Both are arguably
desirable; both are behaviour changes on live features and belong in the UAT script.

**3.2 — 🔴 `Opportunity` OWD is UNVERIFIED, and the failure mode is silence.**
`objects/Opportunity/Opportunity.object-meta.xml:165` says `sharingModel = ReadWrite`. The RBAC
build set **28 OWDs to Private**, and standard-object OWD is not reliably round-tripped through the
Metadata API in this org — the repo copy of an org-state file has been measured contradicting the
org twice. **Treat the repo value as unproven.**

`OpportunitySelector` is `with sharing` and its header states *"No SYSTEM_MODE path"*. If Opportunity
is Private, an inbound-pipeline read of a deal owned by an acquisitions user returns **zero rows** —
which this design would report as *"no deal matched"*, the exact behaviour it is replacing. Nothing
throws, nothing logs, no test fails. This is the 2026-08-08 `InboundEmailStagingSelector` lesson
verbatim, one module later.

**3.3 — `WITH USER_MODE` would throw here regardless of OWD.**
`Broker_Protection_Access` grants **no `Opportunity` object permission of any kind** (verified —
its five `objectPermissions` blocks are the four Broker Protection objects plus `Task`), and a
Metadata-API-deployed custom field arrives with no field permissions for any profile. A
`WITH USER_MODE` read of `Offer_Due_Date__c` / `Is_Best_And_Final__c` by the pipeline principal
raises `QueryException: No such column` — the platform's way of reporting an FLS denial. This is
the textbook automation-path case in `ARCHITECTURE.md`'s SYSTEM_MODE table.

🔴 **These are TWO separate decisions and D25 is the precedent for not conflating them:** `SYSTEM_MODE`
lifts CRUD/FLS and does **not** touch sharing. Both are required.

**3.4 — Plain DML is system-mode for CRUD/FLS but not for sharing.**
The write needs the same `without sharing` treatment as the read, for the same reason. `EmailToLeadService`
and `PropertyClaimService` are both `with sharing` and get away with it only because they write objects
the pipeline principal owns. Opportunity is not one of those.

**3.5 — 🔴 The Opportunity may be LOCKED by its own approval when the email arrives.**
`Underwriting_Approval` and `LOI_Approval` both carry `recordEditability = AdminOnly`, and a deal at
Underwriting or LOI is precisely the kind of live deal a broker blasts. `SYSTEM_MODE` **does not lift
an approval lock** — measured in this repo (`OpportunityReviewService`'s LOI block), and cited three
times in the decisions file. The stamp will throw `ENTITY_IS_LOCKED` on a real and reasonably common
input. It must be fail-soft and the refusal must be recorded.

**3.6 — Existing CFO tests pin the exact label.**
Five tests assert `Outcome__c == OUTCOME_CALL_FOR_OFFERS` (`ExtractAddressQueueableTest.cls:2749,
2787, 2813, 2847, 2873`). The **no-match label must stay byte-identical**; only a new sibling label
may be added.

---

## 4. 🔵 ADMIN WORK — TRANCHE 4A (`salesforce-admin`)

Routine declarative work. No architecture decisions. Follow `.claude/rules/salesforce-global-rule.md`
(per-type skill load + `salesforce-api-context` MCP attempt before each write).

| # | Item | Detail |
|---|---|---|
| A1 | **`Opportunity.Is_Best_And_Final__c`** | Checkbox, `defaultValue false`. `<description>`: "True when the inbound call-for-offers email states a best-and-final round. Written by CallForOffersStampService from the inbound email pipeline; never set by hand as part of a process." ⚠ ≤255 chars. |
| A2 | **`Lead.Is_Best_And_Final__c`** | Identical. **Only if Gate 1 Q1 = (b).** |
| A3 | **FLS for A1/A2** | Add to exactly the four permission sets that already grant the sibling `Offer_Due_Date__c` / `Listing_Broker_Name__c`: `DPEG_Acquisitions`, `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Opportunity_View`. Read on the View sets, read+edit on the Edit sets. 🔴 **Reconcile each file against the org first** — a `PermissionSet` deploy REPLACES its whole `fieldPermissions` set and has silently wiped an org-side grant twice in this module. |
| A4 | **`Opportunity` list view `Offers_Due_Soon`** | Mirrors the Lead one: columns Name, `Property_Address__c`, `Offer_Due_Date__c`, `Is_Best_And_Final__c`, `Listing_Broker_Name__c`, `StageName`; filters `Offer_Due_Date__c >= TODAY` AND `<= NEXT_N_DAYS:14` AND `StageName notEqual Closed Won,Dead/Pass`. **Gate 1 Q4.** |
| A5 | 🔴 **Widen `Inbound_Email_Staging__c` list view `Gated_Call_For_Offers`** | Add `booleanFilter` `1 OR 2`, keeping filter 1 (`Outcome__c startsWith 'Not Routed'`) and adding filter 2 (`Outcome__c contains 'call for offers'`). **See §5.3 — without this, every multi-property call-for-offers email disappears from the only misclassification watch surface in the module.** |
| A6 | **`Inbound_Email_Staging__c` list view `Call_For_Offers_Matched`** | `Outcome__c contains 'deal updated'`. Separates the harmless matched population from the risky unmatched one, without narrowing A5's watch. |
| A7 | **Add the field(s) to the Opportunity (and Lead) page layout / Dynamic Form region** | Next to `Offer_Due_Date__c`. ⚠ **Do NOT enable Dynamic Actions on any page** — it has silently emptied three pages' action bars in this repo. Layout field placement only. |

**Not in 4A, deliberately:** no validation rule, no flow, no permission set, no notification type, no
approval change. None was requested and D9 defers every notification.

---

## 5. 🟢 DEVELOPMENT WORK — TRANCHE 4B

**Routing recommendation: `salesforce-technical-architect`, not `salesforce-developer`.** The work
is small in line count but its decisions are a sharing-model escalation, a new `SYSTEM_MODE`
automation-path justification, a new service owning the module's first Opportunity DML, and a
re-pin of governor budgets on the repo's most incident-prone class. That is CLAUDE.md's
"architectural decisions affecting multiple layers". Use `salesforce-developer` only if the user
overrides.

### 5.1 — `OpportunitySelector` — a new `private without sharing` inner class

Mirrors `LeadSelector.GuestReads` and `InboundEmailStagingSelector.RoutingReads` exactly.

```
private without sharing class RoutingReads   // name it CallForOffersReads if clearer
    selectStampTargetsByIds(Set<Id> opportunityIds)   // WITH SYSTEM_MODE
```

Selects `Id, Offer_Due_Date__c, Is_Best_And_Final__c, Listing_Broker_Name__c, Listing_Broker_Email__c`.
🔴 **Both the mode and the sharing keyword need their own justification in the method header**, and
they must be argued separately (D25: on a `with sharing` class a mode change lifts CRUD/FLS and
leaves the row filtering exactly as it was). **The outer class stays `with sharing` and every
existing `WITH USER_MODE` method is untouched** — this class backs eleven user-facing reads and
none of them may be widened.

If Q1 = (b), the Lead equivalent goes in `LeadSelector` — ⚠ **not** in `GuestReads`, which is the
guest-portal anti-abuse read and must not acquire a second purpose.

### 5.2 — New `CallForOffersStampService` (the only Opportunity writer in this module)

**Why a new service and not an existing one:** `EmailToLeadService` owns Lead DML and only Lead DML;
`PropertyClaimService` owns registry + submission DML; `ExtractAddressQueueable` holds a stated
"no SOQL and no DML of its own" invariant. A new service is the only placement that breaks none of
the three.

```
public with sharing class CallForOffersStampService {
    public class StampRequest { Id recordId; Date offerDueDate; Boolean bestAndFinal;
                                String listingBrokerName; String listingBrokerEmail; }
    public class StampResult  { List<Id> stamped; List<String> refusals; }

    public static StampResult stamp(List<StampRequest> requests)   // ONE bulk read, ONE bulk update
    private without sharing class StampWrites { ... }              // the Database.update lives here
}
```

Rules, all load-bearing:

1. **One bulk read, one bulk `Database.update(list, false)`** — constant in the number of matched
   deals, exactly as `AttachmentPersistQueueable` is constant in target count.
2. **`allOrNone = false` is mandatory**, because of §3.5. One locked deal must not roll back
   another deal's stamp, and must not roll back the claim/Task work already committed upstream.
3. **Fill-if-present per field** (Q5) — never write null over a value. Skip the record entirely when
   every incoming value is null or already equal, so a redelivery is a genuine no-op.
4. **Every `SaveResult` failure is returned in `refusals`, never swallowed.** `EmailThreadAdopterService`
   is the counter-example to avoid: its refusals live only in an in-transaction static and do not
   survive the job, which is why a total failure there is indistinguishable from "nothing needed doing".
5. `with sharing` on the class, with the write isolated in a `private without sharing` inner class —
   never `without sharing` on the whole service.

### 5.3 — `ExtractAddressQueueable` — the gate becomes a branch

Replace the `return` at `:829–835`. **The gate's own predicate `isCallForOffersGated` does not
change and its Javadoc's "no Lead, no claim" contract stays literally true.**

```
if (isCallForOffersGated(extraction)) {
    try {
        routeCallForOffers(extraction);          // ALL new work, fully contained
    } catch (Exception e) {
        routingErrors.add(describeFailure(e));   // Status__c -> 'Error', full stack in Error__c
    }
    finish();                                    // ALWAYS reached
    return;
}
```

🔴 **`finish()` must be unconditionally reachable, and this is the single most important safety rule
in the change.** If a stamp failure escaped to `execute()`'s catch at `:839`, `finish()` never runs,
the **Task is never logged, the Message-ID is never recorded**, and a platform redelivery re-runs the
entire pipeline from the top. The per-property isolation catch in `routeProperties` is the exact
precedent.

**`routeCallForOffers` does, in order:**

1. `buildWorkList(extraction.properties)` — **reuse it, do not reimplement.** It already normalizes,
   de-duplicates, derives cluster keys and caps at `MAX_PROPERTIES`. Reuse is what makes the CFO
   branch normalize addresses **identically by construction** rather than by convention — the
   `EmailThreadAnchorService` lesson.
   ⚠ Do **not** set `pendingSpillover` on this branch; it is consumed only by `createLead`, which
   never runs here.
2. Per property: `findMatchingRegistry(normalized)` → `resolveLiveRecord(winner.Winning_Lead__c)`.
   🔴 **No `Property_Claim_Lock__c` lock, no `PropertyClaimService` call, no
   `Competing_Broker_Submission__c` row.** The registry read is lock-free; taking the cluster lock
   here would put a non-claiming branch into the deadlock-ordering contract for no reason.
3. Keep only ids whose `getSObjectType()` is `Opportunity` (plus `Lead` if Q1 = b). Anything else —
   including an unconverted Lead under Q1 = (a) — is a **no-match**.
4. One `CallForOffersStampService.stamp(...)` call for the whole email.
5. One `RoutingOutcome` **per matched record** (Q8), with the matched record's Id and
   `PRIORITY_REPEAT`. *(Reuse `PRIORITY_REPEAT` — it already means "filed onto an existing record,
   no claim taken", which is precisely this branch. Do not invent a fifth priority.)*
6. If nothing matched: exactly one `RoutingOutcome(OUTCOME_CALL_FOR_OFFERS, null, null,
   PRIORITY_NO_PROPERTY)` — **byte-identical to today**, so the five existing tests and the deployed
   list view are untouched.

**New label:**

```
public static final String OUTCOME_CALL_FOR_OFFERS_MATCHED =
    'Not Routed (call for offers) — deal updated';
```

🔴 **The `'Not Routed'` prefix is mandatory** (`Gated_Call_For_Offers` filters on it) and the label
must **not** start with `'Not Acquisition'` (a different deployed view). Both couplings are already
documented at `:404–423`; the new constant needs the same warning block, and a test must pin the
prefix the way `llmDownOutcome_keepsTheSubstringItsListViewFiltersOn` pins the LLM-down substring.

🔴 **THE MULTI-PROPERTY TRAP — the subtlest defect in this change.**
`buildOutcomeSummary` (`:1798`) returns today's label verbatim only when `outcomes.size() == 1`.
Two or more outcomes produce `buildMultiSummary`, which prefixes **`'Multi-Property (N): …'`** —
which does **not** start with `'Not Routed'`. Today the CFO gate always adds exactly one outcome, so
this cannot happen. Under Q8's per-deal outcomes it happens on the first email that names two
properties, and **that email vanishes from `Gated_Call_For_Offers`** — the only surface for the
misclassification watch that D3's entire residual risk depends on. It breaks with **no compile error
and no failing test outside this module**. Admin item **A5** is the fix and it must ship in the same
deploy; a test must assert a two-property CFO email is still returned by the widened filter's predicate.

### 5.4 — Best-and-final detection (Q3 = b)

A private static in `ExtractAddressQueueable`, alongside the existing deterministic pre-filter
constants: case-insensitive `contains` over `staging.Subject__c` and `staging.Raw_Body__c` for
`'best and final'` and `'best & final'`. Email-level, not per-property — a campaign has one
best-and-final requirement even when it names several assets.
⚠ Note the raw body is a Long Text; a phrase beyond the stored length is a miss. Acceptable — the
phrase is near-universally in the first screen of a campaign email.

### 5.5 — Tests

`.claude/rules/bulk-test-rule.md`'s narrowed exemption does **not** cover this class. A literal 251
is impossible (`System.enqueueJob` caps at 50; SOQL exhausts at ~14–24 properties) and meaningless.
Required, per §7 of the original design:

| # | Test |
|---|---|
| T1 | **Volume** — a 10-property call-for-offers email, all 10 registry-matched, all 10 deals stamped, 10 Tasks. |
| T2 | **Truncation** — 15 properties, exactly 10 processed, ` [truncated: 10 of 15]` present. |
| T3 | 🔴 **Governor headroom** — new named budget, asserted on `lastRunQueryCount` / `lastRunDmlCount`, **read from the statics, never from `Limits.*` after `Test.stopTest()`** (stopTest restores the pre-test counters and makes the obvious assertion silently vacuous). |
| T4 | **Mixed outcome** — 3 properties, 1 matched / 2 unmatched: one stamp, `Outcome__c` still returned by the widened `Gated_Call_For_Offers` predicate. |
| T5 | 🔴 **No-match is byte-identical to today** — same label, no Lead, no registry row, no submission row, Task logged with no target. This is the D3 regression guard. |
| T6 | 🔴 **The five existing CFO tests still pass unmodified.** If one needs editing, the no-match path has drifted — fix the code, not the test. |
| T7 | **Locked deal** — stamp refused, `Status__c = 'Error'`, `Error__c` names the record, **`finish()` still ran and the Task exists**. The §3.5 guard. |
| T8 | **Idempotency** — the same email replayed writes zero DML on the second pass (Q5's no-change skip). |
| T9 | **Unconverted-Lead winner** — behaves per the Q1 answer, asserted explicitly either way. |
| T10 | **Label prefix pin** — `OUTCOME_CALL_FOR_OFFERS_MATCHED.startsWith('Not Routed')` and `!startsWith('Not Acquisition')`. |

⚠ `CallForOffersStampServiceTest` must **not** assert committed state for the `without sharing`
read under `System.runAs` — an FLS/sharing test in this repo has already been shown to be unfalsifiable
(`fls-is-a-display-gate-on-system-mode-writes`). Assert the **decision** (which ids, which values)
through the service's `StampResult`, and put the sharing proof in the post-deploy gates.

---

## 6. 📊 GOVERNOR BUDGET IMPACT — stated numerically

**Existing pinned budgets and what happens to them:**

| Budget | Value | Effect |
|---|---|---|
| `ExtractAddressQueueableTest.QUERY_BUDGET` (N=10 winner path) | ≤ 120 | **Unchanged** — the CFO branch returns before `routeProperties`. |
| `ExtractAddressQueueableTest.DML_BUDGET` (N=10 winner path) | **= 43 exact** | **Unchanged** — same reason. Must stay 43. |
| `singlePropertyQueryBudget` / `singlePropertyDmlBudget` | ≤ 30 / ≤ 20 | **Unchanged.** |
| `execute_singlePropertyWinner_dmlBudgetIsExactlySeven` | **= 7 exact** | **Unchanged.** |
| **The gated path** | **not pinned today** | 🔴 **New budget required.** No existing assertion covers it, so nothing would catch a per-property query creeping in. |

**Delta on the new branch, per email:**

| Source | Queries | DML |
|---|---|---|
| `findMatchingRegistry` per property — 1 exact key lookup, plus 1 fuzzy 90-day scan on a miss | **≤ 2 × N** | 0 |
| `resolveLiveRecord` per registry hit | **≤ 1 × N** | 0 |
| `OpportunitySelector.RoutingReads.selectStampTargetsByIds` — **once, bulk** | **1** | 0 |
| `LeadSelector` equivalent (only if Q1 = b) — once, bulk | **+1** | 0 |
| `CallForOffersStampService` `Database.update` — **once, bulk** | 0 | **1** |
| Lead `Database.update` (only if Q1 = b) — once, bulk | 0 | **+1** |

**Worst case at N = `MAX_PROPERTIES` = 10, all matched, Q1 = (b): +32 SOQL, +2 DML.**
Against async caps of 200 / 150, and on a path whose current consumption is single digits.

⭐ **Recommended new pinned budgets: `CFO_QUERY_BUDGET = 60`, `CFO_DML_BUDGET = 8`** (ceilings, both
comfortably above worst case and well below the caps), asserted in T3.

⚠ **The dominant cost is `findMatchingRegistry`'s fuzzy branch** — a full 90-day registry scan, once
per unmatched property. Branch (d) already pays this, so it is not new, but a 10-property blast pays
it ten times. 🔴 **If T3 or UAT shows the budget under pressure, the fix is a transaction-scoped memo
of `PropertyRegistrySelector.selectRecentWithWinner`, NOT raising the budget** — and that change
touches the claim path, so it is a separate design, not a patch inside this one.

---

## 7. 🔗 EXECUTION ORDER

1. **Gate 1** — answer Q1–Q9. **Q1 and Q3 determine which files 4A creates**, so nothing can start first.
2. **4A** — `salesforce-admin`. Fields → FLS (org-reconciled) → list views (A4, A5, A6) → layout.
3. **4A deploy + post-deploy gates G1–G4.** Stop here if any fail.
4. **4B** — `salesforce-technical-architect`. Selector inner class → service → branch → label → tests.
5. **`salesforce-unit-testing`** — T1–T10 plus `CallForOffersStampServiceTest`.
6. **`salesforce-code-review`** — focus areas in §9.
7. **4B deploy + post-deploy gates G5–G9.**
8. **`salesforce-documentation`** — plus the mandatory `ARCHITECTURE.md` edits in §8.

**Dependency notes:** A5 (list-view widening) must be **deployed before or with** the branch that can
produce a multi-property outcome — deploying 4B first leaves a window in which matched emails are
invisible to the watch view. A1/A2 must exist before the selector compiles.

---

## 8. 📝 `ARCHITECTURE.md` EDITS REQUIRED IN THE SAME PR (§6 mandate)

Not optional; each records a decision a future reader would otherwise reverse.

1. **§2 Key Apex Services** — add the `CallForOffersStampService` row, naming it as **the only
   Opportunity writer in the Broker Protection module** and stating the fail-soft + approval-lock
   reasoning.
2. **§2 `WITH SYSTEM_MODE` automation-path table** — add a row for
   `OpportunitySelector.RoutingReads`, noting the **sharing question is separate** and was answered
   separately. Update the running count (22 → 23/24 across 13 → 14 classes).
3. **§2 INTAKE RULES V2, rule U2** — amend to "produces no Lead and no claim; **may now stamp a
   matched live deal**", explicitly reaffirming that the *suppression* is unchanged (D3).
4. **File-pipeline note (5)** — 🔴 amend *"a gated email (D2 / U2) releases its carrier"* to
   "D2 always releases; U2 releases **only on no-match**", per Q2.
5. **§1 `Inbound_Email_Staging__c`** — note that `Outcome__c` now carries a second `'Not Routed'`
   label and that `Gated_Call_For_Offers` is an OR filter.

---

## 9. ✅ POST-DEPLOY GATES

Job instances, org-wide sharing defaults, FLS and list-view behaviour are **not** provable from a
green test run. Every gate below is a read-back, not a "the deploy succeeded".

| # | Gate | After |
|---|---|---|
| **G1** | 🔴 **Read `Opportunity` OWD out of the org** (Setup → Sharing Settings, or `sf data query` on `EntityDefinition`). **Repo says `ReadWrite`; the RBAC build set 28 objects to Private and this file is not a reliable record of org state.** The whole feature's failure mode depends on the answer. | 4A |
| **G2** | Query the new field back with the Metadata/Tooling API and confirm it exists **with FLS on all four permission sets** — a permission-set deploy REPLACES its grant list, so verify what landed, not what was sent. | 4A |
| **G3** | Open the Opportunity `Offers_Due_Soon` list view **as an acquisitions persona, not as an admin** (a bare System Administrator has no FLS on Metadata-API-deployed custom fields). | 4A |
| **G4** | Confirm `Gated_Call_For_Offers` still returns every historical row it returned before A5 — the OR widening must be additive. | 4A |
| **G5** | 🔴 **End-to-end as the pipeline principal, not as an admin.** Send a real call-for-offers email naming a property that has a registry row whose winner is a **converted** Lead. Verify: deal stamped, Task on the deal, staging `Outcome__c` = the matched label, **no Lead created, no `Property_Registry__c` row created, no `Competing_Broker_Submission__c` row created**. | 4B |
| **G6** | Repeat G5 against an **unmatched** address. Verify `Outcome__c` is byte-identical to the pre-change label and the row appears in `Gated_Call_For_Offers`. | 4B |
| **G7** | 🔴 Repeat G5 against a deal that is **pending approval** (`recordEditability = AdminOnly`). Verify the stamp is refused, `Status__c = 'Error'`, `Error__c` names the record, **and the Task exists** — i.e. `finish()` ran. | 4B |
| **G8** | Send a **two-property** call-for-offers email and confirm the staging row is still returned by `Gated_Call_For_Offers` (the §5.3 trap). | 4B |
| **G9** | Send a matched call-for-offers email **carrying an attachment** and confirm the Q2 answer holds — files linked to the deal (if Q2 = a) or carrier released with a note (if Q2 = b), and `ContentPublication` consumption is what was intended. | 4B |

---

## 10. ⚠ THE DEFERRED HALF — stated so it is a known gap, not a silent one (D9)

The T-2-day notification (spec line 56) is **not built**. What it would need, so the gap is priced:

- **A daily Scheduled Flow or `Schedulable`** querying `Opportunity WHERE Offer_Due_Date__c = TODAY + 2`
  (`BrokerCheckInReminderSchedulable` is the nearest precedent). 🔴 **A deploy that does not schedule
  it silently disables the whole notification** — job instances are not deployable metadata, exactly
  like `RoutingRetrySweepSchedule`.
- 🔴 **An unresolved recipient question that D9 explicitly parks:** the document says *"Acquisition
  queue"*, but `queues/Acquisition` (a Queue) and `groups/Acquisitions_Team` (a public group) are
  **different objects in this org**, and every `GroupNotifier` flow in the repo takes a **group**
  name. This must be settled before anything is built.
- The `Acquisitions_Deal_Update` notification type exists but its **desktop/mobile delivery is org
  and per-user state**, not repo state.
- Under Q1 = (b) the notifier would need to cover **Leads as well as Opportunities**, or half the
  stamped population is never announced.

**Until it is built, the only surface is a list view a human must choose to open** (Q4). That is the
whole of D9's stated consequence for this feature, and it is why A4 is recommended rather than optional.

---

## 11. 📝 PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR `salesforce-admin` (Tranche 4A)

```
Read ARCHITECTURE.md §1 (naming rules 4 and 9) and .claude/rules/salesforce-global-rule.md
before writing anything. Create metadata files only — DO NOT DEPLOY.

Build ONLY these items, exactly as specified. Add nothing else — no validation rules, no
flows, no permission sets, no notification types, no approval changes.

1. force-app/main/default/objects/Opportunity/fields/Is_Best_And_Final__c.field-meta.xml
   Checkbox, defaultValue false, label "Best and Final". <description> under 255 chars:
   "True when the inbound call-for-offers email states a best-and-final round. Written by
   CallForOffersStampService from the inbound email pipeline; not set by hand as part of a
   process." Boolean naming follows ARCHITECTURE.md §1 rule 4 (Is_ prefix) — do not rename.

2. [ONLY IF GATE 1 Q1 = (b)] The identical field on Lead:
   force-app/main/default/objects/Lead/fields/Is_Best_And_Final__c.field-meta.xml

3. FLS for the field(s) in EXACTLY these four permission sets, which are the ones that already
   grant the sibling Opportunity.Offer_Due_Date__c / Listing_Broker_Name__c:
     DPEG_Acquisitions, DPEG_Acquisition_Edit  -> readable + editable
     DPEG_Acquisition_View, DPEG_Opportunity_View -> readable only
   CRITICAL: a PermissionSet deploy REPLACES that file's entire <fieldPermissions> set. Before
   editing any of the four, retrieve the org's current copy and reconcile — an org-side-only
   grant absent from the file is destroyed on deploy. This has caused two incidents in this
   module (see the XML comment in Broker_Protection_Access.permissionset-meta.xml).

4. force-app/main/default/objects/Opportunity/listViews/Offers_Due_Soon.listView-meta.xml
   Mirror objects/Lead/listViews/Offers_Due_Soon.listView-meta.xml.
   Columns: NAME, Property_Address__c, Offer_Due_Date__c, Is_Best_And_Final__c,
            Listing_Broker_Name__c, OPPORTUNITY.STAGE_NAME
   Filters: Offer_Due_Date__c greaterOrEqual TODAY
            Offer_Due_Date__c lessOrEqual NEXT_N_DAYS:14
            OPPORTUNITY.STAGE_NAME notEqual "Closed Won,Dead/Pass"
   filterScope Everything. Label "Offers Due Soon".

5. CRITICAL — widen the EXISTING view
   objects/Inbound_Email_Staging__c/listViews/Gated_Call_For_Offers.listView-meta.xml
   Keep the existing filter (Outcome__c startsWith "Not Routed") as filter 1.
   Add filter 2: Outcome__c contains "call for offers".
   Add <booleanFilter>1 OR 2</booleanFilter>.
   WHY, and do not skip it: ExtractAddressQueueable.buildOutcomeSummary prefixes a
   multi-result outcome with "Multi-Property (N):", which does NOT start with "Not Routed".
   Once the new branch can emit one outcome per matched deal, a two-property call-for-offers
   email drops out of this view entirely — and this view is the ONLY surface for the
   misclassification watch the whole feature's residual risk depends on. It fails with no
   compile error and no failing test.
   Do NOT remove or narrow filter 1; the widening must be purely additive.

6. objects/Inbound_Email_Staging__c/listViews/Call_For_Offers_Matched.listView-meta.xml
   Same columns as Gated_Call_For_Offers. One filter: Outcome__c contains "deal updated".
   Label "Call for Offers: Matched".

7. Add Is_Best_And_Final__c to the Opportunity page layout (and Lead layout if built),
   immediately after Offer_Due_Date__c.
   DO NOT enable Dynamic Actions on any page — doing so silently empties that page's whole
   action bar, which has already happened three times in this repo.

API version 67.0. Package dir force-app/main/default. Do not deploy.
```

### ⚫ PROMPT FOR `salesforce-technical-architect` (Tranche 4B)

```
Read first, in this order: ARCHITECTURE.md §2 (Broker Protection sections, the staging model,
INTAKE RULES V2, and the WITH SYSTEM_MODE automation-path table), the class header of
classes/ExtractAddressQueueable.cls, and agent-output/design-requirements-call-for-offers.md
(this design) sections 3, 5 and 6.

Build the call-for-offers deal-matching branch. Create files only — DO NOT DEPLOY.

BINDING CONSTRAINTS — these are user decisions, not suggestions:
* D3 — ExtractAddressQueueable.isCallForOffersGated is UNCHANGED. A call-for-offers email must
  NEVER create a Lead and NEVER take a Property_Registry__c claim. Do not remove or weaken the
  gate; convert the `return` at :829-835 into a branch that still returns.
* D8 — match ONLY through Property_Registry__c -> PropertyMatchingService.findMatchingRegistry
  -> resolveLiveRecord. DO NOT build an address-based Opportunity query. There is none in this
  application and adding one to this class is explicitly out of scope.
* D9 — build NO notification of any kind. No scheduled flow, no Schedulable, no custom
  notification. The match-and-stamp half only.

WORK:

1. OpportunitySelector — add a `private without sharing` inner class holding ONE method,
   selectStampTargetsByIds(Set<Id>), WITH SYSTEM_MODE, selecting Id, Offer_Due_Date__c,
   Is_Best_And_Final__c, Listing_Broker_Name__c, Listing_Broker_Email__c.
   The outer class stays `with sharing`; every existing WITH USER_MODE method is untouched.
   Justify the MODE and the SHARING KEYWORD SEPARATELY in the method header — they answer
   different questions and conflating them is the D25 mistake:
     - MODE: Broker_Protection_Access grants NO Opportunity permission at all, and a
       Metadata-API-deployed custom field arrives with no FLS for any profile including System
       Administrator, so WITH USER_MODE throws QueryException ("No such column") for the
       pipeline principal.
     - SHARING: Opportunity OWD is UNVERIFIED (the repo file says ReadWrite; the RBAC build set
       28 objects to Private and standard-object OWD is not reliably in source). If it is
       Private, a `with sharing` read returns ZERO ROWS and the feature reports "no deal
       matched" — failing as silence, which is the exact 2026-08-08
       InboundEmailStagingSelector.RoutingReads incident. Model this on
       LeadSelector.GuestReads.
   [ONLY IF GATE 1 Q1 = (b)] the same for Lead, in LeadSelector — in a NEW inner class, NOT in
   GuestReads, which is the guest-portal anti-abuse read and must not gain a second purpose.

2. NEW class CallForOffersStampService — `with sharing`, the ONLY Opportunity writer in this
   module. Public: stamp(List<StampRequest>) returning StampResult {stamped, refusals}.
   - ONE bulk selector read, ONE bulk Database.update(list, false). Constant in the number of
     matched deals.
   - allOrNone MUST be false: an Opportunity pending Underwriting_Approval or LOI_Approval is
     LOCKED (recordEditability = AdminOnly) and the update throws ENTITY_IS_LOCKED.
     AccessLevel.SYSTEM_MODE does NOT lift an approval lock — measured in this repo, see
     OpportunityReviewService's LOI block. One locked deal must not roll back another's stamp
     or the upstream Task.
   - Fill-if-present per field: never write null over a value; skip a record entirely when
     nothing would change, so a redelivery is a true no-op.
   - Every SaveResult failure goes into `refusals`. Do NOT swallow them into a static that
     dies with the transaction (the EmailThreadAdopterService.lastRunFailureCodes shape).
   - The Database.update lives in a `private without sharing` inner class; never make the whole
     service `without sharing`.

3. ExtractAddressQueueable — replace the return at :829-835:
       if (isCallForOffersGated(extraction)) {
           try { routeCallForOffers(extraction); }
           catch (Exception e) { routingErrors.add(describeFailure(e)); }
           finish();
           return;
       }
   MOST IMPORTANT RULE IN THE CHANGE: finish() must be unconditionally reachable. If a stamp
   failure escaped to execute()'s catch, finish() never runs, the Task is never logged, the
   Message-ID is never recorded, and a platform redelivery re-runs the whole pipeline.

   routeCallForOffers:
     a. REUSE buildWorkList(extraction.properties) — do not reimplement normalization. Do NOT
        set pendingSpillover (only createLead consumes it, and no Lead is created here).
     b. Per property: findMatchingRegistry -> resolveLiveRecord. NO Property_Claim_Lock__c lock,
        NO PropertyClaimService call, NO Competing_Broker_Submission__c row.
     c. Keep only Opportunity ids [plus Lead ids if Q1 = (b)]. Anything else is a no-match.
     d. ONE CallForOffersStampService.stamp() call for the whole email.
     e. One RoutingOutcome per matched record, carrying that record's Id and PRIORITY_REPEAT.
        Do not invent a fifth PRIORITY_* constant.
     f. No match -> exactly one RoutingOutcome(OUTCOME_CALL_FOR_OFFERS, null, null,
        PRIORITY_NO_PROPERTY) — BYTE-IDENTICAL to today.

   New constant:
     OUTCOME_CALL_FOR_OFFERS_MATCHED = 'Not Routed (call for offers) - deal updated';
   with a warning block matching the one at :404-423: the 'Not Routed' prefix is required by the
   Gated_Call_For_Offers list view and the label must NOT start with 'Not Acquisition' (a
   different deployed view).

   Broker fields on the stamp: prefer extraction.listingBrokerName / listingBrokerEmail, falling
   back to this.senderName / this.senderEmail. This deliberately inverts U1's envelope-first rule
   FOR A DISPLAY FIELD ONLY — U1 exists for arbitration, and nothing here arbitrates. The reason
   is U1's own documented blast-platform residual: a call-for-offers blast is exactly the traffic
   that arrives from listings@buildout.com, and envelope-first would write a platform address into
   a field a human reads as "who do I call". Comment this at the call site.

   Best-and-final: [PER GATE 1 Q3] a private static, case-insensitive contains over
   staging.Subject__c and staging.Raw_Body__c for 'best and final' / 'best & final'. Email-level,
   not per-property. DO NOT change LLMExtractionCalloutService's prompt — a prompt edit is an
   arbitration change (broker_email and sent_datetime drive claim keys and 90-day repeat
   detection) and is explicitly out of scope for this tranche.

4. GOVERNOR BUDGETS. The existing pinned budgets (43 exact / 7 exact / 120 / 30 / 20) are on the
   winner path and MUST NOT MOVE — the CFO branch returns before routeProperties. Add a NEW
   named budget for the gated path (recommended ceilings: 60 SOQL, 8 DML) and assert it on
   ExtractAddressQueueable.lastRunQueryCount / lastRunDmlCount, read from the statics INSIDE the
   async context — never from Limits.* after Test.stopTest(), which restores the pre-test
   counters and makes the assertion silently vacuous.

Follow ARCHITECTURE.md §2 layering strictly: all SOQL in selectors, DML in the service, the
queueable keeps its "no SOQL and no DML of its own" invariant. API 67.0. Do not deploy.
```

### 🟡 PROMPT FOR `salesforce-unit-testing`

```
Write tests for CallForOffersStampService and extend ExtractAddressQueueableTest, per §5.5 of
agent-output/design-requirements-call-for-offers.md (T1-T10).

Use TestDataFactory. Read .claude/rules/bulk-test-rule.md FIRST — its narrowed exemption does
NOT cover ExtractAddressQueueable. A literal 251 is impossible here (enqueueJob caps at 50 and
SOQL exhausts at ~14-24 properties) and testing a volume production cannot reach is the exact
anti-pattern that rule exists to prevent. The replacements are volume (10 properties),
truncation (15 -> 10), governor headroom, mixed outcome, and idempotency.

Non-negotiable:
* Assert governor counters on ExtractAddressQueueable.lastRunQueryCount / lastRunDmlCount, NOT
  on Limits.* after Test.stopTest().
* T5 and T6 are the D3 regression guard: the no-match label must stay byte-identical and the
  five existing callForOffers_* tests must pass UNMODIFIED. If one needs editing, the no-match
  path has drifted — report it rather than editing the test.
* T7 must prove finish() still ran after a refused stamp (the Task exists).
* Do NOT write a System.runAs FLS test against the SYSTEM_MODE selector — a system-mode write
  cannot be made to fail that way in this org, so the test would be unfalsifiable. Assert the
  DECISION through StampResult and leave the sharing proof to post-deploy gates G1/G5.
```

### 🟣 FOCUS AREAS FOR `salesforce-code-review`

```
1. Is finish() unconditionally reachable on every path through the new branch? (The whole
   redelivery-idempotency contract rests on it.)
2. Does the no-match path produce a byte-identical Outcome__c to the pre-change label?
3. Is the SHARING keyword justified separately from the SYSTEM_MODE mode, on both the read and
   the write? (D25 is the precedent for getting this wrong.)
4. Is Database.update allOrNone = false, and are refusals recorded durably rather than in a
   transaction-scoped static?
5. Does the multi-property case still satisfy the widened Gated_Call_For_Offers filter?
6. Are the four existing pinned governor budgets untouched, and is the new one asserted from the
   in-async statics?
7. Is there any path on which a Lead, a Property_Registry__c row, a Competing_Broker_Submission__c
   row, or a Property_Claim_Lock__c lock can be created on this branch? (There must be none.)
```
