/**
 * THE SHARED THREAD-ANCHOR INDEX for the two EAC capture features (added 2026-08-02).
 *
 * Both halves of the EAC capture pipeline ask the same question of the same data —
 * "which Broker Protection thread anchors match these captured emails, and on which
 * records do they sit?" — and then act on the answer with OPPOSITE polarity:
 *
 *   • EmailThreadAdopterService  ASSOCIATES an anchored capture onto the deal record.
 *   • EmailThreadGuardService    DELETES a capture that is anchored NOWHERE it lives.
 *
 * This class performs that read ONCE per queueable execution and normalizes identifiers
 * ONCE, so the two features cannot disagree. That is the entire reason it exists.
 *
 * ═══ 🔴 WHY THE NORMALIZATION LIVES HERE AND NOWHERE ELSE (defect P4) ═══
 * The pipeline writes its two anchors in DIFFERENT bracket forms, and this was a live
 * defect in the deployed guard before this change:
 *
 *   • `Task.Thread_Key__c`        — written through PropertyMatchingService.computeThreadKey,
 *                                   whose every return path passes through stripAngleBrackets
 *                                   → **UNBRACKETED**.
 *   • `Task.Inbound_Message_Id__c` — written from the RAW `Message-ID` header
 *                                   → **BRACKETED**.
 *   • EAC's `ThreadIdentifier` / `MessageIdentifier` → **BRACKETED**.
 *
 * MEASURED IN `usman-dpeg` 2026-08-02 (experiment E3), both live anchor rows:
 *   Thread_Key__c:         PH0P222MB0047…OUTLOOK.COM
 *   Inbound_Message_Id__c: &lt;PH0P222MB0047…OUTLOOK.COM&gt;
 *
 * Consequence: `ThreadIdentifier ↔ Thread_Key__c` could NEVER match, so the deployed
 * guard was running on its MessageIdentifier leg alone — a reply whose thread root was
 * logged as a mid-thread Task was being deleted as unanchored. Normalizing every value
 * through `normalize(...)` on BOTH sides closes that leg.
 *
 * ⚠ DO NOT re-implement bracket handling in the guard, the adopter, or a selector.
 * `EmailThreadAnchorServiceTest.bracketAsymmetryIsClosedByNormalization` pins this, and
 * the whole point of the shared index is that the two features normalize IDENTICALLY BY
 * CONSTRUCTION rather than by convention.
 *
 * ═══ 🔴 THE OPPORTUNITY RESOLUTION CHAIN — AND WHY IT HAS TWO STEPS, NOT THREE ═══
 * The design (D2) specified three steps: (1) anchor `WhatId` is an Opportunity, (2) anchor
 * `WhoId` is a Lead → resolve through conversion, (3) otherwise fail closed.
 *
 * **EXPERIMENT E1 RETIRED STEP 2.** Measured in a scratch org via `Database.convertLead`:
 *
 *   anchorTask.WhoId  AFTER = the CONTACT      (WHO_STILL_LEAD=false)
 *   anchorTask.WhatId AFTER = the OPPORTUNITY  (WHAT_IS_OPP=true)
 *
 * Standard conversion performs the anchor carry-forward ITSELF: it repoints `WhoId` to the
 * Contact **and** stamps `WhatId` with the converted Opportunity, on the pre-existing
 * anchor Task. So step 1 already covers every converted deal, and step 2 could only ever
 * fire for an UNCONVERTED Lead — which by definition has no Opportunity to adopt onto and
 * must fail closed anyway. Step 2 is unreachable, so it is not implemented.
 *
 * That also keeps the query budget CONSTANT: calling
 * `PropertyMatchingService.resolveLiveRecord(...)` per anchor would be SOQL-in-a-loop
 * (it reads `LeadSelector.selectConversionById` per Id), which
 * `.claude/rules/apex-layering-rule.md` forbids outright. The single-Id resolver remains
 * correct for the inbound pipeline's per-property use; it is deliberately NOT called here.
 *
 * **Fail closed on Contacts (step 3) is retained and is load-bearing.** After conversion
 * every anchor's `WhoId` IS a Contact, and one Contact can front many deals — resolving
 * through it would manufacture exactly the wrong-deal lie the guard exists to delete.
 *
 * ═══ MULTI-ANCHOR TIE-BREAK ═══
 * One Message-ID can carry N anchor Tasks across N records (multi-property routing —
 * `InboundEmailActivityService.logInboundEmail(List&lt;Id&gt;…)`), but `RelatedToId` holds ONE
 * Id. The selector orders `CreatedDate DESC, Id DESC` and this class takes FIRST-WINS,
 * reusing the pipeline's own rule (`TaskSelector.selectLatestByThreadOrMessageIds`): the
 * epilogue inserts Tasks in ASCENDING priority, so the deal DPEG actually owns carries the
 * highest Id and therefore wins here.
 *
 * ═══ LAYER / MODE ═══
 * Service, read-only — NO DML, ever. All SOQL delegates to `TaskSelector`. `with sharing`
 * per ARCHITECTURE.md §2; the underlying anchor read is `WITH SYSTEM_MODE` for the
 * automation-path reason recorded on that selector method.
 *
 * @see EmailThreadGuardService.cls / EmailThreadAdopterService.cls (the two consumers)
 * @see TaskSelector.selectThreadAnchorsByAnchorValues (the single anchor read)
 * @see agent-output/design-requirements-eac-adopter.md (D2, D3, P3, P4)
 */
