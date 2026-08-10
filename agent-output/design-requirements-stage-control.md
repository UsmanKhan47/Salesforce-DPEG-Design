# Design Requirements — Stage Control on Six Child Objects

**Date:** 2026-08-04
**Scope:** `NDA__c`, `LOI__c`, `Underwriting__c`, `Construction_Feasibility_Review__c`,
`Development_Feasibility_Review__c`, `Lease__c` (+ `Opportunity_Record_Page` /
`Lead_Record_Page` Path-button change)
**Status:** awaiting Gate 1 confirmation

---

## 0. What the user asked for (verbatim)

> "I want to remove these quick actions button and bring our quick actions just like we did for
> Lead and Opportunity. Make sure to follow the same strategy on Lease, Construction, Development,
> Underwriting, LOI as well. We need to have complete control on stage change so we can implement
> validation rules."

The button in question is the Path component's **"Mark Status as Complete"** on the NDA record page.

User decisions already taken at the gate:

1. Remove the orphan picklist values.
2. All six objects in one program.
3. `Opportunity_Record_Page` and `Lead_Record_Page` also get `hideUpdateButton = true`.

---

## 1. 🔴 FOUR CORRECTIONS TO THE BRIEF — read before anything else

Everything below was verified against the repo on 2026-08-04. Three of these change the plan.

### C1. The approval-process premise is wrong, and it inverts finding (f)

> Brief: "`LOI__c` and `Underwriting__c` have approval processes in this org, and on Opportunity
> the approval-driven stage write bypasses validation rules."

**Neither object has an approval process.** The repo holds exactly two, both on **Opportunity**:

- `approvalProcesses/Opportunity.LOI_Approval.approvalProcess-meta.xml`
- `approvalProcesses/Opportunity.Underwriting_Approval.approvalProcess-meta.xml`

Both have `entryCriteria` on `Opportunity.StageName`. They are named after the deal *stage*, not
after the child object. The `Submit_for_Approval` quick actions on the LOI and Underwriting record
pages resolve the **parent Opportunity Id** (`OpportunityApprovalController` →
`UnderwritingSelector.selectOpportunityIdRequiredById`) and submit *that*.

**Consequence — the opposite of what the brief assumed.** There are no approval field updates on
these six objects, so the "approval field updates don't fire VRs" protection **does not exist here**.
What *does* reach them is `ApprovalAuditService` — see §7. It writes via **Apex DML**, which fires
validation rules normally.

### C2. There are 14 orphan values, not 12 — and they are already INACTIVE

Verified in the three `Stage__c.field-meta.xml` files. Every one already carries
`<isActive>false</isActive>`, so **none of them can be selected today**. The change is
deactivated → deleted, i.e. a tidy-up, not a control.

Two entries in the brief's list are mis-merged: `Go / Conditional No-Go` is **two separate values**,
`Go / Conditional` and `No-Go`, on both feasibility objects.

| Object (field) | Inactive values | Count |
| --- | --- | --- |
| `Underwriting__c.Stage__c` | Complete, Data Collection, Modeling, Review | 4 |
| `Construction_Feasibility_Review__c.Stage__c` | GC / Vendor Proposals, **Go / Conditional**, **No-Go**, Opinion to Acquisition, Opinion to Junior, Scope & Cost Review | 6 |
| `Development_Feasibility_Review__c.Stage__c` | **Go / Conditional**, **No-Go**, Opinion to Acquisition, Opinion to Junior | 4 |
| | **Total** | **14** |

`NDA__c.Status__c` (3 values), `LOI__c.Stage__c` (5 values) and `Lease__c.Stage__c` (3 values) have
**zero** orphans — their picklists already match their Paths exactly.

### C3. Deleting `No-Go` forecloses the only ready-made off-ramp name

See §6. **None of the six objects has an off-ramp stage.** `No-Go` on the two feasibility Stage
picklists is the only off-ramp-shaped value that already exists. Sequence the off-ramp decision
**before** the picklist deletion, or you will delete it and re-add it.

### C4. Hiding the Path button on `Lead_Record_Page` buys no control

Decision 3 was framed as "the Path button offers a route around the quick actions and their
server-side assertions." That is true on Opportunity. On **Lead** it is not: the three status quick
actions (`leadMarkUnderReview` / `leadMarkQualified` / `leadDisqualify`) write via LDS
`updateRecord` with **no Apex in the path at all** — only `Convert` has a server-side assert. So on
Lead there is no assertion for the Path button to bypass. Hiding it is legitimate UX consistency;
it is not a security change. Recommend keeping decision 3, with the reason restated honestly.

---

## 2. VERIFIED BASELINE (do not re-derive)

### 2.1 Path-declared stage sequences — all six are LINEAR (no branches)

| Object | Field | Sequence | Restricted? | Field `required`? |
| --- | --- | --- | --- | --- |
| `NDA__c` | **`Status__c`** | Pending → Sent → Signed | ✅ yes | no |
| `LOI__c` | `Stage__c` | Draft → Prepare/Review → Sent → Counter → Completed | ✅ yes | no |
| `Lease__c` | `Stage__c` | Draft → Prepare/Review → Completed | ⛔ **NO** | ⛔ **YES** |
| `Underwriting__c` | `Stage__c` | Requested → In Progress → Approved → Completed | ✅ yes | no |
| `Construction_FR__c` | `Stage__c` | Requested → Site Visit → Condition Assessment → Cost Estimate → Share Opinion → Completed | ✅ yes | no |
| `Development_FR__c` | `Stage__c` | Requested → Feasibility analysis → Vendor proposals → Share Opinion → Completed | ✅ yes | no |

Two facts in that table drive design decisions:

- **`NDA__c` uses `Status__c`, the other five use `Stage__c`.** The generic component must carry the
  field name per object; it cannot hardcode `Stage__c`.
