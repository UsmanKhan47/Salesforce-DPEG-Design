# Design Requirements — SharePoint Deal Folder on Closed Won

**Date:** 2026-08-11
**Requested by:** akbar.zaidi@avanzasolutions.com
**Status:** 🚦 **GATE 1 — NOT READY TO IMPLEMENT.** Seven decisions (D1–D7) and one mandatory
spike (SP-1) must be answered first. SP-1's outcome *changes the architecture*, not just a
parameter — see §4.

---

## 1. WHAT THE USER REQUESTED

> "Create a class or flow — whatever is best — that creates a folder on our SharePoint site named
> after the property, when an Opportunity is Closed Won."

**IN SCOPE:** create one folder, named after the property, when an Opportunity **enters** `Closed Won`.

**OUT OF SCOPE (stated by the user):** the credential layer (already live), and the Disposition twin.

**NOT ADDED BY THIS DESIGN:** no notifications, no LWC, no report, no validation rule, no
permission-set-group restructuring beyond the one grant the feature cannot work without, no file
copying (that is decision D4 and the recommendation is "no").

---

## 2. RECOMMENDATION: APEX, NOT FLOW — ARGUED FROM THE REPO

The user believed Apex is correct. It is, but **not for the reason most likely to be assumed.**

### 2.1 The argument that does NOT work

The two-route problem (`StageAdvanceService.NEXT_STAGE` maps **both** `'PSA' ⇒ 'Closed Won'` and
`'About to Close' ⇒ 'Closed Won'`, verified at `StageAdvanceService.cls:98-106`) kills hanging the
feature off the **`Transaction_Complete_Close` flow** — that flow starts on `Transaction__c`, so a
deal driver clicking Advance Stage from `PSA` reaches Closed Won with no `Transaction__c` in the
picture at all. That is exactly why `PropertyAssetService` was put on the Opportunity trigger
(`PropertyAssetService.cls:19-27`).

But it does **not** kill Flow generally: a record-triggered Flow on `Opportunity` with entry
criteria `ISCHANGED(StageName) && StageName = 'Closed Won'` would catch both routes correctly. Say
this plainly rather than reusing the Tranche 5A argument where it does not apply.

### 2.2 The four arguments that do work

1. 🔴 **A per-record Flow cannot survive a bulk save. This is decisive.** A record-triggered Flow
   runs one interview per record. A 251-record update (the `.claude/rules/bulk-test-rule.md`
   mandate) would attempt 251 HTTP Callout actions in one transaction against a hard limit of
   **100 callouts per transaction** — the update fails and the deal close rolls back. Apex can
   enqueue **one** async job per trigger chunk carrying N deal Ids and meter the callouts inside
   it. Flow has no equivalent construct.
2. **ARCHITECTURE §2 Standards (Non-Negotiable):** *"all ASB/Plaid callouts wrapped in a dedicated
   service class ... so they can be mocked via `HttpCalloutMock`."* Flow's HTTP Callout action has
   **no test seam at all** — it cannot be mocked, so the 90% coverage target and the "prove the
   409/429/500 branches" requirement are unreachable. `LLMExtractionCalloutService` +
   `LLMExtractionCalloutMock` is the in-repo precedent.
3. **The work is not expressible declaratively.** Folder-name sanitization against SharePoint's
   illegal-character set, JSON request construction, HTTP status branching (201 / 409 / 429 / 5xx),
   a `System.Finalizer` for uncatchable failures, and a bounded-callout loop are all Apex-only.
4. **`.claude/rules/apex-layering-rule.md`** already governs where each piece goes; a Flow would put
   an external write in a layer the rules do not model.

### 2.3 Where the Apex hangs

**`OpportunityReviewTriggerHandler.route()` — a fifth service call, immediately after
`PropertyAssetService.ensureOnClosedWon`.** Same trigger point, same stage-ENTRY semantics, same
"handoff to another concern" argument that `ContractExecutionService` and `PropertyAssetService`
both won (`OpportunityReviewTriggerHandler.cls:39-57`).

🔴 **One ordering rule, and it is not about position in the method.** `PropertyAssetService`'s
insert is `allOrNone = true` and throws on failure *by design* — its silent absence was the bug.
The SharePoint feature is the opposite: **it must never throw, from anywhere in the synchronous
transaction**, because a SharePoint outage rolling back a Closed Won is strictly worse than a
missing folder. Placing it last does not achieve that (any throw rolls back the whole transaction
regardless of order) — only a total absence of throwing paths does. That is a hard implementation
constraint, not a preference.

---

## 3. RESEARCH FINDINGS AGAINST THE USER'S NINE CONSTRAINTS

