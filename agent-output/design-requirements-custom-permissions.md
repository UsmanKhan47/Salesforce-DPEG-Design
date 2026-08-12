# DESIGN REQUIREMENTS — Replace the `*_Driver__c` flag model with Custom Permissions

**Date:** 2026-08-12
**Requested by:** user — *"I believe we must create custom permissions, I don't like this driver concept."*
**Scope:** refactor of a LIVE, DEPLOYED authorization boundary across two modules (Acquisitions, Disposition).
**Out of scope (user-stated):** changing WHO may drive deals; `Transaction_Stage_Actions_Access`'s
membership-only decision (unless argued explicitly — see Gate 1 Q1, where it IS argued and DEFERRED).

---

## 0. PREMISE CORRECTIONS — read before pricing anything

Everything in the brief was verified. Three items differ from the brief and one of them changes scope.

| # | Brief said | Measured | Impact |
|---|---|---|---|
| **P1** 🔴 | "~31 visibility rules total" | **24 live `<criteria>`.** 7 of the 31 grep hits are XML **comment prose** inside the flexipages (Contract_Review ×3, LOI ×2, NDA ×2). | UAT scope drops 31→24. But the 7 comments **describe the FLS mechanism being deleted**, so they are wrong-after-change and must be rewritten, not ignored. Net edit count is still 31 sites. |
| **P2** | (split not given) | **18 acquisition + 6 disposition.** Per page: Opportunity 8/0, LOI 4/3, Contract_Review 1/1, NDA 1/2, Underwriting 2/0, Dev_FR 1/0, Constr_FR 1/0. | Each criterion repoints to a **different** custom permission. A blind find/replace corrupts the disposition rules. |
| **P3** ✅ | "`dealActionGuard.js` and `recordStageGuard.js` reference the flags — verify" | **VERIFIED: comment-only.** Both hits are Javadoc header prose. No `import`, no field reference, no Jest assertion anywhere under `lwc/`. | **The LWC layer needs ZERO functional change.** Header comments only. No Jest suite changes. Item 6 of the brief is answered: they only call Apex. |
| P4 ✅ | "no formula dependency; `Is_Decline_Allowed__c` is a comment" | Confirmed. `Is_Decline_Allowed__c` is `RecordType.DeveloperName` + `Status__c` only. | No formula work. |
| P5 ✅ | "repo has ZERO custom permissions" | Confirmed — no `customPermissions/` directory. | ⚠ **And there is no `sf-custom-permission` skill in `.claude/skills/`.** Per `salesforce-global-rule.md` the admin agent must record `best_matched_skill` before writing; the nearest is `sf-metadata`. Named as a gate in the admin prompt. |

**P6 — the strongest argument for this change is already written down in this repo, and it is stronger than the brief states.** `Is_Decline_Allowed__c`'s XML comment records:

> *"A flexipage visibility rule referencing `{!Record.Is_Decline_Allowed__c}` evaluates FALSE for any user without FLS READ on it — which is exactly the mechanism that made `{!$User.Deal_Driver__c}` unreachable for the disposition persona."*

That is a **production defect that already happened once** (code review C1). A custom permission has no FLS, so the entire failure class is removed — not mitigated. The same comment records the corollary the brief mentions: Metadata-API-deployed fields arrive with FLS for **nobody, System Administrator included**, which is the sole reason `OpportunityActionPermissionService` and `DispositionActionPermissionService` both carry a load-bearing "Modify All Data must be checked FIRST or every admin is locked out" ordering constraint. That constraint also disappears (see §4).

**P7 — 🔴 THE PRECEDENT THAT SETS THE BIGGEST RISK IN THIS DESIGN.** `Is_Decline_Allowed__c`'s comment also records a **measured** finding:

> *"a parenthesised OR (`1 AND 2 AND (3 OR 4)`) DEPLOYED AND SURVIVED A RETRIEVE while the RENDERER did not honour it — the button stayed visible."*

So this repo has already measured a flexipage construct that **deploys green, retrieves identically, and is silently ignored at render time.** That is exactly the failure shape a `{!$Permission.X}` criterion could have. **A green deploy is not evidence.** This drives the P0 spike in §7.

---

## 1. WHAT THE USER REQUESTED

Replace the two-factor `User.Deal_Driver__c` / `User.Disposition_Driver__c` boolean-flag authorization
model with Salesforce **Custom Permissions**, across both modules, with a migration sequence that
never locks anyone out mid-flight.

Nothing beyond that is proposed below. Every item is either (a) a direct consequence of the swap, or
(b) a decision the user explicitly asked to be surfaced.

---

## 2. 🔴 THE ONE PROPERTY THAT MAKES THIS MIGRATION SAFE — read this before §5

The custom permission is added to the **existing, already-assigned** layer-5 sets
(`Acquisition_Deal_Driver`, `Disposition_Deal_Driver`). Custom-permission grants **are** deployable
metadata (a `<customPermissions>` element inside a `PermissionSet`), while
`PermissionSetAssignment` is not.