- **`Lease__c.Stage__c` is UNRESTRICTED and universally required.** Unrestricted means the API can
  write an arbitrary string into it today. Required means it cannot be made read-only on the
  layout (§5). It is the outlier on both counts.

Every path is a straight line. **There is no equivalent of Opportunity's Land/Commercial branch**,
so the generic feature needs only a single `advance()` per object — no `advanceTo` explicit-target
method, no allow-list. That is a large simplification versus the Opportunity feature.

### 2.2 Path button state

All eight relevant flexipages currently carry `hideUpdateButton = false`:

`NDA_Record_Page`(:33), `LOI_Record_Page`(:48), `Underwriting_Record_Page`(:48),
`Lease_Record_Page`(:17), `Construction_Feasibility_Review_Record_Page`(:33),
`Development_Feasibility_Review_Record_Page`(:33), `Opportunity_Record_Page`(:221),
`Lead_Record_Page`(:94).

### 2.3 The pattern is already HALF-BUILT on two of the six

`LOI__c` and `Underwriting__c` record pages already use **Dynamic Actions** on the Highlights
Panel, with the exact Opportunity visibility rule:

```xml
<value>Underwriting__c.Submit_for_Approval</value>
<visibilityRule><criteria>
  <leftValue>{!$User.Deal_Driver__c}</leftValue><operator>EQUAL</operator><rightValue>true</rightValue>
</criteria></visibilityRule>
```

Those quick actions run the shared `c/dealActionGuard` → `OpportunityActionPermissionService`
two-factor gate, and `OpportunityApprovalController.submitForApproval` asserts it server-side.
**The deal-driver gate is already live on two of these six objects.** That is the single strongest
argument for the permission decision in §4.

`NDA_Record_Page`, `Lease_Record_Page` and the two feasibility pages do **not** use Dynamic Actions
— they inherit the layout's `platformActionList`. Migrating them is a destructive UI change (§8, R2).

### 2.4 Every stage writer in the app, enumerated

| Writer | Objects touched | Insert or Update | Fires a VR? |
| --- | --- | --- | --- |
| `OpportunityReviewService` (`OpportunityReviewTrigger`) | NDA (`Pending`), Underwriting (`Requested` + `Status__c='In Progress'`), Con FR (`Requested`), Dev FR (`Requested`) | **INSERT** | yes, but an `ISCHANGED`-scoped rule never fires on insert ✅ |
| `Lease_Inquiry_Create_Lease` Flow | `Lease__c` (`Stage__c='Draft'`) | **INSERT** | same ✅ |
| **`ApprovalAuditService`** (`@InvocableMethod` from an after-save Flow) | **`Underwriting__c.Stage__c='Approved'` + `Status__c='Approved by Principals'`**; `LOI__c.LOI_Status__c='Approved'` | **UPDATE** | 🔴 **YES — and the `DmlException` is SWALLOWED.** See §7 |
| `NDA_Signed_Status_Sync` Flow | reads `NDA__c.Status__c=='Signed'`, stamps `NDA_Signed__c`/`Date_Signed__c` | does not write the status | ✅ (verify `triggerType` before deploy) |
| `Con_Review_Opinion_Notify` / `Dev_Review_Opinion_Notify` Flows | notification only, filter on `Recommendation__c` | no record write | ✅ |
| `Underwriting_Opp_Sync` Flow | writes **Opportunity** mirrors | n/a | ✅ |
| The new generic stage service | all six | UPDATE | yes — intended, message surfaces (§5) |
| Path button / inline edit / list view / API | all six | UPDATE | yes |

### 2.5 Selectors already exist for all six

`NdaSelector`, `LoiSelector`, `UnderwritingSelector`, `LeaseSelector`,
`ConstructionFeasibilityReviewSelector`, `DevelopmentFeasibilityReviewSelector`. Each needs **one**
new method. No new selector classes.

### 2.6 The picklist sweep (STANDING RULE — run before removal)

Swept: `classes/`, `flows/`, `pathAssistants/`, `flexipages/`, `layouts/`, `objectTranslations/`,
`quickActions/`, `reports/`, `scripts/`, `docs/`.

| Reference found | Verdict |
| --- | --- |
| `pathAssistants/Construction_Feasibility_Path` line 24 — "set the Go / Conditional / No-Go recommendation" | **PROSE inside `<info>`**, not a `<picklistValueName>`. Does not block deletion. |
| `pathAssistants/Development_Feasibility_Path` line 20 — same phrase | same ✅ |
| `flexipages/Development_Feasibility_Review_Record_Page` line 352 — same phrase in a `richText` | same ✅ |
| `Construction_FR__c.Recommendation__c` / `Development_FR__c.Recommendation__c` | 🔴 **DIFFERENT FIELD.** `Go / Conditional` and `No-Go` are **ACTIVE, in-use values** there. A repo-wide string delete would corrupt them. **The removal must be field-scoped, not string-scoped.** |
| `Underwriting__c.Status__c` value `Complete` | 🔴 **DIFFERENT FIELD, ACTIVE, IN USE.** `Underwriting__c.Stage__c` also has an inactive `Complete` (one character from `Completed`). Deleting the wrong one breaks `OpportunityReviewService:115` and `ApprovalAuditService:80`. |
| `objectTranslations/*/Stage__c.fieldTranslation-meta.xml` | Carries **only the active values** — inactive ones are absent. **No translation change is required.** Verified on `Construction_Feasibility_Review__c-en_US/Stage__c`. |
| Apex, Flows, validation rules, list views, reports, quick actions | **zero** references to any of the 14 |

**Verdict: all 14 are safe to delete.** Zero records exist in the org for all six objects, so no
data blocks it either. This is the highest-confidence item in the program. ⚠ It is **not** a
control change — they are already inactive.

---

## 3. (a) ARCHITECTURE — RECOMMENDATION: one generic feature, `StageAdvanceService` left alone

### Recommendation

