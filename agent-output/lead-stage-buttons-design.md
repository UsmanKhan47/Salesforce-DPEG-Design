═══════════════════════════════════════════════════════════════════════════════
                    📋 DESIGN REQUIREMENTS — Lead Stage-Advance Action Buttons
═══════════════════════════════════════════════════════════════════════════════

Grounded against ARCHITECTURE.md (§2 Apex layering, §5 LWC), CLAUDE.md orchestration
rules, and the live Lead conversion pipeline. Requirements were fully clarified with the
user in advance; this document formalizes them and wires the Convert action to the
existing pipeline. **Design only — no implementation files were written.**

🎯 WHAT USER REQUESTED
--------------------------------------------------------------------------------
A custom LWC on the Lead record page that renders contextual stage-advance buttons,
replacing reliance on the Lightning Path's "Mark as Current Status" button. The Path bar
(`Lead_Funnel_Path` / `runtime_sales_lead:pathAssistant`) STAYS for visual progress — the
component is added beside/below it, the Path is NOT removed.

- SHOW only the valid next-step buttons for the current Status; HIDE (not disable) the rest.
- Status-only transitions (Under Review, Qualified, Disqualified) → set `Lead.Status` only,
  create no records, and reactively re-render buttons for the new stage.
- Convert (shown on Qualified) → perform the ACTUAL lead conversion through the existing
  `LeadConvertService` pipeline (Account/Contact/Opportunity + `Property__c`), then redirect
  the user to the newly created Opportunity's record page.

───────────────────────────────────────────────────────────────────────────────
                    STATE MACHINE (authoritative)
───────────────────────────────────────────────────────────────────────────────

Lead Status picklist values (this org, from `LeadStatus.standardValueSet-meta.xml`):
New, Under Review, Qualified, Disqualified, Converted. `New` is the default;
**`Converted` is the only value flagged `<converted>true</converted>`** — this is the
value passed to `Database.LeadConvert.setConvertedStatus(...)`.

| Current Status | Buttons shown            | Action per button                                            |
| -------------- | ------------------------ | ------------------------------------------------------------ |
| New            | [Under Review] [Disqualified] | status-only set to that value                           |
| Under Review   | [Qualified] [Disqualified]    | status-only set to that value                           |
| Qualified      | [Convert] [Disqualified]      | Convert = real conversion; Disqualified = status-only   |
| Disqualified   | (none — terminal)        | —                                                            |
| Converted      | (none — terminal)        | — (see gotcha: page auto-redirects to the Contact)          |

Only single-step forward moves and the always-available Disqualified off-ramp are
exposed; there are no backward transitions.

───────────────────────────────────────────────────────────────────────────────
                    RECONNAISSANCE FINDINGS (grounds the wiring)
───────────────────────────────────────────────────────────────────────────────

**Conversion pipeline — what fires on `IsConverted`:**
`triggers/LeadConvertTrigger.trigger` (`after update`, one-liner) →
`LeadConvertTriggerHandler.afterUpdate()` (extends the repo `TriggerHandler` base) →
`LeadConvertService.stampConvertedOpportunities(newList, oldMap)`.

The service detects a lead that *just* converted (`l.IsConverted && !prior.IsConverted`
with a non-null `l.ConvertedOpportunityId`) and then:
1. Builds one `Property__c` per converted deal — `Name` from address/company/name (≤80
   chars), `Address__c`/`City__c`/`State__c`/`Zip__c`, **`Asking_Price__c` ← `Lead.Guidance_Price__c`**,
   **`Cap_Rate_Asking__c` ← `Lead.Guidance_Cap_Rate__c`**, `Placer_URL__c` ← `Placer_AI_Link__c`,
   `CoStar_URL__c` ← `CoStar_Link__c`, and `Asset_Type__c` only when the lead's value is on
   Property's restricted picklist. Inserted with `allOrNone = false` (a bad Property never
   rolls back the conversion).
2. Resolves Opportunity record types Land/Commercial by developer name via `RecordTypeSelector`.
3. Updates each new Opportunity: `Lead_Approved_By__c = current user` (conversion IS the
   approval to underwrite), `Property__c` link, `Deal_Type__c` (from the lead), and matching
   `RecordTypeId`.

**Critical implication for the Convert button:** `LeadConvertService` runs as an
*after-update trigger side effect* of the Lead being flipped to converted. Therefore the new
Convert controller/service does **NOT** call `LeadConvertService` directly — it only needs to
run `Database.convertLead(...)`. The Lead update that convertLead performs fires the trigger
synchronously in the same transaction, so by the time `convertLead` returns, the Property is
created and the Opportunity is fully stamped. The Opportunity Id is read from
`Database.LeadConvertResult.getOpportunityId()`.

**Account/Contact/Opportunity on convert:**
- `Database.convertLead` creates (or matches, per standard convert behavior) the Account and
  Contact — no custom code needed for those.
