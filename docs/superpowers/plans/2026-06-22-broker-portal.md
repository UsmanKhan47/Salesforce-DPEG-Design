# DPEG Broker Deal-Intake Portal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a public (no-login) Experience Cloud page where outside brokers submit a property/deal that becomes a `Lead` stamped `LeadSource='Broker Portal'`, flows into the existing Lead Funnel, flags possible duplicates, and notifies the acquisitions team.

**Architecture:** A custom LWC form on a guest LWR site calls a `without sharing` Apex controller that validates input, stamps protected/system fields server-side, dedup-checks, assigns the Lead to an internal queue (off the guest user), and inserts it. A record-triggered Flow fires an invocable Apex notifier (system context) that sends an in-app Custom Notification to the queue.

**Tech Stack:** Salesforce DX (API 62.0), Apex, Lightning Web Components, Experience Cloud (LWR), Flow, Custom Notifications.

## Global Constraints

- **API version: `62.0`** for every new `.cls-meta.xml`, LWC `.js-meta.xml`, and Flow (matches `sfdx-project.json` `sourceApiVersion`).
- **Target org:** the active scratch org **`DPEG-Acq-3`** (Active, expires 2026-07-15) — also set as the CLI default. The older `DPEG-Acq-2` in project memory has **expired/been deleted**; do not use it.
- **Run all `sf` commands in PowerShell**, not the Bash tool — on this Windows box the Bash tool mis-invokes the `sf` shim (`'C:\Program' is not recognized`). PowerShell works.
- **Source-tracking:** include **`--ignore-conflicts`** on every code deploy (harmless for net-new components; matches project practice).
- **No git in this workspace.** The per-task checkpoint is **deploy + run tests**, not a commit. Do not run git commands.
- `LeadSource='Broker Portal'` already exists in the `LeadSource` standard value set — do **not** add it.
- Salesforce requires `LastName` and `Company` on every Lead.
- Protected fields (`LeadSource`, `Status`, `First_Seen_Date__c`, `OwnerId`, `Duplicate_Flag__c`) are **set in Apex only** — they are not on the input DTO, so the client structurally cannot supply them.
- All Apex strings use plain ASCII punctuation (hyphen, not em dash) to avoid Windows CLI deploy encoding issues.

## File Structure

| File | Responsibility |
|---|---|
| `force-app/main/default/queues/Broker_Portal_Leads.queue-meta.xml` | Queue that owns new broker submissions (gets records off the guest user). |
| `force-app/main/default/notificationtypes/Broker_Portal_New_Lead.notiftype-meta.xml` | Custom Notification type definition. |
| `force-app/main/default/classes/BrokerPortalController.cls` (+ `-meta.xml`) | Guest-facing `without sharing` controller: `getFormMetadata`, `submitDeal`. |
| `force-app/main/default/classes/BrokerPortalControllerTest.cls` (+ `-meta.xml`) | Unit tests for the controller. |
| `force-app/main/default/classes/BrokerPortalNotifier.cls` (+ `-meta.xml`) | Invocable, system-context notifier that sends the Custom Notification. |
| `force-app/main/default/classes/BrokerPortalNotifierTest.cls` (+ `-meta.xml`) | Unit tests for the notifier. |
| `force-app/main/default/flows/Broker_Portal_New_Lead_Notify.flow-meta.xml` | Record-triggered (after-save, create, `LeadSource='Broker Portal'`) → calls the notifier. |
| `force-app/main/default/lwc/brokerDealIntakeForm/*` | The public form UI (html/js/css/meta). |

---

### Task 1: Lead-routing Queue

**Files:**
- Create: `force-app/main/default/queues/Broker_Portal_Leads.queue-meta.xml`

**Interfaces:**
- Produces: a Queue with `DeveloperName='Broker_Portal_Leads'` supporting `Lead`. Tasks 4 and 7 resolve it via `SELECT Id FROM Group WHERE Type='Queue' AND DeveloperName='Broker_Portal_Leads'`.

- [ ] **Step 1: Create the queue metadata**

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

- [ ] **Step 2: Deploy**

Run: `sf project deploy start -m "Queue:Broker_Portal_Leads" --ignore-conflicts -o DPEG-Acq-3`
Expected: `Status: Succeeded`, 1 component deployed.

- [ ] **Step 3: Verify it exists**

Run: `sf data query -q "SELECT Id, Name, Type FROM Group WHERE DeveloperName='Broker_Portal_Leads' AND Type='Queue'" -o DPEG-Acq-3`
Expected: exactly 1 row, `Type = Queue`, `Name = Broker Portal Leads`.

---

### Task 2: Custom Notification Type

**Files:**
- Create: `force-app/main/default/notificationtypes/Broker_Portal_New_Lead.notiftype-meta.xml`

**Interfaces:**
- Produces: a `CustomNotificationType` with `DeveloperName='Broker_Portal_New_Lead'`. Task 7 resolves its Id via `SELECT Id FROM CustomNotificationType WHERE DeveloperName='Broker_Portal_New_Lead'`.

- [ ] **Step 1: Create the notification type metadata**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomNotificationType xmlns="http://soap.sforce.com/2006/04/metadata">
    <customNotifTypeName>Broker_Portal_New_Lead</customNotifTypeName>
    <desktop>true</desktop>
    <masterLabel>Broker Portal - New Lead</masterLabel>
    <mobile>true</mobile>
</CustomNotificationType>
```

- [ ] **Step 2: Deploy**

Run: `sf project deploy start -m "CustomNotificationType:Broker_Portal_New_Lead" --ignore-conflicts -o DPEG-Acq-3`
Expected: `Status: Succeeded`, 1 component deployed.

- [ ] **Step 3: Verify it exists**

Run: `sf data query --use-tooling-api -q "SELECT Id, DeveloperName, MasterLabel FROM CustomNotificationType WHERE DeveloperName='Broker_Portal_New_Lead'" -o DPEG-Acq-3`
Expected: exactly 1 row.

---

### Task 3: Controller skeleton + `getFormMetadata`

**Files:**
- Create: `force-app/main/default/classes/BrokerPortalController.cls` (+ `-meta.xml`)
- Create: `force-app/main/default/classes/BrokerPortalControllerTest.cls` (+ `-meta.xml`)

**Interfaces:**
- Produces (consumed by the LWC in Task 9):
  - `getFormMetadata()` → `FormMetadata { List<PicklistOption> assetTypes; List<PicklistOption> dealTypes; }`, `PicklistOption { String label; String value; }`
  - `submitDeal(DealSubmission input)` → `SubmitResult { Boolean success; String message; }`
  - `DealSubmission { String firstName, lastName, brokerageFirm, email, phone, propertyAddress, assetType, dealType; Decimal guidancePrice, guidanceCapRate; String coStarLink, dealNotes, website; }`
- In this task `submitDeal` is a stub returning `null`; it is implemented in Tasks 4-6.

- [ ] **Step 1: Create the controller `-meta.xml`**

File `force-app/main/default/classes/BrokerPortalController.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Create the controller with DTOs, `getFormMetadata` implemented, `submitDeal` stubbed**

