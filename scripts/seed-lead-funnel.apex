// Seed 15 OPEN (non-converted) demo Leads so the Acquisitions "Lead Funnel" page renders
// a realistic funnel instead of an empty list.
//
// Why this exists: DPEG-Acq-5 shipped with exactly 2 Leads and BOTH are converted.
// LeadSelector.selectRecent() filters `WHERE IsConverted = false` on purpose (a converted
// Lead auto-redirects to its Contact, so a converted row is not clickable), which left the
// recentLeads LWC empty; and both existing Leads have a null LeadSource, so all three
// channel tiles read 0. This is a DATA gap, not a code defect — nothing in
// LeadSelector / LeadFunnelController / recentLeads is changed by this script.
//
// Every field LeadFunnelController.getFunnel() reads is populated on all 15 rows:
//   Status                (New / Under Review / Qualified — 6 / 5 / 4)
//   LeadSource            (Email-to-Lead / Broker Portal / Manual Entry — 5 each; these are
//                          the exact three values CHANNEL_ORDER matches on)
//   Parse_Confidence__c   (HIGH / MEDIUM / LOW — 7 / 5 / 3; the 3 LOW drive `reviewQueue`)
//   Broker_Priority__c    (High on 3 rows, exercising the high-priority-first partition)
//   Property_Address__c   (the display name in the list — distinct Houston-area CRE addresses)
//   Guidance_Price__c, Broker_First__c, Asset_Type__c
//   First_Seen_Date__c    (1-45 days back, so the Age column shows a range; all 15 are inside
//                          the 90-day broker-protection window, so bpActive = true on every row)
// All picklist values below were verified against DPEG-Acq-5 with getDescribe().getPicklistValues()
// before this script was written — do not substitute values without re-verifying.
//
// Idempotent: deletes ONLY its own previously-seeded rows, matched on the exact
// SEED_ADDRESSES set below AND `IsConverted = false`, then re-inserts. Re-running does not
// accumulate duplicates and can never touch the 2 pre-existing converted Leads (they are
// converted, and their addresses are not in the set).
//
// Duplicate rule: the org has an ACTIVE Standard_Lead_Duplicate_Rule. Every row below has a
// unique LastName / Company / Email / Property Address, so a plain insert is attempted first;
// only if that is blocked with DUPLICATES_DETECTED does the script retry with
// DMLOptions.duplicateRuleHeader.allowSave = true. The rule itself is never weakened.
//
// Does NOT convert anything — Status stays New / Under Review / Qualified.
// Run: sf apex run --file scripts/seed-lead-funnel.apex --target-org DPEG-Acq-5

DateTime now = System.now();

// ── Stable idempotency marker: the exact address set this script owns ──────────────────
List<String> SEED_ADDRESSES = new List<String>{
    '4200 Westheimer Rd, Houston, TX 77027',
    '8815 Gulf Freeway, Houston, TX 77017',
    '1770 Sam Houston Pkwy N, Houston, TX 77043',
    '505 North Belt Dr, Houston, TX 77060',
    '12400 Katy Freeway, Houston, TX 77079',
    '300 Bay Area Blvd, Webster, TX 77598',
    '9950 Bissonnet St, Houston, TX 77036',
    '2100 W Loop South, Houston, TX 77027',
    '7600 Almeda Genoa Rd, Houston, TX 77075',
    '1450 FM 1960 Bypass, Humble, TX 77338',
    '18200 Highway 249, Houston, TX 77070',
    '3355 W Alabama St, Houston, TX 77098',
    '6100 Hillcroft Ave, Houston, TX 77081',
    '21500 Grand Pkwy, Katy, TX 77449',
    '14000 Beechnut St, Houston, TX 77083'
};

// ── 1. Clear this script's own prior rows (open leads only — converted leads are untouched) ──
List<Lead> stale = [
    SELECT Id FROM Lead
    WHERE IsConverted = false AND Property_Address__c IN :SEED_ADDRESSES
];
if (!stale.isEmpty()) {
    delete stale;
    try {
        Database.emptyRecycleBin(stale);
    } catch (Exception e) {
        System.debug(LoggingLevel.ERROR, 'LFSEED recycle-bin purge skipped: ' + e.getMessage());
    }
}
System.debug(LoggingLevel.ERROR, 'LFSEED deleted prior seed rows :: ' + stale.size());

// ── 2. Build the 15 open leads ────────────────────────────────────────────────────────
List<Lead> seeds = new List<Lead>();

// --- New (6) ---
seeds.add(new Lead(
    FirstName = 'Marcus', LastName = 'Delgado', Company = 'Delgado Retail Advisors',
    Email = 'marcus.delgado@delgadoretail.example.com', Phone = '(713) 555-0142',
    Status = 'New', LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'HIGH',
    Broker_Priority__c = 'High', Broker_First__c = 'Marcus Delgado',
    Property_Address__c = SEED_ADDRESSES[0], Asset_Type__c = 'Retail', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 12400000, Guidance_Cap_Rate__c = 6.25,
    First_Seen_Date__c = now.addDays(-2)));