**Build ONE generic service + ONE controller + ONE LWC bundle + ONE guard util, driven by a
per-object CONFIG map in Apex, with a six-branch selector dispatch. No dynamic SOQL. No Custom
Metadata. Do NOT fold in the Opportunity `StageAdvanceService`.**

New Apex:

```
RecordStageAdvanceService.cls      // config map + advance(recordId); no SOQL of its own
RecordStageAdvanceController.cls   // thin @AuraEnabled boundary + permission dispatch
```

New LWC:

```
lwc/advanceRecordStage/            // headless, @api recordId; ONE bundle, six quick actions
lwc/recordStageGuard/              // JS-only util: permission -> confirm (mirrors c/dealActionGuard)
```

### Why generic, not six copies

Six copies would be ~18 Apex classes + 6 LWC bundles + 6 Jest suites to express six straight-line
maps that differ only in *(object, field name, ordered stage list, gate)*. Every future fix would
be six edits, and drift between the copies is certain — this repo already documents that failure
mode for the three lead-conversion classes. The paths are linear and structurally identical, so
there is nothing to specialise.

### How the Selector layering rule is satisfied WITHOUT dynamic SOQL

`.claude/rules/apex-layering-rule.md` is non-negotiable: all SOQL lives in a selector, uses
`WITH USER_MODE`, and a service never writes its own query. A generic service that
`Database.query`'d six objects would violate all three and add an injection surface.

Instead: **each of the six existing selectors gains one static, fully-literal method**, modelled on
`OpportunitySelector.selectStageRequiredById`:

```apex
// e.g. NdaSelector — fetch-for-use, a miss throws System.QueryException (repo contract)
public static NDA__c selectStageRequiredById(Id recordId) {
    return [SELECT Id, Status__c FROM NDA__c WHERE Id = :recordId WITH USER_MODE LIMIT 1];
}
```

The service dispatches on `recordId.getSObjectType()` through a six-branch `switch`, each branch two
lines. Zero dynamic SOQL; zero string-built queries; every query is compile-checked and
`WITH USER_MODE`. The FLS surface is per-object and minimal, matching each selector's existing
"per-caller minimal field list" philosophy.

### Where the NEXT_STAGE maps live: **Apex static map. NOT Custom Metadata.**

| | Apex `Map<String,String>` | `Stage_Map__mdt` |
| --- | --- | --- |
| Deploy cost in this org | none | 🔴 **CMDT *record* deploys fail here with `UNKNOWN_EXCEPTION` and need an Apex loader** (recorded org defect) |
| Runtime cost | zero | `getAll()` per transaction |
| Compile-checked with its callers | ✅ | ❌ |
| Under source control / code review | ✅ | records are not, in practice |
| Admin can change a stage map without a deploy | ❌ | ✅ |

That last row looks like CMDT's win. It is actually the argument against it: **an unreviewed stage-map
edit is the same class of hole as the Path button the user is removing.** And a stage change already
requires touching the picklist, the pathAssistant, the quick action and probably a validation rule —
all metadata deploys. The map is not the bottleneck. The Opportunity precedent is an Apex map;
matching it keeps one pattern.

### Why `StageAdvanceService` (Opportunity) stays as it is

It is **not** a stage-map service and does not generalise:

- `advance()` has a branch that submits into an **approval process** instead of writing a stage.
- `advanceTo()` exists only because Opportunity has **parallel record-type branches** (Land /
  Commercial) and an off-ramp; it carries `ALLOWED_EXPLICIT_TARGETS`. None of the six objects has a
  branch or an off-ramp.
- It is live, deployed, gated, and covered by `StageAdvanceServiceTest`, `StageAdvanceControllerTest`,
  `StageBackwardMovementGateTest`, `StageApprovalGatesTest`, `LoiGateTest`, `UnderwritingGateTest`.

Folding it in means re-testing a live gated feature to gain tidiness. **Negative expected value.**
The two services coexist and **share the permission service and the confirm util**. Add a
"know which one you are editing" note to both class headers and to ARCHITECTURE.md §2, exactly like
the three `LeadConvert*` classes.

### 🔴 One thing the generic service must NOT have

**No `advanceTo(recordId, target)`.** Generalising an explicit-target write across six objects
re-opens precisely the hole `ALLOWED_EXPLICIT_TARGETS` was created to close — any holder of class
access could write any stage on any of six objects. Expose **only `advance(recordId)`**, which
derives the target from the map and therefore cannot skip a hop. Add an explicit-target method only
when an off-ramp exists, and give it an allow-list on day one.

### Decision point D1 — write mode

`StageAdvanceService.setStage` uses plain `update o;` — **system-mode DML, so FLS on the stage field
is not enforced on the write**. The alternative is `Database.update(rec, AccessLevel.USER_MODE)`
(available at API 67.0), which enforces CRUD+FLS and fails closed.

- **Recommended: match the precedent (`update`).** The control here is the permission service plus
  the validation rule, not FLS; and a silent divergence between two sibling services is itself a bug
  source. Residual: a user without FLS edit on the stage field can still drive the button. Accepted
  and documented.
- If the user prefers USER_MODE DML, it is a one-line change with one extra catch clause, but it
  makes an FLS provisioning gap present as a mysterious denial — and per the repo's own note, **FLS
  truth is not in source control** (profiles are `.forceignore`d), so it cannot be regression-tested
  from this repo.

---

## 4. (b) THE PERMISSION MODEL

### Recommendation: reuse the Opportunity TWO-FACTOR gate for five objects; a separate gate for `Lease__c`

| Object | Gate | Rationale |
| --- | --- | --- |
| `NDA__c` | `OpportunityActionPermissionService` (two-factor) | acquisitions deal child |
| `LOI__c` | same | **already deployed on this object** (§2.3) |
| `Underwriting__c` | same | **already deployed on this object** |
| `Construction_FR__c` | same | acquisitions deal child |
| `Development_FR__c` | same | acquisitions deal child |
| `Lease__c` | ⚠ **NOT the deal-driver gate** — see below | different persona |