File `force-app/main/default/classes/BrokerPortalController.cls`:

```apex
public without sharing class BrokerPortalController {

    private static final String LEAD_SOURCE = 'Broker Portal';
    private static final String QUEUE_DEV_NAME = 'Broker_Portal_Leads';
    private static final Set<String> CLOSED_STATUSES = new Set<String>{ 'Converted', 'Disqualified' };
    private static final String CONFIRMATION_MSG =
        'Thank you! We have received your deal. Our acquisitions team will review it shortly.';

    // ---- DTOs ----
    public class DealSubmission {
        @AuraEnabled public String firstName { get; set; }
        @AuraEnabled public String lastName { get; set; }
        @AuraEnabled public String brokerageFirm { get; set; }
        @AuraEnabled public String email { get; set; }
        @AuraEnabled public String phone { get; set; }
        @AuraEnabled public String propertyAddress { get; set; }
        @AuraEnabled public String assetType { get; set; }
        @AuraEnabled public String dealType { get; set; }
        @AuraEnabled public Decimal guidancePrice { get; set; }
        @AuraEnabled public Decimal guidanceCapRate { get; set; }
        @AuraEnabled public String coStarLink { get; set; }
        @AuraEnabled public String dealNotes { get; set; }
        @AuraEnabled public String website { get; set; } // honeypot - must be blank
    }

    public class SubmitResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String message { get; set; }
        public SubmitResult(Boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }

    public class PicklistOption {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class FormMetadata {
        @AuraEnabled public List<PicklistOption> assetTypes { get; set; }
        @AuraEnabled public List<PicklistOption> dealTypes { get; set; }
    }

    // ---- getFormMetadata ----
    @AuraEnabled(cacheable=true)
    public static FormMetadata getFormMetadata() {
        FormMetadata meta = new FormMetadata();
        meta.assetTypes = optionsFor(Lead.Asset_Type__c.getDescribe());
        meta.dealTypes = optionsFor(Lead.Deal_Type__c.getDescribe());
        return meta;
    }

    private static List<PicklistOption> optionsFor(Schema.DescribeFieldResult dfr) {
        List<PicklistOption> opts = new List<PicklistOption>();
        for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
            if (e.isActive()) {
                opts.add(new PicklistOption(e.getLabel(), e.getValue()));
            }
        }
        return opts;
    }

    // ---- submitDeal (implemented in Tasks 4-6) ----
    @AuraEnabled
    public static SubmitResult submitDeal(DealSubmission input) {
        return null;
    }
}
```

- [ ] **Step 3: Create the test `-meta.xml`**

File `force-app/main/default/classes/BrokerPortalControllerTest.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 4: Write the failing test for `getFormMetadata`**

File `force-app/main/default/classes/BrokerPortalControllerTest.cls`:

```apex
@IsTest
private class BrokerPortalControllerTest {

    private static BrokerPortalController.DealSubmission validInput() {
        BrokerPortalController.DealSubmission d = new BrokerPortalController.DealSubmission();
        d.firstName = 'Jane';
        d.lastName = 'Broker';
        d.brokerageFirm = 'Acme Realty';
        d.email = 'jane@acme.com';
        d.phone = '555-1234';
        d.propertyAddress = '123 Main St, Dallas TX';
        d.assetType = 'Retail';
        d.dealType = 'Commercial';
        d.guidancePrice = 5000000;
        d.guidanceCapRate = 6.25;
        d.coStarLink = 'https://costar.com/listing/1';
        d.dealNotes = 'Anchored center.';
        return d;
    }

