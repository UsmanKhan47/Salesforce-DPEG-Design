# Lease Inquiry Negotiation Log — "Reminder → Task" Feature

**Date:** 2026-07-17
**Author:** Documentation Agent
**Status:** Completed (code + tests); ARCHITECTURE.md drift **not** updated (out of scope for this task)

---

## 📋 Overview

### Original Request

> On the Property Management → Lease Inquiry record page → Negotiation Log tab, the "Add Update"
> composer (`leaseNegotiationLog` LWC) gets a "Do you need a reminder?" checkbox. Ticking it reveals
> reminder name + reminder date fields. On save, a standard Task is created against the Lease
> Inquiry, visible in a new Activity component on the record page sidebar.

### Business Objective

Leasing staff log negotiation updates against a `Lease_Inquiry__c` (e.g. "Countered at $30/sq ft")
through the Negotiation Log's "Add Update" composer. Many of those updates carry an implicit
follow-up ("chase the tenant for the signed LOI in 7 days"). Before this change, creating that
follow-up meant leaving the composer and manually building a standard Task with the right `WhatId`
— an easy step to skip. This feature lets the user opt into a reminder Task **at the moment they log
the update**, in the same composer, with no separate navigation.

### Summary

The `leaseNegotiationLog` LWC composer gained an optional "Do you need a reminder?" checkbox that
reveals a reminder name and date. On save, `LeaseInquiryController.addUpdate` — already responsible
for appending the log entry and updating the parent's Ball in Court / Stage — now also inserts a
standard `Task` against the Lease Inquiry as one transaction. A new `activityPanel` component was
added to the record page sidebar, and the page layout's Activity composer actions
(`LogACall`/`NewEvent`/`NewTask`) were extended so that panel actually renders a "New Task" button.
**Zero schema change** — no new objects or fields were created; the feature reuses the standard
`Task` object and the existing `Lease_Inquiry__c` / `Lease_Activity__c` schema.

---

## 🏗️ Components Created / Modified

No custom objects or custom fields were created or modified. All five changed files are listed below.

### Admin Components (Declarative) — both modified, not created

#### Page Layout

| Object | Layout | Change |
|--------|--------|--------|
| `Lease_Inquiry__c` | `Lease Inquiry Layout` | `platformActionList` extended with `LogACall` (sortOrder 3), `NewEvent` (sortOrder 4), `NewTask` (sortOrder 5) QuickActions, alongside the existing `Edit` StandardButton (sortOrder 0) |

#### FlexiPage

| FlexiPage | Change |
|-----------|--------|
| `Lease_Inquiry_Record_Page` | `sidebar` region gained a `runtime_sales_activities:activityPanel` component (`showLegacyActivityComposer=false`), alongside the pre-existing `force:detailPanel` and `leaseStatusSummary` components |

No Flows, Validation Rules, or Permission Sets were created for this feature.

---

### Development Components (Code)

#### Apex Classes

| Class Name | Type | Change |
|------------|------|--------|
| `LeaseInquiryController` | Controller | `addUpdate` signature widened from `(Id, String, String, Boolean)` to `(Id inquiryId, String details, String ball, Boolean advance, Boolean reminder, String reminderName, Date reminderDate)`. Adds a conditional `Task` insert, an up-front reminder-name length guard, and a `Database.setSavepoint()` / two-catch-block rollback around all three DML operations. Adds a private `ahe(String)` helper. |

#### Test Classes

| Test Class | Tests For | Coverage |
|------------|-----------|----------|
| `LeaseInquiryControllerTest` | `LeaseInquiryController` | 22 test methods total (8 new, reminder-specific); ~99% class coverage as reported by the developer/testing agent — not independently re-measured by this documentation pass |

#### Lightning Web Components

| Component Name | Location | Change |
|----------------|----------|--------|
| `leaseNegotiationLog` | `force-app/main/default/lwc/leaseNegotiationLog/` | `.js` and `.html` only — added `upReminder` / `upReminderName` / `upReminderDate` state, a checkbox + two conditionally-rendered inputs, and client-side validation before calling `addUpdate`. `.css` and `.js-meta.xml` unchanged. |

---

## 🔄 Data Flow

### How It Works

1. User is on the Lease Inquiry record page → Negotiation Log tab → clicks **Add Update**.
2. In the `leaseNegotiationLog` composer, the user enters details and a Next Action Owner, and
   optionally ticks **Do you need a reminder?** — revealing **Reminder name** and **Reminder date**.
