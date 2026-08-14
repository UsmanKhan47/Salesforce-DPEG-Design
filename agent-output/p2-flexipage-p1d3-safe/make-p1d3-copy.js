#!/usr/bin/env node
/*
 * ONE FILE, NOW THREE PHASES, THREE DIFFERENT CORRECT CONTENTS — this script resolves that.
 *
 * force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml now carries
 * ALL THREE of:
 *   - Phase 1's edits: two {!Record.Deal_Type__c} criteria repointed Commercial -> Retail,
 *     plus four new Opportunity field items (Listing_Status__c + the three score fields);
 *   - Phase 2's edits: two {!Record.StageName} criteria repointed PSA -> Under Contract (PSA),
 *     gating Opportunity.Move_to_About_to_Close and Opportunity.Close_Deal;
 *   - Phase 4's edit: the c/callForOffersPanel component in the `sidebar` region, immediately
 *     above the tabset that holds the Activity tab.
 *
 * A FlexiPage deploys WHOLE, so each of the three deploys of this file needs different contents.
 *
 * ══ WHY THE FILENAME IS NOW A MISNOMER, AND WHY IT WAS KEPT ANYWAY ═════════════════════════
 * This script was written to serve P1-D3 only. It now serves P1-D3 AND P2-D2, so "make-p1d3-copy"
 * under-describes it. The name is retained deliberately.
 *
 * [CORRECTED 2026-08-14] The justification that stood here was WRONG ON ITS OWN TERMS, twice, and
 * is quoted so it is not re-derived. It read:
 *
 *     "The name is retained deliberately: BOTH the Phase 1 and the Phase 2 runbooks spell out
 *      `node agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js <scratch-dir>` verbatim, and
 *      renaming the file would silently invalidate an instruction in two documents this change is
 *      not editing."
 *
 *   (1) It was FALSE when it was written. Only the PHASE 2 runbook documented this generator.
 *       The Phase 1 runbook named no command at all - it said P1-D3 "DEPLOYS the file", meaning
 *       the tree copy. So the count was one document, not two, and "two documents" was the whole
 *       weight of the argument.
 *   (2) The command it quoted is the BARE form, which THIS SCRIPT NOW REFUSES (exit 1, no output),
 *       because --phase4 has no default. Quoting it as the instruction to protect was already
 *       self-contradictory by the end of the same change that repaired the script.
 *
 * THE DECISION IT SUPPORTED STILL STANDS, and now rests on a fact that is actually true: as of
 * 2026-08-14 BOTH runbooks spell this path out - Phase 2 always did, and the Phase 1 runbook was
 * corrected in the same pass and now carries
 *   `node agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js <scratch-dir> --phase 1 --phase4 strip`
 * plus an explicit warning that the bare form is refused. So renaming this file today WOULD break a
 * documented instruction in two documents - which is why the name stays. Note the difference that
 * matters: the claim is now true because the documents were FIXED, not because it was ever right.
 *
 * Use --phase to select which step you are generating for.
 *
 * ══ WHAT PHASE 4 CHANGED, AND WHY THE OLD SCRIPT DID NOT CATCH IT ═════════════════════════
 * Phase 4's component was added on 2026-08-14. The PREVIOUS version of this script PASSED every
 * one of its own assertions against that tree and exited 0 — and emitted a copy labelled
 * "P1-D3-safe" that carried c/callForOffersPanel. That is the exact drift its own header predicted
 * ("re-run weeks after it was written, against a tree that Phase 4 will also have edited") and did
 * not guard against, because every assertion it held was about Phase 1 and Phase 2 content. An
 * assertion set that only tests what you already thought of passes loudest at the moment it is
 * wrong.
 *
 * Two failure directions, and they are NOT symmetric — which is why this script refuses to guess:
 *
 *   Phase 4 NOT yet deployed, panel LEFT IN   the earlier deploy carries a component reference the
 *                                             org cannot resolve. The deploy FAILS. Loud, and no
 *                                             harm done — but it blocks P1-D3 or P2-D2 on a phase
 *                                             they do not depend on.
 *   Phase 4 ALREADY deployed, panel STRIPPED  the earlier deploy silently REMOVES a live component
 *                                             from the Opportunity record page. Nothing errors.
 *                                             Nobody is told. The panel is simply gone.
 *
 * The second is the dangerous one and it is invisible, so --phase4 has NO DEFAULT and must be
 * stated by the operator whenever the panel is present in the tree.
 *
 *   node make-p1d3-copy.js <output-dir> [--phase 1|2] --phase4 <strip|keep>
 *
 *     --phase 1   (default) for P1-D3: revert the two StageName criteria to PSA.
 *     --phase 2             for P2-D2: leave the StageName criteria at Under Contract (PSA).
 *     --phase4 strip        Phase 4 is NOT yet deployed. Remove the panel from the copy.
 *     --phase4 keep         P4-D has ALREADY landed. Leave the panel in, so this deploy does not
 *                           un-ship it.
 *
 * P4-D itself uses NEITHER mode and NOT this script: it deploys the tree copy verbatim.
 * The tree is the union of all three phases and P4-D owns it.
 *
 * The output is a deployable source tree fragment:
 *   <output-dir>/flexipages/Opportunity_Record_Page.flexipage-meta.xml
 *
 * It writes NOTHING unless every check below holds. See the assertion blocks for the reasoning.
 *
 * WARNING Do NOT commit the output. It is a transient deploy artifact, not a second source of truth.
 * WARNING Re-run it immediately before the deploy it is for. It reads the tree at run time, so it
 *   cannot go stale the way a stored patch would, but only if it is run then, not now.
 */