    @IsTest
    static void getFormMetadata_returnsActiveOptions() {
        Test.startTest();
        BrokerPortalController.FormMetadata meta = BrokerPortalController.getFormMetadata();
        Test.stopTest();

        System.Assert.isFalse(meta.assetTypes.isEmpty(), 'Asset types should not be empty');
        Set<String> assetValues = new Set<String>();
        for (BrokerPortalController.PicklistOption o : meta.assetTypes) {
            assetValues.add(o.value);
        }
        System.Assert.isTrue(assetValues.contains('Retail'), 'Expected Retail asset type');

        Set<String> dealValues = new Set<String>();
        for (BrokerPortalController.PicklistOption o : meta.dealTypes) {
            dealValues.add(o.value);
        }
        System.Assert.isTrue(dealValues.contains('Commercial'), 'Expected Commercial deal type');
    }
}
```

- [ ] **Step 5: Deploy both classes**

Run: `sf project deploy start -m "ApexClass:BrokerPortalController" -m "ApexClass:BrokerPortalControllerTest" --ignore-conflicts -o DPEG-Acq-3`
Expected: `Status: Succeeded` (both compile — `getFormMetadata` is implemented, `submitDeal` is a stub).

- [ ] **Step 6: Run the test, expect PASS**

Run: `sf apex run test --tests BrokerPortalControllerTest.getFormMetadata_returnsActiveOptions --result-format human --wait 10 -o DPEG-Acq-3`
Expected: PASS. (`getFormMetadata` is already implemented; this proves the describe-driven options work against the real org picklists.)

- [ ] **Step 7: Checkpoint** — both classes deployed, metadata test green.

---

### Task 4: `submitDeal` — happy path (build, stamp, assign, insert)

**Files:**
- Modify: `force-app/main/default/classes/BrokerPortalController.cls` (replace the `submitDeal` stub)
- Modify: `force-app/main/default/classes/BrokerPortalControllerTest.cls` (add happy-path test)

**Interfaces:**
- Consumes: the Queue from Task 1 (`Broker_Portal_Leads`).
- Produces: a working `submitDeal` that inserts one stamped Lead and returns `SubmitResult(true, <confirmation>)`. Validation (Task 5) and dedup (Task 6) are layered on next.

- [ ] **Step 1: Add the failing happy-path test**

Add these methods inside `BrokerPortalControllerTest`:

```apex
    @IsTest
    static void submitDeal_happyPath_insertsStampedLead() {
        BrokerPortalController.DealSubmission d = validInput();

        Test.startTest();
        BrokerPortalController.SubmitResult res = BrokerPortalController.submitDeal(d);
        Test.stopTest();

        System.Assert.isTrue(res.success, 'Should succeed');

        List<Lead> leads = [
            SELECT FirstName, LastName, Company, Broker_First__c, Email, Phone,
                   Property_Address__c, Asset_Type__c, Deal_Type__c, Guidance_Price__c,
                   Guidance_Cap_Rate__c, CoStar_Link__c, Deal_Notes__c,
                   LeadSource, Status, First_Seen_Date__c, OwnerId, Duplicate_Flag__c
            FROM Lead
        ];
        System.Assert.areEqual(1, leads.size(), 'Exactly one lead inserted');
        Lead l = leads[0];
        System.Assert.areEqual('Jane', l.FirstName, 'First name mapped');
        System.Assert.areEqual('Broker', l.LastName, 'Last name mapped');
        System.Assert.areEqual('Acme Realty', l.Company, 'Company = firm');
        System.Assert.areEqual('Acme Realty', l.Broker_First__c, 'Broker_First mirrors firm');
        System.Assert.areEqual('Retail', l.Asset_Type__c, 'Asset type mapped');
        System.Assert.areEqual(5000000, l.Guidance_Price__c, 'Guidance price mapped');
        System.Assert.areEqual('Broker Portal', l.LeadSource, 'LeadSource stamped server-side');
        System.Assert.areEqual('New', l.Status, 'Status stamped server-side');
        System.Assert.areNotEqual(null, l.First_Seen_Date__c, 'First Seen Date stamped server-side');
        System.Assert.isFalse(l.Duplicate_Flag__c, 'No duplicate expected');

        Group q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Broker_Portal_Leads' LIMIT 1];
        System.Assert.areEqual(q.Id, l.OwnerId, 'Lead owned by the Broker Portal queue, not the guest user');
    }
```

- [ ] **Step 2: Deploy and run the new test, expect FAIL**

Run: `sf project deploy start -m "ApexClass:BrokerPortalControllerTest" --ignore-conflicts -o DPEG-Acq-3`
Then: `sf apex run test --tests BrokerPortalControllerTest.submitDeal_happyPath_insertsStampedLead --result-format human --wait 10 -o DPEG-Acq-3`
Expected: FAIL — `submitDeal` returns `null`, so `res.success` throws a null-pointer / assertion failure.

- [ ] **Step 3: Implement `submitDeal` core + helpers**

In `BrokerPortalController`, replace the stub `submitDeal` with the implementation below, and add the helper methods:

```apex
    // ---- submitDeal ----
    @AuraEnabled
    public static SubmitResult submitDeal(DealSubmission input) {
        Lead l = new Lead();
        l.FirstName = input.firstName.trim();
        l.LastName = input.lastName.trim();
        l.Company = input.brokerageFirm.trim();
        l.Broker_First__c = input.brokerageFirm.trim();
        l.Email = input.email.trim();
        l.Phone = trimToNull(input.phone);
        l.Property_Address__c = input.propertyAddress.trim();
        l.Asset_Type__c = input.assetType;
        l.Deal_Type__c = trimToNull(input.dealType);
        l.Guidance_Price__c = input.guidancePrice;
        l.Guidance_Cap_Rate__c = input.guidanceCapRate;
        l.CoStar_Link__c = trimToNull(input.coStarLink);
        l.Deal_Notes__c = trimToNull(input.dealNotes);
        // Server-stamped - never accepted from the client.
        l.LeadSource = LEAD_SOURCE;
        l.Status = 'New';
        l.First_Seen_Date__c = Datetime.now();
        Id queueId = brokerQueueId();
        if (queueId != null) {
            l.OwnerId = queueId;
        }
        try {
            insert l;
        } catch (DmlException e) {
            throw new AuraHandledException('We could not save your submission. Please try again.');
        }
        return new SubmitResult(true, CONFIRMATION_MSG);
    }

    private static Id cachedQueueId;
    private static Boolean queueResolved = false;
    private static Id brokerQueueId() {
        if (!queueResolved) {
            queueResolved = true;
            List<Group> qs = [
                SELECT Id FROM Group
                WHERE Type = 'Queue' AND DeveloperName = :QUEUE_DEV_NAME
                LIMIT 1
            ];
            cachedQueueId = qs.isEmpty() ? null : qs[0].Id;
        }
        return cachedQueueId;
    }

    private static String trimToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
