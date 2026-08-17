// Seed sample Placer.ai / CoStar market data onto Property__c records — usman-dpeg
// Fill-blanks-only. Deterministic (index-derived, NOT Math.random). No URL/Last-Synced writes.
// Approved by user 2026-08-17.

List<Property__c> props = [
    SELECT Id, Name,
        Placer_State_Rank__c, Placer_State_Percentile__c, Placer_MSA_Rank__c, Placer_National_Rank__c,
        Monthly_Visits__c, CoStar_Pct_Leased__c, CoStar_Location_Score__c,
        Market_Rent_PSF__c, CoStar_Asking_Rent_PSF__c, CoStar_Exit_Cap_Rate__c,
        Placer_Data_Source__c, CoStar_Data_Source__c, Placer_Fetch_Status__c, CoStar_Fetch_Status__c,
        Placer_URL__c, CoStar_URL__c, Placer_Last_Synced_DateTime__c, CoStar_Last_Synced_DateTime__c
    FROM Property__c
    ORDER BY Id
];

System.debug('TOTAL_PROPERTIES=' + props.size());

Map<String, Integer> writeCounts = new Map<String, Integer>();
Map<String, Integer> skipCounts = new Map<String, Integer>();
List<String> trackedFields = new List<String>{
    'Placer_State_Rank__c','Placer_State_Percentile__c','Placer_MSA_Rank__c','Placer_National_Rank__c',
    'Monthly_Visits__c','CoStar_Pct_Leased__c','CoStar_Location_Score__c',
    'Market_Rent_PSF__c','CoStar_Asking_Rent_PSF__c','CoStar_Exit_Cap_Rate__c',
    'Placer_Data_Source__c','CoStar_Data_Source__c','Placer_Fetch_Status__c','CoStar_Fetch_Status__c'
};
for (String fn : trackedFields) {
    writeCounts.put(fn, 0);
    skipCounts.put(fn, 0);
}

List<Property__c> toUpdate = new List<Property__c>();
Integer idx = 0;

