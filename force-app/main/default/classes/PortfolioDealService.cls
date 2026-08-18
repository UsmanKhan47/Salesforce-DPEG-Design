/**
 * Broker Protection — the ONLY class in the application that WRITES `Portfolio_Deal__c`.
 *
 * A "portfolio deal" is ONE inbound broker email that named TWO OR MORE addressable
 * properties. The pipeline already derived that grouping correctly (see
 * `Inbound_Email_Staging__c.Routed_Record_Ids__c`, "the only place the full property-to-record
 * mapping exists") — but it derived it as TEXT on a Private-OWD backend object the Acquisitions
 * team cannot see. This object, and this service, exist to make that same grouping QUERYABLE and
 * VISIBLE on the records an analyst actually works. Nothing here re-derives anything.
 *
 * ═══ 🔴 VOCABULARY — "PORTFOLIO DEAL" IS ALWAYS SPELLED IN FULL, NEVER SHORTENED TO "DEAL" ═══
 * Renamed from `PropertyPackageService` / `Property_Package__c` in phase B4 of the Portfolio Deal
 * rename (2026-08-18). The bare word "deal" means an **Opportunity** everywhere else in this repo,
 * and this module writes Opportunities too, so a `Portfolio_Deal__c` is never called "the deal"
 * here. ⚠ AND THE MEANING DID NOT CHANGE WITH THE NAME: this is still exactly "one inbound broker
 * email that named several properties", not a seller's bundle of deals, not a fund, not a
 * portfolio of assets under management. See `LeadConvertService.applyDealFields` for the long-form
 * warning about the retired, unrelated concept that used to carry this name on Opportunity.
 *
 * ═══ LAYER ═══
 * Service. Zero SOQL (`createForEmail` is a blind insert; the caller already holds every value).
 * Every READ of `Portfolio_Deal__c` belongs in `PortfolioDealSelector`, which is the first
 * and only SOQL against this object in the application.
 *
 * ═══ SHARING — `with sharing`, AND NO `without sharing` INNER CLASS. DO NOT ADD ONE. ═══
 * 🔴 `Portfolio_Deal__c` is `sharingModel = ReadWrite` (Decision F1, carried over unchanged from
 * the object it replaces), deliberately matching its two sibling pipeline-written objects,
 * `Property_Registry__c` and `Competing_Broker_Submission__c`. That choice DELETES an entire
 * failure class rather than mitigating it: every `private without sharing` inner class in this repo
 * (`InboundEmailStagingSelector.RoutingReads`, `PropertyAssetSelector.AssetCreationReads`,
 * `PropertySelector.FolderCreationReads`, `DispositionOfferSelector.TractionReads`) exists
 * because a Private-OWD object made a pipeline read return zero rows for a principal who did not
 * own them — failing as SILENCE, or worse, as a DUPLICATE when the read backed an idempotency
 * guard. With `ReadWrite` OWD there is no such read here and no such class is needed.
 *
 * ⚠ If anyone ever narrows this object's OWD to Private, that is not a settings change — it
 * silently re-opens that whole class of defect for every reader of this object, starting with
 * `PortfolioDealController`'s sibling lookup. Change the OWD and this comment together, or not
 * at all.
 *
 * ═══ 🔴 WHY THE INSERT IS `AccessLevel.SYSTEM_MODE` — DAY-ONE FAILURE, NOT DEFENSIVENESS ═══
 * Every field on `Portfolio_Deal__c` is a Metadata-API-deployed custom field, and such a field
 * arrives with NO field permissions for ANY profile — System Administrator included. A bare
 * `insert` therefore throws `System.TypeException` on the first inbound multi-property email
 * after deploy, for every principal in the org, before any permission set is assigned. That is
 * the same measured reasoning `PropertyAssetService` and `DealFolderService` record for their own
 * DML, and the same reason `LeadConvertService`'s DML runs in system mode.
 *
 * ⚠ THAT ARGUMENT IS LIVE AGAIN, NOT HISTORICAL. The B1 object is a fresh set of Metadata-API
 * fields with their own fresh (empty) FLS — inheriting nothing from `Property_Package__c`'s
 * grants. This write survives the rename window for the same reason it survived day one; the
 * `WITH USER_MODE` reads in `PortfolioDealSelector` do not, which is why the permission-set grants
 * are part of the same program.
 *
 * ⚠ SYSTEM_MODE lifts CRUD and FLS. It does NOT lift sharing (irrelevant here — see above), and
 * it does NOT lift record-type visibility (irrelevant here — this object has no record types).
 *
 * ═══ IT THROWS. THE CALLER IS WHAT MAKES THAT SAFE. ═══
 * `createForEmail` uses `allOrNone = true`, so a failure raises `DmlException` rather than
 * silently returning null — a grouping that half-exists is worse than one that does not exist,
 * because `Lead.Portfolio_Deal__c` would then be stamped with nothing.
 *
 * 🔴 BUT THE CALLING TRANSACTION OWNS THE LEAD AND THE REGISTRY CLAIM, so
 * `ExtractAddressQueueable` wraps this call in its own try/catch and DEGRADES to "no portfolio
 * deal" rather than losing the email. That division is deliberate and must not be moved: this class
 * reports the truth, and the one caller that owns something irreplaceable decides what to do
 * about it. This is the same rule the 2026-08-06 `ContentPublication` outage produced — *a write
 * must never sit unguarded inside a transaction whose rollback would lose something
 * irreplaceable* — applied at the caller rather than by hiding the failure here.
 *
 * `stampRoutedOutcomes` is the opposite posture and says so at its own declaration: it is
 * FAIL-SOFT, because by the time it runs the portfolio deal and its links already exist and the
 * text it writes is a COPY of data that is already durable on the staging row.
 *
 * @see PortfolioDealSelector.cls (every READ of this object)
 * @see ExtractAddressQueueable.cls (the only caller — pre-loop creation, Decision C1)
 * @see agent-output/design-requirements-deal-portfolio.md (Decisions B2 / C1 / D / E / F)
 * @see agent-output/design-requirements-portfolio-deal-rename.md §5 (the B1-B6 rename phases)
 */