⇒ **At the instant the deploy completes, exactly the current holders hold the new permission. There
is ZERO in-org assignment work and ZERO window.** The migration's whole risk profile follows from
this one fact, and it is why:

- no dual-accept transition window is needed (§5 / Gate 1 Q5);
- the populations are preserved by construction rather than by a migration script;
- the only remaining question is whether "current holders of the SET" equals "current drivers"
  (Gate 1 Q4 — an **org measurement**, resolved in Step 0 below).

⚠ **Verified precondition:** `Acquisition_Deal_Driver` is assigned **directly**, not through a
permission set group — it is absent from `DPEG_Junior_Analyst_PSG`'s member list (checked). So there
is no PSG-recalculation lag. Re-verify in-org for `Disposition_Deal_Driver` in Step 0.

---

## 3. GATE 1 — DECISIONS THE USER MUST MAKE

| # | Question | Options | **Recommendation** |
|---|---|---|---|
| **Q1** | **How many custom permissions?** Two (one per module), or also one for `Transaction__c`? | **A.** Two: `Acquisition_Deal_Actions`, `Disposition_Deal_Actions`.<br>**B.** Three: also `Transaction_Deal_Actions`.<br>**C.** Finer (per object). | 🟢 **A — two.** See §3.1. **C is rejected outright**: only two distinct gates exist on this axis today; a finer split invents a boundary nobody has and multiplies UAT by 7. |
| **Q2** | **Where does the custom permission live?** 🔴 *the load-bearing decision* | **A.** In the existing layer-5 sets (`Acquisition_Deal_Driver` / `Disposition_Deal_Driver`).<br>**B.** In the layer-4 capability sets (`Opportunity_Stage_Actions_Access`). | 🟢 **A — layer 5.** **B is a live, silent widening** — see §3.2 for the file-verified mechanism. |
| **Q3** | **Naming.** The user dislikes "the driver concept" — is the *word* also objectionable? | **A.** `Acquisition_Deal_Actions` / `Disposition_Deal_Actions`.<br>**B.** `Drive_Acquisition_Deals` / `Drive_Disposition_Deals`.<br>**C.** Keep "Driver" in the name. | 🟢 **A.** Mirrors `Opportunity_Stage_Actions_Access`'s vocabulary, avoids "driver", reads correctly as `{!$Permission.Acquisition_Deal_Actions}`. ⚠ **The permission SET keeps its name `Acquisition_Deal_Driver`** — renaming a set is a delete+create on its API name and **destroys every assignment**, which is the one thing making this migration free. Set the expectation now. |
| **Q4** | **Is the one-factor gate a WIDENING?** Depends on an org fact. | Not a preference — a **measurement**. | 🔴 **Blocking. Run the SOQL in Step 0 BEFORE any build.** If `{holds the set} ∧ {flag = false}` is **empty**, this is population-preserving and there is no widening. If it is non-empty, those users must be **unassigned first** — otherwise the deploy grants them deal-driving. |
| **Q5** | **Dual-accept transition window** (Apex accepts flag OR custom permission, then narrows)? | **A.** No window — one atomic deploy; keep the flag fields + FLS grants untouched as the rollback lever.<br>**B.** Window, then a cleanup pass. | 🟢 **A — no window.** §5.3 explains why B is *worse*, not merely unnecessary: it is a real widening for its duration, it needs more code not less, and A already delivers instant rollback **without** any widening. |
| **Q6** | **Retire `User.Deal_Driver__c` / `User.Disposition_Driver__c` now, or later pass?** | **A.** Later, separate pass after a soak.<br>**B.** Same pass. | 🟢 **A — later.** They are the rollback lever (Q5-A). Retiring them also **deletes `UserSelector` entirely** — see §6, which has an ARCHITECTURE consequence worth its own review. |
| **Q7** | **Keep the "Modify All Data" bypass?** It is the only remaining SOQL. | **A.** Keep → 1 SOQL per gate.<br>**B.** Drop it and grant the custom permission to `DPEG_Admin_Access` → **0 SOQL**. | 🟢 **A — keep.** B changes the admin population from "any MAD holder" to "any `DPEG_Admin_Access` holder", silently excluding integration users and any admin not in that set. The 2→1 SOQL cut is already the win; 1→0 is not worth a semantic change to admin access. |

### 3.1 Q1 in full — why Transaction is DEFERRED, and why *not* on symmetry grounds

`TransactionActionPermissionService`'s own header (shipped 2026-08-12, four days ago) says in
capitals: *"DO NOT 'harmonize' it with its two siblings"*, and records the user decision behind it.
Two honest observations, in both directions:

**The argument FOR including it is real and is NOT symmetry.** Today there is **no** flexipage
visibility rule for the Transaction Advance Stage button — `Transaction__c` appears in zero of the
seven driver-gated flexipages. That is not an oversight: **a visibility rule cannot test permission
set membership.** `$Permission` is the only mechanism available, so a Transaction custom permission
would, for the first time, make that button *hideable declaratively*. That is a new capability, not
a tidying.

