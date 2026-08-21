# Design Requirements — Offer Form Simplification, Call-for-Offers De-manualisation, Stage Retirement

**Date:** 2026-08-21
**Author:** Salesforce Design Agent
**Scope:** Three user requests (A, B, C), analysed against the repo as it stands on branch
`feature/acquisitions-fsd-tranche-1`.
**Status:** 🔴 **NOT READY TO BUILD.** Request A carries one blocking design question that the
user's stated resolution does not answer (§A.4). Requests B and C are ready.

**Sources read in full before writing:** `CLAUDE.md`, `ARCHITECTURE.md`,
`.claude/rules/{apex-layering,bulk-test,content-publication,invocable,salesforce-global}-rule.md`,
`docs/2026-08-19-disposition-flow-redesign.md`, plus every file quoted below.

---

## 0. Corrections to the brief — read these first

The brief's premises were checked, not assumed. Five are wrong or incomplete, and three of them
change the design.

| # | Brief said | Repo says | Impact |
|---|---|---|---|
| 0.1 | "`Disposition_Offer__c` has **no broker field today** — verify" | ✅ **Confirmed.** `force-app/main/default/objects/Disposition_Offer__c/fields/` holds 16 custom fields; none is a broker. | None — brief correct. |
| 0.2 | "`Disposition__c.Selected_Broker__c` is a Text display string, while `BOV_Submission__c.Broker__c` is the actual Contact on the on-market path — work out the correct source for **both**" | ⚠ **Incomplete.** `force-app/main/default/objects/Disposition__c/fields/Broker__c.field-meta.xml` **exists** — a `Lookup(Contact)` added 2026-08-20, off-market only, *"the field the Broker Selection approval gate tests"*. The off-market source is not a text parse; it is a lookup already on the parent. | 🔴 **Changes the design.** See §A.3. |
| 0.3 | "Hide … the Buyer field" | ⚠ **Ambiguous — there are TWO.** The layout carries `Buyer_Name__c` (Text 255, **`<label>Buyer</label>`**) *and* `Buyer__c` (Lookup(Contact), label "Buyer Contact"), lines 91–98 of the layout file. | 🔴 **Blocking clarification.** §A.2. |
| 0.4 | "stamp the buyer automatically … and keep the field hidden" | ⚠ **Half of this already exists.** `DispositionOfferBuyerStampService` (added 2026-08-20) already stamps `Buyer_Name__c` from `Buyer__c` in **before insert and before update**, wired in `DispositionOfferTriggerHandler.beforeInsert/beforeUpdate`. | ✅ **Simplifies the build.** Only `Buyer__c` needs a new source; `Buyer_Name__c` and the validation rule fall out for free. §A.4. |
| 0.5 | "Specify precisely which NDA is chosen when a disposition has several signed NDAs — that is the hard part" | 🔴 **It is harder than stated, and in a different way.** The question is not only "which NDA" but "why does every offer on this sale get the *same* buyer". See §A.5 — this is the conflict flag the brief asked for. | 🔴 **Blocking.** |

---

## 🚨 CONFLICT FLAG #1 — auto-stamping one buyer onto every offer breaks the timeline it was meant to protect

The brief justified auto-stamping partly to keep `lwc/dispositionBuyerTimeline` alive. **Auto-stamping
a single disposition-scoped buyer onto every offer does not keep it alive — it makes it wrong in a way
nothing on the page contradicts.**

The join is a Contact Id, both ends:

- `force-app/main/default/classes/DispositionBuyerTimelineService.cls:245` reads
  `NdaSelector.selectBuyerTimelineByDispositionId(dispositionId)` — **one row per buyer-role NDA**, many
  rows per disposition, no `LIMIT`.
- `:262` reads `DispositionOfferSelector.selectEarliestByBuyerIds(buyerIds, dispositionId)` and at `:266`
  keys the result map on `offer.Buyer__c`.
- `:320-322` — `if (nda.Buyer__c != null) { row.firstOfferDate = firstOfferByBuyer.get(nda.Buyer__c); }`

So the "first offer" column matches **`Disposition_Offer__c.Buyer__c == NDA__c.Buyer__c`**, per buyer.

If a rule stamps *one* buyer (however chosen) onto *every* offer on a disposition with three signed
buyer NDAs, then:

1. Buyer 1's tile shows a first-offer date derived from **offers that buyers 2 and 3 made**.
2. Buyers 2 and 3 show a permanent `—` in the first-offer column and `—` in "days to respond",
   which `DispositionBuyerTimelineService`'s own header calls out as the legacy-row shape:
   *"a legacy row has no buyer Contact Id, so it can never be matched to an offer … It is NOT a
   reason to match on NAME instead: two buyers can share a name, and a name-matched offer would
   attribute one buyer's bid to another."* The stamp reintroduces exactly the misattribution that
   sentence forbids, by a different route.
3. `dispositionOffer`'s card (`lwc/dispositionOffer/dispositionOffer.js:15`, column `Buyer_Name__c`)
   renders the **same buyer name on every row** of a competitive bid table.
4. `DispositionApprovalService.selectOffer` — described in `Buyer_Required_On_Offer`'s own comment as
   *"Buyer identity is what … selectOffer is ultimately choosing between"* — is now choosing between
   offers that all name the same party.

**This is not an edge case.** A multi-buyer disposition is the normal shape of the sale: it is what
`lwc/dispositionCallForOffers` exists to run, what `Offer Selection` is a stage for, and what
`DispositionOfferSelectionGuardService`'s exclusivity guard exists to arbitrate. The single-buyer
disposition is the *special* case.

**Consequence for the decision the user already made:** "stamp the buyer automatically and keep the
field hidden" is safe **only where the disposition has exactly one qualifying signed buyer NDA**. It is
not safe as a general rule, and the failure is silent. §A.5 sets out three resolutions and asks the
user to pick one; nothing in A should be built until they do.

---

## 🚨 CONFLICT FLAG #2 — hiding `Offer_Financing_Type__c` blanks the offer-selection decision surface

`Offer_Financing_Type__c` is not an isolated form field. It is read on two decision screens:

- `force-app/main/default/lwc/dispositionOfferSelect/dispositionOfferSelect.js:23` (field list) and
  `:85` (rendered into the radio-list label). This is the **Select Offer** ScreenAction behind the
  `Select_Offer` quick action — the screen where DPEG picks the winning bid.
