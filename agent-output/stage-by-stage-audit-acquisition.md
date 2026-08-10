# Acquisition Stage-by-Stage Spec — Conformance Audit

**Spec audited:** `spec-acquisition.md` (Part 1 — Acquisition, lines 1–191 of the DPEG stage-by-stage document)
**Implementation audited:** `F:\Acquisition-Design-Salesforce` @ `main` (commit `abcb4b3`), metadata files as source of truth
**Date:** 2026-08-09 · **Type:** read-only audit, no metadata created or changed

---

## 1. Verdict summary

| # | Spec section (lines) | Verdict |
|---|---|---|
| 1 | Lead status values New/Under Review/Qualified/Converted/Disqualified (4–28) | **ALIGNED** |
| 2 | Lead New → notification to Acquisition queue (8) | **NOT ALIGNED** — only Broker-Portal leads notify; email-intake leads notify nobody and are not queue-owned |
| 3 | Lead Qualified → notification to Acquisitions team (18) | **NOT ALIGNED** — notification exists but fires on *Converted*, not Qualified |
| 4 | Lead Converted → Property created, broker carried across, no notification (20–23) | **PARTIAL** — Property + broker correct; an unspecified notification fires here |
| 5 | Lead Disqualified available at any point (25) | **ALIGNED** |
| 6 | Opportunity stage names + order (30–190) | **ALIGNED** — plus one extra unspecified value `Portfolio Deal` |
| 7 | Record-type branching Land / "Retail" (57, 79) | **PARTIAL** — branching is correct; the branch is named **Commercial**, not Retail |
| 8 | Sale process field on/off-market (31) | **ALIGNED** (superset: 4 values) |
| 9 | NDA created when deal opens, linked as primary (35–36) | **ALIGNED** |
| 10 | NDA picklist Pending → **Received** → Signed (37–45) | **NOT ALIGNED** — middle value is `Sent`, not `Received` |
| 11 | Deal cannot pass Under Review until NDA Signed (44) | **PARTIAL** — gate covers Underwriting/LOI/PSA/About to Close/Closed Won but **not** Development or Construction Review |
| 12 | **Call for Offers matched to an existing deal (51–56)** | **NOT ALIGNED** — the implementation deliberately does the opposite (hard-gates, creates nothing). See §4. |
| 13 | Development Feasibility Review picklist (64–78) | **ALIGNED** — exact, value for value |
| 14 | Construction Feasibility Review picklist (86–103) | **ALIGNED** — exact, value for value |
| 15 | DFR/CFR auto-created at stage entry **and** on input-needed flag (62–63, 84–85) | **ALIGNED** |
| 16 | Dev/Con "notify Acquisitions team when opinion is shared" (61, 75, 83, 100) | **PARTIAL** — fires on `Recommendation__c` becoming non-null, not on `Stage__c = 'Share Opinion'` |
| 17 | Signed NDA required before Underwriting (105) | **ALIGNED** |
| 18 | Underwriting record + picklist Requested/In Progress/Approved/Completed (109–123) | **ALIGNED** |
| 19 | Underwriting Approval — **four principals**, first-to-respond, submitted by owner (107, 119) | **PARTIAL** — first-response and submitter correct; **two** approvers configured, not four |
| 20 | Underwriting approve → LOI; reject → back to Underwriting (107) | **ALIGNED** |
| 21 | Underwriting approval → Acquisitions team notification (108, 120) | **ALIGNED** |
| 22 | LOI cannot be entered until underwriting approved (125) | **ALIGNED** |
| 23 | LOI record + picklist Draft/Prepare / Review/Sent/Counter/Completed (129–146) | **ALIGNED** (cosmetic: stored as `Prepare/Review`) |
| 24 | LOI Approval — four principals, first-to-respond, reject → Underwriting (127) | **PARTIAL** — same two-approver gap; reject path correct |
| 25 | LOI notifications: Acquisitions on every counter, Legal on execution (128, 143, 149) | **ALIGNED** (IR also notified — extra) |
| 26 | Each counter round is its own Counter Offer record (144) | **ALIGNED** |
| 27 | PSA requires a linked, approved LOI (151) | **ALIGNED** |
| 28 | PSA stage derived from negotiation status, not set by hand (155) | **ALIGNED** |
| 29 | PSA negotiation-status → displayed-stage mapping (156–171) | **ALIGNED** — exact |
| 30 | PSA notifications per version / ready / executed (154, 160, 165, 170, 175) | **PARTIAL** — version, ready and executed all exist; nothing fires on `Initial Draft` itself |
| 31 | Executed → contract signed + Day 0 stamped (172) | **ALIGNED** |
| 32 | About to Close requires a close date not in the past (177) | **ALIGNED** |
| 33 | About to Close → Transaction opened notification (180) | **ALIGNED** |
| 34 | Closed Won requires contract signed (182) | **ALIGNED** |
| 35 | Closed Won → "the property becomes asset" (182) | **NOT ALIGNED** — only a status stamp; no `Property_Asset__c` is ever created |
| 36 | Dead/Pass available from any stage, "the only way out" (186–187) | **PARTIAL** — always reachable, but no dedicated action, and it is a documented two-save backdoor to any earlier stage |
| 37 | Department column throughout (who does what) | **NEEDS ORG VERIFICATION** — permission sets/personas are org state; profiles are `.forceignore`d |

---

## 2. Line-by-line findings

### Lead

**L4–8 — "New. The email lands in the system and a lead is created automatically. Notification: Acquisition queue."**

Lead creation is correct. The Broker Protection pipeline (`EmailToLeadHandler` → `ExtractAddressQueueable` → `EmailToLeadService.createLeadFromExtracted`) creates the Lead with `LeadSource = 'Email-to-Lead'` (`classes/EmailToLeadService.cls:86`, written at `:229`).

The notification is **missing for this population**. The only new-Lead notification is `flows/Broker_Portal_New_Lead_Notify.flow-meta.xml`, whose start filter is `LeadSource EqualTo 'Broker Portal'` (`:31–38`) — email-intake Leads never match it. Two further points:

- `assignmentRules/Lead.assignmentRules-meta.xml:1–2` is an **empty `<AssignmentRules/>` element** — no assignment rules exist at all.
- `EmailToLeadService` never sets `OwnerId`, so an email-intake Lead is owned by the Email Service context user, not the Acquisition queue.
- The queue itself exists and accepts Leads: `queues/Acquisition.queue-meta.xml:5–8`.
- Note the naming collision: the **Acquisition queue** (`queues/Acquisition`) and the **`Acquisitions_Team` public group** (`groups/Acquisitions_Team.group-meta.xml`, the recipient every `GroupNotifier` flow uses) are different objects. The spec uses both terms; they are not interchangeable in this org.

**Verdict: NOT ALIGNED.**

**L9–13 — "Under Review. Approval: None. Notification: None."**

Status value exists (`standardValueSets/LeadStatus.standardValueSet-meta.xml:10–15`); quick action `quickActions/Lead.Mark_Under_Review.quickAction-meta.xml` writes it via LDS with no Apex and no notification. **ALIGNED.**

*Undocumented extra gate:* `objects/Lead/validationRules/Property_And_Email_Required_To_Progress.validationRule-meta.xml:39–50` blocks entry to Under Review **or** Qualified unless `Property_Address__c` and `Email` are both filled. The spec does not mention this. Not a conflict, but it is a real entry criterion a reader of the spec would not expect.

**L14–18 — "Qualified. Notification: Acquisitions team."**

**No notification fires on Qualified.** `quickActions/Lead.Mark_Qualified.quickAction-meta.xml` is a headless LWC writing `Status` through LDS; no flow has a `Status = Qualified` filter.

The Acquisitions-team notification that does exist is `flows/Lead_Approved_Notify.flow-meta.xml` — label "Lead Converted Notify", start object `Lead`, `recordTriggerType Update`, filter `IsConverted` (`:55–63`), sending `Acquisitions_Team` the message "Lead converted — underwriting pending" (`:14, :20`). It fires **one status later than the spec asks**.

**Verdict: NOT ALIGNED** — the notification exists but is attached to the wrong status.

**L19–23 — "Converted. The property record is created and the broker is carried across. Notification: None."**

Property + broker are correct:
- `classes/LeadConvertService.cls:190` builds and inserts `Property__c`, `:241` links it as `Opportunity.Property__c`, `:315–361` maps the physical property facts.
- Broker: `:237–238` sets `Opportunity.Broker__c = l.ConvertedContactId`, and `stampBrokerContactRoles` (`:370+`) makes the converted Contact the **primary `Broker` `OpportunityContactRole`** by read-then-write.
- Record type + Deal Type carried at `:243–247`.

But `Lead_Approved_Notify` fires here, which the spec says should be silent.

**Verdict: PARTIAL** — mechanics correct, an unrequested notification fires.

**L24–28 — "Disqualified. Available at any point."**

`standardValueSets/LeadStatus.standardValueSet-meta.xml:28–33`; `quickActions/Lead.Disqualify.quickAction-meta.xml`. No validation rule restricts entry. **ALIGNED.** (Path step `pathAssistants/Lead_Funnel_Path.pathAssistant-meta.xml:12–16` surfaces `Disqualification_Reason__c` as a key field — guidance only, not enforced.)

---

### Opportunity — stages, record types, sale process

**L29–34 — stage list and "New" on conversion; sale process field.**

Stage values (`standardValueSets/OpportunityStage.standardValueSet-meta.xml`): New (`:5`), Under Review (`:14`), Development Review (`:23`), Construction Review (`:32`), Underwriting (`:41`), LOI (`:50`), PSA (`:59`), About to Close (`:68`), Closed Won (`:77`), Dead/Pass (`:86`) — **exact match to the spec, in the spec's order**. There is an eleventh value **`Portfolio Deal`** (`:95`) that the spec does not mention; it is absent from both business processes, so it is not selectable on either record type, but it does appear as a Path step (`pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml:44`).

`Sale_Process__c` exists (`objects/Opportunity/fields/Sale_Process__c.field-meta.xml`), restricted picklist: `Off-Market`, `On-Market Listing`, `Call for Offers`, `Auction` (`:15–33`), carried from `Lead.Sale_Process__c` at conversion (`classes/LeadConvertService.cls`, deal-process block). **ALIGNED** — a superset of the spec's on-/off-market requirement.

**L57 / L79 — record-type branching.**

- `objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml:17–20` contains **Development Review** and no Construction Review.
- `objects/Opportunity/businessProcesses/Commercial.businessProcess-meta.xml:13–16` contains **Construction Review** and no Development Review.
- Record types `Land` / `Commercial` bind to them (`recordTypes/Land.recordType-meta.xml:5`, `recordTypes/Commercial.recordType-meta.xml:5`).

The branching behaviour is exactly what the spec describes. **The discrepancy is the name:** the spec says "Construction Review — **Retail** deals only"; the org calls that record type **Commercial**. "Retail" exists in this org only as one of six `Asset_Type__c` values (`Retail Strip`, `recordTypes/Commercial.recordType-meta.xml:29–32`), which is a property attribute, not a deal branch. So the spec's "Retail deals" reads onto **Commercial deals** — but if DPEG genuinely means "only Commercial deals whose asset type is retail", the implementation is wider than the spec. Flagged as an open question (§5, Q1).

**Verdict: PARTIAL (naming).**

**L186–187 — "Dead / Pass. Available from any stage, and the only way out."**

- Present on both business processes (`Dead%2FPass`, `Land:13–16`, `Commercial:17–20`) and on the Path (`Acquisitions_Deal_Path:20`).
- `objects/Opportunity/validationRules/No_Backward_Stage_Movement.validationRule-meta.xml:141–157` gives Dead/Pass **rank 0**, which makes clause 3 (`new rank > 0`) false, so the backward-block never fires on entry to Dead/Pass. Always reachable — correct.
- `classes/StageAdvanceService.cls:89–93` pre-authorises `'Dead/Pass'` in `ALLOWED_EXPLICIT_TARGETS`, but **there is no Dead/Pass quick action** in `quickActions/` — the comment at `:70–72` calls it "pre-authorized for the deal off-ramp action", i.e. the action was never built. Today a user reaches Dead/Pass through the Path or inline edit, not a guarded action.
- **"the only way out" is not strictly true.** The same rule's own comment (`:26–30`) documents that entering and then leaving Dead/Pass is a two-save route back to *any* earlier stage with no special permission, and calls that the intended recovery procedure.

