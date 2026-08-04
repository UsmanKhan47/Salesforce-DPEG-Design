# DESIGN REQUIREMENTS — Lead field gate + Opportunity stage validation rules

Date: 2026-08-04 · Design agent · Target: `usman-dpeg` (verify) · API 67.0

---

## 0. RECON FINDINGS THAT CHANGE THE BRIEF (read these before the plan)

Six findings from reading the actual metadata. Three of them change what should be built.

### F1 — 🔴 Decision 2(d) "Close Date set → About to Close" CANNOT BE BUILT AS STATED

`CloseDate` is a **platform-required** field on `Opportunity`. It can never be blank on a saved
record. `TestDataFactory` even hardcodes `CloseDate = Date.today().addDays(90)`. A rule
`ISBLANK(CloseDate)` is a **guaranteed no-op** — it would deploy green, look like protection, and
never fire once.

**This is a mistaken user decision and must go back to the user.** Options:

| Option | Rule | Meaning |
| --- | --- | --- |
| **d-1 (recommended)** | `CloseDate < TODAY()` | Block About to Close when the close date is already in the past — i.e. force the deal-driver to re-set a realistic date before the deal enters the closing runway. This is the only reading of "Close Date set" that has teeth. |
| d-2 | drop gate (d) | The other three gates already chain About to Close behind a signed NDA. |
| d-3 | new field `Target_Close_Date__c` | Rejected — the brief says prefer no new fields, and this duplicates a standard field. |

Everything below is written for **d-1**, and is marked so it can be dropped cleanly if the user
picks d-2.

### F2 — ✅ The backward-block constraint is much smaller than feared. Repo evidence, not theory.

The brief's hard constraint assumed `Set_Stage_Underwriting` (LOI rejection → Underwriting) would
be blocked by a backward rule. **There is a currently-green test in this repo that proves validation
rules do not run on approval-process field updates in this org:**

`LoiGateTest.rejectionReturnsDealToUnderwriting` inserts an Opportunity at `LOI`. On insert,
`OpportunityReviewService.ensureNda` creates an NDA with `Status__c = 'Pending'` (unsigned) and
stamps it onto `Primary_NDA__c`. The test then rejects the approval, whose `finalRejectionActions`
field update sets `StageName = 'Underwriting'`. That transition satisfies **every** clause of the
deployed `NDA_Signed_Before_Underwriting` rule — `ISCHANGED(StageName)` is true, the stage IS
Underwriting, and the primary NDA is NOT signed. The test asserts the stage landed on
`'Underwriting'` and the suite is green.

⇒ The rule did not fire. Approval-process field updates bypass custom validation rules here
(consistent with the documented order of execution, where workflow field updates re-run system
validation but not custom validation rules).

**Consequence:** the LOI-rejection path is already safe. We still add an explicit LOI→Underwriting
carve-out as belt-and-braces (see VR-6), but the design does not depend on it.

**⚠ MUST RE-VERIFY BEFORE DEPLOY (2 minutes, no code):** on the target org, take a deal to LOI with
an unsigned NDA, submit the LOI approval, reject it, confirm the stage lands on Underwriting. If it
errors, F2 is false in that org and VR-6's carve-out becomes load-bearing rather than redundant.

### F3 — 🔴 A record-triggered flow writes `Closed Won`. It IS subject to validation rules.

`flows/Transaction_Complete_Close` is an after-save flow on `Transaction__c` that, when
`Status__c = 'Closed'`, updates the parent Opportunity to `StageName = 'Closed Won'`. Unlike an
approval field update, a flow's `recordUpdates` is ordinary DML and **runs validation rules**.

Gate (c) (`Contract_Signed__c` required for Closed Won) is satisfied on the normal path — the same
`Contract_Executed_Date__c` / `Contract_Signed__c` stamp that `ContractExecutionService` writes is
what creates the `Transaction__c` in the first place. But a manually-created Transaction, or a deal
whose NDA was never signed, would make the flow throw and **roll back the Transaction save**.

Named risk R2. No test drives this path today (grep for `Status__c = 'Closed'` on `Transaction__c`
in tests returns nothing), so it will only be seen in UAT.

### F4 — 🔴 A before-save flow moves the stage BACKWARD from any stage. It IS subject to VRs.

`flows/Opportunity_Initiate_Underwriting` is a **before-save** flow: when
`Initiate_Underwriting__c` flips true, it sets `StageName = 'Underwriting'` from *any* stage whose
name is not already `Underwriting` — including `LOI`, `PSA`, `About to Close`, `Closed Won`.
Before-save flow values are validated. So after VR-6 lands, flipping that checkbox on a deal past
Underwriting becomes an error instead of a silent rewind.

The LOI→Underwriting carve-out covers the LOI case. PSA→Underwriting and later will start being
blocked. That is a genuine behaviour change to an existing checkbox — named residual, listed in §7.

### F5 — 🔴 The Lead status LWCs will show a USELESS error message unless one JS line is fixed.

`c/leadStatusChange.messageFor()` reads `error.body.message` only. When `updateRecord` fails on a
validation rule, LDS puts the platform's generic *"An error occurred while trying to update the
record. Please try again."* in `body.message` and the **rule's own text** in
`body.output.errors[0].message` / `body.output.fieldErrors`. Grep confirms **zero** occurrences of
`body.output` anywhere in `lwc/`.

⇒ Without this fix, the entire Lead half of this change is invisible to the user: they click, they
confirm, and they get a generic failure with no mention of Property Address or Email. The three-line
fix in one shared module is the difference between the feature working and the feature being
indistinguishable from a bug.

### F6 — ✅ `shouldLeadConvertRequireValidation` is `true` — Lead VRs DO fire at conversion.

`settings/LeadConfig.settings-meta.xml` line 10. This is the "Require Validation for Converted
Leads" org setting. It answers brief item (e) directly: a Lead validation rule that matches the
conversion update WILL block `Database.convertLead`.

