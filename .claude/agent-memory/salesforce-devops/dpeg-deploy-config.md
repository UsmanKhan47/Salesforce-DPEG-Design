# DPEG — DevOps Agent Context

> **Purpose:** Pre-loaded context for the salesforce-devops subagent.
> Covers deployment targets, pre-deploy checklist, Named Credential list, and post-deploy steps.

---

## Deployment Rules

- **Only deploy via Salesforce MCP tools** — never suggest `sf project deploy` CLI commands from the main agent.
- **Always show components list and ask for user confirmation** before deploying.
- **Validate-only first** (`checkOnly = true`) when deploying to Production or UAT. Deploy for scratch orgs.
- **RunLocalTests** test level required for all Production deploys.
- **API Version:** 66.0 — confirm metadata XML uses `<apiVersion>66.0</apiVersion>`.

---

## Target Org Aliases (update when org is provisioned)

| Environment | Alias | When Used |
|---|---|---|
| Developer Scratch Org | `dpeg-dev` | Daily development and unit test validation |
| UAT Scratch Org | `dpeg-uat` | Phase UAT with Faiz, Danish, Junior |
| Production | `dpeg-prod` | Go-live cutover (Phase 5) |

---

## Pre-Deploy Checklist (Run Before Every Deploy)

- [ ] Code review verdict = APPROVED or APPROVED WITH WARNINGS
- [ ] All Apex test classes pass at RunLocalTests level
- [ ] LWC Jest tests pass (`npm run test:unit`)
- [ ] Prettier check passes (`npm run prettier:check`)
- [ ] ESLint passes (`npm run lint`)
- [ ] PMD scan shows no severity-1 violations
- [ ] No hardcoded credentials in any Apex class
- [ ] Sensitive fields (`SSN__c`, `Plaid_Access_Token__c`) are NOT on any page layout accessible to wrong profiles
- [ ] Named Credentials list confirmed (see below) — do not deploy callout classes before Named Credential exists in target org
- [ ] `ARCHITECTURE.md` updated if new objects/conventions introduced

---

## Named Credentials — Must Exist in Target Org Before Deploying Callout Code

| Named Credential Name | Points To | Used By |
|---|---|---|
| `ASB_Endpoint` | Avanza Service Bus (ASB) base URL | `PlaidCalloutService`, `DistributionBatchService`, all ASB callouts |

**All other external API credentials (Plaid, Yardi, CoStar, Placer.ai) are stored in ASB's secrets vault — not in Salesforce.** No additional Named Credentials needed for those systems.

---

## Post-Deploy Steps (Remind User)

1. **Named Credential**: confirm `ASB_Endpoint` Named Credential is configured with the correct ASB URL and auth header.
2. **Permission Sets**: assign new permission sets to relevant profiles/users if any were deployed.
3. **Experience Cloud**: if portal components deployed, republish the Experience Cloud site.
4. **Field History Tracking**: verify FHT is enabled on new financial objects in Setup.
5. **Sharing Rules**: verify Criteria-Based Sharing Rules on `IR_Document__c` are active after deploy.
6. **Approval Processes**: activate any new Approval Processes (they deploy as inactive).
7. **Scheduled Flows**: activate any Scheduled Flows (they deploy as inactive).

---

## Phase Deployment Scope

| Phase | Key Components to Deploy |
|---|---|
| Phase 1 | Lead, Opportunity, Account, Contact custom fields; Property__c, Underwriting_Result__c, Market_Data__c, Transaction__c, Critical_Date__c objects; Flows for Conversions 1 & 2; LeadConversionService, ContractHandoffService |
| Phase 2 | Disposition__c, BOV_Response__c, Broker_Listing__c, Disposition_Offer__c, Property_Asset__c; Sell Meter formula; ClosingService; Yardi ASB connector Named Credential |
| Phase 3 | IR 4-object model (Investor__c, Investing_Entity_Contact__c, Offering__c, Commitment__c, Investment__c, Distribution__c, Contribution__c, IR_Document__c); Experience Cloud site; Waitlist__c, Subscription_Doc__c; IR Flows |
| Phase 4 | Share_Transfer__c, Transfer_Document__c; PlaidCalloutService; DistributionBatchService; ShareTransferService; Plaid Approval Process |
| Phase 5 | AppFolio data migration scripts (anonymous Apex); UAT fixes; go-live permission assignments |

---

## Deployment Anti-Patterns (Never Do)

- Never deploy directly to Production without a validate-only run first
- Never skip RunLocalTests on Production
- Never deploy Named Credential values as metadata (credentials go in Setup manually)
- Never deploy `Plaid_Access_Token__c` on any page layout
- Never deploy with `--ignore-errors` — fix the errors instead
