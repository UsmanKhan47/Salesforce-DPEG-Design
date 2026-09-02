/**
 * FSD demo data - Part 4: one flagship deal walked all the way to Closed Won, including
 * an executed PSA (triggers Transaction__c + Day-0 task fan-out) plus an Offering__c and
 * a couple of Deal_Message__c negotiation-log entries for a rich record-detail screenshot.
 * Idempotent: skips if the Opportunity already exists.
 */
public class FsdClosedWon {
    public Id convertLead(String company, String propName, String addr, String street,
            String city, String postal, String assetType, String dealType, Decimal price,
            Decimal priceLow, Decimal priceHigh, Decimal capRate, String brokerName,
            String brokerEmail, String phone) {
        Integer sp = brokerName.lastIndexOf(' ');
        Lead ld = new Lead(
            FirstName = sp > 0 ? brokerName.substring(0, sp) : brokerName,
            LastName = sp > 0 ? brokerName.substring(sp + 1) : brokerName,
            Company = company, Property_Name__c = propName, Property_Address__c = addr,
            Street = street, City = city, State = 'TX', PostalCode = postal,
            Asset_Type__c = assetType, Deal_Type__c = dealType,
            Guidance_Price__c = price, Guidance_Price_Low__c = priceLow, Guidance_Price_High__c = priceHigh,
            Guidance_Cap_Rate__c = capRate,
            Listing_Broker_Name__c = brokerName, Listing_Broker_Email__c = brokerEmail,
            Broker_First__c = brokerName, Phone = phone, Email = brokerEmail,
            Status = 'Qualified', LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'HIGH',
            First_Seen_Date__c = DateTime.now().addDays(-45), Sale_Process__c = 'Off-Market'
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
                Date_Sent__c = Date.today().addDays(-40), Date_Signed__c = Date.today().addDays(-37),
                NDA_Expiry_Date__c = Date.today().addDays(325), Method__c = 'DocuSign');
        }
    }
}

FsdClosedWon helper = new FsdClosedWon();

final String N9 = 'Copperfield Town Center';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N9] == 0) {
    Id opp9 = helper.convertLead('Colliers Houston', N9, '16700 Copperfield Blvd, Houston, TX', '16700 Copperfield Blvd',
        'Houston', '77095', 'Retail', 'Retail', 31200000, 29800000, 32600000, 6.1,
        'Derek Simmons', 'derek.simmons@colliers.com', '713-555-0142');

    update new Opportunity(Id = opp9, StageName = 'Under Review', CloseDate = Date.today().addDays(30));
    helper.signPrimaryNda(opp9);

    update new Opportunity(Id = opp9, StageName = 'Underwriting');
    Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :opp9 LIMIT 1];
    update new Underwriting__c(Id = uw.Id, Stage__c = 'Approved',
        My_Price__c = 30500000, My_Cap_Rate__c = 6.4, Market_Cap_Rate__c = 6.1,
        Underwritten_NOI__c = 1952000, Target_Return__c = 18.2, Hold_Period__c = 6,
        Equity_Required__c = 9150000, Projected_Loan__c = 21350000);
    update new Opportunity(Id = opp9, UW_Approved__c = true, UW_Approval_Date__c = Date.today().addDays(-25));

    update new Opportunity(Id = opp9, StageName = 'LOI');
    LOI__c loi = [SELECT Id FROM LOI__c WHERE Opportunity__c = :opp9 LIMIT 1];
    update new LOI__c(Id = loi.Id, Stage__c = 'Signed', LOI_Status__c = 'Signed', Ball_In_Court__c = 'Us',
        Offer_Price__c = 30500000, Submitted_Date__c = Date.today().addDays(-21),
        Counter_Price__c = 31000000, Counter_Received_Date__c = Date.today().addDays(-18),
        Final_Agreed_Price__c = 31000000, LOI_Signed__c = true, LOI_Signed_Date__c = Date.today().addDays(-14),
        Approved_Date__c = Date.today().addDays(-15), Earnest_Money__c = 310000, Due_Diligence_Days__c = 45);
    insert new List<Counter_Offer__c>{
        new Counter_Offer__c(LOI__c = loi.Id, Direction__c = 'Ours', Counter_Price__c = 30500000, Counter_Date__c = Date.today().addDays(-21), Revision_Number__c = 'v1'),
        new Counter_Offer__c(LOI__c = loi.Id, Direction__c = 'Seller', Counter_Price__c = 31000000, Counter_Date__c = Date.today().addDays(-18), Revision_Number__c = 'v2')
    };
    update new Opportunity(Id = opp9, Primary_LOI__c = loi.Id, LOI_Approved__c = true,
        LOI_Prep_Approved__c = true, LOI_Prep_Approval_Date__c = Date.today().addDays(-14));

    update new Opportunity(Id = opp9, StageName = 'Under Contract (PSA)');
    Contract_Review__c cr = [SELECT Id FROM Contract_Review__c WHERE Opportunity__c = :opp9 LIMIT 1];
    update new Contract_Review__c(Id = cr.Id, Negotiation_Status__c = 'Signed', Ball_In_Court__c = 'Us',
        Contract_Value__c = 31000000, PSA_Date__c = Date.today().addDays(-8));
    insert new List<PSA_Version__c>{
        new PSA_Version__c(Contract_Review__c = cr.Id, Direction__c = 'Ours', Version_Date__c = Date.today().addDays(-12)),
        new PSA_Version__c(Contract_Review__c = cr.Id, Direction__c = 'Seller', Version_Date__c = Date.today().addDays(-8))
    };
    update new Contract_Review__c(Id = cr.Id, Negotiation_Status__c = 'Executed', Execution_Date__c = Date.today().addDays(-3));

    update new Opportunity(Id = opp9, StageName = 'About to Close', CloseDate = Date.today().addDays(7));
    update new Opportunity(Id = opp9, StageName = 'Closed Won');

    insert new Offering__c(Opportunity__c = opp9, Status__c = 'Active');

    insert new List<Deal_Message__c>{
        new Deal_Message__c(Contract_Review__c = cr.Id, Direction__c = 'Received', Method__c = 'Email',
            Entry_DateTime__c = DateTime.now().addDays(-9),
            Details__c = 'Seller counsel confirmed title commitment issued; no exceptions requiring further review.'),
        new Deal_Message__c(Contract_Review__c = cr.Id, Direction__c = 'Sent', Method__c = 'Email',
            Entry_DateTime__c = DateTime.now().addDays(-4),
            Details__c = 'Confirmed wire instructions and closing date with title company; all conditions satisfied.')
    };
}

System.debug('Flagship Closed Won deal complete.');
