/**
 * Tests for SharePointCalloutService — the ONE `Http.send` in the SharePoint deal-folder feature.
 *
 * Every test here mocks through `SharePointCalloutMock` (per
 * .claude/skills/sf-apex-test/references/mocking-patterns.md) and asserts on the typed
 * `FolderResult`, never on a raw `HttpResponse`. Coverage focus, per the class's own contract:
 *   - it NEVER throws, under any response shape or transport failure;
 *   - `isSuccess()` requires BOTH a 2xx status AND a non-blank item id;
 *   - the endpoint is built correctly for all four drive/parent combinations, and item-id
 *     addressing is used (never path addressing — see the class header's encoding-trap argument);
 *   - `conflictBehavior` is always `rename`, never `replace`;
 *   - a blank site id or a blank name short-circuits with ZERO callouts.
 *
 * @see SharePointCalloutService.cls
 * @see SharePointCalloutMock.cls
 * @author Unit Testing Agent
 */
@isTest
private class SharePointCalloutServiceTest {

    private static final String SITE_ID = 'contoso.sharepoint.com,11111111-1111-1111-1111-111111111111,'
        + '22222222-2222-2222-2222-222222222222';

    // ═════════════════════════════════════════════════════════════════════════════════════
    // SUCCESS
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void createFolder_201WithWellFormedBody_parsesItemIdAndWebUrl() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('item-123', 'https://contoso.sharepoint.com/x/Magnolia'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'A 201 with an id must be reported as a success');
        Assert.areEqual(201, result.statusCode, '');
        Assert.areEqual('item-123', result.itemId, 'The Graph id must be parsed out of the body');
        Assert.areEqual('https://contoso.sharepoint.com/x/Magnolia', result.webUrl, '');
        Assert.isNull(result.errorMessage, 'A success carries no error message');
        Assert.areEqual(1, mock.requestCount, 'Exactly one callout for one createFolder call');
    }

    /**
     * `isSuccess()` requires BOTH a 2xx status AND a non-blank item id. A 2xx whose body cannot be
     * parsed leaves a folder Salesforce can never address again, which the class header says must
     * be treated as a failure, not a success with a null id.
     */
    @isTest
    static void createFolder_201WithMalformedBody_isTreatedAsFailureNotSuccess() {
        Test.setMock(HttpCalloutMock.class, new SharePointCalloutMock(201, 'not { valid json'));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'A 2xx with an unparseable body must NOT be reported as success — the id is unknown, '
            + 'so the idempotency guard would otherwise be permanently disabled for this property');
        Assert.areEqual(201, result.statusCode, 'The transport status is still recorded honestly');
        Assert.isNull(result.itemId, '');
        Assert.isNotNull(result.errorMessage, 'The caller must be told WHY this 2xx was refused');
    }

    @isTest
    static void createFolder_201WithEmptyBody_isTreatedAsFailure() {
        Test.setMock(HttpCalloutMock.class, new SharePointCalloutMock(201, ''));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'An empty 2xx body carries no id and must be a failure');
        Assert.isTrue(result.errorMessage.contains('no folder id'),
            'Actual: ' + result.errorMessage);
    }

    @isTest
    static void createFolder_201WithBodyMissingId_isTreatedAsFailure() {
        // Well-formed JSON, but no "id" key — a different malformed shape than "not JSON at all".
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, JSON.serialize(new Map<String, Object>{ 'foo' => 'bar' })));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.isNull(result.itemId, '');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // FAILURE STATUS CODES — every one must produce a FolderResult, never throw
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void createFolder_401_isFailureCarryingTheGraphMessage() {
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(401, SharePointCalloutMock.errorBody('Access denied')));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.areEqual(401, result.statusCode, '');
        Assert.isTrue(result.errorMessage.contains('Access denied'),
            'The Graph error.message must surface. Actual: ' + result.errorMessage);
    }

    @isTest
    static void createFolder_403_isFailureCarryingTheGraphMessage() {
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(403, SharePointCalloutMock.errorBody('Forbidden')));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.areEqual(403, result.statusCode, '');
        Assert.isTrue(result.errorMessage.contains('Forbidden'), 'Actual: ' + result.errorMessage);
    }

    @isTest
    static void createFolder_429_isFailure() {
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(429, SharePointCalloutMock.errorBody('Too many requests')));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.areEqual(429, result.statusCode, '');
    }

    @isTest
    static void createFolder_500WithNonGraphShapedBody_fallsBackToTheRawBodyText() {
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(500, 'Internal Server Error (plain text, not Graph JSON)'));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.areEqual(500, result.statusCode, '');
        Assert.isTrue(result.errorMessage.contains('Internal Server Error'),
            'A non-Graph-shaped error body must fall back to the raw text. Actual: ' + result.errorMessage);
    }

    @isTest
    static void createFolder_500WithGraphShapedBody_usesTheGraphMessage() {
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(500, SharePointCalloutMock.errorBody('Service unavailable')));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.isTrue(result.errorMessage.contains('Service unavailable'), 'Actual: ' + result.errorMessage);
    }

    /** A very long error message must be bounded — this field lands in a Long Text(4096) column
     *  alongside DPEG's own explanatory copy, and one Graph body must not consume it all. */
    @isTest
    static void createFolder_veryLongErrorBody_isClippedNotUnbounded() {
        String longMessage = 'X'.repeat(2000);
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(500, SharePointCalloutMock.errorBody(longMessage)));

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isTrue(result.errorMessage.length() < 700,
            'The error text must be clipped to a bounded length. Actual length: '
            + result.errorMessage.length());
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // NEVER THROWS — including a transport-level failure (the credential-denied shape)
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** Simulates the exact failure a running user with no External Credential Principal Access
     *  produces: `Http.send` throws before any HTTP exchange completes. */
    private class ThrowingCalloutMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            throw new CalloutException('Unable to resolve external credential principal for user');
        }
    }

    @isTest
    static void createFolder_transportExceptionFromHttpSend_neverThrows_returnsStatusZero() {
        Test.setMock(HttpCalloutMock.class, new ThrowingCalloutMock());

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.areEqual(0, result.statusCode,
            'Status 0 is how the caller tells "the exchange never happened" from "SharePoint said no"');
        Assert.isTrue(result.errorMessage.contains('CalloutException'),
            'The exception type must be named. Actual: ' + result.errorMessage);
        Assert.isTrue(result.errorMessage.contains('external credential principal'),
            'The exception message must be named. Actual: ' + result.errorMessage);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // GUARD CLAUSES — zero callouts for a blank site id or a blank name
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void createFolder_blankSiteId_noCalloutIsAttempted() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('should-never-be-used', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(null, null, null, 'Magnolia Crossing');
        SharePointCalloutService.FolderResult resultBlank =
            new SharePointCalloutService().createFolder('   ', null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.areEqual(0, result.statusCode, '');
        Assert.isTrue(result.errorMessage.contains('site id'), 'Actual: ' + result.errorMessage);
        Assert.isFalse(resultBlank.isSuccess(), 'A whitespace-only site id is also blank');
        Assert.areEqual(0, mock.requestCount,
            'A hardcoded/guessed site id is never attempted — the class must refuse before calling out');
    }

    @isTest
    static void createFolder_blankName_noCalloutIsAttempted() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('should-never-be-used', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SharePointCalloutService.FolderResult result =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, null);
        SharePointCalloutService.FolderResult resultBlank =
            new SharePointCalloutService().createFolder(SITE_ID, null, null, '   ');
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), '');
        Assert.areEqual(0, result.statusCode, '');
        Assert.isTrue(result.errorMessage.contains('Folder name'), 'Actual: ' + result.errorMessage);
        Assert.isFalse(resultBlank.isSuccess(), '');
        Assert.areEqual(0, mock.requestCount, '');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // ENDPOINT COMPOSITION — item-id addressing, never path addressing
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void buildEndpoint_blankDriveAndBlankParent_addressesTheSiteDriveRoot() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('id-1', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.areEqual('callout:SharePoint/sites/' + SITE_ID + '/drive/root/children',
            mock.lastRequest.getEndpoint(), '');
    }

    @isTest
    static void buildEndpoint_blankDriveWithParent_addressesItemsChildrenByParentId() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('id-1', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new SharePointCalloutService().createFolder(SITE_ID, null, 'parent-item-42', '01 - NDA');
        Test.stopTest();

        Assert.areEqual(
            'callout:SharePoint/sites/' + SITE_ID + '/drive/items/parent-item-42/children',
            mock.lastRequest.getEndpoint(),
            'A subfolder must be addressed BY THE PARENT ITEM ID, never by path');
    }

    @isTest
    static void buildEndpoint_explicitDriveIdBlankParent_addressesDrivesRoot() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('id-1', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new SharePointCalloutService().createFolder(SITE_ID, 'drive-99', null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.areEqual('callout:SharePoint/drives/drive-99/root/children',
            mock.lastRequest.getEndpoint(),
            'An explicit drive id must address /drives/{id}, not the site default library');
    }

    @isTest
    static void buildEndpoint_explicitDriveIdWithParent_addressesDrivesItemsChildren() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('id-1', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new SharePointCalloutService().createFolder(SITE_ID, 'drive-99', 'parent-7', '02 - LOI');
        Test.stopTest();

        Assert.areEqual('callout:SharePoint/drives/drive-99/items/parent-7/children',
            mock.lastRequest.getEndpoint(), '');
    }

    /** DPEG property names contain spaces constantly — the endpoint (ids only) must never encode
     *  them, and the class header explains why: ids are opaque and URL-safe, unlike a path. */
    @isTest
    static void buildEndpoint_siteIdContainingCommas_isNotUrlEncoded() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('id-1', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.isTrue(mock.lastRequest.getEndpoint().contains(SITE_ID),
            'A site id containing commas must survive verbatim, unescaped, in the endpoint. Actual: '
            + mock.lastRequest.getEndpoint());
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // REQUEST BODY — conflictBehavior is ALWAYS "rename", folder is {}
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void requestBody_alwaysCarriesConflictBehaviorRename_andAnEmptyFolderObject() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('id-1', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Map<String, Object> body =
            (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.areEqual('Magnolia Crossing', body.get('name'), '');
        Assert.areEqual(SharePointCalloutService.CONFLICT_BEHAVIOR,
            body.get('@microsoft.graph.conflictBehavior'), '');
        Assert.areEqual('rename', body.get('@microsoft.graph.conflictBehavior'),
            'PROHIBITED: "replace" would destroy signed LOIs, executed PSAs and closing documents. '
            + 'This must never change without a design review');
        Assert.isTrue(body.containsKey('folder'), 'The "folder" key marks the new item as a FOLDER, not a file');
        Map<String, Object> folderNode = (Map<String, Object>) body.get('folder');
        Assert.areEqual(0, folderNode.size(), 'folder must serialize as an EMPTY object, not null');
    }

    @isTest
    static void requestBody_nameWithQuotesAndBackslash_isSafelyEscapedByJsonSerialize() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('id-1', null));
        Test.setMock(HttpCalloutMock.class, mock);
        String trickyName = 'Deal "Alpha" \\ Co';

        Test.startTest();
        new SharePointCalloutService().createFolder(SITE_ID, null, null, trickyName);
        Test.stopTest();

        Map<String, Object> body =
            (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.areEqual(trickyName, body.get('name'),
            'JSON.serialize must round-trip a quote/backslash-bearing name without corrupting the body');
    }

    @isTest
    static void requestBody_setsContentTypeHeader() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('id-1', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new SharePointCalloutService().createFolder(SITE_ID, null, null, 'Magnolia Crossing');
        Test.stopTest();

        Assert.areEqual('application/json', mock.lastRequest.getHeader('Content-Type'), '');
        Assert.areEqual('POST', mock.lastRequest.getMethod(), '');
    }
}
