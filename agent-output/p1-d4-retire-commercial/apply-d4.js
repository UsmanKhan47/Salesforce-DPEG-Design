// Applies the P1-D4 subtractive edits in place.
//
//   node apply-d4.js a            deactivate pass  (reversible)
//   node apply-d4.js b            removal pass     (irreversible once deployed)
//   node apply-d4.js a --check    validate only, write NOTHING
//   node apply-d4.js b --check    validate only, write NOTHING
//
// ---------------------------------------------------------------------------
// THREE PROPERTIES THIS SCRIPT GUARANTEES. All three were defects on 2026-08-14
// and are fixed here; the README and the runbook already promised the first.
//
// 1. IT IS ATOMIC. Every replacement is built and asserted IN MEMORY first.
//    Nothing is written to disk unless EVERY edit in the pass validated. The
//    previous version wrote inside the edit helper, so pass `b` -- 12 sequential
//    edits across 8 files -- left edits 1..N-1 on disk when edit N hit drift.
//    That is a half-applied IRREVERSIBLE pass, which is the one state this
//    package exists to prevent.
//
// 2. IT IS CRLF-SAFE. Every match literal below is written with '\n'. Files are
//    normalised to '\n' for matching and written back in their ORIGINAL ending
//    style, so a CRLF file stays CRLF and the diff stays limited to the intended
//    blocks.
//
//    MEASURED 2026-08-14, because the obvious claim here is wrong and was
//    briefly written into this header: THIS CHECKOUT IS LF, NOT CRLF. Both the
//    HEAD blobs and the working-tree files contain zero CRLF pairs, so the
//    previous version's '\n' literals matched correctly here and the script was
//    NOT broken on this box. Do not repeat that claim.
//    What makes the normalisation load-bearing anyway is the CONFIG, not the
//    current bytes: `core.autocrlf` is `false` and there is NO `.gitattributes`,
//    so nothing in this repo pins the line ending. The ending is therefore a
//    property of the machine that cloned, not of the repo -- a DevOps engineer
//    whose global git sets `core.autocrlf=true` (the Git-for-Windows installer
//    default) gets a CRLF working tree, and against that tree EVERY literal
//    below matches zero times and the whole pass aborts. That is the failure
//    this normalisation removes, and it is a fair thing to guard because D4 is
//    the pass most likely to be run months later on somebody else's laptop.
//
// 3. PASS `b` DOES NOT REQUIRE PASS `a`. The value-removal edits accept the
//    ACTIVE block or the DEACTIVATED block. The README's own fallback tells the
//    operator that if `<isActive>false</isActive>` is rejected by the Metadata
//    API they may deactivate the two values in Setup instead, or skip the value
//    half of `a` entirely -- both of which leave the file carrying the ACTIVE
//    block, which the previous version could not match. The two forms are
//    mutually exclusive (one carries the <isActive> line, the other does not),
//    so accepting either is not a loosening of the exactly-one-match rule.
//
// The exactly-one-match assertion is otherwise unchanged and is the point of the
// script: a drifted file aborts the run.
// ---------------------------------------------------------------------------

const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..', '..', 'force-app', 'main', 'default');

const pass = process.argv[2];
const checkOnly = process.argv.includes('--check');

// --- the plan -------------------------------------------------------------
// stage() records an edit. It performs no I/O. `from` may be a single string or
// an array of mutually exclusive alternatives, exactly one of which must match
// exactly once. `marker` is diagnostic only: a string whose continued presence
// after a failed match tells the operator "drifted" rather than "already done".

const plan = [];
function stage(rel, from, to, label, marker) {
  plan.push({ rel, from: Array.isArray(from) ? from : [from], to, label, marker });
}

const VALUE_BLOCK =
  '            <value>\n' +
  '                <fullName>Commercial</fullName>\n' +
  '                <default>false</default>\n' +
  '                <label>Commercial</label>\n' +
  '            </value>\n';

