# DESIGN REQUIREMENTS — Acquisitions Gap-Fix, Items 1–6

Date: 2026-08-30 · Revision 2 (all nine open questions answered)
Branch: `qa/lifecycle-simulation-2026-08-27`
Docs consulted: `CLAUDE.md`, `ARCHITECTURE.md`, `.claude/rules/{salesforce-global,apex-layering,bulk-test,invocable,content-publication}-rule.md`.

---

> # 🔴 THIS DOCUMENT IS THE RECORD OF TRUTH
>
> **Wherever this document and the originating task brief disagree, THIS DOCUMENT IS CORRECT.**
> The brief will not be in context for the specialist agents. Nine of its assertions were verified
> wrong or incomplete (§0); the coordinator independently re-verified every one of them and accepted
> the corrections. Do not "restore" a detail from memory of the brief — if it is not in this document,
> it is not in scope.
>
> **Status: ALL NINE OPEN QUESTIONS ANSWERED. All items are dispatchable.**
> Two answers **reverse** what this document previously recommended (Q1 and Q6). The superseded
> recommendations are retained in §0.5 with their reasoning, deliberately — they are what a future
> reader will re-propose on seeing the shape, and deleting them invites the loop again.

---

## §0 — FINDINGS: WHERE THE BRIEF AND THE ORG DISAGREED

Every surface inventory the brief asserted was re-derived from source. Nine were wrong or
incomplete. **All nine were independently re-verified by the coordinator and accepted.**

| # | Brief said | Verified reality | Consequence |
|---|---|---|---|
| F1 | "verify what `No_Backward_Stage_Movement` does and does not already prevent" | Dead/Pass ranks **0 = UNRANKED**, so clause 3 (`new rank > 0`) is FALSE for every move *into* Dead/Pass. **The rule never fires on entry to Dead/Pass from any stage, including Closed Won.** | Item 1's Closed Won half is a genuine gap. **Now approved to build — see Q1 in §0.5.** |
| F2 | (not stated) | `No_Backward_Stage_Movement`'s header records *"the user-required invariant that Dead/Pass stay reachable from every stage"* and names the Closed Won → Dead/Pass → earlier round trip as **"the actual recovery procedure for a mistakenly advanced deal"**. D4 rejected a bypass permission. Ranks 1–7 are blocked as backward; CARVE-OUT 2 excludes Closed Won. | **Dead/Pass is currently the ONLY exit from Closed Won.** The user was shown this and **overrode it**. See Q1 — this is now the highest-risk change in the tranche. |
| F3 | "Opportunity ALREADY has four before-save flows" | **Opportunity has TWO.** `Contract_Review_Stage_Sync` targets `Contract_Review__c`; `NDA_Signed_Status_Sync` targets `NDA__c`. Opportunity also has **five after-save flows** the brief omitted. | The brief's argument for Apex was priced at 2.5× reality. Conclusion stands, reason replaced — see F4. |
| F4 | "STRONGLY PREFER stamping in the existing `OpportunityReviewTriggerHandler` (before update)" | `OpportunityReviewTrigger` is `on Opportunity (**after insert, after update**)` — **there is no before context**. | The trigger must be **widened**. The real argument is order-of-execution: **before-save Flows run BEFORE Apex before-triggers**, so a before-trigger stamp is *guaranteed* to see the final `StageName` after `Opportunity_Initiate_Underwriting` rewrites it. A third before-save Flow has no such guarantee. |
| F5 | "`DispositionStageEntryService` does this for `Disposition__c`" | It creates stage-entry **child records** and fills one date for one stage. `Disposition__c` has no days-in-stage field. | Real precedents: **`Lease_Inquiry__c.Days_In_Stage__c`** (a *formula* over `Stage_Start_Date__c`) and **`stampListingDates`** (before-save, in-memory, zero statements). |
| F6 | "A VR alone **may** not fire if submission does not perform DML on the LOI" | **Not "may" — cannot.** `resolveApprovalTargetId` maps `LOI__c` → the **parent Opportunity**; `Approval.process` submits the Opportunity. **No DML touches the LOI row.** `Acquisition_LOI.recordType-meta.xml` says it independently. | **A VR on `LOI__c` is dead code.** Gate must be Apex. The approved record-type scoping is **already satisfied structurally**. |
| F7 | "(e) … **This is a likely latent bug**" | **Not a bug — already built, deliberately.** `CallForOffersService.shouldFire` line 416: `Integer effective = (markerDueDate == liveDueDate) ? lastInterval : null;` under the comment *"A DEADLINE THAT MOVED RE-ARMS EVERYTHING."* | **Item 5(e) is ZERO work.** Do not modify `shouldFire`. |
| F8 | "(d) the reminder interval (… the story's default is 2 days)" | No single interval. `ALERT_INTERVALS = {7, 3, 1, 0}` — a four-rung ladder. `Offer_Alert_Last_Interval__c` stores **the rung**. | Resolved as **Q5 option (i)**: preserve the ladder, move the rung values to CMDT. |
| F9 | "**GROUPNOTIFIER IS ACQUISITIONS-BRANDED** … hardcodes `Acquisitions_Deal_Update`" | **Stale.** Header line 7: *"It **was** a hardcoded private constant … with no override."* Now `DEFAULT_NOTIF_TYPE_DEV_NAME` + a per-`Request` override. | Conclusion holds (default type is correct for acquisitions); reason does not. No override needed. |
| **F10** | "the Owner and the **Acquisition Team public group**" / "the **Acquisitions** public group is EMPTY" | Three distinct objects exist: `queues/Acquisition`, `groups/Acquisitions_Team`, `groups/DPEG_Acquisitions_Team`. `NdaExpiryAlertBatch` records **Gate 1 decision Q2.3**: *"the `Acquisition` **QUEUE** … matching the only other alert job … is what stops the two disagreeing about who 'the Acquisition team' is."* | **Item 4 must use `RECIPIENT_GROUP = 'Acquisition'`.** Upside: the empty-membership go-live gate is the **same gate (G2) already open for two jobs**, not a third. |

### F11 — NEW (revision 2): `BrokerFirmController` already computes Item 6.1's three numbers

`BrokerFirmController.cls` lines 46–51 already derive **`dealsSubmitted` / `dealsWon` / `dealsLost`
per firm, live in Apex**, via `OpportunitySelector.countByStageForAccount(opp.AccountId)` and a
string compare on `'Closed Won'` / `'Dead/Pass'`. `BrokerFirmControllerTest` pins it with a
251-row test asserting 251 / 126 / 125.

Item 6.1's three Account roll-up summaries therefore create a **second computation of the same
three numbers**. They are still worth building — a roll-up is **reportable and queryable**, which a
live Apex computation is not, and that is exactly what the story's "Account roll-ups" AC asks for —
but the duplication must be recorded, not discovered later. **See Q10 (§0.5): the repoint of
`BrokerFirmController` onto the roll-up fields is deliberately OUT OF SCOPE for this tranche.**

---

## §0.5 — DECISION HISTORY (read before re-opening anything)

| Q | Question | Decision | Reverses my recommendation? |
|---|---|---|---|
| **Q1** | Block Dead/Pass from Closed Won? | 🔴 **YES — BUILD IT. User overrides the recorded invariant, with no replacement recovery route.** Presented with the full consequence (Closed Won becomes inescapable; D4 rejected a bypass permission; a wrongly-Closed-Won deal will need an admin data fix) and **reaffirmed**. | ✅ **YES.** I recommended amending the spec instead. Overruled. |
| **Q2** | Item 4 suppression cadence | **Fire once per stage occupancy.** | No — my default |
| **Q3** | Delayed vs the existing Stale widget | **Keep both, distinct titles.** | No — my default |
| **Q4** | Item 2 backfill | **Backfill from `LastModifiedDate.date()`**, caveat in the script header, RESIDUAL-6 retained. | No — my default |
| **Q5** | Item 5(d) CFO interval | **Option (i): make the four rungs configurable.** Ladder `{7,3,1,0}` preserved exactly; only the values move to CMDT. **No regression, no marker invalidation.** | No — my recommended reading |
| **Q6** | Item 6 Contact side | **Partially reversed.** Build the Contact counters via a nightly batch — **but scoped honestly and explicitly NOT as the leaderboard's source.** Leaderboard untouched. Every field carries a description naming its narrow population. | ✅ **PARTIALLY.** I recommended 6A or 6C. The user chose a disciplined 6B after accepting my three reasons. |
| **Q7** | "Default Open" | **Stamp `Open` in `CallForOffersStampService`** when a due date first appears on an existing deal, plus the insert-time field default. | No — my default |
| **Q8** | `Source_Broker__c` | 🔴 **DO NOT CREATE IT. Reuse `Listing_Broker_Name__c` / `Listing_Broker_Email__c`** — a CFO is issued by the seller's listing broker, which those fields already hold. | No — I recommended not creating it |
| **Q9** | Contact date field naming | **`First_Submission_DateTime__c`.** | No — my default |
| **Q10** | *(new, revision 2)* Repoint `BrokerFirmController` at the new roll-ups? | **OUT OF SCOPE for this tranche.** Flagged in F11 and RESIDUAL-8. Not silently expanded into. | n/a |

### 🔴 The superseded recommendation on Q1, retained deliberately

I recommended **not** blocking Dead/Pass from Closed Won, because `No_Backward_Stage_Movement`'s
header records the opposite as a user-required invariant and because Dead/Pass is the only exit
from Closed Won. **That recommendation was put to the user with its consequence stated and was
overruled.** It is kept here because it is what the next reader will re-propose on encountering
the contradiction — and the answer they need is *"this was considered on 2026-08-30 and
deliberately overridden"*, not a re-run of the argument.

### The superseded recommendation on Q6, retained deliberately

I recommended **6A** (extend the existing aggregate) or **6C** (no Contact-side work), because
Contact counters describe only the converted-winner subset. **The user accepted the reasoning and
then chose a narrower, honest version of 6B**: build the counters, but for the `Broker_Hub` surface
only, with the population stated on every field, and with the leaderboard explicitly left as the
authoritative source. That is a better outcome than either of my options, and the field
descriptions are what make it safe.

---

## §1 — ITEM 6 IN CONTEXT: THE METRIC-INVERSION RISK, AND HOW THE ANSWER CONTAINS IT

Retained because it is the reasoning that shapes Item 6, and the field descriptions required in
§2 ITEM 6 are meaningless without it.

`BrokerLeaderboardService`'s header argues against Contact-based rollups in three numbered reasons.
Reason 1 is the load-bearing one:

> *"🔴 MOST BROKERS IN THE LEDGER HAVE NO CONTACT AND NEVER WILL. Since 2026-07-31 a COMPETING
> broker receives no Lead at all, so no conversion, so no Contact, ever … A Contact-based rollup
> can therefore only ever describe the subset that WON and then CONVERTED — i.e. it would silently
> omit every losing broker … **That is not a trade-off; it is the metric inverting itself.**"*

**The user was shown this verbatim, agreed, and withdrew "broker must be a contact"** — their
words: *"leave this idea … a contact will be created on conversion so if it's sent by a new broker
which doesn't exist in the system then we can face some issue."*

**What makes the approved shape safe** is that the two surfaces are now explicitly *ranked*:

| Surface | Population | Role |
|---|---|---|
| `brokerLeaderboard` / `BrokerLeaderboardService` (**unchanged**) | **every broker who ever submitted**, winners and losers, Contact or not — keyed by `Broker_Email__c` | 🟢 **AUTHORITATIVE** |
| `Contact.Deals_*__c` (**new writer**) | brokers who won **and** converted, i.e. those who have a Contact | 🟡 fixes `BrokerController` / `Broker_Hub`'s permanent zeroes **only** |
| `Account.*` roll-ups (**new**) | every Opportunity on the firm Account | 🟡 firm-level, reportable |

🔴 **The four Contact field descriptions are the control that keeps this safe.** Without them, the
inversion gets rediscovered as a bug in six months. They are a hard requirement, not documentation
polish — see §2 ITEM 6.

**Reason 2 still stands and constrains the work:** `Active_Listings__c`, `Closed_Volume__c` and
`Avg_Days_On_Market__c` are the **disposition-side** scorecard. **Do not touch them.**

**Reason 3 does NOT transfer to the approved design — stated explicitly so it is not re-inherited.**
Reason 3 warned that any rollup would need *"Apex plus a fuzzy email match … under which a broker
with two addresses becomes ONE SILENTLY UNDERCOUNTED Contact."* That warning was about joining
**`Competing_Broker_Submission__c`** (which has **no Contact lookup** — its identity is a Text
email) to Contact. **The approved batch does not touch that object.** It keys on
**`Opportunity.Broker__c`, which is a real Contact lookup**, stamped by `LeadConvertService`
(`o.Broker__c = l.ConvertedContactId`). **There is no matching step, fuzzy or otherwise, anywhere
in this design.** The coordinator's reading is correct and is confirmed here so the next reader
does not re-inherit a warning that does not apply.

---

## §2 — ITEM-BY-ITEM DESIGN

### ITEM 1 — Rejection Reason required on Dead/Pass **+ Dead/Pass blocked from Closed Won**

**Verified:** `Rejection_Reason__c` exists, Picklist, `required=false`, **`restricted=true`**, 7
values, on all three record types. No VR enforces it. The picklist value is literally `Dead/Pass`
(`Dead%2FPass` inside `BusinessProcess`/`RecordType` metadata only — do not "correct" either form).