**⚠ Two caveats, both real:** (1) `force-app/main/default/settings/**` is in `.forceignore`, so this
file is a retrieved snapshot that never deploys — it may be from a different org than the deploy
target. (2) The repo was retrieved wholesale from another org. **Verify in Setup → Lead Settings on
the target org before relying on it.**

**Also from F6:** `Lead` has **zero** validation rules today. That makes right now the cheapest
moment in the project's life to depend on (or switch on) this setting — there is nothing else it
could newly enforce.

### F7 — ✅ Two things that are already fine, so nobody spends effort on them

- **`StageAdvanceService` needs NO change.** `setStage()` already catches `DmlException` and
  rethrows `getDmlMessage(0)`, which `StageAdvanceController` surfaces verbatim to the toast. Every
  new validation-rule message reaches the Opportunity UI for free. `NEXT_STAGE` and
  `ALLOWED_EXPLICIT_TARGETS` are untouched.
- **`TestDataFactory.createLeads` already sets BOTH `Email` and `Property_Address__c`** (lines
  484/488). Most Lead conversion tests are therefore safe under the new Lead rules.

---

## 1. WHAT THE USER REQUESTED

1. Lead: block Mark Under Review / Mark Qualified / Convert unless **Property Address** and
   **Email** are filled.
2. Opportunity: four stage gates — (a) Underwriting approved → LOI, (b) LOI in place → PSA,
   (c) Contract signed → Closed Won, (d) Close Date set → About to Close.
3. Opportunity: a signed NDA required for Underwriting, LOI, PSA, About to Close **and** Closed Won
   (closing the About-to-Close shortcut hole).
4. Opportunity: block backward stage movement.

---

## 2. STAGE-RANK DECISION (brief item a) — NO NEW FIELD

**Recommendation: no `Stage_Rank__c` formula field. Inline `CASE()` in the ONE rule that needs it.**

Four reasons, the first of which is decisive:

1. **`PRIORVALUE()` cannot read a formula field.** The only rule that genuinely needs a rank is the
   backward block, and it needs the *prior* rank. A rank formula field could not supply it — the
   `CASE()` would have to be written inline for the prior side anyway, so the rank would exist in
   two places instead of one. The field buys nothing and costs duplication.
2. **Only 1 of 6 rules needs a rank.** The four forward gates each target exactly one stage;
   `ISPICKVAL(StageName,'PSA')` is more auditable than `Stage_Rank__c >= 6`.
3. **The NDA rule reads better as an explicit 5-stage list** than as a threshold — a reviewer can
   check it against the business process table by eye.
4. **A new field is not free in this repo:** FLS is not in source control (profiles are
   `.forceignore`d), so it needs a grant on every persona permission set; it needs a §1 rule-9
   naming decision; and it creates a §6 doc obligation.

**Rank map** (used only inside VR-6, twice):

| Stage | Rank | Note |
| --- | --- | --- |
| New | 1 | |
| Under Review | 2 | |
| Development Review | 3 | Land only |
| Construction Review | 3 | Commercial only — deliberately the SAME rank; they are parallel branches, not a sequence |
| Underwriting | 4 | |
| LOI | 5 | |
| PSA | 6 | |
| About to Close | 7 | |
| Closed Won | 8 | |
| **Dead/Pass** | **0** | unranked — see invariant C |
| anything else | **0** | fail-OPEN default (see below) |

**The `CASE()` default is 0 = "unranked" = do not compare.** This is a deliberate fail-open: if
someone adds a tenth stage later, an unmapped stage produces no block rather than freezing every
transition that touches it. The alternative (fail-closed) would take the whole pipeline down the
first time an admin adds a picklist value — the exact failure shape recorded in memory as
"picklist values bypass the compile checker."

⚠ **Use `TEXT(StageName)` in the CASE, never `ISPICKVAL(..., 'Dead/Pass')`.** `Dead/Pass` is stored
as `Dead%2FPass` in BusinessProcess/picklist metadata and as `Dead/Pass` at runtime. `TEXT()` is a
plain string compare and sidesteps the encoding question entirely. If any rule ever needs
`ISPICKVAL` on that value, use the DECODED form and expect to test it.

---

## 3. RECORD-TYPE AWARENESS (brief item b) — VERIFIED SAFE

Both business processes were read (`objects/Opportunity/businessProcesses/{Land,Commercial}`).
Commercial has `Construction Review` and NOT `Development Review`; Land has the inverse. All other
7 values are identical.

**No rule can fire on the wrong record type**, because the platform rejects a `StageName` value that
is not in the record type's business process *before* any validation rule evaluates it. A rule
naming `'Development Review'` simply never matches on a Commercial deal — there is no state in
which that comparison is true. Both branch stages share rank 3 so neither is "ahead of" the other.

Verified per rule in §4's table (column "RT-safe").

---

## 4. THE SIX OPPORTUNITY RULES

### VR-1 — REPLACE `NDA_Signed_Before_Underwriting` → `NDA_Signed_Before_Deal_Progression`

Closes the About-to-Close hole (user decision 3).

```
AND(
  ISCHANGED(StageName),
  OR(
    ISPICKVAL(StageName, 'Underwriting'),
    ISPICKVAL(StageName, 'LOI'),
    ISPICKVAL(StageName, 'PSA'),
    ISPICKVAL(StageName, 'About to Close'),
    ISPICKVAL(StageName, 'Closed Won')
  ),
  OR(
    ISBLANK(Primary_NDA__c),
    NOT(Primary_NDA__r.NDA_Signed__c)
  )
)
```

- `errorDisplayField`: **`StageName`** (unchanged from today — the user is acting on the stage, and
  on the Path/inline edit this renders the error exactly where they clicked).