**Verdict: PARTIAL.**

*Cosmetic:* spec writes "Dead / Pass"; runtime value is `Dead/Pass` (stored `Dead%2FPass` in picklist/BusinessProcess metadata only).

*Path coverage gap:* `Acquisitions_Deal_Path` is `recordTypeName __MASTER__` (`:57`) and has steps for About to Close, Closed Won, Dead/Pass, LOI, New, PSA, Portfolio Deal, Under Review, Underwriting — but **no Development Review and no Construction Review steps**. The two record-type branch stages get no Path guidance.

---

### NDA

**L35–36 — "Created the moment the deal opens and linked as the deal's primary NDA."**

`classes/OpportunityReviewService.cls:207–238` (`ensureNda`): insert-only (`:209–211` returns when `oldMap != null`), idempotent via `NdaSelector`, creates `NDA__c(Status__c = 'Pending')` (`:230`) and stamps `Primary_NDA__c` back onto the deal (`:233–238`). **ALIGNED.**

**L37–43 — "Pending → Received → Signed."**

`objects/NDA__c/fields/Status__c.field-meta.xml:13–27` — restricted picklist `Pending` (default) / **`Sent`** / `Signed`.

The middle value is **`Sent`**, not `Received`. This is a real semantic difference, not just a label: `Sent` describes DPEG sending the NDA out; the spec's `Received` describes the NDA coming back from the broker (line 38 "NDA not yet received from broker", line 41 "The NDA has been received"). Two supporting fields follow the `Sent` reading — `Date_Sent__c` and `Date_Signed__c` (`objects/NDA__c/fields/`), with `Date_Sent__c` surfaced as the key field on the `Sent` Path step (`pathAssistants/NDA_Path.pathAssistant-meta.xml:14–17`).

Blast radius if renamed: `NDA__c/fields/Status__c.field-meta.xml`, `pathAssistants/NDA_Path.pathAssistant-meta.xml:17`, `classes/RecordStageAdvanceService.cls:125–128` (`NDA_NEXT_STAGE = {'Pending'=>'Sent', 'Sent'=>'Signed'}`), plus `Date_Sent__c` semantics and any list view/report referencing the value. ⚠ `.claude/rules` / memory: picklist-value removal requires a repo grep **and** an org query first.

**Verdict: NOT ALIGNED.**

**L44 — "Both sides have signed. The deal cannot pass Under Review until this stage is reached."**

`objects/Opportunity/validationRules/NDA_Signed_Before_Deal_Progression.validationRule-meta.xml:25–38` blocks stage entry to **Underwriting, LOI, PSA, About to Close, Closed Won** when `Primary_NDA__c` is blank or `Primary_NDA__r.NDA_Signed__c` is false.

Two gaps against a literal "cannot pass Under Review":
1. **Development Review and Construction Review are not in the list.** Both are rank 3 (`No_Backward_Stage_Movement:142`), i.e. immediately after Under Review, so a deal can leave Under Review into either review branch with an unsigned NDA. The rule's own comment (`:13–15`) says a new stage "must be added to this OR list explicitly, it is not covered automatically" — these two never were.
2. The rule is `ISCHANGED(StageName)`-gated, so a record **inserted directly** at a gated stage is not blocked (documented as an accepted hole, `:17–20`).

`NDA_Signed__c` is kept in sync from `Status__c = 'Signed'` by `flows/NDA_Signed_Status_Sync.flow-meta.xml:48–65`, which also stamps `Date_Signed__c`.

**Verdict: PARTIAL.**

---

### Call for Offers (L51–56) — the headline divergence

**Spec:** "the property address is read from it and compared against our live deals. On a match, the offer due date is taken from the email and stamped on that deal… Where no deal matches, nothing is created… the broker, the best-and-final requirement and the email itself are held alongside it… Notification: Acquisition queue, two days before the due date."

**What the implementation does today:** it creates nothing **and matches nothing**.

`classes/ExtractAddressQueueable.cls:829–835`:

```apex
if (isCallForOffersGated(extraction)) {
    // U2 CALL-FOR-OFFERS GATE. Same shape as the hard gate immediately above, and
    // deliberately so — no Lead, no claim, Task still logged by finish().
    outcomes.add(new RoutingOutcome(OUTCOME_CALL_FOR_OFFERS, null, null, PRIORITY_NO_PROPERTY));
    finish();
    return;
}
```

`isCallForOffersGated` (`:2489–2491`) is a single unconditional test on the LLM's own classification: `LLMExtractionResult.CATEGORY_CALL_FOR_OFFERS.equals(extraction.emailCategory)`. It returns **before `routeProperties(extraction)`**, so no address normalization, no registry lookup, no matching of any kind runs. The outcome label is `OUTCOME_CALL_FOR_OFFERS = 'Not Routed (call for offers)'` (`:423`). The `Inbound_Email_Staging__c` row keeps the raw body, all RFC headers and the full extraction JSON; a `Task` is logged (for Message-ID idempotency) but with a **null routed record**, so it is attached to nothing.

Component-by-component against what the spec now wants:

| Spec requirement | Exists today? | Evidence |
|---|---|---|
| Offer due date extracted from the email | **Yes** | The LLM extraction already returns `offerDueDate`; `classes/EmailToLeadService.cls:329` writes it to `Lead.Offer_Due_Date__c` on the *non-gated* paths |
| Deadline "normally in the subject line" is visible to the model | **Yes** | `buildLlmText` prepends `Subject: …` to the LLM text input (2026-08-03 change) |
| `Offer_Due_Date__c` field on Opportunity | **Yes** | `objects/Opportunity/fields/Offer_Due_Date__c.field-meta.xml` |
| Anything stamps it on an **existing** deal | **No** | Its only writer is `classes/LeadConvertService.cls:283`, carrying `Lead.Offer_Due_Date__c` → Opportunity at conversion. Nothing updates a live deal |
| Address matched against **live deals** | **Partial / indirect** | `PropertyMatchingService` matches against `Property_Registry__c` (the claim ledger), not against Opportunity. `resolveLiveRecord(Id)` (`:454–468`) resolves a converted Lead → `ConvertedOpportunityId`. So a deal is reachable **only if** it came through the claim pipeline and has a registry row; a manually-created deal has none and cannot be matched |
| Broker held alongside | **Partial** | Sender identity is resolved on every email (U1, `applySenderFirstBrokerIdentity`), but on the gated path it lands nowhere except the staging row |
| **Best-and-final requirement** | **No field anywhere** | Repo-wide grep for `best_and_final` / `Best_And_Final` / "best and final" across `force-app` and `docs` returns **zero hits** |
| Email held alongside the deal | **No** | The gated path's `RoutingOutcome` carries a null record Id, so the logged Task has no deal to attach to |
| Notification 2 days before the due date | **No** | No scheduled flow exists (`grep Scheduled force-app/main/default/flows` → nothing); the only Schedulables are `AttachmentCarrierSweepSchedule`, `RoutingRetrySweepSchedule`, `BrokerCheckInReminderSchedulable`. Closest artefact is the `Offers_Due_Soon` **Lead** list view (`objects/Lead/listViews/Offers_Due_Soon.listView-meta.xml`) — a manual surface, on the wrong object |