**ADMIN — TWO new validation rules, not one, and not a formula clause added to the existing rule.**

**Why two separate rules rather than one, and why not an amendment to `No_Backward_Stage_Movement`:**
- The two conditions need **different error messages** and **different `errorDisplayField`s** (one
  points at `Rejection_Reason__c`, one at `StageName`). Folding them into one rule forces a single
  generic message that serves neither.
- `No_Backward_Stage_Movement` is a 200-line, heavily-argued rule with two carve-outs and a rank
  map. Adding a clause to it means its `errorMessage` — *"A deal cannot be moved back to an earlier
  stage. **To stop work on this deal, move it to Dead/Pass instead.**"* — must also change, because
  that message would otherwise recommend a route that is now blocked. Keeping the new logic out of
  that formula limits the blast radius to a message edit and a header amendment.

**1A.** `objects/Opportunity/validationRules/Rejection_Reason_Required_On_Dead.validationRule-meta.xml`
```
AND(
  ISCHANGED(StageName),
  ISPICKVAL(StageName, 'Dead/Pass'),
  ISBLANK(TEXT(Rejection_Reason__c))
)
```
- `errorDisplayField`: `Rejection_Reason__c`
- `errorMessage`: *"Choose a Rejection Reason before moving this deal to Dead/Pass."*
- **`ISCHANGED`-gating is deliberate**: matches the story AC (a stage *change*), matches both
  sibling rules, inherits their accepted insert-time hole, and **keeps `scripts/seed-pipeline.apex`
  green** (§6.1).

**1B.** `objects/Opportunity/validationRules/Dead_Pass_Not_Allowed_From_Closed_Won.validationRule-meta.xml`
```
AND(
  ISCHANGED(StageName),
  ISPICKVAL(PRIORVALUE(StageName), 'Closed Won'),
  ISPICKVAL(StageName, 'Dead/Pass')
)
```
- `errorDisplayField`: `StageName`
- `errorMessage`: *"A Closed Won deal cannot be moved to Dead/Pass. Contact your administrator."*
  (The message must **not** suggest a self-service route, because there is none.)
- **`PRIORVALUE`-keyed, so it is transition-only and inherently self-limiting** — the same
  stickiness property `No_Backward_Stage_Movement`'s CARVE-OUT 1 relies on. A record already
  sitting at Dead/Pass is unaffected; `PRIORVALUE` is re-derived from the immediately prior stored
  value on every save and cannot go stale.

**🔴 1C — THE HEADER BLOCK. THIS IS THE HIGHEST-RISK CHANGE IN THE TRANCHE AND IS NOT OPTIONAL.**

Rule **1B reverses a recorded prior user decision.** A reader who finds only the older header will
be actively misled. `Dead_Pass_Not_Allowed_From_Closed_Won` must carry an XML comment **inside the
root element** (a comment *above* the root breaks `sf` at source conversion with a misleading
parent-xml error) containing all five of:

1. The **2026-08-30 user decision and its date**, and that it was **reaffirmed after the
   consequence was stated**.
2. The superseded invariant **quoted verbatim** — *"the user-required invariant that Dead/Pass stay
   reachable from every stage"* — and **where it is recorded**
   (`objects/Opportunity/validationRules/No_Backward_Stage_Movement.validationRule-meta.xml`).
3. A plain statement that **Closed Won now has NO in-app exit**: ranks 1–7 are blocked as backward,
   CARVE-OUT 2 excludes Closed Won, D4 rejected a bypass permission, and this rule closes the last
   route. **A wrongly-Closed-Won deal requires an admin data fix.**
4. That **no bypass custom permission was added**, and that adding one would re-open D4.
5. A warning that **anyone reading only `No_Backward_Stage_Movement`'s header will be misled**, with
   a pointer to this file as the current decision.

⚠ `<description>` is capped at **255 characters** (breached three times in this programme). The
block above goes in the **comment**, not the description.

**🔴 1D — FOUR OTHER FILES CARRY PREMISES THIS OVERRIDE FALSIFIES OR NARROWS. All four must be
amended in the same change**, in this repo's retracted-verbatim-then-corrected house style:

| File | What becomes false | Required edit |
|---|---|---|
| `objects/Opportunity/validationRules/No_Backward_Stage_Movement.validationRule-meta.xml` | Its **`errorMessage`** — *"To stop work on this deal, move it to Dead/Pass instead"* — now recommends a **blocked** route for Closed Won deals. Its header's "two-save round trip through Dead/Pass IS the actual recovery procedure" paragraph and its "Dead/Pass always reachable, per invariant" claim are both now false for Closed Won. | Amend the `errorMessage`; **retract the recovery-procedure paragraph verbatim** and point at rule 1B as current. |
| `classes/DealFolderService.cls` | Its header lists **"the Dead/Pass two-save recovery"** as one of seven live routes into `CLAIM_STAGES`. | **Narrowed, not falsified** (Dead/Pass is still reachable from ranks 1–7). Amend to say the route no longer exists *from Closed Won*. |
| `classes/LeadPropertyEmailGateTest.cls` | Its header justifies the Lead `Disqualified` carve-out as *"mirroring the Opportunity Dead/Pass invariant"* — an invariant that no longer holds universally. | Amend the justification. ⚠ **Do NOT change the Lead behaviour** — the Lead carve-out was not part of this decision and must not be swept along. |
| `classes/OpportunityReviewServiceTest.cls` (`noDuplicateOnReentry`, ~line 707) | Its comment asserts *"entering it is always allowed (the escape hatch every stranded deal needs)"*. | **The test still PASSES** — it moves away from Development Review (rank 3), not Closed Won. **Amend the comment only.** A future test copying this pattern from Closed Won would fail confusingly. |

**Routing: 🔵 `salesforce-admin`** for 1A/1B/1C and the `No_Backward_Stage_Movement` edit;
**🟢 `salesforce-developer`** for the three Apex header/comment amendments in 1D.

---

### ITEM 2 — Stage-entry date stamping (feeds Item 4)

**Verified:** Opportunity has neither field. ⚠ `Days_in_System__c` exists with a **lowercase `in`** —
a pre-existing `ARCHITECTURE.md` §1 violation. **Do not copy that casing.**

| Field | Type | Rationale |
|---|---|---|
| `Stage_Entry_Date__c` | **Date** | Item 4's threshold is whole days, the batch runs daily, sub-day precision buys nothing, and a `Date` makes `TODAY() - Stage_Entry_Date__c` exact and timezone-free. Matches `Lease_Inquiry__c.Stage_Start_Date__c`. ⚠ Counter-precedent as a *warning*: `Lead.First_Seen_Date__c` is a **DateTime despite its Date suffix** — a violation `LeadConvertService` documents and refuses to "fix" because a rename is a delete-and-create. |
| `Days_In_Stage__c` | **Formula (Number, scale 0)** | Zero storage, always current, no batch to keep it fresh. `IF(IsClosed, 0, IF(ISBLANK(Stage_Entry_Date__c), null, TODAY() - Stage_Entry_Date__c))`, `formulaTreatBlanksAs = BlankAsZero`. Use **`IsClosed`** rather than naming the two stages: it is the standard formula field, is true for both (verified in `OpportunityStage.standardValueSet`), and survives a future added closed stage. |

**Where the stamp goes — Apex before-trigger.** Before-save Flows run **before** Apex
before-triggers, so a before-trigger observes the final `StageName` after
`Opportunity_Initiate_Underwriting` has rewritten it, while `Trigger.oldMap` still holds the true
prior DB value. A third before-save Flow would have **no defined ordering** relative to the two
existing ones.

**DEVELOPER**
1. `triggers/OpportunityReviewTrigger.trigger` — **MODIFY**: widen to
   `on Opportunity (before insert, before update, after insert, after update)`.
