# Smart Lead Conversion — Attach to Existing Contact / Account

**Date:** 2026-08-03
**Author:** Documentation Agent
**Status:** Deployed to `usman-dpeg` — validate-first two-phase deploy `0Afiw000000DOirCAG`, 236/236 tests passing.

---

## 📋 Overview

### Original Request

> When a Contact and/or Account already exist matching the converting Lead's person and company, the
> conversion must ATTACH to them (creating only the Opportunity + the module's usual artifacts) instead
> of minting duplicate Contact/Account records.

(`agent-output/design-requirements-lead-convert-matching.md` §0, triggered by a live incident on
`usman-dpeg` — see below.)

### Business Objective

Broker Protection's whole reason for existing is that the **same broker firms submit deals to DPEG
over and over** — repeat submission is the normal shape of this business, not an edge case.
`BrokerFirmController` already assumes it: it aggregates every Opportunity on an Account into that
firm's submitted/won/lost counts. But before this change, a repeat broker's **second** Lead conversion
was guaranteed to fail outright, because standard Lead conversion always tried to mint a brand-new
Contact and Account, and the org's own active duplicate rules blocked it. Smart Lead Conversion makes
conversion recognize a broker (and their firm) it already knows, and attach the new deal to the
existing person and firm instead of failing or duplicating them — while being careful not to
mis-attribute a deal to the wrong broker in the process.

### Summary

`LeadConvertActionService.convert()` — the only place in the app that calls `Database.convertLead` —
now asks a new read-only service, `LeadConvertMatchService`, whether the converting Lead's email
matches an existing Contact and/or its company name matches an existing Account, and applies
`setContactId`/`setAccountId` when it does. Independently, every conversion now also bypasses the
standard Contact/Account duplicate-rule block (`setBypassContactDedupeCheck` /
`setBypassAccountDedupeCheck`), because that block is a UI artifact of headless Apex conversion, not
the rules' actual configured intent. The build is one new service, one new selector (`AccountSelector`
— the first Account SOQL in the app), two new selector methods, and a small change to the existing
convert path; the controller and LWC are untouched. A validate-first, two-phase deploy caught 7
pre-existing/self-inflicted test-fixture bugs before they ever reached the org, and a deploy-time FLS
audit (prompted by a code-review correction) found and closed a real permission-set gap before go-live.

---

## 🚨 The Triggering Incident

Converting the Lead *Usman Khan / `usmankhan-96@hotmail.com` / "Unknown - Via Email"* on `usman-dpeg`
failed live with `DUPLICATES_DETECTED, Duplicate Alert: []`. That broker already existed as a Contact
from an earlier conversion, so standard Lead conversion tried to mint a **second** Contact for the same
person, and the org's active `Standard_Contact_Duplicate_Rule` blocked the entire all-or-none
`Database.convertLead` call.

The rule's own configuration is `actionOnInsert=Allow`, `operationsOnInsert=Alert,Report` — "warn a
human, let them continue." Apex-driven conversion has no surface on which to render that alert, so the
platform degrades "Alert" into a hard block. That is not the rule's configured intent; it is the
absence of a UI. From the headless "Convert" quick action the user cannot merge, review, or override —
the failure is simply terminal for that Lead.

Because **repeat brokers are the norm** in this app, this was not a rare-edge-case bug: it meant every
broker's second-and-later deal was unconvertible through the button the moment they became a Contact.

---

## 🧠 The Matching Design

`LeadConvertMatchService.matchForConversion(List<Id> leadIds)` decides, for a batch of Leads at once,
what each one's conversion should attach to. It is read-only (zero DML), and every read goes through a
selector — `LeadSelector.selectMatchKeysByIds`, `ContactSelector.selectByEmails`,
`AccountSelector.selectByNames` — exactly 3 SOQL total regardless of how many Leads are passed.

### Contact wins on email alone

A Contact matches only when `Contact.Email = Lead.Email` (SOQL string comparison on Email is
case-insensitive by default, so no `LOWER()` is needed). The person's **name is deliberately unused**,
neither as a requirement nor as a widener:

- **Not a requirement**, because the Lead's name is LLM-extracted from a forwarded signature block and
  is the least stable value on these records — "Usman Khan," "Usman A. Khan," and "Khan, Usman" are all
  reachable for the same broker. Requiring a name match would make the feature miss exactly the case it
  exists to catch, and mint the duplicate anyway.
