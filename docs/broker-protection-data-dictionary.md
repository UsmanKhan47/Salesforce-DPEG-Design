# Broker Protection — Data Dictionary

**Date:** 2026-07-28
**Author:** Documentation Agent

All field lengths, types, and descriptions below were read directly from the deployed
`.field-meta.xml` / `.object-meta.xml` source under `force-app/main/default/objects/`.

---

## `Inbound_Email_Staging__c`

**Label:** Inbound Email Staging · **Name field:** AutoNumber `IES-{0000000}` · **Sharing:** Private
**Description:** "Durable landing record for every inbound broker email processed by the Email
Service. Captures raw email content, headers, and attachment metadata for async processing and audit
trail."

| Field | Type | Length | Description |
|---|---|---|---|
| `From_Name__c` | Text | 255 | Sender display name from the envelope. |
| `From_Address__c` | Email | — (standard 80) | Envelope From address (broker in auto-forward). |
| `Subject__c` | Text | 255 | Inbound email subject, verbatim. |
| `Raw_Body__c` | LongTextArea | 131,072 | Full raw body of the inbound broker email as received, before any parsing or extraction. |
| `Raw_Headers__c` | LongTextArea | 131,072 | All RFC headers, one per line — captured whole and unparsed. |
| `Message_Id__c` | Text | 255 | RFC Message-ID for idempotency and threading. |
| `In_Reply_To__c` | Text | 255 | RFC In-Reply-To header for reply threading. |
| `References__c` | LongTextArea | 32,768 | RFC References header for conversation threading. |
| `Forwarded_By__c` | Email | — | The monitored inbox that auto-forwarded this email (internal user email). |
| `Has_Image__c` | Checkbox (default `false`) | — | True if an image attachment was found. |
| `Image_Mime_Type__c` | Text | 255 | MIME type of the image (e.g., `image/png`). |
| `Status__c` | Picklist (restricted) | — | `Pending` (default) / `Processed` / `Error`. |
| `Outcome__c` | Text | 255 | Routing outcome label (e.g., `New Lead (winner)`, `Competing Submission`, `Reply Thread`). **Three eras of labels can coexist in this org** — see "Outcome label history" below. |
| `Result_Record_Id__c` | Text | 18 | Lead/Opportunity/Contact Id — the routing outcome's target record. |
| `Processed_DateTime__c` | DateTime | — | When async processing completed. |
| `Error__c` | LongTextArea | 32,000 | Exception detail/stack trace when `Status__c = Error`. |
| `Extracted_JSON__c` *(added 2026-07-31)* | LongTextArea | 131,072 | The LLM's response **verbatim**, written before any routing decision (D3 tier 1) — survives every branch, including the ones that create no Lead. Never blank on a routed row: a skipped callout (reply, pre-filter) writes a `{"skipped":"..."}` marker instead. See `docs/2026-07-31-llm-field-extraction.md`. |
| `Routed_Record_Ids__c` *(added 2026-07-31)* | LongTextArea | 32,768 | One line per routed property, in processing order: `<normalized address> \| <outcome> \| <recordId>`. The only place a multi-property email's full N-result mapping exists. Null for single-result emails (`Result_Record_Id__c` already describes those completely). |
| `Property_Count__c` *(added 2026-07-31)* | Number | 3,0 | Properties the extraction **found**, pre-truncation. When this exceeds the number of lines in `Routed_Record_Ids__c`, the difference IS the truncation signal (`MAX_PROPERTIES = 10`). |

**Total: 19 fields**, matching the object's field-folder inventory verified at documentation time
(16 at the 2026-07-28 staging-model rework + 3 added 2026-07-31 for the LLM field-extraction
enrichment).

### Outcome label history (three eras)

`Outcome__c` is free Text, not a picklist, so nothing enforces one label vocabulary over time. Rows in
this org can legitimately carry any of these, depending on when they were processed:

