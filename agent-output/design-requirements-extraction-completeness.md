# Design — Broker Protection: EXTRACTION COMPLETENESS (two fixes)

**Date:** 2026-08-03 · **Priority:** CRITICAL (user-declared — "we need to extract as much information as we can")
**Scope:** `ExtractAddressQueueable.cls` + the ENRICHED block of `LLMExtractionCalloutService.cls`. Nothing else.
**Routing:** `salesforce-developer` (the module's warm builder). Then `salesforce-unit-testing` → `salesforce-code-review`.
**Status:** approved-in-principle by the user; this doc records the decisions, the residuals and the verification plan.

**Additive to, and does not supersede:**
`agent-output/design-requirements.md` (C-1…C-22), `agent-output/design-requirements-prompt-tuning.md` (2026-08-02, D1–D4),
`agent-output/design-requirements-conversion-enrichment.md` (2026-08-03, S1–S4),
`docs/2026-07-31-llm-field-extraction.md`, `docs/2026-08-03-conversion-enrichment.md`.

---

## 0. TRIGGERING INCIDENT (live, 2026-08-03)

The **Eden Prairie** email. Its SUBJECT carried essentially the whole deal:

```
Offers Due: August 18th | Eden Prairie Apartments | 432-Unit Value-Add Community | Suburban Chicago
```

**The model never saw it.** `ExtractAddressQueueable.extractOrDegrade` (≈ line 552) calls
`new LLMExtractionCalloutService().extract(staging.Raw_Body__c, imageBase64, imageMimeType)` — **body only**.
`staging.Subject__c` is read three other places in the same class (`routeProperty` → submission rows, `createLead` →
`Lead.Email_Subject__c`, `finish()` → the Task subject) but is **never handed to the LLM**.

Measured consequences on that email:

| Value | Returned | Where the truth actually was |
|---|---|---|
| `email_category` | `other` | `Offers Due:` LEADS the subject |
| `confidence` | `0.0` | — |
| `unit_count` | `null` | `432-Unit`, subject-only |
| `property_address` | `''` | `Suburban Chicago`, subject-only |
| `property_name` | short-form | full name in the subject |

`property_address = ''` → empty work-list → **branch (c) NO-PROPERTY** → no claim key → **no registry row, no
first-broker-wins protection** — and every per-property field the model *did* extract died in the staging JSON,
because branch (c) passes `property = null` into `createLead`. The only surviving trace was the Deal Notes footnote
`- Eden Prairie (no usable address)`.

Two independent defects, therefore two fixes. **FIX 1 reduces how often FIX 2 fires; FIX 2 is the safety net for
what is left.** Both are wanted.

---

## 1. WHAT THE USER REQUESTED

**FIX 1 — pass the SUBJECT to the LLM.** Prepend a labelled `Subject:` line to the text content, decide whether the
enriched prompt should tell the model subjects exist and often carry unit counts / due dates / locations / names,
resolve the `MAX_INPUT_CHARS` clipping interplay, consider `RE:`/`FW:` noise, and produce a test plan.

**FIX 2 — stamp unroutable properties onto the Lead.** When the extraction contains ≥ 1 property but NONE is
routable, apply the property block of the FIRST property to the branch-(c) Lead. No claim, no registry row.
`Property_Address__c` stays null. Never fabricate an address.

Nothing else. No new fields, no new objects, no permission changes, no schema change.

---

## 2. FINDINGS THAT SHAPE THE DESIGN (verified against the code, not assumed)

### F1 — The clip runs INSIDE the callout service, on whatever string it is handed

`LLMExtractionCalloutService.buildRequestBody` → `InboundEmailFieldUtil.clip(textContent, MAX_INPUT_CHARS /* 40000 */)`.
`clip` is `substring(0, maxLength)` — it truncates the **tail** and preserves the **head**.
**Therefore: prepend before the call and the subject survives the clip unconditionally.** No change to
`MAX_INPUT_CHARS`, no change to `buildRequestBody`, no change to the `extract(...)` signature.

Cost: the prepended block displaces ≤ ~270 characters of quoted history from the tail of a > 40k body
(`Subject__c` is `Text(255)`, already clipped at `InboundEmailStagingService.createStaging`). That is the same
trade C-15 already accepted, an order of magnitude smaller.

### F2 — Changing `extract(...)`'s signature would break a documented, load-bearing promise

`LLMExtractionCalloutService`'s header states the §3 ASB exception is "scoped and reversible: **only this class's
endpoint constant … change; the public `extract(...)` signature, the request-shaping, and every downstream caller
stay identical**." A 4-arg `extract(subject, body, image, mime)` would break that sentence, touch
`LLMExtractionCalloutServiceTest`, `EmailToLeadServiceTest` and `EmailToLeadHandlerTest`, and buy nothing —
composition at the queueable call site is strictly cheaper. **The queueable is the cleaner seam. Confirmed, not
assumed.**

### F3 — The Apex regex fallback reads `Raw_Body__c` directly and must keep doing so

`applyRegexFallback` matches `FROM_LINE_PATTERN` against `staging.Raw_Body__c`; `applyEnvelopeEmailFallback` reads
the envelope. Neither sees the composed string. **Do not repoint them at the composed text** — an injected line
above the outermost `From:` is exactly the shape that would re-attribute a claim, and that is the module's worst
failure class.

### F4 — A one-line `Subject:` header structurally defuses the "injected From: line" hazard

The only way the prepend could re-attribute a broker is if the subject itself contained a line starting `From:`.
`FROM_LINE_PATTERN` is `(?im)^\s*From:\s*(.+)$` — **start of line**. If the subject is emitted as exactly ONE line
prefixed with `Subject: `, any `From:` inside it is mid-line and is neither a "From: line" to the regex nor to a
model told the outermost/earliest **line** is authoritative. The mitigation is therefore "collapse CR/LF in the
subject to a space", which is one `replaceAll`.

### F5 — Branch (c) already has everything FIX 2 needs; only `null` is being passed

`EmailToLeadService.LeadRequest.property` is already a nullable `PropertyExtraction`, and `applyPropertyBlock`
already stamps all 20 deal-screening fields and **deliberately never writes `Property_Address__c`** (that is set
separately in `createLeadFromExtracted`, and only `if (String.isNotBlank(request.propertyAddress))`).
`ExtractAddressQueueable.routeNoProperty` calls `createLead(extraction, null)`.
**FIX 2 is "stop passing null". `EmailToLeadService` needs NO change at all.**

### F6 — These Leads feed conversion, so FIX 2's value is larger than "fields on a Lead"

`LeadConvertService.buildProperty` / `buildOpportunity` already read `Property_Name__c`, `Property_Address__c`,
`Unit_Count__c`, `Asset_Type__c`, `Guidance_Price__c`, `Building_SF__c`, `NOI__c`, `Occupancy_Pct__c`,
`Year_Built__c`. The Opportunity name falls back to `firstNonBlank(Property_Name__c, Property_Address__c)`.
Today a branch-(c) Lead carries **none** of those, so it converts into an unnamed Property/Opportunity with no
deal facts. FIX 2 makes a no-address Lead convert with the **same payload as a winner Lead**, minus the address.

### F7 — The existing no-property test does NOT break

`execute_noExtractableAddress_createsPlainLeadWithoutClaimingAnything` mocks the LEGACY four-key shape with
`property_address: ''`. In `LLMExtractionParser.parseProperties`, no `properties` array is present and
`textOf('')` returns null, so the legacy synthesis is skipped and `result.properties` is **empty**. That email has
zero properties, so it stays on `OUTCOME_NO_PROPERTY` byte-identically. It becomes the regression guard for the
"genuinely nothing" case.

### F8 — `LLMExtractionResult.emptyResult()` carries an empty `properties` list

So the LLM-outage path can never collide with FIX 2's new label — a degraded extraction has no properties and
still stamps `OUTCOME_NO_PROPERTY_LLM_DOWN`. Verified, not assumed.

### F9 — Nothing in the suite blocks the prompt edit, provided the legacy block is untouched

`ExtractionRegressionFixtureTest` pins `LEGACY_EXTRACTION_RULES` / `LEGACY_RESPONSE_FORMAT` verbatim and asserts
the clip preserves the head. `LLMExtractionCalloutServiceTest` asserts `contains` on the request body plus
`sentBody.length() < 80000`. A ~600-char enriched paragraph and a ~270-char subject line break none of them.
Same finding as prompt-tuning F4, re-verified.

---

## 3. DECISIONS

### 🔷 FIX 1

#### D1 — Compose at the QUEUEABLE call site, in a `@TestVisible` pure function

Add to `ExtractAddressQueueable`:

```apex
@TestVisible
private static String buildLlmText(String subject, String body)
```

`extractOrDegrade()` becomes:

```apex
.extract(buildLlmText(staging.Subject__c, staging.Raw_Body__c), imageBase64, imageMimeType)
```

**Why `@TestVisible` and pure:** it is the only part of FIX 1 that CAN be asserted deterministically — the same
reasoning `buildWorkList` already carries in its Javadoc ("a pure function and the ordering is the only part of
the deadlock guarantee that CAN be asserted directly"). A prompt's *effect* is not unit-testable; its *input*
is.

#### D2 — Exact format

```
Subject: <subject, CR/LF collapsed to a single space>
<blank line>
<raw body verbatim>
```

i.e. `'Subject: ' + oneLine(subject) + '\n\n' + body`.

Rules, all load-bearing:

1. **Blank/null subject → return the body BYTE-IDENTICALLY**, with no `Subject:` line and no leading newlines.
   This is what keeps every existing test's sent body and every existing email shape unchanged, and it makes
   FIX 1 a strict superset of today's behaviour.
2. **Blank/null body → `'Subject: X'` alone** (no trailing separator, no NPE).
3. **CR/LF inside the subject collapse to one space** — F4's structural mitigation. Non-negotiable.
4. The label is `Subject: ` — the exact RFC token the model already reads inside forwarded header blocks, so the
   composed text reads as a continuous email header block rather than as an annotated prompt.

**Rejected:** `EMAIL SUBJECT:` / `=== SUBJECT ===` framing. It makes the text look like prompt scaffolding rather
than an email, and the enriched paragraph (D3) names the line explicitly anyway.

#### D3 — YES, add ONE enriched-block paragraph. The prompt must be told the line exists.

**Required**, not optional. The legacy block's opening sentence — *"The content below is the body of a broker
email"* — is now slightly untrue, and we may not edit it. More importantly, the legacy rule says
*"property_address is any property address found anywhere in the **body**"*; without an explicit extension, the
model may reasonably decline to take `Suburban Chicago` from a Subject line, and FIX 1 achieves nothing on the
exact email that motivated it.

**Placement:** `ENRICHED_EXTRACTION_RULES` only. `LEGACY_EXTRACTION_RULES` and `LEGACY_RESPONSE_FORMAT` are
**untouchable** — byte-pinned by `ExtractionRegressionFixtureTest` and the one-line rollback lever. Put it FIRST
in the enriched block, immediately after the `=== END OF THE ORIGINAL RULES ===` delimiter, because it describes
the SHAPE of the input and everything after it depends on that shape.

**The paragraph must say (content requirements, developer to word it):**

- The content begins with a single `Subject:` line carrying the subject of the forwarded email as received,
  followed by a blank line and then the body.
- **It is part of the email's content and may be read for any extracted value** — explicitly naming
  `property_name`, `property_address`, `unit_count`, `offer_due_date`, `asset_type`, `sale_process` and the
  classification — because broker subjects routinely carry the deadline, the unit count, the asset name and
  the market.
- **BODY-OVER-SUBJECT PRECEDENCE (this is the safety property — see D4):** when the body and the subject both
  state a property address, the BODY wins. The subject may only supply an address the body does not state.
- A leading forwarding/reply prefix (`RE:`, `FW:`, `FWD:`, bracketed list tags) is transport noise and is not
  part of `property_name`.
- **Deferral sentence** — the same pattern `BROKER vs LISTING BROKER`, `sent_datetime` and S4 already use:
  this paragraph does not change WHICH `From:` / `Sent:` line is authoritative for `broker_name`,
  `broker_email` or `sent_datetime` (a `Subject:` line is neither), and it does not relax any
  anti-hallucination rule.

#### D4 — BODY-OVER-SUBJECT PRECEDENCE is the change's principal risk control. State it as a decision.

The paragraph in D3 **widens where `property_address` may be found**, and `property_address` is one of the two
values the first-broker-wins ledger arbitrates on. Per the standing rule *"a prompt change silently changes who
WINS a property"*, that must be bounded, not hand-waved.

The precedence rule bounds it exactly: **the subject can only ADD an address where the body stated none.**
Consequence, stated plainly and worth the whole design:

> **FIX 1 cannot change the claim key of any email that already produced one.** Every existing
> `Property_Registry__c` row was keyed from a body-derived address; body-over-subject leaves those emails'
> extraction unchanged. The behaviour change is confined to emails that TODAY yield no key at all, where there is
> nothing to regress against.

That property is what makes this shippable without re-keying the ledger. It is also what UAT case **D** tests.

#### D5 — Do NOT strip `RE:` / `FW:` in Apex

Three reasons:

1. **The prefix is evidence.** `RE:` is a genuine classification signal feeding `email_category` and the D2
   relevance gate. Stripping it destroys information.
2. **It would be a second, divergent rule.** The model is already told `property_name` is the marketing/brand
   name and never to invent one; an Apex-side strip creates a competing semantic rule that will drift — the same
   argument `LLMExtractionParser` uses for owning coercion in exactly one place.
3. **It cannot affect routing.** Reply detection is header-based (`In_Reply_To__c` / `References__c`) and runs in
   the prologue BEFORE the callout, so a subject's `RE:` never routes anything.

Handle it with the one sentence in D3 instead. **Apex does not parse email semantics in this module — that is
the LLM's job and the parser's contract.**

#### D6 — The deterministic pre-filter is NOT touched

`SENDER_CONTAINS`'s Javadoc says *"NO SUBJECT-KEYWORD FILTERING, deliberately … a false positive here costs a
broker their claim."* FIX 1 feeds the subject to the **LLM**, which is judged by the tiered gate where a wrong
call lands in the SOFT tier (Lead created, `Parse_Confidence__c = LOW`, claim still taken). That is entirely
consistent with the existing decision and must be recorded so a reviewer does not read it as a reversal.

#### D7 — Accepted second-order effect: classification will change in BOTH directions

Giving the model the subject is precisely intended to move Eden Prairie from `other`/`0.0` to
`call_for_offers`/high. The symmetric effect: an email whose subject reads `Out of Office` or `Undeliverable`,
and which the deterministic pre-filter does not catch, may now be **HARD-gated** (`is_acquisition_related = false`
AND `confidence ≥ 0.85`) where it previously minted a junk Lead. That is the gate working as designed, but it is
a live behaviour change and is named as **UAT case G**. A genuine broker email would have to make the model
confidently wrong to be gated, which is the bar D2 was tuned to.

---

### 🔷 FIX 2

#### D8 — Reuse `LeadRequest.property` + `applyPropertyBlock`. NO new path, NO `EmailToLeadService` change.

Per F5, branch (c) already passes `null` into a mechanism that does exactly the right thing. Adding a second
stamping path would create a second, divergent field-mapping rule set — the precise anti-pattern the
parser/util/service split exists to prevent, and the one that guarantees the two drift apart on the next field
added. `applyPropertyBlock` already never writes the address, which is the invariant FIX 2 depends on.

**`EmailToLeadService.cls` is untouched by this change.**

#### D9 — Which branch code changes: `ExtractAddressQueueable.routeNoProperty` only

```apex
private void routeNoProperty(LLMExtractionResult extraction) {
    PropertyExtraction stampable = firstProperty(extraction.properties);   // null when the list is empty
    pendingSpillover = buildSpilloverNote(extraction.properties, new List<PropertyExtraction>(), stampable);
    Id leadId = createLead(extraction, stampable);
    ...
}
```

Plus a small `claimableAddress(...)` guard in `createLead` (D12) and a third parameter on `buildSpilloverNote`
(D13). That is the entire code surface of FIX 2.

#### D10 — Multi-property: FIRST only, in the MODEL's array order; the rest stay in the Deal Notes footer

"Priority-ordered" resolves to **`extraction.properties[0]` (first non-null element)** — the model's own order.

Justification, and why the class header's "the model's array order is not stable" warning does **not** apply:
that warning governs **lock ordering** (`buildWorkList` sorts by cluster key to prevent an AB-BA deadlock), where
cross-transaction stability is a correctness requirement. **Branch (c) takes no lock and creates no claim key**,
so nothing here is order-sensitive; the only question is which of N addressless properties gets stamped. Three
reasons to use the model's order anyway:

1. the model lists the headline property first — that is exactly the Eden Prairie / subject-led shape;
2. `buildSpilloverNote` already iterates in the same order, so the stamped property and the footnote list stay
   consistent by construction;
3. any "richness ranking" heuristic (most non-null fields wins) is a second ordering rule that would drift from
   the footer and would have to be maintained.

**No ordering guarantee is claimed and none is needed.** Say that in the Javadoc so nobody later "hardens" it.

Note the clean partition this relies on: branch (c) fires **only when the work-list is empty**, so in branch (c)
**every** property is addressless. There is no mixed case to reason about.

#### D11 — NEW outcome label: `OUTCOME_NO_ADDRESS = 'New Lead (property, no address)'`

Keep `OUTCOME_NO_PROPERTY` for the genuinely-nothing case. Precedent is `OUTCOME_NO_PROPERTY_LLM_DOWN`, whose
Javadoc gives the test: **a distinct label exists when the FOLLOW-UP DIFFERS.** It does here:

| Label | What it means | Follow-up |
|---|---|---|
| `New Lead (no property)` | the email pitched nothing identifiable | none |
| `New Lead (property, no address)` | **a named property with deal facts, holding NO registry claim** | chase an address so the claim can be taken |
| `New Lead (no property) — LLM unavailable` | outage; re-extract when it clears | re-extract |

The middle row is the population an admin must be able to list — these are the Leads with deal data and **no
first-broker-wins protection**. Precedence when both could apply: **LLM-down wins** (per F8 it cannot actually
collide, but code it explicitly so it stays true).

`Outcome__c` is free Text and **historical rows are NOT back-filled** — same precedent as the retired
`'Competing Duplicate'` label on 2026-07-31. The staging object is an audit trail of what the pipeline did at
the time.

#### D12 — `Property_Address__c` stays null — enforced, not inherited

Do not rely on "the addressless property's `propertyAddress` happens to be blank". It is not guaranteed:
`buildWorkList` drops a property when `normalizeAddress(propertyAddress)` is **blank**, and
`normalizeAddress` strips every non-alphanumeric — so a raw value of `'###'` or `'—'` is non-blank while its
normalized form is empty. Passing that through would stamp punctuation into `Lead.Property_Address__c`.

Add a private helper in `ExtractAddressQueueable.createLead`:

```apex
request.propertyAddress = claimableAddress(property);   // null unless normalizeAddress(...) is non-blank
```

This encodes a genuinely useful, statable invariant:

> **`Lead.Property_Address__c` only ever holds an address that COULD have produced a claim key.**

Branches (b)/(d)/(e) are unaffected — their properties normalize non-blank by construction — so this is a pure
guard, not a behaviour change on the claim paths. **Never fabricate, never synthesize from `property_name`, never
copy the subject in.**

#### D13 — Exclude the stamped property from the Deal Notes footer

`buildSpilloverNote` currently emits `- Eden Prairie (no usable address)` under the heading *"Additional
properties in this email (not routed)"*. After FIX 2 the FIRST property's fields are ON the Lead, so listing it
there reads as a contradiction on exactly the record this fix exists to improve.

Add a third parameter — `PropertyExtraction exclude` — and pass `null` from `routeProperties` (unchanged
behaviour) and `stampable` from `routeNoProperty`. Compare by **object identity**, not by value.

Common case (one addressless property): the note becomes empty → no footer at all → the Lead simply carries the
property block. Correct.

**This is the one discretionary piece of FIX 2** — it can be dropped for maximum surgicality at the cost of a
confusing footnote. Recommendation: keep it, it is ~3 lines.

#### D14 — Interplay with every other branch: verified NONE

| Branch | Requires | Reachable in the FIX 2 case? |
|---|---|---|
| (a) REPLY | `In_Reply_To__c` / `References__c` header match, resolved in the PROLOGUE **before** the callout | No — if it matched, `routePrologueWithoutCallout()` already returned true and `routeProperties` never runs |
| pre-filter | envelope/headers, also pre-callout | No — same |
| HARD gate | `is_acquisition_related = false` AND `confidence ≥ 0.85`, checked **before** `routeProperties` | Not affected — a gated email still creates **NO Lead**, with or without properties. FIX 2 must not change that |
| SOFT gate | continues, `Parse_Confidence__c = LOW` | Compatible — a LOW-confidence Lead now also carries the property block and still lands in the Review Queue |
| (b) REPEAT | `findBrokerSubmission(brokerEmail, normalized)` — needs a **normalized address** | No |
| (d) COMPETING | `findMatchingRegistry(normalized)` — needs a **normalized address** | No |
| (e) WINNER | `claim(..., normalized, ...)` — needs a **normalized address** | No |

Branch (c) is reached **only** when no normalized address exists anywhere in the extraction, which is exactly the
precondition (b)/(d)/(e) each fail. **Confirmed by reading the call chain, not assumed.**

Also: the FIX 2 Lead creates no `Property_Registry__c` row, so no orphan-adoption path can later reach it, and
no `Competing_Broker_Submission__c` points at it.

#### D15 — C-1 is NOT contradicted

C-1 says: do not mint a junk unclaimable Lead **per** addressless property. FIX 2 mints **no additional Lead** —
it stamps the single Lead branch (c) already creates. C-1's own words ("Unaddressable entries alongside
addressable ones become the spillover note instead") describe the multi-property case, which is untouched:
when at least one property IS addressable, branch (c) never fires and the footer behaves exactly as today.

#### D16 — RESIDUAL, stated explicitly as the user asked: no first-broker-wins protection until an address exists

An address-less property **cannot** claim. A blank `Property_Key__c` would collide with every other addressless
email on the registry's unique index, and claiming on a synthesized key would write a guess into a permanent,
unique-keyed ledger. So:

> **A `New Lead (property, no address)` Lead carries the deal facts but NO claim. Any broker who later submits the
> same property WITH an address will win it outright. The only mitigation is human: chase the address, then let
> the next email claim it.**

The new outcome label is what makes that population findable. **No claim is attempted, now or later, by this
change.**

---

## 4. CONSTRAINTS — restated as a checklist for the implementer

- [ ] `LEGACY_EXTRACTION_RULES` and `LEGACY_RESPONSE_FORMAT` are **byte-untouched**. All prompt text goes in
      `ENRICHED_EXTRACTION_RULES`.
- [ ] No address is ever fabricated, synthesized, or copied from `property_name` / the subject into
      `Lead.Property_Address__c`.
- [ ] The claim engine's contract for **routable** properties is unchanged: `buildWorkList`, the cluster-key sort,
      `PropertyClaimService`, `PropertyMatchingService`, `EmailToLeadService` — **not one line**.
- [ ] `Outcome__c` labels are free Text; **no back-fill** of historical rows.
- [ ] `ExtractionRegressionFixtureTest` stays green **unmodified**. A red fixture means the legacy block was
      touched — stop, do not deploy.
- [ ] `extract(String, String, String)` signature, `MODEL`, `temperature`, `MAX_TOKENS`, `response_format`,
      `MAX_INPUT_CHARS`, `MAX_PROPERTIES_IN_PROMPT`, the image-part ordering and `referenceDateLine()` are all
      unchanged.
- [ ] **Zero new SOQL, zero new DML.** The governor-headroom assertions
      (`ExtractAddressQueueable.lastRunQueryCount` / `lastRunDmlCount`) must remain green **at their current
      numbers**. If an implementer finds themselves relaxing that budget, the change is wrong.
- [ ] `applyRegexFallback` / `applyEnvelopeEmailFallback` keep reading `staging.Raw_Body__c` and the envelope —
      never the composed text.
- [ ] Surgical: this module is live and has shipped 7 features this week.

---

## 5. COMPONENT LIST

### 🔵 ADMIN WORK

**No admin work required for this request.** No fields, objects, picklists, layouts, list views or permission
sets change. `Outcome__c` is free Text. Every Lead field FIX 2 stamps (`Property_Name__c`, `Unit_Count__c`,
`Asset_Type__c`, `Sale_Process__c`, `Offer_Due_Date__c`, …) already exists and is already stamped on WINNER
Leads, so the FLS the personas need is already granted — a persona who can see these on a winner Lead sees them
on a no-address Lead. (The insert is system-mode regardless; FLS is a display gate only.)

### 🟢 DEVELOPMENT WORK

| # | File | Change |
|---|---|---|
| 1 | `classes/ExtractAddressQueueable.cls` | **FIX 1:** new `@TestVisible private static String buildLlmText(String subject, String body)` (D2); `extractOrDegrade()` calls it (D1). |
| 2 | `classes/ExtractAddressQueueable.cls` | **FIX 2:** new constant `OUTCOME_NO_ADDRESS` (D11); `routeNoProperty` selects + stamps the first property and picks the label (D9/D10/D11); new `claimableAddress(...)` guard used by `createLead` (D12); `buildSpilloverNote` gains an `exclude` parameter, `routeProperties` passes `null` (D13). |
| 3 | `classes/ExtractAddressQueueable.cls` | Header: update the ROUTING TREE block's branch-(c) line and step 8, document the composed LLM input, the new label, D10's no-ordering-guarantee note and D16's residual. |
| 4 | `classes/LLMExtractionCalloutService.cls` | **FIX 1 prompt:** one paragraph at the TOP of `ENRICHED_EXTRACTION_RULES` (D3), plus a dated `2026-08-03` header note recording that the input now carries a `Subject:` line, that the legacy block is untouched, and that body-over-subject precedence (D4) is the claim-key protection. |
| 5 | `classes/ExtractAddressQueueableTest.cls` | New tests T1–T5, T8–T14 (§6). Existing tests unchanged. |
| 6 | `ARCHITECTURE.md` §2 | Amend the **Broker Protection staging model** paragraph: branch (c) now stamps the first property's block and may stamp the new outcome label; amend the `LLMExtractionCalloutService` row to say the extraction input is the **subject line + body** (+ image). Per §6, same PR. |

**Not changed, deliberately:** `EmailToLeadService.cls` (F5/D8), `LLMExtractionParser.cls`,
`PropertyMatchingService.cls`, `PropertyClaimService.cls`, `InboundEmailStagingService.cls`,
`InboundEmailFieldUtil.cls`, `EmailToLeadHandler.cls`, `ExtractionRegressionFixtureTest.cls`,
`LLMExtractionCalloutServiceTest.cls`, and every metadata file.

### 🔗 EXECUTION ORDER

1. **FIX 1 code + prompt** (items 1, 4) — independently shippable and independently rollback-able.
2. **FIX 2 code** (items 2, 3) — independent of FIX 1; ship together only for convenience.
3. **Tests** (item 5) → **ARCHITECTURE.md** (item 6) → code review → deploy → live UAT.

Neither fix depends on the other. If FIX 1's live UAT disappoints, FIX 2 still stands on its own (and becomes
*more* valuable, since more emails stay addressless).

---

## 6. TEST PLAN

### 6.1 Bulk-test-rule position (`.claude/rules/bulk-test-rule.md`)

`ExtractAddressQueueable`, `PropertyClaimService`, `EmailToLeadService` and `PropertyMatchingService` are
**de-exempted** (design C-18, 2026-07-31) and their replacement volume tests already exist at the bottom of
`ExtractAddressQueueableTest`: 10-property routing with governor-headroom assertions, 15-property truncation,
mixed outcomes, cluster-key ordering (pure + end-to-end), the tiered gate, and the two no-callout branches.

**No NEW volume mandate is triggered:** FIX 1 adds zero per-property work, and FIX 2 fires only when the
work-list is **empty** (zero properties routed). Two obligations remain:

1. all five existing replacement tests stay green **unmodified**, at their current governor budget;
2. add **T11** — the multi-property shape FIX 2 does introduce (3 addressless properties → ONE Lead).

`LLMExtractionCalloutService` remains exempt (still exactly one callout per job) and is untouched by code anyway.

### 6.2 Deterministic Apex tests — FIX 1

| # | Test | Asserts |
|---|---|---|
| T1 | `buildLlmText_prependsALabelledSubjectLine` | exact output `'Subject: X\n\n<body>'` — pinned as a string, so a later "tidy" of the format fails here |
| T2 | `buildLlmText_blankSubject_returnsTheBodyByteIdentically` | **the compatibility guard.** No `Subject:` line, no leading newline. This is what proves FIX 1 is a strict superset of today |
| T3 | `buildLlmText_blankBody_returnsTheSubjectLineAlone` | no NPE, no trailing separator |
| T4 | `buildLlmText_multilineSubject_isCollapsedToOneLine` | **F4's structural mitigation.** A subject containing `\n From: attacker@x` must not produce a line beginning `From:` |
| T5 | `buildLlmText_survivesTheFortyThousandCharacterClip` | `InboundEmailFieldUtil.clip(buildLlmText(subject, 60k body), 40000)` still `startsWith('Subject: ')` **and** still contains the outermost `From:` / `Sent:` lines — mirrors `ExtractionRegressionFixtureTest.inputClip_neverRemovesTheOutermostFromAndSentLines` |
| T6 | `execute_sendsTheSubjectToTheModel` (end-to-end) | hold the `LLMExtractionCalloutMock` instance, run the queueable, assert `mock.lastRequest.getBody().contains('Subject: FW: Offers Due')` |
| T7 | `ExtractionRegressionFixtureTest` — **run unmodified** | legacy block verbatim, rollback lever intact, clip head-preserving |

⚠ **T6 caveat the developer must handle.** `mock.lastRequest` is only proven in this repo for a **synchronous**
call (`LLMExtractionCalloutServiceTest`). Asserting it across the `Test.stopTest()` async boundary is unproven
here. It *should* hold (the queueable runs in the same test transaction and `Test.setMock` retains the instance
reference), but if it does not, use the in-class precedent: a test-local `HttpCalloutMock` with a **static**
capture field, exactly as `VolumeMock` is already defined inside `ExtractAddressQueueableTest`. **T1–T5 are the
real guarantee; T6 is confirmation.** Do not let T6 flakiness block the change.

### 6.3 Deterministic Apex tests — FIX 2

| # | Test | Asserts |
|---|---|---|
| T8 | `execute_addresslessNamedProperty_stampsTheBlockButClaimsNothing` | Lead created; `Property_Name__c` / `Unit_Count__c` / `Offer_Due_Date__c` / `Asset_Type__c` / `Sale_Process__c` stamped; **`Property_Address__c` IS NULL**; `COUNT() FROM Property_Registry__c` = 0; `COUNT() FROM Competing_Broker_Submission__c` = 0; `Outcome__c` = `OUTCOME_NO_ADDRESS` |
| T9 | `execute_noExtractableAddress_createsPlainLeadWithoutClaimingAnything` (**existing, unmodified**) | per F7 it carries ZERO properties, so it must still stamp `OUTCOME_NO_PROPERTY` and leave the property block unset — the regression guard for the old label |
| T10 | `execute_llmCalloutFails_...` (**existing, unmodified**) | `OUTCOME_NO_PROPERTY_LLM_DOWN` still wins (F8) |
| T11 | `execute_threeAddresslessProperties_stampsTheFirstAndFootnotesTheRest` | ONE Lead; first property's fields on it; the other two in `Deal_Notes__c` under *"Additional properties in this email (not routed)"*; **the stamped one is NOT repeated there** (D13); 0 registry rows |
| T12 | `execute_unNormalizableAddress_leavesPropertyAddressNull` | `property_address = '###'` → block stamped, `Property_Address__c` null (D12) |
| T13 | `execute_newUnclaimedProperty_...` (**existing, unmodified**) | branch (e) still stamps `Property_Address__c` **verbatim** — the regression guard on `claimableAddress` |
| T14 | `execute_hardGatedEmailWithAnAddresslessProperty_stillCreatesNoLead` | the gate precedes `routeProperties`; FIX 2 must not resurrect a Lead the gate suppressed |

Plus the existing suite green: `LLMExtractionParserTest`, `EmailToLeadServiceTest`, `EmailToLeadHandlerTest`,
`PropertyClaimServiceTest`, `PropertyMatchingServiceTest`, `LLMExtractionCalloutServiceTest`,
`ExtractionRegressionFixtureTest`, and `ExtractAddressQueueableTest`'s five volume tests.

### 6.4 What is ONLY live-verifiable — say so plainly

**No Apex test can prove any of this.** The callout is mocked and the model is non-deterministic. Same posture
as the 2026-08-02 prompt tuning: **fixture-green + live UAT is the verification pattern.**

1. That the model actually READS the `Subject:` line and returns `call_for_offers`, `unit_count 432` and a
   non-empty `property_address` for Eden Prairie.
2. That body-over-subject precedence (D4) actually holds in the model's behaviour — i.e. that no email which
   already had a body address now returns a different, subject-influenced one. **This is the arbitration risk and
   it is only observable live.** UAT case D is the check; a re-send corpus is the ongoing one.
3. That the `RE:`/`FW:` sentence keeps prefixes out of `property_name`.
4. That D7's classification shift (both directions) is net-desirable on real traffic.
5. Whether the ≤270-char displacement ever costs anything in a > 40k body.

**Free regression corpus, per the standing note:** `Inbound_Email_Staging__c` rows are never deleted, so
`usman-dpeg` holds the raw body, headers and subject of every email this pipeline has processed, plus the
`Property_Key__c` each produced. Re-sending a handful of them (fresh Message-IDs) is a zero-cost, high-signal
key-drift check — and any NEW email shape found there should be added to `ExtractionRegressionFixtureTest`'s
`fixtures()`, which costs one entry.

### 6.5 UAT EMAIL MATRIX — `usman-dpeg`

⚠ **Always forward FRESH (a new Message-ID).** Asking the platform to redeliver the original is skipped by the
Message-ID idempotency guard and proves nothing.

| Case | Email | PASS condition |
|---|---|---|
| **A — Eden Prairie re-send** (THE case) | the original Eden Prairie email, forwarded fresh | `Extracted_JSON__c`: `email_category` = `call_for_offers`, `is_acquisition_related` = true at high confidence, `unit_count` = **432**, `property_address` = **`Suburban Chicago`** (non-empty), `property_name` = the full name, `offer_due_date` = **2026-08-18**, `asset_type` = `Multifamily`, `sale_process` = `Call for Offers`. **Routing: branch (e) WINNER** — a Lead **plus a `Property_Registry__c` row** plus a `Competing_Broker_Submission__c`; `Outcome__c` = `New Lead (winner)`. Lead carries `Property_Address__c` = `Suburban Chicago`, `Unit_Count__c` = 432, `Offer_Due_Date__c`, `Property_Name__c`. ⚠ **Note it is NOT branch (c) any more** — FIX 1 turns this email into a claim, which is the whole point. If the property is already in the registry from the incident run, clear that row (and its submissions) first, or expect branch (d). |
| **B — FIX 2's own case** | a broker email naming ONE property with no address in the subject OR the body (the `Royal Inn portfolio` fixture shape) | ONE Lead. `Outcome__c` = **`New Lead (property, no address)`**. `Property_Name__c` + every stated deal field stamped. **`Property_Address__c` BLANK.** **ZERO `Property_Registry__c` rows.** Deal Notes carries **no** duplicate footnote for that property. |
| **C — multi addressless** | one email naming 3 properties, none with an address anywhere | ONE Lead stamped with the FIRST; the other two listed under *"Additional properties in this email (not routed)"*; still zero registry rows; `Property_Count__c` = 3 |
| **D — no key drift** (D4's live proof) | re-send a previously-processed email that already owns a registry row **and** states its address in the BODY | the new `Extracted_JSON__c` `property_address` normalizes to the **SAME `Property_Key__c`**, and routing lands on branch (d) COMPETING (or (b) REPEAT if the same broker inside 90 days) — i.e. it FOUND the existing winner. **A NEW registry row means the key drifted → ROLL BACK FIX 1.** |
| **E — RE:/FW: noise** | subject `RE: FW: Eden Prairie Apartments` | `property_name` = `Eden Prairie Apartments` with no prefix; routing unchanged (a subject `RE:` must NOT by itself route as a reply — reply detection is header-based) |
| **F — blank subject** | an email with an empty subject | routing and extraction unchanged vs. today. (The sent body is not persisted, so the byte-identity claim is really **T2**; this is a live smoke confirmation only.) |
| **G — gate direction** (D7) | an out-of-office / auto-reply-shaped email the deterministic pre-filter does NOT catch | may now stamp `Not Acquisition (gated)` and create **no** Lead where it previously created one. Confirm that is desirable, and confirm **no genuine broker email** is gated. |

### 6.6 Rollback

- **FIX 1 prompt** — delete the one enriched paragraph. One constant, no data migration.
- **FIX 1 code** — revert `extractOrDegrade` to `staging.Raw_Body__c`. `buildLlmText` can stay dead or go.
- **FIX 2** — revert `routeNoProperty` to `createLead(extraction, null)`. Leads already stamped keep their
  fields (correct — the data is true); the `New Lead (property, no address)` label survives on historical staging
  rows and is **not** back-filled, exactly as the retired `Competing Duplicate` label was left.
- **No registry, claim or Lead data is written differently by FIX 2**, so nothing needs undoing.

---

## 7. PROMPTS FOR SPECIALIST AGENTS

### 🟢 PROMPT FOR `salesforce-developer`

```
Read agent-output/design-requirements-extraction-completeness.md and ARCHITECTURE.md §2 first.
Two surgical fixes to the LIVE Broker Protection pipeline. Touch ONLY the files listed in §5.

═══ FIX 1 — pass the SUBJECT to the LLM ═══

A) force-app/main/default/classes/ExtractAddressQueueable.cls
   1. Add a pure, @TestVisible private static method:
        String buildLlmText(String subject, String body)
      Format EXACTLY (design D2):
        - subject blank/null  -> return `body` BYTE-IDENTICALLY (no 'Subject:' line, no leading
          newline). This is the compatibility guarantee; get it exactly right.
        - body blank/null     -> return 'Subject: ' + oneLineSubject (no trailing separator).
        - otherwise           -> 'Subject: ' + oneLineSubject + '\n\n' + body
        - oneLineSubject      -> subject with every CR/LF run collapsed to a single space.
          This is NOT cosmetic: it is what stops an injected line beginning 'From:' from
          appearing ABOVE the outermost From: line and re-attributing a broker's claim.
      Javadoc it with that reasoning and with WHY it is @TestVisible (a prompt's effect is not
      unit-testable; its input is — same rationale buildWorkList already carries).
   2. In extractOrDegrade(), change the single call to:
        .extract(buildLlmText(staging.Subject__c, staging.Raw_Body__c), imageBase64, imageMimeType)
      DO NOT change the extract(...) signature. DO NOT change LLMExtractionCalloutService's
      buildRequestBody, MAX_INPUT_CHARS, or referenceDateLine(). The 40,000-char clip preserves the
      HEAD of the string, so prepending here makes the subject survive it unconditionally — record
      that in a comment.
   3. DO NOT repoint applyRegexFallback or applyEnvelopeEmailFallback at the composed text. They
      must keep reading staging.Raw_Body__c and the envelope.

B) force-app/main/default/classes/LLMExtractionCalloutService.cls — PROMPT TEXT ONLY
   🔴 DO NOT EDIT LEGACY_EXTRACTION_RULES OR LEGACY_RESPONSE_FORMAT. Both are byte-pinned by
   ExtractionRegressionFixtureTest and are the documented one-line rollback lever. A red fixture
   test means you touched them — stop.
   Add ONE paragraph at the TOP of ENRICHED_EXTRACTION_RULES, immediately after the
   '=== END OF THE ORIGINAL RULES ... ===' delimiter (it describes the SHAPE of the input, so
   everything after it depends on it). It must say:
     - the content begins with a single 'Subject:' line carrying the subject of the forwarded email
       as received, then a blank line, then the body;
     - the subject line IS part of the email's content and may be read for any extracted value —
       name property_name, property_address, unit_count, offer_due_date, asset_type, sale_process
       and the classification explicitly, because broker subjects routinely carry the deadline, the
       unit count, the asset name and the market;
     - BODY-OVER-SUBJECT PRECEDENCE: when the body and the subject both state a property address,
       the BODY wins; the subject may only supply an address the body does not state. (This is the
       claim-key protection — it makes it impossible for this change to re-key an email that
       already produces a key. Do not weaken or omit it.)
     - a leading RE: / FW: / FWD: / bracketed list tag is transport noise and is not part of
       property_name;
     - a DEFERRAL sentence in the same style as the existing 'BROKER vs LISTING BROKER',
       'sent_datetime WHEN NO DATE IS STATED' and broker_company paragraphs: this paragraph does not
       change WHICH 'From:'/'Sent:' line is authoritative for broker_name, broker_email or
       sent_datetime (a 'Subject:' line is neither), and it relaxes no anti-hallucination rule.
   Also add a dated 2026-08-03 note to the class header recording: the input now carries a
   Subject: line composed by ExtractAddressQueueable; the legacy block is untouched; and
   body-over-subject precedence is the reason this cannot re-key existing claims.
   Do NOT strip RE:/FW: in Apex — the prompt sentence handles it (design D5).
   Do NOT touch the deterministic pre-filter (SENDER_CONTAINS / SENDER_EXACT / the header
   patterns): "no subject-keyword filtering" is still the decision (design D6).

═══ FIX 2 — stamp unroutable properties onto the branch-(c) Lead ═══

force-app/main/default/classes/ExtractAddressQueueable.cls ONLY.
EmailToLeadService.cls is NOT changed — LeadRequest.property + applyPropertyBlock already do
exactly the right thing, and applyPropertyBlock already never writes the address.

   1. New public constant, next to the other OUTCOME_* constants:
        OUTCOME_NO_ADDRESS = 'New Lead (property, no address)'
      Javadoc it the way OUTCOME_NO_PROPERTY_LLM_DOWN is: a distinct label exists because the
      FOLLOW-UP differs — these are Leads carrying deal facts with NO first-broker-wins claim, and
      an admin must be able to list exactly them to chase an address. Outcome__c is free Text and
      historical rows are NOT back-filled (same precedent as the retired 'Competing Duplicate').
   2. routeNoProperty(extraction):
        - pick the FIRST non-null element of extraction.properties (the model's own order) as
          `stampable`; null when the list is empty;
        - recompute pendingSpillover EXCLUDING `stampable` (see 4);
        - pass `stampable` to createLead instead of null;
        - label: LLM-down still wins; else stampable != null ? OUTCOME_NO_ADDRESS
          : OUTCOME_NO_PROPERTY.
      Javadoc: state that NO ordering guarantee is claimed and none is needed — branch (c) takes no
      lock and derives no claim key, so the class header's "the model's array order is not stable"
      warning (which governs LOCK ORDERING) does not apply here. Say so, or someone will later
      "harden" it and couple it to buildWorkList's sort.
   3. createLead(...): replace
        request.propertyAddress = (property == null) ? null : property.propertyAddress;
      with a small private static helper claimableAddress(PropertyExtraction) that returns null
      unless PropertyMatchingService.normalizeAddress(property.propertyAddress) is NON-BLANK.
      Reason (design D12): normalizeAddress strips every non-alphanumeric, so '###' is non-blank
      raw but normalizes to empty — without the guard, punctuation would be stamped into
      Lead.Property_Address__c. This encodes the invariant "Lead.Property_Address__c only ever holds
      an address that COULD have produced a claim key". Branches (b)/(d)/(e) are unaffected.
      NEVER fabricate an address, never synthesize one from property_name or the subject.
   4. buildSpilloverNote(extracted, overflow) gains a third parameter
      `PropertyExtraction exclude` (compare by OBJECT IDENTITY, not value). routeProperties passes
      null (unchanged behaviour); routeNoProperty passes `stampable`. Without this the footer says
      "Additional properties in this email (not routed): - Eden Prairie (no usable address)" on the
      very Lead whose Property Name reads "Eden Prairie" — a visible contradiction.
   5. Class header: update the ROUTING TREE block's branch-(c) line and step 8, note that the LLM
      input is now subject + body, and record the residual verbatim: an address-less property CANNOT
      claim, so these Leads have NO first-broker-wins protection until an address exists — a later
      broker who submits the same property WITH an address wins it outright.

═══ HARD CONSTRAINTS ═══
- ZERO new SOQL and ZERO new DML. The existing governor-headroom assertions
  (lastRunQueryCount / lastRunDmlCount in execute_tenPropertyEmail_...) must stay green AT THEIR
  CURRENT NUMBERS. If you need to relax them, the change is wrong.
- Do not touch: EmailToLeadService, LLMExtractionParser, PropertyMatchingService,
  PropertyClaimService, InboundEmailStagingService, InboundEmailFieldUtil, EmailToLeadHandler, or
  ANY metadata file.
- Do not modify ExtractionRegressionFixtureTest or LLMExtractionCalloutServiceTest.
- ARCHITECTURE.md §6 requires same-PR doc updates: amend the §2 "Broker Protection staging model"
  paragraph (branch (c) now stamps the first property's block; new outcome label) and the
  LLMExtractionCalloutService §2 row (the extraction input is now the subject line + body + image).
- Do not deploy. Run no org commands.
```

### 🟡 PROMPT FOR `salesforce-unit-testing`

```
Add tests to force-app/main/default/classes/ExtractAddressQueueableTest.cls for the two changes in
agent-output/design-requirements-extraction-completeness.md §6.2 and §6.3. Do not modify
ExtractionRegressionFixtureTest or LLMExtractionCalloutServiceTest.

FIX 1 (T1-T6): buildLlmText is @TestVisible and pure — pin its EXACT output as a string; blank
subject returns the body BYTE-IDENTICALLY (the compatibility guard); blank body returns the subject
line alone; a multiline subject collapses to one line (assert no line begins 'From:'); and
InboundEmailFieldUtil.clip(buildLlmText(subject, 60k body), 40000) still startsWith('Subject: ')
AND still contains the outermost From:/Sent: lines. Add ONE end-to-end test asserting the sent
request body contains the subject line.
⚠ mock.lastRequest is only proven SYNCHRONOUSLY in this repo. If it does not survive the
Test.stopTest() async boundary, use a test-local HttpCalloutMock with a STATIC capture field —
the VolumeMock class already inside this test file is the in-file precedent. T1-T5 are the real
guarantee; do not let the end-to-end test block the change.

FIX 2 (T8, T11, T12, T14): an addressless NAMED property stamps the block but claims nothing
(Property_Address__c IS NULL, 0 Property_Registry__c, 0 Competing_Broker_Submission__c, Outcome__c
= ExtractAddressQueueable.OUTCOME_NO_ADDRESS); three addressless properties stamp the FIRST and
footnote the other two WITHOUT repeating the stamped one; an un-normalizable address ('###') leaves
Property_Address__c null while the rest of the block is stamped; a HARD-gated email carrying an
addressless property still creates NO Lead.

DO NOT MODIFY these three existing tests — they are the regression guards and must pass unchanged:
execute_noExtractableAddress_createsPlainLeadWithoutClaimingAnything (zero properties -> still
OUTCOME_NO_PROPERTY), execute_llmCalloutFails_... (still OUTCOME_NO_PROPERTY_LLM_DOWN), and
execute_newUnclaimedProperty_... (branch (e) still stamps Property_Address__c verbatim).

BULK-TEST RULE: this class is DE-EXEMPTED (C-18) and its five replacement volume tests already
exist at the bottom of the file. Do not add a 251-record test — a literal 251 is impossible here
(System.enqueueJob caps at 50; SOQL exhausts at ~14-24 properties). Keep all five green at their
current governor budget. Record that reasoning in any new test's comment so review does not demand
it. Use TestDataFactory and the existing insertStaging/setMock helpers. Assert.* style.
```

### 🟣 `salesforce-code-review` — flag for the reviewer

Three things worth the reviewer's specific attention:

1. **D4 body-over-subject precedence** is the only thing standing between this change and a re-keyed claim
   ledger. Confirm the sentence is present, unhedged, and in the enriched block.
2. **`claimableAddress`** must not alter branches (b)/(d)/(e). Confirm `execute_newUnclaimedProperty_...` passes
   unmodified.
3. **Governor budget** — confirm `lastRunQueryCount` / `lastRunDmlCount` assertions are unchanged, not relaxed.

---

## 8. RESIDUALS — accepted, not mitigated

| # | Residual | Why it is accepted |
|---|---|---|
| **R1** | A subject-derived COARSE address (`Suburban Chicago`) becomes a permanent claim key. A later PRECISE address for the same asset will not clear the 0.6 Jaccard threshold, so one property can end up with two registry rows and two "winners". | Strictly better than today's **zero** protection, and it is not a new failure class — two differently-worded addresses already do this. The user explicitly wants the claim taken. A human merges the duplicate. |
| **R2** | A `New Lead (property, no address)` Lead has deal facts and **no** first-broker-wins protection; a later broker with an address wins the property outright. | Unavoidable — an address-less property cannot claim without writing a guess into a permanent unique-keyed ledger. Mitigation is the new outcome label, which makes the population listable so a human can chase the address. |
| **R3** | Prompt behaviour is un-unit-testable. | Established pattern: fixture-green + live UAT (2026-08-02 precedent). §6.4 names exactly what only live traffic can prove. |
| **R4** | D7's classification shift can now HARD-gate an email that previously produced a junk Lead. | That is the gate working as designed; it requires the model to be **confidently** wrong. UAT case G watches it. |
| **R5** | The `Subject:` line displaces ≤ ~270 chars of quoted history from a > 40k body. | Same trade C-15 already accepted, an order of magnitude smaller. |
