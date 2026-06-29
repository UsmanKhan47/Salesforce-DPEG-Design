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
    'LOI Submitted'  => new List<Object>{ 4,  7450000, 'On Hold',         'Live', soon,   'LOI Deal' },
    'Under Contract' => new List<Object>{ 2,  9500000, 'Contract Signed', 'Live', soon,   'Contract Deal' },
    'Dead/Pass'      => new List<Object>{ 9,  5788888, 'Killed',          'Dead', thisFy, 'Dead Deal' }
};

for (String stage : plan.keySet()) {
    List<Object> p = plan.get(stage);
    Integer count        = (Integer) p[0];
    Decimal price        = (Decimal) p[1];
    String  dealStatus   = (String)  p[2];
    String  dealCategory = (String)  p[3];
    Date    closeDate    = (Date)    p[4];
    String  prefix       = (String)  p[5];
    for (Integer i = 1; i <= count; i++) {
        opps.add(new Opportunity(
            Name            = prefix + ' ' + i,
            StageName       = stage,
            CloseDate       = closeDate,
            Asking_Price__c = price,
            Deal_Status__c  = dealStatus,
            Deal_Category__c = dealCategory
        ));
    }
}

insert opps;
System.debug('Inserted ' + opps.size() + ' opportunities across the pipeline.');