for (Property__c p : props) {
    Integer i = idx;

    // ---- deterministic derived values (index-seeded, reproducible) ----
    Integer placerStateRank = 1 + Math.mod(i * 37, 250);
    Decimal placerStatePercentile = (50.00 + (Math.mod(i * 107, 4990) / 100.0)).setScale(2);
    Integer placerMsaRank = 1 + Math.mod(i * 13, 80);
    Integer placerNationalRank = 100 + Math.mod(i * 191, 8900);
    Integer monthlyVisits = 40000 + Math.mod(i * 17903, 860000);
    Decimal costarPctLeased = (78.00 + (Math.mod(i * 83, 2050) / 100.0)).setScale(2);
    Decimal costarLocationScore = (6.5 + (Math.mod(i * 7, 31) / 10.0)).setScale(1);
    Decimal marketRentPsf = (18.00 + (Math.mod(i * 97, 2800) / 100.0)).setScale(2);
    Decimal costarExitCapRate = (5.25 + (Math.mod(i * 59, 250) / 100.0)).setScale(2);
    Decimal askingPremium = (2.00 + (Math.mod(i, 5) * 0.50)).setScale(2);

    // Asking must sit above whatever this record's market rent actually is/will-be —
    // use existing value if already populated (fill-blanks-only means we won't touch it),
    // otherwise use the value we are about to write.
    Decimal effectiveMarketRent = (p.Market_Rent_PSF__c != null) ? p.Market_Rent_PSF__c : marketRentPsf;
    Decimal costarAskingRentPsf = (effectiveMarketRent + askingPremium).setScale(2);

    Boolean changed = false;
    Property__c upd = new Property__c(Id = p.Id);

    // Dry-run print for the first 3 records only — BEFORE any DML statement runs.
    Boolean printThis = (i < 3);
    if (printThis) {
        System.debug('DRYRUN_RECORD idx=' + i + ' Id=' + p.Id + ' Name=' + p.Name);
    }

    if (p.Placer_State_Rank__c == null) {
        upd.Placer_State_Rank__c = placerStateRank; changed = true;
        writeCounts.put('Placer_State_Rank__c', writeCounts.get('Placer_State_Rank__c') + 1);
        if (printThis) System.debug('  Placer_State_Rank__c -> WRITE ' + placerStateRank);
    } else {
        skipCounts.put('Placer_State_Rank__c', skipCounts.get('Placer_State_Rank__c') + 1);
        if (printThis) System.debug('  Placer_State_Rank__c -> SKIP (already=' + p.Placer_State_Rank__c + ')');
    }

    if (p.Placer_State_Percentile__c == null) {
        upd.Placer_State_Percentile__c = placerStatePercentile; changed = true;
        writeCounts.put('Placer_State_Percentile__c', writeCounts.get('Placer_State_Percentile__c') + 1);
        if (printThis) System.debug('  Placer_State_Percentile__c -> WRITE ' + placerStatePercentile);
    } else {
        skipCounts.put('Placer_State_Percentile__c', skipCounts.get('Placer_State_Percentile__c') + 1);
        if (printThis) System.debug('  Placer_State_Percentile__c -> SKIP (already=' + p.Placer_State_Percentile__c + ')');
    }

    if (p.Placer_MSA_Rank__c == null) {
        upd.Placer_MSA_Rank__c = placerMsaRank; changed = true;
        writeCounts.put('Placer_MSA_Rank__c', writeCounts.get('Placer_MSA_Rank__c') + 1);
        if (printThis) System.debug('  Placer_MSA_Rank__c -> WRITE ' + placerMsaRank);
    } else {
        skipCounts.put('Placer_MSA_Rank__c', skipCounts.get('Placer_MSA_Rank__c') + 1);
        if (printThis) System.debug('  Placer_MSA_Rank__c -> SKIP (already=' + p.Placer_MSA_Rank__c + ')');
    }

    if (p.Placer_National_Rank__c == null) {
        upd.Placer_National_Rank__c = placerNationalRank; changed = true;
        writeCounts.put('Placer_National_Rank__c', writeCounts.get('Placer_National_Rank__c') + 1);
        if (printThis) System.debug('  Placer_National_Rank__c -> WRITE ' + placerNationalRank);
    } else {
        skipCounts.put('Placer_National_Rank__c', skipCounts.get('Placer_National_Rank__c') + 1);
        if (printThis) System.debug('  Placer_National_Rank__c -> SKIP (already=' + p.Placer_National_Rank__c + ')');
    }

    if (p.Monthly_Visits__c == null) {
        upd.Monthly_Visits__c = monthlyVisits; changed = true;
        writeCounts.put('Monthly_Visits__c', writeCounts.get('Monthly_Visits__c') + 1);
        if (printThis) System.debug('  Monthly_Visits__c -> WRITE ' + monthlyVisits);
    } else {
        skipCounts.put('Monthly_Visits__c', skipCounts.get('Monthly_Visits__c') + 1);
        if (printThis) System.debug('  Monthly_Visits__c -> SKIP (already=' + p.Monthly_Visits__c + ')');
    }

    if (p.CoStar_Pct_Leased__c == null) {
        upd.CoStar_Pct_Leased__c = costarPctLeased; changed = true;
        writeCounts.put('CoStar_Pct_Leased__c', writeCounts.get('CoStar_Pct_Leased__c') + 1);
        if (printThis) System.debug('  CoStar_Pct_Leased__c -> WRITE ' + costarPctLeased);
    } else {
        skipCounts.put('CoStar_Pct_Leased__c', skipCounts.get('CoStar_Pct_Leased__c') + 1);
        if (printThis) System.debug('  CoStar_Pct_Leased__c -> SKIP (already=' + p.CoStar_Pct_Leased__c + ')');
    }

    if (p.CoStar_Location_Score__c == null) {
        upd.CoStar_Location_Score__c = costarLocationScore; changed = true;
        writeCounts.put('CoStar_Location_Score__c', writeCounts.get('CoStar_Location_Score__c') + 1);
        if (printThis) System.debug('  CoStar_Location_Score__c -> WRITE ' + costarLocationScore);
    } else {
        skipCounts.put('CoStar_Location_Score__c', skipCounts.get('CoStar_Location_Score__c') + 1);
        if (printThis) System.debug('  CoStar_Location_Score__c -> SKIP (already=' + p.CoStar_Location_Score__c + ')');
    }

    if (p.Market_Rent_PSF__c == null) {
        upd.Market_Rent_PSF__c = marketRentPsf; changed = true;
        writeCounts.put('Market_Rent_PSF__c', writeCounts.get('Market_Rent_PSF__c') + 1);
        if (printThis) System.debug('  Market_Rent_PSF__c -> WRITE ' + marketRentPsf);
    } else {
        skipCounts.put('Market_Rent_PSF__c', skipCounts.get('Market_Rent_PSF__c') + 1);
        if (printThis) System.debug('  Market_Rent_PSF__c -> SKIP (already=' + p.Market_Rent_PSF__c + ')');
    }

    if (p.CoStar_Asking_Rent_PSF__c == null) {
        upd.CoStar_Asking_Rent_PSF__c = costarAskingRentPsf; changed = true;
        writeCounts.put('CoStar_Asking_Rent_PSF__c', writeCounts.get('CoStar_Asking_Rent_PSF__c') + 1);
        if (printThis) System.debug('  CoStar_Asking_Rent_PSF__c -> WRITE ' + costarAskingRentPsf + ' (market=' + effectiveMarketRent + ')');
    } else {
        skipCounts.put('CoStar_Asking_Rent_PSF__c', skipCounts.get('CoStar_Asking_Rent_PSF__c') + 1);
        if (printThis) System.debug('  CoStar_Asking_Rent_PSF__c -> SKIP (already=' + p.CoStar_Asking_Rent_PSF__c + ')');
    }

    if (p.CoStar_Exit_Cap_Rate__c == null) {
        upd.CoStar_Exit_Cap_Rate__c = costarExitCapRate; changed = true;
        writeCounts.put('CoStar_Exit_Cap_Rate__c', writeCounts.get('CoStar_Exit_Cap_Rate__c') + 1);
        if (printThis) System.debug('  CoStar_Exit_Cap_Rate__c -> WRITE ' + costarExitCapRate);
    } else {
        skipCounts.put('CoStar_Exit_Cap_Rate__c', skipCounts.get('CoStar_Exit_Cap_Rate__c') + 1);
        if (printThis) System.debug('  CoStar_Exit_Cap_Rate__c -> SKIP (already=' + p.CoStar_Exit_Cap_Rate__c + ')');
    }

    if (p.Placer_Data_Source__c == null) {
        upd.Placer_Data_Source__c = 'Manual'; changed = true;
        writeCounts.put('Placer_Data_Source__c', writeCounts.get('Placer_Data_Source__c') + 1);
        if (printThis) System.debug('  Placer_Data_Source__c -> WRITE Manual');
    } else {
        skipCounts.put('Placer_Data_Source__c', skipCounts.get('Placer_Data_Source__c') + 1);
        if (printThis) System.debug('  Placer_Data_Source__c -> SKIP (already=' + p.Placer_Data_Source__c + ')');
    }

    if (p.CoStar_Data_Source__c == null) {
        upd.CoStar_Data_Source__c = 'Manual'; changed = true;
        writeCounts.put('CoStar_Data_Source__c', writeCounts.get('CoStar_Data_Source__c') + 1);
        if (printThis) System.debug('  CoStar_Data_Source__c -> WRITE Manual');
    } else {
        skipCounts.put('CoStar_Data_Source__c', skipCounts.get('CoStar_Data_Source__c') + 1);
        if (printThis) System.debug('  CoStar_Data_Source__c -> SKIP (already=' + p.CoStar_Data_Source__c + ')');
    }

    if (p.Placer_Fetch_Status__c == null) {
        upd.Placer_Fetch_Status__c = 'Not Synced'; changed = true;
        writeCounts.put('Placer_Fetch_Status__c', writeCounts.get('Placer_Fetch_Status__c') + 1);
        if (printThis) System.debug('  Placer_Fetch_Status__c -> WRITE Not Synced');
    } else {
        skipCounts.put('Placer_Fetch_Status__c', skipCounts.get('Placer_Fetch_Status__c') + 1);
        if (printThis) System.debug('  Placer_Fetch_Status__c -> SKIP (already=' + p.Placer_Fetch_Status__c + ')');
    }

    if (p.CoStar_Fetch_Status__c == null) {
        upd.CoStar_Fetch_Status__c = 'Not Synced'; changed = true;
        writeCounts.put('CoStar_Fetch_Status__c', writeCounts.get('CoStar_Fetch_Status__c') + 1);
        if (printThis) System.debug('  CoStar_Fetch_Status__c -> WRITE Not Synced');
    } else {
        skipCounts.put('CoStar_Fetch_Status__c', skipCounts.get('CoStar_Fetch_Status__c') + 1);
        if (printThis) System.debug('  CoStar_Fetch_Status__c -> SKIP (already=' + p.CoStar_Fetch_Status__c + ')');
    }

    if (printThis) {
        System.debug('  [untouched, never written by this script] Placer_URL__c=' + p.Placer_URL__c
            + ' CoStar_URL__c=' + p.CoStar_URL__c
            + ' Placer_Last_Synced_DateTime__c=' + p.Placer_Last_Synced_DateTime__c
            + ' CoStar_Last_Synced_DateTime__c=' + p.CoStar_Last_Synced_DateTime__c);
    }

    if (changed) {
        toUpdate.add(upd);
    }

    idx++;
}

