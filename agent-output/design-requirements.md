# DPEG — Role-Based Access Security Model (Design Requirements / Gate-1 Artifact)

**Request type:** Declarative security-model build — **no Apex, no LWC.**
**Target org:** `usman-dpeg` (Enterprise Edition, treated as UAT; direct fixes approved by user).
**Routing:** `salesforce-solution-architect` (security design) → `salesforce-admin` (build).
**Prepared by:** salesforce-design · **Date:** 2026-07-22

> This is a **design / requirements** document only. No users, queues, permission sets, roles, sharing rules, or approval edits are created here, and no deploy is run. Gate-1 confirmation required before build.

---

## 1. Objectives & Scope

### Objective
Stand up a **production-grade, least-privilege RBAC model** for two named users on the standard **Minimum Access – Salesforce** profile, composed entirely from OWD + Role Hierarchy + Sharing + Permission Sets/PSGs + a Queue, and reconcile the two Opportunity approval processes to the correct principal approver.

### In scope
- Two users: **Junior Dhanani** (junior acquisition analyst) and **Nikhil Dhanani** (principal).
- **Acquisition queue** (Leads + a recommended set of acquisition custom objects) with Junior as member.
- **Full least-privilege RBAC**: per-object OWD tightening, a DPEG role hierarchy, and sharing strategy.
- A **new** permission-set / PSG architecture that composes exactly the required access (existing perm sets are unsuitable — see §7).
- **Approval repoint** of `Opportunity.LOI_Approval` and `Opportunity.Underwriting_Approval` to Nikhil.

### Out of scope (explicit)
- **Transaction / Property Management team editor personas** — deferred (only Junior + Nikhil now).
- **Experience Cloud / Investor Portal** access and guest sharing.
- **Sharing for the IR module** (Investor/Investment objects — never built; do not design for them).
- **Modifying or deleting existing permission sets / users** — the new perm sets are strictly additive; existing personas must remain unaffected.
- Apex, LWC, Flow, validation rules, field creation.

### The 4 binding decisions (already made — do not re-litigate)
1. **Junior** = Edit on Acquisition + Disposition; View-only on Transaction + Property Management.
2. **Queue** = Acquisition queue owns Leads + acquisition objects; Junior is a member.
3. **RBAC** = full least-privilege (OWD tighten + Role Hierarchy + Sharing), not simple perm-set-only control.
4. **Approver** = Nikhil Dhanani is the principal approver on both Opportunity approval processes.

---

## 2. Ground-Truth Facts (verified against repo, 2026-07-22)

These facts drive the design; the admin must re-verify the **live org** values before building (repo ≠ org in places, see risks).

| Fact | Verified value |
|------|----------------|
| Custom objects | **33** (11 Acquisition, 2 Transaction, 5 Disposition, 15 Property Management) per ARCHITECTURE §1 |
| OWD — 28 master objects | **`ReadWrite` (Public Read/Write)** — org-wide-open; no tightening deployed |
| OWD — 5 detail objects | **`ControlledByParent`**: `Unit__c`, `Rent_Step__c`, `Lease_Activity__c`, `Renewal_Activity__c`, `Work_Order_Activity__c` — inherit master; **cannot** carry their own OWD |
| Apps (4) | `Acquisition`, `Disposition`, `Transaction`, `Property_Management` |
| Existing Acquisition queue | **None.** Only `Broker_Portal_Leads` (Lead only) exists in repo |
| `LOI_Approval` approvers | `usman.khan.dpeg@avanzasolutions.com` **+** `aftab.ali.dpeg.usman@avanzasolutions.com`, **Unanimous** |
| `Underwriting_Approval` approvers | Same two, **Unanimous**; description states *"Both principals (Ali + Nikhil) must approve"* |
| Existing perm sets | `DPEG_Acquisitions` (346 FLS fields, Create/Edit/Delete broad), `Property_Management_Access` (183), `Transaction_App_Access` (44), `Acquisition_App_Access` (all-4-apps visibility), + dashboard/admin sets — all **edit/power-user scoped** |
| FLS location | Effective FLS lives on **profiles**, which are `.forceignore`d — **FLS is NOT in the repo.** New perm sets must author FLS fresh (cannot copy from profiles) |

