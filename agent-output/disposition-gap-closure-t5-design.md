# Disposition BA Gap Closure — Tranche 5 (FINAL), Design

**Date:** 2026-09-02
**Author:** salesforce-design subagent (analysis + design only — no metadata, no Apex, no org change)
**Scope input:** the Tranche 5 + Tranche 6 residue named in the request (items A–H)
**Standing constraint, unchanged since day one:** *"you can skip integrations and notifications part."*
**Output contract:** this file only. `agent-output/design-requirements.md` was NOT touched (a concurrent
session owns it — it is `M` in the working tree right now).

---

## 0. HEAD, and why a manifest cannot be derived from it

🔴 **I could not run `git`. The Bash tool is disabled for this session, in this agent and in subagents.**
Everything below about repository state comes from the session-start `gitStatus` snapshot plus direct
file reads. Both are point-in-time.

| | |
|---|---|
| **Branch** | `qa/lifecycle-simulation-2026-08-27` |
| **HEAD at session start** | **`5e14e2f`** — *"Acquisitions gap-fix: stage-entry dates, stalled-deal reminder, CFO status, broker counters, Dead/Pass gates"* |
| Four commits behind it | `e6d7cef`, `a8a1bb2`, `261ad1a`, `d867ac8` — **all acquisition / broker-protection / checklist work** |

🔴 **None of the four Tranche-4 commit hashes named in the request (`de60c37`, `2997bed`, `d5d8d81`)
is anywhere in the last five commits.** HEAD is an **acquisitions** commit. The working tree carries
a live, uncommitted acquisitions change set — `BrokerProtectionConfig.cls`,
`LLMExtractionCalloutService.cls`, three `*DefProvider` classes, three dashboards, six tabs, nine seed
scripts, `ARCHITECTURE.md`, and `.claude/skills/sf-apex/SKILL.md` — plus:

- 🔴 **an uncommitted DELETION**: `force-app/main/default/objects/Opportunity/recordTypes/Commercial.recordType-meta.xml` (`D`);
- 🔴 an uncommitted **modification of two permission sets** this tranche also touches conceptually:
  `DPEG_Transaction_Edit`, `DPEG_Transaction_View` (not disposition sets — but the same hub-file class of hazard);
- `agent-output/design-requirements.md` (`M`) — the file the request told me not to write to, confirming why.

⇒ **The parallel-build hub-file protocol applies to this tranche in full.** Whoever assembles the
deploy payload must re-read `git status` at that moment, and **diff every shared file against the ORG,
not against HEAD**, before deploying. Nothing in this document is a manifest.

---

## 1. THE SCOPING QUESTION, ANSWERED FIRST AND PLAINLY

> *"Work out what is genuinely left once notifications and integrations are removed — and say so
> plainly, even if the honest answer is 'much less than the tranche list implies.'"*

**The honest answer is: much less than the list implies, and the residue is smaller and better than it
looks — but not for the reasons the candidate list gives.**

Of the eight candidates:

| | Candidate | Verdict |
|---|---|---|
| **A** | Broker clock Week 1 → Week 2 | ✅ **IN** — but its stated justification is **wrong** (see P-1) |
| **B** | Detection jobs (30, 32, 40) | 🟡 **TWO of three are OUT** (pure notification). The third has a real non-notification consumer but needs its own decision (G-3) |
| **C** | Offer comparison terms | ✅ **IN** — and it is **free of permission work**, which the brief did not know (P-4) |
| **D** | Selected offer visually distinguished | ❌ **OUT — NOT A GAP.** Refused in writing on 2026-08-24, and already satisfied at the stage that matters (P-5) |
| **E** | Closing statement upload | 🟡 **IN, IN A SHAPE THAT CREATES ZERO FILES** — needs one decision (G-4) |
| **F** | PSA status ordering + `PSA_Executed__c` as a Date | ❌ **OUT — BOTH HALVES REST ON FALSE PREMISES.** Route to the BA (P-6, P-7) |
| **G** | Conversion 6 (`Status__c = 'Disposed'`) | ✅ **IN, AND IT IS THE BEST ITEM IN THE TRANCHE** — six report filters are already built and inert, waiting for one writer (P-8) |
| **H** | CoStar / Argus deep links | 🟡 **CoStar half IN and nearly free; Argus half is NOT BUILDABLE** (P-10) |

**Recommended Tranche 5 = four build items + one conditional.** Everything else is a BA conversation
or a notification.

The single most useful sentence in this document: **item G is not "add a status write". Six of the
seven `Property_Asset__c` reports on the Disposition Dashboard ALREADY carry
`Status__c equals Active` as a filter. They have been shipped, filtered and correct for weeks, and
they have never once excluded anything, because nothing in the application has ever written
`Disposed`.** One writer turns six existing filters from decoration into behaviour.

---

## 2. PREMISE CORRECTIONS — read these before anything else

The four prior design passes falsified 6, 14, 18 and 4 premises. This pass falsifies **ten**. Four of
them change what should be built; two remove an item from scope entirely.

### P-1. 🔴 The Week 2 change does **NOT** touch the `Broker Alert Due` KPI. The brief says it does.

> Request: *"It changes the badge and the `Broker Alert Due` KPI."*

`reports/Dispositions/Broker_Alert_Due.report-meta.xml` filters on
**`Disposition__c.Next_Broker_Checkin__c equals NEXT_N_DAYS:7`**.

`objects/Disposition__c/fields/Next_Broker_Checkin__c.field-meta.xml` is **nine lines long and is a
bare `<type>Date</type>`** — no formula, no default. A repo-wide grep for writers returns **two seed
scripts and nothing else**: `scripts/seed-dispositions.apex:66` and
`scripts/seed-disposition-bulk.apex:183,188`. **No Apex, no flow, no trigger, no process writes it.**

⇒ The `Broker Alert Due` KPI is driven by a **hand-typed date that nothing maintains**, and it is
completely decoupled from `DispositionTractionService`'s rungs. Changing `WEEK_1_DAYS` from 7 to 14
changes **the badge, the rung panel and the detail sentence, and nothing else in the org.**

⚠ This is not a reason to drop item A — it is a reason to **stop justifying it with the KPI**, and it
is the origin of the one genuinely non-notification detection job (G-3 below).

### P-2. ⚠ The `7` in `brokerListing.js` is NOT the week-1 rung and must not be changed with it.

`lwc/brokerListing/brokerListing.js:143` — `const DUE_SOON_DAYS = 7;` — with a header at :133-141
stating in terms that it is **`CallForOffersService.APPROACHING_DAYS`**, the acquisition module's
call-for-offers amber threshold, and that its equality with `WEEK_1_DAYS` is *"a COINCIDENCE OF VALUE,
not a derivation: do not 'unify' the two."* Changing it would silently re-time an **acquisition**
concept from a disposition decision.

### P-3. ⚠ The rung is not one constant — it is a constant, an ENUM VALUE, two label strings and ~25 assertions.

`DispositionTractionService` carries `Band.WEEK_1` (an enum member whose `.name()` crosses the
`@AuraEnabled` boundary as `Traction.band` and `Rung.key`), the label literal `'Week 1'` at :476, the
badge string `'Week 1 — Check-in due'` at :434, and the sentence `'One week on the market…'` at :435
plus `'The week-1 check-in is due in N days'` at :445-446.

✅ **Good news, measured:** no production LWC branches on the literal `'WEEK_1'`. `listingAlerts.js`
uses `r.key` only as a `for:each` key; `brokerListing.js` colours off the boolean `isAtRisk`. The
blast radius is the enum, the strings, `DispositionTractionServiceTest` (~18 assertion sites),
`BrokerListingControllerTest` (:74, :98, :111-114) and `listingAlerts.test.js` fixtures (~12 sites).

