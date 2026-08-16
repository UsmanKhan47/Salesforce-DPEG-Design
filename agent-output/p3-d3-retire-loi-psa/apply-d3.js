#!/usr/bin/env node
/*
 * P3-D3 — the SUBTRACTIVE step of Phase 3 (Acquisition Observations, observations 5 and 7).
 *
 * Run from the repo root:
 *     node agent-output/p3-d3-retire-loi-psa/apply-d3.js --check   # validates, writes NOTHING
 *     node agent-output/p3-d3-retire-loi-psa/apply-d3.js           # writes, all-or-nothing
 *
 * 🔴 TWO-PHASE AND ATOMIC BY CONSTRUCTION. Every edit is applied IN MEMORY first and each one
 *    asserts EXACTLY ONE match. If any edit fails to match exactly once, NOTHING is written.
 *    This is not stylistic: Phase 1's equivalent script was NOT atomic until review C3 found
 *    that a drift on edit 7 of 12 left edits 1-6 on disk, i.e. a half-applied IRREVERSIBLE pass.
 *
 * 🔴 IT ASSERTS, IT DOES NOT PRINT REASSURANCE. Every check below exits non-zero on failure.
 *    A script that prints "looks fine" months before it runs is a claim, not a check.
 *
 * 🔴 PRECONDITION THIS SCRIPT CANNOT CHECK — RUN THE ORG QUERIES IN THE RUNBOOK FIRST.
 *    Deactivating a picklist value while rows still hold it strands those rows on a value the
 *    Path cannot render. The queries are in
 *    agent-output/runbook-acquisition-observations-phase3.md, step P3-D3.
 *
 * 🔴 WHAT THIS SCRIPT DELIBERATELY DOES *NOT* DO — decision O3, a HARD STOP:
 *    it does NOT deactivate ANY value on Contract_Review__c.Negotiation_Status__c.
 *    'Initial Draft', 'Revised' and 'Ready for Execution' stay ACTIVE on the field because
 *    Disposition_PSA still runs on all three. They are removed from the ACQUISITION RECORD TYPE
 *    only. Anyone "harmonising" this with the LOI half deletes the sell-side PSA sequence.
 */

const fs = require('fs');
const path = require('path');

const ROOT = process.cwd();
const CHECK = process.argv.includes('--check');
const R = (p) => path.join(ROOT, 'force-app', 'main', 'default', p);

const LOI_STAGE   = R('objects/LOI__c/fields/Stage__c.field-meta.xml');
const LOI_ADV     = R('objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml');
const LOI_RT      = R('objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml');
const LOI_PATH    = R('pathAssistants/LOI_Path_Acquisition.pathAssistant-meta.xml');
const OPP_VR      = R('objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml');
const PSA_RT      = R('objects/Contract_Review__c/recordTypes/Acquisition_PSA.recordType-meta.xml');
const PSA_PATH    = R('pathAssistants/Contract_Review_Path_Acquisition.pathAssistant-meta.xml');

const RETIRED_LOI = ['Prepare/Review', 'Sent', 'Counter', 'Completed'];
const RETIRED_LOI_RT = ['Prepare%2FReview', 'Sent', 'Counter', 'Completed']; // encoded inside a RecordType
const RETIRED_PSA_RT = ['Initial Draft', 'Revised', 'Ready for Execution'];

const edits = [];
const problems = [];

function edit(label, file, find, replace) {
  edits.push({ label, file, find, replace });
}

/* ------------------------------------------------------------------ *
 * 1. LOI__c.Stage__c — DEACTIVATE the four retired acquisition values.
 *    Element order <fullName> <default> <isActive> <label> follows the deployed precedent in
 *    objects/Contract_Review__c/fields/Stage__c.field-meta.xml, which carries three inactive
 *    CustomValues in exactly this shape. That is a CustomValue precedent on a CUSTOM field, so
 *    unlike Phase 2's StandardValue case it is not an extrapolation.
 *    NOTHING IS DELETED (decision O3) - an inactive value keeps every historical row, report
 *    filter and Path reference resolvable.
 * ------------------------------------------------------------------ */
for (const v of RETIRED_LOI) {
  edit(
    `LOI Stage__c: deactivate '${v}'`,
    LOI_STAGE,
    `            <value>\n                <fullName>${v}</fullName>\n                <default>false</default>\n                <label>${v}</label>\n            </value>\n`,
    `            <value>\n                <fullName>${v}</fullName>\n                <default>false</default>\n                <isActive>false</isActive>\n                <label>${v}</label>\n            </value>\n`
  );
}

/* ------------------------------------------------------------------ *
 * 2. Acquisition_LOI record type — REMOVE the four retired values.
 *    They are appended AFTER the four live ones in the Stage__c block precisely so this removal
 *    is one contiguous cut. 'Sent' / 'Counter' / 'Completed' do not appear as values on the
 *    object's other two picklists (LOI_Status__c carries 'Countered' and 'Signed', not these),
 *    but the cut is anchored on the contiguous block anyway so it cannot stray.
 * ------------------------------------------------------------------ */