3. Client-side validation in `save()` blocks the call if details/ball are missing, or if the
   reminder is ticked but name/date are not filled in.
4. The LWC calls `LeaseInquiryController.addUpdate(inquiryId, details, ball, advance=false,
   reminder, reminderName, reminderDate)`.
5. Apex runs up-front guards (null inquiry, blank details, over-length reminder name — measured on
   the **trimmed** value), then takes `Database.setSavepoint()` and, in one try block:
   - inserts the `Lease_Activity__c` log entry,
   - conditionally updates `Lease_Inquiry__c.Ball_In_Court__c` and/or `Stage__c`,
   - if `reminder == true`, backstop-validates name/date again and inserts a standard `Task`
     (`Subject`, `ActivityDate`, `OwnerId`, `WhatId` only).
6. On any `AuraHandledException` or `DmlException` in that block, `Database.rollback(sp)` undoes
   everything committed so far in the transaction (log entry + parent update, if either had already
   committed before the Task insert failed), and a user-safe error is thrown.
7. On success, the LWC calls `notifyRecordUpdateAvailable` (so the Path/highlights refresh) and
   `refreshApex` on the wired log, then shows a success toast.
8. The new Task is visible in the record page **sidebar**, in the `runtime_sales_activities:activityPanel`
   component — a standard Salesforce component, not custom code. It renders the "New Task" composer
   button because the page layout's `platformActionList` now includes the `NewTask` QuickAction (see
   the layout/flexipage gotcha below).

### Architecture Diagram

```
┌───────────────────────────────┐
│ Lease Inquiry Record Page      │
│ Negotiation Log tab            │
└───────────────┬─────────────────┘
                │ user ticks "Do you need a reminder?"
                ▼
┌───────────────────────────────┐
│ leaseNegotiationLog LWC         │
│ upReminder / upReminderName /   │
│ upReminderDate + client-side    │
│ validation                      │
└───────────────┬─────────────────┘
                │ addUpdate(inquiryId, details, ball,
                │   advance, reminder, reminderName, reminderDate)
                ▼
┌─────────────────────────────────────────────────┐
│ LeaseInquiryController.addUpdate (Apex)           │
│ 1. guards: null id / blank details / name > 255   │
│ 2. Savepoint sp = Database.setSavepoint()         │
│ 3. insert Lease_Activity__c   (log entry)         │
│ 4. update Lease_Inquiry__c    (ball / stage)      │
│ 5. if reminder: insert Task                        │
│      Subject / ActivityDate / OwnerId / WhatId     │
│ catch AuraHandledException | DmlException          │
│   → Database.rollback(sp) → rethrow user-safe      │
└───────────────────┬───────────────────────────────┘
                     │ success → returns inquiryId
                     ▼
        ┌─────────────────────────────┐
        │ notifyRecordUpdateAvailable   │
        │ + refreshApex(wired log)      │
        └───────────────┬────────────────┘
                         ▼
        ┌───────────────────────────────────────┐
        │ Sidebar: runtime_sales_activities:      │
        │ activityPanel (added to the flexipage    │
        │ sidebar region). Shows the new Task via  │
        │ the standard Activity timeline — its      │
        │ New Task button only renders because the │
        │ layout's platformActionList now carries   │
        │ LogACall / NewEvent / NewTask.            │
        └───────────────────────────────────────┘
```

---

## 📁 File Locations

| Component | Path |
|-----------|------|
| Apex Controller | `force-app/main/default/classes/LeaseInquiryController.cls` |
| Apex Test Class | `force-app/main/default/classes/LeaseInquiryControllerTest.cls` |
| LWC | `force-app/main/default/lwc/leaseNegotiationLog/` (`.js`, `.html` changed; `.css`, `.js-meta.xml` unchanged) |
| Page Layout | `force-app/main/default/layouts/Lease_Inquiry__c-Lease Inquiry Layout.layout-meta.xml` |
| FlexiPage | `force-app/main/default/flexipages/Lease_Inquiry_Record_Page.flexipage-meta.xml` |

---

## ⚙️ Configuration Details

### `addUpdate` signature

```apex
@AuraEnabled
public static Id addUpdate(Id inquiryId, String details, String ball, Boolean advance,
                           Boolean reminder, String reminderName, Date reminderDate)
```

Returns the inquiry `Id` (unchanged from before this feature) so the LWC can refresh the record.

### Guards (in order)

