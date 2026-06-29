# Lead Record Page — Design Spec

**Date:** 2026-06-09
**Status:** Approved (design); pending spec review → implementation plan
**Context:** DPEG Acquisitions Phase-1 build. Adds a Lead record page mirroring the
existing `Opportunity_Record_Page` ("Acquisition Deal Page"), with a Highlights Panel
matching `docs/lead-highlights-acquisition.png`.

## Goal

Give the standard **Lead** object a Lightning record page that reuses the deal page's
template and component mix, and whose header highlights show four tiles —
**Guidance Price, Cap Rate, BP Expiry, Days in System** — per the supplied mockup.

## Decisions (locked with user)

1. **Highlights = standard Highlights Panel** (`force:highlightsPanel`), consistent with
   the deal page's all-standard component directive — *not* a custom LWC. Driven by a Lead
   compact layout.
2. **Full Opportunity-style body**: Path (subheader) + tabbed Details/Related (main) +
   Activities (sidebar).
3. **Cap Rate tile = `My_Cap_Rate__c`** (DPEG's underwritten cap rate).
4. **Days in System = Text formula** rendering `"3d"` (matches the mockup) rather than a
   numeric field.
5. **Generator drift is real** (the `Primary_*__c` lookups have FLS in the permission set
   but are absent from `gen-metadata.mjs`). Therefore: **hand-author** the new metadata +
   targeted permission-set edits for this deploy; patch the generator as source-of-truth
   but defer any full re-run to a separate, verified reconciliation pass.

## Accepted trade-offs

The standard Highlights Panel will **not** look like the PNG card: it shows the record
name + action buttons, full-precision currency (`$8,200,000.00`, not `$8.2M`), and the
org's locale date format for BP Expiry. The user accepted this when choosing the standard
panel over a custom LWC. We match the mockup only where the panel allows it — notably the
"3d" text and the exact "BP Expiry" / "Days in System" labels (we own those new fields).

---

## Components to build

### A. Two new Lead formula fields

Both mirror `LeadFunnelController` exactly: age and broker-protection expiry derive from
`First_Seen_Date__c` (a DateTime), falling back to `CreatedDate`, with a 90-day window.

**`force-app/main/default/objects/Lead/fields/BP_Expiry__c.field-meta.xml`** — Date formula:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>BP_Expiry__c</fullName>
    <label>BP Expiry</label>
    <type>Date</type>
    <formula>DATEVALUE(IF(ISBLANK(First_Seen_Date__c), CreatedDate, First_Seen_Date__c)) + 90</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <description>Broker protection expiry = First Seen Date (fallback CreatedDate) + 90 days. Mirrors LeadFunnelController.BP_WINDOW_DAYS.</description>
</CustomField>
```

**`force-app/main/default/objects/Lead/fields/Days_in_System__c.field-meta.xml`** — Text formula → `"Nd"`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Days_in_System__c</fullName>
    <label>Days in System</label>
    <type>Text</type>
    <formula>TEXT(TODAY() - DATEVALUE(IF(ISBLANK(First_Seen_Date__c), CreatedDate, First_Seen_Date__c))) &amp; "d"</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <description>Age in days since First Seen Date (fallback CreatedDate), formatted "Nd". Mirrors LeadFunnelController.</description>
</CustomField>
```

Notes: formula fields are read-only — no `<length>` on the text formula; the `&` in the
formula is XML-escaped as `&amp;`.

### B. Compact layout + object assignment (the Highlights Panel source)

**`force-app/main/default/objects/Lead/compactLayouts/Lead_Highlights.compactLayout-meta.xml`** —
field order matches the mockup left→right:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CompactLayout xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Lead_Highlights</fullName>
    <fields>Guidance_Price__c</fields>
    <fields>My_Cap_Rate__c</fields>
    <fields>BP_Expiry__c</fields>
    <fields>Days_in_System__c</fields>
    <label>Lead Highlights</label>
</CompactLayout>
```

**`force-app/main/default/objects/Lead/Lead.object-meta.xml`** (new — assigns the primary
compact layout, exactly as `Opportunity.object-meta.xml` → `Deal_Highlights`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <compactLayoutAssignment>Lead_Highlights</compactLayoutAssignment>
</CustomObject>
```

### C. Permission-set FLS (read-only for formula fields)

Add to `force-app/main/default/permissionsets/DPEG_Acquisitions.permissionset-meta.xml`
(`editable=false` is **required** for formula/read-only fields — `true` fails to deploy):

```xml
    <fieldPermissions>
        <field>Lead.BP_Expiry__c</field><readable>true</readable><editable>false</editable>
    </fieldPermissions>
    <fieldPermissions>
        <field>Lead.Days_in_System__c</field><readable>true</readable><editable>false</editable>
    </fieldPermissions>
```

### D. The flexipage

**`force-app/main/default/flexipages/Lead_Record_Page.flexipage-meta.xml`** —
`<type>RecordPage</type>`, `<sobjectType>Lead</sobjectType>`, master label
**"Lead Intake Page"**, template **`flexipage:recordHomeWithSubheaderTemplateDesktop`**.

Regions (mirrors `Opportunity_Record_Page`):

- **header** → `force:highlightsPanel` (props `collapsed=false`, `enableActionsConfiguration=false`,
  `hideChatterActions=false`).
- **subheader** → `runtime_sales_pathassistant:pathAssistant` (`hideUpdateButton=false`).
  Renders the already-active **`Lead_Funnel_Path`** (entity Lead, field Status, MASTER).
- **main** → one `flexipage:tabset` whose `tabs` property points at a `tabs` Facet
  containing two `flexipage:tab`s:
  - **Details** (`body` → `detailsTabContent` facet) — Dynamic Forms over the Lead's
    *own* fields (no cross-object lookups), built with `flexipage:fieldSection` →
    `flexipage:column` → `fieldInstance` facets, each field referenced as
    `Record.<FieldApiName>`. Two sections:
    - **Lead Info**: `Name`, `Company`, `Status`, `OwnerId`, `LeadSource`
    - **Deal Intake**: `Property_Address__c`, `Asset_Type__c`, `Guidance_Price__c`,
      `Guidance_Cap_Rate__c`, `My_Price__c`, `My_Cap_Rate__c`, `Broker_First__c`,
      `DPEG_First__c`, `Parse_Confidence__c`, `First_Seen_Date__c`, `BP_Expiry__c`,
      `Days_in_System__c`, `CoStar_Link__c`, `Placer_AI_Link__c`, `Deal_Notes__c`,
      `Disqualification_Reason__c`
  - **Related** (`body` → `relatedTabContent` facet) — `force:relatedListContainer`
    (`rowsToDisplay=10`, `showActionBar=true`), surfacing the existing `Lead-Lead Layout`
    related lists (Activities, Activity History, Campaign History, Email Status).
- **sidebar** → `runtime_sales_activities:activityPanel` (`showLegacyActivityComposer=false`).

**XML gotchas to honor** (from `flexipage-template-pattern`): one `<componentInstance>` per
`<itemInstances>` wrapper (repeat the wrapper for siblings); tab `body`/`fieldSection
columns`/`column body` all reference Facet region **names**.

### E. App-scoped page assignment

Add a second `<actionOverrides>` to
`force-app/main/default/applications/Acquisition.app-meta.xml` (org-default assignment is
not deployable; app-scoped is):

```xml
    <actionOverrides>
        <actionName>View</actionName>
        <comment>Lead Intake Page</comment>
        <content>Lead_Record_Page</content>
        <formFactor>Large</formFactor>
        <pageOrSobjectType>Lead</pageOrSobjectType>
        <skipRecordTypeSelect>false</skipRecordTypeSelect>
        <type>Flexipage</type>
    </actionOverrides>
```

### F. Generator update (source-of-truth only — do NOT re-run in this deploy)

Patch `scripts/gen-metadata.mjs` so it stops lying, but treat running it as a separate task:

1. Extend `fieldXml(f)`: when `f.formula` is set, emit the return-type tag (from `f.type`),
   then `<formula>` (escaped) and `<formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>`;
   skip `<length>`/`<default>`.
2. Track read-only: `allFieldPerms.push({ obj, field, readOnly: !!f.formula })` and emit
   `<editable>${readOnly ? false : true}</editable>` in the FLS block.
3. Append the two fields to `standardFields.Lead` with their `formula` strings.

**Reconciliation (out of scope here, flagged for a later pass):** before ever re-running
the generator for real, backfill the missing `Opportunity.Primary_Underwriting__c /
Primary_NDA__c / Primary_LOI__c` lookups into `standardFields.Opportunity`, regenerate to a
scratch diff, and confirm no metadata is dropped. Until then, the hand-authored files above
are the deployed truth.

---

## Deploy order (rollback-safe)

`sf project deploy start` rolls back *all* components on any failure, and a flexipage that
references not-yet-deployed metadata fails with a misleading error. So deploy in stages:

1. **Components:** the two fields, `Lead.object-meta.xml`, `Lead_Highlights` compact layout,
   and the permission-set edit — one successful deploy.
2. **Flexipage:** `Lead_Record_Page`.
3. **App:** `Acquisition` (the new actionOverride).

## Verification

- Each stage's `sf project deploy start` returns success.
- Permission set assigned/refreshed; open a Lead in the **Acquisition** app:
  - Header highlights show the four tiles (Guidance Price, My Cap Rate, BP Expiry,
    Days in System "Nd").
  - Path renders the five Lead statuses; subheader correct.
  - Details tab shows both field sections; Related tab shows Activities/Campaign/Email lists.
  - Activities panel in the right sidebar.
- Sanity-check a seeded Lead: `BP_Expiry__c` = First Seen + 90 and `Days_in_System__c`
  match what the Lead Funnel `recentLeads` table shows for the same record.

## Out of scope

- Custom-LWC highlights card (explicitly declined in favor of the standard panel).
- Any automation/validation on the new fields.
- Full generator re-run / drift reconciliation (separate task, see §F).
- Org-default (non-app-scoped) page assignment — set in App Builder if ever needed.
