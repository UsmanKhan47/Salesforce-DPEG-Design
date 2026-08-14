# P1-D4 — retire `Commercial` (SUBTRACTIVE — GATED, DO NOT DEPLOY EARLY)

**Author:** salesforce-solution-architect · **Date:** 2026-08-14
**Governing runbook:** `agent-output/runbook-acquisition-observations-phase1.md` §3 (step P1-D4)

---

## 🔴 Why this is a separate package and not applied to the tree

Everything here is **subtractive**. The working tree is deliberately held at **P1-D1 state**
(`Commercial` and `Retail` coexist everywhere), because the tree must stay deployable at every
step *before* D4. If these edits sat in the tree, any deploy taken for an unrelated reason
between now and D4 would delete a picklist value that live rows still hold.

**None of this may be applied until BOTH of the following have landed and been verified BY ORG
QUERY, not by a green deploy:**

| Precondition | Verify with |
|---|---|
| **[MIG]** — the row backfill is complete | `SELECT COUNT() FROM Lead WHERE Deal_Type__c = 'Commercial'` → **0**<br>`SELECT COUNT() FROM Opportunity WHERE Deal_Type__c = 'Commercial'` → **0**<br>`SELECT COUNT() FROM Opportunity WHERE RecordType.DeveloperName = 'Commercial'` → **0** |
| **P1-D3** — every live reference repointed to `Retail` | repo grep for `Commercial` returns only `profiles/`, the 5 verified false positives, and prose |

🔴 **Re-run the three [MIG] queries IMMEDIATELY BEFORE D4b, not once at migration time.** A
record type with records still assigned cannot be deleted, and a row created between the
migration and this step re-arms that block.

🔴 **D4 IS THE POINT OF NO RETURN.** Deleting a picklist value and a record type is not
reversible by deploy — recreating them does not restore row values. The only rollback is the
`lead_dealtype_before.csv` / `opp_dealtype_before.csv` extracts taken at [MIG]. **Confirm those
exist before starting.**

---

## Contents

| File | What it is |
|---|---|
| `apply-d4.js` | **The apply mechanism.** Node script, no dependencies. **TWO-PHASE: it validates every edit in memory first, asserting EXACTLY ONE MATCH each, and writes only if ALL of them validated** — so a drift on the last edit leaves the tree untouched rather than half-converted. Supports `--check` (validate, write nothing). |
| `d4a-deactivate.diff` | Review artifact for pass **a**. Human-readable record of the deactivation edits. |
| `d4b-remove.diff` | Review artifact for pass **b**. Human-readable record of the removal edits. |
| `destructiveChangesPost.xml` | Deletes the `Commercial` RecordType + BusinessProcess. |
| `package.xml` | 🔴 **NOT empty — it lists all eight files `apply-d4.js b` edits.** See D4b below. |

> 🔴 **THIS ROW SAID "Empty companion manifest, required alongside a destructive manifest" until
> 2026-08-14 and that description was STALE, not merely terse — it described the pre-W4 state and
> contradicted the D4b section of this same file, which argues at length that the manifest must
> NOT be empty (re-review drift 1).** An operator skimming the table could have "restored" an
> empty manifest and silently reinstated W4 on the **irreversible** pass: the run would deploy
> nothing, the org's `DPEG_Acquisition_Edit` and `DPEG_Admin_Access` would still carry
> `<recordType>Opportunity.Commercial</recordType>` when the destructive half fired, and the
> delete is refused — while the `apply-d4.js b` edits sat in the working tree looking done.
> An empty manifest is correct in **exactly one** place: step 2 of the split-run fallback in D4b.

⚠ **The two `.diff` files are FOR REVIEW ONLY — apply with `apply-d4.js`, not with `git apply`.**
They are plain `diff -u` output taken from the D1 tree as it stood on 2026-08-14; if any of the
nine files changes before D4 the diff context goes stale silently, whereas the script fails
loudly. `d4b-remove.diff` assumes `d4a-deactivate` has already been applied — **that is a property
of the DIFF, not of the script**: `apply-d4.js b` accepts the tree either way (see D4a below).

---

## Execution order

### Step D4a — deactivate (reversible)

```bash
node agent-output/p1-d4-retire-commercial/apply-d4.js a --check   # validate, write nothing
node agent-output/p1-d4-retire-commercial/apply-d4.js a           # apply
```

Sets `<active>false</active>` on the `Commercial` record type, and `<isActive>false</isActive>`
on the `Commercial` value of both `Deal_Type__c` fields. Deploy:

```
force-app/main/default/objects/Lead/fields/Deal_Type__c.field-meta.xml
force-app/main/default/objects/Opportunity/fields/Deal_Type__c.field-meta.xml
force-app/main/default/objects/Opportunity/recordTypes/Commercial.recordType-meta.xml
```