| Label | Era | Meaning |
|---|---|---|
| `Competing Duplicate` | Pre-2026-07-31 | A different broker's email created a **duplicate-flagged Lead** (`Is_Duplicate_Property__c = true`, `Duplicate_Of_Lead__c` = winner). |
| `Competing Duplicate (race)` | Pre-2026-07-31 — **never actually written** | Documented in the original design as the lost-race label, but no code path ever produced it; every race loss reconciled to the plain `Competing Duplicate` label instead. |
| `Competing Submission` | 2026-07-31 onward | Branch (d): a different broker's email produced **no Lead** — only a non-winning `Competing_Broker_Submission__c` (`Source_Lead__c = null`) against the winner. |
| `Competing Submission (race)` | 2026-07-31 onward | Branch (e)'s lost-race tail: a Lead **was** briefly created, then deleted once the claim discovered a concurrent winner. The only outcome shape where a Lead existed and was removed. |

**Per decision C-11, history is deliberately NOT back-filled.** `Inbound_Email_Staging__c` is an audit
trail of what the pipeline actually did at the time it ran — rewriting old `Competing Duplicate` rows
to `Competing Submission` would misreport that a Lead was never created when in fact one was (and still
exists, duplicate-flagged, on the Lead object). When filtering or reporting on this field, match on
**both** the current and retired labels for a given era's meaning; do not assume `Competing Duplicate`
rows are absent from a mature org. See `docs/2026-07-31-competing-broker-no-lead.md` for the full
change writeup.

---

## `Property_Registry__c` — the claim ledger

**Sharing:** ReadWrite

| Field | Type | Notes |
|---|---|---|
| `Property_Key__c` | Text(255), **unique, case-insensitive, `externalId=true`, required** | The atomic claim key — normalized property address. Database-level race-safety backstop for exact-match collisions. |
| `Normalized_Address__c` | Text(255) | Same normalized address, stored for fuzzy-match comparison. |
| `Winning_Lead__c` | Lookup → Lead, `SetNull` | The Lead currently holding this claim. Null when the winner was deleted (an orphaned registration). |
| `Registered_DateTime__c` | DateTime | When the claim was registered (claim time, not the email's send time). §1 rule 6/9 conformant — never suffixed `_Date`. |

Validation rule `Winning_Lead_Required` (`AND(ISNEW(), ISBLANK(Winning_Lead__c))`) is the insert-scoped
stand-in for "required" on a lookup that must be `SetNull`.

---

## `Competing_Broker_Submission__c` — the audit trail

**Sharing:** ReadWrite · **Deliberately not master-detail** on `Winning_Lead__c`/`Source_Lead__c` —
cascade delete would silently wipe this audit trail.

| Field | Type | Notes |
|---|---|---|
| `Winning_Lead__c` | Lookup → Lead, `SetNull` | The Lead that holds the claim this submission was logged against. |
| `Source_Lead__c` | Lookup → Lead, `SetNull` | The Lead this specific inbound email produced (equals `Winning_Lead__c` for the winning submission). |
| `Broker_Name__c` | Text(255) | LLM/regex-extracted broker display name. |
| `Broker_Email__c` | Email | LLM/regex-extracted broker email. |
| `Email_Subject__c` | Text(255) | The inbound email subject. |
| `Forwarded_By_Email__c` | Email | The internal forwarder's / monitored inbox's email. |
| `Property_Address_Raw__c` | Text(255) | The raw (un-normalized) extracted address, for display. |
| `Submitted_DateTime__c` | DateTime | The email's original send time (LLM `sent_datetime`, parsed; defaults to `now()` if unparseable). |
| `Is_Winning_Submission__c` | Checkbox (default `false`) | `true` for exactly the one submission that registered the winning claim. |

Validation rule `Winning_Lead_Required` — same formula/rationale as `Property_Registry__c`.

---

## `Property_Claim_Lock__c` — the concurrency-control partition object

**Not a business object** — a pure lock partition. `allowDelete=false`.

| Field | Type | Notes |
|---|---|---|
| `Cluster_Key__c` | Text(255), unique, `externalId=true`, required | Coarse address-cluster bucket key (street number + first alphabetic street-name token) — the `FOR UPDATE` lock partition. |

---

## Lead fields

| Field | Type | Description |
|---|---|---|
| `Email_Subject__c` | Text(255) | Subject line of the inbound broker email that created this Lead. |
| `Forwarded_By_Email__c` | Email | The internal forwarder's email address captured from the inbound email envelope. Named `_Email` (not `_By__c`) so it is not mistaken for a §1 role-lookup. |
| `Is_Duplicate_Property__c` | Checkbox (default `false`) | **LEGACY as of 2026-07-31** — no longer written by any code path. Formerly set by `ExtractAddressQueueable`/`PropertyClaimService` when this Lead's property was already claimed by an earlier broker submission. A competing broker no longer receives a Lead to flag; retained for historical data only. |
| `Duplicate_Of_Lead__c` | Lookup → Lead, `SetNull` | **LEGACY as of 2026-07-31** — no longer written by any code path. Formerly populated only when `Is_Duplicate_Property__c = true`. Retained for historical data only. |
| `Property_Address__c` | Text(255) | **Pre-existing field, reused, not created by this feature.** Target of the LLM-extracted property address. |

### Deal-screening fields (19 new, added 2026-07-31 — LLM Field Extraction Enrichment)

Populated by `LLMExtractionParser` from the LLM's per-property JSON (see
`docs/2026-07-31-llm-field-extraction.md` for the full JSON contract). Every field is `required=false`,
`trackFeedHistory=false`, carries a populated `<description>` + inline help text, and is nulled (never
thrown on) by the parser when the model's value is missing or fails validation — a rejection note is
appended to `Deal_Notes__c` instead.

