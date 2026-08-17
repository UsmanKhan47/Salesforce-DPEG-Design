# 📋 DESIGN REQUIREMENTS — DPEG Acquisitions FSD Gap Closure, Tranche 3

**Branch:** `feature/acquisitions-fsd-tranche-1` (as instructed — tranche 3 continues on the tranche-1 branch)
**Source:** `docs/DPEG Acquisitions Module Revised FSD v2_0.docx` §3, §11.1, §12, §25.2.2, §27.1, §27.3, §27.4, ACQ-03
**Verified against:** repo @ 2026-08-17, after tranches 1 and 2 landed and deployed to `usman-dpeg`. `ARCHITECTURE.md`, `CLAUDE.md`, `.claude/rules/*` and both prior tranche designs read first.
**Scope:** requirements only. No implementation files written.

> ⚠ **INFORMATION GAP, STATED UP FRONT.** This agent has no shell, so `docs/DPEG Acquisitions Module Revised FSD v2_0.docx` is unreadable (binary). The FSD wording is taken from the brief and treated as authoritative, as instructed. Everything else below is verified against the repo, which is exhaustive.

---

## 🔴 PARALLEL-SESSION COLLISION MAP — READ THIS BEFORE SCHEDULING ANY OF IT

A second session is building the **deal portfolio** feature (`Property_Package__c`, FSD §11.1 / §14.2) in this same tree. That work is out of scope here and is not designed. But it has **already edited files this tranche needs**, and the overlap is not uniform — it decides the build order.

| File the parallel session has already touched | Which of my items collides |
|---|---|
| `OpportunitySelector.cls` (new `selectPackageAnchorById`, ~line 444) | 🔴 **Item 4** — hard blocker, see P11 |
| `LeadSelector.cls`, `LeadFunnelController.cls`, `lwc/recentLeads` | Item 3 (adjacent), Item 2 (none) |
| `ExtractAddressQueueable.cls`, `EmailToLeadService.cls`, `LeadConvertService.cls` | 🔴 **Item 3** — direct; **Item 1 avoids these by design** |
| `Lead_Record_Page.flexipage`, `Opportunity_Record_Page.flexipage` | 🔴 **Item 3**, ⚠ Item 4 |
| `Broker_Protection_Access`, `DPEG_Acquisition_View`, `DPEG_Acquisition_Edit` | 🔴 **Item 3**, ⚠ Items 1/4 (FLS) |
| `Property__c`, `Opportunity`, `Lead` — new `Property_Package__c` field on each | — |

**Consequences, by item:**

| Item | Collision | Verdict |
|---|---|---|
| **1 — claim expiry** | **NONE.** `PropertyClaimService`, `PropertyMatchingService`, `PropertyRegistrySelector` are all untouched by the parallel session. | ✅ **Build first, independently.** The design below deliberately keeps the whole change inside those three classes and out of `ExtractAddressQueueable` — see §1.4. That is not a coincidence; it is why that shape was chosen. |
| **2 — broker leaderboard** | Contact FLS + `Broker_Hub` flexipage only. Low. | ✅ Build in parallel. |
| **3 — Lead AI fields** | 🔴 **Highest in the tranche.** Touches Lead fields, `Lead_Record_Page`, and all three permission sets the other session is editing. | ⚠ **Sequence LAST, or defer.** See Q3 and the flagged section. |
| **4 — stalled deals** | 🔴 **Hard blocker on `OpportunitySelector`.** | 🚦 **Gated — see P11.** |
| **5 — CFO cadence** | None. | 🚩 **Recommend NO CHANGE — the item closes as already satisfied.** |

---

## 🔴 PREMISE CORRECTIONS — READ BEFORE PRICING ANYTHING

Eleven statements in the brief were checked against the code. Four of them change the shape of Item 1 outright, and two remove work.

| # | Brief said | Repo says | Consequence |
|---|---|---|---|
| **P1** | `Lead.BP_Expiry__c` is a formula and **"NOTHING references it"** — no Apex, no flow, no list view, no report. | ⚠ **Half true, and the wrong half.** No *logic* consumes it — correct. But it is rendered on **`flexipages/Lead_Record_Page`** (line 351), on **`compactLayouts/Lead_Highlights`** (so it is in the Lead highlights panel), and carries FLS in **`DPEG_Acquisition_View` + `DPEG_Acquisition_Edit`**. | It is not dead, it is **decorative and live**. Users read it today. Retiring it is a flexipage + compact-layout + two-permission-set change, not a delete — and any expiry rule that disagrees with what that field displays creates a visible contradiction on the record page. |
| **P2** | 🔴 A claim never expires. | ❌ **THE 90-DAY WINDOW IS ALREADY HALF-LIVE, AND WHICH HALF YOU GET DEPENDS ON HOW THE BROKER TYPED THE ADDRESS.** `PropertyMatchingService.LOOKBACK_DAYS = 90` already windows **two** of the three claim reads: the FUZZY registry match (`selectRecentWithWinner(now − 90)`, line 231) and REPEAT detection (`selectRecentByBrokerEmail(…, now − 90)`, line 335). Only the EXACT key path — `selectByPropertyKeyWithWinner` — has no date filter at all. | On day 91, same property: **identical wording → the incumbent keeps it for ever; different wording → the new broker wins outright** and a SECOND registry row is minted on a different `Property_Key__c`. This is not "add an expiry"; it is **"make the exact path agree with the two windows already in the same class."** It also means the feature is partly a **defect fix**, and the defect currently favours whoever writes addresses inconsistently. |
| **P3** | 🔴 The hard part is re-pointing the existing registry row. | ✅ Correct — **and `PropertyClaimService`'s own class header PROHIBITS IT BY NAME.** Verbatim: *"🔴 **THE PROHIBITION: DO NOT ADD A THIRD.** Any future `update` of a registry row that is merely LIVE (a 'last touched' stamp, a status field, a re-key, a merge/cleanup tool) would be updating a row whose lookup may hold a converted Lead — and the platform may reject the whole DML over a lookup the update never touched. That would fail on exactly the long-running, successful properties, which is the population least likely to appear in a test fixture."* The header then names the remedy: *"this object needs the same split anchor the submission just received."* | The brief's hardest question and its riskiest one are **the same question**. This is what makes the converted-winner decision (Q1) load-bearing rather than a nicety: **"a converted winner's claim does not expire" is the only reading under which the re-point never touches a prohibited row**, and it therefore costs zero new fields, zero split-anchor logic, zero VR change. See §1.3. |
| **P4** | 🔴 Implied: adding a recency filter to the exact-match read is the mechanism. | ❌ **A DATE FILTER ALONE MAKES THE PROPERTY PERMANENTLY UNCLAIMABLE BY ANYONE.** Traced through the live code: `findMatchingRegistry` returns null (expired) → not a lost race → `registerWinner` inserts → **`DUPLICATE_VALUE`** (the expired row still holds the unique key) → catch re-runs `findMatchingRegistry`, still null → `findOrphanedRegistry` filters `Winning_Lead__c = null`, and the expired row **has** a winner, so it is not an orphan → falls through to the logged `UNCLAIMED` return. The new broker gets a Lead with **no claim**, and the key can never be claimed again by anyone. | Expiry requires a **third adoption leg** inside `registerWinner`'s duplicate catch, not a `WHERE` clause. Anyone who ships only the filter ships a silent, permanent claim sink. |
| **P5** | Does `Registered_DateTime__c` reset on re-claim? | ✅ **Already answered in the repo, by working code.** `registerWinner`'s ORPHAN-ADOPTION leg already writes `Registered_DateTime__c = Datetime.now()` (plus `Normalized_Address__c`) when it adopts a row. | The field already means *"when the CURRENT winner claimed it"*, and both the fuzzy lookback and repeat detection already read it that way. **Yes, it resets — and the expiry adoption must be byte-identical to the orphan leg** so the two cannot acquire different semantics. |
| **P6** | `CallForOffersAlertBatch` fires at **7, 3 and 1** days. | ❌ `CallForOffersService.ALERT_INTERVALS = {7, 3, 1, 0}` — **four rungs, including day-of (0)**. | The FSD's *"default proposed at 2 days"* is **bracketed** by the built 3 and 1 rungs. The requirement is already over-satisfied; see Item 5. |
| **P7** | The six Contact broker-stat fields are read by "the Disposition broker hub". | ⚠ `BrokerController`'s own header: *"Read-only data provider for the Broker Hub Lightning page (**Acquisitions**)."* Two flexipages exist: `Broker_Hub` and `Broker_Scorecard`. | The leaderboard **already has a home page** and needs no new one. |
| **P8** | The Contact fields are *"all plain Number fields that NOTHING writes."* | ✅ **Confirmed** by repo-wide grep: every non-test reference is a read (`BrokerController`, `ContactSelector`). Zero writers in Apex, zero in Flow. | Correct as stated — and see §2.2 for why they must stay that way rather than becoming the leaderboard's storage. |
| **P9** | Item 3's raw email lives on `Inbound_Email_Staging__c`. | ✅ **`Raw_Body__c` (LongText 131072) + `Subject__c` — the FSD's "subject and body only" verbatim.** ⚠ But `Result_Record_Id__c`, the only link back to the Lead, is **`Text(18)` with `externalId = false`** — i.e. **not indexed**. And a second copy of the same content already exists on the Lead's own timeline: `InboundEmailActivityService` writes a `From:` / `Subject:` / rule header block plus the raw body into `Task.Description`. | Nothing is missing; it is **unlinked**, and the link field is non-selective against a table that grows with every inbound email. See §3.3. |
| **P10** | Precedent to copy: `Lease_Inquiry_Stage_Timer`. | ✅ Correct shape — `Stage_Start_Date__c` (Date) stamped by a **before-save** flow on `ISNEW() \|\| ISCHANGED(Stage__c)`, read by a `Days_In_Stage__c` formula. ⚠ **But that formula is declared `formulaTreatBlanksAs = BlankAsZero` while its body returns `null` for a blank start date.** | Copy the **mechanism**, not the blank handling. `BlankAsZero` is the exact defect ARCHITECTURE records for `Days_On_Market__c`: an unset date reads **0 for ever, not null** — a clock that looks healthy and never ticks, and a deal that is permanently invisible to the alert. Use `BlankAsBlank`. |
| **P11** | 🔴 `OpportunitySelector.cls` cannot deploy from this tree. | ✅ **Confirmed.** `selectPackageAnchorById` (~line 444) selects `Opportunity.Property_Package__c`, absent from the org. | **Item 4's batch locator must live in `OpportunitySelector`** (`.claude/rules/apex-layering-rule.md`: all SOQL for an object in one selector). ⚠ **Do not "solve" this by inventing an `OpportunityAlertSelector`** — that is a rule violation bought to dodge a scheduling problem. Item 4 is **gated behind the parallel session's field deploy.** |

---

## 🎯 WHAT THE USER REQUESTED

Five FSD gap-closure items, requirements only. Nothing beyond them is proposed; findings outside them are listed in one place at the end and are **not** folded into the build.

---

# ITEM 1 — The broker-protection window must actually expire

**User decision, given:** an expired claim **RELEASES** the property so a later broker can win it. Not advisory.

## 1.1 What is actually being built (after P2)

Not "an expiry". **One recency window, applied consistently to all three claim reads instead of two of them**, plus the adoption leg that makes the third one survivable (P4).

| Read | Windowed today? | After |
|---|---|---|
| `findMatchingRegistry` — EXACT (`selectByPropertyKeyWithWinner`) | ❌ never expires | ✅ windowed |
| `findMatchingRegistry` — FUZZY (`selectRecentWithWinner`) | ✅ 90d already | ✅ unchanged |
| `findBrokerSubmission` — REPEAT (`selectRecentByBrokerEmail`) | ✅ 90d already | ✅ unchanged |

🔴 **The two windows must never diverge, and one line of the design exists only to guarantee it.** If the protection window were ever set **longer** than `LOOKBACK_DAYS`, a claim in the gap would be protected on the exact path and invisible on the fuzzy path — reintroducing P2's defect in a new place, where a re-worded resubmission wins a property that an identically-worded one loses. ⇒ declare `PROTECTION_WINDOW_DAYS = 90` in `PropertyMatchingService` beside `LOOKBACK_DAYS`, and **pin `LOOKBACK_DAYS >= PROTECTION_WINDOW_DAYS` with a test**. This is exactly the in-repo pattern `CallForOffersService` uses for `CRITICAL_DAYS` / `APPROACHING_DAYS` versus `ALERT_INTERVALS`: constants declared separately, held together by `everyRungOfTheLadderMapsToExactlyOneBand` rather than by construction, with a header note saying so.

## 1.2 Where expiry is evaluated — LAZY, at claim time. Recommended, not offered.