### P-4. ✅ Item C needs **ZERO** permission-set work. All three fields are already granted, in both sets.

| Field | `DPEG_Disposition_View` | `DPEG_Disposition_Edit` |
|---|---|---|
| `Disposition_Offer__c.Earnest_Money_Proposed__c` | :991 ✅ | :1720 ✅ |
| `Disposition_Offer__c.Due_Diligence_Days__c` | :986 ✅ | :1715 ✅ |
| `Disposition_Offer__c.Closing_Period_Days__c` | :966 ✅ | :1695 ✅ |

And all three are **already on `Disposition_Offer__c.Offer_Selection_Approval`'s `approvalPageFields`**
(:99-101). ⇒ **The approver can already see the terms; the person CHOOSING cannot.** That inversion is
the real defect and is worth putting to the BA in exactly those words.

⇒ Item C is a **pure LWC change to one bundle**. No permission set, no FlexiPage, no Apex, no field.

### P-5. 🔴 Item D is not "unconfirmed" — it was **decided, in writing, and refused**, and it is already satisfied where it matters.

`lwc/dispositionOffer/dispositionOffer.js:170-214`:

- `Is_Selected__c` **is already requested in every mode** (:190), with a 🔴 note that dropping it
  makes selected-only mode "go blind, not loud", pinned by a `getLastConfig()` assertion.
- :210-214, verbatim: *"🔴 **NOT RENDERED** — this is the FILTER KEY for `selected-only` mode.
  Deliberately not shown as a column: in that mode every visible row is selected by definition, so a
  marker would be a constant; and in the default mode a per-row tick would compete with the Select
  Offer quick action for the same meaning."*

And `lwc/dispositionSidebar` sets `selected-only` at **Offer Selection AND Closing** (its Jest
`NARROWING` test at :343 pins the exact set), where the card retitles itself **"Selected Offer"**
(`cardTitle`, :331) and renders that offer alone. ⇒ At the two stages where "which offer won" is the
question, the selected offer is not merely marked — **it is the only thing on the card.**

The one window where the story's AC is literally unmet is **Active Listing / Release Materials**,
where no offer is selected yet, and **LOI**, where one is. That is a one-stage cosmetic residual
against an explicit written refusal. ⇒ **OUT.** Report it; do not build it.

### P-6. 🔴 Item F's picklist premise names a sequence **the user personally retired eleven days ago**.

The gap analysis says the field has seven values *"where the story names four"* — Initial Draft,
Revised, Ready for Execution, Executed. That was true **until 2026-08-21**, when the user changed
`Disposition_PSA` **directly in Setup**. Measured from
`objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml:255-269`:

```
Disposition_PSA runs EXACTLY THREE values:  Initial Draft (default) -> Negotiation -> Signed
```

`Revised`, `Ready for Execution` and **`Executed`** are all **removed from the disposition record
type**. The terminal is `Signed`. `Acquisition_PSA` runs Draft → Negotiation → Signed → Executed.

⇒ The story's four values are not "four of the seven" — **not one of the four is the disposition
sequence today**, and `Executed` is not even reachable on a sell-side PSA. Building "enforce the
story's four-step order" would **reverse a decision the client made by hand in Setup on 2026-08-21**
and would break `RecordStageAdvanceService.CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE`, the two per-hop
quick actions `Move_to_Negotiation` / `Move_to_Signed`, and the `Contract_Review_Record_Page`
visibility rules that were corrected from `NE 'Executed'` to `NE 'Signed'` the same day.

⚠ **And "nothing enforces the order" is only half true.** The *hop* path is enforced:
`CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE` derives the target server-side, and the FlexiPage renders
exactly one named next-stage button per current status. What is unenforced is a **direct field edit**
— a validation rule would close that, and that is a one-line ask if the BA wants it. It is not what
the story describes.

### P-7. 🔴 Item F's second half — `PSA_Executed__c` Checkbox → Date — is an in-place type change with a compile break, a naming-convention violation, and a field that already exists.

- `DispositionController.cls:182` — `row.psaExecuted = d.PSA_Executed__c;` assigns into a **Boolean**
  DTO member. **Compile break**, and it cascades to `lwc/dispositionClosing`'s `psaLabel`,
  `iconColor` and its Jest fixtures (`psaExecuted: true/false`).
- `TestDataFactory.cls:3272` assigns `false`. `DispositionSelectorTest.cls:93` asserts `false`.
  `scripts/seed-disposition-bulk.apex:195,202` and `scripts/create-on-market-disposition.apex:37`
  assign booleans.
- `approvalProcesses/Disposition__c.Closing_Approval:145` and **both** path assistants
  (`Disposition_Path_On_Market:141`, `Disposition_Path_Off_Market:135`) name the field.
