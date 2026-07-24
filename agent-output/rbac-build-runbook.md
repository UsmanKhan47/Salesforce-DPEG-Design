# DPEG RBAC — Org-Operations Runbook

**Status:** DO NOT EXECUTE. This runbook documents the steps that cannot be expressed as a plain
metadata deploy (user creation, standard-object OWD, queue/PSG membership, approval-process
repoint). It is prepared for **Gate-3** — execute only after the user reviews and approves, and
only through the `salesforce-devops` subagent (or explicit direct authorization).

**Target org:** `usman-dpeg` (`usmandpegorg.my.salesforce.com`, org ID `00Diw000000Fqw1EAC`, Enterprise
Edition, default org). All commands below assume `-o usman-dpeg` / `--target-org usman-dpeg`.

**Prerequisite:** the metadata build in this session (roles, group, queue shell, 28 OWD edits,
7 sharing-rule files, 10 permission sets, 2 PSGs) must be deployed FIRST via `salesforce-devops`
before any step below — several steps below reference Ids/records that only exist after that
deploy (the two roles, the group, the queue, the 10 perm sets, the 2 PSGs).

---

## 0. Pre-flight (R1) — COMPLETED during this build session, results below

**Check:** does `usman.khan.dpeg` (and any other currently-active non-admin user) have View All
Data, so the OWD→Private change doesn't break the admin's own testing or another live persona?

**Result — read-only queries run against `usman-dpeg` on 2026-07-22:**

```
SELECT Id, Username, ProfileId, Profile.Name FROM User WHERE Username='usman.khan.dpeg@avanzasolutions.com'
→ Profile.Name = "System Administrator"

SELECT Username, Name, Profile.Name, IsActive FROM User WHERE IsActive=true
→ 6 active users total:
   usman.khan.dpeg@avanzasolutions.com       (Usman Khan)  — System Administrator
   aftab.ali.dpeg.usman@avanzasolutions.com  (Aftab Ali)   — System Administrator
   autoproc@00diw000000fqw1eac               (Automated Process)        — no Profile (system)
   cloud@00diw000000fqw1eac                  (Platform Integration User) — no Profile (system)
   automatedclean@00diw000000fqw1eac         (Data.com Clean)           — no Profile (system)
   chatty...@chatter.salesforce.com          (Chatter Expert)           — Chatter Free User
```

**Verdict: NO REMEDIATION NEEDED.** Both real human users in the org today — `usman.khan.dpeg`
**and** `aftab.ali.dpeg.usman` (the co-approver on both approval processes) — are on the
**System Administrator** profile, which carries `View All Data` / `Modify All Data` and bypasses
sharing entirely. The OWD→Private tightening (§ below) cannot regress either of them. The four
remaining active users are system/integration accounts (Automated Process, Platform Integration
User, Data.com Clean) or Chatter Free (no object access relevant here) — none are affected by
custom-object OWD.

This is a **stronger result than the spec anticipated** — spec Risk R1 was framed as "existing
personas may lack View All under the new Private OWD" as a hypothetical regression against
*power users generally*. In this org's actual current state, there are no non-admin human users
to regress at all. (The spec's underlying audit finding — that `Property_Management_Access` lacks
`viewAllRecords` on `Broker_Assignment__c`/`Lease_Activity__c`/`Lease_Inquiry__c`/`Lease__c`/
`Onboarding__c`/`Property_Asset__c`, and `Transaction_App_Access` lacks it on both its objects —
is still true and still worth fixing before any *future* non-admin power user is provisioned on
those sets, but it is not a blocker for the 2 users this build is for.)

---

## 1. Create the 2 users

**Recommended path: Setup UI** (matches the architecture spec's own guidance — activation email
and license assignment are org operations, not source-deployable). **Activation emails WILL
send** to the addresses below the moment each user is created — confirm the user wants this
before proceeding.

Setup → Users → New User, for each of:

| Field | Junior Dhanani | Nikhil Dhanani |
|---|---|---|
| First Name / Last Name | Junior / Dhanani | Nikhil / Dhanani |
| Alias | `jdhan` | `ndhan` |
| Email | `usmankhan-96@hotmail.com` | `usmanthehitman@gmail.com` |
| Username | `junior.dhanani@usmandpeg.uat` (suffix `.01` etc. if globally taken) | `nikhil.dhanani@usmandpeg.uat` (suffix if taken) |
| Role | `Acquisitions Analyst` | `DPEG Principal` |
| User License | Salesforce | Salesforce |
| Profile | Minimum Access - Salesforce | Minimum Access - Salesforce |
| Locale/Timezone/Language | org defaults | org defaults |
| Generate new password / notify | checked (sends activation email) | checked |

**CLI alternative** (`sf data create record` — only after the roles from this build are deployed;
substitute `<Acquisitions_Analyst_RoleId>` / `<DPEG_Principal_RoleId>` from a query first):

```bash
# 1. Resolve Ids (Minimum Access - Salesforce ProfileId already resolved: 00eiw0000005gEoAAI)
sf data query -o usman-dpeg -q "SELECT Id, Name FROM UserRole WHERE Name IN ('Acquisitions Analyst','DPEG Principal')"

# 2. Create Junior (replace <ACQ_ANALYST_ROLE_ID>)
sf data create record -o usman-dpeg --sobject User --values "FirstName='Junior' LastName='Dhanani' Alias='jdhan' Email='usmankhan-96@hotmail.com' Username='junior.dhanani@usmandpeg.uat' ProfileId='00eiw0000005gEoAAI' UserRoleId='<ACQ_ANALYST_ROLE_ID>' TimeZoneSidKey='America/Chicago' LocaleSidKey='en_US' EmailEncodingKey='UTF-8' LanguageLocaleKey='en_US'"

# 3. Create Nikhil (replace <DPEG_PRINCIPAL_ROLE_ID>)
sf data create record -o usman-dpeg --sobject User --values "FirstName='Nikhil' LastName='Dhanani' Alias='ndhan' Email='usmanthehitman@gmail.com' Username='nikhil.dhanani@usmandpeg.uat' ProfileId='00eiw0000005gEoAAI' UserRoleId='<DPEG_PRINCIPAL_ROLE_ID>' TimeZoneSidKey='America/Chicago' LocaleSidKey='en_US' EmailEncodingKey='UTF-8' LanguageLocaleKey='en_US'"
```

Note: `sf data create record` against `User` still triggers the activation email exactly like the
UI does — there is no silent-create option. Confirm timezone/locale defaults match the org's
actual defaults (`America/Chicago`/`en_US` above are placeholders — verify in Setup → Company
Information before running).

**Username global-uniqueness:** both usernames were confirmed absent from *this* org (`SELECT
Username FROM User WHERE Username LIKE '%dhanani%'` → 0 rows), but usernames are unique
**across every Salesforce org globally**, so a collision can only be discovered at create time.
If creation fails with `DUPLICATE_USERNAME`, suffix per spec (`.01`, `.02`, …).

---

## 2. Standard-object OWD — Lead → Private; confirm Opportunity unchanged

**Recommended path: Setup UI only.** Standard-object OWD is not part of this build's
`object-meta.xml` edits (only custom objects carry a deployable `<sharingModel>`). It is
technically possible to deploy standard-object OWD via the `SecuritySettings`
(`settings/Security.settings-meta.xml`) metadata type, **but this repo's `.forceignore` excludes
`settings/**` from source-format deploys** (a prior session's finding: a source deploy touching
that path reports false success without changing anything — the fix, if ever needed, is
`--metadata-dir` with a raw MDAPI package, not `--source-dir`). Given that trap, use the UI:

1. Setup → **Security → Sharing Settings**.
2. Note the current **Opportunity** OWD value (expected `Public Read/Write` per design-doc
   assumption — **verify, do not assume**). **Take no action on Opportunity** — leave as-is
   (OQ4, confirmed).
3. Click **Edit**. Change **Lead** → **Private**. **Save.**
4. This triggers an org-wide sharing recalculation — on a real EE org with live data this can
   take noticeable time; do not run the persona acceptance test until the recalculation job
   completes (Setup → Sharing Settings shows a recalculation-in-progress banner while running).
5. After recalculation completes, re-open Sharing Settings and confirm **Grant Access Using
   Hierarchies** is still checked for the 28 custom masters (default; should be unaffected by
   this change, but verify per spec §1d).

