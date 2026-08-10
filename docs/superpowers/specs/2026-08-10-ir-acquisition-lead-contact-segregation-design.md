# IR / Acquisitions segregation — Lead, Contact and Account

**Date:** 2026-08-10
**Status:** Design approved, not yet planned or implemented
**Author:** Design session with Akbar Zaidi

---

## 1. Problem

DPEG is standing up a second team. **Investor Relations (IR)** will work Leads and Contacts alongside the existing **Acquisitions** team, which uses those same two objects for **brokers**.

Today the two populations would be indistinguishable and mutually visible. The requirement is a **hard security boundary**: IR must not be able to reach broker Leads, Contacts or Accounts, and Acquisitions must not be able to reach investor ones — not merely a decluttered UI.

### Decisions taken at design time

| Question | Answer | Consequence |
|---|---|---|
| Security boundary or workspace separation? | **Hard security boundary** | Org-wide OWD changes and criteria-based sharing rules are in scope. |
| Can one person be both a broker and an investor? | **Never** | The populations are disjoint. `LeadConvertMatchService`'s email-only Contact match cannot cross-attach, and no dual-role record model is needed. |
| Is IR net new, or migrating existing data? | **Net new** | Every existing Lead / Contact / Account is Acquisitions. The backfill is a blanket stamp, not a classification exercise. |

---

## 2. Current state (measured 2026-08-10)

| Fact | Source | Implication |
|---|---|---|
| No record types on Lead, Contact or Account | `objects/{Lead,Contact,Account}/` — no `recordTypes/` directory | Clean slate; nothing to migrate. |
| `Account.sharingModel = ReadWrite` (Public) | `Account.object-meta.xml` | Every Account is visible to every user with Account Read. |
| `Contact.sharingModel = ControlledByParent` | `Contact.object-meta.xml` | Contact visibility is entirely a function of Account visibility. **Combined with the row above, every Contact in the org is currently visible to everyone with Contact Read.** |
| `Contact.sharingRules` is empty; `Account.sharingRules` is empty | `sharingRules/` | Record-level segregation for these objects is unbuilt. |
| `Lead.sharingModel` reads `ReadWriteTransfer` in the repo | `Lead.object-meta.xml` | **Unverified.** OWD on standard objects is not deployable metadata, so the repo file never reconciles with the org. Must be read from Setup. |
| One Lead sharing rule: `Lead_Acquisition_Queue_RW` (Acquisition queue → `DPEG_Acquisitions_Team`) | `sharingRules/Lead.sharingRules-meta.xml` | Preserved unchanged. |
| No Apex anywhere references a RecordType on Lead or Contact | `grep` over `classes/` | Adding record types carries low code risk. |
| `LeadConvertMatchService` matches a Contact on `Email` alone, and the Contact match wins | class header | Would be the sharpest cross-team collision — **neutralised by the "never overlaps" decision**, and closed structurally anyway (§6). |
| The only Contact lookups in the app are `Broker_Assignment__c.Broker__c`, `Lease_Inquiry__c.Broker__c`, `Opportunity.Broker__c` | `grep referenceTo Contact` | Property Management and Transactions both consume broker Contacts. The split is **"everyone except IR" vs "IR only"**, not two-way. |
| **Zero custom Account lookups exist** | `grep referenceTo Account` | Account → Private has a far smaller blast radius than expected. |
| `LeadSelector.GuestReads`, `ContactSelector.GuestReads` and `BrokerPortalService` are already `without sharing` | class headers | **The Broker Portal guest dedup already survives Lead/Account going Private.** No change needed. |
| `Investor_Relations` public group already exists, with `doesIncludeBosses = true` | `groups/Investor_Relations.group-meta.xml` | Reusable. The flag is inconsistent with `DPEG_Acquisitions_Team` (`false`) and must be set deliberately. |
| Contact has 12 broker-only fields (`Broker_Firm__c`, `Broker_License__c`, `Deals_Won__c`, `Closed_Volume__c`, `NDA_On_File__c`, …) | `objects/Contact/fields/` | FLS must be split per team, not just layouts. |

---

## 3. Architecture — Account is the boundary, Contact inherits it

Rather than flipping three OWDs, flip **two** and let the existing `ControlledByParent` relationship carry Contact.

| Object | OWD today | OWD after | Segregation mechanism |
|---|---|---|---|
| **Account** | `ReadWrite` | **`Private`** | Record types `Broker_Firm` / `Investor_Entity` + criteria-based sharing rules |
| **Contact** | `ControlledByParent` | **unchanged** | Inherits its Account. Record types `Broker` / `Investor` for layout, FLS and reporting only — **not** for sharing. |
| **Lead** | `ReadWriteTransfer` (unverified) | **`Private`** | Record types `Acquisition_Broker` / `IR_Investor` + criteria-based sharing rules |

