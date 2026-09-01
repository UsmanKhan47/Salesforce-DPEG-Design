// ─────────────────────────────────────────────────────────────────────────────
// DISP-0032 "-" BOV Tracker repair — Lakeline Corporate Center. 2026-08-29.
//
// ══════════════════════════════════════════════════════════════════════════════
// THE DEFECT
// ══════════════════════════════════════════════════════════════════════════════
// The Disposition dashboard's BOV Tracker renders a group labelled "-" with no
// property name. `BOV_Submission__c.Property_Name__c` is a FORMULA —
//     Disposition__r.Property_Asset__r.Name
// — and disposition DISP-0032 (stage `BOV Outreach`) carries
// `Property_Asset__c = null`, so its three BOV rows resolve the formula to blank.
// It is the ONLY disposition with a null asset; the other 7 are fine.
//
// ROOT CAUSE (already diagnosed — this script does not re-investigate it):
// `scripts/seed-disposition-bulk.apex:161` reads
//     Property_Asset__c = assetIdByName.get('Lakeline Corporate Center')
// and NO `Property_Asset__c` by that name has ever existed. A property asset is
// normally minted by the acquisition chain on Closed Won, but Lakeline sits at
// stage `New` in `scripts/seed-fsd-06-volume-pipeline.apex:31`, so it never
// converts and the map lookup silently returns null. `Property_Asset__c` on
// `Disposition__c` is an optional lookup, so the insert succeeded regardless.
//
// ══════════════════════════════════════════════════════════════════════════════
// WHAT THIS SCRIPT DOES
// ══════════════════════════════════════════════════════════════════════════════
//   1. Resolves the EXISTING `Property__c` named 'Lakeline Corporate Center' by
//      name (never by hardcoded Id). It is expected to exist — Asset_Type__c =
//      'Office'. If it does not, the script aborts loudly BEFORE any DML.
//   2. Creates ONE `Property_Asset__c` named exactly 'Lakeline Corporate Center'
//      parented to it, with the full sell-meter field set populated so the row
//      does not look half-empty beside its 5 fully-stamped siblings.
//   3. Repoints DISP-0032's `Property_Asset__c` at that asset (disposition
//      resolved by `Name = 'DISP-0032'`, never by hardcoded Id).
//   4. Re-queries the three BOV rows and prints their now-populated
//      `Property_Name__c` — the actual fix, not a success message.
//
// NON-DESTRUCTIVE. No deletes. Two DML statements total (one insert, one update),
// neither inside a loop.
//
// ── IDEMPOTENT ────────────────────────────────────────────────────────────────
// The asset is looked up by name first and REUSED if present; the disposition is
// only updated when its `Property_Asset__c` is null or points elsewhere. A second
// run therefore performs 0 DML and reports a labelled NO-OP.
//
// ══════════════════════════════════════════════════════════════════════════════
// 🔴 VALUE COHERENCE — THE WHOLE POINT OF THE NUMBERS BELOW
// ══════════════════════════════════════════════════════════════════════════════
// DISP-0032's three BOVs are 32,100,000 / 32,950,000 / 33,800,000. The Lakeline
// row in the ACQUISITION pipeline (`seed-fsd-06-volume-pipeline.apex`) carries
// 18,200,000 — roughly HALF the brokers' opinions. Reusing 18.2M here would put a
// blatantly contradictory number next to those BOVs on the SAME dashboard, which
// is a worse demo defect than the blank label this script exists to fix.
//
// So `Argus_Value__c` is set to 31,800,000 — low 30-millions, sitting just under
// the lowest broker opinion (32.1M) by ~300K. That is the realistic relationship:
// brokers pitching for a listing quote at or slightly above the owner's internal
// valuation, because the pitch IS the argument that the asset is worth more than
// the owner thinks.
//
// `NOI__c` is then DERIVED, never stated:
//     NOI = Argus_Value * Market_Cap_Rate / 100
//         = 31,800,000 * 6.50 / 100 = 2,067,000.00
// which is the exact invariant every sibling asset satisfies (verified on the
// existing 5: Copperfield 1,608,000 / 0.0600 = 26,800,000 = its Argus_Value;
// Windcrest 1,559,250 / 0.0675 = 23,100,000 = its Argus_Value). Deriving it in
// code rather than typing a second figure makes a typo impossible.
//
// The cap rate 6.50 is the value `seed-sell-meter.apex` already reserved for
// Lakeline, so this asset lands where that script always intended it to.
//
// ── SIGNAL / SCORE / DATE ────────────────────────────────────────────────────
// The deal is at `BOV Outreach` — actively being taken to market — so `Hold`
// would contradict the stage on the same screen. Signal is `Sell Now`, and
// `Sell_Readiness_Score__c` = 85 sits in the Sell Now band (80-92) used by
// `seed-asset-sell-signals.apex`; 85 is not used by any existing row.
// `Peak_Sell_Date__c` = today + 21 days, matching the same script's Sell Now
// spread (11 / 18 / 23 / 29 days) and landing the asset GREEN on the Sell Meter
// (`SellMeterService.bandForPeak`: <= 30 GREEN, 31-90 YELLOW, > 90 RED), which is
// the band a live BOV outreach should be in.
//
// ── TARGET / PROJECTED (house convention, from seed-asset-sell-signals.apex) ──
//     target    = argusValue * 0.95   (discount band 0.87-0.95 — below fair value
//                                      so the portfolio-upside tile is positive)
//               = 30,210,000
//     projected = target * 1.08       (uplift band 1.05-1.10, above target)
//               = 32,626,800
// The 0.95 discount (top of the band) is chosen deliberately: `BOV_Score__c`
// scores value as 50 * MIN(BOV_Amount / Target_Sale_Price, 1.10) / 1.10, so the
// three BOVs land at ratios 1.063 / 1.091 / 1.119 — only the highest hits the
// 1.10 cap, giving a differentiated 48.3 / 49.6 / 50.0 value term instead of two
// rows tying at the ceiling. Those three scores are currently BLANK (the formula
// returns null when the asset chain is broken), so this also un-blanks the BOV
// score column as a side effect of the fix.
//
// ══════════════════════════════════════════════════════════════════════════════
// FIELD SAFETY — every API name and picklist literal verified against
// force-app/main/default/objects/Property_Asset__c/fields/ and
// force-app/main/default/objects/Disposition__c/fields/ on 2026-08-29
// ══════════════════════════════════════════════════════════════════════════════
// Property_Asset__c (Name is a Text name field, not an autonumber — so we can set it):
//   Property__c                Lookup -> Property__c (deleteConstraint SetNull)
//   Status__c                  Picklist, restricted=TRUE, values EXACTLY {Active, Disposed}
//                              -> writing 'Active'   ✔ (restricted picklists ARE
//                                 DML-enforced on this project; a stale literal is a
//                                 hard INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST failure)
//   Property_Type__c           Picklist, NOT restricted, values EXACTLY
//                              {Retail, Industrial, Multifamily, Office, Mixed-Use}
//                              -> writing 'Office'   ✔ (matches the parent Property__c's
//                                 Asset_Type__c = 'Office'; asserted at runtime below)
//   Argus_Signal__c            Picklist, restricted=TRUE, values EXACTLY
//                              {Sell Now, 12 mo, Hold} -> writing 'Sell Now'  ✔
//   Sell_Readiness_Score__c    Percent(3,0)    -> 85
//   Argus_Value__c             Currency(18,2)  -> 31,800,000.00
//   NOI__c                     Currency(18,2)  -> derived, .setScale(2)
//   Market_Cap_Rate__c         Percent(5,2)    -> 6.50
//   Peak_Sell_Date__c          Date            -> today + 21
//   Target_Sale_Price__c       Currency(18,2)  -> derived, .setScale(2)
//   Projected_Value_At_Peak__c Currency(18,0)  -> derived, .setScale(0)  ⚠ scale 0
//
// 🔴 DELIBERATELY NOT WRITTEN — FORMULA fields; any write is a runtime failure:
//   Readiness_Score__c      IF(ISPICKVAL(Argus_Signal__c,"Sell Now"),1,0)
//   Sell_Readiness_Band__c  CASE(TEXT(Argus_Signal__c), ...)
//   Property_Name__c        Name
// [RETRACTED 2026-08-31, Disposition Gap Closure TRANCHE 2 item 1a/1b — see
//  agent-output/disposition-gap-closure-t2-design.md §3 item 1. The two quoted formulas above are
//  STALE and the closing line is now partly FALSE — kept, not deleted:]
// [FALSE AS OF 2026-08-31] All three are derived from what we DO write, so they populate for
// free. [END FALSE, for the first two only]
// CORRECTED: Sell_Readiness_Band__c now derives from Peak_Sell_Date__c (days-until-peak,
// mirroring SellMeterService.bandForPeak), and Readiness_Score__c now derives from
// Sell_Readiness_Band__c — Argus_Signal__c drives neither formula any longer. Property_Name__c
// (formula: Name) is UNCHANGED. This script's outcome is unaffected in practice because it
// already writes Peak_Sell_Date__c = today + 21 (GREEN under the new rule) alongside
// Argus_Signal__c = 'Sell Now', so the two still tell the same story here — but that is now a
// property of the CHOSEN VALUES, not of the formula's mechanism.
//
// 🔴 DELIBERATELY NOT WRITTEN — `Closing_Date__c`. THIS IS A SAFETY CONSTRAINT,
//    NOT AN OMISSION. `PropertyAssetTrigger` -> `PropertyAssetTriggerHandler
//    .afterInsert` -> `OnboardingAutoCreateService.ensureOnClosing` keys on
//    `Closing_Date__c` TRANSITIONING to non-null. Setting it on this insert would
//    mint an unwanted `Onboarding__c` plus the ~45-Task checklist fan-out. Because
//    we leave it null the service returns before its first query: 0 extra SOQL,
//    0 extra DML, 0 Onboarding rows. Do not "complete" this record by adding it.
//
// ALSO not written: `Final_Purchase_Price__c`, `Vacant_Area__c` — out of scope,
// and the 5 stamped siblings do not carry them either.
//
// Disposition__c: ONLY `Property_Asset__c` is written. The update is built as a
// FRESH, NARROW sObject (`new Disposition__c(Id = ..., Property_Asset__c = ...)`)
// rather than by mutating the queried row, so no other field value is re-sent.
//
// ══════════════════════════════════════════════════════════════════════════════
// AUTOMATION AUDIT — checked against the repo, not assumed
// ══════════════════════════════════════════════════════════════════════════════
// ✔ NO before-save flow exists on `Disposition__c`. The six flows that mention
//   the object are: NDA_Signed_Rollup (start object NDA__c, RecordAfterSave),
//   Wire_Verification_Rollup (Wire__c, RecordAfterSave), Counter_Offer_Notify
//   (Counter_Offer__c), PSA_Ready_Notify + Contract_Review_Stage_Sync
//   (Contract_Review__c), PSA_Version_Notify (PSA_Version__c). The only
//   RecordBeforeSave flow among them is Contract_Review_Stage_Sync, whose start
//   object is Contract_Review__c. So the `Contract_Review__c.Stage__c`
//   silently-discarded-write hazard this repo has previously hit does NOT apply
//   here — nothing recomputes `Property_Asset__c` on save.
//
// ✔ `PropertyAssetTriggerHandler.afterInsert` routes ONLY to
//   `OnboardingAutoCreateService.ensureOnClosing`, which no-ops without a
//   Closing_Date__c transition (see above). `BovAutoSelectionService
//   .reselectForRepricedDispositions` is on afterUPDATE only — deliberately, since
//   a brand-new asset has no dispositions — so our INSERT does not fire it. On the
//   idempotent re-run path we do not update the asset at all, so it stays unfired.
//
// ✔ `DispositionTriggerHandler` before/after update route to
//   `stampListingDates` (guarded on a transition INTO 'Active Listing'),
//   `stampSelectedBrokerLabel` (guarded on `Broker__c` changing),
//   `createStageEntryRecords` (guarded on `priorStage != newStage`) and
//   `enqueuePendingAdvances` (guarded on `Approval_Advance_Pending__c` going
//   true). We change only `Property_Asset__c`, so all four return early: no
//   child records, no queueable, no stage movement.
//
// ✔ All three `Disposition__c` validation rules are stage-gated —
//   All_NDAs_Signed_Before_Progression (`ISCHANGED(Disposition_Stage__c)` +
//   forward stages), Wire_Complete_Before_Sale_Closes (`ISPICKVAL(...,'Sale
//   Closes')`), Broker_Lookup_Is_Off_Market_Only (`NOT(ISBLANK(Broker__c))` AND
//   `Is_On_Market__c`). None can fire on an asset-only edit at 'BOV Outreach'.
//
// ⚠ FORWARD HAZARD, worth knowing but NOT acted on here: `seed-sell-meter.apex`
//   already contains a 'Lakeline Corporate Center' entry (NOI 2,223,000 @ 6.5,
//   implied fair 34,200,000, peak today+55) and selects on `Property__c != null`.
//   Once this asset exists, a future run of THAT script will overwrite the NOI,
//   cap, target, projected and peak date set here — leaving Argus_Value 31.8M
//   beside an implied fair value of 34.2M that sits ABOVE all three BOVs. If that
//   script is ever re-run, re-run this one's sibling `seed-asset-sell-signals`
//   conventions or update the Lakeline row there to NOI 2,067,000 @ 6.50.
//   `seed-asset-sell-signals.apex` is NOT a hazard: it filters
//   `Argus_Signal__c = null` and we stamp the signal on insert.
//
// ⚠ `BOV_Submission__c.Approval_Pending__c` is deliberately EXCLUDED from the
//   readback query. It has zero FieldPermissions rows by design, and anonymous
//   Apex naming it does not COMPILE. Every other field this script touches was
//   confirmed to be granted in at least 2 permission sets.
// ─────────────────────────────────────────────────────────────────────────────

