/**
 * @description Tests `DispositionOfferBuyerStampService.stampBuyerName` and, through it, the
 * `before insert` / `before update` contexts of `DispositionOfferTrigger` —  the buyer activity
 * timeline's offer-side stamp (`agent-output/disposition-tranche-2-requirements.md` §3 D6.2, added
 * 2026-08-20). The twin of `NdaBuyerStampServiceTest`; read that suite's header too, most of it
 * applies verbatim.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ✅ THE EXISTING SUITE STAYS GREEN BY CONSTRUCTION, AND HERE IS EXACTLY WHY:
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 *   `TestDataFactory.createDispositionOffers` SETS THE DERIVED **TEXT**
 *   (`Buyer_Name__c = 'Test Buyer ' + i`) AND NEVER SETS THE **LOOKUP** (`Buyer__c` stays null).
 *
 * So on insert `null == null` reads as "unchanged", the change-keyed guard skips EVERY existing
 * offer fixture in the repo, and the new stamp costs ZERO QUERIES on all of them. **Do not change
 * `TestDataFactory.createDispositionOffers`**; a test that needs a buyer sets `Buyer__c` itself.
 *
 * ⚠ AND `Disposition_Offer__c.Buyer__c` IS UNFILTERED. A plain `TestDataFactory.createContact(s)`
 * Contact is accepted — `createBrokerContact` is NOT required, which is the opposite of
 * `BovSubmissionBrokerStampServiceTest`, whose lookup carries an active `Is_Broker__c` filter.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE LIVE VALIDATION RULE THIS SUITE HAS TO WORK AROUND, AND WHY THAT IS NOT A TEST SMELL
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `objects/Disposition_Offer__c/validationRules/Buyer_Required_On_Offer` is ACTIVE with the formula
 * `ISBLANK(Buyer_Name__c)` and NO ISNEW/ISCHANGED guard. Two consequences the tests below encode:
 *   1. `Buyer_Name__c` can never be blanked, so the "cleared lookup leaves the text alone" branch is
 *      not merely a preference — blanking would make "remove the buyer lookup" an UN-PERFORMABLE
 *      operation. `updateClearingBuyer_leavesBuyerNameUnchanged` is that falsifier.
 *   2. Every fixture must carry a non-blank `Buyer_Name__c` at save time. The factory already does.
 * ⚠ That rule's own XML comment instructs Workstream D to re-point it at `Buyer__c`. **This change
 * does not make that amendment** (validation rules are object metadata, out of scope for a code-only
 * deliverable) and it is reported as outstanding. If it ever lands, re-read this block AND
 * `DispositionOfferBuyerStampService`'s clear-branch section.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE 251-RECORD MANDATE APPLIES IN FULL — NO EXEMPTION. Trigger path, loops over a collection;
 * the per-transaction-singleton exemption does not reach it and no content object is involved.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ AND IT MANDATES ONE BULK TEST **PER TRIGGER CONTEXT**. The 251-row UPDATE was missing until
 * 2026-08-20 (code review W3). Insert and update reach this service down different branches — a null
 * `oldMap` with a null-prior shortcut versus a populated `oldMap` and a real value comparison — and
 * the comparison path is the one every other writer of this object takes. Both contexts are now
 * driven at 251 through the real trigger:
 * `bulkInsert251WithBuyers_allStampedThroughTheRealTrigger` and
 * `bulkUpdate251ChangingEveryBuyer_allRestampedThroughTheRealTrigger`.
 *
 * ── 🔴 WHY "EXACTLY 1 QUERY" IS MEASURED BY DIRECT INVOCATION ──
 * A real 251-row DML spans TWO trigger chunks (chunks are 200), so the service is legitimately
 * invoked twice and legitimately issues two queries. Asserting `1` around a real 251-row insert
 * would assert a falsehood; asserting `2` would pin the chunk size rather than the service. The
 * real-DML bulk test still proves the trigger — completing 251 rows AT ALL falsifies a per-record
 * query, which would need 251 SOQL and blow the 100-query limit.
 *
 * ⚠ THE REAL-DML BULK TEST MEASURES QUERIES ACROSS **TWO** WRITERS, NOT ONE. This trigger's before
 * contexts also run `DispositionOfferSelectionGuardService`, which itself issues at most one query
 * per chunk. That is why the bulk assertions below are about CORRECTNESS through the trigger and
 * about the SERVICE's own per-chunk constant measured directly — never about a raw query total
 * around the DML, which would silently pin an unrelated service's budget.
 *
 * ── EXPECTED-NAME ARITHMETIC (do not re-query Contact.Name — compose it locally) ──
 * `Name` is compound and is NOT reliably populated on an in-memory sObject after insert.
 * `FirstName` / `LastName` are the literal fields the fixture set.
 *
 * @see force-app/main/default/classes/DispositionOfferBuyerStampService.cls
 * @see force-app/main/default/classes/DispositionOfferTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/NdaBuyerStampServiceTest.cls (the twin suite)
 */