> ⚠ **A record type must be INACTIVE before it can be deleted.** That is what makes this pass
> mandatory rather than cosmetic — D4b's destructive manifest fails against an active type.
> ⚠ **`<isActive>false</isActive>` on a custom picklist value is the one construct in this pack
> with no in-repo precedent.** If the Metadata API rejects it, deactivate the two values in
> Setup instead (an in-org step, not deployable) — or skip the value-deactivation half
> entirely and go straight to D4b, which is safe **only because** the [MIG] queries returned 0.
> Do not skip the RECORD TYPE half; that one is load-bearing.
> ✅ **Either of those fallbacks is now genuinely supported by pass `b`** (fixed 2026-08-14): both
> leave the file carrying the **active** `<value>` block, and pass `b` used to match only the
> **deactivated** one, so it aborted on its very first edit and this fallback was advice the tool
> could not honour. `b` now accepts either form and prints which one it matched. The two forms are
> mutually exclusive — one carries the `<isActive>` line, the other does not — so this is not a
> loosening of the exactly-one-match rule.

**[ORG-Q] Verify:**
```sql
SELECT Id, DeveloperName, IsActive FROM RecordType
WHERE SobjectType = 'Opportunity' AND DeveloperName = 'Commercial'
```
→ one row, `IsActive = false`.

---

### Step D4b — remove (irreversible)

**RECONCILE `DPEG_Acquisition_Edit` AND `DPEG_Admin_Access` ORG → REPO FIRST — gate G4.** A
`PermissionSet` deploy REPLACES its entire `<fieldPermissions>` set and its entire
`<recordTypeVisibilities>` list; a grant added org-side since 2026-08-14 will be silently wiped.
`DPEG_Admin_Access` in particular has already been found drifty once (six duplicated record
types, runbook §2 Finding B). Retrieve to a scratch dir and diff before touching it — and
confirm the retrieved file is **non-empty**, because an empty retrieve proves nothing.

```bash
node agent-output/p1-d4-retire-commercial/apply-d4.js b --check   # validate, write nothing
node agent-output/p1-d4-retire-commercial/apply-d4.js b           # apply
```

> 🔴 **RUN `--check` FIRST ON THIS PASS.** It reports every drifted edit at once, before anything
> is written — which matters here because D4b is the irreversible half and because the failure it
> is most likely to hit is a `PermissionSet` that moved org-side since 2026-08-14 (the gate above).

This performs, in ONE atomic pass — **every edit is validated in memory first and NOTHING is
written unless ALL 12 validate** — with an exactly-one-match assertion on each:

| # | File | Edit |
|---|---|---|
| 1 | `objects/Lead/fields/Deal_Type__c.field-meta.xml` | remove the `Commercial` `<value>` block |
| 2 | `objects/Opportunity/fields/Deal_Type__c.field-meta.xml` | same |
| 3 | `objects/Lead/recordTypes/Acquisition_Broker.recordType-meta.xml` | remove the `Commercial` `<values>` block under the `Deal_Type__c` `<picklistValues>` |
| 4 | `objects/Lead/recordTypes/IR_Investor.recordType-meta.xml` | same |
| 5 | `objects/Opportunity/recordTypes/Land.recordType-meta.xml` | same |
| 6 | `objects/Opportunity/recordTypes/Retail.recordType-meta.xml` | same, **plus** retire the transitional comment and rewrite `<description>` |
| 7 | `permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml` | remove `<recordType>Opportunity.Commercial</recordType>` + retire the D1-window comment |
| 8 | `permissionsets/DPEG_Admin_Access.permissionset-meta.xml` | same |

> 🔴 **FIVE record-type files enumerate the value, not four.** The four from §9 C12
> (`Acquisition_Broker`, `IR_Investor`, `Land`, `Commercial`) plus the **transitional fifth**,
> `Opportunity/recordTypes/Retail`, which carries `Commercial` on purpose through the D1→D4
> window — its own XML comment says so. `Commercial.recordType-meta.xml` is not edited; it is
> deleted whole below. A record-type file that OMITS a picklist silently drops all of that
> picklist's values from that type, which is why every file must be edited rather than left.

Then deploy those eight files, and delete the record type and business process — **one command,
because the two halves must happen in that order in the same run**:

```bash
sf project deploy start --manifest agent-output/p1-d4-retire-commercial/package.xml \
  --post-destructive-changes agent-output/p1-d4-retire-commercial/destructiveChangesPost.xml \
  --target-org usman.khan.dpeg@avanzasolutions.com
```

