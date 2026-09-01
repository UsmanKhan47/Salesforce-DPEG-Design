// Build-time generator for DPEG Acquisitions Phase-1 metadata.
// Emits CustomObject, CustomField, CustomTab and a PermissionSet under force-app.
// Not deployed itself (lives outside force-app). Run: node scripts/gen-metadata.mjs
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const ROOT = 'force-app/main/default';
const w = (p, body) => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, body.trim() + '\n'); };
const xml = (inner) => `<?xml version="1.0" encoding="UTF-8"?>\n${inner}`;
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// ---- field XML --------------------------------------------------------------
function picklistBody(values) {
  const vals = values.map((v, i) => {
    const label = typeof v === 'string' ? v : v.label;
    const def = typeof v === 'object' && v.default ? '<default>true</default>' : '<default>false</default>';
    return `            <value><fullName>${esc(label)}</fullName>${def}<label>${esc(label)}</label></value>`;
  }).join('\n');
  return `        <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
${vals}
        </valueSetDefinition>
    </valueSet>`;
}

function fieldXml(f) {
  const lines = [`    <fullName>${f.name}</fullName>`, `    <label>${esc(f.label)}</label>`];
  const t = f.type;
  if (f.formula) {
    // Read-only formula field. f.type is the RETURN type.
    if (t === 'Number') { lines.push('    <type>Number</type>', `    <precision>${f.precision || 18}</precision>`, `    <scale>${f.scale || 0}</scale>`); }
    else if (t === 'Currency') { lines.push('    <type>Currency</type>', '    <precision>18</precision>', '    <scale>2</scale>'); }
    else if (t === 'Percent') { lines.push('    <type>Percent</type>', '    <precision>5</precision>', '    <scale>2</scale>'); }
    else if (t === 'Date') { lines.push('    <type>Date</type>'); }
    else if (t === 'DateTime') { lines.push('    <type>DateTime</type>'); }
    else if (t === 'Checkbox') { lines.push('    <type>Checkbox</type>'); }
    else { lines.push('    <type>Text</type>'); }
    lines.push(`    <formula>${esc(f.formula)}</formula>`, '    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>');
    if (f.description) lines.push(`    <description>${esc(f.description)}</description>`);
    return xml(`<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">\n${lines.join('\n')}\n</CustomField>`);
  }
  if (t === 'Text') { lines.push('    <type>Text</type>', `    <length>${f.length || 255}</length>`); }
  else if (t === 'TextArea') { lines.push('    <type>TextArea</type>'); }
  else if (t === 'LongTextArea') { lines.push('    <type>LongTextArea</type>', '    <length>32768</length>', '    <visibleLines>3</visibleLines>'); }
  else if (t === 'Currency') { lines.push('    <type>Currency</type>', '    <precision>18</precision>', '    <scale>2</scale>'); }
  else if (t === 'Percent') { lines.push('    <type>Percent</type>', '    <precision>5</precision>', '    <scale>2</scale>'); }
  else if (t === 'Number') { lines.push('    <type>Number</type>', `    <precision>${f.precision || 18}</precision>`, `    <scale>${f.scale || 0}</scale>`); }
  else if (t === 'Date') { lines.push('    <type>Date</type>'); }
  else if (t === 'DateTime') { lines.push('    <type>DateTime</type>'); }
  else if (t === 'Checkbox') { lines.push('    <type>Checkbox</type>', `    <defaultValue>${f.default || false}</defaultValue>`); }
  else if (t === 'Url') { lines.push('    <type>Url</type>'); }
  else if (t === 'Picklist') { lines.push('    <type>Picklist</type>', picklistBody(f.values)); }
  else if (t === 'Lookup') {
    lines.push('    <type>Lookup</type>', `    <referenceTo>${f.ref}</referenceTo>`,
      `    <relationshipLabel>${esc(f.relLabel || f.label)}</relationshipLabel>`,
      `    <relationshipName>${f.relName}</relationshipName>`, '    <required>false</required>',
      '    <deleteConstraint>SetNull</deleteConstraint>');
  }
  if (f.description) lines.push(`    <description>${esc(f.description)}</description>`);
  return xml(`<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">\n${lines.join('\n')}\n</CustomField>`);
}

