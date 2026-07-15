// Seed Underwritten NOI on Opportunities so the "Recent Opportunities" home-page
// widget (top 10 by asking price) shows NOI instead of dashes.
//
// NOI is derived from the cap-rate identity: NOI = Asking Price x Cap Rate.
// Uses the underwritten cap rate (My_Cap_Rate__c) when present, else a sensible
// 6.75% default. Idempotent: only fills deals whose NOI is currently blank, so
// re-running never clobbers real underwriting numbers.
List<Opportunity> toUpdate = new List<Opportunity>();
for (Opportunity o : [
    SELECT Id, Asking_Price__c, My_Cap_Rate__c
    FROM Opportunity
    WHERE Underwritten_NOI__c = null AND Asking_Price__c != null
]) {
    Decimal capRate = (o.My_Cap_Rate__c != null && o.My_Cap_Rate__c > 0)
        ? o.My_Cap_Rate__c : 6.75;
    // NOI = price x cap%, rounded to the nearest $1,000 to look hand-entered.
    Decimal noi = (o.Asking_Price__c * capRate / 100).divide(1000, 0, System.RoundingMode.HALF_UP) * 1000;
    o.Underwritten_NOI__c = noi;
    toUpdate.add(o);
}
update toUpdate;
System.debug('Seeded NOI on ' + toUpdate.size() + ' opportunities');
