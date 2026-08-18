/**
 * Phase B3 of the Property Package -> Portfolio Deal rename program.
 * See agent-output/design-requirements-portfolio-deal-rename.md §5 Phase B3.
 *
 * WHAT IT DOES
 *   1. Copies every Property_Package__c row into a matching Portfolio_Deal__c row
 *      (Name + all six custom fields, verbatim).
 *   2. Backfills the three NEW Portfolio_Deal__c lookups on Lead / Opportunity /
 *      Property__c from an in-memory old-Id -> new-Id map.
 *   3. Verifies the result and THROWS if anything is incomplete or mislinked.
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 *   🔴 It NEVER reads, clears, or writes the OLD Property_Package__c lookups. Both the
 *      old and the new lookup must coexist after B3 - retiring the old ones is B5, and
 *      the old values ARE the mapping this backfill depends on (design §3.2: deleting
 *      the old object early nulls them via SetNull and destroys the mapping).
 *      Updates are built as fresh `new Lead(Id = ..., Portfolio_Deal__c = ...)` stubs
 *      rather than by mutating the queried rows, so no other field can be written back.
 *
 * Run:  sf apex run --file scripts/migrate-portfolio-deal-b3.apex --target-org usman-dpeg
 * Then read the VERIFY block at the bottom of the debug log. The final line must read
 * "B3 VERDICT: COMPLETE". Any other verdict means DO NOT PROCEED TO B4.
 *
 * ---------------------------------------------------------------------------------
 * WHY THIS IS NOT AN UPSERT, AND WHY THE MATCH KEY IS COMPOSITE
 * ---------------------------------------------------------------------------------
 * Source_Staging_Id__c is a plain Text(18) field on BOTH objects - not unique, not an
 * external Id (verified in the B1/B2 metadata) - so `upsert` is unavailable and the
 * old->new mapping has to be held in memory for the life of this one transaction.
 *
 * 🔴 AND IT IS NOT A USABLE KEY ANYWAY. Design §3.2 said to key the migration on
 * Source_Staging_Id__c "confirm it is populated on 100% of live rows before relying on
 * it". Measured live 2026-08-18: it is populated on ONE of the TWO rows. Package
 * a0diw000000dfT9AAI (Grant Ashworth / JLL) has it NULL. So the design's preferred key
 * is dead on arrival and no fallback Legacy_Id__c field was ever added.
 *
 * This script therefore matches on a COMPOSITE natural key of all five stable
 * attributes (Name + Source_Staging_Id + Received_DateTime + Property_Count +
 * Broker_Email). That key is only needed for RE-RUN safety - on a clean first run the
 * destination is empty and every row is simply inserted. If the composite key is ever
 * ambiguous (two source rows sharing one key) the script ABORTS rather than guessing
 * which new row a Lead should point at.
 *
 * ---------------------------------------------------------------------------------
 * IDEMPOTENCY / RE-RUNNABILITY
 * ---------------------------------------------------------------------------------
 * Safe to re-run. Rows already migrated are matched by composite key and REUSED (not
 * duplicated); lookups already populated are excluded by `AND Portfolio_Deal__c = null`,
 * exactly as the backfill-unit-label.apex precedent does. A re-run after a fully
 * successful run updates zero rows and still prints the VERIFY block.
 *
 * ROLLBACK: delete the created Portfolio_Deal__c rows. All three new lookups are
 * deleteConstraint=SetNull, so deleting the parents automatically clears every lookup
 * this script set, returning the org to its pre-B3 state in one step. The OLD lookups
 * are untouched throughout and so cannot be lost by a rollback.
 *
 * ---------------------------------------------------------------------------------
 * SYSTEM MODE IS DELIBERATE (no WITH USER_MODE)
 * ---------------------------------------------------------------------------------
 * ARCHITECTURE.md §2 mandates WITH USER_MODE for SELECTOR classes in force-app. This is
 * a one-off script, matching the house precedent (backfill-unit-label.apex,
 * migrate-loi-psa-stages.apex), and it runs in system mode ON PURPOSE: a data migration
 * that copies only the subset of rows and fields the running operator happens to hold
 * FLS on is a SILENTLY PARTIAL migration, which is the single worst outcome here.
 * Object/field/record access for the intended runner was verified independently as a
 * pre-flight (create+edit on Portfolio_Deal__c and all six fields via
 * DPEG_Acquisition_Edit + Broker_Protection_Access; edit on Lead.Portfolio_Deal__c;
 * HasEditAccess=true on all five target Leads).
 */