```

- [ ] **Step 4: Deploy and run the happy-path test, expect PASS**

Run: `sf project deploy start -m "ApexClass:BrokerPortalController" --ignore-conflicts -o DPEG-Acq-3`
Then: `sf apex run test --tests BrokerPortalControllerTest.submitDeal_happyPath_insertsStampedLead --result-format human --wait 10 -o DPEG-Acq-3`
Expected: PASS.

- [ ] **Step 5: Checkpoint** — a valid submission inserts one queue-owned, server-stamped Lead.

---

### Task 5: `submitDeal` — validation + honeypot

**Files:**
- Modify: `force-app/main/default/classes/BrokerPortalController.cls` (add validation + honeypot guard at the top of `submitDeal`)
- Modify: `force-app/main/default/classes/BrokerPortalControllerTest.cls` (add validation tests)

**Interfaces:**
- Consumes: Task 4 `submitDeal`.
- Produces: `submitDeal` rejects invalid input with `AuraHandledException` (no insert) and silently drops honeypot submissions.

- [ ] **Step 1: Add failing validation + honeypot tests**

Add these methods inside `BrokerPortalControllerTest`:

```apex
    private static void assertRejected(BrokerPortalController.DealSubmission d, String scenario) {
        Boolean threw = false;
        try {
            BrokerPortalController.submitDeal(d);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.Assert.isTrue(threw, 'Expected rejection for: ' + scenario);
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No lead should be inserted for: ' + scenario);
    }

    @IsTest
    static void submitDeal_missingLastName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.lastName = '   ';
        Test.startTest();
        assertRejected(d, 'blank last name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingFirm_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.brokerageFirm = '';
        Test.startTest();
        assertRejected(d, 'blank firm');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_invalidEmail_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.email = 'not-an-email';
        Test.startTest();
        assertRejected(d, 'invalid email');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_nonPositivePrice_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.guidancePrice = 0;
        Test.startTest();
        assertRejected(d, 'zero price');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_invalidAssetType_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.assetType = 'Spaceship';
        Test.startTest();
        assertRejected(d, 'invalid asset type');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_badCoStarUrl_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.coStarLink = 'javascript:alert(1)';
        Test.startTest();
        assertRejected(d, 'non-http url');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_honeypotFilled_skipsInsert() {
        BrokerPortalController.DealSubmission d = validInput();
        d.website = 'http://spam.example';
        Test.startTest();
        BrokerPortalController.SubmitResult res = BrokerPortalController.submitDeal(d);
        Test.stopTest();
        System.Assert.isTrue(res.success, 'Honeypot returns benign success so bots learn nothing');
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'Honeypot blocks the insert');
    }
```

- [ ] **Step 2: Deploy and run, expect FAIL**

Run: `sf project deploy start -m "ApexClass:BrokerPortalControllerTest" --ignore-conflicts -o DPEG-Acq-3`
Then: `sf apex run test --tests BrokerPortalControllerTest --result-format human --wait 10 -o DPEG-Acq-3`
Expected: the new validation/honeypot tests FAIL (no validation yet — invalid input currently inserts a Lead).

- [ ] **Step 3: Add the honeypot guard + `validate()` to `submitDeal`**

In `BrokerPortalController`, insert these two blocks at the very top of `submitDeal` (before building the Lead):

```apex
        // Honeypot - silently drop bot submissions with a normal-looking response.
        if (input != null && String.isNotBlank(input.website)) {
            return new SubmitResult(true, CONFIRMATION_MSG);
        }
        validate(input);
```

Then add these helper methods to the class:

```apex
    private static void validate(DealSubmission sub) {
        if (sub == null) {
            throw new AuraHandledException('No submission was received.');
        }
        List<String> errors = new List<String>();
        if (String.isBlank(sub.firstName)) errors.add('First name is required.');
        if (String.isBlank(sub.lastName)) errors.add('Last name is required.');
        if (String.isBlank(sub.brokerageFirm)) errors.add('Brokerage firm is required.');
        if (String.isBlank(sub.propertyAddress)) errors.add('Property address is required.');
        if (String.isBlank(sub.email) || !isValidEmail(sub.email)) errors.add('A valid email is required.');
        if (sub.guidancePrice == null || sub.guidancePrice <= 0) errors.add('Guidance price must be greater than zero.');
        if (sub.guidanceCapRate != null && (sub.guidanceCapRate < 0 || sub.guidanceCapRate > 100)) {
            errors.add('Cap rate must be between 0 and 100.');
        }
        if (String.isNotBlank(sub.coStarLink) && !isValidUrl(sub.coStarLink)) errors.add('CoStar link must be a valid URL.');
        if (String.isBlank(sub.assetType) || !isValidPicklist(Lead.Asset_Type__c.getDescribe(), sub.assetType)) {
            errors.add('Please choose a valid asset type.');
        }
        if (String.isNotBlank(sub.dealType) && !isValidPicklist(Lead.Deal_Type__c.getDescribe(), sub.dealType)) {
            errors.add('Please choose a valid deal type.');
        }
        if (!errors.isEmpty()) {
            throw new AuraHandledException(String.join(errors, ' '));
        }
    }

    private static Boolean isValidEmail(String value) {
        return Pattern.matches('^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$', value.trim());
    }

    private static Boolean isValidUrl(String value) {
        String v = value.trim().toLowerCase();
        return v.startsWith('http://') || v.startsWith('https://');
    }

    private static Boolean isValidPicklist(Schema.DescribeFieldResult dfr, String value) {
        for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
            if (e.isActive() && e.getValue() == value) {
                return true;
            }
        }
        return false;
    }
```

- [ ] **Step 4: Deploy and run the full class, expect PASS**

Run: `sf project deploy start -m "ApexClass:BrokerPortalController" --ignore-conflicts -o DPEG-Acq-3`
Then: `sf apex run test --tests BrokerPortalControllerTest --result-format human --wait 10 -o DPEG-Acq-3`
Expected: ALL tests PASS (happy path + validation + honeypot).

- [ ] **Step 5: Checkpoint** — invalid input is rejected with no insert; bots are silently dropped.

---

### Task 6: `submitDeal` — duplicate flagging

**Files:**
- Modify: `force-app/main/default/classes/BrokerPortalController.cls` (set `Duplicate_Flag__c` before insert)
- Modify: `force-app/main/default/classes/BrokerPortalControllerTest.cls` (add dedup tests)

**Interfaces:**
- Consumes: Task 4/5 `submitDeal`.
- Produces: `Duplicate_Flag__c = true` when an **open** Lead (`Status NOT IN ('Converted','Disqualified')`) already has the same trimmed `Property_Address__c`.

- [ ] **Step 1: Add failing dedup tests**

Add these methods inside `BrokerPortalControllerTest`:

```apex
    @IsTest
    static void submitDeal_openDuplicate_setsFlag() {
        insert new Lead(
            LastName = 'Existing', Company = 'Other Firm',
            Property_Address__c = '123 Main St, Dallas TX',
            Status = 'New', LeadSource = 'Manual Entry'
        );
        Test.startTest();
        BrokerPortalController.submitDeal(validInput()); // same address
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isTrue(created.Duplicate_Flag__c, 'Open same-address lead should flag a duplicate');
    }

    @IsTest
    static void submitDeal_closedDuplicate_doesNotSetFlag() {
        insert new Lead(
            LastName = 'Old', Company = 'Other Firm',
            Property_Address__c = '123 Main St, Dallas TX',
            Status = 'Disqualified', LeadSource = 'Manual Entry'
        );
        Test.startTest();
        BrokerPortalController.submitDeal(validInput()); // same address, but existing is closed
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isFalse(created.Duplicate_Flag__c, 'Closed same-address lead should not flag a duplicate');
    }

    @IsTest
    static void submitDeal_differentAddress_doesNotSetFlag() {
        insert new Lead(
            LastName = 'Existing', Company = 'Other Firm',
            Property_Address__c = '999 Elsewhere Ave',
            Status = 'New', LeadSource = 'Manual Entry'
        );
        Test.startTest();
        BrokerPortalController.submitDeal(validInput()); // different address
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isFalse(created.Duplicate_Flag__c, 'Different address should not flag a duplicate');
    }