| Field | Type | LLM key | Notes |
|---|---|---|---|
| `Property_Name__c` | Text(255) | `property_name` | The marketed name (e.g. "Royal Inn") — the matching signal for a name-only deal with no street address. |
| `NOI__c` | Currency(18,2) | `noi` | Net operating income. When the email quotes both a reported and adjusted figure, the ADJUSTED one lands here; both are noted in `Deal_Notes__c`. |
| `Occupancy_Pct__c` | **Percent(5,2)** | `occupancy_pct` | A PERCENTAGE number (88.0, never 0.88) — Percent(5,2), not the spec's originally proposed (3,2), which caps at 9.99% and cannot hold 88.00. |
| `Building_SF__c` | Number(18,0) | `building_sf` | Rentable building area. |
| `Unit_Count__c` | Number(18,0) | `unit_count` | Apartment units, **or hotel keys for a hospitality asset** (help text says so explicitly). |
| `Offer_Due_Date__c` | Date | `offer_due_date` | Call-for-offers deadline. Relative phrasing ("offers due today") is resolved by the PROMPT against `sent_datetime`, never by Apex. |
| `Sale_Process__c` | Picklist (restricted) | `sale_process` | Off-Market / On-Market Listing / Call for Offers / Auction. |
| `Guidance_Price_Low__c` | Currency(18,2) | `guidance_price_low` | Bottom of a quoted price RANGE. Matches the existing `Guidance_Price__c`'s precision. |
| `Guidance_Price_High__c` | Currency(18,2) | `guidance_price_high` | Top of a quoted price RANGE. |
| `Year_Built__c` | Number(4,0) | `year_built` | Apex expands a 2-digit year ('88'→1988, '22'→2022, pivoting on the current 2-digit year). |
| `Year_Renovated__c` | Number(4,0) | `year_renovated` | Same 2-digit expansion as `Year_Built__c`. |
| `Lot_Size_Acres__c` | Number(10,2) | `lot_size_acres` / `lot_size_sf` | Canonicalized to ACRES. The model reports whichever unit the email stated; Apex — never the model — converts sq ft ÷ 43,560 when only `lot_size_sf` is present. |
| `WALT_Years__c` | Number(4,1) | `walt_years` | Weighted average lease term remaining. |
| `ADR__c` | Currency(10,2) | `adr` | Average daily rate — hospitality only. |
| `Zoning__c` | Text(100) | `zoning` | Zoning designation as quoted. |
| `Seller_Entity__c` | Text(255) | `seller_entity` | The selling ownership entity. |
| `Deal_Room_Link__c` | URL(255) | `deal_room_link` | Deal room / OM download link. **Never clipped** — a truncated URL is a broken link that still looks valid, so an over-length one is nulled instead. |
| `Listing_Broker_Name__c` | Text(120) | `listing_broker_name` | The listing broker, when the SENDER of the email is not the broker (blast/marketing platforms). NOT a claim-engine input. |
| `Listing_Broker_Email__c` | Email | `listing_broker_email` | Same as above. NOT a claim-engine input — the claim engine reads only `broker_email`. |