**Why two-factor and not membership for the five.** `Deal_Driver__c`'s own field description names
"Submit for Approval on Underwriting/LOI" explicitly, and the visibility rule
`{!$User.Deal_Driver__c} EQUAL true` is already deployed on two of these six record pages. Adding a
*membership* check would grant every holder of `Acquisition_Deal_Driver` whose flag is `false` —
a silent widening of a live authorization boundary. `OpportunityActionPermissionServiceTest`
`hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` exists to go red if anyone tries.
This choice costs **zero new permission machinery**.

**Why `Lease__c` is different.** `Lease__c` belongs to Property Management leasing — it is created
by `Lease_Inquiry_Create_Lease` from a Lease Inquiry and worked by **legal** (`Legal_Owner__c`),
not by an acquisitions deal driver. Setting `Deal_Driver__c = true` on the legal team to let them
advance a lease would simultaneously grant them **every Opportunity stage action and the principal
approval submission**. That is a cross-persona widening and must not be done implicitly.

**Decision point D2 — the `Lease__c` gate.** Three options:

| Option | Cost | Verdict |
| --- | --- | --- |
| **(i) New `Lease_Stage_Actions_Access` permission set + `LeaseActionPermissionService` (membership, Lead pattern)** | +2 classes, +2 tests, +1 perm set (~1.5 days) | ✅ **Recommended.** There is no existing flag for the legal persona, and adding a second boolean User field to mirror `Deal_Driver__c` is worse than a permission set. |
| (ii) Reuse the deal-driver flag | 0 | ❌ cross-persona widening |
| (iii) Ship Lease's Path-button removal + VR now, defer its quick action | −1.5 days | acceptable fallback if the program needs trimming |

**How ONE component serves TWO gates without merging them.** `c/dealActionGuard` imports
`OpportunityActionPermissionController` at module scope, so it cannot serve Lease. Instead the new
`RecordStageAdvanceController` exposes:

```apex
@AuraEnabled(cacheable=true)
public static Boolean hasStageActionAccess(Id recordId)   // dispatches by SObjectType
```

and the new `c/recordStageGuard` calls that one method. **This dispatches to two gates; it does not
merge them.** Pin it with a matched pair of tests that discriminate in opposite directions: a
deal-driver denied on `Lease__c`, and a lease-permset holder denied on `Underwriting__c`.

### 🔴 LAUNCH BLOCKER — the operational finding from today

The two-factor gate **fails closed and silently**, and today **no user in the org had
`Deal_Driver__c = true`**, so the deployed Opportunity buttons were invisible to everyone. That is
not a bug; it is the gate working with an empty roster. Before any of these six actions can be
accepted:

1. Assign `Acquisition_Deal_Driver` to the intended users — this is what grants **FLS read on
   `User.Deal_Driver__c`**, factor (a).
2. Set `Deal_Driver__c = true` on those users' own User records — factor (b).
3. ⚠ **An admin smoke test proves nothing.** "Modify All Data" bypasses the gate before the flag is
   read. UAT must run as a real deal-driver persona and as a real *denied* persona.
4. Neither user-field values nor FLS deploy from this repo. This is an **in-org runbook step**, and
   it must appear in the DevOps hand-off, not be assumed.

---

## 5. (c) THE WRITE PATH — CONFIRMED: imperative Apex everywhere

The user's instinct is right, but not for the reason stated. **Validation rules fire on both paths**
— a VR is a database control, so LDS `updateRecord` is blocked by it exactly as Apex DML is.
"We need control so we can implement validation rules" does not by itself require Apex.

Apex is still the right answer, for four other reasons:

1. **Server-side enforcement is only possible with Apex in the path.** The LDS route has no place to
   put `assertStageActionAccess()`; a client check is bypassed by calling nothing at all. This is the
   documented weakness of the three Lead status actions and should not be repeated six more times.
2. **Transition control, not just value control.** A map-derived `advance()` cannot skip a hop. LDS
   writes whatever value the JS holds, which puts the map in JS where it drifts — refused for
   `advanceDealStage` in ARCHITECTURE.md §5 for exactly this reason.
3. **The VR message reaches the toast for free.** `StageAdvanceService.setStage` catches
   `DmlException` and rethrows `getDmlMessage(0)`; the controller surfaces it verbatim; the LWC reads
   `error.body.message`. Copy that. On the **LDS** route the rule text lands in
   `body.output.errors[...]` instead, and `c/dealActionGuard.messageFor` reads **`body.message` only**
   — so a VR behind an LDS write would ship invisible. (`c/leadStatusChange.messageFor` already has
   the `body.output` walk; `dealActionGuard` does not and does not need it on the Apex path.)
4. One consistent shape across six objects.

### 🔴 `getRecordNotifyChange` is MANDATORY

Apex DML happens behind LDS's back. Without `getRecordNotifyChange([{ recordId }])` on success, the
Path and the highlights panel show a **stale stage** after every click. This is non-negotiable for
the new bundle and must be asserted in its Jest suite.

Conversely — do **not** add it to any LDS-writing bundle. ARCHITECTURE.md §5 documents that the two
requirements are opposite and must not be harmonised.

---

## 6. (d) WHAT `hideUpdateButton` DOES AND DOES NOT BUY

### What it does

Removes the button rendered by `runtime_sales_pathassistant:pathAssistant` **on that one flexipage**.
Declarative, one line, reversible. That is the entire effect.

### What it does not stop

| Route | Still open after `hideUpdateButton = true`? |
| --- | --- |
| Inline edit on the record detail panel | **yes**, where the field is on the layout |
| Inline edit / mass update in a list view | **yes** — but list views *do* respect page-layout read-only |
| The standard Edit page | **yes** |
| REST/SOAP API, Data Loader, anonymous Apex, Flow | **yes** — no UI control reaches these |
| A different record page (app-specific override, Salesforce Mobile) still showing the button | **yes** |