- `errorMessage`: *"The primary NDA must be signed before this deal can move to this stage. Link a
  signed NDA (Primary NDA) first."*
- `<description>` must carry the 5-stage list and the note that it is `ISCHANGED`-scoped on purpose.

**Rename mechanics — a decision for the gate.** A ValidationRule's `fullName` IS its name in Setup,
so renaming requires **delete + create** (a destructive change in the deploy). There is no data
risk — validation rules store nothing.
- **Recommended:** rename. Keeping `..._Before_Underwriting` on a rule that gates five stages is a
  trap for the next reader, and this repo's own §1 amendment exists because stale names cost more
  than they save.
- **Fallback** (if the pipeline cannot run destructive changes): keep the `fullName`, change only
  the formula/message/description, and add a loud first line to the description.

Existing tests assert the *block*, not the rule name — `UnderwritingGateTest.ndaGateBlocksUnderwritingEntry`
and `StageAdvanceServiceTest.signedNdaGateBlocksUnderwritingAndSurfacesMessage` both keep passing
either way.

### VR-2 — NEW `Underwriting_Approved_Before_LOI` (gate a)

```
AND(
  ISCHANGED(StageName),
  ISPICKVAL(StageName, 'LOI'),
  NOT(UW_Approved__c)
)
```

- `errorDisplayField`: **`StageName`**
- `errorMessage`: *"This deal cannot enter LOI until the underwriting has been approved by the
  principals. Submit it for approval from the Underwriting stage."*

**Why this is safe against the legitimate route:** the only sanctioned way into LOI is
`Underwriting_Approval`'s `finalApprovalActions`, which fires `UW_Set_Stage_Initiate_LOI`
(`StageName = 'LOI'`) and `UW_Set_Approved_Flag` (`UW_Approved__c = true`) **in the same action
set**, i.e. the same record save. So even if F2 is wrong and approval field updates *do* run
validation rules, the flag is already true when the rule evaluates. This rule is safe under both
readings of F2 — the strongest position available.

Canary test: `UnderwritingGateTest.principalApprovalAdvancesToLoi`.

⚠ Known, accepted: `UW_Approved__c` is never cleared (`UW_Reopen_For_Revision` clears
`Underwriting_Complete__c` only), so a once-approved deal can be moved back into LOI manually
forever. Acceptable — a deal that has been principal-approved once has passed the gate this rule
exists to enforce.

### VR-3 — NEW `Approved_LOI_Before_PSA` (gate b)

```
AND(
  ISCHANGED(StageName),
  ISPICKVAL(StageName, 'PSA'),
  OR(
    ISBLANK(Primary_LOI__c),
    NOT(LOI_Approved__c)
  )
)
```

- `errorDisplayField`: **`StageName`**
- `errorMessage`: *"This deal cannot enter PSA until an approved LOI is in place. Link the primary
  LOI and complete the LOI approval first."*

**Interpretation flagged for the gate:** the user said "LOI in place". I have read that as
*"an approved LOI"* — `LOI_Approved__c` is the flag set by `LOI_Approval`'s `Set_LOI_Approved_Flag`
final action, and it is the only machine-readable meaning of "in place" in this pipeline (the LOI
approval deliberately leaves the stage at `LOI`, so the flag is the *only* evidence it happened).
If the user meant merely "a Primary LOI record exists", drop the `NOT(LOI_Approved__c)` clause —
say so at the gate.

**This is the single highest-blast-radius rule in the change** — see §6.

### VR-4 — NEW `Contract_Signed_Before_Closed_Won` (gate c)

```
AND(
  ISCHANGED(StageName),
  ISPICKVAL(StageName, 'Closed Won'),
  NOT(Contract_Signed__c)
)
```

- `errorDisplayField`: **`StageName`**
- `errorMessage`: *"This deal cannot be marked Closed Won until the contract is signed. Execute the
  PSA on the Contract Review first."*

⚠ Interacts with F3 (`Transaction_Complete_Close`). Normal path passes; manual Transactions do not.

### VR-5 — NEW `Close_Date_Before_About_To_Close` (gate d) — **CONDITIONAL ON THE F1 DECISION**

Build only if the user picks **d-1**:

```
AND(
  ISCHANGED(StageName),
  ISPICKVAL(StageName, 'About to Close'),
  CloseDate < TODAY()
)
```

- `errorDisplayField`: **`CloseDate`** — the only rule in this set whose error attaches to a field
  other than `StageName`, because `CloseDate` is the field the user must actually change and it IS
  editable on the layout.
- `errorMessage`: *"Set a current Close Date before moving this deal to About to Close — the
  current Close Date is in the past."*

If the user picks **d-2**, this rule is not built. Do not build the literal
`ISBLANK(CloseDate)` version under any circumstances (F1).

### VR-6 — NEW `No_Backward_Stage_Movement` (user decision 4)

```
AND(
  ISCHANGED(StageName),

  /* prior rank */
  CASE(TEXT(PRIORVALUE(StageName)),
    'New',1, 'Under Review',2, 'Development Review',3, 'Construction Review',3,
    'Underwriting',4, 'LOI',5, 'PSA',6, 'About to Close',7, 'Closed Won',8, 0) > 0,

  /* new rank */
  CASE(TEXT(StageName),
    'New',1, 'Under Review',2, 'Development Review',3, 'Construction Review',3,
    'Underwriting',4, 'LOI',5, 'PSA',6, 'About to Close',7, 'Closed Won',8, 0) > 0,

  /* is it backward? */
  CASE(TEXT(StageName),
    'New',1, 'Under Review',2, 'Development Review',3, 'Construction Review',3,
    'Underwriting',4, 'LOI',5, 'PSA',6, 'About to Close',7, 'Closed Won',8, 0)
  <
  CASE(TEXT(PRIORVALUE(StageName)),
    'New',1, 'Under Review',2, 'Development Review',3, 'Construction Review',3,
    'Underwriting',4, 'LOI',5, 'PSA',6, 'About to Close',7, 'Closed Won',8, 0),

  /* CARVE-OUT 1: the LOI-rejection transition (see F2) */
  NOT( AND(
    ISPICKVAL(PRIORVALUE(StageName), 'LOI'),
    ISPICKVAL(StageName, 'Underwriting')
  )),

  /* CARVE-OUT 2: admin/data-fix escape hatch — OPTIONAL, see below */
  NOT( $Permission.Bypass_Stage_Backward_Block )
)
```

