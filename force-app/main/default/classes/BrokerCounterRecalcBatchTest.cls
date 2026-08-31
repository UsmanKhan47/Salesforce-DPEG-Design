/**
 * Tests for `BrokerCounterRecalcBatch` — the nightly broker counter recalculation — and for the
 * three selector methods it added (`ContactSelector.queryBrokerCounterTargets`,
 * `OpportunitySelector.aggregateDealCountsByBroker`,
 * `LeadSelector.aggregateFirstSeenByConvertedContact`).
 *
 * ═══ 🔴 §A THE ONE TEST THAT JUSTIFIES THE WHOLE DESIGN: `resetsStaleCountersToZero` ═══
 * The design chose a **Contact-rooted** batch over the obvious Opportunity-rooted one for exactly
 * one reason: only a job that visits EVERY broker can push a stale count back to **0**. An
 * Opportunity-rooted job never visits a broker whose deals were deleted or reassigned, so their
 * old number survives forever and reads as live — a wrong answer that never surfaces as an error.
 *
 * `resetsStaleCountersToZero` is the falsifier for that decision, and `bulkResetsAndRecalculates`
 * repeats it at 251 rows. If someone "optimises" the locator with a
 * `WHERE the broker has deals` / `LastModifiedDate` predicate, or repoints the batch at
 * Opportunity, those two go red and nothing else does. Do not weaken them.
 *
 * ═══ §B WHY THERE IS NO `@TestSetup`, AND IT IS NOT AN OVERSIGHT ═══
 * 🔴 **The batch's locator is deliberately UNFILTERED — it selects every broker Contact in the
 * org.** So any Contact a `@TestSetup` created would appear in EVERY test's scope and be
 * recalculated and asserted against by tests that know nothing about it. A shared fixture here
 * does not merely waste time, it silently changes what each test is measuring: a reset test would
 * be reading counters some other test's deals contributed to. Each method therefore builds only
 * the brokers it intends the batch to see. The cost is real and accepted.
 *
 * ═══ 🔴 §C EVERY FIXTURE DML AND EVERY READ-BACK USES EXPLICIT `AccessLevel.SYSTEM_MODE` ═══
 * `Contact.Deals_Lost__c` and `Contact.First_Submission_DateTime__c` are new in this change. A
 * Metadata-API-deployed custom field arrives with **NO `FieldPermissions` for any profile, System
 * Administrator included** — and a field with zero grants is measured on this project to make
 * **plain SOQL and plain DML refuse outright** (`fields being inaccessible`), not silently drop
 * the column. A test that hand-built a Contact carrying those two fields and saved it with a bare
 * `update` would therefore fail for a PERMISSIONS reason wearing a schema error, on the very
 * administrator running the deploy, and would keep failing until an unrelated permission-set
 * change landed.
 *
 * ⚠ That rule applies to CALLER-BUILT payloads, which is exactly what a fixture is. It does NOT
 * apply to the production code under test — `BrokerCounterRecalcBatch` already writes through
 * `AccessLevel.SYSTEM_MODE` by design. So the SYSTEM_MODE here is about the FIXTURES, and removing
 * it would couple this test class's fate to an admin deliverable it does not own.
 *
 * ═══ §D BULK VOLUME IS 251, AND THE BATCH SIZE IS RAISED TO MATCH — DELIBERATELY ═══
 * `.claude/rules/bulk-test-rule.md` applies in full (no exemption: this is a batch job over a real
 * population). `bulkResetsAndRecalculates` uses **251 broker Contacts**.
 *
 * ⚠ THE BATCH SIZE PASSED IN THAT TEST IS 251, **NOT** `BrokerCounterRecalcBatch.SCOPE` (100), and
 * that is required rather than convenient: **a test method executes only ONE `execute()`
 * invocation**, so at a batch size of 100 the other 151 brokers would never be processed and the
 * test would assert a bulk property it had not exercised. Production still runs at SCOPE = 100 for
 * the `AggregateResult` reason in the batch header §2a; `scopeIsOneHundredNotTwoHundred` pins that
 * separately so raising the test's batch size cannot be mistaken for changing the production one.
 *
 * ⚠ DEAL volume is kept well below the broker volume on purpose. The bulk dimension under test is
 * the number of BROKERS (the locator and the two aggregates' IN-clause). Every Opportunity insert
 * additionally fans out through `OpportunityReviewTrigger`'s five services — `TestDataFactory`
 * records that 251 Opportunities cost 753 DML rows through the NDA cascade alone — so inflating
 * the deal count would spend the transaction's budget proving nothing this class is responsible
 * for. `governorCostIsConstantInTheNumberOfDeals` is where deal volume is actually varied.
 *
 * ═══ §E GOVERNOR ASSERTIONS READ IN-CONTEXT STATICS, NEVER `Limits.*` AFTER `stopTest()` ═══
 * `Database.Stateful` serialises the batch instance, so the object handed to
 * `Database.executeBatch` is NOT the object that ran — its instance fields never move. And
 * `Test.stopTest()` RESTORES the pre-test governor counters, so a `Limits.getQueries()` assertion
 * placed after it is **silently vacuous**. Both traps are avoided the way this repo already does
 * it: `BrokerCounterRecalcBatch.chunkQueries` / `.chunkDmlStatements` are captured INSIDE the
 * async transaction and read afterwards.
 *
 * @see BrokerCounterRecalcBatch.cls (§0 — and 🔴 read why the leaderboard is untouched)
 */