| # | Constraint | Finding |
|---|---|---|
| 1 | Two routes to Closed Won | ✅ Confirmed at `StageAdvanceService.cls:98-106`. Also confirmed `Transaction_Complete_Close.flow-meta.xml` contains **no `<runInMode>` element** (grep returned nothing), so it writes `StageName = 'Closed Won'` as the Transactions persona. Co-location with `PropertyAssetService` is correct. |
| 2 | No callout with pending DML → must be async | ✅ Correct, and the governing rule is stronger than "must be async": *a fragile external write must never sit in a transaction whose rollback would lose something irreplaceable* (`AttachmentPersistQueueable.cls:14-16`). Here the irreplaceable thing is the deal close. |
| 3 | External Credential Principal Access is per-user | 🔴 **CONFIRMED AS THE HARDEST CONSTRAINT, AND IT DETERMINES THE ARCHITECTURE.** See §4 — this is SP-1 and D1. |
| 4 | `Property__c` may be null | ✅ Confirmed. `PropertyAssetService.createAssets` skips such deals and increments `runSkippedNoProperty` (`PropertyAssetService.cls:280-312`), with the residual named in its own header. → **D5.** |
| 5 | Idempotency; `replace` destroys documents | ✅ Agreed and adopted as a prohibition. → **D3.** |
| 6 | Nowhere to store the result | ✅ Confirmed — no SharePoint field exists anywhere. Strong in-repo naming precedent found on the same object: `Property__c.CoStar_URL__c` / `Placer_URL__c` (type `Url`), `Property__c.Parcel_ID__c` (Text, uppercase `ID`), `Property__c.Placer_Fetch_Status__c` (restricted picklist, an integration-status field on this exact object). → **§5, D6.** |
| 7 | Bulk safety vs 100 callouts / 50 enqueues | ✅ Reconciled in §7. **No exemption is claimed** — the rule applies literally and 251 is achievable. |
| 8 | Mockable callout service | ✅ `LLMExtractionCalloutService` / `LLMExtractionCalloutMock` is the precedent. |
| 9 | Layering; `PropertySelector` exists | ✅ Confirmed — `PropertySelector` has exactly one method, `selectAssetSeedByIds`, `WITH SYSTEM_MODE` inside a `private without sharing` inner class `AssetCreationReads`. The new read belongs there and inherits that argument almost verbatim (§6.2). |

### 3.1 Two additional facts found that the request did not anticipate

- 🔴 **`Property__c.Name` is not safe as a folder name without sanitization.** SharePoint/OneDrive
  reject `" * : < > ? / \ |`, leading/trailing whitespace, trailing dots, a `~$` prefix, and a set of
  reserved names, and enforce a full-path length ceiling. Seeded DPEG names are benign
  (`"Magnolia Crossing"`, `"Hwy 290 Retail Center"` — `data/properties.json`), but `Property__c` is
  created by `LeadConvertService` from LLM-extracted marketing text, so a name containing `/` or `:`
  is entirely reachable. Sanitization is mandatory and must be a pure, unit-testable method.
- 🔴 **Custom Metadata Type *records* do not deploy in this org.** There is no `customMetadata/`
  directory in the repo at all, and `RecordStageAdvanceService.cls:203-204` records the defect
  verbatim: *"CMDT *record* deploys fail in this org with UNKNOWN_EXCEPTION and need an Apex
  loader."* This eliminates CMDT as the config home and answers most of D7.

---

## 4. 🔴 SP-1 — THE MANDATORY SPIKE. IT DECIDES THE ARCHITECTURE, NOT A PARAMETER.

**Question:** in async Apex (Queueable / Batch), is *External Credential Principal Access* evaluated
against the **enqueuing user**, or does the async context bypass it?

**Why it cannot be assumed:** the in-repo precedent is consistent with "the enqueuing user's grant
matters" but does not prove it. `ExtractAddressQueueable` (`Queueable, Database.AllowsCallouts`)
makes the OpenAI callout asynchronously, and `Broker_Protection_Access` — which carries
`externalCredentialPrincipalAccesses` for `OpenAI_Credential-OpenAI_Principal` — is described as
*"Assign to the Email Service user"*, i.e. to the principal whose transaction enqueues. That is one
data point with a one-user population, gathered for a different reason. Assuming from it is exactly
the reasoning-not-measurement move this project has been burned by.

**Measurement (≈30 min, `usman-dpeg`, anonymous Apex + one throwaway user):**
1. As a user who does **not** hold `SharePoint_Integration_Access`, enqueue a trivial Queueable that
   calls `GET callout:SharePoint/sites/{siteId}`. Record the outcome.
2. Repeat from a `Schedulable` **scheduled by a user who does hold the grant**, while operating on a
   record last touched by the non-holder.
3. Record whether `UserExternalCredential` read is likewise evaluated per running user.

**What each outcome means:**

| SP-1 result | Consequence |
|---|---|
| **Async is gated by the enqueuing user** (expected) | The callout cannot run in the closing user's context without granting the credential to *everyone who can close a deal* — both `DPEG_Junior_Analyst_PSG` and `DPEG_Transaction_Team`. That forces **D1 Option B** (work-queue + scheduled sweeper), which then also solves the callout budget and the retry story. |
| **Async bypasses the per-user check** | The constraint evaporates; **D1 Option A** (Queueable straight off the trigger) becomes viable and is materially simpler. |

