# DPEG Broker Portal — Final Whole-Feature Code Review

**Date:** 2026-06-22
**Reviewer:** Automated whole-feature review (read-only)
**Scope:** `BrokerPortalController(.cls/Test)`, `BrokerPortalNotifier(.cls/Test)`, `Broker_Portal_New_Lead_Notify.flow`, `brokerDealIntakeForm` LWC, `Broker_Portal_Leads` queue, `Broker_Portal_New_Lead` notification type.
**Spec:** `docs/superpowers/specs/2026-06-22-broker-portal-design.md`

Because this is a **public, unauthenticated, guest-accessible** Lead-creation endpoint, security and abuse-resistance are weighted heavily.

---

## Verdict

**Fix 4 items first (2 Important security/correctness, plus 2 Important hardening gaps).** No Critical issues. The protected-field whitelisting, server-side re-validation, dedup logic, queue ownership, honeypot, and "no internal data leaked back" requirements are all implemented correctly and are covered by tests. The gaps are: a silent fallback that can leave a Lead owned by the guest user, missing server-side length caps on free-text fields, no abuse/rate control, and a few test/robustness holes.

---

## Findings

### 1. [Important] Queue-resolution fallback silently leaves the Lead owned by the guest user
**File:** `BrokerPortalController.cls` lines 95–98 (and `brokerQueueId()` 109–122)

```apex
Id queueId = brokerQueueId();
if (queueId != null) {
    l.OwnerId = queueId;
}
```

If the `Broker_Portal_Leads` queue cannot be resolved (not deployed yet, renamed, wrong `Type`, or query returns empty), `OwnerId` is left unset and the Lead inserts **owned by the guest user**. The spec is explicit (§3, §7, decision table) that ownership-off-the-guest-user is the mechanism that makes the record visible to internal staff under "Secure guest user record access" — and just as importantly, a guest-owned record is the classic guest-user data-exposure footgun. A misconfiguration would silently produce exactly the state the design is trying to prevent, with no error and a benign "thank you" returned to the submitter.

**Why it matters:** Security posture of the whole feature hinges on the Lead never being guest-owned. A silent fallback converts a deploy/config mistake into a latent data-access problem rather than a loud failure.

**Suggested fix:** Treat an unresolvable queue as a hard server error. Throw a safe `AuraHandledException('We could not save your submission. Please try again.')` (logging the real cause via `System.debug`) instead of inserting a guest-owned Lead. At minimum, fail closed rather than open. Add a test that asserts the queue is resolvable (e.g. assert `brokerQueueId()` is non-null in the org), since the happy-path test today *assumes* the queue exists rather than guarding its absence.

---

### 2. [Important] No server-side length caps on free-text fields (only the client enforces `max-length`)
**File:** `BrokerPortalController.cls` `validate()` 129–153; mapping 78–90

Server validation checks required-ness, email/URL/number formats, and picklist membership, but never bounds the **length** of `propertyAddress` (≤255 per spec), `firstName`/`lastName`/`brokerageFirm`, `coStarLink`, or `dealNotes` (≤32768). Length limits exist **only** in the LWC (`max-length="255"`, `max-length="32768"`). A guest endpoint must never trust the client — a direct Apex/Aura call (or a tampered request) can submit a 10,000-char "address" or oversized firm/name.

**Why it matters:** Two concrete effects: (a) `Property_Address__c` is Text(255) and `Company`/`Broker_First__c`/`FirstName`/`LastName` have platform length limits, so an over-length value throws a raw `DmlException` → caught and surfaced as the generic "could not save" — a confusing failure mode for a legitimate-but-long input, and an easy way for an attacker to probe behavior. (b) Unbounded `dealNotes`/address are a cheap storage/abuse vector on a public form (see also Finding 4). The spec's field table lists these caps as validation rules ("non-blank, ≤255", "≤32768"), so omitting them is a spec-compliance gap, not just hardening.

**Suggested fix:** In `validate()`, add explicit length checks mirroring the spec (`propertyAddress.length() > 255`, `dealNotes.length() > 32768`, and reasonable caps on name/firm/email/coStarLink) and reject with a safe message before insert. This keeps the DML path clean and the failure messages user-meaningful.

---

### 3. [Important] No abuse / rate-limiting / volume control on a public write endpoint
**File:** `BrokerPortalController.submitDeal` (whole method); honeypot 71–74

The only abuse control is the honeypot (`website`), which the spec acknowledges is "cheap bot rejection" with "no CAPTCHA in v1." That's an accepted scope decision, so this is **not** a defect against the spec — but for a final security review of an internet-facing, unauthenticated endpoint that inserts a record on every call, it must be called out: a trivial script that omits/blanks the honeypot can create unlimited Leads, each firing the dedup SOQL + after-save Flow + Apex notification. There is no per-IP throttle, no minimum-time-on-page check, no CAPTCHA, and the honeypot defeat is a one-line change for an attacker who reads the page.