const VALUE_BLOCK_INACTIVE =
  '            <value>\n' +
  '                <fullName>Commercial</fullName>\n' +
  '                <default>false</default>\n' +
  '                <isActive>false</isActive>\n' +
  '                <label>Commercial</label>\n' +
  '            </value>\n';

const RT_VALUES_BLOCK =
  '        <values>\n' +
  '            <fullName>Commercial</fullName>\n' +
  '            <default>false</default>\n' +
  '        </values>\n';

const PSET_RTV_BLOCK =
  '    <recordTypeVisibilities>\n' +
  '        <recordType>Opportunity.Commercial</recordType>\n' +
  '        <visible>true</visible>\n' +
  '    </recordTypeVisibilities>\n';

const VALUE_MARKER = '<fullName>Commercial</fullName>';
const PSET_MARKER = '<recordType>Opportunity.Commercial</recordType>';

if (pass === 'a') {
  console.log('P1-D4a - DEACTIVATE (reversible)' + (checkOnly ? '  [--check: validate only]' : ''));
  stage('objects/Opportunity/recordTypes/Commercial.recordType-meta.xml',
    '    <active>true</active>\n', '    <active>false</active>\n',
    'record type -> inactive', '<active>true</active>');
  stage('objects/Lead/fields/Deal_Type__c.field-meta.xml',
    VALUE_BLOCK, VALUE_BLOCK_INACTIVE, 'Lead Deal_Type__c value -> inactive', VALUE_MARKER);
  stage('objects/Opportunity/fields/Deal_Type__c.field-meta.xml',
    VALUE_BLOCK, VALUE_BLOCK_INACTIVE, 'Opportunity Deal_Type__c value -> inactive', VALUE_MARKER);
} else if (pass === 'b') {
  console.log('P1-D4b - REMOVE (irreversible once deployed)' + (checkOnly ? '  [--check: validate only]' : ''));

  // (a) the picklist value definitions.
  //     EITHER form is accepted -- see property 3 in the header block.
  stage('objects/Lead/fields/Deal_Type__c.field-meta.xml',
    [VALUE_BLOCK_INACTIVE, VALUE_BLOCK], '', 'Lead Deal_Type__c value removed', VALUE_MARKER);
  stage('objects/Opportunity/fields/Deal_Type__c.field-meta.xml',
    [VALUE_BLOCK_INACTIVE, VALUE_BLOCK], '', 'Opportunity Deal_Type__c value removed', VALUE_MARKER);

  // (b) the four record-type enumerations
  for (const rel of [
    'objects/Lead/recordTypes/Acquisition_Broker.recordType-meta.xml',
    'objects/Lead/recordTypes/IR_Investor.recordType-meta.xml',
    'objects/Opportunity/recordTypes/Land.recordType-meta.xml',
    'objects/Opportunity/recordTypes/Retail.recordType-meta.xml'
  ]) {
    stage(rel, RT_VALUES_BLOCK, '', 'Deal_Type__c enumeration removed', VALUE_MARKER);
  }

  // (b2) the Retail record type's transitional prose
  stage('objects/Opportunity/recordTypes/Retail.recordType-meta.xml',
    `        TRANSITIONAL: THE Deal_Type__c BLOCK STILL ENUMERATES 'Commercial'. That is
        deliberate for the D1->D4 window. The migration between D1 and D2 moves a record's
        RECORD TYPE and its Deal_Type__c VALUE in the same pass; a record that lands on
        this record type while still holding 'Commercial' must render correctly. Apex DML
        does NOT enforce record-type picklist restriction (ARCHITECTURE.md sec 2), so
        omitting it would not have blocked anything - it would only have made the UI
        disagree with the stored value. Remove that one <values> block at D4, together
        with the Commercial record type and business process.
`,
    `        D4 IS DONE. The transitional Deal_Type__c 'Commercial' enumeration that this
        block used to carry through the D1->D4 window has been REMOVED, together with the
        Commercial record type and business process. Do not re-add it: after the migration
        no row holds the value and the value no longer exists on the field. If a record
        still renders a blank Deal Type, the cause is a missed migration row, not a
        missing enumeration - re-run the [MIG] verification queries in the runbook.
        (Historical note, kept because it explains why the value was ever here: Apex DML
        does NOT enforce record-type picklist restriction (ARCHITECTURE.md sec 2), so
        omitting it during the window would not have blocked anything - it would only have
        made the UI disagree with the stored value.)
`, 'Retail record type prose retired', 'TRANSITIONAL: THE Deal_Type__c BLOCK');

  stage('objects/Opportunity/recordTypes/Retail.recordType-meta.xml',
    '    <description>Commercial acquisition deals. Replaces the Commercial record type, which is retired at Phase 1 D4. Deal_Type__c still enumerates the outgoing Commercial value for the migration window only.</description>\n',
    '    <description>Retail acquisition deals. Replaced the retired Commercial record type at Phase 1 D4 (2026-08). Apex resolves this type by DeveloperName - see RecordTypeSelector and LeadConvertService.</description>\n',
    'Retail record type description retired', 'Replaces the Commercial record type');

  // (c) the two permission sets
  stage('permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml',
    PSET_RTV_BLOCK, '', 'Opportunity.Commercial visibility removed', PSET_MARKER);
  stage('permissionsets/DPEG_Admin_Access.permissionset-meta.xml',
    PSET_RTV_BLOCK, '', 'Opportunity.Commercial visibility removed', PSET_MARKER);

  // (c2) the two permission-set comments
  stage('permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml',
    `      Opportunity.Commercial and Opportunity.Retail COEXIST DELIBERATELY from P1-D1 until P1-D4.
      Retail is added here in the SAME deploy that creates the record type (P1-D1), BEFORE the
      migration moves deals onto it. If it were added later, every user on this set would lose
      the ability to create a commercial deal for the whole window between the migration and the
      grant - visibility is what lets a user SELECT a record type, so the gap is silent on
      existing rows and blocking on new ones. Commercial is removed at P1-D4 and not before.
`,
    `      P1-D4 IS DONE: Opportunity.Commercial has been removed from this set and the record type
      itself is retired. Opportunity.Retail replaced it. The two coexisted from P1-D1 until P1-D4
      on purpose - visibility is what lets a user SELECT a record type, so granting Retail only
      after the migration would have left every user on this set unable to create a commercial
      deal for the whole window. Do not re-add Commercial; the record type no longer exists and
      the deploy would fail.
`, 'D1-window comment retired', 'COEXIST DELIBERATELY from P1-D1');

  stage('permissionsets/DPEG_Admin_Access.permissionset-meta.xml',
    `      Opportunity.Commercial below is RETIRED AT PHASE 1 D4 - see the deploy runbook,
      agent-output/runbook-acquisition-observations-phase1.md. It is deliberately left in place
      until then; Opportunity.Retail is added alongside it at D1 so the two coexist through the
      migration window.
`,
    `      Opportunity.Commercial WAS RETIRED AT PHASE 1 D4 and has been removed from this set;
      Opportunity.Retail replaced it. The two coexisted from D1 through the migration window on
      purpose. Do not re-add Commercial - the record type no longer exists and the deploy would
      fail. Sequence: agent-output/runbook-acquisition-observations-phase1.md.
`, 'D1-window comment retired', 'RETIRED AT PHASE 1 D4 - see the deploy runbook');
} else {
  console.error('usage: node apply-d4.js a|b [--check]');
  process.exit(2);
}