### Layout read-only — VERIFIED per object, and the brief's constraint DOES bite

The brief asked whether the platform's refusal of `behavior=Readonly` on a universally-required
field applies here. **It does, on exactly one object.**

| Object | Stage field on layout? | Current `behavior` | Field `<required>` | Can it be Readonly? |
| --- | --- | --- | --- | --- |
| `NDA__c` (`Status__c`) | yes | `Edit` | `false` | ✅ **yes** |
| `LOI__c` (`Stage__c`) | yes | `Edit` | `false` | ✅ **yes** |
| `Underwriting__c` (`Stage__c`) | yes | `Edit` | `false` | ✅ **yes** |
| `Lease__c` (`Stage__c`) | yes | **`Required`** | **`true`** | ⛔ **NO — the platform refuses Readonly on a universally-required field** |
| `Construction_FR__c` | **not on the layout at all** | — | `false` | n/a — already uneditable from the detail panel |
| `Development_FR__c` | **not on the layout at all** | — | `false` | n/a — same |

So for the two feasibility objects, **hiding the Path button alone removes the last UI writer**.
For NDA / LOI / Underwriting, layout read-only closes the inline-edit and list-view holes.

**`Lease__c` is the exception, and it has a cheap fix:** the field already has
`<default>true</default>` on `Draft` and is written by the creating Flow, so `<required>true</required>`
is belt-and-braces. Dropping field-level `required` (keeping the layout item, changing `Required` →
`Readonly`) makes read-only available. **Decision point D3.** If the user prefers to keep the field
required, Lease keeps inline edit and relies on the validation rule alone.

⚠ Layout read-only does **not** affect the quick action: Apex DML ignores layout behavior. And it
does not affect the API.

### The only control that is uniform across UI, API, Flow and Apex

**Validation rules.** Everything else is a UI affordance. That is why the user's framing —
"complete control on stage change **so we can implement validation rules**" — is the right one, and
why §7 is the load-bearing part of this program, not §3.

A fourth lever exists and is deliberately **not** recommended as primary: removing Edit FLS on the
stage field from every profile and permission set. It is the hardest control, but profiles are
`.forceignore`d in this repo, so it is an in-org-only change that never deploys and cannot be
regression-tested from source.

---

## 7. (e)+(f) VALIDATION-RULE SHAPE AND APPROVAL INTERACTION

**Business content is out of scope** — the user has not defined the gates. This section defines the
SHAPE every future rule on these six objects must take, and the traps that shape must avoid.

### 7.1 The shape

1. **Scope every rule with `ISCHANGED(<stage field>)`.** Consequence, stated plainly: the rule never
   fires on INSERT, so "create a record directly at any stage" stays open. That is deliberate and
   matches the deployed `NDA_Signed_Before_Deal_Progression` rule. It is also what keeps
   `OpportunityReviewService` and `Lease_Inquiry_Create_Lease` working untouched.
2. **Rank map inline, in `CASE(TEXT(<field>), 'A',1, 'B',2, …, 0)`.** Do **not** add a
   `Stage_Rank__c` formula field: `PRIORVALUE()` cannot read a formula field, so a backward-movement
   rule needs the `CASE` inline anyway. (Verified trap.)
3. **Unmapped values rank 0 = FAIL OPEN.** A future picklist value is permissive, not a pipeline
   freeze.
4. **`errorDisplayField` = the stage field**, so the message renders next to the picklist.
5. **`<description>` is capped at 255 characters.** The long rationale goes in an XML comment above
   `<fullName>` — the `No_Backward_Stage_Movement` precedent.
6. **No `Dead%2FPass`-style encoding trap here.** Two values contain a slash — `LOI__c`/`Lease__c`
   `Prepare/Review` — so use `TEXT(...)` string compares rather than `ISPICKVAL`, as the Opportunity
   rules already do.

### 7.2 🔴 THE OFF-RAMP TRAP — none of the six has one

Verified against every picklist in §2.1. There is **no** `Dead/Pass` equivalent, no `Cancelled`,
`Withdrawn`, `Void`, `Declined`, `Expired`, `Abandoned` or `No-Go` **as a stage** on any of the six.
(`No-Go` exists only on `Recommendation__c`, a different field, and only as an **inactive** value on
the two Stage picklists — one of the 14 being deleted.)

On Opportunity the absolute no-backward rule is survivable *only* because Dead/Pass is reachable
from every stage and leavable from it — the documented two-save recovery. **That route does not
exist here.**

> **Recommendation: do NOT ship a no-backward-movement rule on any of the six until that object has
> an off-ramp value.** Without one, a record that goes down the wrong path is trapped forever with
> no user-level recovery at all.

Three ways forward (**decision point D4**):

| Option | Effect |
| --- | --- |
| **(i) Add an off-ramp value per object first, rank 0, exempt in both directions** — recommended | Makes an absolute ordering rule survivable. Cost: 6 picklist values + 6 pathAssistant steps + Path/UI review. **Must be sequenced before the C2 deletion, since `No-Go` is a candidate name being deleted.** |
| (ii) Ship only forward **content** gates ("Signed requires a Date Signed") and no ordering rule | Never traps a record — the record can always go back and fix the content. Safe default if off-ramps are not wanted. |
| (iii) Ship the ordering rule with admin-only API recovery | Rejected: the same "unadministered bypass" the user explicitly refused at the Opportunity D4 gate. |

### 7.3 🔴 THE APPROVAL TRAP — `ApprovalAuditService` fires VRs AND swallows the failure

This replaces the brief's finding (f), which was based on the wrong premise (C1).

`ApprovalAuditService.stampApprovalAudit` runs from an **after-save Flow** on principal sign-off and
performs Apex DML:

```apex
uwUpdates.add(new Underwriting__c(Id = uw.Id,
    Stage__c = 'Approved', Status__c = 'Approved by Principals'));
...
try   { if (!uwUpdates.isEmpty())  { update uwUpdates; }
        if (!loiUpdates.isEmpty()) { update loiUpdates; } }
catch (DmlException e) { System.debug(LoggingLevel.WARN, '... audit stamp failed: ' + ...); }
```

Three consequences:

1. **A validation rule on `Underwriting__c.Stage__c` WILL fire against this write.** Apex DML is not
   an approval field update; it gets no bypass.
2. **If the rule blocks it, the failure is silent** — one debug line, no exception, no user-visible
   error, and the Underwriting Path simply never reaches `Approved`. The approval itself completes.
   This is the worst failure shape in the program because it is invisible.
3. A blocked `update uwUpdates` also **skips `update loiUpdates`**, since both sit in one `try`.

⇒ **Any Underwriting `Stage__c` rule MUST explicitly permit the transition into `'Approved'`**, by
carve-out or by scope. Write it into the rule's XML comment as load-bearing, exactly as CARVE-OUT 1
and 2 are on `No_Backward_Stage_Movement`.

`ApprovalAuditService` also writes `LOI__c.**LOI_Status__c**` — a different field from
`LOI__c.Stage__c`. An `ISCHANGED(Stage__c)`-scoped LOI rule is therefore **inert** against it. Good
outcome; note it so nobody "helpfully" widens the LOI rule to cover `LOI_Status__c`.

### 7.4 🔴 The Underwriting quick-action map must NOT reach `Approved`

`Underwriting__c` Path is `Requested → In Progress → Approved → Completed`, and `Approved` is
**owned by the principal approval process**. A naive "same as Opportunity" copy would put `Approved`
one button-click away and bypass the approval entirely.

**Recommended map — the `In Progress → Approved` hop is deliberately ABSENT:**

```apex
'Requested'  => 'In Progress',
'Approved'   => 'Completed'
// 'In Progress' => (no entry). Reaching Approved is the approval's job:
//                  use the existing Underwriting__c.Submit_for_Approval quick action.
```

This is the same shape as `StageAdvanceService.NEXT_STAGE`, which omits `'Underwriting'` for exactly
this reason. From `In Progress` the generic service throws its "no next step available" message, and
the already-deployed `Submit_for_Approval` action is the visible route. LOI is unaffected — its
`Stage__c` is never written by the approval, so all four LOI hops are free.

### 7.5 Carve-outs required, per object

| Object | Carve-out needed | Why |
| --- | --- | --- |
| `Underwriting__c` | 🔴 **YES** — permit `→ 'Approved'` | `ApprovalAuditService`, silently swallowed |
| `NDA__c` | no (verify `NDA_Signed_Status_Sync` `triggerType` before deploy) | it stamps flags, not the status |
| `LOI__c` | no | approval touches `LOI_Status__c`, not `Stage__c` |
| `Lease__c` | no | Flow creates at `Draft` (INSERT) |
| `Construction_FR__c` / `Development_FR__c` | no | created at `Requested` (INSERT); notify flows do not write |

---

## 8. (g) BLAST RADIUS, SEQUENCING, TESTS

### 8.1 Full component list

**Apex — new (4 files + 4 tests, or 6 + 6 with D2 option (i))**

| Component | Layer |
| --- | --- |
| `RecordStageAdvanceService.cls` (+`Test`) | service |
| `RecordStageAdvanceController.cls` (+`Test`) | controller |
| `LeaseActionPermissionService.cls` (+`Test`) — **only if D2 = (i)** | service |
| `LeaseActionPermissionController.cls` (+`Test`) — **only if D2 = (i)** | controller |

**Apex — modified (12 files)**

`NdaSelector`, `LoiSelector`, `UnderwritingSelector`, `LeaseSelector`,
`ConstructionFeasibilityReviewSelector`, `DevelopmentFeasibilityReviewSelector` — one
`selectStageRequiredById` each, plus one test method each in the six matching `*Test` classes
(required to keep every class ≥90%).

**LWC — new (2 bundles + 2 Jest suites)**

`lwc/advanceRecordStage/`, `lwc/recordStageGuard/`. Author at **apiVersion 67.0**.

**Declarative**

| Type | Count | Detail |
| --- | --- | --- |
| flexipage `hideUpdateButton` → `true` | **8** | 6 objects + `Opportunity_Record_Page` + `Lead_Record_Page` |
| flexipage Dynamic Actions | **6** | 2 already migrated (add the new action); ⚠ **4 need full migration** — see R2 |
| quickAction (new) | **6** | one per object, all bound to `advanceRecordStage`, per-object label |
| picklist field edits | **3** | delete the 14 inactive values (§2.6) |
| layout edits | **3** | NDA / LOI / Underwriting stage field `Edit` → `Readonly`; **+1 if D3 = drop Lease `required`** |
| validation rules | **0–6** | shape only; gated on D4 |
| permission set | **1–2** | Apex class access on `Acquisition_Deal_Driver`; `+ Lease_Stage_Actions_Access` if D2 = (i) |
| `objectTranslations` | **0** | verified: inactive values are not translated |
| ARCHITECTURE.md | §2 + §5 | new service row, the "two stage services" note, the off-ramp trap |

### 8.2 Named risks

**R1 — the 4 flexipages that do NOT yet use Dynamic Actions.** `NDA_Record_Page`,
`Lease_Record_Page`, `Construction_Feasibility_Review_Record_Page`,
`Development_Feasibility_Review_Record_Page` inherit the layout's `platformActionList`. Switching
the Highlights Panel to `actionNames` **replaces that list entirely** — Edit, Delete, Clone, Change
Owner, Printable View all disappear unless explicitly re-listed. 🔴 **Enumerate each layout's
current `platformActionList` and re-list every item.** This is a UI regression with no Apex or Jest
test that can catch it; it is UAT-only.