- `force-app/main/default/approvalProcesses/Disposition_Offer__c.Offer_Selection_Approval.approvalProcess-meta.xml:74`
  — an `approvalPageField`. The two named principals see it when they approve.

Hide the field from the layout and **no analyst can ever enter it again**, because the layout is the
only entry point (§A.1). Both screens keep rendering the field; both will render it blank on every
offer created after the change, permanently, with no error anywhere. All-cash and financed-with-
contingency offers become indistinguishable at the exact moment someone chooses between them.

**This is reported, not decided.** If the user wants it hidden anyway, that is their call — but it
should be made knowing the approval page goes blank, not discovered later.

---

# REQUEST A — Simplify the Disposition Offer form

## A.1 Where the form actually is — answered

**It is the page layout `force-app/main/default/layouts/Disposition_Offer__c-Disposition Offer Layout.layout-meta.xml`.
Hiding a field there works.** Proven three ways, not assumed:

| Evidence | Result |
|---|---|
| `force-app/main/default/flexipages/` searched for `Disposition_Offer__c` | **No files.** No custom record page for this object. |
| `force-app/main/default/quickActions/Disposition_Offer__c*` | **No files.** No create/edit quick action. |
| `lwc/dispositionOffer/dispositionOffer.js:43-49` and `lwc/dispositionCallForOffers/dispositionCallForOffers.js:136-146` | Both "+ Log Offer" buttons call `NavigationMixin.Navigate` → `standard__objectPage`, `actionName: 'new'`. That screen renders **from the layout**. |

The layout file's own comment (lines 18–31, 66–76) states the same conclusion independently:
*"this object has NO custom FlexiPage anywhere in force-app … so this layout is the ONLY route to
reachability for this field"*.

🔴 **The corollary matters for §A.5:** a classic page layout has **no conditional visibility**. There
is no way to show the buyer field "only when the automation couldn't resolve one". That would require
building a FlexiPage with Dynamic Forms for `Disposition_Offer__c`, which does not exist and is new
scope.

## A.2 🔴 BLOCKING CLARIFICATION — which "Buyer field"?

Two fields, both on the layout, one labelled "Buyer":

| API name | Type | Label | Layout line | FLS in `DPEG_Disposition_Edit` |
|---|---|---|---|---|
| `Buyer_Name__c` | Text(255) | **"Buyer"** | 91–94, `Edit` | `editable=true` (line 1593) |
| `Buyer__c` | Lookup(Contact) | "Buyer Contact" | 95–98, `Edit` | `editable=true` (line 1677) |

The naming was deliberate — `Buyer__c.field-meta.xml` lines 26–35 record that `Buyer_Name__c` already
owns the label "Buyer", which is why the lookup took "Buyer Contact".

**The only coherent reading of the request is: hide BOTH.** Hiding one and leaving the other leaves a
field labelled "Buyer" on a form the user asked to have no buyer field on. The design below assumes
both. **Confirm before build.**

## A.3 The broker source — corrected, and it is a lookup on both paths

Do **not** parse `Selected_Broker__c`. Its own field file
(`objects/Disposition__c/fields/Selected_Broker__c` context, documented at
`objects/Disposition__c/fields/Broker__c.field-meta.xml:124-127`) states:
*"⚠ ONE FIELD, TWO FORMATS. `Selected_Broker__c` reads 'Firm' on on-market rows and 'Person - Firm' on
off-market rows … **NO CONSUMER MAY PARSE THIS FIELD.** Nothing parses it today; keep it that way."*
It also carries a documented permanent-staleness window on Contact rename (lines 98–119).

| Path | Source of the broker Contact Id | Evidence |
|---|---|---|
| **Off-market** | `Disposition__c.Broker__c` — read straight off the parent, zero extra query. | `objects/Disposition__c/fields/Broker__c.field-meta.xml:225-248`. Description: *"OFF-MARKET ONLY. The broker Contact directly picked for this disposition."* |
| **On-market** | `BOV_Submission__c.Broker__c` on the submission whose `Submission_Status__c = 'Selected'`. | `BovSubmissionSelector.selectSelectedByDispositionId` (line 181) already isolates that row. |

⚠ **On-market timing gap, stated plainly.** The on-market broker only exists once
`Broker_Finalize_Approval` has approved a submission and `BovSubmissionTriggerHandler` has stamped the
parent. An offer logged before that resolves to **null broker**, and no later automation backfills it.
Off-market has the mirror gap: `Broker__c` is set at `Broker Selection`, so an offer logged at
`Disposition Readiness` also resolves null. Both are acceptable (offers do not normally exist that
early) but must not be discovered in UAT.

⚠ **Widening `BovSubmissionSelector`'s SELECT is an FLS change, not a code change.**
`selectSelectedByDispositionId` (line 185) selects `Id, Broker_Firm__c, Contact_Name__c,
Submission_Status__c` and runs `WITH USER_MODE`. Adding `Broker__c` to that list means **one persona
without read on `BOV_Submission__c.Broker__c` breaks every caller of this method with
`System.QueryException: No such column`** — an FLS denial wearing a schema error (ARCHITECTURE.md §2).
Grant matrix, measured:

| Permission set | `BOV_Submission__c.Broker__c` | Verdict |
|---|---|---|
| `DPEG_Disposition_Edit` | `readable=true, editable=true` (line 1319) | ✅ safe |
| `DPEG_Disposition_View` | `readable=true, editable=false` (line 604) | ✅ safe |
| `DPEG_Admin_Access` | **NOT VERIFIED — must be checked before this SELECT is widened** | ⚠ open |

`SYSTEM_MODE` is **not** the fix here; the method backs a read a human asked for.

### A.3.1 New field — `Disposition_Offer__c.Broker__c`