**Why it matters:** Lead-table flooding, notification spam to the acquisitions queue, and SOQL/Flow governor pressure are all reachable by an unauthenticated party. Even with honeypot, this is the highest residual risk of the feature.

**Suggested fix (no code change required to ship v1, but recommend):** Document the accepted risk explicitly in the deploy notes, and add at least one cheap server-side guard that doesn't need a CAPTCHA vendor — e.g. a per-session/per-IP submission counter (Platform Cache), a minimum render-to-submit elapsed-time field, or enable Salesforce's guest-user/Experience Cloud rate limits and reCAPTCHA on the public page in Setup. Track CAPTCHA as the planned v2 control (already in spec §11), but don't leave the endpoint with honeypot-only protection silently.

---

### 4. [Minor] Email format regex is permissive and length-unbounded
**File:** `BrokerPortalController.cls` `isValidEmail` 155–157

`^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$` accepts addresses with no length ceiling and some technically-invalid shapes (e.g. consecutive dots `a..b@x.com`, leading dot). It's adequate for a format gate and is not an injection risk (it's used only for a value, never concatenated into SOQL), but combined with Finding 2 the email field is effectively unbounded.

**Why it matters:** Low — worst case a malformed-but-regex-passing email reaches the Lead and may bounce later. Not a security hole.

