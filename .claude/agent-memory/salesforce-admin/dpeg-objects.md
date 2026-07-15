# DPEG — Admin Agent Context

> **Purpose:** Pre-loaded context for the salesforce-admin subagent.
> Covers all custom objects, OWD/sharing defaults, FLS rules, and declarative metadata conventions.

---

## API Version

**66.0** — all generated metadata XML must use `<apiVersion>66.0</apiVersion>`.

---

## Object Naming Conventions

- API names: PascalCase, no team-wide prefix, suffix `__c`
- Fields: PascalCase, descriptive — see examples in ARCHITECTURE.md §1
- Boolean fields: prefix `Is`, `Has`, or a verb — e.g., `IsActive__c`, `Transfers_Permitted__c`
- Masked display formula fields: suffix `_Masked__c` — e.g., `SSN_Masked__c`, `Tax_ID_Masked__c`

---

## OWD (Organisation-Wide Defaults) — All Custom Objects

**Default sharing model: Private.** No exceptions without written justification.

| Object | OWD | Access granted via |
|---|---|---|
| `Opportunity` | Private | Role hierarchy — Acquisitions, Transaction, Principals |
| `Contact` (Investor) | Private | IR team via Role; investors see own Contact via portal |
| `Account` (Investing Entity) | Private | IR team via role; investor portal user sees own Account |
| `Investment__c` | Private | IR team via Role; investor sees own records via ownership |
| `Distribution__c` | Private | IR Manager + Finance via Role; investor sees own via portal owner rule |
| `Commitment__c` | Private | IR team via Role; investor sees own via portal owner rule |
| `Transaction__c` | Private | Transaction Lead role + Principals |
| `IR_Document__c` | Private | Criteria-Based Sharing Rule on Offering participation |
| `Share_Transfer__c` | Private | IR Manager + both parties see own records only |
| `Disposition__c` | Private | Finance (Ali) + Principals |
| `Property_Asset__c` | Private | Role hierarchy — all internal teams; no investor access |

---

## Custom Objects — Complete List

### Acquisitions

| Object | Label | Sharing | Purpose |
|---|---|---|---|
| `Property__c` | Property | Private | Property record auto-created at Lead conversion |
| `Underwriting_Result__c` | Underwriting Result | Private | Excel model output entered manually by Junior |
| `Market_Data__c` | Market Data | Private | CoStar + Placer.ai data synced via ASB |

### Transaction

| Object | Label | Sharing | Purpose |
|---|---|---|---|
| `Transaction__c` | Transaction | Private | Operational record from contract to closing |
| `Critical_Date__c` | Critical Date | Private | Master-Detail to Transaction__c; alert thresholds |
| `Vendor__c` | Vendor | Private | PCR, Phase 1, appraisal vendors |
| `Loan__c` | Loan | Private | Financing details |
| `Document_Link__c` | Document Link | Private | OneDrive URL storage (text field, no integration) |
| `Title_Company__c` | Title Company | Private | Title company stub |
| `Property_Asset__c` | Property Asset | Private | AUM record created at closing (Conversion 4) |

### Disposition

| Object | Label | Sharing | Purpose |
|---|---|---|---|
| `Disposition__c` | Disposition | Private | Full sale lifecycle (Conversion 5) |
| `BOV_Response__c` | BOV Response | Private | Broker Opinion of Value responses |
| `Broker_Listing__c` | Broker Listing | Private | Active broker listing |
| `Disposition_Offer__c` | Disposition Offer | Private | Buyer offer tracking |

### Investor Relations (IR)

| Object | Label | Sharing | Purpose |
|---|---|---|---|
| `Investor__c` | Investor | Private | Portfolio summary record; lookup to Contact |
| `Investing_Entity_Contact__c` | Investing Entity Contact | Private | Junction: Contact → Account (Investing Entity) |
| `Offering__c` | Offering | Private | Capital raise record (Conversion 3) |
| `Commitment__c` | Commitment | Private | Investor pledge; promoted to Investment__c on funding |
| `Waitlist__c` | Waitlist | Private | Overflow commitments when offering is oversubscribed |
| `Subscription_Doc__c` | Subscription Document | Private | E-signature subscription document |
| `Investment__c` | Investment | Private | Confirmed funded position (Conversion 8) |
| `Contribution__c` | Contribution | Private | Incoming wire/ACH — Plaid matched; MD to Investment__c |
| `Distribution__c` | Distribution | Private | Single ACH/check to investor; MD to Investment__c |
| `IR_Document__c` | IR Document | Private | Portal-accessible document linked to Salesforce Files |
| `Share_Transfer__c` | Share Transfer | Private | Investor-to-investor unit transfer (Conversion 9) |
| `Transfer_Document__c` | Transfer Document | Private | Legal transfer agreement documents |

