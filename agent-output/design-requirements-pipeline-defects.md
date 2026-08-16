# DESIGN REQUIREMENTS — Broker Protection pipeline defects (live-run findings, 2026-08-12)

Source: six real emails run through the live pipeline on `usman-dpeg` with real OpenAI extraction
(no mocks). All four defects are MEASURED. This document organises them, separates admin from
developer work, and puts every genuine judgement call in the Gate-1 table at the end.

**Defect 1's option choice is the load-bearing decision. Nothing else here should be built until it
is answered, because options (a) and (b) touch different layers and one of them is schema work.**

---

## 0. What I verified in code, and what I did NOT

Verified by reading the source this session:

| Claim | Where | Status |
| --- | --- | --- |
| D2 hard gate is a CONJUNCTION | `ExtractAddressQueueable.isHardGated`, L1152–1155: `isAcquisitionRelated == false && BAND_HIGH.equals(confidenceBand)` | ✅ confirmed |
| `confidence = 0.0` → `BAND_LOW` → gate cannot fire | `LLMExtractionParser.toBand`, L681–700 | ✅ confirmed |
| U2 gate is ONE condition, no confidence factor | `ExtractAddressQueueable.isCallForOffersGated`, L2848: `CATEGORY_CALL_FOR_OFFERS.equals(extraction.emailCategory)` | ✅ confirmed |
| U2 branch takes NO claim and writes NO submission row | `routeCallForOffers`, L1292–1389 — it calls `findLiveDealForProperty` and `CallForOffersStampService` only; no `PropertyClaimService` call anywhere in the branch | ✅ confirmed |
| A registry row with a null `Winning_Lead__c` is INVISIBLE to the match path | `findLiveDealForProperty`, L1420: `if (winner == null \|\| winner.Winning_Lead__c == null) return null;` | ✅ confirmed — decisive for option (b) |
| Branch (c) creates a Lead unconditionally when the work-list is empty | `routeProperties` L1184–1187 → `routeNoProperty` L1468–1487 | ✅ confirmed |
| The BROKER-vs-LISTING-BROKER rule already exists in the prompt | `LLMExtractionCalloutService` L377–381: *"NEVER put the listing broker into broker_name or broker_email"* | ✅ confirmed — so Defect 3 is a rule the model DISOBEYED, not a missing rule |
| That rule sits in the ENRICHED block, after the byte-pinned legacy block ends at L344 | L344–345 vs L377 | ✅ confirmed — this is what makes the Defect 3 fix low-risk |
| The legacy block is declared AUTHORITATIVE for `broker_name` / `broker_email` | L344–345: *"THEY REMAIN AUTHORITATIVE FOR broker_name, broker_email, property_address AND sent_datetime"* | ✅ confirmed — this CONSTRAINS the Defect 3 fix (see §3) |
| `sale_process` is already extracted and enumerated | L453, L488: *"sale_process must be one of: Off-Market, On-Market Listing, Call for Offers, …"* | ✅ confirmed |

🔴 **Three stated uncertainties. I did not re-read these files, and the implementation agent must
verify each BEFORE writing code. I would rather name them than guess.**

- **U-1 — the exact `Winning_Lead_Required` VR text and which object(s) carry it.** ARCHITECTURE
  documents `AND(ISNEW(), ISBLANK(Winning_Lead__c), ISBLANK(Winning_Opportunity__c))` on
  **`Competing_Broker_Submission__c`**, and records `Winning_Opportunity__c` as a field on that
  object. ARCHITECTURE lists `Property_Registry__c`'s only parent as `Lead (Winning_Lead__c)` — so I
  believe `Property_Registry__c` has **no** Opportunity anchor. The task brief implies the registry
  carries a same-named VR. **Verify both `objects/Property_Registry__c/validationRules/*` and
  `objects/Competing_Broker_Submission__c/validationRules/*` before designing around either.** If
  the registry genuinely has no `Winning_Opportunity__c`, option (b) is strictly harder than option
  (c), which is how I have ranked them.
- **U-2 — whether the staging row persists enough header material for a DETERMINISTIC blast test.**
  Option (a)/(d) below want recipient count, `Precedence:`, `List-Unsubscribe:`. I confirmed
  `Inbound_Email_Staging__c` holds `Raw_Body__c`, `Subject__c`, `From_Address__c`, `From_Name__c`,
  `Forwarded_By__c`, `Message_Id__c`, `In_Reply_To__c`, `References__c`. I did **not** confirm
  whether To/Cc or raw headers are stored. If they are not, the deterministic factor is limited to
  what `Raw_Body__c` contains, and that is a scoping answer the developer must surface, not paper
  over.
- **U-3 — why the model put Dana in `broker_*` on that specific email (Defect 3).** The legacy rule
  says take `broker_name`/`broker_email` from the outermost `From:` line. The envelope sender was a
  platform (`listings@zzmarketplace.com`). I do not know whether the forwarded body carried a
  `From:` line at all. If it did not, the model had no legacy-rule candidate and fell back to the
  only named human — which makes the fix "tell it what to do when the sender is a platform", not
  "repeat the prohibition louder". **Read the raw body of that staging row before writing the prompt
  change.**

---

## 1. DEFECT 1 (CRITICAL) — an ordinary offering memorandum costs the broker their claim

### 1.1 What actually happened

