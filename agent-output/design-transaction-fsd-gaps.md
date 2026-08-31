# Design — Transaction FSD Gap Closure (13 partial + 8 not-built stories)

**Date:** 2026-08-31
**Agent:** salesforce-design
**Scope:** Transactions module only. Integration and notification work explicitly EXCLUDED (constraint 10).
**Status:** Requirements + design. **Nothing implemented.**

---

## 0. Process gates (recorded per `.claude/rules/salesforce-global-rule.md`)

```
intent=app | best_matched_skill=none | skill_selection=complete
mcp=unavailable | mcp_tools=none
```

`.claude/rules/salesforce-global-rule.md` mandates the `salesforce-api-context` MCP per metadata type.
A real attempt was made and it is **not configured in this repo**: `.mcp.json` declares only the
`salesforce` server, and this agent's tool set is file-system only (Read / Write / Edit / Glob / Grep)
— no MCP tools, no `sf` CLI, no org access. Recorded `mcp=unavailable` and fell back to per-type
skills plus in-repo empirical evidence, exactly as prior work in this repo has done. **Every metadata
shape below that this repo has no working precedent for is raised as a blocking gate in §3, not
guessed** — see `agent-output/` precedent and §3 GATE-S1.

**Everything in §2 was measured from the working tree today.** File and line references are given so
each claim is falsifiable.

---

## 1. Executive summary

### What this is

A **full data-model replacement** of the Transaction checklist. Today the 82-item checklist is
standard `Task` records driven from two CMDTs; the approved design (user Decision 1) replaces them
with `Checklist__c` + `Checklist_Item__c`, adds four more objects, and re-homes ~6 behaviours that
currently live in subject-string parsing, seed scripts, or nowhere at all.

### Honest effort estimate

This is **not a gap-fix tranche. It is a module rewrite with a live-data migration.**

| Phase | Content | Est. (dev-days) |
|---|---|---|
| 0 | Wire-fraud prerequisite gate on the **current** Task model (ships first, standalone) | 3–5 |
| 1 | Schema: 6 new objects, `Wire__c` + `Transaction__c` field adds, permission consolidation | 5–7 |
| 2 | Fan-out rewrite, rollup rewrite, `ChecklistItemTrigger`, governor re-derivation, tests | 8–12 |
| 3 | UI: 4 LWC rewrites + Jest, FlexiPage, 11 reports + dashboard repoint | 6–9 |
| 4 | Live-deal migration, backfill, dual-model cutover, legacy retirement | 5–8 |
| 5 | Loan / Insurance / Title / Vendor wiring, Critical Dates auto-create, EM + at-risk stamps | 6–9 |
| | **Total** | **33–50 dev-days** |

Plus admin/architect time for the schema and permission passes, and unit-test + code-review cycles
per `CLAUDE.md`. Realistically **7–10 calendar weeks for one developer**, and it cannot safely be
compressed by parallelising Phase 2 and Phase 4 against the same working tree (see §9).

### Top 3 risks

**RISK 1 — the `anti-fraud` / `CRITICAL` subject-string coupling silently reads zero.**
`TaskRollupService.recalc:48` derives `Wire_Open_Risks__c` from
`Subject.toLowerCase().contains('anti-fraud')`, and `transactionTaskGroups.js:11-12` re-derives
CRITICAL and WIRE from a regex on the same subject. Both are **string parses of seed data**, and
neither throws when it stops matching. If the `Flag__c` field lands and the subjects are cleaned up
in a different change, the Wire Sentinel dashboard metric reads **0 open wire risks** on every deal
with no error anywhere, and the checklist stops rendering the red CRITICAL rows. This is a
*fail-silent-in-the-unsafe-direction* coupling on the highest-value control in the module.
**Mitigation: the flag field, the subject cleanup, `TaskRollupService`, and `transactionTaskGroups.js`
must move in ONE change, and the change must be proven by asserting a non-zero `Wire_Open_Risks__c`
after cutover — a green deploy proves nothing here.**

**RISK 2 — the live-deal migration has no cheap rollback.**
`Critical_Date__c.Transaction__c` is `required=true` with `deleteConstraint=Restrict`
(`scripts/seed-critical-dates.apex:19-26` documents this and its consequences). Once Critical Dates
exist under a Transaction, that Transaction **cannot be deleted**. So "delete the deal and re-fan it"
is not available as a repair path on a botched migration, and `scripts/seed-transactions.apex:31`'s
`delete [SELECT Id FROM Transaction__c]` already throws on a rebuilt org for the same reason. The
migration must be **additive and reversible by field, not by record** (§7).

**RISK 3 — the roll-up chain and the governor budget are both unverified and both currently wrong.**
Fan-out grows from 82 rows to 93 rows per Transaction, and `TaskFanoutQueueable.CHUNK_SIZE = 100`
was sized for 82. At 93 + rollup writes the current chunk exceeds the 10,000 DML-row limit (§8
re-derives it: **~10,600 rows, a hard failure**). Separately, the master-detail roll-up-of-a-roll-up
that Story 5 wants is **not verifiable from this repo** and the declarative path may not hold. Both
are addressed below, but both are the kind of thing that passes review and fails in production at
scale.

---

## 2. Contradicted / corrected premises

Per standing practice, the brief's premises were re-measured rather than restated. **Eleven material
corrections**, evidence attached. These change scope; read them before the specs.

### 2.1 ✅ Wire verification evidence is ALREADY BUILT (scope reduction)

Decision 3 asks for "verification evidence (verifier / date / instructions source)" on `Wire__c`.
**All six evidence fields already exist:**

`force-app/main/default/objects/Wire__c/fields/` holds `Verifier_Name__c`, `Verifier_Phone__c`,
`Verified_DateTime__c`, `Wire_Instructions_Source__c`, `Verbal_Verification_Completed__c`,
`Confirmed_Wire_Amount__c`. `flows/Wire_Verification_Rollup.flow-meta.xml:47-54` already treats
exactly those six as the completeness formula.

**What is actually new on `Wire__c`:** (a) a `Transaction__c` lookup, (b) field history tracking,
(c) FLS. Nothing else. See §4.7.

### 2.2 🔴 `Wire__c.enableHistory` is FALSE, and the object file is a Disposition hub file

`objects/Wire__c/Wire__c.object-meta.xml:149` = `<enableHistory>false</enableHistory>`.
Turning history on is an **object-level** change, so it applies to **Disposition wires too**.
Constraint 9 says do not touch the Disposition-side use of `Wire__c`. Enabling history is arguably
desirable for both, but it is a cross-module change and needs explicit sign-off. → **GATE-B1.**

### 2.3 🔴 `Wire__c` already carries a validation rule that WILL fire on Transaction wires

`objects/Wire__c/validationRules/Verified_DateTime_Not_Backdatable.validationRule-meta.xml` is
**object-scoped, not Disposition-scoped**. Any Transaction wire path that writes
`Verified_DateTime__c` must stamp it within a **~1 minute tolerance of `NOW()`**
(`0.0007` days, line 98–99) or the save is refused — including a data-loader migration of historical
wires. The rule was landed 2026-08-31 for the Disposition tranche and inherits onto this work for free.

### 2.4 🔴 "Contract Executed" is NOT a valid `Critical_Date__c.Type__c` value

The brief asks for auto-created Critical Dates for *Contract Executed, Earnest Money, Feasibility End,
Closing*. The field is a **restricted** picklist with exactly five values
(`objects/Critical_Date__c/fields/Type__c.field-meta.xml`):

`Closing Date` | `Feasibility End` | `Insurance Binding` | `Loan Commitment` | `Earnest Money Due`

So: `Closing` → `Closing Date` ✅, `Earnest Money` → `Earnest Money Due` ✅, `Feasibility End` ✅, and
**`Contract Executed` does not exist**. Restricted picklists **are** enforced by Apex DML on this
project (measured repeatedly; `RecordStageAdvanceService`'s header carries the retraction, and
`scripts/seed-critical-dates.apex:34-38` restates it). Writing it produces
`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`, not a coercion. → **GATE-B2:** add the value, or drop
Contract Executed from the auto-create set. **The picklist value must deploy BEFORE the Apex that
writes it.**

### 2.5 🔴 Auto-creating Critical Dates makes every Transaction permanently undeletable

`Critical_Date__c.Transaction__c` is `required=true` + `deleteConstraint=Restrict`. Today only a demo
seed script creates rows, so the blast radius is contained. Auto-creating them on **every** Transaction
makes `DELETE_FAILED` the default for every deal in the org — including in scratch rebuilds and in
`scripts/seed-transactions.apex:31`. The script's own header already flags this
(`seed-critical-dates.apex:19-26`). → **GATE-B3:** accept, or change `deleteConstraint` to
`SetNull` + `required=false` (which then needs a validation rule instead — the
`required-flag-vs-validation-rule` pattern).

### 2.6 ✅ `seed-critical-dates.apex` already IS the auto-create specification — reuse it

`scripts/seed-critical-dates.apex` encodes the exact business rules the auto-create service needs, and
they were reasoned through once already:

- **Pinning:** `Closing Date ⇐ Target_Close_Date__c`, `Feasibility End ⇐ Feasibility_Deadline__c`
  (lines 55–67). A Critical Date that disagrees with the deal record is a defect.
- **Coherence gates:** skip closed/post-closing deals; drop `Feasibility End` at `Closing Prep` or when
  `Feasibility_Missed__c`; drop `Loan Commitment` when `Loan_Required__c != true` (lines 69–84).
- **Idempotency key:** `(Transaction Id + Type__c)` — self-healing on re-run, not a coarse early exit
  (lines 86–91).
- **Deliberately NOT gated:** `Earnest Money Due` is not suppressed when `EM_Wired_Date__c` is set
  (additional/hard-money deposits are normal in CRE).

The Apex service should **lift these rules verbatim**, and the script should then be repointed to call
it rather than duplicating them (§6).

### 2.7 🔴 The two-sources-of-truth problem on Critical Dates is worse than stated — and has a cheap resolution

The brief is right that `transactionCriticalDates` never touches `Critical_Date__c`. Measured:
`lwc/transactionCriticalDates/transactionCriticalDates.js:3-13` wires **eight `Transaction__c` fields
via LDS** and renders four hardcoded rows (`contract`, `em`, `feas`, `close`, lines 61–84). The
`Critical_Date__c` object feeds only `reports/Transactions/Critical_Dates_Countdown.report-meta.xml`
and the dashboard FlexTable.

**Recommended resolution: keep the Transaction fields as the SYSTEM OF RECORD and make
`Critical_Date__c` a derived projection of them.** The sidebar LWC stays exactly as it is (zero change,
zero regression risk); the auto-create service projects the Transaction's own dates into
`Critical_Date__c` rows so the report has data. This is already what the seed script's *pinning* rule
does. The alternative — making `Critical_Date__c` authoritative and repointing the LWC — costs an LWC
rewrite, a Jest rewrite, and a new selector, to fix a problem the pinning rule already solves.
→ **GATE-B4** for confirmation.

### 2.8 🔴 FOUR checklist items render as CRITICAL today, not three

The brief asks whether I7's criticality is intended. Measured against
`scripts/load-transaction-task-defs.apex` and the regex at `transactionTaskGroups.js:11`:

| Item | Subject marker | `CRITICAL_RE` | `WIRE_RE` |
|---|---|---|---|
| **B2** | `Call title company to verbally verify wiring instructions (anti-fraud)` | ✅ | ✅ |
| **F12** | `Set up auto loan payment (CRITICAL - frequently missed)` | ✅ | ❌ |
| **I7** | `Verify wiring instructions by phone (anti-fraud)` | ✅ | ✅ |
| **J4** | `Set up auto loan payment at lender bank (CRITICAL)` | ✅ | ❌ |

So the live set is **{B2, F12, I7, J4}** — I7 is critical today, deliberately (it is the closing-wire
twin of B2 and it is what `Wire_Open_Risks__c` counts). **Recommendation: seed CRITICAL on all four.**
Seeding only B2/F12/J4 would silently *remove* the red flag from the closing wire, which is the
highest-value one on the deal. → **GATE-B5** to confirm.

**🔴 MIGRATION TRAP:** A naive backfill of the form *"`Flag__c` = CRITICAL if `Subject` contains
'critical'"* wrongly flags **A4** (`Receive critical dates from title company`) and **A5**
(`Log critical dates into Salesforce deal record`). The live regex requires the token to be **inside
parentheses** (`/\(\s*(anti-?fraud|critical[^)]*)\s*\)/i`), which is what excludes them. The backfill
must match on the CMDT `Subject__c` literal or on the same parenthesised regex — never on a bare
substring.

### 2.9 🔴 The `Flag__c` picklist as specified DESTROYS the reportability it is being added for

Decision 1 specifies `Flag (None/CRITICAL/Verified/Completed)` as one field, and the brief requires it
to be "reportable". Those two requirements conflict: the four values **conflate a severity
(`CRITICAL`) with a state (`Verified`/`Completed`)** on one field, so completing a critical item
overwrites `CRITICAL` with `Completed` and the criticality is **lost from the record**. The report
"show me all CRITICAL items still open" then returns rows only until they are worked, and "how many
CRITICAL items did this deal have" becomes unanswerable. It is the exact failure the current
subject-string approach *does not* have (the subject is immutable).

**Recommendation: split into two fields** —
`Is_Critical__c` (Checkbox, immutable severity, seeded from the definition) and
`Item_Status__c` (restricted picklist: `Not Started` | `Completed` | `Verified`, the state).
`Flag__c` can still be delivered as a **display-only text formula** if the client wants the single
column: `IF(Is_Critical__c && Item_Status__c = 'Not Started', 'CRITICAL', Item_Status__c)`.

This preserves the client's UI while keeping the data reportable. → **GATE-B6.** This is a
requirements conflict inside an already-settled decision, so it needs the business, not a design call.

### 2.10 🔴 A master-detail child has NO `OwnerId` — so "owner" cannot be a record owner

Both `Checklist__c` and `Checklist_Item__c` list "owner" as a field, and Story 5's roll-ups need
master-detail. **Detail records in a master-detail relationship do not have an `OwnerId` field** — they
inherit ownership from the master. So "owner" here must be a field, not the record owner.

Measured: what the current model calls "owner" is **not a User at all**. `Task_Owner_Label__c` is
seeded from `Transaction_Task_Def__mdt.Owner_Label__c` / `Task_Group_Def__mdt.Owner_Label__c` and holds
role strings — `Danish`, `CFO`, `Legal`, `Accounting`, `Prop. Mgmt.`
(`scripts/load-transaction-task-defs.apex`). `TransactionTaskController.cls:50` and
`TaskSelector.cls:119-126` both carry warnings that pairing this label with a completion date reads as
"completed by <role>" and is false.

⇒ **`Owner_Label__c` (Text)** for the role, per ARCHITECTURE §1's type-suffix discipline
(`_Label__c` for Text carrying a human label). The **real** person is `Completed_By__c` — a role-named
`User` lookup, which §1 explicitly permits.

### 2.11 🔴 `Stage_Entry_Date__c` already has a name, a service and a backfill script — mirror them

The brief says "no `Stage_Entered_Date__c` field exists". True, but the established name in this repo is
**`Stage_Entry_Date__c`**, with a complete working precedent on Opportunity:

- `classes/OpportunityStageEntryService.cls` — `stampStageEntryDates`, a **before-context** stamp
- `triggers/OpportunityReviewTrigger.trigger:8` — the trigger wiring
- `classes/OpportunitySelector.cls:1374-1410` — the `Stage_Entry_Date__c != NULL` "load-bearing, not
  defensive" read for pre-existing deals
- `scripts/backfill-opp-stage-entry-date.apex` — the backfill for rows that predate the field, stamped
  from `LastModifiedDate`

**Use `Stage_Entry_Date__c` on `Transaction__c` and mirror this shape.** Do not invent a second name
for the same concept in the same org.

⚠ `OpportunityStageEntryService.cls:84-92` records that this field deployed with FieldPermissions rows
for **nobody**, System Administrator included — so its permission-set grant is part of the work, not
an afterthought.

### 2.12 🔴 There is a SECOND label mismatch, and a stale quick-action API name

The brief names one ("Closing Prep" vs "Closing"). There are three artefacts out of step:

| Source | Value |
|---|---|
| `Transaction__c.Stage__c` (restricted) | `Open Contract` · `Due Diligence` · **`Closing Prep`** · **`Post-Closing`** · `Closed` |
| `transactionTaskGroups.js:15-20` PHASES | `Open Contract` · `Due Diligence` · **`Closing`** · **`Post Closing`** |
| `Transaction_Record_Page.flexipage` tabs | `Open Contract` · `Due Diligence` · **`Closing`** · **`Post Closing`** |

Plus `quickActions/Transaction__c.Move_to_Closed_Won.quickAction-meta.xml` — the **API name** still says
`Closed_Won` after the terminal value was repointed to `Closed` in commit `a8a1bb2`. It is referenced
by `Transaction_Record_Page.flexipage-meta.xml:135`. Renaming a quick action is a delete+create
(reserved-name hazard). **Recommendation: leave the API name, fix only the label.** → **GATE-B7.**

### 2.13 ✅ Confirmed accurate in the brief

Verified and correct, restated only so the reader knows they were checked: the 11 group letters and
82-row split (A6 B5 C7 D5 E6 F12 G6 H5 H2:5 I10 J15); the fan-out chain
Flow → `TaskFanoutService.fanOut` → `TaskFanoutQueueable` → `fanOutNow`; group F gated on
`Task_Group_Def__mdt.Condition_Field__c = 'Loan_Required__c'`; the rollup chain; `DPEG_Transaction_Team`
holding exactly **11** permission sets; `Transaction_Complete_Close` keying on `Status__c = 'Closed'`;
`EM_Wired__c` being a formula Text that renders `$1.5M`; `Is_Earnest_At_Risk__c` existing with no
writer; `Tasks_Fanned_Out__c` being a one-shot guard with no re-run; and the Task-CRUD /
`ObjectPermissions` restricted-picklist finding.

Also confirmed free of collisions: **`Loan__c`, `Title_Company__c` and `Vendor__c` do not exist** in the
repo (`Vendor_Contract__c` does, on `Property_Asset__c` — untouched). `Insurance_Policy__c` is taken by
the PM Yardi mirror as stated.

Also confirmed: `.forceignore` **does not** ignore `objects/**` for any object in scope, nor
`permissionsets/**`, `flexipages/**` or `flows/**`. It **does** ignore `**/customMetadata/**` (line 16)
— CMDT *records* are not deployable and are loaded by the two apex scripts, exactly as the brief says.

---

## 3. Blocking gates — answer before implementation starts

| Gate | Question | Why it blocks |
|---|---|---|
| **GATE-B1** | Enable field history on `Wire__c`? It is object-level and applies to **Disposition** wires too. | Cross-module change; constraint 9 |
| **GATE-B2** | Add `Contract Executed` to `Critical_Date__c.Type__c`, or drop it from the auto-create set? | Restricted picklist; Apex write fails otherwise; deploy order |
| **GATE-B3** | Accept that auto-created Critical Dates make every Transaction undeletable, or relax `deleteConstraint` to `SetNull`? | Breaks seed/rebuild scripts; no rollback path |
| **GATE-B4** | Confirm `Transaction__c` fields stay the system of record and `Critical_Date__c` becomes a derived projection. | Determines whether the sidebar LWC is rewritten or untouched |
| **GATE-B5** | Seed CRITICAL on **four** items {B2, F12, I7, J4}, not three? | Otherwise the closing wire silently loses its red flag |
| **GATE-B6** | Split `Flag__c` into `Is_Critical__c` + `Item_Status__c` (with `Flag__c` as a display formula)? | The single-picklist spec destroys the reportability it is for (§2.9) |
| **GATE-B7** | Fix the three phase labels; leave `Move_to_Closed_Won` **API name** alone and change only its label? | Rename = delete+create, reserved name |
| **GATE-B8** | `Title_Company__c` and `Vendor__c` field lists are **not specified anywhere**. What fields? What is `Vendor__c`'s relationship to a Transaction (direct lookup? junction? none)? | Cannot write object metadata without them |
| **GATE-B9** | `Title_Company__c` and `Vendor__c` are company records — the org already has `Account`. Confirm the deliberate duplication. | Creates a second vendor master alongside `Vendor_Contract__c.Provider_Name__c` |
| **GATE-B10** | **There is no Accounting persona permission set in this org.** Decision 3 scopes wire FLS to "Transactions + Accounting". Who is Accounting, and does a new `DPEG_Accounting_*` set get created? | Blocks the whole permission pass |
| **GATE-B11** | Is `Transaction_Task_Actions` / `DPEG_Task_Edit` **retired** or **kept**? Recommendation below is *kept through Phase 4, retired in Phase 5* — needs a decision. | Determines whether legacy Tasks stay completable |
| **GATE-S1** | **Roll-up feasibility (Story 5).** Not verifiable from this repo — no org access, `mcp=unavailable`. Must be proven by `salesforce-admin` with a check-only dry-run **plus an org readback**, before Phase 2 design is locked. Protocol in §5.3. | Determines declarative vs Apex rollup — a large fork in Phase 2 |

**Everything below assumes these are answered. Do not start Phase 1 with GATE-B6, B8, B10 or S1 open.**

---

## 4. Object and field specifications

Naming follows `ARCHITECTURE.md` §1: `Title_Case_With_Underscores`; booleans `Is_`/`Has_`/
`<Subject>_<PastParticiple>`; currency names make the unit unambiguous; `Date` for date-only and
`DateTime` for date+time (**never** `Date` on a DateTime); relationship fields named for the target
object (role-named exception for `User`/`Contact`); `_Label__c`/`_Name__c` for Text carrying a human
label; `_Pct__c` for a Number that would otherwise read categorical. **No team-wide prefix.**

All new objects: `deploymentStatus=Deployed`, `enableReports=true`, `enableBulkApi=true`,
`enableSharing=true`, `enableActivities=false`, `enableFeeds=false`, `visibility=Public`,
`sharingModel` as stated per object.

---

### 4.1 `Checklist__c` — one per task group, per Transaction

