public with sharing class OnboardingTaskRollupService {

    // Recompute the summary/rollup fields on each Onboarding__c from its checklist Tasks.
    public static void recalc(Set<Id> onboardingIds) {
        if (onboardingIds == null || onboardingIds.isEmpty()) return;
        Date today = Date.today();
        Date stalledCutoff = today.addDays(-7);
        Date due7dEnd = today.addDays(7);

        Map<Id, Onboarding__c> upd = new Map<Id, Onboarding__c>();
        for (Id oid : onboardingIds) {
            upd.put(oid, new Onboarding__c(Id=oid,
                Tasks_Total__c=0, Tasks_Complete__c=0, Tasks_In_Progress__c=0, Tasks_Not_Started__c=0,
                Tasks_Blocked__c=0, Tasks_NA__c=0, Tasks_Open__c=0, Tasks_Overdue__c=0,
                Tasks_Blocked_Now__c=0, Tasks_Stalled__c=0, Tasks_Due_7d__c=0, Completion_Pct__c=0));
        }

        for (Task t : [
            SELECT Onboarding__c, Onboarding_Status__c, ActivityDate
            FROM Task WHERE Onboarding__c IN :onboardingIds
        ]) {
            Onboarding__c o = upd.get(t.Onboarding__c);
            String st = t.Onboarding_Status__c;
            o.Tasks_Total__c += 1;
            Boolean isComplete = (st == 'Complete');
            Boolean isNA = (st == 'Not Applicable');
            if (isComplete) o.Tasks_Complete__c += 1;
            else if (st == 'In Progress') o.Tasks_In_Progress__c += 1;
            else if (st == 'Not Started') o.Tasks_Not_Started__c += 1;
            else if (st == 'Blocked') { o.Tasks_Blocked__c += 1; o.Tasks_Blocked_Now__c += 1; }
            if (isNA) o.Tasks_NA__c += 1;
            Boolean isOpen = (!isComplete && !isNA);
            if (isOpen) o.Tasks_Open__c += 1;
            if (isOpen && t.ActivityDate != null && t.ActivityDate < today) o.Tasks_Overdue__c += 1;
            if (st == 'In Progress' && t.ActivityDate != null && t.ActivityDate < stalledCutoff) o.Tasks_Stalled__c += 1;
            if (isOpen && t.ActivityDate != null && t.ActivityDate >= today && t.ActivityDate <= due7dEnd) o.Tasks_Due_7d__c += 1;
        }

        for (Onboarding__c o : upd.values()) {
            Decimal tot = (o.Tasks_Total__c == null) ? 0 : o.Tasks_Total__c;
            Decimal comp = (o.Tasks_Complete__c == null) ? 0 : o.Tasks_Complete__c;
            o.Completion_Pct__c = (tot > 0) ? (Integer) Math.round(100 * comp / tot) : 0;
        }
        update upd.values();
    }
}