// --- PHASE 1: validate and build every replacement IN MEMORY ---------------
// Files are loaded ONCE and edited in a buffer, so an edit sees the result of
// the earlier edits to the same file. Nothing touches the disk in this phase.

const buffers = new Map(); // rel -> { text, hadCRLF, touched }
const failures = [];
const applied = [];

function load(rel) {
  if (buffers.has(rel)) return buffers.get(rel);
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) {
    const entry = { missing: true, text: '', hadCRLF: false, touched: false };
    buffers.set(rel, entry);
    return entry;
  }
  const raw = fs.readFileSync(p, 'utf8');
  const entry = {
    missing: false,
    hadCRLF: raw.includes('\r\n'),
    text: raw.replace(/\r\n/g, '\n'),
    touched: false
  };
  buffers.set(rel, entry);
  return entry;
}

for (const e of plan) {
  const buf = load(e.rel);
  if (buf.missing) {
    failures.push(`${e.label} :: ${e.rel}\n      FILE NOT FOUND under force-app/main/default`);
    continue;
  }

  // exactly one of the alternatives must be present, exactly once
  const hits = e.from
    .map((f, i) => ({ i, f, n: buf.text.split(f).length - 1 }))
    .filter(h => h.n > 0);

  if (hits.length === 0) {
    const stillThere = e.marker ? buf.text.split(e.marker).length - 1 : null;
    let why;
    if (e.to && buf.text.includes(e.to)) {
      why = 'the REPLACEMENT text is already present -> this edit looks ALREADY APPLIED.';
    } else if (stillThere === 0) {
      why = `the marker ${JSON.stringify(e.marker)} is ABSENT -> this edit looks ALREADY APPLIED.`;
    } else if (stillThere !== null) {
      why = `the marker ${JSON.stringify(e.marker)} is STILL PRESENT (${stillThere}x) -> the file has DRIFTED; the block no longer matches literally.`;
    } else {
      why = 'the file has DRIFTED.';
    }
    failures.push(`${e.label} :: ${e.rel}\n      expected exactly 1 match, found 0. ${why}`);
    continue;
  }
  if (hits.length > 1) {
    failures.push(`${e.label} :: ${e.rel}\n      AMBIGUOUS: ${hits.length} of the accepted alternative forms are present at once.`);
    continue;
  }
  if (hits[0].n !== 1) {
    failures.push(`${e.label} :: ${e.rel}\n      expected exactly 1 match, found ${hits[0].n}. Refusing to guess which one.`);
    continue;
  }

  buf.text = buf.text.split(hits[0].f).join(e.to);
  buf.touched = true;
  applied.push({ label: e.label, rel: e.rel, alt: hits[0].i });
}

