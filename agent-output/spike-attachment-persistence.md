# Spike Findings — Inbound Broker-Email Attachment Persistence

**Org:** `usman-dpeg` (`00Diw000000Fqw1EAC`), connected as `usman.khan.dpeg@avanzasolutions.com` (System Administrator)
**Date:** 2026-08-05
**Scope:** Investigation only, per instructions. **No metadata deployed to `force-app/`, no feature code written.** One throwaway diagnostic Apex package (2 classes) was deployed *outside* `force-app/` to a scratch MDAPI directory solely to run a `System.runAs()` probe, then deleted — see the methodology note under C1/C3.
**Cleanup:** Confirmed complete — see [Cleanup Verification](#cleanup-verification) at the end. Nothing under `Inbound_Email_Staging__c`, `Property_Registry__c`, `Competing_Broker_Submission__c`, or any real Lead/Opportunity was touched.

---

## Summary table

| # | Question | Answer | Confidence |
| --- | --- | --- | --- |
| C3 | Can the Email Service user create Content at all? | **YES — no permission-set change needed.** Content objects carry zero `ObjectPermissions`/`FieldPermissions` rows org-wide; access is governed by license type, and junior holds a full `Salesforce` license. | High (structural, org-wide, corroborated by a test-context runtime probe as junior) |
| C1 | Does a CDL insert succeed onto a record the running user cannot see? | **The scenario named in the design (a different broker's winning Lead) does not exist as a sharing risk in this org**, because junior's PSG already grants `PermissionsViewAllRecords = true` on both `Lead` and `Opportunity` — the only two object types this feature will ever link files to. `without sharing` is therefore not load-bearing for the feature *as scoped*, though it remains a correct, cheap, future-proofing choice. See caveat below — the abstract "does `without sharing` bypass a genuine access gap" mechanism was not cleanly isolated. | High for the feature's actual scope; **not fully isolated** for the general mechanism (see caveat) |
| C2 | Which `ShareType` values are legal? | `'I'` and `'V'` both succeed on Lead, Opportunity, and `Inbound_Email_Staging__c`. `'C'` (Collaborator) is **rejected** everywhere tested — `INSUFFICIENT_ACCESS_OR_READONLY, Invalid sharing type C`. `FirstPublishLocationId` at insert time (D2) auto-creates **two** CDLs: one to the named record (`ShareType='V'`) and one to the creating user (`ShareType='I'`). | High (direct runtime measurement, admin) |
| F0 | Where do files go on Lead conversion? | **ALL THREE** — Account, Contact, **and** Opportunity — via platform lead-conversion behavior, automatically, with no custom code. The Lead's own link is removed post-conversion. | High (direct runtime measurement, admin, real `Database.convertLead`) |

**Headline implication for the design doc:** F0's "F-1: do nothing, rely on platform carry-over" option was rejected in the design on the premise that files might reach only the Contact. That premise is **empirically wrong on this org** — the platform already carries files to Account, Contact, *and* Opportunity. This significantly weakens the case for `LeadFileCarryOverService` (F-2) — see the F0 section for the full argument, which the design author should read before finalizing decision F1.

---

## C3 — Can the Email Service user create Content at all?

### Structural evidence (runtime, SOQL, admin session — but object-level, not persona-specific)

```sql
SELECT SobjectType, COUNT(Id) cnt FROM ObjectPermissions
WHERE SobjectType IN ('ContentVersion','ContentDocument','ContentNote','ContentWorkspace','ContentDocumentLink')
GROUP BY SobjectType
```
**Result:** `totalSize: 0` — **zero rows, org-wide, across every profile and permission set including System Administrator's own.**

```sql
SELECT SobjectType, Field, COUNT(Id) cnt FROM FieldPermissions
WHERE SobjectType IN ('ContentVersion','ContentDocument') GROUP BY SobjectType, Field
```
**Result:** `totalSize: 0` — zero `FieldPermissions` rows too.

**Interpretation:** Content objects (`ContentVersion`/`ContentDocument`/`ContentNote`/`ContentWorkspace`) are **not governed by the classic object/field permission grid in this org at all** — this is standard, documented Salesforce Files behavior (distinct from the older "Salesforce CRM Content" library feature, which *does* use permission sets). Access to create/read basic Files is instead a function of **user license type**. This is the *same class of finding* as the org's existing Task `ObjectPermissions` quirk (0 rows org-wide, confirmed in prior work — see `[[rbac-metadata-patterns]]`), but for a different, platform-documented reason (license-gated feature vs. an org-specific Task quirk).

### junior.dhanani's license (runtime, SOQL, admin session)

```sql
SELECT Id, Username, ProfileId, Profile.Name, Profile.UserLicense.Name, Profile.UserLicense.LicenseDefinitionKey
FROM User WHERE Username='junior.dhanani@usmandpeg.uat'
```
**Result:** Profile = `Minimum Access - Salesforce`, **`UserLicense.Name = 'Salesforce'`, `LicenseDefinitionKey = 'SFDC'`** — a full internal Salesforce license, not Chatter Free/External/Platform (those licenses *do* restrict file-related actions; a full `Salesforce` license does not).

### Decisive empirical confirmation — TEST CONTEXT, System.runAs(junior)

Since `System.runAs` cannot execute outside `@isTest` (confirmed dead end, re-confirmed this session — see methodology note under C1), a throwaway `@isTest` class was deployed **outside `force-app/`** to a scratch MDAPI package, executed, and then deleted. Relevant excerpt (full class in the C1 section below):

```apex
System.runAs(junior) {
    ContentVersion cv = new ContentVersion(Title = 'ZZSpike C3 Test As Junior', PathOnClient = 'zzspike_c3_junior.txt', VersionData = Blob.valueOf('...'));
    insert cv;   // <-- this is the C3 probe
    ...
}
```

**Debug log (TEST CONTEXT):**
```
USER_DEBUG ZZSPIKE_C3=SUCCESS docId=069iw0000009x8vAAA
```

### ANSWER
**Yes — junior.dhanani@usmandpeg.uat can insert a `ContentVersion` today, with zero permission-set changes.** No object/field permission grant exists to add because the platform doesn't gate this capability that way for a full-license internal user. **Recommendation:** drop decision C3's implied "add a permission-set grant" step from the design entirely — there is nothing to grant. (§3.3 of the design doc can be simplified accordingly.)

**Caveat:** this was measured in test context, consistent with C1's caveat below. Real UAT (sending a live email through the deployed pipeline) remains the only way to fully rule out the kind of test-vs-runtime divergence this repo has measured twice before for other content/platform DML. Given the result is also corroborated by a structural, org-wide, license-based explanation (not a narrow permission grant that could behave differently under different code paths), confidence here is high despite the test-context caveat.

---

## C1 — Does a `ContentDocumentLink` insert succeed onto a record the running user cannot see?

### Methodology note (read before the results)

`System.runAs()` is a hard, permanent Apex-language restriction to `@isTest` methods — re-confirmed this session (identical `System.TypeException: System.runAs can only be used within a test method` when attempted in plain anonymous Apex, matching prior repo memory). There is no way to execute code as `junior.dhanani` at genuine runtime without either (a) a real `@isTest` + `System.runAs`, or (b) an actual login-as/UAT session (out of scope for this spike — no interactive UI access here).

Per the task's own critical-methodology instruction — this repo has **two independently measured precedents** where content/platform DML behaves differently in test context than at runtime (`EmailMessage.RelatedToId` refuses updates only in test context; a Lead-lookup-to-converted-Lead is unenforced only in test context) — a test-context `System.runAs` result for CDL/sharing behavior must be reported as a **signal, not a proof**. I deployed one throwaway diagnostic package (`ZZSpikeCdlAccessTest.cls` + `ZZSpikeWithoutSharingLinker.cls`) to a scratch MDAPI directory **outside `force-app/`**, ran it, captured the debug log, and deleted both classes via a destructive-changes deploy immediately after (confirmed deleted, see cleanup section). This is the same class of temporary/throwaway diagnostic Apex the repo's own memory already documents using for permission verification; nothing was added to the committed source tree.

### The test

```apex
@isTest
private with sharing class ZZSpikeCdlAccessTest {
    @isTest
    static void spike_c1_c3_contentAccessAsJunior() {
        User junior = [SELECT Id FROM User WHERE Username = 'junior.dhanani@usmandpeg.uat' LIMIT 1];
        Lead noAccessLead = new Lead(LastName='ZZSpikeNoAccessTest', Company='ZZSpikeNoAccessCo', LeadSource='Other');
        insert noAccessLead;   // owned by the executing admin context, NOT junior

        System.runAs(junior) {
            List<Lead> visible = [SELECT Id FROM Lead WHERE Id = :noAccessLead.Id];   // baseline read check
            ContentVersion cv = new ContentVersion(...); insert cv;                    // C3
            Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id=:cv.Id].ContentDocumentId;

            insert new ContentDocumentLink(LinkedEntityId=noAccessLead.Id, ContentDocumentId=docId,
                ShareType='I', Visibility='AllUsers');                                 // C1a — WITH SHARING (this class's own declaration)

            ContentVersion cv2 = new ContentVersion(...); insert cv2;
            Id docId2 = [...].ContentDocumentId;
            ZZSpikeWithoutSharingLinker.link(noAccessLead.Id, docId2, 'I');            // C1b — WITHOUT SHARING helper class
        }
    }
}

public without sharing class ZZSpikeWithoutSharingLinker {
    public static void link(Id linkedEntityId, Id contentDocumentId, String shareType) {
        insert new ContentDocumentLink(LinkedEntityId=linkedEntityId, ContentDocumentId=contentDocumentId,
            ShareType=shareType, Visibility='AllUsers');
    }
}
```

### Result (TEST CONTEXT — deploy job `0Afiw000000FFMyCAO`, debug log `07Liw0000008UvOEAU`)

```
ZZSPIKE_READ_ACCESS=ROWS=1
ZZSPIKE_C3=SUCCESS docId=069iw0000009x8vAAA
ZZSPIKE_C1_WITH_SHARING=SUCCESS
ZZSPIKE_C1_WITHOUT_SHARING=SUCCESS docId2=069iw0000009x8wAAA
```

**Both the `with sharing` insert AND the `without sharing` insert succeeded — but this does NOT mean `without sharing` was the reason.** `ZZSPIKE_READ_ACCESS=ROWS=1` is the tell: junior could **already read** the "no access" Lead via a completely ordinary query, before any sharing-bypass mechanism was even invoked. The test's premise — "a record junior cannot see" — was false. I traced why:

```sql
SELECT SobjectType, ParentId, Parent.Name, PermissionsRead, PermissionsEdit, PermissionsViewAllRecords
FROM ObjectPermissions
WHERE SobjectType='Lead' AND ParentId IN (<all 7 of junior's assigned PermissionSet/PSG Ids>)
```
**Result:** `DPEG_Junior_Analyst_PSG` grants **`PermissionsViewAllRecords = true`** on Lead (alongside Read/Edit). I re-ran the identical query for `Opportunity` and got the same result: **`PermissionsViewAllRecords = true`** via the same PSG. I additionally checked `Inbound_Email_Staging__c` (**`PermissionsViewAllRecords = false`** via `Broker_Protection_Access` — genuinely narrower), `Contact` (`true`, redundant with `Account`'s public OWD anyway), `Onboarding__c`/`Transaction__c`/`Disposition__c` (all `true`), and `Competing_Broker_Submission__c`/`Property_Claim_Lock__c`/`Property_Registry__c` (all `true`, permissions-only check, no data touched).

### ANSWER

**The specific risk the design worried about ("branch (d), a different broker's winning Lead") is not a real sharing gap on this org.** `junior.dhanani`'s `DPEG_Junior_Analyst_PSG` already grants `ViewAllRecords = true` on **both** object types this feature will ever call `linkTo()` against — `Lead` and `Opportunity`. A plain `with sharing` CDL insert onto *any* Lead or Opportunity in the org, owned by anyone, already succeeds today, with no `without sharing` declaration required. This is corroborated structurally (the `ObjectPermissions` query, independent of test-context risk) and empirically (both runAs branches succeeded).

**What was NOT decisively isolated:** because `ViewAllRecords` explains both successes equally, this test does not cleanly prove that `without sharing` + `Database.insert(links, false)` would *also* succeed against a record with a genuine access gap (no ownership, no `ViewAllRecords`, no sharing rule). I looked for a real object in this feature's target scope with that shape and found none — every object the routing tree could plausibly link a file to (`Lead`, `Opportunity`, `Contact` via `ViewAllRecords`; `Account` via public Read/Write OWD) is already broadly visible to junior through one mechanism or another. `Inbound_Email_Staging__c` (`ViewAllRecords=false`) is the one narrower object, but the design's own staging link only ever targets the row `InboundEmailStagingService` *just created in the same transaction* — junior owns that row by construction, so ownership (not sharing) governs it regardless.

### RECOMMENDATION

- **Ship `without sharing` on `InboundEmailAttachmentService` anyway**, exactly as the design proposes — it costs nothing, matches the `EmailThreadGuardService`/`EmailThreadAdopterService` precedent, and is the correct defensive choice if a future object without blanket `ViewAllRecords` ever enters the routing target list (e.g. if the RBAC model is later tightened, or a new record type is added to `orderedTaskTargets()`).
- **Downgrade decision C1 from "blocking spike" to "resolved — no fallback needed."** The fallback described in the design ("link only to the staging row and the winner's own Lead") is not needed for the feature as currently scoped.
- **Flag for the RBAC owner, not this feature:** `DPEG_Junior_Analyst_PSG` granting blanket `ViewAllRecords=true` on Lead/Opportunity/Contact/Onboarding/Transaction/Disposition is a much broader grant than "Junior=edit Acq/Disp+view Txn/PM" (the persona description in this repo's own memory) suggests at first read — worth a conscious confirmation from whoever owns the RBAC model that this is intended, since it is precisely what makes C1 a non-issue. Not fixed or flagged as a defect here — reported as context.
- **Residual, for the record:** if a future feature needs to prove the abstract "does `without sharing` bypass a genuine access gap" mechanism on this org, it will need a real object where junior has zero `ViewAllRecords` and zero ownership — none of Broker Protection's own objects qualify (all `ViewAllRecords=true`), so that test would need to reach outside this module's object family.

---

## C2 — ShareType behaviour

All measured **at runtime**, admin session, real (throwaway) records — no test-context caveat applies here since these are pure platform-mechanics questions, not persona-specific.

### Script and raw results

```apex
// ShareType 'I' onto a Lead
insert new ContentDocumentLink(LinkedEntityId=l1.Id, ContentDocumentId=doc1, ShareType='I', Visibility='AllUsers');
// -> C2_LEAD_SHARETYPE_I=SUCCESS

// ShareType 'V' onto the same Lead (different document)
insert new ContentDocumentLink(LinkedEntityId=l1.Id, ContentDocumentId=docB, ShareType='V', Visibility='AllUsers');
// -> C2_LEAD_SHARETYPE_V=SUCCESS

// ShareType 'V' onto a throwaway Inbound_Email_Staging__c row
insert new ContentDocumentLink(LinkedEntityId=s1.Id, ContentDocumentId=docC, ShareType='V', Visibility='AllUsers');
// -> C2_STAGING_SHARETYPE_V=SUCCESS

// ShareType 'I' onto the same staging row (extra data point)
insert new ContentDocumentLink(LinkedEntityId=s1.Id, ContentDocumentId=docD, ShareType='I', Visibility='AllUsers');
// -> C2_STAGING_SHARETYPE_I=SUCCESS

// ShareType 'C' (Collaborator) onto a Lead — negative control
insert new ContentDocumentLink(LinkedEntityId=l1.Id, ContentDocumentId=docF, ShareType='C', Visibility='AllUsers');
// -> System.DmlException: INSUFFICIENT_ACCESS_OR_READONLY, Invalid sharing type C: [ShareType]

// Opportunity leg (from the F0 conversion's real new Opportunity)
insert new ContentDocumentLink(LinkedEntityId=oppId, ContentDocumentId=docOpp, ShareType='I', Visibility='AllUsers');
// -> C2_OPPORTUNITY_SHARETYPE_I=SUCCESS
```

### D2 — `FirstPublishLocationId` at ContentVersion insert time

```apex
ContentVersion cvE = new ContentVersion(Title='...', PathOnClient='...', VersionData=Blob.valueOf('...'), FirstPublishLocationId = l1.Id);
insert cvE;
List<ContentDocumentLink> autoLinks = [SELECT LinkedEntityId, ShareType, Visibility FROM ContentDocumentLink WHERE ContentDocumentId = :docE];
```
**Result:** `D2_AUTO_CDL_COUNT=2`
```
LinkedEntityId=<Admin User Id>   ShareType=I  Visibility=AllUsers   (the owner's personal library — automatic on every ContentVersion insert)
LinkedEntityId=<Lead L1 Id>      ShareType=V  Visibility=AllUsers   (the FirstPublishLocationId target)
```

### ANSWER
- **`'I'` and `'V'` are both legal** on `Lead`, `Opportunity`, and `Inbound_Email_Staging__c` — the design's proposed split (`'I'` for routed records, `'V'` for the staging link) is technically valid; nothing blocks it.
- **`'C'` (Collaborator) is rejected** with `INSUFFICIENT_ACCESS_OR_READONLY, Invalid sharing type C` — expected, since Collaborator is a Library/Workspace concept, not applicable to a plain record link. Not proposed by the design, confirmed as a negative control only.
- **D2 (`FirstPublishLocationId`) works, but it does NOT save a DML statement the way the design hoped, AND it produces `ShareType='V'`, not `'I'`.** It auto-creates **two** CDL rows in the same insert (owner link + target link), and the target link's `ShareType` is hardcoded by the platform to `'V'` — the design would need to accept `'V'` for the routed-record leg too if it adopts D2, contradicting its own recommendation of `'I'` for routed records. **Recommendation: do NOT adopt D2 (option ii, "carry `contentDocumentIds` on the constructor") is unaffected either way, but explicitly reject the `FirstPublishLocationId` shortcut for the staging leg** — it does not let the design choose `ShareType` per the D-OPTION table, and it adds an extra, uncontrolled CDL (the owner link) that the design's row-count arithmetic in §D did not budget for.

---

## F0 — Lead conversion file carry-over

**Measured at runtime**, admin session, real `Database.convertLead` call on a throwaway Lead.

### Script (abbreviated — full script included every field needed to pass this org's `Property_And_Email_Required_To_Convert` validation rule)

```apex
Lead l2 = new Lead(LastName='ZZSpikeL2ConvertDeleteMe', Company='ZZSpikeConvertCoDeleteMe', LeadSource='Other',
    Status='New', Email='zzspike2.deleteme@example.invalid', Property_Address__c='123 ZZ Spike St, Delete Me, TX 00000');
insert l2;

ContentVersion cv = new ContentVersion(Title='ZZSpike2 CV PreConvert', ...);
insert cv;
Id doc = [SELECT ContentDocumentId FROM ContentVersion WHERE Id=:cv.Id].ContentDocumentId;
insert new ContentDocumentLink(LinkedEntityId=l2.Id, ContentDocumentId=doc, ShareType='I', Visibility='AllUsers');

Database.LeadConvert lc = new Database.LeadConvert();
lc.setLeadId(l2.Id);
lc.setConvertedStatus('Converted');   // the only IsConverted=true LeadStatus in this org
lc.setDoNotCreateOpportunity(false);
lc.setOpportunityName('ZZSpike2 Opp Delete Me');
Database.LeadConvertResult lcr = Database.convertLead(lc);

List<ContentDocumentLink> postConvertLinks = [SELECT LinkedEntityId, LinkedEntity.Type, ShareType, Visibility
    FROM ContentDocumentLink WHERE ContentDocumentId = :doc];
```

### Raw result

**First attempt failed** (informative in its own right): `System.DmlException: ConvertLead failed. ... FIELD_CUSTOM_VALIDATION_EXCEPTION, Validation error on Lead: Property Address and Email are both required before this lead can be converted.` — a real validation rule (`Property_And_Email_Required_To_Convert`) on this org. The entire anonymous-Apex transaction rolled back automatically (confirmed via a follow-up `SELECT COUNT(Id) FROM Lead WHERE Id=:leadId` returning `0`) — no cleanup was needed for that attempt.

**Second attempt (with `Email`/`Property_Address__c` populated) succeeded:**
```
CONVERT_SUCCESS=true
ACCOUNT_ID=001iw0000029dkDAAQ
CONTACT_ID=003iw000000bYFeAAM
OPPORTUNITY_ID=006iw000000L8NaAAK

F0_POSTCONVERT_CDL_COUNT=4
F0_POSTCONVERT_CDL LinkedEntityId=001iw0000029dkDAAQ Type=Account     ShareType=I Visibility=AllUsers
F0_POSTCONVERT_CDL LinkedEntityId=003iw000000bYFeAAM Type=Contact     ShareType=I Visibility=AllUsers
F0_POSTCONVERT_CDL LinkedEntityId=005iw0000006eHKAAY Type=User        ShareType=I Visibility=AllUsers   (owner's personal library, pre-existing, unrelated to conversion)
F0_POSTCONVERT_CDL LinkedEntityId=006iw000000L8NaAAK Type=Opportunity ShareType=I Visibility=AllUsers
```
**No row for the original Lead** (`00Qiw000000Uw6cEAC`) remains in this list — the pre-conversion Lead-CDL is gone, replaced by three new links (Account, Contact, Opportunity), all `ShareType='I'`.

### ANSWER

**The file follows to ALL THREE converted records — Account, Contact, AND Opportunity — automatically, via native Salesforce lead-conversion behavior. No custom Apex is required for this to happen on this org.** This is stronger than any of the four options the design considered:

| Design option | What it assumed | What actually happens |
| --- | --- | --- |
| F-1 (do nothing) | **Rejected** because "even if files carry to the Contact, that is insufficient... a file that reaches only the Contact has not reached the deal." | **The premise is false on this org.** The file already reaches the Opportunity too, with zero custom code. |
| F-2 (separate `LeadFileCarryOverService`, +1 SOQL/+1 DML) | Needed to bridge Lead→Opportunity because the platform wouldn't do it alone. | **Already done by the platform.** Building F-2 would either be pure redundant work, or (worse) risk a *double* link if it doesn't check for the platform's own pre-existing link first — a real design hazard to flag if F-2 is still built. |
| F-3 (fold into `LeadConvertService`) | Rejected on separation-of-concerns grounds (correct regardless of this finding). | N/A — still correctly rejected. |
| F-4 (defer) | "Files then sit on the Lead and stop there." | **Also not what happens** — the Lead's own link is *removed* post-conversion, not merely left in place; deferring doesn't even preserve Lead-level access after conversion. |

### RECOMMENDATION

**Re-open decision F1 with the user before building anything.** Given the platform already does exactly what F-2 was designed to guarantee, the design should present the option of **F-1 (do nothing)** as newly viable and likely preferable — it removes an entire service class, its SOQL/DML budget, its `ContentDocumentLinkSelector.selectByLinkedEntityIds` addition, and its `LeadConvertTrigger` wiring, with no loss of functionality on this org. If the team wants defense-in-depth (e.g., in case this platform behavior is ever an opt-in setting that could be toggled off, or differs across Salesforce releases), F-2 could be kept as an idempotent **verification/repair** step rather than an assumed-necessary carry-over — but that is a materially smaller, different piece of code than what §4.7 currently describes, and should be scoped as such if the user still wants it. **This finding should be surfaced explicitly at the next Gate 1 checkpoint before F-2 is built as originally specified.**

One structural note worth carrying into that conversation: this **is** the org's real, org-wide `Database.convertLead` behavior (not a test-context artifact) — verified via the same real API every production Lead conversion in this org uses, with a real validation rule firing correctly along the way, which is itself independent evidence this was a genuine runtime execution and not degraded/mocked in any way.

---

## Cleanup verification

All throwaway records deleted, confirmed via direct re-query (not via retrieve, which would be an unreliable proxy for deletion — per this repo's own `[[retrieve-merges-picklist-values]]` precedent, deletions were verified by re-querying the object directly):

```
ZZCLEANUP VERIFY remainingDocs=0 remainingLeads=0 remainingStaging=0 remainingOpp=0
                  remainingProperty=0 remainingNda=0 remainingContact=0 remainingAccount=0
```

Additional broad sweeps confirming zero residue anywhere in the org:
```sql
SELECT COUNT(Id) FROM Lead WHERE LastName LIKE 'ZZSpike%'                        -- 0
SELECT COUNT(Id) FROM ContentVersion WHERE Title LIKE 'ZZSpike%'                 -- 0
SELECT COUNT(Id) FROM Inbound_Email_Staging__c WHERE Subject__c LIKE 'ZZSPIKE%'  -- 0
SELECT COUNT(Id) FROM ApexClass WHERE Name LIKE 'ZZSpike%'                       -- 0
```

The two throwaway diagnostic ApexClasses (`ZZSpikeCdlAccessTest`, `ZZSpikeWithoutSharingLinker`) were deployed via a standalone MDAPI package outside `force-app/` (deploy job `0Afiw000000FFMyCAO`) and deleted via a destructive-changes deploy (job `0Afiw000000FHwcCAG`, both components `state: Deleted`). The temporary `TraceFlag` created to capture the test's debug log was also deleted. Nothing under `force-app/` was created, modified, or touched at any point in this session.

**Untouched, as instructed:** `Inbound_Email_Staging__c` (real rows), `Property_Registry__c`, `Competing_Broker_Submission__c`, and every real Lead/Opportunity in the org. The only reads against `Property_Registry__c`/`Competing_Broker_Submission__c`/`Property_Claim_Lock__c` were `ObjectPermissions` metadata queries (permission structure only, zero data rows read or written).

---

## Ambiguities / things NOT fully resolved

1. **C1's general mechanism** (does `without sharing` bypass a *genuine* access gap, not just one masked by `ViewAllRecords`) was not isolated — see the caveat in the C1 section. Not blocking for this feature as scoped, but should not be cited as "without sharing is proven to bypass sharing on this org" beyond what was actually shown.
2. **All C1/C3 persona-specific results are test-context measurements** (`System.runAs`), per the hard platform restriction on `System.runAs` outside `@isTest`. They are corroborated by structural, non-test-context evidence (`ObjectPermissions` queries, license type) wherever possible, but the design doc's own §4.9 requirement — "a live UAT step as the Email Service persona is mandatory... do not accept an admin smoke test as evidence" — still stands and is not satisfied by this spike. This spike narrows the risk considerably; it does not replace UAT.
3. **D2's row-count/DML implications were not fully re-costed** — the discovery that `FirstPublishLocationId` creates 2 CDL rows (not the 1 the design's D-OPTION table assumed) means the design's §D budget table should be revisited if D2 is still considered, though this spike's recommendation is to reject D2 for the staging leg regardless (ShareType mismatch), which makes the point moot if that recommendation is accepted.