const fs = require('fs');
const path = require('path');

const REL = path.join('flexipages', 'Opportunity_Record_Page.flexipage-meta.xml');
const SRC = path.resolve(__dirname, '..', '..', 'force-app', 'main', 'default', REL);

const USAGE = 'usage: node make-p1d3-copy.js <output-dir> [--phase 1|2] --phase4 <strip|keep>';

/* ---- argument parsing -------------------------------------------------------------------- */
const argv = process.argv.slice(2);
let outDir = null;
let phase = '1';
let phase4 = null;

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--phase') { phase = argv[++i]; }
  else if (a === '--phase4') { phase4 = argv[++i]; }
  else if (a.startsWith('--')) { console.error('unknown flag: ' + a + '\n' + USAGE); process.exit(1); }
  else if (outDir === null) { outDir = a; }
  else { console.error('unexpected argument: ' + a + '\n' + USAGE); process.exit(1); }
}

if (!outDir) { console.error(USAGE); process.exit(1); }
if (phase !== '1' && phase !== '2') {
  console.error('--phase must be 1 (P1-D3) or 2 (P2-D2), got: ' + phase + '\n' + USAGE);
  process.exit(1);
}

const s = fs.readFileSync(SRC, 'utf8');

/* ==========================================================================================
 * PHASE-2 CONTENT: the two {!Record.StageName} criteria.
 *
 * Asserted for BOTH modes, not only --phase 1. Under --phase 2 nothing is transformed here, but
 * the assertion still establishes that the tree is in the state the caller believes it is in: a
 * tree that has lost Phase 2's repoint would produce a "P2-D2 copy" carrying the old PSA value,
 * which is the same class of silent-wrong-output this whole script exists to prevent.
 * ========================================================================================== */
const lines = s.split(/\r?\n/);
const newHits = [], oldHits = [];
lines.forEach((l, i) => {
  const t = l.trim();
  if (t === '<rightValue>Under Contract (PSA)</rightValue>') newHits.push(i);
  if (t === '<rightValue>PSA</rightValue>') oldHits.push(i);
});
if (oldHits.length) {
  console.error('DRIFT: the tree already carries ' + oldHits.length + ' bare <rightValue>PSA</rightValue> criteria.');
  console.error('       Either Phase 2 has not been applied, or someone reverted it. Nothing written.');
  process.exit(1);
}
if (newHits.length !== 2) {
  console.error('DRIFT: expected exactly 2 <rightValue>Under Contract (PSA)</rightValue>, found ' + newHits.length + '. Nothing written.');
  process.exit(1);
}
for (const i of newHits) {
  if (!(lines[i - 2] || '').includes('{!Record.StageName}')) {
    console.error('DRIFT: L' + (i + 1) + ' is not a StageName criterion. Nothing written.');
    process.exit(1);
  }
}

/* ==========================================================================================
 * PHASE-4 CONTENT: the c/callForOffersPanel component instance.
 *
 * The disposition is REQUIRED FROM THE OPERATOR, never inferred, because the file cannot tell you
 * whether P4-D has deployed. Guessing "strip" un-ships a live component with no error; guessing
 * "keep" blocks an unrelated deploy. Only a human knows which world they are in.
 * ========================================================================================== */
const PANEL_COMPONENT = '<componentName>callForOffersPanel</componentName>';
const PANEL_IDENTIFIER = '<identifier>callForOffersPanelComponent</identifier>';

const panelCount = s.split(PANEL_COMPONENT).length - 1;

if (panelCount > 1) {
  console.error('DRIFT: found ' + panelCount + ' callForOffersPanel component instances, expected 1. Nothing written.');
  process.exit(1);
}

