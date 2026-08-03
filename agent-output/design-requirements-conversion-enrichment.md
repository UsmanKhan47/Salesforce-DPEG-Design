# Design — Broker Protection: CONVERSION ENRICHMENT bundle (S1–S4)

**Date:** 2026-08-03
**Trigger:** Junior's first successful persona conversion (2026-08-03) — the LLM-extracted deal data dies on the converted Lead. The Opportunity arrives nearly empty, the broker is invisible on it, and neither highlight panel surfaces what matters.
**Scope inputs:** S1–S4 are **user-approved and FIXED**. This document does not re-open them; it inventories, names, sequences, and states the consequences.
**Supersedes nothing.** Additive to `agent-output/design-requirements.md` (C-1..C-22), `…-lead-convert-matching.md` (D1–D5), `…-prompt-tuning.md` (D1–D4).
**Read alongside:** `ARCHITECTURE.md` §1 (naming, incl. rule 9) + §2 (layering, Key Apex Services), `docs/2026-08-03-smart-lead-conversion.md`.

---

## 0. WHAT WAS REQUESTED

| # | Scope decision (FIXED) |
|---|---|
| **S1** | On conversion, **deal-process** fields map to the **Opportunity**; **physical property facts** map to the **`Property__c`** the conversion already creates. Mechanism = `LeadConvertService` (the established post-convert stamping site), **not** the declarative Lead field map. |
| **S2** | Conversion creates an **`OpportunityContactRole`** (role `Broker`, primary) for the converted/matched Contact. Broker name/email/phone visible on the Opportunity page via that Contact. The existing Brokerage Firm card keeps working. |
| **S3** | Revise the **Lead** and **Opportunity** highlight panels (compact layouts). **First field = Property Address** (user-mandated), then the most decision-relevant email-derived fields. |
| **S4** | The extraction prompt gains an **ENRICHED-block** rule: infer `broker_company` from the broker email's **domain** when the body states no company; **never** from a free-mail domain. Downstream, the real company name flows through the existing Smart-Conversion Account matching with **no code change**. |

---

## 1. INVENTORY — what already exists (verified against the filesystem, 2026-08-03)

### 1.1 The 19 Lead deal-screening fields (added 2026-08-01) + the 5 pre-existing ones they sit with

| Lead field | Type | Stamped by |
|---|---|---|
| `Property_Name__c` | Text(255) | `EmailToLeadService.applyPropertyBlock` |
| `Sale_Process__c` | Picklist **restricted** — Off-Market / On-Market Listing / Call for Offers / Auction | ″ |
| `Guidance_Price_Low__c` | Currency(18,2) | ″ |
| `Guidance_Price_High__c` | Currency(18,2) | ″ |
| `NOI__c` | Currency(18,2) | ″ |
| `ADR__c` | Currency(10,2) | ″ |
| `Occupancy_Pct__c` | Percent(5,2) | ″ |
| `Building_SF__c` | Number(18,0) | ″ |
| `Unit_Count__c` | Number(18,0) | ″ |
| `Lot_Size_Acres__c` | Number(10,2) | ″ |
| `Year_Built__c` | Number(4,0) | ″ |
| `Year_Renovated__c` | Number(4,0) | ″ |
| `WALT_Years__c` | Number(4,1) | ″ |
| `Zoning__c` | Text(100) | ″ |
| `Seller_Entity__c` | Text(255) | ″ |
| `Deal_Room_Link__c` | Url | ″ |
| `Offer_Due_Date__c` | Date | ″ |
| `Listing_Broker_Name__c` | Text(120) | `applyBrokerBlock` |
| `Listing_Broker_Email__c` | Email | `applyBrokerBlock` |
| *(pre-existing)* `Property_Address__c` | Text(255) | pipeline |
| *(pre-existing)* `Guidance_Price__c` | Currency(18,2) | pipeline |
| *(pre-existing)* `Guidance_Cap_Rate__c` | Percent(5,2) | pipeline |
| *(pre-existing)* `Parse_Confidence__c` | Picklist HIGH/MEDIUM/LOW | `ExtractAddressQueueable` |
| *(pre-existing)* `Asset_Type__c`, `Deal_Type__c` | Picklist | pipeline |

> **There is no `Lot_Size_SF__c` on Lead.** `LLMExtractionParser.acres()` canonicalizes `lot_size_sf` → acres (÷ 43,560) and stores acres only. Conversion therefore has **acres and nothing else** to carry. See D-a note 4.

### 1.2 What `LeadConvertService` stamps TODAY

`stampConvertedOpportunities` (after-update on Lead, via `LeadConvertTrigger` → `LeadConvertTriggerHandler`):

- **Opportunity:** `Lead_Approved_By__c` = running user, `Property__c` = new Property, `Deal_Type__c`, `RecordTypeId` (Land/Commercial via `RecordTypeSelector`).
- **`Property__c` (`buildProperty`):** `Name` (= address ?: Company ?: Lead.Name, clipped 80), `Address__c`, `City__c`, `State__c`, `Zip__c`, `Asking_Price__c` ← `Guidance_Price__c`, `Cap_Rate_Asking__c` ← `Guidance_Cap_Rate__c`, `Placer_URL__c`, `CoStar_URL__c`, `Asset_Type__c` (**guarded** by a describe of the restricted picklist).
- **Shape:** 1 SOQL, 1 `Database.insert(properties, false)`, 1 `update updates`. Constant regardless of batch size.

**Nothing else is carried.** All 19 new Lead fields die at conversion. That is the defect.

### 1.3 Existing counterparts — what to EXTEND rather than duplicate

| Requested target | Existing field | Verdict |
|---|---|---|
| Opportunity ← guidance price (single) | **`Opportunity.Asking_Price__c`** Currency(18,2) | **EXTEND — stamp it.** ⚠ live-KPI impact, see D-a note 1 |
| Opportunity ← guidance cap rate | `Opportunity.Guidance_Cap_Rate__c` Percent(5,2) — **exists, never populated** | **Out of S1's list.** Flagged in §8 as a user decision, not built. |
| Property ← building SF | **`Property__c.Square_Footage__c`** Number(18,0) — description: *"Total building Gross Leasable Area (GLA) in square feet"* | **EXTEND — exact semantic match.** |
| Property ← NOI | **`Property__c.Annual_NOI__c`** Currency(18,2) | **EXTEND — §1 rule 5 "periodic amount" name; exact match.** |
| Property ← year built | **`Property__c.Year_Built__c`** Number(4,0) | **EXTEND.** |
| Property ← occupancy % | `Property__c.Occupancy_Rate_Market__c` Percent(5,2) | **DO NOT REUSE.** That is the *market* benchmark (Placer/CoStar lineage), not the subject asset's stated occupancy. Writing the broker's figure into it would corrupt a comparison field. → new field. |
| Property ← lot size | `Property__c.Lot_Size__c` Number(18,0) — description: *"Total lot or parcel size in **square feet**. Entered from the Offering Memorandum."* | **DO NOT WRITE.** We hold acres only; deriving SF = acres × 43,560 is exactly the derivation the module's own anti-hallucination rules forbid. → new `Lot_Size_Acres__c`. |
| Property ← property name | `Property__c.Name` (standard) | **EXTEND the name precedence** — no new field. A separate `Property_Name__c` on `Property__c` would duplicate the standard Name and trip §1 rule 9's "a label for something that also exists as a record" intent. |
| `Opportunity.Acres__c` Number(16,2) | exists (Land deal sizing) | Left alone — analyst-owned, different lineage. |

### 1.4 Compact layouts — current state

| Object | Compact layout | Assigned in | Current fields |
|---|---|---|---|
| Lead | `Lead_Highlights` | `Lead.object-meta.xml:255` | `Guidance_Price__c`, `My_Cap_Rate__c`, `BP_Expiry__c`, `Days_in_System__c`, `Offer_Due_Date__c`, `Asset_Type__c` (6) |
| Opportunity | `Deal_Highlights` | `Opportunity.object-meta.xml:143` | `Name`, `Asking_Price__c`, `My_Cap_Rate__c`, `Market_Cap_Rate__c`, `Deal_Status__c`, `Broker_First_Seen__c` (6) |

Both assignments are **object-level**; neither `Opportunity.Land` nor `Opportunity.Commercial` carries a record-type-level `compactLayoutAssignment`. **One revision per object covers both record types.**