// --- the gate -------------------------------------------------------------
if (failures.length) {
  console.error(`\nABORTED - ${failures.length} of ${plan.length} edits did not validate.`);
  console.error('NOTHING HAS BEEN WRITTEN. The working tree is untouched.\n');
  failures.forEach((f, i) => console.error(`  ${i + 1}. ${f}`));
  console.error('\n  If these read ALREADY APPLIED, this pass has already run - re-check');
  console.error('  `git status` before running it again.');
  console.error('  If these read DRIFTED, re-derive the block from the current file or');
  console.error('  restore the D1 state with `git checkout -- <file>` and retry.\n');
  process.exit(1);
}

// --- PHASE 2: write. Only reached when EVERY edit validated. ---------------
const files = [...buffers.entries()].filter(([, b]) => b.touched);

for (const a of applied) {
  const via = a.alt > 0 ? '  (matched the ACTIVE form - pass `a` was not applied to this file)' : '';
  console.log(`  ok  ${a.label.padEnd(46)} ${a.rel}${via}`);
}

if (checkOnly) {
  console.log(`\n--check: all ${plan.length} edits validated across ${files.length} file(s). Nothing written.`);
  process.exit(0);
}

for (const [rel, buf] of files) {
  const out = buf.hadCRLF ? buf.text.replace(/\n/g, '\r\n') : buf.text;
  fs.writeFileSync(path.join(ROOT, rel), out, 'utf8');
}

console.log(`\ndone. ${plan.length} edits written across ${files.length} file(s).`);