System.debug('SKIP_SUMMARY_START');
for (String fn : trackedFields) {
    System.debug('  FIELD=' + fn + ' WRITE_COUNT=' + writeCounts.get(fn) + ' SKIP_COUNT=' + skipCounts.get(fn));
}
System.debug('SKIP_SUMMARY_END');

System.debug('RECORDS_TO_UPDATE=' + toUpdate.size());

// ---- real update ----
List<Database.SaveResult> results = Database.update(toUpdate, false);

Integer successCount = 0;
Integer failCount = 0;
for (Integer r = 0; r < results.size(); r++) {
    Database.SaveResult sr = results[r];
    if (sr.isSuccess()) {
        successCount++;
    } else {
        failCount++;
        for (Database.Error err : sr.getErrors()) {
            System.debug('UPDATE_FAILURE recordId=' + toUpdate[r].Id
                + ' statusCode=' + err.getStatusCode()
                + ' message=' + err.getMessage()
                + ' fields=' + err.getFields());
        }
    }
}
System.debug('UPDATE_RESULT successCount=' + successCount + ' failCount=' + failCount + ' totalAttempted=' + toUpdate.size());

// ---- verification pass: re-query a sample of 3 records ----
List<Property__c> verify = [
    SELECT Id, Name,
        Placer_State_Rank__c, Placer_State_Percentile__c, Placer_MSA_Rank__c, Placer_National_Rank__c,
        Monthly_Visits__c, CoStar_Pct_Leased__c, CoStar_Location_Score__c,
        Market_Rent_PSF__c, CoStar_Asking_Rent_PSF__c, CoStar_Exit_Cap_Rate__c,
        Placer_Data_Source__c, CoStar_Data_Source__c, Placer_Fetch_Status__c, CoStar_Fetch_Status__c,
        Placer_URL__c, CoStar_URL__c, Placer_Last_Synced_DateTime__c, CoStar_Last_Synced_DateTime__c
    FROM Property__c
    ORDER BY Id
    LIMIT 3
];

