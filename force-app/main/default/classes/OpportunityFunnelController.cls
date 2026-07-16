/**
 * Read-only data provider for the "Opportunities by Stage" widget on the
 * Acquisition home page. Returns a count per Opportunity stage, in funnel order.
 */
public with sharing class OpportunityFunnelController {

    private static final List<String> STAGE_ORDER = new List<String>{
        'New', 'Under Review', 'Development Review', 'Construction Review', 'Underwriting',
        'LOI', 'PSA', 'About to Close', 'Closed Won', 'Dead/Pass', 'Portfolio Deal'
    };

    @AuraEnabled(cacheable=true)
    public static List<StageCount> getStageCounts() {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (String s : STAGE_ORDER) {
            counts.put(s, 0);
        }
        for (AggregateResult ar : OpportunitySelector.countByStage()) {
            String st = (String) ar.get('st');
            if (st != null && counts.containsKey(st)) {
                counts.put(st, (Integer) ar.get('c'));
            }
        }
        // Outcome stages are scoped to the last 90 days by close date so the cards
        // reflect recent activity rather than an ever-growing all-time total.
        counts.put('PSA', OpportunitySelector.countByStageInLastNDays('PSA', 90));
        counts.put('Closed Won', OpportunitySelector.countByStageInLastNDays('Closed Won', 90));
        counts.put('Dead/Pass', OpportunitySelector.countByStageInLastNDays('Dead/Pass', 90));
        List<StageCount> result = new List<StageCount>();
        for (String s : STAGE_ORDER) {
            result.add(new StageCount(s, counts.get(s)));
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<OppRow> getRecentOpportunities() {
        List<OppRow> rows = new List<OppRow>();
        // Top 5 deals by asking price (largest first); deals without an asking
        // price sort last so the list leads with the biggest opportunities.
        for (Opportunity o : OpportunitySelector.selectTopByAskingPrice(5)) {
            OppRow r = new OppRow();
            r.id = o.Id;
            r.name = o.Name;
            r.stage = o.StageName;
            r.dealType = o.Deal_Type__c;
            r.assetType = o.Asset_Type__c;
            r.price = o.Asking_Price__c;
            r.noi = o.Underwritten_NOI__c;
            r.days = o.CreatedDate.date().daysBetween(Date.today());
            rows.add(r);
        }
        return rows;
    }

    @AuraEnabled(cacheable=true)
    public static PipelineSnapshot getPipelineSnapshot() {
        PipelineSnapshot s = new PipelineSnapshot();
        Set<String> closedStages = new Set<String>{ 'Closed Won', 'Dead/Pass' };
        for (AggregateResult ar : OpportunitySelector.aggregateOpenPipeline(closedStages)) {
            s.openDeals = (Integer) ar.get('c');
            Decimal v = (Decimal) ar.get('v');
            s.pipelineValue = (v == null) ? 0 : v;
        }
        s.landDeals = OpportunitySelector.countByDealType('Land');
        s.commercialDeals = OpportunitySelector.countByDealType('Commercial');
        return s;
    }

    public class StageCount {
        @AuraEnabled public String label;
        @AuraEnabled public Integer count;
        public StageCount(String label, Integer count) {
            this.label = label;
            this.count = count;
        }
    }

    public class PipelineSnapshot {
        @AuraEnabled public Integer openDeals = 0;
        @AuraEnabled public Decimal pipelineValue = 0;
        @AuraEnabled public Integer landDeals = 0;
        @AuraEnabled public Integer commercialDeals = 0;
    }

    public class OppRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String stage;
        @AuraEnabled public String dealType;
        @AuraEnabled public String assetType;
        @AuraEnabled public Decimal price;
        @AuraEnabled public Decimal noi;
        @AuraEnabled public Integer days;
    }
}