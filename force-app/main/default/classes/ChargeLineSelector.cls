/**
 * Selector for `Charge_Line__c` - encapsulates ALL SOQL against the per-component charge
 * lines of a utility bill, per ARCHITECTURE.md section 2 and
 * `.claude/rules/apex-layering-rule.md`.
 *
 * FSD 5.10.3: components vary by utility and appear irregularly (electricity: energy,
 * pass-through, taxes; water: surface water, wastewater, stormwater, grease trap, fire),
 * which is why they are child rows and not fixed columns on the bill.
 *
 * MODE - every method here is USER_MODE. Charge lines exist only to be READ BY A PERSON
 * during the monthly review; no automation path consumes them (the bill's own
 * `Total_Charges_Amount__c` roll-up is what the variance formulas use, and a roll-up is
 * maintained by the platform, not by Apex). There is therefore no automation read to
 * justify SYSTEM_MODE for, and adding one speculatively would remove an FLS check for no
 * caller.
 *
 * SHARING - `with sharing`, inherited by every method. `Charge_Line__c` is
 * ControlledByParent of `Utility_Bill__c`, which is ControlledByParent of the Private
 * `Meter__c`, so visibility follows the meter. That is the intended posture.
 */
public with sharing class ChargeLineSelector {

    /**
     * Every charge component on the given bills, largest amount first so the driver of a
     * variance is the first row a reviewer sees.
     *
     * @param billIds Utility_Bill__c Ids; null/empty returns an empty list.
     * @return Matching charge lines ordered by bill then descending amount; never null.
     */
    public static List<Charge_Line__c> selectByBillIds(Set<Id> billIds) {
        if (billIds == null || billIds.isEmpty()) {
            return new List<Charge_Line__c>();
        }
        return [
            SELECT Id, Name, Utility_Bill__c, Charge_Type__c, Charge_Amount__c
            FROM Charge_Line__c
            WHERE Utility_Bill__c IN :billIds
            WITH USER_MODE
            ORDER BY Utility_Bill__c ASC, Charge_Amount__c DESC NULLS LAST, Id ASC
        ];
    }
}