**The argument AGAINST is stronger for this pass.** The justification for this whole refactor is
removing an FLS failure class. **Transaction's gate has no FLS in it at all** — it is membership-only
with no `User` field — so it has none of the problem being fixed. Including it costs a third custom
permission, a third UAT persona, and a rewrite of a class shipped four days ago, to buy ≤2 SOQL and a
declarative rule nobody has asked for.

⇒ **DEFER, with a named trigger** (not a date): *the first time someone wants the Transaction Advance
Stage button hidden on the record page.* At that moment the change is a one-line
`<customPermissions>` addition to `Transaction_Stage_Actions_Access` plus a `FeatureManagement` call —
and it would **not** disturb the membership-only decision, because the permission would be carried by
that same set, granting the identical population. Record that in the class header so the next reader
finds the argument rather than re-deriving it.

### 3.2 Q2 in full — does a custom permission change the layer-4/layer-5 argument?

**No. The argument is unchanged, and there is a concrete, file-verified reason it must not be
"simplified" now that the token is cheaper.**

ARCHITECTURE §2 states the model: layer 4 = *"can this code be reached at all"*; layer 5 =
*"is this specific user allowed"*. A custom permission changes the **token** (from FLS-on-a-checkbox
to a permission), not the **question**. Both questions still exist.

Two consequences of choosing B, one logical and one measured:

1. **Logical.** If the custom permission lived in `Opportunity_Stage_Actions_Access`, then everyone
   who can *call* the gate automatically *passes* it. `hasDealActionAccess()` could never return
   `false` for anyone able to reach it, so the clean-denial path becomes unreachable — the gate
   becomes a tautology. That is strictly worse than today.
2. 🔴 **Measured.** `Opportunity_Stage_Actions_Access` **is a member of `DPEG_Junior_Analyst_PSG`**
   (verified, line 50 of that group file). `Acquisition_Deal_Driver` is assigned **directly**,
   deliberately, *"because its population is narrower than any group's."* So option B grants
   deal-driving to the **entire Junior Analyst group in one deploy** — the exact widening three
   separate files in this repo exist to prevent.

⇒ **Option A. The layer-5 set keeps its job, its name and its population; only its token changes.**
Both `Acquisition_Deal_Driver` and `Opportunity_Stage_Actions_Access` carry long XML comments
forbidding the merge; those comments must be **amended in place** to describe the new token, not
deleted — they are still correct about the principle.

---

## 4. WHAT ACTUALLY CHANGES — the gate, before and after

### 4.1 Behaviour

| | Today | After |
|---|---|---|
| Factor (a) | FLS read on `User.<X>_Driver__c` via the layer-5 set, enforced by `WITH USER_MODE` (a **throw** is the denial signal) | holds custom permission (granted by the same layer-5 set) |
| Factor (b) | `<X>_Driver__c = true` on the user's own record | *(absorbed into (a) — one check)* |
| Failure mode when FLS is missing | 🔴 **Silent false negative.** A legitimate driver is denied and the button vanishes with no error anywhere. Happened in production (C1). | **Does not exist.** Custom permissions have no FLS. |
| Bare System Administrator | 🔴 **Locked out** unless "Modify All Data" is checked *first* — a documented, load-bearing statement ordering in two classes | Not locked out. The ordering constraint is **gone**. |
| Declarative rule | `{!$User.Deal_Driver__c}` EQUAL `true` | `{!$Permission.Acquisition_Deal_Actions}` EQUAL `true` |
| Undeployable org steps to provision a driver | **2** — assign the set AND tick the box | **1** — assign the set |

**The order can now be INVERTED, and that is a genuine win to take.** Today `hasModifyAllData()` MUST
run before the flag read or admins are locked out. After the change, checking the custom permission
**first** is safe and cheaper: a driver — the common case on these pages — pays **zero** queries, and
only a non-driver pays the one MAD lookup. 🔴 The two class headers currently say *"reversing these
two statements is a lockout, not a style choice"* — that sentence becomes **actively misleading** and
must be rewritten, not merely left standing.

### 4.2 SOQL cost — quantified (Gate 1 Q7 = A, MAD bypass kept)

`FeatureManagement.checkPermission(String)` costs **0 SOQL, 0 DML**.

| Path | Today | After | Δ |
|---|---|---|---|
| `OpportunityActionPermissionService.hasDealActionAccess()` | **2** (PermissionSetAssignment + User) | **1** (MAD only; **0** for a driver if the order is inverted) | −1 to −2 |
| `DispositionActionPermissionService.hasDispositionActionAccess()` | **2** | **1** (or 0) | −1 to −2 |
| `RecordStageAdvanceService.hasStageActionAccess(id)` — 1-sequence object (Underwriting, Dev_FR, Constr_FR) | **2** | **1** (or 0) | −1 to −2 |
| `RecordStageAdvanceService.hasStageActionAccess(id)` — 2-record-type object (NDA, LOI, Contract_Review) | **3** (1 row load + 2) | **2** (1 row load + 1) | −1 |
| `TransactionActionPermissionService` | ≤2 (shared cache) | unchanged — deferred | 0 |

⚠ **Two honest caveats, so this is not oversold:**