**Do not write implementation code before SP-1 returns.** The two outcomes produce different
classes, a different object count, and a different post-deploy gate list.

---

## 5. THE SEVEN DECISIONS FOR GATE 1

Each carries a recommendation and the trade-off. **None is silently picked.**

### D1 — Execution venue (⚠ gated on SP-1; this is the load-bearing decision)

| Option | Shape | Trade-off |
|---|---|---|
| **A — Queueable off the trigger** | `OpportunityReviewTriggerHandler` → `DealFolderService` → **one** `DealFolderQueueable` per trigger chunk carrying deal Ids, self-chaining when the chunk exceeds the callout budget. | Folder appears in seconds. But **requires granting `SharePoint_Integration_Access` to both persona groups** (unless SP-1 says otherwise), and Queueable chaining throws `System.AsyncException: Maximum stack depth has been reached` inside `@isTest` — so the chaining seam is structurally hard to test. Needs a separate Finalizer + retry story. |
| **B — Durable work-queue + scheduled Batch ✅ RECOMMENDED (if SP-1 confirms the gate)** | The trigger writes state only (`SharePoint_Folder_Status__c = 'Pending'`, zero callouts, zero enqueues). `DealFolderSweepBatch` (`Database.AllowsCallouts`) runs on a schedule, selects `Pending`/`Failed` rows, and makes the callouts **as the scheduling user**. | **One** user needs the external-credential grant — the constraint collapses. Batch scope natively meters callouts per transaction. Retry is free (the row simply stays `Pending`). Testable without the chaining quirk. Costs: latency up to the sweep interval, and 🔴 **a scheduled job is not deployable metadata**, so an unscheduled deploy silently disables the whole feature — a verified post-deploy gate, exactly as recorded for `AttachmentCarrierSweepSchedule` and `RoutingRetrySweepSchedule`. |

**Recommendation: B**, and note it is not a compromise — it is the only option that answers
constraints 3, 7 and (d) with one mechanism. If latency is unacceptable, A + the group grants is
the honest alternative; say so and the grant becomes an explicit, reviewed widening rather than a
side effect.

### D2 — Folder naming

| Option | Trade-off |
|---|---|
| **`<sanitized Property Name>` ✅ RECOMMENDED** | Matches the literal request. Two genuinely different properties with the same Name collide — mitigated by `conflictBehavior: rename` (D3), which yields `Magnolia Crossing 1`. Residual: the `1` is meaningless to a human browsing SharePoint; they navigate from the stored URL in Salesforce instead. |
| `<Property Name> — <Property Id>` | Collision-proof and greppable, permanently ugly, and encodes a Salesforce Id in a filesystem humans read. |
| Nested under a parent (e.g. `DPEG2/`) | ✅ **Recommended as an orthogonal add-on**, not an alternative — make the parent folder id/path a config value (D7) defaulting to the drive root. The library already contains `DPEG2/` and a root-level `Salesforce-Upload-Test.txt`, so writing to root mixes production folders into POC clutter. Addressing by **parent item id** also avoids the `EncodingUtil.urlEncode` path trap the user identified. |

### D3 — Idempotency and conflict behaviour

**Recommendation: a Salesforce field is the PRIMARY guard; `conflictBehavior: "rename"` is the
backstop; `"replace"` is PROHIBITED.**

- Primary: if `Property__c.SharePoint_Folder_ID__c` is non-blank → **zero callouts**, skip entirely.
  This is what makes the 251-record bulk case free, and it is keyed on **`Property__c`**, matching
  `PropertyAssetService`'s idempotency key so two deals on one property share one folder.
- Backstop: `"rename"` — never destroys, needs no path lookup, and returns the item id and `webUrl`
  in the 201 body in **one** callout.
- Considered and rejected: `"fail"` + adopt-the-existing-folder-on-409. More recoverable if the
  Salesforce field is ever lost, but it costs a **second** callout (`GET /drive/root:/{name}`) and
  re-opens exactly the URL-encoding trap the user flagged (`EncodingUtil.urlEncode` emits `+` for a
  space, which is wrong for a path segment). Available if the "lost field ⇒ orphan folder" residual
  is judged worse than the extra callout.
- 🔴 `"replace"` is prohibited in code and in review: it destroys signed deal documents.

### D4 — Do Salesforce files get copied in?

**Recommendation: NO for v1.** Empty folder for humans. Three measured costs make copying a
separate feature, not a line item: the 4 MB simple-upload ceiling; Apex heap — SP-4.5 measured a
`ContentVersion` body read plus re-assignment peaking at **~2× the file size**, 10.49 MB of the
12 MB async ceiling for one 5 MB file (`AttachmentPersistQueueable.cls:42-68`); and
`GET /drive/items/{id}/content` returning **302**, requiring a second callout following `Location`.