**Parent:** `Transaction__c`, **Master-Detail** (required for Story 5's rollups; see GATE-S1).
**Sharing:** `ControlledByParent` (forced by master-detail).
**Name field:** AutoNumber, `CHK-{000000}`, label `Checklist Number`.

> ✅ **The `ControlledByParent` worry in constraint 4 does not bite here.** That trap (recorded for
> `Asset`) is about a *standard* object whose sharing parent is `Account`/`Contact` — it cannot inherit
> a custom Private parent. A **custom** detail object under `Transaction__c` (`sharingModel=Private`,
> `Transaction__c.object-meta.xml:165`) inherits Private correctly. The real consequences are:
> (a) **no sharing rules** may be written on these two objects, (b) **no `OwnerId`** (§2.10),
> (c) reparenting is off by default, (d) the parent lookup is **required at insert**, and
> (e) `viewAllRecords` behaviour on a detail object must be confirmed at GATE-S1 — today
> `DPEG_Transaction_View`/`_Edit` both grant `viewAllRecords=true` on `Critical_Date__c`, and the
> checklist must not become *less* visible than the Tasks it replaces.

| API Name | Type | Notes |
|---|---|---|
| `Transaction__c` | Master-Detail(`Transaction__c`) | `relationshipName=Checklists`, `relationshipLabel=Checklists`, `reparentableMasterDetail=false`, `writeRequiresMasterRead=false` |
| `Group_Letter__c` | Text(3), required | `A`…`J`, `H2`. Mirrors `Task_Group_Def__mdt.Letter__c` |
| `Group_Name__c` | Text(120), required | Mirrors `Task_Group_Def__mdt.Group_Name__c` |
| `Owner_Label__c` | Text(80) | Role label, not a User (§2.10). Mirrors `Task_Group_Def__mdt.Owner_Label__c` |
| `Stage__c` | Picklist, **restricted** | Values **byte-identical** to the first four `Transaction__c.Stage__c` values: `Open Contract`, `Due Diligence`, `Closing Prep`, `Post-Closing`. See ⚠ below |
| `Sequence__c` | Number(2,0) | **Parity field** — mirrors `Task_Group_Def__mdt.Sequence__c`; without it today's group ordering is lost |
| `Is_Conditional__c` | Checkbox | Mirrors `Task_Group_Def__mdt.Conditional__c` |
| `Items_Total__c` | See GATE-S1 | Roll-up COUNT of `Checklist_Item__c`, **or** Apex-written Number(3,0) |
| `Items_Complete__c` | See GATE-S1 | Roll-up COUNT filtered `Item_Status__c` ∈ {`Completed`,`Verified`}, **or** Apex Number(3,0) |
| `Pct_Complete__c` | **Number formula**, scale 0 | `IF(Items_Total__c > 0, ROUND(100 * Items_Complete__c / Items_Total__c, 0), 0)`. **Cannot be a roll-up** — roll-ups do COUNT/SUM/MIN/MAX only, never a ratio. Mirrors the existing `Transaction__c.Completion_Pct__c` formula exactly |

⚠ **`Stage__c` values must be byte-identical to `Transaction__c.Stage__c`'s.** `Closing Prep` and
`Post-Closing` (with the hyphen) — not the LWC's `Closing` / `Post Closing`. Anything else makes a
cross-object report join impossible and re-creates §2.12 one layer down. `Transaction__c` has **no
record types** (`RecordStageAdvanceService` keys it on `SINGLE_TYPE_KEY`), so the record-type-subset
DML hazard does **not** apply — but the restricted-value-set hazard does.

⚠ **`Closed` is deliberately absent** from `Checklist__c.Stage__c`: no task group belongs to the
terminal stage. Confirm at GATE-B7.

**Phase mapping (from `transactionTaskGroups.js:15-20`, unchanged):**
`Open Contract` = {A, B} · `Due Diligence` = {C, D, E, F, G, H, H2} · `Closing Prep` = {I} ·
`Post-Closing` = {J}.

---

### 4.2 `Checklist_Item__c` — one per checklist task

**Parent:** `Checklist__c`, **Master-Detail**. **Sharing:** `ControlledByParent`.
**Name field:** AutoNumber, `CLI-{000000}`.

| API Name | Type | Notes |
|---|---|---|
| `Checklist__c` | Master-Detail(`Checklist__c`) | `relationshipName=Checklist_Items`, `reparentableMasterDetail=false` |
| `Subject__c` | Text(255), required | The task text. Named to match `Transaction_Task_Def__mdt.Subject__c` exactly, making the migration mapping 1:1. Not `Task_Description__c` — that reads as a Description field |
| `Sequence__c` | Number(3,0), required | Mirrors `Transaction_Task_Def__mdt.Sequence__c` |
| `Is_Critical__c` | Checkbox, default false | **The immutable severity.** Seeded true on {B2, F12, I7, J4} (GATE-B5). Reportable forever, unlike a status-conflated picklist |
| `Item_Status__c` | Picklist, **restricted** | `Not Started` (default) · `Completed` · `Verified` |
| `Flag__c` | **Text formula** (display only) | `IF(AND(Is_Critical__c, ISPICKVAL(Item_Status__c,'Not Started')), 'CRITICAL', IF(ISPICKVAL(Item_Status__c,'Not Started'), 'None', TEXT(Item_Status__c)))` — delivers the client's requested 4-value column without destroying the data. **Only if GATE-B6 approves the split**; otherwise `Flag__c` is the restricted picklist as specified and `Is_Critical__c`/`Item_Status__c` are dropped |
| `Stage__c` | Picklist, **restricted** | Same four values as `Checklist__c.Stage__c`. **Stamped at creation** from the parent group's phase |
| `Owner_Label__c` | Text(80) | Role label. Mirrors `Transaction_Task_Def__mdt.Owner_Label__c`, falling back to the group's |
| `Completed_By__c` | Lookup(`User`) | **The real person.** Role-named lookup, ARCHITECTURE §1 exception. `deleteConstraint=SetNull`, `required=false` |
| `Completed_DateTime__c` | **DateTime** | ⚠ The brief says "completed-date". §1: **never** suffix a DateTime with `Date`. Today's value is `LastModifiedDate`, a Datetime, and the wire modal renders a time — so DateTime is the correct type and `_DateTime__c` the correct name |
| `Comment__c` | Long Text Area(4000) | Replaces `Task.Description`. ⚠ Long-text fields **strip trailing whitespace on save** in this org — do not assert byte-identical round-trips in tests |
| `Due_Date__c` | Date | **Parity field.** Replaces `Task.ActivityDate`; computed as `Transaction__c.Contract_Executed_Date__c + Transaction_Task_Def__mdt.Due_Day_Offset__c`. Without it `Tasks_Overdue__c` and `reports/Transactions/Overdue_Tasks` have no source |
| `Is_Conditional__c` | Checkbox | Mirrors `Task.Conditional__c` |
| **— wire-fraud evidence (migrated 1:1 from `objects/Activity/fields/`) —** | | |
| `Is_Wire_Verification__c` | Checkbox, default false | **Replaces the `anti-fraud` substring parse.** Seeded true on B2 and I7. This is what `Wire_Open_Risks__c` counts after cutover — see RISK 1 |
| `Verbal_Verification_Completed__c` | Checkbox | ← `Task.Verbal_Verification_Completed__c` |
| `Verified_By_Name__c` | Text(120) | ← `Task.Verified_By__c`. **Renamed deliberately**: `Verified_By__c` is a Text holding a name, and §1's relationship rule makes a bare `_By__c` read as a lookup — it now sits next to the real `Completed_By__c` lookup, so the collision is live, not theoretical |
| `Verification_Phone__c` | Phone | ← `Task.Verification_Phone__c` |
| `Verified_DateTime__c` | DateTime | ← `Task.Verified_At__c`. **Renamed** to the §1 canonical form (`Verified_DateTime__c` is literally the ARCHITECTURE §1 example, and matches `Wire__c.Verified_DateTime__c`) |
| **— prerequisite gate (§5.1) —** | | |
| `Blocked_By__c` | Lookup(`Checklist_Item__c`) | Self-lookup. When populated, this item cannot complete until its target is complete. `deleteConstraint=SetNull`. See §5.1 for why this and not a hardcoded pair |

---

### 4.3 `Loan__c`

**Parent:** `Transaction__c`, **Lookup** (not master-detail — created only when `Loan_Required__c` is
true, so a required parent relationship would be wrong-shaped and would block Transaction deletes).
**Sharing:** `Private`. **Name:** AutoNumber `LOAN-{0000}`.
Backs checklist items F5–F11.

| API Name | Type | Notes |
|---|---|---|
| `Transaction__c` | Lookup(`Transaction__c`) | `required=false`, `deleteConstraint=SetNull`. ⚠ **Not `required=true`** — that forces `deleteConstraint=Restrict` and reproduces the `Critical_Date__c` undeletable-parent problem (§2.5). Enforce presence with a validation rule instead |
| `Lender_Name__c` | Text(255) | ⚠ **Not `Lender__c`.** §1 reserves an object-shaped name for a lookup, and no `Lender__c` object exists. Direct precedent in this repo: `Vendor_Contract__c.Provider_Name__c`. If the lender should be an `Account`, that is GATE-B9 territory |
| `Loan_Amount__c` | Currency | §1: suffix `Amount` for a total |
| `Term_Months__c` | Number(3,0) | §1: the unit is in the name |
| `Interest_Rate_Pct__c` | Percent, scale 3 | §1 rate + `_Pct__c` type-suffix discipline |
| `Bank_Account_Type__c` | Picklist, **restricted** | `Operating` · `Escrow` · `Reserve` · `Other`. ✅ **This is an account TYPE, not an account NUMBER — Decision 3 is not violated.** Say so in the field description so nobody later "hardens" it away |
| `Auto_Payment_Status__c` | Picklist, **restricted** | `Not Set Up` (default) · `Requested` · `Active` · `Failed`. Backs F12 / J4, the two CRITICAL "frequently missed" items |
| `Commitment_Date__c` | Date | **Parity field** — feeds the `Loan Commitment` Critical Date, which `Critical_Date__c.Type__c` already carries and `seed-critical-dates.apex` already gates on `Loan_Required__c` |

🔴 **NO bank account numbers, NO routing numbers, on this object or any other (Decision 3).**

---

### 4.4 Transaction-side insurance — `Insurance_Binder__c`

**Name chosen because** `Insurance_Policy__c` is taken by the PM Yardi mirror (constraint: do not
touch it), and *binder* is the CRE term for exactly this artefact — the pre-closing binding of
coverage. Unambiguous against the PM object at a glance.
**Parent:** `Transaction__c`, Lookup. **Sharing:** `Private`. **Name:** AutoNumber `INSB-{0000}`.
Backs the G-group items.

| API Name | Type | Notes |
|---|---|---|
| `Transaction__c` | Lookup(`Transaction__c`) | `required=false`, `deleteConstraint=SetNull` (same reasoning as `Loan__c`) |
| `Carrier_Name__c` | Text(255) | Same naming reasoning as `Lender_Name__c` |
| `Policy_Number__c` | Text(80) | |
| `Coverage_Amount__c` | Currency | §1: `Amount` for a total |
| `Binding_Deadline_Date__c` | Date | Feeds the `Insurance Binding` Critical Date (already a valid `Type__c` value). ⚠ §1 requires the `Date` suffix; note the existing `Transaction__c.Feasibility_Deadline__c` **deviates** from that rule — do not copy the deviation |
| `Bound_Date__c` | Date | |
| `Is_Bound__c` | Checkbox formula | `NOT(ISBLANK(Bound_Date__c))` — derived, so it cannot drift from the date |

---

### 4.5 `Title_Company__c` — ⚠ SPEC INCOMPLETE (GATE-B8 / B9)

**No field list exists in the FSD, the brief, or the repo.** Below is a **proposal to be confirmed,
not a specification.** Per Rule 2 I will not assume field types for an unspecified object.

**Sharing:** `Private`. **Name field:** standard **Text** `Name` (this is a company, not a
transaction record — AutoNumber would be wrong).

| API Name (proposed) | Type | Notes |
|---|---|---|
| `Phone__c` | Phone | |
| `Email__c` | Email | |
| `Escrow_Officer_Name__c` | Text(120) | The person named in the A-group and B-group items |
| `Escrow_Officer_Phone__c` | Phone | The number B2/I7 verbal verification is made to |
| `Is_Active__c` | Checkbox, default true | |

**Plus** on `Transaction__c`: `Title_Company__c` Lookup(`Title_Company__c`), `deleteConstraint=SetNull`.
⚠ §1 forces the lookup field to carry the object's name, which also means **no Text field anywhere
in this org may ever be named `Title_Company__c`.** Verified: none exists today.

---

### 4.6 `Vendor__c` — ⚠ SPEC INCOMPLETE (GATE-B8 / B9)

Same status. **Proposal, not specification.** In particular **the relationship to `Transaction__c` is
undefined** — direct lookup? a junction (a deal uses many vendors, a vendor serves many deals)? or no
Transaction relationship at all? That determines whether this is one object or two.

**Sharing:** `Private`. **Name field:** standard Text `Name`.

| API Name (proposed) | Type | Notes |
|---|---|---|
| `Service_Type__c` | Picklist, restricted | Values **not specified**. `Vendor_Contract__c.Service_Type__c` exists on the PM side — do **not** share the value set, that would couple the modules |
| `Phone__c` | Phone | |
| `Email__c` | Email | |
| `Is_Active__c` | Checkbox, default true | |

🔴 **Explicit non-change:** `Vendor_Contract__c.Provider_Name__c` (PM) is **not** repointed to
`Vendor__c`. Constraint 9. The consequence — two vendor masters in one org — is a real cost and is
GATE-B9's subject.

---

### 4.7 `Wire__c` — additive changes only

| Change | Detail |
|---|---|
| **ADD** `Transaction__c` | Lookup(`Transaction__c`), `required=false`, `deleteConstraint=SetNull`, `relationshipName=Wires`, `relationshipLabel=Wires`. ✅ Safe: relationship names are unique per **target** object, and `Disposition__c` already uses `Wires` against a different target |
| **ADD** `Wire_Type__c` | Picklist, restricted: `Earnest Money` · `Closing`. **Needed** to distinguish the B-group wire from the I-group wire on the same deal. Not in the brief → confirm at GATE-B8 |
| **CHANGE** object `enableHistory` | `false` → `true`. 🔴 **Cross-module** — GATE-B1 |
| **ADD** `trackHistory=true` | On the six evidence fields + `Transaction__c` + `Wire_Type__c` |
| **NO CHANGE** | `Disposition__c` lookup, the six evidence fields, `Verified_DateTime_Not_Backdatable`, `WireService`, `WireSelector`, `WireController`, `lwc/wireVerification`, `Wire_Verification_Rollup` |

✅ **`Wire_Verification_Rollup` is already safe.** Its start filter is `Disposition__c IsNull = false`
(`Wire_Verification_Rollup.flow-meta.xml:106-113`), so a Transaction-parented wire never enters it and
never attempts `$Record.Disposition__r`. **Verify this by readback after deploy** — the flow writes a
Disposition through a null lookup if that filter is ever relaxed.

⚠ `objects/Wire__c/Wire__c.object-meta.xml` and the three Disposition permission sets are **hub files**
(§9).

---

### 4.8 `Transaction__c` — additive fields

Follows the **additive pattern** (add → backfill → repoint → retire). Nothing is renamed.

| API Name | Type | Notes |
|---|---|---|
| `Stage_Entry_Date__c` | Date | §2.11 — mirrors `Opportunity.Stage_Entry_Date__c` exactly, including the name |
| `Earnest_Money_Sent__c` | Checkbox, default false | §1 boolean `<Subject>_<PastParticiple>`. ⚠ **`EM_Wired__c` cannot be repurposed** — it is a formula **Text** rendering `$1.5M` (verified, `EM_Wired__c.field-meta.xml:5-8`) |
| `Earnest_Money_Sent_Date__c` | Date | Stamped by B5. Distinct from the existing `EM_Wired_Date__c`, which the sidebar LWC already reads — **do not conflate them.** If the business says they are the same thing, that is a retirement of one, and a separate decision |
| `Checklist_Fanned_Out__c` | Checkbox, default false | 🔴 **The migration's single most important field.** A **separate** guard from `Tasks_Fanned_Out__c`, so the two models can coexist and neither guard's writers interfere. It is also a *single-writer discriminator*: only `ChecklistFanoutService` writes it, so `TestDataFactory` and every seed script are immune by construction rather than by a bypass flag |
| `Title_Company__c` | Lookup(`Title_Company__c`) | GATE-B8 |
| `Loan__c` | ⚠ **do not add** | The relationship lives on `Loan__c.Transaction__c`. Adding a reverse lookup gives two sources of truth for one edge |

**Reused unchanged (deliberately):** `Tasks_Complete__c`, `Tasks_Total__c`, `Tasks_Overdue__c`,
`Wire_Open_Risks__c`, `Tasks_Display__c`, `Completion_Pct__c`, `Tasks_Open__c`, `Is_Earnest_At_Risk__c`.
See §5.3 for why these must **stay Apex-written Numbers** and must not become roll-up summaries.

---

## 5. Behaviour gaps — design

### 5.1 🔴 HIGHEST PRIORITY — wire-fraud prerequisite gating (Story 28)

**Requirement:** B3 (*Send wire request to accounting with verified instructions*) blocked until B2
(*Call title company to verbally verify wiring instructions (anti-fraud)*) is complete. I8
(*Send closing wire to title company with verified instructions*) blocked until I7
(*Verify wiring instructions by phone (anti-fraud)*). Enforced by Flow/validation rule,
**not by UI convention alone.**

**Today: nothing enforces it.** `TransactionTaskService.completeWireVerification` requires a
name + phone *on the verification task itself* — it says nothing about the item that follows.
`transactionTaskGroups.js:230-247` routes wire tasks to a modal, but a data loader, the API, a Flow,
or the object's own list view completes B3 with no check whatsoever.

**Recommended shape: a `before update` trigger check on `Checklist_Item__c`, plus a validation rule.**

The brief suggests the trigger, and that is right — but a trigger alone is not sufficient and a
validation rule alone is not either:

- **Trigger** covers everything (UI, Flow, API, data loader, Apex) and can do the lookup a VR cannot.
- **Validation rule** additionally survives an `AccessLevel.SYSTEM_MODE` write, which the trigger's own
  `with sharing` service does not stop. This repo has already made exactly this call —
  `Verified_DateTime_Not_Backdatable`'s header records "FLS alone was rejected as insufficient (D-12 =
  BOTH) … a validation rule STILL evaluates under SYSTEM_MODE."