- `errorDisplayField`: **`StageName`**
- `errorMessage`: *"A deal cannot be moved back to an earlier stage. To stop work on this deal, move
  it to Dead/Pass instead."* — the message names the escape hatch, which is what makes invariant C
  usable rather than merely true.

**Carve-out 2 — the bypass custom permission. Recommend YES.** It is new metadata
(`customPermissions/Bypass_Stage_Backward_Block` + assignment to an admin permission set), so it is
scope the user did not literally ask for — but the brief explicitly listed "a bypass custom
permission" as a lever to evaluate. My reasoning for recommending it: a hard backward block **will**
strand a deal that was advanced by mistake, and without a bypass the only remedy is deactivating the
validation rule org-wide — which removes the protection from every deal to fix one. If the user
declines it, VR-6 still works; the recovery procedure just becomes "deactivate, fix, reactivate."

**Invariants verified against VR-6:**
- Entering `Dead/Pass` → new rank 0 → clause 3 (`new rank > 0`) is false → rule never fires. ✅
- Leaving `Dead/Pass` (reviving a passed deal) → prior rank 0 → clause 2 is false → allowed. ✅
- Land ↔ Commercial branch stages both rank 3, and neither is reachable on the other record type. ✅
- A future unmapped stage → rank 0 on whichever side → allowed (fail-open by design). ✅

---

## 5. THE TWO LEAD RULES + THE LWC FIX

### VR-L1 — NEW `Property_And_Email_Required_To_Progress` (Under Review / Qualified)

```
AND(
  ISCHANGED(Status),
  NOT(IsConverted),
  OR(
    ISPICKVAL(Status, 'Under Review'),
    ISPICKVAL(Status, 'Qualified')
  ),
  OR(
    ISBLANK(Property_Address__c),
    ISBLANK(Email)
  )
)
```

- `errorDisplayField`: **`Status`** — the field being changed, and the only one of the two required
  fields that is guaranteed present on both the layout and the Path. Attaching to
  `Property_Address__c` would highlight the wrong field whenever `Email` is the missing one.
- `errorMessage`: *"Property Address and Email are both required before this lead can move forward.
  Fill them in on the lead first."* — names both fields explicitly so one message covers both cases.

**Disqualified is deliberately NOT gated** — it is the Lead's `Dead/Pass`. A junk lead with no
address must always be disqualifiable, or the same trap invariant C exists to prevent on Opportunity
is reintroduced on Lead. `Converted` is not in the list either (see VR-L2).

**`NOT(IsConverted)` is a defensive guard, not the primary one.** The `ISPICKVAL` list already
excludes `Converted`, so the rule is structurally inert at conversion. The guard exists so a future
edit that adds a status to the list cannot accidentally start blocking conversions.

### VR-L2 — NEW `Property_And_Email_Required_To_Convert` — **DECISION REQUIRED**

This is brief item (e), the highest-risk item in the change. Two mechanisms; pick one.

```
AND(
  ISCHANGED(IsConverted),
  IsConverted,
  OR(
    ISBLANK(Property_Address__c),
    ISBLANK(Email)
  )
)
```

- `errorDisplayField`: **`Status`**
- `errorMessage`: *"Property Address and Email are both required before this lead can be converted."*

| | **Option 1 — VR-L2 (declarative) ✅ RECOMMENDED** | Option 2 — Apex pre-check |
| --- | --- | --- |
| Mechanism | Lead VR, enforced at conversion by `shouldLeadConvertRequireValidation` (F6) | check in `LeadConvertActionService.convert()` before `Database.convertLead` |
| Depends on an org setting? | **Yes** — verify in Setup → Lead Settings | No |
| Covers the standard Convert button / API / Flow? | **Yes** | **No** — only the custom quick action |
| Code changes | none | new `LeadSelector` method, new typed exception, new catch tier in `LeadConvertActionController`, test updates |
| Error surfaced to the user | Clean. `Database.convertLead` throws `DmlException`; `LeadConvertActionController`'s **existing** DmlException tier surfaces `e.getMessage()` verbatim to the toast | Clean, via a new tier |
| Failure mode if the assumption breaks | Fails **open** silently (no gate) | n/a |

**Is a mid-conversion failure dangerous?** No, and this is worth stating precisely because the brief
flagged it. Validation rules evaluate **before** after-update triggers in the order of execution, so
if VR-L2 fires, `LeadConvertTrigger` → `LeadConvertService` never runs at all. `Database.convertLead`
is called single-argument (all-or-none), so the whole conversion rolls back cleanly. There is no
partial-conversion state to clean up. The risk is "the conversion is refused", not "the conversion
half-happens."

**If the setting turns out to be OFF:** turning it ON is a one-click org setting and is *unusually*
safe right now, because Lead currently has **zero** validation rules — there is nothing else it could
newly enforce (F6). That is the recommended remedy over building Option 2.

### 🔴 LEAD DATA-POPULATION WARNING — count these before deploying

Broker Protection **deliberately creates Leads with a null `Property_Address__c`.** ARCHITECTURE.md
§1 documents branch (c) of the routing tree: an email that names a property with no usable address
produces a Lead with outcome label `'New Lead (property, no address)'`, and
`ExtractAddressQueueable`'s `claimableAddress()` guard holds `Property_Address__c` null **on
purpose** (it encodes the invariant that the field only ever holds an address that could produce a
claim key). `ExtractAddressQueueableTest` pins this with `Assert.isNull(...)`.

