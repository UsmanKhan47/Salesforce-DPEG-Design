#!/usr/bin/env node
/*
 * P2-D3 — retire the old `PSA` Opportunity stage value.
 *
 * RUN THIS ONLY AFTER the P2 backfill has been re-confirmed at zero rows. See README.md.
 *
 *   node apply-d3.js --check     validate every edit in memory, write nothing
 *   node apply-d3.js             validate every edit in memory, then write ALL or NONE
 *
 * TWO-PHASE BY CONSTRUCTION. Every edit is resolved and asserted against an
 * EXACTLY-ONE-MATCH rule before a single byte is written. A drift on the LAST edit therefore
 * leaves the tree untouched rather than half-applied. This is the same shape as
 * agent-output/p1-d4-retire-commercial/apply-d4.js, and it exists for the same reason: a
 * `git diff` / `git apply` patch goes stale SILENTLY between the day it is staged and the
 * day the gate opens, whereas this fails loudly and names the file it could not match.
 *
 * ⚠ NO destructiveChanges.xml IS NEEDED OR SUPPLIED. Nothing is deleted at D3: the standard
 * picklist value is DEACTIVATED (a stage value with history must remain resolvable to every
 * historical report, dashboard and audit row), and the BusinessProcess entries are removed
 * by re-deploying the two files without them. Deleting a StandardValueSet value is not a
 * thing the Metadata API does, and it is not wanted here.
 */
const fs = require('fs');
const path = require('path');

const CHECK = process.argv.includes('--check');
const ROOT = path.resolve(__dirname, '..', '..', 'force-app', 'main', 'default');

const SVS = 'standardValueSets/OpportunityStage.standardValueSet-meta.xml';
const BPS = [
  'objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml',
  'objects/Opportunity/businessProcesses/Retail.businessProcess-meta.xml',
  'objects/Opportunity/businessProcesses/Commercial.businessProcess-meta.xml'
];
const RPT = 'reports/Acquisitions/Deal_Pipeline_by_Stage.report-meta.xml';

const edits = [];   // {file, before, after}
const notes = [];

/* LINE ENDINGS — every multi-line needle below is written with bare \n, but a checkout made
 * with core.autocrlf=true (the Windows default) stores these files with \r\n. A literal
 * split would then find ZERO matches and every multi-line edit would report DRIFT and write
 * nothing. That fails loud and safe, which is the right direction — but it fails for a reason
 * that has nothing to do with the change, and the operator is explicitly told above NOT to
 * hand-edit around a DRIFT message. A line-ending false alarm is exactly the case in which
 * someone would do it anyway.
 *
 * So the needle and the replacement are re-terminated to whatever the FILE uses before
 * matching, and the file's own line endings are preserved on write. Same approach as the
 * sibling agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js, which splits on /\r?\n/.
 */
function eolOf(text) { return text.indexOf('\r\n') !== -1 ? '\r\n' : '\n'; }
function toEol(text, eol) { return text.split(/\r?\n/).join(eol); }

function stage(file, rawNeedle, rawReplacement, label) {
  const abs = path.join(ROOT, file);
  if (!fs.existsSync(abs)) {
    notes.push('SKIP (file absent, expected if P1-D4 already ran): ' + file);
    return;
  }
  const before = fs.readFileSync(abs, 'utf8');
  const eol = eolOf(before);
  const needle = toEol(rawNeedle, eol);
  const replacement = toEol(rawReplacement, eol);
  const parts = before.split(needle);
  // NOTE the empty-string case is LOAD-BEARING, not an oversight: the business-process edits
  // have replacement === '', and indexOf('') is always 0, so a needle that is already gone
  // reports SKIP (already applied). That is what makes a re-run idempotent — README step 3
  // depends on it. Do not "tighten" this with a replacement !== '' guard.
  if (parts.length === 1 && before.indexOf(replacement) !== -1) {
    notes.push('SKIP (already applied): ' + label + '  [' + file + ']');
    return;
  }
  if (parts.length !== 2) {
    console.error('DRIFT: expected exactly 1 match for "' + label + '" in ' + file +
                  ', found ' + (parts.length - 1) + '. NOTHING HAS BEEN WRITTEN.');
    console.error('       Open the file, confirm the block below still exists verbatim, and');
    console.error('       update this script rather than hand-editing around it.');
    console.error('       (Line endings are already normalised — this file uses ' +
                  (eol === '\r\n' ? 'CRLF' : 'LF') + ' and the needle was re-terminated to match,');
    console.error('        so a DRIFT here is a real content difference, not a checkout artifact.)');
    console.error('---\n' + needle + '\n---');
    process.exit(1);
  }
  edits.push({ abs, file, out: parts[0] + replacement + parts[1], label });
}

