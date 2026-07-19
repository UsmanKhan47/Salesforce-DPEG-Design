/**
 * Service for the disposition Wire (anti-fraud verification) write workflow.
 *
 * Owns the business logic behind WireController.saveWire (P6 controller thinning): the
 * upsert of the Wire__c under a Disposition — load-or-new, apply the verification
 * fields, and stamp / clear Verified_DateTime__c from the verbal-verification flag. Per
 * .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2, this DML is Service work,
 * not Controller work — the controller now only marshals input, delegates here, re-reads
 * the saved row to shape a view DTO, and maps failures to an AuraHandledException at the
 * LWC boundary (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to WireSelector — this service holds no inline SOQL. It throws
 * the raw platform QueryException (missing update target) / DmlException (save failure);
 * the AuraHandledException boundary lives in the controller, NOT here, so the service
 * stays UI-agnostic.
 *
 * @see force-app/main/default/classes/WireController.cls (thin caller)
 * @see force-app/main/default/classes/WireSelector.cls (all SOQL)
 */
public with sharing class WireService {

    /**
     * Upserts the Wire for a Disposition. When wireId is supplied the existing Wire is
     * loaded and updated in place; otherwise a new Wire is created under the Disposition.
     * The verification fields are applied, and Verified_DateTime__c is stamped the first
     * time verbal verification is turned on and cleared whenever it is turned off.
     *
     * WireSelector.selectRequiredById returns Verified_DateTime__c deliberately — this
     * method reads it to decide whether to (re-)stamp, so narrowing that selector field
     * set would reintroduce a System.SObjectException. See WireSelector's method doc.
     *
     * @param dispositionId    the parent Disposition__c (used only when creating a new Wire)
     * @param wireId           the Wire__c Id to update; null to create a new Wire
     * @param verbalDone       whether verbal verification is complete
     * @param verifierName     the verifier's name
     * @param verifierPhone    the verifier's phone
     * @param wireSource       where the wire instructions came from
     * @param confirmedAmount  the confirmed wire amount
     * @return the saved Wire__c Id
     * @throws System.QueryException when wireId is supplied but matches no row
     * @throws System.DmlException   on a platform save failure
     */
    public static Id saveWire(Id dispositionId, String wireId,
            Boolean verbalDone, String verifierName, String verifierPhone,
            String wireSource, Decimal confirmedAmount) {
        Wire__c w;
        if (wireId != null) {
            w = WireSelector.selectRequiredById((Id) wireId);
        } else {
            w = new Wire__c(Disposition__c = dispositionId);
        }
        w.Verbal_Verification_Completed__c = verbalDone == true;
        w.Verifier_Name__c = verifierName;
        w.Verifier_Phone__c = verifierPhone;
        w.Wire_Instructions_Source__c = wireSource;
        w.Confirmed_Wire_Amount__c = confirmedAmount;
        if (verbalDone == true && w.Verified_DateTime__c == null) {
            w.Verified_DateTime__c = Datetime.now();
        } else if (verbalDone != true) {
            w.Verified_DateTime__c = null;
        }
        upsert w;
        return w.Id;
    }
}
