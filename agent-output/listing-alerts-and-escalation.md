# Stalled-Listing Escalation on `Broker_Listing__c` — Design Requirements

**Date:** 2026-08-21
**Author:** Salesforce Design Agent
**Branch at time of writing:** `feature/acquisitions-fsd-tranche-1`
**Status:** 🔴 **NOT READY TO IMPLEMENT.** Six blocking gates are open (§10). Four of the user's
inputs collide head-on with decisions this repo made deliberately, argued in file headers, and
shipped — those are §1 and must be resolved by the user before any agent is invoked.

**Verification basis.** Every claim below is grounded in a file read during this pass and the path is
quoted inline. This agent has **no org access and no `salesforce-api-context` MCP** — nothing here is
measured against `usman-dpeg`. Anything that would require an org read is marked ⚠ UNVERIFIED rather
than asserted.

---

## 0. The single most important finding

**Both cards in this brief have already been built, and Card 1 was built as a literal hardcoded mock
of this exact table — then deliberately deleted on 2026-08-10 with reasons recorded in the file that
replaced it.**

`force-app/main/default/lwc/listingAlerts/listingAlerts.js` lines 4–18 quote the deleted markup
verbatim:

```
 *     Day 21   ->  No offers -> email to Junior
 *     Week 4   ->  YELLOW flag on Junior dashboard
 *     Week 6   ->  Hard prompt + alert to Junior + Ali
 *     Offer in ->  Clock PAUSES - Disposition Offer created
```

That is, word for word, the user's Card 1. The same file then states why each row was removed:

> *"Rows 1-3 advertised the 6-WEEK CLOCK that D27.1 overturned (the document allows ~2 months with a
> month-1 check). Rows 1 and 3 promised NOTIFICATIONS that D9 defers and that nothing in this org
> sends… Row 4 asserted a 'Clock PAUSES' rule that appears in NO document, NO decision and NO code."*

**This request is therefore not a new feature. It is a reversal of D27.1, D28/Q1, D28/Q2, D28/Q4 and
D9 — five recorded decisions.** That reversal may be entirely correct (the client owns the process),
but it must be made knowingly, because the code that replaced the mock is not inert scaffolding: it
is a live, tested, two-consumer computation whose thresholds are asserted by
`DispositionTractionServiceTest` and rendered on the record page today.

One point in the repo's favour of proceeding:
`force-app/main/default/classes/DispositionTractionService.cls` lines 29–32 states its own
revision rule —

> *"D28 also notes this is the SECOND time these numbers have been disputed; a third revision is the
> point at which to revisit, not before."*

This is the third dispute. By the code's own rule, revisiting is now in order. What is **not** in
order is changing the numbers without also updating that header, or leaving two ladders live.

---

## 1. 🔴 Direct conflicts with what is already built

Each of these is a user-confirmed decision colliding with a shipped, argued decision. **I am not
re-opening the user's decisions — I am reporting that implementing them changes behaviour someone
else deliberately chose, and naming what breaks.**

### C-1. The thresholds. Week 1/4/6 (7/28/42 days) vs. the shipped 30/40/60.

| | Shipped today | This brief |
|---|---|---|
| Rung 1 | Day 30 `CHECKPOINT_DUE` | Week 1 (day 7) — email Junior |
| Rung 2 | Day 40 `REVIEW_OVERDUE` | Week 4 (day 28) — yellow dashboard flag |
| Rung 3 | Day 60 `HARD_STOP` | Week 6 (day 42) — hard prompt + Junior & Ali |
| Full period | 60 days | 42 days |

`classes/DispositionTractionService.cls` lines 7–33 derives 30/60 from
`docs/DPEG-Stage-by-Stage.docx` Part 2 line 213 (*"about two months on the market… no traction within
the first month"*) and calls that document **authoritative over the deployed 6-week Path guidance**
(D27.1). Adopting 7/28/42 re-instates the guidance that document overturned.

**⚠ Blocking gate G1.** Which source wins — `DPEG-Stage-by-Stage.docx` Part 2 line 213, or the
client's Week 1/4/6 schedule? If the schedule wins, `DispositionTractionService`'s §1 header block
must be rewritten as a retraction (the repo's house style: quote-and-retract, not delete — see
`objects/Disposition__c/validationRules/All_NDAs_Signed_Before_Progression.validationRule-meta.xml`
lines 26–52 for the pattern), and the docx should be corrected or explicitly overridden.

⚠ The brief also says *"Week 1 behaviour = Same as the mockup's Day 21."* The mockup's rung was
**Day 21**, not Day 7. Confirmed at `lwc/listingAlerts/listingAlerts.js:7`. I have read this as "the
same **action** (no offers → email Junior), fired at week 1 instead of day 21" and specified it that
way in §7. If Day 21 was meant literally, the ladder is 21/28/42 and G1 must say so.

### C-2. Per-broker clock restart vs. the parent clock that deliberately survives a broker change.

User decision: *"Close the old `Broker_Listing__c` and create a fresh one for the new broker, so
days-on-market restarts per broker."*

`classes/DispositionTractionService.cls` lines 149–153:

> *"🔴 THE CLOCK IS THE PARENT'S, NOT THE LISTING'S. `Disposition__c.Listing_Date__c` is the start of
> the MARKETING PERIOD, which survives a broker change; `Broker_Listing__c.List_Date__c` is
> per-broker and restarts when a second listing row opens. **Using the child's date would silently
> reset the 60-day clock the moment a broker was replaced — i.e. exactly when the clock matters
> most.**"*

`classes/BrokerListingController.cls` lines 128–132 repeats it at the point of use.

These are exactly opposite positions on the same question. The user's version is defensible (a new
broker deserves a fair run) — but it is the thing the current code was written to prevent, and
switching means **the escalation clock can be reset indefinitely by replacing brokers**. If the
client wants both, the answer is two clocks: keep `Disposition__c.Listing_Date__c` as the marketing
total (already stamped, fill-if-blank, by `DispositionStageEntryService.stampListingDates`, lines
430–457) and drive **escalation only** off `Broker_Listing__c.List_Date__c`. That is what §7 assumes.

**⚠ Blocking gate G2.** Confirm: escalation clock = per-broker `Broker_Listing__c.List_Date__c`,
marketing total = parent `Disposition__c.Listing_Date__c`, and the two are allowed to disagree on
screen.

### C-3. Close-and-recreate is silently blocked by the existing auto-create idempotency guard.

`classes/DispositionStageEntryService.cls` lines 975–984:

> *"── IDEMPOTENCY: SIMPLE PRESENCE, ANY LISTING ── 'This disposition already has a broker listing'
> is the whole test… ⚠ IT IS DELIBERATELY *NOT* KEYED ON THE BROKER… **Auto-create must never be the
> thing that appends it — a stage re-entry is not a broker change.**"*

Consequence, verified in code at lines 1022–1044: after a broker change, reverting to
`Broker Selection` and re-advancing to `Active Listing` will **not** open the new broker's listing —
`BrokerListingSelector.selectByDispositionIds` finds the old (closed) row and removes the disposition
from the insert set. The old, closed listing stays the only row.

**This is not a bug to fix — it is the designed seam.** The header explicitly reserves the append to
"the future broker-change action". So the new listing **must be inserted by
`BovSubmissionService.replaceSelectedBroker` itself**, not by stage entry. §8 specifies that.

### C-4. `Listing_Status__c` has no closed state, and it is a `restricted` picklist.

`objects/Broker_Listing__c/fields/Listing_Status__c.field-meta.xml` lines 8–28: `<restricted>true</restricted>`,
values `On Track` (default) / `At Risk` / `Hard Stop`. **There is no `Closed`, `Replaced`, `Expired`
or `Withdrawn` value.**

Two separate problems:

1. **`restricted = true` is enforced by DML.** Memory note `restricted-picklist-is-enforced-by-dml`
   records this as measured on this org (`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`) — so Apex cannot
   write a closed value that is not in the value set. A value must be added, or a separate field used.
2. **The field is already carrying the escalation level.**
   `classes/DispositionTractionService.cls` lines 363–390 (`listingStatusValue`) maps the band to
   exactly these three values and its header states *"the three values are the field's entire
   restricted value set… so this feature needs NO new picklist value and the standing 'grep the repo
   and query the org before touching a picklist' rule is not engaged."* Adding a fourth value makes
   that sentence false and must be corrected in place.

Overloading one picklist with **both** an escalation level and a lifecycle state means a closed
listing's level is unreadable, and the escalation job must special-case it. Recommendation in §5:
keep `Listing_Status__c` for the escalation level and add a **separate** `Closed_Date__c` (Date) as
the closed marker, so neither field has two jobs. ⚠ Decision O-3.