Email A (broker 1, ordinary OM, contains "Offers due 30 September 2026") → `email_category =
call_for_offers` at `category_confidence = 1.0` → U2 gate → **no Lead, no registry claim, no
`Competing_Broker_Submission__c`**. Email B (broker 2, same property, no deadline line) → branch (e)
WINNER → claim `8800 kirby oaks drive houston tx 77054` awarded to the **second** broker.

Broker 1's entire trace is a staging row and a Task with `WhoId = null`.

### 1.2 Why this is worse than ARCHITECTURE's stated residual

ARCHITECTURE records this as a misclassification RISK and points at the `Gated_Call_For_Offers` list
view as the mitigation. Two measured facts change its severity:

1. **Most brokered OMs state a bid deadline.** This is ordinary traffic, not a tail case. The gate's
   population is therefore far larger than "marketed campaigns DPEG does not work".
2. **`category_confidence` was 1.0.** No confidence threshold anywhere in the range would have saved
   it, and nothing gates on that field today anyway. The lever ARCHITECTURE explicitly reserves for
   this problem — *"if a threshold is ever introduced, gate on that field"* — is **measured-dead for
   this failure**. Say so plainly rather than proposing it again.

The tension is real and must not be waved away: the user's own instruction created U2 ("if email is
related to call for offers then we must not store it as a lead, simple"), and ARCHITECTURE's
objection to claiming on a blast is sound — registering a blast makes the FIRST BLAST the winner,
sending a later broker with a genuine exclusive to branch (d) with no Lead, inverting the module's
purpose.

### 1.3 The options

#### Option (a) — NARROW THE CLASSIFIER: require a real blast signal before `call_for_offers` gates anything

Change what `call_for_offers` MEANS. Today the model is told a deadline plus a marketed process
implies the category. Narrow it so the category requires an actual **blast shape** — no single named
individual broker addressing DPEG directly, a mass-distribution signal, a platform sender — and
state explicitly that *an offering memorandum from a named broker that happens to quote a bid
deadline is `acquisition_deal`, not `call_for_offers`*.

- **Genuine blast arrives:** still `call_for_offers`, still gated, no Lead. U2's core rule is
  **untouched** — this is the only option that does not require a user waiver.
- **Genuine exclusive misclassified:** still loses its claim. Frequency drops (the deadline sentence
  stops being sufficient), but the failure mode is unchanged. **A probabilistic fix to a
  deterministic loss.**
- **Commission dispute:** unchanged — broker 1 has a staging row and nothing else. The dispute is
  won by whoever can produce a Salesforce record, and she cannot.
- **Cost:** enriched-block prompt edit only. No schema, no VR, no new DML. Re-pins nothing (see §5).
- **Risk:** prompt behaviour is not unit-testable; verification is UAT against the six real emails.

#### Option (a′) — (a) PLUS a deterministic Apex corroboration factor  ← **RECOMMENDED**

Option (a), and additionally make U2 a **two-factor** gate where the second factor is of a
**different kind** from the first: not a second LLM opinion, but something Apex can check
deterministically off the transport layer.

Suppress only when `email_category == call_for_offers` **AND** at least one non-model blast signal
holds (candidates, subject to U-2: multiple To/Cc recipients, `Precedence: bulk`,
`List-Unsubscribe:`, a known platform sender domain, or the *absence* of a resolvable individual
broker identity). Otherwise the email routes normally — Lead, claim, protection.

- **Genuine blast:** blast platforms set exactly these headers, so it is still gated. U2's core rule
  **survives intact**.
- **Misclassified exclusive:** a named broker emailing DPEG directly carries none of those signals,
  so the corroboration fails and she **keeps her claim**. This is the population Defect 1 is about,
  and this option actually fixes it rather than reducing its probability.
- **Commission dispute:** broker 1 has a Lead and a registry row; she wins on the record.
- **Cost:** the prompt edit from (a) plus one private predicate in `ExtractAddressQueueable`. No
  schema, no VR, no registry DML, no new object.
- 🔴 **THE PROHIBITION THIS DOES NOT VIOLATE, AND THE DEVELOPER MUST BE TOLD WHY.**
  `SENDER_CONTAINS`' Javadoc (L539–572) carries an explicit 🔴 *"DO NOT ADD `bulk`,
  `List-Unsubscribe`, OR ANY OTHER BLAST SIGNAL"*. That prohibition governs the **pre-callout**
  filter, where a blast signal would **suppress** an email before the model ever judged it. Here the
  signal runs **post-callout** and makes suppression **harder**, never easier — it can only ever
  turn a gate OFF. That is the direction the same comment demands: *"Bulk mail must reach the LLM
  and be classified there."* A reviewer who reads only the first sentence will reject this; the
  prompt in §7 states the distinction so they do not.
- **Residual, stated:** an exclusive OM that happens to be sent to several recipients could still be
  gated. Narrower than today by a large margin, but not zero.

#### Option (b) — SEPARATE the decisions: suppress the Lead, take the claim anyway

Keep "no Lead", but write a `Property_Registry__c` row so first-contact is protected.

🔴 **I recommend AGAINST this, and the objection is structural rather than stylistic — three
independent blockers, any one of which is sufficient:**

1. **The registry row would be invisible to the code that reads it.** `findLiveDealForProperty`
   L1420 returns null when `winner.Winning_Lead__c == null`, and `PropertyMatchingService`'s fuzzy
   scan reads `selectRecentWithWinner`. A Lead-less registry row is a row that blocks the unique key
   while answering "no winner" to every reader — the worst of both states: broker 2 is now sent to
   branch (d) **with no Lead** (because branch (d) files onto the winner, and there is no winner
   record to file onto), and broker 1 still has nothing. This is the "first blast wins" inversion
   ARCHITECTURE warns about, arriving through a different door.
