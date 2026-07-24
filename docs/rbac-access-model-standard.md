# DPEG Access Model & Permission-Set Naming Standard

**Status:** Adopted 2026-07-22. Applies to all DPEG team users on `usman-dpeg` (and future orgs).
**Owner:** Platform/Admin. **Related:** `agent-output/rbac-architecture-spec.md`, `agent-output/rbac-build-runbook.md`.

---

## 1. The model (how access is granted)

**One profile for everyone; access via Permission Set Groups.**

- **Profile:** every team user sits on the standard **`Minimum Access – Salesforce`** profile. We do **not** clone per-team profiles.
  - *Why:* a user has exactly **one** profile but **many** permission sets. All CRUD/FLS/app access already lives in permission sets, so a cloned profile carries nothing useful — it would just be an identical empty copy of Minimum Access to maintain. Profiles are also `.forceignore`d in this repo (not deployable), so per-team profiles would be un-versioned, manual config.
  - **Only exception:** if a team genuinely needs a **profile-only** setting that a permission set cannot express — a different **default record type**, **page-layout assignment**, or **login-hours / IP range** — clone a *thin* profile carrying only those settings, and still deliver all access through the PSGs.
- **Permission sets** are the reusable building blocks ("what access to what data").
- **Permission Set Groups (PSGs)** compose building blocks per team/role and are the thing assigned to users ("who").

```
User ──(1)── Minimum Access profile
   └──(1)── Team PSG ──(n)── building-block permission sets
```

---

## 2. Naming convention (Option C)

Three fields matter — fill in **all three** on every permission set:

| Field | Style | Example |
|---|---|---|
| **API Name** | `DPEG_<Scope>_<Access>` — underscores, concise | `DPEG_Opportunity_View` |
| **Label** (what admins see) | spaces + separator, plain | `Opportunity – View Only` |
| **Description** | one plain sentence | *"Read-only access to Opportunities. For teams that reference deals but don't own them."* |

**Scope** = a **Module** (`Acquisition`, `Disposition`, `Transaction`, `PropertyMgmt`) for whole-module access, **or** a shared **Object** (`Opportunity`, `Property`) for a cross-team object.
**Access** = a fixed, small vocabulary: **`View`** (read-only) · **`Edit`** (create/read/update, no delete) · **`Manage`** (full incl. delete). App/tab visibility = **`DPEG_App_<Module>`**.
**Team PSG** = `DPEG_<Team>_Team` (e.g., `DPEG_Transaction_Team`) or role name (`DPEG_Principal`).

**Two rules that keep it clean:**
1. Name a shared/cross-team building block by **object, never by team** — it's `DPEG_Opportunity_View`, not `DPEG_Transaction_Opportunity_View` (Disposition and the principal view Opportunity too). The team association lives in the PSG.
2. Keep the **API name concise**; put the human-readable meaning in **Label + Description**.

---

## 3. Building blocks — deployed vs. to-add

**Already deployed (2026-07-22):**
`DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Disposition_Edit`, `DPEG_Disposition_View`, `DPEG_Transaction_View`, `DPEG_PropertyMgmt_View`, `DPEG_App_Acquisition/Disposition/Transaction/PropertyMgmt`; PSGs `DPEG_Junior_Analyst_PSG`, `DPEG_Principal_PSG`.

**To add for the Transaction & PM teams:**
- `DPEG_Transaction_Edit` (create/read/update Transaction + Critical_Date, no delete)
- `DPEG_PropertyMgmt_Edit` (create/read/update the PM masters, no delete; details follow master)
- `DPEG_Opportunity_View` (shared — deal spine that Transaction/PM/others view read-only)
- `DPEG_Property_View` *(optional — only if teams need to view `Property__c` without full Acquisition read)*

---

## 4. Proposed team personas *(confirm before build)*

Mirrors the Junior/Nikhil pattern: **edit your own module, view the context you need, no delete, no modify-all.**

| Team / PSG | Edit | View | App tabs |
|---|---|---|---|
| **`DPEG_Transaction_Team`** | Transaction, Critical_Date | Opportunity (deal spine); *optionally* Disposition + PM | Transaction |
| **`DPEG_Property_Management_Team`** | the 15 PM objects | Opportunity/Property context; *optionally* Transaction | Property Management |

**Open for you to confirm:** how wide each team's **read** should be — minimal (just Opportunity/Property context) vs. broad (view all four modules like the principal). Default = **minimal** (least-privilege).

---

## 5. Recipe — onboard a new team

1. **Define the matrix:** which module they *edit*, which objects they *view*.
2. **Building blocks:** reuse existing `DPEG_*_View/Edit`; create any missing per §2 naming (Label + Description mandatory).
3. **Team PSG:** `DPEG_<Team>_Team` composing those blocks + the `DPEG_App_<Module>` set(s).
4. **Users:** create on `Minimum Access – Salesforce`, assign the team **role** (role hierarchy), send set-password email.
5. **Assign the PSG** to each user.
6. **Sharing rules** only if the team must edit records they don't own (owner-based → the team's public group).
7. **Test as the persona** (log in as them — admins can't see FLS/OWD gaps).

---

## 6. Still pending (carry-over)

- **Lead OWD → Private** — manual, UI-only: Setup → Security → Sharing Settings (needed to make the Acquisition queue least-privilege).
- **Persona acceptance test** for Junior + Nikhil (log in as each).
- Existing `Property_Management_Access` / `Transaction_App_Access` lack *View All* on some objects — fix before any future **non-admin power user** is put on those legacy sets (not a blocker for the new model).