---

## 2. Verification of "what already exists"

Every item the brief asked me to verify, with the file that answers it.

| Claim in brief | Verdict | Evidence |
|---|---|---|
| `Broker_Listing__c` has the nine named fields | ✅ Confirmed, and that is the **entire** field list — nine, no more | `objects/Broker_Listing__c/fields/` (9 files) |
| `Days_On_Market__c` is a formula → the clock cannot pause | ❌ **PREMISE IS WRONG.** It is `<type>Number</type>` precision 4 scale 0, **stored** | `objects/Broker_Listing__c/fields/Days_On_Market__c.field-meta.xml:6-11` |
| `Offers_Received__c` is a roll-up | ❌ Wrong. Stored `Number(4,0)`, `<defaultValue>0</defaultValue>`. **Not** a roll-up — `Disposition_Offer__c.Disposition__c` is a Lookup, so no roll-up is available at any price | `objects/Broker_Listing__c/fields/Offers_Received__c.field-meta.xml`; `classes/DispositionTractionService.cls:52-55` |
| …but both are **written by nothing** | 🔴 **Yes, and this is the load-bearing fact.** `BrokerListingSelector` calls `Days_On_Market__c` *"LEGACY: a hand-keyed Number that nothing writes"*; `DispositionStageEntryService` leaves both blank on auto-create *"seeding a 0 would resurrect the very field the clock was moved OFF"* | `classes/BrokerListingSelector.cls:53-57`; `classes/DispositionStageEntryService.cls:1008-1011` |
| `BrokerCheckInReminderSchedulable` is a precedent | ⚠ **Poor fit.** It creates **Tasks**, not alerts, and sets no `OwnerId` — so every reminder Task is owned by the scheduling user. Its "recipient" is `WhoId = a.Broker__c`, i.e. the broker, not an internal team | `classes/BrokerCheckInReminderSchedulable.cls:27-34` |
| `NdaExpiryAlertBatch` has reusable interval/marker logic | ✅ **Yes — this is the pattern to follow.** See §7 | `classes/NdaExpiryAlertBatch.cls`, `classes/NdaExpiryService.cls`, `classes/NdaExpiryAlertSchedule.cls` |
| A Replace Broker path already exists | ✅ Confirmed, incl. savepoint + `BOV_Broker_Change__c` history row | `classes/BovSubmissionService.cls:25-26,246-260,336,383` |
| …reached from `bovComparisonMatrix` | ✅ Confirmed — **and it is unreachable at Active Listing** (see §9) | `lwc/dispositionMain/dispositionMain.html:8-31` |
| Off-market uses `Disposition__c.Broker__c`, not a BOV | ✅ Confirmed, and guarded by a VR | `objects/Disposition__c/validationRules/Broker_Lookup_Is_Off_Market_Only.validationRule-meta.xml` |

**Additional pre-existing components the brief did not mention, which this feature must build on
rather than duplicate:**

- `classes/DispositionTractionService.cls` — the pure band ladder, `evaluate(Date, Integer)`,
  `evaluateAll(Set<Id>)` (2 SOQL, constant), and `listingStatusValue(Band)` — described at lines
  121–129 as *"THE SEAM FOR THE DEFERRED D9 ALERT"*, i.e. **this feature's intended entry point**.
- `classes/DispositionTractionController.cls` + `lwc/listingAlerts` — Card 1's shell, already on the
  page at `lwc/dispositionMain/dispositionMain.html:28`.
- `classes/BrokerListingController.cls` + `lwc/brokerListing` — **Card 2 already renders all four
  requested stats** (`Days On Market`, `List Date`, `Call For Offers Date`, `Offers Received`) plus a
  computed badge (`lwc/brokerListing/brokerListing.js:58-71`). The only genuinely missing pieces are
  the **week-shaped label** and the **Replace Broker button**.
- `lwc/backupBrokers` — already rendered at Active Listing and already wired to
  `BovController.getSubmissions`, i.e. it already holds the backup-broker list the Replace Broker
  modal needs (`lwc/backupBrokers/backupBrokers.js:3,10`).

---

## 3. Hard problem #1 — who are "Junior" and "Ali"?

**There is exactly one first-party outbound-email recipient mechanism in this repo, and it already
solves this problem with the user's own constraint written into its description.**

`force-app/main/default/workflows/Transaction__c.workflow-meta.xml` lines 3–13:

```xml
<alerts>
    <fullName>Transaction_Opened_Notification</fullName>
    <description>Notifies the Transactions_Team group by email … Group recipient so it survives staffing changes.</description>
    <recipients>
        <recipient>Transactions_Team</recipient>
        <type>group</type>
    </recipients>
    <senderType>CurrentUser</senderType>
    <template>unfiled$public/Transaction_Opened_Notification</template>
</alerts>
```

**Public group. Explicitly chosen "so it survives staffing changes."** That is the recommendation.

Mechanisms rejected, with the reason:

| Candidate | Verdict |
|---|---|
| **Public group** ✅ RECOMMENDED | The only proven email-recipient shape here; 11 groups already deploy (`force-app/main/default/groups/`) |
| Queue (`Acquisition`) | Used by both alert batches — but for **CustomNotification**, not email, and it is an *acquisitions* queue. `classes/NdaExpiryAlertBatch.cls:172-190` measures it at **ONE member** |
| Disposition record Owner | Free, no new metadata, no post-deploy gate — but "Junior" is a role, and nothing guarantees the owner is that person |
| User lookup on `Broker_Listing__c` | Explicit and per-record, but must be populated on every row or the alert silently has no recipient |
| Custom Metadata holding a username/Id | Same staffing fragility the user is trying to avoid, plus a post-deploy data gate |
| Hardcoded in Apex/Flow | ❌ Explicitly refused by the user, and correctly |

**What already exists, and what does not:**

- ✅ `groups/Principals.group-meta.xml` exists (`doesIncludeBosses = true`).
- ❌ **No disposition group of any kind exists.** Full list: `Acquisitions_Team`, `Due_Diligence`,
  `LOI_Panel`, `Legal_Team`, `Principals`, `Transactions_Team`, `DPEG_Acquisitions_Team`,
  `DPEG_Property_Mgmt_Team`, `DPEG_Transactions_Team`, `Investor_Relations`,
  `Development_Construction_Team`. This confirms `DispositionTractionService.cls:126-128` —
  *"D9 flags 'Disposition team' as neither a queue nor a public group in this repo — unresolved
  org-wide."* Still unresolved.
- 🔴 **`Group` metadata carries NO membership.** Both group files read are four lines with a `name`
  and `doesIncludeBosses` and nothing else. Membership is org state, not deployable
  (memory: `rbac-build-2026-07-22`). **A new group deploys empty and sends to nobody, silently.**

**Recommendation:** two tiers, two groups.

| Tier | Group | Status |
|---|---|---|
| "Junior" | **new** `Disposition_Team` | Must be created and populated by hand — post-deploy gate PD-1 |
| "Ali" | reuse existing `Principals` | Exists; membership ⚠ UNVERIFIED |

⚠ **On "Ali" specifically.** All five disposition approval processes name two principals —
`nikhil.dhanani@usmandpeg.uat` and `aftab.ali.dpeg.usman@avanzasolutions.com`
(`docs/2026-08-19-disposition-flow-redesign.md:226-228`). It is a reasonable inference that "Ali" is
the second of these. **I have not confirmed it and it must not be assumed.** Note also that those
usernames sit in approval metadata — that is the platform's own approver mechanism, and it is *not*
a licence to put a username in Apex or a Flow.

**⚠ Blocking gate G3.** Confirm the two recipient populations by name, and confirm whether `Principals`
is the right Week-6 audience or whether a `Disposition_Principals` group is wanted.

---

## 4. Hard problem #2 — email

🔴 **State this loudly: this repo has ZERO Apex outbound email.** Grep for
`Messaging.sendEmail|Messaging.SingleEmailMessage|OrgWideEmailAddress|setTemplateId|reserveSingleEmailCapacity`
across the whole tree returns **four hits, all inside `.claude/skills/**` reference documentation**
(`sf-apex/references/solid-principles.md`, `sf-apex/references/design-patterns.md`). **Not one line
in `force-app/`.**

What *does* exist:

