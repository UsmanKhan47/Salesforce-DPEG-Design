/**
 * Selector for PSA_Version__c. Encapsulates ALL SOQL against PSA_Version__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 Module A2 (Acquisitions — Deal Support). Consumer: PsaVersionController
 * (the psaVersionLog LWC — full PSA draft/counter history + prior-count for the
 * Ball_In_Court__c / Negotiation_Status__c derivation on save).
 *
 * ⚠ MIXED MODES SINCE 2026-08-09 (Tranche 3C) — READ THE METHOD, NEVER THIS HEADER.
 * selectByContractReviewId stays `WITH USER_MODE`; countByContractReviewId is
 * `WITH SYSTEM_MODE` under the ARCHITECTURE.md §2 automation-path exception. Its
 * full justification lives at its own declaration, which is where §2 says the
 * authoritative inventory lives. The paragraph this replaced said "There is no
 * guest path for PSA versions — no SYSTEM_MODE here", which was true about GUEST
 * paths and wrong as a conclusion: the exception is about reads the running user
 * never asked for, not about anonymous ones.
 *
 * 🔴 AND THE OLD HEADER'S SECOND CLAIM WAS THE ACTIVE DANGER: "USER_MODE ... cannot
 * throw on the selected fields." That is a statement about FLS only. A COUNT() has
 * no fields to be denied — what USER_MODE does to it is FILTER ROWS by sharing, and
 * a filtered COUNT does not throw, it returns a SMALLER NUMBER. See below.
 *
 * NOT-FOUND CONTRACT — both callers treat "no versions" as a normal state, so the
 * list method returns an empty List and the count method returns 0 (never null).
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #7, §4, §5)
 */