| | Lazy (recommended) | Sweep job |
|---|---|---|
| New SOQL on the ordinary path | **zero** — the cutoff is a bind variable on queries that already run | one locator per pass |
| Post-deploy scheduling gate | **none** | 🔴 one more, and this repo has recorded twice that an unscheduled job ships a feature that is **inert with no trace** |
| Consistency with the two live windows | **by construction** — same function, same constant | two mechanisms answering one question |
| Registry DML | only inside the rare `DUPLICATE_VALUE` catch | 🔴 a sweep must **write** something (a status, a flag) — which is precisely the **third DML the class header prohibits** (P3) |

⚠ **The cost of lazy, stated plainly: expiry is INVISIBLE until someone submits the property again.** There is no "expired claims" list view and no report, because no state changes. **Remedy, and it is cheap:** one **formula** field on `Property_Registry__c`, `Protection_Expiry_Date__c = DATEVALUE(Registered_DateTime__c) + 90`. No writer, no DML, no job — and the object is already `enableReports = true`, so a report and a list view fall out. It is the registry's own analogue of `Lead.BP_Expiry__c`, sitting where the claim actually lives. **Include it.**

⚠ It is also a **fifth** copy of "90" in the codebase (`LOOKBACK_DAYS`, the new `PROTECTION_WINDOW_DAYS`, `LeadFunnelController.BP_WINDOW_DAYS`, `Lead.BP_Expiry__c`'s formula, and this one). Formulas cannot read Apex constants, so the duplication is unavoidable — but it must be **pinned, not hoped**: a test that inserts a registry row and asserts `Protection_Expiry_Date__c == Registered_DateTime__c.date().addDays(PROTECTION_WINDOW_DAYS)` turns a silent drift into a red build. Record all five sites in `PropertyMatchingService`'s header.

## 1.3 🔴 The converted winner — the decision everything else hangs off

**RECOMMENDATION: a claim whose winning Lead has been CONVERTED does NOT expire.** Three independent arguments, in order of weight:

1. **Structural, and it is the one that removes work.** The expiry adoption is an `update` of an existing registry row. P3's prohibition is precisely about updating a row whose `Winning_Lead__c` may hold a converted Lead. Filtering the adoption to `Winning_Lead__r.IsConverted = false` means **the update can only ever touch a row whose lookup holds an OPEN Lead** — the prohibition is discharged *structurally*, not mitigated. Under the opposite reading the registry needs the same split anchor the submission got: a new `Winning_Opportunity__c` field, a rewritten `Winning_Lead_Required` VR, a split-anchor rule in a second class, and every existing reader of `Winning_Lead__c` audited. That is a tranche of its own.
2. **Business.** A converted winner is a **live deal**. Releasing it lets a second broker take the registry claim on a property DPEG is actively transacting, and the commission adjudication this module exists for is at its sharpest exactly there. ACQ-03's *"original broker keeps credit"* is least ambiguous on a deal in flight.
3. **Cost.** `Winning_Lead__r.IsConverted` is a spanning field on a query that already runs — **zero extra SOQL**.

⚠ **State the residual, do not hide it: a deal that converted and then DIED protects the property for ever.** A converted Lead whose Opportunity went `Dead/Pass` still reads `IsConverted = true`, so the claim never releases. **The named remedy already exists and is already tested**: delete the registry row by hand, which re-opens the key through the existing **orphan-adoption** path (`Winning_Lead__c` SetNull → `findOrphanedRegistry` → adopt). No new code, no new mechanism. Record it in the class header as the operational escape hatch.

## 1.4 The mechanism — three classes, and deliberately not a fourth

🔴 **`ExtractAddressQueueable` is NOT touched, and that is a design goal rather than a happy accident.** Branch (d) (competing) and branch (e) (winner) both route off the *same* `findMatchingRegistry` call, and `claim()`'s in-lock authority calls it too. Changing that one function flips an expired property from branch (d) to branch (e) **everywhere at once**, so the pre-read and the in-lock decision cannot disagree. It also keeps this item entirely clear of the parallel session's edits (see the collision map).

**(a) `PropertyRegistrySelector`** — ⚠ its header carries a **SIGNATURE CONTRACT** (*"Do not rename or change their parameters/return types"*). Therefore **ADD, never modify**:

- `selectLiveByPropertyKey(Set<String> keys, Datetime cutoff)` — the windowed exact read:
  `Property_Key__c IN :keys AND Winning_Lead__c != null AND (Registered_DateTime__c >= :cutoff OR Winning_Lead__r.IsConverted = true)`
- `selectExpiredByPropertyKey(String key, Datetime cutoff)` — the adoption target, `LIMIT 1`:
  `Property_Key__c = :key AND Winning_Lead__c != null AND Registered_DateTime__c < :cutoff AND Winning_Lead__r.IsConverted = false`
- Both keep the class's stable field shape and add `Winning_Lead__r.IsConverted`. Both stay `WITH USER_MODE` on a `with sharing` class — `Property_Registry__c` is **`sharingModel = ReadWrite`** (verified), so neither the mode nor the sharing question from ARCHITECTURE's automation table arises here. Say so at the method rather than leaving a reader to wonder.
- ⚠ `selectByPropertyKeyWithWinner` is **retained unchanged** and becomes the un-windowed read. Mark it as such in its Javadoc, or delete it if the new method leaves it with no callers — do not leave two same-shaped reads with silently different semantics.

**(b) `PropertyMatchingService`**

- `PROTECTION_WINDOW_DAYS = 90`, declared beside `LOOKBACK_DAYS` with the `>=` invariant note.
- `findMatchingRegistry` switches its exact leg to `selectLiveByPropertyKey(keys, now − PROTECTION_WINDOW_DAYS)`. The fuzzy leg is untouched.
- new `findExpiredRegistry(String normalized)` → `selectExpiredByPropertyKey`, returning the row or null. Mirrors `findOrphanedRegistry` exactly.

**(c) `PropertyClaimService.registerWinner`** — one new leg in the `DUPLICATE_VALUE` catch, placed **after** the orphan leg (they are disjoint: an orphan has a null winner, an expired row has a non-null unconverted one; ordering is therefore about not disturbing tested behaviour, not about correctness):

```
Property_Registry__c expired = PropertyMatchingService.findExpiredRegistry(normalized);
if (expired != null) {
    expired.Winning_Lead__c        = sourceLeadId;
    expired.Normalized_Address__c  = normalized;
    expired.Registered_DateTime__c = Datetime.now();
    update expired;                       // byte-identical to the orphan leg
    insertSubmission(buildSubmission(sourceLeadId, sourceLeadId, sourceLeadId, …, true));
    return ClaimOutcome.WINNER;
}
```

🔴 **It must be byte-identical to the orphan leg**, and the class header must say why: two adoption paths writing two different field sets is how `Registered_DateTime__c` acquires two meanings, which is the one thing the fuzzy lookback and the expiry both depend on it not doing (P5).

🔴 **And the class header's PROHIBITION paragraph must be amended in place, not left standing.** It currently says there are exactly two DML statements against this object and that a third must not be added. There will be three. The amendment must state (i) the third is an adoption of an **expired** row, (ii) it is admissible **only** because it is filtered to `Winning_Lead__r.IsConverted = false`, so it can never touch a converted-Lead lookup, and (iii) **the prohibition still stands for any update not carrying that filter.** Leaving the old text is worse than deleting it — the next reader will believe a rule the code no longer follows.

## 1.5 What happens to the losing incumbent — decided, with the residuals named

| Question | Answer |
|---|---|
| Previous winner's **Lead** | **Untouched.** Nothing deletes it. The module deletes a Lead on exactly one path (`DUPLICATE_RACE`, a Lead created seconds earlier), and this is not it. The Lead keeps its address, its extraction and its Tasks; it is simply no longer the registry winner. |
| Previous winner's **`Competing_Broker_Submission__c` trail** | **Untouched and must stay so** — ARCHITECTURE: *"Deliberately not master-detail — cascade delete would silently wipe this trail."* |
| Two rows now claim `Is_Winning_Submission__c = true` for one property | **Correct, not a defect.** They are anchored on **different** Leads, so the Lead-page component shows each broker only their own. Each row was true when written; the object is append-only by definition. One sentence in the field's description is enough. |
| Where is the handover recorded? | Only in the registry row's moved `Winning_Lead__c` + the new winner's submission. ⚠ **There is no "this claim was superseded" marker, deliberately** — adding one is another registry write and re-opens P3. `Protection_Expiry_Date__c` plus the two submission rows make the handover reconstructible. |

🔴 **RESIDUAL R1 — the superseded broker's follow-ups do not become competing claims, for up to 90 days.** Branch **(b) REPEAT** runs *before* branch (d) in the routing tree and **never consults the registry**. So after a handover, if the superseded broker emailed within the last 90 days, `findBrokerSubmission` still matches their own prior row and files the new email as a Repeat **on their own now-worthless Lead** — no competing submission against the new winner, no error, nothing in the UI. **Recommend accepting it**: the email is still captured, still logged, still auditable, and "fixing" it means making the highest-traffic branch in the pipeline registry-aware. Record it in `ExtractAddressQueueable`'s header so it is a known shape rather than a future bug report.

⚠ **RESIDUAL R2 — `Lead.BP_Expiry__c` will now visibly contradict the truth** on a superseded Lead: the record page and the highlights panel keep showing a date derived from `First_Seen_Date__c + 90` for a Lead that holds no claim. That is P1's cost, and it is the reason `BP_Expiry__c` needs a decision rather than benign neglect.

## 1.6 `BP_Expiry__c` — RETIRE the concept, KEEP the field this tranche

**It cannot be adopted as the expiry source, for two reasons that are about shape rather than taste:**

1. **Wrong cardinality.** `ExtractAddressQueueable` routes up to `MAX_PROPERTIES` (10) properties per email, so **one Lead can be the registry winner of several properties**, each with its own `Registered_DateTime__c`. A single Lead-level date reports one expiry for all of them.
2. **Wrong anchor event.** `First_Seen_Date__c` is when the **Lead** was first seen. A claim starts at `Registered_DateTime__c` — milliseconds later on branch (e), but **arbitrarily later** on an adopted orphan or (now) an expired re-claim.

**Recommendation:** correct its `<description>` to say it is a Lead-level display approximation and that the authoritative window is `Property_Registry__c.Protection_Expiry_Date__c`; leave the field in place. **Do not delete it in this tranche** — it is live on two UI surfaces and in two permission sets the parallel session is editing (P1). Deletion is a separate, low-risk follow-up, flagged below.

## 1.7 Configurability — hardcode at 90. And the argument is stronger here than for the alert ladders.

Tranche 1's three reasons all apply (custom-setting **data is not deployable** ⇒ a silent post-deploy gate; both existing Custom Settings exist because `getOrgDefaults()` is 0 SOQL on a **hot** path, which this is not; an admin editing policy with no deploy and no review). **A fourth is specific to this constant and is decisive:**

🔴 **The window is a claim-arbitration constant, so changing it retroactively re-decides who owns properties that are already claimed.** An admin moving it from 90 to 30 in Setup silently releases every claim between 30 and 90 days old, and the next email on any of them mints a new winner — with no deploy, no review, no audit and no way to tell afterwards which handovers were caused by the edit. That is not configuration; it is a data migration wearing a checkbox. §12's *"configurable window"* is satisfied by *"one named constant, changed by deploy"*.

## 1.8 Governor budget and testing

**Budget: +0 SOQL and +0 DML on every ordinary path.** The cutoff is a bind variable on queries that already run; `findExpiredRegistry` executes only inside the `DUPLICATE_VALUE` catch, which is rare by construction. Assert it — `ExtractAddressQueueable.lastRunQueryCount` must be **unchanged** for both the WINNER and the DUPLICATE paths.

⚠ `PropertyClaimService` is **de-exempted** from the 251 mandate (`.claude/rules/bulk-test-rule.md`, narrowed 2026-07-31), and a literal 251 is documented there as impossible and meaningless. The replacement mandate applies: volume + governor-headroom + ordering tests. Required:

- **Boundary pair:** an 89-day-old claim still wins the property (incumbent kept); a 91-day-old claim with an **unconverted** winner is adopted — `Winning_Lead__c` moves, `Registered_DateTime__c` resets, outcome `WINNER`, the new Lead survives.
- **The converted case:** a 91-day-old claim whose winner is converted is **not** adopted; outcome `DUPLICATE`, no Lead, competing submission logged.
  🔴 ⚠ **State the limit of this test in its own comment.** `PropertyClaimServiceTest.platform_lookupToAConvertedLead_isNotEnforcedInTestContext` already pins that test context does **not** enforce the converted-Lead restriction. So this test proves **the decision** (we refuse to adopt) and **cannot** prove the platform would have thrown had we tried. Do not let a green run be read as validating P3.
- **The P2 falsifier — the highest-value test here.** One property, two wordings, same day, either side of the boundary: exact and fuzzy must reach the **same** outcome. This is the test that fails if anyone re-opens the two paths.
- **`LOOKBACK_DAYS >= PROTECTION_WINDOW_DAYS`** pinned directly.
- **The formula pin:** `Protection_Expiry_Date__c == Registered_DateTime__c.date().addDays(PROTECTION_WINDOW_DAYS)`.
- **P4's falsifier:** an expired key never returns `UNCLAIMED`. This is the test that catches a future "optimisation" that drops the adoption leg and keeps the filter.
- The existing orphan-adoption tests must stay green **unmodified** — they are the proof the new leg did not disturb the old one.

---

# ITEM 2 — Broker leaderboard, by broker PERSON

**User decision, given:** by broker **person**, not by firm.

## 2.1 🔴 Computed live. Do NOT write the six dead Contact fields. The argument is not a preference.

| | Live (recommended) | Stored rollups on Contact |
|---|---|---|
| Covers **losing** brokers | ✅ | ❌ **structurally impossible** |
| Identity resolution needed | none — the ledger's own key | email → Contact, fails soft |
| Drift | none | needs a writer, a backfill and a trigger |
| Reportable | ⚠ not as a component; see below | ✅ |

🔴 **The decisive fact: most brokers in the ledger have no Contact and never will.** Since 2026-07-31 a **competing broker receives no Lead at all** — so no conversion, so no Contact, ever. `Competing_Broker_Submission__c` exists precisely because it is the only record of brokers who appear nowhere else. Rollups on Contact can therefore only ever describe the subset that **won and then converted** — i.e. a leaderboard built on those fields **silently omits every losing broker**, which is the population §27.3/§27.4 is about. That is not a trade-off; it is the metric inverting itself.

Two supporting reasons:

- **The six fields already mean something else.** `Active_Listings__c`, `Closed_Volume__c`, `Avg_Days_On_Market__c` describe brokers DPEG **lists with** (the disposition-side scorecard `BrokerController` renders on `Broker_Hub` / `Broker_Scorecard`). Repurposing `Deals_Submitted__c` / `Deals_Won__c` for inbound submissions puts two unrelated meanings on one card, with no way for a reader to tell which is which.
- **Salesforce cannot roll up across this relationship anyway.** `Competing_Broker_Submission__c` has **no Contact lookup** — the identity is `Broker_Email__c`, a Text field. There is no roll-up summary to build; any rollup is Apex plus a fuzzy email match, i.e. `LeadConvertMatchService`'s job, which matches on Email alone and **fails soft**. A broker with two addresses becomes two visible rows under the live design (correctable) and **one silently undercounted Contact** under the rollup design.

⇒ **Leave all six Contact fields exactly as they are.** They are not this feature's storage. (They remain a separate, real finding — see the out-of-scope list.)

## 2.2 The query — two aggregates, and the split anchor does not bite

```
A:  SELECT Broker_Email__c e, MAX(Broker_Name__c) n, COUNT(Id) c,
           MIN(Submitted_DateTime__c) firstSub, MAX(Submitted_DateTime__c) lastSub
    FROM Competing_Broker_Submission__c
    WHERE Broker_Email__c != null
    GROUP BY Broker_Email__c
    ORDER BY COUNT(Id) DESC
    LIMIT :maxRows

B:  … same, WHERE Broker_Email__c != null AND Is_Winning_Submission__c = true
    GROUP BY Broker_Email__c
```

Merged in memory. **2 SOQL / 0 DML, constant in broker count.** Mode `WITH USER_MODE` on a `with sharing` class: `Competing_Broker_Submission__c` is **`sharingModel = ReadWrite`** (verified), so neither the automation-path mode exception nor a `without sharing` inner class is warranted — and inventing one would be an unargued widening. Say so at the method.

🔴 **The split anchor the brief warns about does NOT affect these counts, and saying so is the point.** Both aggregates group by `Broker_Email__c` and read **neither** `Winning_Lead__c` nor `Winning_Opportunity__c`. A converted winner's rows carry the Opportunity anchor and are still counted, because the anchor is not in the query. ⚠ **It bites the moment anyone adds a drill-through or a deal-outcome column** — at which point both anchors must be read, and `selectByWinningLead` is Lead-only (ARCHITECTURE's named open gap). Record this in the service header so the trap is documented *as not applying yet*, rather than rediscovered.

