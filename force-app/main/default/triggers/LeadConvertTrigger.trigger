/**
 * Fires after a Lead is updated. When the update is a lead conversion that
 * produced an Opportunity, hand off to LeadConvertService to stamp the deal
 * type and the matching record type on that Opportunity.
 */
trigger LeadConvertTrigger on Lead (after update) {
    new LeadConvertTriggerHandler().run();
}