```

- [ ] **Step 2: Deploy and run, expect FAIL**

Run: `sf project deploy start -m "ApexClass:BrokerPortalControllerTest" --ignore-conflicts -o DPEG-Acq-3`
Then: `sf apex run test --tests BrokerPortalControllerTest.submitDeal_openDuplicate_setsFlag --result-format human --wait 10 -o DPEG-Acq-3`
Expected: FAIL — `Duplicate_Flag__c` is still default `false`.

- [ ] **Step 3: Implement dedup**

In `BrokerPortalController.submitDeal`, set the flag immediately before the `try { insert l; }` block:

```apex
        l.Duplicate_Flag__c = isDuplicate(l.Property_Address__c);
```

Add the helper method to the class:

```apex
    private static Boolean isDuplicate(String address) {
        if (String.isBlank(address)) {
            return false;
        }
        List<Lead> existing = [
            SELECT Id FROM Lead
            WHERE Property_Address__c = :address.trim()
              AND Status NOT IN :CLOSED_STATUSES
            LIMIT 1
        ];
        return !existing.isEmpty();
    }
```

- [ ] **Step 4: Deploy and run the full class, expect PASS**

Run: `sf project deploy start -m "ApexClass:BrokerPortalController" --ignore-conflicts -o DPEG-Acq-3`
Then: `sf apex run test --tests BrokerPortalControllerTest --result-format human --wait 10 -o DPEG-Acq-3`
Expected: ALL tests PASS.

- [ ] **Step 5: Checkpoint** — the controller is complete: validate → stamp → dedup → assign → insert.

---

### Task 7: Invocable notifier

**Files:**
- Create: `force-app/main/default/classes/BrokerPortalNotifier.cls` (+ `-meta.xml`)
- Create: `force-app/main/default/classes/BrokerPortalNotifierTest.cls` (+ `-meta.xml`)

**Interfaces:**
- Consumes: the Queue (Task 1) + CustomNotificationType (Task 2).
- Produces: `@InvocableMethod notifyNewLeads(List<Id> leadIds)` — invoked by the Flow in Task 8. `actionName`/`nameSegment` in the Flow = `BrokerPortalNotifier`.

- [ ] **Step 1: Create both `-meta.xml` files**

`force-app/main/default/classes/BrokerPortalNotifier.cls-meta.xml` and `force-app/main/default/classes/BrokerPortalNotifierTest.cls-meta.xml` — both identical:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Create the notifier (full implementation)**

File `force-app/main/default/classes/BrokerPortalNotifier.cls`:

```apex
public without sharing class BrokerPortalNotifier {

    private static final String NOTIF_TYPE_DEV_NAME = 'Broker_Portal_New_Lead';
    private static final String QUEUE_DEV_NAME = 'Broker_Portal_Leads';

    @InvocableMethod(
        label='Notify Broker Portal New Leads'
        description='Sends an in-app custom notification to the Broker Portal Leads queue for new broker submissions.'
    )
    public static void notifyNewLeads(List<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return;
        }
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIF_TYPE_DEV_NAME LIMIT 1
        ];
        List<Group> queues = [
            SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :QUEUE_DEV_NAME LIMIT 1
        ];
        if (types.isEmpty() || queues.isEmpty()) {
            return;
        }
        Id typeId = types[0].Id;
        Set<String> recipients = new Set<String>{ queues[0].Id };

        for (Lead l : [SELECT Id, Name, Company, Property_Address__c FROM Lead WHERE Id IN :leadIds]) {
            String addr = String.isBlank(l.Property_Address__c) ? l.Name : l.Property_Address__c;
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(typeId);
            n.setTargetId(l.Id);
            n.setTitle('New broker deal submitted');
            n.setBody(l.Company + ' - ' + addr);
            try {
                n.send(recipients);
            } catch (Exception e) {
                // A notification failure must never roll back the lead transaction.
                System.debug(LoggingLevel.WARN, 'Broker portal notification failed: ' + e.getMessage());
            }
        }
    }
}
```

- [ ] **Step 3: Write the notifier tests**

File `force-app/main/default/classes/BrokerPortalNotifierTest.cls`:

```apex
@IsTest
private class BrokerPortalNotifierTest {

    @IsTest
    static void notify_runsForNewLead_withoutError() {
        Lead l = new Lead(
            FirstName = 'Jane', LastName = 'Broker', Company = 'Acme Realty',
            Property_Address__c = '123 Main St', LeadSource = 'Broker Portal', Status = 'New'
        );
        insert l;

        Test.startTest();
        BrokerPortalNotifier.notifyNewLeads(new List<Id>{ l.Id });
        Test.stopTest();

        // Custom notifications cannot be queried in tests; success = the method completes without throwing.
        System.Assert.areEqual(1, [SELECT COUNT() FROM Lead], 'Lead remains intact after notify');
    }