1. **The row load does NOT go away** on the three two-record-type objects. `hasStageActionAccess`
   loads the row to resolve the **record type**, which still decides *which* gate applies. That is
   1 SOQL per record view on a `cacheable=true` path and it survives the refactor untouched.
2. All figures are **per transaction**, not per call — both services already cache the answer in a
   static, and Lightning caches `cacheable=true` results client-side. The saving is real but modest.

⇒ **The SOQL saving is a secondary benefit. The justification is the FLS failure class (§0 P6).**
Do not lead with the query count.

### 4.3 The transaction cache

With Q7 = A the cache still guards 1 SOQL, so **keep `cachedHasDealActionAccess` and `clearCache()`
as-is.** (If the user picks Q7 = B, the cache becomes dead weight and `clearCache()` — a documented
`System.runAs` trap — should be deleted along with every test call to it. The two decisions are
coupled; do not split them.)

---

## 5. 🔴 MIGRATION SEQUENCE

### Step 0 — MEASURE FIRST. Blocking. No build starts until this returns.

Run in-org (not a repo check — this is org state):

```sql
SELECT Assignee.Username, Assignee.Name, Assignee.Deal_Driver__c
FROM   PermissionSetAssignment
WHERE  PermissionSet.Name = 'Acquisition_Deal_Driver'
```
```sql
SELECT Assignee.Username, Assignee.Name, Assignee.Disposition_Driver__c
FROM   PermissionSetAssignment
WHERE  PermissionSet.Name = 'Disposition_Deal_Driver'
```

**Any row where the flag is not `true` is a user who would be GRANTED deal-driving by this deploy.**

- Empty result for both ⇒ population-preserving. Proceed.
- Non-empty ⇒ **STOP and return to the user.** Those assignments must be removed first (an in-org
  action), or the design must change. Do not proceed on the assumption they are stale.

Also verify in-org, same step:
- `Acquisition_Deal_Driver` and `Disposition_Deal_Driver` are **not** members of any
  `PermissionSetGroup` (repo says direct-assignment; confirm against the org, because
  ARCHITECTURE §2 records a 2026-08-10 finding of a deployed group carrying a member the repo file
  did not list).
- Reconcile both layer-5 set files org→repo before editing. **A `PermissionSet` deploy REPLACES its
  entire grant list** — this repo has been bitten twice (2026-08-05, 2026-08-06).

### Step 1 — P0 SPIKE (see §7). Blocking. Nothing else is built until it passes.

### Step 2 — ONE ATOMIC DEPLOY

A Salesforce deploy is all-or-nothing, and every changed component is in it, so there is **no window
in which the rules and the Apex disagree**:

1. `customPermissions/Acquisition_Deal_Actions.customPermission-meta.xml` *(new)*
2. `customPermissions/Disposition_Deal_Actions.customPermission-meta.xml` *(new)*
3. `Acquisition_Deal_Driver` — **add** `<customPermissions>`; **KEEP** the existing
   `<fieldPermissions>` on `User.Deal_Driver__c`
4. `Disposition_Deal_Driver` — same shape
5. 7 flexipages — 24 criteria repointed (18 → `Acquisition_Deal_Actions`, 6 →
   `Disposition_Deal_Actions`) + 7 comment lines rewritten
6. `OpportunityActionPermissionService`, `DispositionActionPermissionService` — swap the flag read
   for `FeatureManagement.checkPermission`; invert the check order; rewrite the headers
7. Tests (§6)

🔴 **Keeping (3)/(4)'s `<fieldPermissions>` is the rollback lever and costs nothing.** With the flag
fields and their FLS still in place, rollback = redeploy the previous flexipages + Apex, and the old
gate works instantly. **That is strictly better than a dual-accept window: rollback capability with
no widening.**

### Step 3 — VERIFY IN-ORG (§7). Nothing is "done" until this passes.

### Step 4 — SOAK, then a SEPARATE retirement pass (§6). Not this change.

### 5.3 Why the dual-accept window (Gate 1 Q5-B) is *worse*, not merely unnecessary

The brief asks whether Apex should accept "flag OR custom permission" during a transition. Assessed
and **rejected**, for four reasons:

1. **It is a real widening for its duration** — the gate becomes the *union* of two populations.
2. **It is more code, not less.** The flag leg still reads `WITH USER_MODE`, which **throws** rather
   than degrades, so the OR is `try { flag } catch { false } || checkPermission()` — the exact
   fragile shape being removed, kept alive alongside its replacement.
3. **The window is unnecessary** because both signals are carried by the *same permission set* for
   the *same population* (§2). There is no state in which they disagree.
4. **This repo's own history says the cleanup would not happen.** ARCHITECTURE §3.3 and §3.4 are both
   labelled *"deliberate, TEMPORARY exception"* and both are still live, with §3.4 now carrying an
   explicit "this review is now OWED" note.

**If the user chooses Q5-B anyway,** the forcing function must be structural, not a calendar note:
schedule the flag-field deletion in the *same tranche*, because **a field with live Apex references
cannot be deleted** — so the retirement itself refuses to complete until the dual-accept branch is
gone. Do not rely on a TODO.