final String ASSET_NAME = 'Lakeline Corporate Center';
final String DISP_NAME  = 'DISP-0032';

// ── Inputs, all stated once so the header's arithmetic is checkable at a glance ──
final Decimal ARGUS_VALUE      = 31800000;   // just under the lowest BOV (32,100,000)
final Decimal CAP_RATE         = 6.50;       // the value seed-sell-meter.apex reserved for Lakeline
final Integer READINESS_SCORE  = 85;         // Sell Now band is 80-92
final Integer PEAK_DAYS_OUT    = 21;         // <= 30 => GREEN on the Sell Meter
final Decimal TARGET_DISCOUNT  = 0.95;       // house band 0.87-0.95
final Decimal PEAK_UPLIFT      = 1.08;       // house band 1.05-1.10

// Derived — NEVER typed a second time. This is the invariant every sibling satisfies.
Decimal noi       = (ARGUS_VALUE * CAP_RATE / 100).setScale(2);   // 2,067,000.00
Decimal target    = (ARGUS_VALUE * TARGET_DISCOUNT).setScale(2);  // 30,210,000.00
Decimal projected = (target * PEAK_UPLIFT).setScale(0);           // 32,626,800
Date    today     = Date.today();

// ═════════════════════════════════════════════════════════════════════════════
// STEP 1 — resolve the EXISTING Property__c by name. No hardcoded Id.
// ═════════════════════════════════════════════════════════════════════════════
List<Property__c> properties = [
    SELECT Id, Name, Asset_Type__c
    FROM Property__c
    WHERE Name = :ASSET_NAME
    ORDER BY CreatedDate
];

