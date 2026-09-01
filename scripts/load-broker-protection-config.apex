// ═══════════════════════════════════════════════════════════════════════════════════════
// Load/refresh the single Broker_Protection_Config__mdt record (DeveloperName = Default)
// via the Apex Metadata API. WS5, 2026-08-30.
//
// 🔴 WHY A SCRIPT AND NOT A DEPLOY. .forceignore line 16 excludes **/customMetadata/**:
// file-based CMDT RECORD deploy throws UNKNOWN_EXCEPTION in this org. Same pattern and
// same reason as load-task-group-defs.apex, load-onboarding-task-defs.apex and
// load-transaction-task-defs.apex in this folder. The TYPE and its 8 fields deploy
// normally; only the record needs this script.
//
// 🔴 RUN ORDER — THIS SCRIPT SITS IN THE MIDDLE OF A THREE-STEP SEQUENCE:
//   1. deploy force-app/main/default/objects/Broker_Protection_Config__mdt/ (type + fields)
//      AND the Apex (BrokerProtectionConfig, LLMExtractionCalloutService, ...). The Apex
//      needs the type to compile; it does NOT need this record — every accessor defaults.
//   2. RUN THIS SCRIPT.
//   3. only then deploy Lead.BP_Expiry__c (and WS2's Opportunity.BP_Expiry__c).
//      Those formulas reference
//      $CustomMetadata.Broker_Protection_Config__mdt.Default.Protection_Window_Days__c and
//      WILL NOT DEPLOY until this record exists. Proven by check-only dry-run on
//      `usman-dpeg`, 2026-08-30: without the record the deploy fails with
//      "Field Default does not exist. Check spelling." (0Afiw000000Tj09CAC); with a record
//      present the same formula shape validates Succeeded (0Afiw000000Tj1lCAC).
//
// ⚠ THIS SCRIPT DEPENDS ON THE APEX BEING DEPLOYED FIRST — see the prompt note below.
//
// ⚠ IDEMPOTENT. Metadata.Operations.enqueueDeployment UPSERTS on fullName, so re-running
// this restores every field to the values below. That is the intended recovery action if
// someone edits the record in Setup and needs it put back — but note it also DISCARDS any
// deliberate Setup tuning. Read the record before re-running it on a live org.
//
// ⚠ ASYNCHRONOUS. enqueueDeployment returns a job id immediately; the record is NOT there
// the instant this script finishes. Verify before running step 3:
//     sf data query --query "SELECT DeveloperName, Protection_Window_Days__c FROM \
//       Broker_Protection_Config__mdt" --target-org usman-dpeg
// (on Windows run that from PowerShell, not Git Bash).
// ═══════════════════════════════════════════════════════════════════════════════════════