---

## 6. RETIREMENT OF THE TWO `User` FIELDS (Gate 1 Q6 — recommended: LATER PASS)

Not in this change. When it happens, note three things the brief's point 5 correctly anticipated:

1. **No backfill step.** The repo pattern is add → backfill → repoint → retire, but there is nothing
   to backfill: the custom permission is granted by set membership, not derived from the field value,
   and Step 0 has already **proven** the two populations identical.
2. 🔴 **`UserSelector` must be DELETED, not trimmed.** It has exactly two methods and both are flag
   reads. Removing them leaves a selector class with no methods. The brief is right that the
   "keep them as SEPARATE queries" reasoning evaporates — but the consequence is larger: this is the
   **first and only `User` SOQL in the application**, and deleting it means **any future `User` read
   must re-create the selector**. `UserSelectorTest` goes with it. Flag it in ARCHITECTURE §2 so the
   next feature does not inline a `User` query because "there is no selector".
3. **Order:** remove the `<fieldPermissions>` from the two layer-5 sets → delete `UserSelector` +
   its test → delete the two fields. Follow `docs/permission-set-retirement-runbook.md`'s
   GRANT → VERIFY → REMOVE → SOAK → DELETE. Deleting the fields also strands `<fieldPermissions>`
   stubs in `profiles/**`, which is harmless (force-ignored) and already a documented condition.

---

## 7. VERIFICATION

### 7.1 🔴 P0 SPIKE — BLOCKING, before any build

**Question:** does a flexipage `<visibilityRule><criteria>` with
`<leftValue>{!$Permission.Acquisition_Deal_Actions}</leftValue>`, `EQUAL`, `true` **deploy AND get
honoured by the renderer at API 67?**

**Why this is P0 and not a build detail:** §0 P7 records a **measured** case in this very repo of a
flexipage construct that deployed green, survived a retrieve, and was **silently ignored by the
renderer**. If `$Permission` behaves that way, the declarative half of this refactor is dead and only
the Apex half is achievable — a materially different, much smaller change the user should be told
about before work starts, not after.

**Method — a green deploy is NOT the pass criterion:**
1. Deploy the custom permission + **ONE** criterion on the lowest-risk page
   (`Development_Feasibility_Review_Record_Page`, exactly 1 rule).
2. `sf project retrieve` and confirm the `leftValue` round-trips unchanged.
3. 🔴 **Load the page as a user who HOLDS the permission → button visible.**
4. 🔴 **Load the page as a user who does NOT hold it → button HIDDEN.** *(Step 4 is the one that
   falsifies the P7 failure mode. Step 3 alone proves nothing.)*
5. Confirm the exact Metadata API token spelling via `salesforce-api-context` MCP; if unavailable,
   record `mcp=unavailable` and rely on the deploy+render probe.

**Secondary spike (cheap, same session):** confirm `FeatureManagement.checkPermission` reflects a
`PermissionSetAssignment` **inserted in the same test transaction** under `System.runAs`. The
existing suites already insert assignments before `Test.startTest()`
(`OpportunityActionPermissionServiceTest.assignPermissionSet`), so the fixture shape is proven — but
`checkPermission` reads a different platform surface than a `WITH USER_MODE` SOQL, and if it does not
see a fresh assignment, every positive test in both suites needs restructuring. Find that out now.

### 7.2 What automated testing CAN cover

- **Apex:** both services, `RecordStageAdvanceService.passesGate`, and the assert paths on
  `StageAdvanceController` / `OpportunityApprovalController` / `RecordStageAdvanceController`.
- **Jest:** unchanged — the guards call Apex only (P3).

**Test changes, stated explicitly so the implementer does not improvise:**

| Test | Action | Why |
|---|---|---|
| `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` | 🔴 **REWRITE — do not delete.** New name: `capabilitySetWithoutTheAuthorizationSet_isStillDenied`. Fixture: user holds **`Opportunity_Stage_Actions_Access`** (layer 4) but **not** `Acquisition_Deal_Driver` (layer 5) → asserts DENIED. | The property it pins was never *"the flag"* — it is **"capability ≠ authorization"**, which is still true and still needs a falsifier (§3.2). Deleting it leaves the next refactor nothing to stop it. Kept as-is it goes red and gets deleted by whoever is unblocking the build. |
| `...hasDealActionAccess_flagSetButNoFieldAccess_isDenied` | **DELETE.** | There is no "flag set but no access" state under custom permissions. It has no analogue; rewriting it would be inventing a test. |
| `...hasDealActionAccess_bareStandardUser_returnsFalse` | **KEEP**, fixture unchanged. | Still exactly right. |
| `...hasDealActionAccess_minimumAccessUser_deniesWithoutThrowing` | **KEEP.** | Still guards the deny-not-throw posture on the MAD read. |
| `DispositionActionPermissionServiceTest` | Mirror all of the above. | The two services are one design on two modules. |
| `UserSelectorTest` | **KEEP for now** (fields survive this pass); deleted with `UserSelector` in the retirement pass. | Rollback lever. |
| `RecordStageAdvanceServiceTest` / `RecordStageAdvanceControllerTest` | Update fixtures: assign the set, drop the flag-setting lines. | Fixture-only. |