**`MAX(Broker_Name__c)` is deterministic-arbitrary, not "the latest"** — one address can carry several spellings. Label the row by **email** (the key) and treat the name as a display hint. Say so in the Javadoc; do not add a third query to get a "better" name.

## 2.3 Columns — and what is deliberately absent

| Column | Source |
|---|---|
| Broker (name hint + email) | A |
| Submissions | A: `COUNT(Id)` |
| Properties Won | B: `COUNT(Id)` |
| Win Rate % | computed, `won / submissions` |
| **First Submission** | A: `MIN(Submitted_DateTime__c)` |
| Last Submission | A: `MAX(Submitted_DateTime__c)` |

✅ **§27.4's "First Submission Date" falls out free** as `MIN(Submitted_DateTime__c)` — **no Contact field, no writer, no backfill.** That is the whole of that FSD ask.

🚩 **Deals Won / Lost by OPPORTUNITY OUTCOME is deliberately NOT built.** Three reasons: it needs both winner anchors plus a conversion hop through a selector method that does not exist; it needs **`OpportunitySelector`, which cannot deploy from this tree (P11)**; and "did DPEG close the deal" is a different question from "did this broker win the property", which `Is_Winning_Submission__c` answers exactly and with no hop. Attributing a *lost* deal to the broker who introduced it is a metric nobody has defined. Flag it; price it separately if wanted.

## 2.4 Residual — the blast-platform identity collapse

ARCHITECTURE records it as **expected traffic, not an edge case**: a broker submitting through RCM / Crexi / Buildout can arrive with an envelope From of the **platform** (`listings@buildout.com`), and U1 then keys every such broker to that one address. So **the top row of the leaderboard may be a platform, not a person.**

**Recommend: display it, do not suppress it.** Suppressing hides real submission volume and makes the totals disagree with the ledger. Name the shape in the component's help text, and record in the service header that a platform-sender list (ARCHITECTURE's named eventual fix for U1) would fix this leaderboard for free the day it lands. **Do not build a heuristic here** — a name/domain guess in a reporting component is a second, unowned copy of an arbitration rule.

## 2.5 Surfacing

New `lwc/brokerLeaderboard` on **`flexipages/Broker_Hub`** (P7 — the page already exists and already hosts `brokerStats` / `brokersList` / `brokerTotals`). Read-only, no row actions, `@AuraEnabled(cacheable=true)`, standard `.lv-*` list chrome per the repo's list-view LWC convention. Jest test + `@sa11y/jest` per §5.

⚠ **Field instances / component only — do not add a quick action to this flexipage.** Recorded repo incident: adding one silently empties the page's inherited action list, and no test catches it.

---

# ITEM 3 — Lead AI-review fields (FSD §27.1)

🔴 **Assessed honestly as instructed: the FSD's literal three-field list is mostly a restatement of data that already exists.** Recommend building **one** of the three as written, **dropping** one, and **linking rather than copying** the third.

## 3.1 `AI Review Status` — build it, as a FORMULA

The FSD's three values are a restatement of two facts already stored and already maintained:

| FSD value | Already answered by |
|---|---|
| **Needs Review** | `Parse_Confidence__c = 'LOW'` — which already drives the **deployed `Review_Queue` list view** (verified: `filters: Parse_Confidence__c equals LOW`) |
| **Auto-Accepted** | `Parse_Confidence__c` in {HIGH, MEDIUM} on a pipeline-sourced Lead |
| **Manually Entered** | `LeadSource` outside the two pipeline markers — `'Email-to-Lead'` (`EmailToLeadService.LEAD_SOURCE`) and `'Broker Portal'` (`BrokerPortalService.LEAD_SOURCE`) |

```
IF( AND( TEXT(LeadSource) <> "Email-to-Lead", TEXT(LeadSource) <> "Broker Portal" ),
    "Manually Entered",
IF( ISPICKVAL(Parse_Confidence__c, "LOW"), "Needs Review", "Auto-Accepted" ) )
```

**Why a formula and not a stored picklist:** it has no independent state. A stored field needs a **writer inside `EmailToLeadService`** — a class the parallel session is editing — plus a backfill for every existing Lead, and it can then **drift from `Parse_Confidence__c`**, at which point `Review_Queue` and the new field disagree about the same Lead with nothing to reconcile them.

⚠ **Correct behaviour worth naming:** the LLM-down degrade path writes `Parse_Confidence__c = 'LOW'` (`ExtractAddressQueueable`), so "Needs Review" correctly includes emails the model never successfully read. That is the right answer and it is free.

⚠ **The cost, and it is a real one: a human cannot mark a Lead reviewed.** A formula reports a derived state; it does not carry a workflow. If §11.1's *"flagged 'Needs Review'"* means an analyst clears a flag when they have checked it, that is a **different, stored field with an owner, a button and a permission** — and it should be asked for as such rather than smuggled in. → **Q3.**

## 3.2 `AI Confidence (per field)` — 🚩 DROP

1. **The extraction returns exactly two confidences and both are about CLASSIFICATION.** `confidence` measures certainty about `is_acquisition_related`; `category_confidence` measures certainty about `email_category`. Neither says anything about the value of any extracted field. `LLMExtractionCalloutService`'s prompt text states this in terms (*"a SEPARATE judgement from confidence, which concerns is_acquisition_related only"*).
2. **Getting per-field confidence means a prompt change, and this repo has recorded what that costs.** Every prior change in that class records *"LEGACY_EXTRACTION_RULES and LEGACY_RESPONSE_FORMAT are untouched, so no fixture pin moves"* as an explicit goal, against `ExtractionRegressionFixtureTest`. And a prompt edit **silently changes who WINS a property** — arbitration rides on the model's `broker_email` and `property_address`. Paying that to populate a display field is the wrong trade.
3. 🔴 **What the FSD actually needs already exists, under a name that is more truthful.** `Extraction_Score_Pct__c` measures **per-field CAPTURE** across nine signed-off deal-process keys, with `Fields_Captured_Count__c` / `Fields_Missing_Count__c` beside it — and all three are **already on the Lead record page** (verified: flexipage lines 301 / 311 / 331). That field's own XML comment explicitly forbids conflating the two: *"A confident, correctly-classified acquisition email can still be almost empty of deal facts, and an unconfident one can be complete."* Building per-field confidence next to it would put two measures of "how good is this extraction" on one page with no rule for which to believe.

⇒ **Drop.** If the underlying want is *"which fields did we miss"*, `ExtractionScoreUtil` already computes the missing set to produce the count and naming them is a small, separate ask — flagged below, not folded in.

## 3.3 `Raw Email Content` — LINK, do not copy

It exists verbatim on `Inbound_Email_Staging__c`: **`Raw_Body__c`** (LongText 131072, *"Full raw body … before any parsing or extraction"*) + **`Subject__c`** — the FSD's *"subject and body only"* exactly. A **second** copy already sits on the Lead's own timeline, since `InboundEmailActivityService` writes a `From:` / `Subject:` / rule header block plus the raw body into `Task.Description`.

**Copying it onto the Lead would be a third copy**, ~128 KB per Lead of storage, written from inside `EmailToLeadService` (parallel-session collision), for content that is already retained and already immutable. ⇒ **Read it where it lives.**

**Build:** a read-only `lwc/leadInboundEmail` on the Lead record page, over a new `InboundEmailStagingController` → `InboundEmailStagingSelector` method keyed on `Result_Record_Id__c`.

🔴 **THREE things about this are not optional, and two of them are why this sub-item is the riskiest in the tranche.**

1. **`Result_Record_Id__c` must become an External Id.** It is `Text(18)` with `externalId = false` (P9) — **not indexed** — and `Inbound_Email_Staging__c` grows with every inbound email, so a `WHERE Result_Record_Id__c = :leadId` read becomes non-selective and eventually fails. The change is **additive and free**; skipping it ships a component that works in UAT and degrades silently in production.
2. 🔴 **The read must escape sharing AND user mode, and that is a deliberate widening that needs signing off.** `Inbound_Email_Staging__c` is described as **backend-only**; ARCHITECTURE records it as `sharingModel = Private` with **no sharing rules**, rows owned by the Email Service context user, and `Broker_Protection_Access` setting `viewAllRecords = false`. An acquisitions analyst opening the Lead therefore sees **nothing, with no error** — the exact "returns zero rows, looks healthy" failure the routing sweep paid for. ⇒ the query goes `WITH SYSTEM_MODE` inside a **`private without sharing` inner class, `InboundEmailStagingSelector.AuditReads`**, mirroring `RoutingReads`. The FSD's own words justify it (*"stored for broker-protection audit"* — it is meant to be readable by the team adjudicating claims), but it **is** a widening and belongs in Q4, not in a code comment.
3. 🔴 **Bound the exposure at the controller, not at the selector.** Because the read escapes both sharing and CRUD, the only remaining gate is Apex **class** access, which is coarse. ⇒ the controller must (a) take a **record Id from the page** and never a list or a filter, (b) **first read that Lead `WITH USER_MODE`** and let a denial throw, and only then (c) fetch the staging row whose `Result_Record_Id__c` equals it. That makes the widened read reachable only for a record the caller can already see. It is the same discipline ARCHITECTURE records for the retired `UserSelector` (*"every method … hard-filtered to `UserInfo.getUserId()` and took no user parameter"*). **2 SOQL, and the first one is the security boundary.** Never expose a list method.

