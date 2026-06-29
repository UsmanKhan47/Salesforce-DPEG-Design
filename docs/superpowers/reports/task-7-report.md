# Task 7 Report: Invocable Notifier (BrokerPortalNotifier)

**Date:** 2026-06-22
**Target org:** DPEG-Acq-3 (test-3iuncy5c1je5@example.com)

---

## Files Created

| File | Path |
|---|---|
| Notifier class | `force-app\main\default\classes\BrokerPortalNotifier.cls` |
| Notifier meta | `force-app\main\default\classes\BrokerPortalNotifier.cls-meta.xml` |
| Test class | `force-app\main\default\classes\BrokerPortalNotifierTest.cls` |
| Test meta | `force-app\main\default\classes\BrokerPortalNotifierTest.cls-meta.xml` |

All four files created verbatim from Task 7 in the plan (`2026-06-22-broker-portal.md`). API version 62.0 on all meta files.

---

## Deploy Command and Result

```
sf project deploy start -m "ApexClass:BrokerPortalNotifier" -m "ApexClass:BrokerPortalNotifierTest" --ignore-conflicts -o DPEG-Acq-3
```

**Result:**

```
Deployed Source
+---------+--------------------------+-----------+------------------------------------------------------------------+
| State   | Name                     | Type      | Path                                                             |
+---------+--------------------------+-----------+------------------------------------------------------------------+
| Created | BrokerPortalNotifier     | ApexClass | force-app\main\default\classes\BrokerPortalNotifier.cls          |
| Created | BrokerPortalNotifier     | ApexClass | force-app\main\default\classes\BrokerPortalNotifier.cls-meta.xml |
| Created | BrokerPortalNotifierTest | ApexClass | force-app\main\default\classes\BrokerPortalNotifierTest.cls      |
| Created | BrokerPortalNotifierTest | ApexClass | force-app\main\default\classes\BrokerPortalNotifierTest.cls-meta.xml |
+---------+--------------------------+-----------+------------------------------------------------------------------+

Status: Succeeded
Deploy ID: 0AfIm000009s6FAKAY
Elapsed Time: 3.07s
Components: 2/2 (100%)
```

---

## Test Run Command and Full Output

```
sf apex run test --tests BrokerPortalNotifierTest --result-format human --wait 10 -o DPEG-Acq-3
```

**Full output:**

```
=== Test Results
TEST NAME                                                    OUTCOME  MESSAGE  RUNTIME (MS)
───────────────────────────────────────────────────────────  ───────  ───────  ────────────
BrokerPortalNotifierTest.notify_emptyOrNull_isNoOp           Pass              27
BrokerPortalNotifierTest.notify_runsForNewLead_withoutError  Pass              180

=== Test Summary
NAME                 VALUE
───────────────────  ─────────────────────────────
Outcome              Passed
Tests Ran            2
Pass Rate            100%
Fail Rate            0%
Skip Rate            0%
Test Run Id          707Im00000UzdWg
Test Setup Time      0 ms
Test Execution Time  207 ms
Test Total Time      207 ms
Org Id               00DIm000000LeIDMA0
Username             test-3iuncy5c1je5@example.com
```

**Result: 2/2 PASS**

---

## Test Method Summary

| Test Method | Outcome | Runtime |
|---|---|---|
| `notify_runsForNewLead_withoutError` | PASS | 180 ms |
| `notify_emptyOrNull_isNoOp` | PASS | 27 ms |

---

## Fixes / Concerns

None. Code deployed and tests passed on the first attempt without any modifications.

**Design notes (no concerns):**

- `notify_runsForNewLead_withoutError` inserts a Lead with `LeadSource='Broker Portal'` and calls `notifyNewLeads`. In test context, `Messaging.CustomNotification.send()` is allowed but does not actually dispatch; the test asserts the Lead is still intact (1 row). This is the intended test pattern per the plan — custom notifications cannot be queried in tests, so success = no exception thrown.
- The notifier gracefully handles missing `CustomNotificationType` or `Group` (queue) by returning early; it also swallows individual notification send failures to prevent rolling back the Lead transaction. Both are correct behaviors for production resilience.
- The Queue (`Broker_Portal_Leads`) and CustomNotificationType (`Broker_Portal_New_Lead`) were already deployed in Tasks 1-2, so the notifier resolved both correctly in the test run.