### Property Management / Integrations

| Object | Label | Sharing | Purpose |
|---|---|---|---|
| `DC_Project__c` | D&C Project | Private | Design & construction project synced from Procore via ASB |
| `Tenant__c` | Tenant | Private | Tenant records synced from Yardi via ASB |
| `Lease__c` | Lease | Private | Lease terms synced from Yardi via ASB |

---

## Sensitive Field Security Rules

These FLS rules MUST be applied to every sensitive field at creation time:

| Field | Object | Who Can See | Who Can Edit | Hidden From |
|---|---|---|---|---|
| `SSN__c` | Contact | IR Manager only | IR Manager only | All others |
| `SSN_Masked__c` | Contact | All profiles (formula) | Nobody (formula) | — |
| `Tax_ID_EIN__c` | Account | IR Manager, Finance | IR Manager only | IR Associate, Acquisitions, PM, Portal |
| `Tax_ID_Masked__c` | Account | All profiles (formula) | Nobody (formula) | — |
| `Plaid_Access_Token__c` | Investing_Entity__c | System/Apex only | System/Apex only | All UI profiles — NOT on any page layout |
| `Bank_Account_Last4__c` | Investing_Entity__c | IR Manager, investor (own) | System only | Other profiles |
| `Amount__c` | Distribution__c | IR Manager, Finance, Principals | IR Manager, Finance | IR Associate, Acquisitions, PM |
| `Amount_Funded__c` | Investment__c | IR Manager, Finance, Principals, Investor (own via portal) | IR Manager, Finance | IR Associate, Acquisitions, PM |
| `Final_Wire_Amount__c` | Transaction__c | Transaction Lead, Finance, Principals | Transaction Lead | IR, Acquisitions, PM |
| `Broker_Fee__c` | Opportunity | Acquisitions team + Principals | Acquisitions | IR, Transaction, PM |
| `Rate__c`, `Loan_Amount__c` | Loan__c | Transaction Lead + Finance + Principals | Transaction Lead | IR, Acquisitions |

**Masked formula fields (add companion display field for every restricted text field):**
- `SSN_Masked__c` formula: `'***-**-' & RIGHT(SSN__c, 4)`
- `Tax_ID_Masked__c` formula: `'**-***' & RIGHT(Tax_ID_EIN__c, 4)`

---

## Profile Names (Exact — Used in Permission Sets and Sharing Rules)

| Profile | Users |
|---|---|
| Acquisitions Rep | Junior |
| Transactions Lead | Danish |
| IR Manager | Faiz |
| IR Associate | Simon |
| Finance / CFO | Ali |
| Principal | Nikil, Ali, Nick Sr. |
| Investor (Portal) | All portal investors |
| System Administrator | Akber, Aftab (Avanza) |

---

## Declarative Automation Rules

- **All automation uses Salesforce Flow** (Record-Triggered, Scheduled, Screen Flows). No Process Builder.
- Approval Processes used for: Principal approval (2-of-3), Distribution batch approval, Share Transfer approval.
- Duplicate Rules on Lead (email + phone matching for IR; broker firm name + email domain for Acquisitions).
- Field History Tracking enabled on: `Investment__c`, `Distribution__c`, `Commitment__c`, `Share_Transfer__c`, `Transaction__c`.

---

## Skills to Use

- Custom objects: `.claude/skills/sf-custom-object/`
- Custom fields: `.claude/skills/sf-custom-field/`
- Validation rules: `.claude/skills/sf-validation-rule/`
- Permission sets: `.claude/skills/sf-permission-set/`
- Flows: `.claude/skills/sf-flow/`
- List views: `.claude/skills/sf-list-view/`