- 🔴 **`ARCHITECTURE.md §1 uses `PSA_Executed__c` as the canonical EXAMPLE of the Boolean naming
  convention.** A Date field must carry a `Date` suffix per the same table — so this is not a type
  change, it is a **rename**, i.e. delete + create, with the old API name reserved until manually
  ERASED in Setup.
- 🔴 **The date already exists.** `objects/Disposition__c/fields/Primary_PSA__c.field-meta.xml:28-33`
  argues this explicitly: *"`PSA_Executed__c` = what this disposition says"* versus the child's
  `Contract_Review__c.Execution_Date__c` = the date.

⇒ **OUT.** The FSD says "Date"; the org says Checkbox-plus-a-child-Date, and it was reasoned. Correct
the FSD.

### P-8. 🔴 Item G is **already half-built and inert.** Six of seven reports filter `Status__c = 'Active'` today.

The gap analysis says *"Nothing removes the property from the portfolio dashboards. Both sell-meter
queries filter … with **no `Status__c` filter**, so a sold asset keeps appearing on the Sell Meter and
in the readiness donuts."* **The first clause is true of the Apex; it is FALSE of the reports.**

| Report | `Status__c = 'Active'` filter? |
|---|---|
| `Readiness_Mix` (**donut — by count**) | ✅ :8-12 |
| `Readiness_Signal_By_Value_Avk` (**donut — by value**) | ✅ :12-16 |
| `Portfolio_Sell_Readiness` | ✅ :9-13 |
| `Properties_by_Argus_Value` | ✅ :9-13 |
| `Properties_in_AUM` | ✅ :8-12 (and groups on it) |
| `Total_Argus_Value` | ✅ :19-23 |
| `Sell_Ready_Argus` | ❌ filters on `Argus_Signal__c`; carries `Status__c` as a **column** only |

⇒ **Both donuts are already correct.** The genuine gaps are exactly three:
1. no writer of `'Disposed'`, anywhere;
2. `PropertyAssetSelector.selectAllForMeterSummary` (:65-72) and `.selectAllForPortfolio` (:87-96) —
   the two Sell Meter queries — carry `WHERE Property__c != null AND Peak_Sell_Date__c != null` and
   **no `Status__c` term**;
3. `Sell_Ready_Argus` alone lacks the filter.

✅ **And the picklist value already exists and is safe.**
`objects/Property_Asset__c/fields/Status__c.field-meta.xml` is a `restricted` picklist with exactly
`Active` (default) / `Disposed`. **`Property_Asset__c` has NO record types** (`recordTypes/` is
empty) — so the standing describe-guard-is-record-type-blind trap and the picklist-removal sweep rule
**do not fire here**. No picklist surgery at all.

✅ **And there is no FLS cost.** `Property_Asset__c.Status__c` is granted `readable=true /
editable=false` in **both** `DPEG_Disposition_View` (:1643-1647) and `DPEG_Disposition_Edit`
(:2501-2505). A `WITH USER_MODE` predicate on it is safe for both disposition personas — which
matters, because USER_MODE enforces FLS on WHERE-clause fields, not just SELECT.

### P-9. 🔴 Item G's write is a **cross-object, Private-OWD, non-owner write from inside an approval transaction** — the exact shape that has already failed silently on this project once.

- `objects/Property_Asset__c/Property_Asset__c.object-meta.xml:164` → **`<sharingModel>Private</sharingModel>`**.
- The stage that must trigger it, `Sale Closes`, is written by **`DispositionApprovalAdvanceService`**
  (`RT_ON_MARKET + '|Closing' => 'Sale Closes'`, :140-141) — i.e. **on final approval, running as the
  APPROVER**, a principal who almost certainly does not own the Property Asset.
- `SYSTEM_MODE` lifts CRUD/FLS and **never sharing** (ARCHITECTURE.md §2, and the repo has a live
  incident where exactly this write "worked only when approver == owner, which is what every test
  does").
- ⇒ The write needs a **narrow `private without sharing` inner class holding only that DML**, with
  its own justification at the declaration, and a test that runs as a **non-owner** under
  `System.runAs`.

✅ **The cascade is safe, verified.** Writing `Status__c` fires `PropertyAssetTrigger (after insert,
after update)`, whose two jobs are gated on **`Closing_Date__c` transitioning non-null**
(`OnboardingAutoCreateService`) and **`Target_Sale_Price__c` changing** (`BovAutoSelectionService`).
A `Status__c`-only update touches neither. The eight PM feature trees hanging off `Property_Asset__c`
are not disturbed by a status write — but that claim is worth one browser check, not just a grep.

✅ **`DispositionTrigger` already has the context needed:** `before insert, before update, after
insert, after update`. No trigger-context change (contrast the T1 finding on `BovSubmissionTrigger`).

### P-10. 🟡 Item H splits cleanly: CoStar is nearly free; **Argus is not buildable as written.**

- ✅ **`Property__c.CoStar_URL__c` EXISTS** and is **already granted read-only to both disposition
  personas** — `DPEG_Disposition_View:1701`, `DPEG_Disposition_Edit:2557-2561` (shipped by T1 item
  11). The gap analysis knew the field existed but treated it as acquisition-only.
- 🔴 **But the page cannot reach it in one hop.** `Disposition_Record_Page` renders spanning fields as
  `Record.Property_Asset__r.X` (:998, :1004, :1031, :1037). CoStar needs
  `Disposition → Property_Asset__r → Property__r → CoStar_URL__c` — **two hops**. A repo-wide grep for
  a two-hop `fieldItem` returns **zero matches**; Dynamic Forms supports one lookup level.
  ⇒ The mechanism is a **formula field on `Property_Asset__c`** mirroring `Property__r.CoStar_URL__c`,
  after which the page uses the one-hop form it already uses four times.
- ❌ **There is no Argus URL field anywhere in the org.** `Property_Asset__c` has exactly 17 fields;
  the Argus ones are `Argus_Value__c` (Currency) and `Argus_Signal__c` (Picklist). **No Argus link, no
  Argus model reference, on any object.** And "the Argus model" is a desktop Argus Enterprise
  artefact, not obviously a URL. ⇒ **The BA must say what the Argus link actually points at** before
  a field can be named, let alone typed.

---

## 3. RECOMMENDED TRANCHE 5 CONTENTS

### ✅ Item 1 — Conversion 6: write `Property_Asset__c.Status__c = 'Disposed'` at Sale Closes (story 49)

**Why first:** highest value per unit of risk in the whole residue. Six shipped report filters become
load-bearing; the Sell Meter stops offering an Initiate button on a building DPEG has already sold.

Four parts:
1. **The writer.** In `DispositionTriggerHandler` → a service method, on `after update`, keyed on
   `Disposition_Stage__c` transitioning **into** `'Sale Closes'` (transition, not equality — a re-save
   must be a no-op). Reads the parent asset id off `Property_Asset__c`; writes only `Status__c`.
   - 🔴 DML in a **narrow `private without sharing` inner class** (P-9), justified at its declaration.
   - Idempotent: skip rows already `'Disposed'`.
   - Bulk-safe; 251-record bulk test per `.claude/rules/bulk-test-rule.md` (no content objects here,
     so the ContentPublication carve-out does not apply).
2. **`PropertyAssetSelector.selectAllForMeterSummary` and `.selectAllForPortfolio`** — add
   `AND Status__c != 'Disposed'` to both, in the **same edit**, and update the shared class-header
   paragraph at :37-44 that documents the *"both queries share the SAME predicate"* invariant. If only
   one moves, the summary tiles and the table disagree — which is precisely the defect that header
   exists to prevent.
   - ⚠ **Use `!= 'Disposed'`, not `= 'Active'`.** The field is not required and a null status must
     stay on the meter, not silently vanish.
3. **`reports/Dispositions/Sell_Ready_Argus`** — add the same `Status__c equals Active` criterion the
   other six already carry, **or** deliberately leave it out. Recommend adding, for consistency, and
   note it is the report A3 has left partially open.
4. ⚠ **Do NOT touch the six reports that already have the filter.** They are correct.

**Not in scope here:** removing the sold asset from PM surfaces; anything that writes
`Closing_Date__c`; anything on `Property__c`.

### ✅ Item 2 — Broker clock: Week 1 → Week 2 (story 30, decision A2)

`DispositionTractionService`: `WEEK_1_DAYS` 7 → **14**; `Band.WEEK_1` → `Band.WEEK_2`; `'Week 1'` →
`'Week 2'`; `'Week 1 — Check-in due'` → `'Week 2 — Check-in due'`; `'One week on the market…'` →
`'Two weeks on the market…'`; `'The week-1 check-in is due in N days'` → `'week-2'`.

🔴 **The header block is the deliverable, not the constant.** §1 of the class header is a
retract-in-place record of the 2026-08-21 decision, and it states *"a third revision is the point at
which to revisit"* and *"a future revision cannot claim one threshold is 'the derived one'"*. This is
the **FOURTH** revision. It must be recorded in the same style: the 2026-08-21 text quoted verbatim
and marked RETRACTED, the new decision dated **2026-09-02**, and an explicit note that
`DPEG-Stage-by-Stage.docx` is now **two revisions** out of date.

⚠ **Do not touch `DUE_SOON_DAYS` in `brokerListing.js`** (P-2).
⚠ **Do not touch `WEEK_4_DAYS` (28) or `WEEK_6_DAYS` (42)** — only the first rung was disputed.
⚠ The `MARKETING_PERIOD_DAYS = WEEK_6_DAYS` identity is unaffected.

Test blast radius to repair, not to argue with: `DispositionTractionServiceTest` (~18 sites,
including the `Band => 'On Track'` map at :547-555), `BrokerListingControllerTest` (:74, :98,
:111-114), `listingAlerts.test.js` (~12 fixture/assertion sites), `brokerListing.test.js:23` comment.

### ✅ Item 3 — Offer comparison shows the terms (story 35, residual of decision D4)

`lwc/dispositionOfferSelect` only. Add to `FIELDS` and to the table:

- `Disposition_Offer__c.Earnest_Money_Proposed__c` → column **"Earnest Money"**
- `Disposition_Offer__c.Due_Diligence_Days__c` → column **"DD Days"**
- `Disposition_Offer__c.Closing_Period_Days__c` → column **"Closing Days"**

🔴 **`Offer_Financing_Type__c` stays out** (decision D4, 2026-08-21 UAT). The bundle's header at
:42-47 records that removal and that the field is *"no longer requested, which also drops an FLS gate
this quick action no longer needs"* — do not re-add it as a fifth column.

⚠ **Format in JS, not with `lightning-formatted-number`.** The bundle's `<caption>` comment at :53-57
explains why: the exact figure must be a **text node this bundle's own Jest suite can read**, after a
live defect where `$1,850,000` and `$1,860,000` both rendered `$1.9M` on the screen that chooses
between them. Earnest Money is Currency and carries exactly that risk. Use `formatExactCurrency` from
`c/utils`, as `amount` already does.

⚠ **`aria-label` is a uniqueness contract, not decoration** (:159-191). Adding columns does not change
it — but the three new cells must not be appended to it either, or the announced string becomes
unreadable. Leave `ariaLabel` byte-identical and add only `<th>`/`<td>` pairs.

⚠ A `null` in any of the three must render an em dash, never `undefined` (repo-wide rule; the bundle
already pins *"never renders the literal string undefined"*).

⚠ **Eight columns in a screen quick action is a width question.** The table is hand-rolled with
per-column classes (`.qa-col-*`); the CSS needs a pass and the result is a **browser check**.

### 🟡 Item 4 (CONDITIONAL on G-4) — Closing statement derived from an attached file (story 48)

**The shape that creates ZERO ContentPublications:** do not build an uploader. Build a **reader**.

1. **Admin:** add the Files related list to `layouts/Disposition__c-Disposition Layout`. 🔴 Measured:
   that layout's `<relatedLists>` today are **only** `RelatedProcessHistoryList`,
   `RelatedActivityList`, `RelatedHistoryList` (:149-175). **There is nowhere on the Disposition
   record page to attach a file at all.** The page already carries `force:relatedListContainer`
   (:923), which is layout-driven, so one layout entry surfaces it.
2. **Developer:** in `DispositionController.getClosingSummary`, derive
   `row.closingStatementUploaded` from the presence of a linked document rather than from the
   checkbox — reusing the **existing** `ContentDocumentLinkSelector.selectByLinkedEntityId` (:44-52,
   `WITH USER_MODE`, deliberately, so a user only sees documents shared with them).
   ✅ **The precedent is in the same method, one line below:** `row.wireCreated = !d.Wires__r.isEmpty();`
   already derives one of the four closing states from child presence rather than a flag.
3. 🔴 **Reads create no `ContentPublication`.** `.claude/rules/content-publication-rule.md` binds
   file-CREATING paths; this creates none. The tests read at most **20** rows per the selector-read
   ceiling in that rule, and must carry the standing `BULK VOLUME IS 20, NOT 251 — DELIBERATE` header
   block used by `ContentVersionSelectorTest` / `ContentNoteSelectorTest`.
4. 🔴 **And there is a second reason not to build an uploader.**
   `ContentPublicationBudget` (a hierarchy Custom Setting backstop, L4/L5 of the attachment design)
   counts publications **only for paths that route through `AttachmentPersistQueueable`**. A
   `lightning-file-upload` component publishes through the **platform**, which that counter cannot
   see — so every closing statement uploaded would widen a structural undercount the class header
   already calls out, on an org-wide, non-refundable, uncatchable quota.

🔴 **The decision this needs (G-4): does the checkbox stay?** Two honest options and they are not
equivalent — see §7.

### ⚠ Item 5 (CoStar half of story 63 — recommend IN; Argus half OUT)

1. **Admin:** new **formula** field on `Property_Asset__c` — `CoStar_URL__c`, Text formula
   `Property__r.CoStar_URL__c`, treat blanks as blanks. (Name is convention-clean: `_URL__c` suffix,
   does not collide with the relationship-naming rule.)
2. **Admin:** grant it read-only on `DPEG_Disposition_View` and `DPEG_Disposition_Edit`. 🔴 A
   Metadata-API-deployed field arrives with **no FLS for anyone, System Administrator included**.
3. **Admin:** add `Record.Property_Asset__r.CoStar_URL__c` to a `flexipage:fieldSection` on
   `Disposition_Record_Page`, alongside the four spanning fields already there.
4. ❌ **No Argus field.** G-6.

⚠ 🔴 **Any `Disposition_Record_Page` edit is the highest-risk single act in this tranche** — a
FlexiPage deploy **replaces** the org copy, there is no version history, and this project lost two
hand-made tabs to exactly that on 2026-08-25. **Retrieve and diff the page seconds before deploying,
and read `SetupAuditTrail` for saves newer than the last retrieve.**

---

## 4. CONFIRMED **OUT** — with reasons, so nobody re-scopes them

| Item | Why out |
|---|---|
| **Call-for-Offers reminder ladder (story 32)** | `CallForOffersAlertBatch`'s entire product is `Messaging.CustomNotification.send()` — its class header is 200 lines of send-cost measurement. It is Opportunity-scoped and keyed on `Opportunity.Offer_Due_Date__c`. A disposition twin would have **no** non-notification consequence: `Broker_Listing__c.Call_For_Offers_Date__c` is already rendered by `dispositionCallForOffers`. **Pure notification.** |
| **Off-market one-week follow-up timer (story 40)** | The anchor already exists and is already automated — `DispositionStageEntryService` default-stamps `NDA__c.Materials_Released_Date__c` on every buyer NDA at Release Materials entry (T2/D6.1, idempotent). A timer on top of it produces **only a message**. **Pure notification.** |
| **Selected offer visually distinguished (D / story 37)** | Refused in writing 2026-08-24; already satisfied at Offer Selection and Closing by the "Selected Offer" mode. **Not a gap** (P-5). |
| **PSA status ordering (F / story 42)** | The story's four values are not the disposition sequence and one of them is unreachable on the record type. Reversing it would undo a 2026-08-21 Setup change the client made by hand (P-6). **BA conversation.** |
| **`PSA_Executed__c` Checkbox → Date (F)** | Compile break + delete-and-recreate rename + violates `ARCHITECTURE.md §1`'s own worked example, and the date already exists on `Contract_Review__c.Execution_Date__c` (P-7). **Correct the FSD.** |
| **Argus deep link (H)** | No field, no defined target, no precedent. Needs the BA to say what it points at (G-6). |
| **The Conversion 5 freeze (13/66)** | **A1: NO FREEZE.** Not revisited. |
| **`BOV_Score__c` re-ranking / DISP-0041 divergence** | User decision 2026-09-02: **LEAVE IT.** No backfill, no `reselect`. ⚠ And the deeper finding stands — Value is saturated and Speed is floored on realistic data, so 80 of 100 points are constant. **That is a scoring-model question for the BA, not a tranche item.** |
| **Broker sale history (story 21)** | Deferred entirely at T4 Gate 1. Unchanged. ⚠ And note the working tree currently holds an **uncommitted deletion of `Opportunity/recordTypes/Commercial.recordType-meta.xml`** — a live change on the object that item would have queried. |
| **Anything integration- or notification-shaped** | Standing instruction. |

---

## 5. THE ADMIN / SOLUTION-ARCHITECT / DEVELOPER SPLIT

### 🔵 `salesforce-admin`

| # | Artefact | Change |
|---|---|---|
| 1 | `reports/Dispositions/Sell_Ready_Argus.report-meta.xml` | Add `Property_Asset__c.Status__c equals Active` criterion (item 1, part 3) |
| 2 | `layouts/Disposition__c-Disposition Layout.layout-meta.xml` | Add the Files related list — **CONDITIONAL on G-4**. 🔴 Keep all three existing `<relatedLists>` blocks; a layout deploy replaces the whole set |
| 3 | `objects/Property_Asset__c/fields/CoStar_URL__c.field-meta.xml` | **NEW** Text formula = `Property__r.CoStar_URL__c` (item 5) |
| 4 | `permissionsets/DPEG_Disposition_View`, `DPEG_Disposition_Edit` | Add `Property_Asset__c.CoStar_URL__c` read-only. 🔴 **A PermissionSet deploy REPLACES its collections** — the file must be edited in place and re-verified for `fieldPermissions` **+ `objectPermissions` + `SetupEntityAccess`** |

### 🟤 `salesforce-solution-architect`

**Nothing.** No multi-object schema, no security-model design, no subflow orchestration, no ERD. The
one cross-module change (item 1) is a single field write on an existing object with an existing
value, and its authorisation question is already answered by shipped grants (P-8).

### 🟢 `salesforce-developer`

| # | Artefact | Change |
|---|---|---|
| 5 | `DispositionTriggerHandler` + a service | Conversion 6 writer, `after update`, transition-keyed, narrow `private without sharing` DML (item 1, part 1) |
| 6 | `PropertyAssetSelector.cls` | `AND Status__c != 'Disposed'` on **both** meter queries + header invariant paragraph (item 1, part 2) |
| 7 | `DispositionTractionService.cls` | Week 2 rung: constant, enum member, 4 strings, header retraction block (item 2) |
| 8 | `lwc/dispositionOfferSelect` (js + html + css + `__tests__`) | Three term columns (item 3) |
| 9 | `DispositionController.getClosingSummary` (+ `ContentDocumentLinkSelector` reuse) | Derive `closingStatementUploaded` — **CONDITIONAL on G-4** (item 4) |
| 10 | Tests | `DispositionTractionServiceTest`, `BrokerListingControllerTest`, `PropertyAssetSelectorTest`, new writer test (251-row bulk + **non-owner `System.runAs`**), `listingAlerts.test.js`, `brokerListing.test.js`, `dispositionOfferSelect.test.js`, `dispositionClosing.test.js` |

⚫ `salesforce-technical-architect`: **not needed.** No ASB/Plaid/Yardi, no Named Credentials, no LDV,
no platform events.

🔴 **`DPEG_Apex_Access`:** no new `@AuraEnabled` class is proposed. `DispositionController`,
`SellMeterController`, `BrokerListingController` and `DispositionTractionController` all already carry
`classAccesses` entries (:265, :532, :55, :316). **If any implementing agent adds a new controller,
it needs an entry** — T3 shipped one without and the component was dead for every non-admin on a
green deploy.

---

## 6. DEPLOY ORDER

🔴 **`usman-dpeg` is PRODUCTION. Every class in a payload must individually clear 75%.**

**Wave 0 — pre-flight (no deploy).**
Re-read `git status`. Retrieve and diff against the **ORG**: `Disposition_Record_Page.flexipage`,
`Disposition__c-Disposition Layout.layout`, `DPEG_Disposition_View`, `DPEG_Disposition_Edit`,
`Sell_Ready_Argus.report`. The concurrent stream is live in this tree.

**Wave 1 — item 5 (CoStar), declarative-only, lowest risk.**
`Property_Asset__c.CoStar_URL__c` formula → both permission sets → the FlexiPage `fieldItem`.
🔴 Field **before** grant, grant **before** page. A page that names an ungranted field renders blank
for the persona and green for the admin.
Discharge: readback of the field, readback of both grants, **browser check on DISP-0041**.

**Wave 2 — item 3 (offer terms), LWC-only, zero server surface.**
Jest + SLDS linter + `@sa11y/jest` locally; then deploy the bundle alone.
Discharge: Jest proves the columns and the exact-currency strings; **the browser proves eight columns
fit a screen quick action.**

**Wave 3 — item 2 (Week 2 rung), Apex + tests, no metadata.**
Deploy `DispositionTractionService` + `DispositionTractionServiceTest` +
`BrokerListingControllerTest` + the two Jest bundles **in one payload**. The `--tests` flag runs the
ORG's copy — **include the test classes in the payload** or a targeted run can silently execute fewer
methods than the repo has and still report 100%.

**Wave 4 — item 1 (Conversion 6), the only behavioural change.**
Order inside the wave: `Sell_Ready_Argus.report` → `PropertyAssetSelector` + its test → the writer +
its test. Report first because it is inert until a writer exists; selector before writer for the same
reason.
🔴 **This wave changes what the Sell Meter shows and what the Initiate button offers.** It should not
ship in the same payload as anything else.

**Wave 5 — item 4 (closing statement), only if G-4 answers "derive".**
Layout → controller + selector reuse → `dispositionClosing` Jest.

---

## 7. WHAT A DEPLOY CAN DISCHARGE vs WHAT NEEDS DATA OR A BROWSER

Org state as given: **4 Property Assets** (GREEN 2 / YELLOW 1 / RED 1), **2 Dispositions**
(DISP-0041 On_Market, DISP-0042 Off_Market, **both at `Disposition Readiness`**), **4 BOV
submissions** on DISP-0041, **0 Broker Listings**, 8 broker Contacts,
`Opportunity` New=2 / ClosedWon=4 / Dead-Pass=1.

| Item | Deploy + readback discharges | Seeded data discharges | Still needs a browser / more data |
|---|---|---|---|
| **1 — Conversion 6** | the trigger context, the selector predicate, the report criterion; the 251-row bulk test; the non-owner `runAs` test | ⚠ **almost nothing.** Both dispositions are at `Disposition Readiness` — **six stages short of `Sale Closes`** | 🔴 **The whole behaviour.** Needs a disposition walked to Closing with a verified Wire and `Closing_Approval` approved — and walked **by a real principal who does not own the Property Asset**, or P-9 is untested. 🔴 And then: the asset **leaves** the Sell Meter (4 → 3 rows), the band tiles re-count, and six report filters finally bite. That is a **before/after screenshot pair**, not a deploy result |
| **2 — Week 2 rung** | ✅ everything the Apex and Jest can say: the constant, the enum, every string, every boundary | ❌ **nothing.** **0 Broker Listings** and no disposition past Readiness, so `Listing_Date__c` is null everywhere ⇒ every live record is `NOT_LISTED` and **no rung can render at all** | 🔴 The badge, the rung panel and the detail sentence. Needs one disposition at Active Listing with a `Listing_Date__c` 14–27 days old and zero offers. **Today this item is invisible in the org in every state.** |
| **3 — offer terms** | ✅ the field list, the three cells, the em-dash nulls, the exact-currency formatting, the unchanged `aria-label`, sa11y on the caption + `<th scope="col">` | ⚠ partly — the quick action opens on DISP-0041, but a disposition at `Disposition Readiness` has no offers and the screen renders its **"No offers have been logged"** branch | 🔴 **Column widths at eight columns.** Needs ≥2 offers on one disposition with all three terms populated. This is the item most likely to look wrong rather than be wrong |
| **4 — closing statement** | ✅ the layout entry, the selector reuse, the derivation, the ≤20-row tests | ⚠ the Files related list renders on any Disposition immediately | 🔴 That attaching a real file flips the panel tile from "Not uploaded" to "Uploaded" — and that **detaching it flips back**, which is the whole difference from a latching checkbox |
| **5 — CoStar link** | ✅ the formula compiles and deploys; both grants read back | 🔴 **the formula resolves only if DISP-0041's Property Asset has a `Property__c` AND that Property has a non-blank `CoStar_URL__c`.** Neither is stated in the seed summary — **check before building**, or the item ships and renders blank on every record | 🔴 That the link renders as a clickable hyperlink and not as raw text (a Text formula renders as text unless the formula is `HYPERLINK(...)` or the field is typed as a URL formula — **decide this at G-5**) |

🔴 **The blunt summary: of five items, exactly ONE (item 3) can be substantially seen in this org
today, and even that one needs two offers logged first.** Items 1 and 2 are invisible in every state
the org can currently reach.

⇒ **Recommendation: seed before Waves 3 and 4.** The minimum fixture is one disposition walked from
`Disposition Readiness` to `Sale Closes` on a Property Asset that is on the Sell Meter, with a broker
listing dated ~20 days back and no offers at the point where the rung is checked, and ≥2 offers
carrying all three comparison terms by the time it reaches Offer Selection. `scripts/seed-disposition.apex`
and the demo-seed runbook already build most of that chain.

⚠ **And one measurement that costs nothing and would change item 5:** query
`SELECT Id, Property__c, Property__r.CoStar_URL__c FROM Property_Asset__c` before designing the
formula. If `CoStar_URL__c` is blank on all four assets, item 5 ships a field nobody can see working.

---

## 8. PER-ITEM RISK REGISTER

| # | Item | Risk | Dominant hazards |
|---|---|---|---|
| 1 | **Conversion 6 writer + selectors + 1 report** | 🔴 **MED-HIGH** | 🔴 **P-9: a Private-OWD parent write from inside an approval transaction, running as a non-owner approver.** `SYSTEM_MODE` does not fix it; only a narrow `without sharing` inner class does, and `allOrNone=false` anywhere on the path would swallow the failure exactly as it did in the live incident this repo has already paid for. 🔴 **It is a cross-module write** — `Property_Asset__c` carries eight PM feature trees. ⚠ **It changes what the Home page shows**: a sold asset leaves the Sell Meter, the four band tiles re-count, and Portfolio Upside moves. On a 4-asset portfolio that is a 25% change nobody may be expecting. ⚠ **The predicate must be `!= 'Disposed'`, not `= 'Active'`** — the field is not required. ✅ Mitigated four ways: the picklist value **already exists** and the object has **no record types**; FLS is **already granted read-only in both sets**; the `PropertyAssetTrigger` cascade is **provably gated** on two other fields; and **six of seven reports are already filtered**, so the reporting half needs no design at all |
| 2 | **Week 2 rung** | 🟡 **LOW-MED** | ⚠ **It is the FOURTH revision of a number the class header demands be recorded as a decision, never re-derived.** The retraction block is the actual deliverable; a bare constant change is the failure mode. ⚠ **P-2: the `7` in `brokerListing.js` is an ACQUISITION constant** and changing it would silently re-time a different module. ⚠ **P-3: it is an enum rename, not a constant edit** — ~25 assertion sites. ⚠ `DPEG-Stage-by-Stage.docx` will then be **two** revisions stale. ✅ Mitigated: no LWC branches on the band literal; `WEEK_4`/`WEEK_6` untouched; **P-1 removes the KPI from the blast radius entirely** |
| 3 | **Offer comparison terms** | 🟢 **LOW** | ⚠ **Eight columns in a screen quick action is a layout risk, and Jest cannot see width.** ⚠ Currency must be formatted **in JS as a text node** or the bundle's own exact-amount contract goes vacuous — the `$1.9M` collision defect is documented on this exact screen. ⚠ `ariaLabel` must stay byte-identical. 🔴 `Offer_Financing_Type__c` must **not** return (D4). ✅ Mitigated: **zero permissions, zero Apex, zero FlexiPage, zero fields** — all three fields already granted in both sets (P-4), and the hand-rolled `<table>` means every new cell is genuinely assertable |
| 4 | **Closing statement (conditional)** | 🟡 **MED** | 🔴 **It changes the meaning of a shipped field**: a checkbox someone ticked once becomes a derived state that can go **backwards** when a file is deleted. That is more honest and it is a behaviour change. ⚠ `ContentDocumentLinkSelector` is `WITH USER_MODE` **by intent** — so two users can legitimately see different closing-readiness states on the same record. That is correct and must be stated, not fixed. ⚠ The layout deploy **replaces** the `<relatedLists>` set. ✅ Mitigated: **creates zero `ContentPublication`s**; reuses an existing selector; the sibling `wireCreated` line is an exact in-method precedent; test volume capped at 20 per the content rule |
| 5 | **CoStar deep link** | 🟡 **MED** | 🔴 **The `Disposition_Record_Page` deploy is the single highest-risk act in the tranche** — it replaces the org copy, has no version history, and this project lost user work to it on 2026-08-25. Retrieve-and-diff seconds before, plus `SetupAuditTrail`. ⚠ **A new field arrives with NO FLS for anyone**, admin included. ⚠ **It may render blank on every record** if the seeded assets have no `Property__c` or no CoStar URL — measure first. ⚠ Text-vs-URL formula decides whether it is clickable (G-5). ✅ Mitigated: the source field and its grant **already exist** (P-10); the one-hop spanning pattern is used four times on this page already |

---

## 9. 🚦 DECISIONS NEEDED AT GATE 1

**Blocking — the tranche cannot be scoped without these.**

| Ref | Question | Recommendation |
|---|---|---|
| **G-1** | **Item 2 is now justified ONLY by the badge and the rung panel — the `Broker Alert Due` KPI is unaffected (P-1), and with 0 Broker Listings in the org the rungs are invisible in every state today. Do you still want Week 2, on its own?** | **Yes, ship it** — it is decision A2, it is cheap, and the alternative is a fifth dispute later. But it must ship **with the retraction block**, and its acceptance criterion is a browser check that cannot be performed until a listing exists |
| **G-2** | **Item 1 changes what the Sell Meter shows.** A disposed asset disappears from the table, the four band tiles re-count, and Portfolio Upside moves. On a 4-asset portfolio that is visible immediately. Confirm that is wanted | **Yes** — it is the whole point of story 49, and six report filters have been waiting for it |
| **G-3** | **The ONE detection job with a non-notification consequence.** `Disposition__c.Next_Broker_Checkin__c` is a hand-typed Date that **nothing** writes, and it is the sole input to the `Broker Alert Due` dashboard KPI (P-1). A daily job could maintain it — `DispositionTractionService.evaluateAll` is 2 SOQL for any number of dispositions and its header **explicitly designs this seam**. ⚠ But: (a) a `Schedulable` is **inert until someone runs `System.schedule` post-deploy** and fails silently with zero errors; (b) the offers clause and the clock **pause** cannot be expressed in a formula, so a formula alternative would flag listings that already have offers. **Build it, defer it, or drop it?** | **DEFER, and say so on the field.** It is real work with a real consumer, but it is a new job class with a post-deploy gate, in a tranche whose other items are all verifiable-in-principle. Recommend: **add an `inlineHelpText` to `Next_Broker_Checkin__c` saying it is hand-maintained**, so the KPI stops looking automated, and schedule the job as its own item |
| **G-4** | **Item 4's shape.** (a) **Derive** `closingStatementUploaded` from an attached file and leave `Closing_Statement_Uploaded__c` as an orphaned field; (b) **Derive, and retire the checkbox** (a rename/retire wave, with `DispositionSelector`, `TestDataFactory`, two seed scripts and `Closing_Approval`'s page fields to sweep); (c) **Keep the checkbox and add nothing**; (d) **Build an uploader** | **(a).** It closes the story's real complaint (no upload UI, no link to a document) at zero ContentPublication cost and with no field retirement. (d) is the only option that consumes the org-wide quota and is the one option I would argue against |
| **G-5** | **Item 5's field type.** A Text formula renders the CoStar URL as **plain text**; a `HYPERLINK()` formula renders it clickable but its label is fixed in the formula. Which? | **`HYPERLINK(Property__r.CoStar_URL__c, 'View in CoStar')`**, with a blank guard so an empty URL renders nothing rather than a dead link. The story's word is *"deep links"* |
| **G-6** | **Item 5's Argus half is not buildable.** There is no Argus URL field anywhere in the org, and "the Argus model" is a desktop Argus Enterprise artefact, not obviously a URL. **What does the Argus link point at?** | **Ask the BA.** Do not name a field for an unknown target |

**Non-blocking — decisions to record, not to build.**

| Ref | Item | Recommendation |
|---|---|---|
| **G-7** | **Story 42 (PSA ordering) is out (P-6).** The story names a sequence the client retired by hand in Setup on 2026-08-21. **Correct the story to `Initial Draft → Negotiation → Signed`.** Optionally: a validation rule closing direct field edits (the *hop* path is already enforced) | Correct the story. Offer the VR as a separate one-line item |
| **G-8** | **`PSA_Executed__c` stays a Checkbox (P-7).** The FSD's "Date" is already satisfied by `Contract_Review__c.Execution_Date__c` | Correct the FSD |
| **G-9** | **Story 37's "selected offer visually distinguished" is closed (P-5)** — refused in writing, and satisfied at Offer Selection and Closing by the "Selected Offer" mode | Amend the AC |
| **G-10** | **The gap analysis's story-49 line is wrong about the dashboards (P-8)** and its story-31 line still attributes Replace Broker to a Property Management component. Both should be corrected in the document | Correct both |
| **G-11** | ⚠ **`Disposition_Dashboard_Access` does NOT grant `Property_Asset__c.Status__c`**, yet six reports already filter on it. That is **pre-existing**, not caused by this tranche, but it means those six may already be failing for that persona | Verify in a browser **as that persona**, not as an admin |
| **G-12** | ⚠ **The DISP-0041 scoring divergence stands (user decision 2026-09-02: LEAVE IT).** The deeper finding — Value saturated, Speed floored, 80 of 100 points constant — is a **scoring-model question for the BA** | Raise it; do not fix it |

---

## 10. PROMPTS FOR THE SPECIALIST AGENTS

Only what is in §3 and §5. No extras. **Do not deploy.**

### 🔵 PROMPT FOR `salesforce-admin`

```
Per agent-output/disposition-gap-closure-t5-design.md §3 items 1/4/5 and §5's admin table.
Create metadata files only. DO NOT DEPLOY.