⚠ **Positive-path fixtures get SIMPLER**, which is a real quality gain: "assign the set AND set the
flag true" becomes "assign the set".

### 7.3 🔴 What automated testing CANNOT cover — and the manual UAT it forces

**No test in this repo can see a flexipage visibility rule.** Not Apex, not Jest. `profiles/**` is
force-ignored, so no file-based check establishes FLS truth either. A rule that silently evaluates
`false` just hides a button — indistinguishable from *"this feature isn't for me."*

**Practical shape: 7 pages × 2 personas = 14 page loads, covering all 24 rules in BOTH directions.**

| Persona | Provisioning | Must observe |
|---|---|---|
| **1. Acquisitions deal driver** | holds `Acquisition_Deal_Driver` (+ `DPEG_Junior_Analyst_PSG`) | All **18** acquisition-gated buttons visible AND clickable across Opportunity (8), LOI (4), Contract_Review (1), NDA (1), Underwriting (2), Dev_FR (1), Constr_FR (1). |
| **2. Disposition deal driver** | holds `Disposition_Deal_Driver` | All **6** disposition-gated buttons visible AND clickable: LOI (3), NDA (2), Contract_Review (1). **Acquisition buttons NOT visible.** 🔴 This persona is where the original C1 defect lived — it is the highest-value check in the matrix. |
| **3. 🔴 Non-driver Junior Analyst** | `DPEG_Junior_Analyst_PSG` **only** — explicitly NOT either layer-5 set | **ZERO stage buttons on all 7 pages.** This is the persona that proves the widening did not happen (Gate 1 Q2/Q4). Without it the UAT is worthless. |
| **4. Bare System Administrator** | no layer-5 set | Buttons visible (Modify All Data bypass). Proves the admin lockout is gone. ⚠ **An admin smoke test proves nothing about personas 1–3** — three separate files in this repo say so. |
| **5. Principal / approver** (`DPEG_Principal_PSG`) | as provisioned | **No new buttons.** Both layer-5 sets are documented as *"not assigned to approvers"*; confirm that survived. |

**Also required, and easy to skip:** for personas 1–3, click one button per page and confirm the
server-side assert agrees with the chrome, and that a refusal surfaces the clean message
(`"You don't have permission to perform this action."`) — **never raw platform text**. Both guards do
`error.body.message` straight into a toast, so a class-access regression would surface as
*"You do not have access to the Apex class named …"*, which ARCHITECTURE §5 forbids.

### 7.4 Two structural checks on the flexipage edit

1. 🔴 **Surgical edit only — do NOT regenerate any flexipage.** Enabling/regenerating Dynamic Actions
   is documented in this repo as **silently emptying a page's action list** (3 of 5 pages were left
   with zero buttons, and no automated check can see it). Acceptance criterion: the git diff on each
   of the 7 files shows **only** changed `<leftValue>` lines plus the comment rewrites — **no change
   to any `<actionName>`, `<valueListItems>` count, or `<booleanFilter>`.**
2. **`<booleanFilter>` strings must not change.** Each criterion is being swapped 1:1 in place, so
   every filter stays a pure chain of ANDs. Per `Is_Decline_Allowed__c`'s measured note, do not take
   the opportunity to "simplify" any filter into an OR.

---

## 8. 🔵 ADMIN WORK (`salesforce-admin`)

- **2 new Custom Permissions**: `Acquisition_Deal_Actions`, `Disposition_Deal_Actions`.
- **2 permission set edits**: add `<customPermissions>` to `Acquisition_Deal_Driver` and
  `Disposition_Deal_Driver`; **keep** existing `<fieldPermissions>`; amend the XML comments.
- **7 flexipage edits**: 24 criteria repointed + 7 comment lines rewritten.

## 9. 🟢 DEVELOPMENT WORK (`salesforce-developer`)

- `OpportunityActionPermissionService`, `DispositionActionPermissionService` — swap the check, invert
  the order, rewrite headers.
- Test updates per §7.2.
- `lwc/dealActionGuard/dealActionGuard.js`, `lwc/recordStageGuard/recordStageGuard.js` — **header
  comments only**, no code, no Jest change.
- `RecordStageAdvanceService` header comment (the gate table's DEAL_DRIVER / DISPOSITION_DRIVER rows
  describe the flag mechanism). **The `StageActionGate` enum VALUES do not change** — they name the
  gate, not the mechanism. Renaming them is churn across a config map for zero benefit.

## 10. 🔗 EXECUTION ORDER

1. **Step 0 org measurement** (§5) — blocking, returns to user if non-empty.
2. **P0 spike** (§7.1) — blocking; a negative result changes the whole design.
3. Admin: custom permissions → permission sets → flexipages.
4. Developer: services → tests.
5. One atomic deploy (§5 Step 2).
6. Manual UAT as 5 personas (§7.3).
7. ARCHITECTURE §2 update **in the same PR** (§6 rule): the two-factor subsection, the seven-layer
   table's layer-5 row, and the `WITH SYSTEM_MODE` table's *"Permission-gate reads"* row.