// ── The extraction prompt ───────────────────────────────────────────────────────────────
// 🔴 NOT A TRANSCRIBED LITERAL, AND DELIBERATELY SO. The brief called for the ~20KB prompt
// to be built by chunked String concatenation rather than one big literal, because a large
// collection/string initializer can fail to compile in this org with an error naming the
// STATEMENT START rather than the real cause. Seeding from the shipped constant satisfies
// that constraint more strongly than chunking would: there is no large literal here AT ALL,
// so the initializer-complexity limit cannot be reached.
//
// It also removes a worse hazard. A hand-copied twenty-thousand-character prompt in this file
// would be a SECOND copy of the exact text that determines broker_email and property_address —
// the Property_Registry__c claim key. The first time someone edited the Apex constant and
// re-ran this loader, the two copies would disagree, and nothing would report it. Sourcing
// the seed from LLMExtractionCalloutService.shippedPrompt() makes "the loaded record equals
// the shipped prompt" true by construction.
//
// ⚠ CONSEQUENCE: LLMExtractionCalloutService must be deployed before this script runs.
// If it is not, this line throws "Variable does not exist" and nothing is written.
String prompt = LLMExtractionCalloutService.shippedPrompt();
// ⚠ THE `expect <N>` PIN THAT USED TO BE ON THE LINE BELOW IS GONE — 2026-08-31, DELIBERATELY.
// DO NOT PUT ONE BACK. It was corrected twice and was wrong both times it was read:
//   WS8 (2026-08-30) changed `expect 19254` to `expect 20592`, because WS7's prompt edit had
//   invalidated it the same day. 2026-08-31 changed it again to 20596 — and that second
//   correction was NOT another prompt edit, it was an ARITHMETIC BLIND SPOT:
//     20,592 is the sum of the STRING LITERALS ONLY (LEGACY 596 + ENRICHED's literals 19,996).
//     ENRICHED_EXTRACTION_RULES also interpolates MAX_PROPERTIES_IN_PROMPT (= 10, two chars)
//     TWICE at runtime. 596 + 19,996 + 4 = 20,596, which is what shippedPrompt().length()
//     actually returned — measured on usman-dpeg at API 67.0 on 2026-08-31, with the org's
//     ApexClass Body verified byte-identical to the repo file, so this was never repo/org drift.
// 🔴 THE PIN SERVED NO OPERATOR PURPOSE. This file's own note said a printed mismatch means
// "update this line", never "the prompt is corrupt" — i.e. the pin could only ever raise a FALSE
// alarm, and it went stale on every prompt edit. The 2026-08-31 schema-key definition pass would
// have made it stale a fourth time.
// ✅ WHAT THIS LINE IS FOR NOW: it PRINTS the length, and THIS RUN IS THE MEASUREMENT. There is
// nothing to compare it against and nothing to keep in sync. If you need to know whether the
// loaded record matches the shipped prompt, compare
// BrokerProtectionConfig.extractionPromptOverride().length() against
// LLMExtractionCalloutService.shippedPrompt().length() — two live values, neither of them a
// literal in a comment. ⚠ The one thing worth eyeballing is the ORDER OF MAGNITUDE: a five-digit
// number is healthy; 255 or a three-digit number means something truncated it.
System.debug('Seed prompt length (measured now; no expected value is pinned): ' + prompt.length());

// ── The record ──────────────────────────────────────────────────────────────────────────
// Every value below is the Apex literal it replaces, so loading this record changes NO
// behaviour on day one. It only makes the values editable. See each field's
// <description> in objects/Broker_Protection_Config__mdt/fields/ for what changing it does.
Map<String, Object> fields = new Map<String, Object>{
    // 🔴 CLAIM-ARBITRATION. Lowering this retroactively releases live broker claims in bulk,
    // with no deploy, no review and no undo (GATE A, decision A1, user-approved 2026-08-30).
    'Protection_Window_Days__c' => 90,
    // 🔴 CLAIM-ARBITRATION. MUST stay >= Protection_Window_Days__c. BrokerProtectionConfig
    // clamps it at runtime and logs WARN if this is violated — the clamp is enforcement,
    // this value is only the request.
    'Lookback_Days__c'          => 90,
    // ⚠ Also ExtractAddressQueueable's silent-suppression hard gate, not just a display band.
    'Confidence_High_Min__c'    => 0.85,
    'Confidence_Medium_Min__c'  => 0.60,
    'Model__c'                  => 'gpt-4o-mini',
    'Temperature__c'            => 0,
    'Max_Tokens__c'             => 4096,
    // 🔴 Editing this in Setup re-keys the broker registry and has NO regression guard.
    'Extraction_Prompt__c'      => prompt
};

Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
// fullName is '<TypeDeveloperName>.<RecordDeveloperName>' — the type name here carries NO
// __mdt suffix. 'Broker_Protection_Config__mdt.Default' is wrong and fails silently-ish.
cm.fullName = 'Broker_Protection_Config.Default';
cm.label = 'Default';

for (String f : fields.keySet()) {
    Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
    v.field = f;
    v.value = fields.get(f);
    cm.values.add(v);
}

Metadata.DeployContainer container = new Metadata.DeployContainer();
container.addMetadata(cm);
System.debug('Enqueued Broker_Protection_Config.Default deploy: '
    + Metadata.Operations.enqueueDeployment(container, null));