if (panelCount === 1 && phase4 === null) {
  console.error('PHASE-4 DISPOSITION REQUIRED. Nothing written.');
  console.error('');
  console.error('  The tree carries Phase 4\'s c/callForOffersPanel, and this script will NOT guess');
  console.error('  whether to include it in a Phase-' + phase + ' copy. State it:');
  console.error('');
  console.error('    --phase4 strip   P4-D has NOT deployed yet. Remove the panel from this copy.');
  console.error('                     Leaving it in would make this deploy reference an LWC the org');
  console.error('                     does not have, and it would FAIL.');
  console.error('    --phase4 keep    P4-D HAS deployed. Leave the panel in.');
  console.error('                     Stripping it would SILENTLY REMOVE a live component from the');
  console.error('                     Opportunity record page. No error, no log, no warning.');
  console.error('');
  console.error('  Check first:  sf project retrieve start --metadata "FlexiPage:Opportunity_Record_Page"');
  console.error('                and grep the retrieved file for callForOffersPanel.');
  process.exit(1);
}

if (panelCount === 0 && phase4 !== null) {
  console.error('DRIFT: --phase4 ' + phase4 + ' was given, but the tree carries NO callForOffersPanel.');
  console.error('       Phase 4\'s FlexiPage edit is missing or has been reverted. Nothing written.');
  process.exit(1);
}

if (phase4 !== null && phase4 !== 'strip' && phase4 !== 'keep') {
  console.error('--phase4 must be strip or keep, got: ' + phase4 + '\n' + USAGE);
  process.exit(1);
}

/* ---- transform 1: Phase 2's stage criteria ------------------------------------------------ */
let out = s;
if (phase === '1') {
  out = out.split('<rightValue>Under Contract (PSA)</rightValue>')
           .join('<rightValue>PSA</rightValue>');
}

/* ---- transform 2: Phase 4's panel --------------------------------------------------------- */
/*
 * Removal is STRUCTURAL, not a regex over the raw text: find the componentName line, walk out to
 * its enclosing <itemInstances> block, assert that block contains exactly one componentName (so a
 * future nested container cannot be silently swallowed with it), and splice the block out.
 */
let panelRemovedAt = null;
if (phase4 === 'strip') {
  const ls = out.split(/\r?\n/);
  const at = ls.findIndex((l) => l.trim() === PANEL_COMPONENT);
  if (at === -1) {
    console.error('INTERNAL: the panel line vanished after transform 1. Nothing written.');
    process.exit(1);
  }
  let start = at;
  while (start >= 0 && ls[start].trim() !== '<itemInstances>') { start--; }
  let end = at;
  while (end < ls.length && ls[end].trim() !== '</itemInstances>') { end++; }
  if (start < 0 || end >= ls.length) {
    console.error('DRIFT: could not find the <itemInstances> block enclosing the panel. Nothing written.');
    process.exit(1);
  }
  const block = ls.slice(start, end + 1);
  const componentNames = block.filter((l) => l.trim().startsWith('<componentName>'));
  if (componentNames.length !== 1) {
    console.error('DRIFT: the panel\'s <itemInstances> block holds ' + componentNames.length +
                  ' components, expected 1. Removing it would take something else with it. Nothing written.');
    process.exit(1);
  }
  panelRemovedAt = start + 1;
  ls.splice(start, end - start + 1);
  out = ls.join('\n');
}

/* ==========================================================================================
 * ASSERT the payload of every phase that is supposed to SURVIVE, in the OUTPUT.
 *
 * This script's whole purpose is to be re-run weeks after it was written, against a tree later
 * phases will also have edited. Printing "the other phases are UNCHANGED and present" without
 * testing it is worse than printing nothing: the operator's only signal is a line that is true by
 * assumption. The output is deployed to the org, so a regression here silently ships a page
 * missing the very things the step exists to deliver.
 *
 * Checked against `out`, not `s`, so the checks also cover the transforms themselves.
 * ========================================================================================== */
const P1_FIELD_ITEMS = [
  'Record.Listing_Status__c',
  'Record.Extraction_Score_Pct__c',
  'Record.Fields_Captured_Count__c',
  'Record.Fields_Missing_Count__c'
];

const outLines = out.split(/\r?\n/);
const failures = [];

/* (a) Phase 1's two Deal Type criteria. If these regressed to 'Commercial', the copy hides the
 *     Construction Review tab and the Send to Construction Review action on every deal after the
 *     Deal Type backfill. */
let retailCriteria = 0;
outLines.forEach((l, i) => {
  if (l.trim() !== '<rightValue>Retail</rightValue>') return;
  if ((outLines[i - 2] || '').includes('{!Record.Deal_Type__c}')) retailCriteria++;
});
if (retailCriteria !== 2) {
  failures.push('expected exactly 2 {!Record.Deal_Type__c} EQUAL Retail criteria, found ' +
                retailCriteria + ' — Phase 1\'s Deal Type repoint is missing or has drifted');
}
if (/<rightValue>Commercial<\/rightValue>/.test(out)) {
  failures.push('the output still carries <rightValue>Commercial</rightValue> — Phase 1\'s ' +
                'repoint has been reverted');
}

