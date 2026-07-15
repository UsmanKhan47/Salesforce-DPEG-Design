# DPEG — Documentation Agent Context

> **Purpose:** Pre-loaded context for the salesforce-documentation subagent.
> Covers docs/ folder conventions, document structure, and what belongs in each document type.

---

## Output Location

All documentation is saved to `docs/` in the project root.

---

## File Naming Convention

`DPEG_<ModuleOrFeature>_<DocType>_v<version>.md`

Examples:
- `docs/DPEG_Acquisitions_LeadConversion_v1.0.md`
- `docs/DPEG_IR_PlaidIntegration_v1.0.md`
- `docs/DPEG_Transaction_CriticalDates_v1.0.md`

---

## Standard Document Structure

Every feature document should include:

```
# DPEG — [Feature Name]

## 1. What Was Built
- Summary of components created (objects, Apex classes, Flows, LWC, permission sets)
- Object conversion points affected (reference Conversion numbers 1–9)

## 2. Why It Was Built
- Business problem it solves
- Which module it belongs to (Acquisitions / Transaction / Disposition / IR)
- Which stakeholder(s) it serves (Junior, Danish, Faiz, Simon, Ali, Principals, Investors)

## 3. How It Works
- Step-by-step data flow
- Automation triggers involved
- Integration touchpoints (ASB handlers if applicable)

## 4. Security & Access
- Who can see / edit the new records or fields
- FLS rules applied
- OWD on new objects

## 5. Testing
- How to verify the feature works
- Test class names and what they cover

## 6. Deployment Notes
- Named Credentials to configure
- Post-deploy manual steps
- Dependencies on other phases
```

---

## Module Context for Documentation

| Module | Owner | Key Business Process |
|---|---|---|
| Acquisitions | Junior | Broker deal intake → NDA → Underwriting → Principal approval → Contract |
| Transaction | Danish | Contract → Due diligence → Closing → Property_Asset__c creation |
| Disposition | Ali + Principals | Sell Meter alert → BOV outreach → Listing → Sale closing → Investor proceeds |
| Investor Relations | Faiz + Simon | Investor onboarding → Commitment → Plaid funding → Distributions → Portal |

---

## Reference Document

The primary technical reference is `docs/DPEG_Technical_Solution_Design_v1.3.docx`.
All architecture decisions should reference `ARCHITECTURE.md` as the living source of truth.
Do NOT duplicate content already in ARCHITECTURE.md — link to it instead.

---

## What NOT to Document

- Code-level implementation details that are self-evident from reading the class
- Salesforce platform basics (assume reader knows Salesforce)
- Credentials or API keys (never in docs)
- Temporary workarounds — document the final state, not the journey
