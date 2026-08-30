/**
 * Tests for LeadConvertService — the post-convert stamping site.
 *
 * ═══ WHAT THE 2026-08-03 CONVERSION-ENRICHMENT METHODS PIN ═══
 * S1 split the LLM-extracted deal-screening field set BY MEANING: deal-process facts to the
 * Opportunity, physical property facts to the Property__c. Several of the assertions below exist
 * to stop a later "helpful" change from quietly undoing a deliberate decision:
 *   • Property__c.Lot_Size__c must stay NULL — we hold ACRES only and deriving SF from acres is
 *     forbidden by this module's anti-hallucination contract.
 *   • A RANGE-priced lead must leave Asking_Price__c NULL — synthesizing a midpoint would
 *     fabricate a price.
 *   • An out-of-range restricted-picklist value must be DROPPED, not pushed — `update updates` is
 *     all-or-none, so one illegal value would roll back the structural RecordTypeId / Property__c
 *     link for every lead in the chunk.
 *   • The broker OpportunityContactRole must be exactly ONE row — standard conversion already
 *     creates it, so a blind insert would duplicate both the broker and the primary flag.
 *
 * ═══ WS2 (2026-08-30) — WHAT SECTION 2b PINS, AND THE ONE STATE IT CANNOT REACH ═══
 * Conversion now carries `Lead.First_Seen_Date__c` -> `Opportunity.Broker_First_Seen__c` and
 * `Lead.DPEG_First__c` -> `Opportunity.DPEG_First__c`, which makes a previously dead field live.
 * Two fixtures do the work: a 40-day-old first-seen instant (so a stamp using "now" or the
 * Opportunity's own CreatedDate is 40 days wrong) and a DPEG First user who is NOT the running
 * user (so `UserInfo.getUserId()` cannot masquerade as the carried value — `Lead_Intake_Stamp`
 * fills that Lead field from OwnerId, which makes the two identical on any ordinary fixture).
 *
 * ⚠ THE BOTH-BLANK CASE IS NOT TESTED AND CANNOT BE. `flows/Lead_Intake_Stamp` stamps
 * `First_Seen_Date__c` on every Lead save where it IsNull, and `Lead.Broker_First_Seen_Is_System_Set`
 * then refuses any update that blanks it — so no Lead in this org can reach conversion with that
 * field empty. `DPEG_First__c` CAN be blank (a queue-owned Lead), and that half IS tested, by
 * nulling the value on a re-read Lead rather than by building a queue-owned fixture (queue
 * membership is not deployable metadata here). Faking the first-seen blank would be testing a
 * state production cannot produce.
 *
 * ⚠ NO FLS TEST EXISTS HERE, DELIBERATELY. LeadConvertService writes in SYSTEM MODE and
 * Trigger.new is not FLS-filtered, so a `System.runAs` test asserting "the stamp lands as a
 * non-admin persona" would pass whether or not the FLS grant exists — a test that cannot fail.
 * FLS on these fields is a DISPLAY gate, not a write gate, and is verified manually as a real
 * convert-capable persona (never as an admin, whose FLS on Metadata-API-deployed custom fields is
 * not representative). See agent-output/design-requirements-conversion-enrichment.md §9.4.
 *
 * ⚠ SEVERAL METHODS RE-INVOKE THE SERVICE DIRECTLY on an already-converted Lead. That is the only
 * way to drive states the platform will not produce (an out-of-range picklist value; a second
 * pass over the same converted set; two Leads naming a building neither has created yet).
 * ⚠ AMENDED 2026-08-30 (WS3): this paragraph used to warn that "the re-run also builds a SECOND
 * Property". THAT IS NO LONGER TRUE, AND THE CHANGE IS THE FEATURE. A re-run now recomputes the
 * same normalized-address key, finds the Property the first run inserted, and REUSES it — so a
 * second pass over one converted Lead leaves the Property count at one. Only an addressless Lead
 * still gets a fresh Property on every pass (a blank address is not a key, so it can never match).
 * `reusingAPropertySpendsOneFewerDmlAndTheSameQueries` turns that difference into the assertion.
 *
 * ═══ WS3 (2026-08-30) — WHY EVERY PROPERTY READ IN THIS CLASS IS NOT PLAIN SOQL ═══
 * 🔴 Anything selecting `Property__c.Normalized_Address__c` goes through `readProperty` /
 * `readPropertiesByKey`, which use `WITH SYSTEM_MODE`. That is MANDATORY, not stylistic. The field
 * is deployed by the Metadata API and this change grants it to nobody, so it has ZERO
 * `FieldPermissions` rows — and a field nobody has been granted is not merely FLS-denied, it is
 * ABSENT from the running user's schema. A plain `[SELECT Normalized_Address__c ...]` therefore
 * throws `System.QueryException: No such column` AT RUNTIME, as a System Administrator, even though
 * the class compiled and deployed clean. Measured on this org 2026-08-24 against
 * `BOV_Submission__c.Approval_Pending__c`. Do not "simplify" those helpers back to plain SOQL.
 *
 * ⚠ NO TEST EXERCISES stampBrokerContactRoles' describe-guard SKIP PATH (the early return when
 * `OpportunityContactRole.Role` does not offer 'Broker'), and none can: `activePicklistValues()`
 * reads the LIVE org describe, which is identical in every test context to whatever is actually
 * deployed — there is no seam (unlike `EmailThreadGuardService.treatAllAsMaterialized`) that lets
 * a test force the value to appear absent. As long as the admin-deployed StandardValueSet addition
 * ships, 'Broker' is present in every test run, so the skip branch is only reachable by a deploy
 * that never added the value in the first place — a deploy-order failure, not something this suite
 * can simulate. Confirmed dead-in-test, not merely un-covered; do not add a test that fakes this by
 * asserting against a hardcoded picklist value list instead of the real describe.
 *
 * ⚠ EVERY LEAD CONVERTED HERE MUST CARRY Property_Address__c AND Email (2026-08-04). The Lead
 * validation rule Property_And_Email_Required_To_Convert refuses `Database.convertLead` when either
 * is blank, so a fixture that deliberately empties one of them no longer reaches this service at
 * all — it fails at the conversion with FIELD_CUSTOM_VALIDATION_EXCEPTION. TestDataFactory.createLead
 * supplies both, so the only exposure is a fixture that NULLS one on purpose; there is exactly one
 * such intent in this class and it is handled by
 * blankAddressLeavesTheDealNameAloneAndFallsBackToCompany, which drives the service directly rather
 * than through a conversion. Do not "simplify" that method back into a conversion — it cannot work.
 *
 * @see force-app/main/default/classes/LeadConvertService.cls
 * @see force-app/main/default/classes/OpportunityContactRoleSelector.cls
 * @see force-app/main/default/objects/Lead/validationRules/Property_And_Email_Required_To_Convert.validationRule-meta.xml
 */
@isTest
private class LeadConvertServiceTest {

    private static final Integer BULK_N = 251;

    /**
     * The minimum a Lead must carry to get PAST Property_And_Email_Required_To_Convert. Used by the
     * fixtures whose subject is what happens when everything ELSE is blank — naming it makes it
     * obvious in the assertions below which values are under test and which are gate tax.
     * Kept short so it survives both OPPORTUNITY_NAME_MAX and PROPERTY_NAME_MAX unclipped.
     */
    private static final String GATE_ADDRESS = '5 Gate Row, Austin TX';

    /** Batch size used by the governor-scaling proof; see stampCostDoesNotScaleWithBatchSize. */
    private static final Integer SCALE_N = 50;

    /**
     * Slack allowed between a 1-record and a SCALE_N-record invocation. Deliberately small: the
     * service's own cost is constant (2 SOQL / ≤5 DML — raised from ≤4 in the IR segregation
     * change, which added the Contact/Account record-type stamp), and a change that added ONE
     * query per Lead would show up as +SCALE_N-1, which no plausible tolerance hides.
     */
    private static final Integer SCALE_TOLERANCE = 5;

    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    private static Opportunity convertLeadOfType(String dealType, String company) {
        Lead l = TestDataFactory.createLead(false);
        l.LastName = 'Tester';
        l.Company = company;
        l.Deal_Type__c = dealType;
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Database.LeadConvertResult res = Database.convertLead(lc);
        System.assert(res.isSuccess(), 'Lead conversion should succeed');
        return [
            SELECT Id, Deal_Type__c, RecordType.DeveloperName
            FROM Opportunity
            WHERE Id = :res.getOpportunityId()
        ];
    }

    /** Standard single conversion (the recipe proven on this org — never setDoNotCreateOpportunity). */
    private static Database.LeadConvertResult convertOne(Lead l) {
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult res = Database.convertLead(lc);
        System.assert(res.isSuccess(), 'Lead conversion should succeed');
        return res;
    }

    /**
     * Every deal-screening value the extraction pipeline can put on a Lead, set to a distinct
     * recognisable value so a mis-mapped field shows up as the WRONG value rather than as a
     * coincidentally-equal one. Mutates and returns the lead.
     */
    private static Lead withFullDealScreening(Lead l) {
        // Deal-process facts -> Opportunity
        l.Property_Name__c = 'Orion ParkView';
        l.Property_Address__c = '1400 Royal Lane, Dallas TX 75229';
        l.Guidance_Price__c = 7100000;
        l.Guidance_Cap_Rate__c = 6.75;
        l.Offer_Due_Date__c = Date.newInstance(2026, 9, 15);
        l.Sale_Process__c = 'Call for Offers';
        l.Parse_Confidence__c = 'HIGH';
        l.Deal_Room_Link__c = 'https://deals.example.invalid/room/orion';
        l.Listing_Broker_Name__c = 'Kevin Girard';
        l.Listing_Broker_Email__c = 'kevin.girard@example.invalid';
        // Acquisition Observations phase 1 (2026-08-14) — also DEAL-PROCESS, also to the
        // Opportunity. The three score numbers are internally consistent (7 + 2 = 9, 7/9 = 78%)
        // because the carry-forward must preserve the identity that makes the denominator
        // recoverable per record; a fixture that broke it could not detect a service that did.
        l.Listing_Status__c = 'Off Market';
        l.Extraction_Score_Pct__c = 78;
        l.Fields_Captured_Count__c = 7;
        l.Fields_Missing_Count__c = 2;
        // Physical property facts -> Property__c
        l.Building_SF__c = 84000;
        l.NOI__c = 512345.67;
        l.Year_Built__c = 1988;
        l.Year_Renovated__c = 2022;
        l.Unit_Count__c = 240;
        l.Occupancy_Pct__c = 88.50;
        l.Lot_Size_Acres__c = 12.34;
        l.WALT_Years__c = 7.5;
        l.ADR__c = 142.75;
        l.Zoning__c = 'C-2 Commercial';
        l.Seller_Entity__c = 'Royal Lane Holdings LP';
        return l;
    }

    /**
     * Re-reads converted Leads with EVERY field the service touches, so a test can hand the same
     * records back to `stampConvertedOpportunities` directly. `oldMap = null` makes the service
     * treat them as just-converted (see its `justConverted` guard).
     *
     * ⚠ ConvertedAccountId was ADDED here 2026-08-10 (IR segregation, Task 5). Without it,
     * stampConvertedPartyRecordTypes' read of l.ConvertedAccountId throws
     * `SObjectException: SObject row was retrieved via SOQL without querying the requested
     * field` for every test that drives the service directly off this helper's output — the
     * live trigger path is unaffected because Trigger.new in an after-update trigger already
     * carries every field.
     *
     * ⚠ Portfolio_Deal__c was ADDED here 2026-08-17 (multi-property email package) FOR THE SAME
     * REASON, and it is worth stating that this trap recurs on EVERY field the service starts
     * reading: `applyDealFields` and `buildProperty` both now read `l.Portfolio_Deal__c`, so
     * omitting it here would throw the identical `SObjectException` for every test in this class
     * that drives the service off this helper — while the live trigger path stayed perfectly green,
     * because Trigger.new carries every field. ⇒ ADDING A FIELD TO THE SERVICE MEANS ADDING IT
     * HERE, and the failure is a test-only one that looks like a service defect.
     *
     * ⚠ `First_Seen_Date__c` and `DPEG_First__c` were ADDED 2026-08-30 (WS2) FOR THE THIRD TIME
     * FOR THE SAME REASON. `applyDealFields` now reads both, so omitting them here would throw
     * that identical `SObjectException` in stampCostDoesNotScaleWithBatchSize,
     * packageCarryForwardAddsNoQueryAndNoDml, opportunityContactRoleIsIdempotent and
     * blankAddressLeavesTheDealNameAloneAndFallsBackToCompany — four tests, none of which is about
     * broker protection — while the live trigger path stayed green. The prediction in the
     * paragraph above has now come true three times; treat it as a rule, not a warning.
     *
     * ✅ WS3 (2026-08-30) NEEDED NOTHING HERE, AND THAT WAS CHECKED RATHER THAN ASSUMED — recorded
     * so the next reader does not have to re-derive it. WS3 makes `createProperties` read
     * `Property_Address__c` and `Street` (through the new `propertyAddress` helper, to derive the
     * reuse key) and `buildProperty` write `Property__c.Normalized_Address__c`. Both Lead fields
     * were ALREADY in this SELECT, and the new field is on `Property__c`, not on `Lead`. So the
     * rule above did not fire a fourth time — this time.
     */
    private static List<Lead> reReadForReRun(Set<Id> leadIds) {
        return [
            SELECT Id, Name, Company, Street, City, State, PostalCode, Portfolio_Deal__c,
                   First_Seen_Date__c, DPEG_First__c,
                   IsConverted, ConvertedOpportunityId, ConvertedContactId, ConvertedAccountId,
                   Deal_Type__c, Asset_Type__c, Property_Name__c, Property_Address__c,
                   Guidance_Price__c, Guidance_Price_Low__c, Guidance_Price_High__c,
                   Guidance_Cap_Rate__c, Offer_Due_Date__c, Sale_Process__c, Parse_Confidence__c,
                   Deal_Room_Link__c, Listing_Broker_Name__c, Listing_Broker_Email__c,
                   Listing_Status__c, Extraction_Score_Pct__c,
                   Fields_Captured_Count__c, Fields_Missing_Count__c,
                   Placer_AI_Link__c, CoStar_Link__c,
                   Building_SF__c, NOI__c, Year_Built__c, Year_Renovated__c, Unit_Count__c,
                   Occupancy_Pct__c, Lot_Size_Acres__c, WALT_Years__c, ADR__c, Zoning__c,
                   Seller_Entity__c
            FROM Lead
            WHERE Id IN :leadIds
        ];
    }