### D5 — Deals with a null `Property__c`

**Recommendation: SKIP, and name the residual out loud** — matching `PropertyAssetService`'s
identical decision and its identical residual (such a deal closes with no folder and nothing says
so; the recovery query is `SELECT Id FROM Opportunity WHERE StageName = 'Closed Won' AND
Property__c = null`). Throwing is rejected for the reason stated there: it would make a manually
created deal unclosable. Falling back to `Opportunity.Name` is rejected because the result fields
live on `Property__c` (D6), so a Property-less deal has nowhere to record its own folder — the
folder would exist with no way back to it, which is worse than none.

*If you want folders for Property-less deals, that changes D6 (fields would have to live on
Opportunity or be duplicated) — say so now, not later.*

### D6 — Where the result is stored

**Recommendation: four fields on `Property__c`.** The folder is named after the property, the
idempotency key is the property, and two deals on one property must share one folder — all three
point at the same object. `Property__c` also already carries the exact naming precedents.

| Field | Type | §1 rule check |
|---|---|---|
| `SharePoint_Folder_URL__c` | Url | Acronym uppercase (rule 2); matches `CoStar_URL__c` / `Placer_URL__c` on this object |
| `SharePoint_Folder_ID__c` | Text(255) | Matches `Parcel_ID__c`'s uppercase `ID` convention; not an object name, so rule 3 is not engaged |
| `SharePoint_Folder_Status__c` | Picklist, restricted: `Pending` / `Created` / `Failed` / `Skipped` | Rule 7 (current state → `Status__c`); matches `Placer_Fetch_Status__c` on this object. Under D1-B this picklist **is the sweeper's work queue**, which is why it is a picklist and not a checkbox |
| `SharePoint_Folder_Error__c` | Long Text Area (4096) | The durable failure surface. Not a past participle, so rule 4 is not engaged |

⚠ **All four arrive with NO field permissions for ANY profile, System Administrator included** —
the trap this repo has paid for repeatedly. That forces the mode decisions in §6.2/§6.3.

### D7 — Site id / drive id: constant, Custom Setting, or CMDT?

**Recommendation: a hierarchy Custom Setting `SharePoint_Config__c`**, read via `getOrgDefaults()`.

- **CMDT is eliminated by measurement**, not preference: no `customMetadata/` directory exists in
  the repo and CMDT *record* deploys fail in this org with `UNKNOWN_EXCEPTION`
  (`RecordStageAdvanceService.cls:203-204`).
- **An Apex constant is compile-checked and deployable but wrong per environment** — this POC site
  id must not travel to production in code.
- **Custom Setting** follows the one existing precedent, `Content_Publication_Budget__c`, chosen
  there because `getOrgDefaults()` costs **zero SOQL** — which matters here too, since the read sits
  on the Closed Won path. ⚠ Note the two known traps carried by that precedent: custom-setting
  **data is not deployable** (the org-default row is created at runtime or by hand and is a
  post-deploy gate), and `customSettingsVisibility` **must be omitted** or the deploy fails at API
  67.0 and cascades into ~30 bogus "Dependent class is invalid" Apex errors
  (`Content_Publication_Budget__c.object-meta.xml:3-25`).
- 🔴 **No hardcoded fallback.** If the setting is unset the feature must do nothing and record
  `Skipped`. A fallback pointing at the POC site is precisely how production deal folders end up in
  a POC library.
- Considered and rejected: putting `/sites/{siteId}/drive` into the Named Credential URL. It is
  deployable and environment-scoped, but it welds one feature's resource path into a credential
  ARCHITECTURE §3.4 describes as generic and reversible.

---

## 6. THE BUILD (assuming the recommended answers; ⚠ re-scope if D1 flips)

### 6.1 🔵 ADMIN WORK

- **4 custom fields on `Property__c`** exactly as specified in D6.
- **1 hierarchy Custom Setting `SharePoint_Config__c`** with `Site_ID__c` (Text 255),
  `Drive_ID__c` (Text 255, optional — Graph accepts `/sites/{id}/drive`), `Parent_Folder_ID__c`
  (Text 255, optional, blank = drive root), `Is_Enabled__c` (Checkbox, default false).
  ⚠ Omit `customSettingsVisibility`. ⚠ Custom-setting data is not deployable.
- **FLS grants for the 4 new fields.** 🔴 Grant them where the **sibling** fields live, not where
  the feature lives: `CoStar_URL__c` / `Placer_URL__c` / `Placer_Fetch_Status__c` are declared in
  `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Property_View` and
  `DPEG_Opportunity_View`. ⚠ **Reconcile each file against the org before editing it** — a
  `PermissionSet` deploy **replaces** its `fieldPermissions` set wholesale, and a
  `DPEG_Admin_Access` reconciliation on 2026-08-09 was already found stale one day later.
