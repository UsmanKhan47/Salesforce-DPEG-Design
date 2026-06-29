# Task 1 & 2 Report — DPEG Broker Portal
Date: 2026-06-22  
Target org: DPEG-Acq-3 (test-3iuncy5c1je5@example.com)

---

## Task 1: Lead-routing Queue

### File Created
`force-app\main\default\queues\Broker_Portal_Leads.queue-meta.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Queue xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Broker_Portal_Leads</fullName>
    <name>Broker Portal Leads</name>
    <doesSendEmailToMembers>false</doesSendEmailToMembers>
    <queueSobject>
        <sobjectType>Lead</sobjectType>
    </queueSobject>
</Queue>
```

### Deploy Command
```
sf project deploy start -m "Queue:Broker_Portal_Leads" --ignore-conflicts -o DPEG-Acq-3
```

### Deploy Output (final status)
```
Deploying v62.0 metadata to test-3iuncy5c1je5@example.com using the v67.0 SOAP API.

✔ Preparing 445ms
◯ Waiting for the org to respond - Skipped
✔ Deploying Metadata 1.24s
  ▸ Components: 1/1 (100%)
◯ Running Tests - Skipped
✔ Updating Source Tracking 382ms
  ▸ Members: 1/1 (100%)
✔ Done 0ms

Status: Succeeded
Deploy ID: 0AfIm000009s6EbKAI
Target Org: test-3iuncy5c1je5@example.com
Elapsed Time: 2.08s

Deployed Source
┌─────────┬─────────────────────┬───────┬──────────────────────────────────────────────────────────────────┐
│ State   │ Name                │ Type  │ Path                                                             │
├─────────┼─────────────────────┼───────┼──────────────────────────────────────────────────────────────────┤
│ Created │ Broker_Portal_Leads │ Queue │ force-app\main\default\queues\Broker_Portal_Leads.queue-meta.xml │
└─────────┴─────────────────────┴───────┴──────────────────────────────────────────────────────────────────┘
```

### Verify Command
```
sf data query -q "SELECT Id, Name, Type FROM Group WHERE DeveloperName='Broker_Portal_Leads' AND Type='Queue'" -o DPEG-Acq-3
```

### Verify Output
```
Querying Data... done
┌────────────────────┬─────────────────────┬───────┐
│ ID                 │ NAME                │ TYPE  │
├────────────────────┼─────────────────────┼───────┤
│ 00GIm000001JgTMMA0 │ Broker Portal Leads │ Queue │
└────────────────────┴─────────────────────┴───────┘

Total number of records retrieved: 1.
```

**Result: PASS — 1 row, Type=Queue, Name=Broker Portal Leads**

---

## Task 2: Custom Notification Type

### File Created
`force-app\main\default\notificationtypes\Broker_Portal_New_Lead.notiftype-meta.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomNotificationType xmlns="http://soap.sforce.com/2006/04/metadata">
    <customNotifTypeName>Broker_Portal_New_Lead</customNotifTypeName>
    <desktop>true</desktop>
    <masterLabel>Broker Portal - New Lead</masterLabel>
    <mobile>true</mobile>
</CustomNotificationType>
```

### Deploy Command
```
sf project deploy start -m "CustomNotificationType:Broker_Portal_New_Lead" --ignore-conflicts -o DPEG-Acq-3
```

### Deploy Output (final status)
```
Deploying v62.0 metadata to test-3iuncy5c1je5@example.com using the v67.0 SOAP API.

✔ Preparing 1.11s
◯ Waiting for the org to respond - Skipped
◯ Deploying Metadata - Skipped
◯ Running Tests - Skipped
✔ Updating Source Tracking 774ms
  ▸ Members: 1/1 (100%)
✔ Done 0ms

Status: Succeeded
Deploy ID: 0AfIm000009s6EgKAI
Target Org: test-3iuncy5c1je5@example.com
Elapsed Time: 1.90s

Deployed Source
┌─────────┬────────────────────────┬────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────┐
│ State   │ Name                   │ Type                   │ Path                                                                               │
├─────────┼────────────────────────┼────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────┤
│ Created │ Broker_Portal_New_Lead │ CustomNotificationType │ force-app\main\default\notificationtypes\Broker_Portal_New_Lead.notiftype-meta.xml │
└─────────┴────────────────────────┴────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────┘
```

### Verify Command
```
sf data query --use-tooling-api -q "SELECT Id, DeveloperName, MasterLabel FROM CustomNotificationType WHERE DeveloperName='Broker_Portal_New_Lead'" -o DPEG-Acq-3
```

### Verify Output
```
Querying Data... done
┌────────────────────┬────────────────────────┬──────────────────────────┐
│ ID                 │ DEVELOPERNAME          │ MASTERLABEL              │
├────────────────────┼────────────────────────┼──────────────────────────┤
│ 0MLIm0000008PIHOA2 │ Broker_Portal_New_Lead │ Broker Portal - New Lead │
└────────────────────┴────────────────────────┴──────────────────────────┘

Total number of records retrieved: 1.
```

**Result: PASS — 1 row, DeveloperName=Broker_Portal_New_Lead, MasterLabel=Broker Portal - New Lead**