### 1.5 Opportunity record page — where new fields will and will not appear

`flexipages/Opportunity_Record_Page.flexipage-meta.xml` ("Acquisition Deal Page"):

- **Detail tab** = `force:detailPanel` (facet `detailContent`). This is the **standard page-layout-driven panel** — new Opportunity fields appear here **only if added to the Opportunity page layout**. There is no Dynamic-Forms field section to edit for the Detail tab.
- **Property tab** = `flexipage:fieldSection` "Details", two columns, already rendering cross-object `Record.Property__r.*`: col 1 = `Name`, `Address__c`, `Asking_Price__c`; col 2 = `Square_Footage__c`, `State__c`, `Cap_Rate_Asking__c`, plus `Record.Lead_Approved_By__c`. **New `Property__c` fields must be added here explicitly** — a cross-object field section does not auto-expand.
- **Sidebar region** = `brokerFirmCard`, `dealDocStatus`, tabset. `brokerFirmCard` → `BrokerFirmController.getBrokerFirm` reads the **Account** and names the *earliest-created Contact on the Account* as "the broker". S2 does not change it; §8 notes the improvement it now makes possible.
- Layouts on disk: only **`Opportunity-Opportunity Layout`** is DPEG-relevant (the three `(Marketing)/(Sales)/(Support)` layouts are platform boilerplate). ⚠ **Record-type → layout assignment lives in profiles, which are `.forceignore`d** — the admin must confirm in-org which layout each Opportunity record type actually uses before assuming one edit covers both.

### 1.6 `OpportunityContactRole` — the role value does not exist

`standardValueSets/ContactRole.standardValueSet-meta.xml` contains exactly: Business User, Decision Maker, Economic Buyer, Economic Decision Maker, Evaluator, Executive Sponsor, Influencer, Technical Buyer, Other. **There is no `Broker`.** It must be added.

There is **no `OpportunityContactRole` handling anywhere in the codebase today** (`grep`: zero hits outside comments) and **no `OpportunityContactRoleSelector`**.

### 1.7 `broker_company` is an ENRICHED-block value — S4 is safe from the byte-pin

`broker_company` appears **only** in `ENRICHED_EXTRACTION_RULES` (the response-shape schema, `"broker_company": ""`). It is **absent from `LEGACY_EXTRACTION_RULES`** and from `LEGACY_RESPONSE_FORMAT`'s four-key contract.

`ExtractionRegressionFixtureTest` pins `LEGACY_EXTRACTION_RULES` (`startsWith` + four `contains`) and the `LEGACY + LEGACY_RESPONSE_FORMAT` rollback composition, and compares legacy-vs-enriched only on **`brokerEmail`** and the **claim key**. `broker_company` is in neither. **An enriched-block-only rule leaves every existing assertion green.**

---

## 2. D-a — EXACT FIELD INVENTORY

**Governing rule for every new field: it MUST mirror its Lead source's type, length, precision and scale EXACTLY.** That is what makes the stamp unconditionally safe — `InboundEmailFieldUtil` already clipped every value to the Lead field's limit, so an identically-shaped target can never overflow and no re-clipping is needed in `LeadConvertService`. §1 naming rules (incl. rule 9) apply throughout; each new name is the Lead name, which is already §1-conformant.

### 2.1 NEW `Opportunity` fields — 9

| # | API name | Type | Source | Notes |
|---|---|---|---|---|
| 1 | `Guidance_Price_Low__c` | Currency(18,2) | `Lead.Guidance_Price_Low__c` | §1 rule 5: range bound, unit implicit in `Price` |
| 2 | `Guidance_Price_High__c` | Currency(18,2) | `Lead.Guidance_Price_High__c` | |
| 3 | `Offer_Due_Date__c` | Date | `Lead.Offer_Due_Date__c` | §1 rule 6/9: `_Date` on a Date field ✅ |
| 4 | `Sale_Process__c` | Picklist, **`restricted=true`**, values **byte-identical to Lead's**: Off-Market / On-Market Listing / Call for Offers / Auction | `Lead.Sale_Process__c` | §1 rule 7: a marketing-mode picklist, **not** a Status field — name stays `Sale_Process__c` |
| 5 | `Parse_Confidence__c` | Picklist, values HIGH / MEDIUM / LOW (mirror Lead exactly, incl. `restricted` flag) | `Lead.Parse_Confidence__c` | The analyst's "should I trust the rest of this?" signal |
| 6 | `Deal_Room_Link__c` | Url | `Lead.Deal_Room_Link__c` | |
| 7 | `Listing_Broker_Name__c` | Text(120) | `Lead.Listing_Broker_Name__c` | |
| 8 | `Listing_Broker_Email__c` | Email | `Lead.Listing_Broker_Email__c` | |
| 9 | `Property_Address__c` | **Formula (Text)** = `Property__r.Address__c`, `formulaTreatBlanksAs = BlankAsBlank` | derived | **S3 enabler — see D-d note 1.** Not stamped; read-only. |

**EXTENDED (existing, newly stamped): `Opportunity.Asking_Price__c` ← `Lead.Guidance_Price__c`.**

> **Note 1 — ⚠ THIS CHANGES A LIVE DASHBOARD NUMBER.** `Opportunity.Asking_Price__c` is the aggregation column behind `OpportunitySelector.aggregateOpenPipeline` (`SUM(Asking_Price__c)` → open-pipeline value KPI) and the ordering key of `selectTopByAskingPrice` ("biggest deals"). Today it is **never populated at conversion**, so every email-born deal contributes **0** to pipeline value and never appears in the biggest-deals list. Stamping it will make those numbers **jump** on the next dashboard refresh — correctly, but visibly. The alternative (a new `Opportunity.Guidance_Price__c` leaving `Asking_Price__c` untouched) was rejected: it duplicates a field, contradicts the "extend, don't duplicate" instruction, and breaks the equivalence `Property__c.Asking_Price__c ← Guidance_Price__c` that conversion has used since day one. **This must be stated at Gate 1, not discovered on a dashboard.**
>
> **Note 2 — the range case leaves `Asking_Price__c` NULL, deliberately.** The extraction prompt's own rule: *"If a price is quoted as a range, use guidance_price_low and guidance_price_high and leave guidance_price null."* So a range-priced deal stamps low/high and leaves `Asking_Price__c` empty, contributing 0 to the pipeline KPI until an analyst fills it. **We do not synthesize a midpoint** — that would fabricate a price, which is the exact behaviour the whole module forbids. Accepted, stated.
>
> **Note 3 — `Deal_Room_Link__c` on Opportunity vs `OneDrive_Folder_URL__c`.** Different things: `OneDrive_Folder_URL__c` is DPEG's own document folder; `Deal_Room_Link__c` is the broker's data room. No collision.

### 2.2 NEW `Property__c` fields — 8

| # | API name | Type | Source | Notes |
|---|---|---|---|---|
| 1 | `Unit_Count__c` | Number(18,0) | `Lead.Unit_Count__c` | §1 rule 9 `_Count__c` ✅ |
| 2 | `Occupancy_Pct__c` | Percent(5,2) | `Lead.Occupancy_Pct__c` | §1 rule 9 `_Pct__c` ✅. Deliberately distinct from `Occupancy_Rate_Market__c` (see §1.3) — put that distinction in the `<description>` of BOTH so nobody merges them later |
| 3 | `Year_Renovated__c` | Number(4,0) | `Lead.Year_Renovated__c` | |
| 4 | `Lot_Size_Acres__c` | Number(10,2) | `Lead.Lot_Size_Acres__c` | Name states its unit; see note 4 |
| 5 | `WALT_Years__c` | Number(4,1) | `Lead.WALT_Years__c` | |
| 6 | `ADR__c` | Currency(10,2) | `Lead.ADR__c` | §1 rule 5: established industry term, keeps its name |
| 7 | `Zoning__c` | Text(100) | `Lead.Zoning__c` | |
| 8 | `Seller_Entity__c` | Text(255) | `Lead.Seller_Entity__c` | ⚠ **Text, not a lookup** — §1 rule 3 reserves a bare object-shaped name for a relationship. `Seller_Entity__c` is a quoted string from the email (there is no Seller object); say so in the `<description>` per §1 rule 9's Text exception |

**EXTENDED (existing, newly stamped):**

