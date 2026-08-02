# LLM Field Extraction Enrichment — Requirements Spec (2026-07-31)

User-approved scope and decisions for enriching the Broker Protection inbound-email pipeline:
extract the full deal-screening field set from broker emails via the LLM, gate out
non-acquisition emails, and support multiple properties per email. Source analysis: the
2026-07-30 review of `Acquisition-Emails.pdf` against the Lead object (19 missing fields + 2
picklist values identified, "Comprehensive" scope approved by the user).

## User decisions (final — do not re-litigate)

| # | Decision | Choice |
|---|---|---|
| D1 | Multi-property emails | **One Lead per property.** Extraction returns an array of properties; the pipeline claims each property separately — N Leads / N registry claims can result from one email (e.g. the Bracket blast carrying both Royal Inn AND Bass Inn). |
| D2 | Relevance gate | **Tiered.** Confident not-acquisition → NO Lead, staging outcome records it (audit only). Unsure / low confidence → CREATE the Lead, mark `Parse_Confidence__c = LOW` for human review. LLM outage → create (the standing "outage = missing optional input, never a lost email" rule survives). |
| D3 | Storage | **Two-tier.** Raw LLM response JSON stored VERBATIM in a new `Inbound_Email_Staging__c.Extracted_JSON__c` (LongTextArea); typed, Apex-validated values land only on the Lead. Extraction survives on the staging row even for branches that create no Lead (Reply/Repeat/Competing/not-acquisition). |
| D4 | Build scope | **Fields + prompt + gate in this iteration.** PDF-attachment (OM) parsing deferred. |

## New metadata

### Lead — 19 new custom fields (per ARCHITECTURE.md §1 naming; all verified conformant)

| Field | Type | Populated from LLM key |
|---|---|---|
| `Property_Name__c` | Text(255) | `property_name` |
| `NOI__c` | Currency(16,2) | `noi` |
| `Occupancy_Pct__c` | Percent(3,2) | `occupancy_pct` |
| `Building_SF__c` | Number(18,0) | `building_sf` |
| `Unit_Count__c` | Number(18,0) | `unit_count` (units or hotel keys — help text says so) |
| `Offer_Due_Date__c` | Date | `offer_due_date` |
| `Sale_Process__c` | Picklist: Off-Market, On-Market Listing, Call for Offers, Auction | `sale_process` |
| `Guidance_Price_Low__c` | Currency(16,2) | `guidance_price_low` |
| `Guidance_Price_High__c` | Currency(16,2) | `guidance_price_high` |
| `Year_Built__c` | Number(4,0) | `year_built` |
| `Year_Renovated__c` | Number(4,0) | `year_renovated` |
| `Lot_Size_Acres__c` | Number(10,2) | `lot_size_acres` (SF→acres conversion in Apex) |
| `WALT_Years__c` | Number(4,1) | `walt_years` |
| `ADR__c` | Currency(10,2) | `adr` (hospitality only) |
| `Zoning__c` | Text(100) | `zoning` |
| `Seller_Entity__c` | Text(255) | `seller_entity` |
| `Deal_Room_Link__c` | URL | `deal_room_link` |
| `Listing_Broker_Name__c` | Text(120) | `listing_broker_name` (blast-platform emails where sender ≠ broker) |
| `Listing_Broker_Email__c` | Email | `listing_broker_email` |

### Existing Lead fields the extraction newly populates

`Company` (today hardcoded "Unknown - Via Email" → `broker_company`), `Phone`/`MobilePhone`
(`broker_phone`/`broker_mobile`), `Title` (`broker_title`), `Guidance_Price__c`
(`guidance_price`), `Guidance_Cap_Rate__c` (`cap_rate`), `Asset_Type__c` (`asset_type`),
`Deal_Type__c` (`deal_type`), `Deal_Notes__c` (`deal_summary` — the narrative: roof/lien/tenant
detail, future NOI notes, additional-property spillover), `Parse_Confidence__c` (`confidence` —
field exists today, unused by the pipeline).

### Picklist additions

`Asset_Type__c` (restricted): add **Hospitality** and **Medical Office**.

### Inbound_Email_Staging__c — 1 new field

`Extracted_JSON__c` LongTextArea(131072) — the LLM response verbatim, written before any
routing decision. Plus whatever new Outcome label(s) the design settles for the
not-acquisition branch (Outcome__c is free Text — no picklist work).

## LLM prompt / extraction contract

- Response is a strict JSON object: email-level keys (`email_category`,
  `is_acquisition_related`, `confidence`, broker identity block, `deal_summary`) plus a
  `properties` ARRAY — each element carries the per-property keys (name, address, asset_type,
  metrics, financials, process). One property = array of one. The current 4-key contract
  (broker_name, broker_email, property_address, sent_datetime) must remain derivable for
  backward compatibility during rollout.
- `email_category` closed set (e.g.): acquisition_deal, call_for_offers, reply,
  system_notification, newsletter, out_of_office, other.
- Anti-hallucination rules in the prompt: null when absent; never derive one number from
  another (no price-from-cap-rate); numbers normalized to plain numerics ("$7.1M" → 7100000,
  "88/22" years → 1988/2022); closed-set fields must be one of the listed values or null;
  reported-vs-adjusted NOI → prefer adjusted, note both in deal_summary; "offers due TODAY"
  resolves against sent_datetime; auction date ranges → start date.
- Apex owns validation/parsing of everything the LLM returns (strict schema check, clip via
  InboundEmailFieldUtil, unparseable → null + deal_summary note; never a crash).

## Routing-tree impact (D1 + D2)

- New earliest gate: confident `is_acquisition_related = false` → stamp staging outcome, store
  JSON, NO Lead, no claim. (Today's two Gmail forwarding-confirmation junk Leads are the
  canonical prevented case.) Tiered per D2 — unsure creates with LOW confidence.
- Reply detection stays email-level (thread precedes everything).
- Per-property loop for Repeat/Duplicate/Winner claims. Design must solve: cluster-lock
  ORDERING across multiple `Property_Claim_Lock__c` acquisitions in one transaction (sort keys
  to prevent deadlock between concurrent multi-property emails), Task logging shape (one Task
  per routed record vs one per email), staging outcome/Result_Record_Id semantics when one
  email yields N results, and governor headroom (N claims + N Leads + N submissions in one
  queueable execution; the per-transaction-singleton bulk exemption may need revisiting).

## Edge-case register (design must address each)

Non-acquisition system emails (forwarding confirmations, out-of-office, newsletters) —
deterministic pre-filters worth considering before the LLM (noreply sender patterns); unpriced
deals ("Market to Establish") → nulls; price ranges; no-street-address deals (name-only —
`Property_Name__c` doubles as matching signal); image-only flyers (vision path exists); sender ≠
listing broker (blast platforms); team senders (3 names, one shared reply address); manual-vs
auto-forward broker attribution (existing envelope-fallback rules incl. the N2 residual);
LLM outage → regex fallback path must still create (D2); token/response-size limits with the
bigger prompt; org gotchas: Task.Type does NOT exist in usman-dpeg (never write it),
Asset_Type__c is a restricted picklist (values must deploy before any code writes them),
metadata-deployed fields have NO FLS until permission sets grant it (Broker_Protection_Access
must add all 20 new fields).

## Explicitly deferred

PDF/OM attachment parsing; CoStar/Placer link auto-population; any change to conversion mapping
(`LeadConvertService`) for the new fields — Leads carry them; carrying them onto
Opportunity/Property__c at conversion is a separate piece unless design finds it trivial.