**R2 — a green `ApprovalAuditServiceTest` is not evidence.** Because the service swallows the
`DmlException`, a validation rule that blocks the Underwriting stamp leaves the test **green and the
feature broken** — the vacuous-pass shape this repo has been bitten by before. The test must be
strengthened to assert the stamp **landed** (`Stage__c == 'Approved'` re-read from the database),
not merely that the method returned.

**R3 — `TestDataFactory` is the systemic single point of failure.** If any validation rule blocks a
factory insert, *every* suite in the org fails at once. Mitigation: keep every rule
`ISCHANGED`-scoped, so no rule can fire on an insert.

**R4 — the empty deal-driver roster** (§4). Five of six actions are invisible to every user until
the in-org provisioning step runs. Not a code defect; a runbook item that must not be forgotten.

**R5 — `Lease__c.Stage__c` is unrestricted.** Even with the button hidden, the layout read-only
refused and a VR in place, an API caller can write an arbitrary string. If genuine control on Lease
matters, `<restricted>true</restricted>` should be added (safe: zero records exist).

### 8.3 Existing tests — what breaks, what merely re-runs

| Change | Test impact |
| --- | --- |
| **14 picklist deletions** | **ZERO.** Swept `classes/`, `flows/`, `pathAssistants/`, `layouts/`, `objectTranslations/`, `reports/`, `scripts/` — no reference to any of the 14. Highest-confidence item. |
| **8 flexipage edits, 6 quickActions, 3 layout edits** | **ZERO automated coverage exists.** UAT-only. |
| **6 selector method additions** | **6 test-class EDITS** (`NdaSelectorTest`, `LoiSelectorTest`, `UnderwritingSelectorTest`, `LeaseSelectorTest`, `ConstructionFeasReviewSelectorTest`, `DevelopmentFeasibilityReviewSelectorTest`) — additions, not breaks, but required for the 90% bar. |
| **`StageAdvanceService` left alone** | `StageAdvanceServiceTest` / `StageAdvanceControllerTest` **unaffected** — the reason the recommendation is not to fold it in. |
| **Validation rules — the real risk** | **`ApprovalAuditServiceTest` 🔴 highest risk** (see R2). Then, at risk and mandatory to re-run: `OpportunityDocStatusControllerTest` (line 39 UPDATEs `uw.Stage__c = 'In Progress'` — the only stage **update** in the whole test corpus for these six), `UnderwritingGateTest`, `LoiGateTest`, `StageApprovalGatesTest`, `StageBackwardMovementGateTest` (all drive approvals that cascade into `ApprovalAuditService`), `OpportunityReviewServiceTest` (25 refs, insert-only → expected safe), `OpportunityReviewTriggerHandlerTest`, the six selector tests, `CounterOfferServiceTest` / `CounterOfferControllerTest` / `DealMessageServiceTest` (touch LOI fields other than `Stage__c` → expected inert). |
| Jest | 82 existing suites unaffected; **+2 new**. |

**43 files in `classes/` reference at least one of the six objects.** Budget a full `RunLocalTests`
plus the full Jest net after each phase, not only at the end.

### 8.4 Build order — which object proves the pattern

All six ship together. The **order** is chosen to surface design errors while the design is still
cheap to change.

| # | Object | Why here |
| --- | --- | --- |
| **1** | **`NDA__c`** | It is the object in the reported defect. Shortest path (3 stages / 2 hops). **Its stage field is `Status__c`, not `Stage__c` — so it proves the config's field-name parameterisation on day one instead of on object six.** No approval interaction. It is created on *every* Opportunity insert, so `TestDataFactory` produces one in almost every suite → maximum regression signal, earliest. It also spans Disposition, surfacing the persona question early. |
| **2** | **`Underwriting__c`** | The hardest case: the `→ Approved` carve-out (§7.3), the map that must skip `In Progress → Approved` (§7.4), the orphan values, and the `Complete` / `Completed` near-collision (§2.6). Prove it while the pattern is still malleable. |
| 3 | `LOI__c` | Longest linear path; Dynamic Actions already present. Mechanical. |
| 4–5 | `Construction_FR__c`, `Development_FR__c` | Mechanical, but each needs the R1 flexipage migration. |
| **6** | **`Lease__c`** | Last, deliberately: different persona (D2), `required=true` blocks layout read-only (D3), unrestricted picklist (R5), Flow-created. It shares the least with the other five. |

### 8.5 Honest estimate

| Phase | Days |
| --- | --- |
| P0 — verify in org (FLS, personas, `NDA_Signed_Status_Sync` `triggerType`, layout action lists) | 1 |
| P1 — picklist deletion (3 files, field-scoped) + org verify | 0.5 |
| P2 — generic service + controller + tests to 90% | 3–4 |
| P3 — 6 selector methods + 6 test edits | 1 |
| P4 — 2 LWC bundles + 2 Jest suites | 1.5 |
| P5 — 6 quickActions + 8 flexipage edits (4 with full Dynamic Actions migration, R1) | 2–3 |
| P6 — layout read-only + the `Lease__c` required/restricted decisions | 0.5–1 |
| P7 — validation-rule shape + up to 6 rules + gate tests + the `ApprovalAuditServiceTest` hardening | 3–5 |
| P8 — permission provisioning + persona UAT (6 objects × permitted/denied) | 2 |
| P9 — full `RunLocalTests` + Jest regression, fixing breaks | 2 |
| P10 — ARCHITECTURE.md §2/§5 + docs | 1 |
| **Total** | **18–24 engineering days** |
| **+ D2 option (i)** — `Lease` membership gate | **+1.5** |
| **+ D4 option (i)** — add off-ramp values to six picklists + Paths | **+2** |

P7 is the widest range because the business gates are undefined. P5 is the highest UAT risk (R1).
P1 and P3 are the only phases that can be called near-certain.

---

## 9. DECISIONS NEEDED BEFORE BUILD