seeds.add(new Lead(
    FirstName = 'Priya', LastName = 'Raman', Company = 'Gulf Coast Industrial Group',
    Email = 'priya.raman@gulfcoastind.example.com', Phone = '(713) 555-0188',
    Status = 'New', LeadSource = 'Broker Portal', Parse_Confidence__c = 'MEDIUM',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Priya Raman',
    Property_Address__c = SEED_ADDRESSES[1], Asset_Type__c = 'Industrial', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 8750000, Guidance_Cap_Rate__c = 7.10,
    First_Seen_Date__c = now.addDays(-4)));

seeds.add(new Lead(
    FirstName = 'Devin', LastName = 'Okafor', Company = 'Beltway Logistics Realty',
    Email = 'devin.okafor@beltwaylogistics.example.com', Phone = '(281) 555-0116',
    Status = 'New', LeadSource = 'Manual Entry', Parse_Confidence__c = 'LOW',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Devin Okafor',
    Property_Address__c = SEED_ADDRESSES[2], Asset_Type__c = 'Industrial', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 21900000, Guidance_Cap_Rate__c = 6.80,
    First_Seen_Date__c = now.addDays(-6)));

seeds.add(new Lead(
    FirstName = 'Alicia', LastName = 'Nunez', Company = 'North Belt Office Partners',
    Email = 'alicia.nunez@northbeltoffice.example.com', Phone = '(281) 555-0173',
    Status = 'New', LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'HIGH',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Alicia Nunez',
    Property_Address__c = SEED_ADDRESSES[3], Asset_Type__c = 'Office', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 16250000, Guidance_Cap_Rate__c = 8.05,
    First_Seen_Date__c = now.addDays(-9)));

seeds.add(new Lead(
    FirstName = 'Grant', LastName = 'Whitmore', Company = 'Energy Corridor Capital',
    Email = 'grant.whitmore@energycorridorcap.example.com', Phone = '(832) 555-0121',
    Status = 'New', LeadSource = 'Broker Portal', Parse_Confidence__c = 'HIGH',
    Broker_Priority__c = 'High', Broker_First__c = 'Grant Whitmore',
    Property_Address__c = SEED_ADDRESSES[4], Asset_Type__c = 'Retail', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 34000000, Guidance_Cap_Rate__c = 5.90,
    First_Seen_Date__c = now.addDays(-12)));

seeds.add(new Lead(
    FirstName = 'Sofia', LastName = 'Bertrand', Company = 'Bay Area Mixed-Use Holdings',
    Email = 'sofia.bertrand@bayareamixeduse.example.com', Phone = '(281) 555-0159',
    Status = 'New', LeadSource = 'Manual Entry', Parse_Confidence__c = 'MEDIUM',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Sofia Bertrand',
    Property_Address__c = SEED_ADDRESSES[5], Asset_Type__c = 'Mixed-Use', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 6300000, Guidance_Cap_Rate__c = 7.45,
    First_Seen_Date__c = now.addDays(-15)));

// --- Under Review (5) ---
seeds.add(new Lead(
    FirstName = 'Hector', LastName = 'Salinas', Company = 'Bissonnet Commercial Brokers',
    Email = 'hector.salinas@bissonnetcre.example.com', Phone = '(713) 555-0134',
    Status = 'Under Review', LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'MEDIUM',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Hector Salinas',
    Property_Address__c = SEED_ADDRESSES[6], Asset_Type__c = 'Retail', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 4150000, Guidance_Cap_Rate__c = 8.30,
    First_Seen_Date__c = now.addDays(-18)));

seeds.add(new Lead(
    FirstName = 'Renee', LastName = 'Caldwell', Company = 'West Loop Tower Advisors',
    Email = 'renee.caldwell@westlooptower.example.com', Phone = '(713) 555-0197',
    Status = 'Under Review', LeadSource = 'Broker Portal', Parse_Confidence__c = 'HIGH',
    Broker_Priority__c = 'High', Broker_First__c = 'Renee Caldwell',
    Property_Address__c = SEED_ADDRESSES[7], Asset_Type__c = 'Office', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 28600000, Guidance_Cap_Rate__c = 6.60,
    First_Seen_Date__c = now.addDays(-21)));

seeds.add(new Lead(
    FirstName = 'Tomas', LastName = 'Vega', Company = 'Almeda Genoa Distribution Realty',
    Email = 'tomas.vega@almedagenoa.example.com', Phone = '(713) 555-0165',
    Status = 'Under Review', LeadSource = 'Manual Entry', Parse_Confidence__c = 'LOW',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Tomas Vega',
    Property_Address__c = SEED_ADDRESSES[8], Asset_Type__c = 'Industrial', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 11050000, Guidance_Cap_Rate__c = 7.25,
    First_Seen_Date__c = now.addDays(-25)));