// ---- object + tab -----------------------------------------------------------
function objectXml(o) {
  const nameField = o.nameType === 'AutoNumber'
    ? `    <nameField>\n        <type>AutoNumber</type>\n        <displayFormat>${o.autoFmt}</displayFormat>\n        <label>${esc(o.nameLabel)}</label>\n    </nameField>`
    : `    <nameField>\n        <type>Text</type>\n        <label>${esc(o.nameLabel)}</label>\n    </nameField>`;
  return xml(`<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <deploymentStatus>Deployed</deploymentStatus>
    <label>${esc(o.label)}</label>
    <pluralLabel>${esc(o.plural)}</pluralLabel>
${nameField}
    <sharingModel>ReadWrite</sharingModel>
    <enableActivities>true</enableActivities>
    <enableHistory>true</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
</CustomObject>`);
}

function tabXml(motif) {
  return xml(`<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <customObject>true</customObject>
    <motif>${motif}</motif>
</CustomTab>`);
}

// ---- data model -------------------------------------------------------------
// ---- Asset_Type__c, ONE source of truth for all three objects (Gap 1, 2026-08-31) -----------
//
// 🔴 THIS SPLIT IS THE FIX FOR A REAL DEFECT. Until 2026-08-31 there was a single `ASSET`
// constant used for Property__c and Lead, and the Opportunity list was HARDCODED INLINE further
// down this file with a sixth, different set that spelled Retail as 'Retail Strip'. That inline
// list is where the divergence came from: every org rebuild regenerated an Opportunity picklist
// that no Lead value could satisfy, so LeadConvertService's describe guard silently dropped the
// asset type on every converted deal and the acquisition funnel reported null for all of them.
// If you collapse these back into one constant, or re-inline a list at a call site, you rebuild
// the defect.
//
// The relationship is a SUBSET one and must stay that way: Lead == Opportunity, and Property__c
// is those plus two asset-management-only types. LeadConvertService copies Lead -> Opportunity
// AND Lead -> Property__c, so `ASSET_CORE ⊆ ASSET_PROPERTY` is what keeps both writes total.
// The old constant was ALSO stale in its own right — it carried C-Store and Storage but had
// never gained Hospitality or Medical Office, which both Lead and Property__c have in the org.
const ASSET_CORE = [
  'Retail', 'Land', 'Industrial', 'Office', 'Multifamily', 'Mixed-Use', 'Hospitality', 'Medical Office',
];
// C-Store and Storage exist only on Property__c: they are asset-management categories, and no
// inbound broker email / Lead can ever produce them. Adding them to ASSET_CORE would create two
// Opportunity values no automation could ever write.
const ASSET_PROPERTY = [...ASSET_CORE, 'C-Store', 'Storage'];
const objects = {
  Property__c: {
    label: 'Property', plural: 'Properties', nameType: 'Text', nameLabel: 'Property Name', motif: 'Custom20: Asset',
    fields: [
      { name: 'Address__c', label: 'Address', type: 'Text' },
      { name: 'City__c', label: 'City', type: 'Text', length: 100 },
      { name: 'State__c', label: 'State', type: 'Text', length: 50 },
      { name: 'Zip__c', label: 'Zip', type: 'Text', length: 20 },
      { name: 'Parcel_ID__c', label: 'Parcel ID', type: 'Text', length: 50 },
      { name: 'Asset_Type__c', label: 'Asset Type', type: 'Picklist', values: ASSET_PROPERTY },
      { name: 'Market_Cap_Rate__c', label: 'Market Cap Rate', type: 'Percent', description: 'CoStar via ASB (stub)' },
      { name: 'Market_Rent_PSF__c', label: 'Market Rent PSF', type: 'Currency' },
      { name: 'Occupancy_Rate_Market__c', label: 'Occupancy Rate Market', type: 'Percent' },
      { name: 'Comp_Sales__c', label: 'Comp Sales', type: 'LongTextArea' },
      { name: 'Days_On_Market_Avg__c', label: 'Days On Market Avg', type: 'Number' },
      { name: 'CoStar_URL__c', label: 'CoStar URL', type: 'Url' },
      { name: 'Monthly_Visits__c', label: 'Monthly Visits', type: 'Number', description: 'Placer.ai (stub)' },
      { name: 'YoY_Growth__c', label: 'YoY Growth', type: 'Percent' },
      { name: 'Peak_Hour__c', label: 'Peak Hour', type: 'Text', length: 50 },
      { name: 'Visitor_Demographics__c', label: 'Visitor Demographics', type: 'LongTextArea' },
      { name: 'Trade_Area_Population__c', label: 'Trade Area Population', type: 'Number' },
      { name: 'Comp_Monthly_Visits__c', label: 'Comp Monthly Visits', type: 'Number' },
      { name: 'Placer_Fetch_Status__c', label: 'Placer Fetch Status', type: 'Picklist', values: ['Success', 'Error'] },
      { name: 'Placer_URL__c', label: 'Placer URL', type: 'Url' },
    ],
  },
  NDA__c: {
    label: 'NDA', plural: 'NDAs', nameType: 'AutoNumber', nameLabel: 'NDA Number', autoFmt: 'NDA-{0000}', motif: 'Custom53: Lock',
    fields: [
      { name: 'Opportunity__c', label: 'Opportunity', type: 'Lookup', ref: 'Opportunity', relName: 'NDAs' },
      { name: 'Status__c', label: 'Status', type: 'Picklist', values: [{ label: 'Pending', default: true }, 'Sent', 'Signed'] },
      { name: 'Date_Sent__c', label: 'Date Sent', type: 'Date' },
      { name: 'Date_Signed__c', label: 'Date Signed', type: 'Date' },
      { name: 'NDA_Expiry_Date__c', label: 'NDA Expiry Date', type: 'Date' },
      { name: 'NDA_Signed__c', label: 'NDA Signed', type: 'Checkbox' },
      { name: 'Method__c', label: 'Method', type: 'Picklist', values: ['DocuSign', 'Wet Sign'] },
      { name: 'OneDrive_URL__c', label: 'OneDrive URL', type: 'Url' },
    ],
  },
  Underwriting__c: {
    label: 'Underwriting', plural: 'Underwritings', nameType: 'AutoNumber', nameLabel: 'Underwriting Number', autoFmt: 'UW-{0000}', motif: 'Custom19: Magnifying Glass',
    fields: [
      { name: 'Opportunity__c', label: 'Opportunity', type: 'Lookup', ref: 'Opportunity', relName: 'Underwritings' },
      { name: 'My_Price__c', label: 'My Price', type: 'Currency' },
      { name: 'My_Cap_Rate__c', label: 'My Cap Rate', type: 'Percent' },
      { name: 'Market_Cap_Rate__c', label: 'Market Cap Rate', type: 'Percent' },
      { name: 'Underwritten_NOI__c', label: 'Underwritten NOI', type: 'Currency' },
      { name: 'Target_Return__c', label: 'Target Return', type: 'Percent' },
      { name: 'Hold_Period__c', label: 'Hold Period (yrs)', type: 'Number' },
      { name: 'Equity_Required__c', label: 'Equity Required', type: 'Currency' },
      { name: 'Projected_Loan__c', label: 'Projected Loan', type: 'Currency' },
      { name: 'GRM__c', label: 'GRM', type: 'Number', precision: 4, scale: 1, description: "Gross Rent Multiplier - entered manually from Junior's Excel model." },
      { name: 'Year_5_IRR__c', label: 'Year 5 IRR', type: 'Percent', description: "5-year levered IRR - entered manually from Junior's Excel model." },
      { name: 'Underwriting_OneDrive_URL__c', label: 'Underwriting OneDrive URL', type: 'Url' },
    ],
  },
  LOI__c: {
    label: 'LOI', plural: 'LOIs', nameType: 'AutoNumber', nameLabel: 'LOI Number', autoFmt: 'LOI-{0000}', motif: 'Custom33: Form',
    fields: [
      { name: 'Opportunity__c', label: 'Opportunity', type: 'Lookup', ref: 'Opportunity', relName: 'LOIs' },
      { name: 'LOI_Status__c', label: 'LOI Status', type: 'Picklist', values: [{ label: 'Draft', default: true }, 'Pending Approval', 'Approved', 'Rejected', 'Submitted', 'Working', 'Countered', 'Killed', 'Signed'] },
      { name: 'Offer_Price__c', label: 'Offer Price', type: 'Currency' },
      { name: 'Offer_Cap_Rate__c', label: 'Offer Cap Rate', type: 'Percent' },
      { name: 'Submitted_Date__c', label: 'Submitted Date', type: 'Date' },
      { name: 'Counter_Price__c', label: 'Counter Price', type: 'Currency' },
      { name: 'Counter_Cap_Rate__c', label: 'Counter Cap Rate', type: 'Percent' },
      { name: 'Counter_Received_Date__c', label: 'Counter Received Date', type: 'Date' },
      { name: 'Counter_Response_Due__c', label: 'Counter Response Due', type: 'Date' },
      { name: 'LOI_Signed__c', label: 'LOI Signed', type: 'Checkbox' },
      { name: 'LOI_Signed_Date__c', label: 'LOI Signed Date', type: 'Date' },
      { name: 'Approved_Date__c', label: 'Approved Date', type: 'Date' },
      { name: 'OneDrive_URL__c', label: 'OneDrive URL', type: 'Url' },
    ],
  },
  Transaction__c: {
    label: 'Transaction', plural: 'Transactions', nameType: 'AutoNumber', nameLabel: 'Transaction Number', autoFmt: 'TXN-{0000}', motif: 'Custom16: Briefcase',
    fields: [
      { name: 'Opportunity__c', label: 'Opportunity', type: 'Lookup', ref: 'Opportunity', relName: 'Transactions' },
      { name: 'Status__c', label: 'Status', type: 'Picklist', values: [{ label: 'Draft', default: true }, 'Active', 'Closed'] },
      { name: 'Contract_Executed_Date__c', label: 'Contract Executed Date', type: 'Date' },
      { name: 'OneDrive_URL__c', label: 'OneDrive URL', type: 'Url' },
    ],
  },
  Offering__c: {
    label: 'Offering', plural: 'Offerings', nameType: 'AutoNumber', nameLabel: 'Offering Number', autoFmt: 'OFR-{0000}', motif: 'Custom51: Money',
    fields: [
      { name: 'Opportunity__c', label: 'Opportunity', type: 'Lookup', ref: 'Opportunity', relName: 'Offerings' },
      { name: 'Status__c', label: 'Status', type: 'Picklist', values: [{ label: 'Draft', default: true }, 'Active', 'Closed'] },
      { name: 'IR_Owner__c', label: 'IR Owner', type: 'Lookup', ref: 'User', relName: 'IR_Offerings' },
    ],
  },
  Property_Asset__c: {
    label: 'Property Asset', plural: 'Property Assets', nameType: 'Text', nameLabel: 'Asset Name', motif: 'Custom25: Building',
    fields: [
      { name: 'Property__c', label: 'Property', type: 'Lookup', ref: 'Property__c', relName: 'Property_Assets' },
      { name: 'Closing_Date__c', label: 'Closing Date', type: 'Date' },
      { name: 'Final_Purchase_Price__c', label: 'Final Purchase Price', type: 'Currency' },
      { name: 'Status__c', label: 'Status', type: 'Picklist', values: [{ label: 'Active', default: true }, 'Disposed'] },
      { name: 'NOI__c', label: 'NOI', type: 'Currency' },
      { name: 'Market_Cap_Rate__c', label: 'Market Cap Rate', type: 'Percent' },
      { name: 'Target_Sale_Price__c', label: 'Target Sale Price', type: 'Currency' },
      { name: 'Argus_Signal__c', label: 'Argus Signal', type: 'Picklist', values: ['Sell Now', '12 mo', 'Hold'] },
    ],
  },
};

