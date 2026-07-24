/**
 * Selector for Property_Claim_Lock__c. Encapsulates ALL SOQL against
 * Property_Claim_Lock__c per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * Broker Protection module — concurrency control (W4). Property_Claim_Lock__c is a pure
 * lock-partition object: one row per COARSE address cluster (Cluster_Key__c is the unique
 * bucket key). PropertyClaimService acquires a pessimistic FOR UPDATE row lock on the
 * cluster's row at the top of claim(), which serialises every concurrent same-cluster
 * claim so the downstream fuzzy match-then-insert is atomic (no dual winners). This
 * selector owns the two reads that support that: a plain existence read (for the
 * idempotent get-or-create) and the FOR UPDATE lock-acquisition read.
 *
 * MODE — both queries use `WITH USER_MODE` (API 67). Property_Claim_Lock__c is a custom
 * object; USER_MODE enforces the running user's sharing + object read. Cluster_Key__c is a
 * `required` field, so its read FLS is implicitly granted (the field cannot be hidden),
 * exactly like Property_Registry__c.Property_Key__c — which is why neither needs an explicit
 * fieldPermissions stub in Broker_Protection_Access. The backend claim engine runs under the
 * Email Service user, so that permission set must grant OBJECT read on Property_Claim_Lock__c
 * (added alongside this change) or the USER_MODE reads below would throw. FOR UPDATE combined
 * with WITH USER_MODE is legal (unlike WITH SECURITY_ENFORCED, which forbids FOR UPDATE).
 *
 * SIGNATURE CONTRACT — both public methods are STATIC, matching the repo selector norm
 * (PropertyRegistrySelector, CompetingBrokerSubmissionSelector, LeadSelector all expose
 * `public static` query methods). PropertyClaimService binds to them by name; do not rename
 * or change their parameter/return types.
 *
 * NOT-FOUND CONTRACT — both methods return their natural empty List, never null: a cluster
 * that has never been claimed simply has no lock row yet.
 *
 * @see PropertyClaimService.cls (acquires the lock at the top of claim())
 * @see PropertyRegistrySelector.cls (sibling Broker-Protection selector)
 */
public with sharing class PropertyClaimLockSelector {

    /**
     * The lock row for one cluster key, WITHOUT a lock — backs the idempotent
     * get-or-create existence check (read first, insert only when absent). LIMIT 1
     * because Cluster_Key__c is unique.
     *
     * @param clusterKey The coarse cluster partition key; null/blank returns an empty list.
     * @return At most one Property_Claim_Lock__c row for that key; empty when `clusterKey`
     *         is null/blank or the cluster has no lock row yet.
     * @example
     * Boolean exists = !PropertyClaimLockSelector.selectByClusterKey(key).isEmpty();
     */
    public static List<Property_Claim_Lock__c> selectByClusterKey(String clusterKey) {
        if (String.isBlank(clusterKey)) {
            return new List<Property_Claim_Lock__c>();
        }
        return [
            SELECT Id
            FROM Property_Claim_Lock__c
            WHERE Cluster_Key__c = :clusterKey
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * The lock row for one cluster key, WITH a pessimistic FOR UPDATE row lock — this is the
     * serialization primitive. Acquiring the lock BLOCKS any concurrent transaction that
     * tries to lock the same cluster row until this transaction commits (or ~10s elapse, at
     * which point Apex throws a QueryException / UNABLE_TO_LOCK_ROW that the caller handles).
     * LIMIT 1 because Cluster_Key__c is unique; no ORDER BY (illegal with FOR UPDATE).
     *
     * @param clusterKey The coarse cluster partition key; null/blank returns an empty list.
     * @return At most one locked Property_Claim_Lock__c row for that key; empty when
     *         `clusterKey` is null/blank or the cluster has no lock row yet.
     * @throws System.QueryException on a FOR UPDATE lock-wait timeout (UNABLE_TO_LOCK_ROW).
     * @example
     * Boolean held = !PropertyClaimLockSelector.selectByClusterKeyForUpdate(key).isEmpty();
     */
    public static List<Property_Claim_Lock__c> selectByClusterKeyForUpdate(String clusterKey) {
        if (String.isBlank(clusterKey)) {
            return new List<Property_Claim_Lock__c>();
        }
        return [
            SELECT Id
            FROM Property_Claim_Lock__c
            WHERE Cluster_Key__c = :clusterKey
            WITH USER_MODE
            LIMIT 1
            FOR UPDATE
        ];
    }
}
