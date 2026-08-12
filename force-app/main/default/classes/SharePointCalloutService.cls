/**
 * Dedicated Microsoft Graph callout wrapper for the SharePoint deal-folder feature. Creates
 * ONE folder under a parent item (or under the drive root) and returns a typed result.
 *
 * LAYER — callout service. Per ARCHITECTURE.md §2 Standards ("all ASB/Plaid callouts wrapped in
 * a dedicated service class ... so they can be mocked via `HttpCalloutMock`") the single
 * `Http.send` in this feature lives here and NOWHERE else, so callers and their tests mock this
 * one boundary. No SOQL, no DML, no configuration reads — every value it needs is a parameter.
 * Modelled on `LLMExtractionCalloutService`, which is the in-repo precedent for both the shape
 * and the §3 exception below.
 *
 * ⚠ DELIBERATE, TEMPORARY §3 EXCEPTION — DIRECT (NON-ASB) EXTERNAL CALLOUT.
 * ARCHITECTURE.md §3.1 mandates that all external integrations route through the Avanza Service
 * Bus. This class INTENTIONALLY breaks that rule and is the SECOND standing exception, recorded
 * and accepted at the design gate in ARCHITECTURE.md §3.4: no ASB SharePoint/Graph spoke exists,
 * so there is nothing on the bus to route to. Credentials are never hardcoded — the client secret
 * lives entirely in the hand-built `SharePoint_Credential` External Credential's
 * `SharePoint_Principal`, injected into the Authorization header by the platform.
 *
 * 🔴 `BASE` BELOW IS THE ONE ENDPOINT CONSTANT IN THE ENTIRE FEATURE, AND THAT IS THE WHOLE POINT.
 * §3.4 promises the exception is retired "by repointing the Named Credential's URL at the ASB
 * spoke ... no Apex signature changes". That promise is only literally true while every path
 * segment is composed here. Do not build a Graph URL anywhere else, and do not let a caller pass
 * one in.
 *
 * ═══ 🔴 ADDRESSING IS BY PARENT ITEM ID, NEVER BY PATH ═══
 * Graph offers two ways to name a parent: by item id (`/drive/items/{id}/children`) and by path
 * (`/drive/root:/{path}:/children`). This class uses the FIRST and must keep using it.
 * `EncodingUtil.urlEncode` emits `+` for a space — correct for a query string, WRONG for a path
 * segment, where a space must be `%20` — and DPEG property names contain spaces constantly
 * ("Magnolia Crossing", "Hwy 290 Retail Center"). Path addressing would therefore either create
 * folders with literal `+` characters in their names or 404 on lookup, intermittently, depending
 * on the name. Item-id addressing has no encoding surface at all: the id is opaque, URL-safe, and
 * is returned by the very call that creates the parent. Measured live: item-id addressing returns
 * 201 for names containing spaces.
 *
 * ═══ 🔴 `conflictBehavior` IS `rename` AND `replace` IS PROHIBITED ═══
 * `replace` on a folder that already exists DESTROYS ITS CONTENTS — which here means signed LOIs,
 * executed PSAs and closing documents. `rename` never destroys anything, needs no pre-flight
 * lookup (so it costs no second callout), and returns the created item's id and `webUrl` in the
 * 201 body. `fail` was considered and rejected in design D3: adopting an existing folder on 409
 * would require a GET by PATH, re-opening exactly the encoding trap described above. The cost of
 * `rename` is a residual, stated rather than hidden: two genuinely different properties with the
 * same Name yield "Magnolia Crossing" and "Magnolia Crossing 1", and humans navigate by the URL
 * stored on `Property__c`, not by browsing.
 *
 * ═══ 🔴 IT NEVER THROWS. EVERY FAILURE COMES BACK AS A `FolderResult`. ═══
 * A transport failure, a timeout, a refused credential and a malformed response body all resolve
 * to a result carrying `statusCode` and a human-readable `errorMessage`. That is not defensive
 * tidiness — it is what lets `DealFolderService` treat one bad property as one bad property
 * instead of losing the whole chunk, and it is what keeps the never-throw contract of the
 * synchronous trigger path expressible at all. ⚠ It cannot catch an UNCATCHABLE platform limit
 * (callout count, cumulative callout time, heap); those are bounded by the CALLER's budget guards
 * in `DealFolderService`, which is where that arithmetic lives.
 *
 * @see DealFolderService.cls          (the only caller; owns folder naming, budget and stamping)
 * @see LLMExtractionCalloutService.cls (the precedent for this shape and for the §3 exception)
 * @see ARCHITECTURE.md §3.4           (the accepted direct-Graph exception and its retirement plan)
 */
