# Design Requirements — Restore 3 failing Apex tests blocking RunLocalTests

Date: 2026-08-17
Scope class: bug fix (restore documented/intended behaviour). Touches the security model.
Status: **BLOCKED at Gate 1** — three decisions below require the user before any agent proceeds.

---

## 0. CONTRADICTED PREMISES (read first)

The brief's hypotheses were checked against the repo. Four are falsified.

### 0.1 No sharing rule is missing. Zero sharing-rule work is indicated.

The brief proposed "a sharing-rule criteria gap ... left over from the RBAC rollout". Both rules
the brief predicted would be missing already exist, with exactly the record-type criteria it
predicted would be absent:

| File | Rule | Criteria |
|---|---|---|
| `force-app/main/default/sharingRules/Lead.sharingRules-meta.xml` | `Lead_Acquisition_Broker` | `RecordTypeId` equals `Acquisition Broker` |
| `force-app/main/default/sharingRules/Lead.sharingRules-meta.xml` | `Lead_IR_Investor` | `RecordTypeId` equals `IR Investor` |
| `force-app/main/default/sharingRules/Account.sharingRules-meta.xml` | `Account_Broker_Firm_Internal_Acquisitions` | `RecordTypeId` equals `Broker Firm` |
| `force-app/main/default/sharingRules/Account.sharingRules-meta.xml` | `Account_Broker_Firm_Internal_Transactions` | `RecordTypeId` equals `Broker Firm` |
| `force-app/main/default/sharingRules/Account.sharingRules-meta.xml` | `Account_Broker_Firm_Internal_PropertyMgmt` | `RecordTypeId` equals `Broker Firm` |

Neither failing test asserts anything about sharing. Both assert only
`RecordType.DeveloperName`. The words "matches no sharing rule" appear in the assertion
**messages** as the rationale for *why the record type matters* — they are not the thing under
test. The brief read the rationale as the symptom.

### 0.2 The root cause recorded in `LeadConvertService.cls` is wrong, and it is why this is still broken

`force-app/main/default/classes/LeadConvertService.cls` lines 622-651 carry a "FIX ROUND 1
(2026-08-10) — DIAGNOSED: THIS IS A PROVISIONING GAP, NOT AN APEX DEFECT" block. It concludes the
org's `DPEG_Admin_Access` lacks the six IR-segregation `recordTypeVisibilities`, that
`isAvailable()` is therefore false, and that "no code change here can fix it."

Three independent repo facts falsify that:

1. **`DPEG_Admin_Access.permissionset-meta.xml` lines 389-410** carry a later, 2026-08-14
   de-duplication note recording a *measured* retrieve from `usman-dpeg`: the six record type
   visibilities **are live in the org** ("the first half was true"), and the file itself now holds
   each exactly once, all `<visible>true</visible>` (lines 422-469). Two same-day 2026-08-10
   "measured retrieves" reached opposite conclusions; the 2026-08-14 re-measurement settles it
   against the LeadConvertService note.
2. **`TestDataFactoryTest.factoryStampsAcquisitionSideRecordTypes`** (line 533) asserts that
   `Lead.Acquisition_Broker`, `Account.Broker_Firm` and `Contact.Broker` all stamp successfully on
   INSERT. It is **not** in the failing set. That is impossible if `isAvailable()` returned false
   for this principal.
3. **`TestDataFactory.cls` lines 313-319** state the opposite of the LeadConvertService note, in
   writing: "verified for the admin test-running user specifically (System Administrator returns
   `isAvailable()` = true for all three record types)".

Consequence: the prescribed remedy (a permission-set redeploy) was never going to work, and
anyone who follows that comment will burn a cycle re-deploying `DPEG_Admin_Access` — a file that
**replaces its entire `fieldPermissions` set on every deploy**. The comment is an active hazard and
must be corrected as part of this work.

### 0.3 Failure 1's actual mechanism: two components of the same 2026-08-10 change deadlock

`force-app/main/default/objects/Account/validationRules/Record_Type_Is_Immutable.validationRule-meta.xml`:

```
AND(
    NOT(ISNEW()),
    ISCHANGED(RecordTypeId)
)
```

`LeadConvertService.stampConvertedPartyRecordTypes` (line 673) stamps the converted Account with
`Database.update(accountUpdates, false)` — an **UPDATE**. On an update `ISNEW()` is false and
`ISCHANGED(RecordTypeId)` is true (null → `Broker_Firm`), so the rule fires, `allOrNone = false`
swallows the failure silently, and `RecordTypeId` stays null. Validation rules are not bypassed by
system-mode Apex DML, and this one deliberately does not consult `$Permission` (its own comment,
lines 13-16: "ADMINS ARE OUT OF SCOPE BY DESIGN ... `$Permission` is deliberately not consulted").

