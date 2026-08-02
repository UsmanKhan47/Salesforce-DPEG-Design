═══════════════════════════════════════════════════════════════════════════════
                    📋 DESIGN REQUIREMENTS
         Lead stage actions — RE-DELIVER as headless LWC quick actions
═══════════════════════════════════════════════════════════════════════════════

🎯 WHAT USER REQUESTED
Replace the inline `leadStageActions` LWC (buttons rendered below the Path) with the
SAME behavior delivered as one-click **headless LWC quick actions** in the Lead
highlights-panel action bar. Each action is shown only for the valid next stage via
Dynamic Actions visibility rules **the user will configure manually in App Builder**.
No modal / no screen — each action runs `@api invoke()` on click.

- "Mark Under Review" → set `Status = 'Under Review'` via LDS `updateRecord` (headless, one-click).
- "Mark Qualified"    → set `Status = 'Qualified'`.
- "Disqualify"        → set `Status = 'Disqualified'`.
- "Convert"           → call the EXISTING `LeadConvertActionController.convertLead(leadId)`, then
                        `NavigationMixin.Navigate` to the returned Opportunity. Reuse the existing
                        controller/service — do NOT rebuild convert.
- On error → `ShowToastEvent`. Status-change success needs no navigation (the LDS cache write
  reactively refreshes the Path/highlights).
- Remove `leadStageActions` from the Lead flexipage (subheader region).
- KEEP `LeadConvertActionController` / `LeadConvertActionService` + their tests.

This is a **re-delivery of an already-shipped feature** — behavior is unchanged, only the
delivery surface changes (inline LWC → quick actions). Requirements are fully clarified;
this doc formalizes the mechanics, the metadata shapes, the visibility spec, and the removal.

───────────────────────────────────────────────────────────────────────────────
                    🔎 RECONNAISSANCE FINDINGS
───────────────────────────────────────────────────────────────────────────────

**An existing headless-LWC-quick-action pattern already exists in this repo — mirror it exactly.**

1. **Shared-bundle precedent** — `lwc/advanceDealStage` (Opportunity). One headless bundle backs
   FIVE quick actions (`Opportunity.Begin_Review`, `Initiate_Underwriting`, `Initiate_LOI`,
   `Advance_to_PSA`, `Close_Deal`). Its Apex (`StageAdvanceController.advance`) DERIVES the target
   from the current stage; each quick action is shown only on its stage via Dynamic Actions.
2. **Per-action-bundle precedent** — `lwc/dealSendToDevelopmentReview` (Opportunity). A tiny headless
   bundle used by ONE quick action (`Opportunity.Send_to_Development_Review`) that HARDCODES its
   target (`advanceTo({ recordId, target: 'Development Review' })`).
3. **`@api recordId`** is supplied automatically on the `lightning__RecordAction` target — both
   precedents rely on it. `@api invoke()` is the platform-invoked click handler; the template is
   empty (`<template></template>`).
4. **`ShowToastEvent` works in headless quick actions** — proven by `advanceDealStage` (success +
   error toasts). **`NavigationMixin` works too** — the current `leadStageActions` LWC already uses
   `NavigationMixin(LightningElement)` + `this[NavigationMixin.Navigate]({ type:'standard__recordPage' … })`
   for its Convert path; that code moves verbatim into the Convert quick-action bundle.
5. **QuickAction metadata shape** (from `Opportunity.Initiate_LOI.quickAction-meta.xml`): the target
   sObject is the **filename prefix** (`Lead.<Name>.quickAction-meta.xml`) — there is **no
   `<targetSObject>` element**. `type = LightningWebComponent`, `actionSubtype = Action`,
   `lightningWebComponent = <bundle>`, `optionsCreateFeedItem = false`, plus `<label>`.
6. **Shared-util precedent** — `lwc/utils` (`isExposed=false`, no `.html`) already exists, but it is
   documented as **"pure, stateless formatting utilities."** Do NOT put `updateRecord` logic there —
   use a small dedicated shared module instead (see recommendation).
7. **Lead Status picklist values** (`standardValueSets/LeadStatus.standardValueSet-meta.xml`):
   `New`, `Under Review`, `Qualified`, `Converted`, `Disqualified`. Only `Converted` is
   `converted=true`. These exact strings are the visibility-rule values.