**Why Account rather than Contact as the sharing boundary:** making Contact `Private` is a second org-wide OWD change with its own recalculation and blast radius, and it buys nothing. Because a person is **never both** a broker and an investor, the firm/entity *is* the correct boundary — there is no case where one Account's Contacts must split across teams. One OWD change on the parent, one mental model, one recalculation. It also leaves the `contactAccessLevel` setting on roles inert, removing an axis that is easy to get wrong.

### Assumption, with a defined switch point

`ControlledByParent` means a Contact with no Account is visible to its owner alone. This is correct for brokers (always at a firm) and assumes **investors are modelled as entities** — LLCs, trusts, funds — each with an Account.

> **Switch point:** if a meaningful share of DPEG investors turn out to be *individuals* rather than entities, Contact moves to `Private` and gains its own criteria-based sharing rules on the Contact record type. That is a contained change to §3 and §4, not a redesign.

### Roles

One new role, `Investor_Relations_Manager`, parented to `DPEG_Principal` — a **sibling** of `Acquisitions_Analyst`, `Transactions_Coordinator` and `Property_Management_Coordinator`.

Siblings do not see each other's records under Private OWD, so **the boundary holds by construction rather than by rule**. The Principal sees both sides automatically through upward hierarchy access, which is intended.

---

## 4. Sharing rules

Criteria-based, on **Account and Lead only**. Contact needs none — it inherits.

| Rule | Criteria | Shared to | Access |
|---|---|---|---|
| `Account_Broker_Firm_Internal` | RecordType = `Broker_Firm` | `DPEG_Acquisitions_Team`, `DPEG_Transactions_Team`, `DPEG_Property_Mgmt_Team` | Read/Write |
| `Account_Investor_Entity_IR` | RecordType = `Investor_Entity` | `Investor_Relations` | Read/Write |
| `Lead_Acquisition_Broker` | RecordType = `Acquisition_Broker` | `DPEG_Acquisitions_Team` | Read/Write |
| `Lead_IR_Investor` | RecordType = `IR_Investor` | `Investor_Relations` | Read/Write |

Existing `Lead_Acquisition_Queue_RW` is preserved unchanged.

**On the access levels:** a sharing rule grants *record* access; **object CRUD in the permission set remains the ceiling**. `Read/Write` on `Account_Broker_Firm_Internal` therefore does not hand Property Management edit rights on broker Accounts — `DPEG_PropertyMgmt_View` caps them at Read regardless. Setting the rules to Read/Write keeps the record-level and object-level questions separate, so per-team access is tuned in exactly one place: the permission sets.

Two constraints on delivery:

- ⚠ **Sharing rules must be deployed one at a time.** A batch deploy rolls all of them back on a single failure (established on this project during the 2026-07-22 RBAC build).
- ⚠ **Criteria-based sharing on `RecordTypeId` must be verified against this org before it is committed to.** If rejected, the fallback is a `Business_Unit__c` picklist (`Acquisitions` / `Investor Relations`) kept in sync by the same code that stamps the record type, with sharing keyed on that field instead. **This is a T1 verification gate, not a T5 discovery.**

`Investor_Relations` currently carries `doesIncludeBosses = true` while `DPEG_Acquisitions_Team` carries `false`. Set IR to **`false`** for symmetry and let the role hierarchy be the single mechanism granting the Principal upward access — two mechanisms doing one job is how this drifts.

---

## 5. Keeping Accounts and Contacts genuinely separate

The sharing model above is necessary but not sufficient. Because Contact visibility is derived from its Account, **the boundary leaks the moment a Contact and its Account disagree about which team owns them.** These enforcement points are part of the deliverable, not hardening to do later.

| Leak | Enforcement |
|---|---|
| A `Broker` Contact parented to an `Investor_Entity` Account (or vice versa) — the Contact becomes visible to the wrong team | **Validation rule on Contact:** the Contact's record type must match its parent Account's record type. Blocks both creation and reparenting. |
| An Account's record type is changed after it has Contacts, silently moving every child across the boundary | **Validation rule on Account:** block record-type changes outright. A miscategorised Account is corrected by an admin with Modify All Data, deliberately, not by an end user mid-workflow. |
| A broker Account and an investor Account are merged | **Duplicate and matching rules scoped per record type**, so cross-type candidates are never offered for merge. |
| `viewAllRecords` / `modifyAllRecords` on Account, Contact or Lead in any permission set defeats sharing entirely | **Verified absent as of 2026-08-10** on all of Lead, Contact and Account. Add a standing check to the deploy gate — note `DPEG_Acquisition_View` / `_Edit` *do* grant `viewAllRecords` on **Opportunity**, which is correct today but is the shape to watch for. |
| Lead conversion mints a cross-type Account or Contact | Covered by the `LeadConvertService` stamp in §6. |
| Administrators see everything | **Accepted.** "Modify All Data" is outside this boundary by design, consistent with every other gate in this org. |

Reports, list views and global search all respect sharing, so they need no separate treatment.

