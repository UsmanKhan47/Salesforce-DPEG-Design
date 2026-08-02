# Salesforce Code Review — Memory Index

- [8-DateTime migration (D1–D4)](migration-8datetime.md) — DateTimeBackfillBatch (D2), the Work_Order_Touch_Sync canary gate, and review stances for backfill batches
- [System.debug is a convention here](review-standard-system-debug.md) — catch-block diagnostics are the repo norm; don't flag them, flag the comment that oversells the debug log
- [Controller DML is accepted P4 debt](review-standard-controller-dml.md) — warn don't block; but reject class headers that miscite the layering rule as blessing it
- [Metadata naming §1 scope](metadata-naming-scope.md) — §1 repair was custom-objects-only; standard-object field drift = out-of-scope debt (WARNING not regression); verified-clean fields + the EM_Wired rule-9b miss