**Suggested fix:** Add a length cap (e.g. ≤80, Salesforce's Email field limit) in `validate()`; optionally tighten the regex, but the current one is acceptable.

---

### 5. [Minor] `getFormMetadata` picklist describe leaks **all** active values to an anonymous client
**File:** `BrokerPortalController.cls` `getFormMetadata`/`optionsFor` 50–66

`getFormMetadata` is `cacheable=true` and returns every active Asset Type / Deal Type picklist label+value to the unauthenticated page. This is by design (the form needs the options) and the values are not sensitive, so **verified acceptable** — but note that any future addition of internal-only picklist values to `Asset_Type__c`/`Deal_Type__c` would auto-expose them to the public form. No action needed now; flag for whoever maintains those picklists.

---

### 6. [Minor] Honeypot is `display:none` only — no time-trap or second technique
**File:** `brokerDealIntakeForm.css` `.hp { display: none; }` (82–84); `.html` 51–54

The honeypot is hidden purely via `display:none`. Many headless bots that parse the DOM will skip `display:none` inputs (good), but the field name `website` is guessable and some form-fillers will still populate it. The `aria-hidden`/`tabindex="-1"`/`autocomplete="off"` are good touches. **Verified OK for v1** given the explicit "honeypot only" scope; pairs with Finding 3 if hardening later.

---

### 7. [Minor] SOQL injection — verified NOT present
**File:** `BrokerPortalController.cls` `isDuplicate` 174–185; `brokerQueueId` 111–122; `BrokerPortalNotifier` 14–26

All queries use bind variables (`:address.trim()`, `:CLOSED_STATUSES`, `:QUEUE_DEV_NAME`, `:leadIds`, `:NOTIF_TYPE_DEV_NAME`). No dynamic SOQL, no string concatenation into a query anywhere in the feature. **Verified OK.**

---

### 8. [Minor] `without sharing` scope — verified appropriate, but FLS/CRUD is not enforced in code
**File:** `BrokerPortalController.cls` class decl line 1; no `Security.stripInaccessible` / `isCreateable` anywhere

`without sharing` is correct and spec-mandated: the guest user must insert a Lead it will not own and must run the dedup query across records it can't see. The class does not over-reach — it only inserts one Lead and reads `Group`/`Lead Id`. However, there is **no in-code FLS/CRUD enforcement** (`Security.stripInaccessible`, `WITH USER_MODE`, or field-level `isCreateable` checks). The design delegates all field-write authorization to the guest profile ("grants the minimum: Lead Create + create-FLS on exactly the written fields"). That is a valid model, but it means the *profile config is the only thing standing between a future code change and writing a field the guest shouldn't*. Since protected fields are stamped server-side from constants (not from client input), there's no privilege-escalation path today — **verified OK** — but note the security guarantee lives in the (manual, Setup-side) profile, not in this class, and the profile is not in the repo to review.

**Suggested fix (optional/defense-in-depth):** None required for v1. If you want the guarantee in code, build the Lead via `Security.stripInaccessible(AccessType.CREATABLE, leads)` before insert — but that would strip exactly the fields the guest profile is expected to grant, so only do this if the profile FLS is reliably deployed first.

---

### 9. [Minor] Test gaps vs. spec §9 (several listed scenarios are missing)
**File:** `BrokerPortalControllerTest.cls`

The existing tests are genuinely meaningful (the happy-path test asserts every stamped field including `OwnerId == queue`, dedup tests assert the flag value, rejection helper asserts both the throw *and* zero rows). Not hollow. But the spec's §9 list is only partially covered. Missing:

- **Client-override-ignored test** (spec §9 "Client-override ignored"): no test sends `LeadSource='Web'` / `Status='Qualified'` / a bogus `OwnerId` in the payload to prove they're discarded. This is the single most important security assertion for the feature and it isn't tested. (The DTO has no `leadSource`/`status`/`ownerId` fields, so the override is structurally impossible — which is the *right* design — but a test documenting that the server values win would lock the guarantee.)
- **Missing `propertyAddress` / missing `email` (null vs blank)** rejection not individually tested (only `lastName`, `firm`, `email='not-an-email'`, price, asset type, URL are). 
- **`guidanceCapRate` out of 0–100** not tested (e.g. `150` → reject).
- **Invalid `dealType`** not tested (only invalid `assetType`).
- **`First_Seen_Date__c` ≈ now** is asserted non-null but not asserted to be recent.

**Why it matters:** The client-override gap leaves the feature's core security promise unverified by tests; the others are validation branches with no coverage.

**Suggested fix:** Add a `submitDeal_clientOverrideIgnored` test (even though the DTO can't carry those fields, assert the inserted Lead is `'Broker Portal'`/`'New'`/queue-owned regardless of input). Add cap-rate-out-of-range, invalid-dealType, and explicit missing-propertyAddress/missing-email cases.

---

### 10. [Minor] `BrokerPortalNotifierTest` is thin — asserts "no throw," not behavior
**File:** `BrokerPortalNotifierTest.cls` 4–18

The test honestly notes "Custom notifications cannot be queried in tests," which is true, so it can only assert the method completes and the Lead survives. That's acceptable given the platform limitation. However it does **not** cover the early-return-when-type/queue-missing branch (20–22 in the notifier) or the body-fallback-to-Name branch (27) — both are pure Apex logic that *can* be exercised. Minor.

**Suggested fix:** Add a case with a blank `Property_Address__c` to exercise the `addr = l.Name` fallback path, and (optionally) one asserting graceful no-op behavior. Coverage-wise the class is fine; behavior-wise these are untested branches.

---

### 11. [Minor] Notifier body building loops per-lead but is invoked only with one Id — bulk-safe, verified OK
**File:** `BrokerPortalNotifier.cls` 26–39

The notifier queries Leads `IN :leadIds` once and loops, sending one notification per Lead with a try/catch so a send failure never rolls back the Lead transaction (good — and matches the "notification failure must not roll back" comment). The Flow passes a single `$Record.Id`, so there's no real bulk path, but the code is written bulk-safely regardless. The describe calls in the controller (`Lead.Asset_Type__c.getDescribe()` called in both `validate` and `getFormMetadata`) are fine — describes are cheap and not governed. **Verified OK.**

---

### 12. [Minor] Confirmation text mismatch between Apex and LWC (cosmetic)
**File:** `BrokerPortalController.cls` `CONFIRMATION_MSG` 6–7 vs `brokerDealIntakeForm.html` 11–12

The controller returns *"Thank you! We have received your deal. Our acquisitions team will review it shortly."* but the LWC's success state ignores `result.message` and renders its own hardcoded *"Thank you! We've received your deal."* So the carefully-constructed server message is never shown on success (it's only used as an error fallback string). Harmless, but the server `CONFIRMATION_MSG` is effectively dead on the happy path. Spec §6.2 step 7 specifies the server message text; the UI silently diverges.

**Suggested fix:** Either render `result.message` in the confirmation state, or drop the unused server string — pick one source of truth.

---

## Spec-compliance summary

| Requirement | Status |
|---|---|
| Protected fields stamped server-side only (`LeadSource`, `Status`, `First_Seen_Date__c`, `OwnerId`, `Duplicate_Flag__c`) | **OK** — set from constants; DTO can't carry them |
| Lead assigned to `Broker_Portal_Leads` queue (off guest user) | **OK on happy path; fails open if queue unresolved** (Finding 1) |
| Independent server-side re-validation of required + email/URL/number | **OK**, except **length caps missing** (Finding 2) and cap-rate/dealType under-tested |
| Honeypot silently drops bots, benign success | **OK** (Finding 6 caveats) |
| Duplicate flag for open same-address Lead (`Status NOT IN ('Converted','Disqualified')`) | **OK** — bind vars, case-insensitive, tested |
| Apex API 62.0 | **OK** (controller, LWC, flow all 62.0) |
| `without sharing` by design | **OK & appropriately scoped** (Finding 8) |
| Confirmation result leaks no internal data (no Lead Id, no dup status) | **OK** — `SubmitResult` carries only `success` + generic `message` |
| Notification via Flow → Apex (system context, not guest) | **OK** — separation of concerns honored |
| No over-engineering beyond spec | **OK** — nothing built beyond scope; `PicklistOption`/`FormMetadata` are warranted |

**Net:** No Critical issues. Two Important items (queue fail-open, missing length caps) and one Important hardening callout (abuse control) should be addressed before treating this as production-hardened on a public endpoint. Everything else is Minor or verified-OK.