    @IsTest
    static void notify_emptyOrNull_isNoOp() {
        Test.startTest();
        BrokerPortalNotifier.notifyNewLeads(new List<Id>());
        BrokerPortalNotifier.notifyNewLeads(null);
        Test.stopTest();
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No leads created by a no-op notify');
    }
}
```

- [ ] **Step 4: Deploy and run, expect PASS**

Run: `sf project deploy start -m "ApexClass:BrokerPortalNotifier" -m "ApexClass:BrokerPortalNotifierTest" --ignore-conflicts -o DPEG-Acq-3`
Then: `sf apex run test --tests BrokerPortalNotifierTest --result-format human --wait 10 -o DPEG-Acq-3`
Expected: both tests PASS. (Relies on the Queue + CustomNotificationType from Tasks 1-2 already deployed.)

- [ ] **Step 5: Checkpoint** — the notifier sends without error and is safe on empty input.

---

### Task 8: Notification Flow

**Files:**
- Create: `force-app/main/default/flows/Broker_Portal_New_Lead_Notify.flow-meta.xml`

**Interfaces:**
- Consumes: `BrokerPortalNotifier` (Task 7) via an apex action; passes `$Record.Id` to `leadIds`.

- [ ] **Step 1: Create the record-triggered Flow (mirrors the repo's `Transaction_Task_Fanout` pattern)**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Flow xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <environments>Default</environments>
    <interviewLabel>Broker Portal New Lead Notify {!$Flow.CurrentDateTime}</interviewLabel>
    <label>Broker Portal New Lead Notify</label>
    <processType>AutoLaunchedFlow</processType>
    <actionCalls>
        <name>Notify_Acquisitions</name>
        <label>Notify Acquisitions</label>
        <locationX>176</locationX>
        <locationY>288</locationY>
        <actionName>BrokerPortalNotifier</actionName>
        <actionType>apex</actionType>
        <flowTransactionModel>CurrentTransaction</flowTransactionModel>
        <inputParameters>
            <name>leadIds</name>
            <value>
                <elementReference>$Record.Id</elementReference>
            </value>
        </inputParameters>
        <nameSegment>BrokerPortalNotifier</nameSegment>
    </actionCalls>
    <start>
        <locationX>50</locationX>
        <locationY>0</locationY>
        <connector>
            <targetReference>Notify_Acquisitions</targetReference>
        </connector>
        <filterLogic>and</filterLogic>
        <filters>
            <field>LeadSource</field>
            <operator>EqualTo</operator>
            <value>
                <stringValue>Broker Portal</stringValue>
            </value>
        </filters>
        <object>Lead</object>
        <recordTriggerType>Create</recordTriggerType>
        <triggerType>RecordAfterSave</triggerType>
    </start>
    <status>Active</status>
</Flow>
```

- [ ] **Step 2: Deploy**

Run: `sf project deploy start -m "Flow:Broker_Portal_New_Lead_Notify" --ignore-conflicts -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

- [ ] **Step 3: Verify it is active**

Run: `sf data query --use-tooling-api -q "SELECT ActiveVersionId FROM FlowDefinition WHERE DeveloperName='Broker_Portal_New_Lead_Notify'" -o DPEG-Acq-3`
Expected: `ActiveVersionId` is not null.

- [ ] **Step 4: Functional check (add yourself to the queue first)**

In Setup → Queues → Broker Portal Leads, add your user as a member. Then run anonymous Apex to simulate a submission and confirm the bell notification appears:

Run (PowerShell):
```powershell
@'
BrokerPortalController.DealSubmission d = new BrokerPortalController.DealSubmission();
d.firstName='Test'; d.lastName='Broker'; d.brokerageFirm='QA Realty';
d.email='qa@example.com'; d.propertyAddress='500 Test Plaza';
d.assetType='Retail'; d.guidancePrice=1000000;
System.debug(BrokerPortalController.submitDeal(d));
'@ | Out-File -FilePath scripts/tmp-broker-submit.apex -Encoding utf8
sf apex run -o DPEG-Acq-3 --file scripts/tmp-broker-submit.apex
```
Expected: a desktop bell notification "New broker deal submitted - QA Realty - 500 Test Plaza" for queue members, and the Lead appears in the Lead Funnel "Broker Portal" channel. (Delete the QA Lead afterward.)

- [ ] **Step 5: Checkpoint** — new Broker Portal leads trigger the in-app notification.

---

### Task 9: Broker intake form LWC

**Files:**
- Create: `force-app/main/default/lwc/brokerDealIntakeForm/brokerDealIntakeForm.js-meta.xml`
- Create: `force-app/main/default/lwc/brokerDealIntakeForm/brokerDealIntakeForm.js`
- Create: `force-app/main/default/lwc/brokerDealIntakeForm/brokerDealIntakeForm.html`
- Create: `force-app/main/default/lwc/brokerDealIntakeForm/brokerDealIntakeForm.css`

**Interfaces:**
- Consumes: `BrokerPortalController.getFormMetadata` and `BrokerPortalController.submitDeal` (Tasks 3-6).
- Produces: a component exposed to Experience Builder (`lightningCommunity__Page` + `lightningCommunity__Default`) for Task 10.

- [ ] **Step 1: Create the metadata (Experience Builder targets)**

File `brokerDealIntakeForm.js-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Broker Deal Intake Form</masterLabel>
    <description>Public broker portal form that submits a property/deal as a Lead.</description>
    <targets>
        <target>lightningCommunity__Page</target>
        <target>lightningCommunity__Default</target>
    </targets>
</LightningComponentBundle>
```

- [ ] **Step 2: Create the JavaScript**

File `brokerDealIntakeForm.js`:

```js
import { LightningElement, wire } from 'lwc';
import getFormMetadata from '@salesforce/apex/BrokerPortalController.getFormMetadata';
import submitDeal from '@salesforce/apex/BrokerPortalController.submitDeal';

export default class BrokerDealIntakeForm extends LightningElement {
    assetTypeOptions = [];
    dealTypeOptions = [];
    submitting = false;
    submitted = false;
    errorMessage = '';

    // form state
    firstName = '';
    lastName = '';
    brokerageFirm = '';
    email = '';
    phone = '';
    propertyAddress = '';
    assetType = '';
    dealType = '';
    guidancePrice = null;
    guidanceCapRate = null;
    coStarLink = '';
    dealNotes = '';
    website = ''; // honeypot

    @wire(getFormMetadata)
    wiredMeta({ data, error }) {
        if (data) {
            this.assetTypeOptions = data.assetTypes.map((o) => ({ label: o.label, value: o.value }));
            this.dealTypeOptions = data.dealTypes.map((o) => ({ label: o.label, value: o.value }));
        } else if (error) {
            this.errorMessage = 'Could not load the form. Please refresh and try again.';
        }
    }

    handleChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value;
    }

    handleSubmit() {
        this.errorMessage = '';
        if (!this.validate()) {
            return;
        }
        this.submitting = true;
        const input = {
            firstName: this.firstName,
            lastName: this.lastName,
            brokerageFirm: this.brokerageFirm,
            email: this.email,
            phone: this.phone,
            propertyAddress: this.propertyAddress,
            assetType: this.assetType,
            dealType: this.dealType,
            guidancePrice: this.guidancePrice ? parseFloat(this.guidancePrice) : null,
            guidanceCapRate: this.guidanceCapRate ? parseFloat(this.guidanceCapRate) : null,
            coStarLink: this.coStarLink,
            dealNotes: this.dealNotes,
            website: this.website
        };
        submitDeal({ input })
            .then((result) => {
                this.submitting = false;
                if (result && result.success) {
                    this.submitted = true;
                } else {
                    this.errorMessage = (result && result.message) || 'Something went wrong. Please try again.';
                }
            })
            .catch((error) => {
                this.submitting = false;
                this.errorMessage =
                    (error && error.body && error.body.message) || 'Something went wrong. Please try again.';
            });
    }

    validate() {
        const inputs = [...this.template.querySelectorAll('.validate')];
        let allValid = true;
        inputs.forEach((input) => {
            if (!input.reportValidity()) {
                allValid = false;
            }
        });
        return allValid;
    }

    handleReset() {
        this.submitted = false;
        this.firstName = '';
        this.lastName = '';
        this.brokerageFirm = '';
        this.email = '';
        this.phone = '';
        this.propertyAddress = '';
        this.assetType = '';
        this.dealType = '';
        this.guidancePrice = null;
        this.guidanceCapRate = null;
        this.coStarLink = '';
        this.dealNotes = '';
        this.website = '';
        this.errorMessage = '';
    }
}
```

- [ ] **Step 3: Create the HTML**

File `brokerDealIntakeForm.html`:

```html
<template>
    <div class="portal">
        <div class="portal__header">
            <h1 class="portal__title">Submit a Deal</h1>
            <p class="portal__subtitle">Bring your property to DPEG. We review every submission.</p>
        </div>

        <template lwc:if={submitted}>
            <div class="confirmation">
                <lightning-icon icon-name="utility:success" variant="success" size="large"></lightning-icon>
                <h2>Thank you! We've received your deal.</h2>
                <p>Our acquisitions team will review it shortly.</p>
                <lightning-button label="Submit another deal" variant="brand" onclick={handleReset}></lightning-button>
            </div>
        </template>

        <template lwc:else>
            <div class="form">
                <template lwc:if={errorMessage}>
                    <div class="form__error" role="alert">{errorMessage}</div>
                </template>

                <h3 class="section__title">Deal details</h3>
                <lightning-input class="validate" data-field="propertyAddress" label="Property Address"
                    value={propertyAddress} onchange={handleChange} required max-length="255"></lightning-input>
                <lightning-combobox class="validate" data-field="assetType" label="Asset Type" value={assetType}
                    options={assetTypeOptions} onchange={handleChange} required placeholder="Select..."></lightning-combobox>
                <lightning-combobox data-field="dealType" label="Deal Type" value={dealType}
                    options={dealTypeOptions} onchange={handleChange} placeholder="Select..."></lightning-combobox>
                <lightning-input class="validate" type="number" formatter="currency" data-field="guidancePrice"
                    label="Guidance Price" value={guidancePrice} onchange={handleChange} required min="0.01" step="0.01"></lightning-input>
                <lightning-input class="validate" type="number" data-field="guidanceCapRate"
                    label="Guidance Cap Rate (%)" value={guidanceCapRate} onchange={handleChange} min="0" max="100" step="0.01"></lightning-input>
                <lightning-input class="validate" type="url" data-field="coStarLink" label="CoStar Link"
                    value={coStarLink} onchange={handleChange}></lightning-input>
                <lightning-textarea data-field="dealNotes" label="Deal Notes" value={dealNotes}
                    onchange={handleChange} max-length="32768"></lightning-textarea>

                <h3 class="section__title">Your details</h3>
                <lightning-input class="validate" data-field="firstName" label="First Name"
                    value={firstName} onchange={handleChange} required></lightning-input>
                <lightning-input class="validate" data-field="lastName" label="Last Name"
                    value={lastName} onchange={handleChange} required></lightning-input>
                <lightning-input class="validate" data-field="brokerageFirm" label="Brokerage Firm"
                    value={brokerageFirm} onchange={handleChange} required></lightning-input>
                <lightning-input class="validate" type="email" data-field="email" label="Email"
                    value={email} onchange={handleChange} required></lightning-input>
                <lightning-input type="tel" data-field="phone" label="Phone"
                    value={phone} onchange={handleChange}></lightning-input>

                <!-- Honeypot: hidden from humans, catches bots -->
                <div class="hp" aria-hidden="true">
                    <input tabindex="-1" autocomplete="off" data-field="website" value={website} onchange={handleChange} />
                </div>

                <div class="form__actions">
                    <lightning-button label="Submit Deal" variant="brand" onclick={handleSubmit}
                        disabled={submitting}></lightning-button>
                    <template lwc:if={submitting}>
                        <lightning-spinner alternative-text="Submitting" size="small"></lightning-spinner>
                    </template>
                </div>
            </div>
        </template>
    </div>
</template>
```

- [ ] **Step 4: Create the CSS (DPEG design tokens)**

File `brokerDealIntakeForm.css`:

```css
:host {
    --dpeg-header: #032d60;
    --dpeg-subheader: #1565c0;
    --dpeg-teal: #2bafac;
    display: block;
    font-family: 'Salesforce Sans', Arial, sans-serif;
    background: #f3f5f8;
    padding: 24px 0;
}
.portal {
    max-width: 640px;
    margin: 0 auto;
    background: #ffffff;
    border: 1px solid #e3e6eb;
    border-radius: 10px;
    overflow: hidden;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.06);
}
.portal__header {
    background: var(--dpeg-header);
    color: #ffffff;
    padding: 24px 28px;
}
.portal__title {
    margin: 0;
    font-size: 22px;
    font-weight: 700;
}
.portal__subtitle {
    margin: 6px 0 0;
    font-size: 14px;
    opacity: 0.85;
}
.form,
.confirmation {
    padding: 24px 28px;
}
.section__title {
    color: var(--dpeg-subheader);
    font-size: 15px;
    font-weight: 700;
    margin: 18px 0 8px;
    border-bottom: 1px solid #e3e6eb;
    padding-bottom: 6px;
}
.section__title:first-child {
    margin-top: 0;
}
lightning-input,
lightning-combobox,
lightning-textarea {
    display: block;
    margin-bottom: 12px;
}
.form__actions {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-top: 20px;
}
.form__error {
    background: #fde7e9;
    color: #b91c1c;
    border: 1px solid #f5c2c7;
    border-radius: 6px;
    padding: 10px 12px;
    margin-bottom: 16px;
    font-size: 13px;
}
.confirmation {
    text-align: center;
    padding: 48px 28px;
}
.confirmation h2 {
    color: var(--dpeg-header);
    margin: 16px 0 8px;
}
.confirmation p {
    color: #4a4f57;
    margin: 0 0 24px;
}
.hp {
    display: none;
}
```

- [ ] **Step 5: Deploy**

Run: `sf project deploy start -m "LightningComponentBundle:brokerDealIntakeForm" --ignore-conflicts -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