🔴 GATES FIRST. Write nothing until G-4 (closing-statement shape) and G-5 (CoStar formula type)
have answers. Item 2 below is CONDITIONAL on G-4 = (a). Item 3/4 are CONDITIONAL on G-5.

🔴 BEFORE ANY EDIT: re-read `git status`. A concurrent session is committing into this working
tree; HEAD at design time was 5e14e2f (an ACQUISITIONS commit) with an uncommitted acquisitions
change set including a DELETED Opportunity record type and two modified Transaction permission
sets. Diff every file you touch against the ORG, not against HEAD.

1. reports/Dispositions/Sell_Ready_Argus.report-meta.xml
   Add ONE criteriaItem: column Property_Asset__c.Status__c, operator equals, value Active.
   Copy the exact block shape from reports/Dispositions/Readiness_Mix.report-meta.xml lines 7-13
   (columnToColumn false, isUnlocked false).
   🔴 DO NOT TOUCH THE OTHER SIX Property_Asset__c REPORTS. Readiness_Mix,
   Readiness_Signal_By_Value_Avk, Portfolio_Sell_Readiness, Properties_by_Argus_Value,
   Properties_in_AUM and Total_Argus_Value ALREADY carry this filter and are correct.

2. layouts/Disposition__c-Disposition Layout.layout-meta.xml  [CONDITIONAL on G-4 = (a)]
   Add the Files related list.
   🔴 A LAYOUT DEPLOY REPLACES THE WHOLE <relatedLists> SET. The file currently holds exactly
   three: RelatedProcessHistoryList, RelatedActivityList, RelatedHistoryList. All three must
   survive verbatim. Losing RelatedProcessHistoryList makes Recall unreachable from the UI —
   this repo has already paid for that once.