@IsTest
private class BrokerCounterRecalcBatchTest {

    /** `.claude/rules/bulk-test-rule.md`'s mandate. See §D for why the batch size matches it. */
    private static final Integer BULK_BROKERS = 251;

    /** Brokers in the bulk fixture that actually have deals. See §D on why this is small. */
    private static final Integer BULK_BROKERS_WITH_DEALS = 20;

    /** The stale values a reset test pre-stamps, chosen to be obviously not-derivable from zero. */
    private static final Integer STALE_SUBMITTED = 9;
    private static final Integer STALE_WON = 5;
    private static final Integer STALE_LOST = 4;

    // ═══════════════════════════════════════════════════════════════════════════
    // FIXTURE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * A broker Contact parented to a Broker_Firm Account.
     *
     * ⚠ THE ACCOUNT IS NOT DECORATION. `Contact.Record_Type_Matches_Account` is an ACTIVE
     * validation rule, so a Broker-record-type Contact must hang off a Broker_Firm Account or the
     * insert is refused — and separately, an ACCOUNT-LESS Contact is owner-private regardless of
     * OWD, which is the very hazard `ContactSelector.CounterTargetReads` exists to escape.
     * `TestDataFactory.createAccount` stamps Broker_Firm, so this pairing is correct by
     * construction.
     *
     * @return An inserted broker Contact with all four counters still null.
     */
    private static Contact newBroker() {
        return newBrokers(1)[0];
    }

    /**
     * Several broker Contacts under ONE Broker_Firm Account.
     *
     * 🔴 THE SHARED ACCOUNT IS NOT A TIDY-UP — CALLING `newBroker()` TWICE FAILS.
     * `TestDataFactory.createAccounts` generates its Name/Phone from a LOOP INDEX that resets to 0
     * on every call, and unlike its Contact sibling it saves through the plain `insertIf` rather
     * than `insertAllowingDuplicates`. Two separate `createAccount(true)` calls in one transaction
     * therefore produce two identically-shaped Accounts, which the org's active
     * `Standard_Account_Duplicate_Rule` refuses with `DUPLICATES_DETECTED` — measured here on
     * 2026-08-31 when `doesNotCountAnotherBrokersDeals` originally built its two brokers that way.
     * ⚠ The error names the CONTACT-shaped symptom ("Duplicate Alert: []") with no field detail, so
     * it reads like a Contact problem. It is not. One Account, N Contacts.
     *
     * @param count How many broker Contacts.
     * @return The inserted broker Contacts, counters still null.
     */
    private static List<Contact> newBrokers(Integer count) {
        Account firm = TestDataFactory.createAccount(true);
        return TestDataFactory.createBrokerContacts(count, firm.Id, true);
    }

    /**
     * Opportunities at a given stage, all naming one broker.
     *
     * ⚠ THE RECORD TYPE IS NAMED EXPLICITLY ('Retail') rather than left to the running user's
     * default. Record-type picklist restriction IS enforced by DML in this org (measured four
     * times), and only the Retail business process is known to carry both terminal stages. A
     * default-record-type fixture would be a coin flip that fails as an opaque picklist error.
     *
     * ⚠ `Rejection_Reason__c` IS SET FOR 'Dead/Pass' AND MUST BE. `Rejection_Reason_Required_On_Dead`
     * fires on `OR(ISNEW(), ISCHANGED(StageName))` — the insert-time half was added in this same
     * programme (design ITEM 1), so inserting straight at Dead/Pass without a reason is refused.
     * A fixture written before that tightening would fail here for a reason that looks unrelated.
     *
     * @param brokerId The Contact to stamp on `Broker__c`.
     * @param stage    The `StageName` to insert at.
     * @param count    How many deals.
     * @return The inserted Opportunities.
     */
    private static List<Opportunity> dealsFor(Id brokerId, String stage, Integer count) {
        List<Opportunity> deals =
            TestDataFactory.createOpportunitiesByRecordType(count, 'Retail', null, false);
        for (Opportunity deal : deals) {
            deal.Broker__c = brokerId;
            deal.StageName = stage;
            if (stage == 'Dead/Pass') {
                deal.Rejection_Reason__c = 'Other';
            }
        }
        insert deals;
        return deals;
    }

    /**
     * Force a broker's stored counters to a known state. See §C for why this is SYSTEM_MODE.
     *
     * @param brokerId  The broker to stamp.
     * @param submitted Value for `Deals_Submitted__c`.
     * @param won       Value for `Deals_Won__c`.
     * @param lost      Value for `Deals_Lost__c`.
     * @param firstSeen Value for `First_Submission_DateTime__c`; may be null.
     */
    private static void stampCounters(
        Id brokerId, Integer submitted, Integer won, Integer lost, Datetime firstSeen
    ) {
        stampCounters(new List<Id>{ brokerId }, submitted, won, lost, firstSeen);
    }

