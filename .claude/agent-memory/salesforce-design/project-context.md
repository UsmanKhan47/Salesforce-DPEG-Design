# DPEG — Project Context (seed memory for salesforce-design agent)

> **Purpose:** Baseline context that Design Agent should assume without re-asking the user.
> Update this file when product direction, stakeholders, or the data model changes.

---

## Business Domain

**DPEG (Dhanani Private Equity Group)** is a commercial real estate private equity firm. This Salesforce CRM implementation fully manages four business processes:

1. **Acquisitions** — Deal sourcing from broker email/web intake through underwriting, principal approval, and contract execution (Junior's pipeline).
2. **Transaction Management** — Contract-to-closing lifecycle tracking with critical date alerts, vendor management, and loan tracking (Danish's 60-step checklist replaced).
3. **Disposition** — Sale of owned assets from sell-meter trigger through broker BOV, offer tracking, and proceeds distribution (Ali/Principals decision).
4. **Investor Relations (IR)** — Full replacement of AppFolio Investment Manager — investor onboarding, commitments, Plaid ACH distributions, Experience Cloud portal (Faiz/Simon's domain).

End users: Junior (Acquisitions), Danish (Transaction), Faiz (IR Manager), Simon (IR Associate), Ali (CFO/Finance), Nikil + Nick Sr. (Principals), and investor portal users (all active investors).

---

## Stakeholder Vocabulary

| Term | Meaning in DPEG |
|---|---|
| **Broker** | Commercial real estate broker who sources deals for DPEG. Represented as Account (firm) + Contact (individual). |
| **Offering** | A capital raise tied to a property deal — investors commit to an Offering. `Offering__c` object. |
| **Commitment** | An investor's pledge to invest in an Offering before wires are sent. `Commitment__c` object. |
| **Investment** | A confirmed, funded position in an Offering. Created from a Commitment when Plaid confirms receipt. `Investment__c` object. |
| **Investing Entity** | The investor's legal entity (LLC, Trust, Corp, Individual) — stored as an Account (`Account_Type__c = 'Investing Entity'`). |
| **Investor Person** | The individual investor or co-signer — stored as a Contact linked to an Investing Entity. |
| **Investor__c** | Custom profile record that joins a Contact to their portfolio summary (total committed, funded, distributed). |
| **Investing_Entity_Contact__c** | Junction object linking a Contact to an Account (Investing Entity) as Primary or Secondary signer. |
| **Distribution** | An ACH payment from DPEG to an investor for returns. `Distribution__c` object; executed via Plaid through ASB. |
| **Contribution** | An incoming wire/ACH from an investor — Plaid-matched against a Commitment. `Contribution__c` object. |
| **Share Transfer** | Investor-to-investor transfer of investment units. `Share_Transfer__c` object. Requires IR + Principal approval. |
| **Sell Meter** | Formula field (`GREEN/YELLOW/RED`) on `Disposition__c` — triggers principal sell decision when GREEN. |
| **ASB** | Avanza Service Bus — Avanza's managed middleware. ALL external integrations route through ASB. Never direct SF-to-external. |
| **Plaid** | Universal bank integration layer for ACH distributions and contribution wire matching. Credentials stored in ASB, not Salesforce. |
| **AppFolio** | The legacy IR system being replaced. All historical data migrated before Phase 5 go-live. |
| **Principal Approval** | Two-of-three vote from Nikil, Ali, Nick Sr. Implemented as Salesforce Approval Process. |
| **Broker Protection** | Logic preventing a broker from being cut out of a deal they sourced. Operates at Account (firm) level. |
| **BOV** | Broker Opinion of Value — disposition-stage responses logged as `BOV_Response__c`. |
| **KYC** | Know Your Customer — accreditation verification step in investor onboarding. |
| **Critical Date** | Key milestone date on a Transaction (Feasibility End, Hard Money, Closing). `Critical_Date__c` object with alert thresholds. |

---

## Object Conversion Chain (Canonical — Never Skip)

```
Lead (Broker deal)
  → Conversion 1: Opportunity + Account (Broker Firm) + Contact (Broker Person)  [Junior converts]
      → Conversion 2: Transaction__c  [Contract_Signed__c = TRUE — auto Flow]
      → Conversion 3: Offering__c  [simultaneous with #2 — auto Flow]
          → Conversion 4: Property_Asset__c (AUM)  [Transaction stage = Closed Won]
              → Conversion 5: Disposition__c  [Principal sell decision]
                  → Conversion 6: Property_Asset__c.Status = Disposed  [sale close]

Lead (IR investor form — Web-to-Lead)
  → Conversion 7: Account (Investing Entity) + Contact (Investor Person) + Investor__c
      → Commitment__c → Conversion 8: Investment__c  [Plaid confirms full wire]
          → Distribution__c, Contribution__c
          → Share_Transfer__c → Conversion 9: Updated + New Investment__c  [transfer approved]
```

---

## Stakeholder Roles & Decision Scope

| Stakeholder | Role | Decision Scope |
|---|---|---|
| Junior | Acquisitions Lead | Lead qualification, broker management, underwriting entry, principal approval request |
| Danish | Transaction Lead | Contract-to-close execution, critical dates, vendor management, loan coordination |
| Faiz | IR Manager | Investor onboarding, commitment approval, distribution batch approval, share transfer approval, SSN/EIN field access |
| Simon | IR Associate | Investor support, document upload, commitment creation — no approval authority |
| Ali | CFO / Finance | Disposition decisions, financial dashboard, distribution visibility, loan terms — read-only on most |
| Nikil, Nick Sr. | Principals | All-module approval authority, executive dashboards |
| Natalie | Marketing | Marketing Cloud — investor email campaigns |
| Shakeel | Property Management | Yardi liaison, post-closing PM handoff |
| Akber, Aftab | System Admins (Avanza) | Full org during implementation; Named Credential management |

---

## Active Initiatives (as of 2026-04-15)

- **Phase 0**: Project scaffold, TestDataFactory, agent orchestration — **complete**
- **Phase 1** (Weeks 1–8): Acquisitions + Transaction — Lead pipeline, broker Account/Contact model, Conversions 1 & 2, Transaction tasks, critical date alerts
- **Phase 2** (Weeks 9–16): Disposition + Property Mgmt — Disposition object, Sell Meter, BOV tracker, Property_Asset__c lifecycle, Yardi ASB connector
- **Phase 3** (Weeks 17–26): IR core — 4-object model, Experience Cloud portal, Conversion 7, commitment/waitlist, subscription docs, SF Files upload
- **Phase 4** (Weeks 27–34): Plaid + Share Transfer — Plaid Link integration, Transfer API, Wire Matching Engine (Conversion 8), Share Transfer (Conversion 9)
- **Phase 5** (Weeks 35–38): UAT + Go-Live — AppFolio data migration, parallel run, go-live cutover

---

## Known Constraints

- **API version:** 66.0 (pinned in `sfdx-project.json`). Do not propose features requiring a higher API.
- **No team-wide field prefix** in use. API names are unprefixed beyond `__c`.
- **Deployment:** only via `salesforce-devops` subagent (Salesforce MCP). Never propose direct `sf deploy` CLI calls from main agent.
- **No Salesforce Shield.** All data protection via native FLS, OWD, masked formula fields, Named Credentials, platform AES-256.
- **No OmniStudio.** DPEG does not use OmniScript, Integration Procedures, DataRaptors, or FlexCards.
- **No Aura components.** LWC only.
- **No direct external integrations.** All external system calls route through ASB. Salesforce holds only a Named Credential to ASB endpoint.
- **OneDrive: links only.** No OneDrive/Microsoft Graph integration. Staff paste OneDrive URLs as text fields.
- **Salesforce is read-only for Yardi and Procore.** No write-back to either system.
- **AppFolio data migration** must complete before Phase 5 go-live. Faiz owns the export.

---

## What Design Agent Should Default to When the User is Vague

- **Sharing:** Private OWD for all transactional and financial objects.
- **Trigger architecture:** always handler pattern (`<Object>TriggerHandler.cls`), never inline logic.
- **SOQL enforcement:** `WITH USER_MODE` unless there is a written justification for `SYSTEM_MODE`.
- **Test data:** mandate `TestDataFactory` — use DPEG-specific builder methods.
- **When field type is unclear:** ask, don't guess.
- **New objects:** follow the naming conventions in `ARCHITECTURE.md §1`.
- **New Apex services:** follow the Service / Selector / Domain / Trigger-handler layering in `ARCHITECTURE.md §2`.
- **Integration requests:** always route through ASB — never propose direct Salesforce-to-external callouts.
- **Financial field visibility:** always restrict to IR Manager + Finance + Principals; investors see own records only via portal.
