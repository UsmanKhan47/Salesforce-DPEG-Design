/**
 * Tests RentRollController: summary aggregation over occupied/vacant units,
 * nested step ordering, and null-safe behavior for empty/sparse data.
 */
@isTest
private class RentRollControllerTest {

    private static Property_Asset__c makeAsset() {
        Property_Asset__c pa = new Property_Asset__c(Name = 'Test Retail Center');
        insert pa;
        return pa;
    }

    @isTest
    static void summaryAggregatesOccupiedAndVacant() {
        Property_Asset__c pa = makeAsset();
        insert new List<Unit__c>{
            new Unit__c(Property_Asset__c = pa.Id, Suite_Number__c = '100', Tenant_Name__c = 'T1',
                Status__c = 'Occupied', Square_Feet__c = 2000, Current_Monthly_Rent__c = 4000,
                NNN_Monthly_Total__c = 700),
            new Unit__c(Property_Asset__c = pa.Id, Suite_Number__c = '101', Tenant_Name__c = 'T2',
                Status__c = 'Occupied', Square_Feet__c = 1000, Current_Monthly_Rent__c = 2000,
                NNN_Monthly_Total__c = 300),
            new Unit__c(Property_Asset__c = pa.Id, Suite_Number__c = '102',
                Status__c = 'Vacant', Square_Feet__c = 1000, Asking_Rent_PSF__c = 27)
        };

        RentRollController.RentRollDTO dto = RentRollController.getRentRoll(pa.Id);

        System.assertEquals(3, dto.units.size(), 'All units returned');
        System.assertEquals(4000, dto.summary.totalSqFt, 'Total sq ft sums all units');
        System.assertEquals(3000, dto.summary.occupiedSqFt, 'Occupied sq ft');
        System.assertEquals(1000, dto.summary.vacantSqFt, 'Vacant sq ft');
        System.assertEquals(75.0, dto.summary.occupiedPct, 'Occupied pct to 1dp');
        System.assertEquals(25.0, dto.summary.vacantPct, 'Vacant pct to 1dp');
        System.assertEquals(6000, dto.summary.monthlyRent, 'Rent sums occupied units only');
        System.assertEquals(24.00, dto.summary.blendedPsf, 'Blended = 6000*12/3000');
        System.assertEquals(1000, dto.summary.nnnMonthlyTotal, 'NNN total sums');
        System.assertEquals(2, dto.summary.occupiedCount, 'Occupied count');
        System.assertEquals(1, dto.summary.vacantCount, 'Vacant count');
        System.assertNotEquals(null, dto.summary.lastSynced, 'Last synced derives from units');
    }

    @isTest
    static void stepsComeBackInSortOrder() {
        Property_Asset__c pa = makeAsset();
        Unit__c u = new Unit__c(Property_Asset__c = pa.Id, Suite_Number__c = '200',
            Tenant_Name__c = 'T', Status__c = 'Occupied', Square_Feet__c = 500,
            Current_Monthly_Rent__c = 1000);
        insert u;
        insert new List<Rent_Step__c>{
            new Rent_Step__c(Unit__c = u.Id, Sort_Order__c = 2, Period_Label__c = 'Years 6-10',
                Type__c = 'Renewal Option', Note__c = 'FMR'),
            new Rent_Step__c(Unit__c = u.Id, Sort_Order__c = 1, Period_Start__c = Date.newInstance(2026, 1, 1),
                Period_End__c = Date.newInstance(2026, 12, 31), Monthly_Rent__c = 1000,
                Rent_PSF__c = 24, Type__c = 'Current Term')
        };

        RentRollController.RentRollDTO dto = RentRollController.getRentRoll(pa.Id);

        System.assertEquals(2, dto.units[0].steps.size(), 'Both steps returned');
        System.assertEquals('Current Term', dto.units[0].steps[0].stepType, 'Sort_Order__c=1 first');
        System.assertEquals('Years 6-10', dto.units[0].steps[1].periodLabel, 'Label-only step mapped');
        System.assertEquals(null, dto.units[0].steps[1].monthlyRent, 'Null rent preserved');
    }

    @isTest
    static void emptyAndNullInputsAreSafe() {
        Property_Asset__c pa = makeAsset();

        RentRollController.RentRollDTO empty = RentRollController.getRentRoll(pa.Id);
        System.assertEquals(0, empty.units.size(), 'No units -> empty list');
        System.assertEquals(0, empty.summary.totalSqFt, 'Zero total');
        System.assertEquals(null, empty.summary.occupiedPct, 'No pct on zero sq ft');
        System.assertEquals(null, empty.summary.blendedPsf, 'No blended on zero occupied');
        System.assertEquals(null, empty.summary.lastSynced, 'No sync stamp without units');

        System.assertEquals(0, RentRollController.getRentRoll(null).units.size(), 'Null id -> empty DTO');
    }
}