**Classes this would touch, in dependency order:**

1. `ExtractAddressQueueable` — the gate at `:829–835` must become a *branch* rather than a *return*, and a new sixth routing branch must resolve an existing deal and stamp it. This is the highest-risk edit in the module: everything below `:837` (`routeProperties`) currently assumes the email is a broker submission that may take a claim.
2. `LLMExtractionCalloutService` — the extraction already carries `email_category`, `offerDueDate`, broker identity and `category_confidence` (parsed but ungated). A **best-and-final** flag is a new prompt key + new parsed field; the class header at `:205–221` documents that adding keys is additive and does not break legacy-shape responses.
3. A **new selector/matching path to Opportunity.** `PropertyMatchingService` has no Opportunity read at all today. Either extend it to query live deals by normalized address (a new `OpportunitySelector` method — Opportunity carries `Property_Address__c`), or accept registry-only matching and its coverage hole.
4. `InboundEmailStagingService` — needs a new outcome label distinguishing *matched-and-stamped* from *no deal matched* (today both collapse into `'Not Routed (call for offers)'`; note the label prefix rules at `ExtractAddressQueueable:358, :423` — `'Not Routed'` is a list-view filter and `'Not Acquisition'` is a *different* one).
5. `EmailToLeadService` — **arguably untouched**, which is the safe design: the spec explicitly says "Where no deal matches, nothing is created", so no Lead is ever minted on this path and Lead DML ownership stays where it is.
6. New: two Opportunity fields (best-and-final flag; possibly a call-for-offers broker text pair, or reuse `Listing_Broker_Name__c` / `Listing_Broker_Email__c` which already exist on Opportunity), plus a scheduled notifier (Scheduled Flow or Schedulable + `GroupNotifier`) for T-2 days.

**Verdict: NOT ALIGNED — and in direct conflict with a documented decision. See §4.**

---

### Development Review (L57–78)

- **L57 Land only** — `businessProcesses/Land.businessProcess-meta.xml:17–20`. **ALIGNED.**
- **L62–63 created at the stage, and also if development input is flagged without moving the deal** — `classes/OpportunityReviewService.cls:40–41` (`devFlip` on `Development_Input_Needed__c`), `:45–47` (stage entry OR flip), `:86–91` inserts with `Stage__c = 'Requested'`, `Requested_By__c`. Idempotent via `DevelopmentFeasibilityReviewSelector` (`:70–72`). **ALIGNED.**
- **L64–78 picklist** — `objects/Development_Feasibility_Review__c/fields/Stage__c.field-meta.xml:13–37`: `Requested` (default) / `Feasibility analysis` / `Vendor proposals` / `Share Opinion` / `Completed`. **Exact match**, including the spec's lowercase "analysis" and "proposals". Advance order matches `classes/RecordStageAdvanceService.cls:243–248`. **ALIGNED.**
- **L61/L75 notification to Acquisitions team when the opinion is shared** — `flows/Dev_Review_Opinion_Notify.flow-meta.xml` sends `Acquisitions_Team` "Development opinion received" (`:14, :20`), but its start filter is `Recommendation__c IsNull false` with `doesRequireRecordChangedToMeetCriteria` (`:55–61`). It fires when a recommendation is **first entered**, not when `Stage__c` reaches `Share Opinion`. In practice those usually coincide; formally they are different triggers, and a stage advanced to Share Opinion without a recommendation notifies nobody. **PARTIAL.**

### Construction Review (L79–103)

- **L79 "Retail deals only"** — implemented on the **Commercial** record type (`businessProcesses/Commercial.businessProcess-meta.xml:13–16`). See §2 record-type note. **PARTIAL (naming).**
- **L84–85 created at the stage and on the input-needed flag** — `OpportunityReviewService.cls:42–43, :48–50, :92–97`. **ALIGNED.**
- **L86–103 picklist** — `objects/Construction_Feasibility_Review__c/fields/Stage__c.field-meta.xml:13–42`: `Requested` / `Site Visit` / `Condition Assessment` / `Cost Estimate` / `Share Opinion` / `Completed`. **Exact match.** Order matches `RecordStageAdvanceService.cls:228–234`. **ALIGNED.**
- **L83/L100 notification** — `flows/Con_Review_Opinion_Notify.flow-meta.xml`, same `Recommendation__c` proxy (`:55–61`). **PARTIAL.**

---

### Underwriting (L104–123)

- **L105 signed NDA required before this stage** — `NDA_Signed_Before_Deal_Progression:28` includes `Underwriting`. **ALIGNED.**
- **L109 Underwriting record created here** — `OpportunityReviewService.cls:124–136`, `Underwriting__c(Stage__c='Requested', Status__c='In Progress')`, then stamps `Primary_Underwriting__c`. **ALIGNED.**
- **L110–123 picklist** — `objects/Underwriting__c/fields/Stage__c.field-meta.xml:13–33`: `Requested` (default) / `In Progress` / `Approved` / `Completed`. **Exact match. ALIGNED.**
  - Note: `RecordStageAdvanceService.cls:218–222` deliberately **omits** `In Progress → Approved` from the manual advance map — that transition belongs to the approval process (line 220 is the gap in the map). This matches the spec's line 114 ("submits request for approval") and line 117 ("Set when the principals approve").
  - `Underwriting__c.Stage__c = 'Approved'` is written by `classes/ApprovalAuditService.cls:74–83` (`Stage__c = 'Approved'`, `Status__c = 'Approved by Principals'`) after the approval. **ALIGNED.**
