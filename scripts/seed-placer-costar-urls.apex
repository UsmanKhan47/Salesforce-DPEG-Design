// Seed placeholder Placer.ai / CoStar URLs onto Property__c records — usman-dpeg
// Fill-blanks-only. Deterministic (Name-slug + record Id, NOT Math.random). No touch to
// Last-Synced-DateTime / Fetch-Status / Data-Source fields — those stay exactly as the prior
// market-data seed (scripts/seed-market-data-placer-costar.apex) left them.
// Explicitly requested by the user 2026-08-17: dummy/placeholder URLs are wanted here, reversing
// that earlier seed's deliberate decision to leave these two fields null.

// ---- helpers -------------------------------------------------------------------------------

// URL field max length in Salesforce is a fixed 255 chars. Longest prefix used below is the
// CoStar one (46 chars); reserve headroom for "-" + an 18-char record Id (1 + 18 = 19) and cap
// the slug well under the remaining budget (255 - 46 - 19 = 190) for a comfortable margin.
Integer MAX_SLUG_LEN = 150;

String placerUrl;
String costarUrl;

List<Property__c> props = [
    SELECT Id, Name, Placer_URL__c, CoStar_URL__c,
        Placer_Last_Synced_DateTime__c, CoStar_Last_Synced_DateTime__c,
        Placer_Fetch_Status__c, CoStar_Fetch_Status__c
    FROM Property__c
    ORDER BY Id
];

System.debug('TOTAL_PROPERTIES=' + props.size());

Integer placerWrite = 0, placerSkip = 0, costarWrite = 0, costarSkip = 0;
List<Property__c> toUpdate = new List<Property__c>();
Set<String> seenUrls = new Set<String>(); // uniqueness sanity check across the whole run

Integer idx = 0;
for (Property__c p : props) {
    Boolean printThis = (idx < 3);

    // --- deterministic slug from Name ---
    String raw = (p.Name == null) ? '' : p.Name.toLowerCase();
    String slug = raw.replaceAll('[^a-z0-9]+', '-');
    slug = slug.replaceAll('-+', '-');
    slug = slug.replaceAll('^-|-$', '');
    if (slug.length() > MAX_SLUG_LEN) {
        slug = slug.substring(0, MAX_SLUG_LEN);
        slug = slug.replaceAll('-+$', '');
    }
    if (String.isBlank(slug)) {
        slug = 'property';
    }

    // Record Id is the uniqueness guarantee (unique per row by construction, so two properties
    // can never collide even if their Names slug identically).
    String idTail = String.valueOf(p.Id).toLowerCase();

    placerUrl = 'https://app.placer.ai/property/demo-sample/' + slug + '-' + idTail;
    costarUrl = 'https://www.costar.com/property/demo-sample/' + slug + '-' + idTail;

    Boolean changed = false;
    Property__c upd = new Property__c(Id = p.Id);

    if (printThis) {
        System.debug('DRYRUN_RECORD idx=' + idx + ' Id=' + p.Id + ' Name=' + p.Name);
    }

    if (p.Placer_URL__c == null) {
        upd.Placer_URL__c = placerUrl;
        changed = true;
        placerWrite++;
        if (printThis) System.debug('  Placer_URL__c -> WRITE ' + placerUrl + ' (len=' + placerUrl.length() + ')');
    } else {
        placerSkip++;
        if (printThis) System.debug('  Placer_URL__c -> SKIP (already=' + p.Placer_URL__c + ')');
    }

    if (p.CoStar_URL__c == null) {
        upd.CoStar_URL__c = costarUrl;
        changed = true;
        costarWrite++;
        if (printThis) System.debug('  CoStar_URL__c -> WRITE ' + costarUrl + ' (len=' + costarUrl.length() + ')');
    } else {
        costarSkip++;
        if (printThis) System.debug('  CoStar_URL__c -> SKIP (already=' + p.CoStar_URL__c + ')');
    }

    if (printThis) {
        System.debug('  [untouched, never written by this script] Placer_Last_Synced_DateTime__c=' + p.Placer_Last_Synced_DateTime__c
            + ' CoStar_Last_Synced_DateTime__c=' + p.CoStar_Last_Synced_DateTime__c
            + ' Placer_Fetch_Status__c=' + p.Placer_Fetch_Status__c
            + ' CoStar_Fetch_Status__c=' + p.CoStar_Fetch_Status__c);
    }

    // Uniqueness sanity check (should never trip — Id-suffixed by construction)
    if (upd.Placer_URL__c != null) {
        if (seenUrls.contains(upd.Placer_URL__c)) {
            System.debug('DUPLICATE_URL_DETECTED (placer) ' + upd.Placer_URL__c);
        }
        seenUrls.add(upd.Placer_URL__c);
    }
    if (upd.CoStar_URL__c != null) {
        if (seenUrls.contains(upd.CoStar_URL__c)) {
            System.debug('DUPLICATE_URL_DETECTED (costar) ' + upd.CoStar_URL__c);
        }
        seenUrls.add(upd.CoStar_URL__c);
    }

    if (changed) {
        toUpdate.add(upd);
    }

    idx++;
}

System.debug('WRITE_SKIP_SUMMARY Placer_URL__c write=' + placerWrite + ' skip=' + placerSkip
    + ' | CoStar_URL__c write=' + costarWrite + ' skip=' + costarSkip);
System.debug('RECORDS_TO_UPDATE=' + toUpdate.size());

// ---- real update (partial-success: one bad row must not roll back the batch) ----
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

// ---- verification pass: re-query a sample of 3 records, confirming the untouched fields too ----
List<Property__c> verify = [
    SELECT Id, Name, Placer_URL__c, CoStar_URL__c,
        Placer_Last_Synced_DateTime__c, CoStar_Last_Synced_DateTime__c,
        Placer_Fetch_Status__c, CoStar_Fetch_Status__c
    FROM Property__c
    ORDER BY Id
    LIMIT 3
];

for (Property__c v : verify) {
    System.debug('VERIFY_RECORD Id=' + v.Id + ' Name=' + v.Name
        + ' Placer_URL__c=' + v.Placer_URL__c
        + ' CoStar_URL__c=' + v.CoStar_URL__c
        + ' Placer_Last_Synced_DateTime__c=' + v.Placer_Last_Synced_DateTime__c
        + ' CoStar_Last_Synced_DateTime__c=' + v.CoStar_Last_Synced_DateTime__c
        + ' Placer_Fetch_Status__c=' + v.Placer_Fetch_Status__c
        + ' CoStar_Fetch_Status__c=' + v.CoStar_Fetch_Status__c);
}