3. objects/Property_Asset__c/fields/CoStar_URL__c.field-meta.xml  [NEW, CONDITIONAL on G-5]
   Formula field. Per G-5's answer, either:
     Text formula: Property__r.CoStar_URL__c
     or HYPERLINK formula with a blank guard so an empty URL renders nothing, not a dead link.
   Label "CoStar Link". formulaTreatBlanksAs BlankAsBlank.
   ⚠ CustomField <description> caps at 1000 chars (NOT 255 — that cap is ValidationRule /
   CustomPermission / LWC meta). Put long rationale in an XML COMMENT INSIDE the root element —
   a comment ABOVE <CustomField> breaks `sf` at source conversion.
   ⚠ Property__c.CoStar_URL__c already exists and is already granted read-only to both
   disposition personas. You are mirroring it one hop closer, not creating the data.

4. permissionsets/DPEG_Disposition_View + DPEG_Disposition_Edit  [CONDITIONAL on G-5]
   Add Property_Asset__c.CoStar_URL__c, readable=true editable=false (a formula field cannot be
   editable=true — that is a DEPLOY ERROR, not a preference).
   🔴 A PERMISSIONSET DEPLOY REPLACES ITS COLLECTIONS. Edit in place. Before handing off,
   re-verify fieldPermissions AND objectPermissions AND SetupEntityAccess are all intact.