8. **Flexipage** `Lead_Record_Page.flexipage-meta.xml`: `leadStageActions` sits in the **`subheader`**
   region as a SECOND `<itemInstances>` block, directly after the `runtime_sales_lead:pathAssistant`
   block (lines 44–49). Removing only that block leaves the Path intact.
9. **Reused-as-is Apex is 67.0-clean and thin** — `LeadConvertActionController.convertLead(Id leadId)`
   returns the new Opportunity `Id`; the Convert bundle imports it unchanged. No Apex changes needed.

**One-bundle-vs-many decision:** headless quick actions **cannot take per-instance design/App-Builder
params**, so a single shared bundle cannot be told "which status to write." The `advanceDealStage`
"derive-target-from-current-state" trick does NOT fit here because (a) the spec requires **LDS
`updateRecord`, not Apex**, for the three status changes, and (b) **Disqualify is many→one** (valid
from New OR Under Review OR Qualified, always writing `Disqualified`) — a derive-from-current bundle
would compute the wrong (forward) target. Therefore the correct model is the **per-action bundle**
precedent (`dealSendToDevelopmentReview`): one tiny bundle per action with its target hardcoded.

───────────────────────────────────────────────────────────────────────────────
                    🟢 DEVELOPMENT WORK (salesforce-developer)
───────────────────────────────────────────────────────────────────────────────

Everything here is standard LWC + coupled declarative metadata → **salesforce-developer**. The
quick-action `.quickAction-meta.xml` files and the flexipage removal reference the new bundles, so
they are produced together with the LWCs (repo precedent: the `advanceDealStage` quick actions are
dev-owned). No new Apex is created → no `salesforce-unit-testing` (Apex) pass; Jest is authored by
the developer per §5.

### New LWC bundles (apiVersion 67.0, headless)

Recommended: **3 tiny status bundles + 1 convert bundle + 1 shared util module.**

| Bundle | Action on `invoke()` | Notes |
| --- | --- | --- |
| `leadMarkUnderReview` | `updateRecord` → `Status='Under Review'`; success toast | hardcoded target |
| `leadMarkQualified`   | `updateRecord` → `Status='Qualified'`; success toast | hardcoded target |
| `leadDisqualify`      | `updateRecord` → `Status='Disqualified'`; success toast | hardcoded target |
| `leadConvertAction`   | `await convertLead({ leadId: recordId })` → `NavigationMixin.Navigate` to the Opportunity | reuses existing controller; extends `NavigationMixin(LightningElement)` |
| `leadStatusChange` (shared, `isExposed=false`, no `.html`) | exports `changeStatus(recordId, targetStatus)` (does `updateRecord`, throws on failure) + `errorMessage(err)` | the 3 status bundles are identical bar the target constant + success text; the util removes the duplication. Do **not** fold this into `c/utils` (that module is contractually pure formatting only). |

