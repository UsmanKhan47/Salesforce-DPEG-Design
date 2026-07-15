/**
 * Selector class for {SObject} queries.
 *              Encapsulates all SOQL for {SObject} records.
 *              All methods return bulkified results (Lists or Maps).
 */
public inherited sharing class {SObject}Selector {

    // ─── Field Lists ─────────────────────────────────────────────────────

    /**
     * Returns the default set of fields to query for {SObject}.
     *              Centralizes field references to keep queries DRY.
     * @return Comma-separated field list as a String
     */
    private static String getDefaultFields() {
        return String.join(
            new List<String>{
                'Id',
                'Name',
                'CreatedDate',
                'LastModifiedDate'
                // TODO: Add additional fields here
            },
            ', '
        );
    }

    // ─── Query Methods ───────────────────────────────────────────────────

    /**
     * Selects {SObject} records by their Ids
     * @param recordIds Set of {SObject} Ids to query
     * @return List of {SObject} records matching the provided Ids
     * @example
     * Set<Id> ids = new Set<Id>{ '001xx000003DGbY' };
     * List<{SObject}> results = {SObject}Selector.selectByIds(ids);
     */
    public static List<{SObject}> selectByIds(Set<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty()) {
            return new List<{SObject}>();
        }

        return Database.query(
            'SELECT ' + getDefaultFields() +
            ' FROM {SObject}' +
            ' WHERE Id IN :recordIds'
        );
    }

    /**
     * Selects {SObject} records as a Map keyed by Id
     * @param recordIds Set of {SObject} Ids to query
     * @return Map of Id to {SObject}
     */
    public static Map<Id, {SObject}> selectMapByIds(Set<Id> recordIds) {
        return new Map<Id, {SObject}>(selectByIds(recordIds));
    }

    /**
     * Selects {SObject} records by a specific field value
     * @param fieldName API name of the field to filter on
     * @param values Set of values to match
     * @return List of matching {SObject} records
     * @example
     * List<{SObject}> results = {SObject}Selector.selectByField('Status__c', new Set<String>{ 'Active' });
     */
    public static List<{SObject}> selectByField(String fieldName, Set<String> values) {
        if (String.isBlank(fieldName) || values == null || values.isEmpty()) {
            return new List<{SObject}>();
        }

        // Validate field name to prevent SOQL injection
        Schema.SObjectField field = Schema.SObjectType.{SObject}.fields.getMap().get(fieldName);
        if (field == null) {
            throw new QueryException('Invalid field name: ' + fieldName);
        }

        return Database.query(
            'SELECT ' + getDefaultFields() +
            ' FROM {SObject}' +
            ' WHERE ' + String.escapeSingleQuotes(fieldName) + ' IN :values WITH USER_MODE'
        );
    }

    /**
     * @description Selects records by IDs with related records
     * @param ids Set of record IDs
     * @return List of {{ObjectName}} records with child records
     */
    public List<{{ObjectName}}> selectByIdWithRelated(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) {
            return new List<{{ObjectName}}>();
        }

        return [
            SELECT Id, Name, CreatedDate, LastModifiedDate,
                (SELECT Id, Name FROM {{ChildRelationship}})
            FROM {{ObjectName}}
            WHERE Id IN :ids
            WITH USER_MODE
        ];
    }

    /**
     * @description Selects records by Name
     * @param name Name to search for (supports wildcards)
     * @return List of matching {{ObjectName}} records
     */
    public List<{{ObjectName}}> selectByName(String name) {
        if (String.isBlank(name)) {
            return new List<{{ObjectName}}>();
        }

        String searchName = '%' + String.escapeSingleQuotes(name) + '%';
        return [
            SELECT Id, Name, CreatedDate, LastModifiedDate
            FROM {{ObjectName}}
            WHERE Name LIKE :searchName
            WITH USER_MODE
            LIMIT 100
        ];
    }

      /**
     * @description Selects records created in date range
     * @param startDate Start date
     * @param endDate End date
     * @return List of {{ObjectName}} records in date range
     */
    public List<{{ObjectName}}> selectByCreatedDateRange(Date startDate, Date endDate) {
        return [
            SELECT Id, Name, CreatedDate, LastModifiedDate
            FROM {{ObjectName}}
            WHERE CreatedDate >= :startDate
            AND CreatedDate <= :endDate
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * @description Counts records matching criteria
     * @return Count of matching records
     */
    public Integer countAll() {
        return [SELECT COUNT() FROM {{ObjectName}} WITH USER_MODE];
    }

    // ─── Exception ───────────────────────────────────────────────────────

    /**
     * Custom exception for query errors
     */
    public class QueryException extends Exception {}
}