- ⚠ A VR **cannot** read a sibling record, so it can only assert on a **denormalised** field. Hence:

**Mechanism:**
1. `Checklist_Item__c.Blocked_By__c` (self-lookup) is **seeded at fan-out** — B3 → B2, I8 → I7. Data,
   not code. Adding a third prerequisite pair later is a definition change, not a deploy.
2. `ChecklistItemTriggerHandler` (before update) refuses any item transitioning to
   `Completed`/`Verified` whose `Blocked_By__c` target is not complete. Bulk-safe: **one** selector
   read for all `Blocked_By__c` targets in the chunk, zero SOQL in a loop.
3. A denormalised `Is_Prerequisite_Met__c` checkbox, maintained by the same handler, backs a
   validation rule as the SYSTEM_MODE backstop.

**⚠ Do NOT implement this by hardcoding the strings `B3`/`I8` or the subject text.** That reproduces
RISK 1 in a new place. The `Blocked_By__c` link is set from `Transaction_Task_Def__mdt` at fan-out.

**⚠ This phase ships FIRST, against the CURRENT Task model.** Phase 0 (§10) delivers the equivalent
gate on `Task` via `TaskRollupTriggerHandler`'s existing `before update` context — the trigger already
declares `before insert, before update` (`TaskRollupTrigger.trigger:23-30`), so no trigger-context
change is needed. The org should not carry an unenforced wire-fraud control for the 7–10 weeks the
rest of this takes.

### 5.2 CRITICAL flag + per-item Stage + real completed-by

- **CRITICAL:** `Is_Critical__c`, seeded from the definition on {B2, F12, I7, J4} (GATE-B5), matched by
  the **parenthesised** regex or by CMDT literal — never by bare substring (§2.8 trap).
- **`Is_Wire_Verification__c`:** seeded on {B2, I7}. This is what replaces
  `Subject.contains('anti-fraud')` in `TaskRollupService`. **Both must move together** (RISK 1).
- **Stage:** stamped at creation from the group's phase mapping (§4.1). Values byte-identical to
  `Transaction__c.Stage__c`.
- **Completed-by / date:** `Completed_By__c` (User lookup) and `Completed_DateTime__c`, written by the
  completion service. This retires the `LastModifiedBy` approximation that `TaskSelector.cls:119-126`
  and `TransactionTaskController.cls:50` both carry warnings about.

### 5.3 🔴 GATE-S1 — roll-up feasibility, and the recommended answer

**Story 5 wants:** `Checklist__c.Pct_Complete__c` and `Transaction__c.Tasks_Complete__c` as roll-ups.

**What is certain without an org:**
- A roll-up summary computes **COUNT / SUM / MIN / MAX only**. A **percentage is not one of them**, so
  `Pct_Complete__c` is a **formula** over two roll-ups, never a roll-up. That part is settled.
- Roll-up summaries require **master-detail** the whole way. A lookup will not do.
- What is **NOT** certain from here: whether `Transaction__c` can carry a roll-up that SUMs
  `Checklist__c.Items_Complete__c` **when that field is itself a roll-up summary** (the roll-up-of-a-
  roll-up). This is the crux and it must be measured.

**🔴 Recommendation: do NOT use declarative roll-ups for `Tasks_Complete__c` / `Tasks_Total__c`,
regardless of what GATE-S1 finds. Keep them Apex-written Numbers.** Three independent reasons:

1. **Converting a stored Number to a roll-up summary is a suite-wide compile break.** Both fields are
   **assigned** today in: `scripts/seed-transactions.apex:45,52,59,66,89`,
   `scripts/seed-transactions-nondestructive.apex:59,66,73,80,104`,
   `TaskFanoutService.cls:131`, `TaskRollupService.cls:57`, and `TaskFanoutServiceTest.cls:239-240`.
   A roll-up summary is **not writable**, so every one of those breaks — and the seed scripts are how
   the demo org is built.
2. **`editable=true` FLS on a roll-up summary fails the deploy.** `agent-output/hub-consolidation-tracker.md:26-40`
   records this exact trap for eight PM fields. Both `Tasks_*` fields are granted `editable` today.
3. **`Wire_Open_Risks__c` and `Tasks_Overdue__c` cannot be roll-ups anyway** — one is conditional on
   two fields, the other is date-relative (`ActivityDate < TODAY`), and roll-up criteria cannot
   express a rolling date. So Apex is required for two of the four counters regardless; running two
   mechanisms side by side is strictly worse than running one.

⇒ **`ChecklistRollupService` recomputes all four counters plus `Checklist__c.Items_*`, from a single
selector read, in one DML per level.** `Pct_Complete__c` and `Completion_Pct__c` stay formulas.
Story 5's *acceptance criterion* (the numbers are correct and live) is met; only the *mechanism*
differs, and that is worth stating to the business rather than hiding.

