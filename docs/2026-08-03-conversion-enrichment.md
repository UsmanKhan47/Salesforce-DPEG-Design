# Conversion Enrichment — Deal-Screening Data Now Survives Lead Conversion

**Date:** 2026-08-03
**Author:** Documentation Agent
**Status:** Deployed to `usman-dpeg` — two-stage deploy, metadata `0Afiw000000DimPCAS` then Apex
`0Afiw000000DipdCAC`, 213/213 tests passing. Two components (the Opportunity record page and the
`DPEG_Acquisitions` permission set) were deliberately split out and NOT deployed in this bundle — see
"What Was Deferred" below.

---

## 📋 Overview

### Original Request

> Junior's first successful persona conversion (2026-08-03) showed the LLM-extracted deal data dying
> on the converted Lead: the Opportunity arrived nearly empty, the broker was invisible on the deal,
> and neither highlight panel surfaced what mattered. Fix conversion so the 19 deal-screening fields
> the Broker-Protection extraction pipeline already writes onto the Lead actually reach the deal.

(`agent-output/design-requirements-conversion-enrichment.md` §0, trigger paragraph — this document is
additive to, and does not re-open, the S1–S4 scope decisions the design doc fixed at Gate 1.)

### Business Objective

Broker Protection's extraction pipeline has, since 2026-08-01, pulled a rich deal-screening field set
(guidance price/range, NOI, occupancy, square footage, lot size, WALT, ADR, zoning, seller entity, sale
process, offer due date, listing broker, parse confidence — 19 fields in all) out of a forwarded broker
email and onto the Lead. None of it survived conversion. An analyst who converted a well-extracted Lead
got a blank Opportunity, an unnamed deal, and no visible broker — the exact moment the pipeline's work
should pay off is the moment it was thrown away. Conversion Enrichment closes that gap: it teaches
`LeadConvertService` — the one class that already runs at conversion — to carry the right half of that
field set onto the Opportunity, the other half onto the `Property__c`, to put the submitting broker on
the deal as a real `OpportunityContactRole`, and to surface the result on both objects' highlight
panels, Property Address first.

### Summary

Four scope decisions (S1–S4), fixed at Gate 1 and inventoried in full in
`agent-output/design-requirements-conversion-enrichment.md`: **S1** splits the 19 Lead fields by
meaning — deal-process facts to the Opportunity, physical property facts to the `Property__c`. **S2**
creates a primary `Broker` `OpportunityContactRole` for the converted Contact. **S3** rebuilds both
highlight panels (`Lead_Highlights`, `Deal_Highlights`) with Property Address first. **S4** teaches the
extraction prompt to infer `broker_company` from the broker's email domain when no company is stated in
the body — with a blocklist that a post-design hardening pass had to widen before it shipped, because
the version in the design doc would have quietly created a "Comcast" brokerage the first time a broker
used a personal ISP mailbox. All of it lands in `LeadConvertService` (extended) and one new selector,
`OpportunityContactRoleSelector` — the first `OpportunityContactRole` code of any kind in the
application. Two Gate-1-approved add-ons rode along: naming the Opportunity after the property instead
of the broker's firm (D-f), and stamping the cap-rate twin of the price field that S1 already fixed
(F1). The deploy itself surfaced a genuine conflict with an unrelated, still-uncommitted feature sharing
the same FlexiPage and permission set, which is why two components shipped later than the rest.

---

## 🚨 The Driver

