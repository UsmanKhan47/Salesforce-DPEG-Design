# P3-D3 — retire the LOI values, narrow the acquisition PSA record type

**Staged 2026-08-14. NOT applied to the tree.** The working tree sits at P3-D1 + P3-D2 state and
must stay deployable there. This package is the subtractive step and runs only after the row
migration has provably completed.

Authoritative execution order: `agent-output/runbook-acquisition-observations-phase3.md` §3, P3-D3.

## Contents

| File | Role |
|---|---|
| `apply-d3.js` | The apply mechanism. **Two-phase and atomic**: every edit is applied in memory first and each asserts EXACTLY ONE match; if any fails, **nothing is written**. `--check` validates and writes nothing. |
| `falsify.js` | The harness that proves `apply-d3.js` actually catches what it claims to. Builds ten deliberately mutated copies of the tree in a temp directory, runs the real script against each, and requires exit non-zero **and** every file byte-identical. Plus a positive control on a clean tree. Touches nothing in `force-app`. |

There is deliberately **no `.diff` artifact**. Phase 1's went stale silently; a script fails loudly.

## Run order

```bash
node agent-output/p3-d3-retire-loi-psa/falsify.js      # optional but cheap; re-run if the tree moved
node agent-output/p3-d3-retire-loi-psa/apply-d3.js --check
node agent-output/p3-d3-retire-loi-psa/apply-d3.js
```

Last verified 2026-08-14: `--check` green on 13 edits; falsifier **10/10 mutations caught, nothing
written**, positive control rewrites 7 files cleanly.

## 🔴 The one thing that must not be "harmonised"

This package **deactivates four values on `LOI__c.Stage__c`** and **deactivates NOTHING on
`Contract_Review__c.Negotiation_Status__c`**. That asymmetry is decision **O3** and it is a hard
stop: `Initial Draft`, `Revised` and `Ready for Execution` remain ACTIVE because `Disposition_PSA`
still runs on all three. They are removed from the **`Acquisition_PSA` record type** only.

`apply-d3.js` asserts this and falsifier mutation **M6** proves the assertion goes red.

## 🔴 Preconditions this package cannot check

1. **The row migration has completed — INCLUDING the Master-record-type rows.** Re-run the
   zero-count query in the runbook immediately before executing, not once at migration time: until
   the P3-D2 Apex lands, `RecordStageAdvanceService` still derives the OLD values, so new rows keep
   appearing on them.
   🔴 **The migration filter is `RecordType.DeveloperName != 'Disposition_LOI'`, NEVER
   `= 'Acquisition_LOI'`.** This package does not perform the migration and does not repeat that
   filter — the authoritative wrong-vs-right box is at the `[MIG]` step of the runbook. It matters
   here because **this script is what makes the mistake irreversible**: a Master LOI missed by an
   `= 'Acquisition_LOI'` filter is still on `Completed` when step 1 below deactivates that value,
   and a restricted picklist then rejects the value the row already holds — the record can no
   longer be saved at all. The precondition query below is the last chance to catch it.
2. **`LOI__c.Stage__c` is genuinely restricted in the org** (measured `true`, 2026-08-14). That is
   what makes this deactivation a control rather than a cosmetic — and it is also why a stranded row
   becomes unsaveable, which is why precondition 1 matters.

## Prose is NOT scripted, on purpose

The 13 edits are structural. The `<description>` and comment touch-ups that go with them are listed
in the runbook's P3-D3 section as a checklist. A half-applied sentence is not a failure mode worth
introducing into an all-or-nothing script.
