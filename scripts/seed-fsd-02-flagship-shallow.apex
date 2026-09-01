/**
 * FSD demo data - Part 2: flagship Lead->Opportunity conversions walked through the
 * REAL stage-entry pipeline (OpportunityReviewService auto-creates NDA/Development-Review/
 * Construction-Review/Underwriting/LOI children on stage entry) up to a SHALLOW target
 * stage each (New, Under Review, Development Review, Construction Review, Underwriting, LOI).
 * Idempotent: skips a deal whose Opportunity Name already exists.
 */
public class FsdShallow {
    public Id convertLead(String company, String propName, String addr, String street,
            String city, String postal, String assetType, String dealType, Decimal price,
            Decimal priceLow, Decimal priceHigh, Decimal capRate, String brokerName,
            String brokerEmail, String phone) {
        Integer sp = brokerName.lastIndexOf(' ');
        Lead ld = new Lead(
            FirstName = sp > 0 ? brokerName.substring(0, sp) : brokerName,
            LastName = sp > 0 ? brokerName.substring(sp + 1) : brokerName,
            Company = company,
            Property_Name__c = propName,
            Property_Address__c = addr,
            Street = street, City = city, State = 'TX', PostalCode = postal,
            Asset_Type__c = assetType, Deal_Type__c = dealType,
            Guidance_Price__c = price, Guidance_Price_Low__c = priceLow, Guidance_Price_High__c = priceHigh,
            Guidance_Cap_Rate__c = capRate,
            Listing_Broker_Name__c = brokerName, Listing_Broker_Email__c = brokerEmail,
            Broker_First__c = brokerName, Phone = phone, Email = brokerEmail,
            Status = 'Qualified', LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'HIGH',
            First_Seen_Date__c = DateTime.now().addDays(-10), Sale_Process__c = 'Off-Market'
        );
        insert ld;
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(ld.Id);
        lc.setOpportunityName(propName);
        lc.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel);
        lc.setBypassContactDedupeCheck(true);
        lc.setBypassAccountDedupeCheck(true);
        Database.LeadConvertResult lcr = Database.convertLead(lc);
        System.assert(lcr.isSuccess(), 'Lead conversion failed for ' + propName);
        return lcr.getOpportunityId();
    }

    public void signPrimaryNda(Id oppId) {
        Opportunity o = [SELECT Primary_NDA__c FROM Opportunity WHERE Id = :oppId];
        if (o.Primary_NDA__c != null) {
            update new NDA__c(Id = o.Primary_NDA__c, Status__c = 'Signed', NDA_Signed__c = true,
                Date_Sent__c = Date.today().addDays(-9), Date_Signed__c = Date.today().addDays(-6),
                NDA_Expiry_Date__c = Date.today().addDays(359), Method__c = 'DocuSign');
        }
    }

    public void progressNda(Id oppId, String status) {
        Opportunity o = [SELECT Primary_NDA__c FROM Opportunity WHERE Id = :oppId];
        if (o.Primary_NDA__c != null) {
            NDA__c n = new NDA__c(Id = o.Primary_NDA__c, Status__c = status, Method__c = 'DocuSign');
            if (status == 'Sent') { n.Date_Sent__c = Date.today().addDays(-3); }
            if (status == 'Received') { n.Date_Sent__c = Date.today().addDays(-6); n.Date_Received__c = Date.today().addDays(-2); }
            update n;
        }
    }
}

FsdShallow helper = new FsdShallow();

// ---------- Flagship 1: New stage (Retail) ----------
final String N1 = 'Magnolia Ridge Shopping Center';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N1] == 0) {
    helper.convertLead('Colliers Houston', N1, '9200 Westheimer Rd, Houston, TX', '9200 Westheimer Rd',
        'Houston', '77063', 'Retail', 'Retail', 16800000, 16000000, 17600000, 6.6,
        'Derek Simmons', 'derek.simmons@colliers.com', '713-555-0142');
    // stays at New - no action needed, NDA auto-created at Pending
}

