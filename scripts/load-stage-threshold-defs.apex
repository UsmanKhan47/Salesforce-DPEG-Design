// ═══════════════════════════════════════════════════════════════════════════════════════
// Load/refresh the EIGHT Stage_Threshold_Def__mdt records — the per-stage stalled-deal
// thresholds — via the Apex Metadata API. Design §2 ITEM 4, 2026-08-31.
//
// 🔴 WHY A SCRIPT AND NOT A DEPLOY. .forceignore excludes **/customMetadata/**: a file-based
// CMDT RECORD deploy throws UNKNOWN_EXCEPTION in this org. Same pattern and same reason as
// load-cfo-alert-rungs.apex, load-broker-protection-config.apex, load-task-group-defs.apex,
// load-onboarding-task-defs.apex and load-transaction-task-defs.apex in this folder. The TYPE
// and its three fields deploy normally; only the records need this script.
//
// 🔴 WHAT HAPPENS IF YOU DO NOT RUN IT — READ THIS BEFORE DECIDING IT IS OPTIONAL.
// StageDelayService.resolveThresholds falls back to a FLAT 14-day threshold for every open
// stage when the type carries NO ROWS, and logs a WARN saying so. StageDelayAlertBatch.finish()
// additionally prints the org's row count on every pass, so an empty load is VISIBLE rather
// than silent. The feature therefore does NOT die if this is skipped — that fallback exists
// precisely because a script-loaded record is a step someone will forget.
// What you lose by skipping it is the whole point of putting the thresholds in Custom Metadata:
// they are not tunable in Setup until they exist as rows.
// ⚠ Do not "simplify" the service by deleting DEFAULT_THRESHOLD_DAYS on the strength of this
// script existing. The script is a manual step; the fallback is what makes the deploy safe.
//
// ═══ THE VALUES: A FLAT 14 FOR EVERY OPEN STAGE ═══
// A flat 14 days per stage — not an escalating or per-stage-tuned ladder — is a RECORDED USER
// DECISION. Seeding exactly 14 everywhere is also what makes running this script a no-op in
// behaviour: it must EQUAL StageDelayService.DEFAULT_THRESHOLD_DAYS, or running the loader
// would CHANGE how the job behaves rather than merely making it tunable. If you change a value
// here, change nothing in Apex — that is the point — but do read the next paragraph first.
//
// ⚠ RESIDUAL, stated so it is not later filed as a bug: the suppression marker is per STAGE
// OCCUPANCY, not per threshold value (StageDelayService.shouldFire keys on Stage_Alert_Stage__c
// and Stage_Alert_Last_Sent_Date__c, neither of which stores a threshold). So unlike
// CFO_Alert_Rung__mdt — whose values ARE a data contract with a stored rung on every alerted
// deal — retuning a threshold here invalidates NOTHING. Lowering one can make already-reminded
// deals... still silent (they are already marked for this occupancy); RAISING one can make a
// not-yet-reminded deal wait longer. Both are the intended meaning of the setting.
//
// ⚠ THE EIGHT STAGES ARE THE **OPEN** ONES. `Closed Won` and `Dead/Pass` deliberately get NO
// ROWS: both carry IsClosed = true (verified against OpportunityStage in usman-dpeg 2026-08-31)
// and OpportunitySelector.queryStalledDeals excludes them with `IsClosed = FALSE` before the
// thresholds are ever consulted. Adding rows for them would be inert, and would imply to the
// next reader that closed deals are chased.
// ⚠ `Development Review` is Land-only and `Construction Review` is Commercial/Retail-only. Both
// get a row: a threshold for a stage a given record type cannot reach is inert, not wrong.
//
// ⚠ IDEMPOTENT. Metadata.Operations.enqueueDeployment UPSERTS on fullName, so re-running this
// restores all eight rows to the values below — which is the intended recovery if someone edits
// them in Setup and needs them put back. It also DISCARDS any deliberate tuning. Read the rows
// before re-running on a live org (query at the bottom).
//
// ⚠ ASYNCHRONOUS. enqueueDeployment returns a job id immediately; the rows are NOT there the
// instant this script finishes. Verify with:
//     sf data query --query "SELECT DeveloperName, Stage_Value__c, Threshold_Days__c, \
//       Is_Active__c FROM Stage_Threshold_Def__mdt ORDER BY Stage_Value__c" \
//       --target-org usman-dpeg
// (on Windows run that from PowerShell, not Git Bash.)
//
// ⚠ Stage_Value__c IS MATCHED CASE-INSENSITIVELY by StageDelayService (Apex `==` on String is
// case-insensitive but Map.get is case-SENSITIVE, so the service lower-cases both sides). It is
// still written here in the exact StageName API casing — a row a human can read against the
// picklist is worth more than a row that merely happens to match.
//
// RUN ORDER:
//   1. deploy force-app/main/default/objects/Stage_Threshold_Def__mdt/ (type + 3 fields),
//      the two Opportunity marker fields, AND the Apex (StageDelayService needs the type to
//      compile).
//   2. RUN THIS SCRIPT.
//   3. confirm the eight rows with the query above, then confirm StageDelayServiceTest and
//      StageDelayAlertBatchTest are still green against the loaded rows. (They inject their own
//      rows through a @TestVisible seam and do not read the org's, so they should be
//      unaffected — which is itself the thing being confirmed.)
// ═══════════════════════════════════════════════════════════════════════════════════════

