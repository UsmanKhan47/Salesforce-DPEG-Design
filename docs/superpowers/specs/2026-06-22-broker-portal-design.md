# DPEG Broker Deal-Intake Portal — Design Spec

**Date:** 2026-06-22
**Status:** Approved design — pending implementation plan
**Module:** Acquisitions (DPEG)

## 1. Summary

A **public, no-login Experience Cloud (LWR) page** where outside brokers submit a property/deal to DPEG. The page hosts a single custom LWC form. On submit, a `without sharing` Apex controller validates the input, creates a `Lead`, stamps the protected/system fields server-side, flags possible duplicates, assigns the Lead to an internal queue (off the guest user), and inserts it. An after-save record-triggered Flow notifies the acquisitions team. The new Lead flows into the **existing Lead Funnel** automatically because it is stamped `LeadSource = 'Broker Portal'` — already a recognized intake channel in `LeadFunnelController`.

## 2. Locked decisions

| Decision | Choice |
|---|---|
| Access model | **Public guest form** (no login). Authenticated broker logins deferred. |
| Build approach | **Custom LWC + Apex** (consistent with the repo's ~14-LWC design system). |
| Post-submit | **On-screen confirmation** + **notify acquisitions team** + **flag likely duplicates**. No broker confirmation email (scratch-org email is unreliable). |
| Lead routing | New submissions assigned to a deployable **Queue `Broker_Portal_Leads`** (gets records off the guest user; required under "Secure guest user record access"). |
| Notification channel | **Custom Notification** (in-app bell) via record-triggered Flow — no dependency on outbound email deliverability or a pre-existing Chatter group. |

## 3. Data model context (verified against the org)

- **Lead = an inbound acquisition deal.** Display name in the funnel is `Property_Address__c` (falls back to person Name). `Broker_First__c` (Text) holds the broker/firm identity that drives the 90-day broker-protection window.
- **`LeadSource` already contains `'Broker Portal'`** (`standardValueSets/LeadSource`) — no picklist change needed. `LeadFunnelController` already groups this channel.
- Salesforce **requires `LastName` and `Company`** on every Lead, so the form must capture broker name + firm.
- **`First_Seen_Date__c`** (DateTime) is the immutable intake stamp that starts the 90-day window (`BP_Expiry__c` / `Days_in_System__c` derive from it). The portal stamps it to submission time.
- No Experience site or guest profile exists yet — both are net-new.

## 4. Form fields

### 4.1 Broker fills (deal)
| Form label | Lead field | Type | Required | Validation |
|---|---|---|---|---|
| Property Address | `Property_Address__c` | Text(255) | ✅ | non-blank, ≤255 |
| Asset Type | `Asset_Type__c` | Picklist | ✅ | must be an active picklist value |
| Deal Type | `Deal_Type__c` | Picklist (Land/Commercial) | — | valid value if provided |
| Guidance Price | `Guidance_Price__c` | Currency | ✅ | number > 0 |
| Guidance Cap Rate | `Guidance_Cap_Rate__c` | Percent | — | 0–100 if provided |
| CoStar Link | `CoStar_Link__c` | URL | — | http(s):// URL if provided |
| Deal Notes | `Deal_Notes__c` | Long Text | — | ≤32768 |

### 4.2 Broker fills (contact)
| Form label | Lead field | Type | Required | Validation |
|---|---|---|---|---|
| First Name | `FirstName` | Text | ✅ | non-blank |
| Last Name | `LastName` | Text | ✅ | non-blank (Salesforce-required) |
| Brokerage Firm | `Company` **and** `Broker_First__c` (mirrored) | Text | ✅ | non-blank |
| Email | `Email` | Email | ✅ | valid email format |
| Phone | `Phone` | Phone | — | — |

### 4.3 Stamped server-side (never accepted from the client)
- `LeadSource = 'Broker Portal'`
- `Status = 'New'`
- `First_Seen_Date__c = Datetime.now()`
- `OwnerId =` the `Broker_Portal_Leads` queue
- `Duplicate_Flag__c =` computed (see §6)

### 4.4 Left blank — internal only (not on the form)
`My_Price__c`, `My_Cap_Rate__c` (underwriting), `DPEG_First__c`, `Parse_Confidence__c`, `Disqualification_Reason__c`, `Placer_AI_Link__c`. Picklist options for Asset Type / Deal Type are read live from the org via Apex describe so they never drift.

## 5. Components to build

| Artifact | Type | Notes |
|---|---|---|
| `brokerDealIntakeForm` | **LWC** | Targets `lightningCommunity__Page` + `lightningCommunity__Default`. Form UI, client validation, calls Apex, renders confirmation state. Styled to DPEG tokens (`#032D60` header, `#1565C0` sub-header, `#2BAFAC` teal, Salesforce Sans) + DPEG logo. Includes a hidden honeypot field. |
| `BrokerPortalController` | **Apex** (`without sharing`) | `@AuraEnabled(cacheable=true) getFormMetadata()` → picklist options for Asset Type / Deal Type. `@AuraEnabled submitDeal(DealSubmission input)` → validate, build, stamp, dedup, assign, insert; returns a minimal `SubmitResult`. |
| `BrokerPortalControllerTest` | **Apex test** | See §9. |
| `Broker_Portal_Leads` | **Queue** | Supports Lead; owns new submissions. Admin adds members. |
| `Broker_Portal_New_Lead` | **CustomNotificationType** | In-app notification definition. |
| `Broker_Portal_New_Lead_Notify` | **Flow** (record-triggered, after-save) | Entry: `LeadSource = 'Broker Portal'` AND record is new. Action: Send Custom Notification to the `Broker_Portal_Leads` queue — title "New broker deal submitted", body "{FirstName} {LastName} ({Company}) — {Property_Address__c}", target = the Lead. |
| Guest profile permissions | **Profile** config | Lead Create; create-FLS on every written field; Apex class access to `BrokerPortalController`; component visibility. Configured once the site exists. |
| "DPEG Broker Portal" | **Experience site** (LWR) | Public/guest host (Setup — see §10). |

**Separation of concerns:** dedup is computed in **Apex** (deterministic + unit-testable); notification is in the **Flow** (runs in system context, so it can send the Custom Notification reliably — a guest user cannot).

## 6. Apex contract & logic

### 6.1 DTOs
```
public class DealSubmission {
    // contact
    public String firstName;      // → FirstName (required)
    public String lastName;       // → LastName  (required)
    public String brokerageFirm;  // → Company + Broker_First__c (required)
    public String email;          // → Email (required)
    public String phone;          // → Phone
    // deal
    public String propertyAddress;// → Property_Address__c (required)
    public String assetType;      // → Asset_Type__c (required, validated)
    public String dealType;       // → Deal_Type__c (validated if present)
    public Decimal guidancePrice; // → Guidance_Price__c (required, > 0)
    public Decimal guidanceCapRate;// → Guidance_Cap_Rate__c (0–100 if present)
    public String coStarLink;     // → CoStar_Link__c (URL if present)
    public String dealNotes;      // → Deal_Notes__c
    // anti-spam
    public String website;        // honeypot — must be blank
}

public class SubmitResult {
    public Boolean success;
    public String message;        // generic confirmation/error text — NO internal data leaked
}
```
The result intentionally **does not return** the Lead Id or duplicate status — nothing internal is exposed to a public client.

### 6.2 `submitDeal` flow
1. **Honeypot:** if `website` is non-blank → skip insert, return a normal-looking success (do not reveal to bots).
2. **Validate** all required fields + formats server-side (never trust the client). On failure → `AuraHandledException` with a safe message.
3. **Build** the `Lead` from the whitelisted fields only. Any client-supplied `LeadSource` / `Status` / `OwnerId` is **ignored**.
4. **Stamp** `LeadSource='Broker Portal'`, `Status='New'`, `First_Seen_Date__c=Datetime.now()`, `Company`/`Broker_First__c` = firm, `OwnerId` = `Broker_Portal_Leads` queue Id (resolved by `DeveloperName`).
5. **Dedup:** query open Leads — `Status NOT IN ('Converted','Disqualified')` AND `Property_Address__c = :propertyAddress.trim()` (SOQL string equality is case-insensitive). If any exist → `Duplicate_Flag__c = true`.
6. **Insert** in a try/catch; on DML error → safe `AuraHandledException`.
7. Return `SubmitResult{ success=true, message="Thank you — we've received your deal." }`.

## 7. Security & guest hardening
- Controller is `without sharing` (guest user needs to insert a Lead it won't own) and **whitelists** input — system/protected fields are set in Apex only.
- New Lead is **assigned to the `Broker_Portal_Leads` queue at insert**, never left owned by the guest user. Required so internal staff can see it under **"Secure guest user record access."**
- Server-side re-validation of every required field + email/URL/number formats.
- **Honeypot** hidden field for cheap bot rejection (no CAPTCHA in v1).
- Guest profile grants the **minimum**: Lead Create + create-FLS on exactly the written fields + Apex class access. No read access to other records.

## 8. UX, post-submit & error handling
- **Confirmation state:** on success the form is replaced by "Thank you — we've received your deal." + a **Submit another** button that resets the form.
- **Notification:** the after-save Flow sends the Custom Notification to the queue so the acquisitions team is alerted in-app.
- **Duplicate flag:** `Duplicate_Flag__c` set server-side when an open Lead already has the same Property Address; surfaces to internal triage only (the broker is not told).
- **Error handling:** inline per-field validation messages; submit button disabled + spinner during the call; a friendly error banner if Apex throws; controller throws `AuraHandledException` with safe text and never leaks internal details.

## 9. Testing

`BrokerPortalControllerTest` (Apex):
- **Happy path:** valid `DealSubmission` → one Lead inserted; assert `LeadSource='Broker Portal'`, `Status='New'`, `First_Seen_Date__c` set, `Company`/`Broker_First__c` = firm, `OwnerId` = the queue (≠ running user).
- **Required-field rejection:** blank `lastName` / `brokerageFirm` / `propertyAddress` / `email`, or null `guidancePrice` → `AuraHandledException`, no Lead inserted.
- **Format rejection:** invalid email; non-http CoStar link; `guidancePrice <= 0`; cap rate out of 0–100.
- **Invalid picklist:** unknown `assetType` / `dealType` → rejected.
- **Honeypot:** `website` non-blank → no Lead inserted, benign success returned.
- **Dedup:** pre-insert an *open* Lead with the same address → new Lead `Duplicate_Flag__c=true`; different address → false; a `Converted`/`Disqualified` Lead with the same address is **not** treated as a duplicate.
- **Client-override ignored:** payload attempts `LeadSource='Web'` / `Status='Qualified'` / a bogus owner → record is still `'Broker Portal'` / `'New'` / queue-owned.
- **`getFormMetadata`:** returns non-empty Asset Type options containing known values (e.g. Retail, Land).

Optional `brokerDealIntakeForm` Jest test: renders all fields, blocks submit when required fields are empty, calls Apex with the expected payload, shows the confirmation state on success.

## 10. Manual Setup vs. deployable

**Manual (Setup UI) — cannot be done purely from metadata when starting from zero:**
1. Enable **Digital Experiences** and set the Experiences domain.
2. Create the LWR site **"DPEG Broker Portal"** (Build Your Own (LWR) template).
3. Activate/publish the site; record the public URL.
4. In **Experience Builder**, add the `brokerDealIntakeForm` component to the page and publish.
5. In **Public Access Settings / guest profile**, confirm Lead Create + field create-access + Apex class access (deploy where possible; verify in Builder).
6. Add members to the **`Broker_Portal_Leads`** queue.
7. Confirm **"Secure guest user record access"** is enabled (default) — owner reassignment handles visibility.

**Deployable by Claude:** the LWC, Apex + test, the Queue, the CustomNotificationType, the notify Flow, and the guest profile field/object/Apex permissions (once the site exists). The `'Broker Portal'` LeadSource value already exists.

## 11. Out of scope (deferred to later phases)
- Authenticated broker logins (community users tied to Contacts under Broker Firm accounts).
- Broker confirmation email (depends on scratch-org outbound email).
- CAPTCHA / advanced spam protection (honeypot only in v1).
- Fuzzy/normalized address matching for duplicate detection (v1 is trimmed, case-insensitive exact match).
- File / offering-memo upload.
- Auto-creating or matching a broker **Contact** record (v1 stores broker identity on the Lead only).
