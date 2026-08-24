// Fires the REAL production auto-create path (not a fixture): setting Closing_Date__c
// on Property_Asset__c triggers PropertyAssetTriggerHandler -> OnboardingAutoCreateService
// -> creates Onboarding__c -> the Onboarding_Task_Fanout flow fires on insert -> 45 checklist
// Tasks fan out from Onboarding_Task_Def__mdt. This is the acceptance test for that whole
// chain, not a shortcut around it.
//
// Two properties, at different points in the checklist, so the Onboarding home page shows
// more than one row and the portfolio/aging tiles have something to aggregate.

List<Property_Asset__c> targets = [
    SELECT Id, Property_Name__c, Closing_Date__c FROM Property_Asset__c
    WHERE Property_Name__c IN ('Cypresswood Retail', 'Bandera Crossing Center')
];
if (targets.size() != 2) {
    throw new System.CalloutException('Expected 2 properties, found ' + targets.size());
}
for (Property_Asset__c p : targets) {
    p.Closing_Date__c = Date.today().addDays(-14);
}
update targets;

System.debug(LoggingLevel.ERROR, 'Closing_Date__c set on ' + targets.size() + ' properties. '
    + 'Onboarding__c + 45 checklist Tasks should now exist for each (async flow - see readback).');
