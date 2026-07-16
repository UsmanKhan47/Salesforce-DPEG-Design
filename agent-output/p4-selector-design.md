# Phase 4 — Selector Layer Design (DESIGN / PLAN ONLY)

**Program:** ARCHITECTURE.md §2 conformance — "All SOQL must live in Selector classes. Nothing else queries that object."
**Scope of this run:** architecture + per-module work-list. **No Selector classes written, no repoints, no deploys, no commits.**
**Author context:** Technical Architect. Read: `ARCHITECTURE.md §2`, `CLAUDE.md`, `.claude/rules/apex-layering-rule.md`, `.claude/skills/sf-apex/references/AccountSelector.cls`.
**FLS evidence source:** live describe + `FieldPermissions` read against **DPEG-Acq-5** (default org, API 66/67, expires 2026-08-14) on 2026-07-16. Point-in-time snapshot.

---

## 1. Executive Summary

| Metric | Plan said | This design (measured) |
|---|---|---|
| Selectors to create | ~38 | **24 object selectors** (+ 2 CMDT providers) |
| Query sites | ~107, then re-measured "~38" | **~63 SOQL statements** across 16 team classes (+3 in the out-of-scope guest `BrokerPortalController`) |
| Selectors today | 0 | 0 (confirmed) |
| Standard-object FLS breakage risk under `USER_MODE` | "could break dashboards" (2 reviewers) | **Zero for every internal-facing selector** — proven below |
| Cost | 20–28 dev-days | **26–34 dev-days** (statement count was undercounted; see §9) |

**Headline FLS verdict:** The `USER_MODE` fear does **not** materialise on this org. Custom-field FLS gap = 0 (P3). For standard objects, the only fields carrying FLS are 6 permissionable standard fields, and **all 6 are readable by the `Standard User` profile** (verified) — which is a live active persona here and is exactly P3's "290-field" worst case. Every Opportunity standard field selected is `permissionable=false` (never subject to FLS). **Internal selectors → `USER_MODE` across the board.** The only `SYSTEM_MODE` cases are the **guest/automation path** (`BrokerPortalNotifier` setup-object + Lead lookups) where guest FLS lives on the non-deployable Guest Profile and P3's guest spike never completed.

---

## 2. The Real Inventory (honest recount)

The plan's "~38 query sites" counts at *method/feature* granularity. At the SOQL-*statement* level the real number is **~63**, and several classes scored as "1 query" actually hold 5–8. This is the single biggest way the plan's assumptions did not survive the code (see §10).

