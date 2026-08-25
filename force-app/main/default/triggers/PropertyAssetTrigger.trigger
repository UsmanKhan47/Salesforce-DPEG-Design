/**
 * The single Property_Asset__c trigger (one-trigger-per-object). Two jobs, not one
 * (⚠ this comment described only the first until 2026-08-25):
 *   1. opens the PM onboarding checklist when Closing_Date__c transitions to non-null
 *      (PropertyAssetTriggerHandler -> OnboardingAutoCreateService);
 *   2. re-ranks the BOV submissions of every Disposition under this asset when
 *      Target_Sale_Price__c changes (-> BovAutoSelectionService), because that field
 *      is BOV_Score__c's value basis as of 2026-08-25.
 * All logic lives in PropertyAssetTriggerHandler; this file stays a one-liner.
 *
 * ⚠ after update is included deliberately, not by symmetry: an asset created without
 * a Closing Date and given one later (a manual correction, a data load, a future
 * acquisition path) must still get an onboarding. The service tests the TRANSITION,
 * so a re-save of an already-closed asset does nothing. The same is true of job 2 —
 * an asset save that does not move Target_Sale_Price__c costs zero queries.
 */
trigger PropertyAssetTrigger on Property_Asset__c (after insert, after update) {
    new PropertyAssetTriggerHandler().run();
}
