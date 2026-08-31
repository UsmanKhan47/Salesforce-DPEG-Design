// Seed representative Opportunity pipeline data for the Acquisitions dashboard.
// Counts + Asking Price sums match the Deal Stage Pipeline prototype
// (Total Active Deals 42, Total Pipeline Value $252.8M; Dead/Killed excluded).
// NOTE: close dates must fall in the CURRENT fiscal quarter or the dashboard
// reports (which default to a current-quarter close-date filter) won't show them.
List<Opportunity> opps = new List<Opportunity>();
Date soon   = Date.today();
Date thisFy = Date.today();

Map<String, List<Object>> plan = new Map<String, List<Object>>{
    // StageName        => { count, perDealAskingPrice, Deal_Status__c, Deal_Category__c, closeDate, namePrefix }
    'New'            => new List<Object>{ 18, 5233333, 'Evaluating',      'Live', soon,   'Intake Deal' },
    'Under Review'   => new List<Object>{ 11, 5590909, 'Working',         'Live', soon,   'Working Deal' },
    'Underwriting'   => new List<Object>{ 7,  6900000, 'Countered',       'Live', soon,   'Underwriting Deal' },
    'LOI'                  => new List<Object>{ 4,  7450000, 'On Hold',         'Live', soon,   'LOI Deal' },
    'Under Contract (PSA)' => new List<Object>{ 2,  9500000, 'Contract Signed', 'Live', soon,   'Contract Deal' },
    'Dead/Pass'      => new List<Object>{ 9,  5788888, 'Killed',          'Dead', thisFy, 'Dead Deal' }
};

// ═══ 🔴 REJECTION REASONS FOR THE NINE Dead/Pass ROWS — REQUIRED AS OF 2026-08-30 ═══
// `Rejection_Reason_Required_On_Dead` was tightened to fire on INSERT as well as on a stage
// change (user decision 2026-08-30). This script inserts nine Opportunities STRAIGHT AT
// Dead/Pass and previously set no reason anywhere, so without this it now fails outright — all
// 51 rows, because the insert is a single all-or-none DML.
//
// ⚠ EVERY VALUE BELOW IS VERIFIED PRESENT ON BOTH SURVIVING Opportunity RECORD TYPES — Land and
// Retail each list all seven `Rejection_Reason__c` values. RE-VERIFIED 2026-08-30 by reading
// objects/Opportunity/recordTypes/*.recordType-meta.xml directly.
//
// 🔴 THIS PARAGRAPH SAID "ALL THREE ... Land, Retail and Commercial" AND WAS CORRECTED THE SAME
// DAY. It was true when written and became false hours later: a concurrent session staged
// objects/Opportunity/recordTypes/Commercial.recordType-meta.xml FOR DELETION. The VALUES were
// re-checked against the two surviving files rather than the claim merely being renumbered, so
// 'Wrong Market' and the four below are still valid on every record type that exists. The
// correction is recorded rather than silently applied because THIS PARAGRAPH'S ENTIRE POINT IS
// THAT THE CHECK IS NOT OPTIONAL — a verification claim that has quietly gone stale is worse
// than none, since the next reader trusts it instead of re-running it.
//
// That check is NOT optional and a field describe is NOT a substitute for it:
// `Rejection_Reason__c` is a RESTRICTED picklist, record-type restriction IS enforced by DML in
// this org (measured four times; the repo's scattered "UI-only" claims are wrong), and a value
// can be present on the FIELD while absent from a given RECORD TYPE. This script sets no
// RecordTypeId, so the rows take the running user's default — which is exactly why a value valid
// on ALL of them is the only safe choice here.
//
// ⚠ AND THE RECORD-TYPE SET IS ITSELF MOVING. Anyone editing this list must re-read the
// recordTypes directory rather than trusting the names above; "Land and Retail" is a fact as of
// 2026-08-30 and nothing enforces it.
//
// ⚠ ROTATED RATHER THAN CONSTANT so a "dead deals by reason" report shows more than one bar.
// Nine rows over five reasons is 2/2/2/2/1 — deterministic, so re-running the seed produces the
// same demo data.
List<String> deadReasons = new List<String>{
    'Wrong Market', 'Price Too High', 'Failed DD', 'Lost to Competitor', 'Seller Withdrew'
};
Integer deadIndex = 0;

for (String stage : plan.keySet()) {
    List<Object> p = plan.get(stage);
    Integer count        = (Integer) p[0];
    Decimal price        = (Decimal) p[1];
    String  dealStatus   = (String)  p[2];
    String  dealCategory = (String)  p[3];
    Date    closeDate    = (Date)    p[4];
    String  prefix       = (String)  p[5];
    for (Integer i = 1; i <= count; i++) {
        Opportunity o = new Opportunity(
            Name            = prefix + ' ' + i,
            StageName       = stage,
            CloseDate       = closeDate,
            Asking_Price__c = price,
            Deal_Status__c  = dealStatus,
            Deal_Category__c = dealCategory
        );
        // ⚠ ONLY the Dead/Pass rows. A reason on a LIVE deal is not merely noise — it is the
        // state `Rejection_Reason_Required_On_Dead` exists to make meaningful, and seeding one
        // onto an open deal would put demo data into a state no human workflow produces.
        if (stage == 'Dead/Pass') {
            o.Rejection_Reason__c = deadReasons[Math.mod(deadIndex, deadReasons.size())];
            deadIndex++;
        }
        opps.add(o);
    }
}

insert opps;
System.debug('Inserted ' + opps.size() + ' opportunities across the pipeline.');