- **Page layout / Dynamic Form placement** for the four fields on the Property layout.
- **Permission-set change for the credential**, per D1:
  - **D1-B:** none beyond assigning the existing `SharePoint_Integration_Access` to the **one**
    scheduling user (an in-org step; `PermissionSetAssignment` is not deployable metadata).
  - **D1-A:** add `SharePoint_Integration_Access` as a member of `DPEG_Junior_Analyst_PSG` **and**
    `DPEG_Transaction_Team`. 🔴 **Reconcile each group's membership against the org first** — a
    `PermissionSetGroup` deploy replaces its member list wholesale, and a deployed group was found
    on 2026-08-10 carrying a member the repo copy does not list.
- **ARCHITECTURE.md updates (§6 requires same-PR):** §1 field additions; §2 *Key Apex Services* rows
  for the new services; a new row in the §2 automation-path `SYSTEM_MODE` table; §3.4 extended to
  record that Apex now uses the exception and where its endpoint constant lives.

### 6.2 🟢 DEVELOPER WORK

| Class | Layer | Responsibility |
|---|---|---|
| `SharePointCalloutService` | callout service | 🔴 **The ONLY `Http.send` in the feature.** `createFolder(siteId, parentItemId, name)` → typed result `{ itemId, webUrl, statusCode, errorMessage }`. Holds the one endpoint constant so §3.4's "retire by changing one constant" promise stays literally true. No SOQL, no DML. Precedent: `LLMExtractionCalloutService`. |
| `SharePointCalloutMock` | test | `HttpCalloutMock` returning 201 / 409 / 429 / 500 / malformed-body. Precedent: `LLMExtractionCalloutMock`. |
| `SharePointConfig` | config accessor | `getOrgDefaults()` wrapper, **zero SOQL**. Returns null/disabled cleanly when unset. Precedent: `ContentPublicationBudget`. |
| `DealFolderService` | service | Owns stage-ENTRY detection, the null-`Property__c` skip, the pure `sanitizeFolderName(String)`, and the result stamp. Called from the trigger handler (state only) and from the async job (callout orchestration). |
| `DealFolderSweepBatch` *(D1-B)* | batch | `Database.AllowsCallouts`. Selects `Pending`/`Failed`, scope tuned to the callout budget. Idempotent and convergent. |
| `DealFolderSweepSchedule` *(D1-B)* | schedulable | 🔴 Post-deploy scheduling gate. |
| `DealFolderQueueable` + `DealFolderFinalizer` *(D1-A only)* | queueable / finalizer | Only if D1-A is chosen. |
| `PropertySelector.selectFolderStateByIds` | selector (existing class) | New method. See §6.3. |

**Layering:** all SOQL in `PropertySelector`; the callout in `SharePointCalloutService` only;
`DealFolderService` orchestrates and holds no query. Per `.claude/rules/apex-layering-rule.md`.

### 6.3 🔴 MODE AND SHARING — TWO SEPARATE DECISIONS, PRE-ARGUED

**`PropertySelector.selectFolderStateByIds` must be `WITH SYSTEM_MODE` *and* live in a
`private without sharing` inner class**, and the two halves are argued separately (conflating them
is the D25 mistake this repo has paid for):