- **L107 "Submitted by the deal owner, sent to four principals, and the first to respond decides."**
  `approvalProcesses/Opportunity.Underwriting_Approval.approvalProcess-meta.xml`:
  - `allowedSubmitters: type owner` (`:5–7`) — **matches**.
  - `whenMultipleApprovers: FirstResponse` (`:29`) — **matches**.
  - Approvers (`:20–27`): `nikhil.dhanani@usmandpeg.uat` and `aftab.ali.dpeg.usman@avanzasolutions.com` — **two, not four**. The `<description>` (`:34`) states the design explicitly as "EITHER principal (Ali or Nikhil)". Also `groups/Principals.group-meta.xml` exists but is not used as the approver.
  - Entry criteria `StageName equals Underwriting` (`:36–42`). Submission is routed by stage from `classes/OpportunityApprovalService.cls:50–91`, and from a child record via parent resolution (`:96–107`), so both `quickActions/Opportunity.Submit_for_Approval` and `quickActions/Underwriting__c.Submit_for_Approval` land in the right process.
  - `recordEditability: AdminOnly` (`:67`) — the deal is locked while pending. Spec is silent on this.
  - **PARTIAL — approver count.**
- **L107 "Approve advances the deal to LOI; reject returns it here for rework."**
  - Approve: `finalApprovalActions` → `UW_Set_Approved_Flag` (`workflows/Opportunity.workflow-meta.xml:34–37`, `UW_Approved__c = true`), `UW_Set_Stage_Initiate_LOI` (`:44–47`, `StageName = 'LOI'`), `UW_Set_Status_Approved` (`:54–57`, `Underwriting_Status__c = 'Approved by Principals'`). **ALIGNED.**
  - Reject: `UW_Reopen_For_Revision` (`:24–27`, clears `Underwriting_Complete__c`); no stage change, so the deal stays at Underwriting. **ALIGNED.**
  - `finalApprovalRecordLock: false` / `finalRejectionRecordLock: false` (`:57, :64`) — correct, and load-bearing for `LoiPrimaryStampQueueable`.
- **L108/L120 "Notification: Acquisitions team on approval"** — `flows/Opportunity_UW_Approved_Notify.flow-meta.xml`, start filter `Underwriting_Status__c EqualTo 'Approved by Principals'` (`:70–77`), notifies `Acquisitions_Team` "Underwriting approved - LOI pending" (`:14, :20`), and invokes `ApprovalAuditService` (`:42`). **ALIGNED.**

---

### LOI (L124–149)

- **L125 "Cannot be entered until underwriting is approved."** — `objects/Opportunity/validationRules/Underwriting_Approved_Before_LOI.validationRule-meta.xml:28–32`: blocks `StageName → 'LOI'` when `NOT(UW_Approved__c)`. **ALIGNED.** (Known accepted: `UW_Approved__c` is never cleared, so a once-approved deal can re-enter LOI forever — documented at `:21–23`.)
- **L129 "LOI record — created here"** — `OpportunityReviewService.cls:57–61, :160–178`: on entry to `LOI`, inserts `LOI__c(Stage__c='Draft', LOI_Status__c='Draft')` under `AccessLevel.SYSTEM_MODE` and defers the `Primary_LOI__c` stamp to `LoiPrimaryStampQueueable` (the approval lock). **ALIGNED.**
- **L130–146 picklist** — `objects/LOI__c/fields/Stage__c.field-meta.xml:13–38`: `Draft` (default) / `Prepare/Review` / `Sent` / `Counter` / `Completed`. Spec writes "Prepare / Review" with spaces; stored value is `Prepare/Review`. **Cosmetic only — treat as ALIGNED**, but if DPEG wants the spaced label it is a picklist-value change with the same blast radius as the NDA one (`RecordStageAdvanceService.cls:131–136`, `pathAssistants/LOI_Path`, `quickActions/LOI__c.*`).
- **L127 "LOI Approval. Same four principals, first to respond decides. Reject returns the deal to Underwriting."**
  `approvalProcesses/Opportunity.LOI_Approval.approvalProcess-meta.xml`:
  - `allowedSubmitters: owner` (`:5–7`) ✓; `FirstResponse` (`:27`) ✓; **two approvers** (`:19–26`) ✗ — same gap as Underwriting.
  - Entry `StageName equals LOI` (`:33–39`).
  - Approve → `Set_LOI_Approved_Flag` only (`:40–45`; `workflows/Opportunity.workflow-meta.xml:4–7`, `LOI_Approved__c = true`) — no stage move, which is correct because the PSA gate reads that flag.
  - Reject → `Set_Stage_Underwriting` (`:47–52`; `workflow:14–17`, `StageName = 'Underwriting'`). **ALIGNED**, and explicitly carved out of the backward-move rule (`No_Backward_Stage_Movement:159–163`).
  - **PARTIAL — approver count.**
- **L143 "Notification: Acquisitions team on every counter"** — `flows/Counter_Offer_Notify.flow-meta.xml`, object `Counter_Offer__c`, `recordTriggerType Create` (`:60–61`), recipient `Acquisitions_Team` (`:14`). **ALIGNED.**
- **L144 "Each round is its own Counter Offer record"** — `Counter_Offer__c` is a child of `LOI__c` (ARCHITECTURE §1); `lwc/loiCounterOffer` + `CounterOfferService` maintain the history. **ALIGNED.**
- **L149 "Notification: Legal"** on LOI executed — `flows/LOI_Signed_Notify.flow-meta.xml`, filter `LOI_Signed__c` (`:87–93`), notifies `Legal_Team` (`:51`) **and** `Investor_Relations` (`:14`). Legal is present; IR is an extra the spec does not request. **ALIGNED (superset).**

---

### PSA / Contract Review (L150–175)

