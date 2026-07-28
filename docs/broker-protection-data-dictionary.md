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
| `Outcome__c` | Text | 255 | Routing outcome label (e.g., `New Lead (winner)`, `Competing Duplicate`, `Reply Thread`). |
| `Result_Record_Id__c` | Text | 18 | Lead/Opportunity/Contact Id — the routing outcome's target record. |
| `Processed_DateTime__c` | DateTime | — | When async processing completed. |
| `Error__c` | LongTextArea | 32,000 | Exception detail/stack trace when `Status__c = Error`. |

**Total: 16 fields**, matching the object's field-folder inventory verified at documentation time.

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
| `Is_Duplicate_Property__c` | Checkbox (default `false`) | Set by `ExtractAddressQueueable`/`PropertyClaimService` when this Lead's property was already claimed by an earlier broker submission. Kept for traceability only — this is a "dead" Lead. |
| `Duplicate_Of_Lead__c` | Lookup → Lead, `SetNull` | Points a duplicate Lead at its winner. Populated only when `Is_Duplicate_Property__c = true`. |
| `Property_Address__c` | Text(255) | **Pre-existing field, reused, not created by this feature.** Target of the LLM-extracted property address. |

---

## Task (Activity) fields — the RFC threading keys

Both deployed under `force-app/main/default/objects/Activity/fields/` (Task inherits Activity custom
fields in the Metadata API's file layout).

| Field | Type | Description |
|---|---|---|
| `Inbound_Message_Id__c` | Text(255), `externalId=true` | RFC Message-ID from the inbound email — idempotency key and reply threading. |
| `Thread_Key__c` | Text(255), `externalId=true` | RFC References root Message-ID — conversation threading key, shared across an entire email thread. |

Every inbound broker email is logged as one completed `Task` (`TaskSubtype = 'Email'`,
`Type = 'Email'`, `Status = 'Completed'`), attached via `WhoId` (Lead/Contact) or `WhatId` (everything
else, chosen by the target Id's own `SObjectType` — Task rejects a Lead Id on `WhatId`).

---

## Integration Credentials

| Credential | Type | Purpose |
|---|---|---|
| `OpenAI_Credential` | External Credential (Custom protocol) | Holds the OpenAI API key as a `NamedPrincipal` authentication parameter (`OpenAI_Principal`), referenced by an `Authorization: Bearer {!$Credential.OpenAI_Credential.API_Key}` `AuthHeader`. Key value entered in Setup post-deploy — never in metadata. |
| `OpenAI_API` | Named Credential (`SecuredEndpoint` → `https://api.openai.com`) | `allowMergeFieldsInHeader=true` (required, else the merge-field header is sent literally → 401). Points at `OpenAI_Credential` for authentication. |

---

## Permission Set

| Permission Set | Grants |
|---|---|
| `Broker_Protection_Access` | Object CRUD + `viewAllRecords` on `Property_Registry__c`, `Competing_Broker_Submission__c`, `Property_Claim_Lock__c`; object CRUD (private sharing, no `viewAllRecords`) on `Inbound_Email_Staging__c` and `Task`; FLS (read/edit) on every custom field this pipeline writes — the 4 Lead fields, the 2 Activity threading fields, all 9 `Competing_Broker_Submission__c` fields, all 16 `Inbound_Email_Staging__c` fields, and the 3 read-relevant `Property_Registry__c` fields; class access to `CompetingSubmissionController`; external-credential principal access for `OpenAI_Credential-OpenAI_Principal`. |

---

## Lightning Web Component

| Component | Location | Description |
|---|---|---|
| `competingBrokerSubmissions` | `force-app/main/default/lwc/competingBrokerSubmissions/` | Placed on `Lead_Record_Page`. Single reactive `@wire(getSubmissions, { leadId: '$recordId' })` against `CompetingSubmissionController`; renders a related-list-style table (Winner/Competing badge, broker/forwarded-by/address/submitted-time columns), error toast + graceful empty state. SLDS 2 tokens; Jest + `@sa11y/jest` test included. |
