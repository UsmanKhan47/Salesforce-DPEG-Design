# Design — Broker Protection LLM prompt tuning (3 extraction defects)

**Date:** 2026-08-02 · **Scope:** `LLMExtractionCalloutService.cls` only · **Routing:** `salesforce-technical-architect`
**Evidence:** staging row `a0aiw000000NEK1AAO` (usman-dpeg) — raw body + `Extracted_JSON__c` read from the org.
**This doc does NOT supersede `agent-output/design-requirements.md`** (the C-1..C-22 extraction contract). It is additive.

---

## 🎯 WHAT WAS REQUESTED

Three prompt-rule additions to fix three observed extraction defects. No schema change, no new fields, no parser change.

| # | Defect (observed) | Rule requested |
|---|---|---|
| 1 | `property_name` returned `""` although the name is the first three words of the body, and the model wrote "Orion ParkView" into its own `deal_summary`. Reproduced on two consecutive live emails. | Define `property_name` explicitly (marketing/brand name; subject line, first sentence, or flyer headline; distinct from `property_address`), with an example. |
| 2 | `offer_due_date` `2023-08-11` — no date exists anywhere in the body or flyer. Training-data recall of the real 2023 JLL campaign. | Year-less dates resolve against the email's received/processing date, never world knowledge. |
| 3 | `sent_datetime` `2023-08-11 00:00:00` — same fabrication, and it is **not** gated, so it flowed to `Competing_Broker_Submission__c.Submitted_DateTime__c` ("Aug 11, 2023"). | `sent_datetime` must come from explicit content (a `Sent:`/`Date:` header line or a date written in the body); if absent → EMPTY. Never inferred. |

---

## 🔎 FINDINGS THAT CHANGE THE DESIGN

### F1 — The fabricated `sent_datetime` is worse than a display-order bug: it breaks REPEAT DETECTION

`Submitted_DateTime__c` is not only the timeline sort key. It is the **recency filter behind repeat detection**:

- `PropertyMatchingService.findBrokerSubmission()` → `CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(brokerEmail, Datetime.now().addDays(-LOOKBACK_DAYS))`, `LOOKBACK_DAYS = 90`, `WHERE Submitted_DateTime__c >= :cutoff`.
- A row stamped 2023 sits **outside** that window. When the same broker re-sends the same property, the prior submission is invisible → the **REPEAT branch never fires** → their follow-up is routed as a fresh competing submission instead of a repeat.

Winner determination itself is unaffected (that fuzzy path keys off `Property_Registry__c` recency, not the submission). But this is an arbitration-behaviour defect, not cosmetics — it raises the priority of rule 3 above rules 1–2.

### F2 — Blank `sent_datetime` fallback today: `Datetime.now()`, and it is ACCEPTABLE (no code touch required)

`ExtractAddressQueueable.parseSentDatetime(String raw)` (~line 1338): blank or unparseable → `Datetime.now()`, evaluated **inside the queueable**, i.e. within seconds of the `Inbound_Email_Staging__c` row being written at the email boundary. That value is passed as `submittedOn` into every `PropertyClaimService` write (`claim` / `markDuplicate` / `logRepeatSubmission` → `buildSubmission`).

**Verdict: acceptable as-is.** Approximate receipt time keeps rows inside the 90-day window and preserves relative order across competing brokers (processing order ≈ receipt order). Rule 3 therefore ships **prompt-only** — no code change needed to make it safe. See Optional O1 for the strictly-better source if the user wants it.

### F3 — Rule 2 is not expressible without a reference date

The prompt currently carries **no notion of the current date**, and the model has none. "Resolve against the received date" is un-actionable unless we tell it the received date. Two anchors are available:

- **In-content anchor** — the forward's own outermost `Sent:` / `Date:` line (present on most forwards; this is what the legacy rule already reads). Zero code.
- **Injected anchor** — a `REFERENCE DATE` line added at request-build time. Needed for emails like Orion, whose body carries **no date at all**.

Without the injected anchor, a year-less deadline in a date-less email must be dropped (null), losing a legitimately extractable field. Recommendation below takes both.

