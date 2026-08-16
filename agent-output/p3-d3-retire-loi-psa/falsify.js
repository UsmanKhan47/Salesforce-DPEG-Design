#!/usr/bin/env node
/*
 * FALSIFIER for apply-d3.js. Run from the repo root:
 *     node agent-output/p3-d3-retire-loi-psa/falsify.js
 *
 * WHY THIS EXISTS. apply-d3.js is a gate artifact: it will be run months from now, once, on an
 * irreversible-ish step, by someone who did not write it. An assertion that has never been SEEN
 * TO GO RED is an unverified claim, not a check. This harness builds a deliberately MUTATED copy
 * of the tree for each assertion, runs the real script against it, and requires that the script
 *   (a) exits NON-ZERO, and
 *   (b) leaves EVERY file byte-identical.
 * A mutation that the script accepts is reported as a FALSIFIER MISS and this harness exits 1.
 *
 * It also runs one POSITIVE case (unmutated tree) to prove the script is not simply always red -
 * an always-failing gate is as useless as an always-passing one.
 *
 * Nothing here touches force-app. Every run happens in an isolated temp tree.
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const REPO = process.cwd();
const SCRIPT = path.join('agent-output', 'p3-d3-retire-loi-psa', 'apply-d3.js');
const MD = path.join('force-app', 'main', 'default');

// Every file apply-d3.js reads, edits, or asserts on.
const FILES = [
  'objects/LOI__c/fields/Stage__c.field-meta.xml',
  'objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml',
  'objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml',
  'objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml',
  'objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml',
  'objects/Contract_Review__c/recordTypes/Acquisition_PSA.recordType-meta.xml',
  'objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml',
  'objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml',
  'pathAssistants/LOI_Path_Acquisition.pathAssistant-meta.xml',
  'pathAssistants/Contract_Review_Path_Acquisition.pathAssistant-meta.xml'
];

function buildTree() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'p3d3-falsify-'));
  for (const rel of FILES) {
    const dst = path.join(root, MD, rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(path.join(REPO, MD, rel), dst);
  }
  const sdst = path.join(root, SCRIPT);
  fs.mkdirSync(path.dirname(sdst), { recursive: true });
  fs.copyFileSync(path.join(REPO, SCRIPT), sdst);
  return root;
}

function snapshot(root) {
  // A missing file snapshots as null rather than throwing — M10 deliberately deletes one, and a
  // harness that crashes on its own mutation reports nothing about the script under test.
  const m = new Map();
  for (const rel of FILES) {
    const p = path.join(root, MD, rel);
    m.set(rel, fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null);
  }
  return m;
}

function run(root) {
  try {
    const out = execFileSync(process.execPath, [SCRIPT], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return { code: 0, out };
  } catch (e) {
    return { code: e.status === undefined ? -1 : e.status, out: (e.stdout || '') + (e.stderr || '') };
  }
}

function rm(root) { fs.rmSync(root, { recursive: true, force: true }); }

// ---- the mutations -------------------------------------------------------
// Each returns a function(root) that edits the temp tree. Each targets ONE assertion.
const MUTATIONS = [
  {
    name: 'M1 exactly-one-match: the LOI Stage value block has DRIFTED (label reworded)',
    why: 'catches a tree that moved on since 2026-08-14 - the top failure mode for a staged package',
    apply: (root) => {
      const f = path.join(root, MD, 'objects/LOI__c/fields/Stage__c.field-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8')
        .replace('<label>Counter</label>', '<label>Counter Offer</label>'));
    }
  },
  {
    name: 'M2 exactly-one-match: a retired value is ALREADY deactivated (script re-run)',
    why: 'a second run must refuse rather than silently double-apply',
    apply: (root) => {
      const f = path.join(root, MD, 'objects/LOI__c/fields/Stage__c.field-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(
        '<fullName>Sent</fullName>\n                <default>false</default>\n                <label>Sent</label>',
        '<fullName>Sent</fullName>\n                <default>false</default>\n                <isActive>false</isActive>\n                <label>Sent</label>'));
    }
  },
  {
    name: 'M3 exactly-one-match: the Acquisition_LOI retired-value block was hand-edited',
    why: 'a partial hand-cleanup upstream must stop the whole run, not leave a half-cut record type',
    apply: (root) => {
      const f = path.join(root, MD, 'objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(
        '        <values>\n            <fullName>Counter</fullName>\n            <default>false</default>\n        </values>\n', ''));
    }
  },
  {
    name: 'M4 post-condition: the RecordType guard is missing from Is_Advance_Allowed__c',
    why: 'THE most dangerous silent regression - it hides the DISPOSITION Advance Stage button at step 2 of 5',
    apply: (root) => {
      const f = path.join(root, MD, 'objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8')
        .replace('    RecordType.DeveloperName <> "Acquisition_LOI",\n', ''));
    }
  },
  {
    name: 'M5 post-condition: the acquisition terminal clause (Signed) was removed',
    why: 'without it Advance Stage renders on a FINISHED acquisition LOI and then refuses the click',
    apply: (root) => {
      const f = path.join(root, MD, 'objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8')
        .replace('  TEXT(Stage__c) <> "Signed",\n', ''));
    }
  },
  {
    name: 'M6 O3 HARD STOP: someone deactivated a value on Negotiation_Status__c',
    why: 'deactivating Initial Draft / Revised / Ready for Execution deletes the Disposition_PSA sequence',
    apply: (root) => {
      const f = path.join(root, MD, 'objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(
        '<fullName>Revised</fullName>\n                <default>false</default>\n                <label>Revised</label>',
        '<fullName>Revised</fullName>\n                <default>false</default>\n                <isActive>false</isActive>\n                <label>Revised</label>'));
    }
  },
  {
    name: 'M7 exactly-one-match: the Acquisition_PSA default was already flipped to Draft',
    why: 'a hand-flipped default must refuse, not leave the record type with no default at all',
    apply: (root) => {
      const f = path.join(root, MD, 'objects/Contract_Review__c/recordTypes/Acquisition_PSA.recordType-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(
        '<fullName>Draft</fullName>\n            <default>false</default>',
        '<fullName>Draft</fullName>\n            <default>true</default>'));
    }
  },
  {
    name: 'M8 exactly-one-match: a pathAssistant <info> was reworded',
    why: 'Path prose is edited casually; a stale cut must not silently leave a retired step behind',
    apply: (root) => {
      const f = path.join(root, MD, 'pathAssistants/Contract_Review_Path_Acquisition.pathAssistant-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(
        'Terms are locked and the document is final. Route for signature.',
        'Terms are locked and the document is final. Route it for signature.'));
    }
  },
  {
    name: 'M9 exactly-one-match: the VR formula leg order was swapped by hand',
    why: 'the cut is anchored on Signed-then-Completed; a reordered formula must refuse',
    apply: (root) => {
      const f = path.join(root, MD, 'objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(
        "    TEXT(Primary_LOI__r.Stage__c) &lt;&gt; &apos;Signed&apos;,\n    TEXT(Primary_LOI__r.Stage__c) &lt;&gt; &apos;Completed&apos;\n)",
        "    TEXT(Primary_LOI__r.Stage__c) &lt;&gt; &apos;Completed&apos;,\n    TEXT(Primary_LOI__r.Stage__c) &lt;&gt; &apos;Signed&apos;\n)"));
    }
  },
  {
    name: 'M10 missing file: a target file was deleted or moved',
    why: 'a renamed file must stop the run, not be silently skipped',
    apply: (root) => {
      fs.unlinkSync(path.join(root, MD, 'pathAssistants/LOI_Path_Acquisition.pathAssistant-meta.xml'));
    }
  }
];

// ---- run -----------------------------------------------------------------
let misses = 0;

console.log('POSITIVE CONTROL — unmutated tree must APPLY cleanly (exit 0) and CHANGE files.');
{
  const root = buildTree();
  const before = snapshot(root);
  const r = run(root);
  const after = snapshot(root);
  const changed = FILES.filter(f => before.get(f) !== after.get(f));
  if (r.code !== 0) { console.log(`  ✗ MISS: script failed on a clean tree (exit ${r.code})\n${r.out}`); misses++; }
  else if (changed.length !== 7) { console.log(`  ✗ MISS: expected 7 files changed, got ${changed.length}: ${changed.join(', ')}`); misses++; }
  else console.log(`  ok  exit 0, ${changed.length} files rewritten`);
  rm(root);
}

console.log('\nNEGATIVE CASES — each must exit NON-ZERO and write NOTHING.');
for (const m of MUTATIONS) {
  const root = buildTree();
  m.apply(root);
  const before = snapshot(root);
  const r = run(root);
  const after = snapshot(root);
  const changed = FILES.filter(f => (before.get(f) ?? null) !== (after.get(f) ?? null));

  const caught = r.code !== 0;
  const clean = changed.length === 0;
  if (caught && clean) {
    console.log(`  ok  ${m.name}`);
  } else {
    misses++;
    console.log(`  ✗ FALSIFIER MISS — ${m.name}`);
    console.log(`      why it matters: ${m.why}`);
    if (!caught) console.log(`      script exited 0 — the mutation was ACCEPTED`);
    if (!clean)  console.log(`      script wrote to: ${changed.join(', ')}`);
  }
  rm(root);
}

console.log(misses
  ? `\n🔴 ${misses} FALSIFIER MISS(ES). apply-d3.js does not actually catch what it claims to.`
  : `\n✅ ${MUTATIONS.length} mutations, all caught, nothing written; positive control applies cleanly.`);
process.exit(misses ? 1 : 0);
