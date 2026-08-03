# Design Requirements — Smart Lead Conversion (attach to existing Contact / Account)

**Module:** Broker Protection (Lead Intake) — conversion core
**Date:** 2026-08-02
**Status:** Gate-1 — awaiting user confirmation
**Triggering incident:** `DUPLICATES_DETECTED, Duplicate Alert: []` converting Lead *Usman Khan /
usmankhan-96@hotmail.com / "Unknown - Via Email"* on `usman-dpeg`, live.

---

## 0. What the user asked for

> When a Contact and/or Account already exist matching the converting Lead's person and company,
> the conversion must ATTACH to them (creating only the Opportunity + the module's usual artifacts)
> instead of minting duplicate Contact/Account records.

Nothing beyond that is designed here. §8 (Scope Guard) lists what is deliberately NOT touched.

---

## 1. Recon — what is actually there today

Verified against the working tree, not assumed.

| Fact | Evidence |
| --- | --- |
| `LeadConvertActionService` is the **only** class that runs `Database.convertLead`. Its only caller is `LeadConvertActionController`. | `Grep convertLead` → 11 files; the only non-test production callers are the controller + the service itself. |
| `convert(List<Id>)` today performs **zero reads** — it builds one `Database.LeadConvert` per Id (`setLeadId`, `setConvertedStatus('Converted')`, `setDoNotCreateOpportunity(false)`) and makes one all-or-none `Database.convertLead` call. | `LeadConvertActionService.cls` lines 59–83 |
| `LeadConvertService` runs **after** conversion, from `LeadConvertTrigger`, and only touches the *new Opportunity* + a new `Property__c`. It never reads or writes Contact/Account. | `LeadConvertService.cls` — `stampConvertedOpportunities` operates on `ConvertedOpportunityId` only |
| `ContactSelector` exists. It has **no** email-keyed internal method — the only email lookup is `GuestReads.selectBrokerPriorityByEmailSystem` (`without sharing` + `SYSTEM_MODE`, guest-portal only). | `ContactSelector.cls` |
| **`AccountSelector` does not exist.** There is **zero Account SOQL anywhere in the codebase** (`Grep "FROM Account"` over `classes/` → no matches). `.claude/skills/sf-apex/references/AccountSelector.cls` is a *template*, not a deployed class. | Glob + Grep |
| **Active** duplicate rules: `Standard_Contact_Duplicate_Rule`, `Standard_Account_Duplicate_Rule` — both `actionOnInsert=Allow`, `operationsOnInsert=Alert,Report`. | `duplicateRules/*.xml` |
| **Inactive** duplicate rules: `Standard_Lead_Duplicate_Rule`, `Standard_Rule_for_Leads_with_Duplicate_Contacts`, `Standard_Rule_for_Contacts_with_Duplicate_Leads` (`isActive=false`). | same |
| `matchingRules/Contact.matchingRule-meta.xml` and `Account.matchingRule-meta.xml` are **empty** (`<MatchingRules/>`). The rules referenced by the duplicate rules (`Standard_Contact_Match_Rule_v1_1`, `Standard_Account_Match_Rule_v1_0`) are platform-standard and **their criteria are not in source control** — they can only be read in Setup. | file contents |
| **The org has already solved this exact problem once, by deactivation.** Commit `e1f5a9f` "deactivate standard Lead duplicate rule" turned the two Lead-side rules off because they were blocking the automated inbound pipeline's Lead insert. `EmailToLeadService.deleteLead`'s header records the reasoning: *"its collision with org-level Lead duplicate rules on Email (DUPLICATES_DETECTED rolls back the whole transaction and the email's Task is silently lost)."* | `EmailToLeadService.cls` lines 366–375; git log |
| Account **means "brokerage firm"** in this app, and `BrokerFirmController.getBrokerFirm` aggregates **every Opportunity on that Account** into the Opportunity sidebar's firm deal counts (submitted / won / lost) and names *the earliest-created Contact on the Account* as "the broker". | `BrokerFirmController.cls` 33–52 + `OpportunitySelector.countByStageForAccount` |
| Email is the durable broker key throughout this module. | `Competing_Broker_Submission__c.Broker_Email__c` + `CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail`; `ContactSelector.GuestReads.selectBrokerPriorityByEmailSystem`; `EmailToLeadService` sets `Lead.Email` from `broker_email` else the envelope `From` |
| `Lead.Company` falls back to the literal `'Unknown - Via Email'` (`EmailToLeadService.COMPANY_PLACEHOLDER`, currently **private**) whenever the LLM extracts no `broker_company`. | `EmailToLeadService.cls` line 81 |

**⚠ Conflict surfaced against the prompt's D7.** The prompt says the duplicate rules "stay ON". The
org's own precedent for this class of failure was to turn the offending rules OFF. This design
**honours the prompt** (rules stay untouched) — see §5.4 for why the code fix is the better answer
here and why repeating the deactivation precedent would be worse, not merely out of scope.

---

## 2. D1 — Match keys

### D1a. Contact: **`Lead.Email` exact, single key. Name is neither a requirement nor a widener.**

**Recommendation.** Match a Contact when `Contact.Email = Lead.Email` (trimmed). Do **not** require
a name match. Do **not** fall back to a name match when the email differs.

SOQL string comparison on Text/Email fields is **case-insensitive by default** in Salesforce, so
`WHERE Email = :trimmedEmail` already satisfies "case-insensitive exact". Do not add `LOWER()` —
it is not valid SOQL and is not needed.

**Why email alone, and not name-as-requirement.** The extracted person name is the *least* stable
value on these Leads — it comes from an LLM reading a forwarded signature block, so "Usman Khan",
"Usman A. Khan" and "Khan, Usman" are all reachable for one broker. Requiring a name match makes
the feature **miss exactly the case it exists for** and mint the duplicate anyway. Email is the key
the rest of the module already treats as broker identity (`Broker_Email__c`,
`selectRecentByBrokerEmail`, `selectBrokerPriorityByEmailSystem`).

**Why not name-as-widener.** Matching on name when the email differs would fuse two different
"John Smith" brokers at two different firms into one Contact, attaching a deal to the wrong person.
That is unrecoverable by the user from the quick action and is the opposite of broker protection.
A missed match creates a duplicate (recoverable by merge); a wrong match mis-attributes a deal.
**Prefer the recoverable failure.**

**Guard — the matched Contact must have an `AccountId`.** Salesforce requires the conversion target
Contact to belong to the Account being converted into. Filter `AccountId != null` **in the query**,
so an orphan Contact simply never matches and the code has no special case. Consequence (L1): a
broker whose only Contact is account-less still gets a duplicate Contact. Acceptable — this org's
Contacts are conversion-born and always carry an Account.

### D1b. Account: **exact `Name` match on `Lead.Company`, but ONLY when no Contact matched AND the company is not the placeholder.**

**This is the crux, and the answer is: the placeholder must NOT account-match.**

The Salesforce constraint settles the ordering: if you `setContactId`, the convert must target that
Contact's Account. So **Contact-match wins and dictates the Account**; Account-name matching is
reachable only when no Contact matched.

That leaves one real decision — what to do with `'Unknown - Via Email'`. Two candidate answers:

| | **Bucket** (match the placeholder by name) | **No-match** (recommended) |
| --- | --- | --- |
| Result | ONE Account holding every firm-unknown broker | ONE placeholder Account **per broker** |
| Repeat broker's 2nd deal | attaches (via bucket) | attaches (via **Contact** match — same outcome) |
| `BrokerFirmController` sidebar | shows every unrelated broker's deals as "this firm's" deals, and names a random other broker as "the broker" | correct — the Account holds one broker's deals |
| Cross-broker exposure | all brokers' Contacts + Opportunities sit under one Account | none |

**Recommendation: no-match.** The decisive fact is `BrokerFirmController.getBrokerFirm` +
`OpportunitySelector.countByStageForAccount` — bucketing puts an **actively wrong answer on a live
page**, in the one module whose entire purpose is broker attribution. And bucketing buys nothing:
the repeat-broker case (the incident, and the *normal* case per the prompt) is already solved by the
Contact match, which reuses that broker's own Account. `'Unknown - Via Email'` is not a firm name —
it is a null wearing a string — and matching records on a null value is a category error.

Under this rule the placeholder Account proliferates **once per distinct broker**, never once per
conversion. That is semantically correct: it is a per-broker firm stub awaiting a real name.

**Where the account match DOES earn its keep:** a *new* broker (no Contact) whose email carried an
extractable firm — e.g. `Company = 'Marcus & Millichap'`. Their new Contact lands under the existing
firm Account instead of creating a second one. That is the "company" half of the user's request.

**Implementation note (one deliberate scope exception — approval requested).** The matching service
must know the placeholder literal. Promote `EmailToLeadService.COMPANY_PLACEHOLDER` from `private`
to `public static final` and reference it, rather than re-typing `'Unknown - Via Email'` in a second
class. Visibility change only; zero behaviour change. Duplicating the literal is the drift trap this
avoids.

### D1c. Scope of matching: **every Lead converted through this action, no `LeadSource` filter.**

Duplicates are not a Broker-Protection-specific problem, and a LeadSource filter would give one
button two different behaviours — a surprise nobody can see from the UI.

---

## 3. D2 — Multiple matches

**Deterministic rule, identical for Contact and Account: `ORDER BY CreatedDate ASC, Id ASC LIMIT 1`
— the oldest wins.**

- **Oldest, because** it carries the most history (activities, prior deals) and is the record a
  manual merge would keep as master, so code and human converge on the same winner.
- **`Id ASC` as the tiebreak, because** two rows created in the same transaction can share a
  `CreatedDate`; without it the pick is not total and the feature could oscillate between two
  targets across conversions.
- **The rule is convergent**: a newly created duplicate can never displace the canonical target,
  so repeated conversions attach to the same record forever.

**Ops follow-up (out of scope, manual):** the two pre-existing `Unknown - Via Email` Accounts
(`001iw000001hiTZAAY`, `001iw000001hk76AAA`) should be merged by an admin. **No code depends on
that merge** — under D1b the placeholder never account-matches, and the incident Lead resolves
through Contact `003iw000000UTW4AAO`'s own `AccountId`, whichever of the two that is. The merge is
hygiene, not a prerequisite.

---

## 4. D3 — Where the logic lives

### Layer placement

Matching is **read + decide** → a Service calling Selectors (`ARCHITECTURE.md` §2,
`.claude/rules/apex-layering-rule.md`). The controller is **not** touched.

### The wiring decision: `LeadConvertActionService.convert()` calls the match service

Not the controller. Reasons:

1. `LeadConvertActionController` must stay thin (marshal → delegate → `catch` → `AuraHandledException`).
   Its three-tier `catch` ladder and the `LeadActionPermissionService.assertLeadActionAccess()`
   ordering are load-bearing and should not be re-opened for this.
2. `LeadConvertActionService.convert()` is **the only place in the app that runs
   `Database.convertLead`**. Putting the wiring there makes "attach when possible" an invariant of
   conversion itself — a future second caller cannot accidentally bypass it. Putting it in the
   controller makes it an invariant of *one button*.

### Components

| # | Component | Layer | Change |
| --- | --- | --- | --- |
| 1 | **`LeadConvertMatchService.cls`** (new) | Service, `with sharing` | `public static Map<Id, ConversionMatch> matchForConversion(List<Id> leadIds)`; inner `public class ConversionMatch { public Id accountId; public Id contactId; }`. **Invariant: `contactId != null` implies `accountId == that Contact's AccountId`.** Bulk-shaped: exactly **3 SOQL** regardless of N. No DML. |
| 2 | **`AccountSelector.cls`** (new — first Account SOQL in the app) | Selector, `with sharing` | `selectByNames(Set<String> names)` → `Id, Name, CreatedDate`, `WITH USER_MODE`, `ORDER BY CreatedDate, Id`. Null/empty-safe → empty list. |
| 3 | `ContactSelector.cls` | Selector | **add** `selectByEmails(Set<String> emails)` → `Id, Email, AccountId, CreatedDate`, `WHERE Email IN :emails AND AccountId != null`, `WITH USER_MODE`, `ORDER BY CreatedDate, Id`. Goes on the **outer** class (internal path) — **not** in `GuestReads`. |
| 4 | `LeadSelector.cls` | Selector | **add** `selectMatchKeysByIds(Set<Id> leadIds)` → `Id, Email, Company`, `WITH USER_MODE`. Sits with the existing Broker-Protection block. |
| 5 | `LeadConvertActionService.cls` | Service | Call the match service; per Lead apply `setAccountId` / `setContactId` when matched, plus the D4 bypass flags. ~15 lines + header. |
| 6 | `EmailToLeadService.cls` | Service | **Visibility only:** `COMPANY_PLACEHOLDER` `private` → `public`. (§2 D1b, approval requested.) |
| 7 | `LeadConvertActionController.cls` | Controller | **UNCHANGED.** |
| 8 | `leadConvertAction` LWC | UI | **UNCHANGED.** |
| 9 | `ARCHITECTURE.md` | Doc | §2 Key Apex Services: add `LeadConvertMatchService`. **Also add the missing `LeadConvertActionService` row** — a pre-existing §6 gap (only `LeadConvertService` is listed today). |

**Naming hazard, called out deliberately:** the app will then hold three similarly-named classes.
Each header must carry the same three-line map:
`LeadConvertActionService` = *runs* `convertLead` · `LeadConvertMatchService` = *decides what it
attaches to* (before) · `LeadConvertService` = *stamps the Opportunity + creates the Property*
(after, via trigger).

### Mode / sharing / failure

- **`WITH USER_MODE`** on all three selector reads (§2 default). No `SYSTEM_MODE` justification
  exists: this is an interactive, user-initiated path, not the guest/automation path that earns
  `SYSTEM_MODE` in `LeadSelector.GuestReads` / `EmailThreadGuardService`.
- **`with sharing`** on the match service (§2 mandate; no written justification for `without
  sharing` is available or warranted). **Consequence L2:** a Contact/Account the converting user
  cannot see will not match, and a duplicate results — *the same outcome as today, never worse*.
  If L2 bites in production the remedy is a sharing rule, not `without sharing` in Apex.
- **⚠ FLS degrade — required.** `Lead.Email` and `Contact.Email` are FLS-permissionable.
  `USER_MODE` **throws** (it does not degrade) when the running user lacks read. A raw throw would
  **regress conversion for users who can convert today**. So `matchForConversion` catches
  `System.QueryException`, logs at `LoggingLevel.ERROR`, and returns an **empty map** → conversion
  proceeds exactly as it does today.
  - Justified because matching is an *optimisation over platform default behaviour*, not an
    authorization control. Degrading is strictly no worse than the status quo. (`Account.Name`,
    `Lead.Company` (required) and `CreatedDate` are not FLS-subject, so only the two Email reads
    carry this risk.)
  - **Make the degrade loud, per the adopter's R1 lesson ("fails soft → watch for silence"):**
    expose a static `lastRunDegraded` (in-transaction, for tests and debugging only — it is not
    monitoring) and assert it in a dedicated test. The production symptom of a silent degrade is
    *duplicates reappearing*, which is observable.

---

## 5. D4 — Duplicate-rules interplay

### 5.1 Recommendation

**Set `setBypassAccountDedupeCheck(true)` and `setBypassContactDedupeCheck(true)` on every
`Database.LeadConvert`** (the API-44+ setters that exist specifically for this call). Proceed-and-
create. Do **not** surface a "near-duplicate exists" `AuraHandledException` as the primary path.

### 5.2 Why proceed, not block

1. **The org's configured intent for these rules is already "alert and proceed."**
   `actionOnInsert=Allow`, `operationsOnInsert=Alert,Report` means *warn a human, let them
   continue*. Apex conversion has no surface on which to render the alert, so the platform converts
   "Alert" into a hard `DUPLICATES_DETECTED`. **That is not the configured intent; it is the absence
   of a UI.** The bypass restores the intent.
2. **Blocking protects nothing and strands the deal.** From a headless quick action the user cannot
   merge, cannot review the matched records, and cannot override. The failure is terminal for that
   Lead.
3. **The module's fail-closed philosophy is about *claims and authorization*** — who wins a
   property, who may act — **not about record creation.** `PropertyClaimService` fails closed
   because a wrong claim mis-attributes a commission. A duplicate Contact does not.
4. **Exact matching removes the common duplicate source.** The residual the bypass covers is only
   the *fuzzy near-miss* (same person, different email; near-identical firm name) — rare, and
   recoverable by merge.

### 5.3 Accepted cost (state it, don't hide it)

Bypassing skips the rule **entirely**, including its `Report` operation — so **no
`DuplicateRecordSet` is logged** for a conversion-created duplicate. That is the price of the
bypass and it is worth paying. `Database.DMLOptions.DuplicateRuleHeader.allowSave` (which preserves
the Report side for ordinary DML) is **not** the right instrument here — the `LeadConvert` setters
are the call-specific API Salesforce added because DML options did not reach the records conversion
creates. **Build-time verification V1 (below) must confirm this on API 67 before the design is
relied on.**

### 5.4 Alternative considered and rejected: deactivate the Contact + Account rules

This is what the org did to the *Lead* rules in `e1f5a9f`, so it is the standing precedent and had
to be examined. Rejected: the Lead rules only ever obstructed the automated pipeline, so turning
them off cost nothing. The Contact and Account rules also protect **every UI-driven creation path
org-wide**; deactivating them to unblock one Apex call would remove duplicate protection from
everyone who never had this problem. The per-call bypass is the same fix, scoped to the caller that
needs it. **The rules stay `isActive=true` and untouched** (D7).

### 5.5 Retained

The existing `catch (DmlException e) → ahe(e.getMessage())` tier in `LeadConvertActionController`
stays as-is and already surfaces any *other* convert failure verbatim. No new exception type, no new
message.

---

## 6. D5 — Converted-lead reuse

**Answer: no interaction. Conversion is per-Lead and nothing about attaching to a shared Contact
changes that.** Stated precisely, because one consequence is worth flagging:

- The July 25 Lead stays converted and untouched. The new Lead converts independently and gets
  **its own new Opportunity** — attaching two Leads to one Contact does **not** fuse their deals.
- `PropertyMatchingService.resolveLiveRecord(leadId)` reads *that specific Lead's*
  `ConvertedOpportunityId`. `Property_Registry__c.Winning_Lead__c` and
  `Competing_Broker_Submission__c.Winning_Lead__c` still point at their own Leads. Routing is
  **unaffected**.
- **⚠ Second-order effect worth recording (no action required now).** Today each conversion mints
  its own Contact, so one Contact fronts ~1 deal. After this change a repeat broker's **single
  Contact fronts N deals**. The EAC adopter already names that as load-bearing —
  *"Failing closed on a Contact `WhoId` is retained and load-bearing — one Contact fronts many
  deals"* (`ARCHITECTURE.md` §, adopter D2). This feature moves that condition from theoretical to
  routine, so the adopter's fail-closed-on-Contact behaviour must not be "optimised" later.
  Relatedly, `EmailThreadGuardService` is **Leads-only by design**, so shared Contacts will
  accumulate more EAC cross-deal timeline noise at the Contact level. **Out of scope; flagged for
  the L-check to observe, not to fix here.**

---

## 7. D6 — Test plan

New: `LeadConvertMatchServiceTest`, `AccountSelectorTest`. Extended: `ContactSelectorTest`,
`LeadSelectorTest`, `LeadConvertActionServiceTest`. All test data via `TestDataFactory`.

### 7.1 Bulk — where 251 actually belongs

`.claude/rules/bulk-test-rule.md` requires 251 for a service method with DML.
`LeadConvertActionServiceTest`'s header already documents a **waiver for `convert()`**:
`Database.convertLead` enforces a per-call ceiling well under 251 in this org (~100), and `convert()`
makes one un-chunked call by contract, so 251 there fails on the platform ceiling before exercising
any of the service's own logic.

**That waiver does not extend to the new service.** `matchForConversion` performs **no DML and no
`convertLead`** — it is pure read + map-build, so 251 is both reachable and meaningful.

- **`matchForConversion_at251Leads_isBulkSafe`** — 251 Leads, mixed (matched-contact /
  matched-account / no-match), one call. Assert every entry is correct **and** that the SOQL count
  delta is **≤ 3** (governor headroom against a named budget). This is the highest-value test in the
  plan: it makes a future change that adds one query per Lead fail *here*, not in production.
- `convert()` keeps its existing small-list (3-Lead) index-alignment proof. Extend the existing
  waiver paragraph in `LeadConvertActionServiceTest`'s header to say where 251 now lives.

### 7.2 Match matrix (through a real `convert()` — `Database.convertLead` cannot be mocked)

| Test | Arrange | Assert |
| --- | --- | --- |
| `contactAndAccountExist_attachesToBoth` | Contact with `Email = lead.Email` under Account A | 0 new Contacts for that email; `Opportunity.AccountId == A`; `Lead.ConvertedContactId == existing` |
| `contactOnly_accountFollowsTheContact` | matched Contact under Account A; `Lead.Company` = some *other* existing account name | Account A wins — `Lead.Company` is **ignored** (the Salesforce constraint) |
| `accountOnly_newContactLandsUnderExistingAccount` | Account named `Lead.Company`; no matching Contact | 0 new Accounts; new Contact created with `AccountId == existing` |
| `neitherMatches_behavesExactlyAsToday` | unique email + unique company | new Account **and** new Contact created (status quo preserved) |
| **`placeholderCompany_doesNotBucketUnrelatedBrokers`** | 2 Leads, `Company = 'Unknown - Via Email'`, **different** emails, no existing Contacts | **2 distinct Accounts.** *This test pins the D1b crux — it must exist and must be named for the decision.* |
| `orphanContactIsNotMatched` | matching Contact with `AccountId = null` | treated as no-match; conversion succeeds |

### 7.3 Determinism (D2)

- `multipleAccountsSameName_oldestWins` and `multipleContactsSameEmail_oldestWins`.
- **Use `Test.setCreatedDate(id, dt)`** to age the records. Do **not** rely on insert order or Id
  ordering — records inserted in one transaction can share a `CreatedDate`, which is exactly why
  `Id ASC` is only the *tiebreak*, and a test built on insert order would be flaky.

### 7.4 D4 — the bypass path

- `nearDuplicateContact_conversionStillSucceeds` — a Contact that the standard Contact rule
  fuzzy-matches (same first/last name, **different** email, so exact matching misses). Without the
  bypass this is the incident; with it, conversion succeeds and a second Contact is created.
  ⚠ The exact standard matching criteria are **not in source control** (§1) — build the fixture from
  what Setup shows, and if the rule cannot be made to fire in a test context, record that in the
  test header and move the assertion to the L-check rather than deleting the test.

### 7.5 FLS / degrade

- `matchReadDenied_degradesToNoMatch` — `System.runAs` a user without `Contact.Email` read; assert
  conversion **succeeds**, `lastRunDegraded == true`, and a duplicate is created (i.e. it fell back
  to today's behaviour rather than throwing).

### 7.6 Regression — must stay green, unchanged

`LeadConvertActionControllerTest`, `LeadConvertActionServiceTest`, `LeadConvertServiceTest`,
`LeadConvertTriggerHandlerTest`.

**Why they should stay green without edits:** `TestDataFactory.createLeads` generates
`Email = 'test.lead<u>@example.invalid'` and `Company = 'Test Company <i>-<u>'` — both unique per
record — so no existing test Lead can match anything and every existing conversion takes the
no-match path.

**Post-convert artifacts must be unchanged** (assert in `contactAndAccountExist_attachesToBoth`, not
only in the isolated cascade tests): `Opportunity.Property__c` populated, `Deal_Type__c` carried,
Land/Commercial `RecordTypeId` set, `Lead_Approved_By__c` stamped.

### 7.7 The E1 anchor check (flagged in the prompt — belongs in both the suite and the L-check)

- `attachingToExistingContact_stillRepointsTheAnchorTask` — put a Broker-Protection anchor Task on
  the Lead (`WhoId = leadId`, `Thread_Key__c` / `Inbound_Message_Id__c` set), convert into a
  **pre-existing** Contact, then assert `Task.WhoId == matchedContactId` **and**
  `Task.WhatId == ConvertedOpportunityId`.
- Expected to pass — this is platform mechanics measured by adopter experiment E1 — but E1 measured
  it against a *conversion-created* Contact. This asserts the same holds when the Contact
  pre-existed. It is cheap, and it is the exact thing whose silent breakage would disable the EAC
  adopter.

---

## 8. D7 — Scope guard

**Not touched:**

- `LeadConvertService` — no change to post-convert stamping, Property creation, record types.
- The Broker Protection routing tree (`ExtractAddressQueueable`, `PropertyClaimService`,
  `EmailToLeadService.createLeadFromExtracted` / `deleteLead`, `PropertyMatchingService`).
- Duplicate rules and matching rules — **`isActive` unchanged**, no metadata edits at all.
- `LeadConvertActionController`, the `leadConvertAction` LWC, `LeadActionPermissionService`, the
  permission model.
- `EmailThreadGuardService` / `EmailThreadAdopterService`.
- No new fields, objects, permission sets, validation rules, flows, or layouts.
- Opportunity naming on conversion is left to the platform — **no `setOpportunityName`.**

**The one exception, requiring explicit approval:** `EmailToLeadService.COMPANY_PLACEHOLDER`
`private` → `public static final`. Visibility only; no behaviour change. §2 D1b explains why this is
better than re-typing the literal.

---

## 9. Verification plan

### Build-time (developer must confirm before relying on this design)

| # | Item | Why it matters |
| --- | --- | --- |
| **V1** | `Database.LeadConvert.setBypassAccountDedupeCheck` / `setBypassContactDedupeCheck` compile at API 67 **and** actually suppress the block. | The whole of D4 rests on it. If they are unavailable or ineffective, **stop and escalate** — the fallback (a user-readable block message) is a different UX decision and needs re-approval. |
| **V2** | Attaching to an existing Contact/Account does **not** overwrite that record's field values with Lead values. | Expected (platform preserves existing records; `setOverwriteLeadSource` defaults false), but if wrong, an LLM-extracted name/title would overwrite good CRM data. Cheap to check; high blast radius. |
| **V3** | The Opportunity name produced when converting into an *existing* Account. | Observation only — record it in a test assertion so a future change notices a shift. No requirement to change it. |
| **V4** | Person Accounts are not enabled in this org. | The whole `setAccountId`/`setContactId` shape differs under Person Accounts. |

### L-check on `usman-dpeg` (live)

1. **Reproduce the incident, then fix it:** re-convert a Lead for
   `usmankhan-96@hotmail.com` and confirm it attaches to Contact `003iw000000UTW4AAO` and that
   Contact's Account, creating **no** new Contact and **no** new Account.
2. **Run it as a real deal-driver persona, not as an admin.** Per the
   `OpportunityActionPermissionService` lesson: a System Administrator's FLS is not representative
   (Metadata-API-deployed fields arrive with no field permissions, and FLS truth lives in the org —
   profiles are `.forceignore`d). An admin smoke test would not exercise the §4 degrade path.
3. **New broker at a known firm:** confirm the Contact lands under the existing firm Account.
4. **Two firm-unknown brokers:** confirm **two** placeholder Accounts, not one (the D1b decision,
   live).
5. **Anchor check:** on a Lead carrying a pipeline anchor Task, confirm post-conversion
   `WhoId` → the pre-existing Contact and `WhatId` → the new Opportunity (§7.7).
6. **Ops follow-up:** admin merges `001iw000001hiTZAAY` + `001iw000001hk76AAA`. Not a prerequisite.

---

## 10. Routing recommendation

**`salesforce-developer`.**

The controller is untouched; the work is one new service, one new selector, two selector methods,
and a ~15-line change in an existing service — standard Apex service/selector work following
patterns this repo already has many instances of. None of the `salesforce-technical-architect`
triggers apply: no ASB/Plaid/Yardi integration, no Named Credentials, no LDV/performance work, no
Platform Events. The architectural decisions (D1–D5) are made in this document; what remains is
conventional implementation, and continuity with the module's existing conventions argues for the
agent that has been building them.

**One escalation condition:** if **V1** fails — the bypass setters are unavailable or do not
suppress the block — stop and route to `salesforce-technical-architect`, because the fallback
changes the conversion UX contract and needs a new Gate-1.

**Then:** `salesforce-unit-testing` → `salesforce-code-review` → `salesforce-devops` +
`salesforce-documentation`.