The trigger was not a hypothetical — it was Junior's own first end-to-end persona run. A forwarded
broker email went through the pipeline, the LLM extraction worked, all 19 fields landed correctly on
the Lead, and the Lead converted cleanly. Then the deal itself showed almost nothing: no price, no
cap rate, no property facts, no visible broker, and a name reading `Unknown - Via Email` — the
placeholder `EmailToLeadService` stamps onto `Lead.Company` whenever the extraction pipeline could not
identify a firm. The extraction pipeline had done its job perfectly; conversion had simply never been
taught to look at the fields it produced. `LeadConvertService` predates the 19-field deal-screening set
by weeks — it already creates the `Property__c` and stamps a handful of structural fields (Deal Type,
record type, the seller's guidance price/cap rate, Placer/CoStar links), but it had no knowledge of the
newer Lead fields at all. Conversion Enrichment is the fix: not new extraction, not a new pipeline —
just teaching the one class that already runs at conversion to carry forward what the pipeline had
already produced.

---

## 🧩 S1 — Splitting the Deal-Screening Set by Meaning

The 19 Lead fields split cleanly into two kinds of fact, and S1's rule is to route each kind to the
object it actually describes: **deal-process facts** (the guidance price range, the offer due date, how
the deal is being run, the deal-room link, the listing broker, how much to trust the extraction) go to
the **Opportunity**, because they describe the *transaction*. **Physical property facts** (square
footage, NOI, unit count, occupancy, year built/renovated, lot size, WALT, ADR, zoning, the seller
entity) go to the **`Property__c`**, because they describe the *asset*, and the asset will outlive this
particular deal. Neither object gets the other half — `LeadConvertService`'s own header is explicit that
this split "IS the design, not an oversight."

Where an existing field already meant the same thing, S1 extends it rather than creating a duplicate —
and three of those extension calls carried real consequences worth stating plainly, because a future
reader who only sees the field list would not know they were deliberate:

- **`Opportunity.Asking_Price__c` now gets stamped from `Lead.Guidance_Price__c` for the first time.**
  That field is the aggregation column behind the open-pipeline-value KPI
  (`OpportunitySelector.aggregateOpenPipeline`) and the ordering key of the "biggest deals" list
  (`selectTopByAskingPrice`) — so every email-born deal, which before this change contributed exactly
  **0** to both, will now count. That is correct, but it is a visible jump on the next dashboard
  refresh, not a bug. It was also checked for a second, quieter consequence — whether stamping it would
  change **approval routing** on the Underwriting or LOI approval processes — and it does not:
  `Asking_Price__c` appears in both processes' `approvalPageFields` (it is shown to the approver) but in
  neither process's entry criteria, so approvers now see a real number instead of a blank one, and
  nothing about who gets routed to whom changes.
- **`Property__c.Lot_Size__c` is never touched, on purpose.** That field is documented as square feet,
  entered from the Offering Memorandum. The pipeline only ever produces acres
  (`LLMExtractionParser.acres()` canonicalizes `lot_size_sf` into acres and keeps nothing else), and
  computing SF = acres × 43,560 would derive one number from another — exactly what the extraction
  pipeline's own anti-hallucination rules forbid, and it would silently overwrite an analyst's
  OM-sourced figure with a machine estimate. S1 adds a new field instead, `Lot_Size_Acres__c`, and both
  `LeadConvertService.cls` and its test class pin the guarantee that `Lot_Size__c` stays null.
- **`Property__c.Occupancy_Rate_Market__c` is never overwritten.** That field is the *market* benchmark
  fed by Placer/CoStar; the broker's stated occupancy for the subject asset is a different fact
  entirely, and writing one into the other would corrupt a comparison field. S1 adds a distinct new
  field, `Occupancy_Pct__c`, and the description on both fields now says so explicitly, so nobody merges
  them later.

The other three existing fields extended cleanly with no such caveat — `Square_Footage__c` (documented
as building GLA, an exact match for `Building_SF__c`), `Annual_NOI__c` (the §1 rule-5 periodic-amount
name for NOI), and `Year_Built__c`. Everything else — 9 new Opportunity fields, 8 new `Property__c`
fields — mirrors its Lead source's type, length, precision and scale exactly, which is what lets
`LeadConvertService` skip re-clipping: `InboundEmailFieldUtil` already clipped every value once, at the
email boundary.

One more S1 side effect worth stating: the `Property__c.Name` precedence changed. It used to be the
address, always. It is now `Property_Name__c` → `Property_Address__c` → `Street` → `Company` →
`Lead.Name`, so a named asset like "Orion ParkView" converts under its marketing name instead of
"1400 Royal Lane, Dallas TX." The address is still stored on `Address__c` and still shown on the
Property tab, so nothing becomes unfindable — but existing Properties are not back-filled, so the
Property list view reads differently for new records only.

---

## 🤝 S2 — The Broker Becomes a Real Contact Role

Before this change, the submitting broker was visible on a deal only indirectly, through the
`brokerFirmCard` sidebar reading the Account. S2 makes them a first-class fact on the deal itself: a
primary `OpportunityContactRole` with `Role = 'Broker'`, pointing at the converted Contact.

The interesting part is not the insert — it is that a blind insert would have been wrong. **Standard
Lead conversion already creates an `OpportunityContactRole`** for the converted Contact, `IsPrimary =
true`, `Role` left blank — undocumented platform behavior that `LeadConvertService`'s own header calls
out explicitly. An unconditional insert would therefore leave the deal with two rows for one Contact and
two primaries, which Salesforce does not actually allow, so it would either silently demote the
platform's row or throw. The fix is **read-then-write, always**: a new selector,
`OpportunityContactRoleSelector.selectByOpportunityIds`, reads every role row already on the converted
Opportunities in one query, and `LeadConvertService` either **updates** the row it finds (naming the
role, claiming primary only if it isn't already) or **inserts** one only when none exists. This is
correct whether or not the platform's undocumented behavior holds, so it does not depend on it — and it
is naturally idempotent if the path is ever re-invoked, which the test suite proves directly by calling
`stampConvertedOpportunities` twice over the same converted set and asserting the role count stays at
one.

The role value itself is **describe-guarded**, the same pattern S1 uses for its restricted picklists:
`OpportunityContactRole.Role` is driven by the standard `ContactRole` value set, and `'Broker'` is a new
value in it. If that value were ever missing from a target org, an unguarded write would throw — and
because this runs inside a Lead after-update trigger, that throw would take the *entire conversion* down
with it, not just the broker role. So `stampBrokerContactRoles` checks first whether `'Broker'` is an
active value at all; if it isn't, the method returns immediately — no read, no write — and the rest of
conversion proceeds untouched. The visible symptom of a missing value is a broker with no role on the
Contact Roles list, which is exactly the thing persona UAT checks for.

The last design choice worth recording: the update and the insert are **two separate, partitioned DML
statements**, not one `upsert`. That costs one extra `isEmpty()`-guarded conditional, and in the
ordinary case — conversion always creates the platform's row first — it is free, because the insert list
is normally empty and the whole method spends exactly one statement. The reason to pay that cost at all
is that plain `insert`/`update` on `OpportunityContactRole` are certainly supported (the platform does
both itself during conversion), whereas `upsert` support on this particular standard junction is not
something this codebase has ever exercised. This program has been bitten before by trusting undocumented
platform behavior it never verified — the whole reason S2 needs a read-then-write in the first place is
one such case, the blank-Role row nobody had documented until this feature went looking for it. The
partition removes the one remaining unknown rather than adding a second one on top of the first.

---

## 👁️ S3 — Highlight Panels, Property Address First

Both compact layouts — `Lead_Highlights` and `Deal_Highlights` — were revised from 6 fields to the
10-field maximum, with one user mandate governing both: **Property Address is field #1.**

```xml
<!-- Lead_Highlights -->
Property_Address__c, Guidance_Price__c, Guidance_Cap_Rate__c, NOI__c, Occupancy_Pct__c,
Building_SF__c, Asset_Type__c, Offer_Due_Date__c, BP_Expiry__c, Parse_Confidence__c

<!-- Deal_Highlights (Opportunity) -->
Property_Address__c, Asking_Price__c, Deal_Status__c, Offer_Due_Date__c, Sale_Process__c,
My_Cap_Rate__c, Market_Cap_Rate__c, Listing_Broker_Name__c, Broker_First_Seen__c, Parse_Confidence__c
```

The Lead already had `Property_Address__c` as a real Text field, so its panel needed no new metadata.
The Opportunity did not — a compact layout cannot reference `Property__r.Address__c` across the lookup,
so S3 adds one new Opportunity field to make the mandate reachable: `Property_Address__c`, a **formula**
(`Property__r.Address__c`, `BlankAsBlank`). A formula was chosen over a stamped copy deliberately: it
cannot drift from the Property record that S1 makes the system of record for the address, and it
self-corrects if the address is ever fixed later — the cost is that it reads blank on the rare
Opportunity whose Property insert failed or that was created by hand, which is judged the safer failure
than a snapshot silently diverging from the field that also anchors the claim key.

Both panels also dropped their `Name` slot on the theory that the panel already renders the record's own
name as its title, freeing the slot for the mandated field — and `Deal_Highlights` keeps every
still-relevant analyst-owned field (`My_Cap_Rate__c`, `Market_Cap_Rate__c`, `Broker_First_Seen__c`) even
though they're empty the instant a deal converts, because the Opportunity panel serves the deal's whole
lifecycle, not just the minute after conversion.

One thing S3 does **not** solve on its own: FLS. A compact layout needs no permission of its own — the
fields inside it do — and every one of the 8 new Opportunity fields plus `Property_Address__c` had to be
granted through the sibling permission sets before the panel would actually show anything to a
non-admin persona. See "The Deploy Saga" below for what that surfaced in practice.

---

## 🏢 S4 — Company From the Email Domain, and the Blocklist That Almost Wasn't Enough

S4's job is narrow: when a broker email never states the firm's name anywhere in the body, signature or
subject, infer `broker_company` from the **domain** of `broker_email` instead of leaving
`Lead.Company` at the `'Unknown - Via Email'` placeholder. `kevin.girard@jll.com` gives `"JLL"`; an
unrecognized-but-real brokerage domain like `orion-realty.com` gives `"Orion Realty"` via the
registrable-domain fallback. A stated company always wins over an inferred one, and the rule reads
`broker_email` only — it explicitly may not touch `broker_name`, `property_address` or `sent_datetime`,
the four legacy values the claim engine's first-broker-wins ledger depends on.

**The design's own §6.2 wording was not safe as written, and the gap was caught before it shipped.** The
design listed named webmail providers (gmail, hotmail, outlook, yahoo, icloud, …) and then relied on a
catch-all: "any other consumer mailbox provider … never from a domain that is not a company's own
domain." A code-review pass predicted the hole in that wording, and verification against the shipped
prompt confirmed it: an ISP mailbox domain **is** a real company's own domain under the very sentence
that is supposed to license the inference — `comcast.net` genuinely is Comcast's domain, so the
"use the registrable part of the domain" rule the design relied on for `orion-realty.com` would just as
happily hand back `"Comcast"` for a broker who happened to email from a home Comcast account, and
`"AT&T"` for one on `att.net`. That is not a cosmetic mistake: `broker_company` flows straight into
`Lead.Company`, which `AccountSelector.selectByNames` treats as an Account match key, and
`BrokerFirmController` then aggregates **every** Opportunity on an Account into one firm's
submitted/won/lost counts. A single leaked ISP domain would have pooled every unrelated independent
broker who happens to use that ISP into a fictitious "Comcast" or "AT&T" brokerage — the identical
failure shape D1b's placeholder guard exists to prevent (Smart Lead Conversion, `docs/2026-08-03-smart-lead-conversion.md`), arriving this time by a different route the design hadn't closed.

Three hardening additions closed it, all landing in the enriched prompt block only (`LEGACY_EXTRACTION_RULES` untouched):

1. **The named-ISP list was extended** with the domains a catch-all sentence alone had missed:
   `comcast.net`, `verizon.net`, `att.net`, `sbcglobal.net`, `bellsouth.net`, `cox.net`, `charter.net`,
   `earthlink.net`, `optonline.net`, `rr.com`, `roadrunner.com`, `windstream.net`, `frontier.com`,
   `aim.com`, `juno.com`, plus `gmx.net` and `yandex.com`.
2. **A "never a firm" rule was added**, stated as its own sentence rather than left to the catch-all:
   *"AN INTERNET-SERVICE-PROVIDER, TELECOM, CABLE, WEBMAIL OR PORTAL DOMAIN IS NEVER THE BROKER'S FIRM,
   even when its name is a real company"* — with the exact counter-examples that would otherwise have
   slipped through: `comcast.net` must not give `"Comcast"`, `att.net` must not give `"AT&T"`,
   `verizon.net` must not give `"Verizon"`, `sbcglobal.net` must not give `"SBC Global"`.
3. **An ambiguity tie-breaker resolves toward EMPTY, but only for the mailbox-provider question.** *"If
   you cannot tell whether a domain is a business's own domain or a mailbox provider, treat it as a
   mailbox provider and leave broker_company EMPTY."* This is deliberately scoped narrowly: it decides
   what to do when a domain *might* be a personal mailbox, not whether an unrecognized-but-genuine
   brokerage domain should be trusted at all. `orion-realty.com` → `"Orion Realty"` is the entire point
   of S4 and had to keep working — the tie-breaker only fires on the ISP-shaped ambiguity, never on an
   ordinary small-firm domain nobody happens to recognize.

**The D1b coupling this creates is real and intended, not a side effect to be surprised by later.**
Because a domain-derived company is a non-blank, non-placeholder `Lead.Company`, it is now
Account-matchable through the exact same path Smart Lead Conversion already built:
`LeadConvertMatchService.collectMatchKeys` excludes only the literal `COMPANY_PLACEHOLDER` string, so
`"JLL"` sails straight through to `AccountSelector.selectByNames`. Two different brokers at the same
firm — two different emails, so no Contact match — will each match the same `JLL` Account by name and
converge onto it; whichever converts first mints the canonical Account, and D2's `CreatedDate ASC, Id
ASC` ordering means a later duplicate can never displace it. This is the "company half" of Smart Lead
Conversion's original request finally becoming reachable: before S4, almost every email-born Lead
carried the placeholder and could never account-match at all. No downstream code changed to make this
work — `EmailToLeadService.buildLead`, `LeadConvertMatchService.collectMatchKeys` and
`AccountSelector.selectByNames` were traced end to end and confirmed unchanged.

---

## 🏷️ Two Gate-1-Approved Add-Ons

Two small, contained changes rode along with S1–S4, both flagged as user decisions in the design doc and
both approved:

- **D-f — name the Opportunity after the property, not the broker's firm.** Left alone, the platform
  derives `Opportunity.Name` from `Lead.Company` — before S4 that was always `'Unknown - Via Email'`;
  after S4 it would be the broker's firm, e.g. `"JLL"`. That is a regression hiding inside an
  improvement: today's `Unknown - Via Email` name is obviously broken and gets noticed, but
  `N` deals from the same firm all sharing the name `"JLL"` is *plausible-looking* and therefore harder
  to catch. `LeadConvertService.applyDealFields` now sets `o.Name` from `Property_Name__c` →
  `Property_Address__c`, clipped to 120, and leaves the platform-derived name alone when the Lead
  carries neither — `Opportunity.Name` is required, so writing null there would fail the whole update.
- **F1 — stamp the cap-rate twin of the price field S1 already fixed.** `Opportunity.Guidance_Cap_Rate__c`
  existed and was never populated; S1's own field list stamped its price counterpart
  (`Asking_Price__c`) without it, which would have left every converted deal showing a price with no
  cap rate — an asymmetric pair that reads as a defect on sight. One line, `o.Guidance_Cap_Rate__c =
  l.Guidance_Cap_Rate__c`, closes it.

Both are visible in `LeadConvertService.applyDealFields` with inline comments crediting the 2026-08-03
Gate-1 approval, and both are pinned by `LeadConvertServiceTest` (`opportunityNameFromPropertyName`,
and the cap-rate assertion inside `stampsDealProcessFieldsOntoOpportunity`).

---

## 🚀 The Deploy Saga

The deploy went out in two stages — metadata first (`0Afiw000000DimPCAS`), then Apex
(`0Afiw000000DipdCAC`) — which was always the plan, not a recovery: the design doc's own routing
section says the dependency is hard, because Apex referencing `Opportunity.Sale_Process__c` or
`OpportunityContactRole.Role = 'Broker'` will not compile, or will throw at runtime, until the fields
and the picklist value actually exist in the org. What made the split matter in practice, and what is
worth a future reader knowing, are three things the deploy surfaced along the way:

**A repo-only, unrelated feature was already sitting on the exact file this bundle needed to touch.**
`force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml` already carried
uncommitted, undeployed local edits for a different, independently-tracked feature — the Opportunity
stage-advance quick-action confirmation dialogs and permission-visibility work described in
`ARCHITECTURE.md` §5 (`advanceDealStage`, `dealSendToDevelopmentReview`,
`dealSendToConstructionReview`, and their controllers). Conversion Enrichment's own FlexiPage work —
adding the 8 new/extended `Property__r.*` fields to the Property tab's "Details" section and the
standard Contact Roles related list to the Related tab — would have had to deploy on top of that
unfinished, unrelated change, entangling two features that had no business shipping together. The
`DPEG_Acquisitions` permission set turned out to have the identical problem for a more specific reason:
it grants `classAccess` to `StageAdvanceController` and `OpportunityApprovalController` — the very
controllers mid-flight in that same uncommitted feature — so deploying that permission set file would
also have carried those class-access grants along, tying this bundle's field-level FLS work to a feature
it has nothing to do with. Both were pulled out of this deploy and tracked separately rather than
deployed; see "What Was Deferred" below. The other three permission sets this bundle needed
(`DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Opportunity_View`) carry no such class-access
entries and deployed cleanly with the new field grants.

**FLS verification found exactly the gap the design doc warned it would.** `LeadConvertService`'s DML
runs in system mode, so the stamp itself never depended on FLS — but the design's own §3.5/§9.4 called
out, in advance, that verifying as an admin would prove nothing (a System Administrator has no FLS on
Metadata-API-deployed custom fields in this org, per `ARCHITECTURE.md` §2) and that the only real check
is a convert-capable persona. Running that check found the persona initially assigned only the
permission set the design doc explicitly listed as **excluded** from this bundle's FLS grants
(`Broker_Protection_Access`, which carries Lead fields only, by design), and not one of the sibling sets
that actually received the new grants (`DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`,
`DPEG_Opportunity_View`). The fix was a permission-set **assignment**, not a metadata change — adding
the correct sibling permission set to the verifying persona — which is the same class of gotcha this
program has hit before in RBAC work: the fields, the FLS grants and the deploy were all correct, and the
only thing missing was which permission sets were actually assigned to the user doing the check.

**`TestDataFactory` restarts its Contact numbering on every call, and this bundle's own tests tripped
it.** `TestDataFactory.createContacts` names every Contact `'Test Contact ' + i`, where `i` is a
per-call loop index starting at 0 — not the class-level unique counter used elsewhere in the factory —
so two separate single-Contact seeds in one test method both produce `'Test Contact 0'`. Combined with
the standard Account duplicate rule's fuzzy matching (every factory Account shares
`BillingCity='Houston'`/`BillingState='TX'`, the same trap Smart Lead Conversion's own tests hit),
`OpportunityContactRoleSelectorTest.selectByOpportunityIds_scopesToTheRequestedOpportunities` — which
calls its `seedRole` helper twice in one transaction — failed with `DUPLICATES_DETECTED` the first time
it ran. It was fixed the same way Smart Lead Conversion fixed the identical trap: routing every
Account/Contact seed in the test class through `TestDataFactory.insertAllowingDuplicates`, which
suppresses the duplicate *alert* only (`optAllOrNone` stays `true`, so a genuine failure still throws).
This is pre-existing factory behavior, not something this bundle introduced — it is simply the second
feature in a row to be caught by it, which is worth knowing if a third one is.

---

## ✅ UAT Script

Because the S4 prompt change is not meaningfully unit-testable beyond the fixture byte-pin and a length
check, verification for this whole bundle is manual, live, on `usman-dpeg`. All conversions below use a
**freshly forwarded email** (a new Message-ID — redelivering an old one hits the idempotency guard) and
must be run **as the Junior Analyst persona, never as an admin**, per the FLS note above.

**Core conversion check (S1 + S2 + S3):**

1. As Junior, send a forwarded broker email from a **corporate domain** broker (e.g. `@jll.com`) whose
   body states no company, carrying a full deal-screening payload (price, NOI, occupancy, SF, dates,
   etc.).
2. Let it route through the pipeline to a Lead; convert it.
3. On the **Opportunity**: confirm the Detail tab shows all 8 stamped deal-process fields with real
   values, `Asking_Price__c` is populated, `Guidance_Cap_Rate__c` is populated (F1), and the Opportunity
   **Name** reads the property's name or address, not `"JLL"` or `Unknown - Via Email"` (D-f).
4. On the **Property tab**: confirm the newly-stamped `Property__r.*` fields (Square Footage, NOI, Year
   Built, plus the new fields once the layout placement lands) show real values.
5. On the **Contact Roles related list**: confirm the converted Contact appears with **Role = Broker,
   Primary = checked** — not a second, blank-role row alongside it.
6. On **both highlight panels** (Lead, if re-checked pre-conversion; Opportunity, post-conversion):
   confirm **Property Address is the first field shown**, and every other slot renders a value rather
   than blank (a blank slot for this persona means a missing FLS grant, not a failed stamp — query the
   record directly to tell the two apart).

**S4-specific checks, four emails, each freshly forwarded:**

| Case | Email | Pass condition |
|---|---|---|
| **A — corporate domain, no company stated** | Broker at a real brokerage domain (e.g. `@jll.com`), body names no firm | `Extracted_JSON__c.broker_company` = `"JLL"`; `Lead.Company` = `"JLL"`; conversion creates-or-attaches a `JLL` Account |
| **B — free-mail / ISP domain, no company stated** | The original incident address (`usmankhan-96@hotmail.com`) or any ISP address (e.g. a `comcast.net` sender), body names no firm | `broker_company` = `""`; `Lead.Company` = `'Unknown - Via Email'`; conversion does **not** account-match |
| **C — company IS stated (regression)** | Any email whose signature names the firm | The **stated** company comes back verbatim — inference must never override a stated value |
| **D — same-firm convergence** | Two Leads, two different brokers at the same domain (e.g. two different `@jll.com` senders) | Both Opportunities land on the **same** `JLL` Account (oldest wins); two distinct Contacts, not one shared one |

On every case, also re-check that `property_address` still normalizes to the same `Property_Key__c` as
before this change — a claim-key drift on this feature would mean rolling back the prompt paragraph
(a one-class revert, independent of everything else in this bundle).

---

## 🏗️ Components Created / Modified

### Custom Fields — new (17)

| Object | Field | Type | Notes |
|---|---|---|---|
| Opportunity | `Guidance_Price_Low__c` | Currency(18,2) | |
| Opportunity | `Guidance_Price_High__c` | Currency(18,2) | |
| Opportunity | `Offer_Due_Date__c` | Date | |
| Opportunity | `Sale_Process__c` | Picklist, restricted, 4 values | byte-identical to `Lead.Sale_Process__c` |
| Opportunity | `Parse_Confidence__c` | Picklist, restricted, HIGH/MEDIUM/LOW | mirrors `Lead.Parse_Confidence__c` |
| Opportunity | `Deal_Room_Link__c` | Url | |
| Opportunity | `Listing_Broker_Name__c` | Text(120) | |
| Opportunity | `Listing_Broker_Email__c` | Email | |
| Opportunity | `Property_Address__c` | Formula (Text) = `Property__r.Address__c` | S3 enabler; read-only; FLS `readable` only |
| Property__c | `Unit_Count__c` | Number(18,0) | |
| Property__c | `Occupancy_Pct__c` | Percent(5,2) | distinct from `Occupancy_Rate_Market__c` |
| Property__c | `Year_Renovated__c` | Number(4,0) | |
| Property__c | `Lot_Size_Acres__c` | Number(10,2) | never used to derive `Lot_Size__c` |
| Property__c | `WALT_Years__c` | Number(4,1) | |
| Property__c | `ADR__c` | Currency(10,2) | |
| Property__c | `Zoning__c` | Text(100) | |
| Property__c | `Seller_Entity__c` | Text(255) | deliberately Text, not a lookup |

### Existing fields newly stamped (4)

`Opportunity.Asking_Price__c` (← `Lead.Guidance_Price__c`), `Property__c.Square_Footage__c` (←
`Building_SF__c`), `Property__c.Annual_NOI__c` (← `NOI__c`), `Property__c.Year_Built__c` (←
`Year_Built__c`). Plus `Opportunity.Guidance_Cap_Rate__c` (F1) and the `Property__c.Name` /
`Opportunity.Name` precedence changes (S1 / D-f) — not new fields, but newly-driven values.

### StandardValueSet

`ContactRole` → added value `Broker` (label "Broker", additive only).

### Compact Layouts — revised (2)

`Lead_Highlights` (6 → 10 fields), `Deal_Highlights` on Opportunity (6 → 10 fields). Both object-level
assignments; both now lead with `Property_Address__c`.

### Page Layouts — updated (2)

`Opportunity-Opportunity Layout` (the 8 stamped Opportunity fields + `Property_Address__c`, read-only),
`Property__c-Property Layout` (the 8 new `Property__c` fields).

### Apex Classes — new (1)

| Class | Layer | Responsibility |
|---|---|---|
| `OpportunityContactRoleSelector` | Selector, `with sharing` | The first `OpportunityContactRole` SOQL — and the first `OpportunityContactRole` handling of any kind — in the application. `selectByOpportunityIds(Set<Id>)`, `WITH USER_MODE`, null/empty short-circuit. |

### Apex Classes — modified (2)

| Class | Change |
|---|---|
| `LeadConvertService` | Extended `buildProperty` (S1 physical facts), added `applyDealFields` (S1 deal-process facts + D-f naming + F1), added `stampBrokerContactRoles` (S2, read-then-write), generalized the picklist guard to `activePicklistValues(Schema.SObjectField)`. Bulk contract: 2 SOQL / 3 DML (≤4) per invocation, unchanged in shape from before this feature, now carrying more work per statement. |
| `LLMExtractionCalloutService` | One new paragraph in `ENRICHED_EXTRACTION_RULES` only (S4 + the hardened blocklist). `LEGACY_EXTRACTION_RULES`/`LEGACY_RESPONSE_FORMAT` untouched — the one-line rollback still holds. |

### Test Classes — extended / new (2)

| Class | Change |
|---|---|
| `LeadConvertServiceTest` | Extended from 7 to a full S1–S2 + D-f/F1 suite: the deal-process/physical-facts split, the two no-touch guarantees (`Lot_Size__c`, `Occupancy_Rate_Market__c`), the range-price null guarantee, the Property/Opportunity naming precedence, the restricted-picklist drop-not-throw guard, the OCR read-then-write (one row, idempotent), null-safety for a thin email, and the 251-Lead bulk/governor-headroom proof (now also asserting 251 role rows and bounded query/DML growth). |
| `OpportunityContactRoleSelectorTest` | New — field shape, the blank-Role row (the realistic production shape), Opportunity scoping, multi-role-per-Opportunity, no-match, null/empty short-circuit, and an independent 251-row bulk proof. |

### Permission Sets — updated (3 of 4 planned)

| Permission Set | Grant | Status |
|---|---|---|
| `DPEG_Acquisition_Edit` | 9 Opportunity + 8 Property__c fields, editable (formula field read-only) | ✅ Deployed |
| `DPEG_Acquisition_View` | Same fields, read-only | ✅ Deployed |
| `DPEG_Opportunity_View` | 9 Opportunity fields, read-only | ✅ Deployed |
| `DPEG_Acquisitions` | 9 Opportunity + 8 Property__c fields | ⏸ **Deferred** — entangled with the in-flight deal-actions feature's `classAccess` grants (see Deploy Saga); repo file already carries the field entries, not yet deployed |

`Broker_Protection_Access` was deliberately **not** touched — it carries Lead-field grants only, by
design.

---

## 🔄 Data Flow

```
Lead (all 19 deal-screening fields populated by the extraction pipeline)
        │
        │  IsConverted false -> true  (LeadConvertTrigger -> LeadConvertTriggerHandler)
        ▼
LeadConvertService.stampConvertedOpportunities
        │
        ├─► createProperties            [DML 1 — Database.insert(properties, false)]
        │     buildProperty: NAME precedence (Property_Name__c -> Address -> Street ->
        │     Company -> Lead.Name); physical facts (S1) copied onto the new Property__c;
        │     Lot_Size__c and Occupancy_Rate_Market__c are NEVER written here.
        │
        ├─► buildOpportunityUpdates     [SOQL 1 — RecordTypeSelector]
        │     applyDealFields: deal-process facts (S1) + Asking_Price__c + Guidance_Cap_Rate__c
        │     (F1) + restricted-picklist guard (Sale_Process__c, Parse_Confidence__c) +
        │     Opportunity.Name from the property (D-f)
        │     update updates             [DML 2 — all-or-none]
        │
        └─► stampBrokerContactRoles     [SOQL 2 — OpportunityContactRoleSelector]
              describe-guard on 'Broker' -> skip entirely if absent
              partition existing vs. new role rows
              Database.update(roleUpdates, false)   [DML 3]
              Database.insert(roleInserts, false)   [DML 4, ordinary case: empty]

Opportunity / Property__c, now fully stamped
        │
        ▼
Lead_Highlights / Deal_Highlights compact layouts render Property Address first (S3)
Contact Roles related list shows the broker as Broker / Primary (S2, once the FlexiPage lands)
```

---

## 📁 File Locations

| Component Type | Path |
|---|---|
| New Apex | `force-app/main/default/classes/OpportunityContactRoleSelector.cls` |
| New test | `force-app/main/default/classes/OpportunityContactRoleSelectorTest.cls` |
| Modified Apex | `force-app/main/default/classes/{LeadConvertService,LLMExtractionCalloutService}.cls` |
| Extended test | `force-app/main/default/classes/LeadConvertServiceTest.cls` |
| New Opportunity fields | `force-app/main/default/objects/Opportunity/fields/` |
| New Property__c fields | `force-app/main/default/objects/Property__c/fields/` |
| StandardValueSet | `force-app/main/default/standardValueSets/ContactRole.standardValueSet-meta.xml` |
| Compact layouts | `force-app/main/default/objects/{Lead,Opportunity}/compactLayouts/{Lead_Highlights,Deal_Highlights}.compactLayout-meta.xml` |
| Page layouts | `force-app/main/default/layouts/{Opportunity-Opportunity Layout,Property__c-Property Layout}.layout-meta.xml` |
| Permission sets | `force-app/main/default/permissionsets/{DPEG_Acquisition_Edit,DPEG_Acquisition_View,DPEG_Opportunity_View,DPEG_Acquisitions}.permissionset-meta.xml` |
| Deferred (repo-only) | `force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml` |
| Design doc | `agent-output/design-requirements-conversion-enrichment.md` |
| Architecture reference | `ARCHITECTURE.md` §2 — `LeadConvertService` row extended, `OpportunityContactRoleSelector` recorded alongside `AccountSelector` |

---

## 🧪 Testing

### Test volume

213/213 tests passing on the second (Apex) deploy stage. New/extended coverage for this bundle:
`OpportunityContactRoleSelectorTest` (7 methods, new) and `LeadConvertServiceTest` (extended from 7
pre-existing methods to cover the full S1/S2/D-f/F1 surface, including the 251-Lead bulk test now also
asserting 251 broker-role rows and bounded governor-limit growth).

### Bulk-Test-Rule application

`LeadConvertService.stampConvertedOpportunities` is trigger-driven, so the 251-record mandate applies in
full — no exemption. The existing 251-Lead bulk test
(`bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities`) already drove 251 conversions across
two `convertLead` chunks (so the service fires twice in one transaction); it was extended to assert 251
Properties, 251 stamped Opportunities, and **251 distinct broker-role rows, not 502** — the sharp proof
that the OCR read-then-write is per-invocation, not per-record. `OpportunityContactRoleSelectorTest`
carries its own independent 251-row bulk proof, asserting the read costs exactly one query regardless of
how many Opportunities are asked about.

### What is deliberately NOT tested

`LeadConvertServiceTest`'s own header states this explicitly: **no `System.runAs` FLS test exists.**
`LeadConvertService`'s DML runs in system mode and `Trigger.new` is not FLS-filtered, so a `runAs` test
asserting "the stamp lands as a non-admin persona" would pass whether or not the FLS grant exists — a
test that cannot fail. FLS on these fields is a display gate, not a write gate, and is verified manually,
as a real persona — see the UAT Script above. Similarly, `stampBrokerContactRoles`'s describe-guard skip
path (the early return when `'Broker'` is absent from the org) is confirmed dead-in-test: the picklist
check reads the live org describe, which is identical in every test context to whatever is actually
deployed, so there is no seam to force the value absent.

---

## 🔒 Security

- `LeadConvertService` and `OpportunityContactRoleSelector` are `with sharing`, per `ARCHITECTURE.md`
  §2. `OpportunityContactRoleSelector.selectByOpportunityIds` runs `WITH USER_MODE` — this is an
  interactive, user-initiated read (the running user just converted a Lead), not the guest/automation
  path that earns `SYSTEM_MODE` elsewhere in Broker Protection.
- `LeadConvertService`'s DML is plain `insert`/`update`, which runs in **system mode**: a missing FLS
  grant on any of the 17 new fields does **not** block the stamp — the data lands regardless. FLS is
  required only so a persona can **see** the values afterward; without it, the highlight panel and the
  Detail/Property tabs render blank for that field, silently. This is the single most important thing
  to know before treating a blank field as a failed stamp — query the record directly to tell the two
  apart.
- Every restricted-picklist write (`Sale_Process__c`, `Parse_Confidence__c`, `Asset_Type__c`, and now
  `OpportunityContactRole.Role`) is describe-guarded via `activePicklistValues`. `update updates` stays
  all-or-none on purpose — the structural fields (`RecordTypeId`, the `Property__c` link,
  `Lead_Approved_By__c`) must land or the conversion is broken — so the guard exists precisely to keep
  that all-or-none guarantee affordable: one illegal picklist value can no longer roll back every other
  Lead's stamp in the same chunk.
- The S4 prompt paragraph is the first prompt change in this module whose output feeds an **attachment
  decision** rather than a display value — `broker_company` now participates in which Account a deal is
  matched to. The hardened blocklist (see S4 above) is the control that keeps that widening from
  producing a wrong answer; a slightly-off inferred firm name still only ever produces a *recoverable*
  failure (a second Account a human can merge), never a wrong one.

---

## 📝 Notes & Considerations

### What Was Deferred

Two components from the original 11-line component inventory did not ship in this deploy, both for the
same underlying reason — entanglement with an unrelated, still-uncommitted feature (the Opportunity
stage-advance quick-action confirmation dialogs, `ARCHITECTURE.md` §5):

| # | Item | Status |
|---|---|---|
| 1 | `Opportunity_Record_Page.flexipage-meta.xml` — the Property tab's 8 new/extended field additions, and the standard Contact Roles related list on the Related tab | **Deferred**, tracked as a follow-up. Until it lands, the new Property fields and the S2 broker role are reachable only via the Detail/Property-Layout-driven surfaces and direct record queries, not via the record page's own tabs. |
| 2 | `DPEG_Acquisitions` permission set — the 9 Opportunity + 8 Property__c field grants | **Deferred**, tracked as a follow-up. The repo file already carries the correct field entries; it was not deployed because the same file also carries `classAccess` grants to the two controllers mid-flight in the unrelated deal-actions feature. Personas relying solely on `DPEG_Acquisitions` (rather than `DPEG_Acquisition_Edit`/`View`) will not see the new fields until this follow-up ships. |

### KPI-Shift Note for Report Readers

Anyone consuming the open-pipeline-value KPI or the "biggest deals" list should expect both to **jump**
on the next refresh after this deploy, because `Opportunity.Asking_Price__c` is now populated for
email-born deals for the first time (see S1 above). This is the fix working as intended, not a data
error — every email-born deal was contributing exactly 0 before this change. Two related shapes to
expect: a **range-priced** deal (guidance given as low/high rather than a single number) still
contributes 0, deliberately — the extraction rule fills the range and leaves the single price null, and
`LeadConvertService` refuses to synthesize a midpoint, because that would fabricate a number the email
never stated. And **existing** Properties/Opportunities are not back-filled by this change at all — only
newly-converted deals from this point forward carry the enriched data.

### Known Limitations

- **`Property__c.Lot_Size__c` still does not name its unit** (it is square feet, per its own
  description) and now sits beside `Lot_Size_Acres__c`, which does. Relabelling it is a one-line
  `<label>` change but touches a field with stored, OM-entered data — out of scope for this bundle.
- **`brokerFirmCard` still names "the broker" as the earliest-created Contact on the Account**, not
  through the new `OpportunityContactRole`. After S2, every conversion-born deal has an authoritative
  broker; after Smart Lead Conversion, one Contact can front many deals, so "earliest Contact on the
  Account" is now more likely than before to name the wrong person. A real accuracy improvement S2
  unlocks, deliberately not built here.
- **`'Unknown - Via Email'` Accounts already in the org are not renamed** by S4 — it reduces how many
  more get created, but does not clean up the existing per-broker stubs (already filed as a follow-up in
  Smart Lead Conversion's own documentation).

### Dependencies

- `OpportunityContactRoleSelector` depends on nothing new; `LeadConvertService` is its sole consumer.
- S4's `broker_company` inference depends on `EmailToLeadService.COMPANY_PLACEHOLDER` staying the exact
  literal `LeadConvertMatchService.collectMatchKeys` excludes — unchanged by this bundle, but load-bearing
  to why an inferred company can account-match while the placeholder still cannot.
- The S3 highlight-panel mandate and the S1 Property-tab placement both depend on the deferred FlexiPage
  work landing before either is fully visible to end users.

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-03 | Documentation Agent | Initial creation — documents Conversion Enrichment (S1 deal-process/physical-facts split, S2 broker Contact Role, S3 highlight panels, S4 company-from-domain with the hardened blocklist), the D-f/F1 Gate-1 add-ons, the two-stage deploy and what it surfaced (the repo-only deal-actions entanglement, the FLS-assignment gap, the `TestDataFactory` LastName-restart trap), the UAT script, and the two deferred components (FlexiPage placement, `DPEG_Acquisitions`). `ARCHITECTURE.md` §2 was already updated for this feature in the same change by the developer agent; not re-edited here. |