| Property | Value | Reason |
|---|---|---|
| API name | `Broker__c` | ARCHITECTURE.md §1: a role-named Contact lookup takes the role name. Matches `BOV_Submission__c.Broker__c`, `Disposition__c.Broker__c`, `Lease_Inquiry__c.Broker__c`. |
| Label | **"Broker Contact"** — *not* "Broker" | Matches the sibling convention (`BOV_Submission__c.Broker__c` is labelled "Broker Contact"; `Buyer__c` is "Buyer Contact"). Also avoids a duplicate-label collision in the report field picker, the hazard `Buyer__c`'s comment (lines 26–35) was written to prevent. |
| `referenceTo` | `Contact` | |
| `deleteConstraint` | `SetNull` | Every sibling Contact lookup in this repo uses it. `Restrict` would block Contact deletion org-wide. |
| `relationshipName` | 🔴 **Collision check required at build time.** Taken so far: `Broker_Assignments`, `Brokered_Dispositions`, `Lease_Inquiries`, `Brokered_Opportunities`, `Brokered_BOV_Submissions`, `Incoming_Broker_Changes`, `Outgoing_Broker_Changes`, `Buyer_NDAs`, `Buyer_Disposition_Offers`. Suggest `Brokered_Disposition_Offers`. | Relationship names are unique per parent object and disruptive to change after deploy. |
| `lookupFilter` | 🔴 **NONE (or `isOptional=true`) — deliberately** | Five sibling fields carry an ACTIVE non-optional filter on `Contact.RecordType.DeveloperName = 'Broker'`. **This field is machine-stamped, and the repo's own precedent forbids an active filter on a machine-stamped lookup:** `Opportunity.Broker__c` has no filter *"because that field is machine-stamped by `LeadConvertService` at conversion, and a non-optional filter would make lead conversion fail hard"* (`Disposition__c/fields/Broker__c.field-meta.xml:44-53`, corroborated at `NDA__c/fields/Buyer__c.field-meta.xml:22-30`). Same shape here. |
| `required` | `false` | See §A.3's null cases. |
| FLS | `readable=true, editable=false` in **both** `DPEG_Disposition_Edit` and `DPEG_Disposition_View` | It is machine-owned, matching how `Is_Selected__c` and `Approval_Status__c` are granted (`DPEG_Disposition_Edit` lines 1657–1666). ⚠ A Metadata-API-deployed field ships with **no FLS for anyone, System Administrator included** — the field file and both permission sets must deploy together. |
| Layout | **Not added** | The user asked for a *simpler* form. It is stamped, not entered. It stays reachable via reports and the Select Offer screen if it is added there. ⚠ Note the layout-comment warning at lines 18–31: a field absent from the layout is invisible on the detail page and unrepairable by hand. Accept or add as `Readonly`. **User decision.** |

## A.4 The buyer source — the NDA-selection rule

### A.4.1 The gate — four predicates, and the brief named only one

```
NDA__c
WHERE Disposition__c = <the offer's parent>
  AND Party_Role__c   = 'Buyer'          <- 🔴 MANDATORY. The brief did not mention it.
  AND Status__c       = 'Signed'         <- the brief's gate
  AND Buyer__c       != null             <- 🔴 MANDATORY. Legacy rows have no Contact.
```