Under VR-L1/VR-L2 that entire population becomes **unable to progress** until a human types the
address. That is arguably the intended outcome — ARCHITECTURE.md says the label exists "so a human
can list them and chase the address", and this change turns that from a suggestion into an
enforcement. **But it is a live behaviour change against an existing backlog.** Run this before
deploy and show the user the number:

```sql
SELECT COUNT() FROM Lead
WHERE IsConverted = false
  AND Status NOT IN ('Disqualified','Converted')
  AND (Property_Address__c = null OR Email = null)
```

### LWC-1 — FIX `c/leadStatusChange.messageFor()` (brief item f) — REQUIRED, not optional

Per F5, without this the Lead rules produce a generic, unhelpful error and the feature looks broken.
The fix is confined to one function in one shared module:

```js
function messageFor(error, fallback) {
    const body = error && error.body;
    const output = body && body.output;
    const pageError = output && output.errors && output.errors[0] && output.errors[0].message;
    const fieldError = /* first message in output.fieldErrors, if any */;
    return pageError || fieldError || (body && body.message) || fallback || GENERIC_ERROR;
}
```

Benefits every existing error path in all four Lead quick actions, not just this change. Its Jest
suite (`lwc/leadStatusChange/__tests__/leadStatusChange.test.js`) already exists and needs two new
cases (page-level error shape, field-level error shape).

### Client-side PRE-CHECK — **RECOMMEND NOT BUILDING IT** (brief item f)

The brief asks whether `c/leadStatusChange` should also pre-check the fields before the confirm
dialog. My recommendation is **no, for v1**:

1. **ARCHITECTURE.md §5's ordering rule is about PERMISSION, not data readiness.** "Never ask a user
   to confirm an action they are not permitted to take" — a missing field is not a permission
   problem, and every other save in the platform reports missing data after the attempt.