| Class | Module | SOQL stmts | Dynamic? | Objects queried | Standard-obj fields selected | Mode |
|---|---|---|---|---|---|---|
| `WorkOrderController` | PM | 6 | 3× `Database.query` | Work_Order__c, Work_Order_Activity__c | none (all custom) | USER |
| `LeaseRenewalController` | PM | 5 | 2× `Database.query` | Lease_Renewal__c, Renewal_Activity__c | `CreatedBy.Name` (rel, non-perm) | USER |
| `BrokerAssignmentController` | PM | 5 | no | Broker_Assignment__c, Contact, ContentDocumentLink, ContentNote | Contact.Name, CDL/ContentNote std fields | USER |
| `BrokerCheckInReminderSchedulable` | PM | 2 | no | Broker_Assignment__c, Task | Task.WhatId, IsClosed, Subject | USER |
| `OpportunityFunnelController` | Acq | **8** | no | Opportunity (×8) | StageName, Name, CloseDate, CreatedDate (all non-perm) | USER |
| `OpportunityDocStatusController` | Acq | **7** | 3× `Database.query` | Opportunity, NDA__c, Underwriting__c, LOI__c, Development_Feasibility_Review__c, Construction_Feasibility_Review__c, Contract_Review__c | Opportunity: custom only | USER |
| `OpportunityApprovalController` | Acq | 5 | no | ProcessInstance, Opportunity, LOI__c, Underwriting__c, Contract_Review__c | Opp.StageName (non-perm); ProcessInstance sys fields | USER (see §5 note) |
| `OpportunityReviewService` | Acq | **5** | no | Development_/Construction_Feasibility_Review__c, Contract_Review__c, Underwriting__c, NDA__c | none (custom lookup only) | USER |
| `LeadFunnelController` | Acq | **5** | no | Lead (×5) | Status, Name, LeadSource, ConvertedDate, LastModifiedDate | USER |
| `StageAdvanceController` | Acq | 1 | no | Opportunity | Id, StageName (non-perm) | USER |
| `PsaVersionController` | Acq | 2 | no | PSA_Version__c | none | USER |
| `DealMessageController` | Acq | 1 | 1× `Database.query` | Deal_Message__c | `CreatedBy.Name` (rel) | USER |
| `BrokerPortalNotifier` | Acq (guest) | 3 | no | CustomNotificationType, Group, Lead | Lead.Name, Company (non-perm) | **SYSTEM** |
| `TransactionTaskController` | Txn | 3 | no | Task_Group_Def__mdt, Task (×2) | Task.Subject/Status/IsClosed/ActivityDate/Description/LastModifiedDate | USER |
| `TaskFanoutService` | Txn | 3 | 1× `Database.query` | Task_Group_Def__mdt, Transaction_Task_Def__mdt, Transaction__c | none | USER |
| `WireController` | Disp | 2 | no | Wire__c | none | USER |
| _`BrokerPortalController` (OUT OF SCOPE — not in the 17)_ | Acq (guest) | _3_ | no | Group, Contact, Lead | Contact.Email (WHERE), Lead std | _SYSTEM_ |
| _`TestDataFactory` (leave)_ | — | 1 | — | — | — | — |

**Total in scope: ~63 SOQL statements, 16 classes, 24 objects, 2 CMDT types.**

---

## 3. The Selector List (one per object)

Per §2 / apex-layering-rule: one selector per object; nothing else queries that object. **Owner module** = the single agent that creates the selector; **Consumers** = every class repointed to it. Cross-module shared selectors are flagged 🔗.

### Custom-object selectors (15) — all `USER_MODE` (P3: custom-field FLS gap = 0)

| # | Selector | Object | Owner module | Consumers |
|---|---|---|---|---|
| 1 | `WorkOrderSelector` | Work_Order__c | PM | WorkOrderController |
| 2 | `WorkOrderActivitySelector` | Work_Order_Activity__c | PM | WorkOrderController |
| 3 | `LeaseRenewalSelector` | Lease_Renewal__c | PM | LeaseRenewalController |
| 4 | `RenewalActivitySelector` | Renewal_Activity__c | PM | LeaseRenewalController |
| 5 | `BrokerAssignmentSelector` | Broker_Assignment__c | PM | BrokerAssignmentController, BrokerCheckInReminderSchedulable |
| 6 | `WireSelector` | Wire__c | Disposition | WireController |
| 7 | `PsaVersionSelector` | PSA_Version__c | Acq | PsaVersionController |
| 8 | `NdaSelector` | NDA__c | Acq | OpportunityDocStatusController, OpportunityReviewService |
| 9 | `UnderwritingSelector` | Underwriting__c | Acq | OpportunityApprovalController, OpportunityDocStatusController, OpportunityReviewService |
| 10 | `LoiSelector` | LOI__c | Acq | OpportunityApprovalController, OpportunityDocStatusController |
| 11 | `ContractReviewSelector` | Contract_Review__c | Acq | OpportunityApprovalController, OpportunityDocStatusController, OpportunityReviewService |
| 12 | `DevelopmentFeasibilityReviewSelector` | Development_Feasibility_Review__c | Acq | OpportunityDocStatusController, OpportunityReviewService |
| 13 | `ConstructionFeasibilityReviewSelector` | Construction_Feasibility_Review__c | Acq | OpportunityDocStatusController, OpportunityReviewService |
| 14 | `DealMessageSelector` | Deal_Message__c | Acq | DealMessageController |
| 15 | `TransactionSelector` | Transaction__c | Transactions | TaskFanoutService |

### Standard business-object selectors (4) — `USER_MODE` (FLS proven safe, §5)

