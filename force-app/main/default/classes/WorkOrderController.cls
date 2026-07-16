/**
 * Backs the read-only Work Order Tracker: home-page widgets and the record-page
 * activity timeline. No mutation methods — work orders are managed in Yardi.
 */
public with sharing class WorkOrderController {

    public class HomeKpis {
        @AuraEnabled public Integer open;
        @AuraEnabled public Integer breached;
        @AuraEnabled public Integer dueSoon;
        @AuraEnabled public Integer untouched;
    }
    @AuraEnabled(cacheable=true)
    public static HomeKpis getHomeKpis() {
        HomeKpis k = new HomeKpis();
        k.open = 0; k.breached = 0; k.dueSoon = 0; k.untouched = 0;
        for (Work_Order__c w : WorkOrderSelector.selectForKpis()) {
            if (w.Is_Open__c) {
                k.open++;
                if (w.SLA_Breached__c) k.breached++;
                if (w.SLA_Health__c != null && w.SLA_Health__c.contains('Due Soon')) k.dueSoon++;
                if (w.Untouched__c) k.untouched++;
            }
        }
        return k;
    }

    public class Row {
        @AuraEnabled public Id id;
        @AuraEnabled public String subject;
        @AuraEnabled public String property;
        @AuraEnabled public String unit;
        @AuraEnabled public String priority;
        @AuraEnabled public String status;
        @AuraEnabled public String slaHealth;
        @AuraEnabled public Integer hoursOpen;
        @AuraEnabled public Boolean breached;
        @AuraEnabled public Boolean untouched;
        @AuraEnabled public Boolean isOpen;
    }
    private static List<Row> toRows(List<Work_Order__c> recs) {
        List<Row> out = new List<Row>();
        for (Work_Order__c w : recs) {
            Row r = new Row();
            r.id = w.Id; r.subject = w.Subject__c; r.property = w.Property_Display_Name__c; r.unit = w.Unit_Label__c;
            r.priority = w.Priority__c; r.status = w.Status__c; r.slaHealth = w.SLA_Health__c;
            r.hoursOpen = w.Hours_Open__c == null ? null : (Integer) w.Hours_Open__c;
            r.breached = w.SLA_Breached__c == true; r.untouched = w.Untouched__c == true; r.isOpen = w.Is_Open__c == true;
            out.add(r);
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Row> getRecentWorkOrders() {
        return toRows(WorkOrderSelector.selectRecentOpen());
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getEscalations() {
        return toRows(WorkOrderSelector.selectEscalations());
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getUntouched() {
        return toRows(WorkOrderSelector.selectUntouched());
    }

    public class Entry {
        @AuraEnabled public Id id;
        @AuraEnabled public String kind;
        @AuraEnabled public String detail;
        @AuraEnabled public String actor;
        @AuraEnabled public Datetime entryDate;
    }
    public class ActivityView {
        @AuraEnabled public List<Entry> entries;
        @AuraEnabled public Boolean untouched;
    }
    @AuraEnabled(cacheable=true)
    public static ActivityView getActivity(Id workOrderId) {
        Work_Order__c w = WorkOrderSelector.selectRequiredById(workOrderId);
        ActivityView v = new ActivityView();
        v.untouched = w.Untouched__c == true;
        v.entries = new List<Entry>();
        // Frozen-clock gotcha: same-transaction rows share timestamps, so the
        // selector tie-breaks on Name DESC (see WorkOrderActivitySelector).
        for (Work_Order_Activity__c a : WorkOrderActivitySelector.selectByWorkOrderId(workOrderId)) {
            Entry e = new Entry();
            e.id = a.Id; e.kind = a.Kind__c; e.detail = a.Detail__c; e.actor = a.Actor__c; e.entryDate = a.Entry_DateTime__c;
            v.entries.add(e);
        }
        return v;
    }
}