2. **It duplicates the business rule in JS, where it will drift.** This repo already has a written
   precedent for exactly this refusal: ARCHITECTURE.md §5 on `advanceDealStage` — *"Do NOT `@wire
   getRecord` the stage and compute a nicer label — that duplicates the `NEXT_STAGE` map in JS,
   where it will drift from the Apex."* Same shape, same answer.
3. **A headless quick action cannot read the record cleanly.** It has no template and the platform
   calls `invoke()` immediately on click, so an `@wire(getRecord)` is very likely unresolved at
   click time. Doing it properly means a *second* Apex round trip on every click, on top of the
   `hasLeadActionAccess` call the guard already makes.
4. **With LWC-1 the user experience is already correct**: click → confirm → *"Property Address and
   Email are both required before this lead can move forward."*

If the user still wants the pre-confirm check, it is an additive change later; nothing here blocks
it. It is listed as optional in the prompts below.

---

## 6. BLAST RADIUS (brief item h)

### Metadata created / modified

| Item | Type | Change |
| --- | --- | --- |
| `Opportunity.NDA_Signed_Before_Deal_Progression` | ValidationRule | REPLACES `NDA_Signed_Before_Underwriting` (delete + create; fallback = edit in place) |
| `Opportunity.Underwriting_Approved_Before_LOI` | ValidationRule | NEW |
| `Opportunity.Approved_LOI_Before_PSA` | ValidationRule | NEW |
| `Opportunity.Contract_Signed_Before_Closed_Won` | ValidationRule | NEW |
| `Opportunity.Close_Date_Before_About_To_Close` | ValidationRule | NEW — **only under decision d-1** |
| `Opportunity.No_Backward_Stage_Movement` | ValidationRule | NEW |
| `Lead.Property_And_Email_Required_To_Progress` | ValidationRule | NEW |
| `Lead.Property_And_Email_Required_To_Convert` | ValidationRule | NEW — only under Option 1 |
| `Bypass_Stage_Backward_Block` | CustomPermission | NEW — only if the bypass is approved |
| admin permission set | PermissionSet | + the custom permission, if approved |

**No new fields. No new objects. No Flow changes. No approval-process changes.**

### Apex / LWC

| Component | Change |
| --- | --- |
| `StageAdvanceService` | **NONE.** `NEXT_STAGE` unchanged, `ALLOWED_EXPLICIT_TARGETS` unchanged. `setStage()`'s existing `DmlException` catch already surfaces each new rule's message verbatim (F7). |
| `StageAdvanceController` / `OpportunityApprovalController` | **NONE.** |
| The 5 Opportunity LWC bundles | **NONE.** |
| `c/leadStatusChange` | **1 function** — `messageFor()` (LWC-1). |
| `LeadConvertActionService` / `Controller` | **NONE** under Option 1. Under Option 2: new pre-check + selector + exception tier. |
| `TestDataFactory` | **NEW helpers** (see below). |

### Apex test classes AT RISK — enumerated

**Category A — WILL FAIL. Confirmed by reading the code.**

| # | Class · method | Transition | Broken by | Fix |
| --- | --- | --- | --- | --- |
| 1 | `ContractExecutionServiceTest.dealAtPsa()` (2 call sites, lines 10–15 and 120–125) — **used by every test in the class** | insert `LOI` → **update `PSA`** | VR-3 | approve an LOI on the fixture before the PSA update |
| 2 | `ContractReviewTriggerHandlerTest` (lines 13–15, 48–52) | insert `LOI` → **update `PSA`** | VR-3 | same |
| 3 | `OpportunityDocStatusControllerTest.returnsAllDealArtifacts` (12–16) | insert `Development Review` → **update `PSA`** | VR-3 **and** VR-1 (it signs the NDA *after* the PSA move) | sign NDA + approve LOI **before** the stage move |
| 4 | `OpportunityReviewServiceTest.contractReviewCreatesOnUpdate` (147–152) | insert `Under Review` → **update `PSA`** | VR-3 + VR-1 | same |
| 5 | `OpportunityReviewServiceTest.noDuplicateOnReentry` (170–178) | `Development Review` → **`Under Review`** (rank 3→2) | **VR-6 backward block** | re-route the "move away" hop forward, or use `Dead/Pass` and back (which VR-6 permits) |
| 6 | `StageAdvanceServiceTest.advanceMovesLoiToPsaAndPsaToClosedWon` (56–69) | `LOI`→`PSA`, `PSA`→`Closed Won` | VR-3 + VR-4 + VR-1 | prepare both fixtures |
| 7 | `StageAdvanceServiceTest.advanceToAcceptsEveryAllowedExplicitTarget` (205–241) | `PSA` → **`About to Close`** | VR-1 (auto-created NDA is `Pending`) | sign the NDA on `psaDeal`. ✅ The `Dead/Pass` leg in the same test is a live assertion of invariant C — leave it alone, it should keep passing untouched |
| 8 | `StageAdvanceControllerTest.advanceToPsaMovesLoiToPsa` (82–90) | `LOI`→`PSA` | VR-3 + VR-1 | prepare fixture |
| 9 | `StageAdvanceControllerTest.closeDealMovesPsaToClosedWon` (93–101) | `PSA`→`Closed Won` | VR-4 + VR-1 | prepare fixture |

**Category B — MUST BE RE-VERIFIED (stage writes present; insert-vs-update not confirmed by reading)**

`OpportunityApprovalControllerTest` (lines 18, 58, 75, 137, 183) · `OpportunityFunnelControllerTest`
(11, 114–116) · `PsaVersionControllerTest` (20) · `PsaVersionServiceTest` (22) ·
`DealMessageControllerTest` · `ProcessInstanceSelectorTest` (34) · `ProcessInstanceStepSelectorTest`
(39) · `UnderwritingGateTest` (28, 36, 138).

**Category C — CANARIES. These must stay green; if they go red, a design assumption is wrong.**

| Class · method | What it proves |
| --- | --- |
| `LoiGateTest.rejectionReturnsDealToUnderwriting` | **F2** — approval field updates bypass validation rules. If this reds after VR-6 lands, F2 is false and the LOI→Underwriting carve-out is doing real work (which is fine) — but re-check every other approval interaction |
| `UnderwritingGateTest.principalApprovalAdvancesToLoi` | VR-2 does not block the approval's own `StageName = 'LOI'` write |
| `UnderwritingGateTest.ndaGateBlocksUnderwritingEntry` | VR-1's rename/rewrite preserved the original Underwriting gate |
| `StageAdvanceServiceTest.signedNdaGateBlocksUnderwritingAndSurfacesMessage` | the rule message still reaches the LWC boundary via `getDmlMessage(0)` |

**Category D — SAFE. Verified, no action.**

- `BrokerFirmControllerTest` — sets `Closed Won` / `Dead/Pass` **before insert** (lines 40–46,
  91–95). `ISCHANGED()` is false on insert, so no rule fires.
- `LoiGateTest`, `PsaVersion*`, `ProcessInstance*Test` insert *at* LOI rather than moving into it.
- All Broker Protection tests (`ExtractAddressQueueableTest`, `EmailToLeadServiceTest`,
  `PropertyClaimServiceTest`) — they insert Leads and never change `Status`, so VR-L1 (`ISCHANGED(Status)`)
  cannot fire.
- Every conversion test built on `TestDataFactory.createLeads` — the factory already supplies both
  `Email` and `Property_Address__c` (F7).

**Category E — conversion-path classes to re-run if VR-L2 lands** (expected green because of the
factory, but any fixture that *deliberately* builds an address-less Lead and converts it will fail):
`LeadConvertActionServiceTest`, `LeadConvertActionControllerTest`, `LeadConvertServiceTest`,
`LeadConvertMatchServiceTest`, `LeadConvertTriggerHandlerTest`, `AccountSelectorTest`,
`ContactSelectorTest`, `LeadSelectorTest`, `OpportunityContactRoleSelectorTest`,
`PropertyClaimServiceTest`.

### `TestDataFactory` additions (the cleanest fix for Category A)

Rather than 9 ad-hoc patch-ups, add four named helpers so the intent is legible and the next gate
change has one place to update:

```apex
signPrimaryNda(Opportunity o)      // flips the auto-created Primary NDA to Signed
approveUnderwriting(Opportunity o) // UW_Approved__c = true
placeApprovedLoi(Opportunity o)    // creates an LOI, stamps Primary_LOI__c, LOI_Approved__c = true
signContract(Opportunity o)        // Contract_Signed__c = true (+ Contract_Executed_Date__c)
```

---

## 7. RESIDUAL RISKS — stated, not hidden

| # | Risk | Severity | Disposition |
| --- | --- | --- | --- |
| R1 | **`ISCHANGED`-only scoping leaves an INSERT hole.** None of the 7 rules fire on insert, so an Opportunity can be *created* directly at `Closed Won` with no NDA, and a Lead can be created at `Qualified` with no address. Data Loader, the API, and the New Opportunity form all reach this. | Medium | **Accept for v1.** Brief item (d) mandates transition scoping, and the existing NDA rule has the same hole deliberately. Adding `OR(ISNEW(), ISCHANGED(...))` would break every Category-D test that inserts at a late stage (~8 classes) and is a separate, larger change. Flag to the user as a known-open. |
| R2 | **`Transaction_Complete_Close` (F3) can now fail and roll back a Transaction save.** | Medium | Accept + monitor. Normal path is safe (`Contract_Signed__c` is stamped by the same service that creates the Transaction). UAT step: close a Transaction end-to-end. |
| R3 | **`Opportunity_Initiate_Underwriting` (F4) backward rewinds from PSA+ start erroring.** | Medium | Accept — that rewind is exactly what decision 4 asks to stop. Behaviour change to an existing checkbox; must be in the release note. |
| R4 | **Manual `LOI → Underwriting` remains possible** (the VR-6 carve-out cannot distinguish a human from the approval). | Low | Accept. Arguably desirable — it mirrors what a rejection does, and a deal-driver reworking terms should be able to do it. |
| R5 | **F2 (VRs skip approval field updates) is evidenced by a green test, not by a live measurement in the deploy target.** | Medium | **Verify before deploy** — the 2-minute procedure is in F2. VR-2 is safe either way; VR-1 and VR-6 depend on it for the LOI-rejection path (and VR-6 carries an explicit carve-out for exactly that). |
| R6 | **F6 (`shouldLeadConvertRequireValidation`) comes from a `.forceignore`d snapshot.** If it is OFF in the target org, VR-L2 silently does nothing — fails **open**. | Medium | **Verify in Setup → Lead Settings.** Remedy: turn it on (safe today — Lead has zero VRs) or switch to Option 2. |
| R7 | **A Broker Protection backlog of address-less Leads becomes frozen.** | Medium | Count first (query in §5), show the user, then decide whether to backfill or accept. |
| R8 | **Rank drift.** Adding a 10th stage means editing VR-6's `CASE` (4 places in one formula) and VR-1's stage list. | Low | Documented in both `<description>`s. The fail-open default (rank 0) means forgetting is permissive, not catastrophic. |
| R9 | **`Close_Deal` is already unreachable from `About to Close`.** Its visibility rule on `Opportunity_Record_Page` is `StageName EQUAL PSA` only, yet `NEXT_STAGE` maps `About to Close => Closed Won`. A deal parked at About to Close has no button to close it. | Low | **Pre-existing defect, found during recon. NOT in scope — flagged for a separate decision.** VR-6 makes it worse (the deal can no longer be walked back to PSA to use the button), so it should be decided at the same gate. |

### Can a true backward block be made safe here? — the brief's direct question

**Yes.** Not because backward blocking is inherently safe, but because of two specific, verified
facts about this org:

1. Approval-driven backward movement happens in exactly **one** place — `LOI_Approval`'s
   `finalRejectionActions` → `Set_Stage_Underwriting` — and validation rules do not run on it (F2).
2. Even if (1) is wrong, that transition is a single, nameable `PRIORVALUE(StageName)='LOI' →
   StageName='Underwriting'` pair, which VR-6 carves out explicitly.

The lever I recommend is therefore **`PRIORVALUE` carve-out of the one known transition**, plus the
optional custom-permission bypass as an operational escape hatch. I did **not** recommend keying off
approval-stamp fields (`UW_Approved__c` etc.) — those are set-once and never cleared, so they cannot
distinguish "an approval just did this" from "an approval did this three weeks ago", which is the
distinction the rule needs.

The price is R3 and R4, both named above. Neither is a correctness hazard; both are behaviour
changes that a release note covers.

---

## 8. EXECUTION ORDER

1. **Gate decisions** (§9) — especially F1 (gate d), VR-3's "LOI in place" reading, VR-L2's
   mechanism, the bypass permission, and the VR-1 rename.
2. **Two in-org verifications** — F2 (approval rejection) and F6 (Lead Settings). Both are read-only
   / 2 minutes. **Do not deploy before these.**
3. **Count the affected Lead backlog** (query in §5) and show the user.
4. **Admin work** — the validation rules (+ custom permission if approved). Deploy with rules
   **INACTIVE** if the team wants a staged cutover.
5. **Dev work** — `TestDataFactory` helpers → Category A test fixes → LWC-1 + its Jest cases.
   Must land in the same deploy as the rules or `RunLocalTests` fails.
6. **Code review**, then deploy, then activate.
7. **UAT as a real deal-driver persona, not an admin** (memory: an admin smoke test proves nothing
   about `Deal_Driver__c`-gated UI, and FLS truth lives in the org, not this repo).

---

## 9. DECISIONS NEEDED AT THE GATE

| # | Question | My recommendation |
| --- | --- | --- |
| D1 | **Gate (d) is unbuildable as stated (F1).** `CloseDate < TODAY()` (d-1), or drop it (d-2)? | **d-1** |
| D2 | VR-3: does "LOI in place" mean an **approved** LOI (`LOI_Approved__c`) or merely a linked one (`Primary_LOI__c`)? | **approved** |
| D3 | VR-L2 mechanism: declarative (Option 1, depends on the org setting) or Apex (Option 2)? | **Option 1** |
| D4 | Build the `Bypass_Stage_Backward_Block` custom permission? | **Yes** |
| D5 | VR-1: rename to `NDA_Signed_Before_Deal_Progression` (destructive change) or edit in place and keep the stale name? | **rename** |
| D6 | Add the client-side pre-check to `c/leadStatusChange` on top of LWC-1? | **No for v1** |
| D7 | R1 (the INSERT hole) — accept for v1? | **Accept**, tracked as known-open |
| D8 | R9 (`Close_Deal` unreachable from `About to Close`) — pre-existing defect found during recon. Fix now, or separate ticket? | **Separate ticket**, but decide now because VR-6 makes it harder to work around |

---

## 10. PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR salesforce-admin

```
Create validation rules on Opportunity and Lead exactly as specified in
agent-output/design-requirements-stage-validations.md §4 and §5. Do not add rules, fields,
permission sets, or layout changes beyond what is listed there.