// ============================================================ 0. PRE-FLIGHT
// Name is a TEXT name field on both objects (verified in the object metadata), NOT an
// auto-number. That makes Name a REQUIRED, WRITABLE field: it must be copied explicitly
// or the insert fails with REQUIRED_FIELD_MISSING. This is the single easiest thing to
// get wrong here, because on an auto-number object copying Name would instead be an error.
final String DELIM = '~|~';

List<Property_Package__c> oldRows = [
    SELECT Id, Name, Property_Count__c, Broker_Email__c, Broker_Name__c,
           Source_Staging_Id__c, Received_DateTime__c, Routed_Outcomes__c
    FROM Property_Package__c
    ORDER BY CreatedDate ASC
];
System.debug('Property_Package__c rows found: ' + oldRows.size());

if (oldRows.isEmpty()) {
    throw new IllegalArgumentException(
        'ABORT: zero Property_Package__c rows found. Expected at least 1. ' +
        'Either the object is already retired or this is the wrong org.');
}

// Composite key builder - shared by both sides of the match so the two can never drift.
Map<String, Property_Package__c> oldByKey = new Map<String, Property_Package__c>();
for (Property_Package__c p : oldRows) {
    String key = String.join(new List<String>{
        String.valueOf(p.Name),
        String.valueOf(p.Source_Staging_Id__c),
        String.valueOf(p.Received_DateTime__c),
        String.valueOf(p.Property_Count__c),
        String.valueOf(p.Broker_Email__c)
    }, DELIM);

    // Ambiguity is unresolvable, not recoverable: if two source rows are indistinguishable
    // we cannot know which new row a given Lead belongs to. Stop before writing anything.
    if (oldByKey.containsKey(key)) {
        throw new IllegalArgumentException(
            'ABORT: two Property_Package__c rows share one composite key, so the old->new ' +
            'mapping is ambiguous and no safe backfill exists. Add a Legacy_Id__c field ' +
            'to Portfolio_Deal__c and key on that instead. Colliding Ids: ' +
            oldByKey.get(key).Id + ' and ' + p.Id + ' | key=' + key);
    }
    oldByKey.put(key, p);
}

// ============================================================ 1. COPY THE RECORDS
// Re-run support: adopt any Portfolio_Deal__c row that already matches a source row.
Map<String, Id> existingNewByKey = new Map<String, Id>();
for (Portfolio_Deal__c d : [
    SELECT Id, Name, Property_Count__c, Broker_Email__c, Broker_Name__c,
           Source_Staging_Id__c, Received_DateTime__c
    FROM Portfolio_Deal__c
]) {
    existingNewByKey.put(String.join(new List<String>{
        String.valueOf(d.Name),
        String.valueOf(d.Source_Staging_Id__c),
        String.valueOf(d.Received_DateTime__c),
        String.valueOf(d.Property_Count__c),
        String.valueOf(d.Broker_Email__c)
    }, DELIM), d.Id);
}
System.debug('Portfolio_Deal__c rows already present: ' + existingNewByKey.size());

Map<Id, Id> oldToNew = new Map<Id, Id>();          // the mapping everything below depends on
List<Portfolio_Deal__c> toInsert = new List<Portfolio_Deal__c>();
List<Id> insertSourceIds = new List<Id>();          // parallel to toInsert, to rebuild the map