// ---------- Flagship 2: Under Review (Land) ----------
final String N2 = 'Prairie Vista Land Assemblage';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N2] == 0) {
    Id opp2 = helper.convertLead('Transwestern', N2, '5100 CR 205, Georgetown, TX', '5100 CR 205',
        'Georgetown', '78626', 'Land', 'Land', 6200000, 5800000, 6600000, null,
        'Sofia Delgado', 'sofia.delgado@transwestern.com', '469-555-0119');
    update new Opportunity(Id = opp2, StageName = 'Under Review', CloseDate = Date.today().addMonths(4));
    // 'Sent' was REMOVED from the Acquisition_NDA record type on 2026-08-27 (user decision);
    // this NDA is acquisition-side, so 'Sent' now throws INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST
    // and rolls this whole seed back. The acquisition sequence is Pending -> Received -> Signed.
    // progressNda already stamps both Date_Sent__c and Date_Received__c for 'Received'.
    helper.progressNda(opp2, 'Received');
}

// ---------- Flagship 3: Development Review (Land) ----------
final String N3 = 'Cedar Hollow Business Park Land';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N3] == 0) {
    Id opp3 = helper.convertLead('Stream Realty Partners', N3, '14700 FM 1826, Austin, TX', '14700 FM 1826',
        'Austin', '78737', 'Land', 'Land', 8900000, 8400000, 9400000, null,
        'Ryan O\'Connell', 'ryan.oconnell@streamrealty.com', '512-555-0163');
    update new Opportunity(Id = opp3, StageName = 'Under Review', CloseDate = Date.today().addMonths(4));
    helper.progressNda(opp3, 'Received');
    update new Opportunity(Id = opp3, StageName = 'Development Review');
    Development_Feasibility_Review__c dfr = [SELECT Id FROM Development_Feasibility_Review__c WHERE Opportunity__c = :opp3 LIMIT 1];
    update new Development_Feasibility_Review__c(
        Id = dfr.Id, Stage__c = 'Vendor proposals', Proposals_Target__c = '3', Proposals_Received__c = 2,
        Flood_Plain_Risk__c = 'None', Zoning_PD_Approval__c = 'Required'
    );
}

// ---------- Flagship 4: Construction Review (Retail) ----------
final String N4 = 'Brookhaven Retail Center';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N4] == 0) {
    Id opp4 = helper.convertLead('Cushman & Wakefield Dallas', N4, '7400 Brookhaven Club Dr, Dallas, TX', '7400 Brookhaven Club Dr',
        'Dallas', '75230', 'Retail', 'Retail', 13400000, 12800000, 14000000, 6.9,
        'Priya Nair', 'priya.nair@cushwake.com', '214-555-0187');
    update new Opportunity(Id = opp4, StageName = 'Under Review', CloseDate = Date.today().addMonths(4));
    helper.signPrimaryNda(opp4);
    update new Opportunity(Id = opp4, StageName = 'Construction Review');
    Construction_Feasibility_Review__c cfr = [SELECT Id FROM Construction_Feasibility_Review__c WHERE Opportunity__c = :opp4 LIMIT 1];
    update new Construction_Feasibility_Review__c(
        Id = cfr.Id, Stage__c = 'Condition Assessment', Roof_Age_Years__c = 9, Roof_Condition__c = 'Fair',
        HVAC_MEP_Condition__c = 'Fair', Overall_Condition_Rating__c = 'Good'
    );
}