**GATE-S1 protocol for `salesforce-admin` (do not skip a step; a green deploy is not proof):**
1. Load the per-type skill; attempt the MCP; record `mcp=complete|unavailable` + tools.
2. Prove the shape on **ONE** field first — a roll-up COUNT of `Checklist_Item__c` on `Checklist__c` —
   via a **check-only dry-run**.
3. **Read it back from the org** and verify the field type is what was intended.
4. Then attempt the roll-up-of-a-roll-up on `Transaction__c` as a **separate** dry-run.
5. Independently confirm that `viewAllRecords` can be granted on a `ControlledByParent` detail object,
   with a readback — the checklist must not become less visible than the Tasks it replaces.
6. Only then replicate.

### 5.4 Stage-entry date

Mirror `OpportunityStageEntryService` exactly (§2.11): a **before-context** stamp on
`TransactionTriggerHandler`, writing `Stage_Entry_Date__c` on every record whose `Stage__c` this save
is changing. **No `if (field == null)` guard** — `OpportunityStageEntryService.cls:212` records that
such a guard silently reintroduces the bug it was meant to fix.

✅ **In-repo precedent for "fires for every writer":** `flows/Transaction_Stage_Closed_Sets_Status.flow-meta.xml`
is a before-save flow on this exact object, and its header argues at length for before-save over a
branch in `RecordStageAdvanceService.setStage` — because it catches "the advanceRecordStage quick
action, an inline Path edit, the API, a data loader, or a seed script — not just the one button."
The same argument applies verbatim here. Either shape (before-save Flow or before-context Apex) is
defensible; the Apex mirrors the Opportunity precedent and the Flow mirrors the Transaction precedent.
**Recommendation: Apex, to match the field's namesake.**

**Plus a backfill script** modelled on `scripts/backfill-opp-stage-entry-date.apex`, stamping open
deals from `LastModifiedDate`. Without it, every pre-existing Transaction reads null forever and any
downstream "days in stage" report silently excludes them.

⚠ The field will deploy with **zero FieldPermissions for anybody, System Administrator included**.
The permission-set grant is part of the work.

### 5.5 Critical Dates auto-create

Per §2.6: lift `seed-critical-dates.apex`'s rules verbatim into `CriticalDateService.ensureFor(Set<Id>)`
— pinning, coherence gates, `(Transaction + Type)` idempotency key, `allOrNone = false` with per-row
failure logging. Called from the Transaction trigger on stage change and on the date fields changing.
Then **repoint the seed script to call the service** rather than duplicating the rules.

Blocked on GATE-B2 (`Contract Executed` value), GATE-B3 (`Restrict` constraint), GATE-B4 (source of truth).

### 5.6 `Loan_Required__c` correction path (Story 10)

Today `Tasks_Fanned_Out__c` is one-shot with no re-run
(`TaskFanoutService.cls:94`, `if (t.Tasks_Fanned_Out__c == true && !bypassDedupe) continue;`).
`scripts/fanout-seeded-transactions.apex` re-arms it by resetting the flag — a manual script, not a
feature.

**Design:** an idempotent `ChecklistFanoutService.reconcile(Set<Id>)` that **adds the missing group F
checklist and its 12 items** when `Loan_Required__c` flips false→true before `Stage__c = 'Closed'`,
and **removes group F** on the reverse flip **only when no item in it has been completed** (otherwise
refuse with a user-safe message — deleting worked history is worse than an inconsistent checklist).
Reconcile, never blanket re-fan: a blanket re-fan on a live deal destroys completions.

The correction is keyed on `Checklist_Fanned_Out__c`, not `Tasks_Fanned_Out__c`, so it cannot disturb
the legacy model during the migration window.

### 5.7 A5 → Critical Dates; B5 → Earnest Money Sent

- **A5** (`Log critical dates into Salesforce deal record`) completion invokes `CriticalDateService`.
- **B5** completion sets `Earnest_Money_Sent__c = true` and stamps `Earnest_Money_Sent_Date__c`.
  ⚠ Note the B-group is 5 items (B1–B5); B5 in `load-transaction-task-defs.apex` is the last one.
  **Confirm the exact item** with the business before wiring — the brief says "B5 sets Earnest Money
  Sent" but B4 reads *Confirm wire sent and mark task complete*, which is arguably the event.
  → **open question OQ-4.**

Both are keyed on the **`Checklist_Item__c` record**, resolved via `Sequence__c` + parent
`Group_Letter__c` — **never** on subject text.

### 5.8 Earnest At Risk auto-flag

`Is_Earnest_At_Risk__c` exists, the portfolio KPI sums it, nothing writes it. Set true when the
feasibility period has ended and earnest money has been sent:
`Feasibility_Deadline__c < TODAY && Earnest_Money_Sent__c` (and not `Feasibility_Missed__c`).

⚠ **This is time-based, so a trigger alone will not do it** — no save occurs on the day feasibility
expires. It needs a **Schedulable** (or a formula). **Recommendation: make it a formula checkbox** and
retire the stored field via the additive pattern — a formula cannot go stale, needs no job, and this
org already has *two unscheduled jobs* as open go-live gates from a prior tranche. → **OQ-5**, because
the portfolio KPI currently SUMs the stored field and a formula checkbox is still summable.

### 5.9 C7 / G6 document attachment; F5–F11 → Loan; G-tasks → Insurance

- **C7 / G6:** on completion, prompt for and attach a document to the **Transaction**.
  🔴 **Read `.claude/rules/content-publication-rule.md` before writing any test here.** Every
  `ContentVersion` insert consumes one of the org's **2,500 per rolling 24 hours** `ContentPublication`
  quota; **test rollback does not refund it**; `Limits` cannot see it; and exceeding it throws
  `System.UnexpectedException` that **escapes `catch (Exception)` and ignores `allOrNone=false`**,
  aborting the whole transaction. This org has already had that outage. Max **1–3** content rows per
  DML test method. **The 251-record bulk mandate does NOT apply to these tests.**
- **F5–F11 → `Loan__c`, G-group → `Insurance_Binder__c`:** the item→field map lives in
  `Transaction_Task_Def__mdt` (a new `Target_Field__c` column) or in a `ChecklistItemDefProvider`
  constant, **not** in a subject-string switch.

---

## 6. Complete inventory of existing components — rewrite / repoint / retire

Legend: **RW** rewrite · **RP** repoint · **RT** retire · **AM** amend · **NC** no change but verify.

### 6.1 Apex

| File | Action | What |
|---|---|---|
| `classes/TaskFanoutService.cls` | **RT** after cutover | Replaced by `ChecklistFanoutService`. Keep until legacy Tasks are retired. Its `SYSTEM_MODE` justification block (lines 134–145) must be **carried over verbatim** to the replacement — same Flow, same un-provisioned calling user |
| `classes/TaskFanoutQueueable.cls` | **RT** | Replaced by `ChecklistFanoutQueueable`. The `CHUNK_SIZE` sizing comment (lines 5–7) is **now wrong** — see §8 |
| `classes/TaskFanoutServiceTest.cls` | **RT** | Asserts `Tasks_Total__c = 82` at line 239 |
| `classes/TaskRollupService.cls` | 🔴 **RW** | **RISK 1 lives at line 48.** `Subject.toLowerCase().contains('anti-fraud')` → `Is_Wire_Verification__c`. The whole `SYSTEM_MODE` block (lines 61–106) transfers unchanged — it documents a real AsyncApexJob failure |
| `classes/TaskRollupServiceTest.cls` | **RW** | |
| `classes/TaskRollupTriggerHandler.cls` | **AM** | 🔴 **SHARED WITH PROPERTY MANAGEMENT.** Routes `Transaction__c` **and** `Onboarding__c`, and carries the before-context onboarding completion stamp. Remove only the Transaction arm; **do not touch the Onboarding arm** (constraint 9) |
| `classes/TaskRollupTriggerHandlerTest.cls` | **AM** | Same |
| `triggers/TaskRollupTrigger.trigger` | **AM** | Six contexts, both parents. The `before` contexts stay (Onboarding needs them) |
| `classes/TaskSelector.cls` | **AM** | 🔴 **SHARED, CROSS-MODULE, EXPLICITLY A CONTRACT** (its own header, lines 6–24). Retire `selectChecklistByTransactionDealIds` + `selectByTransactionDealIds` **only**. Leave the Onboarding, PM-Schedulable, Disposition and Broker-Protection/EAC methods untouched — that is six of the nine methods |
| `classes/TaskSelectorTest.cls` | **AM** | Same |
| `classes/TransactionTaskService.cls` | **RT** → `ChecklistItemService` | 🔴 Its entire reason for existing is the un-grantable Task CRUD (header lines 22–66). **With custom objects that problem disappears — the replacement uses ordinary `USER_MODE` DML and normal permission sets, no custom permission, no SYSTEM_MODE.** That is the single biggest simplification in this programme |
| `classes/TransactionTaskServiceTest.cls` | **RW** | |
| `classes/TransactionTaskController.cls` | **RW** | `TaskRow`/`GroupRow` DTOs (lines 35–63) become `ItemRow`/`ChecklistRow`. Lines 91–114's `completedByName = LastModifiedBy.Name` approximation is **retired** in favour of the real `Completed_By__c` |
| `classes/TransactionTaskControllerTest.cls` | **RW** | |
| `classes/TransactionActionPermissionService.cls` | **AM** / **RT** | `assertTaskActionAccess` has no purpose once items are a custom object. **GATE-B11** |
| `classes/TaskGroupDefProvider.cls` | **NC** | ✅ Reused as-is. Its header already documents that `getAll()` populates every **non-long-text** field |
| `classes/TransactionTaskDefProvider.cls` | **AM** | New CMDT columns (`Is_Critical__c`, `Is_Wire_Verification__c`, `Blocked_By_Sequence__c`, optional `Target_Field__c`) |
| `classes/TransactionSelector.cls` | **AM** | `selectByIdsWithConditionFields` gains the new Transaction fields |
| `classes/TransactionController.cls` | **AM** | Reads `Status__c`/`Tasks_*` — verify unaffected |
| `classes/TestDataFactory.cls` | 🔴 **AM — HUB FILE** | `createChecklistTasks` (:1282), the bulk variant (:1331), `createTransactions` (:2500), `createCriticalDates` (:2546), `createWires` (:3490). **Lines 2573-2575 and 3490-3497 assert "the org has no `Wire__c` → `Transaction__c` relationship" — that becomes FALSE and must be corrected in the same change** |
| **NEW** | | `ChecklistFanoutService`, `ChecklistFanoutQueueable`, `ChecklistRollupService`, `ChecklistSelector`, `ChecklistItemSelector`, `ChecklistItemService`, `ChecklistItemTriggerHandler`, `ChecklistController`, `CriticalDateService`, `CriticalDateSelector`, `LoanService`, `TransactionStageEntryService`, `ChecklistMigrationBatch` + a test class each |

### 6.2 LWC