| Guard | Condition | Result |
|-------|-----------|--------|
| Null inquiry | `inquiryId == null` | `ahe('No inquiry specified.')` |
| Blank details | `String.isBlank(details)` | `ahe('Enter what changed before saving.')` |
| Reminder name too long | `reminder == true && reminderName.trim().length() > 255` | `ahe('The reminder name is too long. Shorten it to 255 characters or fewer.')` — measured on the **trimmed** value, since that is what is actually stored on `Task.Subject` |
| Reminder backstop (inside the try block) | `reminder == true && (String.isBlank(reminderName) \|\| reminderDate == null)` | `ahe('Add a reminder name and due date, or clear the reminder.')` — backstops the LWC's client-side validation; does not replace it |

`255` is used because `Task.Subject` is a 255-char combobox field, verified against the org (255
inserts, 256 fails with `STRING_TOO_LONG`). The composer's `max-length="255"` is a client-side
control only and does not bind any other caller of `addUpdate`.

### Task fields set on the reminder insert

| Field | Value | Set? |
|-------|-------|------|
| `Subject` | `reminderName.trim()` | Yes |
| `ActivityDate` | `reminderDate` | Yes |
| `OwnerId` | `UserInfo.getUserId()` | Yes |
| `WhatId` | `inquiryId` (the **Lease Inquiry**, not the log entry) | Yes |
| `IsReminderSet` | — | **Deliberately not set** (no bell popup) |
| `ReminderDateTime` | — | **Deliberately not set** |
| `Status` / `Priority` / `Description` | — | Left to field defaults |

### Layout `platformActionList`

```xml
<platformActionListItems><actionName>Edit</actionName><actionType>StandardButton</actionType><sortOrder>0</sortOrder></platformActionListItems>
<platformActionListItems><actionName>LogACall</actionName><actionType>QuickAction</actionType><sortOrder>3</sortOrder></platformActionListItems>
<platformActionListItems><actionName>NewEvent</actionName><actionType>QuickAction</actionType><sortOrder>4</sortOrder></platformActionListItems>
<platformActionListItems><actionName>NewTask</actionName><actionType>QuickAction</actionType><sortOrder>5</sortOrder></platformActionListItems>
```

### FlexiPage sidebar region

The `sidebar` region on `Lease_Inquiry_Record_Page` now has three components, in this order:
`force:detailPanel`, `leaseStatusSummary`, `runtime_sales_activities:activityPanel`
(`showLegacyActivityComposer=false`).

---

## 🎯 Key Design Decisions and Rationale

This is the part worth reading before touching this feature again.

**1. Reminder date drives `Task.ActivityDate` (Due Date) only — no bell popup.**
`IsReminderSet` and `ReminderDateTime` are deliberately left unset. This was an explicit user
decision, not an oversight — the field comment in the controller and the test
(`addUpdateWithReminderCreatesTask` asserts `IsReminderSet == false`) both call this out.

**2. `Task.WhatId` = the Lease Inquiry, not the log entry.**
`Lease_Activity__c` has `enableActivities=false` (per its object metadata), so a Task cannot be
parented to a log entry at all — Salesforce Activities can only attach to objects with Activities
enabled. The Task is therefore always filed against the parent `Lease_Inquiry__c`.

**3. No badge on log entries, and no link field from the log entry to the Task — deliberately.**
Two independent reasons rule this out, not one:
- Salesforce does not permit a Lookup from `Lease_Activity__c` to `Task`. A "link" field would have
  to be a Text field holding a Task Id — exactly the type-vs-name trap
  `ARCHITECTURE.md` §1 rule 9 prohibits (a field that asserts a relationship it cannot actually have).