| Surface | Count | Files |
|---|---|---|
| First-party `EmailTemplate` | **1** | `email/unfiled$public/Transaction_Opened_Notification.email{,-meta.xml}` — `type=text`, `style=none`, `uiType=Aloha`, subject merges `{!Transaction__c.Name}` |
| Salesforce boilerplate templates | 14 | `email/unfiled$public/Community*`, `Commerce*`, `ExperienceCloud*` — retrieved Site/self-reg stock, not DPEG code (memory: `stock-community-boilerplate`) |
| Workflow `<alerts>` | **1** | `workflows/Transaction__c.workflow-meta.xml` |
| Fired by | a record-triggered Flow | `flows/Transaction_Opened_Notify.flow-meta.xml:8-9` — `actionType = emailAlert`, `RecordAfterSave` / `Create` on `Transaction__c` |
| `OrgWideEmailAddress` metadata | **0** | none anywhere |
| `CustomNotificationType` | 2 | `notificationtypes/{Acquisitions_Deal_Update,Broker_Portal_New_Lead}.notiftype-meta.xml` |

**Two viable mechanisms, and they are not equivalent:**

**Option A — Flow + workflow email alert (RECOMMENDED).** The batch stamps
`Broker_Listing__c.Listing_Status__c` + a marker; an after-save record-triggered Flow on
`Broker_Listing__c` keyed on `ISCHANGED(Listing_Status__c)` fires one of two email alerts. This is a
byte-for-byte reuse of the only proven path in the org.

- ✅ No new Apex surface, no email-limit accounting in Apex, no test-mocking problem.
- ⚠ Add `<runInMode>` explicitly. Memory `flow-runinmode-runs-as-approver` records a measured
  incident on this org: a record-triggered Flow with no `<runInMode>` runs as the **saving user**.
  Here that is the batch's scheduling principal, and an email alert performs no DML — so it is safe —
  but it must be stated, not assumed.
- ⚠ `senderType` — the precedent uses `CurrentUser`, which for a batch means *the scheduling user's*
  address appears as the sender. If that is unacceptable, an `OrgWideEmailAddress` is required, which
  is **Setup-created and verified by email**, not deployable → post-deploy gate.

**Option B — Apex `Messaging.sendEmail` from the batch.** Rejected unless A is refused.

- 🔴 **First Apex email in the application** — new integration surface with deliverability,
  org-wide-address and test-mocking implications, exactly as the brief anticipated.
- The org daily single-email allocation (default 5,000/day for the org, shared) becomes a real
  constraint that `System.Limits` *does* expose (`Limits.getEmailInvocations()`), unlike the
  CustomNotification case that `CallForOffersAlertBatch.cls:29-32` had to measure by probe.
- ⚠ **Emails are not actually sent in Apex tests**, so `send-first-stamp-second` (§7) cannot be
  falsified the way `GroupNotifier.notifyWithOutcome` allows. A `@TestVisible` seam returning the
  built `Messaging.SingleEmailMessage` list would be required — and
  `classes/DispositionTractionController.cls:39-54` records this repo's standing objection to
  test-only branches in production code.

**Option C — CustomNotification instead of email.** Not what the user asked for, but it is what both
existing alert jobs do (`NdaExpiryAlertBatch`, `CallForOffersAlertBatch` → `GroupNotifier`), it is
fully measured for cost, and it requires no new integration surface. **Noting it as a fallback only —
the user asked for email and this design specifies email.**

**⚠ Blocking gate G4.** Option A or B, and if A: `CurrentUser` sender or a new Org-Wide Email Address?

---

## 5. Hard problem #3 — "YELLOW flag on Junior's dashboard"

**It is concrete. The dashboard exists.**

`force-app/main/default/dashboards/Dispositions/Disposition_Dashboard_Junior.dashboard-meta.xml`,
title *"Disposition Dashboard"*, 8 components, 12-column grid. It already carries a red-indicator
metric at `columnIndex 4 / rowIndex 4`:

```xml
<metricLabel>Broker Alert Due</metricLabel>
<report>Dispositions/Broker_Alert_Due</report>
<indicatorHighColor>#C23934</indicatorHighColor>
```

But `reports/Dispositions/Broker_Alert_Due.report-meta.xml` filters on
`Disposition__c.Next_Broker_Checkin__c equals NEXT_N_DAYS:7` — and
`objects/Disposition__c/fields/Next_Broker_Checkin__c.field-meta.xml` is a bare `<type>Date</type>`
with **no writer anywhere in `force-app/`** (grep: permission sets, seed scripts, the report, an
objectTranslation — no Apex, no Flow). So the dashboard's existing "alert" tile is driven by a
hand-keyed date nobody maintains.

**So "YELLOW flag" = extend the existing dashboard, do not invent one:**

- **New report** `Dispositions/Listings_At_Risk` over `Broker_Listing__c`, filtered
  `Listing_Status__c = 'At Risk'` (and `Closed_Date__c` blank — see C-4).
  ⚠ There is **no report on `Broker_Listing__c` in the repo today**; the object carries
  `<enableReports>true</enableReports>` (`Broker_Listing__c.object-meta.xml:151`) so the standard
  report type should exist, but the report-type token is ⚠ UNVERIFIED (memory
  `lead-report-and-status` records that report-type tokens have bitten this repo before).
- **New dashboard metric** on `Disposition_Dashboard_Junior`, `componentType = Metric`, amber
  indicator colours (the file's existing palette is `#1B7A4B` green / `#C23934` red — amber is a new
  colour and the exact hex is an open question, O-5).

🔴 **Two hazards on this file specifically:**

1. `<dashboardType>SpecifiedUser</dashboardType>` with
   `<runningUser>test-aysz9meqvl23@example.com</runningUser>` (lines 222–225) — a **scratch-org
   username**. Memory `testing-bugfix-2026-07-19` records that stale org-specific Ids/usernames in
   dashboards recur on every org rebuild. Editing this file risks a deploy failure in `usman-dpeg`
   for a reason unrelated to the change.
2. The dashboard runs **as that user**, so that user needs read on `Broker_Listing__c`.
   `permissionsets/Disposition_Dashboard_Access.permissionset-meta.xml` grants **zero**
   `Broker_Listing__c` permissions (grep: 0 matches). Without a grant the new tile renders blank or
   errors.

**The escalation level must therefore be STORED, not computed.** A dashboard cannot filter on an
Apex computation. `classes/DispositionTractionService.cls:69-72` already concedes this:

> *"⚠ THE COST, STATED: a computed band is NOT reportable and NOT filterable. `Listing_Status__c` and
> the `Broker_Alert_Due` report cannot see it. That is the real argument for a job, and it is why the
> shape below exists."*

---

## 6. Hard problem #4 — the escalation label, and one source of truth

**Stored *and* computed, from one derivation, with the stored copy written only by the job.**

The repo already has the exact shape for this and names it:
`DispositionTractionService.evaluate(...)` is pure (no SOQL, no DML, no `Date.today()` beyond its
argument), and `listingStatusValue(Band)` exists **solely** as the seam a future job writes through —
*"kept next to the thresholds so the stored value and the displayed badge can never derive from two
different ladders"* (`classes/DispositionTractionService.cls:363-372`).

So:

- **One ladder**, in `DispositionTractionService.evaluate`. Nothing else may contain `7`, `28` or
  `42`. The two existing alert services enforce the same rule on themselves
  (`NdaExpiryService.cls:104-107`: *"if you find yourself writing `5` or `2` … stop"*).
- **The card** renders the live computation via the existing controllers (`getTraction`,
  `getListing`), so it is never stale relative to today's date.
- **The dashboard and the emails** read the stored `Listing_Status__c`, written by the job through
  `listingStatusValue(...)`.
- **They can disagree by at most one job cycle** (up to 24h). That is inherent to any
  stored-plus-computed pair and must be stated on the card, not hidden. It is strictly better than
  the alternative — two ladders — which is what
  `classes/BrokerListingController.cls:14-18` calls *"the W4 'the badge and the gate can never
  disagree' defect."*

---

## 7. The escalation level — exact definition

### 7.1 Inputs

| Input | Source | Note |
|---|---|---|
| `listDate` | `Broker_Listing__c.List_Date__c` | ⚠ per C-2 / gate G2. Today the ladder reads the **parent** `Disposition__c.Listing_Date__c` |
| `firstOfferDate` | earliest `Disposition_Offer__c.Offer_Date__c` for the disposition | new selector method — see §9. `DispositionOfferSelector.selectEarliestByBuyerIds` (Tranche 2) is the shape to copy |
| `offerCount` | `DispositionOfferSelector.countByDispositionIds` | **already exists**, already used by `evaluate`'s callers |
| `asOf` | one `Date.today()` per batch chunk | mandated by `NdaExpiryAlertBatch.cls:50-53` — per-record `Date.today()` lets two rows straddle midnight |
| `closedDate` | `Broker_Listing__c.Closed_Date__c` (new, C-4) | a closed listing is excluded from the locator entirely |