### F4 — Nothing in the test suite blocks these edits

`ExtractionRegressionFixtureTest` pins `LEGACY_EXTRACTION_RULES` with `startsWith` / `contains` assertions plus the `LEGACY_EXTRACTION_RULES + LEGACY_RESPONSE_FORMAT` rollback composition. `LLMExtractionCalloutServiceTest` asserts `contains` on the request body (`max_tokens`, `response_format`, `model`, `temperature`, `image_url`) and `sentBody.length() < 80000`. **Additions to the enriched block and a ~150-char reference-date line break none of them** — provided `LEGACY_EXTRACTION_RULES` is not touched.

---

## ✅ DECISIONS

### D1 — `property_name` definition → **ENRICHED block**

`property_name` is a per-property enriched key, not one of the four legacy claim values. Zero arbitration exposure. Add it as a new bullet immediately before the `MULTIPLE PROPERTIES` paragraph (it defines a per-property field, so it belongs with the per-property rules), including the requested one-line example and the explicit "distinct from `property_address`" contrast plus a "leave empty rather than invent one" clause.

### D2 — Year-less date resolution → **RECEIVED-YEAR ANCHORING with a bounded roll-forward**, in the **ENRICHED block**

**The rule (recommended, state it verbatim in the prompt):**

> Determine the anchor date A = the year-bearing `Sent:` / `Date:` line in the email if one exists, otherwise the supplied REFERENCE DATE. Give a year-less date the year of A. Only if the result falls **more than 30 days before A** does it take A's year + 1. Never roll a year backward, and never use knowledge of when a real-world campaign or listing happened.

**Why not next-future-occurrence** (the rejected alternative): it silently rolls "August 1st" received August 2 forward to **August 1 next year** — fabricating a deadline ~364 days out that the parser's plausibility gate happily accepts (`OFFER_DATE_MAX_FUTURE_DAYS = 730`). That converts a harmless already-expired date into a plausible-looking wrong one, which is the exact failure mode this change exists to remove. Received-year anchoring yields `2026-08-01` for that case — one day past, truthful, and informative on the Lead.

**Interaction with the existing plausibility gate** (`LLMExtractionParser.offerDate`, `Date.today() - 365` .. `Date.today() + 730`): **unchanged, and it stays the safety net.** Note the asymmetry that let this defect through — `offer_due_date` is gated (it correctly rejected 2023-08-11 and filed the audit note in Deal Notes), **`sent_datetime` is gated by nothing**; `parseSentDatetime` accepts any parseable GMT value including 2023. That is why D3 is the load-bearing fix and D2 mostly protects `offer_due_date`. The 30-day grace is deliberately far inside the gate's ±window, so the two rules cannot fight.

**Placement:** extend the existing `- Relative deadlines are resolved against sent_datetime: ...` bullet in the enriched anti-hallucination list. Same subject, same block.

### D3 — `sent_datetime` must be explicit-or-empty → **ENRICHED block, as a deferring clarification. `LEGACY_EXTRACTION_RULES` is NOT edited.**

**Why not the original block**, even though `sent_datetime` is a legacy value:

1. `LEGACY_EXTRACTION_RULES` is marked `DO NOT EDIT`, is byte-pinned by `ExtractionRegressionFixtureTest`, and is diffable against git history on purpose.
2. Editing it destroys the documented **one-line rollback** (`EXTRACTION_INSTRUCTION = LEGACY_EXTRACTION_RULES + LEGACY_RESPONSE_FORMAT`).
3. It is **not a new behaviour**: the legacy block already ends *"If a value is absent, use an empty string."* Rule 3 is an emphasis on that existing sentence, not a replacement for it.

**Required wording constraints** (carry these into the dev prompt verbatim):

- Phrase it as a restatement that **defers** to the original rule — the same pattern the existing `BROKER vs LISTING BROKER` paragraph already uses.
- It may only ever **narrow `sent_datetime` toward empty**. It must not change *where* the value is read from: "the OUTERMOST / EARLIEST `Sent:` line" stays authoritative.
- It must **not mention `broker_name`, `broker_email` or `property_address` at all** — those are untouched by this change and any new sentence naming them is a claim-engine edit.