public with sharing class PortfolioDealService {

    /** `Portfolio_Deal__c.Name` is Text(80). The subject is clipped, never rejected. */
    private static final Integer LEN_NAME = 80;
    /** `Broker_Name__c` is Text(255). */
    private static final Integer LEN_BROKER_NAME = 255;
    /** `Routed_Outcomes__c` is LongTextArea(32768). */
    private static final Integer LEN_ROUTED_OUTCOMES = 32768;
    /**
     * `Property_Count__c` is Number(2,0), so 99 is the largest storable value.
     *
     * ⚠ THE CLAMP IS NOT COSMETIC. A value of 100 would throw at DML, and this insert sits in the
     * transaction that owns the Lead and the claim — so an unclamped count would turn a
     * pathological extraction into a lost broker submission. `ExtractAddressQueueable
     * .MAX_PROPERTIES` is 10 and the count passed here is the pre-truncation candidate count, so
     * reaching 99 requires an email naming 99 distinct addresses; unreachable is not the same as
     * impossible, and the failure mode is disproportionate.
     *
     * ⚠ ALL FOUR LENGTH/SCALE CONSTANTS ABOVE WERE RE-VERIFIED AGAINST THE NEW OBJECT'S OWN FIELD
     * METADATA IN PHASE B4, NOT ASSUMED FROM THE OLD ONE. The six fields were cloned 1:1 and the
     * API names are byte-identical, which is exactly why an unverified assumption would have gone
     * unnoticed until the first over-length subject line in production.
     */
    private static final Integer MAX_PROPERTY_COUNT = 99;

    /**
     * Fallback `Name` for an email with no subject. `Name` is required by the platform, so a blank
     * subject would otherwise throw REQUIRED_FIELD_MISSING inside the routing transaction.
     */
    private static final String NAME_FALLBACK = 'Multi-Property Email';

    /**
     * Create the portfolio deal for ONE inbound multi-property broker email.
     *
     * Called exactly ONCE per email, PRE-LOOP, so every Lead the email goes on to create can be
     * stamped with the portfolio deal Id AT INSERT — no Lead is ever re-updated for it
     * (Decision C1). `Routed_Outcomes__c` is deliberately NOT a parameter: the routing audit does
     * not exist yet at this point in the transaction. It is stamped afterwards by
     * `stampRoutedOutcomes`.
     *
     * ZERO SOQL. Exactly ONE DML statement.
     *
     * @param dealName      The email subject; clipped to 80, and replaced with a fixed fallback
     *                      when blank because `Name` is required.
     * @param propertyCount Distinct addressable properties the email named (pre-truncation);
     *                      clamped to 99, the largest value Number(2,0) can hold.
     * @param brokerEmail   The RESOLVED broker email (post-U1 envelope arbitration). Sanitized —
     *                      an LLM "email" can be a display name, and `Broker_Email__c` is an Email
     *                      field, so a raw value would throw INVALID_EMAIL_ADDRESS and take the
     *                      claim with it.
     * @param brokerName    The RESOLVED broker name (post-U1); clipped to 255.
     * @param stagingId     The `Inbound_Email_Staging__c` row this email landed on — a Text
     *                      pointer, not a lookup, mirroring `Result_Record_Id__c`'s precedent.
     * @param receivedOn    When the email was sent, as the pipeline parsed it; may be null.
     * @return The new portfolio deal's Id. Never null — a failure throws instead.
     * @throws DmlException when the insert fails. The caller owns the Lead and the registry claim
     *         and MUST decide what that costs; see this class's header.
     * @example
     * Id portfolioDealId = PortfolioDealService.createForEmail(
     *     staging.Subject__c, candidateCount, extraction.brokerEmail, extraction.brokerName,
     *     stagingId, submittedOn);
     */
    public static Id createForEmail(String dealName, Integer propertyCount, String brokerEmail,
                                    String brokerName, Id stagingId, Datetime receivedOn) {
        Portfolio_Deal__c deal = new Portfolio_Deal__c();
        deal.Name = String.isNotBlank(dealName)
            ? InboundEmailFieldUtil.clip(dealName, LEN_NAME)
            : NAME_FALLBACK;
        deal.Property_Count__c = clampCount(propertyCount);
        // Sanitized, not clipped: an over-long or malformed address becomes null (a blank field a
        // human can fix) rather than a DML failure that costs the email its claim.
        deal.Broker_Email__c = InboundEmailFieldUtil.sanitizeEmail(brokerEmail);
        deal.Broker_Name__c = InboundEmailFieldUtil.clip(brokerName, LEN_BROKER_NAME);
        deal.Source_Staging_Id__c = (stagingId == null) ? null : String.valueOf(stagingId);
        deal.Received_DateTime__c = receivedOn;

        // 🔴 SYSTEM_MODE: the fields are Metadata-API-deployed and carry no FLS for any profile,
        // System Administrator included — a bare insert throws System.TypeException on day one.
        // allOrNone = true: a portfolio deal that fails must be reported, never silently absent.
        Database.insert(new List<Portfolio_Deal__c>{ deal }, true, AccessLevel.SYSTEM_MODE);
        return deal.Id;
    }

    /**
     * Copy the email's full per-property routing audit onto an EXISTING portfolio deal
     * (Decision B2).
     *
     * ═══ WHY THIS IS A SECOND STATEMENT AND NOT PART OF THE INSERT ═══
     * The audit is a function of the routing OUTCOMES, which do not exist until the per-property
     * loop has finished — while the portfolio deal Id must exist BEFORE the loop starts, so each
     * Lead can be stamped at insert (Decision C1). Those two requirements are on opposite sides of
     * the loop, so no single DML statement can satisfy both. See `ExtractAddressQueueable.finish()`
     * for the resulting, deliberately-flagged budget cost.
     *
     * ═══ FAIL-SOFT, UNLIKE `createForEmail` — AND THE ASYMMETRY IS THE POINT ═══
     * By the time this runs the portfolio deal exists, every Lead is already linked to it, and the
     * same audit text is already durable on `Inbound_Email_Staging__c.Routed_Record_Ids__c` (the
     * canonical copy). So a failure here loses a CONVENIENCE COPY of recoverable data, whereas
     * raising would risk the routing record itself — the caller invokes this AFTER `markRouted`
     * precisely so nothing it does can cost the email its routing. Same posture, same reasoning,
     * as `InboundEmailStagingService`'s own status writes.
     *
     * It catches `Exception` rather than `DmlException` on purpose: this method's own catch is the
     * last line of defence in a transaction that has already committed everything that matters.
     *
     * @param portfolioDealId The portfolio deal to stamp; null is a NO-OP, which is what makes the
     *                        caller's single-property and gated paths free.
     * @param routedAudit The audit block (one line per property); blank is a no-op.
     * @example
     * PortfolioDealService.stampRoutedOutcomes(portfolioDealId, buildRoutedAudit());
     */
    public static void stampRoutedOutcomes(Id portfolioDealId, String routedAudit) {
        if (portfolioDealId == null || String.isBlank(routedAudit)) {
            return;
        }
        try {
            Database.update(
                new List<Portfolio_Deal__c>{
                    new Portfolio_Deal__c(
                        Id = portfolioDealId,
                        Routed_Outcomes__c =
                            InboundEmailFieldUtil.clip(routedAudit, LEN_ROUTED_OUTCOMES)
                    )
                },
                true,
                AccessLevel.SYSTEM_MODE
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'PortfolioDealService.stampRoutedOutcomes: could not stamp the routing audit on '
                + 'portfolio deal ' + portfolioDealId + '. The canonical copy is on the staging '
                + 'row\'s Routed_Record_Ids__c. ' + e.getMessage());
        }
    }

    /**
     * Hold `Property_Count__c` inside what Number(2,0) can store.
     *
     * @param propertyCount The raw candidate count; null or non-positive yields null.
     * @return The count, capped at 99, or null.
     */
    private static Integer clampCount(Integer propertyCount) {
        if (propertyCount == null || propertyCount <= 0) {
            return null;
        }
        return Math.min(propertyCount, MAX_PROPERTY_COUNT);
    }
}