for (String key : oldByKey.keySet()) {
    Property_Package__c p = oldByKey.get(key);
    if (existingNewByKey.containsKey(key)) {
        oldToNew.put(p.Id, existingNewByKey.get(key));   // already migrated - reuse, do not duplicate
        continue;
    }
    toInsert.add(new Portfolio_Deal__c(
        Name                = p.Name,                    // REQUIRED - Text name field, see PRE-FLIGHT
        Property_Count__c   = p.Property_Count__c,
        Broker_Email__c     = p.Broker_Email__c,
        Broker_Name__c      = p.Broker_Name__c,
        Source_Staging_Id__c= p.Source_Staging_Id__c,    // copied verbatim, nulls included
        Received_DateTime__c= p.Received_DateTime__c,
        Routed_Outcomes__c  = p.Routed_Outcomes__c
    ));
    insertSourceIds.add(p.Id);
}

if (!toInsert.isEmpty()) {
    // allOrNone = true: a PARTIAL insert would produce a half-built map and a half-linked
    // org, which is far worse to unpick than a clean failure.
    List<Database.SaveResult> srs = Database.insert(toInsert, true);
    for (Integer i = 0; i < srs.size(); i++) {
        if (!srs[i].isSuccess()) {
            throw new IllegalArgumentException(
                'ABORT: Portfolio_Deal__c insert failed for source ' + insertSourceIds[i] +
                ': ' + srs[i].getErrors()[0].getMessage());
        }
        oldToNew.put(insertSourceIds[i], srs[i].getId());
    }
}
System.debug('Portfolio_Deal__c inserted this run: ' + toInsert.size());
System.debug('old -> new map size: ' + oldToNew.size() + ' (must equal source rows: ' + oldRows.size() + ')');

if (oldToNew.size() != oldRows.size()) {
    throw new IllegalArgumentException(
        'ABORT: mapping is incomplete (' + oldToNew.size() + ' of ' + oldRows.size() +
        '). Refusing to backfill lookups from a partial map.');
}

// ============================================================ 2. BACKFILL THE LOOKUPS
// `AND Portfolio_Deal__c = null` is what makes each of these re-runnable, and is also
// what guarantees an already-correct row is never rewritten.
Integer unmapped = 0;

// -------- Lead
List<Lead> leadUpdates = new List<Lead>();
for (Lead l : [SELECT Id, Property_Package__c FROM Lead
               WHERE Property_Package__c != null AND Portfolio_Deal__c = null]) {
    if (!oldToNew.containsKey(l.Property_Package__c)) { unmapped++; continue; }
    leadUpdates.add(new Lead(Id = l.Id, Portfolio_Deal__c = oldToNew.get(l.Property_Package__c)));
}
if (!leadUpdates.isEmpty()) {
    for (Database.SaveResult sr : Database.update(leadUpdates, true)) {
        if (!sr.isSuccess()) {
            throw new IllegalArgumentException('ABORT: Lead backfill failed: ' + sr.getErrors()[0].getMessage());
        }
    }
}
System.debug('Lead        lookups backfilled: ' + leadUpdates.size());

// -------- Opportunity  (measured 0 rows on 2026-08-18; handled generically in case that changed)
List<Opportunity> oppUpdates = new List<Opportunity>();
for (Opportunity o : [SELECT Id, Property_Package__c FROM Opportunity
                      WHERE Property_Package__c != null AND Portfolio_Deal__c = null]) {
    if (!oldToNew.containsKey(o.Property_Package__c)) { unmapped++; continue; }
    oppUpdates.add(new Opportunity(Id = o.Id, Portfolio_Deal__c = oldToNew.get(o.Property_Package__c)));
}
if (!oppUpdates.isEmpty()) {
    for (Database.SaveResult sr : Database.update(oppUpdates, true)) {
        if (!sr.isSuccess()) {
            throw new IllegalArgumentException('ABORT: Opportunity backfill failed: ' + sr.getErrors()[0].getMessage());
        }
    }
}
System.debug('Opportunity lookups backfilled: ' + oppUpdates.size());

