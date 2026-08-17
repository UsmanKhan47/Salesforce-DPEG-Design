/**
 * FSD demo data - Part 6: "volume" Opportunities inserted DIRECTLY (no Lead conversion,
 * no stage-by-stage walk) purely to give every Kanban/list view a populated look across
 * every stage bucket. Safe to insert straight at a deep stage because every Opportunity
 * stage-gate validation rule in this org is ISCHANGED(StageName)-scoped, which is FALSE on
 * INSERT (see No_Backward_Stage_Movement's own comment) - so none of the NDA/UW/LOI/PSA
 * gates fire here. OpportunityReviewTrigger still fires normally and will auto-create the
 * usual stage-appropriate child record (NDA on every insert; Underwriting/LOI/Contract
 * Review/Development-or-Construction-Review on the matching stage), which is a deliberate,
 * free bonus for realism, not something this script drives itself.
 * Idempotent: skips the whole batch if the marker Property (first row) already exists.
 */
final String MARKER = 'Alta Vista Crossing';
if ([SELECT COUNT() FROM Property__c WHERE Name = :MARKER] > 0) {
    System.debug('Volume pipeline already seeded - skipping.');
} else {
    Id landRT = [SELECT Id FROM RecordType WHERE SObjectType = 'Opportunity' AND DeveloperName = 'Land' LIMIT 1].Id;
    Id retailRT = [SELECT Id FROM RecordType WHERE SObjectType = 'Opportunity' AND DeveloperName = 'Retail' LIMIT 1].Id;

    Map<String, Id> acctByName = new Map<String, Id>();
    for (Account a : [SELECT Id, Name FROM Account WHERE Type = 'Broker Firm']) { acctByName.put(a.Name, a.Id); }
    List<String> firms = new List<String>(acctByName.keySet());

    // [Name, City, Street, Postal, AssetType(Opp set), DealType(Land/Retail), Stage,
    //  AskingPrice, MyPrice, MyCap, MktCap, DealStatus, DealCategory, DaysAgoBrokerSeen,
    //  RejectionReason(nullable), CallForOffers(bool)]
    List<List<Object>> rows = new List<List<Object>>{
        // New (4)
        new List<Object>{ 'Alta Vista Crossing', 'San Marcos', '2100 Hunter Rd', '78666', 'Retail Strip', 'Retail', 'New', 12800000, null, null, 6.7, 'Evaluating', 'Live', 3, null, true },
        new List<Object>{ 'Bandera Ranch Land Tract', 'Bandera', '600 TX-16', '78003', 'Land', 'Land', 'New', 4300000, null, null, null, 'Evaluating', 'Live', 5, null, false },
        new List<Object>{ 'Lakeline Corporate Center', 'Cedar Park', '11200 Lakeline Blvd', '78613', 'Office', 'Retail', 'New', 18200000, null, null, 7.0, 'Evaluating', 'Live', 2, null, true },
        new List<Object>{ 'Converse Gateway Land', 'Converse', '8700 FM 1516', '78109', 'Land', 'Land', 'New', 5100000, null, null, null, 'Evaluating', 'Live', 4, null, true },
        // Under Review (4)
        new List<Object>{ 'Willowbrook Plaza', 'Houston', '7500 FM 1960 W', '77070', 'Retail Strip', 'Retail', 'Under Review', 20600000, null, null, 6.5, 'Working', 'Live', 12, null, false },
        new List<Object>{ 'Hays County Land Reserve', 'Kyle', '2900 FM 150', '78640', 'Land', 'Land', 'Under Review', 6700000, null, null, null, 'Working', 'Live', 10, null, false },
        new List<Object>{ 'Northgate Business Center', 'San Antonio', '10500 Northgate Dr', '78154', 'Industrial', 'Retail', 'Under Review', 16400000, null, null, 7.2, 'Working', 'Live', 14, null, false },
        new List<Object>{ 'Comfort Hill Country Land', 'Comfort', '1400 TX-27', '78013', 'Land', 'Land', 'Under Review', 3900000, null, null, null, 'Working', 'Live', 9, null, true },
        // Development Review (Land only, 3)
        new List<Object>{ 'Buda Trailhead Land Assemblage', 'Buda', '3300 Main St', '78610', 'Land', 'Land', 'Development Review', 9200000, null, null, null, 'Working', 'Live', 19, null, false },
        new List<Object>{ 'Marble Falls Lakefront Tract', 'Marble Falls', '1500 RR 1431', '78654', 'Land', 'Land', 'Development Review', 7600000, null, null, null, 'Working', 'Live', 22, null, false },
        new List<Object>{ 'Seguin Industrial Land', 'Seguin', '2200 N Guadalupe St', '78155', 'Land', 'Land', 'Development Review', 5400000, null, null, null, 'Working', 'Live', 17, null, false },
        // Construction Review (Retail only, 3)
        new List<Object>{ 'Sherman Oaks Center', 'San Antonio', '4400 Fredericksburg Rd', '78201', 'Retail Strip', 'Retail', 'Construction Review', 14100000, null, null, 6.8, 'Working', 'Live', 25, null, false },
        new List<Object>{ 'Boerne Trade Center', 'Boerne', '31000 IH-10 W', '78006', 'Industrial', 'Retail', 'Construction Review', 22300000, null, null, 7.1, 'Working', 'Live', 28, null, false },
        new List<Object>{ 'Live Oak Medical Court', 'Live Oak', '8100 Foster Rd', '78233', 'Medical Office', 'Retail', 'Construction Review', 11700000, null, null, 6.9, 'Working', 'Live', 20, null, false },
        // Underwriting (4)
        new List<Object>{ 'Cibolo Crossing Retail', 'Cibolo', '5500 FM 1103', '78108', 'Retail Strip', 'Retail', 'Underwriting', 17900000, 17400000, 6.6, 6.5, 'Countered', 'Live', 33, null, false },
        new List<Object>{ 'Guadalupe County Land Fund', 'Schertz', '2000 FM 78', '78154', 'Land', 'Land', 'Underwriting', 8100000, 7900000, null, null, 'Countered', 'Live', 30, null, false },
        new List<Object>{ 'Selma Distribution Hub', 'Selma', '17700 IH-35 N', '78154', 'Industrial', 'Retail', 'Underwriting', 26800000, 25900000, 7.0, 6.8, 'Working', 'Live', 27, null, false },
        new List<Object>{ 'Uhland Ranch Land', 'Uhland', '600 Old Bastrop Hwy', '78640', 'Land', 'Land', 'Underwriting', 6200000, 6000000, null, null, 'Working', 'Live', 24, null, false },
        // LOI (4)
        new List<Object>{ 'Kerrville Riverside Retail', 'Kerrville', '1200 Sidney Baker St', '78028', 'Retail Strip', 'Retail', 'LOI', 13600000, 13200000, 6.9, 6.7, 'LOI Signed', 'Live', 40, null, false },
        new List<Object>{ 'Fredericksburg Vineyard Land', 'Fredericksburg', '9800 US-290', '78624', 'Land', 'Land', 'LOI', 7400000, 7200000, null, null, 'Countered', 'Live', 37, null, false },
        new List<Object>{ 'Universal City Office Park', 'Universal City', '2100 Pat Booker Rd', '78148', 'Office', 'Retail', 'LOI', 21400000, 20800000, 7.2, 7.0, 'LOI Signed', 'Live', 44, null, false },
        new List<Object>{ 'Wimberley Hill Country Land', 'Wimberley', '400 RR 12', '78676', 'Land', 'Land', 'LOI', 5800000, 5650000, null, null, 'Working', 'Live', 35, null, false },
        // Under Contract (PSA) (4)
        new List<Object>{ 'Helotes Market Commons', 'Helotes', '13400 Bandera Rd', '78023', 'Retail Strip', 'Retail', 'Under Contract (PSA)', 19500000, 19300000, 6.4, 6.3, 'Contract Signed', 'Live', 55, null, false },
        new List<Object>{ 'Blanco River Land Portfolio', 'Wimberley', '700 River Rd', '78676', 'Land', 'Land', 'Under Contract (PSA)', 8900000, 8750000, null, null, 'Contract Signed', 'Live', 52, null, false },
        new List<Object>{ 'Converse Logistics Park', 'Converse', '5200 FM 78', '78109', 'Industrial', 'Retail', 'Under Contract (PSA)', 29800000, 29200000, 6.9, 6.7, 'Contract Signed', 'Live', 58, null, false },
        new List<Object>{ 'New Braunfels Growth Corridor', 'New Braunfels', '3500 IH-35 N', '78130', 'Land', 'Land', 'Under Contract (PSA)', 9600000, 9400000, null, null, 'Contract Signed', 'Live', 49, null, false },
        // About to Close (3)
        new List<Object>{ 'Round Rock Premium Outparcels', 'Round Rock', '2500 IH-35 N', '78664', 'Retail Strip', 'Retail', 'About to Close', 15300000, 15100000, 6.5, 6.4, 'Contract Signed', 'Live', 63, null, false },
        new List<Object>{ 'Spring Branch Ranch Land', 'Spring Branch', '900 FM 311', '78070', 'Land', 'Land', 'About to Close', 6900000, 6800000, null, null, 'Contract Signed', 'Live', 60, null, false },
        new List<Object>{ 'Leon Valley Shopping Center', 'Leon Valley', '6800 Bandera Rd', '78238', 'Retail Strip', 'Retail', 'About to Close', 21100000, 20900000, 6.6, 6.5, 'Contract Signed', 'Live', 66, null, false },
        // Closed Won (4)
        new List<Object>{ 'Universal City Retail Row', 'Universal City', '1900 Kitty Hawk Rd', '78148', 'Retail Strip', 'Retail', 'Closed Won', 16700000, 16700000, 6.7, 6.7, 'Asset Under Management', 'Closed', 90, null, false },
        new List<Object>{ 'Canyon Lake Land Holdings', 'Canyon Lake', '2100 FM 2673', '78133', 'Land', 'Land', 'Closed Won', 5200000, 5200000, null, null, 'Asset Under Management', 'Closed', 95, null, false },
        new List<Object>{ 'Windcrest Business Park', 'Windcrest', '8500 IH-35 N', '78239', 'Industrial', 'Retail', 'Closed Won', 24600000, 24600000, 6.8, 6.8, 'Asset Under Management', 'Closed', 100, null, false },
        new List<Object>{ 'Terrell Hills Medical Plaza', 'Terrell Hills', '4700 Broadway St', '78209', 'Medical Office', 'Retail', 'Closed Won', 12900000, 12900000, 6.5, 6.5, 'Asset Under Management', 'Closed', 88, null, false },
        // Dead/Pass (2)
        new List<Object>{ 'Von Ormy Frontage Land', 'Von Ormy', '15100 IH-35 S', '78073', 'Land', 'Land', 'Dead/Pass', 4700000, null, null, null, 'Killed', 'Dead', 48, 'Seller Withdrew', false },
        new List<Object>{ 'Elmendorf Rail Yard', 'Elmendorf', '2200 FM 1937', '78112', 'Industrial', 'Retail', 'Dead/Pass', 13400000, null, null, 8.2, 'Killed', 'Dead', 42, 'Lost to Competitor', false }
    };

    // Property__c.Asset_Type__c has its OWN restricted value set (Retail, not Retail Strip;
    // no direct C-Store/Storage in this dataset) - map, don't copy verbatim from the
    // Opportunity-shaped value in r[4].
    Map<String, String> assetTypeToProperty = new Map<String, String>{
        'Retail Strip' => 'Retail', 'Office' => 'Office', 'Industrial' => 'Industrial',
        'Land' => 'Land', 'Multifamily' => 'Multifamily', 'Mixed-Use' => 'Mixed-Use',
        'Medical Office' => 'Medical Office'
    };
    // Opportunity.Asset_Type__c has only 6 values and no medical-specific one.
    Map<String, String> assetTypeToOpportunity = new Map<String, String>{
        'Retail Strip' => 'Retail Strip', 'Office' => 'Office', 'Industrial' => 'Industrial',
        'Land' => 'Land', 'Multifamily' => 'Multifamily', 'Mixed-Use' => 'Mixed-Use',
        'Medical Office' => 'Office'
    };

    List<Property__c> props = new List<Property__c>();
    for (List<Object> r : rows) {
        props.add(new Property__c(
            Name = (String) r[0], City__c = (String) r[1], Address__c = (String) r[2] + ', ' + (String) r[1] + ', TX',
            State__c = 'TX', Zip__c = (String) r[3], Asset_Type__c = assetTypeToProperty.get((String) r[4]),
            Asking_Price__c = r[7] == null ? null : (Decimal) (Integer) r[7]
        ));
    }
    insert props;

    List<Opportunity> opps = new List<Opportunity>();
    Integer i = 0;
    for (List<Object> r : rows) {
        String brokerFirm = firms[Math.mod(i, firms.size())];
        Opportunity o = new Opportunity(
            Name = (String) r[0],
            RecordTypeId = ((String) r[5] == 'Land') ? landRT : retailRT,
            StageName = (String) r[6],
            CloseDate = ((String) r[6] == 'Dead/Pass') ? Date.today().addDays(-5) : Date.today().addDays(45 + Math.mod(i, 60)),
            Property__c = props[i].Id,
            AccountId = acctByName.get(brokerFirm),
            Asset_Type__c = assetTypeToOpportunity.get((String) r[4]),
            Deal_Type__c = (String) r[5],
            Asking_Price__c = r[7] == null ? null : (Decimal) (Integer) r[7],
            My_Price__c = r[8] == null ? null : (Decimal) (Integer) r[8],
            My_Cap_Rate__c = r[9] == null ? null : (Decimal) r[9],
            Market_Cap_Rate__c = r[10] == null ? null : (Decimal) r[10],
            Deal_Status__c = (String) r[11],
            Deal_Category__c = (String) r[12],
            Broker_First_Seen__c = Date.today().addDays(-(Integer) r[13]),
            LeadSource = 'Email-to-Lead'
        );
        if (r[14] != null) { o.Rejection_Reason__c = (String) r[14]; }
        if ((String) r[6] == 'Closed Won') { o.Contract_Signed__c = true; }
        if ((Boolean) r[15]) {
            o.Sale_Process__c = 'Call for Offers';
            o.Offer_Due_Date__c = Date.today().addDays(21 + Math.mod(i, 21));
            o.Listing_Broker_Name__c = 'Derek Simmons';
            o.Listing_Broker_Email__c = 'derek.simmons@colliers.com';
            o.Guidance_Cap_Rate__c = r[10] == null ? 7.0 : (Decimal) r[10];
        }
        opps.add(o);
        i++;
    }
    insert opps;

    System.debug('Inserted ' + props.size() + ' Properties and ' + opps.size() + ' volume Opportunities.');
}