- **Not a widener**, because matching on name when the email differs would fuse two different people
  who happen to share a name — say, two unrelated brokers both named "John Smith" at two different
  firms — into one Contact, silently attaching a deal to the wrong person.

The asymmetry is the whole argument: a **missed** match creates a duplicate, which a human can merge; a
**wrong** match mis-attributes a deal, which the user cannot undo from a headless quick action and is
the precise opposite of what Broker Protection exists to prevent. The design deliberately **prefers the
recoverable failure**.

### Account matches by name only when no Contact matched, and never on the placeholder

Because Salesforce requires a specified Contact's own Account to be the conversion target, a Contact
match always wins and dictates the Account — `Lead.Company` is consulted for an Account match only when
no Contact matched at all.

The crux decision is what happens with `EmailToLeadService.COMPANY_PLACEHOLDER`
(`'Unknown - Via Email'`, the fallback `Lead.Company` value whenever the LLM extraction pipeline could
not identify a firm). **The placeholder must never account-match**, even against an Account literally
named that placeholder string. The reason lives in `BrokerFirmController.getBrokerFirm`: it aggregates
**every** Opportunity on an Account into that firm's submitted/won/lost deal counts, and names the
earliest-created Contact on the Account as "the broker." Bucketing every firm-unknown broker into one
shared placeholder Account would put an **actively wrong answer on a live page** — every unrelated
broker's deals shown as one firm's, a random other broker named as "the broker" — in the one module
whose entire purpose is broker attribution. It also buys nothing: the repeat-broker case this feature
exists for is already solved by the Contact match, which reuses that broker's own Account.
`'Unknown - Via Email'` is not a firm name; as the class header puts it, "it is a null wearing a
string," and matching records on a null value is a category error.

Under this rule the placeholder Account proliferates **once per distinct broker** (a legitimate
per-broker firm stub awaiting a real name), never once per conversion. Where the Account match *does*
earn its keep is the genuine "company half" of the original request: a brand-new broker (no Contact
yet) whose email carried a real firm name — e.g. `Company = 'Marcus & Millichap'` — lands their new
Contact under the existing firm Account instead of minting a second one.

### Oldest wins, deterministically

Both the Contact-by-email and Account-by-name selector reads are ordered `CreatedDate ASC, Id ASC`, and
the matcher takes the first row per key. Oldest wins because it carries the most history and is the
record a manual merge would keep as master, so code and a human reviewer converge on the same answer.
`Id ASC` is the tiebreak, not an afterthought: rows created in the same transaction can share a
`CreatedDate`, so without it the pick would not be a total order and the target could oscillate between
duplicate records across separate conversions. Because the order is ascending, the rule is
**convergent** — a newly created duplicate can never displace the canonical target.

### The orphan filter

`ContactSelector.selectByEmails` filters `AccountId != null` **in the query itself**, not as a
post-filter, because a Contact without an Account cannot legally be a `setContactId` target — Salesforce
requires that Contact's own Account to also be the target. Filtering in the query means the caller has
no special case to remember: an account-less Contact simply never appears as a candidate. Accepted
consequence: a broker whose only Contact record has no Account still gets a duplicate on this
conversion — acceptable, because every Contact in this org is conversion-born and always carries an
Account.

---

## 🚦 D4 — Bypassing the Duplicate Rules

`Standard_Contact_Duplicate_Rule` and `Standard_Account_Duplicate_Rule` both stay `isActive=true` and
untouched by this feature — deliberately. What changes is that `LeadConvertActionService.convert()` now
sets `setBypassAccountDedupeCheck(true)` and `setBypassContactDedupeCheck(true)` on **every**
`Database.LeadConvert`, matched or not. These are the API-44+, call-specific setters Salesforce added
because the ordinary `Database.DMLOptions.DuplicateRuleHeader.allowSave` mechanism does not reach the
records a conversion itself creates.

The justification is the rules' own configuration: `actionOnInsert=Allow`,
`operationsOnInsert=Alert,Report` is already "warn a human, let them continue" — the bypass restores
that intent where Apex conversion cannot render it. Since exact email/name matching (above) already
removes the common duplicate source, what the bypass actually covers is the residual **fuzzy near-miss**
— the same person at a slightly different email, or a near-identical firm name — which is rare and, if
it does happen, is recoverable with a manual merge.