- **MODE — `SYSTEM_MODE`.** The read selects the four fields created in this same change, and a
  Metadata-API-deployed field arrives with no FLS for any profile, System Administrator included.
  `USER_MODE` throws rather than degrades. Under D1-A that throw escapes an after-update trigger as
  `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and **rolls back the deal close**; under D1-B it kills the
  sweeper for the very administrator who deployed the fields.
- 🔴 **SHARING — `without sharing`, and this is the more dangerous half.** `Property__c` is
  `sharingModel = Private`; its single sharing rule is an OWNER rule scoped to the `Acquisition`
  queue, which does not reach a `LeadConvertService`-created Property. This read is an
  **idempotency guard**, and ARCHITECTURE §2 states the rule this triggers exactly: *"whenever a
  SYSTEM_MODE automation read against a Private-OWD object is used to decide whether something
  already exists, sharing is not a robustness question, it is a correctness one — a filtered read
  does not disable the feature, it inverts it."* Zero rows would read as "no folder exists" and mint
  a **duplicate SharePoint folder**, silently. Mirror `PropertySelector.AssetCreationReads`; keep
  the outer class `with sharing` and leave `selectAssetSeedByIds` untouched.

**The result stamp DML is `AccessLevel.SYSTEM_MODE` and `allOrNone = false`.** SYSTEM_MODE because
the personas may hold no Edit on `Property__c` and the new fields have no FLS; `allOrNone = false`
because a failed stamp must never take anything else down. Under D1-B the write happens in the
sweeper's own transaction, so no approval-lock question arises (`Property__c` is under no approval).

### 6.4 Failure behaviour

**Fail-soft, durable, and retried by the venue itself** (D1-B makes retry free — a row that stays
`Pending`/`Failed` is picked up on the next run; no separate retry engine is needed, which is a
third reason to prefer B).

⚠ **If D1-A is chosen, a `System.Finalizer` becomes mandatory rather than optional,** and it must be
argued rather than copied: the job's own `catch` provably cannot see the failure family that
matters — SP-R1 measured heap and CPU `LimitException`s escaping a `catch (Exception e)` wrapped
directly around the failing code. Two consequences carry over verbatim: `attachFinalizer` must be
the **first** statement (above any load, because a `USER_MODE` selector throw would otherwise kill
the job before anything that could record it runs), and **detection must be a message substring,
never a type check** — the platform wraps the cause as `System.AsyncException` and preserves the
real type only as text.

---

## 7. BULK SAFETY — THE RECONCILIATION, AND NO EXEMPTION IS CLAIMED

`.claude/rules/bulk-test-rule.md` mandates 251 for trigger-driven work. This is trigger-driven, so
the rule applies literally. It is achievable because **callouts are bounded per JOB, never per
record**:

| Limit | Value | How the design stays inside it |
|---|---|---|
| Callouts / transaction | 100 | D1-B: batch `scope` sets it (flat folder ⇒ 1 callout per deal ⇒ scope ≤ 50 leaves 2× headroom). D1-A: bounded deals-per-job + chaining. |
| Cumulative callout timeout | 120 s | Real practical ceiling before the callout count is: ~50 Graph calls at 200–500 ms ≈ 10–25 s. Stated so a future "raise the scope" change re-checks it. |
| Queueable enqueues / sync txn | 50 | **One enqueue per trigger chunk, never one per deal.** A 200-deal chunk enqueuing per record would throw and roll back the close. |
| Queueable enqueues / async txn | 1 | Why D1-A needs chaining, and why chaining is untestable inside `@isTest`. |
| Batch jobs / transaction | 5 | D1-B starts at most one per chunk. |

**What the 251 bulk test must assert:**

1. 251 Opportunities driven to `Closed Won` produce **exactly one** enqueue/batch-start per trigger
   chunk (i.e. **2**, not 251).
2. The synchronous service's SOQL and DML are **CONSTANT in deal count** — assert measured `Limits`
   deltas on run counters, following `PropertyAssetService`'s `runQueryCount` / `runDmlCount`
   pattern rather than a hand-maintained tally.
3. 🔴 **Re-running the identical 251-record update produces ZERO callouts and ZERO enqueues.** This
   is the single most valuable assertion in the suite — it is the duplicate-folder falsifier.
4. Callout counts asserted on a counter captured **inside** the async context, never on `Limits.*`
   after `Test.stopTest()` (which restores pre-test counters and makes the obvious assertion
   silently vacuous — the `ExtractAddressQueueable.lastRunQueryCount` precedent).
5. `HttpCalloutMock` branches: 201, 409, 429, 500, malformed body. Every one must leave the deal
   closed.
6. A deal with null `Property__c` closes cleanly and is counted as skipped.
7. Sanitization is a pure unit test — illegal characters, leading/trailing whitespace, trailing
   dot, over-length, and a name that sanitizes to empty.
8. Config unset ⇒ `Skipped`, zero callouts, deal still closes.

**Coverage target 90%** on every new class (ARCHITECTURE §2, team-owned).

---

## 8. EXECUTION ORDER

1. **SP-1** — the credential/async spike. Blocks everything; determines D1. *(DevOps or
   technical-architect, in `usman-dpeg`.)*
2. **Gate 1** — user answers D1–D7 with SP-1's result in hand.
3. **Admin** — 4 fields + custom setting + FLS + layout. Must land before the Apex compiles.
4. **Developer / technical-architect** — the classes in §6.2.
5. **Unit testing** — the §7 suite.
6. **Code review.**
7. **DevOps + Documentation** in parallel, including the post-deploy gates: create the custom-setting
   org-default row, assign `SharePoint_Integration_Access`, and (D1-B) **schedule the sweep** — an
   unscheduled deploy leaves every folder permanently `Pending` while nothing errors.

---

## 9. PROMPTS FOR THE SPECIALIST AGENTS

⚠ **Do not hand these over until D1–D7 are answered and SP-1 has returned.** They are written
against the recommended answers; the lines that change under a different answer are marked.

### 🟠 PROMPT 0 — for `salesforce-devops` (or `salesforce-technical-architect`), RUN FIRST

```
Run spike SP-1 in the org `usman-dpeg`. Do not write any feature code.

QUESTION: in asynchronous Apex (Queueable and Batch), is "External Credential Principal Access"
for `SharePoint_Credential-SharePoint_Principal` evaluated against the enqueuing/scheduling user,
or does the async context bypass it?

The SharePoint Named Credential, the SharePoint_Credential External Credential and the
SharePoint_Integration_Access permission set already exist and are working. Do not modify them.

Measure, do not reason:
1. As a user who does NOT hold SharePoint_Integration_Access, enqueue a trivial Queueable that
   calls `GET callout:SharePoint/sites/{siteId}`. Record the exact exception or status.