---

## 6. Apex changes

| Class | Change |
|---|---|
| `EmailToLeadService.createLeadFromExtracted` | Stamp `Acquisition_Broker`, describe-guarded via `isAvailable()` (the `DispositionService.onMarketRecordTypeId` pattern). A describe, not a query — **zero new SOQL**. |
| `BrokerPortalService` | The same stamp on the guest Lead insert. |
| `LeadConvertService` | Stamp Contact = `Broker` and Account = `Broker_Firm`. Standard conversion **does not map Contact record types** — the converted Contact takes whatever is default for the *running user's profile*, so without this an acquisition conversion can mint an `Investor` Contact. ⚠ This class carries a **test-pinned 2 SOQL / 3 DML budget**; the stamps must ride the existing `update updates` statement. The pin goes red if they do not. |
| `LeadConvertMatchService`, `ContactSelector.selectByEmails`, `AccountSelector.selectByNames` | Filter to the broker record type. The populations never overlap today, so this changes no behaviour — it makes the guarantee **structural rather than policy-dependent**. |
| `LeadSelector.GuestReads`, `ContactSelector.GuestReads`, `BrokerPortalService` (reads) | **No change.** Already `without sharing` + `SYSTEM_MODE`, so the Broker Portal anti-abuse dedup survives the OWD flip intact. |

No new triggers, services, selectors or objects. Every change is an addition to an existing class.

---

## 7. Sequencing

Order is load-bearing. If the OWD flips while any record lacks a record type, that record matches no sharing rule and **disappears from everyone except its owner.**

```
T1  Record types (Lead, Contact, Account) + layouts + compact layouts
    + recordTypeVisibilities on every existing persona permission set
    GATE: criteria-based sharing on RecordTypeId verified in-org (§4)
    GATE: current real Lead OWD read from Setup
                                                    → additive, invisible to users

T2  Apex stamps: EmailToLeadService, BrokerPortalService, LeadConvertService
    + TestDataFactory record-type stamping
                                                    → new records are now safe

T3  Backfill: stamp every existing Lead / Contact / Account with the
    Acquisition / Broker / Broker_Firm type
    GATE: query returns 0 rows with a null or Master record type

T4  Groups, Investor_Relations_Manager role, IR permission sets, PSG,
    validation rules (§5), sharing rules (one at a time)
                                                    → inert while OWD is public

T5  ⚠ OWD FLIP — Account → Private, Lead → Private
    MANUAL, in Setup, by an admin. Not deployable. Verified by read-back.

T6  Investor Relations app, tabs, list views, dashboards
```

**T2 must precede T3.** Between the backfill finishing and the stamping code shipping, every inbound broker email would mint an unstamped Lead.

---

## 8. Testing

| Risk | Treatment |
|---|---|
| **Highest-volume risk:** introducing record types on Lead and Contact affects `TestDataFactory`, and the suite is ~600+ tests, most of which create a Lead or a Contact. Each would otherwise take the test user's profile default. | `TestDataFactory` stamps explicitly, and the stamp tolerates the record type not existing, so T1 and T2 can land in either order. |
| Record types deployed via the Metadata API are visible to **no profile by default** — the same trap as FLS on new fields. Miss it and users cannot create Leads at all, and `Database.convertLead` fails outright. | Explicit `<recordTypeVisibilities>` in every persona permission set, delivered in T1 alongside the record types. |
| A PermissionSet deploy **replaces** its entire `<fieldPermissions>` set. Splitting `DPEG_Contact_Edit` into broker-only and investor-only FLS risks wiping surviving grants. | Every surviving grant declared in-file. This wiped a live `Task.WhoId` grant twice in August 2026. |
| An admin smoke test proves nothing about a sharing boundary. | UAT is run **as each real persona** — an IR user, an acquisitions analyst, a PM coordinator and the Principal — confirming each sees exactly its own population and nothing else. |
| The `LeadConvertService` governor pin | Existing test asserts 2 SOQL / 3 DML; it must stay green without being relaxed. |

The `.claude/rules/bulk-test-rule.md` 251-record mandate is unaffected — no new trigger, batch or queueable is introduced.

---

## 9. Out of scope

- The IR module itself — investor commitments, distributions, K-1s, Plaid bank linking, the Experience Cloud investor portal. This spec delivers only the **segregation substrate** those features will sit on.
- Migrating any existing record into IR. IR is net new.
- Person Accounts. Not enabled, and not required under the entity assumption in §3.
- Splitting Opportunity, Task or any other object between the teams.

---

## 10. Open items

1. **Does criteria-based sharing accept `RecordTypeId` in this org?** Verify in T1. Fallback is a synced `Business_Unit__c` picklist (§4).
2. **What is the real current Lead OWD?** The repo value is unverifiable; read it from Setup in T1.
3. **Are DPEG's investors entities or individuals?** Assumed entities. If largely individuals, apply the §3 switch point.