| # | Selector | Object | Owner module | Consumers |
|---|---|---|---|---|
| 16 | `OpportunitySelector` | Opportunity | Acq | OpportunityFunnelController, OpportunityDocStatusController, OpportunityApprovalController, StageAdvanceController |
| 17 | `LeadSelector` | Lead | Acq | LeadFunnelController, BrokerPortalNotifier* (*SYSTEM_MODE method, §5) |
| 18 | `TaskSelector` 🔗 | Task | **Transactions** | TransactionTaskController, **BrokerCheckInReminderSchedulable (PM)** |
| 19 | `ContactSelector` | Contact | PM | BrokerAssignmentController (+ BrokerPortalController later, out of scope) |

### System / setup-object selectors (5)

| # | Selector | Object | Owner module | Consumers | Mode |
|---|---|---|---|---|---|
| 20 | `ProcessInstanceSelector` | ProcessInstance | Acq | OpportunityApprovalController | USER (smoke-test, §5) |
| 21 | `ContentDocumentLinkSelector` | ContentDocumentLink | PM | BrokerAssignmentController | USER (respects file sharing) |
| 22 | `ContentNoteSelector` | ContentNote | PM | BrokerAssignmentController | USER (respects file sharing) |
| 23 | `NotificationTypeSelector` | CustomNotificationType | Acq | BrokerPortalNotifier | **SYSTEM** (guest/setup) |
| 24 | `QueueGroupSelector` | Group | Acq | BrokerPortalNotifier (+ BrokerPortalController later) | **SYSTEM** (guest/setup) |

### CMDT providers (2) — NOT USER_MODE selectors

CMDT (`__mdt`) is metadata, not subject to FLS/sharing — `WITH USER_MODE` is inert on it, and the sf-apex rule says query CMDT via `getAll()/getInstance()`, not SOQL. Recommend small provider classes using `getAll().values()` with in-memory sort, replacing the SOQL:

| Provider | CMDT | Consumers |
|---|---|---|
| `TaskGroupDefProvider` | Task_Group_Def__mdt | TransactionTaskController, TaskFanoutService |
| `TransactionTaskDefProvider` | Transaction_Task_Def__mdt | TaskFanoutService |

> Optional consolidation (team decision, default = one-per-object): #21+#22 could be one `ContentNoteSelector` (always queried as a pair for the Notes feature); #23+#24 could be one `NotificationSetupSelector`. This trims 24→22. Left as-is here to honour the literal one-per-object rule.

---

## 4. Naming & Method-Signature Convention

Follows the `AccountSelector.cls` reference and ARCHITECTURE.md §2. Every module must build selectors to this shape so implementation is uniform.

**Class:** `<Object>Selector`, `public with sharing` (ARCHITECTURE.md §2 mandates `with sharing` on every selector — this overrides the generic `inherited sharing` default in the sf-apex skill). One selector per object. `@AuraEnabled` never appears in a selector — selectors return SObjects/aggregates; controllers wrap and map to DTOs.

**Methods:** `public static`, bulk-first, return `List<SObject>` / `Map<Id,SObject>` / `List<AggregateResult>` / `Integer` (counts). Never return a single SObject — callers take `[0]`.

| Intent | Signature |
|---|---|
| by ids | `List<X> selectByIds(Set<Id> ids)` |
| map by ids | `Map<Id,X> selectMapByIds(Set<Id> ids)` |
| by a FK (idempotency/child lookups) | `List<X> selectByOpportunityIds(Set<Id> oppIds)` |
| filtered list for a widget | `List<X> selectOpenOrderedBySla()`, `selectAttention()` |
| single-parent child list | `List<X> selectByParentId(Id parentId)` |
| aggregate | `List<AggregateResult> countByStage()` |
| count | `Integer countByStageInLastNDays(String stage, Integer days)` |