- **L151 "Requires a linked, approved LOI."** — `objects/Opportunity/validationRules/Approved_LOI_Before_PSA.validationRule-meta.xml:22–29`: blocks `→ PSA` when `ISBLANK(Primary_LOI__c)` **or** `NOT(LOI_Approved__c)`. Both halves of "linked **and** approved". **ALIGNED.**
- **Contract Review created here** — `OpportunityReviewService.cls:51–53, :98–102, :110–120`: on entry to `PSA`, inserts `Contract_Review__c(Stage__c = 'PSA Drafting')` and stamps `Primary_Contract__c`. **ALIGNED.**
- **L155 "The stage shown on this record is worked out from the negotiation status, not set by hand."** — `flows/Contract_Review_Stage_Sync.flow-meta.xml` is a `RecordBeforeSave` `CreateAndUpdate` flow on `Contract_Review__c` (`:129–147`) that writes `Stage__c` from `Negotiation_Status__c`. Corroborated by the field description at `objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml:4` and by the memory note "derived stage field silently discards writes". **ALIGNED.**
- **L156–171 negotiation status values and their displayed stages.**
  `Negotiation_Status__c` values (`:14–33`): `Initial Draft` (default) / `Revised` / `Ready for Execution` / `Executed` — **exact match to the spec.**
  Mapping in `Contract_Review_Stage_Sync`:
  | Negotiation status | Spec says shows as | Flow writes | |
  |---|---|---|---|
  | Initial Draft | PSA Drafting | `Set_Stage_Drafting` → `'PSA Drafting'` (`:5–13`) | ✅ |
  | Revised | Review | falls to the default → `Set_Stage_Negotiation` → `'Review'` (`:51–59`) | ✅ |
  | Ready for Execution | Review | same default → `'Review'` | ✅ |
  | Executed | Contract Execution | `Set_Stage_Executed` / `Set_Stage_Executed_Only` → `'Contract Execution'` (`:18–46`), stamping `Execution_Date__c` when blank | ✅ |
  `Stage__c` also retains three **inactive** legacy values — `Contract Execution (Signed)`, `Contract Negotiation`, `Prepare` (`objects/Contract_Review__c/fields/Stage__c.field-meta.xml:28–45`, all `isActive false`). Harmless. **ALIGNED.**
  Manual advance order matches (`RecordStageAdvanceService.cls:170–174`).
- **L154/L160/L165 "Acquisitions team and Legal on each version"** — `flows/PSA_Version_Notify.flow-meta.xml`, object `PSA_Version__c`, `Create` (`:97–98`), recipients `Acquisitions_Team` (`:17`) and `Legal_Team` (`:51`). **ALIGNED.**
  ⚠ But nothing fires on `Negotiation_Status__c = 'Initial Draft'` itself (spec L160). The notification is tied to logging a **PSA Version row**, not to the status. If a first draft is received and the status set without a version row being created, no one is told. **PARTIAL.**
- **L170 "Ready for Execution → Acquisitions team"** — `flows/PSA_Ready_Notify.flow-meta.xml`, filter `Negotiation_Status__c EqualTo 'Ready for Execution'` (`:50–56`), recipient `Acquisitions_Team` (`:14`). **ALIGNED.**
- **L172 "the deal is marked contract signed and the execution date is stamped as Day 0"** — `classes/ContractExecutionService.cls:129–137`: `Contract_Signed__c = true`, `Contract_Executed_Date__c = dayZero` (only when null — "this is now the ONLY place it is stamped"). **ALIGNED.**
- **L175 "Notification: Transactions, Investor Relations"** — `ContractExecutionService.cls:152–164`: `Transactions_Team`, `Investor_Relations`, **and `Due_Diligence`** (a third recipient the spec does not name). **ALIGNED (superset).**

---

### About to Close (L176–180)

- **L177 "Requires a close date that is not in the past."** — `objects/Opportunity/validationRules/Close_Date_Before_About_To_Close.validationRule-meta.xml:25–29`: blocks entry when `CloseDate < TODAY()`. The comment (`:10–14`) explains why "close date set" could not be implemented as a blank check (`CloseDate` is platform-required). **ALIGNED** — and note this is a *not in the past* rule, exactly as the spec words it.
- **L180 "Notification: Transaction opened notification."** — `ContractExecutionService.openTransactionsOnAboutToClose` (`:64–98`) creates the `Transaction__c` at the About to Close stage; `flows/Transaction_Opened_Notify.flow-meta.xml` fires on `Transaction__c` `Create` (`:29–30`) and sends the `Transaction__c.Transaction_Opened_Notification` **email alert** (`:8–9`). **ALIGNED.** (It is an email alert, not a custom notification — worth confirming that is what "notification" means here.)
- **L178 "Department: Transactions"** — **NEEDS ORG VERIFICATION** (persona/permission-set state).

### Closed Won (L181–185)

- **L182 "Requires the contract to be signed."** — `objects/Opportunity/validationRules/Contract_Signed_Before_Closed_Won.validationRule-meta.xml:26–30`. **ALIGNED.**
- **L182 "the property becomes asset"** — `flows/Transaction_Complete_Close.flow-meta.xml:51–65` sets `Deal_Category__c = 'Closed'`, `Deal_Status__c = 'Asset Under Management'`, `StageName = 'Closed Won'`. That is a **status stamp only**. A repo-wide search for `new Property_Asset__c` in `classes/` and `flows/` returns nothing — **no `Property_Asset__c` record is created anywhere** when a deal closes, so the Property Management module's root object must be created by hand. **NOT ALIGNED**, if the spec means an actual asset record.
- **L185 "Notification: None"** — but `Transaction_Complete_Close.flow-meta.xml:5–26` sends `Acquisitions_Team` "Deal closed - congratulations! 🎉". Minor extra.

---

## 3. Gaps requiring build work

Ordered by importance.

1. **Call for Offers → match to an existing deal (L51–56).** The single largest gap and a reversal of shipped behaviour.
   *Touches:* `ExtractAddressQueueable` (new routing branch replacing the `return` at `:829–835`), `LLMExtractionCalloutService` (best-and-final prompt key), a new Opportunity-matching read (there is **no** Opportunity address query today), `InboundEmailStagingService` (new outcome labels), new Opportunity fields (best-and-final; possibly a call-for-offers broker pair), a new scheduled T-2-day notifier.
   *Size:* **L.**
   *Risk/dependency:* this is the riskiest file in the repo — the routing tree owns Lead creation, the registry claim and broker arbitration, and the module has already had two production incidents. It also **contradicts a deliberate, user-instructed decision** (see §4.1). Must go through the design gate before any code.