    /**
     * Bulk form of `stampCounters` — one DML statement for the whole list.
     *
     * @param brokerIds The brokers to stamp.
     * @param submitted Value for `Deals_Submitted__c`.
     * @param won       Value for `Deals_Won__c`.
     * @param lost      Value for `Deals_Lost__c`.
     * @param firstSeen Value for `First_Submission_DateTime__c`; may be null.
     */
    private static void stampCounters(
        List<Id> brokerIds, Integer submitted, Integer won, Integer lost, Datetime firstSeen
    ) {
        List<Contact> shells = new List<Contact>();
        for (Id brokerId : brokerIds) {
            shells.add(new Contact(
                Id = brokerId,
                Deals_Submitted__c = submitted,
                Deals_Won__c = won,
                Deals_Lost__c = lost,
                First_Submission_DateTime__c = firstSeen
            ));
        }
        Database.update(shells, true, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Re-read brokers' counters after the batch. See §C for why this is SYSTEM_MODE.
     *
     * @param brokerIds The brokers to read.
     * @return The rows keyed by Id.
     */
    private static Map<Id, Contact> reload(Set<Id> brokerIds) {
        List<Contact> rows = (List<Contact>) Database.queryWithBinds(
            'SELECT Id, Deals_Submitted__c, Deals_Won__c, Deals_Lost__c, '
            + 'First_Submission_DateTime__c FROM Contact WHERE Id IN :ids',
            new Map<String, Object>{ 'ids' => brokerIds },
            AccessLevel.SYSTEM_MODE
        );
        return new Map<Id, Contact>(rows);
    }

    /**
     * Convenience single-row form of `reload`.
     *
     * @param brokerId The broker to read.
     * @return The row.
     */
    private static Contact reload(Id brokerId) {
        return reload(new Set<Id>{ brokerId }).get(brokerId);
    }

    /**
     * Run one pass.
     *
     * @param batchSize The chunk size. See §D on why the bulk test does not pass `SCOPE`.
     */
    private static void runBatch(Integer batchSize) {
        Test.startTest();
        Database.executeBatch(new BrokerCounterRecalcBatch(), batchSize);
        Test.stopTest();
    }

    /** @return This org's converted Lead status label. */
    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // §A — THE RESET. THE REASON THE BATCH IS ROOTED AT CONTACT.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE DESIGN'S FALSIFIER. A broker carrying counts whose deals no longer exist must be
     * pushed back to zero — not left alone, and not skipped.
     *
     * An Opportunity-rooted batch physically cannot pass this: with no Opportunity naming this
     * broker there is nothing to iterate, so the broker is never visited and keeps 9/5/4 forever.
     * Read the class header §A before changing anything here.
     */
    @IsTest
    static void resetsStaleCountersToZero() {
        Contact broker = newBroker();
        stampCounters(broker.Id, STALE_SUBMITTED, STALE_WON, STALE_LOST, Datetime.now());

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Contact after = reload(broker.Id);
        Assert.areEqual(0, after.Deals_Submitted__c.intValue(),
            'Deals_Submitted__c must reset to 0 for a broker with no deals — a stale count that '
            + 'survives is exactly the bug the Contact-rooted design exists to prevent');
        Assert.areEqual(0, after.Deals_Won__c.intValue(),
            'Deals_Won__c must reset to 0 for a broker with no deals');
        Assert.areEqual(0, after.Deals_Lost__c.intValue(),
            'Deals_Lost__c must reset to 0 for a broker with no deals');
        Assert.isNull(after.First_Submission_DateTime__c,
            'First_Submission_DateTime__c must reset to null for a broker with no converted Lead');
    }

    /**
     * The reset is per-field, not all-or-nothing: a broker whose deals shrank from three to one
     * must go DOWN to 1, not stay at 3. This is the partial case `resetsStaleCountersToZero`
     * cannot reach, and the one an "only ever increase" implementation would pass by accident.
     */
    @IsTest
    static void reducesACountWhenDealsWereRemoved() {
        Contact broker = newBroker();
        dealsFor(broker.Id, 'New', 1);
        stampCounters(broker.Id, STALE_SUBMITTED, STALE_WON, STALE_LOST, null);

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Contact after = reload(broker.Id);
        Assert.areEqual(1, after.Deals_Submitted__c.intValue(),
            'Deals_Submitted__c must fall from the stale 9 to the true 1');
        Assert.areEqual(0, after.Deals_Won__c.intValue(),
            'Deals_Won__c must fall from the stale 5 to 0');
        Assert.areEqual(0, after.Deals_Lost__c.intValue(),
            'Deals_Lost__c must fall from the stale 4 to 0');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // THE THREE COUNTS
    // ═══════════════════════════════════════════════════════════════════════════

    /** Submitted / won / lost are counted from one broker's own deals, per the ITEM 6.2 definitions. */
    @IsTest
    static void countsSubmittedWonAndLost() {
        Contact broker = newBroker();
        dealsFor(broker.Id, 'New', 3);
        dealsFor(broker.Id, 'Closed Won', 2);
        dealsFor(broker.Id, 'Dead/Pass', 1);

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Contact after = reload(broker.Id);
        Assert.areEqual(6, after.Deals_Submitted__c.intValue(),
            'Deals_Submitted__c is ALL deals naming this broker — 3 New + 2 Closed Won + 1 Dead/Pass');
        Assert.areEqual(2, after.Deals_Won__c.intValue(),
            'Deals_Won__c counts only StageName = Closed Won');
        Assert.areEqual(1, after.Deals_Lost__c.intValue(),
            'Deals_Lost__c counts only StageName = Dead/Pass');
    }

    /**
     * A won deal is ALSO a submitted deal. Falsifies the plausible misreading in which
     * `Deals_Submitted__c` means "open deals" and the three counts partition rather than nest —
     * under which this broker would read 0 submitted, and the number a page shows would drop the
     * moment a deal closed.
     */
    @IsTest
    static void wonAndLostDealsAlsoCountAsSubmitted() {
        Contact broker = newBroker();
        dealsFor(broker.Id, 'Closed Won', 1);
        dealsFor(broker.Id, 'Dead/Pass', 1);

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Contact after = reload(broker.Id);
        Assert.areEqual(2, after.Deals_Submitted__c.intValue(),
            'A closed deal is still a submitted deal — Deals_Submitted__c must be 2, not 0');
        Assert.areEqual(1, after.Deals_Won__c.intValue(), 'one Closed Won');
        Assert.areEqual(1, after.Deals_Lost__c.intValue(), 'one Dead/Pass');
    }

    /**
     * The losing stage is spelled `Dead/Pass` — NOT `Dead`. Pinned as its own assertion because a
     * one-word slip would not break the compile, would not break `countsSubmittedWonAndLost`'s
     * submitted total, and would simply leave every broker's loss count permanently at 0.
     */
    @IsTest
    static void theLostStageLiteralIsDeadSlashPass() {
        Assert.areEqual('Closed Won', BrokerCounterRecalcBatch.STAGE_WON,
            'the winning StageName literal must not drift');
        Assert.areEqual('Dead/Pass', BrokerCounterRecalcBatch.STAGE_LOST,
            'the losing StageName is Dead/Pass — "Dead" alone matches nothing and silently zeroes '
            + 'Deals_Lost__c for the whole org');
    }

    /** One broker's deals must never be counted against another. */
    @IsTest
    static void doesNotCountAnotherBrokersDeals() {
        List<Contact> pair = newBrokers(2);
        Contact mine = pair[0];
        Contact theirs = pair[1];
        dealsFor(mine.Id, 'New', 2);
        dealsFor(theirs.Id, 'Closed Won', 3);

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Map<Id, Contact> after = reload(new Set<Id>{ mine.Id, theirs.Id });
        Assert.areEqual(2, after.get(mine.Id).Deals_Submitted__c.intValue(),
            'the first broker sees only their own 2 deals');
        Assert.areEqual(0, after.get(mine.Id).Deals_Won__c.intValue(),
            'the first broker has no wins — the second broker\'s 3 must not leak across');
        Assert.areEqual(3, after.get(theirs.Id).Deals_Won__c.intValue(),
            'the second broker sees their own 3 wins');
    }

    /** A deal with no broker must not be attributed to anyone. */
    @IsTest
    static void ignoresDealsWithNoBroker() {
        Contact broker = newBroker();
        dealsFor(broker.Id, 'New', 1);
        // Broker__c left null.
        insert TestDataFactory.createOpportunitiesByRecordType(2, 'Retail', null, false);

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Assert.areEqual(1, reload(broker.Id).Deals_Submitted__c.intValue(),
            'only the deal naming this broker counts; the two broker-less deals belong to nobody');
    }

    /** A Contact that is not on the Broker record type is outside the locator entirely. */
    @IsTest
    static void doesNotTouchNonBrokerContacts() {
        Contact outsider = TestDataFactory.createNonBrokerContact(null, true);
        stampCounters(outsider.Id, STALE_SUBMITTED, STALE_WON, STALE_LOST, null);

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Contact after = reload(outsider.Id);
        Assert.areEqual(STALE_SUBMITTED, after.Deals_Submitted__c.intValue(),
            'a non-broker Contact is not in the locator, so its counters must be left exactly as '
            + 'they were — including a wrong one. Widening the record-type filter would red this.');
        Assert.areEqual(STALE_WON, after.Deals_Won__c.intValue(),
            'a non-broker Contact\'s Deals_Won__c must be left alone');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FIRST SUBMISSION — THE LEAD JOIN
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * `First_Submission_DateTime__c` comes from the broker's converted Lead, via
     * `ConvertedContactId` — an exact Id join, not an email match.
     *
     * ⚠ Conversion is used rather than a hand-set `ConvertedContactId` because that field is not
     * writeable: `Database.convertLead` is the only way to produce the shape this aggregate reads.
     * A useful side effect is that the fixture is the real production shape — `LeadConvertService`
     * also stamps `Opportunity.Broker__c = ConvertedContactId`, which is why the deal count below
     * is asserted as 1 rather than 0.
     */
    @IsTest
    static void firstSubmissionComesFromTheConvertedLead() {
        Datetime seenAt = Datetime.newInstanceGmt(2026, 3, 4, 5, 6, 7);
        Lead lead = TestDataFactory.createLead(false);
        lead.First_Seen_Date__c = seenAt;
        insert lead;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(lead.Id);
        lc.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult result = Database.convertLead(lc);
        Assert.isTrue(result.isSuccess(), 'the fixture Lead must convert');
        Id brokerId = result.getContactId();

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Contact after = reload(brokerId);
        Assert.areEqual(seenAt, after.First_Submission_DateTime__c,
            'First_Submission_DateTime__c must be the converted Lead\'s First_Seen_Date__c, to the '
            + 'instant — both fields are DateTime, so nothing may be truncated to a date');
        Assert.areEqual(1, after.Deals_Submitted__c.intValue(),
            'conversion also creates the Opportunity and stamps Broker__c, so the same Contact '
            + 'legitimately has one submitted deal');
    }

    /**
     * With two Leads on one broker, the EARLIEST wins — the aggregate is `MIN`, not "any" and not
     * "latest". The second Lead is attached to the already-converted Contact explicitly, so the
     * test does not depend on Smart Lead Conversion's email matching to produce the shape.
     */
    @IsTest
    static void firstSubmissionIsTheEarliestOfSeveralLeads() {
        Datetime earlier = Datetime.newInstanceGmt(2025, 1, 2, 3, 4, 5);
        Datetime later = Datetime.newInstanceGmt(2026, 7, 8, 9, 10, 11);

        Lead first = TestDataFactory.createLead(false);
        first.First_Seen_Date__c = later;
        insert first;
        Database.LeadConvert lc1 = new Database.LeadConvert();
        lc1.setLeadId(first.Id);
        lc1.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult res1 = Database.convertLead(lc1);
        Assert.isTrue(res1.isSuccess(), 'the first fixture Lead must convert');

        Lead second = TestDataFactory.createLead(false);
        second.First_Seen_Date__c = earlier;
        insert second;
        Database.LeadConvert lc2 = new Database.LeadConvert();
        lc2.setLeadId(second.Id);
        lc2.setConvertedStatus(convertedStatus());
        lc2.setAccountId(res1.getAccountId());
        lc2.setContactId(res1.getContactId());
        Database.LeadConvertResult res2 = Database.convertLead(lc2);
        Assert.isTrue(res2.isSuccess(), 'the second fixture Lead must convert onto the same Contact');

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Assert.areEqual(earlier, reload(res1.getContactId()).First_Submission_DateTime__c,
            'MIN(First_Seen_Date__c) must return the EARLIER of the two Leads — returning the '
            + 'later one would make a long-standing broker look brand new');
    }

    /** A broker who never came from a Lead has no first-submission instant, and that is null. */
    @IsTest
    static void brokerWithNoLeadGetsNullFirstSubmission() {
        Contact broker = newBroker();
        dealsFor(broker.Id, 'New', 1);
        stampCounters(broker.Id, STALE_SUBMITTED, STALE_WON, STALE_LOST, Datetime.now());

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Assert.isNull(reload(broker.Id).First_Submission_DateTime__c,
            'a broker with deals but no converted Lead must have First_Submission_DateTime__c '
            + 'CLEARED, not left at its stale value — the reset applies to all four fields');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNOR SHAPE AND THE NO-OP SKIP
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * A pass over brokers whose stored counters are already correct must write NOTHING — no DML
     * statement at all. This is what stops a nightly job churning `LastModifiedDate`, field
     * history and every downstream trigger on a roster that did not change (batch header §2b).
     *
     * ⚠ It is also the reason `isChanged` must treat null and 0 as DIFFERENT: the broker here is
     * pre-stamped with explicit ZEROES, not left null. A version that skipped on null-vs-zero
     * would pass this test and never perform the day-one backfill at all.
     */
    @IsTest
    static void quietRunWritesNothing() {
        Contact broker = newBroker();
        stampCounters(broker.Id, 0, 0, 0, null);

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Assert.areEqual(1, BrokerCounterRecalcBatch.chunkEvaluated,
            'the broker must still be evaluated — skipping the WRITE is not skipping the ROW');
        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkChanged,
            'nothing changed, so no Contact should have been queued for update');
        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkDmlStatements,
            'a quiet night must cost ZERO DML statements');
    }

    /**
     * The per-chunk cost is 2 SOQL and at most 1 DML, and it does NOT grow with the number of
     * deals. A change that added a query or an update per deal would show here as a number far
     * above 2 — which is the whole reason this work is a batch and not a trigger.
     *
     * ⚠ Read via in-context statics, never `Limits.*` after `stopTest()`. See §E.
     */
    @IsTest
    static void governorCostIsConstantInTheNumberOfDeals() {
        Contact broker = newBroker();
        dealsFor(broker.Id, 'New', 15);
        dealsFor(broker.Id, 'Closed Won', 10);

        runBatch(BrokerCounterRecalcBatch.SCOPE);

        Assert.areEqual(2, BrokerCounterRecalcBatch.chunkQueries,
            '25 deals must still cost exactly 2 queries — one Opportunity aggregate, one Lead '
            + 'aggregate. Any other number means a read moved inside a loop.');
        Assert.areEqual(1, BrokerCounterRecalcBatch.chunkDmlStatements,
            '25 deals must still cost exactly 1 DML statement for the one broker that changed');
        Assert.areEqual(25, reload(broker.Id).Deals_Submitted__c.intValue(),
            'and the count itself must be right — a constant-cost job that computes the wrong '
            + 'number is not a passing test');
    }

    /**
     * 🔴 Pins `SCOPE = 100`. It is DERIVED, not inherited: the deal aggregate groups by broker AND
     * stage, so a chunk yields up to `|brokers| × 10 stages` rows and an `AggregateResult` list
     * throws above 2,000. At 200 a full chunk lands exactly on that cliff. Batch header §2a.
     *
     * This exists because 200 is the number every other batch in this repo uses, so "aligning"
     * this one looks like tidying up. It is not — it would reintroduce a swallowed chunk failure.
     */
    @IsTest
    static void scopeIsOneHundredNotTwoHundred() {
        Assert.areEqual(100, BrokerCounterRecalcBatch.SCOPE,
            'SCOPE is 100, derived from the 2,000-row AggregateResult cap crossed with '
            + 'Opportunity\'s 10 stages. Do not raise it to match the sibling batches without '
            + 'redoing the arithmetic in the batch header §2a.');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BULK — 251 BROKERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE BULK TEST, AND IT IS ALSO THE BULK RESET TEST. 251 broker Contacts, all pre-stamped
     * with stale counts; only 20 of them actually have deals. The other 231 must every one of them
     * come back to zero.
     *
     * That combination is deliberate: a bulkification bug and a reset bug fail this test in
     * visibly different ways (a wrong total vs. a surviving 9), and running the reset at 251 rows
     * is what proves the reset is not a single-record accident.
     *
     * ⚠ Batch size is 251, not `SCOPE`. See §D — a test executes only ONE chunk, so at 100 the
     * remaining 151 brokers would never be visited and this test would assert nothing about them.
     */
    @IsTest
    static void bulkResetsAndRecalculates() {
        Account firm = TestDataFactory.createAccount(true);
        List<Contact> brokers = TestDataFactory.createBrokerContacts(BULK_BROKERS, firm.Id, true);
        Assert.areEqual(BULK_BROKERS, brokers.size(), 'the bulk fixture must be 251 brokers');

        List<Id> brokerIds = new List<Id>();
        for (Contact broker : brokers) {
            brokerIds.add(broker.Id);
        }
        stampCounters(brokerIds, STALE_SUBMITTED, STALE_WON, STALE_LOST, Datetime.now());

        // One 'Closed Won' deal each for the first 20 brokers — built and inserted in ONE
        // statement so the fixture itself is not the thing that runs out of DML.
        List<Opportunity> deals = TestDataFactory.createOpportunitiesByRecordType(
            BULK_BROKERS_WITH_DEALS, 'Retail', null, false
        );
        for (Integer i = 0; i < deals.size(); i++) {
            deals[i].Broker__c = brokerIds[i];
            deals[i].StageName = 'Closed Won';
        }
        insert deals;

        runBatch(BULK_BROKERS);

        Assert.areEqual(BULK_BROKERS, BrokerCounterRecalcBatch.chunkEvaluated,
            'all 251 brokers must be evaluated in the single chunk');
        Assert.areEqual(BULK_BROKERS, BrokerCounterRecalcBatch.chunkChanged,
            'all 251 changed — 20 gained real counts, 231 were reset from the stale 9/5/4');
        Assert.areEqual(BULK_BROKERS, BrokerCounterRecalcBatch.chunkUpdated,
            'all 251 must have been written successfully');
        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkWriteFailures,
            'no counter write may be refused');
        Assert.areEqual(2, BrokerCounterRecalcBatch.chunkQueries,
            '251 brokers must still cost exactly 2 queries — the IN-clause is bound, not looped');
        Assert.areEqual(1, BrokerCounterRecalcBatch.chunkDmlStatements,
            '251 brokers must still cost exactly 1 DML statement');

        Map<Id, Contact> after = reload(new Set<Id>(brokerIds));
        Integer withDeals = 0;
        Integer resetToZero = 0;
        for (Integer i = 0; i < BULK_BROKERS; i++) {
            Contact row = after.get(brokerIds[i]);
            if (i < BULK_BROKERS_WITH_DEALS) {
                if (row.Deals_Submitted__c == 1 && row.Deals_Won__c == 1 && row.Deals_Lost__c == 0) {
                    withDeals++;
                }
            } else if (row.Deals_Submitted__c == 0 && row.Deals_Won__c == 0
                       && row.Deals_Lost__c == 0 && row.First_Submission_DateTime__c == null) {
                resetToZero++;
            }
        }
        Assert.areEqual(BULK_BROKERS_WITH_DEALS, withDeals,
            'every broker with a Closed Won deal must read 1 submitted / 1 won / 0 lost');
        Assert.areEqual(BULK_BROKERS - BULK_BROKERS_WITH_DEALS, resetToZero,
            'every one of the 231 deal-less brokers must be fully reset — a single survivor of '
            + 'the stale 9/5/4 means the reset does not hold at volume');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEFENSIVE PATHS
    //
    // ⚠ These call `execute` DIRECTLY rather than through `Database.executeBatch`, because the
    // platform never hands a batch a null or empty scope — so the guards are unreachable through
    // the normal entry point and would otherwise sit uncovered while still being the right thing
    // to write. Calling the method directly is the only honest way to exercise them.
    // ═══════════════════════════════════════════════════════════════════════════

    /** A null scope must return quietly rather than dereferencing it. */
    @IsTest
    static void executeIsSafeForANullScope() {
        Test.startTest();
        new BrokerCounterRecalcBatch().execute(null, null);
        Test.stopTest();

        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkQueries,
            'a null scope must issue no query at all');
    }

    /** An empty scope must return quietly and, crucially, must not query with an empty IN-clause. */
    @IsTest
    static void executeIsSafeForAnEmptyScope() {
        Test.startTest();
        new BrokerCounterRecalcBatch().execute(null, new List<Contact>());
        Test.stopTest();

        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkQueries,
            'an empty scope must issue no query — two aggregates over nothing would be pure waste');
        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkDmlStatements,
            'an empty scope must write nothing');
    }

    /** A scope of nothing but nulls resolves to no broker Ids, so it must short-circuit too. */
    @IsTest
    static void executeIgnoresNullRowsInTheScope() {
        Test.startTest();
        new BrokerCounterRecalcBatch().execute(null, new List<Contact>{ null, null });
        Test.stopTest();

        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkQueries,
            'null rows contribute no Ids, so the aggregates must be skipped entirely');
        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkEvaluated,
            'a null row is not an evaluated broker');
    }

    /** Both folds tolerate a null aggregate list rather than assuming the selector returned one. */
    @IsTest
    static void foldHelpersAreNullSafe() {
        Assert.areEqual(0, BrokerCounterRecalcBatch.foldDealCounts(null).size(),
            'foldDealCounts(null) must yield an empty map, not throw');
        Assert.areEqual(0, BrokerCounterRecalcBatch.foldFirstSeen(null).size(),
            'foldFirstSeen(null) must yield an empty map, not throw');
    }

    /**
     * 🔴 A REFUSED COUNTER WRITE MUST BE COUNTED AND LOGGED, NOT SWALLOWED.
     *
     * `allOrNone = false` is deliberate — one bad broker must not cost the other 99 their counters
     * — but its cost is that a refusal arrives as a `SaveResult`, never as an exception. The
     * broker then simply keeps yesterday's number, which looks exactly like a correct one. This
     * project has already paid for that combination once, on an approval's parent write that
     * failed silently for every approver who did not own the record.
     *
     * A hard-deleted Contact is used as the refusal because it is the one failure mode a test can
     * produce deterministically without depending on a persona, a sharing rule or an FLS grant.
     * What is under test is the HANDLING — `chunkWriteFailures` moves and nothing throws — not the
     * particular reason the row was rejected.
     */
    @IsTest
    static void recordsAWriteFailureWithoutThrowing() {
        Contact doomed = newBroker();
        Id doomedId = doomed.Id;
        delete doomed;
        Database.emptyRecycleBin(new List<Id>{ doomedId });

        Test.startTest();
        new BrokerCounterRecalcBatch().execute(null, new List<Contact>{ new Contact(Id = doomedId) });
        Test.stopTest();

        Assert.areEqual(1, BrokerCounterRecalcBatch.chunkChanged,
            'the shell has null counters against a computed 0, so it must be queued for update');
        Assert.areEqual(1, BrokerCounterRecalcBatch.chunkDmlStatements,
            'the update must be attempted');
        Assert.areEqual(0, BrokerCounterRecalcBatch.chunkUpdated,
            'nothing was actually written');
        Assert.areEqual(1, BrokerCounterRecalcBatch.chunkWriteFailures,
            'the refusal must be COUNTED — an uncounted SaveResult failure is how a broker keeps '
            + 'a stale number forever with nothing anywhere reporting it');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SELECTOR-LEVEL TESTS
    //
    // ⚠ THEY LIVE HERE RATHER THAN IN OpportunitySelectorTest / LeadSelectorTest /
    // ContactSelectorTest DELIBERATELY, AND TEMPORARILY. All three of those are hub test files
    // being edited by concurrent streams in this same programme, and a merge collision there
    // would be a worse failure than a slightly misplaced test. They are prefixed `selector_` so
    // they are findable, and relocating them once the wave lands is a safe follow-up.
    // ═══════════════════════════════════════════════════════════════════════════

    /** A null input must not query. Separate from the empty case per the one-behaviour rule. */
    @IsTest
    static void selector_aggregateDealCountsByBroker_nullInputReturnsEmpty() {
        Assert.areEqual(0, OpportunitySelector.aggregateDealCountsByBroker(null).size(),
            'a null Id set must return an empty list and issue no query');
    }

    /** An empty input must not query. */
    @IsTest
    static void selector_aggregateDealCountsByBroker_emptyInputReturnsEmpty() {
        Assert.areEqual(0, OpportunitySelector.aggregateDealCountsByBroker(new Set<Id>()).size(),
            'an empty Id set must return an empty list and issue no query');
    }

    /**
     * The aggregate returns ONE row per (broker, stage) pair with the alias names the batch reads.
     * An alias rename would compile fine and silently yield nulls, so the aliases are asserted by
     * being read.
     */
    @IsTest
    static void selector_aggregateDealCountsByBroker_groupsByBrokerAndStage() {
        Contact broker = newBroker();
        dealsFor(broker.Id, 'New', 2);
        dealsFor(broker.Id, 'Closed Won', 1);

        Test.startTest();
        List<AggregateResult> rows = OpportunitySelector.aggregateDealCountsByBroker(
            new Set<Id>{ broker.Id }
        );
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            'two distinct stages for one broker must produce two grouped rows');
        Map<String, Integer> byStage = new Map<String, Integer>();
        for (AggregateResult row : rows) {
            Assert.areEqual(broker.Id, (Id) row.get('brokerId'),
                'the brokerId alias must carry the Broker__c value');
            byStage.put((String) row.get('st'), Integer.valueOf(row.get('c')));
        }
        Assert.areEqual(2, byStage.get('New'), 'the New group must count 2');
        Assert.areEqual(1, byStage.get('Closed Won'), 'the Closed Won group must count 1');
    }

    /** A null input must not query. */
    @IsTest
    static void selector_aggregateFirstSeenByConvertedContact_nullInputReturnsEmpty() {
        Assert.areEqual(0, LeadSelector.aggregateFirstSeenByConvertedContact(null).size(),
            'a null Id set must return an empty list and issue no query');
    }

    /** An empty input must not query. */
    @IsTest
    static void selector_aggregateFirstSeenByConvertedContact_emptyInputReturnsEmpty() {
        Assert.areEqual(
            0, LeadSelector.aggregateFirstSeenByConvertedContact(new Set<Id>()).size(),
            'an empty Id set must return an empty list and issue no query'
        );
    }

    /**
     * A Lead with a NULL `First_Seen_Date__c` must be excluded at the query, not folded in as a
     * null minimum. Falsifies the version without the `!= NULL` predicate, under which the
     * unstamped Lead would drag `MIN` to null and blank a broker who does have a real date.
     */
    @IsTest
    static void selector_aggregateFirstSeenByConvertedContact_excludesUnstampedLeads() {
        Lead stamped = TestDataFactory.createLead(false);
        stamped.First_Seen_Date__c = Datetime.newInstanceGmt(2026, 2, 3, 4, 5, 6);
        insert stamped;
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(stamped.Id);
        lc.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult res = Database.convertLead(lc);
        Assert.isTrue(res.isSuccess(), 'the fixture Lead must convert');

        Lead unstamped = TestDataFactory.createLead(false);
        insert unstamped;
        Database.LeadConvert lc2 = new Database.LeadConvert();
        lc2.setLeadId(unstamped.Id);
        lc2.setConvertedStatus(convertedStatus());
        lc2.setAccountId(res.getAccountId());
        lc2.setContactId(res.getContactId());
        Assert.isTrue(Database.convertLead(lc2).isSuccess(),
            'the unstamped Lead must convert onto the same Contact');

        Test.startTest();
        List<AggregateResult> rows = LeadSelector.aggregateFirstSeenByConvertedContact(
            new Set<Id>{ res.getContactId() }
        );
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'one broker must produce one grouped row');
        Assert.areEqual(res.getContactId(), (Id) rows[0].get('contactId'),
            'the contactId alias must carry the ConvertedContactId value');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 2, 3, 4, 5, 6),
            (Datetime) rows[0].get('firstSeen'),
            'the unstamped Lead must be excluded at the query — if it were included, MIN would '
            + 'return null and blank a broker who has a perfectly good date');
    }

    /**
     * The locator returns broker Contacts and only broker Contacts, and it carries the four
     * counter fields the batch's no-op skip depends on. Dropping a field from the select list
     * would make every night write every broker.
     */
    @IsTest
    static void selector_queryBrokerCounterTargets_selectsBrokersWithTheirCounters() {
        Contact broker = newBroker();
        Contact outsider = TestDataFactory.createNonBrokerContact(null, true);
        stampCounters(broker.Id, 7, 3, 2, null);

        Test.startTest();
        Database.QueryLocatorIterator iterator =
            ContactSelector.queryBrokerCounterTargets().iterator();
        Test.stopTest();

        Set<Id> selected = new Set<Id>();
        Contact loaded = null;
        while (iterator.hasNext()) {
            Contact row = (Contact) iterator.next();
            selected.add(row.Id);
            if (row.Id == broker.Id) {
                loaded = row;
            }
        }
        Assert.isNotNull(loaded, 'the broker Contact must appear in the locator');

        Assert.isTrue(selected.contains(broker.Id),
            'the locator must select every broker Contact');
        Assert.isFalse(selected.contains(outsider.Id),
            'the locator must exclude non-broker Contacts');
        Assert.areEqual(7, loaded.Deals_Submitted__c.intValue(),
            'the locator must carry Deals_Submitted__c — the no-op skip compares against it');
        Assert.areEqual(3, loaded.Deals_Won__c.intValue(),
            'the locator must carry Deals_Won__c');
        Assert.areEqual(2, loaded.Deals_Lost__c.intValue(),
            'the locator must carry Deals_Lost__c');
    }
}