2. Repeat via a Schedulable scheduled by a user who DOES hold the grant, operating on a record last
   touched by the non-holder.
3. Record whether `UserExternalCredential` object read is likewise evaluated per running user.

Report the raw results and the exact error text. State explicitly which of the two outcomes in
`agent-output/design-requirements-sharepoint-deal-folder.md` §4 was observed. Do not deploy
anything.
```

### 🔵 PROMPT — for `salesforce-admin`

```
Create metadata only. Do not deploy. Follow ARCHITECTURE.md §1 naming rules and
.claude/rules/salesforce-global-rule.md. API version 67.0.

1. Four custom fields on Property__c:
   - SharePoint_Folder_URL__c     Url
   - SharePoint_Folder_ID__c      Text(255)
   - SharePoint_Folder_Status__c  Picklist, restricted, values: Pending, Created, Failed, Skipped
                                  (no default)
   - SharePoint_Folder_Error__c   Long Text Area(4096)
   Match the file shape of the existing Property__c/fields/CoStar_URL__c,
   Parcel_ID__c and Placer_Fetch_Status__c on this same object.

2. A hierarchy Custom Setting SharePoint_Config__c with fields:
   Site_ID__c Text(255), Drive_ID__c Text(255), Parent_Folder_ID__c Text(255),
   Is_Enabled__c Checkbox default false.
   CRITICAL: OMIT the customSettingsVisibility element entirely — it is rejected at API 67.0 in
   this org and cascades into ~30 bogus "Dependent class is invalid" Apex errors. See the XML
   comment in objects/Content_Publication_Budget__c/Content_Publication_Budget__c.object-meta.xml
   for the full incident record. Custom-setting DATA is not deployable; do not create a data row.

3. FLS for the four Property__c fields. Grant them in the SAME permission sets that already
   declare the sibling fields CoStar_URL__c / Placer_URL__c / Placer_Fetch_Status__c:
   DPEG_Acquisition_Edit, DPEG_Acquisition_View, DPEG_Property_View, DPEG_Opportunity_View.
   CRITICAL: a PermissionSet deploy REPLACES its entire fieldPermissions set. Retrieve each of
   those four files from the org and reconcile before editing, per ARCHITECTURE.md §2 Standards.
   Report any org-only grants you find.

4. Add the four fields to the Property__c page layout.

[IF DECISION D1 = OPTION A ONLY — otherwise SKIP THIS ITEM ENTIRELY]
5. Add SharePoint_Integration_Access as a member of DPEG_Junior_Analyst_PSG and
   DPEG_Transaction_Team. CRITICAL: a PermissionSetGroup deploy replaces its MEMBER LIST wholesale
   — retrieve both groups from the org and reconcile membership before editing.

Do not add validation rules, flows, reports or any field not listed above.
```

### 🟢 PROMPT — for `salesforce-technical-architect`

```
Build the SharePoint deal-folder feature. Read agent-output/design-requirements-sharepoint-deal-
folder.md in full first, then ARCHITECTURE.md §2 and §3.4, .claude/rules/apex-layering-rule.md and
.claude/rules/bulk-test-rule.md. API version 67.0.

The SharePoint Named Credential and credentials already exist and work — callouts use
callout:SharePoint/... Do not touch the credential layer.

BUILD (assuming decision D1 = Option B, work-queue + scheduled sweeper):

1. SharePointCalloutService — the ONLY Http.send in the feature. One public method
   createFolder(siteId, parentItemId, name) returning a typed result {itemId, webUrl, statusCode,
   errorMessage}. POST /sites/{siteId}/drive/items/{parentId}/children (or /drive/root/children
   when parentId is blank) with {"name":..., "folder":{}, "@microsoft.graph.conflictBehavior":
   "rename"}. Address by PARENT ITEM ID, never by path — EncodingUtil.urlEncode emits '+' for a
   space and is WRONG for path segments. conflictBehavior "replace" is PROHIBITED: it destroys
   signed deal documents. Hold the endpoint constant here and nowhere else so ARCHITECTURE §3.4's
   "retire by changing one constant" promise stays true. No SOQL, no DML. Model it on
   LLMExtractionCalloutService.

2. SharePointConfig — getOrgDefaults() accessor over SharePoint_Config__c, ZERO SOQL. Model it on
   ContentPublicationBudget. NO hardcoded site-id fallback: unset or Is_Enabled__c = false means do
   nothing and stamp Skipped.

3. PropertySelector.selectFolderStateByIds(Set<Id>) — a NEW method on the EXISTING class.
   WITH SYSTEM_MODE, inside a private without sharing inner class, mirroring the existing
   AssetCreationReads. Both halves are argued separately in §6.3 of the design doc — reproduce that
   argument in the method's Javadoc. Leave selectAssetSeedByIds and the outer `with sharing`
   untouched.