DO NOT: touch Disposition_Dashboard_Access; touch any Contract_Review__c file; change
PSA_Executed__c; add any Argus field; add any picklist value anywhere.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Per agent-output/disposition-gap-closure-t5-design.md §3 items 1/2/3/4 and §5's developer table.
Create/modify source only. DO NOT DEPLOY.

🔴 GATES FIRST. G-1 (Week 2 confirmed), G-2 (Sell Meter visibly changes), G-4 (closing-statement
shape). Item 4 below is CONDITIONAL on G-4 = (a).

🔴 usman-dpeg IS PRODUCTION. Every class in a payload must individually clear 75%.
🔴 Re-read `git status` first — a concurrent session is committing into this tree.

── ITEM 1: Conversion 6 ────────────────────────────────────────────────────
1a. DispositionTriggerHandler + a service method (ARCHITECTURE.md §2 layering):
    on AFTER UPDATE, for each Disposition__c whose Disposition_Stage__c TRANSITIONED INTO
    'Sale Closes' (transition, not equality — a re-save must be a no-op), set the parent
    Property_Asset__c.Status__c = 'Disposed'. Skip rows already 'Disposed'.
    🔴 THE DML GOES IN A NARROW `private without sharing` INNER CLASS HOLDING ONLY THAT WRITE,
    justified at its declaration. Property_Asset__c is <sharingModel>Private</sharingModel>, the
    write runs as the Closing_Approval APPROVER (DispositionApprovalAdvanceService maps
    '<recordtype>|Closing' => 'Sale Closes'), and that approver is a principal who will not own
    the asset. SYSTEM_MODE lifts CRUD/FLS and NEVER sharing — this repo has a live incident where
    exactly this write succeeded only when approver == owner, which is what every test does.
    🔴 DO NOT use allOrNone=false anywhere on this path; it swallows the sharing failure silently.
    ⚠ DispositionTrigger already has before/after insert + before/after update. No context change.
    ⚠ Writing Status__c fires PropertyAssetTrigger (after insert/update) — verified safe: its two
    jobs are gated on Closing_Date__c transitioning non-null and on Target_Sale_Price__c changing.
    State that in the header so nobody re-derives it.

