# Broker Protection — LLM Field Extraction Enrichment

**Date:** 2026-07-31
**Author:** Documentation Agent
**Status:** Code-reviewed, APPROVED WITH WARNINGS. Deployed behavior described below; see "Known-Open
Items" for what remains unaddressed.
**Companion docs:** `docs/2026-07-31-competing-broker-no-lead.md` (the immediately-prior change this
one builds on top of), `docs/broker-protection-architecture.md`, `docs/broker-protection-data-dictionary.md`,
`docs/broker-protection-operations.md`, `docs/broker-protection-faq.md`, `docs/broker-protection-overview.md`
(all updated in this same pass), `ARCHITECTURE.md` §1/§2 (updated by the implementing agent, not this
pass).

---

## 📋 Overview

### Original Request

> Source analysis: a 2026-07-30 review of `Acquisition-Emails.pdf` against the Lead object found 19
> missing deal-screening fields and 2 missing `Asset_Type__c` picklist values ("Comprehensive" scope
> approved by the user). Enrich the Broker Protection inbound-email pipeline to extract the full
> deal-screening field set from broker emails via the LLM (not just broker identity + one address),
> gate out non-acquisition email so it stops producing junk Leads, and support multiple properties per
> email — a broker blast pitching two or more properties should produce one Lead per property, not one
> Lead for the first address found. Four decisions were made final up front (D1–D4): one Lead per
> property; a tiered relevance gate (confident non-acquisition → no Lead, uncertain → Lead flagged for
> review); two-tier storage (the LLM's raw JSON verbatim on the staging row, typed values on the Lead);
> and PDF/OM attachment parsing explicitly out of scope for this iteration.
> *(Source: `agent-output/llm-field-extraction-spec-2026-07-31.md`.)*

### Business Objective

The pipeline previously extracted only four values from a broker email — broker name, broker email,
one property address, and a send time — which was enough to run the first-broker-wins claim engine but
left every deal-screening fact (asking price, cap rate, NOI, occupancy, offer deadline, asset type,
and a dozen more) sitting unread in the email body, to be re-typed by hand from the raw text on every
Lead. At the same time, non-acquisition email (Gmail forwarding confirmations, newsletters,
out-of-office replies) was indistinguishable from real deal flow to the pipeline, so it minted a Lead
for those too. This change closes both gaps at once: the same LLM call that already reads the email
now extracts the full deal-screening field set structured and typed, a relevance gate stops the
pipeline from creating Leads for email that plainly isn't a deal, and a broker blast pitching several
properties correctly produces a Lead per property instead of just the first one found.

### Summary

The LLM prompt grew from a tight four-key instruction to a ~20× larger one returning an email-level
classification block (category, `is_acquisition_related`, a 0–1 confidence number, full broker
identity including a separate "listing broker" for blast-platform emails where the sender isn't the
broker) plus a `properties` array — one object per property, each carrying 23 deal-screening keys
(name, address, asset type, financials, physical characteristics, process). A new pure-coercion class,
`LLMExtractionParser`, turns that JSON into a typed `LLMExtractionResult`/`PropertyExtraction` object
graph that **never throws** — every unparseable or out-of-range value becomes a typed `null` plus a
human-readable note, which the writer appends to `Deal_Notes__c` instead of silently vanishing. 19 new
Lead fields (`Property_Name__c`, `NOI__c`, `Occupancy_Pct__c`, `Guidance_Price_Low__c`/`High__c`,
`Offer_Due_Date__c`, and 14 more) plus 2 new `Asset_Type__c` restricted-picklist values (Hospitality,
Medical Office, added on both `Lead` and `Property__c`) carry the extracted data. The raw JSON is
stored verbatim on a new `Inbound_Email_Staging__c.Extracted_JSON__c` field *before* any routing
decision, so it survives every branch — including the ones that create no Lead. A tiered relevance
gate suppresses a Lead entirely for a confidently non-acquisition email, while anything less certain
still creates a Lead flagged `Parse_Confidence__c = LOW` for human review. The routing tree was
restructured from one linear pass into a prologue (Reply detection and a deterministic pre-filter, both
skipping the LLM callout entirely), a per-property loop (processed in a specific, deadlock-avoiding
order — up to 10 properties per email), and an epilogue (one Task per distinct routed record, staging
stamped with the full N-result audit).

### A note on scope and sequencing

This change was built directly on top of `docs/2026-07-31-competing-broker-no-lead.md` (Change 1) —
the "no Lead for a competing broker" behavior is unaffected by this enrichment; it simply now runs
once per property instead of once per email. PDF/OM attachment parsing was explicitly deferred (D4);
this change extracts only from the plain-text/HTML body and an optional single inline image, exactly
as the pipeline already did.

---

## 📜 The Extraction JSON Contract

### Why the legacy four keys are still load-bearing

The first-broker-wins claim engine arbitrates on exactly two extracted values — `broker_email` (repeat
detection and submission attribution) and `property_address` (normalized into the unique
`Property_Registry__c.Property_Key__c`, the claim identity). Both used to come from a tight,
in-production four-key prompt. **Rewriting the prompt is therefore a silent behavior change to the
claim engine**, not merely a field-enrichment exercise: a subtly differently-worded address produces a
different claim key, and the 0.6 Jaccard fuzzy threshold may or may not rescue it. The failure mode is
invisible — a competing broker quietly *wins* a property they lost, or a repeat registers as a new
claim — with no exception, no error row, and no failing test to catch it by accident.

Three structural protections address this, all stated in `LLMExtractionCalloutService`'s class header
and enforced by `ExtractionRegressionFixtureTest`:

1. **`LEGACY_EXTRACTION_RULES` is the pre-enrichment instruction verbatim and first**, in its own
   delimited block, ahead of every new instruction — not paraphrased, not reordered.
2. **`MODEL` (`gpt-4o-mini`) and `temperature` (0) are unchanged.** Changing the model at the same time
   as the prompt would make any regression impossible to attribute to one cause or the other.
3. **Rollback is one line.** Setting `EXTRACTION_INSTRUCTION = LEGACY_EXTRACTION_RULES +
   LEGACY_RESPONSE_FORMAT` reverts the pipeline to the original four-key contract with no other code
   change — `LLMExtractionParser` already tolerates a response with no `properties` array by
   synthesizing a one-element array from a top-level `property_address` (`usedLegacyShape = true`).

### The schema

Email-level keys, once per response:

| Key | Destination | Notes |
|---|---|---|
| `email_category` | `Extracted_JSON__c` only | Closed set: `acquisition_deal`, `call_for_offers`, `reply`, `system_notification`, `newsletter`, `out_of_office`, `other`. Drives nothing except explainability. |
| `is_acquisition_related` | gate input | `true`/`false`/absent. `null` (the model didn't say) is never treated as `false` — the hard gate fires only on an explicit `false`. |
| `confidence` | `Parse_Confidence__c` (via band) | A number 0.00–1.00. Apex, not the model, derives the HIGH/MEDIUM/LOW band — see "The Tiered Relevance Gate" below. |
| `broker_name` / `broker_email` | **claim engine input, legacy keys** | The forwarding/original broker per the outermost `From:` line. Untouched by the enrichment. |
| `broker_company` / `broker_phone` / `broker_mobile` / `broker_title` | `Company`/`Phone`/`MobilePhone`/`Title` | New. `Company` still falls back to the placeholder `'Unknown - Via Email'` when blank (required field, never written blank). |
| `listing_broker_name` / `listing_broker_email` | `Listing_Broker_Name__c` / `Listing_Broker_Email__c` | **Not** a claim-engine input. The blast-platform case (RCM/Crexi-style mailers) where the sender is not the actual listing broker. |
| `sent_datetime` | claim engine input, legacy key | Unchanged: UTC `yyyy-MM-dd HH:mm:ss`. |
| `deal_summary` | `Deal_Notes__c` (narrative section) | ≤ 800 chars (prompt-capped). Carries roof/lien/tenant detail, reported-vs-adjusted NOI notes, and spillover for properties beyond the 10-property cap. |

Per-property keys, one object per property in the `properties` array (23 keys — see
`LLMExtractionCalloutService.ENRICHED_EXTRACTION_RULES` for the exact JSON shape sent to the model):
`property_name`, `property_address` (legacy key, the claim identity), `asset_type`, `deal_type`,
`sale_process`, `guidance_price`, `guidance_price_low`/`high`, `cap_rate`, `noi`, `occupancy_pct`,
`building_sf`, `lot_size_acres`/`lot_size_sf`, `unit_count`, `year_built`, `year_renovated`,
`walt_years`, `adr`, `zoning`, `seller_entity`, `deal_room_link`, `offer_due_date`.

### Anti-hallucination rules (in the prompt, enforced again by the parser)

- **Never derive one number from another.** No computing price from cap rate + NOI, no converting
  square feet to acres or vice versa. `lot_size_acres` is reported only when the email states acres;
  `lot_size_sf` only when it states square feet — **Apex** converts sq ft → acres (÷ 43,560) when only
  the SF value is present, never the model, because asking a language model to do arithmetic is asking
  it to hallucinate.
- **Numbers are plain numerics.** `"$7.1M"` must become `7100000` in the model's response — but Apex
  (`LLMExtractionParser.toDecimal`) re-parses currency-formatted strings anyway (`$`, commas, `K`/`M`/
  `MM`/`B` suffixes) as a defense-in-depth backstop, since the model does not always comply.
- **`cap_rate` / `occupancy_pct` are percentage numbers** — `6.75` means 6.75%, never the fraction
  `0.0675`. The parser rejects anything outside `[0, 100]` and **deliberately has no "assume a
  fraction if ≤ 1" heuristic** — a 0.9% cap rate is implausible but a 0.9 occupancy fraction is not,
  and the same heuristic can't be right for both, so guessing would silently corrupt one of them.
- **Two-digit years are expanded by Apex**, not the model: `'88'` → 1988, `'22'` → 2022, pivoting on
  the current two-digit year.
- **Reported vs. adjusted NOI**: the adjusted figure lands in `noi`; both are mentioned in
  `deal_summary`.
- **Relative deadlines** ("offers due TODAY") are resolved by the **prompt** against `sent_datetime` —
  never by Apex, which has no reliable notion of the email's local day.
- **Closed-set fields must be a listed value or `null`**, never invented.

### The parser — never throws, always records why

`LLMExtractionParser.parse(rawContent)` is a total function: a malformed payload, a missing key, a
string where a number was promised, a 300-character URL — all resolve to a typed `null` plus a note in
`LLMExtractionResult.notes`, never an exception. Throwing here would abort the routing transaction and
lose a broker's claim over a formatting mistake by a language model, which is why this is a hard
invariant, not a best-effort one. A few rules worth knowing operationally:

- **Restricted picklists (`asset_type`, `deal_type`, `sale_process`) are validated against
  `Schema.describe`'s ACTIVE values at RUNTIME**, not compile time — because Apex compiles a picklist
  reference regardless of whether its values exist, so a code-first deploy would go green and then
  throw `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` on the first Hospitality email, rolling back a real
  claim. This is why the metadata (picklist values) had to deploy and be **verified in the org** before
  any of this Apex did. Values are cached per-transaction (`PICKLIST_CACHE`) so a 10-property email
  doesn't re-describe 30 times.
- **`deal_room_link` is never clipped, only nulled.** A truncated URL is a broken link that still looks
  valid — worse than no link at all — so an over-length one is dropped with a note rather than
  silently mangled.
- **Every other rejection is recorded**, not silently dropped: `LLMExtractionResult.notes` accumulates
  up to 60 human-readable reasons (`'guidance_price_low "$-500" was ignored: a negative amount.'`),
  which `EmailToLeadService` appends to `Deal_Notes__c` under a `-- Extraction notes --` header. That
  is the entire point of validating rather than trusting: a rejected value becomes something a person
  sees on the record instead of vanishing.

### Response-size safety (why `MAX_TOKENS` moved from 512 to 4096)

The old four-key response comfortably fit in 512 tokens. The enriched contract does not: roughly 150
tokens of email-level block, plus 200–260 per property object, plus up to 400 for the narrative — three
properties is already ~1,150 tokens, ten is ~2,900. A truncated response is cut mid-object, which used
to throw `JSONException` and — because the degrade catch was narrowed to `CalloutException` only — land
the email in `Status = 'Error'` with **no Lead, no Task, no claim at all**, strictly worse than an
outage. Four changes work together to prevent and then survive this:

1. `MAX_TOKENS` **512 → 4096** (well inside gpt-4o-mini's 16k output ceiling).
2. `response_format: {"type": "json_object"}` — OpenAI JSON mode, which **guarantees** syntactically
   valid JSON. The single strongest mitigation; it also demotes the existing `stripCodeFences` helper
   from load-bearing to belt-and-braces.
3. Prompt-level caps: `deal_summary` ≤ 800 chars, at most 10 property objects (the model is told to
   describe any remainder in `deal_summary`).
4. **The degrade catch was deliberately widened to also catch `JSONException`** (a documented reversal
   of the prior narrow-catch decision, called out explicitly in `ExtractAddressQueueable`'s class
   header so a future reader does not "restore" the old comment). With an 8× larger response, a
   malformed reply is no longer "a defect in our own contract" — it is the same category of event as
   an outage: an absent optional input. Degrading loses the address; erroring loses the whole email.

Also raised: `TIMEOUT_MS` 30000 → 60000 (a 10-property extraction is materially slower; the platform's
per-callout ceiling is 120s). The LLM input body is now clipped to 40,000 characters
(`MAX_INPUT_CHARS`) before sending — safe because the outermost `From:`/`Sent:` lines a forward's
legacy fields depend on sit at the *top* of the body, which is exactly what
`ExtractionRegressionFixtureTest.inputClip_neverRemovesTheOutermostFromAndSentLines` asserts.

Cost is explicitly **not** the constraint here: ~10k input + ~1.5k output on gpt-4o-mini is about
$0.0024/email, roughly $36/month at 500 emails/day. Shrinking the prompt "for cost" would trade a
trivial saving for the truncation failure this section exists to prevent.

---

## 🚪 The Tiered Relevance Gate

| Condition | Action | Lead? | Claim? | Staging `Outcome__c` |
|---|---|---|---|---|
| Reply (In-Reply-To/References match an existing thread) | **Always wins, never gated** | No (files on existing record) | n/a | `Reply Thread` |
| Deterministic pre-filter hit (automated sender or auto-reply header) | HARD, no callout | ❌ | ❌ | `Not Acquisition (pre-filtered)` |
| `is_acquisition_related = false` **and** confidence ≥ 0.85 (HIGH band) | HARD | ❌ | ❌ | `Not Acquisition (gated)` |
| `is_acquisition_related = false` **and** confidence < 0.85 | SOFT | ✅ | ✅ (still claims) | the normal routing outcome, plus `Parse_Confidence__c = LOW` on the Lead |
| `is_acquisition_related = true` | normal | ✅ | ✅ | the normal routing outcome |
| LLM outage or malformed response | degrade (standing rule, unchanged) | ✅ | ❌ (no address) | `New Lead (no property) — LLM unavailable` |

**Reply always wins, unconditionally, even if the reply's own content would classify as non-acquisition
if judged in isolation.** Three reasons this is not close: (1) a header match on `In-Reply-To`/
`References` is *proof* the message continues a thread the pipeline already routed — a deterministic
identity match cannot be outranked by a classifier's opinion of the text; (2) the failure modes are
wildly asymmetric — losing a genuine reply from the deal record costs a human-written message that
belongs there, while filing a non-acquisition reply costs one extra Task on a record it's already
threaded to; (3) replies systematically *look* non-acquisition ("Thanks." / "Will do." / an
out-of-office auto-reply inside a live thread) — gating on classification would discard exactly the
conversational tail the thread anchors were built to capture. Consequence, stated plainly: **the gate
can only ever suppress a NEW conversation, never an existing one.**

**The deterministic pre-filter runs before the LLM callout, on envelope/headers only, tuned for
precision over recall:**

- `From` local-part contains/equals a machine-sender token: `noreply`, `donotreply`, `mailerdaemon`,
  `postmaster` (contains-match on the compacted local part, which is what makes Gmail's
  `forwarding-noreply@google.com` — the canonical case this filter exists for — match even though
  its local part is neither an exact nor a prefix match on `noreply`), or `bounce`/`bounces` (exact
  match only, since `bouncer@` legitimately contains `bounce`).
- Raw headers carry `Auto-Submitted: auto-replied` / `auto-generated` / `auto-notified`,
  `X-Autoreply:`, or `Precedence: auto_reply`.
- **No subject-keyword filtering** ("Out of Office", "Undeliverable", "Newsletter") — a broker's
  subject line can contain anything, and this would be low-precision.
- 🔴 **`Precedence: bulk` is deliberately excluded — this is a decision, not an oversight.** The
  design originally listed `bulk` alongside `auto_reply`; code review overruled it and the user
  endorsed the ruling. `Precedence: bulk` means MASS-SENT, not MACHINE-GENERATED — it is exactly what
  a legitimate broker blast platform (RCM, Crexi, Buildout) sets on a real listing announcement, the
  highest-value email this pipeline exists to capture. It also violates the gate's own asymmetry: a
  false positive here is a broker's **lost claim**, discoverable only if the broker complains months
  later — not reversible and not observable, so the pattern isn't worth its cost. Bulk mail is
  routed to the LLM and judged there, where a wrong call lands in the soft tier (Lead created, `LOW`
  confidence, claim still taken) instead of vanishing outright.

**The soft tier's claim-anyway policy is deliberately generous, not a bug.** An uncertain "not
acquisition" verdict still creates the Lead and still attempts the claim — claiming a junk address
costs one registry row a human can delete by hand; failing to claim a genuine one costs a broker their
commission and DPEG its protection. The soft tier gets **no dedicated staging label of its own** — it
expresses purely as `Parse_Confidence__c = LOW` on the Lead, which flows straight into the
already-existing `Review_Queue` list view (no new metadata needed for this half of the gate).

**Auditing what the gate rejected:** the `Gated_Not_Acquisition` list view on
`Inbound_Email_Staging__c` filters `Outcome__c startsWith 'Not Acquisition'` — this is the only way
anyone sees what the gate is doing, and checking it periodically is what makes a hard, silent-by-design
gate trustworthy rather than a black box.

---

## 🧩 Multi-Property Semantics (D1)

### One email, up to 10 Leads

`route()` is no longer one linear pass. It splits into:

```
EMAIL-LEVEL PROLOGUE (once)
 0. staging Status == 'Processed'?          -> skip
 1. Message-ID already on a Task?           -> skip (redelivery)
 2. (a) REPLY                               -> route, NO LEAD, NO CALLOUT
 3. Deterministic pre-filter                -> gated, NO LEAD, NO CALLOUT
 4. LLM callout (still exactly ONE per job)
 5. Extracted_JSON__c stored VERBATIM, before any routing decision
 6. Regex + envelope broker fallbacks
 7. RELEVANCE GATE (hard / soft)
 8. Build the work-list: drop blank addresses, de-duplicate on NORMALIZED
    address, SORT by cluster key, truncate to MAX_PROPERTIES (10).
    Empty work-list -> (c) NO-PROPERTY, ONE Lead, done.

PER-PROPERTY LOOP (sorted order, each iteration isolated by try/catch)
 (b) REPEAT | (d) COMPETING | (e) WINNER  -- exactly as in Change 1, run once per property

EMAIL-LEVEL EPILOGUE (once)
 9.  ONE Task per DISTINCT routed record, ONE bulk DML, ascending priority
 10. Stamp staging: Outcome__c (summary), Result_Record_Id__c (primary),
     Routed_Record_Ids__c (all N), Property_Count__c, Processed_DateTime__c
```

### The deadlock that motivated the sort order

`PropertyClaimService.claim()` takes a pessimistic `FOR UPDATE` lock per property, and **Apex cannot
release a row lock before the transaction commits** — so a queueable claiming N properties holds N
locks simultaneously. Two concurrent multi-property emails sharing two properties in *different* order
are a textbook AB-BA deadlock:

```
Job A (Royal Inn, Bass Inn)        Job B (Bass Inn, Royal Inn)
  lock "1400 royal"   OK             lock "220 bass"    OK
  lock "220 bass"     blocked        lock "1400 royal"  blocked
```

**Salesforce does not detect or report this as a deadlock** — both sides simply hit the ~10s lock-wait,
`acquireClusterLock` retries once, both give up, and `claim()` fails safe to `ClaimOutcome.UNCLAIMED`
— a Lead that holds no claim, with (before this fix) only a `System.debug` to show for it. **Broker
Protection would have silently failed on exactly the multi-broker blast emails D1 exists to support.**

The fix costs nothing and adds no new locking API: process properties in **ascending
`deriveClusterKey` order**, ties broken by normalized address (`PropertyExtraction.compareTo`).
Because every transaction visits shared clusters in the same relative order, no wait-for cycle can
form — the loser simply blocks on the first shared key and proceeds once the winner commits. Three
rules this depends on, all easy to get wrong:

- **The sort key comes only from the address**, never from the LLM's array order, which is not stable
  across transactions.
- **De-duplication is on the normalized address, never the cluster key** — `deriveClusterKey` is
  deliberately coarse (street number + first alphabetic token), so two genuinely different buildings
  can share a cluster key (`'123 Main St, Dallas'` and `'123 Main St, Houston'` both derive `'123
  main'`), and re-locking the same row inside one transaction is a harmless no-op, but collapsing on
  the coarse key would silently drop a real property.
- **Locks are not hoisted up front.** That would extend the last cluster's hold time across the whole
  loop for no correctness gain; sorted lazy acquisition already removes the cycle at zero extra cost.

A lock timeout is now genuine *contention*, not a silent deadlock, and it no longer hides: any
property that fails safe on a timeout appends ` [unclaimed: lock timeout]` to the staging
`Outcome__c`.

**Testability, honestly stated:** true concurrency is not reproducible in single-threaded Apex tests.
The achievable, and actually achieved, coverage is (1) a direct unit test of the sort function itself
(`buildWorkList_sortsByClusterKeyAndDeduplicatesOnNormalizedAddress`, a pure function) and (2) an
end-to-end assertion that `Routed_Record_Ids__c` comes back in cluster-key order for a scrambled input
array (`execute_scrambledInput_isProcessedInDeterministicClusterKeyOrder`). Neither test proves the
deadlock itself is prevented — nothing in Apex can — only that the ordering the prevention depends on
is correct.

### Per-property isolation, and why there is still no Savepoint

Each loop iteration is wrapped in its own `try/catch`: a failure on one property records an `Error (...)`
outcome and the loop **continues**, rather than one bad property rolling back a legitimate claim on
another. `PropertyClaimService.isLostRaceAgainst`'s self-match reasoning (see
`docs/2026-07-31-competing-broker-no-lead.md`) depends on there being **no Savepoint** in this module —
introducing one to isolate loop iterations would silently change that reasoning, so plain `try/catch` +
continue is the correct — and only — isolation primitive here.

### Task logging and the priority order

One Task per **distinct routed record** (not per email, not per property), all inserted in a single
bulk DML. Not one per email — a competing submission on property B would leave no activity at all on
B's winning Lead. Not one per property — two properties resolving to the same record would double-log
the same email there. Verified safe because:

- `Inbound_Message_Id__c` is `externalId` but explicitly **not `unique`** — N rows carrying one
  Message-ID insert cleanly, and `isAlreadyLogged`'s `LIMIT 1` existence check is unaffected by there
  being several.
- `Thread_Key__c` is the conversation root and is *supposed* to be identical across every message in
  a thread — identical values on N rows is correct, not a collision.

**Insert order is load-bearing.** The Task list is built in ascending priority (`NO-PROPERTY <
REPEAT < COMPETING < WINNER`) so the highest-priority record gets the highest Id. N rows in one bulk
DML share a `CreatedDate` to the millisecond, so `TaskSelector.selectLatestByThreadOrMessageIds`'s
`ORDER BY CreatedDate DESC, Id DESC` tie-break resolves on Id — and inserting the highest-priority
record last is what makes a later reply into a multi-property thread land on the deal DPEG actually
owns, deterministically, instead of on an arbitrary one of several candidates.

### Staging semantics for N results

`Result_Record_Id__c` stays `Text(18)` and unchanged in meaning — the **primary** record (first WINNER
Lead, else first COMPETING winner, else the REPLY/REPEAT target, else null) — so a single-property
email stamps byte-identically to before this change. Two new fields carry the rest:

- **`Routed_Record_Ids__c`** (LongTextArea 32,768) — one line per routed property, in processing
  order: `<normalized address> | <outcome> | <recordId>`. The only place the full N-result mapping
  exists.
- **`Property_Count__c`** (Number 3,0) — properties the extraction *found*, pre-truncation. The gap
  between this and the number of lines in `Routed_Record_Ids__c` *is* the truncation signal.

`Outcome__c` for N = 1 is byte-identical to today's label (no historical sweep needed); for N > 1 it's
a stable, filterable summary with the prefix `Multi-Property`, e.g. `Multi-Property (3): 1 New Lead
(winner), 1 Competing Submission, 1 Repeat`. Two suffixes may append: ` [truncated: 10 of M]` above the
cap, and ` [unclaimed: lock timeout]` when any property genuinely failed safe on lock contention.

### The cap, and why 10

Measured against the code, the binding governor limit is SOQL (async cap 200), at roughly 8 queries per
property typical / 14 worst-case on the WINNER path. That puts the realistic ceiling at ~14–24
properties before SOQL exhausts. `MAX_PROPERTIES = 10` leaves more than 2× headroom on the worst
realistic path and sits comfortably above any real broker blast observed in production (the motivating
Bracket email carried two properties). Above the cap, the email **truncates visibly, never silently**:
the first 10 in sorted (deterministic) order are processed, `Extracted_JSON__c` still holds all M
properties verbatim, and the remainder is described in the first Lead's `Deal_Notes__c` under
"Additional properties in this email (not routed)."

**Queueable chaining for 11+ properties is explicitly deferred, not rejected** — it's feasible (the
callout is already done and the JSON is already on staging, so a child job needs no second callout,
and the parent commits and releases its own locks before a child would start) but was left out because
it doubles the state machine for a case with zero observed occurrences. `MAX_PROPERTIES` is a named
constant specifically so raising it, or wiring chaining later, stays a small, local change.

---

## 🛡️ The Claim-Key Regression Guard (`ExtractionRegressionFixtureTest`)

**This is the single most valuable test in the change**, and the only mechanism that catches a
prompt-quality regression before a broker does. It cannot call the real model — there is no callout in
a test context, and a non-deterministic dependency has no place in a regression suite — so it does NOT
prove "gpt-4o-mini returns the same address under both prompts." Nothing in Apex can prove that. What it
DOES pin is everything **between** the model and the ledger, which is where an Apex-side regression
would actually live:

1. **The parser contract.** For each of 5 anonymized real-shape fixtures (auto-forward with a plain
   address; manual forward with a quoted original; heavy punctuation and a suite number; a
   multi-property blast; a name-only deal with no street address), the LEGACY four-key response and
   the ENRICHED response derived from the *same underlying email* must produce the **identical**
   `broker_email` and the **identical** `PropertyMatchingService.normalizeAddress(property_address)`.
   Not "a similar address" — the same normalized key, because that key **is** the claim identity.
2. **The prompt text itself.** `legacyExtractionRules_areStillVerbatim` asserts the four legacy
   instructions character-for-character, so an accidental edit to the claim engine's prompt fails here
   instead of silently re-keying the registry in production.
3. **The 40,000-character input clip (C-15).** `inputClip_neverRemovesTheOutermostFromAndSentLines`
   asserts the clip does not remove the outermost `From:`/`Sent:` lines the legacy rules read — the
   only reason clipping the LLM's input body is safe at all.
4. **The rollback lever itself is real, not theoretical** — `rollbackLever_recomposesTheOriginalFourKeyPrompt`
   and `legacyResponseShape_stillRoutesThroughTheParserUnchanged` prove that reverting
   `EXTRACTION_INSTRUCTION` to the legacy constant is genuinely a one-line, no-other-code-change
   rollback.

**Where the fixtures come from, and the intended maintenance action:** `Inbound_Email_Staging__c` rows
are never deleted (the object is the pipeline's audit trail), so `usman-dpeg` already holds the raw
body and headers of every email the pipeline has ever processed — a free regression corpus. The five
fixtures currently in the test are anonymized transcriptions of shapes already seen in production.
**Adding a fixture when a genuinely new email shape appears is the intended way to extend this guard**
— it costs one entry in `fixtures()`.

---

## 🔧 Operational Guidance

### Outcome labels — now three axes, not just three eras

`Inbound_Email_Staging__c.Outcome__c` remains free Text (no picklist, no value sweep needed). As of
this change there are effectively three independent things a label can now encode, layered on top of
the three-era history already documented in `docs/broker-protection-data-dictionary.md` ("Outcome
label history"):

1. **Which branch fired** — the original vocabulary (`New Lead (winner)`, `Repeat`, `Reply Thread`,
   `Competing Submission`, `Competing Submission (race)`, `New Lead (no property)` /
   `... — LLM unavailable`), unchanged for a single-property email.
2. **Whether the gate fired** — the two new labels `Not Acquisition (gated)` (the LLM was confident)
   and `Not Acquisition (pre-filtered)` (a regex/header match, no callout at all). These need
   different follow-up: one is a prompt/threshold question, the other is a filter-tuning question.
3. **Whether it was a multi-property result** — the `Multi-Property (N): ...` summary prefix, with
   the ` [truncated: X of M]` / ` [unclaimed: lock timeout]` suffixes layered on top of any of the
   above.

A single-property, non-gated email is byte-identical to how it always stamped — none of this is a
breaking change to any existing consumer or dashboard filter.

### Re-mapping from `Extracted_JSON__c`

`Extracted_JSON__c` holds the model's response **verbatim**, written before any routing decision, so it
survives every branch including the ones that create no Lead (gate, pre-filter, reply, repeat,
competing). It is never ambiguously blank: branches that skip the callout entirely write an explicit
marker instead — `{"skipped":"reply"}` or `{"skipped":"llm-unavailable"}` (extraction failure) or
`{"skipped":"pre-filter","reason":"sender:noreply"}` (pre-filter hit, with the specific pattern that
matched). To recover what happened on a given staging row:

- A JSON object with `"properties"` → a normal (possibly multi-property) extraction; each property's
  `property_address` maps to a line in `Routed_Record_Ids__c` via
  `PropertyMatchingService.normalizeAddress(...)`.
- A JSON object with `"skipped"` and no `"properties"` → the email never reached (or never needed) the
  LLM; the `"reason"` sub-key (pre-filter only) names which pattern matched.
- **This is not an indexed or filterable field** (LongTextArea, 131,072 chars) — it is an audit/
  recovery store, not a reporting surface. Use `Outcome__c` for filtering; use `Extracted_JSON__c` only
  when investigating one specific row.

### `Parse_Confidence__c = LOW` and the Review Queue

Written on **every** Lead this pipeline creates (not only soft-gated ones), derived by Apex from the
model's numeric `confidence` (≥ 0.85 → HIGH, 0.60–0.849 → MEDIUM, below 0.60 or missing/unparseable →
LOW). `LOW` is the operationally interesting value — it is what the soft-gate tier looks like *on the
Lead itself*: the model was uncertain enough about acquisition-relevance that it didn't clear the hard
gate's bar, but a Lead was created and the property was still claimed anyway (the soft tier's
deliberate generosity — see "The Tiered Relevance Gate" above). The existing `Review_Queue` list view
(`Parse_Confidence__c = LOW`, pre-existing, unmodified by this change) is where a human works this
queue. No new list view was needed for this half of the gate — only `Gated_Not_Acquisition` (for the
hard-gated and pre-filtered rows) was new.

### The `Task.Type` incident (found and fixed during this rollout)

Not part of the design, but directly relevant to reading `Inbound_Email_Staging__c.Error__c` rows from
around this date: the first two real inbound broker emails to reach `usman-dpeg` both died with
`Status = 'Error'` because `InboundEmailActivityService` was setting `Task.Type = 'Email'` alongside
`TaskSubtype`. **`Task.Type` does not exist in this org's `FieldDefinition`** — an org-template
difference (Enhanced-Email-era orgs retired the classic `Type` picklist in favor of `TaskSubtype`), not
a licensing gap. Apex compiles a `Task.Type` assignment without complaint (the compiler checks against
the standard object schema, not this org's actual field set) and only fails at runtime
(`"Operation failed due to fields being inaccessible on Sobject Task"`), which is why it survived every
prior review and deploy — the builder/scratch orgs used to develop this module still carry classic
`Type`. The fix (remove the `Type` assignment; `TaskSubtype` alone is portable across both org
templates and is what renders the email icon on the Activity timeline) is already live; see
`InboundEmailActivityService`'s class header for the full retraction/root-cause writeup. **Do not
"restore" `Task.Type`** if you ever see it suggested — a green test run in a different org proves
nothing about whether the field exists here.

A related, incidental correction surfaced at the same time: several docs in this set previously stated
Enhanced Email/EAC licensing is not present in this org. That was true when originally written and is
no longer true — Enhanced Email is now enabled (via EAC setup) — though the Task-based logging design
is retained deliberately rather than migrated, since the thread-anchor contract
(`Inbound_Message_Id__c`/`Thread_Key__c`) is what reply threading actually depends on. See
`docs/broker-protection-overview.md`'s EAC note and `docs/broker-protection-faq.md` for the corrected
answers.

---

## ⚠️ Known-Open Items

None of the following are deploy-blocking; the review verdict was **APPROVED WITH WARNINGS**.

| # | Item | Detail |
|---|---|---|
| — | **No `LeadConvertService` test for the new asset types.** `Hospitality` and `Medical Office` were added to `Property__c.Asset_Type__c` specifically so `LeadConvertService.buildProperty`'s `allowedAssetTypes.contains(...)` guard would carry them through conversion instead of silently dropping them (the defect this metadata addition exists to prevent). No test in `LeadConvertServiceTest` currently proves a Hospitality- or Medical-Office-flagged Lead actually converts with its asset type intact — the fix is verified only by reading the metadata, not by a test exercising the conversion path end to end. |
| — | **No dedicated `InboundEmailActivityServiceTest`.** The class (bulk `logInboundEmail`, the priority-ordering contract, `isAlreadyLogged`) is exercised only indirectly through `ExtractAddressQueueableTest`'s end-to-end assertions. There is no unit-level test file for it in isolation. |
| W3 | Carried forward from Change 1 — **no converted-winner test of `resolveLiveRecord`.** Every test that routes a competing-broker or repeat submission onto "the winning Lead" uses an unconverted Lead as the winner; no test proves the same routing correctly redirects onto a converted winner's live Opportunity/Contact. |
| W6 | Carried forward from Change 1 — **the 251-decoy reply test cannot fail.** `execute_replyThreadedAmong251PriorTasks_stillFindsTheCorrectThread` inserts 250 noise Tasks plus the real thread root, but because the underlying selector filters directly on the cited Message-IDs (a targeted `WHERE ... IN`, not a scan), the volume of noise cannot actually perturb the result. |
| S3 | Carried forward from Change 1 — **`ClaimOutcome.DUPLICATE`'s label mapping is unreachable in practice.** Retained so `toOutcomeLabel` stays a total function over the enum, but no path through `claim()` returns plain `DUPLICATE` today (every duplicate reached through `claim()` is, by construction, a lost race and returns `DUPLICATE_RACE` instead). |
| S4 | Carried forward from Change 1 — **`routeLostRace`'s `winner == null` fallback can under-describe a written submission.** If the re-read inside the lost-race tail comes back empty, the Lead is kept and reported `UNCLAIMED` (correct and data-preserving for the Lead) even though `markDuplicate` may have already inserted a `Competing_Broker_Submission__c` row earlier in the same attempt — a narrow window where the outcome label doesn't fully describe what was written. |
| — | **PDF/OM attachment parsing is out of scope (D4), by design, not an oversight.** The pipeline extracts only from the plain-text/HTML body and a single optional inline image, exactly as before this change. A deal room link (`Deal_Room_Link__c`) or the model's own narrative summary is the closest current substitute for information that lives only inside an attached Offering Memorandum. |
| — | **The per-property Lead cap is 10 (`MAX_PROPERTIES`), and queueable chaining for 11+ is deferred, not rejected.** No broker email has ever pitched more than a handful of properties in production; if that changes, the constant is a one-line raise, and chaining (feasible, no second callout needed) is the documented next step should the cap prove insufficient. |

---

## 🧱 Components

### New

| Component | Layer | Responsibility |
|---|---|---|
| `LLMExtractionParser.cls` | Utility (pure coercion) | JSON → typed value coercion/validation. Never throws; records every rejection as a note. |
| `LLMExtractionResult.cls` | DTO | Email-level extraction result: classification, broker identity, `properties`, raw JSON, notes. `toLegacyMap(property)` re-emits the exact 4-key map the claim engine has always consumed. |
| `PropertyExtraction.cls` | DTO | One property's typed, validated fields. `implements Comparable` — the deadlock-avoidance sort (`compareTo` on cluster key, then normalized address) lives here. |
| `EmailToLeadService.LeadRequest` (inner class) | DTO | ~25 values needed to build one Lead for one property; replaces a would-be ~25-parameter method. |

### Modified

| Class | Change |
|---|---|
| `LLMExtractionCalloutService` | New prompt (legacy 4-key block verbatim and first); `MAX_TOKENS` 512→4096; `TIMEOUT_MS` 30000→60000; `response_format: json_object`; input-body clip to 40,000 chars; returns typed `LLMExtractionResult` instead of a 4-key map. `MODEL`/`temperature` unchanged. |
| `ExtractAddressQueueable` | Restructured into prologue / per-property loop / epilogue. Reply detection and the deterministic pre-filter now run before the LLM callout. The tiered relevance gate. `Extracted_JSON__c` written pre-routing. Degrade catch widened to `JSONException`. New `OUTCOME_NOT_ACQUISITION` / `OUTCOME_PRE_FILTERED` / `OUTCOME_MULTI_PREFIX` constants and `MAX_PROPERTIES = 10`. Class-header routing tree fully rewritten. |
| `EmailToLeadService` | `createLeadFromExtracted` takes a `LeadRequest` DTO, not positional parameters. Class invariant restated: "one PROPERTY == at most one Lead; one email can produce N" (was "one email == at most one Lead"). `deleteLead` unchanged. |
| `InboundEmailActivityService` | New bulk `logInboundEmail(List<Id>, ...)` doing one insert of N Tasks; the original single-Id method survives as a one-element wrapper. |
| `InboundEmailStagingService` | Writes `Extracted_JSON__c` (clipped); stamps `Routed_Record_Ids__c` / `Property_Count__c` alongside the existing terminal-state fields. |
| `TaskSelector` | `selectLatestByThreadOrMessageIds` gained `, Id DESC` as a secondary sort, needed once N Tasks in one bulk DML can share a `CreatedDate` to the millisecond. |
| `PropertyClaimService` / `PropertyMatchingService` | **Signatures unchanged.** Javadoc-only updates recording that `claim()` is now called N times per transaction and that the caller's sorted iteration order — not the class itself — is what prevents the multi-property deadlock. |

### Tests

`ExtractAddressQueueableTest` gained roughly a dozen new methods covering the gate (hard/soft/
pre-filter/reply-beats-gate), multi-property routing (10-property volume, 15-property truncation,
scrambled-input ordering, mixed-outcome, Task-priority, reply-into-multi-property-thread), and
governor-headroom telemetry. `LLMExtractionParserTest` is a new, large (~40 method) unit-test class
covering one test per validation rule in the parser. `ExtractionRegressionFixtureTest` is new (see
above). `bulk-test-rule.md`'s per-transaction-singleton exemption was narrowed in the same change to
cover `LLMExtractionCalloutService` only — `ExtractAddressQueueable`, `PropertyClaimService`,
`EmailToLeadService`, and `PropertyMatchingService` are now called N times per transaction and are no
longer exempt (see the rule file's "Narrowed scope (2026-07-31, design C-18)" section; not edited by
this documentation pass).

---

## 📁 File Locations

| Component | Path |
|---|---|
| New DTOs / parser | `force-app/main/default/classes/{LLMExtractionParser,LLMExtractionResult,PropertyExtraction}.cls` |
| Modified queueable / services | `force-app/main/default/classes/{ExtractAddressQueueable,EmailToLeadService,LLMExtractionCalloutService,InboundEmailActivityService,InboundEmailStagingService,TaskSelector}.cls` |
| New test classes | `force-app/main/default/classes/{LLMExtractionParserTest,ExtractionRegressionFixtureTest}.cls` |
| 19 new Lead fields | `force-app/main/default/objects/Lead/fields/{Property_Name__c,NOI__c,Occupancy_Pct__c,Building_SF__c,Unit_Count__c,Offer_Due_Date__c,Sale_Process__c,Guidance_Price_Low__c,Guidance_Price_High__c,Year_Built__c,Year_Renovated__c,Lot_Size_Acres__c,WALT_Years__c,ADR__c,Zoning__c,Seller_Entity__c,Deal_Room_Link__c,Listing_Broker_Name__c,Listing_Broker_Email__c}.field-meta.xml` |
| Asset_Type__c picklist additions | `force-app/main/default/objects/{Lead,Property__c}/fields/Asset_Type__c.field-meta.xml` |
| 3 new staging fields | `force-app/main/default/objects/Inbound_Email_Staging__c/fields/{Extracted_JSON__c,Routed_Record_Ids__c,Property_Count__c}.field-meta.xml` |
| FLS | `force-app/main/default/permissionsets/{Broker_Protection_Access,DPEG_Acquisition_View,DPEG_Acquisition_Edit,DPEG_Acquisitions}.permissionset-meta.xml` |
| Flexipage | `force-app/main/default/flexipages/Lead_Record_Page.flexipage-meta.xml` (new "Deal Screening" `flexipage:fieldSection`) |
| Compact layout | `force-app/main/default/objects/Lead/compactLayouts/Lead_Highlights.compactLayout-meta.xml` (added `Offer_Due_Date__c`, `Asset_Type__c`) |
| New list views | `force-app/main/default/objects/Lead/listViews/Offers_Due_Soon.listView-meta.xml`, `force-app/main/default/objects/Inbound_Email_Staging__c/listViews/Gated_Not_Acquisition.listView-meta.xml` |
| Bulk-test-rule narrowing | `.claude/rules/bulk-test-rule.md` (§ "Narrowed scope (2026-07-31, design C-18)") |

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-07-31 | Documentation Agent | Initial creation — documents the LLM Field Extraction Enrichment: the JSON contract and its anti-hallucination/parser rules, the tiered relevance gate, D1 multi-property semantics (deadlock avoidance, task priority, staging semantics, the 10-property cap), the `ExtractionRegressionFixtureTest` claim-key regression guard, operational guidance (outcome labels, `Extracted_JSON__c` remapping, `Parse_Confidence__c`/Review Queue, the `Task.Type` incident), and known-open items. Companion edits landed the same pass in `docs/broker-protection-architecture.md`, `docs/broker-protection-data-dictionary.md`, `docs/broker-protection-operations.md`, `docs/broker-protection-overview.md`, and `docs/broker-protection-faq.md`. |

---

## 2026-08-02 — Prompt tuning (deploy 0Afiw000000DDE0CAO)

**Scope:** `LLMExtractionCalloutService.cls` only — three prompt-rule additions, no schema change, no
new fields, no parser change. **Source:** `agent-output/design-requirements-prompt-tuning.md`; the
class's own header (`═══ PROMPT TUNING 2026-08-02 ═══` block) and `referenceDateLine()`'s ApexDoc carry
the same story as the shipped, deployed truth.

### What was observed

Three live-traffic defects, all reproduced from staging row `a0aiw000000NEK1AAO` on `usman-dpeg`:

1. `property_name` came back empty even though the property's marketing name led the email body — the
   model wrote it into its own `deal_summary` narrative instead of the dedicated field, reproduced on
   two consecutive live emails.
2. `offer_due_date` came back `2023-08-11` with no date anywhere in the body or the attached flyer —
   the model recalled the year from training-data knowledge of a real 2023 campaign for a
   similarly-branded property, not from anything the email itself said.
3. `sent_datetime` came back `2023-08-11 00:00:00` — the identical fabrication, but unlike
   `offer_due_date` this value passes through no plausibility gate before it is written.

One more field was checked in the same pass and explicitly ruled *not* a defect: `property_address`.
Whatever incompleteness was observed there traced back to what the source email itself stated, not to
the prompt or the parser — it needed no rule change, is explicitly excluded from the new
`sent_datetime` prompt text (that paragraph is barred from mentioning `broker_name`, `broker_email` or
`property_address` at all), and its correctness is the thing the UAT plan below re-verifies rather than
the thing being fixed. Worth stating once so a future reader doesn't re-open it as a fourth defect.

### Why the fabricated `sent_datetime` was the worst of the three

`offer_due_date` is protected by `LLMExtractionParser.offerDate`'s plausibility gate (`Date.today() -
365` .. `Date.today() + 730`), so the fabricated 2023 value was rejected there and only landed as an
audit note in `Deal_Notes__c`. `sent_datetime` passes through no gate at all — `parseSentDatetime`
accepts any parseable GMT value — so the 2023 timestamp reached
`Competing_Broker_Submission__c.Submitted_DateTime__c` for real. That field is the 90-day recency filter
behind repeat detection (`CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail`, cutoff
`Datetime.now().addDays(-90)`): a row stamped outside that window is invisible to the lookup, so when
the same broker sends a genuine follow-up on the same property, the pipeline can no longer see its own
prior submission and routes the follow-up as a fresh competing claim instead of a repeat. That makes
this an arbitration defect, not a display bug — which is why the `sent_datetime` rule is the
highest-priority of the three even though it touches a legacy, claim-engine value the enriched block is
normally forbidden from redefining.

### The fix — three prompt rules plus one injected line, all in the enriched block

`LEGACY_EXTRACTION_RULES` was not edited. All three rules landed in `ENRICHED_EXTRACTION_RULES`:

1. **`property_name`** is now defined explicitly — the marketing/brand name of the property, typically
   the subject line, the first sentence of the body, or an attached flyer's headline — with a worked
   example ("Orion ParkView, 1400 Royal Lane, Dallas TX" → name `"Orion ParkView"`, address `"1400
   Royal Lane, Dallas TX"`) and an instruction to leave it empty rather than invent one.
2. **Year-less dates** now anchor on an explicit reference date A: the year-bearing `Sent:`/`Date:` line
   in the email if one exists, otherwise the injected REFERENCE DATE line (below). A date takes A's
   year, and rolls forward to A's year + 1 only if it would otherwise fall more than 30 days before A —
   never backward, and never from world knowledge of a real campaign or listing.
3. **`sent_datetime`** now must come from explicit content — a `Sent:`/`Date:` header line or a date
   written in the body — or return an empty string. Because `sent_datetime` is a legacy claim-engine
   value, the rule is deliberately worded as a *deferring* paragraph (the same pattern the existing
   "BROKER vs LISTING BROKER" paragraph already uses): it only narrows the value toward empty, it does
   not restate or change where the value is read from (the outermost/earliest `Sent:` line stays
   authoritative), and it names none of the other claim values.

**The injected REFERENCE DATE line** (`buildRequestBody`, between `EXTRACTION_INSTRUCTION` and the
clipped email text) carries `Datetime.now().formatGmt('yyyy-MM-dd')`, labelled and guarded: "Use it
ONLY to resolve a date written without a year. It is NOT a value to extract; it is never
`sent_datetime`." Two things about its shape are deliberate, not incidental:

- **Date-only GMT format is both anti-harvest and fail-safe.** The guard sentence is the primary
  defense against the model harvesting the reference date as a send time, but the format is a second,
  independent line of defence: if the guard is ignored anyway, a harvested date-only string
  (`2026-08-02`, no time component) fails `Datetime.valueOfGmt` inside `parseSentDatetime` — verified
  in-org (`System.TypeException: Invalid date/time: 2026-08-02`) — and falls back to `Datetime.now()`,
  which for a just-received email is the *correct* value anyway. A harvested full timestamp would not
  have failed safe the same way, which is why the line is deliberately date-only rather than a full
  ISO timestamp.
- **Next-future-occurrence anchoring was considered and rejected.** Rolling a year-less date forward to
  its next future occurrence (e.g. "August 1st" received August 2 → next August 1) silently fabricates a
  deadline roughly 364 days out — squarely inside the plausibility gate's `+730`-day window, so the gate
  would wave it through as a believable-but-wrong date. That converts a harmless, already-expired date
  into a plausible wrong one, which is the exact failure mode this change exists to remove. Received-year
  anchoring instead yields a truthful, one-day-past date for the same input.

### What is fixture-protected vs. what only UAT can verify

`ExtractionRegressionFixtureTest` byte-pins `LEGACY_EXTRACTION_RULES`
(`legacyExtractionRules_areStillVerbatim`) and proves the one-line rollback still recomposes the
original four-key prompt (`rollbackLever_recomposesTheOriginalFourKeyPrompt`) — both untouched by this
change, since none of the three rules or the reference-date line touch the legacy block.
`LLMExtractionCalloutServiceTest`'s `contains`/length assertions (`max_tokens`, `response_format`,
`model`, `temperature`, `image_url`, `sentBody.length() < 80000`) are likewise unaffected by a
~150-character reference-date line appended inside the existing text part. None of this proves the
model actually *behaves* differently — there is no callout in a test context, and nothing in Apex can
assert what gpt-4o-mini returns. The only way to confirm the three defects are actually fixed is live
UAT on `usman-dpeg`.

### UAT plan

Two cases, because one email cannot prove both directions:

- **Case A — resend the original Orion email fresh** (new Message-ID, not a redelivery of the original,
  since the Message-ID idempotency guard would skip it). Expect `property_name` = `"Orion ParkView"`,
  `sent_datetime` = `""` (empty is correct — the body carries no date at all), `offer_due_date` = `null`
  for the same reason, and the new `Competing_Broker_Submission__c` row's submitted timestamp to show
  today, not August 2023. Verify primarily against the new `Inbound_Email_Staging__c` row's
  `Extracted_JSON__c`, since it is branch-independent — Orion is already claimed and its existing
  submission is stamped 2023, which is outside the 90-day repeat window, so a plain resend routes to
  Competing Submission and creates no Lead to check at the Lead level.
- **Case B — a year-less deadline test email** ("offers due Tuesday, August 11th", no year, no `Sent:`
  line). Expect `offer_due_date` = the received-year anchor date, and — the named hazard check —
  `sent_datetime` = `""`, confirming the REFERENCE DATE line was not harvested as a send time.

**Reviewer-required claim-safety check, on top of both cases above:** because `property_name` is now
split out as its own field where the model could previously fold the same information into
`property_address` or `deal_summary`, a re-sent or re-processed email for a property that is *already
claimed* in `Property_Registry__c` must still route as Competing Submission or Repeat — never register
as a second winner. This is exactly what Case A's "`property_address` still normalizes to the same
`Property_Key__c`" check exists to catch: if the name/address split shifts what the model puts in
`property_address` during this transition, `PropertyMatchingService`'s 0.6 Jaccard fuzzy-match threshold
is the net that should absorb minor wording drift — but the check must be performed live, not assumed,
and any drift is grounds to roll back.

**Rollback:** revert the single class; the rule additions and the reference-date line are independent of
every other component, with no data migration and no dependent deploy.

### Deferred follow-ups

Three items surfaced by the investigation but explicitly out of scope for this change, per
`agent-output/design-requirements-prompt-tuning.md`:

- **O1** — anchor the blank-`sent_datetime` fallback on the staging row's `CreatedDate` instead of
  `Datetime.now()`, which is more stable under queueable retry/reprocessing. Judged worth more *after*
  this change than before it, since rule 3 makes a blank `sent_datetime` common where the model
  previously always fabricated one.
- **O2** — a plausibility guard on `sent_datetime` itself, the one input this change still leaves with
  no gate at all. Deliberately not added here because a broker legitimately forwarding a genuinely old
  thread would produce a truthfully old timestamp, and suppressing that is arguably wrong — worth a
  separate design decision, not a corollary of this fix.
- **O3** — the existing 2023-stamped Orion `Competing_Broker_Submission__c` row is not corrected by this
  change. No backfill was requested and none is proposed.
