/**
 * Read-only data provider for the Lead Funnel Lightning page (Acquisitions).
 * Aggregates Leads by stage and intake channel and returns recent leads.
 *
 * All SOQL against Lead lives in LeadSelector per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md — this controller holds zero inline SOQL.
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

    @AuraEnabled(cacheable=true)
    public static FunnelData getFunnel() {
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

    public class LeadRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String channel;
        @AuraEnabled public String confidence;
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