4. DealFolderService — stage-ENTRY detection (Closed Won, oldMap-aware, insert counts as entering,
   matching PropertyAssetService.ensureOnClosedWon exactly), the null-Property__c SKIP with a run
   counter, a PURE sanitizeFolderName(String), and the result stamp
   (AccessLevel.SYSTEM_MODE, allOrNone = false).
   🔴 THIS SERVICE MUST NOT THROW FROM THE SYNCHRONOUS PATH UNDER ANY INPUT. A SharePoint problem
   rolling back a Closed Won is strictly worse than a missing folder. Placing it last in the
   handler does NOT achieve this — only the absence of throwing paths does.
   Expose measured run counters (Limits deltas) the way PropertyAssetService does.

5. DealFolderSweepBatch (Database.AllowsCallouts) + DealFolderSweepSchedule. Selects
   SharePoint_Folder_Status__c IN ('Pending','Failed'). Scope tuned so callouts stay well under
   100 per transaction. Idempotent and convergent — a populated SharePoint_Folder_ID__c means zero
   callouts.

6. Wire DealFolderService into OpportunityReviewTriggerHandler.route() as a FIFTH call, after
   PropertyAssetService.ensureOnClosedWon. The synchronous side writes state only: zero callouts,
   zero enqueues, and zero SOQL/DML when the chunk closes nothing.

SANITIZATION: strip/replace " * : < > ? / \ | , trim leading and trailing whitespace, strip
trailing dots, reject a leading ~$, clamp length, and handle a name that sanitizes to empty
(stamp Skipped with a reason). Property__c.Name comes from LLM-extracted marketing text, so this
is reachable, not hypothetical.

DO NOT: copy any Salesforce file into SharePoint (decision D4 = no), create subfolders (D2 = flat),
hardcode the site id, use conflictBehavior "replace", or make a callout from the synchronous
trigger transaction.

Include Javadoc class headers in this repo's style stating WHY, not just what — specifically the
SYSTEM_MODE/without-sharing split, the never-throw rule, and the callout budget.
```

### 🟡 PROMPT — for `salesforce-unit-testing`

```
Write test classes for the SharePoint deal-folder feature. Target 90%+ per class. Use
TestDataFactory (force-app/main/default/classes/TestDataFactory.cls) — do not stand up a competing
factory. Read .claude/rules/bulk-test-rule.md; NO exemption is claimed for this feature.

Required, from §7 of agent-output/design-requirements-sharepoint-deal-folder.md:
1. 251 Opportunities driven to Closed Won produce exactly ONE enqueue/batch-start per trigger
   chunk (2 total), never 251.
2. The synchronous service's SOQL and DML are CONSTANT in deal count — assert measured Limits
   deltas on the service's run counters, following PropertyAssetServiceTest's pattern.
3. 🔴 THE MOST IMPORTANT ONE: re-running the identical 251-record update produces ZERO callouts and
   ZERO enqueues. This is the duplicate-folder falsifier.
4. Assert callout counts on a counter captured INSIDE the async context. NEVER on Limits.* after
   Test.stopTest() — stopTest restores the pre-test counters and makes that assertion silently
   vacuous (the ExtractAddressQueueable.lastRunQueryCount precedent).
5. SharePointCalloutMock branches: 201, 409, 429, 500 and a malformed body. Every one must leave
   the deal CLOSED.
6. A deal with null Property__c closes cleanly and is counted as skipped.
7. sanitizeFolderName as pure unit tests: each illegal character, leading/trailing whitespace,
   trailing dot, over-length, and a name that sanitizes to empty.
8. Config unset / Is_Enabled__c = false ⇒ Skipped, zero callouts, deal still closes.

Do not add test scenarios beyond this list.
```

---

## 10. RESIDUALS AND KNOWN GAPS — STATED, NOT HIDDEN

1. **A Property-less deal gets no folder and nothing says so** (D5) — same residual
   `PropertyAssetService` carries, same recovery query.
2. **D1-B trades latency for a single credential grant.** A folder does not exist at the moment the
   deal closes.
3. **An unscheduled sweep silently disables the feature** and leaves rows reading `Pending` — which
   *looks* handled. Verified post-deploy gate, same class of hazard as
   `RoutingRetrySweepSchedule`.
4. **Two different properties with identical Names** produce `Name` and `Name 1` under
   `conflictBehavior: rename` (D2). Navigation is by the stored URL, not by browsing.
5. **If `SharePoint_Folder_ID__c` is ever blanked, a duplicate empty folder is created** on the
   next sweep. `conflictBehavior: "fail"` + adopt-on-409 would prevent it at the cost of a second
   callout and the path-encoding trap.
6. **This is the first Apex to exercise ARCHITECTURE §3.4.** §3.4 itself warns that two standing
   direct-callout exceptions is the point at which a third should trigger a review of the rule
   rather than another exception block.
7. **`Placer_Fetch_Status__c` is a dormant precedent** — it has no Apex writer anywhere in the repo.
   It is being followed for *naming*, not as evidence that this integration-status pattern has ever
   run here.