public with sharing class EmailThreadAnchorService {

    /**
     * The one-per-execution answer to "what is anchored where, and which Opportunity does
     * each anchor value resolve to?". Built by `index(...)`, consumed with opposite
     * polarity by the adopter and the guard.
     */
    public class AnchorIndex {

        /** Normalized anchor values present on each record (`Task.WhoId` ∪ `Task.WhatId`). */
        private Map<Id, Set<String>> anchorsByRecordId = new Map<Id, Set<String>>();

        /** Normalized anchor value → the Opportunity it resolves to (first-wins by priority). */
        private Map<String, Id> opportunityByAnchorValue = new Map<String, Id>();

        /**
         * Is this capture anchored on that specific record? Both of the capture's
         * identifiers are tested, already normalized.
         *
         * @param recordId The record to test (a related Lead, or the RelatedToId record).
         * @param message  The capture under examination.
         * @return true when the record carries a matching anchor.
         */
        public Boolean isAnchoredOn(Id recordId, EmailMessage message) {
            if (recordId == null || message == null) {
                return false;
            }
            Set<String> anchors = anchorsByRecordId.get(recordId);
            if (anchors == null) {
                return false;
            }
            return anchors.contains(normalize(message.ThreadIdentifier))
                || anchors.contains(normalize(message.MessageIdentifier));
        }

        /**
         * The Opportunity this capture's thread resolves to, or null when the chain fails
         * closed (no anchor, or the anchor sits only on a Contact / unconverted Lead).
         *
         * ⚠ MessageIdentifier is consulted BEFORE ThreadIdentifier, and the order is the
         * whole content of this method (corrected at review, finding W1). EXACT IDENTITY
         * BEATS CONVERSATION-LEVEL IDENTITY: `MessageIdentifier` says "the pipeline filed
         * THIS SPECIFIC EMAIL there", while `ThreadIdentifier` only says "something in this
         * conversation was filed there".
         *
         * The two diverge in a shape D1 multi-property extraction makes routine: ONE
         * inbound email produces N anchor Tasks sharing ONE `Thread_Key__c` but carrying
         * DIFFERENT `Inbound_Message_Id__c` values, and after conversion those N anchors sit
         * on N DIFFERENT Opportunities. The index then holds root R → Opp₁ (first-wins) and
         * message M₂ → Opp₂. A capture carrying (R, M₂) IS the email filed on deal 2, so
         * thread-first would adopt it onto deal 1. The harm is bounded — always a SIBLING
         * deal from the same email, never an unrelated one — but the specific signal is
         * available and must win.
         *
         * The ThreadIdentifier FALLBACK is still load-bearing and is why this is an OR
         * rather than a single lookup: a reply's own Message-ID anchors nothing until the
         * pipeline has logged that reply, so for most captures the conversation root is the
         * only key that resolves at all.
         *
         * @param message The capture under examination.
         * @return The resolved Opportunity Id, or null to adopt nothing.
         */
        public Id resolveOpportunity(EmailMessage message) {
            if (message == null) {
                return null;
            }
            Id viaMessage = opportunityByAnchorValue.get(normalize(message.MessageIdentifier));
            return (viaMessage != null)
                ? viaMessage
                : opportunityByAnchorValue.get(normalize(message.ThreadIdentifier));
        }

        /** @return true when no anchor matched anything — both consumers can exit early. */
        public Boolean isEmpty() {
            return anchorsByRecordId.isEmpty() && opportunityByAnchorValue.isEmpty();
        }
    }

    /**
     * THE ONLY bracket handling in either feature. Strips the RFC angle brackets and trims,
     * so a value written by the pipeline in either form compares equal to EAC's raw header.
     *
     * @param identifier A raw RFC identifier or a stored anchor value; null/blank safe.
     * @return The normalized value, or null when there is nothing to compare.
     */
    public static String normalize(String identifier) {
        if (String.isBlank(identifier)) {
            return null;
        }
        String trimmed = identifier.trim();
        if (trimmed.startsWith('<')) {
            trimmed = trimmed.substring(1);
        }
        if (trimmed.endsWith('>')) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        trimmed = trimmed.trim();
        return String.isBlank(trimmed) ? null : trimmed;
    }

    /**
     * THE QUEUEABLE'S ENTRY POINT (added with the adopter, 2026-08-02): build the shared
     * index from message Ids alone, so `EmailCaptureQueueable` can build it ONCE and hand
     * the same instance to both consumers without holding any SOQL of its own.
     *
     * That containment is the reason this overload exists rather than the queueable
     * calling `EmailMessageSelector` directly: `.claude/rules/apex-layering-rule.md` puts
     * SOQL in selectors and orchestration in services, and a queueable is neither.
     *
     * @param messageIds The captured emails under examination; null/empty-safe.
     * @return The index; never null. `isEmpty()` is true when nothing matched.
     * @example
     * EmailThreadAnchorService.AnchorIndex anchors =
     *     EmailThreadAnchorService.index(messageIds);
     */
    public static AnchorIndex index(Set<Id> messageIds) {
        if (messageIds == null || messageIds.isEmpty()) {
            return new AnchorIndex();
        }
        return index(EmailMessageSelector.selectByIds(messageIds));
    }

    /**
     * Build the shared index for one batch of captures: ONE anchor query, ONE
     * normalization pass, no DML.
     *
     * @param messages The captured emails under examination; null/empty-safe.
     * @return The index; never null. `isEmpty()` is true when nothing matched.
     * @example
     * EmailThreadAnchorService.AnchorIndex anchors =
     *     EmailThreadAnchorService.index(messages);
     */
    public static AnchorIndex index(List<EmailMessage> messages) {
        AnchorIndex result = new AnchorIndex();
        if (messages == null || messages.isEmpty()) {
            return result;
        }

        Set<String> candidates = candidateAnchorValues(messages);
        if (candidates.isEmpty()) {
            return result;
        }

        // Ordered CreatedDate DESC, Id DESC by the selector — first-wins IS the tie-break.
        for (Task anchor : TaskSelector.selectThreadAnchorsByAnchorValues(candidates)) {
            Set<String> anchorValues = new Set<String>();
            String threadKey = normalize(anchor.Thread_Key__c);
            String messageId = normalize(anchor.Inbound_Message_Id__c);
            if (threadKey != null) {
                anchorValues.add(threadKey);
            }
            if (messageId != null) {
                anchorValues.add(messageId);
            }
            if (anchorValues.isEmpty()) {
                continue;
            }

            recordAnchors(result, anchor.WhoId, anchorValues);
            recordAnchors(result, anchor.WhatId, anchorValues);

            Id resolvedOpportunity = resolveOpportunityFor(anchor);
            if (resolvedOpportunity == null) {
                continue;
            }
            for (String value : anchorValues) {
                if (!result.opportunityByAnchorValue.containsKey(value)) {
                    result.opportunityByAnchorValue.put(value, resolvedOpportunity);
                }
            }
        }
        return result;
    }

    /**
     * The normalized identifiers the captures actually carry — what makes the anchor query
     * selective regardless of how much history the org holds.
     *
     * @param messages The captures under examination.
     * @return Distinct normalized identifiers; empty when none carry one.
     */
    private static Set<String> candidateAnchorValues(List<EmailMessage> messages) {
        Set<String> candidates = new Set<String>();
        for (EmailMessage message : messages) {
            String threadId = normalize(message.ThreadIdentifier);
            String messageId = normalize(message.MessageIdentifier);
            if (threadId != null) {
                candidates.add(threadId);
            }
            if (messageId != null) {
                candidates.add(messageId);
            }
        }
        return candidates;
    }

    /**
     * Records that `recordId` carries these anchor values. Null record Ids are skipped —
     * an anchor Task may legitimately have only one of WhoId / WhatId set.
     *
     * @param index        The index under construction.
     * @param recordId     The record the anchor sits on.
     * @param anchorValues The normalized values it carries.
     */
    private static void recordAnchors(AnchorIndex index, Id recordId, Set<String> anchorValues) {
        if (recordId == null) {
            return;
        }
        if (!index.anchorsByRecordId.containsKey(recordId)) {
            index.anchorsByRecordId.put(recordId, new Set<String>());
        }
        index.anchorsByRecordId.get(recordId).addAll(anchorValues);
    }

    /**
     * The D2 resolution chain, reduced to its two reachable branches by experiment E1
     * (see the class header): the anchor `WhatId` is an Opportunity, or nothing.
     *
     * ⚠ FAIL CLOSED IS THE POINT. `WhoId` is a Contact on every converted anchor, and a
     * Contact can front many deals — resolving through it would adopt onto the wrong
     * Opportunity, which is strictly worse than adopting onto none.
     *
     * @param anchor The anchor Task.
     * @return The Opportunity Id, or null to adopt nothing.
     */
    private static Id resolveOpportunityFor(Task anchor) {
        if (anchor.WhatId == null) {
            return null;
        }
        return (anchor.WhatId.getSObjectType() == Opportunity.SObjectType) ? anchor.WhatId : null;
    }
}