// custom fields on standard objects
const standardFields = {
  Lead: [
    { name: 'First_Seen_Date__c', label: 'First Seen Date', type: 'DateTime', description: 'Immutable - starts 90-day broker protection window' },
    { name: 'Guidance_Price__c', label: 'Guidance Price', type: 'Currency' },
    { name: 'Guidance_Cap_Rate__c', label: 'Guidance Cap Rate', type: 'Percent' },
    { name: 'My_Price__c', label: 'My Price', type: 'Currency' },
    { name: 'My_Cap_Rate__c', label: 'My Cap Rate', type: 'Percent' },
    { name: 'Asset_Type__c', label: 'Asset Type', type: 'Picklist', values: ASSET_CORE },
    { name: 'Property_Address__c', label: 'Property Address', type: 'Text' },
    { name: 'Broker_First__c', label: 'Broker First', type: 'Text' },
    { name: 'DPEG_First__c', label: 'DPEG First', type: 'Lookup', ref: 'User', relName: 'DPEG_First_Leads' },
    { name: 'Parse_Confidence__c', label: 'Parse Confidence', type: 'Picklist', values: ['HIGH', 'MEDIUM', 'LOW'] },
    { name: 'Deal_Notes__c', label: 'Deal Notes', type: 'LongTextArea' },
    { name: 'Disqualification_Reason__c', label: 'Disqualification Reason', type: 'Picklist', values: ['Wrong Market', 'Price Too High', 'Bad Anchor Tenant', 'Duplicate Deal', 'Portfolio Declined', 'Other'] },
    { name: 'Placer_AI_Link__c', label: 'Placer AI Link', type: 'Url' },
    { name: 'CoStar_Link__c', label: 'CoStar Link', type: 'Url' },
    { name: 'BP_Expiry__c', label: 'BP Expiry', type: 'Date', formula: 'DATEVALUE(IF(ISBLANK(First_Seen_Date__c), CreatedDate, First_Seen_Date__c)) + 90', description: 'Broker protection expiry = First Seen Date (fallback CreatedDate) + 90 days. Mirrors LeadFunnelController.BP_WINDOW_DAYS.' },
    { name: 'Days_in_System__c', label: 'Days in System', type: 'Text', formula: 'TEXT(TODAY() - DATEVALUE(IF(ISBLANK(First_Seen_Date__c), CreatedDate, First_Seen_Date__c))) & "d"', description: 'Age in days since First Seen Date (fallback CreatedDate), formatted "Nd". Mirrors LeadFunnelController.' },
  ],
  Opportunity: [
    { name: 'Deal_Status__c', label: 'Deal Status', type: 'Picklist', values: ['Evaluating', 'Working', 'Countered', 'Killed', 'On Hold', 'LOI Signed', 'Contract Signed', 'Asset Under Management'] },
    { name: 'Deal_Category__c', label: 'Deal Category', type: 'Picklist', values: [{ label: 'Live', default: true }, 'Dead', 'Closed'] },
    // 🔴 ASSET_CORE, NOT AN INLINE LIST, AND NOT ASSET_PROPERTY. This line held
    // ['Retail Strip', 'Office', 'Industrial', 'Land', 'Multifamily', 'Mixed-Use'] until
    // 2026-08-31 and WAS the root cause of Gap 1 — see the constant's header near the top of this
    // file. It must stay pointed at the SAME constant as the Lead field below/above it: a Lead
    // value the Opportunity picklist lacks is dropped silently at conversion, and a value the
    // Opportunity RECORD TYPES lack rolls the whole conversion chunk back.
    { name: 'Asset_Type__c', label: 'Asset Type', type: 'Picklist', values: ASSET_CORE },
    { name: 'Asking_Price__c', label: 'Asking Price', type: 'Currency' },
    { name: 'My_Price__c', label: 'My Price', type: 'Currency' },
    { name: 'My_Cap_Rate__c', label: 'My Cap Rate', type: 'Percent' },
    { name: 'Market_Cap_Rate__c', label: 'Market Cap Rate', type: 'Percent' },
    // WS2 (2026-08-30): DateTime, NOT Date. It mirrors Lead.First_Seen_Date__c, which is a
    // DateTime despite its Date-suffixed name. Reverting this to 'Date' regenerates the field at
    // the old type and silently breaks LeadConvertService.applyDealFields and CallForOffersService.
    { name: 'Broker_First_Seen__c', label: 'Broker First Seen', type: 'DateTime', description: 'Copied from Lead.First_Seen_Date__c at Conversion 1 - drives 90-day protection' },
    { name: 'Contract_Executed_Date__c', label: 'Contract Executed Date', type: 'DateTime', description: 'Day 0 trigger field' },
    { name: 'Loan_Required__c', label: 'Loan Required', type: 'Checkbox' },
    { name: 'OneDrive_Folder_URL__c', label: 'OneDrive Folder URL', type: 'Url' },
    { name: 'Rejection_Reason__c', label: 'Rejection Reason', type: 'Picklist', values: ['Wrong Market', 'Price Too High', 'Bad Anchor Tenant', 'Failed DD', 'Lost to Competitor', 'Seller Withdrew', 'Other'] },
    { name: 'Property__c', label: 'Property', type: 'Lookup', ref: 'Property__c', relName: 'Opportunities' },
    { name: 'Placer_URL__c', label: 'Placer URL', type: 'Url' },
    { name: 'CoStar_URL__c', label: 'CoStar URL', type: 'Url' },
  ],
};