- **`Party_Role__c = 'Buyer'` is the single most important filter.**
  `objects/NDA__c/fields/Party_Role__c.field-meta.xml` is restricted to `{Buyer, Introducing Broker}`
  and is *"EXPOSED ON THE `Disposition_NDA` RECORD TYPE ONLY"*. Its help text: *"One NDA record per
  party — DPEG collects and counter-signs both."* Without this predicate the automation will happily
  stamp **the introducing broker as the buyer** on any deal where the broker's NDA came back first.
  `DispositionBuyerTimelineService`'s header (lines 43–49) makes the same point: *"An `Introducing
  Broker` NDA is a real and expected row on a disposition and is NOT a buyer."*
- **`Status__c = 'Signed'`** — correct, and the brief's warnings are confirmed verbatim:
  - `NDA_Signed__c` **latches**. Its own field file (`NDA__c/fields/NDA_Signed__c.field-meta.xml:24-28`):
    *"DO NOT USE THIS FIELD TO ANSWER 'DID THIS PARTY SIGN'. Use `Status__c`."* It is also **not granted
    to either disposition permission set**, so a `USER_MODE` read of it would throw.
  - `Date_Signed__c` is never cleared on decline (same file, and
    `DispositionBuyerTimelineService.cls:17-27`). Gate on status; read the date only after.
- **`Buyer__c != null`** — `NDA__c.Buyer__c` was added 2026-08-20 and *"No backfill is in scope — that is
  a decision, not an omission"* (`DispositionBuyerTimelineService.cls:64-73`). Every NDA created before
  that date carries only `Counterparty_Name__c`. Matching on the **name** instead is explicitly
  forbidden by that same passage.

### A.4.2 What happens after the gate — 🔴 THE OPEN DECISION

| Qualifying signed buyer NDAs | Recommended behaviour | Consequence |
|---|---|---|
| **Exactly 1** | Stamp `Disposition_Offer__c.Buyer__c` from it. The existing `DispositionOfferBuyerStampService` then fills `Buyer_Name__c` in the same before-save pass, and `Buyer_Required_On_Offer` passes. | ✅ Clean. No further work. |
| **0** | 🔴 **The save fails and there is no field on screen to fix it.** `Buyer_Required_On_Offer` is `ISBLANK(Buyer_Name__c)` with **no `ISNEW`/`ISCHANGED` guard** (`Buyer_Required_On_Offer.validationRule-meta.xml:62`), so it refuses **every** save, not just the first. | ⚠ **Unresolved.** See §A.4.3. |
| **2 or more** | Any pick is a coin flip that silently misattributes the offer. See Conflict Flag #1. | ⚠ **Unresolved.** See §A.4.3. |

### A.4.3 Three resolutions — the user must pick one

**Option 1 — Ship it anyway, accept the failures.** Stamp when exactly one qualifies; leave `Buyer__c`
null otherwise. On 0 or ≥2 the offer **cannot be created at all** and the analyst gets a validation
error naming a field they cannot see. *Cost: creating an offer becomes impossible on any competitive
sale.* **Not recommended.**

**Option 2 — Repoint the validation rule and let the buyer be blank.** Amend
`Buyer_Required_On_Offer` from `ISBLANK(Buyer_Name__c)` to `ISBLANK(Buyer__c)` (which the rule's own
comment already schedules: *"WHEN D LANDS, AMEND THIS ONE FILE"*), then **deactivate** it. Offers save
with no buyer; the timeline shows `—` for the first-offer column, which is truthful. *Cost: the
protection the rule was created for on 2026-08-20 is discarded, and the offer table shows a blank
buyer column.* Requires explicit user sign-off — the rule is one day old.

**Option 3 — Move buyer selection off the form entirely (recommended, larger).** Replace the
"+ Log Offer" navigation in `lwc/dispositionOffer` and `lwc/dispositionCallForOffers` with a
ScreenAction LWC modelled on the existing `lwc/dispositionOfferSelect`: a short radio list of the
disposition's **signed buyer-role NDAs**, plus the price/date fields, submitted through a service that
sets `Buyer__c` and `Broker__c`. The analyst still never types a buyer — they pick from two or three
names the deal already has — the form gets genuinely simpler, and every offer is attributed correctly.
*Cost: one new LWC + one service + one controller + Jest + Apex tests. Precedent exists
(`dispositionOfferSelect` + `DispositionApprovalController`), so it is a copy, not an invention.*
**Note this is more than the user asked for and is offered as an option, not assumed.**

### A.4.4 If Option 1 or 2 is chosen — Apex shape

| Layer | Component | Notes |
|---|---|---|
| Service (new) | `DispositionOfferBuyerResolveService` | Resolves `Buyer__c` and `Broker__c` for offers whose parent is set and whose fields are blank. Mirrors `DispositionOfferBuyerStampService`'s **skeleton** — two-pass collect-then-assign, change-keyed, one query per chunk. 🔴 It must run **before** `DispositionOfferBuyerStampService` in `beforeInsert` so the name stamp sees the buyer it just resolved. |
| Trigger Handler (modify) | `DispositionOfferTriggerHandler.beforeInsert` | Insert the new call **ahead of** the existing `DispositionOfferBuyerStampService.stampBuyerName(...)` at line 186. Do **not** add it to `beforeUpdate` — re-resolving on every save would overwrite a hand correction. |
| Selector (modify) | `NdaSelector` — new method, e.g. `selectSignedBuyerNdasByDispositionIds(Set<Id>)` | 🔴 **`WITH SYSTEM_MODE`, justified at its own declaration in the class header.** This is a trigger-path read performed on the principal's behalf, not one they asked for (ARCHITECTURE.md §2). `USER_MODE` here would throw inside a trigger and roll back the analyst's own save. ⚠ It traverses no relationship, so unlike `selectBuyerTimelineByDispositionId` it adds no `Contact` object-level gate. ⚠ Update the class header's method census — it currently enumerates 9 methods, 2 `SYSTEM_MODE`; ARCHITECTURE.md §2 names those headers as the authoritative inventory and this file has miscounted before (its own lines 31–39). |
| Selector (modify) | `BovSubmissionSelector.selectSelectedByDispositionIds` (line 325) | Add `Broker__c` to the SELECT. See the FLS matrix in §A.3. |
| Domain | none | No new domain rules. Do not put SOQL in the handler (`.claude/rules/apex-layering-rule.md`). |

**Budget:** at most **two SOQL, zero DML per chunk**, constant in offer count (one NDA read, one BOV
read; both skipped when no row in the chunk needs resolution). Must be asserted, matching the pattern
`DispositionOfferBuyerStampService`'s header sets.

**Bulk:** 🔴 `.claude/rules/bulk-test-rule.md`'s **251-record mandate applies in full and there is no
exemption to claim** — this is a trigger path that loops over a collection, exactly as
`DispositionOfferBuyerStampService`'s header states for itself (line 195).

**Fixtures:** ⚠ `TestDataFactory.createDispositionOffers` sets `Buyer_Name__c` and leaves `Buyer__c`
null (recorded at `DispositionOfferBuyerStampService.cls:159-168` — *"Do not change
`TestDataFactory.createDispositionOffers`"*). New resolution logic must **skip** a record whose buyer
is already resolved, or every existing offer fixture in the suite changes meaning. This is the
`definition-swap-inverts-negative-fixtures` trap.

## A.5 The fields to hide — one-by-one automation impact

Layout file: `force-app/main/default/layouts/Disposition_Offer__c-Disposition Offer Layout.layout-meta.xml`.

| Field / section | Layout lines | Machine writer? | Safe to hide? |
|---|---|---|---|
| `Buyer_Name__c` | 91–94 | `DispositionOfferBuyerStampService.stampBuyerName` — **before-context in-memory assignment**, *"NOT FLS-checked"* (class header, lines 198–201). Layout removal cannot disable it. | ✅ Automation safe. ⚠ It is the **only** column in `lwc/dispositionOffer/dispositionOffer.js:15,23` — the offers card renders `—` for every offer whose buyer cannot be resolved. |
| `Buyer__c` | 95–98 | To be added by A.4.4. | ✅ Automation safe. 🔴 Depends entirely on A.4.3. |
| `NDA_Status__c` | 105–108 | **None.** Repo-wide the only references are this layout, both permission sets, `objectTranslations/Disposition_Offer__c-en_US/NDA_Status__c`, and `scripts/seed-disposition-offers.apex:38,50,57,70,85`. No Apex, no LWC, no flow, no approval page field. | ✅ **Clean.** Nothing breaks. Value becomes the picklist default `Pending` forever. |
| `Offer_Status__c` | 102–105 | `DispositionOfferTriggerHandler.stampAcceptedStatus` (line 232) — **before update, in-memory**, writes only `'Accepted'`. | ✅ Automation safe. 🔴 **Behaviour loss.** The layout's own comment (lines 57–61) says it is *"LEFT EDITABLE ON PURPOSE … Every other transition, Received, Countered and so on, is the analyst's to log, so this is not a machine owned field and locking it would remove the ability to record a negotiation."* Hiding it does exactly what that comment warns against. |
| `Offer_Financing_Type__c` | 136–139 | **None** — analyst-typed. | ⚠ **See Conflict Flag #2.** Automation safe, but read by `lwc/dispositionOfferSelect` and by `Offer_Selection_Approval`'s approval page. Both go permanently blank. |
| **"Selection and Approval"** section — `Is_Selected__c`, `Approval_Status__c` | 178–196 | `Is_Selected__c` ← `DispositionApprovalService.selectOffer` (`SYSTEM_MODE` DML). `Approval_Status__c` ← `Offer_Selection_Approval`'s `finalApprovalActions` workflow field updates. | ✅ **Confirmed safe.** Both are already `Readonly` on the layout and `editable=false` in `DPEG_Disposition_Edit` (lines 1657–1666). Neither writer reads a layout. |

🔴 **Do NOT touch the `relatedLists` block (lines 236–243).** It is a sibling of `layoutSections`, not a
child of the section being removed. It carries `RelatedProcessHistoryList`, which the file's own
comment (lines 225–235) identifies as *"the only route to Recall Approval Request on this object"*.
`Offer_Selection_Approval` is `recordEditability = AdminOnly` with `allowRecall = true`; delete this
block and a locked offer becomes unrecallable from the UI.

⚠ **No FLS change is proposed for any hidden field.** Layout visibility and FLS are independent, the
fields are still read by LWCs and selectors, and a `PermissionSet` deploy **replaces its entire
`fieldPermissions` set** — a needless edit there is a large blast radius for no gain.

---

# REQUEST B — Call for Offers is no longer entered by hand

> *"call for offers won't be log manually, they will be populated automatically but right now can just
> seed data in it. We will create its proper flow later on."*

**Scoped minimally. The future automation is explicitly NOT designed here.**

## B.1 What currently *requires* a manual entry — nothing

Checked, not assumed:

| Possible requirement | Finding |
|---|---|
| `required=true` on the field? | **No.** `objects/Broker_Listing__c/fields/Call_For_Offers_Date__c.field-meta.xml:5` — `<required>false</required>`. Plain `Date`, 9-line file, no default. |
| Validation rule? | **No.** `objects/Broker_Listing__c/` has **no `validationRules/` directory at all.** |
| Apex writer? | **No.** The only creator of `Broker_Listing__c` is `DispositionStageEntryService.openBrokerListings`, which writes `Disposition__c`, `List_Date__c`, `Listing_Status__c`, `Broker_Firm__c` — the field is not among them. |
| Reader that breaks on null? | **No.** `lwc/dispositionCallForOffers/dispositionCallForOffers.js:81-86,111-113` handles null explicitly (`_cfoDate = null` → `formatLongDate(null)`), and the file's own rule is *"EVERY DISPLAYED GETTER RETURNS A STRING, NEVER `undefined`"*. `BrokerListingController.cls:125` copies the value through as-is. `BrokerListingSelector.cls:71` selects it. |

✅ **A blank `Call_For_Offers_Date__c` breaks nothing today.**

## B.2 The smallest honest change

**One word, in one file.**

| Change | File | Detail |
|---|---|---|
| Layout behaviour `Edit` → `Readonly` | `force-app/main/default/layouts/Broker_Listing__c-Broker Listing Layout.layout-meta.xml:82` (the `<behavior>` for `Call_For_Offers_Date__c` at line 87) | The field still renders on the detail and edit screens, still shows a seeded value, and can no longer be typed into. |

⚠ **Do NOT set `editable=false` in `DPEG_Disposition_Edit`** (currently line 1328, `editable=true`).
Two reasons: (1) a `PermissionSet` deploy replaces its whole `fieldPermissions` set, which is a large
blast radius for one word of intent; (2) the future automation the user deferred will need the grant
back, and reinstating it is a second change to the same file for no interim benefit. Layout behaviour
expresses "not hand-entered" precisely and reversibly.

⚠ The layout's own comment (lines 25–35) records a **behaviour rule** it applied — *"NO MACHINE OWNED
FIELD EXISTS ON THIS OBJECT … so every business field below is Edit"*. That statement becomes
partially false with this change. The comment must be amended in place (quote-and-retract, matching
this repo's convention), not left to mislead: the field is not yet machine-owned, it is *reserved for*
a machine owner that does not exist yet.

## B.3 Seed data — ⚠ this may already be done

| Location | Line(s) | Value |
|---|---|---|
| `scripts/seed-disposition.apex` | 216 | `Date.newInstance(2026, 6, 10)` |
| `scripts/seed-disposition-bulk.apex` | 371, 376, 381, 386 | `today.addDays(+14)`, `+7`, `-20`, `-30` — four listings, a live/overdue mix |
| `scripts/seed-disp0002.apex` | 182 | `Date.newInstance(2026, 7, 14)` |
| `force-app/main/default/classes/TestDataFactory.cls` | 2800 | `Date.today().addDays(30)` |

🔴 **`scripts/seed-disposition-bulk.apex` is MODIFIED and uncommitted in the working tree** (git status
at session start, alongside `seed-disposition-offers.apex`, `seed-sell-meter.apex`,
`seed-sell-readiness.apex`). Diff it against `HEAD` before concluding the seed is adequate — this repo
has a measured incident of a concurrent session editing shared files mid-run.

**Recommendation:** verify the four bulk-seed dates still produce the intended spread, and add nothing
new unless they do. Seeding a field that is already seeded four times over is scope creep.

## B.4 Explicitly out of scope

The automation itself. No flow, no trigger, no field-update, no `Listing_Status__c` coupling, no
`List_Date__c` arithmetic. The user deferred it in the same sentence they raised it.

---

# REQUEST C — Retire three `Disposition__c.Disposition_Stage__c` values

**Values:** `Call for Offers`, `Disposition Offer`, `Completed`. All three user-confirmed.

## C.1 Org half — done by the user

`GROUP BY Disposition_Stage__c` returns **`Active Listing` = 1 and nothing else.** Zero rows on any
retired value. This agrees with the 2026-08-19 sweep recorded at
`objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml:23-26` and at
`docs/2026-08-19-disposition-flow-redesign.md:489`, and supersedes it as the current measurement.

## C.2 Repo half — the full sweep

### C.2.1 🔴 DEPLOYABLE METADATA — must be edited

| # | File | Line(s) | What |
|---|---|---|---|
| 1 | `force-app/main/default/objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` | **157–161** `Call for Offers`, **162–166** `Disposition Offer`, **167–171** `Completed` (`<value>` blocks); comment **154–156** | The master value set. |
| 2 | `force-app/main/default/objects/Disposition__c/recordTypes/On_Market.recordType-meta.xml` | **123–127** `Call for Offers`, **128–131** `Completed` (`<values>` blocks); `<description>` **75** names both; comment **48–61** | ⚠ Carries `Call for Offers` + `Completed`, **not** `Disposition Offer` (line 56: *"Disposition Offer is NOT here — it was never on this type"*). |
| 3 | `force-app/main/default/objects/Disposition__c/recordTypes/Off_Market.recordType-meta.xml` | **114** `Disposition Offer`, **118** `Completed` (`<values>` blocks); comment **30** | ⚠ Carries `Disposition Offer` + `Completed`, **not** `Call for Offers`. **The two record types carry different subsets — do not copy one edit to the other.** |
| 4 | `force-app/main/default/objectTranslations/Disposition__c-en_US/Disposition_Stage__c.fieldTranslation-meta.xml` | **17–20** `Call for Offers`, **25–28** `Completed`, **29–32** `Disposition Offer` | 🔴 **Easy to miss.** A `<masterLabel>` naming a value the field no longer has will fail or silently no-op the deploy. Must be trimmed in the *same commit* as #1–#3. |

### C.2.2 ⚠ DEPLOYABLE METADATA — comment-only, already correct

| File | Line | Note |
|---|---|---|
| `force-app/main/default/objects/Disposition__c/fields/Is_On_Market__c.field-meta.xml` | 13 | Prose naming the retired values. Amend for accuracy; no functional change. |
| `force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml` | 148 | Comment stating both visibility rules *"now name 'Sale Closes'"*. ✅ **Verified: no live `Completed` rightValue remains** on this page. |

### C.2.3 Repo-only (never deploys — `.forceignore` lines 9, 12)

| File | Line(s) | Note |
|---|---|---|
| `force-app/main/default/lwc/dispositionSidebar/dispositionSidebar.js` | 40 | Comment. |
| `force-app/main/default/lwc/dispositionSidebar/__tests__/dispositionSidebar.test.js` | 18, 23, 24, **227** | 🔴 Line 227 is `it.each(['Call for Offers', 'Disposition Offer', 'Completed'])` — a live assertion **over the retired values**. `__tests__/**` is force-ignored so it never deploys, and Jest has no knowledge of org picklists, so it will **keep passing** after the org deletion. It is stale, not broken. Update for honesty; it is not a blocker. |
| `force-app/main/default/lwc/dispositionMain/dispositionMain.js` | 34 | Comment. |
| `force-app/main/default/lwc/dispositionMain/__tests__/dispositionMain.test.js` | 11 | Comment. |
| `force-app/main/default/classes/TestDataFactory.cls` | 2491, 2492, 2496, 2497 | Comments only. **No test fixture writes a retired value.** |
| `force-app/main/default/classes/DispositionStageEntryServiceTest.cls` | 219, 224, 459, **1366** | Comments only. Line 1366 explicitly says *"'Call for Offers' is RETIRED (pending manual Setup deletion) and must not be reintroduced"*. |
| `manifest/disposition-redesign-destructive/destructiveChangesPost.xml` | 17, 25, 34 | Comments. |
| `docs/2026-08-19-disposition-flow-redesign.md` | 192, 203, 488 | `docs/` is force-ignored. |

### C.2.4 ✅ Verified CLEAN — zero hits

`force-app/main/default/flows/**` · `objects/Disposition__c/validationRules/**` (the three surviving
rules are `All_NDAs_Signed_Before_Progression`, `Wire_Complete_Before_Sale_Closes`,
`Broker_Lookup_Is_Off_Market_Only` — none names a retired value) · `approvalProcesses/**` (all five
Disposition-family processes) · `workflows/**` · `pathAssistants/Disposition_Path_On_Market` (11 steps,
Readiness→Sale Closes) and `Disposition_Path_Off_Market` (9 steps) — **both rebuilt and clean** ·
`objects/Disposition__c/listViews/` — **the directory does not exist** · all Apex non-comment code ·
all seed scripts (none writes a retired stage) · `reports/Dispositions/**` — four reports
(`BOVs_Ordered`, `Avg_Days_on_Market`, `Broker_Alert_Due`, `Listed_With_Broker`) reference
`Disposition_Stage__c` as a **column/grouping only**, never as a filter value.

⚠ Even had a report filtered on one, it would **not** block the deletion — a report referencing a
deleted picklist value fails **silently**, which is why it is checked explicitly rather than relied on.

### C.2.5 🔴 SAME STRINGS, DIFFERENT PICKLISTS — DO NOT TOUCH

The repo carries ~60 further hits that are a **different field**. Touching any of them is a production
break unrelated to this request.

| Not-this-picklist | Where |
|---|---|
| `Opportunity.Sale_Process__c` value `Call for Offers` | `objects/Opportunity/fields/Sale_Process__c.field-meta.xml:25-27` |
| `Lead.Sale_Process__c` value `Call for Offers` | `objects/Lead/fields/Sale_Process__c.field-meta.xml:25-27`; `Lead/recordTypes/IR_Investor:388`; `Lead/recordTypes/Acquisition_Broker:400` |
| Apex on `Sale_Process__c` | `CallForOffersStampService`, `CallForOffersStampServiceTest`, `CallForOffersServiceTest`, `ExtractAddressQueueableTest`, `EmailToLeadServiceTest`, `LeadConvertServiceTest`, `PropertyExtraction`, `PropertyExtractionTest`, `ExtractionScoreUtilTest`, `LLMExtractionCalloutService:773`, `scripts/seed-fsd-06-volume-pipeline.apex:125` |
| Component **names/titles**, not values | `lwc/callForOffersList`, `lwc/callForOffersPanel`, `lwc/dispositionCallForOffers`, `layouts/Disposition_Offer__c-…` |
| A **list-view name** | `objects/Inbound_Email_Staging__c/listViews/Gated_Call_For_Offers.listView-meta.xml:68` |
| Other objects' `Completed` | `Work_Order__c.Status__c`, `Development_Feasibility_Review__c.Stage__c`, `Construction_Feasibility_Review__c.Stage__c`, `standardValueSets/{TaskStatus,WorkOrderStatus,WorkOrderLineItemStatus,ServiceAppointmentStatus}` |
| Force-ignored noise | `profiles/**` (55 files) — `.forceignore:28`. Never deploys. |

## C.3 🔴 The two org-only deletion blockers — and a hazard in the prepared manifest

`manifest/disposition-redesign-destructive/destructiveChangesPost.xml` already exists and is
**PREPARED, NOT AUTHORISED**. It deletes exactly two components, and **both exist only in the org —
neither is in `force-app` any more:**

| Component | Blocks | Repo state |
|---|---|---|
| `ValidationRule Disposition__c.Wire_Complete_Before_Completed` | Names `'Completed'` — *"a validation rule referencing a value blocks that value's manual deletion in Setup"* (manifest lines 17–19) | 🔴 **Absent.** `objects/Disposition__c/validationRules/` holds only the three rules named in §C.2.4. |
| `PathAssistant Disposition_Path` (the legacy inactive `__MASTER__` path) | *"its four remaining steps name Call for Offers and Completed"* (manifest lines 21–27) | 🔴 **Absent.** `pathAssistants/Disposition*` returns only the two rebuilt record-typed paths. |

🔴 **Consequence, and it is a real deploy hazard:** because neither component is in the source tree,
this manifest **cannot be validated locally**, and a destructive deploy targeting a component that has
already been removed from the org by hand **fails**. Before running it, confirm both still exist in
the org (e.g. `sf project retrieve start --metadata ValidationRule:Disposition__c.Wire_Complete_Before_Completed`
and `PathAssistant:Disposition_Path`) and drop from the manifest whichever no longer does.

✅ **Reconciled, not duplicated:** do **not** create a second destructive folder. This one covers both
blockers exactly, and its header explicitly and correctly refuses to list the picklist values
themselves (lines 31–36).

## C.4 Ordering — including the manual Setup steps

```
STEP 0  VERIFY (no deploy)
        0a. Re-run the zero-row sweep. ✅ Done by the user: Active Listing = 1, nothing else.
        0b. Confirm ZERO pending approval instances on any Disposition.
        0c. 🔴 Confirm both C.3 components still EXIST in the org. Amend the manifest if not.
        0d. Diff the four modified seed scripts against HEAD (concurrent-session hazard).

STEP 1  DEPLOY the A + B payload (see §D). Nothing from C ships here.

STEP 2  DEPLOY the prepared post-destructive package — deletes the two blockers.
        manifest/disposition-redesign-destructive/{package.xml, destructiveChangesPost.xml}
        Post-destructive is load-bearing: Wire_Complete_Before_Sale_Closes must already be
        live before the old rule goes, or there is a window with no wire gate at all.
        Test level RunLocalTests. Via the salesforce-devops subagent, never a direct CLI call.

STEP 3  🔴 MANUAL, IN SETUP — a deploy CANNOT delete a picklist value.
        Setup > Object Manager > Disposition > Fields & Relationships > Disposition Stage
          > Values > "Del" beside each of: Call for Offers, Disposition Offer, Completed.
        3a. When prompted, choose to REPLACE WITH NONE / leave blank. Zero rows carry any of
            the three, so no replacement value is needed and choosing one would be a silent
            data change.
        3b. Both record types update THEMSELVES. On_Market's own comment (lines 51-55):
            "they must be listed here until that wave runs and Salesforce drops them from
            this type automatically." Do NOT hand-edit the record types in Setup.
        3c. Then scroll to the "Deleted Values" list and ERASE all three. A deleted picklist
            value is only soft-deleted; the label stays reserved until erased.
        3d. Read the surviving value ORDER back on the same screen. A picklist REORDER can
            silently not take, and no Apex or Jest test can observe Path render order.

STEP 4  DEPLOY the repo trim — ONE commit, ALL FOUR files from §C.2.1 together.
        🔴 Splitting them fails: a record type referencing a value the field no longer
        declares, or an objectTranslation masterLabel with no matching value, is a deploy
        error.
        🔴 Doing STEP 4 BEFORE STEP 3 does nothing useful — the org keeps the values, and
        the next retrieve UNIONS them back into the repo, which reads exactly like a failed
        deploy.
        🔴 DO NOT RUN `sf project retrieve` AT ANY POINT BETWEEN STEP 3 AND STEP 4.

STEP 5  VERIFY via REST describe on Disposition_Stage__c — expect exactly 11 active values.
        🔴 Verify by DESCRIBE, never by retrieving the field file: a retrieve unions local
        and remote picklist values and will show the deleted ones as if the deletion failed.
```

---

# D. Deliverable summary

## D.1 Metadata inventory (🔵 salesforce-admin)

| Component | File | Request | Action |
|---|---|---|---|
| CustomField (new) | `objects/Disposition_Offer__c/fields/Broker__c.field-meta.xml` | A | Create per §A.3.1 |
| PermissionSet | `permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml` | A | Add `Disposition_Offer__c.Broker__c` — `readable=true, editable=false`. Additions-only; diff against `HEAD` for zero deletions. |
| PermissionSet | `permissionsets/DPEG_Disposition_View.permissionset-meta.xml` | A | Same grant. |
| Layout | `layouts/Disposition_Offer__c-Disposition Offer Layout.layout-meta.xml` | A | Remove `Buyer_Name__c`, `Buyer__c`, `NDA_Status__c`, `Offer_Status__c`, `Offer_Financing_Type__c` and the whole "Selection and Approval" section. 🔴 **Preserve the `relatedLists` block.** |
| ValidationRule | `objects/Disposition_Offer__c/validationRules/Buyer_Required_On_Offer.validationRule-meta.xml` | A | **Only if Option 2 (§A.4.3) is chosen.** Amend in place per its own comment; do not add a second rule. |
| Layout | `layouts/Broker_Listing__c-Broker Listing Layout.layout-meta.xml` | B | Line 82 `<behavior>Edit</behavior>` → `Readonly` for `Call_For_Offers_Date__c`; amend the lines 25–35 comment. |
| CustomField | `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` | C | Remove three `<value>` blocks (STEP 4 only) |
| RecordType | `objects/Disposition__c/recordTypes/On_Market.recordType-meta.xml` | C | Remove `Call for Offers`, `Completed`; fix `<description>` |
| RecordType | `objects/Disposition__c/recordTypes/Off_Market.recordType-meta.xml` | C | Remove `Disposition Offer`, `Completed` |
| CustomFieldTranslation | `objectTranslations/Disposition__c-en_US/Disposition_Stage__c.fieldTranslation-meta.xml` | C | Remove three `<picklistValues>` blocks |
| CustomField (comment) | `objects/Disposition__c/fields/Is_On_Market__c.field-meta.xml` | C | Amend line 13 |
| Manifest | `manifest/disposition-redesign-destructive/` | C | **Reconcile, do not duplicate.** Amend only if a target no longer exists in the org. |

## D.2 Apex inventory by layer (🟢 salesforce-developer)

| Layer | Class | Action |
|---|---|---|
| Service | `DispositionOfferBuyerResolveService` | **New.** `with sharing`. Zero SOQL, zero DML — mutates `Trigger.new`. §A.4.4. |
| Trigger Handler | `DispositionOfferTriggerHandler` | **Modify** `beforeInsert` only; new call ordered **ahead of** `stampBuyerName`. No SOQL, no DML in the handler. |
| Selector | `NdaSelector` | **New method**, `WITH SYSTEM_MODE`, justified at its own declaration. Update the class header's method census. |
| Selector | `BovSubmissionSelector` | **Modify** `selectSelectedByDispositionIds` SELECT — an FLS change (§A.3). |
| Domain | — | None. |
| Tests | `DispositionOfferBuyerResolveServiceTest` (new), `DispositionOfferTriggerHandlerTest`, `NdaSelectorTest`, `BovSubmissionSelectorTest` | 🔴 251-record bulk mandate applies in full. Constant-query-count assertion required. |

## D.3 LWC inventory

**No LWC change is required by A, B or C as scoped.** Impacts to report, not to build:

| Component | Impact |
|---|---|
| `lwc/dispositionOffer` | Its `Buyer_Name__c` column renders `—` on any offer whose buyer cannot be resolved (§A.5). |
| `lwc/dispositionOfferSelect` | Its financing-type label renders blank on every offer created after the change (Conflict Flag #2). |
| `lwc/dispositionBuyerTimeline` | Depends on the §A.4.3 decision (Conflict Flag #1). |
| `lwc/dispositionSidebar/__tests__` | Stale assertion over retired values; passes regardless. |
| `lwc/dispositionCallForOffers` | Unaffected by B — already null-safe. |

⚠ If Option 3 (§A.4.3) is chosen, add one new LWC + Jest + `@sa11y/jest` and the LWC inventory changes
materially.

## D.4 Risk register

| # | Risk | Severity | Evidence | Mitigation |
|---|---|---|---|---|
| R1 | One buyer stamped onto every offer misattributes bids and half-kills the two-day-old timeline | 🔴 **Critical** | `DispositionBuyerTimelineService.cls:262-266, 320-322` | **Blocking.** Resolve §A.4.3 before any build. |
| R2 | The stamp picks an `Introducing Broker` NDA and names a broker as the buyer | 🔴 Critical | `NDA__c/fields/Party_Role__c.field-meta.xml` | Mandatory `Party_Role__c = 'Buyer'` predicate (§A.4.1). |
| R3 | Zero qualifying NDAs → unsaveable offer, VR error on a field with no input on screen | 🔴 Critical | `Buyer_Required_On_Offer:62` (no `ISNEW`/`ISCHANGED`) | §A.4.3. A classic layout has no conditional visibility (§A.1). |
| R4 | Hiding `Offer_Financing_Type__c` blanks the Select Offer screen and the approval page | 🟠 High | `dispositionOfferSelect.js:23,85`; `Offer_Selection_Approval:74` | Conflict Flag #2 — user decision. |
| R5 | Widening `BovSubmissionSelector`'s `USER_MODE` SELECT throws `QueryException` for an ungranted persona | 🟠 High | ARCHITECTURE.md §2; grant matrix §A.3 | Verify `DPEG_Admin_Access` before deploy. Fix is a permission set, never `SYSTEM_MODE`. |
| R6 | Destructive package targets components absent from the org → deploy fails | 🟠 High | Neither target is in `force-app` | STEP 0c. |
| R7 | Repo trim deployed before the manual Setup deletion → silent no-op; retrieve restores the values | 🟠 High | `Disposition_Stage__c` comment lines 16–22 | STEP 3 strictly before STEP 4; never retrieve between them. |
| R8 | The three §C.2.1 files deployed separately → deploy error | 🟠 High | Record types and translations reference the master value set | One commit, four files. |
| R9 | Picklist reorder silently not taken; both Paths render wrong; every test still passes | 🟡 Medium | Same comment, lines 67–69 | STEP 3d — read the order back in Setup. |
| R10 | A sibling `Sale_Process__c` value edited by mistake | 🟡 Medium | §C.2.5, ~60 hits | Edit **only** the four files in §C.2.1. |
| R11 | Hiding `Offer_Status__c` removes the analyst's ability to log Received/Countered | 🟡 Medium | Layout comment lines 57–61 | Report to user; their call. |
| R12 | A concurrent session has already edited the shared seed scripts / permission sets | 🟡 Medium | Four scripts modified and uncommitted at session start | Diff hub files against `HEAD` before deploying. |
| R13 | Adding a `lookupFilter` to the new `Broker__c` makes the stamp fail hard | 🟡 Medium | `Disposition__c/fields/Broker__c.field-meta.xml:44-53` | No active filter on a machine-stamped lookup (§A.3.1). |
| R14 | New field ships FLS-invisible to everyone including System Administrator | 🟡 Medium | ARCHITECTURE.md §2 | Field + both permission sets deploy together. |

## D.5 Open questions — kept separate, nothing assumed

| # | Question | Blocks |
|---|---|---|
| **Q1** | 🔴 **§A.4.3 — which resolution for 0 or ≥2 signed buyer NDAs?** Option 1 (offer becomes uncreatable on competitive sales), Option 2 (retire a one-day-old validation rule), or Option 3 (buyer picker ScreenAction — larger, but the only one that keeps the timeline correct)? | **All of Request A** |
| **Q2** | 🔴 **§A.2 — "the Buyer field" means both `Buyer_Name__c` and `Buyer__c`?** | A |
| **Q3** | Conflict Flag #2 — hide `Offer_Financing_Type__c` knowing the Select Offer screen and the approval page go permanently blank? | A |
| **Q4** | R11 — hide `Offer_Status__c` knowing the analyst can no longer log Received/Countered? | A |
| **Q5** | Should the new `Disposition_Offer__c.Broker__c` appear on the layout as `Readonly`, or be entirely off-layout (invisible on the detail page and unrepairable by hand)? | A |
| **Q6** | Off-market vs on-market broker resolution timing (§A.3) — is a null broker on an early offer acceptable, or should the stamp be retried when the broker is later appointed? | A |
| **Q7** | Is `DPEG_Admin_Access` granted `BOV_Submission__c.Broker__c`? (Not verifiable from the repo alone — needs an org query.) | A |
| **Q8** | B — are the four existing seeded `Call_For_Offers_Date__c` values sufficient, or is a new seed wanted? Requires diffing the uncommitted `seed-disposition-bulk.apex`. | B |
| **Q9** | C — do both destructive-package targets still exist in the org? | C STEP 2 |

---

## Routing (per `CLAUDE.md`)

- **Request B, Request C** → 🔵 `salesforce-admin`. Layout behaviour, picklist/record-type/translation
  trims, a prepared destructive manifest. No architecture decisions.
- **Request A** → 🔵 `salesforce-admin` (field, FLS, layout) then 🟢 `salesforce-developer` (service,
  handler, selectors) then 🟡 `salesforce-unit-testing` then 🟣 `salesforce-code-review`.
  **If Option 3 is chosen, the LWC + service work stays with `salesforce-developer`** — it is a
  standard ScreenAction with an in-repo precedent, not an integration or LDV problem.
- 🔴 **Gate 1 must not be passed for Request A until Q1 and Q2 are answered.**

**Deployment:** all deploys, including the destructive package, route through 🔴 `salesforce-devops`.
No direct `sf` CLI calls from the main agent.
