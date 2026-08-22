/**
 * Trigger handler for `Property_Asset__c`. Routes the two contexts in which an asset's
 * `Closing_Date__c` can transition to non-null — i.e. the moment DPEG finishes
 * acquiring a property — to `OnboardingAutoCreateService`, which opens the PM
 * onboarding checklist and alerts the Property Management team.
 *
 * ⚠ THIS IS THE FIRST TRIGGER `Property_Asset__c` HAS EVER HAD, and
 * `PropertyAssetService`'s header explicitly asserted that fact as verified
 * ("Starts no downstream automation… no `Property_Asset__c` trigger, no flow with it
 * as the start object"). That assertion has been corrected in place in the same
 * change rather than left to mislead the next reader.
 *
 * No SOQL, no DML, no logic — the id filtering and the transition test both live in
 * the service, because "did Closing_Date__c just become non-null" is a business rule
 * about acquisitions, not a mechanical projection of a lookup field.
 *
 * `after` rather than `before`: the service needs the asset Ids to key the Onboarding
 * lookups it creates, and it performs its own DML on a different object, so nothing is
 * gained by running before the save and the record Ids would not exist yet on insert.
 *
 * @see force-app/main/default/classes/OnboardingAutoCreateService.cls
 * @see force-app/main/default/triggers/PropertyAssetTrigger.trigger
 */
public with sharing class PropertyAssetTriggerHandler extends TriggerHandler {

    protected override void afterInsert() {
        OnboardingAutoCreateService.ensureOnClosing((List<Property_Asset__c>) newList, null);
    }

    protected override void afterUpdate() {
        OnboardingAutoCreateService.ensureOnClosing(
            (List<Property_Asset__c>) newList,
            (Map<Id, Property_Asset__c>) oldMap
        );
    }
}
