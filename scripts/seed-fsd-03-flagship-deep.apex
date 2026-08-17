/**
 * FSD demo data - Part 3: flagship deals walked all the way to Under Contract (PSA),
 * About to Close, and Closed Won - the deepest stages, exercising every validation-rule
 * gate (NDA signed, UW approved, LOI approved+Signed, Contract executed/signed).
 * Idempotent: skips a deal whose Opportunity Name already exists.
 */
public class FsdDeep {
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
            First_Seen_Date__c = DateTime.now().addDays(-20), Sale_Process__c = 'Off-Market'
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
                Date_Sent__c = Date.today().addDays(-18), Date_Signed__c = Date.today().addDays(-15),
                NDA_Expiry_Date__c = Date.today().addDays(350), Method__c = 'DocuSign');
        }
    }

    // Walks New -> Under Review -> Underwriting -> LOI (Signed) -> Under Contract (PSA).
    // Returns the Contract_Review__c Id created on entry to Under Contract (PSA).
    public Id walkToPsa(Id oppId, Decimal uwPrice, Decimal loiOfferPrice, Decimal loiFinalPrice) {
        update new Opportunity(Id = oppId, StageName = 'Under Review', CloseDate = Date.today().addMonths(3));
        signPrimaryNda(oppId);
        update new Opportunity(Id = oppId, StageName = 'Underwriting');
        Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :oppId LIMIT 1];
        update new Underwriting__c(Id = uw.Id, Stage__c = 'Approved', Status__c = 'Approved by Principals',
            My_Price__c = uwPrice, Target_Return__c = 17, Hold_Period__c = 5,
            Equity_Required__c = uwPrice * 0.3, Projected_Loan__c = uwPrice * 0.7);
        update new Opportunity(Id = oppId, UW_Approved__c = true, UW_Approval_Date__c = Date.today().addDays(-5));
        update new Opportunity(Id = oppId, StageName = 'LOI');
        LOI__c loi = [SELECT Id FROM LOI__c WHERE Opportunity__c = :oppId LIMIT 1];
        update new LOI__c(Id = loi.Id, Stage__c = 'Signed', LOI_Status__c = 'Signed', Ball_In_Court__c = 'Us',
            Offer_Price__c = loiOfferPrice, Submitted_Date__c = Date.today().addDays(-12),
            Counter_Price__c = loiFinalPrice, Counter_Received_Date__c = Date.today().addDays(-9),
            Final_Agreed_Price__c = loiFinalPrice, LOI_Signed__c = true,
            LOI_Signed_Date__c = Date.today().addDays(-4), Approved_Date__c = Date.today().addDays(-5),
            Earnest_Money__c = loiFinalPrice * 0.01, Due_Diligence_Days__c = 45);
        // Primary_LOI__c is normally back-stamped async (LoiPrimaryStampQueueable), which will
        // not have run yet inside this same synchronous script execution - stamp it directly so
        // the PSA-entry gates (Approved_LOI_Before_PSA / Completed_LOI_Before_PSA) can see it.
        update new Opportunity(Id = oppId, Primary_LOI__c = loi.Id, LOI_Approved__c = true,
            LOI_Prep_Approved__c = true, LOI_Prep_Approval_Date__c = Date.today().addDays(-4));
        update new Opportunity(Id = oppId, StageName = 'Under Contract (PSA)');
        Contract_Review__c cr = [SELECT Id FROM Contract_Review__c WHERE Opportunity__c = :oppId LIMIT 1];
        return cr.Id;
    }
}

FsdDeep helper = new FsdDeep();

// ---------- Flagship 7: Under Contract (PSA) - stays in Negotiation (Retail) ----------
final String N7 = 'Sunridge Marketplace';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N7] == 0) {
    Id opp7 = helper.convertLead('Cushman & Wakefield Dallas', N7, '4800 Sunridge Blvd, Frisco, TX', '4800 Sunridge Blvd',
        'Frisco', '75034', 'Retail', 'Retail', 19800000, 18900000, 20700000, 6.3,
        'Priya Nair', 'priya.nair@cushwake.com', '214-555-0187');
    Id cr7 = helper.walkToPsa(opp7, 19200000, 19400000, 19750000);
    update new Contract_Review__c(Id = cr7, Negotiation_Status__c = 'Negotiation', Ball_In_Court__c = 'Seller',
        Contract_Value__c = 19750000, PSA_Date__c = Date.today().addDays(-2));
    insert new List<PSA_Version__c>{
        new PSA_Version__c(Contract_Review__c = cr7, Direction__c = 'Ours', Version_Date__c = Date.today().addDays(-6)),
        new PSA_Version__c(Contract_Review__c = cr7, Direction__c = 'Seller', Version_Date__c = Date.today().addDays(-2))
    };
}

// ---------- Flagship 8: About to Close - executed PSA (Land) ----------
final String N8 = 'Whispering Pines Commerce Park';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :N8] == 0) {
    Id opp8 = helper.convertLead('Matthews Real Estate Investment Services', N8, '1600 Whispering Pines Trl, Conroe, TX', '1600 Whispering Pines Trl',
        'Conroe', '77304', 'Land', 'Land', 8300000, 7900000, 8700000, null,
        'Marcus Whitfield', 'marcus.whitfield@matthews.com', '972-555-0154');
    Id cr8 = helper.walkToPsa(opp8, 8000000, 8100000, 8350000);
    update new Contract_Review__c(Id = cr8, Negotiation_Status__c = 'Signed', Ball_In_Court__c = 'Us',
        Contract_Value__c = 8350000, PSA_Date__c = Date.today().addDays(-10));
    insert new List<PSA_Version__c>{
        new PSA_Version__c(Contract_Review__c = cr8, Direction__c = 'Ours', Version_Date__c = Date.today().addDays(-14)),
        new PSA_Version__c(Contract_Review__c = cr8, Direction__c = 'Seller', Version_Date__c = Date.today().addDays(-10)),
        new PSA_Version__c(Contract_Review__c = cr8, Direction__c = 'Ours', Version_Date__c = Date.today().addDays(-3))
    };
    update new Contract_Review__c(Id = cr8, Negotiation_Status__c = 'Executed', Execution_Date__c = Date.today().addDays(-1));
    update new Opportunity(Id = opp8, StageName = 'About to Close', CloseDate = Date.today().addDays(21));
}

System.debug('Flagship deep (PSA + About to Close) deals complete.');