// -------- Property__c  (measured 0 rows on 2026-08-18; handled generically in case that changed)
List<Property__c> propUpdates = new List<Property__c>();
for (Property__c pr : [SELECT Id, Property_Package__c FROM Property__c
                       WHERE Property_Package__c != null AND Portfolio_Deal__c = null]) {
    if (!oldToNew.containsKey(pr.Property_Package__c)) { unmapped++; continue; }
    propUpdates.add(new Property__c(Id = pr.Id, Portfolio_Deal__c = oldToNew.get(pr.Property_Package__c)));
}
if (!propUpdates.isEmpty()) {
    for (Database.SaveResult sr : Database.update(propUpdates, true)) {
        if (!sr.isSuccess()) {
            throw new IllegalArgumentException('ABORT: Property__c backfill failed: ' + sr.getErrors()[0].getMessage());
        }
    }
}
System.debug('Property__c lookups backfilled: ' + propUpdates.size());

// ================================================================ VERIFY
// Prove it, do not assume it. The row-count check alone is NOT sufficient - it cannot
// tell "every Lead got the RIGHT parent" from "every Lead got A parent". So the child
// checks traverse BOTH lookups from the SAME row and compare the two parents' field
// tuples. Note this deliberately does NOT lean on Source_Staging_Id__c alone: it is null
// on one of the two live packages (see the header), so a Source_Staging_Id__c-only
// comparison would "pass" by comparing null to null and prove nothing about that row.
System.debug('======================= VERIFY =======================');

Integer srcTotal = [SELECT COUNT() FROM Property_Package__c];
Integer dstTotal = [SELECT COUNT() FROM Portfolio_Deal__c];
System.debug('OBJECT COUNTS  Property_Package__c=' + srcTotal + '  Portfolio_Deal__c=' + dstTotal);

Integer mismatch = 0;
Integer matched  = 0;
Integer missing  = 0;

// -------- Lead
Integer leadRemaining = [SELECT COUNT() FROM Lead WHERE Property_Package__c != null AND Portfolio_Deal__c = null];
for (Lead l : [
    SELECT Id,
           Property_Package__r.Name, Property_Package__r.Source_Staging_Id__c,
           Property_Package__r.Received_DateTime__c, Property_Package__r.Property_Count__c,
           Property_Package__r.Broker_Email__c, Property_Package__r.Broker_Name__c,
           Portfolio_Deal__r.Name, Portfolio_Deal__r.Source_Staging_Id__c,
           Portfolio_Deal__r.Received_DateTime__c, Portfolio_Deal__r.Property_Count__c,
           Portfolio_Deal__r.Broker_Email__c, Portfolio_Deal__r.Broker_Name__c
    FROM Lead WHERE Property_Package__c != null
]) {
    if (l.Portfolio_Deal__c == null) { missing++; continue; }
    Boolean same =
        l.Property_Package__r.Name                 == l.Portfolio_Deal__r.Name &&
        l.Property_Package__r.Source_Staging_Id__c == l.Portfolio_Deal__r.Source_Staging_Id__c &&
        l.Property_Package__r.Received_DateTime__c == l.Portfolio_Deal__r.Received_DateTime__c &&
        l.Property_Package__r.Property_Count__c    == l.Portfolio_Deal__r.Property_Count__c &&
        l.Property_Package__r.Broker_Email__c      == l.Portfolio_Deal__r.Broker_Email__c &&
        l.Property_Package__r.Broker_Name__c       == l.Portfolio_Deal__r.Broker_Name__c;
    if (same) { matched++; }
    else {
        mismatch++;
        System.debug('🔴 MISLINKED Lead ' + l.Id +
                     ' old="' + l.Property_Package__r.Name + '" new="' + l.Portfolio_Deal__r.Name + '"');
    }
}
System.debug('Lead        linked-correctly=' + matched + '  mislinked=' + mismatch +
             '  still-null=' + missing + '  remaining(query)=' + leadRemaining);