- Heuristic matching (pairing a log entry to "the Task created around the same time with a similar
  subject") would false-match against the *ordinary* Tasks users can now create directly via the
  Activity composer this same change enables — there is no reliable way to distinguish
  "the Task this log entry created" from "an unrelated Task someone logged five minutes later."

**4. The layout change is not cosmetic — it is required for the flexipage change to work.**
The Activity panel's composer tabs (Log a Call / New Task / New Event) are driven by the **page
layout's** `platformActionList`, not by the flexipage. Shipping the flexipage's `activityPanel`
without the layout change renders a panel with no New Task button. **This exact bug has already
shipped on Opportunity, Lead, Transaction, and Disposition** before being caught here — treat
"layout + flexipage ship together for any Activity panel addition" as a standing gotcha for this
codebase, not a one-off fix.

**5. No `WITH USER_MODE` / `AccessLevel.USER_MODE` on the Task insert — deliberately, and asymmetrically.**
Reads in this controller go through selectors that use `WITH USER_MODE`
(`LeaseInquirySelector`, `LeaseActivitySelector`, `LeaseSelector`), per `ARCHITECTURE.md` §2. The
Task insert (and the other two DML statements in `addUpdate`) do not enforce FLS/CRUD. This is a
recorded, accepted decision: this repo has prior documented incidents of `USER_MODE` breaking
functionality for non-admin users, because the FLS grants it depends on live in the org's
permission sets rather than in source control, so they are invisible to a code review. The
asymmetry (reads enforce FLS, writes do not) is real and is noted here rather than silently
carried forward.

**6. The savepoint is load-bearing, not boilerplate.**
An uncaught exception rolls back automatically in Apex. But converting a caught `DmlException` into
the `AuraHandledException` the LWC boundary requires (`ARCHITECTURE.md` §5) suppresses that
automatic rollback — the platform no longer knows the transaction failed, because from its
perspective the method returned an exception object, not an uncommitted transaction. Both catch
blocks (`AuraHandledException` and `DmlException`) explicitly call `Database.rollback(sp)` for this
reason. This was proven, not assumed: mutation-testing the rollback call (temporarily disabling
`Database.rollback(sp)`) causes `addUpdateReminderDateOutOfRangeRollsBackCommittedWork` to fail
with `Expected: 1, Actual: 2` — i.e. without the rollback, the already-committed
`Lease_Activity__c` insert and `Lease_Inquiry__c` update survive a failed third DML. That test's
sibling, `addUpdateWithReminderCreatesTask`, exists specifically as a control: it proves the parent
update commits for the same payload shape when the Task insert *succeeds*, so the rollback test's
failure can only be attributable to the third DML (the Task), not a false-green from the first DML
never having run.

**7. `AuraHandledException` needs `setMessage()` — status: believed true, not fully verified.**
`AuraHandledException.getMessage()` is known to return the generic `"Script-thrown exception"`
string unless `setMessage()` is called after construction — this bites in test assertions, which is
how the missing-`setMessage()` defect was originally caught in this class
(`addUpdateDetailsTooLongTriggersDmlExceptionWrap` asserts on message content specifically for this
reason). The private `ahe(String)` helper added to `LeaseInquiryController` in this build always
calls `setMessage()`. **What is not independently verified**: whether the constructor argument
alone (without `setMessage()`) still reaches the LWC client as `body.message` at runtime outside of
a test context. Web documentation was unreachable from the agent context that built this feature,
so this is recorded as unverified rather than confirmed. See **Known Open Items** below for the
decisive check.

---

## 🧪 Testing

### Test Coverage Summary

| Class | Coverage | Status |
|-------|----------|--------|
| `LeaseInquiryController` | ~99% (as reported by the build; not independently re-measured here) | Reported passing |

### Reminder-Specific Test Scenarios (in `LeaseInquiryControllerTest`)

| Test | Verifies |
|------|----------|
| `addUpdateWithReminderCreatesTask` | Ticked reminder creates exactly one Task with trimmed Subject, correct ActivityDate/WhatId/OwnerId, `IsReminderSet == false`. Also serves as the **control** for the rollback proof below. |
| `addUpdateWithoutReminderCreatesNoTask` | Unticked reminder (`reminder == false`) creates no Task. |
| `addUpdateReminderNullFlagCreatesNoTask` | Null reminder flag (caller omits it) creates no Task. |
| `addUpdateReminderBlankNameRollsBackEntry` | Ticked reminder with a blank name is rejected; the log entry insert is rolled back, not left orphaned. |
| `addUpdateReminderNullDateRollsBackEntry` | Ticked reminder with no date is rejected; same rollback guarantee. |
| `addUpdateDetailsTooLongTriggersDmlExceptionWrap` | A `DmlException` on the *first* DML (over-length `Details__c`) is caught, rolled back, and wrapped in the fixed generic message — no field name, status code, or platform limit leaks to the user. |
| `addUpdateReminderDateOutOfRangeRollsBackCommittedWork` | An out-of-range `ActivityDate` fails the *third* DML (the Task) after the first two have already committed in the same transaction, and `Database.rollback(sp)` reverts all three — the mutation-tested proof described in decision #6 above. |
| `addUpdateReminderNameTooLongIsRejectedWithSpecificMessage` | The up-front 255-char guard rejects with a specific message rather than letting `STRING_TOO_LONG` fall through to the generic DML wrap. |
| `addUpdateReminderNameOverLengthOnlyBeforeTrimIsAccepted` | A name that is >255 raw but ≤255 once trimmed is accepted — the guard measures the trimmed value, matching what is actually stored. |

### Bulk-Test-Rule Applicability

This feature has no trigger, batch, or queueable component, and `addUpdate` is invoked once per
user save action from the LWC composer — not from a bulk DML entry point. Per
`.claude/rules/bulk-test-rule.md`, the 251-record bulk threshold applies to trigger/batch/queueable
contexts and service methods that process collections; it does not apply to this single-record
controller method, consistent with the rest of `LeaseInquiryControllerTest`'s pre-existing test
suite (which also does not carry a 251-record scenario for this class).

---

## 🔒 Security

- `LeaseInquiryController` is `with sharing`.
- SOQL reads go through selectors (`LeaseInquirySelector`, `LeaseActivitySelector`, `LeaseSelector`)
  using `WITH USER_MODE`, per `ARCHITECTURE.md` §2.
- The three DML statements in `addUpdate` (the `Lease_Activity__c` insert, the `Lease_Inquiry__c`
  update, and the `Task` insert) do **not** use `AccessLevel.USER_MODE` — see design decision #5
  above. This is a recorded asymmetry, not an omission: reads enforce FLS, writes do not.
- `AuraHandledException` is used at the LWC boundary for all guard failures and DML failures, per
  `ARCHITECTURE.md` §5; raw platform exception detail (`e.getMessage()`, `e.getStackTraceString()`)
  is sent only to `System.debug(LoggingLevel.ERROR, ...)`, never to the user-facing message.

---

## 📝 Notes & Considerations

### Known Layering Deviation (pre-existing, not introduced by this feature)

`LeaseInquiryController` carries stage-advance business logic, three-object DML, and its own
savepoint/rollback transaction management — all Service-layer responsibilities per
`.claude/rules/apex-layering-rule.md`, which scopes a Controller to "thin: call service, catch
`AuraHandledException`." This is flagged in the class's own header comment as **an accepted
deferral, not a sanctioned pattern**: the P4 selector-layer cleanup wave scoped itself to SOQL
extraction only and consciously left DML/business-logic extraction out of scope. A
`LeaseInquiryService` extraction is untracked. Do not treat this class's shape as precedent for a
new controller.

### Known Open Items (recorded, not resolved by this task)

1. **`AuraHandledException` `setMessage()` sweep — scope and severity unverified.** A repo-wide
   check found 17 `new AuraHandledException(...)` construction sites across 10 classes
   (`BrokerAssignmentController`, `BrokerPortalController`, `CounterOfferController`,
   `DealMessageController`, `LeaseInquiryController`, `LeaseRenewalController`,
   `OpportunityApprovalController`, `PsaVersionController`, `StageAdvanceController`,
   `TransactionTaskController`). Of those 10 classes, **4** now use an `ahe()`-style helper that
   calls `setMessage()`: `StageAdvanceController`, `LeaseRenewalController`,
   `OpportunityApprovalController`, and — as of this build — `LeaseInquiryController`, which gained
   the pattern for this feature. Whether the remaining 6 classes' bare-constructor throws are a
   test-assertability issue only, or a real user-facing defect (toast shows literally
   `"Script-thrown exception"`), is **unverified**. The decisive check: trigger a bare-constructor
   error in the UI (e.g. `CounterOfferController`'s "Pick who made this counter") and read the
   toast text. Friendly text → test-only issue, low priority. `"Script-thrown exception"` → P1
   sweep needed across the remaining 6 classes.

2. **`ARCHITECTURE.md` is stale in two places, unrelated to this feature but observed while
   verifying it.** Not corrected here per instruction — recorded as drift only:
   - §2 states `TestDataFactory` "does not exist yet; it is created in Phase 1 of the conformance
     program." It exists (`force-app/main/default/classes/TestDataFactory.cls`) and is in active
     use — `LeaseInquiryControllerTest.setup()` calls `TestDataFactory.createProperty`,
     `.createPropertyAsset`, `.createBrokerContact`, and `.createLeaseInquiry`.
   - §1's rule-6 DateTime-naming violation list names `Entry_Date__c` on `Lease_Activity__c` (among
     other objects). The actual field is `Entry_DateTime__c`
     (`force-app/main/default/objects/Lease_Activity__c/fields/Entry_DateTime__c.field-meta.xml`),
     which already conforms to rule 6 — the violation-count for that bundle is overstated by at
     least this one field.

---

## 📜 Change History

| Date | Author | Change Description |
|------|--------|--------------------|
| 2026-07-17 | Documentation Agent | Initial creation — documents the reminder → Task feature on the Lease Inquiry Negotiation Log |