Finally delete the two source files:
```
force-app/main/default/objects/Opportunity/recordTypes/Commercial.recordType-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Commercial.businessProcess-meta.xml
```

> 🔴 **`package.xml` LISTS ALL EIGHT FILES AS MEMBERS, AND IT MUST — an empty manifest silently
> breaks the very argument that makes `--post-destructive-changes` correct (review W4, fixed
> 2026-08-14).** `--post-` is right *because* the record type has to be removed from the two
> permission sets **in the same run, before** it is deleted. That reasoning only holds if those
> permission sets are actually IN the run. Until this fix the manifest carried nothing but
> `<version>67.0</version>`, so the run deployed **zero** files: the org's
> `DPEG_Acquisition_Edit` and `DPEG_Admin_Access` would still have carried
> `<recordType>Opportunity.Commercial</recordType>` at the moment the destructive half fired,
> and the delete is **refused**. The `apply-d4.js b` edits would have sat in the working tree,
> looking done, having reached the org through no command in this file.
> ⇒ **The eight members and the `--post-` flag are one mechanism. If you ever empty the manifest,
> you must also stop claiming `--post-` is correct.**
>
> ⚠ **The alternative, if the single run has to be split** (e.g. the combined deploy is rejected
> and you want to isolate which half failed) — two commands, in this order, never reversed:
> ```bash
> # 1. the eight files FIRST, so nothing references the record type any more
> sf project deploy start --manifest agent-output/p1-d4-retire-commercial/package.xml \
>   --target-org usman.khan.dpeg@avanzasolutions.com
> # 2. THEN the destructive half, with an empty companion manifest
> sf project deploy start --manifest <an-empty-manifest.xml> \
>   --post-destructive-changes agent-output/p1-d4-retire-commercial/destructiveChangesPost.xml \
>   --target-org usman.khan.dpeg@avanzasolutions.com
> ```
> An **empty** companion manifest is correct in step 2 and only in step 2 — there the run genuinely
> has nothing to deploy, because step 1 already deployed it. Do not reuse `package.xml` for step 2;
> re-deploying the eight files is harmless but it makes the two steps indistinguishable in the
> deploy history.
>
> ⚠ **There is NO destructiveChanges precedent in this repo — this is the first.** Expect to
> iterate on the manifest. `RecordType` and `BusinessProcess` members are named
> `<Object>.<DeveloperName>`; note that `Opportunity.Commercial` appears in
> `destructiveChangesPost.xml` and must **not** also appear in `package.xml`.

**[ORG-Q] Verify:**
```sql
SELECT COUNT() FROM Lead        WHERE Deal_Type__c = 'Commercial'
SELECT COUNT() FROM Opportunity WHERE Deal_Type__c = 'Commercial'
SELECT Id, DeveloperName FROM RecordType
WHERE SobjectType = 'Opportunity' AND DeveloperName = 'Commercial'
```
First two → 0. Third → **no rows**. Then re-describe both objects and confirm `Commercial` is
absent from `Deal_Type__c.picklistValues`:
```bash
sf sobject describe --sobject Lead        --target-org usman.khan.dpeg@avanzasolutions.com
sf sobject describe --sobject Opportunity --target-org usman.khan.dpeg@avanzasolutions.com
```

---

## What this package deliberately does NOT touch

- **`Construction_Feasibility_Review__c.Deal_Type__c`, `Contract_Review__c.Deal_Type__c`,
  `Development_Feasibility_Review__c.Deal_Type__c`** — all three are **formula Text** fields
  (`TEXT(Opportunity__r.Deal_Type__c)`), not picklists. They carry no values to remove and
  start returning `Retail` on their own after [MIG]. 🔴 **The source spec §2.6 D1 instructs
  "Add `Retail` to `Deal_Type__c` on Lead, Opportunity, `Contract_Review__c`" — that third
  target is WRONG and unbuildable**; there is no value set on a formula field. Verified
  2026-08-14 by opening all five `Deal_Type__c` files.
- **The prose/comment wave** — `LOI__c/recordTypes/{Acquisition,Disposition}_LOI` cite
  `objects/Opportunity/recordTypes/Commercial.recordType-meta.xml` **by file path**, a path
  that ceases to exist here; `No_Backward_Stage_Movement`'s rank-map comment,
  `Construction_Feasibility_Review_Record_Page` and `Construction_Feasibility_Path` carry
  user-facing prose *"Commercial deal forwarded for a construction condition assessment"*.
  These belong to the **D3** comment wave (requirements §6.1 ⚪), not to D4.
- **Reports and dashboards** filtering `Deal_Type__c = 'Commercial'` — org-side, not fully
  represented in this repo, and they break **silently** because they reference by name and do
  not block the change. Gate **G8**.