| Bundle | Action | What |
|---|---|---|
| `lwc/transactionTaskGroups` | 🔴 **RW** | The largest single UI change. Lines 11–12's `CRITICAL_RE`/`WIRE_RE` **regexes are deleted** and replaced with the boolean fields. Line 179's `subject.replace(CRITICAL_RE, '')` (which strips the marker for display) goes with them. Phase labels fixed (§2.12). `__tests__/transactionTaskGroups.test.js` rewritten — ⚠ its current fixtures *bake in the subject-marker convention*, so they will pass vacuously against a repointed component if not rewritten |
| `lwc/transactionChecklistSummary` | **RP** | + Jest |
| `lwc/transactionPhaseCards` | **RP** | Phase labels; + Jest |
| `lwc/transactionTaskCards` | **RP** | + Jest |
| `lwc/transactionCriticalDates` | **NC** (per GATE-B4) | ✅ Reads Transaction fields via LDS and never touches `Critical_Date__c`. If B4 is approved it changes **nothing** |
| `lwc/transactionKpis`, `lwc/activeTransactionsList`, `lwc/transactionStageDonut` | **NC / verify** | Read `Transaction__c` counters, which are being preserved |
| `lwc/wireVerification` | **NC** | Disposition-side. Constraint 9 |

⚠ **`.js-meta.xml` `<description>` is capped at 255 characters and ONLY a deploy catches it** — Jest,
the SLDS linter and code review all passed a 258-char one in this repo.

### 6.3 Declarative

| File | Action | What |
|---|---|---|
| `flows/Transaction_Task_Fanout.flow-meta.xml` | **RP** | Action → `ChecklistFanoutService`; start filter `Tasks_Fanned_Out__c` → `Checklist_Fanned_Out__c`. ⚠ It declares **no `runInMode`**, so it runs as the calling user — that is precisely why the SYSTEM_MODE blocks exist downstream |
| `flows/Transaction_Complete_Close.flow-meta.xml` | **NC** | 🔴 Keys on `Status__c = 'Closed'` — **explicit user decision, do not change** |
| `flows/Transaction_Stage_Closed_Sets_Status.flow-meta.xml` | **NC** | Before-save `Stage__c='Closed'` → `Status__c='Closed'`. Its in-file comment forbids repointing the sibling flow |
| `flows/Transaction_Opened_Notify.flow-meta.xml` | **NC** | Constraint 10 (no notification work) |
| `flows/Wire_Verification_Rollup.flow-meta.xml` | **NC — verify by readback** | Disposition-scoped by its start filter (§4.7) |
| `flows/Onboarding_Task_Fanout.flow-meta.xml` | **NC** | PM. Constraint 9 |
| `pathAssistants/Transaction_Path.pathAssistant-meta.xml` | **AM** | Labels only. 🔴 **Do not touch the picklist `<valueSet>`** — the `Closed` terminal was deliberately repointed in `a8a1bb2`; a prior harmonisation of a shared terminal red-lined 12 acquisition tests |
| `flexipages/Transaction_Record_Page.flexipage-meta.xml` | 🔴 **AM — HUB FILE** | Four `transactionTaskGroups` instances (`phase` = open/dd/close/post, lines 194–245), five tabs, four Move_to_* quick actions. **A FlexiPage deploy REPLACES the org copy and there is no version history.** Retrieve + diff seconds before deploying, and check `SetupAuditTrail` for App Builder saves newer than the last retrieve — two tabs were lost this way on 2026-08-25 |
| `flexipages/Active_Transactions.flexipage-meta.xml` | **NC / verify** | |
| `quickActions/Transaction__c.Move_to_Closed_Won.*` | **AM** | **Label only** (GATE-B7) |
| `objects/Task/listViews/Transaction_Tasks_by_Group.listView-meta.xml` | **RT** | Filters on `Task_Group__c` |
| `objects/Activity/fields/{Task_Group__c, Task_Sequence__c, Task_Owner_Label__c, Transaction_Deal__c, Conditional__c, Verbal_Verification_Completed__c, Verified_By__c, Verified_At__c, Verification_Phone__c}` | **RT** — Phase 5 only | 🔴 **`objects/Activity/fields/` is SHARED with PM and Broker Protection.** Only these nine are Transaction-only; `Onboarding*`, `Source_System__c`, `Blocked_Reason__c`, `Inbound_Message_Id__c`, `Thread_Key__c` are **not**. Retire only after the migration is signed off — a deleted field name **stays reserved until ERASED** |

### 6.4 Reports / dashboards

All eleven under `reports/Transactions/` report on `CustomEntity$Transaction__c` (verified on
`Total_Completed_Tasks`), so they read the **Transaction counters**, not Tasks — and therefore
**survive unchanged** if §5.3's recommendation (keep the counters Apex-written on `Transaction__c`) is
followed. That is a large part of the case for it.

| File | Action |
|---|---|
| `reports/Transactions/Open_Wire_Risks.report-meta.xml` | **NC** — but its number is the RISK 1 canary. **Assert it is non-zero after cutover** |
| `reports/Transactions/{Total_Tasks, Total_Open_Tasks, Total_Completed_Tasks, Overdue_Tasks, Completion_By_Deal, Closing_In_30_Days, Transactions_By_Stage, Open_Transactions, Financing_Active}` | **NC / verify** |
| `reports/Transactions/Critical_Dates_Countdown.report-meta.xml` | **NC** — starts returning real rows once §5.5 lands |
| `dashboards/Transactions/Transaction_Dashboard_Junior.dashboard-meta.xml` | 🔴 **verify** — the Wire Sentinel metric. ⚠ Dashboard "invalid cross reference id" after an org rebuild is **stale hardcoded Dashboard Ids in URL tabs**, not this change |

### 6.5 Permission sets, CMDT, scripts

| File | Action |
|---|---|
| `permissionsets/DPEG_Transaction_Edit.permissionset-meta.xml` | 🔴 **AM — HUB** |
| `permissionsets/DPEG_Transaction_View.permissionset-meta.xml` | 🔴 **AM — HUB** |
| `permissionsets/DPEG_App_Transaction.permissionset-meta.xml` | 🔴 **AM — HUB** (tab visibility) |
| `permissionsets/DPEG_Task_Edit.permissionset-meta.xml` | **AM / RT** — GATE-B11. ⚠ Its 2026-08-28 comment (lines 191–213) explains why the Task `<objectPermissions>` block **must not be re-added** |
| `permissionsets/DPEG_TaskChecklist_View.permissionset-meta.xml` | **AM** |
| `permissionsets/DPEG_Admin_Access.permissionset-meta.xml` | 🔴 **AM — HUB, and the usual casualty of a widened SELECT** |
| `permissionsets/DPEG_Disposition_Edit` / `_View` | **AM** only if GATE-B1 approves Wire history |
| `permissionsetgroups/DPEG_Transaction_Team.permissionsetgroup-meta.xml` | **AM** only if a new set is added. 🔴 **Do NOT collapse the 11 sets** — that undoes the 2026-07-22 least-privilege RBAC design |
| `objects/Transaction_Task_Def__mdt/fields/` | **AM** — new columns (§6.1) |
| `objects/Task_Group_Def__mdt/fields/` | **NC** — reused as-is |
| `scripts/load-task-group-defs.apex` | **NC** |
| `scripts/load-transaction-task-defs.apex` | **AM** — new columns; the 82 rows are the source of truth for the migration |
| `scripts/seed-critical-dates.apex` | **RP** to call `CriticalDateService` (§5.5) |
| `scripts/fanout-seeded-transactions.apex` | **RP** to `Checklist_Fanned_Out__c` |
| `scripts/seed-transaction-progress.apex` | 🔴 **RW** — completes checklist Tasks directly |
| `scripts/seed-transactions.apex`, `scripts/seed-transactions-nondestructive.apex` | **AM** — they **assign** `Tasks_Complete__c` (§5.3 reason 1) |
| `scripts/verify-junior-lifecycle.apex`, `scripts/seed-fsd-04-flagship-closed-won.apex` | **verify** |

🔴 **`**/customMetadata/**` is force-ignored (`.forceignore:16`).** CMDT *records* never deploy; the
loader scripts are the only path, and **re-running them is an ordered step** in the build sequence, not
an afterthought.

---

## 7. Migration strategy for live deals (REQUIRED SECTION)

### The problem

CMDT drives **creation only**. Every existing Transaction already carries up to 82 `Task` rows with
real completions, real comments, real wire-verification evidence, and real dates. `Tasks_Fanned_Out__c`
is already `true` on all of them, so nothing re-fans. The new model must be populated **from the
existing rows**, not from the definitions — otherwise every deal in flight resets to zero.

### Recommended strategy: dual-model window, additive backfill, deferred retirement

**Old Tasks are LEFT IN PLACE and made read-only. They are not converted in place and not deleted.**

Rationale: `Task` rows cannot be reconstructed once deleted; the Activity model has no undelete
guarantee across a rollback of this size; and RISK 2 means there is no cheap way to rebuild a deal.
Leaving them costs storage and one obsolete list view. That is a good trade.

**Sequence:**

| Step | Action | Reversal |
|---|---|---|
| **M0** | Deploy schema + Apex with `Checklist_Fanned_Out__c` **false** everywhere. The new fan-out is armed but fires for nobody. **Old model still fully live.** | Nothing has changed behaviourally |
| **M1** | `ChecklistMigrationBatch` — per Transaction, read its Tasks and build 11 `Checklist__c` + N `Checklist_Item__c`, mapping each Task to its definition **by `Task_Group__c` letter + `Task_Sequence__c`**, never by subject text. Carry over: `Item_Status__c` (from `IsClosed`), `Completed_DateTime__c` (`LastModifiedDate`), `Completed_By__c` (`LastModifiedById` — the acknowledged approximation, now frozen as history rather than recomputed), `Comment__c` (`Description`), `Due_Date__c` (`ActivityDate`), and all four wire-evidence fields. Set `Checklist_Fanned_Out__c = true` **last**, per Transaction | **Delete the `Checklist__c` rows** (cascade deletes items) and reset the flag. Old Tasks are untouched and still authoritative |
| **M2** | **Reconciliation report**, run before cutover: per Transaction, old `Tasks_Complete__c` vs new `Items_Complete__c` summed. **Any mismatch blocks cutover.** Also assert the CRITICAL count is 4 per deal and `Wire_Open_Risks__c` recomputes to the same number under both mechanisms | Read-only |
| **M3** | **Cutover** — deploy the LWC/controller repoint and the `TaskRollupService` change **in one deploy**. Verify `Open_Wire_Risks` report is non-zero. This is the irreversible-ish step; the reversal is redeploying the previous bundle | Redeploy prior LWC/Apex; data untouched |
| **M4** | Make legacy Tasks read-only: revoke `Transaction_Task_Actions` from `DPEG_Task_Edit`. **Do not delete Tasks.** | Re-grant |
| **M5** | *Weeks later, separate change:* retire the nine Transaction-only `Activity` fields, `TaskFanoutService`, `TaskFanoutQueueable`, the two `TaskSelector` methods, the Task list view, and `Transaction_Task_Actions` (GATE-B11) | Irreversible — deleted field names stay reserved until ERASED |

### 🔴 Migration risks called out explicitly

1. **The `(anti-fraud)` / `(CRITICAL)` marker must be matched by the parenthesised regex or the CMDT
   literal.** A bare substring match wrongly flags A4 and A5 (§2.8).
2. **`Completed_By__c` from `LastModifiedById` is knowingly wrong for any Task edited after
   completion.** Migrating it freezes an approximation as history. The alternative — leaving it null —
   loses the information entirely. **Recommendation: migrate it, and set a
   `Is_Completed_By_Migrated__c` marker** so a report can distinguish inferred from recorded.
   → **OQ-6.**