/* (b) Phase 1's four new field items. If missing, the step reports success while delivering none
 *     of the new fields to the page. */
for (const f of P1_FIELD_ITEMS) {
  const n = out.split('<fieldItem>' + f + '</fieldItem>').length - 1;
  if (n !== 1) {
    failures.push('expected exactly 1 <fieldItem>' + f + '</fieldItem>, found ' + n +
                  ' — Phase 1\'s new field items are missing or duplicated');
  }
}

/* (c) Phase 2's stage criteria, in whichever form this phase wants them. */
const wantStage = phase === '1' ? '<rightValue>PSA</rightValue>'
                                : '<rightValue>Under Contract (PSA)</rightValue>';
const gotStage = out.split(wantStage).length - 1;
if (gotStage !== 2) {
  failures.push('expected exactly 2 ' + wantStage + ' in a phase-' + phase + ' copy, found ' + gotStage);
}

/* (d) Phase 4's panel, present or absent as instructed — asserted in BOTH directions, because
 *     "strip" failing open and "keep" failing closed are both silent at deploy time. */
const outPanel = out.split(PANEL_COMPONENT).length - 1;
const outPanelId = out.split(PANEL_IDENTIFIER).length - 1;
if (phase4 === 'strip') {
  if (outPanel !== 0) failures.push('--phase4 strip left ' + outPanel + ' callForOffersPanel component(s) in the output');
  if (outPanelId !== 0) failures.push('--phase4 strip left ' + outPanelId + ' callForOffersPanel identifier(s) in the output');
} else if (phase4 === 'keep') {
  if (outPanel !== 1) failures.push('--phase4 keep produced ' + outPanel + ' callForOffersPanel component(s), expected 1');
  if (outPanelId !== 1) failures.push('--phase4 keep produced ' + outPanelId + ' callForOffersPanel identifier(s), expected 1');
}

/* (e) The Activity tabset the panel sits above must survive either transform untouched. A strip
 *     that walked its block boundaries wrongly would take the Activity and Files tabs with it. */
const tabset = out.split('<identifier>flexipage_tabset</identifier>').length - 1;
if (tabset !== 1) {
  failures.push('expected exactly 1 <identifier>flexipage_tabset</identifier> (the sidebar tabset ' +
                'holding the Activity and Files tabs), found ' + tabset);
}
if (out.split('<name>sidebar</name>').length - 1 !== 1) {
  failures.push('the sidebar region is missing or duplicated in the output');
}

if (failures.length) {
  console.error('PAYLOAD CHECK FAILED. Nothing written.');
  for (const f of failures) console.error('  - ' + f);
  console.error('\nDo NOT hand-edit around this. Re-check the tree against the phase runbooks in');
  console.error('agent-output/ before deploying anything.');
  process.exit(1);
}

const dest = path.join(outDir, REL);
fs.mkdirSync(path.dirname(dest), { recursive: true });
fs.writeFileSync(dest, out);

const step = phase === '1' ? 'P1-D3' : 'P2-D2';
console.log('Wrote ' + step + '-safe copy: ' + dest);
if (phase === '1') {
  console.log('  2 StageName criteria reverted to PSA (verified at L' + (newHits[0] + 1) + ' and L' + (newHits[1] + 1) + ')');
} else {
  console.log('  2 StageName criteria left at Under Contract (PSA) — phase 2 owns that value');
}
if (phase4 === 'strip') {
  console.log('  Phase 4 panel REMOVED (its itemInstances block began at L' + panelRemovedAt + ' of the tree)');
} else if (phase4 === 'keep') {
  console.log('  Phase 4 panel KEPT — P4-D is live, so this deploy must not un-ship it');
}
console.log('  ASSERTED in the output: ' + retailCriteria + ' {!Record.Deal_Type__c} EQUAL Retail criteria, ' +
            '0 Commercial, all ' + P1_FIELD_ITEMS.length + ' Phase-1 field items present exactly once, ' +
            gotStage + ' phase-' + phase + ' stage criteria, ' + outPanel + ' Phase-4 panel, 1 sidebar tabset.');
console.log('\n  Deploy with:  sf project deploy start --source-dir "' + path.join(outDir, 'flexipages') + '" --target-org <alias>');
console.log('  Then RETRIEVE THE PAGE BACK AND DIFF IT. A FlexiPage deploy can roll back on a');
console.log('  design-time error and still report success. A green deploy is not evidence.');