### D4 — REFERENCE DATE injection (the one code touch beyond string constants)

Add to `buildRequestBody`, between `EXTRACTION_INSTRUCTION` and the clipped email text:

- One labelled line carrying `Datetime.now()` formatted `yyyy-MM-dd` in GMT.
- It **must** state that it is context only — *"Use it ONLY to resolve a year-less date. It is NOT a value to extract; it is never `sent_datetime`."* This is the single hazard of the injection and is a named UAT check below.

No signature change (`extract(textContent, imageBase64, imageMimeType)` is untouched), no caller change, no parser change, no new constant contract. The ASB re-homing promise in the class header is unaffected.

**Zero-code variant if the user wants the absolute minimum:** drop D4 and anchor D2 on the in-content `Sent:`/`Date:` line only, returning null when the email carries no date. This still fixes the Orion case (its body has no date, so the correct answer is null either way) but drops year-less deadlines in date-less emails. **Recommend taking D4.**

---

## 🔵 ADMIN WORK

No admin work required for this request. No fields, objects, permissions or layouts change.

---

## 🟢 DEVELOPMENT WORK — prompt for `salesforce-technical-architect`

```
Edit force-app/main/default/classes/LLMExtractionCalloutService.cls ONLY. No other class,
no metadata, no test changes. Read agent-output/design-requirements-prompt-tuning.md first.

DO NOT EDIT LEGACY_EXTRACTION_RULES or LEGACY_RESPONSE_FORMAT. Both are pinned by
ExtractionRegressionFixtureTest and are the one-line rollback lever. All three rule
additions go in ENRICHED_EXTRACTION_RULES.

1. property_name (new bullet, immediately before the "MULTIPLE PROPERTIES" paragraph):
   define property_name as the marketing / brand name of the property — typically the
   subject line, the first sentence of the body, or the headline of an attached flyer
   image — explicitly distinct from property_address. Include a one-line example of the
   "Orion ParkView" shape (name vs address). State that it is left empty if the email
   gives the property no name; never invent one.

2. Year-less dates: EXTEND the existing bullet
   "- Relative deadlines are resolved against sent_datetime: ..."
   with the received-year anchoring rule from D2 —
     anchor A = the year-bearing "Sent:"/"Date:" line if one exists, else the supplied
     REFERENCE DATE; a year-less date takes A's year; it takes A's year + 1 ONLY if it
     would otherwise fall more than 30 days before A; never roll a year backward; never
     use knowledge of when a real-world campaign or listing happened.
   Do not change the existing auction-date-range or "yyyy-MM-dd" sentences.

3. sent_datetime (new short paragraph in the enriched block, worded to DEFER to the
   original rules, in the same style as the existing "BROKER vs LISTING BROKER"
   paragraph): sent_datetime must come from explicit content — a "Sent:" or "Date:"
   header line, or a date written in the body. If the email states no send date, return
   an EMPTY STRING. Never infer it from knowledge of the property, campaign or listing.
   HARD CONSTRAINTS on this paragraph: it may only narrow the value toward empty; it must
   NOT restate or alter where the value is read from (the OUTERMOST / EARLIEST "Sent:"
   line stays authoritative); it must NOT mention broker_name, broker_email or
   property_address.

4. REFERENCE DATE injection in buildRequestBody: between EXTRACTION_INSTRUCTION and the
   clipped email text, insert one labelled line carrying Datetime.now() formatted
   'yyyy-MM-dd' in GMT, stating that it is the date this email was received, that it is
   to be used ONLY to resolve a year-less date, and that it is NOT a value to extract and
   is never sent_datetime. Do not change the extract(...) signature, the parts ordering
   (image part first when present), MODEL, temperature, MAX_TOKENS, response_format,
   MAX_INPUT_CHARS or MAX_PROPERTIES_IN_PROMPT.

5. Class header: add a short dated note (2026-08-02) recording the three prompt rules,
   that they are additive to the enriched block, that the legacy block is untouched, and
   that the request now carries a dynamic reference-date line. Per ARCHITECTURE.md §6,
   update the LLMExtractionCalloutService row in §2 ONLY if a convention changed —
   nothing here changes a convention, so no §2 edit is expected.

Do not deploy. Run no org commands.
```

