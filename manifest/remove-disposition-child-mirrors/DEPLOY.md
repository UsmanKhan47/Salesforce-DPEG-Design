# Deploy — remove Disposition child-mirror fields (2026-08-25)

**STATUS: PREPARED, NOT DEPLOYED.** Nothing here has been run against any org. Do not run it
without the user's explicit go-ahead.

---

## 🔴 SUPERSEDED IN PART — 2026-08-26

**Do not run this payload as written.** On 2026-08-26 the user chose **option A**: restore
`Disposition__c.Primary_LOI__c` and `Primary_PSA__c`, and rebuild the NDA / LOI / PSA Details
sections on **spanning field items** (`Record.Primary_LOI__r.Stage__c` and friends) rather than on
local mirror fields.

What that leaves of this manifest:

| Component | Still to be deleted? |
|---|---|
| The 15 formula mirror fields (5 `NDA_*__c`, 9 `LOI_*__c` / `PSA_*__c`, plus `LOI_Status__c`) | **YES.** A FlexiPage `fieldItem` CAN traverse a relationship — the premise those mirrors existed to work around was simply wrong. They are not coming back. |
| `Disposition__c.Primary_LOI__c` / `Primary_PSA__c` | **NO — restored.** Remove both from `destructiveChangesPost.xml` before running anything. |
| `DispositionPrimaryChildStampQueueable` | **NO — restored**, along with both enqueues in `DispositionStageEntryService`. Remove from the destructive manifest. |

⚠ **The lookups may never have been deleted from the org at all.** The status line above says
PREPARED, NOT DEPLOYED. Check the org before assuming a backfill is needed — if the destructive half
never ran, the existing stamps are intact and `scripts/backfill-disposition-primary-children.apex`
finds nothing to do. It is idempotent, so running it either way is safe.

⚠ **Two permission-set claims below are now wrong in the same direction.** `DPEG_Disposition_Edit`
and `DPEG_Disposition_View` carry the two lookup grants again, and each **gained**
`NDA__c.Date_Sent__c` and `NDA__c.NDA_Expiry_Date__c` (read-only) on 2026-08-26 — a gap the deleted
formula mirrors had been masking, because a formula field needs FLS on **itself**, not on the fields
it references. A spanning item checks the child field, so the gap became visible the moment the
mirrors went away.

⚠ **The `--tests DispositionStageEntryServiceTest` line below is still the right test class**, but
its content changed: `loiAndPsaAutoCreateEnqueueNothing` is back to
`loiAndPsaAutoCreateEachEnqueueOneParentStamp` (asserting 2), and
`primaryChildStampQueueableIsInertOnAnEmptyOrNullMap` is restored.

---

Read `package.xml` first — it carries the reasoning, the inventory and the two pre-flight checks.
This file exists only because an XML comment may not contain a double hyphen, so `sf` flags cannot
live inside the manifest itself.

## Pre-flight

1. **Confirm the org actually has all 17 fields.** A destructive delete naming a component the org
   does not have fails the deploy unless `--ignore-warnings` is passed.
   `manifest/native-loi-psa/package.xml` still says "PREPARED, NOT DEPLOYED" for eleven of them,
   but `Disposition_Record_Page` was *retrieved from* `usman-dpeg` at commit `472155f` with all
   three Details sections present — and a FlexiPage cannot name a `fieldItem` for a field that does
   not exist. Trust the retrieve over the status line, but verify.
2. **Diff the three permission sets against the org / against HEAD before deploying.** A
   PermissionSet deploy *replaces* its whole `fieldPermissions` set. `DPEG_Disposition_Edit` was
   already modified in the working tree before this change; only the 17 grants and two comment
   blocks were touched here.

## Dry run (validate only — nothing is written)

```powershell
sf project deploy start `
  --manifest manifest/remove-disposition-child-mirrors/package.xml `
  --post-destructive-changes manifest/remove-disposition-child-mirrors/destructiveChangesPost.xml `
  --target-org usman-dpeg `
  --test-level RunSpecifiedTests `
  --tests DispositionStageEntryServiceTest `
  --dry-run --wait 60
```

## Real deploy

The same command with `--dry-run` removed.

If the destructive half is refused because a field is missing from the org, add `--ignore-warnings`
— but check *which* field first, because a missing field may mean the org and repo disagree about
more than this change.

## Source paths (equivalent, if deploying by path rather than manifest)

Constructive:

- `force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml`
- `force-app/main/default/permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml`
- `force-app/main/default/permissionsets/DPEG_Disposition_View.permissionset-meta.xml`
- `force-app/main/default/permissionsets/DPEG_Apex_Access.permissionset-meta.xml`
- `force-app/main/default/classes/DispositionStageEntryService.cls`
- `force-app/main/default/classes/DispositionStageEntryServiceTest.cls`
- `force-app/main/default/objects/Disposition__c/fields/Primary_NDA__c.field-meta.xml`
- `force-app/main/default/objects/LOI__c/fields/Selected_Offer__c.field-meta.xml`
- `force-app/main/default/objects/Contract_Review__c/fields/Selected_Offer__c.field-meta.xml`

Destructive: see `destructiveChangesPost.xml` — 17 `CustomField` + 1 `ApexClass`.
**A path-based deploy cannot express the deletion**, so the manifest form above is the only one
that does the whole change in one transaction.

## Tests

- `DispositionStageEntryServiceTest` — the only class whose methods changed. It contains the
  falsifier for the enqueue count (`loiAndPsaAutoCreateEnqueueNothing`, asserting 0) and the
  surviving NDA-stamp coverage (`stampQueueableWithNothingToDoIsANoOp`).

Two traps this repo has already paid for, both of which apply here:

- **A green dry run can mean "never validated."** Byte-identical components report `Unchanged` and
  are skipped. `DPEG_Apex_Access` is a comment-only edit in this payload.
- **"N/N deployed, 0 errors" has been observed on a deploy that rolled everything back.**
  `numberComponentsDeployed` is a pre-rollback tally, and `RunSpecifiedTests` can fail on per-class
  75% coverage through `codeCoverageWarnings` that no error counter surfaces. Read the coverage
  section of the result, not just the error count. If coverage is the blocker, re-run at
  `--test-level RunLocalTests`.

## Rollback

Everything is recoverable from git history. Field **data** is not: the 15 formulas are derived and
lose nothing, but `Primary_LOI__c` / `Primary_PSA__c` hold real Ids and restoring them would need
the backfill described in `manifest/native-loi-psa/` to be run again.