3. **Group F is absent on no-loan deals**, so item counts vary per deal (`Tasks_Total__c` is
   per-Transaction, not 82 — `TaskRollupService.cls:6-15` is emphatic about this). The migration must
   build from **the Tasks that exist**, never from the 82-row definition list, or every no-loan deal
   gains 12 phantom incomplete items.
4. **`Transaction__c` is `enableHistory=true`** (line 149), so the backfill's writes to
   `Checklist_Fanned_Out__c` land in field history. Harmless, but it means the migration is auditable —
   use that in M2.
5. **The batch must respect the DML budget** — see §8. `Database.executeBatch(batch, 50)`.
6. **`Critical_Date__c` `Restrict`** (RISK 2) means a failed migration cannot be repaired by deleting
   the deal.
7. **A concurrent session edits this working tree.** M3 is a multi-file deploy touching hub files —
   see §9.
8. 🔴 **Any bulk (re-)load of historical `Task` rows must INSERT WITH A BLANK `Blocked_By__c` AND
   STAMP THE KEY IN A SECOND PASS.** Phase 0 shipped an insert-time control:
   `TaskPrerequisiteService.clampOnInsert` forces `Is_Prerequisite_Met__c` to false on any Task
   created with a `Blocked_By__c`, and `Prerequisite_Must_Be_Met_To_Complete`'s `ISNEW()` arm then
   refuses it if it is also `Completed`. **The refusal does not consult the prerequisite's real
   state** — the insert context deliberately performs no lookup (the Day-0 fan-out cascade cannot
   afford ~41 extra queries), so it is refused *whenever* a key is present. A loader that recreates
   a completed B3 or I8 with its key in one statement therefore fails, and `allOrNone = false` will
   silently drop exactly those rows. Insert first, `update` the key afterwards: an already-complete
   row is not *transitioning* into completion, so the gate passes it. This is the same ordering
   `scripts/backfill-task-blocked-by.apex` uses and it is pinned by
   `TaskPrerequisiteServiceTest.allowsBackfillOfAnAlreadyCompleteDependent`.
   ⚠ Applies to **M1** (if any Task is ever recreated rather than read), to any dry-run rehearsal
   that rebuilds a sandbox's Tasks from an extract, and to M5 rollback. It does **not** apply to
   `TaskFanoutService`, which creates everything `Not Started`.

---

## 8. Governor budget — re-derived, not assumed

`TaskFanoutQueueable.CHUNK_SIZE = 100`, justified as "82 Tasks per Transaction, so 100 Transactions =
~8,200 Task rows, comfortably inside the 10,000 DML-row limit" (lines 5–7). **That sizing does not
survive the new model.**

**Per Transaction, new model (loan deal, all 11 groups):**

| Rows | Source |
|---|---|
| 11 | `Checklist__c` inserts |
| 82 | `Checklist_Item__c` inserts |
| 1 | `Transaction__c` update (`Checklist_Fanned_Out__c`, `Tasks_Total__c`) |
| **94** | **subtotal** |
| +11 | `Checklist__c` rollup writes, if the rollup trigger is not suppressed |
| +1 | `Transaction__c` rollup write, ditto |
| **106** | **worst case** |

| Chunk | Rows | Verdict |
|---|---|---|
| 100 (current) | **10,600** | 🔴 **`Too many DML rows: 10001` — hard failure** |
| 90 | 9,540 | ⚠ <5% headroom. One added write per item breaks it |
| 75 | 7,950 | ~20% headroom |
| **50** | **5,300** | ✅ **~47% headroom. Recommended** |

**Recommendation: `CHUNK_SIZE = 50`, AND suppress the rollup during fan-out.** The fan-out already
knows the counts it is creating (`createdForTxn` at `TaskFanoutService.cls:97,129`), so it writes
`Items_Total__c` / `Tasks_Total__c` directly and sets a static suppression flag the rollup handler
respects. That drops the worst case to 94 × 50 = **4,700 rows**, and removes the
`ceil(rows/200)`-SOQL-and-DML trigger-cascade cost that routing a new parent into a Task trigger
produced last time.

**Other limits, checked:**
- **DML statements (150):** 3 per chunk (Checklist insert, Item insert, Transaction update). Fine.
- **SOQL (100/200):** 1 selector read + the CMDT providers (`getAll()` is free). Fine.
- **Queueable chaining (50 per transaction):** unchanged — exactly **one** `System.enqueueJob` per
  invocation, the chain advances from the `ChainFinalizer` (`TaskFanoutQueueable.cls:51-86`). **Keep
  that Finalizer shape** — it is what stops a failed chunk stranding every chunk behind it.
- **Row locks:** a master-detail child insert locks its master. Within one chunk that is all
  self-contained, but a concurrent user edit of a `Transaction__c` during fan-out can now throw
  `UNABLE_TO_LOCK_ROW` where it previously could not. **New failure mode; state it.**

**Bulk-test mandate (`.claude/rules/bulk-test-rule.md`):** the **251-record mandate applies** to
`ChecklistItemTrigger`, `ChecklistRollupService`, `ChecklistFanoutService.fanOutNow` and
`ChecklistMigrationBatch` — none is a per-transaction singleton, all loop, all take collections.
**Two carve-outs:** (a) the content-attachment tests of §5.9 are capped at 1–3 rows by
`.claude/rules/content-publication-rule.md`; (b) a literal 251 **Transactions** in one fan-out test is
impossible and meaningless — 251 × 94 = 23,594 DML rows — so the fan-out volume test asserts at the
**chunk boundary (50 and 51 Transactions)**, with the reasoning recorded in the test class header so
review does not demand 251. The **251-record mandate stands unchanged for `Checklist_Item__c` itself.**

⚠ **Assert governor headroom on counters captured INSIDE the async context**, not on
`Limits.getQueries()` after `Test.stopTest()` — `stopTest` restores the pre-test counters and the
obvious assertion passes vacuously.

---

## 9. Shared / hub files — consolidate in ONE pass

**A concurrent session edits this same working tree.** `agent-output/hub-consolidation-tracker.md`
establishes the protocol: **no implementation stream edits these files; the orchestrator applies them
in one pass; diff every one against HEAD immediately before deploying; never run a repo-wide deploy.**