edit(
  'Acquisition_LOI: drop the four retired Stage__c values',
  LOI_RT,
  RETIRED_LOI_RT.map(v => `        <values>\n            <fullName>${v}</fullName>\n            <default>false</default>\n        </values>\n`).join(''),
  ''
);

/* ------------------------------------------------------------------ *
 * 3. LOI_Path_Acquisition — REMOVE the four retired steps.
 *    Nine steps collapse to the intended five: Draft, Under Review, Submitted, Negotiation,
 *    Signed.
 * ------------------------------------------------------------------ */
const LOI_PATH_CUT =
`    <pathAssistantSteps>
        <info>Prepare and review the LOI internally. Validate the terms, route it for any required approval, and refine based on feedback before finalizing.</info>
        <picklistValueName>Prepare/Review</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>LOI sent to the seller/broker. Awaiting their response - a counter moves it to the Counter stage.</info>
        <picklistValueName>Sent</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>Counter-offer stage. Track the back-and-forth with the seller - log each counter in the Counter History and update the offer terms until both sides align.</info>
        <picklistValueName>Counter</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>LOI finalized and complete. Record is closed out for this stage of the deal.</info>
        <picklistValueName>Completed</picklistValueName>
    </pathAssistantSteps>
`;
edit('LOI_Path_Acquisition: drop the four retired steps', LOI_PATH, LOI_PATH_CUT, '');

/* ------------------------------------------------------------------ *
 * 4. Completed_LOI_Before_PSA — drop the transitional 'Completed' leg.
 *    From P3-D1 the rule reads "neither Completed NOR Signed", which is what makes it correct on
 *    BOTH sides of the row migration. Once the migration has provably completed, no acquisition
 *    LOI can read 'Completed' and the leg is dead weight.
 *    ⚠ ORDER: the 'Signed' leg is FIRST in the formula, so the cut removes the trailing line.
 * ------------------------------------------------------------------ */
edit(
  'Completed_LOI_Before_PSA: drop the transitional Completed leg',
  OPP_VR,
  `    TEXT(Primary_LOI__r.Stage__c) &lt;&gt; &apos;Signed&apos;,\n    TEXT(Primary_LOI__r.Stage__c) &lt;&gt; &apos;Completed&apos;\n)`,
  `    TEXT(Primary_LOI__r.Stage__c) &lt;&gt; &apos;Signed&apos;\n)`
);

/* ------------------------------------------------------------------ *
 * 5. Is_Advance_Allowed__c — drop the three transitional clauses.
 *    'Completed' and 'Sent' were named alongside their replacements ('Signed', 'Submitted') so
 *    the formula was correct on both sides of the migration; the whole Prepare/Review
 *    disjunction is superseded by the record-type-guarded Under Review one directly above it.
 *    ⚠ WHAT SURVIVES AND MUST NOT BE TOUCHED: the RecordType.DeveloperName guard on the
 *    Under Review clause. Removing it hides the DISPOSITION Advance Stage button at step 2 of 5.
 * ------------------------------------------------------------------ */
edit(
  'Is_Advance_Allowed__c: drop the transitional Completed clause',
  LOI_ADV,
  `  TEXT(Stage__c) <> "Completed",\n`,
  ''
);
edit(
  'Is_Advance_Allowed__c: drop the transitional Sent clause',
  LOI_ADV,
  `  TEXT(Stage__c) <> "Sent",\n`,
  ''
);
edit(
  'Is_Advance_Allowed__c: drop the superseded Prepare/Review disjunction',
  LOI_ADV,
  `  OR(\n    TEXT(Stage__c) <> "Prepare/Review",\n    TEXT(LOI_Status__c) = "Approved"\n  ),\n`,
  ''
);

/* ------------------------------------------------------------------ *
 * 6. Acquisition_PSA record type — REMOVE the three retiring values and MOVE THE DEFAULT.
 *    🔴 THE DEFAULT FLIP IS NOT COSMETIC. 'Initial Draft' currently carries default=true on this
 *    record type; removing it without promoting another value leaves the record type with NO
 *    default. And note what the flip does NOT fix: a record-type default does not apply to Apex
 *    DML, so OpportunityReviewService's insert still takes the FIELD default ('Initial Draft')
 *    and lands on a value that is no longer on its own record type - silently, because
 *    record-type picklist restriction is UI-ONLY. That is requirements C3 and it is DEVELOPER
 *    work that must land in the same window as this step.
 *    🔴 NOTHING IS DEACTIVATED ON THE FIELD. Disposition_PSA runs on all three.
 * ------------------------------------------------------------------ */
edit(
  'Acquisition_PSA: promote Draft to the record-type default',
  PSA_RT,
  `        <values>\n            <fullName>Draft</fullName>\n            <default>false</default>\n        </values>\n`,
  `        <values>\n            <fullName>Draft</fullName>\n            <default>true</default>\n        </values>\n`
);
edit(
  'Acquisition_PSA: drop the three retiring Negotiation_Status__c values',
  PSA_RT,
  `        <values>\n            <fullName>Initial Draft</fullName>\n            <default>true</default>\n        </values>\n` +
  RETIRED_PSA_RT.slice(1).map(v => `        <values>\n            <fullName>${v}</fullName>\n            <default>false</default>\n        </values>\n`).join(''),
  ''
);