2. **Approval panels are 2 principals, not 4 (L107, L119, L127, L148).**
   *Touches:* `approvalProcesses/Opportunity.Underwriting_Approval.approvalProcess-meta.xml:18–33`, `approvalProcesses/Opportunity.LOI_Approval.approvalProcess-meta.xml:16–31`; possibly repoint to `groups/Principals.group-meta.xml` instead of named users.
   *Size:* **S** (metadata), **but see risk.**
   *Risk:* the two named approvers are **org-specific usernames on `usman-dpeg`**; adding two more requires the real principals to exist as users in the target org. Memory note: changing `whenMultipleApprovers` on a live process breaks pending work-item loops — do not also change the mode. Deactivating/reactivating an approval process with history requires recycle-bin purge. **NEEDS ORG VERIFICATION** for who the other two principals are.

3. **NDA middle status is `Sent`, spec says `Received` (L40–42).**
   *Touches:* `objects/NDA__c/fields/Status__c.field-meta.xml`, `pathAssistants/NDA_Path.pathAssistant-meta.xml:14–17`, `classes/RecordStageAdvanceService.cls:125–128`, `objects/NDA__c/fields/Date_Sent__c.field-meta.xml` semantics, plus list views/reports.
   *Size:* **M** (additive add → backfill → repoint → retire, per the field-rename rule; picklist value removal requires a repo grep **and** an org query first).
   *Risk:* `Sent`/`Received` are not synonyms — decide whether DPEG wants a **rename** or a **fourth value** (Pending → Sent → Received → Signed). Q2 in §5.

