// One-shot cleanup (2026-08-25): reset-green-sell-meter-assets.apex was run twice, and its
// create step was not guarded, so Stone Oak / Alamo Ranch exist twice. Keep the 07:44 pair
// (Alamo Ranch already carries a Disposition); remove the 07:54 pair with the
// Property__c parents and the Onboarding__c rows the asset trigger opened for them.
Set<Id> dupAssets = new Set<Id>{ 'a0Niw000005c3LNEAY', 'a0Niw000005c3LOEAY' };
Set<Id> dupProps  = new Set<Id>{ 'a0Oiw000000TAC5EAO', 'a0Oiw000000TAC6EAO' };

List<Disposition__c> guard = [SELECT Id FROM Disposition__c WHERE Property_Asset__c IN :dupAssets];
if (!guard.isEmpty()) {
    throw new HandledException('Refusing: duplicate assets already have dispositions ' + guard);
}
delete [SELECT Id FROM Onboarding__c WHERE Property_Asset__c IN :dupAssets];
delete [SELECT Id FROM Property_Asset__c WHERE Id IN :dupAssets];
delete [SELECT Id FROM Property__c WHERE Id IN :dupProps];
System.debug(LoggingLevel.ERROR, 'Duplicates removed. Remaining: '
    + [SELECT Id, Name FROM Property_Asset__c WHERE Name IN ('Stone Oak Village Center','Alamo Ranch Marketplace')]);
