/**
 * Read-only data provider for the "Opportunities by Stage" widget on the
 * Acquisition home page. Returns a count per Opportunity stage, in funnel order.
 *
 * All SOQL is delegated to OpportunitySelector per ARCHITECTURE.md §2 — this
 * controller holds no inline SOQL. Read-only: there are no mutation methods here.
 *
 * Thin controller (P6 controller thinning — boundaries only, no DML to extract).
 * Every @AuraEnabled read wraps its work in a try/catch that maps a failure to a
 * user-safe AuraHandledException at the LWC boundary (ARCHITECTURE.md §5): platform
 * detail goes to the debug log (admin-only) and the user gets a fixed, generic message
 * with no exception detail concatenated into it.
 */
public with sharing class OpportunityFunnelController {

    private static final List<String> STAGE_ORDER = new List<String>{
        'New', 'Under Review', 'Development Review', 'Construction Review', 'Underwriting',
        'LOI', 'PSA', 'About to Close', 'Closed Won', 'Dead/Pass', 'Portfolio Deal'
    };

    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'The opportunity funnel could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static List<StageCount> getStageCounts() {
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OpportunityFunnelController.getStageCounts: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<OppRow> getRecentOpportunities() {
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OpportunityFunnelController.getRecentOpportunities: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled(cacheable=true)
    public static PipelineSnapshot getPipelineSnapshot() {
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OpportunityFunnelController.getPipelineSnapshot: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
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