2. `classes/OpportunityReviewTriggerHandler.cls` — **MODIFY**: add `beforeInsert()` /
   `beforeUpdate()` overrides. Update the class header (it says "Routes the after-insert and
   after-update contexts" and enumerates five after-context calls — both become incomplete).
3. `classes/OpportunityStageEntryService.cls` — **NEW**.
   `stampStageEntryDates(List<Opportunity>, Map<Id,Opportunity>)`.
   **Zero SOQL, zero DML at any record count** — a pure in-memory assignment, the
   `stampListingDates` shape. That is what makes it safe to widen a trigger already routing five
   services. ⚠ One deliberate difference from `stampListingDates`: that method is *fill-if-blank*
   for idempotency; this one must **overwrite unconditionally on a genuine transition** — re-entering
   a stage must restart the clock. Entry, not presence (`prior == null` on insert counts). Hoist
   `Date.today()` once per chunk. `with sharing`; layer = service; no selector.
4. `classes/OpportunityStageEntryServiceTest.cls` — **NEW**. Bulk-test rule applies **in full**
   (trigger-driven, no exemption): **251-record** insert and update tests. Assert the governor shape
   on counters captured **inside** the trigger context — `Test.stopTest()` restores pre-test
   counters and makes the obvious assertion **silently vacuous**.
5. `scripts/backfill-opp-stage-entry-date.apex` — **NEW** (Q4 = backfill).
   `Stage_Entry_Date__c = LastModifiedDate.date()` for open deals where null; `SYSTEM_MODE`,
   `allOrNone = false`, debug the row count. 🔴 Header must state that `LastModifiedDate` is the
   last edit **of any kind**, so day-1 values are an approximation, not history (RESIDUAL-6).

**ADMIN:** the two fields + `fieldPermissions` merged into `DPEG_Acquisition_Edit`,
`DPEG_Acquisition_View`, `DPEG_Opportunity_View` — **GATE PS-1**. `Days_In_Stage__c` is a formula ⇒
**`readable` only, never `editable`** (an `editable` entry on a formula fails the deploy).

**All eight `StageName` mutation paths — verified:**

| # | Path | Fires? |
|---|---|---|
| 1 | Manual UI / Path / list-view inline | ✅ |
| 2 | `StageAdvanceService.setStage` (Advance Stage action, `advanceDealStage` LWC) | ✅ |
| 3 | `Opportunity_Initiate_Underwriting` before-save Flow (→ `Underwriting` from any stage) | ✅ runs **before** the trigger — the decisive case |
| 4 | `workflows/Opportunity.workflow-meta.xml` → `Set_Stage_Underwriting` (LOI_Approval **final rejection**) | ✅ expected — **verify in-org (P7)** |
| 5 | `workflows/Opportunity.workflow-meta.xml` → `UW_Set_Stage_Initiate_LOI` (UW approval → `LOI`) | ✅ expected — same check |
| 6 | **`flows/Transaction_Complete_Close.flow-meta.xml`** → RecordUpdate `StageName='Closed Won'` **from the Transaction object** | ✅ 🔴 **the brief did not list this path** |
| 7 | `LeadConvertService` (conversion creates the Opportunity) | ✅ via before-**insert** |
| 8 | `scripts/*.apex` seed and migration scripts | ✅ |

No path changes `StageName` without DML ⇒ a before-trigger is **exhaustive**.

**Routing: 🔵 `salesforce-admin`** (2 fields, FLS) → **🟢 `salesforce-developer`**.

---

### ITEM 3 — LOI cannot be submitted for approval without a signed NDA

**🔴 The approved mechanism cannot work (F6). The gate is Apex, and only Apex.**

Path: `LOI__c.Submit_for_Approval` → `lwc/submitForApproval` → `OpportunityApprovalController` →
`OpportunityApprovalService.submitForApproval` → `resolveApprovalTargetId(LOI__c)` →
`LoiSelector.selectOpportunityIdRequiredById(...).Opportunity__c` → `Approval.process` on the
**Opportunity**. Nothing writes the LOI row. An Opportunity-side VR is also unreliable —
`LoiGateTest.rejectionReturnsDealToUnderwriting` demonstrates approval field updates **bypass
custom validation rules** in this org.

**Module boundary — already structural; no criterion needed.** A `Disposition_LOI` has a blank
`Opportunity__c`, so the resolver returns null and the service already refuses it. The disposition
side has a separate path entirely (`dispositionSubmitForApproval` → `DispositionApprovalService`).
⚠ **Do not add a `RecordType.DeveloperName == 'Acquisition_LOI'` check** — a criterion that never
discriminates is read as load-bearing by the next reader. Record the reasoning in the header instead.

**DEVELOPER**
1. `classes/OpportunityApprovalService.cls` — **MODIFY**. NDA pre-check **before**
   `Approval.process`, applying only when the resolved target is an Opportunity at
   `StageName = 'LOI'`. Refuse when `Primary_NDA__c` is blank **or**
   `Primary_NDA__r.NDA_Signed__c` is false. Throw the class's own typed **`ApprovalException`**
   (the EXCEPTION CONTRACT reserves it for user-actionable violations safe verbatim) — **never**
   `AuraHandledException`; this service deliberately never throws that.
   Message: *"The primary NDA must be signed before this LOI can be submitted for approval. Link a
   signed NDA (Primary NDA) on the deal first."* (mirrors the sibling VR so the gates read as one rule).
   🔴 **Amend the class-header premise in place.** It argues *"a pre-check would cost a query on
   every successful submission to serve only the failure path"* — true when the query buys a better
   **error message**, false when it buys a **correctness gate**. Retract-verbatim-then-correct, or
   the next reader deletes the gate as a violation of the class's own rule.
2. `classes/OpportunitySelector.cls` — **MODIFY**. New method returning `Id, StageName,
   Primary_NDA__c, Primary_NDA__r.NDA_Signed__c`. **`WITH SYSTEM_MODE`, justified at its own
   declaration**: performed on the submitter's behalf as an automation gate, and `USER_MODE`
   *throws* (does not degrade) on one inaccessible field, refusing a legitimate submission with
   `No such column` wearing a schema error. ⚠ The header says **"THREE are `WITH SYSTEM_MODE`"** and
   enumerates them — amend count and list **in place**, and heed its warning: *"Do not read a future
   fourth SYSTEM_MODE method as conformant because three already exist."*
3. `classes/OpportunityApprovalServiceTest.cls` — **MODIFY**. Signed NDA submits; unsigned refused;
   **blank `Primary_NDA__c` refused**; non-LOI stage unaffected; `Underwriting__c` submission
   unaffected. The 251 mandate does **not** apply (single-record UI action) — **state that reasoning
   in the test class header**, as the rule's exemption requires.

**RESIDUAL-1:** a UI-path gate, not an absolute one — `Approval.process` can be called directly
(`scripts/verify-junior-lifecycle.apex` does).
**RESIDUAL-2:** narrow live population — `NDA_Signed_Before_Deal_Progression` already blocks *entry*
to LOI, so this covers only the insert-time hole, post-hoc un-signing/repointing, and approval field
updates. Do not later file "the gate never fires" as a bug.

**Routing: 🟢 `salesforce-developer`.** No admin work at all.

---

### ITEM 4 — Stalled-deal reminder (DEPENDS ON ITEM 2)

Structural template: **`NdaExpiryAlertBatch` / `NdaExpiryAlertSchedule` / `NdaExpiryService`** —
itself cloned from `CallForOffers*`. This is the third instance of a proven pattern.

**ADMIN**
- `objects/Stage_Threshold_Def__mdt/...` — **NEW**. `Stage_Value__c` Text(80) (a CMDT picklist
  cannot reference a standard value set), `Threshold_Days__c` Number(3,0), `Is_Active__c` Checkbox.
  Template: `Broker_Protection_Config__mdt`. **Structure only — rows via the loader script.**
- `objects/Opportunity/fields/Stage_Alert_Last_Sent_Date__c.field-meta.xml` — Date.
- `objects/Opportunity/fields/Stage_Alert_Stage__c.field-meta.xml` — Text(80), **the snapshot**.
  🔴 **Not optional.** The `Offer_Alert_*` / `NDA_Alert_*` markers snapshot a *date*; here the thing
  that must re-arm the alert is a **stage change**. Re-arm test:
  `Stage_Alert_Stage__c != StageName OR Stage_Alert_Last_Sent_Date__c < Stage_Entry_Date__c`.
  A date-only marker would leave a deal that moved and stalled again **permanently silent**.
- `reports/Acquisitions/Delayed_Opportunities.report-meta.xml` — **NEW**. `Opportunity` report type,
  grouped by `STAGE_NAME`, filtered `Days_In_Stage__c > 14` and open. ⚠ **A report filter cannot
  read a CMDT row** (RESIDUAL-4) — state that in the description. ⚠ A `Metric` component needs a
  **Summary**-format report; use `FlexTable` for detail; `<aggregate>` not `a!`/`s!`.
- `dashboards/Acquisitions/Acquisitions_Dashboard_Junior.dashboard-meta.xml` — **MODIFY**, +1
  component (currently **13 of 20** ✅). Q3 = keep both widgets with **distinct titles**
  ("Stale — no activity 7d" vs "Delayed — 14d in stage").
  🔴 Carries `<runningUser>test-aysz9meqvl23@example.com</runningUser>` — a **stale scratch-org
  address**, the known cause of "invalid cross reference id" failures here. **Repoint it.**
  🔴 Three other dashboards are modified and uncommitted in this tree — **diff against HEAD first**.
  **GATE FP-1** applies.

**DEVELOPER**
1. `classes/StageDelayService.cls` — **NEW**. **Pure** (no SOQL/DML/clock), like
   `CallForOffersService` / `NdaExpiryService`. Reads `Stage_Threshold_Def__mdt.getAll()` (a CMDT
   read is **not** SOQL and costs no governor units). Exposes `thresholdFor(String)` and
   `shouldFire(...)`. **Every threshold lives here — the batch contains no `14`.**
2. `classes/OpportunitySelector.cls` — **MODIFY**. `queryStalledDeals()` `Database.QueryLocator`,
   **`WITH SYSTEM_MODE`** (same justification as `queryCallForOffersAlerts`: it selects custom
   fields created in this same change, which arrive with **no FLS for any profile including the
   deploying admin**).
   `WHERE IsClosed = FALSE AND Stage_Entry_Date__c != NULL AND Stage_Entry_Date__c <= :ceiling`.
   **`IsClosed = FALSE` is the correct exclusion** for "excluding Dead/Pass and Closed Won" (both
   carry `<closed>true</closed>`) and survives a future closed stage. **`!= NULL` is load-bearing** —
   it excludes un-backfilled legacy deals. Amend the header's SYSTEM_MODE count/list in place.
3. `classes/StageDelayAlertBatch.cls` — **NEW**. `Database.Batchable` + `Database.Stateful`.
   `SCOPE = 200` **INHERITED from `CallForOffersAlertBatch`'s five measured probes — say so plainly**
   rather than implying a fresh measurement (exactly how `NdaExpiryAlertBatch` words it).
   **SEND FIRST, STAMP SECOND** (a notification is not transactional; only this order is
   recoverable). `GroupNotifier.notifyWithOutcome`, **never** `notify`. Stamp only successes.
   `Database.update(toStamp, false, AccessLevel.SYSTEM_MODE)`.
   🔴 **`RECIPIENT_GROUP = 'Acquisition'` — the QUEUE**, per recorded Gate 1 Q2.3 (F10).
   🔴 If notifying the Owner needs a **second `send()` per deal**, **re-run** the CPU arithmetic
   (`6.0 ms + 0.22 ms × |recipients|`) for 400 sends/chunk before accepting `SCOPE = 200`. At the
   measured rate that is ≈2,500 ms of a 60,000 ms async budget (~24× margin) — but do the arithmetic
   in your header rather than inheriting a number computed for a different call count.
4. `classes/StageDelayAlertSchedule.cls` — **NEW**. `Schedulable`, one line.
5. `scripts/load-stage-threshold-defs.apex` — **NEW**. **8 rows, all `Threshold_Days__c = 14`**:
   `New`, `Under Review`, `Development Review`, `Construction Review`, `Underwriting`, `LOI`,
   `Under Contract (PSA)`, `About to Close`. (Closed stages get no rows.) Template:
   `load-broker-protection-config.apex`. ⚠ Watch the **45-row collection-initializer compile
   ceiling** — Apex names the *statement start* (`Unexpected token "<"`), not the real cause. 8 is safe.
6. Tests — **251-record** fixtures. Assert the constant-governor property (a chunk owing nothing
   costs **zero DML and zero notifications**), not merely that 251 rows produced 251 alerts.
   ⚠ `content-publication-rule.md` does **not** apply (no `ContentVersion`/`ContentNote`).

⚠ Class names cap at **40 chars** (all four are within). **`bulk` is a reserved word** and produces
misleading "method does not exist" errors.

**Routing: 🔵 `salesforce-admin`** (CMDT structure, 2 fields, report, dashboard) **+ 🟢
`salesforce-developer`** (service, selector, batch, schedule, loader, tests).

---

### ITEM 5 — Call for Offers, extended in place

**(a) `Offer_Status__c` — ADMIN**
- Picklist, **`restricted=true`**, `Open` / `Submitted` / `Closed`, `Open` as `<default>true`.
- 🔴 **Add all three values to the `Land`, `Retail` and `Commercial` record types, and deploy the
  record types BEFORE any Apex naming a value.** Record-type picklist restriction **IS enforced by
  DML** in this org (measured 4×) — several repo files claim it is UI-only and are **wrong**. ⚠ A
  record type file that **omits** a picklist silently drops all of its values for that type —
  enumerate every picklist already present; never write a partial file.
- **Q7:** a `<default>` applies **on insert only**. Also stamp `Open` in **`CallForOffersStampService`**
  when `Offer_Due_Date__c` first appears on an existing deal — one extra in-memory assignment on a
  record already being written, zero added queries.

**(b) `Source_Broker__c` — 🔴 DO NOT CREATE (Q8).** A CFO is issued by the seller's **listing
broker**, and `Listing_Broker_Name__c` / `Listing_Broker_Email__c` already hold exactly that.
Surface those in `callForOffersPanel` instead. This respects `LeadConvertService`'s explicit
warning — *"This is the SUBMITTING broker; the OM's listing broker is a different person … **Do not
merge the two**"* — and adds no fourth broker role.
✅ **Convenient consequence:** `OpportunitySelector.queryCallForOffersAlerts` **already selects
`Listing_Broker_Name__c`**, and `CallForOffersAlertBatch.buildRequest` already puts it in the
notification body. The bell and the panel will name the same person **by construction**. No selector
change is needed for (b).

**(c) Suppress once Submitted/Closed — DEVELOPER**
Modify `OpportunitySelector.queryCallForOffersAlerts()`. 🔴 **SOQL NULL TRAP:** every existing deal
has `Offer_Status__c = null`, and `Offer_Status__c NOT IN ('Submitted','Closed')` evaluates
**unknown for null and EXCLUDES the row** — silently killing the alert for the entire existing
population on day one. Write:
```
AND (Offer_Status__c = NULL OR Offer_Status__c NOT IN ('Submitted','Closed'))
```
The filter belongs in the **selector** (a *population* filter, not a ladder threshold; and
excluding rows before chunking is cheaper). ⚠ `OpportunitySelectorTest.queryCallForOffersAlerts_doesNotSelectTheReceivedDate`
**pins the selected field list** — adding a field may red it. Add both
`..._excludesSubmittedAndClosed` **and** `..._stillIncludesNullStatus`; the second is the falsifier
for the null trap and is the more valuable.

**(d) Rung values → Custom Metadata (Q5 = option (i)) — DEVELOPER + ADMIN**

**The ladder is preserved exactly. Only its values move.** No regression, no marker invalidation.

- **A SEPARATE CMDT type — `CFO_Alert_Rung__mdt`. Not shared with Item 4.** Three reasons:
  1. **Different cardinality and meaning** — one row per *stage* (Item 4) vs one row per *rung*
     (here). A shared type would need a discriminator plus two mutually-irrelevant columns.
  2. **Different readers** — `StageDelayService` vs `CallForOffersService`, two batches.
  3. 🔴 **Decisive: the rung values are a data contract with existing rows.**
     `Offer_Alert_Last_Interval__c` stores **the rung** on every deal that has ever alerted. Item 4's
     thresholds have no such stored counterpart. Putting both in one type means **one admin edit can
     corrupt the other feature's stored markers.** Keep them apart.
- Fields: `Days_Before_Due__c` Number(3,0), `Is_Active__c` Checkbox.
- **Seed EXACTLY `{7, 3, 1, 0}`** via `scripts/load-cfo-alert-rungs.apex` so day-one behaviour is
  **byte-identical** to today.
- 🔴 **ORDER IS LOAD-BEARING AND `getAll()` DOES NOT GUARANTEE IT.** `intervalFor` iterates
  `ALERT_INTERVALS` and keeps the **last** match, which only yields "the smallest rung still
  containing the deal" because the list is in **descending** order. A `Map` from `getAll()` has **no
  guaranteed iteration order**, so `CallForOffersService` must **sort the rungs descending
  explicitly** after reading them. Getting this wrong changes which rung fires, silently.
- ✅ `CallForOffersAlertBatch`'s rule — *"If you find yourself writing `7` or `3` in this file,
  stop"* — **survives unchanged and is strengthened**: the values now live in CMDT, read by the pure
  service, and the batch still contains no literal.

**(e) Due-date change re-arms — ✅ ALREADY BUILT. ZERO WORK (F7).** Only confirm
`CallForOffersServiceTest` has a re-arms-on-moved-due-date case; add one if not. **Do not modify
`shouldFire`.**

**(f) Surface `Offer_Status__c` (+ the listing broker, per (b)) — ADMIN + DEVELOPER**
- `objects/Opportunity/listViews/Offers_Due_Soon.listView-meta.xml` — **MODIFY**, add the
  `Offer_Status__c` column.
- `lwc/callForOffersPanel/*`, `lwc/callForOffersList/*` — **MODIFY**. Check first whether each is
  LDS-wired or imperative-Apex-backed; if imperative, `CallForOffersController` + its DTO need the
  new member and the JS/HTML change is additive.
  ⚠ `lightning-record-edit-form` **FLS-checks every key in its payload including programmatic ones**
  — a non-editable field vanishes with a **success toast**. ⚠ A getter bound to a custom element
  attribute is written **unconditionally** — return `''`, not `undefined`, and assert on the
  **rendered attribute**, not the getter. ⚠ Jest + `@sa11y/jest` required. ⚠ **`<description>` in an
  LWC `.js-meta.xml` is capped at 255 chars and ONLY a deploy catches it.** ⚠ Run the **SLDS linter**.

**RESIDUAL-3 (user-accepted):** a CFO cannot span multiple deals in a portfolio package.
`Portfolio_Deal__c` members each carry independent `Offer_Due_Date__c` / `Offer_Status__c` and can
silently disagree. Nothing detects it.

**Routing: 🔵 `salesforce-admin`** (1 field, 3 record types, CMDT structure, list view) **+ 🟢
`salesforce-developer`** (selector, service, loader script, 2 LWCs + Jest, controller, tests).

---

### ITEM 6 — Broker leaderboard counters

**Read §1 first. The Contact fields' descriptions are a hard requirement, not polish.**

#### 6.1 ACCOUNT SIDE — three native roll-up summaries ✅

**Verified:** Account has **zero** custom fields. `Opportunity.AccountId` **is** the broker firm
(`BrokerFirmController` reads `opp.Account.Name`; `LeadConvertService`: *"Several Leads can converge
on ONE Account (Smart Lead Conversion reuses a firm)"*). Account→Opportunity **is** a supported
non-master-detail roll-up path.

| Field | Summary | Filter |
|---|---|---|
| `Total_Deals_Submitted__c` | COUNT of Opportunity | none |
| `Deals_Won__c` | COUNT | `StageName equals Closed Won` |
| `Deals_Lost__c` | COUNT | `StageName equals Dead/Pass` |

🔴 **Roll-up summary XML is a known deployment-failure area.** Load the **`sf-custom-field`** skill.
`<summaryForeignKey>Opportunity.AccountId</summaryForeignKey>`, `<summaryOperation>count</summaryOperation>`,
**omit `<summarizedField>` for `count`** (supplying it is a common failure), `<summaryFilterItems>`
with `<field>Opportunity.StageName</field>` / `<operation>equals</operation>` / `<value>`.
Use the **literal** `Dead/Pass` in a filter value (`%2F` is a BusinessProcess/RecordType-only convention).

⚠ Roll-ups are **read-only** ⇒ `readable` only in `DPEG_Account_View`; `editable=true` fails the deploy.
⚠ Deploying triggers a **full recalculation** across all Opportunities — harmless here, but do not
misdiagnose a slow deploy.

**RESIDUAL-5:** a roll-up counts **every** Opportunity on the Account, not just broker-introduced
ones. Verify against live data before go-live (count Opportunities whose Account record type is not
`Broker_Firm`).
**RESIDUAL-8 (new):** these three numbers now exist **twice** — as roll-ups and as
`BrokerFirmController`'s live Apex computation (F11). **Q10 deliberately leaves the repoint out of
scope.** Record the duplication in the field descriptions so a future divergence is diagnosable.

#### 6.2 / 6.4 CONTACT SIDE — four fields + one nightly batch

**🔴 The brief pointed at the wrong field.** `Lead.Broker_First__c` is a **Text(255) mirroring the
brokerage FIRM NAME** (`BrokerPortalService` lines 140–141 set `l.Company` and `l.Broker_First__c`
to the same `input.brokerageFirm`; two tests assert *"Broker_First mirrors firm"*). It is **not** a
broker-identity link. **The join is `Lead.ConvertedContactId`**, which `LeadConvertService` also
stamps onto `Opportunity.Broker__c`.

**ADMIN — four fields on Contact**

| Field | Type | Source |
|---|---|---|
| `Deals_Submitted__c` *(exists)* | Number(18,0) | COUNT of Opportunity `GROUP BY Broker__c` |
| `Deals_Won__c` *(exists)* | Number(18,0) | COUNT where `StageName = 'Closed Won'` |
| `Deals_Lost__c` | **NEW** Number(18,0) | COUNT where `StageName = 'Dead/Pass'` |
| `First_Submission_DateTime__c` | **NEW** DateTime (Q9) | `MIN(Lead.First_Seen_Date__c)` `GROUP BY ConvertedContactId` |

⚠ `Lead.First_Seen_Date__c` is a **DateTime** despite its Date suffix (a violation
`LeadConvertService` documents and refuses to rename). `Opportunity.Broker_First_Seen__c` moved
Date → DateTime on **2026-08-30 (today, WS2)** to match. The new field is a **DateTime** so the
instant maps straight across with no `.date()` truncation.

🔴 **WS2 is active work on this exact surface, today.** `LeadConvertService` and
`Broker_First_Seen__c` both changed 2026-08-30. **Diff against HEAD and check for concurrent-session
edits before touching the lead-convert path.**

🔴 **ALL FOUR FIELDS REQUIRE A `<description>` STATING THE POPULATION. Non-negotiable.** Each must say,
in substance: *"Covers only brokers who have a Contact — i.e. those whose Lead was converted. Brokers
who submitted and lost never receive a Lead (since 2026-07-31) and therefore never appear here. The
authoritative broker population is the `brokerLeaderboard` component / `BrokerLeaderboardService`,
computed live from `Competing_Broker_Submission__c`. Maintained nightly by `BrokerCounterRecalcBatch`."*
⚠ `<description>` is capped at **255 characters** — split across the field description and an XML
comment inside the root if needed.

🔴 **DO NOT TOUCH `Active_Listings__c`, `Closed_Volume__c` or `Avg_Days_On_Market__c`** — they are
the **disposition-side** scorecard and mean something else entirely (§1 reason 2).

**LEADERBOARD — NO CHANGE.** `BrokerLeaderboardService`, `BrokerLeaderboardController`,
`lwc/brokerLeaderboard`, `brokerFirmCard` and `reports/Acquisitions/Broker_Leaderboard` are **all
untouched**. Do not repoint the leaderboard at Contact.

**DEVELOPER — the batch (nightly, NOT trigger-time)**

**Why a batch, decisively.** `OpportunityReviewTrigger` already routes **five** services — one
(`DealFolderService`) enqueues a SharePoint Queueable under a **never-throw** contract, another
(`PropertyAssetService`) **throws by design**. Adding a parent read + parent DML to that cascade is
the exact shape of a **measured** failure in this repo: routing a new parent into a Task trigger cost
`ceil(rows/200)` SOQL **and** DML — 23 each at production scale. **And Item 2 is already widening
this same trigger** — doing both in one wave makes a regression unattributable.

1. `classes/BrokerCounterRecalcBatch.cls` — **NEW** (24 chars ✅).
   🔴 **Batch over CONTACT, not over Opportunity.** `Database.getQueryLocator` on
   `Contact WHERE RecordType.DeveloperName = 'Broker'`. This is not a style choice: batching over
   Contact means **every Contact in scope is written**, so a broker whose deals were deleted or
   reassigned correctly goes to **0** instead of keeping a stale count. Batching over Opportunity
   can only ever *increase* counts and would silently strand them.
   Per chunk — **2 SOQL, 1 DML, constant in the number of deals**:
   - `AggregateResult` over Opportunity `GROUP BY Broker__c WHERE Broker__c IN :chunkIds`
   - `AggregateResult` over Lead `MIN(First_Seen_Date__c) GROUP BY ConvertedContactId WHERE
     ConvertedContactId IN :chunkIds`
   - one `Database.update(..., false, AccessLevel.SYSTEM_MODE)`
   ✅ **NO EMAIL MATCHING, FUZZY OR OTHERWISE.** `Opportunity.Broker__c` is a real Contact lookup
   (`LeadConvertService`: `o.Broker__c = l.ConvertedContactId`). `BrokerLeaderboardService`'s
   reason-3 warning was about `Competing_Broker_Submission__c`, whose identity is a **Text email
   with no Contact lookup** — **this batch does not touch that object.** Record this in the class
   header so the warning is not re-inherited.
   ⚠ All SOQL via selectors per `.claude/rules/apex-layering-rule.md` — add the aggregates to
   `OpportunitySelector` and `LeadSelector`, **not** inline. `WITH SYSTEM_MODE`, justified at each
   declaration (automation path; new fields arrive with no FLS).
2. `classes/BrokerCounterRecalcSchedule.cls` — **NEW** (27 chars ✅).
3. Tests — **251-record** fixtures (`bulk-test-rule.md`, no exemption). Include a **reset-to-zero**
   case: a Contact with counts whose Opportunities are removed must go to 0. That is the falsifier
   for the batch-over-Contact decision.

**Win rate & last submission — computed, not stored.** The existing `BrokerLeaderboardService`
already returns first/last submission and computes rank in Apex, precisely so *"two surfaces
computing their own ranks"* cannot disagree. No stored field. If a reporting need emerges, the
honest form is a **formula** over the two counts, not a maintained Number.

**Routing: 🔵 `salesforce-admin`** (3 Account roll-ups, 2 new Contact fields, 2 existing Contact
field descriptions, FLS) **+ 🟢 `salesforce-developer`** (2 selector aggregates, batch, schedule,
tests). **Not solution-architect** — no OWD/sharing decision is embedded and the roll-up
relationship is platform-fixed.

---

## §3 — SEQUENCING AND PARALLELISM

```
WAVE A (fully parallel)
  ├── ITEM 1   VR 1A + VR 1B + header block 1C + No_Backward amendment  🔵 admin
  │            └── 1D: three Apex header/comment amendments             🟢 developer
  ├── ITEM 3   Apex NDA gate                                            🟢 developer
  ├── ITEM 5a/b/f  Offer_Status__c + record types + list view + LWCs    🔵 admin + 🟢 developer
  ├── ITEM 5c  selector predicate (SOQL null trap)                      🟢 developer
  ├── ITEM 5d  CFO_Alert_Rung__mdt + loader + service repoint           🔵 admin + 🟢 developer
  └── ITEM 6.1 Account roll-ups                                         🔵 admin

WAVE B
  └── ITEM 2   fields ─► trigger widening + service + backfill script
                                                       🔵 admin ─► 🟢 developer

WAVE C (HARD DEPENDENCY on Item 2 — the batch reads Days_In_Stage__c)
  └── ITEM 4   CMDT + 2 fields + report + dashboard ─► service/selector/batch/schedule/loader
                                                       🔵 admin ─► 🟢 developer

WAVE D (must NOT share a wave with Item 2 — see below)
  └── ITEM 6.2/6.4  Contact fields + nightly recalc batch  🔵 admin + 🟢 developer

ITEM 5e — ZERO WORK.
```

🔴 **Item 6.4 must NOT run in the same wave as Item 2.** Both touch the Opportunity write path
(Item 2 widens the trigger; Item 6.4 adds a nightly writer keyed on `Opportunity.Broker__c`). A
regression would be unattributable. Item 6.4 can run in parallel with Item 4 (Item 4 touches
Opportunity marker fields only, via a different batch).

🔴 **HUB-FILE PROTOCOL.** Items 1, 2, 4, 5 and 6 all touch **permission sets**; Item 4 touches a
**dashboard**; Items 5 and 6 touch **LWCs**. No concurrent stream may edit these. Nominate **one
consolidation pass per wave** that merges all `fieldPermissions` for that wave into the six
permission-set files in a single edit.

---

## §4 — COMPLEXITY ROUTING SUMMARY

| Item | Declarative | Programmatic | Reasoning |
|---|---|---|---|
| 1 | 🔵 admin (2 VRs, 1 VR message/header amendment) | 🟢 developer (3 Apex header/comment amendments — 1D) | Declarative rules executing a decision taken here. The Apex half is comments only, no logic. |
| 2 | 🔵 admin (2 fields, FLS) | 🟢 developer | Trigger widening + a zero-SOQL/zero-DML service. No integration, no sharing decision (nothing is read). |
| 3 | — none | 🟢 developer | One method in an existing service + one selector method. `Opportunity` OWD is `ReadWrite` ⇒ no sharing question. |
| 4 | 🔵 admin (CMDT structure, 2 fields, report, dashboard) | 🟢 developer | Third instance of a measured pattern; governor shape inherited, not designed. |
| 5 | 🔵 admin (1 field, 3 record types, CMDT structure, list view) | 🟢 developer (selector, service, loader, 2 LWCs + Jest) | Additive to a shipped feature. **5(d) does NOT escalate** — Q5 chose the additive option, so it is a config move, not a migration. |
| 6.1 | 🔵 admin | — | Relationship is platform-fixed ⇒ no model decision embedded. |
| 6.2/6.4 | 🔵 admin (4 fields + descriptions) | 🟢 developer (2 selector aggregates, batch, schedule) | Standard batch. The population decision is taken here; the agents execute it. |

**No item routes to ⚫ `salesforce-technical-architect`** — nothing touches ASB, Plaid, Yardi,
Procore, CoStar, OpenAI, SharePoint or Turnstile; no Named Credentials; no LDV; no Platform Events.

---

## §5 — POST-DEPLOY MANUAL STEPS (ALL FAIL SILENTLY)

> 🔴 **DEPLOYMENT IS BLOCKED THIS SESSION.** The `salesforce` MCP server failed to connect
> (`CONNECT_TIMEOUT`). **Build and code review can proceed; the `salesforce-devops` step cannot.**
> This is a **known environmental state, not a design constraint** — nothing in this document should
> be reshaped around it. Every gate and step below still applies whenever deployment does happen.

| # | Step | Why it cannot be deployed | Fails how |
|---|---|---|---|
| **P1** | **Populate the `Acquisition` queue's membership.** | Queue/group membership is **not deployable metadata**; no test can see it. | 🔴 `GroupNotifier` logs `WARN: no recipients` and returns `false`. Because these jobs are **send-then-stamp**, `false` ⇒ **no marker written** ⇒ the job re-evaluates every delayed deal **every day forever, sending nothing.** Noisy in the log, invisible to users. **Same gate (G2) already open for `CallForOffersAlertBatch` and `NdaExpiryAlertBatch` — one gate, now three jobs.** |
| **P2** | **Schedule `StageDelayAlertSchedule`** and **`BrokerCounterRecalcSchedule`**. | A `Schedulable` deploys; its **CronTrigger does not**. | The jobs never run. No error anywhere. ⚠ Also verify `CallForOffersAlertSchedule` and `NdaExpiryAlertSchedule` in the same pass — they may still be unscheduled. |
| **P3** | **Run `scripts/load-stage-threshold-defs.apex`** (8 rows) **and `scripts/load-cfo-alert-rungs.apex`** (4 rows). | CustomMetadata **record** deploys fail in this repo (four loader-script precedents). | `getAll()` empty ⇒ Item 4 treats **every deal as not-delayed** (silently dead); Item 5(d) loses its ladder. Add a `finish()` debug naming the row count so an empty load is visible. |
| **P4** | **Run `scripts/backfill-opp-stage-entry-date.apex`.** | One-off data operation. | Without it every existing open deal has `Stage_Entry_Date__c = null`, is excluded by the selector, and never alerts. Silent. |
| **P5** | **Assign the six permission sets** to the running users and confirm the new grants landed. | Assignment is not in the deployed metadata. | Recorded incident shape: *"RunLocalTests fails with ~500 field-access errors" = permission sets not **assigned**.* |
| **P6** | **Repoint the Acquisitions dashboard `<runningUser>`** away from `test-aysz9meqvl23@example.com`. | Scratch-org username baked into the file. | "Invalid cross reference id"; recurs on every org rebuild. |
| **P7** | **Verify approval field updates fire the new before-trigger** (Item 2 paths 4 & 5): take a deal to LOI, reject the LOI approval, confirm `Stage_Entry_Date__c` moved. | Behavioural, org-specific. | Deals returned to Underwriting by rejection carry a stale entry date and alert immediately or never. |
| **P8** | **Brief the team that Closed Won is now terminal** (Item 1B), and agree the admin data-fix procedure for a wrongly-Closed-Won deal. | Process, not metadata. | 🔴 A deal driver who closes a deal by mistake has **no in-app route out** and no error message that helps. This is the single most likely support call from this tranche. |

---

## §6 — BREAKAGE REGISTER

### 6.1 🔴 `scripts/seed-pipeline.apex` — the one seed script at risk (Item 1A)

```
scripts/seed-pipeline.apex:17   'Dead/Pass' => new List<Object>{ 9, 5788888, 'Killed', 'Dead', thisFy, 'Dead Deal' }
scripts/seed-pipeline.apex:31       StageName = stage,
```
Inserts **9 Dead/Pass Opportunities**; `Rejection_Reason__c` appears **nowhere** in the file.
⚠ **Currently MODIFIED in the working tree.**
✅ **The `ISCHANGED(StageName)` gate on rule 1A keeps it green** (ISCHANGED is always false on
insert). This is the same insert-time hole `NDA_Signed_Before_Deal_Progression` documents, and
`seed-fsd-06`'s own header relies on it: *"stage-gate validation rule in this org is
`ISCHANGED(StageName)`-scoped, which is FALSE on [insert]."*

### 6.2 ✅ Seed scripts that write Dead/Pass and are SAFE

| Script | Why |
|---|---|
| `seed-fsd-05-flagship-dead.apex` (55, 70, 94) | Three `update`s (ISCHANGED **true**), all three set `Rejection_Reason__c` **in the same statement** (`Wrong Market`, `Failed DD`, `Price Too High`). Prior stages are New/Underwriting/LOI — **none is Closed Won**. |
| `seed-fsd-06-volume-pipeline.apex` (71–72, 107–108, 128) | Two Dead/Pass rows; line 128 sets the reason on the same in-memory record **before insert**. Safe under both rules. |
| `gen-data.mjs` (33, 57) | `if (d[7] === 'Dead/Pass') f.Rejection_Reason__c = 'Bad Anchor Tenant';` |
| `seed-brokers.apex` (23) | Reads only. |

### 6.3 🔴 Item 1B (Closed Won block) — the coordinator's two explicit questions, answered

**(i) What happens to an EXISTING Dead/Pass record whose prior stage was Closed Won?**
**Nothing. It is unaffected and stays valid.** Rule 1B is keyed on `PRIORVALUE(StageName)`, which is
re-derived from the immediately prior stored value on **each save**. A record already sitting at
Dead/Pass is not changing `StageName`, so `ISCHANGED` is false and the rule cannot fire. The rule is
transition-keyed, not a sticky field state — the same self-limiting property
`No_Backward_Stage_Movement`'s "CARVE-OUT 1 STICKINESS CHECK" documents.
⚠ **The one real consequence:** such a record can never be moved *out of* Dead/Pass and back in.
Leaving Dead/Pass is still allowed (prior rank 0), but the return trip would then evaluate
`PRIORVALUE = 'Closed Won'`? No — it would evaluate the stage it was moved to. So a revived deal is
governed normally. **No existing data is invalidated.**

**(ii) Does any seed script or test perform a Closed Won → Dead/Pass transition?**
**NO. Verified across `scripts/**` and `force-app/main/default/classes/**`.**

| Surface | Finding |
|---|---|
| `seed-fsd-04-flagship-closed-won.apex` | Ends at `Closed Won` (line 92). No further stage op. ✅ |
| `seed-fsd-05-flagship-dead.apex` | Moves to Dead/Pass from New / Underwriting / LOI. ✅ |
| `seed-pipeline`, `seed-fsd-06`, `gen-data.mjs` | Set Dead/Pass **at insert**. ✅ |
| `BrokerFirmControllerTest` (43–45, 92–93) | Sets `Closed Won` / `Dead/Pass` **at insert**, incl. a 251-row mixed fixture. ✅ |
| `CallForOffersAlertBatchTest` (300–305) | Inserts Dead/Pass deliberately *"so no `ISCHANGED(StageName)` validation rule is involved"*. ✅ |
| `OpportunityFunnelControllerTest` (42–43, 118) | Sets stages at insert. ✅ |
| `OpportunityReviewServiceTest.noDuplicateOnReentry` (~707) | **Uses the Dead/Pass round trip — but from `Development Review` (rank 3), not Closed Won. Test PASSES.** ⚠ Its comment asserts *"entering it is always allowed"*, which is now false. **Comment amendment required (1D)** — a future test copying this pattern from Closed Won would fail confusingly. |

### 6.4 ⚠ Item 2 — no script breaks, but seeded data becomes useless for Item 4

Every seed script that walks a deal through stages now stamps `Stage_Entry_Date__c` on each hop —
**all on the same day**, so seeded deals show `Days_In_Stage__c = 0` and **Item 4 reports nothing on
seeded data**. A demo needs a back-dating step (RESIDUAL-7).

### 6.5 ⚠ Apex tests at risk

- **Item 3:** `LoiGateTest`, `OpportunityApprovalServiceTest`, `StageApprovalGatesTest`,
  `OpportunityApprovalControllerTest` — any test submitting an LOI-stage deal **without** a signed
  `Primary_NDA__c` now fails. **Fix the FIXTURES, not the logic.**
- **Item 2:** `OpportunityReviewServiceTest`, `OpportunityReviewTriggerHandlerTest`,
  `ContractExecutionServiceTest`, `PropertyAssetServiceTest`, `DealFolderServiceTest` — the trigger
  gains two contexts. Should be unaffected (new work is in-memory only) but this is the blast radius.
- **Items 3, 4, 5c:** all modify `OpportunitySelector`. It contains
  `queryCallForOffersAlerts_doesNotSelectTheReceivedDate`, which **pins the selected field list**.
- **Item 6.1:** `BrokerFirmControllerTest`'s 251-row test (251 / 126 / 125) pins the **live** Apex
  computation. The new roll-ups do not change it, but the two must agree — if they diverge, that
  test is where it shows.
- 🔴 **Run `--tests` with the test class IN THE PAYLOAD.** A targeted run executes the **org's** copy
  and can silently run fewer methods than the repo has while reporting 100%.
- 🔴 **A green dry-run can mean "never validated"** — byte-identical components report `Unchanged`
  and are **skipped**; comment-only edits do not count as a diff. **This matters unusually much for
  Item 1D, which is entirely comment edits.**

### 6.6 ⚠ Existing records

- **1A:** existing Dead/Pass deals with a blank reason stay valid, but refuse the next save that
  changes `StageName`.
- **1B:** see 6.3(i) — no existing data invalidated.
- **5a:** every existing deal gets `Offer_Status__c = null` (a `<default>` does not backfill) —
  handled by the SOQL null guard in 5(c).
- **5d:** seeding the rungs as exactly `{7,3,1,0}` means **zero** change to stored
  `Offer_Alert_Last_Interval__c` markers. **RESIDUAL-9:** if an admin later *changes* a rung value,
  `shouldFire` compares a NEW rung against an OLD stored rung — degrades gracefully (at most one
  extra or one missing alert during the transition), but is worth stating.
- **6.1:** deploying the roll-ups triggers a full recalculation.
- **6.4:** the first batch run overwrites the two existing (permanently zero) Contact fields.

---

## §7 — DEPLOY GATES (BLOCKING SECTIONS, NOT FOOTNOTES)

### 🔴 GATE PS-1 — a PermissionSet deploy REPLACES its entire `<fieldPermissions>` collection

Caused a live outage here. **Metadata-API-deployed fields arrive with NO FLS for ANY profile,
System Administrator included** — without grants the new fields throw `No such column` at runtime.

Per set, no shortcuts: **retrieve → diff against HEAD** (concurrent sessions share this tree; two
Transaction permission sets are already modified and uncommitted) **→ edit the RETRIEVED copy →
deploy → read back and confirm the delta.** *"Succeeded" is not proof.*

| Set | Needs |
|---|---|
| `DPEG_Acquisition_Edit` | `Stage_Entry_Date__c` RW, `Days_In_Stage__c` **R only**, `Offer_Status__c` RW, `Stage_Alert_Last_Sent_Date__c` R, `Stage_Alert_Stage__c` R |
| `DPEG_Acquisition_View` | all of the above, **read-only** |
| `DPEG_Opportunity_View` | `Stage_Entry_Date__c` R, `Days_In_Stage__c` R, `Offer_Status__c` R |
| `DPEG_Account_View` | the three roll-ups, **R only** |
| `DPEG_Contact_Edit` / `DPEG_Contact_View` | `Deals_Lost__c`, `First_Submission_DateTime__c` (**R only** — batch-maintained; `SYSTEM_MODE` writes need no user grant). Confirm `Deals_Submitted__c` / `Deals_Won__c` grants already exist. |

⚠ `editable=true` on a **formula** or **roll-up summary** field **fails the deploy**.

### 🔴 GATE FP-1 — FlexiPage / dashboard deploys REPLACE the org copy, no version history

`Opportunity_Record_Page` has been hand-edited in App Builder and **edits were lost**. Item 4 touches
the Acquisitions dashboard. **Retrieve seconds before deploying → diff against HEAD → read
`SetupAuditTrail` for saves newer than the last retrieve.**
⚠ `.forceignore` hides org/repo drift: un-ignoring a path makes stale drift **deployable**
(`Case.object-meta.xml` once said `ReadWriteTransfer` while the org was `Private` — a silent org-wide
security downgrade). Diff every `Changed` component against the **org**, not just HEAD.

### 🔴 GATE RT-1 — record types deploy BEFORE dependent Apex

Item 5(a) adds values to a **restricted** picklist. DML **enforces** record-type restriction here
(measured 4×; the repo's ~20 "UI-only" assertions are **wrong**, including the one in
`Acquisition_LOI.recordType-meta.xml`). Deploy `Land` / `Retail` / `Commercial` **before** any Apex
or Flow naming `Open` / `Submitted` / `Closed`, or writes fail with an opaque
`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`.
⚠ A **CustomField retrieve UNIONS** local+remote picklist values; a **RecordType retrieve STRIPS**
them. Committing a "clean sync from org" of a record type is a **silent production regression**.
Verify via REST describe, not retrieve.

### ⚠ GATE MCP-1 — `salesforce-api-context` MCP is not configured

`.mcp.json` has only the `salesforce` server, and **subagents have no MCP tools at all**. Make a
**real attempt** per type, then record:

```
mcp=unavailable | mcp_tools=none
```

and fall back to the per-type skill. **Do not fabricate an MCP result.**

Skills that **exist**: `sf-custom-field`, `sf-validation-rule`, `sf-permission-set`, `sf-flexipage`,
`sf-apex`, `sf-apex-test`. **No `sf-layout`, no `sf-quick-action`, and no report / dashboard /
custom-metadata-type skill.** The rule says "if no matching skill exists, STOP and ask" — for those
types, **nominate `sf-metadata`** and use the de-facto templates rather than stalling:

| Type | Template |
|---|---|
| `__mdt` CustomObject | `objects/Broker_Protection_Config__mdt/Broker_Protection_Config__mdt.object-meta.xml` |
| Report | `reports/Acquisitions/Stale_Deals_7Day.report-meta.xml` |
| Dashboard | `dashboards/Acquisitions/Acquisitions_Dashboard_Junior.dashboard-meta.xml` |
| CMDT loader script | `scripts/load-broker-protection-config.apex` |
| Batch/Schedule/Service trio | `classes/NdaExpiryAlertBatch.cls` / `NdaExpiryAlertSchedule.cls` / `NdaExpiryService.cls` |
| Roll-up summary field | *(none in repo — Account has zero custom fields; follow `sf-custom-field` exactly)* |

**Per-type order** (one type fully complete before the next): RecordType → CustomField →
CustomObject (`__mdt`) → ValidationRule → ListView → PermissionSet → Report → Dashboard →
ApexClass → ApexTrigger → LWC.

---

## §8 — ACCEPTED RESIDUALS

| # | Residual |
|---|---|
| **RESIDUAL-1** | Item 3's gate is a **UI-path gate, not absolute** — `Approval.process` can be called directly (`scripts/verify-junior-lifecycle.apex` does). No platform mechanism makes an approval submission absolutely conditional. |
| **RESIDUAL-2** | Item 3's live population is **narrow** — the stage-entry VR already blocks the common path. Covers only the insert-time hole, post-hoc NDA un-signing/repointing, and approval field updates. Do not file "the gate never fires" as a bug. |
| **RESIDUAL-3** | A Call for Offers **cannot span multiple deals in a portfolio package** (user-accepted). `Portfolio_Deal__c` members carry independent `Offer_Due_Date__c` / `Offer_Status__c` and can silently disagree. |
| **RESIDUAL-4** | Item 4's threshold exists in **two disconnected copies** — the CMDT row (batch) and a literal in the report filter (a report filter cannot read CMDT). Unavoidable declaratively; state it in the report description. |
| **RESIDUAL-5** | Item 6.1's roll-ups count **every** Opportunity on the Account, not just broker-introduced ones. Verify against live data. |
| **RESIDUAL-6** | Item 2's backfill is an **approximation** — `LastModifiedDate` is the last edit of any kind. Day-1 `Days_In_Stage__c` values are not history. |
| **RESIDUAL-7** | Item 4 **reports nothing on seeded data** — seeds walk all stages in one run, stamping today at each hop. A demo needs a back-dating step. |
| **RESIDUAL-8** | *(new)* Item 6.1's three numbers now exist **twice** — as Account roll-ups and as `BrokerFirmController`'s live Apex computation (F11). The repoint is **out of scope (Q10)**. Record it in the field descriptions so a future divergence is diagnosable. |
| **RESIDUAL-9** | *(new)* Item 5(d): if an admin **changes** a rung value after go-live, `shouldFire` compares a NEW rung against an OLD stored `Offer_Alert_Last_Interval__c`. Degrades gracefully — at most one extra or one missing alert during the transition — but is not zero. |
| **RESIDUAL-10** | *(new, and the most consequential)* Item 1B leaves **Closed Won with no in-app exit and no bypass permission**. A wrongly-Closed-Won deal requires an admin data fix. Accepted by the user on 2026-08-30 after the consequence was stated and reaffirmed. See P8. |

---

## §9 — TRACEABILITY TO THE STORY ACs

| Story AC | Satisfied by | Fully? |
|---|---|---|
| "Dead available from any stage except Closed Won" | Item 1B | ✅ **as literally specified.** ⚠ Overrides a recorded invariant — see RESIDUAL-10, P8, and the 1C header block. |
| "Rejection Reason required" | Item 1A | ✅ (transition-gated; insert-time hole accepted, consistent with both sibling rules) |
| "Each stage change stamps a stage-entry date" | Item 2 | ✅ all 8 mutation paths verified |
| "Cannot submit [LOI] without a Signed NDA" | Item 3 | ✅ via Apex — **not** via the approved VR mechanism, which provably cannot fire (F6) |
| "Days in stage tracked from the stage-entry date" | Item 2 formula | ✅ |
| "Threshold per stage in Custom Metadata" | Item 4 CMDT + loader | ✅ flat 14, per-stage rows so it can vary later without a deploy |
| "Reminder to the Owner and Acquisition Team" | Item 4 | ✅ ⚠ recipient is the **`Acquisition` queue** per recorded Gate 1 Q2.3 (F10) |
| "'Delayed opportunities' widget on the dashboard" | Item 4 report + dashboard | ✅ sits beside the existing `Stale_Deals_7Day`, distinct titles (Q3) |
| CFO: status, source broker, suppression, interval, re-schedule, surfacing | Item 5 | ✅ ⚠ **(b) satisfied by reusing `Listing_Broker_*` — no new field (Q8); (e) already built — zero work** |
| "Contact field First Submission Date (earliest Lead where the broker is First-Seen)" | Item 6.2 | ✅ via `Lead.ConvertedContactId` — **not** via `Lead.Broker_First__c`, which is a firm-name Text field (brief error) |
| "Account roll-ups: Total Deals Submitted, Won, Lost" | Item 6.1 | ✅ ⚠ duplicates `BrokerFirmController`'s live computation (RESIDUAL-8) |
| "Leaderboard: Submitted, Won, Lost, win rate, last submission — by firm and by broker" | existing `brokerLeaderboard` + `Broker_Leaderboard` report + Item 6.1 + Item 6.2 | ✅ ⚠ **the leaderboard is UNCHANGED and remains authoritative.** The Contact counters serve `Broker_Hub` only and must say so on every field (§1). |

---

## §10 — PROMPTS FOR SPECIALIST AGENTS

> All questions are answered. **All four prompts are dispatchable**, subject to the wave ordering in
> §3. Deployment is blocked this session (MCP `CONNECT_TIMEOUT`) — **build and review only.**

### 🔵 PROMPT — `salesforce-admin` (WAVE A)

```
Read ARCHITECTURE.md and .claude/rules/salesforce-global-rule.md first. Then read
agent-output/design-requirements.md -- it is the RECORD OF TRUTH and overrides anything you may
infer from elsewhere.

The salesforce-api-context MCP is NOT configured (.mcp.json has only the `salesforce` server;
subagents have no MCP tools). Make a real attempt per type, then record
`mcp=unavailable | mcp_tools=none` and fall back to the per-type skill. Do NOT fabricate an MCP
result. There is no report/dashboard/__mdt/roll-up skill -- nominate `sf-metadata` and use the
template files in §7 GATE MCP-1.

Per-type order, one type fully complete before the next:
RecordType -> CustomField -> CustomObject(__mdt) -> ValidationRule -> ListView -> PermissionSet.

=== ITEM 1 -- TWO validation rules, and a header block that is NOT optional ===

1A. objects/Opportunity/validationRules/Rejection_Reason_Required_On_Dead.validationRule-meta.xml
    AND(ISCHANGED(StageName), ISPICKVAL(StageName,'Dead/Pass'), ISBLANK(TEXT(Rejection_Reason__c)))
    errorDisplayField: Rejection_Reason__c
    errorMessage: "Choose a Rejection Reason before moving this deal to Dead/Pass."
    - The value is literally `Dead/Pass`. Do NOT write a rule against 'Dead'. The `Dead%2FPass`
      encoding is BusinessProcess/RecordType-only -- do not use it here.
    - ISCHANGED-gating is DELIBERATE: it matches the story AC, matches both sibling rules, and keeps
      scripts/seed-pipeline.apex green (it inserts 9 Dead/Pass Opportunities with no
      Rejection_Reason__c). Do not remove the gate.

1B. objects/Opportunity/validationRules/Dead_Pass_Not_Allowed_From_Closed_Won.validationRule-meta.xml
    AND(ISCHANGED(StageName), ISPICKVAL(PRIORVALUE(StageName),'Closed Won'),
        ISPICKVAL(StageName,'Dead/Pass'))
    errorDisplayField: StageName
    errorMessage: "A Closed Won deal cannot be moved to Dead/Pass. Contact your administrator."
    - The message must NOT suggest a self-service route, because there is none.
    - PRIORVALUE-keyed so it is transition-only and self-limiting; existing Dead/Pass records are
      unaffected.

1C. 🔴 HIGHEST-RISK CHANGE IN THIS TRANCHE. Rule 1B REVERSES A RECORDED PRIOR USER DECISION.
    1B MUST carry an XML comment INSIDE the root element (a comment ABOVE the root breaks `sf` at
    source conversion with a misleading parent-xml error) containing ALL FIVE of:
      1. the 2026-08-30 user decision + date, and that it was REAFFIRMED after the consequence was
         stated;
      2. the superseded invariant QUOTED VERBATIM -- "the user-required invariant that Dead/Pass
         stay reachable from every stage" -- and where it is recorded
         (objects/Opportunity/validationRules/No_Backward_Stage_Movement.validationRule-meta.xml);
      3. that CLOSED WON NOW HAS NO IN-APP EXIT: ranks 1-7 blocked as backward, CARVE-OUT 2 excludes
         Closed Won, D4 rejected a bypass permission, and this rule closes the last route. A
         wrongly-Closed-Won deal requires an ADMIN DATA FIX;
      4. that NO bypass custom permission was added, and adding one would re-open D4;
      5. a warning that anyone reading only No_Backward_Stage_Movement's header WILL BE MISLED,
         with a pointer to this file as the current decision.
    ⚠ <description> is capped at 255 chars (breached 3x in this programme). The block goes in the
      COMMENT, not the description.

1E. MODIFY objects/Opportunity/validationRules/No_Backward_Stage_Movement.validationRule-meta.xml
    -- DO NOT TOUCH ITS errorConditionFormula. Two edits only:
    (i)  errorMessage: it currently reads "A deal cannot be moved back to an earlier stage. To stop
         work on this deal, move it to Dead/Pass instead." That now RECOMMENDS A BLOCKED ROUTE for
         Closed Won deals. Amend it so it does not.
    (ii) header comment: RETRACT VERBATIM the "two-save round trip through Dead/Pass IS the actual
         recovery procedure" paragraph and the "Dead/Pass always reachable, per invariant" claim,
         in this file's established retracted-then-corrected style, and point at 1B as current.

=== ITEM 2 -- two fields ===
2A. objects/Opportunity/fields/Stage_Entry_Date__c.field-meta.xml -- type Date
2B. objects/Opportunity/fields/Days_In_Stage__c.field-meta.xml -- FORMULA, Number, scale 0
    IF(IsClosed, 0, IF(ISBLANK(Stage_Entry_Date__c), null, TODAY() - Stage_Entry_Date__c))
    formulaTreatBlanksAs: BlankAsZero
    - Ported from objects/Lease_Inquiry__c/fields/Days_In_Stage__c.field-meta.xml.
    - Use IsClosed rather than naming 'Closed Won'/'Dead/Pass': it is the standard formula field, is
      true for both (verified in OpportunityStage.standardValueSet), and survives a future closed
      stage.
    - Note the casing: Days_In_Stage__c, capital I. Opportunity.Days_in_System__c has a lowercase i
      and is a pre-existing ARCHITECTURE.md §1 violation. Do NOT copy it.

=== ITEM 5 -- Offer_Status__c. DO NOT CREATE Source_Broker__c. ===
5A. objects/Opportunity/fields/Offer_Status__c.field-meta.xml
    Picklist, restricted=true, values Open / Submitted / Closed, Open as <default>true.
5B. MODIFY objects/Opportunity/recordTypes/{Land,Retail,Commercial}.recordType-meta.xml
    Add all three Offer_Status__c values to EACH.
    🔴 Record-type picklist restriction IS enforced by DML in this org (measured 4x). Several repo
      files claim it is UI-only; they are WRONG. These record types MUST deploy BEFORE any Apex
      naming a value.
    🔴 A record type file that OMITS a picklist silently drops ALL of its values for that type.
      Enumerate every picklist already present. Never write a partial file.
5C. objects/CFO_Alert_Rung__mdt/CFO_Alert_Rung__mdt.object-meta.xml -- NEW, STRUCTURE ONLY
    Days_Before_Due__c Number(3,0); Is_Active__c Checkbox.
    Rows come from the developer's loader script -- CustomMetadata RECORD deploys fail in this repo.
    Template: objects/Broker_Protection_Config__mdt/.
    It is a SEPARATE type from Item 4's Stage_Threshold_Def__mdt, deliberately: the rung values are a
    data contract with stored Offer_Alert_Last_Interval__c markers on live deals, and Item 4's
    thresholds are not. One shared type would let one admin edit corrupt the other feature.
5D. MODIFY objects/Opportunity/listViews/Offers_Due_Soon.listView-meta.xml
    Add the Offer_Status__c column.
    ⚠ DO NOT create Source_Broker__c. A CFO is issued by the seller's LISTING broker and
      Listing_Broker_Name__c / Listing_Broker_Email__c already hold that. Adding a fourth broker
      field would violate LeadConvertService's explicit "Do not merge the two" warning.

=== ITEM 6.1 -- three Account roll-up summaries ===
Load the sf-custom-field skill. Roll-up XML is a known deploy-failure area.
    objects/Account/fields/Total_Deals_Submitted__c  count of Opportunity, no filter
    objects/Account/fields/Deals_Won__c              count, filter StageName equals 'Closed Won'
    objects/Account/fields/Deals_Lost__c             count, filter StageName equals 'Dead/Pass'
  - summaryForeignKey Opportunity.AccountId; summaryOperation count; OMIT <summarizedField> for
    count (supplying it is a common failure). Use the LITERAL 'Dead/Pass' in the filter value.
  - Field descriptions must note that BrokerFirmController also computes these three numbers live in
    Apex, so a future divergence is diagnosable.

=== ITEM 6.2 -- two NEW Contact fields + descriptions on two EXISTING ones ===
6A. objects/Contact/fields/Deals_Lost__c.field-meta.xml            -- NEW, Number(18,0)
6B. objects/Contact/fields/First_Submission_DateTime__c.field-meta.xml -- NEW, DateTime
    (DateTime, not Date: the source Lead.First_Seen_Date__c is a DateTime despite its Date suffix,
    and Opportunity.Broker_First_Seen__c moved Date->DateTime on 2026-08-30 to match. A .date()
    truncation would discard the instant.)
6C. MODIFY objects/Contact/fields/Deals_Submitted__c.field-meta.xml and Deals_Won__c.field-meta.xml
    -- description only, no type change.

🔴 ALL FOUR of the above need a <description> stating the POPULATION. This is a HARD REQUIREMENT,
   not documentation polish -- without it the metric inversion documented in §1 gets rediscovered as
   a bug. In substance: "Covers only brokers who have a Contact -- i.e. those whose Lead was
   converted. Brokers who submitted and lost never receive a Lead (since 2026-07-31) and therefore
   never appear here. The authoritative broker population is the brokerLeaderboard component /
   BrokerLeaderboardService, computed live from Competing_Broker_Submission__c. Maintained nightly by
   BrokerCounterRecalcBatch."
   ⚠ <description> caps at 255 chars -- split across the description and an XML comment inside the
   root if needed.
🔴 DO NOT TOUCH Contact.Active_Listings__c, Closed_Volume__c or Avg_Days_On_Market__c. They are the
   DISPOSITION-side scorecard and mean something else entirely.

=== ITEM 4 IS NOT IN THIS WAVE === (it depends on Item 2 deploying first)

=== PERMISSION SETS -- 🔴 READ GATE PS-1 IN THE DESIGN DOC BEFORE TOUCHING THESE ===
A PermissionSet deploy REPLACES its entire <fieldPermissions> collection. This caused a live outage
here. For each set: retrieve from the org -> diff against HEAD (concurrent sessions share this tree;
two Transaction permission sets are already modified and uncommitted) -> edit the RETRIEVED copy ->
deploy -> read back and confirm the delta. "Succeeded" is not proof.
  DPEG_Acquisition_Edit : Stage_Entry_Date__c RW, Days_In_Stage__c R, Offer_Status__c RW
  DPEG_Acquisition_View : same, all read-only
  DPEG_Opportunity_View : Stage_Entry_Date__c R, Days_In_Stage__c R, Offer_Status__c R
  DPEG_Account_View     : the three roll-ups, R ONLY
  DPEG_Contact_Edit / DPEG_Contact_View : Deals_Lost__c R, First_Submission_DateTime__c R (both are
    batch-maintained; SYSTEM_MODE writes need no user grant). Confirm Deals_Submitted__c /
    Deals_Won__c grants already exist.
⚠ editable=true on a FORMULA or ROLL-UP field FAILS the deploy.
⚠ Metadata-deployed fields arrive with NO FLS for ANY profile including System Administrator --
  without these grants the new fields throw "No such column" at runtime.

DO NOT DEPLOY -- create metadata files only. (Deployment is blocked this session anyway: the
salesforce MCP server is returning CONNECT_TIMEOUT.)
```

### 🟢 PROMPT — `salesforce-developer` (WAVE A: Items 1D, 3, 5c, 5d)

```
Read ARCHITECTURE.md §2, .claude/rules/apex-layering-rule.md, .claude/rules/bulk-test-rule.md, and
agent-output/design-requirements.md (the RECORD OF TRUTH). Record
`mcp=unavailable | mcp_tools=none` after a real attempt; fall back to sf-apex / sf-apex-test.
API 67.0. Class names cap at 40 chars. `bulk` is a RESERVED WORD and produces misleading
"method does not exist" errors. No inline SOQL outside selectors. `with sharing` on every class.

=== ITEM 1D: THREE COMMENT-ONLY AMENDMENTS. NO LOGIC CHANGES. ===
A new validation rule (Dead_Pass_Not_Allowed_From_Closed_Won) blocks Closed Won -> Dead/Pass. This
REVERSES a recorded user invariant, and three Apex files carry premises it falsifies or narrows.
Amend the COMMENTS ONLY, in this repo's retracted-verbatim-then-corrected style:

  1. classes/DealFolderService.cls -- its header lists "the Dead/Pass two-save recovery" as one of
     seven live routes into CLAIM_STAGES. NARROWED, not falsified (Dead/Pass is still reachable from
     ranks 1-7). Amend to say the route no longer exists FROM CLOSED WON.
  2. classes/LeadPropertyEmailGateTest.cls -- its header justifies the Lead `Disqualified` carve-out
     as "mirroring the Opportunity Dead/Pass invariant", which no longer holds universally. Amend
     the justification. ⚠ DO NOT CHANGE THE LEAD BEHAVIOUR -- the Lead carve-out was not part of
     this decision and must not be swept along.
  3. classes/OpportunityReviewServiceTest.cls, noDuplicateOnReentry (~line 707) -- its comment
     asserts "entering it is always allowed (the escape hatch every stranded deal needs)". THE TEST
     STILL PASSES (it moves away from Development Review, rank 3, not Closed Won). Amend the COMMENT
     only, and note that a future test copying this pattern from Closed Won would fail confusingly.

🔴 A green dry-run can mean "never validated": byte-identical components report `Unchanged` and are
SKIPPED, and comment-only edits may not register as a diff. This applies unusually strongly to this
item -- confirm these three files actually deployed.

=== ITEM 3: NDA gate on LOI approval submission ===
🔴 A validation rule CANNOT implement this and you must not write one. Verified:
OpportunityApprovalService.resolveApprovalTargetId maps LOI__c -> the PARENT Opportunity, and
Approval.process submits the OPPORTUNITY. NO DML touches the LOI__c row, so an LOI__c VR can never
fire. Confirmed independently by objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml. An
Opportunity-side VR is also unreliable -- LoiGateTest.rejectionReturnsDealToUnderwriting shows
approval field updates BYPASS custom validation rules in this org.

1. MODIFY classes/OpportunityApprovalService.cls
   Add an NDA pre-check BEFORE Approval.process, applying ONLY when the resolved target is an
   Opportunity at StageName = 'LOI'. Refuse when Primary_NDA__c is blank OR
   Primary_NDA__r.NDA_Signed__c is false.
   Throw the class's own typed ApprovalException (its EXCEPTION CONTRACT reserves that type for
   user-actionable violations safe to surface verbatim). NEVER AuraHandledException -- this service
   deliberately never throws that; the controller masks unexpected failures.
   Message: "The primary NDA must be signed before this LOI can be submitted for approval. Link a
   signed NDA (Primary NDA) on the deal first."  (mirrors NDA_Signed_Before_Deal_Progression so the
   two gates read as one rule)

   🔴 YOU ARE FALSIFYING A PREMISE IN THIS CLASS'S OWN HEADER. It argues: "THE STAGE RE-READ IS
   DELIBERATELY IN THE CATCH, NOT BEFORE THE SUBMIT. A pre-check would cost a query on every
   successful submission to serve only the failure path." That is true when the query buys a better
   ERROR MESSAGE and false when it buys a CORRECTNESS GATE. Amend that paragraph IN PLACE in this
   file's retracted-verbatim-then-corrected style, or the next reader will delete your pre-check as
   a violation of the class's own stated rule.

   🔴 DO NOT add a RecordType.DeveloperName == 'Acquisition_LOI' check. It would never discriminate:
   a Disposition_LOI has a blank Opportunity__c, so resolveApprovalTargetId already returns null and
   the service already refuses it. The disposition side has a wholly separate path
   (dispositionSubmitForApproval -> DispositionApprovalService). Record this reasoning in the header
   INSTEAD -- a criterion that never discriminates gets read as load-bearing by the next person.

2. MODIFY classes/OpportunitySelector.cls
   New method returning Id, StageName, Primary_NDA__c, Primary_NDA__r.NDA_Signed__c for one Id.
   WITH SYSTEM_MODE, justified AT ITS OWN DECLARATION: performed on the submitter's behalf as an
   automation gate, and USER_MODE THROWS (does not degrade) on one inaccessible field, refusing a
   legitimate submission with "No such column" wearing a schema error.
   ⚠ This class's header says "THREE are WITH SYSTEM_MODE" and enumerates them. Amend the count and
   list IN PLACE, and heed its warning: "Do not read a future fourth SYSTEM_MODE method as
   conformant because three already exist."

3. MODIFY classes/OpportunityApprovalServiceTest.cls
   signed NDA submits; unsigned refused (typed exception); BLANK Primary_NDA__c refused; non-LOI
   stage unaffected; an Underwriting__c submission unaffected (resolves to itself).
   The 251-record mandate does NOT apply (single-record UI action, one per transaction) -- STATE
   THAT REASONING IN THE TEST CLASS HEADER, as bulk-test-rule.md's exemption requires.
   ⚠ Expect fixture breakage in LoiGateTest, StageApprovalGatesTest and
   OpportunityApprovalControllerTest: any existing test submitting an LOI-stage deal without a
   signed Primary_NDA__c now fails. Fix the FIXTURES, not the logic.

=== ITEM 5(c): suppress the CFO reminder once Submitted/Closed ===
4. MODIFY OpportunitySelector.queryCallForOffersAlerts()
   🔴 SOQL NULL TRAP -- get this exactly right. Every existing deal has Offer_Status__c = null, and
   `Offer_Status__c NOT IN ('Submitted','Closed')` evaluates UNKNOWN for null and EXCLUDES the row,
   silently killing the alert for the ENTIRE existing population on day one. Write:
       AND (Offer_Status__c = NULL OR Offer_Status__c NOT IN ('Submitted','Closed'))
   The filter belongs in the SELECTOR, not the batch: it is a POPULATION filter, not a ladder
   threshold, and excluding rows before chunking is cheaper.
   ⚠ OpportunitySelectorTest.queryCallForOffersAlerts_doesNotSelectTheReceivedDate PINS the selected
   field list -- adding a field may red it.
5. Add BOTH `..._excludesSubmittedAndClosed` and `..._stillIncludesNullStatus` to
   OpportunitySelectorTest. The second is the falsifier for the null trap and is the more valuable.

=== ITEM 5(d): move the CFO rung VALUES to Custom Metadata. PRESERVE THE LADDER. ===
The user chose OPTION (i): the {7,3,1,0} four-rung ladder is preserved EXACTLY; only its values move
into CMDT so an admin can retune without a deploy. NO regression. Do NOT collapse it to a single
2-day interval. Do NOT invalidate any stored Offer_Alert_Last_Interval__c marker.

6. MODIFY classes/CallForOffersService.cls -- replace the ALERT_INTERVALS constant with a read of
   CFO_Alert_Rung__mdt (the admin ships the type; a CMDT read is NOT SOQL and costs no governor
   units). Filter on Is_Active__c.
   🔴 ORDER IS LOAD-BEARING AND getAll() DOES NOT GUARANTEE IT. intervalFor() iterates the list and
   keeps the LAST match, which only yields "the smallest rung still containing the deal" because the
   list is in DESCENDING order. A Map from getAll() has NO guaranteed iteration order. You MUST sort
   the rungs DESCENDING explicitly after reading them. Getting this wrong changes which rung fires,
   silently, with no error.
   ✅ CallForOffersAlertBatch's rule -- "If you find yourself writing 7 or 3 in this file, stop" --
   SURVIVES UNCHANGED and is strengthened: the values live in CMDT, are read by the pure service,
   and the batch still contains no literal. Do not move any logic into the batch.
7. CREATE scripts/load-cfo-alert-rungs.apex -- seed EXACTLY 7, 3, 1, 0 so day-one behaviour is
   BYTE-IDENTICAL to today. Template: scripts/load-broker-protection-config.apex. Debug the row
   count in finish() so an empty load is visible.
8. CallForOffersServiceTest -- add a case proving the ladder still behaves identically at each rung
   with the seeded CMDT rows, and a case proving DESCENDING sort is applied regardless of map order.
   ⚠ ALSO (Item 5e): confirm a `shouldFire`-re-arms-on-moved-due-date case exists; add one if not.
   DO NOT MODIFY shouldFire -- line 416 already reads
       Integer effective = (markerDueDate == liveDueDate) ? lastInterval : null;
   under the comment "A DEADLINE THAT MOVED RE-ARMS EVERYTHING." The task brief called this a
   "likely latent bug". It is not a bug. It is the feature.

DO NOT deploy. DO NOT write tests for code you did not change.
```

### 🟢 PROMPT — `salesforce-developer` (WAVE B: Item 2)

```
Dispatch only AFTER Item 2's admin fields (Stage_Entry_Date__c, Days_In_Stage__c) have deployed.
Read ARCHITECTURE.md §2, apex-layering-rule.md, bulk-test-rule.md, and
agent-output/design-requirements.md §2 ITEM 2.

Stamp Opportunity.Stage_Entry_Date__c on every StageName change, in a BEFORE trigger.

WHY A BEFORE-TRIGGER AND NOT A FLOW -- carry this into the code, do not re-derive it:
Salesforce order of execution runs before-save FLOWS before Apex BEFORE-TRIGGERS. Opportunity has
TWO active before-save flows -- Opportunity_Initiate_Underwriting (which jumps StageName to
'Underwriting' from any stage) and Opportunity_LOI_Prep_Stamp. A before-trigger therefore observes
the FINAL StageName after the flow has rewritten it, while Trigger.oldMap still holds the true prior
DB value. A third before-save Flow would have NO defined ordering relative to the other two.
(The task brief claimed FOUR before-save flows on Opportunity. There are TWO --
Contract_Review_Stage_Sync targets Contract_Review__c and NDA_Signed_Status_Sync targets NDA__c.
The conclusion holds; the count did not.)

1. MODIFY triggers/OpportunityReviewTrigger.trigger
   Widen from `on Opportunity (after insert, after update)` to
   `on Opportunity (before insert, before update, after insert, after update)`.
   (The brief said to stamp in "OpportunityReviewTriggerHandler (before update)" -- that context does
   not exist yet, which is why the trigger must be widened.)
2. MODIFY classes/OpportunityReviewTriggerHandler.cls
   Add beforeInsert() / beforeUpdate() overrides routing to the new service. Update the class header:
   it says "Routes the after-insert and after-update contexts" and enumerates five after-context
   service calls. Both statements become incomplete.
3. CREATE classes/OpportunityStageEntryService.cls
   stampStageEntryDates(List<Opportunity> opps, Map<Id,Opportunity> oldMap)
   - ZERO SOQL, ZERO DML at any record count -- a pure in-memory assignment. That is what makes it
     safe to widen a trigger already routing five services, one of which enqueues a SharePoint
     Queueable under a never-throw contract and another of which throws by design.
   - Model it on DispositionStageEntryService.stampListingDates (before-save, in-memory, zero
     statements) BUT NOTE ONE DELIBERATE DIFFERENCE: that method is FILL-IF-BLANK for idempotency.
     Yours must OVERWRITE UNCONDITIONALLY on a genuine transition -- re-entering a stage MUST restart
     the clock.
   - Entry, not presence: prior == null (insert) counts as entry into whatever stage it was created
     at. Guard `priorStage == newStage -> continue`.
   - Hoist Date.today() once per chunk so two records in one save cannot straddle midnight.
   - `with sharing`. Layer = service. No selector (nothing is read).
4. CREATE classes/OpportunityStageEntryServiceTest.cls
   bulk-test-rule.md applies IN FULL -- trigger-driven, no exemption. 251-record bulk INSERT and bulk
   UPDATE tests, assertions matching 251.
   🔴 Assert the governor shape (0 added SOQL, 0 added DML) on counters captured INSIDE the trigger
   context. Test.stopTest() RESTORES pre-test governor counters, so asserting Limits.* afterwards is
   SILENTLY VACUOUS. Precedent: ExtractAddressQueueable.lastRunQueryCount.
   Use TestDataFactory. Never @isTest(SeeAllData=true).
   Cover: insert-at-a-stage stamps; an update that moves the stage re-stamps; an update that does NOT
   move the stage leaves the date alone.
5. CREATE scripts/backfill-opp-stage-entry-date.apex
   Stage_Entry_Date__c = LastModifiedDate.date() for OPEN deals where it is null. SYSTEM_MODE,
   allOrNone = false, debug the row count.
   🔴 State in the header that LastModifiedDate is the last edit OF ANY KIND, not the stage entry, so
   day-1 Days_In_Stage__c values are an approximation and must not be read as history.

VERIFY, do not assume -- all eight StageName mutation paths must produce a correct stamp:
  1 manual UI / Path / list-view inline
  2 StageAdvanceService.setStage (Advance Stage action, advanceDealStage LWC)
  3 Opportunity_Initiate_Underwriting before-save Flow (-> 'Underwriting' from any stage)
  4 workflows/Opportunity.workflow-meta.xml -> Set_Stage_Underwriting (LOI_Approval final rejection)
  5 workflows/Opportunity.workflow-meta.xml -> UW_Set_Stage_Initiate_LOI (UW approval -> 'LOI')
  6 flows/Transaction_Complete_Close.flow-meta.xml -> RecordUpdate StageName='Closed Won' FROM THE
    TRANSACTION OBJECT  <-- the task brief did not list this path; it is ordinary DML and does fire
  7 LeadConvertService (conversion creates the Opportunity) -- this is why before-INSERT is included
  8 scripts/*.apex seed and migration scripts
Paths 4 and 5 are approval field updates, EXPECTED to re-fire triggers -- but this repo has measured
that approval field updates bypass VALIDATION RULES (a different mechanism, but the surprise rate is
high enough) so path 4 must be verified in-org post-deploy: take a deal to LOI, reject the LOI
approval, confirm the stamp moved.

Class names cap at 40 chars. `bulk` is a reserved word. Do NOT deploy.
```

### 🔵 + 🟢 PROMPT — WAVE C (Item 4) and WAVE D (Item 6.2/6.4)

```
WAVE C dispatches only AFTER Item 2 has deployed and Stage_Entry_Date__c / Days_In_Stage__c exist in
the org. WAVE D must NOT share a wave with Item 2 -- both touch the Opportunity write path and a
regression would be unattributable. Full component lists in
agent-output/design-requirements.md §2 ITEM 4 and ITEM 6, gates in §7.

--- WAVE C: ITEM 4 (stalled-deal reminder) ---
ADMIN: Stage_Threshold_Def__mdt (STRUCTURE ONLY -- rows come from the developer's loader script,
because CustomMetadata RECORD deploys fail in this repo); Opportunity marker fields
Stage_Alert_Last_Sent_Date__c (Date) and Stage_Alert_Stage__c (Text 80 -- THE SNAPSHOT, and it is NOT
optional: the thing that must re-arm this alert is a STAGE CHANGE, not a date change, so a date-only
marker leaves a deal that moved and stalled again PERMANENTLY SILENT); the Delayed_Opportunities
report; one new dashboard component titled distinctly from the existing "Stale Deals 7-Day" widget,
which measures NO ACTIVITY IN 7 DAYS, not stuck-in-stage (keep both -- user decision Q3).
🔴 dashboards/Acquisitions/Acquisitions_Dashboard_Junior.dashboard-meta.xml has
<runningUser>test-aysz9meqvl23@example.com</runningUser> -- a STALE SCRATCH-ORG ADDRESS, the known
cause of "invalid cross reference id" dashboard failures here. Repoint it. It is at 13 of 20
components. THREE OTHER dashboards are already modified and uncommitted in this working tree -- diff
against HEAD before editing. GATE FP-1: a dashboard deploy REPLACES the org copy, no version history.

DEVELOPER: StageDelayService (PURE -- every threshold lives here, the batch contains no `14`);
OpportunitySelector.queryStalledDeals (WITH SYSTEM_MODE; `IsClosed = FALSE` NOT a two-value NOT IN;
and `Stage_Entry_Date__c != NULL`, which is load-bearing for un-backfilled legacy deals);
StageDelayAlertBatch (SCOPE=200 INHERITED from CallForOffersAlertBatch's five measured probes -- say
so plainly rather than implying a fresh measurement, exactly as NdaExpiryAlertBatch words it; SEND
FIRST, STAMP SECOND; GroupNotifier.notifyWithOutcome, NEVER notify; stamp only successes);
StageDelayAlertSchedule; scripts/load-stage-threshold-defs.apex (8 rows, all 14); 251-record tests.
🔴 RECIPIENT_GROUP = 'Acquisition' -- the QUEUE. This is a RECORDED decision (Gate 1 Q2.3, in
NdaExpiryAlertBatch's header) taken over Acquisitions_Team and DPEG_Acquisitions_Team specifically so
the org's alert jobs cannot disagree about who "the Acquisition team" is. The task brief's
"Acquisitions public group" is a THIRD name and would re-open a settled question.
🔴 If notifying the Owner requires a SECOND send() per deal, RE-RUN the CPU arithmetic in
CallForOffersAlertBatch §1 (6.0 ms + 0.22 ms x |recipients|) for 400 sends per chunk before accepting
SCOPE=200. Do the arithmetic in your header; do not inherit a number computed for a different call
count.
Suppression cadence: FIRE ONCE PER STAGE OCCUPANCY (user decision Q2). Re-arm test:
Stage_Alert_Stage__c != StageName OR Stage_Alert_Last_Sent_Date__c < Stage_Entry_Date__c.
Structural template for all of it: NdaExpiryAlertBatch / NdaExpiryAlertSchedule / NdaExpiryService.

--- WAVE D: ITEM 6.2/6.4 (Contact broker counters) ---
The LEADERBOARD IS UNTOUCHED. Do NOT modify BrokerLeaderboardService, BrokerLeaderboardController,
lwc/brokerLeaderboard, brokerFirmCard or reports/Acquisitions/Broker_Leaderboard. It remains the
AUTHORITATIVE broker population because it is the only surface that sees losing brokers. These
Contact counters fix the BrokerController / Broker_Hub permanent-zeroes surface ONLY.

DEVELOPER:
1. classes/BrokerCounterRecalcBatch.cls -- NEW.
   🔴 BATCH OVER CONTACT, NOT OVER OPPORTUNITY. Locator: Contact WHERE
   RecordType.DeveloperName = 'Broker'. This is not style: batching over Contact means EVERY Contact
   in scope is written, so a broker whose deals were deleted or reassigned correctly goes to 0.
   Batching over Opportunity can only ever INCREASE counts and would silently strand them.
   Per chunk -- 2 SOQL, 1 DML, CONSTANT in the number of deals:
     - AggregateResult over Opportunity GROUP BY Broker__c WHERE Broker__c IN :chunkIds
       (COUNT all; COUNT where StageName='Closed Won'; COUNT where StageName='Dead/Pass')
     - AggregateResult over Lead MIN(First_Seen_Date__c) GROUP BY ConvertedContactId
       WHERE ConvertedContactId IN :chunkIds
     - one Database.update(..., false, AccessLevel.SYSTEM_MODE)
   ✅ NO EMAIL MATCHING, FUZZY OR OTHERWISE, ANYWHERE. Opportunity.Broker__c is a REAL Contact lookup
   (LeadConvertService: `o.Broker__c = l.ConvertedContactId`). BrokerLeaderboardService's reason-3
   warning about a fuzzy email match applied to Competing_Broker_Submission__c, whose identity is a
   TEXT EMAIL with no Contact lookup -- THIS BATCH DOES NOT TOUCH THAT OBJECT. Record this in your
   class header so the warning is not re-inherited by the next reader.
   ⚠ The brief pointed at Lead.Broker_First__c for the first-submission join. That field is a
   Text(255) MIRRORING THE BROKERAGE FIRM NAME (BrokerPortalService sets l.Company and
   l.Broker_First__c to the same input.brokerageFirm). It is NOT a broker link. Use
   Lead.ConvertedContactId.
   ⚠ All SOQL via selectors per apex-layering-rule.md -- add the aggregates to OpportunitySelector
   and LeadSelector, NOT inline. WITH SYSTEM_MODE, justified at EACH declaration.
2. classes/BrokerCounterRecalcSchedule.cls -- NEW.
3. Tests -- 251-record fixtures (no exemption). INCLUDE A RESET-TO-ZERO CASE: a Contact with counts
   whose Opportunities are removed must go to 0. That is the falsifier for the batch-over-Contact
   decision and is the most valuable test here.

DO NOT store win rate or last submission as fields -- they are computed in BrokerLeaderboardService,
which already ranks in Apex precisely so two surfaces cannot disagree.
DO NOT touch Contact.Active_Listings__c, Closed_Volume__c or Avg_Days_On_Market__c -- disposition-side.
DO NOT repoint BrokerFirmController at the new Account roll-ups -- explicitly out of scope (Q10).
```

---

## §11 — REMAINING JUDGEMENT CALLS I WOULD STILL FLAG

Everything below is **approved and being built**. These are recorded so that if any of them later
surfaces as a problem, the reasoning is on file rather than rediscovered.

1. **Item 1B leaves Closed Won with no in-app exit** (RESIDUAL-10). The user was shown this and
   reaffirmed. The mitigations are the 1C header block, the four 1D amendments, and post-deploy
   step **P8** (brief the team + agree the admin data-fix procedure). **P8 is the one most likely to
   be skipped and the one whose absence generates the first support call.**
2. **Item 6's Contact counters and the leaderboard will legitimately show different numbers** for
   the same broker — the counters count Opportunities where that Contact is the submitting broker;
   the leaderboard counts ledger submissions including competing ones. This is **correct**, not a
   bug, and the field descriptions are the only thing that will make it look correct to a reader.
   **Do not let the descriptions be trimmed to fit 255 characters — split into an XML comment instead.**
3. **Item 6.1 duplicates `BrokerFirmController`'s live computation** (F11, RESIDUAL-8). Out of scope
   by decision (Q10), but it is a genuine two-sources-of-truth situation and the natural follow-up
   is a one-line repoint that deletes the live count.
4. **Item 4's threshold exists in two places** (RESIDUAL-4) because a report filter cannot read
   CMDT. Unavoidable; worth the user knowing before they retune the CMDT and find the widget
   disagreeing with the bell.
5. **Item 4 will report nothing on seeded data** (RESIDUAL-7). Cheap to fix, embarrassing to
   discover during a demo.