// ── The eight open stages ───────────────────────────────────────────────────────────────
// DeveloperName -> [MasterLabel, Stage_Value__c (the StageName API value), Threshold_Days__c]
//
// ⚠ THE DEVELOPER NAMES CARRY THE STAGE, NOT AN ORDINAL. `Stage_1..8` would go stale the moment
// the pipeline changed, and nothing in Apex reads these names — the service keys on
// Stage_Value__c. They exist so a human editing Setup can tell the rows apart.
// ⚠ A DeveloperName cannot contain spaces, parentheses or slashes, which is why
// `Under Contract (PSA)` becomes `Stage_Under_Contract_PSA`. The AUTHORITATIVE value is
// Stage_Value__c; the DeveloperName is a label.
//
// ⚠ SMALL LITERAL ON PURPOSE. This repo has a measured Apex parser ceiling on large
// collection-initializer literals (it reports the STATEMENT START, e.g. `Unexpected token "<"`,
// not the real cause — measured at 45 rows). Eight is nowhere near it; do not grow this into a
// hundred-row initializer if the pipeline is ever extended — build it in halves with addAll.
Integer flatThresholdDays = 14;

Map<String, List<Object>> stages = new Map<String, List<Object>>{
    'Stage_New'                  => new List<Object>{ 'New',                  'New',                  flatThresholdDays },
    'Stage_Under_Review'         => new List<Object>{ 'Under Review',         'Under Review',         flatThresholdDays },
    'Stage_Development_Review'   => new List<Object>{ 'Development Review',   'Development Review',   flatThresholdDays },
    'Stage_Construction_Review'  => new List<Object>{ 'Construction Review',  'Construction Review',  flatThresholdDays },
    'Stage_Underwriting'         => new List<Object>{ 'Underwriting',         'Underwriting',         flatThresholdDays },
    'Stage_LOI'                  => new List<Object>{ 'LOI',                  'LOI',                  flatThresholdDays },
    'Stage_Under_Contract_PSA'   => new List<Object>{ 'Under Contract (PSA)', 'Under Contract (PSA)', flatThresholdDays },
    'Stage_About_To_Close'       => new List<Object>{ 'About to Close',       'About to Close',       flatThresholdDays }
};

Metadata.DeployContainer container = new Metadata.DeployContainer();

for (String developerName : stages.keySet()) {
    List<Object> row = stages.get(developerName);

    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
    // fullName is '<TypeDeveloperName>.<RecordDeveloperName>' — the type name here carries NO
    // __mdt suffix. 'Stage_Threshold_Def__mdt.Stage_New' is wrong and fails silently-ish.
    cm.fullName = 'Stage_Threshold_Def.' + developerName;
    cm.label = (String) row[0];

    Metadata.CustomMetadataValue stageValue = new Metadata.CustomMetadataValue();
    stageValue.field = 'Stage_Value__c';
    stageValue.value = row[1];
    cm.values.add(stageValue);

    Metadata.CustomMetadataValue days = new Metadata.CustomMetadataValue();
    days.field = 'Threshold_Days__c';
    days.value = row[2];
    cm.values.add(days);

    Metadata.CustomMetadataValue active = new Metadata.CustomMetadataValue();
    active.field = 'Is_Active__c';
    // 🔴 ALL EIGHT SHIP ACTIVE. Deactivating every row is a supported admin act — it switches the
    // reminder off entirely and StageDelayService HONOURS an all-inactive configuration rather
    // than falling back to the default (that distinction is the whole reason resolveThresholds
    // counts rows and active rows separately) — but it is not the shipped state.
    active.value = true;
    cm.values.add(active);

    container.addMetadata(cm);
}

// The count is debugged BEFORE the enqueue as well as after, so a container that was built empty
// (a future edit that filters the map and filters everything out) is visible rather than showing
// up as a silently successful no-op deployment.
System.debug('Stage_Threshold_Def rows in this deployment: ' + stages.size()
    + ' (expect 8, one per OPEN Opportunity stage, all at ' + flatThresholdDays + ' days). '
    + 'This value MUST equal StageDelayService.DEFAULT_THRESHOLD_DAYS or running this loader '
    + 'CHANGES behaviour instead of merely making it tunable.');

System.debug('Enqueued Stage_Threshold_Def deploy: '
    + Metadata.Operations.enqueueDeployment(container, null));