**Guards:** null/empty input → return empty collection (never null), matching the reference. **Field lists:** centralise in a private `getFields()` returning a `String.join(...)` (reference pattern) so queries stay DRY. **Mode:** static SOQL → `WITH USER_MODE`; dynamic → `Database.query(q, AccessLevel.USER_MODE)` or `Database.queryWithBinds(...)`; counts → `Database.countQuery(q, AccessLevel.USER_MODE)` or `[SELECT COUNT() ... WITH USER_MODE]`. **⚠ Clause order (compile-breaker): `WITH USER_MODE` goes immediately after `FROM`/`WHERE` and BEFORE `GROUP BY`/`ORDER BY`/`LIMIT`.** Placing it after `ORDER BY` or `GROUP BY` fails the compile (caught in the pilot; both skeletons above are now correct).

### Skeleton A — `WorkOrderSelector` (static + dynamic + child; all custom → USER_MODE)

```apex
public with sharing class WorkOrderSelector {
    private static String rowFields() {
        return String.join(new List<String>{
            'Id','Subject__c','Property_Display_Name__c','Unit_Label__c','Priority__c','Status__c',
            'SLA_Health__c','Hours_Open__c','SLA_Breached__c','Untouched__c','Is_Open__c'
        }, ', ');
    }
    // getHomeKpis() source — narrow field set, WITH USER_MODE (static)
    public static List<Work_Order__c> selectForKpis() {
        return [SELECT Is_Open__c, SLA_Breached__c, SLA_Health__c, Untouched__c
                FROM Work_Order__c WITH USER_MODE];
    }
    // getRecent/getEscalations/getUntouched source — was ROW_QUERY + literal tail (no user input)
    public static List<Work_Order__c> selectByClause(String whereOrderClause) {
        return Database.query(
            'SELECT ' + rowFields() + ' FROM Work_Order__c ' + whereOrderClause,
            AccessLevel.USER_MODE);           // dynamic → AccessLevel, NOT the WITH clause
    }
    public static Work_Order__c selectOneById(Id id) {
        List<Work_Order__c> r = [SELECT Untouched__c FROM Work_Order__c WHERE Id = :id WITH USER_MODE LIMIT 1];
        return r.isEmpty() ? null : r[0];
    }
}
```
(`WorkOrderActivitySelector.selectByWorkOrderId(Id)` holds the timeline query with its `ORDER BY Entry_DateTime__c DESC, Name DESC`.)

### Skeleton B — `OpportunitySelector` (standard object, aggregates + counts; USER_MODE proven safe)

```apex
public with sharing class OpportunitySelector {
    public static List<AggregateResult> countByStage() {
        return [SELECT StageName st, COUNT(Id) c FROM Opportunity WITH USER_MODE GROUP BY StageName];
    }
    public static Integer countByStageLastNDays(String stage, Integer days) {
        // no user-authored field/operator strings → bind literals; USER_MODE on count
        return Database.countQuery(
            'SELECT COUNT() FROM Opportunity WHERE StageName = :stage AND CloseDate = LAST_N_DAYS:' + Integer.valueOf(days),
            AccessLevel.USER_MODE);
    }
    public static List<Opportunity> selectTopByAskingPrice(Integer lim) {
        return [SELECT Id, Name, StageName, Deal_Type__c, Asset_Type__c, Asking_Price__c, Underwritten_NOI__c, CreatedDate
                FROM Opportunity WITH USER_MODE
                ORDER BY Asking_Price__c DESC NULLS LAST, CreatedDate DESC LIMIT :lim];
    }
    public static Opportunity selectStageById(Id id) {
        List<Opportunity> r = [SELECT Id, StageName FROM Opportunity WHERE Id = :id WITH USER_MODE LIMIT 1];
        return r.isEmpty() ? null : r[0];
    }
}
```

### Skeleton C — dynamic with a per-parent bind + SYSTEM_MODE guest lookup