**Accepted cost, stated rather than hidden:** bypassing skips the rule **entirely**, including its
`Report` operation, so **no `DuplicateRecordSet` is logged** for a conversion-created duplicate. That
cost is judged worth paying because record creation is not this module's fail-closed boundary — its
fail-closed philosophy is about claims and authorization (who wins a property, who may act), not about
whether a second Contact gets created. A rejected alternative was deactivating the Contact/Account rules
org-wide, the same fix already applied to the *Lead* rules in commit `e1f5a9f`. That precedent was
examined and rejected here: the Lead rules only ever obstructed the automated inbound pipeline, so
turning them off cost nothing, but the Contact/Account rules protect every UI-driven creation path in
the org — deactivating them to unblock one Apex call would strip duplicate protection from every user
who never had this problem. The per-call bypass is the same fix, scoped only to the caller that needs
it. The mitigation for the accepted cost is the **W2 Duplicate Job** — a scheduled, declarative job
that is not yet built — which is what will surface bypass-created duplicates on a lag, since the
bypass itself suppresses the org's own real-time Report signal.

---

## 🪶 Fail-Soft, and the Reviewer's W1 Correction

`Lead.Email` and `Contact.Email` are FLS-permissionable fields, and both selector reads run
`WITH USER_MODE` (the interactive-path default). `USER_MODE` **throws** rather than degrading when the
running user lacks read access — a raw throw here would have regressed conversion for users who convert
Leads perfectly well today. So `LeadConvertMatchService.matchForConversion` wraps every read in a
`try`/`catch(System.QueryException)`, sets a `@TestVisible` `lastRunDegraded` flag, logs at
`LoggingLevel.ERROR`, and returns an **empty map** — the caller then converts exactly as it would have
before this feature existed.

The code review's **W1 finding** sharpened what "exactly as before" actually means. It is tempting to
describe a degrade as a harmless return to the status quo, but the always-on D4 bypass shipped in the
same change and does **not** degrade — so for a repeat broker, the real before/after is:

- **Before this change:** a loud, terminal `DUPLICATES_DETECTED` block. The deal is stranded, but
  nothing is silently created.
- **A degraded run after this change:** the conversion **succeeds** and **silently** creates a
  duplicate Contact.

A degrade therefore converts a loud failure into silent duplicate accumulation. That trade is still
judged correct — a duplicate is recoverable by merge; a stranded deal is not, and the user can neither
merge nor override from a headless quick action — but it is a **new accepted cost** this feature
introduces, not a return to the pre-existing baseline. Because a silent degrade is now something worth
actively avoiding rather than merely tolerating, W1 promoted the FLS state of every convert-capable
persona from a nice-to-have into a **verified deploy gate**: every persona who can click Convert must
hold read on **both** `Lead.Email` and `Contact.Email`, or matching degrades permanently for them,
invisibly, unless someone happens to notice duplicates reappearing.

Running that gate against the real permission-set model — not as an admin, since an admin's FLS is not
representative and would prove nothing — found the gap **exactly as the reviewer's W1 finding
predicted**: the two permission sets that literally gate the Convert action —
`Broker_Protection_Access` and `Lead_Stage_Actions_Access`, the pair `LeadActionPermissionService`
accepts as authorizing it — had **zero** `FieldPermissions` rows for either `Lead.Email` or
`Contact.Email` at all (queried directly against the org: `FieldPermissions` where
`Parent.IsOwnedByProfile = false`). The base, per-object `DPEG_Acquisition_Edit`/`DPEG_Acquisition_View`
sets already carried `Lead.Email` but were missing `Contact.Email`. `DPEG_Contact_Edit`,
`DPEG_Contact_View`, and the two permission-set groups (`DPEG_Junior_Analyst_PSG`,
`DPEG_Principal_PSG`) already held their own grants and were **not** touched.

Six `FieldPermissions` rows were created **directly in the org** on 2026-08-03 — deliberately in-org
first rather than via a metadata deploy, to avoid `Broker_Protection_Access`'s own documented
redeploy-drops-FLS trap (its header already warns that redeploying that file has been observed to
silently drop other field rows) — and independently re-verified by re-query afterward:

| Permission Set | Field | Org Record Id |
|---|---|---|
| `Broker_Protection_Access` | `Lead.Email` | `01kiw00000TREe5AAH` |
| `Broker_Protection_Access` | `Contact.Email` | `01kiw00000TREfhAAH` |
| `Lead_Stage_Actions_Access` | `Lead.Email` | `01kiw00000TQtbrAAD` |
| `Lead_Stage_Actions_Access` | `Contact.Email` | `01kiw00000TREhJAAX` |
| `DPEG_Acquisition_Edit` | `Contact.Email` | `01kiw00000TRDGQAA5` |
| `DPEG_Acquisition_View` | `Contact.Email` | `01kiw00000TPIfBAAX` |

`DPEG_Acquisition_Edit`/`DPEG_Acquisition_View`'s `Lead.Email` rows (`01kiw00000SIwsrAAD` /
`01kiw00000SIwv7AAD`) pre-existed and are not part of this fix. All four affected permission-set XMLs —
`Broker_Protection_Access`, `Lead_Stage_Actions_Access`, `DPEG_Acquisition_Edit`,
`DPEG_Acquisition_View` — were synced in the same change to declare these org-created rows, so the repo
matches the org (the same org-first, declare-after convention `Broker_Protection_Access` already used
for its `Task.WhoId` row). `Broker_Protection_Access`'s own header was updated accordingly: its
verification query now expects `Lead 28` (was 27) plus a new `Contact 1` group.

---

## 🔬 V1 — The Causal Proof Behind D4

The whole D4 design rests on one premise: that `setBypassAccountDedupeCheck` /
`setBypassContactDedupeCheck` actually compile at API 67 and actually suppress the block. This was
flagged in the design as a hard escalation condition — if it failed, D4's entire UX contract would need
re-approval through a new Gate-1 with `salesforce-technical-architect`.

It was proven, not assumed. On `DPEG-Acq-5`, with both standard Contact and Account duplicate rules
confirmed active, **4 scratch-org probes** were run in which the *only* variable that changed between
probes was the presence or absence of the two setter calls — everything else about the fixture, the
rules, and the org was held constant. An identical fixture was **blocked** (`DUPLICATES_DETECTED`) when
converted without the setters and **succeeded** when converted with them. That causal result is what
D4 relies on; `LeadConvertActionServiceTest.convert_nearDuplicateContactWithRulesActive_stillSucceeds`
is explicitly documented in its own comment as a **smoke test standing guard over that result**, not a
second proof of it — the org's standard fuzzy-matching criteria are not in source control, so the test
can only assert the contract ("conversion still succeeds with the rules active"), never that a
particular rule actually fired.

---

## 🚀 The Validate-First Payoff

The deploy to `usman-dpeg` used a validate-first, two-phase sequence: a validate-only run executes the
full local Apex test suite against the target org without committing any metadata, so a broken test
costs only time, never a rollback.

**The first validate run caught 7 test failures this way, all fixed before anything was committed:**