### 7.2 The pause — how it is achieved, and what carries the frozen value

🔴 **The brief's premise is inverted, and the answer changes because of it.**
`Broker_Listing__c.Days_On_Market__c` is **not** a formula — it is a stored `Number(4,0)`
(`objects/Broker_Listing__c/fields/Days_On_Market__c.field-meta.xml:6-11`). The formula the brief
warns about is a *different field on a different object*:
`Disposition__c.Days_On_Market__c` = `IF(ISBLANK(Listing_Date__c), null, TODAY() - Listing_Date__c)`
with `formulaTreatBlanksAs = BlankAsZero` (quoted at
`classes/DispositionTractionService.cls:139-141`).

**Neither is read by anything today.** The number rendered on the card is computed in Apex from the
raw date (`classes/BrokerListingController.cls:132-139`). So:

> **The pause is achieved by changing the ladder's *input*, not by freezing a stored field.**
> `evaluate` computes `days = max(0, listDate.daysBetween(firstOfferDate ?? asOf))`. Once an offer
> exists, `firstOfferDate` is fixed, so `days` stops advancing — permanently and by construction.
> **No stored frozen value is required, and `evaluate` stays pure.**

That is materially better than a stored freeze, because a stored copy must be *maintained* to stay
true, and this one is true on every evaluation.

⚠ **Note what this changes about today's behaviour.** The shipped rule is
*offers > 0 → band `ON_TRACK`, but `daysOnMarket` keeps counting* (`DispositionTractionService.cls:277-286`,
D28/Q1). That **suppresses the level; it does not pause the clock.** The user asked for a pause. The
two differ visibly: today a listing with an offer at day 20 reads "Day 55 of 60 — On Track" at day 55;
under the pause it reads "Day 20 — offer received, clock paused". Both are defensible; they are not
the same thing. ⚠ Decision O-1.

⚠ **A second offer never un-pauses it, and an offer that is deleted does.** `firstOfferDate` is a
`MIN`, so it only ever moves *earlier*. If a `Disposition_Offer__c` is deleted the clock resumes and
back-dates — the escalation level can jump from `On Track` straight to `Week 6 — Hard Stop` in one
job cycle. That is honest but startling. ⚠ Decision O-2: refuse to un-pause (add a latching
`Clock_Paused_Date__c`) or accept the jump. **Recommend accepting the jump** — a latch is the
`NDA_Signed__c` failure mode this repo has already paid for once
(`docs/2026-08-20-disposition-tranche-2.md:118-126`).

### 7.3 The ladder

Pure function, one home, `DispositionTractionService.evaluate`:

```
NOT_LISTED      listDate == null
                    label   —  (no label rendered)
                    status  On Track          (matches today's blank-date branch, line 258)
                    alert   none

ON_TRACK        firstOfferDate != null                       [THE PAUSE — checked FIRST]
                    label   "Day {days} — Offer received, clock paused"
                    status  On Track
                    alert   none

WEEK_6          days >= 42
                    label   "Week 6 — Hard Stop"
                    status  Hard Stop
                    alert   email -> Disposition_Team AND Principals   + hard prompt on the card

WEEK_4          days >= 28
                    label   "Week 4 — At Risk"
                    status  At Risk
                    alert   none by email; the YELLOW dashboard flag is the stored status itself

WEEK_1          days >= 7
                    label   "Week 1 — No offers"
                    status  ⚠ OPEN — see O-4
                    alert   email -> Disposition_Team

ON_TRACK        otherwise
                    label   "Day {days} of 42 — On Track"
                    status  On Track
                    alert   none
```

**Ordering is load-bearing, in two places.**
1. The pause is tested **before** every threshold — same shape as today's `// 🔴 OFFERS FIRST`
   short-circuit at `DispositionTractionService.cls:274-277`.
2. Thresholds descend. Same reason `NdaExpiryService.ALERT_INTERVALS` must stay descending
   (`NdaExpiryService.cls:47-48`).

**The label template.** `"Week {n} — {band}"` is my reconstruction from the one label the user gave
verbatim ("Week 4 — At Risk"). The exact string for `WEEK_1`, for `NOT_LISTED`, and for the paused
state are **not** in the brief and I have not invented them as final — they are O-6.

**⚠ `Listing_Status__c` has three values and the ladder has four levels.** `WEEK_1` has no natural
home: calling it `On Track` while an escalation email goes out is a contradiction the dashboard will
show. ⚠ Decision O-4: (a) map `WEEK_1 → On Track` and accept the contradiction; (b) map
`WEEK_1 → At Risk` and lose the yellow tile's precision (weeks 1–5 all yellow); (c) add a fourth
restricted value. (c) is cleanest and engages C-4's header correction.

### 7.4 Enum migration

The existing `Band` enum is `{NOT_LISTED, ON_TRACK, CHECKPOINT_DUE, REVIEW_OVERDUE, HARD_STOP}` and
its header warns: *"⚠ ORDER IS MEANINGFUL AND IS RELIED ON BY `isAtRisk`… Insert a new value in the
right place or `isAtRisk` silently changes meaning"* (`DispositionTractionService.cls:181-196`).
Renaming to `{NOT_LISTED, ON_TRACK, WEEK_1, WEEK_4, WEEK_6}` preserves ordinal semantics
(`isAtRisk` = everything from index 2 up) **only if `WEEK_1` is intended to be at-risk**, which
depends on O-4. Do not rename before O-4 is answered.

Blast radius of the enum/threshold change:
`classes/DispositionTractionService.cls`, `classes/DispositionTractionServiceTest.cls`,
`classes/DispositionTractionControllerTest.cls`, `classes/BrokerListingControllerTest.cls`,
`lwc/listingAlerts/listingAlerts.js` (`BAND_THEME` map, lines 79–85),
`lwc/listingAlerts/__tests__/listingAlerts.test.js`,
`lwc/brokerListing/__tests__/brokerListing.test.js`.

---

## 8. The stage-revert sequence

### 8.1 Is `Active Listing → Broker Selection` permitted today?

**Yes — verified against every gate the brief named.**

| Gate | Verdict | Evidence |
|---|---|---|
| Validation rules | ✅ **Not blocked.** `Disposition__c` has exactly three VRs. `All_NDAs_Signed_Before_Progression` names `Release Materials, Active Listing, Offer Selection, LOI, PSA, Closing, Sale Closes` — **`Broker Selection` is not in the list.** `Wire_Complete_Before_Sale_Closes` names only `Sale Closes`. `Broker_Lookup_Is_Off_Market_Only` is about `Broker__c` | `objects/Disposition__c/validationRules/` (3 files); `All_NDAs_Signed_Before_Progression…xml:134-149` |
| A backward-movement rule | ✅ **None exists on this object.** Stated explicitly: *"the No_Backward_Stage_Movement rule is **Opportunity-only** and nothing stops a user jumping NDA → LOI directly"* | `All_NDAs_Signed_Before_Progression…xml:17-19` |
| Path Assistant | ✅ Does not constrain. A Path renders order; it does not forbid a backward set | `pathAssistants/Disposition_Path_On_Market.pathAssistant-meta.xml` |
| `RecordStageAdvanceService` | 🔴 **Cannot express it.** On-market map is four **forward** hops only (`Broker Selection→NDA`, `NDA→Release Materials`, `Release Materials→Active Listing`, `LOI→PSA`), and `advanceTo()` is *"STRUCTURALLY UNREACHABLE on Disposition__c"* | `classes/RecordStageAdvanceService.cls:80-84,325,1111-1113` |

⇒ **A new writer is required.** It belongs in `BovSubmissionService.replaceSelectedBroker`, inside
the existing savepoint — not a new service, and not `RecordStageAdvanceService` (adding a backward
hop to that map would expose it as a button on every disposition, which is not what was asked).

### 8.2 Does re-entry create duplicate NDAs?

**No. I verified this against the code rather than repeating the "idempotent" claim.**

`DispositionStageEntryService.createStageEntryRecords` keys on **ENTRY**
(`priorStage != d.Disposition_Stage__c`, lines 304–327), so a revert *and* every subsequent forward
hop **do** re-fire the blocks. What stops duplication is each block's own guard:

| Block | Guard | Line | Duplicate on re-entry? |
|---|---|---|---|
| `Broker Selection` | — not a target stage at all | 312–326 | n/a — the revert itself creates nothing |
| `NDA` | removes any disposition that already has a `Party_Role__c = 'Buyer'` NDA | 488–492 | ❌ No |
| `Release Materials` | fill-if-blank on `Materials_Released_Date__c` | 892–895 | ❌ No |
| `Active Listing` | removes any disposition that already has **any** `Broker_Listing__c` | 1028–1030 | ❌ No — 🔴 **and this is what blocks C-3** |
| `stampListingDates` | fill-if-blank on `Listing_Date__c` | 453–455 | ❌ No — 🔴 **so the parent clock does not restart** |
| `LOI` / `PSA` | simple presence | 654, 760 | ❌ No |

⇒ **`NDA_Signed_Rollup`'s `NDA_Count__c` / `Signed_NDA_Count__c` are untouched, and the release gate
`All_NDAs_Signed_Before_Progression` is unaffected.** The brief's concern does not materialise.

⚠ **One residual, and it is real.** `NdaSelector.selectByDispositionIds` is `WITH SYSTEM_MODE` but
deliberately **`with sharing`** — its class header says so and says the two must not be harmonised
(`classes/NdaSelector.cls:43-48`). `SYSTEM_MODE` lifts CRUD/FLS and **never** sharing. `NDA__c` is
Private OWD. So a principal who cannot *see* the existing buyer NDA would mint a second one. The
disposition sharing rules are criteria-scoped to the `Disposition NDA` record type
(`classes/NdaExpiryAlertBatch.cls:60-63`), so this is unlikely — but it is the exact
guard-inverts-into-a-duplicate-maker shape ARCHITECTURE.md §2 warns about. Risk R-6.

### 8.3 The sequence

All of this runs **inside the existing savepoint** in `BovSubmissionService.replaceSelectedBroker`
(`classes/BovSubmissionService.cls:336`), and the ordering rule already stated there applies:
*"a history row recording a replacement that then failed is worse than no history at all"*
(`docs/2026-08-20-disposition-tranche-2.md:162-172`).

```
0. PRE-CHECK (new, before the savepoint)
   Refuse if Disposition__c.Approval_Pending__c == true, with an authored message.
   Precedent: DispositionApprovalService.submitForApproval's wire pre-check
   (docs/2026-08-19-disposition-flow-redesign.md:145-157) — raise a human message
   before the platform raises an opaque one.
   ⚠ Also refuse if Disposition_Stage__c != 'Active Listing'  (user decision:
   "Only from Active Listing. Not from earlier stages, and never from LOI or later.")

   Savepoint set  ─────────────────────────────────────────────────────────────

1. DML 1  demote every currently-Selected BOV_Submission__c to Backup, clear Approval_Status__c
2. DML 2  promote the challenger to Selected, clear its Approval_Status__c
3. DML 3  stamp Disposition__c.Selected_Broker__c        (ordinary update — deliberately NOT
                                                          SYSTEM_MODE, so a locked disposition
                                                          refuses the WHOLE replacement)
                                                          — all three UNCHANGED
4. DML 4  insert BOV_Broker_Change__c history row        — UNCHANGED, still last of the old set

   ── NEW BELOW THIS LINE ──────────────────────────────────────────────────────

5. DML 5  CLOSE the current Broker_Listing__c
             Closed_Date__c = TODAY
             (Listing_Status__c left as-is — it is the escalation level, not a lifecycle state)
             SYSTEM_MODE: Closed_Date__c is a new field and arrives with NO FLS for anyone,
             System Administrator included.

6. DML 6  INSERT the new Broker_Listing__c for the incoming broker
             Disposition__c    = the disposition
             List_Date__c      = TODAY          <-- the per-broker clock restart (C-2)
             Broker_Firm__c    = challenger.Broker_Firm__c
             Contact_Name__c   = challenger.Contact_Name__c
             Listing_Status__c = 'On Track'
             ⚠ This is the append DispositionStageEntryService's header reserves for
               "the future broker-change action" (line 983). Auto-create will NOT do it (C-3).

7. DML 7  REVERT Disposition__c.Disposition_Stage__c = 'Broker Selection'
             ⚠ MUST be folded into DML 3 rather than issued separately — see below.

   Savepoint rollback on ANY DmlException — all writes undone, platform text surfaced.
```

🔴 **Fold step 7 into step 3, do not add a seventh statement.** Two reasons, both already recorded
in this repo:
- `Selected_Broker__c` and `Disposition_Stage__c` are on the same record in the same transaction; two
  updates to one record is a second DML against a record that a child approval may have just locked.
- `classes/BovSubmissionService.cls:59-61` already flags a partial state — *"`Selected_Broker__c`
  still names the old firm"* — as the failure mode this method's savepoint exists to prevent. Adding
  a second parent write widens that window rather than narrowing it.

⚠ **The class header's cost line must be updated.** It was corrected once already, from
*"1 SOQL + 2 DML"* to *"1 SOQL + 3 DML"* (`docs/2026-08-20-disposition-tranche-2.md:164-168`). This
change makes it **2 SOQL + 5 DML** (one extra read for the current listing, plus the close and the
insert). Leaving a stale count is the defect that header was corrected for.

### 8.4 Interaction with `Approval_Pending__c` (brief item 7)

**Analysed against the field's own 2026-08-21 header
(`objects/Disposition__c/fields/Approval_Pending__c.field-meta.xml`) and
`agent-output/hide-submit-while-pending.md`.**

| Scenario | Outcome | Evidence |
|---|---|---|
| A Disposition-target approval pending while at `Active Listing` | 🔴 **Structurally impossible.** All three enter at `Disposition Readiness`, `Broker Selection` + Off Market, and `Closing` + wire-verified. None enters at `Active Listing` | `classes/DispositionStageEntryService.cls:39-44,948-951` |
| `Broker_Finalize_Approval` pending on the incumbent BOV submission | ✅ **Fails closed already.** The submission is `recordEditability = AdminOnly`, so DML 1's demote throws `ENTITY_IS_LOCKED`, the savepoint rolls the whole replacement back. Stated directly: *"a submission with a pending approval cannot be replaced at all — it is locked"* | `agent-output/hide-submit-while-pending.md:396`; `triggers/BovSubmissionTrigger.trigger:35-41` |
| Is the mirrored `Disposition__c.Approval_Pending__c` stranded by the revert? | ✅ **No.** It is written only by approval actions on all four terminal transitions (`initialSubmissionActions` / `finalApprovalActions` / `finalRejectionActions` / `recallActions`) plus the BOV mirror in `BovSubmissionTriggerHandler`. The stage revert writes only `Disposition_Stage__c` and touches no approval | `workflows/Disposition__c.workflow-meta.xml:57-63`; `objects/Disposition__c/fields/Approval_Pending__c.field-meta.xml:16-22` |
| Does landing back at `Broker Selection` with the flag true strand a Submit button? | ✅ **No, on-market.** The `Submit_Broker_Selection` Dynamic Action is gated `Disposition_Stage__c = 'Broker Selection' AND Is_On_Market__c = false` — it is off-market-only and never renders here | `docs/2026-08-19-disposition-flow-redesign.md:236` |

🔴 **The mitigation is therefore step 0's pre-check, not a new mechanism.** Refusing the replacement
while `Approval_Pending__c = true` makes the whole class of interaction unreachable and produces an
authored message instead of `ENTITY_IS_LOCKED`. It costs nothing: the platform already refuses these
cases, just opaquely.

⚠ **One residual I could not close.** `replaceSelectedBroker` clears the demoted submission's
`Approval_Status__c` but **not** `BOV_Submission__c.Approval_Pending__c`
(`agent-output/hide-submit-while-pending.md:396` calls the mirror *"a no-op on that path"*). That is
correct only while the demote can never run against a pending approval. Step 0's pre-check makes it
correct **by construction** rather than by the lock. Risk R-5.

---

## 9. Inventories

### 9.1 Metadata