---

## 3. Add Junior to the `Acquisition` queue

The queue metadata deployed by this build (`Acquisition.queue-meta.xml`) creates the queue shell
and its 2 `queueSobject` entries (Lead, Property__c) but **carries no members** — this repo's
only other queue (`Broker_Portal_Leads`) shows the same pattern (no `<queueMembers>` in its
source file despite having real members in the org), so membership does not round-trip through
this org's metadata retrieve/deploy path. Add Junior in-org after both the queue and Junior's user
record exist:

**Setup UI:** Setup → Queues → **Acquisition** → Queue Members → add **Junior Dhanani** to
Selected Users → Save.

**CLI alternative** (queue is a `Group` record with `Type='Queue'`; membership is a `GroupMember`
row):

```bash
# 1. Resolve the queue's Group Id and Junior's User Id
sf data query -o usman-dpeg -q "SELECT Id, Name FROM Group WHERE Type='Queue' AND Name='Acquisition'"
sf data query -o usman-dpeg -q "SELECT Id FROM User WHERE Username='junior.dhanani@usmandpeg.uat'"

# 2. Insert the membership row
sf data create record -o usman-dpeg --sobject GroupMember --values "GroupId='<QUEUE_GROUP_ID>' UserOrGroupId='<JUNIOR_USER_ID>'"
```

**Also add both roles to the public group** `DPEG Acquisitions Team` — the deployed
`Group.group-meta.xml` shell also carries no membership (public-group membership, like queue
membership, is not a deployable field on the `Group` metadata type despite what an earlier draft
of the spec assumed — see the build report for the correction). Add via Setup UI: Setup → Public
Groups → **DPEG Acquisitions Team** → Add: **Role and Subordinates: Acquisitions Analyst**, and
**Role: DPEG Principal**. This step is **load-bearing for the 7 sharing rules (SR-01..07)** — they
target this group, so the sharing rules are inert until the group has real membership.

---

## 4. Assign the Permission Set Groups

**Setup UI:** Setup → Users → open Junior → Permission Set Group Assignments → Edit Assignments
→ add **DPEG Junior Analyst PSG**. Repeat for Nikhil → **DPEG Principal PSG**.

**CLI:** modern `sf` (`sf org assign permset`) resolves either a `PermissionSet` or a
`PermissionSetGroup` developer name passed to `--name`, but this is version-dependent — verify
with `sf --version` / a dry run first. If it does not resolve the group:

```bash
sf org assign permset -o usman-dpeg --name DPEG_Junior_Analyst_PSG --on-behalf-of junior.dhanani@usmandpeg.uat
sf org assign permset -o usman-dpeg --name DPEG_Principal_PSG --on-behalf-of nikhil.dhanani@usmandpeg.uat
```

**Guaranteed fallback if that fails** — a PermissionSetGroup's *effective* grant is delivered
through an auto-generated aggregate `PermissionSet` record (`Type='Group'`,
`PermissionSetGroupId=<the PSG's Id>`) that Salesforce creates once the PSG deploys and its
member sets are all active/non-erroring. Assign that record directly:

```bash
sf data query -o usman-dpeg -q "SELECT Id FROM PermissionSet WHERE PermissionSetGroupId IN (SELECT Id FROM PermissionSetGroup WHERE DeveloperName='DPEG_Junior_Analyst_PSG')"
sf data create record -o usman-dpeg --sobject PermissionSetAssignment --values "AssigneeId='<JUNIOR_USER_ID>' PermissionSetId='<AGGREGATE_PERMSET_ID>'"
# repeat for DPEG_Principal_PSG / Nikhil
```

**Do this step before the approval repoint below** — Nikhil needs `DPEG_Acquisition_View`'s Read
+ View All on Opportunity (delivered via his PSG) before he can be validated as a live, working
approver.

---

## 5. Repoint the 2 approval processes to Nikhil

**Live-org verification (run first — repo vs. org drift is possible):**

```bash
sf project retrieve start -o usman-dpeg -m "ApprovalProcess:Opportunity.LOI_Approval" "ApprovalProcess:Opportunity.Underwriting_Approval"
```