// ---------- Flagship 5: Underwriting (Retail) ----------
final String N5 = 'Timber Creek Distribution Center';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N5] == 0) {
    Id opp5 = helper.convertLead('Matthews Real Estate Investment Services', N5, '3100 Timber Creek Rd, Fort Worth, TX', '3100 Timber Creek Rd',
        'Fort Worth', '76119', 'Industrial', 'Retail', 24500000, 23200000, 25800000, 6.5,
        'Marcus Whitfield', 'marcus.whitfield@matthews.com', '972-555-0154');
    update new Opportunity(Id = opp5, StageName = 'Under Review', CloseDate = Date.today().addMonths(3));
    helper.signPrimaryNda(opp5);
    update new Opportunity(Id = opp5, StageName = 'Underwriting');
    Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :opp5 LIMIT 1];
    update new Underwriting__c(
        Id = uw.Id, Stage__c = 'In Progress', Status__c = 'In Progress',
        My_Price__c = 23800000, My_Cap_Rate__c = 6.6, Market_Cap_Rate__c = 6.5,
        Underwritten_NOI__c = 1570800, Target_Return__c = 16.5, Hold_Period__c = 7,
        Equity_Required__c = 7140000, Projected_Loan__c = 16660000
    );
}

// ---------- Flagship 6: LOI (Land) ----------
final String N6 = 'Rolling Meadows Land Portfolio';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N6] == 0) {
    Id opp6 = helper.convertLead('Newmark Knight Frank', N6, '2200 Rolling Meadows Dr, New Braunfels, TX', '2200 Rolling Meadows Dr',
        'New Braunfels', '78132', 'Land', 'Land', 10600000, 10100000, 11100000, null,
        'Katie Osborne', 'katie.osborne@nmrk.com', '214-555-0198');
    update new Opportunity(Id = opp6, StageName = 'Under Review', CloseDate = Date.today().addMonths(3));
    helper.signPrimaryNda(opp6);
    update new Opportunity(Id = opp6, StageName = 'Development Review');
    Development_Feasibility_Review__c dfr6 = [SELECT Id FROM Development_Feasibility_Review__c WHERE Opportunity__c = :opp6 LIMIT 1];
    update new Development_Feasibility_Review__c(Id = dfr6.Id, Stage__c = 'Completed', Recommendation__c = 'Go');
    update new Opportunity(Id = opp6, StageName = 'Underwriting');
    Underwriting__c uw6 = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :opp6 LIMIT 1];
    update new Underwriting__c(Id = uw6.Id, Stage__c = 'Approved', Status__c = 'Approved by Principals',
        My_Price__c = 10400000, My_Cap_Rate__c = 0, Market_Cap_Rate__c = 0,
        Target_Return__c = 19, Hold_Period__c = 4, Equity_Required__c = 3120000, Projected_Loan__c = 7280000);
    update new Opportunity(Id = opp6, UW_Approved__c = true, UW_Approval_Date__c = Date.today().addDays(-2));
    update new Opportunity(Id = opp6, StageName = 'LOI');
    LOI__c loi6 = [SELECT Id FROM LOI__c WHERE Opportunity__c = :opp6 LIMIT 1];
    update new LOI__c(
        Id = loi6.Id, Stage__c = 'Negotiation', LOI_Status__c = 'Countered', Ball_In_Court__c = 'Seller',
        Offer_Price__c = 10100000, Offer_Cap_Rate__c = 0, Submitted_Date__c = Date.today().addDays(-8),
        Counter_Price__c = 10450000, Counter_Received_Date__c = Date.today().addDays(-3),
        Counter_Response_Due__c = Date.today().addDays(4), Earnest_Money__c = 101000, Due_Diligence_Days__c = 45
    );
    insert new List<Counter_Offer__c>{
        new Counter_Offer__c(LOI__c = loi6.Id, Direction__c = 'Ours', Counter_Price__c = 10100000, Counter_Date__c = Date.today().addDays(-8), Revision_Number__c = 'v1'),
        new Counter_Offer__c(LOI__c = loi6.Id, Direction__c = 'Seller', Counter_Price__c = 10450000, Counter_Date__c = Date.today().addDays(-3), Revision_Number__c = 'v2')
    };
}

System.debug('Flagship shallow deals complete.');