| Type | Item | New/Modified | Notes |
|---|---|---|---|
| CustomField | `Broker_Listing__c.Closed_Date__c` (Date) | **New** | The close marker. ⚠ Naming: ARCHITECTURE.md §1 mandates `Date` suffix for date-only. Alternative `Is_Closed__c` rejected — a date answers "when", a boolean does not |
| CustomField | `Broker_Listing__c.Alert_Last_Level__c` (Number 2,0) | **New** | Idempotency marker — the smallest rung already alerted. Copies `NDA__c.NDA_Alert_Last_Interval__c` exactly. ⚠ arrives as `Decimal`; cast with `.intValue()` (`NdaExpiryAlertBatch.cls:54-56`) |
| CustomField | `Broker_Listing__c.Alert_List_Date__c` (Date) | **New** | The **snapshot** of `List_Date__c` the marker was computed against. 🔴 Not optional — without it, editing the list date leaves the ladder armed against a date that no longer exists and the row is **never alerted again**. Full reasoning: `NdaExpiryService.cls:78-85` |
| Picklist value | `Listing_Status__c` fourth value | **Conditional** | Only if O-4 resolves to (c). Adding to a `restricted` set; and it falsifies `DispositionTractionService.cls:369-372` |
| Group | `Disposition_Team` | **New** | 🔴 Deploys **empty** — membership is not metadata. Post-deploy gate PD-1 |
| Group | `Principals` | Reuse | Exists (`groups/Principals.group-meta.xml`); membership ⚠ UNVERIFIED |
| EmailTemplate | `unfiled$public/Listing_Week_1_No_Offers` | **New** | Shape copied from `Transaction_Opened_Notification.email-meta.xml`: `type=text`, `style=none`, `uiType=Aloha`, `encodingKey=UTF-8` |
| EmailTemplate | `unfiled$public/Listing_Week_6_Hard_Stop` | **New** | Same shape |
| Workflow `<alerts>` | `Broker_Listing__c.Listing_Week_1_Alert` | **New file** — `workflows/Broker_Listing__c.workflow-meta.xml` does not exist | Recipient `<type>group</type>` |
| Workflow `<alerts>` | `Broker_Listing__c.Listing_Week_6_Alert` | Same file | **Two** `<recipients>` blocks — `Disposition_Team` and `Principals` |
| Flow | `Listing_Escalation_Notify` | **New** | `RecordAfterSave` on `Broker_Listing__c`, entry `ISCHANGED(Listing_Status__c)`, two decision branches → `actionType = emailAlert`. ⚠ Set `<runInMode>` explicitly |
| Report | `Dispositions/Listings_At_Risk` | **New** | First report on `Broker_Listing__c`. ⚠ report-type token UNVERIFIED |
| Dashboard | `Dispositions/Disposition_Dashboard_Junior` | **Modified** | +1 amber Metric component. ⚠ scratch-org `runningUser` hazard (§5) |
| PermissionSet | `DPEG_Disposition_Edit`, `DPEG_Disposition_View` | **Modified** | Grants for the three new fields. 🔴 A `PermissionSet` deploy **replaces the whole `fieldPermissions` set** — diff against `HEAD` first (memory: `content-publication-and-permset-replace`) |
| PermissionSet | `Disposition_Dashboard_Access` | **Modified** | Currently grants **nothing** on `Broker_Listing__c` (grep: 0). Needed for the dashboard tile |
| Layout | `Broker_Listing__c-Broker Listing Layout` | **Modified** | Surface `Closed_Date__c`. The two marker fields stay off the layout — same treatment as `NDA_Alert_*` |

⚠ **`Alert_Last_Level__c` naming.** ARCHITECTURE.md §1 says a Number whose name reads categorical
should carry `_Score__c` / `_Count__c` / `_Pct__c`. `_Level__c` is none of these. The precedent
`NDA_Alert_Last_Interval__c` uses `_Interval__c`, which is equally outside the list. Following the
precedent over the rule; flag for the admin agent. ⚠ O-7.

### 9.2 Apex, by layer

| Layer | Class | New/Mod | Responsibility |
|---|---|---|---|
| **Service (pure)** | `DispositionTractionService` | **Modified** | 🔴 The single ladder. `evaluate(Date listDate, Integer offerCount, Date firstOfferDate, Date asOf)` — signature widens by two; keep an overload so existing callers compile. Add `shouldFire(dueLevel, lastLevel, liveListDate, snapshotListDate)` — the marker rule, **pure**, copied from `NdaExpiryService.shouldFire`. Rewrite §1 as a retraction (C-1). Still **zero SOQL, zero DML** |
| **Selector** | `BrokerListingSelector` | **Modified** | `+queryEscalationCandidates()` returning a `Database.QueryLocator` — open listings (`Closed_Date__c = null`), `List_Date__c != null`, on-market. 🔴 `WITH SYSTEM_MODE` **and** a `private without sharing` inner class for the read: `Broker_Listing__c` is `sharingModel Private` (`Broker_Listing__c.object-meta.xml:164`) and a locator scoped to the scheduling user's own rows produces an all-zeros summary indistinguishable from a healthy job — the exact failure `NdaExpiryAlertBatch.cls:59-75` §4 names. `+widen selectMostRecentByDispositionId` to carry the three new fields |
| **Selector** | `DispositionOfferSelector` | **Modified** | `+selectEarliestByDispositionIds(Set<Id>)` — one aggregate for the whole chunk, `MIN(Offer_Date__c)`. Shape copied from the existing `selectEarliestByBuyerIds` |
| **Batch** | `ListingEscalationBatch` | **New** | `Database.Batchable<SObject>, Database.Stateful`. `SCOPE = 200`, **inherited** from `CallForOffersAlertBatch` with the inheritance stated, not re-measured (`NdaExpiryAlertBatch.cls:6-27`). 🔴 **Stamp-only** — it writes `Listing_Status__c` + the two markers; the Flow sends. So the *send-first-stamp-second* ordering (`NdaExpiryAlertBatch.cls:29-41`) **inverts** here: the send is downstream of the stamp, in the same transaction, and a rollback un-sends nothing. ⚠ That divergence must be argued in the class header, not inherited |
| **Schedulable** | `ListingEscalationSchedule` | **New** | Five-line shell. Shape: `NdaExpiryAlertSchedule.cls`. 🔴 Post-deploy scheduling gate PD-2 |
| **Controller** | `DispositionTractionController` | **Modified** | No signature change; the widened `Traction` DTO flows through |
| **Controller** | `BrokerListingController` | **Modified** | `ListingRow` gains `isClosed`, `canReplaceBroker`. ⚠ Its header §"THE 6-WEEK CLOCK THAT USED TO LIVE HERE IS GONE" (lines 5–24) becomes **false** and must be re-retracted |
| **Service** | `BovSubmissionService` | **Modified** | `replaceSelectedBroker` gains the pre-check + DML 5/6 + the folded stage revert (§8.3). Header cost line → **2 SOQL + 5 DML** |
| **Controller** | `BovController` | **Modified** | Passthrough only, if a new parameter is needed |
| **Test support** | `TestDataFactory` | **Modified** | `createBrokerListings` must set the new fields; ⚠ **check whether it already seeds `List_Date__c`** — `createDispositions` seeds `Listing_Date__c = Date.today()` on every fixture, which makes the obvious stamp test vacuous (`DispositionStageEntryService.cls:421-424`). The same trap applies here |

**Not created, deliberately:** no new Domain class (this is orchestration, matching
`.claude/agent-memory/salesforce-admin` precedent that this repo has **no** Domain classes for
trigger logic), no `@InvocableMethod` (nothing invokes from Flow into Apex here — the Flow only
fires an email alert), and **no third alert-job pattern** (per the brief: `NdaExpiryAlertBatch` is
the pattern followed).

**Bulk-test-rule applicability** (`.claude/rules/bulk-test-rule.md`):

| Class | 251 mandate | Why |
|---|---|---|
| `ListingEscalationBatch` | ✅ **Applies in full, no exemption** | It is a batch. `NdaExpiryAlertBatch.cls:146-150` records what 251 actually proves at `SCOPE = 200`: the locator selects/filters/orders 251 rows and a full 200-row chunk behaves — it does **not** drive two `execute()` calls, and no test can |
| `DispositionTractionService.evaluate` / `shouldFire` | ❌ Exempt (volume) | Pure functions, no DML, no collection. Assert **every rung and every boundary** instead — `NdaExpiryServiceTest.everyRungOfTheLadderMapsToExactlyOneBand` is the shape |
| `BovSubmissionService.replaceSelectedBroker` | ❌ Exempt | Per-transaction-singleton `@AuraEnabled`; the existing exemption stays valid and **must be restated in the test class header** so review does not re-demand 251 (`docs/2026-08-20-disposition-tranche-2.md:557`) |
| `BrokerListingSelector.queryEscalationCandidates` | ❌ Exempt (volume) | A read has no batch chunking |

`.claude/rules/content-publication-rule.md` — **not engaged**; nothing here touches
`ContentVersion` / `ContentNote` / `ContentDocument`.

### 9.3 LWC

