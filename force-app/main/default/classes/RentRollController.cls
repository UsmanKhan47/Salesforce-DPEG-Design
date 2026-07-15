/**
 * Backs the rentRoll LWC on the Property Asset record page. Unit__c/Rent_Step__c are a
 * read-only mirror of Yardi (dummy-seeded until the nightly sync exists); this controller
 * only reads and aggregates. All display formatting happens client-side.
 */
public with sharing class RentRollController {

    public class StepDTO {
        @AuraEnabled public Date periodStart;
        @AuraEnabled public Date periodEnd;
        @AuraEnabled public String periodLabel;
        @AuraEnabled public Decimal monthlyRent;
        @AuraEnabled public Decimal rentPsf;
        @AuraEnabled public String stepType;
        @AuraEnabled public String note;
    }

    public class UnitDTO {
        @AuraEnabled public Id unitId;
        @AuraEnabled public String suite;
        @AuraEnabled public String tenant;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal squareFeet;
        @AuraEnabled public Date leaseStart;
        @AuraEnabled public Date leaseEnd;
        @AuraEnabled public Decimal currentRent;
        @AuraEnabled public Decimal currentRentPsf;
        @AuraEnabled public Decimal askingRentPsf;
        @AuraEnabled public Decimal estimatedNnnPsf;
        @AuraEnabled public Decimal nnnTax;
        @AuraEnabled public Decimal nnnInsurance;
        @AuraEnabled public Decimal nnnCam;
        @AuraEnabled public Decimal nnnMonthlyTotal;
        @AuraEnabled public Decimal nnnPsf;
        @AuraEnabled public List<StepDTO> steps = new List<StepDTO>();
    }

    public class SummaryDTO {
        @AuraEnabled public Decimal totalSqFt = 0;
        @AuraEnabled public Decimal occupiedSqFt = 0;
        @AuraEnabled public Decimal vacantSqFt = 0;
        @AuraEnabled public Decimal occupiedPct;
        @AuraEnabled public Decimal vacantPct;
        @AuraEnabled public Decimal monthlyRent = 0;
        @AuraEnabled public Decimal blendedPsf;
        @AuraEnabled public Decimal nnnMonthlyTotal = 0;
        @AuraEnabled public Integer occupiedCount = 0;
        @AuraEnabled public Integer vacantCount = 0;
        @AuraEnabled public Datetime lastSynced;
    }

    public class RentRollDTO {
        @AuraEnabled public SummaryDTO summary = new SummaryDTO();
        @AuraEnabled public List<UnitDTO> units = new List<UnitDTO>();
    }

    @AuraEnabled(cacheable=true)
    public static RentRollDTO getRentRoll(Id propertyAssetId) {
        RentRollDTO dto = new RentRollDTO();
        if (propertyAssetId == null) {
            return dto;
        }

        for (Unit__c u : [
            SELECT Id, Suite_Number__c, Tenant_Name__c, Status__c, Square_Feet__c,
                   Lease_Start__c, Lease_End__c, Current_Monthly_Rent__c, Current_Rent_PSF__c,
                   Asking_Rent_PSF__c, Estimated_NNN_PSF__c, NNN_Property_Tax__c,
                   NNN_Insurance__c, NNN_CAM__c, NNN_Monthly_Total__c, NNN_PSF__c,
                   LastModifiedDate,
                   (SELECT Period_Start__c, Period_End__c, Period_Label__c, Monthly_Rent__c,
                           Rent_PSF__c, Type__c, Note__c
                    FROM Rent_Steps__r
                    ORDER BY Sort_Order__c ASC NULLS LAST)
            FROM Unit__c
            WHERE Property_Asset__c = :propertyAssetId
            ORDER BY Suite_Number__c ASC NULLS LAST
        ]) {
            UnitDTO ud = new UnitDTO();
            ud.unitId = u.Id;
            ud.suite = u.Suite_Number__c;
            ud.tenant = u.Tenant_Name__c;
            ud.status = u.Status__c;
            ud.squareFeet = u.Square_Feet__c;
            ud.leaseStart = u.Lease_Start__c;
            ud.leaseEnd = u.Lease_End__c;
            ud.currentRent = u.Current_Monthly_Rent__c;
            ud.currentRentPsf = u.Current_Rent_PSF__c;
            ud.askingRentPsf = u.Asking_Rent_PSF__c;
            ud.estimatedNnnPsf = u.Estimated_NNN_PSF__c;
            ud.nnnTax = u.NNN_Property_Tax__c;
            ud.nnnInsurance = u.NNN_Insurance__c;
            ud.nnnCam = u.NNN_CAM__c;
            ud.nnnMonthlyTotal = u.NNN_Monthly_Total__c;
            ud.nnnPsf = u.NNN_PSF__c;
            for (Rent_Step__c s : u.Rent_Steps__r) {
                StepDTO sd = new StepDTO();
                sd.periodStart = s.Period_Start__c;
                sd.periodEnd = s.Period_End__c;
                sd.periodLabel = s.Period_Label__c;
                sd.monthlyRent = s.Monthly_Rent__c;
                sd.rentPsf = s.Rent_PSF__c;
                sd.stepType = s.Type__c;
                sd.note = s.Note__c;
                ud.steps.add(sd);
            }
            dto.units.add(ud);

            Decimal sqFt = u.Square_Feet__c == null ? 0 : u.Square_Feet__c;
            dto.summary.totalSqFt += sqFt;
            if (u.Status__c == 'Occupied') {
                dto.summary.occupiedCount++;
                dto.summary.occupiedSqFt += sqFt;
                if (u.Current_Monthly_Rent__c != null) {
                    dto.summary.monthlyRent += u.Current_Monthly_Rent__c;
                }
                // NNN total is occupied-only by design: vacant units carry only Estimated_NNN_PSF__c.
                if (u.NNN_Monthly_Total__c != null) {
                    dto.summary.nnnMonthlyTotal += u.NNN_Monthly_Total__c;
                }
            } else {
                dto.summary.vacantCount++;
                dto.summary.vacantSqFt += sqFt;
            }
            if (dto.summary.lastSynced == null || u.LastModifiedDate > dto.summary.lastSynced) {
                dto.summary.lastSynced = u.LastModifiedDate;
            }
        }

        if (dto.summary.totalSqFt > 0) {
            dto.summary.occupiedPct = (dto.summary.occupiedSqFt * 100 / dto.summary.totalSqFt).setScale(1);
            dto.summary.vacantPct = (dto.summary.vacantSqFt * 100 / dto.summary.totalSqFt).setScale(1);
        }
        if (dto.summary.occupiedSqFt > 0 && dto.summary.monthlyRent > 0) {
            dto.summary.blendedPsf = (dto.summary.monthlyRent * 12 / dto.summary.occupiedSqFt).setScale(2);
        }
        return dto;
    }
}