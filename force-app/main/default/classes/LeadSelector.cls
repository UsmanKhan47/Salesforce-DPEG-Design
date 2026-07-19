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
 * Guidance_Price__c, Broker_First__c, Property_Address__c, Asset_Type__c,
 * First_Seen_Date__c, Broker_Priority__c) are granted by the deployed Acquisition
 * permission sets (P3 custom-field FLS gap = 0).
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
     * @param maxRows Row cap (LIMIT); null / non-positive returns an empty list.
     * @return Open (non-converted) Leads with the funnel display + partition fields
     *         populated (Id, Name, Status, LeadSource, Parse_Confidence__c,
     *         Guidance_Price__c, Broker_First__c, Property_Address__c, Asset_Type__c,
     *         First_Seen_Date__c, CreatedDate, Broker_Priority__c) ordered
     *         First_Seen_Date__c DESC NULLS LAST, CreatedDate DESC; empty when there
     *         are no open Leads.
     */
    public static List<Lead> selectRecent(Integer maxRows) {
        if (maxRows == null || maxRows <= 0) {
            return new List<Lead>();
        }
        return [
            SELECT Id, Name, Status, LeadSource, Parse_Confidence__c, Guidance_Price__c,
                   Broker_First__c, Property_Address__c, Asset_Type__c,
                   First_Seen_Date__c, CreatedDate, Broker_Priority__c
            FROM Lead
            WHERE IsConverted = false
            WITH USER_MODE
            ORDER BY First_Seen_Date__c DESC NULLS LAST, CreatedDate DESC
            LIMIT :maxRows
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