    private static Set<Id> idsOf(List<SObject> records) {
        return new Map<Id, SObject>(records).keySet();
    }

    /**
     * One Property, read with the WS3 key. See the class header for why `WITH SYSTEM_MODE` is
     * mandatory here and not a stylistic choice: `Normalized_Address__c` has no FieldPermissions
     * row anywhere, so a plain SELECT of it throws `No such column` at runtime even for an admin.
     *
     * The field set is the "was it modified?" evidence set for
     * `conversionReusesTheExistingPropertyAndChangesNothingOnIt` — one field per plausible wrong
     * implementation (overwrite a curated value, fill a deliberate blank, rename, re-address).
     */
    private static Property__c readProperty(Id propertyId) {
        return [
            SELECT Id, Name, Address__c, Normalized_Address__c, Asset_Type__c, Asking_Price__c,
                   Cap_Rate_Asking__c, Square_Footage__c, Occupancy_Pct__c, Annual_NOI__c
            FROM Property__c
            WHERE Id = :propertyId
            WITH SYSTEM_MODE
        ];
    }

    /** Every Property carrying a given WS3 key, oldest first — the duplicate detector. See
     *  `readProperty` for why this is `WITH SYSTEM_MODE`. */
    private static List<Property__c> readPropertiesByKey(String key) {
        return [
            SELECT Id, Name, Address__c, Normalized_Address__c
            FROM Property__c
            WHERE Normalized_Address__c = :key
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC, Id ASC
        ];
    }

    /** The Property Ids a set of Opportunities point at, ignoring the ones with no Property. */
    private static Set<Id> propertyIdsOn(Set<Id> oppIds) {
        Set<Id> propertyIds = new Set<Id>();
        for (Opportunity o : [SELECT Property__c FROM Opportunity WHERE Id IN :oppIds]) {
            if (o.Property__c != null) {
                propertyIds.add(o.Property__c);
            }
        }
        return propertyIds;
    }