| Property field | ← Lead source |
|---|---|
| `Square_Footage__c` Number(18,0) | `Building_SF__c` |
| `Annual_NOI__c` Currency(18,2) | `NOI__c` |
| `Year_Built__c` Number(4,0) | `Year_Built__c` |
| `Name` (standard) | **precedence change** — `Property_Name__c` → `Property_Address__c` → `Street` → `Company` → `Lead.Name` → `'Property'`, clipped 80 |

> **Note 4 — lot size: acres only, no derivation.** `Property__c.Lot_Size__c` is documented as **square feet, entered from the Offering Memorandum**. We hold acres only (`LLMExtractionParser.acres()` canonicalizes). Conversion writes `Lot_Size_Acres__c` and **never touches `Lot_Size__c`** — computing SF from acres is deriving one number from another, forbidden by the module's own anti-hallucination contract, and would overwrite an analyst's OM figure with a machine estimate. Cost: `Property__c` now carries two lot-size fields, one of which (`Lot_Size__c`) does not name its unit. That is a pre-existing §1 rule-5/9 ambiguity; relabelling it is **out of scope** and flagged in §8.
>
> **Note 5 — the `Name` precedence change is a visible behaviour change.** Today every conversion-born Property is named after its address. After this, one with a marketing name becomes e.g. `"Orion ParkView"`. Existing Properties are **not** back-filled. The address is still in `Address__c` and on the Property tab, so nothing becomes unfindable — but the Property list view will read differently for new records. Stated, not hidden.

### 2.3 Total new metadata: **17 fields** (9 Opportunity + 8 Property), **4 extended stamps**, **1 name-precedence change**, **1 StandardValueSet value**.

---

## 3. D-b — `LeadConvertService` CHANGE SHAPE

### 3.1 Layer and placement

All three code changes (S1 stamping, S2 OCR, Name precedence) land in **`LeadConvertService`** — the established post-convert stamping site, confirmed by reading it. It is a **Service** (`with sharing`), so DML belongs to it and SOQL does not. Layer contract honoured:

- New SOQL → **new `OpportunityContactRoleSelector`** (`with sharing`, `WITH USER_MODE`). No inline SOQL is added to the service.
- No domain class is introduced (consistent with P5: this trigger path is orchestration, not per-object rules).

### 3.2 Bulk-safe shape — a hard contract, pinned by test

| | Today | After |
|---|---|---|
| SOQL | 1 (`RecordTypeSelector`) | **2** (+ `OpportunityContactRoleSelector.selectByOpportunityIds`) |
| DML | 2 (Property insert, Opportunity update) | **3** (+ one OCR DML) |

**Constant regardless of batch size.** No SOQL or DML inside any loop. Picklist `getDescribe()` calls are describes, not queries — no limit consumed. `bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities` already drives 251 conversions in two `convertLead` chunks, so `stampConvertedOpportunities` fires **twice** per transaction — the OCR read/write must be per-invocation constant, not per-record.

### 3.3 Picklist safety — reuse the guard that already exists

`LeadConvertService.assetTypePicklistValues()` already exists precisely because a restricted picklist accepts values the compiler cannot check. Two of the new Opportunity fields are restricted picklists (`Sale_Process__c`, `Parse_Confidence__c`).

**Generalize that helper** (`activePicklistValues(Schema.SObjectField)`) and guard both writes. Rationale, from a defect this program has already been bitten by: *picklist values bypass the compile checker — a code-first deploy goes green, then throws at runtime; a mapped sibling picklist drops unknown values silently.* Here the failure would be worse than silent: `update updates` is **all-or-none**, so one illegal picklist value on one Lead would roll back the stamping for **every** Lead in the chunk, including the structural `RecordTypeId` / `Property__c` link.

**`update updates` stays all-or-none.** The structural fields must land or the conversion is broken; guarding at source (describe filter + exact type/length mirroring) removes the failure mode without weakening that guarantee. The Property insert keeps its existing `Database.insert(properties, false)`.

### 3.4 Idempotency

- **Stamping:** already guarded by `justConverted` (`IsConverted` false→true), which fires exactly once per Lead. Re-running is impossible via this path; the stamp is a straight field assignment and is naturally idempotent anyway.
- **OCR:** read-then-write, never blind insert. See D-c.
- **No overwrite of analyst input:** every target field on a freshly created Opportunity/Property is empty at this instant, so no "don't clobber" branch is needed. Do **not** add one — it would be untestable dead code today and would mask a real bug tomorrow.

### 3.5 FLS posture — ⚠ **CORRECTION to a common assumption, state it in the class header**

The framing "every new field written needs FLS for the converting persona" is **not accurate for the write, and is accurate for the display.** Precisely:

1. `LeadConvertService`'s DML is plain Apex `insert`/`update` — **system mode**. FLS is **not** enforced on the write.
2. Its reads come from `Trigger.new`, which is **not FLS-filtered**.
3. **⇒ A missing FLS grant does NOT block the stamp. The data lands.**
4. FLS is required so the persona can **SEE** the values — compact layout, page layout, reports, `force:detailPanel`, the Property tab's cross-object fields. Without it the highlight panel renders **nothing at all** for that field, silently. That is the "fails soft ⇒ watch for silence" failure mode this module has been bitten by repeatedly, and it is precisely the shape of the record-type-visibility incident: *the automation succeeded; the persona could not see the result.*
5. **Compact layouts themselves need no FLS. The FIELDS do.** (User's framing — confirmed.)
6. `Opportunity.Property_Address__c` is a **formula**: read-only, but still FLS-permissionable and still needs the grant. Cross-object formulas evaluate in system context, so the persona needs FLS on the formula field only, **not** on `Property__c.Address__c`.
7. **Verify as a real persona, never as an admin.** `ARCHITECTURE.md` §2 already documents that a System Administrator has **no** FLS on Metadata-API-deployed custom fields (measured on `usman-dpeg` for `User.Deal_Driver__c`) — Metadata-API field deploys arrive with zero field permissions for any profile. An admin smoke test proves nothing here.

**Permission-set updates — grant where the SIBLING fields live, not where the feature lives.**

| Object | Permission sets to update | Evidence |
|---|---|---|
| 9 new **Opportunity** fields | `DPEG_Acquisition_Edit` (editable), `DPEG_Acquisitions` (editable), `DPEG_Acquisition_View` (read-only), `DPEG_Opportunity_View` (read-only) | these 4 are the only sets carrying `Opportunity.*` field permissions (80 / 79 / 80 / 53 rows) |
| 8 new **`Property__c`** fields | `DPEG_Acquisition_Edit`, `DPEG_Acquisitions`, `DPEG_Acquisition_View` | same three; `DPEG_Opportunity_View` is Opportunity-only |

⚠ **`Broker_Protection_Access` is deliberately NOT touched.** It carries `Lead.*` grants only — **zero** `Opportunity.*` / `Property__c.*` rows (verified). Adding them there would put the grant where the *feature* lives instead of where its *siblings* live, and would mean touching a file whose own header documents a redeploy-drops-FLS trap. `Property_Address__c` is a formula → grant **read only**, `editable=false`, in every set including the Edit ones (an editable grant on a formula field is rejected).

### 3.6 `Lead.Company` is not remapped

S4 changes what `Lead.Company` *contains*, not where it goes. Conversion continues to let the platform derive the Account from Company / the Smart-Conversion match. No change to `LeadConvertMatchService` or `LeadConvertActionService` — see D-e §6.3.

---

## 4. D-c — OCR CREATION DETAILS

### 4.1 Does the role value exist? **No.**

`Broker` is absent from `standardValueSets/ContactRole.standardValueSet-meta.xml`. **Admin must add it** (additive — the standing "sweep before removing a picklist value" rule governs removals, not additions; nothing to sweep here). `ContactRole` is the `OpportunityContactRole.Role` value set specifically; `AccountContactRole` and `ContractContactRole` are separate files and are unaffected.

### 4.2 Is it idempotent? **It must be, and not by insert.**

⚠ **Standard Lead conversion already creates an `OpportunityContactRole`** for the converted Contact on the new Opportunity, `IsPrimary = true`, `Role` blank. A blind `insert` would therefore produce a **second** row for the same Contact and a second primary — Salesforce permits only one primary per Opportunity, so the insert would either demote the existing row or fail, and either way the deal ends up with two broker rows.

**Design: read-then-write, always.**

1. Skip any Lead whose `ConvertedContactId` is null (defensive; `LastName` is required so a Contact is always produced, but the null check costs nothing).
2. `OpportunityContactRoleSelector.selectByOpportunityIds(Set<Id>)` — one query, `WITH USER_MODE`, returning `Id, OpportunityId, ContactId, Role, IsPrimary`.
3. For each converted (Opportunity, Contact) pair:
   - **row exists** → update `Role = 'Broker'`; set `IsPrimary = true` only when it is not already true.
   - **no row** → insert `new OpportunityContactRole(OpportunityId=…, ContactId=…, Role='Broker', IsPrimary=true)`.
4. One DML for the combined list.

This is correct whether or not the platform creates the row, so it does not depend on undocumented conversion behaviour — and it is naturally idempotent if the path ever re-runs.

### 4.3 Access

`OpportunityContactRole` has **no separate object permission** — access follows the Opportunity. The DML runs in system mode (see D-b §3.5), so provisioning is not a write blocker. `OpportunityContactRole.Role` is a standard field; **verify in-org** that the convert-capable personas can read it, since the Contact Roles related list is how the broker becomes visible.

### 4.4 Page placement (S2's "visible on the Opportunity page")

The broker's name/email/phone live on the **Contact**, and a **compact layout cannot cross objects** — so the highlight panel is not the vehicle. Placement:

- **Add the standard `OpportunityContactRole` related list ("Contact Roles") to the Opportunity_Record_Page `Related` tab.** This is the platform-native surface for exactly this, it renders Contact Name + Role + Primary with a link through to phone/email, and it costs no new component.
- The **existing `brokerFirmCard` sidebar is untouched and keeps working** — it reads the Account, not the OCR.
- `Opportunity.Listing_Broker_Name__c` / `Listing_Broker_Email__c` (new, §2.1) carry the *listing* broker, who is often a different person from the submitting broker. They appear on the page layout, not via the OCR.

> **No new LWC.** The related list satisfies S2 as written. §8 flags the `brokerFirmCard` improvement the OCR now makes possible (reading the OCR instead of "earliest Contact on the Account"), explicitly **not** in this bundle.

---

## 5. D-d — HIGHLIGHT PANEL FIELD LISTS

**Constraints:** compact layouts cap at **10 fields**; the first two are the most prominent in the collapsed bar; **fields must be on the object itself** (no cross-object references); both current assignments are object-level so one revision each covers all record types.

### 5.1 `Lead_Highlights` — REVISE (6 → 10)

| # | Field | Why |
|---|---|---|
| 1 | **`Property_Address__c`** | **user-mandated first**; already a real Text field on Lead |
| 2 | `Guidance_Price__c` | the number the screening decision turns on |
| 3 | `Guidance_Cap_Rate__c` | second screening number |
| 4 | `NOI__c` | the income figure |
| 5 | `Occupancy_Pct__c` | the risk figure |
| 6 | `Building_SF__c` | scale of the asset |
| 7 | `Asset_Type__c` | *(retained)* |
| 8 | `Offer_Due_Date__c` | *(retained)* — the only time-critical value |
| 9 | `BP_Expiry__c` | *(retained)* — the broker-protection window; module-specific and live |
| 10 | `Parse_Confidence__c` | "should I trust rows 2–6?" — the meta-field that makes the rest safe to read |

**Dropped, with reasons:** `My_Cap_Rate__c` (analyst-entered — always empty on an email-born Lead at the moment this panel is read); `Days_in_System__c` (aging, better served by a list view than a 10-slot budget). `Sale_Process__c` did not make the 10 and belongs on the Lead page layout instead.

### 5.2 `Deal_Highlights` (Opportunity) — REVISE (6 → 10)

The Opportunity panel serves the **whole deal lifecycle**, not just the minute after conversion — so the existing analyst-owned fields are **not** stripped just because they are empty at conversion.

| # | Field | Why |
|---|---|---|
| 1 | **`Property_Address__c`** (NEW formula) | **user-mandated first** — see note 1 |
| 2 | `Asking_Price__c` | *(retained)* — now actually populated at conversion |
| 3 | `Deal_Status__c` | *(retained)* |
| 4 | `Offer_Due_Date__c` (NEW) | most time-critical email-derived value |
| 5 | `Sale_Process__c` (NEW) | how the deal is being run — changes the play |
| 6 | `My_Cap_Rate__c` | *(retained)* — analyst's number, fills during underwriting |
| 7 | `Market_Cap_Rate__c` | *(retained)* |
| 8 | `Listing_Broker_Name__c` (NEW) | S2's broker visibility, on-object |
| 9 | `Broker_First_Seen__c` | *(retained)* |
| 10 | `Parse_Confidence__c` (NEW) | tells the analyst how much of rows 1–5 was machine-read |

**Dropped:** `Name` — the highlights panel already renders the record's name as its title, so slot 1 was being spent on a duplicate. Removing it is also what makes room for the mandated Property Address. (`Lead_Highlights` already omits `Name` for the same reason — this makes the two consistent.)

> **Note 1 — why `Opportunity.Property_Address__c` must exist, and why a FORMULA.**
> A compact layout **cannot** reference `Property__r.Address__c`; the mandated first field therefore has to be an Opportunity field. Two options were considered:
> - **Formula (Text) = `Property__r.Address__c` ← CHOSEN.** No new write path, no stamping code, no possibility of drifting from the Property record (which S1 makes the system of record for the address), and it self-corrects if the address is fixed later.
> - *Stamped Text (rejected):* survives a failed Property insert (`Database.insert(..., false)` can leave `Property__c` null), but becomes a snapshot that silently diverges the first time anyone edits the Property address — and divergence on the field that is also the claim key is the last thing this module needs.
>
> **Accepted cost of the formula:** the highlight bar's first field is **blank** when `Property__c` is null — which happens only when the Property insert failed (rare, `allOrNone=false`) or the Opportunity was created manually. Use `formulaTreatBlanksAs = BlankAsBlank`. This is a **reversible one-field decision** — swapping to a stamped Text later costs one field definition and three lines in `buildProperty`'s sibling.
>
> **Note 2 — the submitting broker is deliberately absent from this panel.** They live on the OCR (a related record) and a compact layout cannot cross objects. Slot 8 carries the *listing* broker (an on-object field); the submitting broker surfaces via Contact Roles + `brokerFirmCard`. Do not "fix" this by adding a formula through `AccountId` — an Opportunity's Account is the *firm*, and `BrokerFirmController`'s own header records that naming a broker from an Account is what produces a wrong answer on a live page.

### 5.3 Page/layout placement (so the other 15 fields are reachable)

| Where | What to add |
|---|---|
| `layouts/Opportunity-Opportunity Layout` (feeds the Detail tab's `force:detailPanel`) | the 8 stamped Opportunity fields + `Property_Address__c` (read-only). **Confirm in-org which layout each Opportunity record type uses** — the assignment lives in `.forceignore`d profiles |
| `flexipages/Opportunity_Record_Page` → Property tab → "Details" fieldSection (facets `Facet-dc2cc896-…` / `Facet-d06d7c84-…`) | the 8 new + 3 newly-stamped `Record.Property__r.*` fields |
| `layouts/Property__c-Property Layout` | the 8 new `Property__c` fields (for the Property record page itself) |
| Lead page layout | **nothing new** — all 19 Lead fields already exist and are already placed |

---

## 6. D-e — S4 PROMPT RULE

### 6.1 Placement — ENRICHED block only, immediately after `BROKER vs LISTING BROKER`

`ENRICHED_EXTRACTION_RULES`, as a new paragraph after the `BROKER vs LISTING BROKER` paragraph (which already establishes the "names the legacy values, then defers" pattern). **`LEGACY_EXTRACTION_RULES` and `LEGACY_RESPONSE_FORMAT` are NOT touched** — that preserves the byte-pin, the git-diffability, and the one-line rollback (`EXTRACTION_INSTRUCTION = LEGACY_EXTRACTION_RULES + LEGACY_RESPONSE_FORMAT`).

**Resolving an apparent conflict with the prompt-tuning doc:** `…-prompt-tuning.md` D3 said a new sentence "must NOT mention `broker_name`, `broker_email` or `property_address`." That constraint was scoped to the D3 `sent_datetime` paragraph, whose only job was to narrow a legacy value. This rule **must read `broker_email`** — the domain is its input. It is safe because it is phrased so it can only ever **write `broker_company`**, and because the enriched block **already** names `broker_name`/`broker_email` in the `BROKER vs LISTING BROKER` paragraph and defers. The new paragraph must carry the same explicit deferral sentence.

### 6.2 Wording (carry verbatim into the dev prompt)

> **broker_company WHEN THE EMAIL DOES NOT NAME THE FIRM:** if the body, the signature block or the subject states the broker's company, use it exactly as written. If no company is stated anywhere, you MAY infer broker_company from the DOMAIN of broker_email — kevin.girard@jll.com gives "JLL". When the domain belongs to a brokerage whose conventional capitalization you recognise, use that conventional form (for example JLL, CBRE, Cushman & Wakefield, Marcus & Millichap, Newmark, Colliers, Avison Young, Lee & Associates, Berkadia, Walker & Dunlop, Eastdil Secured, NorthMarq, Matthews, Institutional Property Advisors). Otherwise use the registrable part of the domain with ordinary capitalization and no suffix — orion-realty.com gives "Orion Realty". Return only the FIRM name the domain implies; never append a division, team, region, market or group name. NEVER infer a company from a free or consumer mailbox domain — gmail.com, googlemail.com, hotmail.com, outlook.com, live.com, msn.com, yahoo.com, ymail.com, aol.com, icloud.com, me.com, mac.com, proton.me, protonmail.com, gmx.com, zoho.com, mail.com, or any other consumer mailbox provider — and never from a domain that is not a company's own domain. In those cases leave broker_company EMPTY. This rule reads broker_email only as a source for broker_company; it does not change how broker_name, broker_email, property_address or sent_datetime are determined.

**Hard constraints on the edit:** enriched block only; the paragraph may write **only** `broker_company`; the final deferral sentence is mandatory; no change to `MODEL`, `temperature`, `MAX_TOKENS`, `response_format`, `MAX_INPUT_CHARS`, `MAX_PROPERTIES_IN_PROMPT`, `referenceDateLine()`, the `extract(...)` signature, the parts ordering, or the response schema (`broker_company` is already a key in it — **no schema change**).

### 6.3 Downstream — verify NO code change is needed. **Confirmed: none.**

Traced end to end:

1. `EmailToLeadService.buildLead`: `lead.Company = String.isNotBlank(request.brokerCompany) ? clip(brokerCompany, LEN_COMPANY) : COMPANY_PLACEHOLDER;` — an inferred "JLL" is simply a non-blank `brokerCompany`. **No change.**
2. `LeadConvertMatchService.collectMatchKeys`: excludes **only** the exact literal `EmailToLeadService.COMPANY_PLACEHOLDER` (`equalsIgnoreCase`). `"JLL"` is not that literal, so it enters the `companies` bind set and reaches `AccountSelector.selectByNames`. **No change** — the D1b guard is a placeholder guard, not a general-company guard, exactly as designed.
3. `AccountSelector.selectByNames` → exact, case-insensitive, `CreatedDate ASC, Id ASC`; `LeadConvertMatchService.normalizeKey` lower-cases both sides. So `"Jll"` and `"JLL"` converge. **Case drift is safe.**
4. If no `JLL` Account exists, no Account matches, and standard conversion creates one named `"JLL"`. If one exists, the new Contact lands under it. **Both are the documented, already-shipped behaviour.**
5. `COMPANY_PLACEHOLDER` has exactly 5 referencing files (2 production: `EmailToLeadService`, `LeadConvertMatchService`; 3 test). No Flow, validation rule or layout keys off the literal. **No change.**

> **⇒ Two brokers at the same firm converge on ONE Account.** Broker A (`a@jll.com`) converts first and mints the `JLL` Account. Broker B (`b@jll.com`) converts later, matches no Contact (different email — D1a), matches the `JLL` Account by name, and their new Contact lands under it. **D2 oldest-wins makes this convergent** — a later duplicate can never displace the canonical Account. This is the intended outcome and is exactly the "company half" of the original Smart Conversion request finally becoming reachable: before S4, almost every email-born Lead carried the placeholder and could never account-match at all.

### 6.4 The genuinely new risk, stated

⚠ **This is the first prompt change whose output feeds an ATTACHMENT decision.** Previously `broker_company` was display-only; after Smart Lead Conversion it is an **Account match key**. So a prompt edit now helps decide **which firm a deal is attributed to**.

Why it is nonetheless the right trade:
- The **domain is a hard fact in the email header**, not a free-text guess — categorically more reliable than any name inference, and the free-mail exclusion removes the one case where a domain says nothing about a firm.
- The failure mode is **recoverable**: a slightly-off firm name creates a second Account, which a human merges. Compare the alternative already rejected in D1b — bucketing on the placeholder, which put an *actively wrong* answer on a live page. This design keeps preferring the recoverable failure.
- `'Unknown - Via Email'` is *a null wearing a string*; the whole point of S4 is to produce fewer of them.

**Accepted cost:** an inferred company is a *derived* value occupying a field that used to hold either a stated fact or an explicit placeholder. The "no division/team/region suffix" clause is the load-bearing part of the wording — `"JLL"` vs `"JLL Capital Markets"` is the fragmentation that exact-name matching cannot bridge.

### 6.5 Verification — fixture green + live UAT (the established pattern; prompt changes are un-unit-testable)

**Automated (necessary, not sufficient):** full suite green **unchanged**. Specifically `ExtractionRegressionFixtureTest` (legacy byte-pin + rollback composition — a red here means the legacy block was touched: **stop, do not deploy**), `LLMExtractionCalloutServiceTest` (`contains` assertions + `sentBody.length() < 80000` — the new paragraph is ~1.2 KB, far inside it), `LLMExtractionParserTest`, `ExtractAddressQueueableTest`.

**Live UAT on `usman-dpeg` — four emails, forwarded FRESH (new Message-ID; redelivery hits the idempotency guard):**

| Case | Email | PASS condition |
|---|---|---|
| **A — corporate domain, no company stated** | broker at `@jll.com` (or any real brokerage domain), body naming no firm | `Extracted_JSON__c.broker_company` = `"JLL"`; `Lead.Company` = `"JLL"`; conversion creates-or-attaches a `JLL` Account |
| **B — free-mail domain, no company stated** | the incident address `usmankhan-96@hotmail.com`, body naming no firm | `broker_company` = `""`; `Lead.Company` = `'Unknown - Via Email'`; conversion **does not** account-match (D1b holds) |
| **C — company IS stated (regression)** | any email whose signature names the firm | the **stated** company verbatim; inference must never override a stated value |
| **D — same-firm convergence** | two Leads, two different `@jll.com` brokers | both Opportunities land on the **same** `JLL` Account (oldest-wins); two distinct Contacts |

Also re-check, on every case, that `property_address` still normalizes to the **same `Property_Key__c`** as before — a claim-key drift means roll back. **Rollback:** revert the single class; the paragraph is independent of every other component.

---

## 7. D-f — OPPORTUNITY NAME QUALITY (⚠ USER DECISION — recommended YES, in this bundle)

**Today:** `LeadConvertActionService` calls `setDoNotCreateOpportunity(false)` and **never** calls `setOpportunityName` (its own comment: *"the platform derives its Name from Company"*). So an email-born deal is named **`Unknown - Via Email`**.

**S4 makes this worse, not better.** After S4 those deals will be named `"JLL"`, `"CBRE"`, `"Colliers"` — *plausible-looking* and therefore harder to spot as broken, and now **N deals from one firm share one name**. Today's obviously-broken name at least announces itself.

**Proposal (small, contained):** in `LeadConvertService.stampConvertedOpportunities`, set `o.Name` from `Lead.Property_Name__c` → `Lead.Property_Address__c` → the existing name, clipped to 120 (`Opportunity.Name` max). Post-convert stamping keeps the change in **one class** and needs no touch to `LeadConvertActionService` or `Database.LeadConvert`.

- **Cost:** one more assignment in a loop that already exists; zero new SOQL/DML; the same `firstNonBlank` helper already in the class.
- **Blast radius:** display only — `BrokerFirmController` counts, `OpportunitySelector` aggregates and every KPI key off Ids and Stage, not Name. Existing Opportunities are **not** renamed.
- **Why flag rather than assume:** renaming records is a visible change to reports, list views and anyone's saved searches. It is one line to include and one line to omit.

**Recommendation: include it.** Doing S4 without it ships a naming regression disguised as an improvement.

---

## 8. FLAGGED, NOT IN SCOPE — user decisions, deliberately not built

None of these are in the prompts in §10. Listed because the inventory surfaced them.

| # | Item | Why it is flagged |
|---|---|---|
| F1 | **`Opportunity.Guidance_Cap_Rate__c` exists and is never populated.** Its price twin (`Asking_Price__c`) is being stamped by S1; the cap-rate twin is not in S1's list, so the Opportunity will show a price but no cap rate. One line to add. | S1's field list is fixed; adding it unasked is scope creep. But an asymmetric pair is a defect waiting to be reported. |
| F2 | **`brokerFirmCard` could read the OCR instead of "earliest Contact on the Account".** After S2 there is an authoritative broker on every conversion-born deal, and after Smart Lead Conversion one Contact fronts **many** deals — so "earliest Contact on the Account" is now more likely to name the wrong person than before. | A real accuracy improvement that S2 unlocks, but it is an LWC/controller change nobody asked for. |
| F3 | **`Property__c.Lot_Size__c` does not name its unit** (it is SF per its description) and will now sit beside `Lot_Size_Acres__c`, which does. §1 rule 5 ambiguity. | Relabelling is a one-line `<label>` change but touches an OM-entered field with stored data; out of this bundle. |
| F4 | **`'Unknown - Via Email'` Accounts already in the org are not renamed by S4.** S4 reduces future ones; the existing per-broker stubs remain. (Already filed as S2 in `docs/2026-08-03-smart-lead-conversion.md`.) | No back-fill was requested. |
| F5 | **Range-priced deals contribute 0 to the pipeline-value KPI** (§2.1 note 2). A "use the midpoint" or "use the high" convention would fix the KPI at the cost of fabricating a number. | Deliberately not decided here. |

---

## 9. D-g — TEST PLAN

`LeadConvertServiceTest` **exists** (7 methods incl. a 251-Lead bulk test) — **extend it, do not create a parallel class.** `TestDataFactory` is the org-wide factory (`createLead`, `createLeads`); do not stand up a competing one.

### 9.1 `LeadConvertServiceTest` — new methods

| Test | Asserts |
|---|---|
| `stampsDealProcessFieldsOntoOpportunity` | all 8 stamped Opportunity fields carry from a fully-populated Lead, incl. `Asking_Price__c` ← `Guidance_Price__c` |
| `stampsPhysicalFactsOntoProperty` | all 8 new + 3 extended `Property__c` fields carry; **`Lot_Size__c` stays NULL** (the no-derivation guarantee, pinned) |
| `rangePricedLeadLeavesAskingPriceNull` | low/high stamped, `Asking_Price__c` null — the accepted cost made explicit so a future "helpful" midpoint change fails here |
| `propertyNamePrefersPropertyNameOverAddress` | `Property__c.Name` = `"Orion ParkView"` when `Property_Name__c` is set; falls back to address when it is not (both branches) |
| `unknownPicklistValueIsDroppedNotThrown` | a Lead carrying a `Sale_Process__c` / `Parse_Confidence__c` value absent from the Opportunity picklist leaves the target null **and the rest of the stamp still lands** — the all-or-none protection |
| `createsPrimaryBrokerOpportunityContactRole` | exactly **one** OCR for the converted Contact, `Role = 'Broker'`, `IsPrimary = true` — i.e. the platform's own row was **updated, not duplicated** |
| `opportunityContactRoleIsIdempotent` | invoking the stamp a second time over the same converted set leaves the OCR count unchanged |
| `opportunityNameFromPropertyName` | **only if D-f is approved** — Name = `Property_Name__c`, else address, clipped to 120 |
| `blankLeadFieldsLeaveTargetsNull` | a Lead with all 19 fields empty produces no writes and no exception (the ordinary case for a thin email) |

### 9.2 Extend the existing 251 bulk test

`bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities` already drives 251 conversions in two `convertLead` chunks, so the service fires **twice** per transaction. Extend it to assert:

- 251 Opportunities carry the new fields and 251 Properties carry theirs;
- **251 OCRs, one per deal**, all `Role = 'Broker'`, all primary — the check that the OCR path is per-invocation, not per-record;
- **governor headroom**: query and DML deltas bounded (**≤ 2 SOQL / ≤ 3 DML per invocation**), so a future change that adds one query per Lead fails **here** rather than in production. This is the highest-value assertion in the plan.

The `.claude/rules/bulk-test-rule.md` **251 mandate applies in full** — this is a trigger-driven path and the Broker-Protection per-transaction-singleton exemption was narrowed on 2026-07-31 to `LLMExtractionCalloutService` only.

### 9.3 New selector test

`OpportunityContactRoleSelectorTest` — field shape, Id scoping, null/empty short-circuit (no SOQL), and an independent **251-row bulk proof**, matching the pattern of `AccountSelectorTest` / `ContactSelectorTest`.

### 9.4 Persona / FLS regression — ⚠ **the automated form of this test is a trap**

`System.runAs` **does not enforce FLS on Apex DML**, and `LeadConvertService` writes in system mode. So a `runAs` test asserting "the stamp lands as a non-admin persona" would pass **whether or not the FLS grant exists** — it is a test that cannot fail, i.e. exactly the vacuous-green pattern this program has already been bitten by.

**Therefore:**

- **Automated:** a `runAs` test is still worth having, but only for what it *can* prove — that the conversion path itself does not throw for a non-admin persona. It must carry a comment saying it does **not** prove FLS, or someone will later trust it to.
- **Manual, mandatory, deploy-gated:** log in as a **real convert-capable persona** (the Junior Analyst who ran the 2026-08-03 conversion — **not an admin**, whose FLS on Metadata-API-deployed fields is not representative) and confirm on a freshly converted deal that: every new Opportunity field renders a **value** (not blank) on the Detail tab; every new `Property__r` field renders on the Property tab; **both revised highlight panels render all 10 fields**, Property Address first; the Contact Roles related list shows the broker as **Broker / Primary**.
- A blank field for that persona means a missing FLS grant, **not** a failed stamp — query the row directly to tell the two apart. This distinction is the single most useful line in the runbook.

### 9.5 Jest

**None.** No LWC is created or modified in this bundle.

---

## 10. ROUTING, SEQUENCE, AND AGENT PROMPTS

**Routing: `salesforce-admin` FIRST, then `salesforce-developer`.** The dependency is hard — Apex referencing `Opportunity.Sale_Process__c` or `OpportunityContactRole.Role = 'Broker'` will not compile / will throw at runtime until the fields and the picklist value exist. Neither half is complex enough for the architect variants: the fields are ordinary, the picklist value is additive, and the Apex is one more stamping block plus one selector in an existing, well-understood class. The prompt edit is a string constant in an existing enriched block (`salesforce-developer` is sufficient; the §3.3 ASB exception is untouched).

```
STEP 1  🔵 salesforce-admin              — 17 fields, 1 StandardValueSet value, 2 compact layouts,
                                            layout + flexipage placement, 4 permission sets
STEP 2  🟢 salesforce-developer          — LeadConvertService + OpportunityContactRoleSelector + prompt
STEP 3  🟡 salesforce-unit-testing       — extend LeadConvertServiceTest, new selector test
STEP 4  🟣 salesforce-code-review
STEP 5  🔴 salesforce-devops  ‖  🔷 salesforce-documentation
```

### 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md §1 (naming, incl. rule 9) and
agent-output/design-requirements-conversion-enrichment.md before starting.
Do NOT deploy — create metadata files only.

Every NEW field must mirror its Lead source field's type, length, precision and scale
EXACTLY (the Lead definitions are in force-app/main/default/objects/Lead/fields/). That
exactness is what makes the Apex stamp safe; do not "improve" a length or a scale.
Give every new field a <description> saying it is carried from the Lead at conversion,
and an <inlineHelpText> mirroring the Lead field's.

1. NINE new Opportunity fields (force-app/main/default/objects/Opportunity/fields/):
   Guidance_Price_Low__c    Currency(18,2)
   Guidance_Price_High__c   Currency(18,2)
   Offer_Due_Date__c        Date
   Sale_Process__c          Picklist, restricted=true, values byte-identical to
                            Lead.Sale_Process__c: Off-Market, On-Market Listing,
                            Call for Offers, Auction
   Parse_Confidence__c      Picklist, mirror Lead.Parse_Confidence__c exactly
                            (HIGH, MEDIUM, LOW) including its restricted flag
   Deal_Room_Link__c        Url
   Listing_Broker_Name__c   Text(120)
   Listing_Broker_Email__c  Email
   Property_Address__c      FORMULA (Text), formula = Property__r.Address__c,
                            formulaTreatBlanksAs = BlankAsBlank

2. EIGHT new Property__c fields (force-app/main/default/objects/Property__c/fields/):
   Unit_Count__c        Number(18,0)
   Occupancy_Pct__c     Percent(5,2)   — description MUST state this is the subject
                        asset's stated occupancy from the broker email, DISTINCT from
                        the existing Occupancy_Rate_Market__c (a market benchmark).
                        Do not modify Occupancy_Rate_Market__c.
   Year_Renovated__c    Number(4,0)
   Lot_Size_Acres__c    Number(10,2)   — description MUST state that the existing
                        Lot_Size__c is square feet from the Offering Memorandum and is
                        NOT derived from this field.
   WALT_Years__c        Number(4,1)
   ADR__c               Currency(10,2)
   Zoning__c            Text(100)
   Seller_Entity__c     Text(255)      — description MUST state it is a quoted seller
                        entity name from the email, deliberately Text and NOT a lookup.
   Do NOT create a Property_Name__c on Property__c — the standard Name field is used.

3. StandardValueSet: add ONE value 'Broker' to
   force-app/main/default/standardValueSets/ContactRole.standardValueSet-meta.xml
   (label 'Broker', default false). Additive only — remove nothing, reorder nothing.
   Do not touch AccountContactRole or ContractContactRole.

4. Compact layouts — replace the field lists exactly as specified (10 fields each,
   order is significant, Property Address FIRST in both):
   objects/Lead/compactLayouts/Lead_Highlights.compactLayout-meta.xml:
     Property_Address__c, Guidance_Price__c, Guidance_Cap_Rate__c, NOI__c,
     Occupancy_Pct__c, Building_SF__c, Asset_Type__c, Offer_Due_Date__c,
     BP_Expiry__c, Parse_Confidence__c
   objects/Opportunity/compactLayouts/Deal_Highlights.compactLayout-meta.xml:
     Property_Address__c, Asking_Price__c, Deal_Status__c, Offer_Due_Date__c,
     Sale_Process__c, My_Cap_Rate__c, Market_Cap_Rate__c, Listing_Broker_Name__c,
     Broker_First_Seen__c, Parse_Confidence__c
   Both are assigned at object level (Opportunity.object-meta.xml line ~143,
   Lead.object-meta.xml line ~255) and neither Opportunity record type carries its own
   compactLayoutAssignment — do not add per-record-type assignments.

5. Placement:
   a. layouts/Opportunity-Opportunity Layout.layout-meta.xml — add the 8 stamped
      Opportunity fields plus Property_Address__c (read-only). This layout feeds the
      record page's Detail tab, which is force:detailPanel, so fields do NOT appear
      without it. FIRST verify in-org which layout each Opportunity record type
      (Land / Commercial) actually uses — that assignment lives in profiles, which are
      .forceignore'd and therefore not in this repo.
   b. flexipages/Opportunity_Record_Page.flexipage-meta.xml — in the "Property" tab's
      "Details" fieldSection (facets Facet-dc2cc896-1e61-4d9a-ae6a-c56342861e9a and
      Facet-d06d7c84-8864-47e1-b080-be6f68587424) add the 8 new plus the 3 newly
      stamped Record.Property__r.* fields (Square_Footage__c, Annual_NOI__c,
      Year_Built__c if not already present). Balance across the two columns.
   c. flexipages/Opportunity_Record_Page.flexipage-meta.xml — add the standard
      OpportunityContactRole related list ("Contact Roles") to the Related tab
      (facet relatedTabContent). Do not build an LWC for this.
   d. layouts/Property__c-Property Layout.layout-meta.xml — add the 8 new Property__c
      fields.

6. Permission sets — grant FLS where the SIBLING fields already live:
   9 Opportunity fields ->  DPEG_Acquisition_Edit (editable), DPEG_Acquisitions
                            (editable), DPEG_Acquisition_View (read-only),
                            DPEG_Opportunity_View (read-only)
   8 Property__c fields ->  DPEG_Acquisition_Edit, DPEG_Acquisitions,
                            DPEG_Acquisition_View
   Opportunity.Property_Address__c is a FORMULA: grant readable=true, editable=false in
   EVERY set including the Edit ones (an editable grant on a formula field is rejected).
   Do NOT add Opportunity/Property field permissions to Broker_Protection_Access — it
   carries Lead fields only, and its own header documents a redeploy-drops-FLS trap.

Do not create validation rules, flows, reports, record types or LWC. Do not modify any
Lead field — all 19 already exist. Do not deploy.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md §1 + §2, .claude/rules/apex-layering-rule.md, and
agent-output/design-requirements-conversion-enrichment.md first. The admin agent has
already created the 17 fields and the ContactRole 'Broker' value — this work depends on
them. Do not deploy. Run no org commands.

PART A — force-app/main/default/classes/LeadConvertService.cls

A1. Extend buildProperty(...) to also copy, from the Lead:
      Square_Footage__c  <- Building_SF__c
      Annual_NOI__c      <- NOI__c
      Year_Built__c      <- Year_Built__c
      Unit_Count__c, Occupancy_Pct__c, Year_Renovated__c, Lot_Size_Acres__c,
      WALT_Years__c, ADR__c, Zoning__c, Seller_Entity__c  <- same-named Lead fields
    NEVER write Property__c.Lot_Size__c (it is square feet from the Offering Memorandum;
    deriving SF from acres is forbidden). Add a comment saying so.
    No clipping is needed anywhere: every new field mirrors its Lead source's type and
    length exactly, and InboundEmailFieldUtil already clipped the Lead values.

A2. Change the Property NAME precedence in buildProperty to:
      Property_Name__c -> Property_Address__c -> Street -> Company -> Lead.Name ->
      'Property', still clipped to 80. Reuse the existing firstNonBlank helper.

A3. In stampConvertedOpportunities, also stamp on each Opportunity:
      Asking_Price__c          <- Lead.Guidance_Price__c
      Guidance_Price_Low__c    <- Lead.Guidance_Price_Low__c
      Guidance_Price_High__c   <- Lead.Guidance_Price_High__c
      Offer_Due_Date__c        <- Lead.Offer_Due_Date__c
      Deal_Room_Link__c        <- Lead.Deal_Room_Link__c
      Listing_Broker_Name__c   <- Lead.Listing_Broker_Name__c
      Listing_Broker_Email__c  <- Lead.Listing_Broker_Email__c
      Sale_Process__c          <- Lead.Sale_Process__c      (picklist-guarded)
      Parse_Confidence__c      <- Lead.Parse_Confidence__c  (picklist-guarded)
    Do NOT stamp Opportunity.Guidance_Cap_Rate__c — deliberately out of scope.
    Do NOT synthesize Asking_Price__c from the low/high range; leave it null when
    Guidance_Price__c is null, and comment why (fabricating a price is forbidden).

A4. Generalize the existing assetTypePicklistValues() into a reusable
    activePicklistValues(Schema.SObjectField) helper and use it to guard BOTH new
    restricted-picklist writes plus the existing Property Asset_Type__c write. Rationale
    for the comment: `update updates` is all-or-none, so one illegal picklist value would
    roll back the structural RecordTypeId / Property__c link for every Lead in the chunk.
    Keep `update updates` all-or-none; keep Database.insert(properties, false).

A5. OpportunityContactRole (role 'Broker', primary) — READ-THEN-WRITE, never a blind
    insert. Standard conversion ALREADY creates a primary OCR for the converted Contact
    with a blank Role; inserting a second row would produce a duplicate broker and a
    second primary.
      - Skip any Lead whose ConvertedContactId is null.
      - One selector read for the converted Opportunity Ids.
      - Existing (OpportunityId, ContactId) row  -> update Role = 'Broker'; set
        IsPrimary = true only if it is not already true.
      - No row -> insert Role = 'Broker', IsPrimary = true.
      - ONE DML for the combined list.

A6. Update the class header: the two new stamping blocks, the picklist guard rationale,
    the OCR read-then-write rationale (say plainly that standard conversion already
    creates the row), and this FLS note verbatim in substance: "This service's DML runs
    in SYSTEM MODE and Trigger.new is not FLS-filtered, so a missing FLS grant does NOT
    block the stamp — the data lands. FLS is required only so the persona can SEE the
    values; without it the highlight panel renders blank, silently. Verify as a real
    persona, never as an admin."

PART B — new force-app/main/default/classes/OpportunityContactRoleSelector.cls
    `with sharing`, Selector layer, WITH USER_MODE, no DML, no business logic.
    selectByOpportunityIds(Set<Id> opportunityIds) -> List<OpportunityContactRole>
    (Id, OpportunityId, ContactId, Role, IsPrimary). MUST return a List (never a single
    SObject) and MUST short-circuit to an empty list on null/empty input without
    querying. Follow AccountSelector.cls as the pattern.

    BULK SHAPE IS A CONTRACT: LeadConvertService must stay at exactly 2 SOQL and 3 DML
    per invocation regardless of batch size. Say so in both class headers.

PART C — force-app/main/default/classes/LLMExtractionCalloutService.cls (prompt only)
    Add ONE new paragraph to ENRICHED_EXTRACTION_RULES, immediately AFTER the
    "BROKER vs LISTING BROKER" paragraph. Use the wording in
    agent-output/design-requirements-conversion-enrichment.md §6.2 verbatim.
    HARD CONSTRAINTS:
      - DO NOT EDIT LEGACY_EXTRACTION_RULES or LEGACY_RESPONSE_FORMAT. They are
        byte-pinned by ExtractionRegressionFixtureTest and are the one-line rollback.
      - The paragraph may WRITE only broker_company. It reads broker_email as an input;
        the closing deferral sentence ("it does not change how broker_name, broker_email,
        property_address or sent_datetime are determined") is MANDATORY.
      - No response-schema change: broker_company is already a key in the schema.
      - Do not change MODEL, temperature, MAX_TOKENS, response_format, MAX_INPUT_CHARS,
        MAX_PROPERTIES_IN_PROMPT, referenceDateLine(), the extract(...) signature, or the
        content-parts ordering.
    Add a dated (2026-08-03) class-header note recording the rule, that it is
    enriched-only, that the legacy block is untouched, AND this warning: broker_company
    now flows into Lead.Company, which after Smart Lead Conversion is an ACCOUNT MATCH
    KEY — so this prompt paragraph participates in deciding which firm a deal attaches
    to. It is no longer display-only.

PART D — ARCHITECTURE.md §6 upkeep
    Update the LeadConvertService row in §2 (Key Apex Services) to record that
    conversion now also carries the deal-screening field set onto the Opportunity and
    Property__c and creates the primary Broker OpportunityContactRole. Add
    OpportunityContactRoleSelector where AccountSelector is recorded. No §1 change is
    needed — every new field name is §1-conformant.

OPTIONAL — INCLUDE ONLY IF THE USER APPROVED D-f AT GATE 1:
    In stampConvertedOpportunities also set o.Name from Property_Name__c ->
    Property_Address__c -> the existing name, clipped to 120. Post-convert only; do not
    touch LeadConvertActionService or call setOpportunityName.

Do not modify LeadConvertMatchService, LeadConvertActionService, EmailToLeadService,
ExtractAddressQueueable, LLMExtractionParser or any permission set — S4 requires no
downstream code change (verified end to end in the design doc §6.3).
```

### 🟡 PROMPT FOR `salesforce-unit-testing`

```
Extend force-app/main/default/classes/LeadConvertServiceTest.cls (7 methods today —
extend it, do not create a parallel class) and add OpportunityContactRoleSelectorTest.
Use TestDataFactory (the org-wide factory); never SeeAllData. Follow §9 of
agent-output/design-requirements-conversion-enrichment.md for the full method list.

Non-obvious requirements:
  - Pin the NO-DERIVATION guarantee: assert Property__c.Lot_Size__c stays NULL when
    Lot_Size_Acres__c is stamped.
  - Pin the range case: low/high stamped, Asking_Price__c NULL, so a future "helpful"
    midpoint change fails here.
  - Pin the OCR as ONE row, Role='Broker', IsPrimary=true — i.e. the platform's own
    conversion-created row was UPDATED, not duplicated — plus an idempotency test.
  - Extend the existing 251-Lead bulk test (it fires the service TWICE via two
    convertLead chunks) to assert 251 OCRs and bounded governor deltas: <= 2 SOQL and
    <= 3 DML per invocation. This is the highest-value assertion in the plan.
  - OpportunityContactRoleSelectorTest needs its own independent 251-row bulk proof
    (pattern: AccountSelectorTest).
  - ⚠ A System.runAs test CANNOT prove FLS here: LeadConvertService writes in SYSTEM
    MODE and Trigger.new is not FLS-filtered, so such a test passes whether or not the
    grant exists. If you write one, restrict it to proving the path does not throw for a
    non-admin persona, and comment explicitly that it does NOT prove FLS — otherwise
    someone will later trust it to. FLS is verified manually, as a real persona.
  - No Jest: no LWC is created or modified in this bundle.
```

---

## 11. COMPONENT INVENTORY (Gate-1 summary table)

| Type | Count | Items |
|---|---|---|
| New Opportunity fields | **9** | `Guidance_Price_Low__c`, `Guidance_Price_High__c`, `Offer_Due_Date__c`, `Sale_Process__c`, `Parse_Confidence__c`, `Deal_Room_Link__c`, `Listing_Broker_Name__c`, `Listing_Broker_Email__c`, `Property_Address__c` (formula) |
| New `Property__c` fields | **8** | `Unit_Count__c`, `Occupancy_Pct__c`, `Year_Renovated__c`, `Lot_Size_Acres__c`, `WALT_Years__c`, `ADR__c`, `Zoning__c`, `Seller_Entity__c` |
| Existing fields newly stamped | **4** | `Opportunity.Asking_Price__c`; `Property__c.Square_Footage__c` / `Annual_NOI__c` / `Year_Built__c` |
| StandardValueSet values | **1** | `ContactRole` → `Broker` |
| Compact layouts revised | **2** | `Lead_Highlights`, `Deal_Highlights` (6 → 10 each, Property Address first) |
| Page layouts | **2** | `Opportunity Layout`, `Property Layout` |
| FlexiPage edits | **1 file, 2 areas** | `Opportunity_Record_Page`: Property-tab field section, Related-tab Contact Roles list |
| Permission sets | **4** | `DPEG_Acquisition_Edit`, `DPEG_Acquisitions`, `DPEG_Acquisition_View`, `DPEG_Opportunity_View` |
| Apex modified | **2** | `LeadConvertService`, `LLMExtractionCalloutService` (prompt paragraph only) |
| Apex new | **1** | `OpportunityContactRoleSelector` |
| Tests | **2** | `LeadConvertServiceTest` (extended, ~9 new methods + bulk extension), `OpportunityContactRoleSelectorTest` (new) |
| LWC | **0** | none created or modified |
| Docs | **1** | `ARCHITECTURE.md` §2 (`LeadConvertService` row + selector) |

---

## 12. THINGS THE USER MUST DECIDE OR ACKNOWLEDGE AT GATE 1

1. **⚠ `Opportunity.Asking_Price__c` stamping moves a live dashboard number** — open-pipeline value and "biggest deals" will jump on the next refresh (§2.1 note 1). Correct, but visible.
2. **⚠ Range-priced deals still contribute 0** to that KPI, because we refuse to synthesize a midpoint (§2.1 note 2).
3. **⚠ Conversion-born Property names change** — a marketing name now beats the address; existing records are not back-filled (§2.2 note 5).
4. **D-f (Opportunity Name) — recommended YES.** S4 turns `Unknown - Via Email` into `JLL`, which is *plausible-looking* and shared by every deal from that firm. One line in the same class; explicit approval requested (§7).
5. **⚠ S4 makes a prompt paragraph part of the attachment decision** — `broker_company` now feeds `Lead.Company`, which is an Account match key. Domain-based inference is a hard fact and the free-mail exclusion covers the dangerous case, but this is a real widening (§6.4).
6. **FLS is a display gate, not a write gate** (§3.5). The stamp lands regardless; the persona sees nothing without it. **Acceptance-test as the Junior Analyst persona, never as an admin.**
7. **F1 — `Opportunity.Guidance_Cap_Rate__c` will still be empty** while its price twin is populated. One line to fix; deliberately not in S1's list (§8).
```