- [ ] **Step 6: Checkpoint** — the component deploys clean and is available to Experience Builder. (Visual verification happens in Task 11.)

---

### Task 10: Experience site + guest access (manual Setup)

This task is performed in the Setup UI — it cannot be created purely from metadata starting from zero. Each step is exact.

- [ ] **Step 1: Enable Digital Experiences**

Setup → **Digital Experiences → Settings** → check **Enable Digital Experiences** → pick a domain (e.g. `dpeg-<random>` ) → Save.

- [ ] **Step 2: Create the site**

Setup → **Digital Experiences → All Sites → New** → choose the **Build Your Own (LWR)** template → Name: **`DPEG Broker Portal`** → URL suffix `broker` → Create.

- [ ] **Step 3: Add the component to the page**

In **Experience Builder** for the site: open the Home page, drag **Broker Deal Intake Form** (under Custom Components) onto the page. **Publish**.

- [ ] **Step 4: Grant guest access**

In Experience Builder → **Settings → General → Public Access** (ensure the guest user can access the site). Then **Administration → Pages → (Guest user profile / Public Access Settings)** and grant the guest profile:
- **Apex Class Access:** `BrokerPortalController` (required — without it `submitDeal`/`getFormMetadata` cannot be called).
- **Object:** Lead → **Create**.
- **Field-Level Security (create/edit):** `FirstName`, `LastName`, `Company`, `Email`, `Phone`, `Property_Address__c`, `Asset_Type__c`, `Deal_Type__c`, `Guidance_Price__c`, `Guidance_Cap_Rate__c`, `CoStar_Link__c`, `Deal_Notes__c`, `Broker_First__c`, `LeadSource`, `Status`, `First_Seen_Date__c`, `Duplicate_Flag__c`.

- [ ] **Step 5: Confirm guest record security + queue members**

- Setup → **Sharing Settings** → confirm **"Secure guest user record access"** is enabled (default). Lead OWD stays Private; the controller already assigns the new Lead to the queue, so internal staff see it.
- Setup → **Queues → Broker Portal Leads** → add the acquisitions team members (they own + get notified).

- [ ] **Step 6: Activate the site**

Experience Builder → **Settings → Administration → Activate** (if not already). Note the **public URL**.

- [ ] **Step 7: Version the guest profile (optional)**

Retrieve the auto-created site + guest profile into source so the permissions are tracked:

Run: `sf project retrieve start -m "Profile" -m "DigitalExperienceBundle" -m "DigitalExperienceConfig" -o DPEG-Acq-3`
Expected: the `<SiteName> Profile` and the experience bundle land under `force-app`. (Review before keeping.)

- [ ] **Step 8: Checkpoint** — the public URL loads the form for an unauthenticated visitor.

---

### Task 11: End-to-end verification

**Files:** none (manual acceptance test).

- [ ] **Step 1: Submit as a guest**

Open the public site URL from Task 10 in a **private/incognito window** (not logged in). Fill every required field with a unique property address (e.g. `777 Verify Blvd, Austin TX`), pick an Asset Type, enter a Guidance Price, and Submit.
Expected: the form is replaced by the **"Thank you! We've received your deal."** confirmation with a **Submit another deal** button.

- [ ] **Step 2: Confirm the Lead landed correctly**

Run:
```bash
sf data query -o DPEG-Acq-3 -q "SELECT Name, Company, LeadSource, Status, First_Seen_Date__c, Owner.Name, Duplicate_Flag__c FROM Lead WHERE Property_Address__c='777 Verify Blvd, Austin TX'"
```
Expected: one row — `LeadSource = Broker Portal`, `Status = New`, `First_Seen_Date__c` populated, `Owner.Name = Broker Portal Leads`, `Duplicate_Flag__c = false`.

- [ ] **Step 3: Confirm it appears in the Lead Funnel**

Open the Acquisition app → Lead Funnel. Expected: the new lead shows in the recent-leads table and increments the **Broker Portal** channel card.

- [ ] **Step 4: Confirm the notification fired**

As a queue member, check the bell icon. Expected: **"New broker deal submitted"** notification linking to the new Lead.

- [ ] **Step 5: Confirm duplicate flagging**

Submit again from the portal with the **same** property address (`777 Verify Blvd, Austin TX`). Re-query that address.
Expected: the second Lead has `Duplicate_Flag__c = true`.

- [ ] **Step 6: Checkpoint** — full happy path verified end-to-end. Delete the verification leads when done.

---

## Self-Review

**Spec coverage:**
- §2 access model (public) → Task 10 (LWR public site). ✅
- §2 build approach (LWC + Apex) → Tasks 3-6, 9. ✅
- §4 field list + required/validation → Tasks 4 (mapping), 5 (validation). ✅
- §4.3 server-side stamps → Task 4. ✅
- §4.1 live picklist options → Task 3 `getFormMetadata`. ✅
- §5 Queue → Task 1; CustomNotificationType → Task 2; controller → Tasks 3-6; notifier → Task 7; Flow → Task 8; LWC → Task 9; guest profile → Task 10. ✅
- §6 dedup in Apex → Task 6; client-override protection → structural (DTO has no LeadSource/Status/Owner fields; happy-path test asserts stamped values). ✅
- §7 security (without sharing, whitelist, owner off guest, honeypot) → Tasks 4, 5, 10. ✅
- §8 confirmation + notify + dup flag + error handling → Tasks 9 (confirmation/error UI), 8 (notify), 6 (dup). ✅
- §9 testing matrix → Tasks 3-7 tests. ✅
- §10 manual vs deployable → Task 10 (manual), Tasks 1-9 (deployable). ✅
- §11 deferred items → intentionally excluded. ✅

**Placeholder scan:** No TBD/TODO; every code/command step is complete. ✅

**Type consistency:** `DealSubmission`, `SubmitResult`, `FormMetadata`, `PicklistOption` defined in Task 3 and used identically in Tasks 4-6 and the LWC (Task 9). Invocable `notifyNewLeads(List<Id>)` in Task 7 matches the Flow input `leadIds` + `actionName=BrokerPortalNotifier` in Task 8. Queue dev name `Broker_Portal_Leads` and notif type `Broker_Portal_New_Lead` consistent across Tasks 1, 2, 4, 7. ✅