/* ------------------------------------------------------------------ 1. deactivate the
 * standard picklist value. <isActive> sits between <default> and <label>: that ordering is
 * the in-repo, deploy-proven precedent from
 * objects/Contract_Review__c/fields/Stage__c.field-meta.xml, which carries three
 * deactivated values in exactly this shape.
 *
 * ⚠ UNVERIFIED IN THIS ORG: no StandardValueSet in this repo has ever carried <isActive>,
 * so the precedent above is a CustomValue precedent, not a StandardValue one. StandardValue
 * extends CustomValue in the Metadata API WSDL, which is why this is expected to work — but
 * expected is not measured.
 *
 * 🔴 IF THE DEPLOY REJECTS THE ELEMENT: --skip-svs ALONE IS NOT THE FIX. By the time the
 * rejection is knowable this script has ALREADY written <isActive>false</isActive> into the
 * tree, and --skip-svs only tells a FUTURE run to leave the file alone — it removes nothing.
 * The revert is step 1. Follow the recovery sequence in README.md, section
 * "🔴 If the deploy rejects it — REVERT THE FILE FIRST. `--skip-svs` alone does NOT undo it."
 * That README section is the ONE authoritative copy of the sequence; it is deliberately not
 * repeated here, so the two cannot drift apart.
 */
if (!process.argv.includes('--skip-svs')) {
  stage(SVS,
    '    <standardValue>\n' +
    '        <fullName>PSA</fullName>\n' +
    '        <default>false</default>\n' +
    '        <label>PSA</label>\n',
    '    <standardValue>\n' +
    '        <fullName>PSA</fullName>\n' +
    '        <default>false</default>\n' +
    '        <isActive>false</isActive>\n' +
    '        <label>PSA</label>\n',
    'deactivate the PSA standard value');
}

/* ------------------------------------------------------------------ 2. drop PSA from every
 * business process that still lists it. Commercial's file is deleted by P1-D4, so its
 * absence here is expected and is reported as a SKIP, not a failure.
 */
for (const bp of BPS) {
  stage(bp,
    '    <values>\n        <fullName>PSA</fullName>\n        <default>false</default>\n    </values>\n',
    '',
    'remove the PSA stage from the business process');
}

/* ------------------------------------------------------------------ 3. drop PSA from the
 * in-repo report's STAGE_NAME filter.
 *
 * 🔴 THIS EDIT EXISTS BECAUSE THE INVENTORY MISSED THE FILE, AND THE REASON IT WAS MISSED IS
 * THE REUSABLE LESSON. A report filter stores a multi-value picklist selection as ONE
 * COMMA-JOINED STRING inside a single <value> element:
 *
 *     <value>New,Under Review,...,LOI,PSA</value>   with <operator>equals</operator>
 *
 * so EVERY delimiter-anchored pattern the P2 inventory used - >PSA<, 'PSA',
 * <fullName>PSA, <value>PSA</value> - misses it. Only a BARE-TOKEN sweep (\bPSA\b) over
 * reports/, dashboards/ and every listViews/ directory finds it. Requirements §6.2 and
 * runbook §5 G8-a both said reports were "not fully represented in this repo"; that was
 * FALSE for this one file.
 *
 * Consequence had it been left: the filter is `equals`, so after the backfill every migrated
 * deal fails it. The PSA column does not empty - it DISAPPEARS from the grouping and takes
 * its deals out of the pipeline total, with no error anywhere.
 *
 * P2-D1 therefore lists BOTH values and this step drops the old one. A report filter naming
 * a picklist value the org does not (yet) have deploys fine, so both-then-drop leaves no
 * window in either direction.
 *
 * ⚠ THE FILE SHIPS AT P2-D1, NOT P2-D2 (moved 2026-08-14). Every other repointed file MOVES a
 * value and is blocked until P2-D1 lands; this one ADDS a value and resolves nothing, so it is
 * correct before, during and after the backfill — and leaving it at P2-D2, which runs AFTER the
 * backfill, would open a window in which every just-migrated deal sits outside the filter.
 * ⚠ THIS EDIT IS UNAFFECTED BY THAT MOVE, and that is a property worth stating rather than
 * assuming: the needle below is matched against the REPO TREE, whose content is identical
 * either way. Nothing in this script reads the org or checks which step has run.
 */
stage(RPT,
  '<value>New,Under Review,Development Review,Construction Review,Underwriting,LOI,PSA,Under Contract (PSA)</value>',
  '<value>New,Under Review,Development Review,Construction Review,Underwriting,LOI,Under Contract (PSA)</value>',
  'drop PSA from the Deal Pipeline by Stage report filter');

console.log('=== P2-D3 staged edits ===');
for (const n of notes) console.log('  ' + n);
for (const e of edits) console.log('  READY  ' + e.label + '  [' + e.file + ']');
if (!edits.length) { console.log('  nothing to do.'); process.exit(0); }

if (CHECK) { console.log('\n--check: validated ' + edits.length + ' edit(s). Nothing written.'); process.exit(0); }
for (const e of edits) fs.writeFileSync(e.abs, e.out);
console.log('\nWROTE ' + edits.length + ' file(s). Deploy them, then run the README verification queries.');