⚠ `Routed_Record_Ids__c` exists for multi-target routing; the selector should read `Result_Record_Id__c` only, and the header should say the multi-target case is out of scope rather than leaving it ambiguous.

---

# ITEM 4 — Stalled-deal reminders

## 4.1 🚦 GATED — read this first

🔴 **The batch locator must live in `OpportunitySelector`**, which **cannot deploy from this tree** (P11). ⚠ **Do not route around it** by creating an `OpportunityAlertSelector` — `.claude/rules/apex-layering-rule.md` puts all SOQL for one object in one selector, and buying a rule violation to dodge a scheduling conflict is a permanent cost for a temporary problem. ⇒ **Item 4's Apex is sequenced after the parallel session's `Property_Package__c` field reaches the org.** Its declarative half (fields, formula, flow) is independent and can land first.

## 4.2 🔴 VERIFY FIRST — the standard field may remove half this item

Salesforce provides a standard, system-maintained **`Opportunity.LastStageChangeDate`** (DateTime, read-only). It does not appear in `objects/Opportunity/fields/` because standard fields are not sourced there, so its presence must be **checked in the org**, not in the repo.

| If it is present (likely) | If it is absent |
|---|---|
| ✅ **No stamp field. No flow.** `Days_In_Stage__c` becomes `TODAY() − DATEVALUE(LastStageChangeDate)`. The whole stamping mechanism disappears — and with it the approval-lock analysis in §4.3. | Build `Stage_Start_Date__c` + `Opportunity_Stage_Timer` per §4.3. |

**Recommend the standard field, with the custom pair as the named fallback.** Do not build the flow speculatively. ⚠ **Either way the backfill residual is identical** — see §4.5.

## 4.3 The fallback stamp — and why it is BEFORE-save

`Opportunity_Stage_Timer`: `RecordBeforeSave`, `CreateAndUpdate`, `ISNEW() || ISCHANGED(StageName)` → assign `$Record.Stage_Start_Date__c = $Flow.CurrentDate`. Exactly `Lease_Inquiry_Stage_Timer`'s shape.

🔴 **Before-save is a correctness requirement here, not a performance preference, and Opportunity is a much sharper case than `Lease_Inquiry__c`.** An after-save update would (a) re-fire the whole Opportunity trigger chain — `OpportunityReviewTriggerHandler` → `PropertyAssetService`, `DealFolderService`, `openTransactionsOnAboutToClose` — and (b) issue a **second DML** on a record that may be locked by `Underwriting_Approval`, throwing `ENTITY_IS_LOCKED`. A before-save assignment issues no statement at all. This is precisely the argument `DispositionStageEntryService.stampListingDates` makes for `Listing_Date__c`, and it transfers because the value depends only on the transition, which is fully known in before-update.

## 4.4 `Days_In_Stage__c` — and the one place the precedent must NOT be copied

```
IF( OR( ISPICKVAL(StageName, 'Closed Won'), ISPICKVAL(StageName, 'Dead/Pass') ), 0,
IF( ISBLANK(Stage_Start_Date__c), null, TODAY() - Stage_Start_Date__c ) )
```

🔴 **Declare `formulaTreatBlanksAs = BlankAsBlank`, NOT `BlankAsZero` — a deliberate divergence from `Lease_Inquiry__c.Days_In_Stage__c`, which uses `BlankAsZero` (P10).** Under `BlankAsZero` every deal with no stamp reads **0 days in stage for ever**, which is indistinguishable from "moved today" and makes it permanently invisible to the alert. That is byte-for-byte the `Broker_Listing__c.Days_On_Market__c` defect ARCHITECTURE records — *"a clock that looks healthy and never ticks"*. Record the divergence and its reason in the field's XML comment so nobody "harmonises" it back.

⚠ `'Dead/Pass'` is the **literal** decoded form in a formula and in list-view filters; `Dead%2FPass` is required only inside `BusinessProcess` / `RecordType` / picklist metadata. Getting this backwards yields a branch that silently never matches.

## 4.5 🔴 The backfill residual — the same shape as `DealFolderService` R5

Whichever mechanism is used, **every Opportunity that exists on deploy day has no stage-entry timestamp** and stays invisible to the alert until it next changes stage. `LastStageChangeDate` is blank for records that have not moved since the platform feature landed; the custom stamp is blank until the before-save flow next fires.

**Recommend the same answer this repo already gave for R5: a one-off anonymous-Apex backfill, named in the class header, not a code path.** Seed `Stage_Start_Date__c` from `LastModifiedDate.date()` — knowingly approximate, bounded, and strictly better than blank. ⚠ **State that it is approximate** rather than letting a reader assume the first alert wave is accurate. Do **not** build an "if blank, use CreatedDate" fallback into the formula: that would silently alert on every historical deal at once on day one.

## 4.6 Thresholds — PER STAGE, in Apex

