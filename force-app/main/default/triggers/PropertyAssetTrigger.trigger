/**
 * The single Property_Asset__c trigger (one-trigger-per-object). Opens the PM
 * onboarding checklist when an asset's Closing_Date__c transitions to non-null.
 * All logic lives in PropertyAssetTriggerHandler -> OnboardingAutoCreateService.
 *
 * ⚠ after update is included deliberately, not by symmetry: an asset created without
 * a Closing Date and given one later (a manual correction, a data load, a future
 * acquisition path) must still get an onboarding. The service tests the TRANSITION,
 * so a re-save of an already-closed asset does nothing.
 */
trigger PropertyAssetTrigger on Property_Asset__c (after insert, after update) {
    new PropertyAssetTriggerHandler().run();
}