| Component | New/Mod | Change |
|---|---|---|
| `listingAlerts` | **Modified** | 🔴 Becomes Card 1 for real. Its `milestones` getter (lines 159–213) currently renders Days-on-market / checkpoint / hard-stop / offers; it must render the **three-checkpoint schedule** the user asked for, plus a pause row. `BAND_THEME` (79–85) re-keyed to the new bands. 🔴 **The header's entire "WHAT THIS REPLACED" block (lines 4–30) must be rewritten as a retraction** — it currently argues *against* the exact rows being restored, and leaving it would be the repo's worst class of defect: a file whose comment contradicts its own code. Name kept (it was kept deliberately, line 26–30, precisely for this) |
| `brokerListing` | **Modified** | Add the **Replace Broker** button beside the traction badge. Add `isClosed` handling. `hasTractionLabel` getter (line 79) survives — the payload field name does not change |
| `bovReplaceBrokerModal` | **Reuse, unchanged** | `@api dispositionId`, `backupOptions`, `currentBroker`, `isFirstAppointment` (lines 109–137). Open it from `brokerListing` with `isFirstAppointment` **omitted** — the getter reads `=== true`, so an absent prop defaults to "replacement", the safer branch (line 194–196) |
| `backupBrokers` | ⚠ **Consider hosting the button here instead** | It is already at Active Listing and already wires `BovController.getSubmissions` (lines 3, 10), i.e. it already has `backupOptions`. Putting the button on `brokerListing` means a **second** `getSubmissions` wire on the same page. ⚠ O-8 |
| `dispositionMain` | **Not modified** | `isActiveListing` already mounts all three cards (`dispositionMain.html:11-31`) |
| `bovComparisonMatrix` | **Not modified** | 🔴 **Do not add a third Replace Broker entry point here.** It already has one |

🔴 **Why the listing Replace Broker button is NOT a duplicate.** `dispositionMain.html` renders
`<c-bov-comparison-matrix>` under `if:true={isBovOutreach}` (line 8) and the listing cluster under
`if:true={isActiveListing}` (line 11) — **mutually exclusive**. So the existing Replace Broker button
is *unreachable* at Active Listing, which is the only stage this feature operates in. This is a
genuine gap. **The button converges on `BovController.replaceSelectedBroker` → `BovSubmissionService.replaceSelectedBroker`
and adds no second implementation of the four invariants.**

⚠ **Accessibility.** The "Week 4 — At Risk" label and the yellow flag must render as **text**, not
only as a coloured badge. `docs/2026-08-20-disposition-tranche-2.md:159-161` names a prior incident
in this repo where a text-to-badge swap deleted accessible content a test had already pinned.
`@sa11y/jest` assertions are required per ARCHITECTURE.md §5.

⚠ **`.js-meta.xml` `<description>` is capped at 255 characters and ONLY a deploy catches it** —
Jest, the SLDS linter and code review all passed a 258-char one (memory:
`xml-comment-must-be-inside-root`).

---

## 10. Alert-firing mechanism and schedule

**Pattern followed: `NdaExpiryAlertBatch` / `NdaExpiryService` / `NdaExpiryAlertSchedule`.
No third pattern is invented.**

```
ListingEscalationSchedule  (Schedulable, daily — cron TBD, O-9)
        │  post-deploy scheduling gate PD-2: nothing schedules itself
        ▼
Database.executeBatch(new ListingEscalationBatch(), 200)
        │
        ├─ start()   BrokerListingSelector.queryEscalationCandidates()
        │              WHERE Closed_Date__c = null AND List_Date__c != null
        │              🔴 SYSTEM_MODE + `private without sharing` inner class
        │
        └─ execute(chunk)
             ONE Date asOf = Date.today() for the WHOLE chunk    <-- NdaExpiryAlertBatch §3
             ONE query: DispositionOfferSelector.selectEarliestByDispositionIds(parentIds)
             per row:
               t = DispositionTractionService.evaluate(listDate, offerCount, firstOfferDate, asOf)
               lastLevel = Alert_Last_Level__c?.intValue()
               if (!shouldFire(t.level, lastLevel, listDate, Alert_List_Date__c)) continue
               stage:
                 Listing_Status__c    = DispositionTractionService.listingStatusValue(t.band)
                 Alert_Last_Level__c  = t.level
                 Alert_List_Date__c   = listDate          <-- the SNAPSHOT, re-arms on a date edit
             ONE DML: Database.update(toStamp, false, AccessLevel.SYSTEM_MODE)
                      via a `private without sharing` inner class
        │
        ▼  (same transaction, after-save)
Flow: Listing_Escalation_Notify   entry ISCHANGED(Listing_Status__c)
        ├─ 'Hard Stop'  -> emailAlert Listing_Week_6_Alert  (Disposition_Team + Principals)
        └─ WEEK_1 value -> emailAlert Listing_Week_1_Alert  (Disposition_Team)
```

**Governor shape per `execute()`:** 1 SOQL (the offer aggregate) + at most 1 DML — **constant in
chunk size**, matching `NdaExpiryAlertBatch.cls:119-127`. A chunk where nothing is owed costs zero
DML and zero email.

**Why an idempotency marker at all.** Without it the same email goes out every day and *"the team
stops reading them"* (`NdaExpiryService.cls:87-89`). `Alert_Last_Level__c` is **monotone**, so a
missed day catches up (day 6 → day 30 fires Week 4, not Week 1 then Week 4) and a double run is a
no-op.

🔴 **Two divergences from the `NdaExpiryAlertBatch` precedent that must be argued in the new class's
own header, not inherited:**

1. **Send-first-stamp-second inverts.** The precedent sends via `GroupNotifier.notifyWithOutcome` and
   stamps only what actually went out. Here the *stamp is the trigger* for the send. A stamp that
   commits while the Flow's email alert fails leaves a marker claiming an alert that never went —
   the **silent** direction the precedent explicitly refuses. ⚠ Mitigation: an email alert that fails
   does not roll back the DML, but the platform logs it. Accept and record, or move to Option B
   (Apex email) where the outcome is inspectable. ⚠ This is the strongest argument for Option B.
   Risk R-2.
2. **`without sharing` is needed twice, for two different statements** — the locator and the stamp —
   and the class-level keyword does **not** cover either (`NdaExpiryAlertBatch.cls:76-117` argues
   this at length; do not collapse it to one keyword).

⚠ `Database.AllowsCallouts` is **not** needed. An email alert fired from a Flow is not an HTTP
callout.

⚠ **The daily-email allocation is a real, shared, org-wide resource** and, like `ContentPublication`,
it is not per-transaction. Unlike `ContentPublication` it *is* observable
(`Limits.getLimitEmailInvocations()`), but only under Option B. Under Option A the Flow's sends are
invisible to Apex entirely. Risk R-3.

---