public with sharing class SharePointCalloutService {

    /**
     * 🔴 THE ONE ENDPOINT CONSTANT. The Named Credential resolves to
     * `https://graph.microsoft.com/v1.0`; only this line and the credential change when the
     * callout is re-homed onto an ASB Graph spoke (ARCHITECTURE.md §3.4).
     */
    private static final String BASE = 'callout:SharePoint';

    /** 🔴 NEVER `replace`. See the class header — `replace` destroys signed deal documents. */
    @TestVisible private static final String CONFLICT_BEHAVIOR = 'rename';

    /**
     * 🔴 PER-CALLOUT TIMEOUT — A DERIVED NUMBER, NOT A ROUND ONE. IT CLOSES THE FEATURE'S
     * WORST-CASE CALLOUT-TIME ARITHMETIC, AND CHANGING IT RE-OPENS THAT ARITHMETIC.
     *
     * The binding platform limit is the CUMULATIVE 120 000 ms per transaction, not the per-call
     * ceiling, because this feature makes SEVEN callouts per property inside ONE transaction. The
     * caller's guard admits a property while elapsed callout time is still under
     * `DealFolderService.CALLOUT_TIME_BUDGET_MS`, and — deliberately, see that guard's header —
     * makes NO further time check once `createTree` starts, because abandoning a tree halfway
     * leaves a parent folder whose id is the idempotency guard and which therefore nothing ever
     * retries. So the last admitted property's seven calls must fit, whole, in the headroom the
     * budget leaves:
     *
     *   platform cumulative callout time      120 000 ms   (hard; breach throws UNCATCHABLY)
     *   admitted up to                         90 000 ms   (DealFolderService.CALLOUT_TIME_BUDGET_MS)
     *   ────────────────────────────────────────────────
     *   headroom for one whole property        30 000 ms
     *   calls in one property                       7      (DealFolderService.CALLOUTS_PER_PROPERTY)
     *   30 000 / 7                              4 285 ms   -> 4 000 ms, rounded DOWN
     *
     * At 4 000 ms the pathological case — seven consecutive full timeouts on the property admitted
     * at 89 999 ms — costs 28 000 ms and lands at ~118 s, inside 120 s. At the previous 15 000 ms
     * it cost 105 000 ms and landed at ~195 s: a breach of the cumulative limit, which throws an
     * UNCATCHABLE `LimitException` and rolls the transaction back AFTER real folders exist in
     * SharePoint but BEFORE their ids are stamped — so the next sweep creates "<Name> 1", a
     * duplicate nobody asked for and nothing detects (`DealFolderService` residual R3).
     *
     * ⚠ 4 s is still ~8x a healthy Graph folder create (200-500 ms observed), so it truncates a
     * HUNG call, not a slow one. ⚠ It is derived from two constants in `DealFolderService`: raising
     * `CALLOUT_TIME_BUDGET_MS` or growing the subfolder list invalidates this line and it must be
     * re-derived here by hand — the arithmetic is not expressible in code across the two classes.
     *
     * ═══ ⚠ THE OTHER HALF OF THE LEDGER: A SHORTER TIMEOUT BUYS SAFETY WITH **DUPLICATES** ═══
     * The arithmetic above states the LATENCY trade only. A client-side timeout is not a statement
     * that Graph failed — the request may have COMPLETED at the tenant while Apex stopped waiting,
     * and Apex cannot tell the two apart. So:
     *   • a timeout on the PARENT create stamps `Failed` over a folder that exists. The sweep
     *     retries the row, `conflictBehavior: rename` refuses to collide, and SharePoint mints
     *     "<Name> 1" — `DealFolderService` residual R3, reached through a different door than the
     *     stamp-DML one that residual describes, and materially MORE likely at 4 000 ms than it was
     *     at 15 000 ms.
     *   • a timeout on a SUBFOLDER lands in residual R2, which is TERMINAL: the parent id is
     *     populated, that id is the idempotency guard, and nothing auto-retries it. A shorter
     *     timeout therefore also raises the rate of permanently-incomplete trees that a human has
     *     to finish by hand from the stored URL.
     * Both outcomes are ACCEPTED — they are bounded, visible in `SharePoint_Folder_Error__c`, and
     * strictly preferable to the uncatchable cumulative-limit breach the 4 000 ms figure exists to
     * prevent. They are recorded here so that anyone RE-TUNING this constant weighs the whole
     * ledger: raising it trades duplicate/partial-tree rate for cumulative-limit headroom, and
     * lowering it trades the other way.
     */
    private static final Integer TIMEOUT_MS = 4000;

    /** How much of an error body is worth keeping. The stamp field is Long Text(4096) and holds
     *  several of these plus DPEG's own explanatory copy, so each one is bounded here. */
    private static final Integer MAX_ERROR_CHARS = 600;

    /**
     * The outcome of one folder-creation attempt. A value object — no behaviour beyond
     * `isSuccess()`, no callout state, safe to hold in a collection.
     *
     * `statusCode` is 0 when no HTTP exchange completed at all (transport failure, timeout,
     * refused credential); in that case `errorMessage` carries the exception type and message,
     * which is the only diagnostic available for the credential-grant gap this feature has to
     * fail visibly on.
     */
    public class FolderResult {
        /** Graph `id` of the created folder; null unless the call succeeded. */
        public String itemId;
        /** Graph `webUrl` — the browser link a human follows. May be null even on success if the
         *  response omitted it; the caller treats the id as authoritative. */
        public String webUrl;
        /** HTTP status, or 0 when no exchange completed. Never null. */
        public Integer statusCode;
        /** Human-readable failure text; null on success. */
        public String errorMessage;

        /**
         * Whether a folder now exists and its id is known.
         *
         * Both halves are required: Graph answers 201 with a body, and a 2xx whose body cannot be
         * parsed leaves us with a folder we can never address again — which for the caller is
         * indistinguishable from a failure and must be treated as one, because the alternative is
         * stamping `Created` with a null id and permanently disabling the idempotency guard.
         *
         * @return true when the status is 2xx AND an item id came back.
         */
        public Boolean isSuccess() {
            return statusCode != null && statusCode >= 200 && statusCode < 300
                && String.isNotBlank(itemId);
        }
    }

    /**
     * Create one folder in the SharePoint document library.
     *
     * Exactly ONE callout, always. The caller is responsible for the budget arithmetic (this
     * feature spends 7 of these per property) — see `DealFolderService.CALLOUTS_PER_PROPERTY`.
     *
     * @param siteId       Graph site id, from `SharePoint_Config__c.Site_ID__c`. Required; a blank
     *                     value returns a failure result rather than posting to a malformed URL.
     *                     🔴 There is no fallback and there must never be one — a hardcoded id is
     *                     how production deal folders end up in a POC library (design D7).
     * @param driveId      Optional `SharePoint_Config__c.Drive_ID__c`. Blank addresses the site's
     *                     DEFAULT document library via `/sites/{siteId}/drive`, which is what
     *                     DPEG uses; a populated value addresses `/drives/{driveId}` explicitly
     *                     and is honoured so that a site with several libraries cannot silently
     *                     receive deal folders in the wrong one.
     * @param parentItemId Item id of the parent folder, or blank for the drive ROOT. Blank is the
     *                     expected production case (design decision: library root, no parent).
     * @param name         The folder name, ALREADY SANITIZED by
     *                     `DealFolderService.sanitizeFolderName`. This class does not sanitize —
     *                     one sanitizer, one place, unit-testable as a pure function.
     * @return The typed outcome. NEVER null and NEVER thrown; inspect `isSuccess()`.
     * @example
     * SharePointCalloutService.FolderResult r =
     *     new SharePointCalloutService().createFolder(siteId, null, null, 'Magnolia Crossing');
     * if (r.isSuccess()) { property.SharePoint_Folder_ID__c = r.itemId; }
     */
    public FolderResult createFolder(String siteId, String driveId, String parentItemId, String name) {
        FolderResult result = new FolderResult();
        result.statusCode = 0;

        if (String.isBlank(siteId)) {
            result.errorMessage = 'SharePoint site id is not configured; no callout was attempted.';
            return result;
        }
        if (String.isBlank(name)) {
            result.errorMessage = 'Folder name was blank; no callout was attempted.';
            return result;
        }

        try {
            HttpRequest request = new HttpRequest();
            request.setEndpoint(buildEndpoint(siteId, driveId, parentItemId));
            request.setMethod('POST');
            request.setHeader('Content-Type', 'application/json');
            request.setTimeout(TIMEOUT_MS);
            request.setBody(buildRequestBody(name));

            HttpResponse response = new Http().send(request);
            result.statusCode = response.getStatusCode();

            if (result.statusCode >= 200 && result.statusCode < 300) {
                populateFromBody(result, response.getBody());
                if (String.isBlank(result.itemId)) {
                    result.errorMessage = 'HTTP ' + result.statusCode
                        + ' but the response carried no folder id: '
                        + clip(response.getBody(), MAX_ERROR_CHARS);
                }
            } else {
                result.errorMessage = 'HTTP ' + result.statusCode + ' ' + response.getStatus()
                    + ' — ' + graphErrorMessage(response.getBody());
            }
        } catch (Exception e) {
            // Transport failure, timeout, or — the case this feature must surface loudly — a
            // running user with no External Credential Principal Access to SharePoint_Credential.
            // statusCode stays 0, which is how the caller tells "the exchange never happened"
            // from "SharePoint said no".
            result.statusCode = 0;
            result.errorMessage = e.getTypeName() + ' | ' + clip(e.getMessage(), MAX_ERROR_CHARS);
        }
        return result;
    }

    /**
     * Compose the children-collection URL. 🔴 The ONLY place a Graph path is built.
     *
     * Two independent choices, both explained in the class header: the drive segment prefers the
     * site's default library unless a drive id is configured, and the parent segment addresses by
     * ITEM ID rather than by path. Neither segment is URL-encoded, deliberately — Graph site,
     * drive and item ids are opaque URL-safe tokens (a site id such as
     * `contoso.sharepoint.com,<guid>,<guid>` carries commas, which are legal in a path segment),
     * and running them through `EncodingUtil.urlEncode` would corrupt them exactly as it corrupts
     * a name containing a space.
     *
     * @param siteId       Graph site id; non-blank (guarded by the caller).
     * @param driveId      Optional explicit drive id.
     * @param parentItemId Optional parent item id; blank means the drive root.
     * @return The absolute `callout:`-prefixed endpoint.
     */
    private static String buildEndpoint(String siteId, String driveId, String parentItemId) {
        String drivePart = String.isNotBlank(driveId)
            ? '/drives/' + driveId
            : '/sites/' + siteId + '/drive';
        String parentPart = String.isNotBlank(parentItemId)
            ? '/items/' + parentItemId + '/children'
            : '/root/children';
        return BASE + drivePart + parentPart;
    }

    /**
     * The Graph "create a folder" payload.
     *
     * `folder` must serialize as an EMPTY JSON OBJECT (`{}`) — that empty object is what tells
     * Graph the new driveItem is a folder rather than a file. An empty `Map<String, Object>` is
     * the only shape that produces it; do not "simplify" it to null, which Graph rejects.
     *
     * `JSON.serialize` owns all escaping, so a name containing a quote or a backslash-shaped
     * residue cannot break the body.
     *
     * @param name The sanitized folder name.
     * @return The serialized request body.
     */
    private static String buildRequestBody(String name) {
        return JSON.serialize(new Map<String, Object>{
            'name' => name,
            'folder' => new Map<String, Object>(),
            '@microsoft.graph.conflictBehavior' => CONFLICT_BEHAVIOR
        });
    }

    /**
     * Pull `id` and `webUrl` out of a 2xx driveItem body, tolerating any unexpected shape rather
     * than dereferencing a missing node — a parse failure here must degrade to "no id", which the
     * caller already treats as a failure, never to an exception.
     *
     * @param result The result to populate in place.
     * @param body   The raw response body.
     */
    private static void populateFromBody(FolderResult result, String body) {
        if (String.isBlank(body)) {
            return;
        }
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (!(parsed instanceof Map<String, Object>)) {
                return;
            }
            Map<String, Object> item = (Map<String, Object>) parsed;
            Object id = item.get('id');
            Object url = item.get('webUrl');
            result.itemId = (id == null) ? null : String.valueOf(id);
            result.webUrl = (url == null) ? null : String.valueOf(url);
        } catch (Exception e) {
            // Leave itemId null. isSuccess() is then false and the caller stamps Failed with the
            // status line, which is the honest outcome for an unaddressable folder.
            System.debug(LoggingLevel.ERROR,
                'SharePointCalloutService: unparseable 2xx driveItem body — treating as a failure: '
                + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * The human-readable half of a Graph error body (`error.message`), falling back to the raw
     * body when the shape is unexpected. Both are clipped — this text is written to a
     * `Property__c` field a human reads, not to a log.
     *
     * @param body The raw non-2xx response body.
     * @return A bounded, human-readable message; never null.
     */
    private static String graphErrorMessage(String body) {
        if (String.isBlank(body)) {
            return '(no response body)';
        }
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (!(parsed instanceof Map<String, Object>)) {
                return clip(body, MAX_ERROR_CHARS);
            }
            Object errorNode = ((Map<String, Object>) parsed).get('error');
            if (!(errorNode instanceof Map<String, Object>)) {
                return clip(body, MAX_ERROR_CHARS);
            }
            Object message = ((Map<String, Object>) errorNode).get('message');
            if (message != null) {
                return clip(String.valueOf(message), MAX_ERROR_CHARS);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.DEBUG,
                'SharePointCalloutService: non-JSON error body, falling back to the raw text: '
                + e.getTypeName());
        }
        return clip(body, MAX_ERROR_CHARS);
    }

    /**
     * Bound a string to `max` characters. Local rather than borrowed from
     * `InboundEmailFieldUtil` so this feature carries no dependency on the Broker Protection
     * module.
     *
     * @param value The text to bound; null-safe.
     * @param max   Maximum length.
     * @return The value, truncated with an ellipsis marker when it was longer; '' for null.
     */
    private static String clip(String value, Integer max) {
        if (value == null) {
            return '';
        }
        return (value.length() <= max) ? value : value.substring(0, max) + '…';
    }
}