```apex
// OpportunityDocStatusController.queryNda(tail, pid) → NdaSelector. `tail` is a hardcoded
// allowlisted clause ('Id = :pid' | 'Opportunity__c = :pid ORDER BY CreatedDate DESC').
public with sharing class NdaSelector {
    public static NDA__c selectOneByClause(String tail, Id pid) {
        List<NDA__c> rows = Database.queryWithBinds(
            'SELECT Id, Name, Status__c, Date_Sent__c, NDA_Expiry_Date__c, NDA_Signed__c FROM NDA__c WHERE ' + tail + ' LIMIT 1',
            new Map<String,Object>{ 'pid' => pid },
            AccessLevel.USER_MODE);
        return rows.isEmpty() ? null : rows[0];
    }
}

// BrokerPortalNotifier setup lookups — guest/automation path → SYSTEM_MODE (justified).
public with sharing class QueueGroupSelector {
    /**
     * SYSTEM_MODE: invoked from the Broker-Portal lead intake in guest/automation
     * context. Group is a setup object; guest/portal profiles have no FLS on it and
     * guest FLS lives on the non-deployable Guest Profile (P3 guest spike incomplete).
     * This is a Developer-Name → Id lookup of a queue, not user data.
     */
    public static Group selectQueueByDeveloperName(String devName) {
        List<Group> g = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :devName
                         WITH SYSTEM_MODE LIMIT 1];
        return g.isEmpty() ? null : g[0];
    }
}
```

---

## 5. `USER_MODE` vs `SYSTEM_MODE` — decision per selector, with the standard-object FLS check done

