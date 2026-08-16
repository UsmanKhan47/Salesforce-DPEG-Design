// Find an opp that has at least one NDA and one LOI, then exercise the controller.
Set<Id> ndaOpps = new Set<Id>();
for (NDA__c n : [SELECT Opportunity__c FROM NDA__c WHERE Opportunity__c != null]) ndaOpps.add(n.Opportunity__c);
Id target;
for (LOI__c l : [SELECT Opportunity__c FROM LOI__c WHERE Opportunity__c != null]) {
    if (ndaOpps.contains(l.Opportunity__c)) { target = l.Opportunity__c; break; }
}
if (target == null) {
    // fall back to any opp with an NDA
    target = ndaOpps.isEmpty() ? null : (new List<Id>(ndaOpps))[0];
}
System.debug('TARGET OPP :: ' + target);
OpportunityDocStatusController.DocStatus d = OpportunityDocStatusController.getDocStatus(target);
System.debug('NDA :: has=' + d.hasNda + ' status=' + d.ndaStatus + ' signedCopyReturned=' + d.ndaSignedCopyReturned + ' expiry=' + d.ndaExpiry + ' signed=' + d.ndaSigned);
System.debug('LOI :: has=' + d.hasLoi + ' status=' + d.loiStatus + ' price=' + d.loiOfferPrice + ' cap=' + d.loiCapRate + ' submitted=' + d.loiSubmitted);