// ---- emit -------------------------------------------------------------------
const allFieldPerms = []; // {obj, field}
for (const [api, o] of Object.entries(objects)) {
  w(`${ROOT}/objects/${api}/${api}.object-meta.xml`, objectXml(o));
  w(`${ROOT}/tabs/${api}.tab-meta.xml`, tabXml(o.motif));
  for (const f of o.fields) {
    w(`${ROOT}/objects/${api}/fields/${f.name}.field-meta.xml`, fieldXml(f));
    allFieldPerms.push({ obj: api, field: f.name, readOnly: !!f.formula });
  }
}
for (const [api, fields] of Object.entries(standardFields)) {
  for (const f of fields) {
    w(`${ROOT}/objects/${api}/fields/${f.name}.field-meta.xml`, fieldXml(f));
    allFieldPerms.push({ obj: api, field: f.name, readOnly: !!f.formula });
  }
}

// permission set granting field/object/tab access to the running admin
const objPerms = Object.keys(objects).map((api) => `    <objectPermissions>
        <object>${api}</object>
        <allowRead>true</allowRead><allowCreate>true</allowCreate><allowEdit>true</allowEdit>
        <allowDelete>true</allowDelete><viewAllRecords>true</viewAllRecords><modifyAllRecords>true</modifyAllRecords>
    </objectPermissions>`).join('\n');