- Opportunity: leave `setDoNotCreateOpportunity(false)` (default) so an Opportunity is created.
  **Opportunity name is NOT required to be supplied** — when `setOpportunityName` is omitted,
  the platform derives it from the lead's Company (a required standard Lead field). No name
  input is needed from the user.
- `setConvertedStatus('Converted')` is required and valid (confirmed converted flag above).

**Existing precedent to mirror:** `StageAdvanceController` + `StageAdvanceService` (P6
controller-thinning) is the exact template — thin `@AuraEnabled` controller with the repo
`ahe()` helper, a typed service exception surfaced verbatim, a fixed generic masked message
for unexpected failures, service `with sharing`, all SOQL delegated to a selector. The new
Convert pair should follow this shape. **No existing class calls `Database.convertLead`**, so
this controller/service is genuinely new.

**Flexipage placement:** `flexipages/Lead_Record_Page.flexipage-meta.xml` (masterLabel
"Lead Intake Page", template `recordHomeWithSubheaderTemplateDesktop`). The Path already
lives in the **`subheader`** region as `runtime_sales_lead:pathAssistant`. The new LWC should
be added as a second `<itemInstances>` block in that same `subheader` region, directly below
the Path (satisfies "beside/below the Path" and keeps the Path in place).

───────────────────────────────────────────────────────────────────────────────
                    🔵 ADMIN WORK (salesforce-admin)
───────────────────────────────────────────────────────────────────────────────

• **Edit `Lead_Record_Page` flexipage** — add the new custom LWC (`leadStageActions`, see
  Dev) as a second component in the `subheader` region, immediately below the existing
  `runtime_sales_lead:pathAssistant`. Do NOT remove or alter the Path component.

(The standard Convert button/quick-action removal is deliberately NOT scoped here — see Open
Questions. Left in place absent an explicit decision.)

───────────────────────────────────────────────────────────────────────────────
                    🟢 DEVELOPMENT WORK (salesforce-developer)
───────────────────────────────────────────────────────────────────────────────

• **LWC `leadStageActions`** (`lwc/leadStageActions/`) — apiVersion **67.0**, exposed to
  `lightning__RecordPage` (Lead). Reads current Status via `@wire(getRecord, { fields:
  [STATUS_FIELD, ISCONVERTED_FIELD] })` (reactive, so buttons re-render after any change).
  Computes the visible button set from the state machine above.
  - Status-only buttons (Under Review / Qualified / Disqualified): call LDS
    `updateRecord({ fields: { Id, Status } })` from `lightning/uiRecordApi` — **no Apex**
    (§5 LDS-first). Success toast; the `getRecord` wire re-emits the new Status and the
    buttons re-render automatically.
  - Convert button: call the imperative Apex controller (below); on success
    `NavigationMixin.Navigate` to the returned Opportunity `recordId`
    (`standard__recordPage`, `actionName: 'view'`).
  - Errors → `lightning/platformShowToastEvent` toast with the AuraHandledException message.
  - Terminal states (Disqualified / Converted): render nothing (no buttons).
  - SLDS 2 design tokens (`--slds-g-*`), no hardcoded colors/spacing; run the SLDS linter.