**The reported failure message corroborates this and rules out the permission theory.** The test
asserts Contact (line 666) *before* Account (line 669), and the reported failure is the **Account**
assertion — so the Contact stamp landed. A missing record-type grant would have failed the Contact
assertion first. Only an Account-UPDATE-specific blocker produces that asymmetry. The sibling rule
`Contact.Record_Type_Matches_Account` passes for the same reason: its
`NOT(ISBLANK(Account.RecordType.DeveloperName))` guard short-circuits precisely because the Account
is still unstamped.

Both rules and both Apex stamps shipped in the same 2026-08-10 IR-segregation change. They were
designed independently and interlock.

### 0.4 Failure 3 is not DPEG code, and not a guest-profile/permission gap

`MicrobatchSelfRegController` is Salesforce's **stock self-registration boilerplate**, retrieved
alongside the Broker Portal site. It still carries the shipped placeholders (`profileId = null`,
"to be filled by customer"). It is one of ~10 such classes in `classes/` (`CommunitiesSelfReg*`,
`SiteLogin*`, `SiteRegister*`, `ForgotPassword*`, `ChangePassword*`, `MyProfilePage*`, ...), all
using `@IsTest(SeeAllData=true)` — which ARCHITECTURE.md §2 forbids.

Mechanism: `registerUser()` calls `Network.createExternalUserAsync` (line 39), which throws
`System.NoAccessException`. The method's only catch is `catch (Site.ExternalUserCreateException)`,
so the exception escapes. Its sibling `CommunitiesSelfRegController` calls
`Site.createExternalUser`, whose exception **is** caught — which is exactly why
`CommunitiesSelfRegControllerTest` passes and this one does not. The test's own comment
("registerUser will always return null when the page isn't accessed as a guest user") is a false
assumption for the `Network.*` variant.

Supporting context — the feature is not in use and not deployable:
- `force-app/main/default/networks/DPEG Broker Portal.network-meta.xml`:
  `<selfRegistration>false</selfRegistration>`, `<status>UnderConstruction</status>`
- `.forceignore` lines 488-501 exclude `networks/**`, `sites/**`, `digitalExperiences/**` entirely.

So the site and network are force-ignored, self-registration is off, yet the class and its test
deploy and run under RunLocalTests. There is no guest profile or permission set to fix.

### 0.5 Also stale (flagging, not fixing)

`DPEG_Admin_Access.permissionset-meta.xml` lines 412-415 assert the Account/Contact record types
"exist in the ORG but have no recordType metadata in this repo". They do have repo metadata:
`objects/Account/recordTypes/{Broker_Firm,Investor_Entity}`,
`objects/Contact/recordTypes/{Broker,Investor}`, `objects/Lead/recordTypes/{Acquisition_Broker,IR_Investor}`,
all `<active>true</active>`.

---

## 1. ARE THESE ONE BUG OR THREE?

**Three distinct bugs, sharing one symptom in two of them.** The brief asked; the answer is not the
2-and-1 split it proposed.

| # | Test | Mechanism | Related to? |
|---|---|---|---|
| 1 | `LeadConvertServiceTest.conversionStampsBrokerRecordTypesOnContactAndAccount` | `Account.Record_Type_Is_Immutable` blocks the post-conversion UPDATE stamp; `allOrNone=false` hides it | Independent |
| 2 | `BrokerPortalServiceTest.submitDeal_createdLeadCarriesTheAcquisitionRecordType` | **Unconfirmed** — see §2, Gate B. Not the same mechanism as #1 (this is an INSERT, not an update, so `Record_Type_Is_Immutable` cannot apply and there is no Lead equivalent of it) | Independent |
| 3 | `MicrobatchSelfRegControllerTest.testMicrobatchSelfRegController` | Uncaught `NoAccessException` from `Network.createExternalUserAsync` in stock Salesforce boilerplate | Independent |

#1 and #2 look alike (both read back a null `RecordType.DeveloperName`) and were introduced by the
same 2026-08-10 change, but they fail on different code paths. Fixing #1 will not fix #2.

---

## 2. BLOCKING GATES — user decisions required before any implementation agent runs

### Gate A — Failure 1: which side of the deadlock gives?