    private static List<OpportunityContactRole> rolesOn(Id opportunityId) {
        return [
            SELECT Id, OpportunityId, ContactId, Role, IsPrimary
            FROM OpportunityContactRole
            WHERE OpportunityId = :opportunityId
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 1. PRE-EXISTING BEHAVIOUR — deal type, record type, Property, approver.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void stampsLandDeal() {
        Test.startTest();
        Opportunity o = convertLeadOfType('Land', 'Land Holdings LLC');
        Test.stopTest();
        System.assertEquals('Land', o.Deal_Type__c, 'Deal type should carry to Opportunity');
        System.assertEquals('Land', o.RecordType.DeveloperName, 'Should get the Land record type');
    }

    @isTest
    static void stampsRetailDeal() {
        Test.startTest();
        Opportunity o = convertLeadOfType('Retail', 'Commercial Partners Inc');
        Test.stopTest();
        System.assertEquals('Retail', o.Deal_Type__c, 'Deal type should carry to Opportunity');
        System.assertEquals('Retail', o.RecordType.DeveloperName, 'Should get the Retail record type');
    }

    @isTest
    static void createsAndLinksPropertyFromLead() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'CBRE';
        l.Deal_Type__c = 'Retail';
        l.Property_Address__c = '123 Main St, El Paso, TX';
        l.Asset_Type__c = 'Retail';
        l.Guidance_Price__c = 8200000;
        l.Guidance_Cap_Rate__c = 6.25;
        l.Placer_AI_Link__c = 'https://placer.ai/abc';
        l.CoStar_Link__c = 'https://costar.com/xyz';
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Test.startTest();
        Database.LeadConvertResult res = Database.convertLead(lc);
        Test.stopTest();
        System.assert(res.isSuccess(), 'Lead conversion should succeed');

        Opportunity o = [SELECT Id, Property__c FROM Opportunity WHERE Id = :res.getOpportunityId()];
        System.assertNotEquals(null, o.Property__c, 'Conversion should create and link a Property');

        Property__c p = [
            SELECT Name, Address__c, Asset_Type__c, Asking_Price__c, Cap_Rate_Asking__c, Placer_URL__c, CoStar_URL__c
            FROM Property__c WHERE Id = :o.Property__c
        ];
        System.assertEquals('123 Main St, El Paso, TX', p.Address__c, 'Address copied from lead');
        System.assertEquals('Retail', p.Asset_Type__c, 'Asset type copied from lead');
        System.assertEquals(8200000, p.Asking_Price__c, 'Asking Price comes from Guidance Price');
        System.assertEquals(6.25, p.Cap_Rate_Asking__c, 'Cap Rate Asking comes from Guidance Cap Rate');
        System.assertEquals('https://placer.ai/abc', p.Placer_URL__c, 'Placer URL copied from lead');
        System.assertEquals('https://costar.com/xyz', p.CoStar_URL__c, 'CoStar URL copied from lead');
    }

    @isTest
    static void stampsConvertingUserAsLeadApprover() {
        // Conversion IS the approval to underwrite: no checkbox gate, and the
        // converting user lands on the deal as Lead Approved By.
        Test.startTest();
        Opportunity o = convertLeadOfType('Retail', 'Straight Through LLC');
        Test.stopTest();

        Opportunity fresh = [SELECT Lead_Approved_By__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(UserInfo.getUserId(), fresh.Lead_Approved_By__c,
            'Converting user stamped on the Opportunity as the lead approver');
    }

    @isTest
    static void qualifiedNeedsNoApprovalAndIntakeStampsApply() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Gate LLC';
        insert l;

        // No approval gate: Qualified is reachable directly.
        l.Status = 'Qualified';
        update l;

        l = [SELECT Status, First_Seen_Date__c, DPEG_First__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Qualified', l.Status, 'Qualified requires no prior approval');
        System.assertNotEquals(null, l.First_Seen_Date__c, 'First Seen stamped on create for all channels');
        System.assertEquals(UserInfo.getUserId(), l.DPEG_First__c, 'DPEG First stamped from the owning user');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 2. S1 — THE SPLIT. Deal-process facts to the Opportunity...
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void stampsDealProcessFieldsOntoOpportunity() {
        Lead l = withFullDealScreening(TestDataFactory.createLead(false));
        l.Company = 'Orion Capital Partners';
        l.Deal_Type__c = 'Retail';
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Asking_Price__c, Guidance_Price_Low__c, Guidance_Price_High__c,
                   Guidance_Cap_Rate__c, Offer_Due_Date__c, Sale_Process__c, Parse_Confidence__c,
                   Deal_Room_Link__c, Listing_Broker_Name__c, Listing_Broker_Email__c,
                   Listing_Status__c, Extraction_Score_Pct__c,
                   Fields_Captured_Count__c, Fields_Missing_Count__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];

        // ⚠ Asking_Price__c is the open-pipeline KPI's aggregation column. Before S1 an email-born
        // deal contributed 0 to it forever; this assertion is what makes that fix load-bearing.
        Assert.areEqual(7100000, o.Asking_Price__c,
            'Opportunity.Asking_Price__c must carry Lead.Guidance_Price__c — it is the column behind '
            + 'OpportunitySelector.aggregateOpenPipeline and selectTopByAskingPrice');
        Assert.areEqual(6.75, o.Guidance_Cap_Rate__c,
            'F1: the cap-rate twin of Asking_Price__c must be stamped too, or the deal shows a price '
            + 'with no cap rate');
        Assert.areEqual(Date.newInstance(2026, 9, 15), o.Offer_Due_Date__c, 'Offer due date carries');
        Assert.areEqual('Call for Offers', o.Sale_Process__c, 'Sale process carries (restricted picklist)');
        Assert.areEqual('HIGH', o.Parse_Confidence__c,
            'Parse confidence carries — it is the analyst\'s "should I trust the rest of this?" signal');
        Assert.areEqual('https://deals.example.invalid/room/orion', o.Deal_Room_Link__c,
            'The broker\'s data-room link carries (distinct from DPEG\'s own OneDrive_Folder_URL__c)');
        Assert.areEqual('Kevin Girard', o.Listing_Broker_Name__c, 'Listing broker name carries');
        Assert.areEqual('kevin.girard@example.invalid', o.Listing_Broker_Email__c, 'Listing broker email carries');
        Assert.isNull(o.Guidance_Price_Low__c,
            'A single stated price leaves the range EMPTY — the prompt fills one or the other, never both');
        Assert.isNull(o.Guidance_Price_High__c, 'Range high stays empty for a single-price deal');

        // —— Acquisition Observations phase 1 (2026-08-14) ——
        // Asserted in the SAME test as the rest of the deal-process set, deliberately: these
        // four are not a separate feature, they are four more members of the split this test
        // already guards. A separate test would let someone "tidy" one half away.
        Assert.areEqual('Off Market', o.Listing_Status__c,
            'Listing status is a DEAL-PROCESS fact (is the seller marketing this publicly?), so it '
            + 'carries to the OPPORTUNITY — never to the Property__c');
        Assert.areEqual(78, o.Extraction_Score_Pct__c, 'The extraction score carries');
        Assert.areEqual(7, o.Fields_Captured_Count__c, 'The captured count carries');
        Assert.areEqual(2, o.Fields_Missing_Count__c, 'The missing count carries');
        Assert.areEqual(ExtractionScoreUtil.DENOMINATOR,
            o.Fields_Captured_Count__c + o.Fields_Missing_Count__c,
            'ALL THREE numbers must carry together, not just the percent: captured + missing is '
            + 'what recovers the denominator from the Opportunity, and dropping either count '
            + 'silently destroys that property on every converted deal');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 2b. WS2 (2026-08-30) — BROKER PROTECTION SURVIVES CONVERSION.
    //
    // Two more members of the deal-process split, pinned in their own section because they are
    // the first fields this service carries whose VALUE is load-bearing off the Opportunity:
    // Broker_First_Seen__c anchors the BP_Expiry__c and Days_in_System__c formulas and is
    // protected by the Broker_First_Seen_Is_System_Set validation rule.
    //
    // ⚠ THAT VALIDATION RULE CONSTRAINS WHAT THESE TESTS CAN DO, AND IT IS WORTH KNOWING WHY.
    // It refuses any UPDATE that changes Broker_First_Seen__c when the prior value is non-blank.
    // Conversion is safe because the Opportunity is created blank and stamped once — the false
    // -> true IsConverted edge makes stampConvertedOpportunities fire exactly once per Lead. But
    // the re-invoke pattern this class uses elsewhere would trip the rule if it re-ran with a
    // DIFFERENT first-seen value, and `update updates` is all-or-none, so that would fail the
    // whole chunk. Every re-run below therefore leaves Broker_First_Seen__c at the value the
    // conversion already stamped (ISCHANGED is false when the value is identical).
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * A User who is NOT the running user, needed by exactly one assertion below.
     *
     * ⚠ DELIBERATELY LOCAL RATHER THAN IN `TestDataFactory`, and the reason is not laziness.
     * The factory's two User builders (`createNonOwnerDispositionApprover`,
     * `createRecordTypeBlindDispositionPrincipal`) both attach permission-set assignments and
     * exist to construct RECORD-ACCESS personas that a test then runs as. This user is never run
     * as and needs no grant of any kind: it is a lookup TARGET, and its only job is to be a
     * different Id from `UserInfo.getUserId()`. Promoting it to the shared factory would add a
     * third, differently-shaped User builder to a hub file three other workstreams are editing
     * today, for one caller.
     *
     * ⚠ MIXED_DML: `User` is a setup object and this class's tests all do non-setup DML in the
     * same transaction, so the insert runs inside `System.runAs(currentUser)` — the same
     * workaround the factory's own User builders use.
     *
     * @param aliasSeed 1-4 lowercase characters identifying the calling test. Required by the
     *                  8-character Alias cap once the uniquifier is appended.
     * @return The inserted User.
     */
    private static User lookupOnlyUser(String aliasSeed) {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        String unique = aliasSeed + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User target = new User(
            FirstName = 'Other',
            LastName = 'DpegFirst',
            Alias = aliasSeed,
            Email = 'dpeg.first@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert target;
        }
        return target;
    }

    /**
     * The WS2 carry-forward, and every assertion here is built so a plausible WRONG
     * implementation fails it:
     *
     *   • `DPEG_First__c` is set to a user who is NOT the running user. `flows/Lead_Intake_Stamp`
     *     stamps that Lead field from `OwnerId`, so on an ordinary fixture the Lead's value and
     *     `UserInfo.getUserId()` are the SAME Id — and `o.DPEG_First__c = UserInfo.getUserId()`
     *     would pass. It cannot pass here.
     *   • `First_Seen_Date__c` is set 40 days in the past. The Opportunity is created seconds ago,
     *     so a stamp that used `Datetime.now()`, `CreatedDate`, or simply left the field blank is
     *     40 days away from the expected value.
     *   • The two derived formulas are asserted against the CARRIED anchor, which is what makes
     *     the carry-forward load-bearing rather than decorative.
     *
     * ⚠ 12:00:00 ON PURPOSE. `BP_Expiry__c` and `Days_in_System__c` both wrap the field in
     * `DATEVALUE()`, which converts a Datetime in GMT, while `TODAY()` and `Datetime.date()` use
     * the running user's zone. Midday keeps the calendar date identical for every offset from -11
     * to +11, so these assertions measure the formulas and not the org's time zone. Same
     * convention as `ExtractAddressQueueableTest`'s received-date fixtures.
     */
    @isTest
    static void carriesBrokerProtectionValuesToTheOpportunity() {
        User dpegFirst = lookupOnlyUser('wdf');
        Datetime firstSeen = Datetime.newInstance(
            Date.today().addDays(-40), Time.newInstance(12, 0, 0, 0));

        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Protected Deal Holdings';
        l.Deal_Type__c = 'Retail';
        l.First_Seen_Date__c = firstSeen;
        l.DPEG_First__c = dpegFirst.Id;
        insert l;

        // PRECONDITION, NOT DECORATION. Lead_Intake_Stamp is a before-save flow on CreateAndUpdate
        // that overwrites BOTH of these when they are blank. If it ever lost its IsNull guards it
        // would silently replace the fixture's values with "now" and the running user, and every
        // assertion below would then be measuring the flow instead of the service.
        Lead stampedLead = [SELECT First_Seen_Date__c, DPEG_First__c FROM Lead WHERE Id = :l.Id];
        Assert.areEqual(firstSeen, stampedLead.First_Seen_Date__c,
            'Precondition: Lead_Intake_Stamp must NOT overwrite a First_Seen_Date__c the caller '
            + 'supplied — its Needs_First_Seen decision is IsNull-gated');
        Assert.areEqual(dpegFirst.Id, stampedLead.DPEG_First__c,
            'Precondition: nor a supplied DPEG_First__c — Needs_DPEG_First is IsNull-gated too');

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Broker_First_Seen__c, DPEG_First__c, BP_Expiry__c, Days_in_System__c, CreatedDate
            FROM Opportunity WHERE Id = :res.getOpportunityId()
            WITH SYSTEM_MODE
        ];

        Assert.areEqual(firstSeen, o.Broker_First_Seen__c,
            'THE INSTANT CARRIES WHOLE, not truncated to a day. Both fields are DateTime as of '
            + 'WS2 — Lead.First_Seen_Date__c always was, despite its Date-suffixed name, and '
            + 'Opportunity.Broker_First_Seen__c changed Date -> DateTime in this change precisely '
            + 'so this assertion can be an equality rather than a comparison of calendar days');
        Assert.areEqual(dpegFirst.Id, o.DPEG_First__c,
            'and the first DPEG user on the deal carries too');
        Assert.areNotEqual(UserInfo.getUserId(), o.DPEG_First__c,
            '🔴 AND IT COMES FROM THE LEAD, NOT FROM THE CONVERTING USER. Lead_Intake_Stamp fills '
            + 'DPEG_First__c from OwnerId, so on any ordinary fixture the Lead value and the '
            + 'running user are the same Id and `o.DPEG_First__c = UserInfo.getUserId()` would '
            + 'pass. This fixture is the only thing separating the two. Note Lead_Approved_By__c '
            + 'IS the converting user — they are different questions and must not be merged');

        // ── THE TWO FORMULAS, ASSERTED AGAINST THE CARRIED ANCHOR ────────────────────────────
        // Nothing here assigns them; the point is that they now have something to derive FROM.
        Assert.isNotNull(o.BP_Expiry__c,
            'The protection expiry derives as soon as the anchor lands');
        Integer windowDays = o.Broker_First_Seen__c.date().daysBetween(o.BP_Expiry__c);
        Assert.areEqual(windowDays - 40, o.CreatedDate.date().daysBetween(o.BP_Expiry__c),
            '🔴 THE EXPIRY IS ANCHORED ON THE CARRIED DATE, NOT ON THE OPPORTUNITY\'S OWN CREATION '
            + 'MOMENT. Written as a relationship rather than a literal so it survives WS5 making '
            + 'the window configurable: whatever the window is, an expiry anchored on a value 40 '
            + 'days older must land exactly 40 days earlier than the CreatedDate leg would put it. '
            + 'Before WS2 the field was permanently blank, so the CreatedDate leg was the ONLY '
            + 'leg the formula could ever take');
        // 🔴 THE WINDOW'S OWN VALUE IS DELIBERATELY NOT ASSERTED HERE, AND THAT IS A DECISION, NOT
        // AN OMISSION. As of WS5 the formula resolves it from
        // $CustomMetadata.Broker_Protection_Config__mdt.Default.Protection_Window_Days__c — a
        // SETUP-EDITABLE, script-loaded value. A literal `90` in this class would be a second,
        // weaker copy of the invariant that WS5's own accessor test owns (CMDT window ==
        // PROTECTION_WINDOW_DAYS), and it would go red on a legitimate config change in a test
        // that has nothing to do with configuration. The claim THIS test exists to make is about
        // the ANCHOR, and the assertion above makes it without knowing the window at all.
        Assert.isTrue(windowDays > 0,
            'Sanity only: the expiry is after the anchor. If this is ever 0 the CMDT record is '
            + 'missing or its window is unset — a provisioning fault, not a carry-forward fault');
        Assert.areEqual('40d', o.Days_in_System__c,
            'and the deal reads 40 days old — its age since the BROKER was first seen, which is '
            + 'the whole point of carrying the value. A deal converted today from a 40-day-old '
            + 'Lead read "0d" before this change');
    }

    /**
     * The blank half, and it is a REACHABLE production state rather than a hypothetical: a Lead
     * owned by a QUEUE never gets DPEG_First__c, because Lead_Intake_Stamp's Needs_DPEG_First
     * decision requires `LEFT(CASESAFEID(OwnerId),3) = "005"`. Such a Lead converts with the
     * lookup empty and the Opportunity's must stay empty too — "no DPEG user had this first" is
     * the honest answer, and a defaulting copy would put the converting user there and claim
     * something untrue.
     *
     * ⚠ WHY THE RE-INVOKE PATTERN RATHER THAN A QUEUE-OWNED FIXTURE. Queue membership is not
     * deployable metadata in this repo, so a queue-owned Lead fixture would depend on org state
     * this suite cannot guarantee. Nulling the value on the re-read Lead drives the identical
     * code path — `applyDealFields` reads `l.DPEG_First__c` and finds null — with no org
     * dependency. The class header explains the re-invoke pattern and its one side effect (a
     * second Property is built; this method does not look at Properties).
     *
     * ⚠ AND WHY ONLY THE LOOKUP IS NULLED, NOT BOTH. Blanking Broker_First_Seen__c on a re-run
     * would change it from a non-blank prior value, which is exactly what
     * Broker_First_Seen_Is_System_Set refuses — and `update updates` is all-or-none, so the
     * refusal would take the whole statement down. The first-seen blank case is unreachable
     * through this service by construction (the flow stamps every Lead at insert and the Lead's
     * own sibling rule then blocks blanking it), and a test that faked it would be testing a
     * state production cannot produce.
     */
    @isTest
    static void aLeadWithNoDpegFirstLeavesTheOpportunityLookupBlank() {
        List<Lead> one = TestDataFactory.createLeads(1, true);
        convertChunk(one, 0, 1, convertedStatus());

        List<Lead> reRun = reReadForReRun(idsOf(one));
        Assert.isNotNull(reRun[0].DPEG_First__c,
            'Precondition: the flow stamped DPEG_First__c on insert, so nulling it below is a '
            + 'real change of state and not a no-op that would make this test vacuous');
        reRun[0].DPEG_First__c = null; // in memory only — the Lead is never re-saved

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(reRun, null);
        Test.stopTest();

        Opportunity o = [
            SELECT DPEG_First__c, Broker_First_Seen__c
            FROM Opportunity WHERE Id = :reRun[0].ConvertedOpportunityId
            WITH SYSTEM_MODE
        ];
        Assert.isNull(o.DPEG_First__c,
            'A blank DPEG First on the Lead leaves the Opportunity blank. The assignment is '
            + 'UNGUARDED on purpose — a `!= null` guard here would be indistinguishable from no '
            + 'guard on a freshly created Opportunity (every field is empty at that instant) and '
            + 'would mask a real bug later, which is the same reasoning the three extraction '
            + 'numbers above are copied under');
        Assert.isNotNull(o.Broker_First_Seen__c,
            'and the OTHER half of the pair is untouched by that — the two are independent '
            + 'assignments, not a bundle that travels or fails together');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ...and physical property facts to the Property__c.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void stampsPhysicalFactsOntoProperty() {
        Lead l = withFullDealScreening(TestDataFactory.createLead(false));
        l.Company = 'Meridian Realty Group';
        l.Deal_Type__c = 'Retail';
        l.Asset_Type__c = 'Retail';
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [SELECT Property__c FROM Opportunity WHERE Id = :res.getOpportunityId()];
        Assert.isNotNull(o.Property__c, 'Conversion still creates and links a Property');

        Property__c p = [
            SELECT Square_Footage__c, Annual_NOI__c, Year_Built__c, Year_Renovated__c,
                   Unit_Count__c, Occupancy_Pct__c, Occupancy_Rate_Market__c, Lot_Size_Acres__c,
                   Lot_Size__c, WALT_Years__c, ADR__c, Zoning__c, Seller_Entity__c
            FROM Property__c WHERE Id = :o.Property__c
        ];

        // Existing Property fields EXTENDED (not duplicated) because their semantics already match.
        Assert.areEqual(84000, p.Square_Footage__c, 'Building SF lands on the existing GLA field');
        Assert.areEqual(512345.67, p.Annual_NOI__c, 'NOI lands on the existing periodic-amount field');
        Assert.areEqual(1988, p.Year_Built__c, 'Year built carries');
        // New Property fields.
        Assert.areEqual(2022, p.Year_Renovated__c, 'Year renovated carries');
        Assert.areEqual(240, p.Unit_Count__c, 'Unit count carries');
        Assert.areEqual(88.50, p.Occupancy_Pct__c, 'The SUBJECT asset\'s stated occupancy carries');
        Assert.areEqual(12.34, p.Lot_Size_Acres__c, 'Lot size in ACRES carries');
        Assert.areEqual(7.5, p.WALT_Years__c, 'WALT carries');
        Assert.areEqual(142.75, p.ADR__c, 'ADR carries');
        Assert.areEqual('C-2 Commercial', p.Zoning__c, 'Zoning carries');
        Assert.areEqual('Royal Lane Holdings LP', p.Seller_Entity__c,
            'Seller entity carries as TEXT — there is no Seller object, so this is deliberately not a lookup');

        // ⚠ THE TWO NO-TOUCH GUARANTEES. Both fields are one plausible-looking line away from being
        // corrupted, and neither corruption would raise an error.
        Assert.isNull(p.Lot_Size__c,
            'Lot_Size__c is SQUARE FEET from the Offering Memorandum and must stay NULL. We hold acres '
            + 'only; SF = acres x 43,560 would DERIVE one number from another (forbidden by this '
            + 'module\'s anti-hallucination contract) and would overwrite an analyst\'s OM figure');
        Assert.isNull(p.Occupancy_Rate_Market__c,
            'Occupancy_Rate_Market__c is the MARKET benchmark (Placer/CoStar lineage). Writing the '
            + 'broker\'s figure into it would corrupt a comparison field — that is why Occupancy_Pct__c '
            + 'exists as a separate field');
    }

    /**
     * The accepted cost of refusing to fabricate a price, made explicit so a future "helpful"
     * midpoint change fails HERE rather than quietly inflating the pipeline-value KPI.
     */
    @isTest
    static void rangePricedLeadLeavesAskingPriceNull() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Zephyr Industrial Trust';
        l.Deal_Type__c = 'Retail';
        l.Property_Address__c = '55 Range Road, Austin TX';
        // The prompt's own rule: a range fills low/high and leaves guidance_price null.
        l.Guidance_Price__c = null;
        l.Guidance_Price_Low__c = 6900000;
        l.Guidance_Price_High__c = 7400000;
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Asking_Price__c, Guidance_Price_Low__c, Guidance_Price_High__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.areEqual(6900000, o.Guidance_Price_Low__c, 'The range low bound is stamped');
        Assert.areEqual(7400000, o.Guidance_Price_High__c, 'The range high bound is stamped');
        Assert.isNull(o.Asking_Price__c,
            'A range-priced deal MUST leave Asking_Price__c null. Synthesizing a midpoint (or taking '
            + 'the high) would fabricate a price the email never stated — the exact behaviour this '
            + 'module forbids. Such a deal contributes 0 to the pipeline KPI until an analyst fills it');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 3. NAMING — Property__c.Name precedence (S1) and Opportunity.Name (D-f).
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void propertyNamePrefersPropertyNameOverAddress() {
        Lead named = TestDataFactory.createLead(false);
        named.Company = 'Halcyon Asset Advisors';
        named.Property_Name__c = 'Orion ParkView';
        named.Property_Address__c = '1400 Royal Lane, Dallas TX 75229';

        Lead unnamed = TestDataFactory.createLead(false);
        unnamed.Company = 'Sableridge Investments';
        unnamed.Property_Name__c = null;
        unnamed.Property_Address__c = '900 Fallback Way, Houston TX';
        insert new List<Lead>{ named, unnamed };

        Test.startTest();
        Database.LeadConvertResult namedRes = convertOne(named);
        Database.LeadConvertResult unnamedRes = convertOne(unnamed);
        Test.stopTest();

        Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
            SELECT Id, Property__c FROM Opportunity
            WHERE Id IN (:namedRes.getOpportunityId(), :unnamedRes.getOpportunityId())
        ]);
        Property__c namedProperty = [
            SELECT Name, Address__c FROM Property__c
            WHERE Id = :opps.get(namedRes.getOpportunityId()).Property__c
        ];
        Property__c unnamedProperty = [
            SELECT Name, Address__c FROM Property__c
            WHERE Id = :opps.get(unnamedRes.getOpportunityId()).Property__c
        ];

        Assert.areEqual('Orion ParkView', namedProperty.Name,
            'A marketing name now BEATS the address in the Property name precedence — this is the '
            + 'visible behaviour change S1 accepted; existing Properties are not back-filled');
        Assert.areEqual('1400 Royal Lane, Dallas TX 75229', namedProperty.Address__c,
            'The address is still stored on Address__c, so nothing becomes unfindable');
        Assert.areEqual('900 Fallback Way, Houston TX', unnamedProperty.Name,
            'With no marketing name the address is still the fallback — the pre-S1 behaviour');
    }

