/**
 * Selector for Lease_Inquiry__c — encapsulates ALL SOQL against Lease_Inquiry__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave F1. Relocates the six Lease_Inquiry__c queries out of
 * LeaseInquiryController (Lease Activity Tracker). Mirrors the WireSelector pilot
 * and the LeaseRenewalSelector template.
 *
 * MODE: USER_MODE (custom object, FLS gap 0 — P3). Every method uses static SOQL with
 * `WITH USER_MODE` — the same static shape the relocated inline controller queries had
 * (and the WireSelector pilot uses). No dynamic SOQL / Database.query, so there is no
 * injection surface. selectActiveStagesCreatedSince binds its Datetime cutoff.
 *
 * NOT-FOUND CONTRACT:
 *   - selectRequiredById / selectStageStatusById use a single-row SOQL assignment
 *     (a miss throws System.QueryException), preserving the record-page / update-path
 *     behaviour of LeaseInquiryController.getLog and .addUpdate and mirroring the
 *     WireSelector.selectRequiredById precedent.
 *   - the list methods return an empty list when nothing matches.
 *
 * ORDER BY note: no method orders by the Stage__c picklist, so definition-vs-
 * alphabetical picklist ordering is not in play here; ordering is by datetime/date
 * fields only (LastModifiedDate, Stage_Start_Date__c).
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (pilot template)
 * @see force-app/main/default/classes/LeaseRenewalSelector.cls (template)
 */
public with sharing class LeaseInquirySelector {

    /**
     * One inquiry by Id for the negotiation-log header (Stage / Status / Ball in
     * Court). Backs LeaseInquiryController.getLog. Single-row assignment: a missing
     * Id throws System.QueryException.
     *
     * @param inquiryId Lease_Inquiry__c Id (record-page context).
     * @return The Lease_Inquiry__c with Id, Stage__c, Status__c and Ball_In_Court__c.
     * @throws System.QueryException when no Lease_Inquiry__c matches the Id.
     */
    public static Lease_Inquiry__c selectRequiredById(Id inquiryId) {
        return [
            SELECT Id, Stage__c, Status__c, Ball_In_Court__c
            FROM Lease_Inquiry__c
            WHERE Id = :inquiryId
            WITH USER_MODE
        ];
    }

    /**
     * One inquiry by Id with just the fields the stage-advance decision needs
     * (Stage / Status). Backs LeaseInquiryController.addUpdate. Deliberately does
     * NOT select Ball_In_Court__c: addUpdate can run for a user who never loads the
     * log, and querying an extra field under USER_MODE would widen its FLS surface
     * and could change behaviour for that user. Single-row assignment: a missing Id
     * throws System.QueryException.
     *
     * @param inquiryId Lease_Inquiry__c Id.
     * @return The Lease_Inquiry__c with Id, Stage__c and Status__c.
     * @throws System.QueryException when no Lease_Inquiry__c matches the Id.
     */
    public static Lease_Inquiry__c selectStageStatusById(Id inquiryId) {
        return [
            SELECT Id, Stage__c, Status__c
            FROM Lease_Inquiry__c
            WHERE Id = :inquiryId
            WITH USER_MODE
        ];
    }

    /**
     * Every inquiry with the fields getHomeKpis aggregates in Apex. Backs
     * LeaseInquiryController.getHomeKpis.
     *
     * @return All Lease_Inquiry__c with Status__c, Ball_In_Court__c,
     *         Stage_Start_Date__c and Signed_Date__c populated; empty list when none.
     */
    public static List<Lease_Inquiry__c> selectForKpis() {
        return [
            SELECT Status__c, Ball_In_Court__c, Stage_Start_Date__c, Signed_Date__c
            FROM Lease_Inquiry__c
            WITH USER_MODE
        ];
    }

    /**
     * The six most-recently-modified inquiries for the home widget. Backs
     * LeaseInquiryController.getRecentInquiries.
     *
     * @return Up to 6 Lease_Inquiry__c ordered by LastModifiedDate DESC (LIMIT 6);
     *         empty list when none.
     */
    public static List<Lease_Inquiry__c> selectRecent() {
        return [
            SELECT Id, Tenant_Name__c, Property_Name__c, Broker_Name__c, Stage__c,
                   Ball_In_Court__c, Status__c, Stage_Start_Date__c, CreatedDate
            FROM Lease_Inquiry__c
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 6
        ];
    }

    /**
     * Stage values for active inquiries created on or after the given cutoff — backs
     * getPipelineByStage's per-stage bucketing. The caller owns the business rule
     * (the "last 5 years" window) and passes the resolved cutoff as a bound variable.
     *
     * @param createdSince Lower bound (inclusive) on CreatedDate.
     * @return Stage__c-only Lease_Inquiry__c rows where Status__c = 'Active' and
     *         CreatedDate >= createdSince; empty list when none.
     */
    public static List<Lease_Inquiry__c> selectActiveStagesCreatedSince(Datetime createdSince) {
        return [
            SELECT Stage__c
            FROM Lease_Inquiry__c
            WHERE Status__c = 'Active' AND CreatedDate >= :createdSince
            WITH USER_MODE
        ];
    }

    /**
     * All active inquiries, oldest-in-stage first — the candidate set getAttention
     * filters down (Landlord ball / aging) and caps in Apex. Backs
     * LeaseInquiryController.getAttention.
     *
     * @return Active Lease_Inquiry__c ordered by Stage_Start_Date__c ASC NULLS LAST;
     *         empty list when none.
     */
    public static List<Lease_Inquiry__c> selectActive() {
        return [
            SELECT Id, Tenant_Name__c, Property_Name__c, Broker_Name__c, Stage__c,
                   Ball_In_Court__c, Status__c, Stage_Start_Date__c, CreatedDate
            FROM Lease_Inquiry__c
            WHERE Status__c = 'Active'
            WITH USER_MODE
            ORDER BY Stage_Start_Date__c ASC NULLS LAST
        ];
    }
}