@isTest
private class DispositionOfferBuyerStampServiceTest {

    private static final Integer BULK_N = 251;

    /** Distinct from anything the factory writes, so an assertion can only pass if the stamp ran. */
    private static final String TYPED_NAME = 'TYPED BUYER - MUST BE OVERWRITTEN BY THE STAMP';

    private static Id dispositionId() {
        return TestDataFactory.defaultDisposition().Id;
    }

    /** `Contact.Name` composed from the literal fixture fields, never re-queried. */
    private static String nameOf(Contact buyer) {
        return buyer.FirstName + ' ' + buyer.LastName;
    }

    /** A factory offer whose buyer text is a literal no stamp could coincidentally produce. */
    private static Disposition_Offer__c typedOffer() {
        Disposition_Offer__c offer =
            TestDataFactory.createDispositionOffer(dispositionId(), false);
        offer.Buyer_Name__c = TYPED_NAME;
        return offer;
    }

    /** `count` such offers. */
    private static List<Disposition_Offer__c> typedOffers(Integer count) {
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(count, dispositionId(), false);
        for (Disposition_Offer__c offer : offers) {
            offer.Buyer_Name__c = TYPED_NAME;
        }
        return offers;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Guard
    // ─────────────────────────────────────────────────────────────────────────

    /** Null/empty-safe per the method's own ApexDoc. */
    @isTest
    static void stampBuyerName_nullOrEmptyList_returnsWithoutError() {
        Boolean completedWithoutThrowing = false;

        Test.startTest();
        DispositionOfferBuyerStampService.stampBuyerName(null, null);
        DispositionOfferBuyerStampService.stampBuyerName(
            new List<Disposition_Offer__c>(), null
        );
        completedWithoutThrowing = true;
        Test.stopTest();

        Assert.isTrue(completedWithoutThrowing,
            'Both calls must return without throwing — the guard is a no-op, not an error');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 1 — Buyer__c SET, Contact resolves
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The primary behaviour, ON INSERT, through the real trigger. `Buyer_Name__c` is copied STRAIGHT
     * ACROSS with NO composition and NO separator — the `Person - Firm` shape of
     * `DispositionBrokerStampService` must never appear on this object, which is design D6.2's
     * central warning and is falsified directly below.
     *
     * 🔴 IT ALSO PROVES THE `beforeInsert` WIRING SPECIFICALLY. Unlike `stampAcceptedStatus`, which
     * is deliberately NOT called on insert (it detects a TRANSITION), this stamp must run on insert
     * because an offer CREATED naming a buyer needs its text derived in that very first save.
     */
    @isTest
    static void insertWithBuyer_stampsBuyerNameFromTheContact() {
        // ⚠ A PLAIN Contact — Buyer__c is UNFILTERED, unlike every broker lookup in this repo.
        Contact buyer = TestDataFactory.createContact(null, true);
        String expectedName = nameOf(buyer);
        Disposition_Offer__c offer = typedOffer();
        offer.Buyer__c = buyer.Id;

        Test.startTest();
        insert offer;
        Test.stopTest();

        Disposition_Offer__c saved =
            [SELECT Buyer_Name__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.areEqual(expectedName, saved.Buyer_Name__c,
            'Buyer_Name__c must be the Contact Name copied straight across, on INSERT');
        Assert.isFalse(saved.Buyer_Name__c.contains(' - '),
            'NO composition and NO separator — the "Person - Firm" shape must never appear here');
    }

    /**
     * A BUYER CHANGE on an existing row restamps — the case a fill-if-blank guard would break.
     *
     * ⚠ THE UPDATE IS A FRESH, NARROW sObject, AND THAT STRENGTHENS THE FALSIFIER (fixed
     * 2026-08-21). This test used to reuse the `offer` variable, which — because Apex never
     * refreshes an sObject with values a before trigger assigned (measured; see
     * `updateClearingBuyer_leavesBuyerNameUnchanged`'s ApexDoc) — re-sent the stale `TYPED_NAME`
     * literal. It still passed, because the stamp fires on a buyer change and overwrites, but it
     * could not distinguish "restamped" from "never ran": under a stamp that skipped the update
     * path the row would have shown `TYPED_NAME`, and buyer[0]'s stamped name — the stale name
     * beside a new lookup this service exists to prevent — was never in the payload to survive.
     */
    @isTest
    static void updateChangingBuyer_restampsFromTheNewContact() {
        List<Contact> buyers = TestDataFactory.createContacts(2, null, true);
        Disposition_Offer__c offer = typedOffer();
        offer.Buyer__c = buyers[0].Id;
        insert offer;

        Test.startTest();
        update new Disposition_Offer__c(Id = offer.Id, Buyer__c = buyers[1].Id);
        Test.stopTest();

        Disposition_Offer__c saved =
            [SELECT Buyer_Name__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.areEqual(nameOf(buyers[1]), saved.Buyer_Name__c,
            'A buyer CHANGE must overwrite the previous name');
        Assert.areNotEqual(nameOf(buyers[0]), saved.Buyer_Name__c,
            'and the PREVIOUS buyer\'s stamped name must be gone — meaningful only because the '
            + 'payload above is narrow, so the DB really did hold buyer[0]\'s name going in');
    }

    /**
     * 🔴 NO TRUNCATION HERE, AND THE CEILING IS **NOT** SHARED WITH THE NDA TWIN. `Buyer_Name__c` is
     * Text(255) and `Contact.Name` maxes at 121, so the longest possible name is stored WHOLE. The
     * NDA twin's target is Text(120) and genuinely truncates — one shared constant between the two
     * services would be the bug, and this test is what pins the difference.
     */
    @isTest
    static void insertWithLongContactName_storesTheWholeNameUntruncated() {
        Contact buyer = new Contact(
            FirstName = 'F'.repeat(40),
            LastName = 'L'.repeat(80),
            Email = 'long.name.offer.buyer@example.invalid'
        );
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.insert(buyer, dml);

        String fullName = nameOf(buyer);
        Assert.areEqual(121, fullName.length(),
            'FIXTURE PRECONDITION: the composed Name is at its 121-character maximum');

        Disposition_Offer__c offer = typedOffer();
        offer.Buyer__c = buyer.Id;

        Test.startTest();
        insert offer;
        Test.stopTest();

        Disposition_Offer__c saved =
            [SELECT Buyer_Name__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.areEqual(fullName, saved.Buyer_Name__c,
            'Text(255) comfortably holds a 121-character Name — the value must be stored WHOLE. If '
            + 'this ever truncates, someone has shared the NDA twin\'s 120 ceiling with this service.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 2 — Buyer__c CLEARED (the deliberate divergence, with a live VR behind it)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 CLEARING THE LOOKUP LEAVES THE TEXT ALONE — AND HERE THE SAVE ITSELF IS PART OF THE
     * ASSERTION. If the stamp blanked `Buyer_Name__c`, the active `Buyer_Required_On_Offer`
     * validation rule would REFUSE this update outright, so this test would fail with a
     * `DmlException` rather than a wrong value. That is the concrete, measurable reason this service
     * diverges from `BovSubmissionBrokerStampService`'s null-on-clear branch.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE CLEARING SAVE IS A FRESH, NARROW sObject — **NOT** THE `offer` VARIABLE. FIXED 2026-08-21.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * This test used to read `offer.Buyer__c = null; update offer;` and it FAILED — and the service
     * was never the reason. **APEX DOES NOT REFRESH AN sObject WITH VALUES A BEFORE TRIGGER
     * ASSIGNED**, measured directly on `usman-dpeg` (2026-08-21) on the NDA twin: immediately after
     * the insert, the DATABASE held the stamped Contact name while the in-memory field STILL held
     * the typed literal. Reusing the variable therefore re-sent `TYPED_NAME` in the update payload,
     * the clear branch did exactly what it is documented to do (left the text alone), and the stale
     * literal the TEST ITSELF supplied is what committed.
     *
     * ⚠ IT WAS ALSO ASSERTING AGAINST A STATE A USER CANNOT PRODUCE. A real "clear the buyer" save
     * is made from a form loaded FROM THE DATABASE, and Lightning submits only the changed fields —
     * exactly `{Id, Buyer__c: null}`. `new Disposition_Offer__c(Id = ..., Buyer__c = null)` IS that
     * payload, which is why it is preferred over re-querying and updating the re-queried row, and it
     * cannot carry a stale value because it has no other field on it.
     *
     * ⚠ NEITHER HALF OF THE ASSERTION IS WEAKENED. `Trigger.new` in a before-update context carries
     * the record's FULL final field values, so a blanking stamp would still blank `Buyer_Name__c`
     * here — which still trips `Buyer_Required_On_Offer` and still makes the `update` line throw.
     * MUTATION-VERIFIED 2026-08-21; the NDA twin's ApexDoc records the shared evidence.
     */
    @isTest
    static void updateClearingBuyer_leavesBuyerNameUnchanged() {
        Contact buyer = TestDataFactory.createContact(null, true);
        String stampedName = nameOf(buyer);
        Disposition_Offer__c offer = typedOffer();
        offer.Buyer__c = buyer.Id;
        insert offer;
        Disposition_Offer__c afterInsert =
            [SELECT Buyer_Name__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.areEqual(stampedName, afterInsert.Buyer_Name__c,
            'FIXTURE PRECONDITION: the insert must have stamped the Contact name OVER the typed '
            + 'literal — asserted from a RE-QUERY, never from the in-memory row, so that a failure '
            + 'below is attributable to the clear branch and not to an insert stamp that never ran');

        Test.startTest();
        // The payload a real "clear the buyer" save sends. Completing this update IS half the
        // assertion — a blanking stamp trips Buyer_Required_On_Offer and this line throws.
        update new Disposition_Offer__c(Id = offer.Id, Buyer__c = null);
        Test.stopTest();

        Disposition_Offer__c saved =
            [SELECT Buyer__c, Buyer_Name__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.isNull(saved.Buyer__c, 'FIXTURE PRECONDITION: the lookup really was cleared');
        Assert.areEqual(stampedName, saved.Buyer_Name__c,
            'Clearing the lookup must NOT blank the text: Buyer_Required_On_Offer would refuse the '
            + 'save, making "remove the buyer" impossible to perform');
    }

    /**
     * The same clear, measured for COST: a chunk of pure clears must issue ZERO queries, because the
     * clear is filtered out in pass 1 before the Contact read.
     */
    @isTest
    static void clearingBuyer_costsZeroQueries() {
        Contact buyer = TestDataFactory.createContact(null, true);
        List<Disposition_Offer__c> offers = typedOffers(3);
        Map<Id, Disposition_Offer__c> oldMap = new Map<Id, Disposition_Offer__c>();
        for (Integer i = 0; i < offers.size(); i++) {
            Id fakeId = fakeOfferId(i + 1);
            offers[i].Id = fakeId;
            offers[i].Buyer__c = null;
            oldMap.put(fakeId, new Disposition_Offer__c(Id = fakeId, Buyer__c = buyer.Id));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionOfferBuyerStampService.stampBuyerName(offers, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A chunk of pure CLEARS must cost zero queries — there is no Contact to resolve');
        for (Disposition_Offer__c offer : offers) {
            Assert.areEqual(TYPED_NAME, offer.Buyer_Name__c, 'and the text must be untouched');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 3 — Buyer__c SET but no Contact resolves
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A buyer Id that resolves to NO readable Contact leaves the text UNCHANGED. Blanking would be
     * doubly wrong here: destructive AND refused by `Buyer_Required_On_Offer`.
     */
    @isTest
    static void buyerSetButContactUnresolvable_leavesTextUnchanged() {
        Disposition_Offer__c offer = typedOffer();
        offer.Buyer__c = fakeContactId();

        Test.startTest();
        DispositionOfferBuyerStampService.stampBuyerName(
            new List<Disposition_Offer__c>{ offer }, null
        );
        Test.stopTest();

        Assert.areEqual(TYPED_NAME, offer.Buyer_Name__c,
            'An unresolvable Contact must leave the text alone');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The change-keyed guard
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 A SAVE THAT DOES NOT TOUCH `Buyer__c` CHANGES NOTHING AND COSTS NO QUERY OF ITS OWN.
     *
     * ⚠ THE QUERY COUNT AROUND THIS REAL `update` IS NOT ASSERTED, DELIBERATELY. This trigger's
     * before contexts also run `DispositionOfferSelectionGuardService`, whose own budget is not this
     * service's to pin — a raw total here would go red the day THAT service changed, for reasons
     * having nothing to do with this one. The zero-query claim is asserted where it can be
     * attributed: by direct invocation, in `bulk251NoRecordChangesBuyer_costsNothing`.
     */
    @isTest
    static void updateNotTouchingBuyer_changesNothing() {
        Contact buyer = TestDataFactory.createContact(null, true);
        String stampedName = nameOf(buyer);
        Disposition_Offer__c offer = typedOffer();
        offer.Buyer__c = buyer.Id;
        insert offer;
        // Someone hand-types over the stamped value. The next save leaves Buyer__c alone, so the
        // change-keyed stamp must not fire and must not restore its own value.
        Disposition_Offer__c edit =
            new Disposition_Offer__c(Id = offer.Id, Buyer_Name__c = TYPED_NAME);

        Test.startTest();
        update edit;
        Test.stopTest();

        Disposition_Offer__c saved =
            [SELECT Buyer_Name__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.areEqual(TYPED_NAME, saved.Buyer_Name__c,
            'The hand-typed value must survive a save that does not change Buyer__c');
        Assert.areNotEqual(stampedName, saved.Buyer_Name__c,
            'and specifically must not have restored the Contact name');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BULK — .claude/rules/bulk-test-rule.md, 251 records, no exemption
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 251 offers inserted THROUGH THE REAL TRIGGER, each naming a different Contact, all correctly
     * stamped. Completing this DML at all falsifies a per-record query (251 SOQL would blow the
     * 100-query limit long before finishing).
     */
    @isTest
    static void bulkInsert251WithBuyers_allStampedThroughTheRealTrigger() {
        List<Contact> buyers = TestDataFactory.createContacts(BULK_N, null, true);
        List<Disposition_Offer__c> offers = typedOffers(BULK_N);
        Map<Id, String> expectedByBuyer = new Map<Id, String>();
        for (Integer i = 0; i < BULK_N; i++) {
            offers[i].Buyer__c = buyers[i].Id;
            expectedByBuyer.put(buyers[i].Id, nameOf(buyers[i]));
        }

        Test.startTest();
        insert offers;
        Test.stopTest();

        List<Disposition_Offer__c> saved = [
            SELECT Id, Buyer__c, Buyer_Name__c FROM Disposition_Offer__c WHERE Id IN :offers
        ];
        Assert.areEqual(BULK_N, saved.size(), 'All 251 offers must have saved');
        for (Disposition_Offer__c offer : saved) {
            Assert.areEqual(expectedByBuyer.get(offer.Buyer__c), offer.Buyer_Name__c,
                'Every one of the 251 rows must carry ITS OWN buyer\'s name');
        }
    }

    /**
     * 🔴 251 OFFERS **UPDATED** THROUGH THE REAL TRIGGER, EVERY ONE FLIPPING ITS BUYER, ALL 251
     * RESTAMPED. Added 2026-08-20 (code review W3); the twin of
     * `NdaBuyerStampServiceTest.bulkUpdate251ChangingEveryBuyer_allRestampedThroughTheRealTrigger`,
     * whose header carries the full argument.
     *
     * ⚠ NOT REDUNDANT WITH THE 251-ROW INSERT ABOVE. `.claude/rules/bulk-test-rule.md` mandates a
     * bulk test per trigger CONTEXT, and insert and update reach this service down different
     * branches: a NULL `oldMap` and a null-prior shortcut on insert, a populated `oldMap` and a real
     * value comparison on update. The `oldMap.get(...)` path is the one EVERY OTHER WRITER of this
     * object takes (the approval field update, the exclusivity sweep, the counter-price actions), so
     * a bulkification defect confined to it would have shown nowhere in this suite.
     *
     * ── THE BUYERS ARE ROTATED, NOT DRAWN FROM A SECOND FIXTURE SET ────────────────────────────
     * Row i moves from `buyers[i]` to `buyers[i + 1]` (wrapping). 🔴 A second
     * `TestDataFactory.createContacts(251, ...)` call would have made this pass VACUOUSLY — that
     * factory builds `LastName = 'Contact ' + i` from the LOOP INDEX, which resets to 0 on every
     * call, so the second batch would carry identical names and "restamped" would be
     * indistinguishable from "never ran".
     *
     * ⚠ NO QUERY COUNT IS ASSERTED AROUND THIS `update`, FOR THE REASON THE CLASS HEADER ALREADY
     * GIVES: this trigger's before contexts also run `DispositionOfferSelectionGuardService`, whose
     * budget is not this service's to pin — a total here would go red the day THAT service changed.
     * Completing a 251-row update AT ALL is still the falsifier a per-record query would fail (251
     * SOQL blows the 100-query limit long before finishing), and the attributable per-chunk constant
     * is measured directly in `bulk251BuyerChanges_costsExactlyOneQueryForTheWholeChunk`.
     */
    @isTest
    static void bulkUpdate251ChangingEveryBuyer_allRestampedThroughTheRealTrigger() {
        List<Contact> buyers = TestDataFactory.createContacts(BULK_N, null, true);
        List<Disposition_Offer__c> offers = typedOffers(BULK_N);
        for (Integer i = 0; i < BULK_N; i++) {
            offers[i].Buyer__c = buyers[i].Id;
        }
        insert offers;

        // Rotate. Keyed by offer Id — the verification query returns rows in no guaranteed order.
        //
        // 🔴 SENT AS 251 FRESH, NARROW sObjects RATHER THAN BY MUTATING `offers` (fixed 2026-08-21).
        // Every row in `offers` still carries the `TYPED_NAME` literal `typedOffers()` wrote,
        // because Apex never refreshes an sObject with values a before trigger assigned — so
        // `update offers` re-sent 251 stale literals and the `areNotEqual(priorByOffer...)`
        // assertion below was VACUOUS: the prior stamped name was never in the payload, so no
        // implementation of this service could have left it behind and that assertion could not
        // fail. With narrow payloads the DB genuinely holds buyer[i]'s stamped name going into this
        // save, and a stamp that skipped the update path leaves it there — which is what the
        // assertion claims to catch.
        List<Disposition_Offer__c> rotations = new List<Disposition_Offer__c>();
        Map<Id, String> expectedByOffer = new Map<Id, String>();
        Map<Id, String> priorByOffer = new Map<Id, String>();
        for (Integer i = 0; i < BULK_N; i++) {
            Contact nextBuyer = buyers[Math.mod(i + 1, BULK_N)];
            priorByOffer.put(offers[i].Id, nameOf(buyers[i]));
            expectedByOffer.put(offers[i].Id, nameOf(nextBuyer));
            rotations.add(new Disposition_Offer__c(Id = offers[i].Id, Buyer__c = nextBuyer.Id));
        }

        Test.startTest();
        update rotations;
        Test.stopTest();

        List<Disposition_Offer__c> saved = [
            SELECT Id, Buyer__c, Buyer_Name__c FROM Disposition_Offer__c WHERE Id IN :offers
        ];
        Assert.areEqual(BULK_N, saved.size(),
            'All 251 offers must still be there after the update');
        for (Disposition_Offer__c offer : saved) {
            Assert.areEqual(expectedByOffer.get(offer.Id), offer.Buyer_Name__c,
                'Every one of the 251 rows must have been RESTAMPED from its NEW buyer');
            Assert.areNotEqual(priorByOffer.get(offer.Id), offer.Buyer_Name__c,
                'and specifically must NOT still hold the name it carried before this update');
        }
    }

    /**
     * 🔴 THE CONSTANT-BUDGET FALSIFIER: 251 records, ALL changing their buyer, EXACTLY ONE query.
     * Measured by direct invocation for the reason in the class header.
     */
    @isTest
    static void bulk251BuyerChanges_costsExactlyOneQueryForTheWholeChunk() {
        List<Contact> buyers = TestDataFactory.createContacts(BULK_N, null, true);
        List<Disposition_Offer__c> offers = typedOffers(BULK_N);
        for (Integer i = 0; i < BULK_N; i++) {
            offers[i].Buyer__c = buyers[i].Id;
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionOfferBuyerStampService.stampBuyerName(offers, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 changed records — that CONSTANCY is the property the bulk '
            + 'rule exists to protect, not merely that 251 rows produced 251 stamps');
        for (Integer i = 0; i < BULK_N; i++) {
            Assert.areEqual(nameOf(buyers[i]), offers[i].Buyer_Name__c,
                'and every row is stamped from its own Contact');
        }
    }

    /**
     * 🔴 THE ZERO-BUDGET FALSIFIER: 251 records NONE of which changed `Buyer__c` cost ZERO queries.
     * This is the shape of every existing offer fixture in the repo and of every other writer of
     * this object — the approval field update, the exclusivity sweep, the counter-price actions.
     */
    @isTest
    static void bulk251NoRecordChangesBuyer_costsNothing() {
        Contact buyer = TestDataFactory.createContact(null, true);
        List<Disposition_Offer__c> offers = typedOffers(BULK_N);
        Map<Id, Disposition_Offer__c> oldMap = new Map<Id, Disposition_Offer__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            Id fakeId = fakeOfferId(i + 1);
            offers[i].Id = fakeId;
            offers[i].Buyer__c = buyer.Id;
            oldMap.put(fakeId, new Disposition_Offer__c(Id = fakeId, Buyer__c = buyer.Id));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionOfferBuyerStampService.stampBuyerName(offers, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'ZERO queries when no record changed its buyer — this is what keeps the expanded '
            + 'before contexts free for every other writer of Disposition_Offer__c');
        for (Disposition_Offer__c offer : offers) {
            Assert.areEqual(TYPED_NAME, offer.Buyer_Name__c, 'and nothing was written');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fabricated Ids for direct-invocation tests (nothing is saved, so no FK is validated)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A syntactically valid `Disposition_Offer__c` Id that exists in no org.
     *
     * @param seed A per-row discriminator so the Ids in one chunk are distinct.
     * @return The fabricated Id.
     */
    private static Id fakeOfferId(Integer seed) {
        String suffix = String.valueOf(seed);
        return Id.valueOf(
            Disposition_Offer__c.SObjectType.getDescribe().getKeyPrefix()
                + '0'.repeat(12 - suffix.length())
                + suffix
        );
    }

    /** Ditto, for Contact — the "this buyer resolves to nothing" case. */
    private static Id fakeContactId() {
        return Id.valueOf(Contact.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
    }
}
