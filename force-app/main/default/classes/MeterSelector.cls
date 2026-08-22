/**
 * Selector for `Meter__c` - encapsulates ALL SOQL against the meter register per
 * ARCHITECTURE.md section 2 and `.claude/rules/apex-layering-rule.md` ("All SOQL must live
 * in Selector classes. Nothing else queries that object.").
 *
 * FSD 5.10.4. `Meter__c` is a custom object built in place of standard `Asset` - see user
 * decision D-UM-1 and the object's own description for the two verified blockers.
 *
 * === MODE - THIS SELECTOR MIXES USER_MODE AND SYSTEM_MODE, DELIBERATELY ===
 * ARCHITECTURE.md section 2: "The mode is a property of the METHOD, never of the class."
 * Read the method, not this header, before assuming which one a call uses.
 *
 *   USER_MODE   - selectByPropertyAssetIds, selectByIds, selectForCapture,
 *                 selectByServiceIdentifiers. Every one backs a read the running user ASKED
 *                 for (a register list, a capture screen). A throw there reports a real
 *                 provisioning gap and the fix is a permission set, not a code change.
 *
 *   SYSTEM_MODE - selectRegisterByIds ONLY. Justified at its own declaration below.
 *
 * SHARING. This class is `with sharing`, and `SYSTEM_MODE` does NOT lift it
 * (ARCHITECTURE.md section 2). `Meter__c` is Private OWD. `selectRegisterByIds` is called
 * from the `Utility_Bill__c` trigger path, where the running user is the person saving the
 * bill - and a bill is a master-detail child of the meter, so anyone who can save the bill
 * can by construction see the meter. There is therefore no sharing gap on that path and no
 * `without sharing` inner class is needed here. Contrast
 * `UtilityBillSelector.queryVarianceSweep`, which runs as a SCHEDULED user who owns nothing
 * and does need one.
 *
 * @see UtilityBillSelector
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class MeterSelector {

    /**
     * The register columns the meter list renders. Centralised so the queries below cannot
     * drift apart (AccountSelector reference pattern).
     */
    private static final String REGISTER_FIELDS = String.join(new List<String>{
        'Id', 'Name', 'Meter_Number__c', 'Utility_Type__c', 'Property_Asset__c',
        'Property_Asset__r.Property_Name__c', 'Unit__c', 'Unit__r.Suite_Number__c',
        'Utility_Account_Number__c', 'Service_Identifier__c', 'Provider_Name__c',
        'Paid_By__c', 'Paid_By_Reason__c', 'Register_Size__c', 'Register_Modulus__c',
        'Service_Status__c', 'Master_Meter__c', 'Master_Meter__r.Meter_Number__c',
        'Total_Allocated_Pct__c'
    }, ', ');

    /**
     * Every meter installed at the given properties, master meters first so a caller can
     * group sub-meters under their master without a second pass.
     *
     * USER_MODE: backs the meter register the user opened.
     *
     * @param propertyAssetIds Property_Asset__c Ids; null/empty returns an empty list.
     * @return Matching `Meter__c` ordered master-first then by meter number; never null.
     */
    public static List<Meter__c> selectByPropertyAssetIds(Set<Id> propertyAssetIds) {
        if (propertyAssetIds == null || propertyAssetIds.isEmpty()) {
            return new List<Meter__c>();
        }
        return Database.query(
            'SELECT ' + REGISTER_FIELDS + ' FROM Meter__c ' +
            'WHERE Property_Asset__c IN :propertyAssetIds ' +
            'ORDER BY Master_Meter__c NULLS FIRST, Meter_Number__c ASC NULLS LAST',
            AccessLevel.USER_MODE
        );
    }

    /**
     * Meters by Id, with the same register columns as selectByPropertyAssetIds.
     *
     * USER_MODE: backs a user-requested read.
     *
     * @param meterIds Meter Ids; null/empty returns an empty list.
     * @return Matching `Meter__c`; never null.
     */
    public static List<Meter__c> selectByIds(Set<Id> meterIds) {
        if (meterIds == null || meterIds.isEmpty()) {
            return new List<Meter__c>();
        }
        return Database.query(
            'SELECT ' + REGISTER_FIELDS + ' FROM Meter__c WHERE Id IN :meterIds',
            AccessLevel.USER_MODE
        );
    }

    /**
     * The register facts the consumption calculation needs, keyed by meter Id.
     *
     * === `WITH SYSTEM_MODE`, JUSTIFIED HERE AT ITS OWN DECLARATION (ARCHITECTURE.md s2) ===
     * This is an AUTOMATION-PATH read: it is performed on the saving user's BEHALF from the
     * `Utility_Bill__c` before-trigger, not because the user asked to look at a meter.
     * `USER_MODE` THROWS, IT DOES NOT DEGRADE - one inaccessible field raises
     * `System.QueryException: No such column`, which inside a trigger escapes as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the user's own save of a bill
     * they were perfectly entitled to save. Every DPEG persona is on `Minimum Access` and a
     * Metadata-API-deployed custom field arrives with NO FLS for any profile, System
     * Administrator included, so this is the default case for automation and not an edge
     * case. The fields read here are register PLUMBING - they are never returned to the user
     * and are used only to decide an arithmetic branch.
     *
     * SYSTEM_MODE lifts CRUD/FLS ONLY and never sharing - see the class header for why that
     * is not a gap on this particular path.
     *
     * @param meterIds Meter Ids; null/empty returns an empty map.
     * @return meterId -> `Meter__c` carrying Register_Modulus__c, Service_Identifier__c and
     *         Meter_Number__c; never null.
     */
    public static Map<Id, Meter__c> selectRegisterByIds(Set<Id> meterIds) {
        if (meterIds == null || meterIds.isEmpty()) {
            return new Map<Id, Meter__c>();
        }
        return new Map<Id, Meter__c>([
            SELECT Id, Register_Size__c, Register_Modulus__c, Service_Identifier__c,
                   Meter_Number__c, Utility_Type__c, Service_Status__c,
                   Property_Asset__c, Property_Asset__r.Property_Name__c, Unit__c
            FROM Meter__c
            WHERE Id IN :meterIds
            WITH SYSTEM_MODE
        ]);
    }

    /**
     * The meters already recorded against one property, in the shape the capture screen
     * needs to pre-fill its rows (one per unit, plus whole-building rows).
     *
     * USER_MODE: the capture screen is a user-requested read, and a user who cannot see a
     * property's meters must not be handed them by a modal.
     *
     * @param propertyAssetId The property being captured; null returns an empty list.
     * @return Meters for that property ordered by unit then meter number; never null.
     */
    public static List<Meter__c> selectForCapture(Id propertyAssetId) {
        if (propertyAssetId == null) {
            return new List<Meter__c>();
        }
        return [
            SELECT Id, Name, Meter_Number__c, Utility_Type__c, Property_Asset__c, Unit__c,
                   Unit__r.Suite_Number__c, Utility_Account_Number__c, Service_Identifier__c,
                   Provider_Name__c, Paid_By__c, Paid_By_Reason__c, Register_Size__c,
                   Service_Status__c, Master_Meter__c
            FROM Meter__c
            WHERE Property_Asset__c = :propertyAssetId
            WITH USER_MODE
            ORDER BY Unit__r.Suite_Number__c ASC NULLS FIRST, Meter_Number__c ASC NULLS LAST
        ];
    }

    /**
     * Meters sharing a service identifier (ESID) with any of the given values.
     *
     * FSD 5.10.4 makes the service identifier the DURABLE service-point id - it survives a
     * physical meter swap, where the meter number does not. This method is how the capture
     * screen can tell a user that the ESID they just typed is already on the register under
     * a different meter number, which is the signature of a device swap.
     *
     * USER_MODE: user-requested read from the capture screen.
     *
     * @param serviceIdentifiers ESIDs to match; null/empty returns an empty list.
     * @return Matching meters; never null.
     */
    public static List<Meter__c> selectByServiceIdentifiers(Set<String> serviceIdentifiers) {
        if (serviceIdentifiers == null || serviceIdentifiers.isEmpty()) {
            return new List<Meter__c>();
        }
        return [
            SELECT Id, Meter_Number__c, Service_Identifier__c, Service_Status__c,
                   Property_Asset__c, Unit__c
            FROM Meter__c
            WHERE Service_Identifier__c IN :serviceIdentifiers
            WITH USER_MODE
        ];
    }
}