/* ------------------------------------------------------------------ *
 * 7. Contract_Review_Path_Acquisition — REMOVE the three retiring steps.
 *    Seven steps collapse to the intended four: Draft, Negotiation, Signed, Executed.
 * ------------------------------------------------------------------ */
const PSA_PATH_CUT =
`    <pathAssistantSteps>
        <info>Draft the purchase &amp;amp; sale agreement from the agreed LOI terms. Circulate the first draft and capture the PSA date.</info>
        <picklistValueName>Initial Draft</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>Review the PSA internally. Validate terms, contingencies and timelines. Redlines happen here: log every exchange with Log Version — each one records who sent it and flips Ball In Court — and stay on this step for as long as the negotiation runs. Advance only once the document is final.</info>
        <picklistValueName>Revised</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>Terms are locked and the document is final. Route for signature. Advancing from here executes the contract, so confirm every contingency and date is agreed first.</info>
        <picklistValueName>Ready for Execution</picklistValueName>
    </pathAssistantSteps>
`;
edit('Contract_Review_Path_Acquisition: drop the three retiring steps', PSA_PATH, PSA_PATH_CUT, '');

/* ================================================================== *
 * PHASE 1 — validate every edit in memory. Write nothing.
 * ================================================================== */
const buffers = new Map();
function load(f) {
  if (!buffers.has(f)) {
    if (!fs.existsSync(f)) { problems.push(`MISSING FILE: ${f}`); buffers.set(f, null); }
    else buffers.set(f, fs.readFileSync(f, 'utf8'));
  }
  return buffers.get(f);
}

for (const e of edits) {
  const before = load(e.file);
  if (before === null) { problems.push(`SKIPPED (file missing): ${e.label}`); continue; }
  const count = before.split(e.find).length - 1;
  if (count !== 1) {
    problems.push(`EXPECTED EXACTLY 1 MATCH, FOUND ${count}: ${e.label}\n      in ${path.relative(ROOT, e.file)}`);
    continue;
  }
  buffers.set(e.file, before.replace(e.find, e.replace));
  console.log(`  ok   ${e.label}`);
}

/* Post-conditions the edits alone do not guarantee. Each is an ASSERT. */
function assertContains(f, needle, why) {
  const t = buffers.get(f);
  if (t === null || t === undefined) return;
  if (!t.includes(needle)) problems.push(`POST-CONDITION FAILED in ${path.relative(ROOT, f)}: ${why}`);
}
function assertAbsent(f, needle, why) {
  const t = buffers.get(f);
  if (t === null || t === undefined) return;
  if (t.includes(needle)) problems.push(`POST-CONDITION FAILED in ${path.relative(ROOT, f)}: ${why}`);
}

// The record-type guard is the whole reason the disposition Advance Stage button survives.
assertContains(LOI_ADV, 'RecordType.DeveloperName <> "Acquisition_LOI"',
  'the Under Review record-type guard was removed — this hides the DISPOSITION Advance Stage button at step 2 of 5');
assertContains(LOI_ADV, 'TEXT(Stage__c) <> "Signed"', 'the acquisition terminal clause is gone');
assertContains(LOI_ADV, 'TEXT(Stage__c) <> "Executed"', 'the disposition terminal clause is gone');
assertContains(LOI_ADV, 'TEXT(Stage__c) <> "Submitted"', 'the branch-point clause is gone');

// O3 is a hard stop: no deactivation may reach Negotiation_Status__c.
const NEG = R('objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml');
if (fs.existsSync(NEG) && /<isActive>false<\/isActive>/.test(fs.readFileSync(NEG, 'utf8'))) {
  problems.push('O3 VIOLATION: Contract_Review__c.Negotiation_Status__c carries an inactive value. ' +
    'Initial Draft / Revised / Ready for Execution must stay ACTIVE — Disposition_PSA runs on all three.');
}

// Disposition record types must be untouched by this step.
for (const f of [R('objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml'),
                 R('objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml')]) {
  if (buffers.has(f)) problems.push(`SCOPE VIOLATION: this step must not modify ${path.relative(ROOT, f)}`);
}

if (problems.length) {
  console.error('\n🔴 NOTHING WAS WRITTEN. Resolve every item below and re-run.\n');
  problems.forEach(p => console.error('   - ' + p));
  console.error('\nThe most likely cause is that the tree has drifted since this package was written' +
                ' (2026-08-14). Do NOT loosen a pattern to make it match — re-derive it from the file.');
  process.exit(1);
}

if (CHECK) {
  console.log('\n✅ --check: all ' + edits.length + ' edits and all post-conditions validate. Nothing written.');
  process.exit(0);
}

for (const [f, t] of buffers) if (t !== null) fs.writeFileSync(f, t, 'utf8');
console.log('\n✅ Applied ' + edits.length + ' edits across ' + buffers.size + ' files.');
console.log('   Now do the PROSE touch-ups listed in this package README, then deploy the P3-D3 file list.');
