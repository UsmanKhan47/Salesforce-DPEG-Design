/**
 * Backs the read-only Work Order Tracker: home-page widgets and the record-page
 * activity timeline. No mutation methods — work orders are managed in Yardi.
 */
public with sharing class WorkOrderController {

    private static final String ROW_QUERY =
        'SELECT Id, Subject__c, Property_Display_Name__c, Unit_Label__c, Priority__c, Status__c, ' +
        'SLA_Health__c, Hours_Open__c, SLA_Breached__c, Untouched__c, Is_Open__c ' +
        'FROM Work_Order__c ';

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
        for (Work_Order__c w : [SELECT Is_Open__c, SLA_Breached__c, SLA_Health__c, Untouched__c FROM Work_Order__c]) {
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
        return toRows(Database.query(ROW_QUERY + 'WHERE Is_Open__c = true ORDER BY Reported_DateTime__c DESC LIMIT 6'));
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getEscalations() {
        return toRows(Database.query(ROW_QUERY + 'WHERE Is_Escalation__c = true ORDER BY SLA_Due_DateTime__c ASC NULLS LAST'));
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getUntouched() {
        return toRows(Database.query(ROW_QUERY + 'WHERE Untouched__c = true ORDER BY Reported_DateTime__c ASC NULLS LAST'));
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
        Work_Order__c w = [SELECT Untouched__c FROM Work_Order__c WHERE Id = :workOrderId LIMIT 1];
        ActivityView v = new ActivityView();
        v.untouched = w.Untouched__c == true;
        v.entries = new List<Entry>();
        // Frozen-clock gotcha: same-transaction rows share timestamps, so tie-break on Name DESC.
        for (Work_Order_Activity__c a : [SELECT Id, Kind__c, Detail__c, Actor__c, Entry_DateTime__c
                                         FROM Work_Order_Activity__c WHERE Work_Order__c = :workOrderId
                                         ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC]) {
            Entry e = new Entry();
            e.id = a.Id; e.kind = a.Kind__c; e.detail = a.Detail__c; e.actor = a.Actor__c; e.entryDate = a.Entry_DateTime__c;
            v.entries.add(e);
        }
        return v;
    }
}