8. Retirement pass — **later, separate** (§6).

---

## 11. PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md §2 ("Permission Set Architecture — the seven-layer model") and
agent-output/design-requirements-custom-permissions.md before starting.

PRECONDITIONS — do not start until both are confirmed by the orchestrator:
 (1) The Step 0 org measurement returned EMPTY for both permission sets.
 (2) The P0 spike (§7.1) passed — a $Permission criterion is honoured by the RENDERER,
     not merely deployed.

⚠ SKILL GATE: this repo has no `sf-custom-permission` skill and no customPermissions/
directory. Per .claude/rules/salesforce-global-rule.md you must record
best_matched_skill before writing. Use `sf-metadata` for CustomPermission and
`sf-permission-set` / `sf-flexipage` for the other two types, and attempt
salesforce-api-context MCP for EACH type. If you judge no skill matches
CustomPermission, STOP and ask — do not write it unskilled.

TASK 1 — two new Custom Permissions (API version from sfdx-project.json = 67.0):
  force-app/main/default/customPermissions/Acquisition_Deal_Actions.customPermission-meta.xml
  force-app/main/default/customPermissions/Disposition_Deal_Actions.customPermission-meta.xml
  Labels: "Acquisition Deal Actions" / "Disposition Deal Actions".
  Descriptions must state that this permission is the layer-5 AUTHORIZATION token for the
  stage quick actions, that it replaces User.Deal_Driver__c / User.Disposition_Driver__c,
  and that it must NEVER be added to a layer-4 capability set.

TASK 2 — edit two permission sets. RECONCILE ORG -> REPO FIRST: a PermissionSet deploy
REPLACES its entire grant list (this repo was bitten twice, 2026-08-05 and 2026-08-06), so
retrieve each set from the org and confirm the repo file carries every org-side grant before
you edit it.
  Acquisition_Deal_Driver  -> add <customPermissions> for Acquisition_Deal_Actions
  Disposition_Deal_Driver  -> add <customPermissions> for Disposition_Deal_Actions
  🔴 KEEP the existing <fieldPermissions> entries in BOTH files. They are the rollback lever
     and are retired in a separate, later pass. Do not remove them.
  Amend each file's existing XML comment (which sits INSIDE the root element deliberately —
  a comment above the root breaks `sf` at source conversion) to describe the new token:
  the set is still layer-5 AUTHORIZATION, it still must never merge with the layer-4
  capability set, and the reason is now "it would grant the whole DPEG_Junior_Analyst_PSG
  population" rather than "it would collapse the FLS factor".

TASK 3 — repoint 24 flexipage visibility criteria across 7 files.
  {!$User.Deal_Driver__c}        -> {!$Permission.Acquisition_Deal_Actions}   (18 criteria)
  {!$User.Disposition_Driver__c} -> {!$Permission.Disposition_Deal_Actions}   ( 6 criteria)
  Operator EQUAL and rightValue true are UNCHANGED in every case.

  Exact per-file counts (verified — the two flags are interleaved in three files, so a blind
  find/replace WILL corrupt the disposition rules):
    Opportunity_Record_Page                        8 acq  / 0 disp
    LOI_Record_Page                                4 acq  / 3 disp
    NDA_Record_Page                                1 acq  / 2 disp
    Contract_Review_Record_Page                    1 acq  / 1 disp
    Underwriting_Record_Page                       2 acq  / 0 disp
    Development_Feasibility_Review_Record_Page     1 acq  / 0 disp
    Construction_Feasibility_Review_Record_Page    1 acq  / 0 disp

  Also rewrite the 7 XML COMMENT LINES that describe the old FLS mechanism (Contract_Review
  x3, LOI x2, NDA x2). They currently explain that a disposition driver holds no FLS on
  Deal_Driver__c so the criterion can never evaluate true for them — that mechanism no longer
  exists and the prose would mislead the next reader.

  🔴 SURGICAL EDIT ONLY. Do NOT regenerate any flexipage and do NOT touch Dynamic Actions
  configuration — this repo has a documented incident where that silently emptied the action
  list on 3 of 5 pages with no error and no failing test. Acceptance criterion: the git diff
  on each of the 7 files shows ONLY changed <leftValue> lines plus the comment rewrites, with
  NO change to any <actionName>, no change to the number of <valueListItems>, and no change
  to any <booleanFilter> string.

DO NOT DEPLOY. Create metadata files only.
DO NOT create, rename or delete any permission set, permission set group, or User field.
DO NOT add anything to Opportunity_Stage_Actions_Access or Transaction_Stage_Actions_Access.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md §2 and agent-output/design-requirements-custom-permissions.md first.

Swap the two-factor *_Driver__c gates for a single Custom Permission check. The custom
permissions and permission set edits are being produced by the admin agent — assume
Acquisition_Deal_Actions and Disposition_Deal_Actions exist.

