/**
 * Backs the per-stage "advance" quick actions on the Opportunity. Each button is
 * shown only on its source stage via Dynamic Actions on the Highlights Panel.
 *
 *   advance(recordId)          - moves the deal to the single "primary" next
 *                                stage for its current stage (Begin Review,
 *                                Initiate Underwriting, Advance to PSA, Close
 *                                Deal), or, from Underwriting, submits it into
 *                                the principal LOI approval (Initiate LOI).
 *   advanceTo(recordId, stage) - moves the deal to an explicit target stage,
 *                                used for the branch actions off Under Review
 *                                (Send to Development / Construction Review).
 *
 * Gates preserved: Under Review -> Underwriting hits the signed-NDA validation
 * rule (its message is surfaced); Underwriting -> LOI goes through the approval
 * process rather than a direct write.
 */
public with sharing class StageAdvanceController {

    // Current stage -> the single primary next stage. Underwriting is absent
    // because that step is an approval submission, not a stage write.
    private static final Map<String, String> NEXT_STAGE = new Map<String, String>{
        'New' => 'Under Review',
        'Under Review' => 'Underwriting',
        'Development Review' => 'Underwriting',
        'Construction Review' => 'Underwriting',
        'LOI' => 'PSA',
        'PSA' => 'Closed Won',
        'About to Close' => 'Closed Won'
    };

    @AuraEnabled
    public static String advance(Id recordId) {
        Opportunity o = load(recordId);
        if (o.StageName == 'Underwriting') {
            // Gated by principal approval - submit into the approval process.
            return OpportunityApprovalController.submitForApproval(recordId);
        }
        String target = NEXT_STAGE.get(o.StageName);
        if (target == null) {
            throw ahe('There is no next step available from the ' + o.StageName + ' stage.');
        }
        return setStage(o, target);
    }

    @AuraEnabled
    public static String advanceTo(Id recordId, String target) {
        if (String.isBlank(target)) {
            throw ahe('No target stage was provided.');
        }
        return setStage(load(recordId), target);
    }

    private static Opportunity load(Id recordId) {
        if (recordId == null) {
            throw ahe('No record was provided.');
        }
        return [SELECT Id, StageName FROM Opportunity WHERE Id = :recordId LIMIT 1];
    }

    private static String setStage(Opportunity o, String target) {
        try {
            o.StageName = target;
            update o;
            return 'Deal moved to ' + target + '.';
        } catch (DmlException e) {
            // e.g. the signed-NDA gate, or a stage not valid for the deal's record type.
            throw ahe(e.getDmlMessage(0));
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}