This is a **security-model** decision, not a mechanical fix. Three shapes, and the repo's own
guidance rules one of them out:

- **A1. Gate the validation rule on a custom permission.** Add a custom permission, grant it to the
  automation principal, and change the rule to `AND(NOT(ISNEW()), ISCHANGED(RecordTypeId),
  NOT($Permission.<Name>))`. **This is what the rule's own comment prescribes**: "If an exemption
  is ever needed, add a custom permission and gate on `$Permission` — never widen the rule itself."
  ⚠ Needs a decision on *who* holds it; a permission held by every user is the same as no rule.
- **A2. Narrow the rule to permit only null → value.** e.g. also require
  `NOT(ISBLANK(PRIORVALUE(RecordTypeId)))`. Simplest, and it still blocks the reparenting the rule
  exists to prevent — but it **widens the rule**, which its comment explicitly forbids. Requires the
  user to overrule that written instruction knowingly.
- **A3. Stop stamping the Account by UPDATE.** Would require the record type to land at conversion
  time; `Database.convertLead` does not map record types (that is the stated reason the stamp exists
  at all), so this likely means an Account-side before-update/before-insert path — larger blast
  radius, and it does not remove the rule's conflict with any other admin-driven correction.

**Question 1: A1, A2, or A3? If A1, which principal(s) hold the custom permission?**

### Gate B — Failure 2: one measurement is needed before it can be scoped

I cannot resolve this from the repo, and I will not guess a fix for it.

What is established: `BrokerPortalService.submitDeal` (lines 98-101) sets `RecordTypeId` from
`EmailToLeadService.acquisitionBrokerRecordTypeId()` on an **insert**, and that helper returns null
only when the record type is absent or unavailable. But two sibling tests that depend on the same
helper/describe returning a valid, available id are **not** failing —
`EmailToLeadServiceTest` (line 565, same helper, same assertion) and
`TestDataFactoryTest.factoryStampsAcquisitionSideRecordTypes` (line 542). No Flow references
`RecordTypeId` anywhere in `flows/`, so nothing declarative is clearing it post-insert.

That combination is internally inconsistent and needs org measurement, not inference.

**Question 2: may a devops/measurement step run first** — a savepoint-wrapped anonymous-Apex probe
against `usman-dpeg` that, in one transaction, (a) prints
`EmailToLeadService.acquisitionBrokerRecordTypeId()`, (b) runs `BrokerPortalService.submitDeal`
with the test's own input, (c) reads back the Lead's `RecordTypeId` and `RecordType.DeveloperName`,
then rolls back — **before** failure 2 is assigned to any implementation agent?

Until that runs, failure 2 has **no** admin or developer work item. Do not let an agent invent one.

### Gate C — Failure 3: fix, delete, or exclude the stock boilerplate?

- **C1. Fix the class** — widen the catch in `MicrobatchSelfRegController.registerUser` to also
  catch `NoAccessException`. Smallest change; keeps the class working if self-registration is ever
  enabled. But it edits Salesforce-shipped boilerplate, which will be silently reverted by any
  future site retrieve.
- **C2. Delete `MicrobatchSelfRegController` + its test + `pages/MicrobatchSelfReg.page`.** The
  feature is off (`selfRegistration=false`) and the site is `UnderConstruction`. Cleanest, but
  irreversible-ish if the portal later turns self-registration on, and the page may be referenced by
  the force-ignored site config that is not visible in this repo.
- **C3. Add the class + test to `.forceignore`** so they neither deploy nor run. Consistent with how
  this repo already handles ~60 other pieces of unusable retrieved boilerplate — but leaves them in
  the org if they are already there, so RunLocalTests **against the org** would still run the test.
  ⚠ This option probably does **not** unblock the deploy; confirm before choosing it.

**Question 3: C1, C2, or C3?**

**Question 4 (scope):** the other ~9 stock Site/Communities classes all use `@IsTest(SeeAllData=true)`
in violation of ARCHITECTURE.md §2, and are the same class of artifact. Do you want them in scope,
or is this strictly the one failing test? **Default assumed: out of scope** — only the one failing
test is touched unless you say otherwise.

---

## 3. WHAT USER REQUESTED

Fix three pre-existing, currently-failing Apex tests in `usman-dpeg` that block any future
`RunLocalTests` deploy; separate admin from developer work; state whether the failures are related.
Bug-fix scope only — restoring documented/intended behaviour, no new functionality.

---

## 4. 🔵 ADMIN WORK (salesforce-admin)

**Conditional on Gate A.** Nothing below is authorised until Question 1 is answered.

