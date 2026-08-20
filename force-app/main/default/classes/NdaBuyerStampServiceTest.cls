/**
 * @description Tests `NdaBuyerStampService.stampBuyerName` and, through it, `NdaTrigger` /
 * `NdaTriggerHandler` — the buyer activity timeline's NDA-side stamp
 * (`agent-output/disposition-tranche-2-requirements.md` §3 D6.2, added 2026-08-20).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ✅ THE MOST REASSURING MEASURED FACT ABOUT THIS CHANGE, RECORDED HERE SO NOBODY HAS TO
 *    REDISCOVER IT: **THE EXISTING SUITE STAYS GREEN BY CONSTRUCTION.**
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `NdaTrigger` is the FIRST trigger `NDA__c` has ever had and it fires on EVERY insert and update
 * in the org — acquisition NDAs included. Nothing in the existing suite breaks, and the reason is
 * structural rather than lucky:
 *
 *   `TestDataFactory.createNdas` SETS THE DERIVED **TEXT** (`Counterparty_Name__c = 'Test
 *   Counterparty ' + i`) AND NEVER SETS THE **LOOKUP** (`Buyer__c` stays null).
 *
 * So on insert `null == null` reads as "unchanged", the change-keyed guard skips EVERY existing
 * fixture, the stamp never overwrites one, and the whole trigger costs ZERO QUERIES on every
 * pre-existing NDA test in the repo. The same holds for every non-test writer — the writer-by-writer
 * table is in `NdaBuyerStampService`'s class header. **Do not change
 * `TestDataFactory.createNdas`**; a test that needs a buyer sets `Buyer__c` itself.
 *
 * ⚠ AND `Buyer__c` IS UNFILTERED, UNLIKE EVERY BROKER LOOKUP IN THIS REPO. A plain
 * `TestDataFactory.createContact(s)` Contact is accepted; `createBrokerContact` is NOT required.
 * That is the single easiest thing to get wrong by copying `BovSubmissionBrokerStampServiceTest`,
 * whose fixtures MUST use broker Contacts because `BOV_Submission__c.Broker__c` carries an active,
 * non-optional `Is_Broker__c` filter.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE 251-RECORD MANDATE APPLIES IN FULL — NO EXEMPTION TO CLAIM.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * This is a trigger path that loops over a collection, so `.claude/rules/bulk-test-rule.md` applies
 * unamended: the per-transaction-singleton exemption does not reach it (nothing here is invoked once
 * per async job), and the `.claude/rules/content-publication-rule.md` carve-out does not either (no
 * `ContentVersion` / `ContentNote` / `ContentDocument` is involved). See
 * `bulkInsert251WithBuyers_allStampedThroughTheRealTrigger`,
 * `bulkUpdate251ChangingEveryBuyer_allRestampedThroughTheRealTrigger`,
 * `bulk251BuyerChanges_costsExactlyOneQueryForTheWholeChunk` and
 * `bulk251NoRecordChangesBuyer_costsNothing`.
 *
 * ⚠ THE RULE MANDATES ONE BULK TEST **PER TRIGGER CONTEXT**, AND THE UPDATE ONE WAS MISSING UNTIL
 * 2026-08-20 (code review W3). `NdaTrigger` handles `before insert` AND `before update`, and the two
 * reach this service down different branches — a null `oldMap` with a null-prior shortcut on insert,
 * a populated `oldMap` and a real value comparison on update. A 251-row insert exercises none of the
 * comparison path at volume. Both contexts are now driven at 251 through the REAL trigger.
 *
 * ── 🔴 WHY THE "EXACTLY 1 QUERY" CLAIM IS MEASURED BY DIRECT INVOCATION, NOT THROUGH THE TRIGGER ──
 * The budget claim is "AT MOST 1 SOQL **PER CHUNK**". A real 251-row DML spans TWO trigger chunks
 * (chunks are 200), so the service is legitimately invoked TWICE and legitimately issues TWO
 * queries — asserting `1` around a real 251-row `insert` would be asserting a falsehood, and
 * asserting `2` would be pinning the chunk size rather than the service. The per-chunk constant is
 * therefore measured by invoking the service ONCE with 251 records in hand.
 *
 * That does not leave the real trigger unproven. `bulkInsert251WithBuyers_allStampedThroughTheRealTrigger`
 * runs the genuine DML, and COMPLETING IT AT ALL is part of the falsifier: a per-record query would
 * need 251 SOQL and would blow the 100-query limit long before finishing. Same split, same reason,
 * as `BovSubmissionBrokerStampServiceTest` and `DispositionBrokerStampServiceTest`.
 *
 * ── ⚠ THE BULK FIXTURES DELIBERATELY LEAVE `Disposition__c` NULL, AND THAT IS NOT LAZINESS ──
 * `flows/NDA_Signed_Rollup` is an ACTIVE after-save flow on `NDA__c` whose entry condition is
 * `Disposition__c IS NOT NULL`, and its own description records an untested shape verbatim: *"The
 * many-NDAs-under-ONE-disposition consolidation — the classic duplicate id in list — is untested
 * either way."* Hanging 251 NDAs off ONE disposition would drive exactly that path, and any failure
 * would be attributed to this stamp rather than to the flow. A null `Disposition__c` makes the
 * flow's entry condition false, so these tests measure THIS service and nothing else.
 * ⚠ The before-save flow `NDA_Signed_Status_Sync` still runs on every row below — it is unavoidable
 * and harmless (before-save, zero DML, and it touches `NDA_Signed__c` / `Date_Signed__c`, never
 * `Buyer__c`, so it re-enters the stamp and is skipped).
 *
 * ── EXPECTED-NAME ARITHMETIC (do not re-query Contact.Name — compose it locally) ──
 * `Name` is a compound field and is NOT reliably populated on an in-memory sObject immediately after
 * insert. `FirstName` / `LastName` are the literal fields the fixture set, and English-locale `Name`
 * is exactly `FirstName + ' ' + LastName` — the same assumption the service's own 121-character
 * `Name` ceiling rests on.
 *
 * ── ⚠ FIXTURE COLLISION HAZARD, STATED SO IT IS NOT REINTRODUCED ──
 * `TestDataFactory.createNdas` writes `Counterparty_Name__c = 'Test Counterparty ' + i` and
 * `createContacts` writes `LastName = 'Contact ' + i`. The two strings are different, so no
 * accidental pass is possible from the factory alone — but every stamping test below STILL
 * over-writes the NDA's text with a distinct `TYPED ...` literal first, so an assertion can only
 * pass if the stamp actually ran and not because the fixture happened to agree.
 *
 * @see force-app/main/default/classes/NdaBuyerStampService.cls
 * @see force-app/main/default/triggers/NdaTrigger.trigger
 * @see force-app/main/default/classes/DispositionOfferBuyerStampServiceTest.cls (the twin suite)
 */