if (properties.isEmpty()) {
    throw new HandledException(
        'ABORT before any DML — no Property__c named "' + ASSET_NAME + '" exists in this org. '
        + 'It was verified present (Id a0Oiw000000W0T9EAK, Asset_Type__c = Office) on 2026-08-29, '
        + 'so either the org has been reset or the record was renamed. Do NOT create one here: '
        + 'this script is a targeted repair, and minting a Property would hide a bigger problem.'
    );
}
if (properties.size() > 1) {
    throw new HandledException(
        'ABORT before any DML — ' + properties.size() + ' Property__c rows are named "' + ASSET_NAME
        + '". Exactly one was expected. Parenting the new asset to an arbitrary one of them would be '
        + 'a guess, and duplicate properties are their own defect. Ids: ' + new Map<Id, Property__c>(properties).keySet()
    );
}
Property__c parentProperty = properties[0];

// The asset's Property_Type__c is set to 'Office' to mirror the parent. Assert rather than
// assume, so a changed parent surfaces here instead of as a quietly mismatched demo record.
if (parentProperty.Asset_Type__c != 'Office') {
    throw new HandledException(
        'ABORT before any DML — Property__c "' + ASSET_NAME + '" has Asset_Type__c = '
        + parentProperty.Asset_Type__c + ', but this script hardcodes Property_Type__c = \'Office\' '
        + 'on the asset to mirror it. Reconcile the two before running. Note the two picklists are '
        + 'NOT the same value set: Property__c.Asset_Type__c has 10 values (incl. Land, C-Store, '
        + 'Medical Office, Storage, Hospitality) that Property_Asset__c.Property_Type__c does not.'
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// STEP 2 — create the Property_Asset__c, or REUSE it if a previous run made one.
//          This lookup-first shape is what makes the script idempotent.
// ═════════════════════════════════════════════════════════════════════════════
List<Property_Asset__c> existingAssets = [
    SELECT Id, Name, Property__c, Status__c, Property_Type__c, Argus_Signal__c,
           Sell_Readiness_Score__c, Argus_Value__c, NOI__c, Market_Cap_Rate__c,
           Peak_Sell_Date__c, Projected_Value_At_Peak__c, Target_Sale_Price__c,
           Sell_Readiness_Band__c, Closing_Date__c
    FROM Property_Asset__c
    WHERE Name = :ASSET_NAME
    ORDER BY CreatedDate
];

Property_Asset__c asset;
Boolean assetWasCreated = false;

if (!existingAssets.isEmpty()) {
    asset = existingAssets[0];
    System.debug(LoggingLevel.ERROR, 'LAKELINE_REPAIR REUSING existing Property_Asset__c '
        + asset.Id + ' named "' + ASSET_NAME + '" (' + existingAssets.size()
        + ' row(s) matched) — NOT creating a duplicate. Its sell-meter values are left EXACTLY as '
        + 'they are; this script only ever stamps them on a row it creates itself.');
} else {
    asset = new Property_Asset__c(
        Name                       = ASSET_NAME,
        Property__c                = parentProperty.Id,
        Status__c                  = 'Active',      // restricted picklist {Active, Disposed}
        Property_Type__c           = 'Office',      // {Retail, Industrial, Multifamily, Office, Mixed-Use}
        Argus_Signal__c            = 'Sell Now',    // restricted picklist {Sell Now, 12 mo, Hold}
        Sell_Readiness_Score__c    = READINESS_SCORE,
        Argus_Value__c             = ARGUS_VALUE,
        NOI__c                     = noi,
        Market_Cap_Rate__c         = CAP_RATE,
        Peak_Sell_Date__c          = today.addDays(PEAK_DAYS_OUT),
        Projected_Value_At_Peak__c = projected,
        Target_Sale_Price__c       = target
        // Closing_Date__c INTENTIONALLY OMITTED — see the header. Setting it fires
        // OnboardingAutoCreateService.ensureOnClosing and mints ~45 Tasks.
    );

    Database.SaveResult insertResult = Database.insert(asset, true);
    if (!insertResult.isSuccess()) {
        String errs = '';
        for (Database.Error e : insertResult.getErrors()) {
            errs += '[' + e.getStatusCode() + '] ' + e.getMessage() + ' fields=' + e.getFields() + ' | ';
        }
        throw new HandledException('LAKELINE_REPAIR asset insert FAILED — ' + errs);
    }
    assetWasCreated = true;
    System.debug(LoggingLevel.ERROR, 'LAKELINE_REPAIR CREATED Property_Asset__c ' + asset.Id
        + ' named "' + ASSET_NAME + '" under Property__c ' + parentProperty.Id);
}

// ═════════════════════════════════════════════════════════════════════════════
// STEP 3 — repoint DISP-0032. Resolved by Name, never by hardcoded Id.
// ═════════════════════════════════════════════════════════════════════════════
List<Disposition__c> dispositions = [
    SELECT Id, Name, Disposition_Stage__c, Property_Asset__c
    FROM Disposition__c
    WHERE Name = :DISP_NAME
];

if (dispositions.isEmpty()) {
    throw new HandledException(
        'ABORT — no Disposition__c named "' + DISP_NAME + '" exists. The Property_Asset__c above '
        + (assetWasCreated ? 'WAS CREATED and is now orphaned' : 'already existed and is untouched')
        + '; nothing else was written. Auto-number names shift on a data reset — re-identify the '
        + 'BOV Outreach disposition whose Property_Asset__c is null before re-running.'
    );
}
Disposition__c disposition = dispositions[0];

Boolean dispositionWasRepaired = false;
if (disposition.Property_Asset__c == asset.Id) {
    System.debug(LoggingLevel.ERROR, 'LAKELINE_REPAIR NO-OP on ' + DISP_NAME
        + ' — it ALREADY points at ' + asset.Id + '. This is the EXPECTED result of a second run.');
} else if (disposition.Property_Asset__c != null) {
    // Refuse rather than silently repoint: a non-null value means someone (or something)
    // already made a decision here, and overwriting it is not this script's job.
    System.debug(LoggingLevel.ERROR, 'LAKELINE_REPAIR ⚠ REFUSING to repoint ' + DISP_NAME
        + ' — its Property_Asset__c is ALREADY set to ' + disposition.Property_Asset__c
        + ', which is not the Lakeline asset (' + asset.Id + '). The blank-label defect this script '
        + 'fixes cannot be present, so the link is left alone. Investigate manually if the dashboard '
        + 'still shows a "-" group.');
} else {
    // Fresh, NARROW sObject — only Id and the one field being changed are sent, so no other
    // value is re-asserted from the queried row.
    Disposition__c patch = new Disposition__c(Id = disposition.Id, Property_Asset__c = asset.Id);
    Database.SaveResult updateResult = Database.update(patch, true);
    if (!updateResult.isSuccess()) {
        String errs = '';
        for (Database.Error e : updateResult.getErrors()) {
            errs += '[' + e.getStatusCode() + '] ' + e.getMessage() + ' fields=' + e.getFields() + ' | ';
        }
        throw new HandledException('LAKELINE_REPAIR disposition update FAILED — ' + errs);
    }
    dispositionWasRepaired = true;
    System.debug(LoggingLevel.ERROR, 'LAKELINE_REPAIR LINKED ' + DISP_NAME + ' (' + disposition.Id
        + ') -> Property_Asset__c ' + asset.Id);
}

// ═════════════════════════════════════════════════════════════════════════════
// STEP 4 — VERIFY. Re-query everything from the database so the output is what
//          the org actually holds, not what we hoped we wrote.
// ═════════════════════════════════════════════════════════════════════════════
Property_Asset__c assetAfter = [
    SELECT Id, Name, Property__c, Property__r.Name, Status__c, Property_Type__c,
           Argus_Signal__c, Sell_Readiness_Band__c, Sell_Readiness_Score__c,
           Argus_Value__c, NOI__c, Market_Cap_Rate__c, Peak_Sell_Date__c,
           Target_Sale_Price__c, Projected_Value_At_Peak__c, Closing_Date__c
    FROM Property_Asset__c
    WHERE Id = :asset.Id
    LIMIT 1
];

Disposition__c dispAfter = [
    SELECT Id, Name, Disposition_Stage__c, Property_Asset__c, Property_Asset__r.Name
    FROM Disposition__c
    WHERE Id = :disposition.Id
    LIMIT 1
];

// The three BOV rows — the actual user-visible symptom.
// ⚠ Approval_Pending__c is NOT selected: zero FieldPermissions by design, and naming it
//   in anonymous Apex is a COMPILE failure, not a runtime one.
List<BOV_Submission__c> bovs = [
    SELECT Id, Name, Property_Name__c, BOV_Amount__c, BOV_Score__c, Broker_Firm__c,
           Contact_Name__c, Submission_Status__c
    FROM BOV_Submission__c
    WHERE Disposition__c = :disposition.Id
    ORDER BY BOV_Amount__c DESC NULLS LAST
];

System.debug(LoggingLevel.ERROR, '═════════ LAKELINE_REPAIR SUMMARY ═════════');
System.debug(LoggingLevel.ERROR, 'ACTIONS | asset '
    + (assetWasCreated ? 'CREATED' : 'REUSED (pre-existing)')
    + ' | disposition link '
    + (dispositionWasRepaired ? 'REPAIRED' : 'unchanged (already correct, or already pointed elsewhere)')
    + ' | DML statements issued: '
    + ((assetWasCreated ? 1 : 0) + (dispositionWasRepaired ? 1 : 0)));

System.debug(LoggingLevel.ERROR, 'PROPERTY  | ' + parentProperty.Name + ' | Id=' + parentProperty.Id
    + ' | Asset_Type__c=' + parentProperty.Asset_Type__c);

System.debug(LoggingLevel.ERROR, 'ASSET     | Id=' + assetAfter.Id
    + ' | Name="' + assetAfter.Name + '"'
    + ' | Property__c=' + assetAfter.Property__c + ' ("' + assetAfter.Property__r.Name + '")'
    + ' | Status=' + assetAfter.Status__c
    + ' | Type=' + assetAfter.Property_Type__c
    + ' | Closing_Date__c=' + assetAfter.Closing_Date__c + ' (MUST be null — see header)');
System.debug(LoggingLevel.ERROR, 'SELL METER| signal=' + assetAfter.Argus_Signal__c
    + ' | band(formula)=' + assetAfter.Sell_Readiness_Band__c
    + ' | score=' + assetAfter.Sell_Readiness_Score__c
    + ' | argusValue=' + assetAfter.Argus_Value__c
    + ' | NOI=' + assetAfter.NOI__c
    + ' | cap=' + assetAfter.Market_Cap_Rate__c
    + ' | peak=' + assetAfter.Peak_Sell_Date__c
    + ' | target=' + assetAfter.Target_Sale_Price__c
    + ' | projectedAtPeak=' + assetAfter.Projected_Value_At_Peak__c);

// Restate the invariant from the values actually stored, so a drifted row is visible.
if (assetAfter.Argus_Value__c != null && assetAfter.NOI__c != null
        && assetAfter.Market_Cap_Rate__c != null && assetAfter.Market_Cap_Rate__c != 0) {
    Decimal impliedFair = (assetAfter.NOI__c * 100 / assetAfter.Market_Cap_Rate__c).setScale(2);
    System.debug(LoggingLevel.ERROR, 'INVARIANT | implied fair value = NOI / (cap/100) = ' + impliedFair
        + ' vs Argus_Value__c = ' + assetAfter.Argus_Value__c
        + ' -> ' + (impliedFair == assetAfter.Argus_Value__c ? 'MATCH ✔' : 'DRIFT ⚠ (a sibling script may have restamped this row)'));
}

System.debug(LoggingLevel.ERROR, 'DISPOSITION | ' + dispAfter.Name + ' | Id=' + dispAfter.Id
    + ' | stage=' + dispAfter.Disposition_Stage__c
    + ' | Property_Asset__c=' + dispAfter.Property_Asset__c
    + ' | Property_Asset__r.Name="' + dispAfter.Property_Asset__r.Name + '"');

System.debug(LoggingLevel.ERROR, '───────── BOV rows on ' + DISP_NAME + ' (' + bovs.size()
    + ' found — the "-" group on the BOV Tracker) ─────────');
Integer stillBlank = 0;
for (BOV_Submission__c b : bovs) {
    if (String.isBlank(b.Property_Name__c)) {
        stillBlank++;
    }
    System.debug(LoggingLevel.ERROR, 'BOV | ' + b.Name
        + ' | Property_Name__c="' + b.Property_Name__c + '"   <-- was blank before this fix'
        + ' | amount=' + b.BOV_Amount__c
        + ' | score=' + b.BOV_Score__c
        + ' | firm=' + b.Broker_Firm__c
        + ' | contact=' + b.Contact_Name__c
        + ' | status=' + b.Submission_Status__c);
}
System.debug(LoggingLevel.ERROR, 'RESULT | BOV rows with a BLANK Property_Name__c: ' + stillBlank
    + ' of ' + bovs.size() + '  (must be 0 — a non-zero value means the dashboard will STILL show "-")');
System.debug(LoggingLevel.ERROR, '═════════ END LAKELINE_REPAIR ═════════');