Follow .claude/rules/salesforce-global-rule.md: record the skill-selection line, load the
ValidationRule metadata skill, and attempt salesforce-api-context for the ValidationRule type
(and for CustomPermission separately, if D4 is approved) before writing any file. API version 67.0,
package dir force-app/main/default.

CREATE on Opportunity (objects/Opportunity/validationRules/):
  1. NDA_Signed_Before_Deal_Progression   — §4 VR-1
  2. Underwriting_Approved_Before_LOI     — §4 VR-2
  3. Approved_LOI_Before_PSA              — §4 VR-3
  4. Contract_Signed_Before_Closed_Won    — §4 VR-4
  5. Close_Date_Before_About_To_Close     — §4 VR-5  [ONLY IF decision D1 = d-1]
  6. No_Backward_Stage_Movement           — §4 VR-6

DELETE on Opportunity [ONLY IF decision D5 = rename]:
  objects/Opportunity/validationRules/NDA_Signed_Before_Underwriting.validationRule-meta.xml
  (destructive change — flag it explicitly for the devops agent; there is no data risk)

CREATE on Lead (objects/Lead/validationRules/ — this directory does not exist yet):
  7. Property_And_Email_Required_To_Progress  — §5 VR-L1
  8. Property_And_Email_Required_To_Convert   — §5 VR-L2  [ONLY IF decision D3 = Option 1]