seeds.add(new Lead(
    FirstName = 'Bianca', LastName = 'Ortiz', Company = 'Humble Crossing Retail LLC',
    Email = 'bianca.ortiz@humblecrossing.example.com', Phone = '(281) 555-0148',
    Status = 'Under Review', LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'HIGH',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Bianca Ortiz',
    Property_Address__c = SEED_ADDRESSES[9], Asset_Type__c = 'Retail', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 5900000, Guidance_Cap_Rate__c = 8.75,
    First_Seen_Date__c = now.addDays(-28)));

seeds.add(new Lead(
    FirstName = 'Curtis', LastName = 'Lambert', Company = 'Highway 249 Land Company',
    Email = 'curtis.lambert@hwy249land.example.com', Phone = '(832) 555-0182',
    Status = 'Under Review', LeadSource = 'Broker Portal', Parse_Confidence__c = 'MEDIUM',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Curtis Lambert',
    Property_Address__c = SEED_ADDRESSES[10], Asset_Type__c = 'Land', Deal_Type__c = 'Land',
    Guidance_Price__c = 2450000, Guidance_Cap_Rate__c = null,
    First_Seen_Date__c = now.addDays(-31)));

// --- Qualified (4) ---
seeds.add(new Lead(
    FirstName = 'Naomi', LastName = 'Frazier', Company = 'Upper Kirby Residential Partners',
    Email = 'naomi.frazier@upperkirbyres.example.com', Phone = '(713) 555-0109',
    Status = 'Qualified', LeadSource = 'Manual Entry', Parse_Confidence__c = 'HIGH',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Naomi Frazier',
    Property_Address__c = SEED_ADDRESSES[11], Asset_Type__c = 'Multifamily', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 39750000, Guidance_Cap_Rate__c = 5.40,
    First_Seen_Date__c = now.addDays(-34)));

seeds.add(new Lead(
    FirstName = 'Elliot', LastName = 'Nakamura', Company = 'Hillcroft Professional Plaza Group',
    Email = 'elliot.nakamura@hillcroftplaza.example.com', Phone = '(713) 555-0176',
    Status = 'Qualified', LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'LOW',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Elliot Nakamura',
    Property_Address__c = SEED_ADDRESSES[12], Asset_Type__c = 'Office', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 9200000, Guidance_Cap_Rate__c = 8.90,
    First_Seen_Date__c = now.addDays(-37)));

seeds.add(new Lead(
    FirstName = 'Vanessa', LastName = 'Cho', Company = 'Grand Parkway Development Realty',
    Email = 'vanessa.cho@grandpkwydev.example.com', Phone = '(281) 555-0193',
    Status = 'Qualified', LeadSource = 'Broker Portal', Parse_Confidence__c = 'MEDIUM',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Vanessa Cho',
    Property_Address__c = SEED_ADDRESSES[13], Asset_Type__c = 'Land', Deal_Type__c = 'Land',
    Guidance_Price__c = 3800000, Guidance_Cap_Rate__c = null,
    First_Seen_Date__c = now.addDays(-41)));

seeds.add(new Lead(
    FirstName = 'Jorge', LastName = 'Medina', Company = 'Beechnut Shopping Center Partners',
    Email = 'jorge.medina@beechnutcenter.example.com', Phone = '(832) 555-0127',
    Status = 'Qualified', LeadSource = 'Manual Entry', Parse_Confidence__c = 'HIGH',
    Broker_Priority__c = 'Standard', Broker_First__c = 'Jorge Medina',
    Property_Address__c = SEED_ADDRESSES[14], Asset_Type__c = 'Retail', Deal_Type__c = 'Commercial',
    Guidance_Price__c = 18300000, Guidance_Cap_Rate__c = 6.95,
    First_Seen_Date__c = now.addDays(-45)));

// ── 3. Insert — plain first; fall back to allowSave only if the duplicate rule blocks ──
Boolean usedAllowSave = false;
try {
    insert seeds;
} catch (DmlException e) {
    if (!e.getMessage().contains('DUPLICATES_DETECTED')) {
        throw e;
    }
    usedAllowSave = true;
    Database.DMLOptions dmo = new Database.DMLOptions();
    dmo.DuplicateRuleHeader.AllowSave = true;   // bypass for THIS insert only; rule stays active
    dmo.OptAllOrNone = true;
    Database.insert(seeds, dmo);
}

// ── 4. Report ─────────────────────────────────────────────────────────────────────────
System.debug(LoggingLevel.ERROR, 'LFSEED inserted :: ' + seeds.size()
    + ' | duplicateRuleAllowSaveUsed=' + usedAllowSave);
System.debug(LoggingLevel.ERROR, 'LFSEED open leads now :: '
    + [SELECT COUNT() FROM Lead WHERE IsConverted = false]);
System.debug(LoggingLevel.ERROR, 'LFSEED converted leads (must stay 2) :: '
    + [SELECT COUNT() FROM Lead WHERE IsConverted = true]);
System.debug(LoggingLevel.ERROR, 'LFSEED total leads :: ' + [SELECT COUNT() FROM Lead]);
