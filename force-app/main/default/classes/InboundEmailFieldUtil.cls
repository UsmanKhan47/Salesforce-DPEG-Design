/**
 * Broker-Protection inbound-email intake — field-safety helpers (staging model).
 *
 * Every value written by this pipeline originates OUTSIDE Salesforce: an RFC header, a
 * forwarded email body, or an LLM extraction. None of them respect Salesforce field
 * limits or the Email-field format check, and a single over-long or malformed value
 * throws a DmlException that aborts the whole routing transaction — losing the claim for
 * an email that was otherwise perfectly good. These two helpers are the chokepoint that
 * stops that: every writer in the pipeline clips text to its field length and sanitizes
 * anything bound to an Email field before DML.
 *
 * LAYER — Utility. Pure functions only: no SOQL, no DML, no callouts, no platform
 * dependency, so the whole class is directly unit-testable. `with sharing` is declared
 * for standards conformance (ARCHITECTURE.md §2) and is functionally a no-op here.
 *
 * @see EmailToLeadHandler.cls / InboundEmailStagingService.cls / InboundEmailActivityService.cls
 * @see EmailToLeadService.cls / PropertyClaimService.cls (the other writers that clip)
 */
public with sharing class InboundEmailFieldUtil {

    /**
     * Salesforce's standard Email-field length. An Email custom field is always 80
     * characters regardless of what the field metadata declares.
     */
    public static final Integer EMAIL_FIELD_LENGTH = 80;

    /**
     * Shape check for a value bound to an Email field. Deliberately the SAME expression
     * the LLM contract and ExtractAddressQueueable's regex fallback use, so a value that
     * one accepts the other does not reject.
     */
    private static final Pattern EMAIL_PATTERN =
        Pattern.compile('^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$');

    /**
     * Truncate `value` to `maxLength` characters. Null in → null out; a value already
     * within the limit is returned unchanged (no copy).
     *
     * @param value     The text to clip; null is returned as null.
     * @param maxLength The destination field's length; null or &lt;= 0 returns `value` untouched.
     * @return `value` truncated to at most `maxLength` characters.
     * @example
     * staging.Subject__c = InboundEmailFieldUtil.clip(email.subject, 255);
     */
    public static String clip(String value, Integer maxLength) {
        if (value == null || maxLength == null || maxLength <= 0 || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
    }

    /**
     * Return `raw` only when it is safe to bind to an Email field — trimmed, no longer
     * than 80 characters, and matching the standard address shape. Anything else returns
     * null so the field is simply left blank.
     *
     * This is a HARD requirement on this pipeline, not defensive decoration: broker_email
     * arrives from an LLM, which can return a display name, a truncated address, or a
     * whole "From:" line. Writing that straight to Lead.Email / Broker_Email__c throws
     * INVALID_EMAIL_ADDRESS and rolls back the claim for an otherwise valid email. A blank
     * broker email is recoverable by hand; a lost claim is not.
     *
     * @param raw The candidate address (LLM output, header value, or envelope address).
     * @return The trimmed address when it is a valid, in-length email; otherwise null.
     * @example
     * lead.Email = InboundEmailFieldUtil.sanitizeEmail(extracted.get('broker_email'));
     */
    public static String sanitizeEmail(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String trimmed = raw.trim();
        if (trimmed.length() > EMAIL_FIELD_LENGTH) {
            return null;
        }
        return EMAIL_PATTERN.matcher(trimmed).matches() ? trimmed : null;
    }
}
