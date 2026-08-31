// ═══════════════════════════════════════════════════════════════════════════════════════
// Load/refresh the FOUR CFO_Alert_Rung__mdt records — the call-for-offers notification
// ladder — via the Apex Metadata API. Design Item 5(d), 2026-08-30.
//
// 🔴 WHY A SCRIPT AND NOT A DEPLOY. .forceignore line 16 excludes **/customMetadata/**:
// file-based CMDT RECORD deploy throws UNKNOWN_EXCEPTION in this org. Same pattern and
// same reason as load-broker-protection-config.apex, load-task-group-defs.apex,
// load-onboarding-task-defs.apex and load-transaction-task-defs.apex in this folder. The
// TYPE and its two fields deploy normally; only the records need this script.
//
// 🔴 WHAT HAPPENS IF YOU DO NOT RUN IT — READ THIS BEFORE DECIDING IT IS OPTIONAL.
// CallForOffersService.resolveRungs falls back to its shipped DEFAULT_ALERT_INTERVALS
// ({7, 3, 1, 0}) when the type carries NO ROWS, and logs a WARN saying so. So the feature
// does NOT silently die if this is skipped — that fallback exists precisely because a
// script-loaded record is a step someone will forget. What you lose by skipping it is the
// whole point of the change: the rungs are not tunable in Setup until they exist as rows.
// ⚠ Do not "simplify" the service by deleting that fallback on the strength of this
// script existing. The script is a manual step; the fallback is what makes the deploy safe.
//
// ═══ 🔴 THE VALUES BELOW ARE A DATA CONTRACT WITH LIVE RECORDS. DO NOT RETUNE THEM HERE. ═══
// Every deal that has ever been alerted carries Opportunity.Offer_Alert_Last_Interval__c =
// THE RUNG IT WAS LAST NOTIFIED AT — a stored 7, 3, 1 or 0. CallForOffersService.shouldFire
// compares the rung a deal is in NOW against that stored number and fires only when the new
// one is STRICTLY SMALLER. Seeding exactly {7, 3, 1, 0} is therefore what makes day-one
// behaviour BYTE-IDENTICAL to the behaviour before Item 5(d): no marker is invalidated and
// no deal gets an extra or a missing alert.
//
// ⚠ RESIDUAL-9, stated so it is not later filed as a bug: if an admin CHANGES a rung value
// after go-live, shouldFire compares a NEW rung against an OLD stored marker. It degrades
// gracefully — at most one extra or one missing alert per deal during the transition — but
// it is not zero. Changing a rung is a decision about live records, not a display setting.
//
// ⚠ AND A RUNG WIDER THAN 7 FIRES FOR NOBODY. OpportunitySelector.queryCallForOffersAlerts
// bounds its work queue at TODAY + 7, and a Database.QueryLocator cannot bind an Apex
// collection, so that ceiling cannot read the ladder. CallForOffersService logs a WARN when
// the widest active rung exceeds it (LOCATOR_CEILING_DAYS). Adding a rung above 7 means
// widening that locator in the same change — a deploy, not a Setup edit.
//
// ⚠ IDEMPOTENT. Metadata.Operations.enqueueDeployment UPSERTS on fullName, so re-running
// this restores all four rungs to the values below — which is the intended recovery if
// someone edits them in Setup and needs them put back. It also DISCARDS any deliberate
// tuning. Read the rows before re-running on a live org (query at the bottom).
//
// ⚠ ASYNCHRONOUS. enqueueDeployment returns a job id immediately; the rows are NOT there the
// instant this script finishes. Verify with:
//     sf data query --query "SELECT DeveloperName, Days_Before_Due__c, Is_Active__c FROM \
//       CFO_Alert_Rung__mdt ORDER BY Days_Before_Due__c DESC" --target-org usman-dpeg
// (on Windows run that from PowerShell, not Git Bash).
//
// RUN ORDER:
//   1. deploy force-app/main/default/objects/CFO_Alert_Rung__mdt/ (type + 2 fields) AND
//      CallForOffersService (which needs the type to compile).
//   2. RUN THIS SCRIPT.
//   3. confirm the four rows with the query above, then confirm
//      CallForOffersServiceTest is green against the loaded rows.
// ═══════════════════════════════════════════════════════════════════════════════════════

// ── The four rungs ──────────────────────────────────────────────────────────────────────
// DeveloperName -> [MasterLabel, Days_Before_Due__c]
//
// ⚠ THE DEVELOPER NAMES ARE `Rung_*` AND CARRY THE NUMBER, RATHER THAN BEING `Rung_1..4`.
// An ordinal name would go stale the moment a rung's value changed, and the resolution order
// is derived from Days_Before_Due__c anyway — CallForOffersService sorts DESCENDING
// explicitly because getAll() returns a Map with no guaranteed iteration order. NOTHING
// depends on these names: they exist so a human editing Setup can tell the rows apart.
// ⚠ `Rung_Due_Day` is the 0 rung. Naming it `Rung_0` would read as "disabled" to half of
// the people who open the list view.
//
// ⚠ SMALL LITERAL ON PURPOSE. This repo has a measured Apex parser ceiling on large
// collection-initializer literals (it reports the STATEMENT START, e.g. `Unexpected token
// "<"`, not the real cause). Four rows is nowhere near it; do not grow this into a
// hundred-row initializer if the ladder is ever extended — build it in halves with addAll.
Map<String, List<Object>> rungs = new Map<String, List<Object>>{
    'Rung_7_Day'   => new List<Object>{ '7 Days Before',  7 },
    'Rung_3_Day'   => new List<Object>{ '3 Days Before',  3 },
    'Rung_1_Day'   => new List<Object>{ '1 Day Before',   1 },
    'Rung_Due_Day' => new List<Object>{ 'On the Due Date', 0 }
};

Metadata.DeployContainer container = new Metadata.DeployContainer();

for (String developerName : rungs.keySet()) {
    List<Object> row = rungs.get(developerName);

    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
    // fullName is '<TypeDeveloperName>.<RecordDeveloperName>' — the type name here carries NO
    // __mdt suffix. 'CFO_Alert_Rung__mdt.Rung_7_Day' is wrong and fails silently-ish.
    cm.fullName = 'CFO_Alert_Rung.' + developerName;
    cm.label = (String) row[0];

    Metadata.CustomMetadataValue days = new Metadata.CustomMetadataValue();
    days.field = 'Days_Before_Due__c';
    days.value = row[1];
    cm.values.add(days);

    Metadata.CustomMetadataValue active = new Metadata.CustomMetadataValue();
    active.field = 'Is_Active__c';
    // 🔴 ALL FOUR SHIP ACTIVE. Deactivating every rung is a supported admin act — it switches
    // the alerts off and CallForOffersService HONOURS an empty ladder rather than falling back
    // — but it is not the shipped state, because the shipped state must equal today's
    // behaviour exactly.
    active.value = true;
    cm.values.add(active);

    container.addMetadata(cm);
}

// The count is debugged BEFORE the enqueue as well as after, so a container that was built
// empty (a future edit that filters the map and filters everything out) is visible rather
// than showing up as a silently successful no-op deployment.
System.debug('CFO_Alert_Rung rows in this deployment: ' + rungs.size()
    + ' (expect 4: 7 / 3 / 1 / 0). Ladder seeded from this script MUST equal '
    + 'CallForOffersService.DEFAULT_ALERT_INTERVALS or day-one behaviour changes.');

System.debug('Enqueued CFO_Alert_Rung deploy: '
    + Metadata.Operations.enqueueDeployment(container, null));
