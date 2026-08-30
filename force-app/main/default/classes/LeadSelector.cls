/**
 * Selector for Lead. Encapsulates ALL SOQL against Lead per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 Acquisitions. Consumers:
 *   - LeadFunnelController (internal Lead-Funnel dashboard: 5 relocated statements —
 *     status counts, LeadSource counts, 90-day converted / disqualified outcome
 *     counts, recent-leads list). USER_MODE.
 *   - BrokerPortalNotifier (guest/automation Broker-Portal lead-intake notification
 *     path). SYSTEM_MODE (selectByIdsSystem — by-Id fetch of just-created leads).
 *   - BrokerPortalController (guest LWR deal-intake controller: open-duplicate
 *     detection by property address). SYSTEM_MODE + without sharing —
 *     GuestReads.selectOpenDuplicatesByAddressSystem (nested class below).
 *   - PropertyMatchingService.resolveLiveRecord (inbound-email reply threading:
 *     follows a converted Lead to the record it became). USER_MODE —
 *     selectConversionById.
 *   - LeadConvertMatchService.matchForConversion (Smart Lead Conversion,
 *     2026-08-02: reads Email + Company as the attach-to-existing match keys).
 *     USER_MODE — selectMatchKeysByIds, OR selectMatchKeysWithBrokerByIds (WS8,
 *     2026-08-30) when the running user can read the intake broker link. 🔴 THE
 *     CALLER CHOOSES BETWEEN THEM WITH A DESCRIBE, and that choice is not
 *     cosmetic — see selectMatchKeysWithBrokerByIds for why folding its three
 *     extra columns into selectMatchKeysByIds would have silently disabled Smart
 *     Lead Conversion for every user until the P8 FLS grant landed.
 *
 * ⚠ ADDED-METHOD NOTE (flagged to the orchestrator, accepted). The P4 cleanup-wave
 * task directed BrokerPortalController's Lead site to "reuse selectByIdsSystem".
 * That is not expressible: selectByIdsSystem is a by-Id fetch (Set<Id> ->
 * notification body fields), whereas the controller's isDuplicate SEARCHES for an
 * open lead by Property_Address__c + Status. No existing method matches, so
 * relocating the SOQL out of the controller (the wave's primary goal: 0 inline SOQL)
 * required this one additive method. selectByIdsSystem and every other method are
 * unchanged.
 *
 * ⚠ SHARING — the dedup read is BEHAVIOR-PRESERVING WITHOUT SHARING (see the nested
 * `GuestReads` class). The outer LeadSelector stays `with sharing`; only the guest
 * dedup lives in the `without sharing` inner class so it sees ALL open leads at an
 * address regardless of the guest user's sharing — exactly as the original
 * `without sharing` BrokerPortalController inline query did. Under `WITH SYSTEM_MODE`,
 * FLS is bypassed but record-level sharing follows the class keyword; a `with sharing`
 * selector would have silently scoped the dedup to the (minimal, unconfigured) guest
 * sharing and weakened the Duplicate_Flag__c anti-abuse signal. selectByIdsSystem
 * (the notifier by-Id fetch, out of scope) is left `with sharing` unchanged.
 *
 * ── MODE ──────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector).
 *
 * The internal funnel methods use `WITH USER_MODE` (API 67). Per the P4 design §5
 * the only FLS-bearing standard field selected on this object is `LeadSource`, and
 * the live-active `Standard User` profile has READ = true on it, so USER_MODE
 * cannot throw; the remaining selected / aggregated standard fields (Id, Name,
 * Status, ConvertedDate, LastModifiedDate) are `permissionable=false` (never
 * FLS-subject), and the custom fields selected by selectRecent (Parse_Confidence__c,
 * Extraction_Score_Pct__c, Guidance_Price__c, Broker_First__c, Property_Address__c,
 * Asset_Type__c, First_Seen_Date__c, Broker_Priority__c) are granted by the deployed
 * Acquisition permission sets (P3 custom-field FLS gap = 0).
 * ⚠ `Extraction_Score_Pct__c` joined that list on 2026-08-17; its grant was verified in
 * all three named sets BEFORE the field entered the SELECT — the evidence is recorded at
 * selectRecent itself.
 *
 * 🔴 THAT LIST IS A PRE-CONDITION, NOT A DESCRIPTION. `WITH USER_MODE` throws on the
 * WHOLE ROW for ONE inaccessible field, so adding a custom field to selectRecent —
 * the Lead Funnel homepage's read — means verifying its grant in DPEG_Acquisition_Edit,
 * DPEG_Acquisition_View and Broker_Protection_Access FIRST, per field. A missing grant
 * does not hide a column; it throws the whole homepage query.
 *
 * ⚠ AMENDED 2026-08-17 — the multi-property grouping lookup briefly appeared in that list
 * (plus its spanning `.Name`) for recentLeads' 'Package' column, and was removed with the
 * column the same day; c/recentPortfolioDeals now owns that fact and reads the object directly.
 * selectRecent no longer touches the field, so the homepage no longer depends on its grant.
 *
 * ⚠ RENAMED 2026-08-18 (Portfolio Deal rename, phase B4) — that lookup is now
 * `Lead.Portfolio_Deal__c`, pointing at `Portfolio_Deal__c`, and every reference below was
 * repointed. 🔴 THE OLD `Lead.Property_Package__c` STILL EXISTS AND IS STILL POPULATED until
 * phase B5 retires it; nothing in this class reads it any more, so a row created before the
 * B3 migration and never re-migrated will read as having NO grouping here rather than as an
 * error. The word "Package" survives in the METHOD name and in the historical notes about
 * the retired funnel column below — deliberately, see selectPackageAnchorById.
 *
 * ⚠ selectPackageAnchorById (2026-08-17) is therefore the ONLY USER_MODE consumer of
 * Portfolio_Deal__c here — it was the second until the narrowing above. It backs the
 * c/portfolioDealSiblings card on the Lead record page and is the LEAD-rooted half of that
 * feature's reads — the PORTFOLIO-DEAL-rooted half lives in PortfolioDealSelector, because
 * SOQL follows the object it queries. It is what keeps the field's FLS grants load-bearing in
 * the three Acquisition permission sets, so those grants must not be retired — and they must
 * now name the NEW field, since the old one is no longer read from here.
 *
 * selectByIdsSystem uses `WITH SYSTEM_MODE` (API 67), justified: it is called only
 * from BrokerPortalNotifier in the guest/automation context of the public Broker
 * Portal. Per the P4 design §5 the guest path is not placed under USER_MODE
 * unverified (guest FLS lives on the non-deployable Guest Profile; P3's guest spike
 * never completed). SYSTEM_MODE bypasses FLS on that read; the internal funnel
 * methods stay strictly USER_MODE.
 *
 * ── HISTORY ───────────────────────────────────────────────────────────────────
 * The P4 design (§7) assumed Module A1 would create this class with the USER_MODE
 * funnel methods and repoint LeadFunnelController, while A2 added only the guest
 * SYSTEM_MODE method. A1 shipped without LeadSelector, so A2 created the class with
 * selectByIdsSystem alone. The P4 cleanup wave (Lead cluster) then added the funnel
 * methods below and repointed LeadFunnelController — finishing A1's intended work.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #17, §5, §7)
 */