The 3 status bundles' `invoke()` becomes: call `changeStatus(this.recordId, TARGET)`, then dispatch a
success toast; on throw dispatch an error toast. Toast dispatch stays in the component (needs the
element's `this.dispatchEvent`); `updateRecord` + message-normalization live in the util.

> Alternative (also acceptable): inline the ~15-line `invoke()` in each of the 3 status bundles with
> no shared util — this exactly matches `dealSendToDevelopmentReview`. The shared util is preferred
> only because the three are near-byte-identical here. Developer's call; either satisfies §5.

### Exact metadata shapes

**Headless LWC `*.js-meta.xml`** (identical for all 4 action bundles — mirrors `advanceDealStage.js-meta.xml`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <isExposed>true</isExposed>
    <targets>
        <target>lightning__RecordAction</target>
    </targets>
    <targetConfigs>
        <targetConfig targets="lightning__RecordAction">
            <actionType>Action</actionType>
        </targetConfig>
    </targetConfigs>
</LightningComponentBundle>
```

**Headless `*.html`** for all 4 bundles: `<template></template>` (empty — no rendered UI).

**QuickAction `*.quickAction-meta.xml`** — one per action, filename `Lead.<Name>.quickAction-meta.xml`
(the `Lead.` prefix IS the target sObject — no `<targetSObject>` element):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<QuickAction xmlns="http://soap.sforce.com/2006/04/metadata">
    <actionSubtype>Action</actionSubtype>
    <label>Mark Under Review</label>
    <lightningWebComponent>leadMarkUnderReview</lightningWebComponent>
    <optionsCreateFeedItem>false</optionsCreateFeedItem>
    <type>LightningWebComponent</type>
</QuickAction>
```

| QuickAction file | `<label>` | `<lightningWebComponent>` |
| --- | --- | --- |
| `Lead.Mark_Under_Review.quickAction-meta.xml` | `Mark Under Review` | `leadMarkUnderReview` |
| `Lead.Mark_Qualified.quickAction-meta.xml`    | `Mark Qualified`    | `leadMarkQualified` |
| `Lead.Disqualify.quickAction-meta.xml`        | `Disqualify`        | `leadDisqualify` |
| `Lead.Convert.quickAction-meta.xml`           | `Convert`           | `leadConvertAction` |

**Status-bundle `invoke()` (illustrative — `leadMarkUnderReview`):**

```js
import { LightningElement, api } from 'lwc';
import { changeStatus, errorMessage } from 'c/leadStatusChange';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const TARGET = 'Under Review';

export default class LeadMarkUnderReview extends LightningElement {
    @api recordId;

    @api async invoke() {
        try {
            await changeStatus(this.recordId, TARGET);   // LDS updateRecord (Id + Status)
            this.dispatchEvent(new ShowToastEvent({
                title: 'Success', message: `Lead moved to ${TARGET}.`, variant: 'success'
            }));
            // NO getRecordNotifyChange — updateRecord writes through the LDS cache, so the
            // Path + highlights re-render automatically. (Contrast advanceDealStage, which uses
            // imperative Apex DML and therefore MUST call getRecordNotifyChange.)
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error', message: errorMessage(error), variant: 'error'
            }));
        }
    }
}
```

**Convert-bundle `invoke()` (illustrative — `leadConvertAction`, reuses existing Apex verbatim):**

```js
import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import convertLead from '@salesforce/apex/LeadConvertActionController.convertLead';

export default class LeadConvertAction extends NavigationMixin(LightningElement) {
    @api recordId;

    @api async invoke() {
        try {
            const opportunityId = await convertLead({ leadId: this.recordId });
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: opportunityId, objectApiName: 'Opportunity', actionName: 'view' }
            });
        } catch (error) {
            const message = (error && error.body && error.body.message)
                || 'Unable to convert this lead.';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Cannot convert the lead', message, variant: 'error'
            }));
        }
    }
}
```

### Jest (required by §5 — one suite per new bundle, LOCAL-only, never deploys)

Mirror `advanceDealStage.test.js`: drive `invoke()` directly (`await element.invoke()`), then assert.
- **Status bundles:** mock `c/leadStatusChange` (or `lightning/uiRecordApi` `updateRecord`). Success →
  `updateRecord` called with `{ Id, Status:<target> }` + success toast. Failure (mockRejected) →
  error toast, correct message. `toBeAccessible()` on the empty template.
- **Convert bundle:** mock `@salesforce/apex/LeadConvertActionController.convertLead` and
  `lightning/navigation`. Success → `convertLead` called with `{ leadId }` + `Navigate` to the
  returned Opportunity Id. Failure → error toast, correct message. `toBeAccessible()`.
- **Shared util:** unit-test `changeStatus` / `errorMessage` directly (mock `updateRecord`).

### Flexipage edit (removal)

In `force-app/main/default/flexipages/Lead_Record_Page.flexipage-meta.xml`, delete ONLY this
`<itemInstances>` block from the `subheader` region (keep the `pathAssistant` block above it):

```xml
        <itemInstances>
            <componentInstance>
                <componentName>leadStageActions</componentName>
                <identifier>leadStageActions</identifier>
            </componentInstance>
        </itemInstances>
```

Removing it from the page **unpublishes** the inline component (it stops rendering) — no destructive
deploy required for the page change itself.

### Reused unchanged (do NOT modify or rebuild)

- `LeadConvertActionController.cls` / `LeadConvertActionService.cls` (+ `…ControllerTest`, `…ServiceTest`).
  The Convert quick action imports the controller as-is.
- `c/utils` — untouched (do not add status logic here).

### Removed / cleanup

- **`lwc/leadStageActions` bundle** (`.js`, `.html`, `.css`, `.js-meta.xml`, `__tests__/…`):
  **Recommendation — delete it.** It is fully replaced and its `isExposed=true` + `lightning__RecordPage`
  target would otherwise let someone re-drop it onto a page (dead, misleading code). BUT: deleting a
  deployed component requires a **destructive deploy** (`destructiveChangesPost.xml`), which is a
  distinct salesforce-devops step from the normal source push. Removing it from the flexipage (above)
  is already enough to stop it rendering, so bundle deletion is **optional cleanup, not required for
  the feature to work.** If deleted, delete its Jest test in the same change. → confirm in Open Q1.

───────────────────────────────────────────────────────────────────────────────
                    🔵 ADMIN / MANUAL WORK — App Builder (USER performs)
───────────────────────────────────────────────────────────────────────────────

Per the spec, the **user configures the Dynamic Actions visibility manually in App Builder** — the
agents do NOT deploy the visibility rules into the flexipage. After the 4 quick actions are deployed:

1. Open `Lead Intake Page` (`Lead_Record_Page`) in Lightning App Builder → select the **Highlights
   Panel** → **enable Dynamic Actions** (the panel is currently layout-driven —
   `enableActionsConfiguration=false`).
   ⚠️ Enabling Dynamic Actions **replaces the page-layout action set** for the highlights panel —
   re-add any standard actions you still want (Edit, Clone, etc.) alongside the 4 new ones.
2. Add the 4 quick actions and set each action's **visibility filter** exactly as below.

#### Per-stage visibility-rule spec (App Builder handoff)

Field for every filter: **`Record > Status`** (`{!Record.Status}`), Operator **Equal**, Value = the
exact Lead Status value string (case-sensitive).

| Quick action | Filter logic | Condition(s) — `Record.Status` Equal … |
| --- | --- | --- |
| **Mark Under Review** | single | `New` |
| **Mark Qualified**    | single | `Under Review` |
| **Disqualify**        | **Any** (OR) | `New` **OR** `Under Review` **OR** `Qualified` |
| **Convert**           | single | `Qualified` |

Terminal states `Disqualified` and `Converted` match no rule → **none of the 4 actions show**
(the record is done). For Disqualify, use App Builder's **"Any conditions are met"** (OR) with the
three filters; the others use a single condition.

───────────────────────────────────────────────────────────────────────────────
                    🔗 EXECUTION ORDER
───────────────────────────────────────────────────────────────────────────────

1. **salesforce-developer** — create the 4 headless LWC bundles + shared util, the 4
   `Lead.*.quickAction-meta.xml`, the flexipage removal, and the 5 Jest suites. (Reuses existing
   convert Apex; creates no new Apex.)
2. **salesforce-code-review** — review the LWCs, quick-action metadata, flexipage edit, and Jest.
3. **salesforce-devops** (+ **salesforce-documentation** in parallel) — deploy. If Open Q1 is
   "delete the bundle," devops runs the destructive change for `leadStageActions` as a distinct step.
4. **USER, post-deploy** — App Builder: enable Dynamic Actions on the Lead highlights panel, add the
   4 actions, apply the visibility table above.

No `salesforce-unit-testing` (Apex) step — no new Apex is written; Jest is authored in step 1.

───────────────────────────────────────────────────────────────────────────────
                    🔀 COMPLEXITY ROUTING
───────────────────────────────────────────────────────────────────────────────

**salesforce-developer** (standard LWC work). Not technical-architect — no integration/LDV/Named
Credentials. The quick-action + flexipage metadata are coupled to the bundles they reference and are
produced by the developer alongside the LWCs (repo precedent: `advanceDealStage`). The App Builder
visibility config is a manual user step, not agent work.

───────────────────────────────────────────────────────────────────────────────
                    ⚠️ GOTCHAS
───────────────────────────────────────────────────────────────────────────────

1. **Headless `invoke()` lifecycle** — the action bundle renders NO UI (`<template></template>`); the
   platform calls `@api invoke()` on click. It must be `@api` and may be `async`. `@api recordId` is
   injected on the `lightning__RecordAction` target and is populated by the time `invoke()` runs.
   Required meta: `isExposed=true`, `target=lightning__RecordAction`, `actionType=Action`.
2. **LDS refresh after a status change — do NOT call `getRecordNotifyChange`.** `updateRecord` writes
   THROUGH the LDS cache, so the Path (`pathAssistant`) and highlights re-render on their own. This is
   the deliberate difference from `advanceDealStage`, which uses imperative Apex DML and therefore
   MUST call `getRecordNotifyChange` to tell LDS the record changed. Adding it on the `updateRecord`
   path is redundant. For **Convert**, we navigate away from the Lead, so no source-record refresh is
   needed at all.
3. **Error toast** — extract `error.body.message` (the `AuraHandledException` message for Convert; the
   `updateRecord` DML/FLS error for status changes) with a generic fallback so no raw platform text or
   `undefined` leaks. Never interpolate platform text into a generic message (§5).
4. **`NavigationMixin` in a headless quick action** — supported; the Convert bundle must
   `extends NavigationMixin(LightningElement)` and call `this[NavigationMixin.Navigate]({...})`. This
   is the same code already proven in the current `leadStageActions` LWC.
5. **QuickAction metadata** — object comes from the FILENAME prefix (`Lead.`), not a `<targetSObject>`
   element. Deploy the `.quickAction-meta.xml` files so the actions are selectable in App Builder;
   they do nothing until the user assigns them with visibility rules.
6. **Enabling Dynamic Actions replaces the layout-driven highlights actions** — the user must re-add
   any standard actions they want to keep (see Admin/Manual §, step 1). Easy to miss.
7. **apiVersion 67.0** — all new bundles author at 67.0 (matches repo/org; §5). No 62.0 legacy here.
8. **Jest is LOCAL-only** — never deploys; runs against the repo Jest net. Test `invoke()` by calling
   it directly (as `advanceDealStage.test.js` does) — headless bundles have no DOM to click. `refreshApex`
   is not assertable; `NavigationMixin` needs a MODULE mock of `lightning/navigation`, not an instance spy.
9. **FLS caveat (status writes)** — `updateRecord` runs in the user's context; a persona lacking
   FLS/edit on `Lead.Status` gets a DML error surfaced as the error toast. This mirrors production
   behavior and needs no extra handling, but acceptance-test the status actions as a **non-admin
   persona** (admins pass via profile grants; non-admins rely on permission-set FLS, which is not in
   source control) — an admin smoke test proves nothing about end users.
10. **Do not "fix" `c/utils`** — it is contractually pure formatting; put status logic in a new
    `c/leadStatusChange` module instead.

───────────────────────────────────────────────────────────────────────────────
                    ❓ OPEN QUESTIONS (confirmations only — spec is otherwise complete)
───────────────────────────────────────────────────────────────────────────────

1. **Delete the `leadStageActions` bundle?** Recommended (it is fully replaced; leaving it is dead,
   re-addable code). This needs a destructive deploy as a separate devops step. Confirm delete-now vs.
   leave-orphaned. (Removing it from the page is already done either way.)
2. **Shared util vs. inline** for the 3 status bundles — recommend the shared `c/leadStatusChange`
   module; the inline-per-bundle form (matching `dealSendToDevelopmentReview`) is equally acceptable.
   Any preference?
3. **Toast copy** — proposed: success `"Lead moved to <Status>."`; status error `"The lead status
   could not be updated."`; convert error surfaces the controller's message with fallback `"Unable to
   convert this lead."`. Any specific wording?
4. **Confirm the visibility rules stay a manual App Builder step** (per spec) rather than being
   serialized into the deployed flexipage. (If you'd instead want them deployed, that changes the
   flexipage from a removal-only edit into an add-actions-with-visibility edit — larger, but agent-owned.)

═══════════════════════════════════════════════════════════════════════════════