| # | Decision | Recommendation |
| --- | --- | --- |
| **D1** | Write mode: plain `update` (system mode, matches `StageAdvanceService`) or `Database.update(..., AccessLevel.USER_MODE)` | **Match the precedent (`update`)**; document the FLS residual |
| **D2** | The `Lease__c` permission gate | **(i) new `Lease_Stage_Actions_Access` membership gate** |
| **D3** | Drop `<required>true</required>` on `Lease__c.Stage__c` so layout read-only becomes available? | **Yes** — the field already defaults to `Draft` and is Flow-written |
| **D4** | Off-ramp values before any ordering rule | **(i) add one per object first, ranked 0** — and sequence it **before** the C2 picklist deletion, since `No-Go` is a candidate name being deleted |
| **D5** | Add `<restricted>true</restricted>` to `Lease__c.Stage__c` (R5)? | **Yes** — zero records exist, so it is free now and expensive later |
| **D6** | Ship validation rules in this program, or ship the actions first and the rules once the business gates are defined? | **Actions + shape first, rules as a follow-on.** The user does not yet have the gates; shipping an empty rule set is not a deliverable |

---

## 10. AGENT ROUTING

Per `CLAUDE.md`'s complexity routing gate this is **not** routine admin or standard dev work: it
spans a generic multi-object service, a permission-model decision affecting two personas, a
declarative Dynamic Actions migration on four record pages, and a validation-rule architecture.

- **Declarative work** (picklists, flexipages, quickActions, layouts, validation rules, permission
  sets) → 🟤 **`salesforce-solution-architect`**, not `salesforce-admin`: the Dynamic Actions
  migration and the permission-set/persona split are architectural.
- **Programmatic work** (generic service, controller, selectors, LWC) → 🟢 **`salesforce-developer`**
  — no integration, no LDV, no callouts. Standard layering.
- Then 🟡 unit-testing → 🟣 code-review → 🔴 devops + 🔷 docs.

### Prompt for `salesforce-solution-architect`

```
Read ARCHITECTURE.md (§1, §2 Key Apex Services, §5), all four .claude/rules/ files, and
agent-output/design-requirements-stage-control.md in full before writing anything.

Build the DECLARATIVE half of the stage-control program for NDA__c, LOI__c, Underwriting__c,
Construction_Feasibility_Review__c, Development_Feasibility_Review__c, Lease__c:

1. Delete the 14 INACTIVE orphan picklist values listed in §2 of the design doc. FIELD-SCOPED
   ONLY — see §2.6: 'Complete' is an ACTIVE value on Underwriting__c.Status__c, and
   'Go / Conditional' / 'No-Go' are ACTIVE on both Recommendation__c fields. Do not touch those.
   No objectTranslation change is required (verified).
2. Set hideUpdateButton = true on all EIGHT flexipages named in §2.2.
3. Add one Dynamic Actions entry per object for the new quick action, with the visibility rule
   {!$User.Deal_Driver__c} EQUAL true for the five acquisitions objects (see §4 for Lease).
   ⚠ For NDA_Record_Page, Lease_Record_Page and the two feasibility record pages, migrating the
   Highlights Panel to Dynamic Actions REPLACES the layout's platformActionList — enumerate each
   layout's current action list and re-list every item (design doc R1).
4. Create 6 quick actions, type LightningWebComponent, bound to `advanceRecordStage`, one per
   object, with a per-object label.
5. Set the stage field to behavior=Readonly on the NDA, LOI and Underwriting layouts only.
   Lease__c.Stage__c cannot be Readonly while it is universally required — see decision D3.
6. Do NOT author any validation rule yet (decision D6). Do NOT deploy.
```

### Prompt for `salesforce-developer`

```
Read ARCHITECTURE.md (§2, §5), all four .claude/rules/ files, and
agent-output/design-requirements-stage-control.md in full before writing anything. Also read
classes/StageAdvanceService.cls, classes/StageAdvanceController.cls,
classes/OpportunityActionPermissionService.cls, lwc/dealActionGuard/, lwc/advanceDealStage/.

Build the PROGRAMMATIC half:

1. RecordStageAdvanceService — ONE generic service for the six objects. A per-object config
   (SObjectType -> stage field API name, ordered NEXT_STAGE map, gate) as an Apex static map, NOT
   Custom Metadata (§3). Expose ONLY advance(Id recordId). Do NOT add an explicit-target method.
   ⚠ The Underwriting map deliberately OMITS 'In Progress' -> 'Approved' (§7.4).
   ⚠ NDA__c's stage field is Status__c, not Stage__c.
   No SOQL of its own: dispatch on recordId.getSObjectType() to the six selectors.
2. Add `selectStageRequiredById(Id)` to NdaSelector, LoiSelector, UnderwritingSelector,
   LeaseSelector, ConstructionFeasibilityReviewSelector, DevelopmentFeasibilityReviewSelector.
   Static SOQL, WITH USER_MODE, fetch-for-use (a miss throws System.QueryException). No dynamic SOQL.
3. RecordStageAdvanceController — thin. First statement of every @AuraEnabled method asserts the
   permission. Expose @AuraEnabled(cacheable=true) hasStageActionAccess(Id recordId) which
   DISPATCHES by SObjectType to the correct gate. It must NOT merge the two gates (§4).
   Catch order: AccessDenied -> typed service exception -> generic masked catch. Surface
   DmlException via getDmlMessage(0) so validation-rule text reaches the toast (§5).
4. lwc/recordStageGuard (JS util, isExposed=false) + lwc/advanceRecordStage (headless
   lightning__RecordAction). apiVersion 67.0. Order: permission -> confirm -> act.
   getRecordNotifyChange([{ recordId }]) on success is MANDATORY (§5).
5. Do NOT modify StageAdvanceService or StageAdvanceController (§3).
6. Add the ARCHITECTURE.md §2 service row and the "two stage services — know which one you are
   editing" note in the same change.
Do not deploy.
```