    @isTest
    static void opportunityNameFromPropertyName() {
        Lead named = TestDataFactory.createLead(false);
        named.Company = 'Cobalt Harbor Group';
        named.Property_Name__c = 'Orion ParkView';
        named.Property_Address__c = '1400 Royal Lane, Dallas TX 75229';

        Lead addressOnly = TestDataFactory.createLead(false);
        addressOnly.Company = 'Windward Peak Realty';
        addressOnly.Property_Name__c = null;
        addressOnly.Property_Address__c = '77 Address Only Blvd, Dallas TX';

        // Property_Name__c is Text(255); Opportunity.Name caps at 120.
        Lead overlong = TestDataFactory.createLead(false);
        overlong.Company = 'Juniper Stone Ventures';
        overlong.Property_Name__c = 'X'.repeat(200);
        insert new List<Lead>{ named, addressOnly, overlong };

        Test.startTest();
        Database.LeadConvertResult namedRes = convertOne(named);
        Database.LeadConvertResult addressRes = convertOne(addressOnly);
        Database.LeadConvertResult overlongRes = convertOne(overlong);
        Test.stopTest();

        Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
            SELECT Id, Name FROM Opportunity
            WHERE Id IN (:namedRes.getOpportunityId(), :addressRes.getOpportunityId(),
                         :overlongRes.getOpportunityId())
        ]);

        Assert.areEqual('Orion ParkView', opps.get(namedRes.getOpportunityId()).Name,
            'D-f: the deal is named after the PROPERTY. Left to the platform it would be named from '
            + 'Lead.Company — "Unknown - Via Email", or after S4 the broker\'s FIRM, which every deal '
            + 'from that firm would share');
        Assert.areEqual('77 Address Only Blvd, Dallas TX', opps.get(addressRes.getOpportunityId()).Name,
            'With no marketing name the address names the deal');
        Assert.areEqual(120, opps.get(overlongRes.getOpportunityId()).Name.length(),
            'Opportunity.Name caps at 120 characters — an over-long property name is clipped, not rejected');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 4. THE RESTRICTED-PICKLIST GUARD — the all-or-none protection.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ WHY THIS TEST RE-INVOKES THE SERVICE INSTEAD OF INSERTING A BAD LEAD: Lead.Sale_Process__c
     * and Lead.Parse_Confidence__c are themselves RESTRICTED and byte-identical to the Opportunity
     * picklists, so no INSERTABLE lead can carry a value the target lacks. The realistic production
     * shape is a value RETIRED from one object and not the other — which is exactly what an
     * in-memory assignment reproduces, because picklist restriction is enforced at DML, not at
     * assignment. Delete the guard in LeadConvertService and this test fails with a DmlException.
     */
    @isTest
    static void unknownPicklistValueIsDroppedNotThrown() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Ashgrove Terminal Partners';
        l.Deal_Type__c = 'Retail';
        l.Property_Address__c = '900 Guard Way, Houston TX';
        l.Sale_Process__c = 'Auction';
        l.Parse_Confidence__c = 'HIGH';
        insert l;
        Database.LeadConvertResult res = convertOne(l);

        Lead reRun = reReadForReRun(new Set<Id>{ l.Id })[0];
        reRun.Sale_Process__c = 'Retired Sale Process';   // not on the Opportunity picklist
        reRun.Parse_Confidence__c = 'UNKNOWN';            // not on the Opportunity picklist
        reRun.Listing_Status__c = 'Pending';              // not on the Opportunity picklist
        reRun.Listing_Broker_Name__c = 'Kevin Girard';    // a NON-picklist field on the same update
        reRun.Offer_Due_Date__c = Date.newInstance(2026, 10, 1);

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(new List<Lead>{ reRun }, null);
        Test.stopTest();

        Opportunity o = [
            SELECT Sale_Process__c, Parse_Confidence__c, Listing_Status__c,
                   Listing_Broker_Name__c, Offer_Due_Date__c,
                   RecordTypeId, Property__c, Lead_Approved_By__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.isNull(o.Sale_Process__c, 'An out-of-range restricted-picklist value is DROPPED, never pushed');
        Assert.isNull(o.Parse_Confidence__c, 'Same for the second guarded picklist');
        Assert.isNull(o.Listing_Status__c,
            'Same for the THIRD guarded picklist, added 2026-08-14. Lead.Listing_Status__c and '
            + 'Opportunity.Listing_Status__c are two INDEPENDENT restricted field definitions that '
            + 'merely match today — an unguarded copy would throw and roll back the whole chunk');
        // The point of the guard is not the two nulls — it is that everything ELSE still landed.
        Assert.areEqual('Kevin Girard', o.Listing_Broker_Name__c,
            'The REST of the stamp must still land. `update updates` is all-or-none, so an unguarded '
            + 'illegal picklist value would have rolled back this field — and the structural '
            + 'RecordTypeId / Property__c link with it — for every lead in the chunk');
        Assert.areEqual(Date.newInstance(2026, 10, 1), o.Offer_Due_Date__c, 'And this one');
        Assert.isNotNull(o.RecordTypeId, 'The structural record type survived the guarded write');
        Assert.isNotNull(o.Property__c, 'The structural Property link survived the guarded write');
        Assert.areEqual(UserInfo.getUserId(), o.Lead_Approved_By__c, 'And the approver stamp');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 5. S2 — the primary Broker OpportunityContactRole.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void createsPrimaryBrokerOpportunityContactRole() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Pinnacle Brokerage Advisors';
        l.Deal_Type__c = 'Retail';
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        List<OpportunityContactRole> roles = rolesOn(res.getOpportunityId());
        Assert.areEqual(1, roles.size(),
            'EXACTLY ONE role row. Standard conversion already creates a primary OCR with a BLANK '
            + 'Role, so this proves the service UPDATED that row rather than inserting a second '
            + 'broker and a second primary');
        Assert.areEqual('Broker', roles[0].Role, 'The converted Contact is named as the Broker');
        Assert.isTrue(roles[0].IsPrimary, 'and is the primary contact on the deal');
        Assert.areEqual(res.getContactId(), roles[0].ContactId,
            'The role must point at the CONVERTED Contact — the submitting broker');

        // S2b — the same broker must ALSO land on the Broker__c lookup. The contact role alone was
        // invisible in practice: a related list cannot surface in the highlights panel, a compact
        // layout, a list view column or a report column, so nobody could see who the broker was.
        // The two are asserted together on purpose — they must never drift apart.
        Opportunity deal = [
            SELECT Broker__c, Listing_Broker_Email__c FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.areEqual(res.getContactId(), deal.Broker__c,
            'Broker__c mirrors the primary Broker contact role, so the broker is visible as a FIELD');
        Assert.areEqual(roles[0].ContactId, deal.Broker__c,
            'The lookup and the contact role must name the SAME Contact — they must not drift');
    }

    /**
     * Idempotency. In production the trigger's `justConverted` guard means this path fires once per
     * Lead and cannot re-run, so this drives the service directly — which is the only way to prove
     * the OCR WRITE ITSELF is read-then-write rather than relying on that guard.
     */
    @isTest
    static void opportunityContactRoleIsIdempotent() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Everline Property Group';
        l.Deal_Type__c = 'Retail';
        insert l;
        Database.LeadConvertResult res = convertOne(l);
        Assert.areEqual(1, rolesOn(res.getOpportunityId()).size(), 'Baseline: one role row after conversion');

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(reReadForReRun(new Set<Id>{ l.Id }), null);
        LeadConvertService.stampConvertedOpportunities(reReadForReRun(new Set<Id>{ l.Id }), null);
        Test.stopTest();

        List<OpportunityContactRole> roles = rolesOn(res.getOpportunityId());
        Assert.areEqual(1, roles.size(),
            'Two further passes over the same converted set must leave the role COUNT unchanged — '
            + 'read-then-write is idempotent by construction, a blind insert would now show 3 rows');
        Assert.areEqual('Broker', roles[0].Role, 'and the role value is unchanged');
        Assert.isTrue(roles[0].IsPrimary, 'and it is still primary');
    }

    /**
     * IR segregation (2026-08-10) — job 5. Database.convertLead does not map record types onto
     * the Contact or Account it creates; without the explicit stamp the converted Contact takes
     * the running user's PROFILE default, which is unverifiable from source (profiles are
     * .forceignore'd) and may be Investor rather than Broker.
     */
    @isTest
    static void conversionStampsBrokerRecordTypesOnContactAndAccount() {
        Lead l = TestDataFactory.createLead(true);

        Test.startTest();
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult res = Database.convertLead(lc);
        Test.stopTest();

        Assert.isTrue(res.isSuccess(), 'Conversion must succeed.');

        Contact c = [SELECT RecordType.DeveloperName FROM Contact WHERE Id = :res.getContactId()];
        Account a = [SELECT RecordType.DeveloperName FROM Account WHERE Id = :res.getAccountId()];

        Assert.areEqual('Broker', c.RecordType.DeveloperName,
            'Conversion does not map Contact record types - without the explicit stamp the converted '
            + 'Contact takes the running user profile default, which may be Investor.');
        Assert.areEqual('Broker_Firm', a.RecordType.DeveloperName,
            'An Account left off Broker_Firm matches no sharing rule once Account OWD is Private.');
    }

    /**
     * The Task 5 bulk claim, pinned directly: 251 converted Leads processed through ONE
     * stampConvertedOpportunities invocation cost the SAME <=5 DML statements a single Lead
     * does — proof that stampConvertedPartyRecordTypes's two new statements are batched once
     * per invocation, never once per record.
     *
     * ⚠ Database.convertLead itself caps a single call's LeadConvert list at 200 (see
     * bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities), so the 251 Leads are
     * converted across two chunks first — outside the measured window — then re-read and driven
     * through the service directly in ONE call, which is the only way to observe a single
     * invocation's cost at this volume without also measuring convertLead's own chunking
     * overhead.
     */
    @isTest
    static void conversionDmlIsConstantAcross251Leads() {
        List<Lead> leads = TestDataFactory.createLeads(BULK_N, true);
        String status = convertedStatus();
        convertChunk(leads, 0, 200, status);
        convertChunk(leads, 200, BULK_N, status);

        List<Lead> reRun = reReadForReRun(idsOf(leads));
        Assert.areEqual(BULK_N, reRun.size(), 'All 251 leads converted ahead of the re-run');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(reRun, null);
        Integer dmlDelta = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.isTrue(dmlDelta <= 5,
            'LeadConvertService is pinned at <=5 DML statements, CONSTANT in batch size. It moved '
            + 'from 3 to 5 in the IR segregation change to stamp the converted Contact and Account '
            + 'record types. A number that grows with record count means a statement moved inside a loop.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 5b. THE MULTI-PROPERTY EMAIL PACKAGE, CARRIED FORWARD (2026-08-17)
    //
    // One inbound broker email naming several properties produces several Leads, all stamped
    // with ONE Portfolio_Deal__c at insert. Conversion must carry that grouping onto BOTH
    // records it creates, or the package silently loses its members the moment the deals are
    // worked — which is precisely when an analyst needs to see them together.
    // ═════════════════════════════════════════════════════════════════════════

    /** A package to hang the fixture Leads off. Inserted directly — nothing in this class routes
     *  an email, and PortfolioDealService's own creation path is tested in its own class. */
    private static Portfolio_Deal__c insertPackage(String name) {
        Portfolio_Deal__c pkg = new Portfolio_Deal__c(Name = name, Property_Count__c = 3);
        insert pkg;
        return pkg;
    }

    @isTest
    static void packageIsCarriedToBothTheOpportunityAndTheProperty() {
        Portfolio_Deal__c pkg = insertPackage('FW: Three-property portfolio');

        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Package Brokerage LLC';
        l.Deal_Type__c = 'Retail';
        l.Property_Address__c = GATE_ADDRESS;
        l.Portfolio_Deal__c = pkg.Id;
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Portfolio_Deal__c, Property__c, Property__r.Portfolio_Deal__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.areEqual(pkg.Id, o.Portfolio_Deal__c,
            'BOTH HALVES MATTER, AND THIS IS THE FIRST: the deal must stay in its package after '
            + 'conversion. Without it the grouping dies at exactly the moment the deals become '
            + 'workable, which is when a human needs to see that three of them came off one email');
        Assert.isNotNull(o.Property__c, 'Precondition: conversion created the Property');
        Assert.areEqual(pkg.Id, o.Property__r.Portfolio_Deal__c,
            'AND THE SECOND: the Property__c is the third member of the package one-to-many, and it '
            + 'is the member that makes the grouping legible on the package\'s own record page');
    }

    @isTest
    static void aLeadWithNoPackageLeavesBothLookupsBlank() {
        // The overwhelmingly common case, asserted so the carry-forward can never be "helpful" —
        // e.g. defaulting to some other package, or to any OTHER grouping someone decides a deal
        // ought to belong to. This lookup answers only "which inbound broker email routed this
        // record?", and a deal that came off no multi-property email is in no package at all.
        // Null in, null out.
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Solo Brokerage LLC';
        l.Deal_Type__c = 'Retail';
        l.Property_Address__c = GATE_ADDRESS;
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Portfolio_Deal__c, Property__r.Portfolio_Deal__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.isNull(o.Portfolio_Deal__c, 'No package on the Lead means none on the deal');
        Assert.isNull(o.Property__r.Portfolio_Deal__c, 'and none on the Property');
    }

    /**
     * 🔴 THE CONTRACT ASSERTION FOR THIS CHANGE: the package carry-forward adds ZERO SOQL and ZERO
     * DML, so LeadConvertService's 2 SOQL / <=5 DML budget is UNCHANGED.
     *
     * ⚠ IT IS A COMPARISON, NOT AN ABSOLUTE BUDGET, and for the reason
     * `stampCostDoesNotScaleWithBatchSize` states: the measured window contains the whole
     * Opportunity-update cascade, whose cost is not this service's to pin. Two invocations in the
     * SAME transaction — one carrying a package, one not — cancel that noise exactly. If the
     * carry-forward ever needed a query (say, to resolve a package by name) the deltas would
     * diverge here, which is the only place that would be visible.
     *
     * The absolute `<= 5` is asserted too, mirroring conversionDmlIsConstantAcross251Leads, because
     * "unchanged relative to a run that is itself broken" would prove nothing.
     */
    @isTest
    static void packageCarryForwardAddsNoQueryAndNoDml() {
        Portfolio_Deal__c pkg = insertPackage('FW: budget check');

        // ONE factory call for both Leads, deliberately: the factory's per-record suffix makes each
        // Company and Email unique WITHIN a call, so a single call is the shape least likely to
        // collide with a live Lead duplicate rule.
        List<Lead> pair = TestDataFactory.createLeads(2, false);
        pair[0].Portfolio_Deal__c = pkg.Id;   // index 0 carries the package
        insert pair;
        List<Lead> withPackage = new List<Lead>{ pair[0] };
        List<Lead> withoutPackage = new List<Lead>{ pair[1] };

        String status = convertedStatus();
        convertChunk(withPackage, 0, 1, status);
        convertChunk(withoutPackage, 0, 1, status);

        List<Lead> packagedReRun = reReadForReRun(idsOf(withPackage));
        List<Lead> plainReRun = reReadForReRun(idsOf(withoutPackage));
        Assert.areEqual(pkg.Id, packagedReRun[0].Portfolio_Deal__c,
            'Precondition: the re-read must actually carry the package, or this test is vacuous — '
            + 'and it only does because Portfolio_Deal__c was added to reReadForReRun');

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(plainReRun, null);
        Integer q1 = Limits.getQueries();
        Integer d1 = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(packagedReRun, null);
        Integer q2 = Limits.getQueries();
        Integer d2 = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(q1 - q0, q2 - q1,
            'A Lead CARRYING a package must cost exactly the same number of queries as one without: '
            + 'the value is already on the Trigger.new record, so carrying it is an in-memory '
            + 'assignment. Divergence here means someone added a read');
        Assert.areEqual(d1 - d0, d2 - d1,
            'and exactly the same number of DML statements: both assignments ride records the '
            + 'service was already writing (the `updates` list and the `properties` list), so there '
            + 'is no second statement. Divergence means someone added one');
        Assert.isTrue(d2 - d1 <= 5,
            'and the absolute contract still holds at <=5 DML — otherwise "unchanged" would only '
            + 'mean "equally broken"');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 5c. WS3 (2026-08-30) — REUSE AN EXISTING PROPERTY ON CONVERSION
    //
    // Conversion used to mint a Property__c unconditionally, so two brokers emailing the SAME
    // building produced two rows for it and the building's underwriting, deal folder and PM asset
    // tree forked in two. It now derives a normalized-address key, looks the building up once for
    // the whole chunk, and LINKS to the existing row when there is one — changing NOTHING on it.
    //
    // 🔴 EVERY FIXTURE PAIR BELOW DIFFERS IN CASE, PUNCTUATION AND SPACING, NEVER ONLY IN
    // WHITESPACE THE NORMALIZATION WOULD IGNORE ANYWAY. Two wordings that were already equal as
    // raw strings would pass against an implementation that compared Address__c directly and never
    // normalized anything — i.e. against the exact defect P14 says a formula cannot fix.
    // ═════════════════════════════════════════════════════════════════════════

    /** The building the WS3 fixtures are about, in the FIRST broker's wording. */
    private static final String BUILDING_FIRST_WORDING = '1400 Royal Lane, Dallas TX 75229';

    /**
     * The SAME building in a SECOND broker's wording. Differs in CASE ('ROYAL LANE'), in
     * PUNCTUATION (a period and an extra comma) and in SPACING (doubled spaces) — three separate
     * things `normalizeAddress` collapses, so a partial implementation fails on at least one.
     */
    private static final String BUILDING_SECOND_WORDING = '1400  ROYAL LANE., dallas,  tx  75229';

    /**
     * The key both wordings must produce.
     * 🔴 HARDCODED ON PURPOSE. Asserting only `normalizeAddress(wording)` would be circular — it
     * would pass for any normalization at all, including one that returned its input unchanged.
     * This literal is what makes a change to the key's SHAPE visible here rather than silently
     * re-keying every Property in the org. The tests assert against BOTH: the literal (does the
     * shape still hold?) and the method (is the service still calling the one definition?).
     */
    private static final String BUILDING_KEY = '1400 royal lane dallas tx 75229';

    /** A third building, used where the fixture needs a key that exists NOWHERE yet. */
    private static final String NEW_BUILDING_A = '77 Vantage Circle, Plano TX';
    private static final String NEW_BUILDING_B = '77  vantage circle;; PLANO,  tx';
    private static final String NEW_BUILDING_KEY = '77 vantage circle plano tx';

    /**
     * THE STAMP. A conversion that creates a Property must write the key, and must write the key
     * `PropertyMatchingService.normalizeAddress` produces — not a locally re-derived equivalent.
     * Without this the reuse lookup can never find anything conversion itself created.
     *
     * The raw address is asserted too: normalizing the KEY must not normalize the RECORD. The
     * broker's own wording is what an analyst reads on the Property page, and losing it to a
     * lowercased punctuation-stripped string would be a visible regression nothing else here
     * would catch.
     */
    @isTest
    static void conversionStampsTheNormalizedAddressKeyOnANewProperty() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Orion Capital Partners';
        l.Property_Address__c = BUILDING_FIRST_WORDING;
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [SELECT Property__c FROM Opportunity WHERE Id = :res.getOpportunityId()];
        Assert.isNotNull(o.Property__c, 'Precondition: the conversion still creates a Property');
        Property__c p = readProperty(o.Property__c);

        Assert.areEqual(BUILDING_KEY, p.Normalized_Address__c,
            'The new Property carries the lowercased, punctuation-stripped, space-collapsed key. '
            + 'A null here means buildProperty never stamped it, and the reuse lookup would then '
            + 'be blind to every Property conversion itself creates');
        Assert.areEqual(
            PropertyMatchingService.normalizeAddress(BUILDING_FIRST_WORDING),
            p.Normalized_Address__c,
            'and it is byte-identical to what PropertyMatchingService.normalizeAddress returns — '
            + 'the SOLE definition of this key, shared with Property_Registry__c.Property_Key__c. '
            + 'A second implementation would agree today and diverge silently later');
        Assert.areEqual(BUILDING_FIRST_WORDING, p.Address__c,
            'and the RAW address is stored unchanged. Normalizing the key must never normalize the '
            + 'record an analyst reads');
    }

    /**
     * 🔴 THE CENTRAL WS3 TEST, AND THE ONE THE USER DECISION IS ABOUT. A second broker's deal for
     * a building this org already holds must LINK to the existing Property and CHANGE NOTHING ON
     * IT — not overwrite a curated value, not fill a deliberate blank.
     *
     * The fixture is built so that every rejected alternative implementation fails:
     *   • "overwrite"    — the Lead's Guidance_Price__c / Guidance_Cap_Rate__c / Building_SF__c are
     *                      all DIFFERENT from the curated Property's values, so a copy shows up as
     *                      the wrong number rather than a coincidentally equal one.
     *   • "fill blanks"  — `Occupancy_Pct__c` is deliberately NULL on the curated Property and
     *                      POPULATED on the Lead. This is the assertion the softer alternative
     *                      fails, and it is the one the user chose against: a blank can mean "not
     *                      measured yet" OR "an analyst deleted a wrong number", and from here the
     *                      two are indistinguishable.
     *   • "match on raw address" — the two wordings differ in case, punctuation and spacing.
     *   • "create anyway" — the key is asserted to hold exactly ONE Property afterwards.
     *
     * ⚠ The last assertion pins a STATED CONSEQUENCE rather than a success: the second deal's
     * `Property__r.Address__c` (which is what the `Opportunity.Property_Address__c` cross-object
     * formula renders) shows the FIRST broker's wording. That is the accepted cost of "change
     * nothing"; the second email's wording survives on `Lead.Property_Address__c`. If this
     * assertion ever fails because the address now matches the SECOND wording, the reuse decision
     * has been quietly reversed — that is the failure it is here to catch.
     */
    @isTest
    static void conversionReusesTheExistingPropertyAndChangesNothingOnIt() {
        Property__c curated = new Property__c(
            Name = 'Orion ParkView (curated)',
            Address__c = BUILDING_FIRST_WORDING,
            Normalized_Address__c = BUILDING_KEY,
            Asset_Type__c = 'Retail',
            Asking_Price__c = 6000000,
            Cap_Rate_Asking__c = 5.10,
            Square_Footage__c = 84000,
            Annual_NOI__c = 512345.67
            // Occupancy_Pct__c LEFT NULL DELIBERATELY — the blank-fill probe. See the Javadoc.
        );
        // 🔴 AccessLevel.SYSTEM_MODE IS MANDATORY, AND WAS MEASURED. A plain `insert curated;`
        // fails with `System.DmlException: Operation failed due to fields being inaccessible on
        // Sobject Property__c` (measured 2026-08-30, as a System Administrator) purely because the
        // payload contains Normalized_Address__c, a Metadata-API-deployed field with no
        // FieldPermissions row for anyone. "Apex DML is system mode by default" does not put back a
        // field that is absent from the running user's schema — only an explicit access level does.
        // Same fact that forced the explicit AccessLevel on LeadConvertService's own Property
        // insert; see that statement's comment.
        Database.insert(curated, true, AccessLevel.SYSTEM_MODE);

        Property__c before = readProperty(curated.Id);
        Assert.areEqual(BUILDING_KEY, before.Normalized_Address__c,
            'PRECONDITION: the curated Property really carries the key. If the stamp did not land, '
            + 'the reuse below would "correctly" create a second Property and this test would '
            + 'assert nothing at all');
        Assert.isNull(before.Occupancy_Pct__c,
            'PRECONDITION: the blank a "fill the gaps" implementation would fill');

        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Second Broker LLC';
        l.Property_Name__c = 'Orion ParkView (second broker wording)';
        l.Property_Address__c = BUILDING_SECOND_WORDING;
        l.Guidance_Price__c = 9999999;    // would OVERWRITE Asking_Price__c
        l.Guidance_Cap_Rate__c = 9.99;    // would OVERWRITE Cap_Rate_Asking__c
        l.Building_SF__c = 111111;        // would OVERWRITE Square_Footage__c
        l.NOI__c = 1;                     // would OVERWRITE Annual_NOI__c
        l.Occupancy_Pct__c = 77.7;        // would FILL the deliberate blank
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Property__c, Property__r.Address__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.areEqual(curated.Id, o.Property__c,
            'The second deal LINKS to the building this org already held. A different Id means the '
            + 'reuse lookup missed — most likely because the two wordings were compared raw '
            + 'instead of normalized');
        Assert.areEqual(1, readPropertiesByKey(BUILDING_KEY).size(),
            'and exactly ONE Property carries the key afterwards. Two is the pre-WS3 behaviour: '
            + 'the same building forked into two acquisition graphs');

        Property__c after = readProperty(curated.Id);
        Assert.areEqual(before.Name, after.Name,
            'REUSE CHANGES NOTHING: the curated name is not replaced by the second broker\'s');
        Assert.areEqual(before.Address__c, after.Address__c, 'nor the address wording');
        Assert.areEqual(before.Asking_Price__c, after.Asking_Price__c,
            'nor the curated asking price, by the second email\'s unreviewed guidance figure');
        Assert.areEqual(before.Cap_Rate_Asking__c, after.Cap_Rate_Asking__c, 'nor the cap rate');
        Assert.areEqual(before.Square_Footage__c, after.Square_Footage__c, 'nor the square footage');
        Assert.areEqual(before.Annual_NOI__c, after.Annual_NOI__c, 'nor the NOI');
        Assert.isNull(after.Occupancy_Pct__c,
            '🔴 AND BLANKS ARE NOT FILLED EITHER. This is the assertion that separates the decision '
            + 'the user took from the softer one they rejected: an empty field on a curated record '
            + 'may be an analyst\'s deliberate deletion, and nothing here can tell that apart from '
            + '"never measured"');
        Assert.areEqual(BUILDING_FIRST_WORDING, o.Property__r.Address__c,
            'STATED CONSEQUENCE, pinned so a silent reversal is visible: the second deal displays '
            + 'the FIRST broker\'s wording of the address, because Opportunity.Property_Address__c '
            + 'is a cross-object formula over the reused Property. The second email\'s wording is '
            + 'not lost — it is on Lead.Property_Address__c');
    }

    /**
     * WITHIN-BATCH DEDUPE — the case the query cannot see, because at the moment of the query
     * NEITHER Lead's building exists yet. One email naming a building twice, or two Leads for one
     * building converted together, must produce ONE Property.
     *
     * ⚠ IT DRIVES THE SERVICE DIRECTLY, AND THAT IS THE POINT, NOT A SHORTCUT. Converting two
     * Leads would not reliably exercise this branch: if the platform happened to fire the
     * after-update trigger once per Lead, the second firing would find the first firing's
     * committed Property and take the ORDINARY reuse path instead — the test would pass while the
     * within-batch branch stayed dead. Re-pointing two already-converted Leads at a THIRD building
     * that exists nowhere guarantees one invocation holding two same-key Leads with no row to find.
     *
     * The surviving Property's NAME is asserted, not just the count: it pins the determinism rule
     * (`createProperties` iterates a SORTED list of Opportunity Ids, so the LOWER Opportunity Id
     * supplies the row). Without that, which of the two brokers' facts become the new building is
     * a coin toss on Map iteration order — reproducible-looking until it is not.
     */
    @isTest
    static void twoLeadsForOneBuildingInOneInvocationProduceOneProperty() {
        List<Lead> pair = TestDataFactory.createLeads(2, true);
        String status = convertedStatus();
        convertChunk(pair, 0, 2, status);

        List<Lead> reRun = reReadForReRun(idsOf(pair));
        Assert.areEqual(2, reRun.size(), 'Both fixtures converted ahead of the re-run');
        Assert.isTrue(readPropertiesByKey(NEW_BUILDING_KEY).isEmpty(),
            'PRECONDITION: the building both Leads are about exists NOWHERE yet, so the reuse '
            + 'query must miss for both and the within-batch branch is the only thing that can '
            + 'stop a duplicate');

        // Re-point both at ONE building, in two different wordings, and name each one so the
        // survivor identifies which Lead supplied it.
        Map<Id, String> nameByOpp = new Map<Id, String>();
        for (Integer i = 0; i < reRun.size(); i++) {
            reRun[i].Property_Address__c = (i == 0) ? NEW_BUILDING_A : NEW_BUILDING_B;
            reRun[i].Property_Name__c = 'Vantage from lead ' + i;
            nameByOpp.put(reRun[i].ConvertedOpportunityId, reRun[i].Property_Name__c);
        }

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(reRun, null);
        Test.stopTest();

        List<Property__c> built = readPropertiesByKey(NEW_BUILDING_KEY);
        Assert.areEqual(1, built.size(),
            'ONE Property for one building, even though BOTH Leads missed the reuse query. Two '
            + 'means the within-batch dedupe is gone and the feature re-creates the duplicate it '
            + 'removes, one transaction later');

        Set<Id> oppIds = new Set<Id>(nameByOpp.keySet());
        Set<Id> linked = propertyIdsOn(oppIds);
        Assert.areEqual(1, linked.size(), 'and BOTH Opportunities point at that same one Property');
        Assert.isTrue(linked.contains(built[0].Id), 'specifically at the row that was inserted');

        List<Id> sortedOppIds = new List<Id>(oppIds);
        sortedOppIds.sort();
        Assert.areEqual(nameByOpp.get(sortedOppIds[0]), built[0].Name,
            'DETERMINISM: the surviving Property came from the LOWER Opportunity Id, because '
            + 'createProperties iterates a sorted Id list. Whichever record wins, it must be the '
            + 'same one on every run — a Map-iteration-order winner is reproducible right up until '
            + 'it is not');
    }

    /**
     * 🔴 A BLANK ADDRESS IS NOT A KEY, AND THE COST OF GETTING THAT WRONG IS THE WORST OUTCOME
     * THIS FEATURE CAN PRODUCE. `normalizeAddress('')` returns `''`. If `''` were stored and
     * matched like any other key, EVERY addressless deal in the org would collapse onto ONE shared
     * "building" — a single Property__c accumulating unrelated deals, with no error anywhere.
     *
     * Branch (c) of the broker-protection routing tree legitimately produces addressless Leads, so
     * this is a live path and not a defensive nicety.
     *
     * ⚠ IT MUST DRIVE THE SERVICE DIRECTLY. `Property_And_Email_Required_To_Convert` refuses
     * `Database.convertLead` when the address is blank, so an addressless Lead cannot reach this
     * service through a conversion at all — the same reason
     * `blankAddressLeavesTheDealNameAloneAndFallsBackToCompany` is written this way. TWO Leads,
     * not one: with a single Lead there is nothing for a wrongly-shared key to collide WITH, and
     * the test would pass against the bug.
     */
    @isTest
    static void addresslessLeadsEachGetTheirOwnUnkeyedProperty() {
        List<Lead> pair = TestDataFactory.createLeads(2, true);
        String status = convertedStatus();
        convertChunk(pair, 0, 2, status);

        List<Lead> reRun = reReadForReRun(idsOf(pair));
        Set<Id> oppIds = new Set<Id>();
        for (Lead l : reRun) {
            l.Property_Address__c = null;   // gate tax only; blanked in memory, as above
            l.Street = null;
            oppIds.add(l.ConvertedOpportunityId);
        }

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(reRun, null);
        Test.stopTest();

        Set<Id> linked = propertyIdsOn(oppIds);
        Assert.areEqual(2, linked.size(),
            'TWO addressless deals get TWO Properties. One means the empty string was treated as a '
            + 'key and the two deals were merged onto a building neither of them named');
        for (Id propertyId : linked) {
            Property__c p = readProperty(propertyId);
            Assert.isNull(p.Normalized_Address__c,
                'and neither Property carries a key at all. Storing \'\' would make every '
                + 'addressless Property in the org match every other one from the next conversion '
                + 'onward — the collapse is silent and cumulative');
            Assert.isNull(p.Address__c, 'no address on the Lead means no address on the Property');
        }
    }

    /**
     * THE GOVERNOR SHAPE OF REUSE, pinned by cancellation rather than by an absolute budget — the
     * technique `packageCarryForwardAddsNoQueryAndNoDml` established, for the same reason: the
     * measured window contains the whole Opportunity-update cascade, whose cost is not this
     * service's to pin.
     *
     * Two invocations over the SAME converted Lead. The first misses the reuse lookup and inserts a
     * Property; the second finds the row the first one just created and inserts nothing. So:
     *   • QUERIES must be IDENTICAL — the lookup runs on both passes. A difference means it became
     *     conditional on something, or moved.
     *   • DML must be EXACTLY ONE LOWER on the reuse pass — that difference IS the `isEmpty()`
     *     guard on the Property insert, which the WS3 header calls out as the reason DML 1 became
     *     conditional. Without the guard, `Database.insert(<empty list>)` still spends a statement
     *     and this assertion fails; without reuse, the second pass inserts a duplicate and it fails
     *     the other way. Both wrong implementations are caught by one number.
     *
     * ⚠ Counters are read INSIDE the Test.startTest()/stopTest() window: stopTest restores the
     * pre-test limit counters, so the same assertion written afterwards is silently vacuous.
     */
    @isTest
    static void reusingAPropertySpendsOneFewerDmlAndTheSameQueries() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Budget Check Holdings';
        l.Property_Address__c = BUILDING_FIRST_WORDING;
        insert l;
        convertOne(l);

        List<Lead> reRun = reReadForReRun(new Set<Id>{ l.Id });
        Assert.areEqual(1, readPropertiesByKey(BUILDING_KEY).size(),
            'PRECONDITION: the conversion created exactly one keyed Property for the pass below to '
            + 'find');

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(reRun, null);   // reuse pass
        Integer q1 = Limits.getQueries();
        Integer d1 = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(reRun, null);   // reuse pass again
        Integer q2 = Limits.getQueries();
        Integer d2 = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(q1 - q0, q2 - q1,
            'Two reuse passes cost the same queries: the lookup is ONE call per invocation whatever '
            + 'it finds');
        Assert.areEqual(d1 - d0, d2 - d1,
            'and the same DML statements — a reuse pass writes no Property at all, twice over');
        Assert.areEqual(1, readPropertiesByKey(BUILDING_KEY).size(),
            'and after two further passes the building STILL has exactly one Property. Before WS3 '
            + 'each re-invocation minted another one');
        Assert.isTrue(d2 - d1 <= 4,
            'A reuse pass spends at most FOUR DML statements, one below the class contract\'s <=5: '
            + 'the Property insert is isEmpty()-guarded and there is nothing to insert. A 5 here '
            + 'means the guard is gone and an empty list is being written');
    }

    /**
     * BULK REUSE at .claude/rules/bulk-test-rule.md volume: 251 conversions naming only TEN
     * buildings, in three punctuation/casing variants each.
     *
     * 🔴 THIS IS THE ONLY TEST THAT PROVES REUSE ACROSS INVOCATIONS AT VOLUME.
     * `Database.convertLead` caps a call at 200, so the 251 run in TWO chunks and this service
     * fires TWICE in one transaction. The first firing (200 Leads) creates all ten buildings; the
     * SECOND (51 Leads) must find every one of them and create nothing. A per-Lead lookup, a
     * lookup that only saw within-batch keys, or no lookup at all each produce a different, larger
     * Property count — the assertion is an equality on 10, not a bound.
     *
     * ⚠ THE THREE WORDING VARIANTS ARE LOAD-BEARING. With one wording per building the same test
     * would pass against an implementation that compared raw `Address__c` strings and never
     * normalized anything.
     */
    @isTest
    static void bulk251ConversionsCollapseSharedBuildingsOntoTenProperties() {
        final Integer BUILDINGS = 10;
        List<Lead> leads = TestDataFactory.createLeads(BULK_N, false);
        Set<String> expectedKeys = new Set<String>();
        for (Integer i = 0; i < leads.size(); i++) {
            String building = String.valueOf(Math.mod(i, BUILDINGS));
            Integer variant = Math.mod(i, 3);
            String wording =
                  variant == 0 ? building + ' Shared Tower, Austin TX'
                : variant == 1 ? building + '  SHARED TOWER., austin  tx'
                :                building + ' shared tower ; Austin,, TX';
            leads[i].Property_Address__c = wording;
            expectedKeys.add(PropertyMatchingService.normalizeAddress(wording));
        }
        Assert.areEqual(BUILDINGS, expectedKeys.size(),
            'Fixture sanity: 251 Leads, three wordings each, must reduce to exactly ' + BUILDINGS
            + ' keys. If the three variants did NOT normalize together this test would be about '
            + 'something else entirely');
        insert leads;

        String status = convertedStatus();
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        convertChunk(leads, 0, 200, status);
        convertChunk(leads, 200, BULK_N, status);
        Integer queryDelta = Limits.getQueries() - queriesBefore;
        Integer dmlDelta = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.isTrue(queryDelta < BULK_N,
            'SOQL for 251 conversions must not scale per-Lead (' + queryDelta + ' queries spent). '
            + 'The reuse lookup is ONE call per invocation, not one per Lead');
        Assert.isTrue(dmlDelta < BULK_N,
            'DML for 251 conversions must not scale per-Lead (' + dmlDelta + ' statements spent)');

        Set<Id> oppIds = new Set<Id>();
        for (Lead c : [
            SELECT ConvertedOpportunityId FROM Lead WHERE Id IN :leads AND IsConverted = true
        ]) {
            oppIds.add(c.ConvertedOpportunityId);
        }
        Assert.areEqual(BULK_N, oppIds.size(), 'All 251 leads convert and produce 251 deals');

        Set<Id> linked = propertyIdsOn(oppIds);
        Assert.areEqual(BUILDINGS, linked.size(),
            '🔴 251 deals share exactly ' + BUILDINGS + ' Properties. 251 means the reuse lookup '
            + 'never ran; a number between the two means the SECOND convertLead chunk did not see '
            + 'the buildings the first one created, which is the failure mode a single-chunk test '
            + 'cannot detect');

        // ONE read for all ten — a per-Id read in this loop would be the very shape this class
        // spends three tests forbidding in the service.
        Set<String> actualKeys = new Set<String>();
        for (Property__c p : [
            SELECT Id, Normalized_Address__c FROM Property__c WHERE Id IN :linked WITH SYSTEM_MODE
        ]) {
            actualKeys.add(p.Normalized_Address__c);
        }
        Assert.areEqual(expectedKeys, actualKeys,
            'and the ten surviving Properties carry exactly the ten keys the 251 wordings reduce '
            + 'to — set equality, so a Property keyed on an un-normalized wording fails here even '
            + 'though the COUNT above would still have been ten');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 6. NULL SAFETY — the ordinary case for a thin email.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ Property_Address__c IS POPULATED ON PURPOSE and is the ONLY extraction field that is (Email
     * comes from TestDataFactory). Property_And_Email_Required_To_Convert refuses a conversion when
     * either is blank, so the thin-email fixture this method used to build can no longer be
     * converted at all. Everything else the pipeline can fill is still empty, which is what this
     * method is about — the "leave the target null" assertions below are untouched.
     *
     * The three claims that genuinely NEEDED a blank address — Opportunity.Name left alone, the
     * Property name falling through to Company, and Property.Address__c staying null — moved intact
     * to blankAddressLeavesTheDealNameAloneAndFallsBackToCompany. They are not dropped, and they are
     * not asserted here against a fixture that can no longer produce them.
     */
    @isTest
    static void blankLeadFieldsLeaveTargetsNull() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Thinmail Holdings';
        l.Deal_Type__c = 'Retail';
        // Everything the extraction pipeline might have filled is empty — the common case when an
        // email names a broker and nothing else — EXCEPT the address the conversion gate demands.
        l.Property_Name__c = null;
        l.Property_Address__c = GATE_ADDRESS;
        l.Asset_Type__c = null;
        l.Guidance_Price__c = null;
        l.Guidance_Cap_Rate__c = null;
        // The LLM-DOWN shape: routing branch (c) creates a Lead from the envelope alone, so
        // ExtractionScoreUtil returns NOT-SCORED and all three numbers are null on the Lead.
        l.Listing_Status__c = null;
        l.Extraction_Score_Pct__c = null;
        l.Fields_Captured_Count__c = null;
        l.Fields_Missing_Count__c = null;
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Name, Property__c, Asking_Price__c, Guidance_Price_Low__c, Guidance_Price_High__c,
                   Guidance_Cap_Rate__c, Offer_Due_Date__c, Sale_Process__c, Parse_Confidence__c,
                   Deal_Room_Link__c, Listing_Broker_Name__c, Listing_Broker_Email__c,
                   Listing_Status__c, Extraction_Score_Pct__c,
                   Fields_Captured_Count__c, Fields_Missing_Count__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.isNull(o.Asking_Price__c, 'An empty lead leaves the Opportunity money fields null');
        Assert.isNull(o.Guidance_Price_Low__c, 'and the range low');
        Assert.isNull(o.Guidance_Price_High__c, 'and the range high');
        Assert.isNull(o.Guidance_Cap_Rate__c, 'and the cap rate');
        Assert.isNull(o.Offer_Due_Date__c, 'and the offer date');
        Assert.isNull(o.Sale_Process__c, 'and the guarded picklists');
        Assert.isNull(o.Parse_Confidence__c, 'and the second guarded picklist');
        Assert.isNull(o.Deal_Room_Link__c, 'and the deal room link');
        Assert.isNull(o.Listing_Broker_Name__c, 'and the listing broker');
        Assert.isNull(o.Listing_Broker_Email__c, 'and their email');
        Assert.isNull(o.Listing_Status__c, 'and the listing status');
        // 🔴 NULL AND ZERO ARE DIFFERENT ANSWERS, AND THE CARRY-FORWARD MUST PRESERVE THE
        // DIFFERENCE. A not-scored Lead (the LLM-down path) means "there was nothing to score";
        // a 0 would claim the model ran and gave us none of the nine, which would put the most
        // urgent-looking chase signal in the org onto the one deal nobody can chase anything
        // about. A `!= null` guard or a defaulting copy in applyDealFields fails HERE.
        Assert.isNull(o.Extraction_Score_Pct__c,
            'A not-scored Lead carries a NULL score to the Opportunity, never a 0');
        Assert.isNull(o.Fields_Captured_Count__c, 'and a null captured count, not a 0');
        Assert.isNull(o.Fields_Missing_Count__c, 'and a null missing count, not a 9');
        Assert.areEqual(GATE_ADDRESS, o.Name,
            'With no property NAME, the deal is named after the address — the second rung of the '
            + 'precedence chain. The third rung (no name and no address, so Name is left alone) is '
            + 'unreachable through a conversion now and is pinned by '
            + 'blankAddressLeavesTheDealNameAloneAndFallsBackToCompany instead');

        Property__c p = [
            SELECT Name, Address__c, Asking_Price__c, Square_Footage__c, Annual_NOI__c, Unit_Count__c,
                   Occupancy_Pct__c, Lot_Size_Acres__c, Lot_Size__c, WALT_Years__c, ADR__c, Zoning__c,
                   Seller_Entity__c, Asset_Type__c
            FROM Property__c WHERE Id = :o.Property__c
        ];
        Assert.areEqual(GATE_ADDRESS, p.Name,
            'and the Property takes the same address as its name when no property name was extracted');
        Assert.areEqual(GATE_ADDRESS, p.Address__c,
            'the address the gate required is still copied onto the Property, not swallowed');
        Assert.isNull(p.Square_Footage__c, 'and no physical facts at all');
        Assert.isNull(p.Annual_NOI__c, 'no NOI');
        Assert.isNull(p.Unit_Count__c, 'no unit count');
        Assert.isNull(p.Occupancy_Pct__c, 'no occupancy');
        Assert.isNull(p.Lot_Size_Acres__c, 'no lot acres');
        Assert.isNull(p.Lot_Size__c, 'and still nothing in the OM square-footage field');
        Assert.isNull(p.WALT_Years__c, 'no WALT');
        Assert.isNull(p.ADR__c, 'no ADR');
        Assert.isNull(p.Zoning__c, 'no zoning');
        Assert.isNull(p.Seller_Entity__c, 'no seller entity');
        Assert.isNull(p.Asset_Type__c, 'and a blank asset type is not forced onto the picklist');
    }

    /**
     * The name-precedence FALLBACK — a lead carrying neither a property name, an address nor a
     * street. Three claims live here, moved verbatim (values and wording) out of
     * blankLeadFieldsLeaveTargetsNull when the conversion gate landed:
     *   1. Opportunity.Name is LEFT ALONE (Name is required; writing null would fail the update);
     *   2. Property.Name falls all the way through to Company;
     *   3. Property.Address__c stays null.
     *
     * ⚠ WHY THIS DRIVES THE SERVICE DIRECTLY INSTEAD OF CONVERTING. Property_And_Email_Required_To_Convert
     * makes a blank Property_Address__c UNCONVERTIBLE, so there is no longer any fixture that reaches
     * this branch through Database.convertLead. The branch is NOT dead code: the rule is enforced
     * only when the org setting "Require Validation for Converted Leads" is on (the rule's own file
     * records that as unverified in the target org and notes it fails OPEN when off), and Broker
     * Protection branch (c) deliberately mints address-less Leads (ARCHITECTURE.md §1). So the
     * fallback still has to be right, and this is the only way left to prove it.
     *
     * The re-invoke pattern (reReadForReRun + oldMap = null) is the one already used by
     * stampCostDoesNotScaleWithBatchSize and opportunityContactRoleIsIdempotent — see the class
     * header's note that a re-run also builds a SECOND Property. That second Property is precisely
     * what this method inspects.
     *
     * The Opportunity.Name reset before the re-run is what makes claim 1 OBSERVABLE: the real
     * conversion had already renamed the deal after GATE_ADDRESS, so without a known sentinel
     * "left alone" and "renamed to the address" would look identical.
     */
    @isTest
    static void blankAddressLeavesTheDealNameAloneAndFallsBackToCompany() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Thinmail Holdings';
        l.Deal_Type__c = 'Retail';
        l.Property_Name__c = null;
        l.Property_Address__c = GATE_ADDRESS; // gate tax only — blanked again below, in memory
        l.Street = null;
        insert l;

        Database.LeadConvertResult res = convertOne(l);
        Id dealId = res.getOpportunityId();
        update new Opportunity(Id = dealId, Name = 'Thinmail Holdings');

        // The thin-email shape the pipeline really produces: a broker, a company, nothing else.
        List<Lead> reRun = reReadForReRun(new Set<Id>{ l.Id });
        reRun[0].Property_Name__c = null;
        reRun[0].Property_Address__c = null;
        reRun[0].Street = null;

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(reRun, null);
        Test.stopTest();

        Opportunity o = [SELECT Name, Property__c FROM Opportunity WHERE Id = :dealId];
        Assert.isTrue(o.Name.contains('Thinmail Holdings'),
            'With neither a property name nor an address, Opportunity.Name is LEFT ALONE — the '
            + 'platform-derived name stands rather than being blanked. Name is required, so writing '
            + 'null here would fail the whole update');

        Property__c p = [
            SELECT Name, Address__c FROM Property__c WHERE Id = :o.Property__c
        ];
        Assert.areEqual('Thinmail Holdings', p.Name,
            'The Property name precedence falls all the way through to Company when the lead carries '
            + 'neither a property name, an address nor a street');
        Assert.isNull(p.Address__c, 'No address on the lead means no address on the Property');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 7. GOVERNOR HEADROOM — the cost must not scale with batch size.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * THE HIGHEST-VALUE ASSERTION IN THIS CLASS. LeadConvertService's contract is 2 SOQL / ≤5 DML
     * PER INVOCATION regardless of batch size; a change that put one query inside
     * the per-Lead loop must fail here rather than in production.
     *
     * ⚠ WHY A COMPARISON RATHER THAN AN ABSOLUTE BUDGET: the measured window contains the whole
     * Opportunity-update cascade (OpportunityReviewTrigger and anything downstream of it), whose
     * cost is not this service's to pin. Comparing a 1-record invocation with a SCALE_N-record one
     * IN THE SAME TRANSACTION cancels that noise: only per-RECORD growth changes the difference.
     * Linear growth would show as +(SCALE_N - 1); SCALE_TOLERANCE (5) is far below that and far
     * above ordinary cascade variation.
     *
     * ⚠ The counters are read INSIDE the Test.startTest()/stopTest() window on purpose —
     * stopTest() restores the pre-test limit counters, so the same assertion written afterwards
     * would be silently vacuous.
     */
    @isTest
    static void stampCostDoesNotScaleWithBatchSize() {
        List<Lead> one = TestDataFactory.createLeads(1, true);
        List<Lead> many = TestDataFactory.createLeads(SCALE_N, true);
        String status = convertedStatus();
        convertChunk(one, 0, 1, status);
        convertChunk(many, 0, SCALE_N, status);

        List<Lead> oneReRun = reReadForReRun(idsOf(one));
        List<Lead> manyReRun = reReadForReRun(idsOf(many));

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(oneReRun, null);
        Integer q1 = Limits.getQueries();
        Integer d1 = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(manyReRun, null);
        Integer q2 = Limits.getQueries();
        Integer d2 = Limits.getDmlStatements();
        Test.stopTest();

        Integer oneQueries = q1 - q0;
        Integer manyQueries = q2 - q1;
        Integer oneDml = d1 - d0;
        Integer manyDml = d2 - d1;

        // ⚠ THE ASSERTION IS ON THE GROWTH, NOT ON THE MANY-RECORD TOTAL. Asserting
        // `manyQueries <= <ceiling>` would be "fifty records under a ceiling" — it would pass a
        // service that got quietly more expensive as long as it stayed under the number, and the
        // number itself would be a guess about the whole conversion cascade. Subtracting the
        // 1-record invocation cancels that cascade cost and leaves only what scales.
        Integer queryGrowth = manyQueries - oneQueries;
        Integer dmlGrowth = manyDml - oneDml;

        Assert.isTrue(queryGrowth <= SCALE_TOLERANCE,
            'SOQL must not scale with batch size. Going from 1 record to ' + SCALE_N + ' grew the '
            + 'query cost by ' + queryGrowth + ' (' + oneQueries + ' -> ' + manyQueries + '); the '
            + 'allowed growth is ' + SCALE_TOLERANCE + '. One query per Lead would grow it by '
            + (SCALE_N - 1) + '. The selector read must stay ONE call for the whole converted set');
        Assert.isTrue(dmlGrowth <= SCALE_TOLERANCE,
            'DML must not scale with batch size. Going from 1 record to ' + SCALE_N + ' grew the '
            + 'statement count by ' + dmlGrowth + ' (' + oneDml + ' -> ' + manyDml + '); the '
            + 'allowed growth is ' + SCALE_TOLERANCE + '. The Property insert, the Opportunity '
            + 'update and each contact-role partition are ONE bulk statement each');
        Assert.isTrue(oneQueries >= 3,
            'Sanity: a single invocation still spends its THREE selector reads (record types, '
            + 'contact roles, and — since WS3, 2026-08-30 — the Property reuse lookup). Raised from '
            + '2 with the header contract. A zero here would mean the measurement, not the service, '
            + 'is broken. ⚠ This is a floor over the whole conversion cascade, not a tight budget, '
            + 'so it is a weak pin on the third read specifically; '
            + 'reusingAPropertySpendsOneFewerDmlAndTheSameQueries is the precise one');
    }

    /**
     * Bulk-safety per .claude/rules/bulk-test-rule.md: 251 lead conversions in
     * one transaction. Database.convertLead caps a single call's LeadConvert
     * list, so 251 is split across two calls (200 + 51) - itself a stronger
     * bulk-safety exercise than a single 251-record DML, since
     * LeadConvertService.stampConvertedOpportunities (and the downstream
     * OpportunityReviewTrigger cascade it feeds) fires twice in one transaction.
     *
     * Extended 2026-08-03 (Conversion Enrichment): the enriched stamp and the broker
     * OpportunityContactRole must both survive that split. The OCR assertion is the sharp one —
     * 251 rows, one per deal, is what a per-INVOCATION read-then-write produces; a per-RECORD one
     * would have exhausted SOQL long before getting here.
     */
    @isTest
    static void bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities() {
        List<Lead> leads = TestDataFactory.createLeads(BULK_N, false);
        // WS2 (2026-08-30): a DISTINCT first-seen instant per Lead. The value is what makes the
        // bulk assertion sharp — the classic bulkification defect is every record in the chunk
        // receiving record 0's value, which "isNotNull on all 251" cannot see and a 251-element
        // distinct set can. Midday, for the GMT/local reason given on
        // carriesBrokerProtectionValuesToTheOpportunity.
        Datetime firstSeenBase = Datetime.newInstance(
            Date.today().addDays(-1), Time.newInstance(12, 0, 0, 0));
        Set<Datetime> expectedFirstSeen = new Set<Datetime>();
        for (Integer i = 0; i < leads.size(); i++) {
            leads[i].Deal_Type__c = Math.mod(i, 2) == 0 ? 'Land' : 'Retail';
            // A representative slice of the enriched field set, one field per target object plus
            // one guarded picklist, so the bulk path exercises all three write shapes.
            leads[i].Building_SF__c = 10000 + i;
            leads[i].Unit_Count__c = 10 + i;
            leads[i].Sale_Process__c = 'Off-Market';
            leads[i].Offer_Due_Date__c = Date.today().addDays(30);
            leads[i].First_Seen_Date__c = firstSeenBase.addDays(-i);
            expectedFirstSeen.add(leads[i].First_Seen_Date__c);
        }
        Assert.areEqual(BULK_N, expectedFirstSeen.size(),
            'Fixture sanity: 251 DISTINCT first-seen instants, or the cross-contamination check '
            + 'below could not detect anything');
        insert leads;

        String status = convertedStatus();
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        convertChunk(leads, 0, 200, status);
        convertChunk(leads, 200, BULK_N, status);
        Integer queryDelta = Limits.getQueries() - queriesBefore;
        Integer dmlDelta = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // Scaling guard. Read inside the window (stopTest restores the pre-test counters). This is
        // deliberately a SCALING bound, not a tight budget: the window covers the entire conversion
        // cascade, not just this service. A change that spends one query or one DML PER LEAD needs
        // 251 of them — it would blow the platform's own 100/150 ceilings first, and fails here
        // either way. The precise per-invocation contract is pinned by
        // stampCostDoesNotScaleWithBatchSize.
        Assert.isTrue(queryDelta < BULK_N,
            'SOQL for 251 conversions must not scale per-Lead (' + queryDelta + ' queries spent)');
        Assert.isTrue(dmlDelta < BULK_N,
            'DML for 251 conversions must not scale per-Lead (' + dmlDelta + ' statements spent)');

        List<Lead> convertedLeads = [
            SELECT Id, ConvertedOpportunityId, ConvertedContactId
            FROM Lead WHERE Id IN :leads AND IsConverted = true
        ];
        System.assertEquals(BULK_N, convertedLeads.size(), 'All 251 leads convert');

        Set<Id> oppIds = new Set<Id>();
        Set<Id> contactIds = new Set<Id>();
        for (Lead l : convertedLeads) {
            oppIds.add(l.ConvertedOpportunityId);
            contactIds.add(l.ConvertedContactId);
        }
        assertBulkOpportunitiesAndProperties(oppIds, expectedFirstSeen);
        assertBulkBrokerRoles(oppIds, contactIds);
    }

    /**
     * 251 Opportunities carry the enriched deal fields; their 251 Properties carry the physical
     * ones.
     *
     * @param oppIds            The converted Opportunities.
     * @param expectedFirstSeen The 251 distinct instants stamped on the source Leads (WS2). The
     *                          SET is compared rather than a per-record map because set equality
     *                          already falsifies the failure mode that matters — one Lead's value
     *                          landing on several deals collapses the set and fails on size.
     */
    private static void assertBulkOpportunitiesAndProperties(
        Set<Id> oppIds,
        Set<Datetime> expectedFirstSeen
    ) {
        List<Opportunity> converted = [
            SELECT Id, Property__c, RecordType.DeveloperName, Lead_Approved_By__c,
                   Asking_Price__c, Sale_Process__c, Offer_Due_Date__c,
                   Broker_First_Seen__c, DPEG_First__c
            FROM Opportunity WHERE Id IN :oppIds
            WITH SYSTEM_MODE
        ];
        System.assertEquals(BULK_N, converted.size(), 'Every converted lead produced its own Opportunity');
        Set<Datetime> actualFirstSeen = new Set<Datetime>();
        Set<Id> propertyIds = new Set<Id>();
        for (Opportunity o : converted) {
            actualFirstSeen.add(o.Broker_First_Seen__c);
            Assert.areEqual(UserInfo.getUserId(), o.DPEG_First__c,
                'Every deal carries its Lead\'s DPEG First. All 251 fixture Leads are owned by '
                + 'the running user, so Lead_Intake_Stamp stamped that Id on each of them');
            System.assertNotEquals(null, o.Property__c, 'Every converted deal gets a linked Property');
            System.assertNotEquals(null, o.RecordType.DeveloperName, 'Record type resolved for every deal');
            System.assertEquals(UserInfo.getUserId(), o.Lead_Approved_By__c,
                'Converting user stamped on every deal');
            Assert.isNotNull(o.Asking_Price__c, 'Every deal carries the guidance price as its asking price');
            Assert.areEqual('Off-Market', o.Sale_Process__c, 'The guarded picklist landed on every deal');
            Assert.isNotNull(o.Offer_Due_Date__c, 'and the offer due date');
            propertyIds.add(o.Property__c);
        }

        // 🔴 THE SHARP ONE. 251 conversions run in TWO convertLead chunks, so this service fires
        // TWICE in one transaction and each firing carries its own subset. A carry-forward that
        // read one Lead and applied it to the whole chunk — or that crossed the two chunks —
        // collapses this set; a per-record map would add plumbing without adding a failure mode
        // this misses.
        Assert.areEqual(BULK_N, actualFirstSeen.size(),
            'EXACTLY 251 DISTINCT broker-first-seen instants — one per deal. A smaller number '
            + 'means values were shared across records, which is the bulkification defect a '
            + 'null-check at volume cannot see');
        Assert.areEqual(expectedFirstSeen, actualFirstSeen,
            'and they are the SAME 251 instants the Leads carried, not merely 251 distinct ones. '
            + 'Set equality also proves nothing was truncated to a date on the way across — both '
            + 'fields are DateTime as of WS2');

        List<Property__c> properties = [
            SELECT Id, Square_Footage__c, Unit_Count__c, Lot_Size__c
            FROM Property__c WHERE Id IN :propertyIds
        ];
        Assert.areEqual(BULK_N, properties.size(), 'Every converted deal built its own Property');
        for (Property__c p : properties) {
            Assert.isNotNull(p.Square_Footage__c, 'Physical facts carried on every Property');
            Assert.isNotNull(p.Unit_Count__c, 'including the new unit count');
            Assert.isNull(p.Lot_Size__c, 'and the OM square-footage field is never written, at any volume');
        }
    }

    /**
     * The sharp bulk assertion: 251 role rows, not 502. A per-RECORD read-then-write would have
     * exhausted SOQL long before getting here; a blind insert would have doubled the count.
     */
    private static void assertBulkBrokerRoles(Set<Id> oppIds, Set<Id> contactIds) {
        List<OpportunityContactRole> roles = [
            SELECT Id, OpportunityId, ContactId, Role, IsPrimary
            FROM OpportunityContactRole WHERE OpportunityId IN :oppIds
        ];
        Assert.areEqual(BULK_N, roles.size(),
            'EXACTLY 251 role rows — one per deal, not two. The read-then-write updated the row '
            + 'standard conversion created for each Opportunity across BOTH convertLead chunks');
        Set<Id> roleOppIds = new Set<Id>();
        for (OpportunityContactRole r : roles) {
            Assert.areEqual('Broker', r.Role, 'Every role row names the Broker');
            Assert.isTrue(r.IsPrimary, 'and is primary on its deal');
            Assert.isTrue(contactIds.contains(r.ContactId), 'and points at that deal\'s converted Contact');
            roleOppIds.add(r.OpportunityId);
        }
        Assert.areEqual(BULK_N, roleOppIds.size(), 'One role per distinct Opportunity — no doubled-up deals');
    }

    private static void convertChunk(List<Lead> leads, Integer fromIndex, Integer toIndex, String status) {
        List<Database.LeadConvert> converts = new List<Database.LeadConvert>();
        for (Integer i = fromIndex; i < toIndex; i++) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(leads[i].Id);
            lc.setConvertedStatus(status);
            converts.add(lc);
        }
        List<Database.LeadConvertResult> results = Database.convertLead(converts, false);
        for (Database.LeadConvertResult r : results) {
            System.assert(r.isSuccess(), 'Each lead in the bulk chunk should convert successfully');
        }
    }
}
