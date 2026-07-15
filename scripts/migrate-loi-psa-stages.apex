// One-time migration: collapse the granular LOI/PSA Opportunity stages into the
// two coarse stages 'LOI' and 'PSA'. Idempotent — re-running finds nothing to move.
Map<String, String> remap = new Map<String, String>{
    'Initiate LOI'       => 'LOI',
    'LOI Under Approval' => 'LOI',
    'LOI Submitted'      => 'LOI',
    'LOI Signed'         => 'LOI',
    'PSA Negotiation'    => 'PSA',
    'PSA Executed'       => 'PSA',
    'Under Contract'     => 'PSA'
};
List<Opportunity> toMove = [
    SELECT Id, StageName FROM Opportunity WHERE StageName IN :remap.keySet()
];
for (Opportunity o : toMove) {
    o.StageName = remap.get(o.StageName);
}
if (!toMove.isEmpty()) {
    update toMove;
}
System.debug('Migrated ' + toMove.size() + ' opportunities to LOI/PSA');
