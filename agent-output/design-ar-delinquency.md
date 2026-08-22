# USER DECISIONS - 2026-08-22 - BINDING, DO NOT RE-OPEN

Decided by the user AFTER this design was written. Where they conflict with anything below, these win.

| # | Decision |
|---|---|
| D-AR-1 | KEEP standard Case. The FSD 5.9.2 justification (append-only Case Comments, owner, queues, entitlements, email-to-case) holds. Unlike Asset, Case's only blocker is the ignore line, and its OWD is changeable. |
| D-AR-2 | .forceignore surgery is a GATED PHASE 0 owned by the ORCHESTRATOR, not by this stream. Remove objects/Case/** (line 252) and layouts/Case-* (line 281), then PROVE it: isolated dry-run plus readback of the deploy files array confirming the components actually shipped. Nothing Case-dependent starts until that proof exists. A negation cannot rescue a path under a dir/** ignore - this has already failed twice on Account. |
| D-AR-3 | standardValueSets/ is NOT ignored, so Case Status/Reason values deploy while the object half vanishes - a partial-looking success. Treat a green deploy as unproven until the readback. standardValueSets also REPLACE the whole set, same hazard as PermissionSet fieldPermissions. |
| D-AR-4 | Tenant identity keys on Unit__c - already the Yardi mirror, already carries Yardi_Unit_Id__c, Property_Asset__c, Tenant_Name__c and Current_Monthly_Rent__c (the Months-Outstanding denominator). KNOWN CONSEQUENCE TO DESIGN FOR: a tenant occupying several suites becomes several rows, so section 6.5 "worst by dollars" needs an explicit roll-up to read correctly. Do not leave that implicit. |
| D-AR-5 | DO NOT join to Lease__c - it is the leasing-pipeline shell minted from Lease_Inquiry__c (7 fields, no property asset, no Yardi id). An FSD Lease lookup would assert a false relationship. |
| D-AR-6 | Runtime config uses a Hierarchy Custom Setting, NOT CMDT. Repo precedent is SharePoint_Config__c and Content_Publication_Budget__c (getOrgDefaults, zero SOQL, tunable in Setup without a deploy). This supersedes the original brief and dissolves the CMDT-record-deploy gotcha. |
| D-AR-7 | Accepted: Has Open Delinquency Case CANNOT be a formula. Split into a sharing-proof SOQL guard plus a sync-written Checkbox. Case.Yardi_AR_Id__c is externalId but MUST NOT be unique, or a re-delinquenting tenant can never get a second Case. |
| D-AR-8 | Case OWD is ReadWriteTransfer today, which HIDES the duplicate-maker risk rather than removing it. The idempotency guard must be sharing-proof BEFORE Case is hardened. This repo has a live incident of exactly that shape: SYSTEM_MODE lifts CRUD/FLS but never sharing, and allOrNone=false swallowed the failure. |
| D-AR-9 | Write-off approval: recordLock = false on EVERY step. A locked Case blocks the nightly balance refresh for precisely the cases under principal review. Also set runInMode explicitly - a Flow without it runs as the APPROVER, whose CRUD is read-only. |
| D-AR-10 | Correction to the original brief: there are SEVEN approval processes in the repo, not one. Use the closest fit as the pattern. workflows/Case.workflow-meta.xml ALREADY EXISTS - AR alerts must be ADDED to it, not created fresh. |
| D-AR-11 | Retire Delinquency__c via the additive sequence, including fixing scripts/seed-pm-dashboard.apex lines 37-44 and 66, which resurrect it on every org rebuild. Reports do NOT block field deletion and the failure is silent. |
| D-AR-12 | Ingestion stays PULL against ASB (user-acknowledged third section-3.4 exception), contained in ONE class holding the single endpoint constant and single Http.send. FIRST check whether an ASB receivables spoke exists - if it does, this is the first CONFORMING section-3.1 implementation and not an exception at all. Draft section 3.5 both ways and confirm before writing it. |
| D-AR-13 | GroupNotifier hardcodes Acquisitions_Deal_Update - the 60/90-day escalations to Isha and Nikhil would arrive branded "Acquisitions - Deal Update". Parameterise it. See D-ON-7. |

---

# Design Requirements — FSD §5.9 Accounts Receivable & Delinquency + §6.5 AR Dashboard

**Agent:** salesforce-design · **Date:** 2026-08-22 · **Branch:** `feature/disposition-redesign`
**Source spec:** FSD §4, §5.9.1–5.9.9, §6.1, §6.5, §7, UAT AR-001..AR-005
**Output file (per brief, to avoid collision with two concurrent design runs):** `agent-output/design-ar-delinquency.md`

## Rule-gate status

```
intent=app | best_matched_skill=none-loaded-by-this-agent | skill_selection=n/a-for-design-phase
mcp=unavailable | mcp_tools=none
```

`.claude/rules/salesforce-global-rule.md` mandates a real `salesforce-api-context` MCP attempt before
any metadata write. **This agent has no MCP tools and no org access** — its toolset is Read / Write /
Edit / Glob / Grep only, and `.mcp.json` carries only the `salesforce` server (not `salesforce-api-context`).
No metadata is written by this document. Every implementing agent must record its own
`mcp=complete|unavailable` per metadata type before generating files. Where an XML shape could not be
confirmed from repo precedent, it is raised below as a **blocking gate with a dry-run + readback
protocol**, never guessed.

---

# 1. CONTRADICTED / MISSING PREMISES — read before anything else

Each of these was measured against the repo, not inferred. Five of them change the shape of the build.

## C1 🔴 BLOCKING — `objects/Case/**` and `layouts/Case-*` are FORCE-IGNORED. S3 cannot deploy as briefed.

`.forceignore`:
- **line 252** — `force-app/main/default/objects/Case/**` (Bucket B: "standard objects that already
  exist in the org, with ZERO DPEG customization")
- **line 281** — `force-app/main/default/layouts/Case-*`
- line 77 — `entitlementProcesses/standard case.entitlementProcess-meta.xml`
- lines 50–51 — `quickActions/{Guest,New}CommunityCase.quickAction-meta.xml`

Every artefact S3 needs — `Case/recordTypes/Delinquency.recordType-meta.xml`, ~19 `Case/fields/*__c`,
`Case/compactLayouts/`, `Case/listViews/`, and a new `layouts/Case-Delinquency*.layout-meta.xml` —
lands inside a pruned path. **They will be silently dropped from every deploy with zero errors and
zero warnings.**

This repo has already paid for this exact mistake, and the post-mortem is written into `.forceignore`
itself at **lines 220–249** (the `Account/**` narrowing, 2026-08-10). Two facts recorded there are
binding here:

1. A check-only dry-run reported *"no RecordType named Account.Broker_Firm found"* on two
   PermissionSets — which read like unrelated fallout but was the ignore rule. Reproducible with
   Account alone: **"No local changes to deploy" — zero files, zero errors, nothing to fix.**
2. 🔴 **`!`-negation does NOT rescue it.** `objects/Account/**` prunes the *directory node*; per
   gitignore semantics a negation cannot re-include a path under an already-excluded parent. The
   negated files never appeared in the deploy's `files` array **with no error at all**.

⚠ The Bucket B rationale ("ZERO DPEG customization") is *why* Case was ignored — Case was ignored as
boilerplate cleanup, **not** because it failed. That distinguishes it from Bucket A ("does not resolve
to a valid sObject type"). But whether `Case/fields/**`'s 35 retrieved standard fields deploy cleanly
in `usman-dpeg` is **unverified either way** — Case has not been in a deploy since the ignore landed,
and per the repo's own `dryrun-skips-unchanged-components` finding a green dry-run that never
validated a component proves nothing. Suspect entries include `AssetWarrantyId` (`AssetWarranty/**`
is Bucket A — does not resolve), plus the Entitlements block (`EntitlementId`, `ServiceContractId`,
`MilestoneStatus`, `SlaStartDate`, `SlaExitDate`, `IsStopped`, `StopStartDate`, `BusinessHoursId`).

**Prescribed protocol (delegate to `salesforce-devops`, gate the whole of S3 on it):**
1. Delete line 252 (`objects/Case/**`) and line 281 (`layouts/Case-*`).
2. Re-add the four existing Case layouts **by exact filename**, not by glob, so a new layout is not
   pruned: `Case-Case %28Marketing%29 Layout`, `Case-Case %28Sales%29 Layout`,
   `Case-Case %28Support%29 Layout`, `Case-Case Layout` (`.layout-meta.xml`, URL-encoded parens as
   they appear on disk).
3. Run a **check-only dry-run with `objects/Case/**` alone** and read the report's `files` array — not
   the success flag — to confirm the files were actually in the payload.
4. Re-add **only the individually failing** `Case/fields/<Name>.field-meta.xml` entries by exact path,
   exactly as the Account fix ignores `objects/Account/fields/**` and nothing else. Do **not** re-add
   a blanket `Case/**` or `Case/fields/**` — S3 puts custom fields in `Case/fields/`.
5. Only then deploy record type + fields.

## C2 ✅ FAVOURABLE — `standardValueSets/` is NOT ignored, so Case Status/Reason values *are* deployable

`objects/Case/fields/Status.field-meta.xml` and `Reason.field-meta.xml` carry **no `<valueSet>`** —
values for standard picklists on standard objects live in `standardValueSets/CaseStatus` and
`standardValueSets/CaseReason`, and that directory has no `.forceignore` entry. Both files exist and
carry the stock values only (`CaseStatus`: New / Working / Escalated / Closed(closed=true);
`CaseReason`: 7 equipment-support values). `standardValueSets/LeadStatus` was already customised on
this project, so precedent exists.

⚠ **A `StandardValueSet` deploy REPLACES the whole set** — same replace-not-merge hazard as the
PermissionSet `fieldPermissions` incident. Whoever writes these files must include every retained
stock value, and no concurrent build may edit the same two files.

## C3 🔴 BLOCKING — there is **no `Tenant` object**. The FSD's grain key does not exist.

FSD §5.9.3 says *"Tenant, Lease, Property Asset — existing lookups"*. Measured across all 41 custom
objects: **`Tenant__c` does not exist.** Tenant identity today is unstructured free text in three
places — `Unit__c.Tenant_Name__c`, `Lease__c.Tenant_Name__c`, `Delinquency__c.Tenant_Name__c`.

This is not cosmetic. *"One Receivables Summary per tenant per property"*, *"one open Case per
delinquent tenant at a time"* and the entire never-duplicate idempotency guard all key on an identity
that is a string. Two tenants named "Miguelitos" at two properties, or one renamed in Yardi, silently
split or merge. See §2 GATE-1 for the options and the recommendation.

## C4 🔴 `Lease__c` is NOT a Yardi lease mirror — a Lease lookup would point at the wrong thing

`Lease__c` has exactly 7 fields: `Lease_Inquiry__c`, `Stage__c`, `Executed_Date__c`,
`Target_Execution_Date__c`, `Legal_Owner__c`, `Property_Name__c`, `Tenant_Name__c`. It is the
**leasing-pipeline** lease minted from `Lease_Inquiry__c` (FSD Pattern 1, Area 3) — no
`Property_Asset__c` lookup, no unit, no rent, **no Yardi external id**. It is Category B ("built in
Salesforce"), while AR is Category A ("lives in Yardi").

⇒ FSD §5.9.4's "Lease | Lookup" cannot be satisfied by `Lease__c` without asserting a false join.

## C5 ✅ The real per-tenant-per-property grain in this repo already exists: `Unit__c`

`Unit__c` is the Yardi rent-roll mirror and carries everything AR needs to hang from:
`Yardi_Unit_Id__c`, `Property_Asset__c`, `Tenant_Name__c`, `Suite_Number__c`,
**`Current_Monthly_Rent__c`** (the denominator for Months Outstanding), `NNN_Monthly_Total__c`,
`Lease_Start__c` / `Lease_End__c`, `Status__c`. A `UnitSelector` already exists.

## C6 🔴 The brief's "only approval process in the repo" is wrong — there are **seven**

`Opportunity.LOI_Approval`, `Opportunity.Underwriting_Approval`,
`BOV_Submission__c.Broker_Finalize_Approval`, `Disposition__c.Broker_Selection_Approval`,
`Disposition__c.Closing_Approval`, `Disposition__c.Sale_Decision_Approval`,
`Disposition_Offer__c.Offer_Selection_Approval`. `approvalProcesses/` is **not** force-ignored, so a
`Case.Write_Off_Approval` file deploys — but it references Case fields and a Case record type that
live in the pruned tree (C1), so deploy order is load-bearing.

## C7 🔴 `Case` OWD is `ReadWriteTransfer` (public read/write/transfer) — the only DPEG-visible object that is not Private

`objects/Case/Case.object-meta.xml` line 223. The 2026-07-22 RBAC build set 28 objects to Private;
Case was never in scope because it was unused. Two compounding facts:
- **Standard-object OWD is UI-only on this project** (measured in the RBAC build) — it is not
  deployable metadata, so this is a manual Setup change.
- `objects/Case/**` is force-ignored anyway (C1), so even the `sharingModel` line in that file is
  currently fiction.

⇒ **See GATE-5.** Hardening Case to Private is what *creates* the duplicate-Case sharing hazard; the
guard must be written to survive it from day one regardless of whether the hardening happens now.

## C8 🔴 Case is granted to nobody, and `workflows/Case.workflow-meta.xml` already exists

Confirmed: the only `<object>Case</object>` grant in `permissionsets/` is
`sfdcInternalInt__sfdc_scrt2` (itself force-ignored, `.forceignore` line 528). No DPEG permission set
grants Case. **Correction to the brief:** `force-app/main/default/workflows/Case.workflow-meta.xml`
*does* exist — it holds one stock `fieldUpdates` entry (`ChangePriorityToHigh`). Any workflow
`<alerts>` for AR must be **added to that existing file**, which makes it a soft collision surface.
Also already true and useful: `Case.enableFeeds = true`, and `Status` / `Reason` both have
`trackHistory = true`.

## C9 ⚠ Config precedent in this repo is **Hierarchy Custom Setting**, not Custom Metadata

`customMetadata/**` is force-ignored (`.forceignore` line 16 — *"file-based deploy throws
UNKNOWN_EXCEPTION in this org"*), and CMDT records load via `scripts/load-*-defs.apex`. Only two CMDT
types exist (`Transaction_Task_Def__mdt`, `Task_Group_Def__mdt`), both for bulk row-per-task data.

Runtime feature config in this repo is **two Hierarchy Custom Settings**: `SharePoint_Config__c`
(`Site_ID__c`, `Drive_ID__c`, `Parent_Folder_ID__c`, `Is_Enabled__c`) and
`Content_Publication_Budget__c`. Read via `getOrgDefaults()` — **zero SOQL**, which matters inside a
batch. Both deliberately omit `customSettingsVisibility`, and the reason is a recorded incident in
`SharePoint_Config__c.object-meta.xml`:

> declaring `customSettingsVisibility` fails deploy with *"Property 'customSettingsVisibility' not
> valid in version 67.0"* and **cascades into ~30 unrelated-looking "Dependent class is invalid" Apex
> errors** on a full package deploy.

⇒ Not re-opening the user's decision that thresholds are **config, not constants**. Raising only the
*vehicle* — see GATE-4.

## C10 ✅ A `Last_Synced` naming precedent exists (just not in PM)

`Opportunity.CoStar_Last_Synced_DateTime__c`, `Opportunity.Placer_Last_Synced_DateTime__c`,
`Property__c.CoStar_Last_Synced_DateTime__c`, `Property__c.Placer_Last_Synced_DateTime__c`, plus
`lwc/marketDataSync` and `MarketDataSnapshotService`. Convention: **`<Source>_Last_Synced_DateTime__c`**
⇒ `Yardi_Last_Synced_DateTime__c`. (The brief was right that no PM object has one.)

## C11 ⚠ ZERO Apex outbound email exists in this org — FSD §5.9.7 needs three emails

Measured across `force-app/`: `Messaging.sendEmail`, `SingleEmailMessage`, `OrgWideEmailAddress`,
`setTemplateId` appear **nowhere**. The complete first-party outbound-email inventory is one triple:
`email/unfiled$public/Transaction_Opened_Notification`, a workflow `<alerts>` block in
`workflows/Transaction__c.workflow-meta.xml`, and `flows/Transaction_Opened_Notify`.

In-app alerting is `Messaging.CustomNotification` via `GroupNotifier`, used by
`CallForOffersAlertBatch`, `ContractExecutionService`, `DispositionTractionController`,
`NdaExpiryAlertBatch`, `OfferingService` — **and zero PM classes**. ⚠ `GroupNotifier` hardcodes
notification type `Acquisitions_Deal_Update` (line 22), which is the wrong label to surface on a PM
delinquency alert.

🔴 **Recipients:** the established precedent is a **public group**, whose own `<description>` says
*"Group recipient so it survives staffing changes"*. `DPEG_Property_Mgmt_Team` and `Principals` exist
(11 groups total). **`Group` metadata carries no membership** — a group deploys **empty and notifies
nobody, silently** (`GroupNotifier` degrades a no-recipient group to a `System.debug`). See GATE-6.

## C12 The existing 6.1 surface, measured

- `reports/Property_Management/Delinquency_Aging.report-meta.xml` — `reportType`
  `CustomEntity$Delinquency__c`, `format` Summary, groups down on `Delinquency__c.Aging_Bucket__c`,
  sums `Delinquency__c.Balance__c`, `showDetails=false`.
- `dashboards/Property_Management/Property_Management_Overview.dashboard-meta.xml` — **both**
  components point at that one report: the `Delinquent Tenants` **Metric** (line ~89, `column`
  `RowCount`) and the `Delinquency Aging ($ balance)` **Bar** chart (line ~211, `Sum` of `Balance__c`
  grouped by `Aging_Bucket__c`).

⚠ `Property_Management_Overview.dashboard-meta.xml` is a **soft collision surface** with the two
concurrent builds (§6.1 tiles for CAM / Insurance / Renewals live in the same file). Flagging it even
though the brief's hub-file ban did not name it.

## C13 Full `Delinquency__c` reference inventory (for S8)

| # | Reference | File |
|---|---|---|
| 1 | Object + 6 fields | `objects/Delinquency__c/**` (7 files) |
| 2 | Sharing rule granting **Edit** to the whole PM group | `sharingRules/Delinquency__c.sharingRules-meta.xml` (`Delinquency_PM_All_RW`, criteria `Aging_Bucket__c != ''`) |
| 3 | 6 `fieldPermissions` (all `editable=true`) + `objectPermissions` (`allowEdit`, `viewAllRecords=true`) | `permissionsets/DPEG_PropertyMgmt_Edit.permissionset-meta.xml` (~lines 129–158, ~842–846) |
| 4 | object/field permissions | `permissionsets/DPEG_PropertyMgmt_View.permissionset-meta.xml` |
| 5 | Report | `reports/Property_Management/Delinquency_Aging.report-meta.xml` |
| 6 | 2 dashboard components | `dashboards/Property_Management/Property_Management_Overview.dashboard-meta.xml` |
| 7 | **3 factory methods** | `TestDataFactory.cls:3449–3481` (`createDelinquencies` ×2, `createDelinquency`) |
| 8 | 🔴 **Seed script** | `scripts/seed-pm-dashboard.apex:37–44, 66` — 5 rows + a count assertion. **Resurrects the object on every org rebuild.** |
| 9 | Topics | `topicsForObjects/Delinquency__c.topicsForObjects-meta.xml` |
| 10 | Translations | `objectTranslations/Delinquency__c-en_US/` (2 files) |
| 11 | Manifest | `manifest/package.xml` |
| 12 | Search settings (force-ignored ⇒ harmless but stale) | `settings/Search.settings-meta.xml` |
| 13 | **Comment-only** prose | `PropertyAssetService.cls:15`, `PropertyAssetSelector.cls:146` |
| 14 | ERD diagrams | `docs/dpeg-full-application-erd.svg`, `docs/dpeg-application-erd-with-fields.svg` |

Confirmed absent: no `DelinquencySelector`, no trigger, no LWC, no tab, no flow, no validation rule,
no path. `enableHistory=false`, `enableFeeds=false`, `sharingModel=Private`.
⚠ Standing repo rule: **reports do not block field/object deletion — the failure is silent.**

---

# 2. BLOCKING GATES — answer these before any implementation agent is invoked

## GATE-1 🔴 What is a "tenant"? (blocks S2, S3, S5 — the whole idempotency model)

Per C3 there is no Tenant object. Four candidates:

| Option | Grain key | Pros | Cons |
|---|---|---|---|
| **A — key on `Unit__c`** *(recommended)* | `Unit__c` lookup + `Yardi_AR_Id__c` | `Unit__c` is already the Yardi mirror with `Yardi_Unit_Id__c`, `Property_Asset__c`, `Tenant_Name__c` **and `Current_Monthly_Rent__c`** (the Months-Outstanding denominator). Zero new identity concepts. "Per tenant per property" ≡ per occupied unit. | A tenant occupying 2 suites at one property gets 2 rows / 2 Cases. Needs a rollup or a grouped report to see them as one exposure. |
| B — new `Tenant__c` object | `Tenant__c` lookup | Faithful to the FSD wording | A whole new Yardi-mirrored object nobody asked for; needs its own feed, external id, sharing, perms — large unrequested scope |
| C — `Account` + a `Tenant` record type | `Account` lookup | `Account` already carries `Broker_Firm` and `Investor_Entity` record types, so the precedent exists; gives standard Case `AccountId` for free | No tenant Accounts exist today; needs a matching strategy from a Yardi text name; `objects/Account/fields/**` is force-ignored (11 known-broken standard fields) |
| D — external id only, text tenant name | `Yardi_AR_Id__c` | Zero dependencies; whatever Yardi's AR grain is, is the grain | No navigable tenant record; rankings group on a free-text string; §7 role visibility ("their assigned properties") has nothing to hang on |

**Recommendation: A, with the seam for C left open** — build the mirror on `Unit__c` + carry
`Tenant_Name__c` Text(120) + an *optional, nullable* `Account__c` lookup that nothing depends on
today. If tenant Accounts are later created, the sync populates the lookup and no downstream artefact
changes.

⚠ **Do not proceed on assumption** — this decision determines whether `Yardi_AR_Id__c` is one row per
tenant, per unit, or per ledger, and that in turn determines whether "never create a duplicate Case"
is even well-defined.

## GATE-2 🔴 Case lifecycle field: standard `Status` or a custom `Stage__c`?

FSD §5.9.5 lists 7 stages. ARCHITECTURE.md §1 says *"a lifecycle field driving a Path → `Stage__c`"* —
but that convention is written for **custom** objects; Case ships a lifecycle field, and FSD §5.9.2
chose standard Case *precisely* to inherit it.

**Recommendation: use standard `Case.Status`, extended via `standardValueSets/CaseStatus` (C2), and
drive the Path off Status.** A custom `Stage__c` alongside `Status` creates two state fields for one
lifecycle — the exact "derived stage field silently discards writes" / "shared terminal values"
failure class this repo has hit before. It also makes FSD §5.9.6 step 6's auto-close a single write
instead of two that can diverge.

Proposed `CaseStatus` value set (whole set is replaced, so stock values are retained and simply
excluded from the Delinquency record type):

| Value | `closed` | Notes |
|---|---|---|
| New | false | stock, retained, excluded from Delinquency RT |
| Working | false | stock, retained, excluded |
| Escalated | false | stock, retained, excluded |
| Closed | true | stock, retained, excluded |
| Identified | false | default for the Delinquency RT |
| PM Follow-Up | false | |
| Notice Sent | false | |
| Payment Plan Agreed | false | |
| Escalated to Principal | false | |
| Legal / Eviction | false | |
| **Resolved** | **true** | terminal; drives `IsClosed` + `ClosedDate` |

⚠ Memory/repo standing finding: **record-type picklist restriction IS enforced by DML** (measured 4×
on this project, contradicting ~20 in-repo claims that it is UI-only). ⇒ **the record type must be
deployed before any Apex or test that writes these values**, and the seven values must be listed on
the record type or every write fails at DML.

⚠ `Case.Reason` (standard, `standardValueSets/CaseReason`) needs 4 added values —
**Non-payment, Short payment, Billing dispute, Prior-owner balance** — with the same replace-whole-set
caution.

## GATE-3 🔴 `Has_Open_Delinquency_Case` cannot be a formula. The FSD contradicts itself here.

FSD §5.9.4 types it **Formula**, and §5.9.2 says *"the mirror holds no state and is overwritten on
every sync"*. Both cannot hold:
- A formula on `Receivables_Summary__c` can only traverse a lookup **FROM** the mirror. The natural
  direction is Case → mirror, so there is nothing to traverse.
- A roll-up summary needs Case to be a master-detail child of the mirror — it is not, and cannot be
  (Case is standard and already has its own parents).
- A lookup *from* the mirror to the open Case would be workflow state living on the mirror.

**Recommendation — split it in two, and keep them strictly separate:**

1. **The guard** (never-duplicate, FSD §5.9.6 step 3) is a **SOQL read of Case**, executed inside the
   sync, keyed on the denormalised `Case.Yardi_AR_Id__c` + `IsClosed = false`. It **never** reads the
   mirror field.
2. **The display/report projection** is a stored `Has_Open_Delinquency_Case__c` **Checkbox on the
   mirror, written by the sync every run** from the result of (1). This does not violate the mirror
   rule: nothing but the sync ever writes it, it is recomputed from scratch each run, and losing it
   costs nothing because the next run restores it. It is *derived from* workflow, not *holding*
   workflow.

Why (2) is not optional: the §6.1 **Delinquent Tenants** tile must count tenants over the opening
threshold, but the threshold is **config** (user decision 3) and **a report cannot read a Custom
Setting or CMDT**. Filtering the report on `Has_Open_Delinquency_Case__c = true` makes the tile count
*what the job actually decided*, eliminating a second hardcoded copy of the threshold in report XML.

## GATE-4 ⚠ Config vehicle: Hierarchy Custom Setting (repo precedent) vs Custom Metadata (user's stated choice)

Both satisfy "tunable without a deploy". Per C9:

| | Hierarchy Custom Setting | Custom Metadata |
|---|---|---|
| Records deployable? | No — created in Setup / at runtime | No — `customMetadata/**` force-ignored, loaded by `scripts/load-*-defs.apex` |
| Reads inside a batch | `getOrgDefaults()` — **zero SOQL** | SOQL (or the cached `getInstance` API) |
| In-repo precedent | **2** (`SharePoint_Config__c`, `Content_Publication_Budget__c`) | 2, both bulk-row data, not feature toggles |
| Per-user / per-profile override | Yes | No |
| Known deploy trap | `customSettingsVisibility` must be **omitted** at 67.0 (~30 cascading "Dependent class is invalid" errors) | `UNKNOWN_EXCEPTION` on file deploy — loader script required |

**Recommendation: `Receivables_Sync_Config__c` Hierarchy Custom Setting**, mirroring
`SharePoint_Config__c` exactly (including the omitted `customSettingsVisibility` and the explanatory
XML comment). Zero SOQL inside the nightly batch is the deciding factor.
**⚠ Confirm — this diverges from the user's stated "Custom Metadata".** If CMDT is preferred, the
build is still fine, but it inherits the loader-script post-deploy step and a SOQL read per run.

## GATE-5 🔴 The idempotency guard's sharing exposure — address it now, not when Case is hardened

Today `Case` OWD is `ReadWriteTransfer` (C7), so a sharing-filtered read is **not** currently a risk.
That is a trap, not a reprieve: the moment Case is hardened to Private (which §7 role visibility
implies, and which every other DPEG object already did), a sharing-filtered guard read stops
returning other users' open Cases and **inverts the feature into a duplicate-maker** — silently,
because the sync's `Database.upsert(..., false)` swallows it.

This repo has the incident on file: *"an approval's parent write failed silently for every approver
who didn't OWN the record; `SYSTEM_MODE` lifts CRUD/FLS but never sharing, then `allOrNone=false`
swallowed it. Worked only when approver == owner, which is exactly what every test does."*

**Mandated shape (ARCHITECTURE.md §2's prescribed form):**
- `CaseSelector.selectOpenDelinquencyByArKeys(Set<String>)` — `WITH SYSTEM_MODE`, and the SOQL held in
  a **`private without sharing` inner class**, justified at that method's own declaration in the
  class header. Not `without sharing` on the whole selector.
- Same treatment for the `Receivables_Summary__c` upsert locator and for the mirror write (the job's
  own rows will be owned by whichever principal scheduled the job; a change of scheduling principal
  otherwise silently breaks updates on a Private-OWD object).
- **A test that proves it**: create the open Case as user A, run the sync as user B, assert **zero**
  new Cases. Per the repo's `denial-tests-need-minimum-access-profile` finding, user B must be on the
  `Minimum Access` profile with only the intended permission set — a `Standard User`-based test
  proves nothing for a standard object.

## GATE-6 🔴 "Isha", "Nikhil", "Ali" are people, not deployable recipients

FSD §5.9.7 names individuals. Per C11 the repo's answer is a **public group**, and **group membership
is not deployable** — a new group ships empty and notifies nobody with no error.

Decisions needed:
1. Do the 60-day / 90-day alerts go to **`DPEG_Property_Mgmt_Team` + `Principals`** (both exist), or
   is a new narrower group needed (e.g. an AR/finance group for Isha)?
2. Email vs in-app: FSD says **email**. This org has **zero** Apex email and exactly one first-party
   `EmailTemplate`. Options:
   - **(a) recommended** — workflow `<alerts>` added to the **existing** `workflows/Case.workflow-meta.xml`
     + new `EmailTemplate`s + a record-triggered Flow, copying the
     `Transaction_Opened_Notification` triple verbatim (`type=text`, `style=none`, `uiType=Aloha`,
     `encodingKey=UTF-8`, `<recipients><type>group</type>`, `<senderType>CurrentUser</senderType>`).
   - **(b)** in-app only via `GroupNotifier` — cheapest, but does not satisfy "email to Isha", and
     would surface under the `Acquisitions_Deal_Update` notification type (wrong label for PM).
   - **(c)** first Apex email in the org — **not recommended**: deliverability, org-wide-address and
     test-mocking implications, and Apex tests do not actually send, so a send-then-stamp bug cannot
     be falsified the way `GroupNotifier.notifyWithOutcome` allows.
3. Write-off approval approver: `<approver>` accepts a **user or a queue**, not a public group. Only
   two queues exist (`Acquisition`, `Broker_Portal_Leads`) and neither fits. Named user, or a new
   queue (membership again not deployable)?

## GATE-7 ⚠ The third standing direct-callout exception — confirm the ASB endpoint reality

Decision 1 is settled (user-acknowledged). Two sub-questions remain and only the user/ASB team can
answer them:
1. **Does the ASB receivables spoke exist today?** ARCHITECTURE.md §3.4's 🔴 note says every callout
   this app makes is currently *direct* and there are **no ASB-routed implementations**. If the ASB
   receivables endpoint does not exist yet, this is not an exception to §3.1 at all — it is the
   **first conforming implementation of §3.1**, and §3.5 should say so rather than logging a third
   exception. That is a materially better outcome and worth confirming before writing the doc update.
2. **Auth shape.** `SharePoint_Credential` is *deliberately not shipped as metadata* because the
   OAuth External Credential XML shape could not be confirmed at 67.0 and a malformed guess fails at
   token acquisition with an opaque error. **Same risk here, and this agent has no MCP to resolve it
   (see rule-gate status).** ⇒ ship the **Named Credential only**; the External Credential is a
   hand-built Setup step, and the permission set granting principal access will not deploy until it
   exists.

## GATE-8 ⚠ Report-type tokens for Case reports are unverified

Four §6.5 components report on **Case**, and this repo has prior form for report-type token failures
(the `LeadList` token, plus scope/column gotchas). No Case report exists to copy. The implementing
agent must resolve the correct `<reportType>` token empirically (deploy one report, read it back)
before authoring the other three. Also inherit the measured native-report rules: **Metric components
require a Summary-format report; use FlexTable for detail; `<aggregate>` not `a!`/`s!` prefixes;
Average counts blanks as 0.**

---

# 3. WHAT THE USER REQUESTED (scope statement)

Build FSD §5.9 and §6.5 for the PM module, with a **pluggable Yardi ingestion layer** so the real feed
switches on later without a rebuild. Eight sub-scopes S1–S8 as enumerated in the brief. Three
decisions pre-made by the user and **not re-opened**: (1) Salesforce PULLs via scheduled Apex against
ASB, one boundary class; (2) five aging buckets per §5.9.4, with §6.1's three-bucket chart repointed;
(3) opening threshold and staleness tolerance are config, not constants.

Nothing below adds a feature, object, field, validation rule, permission set or test scenario that is
not traceable to §5.9, §6.1, §6.5, §4, UAT AR-001..AR-005, or the brief's S1–S8. Where the FSD is
silent and a value must exist (escalation level, halt semantics), it is **marked `[DESIGNED — NOT
SPECIFIED]`** and listed in §9.

---

# 4. 🔵 ADMIN / DECLARATIVE WORK

> Routing note for the orchestrator: this is **multi-object schema + a security model + a record-type
> lifecycle**, i.e. `salesforce-solution-architect` territory per CLAUDE.md's complexity routing, not
> routine `salesforce-admin`.

## A1 — `.forceignore` surgery (GATE-1 of the build; see C1)
Not "admin work" in the usual sense — assign to `salesforce-devops`. Blocks all of A4/A5/A6/A7/D-Case.

## A2 — `Receivables_Summary__c` (custom object, read-only Yardi mirror)

Object: `sharingModel` **Private**, `externalSharingModel` Private, `enableHistory` **false** (it is
overwritten nightly — history would be noise and volume), `enableFeeds` false, `enableReports` true,
`enableSearch` true, `enableBulkApi` true, `deploymentStatus` Deployed.
`nameField`: AutoNumber, `displayFormat` `RCV-{0000}`, label "Receivables Summary Number".

| # | FSD §5.9.4 field | API name | Type | Notes |
|---|---|---|---|---|
| 1 | Property | `Property_Asset__c` | Lookup(`Property_Asset__c`) | field name = target object name per ARCHITECTURE §1 |
| 2 | Tenant | `Unit__c` | Lookup(`Unit__c`) | **GATE-1 option A**; carries the Yardi grain |
| 3 | Tenant (label) | `Tenant_Name__c` | Text(120) | `_Name__c` suffix — ARCHITECTURE's type-suffix rule explicitly reserves `Tenant__c` for a lookup |
| 4 | Tenant (future) | `Account__c` | Lookup(Account), nullable | GATE-1 seam for option C. Nothing depends on it |
| 5 | Lease | *(omitted)* | — | **C4** — `Lease__c` is the pipeline lease, not the Yardi lease |
| 6 | Monthly Rent | `Monthly_Rent__c` | Currency(16,2) | from feed; fallback = `Unit__c.Current_Monthly_Rent__c` (open question OQ-3) |
| 7 | Total Outstanding | `Total_Outstanding_Amount__c` | Currency(16,2) | `Amount` suffix = total, per ARCHITECTURE currency rule |
| 8 | Base Rent | `Base_Rent_Outstanding_Amount__c` | Currency(16,2) | §5.9.1's core complaint |
| 9 | NNN-CAM | `NNN_CAM_Outstanding_Amount__c` | Currency(16,2) | acronyms fully uppercase |
| 10 | Late Fee | `Late_Fee_Outstanding_Amount__c` | Currency(16,2) | |
| 11 | Other | `Other_Outstanding_Amount__c` | Currency(16,2) | |
| 12 | Current | `Current_Amount__c` | Currency(16,2) | **bucket 1 of 5** (user decision 2) |
| 13 | 1–30 | `Aging_1_30_Amount__c` | Currency(16,2) | digit-leading segments are legal per ARCHITECTURE §1 |
| 14 | 31–60 | `Aging_31_60_Amount__c` | Currency(16,2) | |
| 15 | 61–90 | `Aging_61_90_Amount__c` | Currency(16,2) | |
| 16 | 90+ | `Aging_90_Plus_Amount__c` | Currency(16,2) | |
| 17 | Days Past Due | `Days_Past_Due__c` | Number(4,0) | oldest unpaid item |
| 18 | Months Outstanding | `Months_Outstanding__c` | **Formula(Number, 1)** | `IF(Monthly_Rent__c > 0, Total_Outstanding_Amount__c / Monthly_Rent__c, NULL)` — **must guard ÷0** |
| 19 | Aging Bucket | `Aging_Bucket__c` | **Formula(Text)** | derived label — see the sort-order note below |
| 20 | Responsible PM | `Responsible_Property_Manager__c` | Lookup(User) | role-named User lookup per ARCHITECTURE §1 exception |
| 21 | Has Open Case | `Has_Open_Delinquency_Case__c` | **Checkbox** | **GATE-3** — not a formula. Written by the sync only |
| 22 | Last Synced | `Yardi_Last_Synced_DateTime__c` | DateTime | **C10** naming precedent. Shown on screen per FSD §4 |
| 23 | (key) | `Yardi_AR_Id__c` | Text(80), **externalId + unique**, `caseSensitive=false` | upsert key |
| 24 | (audit) | `Sync_Run__c` | Lookup(`Sync_Run__c`) | which run last wrote this row → per-row staleness is auditable |

**`Aging_Bucket__c` formula** (highest non-zero bucket wins — "how old is the oldest money"):
```
IF(Aging_90_Plus_Amount__c  > 0, "5. 90+ Days",
IF(Aging_61_90_Amount__c    > 0, "4. 61-90 Days",
IF(Aging_31_60_Amount__c    > 0, "3. 31-60 Days",
IF(Aging_1_30_Amount__c     > 0, "2. 1-30 Days",
IF(Current_Amount__c        > 0, "1. Current", "0. None")))))
```
⚠ **The numeric prefixes are load-bearing, not decoration.** A report grouping on a text formula sorts
ASCII-ascending, which puts `"Current"` **last** (digits sort before letters) — the business reads
Current first. Prefixing is the only way to control grouping order without a picklist. **Cost:** the
prefix is visible on the §6.1 and §6.5 charts. Confirm as OQ-5 — the alternative is an
`Aging_Bucket_Rank__c` Number formula, which cannot be the grouping column *and* the label at once.

🔴 **Two aging models will coexist during migration and must not compete** (user decision 2, S8).
`Delinquency__c.Aging_Bucket__c` is a **4-value restricted picklist**; the new field is a **5-value
text formula on a different object**. Same API name, different objects — legal, but during the
coexistence window the name means two things. S8's sequencing (below) is what closes it.

**Note on the two bucket models — they answer different questions and both are required:**
the five Currency fields split **one tenant's balance across buckets**; `Aging_Bucket__c` puts **the
whole tenant in one bucket**. §6.1's existing "Delinquency Aging ($ balance)" bar chart is the
*second* model (Sum of balance grouped by one label per row) and repoints onto `Aging_Bucket__c`.
§6.5's "Aging by bucket" can be either — see R6.

## A3 — `Sync_Run__c` (custom object, one row per ingestion run)

Makes FSD §5.9.6 step 2's *"halt rather than escalate"* **auditable and unit-testable** — the brief's
explicit ask. `sharingModel` Private, `enableHistory` false, `enableFeeds` false, `enableReports` true.
`nameField` AutoNumber `SYNC-{0000}`.

| API name | Type | Notes |
|---|---|---|
| `Source__c` | Picklist (restricted): `Stub`, `ASB` | which provider ran |
| `Provider_Class_Name__c` | Text(80) | the resolved Apex class — proves what actually ran, not what config said |
| `Started_DateTime__c` / `Finished_DateTime__c` | DateTime ×2 | |
| `Status__c` | Picklist (restricted): `Running`, `Completed`, `Halted`, `Failed` | ARCHITECTURE §1: current state → `Status__c` |
| `Halt_Reason__c` | Picklist (restricted): `None`, `Stale Feed`, `Row Count Below Minimum`, `Callout Failure`, `Parse Failure`, `Disabled` | **the assertable value in the health-check tests** |
| `Halt_Detail__c` | Long Text(4000) | |
| `Feed_As_Of_DateTime__c` | DateTime | 🔴 **the feed's OWN timestamp** — staleness is measured against this, never against Salesforce's clock. A feed that is 3 days old but was fetched 2 minutes ago is stale |
| `Row_Count__c`, `Rows_Upserted__c`, `Rows_Failed__c` | Number(9,0) ×3 | |
| `Cases_Opened__c`, `Cases_Closed__c`, `Cases_Escalated__c` | Number(6,0) ×3 | |
| `Lifecycle_Ran__c` | Checkbox | false whenever the health check halted — the single assertion for "no cases created on suspect data" |

## A4 — `Case` — Delinquency record type + custom fields (⚠ blocked on A1)

**Record type** `Case.Delinquency` — `active=true`, `businessProcess` a new `Delinquency Support
Process` listing the 7 §5.9.5 statuses (Identified default → Resolved terminal). ⚠ Case record types
require a **`businessProcess`** (a `<CaseBusinessProcess>`); the org has none today. Deploy order:
StandardValueSet → BusinessProcess → RecordType → fields → layout → Path → Apex.

**Case custom fields** (all under `objects/Case/fields/`):

| API name | Type | Purpose (FSD ref) |
|---|---|---|
| `Receivables_Summary__c` | Lookup(`Receivables_Summary__c`) | the mirror↔workflow join |
| `Property_Asset__c` | Lookup(`Property_Asset__c`) | §6.5 "by property" / §7 visibility |
| `Unit__c` | Lookup(`Unit__c`) | GATE-1 option A |
| `Yardi_AR_Id__c` | Text(80), **externalId, NOT unique** | 🔴 the guard key. **Must not be unique** — closed Cases accumulate over time for the same tenant; a unique index would refuse the second-ever Case for a tenant who re-delinquents. Easy trap |
| `Resolution_Path__c` | Picklist (restricted): `Collect`, `Correct` | §5.9.5 |
| `Escalation_Level__c` | Number(1,0), default 0 | `[DESIGNED — NOT SPECIFIED]`, see below |
| `Escalation_Basis_Days__c` | Number(4,0) | `[DESIGNED]` the re-arm snapshot, see below |
| `Escalated_DateTime__c` | DateTime | |
| `Balance_At_Open_Amount__c` | Currency(16,2) | §5.9.6 step 4 "stamp the balance" · UAT AR-001 |
| `Days_Past_Due_At_Open__c` | Number(4,0) | §5.9.6 step 4 |
| `Current_Balance_Amount__c` | Currency(16,2) | §5.9.6 step 3 "refresh its balance" |
| `Current_Days_Past_Due__c` | Number(4,0) | §5.9.6 step 3 |
| `Next_Follow_Up_Date__c` | Date | §5.9.7 trigger 6 |
| `Last_Follow_Up_DateTime__c` | DateTime | stamped when a CaseComment is added |
| `Days_Since_Last_Follow_Up__c` | Formula(Number, 0) | §6.5 "no follow-up in 7 days" |
| `Dashboard_Flag__c` | Formula(Text) | `Green` / `Amber` (≥60d) / `Red` (≥90d) — §5.9.7 rows 2–3 "amber/red flag on dashboard". Purely derived, zero automation |
| `Write_Off_Requested__c` | Checkbox | §5.9.7 row 7 |
| `Write_Off_Requested_Amount__c` | Currency(16,2) | |
| `Write_Off_Decision__c` | Picklist (restricted): `Pending`, `Approved`, `Rejected` | |
| `Write_Off_Decided_DateTime__c` | DateTime | |
| `Auto_Closed_By_Sync__c` | Checkbox | §5.9.6 step 6 · UAT AR-004 |
| `Reopened_Count__c` | Number(3,0), default 0 | §5.9.7 row 5 |

**🔴 `Escalation_Level__c` + `Escalation_Basis_Days__c` — `[DESIGNED — NOT SPECIFIED]`.**
FSD §5.9.6 step 5 and §5.9.7 *operate on* an escalation level and state it is *"one-way — the level
never drops without a payment"*, but never define it. Designed to mirror the repo's proven
`NdaExpiryAlertBatch` ladder, whose two load-bearing parts are:
- a **monotone** interval marker (`Escalation_Level__c`: 0 none → 1 = 60d → 2 = 90d → 3 = write-off /
  legal), never decremented except on close/payment; **and**
- a **snapshot of the value the marker was computed against** (`Escalation_Basis_Days__c` = the
  `Days_Past_Due` at the time). Without the snapshot, a record whose underlying date is later
  corrected is **never alerted again**. Here that is not hypothetical: Yardi *correcting* aging
  downward (a billing correction, §5.9.5 "Correct" path) is a first-class scenario.

## A5 — `Payment_Commitment__c` (child of Case)

`Case__c` **Master-Detail(Case)** — the field name is the target object's name per ARCHITECTURE §1.
MD (not lookup) because §5.9.2 requires that the Case holds *all* workflow state and the timeline is
never destroyed: MD gives `ControlledByParent` sharing and cascade-delete, and matches how
`DPEG_PropertyMgmt_Edit`'s description already treats *"the 4 ControlledByParent details"*.

| API name | Type |
|---|---|
| `Case__c` | Master-Detail(Case), `reparentableMasterDetail=false` |
| `Commitment_Type__c` | Picklist (restricted): `Promise to Pay`, `Payment Plan Instalment` |
| `Promised_Amount__c` | Currency(16,2) |
| `Due_Date__c` | Date |
| `Status__c` | Picklist (restricted): `Open`, `Kept`, `Breached`, `Cancelled` |
| `Breached_Date__c` | Date |
| `Instalment_Number__c` | Number(3,0) |
| `Breach_Notified__c` | Checkbox — one-way; prevents §5.9.7's "never re-fire the same alert" |
| `Notes__c` | Long Text Area(4000) |

## A6 — `Receivables_Sync_Config__c` (Hierarchy Custom Setting — GATE-4)

Modelled on `SharePoint_Config__c` **exactly**, including the **omitted `customSettingsVisibility`**
and a copy of its explanatory XML comment.

| API name | Type | Purpose |
|---|---|---|
| `Is_Enabled__c` | Checkbox | kill switch. False ⇒ `Sync_Run__c` logged with `Halt_Reason__c = 'Disabled'`, nothing else happens |
| `Provider_Class_Name__c` | Text(80) | the pluggability pivot — `StubReceivablesFeedProvider` today, `AsbReceivablesFeedProvider` later |
| `Staleness_Tolerance_Hours__c` | Number(4,0) | §5.9.6 step 2, measured against `Feed_As_Of_DateTime__c` |
| `Minimum_Row_Count__c` | Number(6,0) | §5.9.6 step 2 "row count abnormal" (lower bound) |
| `Maximum_Row_Count_Change_Pct__c` | Number(3,0) | `[DESIGNED]` — a lower bound alone does not catch a feed that *doubled*. Compared against the previous `Completed` run's `Row_Count__c` |
| `Opening_Threshold_Amount__c` | Currency(16,2) | 🔴 the value the FSD references **five times and never quantifies**. See OQ-1 |
| `Opening_Threshold_Months__c` | Number(3,1) | the *months-of-rent* threshold — §5.9.1 says the team *"calculates and reasons in months of rent rather than days"*. See OQ-1 |
| `Stale_Follow_Up_Days__c` | Number(3,0) | §5.9.7 row 6 / §6.5 "no follow-up in 7 days" (default 7) |

⚠ **Custom Setting DATA is not deployable.** Post-deploy gate: create the org-default row in Setup.
There must be **no hardcoded fallback anywhere in Apex** — if unset, the job logs a `Sync_Run__c` with
`Halt_Reason__c = 'Disabled'` and does nothing. Same discipline as `SharePoint_Config__c`.

## A7 — Declarative surfaces
- **Path** on `Case.Status` scoped to the Delinquency record type, 7 steps.
  ⚠ Repo standing findings: Paths are invisible org-wide unless `pathAssistantEnabled` is on (a
  *master switch*, not a page bug), and **record pages are assigned per-app** — a page assigned by one
  app's `actionOverride` does not exist in the others.
- **Layout** `Case-Delinquency Layout` + `Case/compactLayouts/Delinquency`, assigned to the record
  type. ⚠ Must be authored **after** A1 removes the `layouts/Case-*` glob.
- **List views** on `Receivables_Summary__c` and Case (Delinquency RT) supporting §6.5's "overdue list".
- **Sharing rule** `sharingRules/Receivables_Summary__c.sharingRules-meta.xml` — criteria-based,
  granting **Read** (never Edit) to `DPEG_Property_Mgmt_Team` and `Principals`. This is the
  `Work_Order__c` pattern (read-only Yardi mirror), **not** the `Delinquency__c` pattern.
  🔴 **S8 must also delete `sharingRules/Delinquency__c` (`Delinquency_PM_All_RW`, accessLevel
  `Edit`)** — it, plus `DPEG_PropertyMgmt_Edit`'s Delinquency grants, is what inverts the FSD's
  read-only-mirror rule today.
- **Approval process** `approvalProcesses/Case.Write_Off_Approval.approvalProcess-meta.xml`, copying
  `Disposition__c.Closing_Approval`'s shape (C6 — there are seven to choose from, not one).
  🔴 **`recordLock` must be `false` on every step and on final approval.** If the Case locks while a
  write-off is pending, the nightly sync's step-3 balance refresh is refused for exactly the Cases
  under principal review — and `allOrNone=false` swallows the refusal. This repo built
  `LoiPrimaryStampQueueable` and `DispositionNdaStampQueueable` **only** because their records lock;
  do not import that cost here.
  ⚠ `whenMultipleApprovers` and the `<approver>` type (user vs queue, **not** public group) — GATE-6.
- **`standardValueSets/CaseStatus` + `CaseReason`** — whole-set replacement (C2, GATE-2).
- **Named Credential** `ASB` (Named Credential only; External Credential is a hand-built Setup step —
  GATE-7).
- **StaticResource** `Receivables_Feed_Sample` — JSON fixture powering the stub provider so the entire
  downstream workflow is live and testable today (the brief's central ask).

## A8 — Reports & dashboards (§6.5 + §6.1 repoint)

New reports in `reports/Property_Management/` (all `format` Summary — Metric components require it):

| Id | Report | Object | Shape |
|---|---|---|---|
| R1 | `AR_Total_Outstanding` | Receivables Summary | Sum(`Total_Outstanding_Amount__c`) |
| R2 | `AR_Tenants_Over_2_Months` | Receivables Summary | filter `Months_Outstanding__c >= 2`, RowCount |
| R3 | `AR_Open_Delinquency_Cases` | Case | RT = Delinquency, `IsClosed = false`, RowCount — **GATE-8** |
| R4 | `AR_Cases_Awaiting_Principal` | Case | `Status = 'Escalated to Principal'` AND `Write_Off_Decision__c = 'Pending'` |
| R5 | `AR_Billing_Corrections_Open` | Case | `Resolution_Path__c = 'Correct'` AND `IsClosed = false` |
| R6 | `AR_Aging_By_Bucket` | Receivables Summary | group `Aging_Bucket__c`, Sum(`Total_Outstanding_Amount__c`) — **also serves §6.1** |
| R7 | `AR_Worst_By_Months_Of_Rent` | Receivables Summary | group `Tenant_Name__c`, **Max**(`Months_Outstanding__c`) desc, top 10 |
| R8 | `AR_Worst_By_Dollars` | Receivables Summary | group `Tenant_Name__c`, **Sum**(`Total_Outstanding_Amount__c`) desc, top 10 |
| R9 | `AR_Open_Cases_By_Responsible_PM` | Case | group Owner, RowCount |
| R10 | `AR_No_Follow_Up_7_Days` | Case | `Days_Since_Last_Follow_Up__c >= 7`, `IsClosed = false` |
| R11 | `AR_Delinquent_Tenants` | Receivables Summary | `Has_Open_Delinquency_Case__c = true`, RowCount — **§6.1 tile repoint** (GATE-3: this is why the checkbox must be stored) |

⚠ **R7 and R8 must sit SIDE BY SIDE** — FSD §5.9.9 is explicit that the different ordering *is the
point*. Same row, adjacent `columnIndex`, in `dashboards/Property_Management/Accounts_Receivable.dashboard-meta.xml`.
⚠ R7 uses **Max**, R8 uses **Sum** — a tenant with two units is one exposure in dollars but its worst
months-of-rent, not their sum. Getting this wrong silently inverts the PM ranking.
⚠ Inherit the measured native-report rules (GATE-8): `<aggregate>` not `a!`/`s!`; FlexTable for
detail; **Average counts blanks as 0** (relevant to R7 if any row has null Monthly Rent).

**§6.1 repoint** (`dashboards/Property_Management/Property_Management_Overview.dashboard-meta.xml`):
`Delinquent Tenants` Metric → **R11**; `Delinquency Aging ($ balance)` Bar → **R6** with
`chartSummary.column` = `Receivables_Summary__c.Total_Outstanding_Amount__c` and `groupingColumn` =
`Receivables_Summary__c.Aging_Bucket__c`. ⚠ Soft collision surface — see C12.

---

# 5. 🟢 DEVELOPMENT / APEX WORK

## D1 — S1: the pluggable ingestion layer (the heart of the ask)

```
                    ReceivablesSyncSchedule  (Schedulable, nightly)
                                 │
                                 ▼
        ReceivablesIngestQueueable  (Queueable, Database.AllowsCallouts)
             │ 1. open Sync_Run__c
             │ 2. resolve provider from Receivables_Sync_Config__c
             ▼
        ReceivablesFeedProvider  ◄── interface, the ONE swap point
             ├── StubReceivablesFeedProvider     (StaticResource JSON — TODAY, no callout)
             └── AsbReceivablesFeedProvider      (LATER)
                          │
                          ▼
                 ReceivablesCalloutService   🔴 the ONLY Http.send, the ONLY endpoint constant
                          │
                          ▼  List<ReceivablesFeedDTO>
        ReceivablesSyncService.ingest(List<ReceivablesFeedDTO>, Id syncRunId)
             │ 3. health check → HALT (Lifecycle_Ran__c = false) or continue
             │ 4. upsert mirror on Yardi_AR_Id__c
             ▼
        DelinquencyLifecycleBatch  (chained; steps 3–6 + the date-driven alerts)
```

| Class | Layer | Notes |
|---|---|---|
| `ReceivablesFeedDTO` | DTO | normalized feed row: external id, unit/tenant keys, monthly rent, total, 4 charge splits, 5 buckets, days past due, responsible PM identifier, `feedAsOfDateTime`. **Source-agnostic by construction** |
| `ReceivablesFeedResult` | DTO | `List<ReceivablesFeedDTO> rows` + `DateTime feedAsOf` + `String providerName` — the health check needs the feed's own clock (A3) |
| `ReceivablesFeedProvider` | interface | `ReceivablesFeedResult fetch(ReceivablesFeedRequest req);` |
| `StubReceivablesFeedProvider` | provider | reads StaticResource `Receivables_Feed_Sample`. **Zero callouts** ⇒ the whole of S5/S6/S7 is live and testable before ASB exists |
| `AsbReceivablesFeedProvider` | provider | thin — delegates to the callout service, maps JSON → DTO |
| `ReceivablesCalloutService` | service | 🔴 **the single `Http.send` and the single endpoint constant** (`private static final String BASE = 'callout:ASB'`). Retiring the exception is a one-line change. Mockable via `HttpCalloutMock` |
| `ReceivablesCalloutMock` | test util | mirrors `SharePointCalloutMock` / `LLMExtractionCalloutMock` |
| `ReceivablesSyncService` | service | 🔴 **the single ingest entry point.** Health check + upsert. Every provider funnels here ⇒ swapping the source touches nothing downstream |
| `DelinquencyCaseService` | service | §5.9.6 steps 3–6 + §5.9.7 triggers. Cross-object orchestration |
| `PaymentCommitmentService` | service | breach + missed-instalment + reopen |
| `ReceivablesSummarySelector` | selector | mixed modes; **read the method, not the class** (ARCHITECTURE §2) |
| `CaseSelector` | selector | **NEW** — no Case selector exists. Holds the idempotency guard (GATE-5) |
| `SyncRunSelector` | selector | previous `Completed` run (for the row-count-change check) |
| `PaymentCommitmentSelector` | selector | due/breached commitments |
| `ReceivablesSyncSchedule` | schedulable | copy `NdaExpiryAlertSchedule` / `DealFolderSweepSchedule` |
| `ReceivablesIngestQueueable` | queueable | `Database.AllowsCallouts`. ⚠ **a Queueable runs as the ENQUEUING user** (measured live on `DealFolderQueueable`) ⇒ per-user credential principal access applies to the *scheduling* principal |
| `DelinquencyLifecycleBatch` | batch | `Database.Batchable` + `Database.Stateful`. **No callouts** — the feed is already landed, so `SCOPE = 200` (contrast `DealFolderSweepBatch`'s `SCOPE = 10`, which is a *callout budget*, not a throughput knob) |
| `CaseTrigger` + `CaseTriggerHandler` | trigger/handler | `Last_Follow_Up_DateTime__c` stamping, write-off gating. ⚠ **check first whether a `CaseTrigger` already exists in the org** — the repo has none, but the org is not source-tracked |
| `CaseCommentTrigger` + handler | trigger/handler | stamps `Last_Follow_Up_DateTime__c` on the parent (§5.9.7 row 6 / UAT AR-002) |
| `PaymentCommitmentTrigger` + handler | trigger/handler | one trigger per object; `.trigger` is one line: `new PaymentCommitmentTriggerHandler().run();` |

### D1 non-negotiables

- **`Type.forName(config.Provider_Class_Name__c).newInstance()`** is the swap. ⚠ A class referenced
  only by a config string can be **deleted without a compile error**. Mitigation: a test that asserts
  every shipped provider name resolves to a non-null `ReceivablesFeedProvider`, plus a hard fallback —
  unresolvable name ⇒ `Sync_Run__c` `Halt_Reason__c = 'Disabled'`, `Lifecycle_Ran__c = false`, **never
  a silent fallback to the stub in production**.
- **All SOQL in selectors** (`.claude/rules/apex-layering-rule.md`). Batch `start()` delegates to a
  selector locator, exactly as `DealFolderSweepBatch.start()` delegates to
  `PropertySelector.queryFolderSweep()`.
- **`WITH SYSTEM_MODE` on every automation-path read**, justified **per method** in the selector's
  class header. `USER_MODE` throws (`No such column`) rather than degrading, and Metadata-API-deployed
  fields arrive with **no FLS for anyone, System Administrator included**.
- **`SYSTEM_MODE` does not lift sharing.** GATE-5's `private without sharing` inner classes for the
  guard read, the mirror upsert locator and the mirror write.
- **Domain purity** — zero SOQL/DML in any domain class; services pass collections in.
- **Callouts mockable via `HttpCalloutMock`** — one class owns the boundary.

## D2 — S5: the nightly lifecycle, all six FSD §5.9.6 steps

| Step | Implementation | The assertable fact |
|---|---|---|
| 1. Load | `ReceivablesSyncService.ingest` → `Database.upsert(rows, Receivables_Summary__c.Yardi_AR_Id__c, false)` | `Rows_Upserted__c` + `Rows_Failed__c`. ⚠ `allOrNone = false` means **partial failure is silent** — the failure list must be captured into `Halt_Detail__c`, not discarded |
| 2. Health check | before **any** Case work: `Feed_As_Of_DateTime__c` older than `Staleness_Tolerance_Hours__c`; `Row_Count__c` below `Minimum_Row_Count__c`; row count deviating from the previous `Completed` run by more than `Maximum_Row_Count_Change_Pct__c` | 🔴 `Status__c = 'Halted'`, `Halt_Reason__c` set, **`Lifecycle_Ran__c = false`, and zero Cases created or escalated**. This single boolean is the whole test surface for §5.9.6's first safety rule |
| 3. Case check | `CaseSelector.selectOpenDelinquencyByArKeys()` (**GATE-5** shape). Refresh `Current_Balance_Amount__c` / `Current_Days_Past_Due__c`, re-evaluate the bucket, check commitments | **never a duplicate** — assert 0 new Cases when an open Case exists, *including when it is owned by someone else* |
| 4. Open | no open Case **and** balance crosses `Opening_Threshold_Amount__c` **or** `Months_Outstanding__c` crosses `Opening_Threshold_Months__c` (OQ-1). Create Case: RT Delinquency, `Status = 'Identified'`, `OwnerId = Responsible_Property_Manager__c`, stamp `Balance_At_Open_Amount__c` + `Days_Past_Due_At_Open__c`, derive `Resolution_Path__c` from `Reason` per §5.9.5 | **UAT AR-001** |
| 5. Escalate | `Escalation_Level__c` raised **only upward**, `Escalation_Basis_Days__c` snapshotted, alert sent **once**. Send first, stamp second (the `NdaExpiryAlertBatch` ordering) | **UAT AR-003** + "never re-fires" |
| 6. Close | balance cleared ⇒ `Status = 'Resolved'`, `Auto_Closed_By_Sync__c = true`. **Comments, commitments and field history are untouched** | **UAT AR-004** "full history retained" |

🔴 **Invariant that must be enforced in code, not just documented:** the sync **never writes any Case
field other than** the refresh/stamp/escalation/close fields above, and **never writes a CaseComment
away**. FSD §5.9.2: *"a failed or partial sync can never destroy follow-up history."*

## D3 — S6: the eight §5.9.7 triggers

| # | Trigger | Venue | Notes |
|---|---|---|---|
| 1 | crosses opening threshold | `DelinquencyLifecycleBatch` step 4 | |
| 2 | 60 days past due | step 5, level 0→1 | email → GATE-6 |
| 3 | 90 days past due | step 5, level 1→2 | email to **two** recipients → GATE-6 |
| 4 | promise-to-pay date passes unpaid | `PaymentCommitmentService`, same nightly batch | `Status__c = 'Breached'`, `Breach_Notified__c` one-way. **UAT AR-005** |
| 5 | instalment missed | `PaymentCommitmentService` | flags the commitment **and reopens a Resolved Case**, `Reopened_Count__c`++ |
| 6 | next-follow-up date passes with no comment | same nightly batch | uses `Last_Follow_Up_DateTime__c` (stamped by `CaseCommentTrigger`) + `Stale_Follow_Up_Days__c` |
| 7 | write-off requested | `Case.Write_Off_Approval` | Case **held at Escalated to Principal until decided** |
| 8 | balance clears | step 6 | |

⚠ Triggers 4 and 6 are date-driven, not feed-driven. **Fold them into `DelinquencyLifecycleBatch`
rather than adding a third schedulable** — FSD §5.9.6 describes one nightly job, and a second
scheduler is unrequested scope plus a second thing to fail to schedule.

🔴 **Write-off approval + approval-triggered Apex.** If any post-approval action runs Apex, the flow
must carry `<runInMode>SystemModeWithoutSharing</runInMode>` **AND** state `AccessLevel.SYSTEM_MODE`
at the DML. Both, not either — `MarketDataSnapshotService`'s header records that `runInMode` alone
*did not* lift the access mode and the stamp **silently wrote nothing**. Without this, an
approval-triggered write hits the read-only approver's CRUD, throws `System.TypeException` (which is
**not** a `DmlException` and escapes a narrow catch), and **rolls back the approval so Nikhil cannot
approve at all**. Prefer pure declarative field updates where possible; if Apex is needed, catch
`Exception`, not `DmlException`.

## D4 — Testing

Per `.claude/rules/bulk-test-rule.md`:
- `DelinquencyLifecycleBatch`, `ReceivablesSyncService.ingest`, and every trigger handler: **251+
  records**, assertion counts matching 251. At `SCOPE = 200`, 251 forces a second chunk — which is the
  entire point.
- ⚠ `.claude/rules/content-publication-rule.md` does **not** apply — no `ContentVersion` /
  `ContentNote` / `ContentDocument` anywhere in this feature.
- **No `@isTest(SeeAllData=true)`.** All fixtures via `TestDataFactory` — add
  `createReceivablesSummaries`, `createDelinquencyCases`, `createPaymentCommitments`,
  `createSyncRuns`, and **remove** the three `createDelinquencies*` methods in S8.
- Callouts mocked via `ReceivablesCalloutMock implements HttpCalloutMock`.
- **Coverage target 90%+ per class.** ⚠ Repo standing finding: a deploy can report *"689/689
  deployed, 0 errors"* and still roll back everything — `RunSpecifiedTests` fails on per-class 75%
  coverage via `codeCoverageWarnings` that **no error counter shows**.
- ⚠ Repo standing finding: `sf apex run test --tests` executes **the org's copy** of a class. Always
  include the test class in the deploy payload.

**Named tests the FSD's own safety rules demand:**

| Test | Proves |
|---|---|
| `haltOnStaleFeedCreatesNoCases` | §5.9.6 step 2 — `Lifecycle_Ran__c = false`, `Halt_Reason__c = 'Stale Feed'`, **Case count unchanged** |
| `haltOnRowCountBelowMinimum` / `haltOnRowCountCollapse` | the two abnormal-row-count arms |
| 🔴 `guardSeesCaseOwnedByAnotherUser` | **GATE-5** — open Case owned by user A, sync runs as user B (on **`Minimum Access`**, not `Standard User`), **zero** new Cases |
| `escalationNeverDrops` | one-way ladder |
| `escalationDoesNotRefireOnSecondRun` | §5.9.7's "send the alert once" |
| `escalationRearmsWhenYardiCorrectsAgingDownward` | the `Escalation_Basis_Days__c` snapshot's whole reason for existing |
| `autoCloseRetainsCommentsAndCommitments` | UAT AR-004 · §5.9.2 |
| `syncNeverOverwritesCaseComments` | §5.9.2's guiding rule · UAT AR-002 |
| `everyConfiguredProviderNameResolves` | the `Type.forName` deletion hazard |
| `stubProviderDrivesFullLifecycleWithNoCallout` | the brief's central claim — the workflow is live today |
| `unresolvableProviderHaltsAndDoesNotFallBackToStub` | no silent production fallback |
| `caseYardiArIdAllowsASecondCaseAfterTheFirstResolves` | the not-unique external id (a re-delinquenting tenant) |

## D5 — S1 optional: an inbound `@RestResource`

**Recommendation: DEFER, but leave the seam explicitly named.** Do not build it now.
- The value is already banked by the architecture: `ReceivablesSyncService.ingest(List<ReceivablesFeedDTO>, Id)`
  is **source-agnostic by construction**, so a future push adapter is *one new thin class* calling the
  identical entry point — zero downstream change. That is the cheap insurance the brief was after,
  and it costs nothing to have.
- The cost of building it now is real and unrequested: an integration user, an `apexClass` grant in a
  permission set (**a hub file this build is banned from editing**), a security review of an
  externally-reachable endpoint, and its own auth story — none of which §5.9 asks for, and all of
  which are wasted if ASB never pushes.
- ⇒ Record the seam in the `ReceivablesSyncService` class header as a named future entry point.

---

# 6. S8 — `Delinquency__c` MIGRATION (decision + justification)

## Decision: **RETIRE `Delinquency__c`. Do not rename or repurpose it.**

Four independent reasons:

1. **An API-name rename is a delete + create** on this platform, and a deleted field/object name stays
   *reserved* until erased. There is no cheap rename to be had.
2. **Its permission model is the inverse of the FSD's rule.** `DPEG_PropertyMgmt_Edit` grants
   `allowEdit` + all six fields `editable=true`, and `sharingRules/Delinquency__c` grants **Edit** to
   the whole PM group. Compare `Work_Order__c` — the same permission set's own `<description>`
   records that it is *"deliberately excluded (Yardi read-only mirror)"*. Keeping the object means
   inheriting and then having to un-invert that. **A read-only mirror should never have been Edit.**
3. **Its aging model is structurally incompatible.** 4 restricted picklist values vs 5 currency
   buckets + a derived label. There is no additive path from one to the other.
4. **Its grain is unknown** and its 6 fields express none of the §5.9.1 pain: no charge-type split, no
   monthly rent, no months outstanding, no responsible PM, no last-synced.

Only **3 live consumers** (1 report, 2 dashboard components), all of which are being rebuilt anyway.

## The additive retirement sequence (add → backfill → repoint → retire)

⚠ **Reports do not block object/field deletion — the failure is silent.** Sequence is the only control.

| # | Step | Files |
|---|---|---|
| 1 | Build `Receivables_Summary__c` + all fields (A2) | new |
| 2 | Land data via the **stub provider** (this is the "backfill" — Yardi is the system of record, so there is no historical `Delinquency__c` data worth migrating; it is all seeded) | `StubReceivablesFeedProvider`, StaticResource |
| 3 | Author R6 + R11 | `reports/Property_Management/AR_Aging_By_Bucket`, `AR_Delinquent_Tenants` |
| 4 | **Repoint** the 2 §6.1 dashboard components | `dashboards/Property_Management/Property_Management_Overview.dashboard-meta.xml` ⚠ C12 collision |
| 5 | Delete the old report | `reports/Property_Management/Delinquency_Aging.report-meta.xml` |
| 6 | 🔴 Strip the **seed script** — the thing that resurrects the object on every org rebuild | `scripts/seed-pm-dashboard.apex` lines **37–44** (delete + 5 inserts) and line **66** (count assertion). Replace with a `Receivables_Summary__c` seed |
| 7 | Remove **3 factory methods** | `TestDataFactory.cls:3449–3481` |
| 8 | Remove permission-set entries | **HUB REQUEST H4** — this build must not edit permission sets |
| 9 | Delete sharing rule | `sharingRules/Delinquency__c.sharingRules-meta.xml` |
| 10 | Delete object + fields | `objects/Delinquency__c/**` (7 files) |
| 11 | Delete companions | `topicsForObjects/Delinquency__c...`, `objectTranslations/Delinquency__c-en_US/` (2 files) |
| 12 | Update manifest | `manifest/package.xml` |
| 13 | Update comment-only prose | `PropertyAssetService.cls:15`, `PropertyAssetSelector.cls:146` |
| 14 | Regenerate ERDs | `docs/dpeg-full-application-erd.svg`, `docs/dpeg-application-erd-with-fields.svg` |
| — | *(no action)* | `settings/Search.settings-meta.xml` — force-ignored, never deploys; stale but harmless |

⚠ Standing repo rule: **grep the repo AND query the org before removing any picklist value** (the
object retirement subsumes this). And a `retrieve` **unions** local and remote picklist values, so a
post-retirement retrieve appears to restore the removed values — verify via REST describe, never via
retrieve.

⚠ **Deletion via source deploy requires a `destructiveChanges.xml`** — `sf project deploy start` does
not delete by file removal alone. Assign to `salesforce-devops`.

---

# 7. 🔗 EXECUTION ORDER

```
PHASE 0 — GATES (no code)
  GATE-1 tenant grain · GATE-2 Status vs Stage · GATE-3 Has_Open_Case
  GATE-4 config vehicle · GATE-6 recipients + approver · GATE-7 ASB reality
        │  (GATE-5 and GATE-8 are resolved DURING build, by protocol, not by decision)
        ▼
PHASE 1 — .forceignore surgery (C1)          → salesforce-devops
  dry-run Case alone · read the `files` array · re-add only what actually fails
        │   🔴 BLOCKS every Case artefact
        ▼
PHASE 2 — Custom objects + config             → salesforce-solution-architect
  Receivables_Summary__c · Sync_Run__c · Payment_Commitment__c
  Receivables_Sync_Config__c · Named Credential ASB · StaticResource
        │
        ▼
PHASE 3 — Case schema (order is mandatory)    → salesforce-solution-architect
  standardValueSets/CaseStatus + CaseReason
    → CaseBusinessProcess → Case.Delinquency RecordType
      → Case custom fields → layout + compactLayout → Path
  🔴 RecordType BEFORE any Apex/test that writes a Status value — restricted
     picklists ARE enforced by DML (measured 4× on this project)
        │
        ▼
PHASE 4 — Apex (S1 + S5 + S6)                 → salesforce-technical-architect
  DTO → interface → Stub provider → CalloutService → Asb provider
    → Selectors → Services → Batch/Queueable/Schedulable → Triggers/Handlers
  (technical-architect, not developer: this is a new external integration boundary
   + a third §3.x exception + LDV-shaped nightly batch)
        │
        ▼
PHASE 5 — Tests                               → salesforce-unit-testing
        ▼
PHASE 6 — Sharing rule + approval process     → salesforce-solution-architect
  sharingRules/Receivables_Summary__c · Case.Write_Off_Approval (recordLock=false)
  workflow <alerts> INTO the existing workflows/Case.workflow-meta.xml + EmailTemplates + Flow
        ▼
PHASE 7 — Reports + AR dashboard (R1..R11, §6.5)
  ⚠ resolve the Case report-type token on ONE report first (GATE-8)
        ▼
PHASE 8 — §6.1 repoint + S8 retirement (steps 1–14 above, IN ORDER)
        ▼
PHASE 9 — HUB FILE CONSOLIDATION (main agent, all three builds in one pass)
        ▼
PHASE 10 — POST-DEPLOY GATES (§8)
```

---

# 8. 🔴 HUB FILE REQUESTS — for the main agent's single consolidation pass

**This build writes NOTHING to `applications/`, `permissionsets/`, or `tabs/`.**
⚠ A PermissionSet deploy **replaces its entire `fieldPermissions` set** — concurrent edits silently
lose each other's fields. All three builds must be merged in one pass.

## H1 — New tabs required (`tabs/`)
| Tab | Type |
|---|---|
| `Receivables_Summary__c` | custom object tab |
| `standard-Case` | standard tab (**no new file** — app nav entry + permission-set `tabVisibility` only) |
| `AR_Dashboard` | web/`CustomObject`-less dashboard tab, mirroring `Property_Management_Dashboard` |
| *(none)* for `Sync_Run__c` / `Payment_Commitment__c` | Sync Run is admin-only (reachable via Setup/reports); Payment Commitment is a related list on Case |

## H2 — `applications/Property_Management.app-meta.xml` nav additions
Current `<tabs>` (lines 80–90): `Onboarding`, `Broker_Assignments`, `Lease_Activity_Tracker`,
`Lease_Renewals`, `Onboarding__c`, `Broker_Assignment__c`, `Lease_Inquiry__c`, `Lease_Renewal__c`,
`Property_Management_Dashboard`, `Leasing_Dashboard`, `Work_Order_Dashboard`.

**Add:** `Receivables_Summary__c`, `standard-Case`, `AR_Dashboard`.
⚠ Repo standing finding: **record pages are assigned per-app** via `actionOverride`. If the Case
Delinquency record page is to carry the Path, the override must be added **in this app file** — the
same record opens on the object default page (which has **no** Path component) in every other app.

## H3 — `permissionsets/DPEG_PropertyMgmt_View` — object + field permissions to ADD

| Object | Object perms | Field perms |
|---|---|---|
| `Receivables_Summary__c` | `allowRead` ✅, `viewAllRecords` ✅ · **`allowCreate` / `allowEdit` / `allowDelete` ALL FALSE** | **all 24 fields `readable=true`, `editable=false`** 🔴 |
| `Case` | `allowRead` ✅, `allowEdit` ✅ (PMs work their own cases), `allowCreate` ✅, `allowDelete` ❌ | all 22 custom fields readable; editable on the workflow ones only |
| `Payment_Commitment__c` | `allowRead`/`allowCreate`/`allowEdit` ✅, `allowDelete` ❌ · **no `viewAllRecords`** (ControlledByParent detail — matches this set's own stated rule) | all readable + editable |
| `Sync_Run__c` | `allowRead` ✅, `viewAllRecords` ✅, everything else ❌ | all readable, none editable |

Also: `recordTypeVisibilities` for `Case.Delinquency`; `tabSettings` Visible for H1's tabs;
`classAccesses` for any `@AuraEnabled` controller.

## H4 — `permissionsets/DPEG_PropertyMgmt_Edit` — **REMOVE** the Delinquency inversion
Delete the 6 `fieldPermissions` blocks (~lines 129–158) **and** the `objectPermissions` block
(~lines 842–846, `allowEdit` + `viewAllRecords=true`) for `Delinquency__c` (S8 step 8).
🔴 **Do NOT add `Receivables_Summary__c` to this set.** The read-only mirror belongs in `..._View`
only — this is exactly how `Work_Order__c` is already handled, and this set's own `<description>`
records that reasoning.
Also update the description: "the 13 editable PM objects" → 12 (Delinquency retired), and add Case +
Payment Commitment to the editable list if PM edit rights are granted here rather than in `_View`.

## H5 — Integration/automation principal grants (⚠ may need a NEW permission set)
The nightly job runs **as a user**. That principal needs:
- Create/Edit on `Receivables_Summary__c` and `Sync_Run__c` — **but the mirror must be read-only to
  humans**, so this cannot go in a PM persona set.
- Create/Edit on `Case`, `CaseComment`, `Payment_Commitment__c`.
- `classAccesses` on the schedulable/queueable/batch/service classes.
- **External Credential principal access** for the ASB callout (GATE-7).
⇒ **Recommend a new `DPEG_Receivables_Integration_Access` permission set**, mirroring
`SharePoint_Integration_Access`. Flagged here rather than authored, per the hub-file ban.
⚠ Precedent warning: `SharePoint_Integration_Access` was granted to **one PSG only**, and the result
was that *an entire ordinary persona's callouts were silently refused*. Decide the assignment
deliberately, not by default.

## H6 — Not a hub file, but a soft collision
`dashboards/Property_Management/Property_Management_Overview.dashboard-meta.xml` (§6.1 repoint) —
the CAM/Insurance/Renewal builds live in the same file. Merge in the same pass. Diff against `HEAD`
before deploying (measured 2026-08-16: a second session's work silently unioned into shared files).

---

# 9. ARCHITECTURE.md UPDATE — §3.5 (draft, pending GATE-7)

⚠ **Two variants. Pick after GATE-7 answers whether the ASB receivables spoke exists.**

**Variant A — the spoke exists (preferred outcome; this is NOT a §3.x exception at all):**
> Add to §3.1: *"The Yardi receivables/delinquency feed (FSD §5.9) is the first ASB-routed
> integration in this application. Salesforce PULLs nightly via `ReceivablesCalloutService` against
> the `ASB` Named Credential; Yardi credentials remain in ASB's secrets vault, per §3.1. This does
> **not** consume the §3.4 exception budget."*
> Then amend §3.4's 🔴 note: *"Every external callout this application makes is currently direct"* is
> **no longer true** and must be corrected.

**Variant B — no spoke yet (a genuine third exception, user-acknowledged):**

> ### 3.5 Standing exception — direct Yardi receivables pull (AR & Delinquency)
>
> FSD §5.9's nightly receivables sync calls the receivables feed **directly** via the `ASB` Named
> Credential, bypassing §3.1. 🔴 **This is the THIRD standing exception and was explicitly
> acknowledged by the user**, as §3.3 and §3.4 each were. Per §3.4's own review threshold, its
> existence is evidence that §3.1 and the reality need reconciling — not a precedent for a fourth.
>
> Scoped and reversible on the same terms as §3.3 and §3.4: **one class owns the boundary** —
> `ReceivablesCalloutService`, which holds the single `Http.send` and the single endpoint constant
> (`private static final String BASE = 'callout:ASB'`). Every path segment is composed there from
> parameters. **Do not build a receivables URL anywhere else.**
>
> This exception is narrower than the other two, and deliberately so. The callout is reached only via
> `ReceivablesFeedProvider`, an interface with two implementations
> (`StubReceivablesFeedProvider`, `AsbReceivablesFeedProvider`) selected at runtime from
> `Receivables_Sync_Config__c.Provider_Class_Name__c`. **Every provider funnels into the single
> `ReceivablesSyncService.ingest(...)` entry point, so the entire §5.9 workflow runs today against a
> StaticResource fixture with no callout at all, and switching to the real feed is a config change —
> not a rebuild.** Retiring the exception is: change the constant, change the credential, change the
> config value. The `fetch(...)` signature and every caller stay identical.
>
> ⚠ Same shape-risk as §3.4: the External Credential is **not** shipped as metadata (the OAuth XML
> shape is unconfirmed at 67.0 and a malformed guess fails at token acquisition with an opaque
> error). It is created by hand in Setup; only the Named Credential and
> `DPEG_Receivables_Integration_Access` deploy, and that permission set will not deploy until the
> hand-built credential exists.

Also update **§1** (new objects + the `_Amount__c` / bucket / `Yardi_Last_Synced_DateTime__c`
conventions) and **§2** (the new selectors' SYSTEM_MODE + `private without sharing` justifications) in
the same PR, per CLAUDE.md's standing rule.

---

# 10. POST-DEPLOY GATES (none of these are deployable — each fails silently)

| # | Gate | Silent failure if skipped |
|---|---|---|
| 1 | **Schedule `ReceivablesSyncSchedule`** | Nothing ever runs. No error. Rows sit in a state that reads as tracked. *(`DealFolderSweepSchedule`'s header calls this out as a verified gate for exactly this reason.)* |
| 2 | **Create the `Receivables_Sync_Config__c` org-default row** with `Is_Enabled__c = true` | Every run logs `Halt_Reason__c = 'Disabled'` and does nothing — by design, but it looks like a bug |
| 3 | **Populate public-group membership** (GATE-6) | 🔴 A group deploys **empty** and notifies **nobody, silently** |
| 4 | **Create the ASB External Credential by hand** + grant principal access | Callouts refused. `DPEG_Receivables_Integration_Access` will not deploy until it exists |
| 5 | **Assign permission sets to the running user** | Repo standing finding: *"RunLocalTests fails with ~500 field-access errors" = perm sets not ASSIGNED* |
| 6 | **`pathAssistantEnabled`** master switch | Paths invisible **org-wide** — a master switch, not a page bug; scratch rebuilds lose it |
| 7 | **Case OWD → Private** (C7), if adopted | Standard-object OWD is **UI-only** on this project — not deployable. And GATE-5's guard must already be sharing-proof before this flips |
| 8 | **Verify the record page is assigned in the PM app** | Assigned per-app; the Case opens on the object default page (no Path) elsewhere |
| 9 | **Read back the `.forceignore` fix** by inspecting a dry-run's `files` array | The whole of C1 |

---

# 11. OPEN QUESTIONS

| # | Question | Why it matters | Blocks |
|---|---|---|---|
| **OQ-1** | 🔴 **What IS the opening threshold?** A dollar amount, a months-of-rent figure, or both (OR / AND)? | The FSD references it **five times and never quantifies it**. Both config fields are designed; the *combination rule* is code, not config | S5 step 4 |
| **OQ-2** | Staleness tolerance (hours) and minimum expected row count — starting values? | Defaults must be *some* number; a wrong one either halts every night or never halts | A6 default row |
| **OQ-3** | Does the Yardi feed supply **Monthly Rent**, or is it read from `Unit__c.Current_Monthly_Rent__c`? | `Months_Outstanding__c` — "the metric the business uses" — is meaningless without it, and a null denominator makes the whole PM ranking (R7) blank | A2 field 6, R7 |
| **OQ-4** | How is **Responsible Property Manager** derived? Yardi field, `Property_Asset__c` owner, or a new mapping? | FSD calls it "Nikhil's accountability ask" and §6.5 ranks by it — but nothing in the repo maps a property to a PM today | S5 step 4, R9 |
| **OQ-5** | Numeric prefixes on the aging-bucket labels ("1. Current") — acceptable on the dashboard? | It is the only way to control report grouping order on a text formula; the alternative shows Current **last** | A2 field 19, R6 |
| **OQ-6** | Is a **Case Delinquency LWC** wanted (commitments + comment composer + last-synced banner)? | FSD §4 requires last-synced "shown on screen"; a layout field satisfies that. **Not designing one — no requirement asks for it.** Raising only because the §5.9 UX is comment-heavy | — |
| **OQ-7** | Retention: how long do resolved Delinquency Cases and their `Sync_Run__c` rows live? | `Sync_Run__c` grows one row per night indefinitely; nothing prunes it | — |
| **OQ-8** | Does the feed page? If yes, expected volume and page size? | Determines whether one callout per run is enough and whether the batch's `SCOPE = 200` holds | D1 |
| **OQ-9** | §5.9.5's Case Reason → Resolution Path mapping is 4 values. What sets **Reason** on an auto-created Case? | The sync creates the Case; if Yardi does not supply a reason, every auto-Case defaults to Non-payment → **Collect**, which is precisely the "pursuing tenants for charges DPEG should not have billed" failure §5.9.5 exists to prevent | S5 step 4 |
| **OQ-10** | Is `Delinquency__c` referenced anywhere **in the org** but not in source (a manual report, list view, or a Setup-built flow)? | The repo sweep cannot see org-only artefacts, and reports do **not** block deletion — they break silently | S8 |

---

# 12. 📝 PROMPTS FOR SPECIALIST AGENTS

> ⚠ Do not dispatch any of these until §2's gates are answered. GATE-1, GATE-2, GATE-3, GATE-4,
> GATE-6 and GATE-7 each change what gets built.

## 🔴 PROMPT FOR `salesforce-devops` — PHASE 1 (blocks everything Case-related)

```
Fix .forceignore so Case metadata can deploy. Do NOT create any Case metadata yourself.

1. Read .forceignore lines 220-249 first — the Account/** narrowing post-mortem. It records
   TWO failed attempts and why `!`-negation cannot rescue a path under a `dir/**` ignore.
   The same reasoning governs this change.
2. Remove line 252 `force-app/main/default/objects/Case/**`.
3. Remove line 281 `force-app/main/default/layouts/Case-*` and replace it with the four
   EXACT existing filenames so a NEW Case layout is not pruned:
     force-app/main/default/layouts/Case-Case %28Marketing%29 Layout.layout-meta.xml
     force-app/main/default/layouts/Case-Case %28Sales%29 Layout.layout-meta.xml
     force-app/main/default/layouts/Case-Case %28Support%29 Layout.layout-meta.xml
     force-app/main/default/layouts/Case-Case Layout.layout-meta.xml
4. Run a CHECK-ONLY dry-run with objects/Case/** alone against usman-dpeg.
   Read the report's `files` ARRAY, not the success flag — "No local changes to deploy"
   with zero files is the exact symptom the Account incident produced.
5. Re-add ONLY the individually failing Case/fields/<Name>.field-meta.xml paths, by exact
   path, with a dated comment naming the error. Suspects (unverified): AssetWarrantyId
   (AssetWarranty/** is Bucket A — does not resolve), EntitlementId, ServiceContractId,
   MilestoneStatus, MilestoneStatusIcon, SlaStartDate, SlaExitDate, IsStopped,
   StopStartDate, BusinessHoursId.
   Do NOT re-add a blanket Case/** or Case/fields/** — custom fields go in Case/fields/.
6. Report back: the files array contents, the exact failures, and the final .forceignore diff.

Record mcp=complete|unavailable + tools. Do not deploy anything else in this pass.
```

## 🟤 PROMPT FOR `salesforce-solution-architect` — PHASES 2, 3, 6

```
Read ARCHITECTURE.md and .claude/rules/*.md first. Read agent-output/design-ar-delinquency.md
in full — sections 1 (contradicted premises), 2 (gates), 4 (admin work) and 8 (hub file ban).
Record mcp=unavailable (salesforce-api-context is not configured in this repo — see
agent-output/design-ar-delinquency.md rule-gate status) and fall back to the per-type skill.

PHASE 2 — create, per §4 A2/A3/A5/A6 of that document:
  - Receivables_Summary__c    (read-only Yardi mirror, Private OWD, 24 fields as specced)
  - Sync_Run__c               (ingestion audit, one row per run)
  - Payment_Commitment__c     (Master-Detail to Case, reparentable=false)
  - Receivables_Sync_Config__c (HIERARCHY CUSTOM SETTING — copy SharePoint_Config__c exactly,
    including the DELIBERATELY OMITTED customSettingsVisibility and its explanatory comment;
    declaring it fails at 67.0 and cascades ~30 "Dependent class is invalid" Apex errors)
  - Named Credential `ASB` ONLY. Do NOT ship an External Credential as metadata — the OAuth
    XML shape is unconfirmed at 67.0 and a malformed guess fails at token acquisition with an
    opaque error (same decision as SharePoint_Credential).
  - StaticResource Receivables_Feed_Sample (JSON fixture for the stub provider)

PHASE 3 — Case schema. THIS ORDER IS MANDATORY:
  standardValueSets/CaseStatus + CaseReason  (whole-set replacement — retain every stock
    value; add the 7 §5.9.5 statuses with Resolved closed=true, and the 4 §5.9.5 reasons)
    -> CaseBusinessProcess "Delinquency Support Process"
      -> Case.Delinquency RecordType (list all 7 statuses on it)
        -> the 22 Case custom fields in §4 A4
          -> Case-Delinquency Layout + compactLayout
            -> Path on Case.Status scoped to the Delinquency record type
  🔴 The RecordType MUST deploy before any Apex or test that writes a Status value —
     restricted picklist values ARE enforced at DML on this project (measured 4×), despite
     ~20 in-repo comments claiming otherwise.
  🔴 Case.Yardi_AR_Id__c is externalId but NOT unique — closed Cases accumulate per tenant.

PHASE 6:
  - sharingRules/Receivables_Summary__c — criteria-based, READ ONLY, to
    DPEG_Property_Mgmt_Team and Principals. Model on how Work_Order__c is treated, NOT on
    sharingRules/Delinquency__c (which grants Edit and is the inversion being retired).
  - approvalProcesses/Case.Write_Off_Approval — copy Disposition__c.Closing_Approval's shape.
    🔴 recordLock MUST be false on every step AND on final approval: a locked Case blocks the
    nightly balance refresh for exactly the cases under principal review, and allOrNone=false
    swallows the refusal.
  - Workflow email alerts: ADD to the EXISTING workflows/Case.workflow-meta.xml (it already
    holds ChangePriorityToHigh — do not create a second file). Copy the
    Transaction_Opened_Notification triple verbatim: EmailTemplate (type=text, style=none,
    uiType=Aloha, encodingKey=UTF-8) + <recipients><type>group</type> +
    <senderType>CurrentUser</senderType> + a record-triggered Flow to fire it.

🚫 DO NOT TOUCH: applications/*, permissionsets/*, tabs/*. Two other builds are running
   concurrently and a PermissionSet deploy REPLACES its entire fieldPermissions set. Everything
   you need from those files is already listed in §8 HUB FILE REQUESTS for the main agent.
🚫 Do not add validation rules, permission sets, or fields beyond the specced list.
```

## ⚫ PROMPT FOR `salesforce-technical-architect` — PHASES 4 (+ its own tests per §5 D4)

```
Read ARCHITECTURE.md §2/§3 and .claude/rules/apex-layering-rule.md + bulk-test-rule.md first.
Read agent-output/design-ar-delinquency.md §5 (D1-D4), §2 GATE-5, and §9 (the ARCHITECTURE
§3.5 update you must land in the same PR). Record mcp=unavailable and fall back to the skill.

Build the pluggable Yardi/ASB receivables ingestion layer and the nightly delinquency
lifecycle, exactly per §5 D1-D3 of that document. The class inventory, layers and
responsibilities are enumerated there — build that set, no more.

🔴 THE FIVE NON-NEGOTIABLES:
1. ONE class owns the callout boundary: ReceivablesCalloutService holds the ONLY Http.send
   and the ONLY endpoint constant (private static final String BASE = 'callout:ASB').
   Model on SharePointCalloutService and LLMExtractionCalloutService — read both headers.
   Ship ReceivablesCalloutMock alongside it.
2. ONE ingest entry point: ReceivablesSyncService.ingest(List<ReceivablesFeedDTO>, Id syncRunId).
   Every provider funnels through it, so swapping the source touches NOTHING downstream.
   The StubReceivablesFeedProvider (StaticResource JSON, zero callouts) must drive the entire
   §5.9 workflow today — that is the user's central ask and needs a test proving it.
3. ALL SOQL in selectors. Batch start() delegates to a selector locator (see how
   DealFolderSweepBatch.start() delegates to PropertySelector.queryFolderSweep()).
   WITH SYSTEM_MODE on every automation-path read, justified PER METHOD in the selector's
   class header — USER_MODE throws rather than degrading, and MDAPI-deployed fields arrive
   with no FLS for anyone.
4. 🔴 SYSTEM_MODE DOES NOT LIFT SHARING. The never-duplicate-Case guard is exactly the read
   where a sharing-filtered result inverts the feature into a DUPLICATE-MAKER. Put the guard
   query, the mirror upsert locator and the mirror write in narrow `private without sharing`
   INNER classes — never `without sharing` on a whole selector. This repo has the incident on
   file: an approval's parent write failed silently for every approver who did not OWN the
   record, masked by allOrNone=false, and it worked in every test only because the test's
   approver was the owner. Case OWD is public TODAY, which hides this — it must be correct
   BEFORE Case is hardened to Private.
   Required test: open Case owned by user A, sync runs as user B on the MINIMUM ACCESS profile
   (a Standard User-based test proves nothing for a standard object), assert ZERO new Cases.
5. Provider resolution is Type.forName(config.Provider_Class_Name__c).newInstance().
   A class referenced only by a config string can be DELETED without a compile error — ship a
   test asserting every configured name resolves, and HALT (Sync_Run__c Halt_Reason__c =
   'Disabled', Lifecycle_Ran__c = false) on an unresolvable name. Never silently fall back to
   the stub in production.

⚠ ALSO:
- Health check measures staleness against the FEED's own Feed_As_Of_DateTime__c, never against
  Salesforce's clock. On halt: Lifecycle_Ran__c = false and ZERO cases created or escalated —
  that boolean is the entire test surface for FSD §5.9.6's first safety rule.
- Escalation is one-way AND carries Escalation_Basis_Days__c (a snapshot of the Days_Past_Due
  the level was computed against). Without the snapshot a record whose aging Yardi later
  CORRECTS DOWNWARD is never alerted again — the NdaExpiryAlertBatch ladder is the precedent;
  read its header. Send first, stamp second.
- Database.upsert(rows, ..., false): allOrNone=false makes partial failure SILENT. Capture the
  failure list into Sync_Run__c.Halt_Detail__c; do not discard it.
- The batch makes NO callouts (the feed is already landed) so SCOPE = 200. Do not copy
  DealFolderSweepBatch's SCOPE = 10 — that number is a callout budget, not a throughput knob.
- Fold the date-driven triggers (promise-to-pay breach, stale follow-up) into
  DelinquencyLifecycleBatch. Do NOT add a third schedulable — the FSD describes one nightly job.
- Any approval-triggered Apex needs BOTH <runInMode>SystemModeWithoutSharing</runInMode> on the
  flow AND AccessLevel.SYSTEM_MODE stated at the DML. runInMode alone is measured NOT to lift
  the access mode (see MarketDataSnapshotService's header) and the stamp silently writes nothing.
  Catch Exception, not DmlException — a TypeException is not a DmlException and rolls back the
  whole approval.
- Bulk tests: 251+ records for the batch, the ingest service and every trigger handler, with
  assertion counts matching 251. TestDataFactory only; never SeeAllData=true.
  The content-publication rule does NOT apply here (no ContentVersion/Note/Document).
- Update ARCHITECTURE.md §1, §2 and add §3.5 in the SAME PR — draft text is in §9 of the design
  doc. Pick Variant A or B based on the GATE-7 answer.

🚫 DO NOT TOUCH applications/*, permissionsets/*, tabs/*. Class access grants go in §8's HUB
   FILE REQUESTS for the main agent to consolidate.
🚫 Do not build the inbound @RestResource — deferred by design (§5 D5). Record the seam in the
   ReceivablesSyncService class header as a named future entry point.
```

## 🔵 PROMPT FOR `salesforce-admin` — PHASES 7 & 8

```
Read agent-output/design-ar-delinquency.md §4 A8 (reports/dashboards) and §6 (the
Delinquency__c retirement sequence). Record mcp=unavailable and fall back to the skill.

PHASE 7 — build R1..R11 in reports/Property_Management/ and the §6.5 AR dashboard at
dashboards/Property_Management/Accounts_Receivable.dashboard-meta.xml.
  ⚠ FOUR reports (R3, R4, R5, R9, R10) are on Case and NO Case report exists in this repo to
    copy. Resolve the correct <reportType> token EMPIRICALLY — deploy ONE report, read it back
    from the org, prove it renders — before authoring the rest. This repo has prior form for
    report-type token failures.
  ⚠ Measured native-report rules: Metric components require a Summary-format report; use
    FlexTable for detail tables; <aggregate> not a!/s! prefixes; Average counts blanks as 0.
  ⚠ R7 (worst by MONTHS OF RENT) uses Max(Months_Outstanding__c); R8 (worst by DOLLARS) uses
    Sum(Total_Outstanding_Amount__c). They are DIFFERENT aggregates and must sit SIDE BY SIDE
    on the same dashboard row — FSD §5.9.9 says the differing order is the whole point.

PHASE 8 — repoint §6.1 and retire Delinquency__c, following §6's 14-step sequence IN ORDER.
  ⚠ Reports do NOT block object/field deletion — the failure is silent. Sequence is the only
    control: repoint the dashboard components BEFORE deleting the old report, and delete the
    old report BEFORE deleting the object.
  🔴 Step 6 is the one always missed: scripts/seed-pm-dashboard.apex lines 37-44 and line 66
    RESURRECT Delinquency__c on every org rebuild.
  ⚠ Step 8 (permission set entries) is a HUB FILE — hand it to the main agent, do not edit
    permissionsets/* yourself.
  ⚠ Deletion needs a destructiveChanges.xml via salesforce-devops; removing files does not
    delete metadata.
  ⚠ dashboards/Property_Management/Property_Management_Overview.dashboard-meta.xml is shared
    with two concurrent builds — diff against HEAD before deploying.
```
