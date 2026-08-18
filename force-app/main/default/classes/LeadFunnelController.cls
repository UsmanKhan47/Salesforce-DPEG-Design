/**
 * Read-only data provider for the Lead Funnel Lightning page (Acquisitions).
 * Aggregates Leads by stage and intake channel and returns recent leads.
 *
 * All SOQL against Lead lives in LeadSelector per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md — this controller holds zero inline SOQL.
 *
 * Thin, read-only controller (P6 controller thinning — boundaries only, no DML to extract).
 * The single @AuraEnabled read maps any failure to a user-safe AuraHandledException at the
 * LWC boundary (ARCHITECTURE.md §5): platform detail goes to the debug log (admin-only) and
 * the user gets a fixed, generic message with no exception detail concatenated into it.
 */
public with sharing class LeadFunnelController {

    private static final List<String> STAGE_ORDER = new List<String>{
        'New', 'Under Review', 'Qualified', 'Converted', 'Disqualified'
    };
    private static final List<String> CHANNEL_ORDER = new List<String>{
        'Email-to-Lead', 'Broker Portal', 'Manual Entry'
    };
    // Broker protection window (days) measured from First Seen Date.
    private static final Integer BP_WINDOW_DAYS = 90;
    // Trailing window (days) for the recency-scoped Converted / Disqualified counts.
    private static final Integer OUTCOME_WINDOW_DAYS = 90;
    // Row cap for the recent-leads / review-queue list.
    private static final Integer RECENT_LIMIT = 50;
    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'The lead funnel could not be loaded. Refresh the page or contact your administrator.';

    @AuraEnabled(cacheable=true)
    public static FunnelData getFunnel() {
        try {
        FunnelData data = new FunnelData();

        // --- counts by stage ---
        Map<String, Integer> stageCounts = new Map<String, Integer>();
        for (String s : STAGE_ORDER) {
            stageCounts.put(s, 0);
        }
        for (AggregateResult ar : LeadSelector.countByStatus()) {
            String st = (String) ar.get('st');
            if (st != null && stageCounts.containsKey(st)) {
                stageCounts.put(st, (Integer) ar.get('c'));
            }
        }
        // Converted/Disqualified widgets show only the last 90 days of activity.
        // ConvertedDate marks conversions; LastModifiedDate is the best available
        // proxy for when a lead was disqualified (no dedicated disqualified timestamp).
        stageCounts.put('Converted', LeadSelector.countConvertedInLastNDays(OUTCOME_WINDOW_DAYS));
        stageCounts.put('Disqualified', LeadSelector.countDisqualifiedInLastNDays(OUTCOME_WINDOW_DAYS));
        data.stages = new List<NameCount>();
        for (String s : STAGE_ORDER) {
            data.stages.add(new NameCount(s, stageCounts.get(s)));
        }

        // --- counts by intake channel (LeadSource) ---
        Map<String, Integer> channelCounts = new Map<String, Integer>();
        for (String c : CHANNEL_ORDER) {
            channelCounts.put(c, 0);
        }
        for (AggregateResult ar : LeadSelector.countByLeadSource()) {
            String ls = (String) ar.get('ls');
            if (ls != null && channelCounts.containsKey(ls)) {
                channelCounts.put(ls, (Integer) ar.get('c'));
            }
        }
        data.channels = new List<NameCount>();
        for (String c : CHANNEL_ORDER) {
            data.channels.add(new NameCount(c, channelCounts.get(c)));
        }

        // --- recent leads + review queue (LOW parse confidence) ---
        // High-priority brokers surface first (Junior: prioritize by broker priority,
        // then by first-received timestamp); within each priority tier the SOQL
        // recency order is preserved, so the partition below is a stable sort.
        List<LeadRow> highPriority = new List<LeadRow>();
        List<LeadRow> standardPriority = new List<LeadRow>();
        Integer reviewQueue = 0;
        for (Lead l : LeadSelector.selectRecent(RECENT_LIMIT)) {
            LeadRow r = new LeadRow();
            r.id = l.Id;
            r.name = String.isNotBlank(l.Property_Address__c) ? l.Property_Address__c : l.Name;
            r.status = l.Status;
            r.channel = l.LeadSource;
            r.confidence = l.Parse_Confidence__c;
            // ⚠ NOT COALESCED, AND THAT IS THE CONTRACT. A null Extraction_Score_Pct__c means "not
            // scored" (scoring is fail-soft by mandate — the inbound email pipeline must never be made
            // to throw), which is NOT the same fact as a score of 0. Defaulting it here would tell an
            // analyst that a lead captured none of the nine deal-process keys when in truth the score
            // could not be computed. The client renders null as its own neutral state.
            r.extractionScore = l.Extraction_Score_Pct__c;
            r.price = l.Guidance_Price__c;
            r.broker = l.Broker_First__c;
            r.assetType = l.Asset_Type__c;
            r.priority = l.Broker_Priority__c;
            // First Seen Date is the immutable intake stamp that starts the 90-day broker
            // protection window. Age and BP expiry both derive from it (fallback: CreatedDate).
            Date firstSeen = l.First_Seen_Date__c != null
                ? l.First_Seen_Date__c.date()
                : l.CreatedDate.date();
            r.created = firstSeen;
            r.days = firstSeen.daysBetween(Date.today());
            r.bpExpiry = firstSeen.addDays(BP_WINDOW_DAYS);
            r.bpActive = r.bpExpiry >= Date.today();
            if (r.priority == 'High') {
                highPriority.add(r);
            } else {
                standardPriority.add(r);
            }
            if (l.Parse_Confidence__c == 'LOW') {
                reviewQueue++;
            }
        }
        data.recent = new List<LeadRow>();
        data.recent.addAll(highPriority);
        data.recent.addAll(standardPriority);
        data.total = data.recent.size();
        data.reviewQueue = reviewQueue;
        return data;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeadFunnelController.getFunnel: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    public class FunnelData {
        @AuraEnabled public List<NameCount> stages;
        @AuraEnabled public List<NameCount> channels;
        @AuraEnabled public List<LeadRow> recent;
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer reviewQueue;
    }

    public class NameCount {
        @AuraEnabled public String label;
        @AuraEnabled public Integer count;
        public NameCount(String label, Integer count) {
            this.label = label;
            this.count = count;
        }
    }

    /**
     * One row of the funnel's recent-leads list — exactly the fields `c/recentLeads` renders.
     *
     * ═══ ⚠ SUPERSEDED 2026-08-17 — `packageId` / `packageName` WERE HERE AND WERE REMOVED ═══
     * They carried the multi-property `Portfolio_Deal__c` a Lead arrived on, so `c/recentLeads`
     * could show a 'Package' column. RETRACTED, verbatim, from their own Javadoc: *"The client builds
     * the link from `packageId` and shows `packageName`, and MUST render an empty cell when the Id is
     * null rather than a dead link."*
     *
     * That is no longer true because the COLUMN is gone. The dedicated `c/recentPortfolioDeals` widget now
     * sits on the same homepage and reads `Portfolio_Deal__c` directly — with its own sort and its
     * own server-side cutoff — so it does not inherit the priority partitioning below, which could
     * push a portfolio deal's own Leads past this list's 5-row cutoff. With that card present the
     * column was redundant, and these two members had no reader left.
     *
     * ⚠ THE OBJECT WAS RENAMED ON 2026-08-18 (Portfolio Deal rename, phase B4): what this note calls
     * the 'Package' column carried `Property_Package__c`, which is now `Portfolio_Deal__c`. The two
     * removed member names (`packageId` / `packageName`) and the column title are quoted VERBATIM as
     * they existed — do not "correct" them to the new vocabulary, or the retraction stops matching
     * what a reader would find in git history. The LWC BUNDLE NAME above is the opposite case and
     * WAS updated (`recentPackages` -> `c/recentPortfolioDeals`, renamed by the LWC half of B4):
     * it names a component that still EXISTS, so it has to resolve for a reader today rather than
     * preserve how it read at the time.
     *
     * 🔴 DO NOT RE-ADD A MEMBER NO CLIENT READS. Every `@AuraEnabled` member here costs a field in
     * `LeadSelector.selectRecent`'s `WITH USER_MODE` SELECT, and USER_MODE throws on the WHOLE ROW for
     * ONE inaccessible field — so an unconsumed member is a live way for the entire Lead Funnel
     * homepage to fail for a persona in exchange for nothing on screen. Removing these two also
     * removed `Portfolio_Deal__c` and the spanning `Portfolio_Deal__r.Name` from that SELECT.
     * `LeadFunnelControllerTest.getFunnel_leadRowCarriesNoPackageMembers` is the falsifier.
     */
    public class LeadRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String channel;
        /** `Parse_Confidence__c` — HIGH / MEDIUM / LOW certainty about `is_acquisition_related`. */
        @AuraEnabled public String confidence;
        /**
         * `Extraction_Score_Pct__c` — 0-100, the percent of the nine signed-off DEAL-PROCESS
         * extraction keys captured from the broker email. Added 2026-08-17 for the renamed 'Score'
         * column, which renders it beside `confidence` in ONE cell as TWO distinct elements.
         *
         * 🔴 A DIFFERENT FACT FROM `confidence`, AND THEY MUST NEVER BE CONFLATED OR BLENDED INTO ONE
         * NUMBER. The field's own metadata comment states it: confidence measures certainty about a
         * single classification question, the score measures how COMPLETE the extraction was. A
         * confident, correctly-classified email can be almost empty of deal facts, and an unconfident
         * one can be complete — so a high confidence does NOT imply a high score and a low score does
         * NOT impeach the classification. Sharing a cell is a display decision; averaging, ranking or
         * deriving one from the other is a defect.
         *
         * ⚠ NULLABLE, AND NULL IS A VALUE. It reads "not scored", never zero (scoring is fail-soft by
         * mandate). Do not coalesce it here or on the client.
         *
         * ⚠ It costs `Lead.Extraction_Score_Pct__c` in `LeadSelector.selectRecent`'s `WITH USER_MODE`
         * SELECT — the grant was verified in `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View` and
         * `Broker_Protection_Access` before it was added; see that method's header.
         */
        @AuraEnabled public Decimal extractionScore;
        @AuraEnabled public Decimal price;
        @AuraEnabled public String broker;
        @AuraEnabled public String assetType;
        @AuraEnabled public Date created;
        @AuraEnabled public Integer days;
        @AuraEnabled public Date bpExpiry;
        @AuraEnabled public Boolean bpActive;
        @AuraEnabled public String priority;
    }
}