@isTest
private class NdaBuyerStampServiceTest {

    private static final Integer BULK_N = 251;

    /** Distinct from anything the factory writes — see the FIXTURE COLLISION HAZARD note. */
    private static final String TYPED_NAME = 'TYPED NAME - MUST BE OVERWRITTEN BY THE STAMP';

    /** `Counterparty_Name__c` is Text(120). The stamp must cut to exactly this. */
    private static final Integer NAME_CEILING = 120;

    /** `Contact.Name` composed from the literal fixture fields, never re-queried. */
    private static String nameOf(Contact buyer) {
        return buyer.FirstName + ' ' + buyer.LastName;
    }

    /**
     * A disposition-shaped NDA with its derived text set to a literal no stamp could coincidentally
     * produce, and NO parent disposition (see the class header's flow-isolation note).
     */
    private static NDA__c typedNda() {
        NDA__c nda = TestDataFactory.createNdas(
            1, null, TestDataFactory.NDA_RT_DISPOSITION, false
        )[0];
        nda.Counterparty_Name__c = TYPED_NAME;
        return nda;
    }

    /** `count` such NDAs. */
    private static List<NDA__c> typedNdas(Integer count) {
        List<NDA__c> ndas = TestDataFactory.createNdas(
            count, null, TestDataFactory.NDA_RT_DISPOSITION, false
        );
        for (NDA__c nda : ndas) {
            nda.Counterparty_Name__c = TYPED_NAME;
        }
        return ndas;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Guard
    // ─────────────────────────────────────────────────────────────────────────

    /** Null/empty-safe per the method's own ApexDoc. */
    @isTest
    static void stampBuyerName_nullOrEmptyList_returnsWithoutError() {
        Boolean completedWithoutThrowing = false;

        Test.startTest();
        NdaBuyerStampService.stampBuyerName(null, null);
        NdaBuyerStampService.stampBuyerName(new List<NDA__c>(), null);
        completedWithoutThrowing = true; // reached only if neither call above threw
        Test.stopTest();

        Assert.isTrue(completedWithoutThrowing,
            'Both calls must return without throwing — the guard is a no-op, not an error');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 1 — Buyer__c SET, Contact resolves
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The primary behaviour: `Counterparty_Name__c` is copied STRAIGHT ACROSS from the chosen
     * Contact, with NO composition and NO separator. The sibling service's `Person - Firm` shape
     * must never appear here — that is design D6.2's central warning, and the assertion below
     * falsifies it directly.
     *
     * The `TYPED_NAME` literal also pins the "where they would collide, the stamp wins" clause of
     * the service header: this save both sets `Buyer__c` and hand-types the text, and the stamp
     * overwrites, because a before trigger sees the final field values.
     */
    @isTest
    static void insertWithBuyer_stampsCounterpartyNameFromTheContact() {
        // ⚠ A PLAIN Contact, not a broker Contact — Buyer__c is UNFILTERED.
        Contact buyer = TestDataFactory.createContact(null, true);
        String expectedName = nameOf(buyer);
        NDA__c nda = typedNda();
        nda.Buyer__c = buyer.Id;

        Test.startTest();
        insert nda;
        Test.stopTest();

        NDA__c saved = [SELECT Counterparty_Name__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual(expectedName, saved.Counterparty_Name__c,
            'Counterparty_Name__c must be the Contact Name copied straight across');
        Assert.isFalse(saved.Counterparty_Name__c.contains(' - '),
            'NO composition and NO separator — the DispositionBrokerStampService "Person - Firm" '
            + 'shape must never appear on this object');
    }

    /**
     * A BUYER CHANGE on an existing row restamps. This is the case a fill-if-blank guard would
     * silently break, which is why this stamp is deliberately NOT fill-if-blank.
     *
     * ⚠ THE UPDATE IS A FRESH, NARROW sObject, AND THAT STRENGTHENS THE FALSIFIER (fixed
     * 2026-08-21). This test used to reuse the `nda` variable, which — because Apex never refreshes
     * an sObject with values a before trigger assigned (see
     * `updateClearingBuyer_leavesCounterpartyNameUnchanged`'s ApexDoc for the measurement) — re-sent
     * the stale `TYPED_NAME` literal in the payload. It still PASSED, because the stamp fires on a
     * buyer change and overwrites, but it could not tell the two failure modes apart: under a stamp
     * that stopped firing on update, the row would have shown `TYPED_NAME` rather than buyer[0]'s
     * name, and the "stale name beside a new lookup" this test exists to prevent would never have
     * been observable at all. With a narrow payload the DB keeps buyer[0]'s STAMPED name until this
     * service overwrites it, so the `areNotEqual` below is now a real assertion rather than a
     * tautology about a literal the test itself supplied.
     */
    @isTest
    static void updateChangingBuyer_restampsFromTheNewContact() {
        List<Contact> buyers = TestDataFactory.createContacts(2, null, true);
        NDA__c nda = typedNda();
        nda.Buyer__c = buyers[0].Id;
        insert nda;

        Test.startTest();
        update new NDA__c(Id = nda.Id, Buyer__c = buyers[1].Id);
        Test.stopTest();

        NDA__c saved = [SELECT Counterparty_Name__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual(nameOf(buyers[1]), saved.Counterparty_Name__c,
            'A buyer CHANGE must overwrite the previous name — a stale name beside a new lookup is '
            + 'the exact disagreement this stamp exists to prevent');
        Assert.areNotEqual(nameOf(buyers[0]), saved.Counterparty_Name__c,
            'and specifically the PREVIOUS buyer\'s stamped name must be gone. This assertion is '
            + 'only meaningful because the payload above is narrow: the DB genuinely held buyer[0]\'s '
            + 'name going into this save, so a stamp that failed to fire would leave it there');
    }

    /**
     * 🔴 TRUNCATION AT **120**, NOT 244 OR 255 — AND THE FALSIFIER IS THAT THE SAVE COMPLETES AT ALL.
     *
     * `Counterparty_Name__c` is Text(120) and `Contact.Name` can reach 121 (FirstName 40 + space +
     * LastName 80). Without the truncation this insert would fail outright with `STRING_TOO_LONG` —
     * a HARD FAILURE OF THE USER'S OWN NDA SAVE, not a cosmetic defect. So this test proves two
     * things at once: the save succeeds, and the stored value is exactly the first 120 characters.
     *
     * ⚠ The Contact is built by hand rather than by the factory because the factory's names are
     * short by construction, and `Database.DMLOptions.DuplicateRuleHeader.AllowSave` is set for the
     * same reason `TestDataFactory.insertAllowingDuplicates` sets it — the org's active
     * `Standard_Contact_Duplicate_Rule` is Alert/Allow, which Apex DML degrades into a hard
     * `DUPLICATES_DETECTED`.
     */
    @isTest
    static void insertWithLongContactName_truncatesToOneHundredAndTwenty() {
        Contact buyer = new Contact(
            FirstName = 'F'.repeat(40),
            LastName = 'L'.repeat(80),
            Email = 'long.name.buyer@example.invalid'
        );
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.insert(buyer, dml);

        String fullName = nameOf(buyer);
        Assert.areEqual(121, fullName.length(),
            'FIXTURE PRECONDITION: the composed Name must exceed the 120-character ceiling, '
            + 'otherwise this test passes without exercising the truncation at all');

        NDA__c nda = typedNda();
        nda.Buyer__c = buyer.Id;

        Test.startTest();
        // Completing this insert IS half the assertion — an untruncated copy throws STRING_TOO_LONG.
        insert nda;
        Test.stopTest();

        NDA__c saved = [SELECT Counterparty_Name__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual(NAME_CEILING, saved.Counterparty_Name__c.length(),
            'The stamp must cut to exactly 120 characters');
        Assert.areEqual(fullName.substring(0, NAME_CEILING), saved.Counterparty_Name__c,
            'Truncation must keep the FIRST 120 characters and must not append an ellipsis — the '
            + 'field is a name a human reads and a report groups by');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 2 — Buyer__c CLEARED (the deliberate divergence from the BOV skeleton)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 CLEARING THE LOOKUP LEAVES THE TEXT ALONE. This is the ONE place this service deliberately
     * diverges from `BovSubmissionBrokerStampService`, whose equivalent branch nulls both of its
     * Text fields. The three reasons are in the service's class header; this test is what stops a
     * future "harmonisation" with the BOV twin from landing silently.
     *
     * ⚠ THE ACCEPTED CONSEQUENCE IS ASSERTED, NOT HIDDEN: the row keeps displaying the last stamped
     * name, which is indistinguishable from a legacy row — a state this feature already renders
     * correctly and deliberately.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE CLEARING SAVE IS A FRESH, NARROW sObject — **NOT** THE `nda` VARIABLE. FIXED 2026-08-21.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * This test used to read `nda.Buyer__c = null; update nda;` and it FAILED — and the service was
     * never the reason. **APEX DOES NOT REFRESH AN sObject WITH VALUES A BEFORE TRIGGER ASSIGNED**,
     * measured directly on `usman-dpeg` (2026-08-21): immediately after `insert nda`, the DATABASE
     * held the stamped Contact name while the in-memory `nda.Counterparty_Name__c` STILL held
     * `TYPED_NAME`. Reusing that variable therefore put `TYPED_NAME` back into the update payload,
     * the clear branch did exactly what it is documented to do (left the text alone), and the stale
     * literal the TEST ITSELF re-sent is what committed.
     *
     * ⚠ IT WAS ALSO ASSERTING AGAINST A STATE A USER CANNOT PRODUCE. A real "clear the buyer" save
     * is made from a form loaded FROM THE DATABASE, and Lightning submits only the fields the user
     * actually changed — i.e. exactly `{Id, Buyer__c: null}`. `new NDA__c(Id = ..., Buyer__c = null)`
     * IS that payload, which is why it is preferred here over re-querying `nda` and updating the
     * re-queried row: the re-query models an all-fields API save, the narrow sObject models the save
     * this feature's UI actually issues, AND it is immune to the stale-value trap by construction —
     * there is no stale field on it to resend.
     *
     * ⚠ THE FALSIFIER IS UNWEAKENED BY THE NARROW PAYLOAD, WHICH IS THE WHOLE POINT. `Trigger.new`
     * in a before-update context carries the record's FULL final field values, not merely the
     * submitted ones, so a service that blanked `Counterparty_Name__c` on clear would blank it here
     * too and this test would go red. MUTATION-VERIFIED 2026-08-21: removing the clear branch's
     * `continue` from `NdaBuyerStampService` turns this test red, and restoring it turns it green.
     */
    @isTest
    static void updateClearingBuyer_leavesCounterpartyNameUnchanged() {
        Contact buyer = TestDataFactory.createContact(null, true);
        String stampedName = nameOf(buyer);
        NDA__c nda = typedNda();
        nda.Buyer__c = buyer.Id;
        insert nda;
        NDA__c afterInsert = [SELECT Counterparty_Name__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual(stampedName, afterInsert.Counterparty_Name__c,
            'FIXTURE PRECONDITION: the insert must have stamped the Contact name OVER the typed '
            + 'literal. Asserted from a RE-QUERY, never from the in-memory row — and asserted at '
            + 'all so that a failure below is attributable to the clear branch rather than to an '
            + 'insert stamp that silently never ran');

        Test.startTest();
        // The payload a real "clear the buyer" save sends: the Id and the one field the user
        // changed. See this method's ApexDoc for why reusing `nda` here is the bug, not the fix.
        update new NDA__c(Id = nda.Id, Buyer__c = null);
        Test.stopTest();

        NDA__c saved = [SELECT Buyer__c, Counterparty_Name__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.isNull(saved.Buyer__c, 'FIXTURE PRECONDITION: the lookup really was cleared');
        Assert.areEqual(stampedName, saved.Counterparty_Name__c,
            'Clearing the lookup must NOT blank the text: blanking would destroy a name a human '
            + 'may have typed, and would discard a replacement typed in the same save');
    }

    /**
     * The same clear, measured for COST rather than for value: a chunk in which every changed record
     * merely CLEARED its buyer must still issue ZERO queries. The clear is filtered out in pass 1,
     * before the Contact read, precisely so this holds.
     */
    @isTest
    static void clearingBuyer_costsZeroQueries() {
        Contact buyer = TestDataFactory.createContact(null, true);
        List<NDA__c> ndas = typedNdas(3);
        Map<Id, NDA__c> oldMap = new Map<Id, NDA__c>();
        for (Integer i = 0; i < ndas.size(); i++) {
            // Fabricated Ids: this is a DIRECT invocation, so nothing is saved and no FK is checked.
            Id fakeId = fakeNdaId(i + 1);
            ndas[i].Id = fakeId;
            ndas[i].Buyer__c = null;
            oldMap.put(fakeId, new NDA__c(Id = fakeId, Buyer__c = buyer.Id));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        NdaBuyerStampService.stampBuyerName(ndas, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A chunk of pure CLEARS must cost zero queries — there is no Contact to resolve');
        for (NDA__c nda : ndas) {
            Assert.areEqual(TYPED_NAME, nda.Counterparty_Name__c,
                'and the text must be untouched');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 3 — Buyer__c SET but no Contact resolves
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A buyer Id that resolves to NO readable Contact (deleted, or invisible under sharing) leaves
     * the text UNCHANGED rather than blanking it. Driven by direct invocation with a syntactically
     * valid but non-existent Contact Id — no DML, so no foreign key is validated.
     */
    @isTest
    static void buyerSetButContactUnresolvable_leavesTextUnchanged() {
        NDA__c nda = typedNda();
        nda.Buyer__c = fakeContactId();

        Test.startTest();
        NdaBuyerStampService.stampBuyerName(new List<NDA__c>{ nda }, null);
        Test.stopTest();

        Assert.areEqual(TYPED_NAME, nda.Counterparty_Name__c,
            'An unresolvable Contact must leave the text alone — blanking is the more destructive '
            + 'direction, and a stale value is visible and self-healing');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The change-keyed guard — the branch that protects every other writer
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 A SAVE THAT DOES NOT TOUCH `Buyer__c` COSTS **ZERO QUERIES** AND CHANGES NOTHING. This is
     * the single most important guarantee in this class: it is what makes a brand-new trigger on a
     * DUAL-MODULE object safe, and what makes every existing fixture in the repo stay green.
     */
    @isTest
    static void updateNotTouchingBuyer_changesNothingAndCostsZeroQueries() {
        Contact buyer = TestDataFactory.createContact(null, true);
        String stampedName = nameOf(buyer);
        NDA__c nda = typedNda();
        nda.Buyer__c = buyer.Id;
        insert nda;
        // Someone hand-types over the stamped value. Because the next save does NOT change
        // Buyer__c, the stamp must not fire and must not restore its own value.
        NDA__c edit = new NDA__c(Id = nda.Id, Counterparty_Name__c = TYPED_NAME);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        update edit;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        NDA__c saved = [SELECT Counterparty_Name__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual(TYPED_NAME, saved.Counterparty_Name__c,
            'The hand-typed value must survive: the stamp is CHANGE-KEYED, so a save that leaves '
            + 'Buyer__c alone must not re-assert the stamped name');
        Assert.areNotEqual(stampedName, saved.Counterparty_Name__c,
            'and specifically must not have restored the Contact name');
        Assert.areEqual(0, queriesUsed,
            'ZERO queries. A save that does not change Buyer__c must never reach the Contact read.');
    }

    /**
     * ✅ THE ACQUISITION HALF OF THE DUAL-MODULE OBJECT IS UNAFFECTED. An acquisition NDA created the
     * ordinary way keeps the factory's typed counterparty name and costs no queries — `Buyer__c` is
     * granted on NEITHER acquisition permission set, so no acquisition surface can set it, and the
     * change-key makes the trigger free on that path.
     */
    @isTest
    static void acquisitionNdaInsert_isUntouchedAndCostsZeroQueries() {
        NDA__c nda = TestDataFactory.createNdas(
            1, null, TestDataFactory.NDA_RT_ACQUISITION, false
        )[0];
        String factoryName = nda.Counterparty_Name__c;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        insert nda;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        NDA__c saved = [SELECT Buyer__c, Counterparty_Name__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.isNull(saved.Buyer__c, 'An acquisition NDA names no buyer');
        Assert.areEqual(factoryName, saved.Counterparty_Name__c,
            'and its counterparty name must be exactly what the factory wrote');
        Assert.areEqual(0, queriesUsed,
            'ACQUISITION BEHAVIOUR IS UNCHANGED: the new trigger fires and returns after one '
            + 'in-memory pass with zero queries');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BULK — .claude/rules/bulk-test-rule.md, 251 records, no exemption
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 251 NDAs inserted THROUGH THE REAL TRIGGER, each naming a different Contact, all correctly
     * stamped. Completing this DML at all is half the falsifier: a per-record Contact query would
     * need 251 SOQL and would blow the 100-query limit long before finishing.
     */
    @isTest
    static void bulkInsert251WithBuyers_allStampedThroughTheRealTrigger() {
        List<Contact> buyers = TestDataFactory.createContacts(BULK_N, null, true);
        List<NDA__c> ndas = typedNdas(BULK_N);
        // ⚠ KEYED BY CONTACT ID, AND THE NAME NOW SAYS SO (code review S2, 2026-08-20). It was
        // `expectedByEmail`, which described a key this map has never held — a reader checking the
        // cross-wiring assertion below had to disprove the variable name before trusting the test.
        Map<Id, String> expectedByBuyer = new Map<Id, String>();
        for (Integer i = 0; i < BULK_N; i++) {
            ndas[i].Buyer__c = buyers[i].Id;
            expectedByBuyer.put(buyers[i].Id, nameOf(buyers[i]));
        }

        Test.startTest();
        insert ndas;
        Test.stopTest();

        List<NDA__c> saved = [
            SELECT Id, Buyer__c, Counterparty_Name__c FROM NDA__c WHERE Id IN :ndas
        ];
        Assert.areEqual(BULK_N, saved.size(), 'All 251 NDAs must have saved');
        for (NDA__c nda : saved) {
            Assert.areEqual(expectedByBuyer.get(nda.Buyer__c), nda.Counterparty_Name__c,
                'Every one of the 251 rows must carry ITS OWN buyer\'s name — a cross-wired map '
                + 'would show here as one row holding another buyer\'s name');
        }
    }

    /**
     * 🔴 251 NDAs **UPDATED** THROUGH THE REAL TRIGGER, EVERY ONE FLIPPING ITS BUYER, ALL 251
     * RESTAMPED. Added 2026-08-20 (code review W3).
     *
     * ⚠ WHY THIS IS NOT REDUNDANT WITH THE 251-ROW INSERT ABOVE, WHICH IS EXACTLY THE ARGUMENT THE
     * SUITE WAS MISSING: `.claude/rules/bulk-test-rule.md` mandates a bulk test PER TRIGGER CONTEXT
     * the trigger handles ("A positive bulk update test with 251 records (if trigger handles
     * updates)"). Insert and update reach this service down DIFFERENT branches — on insert `oldMap`
     * is NULL and every non-null buyer counts as a change by the null-prior shortcut; on update
     * `oldMap` is populated and the change-key is a genuine value comparison. The insert test
     * exercises none of that comparison at volume, so a bulkification defect confined to the
     * `oldMap.get(...)` path — the very path every other writer of this object takes — would not
     * have shown anywhere in this suite. The per-chunk-measurement rationale in the class header is
     * about the *budget* claim and never excused this gap.
     *
     * ── THE BUYERS ARE **ROTATED**, NOT REPLACED FROM A SECOND FIXTURE SET ─────────────────────
     * Row i moves from `buyers[i]` to `buyers[i + 1]` (wrapping). Every row's `Buyer__c` genuinely
     * changes, every row's expected name genuinely differs from the name it carried a moment ago,
     * and the whole thing costs ONE set of 251 Contacts instead of two.
     * 🔴 A SECOND `TestDataFactory.createContacts(251, ...)` CALL WOULD HAVE MADE THIS TEST PASS
     * VACUOUSLY: that factory builds `LastName = 'Contact ' + i` FROM THE LOOP INDEX, which resets
     * to 0 on every call (its own inline comment says so), so the second batch would carry the
     * IDENTICAL names to the first and "the name changed" could not be distinguished from "the
     * stamp never ran". The rotation makes the old and new names provably different, which is why
     * the `areNotEqual` below is a real falsifier.
     *
     * ⚠ THE QUERY BOUND IS DELIBERATELY LOOSE, AND CAPTURED **INSIDE** `Test.startTest()`.
     * Loose because an exact number here would pin the trigger CHUNK SIZE (251 rows = two chunks =
     * two legitimate queries), which the class header explains is not this service's property to
     * assert; the tight "EXACTLY 1 PER CHUNK" claim lives in
     * `bulk251BuyerChanges_costsExactlyOneQueryForTheWholeChunk`. Inside the test window because a
     * counter read AFTER `Test.stopTest()` is restored to its pre-test value and the assertion would
     * be silently vacuous — a trap this repo has been bitten by.
     */
    @isTest
    static void bulkUpdate251ChangingEveryBuyer_allRestampedThroughTheRealTrigger() {
        List<Contact> buyers = TestDataFactory.createContacts(BULK_N, null, true);
        List<NDA__c> ndas = typedNdas(BULK_N);
        for (Integer i = 0; i < BULK_N; i++) {
            ndas[i].Buyer__c = buyers[i].Id;
        }
        insert ndas;

        // Rotate: row i now names buyer i+1. Keyed by NDA Id because the verification query returns
        // rows in no guaranteed order.
        //
        // 🔴 THE ROTATION IS SENT AS 251 FRESH, NARROW sObjects RATHER THAN BY MUTATING `ndas`
        // (fixed 2026-08-21). Every row in `ndas` still carries the `TYPED_NAME` literal
        // `typedNdas()` wrote, because Apex never refreshes an sObject with values a before trigger
        // assigned — so `update ndas` re-sent 251 stale literals and the `areNotEqual(priorByNda...)`
        // assertion below was VACUOUS: the prior stamped name was never in the payload, so no
        // implementation of this service could have left it behind and that assertion could not
        // fail. With narrow payloads the DB genuinely holds buyer[i]'s stamped name going into this
        // save, and a stamp that skipped the update path leaves it there — which is exactly what
        // the assertion claims to catch.
        List<NDA__c> rotations = new List<NDA__c>();
        Map<Id, String> expectedByNda = new Map<Id, String>();
        Map<Id, String> priorByNda = new Map<Id, String>();
        for (Integer i = 0; i < BULK_N; i++) {
            Contact nextBuyer = buyers[Math.mod(i + 1, BULK_N)];
            priorByNda.put(ndas[i].Id, nameOf(buyers[i]));
            expectedByNda.put(ndas[i].Id, nameOf(nextBuyer));
            rotations.add(new NDA__c(Id = ndas[i].Id, Buyer__c = nextBuyer.Id));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        update rotations;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        List<NDA__c> saved = [
            SELECT Id, Buyer__c, Counterparty_Name__c FROM NDA__c WHERE Id IN :ndas
        ];
        Assert.areEqual(BULK_N, saved.size(), 'All 251 NDAs must still be there after the update');
        for (NDA__c nda : saved) {
            Assert.areEqual(expectedByNda.get(nda.Id), nda.Counterparty_Name__c,
                'Every one of the 251 rows must have been RESTAMPED from its NEW buyer — a row '
                + 'holding a neighbour\'s name is the cross-wiring this rotation is designed to '
                + 'expose, and a row holding no name at all is a skipped update');
            Assert.areNotEqual(priorByNda.get(nda.Id), nda.Counterparty_Name__c,
                'and specifically must NOT still hold the name it carried before this update — a '
                + 'stale name beside a new lookup is the exact disagreement this stamp prevents');
        }
        Assert.isTrue(queriesUsed <= 10,
            'A 251-row UPDATE must cost a handful of queries, not one per record. Bound, not exact '
            + 'count: two chunks legitimately cost two, and pinning the number here would pin the '
            + 'platform\'s chunk size. Actual: ' + queriesUsed);
    }

    /**
     * 🔴 THE CONSTANT-BUDGET FALSIFIER. 251 records, ALL changing their buyer, must cost EXACTLY ONE
     * query. Measured by DIRECT INVOCATION for the reason in the class header — a real 251-row DML
     * spans two chunks and would legitimately cost two.
     */
    @isTest
    static void bulk251BuyerChanges_costsExactlyOneQueryForTheWholeChunk() {
        List<Contact> buyers = TestDataFactory.createContacts(BULK_N, null, true);
        List<NDA__c> ndas = typedNdas(BULK_N);
        for (Integer i = 0; i < BULK_N; i++) {
            ndas[i].Buyer__c = buyers[i].Id;
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        // oldMap null == insert context: every non-null buyer counts as a change.
        NdaBuyerStampService.stampBuyerName(ndas, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 changed records. That CONSTANCY — not merely that 251 rows '
            + 'produced 251 stamps — is the property this rule exists to protect.');
        for (Integer i = 0; i < BULK_N; i++) {
            Assert.areEqual(nameOf(buyers[i]), ndas[i].Counterparty_Name__c,
                'and every row is stamped from its own Contact');
        }
    }

    /**
     * 🔴 THE ZERO-BUDGET FALSIFIER, AND THE ONE THAT MATTERS MOST FOR A BRAND-NEW TRIGGER ON A
     * DUAL-MODULE OBJECT: 251 records NONE of which changed `Buyer__c` must cost **ZERO** queries.
     * This is the shape of every acquisition save, every Flow re-entry, every status advance and
     * every existing fixture in the repo.
     */
    @isTest
    static void bulk251NoRecordChangesBuyer_costsNothing() {
        Contact buyer = TestDataFactory.createContact(null, true);
        List<NDA__c> ndas = typedNdas(BULK_N);
        Map<Id, NDA__c> oldMap = new Map<Id, NDA__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            Id fakeId = fakeNdaId(i + 1);
            ndas[i].Id = fakeId;
            ndas[i].Buyer__c = buyer.Id;
            // The prior value is the SAME buyer — i.e. this save changed something else.
            oldMap.put(fakeId, new NDA__c(Id = fakeId, Buyer__c = buyer.Id));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        NdaBuyerStampService.stampBuyerName(ndas, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'ZERO queries when no record changed its buyer. This is what makes NdaTrigger safe on '
            + 'every acquisition NDA and free on every existing test fixture in the repo.');
        for (NDA__c nda : ndas) {
            Assert.areEqual(TYPED_NAME, nda.Counterparty_Name__c,
                'and nothing was written');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fabricated Ids for direct-invocation tests
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A syntactically valid `NDA__c` Id that exists in no org. Safe ONLY for direct invocation —
     * nothing is saved, so no foreign key is validated.
     *
     * @param seed A per-row discriminator so the Ids in one chunk are distinct.
     * @return The fabricated Id.
     */
    private static Id fakeNdaId(Integer seed) {
        return Id.valueOf(
            NDA__c.SObjectType.getDescribe().getKeyPrefix()
                + '0'.repeat(12 - String.valueOf(seed).length())
                + String.valueOf(seed)
        );
    }

    /** Ditto, for Contact — the "this buyer resolves to nothing" case. */
    private static Id fakeContactId() {
        return Id.valueOf(Contact.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
    }
}