**Per-stage, not one global.** "New" sitting 30 days and "Under Contract (PSA)" sitting 30 days are not the same event — PSA negotiation legitimately runs for months while a New lead at 30 days is dead. A single global threshold either spams the late stages or never fires on the early ones, and either way the alerts stop being read (`CallForOffersService`'s header names alert fatigue as the explicit failure to avoid).

**A `Map<String, Integer>` in `StalledDealAlertService`, Apex, not Custom Metadata** — the same argument `RecordStageAdvanceService` makes for its stage map (an admin editing it with no deploy and no review) plus tranche 1's Q2.2 reasoning.

**Proposed defaults → Q2** (the FSD gives none, so this is a genuine decision, not a default I can defend alone):

| Stage | Proposed days |
|---|---|
| New | 14 |
| Under Review | 21 |
| Underwriting | 30 |
| Development Review / Construction Review | 30 |
| LOI | 30 |
| Under Contract (PSA) | 60 |
| About to Close | 30 |
| Closed Won, Dead/Pass | **excluded — terminal** |

⚠ Stage set verified from `objects/Opportunity/businessProcesses/{Land,Commercial,Retail}` — note there are **three** record types, not the two ARCHITECTURE §2 names; `Land` carries Development Review and `Commercial`/`Retail` carry Construction Review. A stage absent from the map is simply never alerted, which is the correct fail-open for an alert.

## 4.7 The marker pair — and the snapshot half is NOT a date here

Per tranche 1's P5, a re-notification guard needs **two** fields. The adaptation is not mechanical:

| Field | Type | Job |
|---|---|---|
| `Stall_Alert_Last_Threshold__c` | Number(4,0) | the threshold already notified. A double run is a no-op. |
| **`Stall_Alert_Stage__c`** | Text(60) | 🔴 **the snapshot of the stage the marker was computed against.** When it differs from the live `StageName`, the marker is treated as blank and the alert **re-arms**. |

🔴 **The snapshot is the STAGE, not a date, and that is the whole point.** Without it, a deal alerted as stalled at LOI, then advanced to `Under Contract (PSA)`, then stalled again there, is **never alerted again** — the marker is still armed against a threshold from a stage it has left. That is the direct analogue of `Offer_Alert_Due_Date__c` (*"an extension leaves the marker armed against a date that no longer exists and the re-armed schedule NEVER FIRES — silently"*), transposed to the axis that actually moves on this object.

## 4.8 Mode, sharing and the deliberate difference from the NDA precedent

- **Locator mode: `WITH SYSTEM_MODE`.** The two marker fields are Metadata-API-deployed customs and arrive with **no FLS for any profile, System Administrator included** — under `USER_MODE` the locator throws `No such column` for the very administrator who deployed them.
- 🔴 **Sharing: `with sharing` is SUFFICIENT, and this is argued, not inherited.** `Opportunity` internal OWD is **`ReadWrite`** (measured, recorded in ARCHITECTURE for `selectCallForOffersTargetsByIds`), so no `without sharing` inner class is warranted and adding one would be an unargued widening. ⚠ **This is a real difference from tranche 1's NDA job**, which needed `NdaSelector.ExpiryAlertReads` *because `NDA__c` is `sharingModel = Private` with no acquisition-side sharing rule.* Do not copy that inner class here by analogy. ⚠ Carry forward the stated residual verbatim: if `Opportunity` OWD is ever narrowed to Private, this locator returns zero rows, `finish()` logs all-zeros, and that is **indistinguishable from "no deal is stalled"**.
- **Stamp write:** `Database.update(toStamp, false, AccessLevel.SYSTEM_MODE)` — plain, **no `without sharing` writer**, for the same OWD reason. Again, a stated difference from the NDA job.
- 🔴 **SEND FIRST, STAMP SECOND**, via `GroupNotifier.notifyWithOutcome(...)`, stamping only rows whose send succeeded. A notification is not transactional; stamp-then-send loses an alert **silently and for ever**, send-then-stamp merely repeats it tomorrow.
- **Recipient:** the **`Acquisition` queue**, matching `CallForOffersAlertBatch.RECIPIENT_GROUP` and tranche 1's NDA job — the third alert job in the app should not invent a fourth audience. ⚠ Per-owner notification is the more natural fit for a stalled deal, but `GroupNotifier` addresses groups and queues only; it would need a different notifier. Flagged, not built.
- **`SCOPE = 200`, inherited** from `CallForOffersAlertBatch` with the citation rather than re-measured — the measured cost model (`≈ 6.0 ms + 0.22 ms × |recipients|` per notification) is a property of `Messaging.CustomNotification.send()`, not of the object.
- Fail-soft per chunk; a batch has no Finalizer. One `asOf` captured once per `execute()`, never `Date.today()` per record.

## 4.9 Testing

251-row bulk test on the locator (`.claude/rules/bulk-test-rule.md`; a test method runs one chunk, so at `SCOPE = 200` a 251-row fixture proves the locator selects, filters and orders 251 rows and that a full 200-row chunk behaves). Plus: a terminal-stage deal is never selected; a blank `Stage_Start_Date__c` deal is never selected (the `BlankAsBlank` falsifier); **a deal that stalls, is alerted, advances a stage and stalls again IS alerted again** (the falsifier for dropping `Stall_Alert_Stage__c`); a double run is a no-op; a failed send is not stamped. Governor assertions read counters captured **inside** the async context, never `Limits.*` after `Test.stopTest()`.

---

# ITEM 5 — Call-for-offers reminder cadence

## 🚩 RECOMMENDATION: NO CHANGE. Close §25.2.2 as already satisfied.

**1. The requirement is already over-satisfied (P6).** The built ladder is `{7, 3, 1, 0}` — **four** rungs, not the three the brief states, and the fourth is day-of. The FSD's *"default proposed at 2 days"* sits **between** the built 3 and 1 rungs, so a call-for-offers deadline already produces a reminder a week out, four days before the FSD's proposal, two days after it, and on the day itself. Adding a "2" rung fires a **fifth** notification inside seven days, on a ladder whose own service header names alert fatigue as the explicit failure to avoid.

**2. Configurability loses on tranche 1's reasoning — and there is a fourth argument specific to this class.** Tranche 1's three stand unchanged: custom-setting **data is not deployable**, so a config-driven ladder adds a post-deploy gate whose omission leaves it empty or silently defaulted; both existing Custom Settings exist because `getOrgDefaults()` costs 0 SOQL on a **hot** path, and a once-daily batch has no such pressure, so the precedent's own justification does not transfer; and an admin editing an alert ladder with no deploy and no review is the hole `RecordStageAdvanceService` cites for keeping its stage map in Apex.

🔴 **The fourth is the one that settles it.** `ALERT_INTERVALS` is **not** derived from `CRITICAL_DAYS` (3) and `APPROACHING_DAYS` (7) — the class header says so explicitly, and what holds the three together is a single test, `CallForOffersServiceTest.everyRungOfTheLadderMapsToExactlyOneBand`, which walks every boundary day and asserts the band **and** the interval at each. A runtime-configurable ladder makes that test **unable to pin anything**, because the ladder it walks is no longer the ladder production runs. Configurability would delete the only existing guarantee that the notification bell and the UI badge agree about a deal.

**3. And no — the NDA ladder should NOT move either.** The user is right that consistency between the two matters more than either choice, and the consistent answer is that **both stay hardcoded**, each in its own service, each pinned by its own test. Moving one to config would leave two ladders that agree in value while differing in mechanism — the worst of both, and the state in which a future reader "harmonises" the wrong one.

**What to actually do — one comment, zero risk:** record the FSD-versus-built delta in `CallForOffersService`'s header (*"§25.2.2 proposes a single configurable reminder defaulting to 2 days; the built ladder is {7, 3, 1, 0}, which brackets it. Assessed 2026-08-17 and deliberately not changed — see …"*), so the next reader closes the question in ten seconds instead of re-opening it.

---

# 🔵 ADMIN WORK (`salesforce-admin`)

| # | Item | Detail |
|---|---|---|
| **A1** | `Property_Registry__c.Protection_Expiry_Date__c` | **Formula (Date)**: `DATEVALUE(Registered_DateTime__c) + 90`. Full rationale in an **XML comment INSIDE the root element** (never above it — that breaks `sf` deploy at conversion; `<description>` caps at 255). Must record that this is one of **five** hardcoded copies of 90, that it is pinned by an Apex test, and that a converted winner's claim does not expire so this date is **advisory** on those rows. |
| **A2** | 2 new `Opportunity` fields (Item 4) | `Stall_Alert_Last_Threshold__c` Number(4,0); `Stall_Alert_Stage__c` Text(60). Descriptions must say both are system-maintained alert markers, not for manual entry, and that **clearing `Stall_Alert_Stage__c` re-arms the ladder**. |
| **A3** | *(fallback only — conditional on the §4.2 verification)* `Opportunity.Stage_Start_Date__c` | Date, no default. **Build only if `LastStageChangeDate` is absent from the org.** |
| **A4** | `Opportunity.Days_In_Stage__c` | Number formula per §4.4. 🔴 **`formulaTreatBlanksAs = BlankAsBlank`** — XML comment must record the deliberate divergence from `Lease_Inquiry__c.Days_In_Stage__c` and name the `Days_On_Market__c` defect it avoids. |
| **A5** | *(fallback only — with A3)* flow `Opportunity_Stage_Timer` | `RecordBeforeSave`, `CreateAndUpdate`, `ISNEW() \|\| ISCHANGED(StageName)`. 🔴 **Before-save is mandatory** — §4.3. |
| **A6** | `Lead.AI_Review_Status__c` | **Text formula** per §3.1. XML comment must record: it is derived, not stored; the two `LeadSource` literals are `EmailToLeadService.LEAD_SOURCE` / `BrokerPortalService.LEAD_SOURCE` and **must be re-read from those classes at build time**; the LLM-down path writes LOW so "Needs Review" correctly covers it; and that it carries **no workflow state** (Q3). |
| **A7** | `Inbound_Email_Staging__c.Result_Record_Id__c` → `externalId = true` | Additive, no data change. 🔴 Required or Item 3's read is non-selective and degrades silently (P9). |
| **A8** | Correct `Lead.BP_Expiry__c`'s `<description>` | State that it is a **Lead-level display approximation**, that a Lead may hold several claims with different expiries, and that the authoritative window is `Property_Registry__c.Protection_Expiry_Date__c`. **Do not delete the field** (P1). |
| **A9** | **FLS for A1–A4, A6, declared IN FILE** | `Opportunity` fields → the sets that already carry `Opportunity.Deal_Bucket__c` (`DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Opportunity_View`). `Lead.AI_Review_Status__c` → wherever `Parse_Confidence__c` already sits. `Property_Registry__c` formula → wherever `Registered_DateTime__c` already sits. Formulas are **readable only**. 🔴 A `PermissionSet` deploy **REPLACES** its entire `<fieldPermissions>` set — reconcile every file against the org first (paid twice on this project), and ⚠ **three of these files are being edited by the parallel session.** |
| **A10** | `flexipages/Broker_Hub` | Add `c/brokerLeaderboard`. **Component only — no quick action** (adding one silently empties the page's inherited action list). |
| **A11** | `flexipages/Lead_Record_Page` | Add `Record.AI_Review_Status__c` beside the existing `Parse_Confidence__c` / `Extraction_Score_Pct__c` block (lines ~301–331), and `c/leadInboundEmail`. ⚠ **Parallel-session collision — this file is being edited concurrently.** |
| **A12** | Optional, recommended: a `Property_Registry__c` list view *Expired Protection* | `Protection_Expiry_Date__c < TODAY`. One line, and it is the only surface on which lazy expiry (§1.2) is visible before someone re-submits. |

**Complexity routing: `salesforce-admin`.** Two formula fields, three stored fields, one picklist-free flow, FLS edits, two flexipage component adds and a list view. **No multi-object schema design, no OWD or sharing-model design, no subflow orchestration, no ERD.** Not `salesforce-solution-architect`.

---

# 🟢 DEVELOPMENT WORK (`salesforce-developer`)

| # | Item | Detail |
|---|---|---|
| **D1** | `PropertyRegistrySelector` (edit — **ADD ONLY**) | `selectLiveByPropertyKey(Set<String>, Datetime)` and `selectExpiredByPropertyKey(String, Datetime)` per §1.4(a). ⚠ The class header carries a **SIGNATURE CONTRACT** — do not rename or re-parameterise the three existing methods. Both new methods `WITH USER_MODE` on the `with sharing` class; state at the method that `Property_Registry__c` is `sharingModel = ReadWrite`, so no automation-path exception and no `without sharing` inner class is warranted. |
| **D2** | `PropertyMatchingService` (edit) | `PROTECTION_WINDOW_DAYS = 90` beside `LOOKBACK_DAYS`, with the `LOOKBACK_DAYS >= PROTECTION_WINDOW_DAYS` invariant and the five-copies-of-90 register in the header. `findMatchingRegistry`'s exact leg moves to `selectLiveByPropertyKey`; the fuzzy leg is untouched. New `findExpiredRegistry(String)` mirroring `findOrphanedRegistry`. |
| **D3** | `PropertyClaimService.registerWinner` (edit) | The expired-adoption leg per §1.4(c), **byte-identical to the orphan leg**. 🔴 **Amend the class header's PROHIBITION paragraph in place** — there will be three DML statements, the third is admissible only because it is filtered to `Winning_Lead__r.IsConverted = false`, and the prohibition still stands for any update without that filter. Also record R1 (superseded-broker repeats) and the hand-delete escape hatch for a converted-then-dead deal. |
| **D4** | `ExtractAddressQueueable` (edit — **HEADER COMMENT ONLY, no code**) | Record R1: after a handover, branch (b) files the superseded broker's follow-ups on their own dead Lead and no competing submission is raised, for up to 90 days. ⚠ **Parallel-session collision — coordinate or defer this one comment.** |
| **D5** | `BrokerLeaderboardService` (new) | Two aggregates + in-memory merge per §2.2. **2 SOQL / 0 DML, constant in broker count.** Header must record: why Contact rollups are structurally impossible (§2.1), that the split anchor does **not** affect these counts but **will** the moment a drill-through or outcome column is added, that `MAX(Broker_Name__c)` is deterministic-arbitrary, and the blast-platform residual. |
| **D6** | `CompetingBrokerSubmissionSelector` (edit — **ADD ONLY**) | The two aggregate methods. ⚠ Same SIGNATURE CONTRACT caution as D1. `WITH USER_MODE`, `with sharing` — the object is `sharingModel = ReadWrite`; argue it at the method. |
| **D7** | `BrokerLeaderboardController` + `lwc/brokerLeaderboard` (new) | Thin `@AuraEnabled(cacheable=true)` controller over D5, `AuraHandledException` boundary with a fixed user-safe message (`ahe()` helper). Read-only LWC, `.lv-*` list chrome, Jest + `@sa11y/jest`, apiVersion 67.0. |
| **D8** | `InboundEmailStagingSelector` (edit) | `selectByResultRecordId(Id)` in a **`private without sharing` inner class `AuditReads`**, `WITH SYSTEM_MODE`, mirroring `RoutingReads`. Justify **mode and sharing as two separate decisions** at the method. Amend the class header's per-method mode policy in place (it already mixes modes). |
| **D9** | `InboundEmailStagingController` + `lwc/leadInboundEmail` (new) | 🔴 **Two SOQL, and the first is the security boundary**: read the supplied Lead `WITH USER_MODE` and let a denial throw, THEN fetch the staging row. Never expose a list method, never accept a filter (§3.3). |
| **D10** | `StalledDealAlertService` (new) | The **pure** per-stage threshold map + the pure `shouldFire(threshold, lastThreshold, liveStage, markerStage)`. Thresholds live here and **nowhere else**. Clock is an argument. Mirrors `CallForOffersService` / `NdaExpiryService`. 🚦 **Gated behind P11 only if it needs the selector; the service itself is pure and can be written first.** |
| **D11** | `OpportunitySelector.queryStalledDeals()` (edit) | `Database.QueryLocator`, `WITH SYSTEM_MODE`, **`with sharing`, no inner class** — argue the OWD = ReadWrite reason at the method and carry the stated OWD-narrowing residual. 🔴 **BLOCKED by P11.** |
| **D12** | `StalledDealAlertBatch` + `StalledDealAlertSchedule` (new) | `Database.Batchable, Database.Stateful`. `SCOPE = 200` **inherited with citation**, not re-measured. **Send-then-stamp** via `notifyWithOutcome`. Plain `Database.update(…, false, SYSTEM_MODE)`. |
| **D13** | Tests | Per §1.8, §4.9, plus `BrokerLeaderboardServiceTest` (aggregate correctness, a converted-winner's rows still counted, win-rate arithmetic, one email with several name spellings) and a Jest suite per new LWC. ⚠ `.claude/rules/content-publication-rule.md` does not apply — nothing here writes `ContentVersion`. |
| **D14** | `ARCHITECTURE.md` (edit, same PR — §6) | §1 `Property_Registry__c` row gains the expiry semantics and the converted-winner rule; §2 Key Apex Services gains `BrokerLeaderboardService`, `StalledDealAlertService`, `StalledDealAlertBatch`, `StalledDealAlertSchedule`; the `WITH SYSTEM_MODE` table gains **two** rows (`InboundEmailStagingSelector.AuditReads`, `OpportunitySelector.queryStalledDeals`) each arguing mode and sharing separately; update the running "N `SYSTEM_MODE` queries across M selector classes" count; and amend `PropertyClaimService`'s entry to record the third registry DML. |

**Complexity routing: `salesforce-developer`.** Selector additions, two pure services, one batch + schedulable, two read-only LWCs and two thin controllers — all following in-repo precedents that are already built, deployed and documented. **No integration, no Named Credentials, no callouts, no Platform Events, no LDV.** Not `salesforce-technical-architect`.

**Unit testing:** `salesforce-unit-testing` after D1–D12.

---

# 🔗 EXECUTION ORDER

1. **A1 + A9(registry FLS) → D1 → D2 → D3** — Item 1, end to end. **Zero collision with the parallel session; start here.** D3 must not land without D1+D2 or the adoption leg has no read.
2. **D4** — the one header comment on `ExtractAddressQueueable`; coordinate with the parallel session or defer it to the end.
3. **D5 → D6 → D7 → A10** — Item 2. Independent of everything else.
4. **§4.2 VERIFICATION in the org** (does `Opportunity.LastStageChangeDate` exist?) — this decides whether A3 + A5 are built at all. Do it before writing any Item 4 metadata.
5. **A2 (+A3) → A4 (+A5) → A9(Opportunity FLS)** — Item 4's declarative half. Fields and FLS in the **same deploy wave**: a field with no FLS is invisible to every persona including the deployer, and a `USER_MODE` reader throws `No such column`.
6. **D10** — pure service, writable now.
7. 🚦 **WAIT for `Property_Package__c` to reach the org**, then **D11 → D12**. Item 4 cannot complete before this (P11).
8. **A7 → D8 → D9 → A6 → A9(Lead FLS) → A11** — Item 3, **last**, and only after Q3 + Q4 are answered. It has the highest collision surface in the tranche.
9. **A12** (optional list view), **A8** (`BP_Expiry__c` description).
10. **Item 5** — one header comment in `CallForOffersService`. No metadata.
11. **D13 → D14** (`ARCHITECTURE.md`, same PR per §6).

---

# ❓ OPEN QUESTIONS — USER DECISION REQUIRED (Gate 1)

Four. Everything else in this document has a defensible default and has been **decided** rather than asked.

| # | Question | Options | Recommendation |
|---|---|---|---|
| **Q1** | 🔴 **Confirm: a claim whose winning Lead has CONVERTED does not expire.** | **(a)** converted ⇒ protected indefinitely; **(b)** converted claims expire too | **(a) — and this is a confirmation, not an open choice.** It is the only reading under which the re-point never touches a row whose lookup holds a converted Lead, i.e. the only one that satisfies `PropertyClaimService`'s own written prohibition **without** adding `Winning_Opportunity__c` to the registry, rewriting `Winning_Lead_Required`, and auditing every existing reader of `Winning_Lead__c` — roughly a tranche of work. It is also the stronger business answer: a converted winner is a live deal DPEG is transacting. **Stated cost:** a converted-then-dead deal protects its property for ever; the remedy is to delete the registry row by hand, which re-opens the key through the already-tested orphan-adoption path. |
| **Q2** | **The per-stage stall thresholds.** The FSD gives none, so these are numbers only you can set. | The §4.6 table, or your own | **Confirm or replace the §4.6 table.** The only structural recommendations are that thresholds are **per stage, not global** (a global one either spams PSA or never fires on New), that `Closed Won` and `Dead/Pass` are excluded, and that a stage absent from the map is simply never alerted. Changing a number later is a one-constant code change plus a deploy. |
| **Q3** | 🔴 **Is `AI Review Status` a DERIVED label or a WORKFLOW state an analyst can clear?** | **(a)** formula, derived from `Parse_Confidence__c` + `LeadSource` — no writer, no backfill, cannot drift from the deployed `Review_Queue`; **(b)** stored picklist an analyst sets to "Reviewed" | **(a).** Every input already exists and is already maintained; (b) needs a writer inside `EmailToLeadService` — a class the parallel session is editing — plus a backfill of every Lead, and it can then disagree with `Review_Queue` about the same record. **But (a) genuinely cannot express "I have checked this"**, and §11.1's wording is ambiguous about whether that is wanted. If it is, say so now: retrofitting a workflow state onto a formula field means deleting the formula and backfilling, which is worse than building it today. |
| **Q4** | 🔴 **Approve deliberately widening read access to `Inbound_Email_Staging__c`?** | **(a)** yes — a Lead-scoped, `without sharing` + `SYSTEM_MODE` read behind a `USER_MODE` Lead check; **(b)** no — leave the raw email backend-only and drop §27.1's third field | **(a).** The object is currently backend-only (Private OWD, no sharing rules, `viewAllRecords = false`), so **without this the component renders empty for every analyst with no error at all** — the "returns zero rows, looks healthy" failure this repo has already paid for twice. The FSD's own words justify it (*"stored for broker-protection audit"*). The exposure is bounded by construction: the method takes one record Id from the page, reads that Lead `WITH USER_MODE` **first** and lets a denial throw, returns only the staging row that produced it, and exposes no list and no filter. It is nonetheless a real widening of a deliberately-closed object and should be signed off rather than buried in a class header. |

---

# 🚦 POST-DEPLOY GATES (none of these is deployable metadata, and none fails loudly)

| # | Gate | Failure mode if skipped |
|---|---|---|
| **G1** | 🔴 **Schedule `StalledDealAlertSchedule`** (daily, off-peak). Record the cron expression **and the owning user**. | The class deploys, compiles, covers and is **completely inert** — zero alerts, zero errors, zero failed `AsyncApexJob` rows. Worse than the sweepers it resembles: they leave rows on a `Failed` status a human can list; an unscheduled alert job leaves **no trace at all**, and "no alert arrived" is indistinguishable from "no deal is stalled". Verify in Setup. |
| **G2** | 🔴 **Verify `Opportunity.LastStageChangeDate` exists in the org** BEFORE building A3/A5 (§4.2). | Building the custom stamp field and flow when the platform already maintains the value is duplicated, drift-prone work; assuming the standard field exists when it does not ships a formula over a null column that reads blank for ever. |
| **G3** | 🔴 **Run the Item 4 backfill** (§4.5) and record that the first alert wave is **approximate**. | Without it, every Opportunity in the org is invisible to the stalled-deal alert until it next changes stage — silently, and precisely the long-stalled deals are the ones least likely to move. |
| **G4** | 🔴 **Reconcile every touched permission set against the org before deploying it** (A9). | A `PermissionSet` deploy **REPLACES** its entire `<fieldPermissions>` set; an org-side-only grant absent from the file is silently wiped (paid twice on this project). ⚠ Sharpened here: **three of these files are being edited by a parallel session**, so the repo copy may be stale in two directions at once. |
| **G5** | **Confirm the `Acquisition` queue's membership** is the intended stalled-deal audience. | Tranche 1 measured it at **one** member. Queue membership is not deployable and no test can see it — alerts fire to one person, or to nobody. |
| **G6** | 🔴 **After Item 1 deploys, re-submit a property whose claim is >90 days old with a CONVERTED winner, as a real acquisitions persona.** | This is the only way to observe Q1's rule in production. The Apex test **cannot** falsify it — `platform_lookupToAConvertedLead_isNotEnforcedInTestContext` pins that test context does not enforce the converted-Lead restriction, so a green suite proves the decision, not the platform. |
| **G7** | **Verify `Protection_Expiry_Date__c` equals what `PROTECTION_WINDOW_DAYS` says**, in the org, once. | Five hardcoded copies of 90 exist across Apex and formula metadata (§1.2). The Apex test pins the formula against the constant, but only a live row proves the deployed formula is the one the test compiled against. |
| **G8** | **Open a Lead's raw-email component as a real acquisitions persona, not an administrator** (Q4). | An administrator passes for reasons unrelated to the design. The failure this catches is an empty panel on every analyst's screen with no error — the exact shape of the `RoutingReads` incident. |
| **G9** | ⚠ **Re-verify `EmailToLeadService.LEAD_SOURCE` and `BrokerPortalService.LEAD_SOURCE` at build time** and match A6's formula literals to them exactly. | Verified today as `'Email-to-Lead'` and `'Broker Portal'`. A mismatch makes **every** pipeline Lead read "Manually Entered" — a formula that is confidently, silently wrong on 100% of rows, with nothing to error. |
| **G10** | 🚦 **Confirm `Property_Package__c` has reached the org before starting D11/D12** (P11). | `OpportunitySelector` will not deploy, and the failure surfaces as "Dependent class is invalid" across every class that touches it — a cascade that looks like a defect in Item 4. |

---

# 🚩 FLAGGED — DROP / DEFER / RE-SCOPE

| Item | Flag |
|---|---|
| **Item 5 in its entirety** | 🚩 **DROP — the requirement is already over-satisfied.** The ladder is `{7, 3, 1, 0}`, not `{7, 3, 1}` (P6), and the FSD's proposed 2 days is bracketed by two live rungs. Configurability additionally destroys the only test that keeps the bell and the badge agreeing. Deliverable: **one header comment.** |
| **The NDA ladder moving to config** | 🚩 **DROP for the same reasons.** Consistency is preserved by leaving **both** hardcoded and test-pinned, not by moving both to config. |
| **Item 1 as "add a date filter"** | 🔴 **RE-SPECIFY.** A filter alone produces a **permanently unclaimable property** (P4). The mechanism is a filter **plus** a third adoption leg in `registerWinner`, and that leg is only admissible because it is scoped to unconverted winners (Q1). |
| **Item 1's record of the handover** | ⚠ **RE-SCOPE from "re-point and mark" to "re-point only".** Any "superseded" marker is another registry write and re-opens the P3 prohibition. The moved `Winning_Lead__c` plus two submission rows plus `Protection_Expiry_Date__c` make the handover reconstructible. |
| **Item 2 as "populate the dead Contact fields"** | 🔴 **DROP the stored-rollup reading entirely.** A competing broker never receives a Lead, therefore never a Contact — so Contact-based rollups **structurally omit every losing broker**, which is the population the leaderboard is about (§2.1). Leave all six fields untouched. |
| **Item 2's Deals Won / Lost by deal outcome** | 🚩 **DEFER.** Needs both winner anchors, a conversion hop, and `OpportunitySelector` (blocked, P11) — and "did DPEG close it" is a different question from "did this broker win the property". Price separately. |
| **Item 3's `AI Confidence (per field)`** | 🔴 **DROP.** The model returns two confidences and both are about classification; per-field would need a prompt change that re-pins the regression fixtures and can silently alter **who wins a property**. The genuine need — which fields were missed — is already served by `Extraction_Score_Pct__c` / `Fields_Captured_Count__c` / `Fields_Missing_Count__c`, all three already on the Lead record page. |
| **Item 3's `Raw Email Content` as a Lead field** | 🔴 **RE-SCOPE to a linked read.** Copying it makes a **third** copy (~128 KB/Lead) of content already retained on `Inbound_Email_Staging__c` and again in the pipeline `Task.Description`, written from a class the parallel session is editing. |
| **Item 3 overall** | ⚠ **SEQUENCE LAST or DEFER.** Highest collision surface in the tranche (Lead fields, `Lead_Record_Page`, three permission sets, `EmailToLeadService`). Its value is also the lowest of the five — two of its three fields already exist under other names. **If the tranche must be trimmed, cut this item.** |
| **Item 4** | 🚦 **GATED, not dropped.** Declarative half is free; the Apex half waits on `Property_Package__c` (P11). |
| **`Lead.BP_Expiry__c` deletion** | 🚩 **DEFER.** It is live on a flexipage, a compact layout and two permission sets (P1). Correct its description now; delete it as its own small change. |

## Findings OUT OF SCOPE — reported, not folded in

1. 🔴 **The exact/fuzzy claim asymmetry (P2) is a live defect today, independent of this tranche.** Until Item 1 lands, a broker who re-words an address wins a >90-day-old property while one who copies it exactly does not. If Item 1 slips, this is worth its own one-line fix.
2. **`PropertyRegistrySelector.selectRecentWithWinner` is capped at `LIMIT 200`.** The fuzzy match scans only the 200 most recent winners in the window. At the org's current volume this is invisible; past ~200 registrations in 90 days the fuzzy path starts silently missing older winners — which now also means silently **releasing** them. Not touched here because Item 1 does not change it, but it is a scaling cliff with no error.
3. **The six Contact broker-stat fields are read by `BrokerController` and written by nothing** — the Broker Hub renders permanent zeroes for `Deals_Submitted__c` / `Deals_Won__c` today. This tranche routes around them rather than fixing them. The real fix is either to retire the two submission-flavoured ones or to point the hub at the ledger.
4. **`CompetingBrokerSubmissionSelector.selectByWinningLead` is still Lead-only** (ARCHITECTURE's named open gap): a converted winner's competing-broker trail has no UI surface at all. Item 2 sidesteps it by aggregating on `Broker_Email__c`, but the Lead-page component remains blind post-conversion.
5. **`ExtractionScoreUtil` already computes the set of MISSING extraction keys** to produce `Fields_Missing_Count__c`, and then discards the names. Surfacing them would give §27.1 the per-field signal it is really asking for, at a fraction of a prompt change. Small, separate, and worth doing.
6. **`Inbound_Email_Staging__c` has no lookup to anything** — `Result_Record_Id__c` is a Text pointer and `Routed_Record_Ids__c` a text list. A7 indexes it; making the relationship real is a bigger change with a migration, and is deliberately not proposed.
7. **`Lease_Inquiry__c.Days_In_Stage__c` carries the `BlankAsZero` defect (P10)** on its own object, today. Item 4 avoids copying it; fixing the original is a separate one-attribute change with a re-check of the three Leasing reports that read it.
8. **ARCHITECTURE §2 names two Opportunity record types (Land / Commercial); there are three** — `Retail` also exists with its own business process. Not corrected here because no item in this tranche keys on record type, but §6 says the doc should track it.

---

# 📝 PROMPTS FOR SPECIALIST AGENTS

## 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md and .claude/rules/* first. Work on branch
feature/acquisitions-fsd-tranche-1. Create metadata files only — DO NOT DEPLOY.
API version 67.0. Package directory force-app/main/default.

⚠ A PARALLEL SESSION IS EDITING THIS TREE. Do NOT touch Property_Package__c, the
PropertyPackage* classes, or any Property_Package__c field on Opportunity/Lead/Property.
Before editing DPEG_Acquisition_Edit, DPEG_Acquisition_View, Broker_Protection_Access,
flexipages/Lead_Record_Page or flexipages/Opportunity_Record_Page, re-read the file from
disk immediately before writing — they are being changed concurrently.

=== ITEM 1 — BROKER PROTECTION EXPIRY ===

1. NEW formula field Property_Registry__c.Protection_Expiry_Date__c
     type: Formula, formulaReturnType Date
     formula: DATEVALUE(Registered_DateTime__c) + 90
   Put the rationale in an XML COMMENT INSIDE the root <CustomField> element (never
   above it — that breaks sf deploy at source conversion with a misleading "unable to
   find matching parent xml file"; <description> caps at 255 chars). Precedent:
   objects/Lead/fields/Extraction_Score_Pct__c.field-meta.xml. The comment must record:
   (i) 90 is hardcoded in FIVE places — PropertyMatchingService.LOOKBACK_DAYS,
   PropertyMatchingService.PROTECTION_WINDOW_DAYS, LeadFunnelController.BP_WINDOW_DAYS,
   Lead.BP_Expiry__c's formula, and here — because a formula cannot read an Apex
   constant; an Apex test pins this one against PROTECTION_WINDOW_DAYS;
   (ii) 🔴 a claim whose Winning_Lead__c is CONVERTED does NOT expire, so on those rows
   this date is ADVISORY ONLY and a past date does not mean the property is claimable;
   (iii) expiry is evaluated LAZILY at claim time, so nothing changes on this record when
   the date passes — this field exists so the window is visible and reportable at all.

2. Correct the <description> of the EXISTING Lead.BP_Expiry__c. DO NOT DELETE THE FIELD —
   it is rendered on flexipages/Lead_Record_Page (line ~351) and on
   compactLayouts/Lead_Highlights, and carries FLS in two permission sets. New text must
   say: this is a LEAD-LEVEL DISPLAY APPROXIMATION; one Lead can hold several property
   claims with different expiries (ExtractAddressQueueable routes up to 10 properties per
   email); the claim window starts at Property_Registry__c.Registered_DateTime__c, not at
   First_Seen_Date__c; the authoritative value is
   Property_Registry__c.Protection_Expiry_Date__c.

3. OPTIONAL, RECOMMENDED: a Property_Registry__c list view "Expired Protection",
   filterScope Everything, filter Protection_Expiry_Date__c lessThan TODAY. Columns:
   Name, Normalized_Address__c, Winning_Lead__c, Registered_DateTime__c,
   Protection_Expiry_Date__c.

=== ITEM 3 — LEAD AI REVIEW STATUS ===

4. NEW formula field Lead.AI_Review_Status__c, type Formula, formulaReturnType Text:
     IF( AND( TEXT(LeadSource) <> "Email-to-Lead",
              TEXT(LeadSource) <> "Broker Portal" ),
         "Manually Entered",
     IF( ISPICKVAL(Parse_Confidence__c, "LOW"), "Needs Review", "Auto-Accepted" ) )
   🔴 BEFORE WRITING: re-read EmailToLeadService.LEAD_SOURCE and
   BrokerPortalService.LEAD_SOURCE and use those literals EXACTLY. Verified 2026-08-17 as
   'Email-to-Lead' and 'Broker Portal'. A mismatch makes every pipeline Lead read
   "Manually Entered" — confidently and silently wrong on 100% of rows, with no error.
   XML comment INSIDE the root element must record: it is DERIVED, not stored, and carries
   NO workflow state (a human cannot mark a Lead reviewed); "Needs Review" is exactly the
   population of the deployed Review_Queue list view (Parse_Confidence__c equals LOW), so
   the two can never disagree; the LLM-down degrade path writes LOW, so emails the model
   never read are correctly included.

5. Inbound_Email_Staging__c.Result_Record_Id__c: change externalId from false to TRUE.
   Nothing else about the field changes. It is Text(18) and currently unindexed, and a
   WHERE Result_Record_Id__c = :leadId read against a table that grows with every inbound
   email is non-selective.

=== ITEM 4 — STALLED DEAL REMINDERS ===

6. 🔴 FIRST, VERIFY IN THE ORG whether the standard field Opportunity.LastStageChangeDate
   exists (it is a standard DateTime and will NOT appear in objects/Opportunity/fields/).
   • If it EXISTS: SKIP steps 7 and 9 entirely, and in step 8 use
     TODAY() - DATEVALUE(LastStageChangeDate) instead of Stage_Start_Date__c.
   • If it is ABSENT: build steps 7, 8 and 9 as written.
   Record which branch you took in the Days_In_Stage__c XML comment.

7. (fallback only) NEW Opportunity.Stage_Start_Date__c, type Date, not required, no
   default. Description: system-maintained stage-entry stamp; not for manual entry.

8. NEW Opportunity.Days_In_Stage__c, Number formula, precision 18 scale 0:
     IF( OR( ISPICKVAL(StageName, 'Closed Won'), ISPICKVAL(StageName, 'Dead/Pass') ), 0,
     IF( ISBLANK(Stage_Start_Date__c), null, TODAY() - Stage_Start_Date__c ) )
   🔴 formulaTreatBlanksAs MUST BE BlankAsBlank, NOT BlankAsZero. XML comment INSIDE the
   root element must record that this DELIBERATELY DIVERGES from
   Lease_Inquiry__c.Days_In_Stage__c, which uses BlankAsZero, and name the reason: under
   BlankAsZero a deal with no stamp reads 0 days in stage FOREVER — indistinguishable from
   "moved today" — and is permanently invisible to the stalled-deal alert. That is the
   same defect ARCHITECTURE.md records for Broker_Listing__c.Days_On_Market__c ("a clock
   that looks healthy and never ticks"). Do not harmonise it back.
   ⚠ 'Dead/Pass' is the LITERAL decoded form in a formula. Dead%2FPass is required only
   inside BusinessProcess / RecordType / picklist metadata.

9. (fallback only) NEW flow Opportunity_Stage_Timer: AutoLaunchedFlow, apiVersion 67.0,
   object Opportunity, triggerType RecordBeforeSave, recordTriggerType CreateAndUpdate,
   status Active. One Boolean formula ISNEW() || ISCHANGED({!$Record.StageName}), one
   decision, one assignment $Record.Stage_Start_Date__c = $Flow.CurrentDate. Mirror
   flows/Lease_Inquiry_Stage_Timer exactly.
   🔴 BEFORE-SAVE IS MANDATORY. An after-save update would re-fire the whole Opportunity
   trigger chain (OpportunityReviewTriggerHandler -> PropertyAssetService,
   DealFolderService, openTransactionsOnAboutToClose) AND issue a second DML on a record
   that may be locked by Underwriting_Approval, throwing ENTITY_IS_LOCKED. A before-save
   assignment issues no statement at all.

10. TWO new Opportunity fields (the alert marker pair):
      Stall_Alert_Last_Threshold__c   Number, precision 4, scale 0
      Stall_Alert_Stage__c            Text, length 60
    Descriptions must say both are system-maintained alert markers, not for manual entry,
    and that Stall_Alert_Stage__c is the SNAPSHOT of the stage the marker was computed
    against — when it differs from the live StageName the marker is treated as blank and
    the whole alert re-arms. Without it, a deal alerted at LOI, advanced to Under Contract
    (PSA) and stalled again there is NEVER alerted again, silently.

=== FLS AND SURFACING ===

11. FLS for every field above, declared IN FILE:
      Opportunity fields  -> the sets that already carry Opportunity.Deal_Bucket__c:
                             DPEG_Acquisition_Edit, DPEG_Acquisition_View,
                             DPEG_Opportunity_View
      Lead.AI_Review_Status__c -> wherever Lead.Parse_Confidence__c already sits
      Property_Registry__c formula -> wherever Registered_DateTime__c already sits
    Formula fields are READABLE ONLY (editable=false).
    🔴 A PermissionSet deploy REPLACES its entire <fieldPermissions> set. Reconcile each
    file against the org before editing it and do not drop any existing entry. THREE of
    these files are being edited by a parallel session — re-read from disk immediately
    before writing.

12. flexipages/Broker_Hub: add the c/brokerLeaderboard component.
13. flexipages/Lead_Record_Page: add Record.AI_Review_Status__c beside the existing
    Parse_Confidence__c / Extraction_Score_Pct__c / Fields_Missing_Count__c block
    (lines ~301-331), and the c/leadInboundEmail component.
    ⚠ COMPONENTS AND FIELD INSTANCES ONLY. Do NOT add a quick action to either flexipage —
    doing so silently empties that page's inherited action list, and no test catches it.

DO NOT create any other field, validation rule, permission set, layout, flow, report,
sharing rule or list view. Do not create a Custom Setting. Do not delete Lead.BP_Expiry__c.
Do not deploy.
```

## 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md and .claude/rules/* first, plus
agent-output/design-requirements-fsd-tranche-3.md. Work on branch
feature/acquisitions-fsd-tranche-1. API version 67.0. Do not deploy. Use TestDataFactory.
Every selector method is WITH USER_MODE unless justified at its own declaration.

⚠ A PARALLEL SESSION IS EDITING THIS TREE. It owns Property_Package__c and the
PropertyPackage* classes, and has already edited OpportunitySelector, LeadSelector,
ExtractAddressQueueable, EmailToLeadService, LeadConvertService and LeadFunnelController.
Re-read any of those from disk immediately before writing.
🔴 OpportunitySelector CANNOT DEPLOY from this tree today (its selectPackageAnchorById
references Opportunity.Property_Package__c, absent from the org). ITEM 4's D11/D12 are
BLOCKED until that field reaches the org. Everything else is unblocked.

=== ITEM 1 — CLAIM EXPIRY (build this first; zero collision) ===

1. EDIT PropertyRegistrySelector — ADD ONLY. ⚠ Its header carries a SIGNATURE CONTRACT:
   do not rename or re-parameterise the three existing methods. Add two:
     selectLiveByPropertyKey(Set<String> keys, Datetime cutoff)
       WHERE Property_Key__c IN :keys AND Winning_Lead__c != null
         AND (Registered_DateTime__c >= :cutoff OR Winning_Lead__r.IsConverted = true)
     selectExpiredByPropertyKey(String key, Datetime cutoff)   // LIMIT 1
       WHERE Property_Key__c = :key AND Winning_Lead__c != null
         AND Registered_DateTime__c < :cutoff
         AND Winning_Lead__r.IsConverted = false
   Both keep the class's stable field shape and add Winning_Lead__r.IsConverted. Both
   WITH USER_MODE on the with sharing class — state AT THE METHOD that
   Property_Registry__c is sharingModel = ReadWrite (verified), so neither ARCHITECTURE's
   automation-path SYSTEM_MODE exception nor a `without sharing` inner class is warranted
   here. Mark the existing selectByPropertyKeyWithWinner in its Javadoc as the UNWINDOWED
   read, or delete it if it ends up with no callers — do not leave two same-shaped reads
   with silently different semantics.

2. EDIT PropertyMatchingService:
   - Add `public static final Integer PROTECTION_WINDOW_DAYS = 90;` beside LOOKBACK_DAYS.
     🔴 Header must record the invariant LOOKBACK_DAYS >= PROTECTION_WINDOW_DAYS and WHY:
     if the protection window were ever longer, a claim in the gap would be protected on
     the exact path and invisible on the fuzzy path, so a re-worded resubmission would win
     a property an identically-worded one loses. Pin it with a test. Also register all
     FIVE hardcoded copies of 90 (LOOKBACK_DAYS, PROTECTION_WINDOW_DAYS,
     LeadFunnelController.BP_WINDOW_DAYS, Lead.BP_Expiry__c's formula,
     Property_Registry__c.Protection_Expiry_Date__c's formula).
   - findMatchingRegistry: its EXACT leg moves to
     selectLiveByPropertyKey(keys, Datetime.now().addDays(-PROTECTION_WINDOW_DAYS)).
     The FUZZY leg is UNTOUCHED — it is already windowed at LOOKBACK_DAYS, and that
     asymmetry is the defect being fixed.
   - New findExpiredRegistry(String normalized) -> Property_Registry__c or null,
     mirroring findOrphanedRegistry exactly.

3. EDIT PropertyClaimService.registerWinner — add ONE new leg to the DUPLICATE_VALUE
   catch, AFTER the existing orphan-adoption leg:
       Property_Registry__c expired = PropertyMatchingService.findExpiredRegistry(normalized);
       if (expired != null) {
           expired.Winning_Lead__c        = sourceLeadId;
           expired.Normalized_Address__c  = normalized;
           expired.Registered_DateTime__c = Datetime.now();
           update expired;
           insertSubmission(buildSubmission(sourceLeadId, sourceLeadId, sourceLeadId,
               extracted, submittedOn, forwardedByEmail, emailSubject, true));
           return ClaimOutcome.WINNER;
       }
   🔴 IT MUST BE BYTE-IDENTICAL TO THE ORPHAN LEG's field set. Two adoption paths writing
   two different field sets is how Registered_DateTime__c acquires two meanings, and both
   the fuzzy lookback and the new expiry depend on it having exactly one.

   🔴 AMEND THE CLASS HEADER'S "THE PROHIBITION: DO NOT ADD A THIRD" PARAGRAPH IN PLACE.
   Do not leave it standing and do not delete it. It must now say: there are THREE DML
   statements against Property_Registry__c; the third is an adoption of an EXPIRED row; it
   is admissible ONLY because selectExpiredByPropertyKey filters
   Winning_Lead__r.IsConverted = false, so it can never update a row whose lookup holds a
   converted Lead; and THE PROHIBITION STILL STANDS for any update not carrying that
   filter.

   Also record in the header:
   - WHY a converted winner's claim does not expire (it is the only reading under which
     the re-point never touches a prohibited row, and the only one that avoids giving this
     object the split anchor Competing_Broker_Submission__c has).
   - THE OPERATIONAL ESCAPE HATCH: a converted-then-dead deal protects its property
     forever; delete the registry row by hand and the key re-opens through the EXISTING,
     already-tested orphan-adoption path. No new code.
   - RESIDUAL R1: branch (b) REPEAT runs before branch (d) and never consults the
     registry, so after a handover the SUPERSEDED broker's follow-ups are filed on their
     own now-worthless Lead and raise no competing submission against the new winner, for
     up to 90 days. Accepted; the email is still captured, logged and auditable.

4. EDIT ExtractAddressQueueable — HEADER COMMENT ONLY, NO CODE CHANGE. Record R1 there
   too. ⚠ Parallel-session collision: re-read the file immediately before writing, and if
   it is mid-edit, defer this one comment to the end of the tranche.
   🔴 DO NOT change any routing branch. The whole point of this design is that changing
   findMatchingRegistry flips an expired property from branch (d) to branch (e)
   EVERYWHERE AT ONCE — the pre-read, the in-lock authority and the competing branch all
   call that one function, so they cannot disagree.

=== ITEM 2 — BROKER LEADERBOARD ===

5. EDIT CompetingBrokerSubmissionSelector — ADD ONLY (same SIGNATURE CONTRACT caution).
   Two aggregate methods:
     A: SELECT Broker_Email__c e, MAX(Broker_Name__c) n, COUNT(Id) c,
               MIN(Submitted_DateTime__c) firstSub, MAX(Submitted_DateTime__c) lastSub
        FROM Competing_Broker_Submission__c WHERE Broker_Email__c != null
        GROUP BY Broker_Email__c ORDER BY COUNT(Id) DESC LIMIT :maxRows
     B: the same, plus AND Is_Winning_Submission__c = true
   WITH USER_MODE, with sharing — state at the method that
   Competing_Broker_Submission__c is sharingModel = ReadWrite (verified), so no
   `without sharing` inner class is warranted and adding one would be an unargued
   widening.

6. NEW BrokerLeaderboardService (with sharing). Calls A and B and merges in memory.
   2 SOQL / 0 DML, CONSTANT in broker count. No SOQL or DML in loops.
   Header must record:
   - 🔴 WHY THE SIX DEAD Contact FIELDS ARE NOT USED AND MUST NOT BE: a competing broker
     receives no Lead (since 2026-07-31), therefore no conversion, therefore no Contact,
     ever. Contact-based rollups can only describe brokers who WON AND CONVERTED, so they
     structurally omit every losing broker — the population this leaderboard is about.
     Also Competing_Broker_Submission__c has NO Contact lookup, so no roll-up summary
     exists; the identity is Broker_Email__c, a Text field.
   - 🔴 THE SPLIT WINNER ANCHOR DOES NOT AFFECT THESE COUNTS, because both aggregates
     group by Broker_Email__c and read NEITHER Winning_Lead__c NOR Winning_Opportunity__c.
     It WILL bite the moment anyone adds a drill-through or a deal-outcome column, at
     which point BOTH anchors must be read and selectByWinningLead is Lead-only.
   - MAX(Broker_Name__c) is DETERMINISTIC-ARBITRARY, not "the latest" — one address can
     carry several spellings. The row is keyed by EMAIL; the name is a display hint. Do
     not add a third query to improve it.
   - THE BLAST-PLATFORM RESIDUAL: a platform sender (listings@buildout.com) collapses many
     brokers onto one address, so the top row may be a platform rather than a person.
     Display it; do not suppress it (that would hide real volume and make the totals
     disagree with the ledger) and do not build a name/domain heuristic here.

7. NEW BrokerLeaderboardController — thin @AuraEnabled(cacheable=true) over (6), with the
   repo-standard ahe() helper and a FIXED user-safe message. Precedent: BrokerController.

8. NEW lwc/brokerLeaderboard — read-only, columns: Broker (name hint + email),
   Submissions, Properties Won, Win Rate %, First Submission, Last Submission. Shared
   .lv-* SLDS list chrome like the other list LWCs. apiVersion 67.0. Jest test +
   @sa11y/jest.
   🔴 DO NOT add a "Deals Won / Lost by Opportunity outcome" column — it needs both winner
   anchors, a conversion hop and OpportunitySelector (blocked), and it answers a different
   question from Is_Winning_Submission__c.

=== ITEM 3 — RAW EMAIL ON THE LEAD (build LAST) ===

9. EDIT InboundEmailStagingSelector: add selectByResultRecordId(Id recordId) inside a NEW
   `private without sharing` inner class named AuditReads, WITH SYSTEM_MODE, mirroring the
   existing RoutingReads. Justify MODE and SHARING as TWO SEPARATE decisions at the method:
     MODE — the row's fields are Metadata-API-deployed customs with no FLS for any profile.
     SHARING — Inbound_Email_Staging__c is sharingModel Private with NO sharing rules, rows
     are owned by the Email Service context user, and Broker_Protection_Access sets
     viewAllRecords = false, so under `with sharing` an acquisitions analyst sees ZERO rows
     with NO error — the "returns zero rows, looks healthy" failure this module has already
     paid for.
   Amend the class header's per-method mode policy in place (it already mixes modes).
   Select Id, Subject__c, Raw_Body__c, From_Address__c, From_Name__c, Forwarded_By__c,
   Processed_DateTime__c only. Read Result_Record_Id__c only — the multi-target
   Routed_Record_Ids__c case is explicitly out of scope; say so in the header.

10. NEW InboundEmailStagingController + lwc/leadInboundEmail (read-only).
    🔴 TWO SOQL, AND THE FIRST ONE IS THE SECURITY BOUNDARY. Because the staging read
    escapes both sharing and CRUD, the only remaining gate is Apex CLASS access, which is
    coarse. So the controller must:
      (a) accept ONE record Id from the page — never a list, never a filter;
      (b) read THAT Lead WITH USER_MODE first and let a denial throw;
      (c) only then fetch the staging row whose Result_Record_Id__c equals it.
    Never expose a list method. This is the same discipline ARCHITECTURE.md records for the
    retired UserSelector (every method hard-filtered, taking no caller-supplied scope).

=== ITEM 4 — STALLED DEALS ===

11. NEW StalledDealAlertService (with sharing) — PURE. No SOQL, no DML, clock is an
    argument. Holds the per-stage threshold Map<String,Integer> and NOTHING ELSE holds it.
    Apex, deliberately NOT Custom Metadata (same argument RecordStageAdvanceService makes
    for its stage map: an admin editing it with no deploy and no review). Terminal stages
    Closed Won and Dead/Pass are excluded; a stage absent from the map is never alerted,
    which is the correct fail-open. Public pure shouldFire(Integer threshold,
    Integer lastThreshold, String liveStage, String markerStage): fire only when the
    threshold is met AND (markerStage != liveStage OR threshold is strictly greater than
    lastThreshold). Mirror CallForOffersService / NdaExpiryService.
    Thresholds: USE THE VALUES THE USER CONFIRMS AT GATE 1 (Q2). Do not invent them.

12. 🚦 BLOCKED UNTIL Property_Package__c REACHES THE ORG:
    EDIT OpportunitySelector — add queryStalledDeals() returning Database.QueryLocator,
    WITH SYSTEM_MODE, on the with sharing class with NO `without sharing` inner class.
    🔴 ARGUE THE SHARING DECISION AT THE METHOD, DO NOT INHERIT IT: Opportunity internal
    OWD is ReadWrite (measured, recorded in ARCHITECTURE for
    selectCallForOffersTargetsByIds), so `with sharing` is SUFFICIENT here. This is a REAL
    DIFFERENCE from tranche 1's NdaSelector.ExpiryAlertReads, which needed a
    `without sharing` inner class only because NDA__c is sharingModel Private with no
    acquisition-side sharing rule. Do not copy that inner class by analogy.
    Carry the stated residual: if Opportunity OWD is ever narrowed to Private, this locator
    returns zero rows, finish() logs all-zeros, and that is indistinguishable from "no deal
    is stalled".
    ⚠ Do NOT create an OpportunityAlertSelector to dodge the deploy block — that is an
    apex-layering-rule violation bought to solve a scheduling problem.

13. 🚦 BLOCKED WITH (12): NEW StalledDealAlertBatch (Database.Batchable, Database.Stateful)
    + StalledDealAlertSchedule (Schedulable, daily, no logic).
    - SCOPE = 200, INHERITED from CallForOffersAlertBatch WITH THE CITATION, not
      re-measured: the cost model (~6.0 ms + 0.22 ms x |recipients| per notification) is a
      property of Messaging.CustomNotification.send(), not of the object.
    - 🔴 SEND FIRST, STAMP SECOND via GroupNotifier.notifyWithOutcome(...), stamping only
      rows whose send succeeded. Stamp-then-send loses an alert silently and forever;
      send-then-stamp merely repeats it tomorrow.
    - Stamp: plain Database.update(toStamp, false, AccessLevel.SYSTEM_MODE) — NO
      `without sharing` writer, for the same OWD = ReadWrite reason as (12). Another
      deliberate difference from the NDA job; say so.
    - RECIPIENT_GROUP = 'Acquisition' (the queue), matching CallForOffersAlertBatch and
      NdaExpiryAlertBatch. Keep it a non-final @TestVisible static so a swallowed send
      failure can be reproduced.
    - One asOf captured once per execute(), never Date.today() per record. Fail-soft per
      chunk (a batch has no Finalizer).

=== TESTS ===

14. ITEM 1 — PropertyClaimService is DE-EXEMPTED from the 251 mandate
    (.claude/rules/bulk-test-rule.md, narrowed 2026-07-31) and a literal 251 is documented
    there as impossible and meaningless. Write the replacement mandate instead:
    - boundary pair: an 89-day-old claim still wins; a 91-day-old claim with an
      UNCONVERTED winner is ADOPTED (Winning_Lead__c moves, Registered_DateTime__c resets,
      outcome WINNER, the new Lead survives);
    - a 91-day-old claim with a CONVERTED winner is NOT adopted (outcome DUPLICATE, no
      Lead, competing submission logged).
      🔴 STATE THE LIMIT OF THIS TEST IN ITS OWN COMMENT:
      PropertyClaimServiceTest.platform_lookupToAConvertedLead_isNotEnforcedInTestContext
      already pins that test context does NOT enforce the converted-Lead restriction, so
      this test proves THE DECISION and cannot prove the platform behaviour;
    - 🔴 THE HIGHEST-VALUE TEST: one property, two wordings, same day, either side of the
      boundary — exact and fuzzy must reach the SAME outcome;
    - LOOKBACK_DAYS >= PROTECTION_WINDOW_DAYS pinned directly;
    - Protection_Expiry_Date__c == Registered_DateTime__c.date().addDays(
      PROTECTION_WINDOW_DAYS) pinned;
    - an expired key NEVER returns UNCLAIMED (the falsifier for a future change that keeps
      the filter and drops the adoption leg);
    - governor: ExtractAddressQueueable.lastRunQueryCount UNCHANGED on both the WINNER and
      the DUPLICATE paths;
    - every existing orphan-adoption test stays green UNMODIFIED.

15. ITEM 4 — 251-row bulk test on the locator (a test method runs one chunk, so at
    SCOPE = 200 a 251-row fixture proves the locator selects/filters/orders 251 rows and a
    full 200-row chunk behaves). Plus: a terminal-stage deal is never selected; a blank
    stage-start deal is never selected (the BlankAsBlank falsifier); 🔴 A DEAL THAT
    STALLS, IS ALERTED, ADVANCES A STAGE AND STALLS AGAIN IS ALERTED AGAIN (the falsifier
    for dropping Stall_Alert_Stage__c); a double run is a no-op; a failed send is not
    stamped.
    ⚠ Governor assertions read counters captured INSIDE the async context, never Limits.*
    after Test.stopTest() — stopTest restores the pre-test counters and makes the obvious
    assertion silently vacuous.

16. ITEM 2 — BrokerLeaderboardServiceTest: aggregate correctness; a CONVERTED winner's
    rows are still counted (the split-anchor non-effect); win-rate arithmetic including a
    zero-submission guard; one email carrying several name spellings.
    Jest suite per new LWC.

=== ITEM 5 — NO CODE ===

17. CallForOffersService: ONE header comment only, no code change. Record that FSD §25.2.2
    proposes a single configurable reminder defaulting to 2 days; that the built ladder is
    {7, 3, 1, 0}, which BRACKETS it; and that configurability was assessed on 2026-08-17
    and deliberately rejected — partly because
    CallForOffersServiceTest.everyRungOfTheLadderMapsToExactlyOneBand is the ONLY thing
    holding ALERT_INTERVALS to CRITICAL_DAYS / APPROACHING_DAYS, and a runtime-configurable
    ladder makes that test unable to pin anything.

=== DOCS ===

18. ARCHITECTURE.md, same PR (§6): §1 Property_Registry__c gains the expiry semantics and
    the converted-winner rule; §2 Key Apex Services gains BrokerLeaderboardService,
    StalledDealAlertService, StalledDealAlertBatch, StalledDealAlertSchedule; the
    WITH SYSTEM_MODE table gains TWO rows (InboundEmailStagingSelector.AuditReads and
    OpportunitySelector.queryStalledDeals) each arguing MODE and SHARING as separate
    decisions; update the running "N SYSTEM_MODE queries across M selector classes" count;
    and amend the PropertyClaimService entry to record the third registry DML and why it
    is admissible.

DO NOT touch Property_Package__c or any PropertyPackage* class. Do not build a Custom
Setting. Do not add a Deals Won/Lost column. Do not write the six Contact broker-stat
fields. Do not deploy.
```