• **Apex controller `LeadConvertActionController`** (`with sharing`) — THIN. One
  `@AuraEnabled` method (e.g. `convert(Id recordId) : Id`) that delegates to the service,
  catches the service's typed exception → `ahe(e.getMessage())` (surface verbatim), and maps
  any unexpected `Exception` → a fixed generic user-safe message (mirror
  `StageAdvanceController`'s `READ_FAILURE_MESSAGE` pattern; never interpolate platform text).

• **Apex service `LeadConvertActionService`** (`with sharing`) — owns the conversion logic:
  builds `Database.LeadConvert` with `setLeadId`, `setConvertedStatus('Converted')`,
  `setDoNotCreateOpportunity(false)`; runs `Database.convertLead(...)`; returns the new
  Opportunity Id from `getOpportunityId()`. Raises a typed `LeadConvertException` for
  user-actionable failures (e.g. already-converted, blocked by a validation/convert error)
  whose message the controller surfaces. **Does not** re-implement Property/Opp stamping —
  that runs automatically via `LeadConvertService` on the trigger. **Bulk-shaped signature
  recommended** (accept a collection, return `Map<Id,Id>`), controller marshals the single
  Id — see Gotchas for the §2 bulkification rationale.

• **Selector method (conditional)** — only if the service adds a server-side guard that
  *reads* the Lead (e.g. confirm `Status == 'Qualified'` / not already converted). If so, that
  SOQL MUST go in `LeadSelector` (add e.g. `selectConvertStateById`), never inline in the
  service (§2 / apex-layering-rule). The happy path needs no read (`convertLead` self-validates),
  so a selector may not be required.

• **Tests** (per project workflow; the unit-testing agent owns Apex tests):
  - Apex: test class(es) for controller + service, 90%+ coverage, `TestDataFactory`, asserting
    a Qualified Lead converts, an Opportunity + `Property__c` are created and the Opp is
    stamped (deal type / record type / `Lead_Approved_By__c`), and the returned Id matches.
  - LWC: Jest test + `@sa11y/jest` accessibility matchers (`__tests__/leadStageActions.test.js`).

───────────────────────────────────────────────────────────────────────────────
                    🔗 EXECUTION ORDER
───────────────────────────────────────────────────────────────────────────────

1. Dev: Apex service → controller (service first; controller depends on it).
2. Dev: LWC `leadStageActions` (depends on the controller's `@AuraEnabled` signature).
3. Admin: flexipage edit to place the LWC (depends on the LWC existing/being exposed).
4. Unit testing → code review → devops + docs (standard workflow).

───────────────────────────────────────────────────────────────────────────────
                    🔀 COMPLEXITY ROUTING RECOMMENDATION
───────────────────────────────────────────────────────────────────────────────

**Development → `salesforce-developer` (CONFIRMED, not technical-architect).**
Rationale: `Database.convertLead` is standard Apex (no ASB/Plaid/Yardi/CoStar integration,
no Named/External Credentials, no LDV/governor tuning, no Platform Events, no complex
multi-layer service design). It is a straight controller→service→LWC feature that directly
mirrors the existing `StageAdvanceController`/`StageAdvanceService` P6 precedent — squarely
"Standard programmatic work" per CLAUDE.md's routing guide.

**Admin → `salesforce-admin` (routine).** A single existing-flexipage edit to place one
component — no multi-object schema, security model, or subflow architecture, so
solution-architect is not warranted.

───────────────────────────────────────────────────────────────────────────────
                    ⚠️ GOTCHAS
───────────────────────────────────────────────────────────────────────────────

- **LDS refresh after a status change:** because Status is read via `@wire(getRecord)` and
  written via `updateRecord` (both LDS), the cache updates and the wire re-emits — buttons
  re-render with no manual `refreshApex`. Do NOT reintroduce imperative Apex for status-only
  changes; that would break the automatic reactivity (and violate §5 LDS-first).

- **Converted-Lead read-only / auto-redirect:** Salesforce ALWAYS auto-redirects
  `/lightning/r/Lead/{convertedId}/view` to the converted Contact (documented in
  `LeadSelector`'s header). The "Converted → no buttons" terminal state will therefore rarely
  be seen on the Lead page in practice — but the component must still handle it (render
  nothing) for the brief window and for robustness. This redirect is *why* navigating to the
  Opportunity after Convert is the correct UX (the user can't usefully stay on the converted Lead).

- **Converted-status value:** must be exactly `'Converted'` — the only picklist value with
  `<converted>true</converted>`. Passing any other value to `setConvertedStatus` throws.

- **Opportunity navigation Id:** obtain it from `Database.LeadConvertResult.getOpportunityId()`
  and return it to the LWC. Do NOT try to re-query the Lead for `ConvertedOpportunityId` from
  the LWC afterward — the Lead page will have redirected. The whole conversion (including the
  trigger's Property creation + Opp stamping) is complete when `convertLead` returns, so the
  returned Id is safe to navigate to immediately.

- **§2 bulkification vs single-record UI:** the button fires per single Lead. §2 mandates
  collection-shaped service methods and the bulk-test rule mandates 251-record tests for
  service DML. Recommendation: give the service a collection signature
  (`convert(Set<Id>) : Map<Id,Id>`) so it is naturally bulk-testable, with the controller
  marshaling the one recordId — `Database.convertLead` already takes a `List<LeadConvert>`, so
  this is free. (If instead a single-record signature is chosen, it must be justified against
  the per-transaction-singleton exemption in bulk-test-rule.md; the collection shape avoids
  that argument entirely.)

- **Standard Convert button/quick action:** currently LEFT in place (no change scoped). It
  coexists with the custom Convert button; both routes now work. If a single entry point is
  desired later, removing the standard Convert quick action from the Lead layout is an admin
  change — flagged, not done, absent an explicit decision (see Open Questions).

- **Context — duplicate rule:** the standard Lead duplicate rule was just deactivated. Not a
  driver of this feature, but it means `Database.convertLead` will not be blocked by a Lead
  duplicate alert during conversion. No action required.

───────────────────────────────────────────────────────────────────────────────
                    ❓ OPEN QUESTIONS
───────────────────────────────────────────────────────────────────────────────

1. **Standard Convert button:** leave it (current recommendation) or remove/hide the standard
   Convert quick action so the custom button is the sole convert path? (Admin change if remove.)
2. **Disqualified reason:** the org has `Lead.Disqualification_Reason__c`. The Disqualified
   button is spec'd as status-only (no reason prompt). Confirm no reason capture is wanted on
   that click, or that it's handled separately.
3. **Confirmation on Convert:** should the Convert click show a confirmation modal before the
   irreversible conversion, or convert immediately on click? (Spec implies immediate.)
4. **Button placement/labels:** confirm the component sits directly below the Path in the
   `subheader` region (vs. the `main`/`sidebar` region), and confirm button label "Convert"
   (vs. "Convert to Opportunity").

═══════════════════════════════════════════════════════════════════════════════