1b. PropertyAssetSelector.cls — add `AND Status__c != 'Disposed'` to BOTH
    selectAllForMeterSummary (~:65) and selectAllForPortfolio (~:87), IN THE SAME EDIT, and update
    the class-header paragraph at ~:37-44 that documents the shared-predicate invariant.
    🔴 `!= 'Disposed'`, NOT `= 'Active'`. Status__c is not required; a null must stay on the meter.
    ⚠ Both queries are WITH USER_MODE and USER_MODE enforces FLS on WHERE-clause fields.
    Property_Asset__c.Status__c is already granted readable/non-editable in DPEG_Disposition_View
    (:1643) and DPEG_Disposition_Edit (:2501). No permission work is needed — do not add any.

1c. Tests: 251-record bulk per .claude/rules/bulk-test-rule.md, plus a NON-OWNER test under
    System.runAs (an admin passes vacuously — Modify All Data bypasses the sharing question this
    item's whole risk is about), plus a negative: a re-save at 'Sale Closes' writes nothing.

── ITEM 2: Week 2 rung ─────────────────────────────────────────────────────
DispositionTractionService.cls:
  WEEK_1_DAYS 7 -> 14 (rename to WEEK_2_DAYS); Band.WEEK_1 -> Band.WEEK_2; rung label 'Week 1'
  -> 'Week 2' (:476); badge 'Week 1 — Check-in due' -> 'Week 2 — Check-in due' (:434); detail
  'One week on the market…' -> 'Two weeks…' (:435); 'The week-1 check-in is due in N days'
  -> 'week-2' (:445-446).
🔴 THE HEADER BLOCK IS THE DELIVERABLE. §1 of the class header records the 2026-08-21 decision in
retract-in-place style and says a further revision must be RECORDED, never re-derived. THIS IS THE
FOURTH REVISION. Quote the 2026-08-21 text verbatim, mark it RETRACTED, date the new decision
2026-09-02, and state that DPEG-Stage-by-Stage.docx is now TWO revisions stale.
🔴 DO NOT TOUCH WEEK_4_DAYS (28) OR WEEK_6_DAYS (42). Only the first rung was disputed.
🔴 DO NOT TOUCH `const DUE_SOON_DAYS = 7` in lwc/brokerListing/brokerListing.js:143. Its own
header (:133-141) states it is CallForOffersService.APPROACHING_DAYS — an ACQUISITION constant —
and that its equality with the week-1 rung is "a COINCIDENCE OF VALUE, not a derivation".
⚠ The Broker Alert Due KPI is NOT affected. It filters on Disposition__c.Next_Broker_Checkin__c,
a bare hand-typed Date with no writer. Do not touch that field or that report.
Repair, do not argue with: DispositionTractionServiceTest (~18 sites incl. the Band=>'On Track'
map at :547-555), BrokerListingControllerTest (:74,:98,:111-114), listingAlerts.test.js (~12
fixture sites), brokerListing.test.js:23 comment.

── ITEM 3: offer comparison terms ──────────────────────────────────────────
lwc/dispositionOfferSelect only (js + html + css + __tests__).
Add to FIELDS and as three columns: Earnest_Money_Proposed__c ("Earnest Money"),
Due_Diligence_Days__c ("DD Days"), Closing_Period_Days__c ("Closing Days").
🔴 Offer_Financing_Type__c STAYS OUT (decision D4, 2026-08-21 UAT). The bundle header at :42-47
records its removal. Do not re-add it.
⚠ Format Earnest Money in JS with formatExactCurrency from c/utils, exactly as `amount` does —
NOT lightning-formatted-number, NOT a datatable currency type. The <caption> comment at :53-57
explains why: the exact figure must be a text node this suite can read, after a live defect where
$1,850,000 and $1,860,000 both rendered $1.9M on this screen.
⚠ Leave `ariaLabel` BYTE-IDENTICAL. It is a uniqueness contract (:159-191), not decoration.
⚠ Nulls render an em dash, never the literal "undefined".
⚠ Keep the hand-rolled <table>. Do NOT convert to lightning-datatable — the Jest stub renders an
empty template and every absence pin in this suite would go vacuous.
⚠ Zero permission-set work: all three fields are already granted read in BOTH disposition sets.
Do not add any.

── ITEM 4: closing statement [CONDITIONAL on G-4 = (a)] ────────────────────
DispositionController.getClosingSummary — derive row.closingStatementUploaded from the presence of
a linked ContentDocument via the EXISTING ContentDocumentLinkSelector.selectByLinkedEntityId
(:44-52, WITH USER_MODE by intent). Mirror the sibling line one below:
`row.wireCreated = !d.Wires__r.isEmpty();`
🔴 CREATE NO ContentVersion/ContentNote/ContentDocument ANYWHERE, in production code or in tests
beyond what the assertion needs. Per .claude/rules/content-publication-rule.md, selector-read tests
cap at 20 rows and MUST carry the "BULK VOLUME IS 20, NOT 251 — DELIBERATE" header block used by
ContentVersionSelectorTest / ContentNoteSelectorTest, cross-referencing that rule.
🔴 DO NOT build a lightning-file-upload component. ContentPublicationBudget cannot see platform
publishes, so an uploader silently widens a structural undercount on an org-wide, non-refundable,
uncatchable quota.
⚠ State in the header that two users can legitimately see different closing-readiness states
because the selector is USER_MODE. That is correct, not a defect.

DO NOT, ANYWHERE IN THIS TRANCHE:
  • add a new @AuraEnabled class (if you must, it needs a DPEG_Apex_Access classAccesses entry —
    T3 shipped one without and the component was dead for every non-admin on a green deploy);
  • change PSA_Executed__c's type, or any Contract_Review__c file;
  • add a per-row "selected" marker to lwc/dispositionOffer (refused in writing, :210-214);
  • build any batch, schedulable, notification, email or callout;
  • touch BOV_Score__c, BovAutoSelectionService, or re-rank DISP-0041.
```

---

## 11. STANDING HAZARDS RESTATED FOR THIS TRANCHE

- 🔴 **Green source ≠ working.** T1 shipped a ListView Checkbox filter using `true` instead of `1`
  through two review passes; T4 shipped `!TypeName` followed by a line-broken `.staticMethod()`.
  Both were caught only by a compile or a deploy. **Nothing in §3 is proven until it compiles and a
  browser sees it.**
- 🔴 **A concurrent session owns this tree.** Re-read `git status` at assembly time; diff hub files
  against the **ORG**.
- 🔴 **`usman-dpeg` is production** — 75% per class, every payload.
- 🔴 **A FlexiPage deploy replaces the org copy with no version history.**
- 🔴 **A PermissionSet deploy replaces its collections** — `fieldPermissions` + `objectPermissions` +
  `SetupEntityAccess`.
- 🔴 **A layout deploy replaces its `<relatedLists>` set.**
- ⚠ **A dry-run skips unchanged components.** A green validation on a byte-identical component means
  "never validated", not "passed". Comment-only edits do not count as a diff.
- ⚠ **`--tests` runs the ORG's copy** — include test classes in the payload.
- ⚠ **`sf sobject describe` is a stale cache** — use Tooling `CustomField` with an explicit
  `TableEnumOrId` (and beware same-named fields on other objects: `CoStar_URL__c` will exist on both
  `Property__c` and `Property_Asset__c` after item 5).
- ⚠ **Description caps:** 255 (ValidationRule / CustomPermission / LWC `.js-meta.xml` / QuickAction /
  RecordType), 1000 (CustomField). `ApprovalProcess.description` is UNPROVEN.
- ⚠ **Anonymous Apex has a hard script-size cap and comments count toward it.**
- ⚠ **Explicit `null` ≠ omission** on Id-typed system fields.