| Hub file | Shared with | Hazard |
|---|---|---|
| `permissionsets/DPEG_Transaction_Edit`, `_View`, `DPEG_App_Transaction`, `DPEG_Task_Edit`, `DPEG_TaskChecklist_View`, `DPEG_Admin_Access` | every stream | 🔴 **A PermissionSet deploy REPLACES its whole `<fieldPermissions>` set** — partial edits silently revoke. The repo file must be a **superset of the org** before it ships (`DPEG_Task_Edit`'s own header records this incident) |
| `permissionsets/DPEG_Disposition_Edit`, `_View` | Disposition | Only if GATE-B1 |
| `permissionsetgroups/DPEG_Transaction_Team` | — | Do not collapse the 11 sets |
| `objects/Wire__c/Wire__c.object-meta.xml` | 🔴 **Disposition** | `enableHistory` is object-level |
| `objects/Activity/fields/**` | 🔴 **PM + Broker Protection** | Nine of ~17 fields are Transaction-only |
| `triggers/TaskRollupTrigger.trigger` + `TaskRollupTriggerHandler.cls` | 🔴 **PM (Onboarding)** | One trigger, two parents, before **and** after contexts |
| `classes/TaskSelector.cls` | 🔴 **PM + Disposition + Broker Protection/EAC** | Its header calls itself "a contract, not a private helper" |
| `classes/TestDataFactory.cls` | every stream | Two stale comments to correct (§6.1) |
| `flexipages/Transaction_Record_Page.flexipage-meta.xml` | App Builder users | 🔴 Deploy **replaces** the org copy; no version history |
| `objects/Transaction_Task_Def__mdt/**` + its loader script | — | Force-ignored records; loader re-run is an ordered step |
| `.forceignore` | every stream | Do not edit |

🔴 **Formula and roll-up fields must be granted `editable=false`** — `editable=true` on one **fails the
deploy**. In scope: `Checklist__c.Pct_Complete__c`, `Checklist_Item__c.Flag__c`,
`Insurance_Binder__c.Is_Bound__c`, plus `Items_Total__c`/`Items_Complete__c` if GATE-S1 makes them
roll-ups, plus the existing `Transaction__c.Completion_Pct__c` / `Tasks_Open__c` / `Tasks_Display__c` /
`EM_Wired__c`.

---

## 10. Recommended build sequence

### Phase 0 — wire-fraud gate on the CURRENT model (ships standalone, first)

The org should not go 7–10 weeks with an unenforced wire-fraud control.

1. `Task.Blocked_By__c` (self-lookup on `Activity`) + `Task.Is_Prerequisite_Met__c`.
2. `TaskRollupTriggerHandler` **before update** — the contexts already exist — refuses B3/I8 while
   B2/I7 are open.
3. Validation rule as the SYSTEM_MODE backstop.
4. Backfill `Blocked_By__c` on all live deals from `Task_Group__c` + `Task_Sequence__c`.
5. Tests: 251-record bulk, plus a **negative** test proving a data-loader write is refused.

**Phase 0 is fully discarded at M5.** That is deliberate and worth the cost.

### Phase 1 — schema
6 objects, `Wire__c` + `Transaction__c` fields, CMDT columns + loader re-run, **one consolidated
permission pass**, `Critical_Date__c.Type__c` value (GATE-B2). **Deploy record-type/picklist values
before any Apex that writes them.**

### Phase 2 — Apex core
Fan-out, rollup, `ChecklistItemTrigger` (incl. the §5.1 gate on the new model), selectors, services,
`TransactionStageEntryService` + backfill script, `CriticalDateService` + seed-script repoint,
`Loan_Required__c` reconcile. Chunk size 50. Full test suite.

### Phase 3 — UI
LWC rewrites + Jest + sa11y, FlexiPage, phase labels, quick-action label. **RISK 1 lands here and must
land atomically with `TaskRollupService`.**

### Phase 4 — migration
M0 → M4 of §7. **M2's reconciliation report gates the cutover.**

### Phase 5 — new-object wiring + retirement
F5–F11 → `Loan__c`; G-group → `Insurance_Binder__c`; C7/G6 documents (content quota rules apply); A5;
B5; Earnest-at-risk; `Title_Company__c`/`Vendor__c` surfaces. Then M5 retirement, including GATE-B11.

---

## 11. 🔵 PROMPT FOR salesforce-admin / salesforce-solution-architect

> **Route to `salesforce-solution-architect`** — this is a 6-object schema with a security model and a
> master-detail hierarchy, not a field add.

```
Read ARCHITECTURE.md and .claude/rules/ first. Record mcp=unavailable after a real attempt
(.mcp.json has only the `salesforce` server; you have no salesforce-api-context tools) and fall
back to the per-type skill. Do NOT deploy — create metadata files only.

Source of truth: agent-output/design-transaction-fsd-gaps.md §4 (specs), §9 (hub files).

BLOCKING — do not start until GATE-B6, B8, B10 and S1 in §3 are answered by the user.

FIRST, execute GATE-S1 (§5.3) as a standalone check-only dry-run with an org readback:
  (a) prove ONE roll-up summary COUNT of Checklist_Item__c on Checklist__c;
  (b) SEPARATELY prove whether Transaction__c can roll up Checklist__c.Items_Complete__c when
      that field is itself a roll-up summary;
  (c) prove whether viewAllRecords can be granted on a ControlledByParent detail object.
A green deploy is not proof — read each result back from the org. Report findings before
building the rest.

THEN create:

1. Checklist__c + Checklist_Item__c per §4.1/§4.2. Master-detail chain to Transaction__c.
   Stage__c values must be BYTE-IDENTICAL to Transaction__c.Stage__c's first four values:
   'Open Contract', 'Due Diligence', 'Closing Prep', 'Post-Closing'. Restricted value sets.
   Detail objects have NO OwnerId — 'owner' is Owner_Label__c (Text), NOT a User lookup.
2. Loan__c per §4.3 and Insurance_Binder__c per §4.4. Lookup parents with required=false and
   deleteConstraint=SetNull — do NOT use required=true, which forces Restrict and reproduces
   the Critical_Date__c undeletable-parent defect.
3. Title_Company__c and Vendor__c per §4.5/§4.6 — ONLY after GATE-B8 supplies the field lists.
   Do not invent fields. Do not touch Vendor_Contract__c or Insurance_Policy__c.
4. Wire__c: ADD Transaction__c lookup + Wire_Type__c. Set enableHistory=true and trackHistory
   on the evidence fields ONLY if GATE-B1 is approved. Change NOTHING else on Wire__c — the
   six evidence fields and Verified_DateTime_Not_Backdatable already exist and are correct.
5. Transaction__c: ADD Stage_Entry_Date__c, Earnest_Money_Sent__c, Earnest_Money_Sent_Date__c,
   Checklist_Fanned_Out__c, Title_Company__c. Rename NOTHING. Do NOT touch Stage__c's value
   set — 'Closed' was deliberately repointed in commit a8a1bb2.
6. Critical_Date__c.Type__c: add 'Contract Executed' ONLY if GATE-B2 approves.
7. Transaction_Task_Def__mdt: add Is_Critical__c, Is_Wire_Verification__c,
   Blocked_By_Sequence__c (+ Target_Field__c if the developer's design needs it).
   customMetadata/** is force-ignored — RECORDS load via scripts/load-transaction-task-defs.apex,
   which must be updated and re-run as an ordered step.
8. Labels only: Transaction_Record_Page tabs and Transaction_Path — 'Closing' -> 'Closing Prep',
   'Post Closing' -> 'Post-Closing'. Leave quickActions/Transaction__c.Move_to_Closed_Won's
   API NAME alone; change its label only.
9. ONE consolidated permission pass over the sets in §9. A PermissionSet deploy REPLACES its
   entire fieldPermissions set — edit each file as a whole and make it a superset of the org
   before shipping. Grant editable=false on every formula/roll-up field listed in §9 (editable=true
   fails the deploy). Do NOT collapse the 11-set DPEG_Transaction_Team PSG.
10. Before touching Transaction_Record_Page: retrieve it and diff against HEAD, and check
    SetupAuditTrail for App Builder saves newer than the last retrieve. A FlexiPage deploy
    replaces the org copy and there is no version history.

Do NOT touch: Insurance_Policy__c, Vendor_Contract__c, Property_Asset__c, any Disposition-side
use of Wire__c, or objects/Activity/fields/Onboarding*.
```

---

## 12. 🟢 PROMPT FOR salesforce-developer

```
Read ARCHITECTURE.md, .claude/rules/apex-layering-rule.md, .claude/rules/bulk-test-rule.md and
.claude/rules/content-publication-rule.md first. Do NOT deploy.

Source of truth: agent-output/design-transaction-fsd-gaps.md §5 (behaviour), §6 (inventory),
§8 (governor budget). Blocked on GATE-S1 for the rollup mechanism.

PHASE 0 FIRST, standalone, against the CURRENT Task model (§10):
  Task.Blocked_By__c self-lookup + Is_Prerequisite_Met__c; a before-update check in
  TaskRollupTriggerHandler (the trigger already declares before insert/update) refusing B3 while
  B2 is open and I8 while I7 is open; a validation rule as the SYSTEM_MODE backstop; a backfill
  script keyed on Task_Group__c + Task_Sequence__c. Include a NEGATIVE test proving a
  data-loader-shaped write is refused. Never key on subject text.

THEN Phases 2-5:

1. ChecklistFanoutService / ChecklistFanoutQueueable, replacing TaskFanoutService /
   TaskFanoutQueueable. CHUNK_SIZE = 50, NOT 100 — §8 re-derives it (100 gives 10,600 DML rows
   and fails). Suppress the rollup during fan-out and write the counts directly. KEEP the
   ChainFinalizer shape. CARRY OVER, VERBATIM, the SYSTEM_MODE justification blocks from
   TaskFanoutService.cls:134-145 and TaskRollupService.cls:61-106 — the flow still declares no
   runInMode and still runs as an un-provisioned calling user.
2. ChecklistRollupService writing Transaction__c.Tasks_Complete__c / Tasks_Total__c /
   Tasks_Overdue__c / Wire_Open_Risks__c. KEEP THESE AS APEX-WRITTEN NUMBERS — §5.3 gives three
   reasons a roll-up summary breaks the seed scripts, the FLS grants and two of the four counters.
3. 🔴 TaskRollupService's replacement must derive the wire count from
   Checklist_Item__c.Is_Wire_Verification__c, NOT from Subject.contains('anti-fraud'). This and the
   transactionTaskGroups.js regex removal MUST land in the SAME change (RISK 1) — otherwise the
   Wire Sentinel silently reads 0 with no error. Prove it with a post-cutover assertion that
   reports/Transactions/Open_Wire_Risks is NON-ZERO.
4. ChecklistItemTriggerHandler: the §5.1 prerequisite gate on the new model, driven by
   Blocked_By__c (seeded data), one selector read per chunk, no SOQL in a loop.
5. ChecklistItemService (replacing TransactionTaskService): ordinary USER_MODE DML and normal
   permission sets. The whole SYSTEM_MODE + Transaction_Task_Actions workaround exists ONLY
   because Task CRUD is un-grantable; on a custom object it is unnecessary. Do not port it.
6. TransactionStageEntryService, mirroring OpportunityStageEntryService exactly (before context,
   Stage_Entry_Date__c, NO `if (field == null)` guard — see that class's line 212), plus a
   backfill script modelled on scripts/backfill-opp-stage-entry-date.apex.
7. CriticalDateService: lift the rules from scripts/seed-critical-dates.apex verbatim (pinning,
   coherence gates, (Transaction + Type) idempotency, allOrNone=false with per-row logging), then
   repoint that script to call the service.
8. ChecklistFanoutService.reconcile for the Loan_Required__c correction path — reconcile, never
   blanket re-fan; refuse removal of group F when any of its items is complete.
9. ChecklistMigrationBatch per §7 M1. Map by Task_Group__c letter + Task_Sequence__c, NEVER by
   subject text. Build from the Tasks that EXIST, never from the 82-row definition list (group F
   is absent on no-loan deals). Database.executeBatch(batch, 50). Plus the M2 reconciliation report.
10. LWC: rewrite transactionTaskGroups (delete CRITICAL_RE/WIRE_RE and the subject-strip at line
    179), repoint transactionChecklistSummary / transactionPhaseCards / transactionTaskCards.
    Leave transactionCriticalDates and lwc/wireVerification alone. Rewrite the Jest suites — the
    existing fixtures bake in the subject-marker convention and will pass vacuously otherwise.
    .js-meta.xml <description> is capped at 255 chars and ONLY a deploy catches it.
11. Correct the two stale TestDataFactory comments at :2573-2575 and :3490-3497 which assert the
    org has no Wire__c -> Transaction__c relationship.

TESTS: 251-record bulk per .claude/rules/bulk-test-rule.md for ChecklistItemTrigger,
ChecklistRollupService, ChecklistFanoutService.fanOutNow and ChecklistMigrationBatch. TWO
carve-outs, each documented in the test class header: (a) content-attachment tests are capped at
1-3 rows by .claude/rules/content-publication-rule.md — a ContentPublication overrun escapes
catch(Exception), ignores allOrNone=false, and has already caused an outage here; (b) the fan-out
VOLUME test asserts at the chunk boundary (50 and 51 Transactions), because 251 Transactions =
23,594 DML rows is unreachable. Assert governor headroom on counters captured INSIDE the async
context, not on Limits.getQueries() after Test.stopTest(). Use TestDataFactory. 90%+ coverage.

Do NOT touch: OnboardingTaskDomain, OnboardingAutoCreateService, the Onboarding arm of
TaskRollupTriggerHandler, the Onboarding/PM/Disposition/Broker-Protection methods of TaskSelector,
DispositionTaskService, WireService, or flows/Transaction_Complete_Close (its Status__c='Closed'
filter is an explicit user decision).
```

---

## 13. Open questions for the business

Distinct from §3's technical gates — these need the client, not an admin.

| # | Question |
|---|---|
| **OQ-1** | **Story 6 is stale.** It asks that the Transaction be created "when `Contract_Executed_Date__c` is populated". Creation was **deliberately moved** to `Opportunity.StageName = 'About to Close'` on 2026-08-05 by user decision, and `ContractExecutionService`'s header carries an explicit "Do not re-add" (three separate places). **Raise with the business as a documentation correction; it is not work.** |
| **OQ-2** | **Story 38's permission set is partly impossible as written** — it asks for Read/Write on `Task`, which cannot be granted by permission set on this platform (`ObjectPermissions.SobjectType` excludes Task/Event/Activity, and a set carrying it **deploys green then is silently discarded**). Decision 1 moots it. Confirm the story is closed by the custom-object move rather than by a permission change. |
| **OQ-3** | **`Flag__c` as specified destroys reportability** (§2.9). Split into `Is_Critical__c` + `Item_Status__c` with `Flag__c` as a display formula? |
| **OQ-4** | **Which B-group item sets Earnest Money Sent?** B5 (per the brief) or **B4** — *Confirm wire sent and mark task complete* — which reads more like the event? |
| **OQ-5** | **Should `Is_Earnest_At_Risk__c` become a formula?** It is time-based: nothing saves the record on the day feasibility expires, so a trigger alone never fires. A formula is self-maintaining; a Schedulable is another job to schedule (this org already has two unscheduled jobs as open go-live gates). |
| **OQ-6** | **Migrated `Completed_By__c` is `LastModifiedById` — a known approximation.** Migrate it and mark it as inferred, or leave it null on historical items? |
| **OQ-7** | **`Title_Company__c` and `Vendor__c` duplicate `Account`.** The org already models companies as Accounts, and PM already stores vendor names as text on `Vendor_Contract__c`. Confirm the deliberate creation of a second company/vendor master. |
| **OQ-8** | **Who is "Accounting"?** Decision 3 scopes wire FLS to Transactions + Accounting, and **no Accounting permission set exists in this org.** Which users, and does a new `DPEG_Accounting_*` set get created and added to a PSG? |
| **OQ-9** | **Should CRITICAL be seeded on four items or three?** Four is what the org renders today ({B2, F12, I7, J4}); three would silently un-flag the **closing wire**, the highest-value item on the deal. |
| **OQ-10** | **Enable field history on `Wire__c`?** It is object-level and therefore applies to **Disposition** wires as well. |
| **OQ-11** | **`Earnest_Money_Sent_Date__c` vs the existing `EM_Wired_Date__c`** — are these the same business event? If so, one should be retired (additively), not shadowed. |
| **OQ-12** | **Old checklist Tasks: convert, retire, or leave in place?** Recommendation is **leave in place, made read-only, deleted never** (§7). Confirm the storage and clutter cost is acceptable in exchange for a reversible migration. |
```