- **If A1:** create one `CustomPermission`; add it to the permission set(s) named in the answer to
  Question 1; edit
  `objects/Account/validationRules/Record_Type_Is_Immutable.validationRule-meta.xml` to add the
  `NOT($Permission.<Name>)` term. Update the rule's in-file XML comment to record the exemption and
  why (the comment is the repo's decision record for this rule).
  ⚠ If the permission set chosen is `DPEG_Admin_Access`, a surgical edit + diff against HEAD is
  mandatory — that file replaces its entire `fieldPermissions` set on deploy, and its own header
  (lines 87-90) says to re-run the org diff before *every* deploy of it.
- **If A2:** edit the same validation rule's `errorConditionFormula` only, plus its XML comment
  recording that the "never widen the rule itself" instruction was knowingly overruled and by whom.
- **If A3:** no admin work; this becomes developer work.

**No sharing rule changes.** **No permission set `recordTypeVisibilities` changes.** **No OWD
changes.** All were checked and are already correct (§0.1, §0.2).

---

## 5. 🟢 DEVELOPMENT WORK (salesforce-developer)

- **Correct the false root-cause block in `force-app/main/default/classes/LeadConvertService.cls`
  (lines 622-651).** Replace the "PROVISIONING GAP ... no code change here can fix it" diagnosis
  with the measured finding in §0.3, and cross-reference `Account.Record_Type_Is_Immutable`. This is
  required regardless of which Gate A option is chosen — leaving it stands the next reader up to
  repeat a dead-end `DPEG_Admin_Access` redeploy. Comment-only change; no behaviour change.
- **If Gate A = A3 only:** re-shape the Account record-type stamp so it is not an UPDATE.
- **If Gate C = C1:** widen the catch in
  `force-app/main/default/classes/MicrobatchSelfRegController.cls` `registerUser()` to handle
  `NoAccessException`, preserving the existing `Site.ExternalUserCreateException` branch.
- **If Gate C = C2:** delete `MicrobatchSelfRegController.cls(-meta.xml)`,
  `MicrobatchSelfRegControllerTest.cls(-meta.xml)`, `pages/MicrobatchSelfReg.page(-meta.xml)`.
- **Failure 2:** no work item until Gate B's measurement returns.

**Not requested, therefore not included:** no new test methods, no test-class refactors, no
`SeeAllData=true` cleanup on the other boilerplate tests, no `Database.update` → throw change in
`stampConvertedPartyRecordTypes` (its `allOrNone = false` is deliberate and documented at lines
618-620; changing it is a separate decision, not a bug fix).

---

## 6. 🔗 EXECUTION ORDER

1. **Gate B measurement** (devops / anonymous Apex, savepoint-wrapped, rolled back) — resolves
   failure 2's scope. Independent of everything else; run first because it may add work.
2. **Gate A admin change** (validation rule ± custom permission) — must land before the
   `LeadConvertServiceTest` assertion can pass.
3. **Developer changes** — the `LeadConvertService.cls` comment correction, plus whichever of
   A3 / C1 / C2 was chosen. The comment correction depends on step 2 being decided (it must record
   the chosen resolution).
4. **Re-run the three tests specifically**, then `RunLocalTests`.

⚠ `salesforce-unit-testing` is **not** required: no new Apex logic is being written under C1/C2,
and no new trigger, batch or service method is introduced — so neither the 251-record bulk rule
nor the ContentPublication rule is engaged. Existing tests are the verification.

---

## 7. 📝 PROMPTS FOR SPECIALIST AGENTS

Held until Gates A, B and C are answered. Writing them now would bake in an assumed resolution to
a security-model decision that is the user's to make.

---

## 8. RISK NOTES

- Every change in §4 touches a rule whose stated purpose is preventing a cross-team data leak
  (Broker vs. Investor visibility). A1 and A2 both create a path by which an Account's record type
  can change after creation — that is the point, but it is the exact thing the rule was built to
  stop. It needs deliberate sign-off, not a silent fix.
- `Account.Record_Type_Is_Immutable` currently blocks **every** post-creation record-type
  correction, including a legitimate admin fixing a misfiled Account (the rule's comment claims
  admins are out of scope; they are not — validation rules ignore Modify All Data). Worth
  confirming whether that is still the intent.
- The `Broker_Portal_Leads` queue that `BrokerPortalService` depends on has **no** `queues/`
  metadata in this repo — it exists only in the org. Relevant to Gate B's measurement, and to any
  future scratch-org rebuild.