`Asset_Type__c` (pre-existing, restricted picklist) gained 2 new values, **`Hospitality`** and
**`Medical Office`**, added on both `Lead.Asset_Type__c` and `Property__c.Asset_Type__c` in the same
change — `LeadConvertService.buildProperty` copies the Lead's value onto `Property__c` only if it
already exists on `Property__c`'s restricted picklist, so omitting the `Property__c` side would have
silently dropped the asset type for exactly these two values at conversion.

**Existing Lead fields the extraction newly populates** (no metadata change, but their write source
changed): `Company` (now `broker_company` when non-blank, else the original `'Unknown - Via Email'`
placeholder — `Company` is required and is never written blank), `Phone` / `MobilePhone` / `Title`,
`Guidance_Price__c`, `Guidance_Cap_Rate__c`, `Asset_Type__c`, `Deal_Type__c`, `Deal_Notes__c` (the
model's narrative + spillover "additional properties" block + the parser's rejection notes, in that
order), and `Parse_Confidence__c` (existed before but was unused until this change — see "Outcome
label history" above for how its `LOW` band feeds the `Review_Queue` list view).

---

## Task (Activity) fields — the RFC threading keys

Both deployed under `force-app/main/default/objects/Activity/fields/` (Task inherits Activity custom
fields in the Metadata API's file layout).

| Field | Type | Description |
|---|---|---|
| `Inbound_Message_Id__c` | Text(255), `externalId=true` | RFC Message-ID from the inbound email — idempotency key and reply threading. |
| `Thread_Key__c` | Text(255), `externalId=true` | RFC References root Message-ID — conversation threading key, shared across an entire email thread. |

Every inbound broker email is logged as one completed `Task` (`TaskSubtype = 'Email'`,
`Status = 'Completed'`), attached via `WhoId` (Lead/Contact) or `WhatId` (everything
else, chosen by the target Id's own `SObjectType` — Task rejects a Lead Id on `WhatId`).

⚠ **`Task.Type` is never set, and must never be.** It does not exist in this org's `FieldDefinition`
(Apex compiles a `Type` assignment regardless and only fails at runtime), which is not a hypothetical
— it took down the first two real inbound emails in `usman-dpeg` on 2026-07-31 before being
diagnosed and removed. See `InboundEmailActivityService`'s class header for the full root-cause
writeup, and `docs/2026-07-31-llm-field-extraction.md` for the operational summary.

Since 2026-07-31 (D1 multi-property), one inbound email can log a Task on **several** distinct
records in a single bulk `insert` — see `docs/2026-07-31-llm-field-extraction.md` for the ordering
rule (ascending priority, so a later reply resolves onto the correct record) and why N Tasks sharing
one `Inbound_Message_Id__c` is safe.

Since 2026-08-04, `Subject` and `Description` (both standard fields, not listed above) also carry the
resolved broker identity: `Subject` gets a head-preserving `From <sender>: ` prefix ahead of the
original subject (the sender is clipped to 60 chars first, so it can never be truncated away), and
`Description` gets a `From:` / `Subject:` / 60-hyphen-rule header block — with the full, untruncated
subject — ahead of the raw body. `Task.Subject` is deliberately **not** a matching key anywhere in
this repo; see `docs/2026-08-04-broker-attribution-on-pipeline-tasks.md` and `ARCHITECTURE.md` §2 for
the full contract, including why this does not fix the "You sent an email" timeline chrome.

---

## Integration Credentials

| Credential | Type | Purpose |
|---|---|---|
| `OpenAI_Credential` | External Credential (Custom protocol) | Holds the OpenAI API key as a `NamedPrincipal` authentication parameter (`OpenAI_Principal`), referenced by an `Authorization: Bearer {!$Credential.OpenAI_Credential.API_Key}` `AuthHeader`. Key value entered in Setup post-deploy — never in metadata. |
| `OpenAI_API` | Named Credential (`SecuredEndpoint` → `https://api.openai.com`) | `allowMergeFieldsInHeader=true` (required, else the merge-field header is sent literally → 401). Points at `OpenAI_Credential` for authentication. |

---

## Permission Sets

| Permission Set | Grants |
|---|---|
| `Broker_Protection_Access` | Object CRUD + `viewAllRecords` on `Property_Registry__c`, `Competing_Broker_Submission__c`, `Property_Claim_Lock__c`; object CRUD (private sharing, no `viewAllRecords`) on `Inbound_Email_Staging__c` and `Task`; FLS (read/edit) on every custom field this pipeline writes — the 4 original Lead fields, the 2 Activity threading fields, all 9 `Competing_Broker_Submission__c` fields, all 19 `Inbound_Email_Staging__c` fields, the 3 read-relevant `Property_Registry__c` fields, **and (2026-07-31) all 19 new deal-screening Lead fields**; class access to `CompetingSubmissionController`; external-credential principal access for `OpenAI_Credential-OpenAI_Principal`. |
| `DPEG_Acquisition_View` *(2026-07-31)* | The 19 new deal-screening Lead fields, **read-only** (readable=true, editable=false). |
| `DPEG_Acquisition_Edit` *(2026-07-31)* | The 19 new deal-screening Lead fields, read + edit. |
| `DPEG_Acquisitions` *(2026-07-31)* | The 19 new deal-screening Lead fields, read + edit (matches its sibling deal-screening fields already on this set: `Asset_Type__c`, `Guidance_Price__c`, `Guidance_Cap_Rate__c`, `Deal_Notes__c`, `Deal_Type__c`, `Parse_Confidence__c`). |

**Why four permission sets, not one:** the sibling deal-screening Lead fields
(`Asset_Type__c`, `Guidance_Price__c`, `Guidance_Cap_Rate__c`, `Deal_Notes__c`, `Deal_Type__c`,
`Parse_Confidence__c`) already live in the three `DPEG_Acquisition*` sets, not in
`Broker_Protection_Access`. Granting FLS only on `Broker_Protection_Access` would leave the 19 new
fields invisible to the acquisitions personas who actually work these Leads — and because profiles
are `.forceignore`d, **an admin acceptance test would not catch this gap** (System Administrator
bypasses FLS entirely). UAT for this feature must be run as a real acquisitions persona, not an
admin.

---

## Lightning Web Component

| Component | Location | Description |
|---|---|---|
| `competingBrokerSubmissions` | `force-app/main/default/lwc/competingBrokerSubmissions/` | Placed on `Lead_Record_Page`. Single reactive `@wire(getSubmissions, { leadId: '$recordId' })` against `CompetingSubmissionController`; renders a related-list-style table (Winner/Competing badge, broker/forwarded-by/address/submitted-time columns), error toast + graceful empty state. SLDS 2 tokens; Jest + `@sa11y/jest` test included. |
