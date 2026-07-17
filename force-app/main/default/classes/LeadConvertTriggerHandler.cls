/**
 * Trigger handler for Lead. Routes the after-update context to
 * LeadConvertService: when the update is a lead conversion that produced an
 * Opportunity, stamp the deal type, matching record type, converting user, and
 * create/link the Property on that Opportunity.
 *
 * All business logic lives in LeadConvertService; this handler only wires the
 * trigger context to that service.
 */
public with sharing class LeadConvertTriggerHandler extends TriggerHandler {

    protected override void afterUpdate() {
        LeadConvertService.stampConvertedOpportunities(
            (List<Lead>) newList,
            (Map<Id, Lead>) oldMap
        );
    }
}