**Boundary objects (note, no design impact):** `Property__c` is the acquisition target (Acquisition module) — distinct from `Property_Asset__c` (PM root). `NDA__c` spans Acquisition + Disposition (Junior edits it under either).

---

## 3. User Matrix (target end-state)

Object groups: **ACQ** = {Opportunity, Lead, Property__c, LOI__c, Counter_Offer__c, Underwriting__c, Development_Feasibility_Review__c, Construction_Feasibility_Review__c, Contract_Review__c, PSA_Version__c, Deal_Message__c, Offering__c, NDA__c}. **DISP** = {Disposition__c, Disposition_Offer__c, BOV_Submission__c, Broker_Listing__c, Wire__c}. **TXN** = {Transaction__c, Critical_Date__c}. **PM** = the 15 Property-Management objects.

| User | Group | Create | Read | Edit | Delete | FLS | Record visibility mechanism |
|------|-------|:------:|:----:|:----:|:------:|-----|-----------------------------|
| **Junior Dhanani** | ACQ | ✅ | ✅ | ✅ | ❌ | View+Edit | Owns + queue/team sharing (R/W); View All for read |
| | DISP | ✅ | ✅ | ✅ | ❌ | View+Edit | Owns + team sharing (R/W); View All for read |
| | TXN | ❌ | ✅ | ❌ | ❌ | View | **View All** (read all) |
| | PM | ❌ | ✅ | ❌ | ❌ | View | **View All** (read all) |
| | Apps | Acquisition, Disposition, Transaction | | | | | |
| **Nikhil Dhanani** | ACQ | ❌ | ✅ | ❌ | ❌ | View | **View All** (read all) |
| | DISP | ❌ | ✅ | ❌ | ❌ | View | **View All** (read all) |
| | TXN | ❌ | ✅ | ❌ | ❌ | View | **View All** (read all) |
| | PM | ❌ | ✅ | ❌ | ❌ | View | **View All** (read all) |
| | Apps | All 4 | | | | | |
| | Approval | Named approver on `LOI_Approval` + `Underwriting_Approval`; Read on Opportunity (via ACQ View) | | | | | |

**Design notes**
- **"Create/Read/Edit, no Delete"** for Junior is deliberate least-privilege — the request said *edit*, not *delete*.
- **View All (read-all) is the mechanism** that delivers "view-only across records" cleanly under an OWD-Private model — it grants read to every record of an object without any sharing rule, and cannot grant edit. It is the right tool for a read-only principal and for Junior's Txn/PM view.
- Junior is **not** granted **Modify All** anywhere (that would bypass sharing and defeat least-privilege). His edit on records he does not own comes from **sharing rules**, not Modify All.

---

## 4. OWD Matrix (Org-Wide Defaults)

**Principle:** tighten every deal/financial/tenant **master** to **Private**; deliver read to view personas via **View All** perm-set flags and edit to Junior via **sharing rules**. Detail objects inherit their master (unchanged). This achieves least-privilege without any `Public Read-Only` tier — no object needs to be world-readable.

| Object(s) | Current OWD | Target OWD | Rationale |
|-----------|-------------|-----------|-----------|
| **28 master custom objects** (all ACQ/DISP/TXN/PM masters) | `ReadWrite` (Public R/W) | **Private** | Deal, financial, wire, and tenant records must not be world-writable. Access granted back explicitly (auditable). |
| `Unit__c`, `Rent_Step__c`, `Lease_Activity__c`, `Renewal_Activity__c`, `Work_Order_Activity__c` | `ControlledByParent` | **`ControlledByParent` (unchanged)** | Master-detail details cannot have an independent OWD — they follow the master. No action. |
| **Opportunity** (standard) | *verify in org* | **Private (recommended)** — **decision required** | Consistent least-privilege for the deal root. **Blast radius:** affects all existing deals + `LeadConvertService`/assignment flows; regression-test first. If disruptive, keep current OWD and rely on Read object perm + View All for read personas. |
| **Lead** (standard) | *verify in org* | **Private (recommended)** | Private + queue ownership is exactly why the Acquisition queue works — queue members auto-see queue-owned leads; assignment rules still route. |

