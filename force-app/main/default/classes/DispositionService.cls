/**
 * Service for the Disposition (closing) write workflow.
 *
 * Owns the business logic behind DispositionController.findOrCreate (P6 controller
 * thinning): the idempotent "find the Property Asset's current Disposition, or create
 * one" operation. Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2, this
 * DML is Service work, not Controller work — the controller now only marshals input,
 * delegates here, and maps failures to an AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to DispositionSelector — this service holds no inline SOQL. It
 * throws the raw platform DmlException on a save failure; the AuraHandledException
 * boundary lives in the controller, NOT here, so the service stays UI-agnostic (also
 * callable from Flow / Apex / a future caller).
 *
 * @see force-app/main/default/classes/DispositionController.cls (thin caller)
 * @see force-app/main/default/classes/DispositionSelector.cls (all SOQL)
 */
public with sharing class DispositionService {

    /**
     * Returns the most-recent Disposition for a Property Asset, creating one when none
     * exists yet — the find-or-create the Disposition dashboard button relies on so the
     * closing workspace self-seeds on first open. Idempotent: a second call for an asset
     * that already has a Disposition returns the existing Id and creates nothing.
     *
     * @param assetId the Property_Asset__c to read/create the Disposition under
     * @return the existing or newly created Disposition__c Id
     * @throws System.DmlException on a platform save failure
     */
    public static Id findOrCreate(Id assetId) {
        Disposition__c existing = DispositionSelector.selectMostRecentByPropertyAssetId(assetId);
        if (existing != null) {
            return existing.Id;
        }
        Disposition__c d = new Disposition__c(Property_Asset__c = assetId);
        insert d;
        return d.Id;
    }
}