## 11. Risk register

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| **R-1** | **The 60-day ladder and a 42-day ladder both live**, one in `DispositionTractionService` and one wherever the new job puts its numbers | 🔴 Critical | One ladder, in `evaluate`. No `7`/`28`/`42` anywhere else. `DispositionTractionServiceTest` must fail if the two decouple — the coupling test `NdaExpiryServiceTest.everyRungOfTheLadderMapsToExactlyOneBand` is the model (`NdaExpiryService.cls:57-62`) |
| **R-2** | Stamp commits, email alert fails ⇒ marker claims an alert that never went. **Silent and permanent** | 🔴 Critical | See §10 divergence 1. Either accept + document, or take Option B and inspect the send outcome |
| **R-3** | Daily org email allocation exhausted by a large pipeline | 🟡 Medium | Bounded by open listings × 2 rungs for the life of the listing, not by row count. Not measurable under Option A |
| **R-4** | `Disposition_Team` group deploys **empty** ⇒ every alert has no recipient, **and nothing errors** | 🔴 Critical | PD-1. `GroupNotifier.cls:130-132` shows the equivalent case degrading to a `System.debug` warning — invisible |
| **R-5** | `BOV_Submission__c.Approval_Pending__c` not cleared on the demote path | 🟡 Medium | §8.4 step-0 pre-check makes the path unreachable |
| **R-6** | `NdaSelector.selectByDispositionIds` is `with sharing`; a principal who cannot see the buyer NDA mints a duplicate on re-entry, corrupting `NDA_Signed_Rollup` | 🟡 Medium | Pre-existing, not introduced here. Named because the stage revert increases how often re-entry happens. Do **not** "fix" by harmonising the keyword — the header forbids it (`NdaSelector.cls:43-48`) |
| **R-7** | `Listing_Status__c` is `editable = true` on `DPEG_Disposition_Edit` (`permissionsets/DPEG_Disposition_Edit…xml:1357-1361`) ⇒ a user hand-edits the level, the job overwrites it next cycle, the dashboard flickers | 🟡 Medium | Either make it read-only (a behaviour change for existing users) or accept overwrite-wins and say so in `inlineHelpText`. ⚠ O-10 |
| **R-8** | Dashboard `runningUser` is a scratch-org username; editing the file breaks the deploy | 🟡 Medium | Deploy the dashboard **alone, last**, and read it back (memory: `testing-bugfix-2026-07-19`) |
| **R-9** | Dashboard tile renders blank — `Disposition_Dashboard_Access` grants nothing on `Broker_Listing__c` | 🟡 Medium | Add the grant. 🔴 Diff the permission set against `HEAD` — a deploy replaces the whole `fieldPermissions` set |
| **R-10** | Deleting a `Disposition_Offer__c` un-pauses the clock and jumps the level several rungs in one cycle | 🟢 Low | Accept (O-2). A latch reproduces the `NDA_Signed__c` failure mode |
| **R-11** | Card 2's `getListing` is `cacheable=true` with **no invalidation**; a just-replaced broker may not appear until reload — and the card has **two** stale values, not one | 🟡 Medium | Pre-existing and documented at `classes/BrokerListingController.cls:35-44`. The replace modal must call `refreshApex`, not `getRecordNotifyChange` — the band is an Apex computation, not a record field |
| **R-12** | Dry-run reports `"state": "Unchanged"` and **skips validation** for byte-identical components; a comment-only edit does not count as a change | 🟡 Medium | Check **per-component** `state`, not the top-level status (`docs/2026-08-20-disposition-tranche-2.md:505-510` — this bit a FlexiPage binding in the last tranche) |
| **R-13** | New fields arrive with **no FLS for anyone, System Administrator included** ⇒ a `USER_MODE` read red-banners the card on day one | 🟡 Medium | Permission sets land **with or before** the Apex (`docs/2026-08-20-disposition-tranche-2.md:489-494`) |
| **R-14** | A concurrent session is editing this same working tree | 🟡 Medium | Measured 2026-08-16 (memory: `commit-retrieves-before-editing`). `Disposition_Record_Page`, `DPEG_Disposition_Edit` and `DPEG_Disposition_View` are shared hub files — **diff against `HEAD` before deploying** |

---

## 12. Open questions and blocking gates

### 🔴 Blocking gates — implementation must not start until these are answered

| # | Gate |
|---|---|
| **G1** | **Thresholds.** Week 1/4/6 (7/28/42) vs. the shipped 30/40/60 derived from `DPEG-Stage-by-Stage.docx` Part 2 line 213. Which source is authoritative? And is "Week 1" day **7** or the mockup's day **21**? (§1 C-1) |
| **G2** | **Which clock.** Per-broker `Broker_Listing__c.List_Date__c` for escalation, parent `Disposition__c.Listing_Date__c` for the marketing total, allowed to disagree on screen? (§1 C-2) |
| **G3** | **Recipients.** Confirm the two populations. Is "Ali" `aftab.ali.dpeg.usman@avanzasolutions.com`? Is the existing `Principals` group the right Week-6 audience, or is a `Disposition_Principals` group wanted? (§3) |
| **G4** | **Email mechanism.** Option A (Flow + workflow email alert — reuses the org's only proven path) or Option B (first-ever Apex `Messaging.sendEmail`)? If A: `senderType = CurrentUser`, or a new Org-Wide Email Address requiring Setup creation and email verification? (§4) |
| **G5** | **"Hard prompt" is undefined.** A prominent banner on `listingAlerts` plus the Replace Broker button promoted to primary? Or something blocking? **I have not invented one.** Note that a *blocking* prompt would be a validation-rule/gate change and is not what was asked |
| **G6** | **Off-market scope — I have an answer, please confirm it.** `Active Listing` is not on the `Off_Market` record-type value set (`classes/DispositionStageEntryService.cls:160-166`), so **no `Broker_Listing__c` is ever auto-created for an off-market disposition** and this feature does not apply to them. ⚠ But nothing *prevents* a hand-created listing on an off-market row, and the batch locator would pick it up. Should the locator filter on record type, or scope on the listing rows alone? |

### ⚠ Design decisions needing an answer, but not blocking discovery

| # | Question | Recommendation |
|---|---|---|
| **O-1** | Does "pause" mean *suppress the level* (today's behaviour) or *stop the day counter*? | Stop the counter — the user said "pauses" |
| **O-2** | Un-pause if the offer is deleted? | Yes, accept the jump. A latch is the `NDA_Signed__c` failure mode |
| **O-3** | Closed state: fourth `Listing_Status__c` value, or a separate `Closed_Date__c`? | Separate `Closed_Date__c` — one field, one job |
| **O-4** | What `Listing_Status__c` does WEEK_1 map to? | Needs a decision; (c) add a fourth value is cleanest but engages C-4 |
| **O-5** | Amber hex for the dashboard indicator (existing palette is `#1B7A4B` / `#C23934`) | — |
| **O-6** | Exact label strings for WEEK_1, NOT_LISTED and the paused state | Only "Week 4 — At Risk" was given verbatim |
| **O-7** | `Alert_Last_Level__c` naming vs. ARCHITECTURE.md §1's `_Score__c`/`_Count__c` guidance | Follow the `NDA_Alert_Last_Interval__c` precedent |
| **O-8** | Replace Broker button on `brokerListing` (needs a second `getSubmissions` wire) or on `backupBrokers` (already has one)? | `backupBrokers` — but the user asked for it "beside" the status label, which is on `brokerListing` |
| **O-9** | Cron for the daily job | Match `NdaExpiryAlertSchedule` / `CallForOffersAlertSchedule` |
| **O-10** | Make `Listing_Status__c` read-only, or accept job-overwrites-user? | — |

### Post-deploy gates (no test and no deploy can see these)

| # | Gate |
|---|---|
| **PD-1** | 🔴 Populate `Disposition_Team`. **`Group` metadata carries no membership** — the file is four lines. An empty group sends to nobody and logs a `System.debug` warning at most |
| **PD-2** | 🔴 Schedule `ListingEscalationSchedule`. Nothing schedules itself; a deploy that misses this leaves the card showing a band nothing maintains — *"silently, which is exactly the Item B failure profile"* (`DispositionTractionService.cls:59-65`) |
| **PD-3** | Verify `Principals` membership |
| **PD-4** | If Option A + Org-Wide Email Address: create and **verify** it in Setup (an OWEA is not usable until the verification email is clicked) |
| **PD-5** | Read the dashboard back. Confirm the amber tile renders **as the running user**, not as an admin |
| **PD-6** | Send one real Week-1 and one real Week-6 email end to end. An email alert that deploys green and never fires is the same silent-failure shape as the `recallActions` trap (memory: `approval-pending-ui-flag-pattern`) |

---

## 13. Things I could not verify

Stated rather than assumed, per the brief.

- **No org access, no `salesforce-api-context` MCP.** Nothing here is measured against `usman-dpeg`.
- **`docs/DPEG-Stage-by-Stage.docx` Part 2 line 213** — quoted from
  `DispositionTractionService.cls:9-11`, not read directly (no Python/LibreOffice on this machine;
  memory: `docx-editing-without-python`). G1 turns on this quotation being accurate.
- **`Principals` group membership** — not deployable, not readable from the repo.
- **Whether "Ali" is `aftab.ali.dpeg.usman@avanzasolutions.com`** — an inference from approval
  metadata, nothing more.
- **The report-type token for `Broker_Listing__c`** — no report on that object exists to copy from.
- **Whether the `Transaction_Opened_Notification` email alert has ever actually delivered** — it
  deploys and the Flow references it; delivery is org state.
- **`Listing_Status__c` live values in the org** — `sf project retrieve` **unions** local and remote
  picklist values, so a retrieved file cannot answer this. Verify via REST describe if O-4 resolves
  to (c) (memory: `retrieve-merges-picklist-values`).
- **Whether the three live `On_Market` dispositions at `Active Listing`** named in
  `docs/2026-08-19-disposition-flow-redesign.md:440-443` (`DISP-0003`, `DISP-0007`, `DISP-0008`) have
  `Broker_Listing__c` rows at all. They predate `openBrokerListings`, so they probably do not — which
  means the new batch's locator would skip them entirely and the feature would be invisible on the
  only live on-market listings in the org. **This is worth checking before anyone judges the feature
  working.**