4. **New-Lead notification to the Acquisition queue (L8), and queue ownership.**
   *Touches:* a new record-triggered flow (or widen `Broker_Portal_New_Lead_Notify`'s filter), `assignmentRules/Lead.assignmentRules-meta.xml` (currently empty), possibly `EmailToLeadService` for `OwnerId`.
   *Size:* **S–M.**
   *Risk:* the "Acquisition **queue**" and the "`Acquisitions_Team` **public group**" are different objects; `GroupNotifier` takes a group name. Queue membership is org-only and not deployable — **NEEDS ORG VERIFICATION**. Setting `OwnerId` inside `EmailToLeadService` touches a class with pinned DML budgets.

5. **Qualified notification is on the wrong status (L18 vs L23).**
   *Touches:* `flows/Lead_Approved_Notify.flow-meta.xml:55–63` (filter `IsConverted` → `Status = 'Qualified'`), or add a second flow and retire the converted one.
   *Size:* **S.**
   *Risk:* decide whether the converted-stage notification is dropped or kept (the spec says Converted is silent).

6. **NDA gate does not cover Development Review / Construction Review (L44).**
   *Touches:* `objects/Opportunity/validationRules/NDA_Signed_Before_Deal_Progression.validationRule-meta.xml:27–33` — add two `ISPICKVAL` clauses.
   *Size:* **S.**
   *Risk:* would block the review branches on deals that legitimately want development input **before** an NDA is signed — note `Development_Input_Needed__c` / `Construction_Input_Needed__c` exist precisely so those teams can engage without moving the stage, so the flag path stays open either way. Confirm intent (Q3).

7. **No `Property_Asset__c` created at Closed Won (L182).**
   *Touches:* a new after-save flow or an extension of `ContractExecutionService` / `Transaction_Complete_Close`.
   *Size:* **M.**
   *Risk:* `Property_Asset__c` is the root of the whole Property Management module (Units, Rent Steps, Onboarding, Leases, Work Orders); minting one automatically has downstream effects across four modules. Confirm whether DPEG wants automation or the current manual hand-off.

8. **"Opinion shared" notifications fire on `Recommendation__c`, not on `Stage__c = 'Share Opinion'` (L61, L75, L83, L100).**
   *Touches:* `flows/Dev_Review_Opinion_Notify.flow-meta.xml:55–61`, `flows/Con_Review_Opinion_Notify.flow-meta.xml:55–61`.
   *Size:* **S.**
   *Risk:* low — decide whether the trigger should be the stage, the recommendation, or both.

9. **No notification when the PSA reaches `Initial Draft` (L160).**
   *Touches:* a new filter on `Contract_Review__c`, or accept the existing `PSA_Version__c`-create notification as the mechanism.
   *Size:* **S.**

10. **No Dead/Pass quick action (L186–187).** `StageAdvanceService.ALLOWED_EXPLICIT_TARGETS` already pre-authorises `'Dead/Pass'` (`:89–93`); the LWC/quick action was never built.
    *Touches:* one `lwc` bundle reusing `c/dealActionGuard` + one quick action + the Opportunity FlexiPage action list.
    *Size:* **S.**
    *Risk:* ⚠ memory note — enabling/editing Dynamic Actions on a page can silently empty its whole action bar; readback is the only proof.

11. **Path coverage: `Acquisitions_Deal_Path` has no Development Review / Construction Review steps and carries a `Portfolio Deal` step for a stage neither record type allows** (`pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml:44, :57`).
    *Size:* **S.**
    *Risk:* the Path is `__MASTER__`; per-record-type Paths would be needed to show the two branch stages correctly.

---

## 4. Contradictions between the spec and deliberate existing decisions

### 4.1 Call for Offers — the spec reverses a decision taken on the user's explicit instruction

This is the headline conflict and it is not an oversight in the code.

**What is documented:** `ARCHITECTURE.md` (INTAKE RULES V2, rule U2) and `classes/ExtractAddressQueueable.cls:2409–2489` record that a call-for-offers email produces **no Lead, unconditionally**, because "DPEG does not work marketed call-for-offers campaigns, so a Lead for one is never wanted." The rationale is recorded verbatim as a **user decision at the design gate**: *"if email is related to call for offers then we must not store it as a lead, simple."* The class header explicitly notes this rule is **stricter than the module's own primary relevance gate** (D2 requires `confidence >= 0.85`; U2 requires nothing), and that the inconsistency was accepted deliberately "because the business rule is categorical… Written down so a future reader treats it as a decision, not a defect to quietly 'fix'."

**What the new spec asks for:** the same emails should be *matched against live deals*, and on a match should *stamp the offer due date, the broker, the best-and-final requirement and the email itself* onto that deal, and should *notify the Acquisition queue two days before the deadline*.

**These are reconcilable, and the reconciliation is important:** the spec does **not** ask for a Lead either. Both agree that a call-for-offers email must never mint a Lead or take a registry claim. The spec adds *enrichment of an existing deal* on top of the existing suppression, and keeps "where no deal matches, nothing is created" — which is exactly today's behaviour for the no-match case. So the correct framing for the user is:

> The gate stays. What changes is that before returning, the pipeline now tries to find an existing deal and, if it finds one, updates it. Nothing is ever created.

Two residual risks the existing documentation already names and that the new requirement makes sharper:
- `ExtractAddressQueueable.cls:2422` — a **misclassified** exclusive listing suppressed as `call_for_offers` leaves the property unclaimed, and a later broker wins it outright; recovery is manual registry surgery. Adding a deal-stamping path does not fix that; it makes the `Gated_Call_For_Offers` list view *more* load-bearing, not less.
- `category_confidence` is parsed and stored but **nothing gates on it** (`ExtractAddressQueueable.cls:510`, `LLMExtractionCalloutService.cls:206`). If deal-stamping is added, that field is the correct gate for it — and the header explicitly warns **not** to use `confidence`, which measures certainty about `is_acquisition_related` and carries no discrimination here.

**Decision needed from the user:** confirm that "match and stamp, still never create" is the intent. If so, U2's suppression is preserved and the change is additive.

### 4.2 "Retail deals only" vs the Commercial record type

The spec's branch name (Retail) does not exist as a record type. `Commercial` covers six asset types including `Retail Strip`. Either the spec is using "Retail" loosely for "Commercial", or DPEG intends Construction Review on a narrower population than the record type currently allows. Documented decision: the Land/Commercial split was built deliberately in the record-types phase and is wired into both business processes, the Path rank map, and `LeadConvertService`'s record-type assignment (`:243–247`). Renaming it is not a label change.

### 4.3 "Dead/Pass is the only way out"

`No_Backward_Stage_Movement`'s comment (`:26–30`) documents the opposite as *intended procedure*: Dead/Pass is deliberately reachable from and escapable to any stage, and the resulting two-save round trip **is** the sanctioned recovery for a mistakenly advanced deal, chosen over a bypass permission which the user explicitly rejected (D4). If the spec means Dead/Pass should be terminal, that reverses D4 and removes the only recovery route the design left in place.

### 4.4 Notification volume

The spec says "Notification: None" at Converted (L23) and Closed Won (L185); the implementation notifies `Acquisitions_Team` at both (`Lead_Approved_Notify`, `Transaction_Complete_Close:5–26`). It also notifies `Due_Diligence` on PSA execution and `Investor_Relations` on LOI execution, neither of which the spec names. These are extras, not errors — but if the spec is meant to be exhaustive, they should be reviewed rather than assumed benign.

---

## 5. Open questions for the user

1. **"Retail deals only" (L79) — does that mean the Commercial record type, or Commercial deals whose asset type is retail?** Today it means all Commercial deals. This changes whether §3 item 2's answer is "rename the label" or "add a filter".
2. **NDA `Received` (L40) — rename `Sent` → `Received`, or add `Received` as a fourth value?** They describe opposite directions of travel (we sent it vs. they returned it), and `Date_Sent__c` currently pairs with `Sent`. A four-value path (Pending → Sent → Received → Signed) may be what the process actually does.
3. **"The deal cannot pass Under Review until the NDA is Signed" (L44) — does that include the Development / Construction Review branches?** Today it does not. Blocking them would conflict with the `Development_Input_Needed__c` / `Construction_Input_Needed__c` design, which exists so those teams can engage before an NDA.
4. **Call for Offers — confirm "never create anything, only update an existing deal."** And: should the deal-stamp be gated on `category_confidence`, or applied unconditionally on any address match?
5. **Call for Offers matching scope — match against *any* live Opportunity by address, or only deals that came through the claim pipeline?** Today the only address→deal path runs through `Property_Registry__c`, so a manually-created deal is invisible to it. Matching all Opportunities means building the first address-based Opportunity query in this application.
6. **"Best-and-final requirement" (L53) — is that a yes/no flag, a date, or free text?** No field of any shape exists today.
7. **"Notification: Acquisition queue, two days before the due date" (L56) — desktop/mobile custom notification, or email?** And to the **Acquisition queue's members** or to the **`Acquisitions_Team` public group**? They are different populations in this org.
8. **Four principals (L107/L127) — who are the other two, and do they exist as users in the target org?** Approver identity is org state; the repo names two `usman-dpeg` usernames.
9. **"The property becomes asset" (L182) — should closing a deal auto-create a `Property_Asset__c`?** Today it only stamps `Deal_Status__c = 'Asset Under Management'`.
10. **Is the notification list in the spec exhaustive?** If yes, the four extra notifications named in §4.4 need a decision.

---

## 6. Items that could not be determined from the repo — NEEDS ORG VERIFICATION

- **Department / persona assignments** for every stage (Acquisitions, Development, Construction, Legal, Transactions, Principals). Profiles are `.forceignore`d in this repo, so FLS and profile-level access are not in source; permission sets are, but assignment is org state.
- **Acquisition queue membership** and whether the queue is a notification-capable recipient — queue/group membership is not deployable metadata.
- **Whether the two approval processes are active in the target org** and whether the named approver usernames resolve there.
- **Custom notification channel activation** for `Acquisitions_Deal_Update` (`notificationtypes/Acquisitions_Deal_Update.notiftype-meta.xml`) — desktop/mobile flags are in source, but delivery depends on org and user settings.
- **Whether the Lightning Paths are visible at all** — `pathAssistantEnabled` is an org-level master switch and `settings/**` is force-ignored (documented in memory as a recurring trap: the repo copy of a settings file has been measured contradicting the org).
- **Any org-side-only validation rules, flows or notifications** created by hand and never retrieved into source.
- The **`Offers_Due_Soon` Lead list view** exists, but whether anyone actually works it is a process question, not a metadata one.