// -------- Opportunity
Integer oppMismatch = 0, oppMatched = 0, oppMissing = 0;
Integer oppRemaining = [SELECT COUNT() FROM Opportunity WHERE Property_Package__c != null AND Portfolio_Deal__c = null];
for (Opportunity o : [
    SELECT Id, Property_Package__r.Name, Property_Package__r.Received_DateTime__c,
           Property_Package__r.Broker_Email__c,
           Portfolio_Deal__r.Name, Portfolio_Deal__r.Received_DateTime__c,
           Portfolio_Deal__r.Broker_Email__c
    FROM Opportunity WHERE Property_Package__c != null
]) {
    if (o.Portfolio_Deal__c == null) { oppMissing++; continue; }
    Boolean same = o.Property_Package__r.Name                 == o.Portfolio_Deal__r.Name &&
                   o.Property_Package__r.Received_DateTime__c == o.Portfolio_Deal__r.Received_DateTime__c &&
                   o.Property_Package__r.Broker_Email__c      == o.Portfolio_Deal__r.Broker_Email__c;
    if (same) { oppMatched++; } else { oppMismatch++; System.debug('🔴 MISLINKED Opportunity ' + o.Id); }
}
System.debug('Opportunity linked-correctly=' + oppMatched + '  mislinked=' + oppMismatch +
             '  still-null=' + oppMissing + '  remaining(query)=' + oppRemaining);

// -------- Property__c
Integer prMismatch = 0, prMatched = 0, prMissing = 0;
Integer prRemaining = [SELECT COUNT() FROM Property__c WHERE Property_Package__c != null AND Portfolio_Deal__c = null];
for (Property__c pr : [
    SELECT Id, Property_Package__r.Name, Property_Package__r.Received_DateTime__c,
           Property_Package__r.Broker_Email__c,
           Portfolio_Deal__r.Name, Portfolio_Deal__r.Received_DateTime__c,
           Portfolio_Deal__r.Broker_Email__c
    FROM Property__c WHERE Property_Package__c != null
]) {
    if (pr.Portfolio_Deal__c == null) { prMissing++; continue; }
    Boolean same = pr.Property_Package__r.Name                 == pr.Portfolio_Deal__r.Name &&
                   pr.Property_Package__r.Received_DateTime__c == pr.Portfolio_Deal__r.Received_DateTime__c &&
                   pr.Property_Package__r.Broker_Email__c      == pr.Portfolio_Deal__r.Broker_Email__c;
    if (same) { prMatched++; } else { prMismatch++; System.debug('🔴 MISLINKED Property__c ' + pr.Id); }
}
System.debug('Property__c linked-correctly=' + prMatched + '  mislinked=' + prMismatch +
             '  still-null=' + prMissing + '  remaining(query)=' + prRemaining);

if (unmapped > 0) {
    System.debug('⚠ ' + unmapped + ' child row(s) referenced a Property_Package__c created AFTER ' +
                 'this run started (Broker Protection is a live writer). Simply re-run the script.');
}

Boolean clean = (srcTotal == dstTotal)
             && (mismatch + oppMismatch + prMismatch == 0)
             && (missing + oppMissing + prMissing == 0)
             && (leadRemaining + oppRemaining + prRemaining == 0)
             && (unmapped == 0);

System.debug('B3 VERDICT: ' + (clean
    ? 'COMPLETE - counts match, every child links to the CORRECT new record, old lookups untouched'
    : 'INCOMPLETE - DO NOT PROCEED TO B4. Re-run, then investigate.'));

if (!clean) {
    // Fail loudly. A silent partial migration is how a rename program corrupts data.
    throw new IllegalArgumentException(
        'B3 migration incomplete: srcTotal=' + srcTotal + ' dstTotal=' + dstTotal +
        ' mislinked=' + (mismatch + oppMismatch + prMismatch) +
        ' stillNull=' + (missing + oppMissing + prMissing) +
        ' remaining=' + (leadRemaining + oppRemaining + prRemaining) +
        ' unmapped=' + unmapped);
}