**Keep "Grant Access Using Hierarchies" = ON** on all Private custom objects so the role hierarchy backbone functions (principal sees subordinates' records). View All is the primary read mechanism for the two personas; hierarchy is the structural backbone and future-proofing.

**Standard-object caveat:** OWD for standard objects (Opportunity, Lead) is managed in **Setup → Sharing Settings**, not reliably in `object-meta.xml`. The admin must read/set these in the org.

---

## 5. Role Hierarchy

The 18 roles in the repo are the **out-of-box Salesforce sample set** (CEO, CFO, Sales teams…) — not DPEG-specific. Design a clean DPEG tree:

```
DPEG Principal            (Nikhil Dhanani)          ← top; grant-access-using-hierarchy reaches all below
├── Acquisitions Lead     (unassigned — scaffold)
│   └── Acquisitions Analyst   (Junior Dhanani)     ← assigned now
├── Disposition Lead      (unassigned — deferred)
├── Transactions Lead     (unassigned — deferred)
└── Property Mgmt Lead    (unassigned — deferred)
```

**Build now (minimal to satisfy the 2 users):**
- `DPEG_Principal` → assign **Nikhil**.
- `Acquisitions_Analyst` (reporting to `DPEG_Principal`, optionally via an `Acquisitions_Lead` placeholder) → assign **Junior**.

The lead/other-module roles are **designed but not built** (out of scope: Txn/PM/Disp team users are deferred). Add them when those personas exist.

**Why hierarchy alone is not enough:** queue-owned and integration-owned (Yardi-mirror) records sit **outside** the role hierarchy — hierarchy will not surface them to Nikhil. This is why the two personas get **View All** (§3) rather than relying on hierarchy for read. Hierarchy is the backbone; View All is the guarantee.

---

## 6. Sharing Strategy (how each persona sees records under OWD Private)

| Persona / need | Mechanism | Detail |
|----------------|-----------|--------|
| **Nikhil — read everything (4 modules)** | **View All** on every object (in his View perm sets) + top of role hierarchy | View All delivers org-wide read with no sharing rules; hierarchy is structural. No sharing rules required for Nikhil. |
| **Junior — read all Txn + PM** | **View All** on TXN + PM objects (in his View perm sets) | No sharing rules required. |
| **Junior — read all Acq + Disp** | **View All (read)** on ACQ + DISP objects (in his Edit perm sets) | Lets him *see* records he doesn't own; edit is separate (below). |
| **Junior — edit Acq records he doesn't own** | **Owner-based sharing rule** | Records **owned by the Acquisition queue** → **Read/Write** to public group **`DPEG Acquisitions Team`**. Queue-owned records do **not** share up the hierarchy, so this rule is mandatory. |
| **Junior — edit Disp records he doesn't own** | **Owner-based sharing rule** | Disposition has **no queue** in scope; records are user-owned. Rule: records owned by **`Role: Acquisitions Analyst and Subordinates`** → **R/W** to `DPEG Acquisitions Team`. If disposition records will be owned outside that role, extend to a criteria-based "all records" R/W rule (see Open Question 3). |

**Public group to create:** `DPEG Acquisitions Team` = { Role **Acquisitions Analyst and Subordinates**, Role **DPEG Principal** }. Sharing rules grant **R/W**; each user's **object permission caps their effective access** (Junior R/W, Nikhil read-only), so one R/W rule serves both safely.

**Critical gotcha (queue ownership ≠ hierarchy sharing):** a record owned by a **queue** has no role, so it is invisible to the role hierarchy — *including to the principal at the top*. Every module whose records are queue-owned needs an explicit owner-based sharing rule (or the viewers need View All). Nikhil is covered by View All; Junior's **edit** on queue-owned acq records requires the sharing rule above.

---

## 7. Permission-Set / PSG Plan (the crux)

### Why the existing perm sets are unsuitable
`DPEG_Acquisitions`, `Property_Management_Access`, `Transaction_App_Access` grant **Create/Edit/Delete + edit-FLS** across their objects — they are power-user/app sets. They **cannot** express "view-only on Transaction/PM." Reusing them would over-grant. **Do not modify them** (existing users depend on them). Build a clean, composable **new** set.

### New atomic permission sets (functional — object CRUD + FLS)

| # | Permission set | Objects | Object perms | FLS | View All |
|---|----------------|---------|--------------|-----|:--------:|
| 1 | `DPEG_Acquisition_Edit` | ACQ (13, incl. Opportunity, Lead) | C / R / U (no D) | Read + Edit | ✅ (read) |
| 2 | `DPEG_Acquisition_View` | ACQ | R | Read | ✅ |
| 3 | `DPEG_Disposition_Edit` | DISP (5) | C / R / U (no D) | Read + Edit | ✅ (read) |
| 4 | `DPEG_Disposition_View` | DISP | R | Read | ✅ |
| 5 | `DPEG_Transaction_View` | TXN (2) | R | Read | ✅ |
| 6 | `DPEG_PropertyMgmt_View` | PM (15, incl. the 5 details) | R | Read | ✅ |

### New app/tab-visibility permission sets

| # | Permission set | Grants |
|---|----------------|--------|
| 7 | `DPEG_App_Acquisition` | App visibility + all Acquisition tabs |
| 8 | `DPEG_App_Disposition` | App visibility + all Disposition tabs |
| 9 | `DPEG_App_Transaction` | App visibility + all Transaction tabs |
| 10 | `DPEG_App_PropertyMgmt` | App visibility + all PM tabs |

### Approval-access permission set
**Recommendation: do NOT create a separate one.** Approval *acting* rights come from being the **named approver** (a process assignment, not a permission) + **Read on Opportunity** — already delivered by `DPEG_Acquisition_View` (Read + View All on Opportunity). A standalone `DPEG_Approval_Principal` would be redundant. Create a thin one (View All on Opportunity only) **only if** you want approval visibility decoupled from module access (see Open Question 5 — flag for confirmation).

### Permission Set Groups (compose per persona)

| PSG | Members | Assigned to |
|-----|---------|-------------|
| `DPEG_Junior_Analyst_PSG` | 1 `Acquisition_Edit`, 3 `Disposition_Edit`, 5 `Transaction_View`, 6 `PropertyMgmt_View`, 7 `App_Acquisition`, 8 `App_Disposition`, 9 `App_Transaction` | **Junior** |
| `DPEG_Principal_PSG` | 2 `Acquisition_View`, 4 `Disposition_View`, 5 `Transaction_View`, 6 `PropertyMgmt_View`, 7–10 all four App sets | **Nikhil** |

A user is never assigned both `*_Edit` and `*_View` for the same module (Junior gets Edit, Nikhil gets View) — no conflict.

### FLS is the bulk of the work (flag)
Each `*_View` / `*_Edit` set must enumerate **FLS for every field** of its objects (33 objects carry **463 custom fields** + standard fields). FLS is **not in the repo** (profiles are forceignored). Practical build path:
- **Source the field lists** from the existing perm sets (`DPEG_Acquisitions` = 346 fields, `Property_Management_Access` = 183, `Transaction_App_Access` = 44) — reuse the enumerations, set the edit flag per view/edit intent.
- **Formula / roll-up / auto-number fields are read-only** → grant **Read FLS only** even in `*_Edit` sets (an edit-FLS on a formula field is invalid).
- **Required & master-detail fields** cannot have Read FLS removed — grant Read.
- **Missing FLS = "No such column" / blank fields** for the persona. This is invisible to an admin tester (admin passes via profile). **Acceptance test as each persona** (see §14 risks).

---

## 8. Acquisition Queue Specification

**Create queue:** `Acquisition` (verify it doesn't already exist in the live org first — only `Broker_Portal_Leads` is in the repo).

**Members:** **Junior Dhanani** (direct member). *(Optionally add the `Acquisitions Analyst` role instead of the user, for future members — recommend user-direct now for the 2-user scope.)*

**Queue-enabled objects — recommendation:**

| Object | Queue-own? | Rationale |
|--------|:----------:|-----------|
| **Lead** | ✅ **Yes** | Primary purpose — inbound acquisition-lead triage/intake (mirrors existing Broker Portal Leads pattern). |
| **Property__c** | ✅ **Recommended** | Standalone acquisition target; a triage pool for sourced-but-unassigned targets before an analyst takes ownership. |
| `Underwriting__c`, `LOI__c`, `Development_Feasibility_Review__c`, `Construction_Feasibility_Review__c`, `Contract_Review__c` | ⚠️ **Optional** | Only if DPEG wants a **pooled-review intake** model (analysts pick up unassigned reviews). Otherwise these are auto-created by Apex tied to a user-owned deal and should follow the deal owner. **Default: No.** |
| `Counter_Offer__c`, `PSA_Version__c`, `Deal_Message__c` | ❌ **No** | Append-only logs / version children — no independent assignment; ownership should track the parent. |
| `Offering__c`, `NDA__c` | ❌ **No** (default) | Documents tied to a deal/disposition; `NDA__c` also spans Disposition. Queue-own only if a legal-triage pool is wanted. |

**Recommended minimal set: `Lead` + `Property__c`.** (See Open Question 2 for the optional pooled-review extension.)

**Constraints the admin must respect:**
- **Opportunity cannot be queue-owned** (standard Opportunity does not support queue ownership) — the deal itself is always user-owned.
- All 11 acquisition custom objects are lookup-based (none are master-detail details), so all **have `OwnerId` and are queue-eligible** — the recommendation above is a *design* choice, not a technical limit.
- The `Acquisition` queue on Lead **coexists** with `Broker_Portal_Leads`; ensure Lead assignment rules don't conflict.

---

## 9. Approval-Process Repoint

**Goal:** Nikhil Dhanani becomes the principal approver on `Opportunity.LOI_Approval` and `Opportunity.Underwriting_Approval`.

**Current repo state:** both processes name **two** approvers — `usman.khan.dpeg@avanzasolutions.com` (the ghost Nikhil placeholder) **+** `aftab.ali.dpeg.usman@avanzasolutions.com` ("Ali") — with **Unanimous**. The Underwriting description documents *"Both principals (Ali + Nikhil) must approve."*

**Recommended repoint (matches documented two-principal design):**
- Replace `usman.khan.dpeg@avanzasolutions.com` → **new Nikhil Dhanani user**.
- **Keep** `aftab.ali.dpeg.usman@avanzasolutions.com` as co-approver; **keep Unanimous.**
- Apply identically to both processes.

> **Open Question 1** — the request says *"so Nikhil is the approver"* (singular). If the intent is **Nikhil as sole approver**, drop Ali and use a single-approver step instead. Repo shows 2/unanimous; confirm before building.

**Operational sequence (admin — declarative gotchas):**
1. **Verify the LIVE org** approver config first — repo may differ from org (drift noted).
2. An **active** approval process's steps **cannot be edited** — **deactivate** each process, edit the approver, **reactivate**.
3. Deactivation is **blocked by pending in-flight approval requests** — **recall** any pending submissions first.
4. The approver must be an **active user with a Salesforce license** (Opportunity is a standard object) and **Read on Opportunity** — delivered by `DPEG_Acquisition_View`. Minimum Access – Salesforce is a Salesforce-licensed profile ✅.
5. `recordEditability = AdminOnly` is unchanged — fine, since Nikhil is read-only anyway; he can still approve/reject as the named approver.

---

## 10. Users to Create

Both on the standard **Minimum Access – Salesforce** profile.

| Field | Junior Dhanani | Nikhil Dhanani |
|-------|----------------|----------------|
| Notification/activation email | `usmankhan-96@hotmail.com` | `usmanthehitman@gmail.com` |
| Proposed username (must be globally unique) | `junior.dhanani@usmandpeg.uat` | `nikhil.dhanani@usmandpeg.uat` |
| Alias | `jdhan` | `ndhan` |
| Profile | Minimum Access – Salesforce | Minimum Access – Salesforce |
| Role | `Acquisitions_Analyst` | `DPEG_Principal` |
| Queue membership | `Acquisition` queue | — |
| PSG | `DPEG_Junior_Analyst_PSG` | `DPEG_Principal_PSG` |
| Approver on | — | `LOI_Approval`, `Underwriting_Approval` |

Usernames are **globally unique across all Salesforce orgs** — if `@usmandpeg.uat` is taken, suffix (e.g., `.01`). Set locale/timezone/language to org defaults at creation.

---

## 11. Admin vs. Solution-Architect Split

### 🟤 SOLUTION-ARCHITECT (design authority)
- Finalize the **OWD matrix** (per-object target + the Opportunity/Lead standard-object decision).
- Finalize the **role hierarchy** tree (which roles to build now vs. defer).
- Specify **sharing rules** (owner/criteria, source owner, target group, grant level) and the **public group** definition.
- Specify the **permission-set / PSG architecture** — object perms, View All flags, FLS scope per set, app/tab visibility, and the user→PSG mapping.
- Decide the **approval repoint** shape (Nikhil sole vs. Nikhil + Ali unanimous) pending Open Question 1.
- Produce the **queue spec** (final object list + members).

### 🔵 ADMIN (build)
- Create **roles**, **public group**, **2 users** (assign roles).
- Set **OWD** per matrix (custom objects via `sharingModel`; standard objects in Sharing Settings).
- Create **sharing rules**.
- Create the **6 functional + 4 app permission sets** (with full FLS enumeration) and the **2 PSGs**; assign to users.
- Create the **`Acquisition` queue** (+ Junior member, + queueSobjects).
- **Repoint** the two approval processes (deactivate → edit approver → reactivate).
- **Do not deploy** without Gate-3 confirmation; **do not modify** existing perm sets/users.

---

## 12. Recommended Build Order (dependency-driven)

1. **Roles** (`DPEG_Principal`, `Acquisitions_Analyst`) — needed before users and role-based sharing.
2. **Public group** `DPEG Acquisitions Team` (references the roles).
3. **Users** (Junior → Acquisitions Analyst; Nikhil → DPEG Principal).
4. **Permission sets + PSGs** (create + FLS enumeration).
5. **OWD tightening** (custom masters → Private; Opportunity/Lead per decision). *Triggers sharing recalculation.*
6. **Sharing rules** (after OWD Private + groups + roles exist).
7. **Acquisition queue** (+ Junior member + queueSobjects).
8. **Assign PSGs** to users.
9. **Repoint approval processes** to Nikhil (recall pending → deactivate → edit → reactivate).
10. **Persona acceptance test** — log in **as Junior** and **as Nikhil**; verify exact access; an admin smoke test proves nothing (FLS/USER_MODE gaps are invisible to admins).

---

## 13. Open Questions (for the user)

1. **Approval approvers** — keep Ali as co-approver with Nikhil (**Unanimous**, matches the documented two-principal design), or make **Nikhil the sole approver**? *(Recommend: swap ghost → Nikhil, keep Ali, keep Unanimous.)*
2. **Queue objects** — confirm the minimal set **`Lead` + `Property__c`**, or extend to the **pooled-review** objects (`Underwriting__c`, `LOI__c`, the two feasibility reviews, `Contract_Review__c`)? *(Recommend: minimal.)*
3. **Junior's edit reach on Acq/Disp** — edit records owned by the **Acquisitions team + queue** (least-privilege sharing rules — recommended), or edit **literally every** acq/disp record (needs a criteria-based "all records" R/W rule)? *(Recommend: team + queue.)*
4. **Opportunity OWD** — tighten standard **Opportunity to Private** for full least-privilege (blast radius on existing deals + lead-convert flows, regression-test), or keep current OWD and deliver read-only via object perm + View All? *(Recommend: keep current initially; revisit.)*
5. **Approval-access perm set** — confirm we **fold** approval visibility into `DPEG_Acquisition_View` (recommended) rather than creating a standalone `DPEG_Approval_Principal`.
6. **Usernames** — confirm `@usmandpeg.uat` scheme; suffix if globally taken.

---

## 14. Assumptions & Risks

### Assumptions
- Both users receive a **full Salesforce license** (Minimum Access – Salesforce) — required for standard-object apps + approvals. Confirm seat availability in the EE org.
- Yardi-mirror objects (`Work_Order__c`, etc.) are **read-only by design** — view-only aligns; no write-back needed.
- Existing perm sets/users are **left untouched**; the new model is purely additive.

### Risks
- **FLS enumeration is large and not in the repo** — 463 custom + standard fields must be authored fresh per perm set. Missing FLS = blank fields / "No such column," **invisible to admin testers**. → Enumerate from existing perm sets; **test as each persona**.
- **OWD Private tightening changes visibility for ALL existing users/integrations** (and, with `WITH USER_MODE` selectors, can silently break dashboards/LWCs for non-admins). → Regression-test existing personas after the OWD change; USER_MODE breakage does not surface for admin testers.
- **Queue ownership does not share up the role hierarchy** — even the principal won't see queue-owned records without View All or a sharing rule. Covered by design (View All + queue sharing rule), but easy to get wrong.
- **Approval repoint** requires deactivating active processes; **blocked by pending approval requests** — recall first.
- **Repo ≠ org drift** on approval approvers (repo shows 2; request describes 1) — verify the live org before editing.
- **Property__c dual role** — Junior edits `Property__c` (Acquisition) but is view-only on PM; ensure this boundary (`Property__c` ≠ `Property_Asset__c`) is intended.
- **Do not grant Modify All** to Junior — it would bypass sharing and break least-privilege.

---

## 15. Prompts for Specialist Agents

### 🟤 Prompt for `salesforce-solution-architect`
```
Design (do not build) the DPEG least-privilege RBAC security model per agent-output/design-requirements.md.
Deliver: (1) final per-object OWD matrix — 28 custom masters → Private, 5 details ControlledByParent unchanged,
and a recommendation on Opportunity/Lead standard-object OWD with blast-radius note; (2) the DPEG role-hierarchy
tree (build DPEG_Principal + Acquisitions_Analyst now; design the lead/module roles as deferred); (3) sharing-rule
specs + the DPEG Acquisitions Team public group (queue-owned acq → R/W to group; disposition owner-based → R/W;
note queue-ownership does NOT share up hierarchy); (4) the permission-set/PSG architecture — 6 functional sets
(Acquisition/Disposition Edit+View, Transaction View, PropertyMgmt View) with View All read flags + FLS scope per
set, 4 app-visibility sets, 2 PSGs, and the user→PSG map; approval visibility folded into Acquisition_View (no
standalone approval set). Follow ARCHITECTURE §1 (object list), §2 (approval services), §4 (portal out of scope).
Least-privilege: no Delete for Junior, no Modify All anywhere. Resolve nothing that is an Open Question — surface it.
```

### 🔵 Prompt for `salesforce-admin`
```
Build (metadata files only; DO NOT deploy) the DPEG RBAC model approved from agent-output/design-requirements.md,
following the solution-architect's spec. Create: roles (DPEG_Principal, Acquisitions_Analyst); public group
DPEG Acquisitions Team; 2 users on Minimum Access – Salesforce (Junior junior.dhanani@usmandpeg.uat →
Acquisitions_Analyst; Nikhil nikhil.dhanani@usmandpeg.uat → DPEG_Principal; emails per doc §10); OWD changes
(28 custom masters → Private; leave the 5 ControlledByParent details; Opportunity/Lead per the confirmed decision);
sharing rules per spec; the 6 functional + 4 app permission sets WITH FULL FLS enumeration (source field lists from
existing DPEG_Acquisitions/Property_Management_Access/Transaction_App_Access; Read-only FLS on formula/roll-up
fields; no Delete for Junior; no Modify All); 2 PSGs + assignments; the Acquisition queue (Lead + Property__c,
Junior as member). Repoint Opportunity.LOI_Approval + Opportunity.Underwriting_Approval to Nikhil per Open
Question 1's resolution (deactivate → edit approver → reactivate; recall pending first). DO NOT modify existing
perm sets or users. DO NOT deploy — hand off to salesforce-devops for Gate-3.
```

---

*End of Gate-1 design artifact. Awaiting user confirmation (yes / no / changes) and resolution of the 6 open questions before routing to solution-architect + admin.*