**Method:** For each *standard* object, every selected/filtered standard field was classified `permissionable` (FLS-controllable) vs not, via live describe. `permissionable=false` ⇒ never subject to FLS ⇒ always readable ⇒ `USER_MODE` cannot throw on it. For the `permissionable=true` ones, `FieldPermissions` was read for the **`Standard User`** profile (a live active persona on DPEG-Acq-5, and P3's "290-field" worst case).

**Standard fields selected, classified (evidence):**

| Object | `permissionable=false` (always readable) | `permissionable=true` (FLS-controlled) | Standard User READ on the true ones? |
|---|---|---|---|
| Opportunity | Id, Name, StageName, CloseDate, CreatedDate | — (none selected) | n/a — **no risk at all** |
| Lead | Id, Name, Status, Company, ConvertedDate, LastModifiedDate | LeadSource | **true** ✔ |
| Task | Id, Subject, Status, IsClosed, LastModifiedDate, OwnerId, Priority | ActivityDate, Description, WhatId, WhoId | **true (all 4)** ✔ |
| Contact | Id, Name | Email* | true ✔ (*Email is only a WHERE filter in the out-of-scope guest `BrokerPortalController`; in-scope `BrokerAssignmentController` selects Name only) |

Custom fields on all objects: P3 measured the FLS gap = **0** across 463 custom fields. Re-confirmed spot-wise in describe (`Deal_Type__c`, `Asking_Price__c`, `Broker_Priority__c`, … all `permissionable=true` and covered by the deployed permsets).

**Decision table:**

| Selector(s) | Mode | Justification |
|---|---|---|
| All 15 custom-object selectors | **USER_MODE** | custom-field FLS gap = 0 (P3), re-confirmed by describe |
| `OpportunitySelector` | **USER_MODE** | every standard field selected is `permissionable=false` → always readable; custom fields granted |
| `LeadSelector` (internal: LeadFunnelController) | **USER_MODE** | only FLS-bearing std field is `LeadSource`; Standard User READ=true |
| `TaskSelector` | **USER_MODE** | 4 FLS-bearing std fields (ActivityDate/Description/WhatId/WhoId) all Standard User READ=true |
| `ContactSelector` | **USER_MODE** | in-scope query selects `Name` (non-perm) + `Broker_Firm__c` (custom, granted) only |
| `ContentDocumentLinkSelector`, `ContentNoteSelector` | **USER_MODE** | **desired** — these SHOULD enforce the running user's file sharing; std fields only |
| `ProcessInstanceSelector` | **USER_MODE** (smoke-test) | fields are system (non-perm); record visibility follows access to the target deal, which the submitter has. The one internal case that touches an approval-system object — worth a manual smoke-test, not a blocker |
| `NotificationTypeSelector`, `QueueGroupSelector` (guest) | **SYSTEM_MODE** | `BrokerPortalNotifier` runs in guest/automation context; `CustomNotificationType` & `Group` are setup objects with no guest FLS; guest FLS lives on the non-deployable Guest Profile and **P3's guest spike never completed** — do not apply USER_MODE blind |
| `LeadSelector` **method used by `BrokerPortalNotifier`** | **SYSTEM_MODE** | same guest/automation transaction. Selected fields (Name/Company non-perm, Property_Address__c custom-granted) would pass USER_MODE, but per policy the guest path is not put under USER_MODE unverified. Implement as a **separate `selectByIdsSystem(Set<Id>)` method** on `LeadSelector` so the internal LeadFunnel path stays USER_MODE and the guest path is explicitly SYSTEM_MODE. |

**Net: 22 selectors USER_MODE, 2 selectors SYSTEM_MODE (guest setup) + 1 SYSTEM_MODE method on LeadSelector.** No standard-object selector needs a permset change — the grants already exist. If future personas are more restrictive than `Standard User`, re-run the §5 check before assuming safety.

---

## 6. Dynamic-Query Conversions (the 5 `Database.query` / `getQueryLocator` classes)

`WITH USER_MODE` is a SOQL *clause* and is illegal in a `Database.query(String)` call — dynamic queries take the mode as an `AccessLevel` argument instead.

| Class | Current | Convert to | Notes |
|---|---|---|---|
| `WorkOrderController` (×3: recent/escalations/untouched) | `Database.query(ROW_QUERY + '<literal WHERE/ORDER>')` | `Database.query(q, AccessLevel.USER_MODE)` in `WorkOrderSelector.selectByClause(...)` | No user input in the tail (hardcoded literals). Safe. |
| `LeaseRenewalController` (×2: recent/attention) | `Database.query(ROW_QUERY + '<literal>')` | `Database.query(q, AccessLevel.USER_MODE)` in `LeaseRenewalSelector` | Same — literal tails only. |
| `OpportunityDocStatusController` (×3: NDA/UW/LOI) | `Database.query('... WHERE ' + tail + ' LIMIT 1')` with `:pid` bound to a local | `Database.queryWithBinds(q, {'pid'=>pid}, AccessLevel.USER_MODE)` | **Important:** `:pid` currently binds to a method-local; moving into a selector breaks that scope — pass the bind map explicitly. `tail` is an allowlisted literal, not user input. Custom → USER_MODE. |
| `DealMessageController` (getMessages) | `Database.query('... WHERE ' + parentField + ' = :recordId ...')` | `Database.queryWithBinds(q, {'recordId'=>recordId}, AccessLevel.USER_MODE)` in `DealMessageSelector` | `parentField` comes from the `PARENT_FIELDS` allowlist (`LOI__c/Underwriting__c/Contract_Review__c`) — injection-safe. Custom → USER_MODE. |
| `TaskFanoutService` (fanOutNow) | `Database.query('SELECT ' + fieldList + ' FROM Transaction__c WHERE Id IN :transactionIds')` | `Database.query(q, AccessLevel.USER_MODE)` in `TransactionSelector.selectByIdsWithConditionFields(Set<Id>, Set<String> condFields)` | `fieldList` is `Id, OwnerId, Contract_Executed_Date__c, Tasks_Fanned_Out__c` + CMDT `Condition_Field__c` values. Those come from CMDT (admin-controlled), but the selector should **validate each condField against `Transaction__c` describe** before concatenating (defense-in-depth vs a bad CMDT row). Custom → USER_MODE. |

No `getQueryLocator` in scope after all — the 5 dynamic classes are all `Database.query`. (The plan's "getQueryLocator" reference does not appear in these 16 classes; the only Batchable-style locator would be elsewhere. Flagged in §10.)

---

## 7. Per-Module Implementation Work-List

One agent per module against this spec. **Acquisitions is oversized (13 selectors / 37 statements / 9 classes)** — split into two waves so a single agent can hold it (the scale that has killed agents this session is whole-codebase / 460-field sweeps; each wave below is well under that).

### 🔗 Cross-module sequencing dependency (must respect)
`TaskSelector` is shared by **Transactions** (owner) and **PM** (`BrokerCheckInReminderSchedulable`). **Transactions builds `TaskSelector` first**; PM's repoint of the Schedulable depends on it existing. Dispatch order: Transactions before (or coordinated with) the PM Task repoint. All other selectors are single-module.

### Module A1 — Acquisitions: Deal Core (Opportunity + Lead + deal-review reads)
- **Create:** `OpportunitySelector`, `LeadSelector` (USER_MODE internal methods only), `NdaSelector`, `UnderwritingSelector`, `LoiSelector`, `ContractReviewSelector`, `DevelopmentFeasibilityReviewSelector`, `ConstructionFeasibilityReviewSelector`, `ProcessInstanceSelector`
- **Repoint:** `OpportunityFunnelController` (8 stmts), `OpportunityDocStatusController` (7, incl. 3 dynamic→queryWithBinds), `OpportunityApprovalController` (5, incl. ProcessInstance), `StageAdvanceController` (1)
- **Size:** 9 selectors, ~21 statements, 4 classes. Heaviest wave.

### Module A2 — Acquisitions: Deal Support (review-service + PSA + messages + guest notifier)
- **Create:** `PsaVersionSelector`, `DealMessageSelector` (dynamic→queryWithBinds), `NotificationTypeSelector` (SYSTEM), `QueueGroupSelector` (SYSTEM), + add `LeadSelector.selectByIdsSystem(...)` SYSTEM method (LeadSelector class created in A1 — A2 adds one method; coordinate or fold LeadSelector wholly into A1)
- **Repoint:** `OpportunityReviewService` (5 — reuses NDA/UW/Contract/Dev/Con selectors from A1), `PsaVersionController` (2), `DealMessageController` (1), `BrokerPortalNotifier` (3, SYSTEM)
- **Size:** 4 new selectors (+1 method), ~11 statements, 4 classes. **Note:** A2 consumes A1's review selectors → run A2 after A1.

### Module B — Property Management
- **Create:** `WorkOrderSelector`, `WorkOrderActivitySelector`, `LeaseRenewalSelector`, `RenewalActivitySelector`, `BrokerAssignmentSelector`, `ContactSelector`, `ContentDocumentLinkSelector`, `ContentNoteSelector`
- **Reuse:** `TaskSelector` (from Transactions)
- **Repoint:** `WorkOrderController` (6, 3 dynamic), `LeaseRenewalController` (5, 2 dynamic), `BrokerAssignmentController` (5), `BrokerCheckInReminderSchedulable` (2 — depends on `TaskSelector`)
- **Size:** 8 selectors, ~18 statements, 4 classes.

### Module C — Transactions
- **Create:** `TaskSelector` 🔗 (build first — PM depends on it), `TransactionSelector` (dynamic + condition-field validation), `TaskGroupDefProvider` (CMDT→getAll), `TransactionTaskDefProvider` (CMDT→getAll)
- **Repoint:** `TransactionTaskController` (3), `TaskFanoutService` (3)
- **Size:** 2 selectors + 2 CMDT providers, ~6 statements, 2 classes.

### Module D — Disposition
- **Create:** `WireSelector`
- **Repoint:** `WireController` (2)
- **Size:** 1 selector, ~2 statements, 1 class. (Tiny — could be folded into another agent's run.)

**Per-selector deliverable (every module):** selector class + `SelectorTest` class with a **251+ bulk method** (bulk-test-rule) asserting field population, filter behaviour, empty-input guard, and — for standard-object selectors — a `System.runAs(standardUser)` test proving USER_MODE returns rows (per sf-apex-test §Selector). Keep existing consumer tests green after repoint.

---

## 8. Out-of-scope items to keep whole (do NOT touch this pass)
- **No `UnitOfWork`.** Per the layering rule it does not exist and is explicitly out of scope. Existing `insert/update/upsert` DML in the controllers/services **stays where it is** — this pass moves SOQL only. (Classes with resident DML: LeaseRenewalController, BrokerAssignmentController, WireController, PsaVersionController, TransactionTaskController, TaskFanoutService, OpportunityReviewService, StageAdvanceController, OpportunityApprovalController, BrokerCheckInReminderSchedulable.)
- **CMDT** stays functionally identical; converting the 3 CMDT SOQL statements to `getAll()` providers is recommended but orthogonal to the FLS goal — a module may keep the CMDT SOQL if time-boxed, since `USER_MODE` is inert on `__mdt` anyway.

---

## 9. Honest Cost

The plan's 20–28 dev-days assumed ~38 sites. The real statement count is **~63**, and four classes scored "1 query" are really 5–8 (`OpportunityReviewService`=5, `LeadFunnelController`=5, `OpportunityFunnelController`=8, `OpportunityDocStatusController`=7). Selector count lands at **24 (+2 CMDT providers)** — fewer classes than "38", but each ships with a bulk-251 test.

| Module | Selectors | Stmts | Classes repointed | Est. dev-days |
|---|---|---|---|---|
| A1 Acq Deal Core | 9 | ~21 | 4 | 9–11 |
| A2 Acq Deal Support | 4 (+1 method) | ~11 | 4 | 5–6 |
| B Property Management | 8 | ~18 | 4 | 7–9 |
| C Transactions | 2 (+2 CMDT) | ~6 | 2 | 3–4 |
| D Disposition | 1 | ~2 | 1 | 1 |
| Integration/regression/code-review buffer | — | — | — | 1–3 |
| **Total** | **24 (+2)** | **~63** | **16** | **26–34** |

Driver of the overage vs plan: ~63 statements not ~38, and the selector-test discipline (24 bulk-251 test classes + `runAs` FLS tests). If the team accepts the two optional consolidations (§3) and keeps CMDT-as-SOQL, trim ~2–3 days.

---

## 10. Where the plan's assumptions did not survive the code (flags)

1. **"~38 query sites" undercounts by ~40%.** Real = **~63 SOQL statements**. The plan counted at method granularity; `OpportunityReviewService` (scored 1) is 5, `LeadFunnelController` (1) is 5, `OpportunityFunnelController` (3) is 8, `OpportunityDocStatusController` (3) is 7, `BrokerAssignmentController` (4) is 5. Cost and test volume scale off statements, not the "38".
2. **The `USER_MODE` FLS fear is disproven for internal selectors, decisively.** Not one selected standard field is invisible to `Standard User`: Opportunity's are all `permissionable=false`; Lead/Task/Contact's FLS-bearing ones are all Standard-User READ=true. The two reviewers' warning does not hold on this org's current grants.
3. **`BrokerPortalController` is guest-facing, has 3 inline SOQL statements (Group/Contact/Lead), and is NOT in the 17-class inventory.** It is the twin of `BrokerPortalNotifier`. Recommend either adding it to Module A2 (as SYSTEM_MODE, reusing `QueueGroupSelector`/`ContactSelector`/`LeadSelector`) or explicitly deferring it — but it should not be silently missed, or §2's "nothing else queries that object" is violated the moment it ships.
4. **No `getQueryLocator` exists in the 16 classes.** The plan lists 5 dynamic classes as `Database.query`/`getQueryLocator`; all 5 are `Database.query` only. If a batch/locator conversion was expected, it's not here (would live in a Batchable elsewhere — out of this scope).
5. **Two CMDT SOQL types (`Task_Group_Def__mdt`, `Transaction_Task_Def__mdt`) are not real "selector" candidates.** `WITH USER_MODE` is meaningless on `__mdt`. Treat as `getAll()` providers, not FLS-enforced selectors.
6. **`OpportunityDocStatusController`'s dynamic `:pid` bind is method-scoped.** A naive move into a selector breaks the bind — must use `Database.queryWithBinds` with an explicit bind map. Same for `DealMessageController`'s `:recordId`. Calling this out so a module agent doesn't produce a compiling-but-broken selector.
7. **`TaskSelector` is the only genuine cross-module shared selector** (Transactions + PM). Sequencing matters — build it in Transactions first.
