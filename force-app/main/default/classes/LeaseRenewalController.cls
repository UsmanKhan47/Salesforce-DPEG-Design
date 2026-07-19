/**
 * Backs the Lease Renewal Tracker: home-page widgets and the record-page
 * timeline. Timeline entries are append-only.
 *
 * Thin controller (P6 controller thinning). The addUpdate write DML and the
 * valid-method/non-blank-outcome business rule live in LeaseRenewalService per
 * .claude/rules/apex-layering-rule.md; all SOQL lives in LeaseRenewalSelector /
 * RenewalActivitySelector per ARCHITECTURE.md §2. Every @AuraEnabled method (read and
 * write) maps failures the same way (ARCHITECTURE.md §5): the platform detail goes to the
 * debug log (admin-only) and the user gets a user-safe message. A user-actionable rule
 * violation (RenewalUpdateException) is surfaced verbatim; an unexpected platform failure
 * gets a fixed, generic message with no exception detail concatenated into it.
 */
public with sharing class LeaseRenewalController {

    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';
    // Fixed, generic user-safe message for an unexpected failed write. Never interpolate
    // platform text or exception detail into it (ARCHITECTURE.md §5).
    private static final String WRITE_FAILURE_MESSAGE =
        'This update could not be saved. Refresh the page and try again, or contact your administrator.';

    public class HomeKpis {
        @AuraEnabled public Integer active;
        @AuraEnabled public Integer expiring90;
        @AuraEnabled public Integer nonResponsive;
        @AuraEnabled public Integer renewedYtd;
    }
    @AuraEnabled(cacheable=true)
    public static HomeKpis getHomeKpis() {
        try {
            HomeKpis k = new HomeKpis();
            k.active = 0; k.expiring90 = 0; k.nonResponsive = 0; k.renewedYtd = 0;
            Date yearStart = Date.newInstance(Date.today().year(), 1, 1);
            for (Lease_Renewal__c r : LeaseRenewalSelector.selectForKpis()) {
                if (r.Status__c == 'Active') {
                    k.active++;
                    if (r.Days_To_Expiry__c != null && r.Days_To_Expiry__c <= 90) k.expiring90++;
                    if (r.Is_Non_Responsive__c) k.nonResponsive++;
                }
                if (r.Status__c == 'Closed Won' && r.Renewed_Date__c != null && r.Renewed_Date__c >= yearStart) k.renewedYtd++;
            }
            return k;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseRenewalController.getHomeKpis: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class Row {
        @AuraEnabled public Id id;
        @AuraEnabled public String tenant;
        @AuraEnabled public String property;
        @AuraEnabled public String unit;
        @AuraEnabled public Date leaseEnd;
        @AuraEnabled public Integer daysToExpiry;
        @AuraEnabled public String stage;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean closed;
        @AuraEnabled public Date lastContact;
        @AuraEnabled public Integer daysSinceContact;
        @AuraEnabled public Boolean nonResponsive;
    }
    private static Row toRow(Lease_Renewal__c r) {
        Row w = new Row();
        w.id = r.Id; w.tenant = r.Tenant_Name__c; w.property = r.Property_Display_Name__c; w.unit = r.Unit_Label__c;
        w.leaseEnd = r.Lease_End__c;
        w.daysToExpiry = r.Days_To_Expiry__c == null ? null : (Integer) r.Days_To_Expiry__c;
        w.stage = r.Stage__c; w.status = r.Status__c; w.closed = r.Status__c != 'Active';
        w.lastContact = r.Last_Contact_Date__c;
        w.daysSinceContact = r.Days_Since_Contact__c == null ? null : (Integer) r.Days_Since_Contact__c;
        w.nonResponsive = r.Is_Non_Responsive__c == true;
        return w;
    }
    private static List<Row> toRows(List<Lease_Renewal__c> recs) {
        List<Row> out = new List<Row>();
        for (Lease_Renewal__c r : recs) out.add(toRow(r));
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Row> getRecentRenewals() {
        try {
            return toRows(LeaseRenewalSelector.selectRecent());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseRenewalController.getRecentRenewals: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getAttention() {
        try {
            return toRows(LeaseRenewalSelector.selectAttention());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseRenewalController.getAttention: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class Entry {
        @AuraEnabled public Id id;
        @AuraEnabled public String method;
        @AuraEnabled public String details;
        @AuraEnabled public String enteredBy;
        @AuraEnabled public Datetime entryDate;
    }
    public class TimelineView {
        @AuraEnabled public List<Entry> entries;
        @AuraEnabled public String stage;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean closed;
        @AuraEnabled public Boolean nonResponsive;
        @AuraEnabled public Integer daysSinceContact;
        @AuraEnabled public Boolean canLog;
    }
    @AuraEnabled(cacheable=true)
    public static TimelineView getTimeline(Id renewalId) {
        try {
            Lease_Renewal__c r = LeaseRenewalSelector.selectRequiredById(renewalId);
            TimelineView v = new TimelineView();
            v.stage = r.Stage__c; v.status = r.Status__c; v.closed = r.Status__c != 'Active';
            v.nonResponsive = r.Is_Non_Responsive__c == true;
            v.daysSinceContact = r.Days_Since_Contact__c == null ? null : (Integer) r.Days_Since_Contact__c;
            v.canLog = !v.closed;
            v.entries = new List<Entry>();
            // Frozen-clock gotcha: same-transaction rows share timestamps, so the
            // selector tie-breaks on Name DESC (see RenewalActivitySelector).
            for (Renewal_Activity__c a : RenewalActivitySelector.selectByLeaseRenewalId(renewalId)) {
                Entry e = new Entry();
                e.id = a.Id; e.method = a.Method__c; e.details = a.Details__c;
                e.enteredBy = a.CreatedBy.Name; e.entryDate = a.Entry_DateTime__c;
                v.entries.add(e);
            }
            return v;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseRenewalController.getTimeline on ' + renewalId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Logs one timeline entry against the renewal and, for a human contact method, stamps
     * the tenant-contact date. Delegates the write + validation to LeaseRenewalService; a
     * user-actionable rule violation is surfaced verbatim, any other failure gets the
     * generic message.
     */
    @AuraEnabled
    public static void addUpdate(Id renewalId, String method, String details) {
        try {
            LeaseRenewalService.addUpdate(renewalId, method, details);
        } catch (LeaseRenewalService.RenewalUpdateException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseRenewalController.addUpdate on ' + renewalId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}