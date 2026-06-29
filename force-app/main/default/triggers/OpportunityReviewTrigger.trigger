/**
 * Fires after an Opportunity is inserted or updated. When the Opp enters the
 * Development Review or Construction Review stage, hand off to
 * OpportunityReviewService to create the matching feasibility-review child record.
 */
trigger OpportunityReviewTrigger on Opportunity (after insert, after update) {
    OpportunityReviewService.createReviewRecords(
        Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null
    );
}