**Unit testing agent:** not invoked — no new behaviour is unit-testable here (tests mock the callout; fixtures pin the parser, not the model). Existing suite must stay green unchanged.

---

## 🔗 VERIFICATION PLAN

**Automated (necessary, not sufficient):** full existing suite green, unchanged. Specifically `ExtractionRegressionFixtureTest` (legacy block byte-pinned + rollback lever intact), `LLMExtractionCalloutServiceTest` (`max_tokens` / `response_format` / `model` / `temperature` / image-part / 80k-length assertions), `LLMExtractionParserTest`, `ExtractAddressQueueableTest`. A red fixture test means the legacy block was touched — stop, do not deploy.

**Live UAT on usman-dpeg — two emails, because one cannot prove both directions:**

⚠ **Read this before re-sending Orion.** The Orion property is already claimed in `Property_Registry__c`, and its existing submission row is stamped 2023 — which is outside the 90-day repeat window (F1). A plain re-send will therefore route to branch (d) COMPETING SUBMISSION, **create no Lead**, and the "Property Name populated" check will have nowhere to land. So:

- **Verify on the new `Inbound_Email_Staging__c` row's `Extracted_JSON__c`** — it is written on every branch, so it is the branch-independent check. This is the primary evidence.
- Forward the email **fresh** (new Message-ID). Do not ask the platform to redeliver the original — the Message-ID idempotency guard will skip it.
- Only if a Lead-level check is wanted: clear the Orion `Property_Registry__c` row (and its submissions) first so the re-send routes as WINNER.

| Case | Email | PASS condition |
|---|---|---|
| **A — Orion re-send** (fixes 1 + 3) | The original Orion ParkView email, forwarded fresh | `property_name` = `"Orion ParkView"` (defect 1 fixed). `sent_datetime` = `""` — **empty is the correct answer**, the body carries no date at all. `offer_due_date` = `null` for the same reason (**not** 2026-08-11 — nothing in the content to anchor). The new `Competing_Broker_Submission__c` row's Submitted timestamp shows **today**, not Aug 2023. `property_address` still normalizes to the SAME `Property_Key__c` as the existing registry row — if it drifts, roll back. |
| **B — year-less deadline** (proves rule 2 positively) | A test broker email whose body says "offers due Tuesday, August 11th" with no year, and no `Sent:` line | `offer_due_date` = `2026-08-11` (received-year anchor). `sent_datetime` = `""` — confirms the REFERENCE DATE line was **not** harvested as a send time (the D4 hazard). |

**Rollback:** revert the single class. The enriched-block additions and the reference-date line are independent of every other component; no data migration, no dependent deploy.

---

## 📌 OPTIONAL FOLLOW-UPS — out of this change's scope, user decision required

Listed only because the investigation surfaced them. **None are included in the prompt above.**

- **O1 — anchor the blank-`sent_datetime` fallback on the staging row's `CreatedDate` instead of `Datetime.now()`.** `CreatedDate` is the true boundary receipt time and is stable under queueable retry or reprocessing, where `now()` is not. Cost: add `CreatedDate` to `InboundEmailStagingSelector.selectById`'s field list and one ternary in `parseSentDatetime`. Worth more *after* this change than before it, because rule 3 makes a blank `sent_datetime` common where the model previously always fabricated one. F2 says the current fallback is acceptable, so this is hardening, not a fix.
- **O2 — plausibility guard on `sent_datetime`, the one input with no gate at all.** Unlike O1 this *is* unit-testable, and it is defence-in-depth for exactly the failure that occurred. Nuance that makes it genuinely optional: a broker legitimately forwarding a two-year-old thread would produce a truthfully old timestamp, and suppressing that is arguably wrong.
- **O3 — the existing 2023-stamped Orion submission row is not corrected by this change.** No backfill was requested and none is proposed.
