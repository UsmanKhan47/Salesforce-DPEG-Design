/**
 * Trigger handler for `Property_Asset__c`. Routes TWO contexts to TWO services (⚠ it routed to ONE
 * until 2026-08-25 — re-count against the methods, never against this sentence):
 *
 *   after insert / after update  -> OnboardingAutoCreateService.ensureOnClosing
 *                                      (the moment `Closing_Date__c` goes non-null, i.e. DPEG
 *                                       finishes acquiring a property: open the PM onboarding
 *                                       checklist and alert the Property Management team)
 *   after update ONLY            -> BovAutoSelectionService.reselectForRepricedDispositions
 *                                      (re-rank the BOV submissions of every disposition under
 *                                       this asset when `Target_Sale_Price__c` changes — added
 *                                       2026-08-25; see `afterUpdate` below for why it is NOT on
 *                                       insert)
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE SECOND SERVICE IS A DISPOSITION CONCERN LIVING ON A PROPERTY MANAGEMENT OBJECT, AND
 *    THAT CROSSING IS DELIBERATE — IT FOLLOWS THE DATA, NOT THE MODULE BOUNDARY.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `BOV_Submission__c.BOV_Score__c` divides by
 * `Disposition__r.Property_Asset__r.Target_Sale_Price__c` as of 2026-08-25 (the user retired
 * `Disposition__c.Asking_Price__c` from the disposition flow). So the ONLY event that moves a BOV
 * score without touching a BOV is a Target Sale Price edit ON THIS OBJECT. The hook used to sit on
 * `DispositionTriggerHandler.afterUpdate`; it moved here with the field it watches. Putting it
 * anywhere else means the broker auto-appointment silently never fires on the primary path —
 * responses first, price later — with a green deploy and green tests.
 *
 * ⚠ IT COSTS A PROPERTY MANAGEMENT USER NOTHING UNLESS THEY MOVE THE PRICE. The service returns
 * before its first query when no asset in the chunk changed `Target_Sale_Price__c`, which is what
 * keeps this handler invisible to every PM bulk test. Do not "simplify" that guard away.
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
 * @see force-app/main/default/classes/BovAutoSelectionService.cls
 * @see force-app/main/default/triggers/PropertyAssetTrigger.trigger
 */
public with sharing class PropertyAssetTriggerHandler extends TriggerHandler {

    protected override void afterInsert() {
        OnboardingAutoCreateService.ensureOnClosing((List<Property_Asset__c>) newList, null);
    }

    /**
     * ⚠ TWO SERVICES HERE, AND THE SECOND ONE IS ON **UPDATE ONLY** — WHICH IS WHY THIS HANDLER
     * HAS NO SHARED `route` HELPER THE WAY `DispositionTriggerHandler` DOES.
     * `BovAutoSelectionService.reselectForRepricedDispositions` has nothing to do on insert: a
     * brand-new Property Asset has no Dispositions, so it has no BOV submissions, so an
     * insert-context call would query for rows that cannot exist. Keeping it out of `afterInsert`
     * makes that true by construction rather than by an `if`.
     *
     * ⚠ ORDER: `ensureOnClosing` runs FIRST. It performs synchronous DML (the onboarding checklist)
     * and is the more consequential failure, so it is the earlier one. The two touch disjoint
     * objects and neither reads the other's output, so nothing else depends on the sequence.
     */
    protected override void afterUpdate() {
        OnboardingAutoCreateService.ensureOnClosing(
            (List<Property_Asset__c>) newList,
            (Map<Id, Property_Asset__c>) oldMap
        );
        BovAutoSelectionService.reselectForRepricedDispositions(
            (List<Property_Asset__c>) newList,
            (Map<Id, Property_Asset__c>) oldMap
        );
    }
}
