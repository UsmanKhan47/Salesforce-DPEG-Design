# PM FSD v1.1 — Build Handover

**Date:** 2026-08-22 · **Org:** `usman-dpeg` (live EE) · **Branch:** `feature/disposition-redesign`
**Commits:** `6b1c6b7`, `90032aa`, `a37bd17`, `7886d16`, `23b0d31`, `b4f8bcb`

---

## Delivered and verified in the org

| Feature | Org state | Tests |
|---|---|---|
| Onboarding checklist fan-out (FSD 5.1) | 17 classes, flow, CMDT | 79/79 |
| AR & Delinquency (FSD 5.9) | 34 classes, Case `Delinquency` RT | 147/147, 0 coverage warnings |
| Utility & Meter (FSD 5.10) | 24 classes, 4 LWCs, trigger | 120/120 Apex + 39 Jest |

Read back from the org: **8 new objects**, **73 Apex classes**, **45 CMDT checklist rows**,
`Case.Delinquency` record type active, both new FlexiPages present.

---

## 🔴 GO-LIVE GATES — none of these are deployable, all fail SILENTLY

Verified open as of this handover.

1. **`DPEG_Property_Mgmt_Team` has 0 members.** Group membership is not deployable metadata, and
   `GroupNotifier` degrades an empty group to a `System.debug` line. Until members are added in
   Setup, **every** delinquency escalation (incl. the 60-day and 90-day alerts to Isha and Nikhil)
   and every utility variance alert reaches nobody, with no error anywhere.
2. **Neither scheduled job is scheduled.** 7 CronTriggers exist; none is ours. An unscheduled
   Schedulable leaves no failed-job row — it is simply inert.
   - `System.schedule('DPEG Receivables Nightly Sync', '0 0 1 * * ?', new ReceivablesSyncSchedule());`
   - `System.schedule('DPEG Utility Variance Alert', '0 0 7 * * ?', new UtilityVarianceAlertSchedule());`
3. **`Receivables_Sync_Config__c` has no org-default row.** Needs `Is_Enabled__c`, a
   `Provider_Class_Name__c`, and at least one opening threshold. ⚠ Also set
   `Staleness_Tolerance_Hours__c` — it is now safe to leave blank (see the F1 fix) but it is the arm
   that answers "how old is too old".

---

## Open decisions (deliberately not invented)

| Item | State |
|---|---|
| 2 missing Performance Tracking task names | FSD says 3, repo has 1. **45 of 47** rows live. Data-only fix via `scripts/load-onboarding-task-defs.apex`. |
| Variance alert threshold | Assumption: \|Δ$\| ≥ 250 **AND** \|Δ%\| ≥ 20. FSD 5.10 specifies none. All four numbers are constructor params — answering this is a re-schedule, not a deploy. |
| `TARGET_COMPLETION_DAYS = 90` | Derived from the largest due-day offset. Needs a real client SLA. |
| Register Size semantics | Dial count vs modulus. `Register_Modulus__c` absorbs either without a schema change. |
| `Oldest_Open_Days__c` | Undefined by the FSD; left unwritten rather than guessed. `getTimeSla` reads null. |

---

## Not built (declarative, out of scope for the Apex streams)

- **§6.5 Accounts Receivable Dashboard** — all supporting fields now exist, including
  `Months_Outstanding__c` for the PM-view ranking and the five aging buckets for the exposure view.
- **Write-off approval process** — `Write_Off_Requested__c` / `_Amount__c` / `Write_Off_Decision__c`
  are deployed. ⚠ When built: `recordLock = false` on every step, or a locked Case blocks the
  nightly balance refresh for exactly the cases under principal review. Set `<runInMode>` explicitly
  — a Flow without it runs as the APPROVER, whose CRUD is read-only.
- **`Delinquency__c` retirement** — still backs 2 live dashboard components and a report, and
  `scripts/seed-pm-dashboard.apex:37-44,66` resurrects it on every org rebuild. Plan only.

---

## Defects found and fixed during the build

1. **`Case.object-meta.xml` carried `ReadWriteTransfer` while the org is `Private`** — stale drift
   hidden by the blanket `objects/Case/**` force-ignore. Un-ignoring Case made a silent org-wide
   security downgrade deployable. Corrected to `Private`.
2. **A failed ASB callout reported HEALTHY.** The null-clock refusal was nested inside an *optional*
   staleness check, and that field is blank by default. An unreachable bus would run the lifecycle
   against an empty feed — which FSD 5.9.6 step 6 reads as "everyone paid", i.e. it could auto-close
   every open delinquency Case. Two already-passing tests had encoded the unsafe half.
3. **`Total_Variance_Pct__c` was 100× too large** (7250.00 vs 72.50, measured live twice). A 20%
   alert threshold would have fired at 0.2%. The field's own comment argued at length *for* the bug.
4. **`Has_Open_Delinquency_Case__c` was set but never cleared**, so the 6.1 tile over-counted forever
   and the duplicate guard could refuse a legitimate new Case.
5. **The onboarding rollup trigger cascade** — `ceil(rows/200)` SOQL *and* DML, i.e. 23+23 at
   production scale. Fixed by suppress-then-recompute-once, not a bare bypass (`recalc` writes twelve
   counters; four feed the dashboard).
6. **`DPEG_Apex_Access` had no `classAccesses`** for any of the 37 new classes — non-admins would
   have seen "class is not visible" from every new LWC.
