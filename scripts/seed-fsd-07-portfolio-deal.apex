/**
 * FSD demo data - Part 7: multi-property email demo for the Portfolio_Deal__c feature.
 * Approach (b) from the task brief: rather than actually enqueueing ExtractAddressQueueable
 * (which needs a live OpenAI callout and the full async routing tree - unreliable to script
 * by hand), this directly inserts a real Inbound_Email_Staging__c landing row (the durable,
 * synchronous artifact EmailToLeadHandler always writes first) plus a Portfolio_Deal__c
 * pointing at it via the Text-pointer Source_Staging_Id__c, then 3 open Leads sharing that
 * deal - matching the shape ExtractAddressQueueable would have produced for a genuine
 * 3-property broker email, without depending on a live LLM callout.
 * Idempotent: skips if the marker staging row already exists.
 *
 * Repointed in phase B4 of the Portfolio Deal rename (2026-08-18) - was
 * scripts/seed-fsd-07-property-package.apex, writing Property_Package__c and
 * Lead.Property_Package__c. Both the old and new objects/lookups exist until phase B5 retires the
 * old ones, so this runs correctly today and will keep running after B5. It deliberately no longer
 * seeds the OLD object at all: a freshly seeded org should look like the post-rename world.
 */
final String MARKER_SUBJECT = 'Portfolio Offering - Three South Austin Retail Assets';
if ([SELECT COUNT() FROM Inbound_Email_Staging__c WHERE Subject__c = :MARKER_SUBJECT] > 0) {
    System.debug('Portfolio Deal demo already seeded - skipping.');
} else {
    Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
        From_Address__c = 'j.reyes@austinretailpartners.com',
        From_Name__c = 'Jordan Reyes',
        Forwarded_By__c = 'j.reyes@austinretailpartners.com',
        Subject__c = MARKER_SUBJECT,
        Message_Id__c = '<pkg-demo-' + String.valueOf(Datetime.now().getTime()) + '@austinretailpartners.com>',
        Raw_Headers__c = 'From: Jordan Reyes <j.reyes@austinretailpartners.com>\nTo: deals@dpeg-demo.com\nSubject: ' + MARKER_SUBJECT,
        Raw_Body__c = 'Hi team,\n\nWe are bringing three South Austin retail assets to market together as a single portfolio offering. Details below:\n\n' +
            '1) Slaughter Lane Shopping Center - 4200 W Slaughter Ln, Austin, TX - Retail, ~$14.5M guidance, 6.6% cap\n' +
            '2) Manchaca Village Retail - 9800 Manchaca Rd, Austin, TX - Retail, ~$8.9M guidance, 6.9% cap\n' +
            '3) Southpark Meadows Pad - 9600 I-35 Frontage Rd, Austin, TX - Retail, ~$6.2M guidance, 7.1% cap\n\n' +
            'Offers due in 4 weeks. Happy to set up a call.\n\nBest,\nJordan Reyes\nAustin Retail Partners',
        Status__c = 'Processed',
        Outcome__c = 'Multi-Property (3): all 3 routed to new Leads',
        Property_Count__c = 3,
        Processed_DateTime__c = DateTime.now().addHours(-6)
    );
    insert staging;

    Portfolio_Deal__c deal = new Portfolio_Deal__c(
        Property_Count__c = 3,
        Broker_Email__c = 'j.reyes@austinretailpartners.com',
        Broker_Name__c = 'Jordan Reyes',
        Source_Staging_Id__c = staging.Id,
        Received_DateTime__c = DateTime.now().addHours(-6),
        Routed_Outcomes__c = '1) 4200 W Slaughter Ln, Austin, TX -> New Lead (winner)\n' +
            '2) 9800 Manchaca Rd, Austin, TX -> New Lead (winner)\n' +
            '3) 9600 I-35 Frontage Rd, Austin, TX -> New Lead (winner)'
    );
    insert deal;

    List<Lead> leads = new List<Lead>{
        new Lead(
            FirstName = 'Jordan', LastName = 'Reyes', Company = 'Austin Retail Partners',
            Email = 'j.reyes@austinretailpartners.com', Phone = '512-555-0177',
            Property_Name__c = 'Slaughter Lane Shopping Center', Property_Address__c = '4200 W Slaughter Ln, Austin, TX',
            Street = '4200 W Slaughter Ln', City = 'Austin', State = 'TX', PostalCode = '78749',
            Asset_Type__c = 'Retail', Deal_Type__c = 'Retail',
            Guidance_Price__c = 14500000, Guidance_Cap_Rate__c = 6.6,
            Listing_Broker_Name__c = 'Jordan Reyes', Listing_Broker_Email__c = 'j.reyes@austinretailpartners.com',
            Broker_First__c = 'Jordan Reyes', Status = 'New', LeadSource = 'Email-to-Lead',
            Parse_Confidence__c = 'HIGH', First_Seen_Date__c = DateTime.now().addHours(-6),
            Sale_Process__c = 'On-Market Listing', Offer_Due_Date__c = Date.today().addDays(28),
            Portfolio_Deal__c = deal.Id
        ),
        new Lead(
            FirstName = 'Jordan', LastName = 'Reyes', Company = 'Austin Retail Partners',
            Email = 'j.reyes@austinretailpartners.com', Phone = '512-555-0177',
            Property_Name__c = 'Manchaca Village Retail', Property_Address__c = '9800 Manchaca Rd, Austin, TX',
            Street = '9800 Manchaca Rd', City = 'Austin', State = 'TX', PostalCode = '78748',
            Asset_Type__c = 'Retail', Deal_Type__c = 'Retail',
            Guidance_Price__c = 8900000, Guidance_Cap_Rate__c = 6.9,
            Listing_Broker_Name__c = 'Jordan Reyes', Listing_Broker_Email__c = 'j.reyes@austinretailpartners.com',
            Broker_First__c = 'Jordan Reyes', Status = 'New', LeadSource = 'Email-to-Lead',
            Parse_Confidence__c = 'HIGH', First_Seen_Date__c = DateTime.now().addHours(-6),
            Sale_Process__c = 'On-Market Listing', Offer_Due_Date__c = Date.today().addDays(28),
            Portfolio_Deal__c = deal.Id
        ),
        new Lead(
            FirstName = 'Jordan', LastName = 'Reyes', Company = 'Austin Retail Partners',
            Email = 'j.reyes@austinretailpartners.com', Phone = '512-555-0177',
            Property_Name__c = 'Southpark Meadows Pad', Property_Address__c = '9600 I-35 Frontage Rd, Austin, TX',
            Street = '9600 I-35 Frontage Rd', City = 'Austin', State = 'TX', PostalCode = '78748',
            Asset_Type__c = 'Retail', Deal_Type__c = 'Retail',
            Guidance_Price__c = 6200000, Guidance_Cap_Rate__c = 7.1,
            Listing_Broker_Name__c = 'Jordan Reyes', Listing_Broker_Email__c = 'j.reyes@austinretailpartners.com',
            Broker_First__c = 'Jordan Reyes', Status = 'Under Review', LeadSource = 'Email-to-Lead',
            Parse_Confidence__c = 'MEDIUM', First_Seen_Date__c = DateTime.now().addHours(-6),
            Sale_Process__c = 'On-Market Listing', Offer_Due_Date__c = Date.today().addDays(28),
            Portfolio_Deal__c = deal.Id
        )
    };
    insert leads;

    staging.Routed_Record_Ids__c = String.join(new List<Id>{ leads[0].Id, leads[1].Id, leads[2].Id }, ',');
    staging.Result_Record_Id__c = leads[0].Id;
    update staging;

    System.debug('Portfolio Deal demo complete: deal ' + deal.Id + ', 3 Leads, staging ' + staging.Id);
}