**Five were self-inflicted by this feature's own new tests.** `TestDataFactory.createAccounts` has
always built every factory Account with `BillingCity = 'Houston'`, `BillingState = 'TX'` — a shared
default nobody had reason to notice until this feature's tests started deliberately creating multiple
factory Accounts in the same transaction (the D2 oldest-wins tie-break tests, and
`AccountSelectorTest`'s 251-row bulk test). The standard Salesforce Account duplicate rule matches on a
fuzzy combination that these shared, identical billing values feed into, so any two factory Accounts in
one transaction began fuzzy-matching each other and tripping `DUPLICATES_DETECTED` on insert. Fixed two
ways: a new `TestDataFactory.insertAllowingDuplicates(List<SObject>)` helper (`Database.insert` with
`DMLOptions.DuplicateRuleHeader.allowSave = true`, `optAllOrNone` still `true` so a genuine failure
still throws loudly — only the duplicate *alert* is suppressed) for the tests that deliberately seed
duplicate-shaped rows as the only way to express a tie-break; and, for the 251-row bulk test, swapping
the factory's plain counter-suffixed names for high-entropy random tokens per row, since "251 distinct
names" had been true and irrelevant — the fuzzy rule doesn't care about distinctness, only similarity.

**Two were pre-existing and unrelated to this feature's own logic.** `BrokerPortalControllerTest` and
`BrokerPortalServiceTest` each had one test (`submitDeal_insertFails_...`) whose forced-failure
mechanism depended on "this org's active Lead duplicate rule (Block)." That premise was wrong on both
counts: `Standard_Lead_Duplicate_Rule` has been `isActive=false` since commit `e1f5a9f` (2026-07-25),
and even when active it is `actionOnInsert=Allow`/`operationsOnInsert=Alert,Report` — an alert rule,
never a block rule. Both tests had therefore been asserting nothing meaningful — both inserts always
succeeded and nothing ever threw — until this validate run's broader test execution surfaced the
failing assertion. Both were fixed by rebuilding the forced failure on the `@TestVisible` queue seam
production already exposes for exactly this kind of deterministic test control (the same seam
`submitDeal_queueNotConfigured_rejected` already uses): pointing `BrokerPortalService.cachedQueueId` at
a Contact Id — syntactically valid, but one `Lead.OwnerId` cannot accept, since only a User or a Queue
can own a Lead — forces an org-independent `DmlException` at the exact line under test, with no
dependency on any org-configurable duplicate-rule behavior at all.

This is genuine pre-existing org test-debt, surfaced as a byproduct of this feature rather than caused
by it — a reminder that any test coupled to undocumented, Setup-configurable org behavior (duplicate
rule actions, in this case) is inherently fragile, independent of Smart Lead Conversion.

The second, clean validate run — with all 7 fixed — became the deploy itself:
**236/236 tests passing, deploy `0Afiw000000DOirCAG`.**

---

## 🗂️ Operational Notes

**A repeat broker's Contact now fronts N deals, not one.** Before this feature, each conversion minted
its own Contact, so one Contact fronted roughly one deal. After it, a repeat broker's single Contact
fronts every deal they have ever submitted. Design D5 flagged this as a foreseeable second-order effect,
and it makes routine a condition the EAC Thread Guard/Adopter feature already treats as load-bearing,
not incidental: `ARCHITECTURE.md`'s `EmailThreadGuardService` entry states plainly that "failing closed
on a Contact `WhoId` is retained and load-bearing — one Contact fronts many deals." This feature moves
that from a theoretical edge case to the everyday shape of the data, so that fail-closed behavior must
not be "optimized" away later on an assumption this feature has now made false.

**A placeholder-Account-naming follow-up (S2) was filed, not built here.** Because the placeholder
Company never account-matches (D1b), `'Unknown - Via Email'` Accounts now proliferate once per distinct
firm-unknown broker by design. That is semantically correct, but it means a rep browsing Accounts will
see many indistinguishable "Unknown - Via Email" rows over time. A cosmetic follow-up — a more
informative default name, or a later rename workflow once a real firm is identified — was filed rather
than built as part of this change.

**A systemic `TestDataFactory` change was filed, not built here.** This build worked around the
Houston/TX-driven fuzzy-Account-match problem locally, inside the tests that needed it
(`insertAllowingDuplicates` plus higher-entropy names), rather than changing `createAccounts`'s own
shared defaults — doing that would be a much wider-blast-radius change touching every existing test
built on that factory method across the whole org. Whether the factory itself should carry more name
entropy by default, or default new Account creation to `allowSave`, was filed as a follow-up rather than
done inline here.

---

## 🏗️ Components Created / Modified

No new custom objects, fields, LWC, Flows, or Named Credentials. The controller
(`LeadConvertActionController`) and the `leadConvertAction` LWC are explicitly **unchanged** — the
design deliberately wires matching and the bypass into the service layer, so "attach when possible" is
an invariant of conversion itself rather than of one button.

### Apex Classes — new

| Class | Layer | Responsibility |
|---|---|---|
| `LeadConvertMatchService` | Service, `with sharing` | Decides what a Lead conversion should attach to. Read-only, 3 SOQL total regardless of batch size, fail-soft on denied FLS reads. |
| `AccountSelector` | Selector, `with sharing` | **First Account SOQL in the application.** `selectByNames(Set<String>)` — exact, case-insensitive, ordered `CreatedDate ASC, Id ASC`. |

### Apex Classes — modified

| Class | Layer | Change |
|---|---|---|
| `LeadConvertActionService` | Service | `convert()` now calls `LeadConvertMatchService.matchForConversion`, applies `setContactId`/`setAccountId` on a hit, and sets the D4 bypass setters unconditionally. ~15 lines. |
| `ContactSelector` | Selector | New outer-class method `selectByEmails(Set<String>)` — exact email match, `AccountId != null`, oldest-wins ordering. Deliberately on the outer (internal/`USER_MODE`) class, not the guest `GuestReads` nested class. |
| `LeadSelector` | Selector | New method `selectMatchKeysByIds(Set<Id>)` — `Id, Email, Company` only, `WITH USER_MODE`. |
| `EmailToLeadService` | Service | Visibility-only change: `COMPANY_PLACEHOLDER` `private` → `public static final`, so `LeadConvertMatchService` reads the same literal instead of re-typing it. Zero behavior change. |
| `TestDataFactory` | Test factory | New helper `insertAllowingDuplicates(List<SObject>)` — `Database.insert` with `DuplicateRuleHeader.allowSave = true`, `optAllOrNone` still `true`. Added 2026-08-03 during the validate-first fix cycle (see below). |

### Test Classes — new / extended

| Test Class | Change |
|---|---|
| `LeadConvertMatchServiceTest` | New — 14 test methods covering the match matrix, the D1b placeholder decision, D2 determinism, the orphan guard, the fail-soft seam, and a 251-Lead bulk/governor-headroom proof. |
| `AccountSelectorTest` | New — 6 test methods covering exact match, case-insensitivity, D2 ordering, no-match, null/empty short-circuit, and a 251-row bulk proof. |
| `LeadConvertActionServiceTest` | Extended — 4 new "Smart Conversion" methods (existing-Contact-and-Account attach, the D4 near-duplicate smoke test, the E1 anchor-Task repoint check, the V2 no-overwrite check), alongside the 5 pre-existing tests, unchanged. |
| `ContactSelectorTest` | Extended — 8 new methods for `selectByEmails` (exact match, orphan exclusion, case-insensitivity, D2 ordering, no-match, null/empty short-circuit, 251-row bulk). |
| `LeadSelectorTest` | Extended — 4 new methods for `selectMatchKeysByIds` (field shape, Id scoping, null/empty short-circuit, 251-Lead bulk). |
| `BrokerPortalControllerTest` | Fixed — 1 pre-existing test's forced-failure mechanism rebuilt on the `@TestVisible` queue seam (see Validate-First Payoff below). Unrelated to this feature's own logic. |
| `BrokerPortalServiceTest` | Fixed — same rebuild, service-layer counterpart. Unrelated to this feature's own logic. |

### Permission Sets — FLS deploy-gate fix

| Permission Set | Field Added (org-created 2026-08-03) | Access | Org Record Id |
|---|---|---|---|
| `Broker_Protection_Access` | `Lead.Email` | Read | `01kiw00000TREe5AAH` |
| `Broker_Protection_Access` | `Contact.Email` | Read | `01kiw00000TREfhAAH` |
| `Lead_Stage_Actions_Access` | `Lead.Email` | Read | `01kiw00000TQtbrAAD` |
| `Lead_Stage_Actions_Access` | `Contact.Email` | Read | `01kiw00000TREhJAAX` |
| `DPEG_Acquisition_Edit` | `Contact.Email` | Read | `01kiw00000TRDGQAA5` |
| `DPEG_Acquisition_View` | `Contact.Email` | Read | `01kiw00000TPIfBAAX` |

`DPEG_Acquisition_Edit`/`DPEG_Acquisition_View` already held `Lead.Email` before this fix (pre-existing
grants, unchanged); `DPEG_Contact_Edit`/`DPEG_Contact_View` and the `DPEG_Junior_Analyst_PSG`/
`DPEG_Principal_PSG` permission-set groups already held their own grants and were not touched. All six
rows above were created **directly in the org**, not via metadata deploy (to avoid
`Broker_Protection_Access`'s documented redeploy-drops-FLS trap), then declared in all four affected
permission-set XMLs so the repo matches the org. See the Fail-Soft section above for the full finding.

---

## 🔄 Data Flow

```
Lead "Convert" quick action
        │
        ▼
LeadConvertActionController  (unchanged — thin, catch → AuraHandledException)
        │
        ▼
LeadConvertActionService.convert(leadIds)
        │
        ├──► LeadConvertMatchService.matchForConversion(leadIds)   [read-only, 3 SOQL total]
        │        │
        │        ├─ LeadSelector.selectMatchKeysByIds      → Id, Email, Company
        │        ├─ ContactSelector.selectByEmails          → exact Email, AccountId != null,
        │        │                                             oldest wins
        │        └─ AccountSelector.selectByNames           → exact Name (skips the
        │                                                      COMPANY_PLACEHOLDER), oldest wins
        │        │
        │        ▼
        │   Map<LeadId, ConversionMatch{accountId, contactId}>
        │   (denied FLS read → empty map, lastRunDegraded = true)
        │
        ▼
For each Lead: build Database.LeadConvert
    • setContactId / setAccountId  when matched (Contact always dictates its own Account)
    • setBypassContactDedupeCheck(true) / setBypassAccountDedupeCheck(true)  — ALWAYS
        │
        ▼
Database.convertLead(conversions)   — single all-or-none call
        │
        ▼
LeadConvertTrigger → LeadConvertService   (unchanged — stamps Opportunity, creates Property__c)
```

---

## 📁 File Locations

| Component Type | Path |
|---|---|
| New Apex | `force-app/main/default/classes/{LeadConvertMatchService,AccountSelector}.cls` |
| New tests | `force-app/main/default/classes/{LeadConvertMatchServiceTest,AccountSelectorTest}.cls` |
| Modified Apex | `force-app/main/default/classes/{LeadConvertActionService,ContactSelector,LeadSelector,EmailToLeadService,TestDataFactory}.cls` |
| Modified/extended tests | `force-app/main/default/classes/{LeadConvertActionServiceTest,ContactSelectorTest,LeadSelectorTest,BrokerPortalControllerTest,BrokerPortalServiceTest}.cls` |
| Permission sets | `force-app/main/default/permissionsets/{Broker_Protection_Access,Lead_Stage_Actions_Access,DPEG_Acquisition_Edit,DPEG_Acquisition_View}.permissionset-meta.xml` |
| Design doc | `agent-output/design-requirements-lead-convert-matching.md` |
| Architecture reference | `ARCHITECTURE.md` §2 (Key Apex Services — `LeadConvertActionService`, `LeadConvertMatchService`, `AccountSelector` entries; already updated in the same change) |

---

## 🧪 Testing

### Code Review Verdict

**Gate 2 — APPROVED WITH WARNINGS.** Two warnings were raised and both were operationalized directly
into the deploy sequence rather than blocking it:

| Warning | Resolution |
|---|---|
| W1 — the fail-soft degrade is not a return to the pre-change status quo; the always-on D4 bypass changes the real baseline | ✅ Operationalized as the deploy-time FLS gate: queried the org directly (not as an admin) and found the gap exactly as predicted — `Broker_Protection_Access` and `Lead_Stage_Actions_Access` (the sets that gate Convert) had zero Email FLS, and the Acquisition base sets were missing `Contact.Email`. Fixed via 6 `FieldPermissions` rows created directly in-org and verified, then declared across the 4 affected permission-set XMLs (see Components table). |
| W2 — the D4 bypass silences the duplicate rules' `Report` operation, so no `DuplicateRecordSet` is logged for a bypass-created duplicate | **Still open** — a scheduled, declarative Duplicate Job (not yet built) is the planned mitigation; it will surface bypass-created duplicates on a lag rather than in real time. |

### Test volume

36 new or changed test methods across 7 test classes (2 new: `LeadConvertMatchServiceTest`,
`AccountSelectorTest`; 3 extended: `LeadConvertActionServiceTest`, `ContactSelectorTest`,
`LeadSelectorTest`; 2 fixed but logically unrelated: `BrokerPortalControllerTest`,
`BrokerPortalServiceTest`). Full-suite deploy result: **236/236 tests passing**, deploy
`0Afiw000000DOirCAG`.

### Bulk-Test-Rule application

`LeadConvertActionService.convert()` keeps its existing, documented waiver from the 251-record mandate
— `Database.convertLead` enforces a per-call ceiling well under 251 in this org, and `convert()` makes
one un-chunked call by contract. That waiver does **not** extend to `LeadConvertMatchService`, which
performs no DML and no conversion call: `matchForConversion_at251Leads_isBulkSafe` drives a real
251-Lead batch and asserts the SOQL delta stays **≤ 3**, so a future change that adds one query per Lead
fails in this test rather than in production. `AccountSelectorTest` and `ContactSelectorTest` each carry
their own independent 251-row bulk proof for the underlying selector query.

---

## 🔒 Security

- `LeadConvertMatchService` and `AccountSelector` are `with sharing`, per `ARCHITECTURE.md` §2. A
  Contact or Account the converting user cannot see will not match — a duplicate results, silently, the
  same outcome as before this feature for that user. If that bites in production, the remedy is a
  sharing rule, not `without sharing` Apex.
- All three new/extended selector reads (`LeadSelector.selectMatchKeysByIds`,
  `ContactSelector.selectByEmails`, `AccountSelector.selectByNames`) run `WITH USER_MODE` — the
  interactive, user-initiated default (this is a user clicking Convert, not the guest/automation path
  that earns `SYSTEM_MODE` elsewhere in this module).
- `Lead.Email` and `Contact.Email` are FLS-permissionable and can throw under `USER_MODE`;
  `LeadConvertMatchService` catches that and fails soft rather than regressing conversion — see the
  Fail-Soft section above for why that degrade is a new accepted cost, not a free pass, and why it
  drove a verified deploy gate.
- The D4 duplicate-rule bypass is **unconditional** on every conversion (matched or not) and is an
  accepted, stated cost — it silences the `Report` side of the org's active Contact/Account duplicate
  rules for conversion-created records only. The rules themselves remain `isActive=true` and untouched
  for every other creation path in the org.
- `Database.convertLead` itself still enforces the running user's own "Convert Leads" permission and
  Create access on Account/Contact/Opportunity; a `DmlException` from either is left to propagate to
  `LeadConvertActionController`'s existing catch ladder, unchanged by this feature.

---

## 📝 Notes & Considerations

### Known Limitations / Deferred

| # | Item | Status |
|---|---|---|
| W2 | No durable, real-time signal for a bypass-created duplicate (the `Report` operation is silenced by the bypass) | **Open** — scheduled Duplicate Job filed as the planned mitigation, not yet built. |
| — | Placeholder-Account naming (S2) — `'Unknown - Via Email'` Accounts proliferate once per distinct firm-unknown broker, which is correct but not very legible in an Account list | Filed, not built. |
| — | `TestDataFactory.createAccounts`'s shared `BillingCity`/`BillingState` defaults make any two factory Accounts in one transaction fuzzy-duplicate-shaped | Worked around locally in this feature's tests (`insertAllowingDuplicates` + high-entropy names); a systemic factory-level fix was filed, not built here. |
| L1 | A broker whose only Contact has no `AccountId` still gets a duplicate on conversion | Accepted — this org's Contacts are conversion-born and always carry an Account, so this is not expected to bite in practice. |
| L2 | A Contact/Account the converting user cannot see (sharing) will not match | Accepted — same outcome as before this feature; remedy is a sharing rule if it bites. |

### Dependencies

- `TestDataFactory` (org-wide test factory) — extended with `insertAllowingDuplicates`, used by this
  feature's own tests and available to any future test that must deliberately seed duplicate-shaped rows.
- `EmailToLeadService.COMPANY_PLACEHOLDER` — now `public`, read directly by `LeadConvertMatchService`
  rather than re-typed, so the two classes cannot drift apart if the placeholder literal is ever
  reworded.
- `BrokerFirmController` / `OpportunitySelector.countByStageForAccount` — the decisive evidence behind
  the D1b no-bucketing decision; not modified by this feature, but load-bearing to its design.
- `LeadActionPermissionService` — the authorization gate this feature's FLS audit was run against
  (`Broker_Protection_Access` OR `Lead_Stage_Actions_Access`); not modified by this feature.

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-03 | Documentation Agent | Initial creation — documents Smart Lead Conversion (attach-to-existing-Contact/Account on Lead convert): the triggering incident, the D1/D2 matching design, the D4 duplicate-rule bypass, the fail-soft/W1 baseline correction and resulting FLS deploy gate, the V1 causal proof, the validate-first deploy's 7 caught test failures, and operational follow-ups. `ARCHITECTURE.md` §2 was already updated for this feature in the same change by the developer agent; not re-edited here. |
| 2026-08-03 | Documentation Agent | **Correction** — the FLS section originally misidentified which permission sets had the gap (named `DPEG_Contact_Edit`/`DPEG_Contact_View`, which were never touched) and hedged that only 4 of 6 `FieldPermissions` rows could be confirmed. Corrected against the authoritative org-query record: the gap was in `Broker_Protection_Access` and `Lead_Stage_Actions_Access` (zero Email FLS each) plus `DPEG_Acquisition_Edit`/`DPEG_Acquisition_View` (missing `Contact.Email` only); all 6 rows were created directly in-org (record Ids now cited) and the 4 correct permission-set XMLs were synced to match. The earlier read was a parallel-edit timing artifact (permission-set XMLs were still being synced by the admin agent while this doc's first pass read them), not a real discrepancy in row count. |
