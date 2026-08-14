# P2-D3 — retire the old `PSA` Opportunity stage value

Staged, **not applied**. The working tree must stay deployable at P2-D1/P2-D2 until the backfill
is done, so this subtractive step lives here as a script rather than as tree edits.

Full context: `agent-output/runbook-acquisition-observations-phase2.md` §3 (P2-D3) and §4.

## Contents

| File | Role |
|---|---|
| `apply-d3.js` | The apply mechanism. `node apply-d3.js --check` validates every edit in memory and writes nothing; `node apply-d3.js` validates then writes **all or none**. Each edit asserts **exactly one match** and aborts loudly, naming the file, on any drift. |

The script applies **five** edits (four if P1-D4 has already deleted the `Commercial` business
process): deactivate the `PSA` standard value, remove `PSA` from each business process that
still lists it, and **drop `PSA` from `reports/Acquisitions/Deal_Pipeline_by_Stage`'s
`STAGE_NAME` filter** — that last one is the file the P2 reference inventory missed; see the
comment above the edit in `apply-d3.js` for why every delimiter-anchored pattern walked past it.

⚠ **That report shipped with BOTH values at P2-D1** (not P2-D2 — it is additive and resolves
nothing, so it is correct on both sides of the backfill; runbook §1.1). **This script does not
depend on that**: its needle is matched against the repo tree, whose content is the same
whichever step deployed it, and nothing here reads the org.

There is deliberately **no `.diff` file and no `destructiveChanges.xml`.**

- No diff, because a `diff -u` snapshot goes stale **silently** between the day it is staged and
  the day the gate opens — which for a gated step is by design. The script fails loudly instead.
- No destructive package, because **nothing is deleted at D3.** The standard picklist value is
  *deactivated* (a stage value with history must stay resolvable to every historical report,
  dashboard and audit row) and the BusinessProcess entries go away by re-deploying those two
  files without them.

## Preconditions — RE-RUN THESE NOW, do not trust them from when this package was written

```sql
-- must be 0 AT THIS MOMENT, not "was 0 after the backfill"
SELECT COUNT() FROM Opportunity WHERE StageName = 'PSA'

-- must be non-zero and equal the pre-backfill extract's row count
SELECT COUNT() FROM Opportunity WHERE StageName = 'Under Contract (PSA)'
```

🔴 **The first count can drift back above zero after the backfill passed.** Until the P2-D2 Apex
deploy lands, `StageAdvanceService.NEXT_STAGE` still maps `'LOI' ⇒ 'PSA'`, so the Advance quick
action keeps minting rows on the old value. If the count is not 0, re-run the backfill on the
survivors before running this script. Runbook §4, risk 2.

Also confirm P2-D2 has fully deployed — **both** the declarative files and the developer agent's
Apex/LWC repoints. Retiring the value while any code still writes it turns a working button into
a runtime error.

## Run

```bash
node agent-output/p2-d3-retire-psa/apply-d3.js --check
node agent-output/p2-d3-retire-psa/apply-d3.js
```

Then deploy:

```
force-app/main/default/standardValueSets/OpportunityStage.standardValueSet-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Retail.businessProcess-meta.xml
force-app/main/default/reports/Acquisitions/Deal_Pipeline_by_Stage.report-meta.xml
```

`objects/Opportunity/businessProcesses/Commercial.businessProcess-meta.xml` is included only if
Phase 1's D4 has not yet deleted it. The script reports a SKIP rather than failing when the file
is absent — that is the expected state once P1-D4 has run.

## ⚠ The one unverified step, and its fallback

`<isActive>false</isActive>` on a `StandardValue` is **not verified in this org.** The element
ordering used (`<default>` → `<isActive>` → `<label>`) is taken from
`objects/Contract_Review__c/fields/Stage__c.field-meta.xml`, which carries three deactivated
values in exactly that shape — but that is a `CustomValue` precedent, and **no file under
`standardValueSets/` in this repo has ever carried `<isActive>`** (measured: zero hits).
`StandardValue` extends `CustomValue` in the Metadata API, which is why this is expected to
work. Expected is not measured, and the Metadata API `StandardValueSet` reference page does not
enumerate the field.

### 🔴 If the deploy rejects it — REVERT THE FILE FIRST. `--skip-svs` alone does NOT undo it.

The rejection is only knowable **after** the deploy, and by then `apply-d3.js` has already
written `<isActive>false</isActive>` into the tree. `--skip-svs` only tells a **future** run to
leave the file alone; it does not remove the element that is already there. Re-running with the
flag and nothing else leaves the repo carrying a `standardValueSets/OpportunityStage` the org
refuses — so **every later deploy that includes that file fails**, for a reason that has nothing
to do with the change being made at the time.

Recover in this order:

```bash
# 1. REVERT the tree edit that was rejected. Do this BEFORE anything else.
git checkout -- force-app/main/default/standardValueSets/OpportunityStage.standardValueSet-meta.xml

# 2. Confirm the element is gone (must print nothing).
grep -n "isActive" force-app/main/default/standardValueSets/OpportunityStage.standardValueSet-meta.xml

# 3. Re-run with the flag, so only the independent halves are applied.
node agent-output/p2-d3-retire-psa/apply-d3.js --skip-svs --check
node agent-output/p2-d3-retire-psa/apply-d3.js --skip-svs
```

⚠ Step 1 discards **only** this file's working-tree change. If the business-process and report
edits were written by the same run, they are in **other** files and step 1 does not touch them;
step 3 then reports them as `SKIP (already applied)`, which is the expected and correct output.

Then deactivate `PSA` **by hand** in Setup → Object Manager → Opportunity → Fields &
Relationships → Stage, and deploy the business-process and report files. The halves are
independent: the hand deactivation and the file deploys can happen in either order.

## Verify

```bash
sf sobject describe --sobject Opportunity --target-org usman.khan.dpeg@avanzasolutions.com
```

`Under Contract (PSA)` must be present and active. `PSA` must be **either absent from the value
list or reported `active: false`** — record which of the two shapes you observe, because this org
has no prior inactive standard value to compare against.

Retrieve both business processes and confirm neither lists `PSA`:

```bash
sf project retrieve start \
  --metadata "BusinessProcess:Opportunity.Land" \
  --metadata "BusinessProcess:Opportunity.Retail" \
  --target-org usman.khan.dpeg@avanzasolutions.com \
  --target-metadata-dir <scratch> --unzip --wait 20
```

⚠ An **empty** retrieve proves nothing. Confirm each file is non-empty before trusting it.

## 🔴 Do not touch the disposition files

`Disposition__c.Disposition_Stage__c` has its own, unrelated `PSA` value. This script names its
four target files explicitly and touches nothing else — but if you extend it, read
`agent-output/runbook-acquisition-observations-phase2.md` §0.1 first. It lists the twelve
disposition files that must never be caught by a `PSA` sweep, and explains why doing so deploys
green and passes every test while being wrong.