public with sharing class LeadSelector {

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNNEL READS (LeadFunnelController) — WITH USER_MODE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Lead counts grouped by Status — backs the funnel stage widgets. Bulk-safe
     * (single aggregate query, no per-record work).
     *
     * @return AggregateResult rows with alias `st` (Status) and `c` (COUNT(Id));
     *         empty when there are no Leads.
     * @example
     * for (AggregateResult ar : LeadSelector.countByStatus()) {
     *     String status = (String) ar.get('st');
     *     Integer count = (Integer) ar.get('c');
     * }
     */
    public static List<AggregateResult> countByStatus() {
        return [
            SELECT Status st, COUNT(Id) c
            FROM Lead
            WITH USER_MODE
            GROUP BY Status
        ];
    }

    /**
     * Lead counts grouped by intake channel (LeadSource), excluding rows with no
     * source — backs the funnel channel widgets. Bulk-safe.
     *
     * @return AggregateResult rows with alias `ls` (LeadSource) and `c`
     *         (COUNT(Id)); empty when there are no sourced Leads.
     * @example
     * for (AggregateResult ar : LeadSelector.countByLeadSource()) {
     *     String source = (String) ar.get('ls');
     *     Integer count = (Integer) ar.get('c');
     * }
     */
    public static List<AggregateResult> countByLeadSource() {
        return [
            SELECT LeadSource ls, COUNT(Id) c
            FROM Lead
            WHERE LeadSource != null
            WITH USER_MODE
            GROUP BY LeadSource
        ];
    }

    /**
     * Count of Leads converted within the trailing N days — backs the recency-scoped
     * "Converted" outcome widget. ConvertedDate marks conversions.
     *
     * Dynamic because the operand of the `LAST_N_DAYS:n` date literal cannot be a
     * bind variable. `days` is coerced through Integer.valueOf and the Status value
     * is passed as a real bind, so neither reaches the query as free text —
     * injection-safe (mirrors OpportunitySelector.countByStageInLastNDays).
     *
     * @param days Trailing window in days for ConvertedDate = LAST_N_DAYS:days;
     *             null / non-positive returns 0.
     * @return The matching converted-Lead count (0 when none).
     */
    public static Integer countConvertedInLastNDays(Integer days) {
        if (days == null || days <= 0) {
            return 0;
        }
        String status = 'Converted';
        return Database.countQuery(
            'SELECT COUNT() FROM Lead ' +
            'WHERE Status = :status AND ConvertedDate = LAST_N_DAYS:' + Integer.valueOf(days),
            AccessLevel.USER_MODE
        );
    }

    /**
     * Count of Leads disqualified within the trailing N days — backs the
     * recency-scoped "Disqualified" outcome widget. LastModifiedDate is the best
     * available proxy for disqualification time (there is no dedicated timestamp).
     *
     * Dynamic for the same LAST_N_DAYS reason as countConvertedInLastNDays; `days`
     * is coerced and the Status value is bound — injection-safe.
     *
     * @param days Trailing window in days for LastModifiedDate = LAST_N_DAYS:days;
     *             null / non-positive returns 0.
     * @return The matching disqualified-Lead count (0 when none).
     */
    public static Integer countDisqualifiedInLastNDays(Integer days) {
        if (days == null || days <= 0) {
            return 0;
        }
        String status = 'Disqualified';
        return Database.countQuery(
            'SELECT COUNT() FROM Lead ' +
            'WHERE Status = :status AND LastModifiedDate = LAST_N_DAYS:' + Integer.valueOf(days),
            AccessLevel.USER_MODE
        );
    }

    /**
     * Most-recent OPEN (non-converted) Leads for the funnel's recent / review-queue
     * list, newest first by First Seen Date (the immutable intake stamp) then
     * CreatedDate. Bulk-safe; capped by the caller's row limit.
     *
     * `IsConverted = false` filters out converted Leads on purpose. A converted Lead
     * is not actionable in this list: Salesforce ALWAYS auto-redirects
     * `/lightning/r/Lead/{convertedLeadId}/view` to the converted Contact, so a
     * converted row would silently navigate the user off the Lead — there is no way to
     * suppress that redirect. Excluding converted Leads keeps every row clickable to an
     * actual Lead record. The funnel's "Converted" outcome metric is computed
     * separately by countConvertedInLastNDays(...) and is unaffected by this filter.
     *
     * ═══ ⚠ WIDENED AND THEN NARROWED AGAIN, BOTH ON 2026-08-17 — READ THIS BEFORE RE-ADDING ═══
     * `Portfolio_Deal__c` and the SPANNING `Portfolio_Deal__r.Name` were added to this SELECT so
     * `recentLeads` could show which multi-property email a Lead arrived on, and were REMOVED the
     * same day when that 'Package' column was retired in favour of the dedicated
     * `c/recentPortfolioDeals` card (which reads `Portfolio_Deal__c` directly, so it escapes this
     * method's priority partitioning and 5-row client cutoff). `LeadFunnelController.LeadRow` lost `packageId` /
     * `packageName` in the same change, so the two fields had no consumer left.
     *
     * RETRACTED, verbatim, from the widening note that stood here: *"The spanning field rides this
     * same query, so the widening costs ZERO extra SOQL."* True as far as it went, and beside the
     * point — the cost was never SOQL:
     *
     * 🔴 THE REAL CURRENCY IS FLS, AND THAT IS WHY THE NARROWING IS A WIN RATHER THAN TIDYING. This
     * method is `WITH USER_MODE`, which THROWS on the WHOLE ROW for ONE inaccessible field, so a
     * persona without FLS on `Lead.Portfolio_Deal__c` did not lose one column — THEY LOST THE
     * ENTIRE LEAD FUNNEL HOMEPAGE (`LeadFunnelController.getFunnel` catches and shows its generic
     * failure message). Removing the pair takes the homepage's FLS surface back down to the fields it
     * actually displays. That is the trap ARCHITECTURE.md records for
     * `InboundEmailStagingSelector.selectById`, which is why `Routing_Attempt_Count__c` was
     * deliberately kept OUT of it.
     *
     * ⚠ THE PERMISSION SETS WERE NOT TOUCHED, AND MUST NOT BE "CLEANED UP" ON THE STRENGTH OF THIS.
     * `Lead.Portfolio_Deal__c` stays granted readable in `DPEG_Acquisition_Edit`,
     * `DPEG_Acquisition_View` and `Broker_Protection_Access` because `selectPackageAnchorById` below
     * still reads it for the `c/portfolioDealSiblings` card. This method simply no longer DEPENDS on
     * those grants.
     * 🔴 A future field added here needs per-field grant verification in all three sets FIRST. Do not
     * add one on the assumption that the sibling fields' grants cover it, and do not re-add these two
     * without also restoring their DTO members and their client-side reader.
     *
     * ═══ WIDENED 2026-08-17 — `Extraction_Score_Pct__c`, AND THE RULE ABOVE WAS FOLLOWED ═══
     * Added so `c/recentLeads`' renamed 'Score' column can show extraction COMPLETENESS beside the
     * `Parse_Confidence__c` band it already showed. Per the pre-condition immediately above, the grant
     * was verified PER SET BEFORE the field was added, not after:
     *   • `DPEG_Acquisition_Edit`   — `Lead.Extraction_Score_Pct__c` readable=true, editable=true
     *   • `DPEG_Acquisition_View`   — readable=true, editable=false
     *   • `Broker_Protection_Access` — readable=true, editable=true
     *   • (`DPEG_Admin_Access` also grants it — the §7 profile-restoration set)
     * All four are declared IN-FILE, so they survive the REPLACE-not-merge behaviour of a permission
     * set deploy. The three named sets are the ones that matter: a persona missing any one of them
     * would not lose the Score column, it would lose the ENTIRE Lead Funnel homepage, because
     * `WITH USER_MODE` throws on the WHOLE ROW for one inaccessible field and
     * `LeadFunnelController.getFunnel` catches it into its generic failure message.
     *
     * ⚠ IT IS A DIFFERENT FACT FROM `Parse_Confidence__c` AND THE TWO MUST NOT BE CONFLATED — the
     * field's own metadata comment is explicit. Confidence is the model's certainty about ONE
     * question (`is_acquisition_related`, which the D2 hard relevance gate consumes); the score is
     * what proportion of the nine signed-off deal-process keys were actually captured. A confident,
     * correctly-classified email can be almost empty of deal facts. Both are selected, both are sent,
     * and the client renders them as two distinct visual elements in one cell.
     *
     * ⚠ NULL IS MEANINGFUL HERE, NOT MISSING DATA. Scoring is fail-soft by mandate (the inbound email
     * pipeline must never be made to throw), so a null reads "not scored" and is NOT zero. Do not
     * coalesce it in this query, in the controller, or on the client.
     *
     * @param maxRows Row cap (LIMIT); null / non-positive returns an empty list.
     * @return Open (non-converted) Leads with the funnel display + partition fields
     *         populated (Id, Name, Status, LeadSource, Parse_Confidence__c,
     *         Extraction_Score_Pct__c, Guidance_Price__c, Broker_First__c,
     *         Property_Address__c, Asset_Type__c, First_Seen_Date__c, CreatedDate,
     *         Broker_Priority__c) ordered First_Seen_Date__c DESC NULLS LAST,
     *         CreatedDate DESC; empty when there are no open Leads.
     */
    public static List<Lead> selectRecent(Integer maxRows) {
        if (maxRows == null || maxRows <= 0) {
            return new List<Lead>();
        }
        return [
            SELECT Id, Name, Status, LeadSource, Parse_Confidence__c,
                   Extraction_Score_Pct__c, Guidance_Price__c,
                   Broker_First__c, Property_Address__c, Asset_Type__c,
                   First_Seen_Date__c, CreatedDate, Broker_Priority__c
            FROM Lead
            WHERE IsConverted = false
            WITH USER_MODE
            ORDER BY First_Seen_Date__c DESC NULLS LAST, CreatedDate DESC
            LIMIT :maxRows
        ];
    }

    /**
     * The `Portfolio_Deal__c` one Lead belongs to — the ANCHOR read behind the
     * `c/portfolioDealSiblings` card on the Lead record page.
     *
     * 🔴 IT LIVES HERE, NOT IN `PortfolioDealSelector`, AND THAT IS THE LAYERING RULE
     * RATHER THAN A PREFERENCE. This is a query against LEAD, and
     * .claude/rules/apex-layering-rule.md is explicit that all SOQL for an object lives in
     * that object's selector and "nothing else queries it". `PortfolioDealSelector` owns
     * the portfolio-deal-rooted read (which returns both member collections through
     * relationship subqueries); this owns the Lead-rooted one. `OpportunitySelector
     * .selectPackageAnchorById` is its exact twin — change both or neither.
     *
     * ⚠ THE METHOD NAME STILL SAYS "Package" AFTER THE 2026-08-18 RENAME, AND THAT WAS A
     * DECISION RATHER THAN AN OVERSIGHT. Phase B4 was scoped to repoint this class's
     * REFERENCES, not to alter its public surface: `DPEG_Admin_Access` and
     * `DPEG_Acquisition_Edit` both cite `LeadSelector.selectPackageAnchorById` BY NAME as the
     * standing justification for an FLS grant, and those files belong to a parallel task. The
     * query below is the authority on what this reads — `Portfolio_Deal__c`. Renaming it is a
     * clean follow-up once the permission sets land, and must move all four sites together
     * (here, `OpportunitySelector`, `PortfolioDealController.resolvePortfolioDealId`, and the
     * permission-set headers).
     *
     * USER_MODE, per the §2 default: this backs a card on a record page the human already
     * opened. It is NOT an automation path and must not be moved to SYSTEM_MODE; the FLS
     * grants are declared in the three Acquisition permission sets.
     *
     * NOT-FOUND CONTRACT — an empty list, never null and never a throw. The controller
     * treats "no row" and "no portfolio deal" identically and renders nothing, so a stale Id on a
     * record page is an ordinary answer rather than an error.
     *
     * ═══ ⚠ THE PORTFOLIO DEAL'S `Name` IS DELIBERATELY NOT SELECTED HERE (2026-08-17, review W2) ═══
     * The spanning `Portfolio_Deal__r.Name` was in this SELECT and was REMOVED, because the only
     * consumer — `PortfolioDealController.resolvePortfolioDealId` — reads `Portfolio_Deal__c` and
     * nothing else; the card's heading comes from `PortfolioDealSelector.selectWithMembersById`,
     * which selects `Name` off the portfolio deal itself one query later. A parent traversal under
     * `WITH USER_MODE` needs READ on the parent OBJECT as well as FLS on the field, so carrying it
     * here was an extra, unused way for this anchor read to THROW — buying nothing.
     *
     * ⚠ AMENDED 2026-08-17 — THE COMPARISON THIS NOTE DREW IS NOW OBSOLETE, THOUGH THE RULE IS NOT.
     * RETRACTED, verbatim: *"Do not 'restore it for symmetry' with `selectRecent`, which genuinely
     * consumes the spanning field (`LeadFunnelController` maps it onto the funnel's Package column)
     * and correctly keeps it."* `selectRecent` no longer selects `Portfolio_Deal__c` or the spanning
     * `Portfolio_Deal__r.Name` at all — the funnel's Package column was retired the same day in
     * favour of `c/recentPortfolioDeals` — so there is no longer a sibling to be asymmetric with. The
     * prohibition stands on its own merits regardless: an unconsumed spanning field is an extra way
     * for this read to THROW under `WITH USER_MODE`, and the card's heading still comes from
     * `PortfolioDealSelector.selectWithMembersById` one query later.
     *
     * @param leadId The Lead whose portfolio deal to resolve; null returns an empty list WITHOUT
     *               querying.
     * @return At most one Lead (Id, Portfolio_Deal__c — the Id only, never the portfolio deal's
     *         Name); empty when `leadId` is null or matches no row.
     * @throws System.QueryException when the running user lacks FLS on
     *         `Lead.Portfolio_Deal__c`.
     * @example
     * List<Lead> rows = LeadSelector.selectPackageAnchorById(recordId);
     */
    public static List<Lead> selectPackageAnchorById(Id leadId) {
        if (leadId == null) {
            return new List<Lead>();
        }
        return [
            SELECT Id, Portfolio_Deal__c
            FROM Lead
            WHERE Id = :leadId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BROKER PROTECTION — CONVERSION READ (PropertyMatchingService) — WITH USER_MODE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The conversion state of one Lead — backs
     * PropertyMatchingService.resolveLiveRecord, which follows a converted Lead to the
     * Opportunity (or Contact) it became so an inbound reply threads onto the LIVE deal
     * record rather than the husk Lead left behind by conversion.
     *
     * USER_MODE: internal automation path (the inbound-email pipeline), and all three
     * selected fields are standard system fields with no restrictive FLS. The guest-path
     * SYSTEM_MODE methods below stay separate per the policy in the class header.
     *
     * NOT-FOUND CONTRACT — an empty List, never null: the caller treats "no row" the same
     * as "not converted" and falls back to the original Id.
     *
     * @param leadId Lead Id whose conversion state to read; null returns an empty list.
     * @return At most one Lead (Id, IsConverted, ConvertedOpportunityId,
     *         ConvertedContactId); empty when `leadId` is null or no row matches.
     * @example
     * List<Lead> rows = LeadSelector.selectConversionById(leadId);
     */
    public static List<Lead> selectConversionById(Id leadId) {
        if (leadId == null) {
            return new List<Lead>();
        }
        return [
            SELECT Id, IsConverted, ConvertedOpportunityId, ConvertedContactId
            FROM Lead
            WHERE Id = :leadId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * The match keys of the Leads about to be converted — backs
     * LeadConvertMatchService.matchForConversion (Smart Lead Conversion), which uses Email to
     * find the broker's existing Contact and Company to find their existing brokerage-firm
     * Account, so conversion ATTACHES instead of minting duplicates.
     *
     * These two fields are the whole contract. Email is this module's durable broker identity
     * (Competing_Broker_Submission__c.Broker_Email__c, selectRecentByBrokerEmail,
     * GuestReads.selectBrokerPriorityByEmailSystem all key on it) and Company is the firm name.
     * Nothing else is selected because nothing else participates in matching — in particular the
     * person NAME is deliberately absent: it is LLM-extracted from a forwarded signature block and
     * is the least stable value on these Leads, so it is neither a requirement nor a widener
     * (design D1a). Do not add it here to "improve" matching.
     *
     * USER_MODE: internal, user-initiated path (a user clicking Convert), so the §2 default
     * applies — not the guest/automation SYSTEM_MODE reads below. Lead.Company is required (and
     * so not FLS-restrictable) but Lead.Email IS FLS-permissionable, so this CAN throw for a user
     * without read on it. USER_MODE throws rather than degrading; the caller catches
     * QueryException and falls back to no-match so conversion never regresses for a user who can
     * convert today. Left to propagate here by design.
     *
     * @param leadIds The Leads about to be converted; null/empty returns an empty list WITHOUT
     *                querying.
     * @return Leads with Id, Email, Company populated; an empty list when the input is null or
     *         empty (never null).
     * @throws System.QueryException when the running user lacks read on Lead.Email.
     * @example
     * List<Lead> keys = LeadSelector.selectMatchKeysByIds(new Set<Id>{ leadId });
     */
    public static List<Lead> selectMatchKeysByIds(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return new List<Lead>();
        }
        return [
            SELECT Id, Email, Company
            FROM Lead
            WHERE Id IN :leadIds
            WITH USER_MODE
        ];
    }

    /**
     * The match keys of the Leads about to be converted, PLUS the intake-time broker link — backs
     * `LeadConvertMatchService.matchForConversion` (WS8, 2026-08-30) when, and only when, the
     * running user can read that link.
     *
     * ═══ 🔴 WHY THIS IS A SECOND METHOD AND NOT THREE MORE FIELDS ON selectMatchKeysByIds ═══
     * `Lead.Broker__c` and `Lead.Broker_Firm__c` are NEW Metadata-API-deployed fields, and such a
     * field arrives with FLS for NOBODY — System Administrator included (ARCHITECTURE.md §2).
     * `WITH USER_MODE` THROWS ON THE WHOLE ROW FOR ONE INACCESSIBLE FIELD, and this query's caller
     * catches `QueryException` and DEGRADES TO NO-MATCH. So adding the two columns to the existing
     * method would not have added a signal — between the WS8 deploy and the P8 permission-set
     * pass it would have SILENTLY DISABLED SMART LEAD CONVERSION ENTIRELY, reintroducing the exact
     * duplicate-Contact accumulation that class was built on 2026-08-02 to stop. That is the same
     * "a green deploy proves nothing, the failure is runtime-only" shape recorded at
     * `EmailToLeadService.jsonWritable()`.
     *
     * The caller therefore ASKS A DESCRIBE FIRST and picks the method. `selectMatchKeysByIds` above
     * is byte-identical to what it has always been and remains the answer whenever the link is not
     * readable, so the ungranted state costs the new preference and NOTHING ELSE.
     *
     * ═══ 🔴 `Broker__r.AccountId` IS SPANNED DELIBERATELY, AND IT IS NOT THE SAME AS Broker_Firm__c ═══
     * The platform requires a specified conversion Contact to belong to the Account being converted
     * into (`LeadConvert.setContactId` is valid only alongside a `setAccountId` for that Contact's
     * OWN Account). `Broker_Firm__c` is a separate, independently editable lookup — a human can
     * point it somewhere else, and then the pair would name a Contact that does not belong to the
     * Account and `Database.convertLead` would throw, breaking a conversion that works today.
     * Reading the Account THROUGH the Contact makes the invariant true BY CONSTRUCTION, which is
     * the identical technique `ContactSelector.selectByEmails` uses (`AccountId != null` in the
     * query, `match.accountId = matchedContact.AccountId` in the service). `Broker_Firm__c` is
     * still selected — it is the caller's lower-precedence FIRM-ONLY signal, where no Contact is
     * being specified and the invariant does not arise.
     *
     * ⚠ THE SPAN COSTS NO EXTRA QUERY (it is a relationship traversal in this same statement) but
     * it DOES require Contact read. That is folded into the caller's describe gate, because a user
     * with no Contact access converting an EMAIL-LESS Lead would otherwise degrade where today
     * they match an Account by name — a narrow but real regression. See the caller.
     *
     * USER_MODE: internal, user-initiated path — identical justification to the method above, and
     * the same `@throws` contract. Left to propagate; the caller owns the fail-soft.
     *
     * @param leadIds The Leads about to be converted; null/empty returns an empty list WITHOUT
     *                querying.
     * @return Leads with Id, Email, Company, Broker__c, Broker__r.AccountId and Broker_Firm__c
     *         populated; an empty list when the input is null or empty (never null).
     * @throws System.QueryException when the running user lacks read on Lead.Email, on either
     *         broker lookup, or on Contact.
     * @example
     * List<Lead> keys = LeadSelector.selectMatchKeysWithBrokerByIds(new Set<Id>{ leadId });
     */
    public static List<Lead> selectMatchKeysWithBrokerByIds(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return new List<Lead>();
        }
        return [
            SELECT Id, Email, Company, Broker__c, Broker__r.AccountId, Broker_Firm__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH USER_MODE
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GUEST / AUTOMATION READ (BrokerPortalNotifier) — WITH SYSTEM_MODE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Leads by Id for the Broker-Portal new-lead notification — backs
     * BrokerPortalNotifier.notifyNewLeads (builds the notification title/body from
     * Name / Company / Property_Address__c). Bulk-safe.
     *
     * SYSTEM_MODE: guest/automation path (see class header). Selected fields
     * (Name/Company are permissionable=false; Property_Address__c is a granted
     * custom field) would pass USER_MODE, but per policy the guest path is
     * explicitly SYSTEM_MODE and kept separate from any internal USER_MODE method.
     *
     * @param leadIds Lead Ids to load; null/empty-safe.
     * @return Leads with Id, Name, Company, Property_Address__c populated; empty
     *         when the input is null or empty.
     */
    public static List<Lead> selectByIdsSystem(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return new List<Lead>();
        }
        return [
            SELECT Id, Name, Company, Property_Address__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * Guest-portal anti-abuse Lead reads that MUST run WITHOUT SHARING.
     *
     * `without sharing` — guest-portal anti-abuse read; must see ALL records
     * regardless of the site guest user's sharing, which is minimal and unconfigured
     * (P3 guest spike incomplete). Inner classes do NOT inherit the outer class's
     * sharing, so `without sharing` is declared explicitly here; the outer
     * LeadSelector stays `with sharing`. Apex forbids static methods on inner
     * classes, so this is an instance method — call
     * `new LeadSelector.GuestReads().selectOpenDuplicatesByAddressSystem(...)`.
     *
     * ⚠ PRE-PROMOTION: this preserves the INTENT (all-records anti-abuse dedup, as
     * the original `without sharing` BrokerPortalController inline query did), but
     * the guest sharing/ownership model itself is still unverified — the P3
     * guest-sharing spike must be completed before portal promotion.
     */
    public without sharing class GuestReads {

        /**
         * Open (non-closed) leads at a given property address — backs
         * BrokerPortalController.isDuplicate, which flags a broker submission as a
         * duplicate when an open lead already exists for the same address. Mirrors
         * the original inline query exactly: address trimmed, Status excluded via
         * NOT IN, LIMIT 1 (the caller only needs existence, not the rows).
         *
         * SYSTEM_MODE (API 67) bypasses FLS; the enclosing `without sharing` bypasses
         * record sharing — together reproducing the original all-fields/all-records
         * guest read.
         *
         * @param propertyAddress The address to match against Property_Address__c
         *                        (trimmed before binding); null/blank returns empty.
         * @param excludedStatuses Statuses that do NOT count as duplicates (e.g.
         *                        Converted / Disqualified); null is treated as no
         *                        exclusions.
         * @return At most one open Lead (Id) at that address; an empty list when the
         *         input is blank or no open duplicate exists (never null). The caller
         *         treats a non-empty result as "duplicate".
         * @example
         * Boolean isDup = !new LeadSelector.GuestReads()
         *     .selectOpenDuplicatesByAddressSystem(address, CLOSED_STATUSES).isEmpty();
         */
        public List<Lead> selectOpenDuplicatesByAddressSystem(String propertyAddress, Set<String> excludedStatuses) {
            if (String.isBlank(propertyAddress)) {
                return new List<Lead>();
            }
            String trimmedAddress = propertyAddress.trim();
            Set<String> closedStatuses = (excludedStatuses == null) ? new Set<String>() : excludedStatuses;
            return [
                SELECT Id
                FROM Lead
                WHERE Property_Address__c = :trimmedAddress AND Status NOT IN :closedStatuses
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        }
    }
}