TASK 1 — OpportunityActionPermissionService.computeDealActionAccess()
  Replace the UserSelector.selectDealDriverFlagForCurrentUser() read (and its
  try/catch(QueryException)) with:
      FeatureManagement.checkPermission('Acquisition_Deal_Actions')
  🔴 INVERT THE CHECK ORDER: test the custom permission FIRST, then hasModifyAllData().
  This is now safe and is a real saving — checkPermission costs 0 SOQL, so a deal driver
  (the common case on these pages) pays ZERO queries, and only a non-driver pays the one
  PermissionSetAssignment lookup.
  KEEP: the AccessDeniedException type, NO_PERMISSION_MESSAGE (byte-identical wording),
  hasModifyAllData(), the transaction cache + clearCache(), simulateLookupFailure, and the
  rule that a permission-machinery failure PROPAGATES rather than being swallowed.

TASK 2 — DispositionActionPermissionService: the identical change with
  'Disposition_Deal_Actions'. These two classes are ONE design on two modules — change both
  or neither, and keep them line-for-line parallel.

TASK 3 — class headers. Both classes carry a long "THE GATE IS TWO-FACTOR, AND THAT IS THE
  WHOLE POINT" section and an ADMIN BYPASS section stating that reversing the two statements
  is a lockout. 🔴 Both are now WRONG and would actively mislead — rewrite them:
   - the gate is ONE factor: holding the layer-5 authorization permission;
   - capability (layer-4 Apex class access) and authorization (layer-5 custom permission)
     are STILL separate and must never merge — that argument is unchanged, and the reason is
     now that Opportunity_Stage_Actions_Access is a member of DPEG_Junior_Analyst_PSG, so
     merging would grant deal-driving to that entire group in one deploy;
   - the admin-lockout ordering constraint is GONE because custom permissions have no FLS;
   - state that an admin smoke test STILL proves nothing (the Modify All Data bypass remains).

TASK 4 — tests. Follow §7.2 of the design doc EXACTLY; the decisions are already made:
   - REWRITE (do not delete) hasDealActionAccess_membershipWithoutTheFlag_isStillDenied as
     capabilitySetWithoutTheAuthorizationSet_isStillDenied — user holds
     Opportunity_Stage_Actions_Access but NOT Acquisition_Deal_Driver, asserts DENIED. It
     pins "capability != authorization", which is still true and still needs a falsifier.
   - DELETE hasDealActionAccess_flagSetButNoFieldAccess_isDenied (no analogue exists).
   - KEEP hasDealActionAccess_bareStandardUser_returnsFalse and
     hasDealActionAccess_minimumAccessUser_deniesWithoutThrowing.
   - Mirror all of the above in DispositionActionPermissionServiceTest.
   - Update RecordStageAdvanceServiceTest / RecordStageAdvanceControllerTest fixtures: assign
     the permission set, drop the flag-setting lines.
   - Keep the existing assignPermissionSet-before-Test.startTest() fixture shape.
   - Keep the Limits.getQueries() assertions and TIGHTEN them to the new budget.

TASK 5 — comment-only edits, NO code change (verified: both files reference the flags in
  Javadoc prose only, never in code, and no Jest test touches them):
   - lwc/dealActionGuard/dealActionGuard.js
   - lwc/recordStageGuard/recordStageGuard.js
   - RecordStageAdvanceService class header (the gate table's DEAL_DRIVER /
     DISPOSITION_DRIVER rows describe the flag mechanism).
  ⚠ Do NOT rename the StageActionGate enum values. They name the GATE, not the mechanism;
  renaming them is churn across a config map for zero behavioural benefit.

DO NOT: delete or modify User.Deal_Driver__c / User.Disposition_Driver__c, delete
UserSelector or UserSelectorTest (both are the rollback lever and are retired in a separate
later pass), touch TransactionActionPermissionService or LeadActionPermissionService, or
change any permission set file.
DO NOT DEPLOY.
```

---

## 12. RESIDUALS — stated, not hidden

- **R1.** The 24 flexipage rules have **no automated coverage of any kind**, before or after. This
  change does not make that worse, but it does not improve it either. §7.3's manual UAT is the only
  control that exists.
- **R2.** Custom permission **assignment via `PermissionSetAssignment` is still not deployable** — a
  fresh org (or a scratch rebuild) needs the two layer-5 sets assigned by hand. That is unchanged
  from today, and is now the **only** manual provisioning step per driver instead of two.
- **R3.** The two `User` fields, their FLS grants and `UserSelector` survive this pass by design
  (Q6). Until the retirement pass they are dead-but-live metadata, and someone reading the schema
  will reasonably believe the flags still govern access. **Mitigation: the field descriptions should
  say they are retired-pending-deletion.** That is a one-line admin edit and is the only reason to
  touch those field files in this pass — flag it to the user rather than assuming it.
- **R4.** If the user later chooses to include `Transaction__c` (Gate 1 Q1-B), the gate mechanism
  changes but the **membership-only policy and its team-wide granularity do not** — per-user
  revocation still does not exist without removing the user from `DPEG_Transaction_Team`. Do not let
  a mechanism swap be read as fixing that.
