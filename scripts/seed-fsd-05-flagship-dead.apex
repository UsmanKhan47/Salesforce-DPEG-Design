/**
 * FSD demo data - Part 5: three flagship deals killed at different points in the pipeline
 * (Dead/Pass is reachable from any stage - see No_Backward_Stage_Movement's rank-0 carve-out).
 * Idempotent: skips a deal whose Opportunity Name already exists.
 */
public class FsdDead {
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
            Status = 'Qualified', LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'MEDIUM',
            First_Seen_Date__c = DateTime.now().addDays(-30), Sale_Process__c = 'Off-Market'
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
                Date_Sent__c = Date.today().addDays(-25), Date_Signed__c = Date.today().addDays(-22),
                NDA_Expiry_Date__c = Date.today().addDays(340), Method__c = 'DocuSign');
        }
    }
}

FsdDead helper = new FsdDead();

// ---------- Dead 1: killed at New (Retail) ----------
final String D1 = 'Sagebrush Village Shops';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :D1] == 0) {
    Id oppD1 = helper.convertLead('Newmark Knight Frank', D1, '9900 Sagebrush Trl, El Paso, TX', '9900 Sagebrush Trl',
        'El Paso', '79925', 'Retail', 'Retail', 7100000, 6700000, 7500000, 8.1,
        'Katie Osborne', 'katie.osborne@nmrk.com', '214-555-0198');
    update new Opportunity(Id = oppD1, StageName = 'Dead/Pass', Rejection_Reason__c = 'Wrong Market');
}

// ---------- Dead 2: killed at Underwriting - failed DD (Industrial) ----------
final String D2 = 'Pasadena Rail Spur Yard';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :D2] == 0) {
    Id oppD2 = helper.convertLead('Stream Realty Partners', D2, '4500 Red Bluff Rd, Pasadena, TX', '4500 Red Bluff Rd',
        'Pasadena', '77503', 'Industrial', 'Retail', 15600000, 14800000, 16400000, 7.4,
        'Ryan O\'Connell', 'ryan.oconnell@streamrealty.com', '512-555-0163');
    update new Opportunity(Id = oppD2, StageName = 'Under Review', CloseDate = Date.today().addMonths(3));
    helper.signPrimaryNda(oppD2);
    update new Opportunity(Id = oppD2, StageName = 'Underwriting');
    Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :oppD2 LIMIT 1];
    update new Underwriting__c(Id = uw.Id, Stage__c = 'In Progress',
        My_Price__c = 14900000, My_Cap_Rate__c = 7.6, Market_Cap_Rate__c = 7.4);
    update new Opportunity(Id = oppD2, StageName = 'Dead/Pass', Rejection_Reason__c = 'Failed DD');
}

// ---------- Dead 3: killed at LOI - price too high (Land) ----------
final String D3 = 'Comal County Land Tract';
if ([SELECT COUNT() FROM Opportunity WHERE Name = :D3] == 0) {
    Id oppD3 = helper.convertLead('Transwestern', D3, '8800 FM 306, New Braunfels, TX', '8800 FM 306',
        'New Braunfels', '78130', 'Land', 'Land', 5900000, 5500000, 6300000, null,
        'Sofia Delgado', 'sofia.delgado@transwestern.com', '469-555-0119');
    update new Opportunity(Id = oppD3, StageName = 'Under Review', CloseDate = Date.today().addMonths(3));
    helper.signPrimaryNda(oppD3);
    update new Opportunity(Id = oppD3, StageName = 'Development Review');
    Development_Feasibility_Review__c dfr = [SELECT Id FROM Development_Feasibility_Review__c WHERE Opportunity__c = :oppD3 LIMIT 1];
    update new Development_Feasibility_Review__c(Id = dfr.Id, Stage__c = 'Completed', Recommendation__c = 'Conditional');
    update new Opportunity(Id = oppD3, StageName = 'Underwriting');
    Underwriting__c uw3 = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :oppD3 LIMIT 1];
    update new Underwriting__c(Id = uw3.Id, Stage__c = 'Approved',
        My_Price__c = 5600000, My_Cap_Rate__c = 0, Market_Cap_Rate__c = 0);
    update new Opportunity(Id = oppD3, UW_Approved__c = true, UW_Approval_Date__c = Date.today().addDays(-8));
    update new Opportunity(Id = oppD3, StageName = 'LOI');
    LOI__c loi3 = [SELECT Id FROM LOI__c WHERE Opportunity__c = :oppD3 LIMIT 1];
    update new LOI__c(Id = loi3.Id, Stage__c = 'Negotiation', LOI_Status__c = 'Killed', Ball_In_Court__c = 'Seller',
        Offer_Price__c = 5600000, Submitted_Date__c = Date.today().addDays(-10),
        Counter_Price__c = 6250000, Counter_Received_Date__c = Date.today().addDays(-4));
    update new Opportunity(Id = oppD3, StageName = 'Dead/Pass', Rejection_Reason__c = 'Price Too High');
}

System.debug('Flagship Dead/Pass deals complete.');