CREATE [ONLY IF decision D4 = yes]:
  customPermissions/Bypass_Stage_Backward_Block + add it to the admin permission set

Copy every errorConditionFormula, errorMessage and errorDisplayField VERBATIM from the design doc.
Write the stated rationale into each rule's <description> — in particular:
  - VR-1 and VR-6 must record their stage list / rank map and the note that a future stage means
    editing them.
  - VR-6 must record WHY the LOI->Underwriting carve-out exists (approval rejection) and that the
    CASE default of 0 is a deliberate fail-open.
  - VR-L1 must record that Disqualified is deliberately ungated.

Two things that will bite:
  - Use TEXT(StageName) inside CASE(). Never write ISPICKVAL(..., 'Dead/Pass') — that value is
    Dead%2FPass in picklist metadata and Dead/Pass at runtime.
  - If the ISPICKVAL literals in VR-1/VR-2/VR-3/VR-4 are rejected at deploy, fall back to
    TEXT(StageName) = '<value>'.

Do NOT deploy. Create the metadata files only.
```

### 🟢 PROMPT FOR salesforce-developer

```
Two pieces of work supporting the validation rules in
agent-output/design-requirements-stage-validations.md. Do not add scope beyond this.

(1) TestDataFactory helpers (§6). Add four public static helpers to
force-app/main/default/classes/TestDataFactory.cls, following the file's existing Javadoc and
insertIf conventions:
      signPrimaryNda(Opportunity o)
      approveUnderwriting(Opportunity o)
      placeApprovedLoi(Opportunity o)
      signContract(Opportunity o)
    Each prepares a fixture Opportunity to legitimately pass one of the new gates. Note
    OpportunityReviewService.ensureNda already auto-creates a Pending NDA and stamps
    Primary_NDA__c on every insert — signPrimaryNda must SIGN that existing record, not insert a
    rival NDA (see OpportunityDocStatusControllerTest lines 18-25 for the established pattern).

(2) Fix the nine Category-A test methods listed in §6 so each fixture satisfies the gate it now
    crosses, using the new helpers. The list is exact — do not change any other test.
    ⚠ StageAdvanceServiceTest.advanceToAcceptsEveryAllowedExplicitTarget: sign the NDA on psaDeal
    ONLY. Its Dead/Pass leg is a live assertion of the "Dead/Pass is always reachable" invariant —
    leave that leg exactly as it is.
    ⚠ OpportunityReviewServiceTest.noDuplicateOnReentry currently moves a deal BACKWARD
    (Development Review -> Under Review) as its "move away" step. That is what the new backward
    block forbids. Re-route it — Dead/Pass and back is permitted by design and is the honest fix.

(3) LWC fix (§5, LWC-1). In force-app/main/default/lwc/leadStatusChange/leadStatusChange.js,
    change ONLY messageFor() so it prefers error.body.output.errors[0].message, then the first
    message in error.body.output.fieldErrors, then error.body.message, then the fallback. This is
    what makes a validation-rule message reach the toast — today LDS puts the rule text in
    body.output and the function reads only body.message, so the user would see a generic error.
    Add two Jest cases to lwc/leadStatusChange/__tests__/leadStatusChange.test.js: page-level error
    shape and field-level error shape. Do NOT add a client-side field pre-check (design decision D6).

DO NOT touch StageAdvanceService (NEXT_STAGE and ALLOWED_EXPLICIT_TARGETS are unchanged — its
existing DmlException catch already surfaces each new rule's message), StageAdvanceController, the
Opportunity LWC bundles, LeadConvertActionService or LeadConvertActionController.

Run the full Apex suite plus Jest. Both must be green before handoff — the Category-B classes in
§6 have stage writes I could not classify by reading, so treat any failure there as expected work,
not a surprise.
```

### 🔴 PRE-DEPLOY VERIFICATION (for salesforce-devops / the user — do this BEFORE deploying)

```
1. F2 — approval rejection: on the target org, create a deal, move it to LOI leaving the
   auto-created NDA unsigned, submit the LOI approval, reject it. Confirm the stage lands on
   Underwriting with no error. (This is the assumption that lets a backward block be safe at all.)
2. F6 — Setup -> Lead Settings -> "Require Validation for Converted Leads". Confirm it is ON.
   settings/** is .forceignore'd, so the repo's copy is a snapshot and may not reflect this org.
3. Count the frozen Lead backlog:
   SELECT COUNT() FROM Lead WHERE IsConverted = false
     AND Status NOT IN ('Disqualified','Converted')
     AND (Property_Address__c = null OR Email = null)
4. Post-deploy UAT: run every stage transition as a REAL deal-driver persona, not as an admin.
   Include one end-to-end Transaction close (risk R2) and one Dead/Pass from a mid-pipeline stage
   (invariant C).
```