2. **`Winning_Lead_Required` blocks the insert** (subject to U-1). Relaxing a VR to permit an
   anchorless ledger row is exactly the change that makes the ledger stop meaning anything.
3. 🔴 **`PropertyClaimService.registerWinner`'s header states its two statements are the ONLY DML
   against `Property_Registry__c` in the codebase and says DO NOT ADD A THIRD**, because updating a
   merely-live registry row can hit a lookup holding a converted Lead. Option (b) is precisely that
   third writer. A reversal of a written prohibition must be argued as one, at Gate 1, with the
   incident it guards against re-examined — not slipped in as a bug fix.

If the user wants this anyway, it is a **separate design** with its own gate, not a line item here.

#### Option (c) — record a `Competing_Broker_Submission__c` ONLY (audit, no claim)

Write the audit row so a commission dispute has a Salesforce record, without touching the registry.

🔴 **This is attractive and it does not work for the measured case, for a reason worth stating
precisely: on the defect's own timeline there is nothing to anchor the row to.** The submission
object requires `Winning_Lead__c` OR `Winning_Opportunity__c` (U-1). Email A arrived **first** — no
registry row, no Lead, no Opportunity existed. So the row cannot be inserted at all for the exact
population the option exists to protect. It works only when the property already matched a live deal
— which is the 4B path where first contact is already visible.

Making it work therefore requires a VR change or a nullable-anchor variant, at which point it is no
longer "audit only", it is schema work with the same review weight as (b). **Viable as a
SECOND-ORDER addition to (a′)** (record the near-miss where an anchor exists), not as the primary
fix.

#### Option (d) — do nothing to the gate; make the gated population workable

Leave U2 exactly as is and invest in the watch surface: a Lead-less "Gated — deadline present"
sub-population, a report, an owner. Cheapest option, zero risk to the claim engine.

- **Genuine blast:** correct today.
- **Misclassified exclusive:** still loses the claim; a human must notice within the window and
  perform manual registry surgery.
- **Commission dispute:** broker 1 still has no record, only a staging row an admin can screenshot.
- **Honest assessment:** this is the status quo with better lighting. Include it so the cost of
  choosing it is explicit, not as a recommendation.

### 1.4 Recommendation

**Option (a′): narrow the classifier AND require a deterministic, non-model corroboration signal
before U2 suppresses anything.**

Reasons, in order:

1. It is the only option that **fixes the measured case** — a named broker's OM keeps its claim —
   while leaving U2's core business rule **completely intact**, so it needs no user waiver.
2. It respects the two written prohibitions in this module (`registerWinner`'s DO-NOT-ADD-A-THIRD,
   and the pre-callout blast-filter ban) rather than reversing either.
3. It costs no schema, no VR, no new object, no registry DML — so it cannot destabilise the claim
   engine, which is the asset at risk.
4. It answers the failure the same way the module already answers others: **a second factor of a
   different kind.** ARCHITECTURE's own record shows a two-factor gate collapsing to one factor when
   both factors are the same kind of judgement (`confidence` measuring `is_acquisition_related`, not
   the category). A transport-layer fact cannot collapse into a model opinion.

Add option (c) as a follow-on **only** where an anchor already exists, and only if the user wants the
audit trail. Ship (a′) first and measure the gated population for a week off `Extracted_JSON__c` —
staging rows are never deleted, so that corpus is free.

---

## 2. DEFECT 2 (CRITICAL) — the relevance gate lets internal email create Leads

### 2.1 The premise needs one correction before the fix is chosen

The brief asks whether the defect is the confidence floor, the empty-property object, or both.
**Verified answer: the empty-property object did NOT make branch (c) reachable.**

`routeProperties` L1184 falls into `routeNoProperty` whenever the **work-list is empty**, and
`buildWorkList` drops blank addresses. An email with **zero** properties and an email with one
**empty** property both produce an empty work-list and both reach branch (c), which creates a Lead
unconditionally (L1478). Branch (c) is the pipeline's default landing point for anything that passes
the gates without an address — that is by design (it is also the LLM-outage landing point, and it is
what stops an outage silently dropping a broker).

What the empty object **did** change is the **label**. `firstProperty` (L1497) returns the first
**non-null** element — an empty object is non-null — so `stampable` was non-null and L1483–1485
chose `OUTCOME_NO_ADDRESS` ("New Lead (property, no address)") instead of `OUTCOME_NO_PROPERTY`.
That is a real second defect: `OUTCOME_NO_ADDRESS` exists to name the population an admin must
**chase the address for**, and a team-lunch email is now sitting in it.

So: **both are defects, but they are different defects with different fixes, and neither is the one
the brief expected.**

### 2.2 The three fixable layers

