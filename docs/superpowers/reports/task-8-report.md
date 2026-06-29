# Task 8 Report: Broker Portal Notification Flow

**Date:** 2026-06-22  
**Task:** Create and deploy `Broker_Portal_New_Lead_Notify` record-triggered Flow  
**Org:** DPEG-Acq-3 (`test-3iuncy5c1je5@example.com`)

---

## 1. Flow File

**Path:** `force-app\main\default\flows\Broker_Portal_New_Lead_Notify.flow-meta.xml`

Created with the exact XML from the plan:
- API version: 62.0
- Process type: AutoLaunchedFlow
- Trigger: RecordAfterSave on Lead, Create only, filter `LeadSource EqualTo 'Broker Portal'`
- Action: Apex action `BrokerPortalNotifier` / `notifyNewLeads`, passing `$Record.Id` as `leadIds`
- Status: Active

---

## 2. Deploy Result

```
Status: Succeeded
Deploy ID: 0AfIm000009s6FKKAY
Target Org: test-3iuncy5c1je5@example.com
Elapsed Time: 5.50s

Deployed Source
| State   | Name                          | Type | Path                                                                     |
|---------|-------------------------------|------|--------------------------------------------------------------------------|
| Created | Broker_Portal_New_Lead_Notify | Flow | force-app\main\default\flows\Broker_Portal_New_Lead_Notify.flow-meta.xml |
```

1 component deployed, 0 errors.

---

## 3. Active-Version Verification

Query:
```
sf data query --use-tooling-api -q "SELECT ActiveVersionId FROM FlowDefinition WHERE DeveloperName='Broker_Portal_New_Lead_Notify'" -o DPEG-Acq-3
```

Result:
```
| ACTIVEVERSIONID    |
|--------------------|
| 301Im000000I8BlIAK |

Total number of records retrieved: 1.
```

`ActiveVersionId` is not null — the Flow is live and active in the org.

---

## 4. Functional Submit Output

Script written to `scripts/tmp-broker-submit.apex` (ASCII, no BOM) and executed via `sf apex run`.

Key log entries confirming success:
```
Compiled successfully.
Executed successfully.

14:06:14.58 | CODE_UNIT_STARTED | Flow:Lead                          <- after-save trigger fired
14:06:14.634 | CODE_UNIT_STARTED | BrokerPortalNotifier.notifyNewLeads(List<Id>)  <- notifier invoked
14:06:14.634 | CODE_UNIT_FINISHED | BrokerPortalNotifier.notifyNewLeads(List<Id>)
14:06:14.58  | USER_DEBUG | [5] | DEBUG | SubmitResult:[message=Thank you! We have received your deal. Our acquisitions team will review it shortly., success=true]
```

No errors. The after-save Flow fired in-transaction and called `BrokerPortalNotifier.notifyNewLeads` successfully.

---

## 5. Lead Creation Confirmed

Query after functional submit:
```
sf data query -q "SELECT Id, FirstName, LastName, Company, LeadSource, Property_Address__c, Status FROM Lead WHERE Property_Address__c='500 Test Plaza'" -o DPEG-Acq-3
```

Result:
```
| ID                 | FIRSTNAME | LASTNAME | COMPANY   | LEADSOURCE    | PROPERTY_ADDRESS__C | STATUS |
|--------------------|-----------|----------|-----------|---------------|---------------------|--------|
| 00QIm000001zj5hMAA | Test      | Broker   | QA Realty | Broker Portal | 500 Test Plaza      | New    |

Total number of records retrieved: 1.
```

Lead created with `LeadSource='Broker Portal'` and `Property_Address__c='500 Test Plaza'`. Confirmed.

---

## 6. Cleanup

- Test Lead `00QIm000001zj5hMAA` (`500 Test Plaza`) deleted:
  ```
  Successfully deleted record: 00QIm000001zj5hMAA.
  ```
- Temp file `scripts\tmp-broker-submit.apex` deleted: confirmed not present on disk.

---

## Summary

| Step | Result |
|------|--------|
| Flow file created | PASS |
| Deploy | SUCCEEDED (Deploy ID: 0AfIm000009s6FKKAY) |
| Active version verified | PASS (ActiveVersionId: 301Im000000I8BlIAK) |
| Functional submit (no errors) | PASS |
| BrokerPortalNotifier invoked in-transaction | PASS (confirmed in debug log) |
| Lead created with correct LeadSource | PASS |
| Test Lead deleted | PASS |
| Temp apex file deleted | PASS |

**Overall: DONE** — Flow is active, functional, and the notifier fires in-transaction on Broker Portal Lead creation.