public with sharing class PsaVersionSelector {

    /**
     * Full PSA version history for one Contract Review, newest first — backs
     * PsaVersionController.getVersions (the psaVersionLog timeline).
     *
     * ✅ `WITH USER_MODE`, DELIBERATELY, AND IT MUST STAY THAT WAY. This is the display read: every
     * row it returns is rendered to the user in the timeline, so it is a read the user explicitly
     * ASKED for and a denial is a real provisioning gap that should be visible. It was reviewed
     * alongside countByContractReviewId's 2026-08-09 move to SYSTEM_MODE and deliberately NOT
     * moved with it — the two differ in KIND, not in strictness, and "the sibling method is
     * SYSTEM_MODE" is not a reason to change this one. See the count method for the full test.
     *
     * @param contractReviewId Parent Contract_Review__c Id; null-safe.
     * @return PSA_Version__c rows ordered by CreatedDate DESC, Name DESC; empty
     *         when the input is null or the Contract Review has no versions.
     * @example
     * List<PSA_Version__c> versions = PsaVersionSelector.selectByContractReviewId(crId);
     */
    public static List<PSA_Version__c> selectByContractReviewId(Id contractReviewId) {
        if (contractReviewId == null) {
            return new List<PSA_Version__c>();
        }
        return [
            SELECT Id, Name, Direction__c, Version_Date__c, Summary__c, Document_URL__c, CreatedDate
            FROM PSA_Version__c
            WHERE Contract_Review__c = :contractReviewId
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Name DESC
        ];
    }

    /**
     * Count of existing PSA versions for a Contract Review — the input to
     * PsaVersionService's derived `Contract_Review__c.Latest_Version__c` stamp
     * (`priorCount + 1`).
     *
     * ⚠ The Javadoc that used to sit here also described a "priorCount == 0 && from-seller =>
     * Initial Draft" rule. That rule was REMOVED from PsaVersionService on 2026-08-05 when the two
     * counter statuses left the restricted picklist; the comment simply outlived it. The count now
     * feeds exactly ONE thing: the version NUMBER.
     *
     * ── 🔴 WITH SYSTEM_MODE, AND IT IS A DATA-CORRUPTION FIX — NOT A CONVENIENCE ──
     * Fixed 2026-08-09 (Tranche 3C). This query ran `WITH USER_MODE` and that was a live defect,
     * not a hardening opportunity, because of one asymmetry that makes a COUNT() categorically
     * different from every other query in this repo:
     *
     *   AN FLS DENIAL THROWS. A SHARING DENIAL FILTERS. A FILTERED COUNT IS STILL A NUMBER.
     *
     * Everywhere else in this codebase the USER_MODE failure mode is a loud
     * `System.QueryException` that a caller can catch, surface or fail closed on. Here the rows
     * are `PSA_Version__c` children on an OWD-Private object graph, so a user who cannot SEE the
     * earlier versions does not get an error — they get a smaller count. `PsaVersionService` then
     * writes `Latest_Version__c = priorCount + 1` STRAIGHT BACK ONTO THE PARENT, so a user who can
     * see none of the prior versions REWINDS a live negotiation's version counter to 1, silently,
     * on a record everyone else is reading. The next reviewer sees "Version 1" on a PSA that is on
     * its ninth redline, and nothing anywhere records that it happened.
     *
     * IT MEETS THE §2 AUTOMATION-PATH TEST ON ITS OWN MERITS, on three grounds:
     *
     *  1. THE USER DID NOT ASK FOR THIS DATA. They asked to LOG A VERSION. Nothing this query
     *     returns is displayed to anyone — it exists only so the service can DERIVE a field. §2's
     *     wording is exactly this case: "a read the running user never asked for must not depend
     *     on the running user's" access.
     *  2. IT COMPUTES A DERIVED FIELD, AND A DERIVED FIELD IS A PROPERTY OF THE RECORD, NOT OF THE
     *     READER. `Latest_Version__c` must mean the same thing to every user who reads the Contract
     *     Review. A per-reader answer is not a narrower answer, it is a WRONG one — and it is
     *     written back, so one reader's narrower view permanently overwrites everyone's.
     *  3. USER_MODE HERE DEGRADES INTO CORRUPTION RATHER THAN THROWING. That inverts the normal
     *     argument for USER_MODE. A user-initiated read that throws is telling you about a real
     *     provisioning gap and the fix is a permission set (§2 says so, and it is right). A count
     *     that silently under-reports tells you nothing and is unrecoverable — the old number is
     *     gone.
     *
     * ── 🔴 SHARING IS A SECOND, SEPARATE MECHANISM AND THIS CHANGE DOES NOT CLOSE IT ──
     * Stated plainly rather than left to be discovered, because the two mechanisms produce the
     * SAME symptom (a number that is too small) and it is easy to read this fix as covering both:
     *
     *   CRUD / FLS  ── enforced by USER_MODE, ignored by SYSTEM_MODE.  ✅ CLOSED BY THIS CHANGE.
     *   SHARING     ── governed by the CLASS's sharing keyword in BOTH modes.  ❌ NOT closed.
     *
     * `SYSTEM_MODE` lifts CRUD and FLS only; record visibility is decided by `with sharing` on
     * this class and is IDENTICAL before and after this edit. So a user who genuinely cannot SEE
     * a sibling version through sharing still counts it out, still writes `priorCount + 1`, and
     * still rewinds the counter. Two facts make that a live possibility rather than a theoretical
     * one, both MEASURED on disk 2026-08-09:
     *   - `PSA_Version__c` is `sharingModel Private` (and `externalSharingModel Private`);
     *   - `sharingRules/PSA_Version__c.sharingRules-meta.xml` is an EMPTY `<SharingRules/>` element
     *     — there is not one sharing rule on the object, so a persona without `viewAllRecords`
     *     sees only the rows they own.
     * Whether any given persona holds `viewAllRecords` is org state that is being edited in this
     * same window, so it is deliberately NOT quoted here as a mitigation.
     *
     * ⚠ THE REMEDY IS KNOWN AND IS DELIBERATELY NOT TAKEN IN THIS CHANGE. Closing the sharing half
     * means a narrow `private without sharing` inner class holding ONLY this one query — the
     * `InboundEmailStagingSelector.RoutingReads` / `LeadSelector.GuestReads` shape — never
     * `without sharing` on the whole selector, which would silently widen the DISPLAY read above
     * as well. That is a deliberate access decision with its own justification burden and it was
     * scoped out; this change fixes the half that is unambiguously a defect and names the half
     * that is a decision. Do not widen the class to reach it.
     *
     * ⚠ AND THE CRUD/FLS HALF IS NOT HYPOTHETICAL EITHER, for a reason this repo has been burned
     * by TWICE: a `PermissionSet` deploy REPLACES its entire `<objectPermissions>` /
     * `<fieldPermissions>` set, so one unrelated redeploy that happens to drop `PSA_Version__c`
     * would, under USER_MODE, break every Log Version save on BOTH sides of the house with a
     * generic "could not be saved" toast. Same ground 3 as
     * LoiSelector.selectNegotiationContextById.
     *
     * ⚠ CONTRAST selectByContractReviewId IMMEDIATELY ABOVE, WHICH MUST STAY USER_MODE. It backs
     * `PsaVersionController.getVersions` — a `cacheable=true` read whose entire output is RENDERED
     * to the user in the psaVersionLog timeline. That is a read the user asked for, it displays
     * what it returns, and a denial there is a real provisioning gap that should be visible.
     * The two methods differ in KIND, not in strictness.
     *
     * @param contractReviewId Parent Contract_Review__c Id; null-safe.
     * @return The number of PSA versions already logged (0 when the input is null
     *         or none exist).
     */
    public static Integer countByContractReviewId(Id contractReviewId) {
        if (contractReviewId == null) {
            return 0;
        }
        return [
            SELECT COUNT()
            FROM PSA_Version__c
            WHERE Contract_Review__c = :contractReviewId
            WITH SYSTEM_MODE
        ];
    }
}