Then diff the retrieved files against `force-app/main/default/approvalProcesses/`. **Confirmed
during this build session** (repo state, 2026-07-22): both processes are `active=true`,
`allowRecall=true`, `recordEditability=AdminOnly`, single step, two approvers
(`usman.khan.dpeg@avanzasolutions.com` + `aftab.ali.dpeg.usman@avanzasolutions.com`),
`whenMultipleApprovers=Unanimous`. Re-verify this still matches the live org before editing —
do not assume the repo is current.

**Recall any pending requests** (an active process cannot be deactivated while requests are
pending):

```bash
sf data query -o usman-dpeg -q "SELECT Id, Status, TargetObjectId FROM ProcessInstance WHERE Status='Pending'"
```

If any rows return, recall each via Setup UI (open the target Opportunity → Approval History
related list → Recall) — there is no direct CLI recall command.

**Two-pass metadata edit per process** (an active process's steps cannot be edited in the same
deploy that keeps it active):

**Pass 1 — deactivate only.** Edit `<active>true</active>` → `<active>false</active>` in both
`Opportunity.LOI_Approval.approvalProcess-meta.xml` and
`Opportunity.Underwriting_Approval.approvalProcess-meta.xml`. Deploy:

```bash
sf project deploy start -o usman-dpeg -d "force-app/main/default/approvalProcesses/Opportunity.LOI_Approval.approvalProcess-meta.xml" "force-app/main/default/approvalProcesses/Opportunity.Underwriting_Approval.approvalProcess-meta.xml"
```

**Pass 2 — edit approver + reactivate.** In both files: remove the
`usman.khan.dpeg@avanzasolutions.com` `<approver>` block, add
`nikhil.dhanani@usmandpeg.uat` (or its actual suffixed username if it collided) as an `<approver>`
of `<type>user</type>`; **leave** the `aftab.ali.dpeg.usman@avanzasolutions.com` approver and
`<whenMultipleApprovers>Unanimous</whenMultipleApprovers>` untouched; set `<active>true</active>`.
Example diff shape for the `LOI_Approval_Step` (`Underwriting_Approval`'s
`Principal_Review_Step` is identical in shape):

```xml
<assignedApprover>
    <approver>
        <name>nikhil.dhanani@usmandpeg.uat</name>   <!-- was usman.khan.dpeg@avanzasolutions.com -->
        <type>user</type>
    </approver>
    <approver>
        <name>aftab.ali.dpeg.usman@avanzasolutions.com</name>   <!-- unchanged -->
        <type>user</type>
    </approver>
    <whenMultipleApprovers>Unanimous</whenMultipleApprovers>   <!-- unchanged -->
</assignedApprover>
```

Deploy pass 2 the same way as pass 1. **Prerequisite:** Nikhil's user must already exist, be
active, hold a Salesforce license, and have his `DPEG_Principal_PSG` assigned (→ Read + View All
on Opportunity) before pass 2 deploys — an approval process cannot reference a user who can't read
the object, and the ghost `usman.khan.dpeg` reference is intentionally left un-modified as a user
record (out of scope; it is simply no longer referenced by either process after pass 2).

**Verify:** as Junior, submit a test Opportunity into the LOI stage, then Underwriting stage;
confirm both Nikhil and Ali receive the approval request and Unanimous holds (one rejection ends
it). Full persona acceptance-test checklist is in `agent-output/rbac-architecture-spec.md` §10b —
run it after every step above is complete, not as an admin smoke test (FLS/OWD gaps are invisible
to an admin/System-Administrator tester, per §0 above and spec R9).

---

## Summary of execution order

1. (Prerequisite, not in this runbook) Deploy this session's metadata build via `salesforce-devops`.
2. §0 Pre-flight — **already done, no action required.**
3. §1 Create Junior + Nikhil users.
4. §2 Lead OWD → Private (Sharing Settings UI); confirm Opportunity untouched.
5. §3 Add Junior to `Acquisition` queue; add both roles' membership to `DPEG Acquisitions Team`.
6. §4 Assign PSGs (Junior → Junior PSG, Nikhil → Principal PSG).
7. §5 Repoint `LOI_Approval` + `Underwriting_Approval` to Nikhil (recall → deactivate → edit → reactivate, both processes).
8. Run the §10b persona acceptance test as Junior, then as Nikhil.