const fieldPerms = allFieldPerms.map(({ obj, field, readOnly }) => `    <fieldPermissions>
        <field>${obj}.${field}</field><readable>true</readable><editable>${readOnly ? false : true}</editable>
    </fieldPermissions>`).join('\n');
const tabPerms = Object.keys(objects).map((api) => `    <tabSettings><tab>${api}</tab><visibility>Visible</visibility></tabSettings>`).join('\n');
w(`${ROOT}/permissionsets/DPEG_Acquisitions.permissionset-meta.xml`, xml(`<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>DPEG Acquisitions</label>
    <hasActivationRequired>false</hasActivationRequired>
${objPerms}
${fieldPerms}
${tabPerms}
    <tabSettings><tab>Lead_Intake</tab><visibility>Visible</visibility></tabSettings>
    <classAccesses><apexClass>LeadFunnelController</apexClass><enabled>true</enabled></classAccesses>
</PermissionSet>`));

// ---- page layouts for custom objects ---------------------------------------
function layoutItem(field, behavior) {
  return `                <layoutItems>
                    <behavior>${behavior}</behavior>
                    <field>${field}</field>
                </layoutItems>`;
}
function customObjectLayout(api, o) {
  const nameBehavior = o.nameType === 'AutoNumber' ? 'Readonly' : 'Required';
  const fieldNames = o.fields.map((f) => f.name);
  const half = Math.ceil(fieldNames.length / 2);
  const col1 = [layoutItem('Name', nameBehavior), ...fieldNames.slice(0, half).map((f) => layoutItem(f, 'Edit'))].join('\n');
  const col2 = [...fieldNames.slice(half).map((f) => layoutItem(f, 'Edit')), layoutItem('OwnerId', 'Edit')].join('\n');
  return xml(`<Layout xmlns="http://soap.sforce.com/2006/04/metadata">
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>${esc(o.label)} Information</label>
        <layoutColumns>
${col1}
        </layoutColumns>
        <layoutColumns>
${col2}
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>
    <showEmailCheckbox>false</showEmailCheckbox>
    <showHighlightsPanel>false</showHighlightsPanel>
    <showInteractionLogPanel>false</showInteractionLogPanel>
    <showRunAssignmentRulesCheckbox>false</showRunAssignmentRulesCheckbox>
    <showSubmitAndAttachButton>false</showSubmitAndAttachButton>
</Layout>`);
}
for (const [api, o] of Object.entries(objects)) {
  w(`${ROOT}/layouts/${api}-${o.label} Layout.layout-meta.xml`, customObjectLayout(api, o));
}

console.log('Generated metadata for', Object.keys(objects).length, 'objects and',
  allFieldPerms.length, 'fields.');