| # | Layer | Defect | Fix |
| --- | --- | --- | --- |
| 2A | `isHardGated` (L1152) | The conjunction means the model must be **both right AND confident** to suppress. Anything it is unsure about becomes a Lead. `confidence = 0.0` on a correct `false` is the worst case: maximum correctness, zero suppression. | Reconsider the floor. See below. |
| 2B | `firstProperty` (L1497) | Treats a structurally empty property object as a real one, mislabelling the Lead into the chase-the-address queue. | Skip properties with no name AND no address — a genuine one-line predicate, no behaviour change to any claim path (branches b/d/e require a non-blank normalized address by construction). |
| 2C | `routeNoProperty` (L1468) | A branch (c) Lead with **no property name AND no address** carries no information at all: `Office Ops / Unknown - Via Email`. It is a junk row in the object the module's whole purpose is to keep clean. | Decide whether that shape should be a Lead at all. **User decision — see Gate 1.** |

**On 2A specifically.** The floor is not simply "too high". Its asymmetry was deliberate:
ARCHITECTURE argues generosity is the correct bias for a first-come-first-served ledger, because
claiming a junk address costs one deletable registry row while failing to claim a real one costs a
broker their commission. That argument is sound **for emails that name a property**. It has no force
at all for an email that names **nothing** — there is no claim to be generous about. That is the
seam: rather than lowering the floor globally (which would start suppressing low-confidence real
broker emails and re-create Defect 1's failure in a new place), make the gate **conditional on
whether anything is at stake**:

> suppress when `is_acquisition_related == false` **AND** ( `confidenceBand == HIGH` **OR** the email
> yielded no addressable property and no property name )

A confidently-wrong classifier still cannot suppress a real property submission, and an email with
nothing in it stops becoming a Lead regardless of how unsure the model was. **This is my
recommendation for 2A**, and it composes with 2B/2C rather than competing with them.

⚠ Note the interaction the developer must not miss: 2B changes which label branch (c) writes, and
`OUTCOME_NO_ADDRESS` / `OUTCOME_NO_PROPERTY` are **free Text audit labels with deployed list-view
couplings** elsewhere in this class (`Gated_Call_For_Offers`, `Gated_Not_Acquisition`,
`LLM_Unavailable` all filter on `Outcome__c` substrings). Neither of these two constants is named in
those filters as far as I could see, but the developer must confirm before touching either constant,
and must **not** back-fill historical rows (standing precedent in this class).

---

## 3. DEFECT 3 — the listing broker is extracted into the wrong slot

### 3.1 Confirmed: this is a prompt defect, and `CallForOffersStampService` is CORRECT

The service received nulls and wrote nothing. That is the deliberate W1 rule — *"passing null
preserves what the deal knows"* — working exactly as designed. **Do not touch that service for this
defect.**

### 3.2 The rule already exists, so "add a rule" is not the fix

L377–381 already says: *"BROKER vs LISTING BROKER: broker_name / broker_email are the sender of the
[email] … NEVER put the listing broker into broker_name or broker_email."* The model disobeyed it.

🔴 **And there is a structural reason it might have to.** L344–345 declares the byte-pinned legacy
block **AUTHORITATIVE for `broker_name`, `broker_email`, `property_address` and `sent_datetime`**,
and the legacy rule takes those from the outermost `From:` line. On this email the envelope sender
was a platform (`listings@zzmarketplace.com`), and U1 stood down because
`From_Address__c == Forwarded_By__c` (the paste-forward guard) — so **nothing** demoted Dana either.
If the body carried no usable `From:` line (uncertainty **U-3**), the model had no legacy candidate
at all and fell back to the only named human in the text.

That diagnosis, if confirmed, decides the shape of the fix:

- ❌ **Wrong fix:** repeat the prohibition more forcefully. It contradicts a block declared
  authoritative for those exact keys, and the model will keep resolving the conflict pragmatically.
- ✅ **Right fix (per the module's own established framing):** state the case the legacy rule does
  **not cover**. *"When the outermost `From:` line is a listing platform or automated mailbox rather
  than a person, `broker_name`/`broker_email` describe that sender; a person named in the body under
  a 'Listing broker:' style label is `listing_broker_name`/`listing_broker_email` and MUST NOT be
  promoted into `broker_*`."* This does not contradict the legacy rule — it answers a case the legacy
  rule is silent on, which is what keeps the byte-pin honest.

### 3.3 Blast radius — this IS an arbitration change

`broker_email` is one of the module's three arbitration inputs (repeat detection,
`Competing_Broker_Submission__c.Broker_Email__c`). A change to how it is determined changes **who
wins a property**. It must therefore ship with the regression check in §5, not on a code review
alone. `property_address` is untouched, so **no `Property_Key__c` moves** — the change is bounded to
attribution, not to claim identity. State that bound explicitly in the developer prompt.

---

## 4. DEFECT 4 — `Sale_Process__c` contradicts what the pipeline knows

### 4.1 The argument

`CallForOffersStampService` has two per-field rules, and they are not arbitrary:

- **offer due date → last-wins**, because a deadline is a fact about **the campaign** and it
  *changes* ("extended to Friday"). Fill-if-blank would freeze the first date and make an extension
  invisible.
- **listing broker → not even a fallback**, because the listing broker on a live deal is a fact about
  **the transaction**, and a third party's blast is not newer information about it.

Where does `sale_process` fall? **It is a fact about the campaign, in the same class as the
deadline.** "This asset is now being sold via a call for offers" is a statement about how the seller
is running the process — the same subject the deadline describes — and it genuinely *changes*: an
off-market deal that goes to a marketed call-for-offers has materially changed, and a deal reading
`Off-Market` while the pipeline holds an email announcing a call for offers is actively misleading
the deal team.

**Recommendation: YES — `Sale_Process__c` joins the last-wins stamp set**, with the same three
guards the existing fields carry: a null/blank incoming value is never written; a record where
nothing would change is dropped from the update list; requests are merged by `recordId` before the
DML.

### 4.2 One extra guard this field needs that the others do not

🔴 **`Sale_Process__c` is a RESTRICTED picklist.** An off-list value from the model **does not throw
at compile time**, and depending on restriction it either throws at runtime and takes the whole
`Database.update` statement with it, or stores silently. This module already has the precedent:
`LeadConvertService` **describe-guards every restricted-picklist write** (`Sale_Process__c` among
them) precisely so one illegal value cannot roll back a batch. **The stamp write must be
describe-guarded the same way**, against the live picklist, not against a hardcoded list. This is the
single most likely way a correct-looking implementation of Defect 4 breaks in production.

⚠ Also confirm the prompt's enumeration (L488: `Off-Market, On-Market Listing, Call for Offers, …`)
matches the **field's** value set exactly. A prompt value that is not a picklist value is an
extraction that can never be stored — silently.

---

## 5. Prompt-change risk register (constraint-mandated)

| Change | Prompt block | Re-pins a fixture? |
| --- | --- | --- |
| Defect 1 (a) — narrow `call_for_offers` | **ENRICHED** (classification paragraph, ~L456–468) | ❌ No. `ExtractionRegressionFixtureTest` pins `LEGACY_EXTRACTION_RULES` + `LEGACY_RESPONSE_FORMAT` only. |
| Defect 3 — platform-sender clause | **ENRICHED** (BROKER vs LISTING BROKER, ~L377–381) | ❌ No — **provided** the legacy block at L320–345 is not touched. If a developer edits the legacy block instead, it **does** re-pin the fixture test and the change class flips from low-risk to high-risk. Say no. |
| Defect 4 — none needed | — | `sale_process` is already extracted; this is an Apex-only change. |

**`extract(String, String, String)` and `MAX_INPUT_CHARS` are NOT changed by any item here.** Every
prompt change is content inside the existing constants. The §3.3 ASB re-homing promise is preserved.

**Hold `MODEL` and `temperature = 0` constant** across this whole change set. Changing them alongside
the prompt makes any regression unattributable.

**Regression verification is free and is mandatory for Defect 3.** The org holds `Raw_Body__c` and
`Extracted_JSON__c` for every email ever processed. Re-run the new prompt against a sample and assert
the **same `broker_email`** and the **same `normalizeAddress(property_address)`** — not "similar", the
same normalized key, because that key *is* the claim identity.

---

## 6. Test obligations (rules check, as requested)

**`.claude/rules/bulk-test-rule.md` narrowed exemption — checked.** The exemption covers
**`LLMExtractionCalloutService` ONLY**. `ExtractAddressQueueable`, `PropertyClaimService` and
`EmailToLeadService` are **NOT exempt**, and every code change proposed here lands in
`ExtractAddressQueueable`. A literal 251 remains impossible and meaningless (enqueue caps at 50; SOQL
exhausts at ~14–24 properties) — the required replacements are the five named in that rule:
10-property volume, 15-property truncation, governor headroom, mixed outcome, ordering determinism.

🔴 **Governor budgets are pinned as EQUALITY assertions and any new query breaks them. Hand the
developer these exact numbers** (from `ExtractAddressQueueable`'s own header):

| Assertion | Value | Kind |
| --- | --- | --- |
| `ExtractAddressQueueableTest:3690` `singlePropertyDmlBudget` | 7 | **EQUALITY** |
| `ExtractAddressQueueableTest:1214` `DML_BUDGET` (N=10) | 43 | **EQUALITY** |
| `:2673`, `:3475` `singlePropertyDmlBudget` | 20 | ceiling (≤) |
| Query budget N=1 (`:2672`, `:3474`) | 30 | — |
| Query budget N=10 (`:1206`) | 120 | — |

⚠ Assert headroom on `ExtractAddressQueueable.lastRunQueryCount` / `lastRunDmlCount`, captured
**inside** the async context — never on `Limits.*` after `Test.stopTest()`, which restores pre-test
counters and makes the obvious assertion silently vacuous.

⚠ **Option (a′) must not add a query.** The blast-signal predicate must read only fields already on
the loaded staging row (see uncertainty **U-2**). If the required header material is not already on
the row, that is a **finding to report back**, not a licence to add a read — a second read on this
path breaks two equality assertions and a pinned budget.

---

## 7. Work breakdown

### 🔵 ADMIN WORK (`salesforce-admin`)

Only if the Gate-1 answers select them — **none of this is unconditional**.

- **A1 (only if Gate-1 D1 = option b or c):** validation-rule change on `Property_Registry__c` and/or
  `Competing_Broker_Submission__c` to permit an anchorless row. **Verify U-1 first.**
- **A2 (only if Gate-1 D4 = yes):** confirm `Opportunity.Sale_Process__c`'s value set matches the
  prompt's enumeration exactly (`Off-Market`, `On-Market Listing`, `Call for Offers`, …), and confirm
  FLS is granted where the sibling stamped fields (`Offer_Due_Date__c`, `Listing_Broker_*__c`) are
  granted — not where the feature lives.
- **A3 (only if Gate-1 D2C = "watch list"):** a list view / report for the branch (c) no-information
  population.

**If the recommended options are taken (D1 = a′, D2 = 2A+2B, D3 = prompt, D4 = yes), the only admin
item is A2.**

### 🟢 DEVELOPER WORK (`salesforce-developer`)

- **DEV-1 — Defect 1 (a′):** enriched-block prompt narrowing + a deterministic blast-corroboration
  predicate in `ExtractAddressQueueable`, consulted by `isCallForOffersGated`.
- **DEV-2 — Defect 2:** conditional hard gate (2A) + empty-property skip in `firstProperty` (2B).
- **DEV-3 — Defect 3:** enriched-block platform-sender clause. Prompt only.
- **DEV-4 — Defect 4:** `saleProcess` added to `CallForOffersStampService.StampRequest` + a
  **describe-guarded** last-wins `buildChange` rule.

**Order:** DEV-3 and DEV-1's prompt half are the same file and should ship together in one prompt
edit. DEV-2 and DEV-4 are independent of both.

---

## 8. EXACT PROMPTS FOR IMPLEMENTATION AGENTS

### 🟢 PROMPT — `salesforce-developer` — DEV-1 + DEV-3 (prompt edits, one file)

```
Edit LLMExtractionCalloutService's prompt CONSTANTS only. Two changes, both in the ENRICHED
block (everything AFTER the "=== END OF THE ORIGINAL RULES ===" marker at ~L344).

🔴 HARD CONSTRAINTS — read before writing:
- Do NOT change extract(String,String,String) or MAX_INPUT_CHARS. The class header's ASB
  re-homing promise (ARCHITECTURE §3.3) depends on both.
- Do NOT edit LEGACY_EXTRACTION_RULES or LEGACY_RESPONSE_FORMAT (~L320-345). They are
  byte-pinned by ExtractionRegressionFixtureTest. Editing them flips this from a low-risk
  change to a high-risk one and re-pins that test.
- Do NOT change MODEL or temperature.

CHANGE 1 (Defect 1) — narrow what call_for_offers MEANS, in the classification paragraph
(~L456-468). Today an offering memorandum that merely quotes a bid deadline is classified
call_for_offers at category_confidence 1.0, which suppresses the Lead AND the registry claim,
and a MEASURED consequence was a named broker losing a property to a second broker who sent the
same asset without a deadline sentence. State explicitly that an OM from a named individual
broker addressing DPEG directly is `acquisition_deal` EVEN IF it states an offers-due date, and
that call_for_offers requires a mass-distribution/marketed-campaign shape.

CHANGE 2 (Defect 3) — in the BROKER vs LISTING BROKER paragraph (~L377-381). The existing
"NEVER put the listing broker into broker_name or broker_email" rule was DISOBEYED on a live
email that said "Listing broker: Dana Whitfield, dana.whitfield@zzbrokergamma.com" — Dana came
back in broker_name/broker_email and listing_broker_* was empty. Do NOT simply restate the
prohibition. The legacy block is declared AUTHORITATIVE for broker_name/broker_email and takes
them from the outermost From: line; on that email the sender was a platform
(listings@zzmarketplace.com). ADD the case the legacy rule does not cover: when the outermost
From: line is a listing PLATFORM or an automated mailbox rather than a person, that sender is
broker_name/broker_email, and a person named in the body under a "Listing broker:"-style label
goes to listing_broker_name/listing_broker_email and must NOT be promoted into broker_*.

FIRST: read the raw body of the staging row for that email in usman-dpeg and confirm whether it
carried a From: line at all. If it did not, say so — it changes the wording.

⚠ THIS IS AN ARBITRATION CHANGE. broker_email drives repeat detection and
Competing_Broker_Submission__c.Broker_Email__c. property_address is untouched, so no
Property_Key__c moves — keep it that way and state the bound in your summary.

VERIFICATION: prompt effects are not unit-testable. Re-run the new prompt against existing
Inbound_Email_Staging__c rows (Raw_Body__c + Extracted_JSON__c are retained for every email ever
processed) and assert the SAME broker_email and the SAME
PropertyMatchingService.normalizeAddress(property_address) — the same normalized key, not a
similar one. Report any row where either moved.

Do not deploy.
```

### 🟢 PROMPT — `salesforce-developer` — DEV-1 Apex half (blast corroboration)

```
In ExtractAddressQueueable, make the U2 call-for-offers gate TWO-FACTOR.

Today isCallForOffersGated (~L2848) is one condition:
    return LLMExtractionResult.CATEGORY_CALL_FOR_OFFERS.equals(extraction.emailCategory);
That single model opinion suppresses the Lead AND the registry claim. MEASURED: an ordinary OM
from a named broker was classified call_for_offers at category_confidence 1.0 and the property
was then won by a different broker.

Add a SECOND factor of a DIFFERENT KIND — a deterministic, transport-layer blast signal Apex can
check, NOT another model field. Suppress only when the category matches AND at least one blast
signal holds. Candidate signals: multiple To/Cc recipients, `Precedence: bulk`,
`List-Unsubscribe:`, a platform sender domain, or no resolvable individual broker identity.

🔴 STEP 1, BEFORE ANY CODE — establish what is actually available. Confirm which of those signals
the Inbound_Email_Staging__c row already carries. I confirmed it holds Raw_Body__c, Subject__c,
From_Address__c, From_Name__c, Forwarded_By__c, Message_Id__c, In_Reply_To__c, References__c. I
did NOT confirm To/Cc or raw headers. If the material is not already on the loaded row, STOP AND
REPORT — do not add a query (see the budget constraint below).

🔴 STEP 2 — do NOT gate on category_confidence. It was 1.0 on the failing email; no threshold on
that field would have prevented this. ARCHITECTURE reserves that field as a future lever; this
measurement retires it for THIS failure. Say so in your summary.

🔴 STEP 3 — THE PROHIBITION YOU ARE NOT VIOLATING, AND YOU MUST SAY SO IN A COMMENT.
SENDER_CONTAINS' Javadoc (~L539-572) carries a 🔴 "DO NOT ADD `bulk`, `List-Unsubscribe`, OR ANY
OTHER BLAST SIGNAL". That governs the PRE-CALLOUT filter, where such a signal would SUPPRESS an
email before the model judged it. Yours runs POST-callout and can only ever turn a gate OFF —
it makes suppression HARDER, never easier. That is the direction the same comment demands ("Bulk
mail must reach the LLM and be classified there"). Write that distinction into the code comment
or the next reviewer will reject it on a first-sentence read.

BUDGET — NON-NEGOTIABLE. This class has EQUALITY-asserted governor budgets:
singlePropertyDmlBudget = 7 (Test:3690), DML_BUDGET = 43 at N=10 (Test:1214), query budgets 30 at
N=1 and 120 at N=10. Your predicate must add ZERO queries and ZERO DML. Assert headroom on
lastRunQueryCount / lastRunDmlCount captured inside the async context — never on Limits.* after
Test.stopTest(), which restores pre-test counters and makes the assertion vacuous.

U2's CORE RULE IS UNCHANGED: a genuine blast still produces no Lead and no claim.

Bulk testing: .claude/rules/bulk-test-rule.md's narrowed exemption covers
LLMExtractionCalloutService ONLY — this class is NOT exempt. Provide the five replacements:
10-property volume, 15-property truncation, governor headroom, mixed outcome, ordering
determinism.

Do not deploy.
```

### 🟢 PROMPT — `salesforce-developer` — DEV-2 (relevance gate + empty property)

```
Two related fixes in ExtractAddressQueueable. MEASURED: an internal email ("Team lunch Friday +
Q3 expense reports", ops@zzinternal.com) created a Lead named "Office Ops / Unknown - Via Email".

FIX 2A — isHardGated (L1152-1155) is a CONJUNCTION:
    isAcquisitionRelated == false && BAND_HIGH.equals(confidenceBand)
The extraction was CORRECT (is_acquisition_related = false) but confidence was 0.0, so the band
was LOW and the gate did not fire. The model must be both right AND confident to suppress
anything.

Do NOT simply lower the floor. The asymmetry is deliberate and documented: generosity is the
correct bias for a first-come-first-served ledger, because claiming a junk address costs a
deletable registry row while failing to claim a real one costs a broker their commission.
That argument holds for emails that NAME A PROPERTY and has no force for an email that names
nothing. Make the gate conditional on whether anything is at stake:

  suppress when is_acquisition_related == false AND ( band == HIGH OR the email yielded no
  addressable property and no property name )

FIX 2B — firstProperty (L1497) returns the first NON-NULL element. The extraction returned one
structurally EMPTY property object (name '', address ''), which is non-null, so `stampable` was
non-null and routeNoProperty (L1483-1485) labelled the Lead OUTCOME_NO_ADDRESS instead of
OUTCOME_NO_PROPERTY. OUTCOME_NO_ADDRESS is the population an admin must CHASE THE ADDRESS for, so
a team-lunch email is now sitting in it. Skip properties with no name AND no address.

⚠ CORRECT A LIKELY MISREADING: the empty property object did NOT make branch (c) reachable.
routeProperties L1184 falls into routeNoProperty whenever the WORK-LIST is empty, and
buildWorkList drops blank addresses — so zero properties and one empty property both land there.
Branch (c) creating a Lead is by design (it is also the LLM-outage landing point). 2B changes the
LABEL only. Do not "fix" branch (c) itself under this ticket.

⚠ Outcome__c labels have deployed list-view couplings elsewhere in this class
(Gated_Call_For_Offers, Gated_Not_Acquisition, LLM_Unavailable all filter on substrings). Confirm
no deployed view filters on OUTCOME_NO_ADDRESS / OUTCOME_NO_PROPERTY before touching either
constant, and do NOT back-fill historical rows — that is standing precedent in this class.

Budget and bulk-test constraints are identical to the DEV-1 Apex prompt: zero added queries, zero
added DML, equality-asserted budgets (7 / 43 / 30 / 120), five bulk replacements, headroom
asserted on lastRunQueryCount inside the async context.

Do not deploy.
```

### 🟢 PROMPT — `salesforce-developer` — DEV-4 (`Sale_Process__c` joins the stamp set)

```
Add Sale_Process__c to CallForOffersStampService's last-wins stamp set.

MEASURED: after a call-for-offers stamp, Opportunity.Sale_Process__c still read 'Off-Market'
while that same extraction returned sale_process = "Call for Offers". The service writes only the
deadline and the listing-broker fields.

WHY IT BELONGS IN THE LAST-WINS SET — argue it in the code comment against the service's two
existing per-field rules, do not just add a field: the offer deadline is last-wins because it is
a fact about THE CAMPAIGN and it CHANGES; the listing broker is not even a fallback because it is
a fact about THE TRANSACTION and a third party's blast is not newer information about it.
sale_process is a fact about the CAMPAIGN, in the deadline's class: "this asset is now being sold
via a call for offers" is a statement about how the seller is running the process, and it
genuinely changes when an off-market deal goes to a marketed campaign.

Keep all three existing guards: a null/blank incoming value is NEVER written (so an email silent
about the process cannot erase what the deal knows); a record where nothing would change is
dropped from the update list entirely (zero DML — this is what makes replay a no-op); requests are
merged by recordId before the DML (a duplicate Id in one Database.update throws DUPLICATE_VALUE
for the WHOLE statement and allOrNone=false does NOT rescue it).

🔴 ONE GUARD THE EXISTING FIELDS DO NOT NEED: Sale_Process__c is a RESTRICTED picklist. An
off-list model value does NOT fail at compile time — it throws at runtime and can take the whole
Database.update with it, or stores silently. DESCRIBE-GUARD the write against the LIVE picklist,
never a hardcoded list. LeadConvertService already does exactly this for Sale_Process__c among
others, for exactly this reason — follow that precedent.

Also confirm the prompt's enumeration (LLMExtractionCalloutService ~L488: "Off-Market, On-Market
Listing, Call for Offers, ...") matches the field's value set exactly. A prompt value that is not
a picklist value is an extraction that can never be stored, silently. Report any mismatch; do not
change the prompt under this ticket.

Bulk/budget constraints as per the other prompts. Do not deploy.
```

### 🔵 PROMPT — `salesforce-admin` — A2 (only if Gate-1 D4 = yes)

```
Two verification tasks for Opportunity.Sale_Process__c, supporting the CallForOffersStampService
change:

1. Report the field's exact value set and whether it is restricted. Compare it to the values the
   extraction prompt enumerates: Off-Market, On-Market Listing, Call for Offers (plus any others
   in LLMExtractionCalloutService ~L488). Report any value present in one and not the other — a
   prompt value that is not a picklist value is an extraction that can never be stored.

2. Confirm FLS on Sale_Process__c is granted in the SAME permission set(s) where the sibling
   stamped fields (Offer_Due_Date__c, Listing_Broker_Name__c, Listing_Broker_Email__c) are
   granted. Grant it where the SIBLINGS live, not where the feature lives.
   ⚠ profiles/** is .forceignore'd in this repo, so any grant that matters must be declared IN a
   permission set file. And a PermissionSet deploy REPLACES its whole fieldPermissions set —
   reconcile the org's live grants into the file before deploying it, or an org-side-only grant
   will be silently wiped.

Report only. Do not deploy.
```

---

## 9. 🚦 GATE 1 — USER DECISIONS

| # | Decision | Options | Recommendation | Why it matters |
| --- | --- | --- | --- | --- |
| **D1** | **Defect 1 — how to stop an ordinary OM costing a broker their claim. LOAD-BEARING.** | (a) narrow the classifier · **(a′) narrow + deterministic blast corroboration** · (b) suppress Lead but take the claim · (c) audit submission row only · (d) status quo + better watch surface | **(a′)** | Only option that fixes the measured case, keeps U2's core rule intact, needs no schema/VR change, and reverses no written prohibition. (b) is blocked three ways incl. `registerWinner`'s DO-NOT-ADD-A-THIRD; (c) cannot insert a row for the very population it protects (no anchor exists yet). |
| **D2** | Does U2's core business rule change? | No / Yes | **No** | (a′) leaves it intact — a genuine blast still produces no Lead. **Flagging as required: if you choose (b) or (c), you ARE weakening it and that is your call to make explicitly.** |
| **D3** | Defect 2 — the D2 relevance-gate conjunction | leave · lower the floor globally · **make it conditional on whether a property is at stake** | **conditional** | Lowering the floor globally would start suppressing low-confidence REAL broker emails — re-creating Defect 1's failure in a new place. |
| **D4** | Defect 2 — should a branch (c) Lead with no property name AND no address exist at all? | create it (today) · suppress it · create + flag | **suppress it** (covered by D3's conditional gate) | Such a Lead carries no information whatsoever (`Office Ops / Unknown - Via Email`). But branch (c) is also the LLM-outage landing point, so the suppression must key on "the model answered and found nothing", never on "we have no extraction". |
| **D5** | Defect 3 — fix the prompt | yes / no | **yes, enriched block only** | Re-pins no fixture test **provided** the legacy block is untouched. It IS an arbitration change (`broker_email`), so it ships with the regression check in §5. |
| **D6** | Defect 4 — `Sale_Process__c` joins the last-wins stamp set | yes / no | **yes** | It is a fact about the campaign, in the deadline's class, not the listing broker's. Requires a describe guard the other stamped fields do not need. |
| **D7** | Follow-on: record a `Competing_Broker_Submission__c` for near-misses where an anchor already exists | yes / no / later | **later** | Genuine value for commission disputes, but it needs U-1 resolved and does not help the measured case. Ship (a′) first and measure the gated population off `Extracted_JSON__c` for a week — staging rows are never deleted, so that corpus is free. |

---

## 10. Before any of this is built

1. **Answer D1.** Options (b)/(c) add admin/schema work and reverse written prohibitions; (a′) does
   not. The rest of the plan changes shape depending on the answer.
2. **Resolve uncertainties U-1, U-2, U-3** (§0). U-2 in particular can invalidate part of (a′)'s
   mechanism, and the honest response to that is to report it, not to add a query.
3. **Hold `MODEL` and `temperature` constant** across the whole change set so any regression is
   attributable.