for (Property__c v : verify) {
    System.debug('VERIFY_RECORD Id=' + v.Id + ' Name=' + v.Name
        + ' Placer_State_Rank__c=' + v.Placer_State_Rank__c
        + ' Placer_State_Percentile__c=' + v.Placer_State_Percentile__c
        + ' Placer_MSA_Rank__c=' + v.Placer_MSA_Rank__c
        + ' Placer_National_Rank__c=' + v.Placer_National_Rank__c
        + ' Monthly_Visits__c=' + v.Monthly_Visits__c
        + ' CoStar_Pct_Leased__c=' + v.CoStar_Pct_Leased__c
        + ' CoStar_Location_Score__c=' + v.CoStar_Location_Score__c
        + ' Market_Rent_PSF__c=' + v.Market_Rent_PSF__c
        + ' CoStar_Asking_Rent_PSF__c=' + v.CoStar_Asking_Rent_PSF__c
        + ' CoStar_Exit_Cap_Rate__c=' + v.CoStar_Exit_Cap_Rate__c
        + ' Placer_Data_Source__c=' + v.Placer_Data_Source__c
        + ' CoStar_Data_Source__c=' + v.CoStar_Data_Source__c
        + ' Placer_Fetch_Status__c=' + v.Placer_Fetch_Status__c
        + ' CoStar_Fetch_Status__c=' + v.CoStar_Fetch_Status__c
        + ' Placer_URL__c=' + v.Placer_URL__c
        + ' CoStar_URL__c=' + v.CoStar_URL__c
        + ' Placer_Last_Synced_DateTime__c=' + v.Placer_Last_Synced_DateTime__c
        + ' CoStar_Last_Synced_DateTime__c=' + v.CoStar_Last_Synced_DateTime__c);
}
