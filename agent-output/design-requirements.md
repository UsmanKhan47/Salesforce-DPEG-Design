# DESIGN REQUIREMENTS — `building_sf` extraction gap (Broker Protection prompt)

**Date:** 2026-08-31
**Agent:** salesforce-design
**Status:** Requirements only. No implementation files were written by this agent.
**Builds on:** `docs/2026-08-31-cmdt-longtext-truncation-p0.md` (deployed earlier today)

---

🔴 **EVERY `:NNN` LINE CITATION BELOW IS STALE. NAVIGATE BY REGION NAME, NEVER BY NUMBER.**
Added 2026-08-31 after code review W3. The implementation added ~135 lines of class header to
`LLMExtractionCalloutService.cls`, shifting every cited region downward. The numbers are deliberately
**not** being re-resolved — for the same reason the prompt length is no longer pinned, they would go
stale again on the next edit. Two are actively dangerous if followed literally:

| This doc says | Now actually at | What the OLD number points at TODAY |
|---|---|---|
| narrow the `lot_size_sf` bullet at `:672-673` | `:808-811` | 🔴 **inside `LEGACY_EXTRACTION_RULES`, marked DO NOT EDIT** |
| "DO NOT TOUCH the response template (`:810-822`)" | `:985-997` | 🔴 **the new `building_sf` bullet this change exists to add** |
| "DO NOT TOUCH the picklist value lines (`:823-835`)" | `:998-1010` | the anti-hallucination numeric / `cap_rate` / `year_built` bullets |
| INPUT SHAPE `:562-579` | `:696-715` | the `LEGACY_RESPONSE_FORMAT` Javadoc |
| `broker_company` `:613-660` / `sent_datetime` `:661-666` | `:749-796` / `:797-802` | the `LEGACY_EXTRACTION_RULES` declaration and Javadoc |
| `field_confidence` exemplar list `:797` | `:971-972` | `sent_datetime WHEN NO DATE IS STATED` |

The region **names** used throughout are correct and are the reliable handle. This matters most in
§6 V1 (the reviewer's mechanical diff checklist) and §13 (the next architect's do-not-touch list): a
reviewer following V1 by number today would inspect six wrong regions and pass.

---

## 0. WHAT THE USER REQUESTED

Reinforce the LLM extraction prompt so that building square footage stated plainly in a broker
email lands in `properties[].building_sf` and therefore on `Lead.Building_SF__c`.

Measured evidence supplied by the user, accepted as given and **not re-derived here**: Lead
`00Qiw000000wZVHEA2` on `usman-dpeg`, 2026-08-31. Every deal field extracted except
`Building_SF__c`. `Inbound_Email_Staging__c.Extracted_JSON__c` `properties[0]` contains **no
`building_sf` key at all**; the number "112,400 square feet" appears only in the prose
`deal_summary`. `LLMExtractionParser.cls:356` and `EmailToLeadService.cls:743` both handle the
field correctly. This is a prompt defect, not a code defect.

---

## 1. 🔴 THE BRIEF'S DIAGNOSIS IS RIGHT ABOUT THE SYMPTOM AND INCOMPLETE ABOUT THE CAUSE — READ THIS FIRST

The brief frames this as **under-reinforcement** (mention count 1 vs 2–5). Mention count is a
correlate, not the mechanism. Reading the prompt structurally gives a sharper and more actionable
cause, and it changes what the fix has to do.

### 1.1 The real discriminator is "rule-bearing text" vs "template-only"

Every schema key in the prompt falls into one of two classes:

- **Rule-bearing** — the key has at least one sentence somewhere in `ENRICHED_EXTRACTION_RULES`
  that *defines it, bounds it, or formats it*. Examples, all of which extracted correctly:
  - `unit_count` — defined (`LLMExtractionCalloutService.cls:685`, "apartment units, or hotel keys
    for a hospitality asset") **and** named as readable from the Subject line (`:565`).
  - `cap_rate` / `occupancy_pct` — an explicit units rule (`:676-677`, "6.75 means 6.75 percent …
    never 0.0675").
  - `year_built` / `year_renovated` — a format rule with a worked example (`:678-679`, "88/22").
  - `noi` — a disambiguation rule (`:680-681`, adjusted beats reported) plus a derivation
    prohibition (`:669-671`).
  - `guidance_price*` — a single-vs-range routing rule (`:682-684`).
  - `listing_status` — an eleven-line definition with positive and negative wording (`:697-708`).
- **Template-only** — the key appears **only** inside the JSON response shape at `:810-822` and
  nowhere else. The model is shown a slot and told nothing about what belongs in it.

`building_sf` is template-only. That is the mechanism: not "mentioned once", but **"never
defined."** The distinction matters because it dictates the shape of the fix — a definition
sentence in the style of its successful peers, not three more occurrences of the token.

### 1.2 🔴 AND `building_sf` IS NOT MERELY UNDEFINED — THE PROMPT ACTIVELY ROUTES SQUARE FOOTAGE SOMEWHERE ELSE

This is the finding that changes the fix, and it is not in the brief.

The literal string "square feet" appears **three times** in the prompt. Every one of them is
about **land**, or is a prohibition:

| Line | Text | Effect |
|---|---|---|
| `:670-671` | "do not convert square feet to acres or acres to square feet" | prohibition |
| `:672-673` | "`lot_size_acres` ONLY if the email states acres. **`lot_size_sf` ONLY if it states square feet.** Never fill both from a single figure." | **routes "square feet" → `lot_size_sf`** |
| `:758` | "(name, address, square feet, occupancy, guidance price, cap rate)" | a classification exemplar, not an extraction rule |

**Zero occurrences in the entire prompt associate square footage with the BUILDING.** The only
routing rule that fires on the exact phrase in the failing email ("112,400 square feet") points at
`lot_size_sf`, and its trailing sentence — "Never fill both from a single figure" — then explicitly
forbids the model from also populating `building_sf`. A model obeying the prompt literally is
**instructed** to do what it did.

### 1.3 🔴 THE MIS-ROUTE HAS A SILENT DATA-CORRUPTION PATH, AND IT MAY ALREADY BE LIVE

`lot_size_sf` is not a stored field. `LLMExtractionParser.cls:361` reads it as a *fallback input*
and converts it:

```apex
property.lotSizeAcres = acres(raw.get('lot_size_acres'), raw.get('lot_size_sf'), result);
```

`EmailToLeadService.cls:745` then writes `lead.Lot_Size_Acres__c = property.lotSizeAcres;`. There
is no `Lot_Size_SF__c`.

So if the model routes a **building** square footage into `lot_size_sf`, the parser silently
converts it to acres and stamps a **fabricated lot size** on the Lead. No exception, no note, no
log — and unlike the null `Building_SF__c`, a wrong `Lot_Size_Acres__c` looks like a successful
extraction.

⚠ **This design agent has no org access and cannot check whether that happened.** It is therefore
a **mandatory pre-work measurement** (step 1 of the execution order), not an assumption. The answer
changes the classification of this ticket:

- `lot_size_sf` absent on the failing row ⇒ pure omission; the fix is additive.
- `lot_size_sf` = 112400 (and/or `Lot_Size_Acres__c` ≈ 2.58 on Lead `00Qiw000000wZVHEA2`) ⇒ this is
  a **mis-routing defect with live bad data**, the `lot_size_sf` bullet must be narrowed as part of
  the fix (it is), and a corpus sweep for other affected Leads becomes a separate user decision.

⚠ Not a defect, do not "fix" it: the prompt forbids **the model** from converting sq ft ↔ acres
while the **parser** converts deterministically. That asymmetry is deliberate — a deterministic
conversion is auditable, a model's is not.

### 1.4 The full template-only inventory — answering "is any other field exposed?"

The brief noted `price_amount` returned 0 mentions. Correct: there is no such key. The real
price keys are `guidance_price`, `guidance_price_low`, `guidance_price_high`, and all three are
rule-bearing (`:682-684`). The actual schema is the response template at `:810-822`.

Checked against the whole schema, **nine** keys are template-only:

| Key | Template-only | Competing rule routes its text elsewhere? | Risk |
|---|---|---|---|
| **`building_sf`** | ✅ | 🔴 **YES — `lot_size_sf` (`:672-673`)** | **HIGH — measured failure + corruption path** |
| `broker_phone` | ✅ | no | Low — self-describing, sits in signature blocks |
| `broker_mobile` | ✅ | no | Low, but ambiguous against `broker_phone` when only one number is given |
| `broker_title` | ✅ | no | Low |
| `walt_years` | ✅ | no | Medium — an acronym with no expansion anywhere in the prompt |
| `adr` | ✅ | no | Medium — an acronym; hospitality-only; bounded by `MAX_ADR` in the parser |
| `zoning` | ✅ | no | Low |
| `seller_entity` | ✅ | no | Low |
| `deal_room_link` | ✅ | no | Low |

`building_sf` is the only one of the nine with an **active competing instruction**, which is why it
is the one that produced a measured failure. The other eight are *unmeasured*, and the honest
response is to measure rather than to add eight speculative sentences to a prompt that re-keys the
broker registry every time it is edited — see decision **D2** below.

---

## 2. 🔴 THE TRAP — CARRIED FORWARD IN FULL

**An Apex-only change will do nothing at runtime.** Restated here because it is the single most
likely way this ticket ships as a false success.

- The org's `Broker_Protection_Config.Default` record now holds a populated `Extraction_Prompt__c`
  of **20,596 characters** — a copy of the *current* shipped prompt, written by
  `scripts/load-broker-protection-config.apex` after today's truncation fix. Verified state
  supplied by the user (`accessor len=20596`), not a hypothesis.
- `LLMExtractionCalloutService.resolvePrompt()` **prefers the configured record over the
  constant**. Editing `EXTRACTION_INSTRUCTION` and deploying it therefore changes nothing that
  reaches OpenAI. The deploy is green, the tests are green, the behaviour is unchanged.
- 🔴 **Re-running `scripts/load-broker-protection-config.apex` is a mandatory, ordered step AFTER
  the Apex deploy** — not an optional refresh, not a follow-up.

Three operational properties of the loader that the execution order must respect:

1. **It seeds from `LLMExtractionCalloutService.shippedPrompt()`, not from a transcribed literal**
   (`scripts/load-broker-protection-config.apex:55`). There is therefore **no second copy of the
   prompt to edit** — one Apex edit plus one loader run is sufficient and correct. Confirmed by
   reading the file; do not go looking for a duplicate.
2. **It must run AFTER the class is deployed**, or line 55 throws "Variable does not exist" and
   nothing is written.
3. ⚠ **It is ASYNCHRONOUS** (`Metadata.Operations.enqueueDeployment`, line 111). The record is
   *not* updated when the script returns. Any probe run immediately afterwards reads the OLD value
   and will look exactly like a failed edit. Poll until the value changes before concluding
   anything.
4. ⚠ It **upserts every field**, discarding Setup tuning. Harmless here — the record was seeded
   from the shipped constant hours ago, so there is no hand-tuning to lose — but confirm the record
   has not been edited in Setup since, before running it.

---

## 3. CONSTRAINTS — ALL RESPECTED BY THIS DESIGN

| # | Constraint | How this design honours it |
|---|---|---|
| C1 | 🔴 Editing the prompt **re-keys the broker registry** (`broker_email` + `property_address` are the `Property_Registry__c` claim key) | The edit is confined to the ANTI-HALLUCINATION bullet list and the PER-FIELD CONFIDENCE exemplar list. It adds one bullet and narrows one adjacent bullet by two words. **No instruction governing `broker_email` or `property_address` is touched, reordered, moved or diluted.** Verification is mechanical, not asserted — see §6 V1. |
| C2 | The two manual regression fixtures must run **before and after**, addresses diffed by hand | **UAT D and UAT D′**, defined in `agent-output/design-requirements-extraction-completeness.md` §6.5 and named as recurring checks in `LLMExtractionCalloutService.cls:178-195`. Gate G2/G4 in §7. Not a suggestion. |
| C3 | `ExtractionRegressionFixtureTest` carries a **DO NOT RESTORE** banner (`:310-323`) forbidding a verbatim prompt pin | The one new test (T5) asserts a **structural property** — "no schema key is template-only" — never bytes. §5.2 states the reasoning so the next reader neither deletes it as a banner violation nor "improves" it into a pin. |
| C4 | **Nothing pins the prompt length any more**; `shippedPrompt().length()` is the sole authority; do not reintroduce a pinned figure | 🔴 **AMENDED 2026-08-31 (review W2).** This row originally said the four forward-looking sites would be "re-stated from a live measurement" — i.e. re-pinned with a fresh number. **They were de-pinned instead, and that is the standing policy.** No figure is written back to L1-L4 at any point. §4.2's table is retained as history only; §10 step 8 is CANCELLED. The dated historical probe records remain MUST-NOT-TOUCH (§4.3) — do not confuse the two categories: a dated probe records a measurement taken on a date, a forward-looking claim asserts a current fact. |
| C5 | ⚠ The length is **value-dependent** — `MAX_PROPERTIES_IN_PROMPT` is interpolated twice; counting source literals under-reports by exactly 4 | Every length figure in this plan is produced by executing `LLMExtractionCalloutService.shippedPrompt().length()` against the org (step 5). **No figure in this plan may be obtained by counting.** |
| C6 | The prompt hardcodes `MAX_PROPERTIES_IN_PROMPT` and the restricted picklist values for `deal_type` / `sale_process` / `listing_status` | None of these is touched. The edit sites are `:672-673`, a new bullet immediately after it, and the key list at `:797`. The picklist lines (`:823-835`) and the MULTIPLE PROPERTIES paragraph (`:588-592`) are out of scope. |
| C7 | 🔴 `Deal_Type__c` is **not** a property category — `Retail` there means the Opportunity record type, not the asset class | Nothing in this change touches `deal_type`, `asset_type`, or any alignment between them. Explicitly out of scope; see §4.3. |
| C8 | Assess whether the fix is only mention-count | Assessed. It is not. §1.1–§1.2. The fix mirrors what actually distinguishes the successful fields — a definition, an explicit unit, a worked example, a disambiguation against the nearest competing key, and presence in the `field_confidence` exemplar list. |
| C9 | Assess whether other schema fields are exposed | Assessed. Nine template-only keys enumerated in §1.4; only `building_sf` has a competing rule. Decision D2 offers a measured, non-speculative way to close the rest. |
| C10 | A **concurrent session shares this working tree** | Its files were not read, are not referenced, and no change to them is proposed: dashboards, tabs, `DPEG_Transaction_*` permission sets, seed scripts, `Transaction__c` fields, reports, `LeadConvertService`, `LeadConvertServiceTest`, `TestDataFactory`. |
| C11 | Do not touch `BrokerProtectionConfigSelector`, `BrokerProtectionConfig`, or the truncation guard | Respected. One consequence is flagged as a Gate-1 micro-decision (D3) rather than silently actioned. |
| C12 | `Building_SF__c` already exists and is handled correctly — confirm, do not create | **Confirmed by reading the repo.** §4.4. |

---

## 4. WHAT ALREADY EXISTS — CONFIRMED, NOTHING TO CREATE

### 4.1 The `building_sf` path is intact end to end

| Layer | Evidence | Verdict |
|---|---|---|
| Field | `force-app/main/default/objects/Lead/fields/Building_SF__c.field-meta.xml` | Exists |
| DTO | `PropertyExtraction.buildingSf` | Exists |
| Parser | `LLMExtractionParser.cls:356` — `wholeNumber(raw.get('building_sf'), 'building_sf', MAX_COUNT, result)` | Correct |
| Service | `EmailToLeadService.cls:743` — `lead.Building_SF__c = property.buildingSf;` | Correct |
| FLS | `Broker_Protection_Access` (`:438`, editable), `DPEG_Acquisition_Edit` (`:589`, editable), `DPEG_Acquisition_View` (`:578`, read-only) | Granted — **no permission-set work** |
| Response schema | `LLMExtractionCalloutService.cls:819` — `"building_sf": null` already in the template | Present |

**Nothing needs to be created. The only missing artefact is an instruction telling the model what
the slot means.**

### 4.2 ~~The four sites that pin the prompt length and MUST be updated from a live measurement~~

🔴 **RETRACTED 2026-08-31 (code review W2). THIS SECTION IS HISTORY, NOT AN INSTRUCTION.**
None of L1-L4 pins a length any more. The implementation **de-pinned all four** rather than
re-measuring them, and that is the standing policy — see `LLMExtractionCalloutService.cls`
(`🔴 THE LENGTH IS NOT STATED HERE ... DO NOT ADD A NUMBER`), `scripts/load-broker-protection-config.apex`
(`'Seed prompt length (measured now; no expected value is pinned)'`), and
`BrokerProtectionConfig.cls` (`"some twenty thousand characters" ... DO NOT PUT IT BACK`).
**`shippedPrompt().length()` is the sole authority. Do not reintroduce a figure at any of these
sites.** The table below is retained only so a reader can see what USED to be pinned and where —
this repo has been wrong about that number four times (19,254 → 20,592 → 20,596 → unpinned), and the
fourth correction was the decision to stop pinning it at all.

| # | File | Line(s) | Why it is forward-looking |
|---|---|---|---|
| L1 | `LLMExtractionCalloutService.cls` | `shippedPrompt()` `@return`, `:917-920` | 🔴 **THE DECLARED SOLE AUTHORITY.** `scripts/load-broker-protection-config.apex:67-70` and `Extraction_Prompt__c.field-meta.xml:16-17` both defer to it by name. If this is stale, every other reader is wrong by construction. |
| L2 | `LLMExtractionCalloutService.cls` | `EXTRACTION_INSTRUCTION` header, `:849-859` | States the current length as fact. |
| L3 | `scripts/load-broker-protection-config.apex` | `:71` — `'Seed prompt length (expect 20596 as of 2026-08-31): '` | The operator sanity check the brief names. It is a debug aid; a mismatch means "update this line", never "the prompt is corrupt" (per its own `:68-70`). |
| L4 | `ExtractionRegressionFixtureTest.cls` | `:296` — "ENRICHED_EXTRACTION_RULES is 20,000 of the prompt's 20,596 characters — roughly 97%" | A ratio derived from both figures; both move. **Follow this file's own convention** — append a new `⚠ RE-MEASURED <date>` line, do not overwrite the history. |

### 4.3 🔴 THE SITES THAT CARRY "20,596" AND MUST **NOT** BE TOUCHED

Every one of these is a **dated historical probe of the 2026-08-31 CMDT truncation P0**
(`getInstance` 255 / SOQL 20,596 / `identical = false`). The 20,596 there is a *measurement taken
on a date*, not a claim about the current prompt. Editing them destroys the incident record and
makes a future reader think the P0 was measured against a prompt that never existed.

- `ARCHITECTURE.md` §2 (CMDT long-text carve-out probe table)
- `.claude/skills/sf-apex/SKILL.md` (same probe table)
- `docs/2026-08-31-cmdt-longtext-truncation-p0.md` (the runbook's probe table)
- `BrokerProtectionConfigSelector.cls:20`
- `BrokerProtectionConfigSelectorTest.cls:179`
- `BrokerProtectionConfig.cls:51-53` and `:548`
- `LLMExtractionCalloutServiceTest.cls:12` (class header probe record)
- `agent-output/ba-gap-closure-p8-hub-pass.md`
- `Extraction_Prompt__c.field-meta.xml:11-13` — the `19,254 -> 20,592 -> 20,596` line is a **history
  of past errors**, immediately under "DO NOT PIN A CHARACTER COUNT HERE". Leave it. The field XML
  needs **no change at all** in this ticket.

Also frozen, for reasons stated in their own headers:

- `LEGACY_EXTRACTION_RULES` (`:531-541`) and `LEGACY_RESPONSE_FORMAT` (`:548-552`) — byte-identical,
  "DO NOT EDIT". They are protection 1 and the one-line rollback lever.
- `ExtractionScoreUtil.SCORED_KEYS` — the denominator is **nine, signed off 2026-08-14**, and
  `building_sf` was **cut by the user deliberately** (a land deal has no building SF, so scoring it
  would report a complete extraction as a poor one). 🔴 **Do not add `building_sf` to the score
  because this ticket made it extract better.** `Extraction_Score_Pct__c` will not and should not
  move.
- `MODEL`, `TIMEOUT_MS`, `MAX_TOKENS`, `MAX_INPUT_CHARS`, `MAX_PROPERTIES_IN_PROMPT`, the `ENDPOINT`
  constant, and the `extract(String,String,String)` signature — all unchanged, which is what keeps
  the §3.3 ASB re-homing promise in the class header literally true.

### 4.4 One stale-adjacent site left deliberately untouched — surfaced, not hidden

`BrokerProtectionConfig.cls:529` reads "its default is `LLMExtractionCalloutService
.EXTRACTION_INSTRUCTION`, 20,596 characters of prompt". Unlike §4.3's entries this is a
**forward-looking descriptive claim**, and it goes stale the moment this prompt is edited.

It is **out of scope by explicit user instruction** (C11). It is recorded here rather than silently
left, because this repo has been bitten by a stale prompt-length figure three times. See decision
**D3**.

---

## 5. THE CHANGE

### 5.1 Prompt edit — three parts, all inside `ENRICHED_EXTRACTION_RULES`

🔴 `LEGACY_EXTRACTION_RULES` and `LEGACY_RESPONSE_FORMAT` are untouched, so protection 1 and the
one-line rollback lever both stand, exactly as every prior prompt revision in this class's header
has recorded.

**Part A — narrow the existing `lot_size_sf` bullet (`:672-673`). The one non-additive edit.**

Current: `- lot_size_acres ONLY if the email states acres. lot_size_sf ONLY if it states square
feet. Never fill both from a single figure.`

Required change: make it explicit that this bullet is about **land** area — e.g. "…`lot_size_sf`
ONLY if it states the LAND or SITE area in square feet…". Two words of scoping.

Risk statement the implementer must carry into the class header: this **narrows** `lot_size_sf`
and can widen nothing. It cannot cause a value to be invented; it can only stop a *building* figure
being captured as *land*. It names no legacy value and touches no arbitration key.

**Part B — add a `building_sf` bullet immediately after it.** This site is chosen deliberately:
adjacency is what performs the disambiguation, and the ANTI-HALLUCINATION list is where every
successful numeric field is defined.

It must mirror what actually distinguishes the fields that worked (§1.1), and must contain all of:

1. **A definition** — the area of the BUILDING / improvements, in square feet.
2. **An explicit contrast with the competing key** — building area goes in `building_sf`; land or
   site area goes in `lot_size_acres`/`lot_size_sf`. This is the sentence that repairs §1.2.
3. **A worked example in the house style** (the `property_name` `:584-586` and `year_built` `:678`
   bullets both use one) — e.g. "112,400 square feet of building on a 3.2-acre site" gives
   `building_sf` 112400 and `lot_size_acres` 3.2.
4. **A "do not omit" clause bounded by the existing anti-hallucination rule** — if the email states
   a building size, return it; if it does not, return null. It must **not** license inference, and
   it must not weaken `:668` ("Use null for any value the email does not state").
5. **A prose clause** — a square-footage figure stated in narrative text is still a stated value.
   This is the specific behaviour the failing email exhibited: the model put 112,400 into
   `deal_summary` prose and nowhere else.
6. **No unit conversion** — the existing `:669-671` prohibition already covers it; do not restate
   it in a way that contradicts it.

**Part C — add `building_sf` to the `field_confidence` exemplar key list (`:797`).** Currently
`("noi", "year_built", "cap_rate")` — all three are rule-bearing fields that extracted correctly.
This is the cheapest form of the reinforcement the peers share, and it is inside a paragraph that
is explicitly declared to change no value ("THIS PARAGRAPH ONLY REPORTS ON VALUES YOU HAVE ALREADY
DECIDED", `:805-807`).

⚠ **Do not touch the response template at `:810-822`.** `building_sf` is already there.

### 5.2 One new test — structural, and it must not be turned into a pin

**`LLMExtractionCalloutServiceTest` T5 — the schema-key reinforcement invariant.**

> **Property:** every key present in the JSON response template is mentioned at least once
> elsewhere in the prompt. A key the model is shown a slot for but never told the meaning of is a
> defect by construction.

Why this and not "the prompt contains the string `building_sf` twice":

- It is the **general form of this exact bug**, so it fixes the class rather than the instance and
  directly answers "fixed once rather than one field at a time" (C9).
- It would have failed on the day `building_sf` was added to the schema.
- It survives arbitrary rewording of the prompt, so it never becomes a byte pin under maintenance
  pressure.

🔴 **Compatibility with the DO NOT RESTORE banner** — this must be argued in T5's own header, in the
same shape `LLMExtractionCalloutServiceTest` T1–T4 already use and which the banner explicitly
blesses at `ExtractionRegressionFixtureTest.cls:317-323`:

- T5 asserts a **property of the text**, never its bytes. A prompt edit in Setup or in Apex keeps
  it green; only *adding a schema key with no rule* turns it red.
- ⚠ **Stated limitation, which must be in the header so nobody over-trusts it:** T5 runs against
  `shippedPrompt()` — the **Apex fallback**, not the live Setup value. It says nothing about a
  prompt an admin has edited in Setup. That is precisely the gap the banner describes as
  unclosable, and T5 does not claim to close it.
- ⚠ **Do not "strengthen" T5 by pinning `EXTRACTION_INSTRUCTION`.** The banner forbids it by name.

**Allowlist:** if scope decision **D2** is "`building_sf` only", T5 needs a dated, commented
allowlist of the eight remaining template-only keys from §1.4, each an *accepted, visible*
exception. An allowlist is the honest form — it forces a decision every time a schema key is added,
which is the behaviour that was missing. If D2 is "fix all nine", T5 ships with no allowlist.

### 5.3 What is NOT in this change

- No new field, object, picklist value, permission set, validation rule, page layout, Flow, LWC or
  Named Credential.
- No parser or service change — both are already correct (§4.1).
- No change to `Extraction_Score_Pct__c` or its denominator (§4.3).
- No change to `MODEL`, `MAX_TOKENS`, temperature, or the callout boundary — so any regression is
  attributable to the prompt alone, per protection 2 in the class header.
- No `Opportunity`-side or conversion-side change.
- Nothing in the concurrent session's file set.

---

## 6. VERIFICATION — DESIGNED, NOT ASSUMED

### V1 — Registry safety (C1). Mechanical, not asserted.

1. `git diff` on `LLMExtractionCalloutService.cls` must show **zero changed lines** inside
   `LEGACY_EXTRACTION_RULES` (`:531-541`) and `LEGACY_RESPONSE_FORMAT` (`:548-552`).
2. `git diff` must show **zero changed lines** in every paragraph governing an arbitration value:
   INPUT SHAPE (`:562-579`), BROKER vs LISTING BROKER (`:593-612`), `broker_company`
   (`:613-660`), `sent_datetime` (`:661-666`), and the response template (`:810-822`).
3. The diff must be confined to `:672-673` (Part A), a new adjacent bullet (Part B), `:797`
   (Part C), and comment blocks.
4. `ExtractionRegressionFixtureTest` section 1 must stay green — it pins the parser contract and
   `PropertyMatchingService.normalizeAddress(property_address)` claim-key derivation. It does not
   test the prompt, but a red there means the claim key moved for a non-prompt reason.

### V2 — Manual regression fixtures (C2). A gate, not a suggestion.

Run **UAT D** and **UAT D′** — the two manual fixtures named in `LLMExtractionCalloutService.cls`
(`:178-195`) and defined in `agent-output/design-requirements-extraction-completeness.md` §6.5 —
**against the live pipeline, before the edit and again after the loader re-run**, and diff by hand:

- **D** — re-send a previously-processed email that already owns a registry row and states its
  address in the BODY. Its `property_address` must normalize to the **SAME** `Property_Key__c`. A
  new registry row means the key drifted → roll back.
- **D′** — body states address A, subject states a different address B. Extracted
  `property_address` must normalize to **A**. This is the only case that exercises the
  body-over-subject precedence clause.

Diff `broker_email` and `PropertyMatchingService.normalizeAddress(property_address)` — **the same
normalized key, not a similar address**. Run both or neither.

### V3 — 🔴 THE PROMPT-IS-LIVE PROBE, WITH AN ANTI-VACUITY CONTROL

The brief's probe (compare `shippedPrompt().length()` against the accessor's length) is correct but
insufficient on its own: if the record were absent or blank, the two would match trivially and the
probe would pass while proving nothing. The control is the **intermediate reading**.

Let `B` = 20,596 (the pre-change baseline, both sides) and `N` = the new measured length.

| Stage | `shippedPrompt().length()` | `BrokerProtectionConfig.extractionPromptOverride().length()` | Required |
|---|---|---|---|
| **P0** — before any change | `B` | `B` | Equal. Confirms the record is populated and is a copy of the shipped constant, i.e. **the trap is real on this org.** |
| **P1** — after Apex deploy, **before** loader | `N` (≠ `B`) | `B` | 🔴 **MUST DIFFER.** This is the anti-vacuity control. It proves the deploy landed **and** proves the record override is what is actually being sent. If they match here, either the deploy did not land or the record is blank — and P2's "they match" would then pass vacuously. |
| **P2** — after loader completes | `N` | `N` | Equal, and `N ≠ B`. |

Plus a content probe at P2, because a length match is a weak equality:
`BrokerProtectionConfig.extractionPromptOverride().contains(<a distinctive phrase from the new
building_sf bullet>)` must be `true`.

⚠ The loader is asynchronous (§2.3). At P2, **poll** until `extractionPromptOverride().length()`
changes; do not read once and conclude.

⚠ `getInstance('Default').Extraction_Prompt__c.length()` will still read **255** at every stage.
That accessor is unchanged and still truncates by platform design. Its divergence from
`extractionPromptOverride()` is the proof today's truncation fix is still working, and it is
**not** a symptom of this change.

### V4 — Acceptance. 🔴 NOT A GREEN DEPLOY.

The acceptance criterion is a **live extraction**, per the standing rule in
`docs/2026-08-31-cmdt-longtext-truncation-p0.md` §4 and repeated throughout this class's header
("NONE OF THESE IS UNIT-TESTABLE — the model is mocked in Apex tests, so a green suite says nothing
about any of them"):

1. Re-send the failing email (the source of Lead `00Qiw000000wZVHEA2`). The new staging row's
   `Extracted_JSON__c` `properties[0]` must contain **`"building_sf": 112400`**, and the new Lead's
   `Building_SF__c` must read **112400**.
2. `field_confidence.building_sf` must be **≥ 0.9** — the email states it outright, and the
   `:799-802` rule requires a stated value to score 0.9+. A high `building_sf` score is the signal
   the model treated it as *read*, not *inferred*.
3. 🔴 **CORRECTED 2026-08-31 — THIS ITEM WAS WRONG AND WOULD HAVE ROLLED BACK A CORRECT FIX.**
   It previously read "`Lot_Size_Acres__c` on that new Lead must be **null** (the email states no
   site area)". **The email DOES state a site area:** IES-0000068's `Raw_Body__c` reads *"The hotel
   sits on 4.6 acres"* — measured directly, not inferred. `Lot_Size_Acres__c` is null TODAY only
   because the model dropped `lot_size_acres` by the same key-omission that dropped `building_sf`,
   which is exactly what this change fixes.
   - ✅ **Expect `Lot_Size_Acres__c` = 4.6.** That is the fix WORKING.
   - 🔴 **The mis-route signature is `Lot_Size_Acres__c` ≈ 2.58** — 112,400 sq ft through
     `LLMExtractionParser.cls:361`'s sq-ft→acres conversion (112400 / 43560 = 2.5803). **2.58 is
     the value that means Part A failed and the change must be rolled back.**
   - A null `Lot_Size_Acres__c` now means the key-omission is UNFIXED, not that the mis-route
     closed — it is a partial failure, not a pass.
4. The Lead must **not** land in `Outcome__c = '… — LLM unavailable'`; the `LLM_Unavailable` list
   view remains the standing detection surface and must stay empty for this run.
5. V2's D and D′ pass with byte-identical normalized keys.

⚠ Two named UAT checks in the class header must be re-run for this change set too, because any edit
to this block makes them mandatory: an OM with a bid deadline from a named broker must still come
back `acquisition_deal`, and a genuine marketplace blast must still come back `call_for_offers`.

---

## 7. GATES

| Gate | When | Condition | If it fails |
|---|---|---|---|
| **G1** | Before any edit | The §1.3 measurement is complete: is `lot_size_sf` / `Lot_Size_Acres__c` populated on the failing row? | ✅ **CLOSED 2026-08-31: omission, not mis-routing. No bad data.** (Was) Stop. The answer decides whether this is an omission or a live mis-routing defect with bad data, and whether a corpus sweep is needed. |
| **G2** | Before the Apex edit | UAT **D** and **D′** run and their normalized keys recorded as the "before" baseline | Stop. There is nothing to diff against afterwards, and this prompt has no automated regression guard. |
| **G3** | After Apex deploy, before the loader | Probe **P1** shows `shippedPrompt().length() ≠ extractionPromptOverride().length()` | Stop. Either the deploy did not land or the record is not populated; running the loader now would make P2 pass vacuously. |
| **G4** | After the loader completes | Probe **P2** length equality + the content probe + UAT **D**/**D′** re-run and diffed by hand | Roll back: clear `Extraction_Prompt__c` in Setup (falls back to the shipped constant, the same zero-code unblock used this morning), then revert the Apex. |
| **G5** | Final | V4 acceptance — a real inbound email yields `building_sf = 112400` and `Lot_Size_Acres__c` = **4.6** (🔴 CORRECTED 2026-08-31: this said "null", which is WRONG — the email states "sits on 4.6 acres"; ≈2.58 is the mis-route signature, see §6 V4.3) | The prompt edit did not take. Sharpen the wording; do **not** reach for a code change — the parser and service are already correct. |

---

## 8. USER DECISIONS REQUIRED AT GATE 1

🟢 **ALL THREE WERE ANSWERED AT GATE 1 ON 2026-08-31 AND ARE CLOSED. Recorded here after code
review W6, which found them still presented as open while the code had already been written against
the answers.** The text below is retained as the reasoning that produced each choice.

| # | Question | Answer given | Where it is visible in the code |
|---|---|---|---|
| **D1** | Narrow the `lot_size_sf` rule as well, or define `building_sf` only? | **Narrow it too.** The mis-route was measured as *unrealised* — `Lot_Size_Acres__c` and `lot_size_sf` were both absent on the failing row, so the model omitted rather than mis-routed — but a silent fabricated lot size is worse than a blank field, so the narrowing was taken as **prophylactic, not corrective**. | the narrowed `lot_size` bullet, plus the explicit `"Land SF"/"Lot SF"/"Site SF"` negative |
| **D2** | Fix `building_sf` only, fix it and measure the other eight, or fix all nine now? | **All nine now.** ⚠ The recommendation was *"fix `building_sf`, measure the rest"* — only `building_sf` had an active competing rule and was the only one with a measured failure. The user chose the broader scope, and it was implemented with the mitigation that the eight unmeasured rules stay conservative (define the key and its unit/format; no speculative extraction heuristics), so as not to dilute the five fields that already extract cleanly. | the nine definition bullets |
| **D3** | Lift the scope boundary for a comment-only correction to `BrokerProtectionConfig.cls`? | **Yes** — it carried a forward-looking "20,596 characters" claim that this edit makes stale. Comment only. | `BrokerProtectionConfig.cls` (`"some twenty thousand characters" ... DO NOT PUT IT BACK`) |

⚠ **§13's "deploy scope is exactly three classes" is therefore incomplete** — `BrokerProtectionConfig.cls`
is a fourth, comment-only, via D3. The 5/5-component dry run already reflects this.

**D1 — Confirm the mis-route repair (Part A) is in scope.**
Recommended: **yes.** Adding a `building_sf` definition while leaving `:672-673` telling the model
that "square feet" means `lot_size_sf` leaves two competing instructions in the same bullet list,
and the existing one is the more specific. It is a two-word narrowing that can only reduce
`lot_size_sf` capture. If declined, the fix rests entirely on the new bullet out-competing an
adjacent contradictory rule — a materially weaker position.

**D2 — Breadth: `building_sf` only, or all nine template-only keys?**
Recommended: **`building_sf` only now**, plus a **measurement** to decide the rest. Rationale: every
prompt edit re-keys the broker registry and has no automated guard, so eight speculative sentences
carry eight times the arbitration risk for zero measured evidence. The evidence is free and already
in the org — `Inbound_Email_Staging__c` rows are never deleted and retain `Extracted_JSON__c` for
every email ever processed. A read-only script that computes the **per-key population rate across
the whole staging corpus** identifies which of the eight are actually failing, and turns the next
prompt edit into one evidence-led change rather than a guess.
⚠ That script is **scope beyond the literal request** and is offered as an option, not assumed.
Option (a) `building_sf` only, no corpus script. Option (b) `building_sf` + corpus script,
findings reported, second edit decided separately (recommended). Option (c) all nine now.

**D3 — `BrokerProtectionConfig.cls:529` (§4.4).**
It carries a forward-looking "20,596 characters" claim that goes stale with this edit, and the
brief places that file out of scope. Option (a) leave it stale and rely on this document as the
record; option (b) lift the boundary for a **comment-only** one-line correction, no logic touched.
Recommended: **(b)**, given the repo's three prior stale-length incidents — but it is the user's
boundary to lift, not this agent's.

**D4 — T5's allowlist shape** follows automatically from D2 and needs no separate answer.

---

## 9. ADMIN vs DEVELOPMENT SPLIT

### 🔵 ADMIN WORK (`salesforce-admin`)

**None.**

Explicitly confirmed as already present, not to be created: `Lead.Building_SF__c` exists;
field-level security is granted on `Broker_Protection_Access`, `DPEG_Acquisition_Edit` and
`DPEG_Acquisition_View`; `Extraction_Prompt__c.field-meta.xml` needs no change (its description
already carries the re-keying warning and the manual-fixture rule, and deliberately pins no length).

⚠ The loader re-run and the org probes are **operational**, not declarative — they are DevOps work
(§10, step 6), and they are the steps this ticket fails without.

### 🟢 DEVELOPMENT WORK

**Recommended agent: `salesforce-technical-architect`** (not `salesforce-developer`).

Justification, per `CLAUDE.md`'s complexity routing: `LLMExtractionCalloutService` is the class that
owns the `ARCHITECTURE.md` §3.3 standing direct-callout exception, and this change is
claim-engine-adjacent — the same text edit that fixes `building_sf` can silently re-key the
`Property_Registry__c` ledger. The deliverable is not "write a method"; it is a text edit plus a
three-stage live-org verification protocol with an anti-vacuity control, on a boundary class with no
automated regression guard. The routing guide's tie-break ("when in doubt, if the task involves
integration systems or architectural decisions affecting multiple layers → architect variant")
applies. `salesforce-developer` is defensible if the user prefers, given the edit itself is small.

Work items:

1. Prompt edit Parts A, B, C (§5.1).
2. `LLMExtractionCalloutServiceTest` T5 (§5.2), with the banner-compatibility argument and the
   stated limitation in its header.
3. Length re-statement at **L1, L2, L4** (§4.2) from the **live measured** `N` — never counted.
4. `scripts/load-broker-protection-config.apex:71` — **L3**, `expect <N>` with a dated note.
5. A new dated revision-log section in the class header, following the file's existing convention
   for all ~10 prior prompt revisions, recording: what changed, that LEGACY is untouched, that no
   arbitration value is touched, the Part A narrowing and its risk, and that UAT D/D′ were re-run.

### 🔴 DEVOPS WORK (`salesforce-devops`)

Deploy, run the loader, execute all three probe stages, poll for the async loader completion,
report `N`. See §10.

### 🟣 CODE REVIEW (`salesforce-code-review`)

Required before deployment per the standard workflow. Reviewer must specifically check V1's
mechanical diff conditions and that T5 was not written as a byte pin.

---

## 10. EXECUTION ORDER

Dependencies are real at every numbered step; none may be reordered.

| # | Step | Owner | Depends on / why |
|---|---|---|---|
| **1** | 🔴 **G1 measurement.** Read `Extracted_JSON__c` on the failing staging row and `Lot_Size_Acres__c` on Lead `00Qiw000000wZVHEA2`. Report whether `lot_size_sf` absorbed 112,400. | ✅ **DONE 2026-08-31 by technical-architect — do not re-run.** RESULT: `properties[0]` has NO `lot_size_sf` key and NO `building_sf` key; `Lot_Size_Acres__c` and `Building_SF__c` both null. Pure OMISSION, no mis-route, NO bad data, no sweep owed. Corpus-wide: `lot_size_sf` populated 0 of 4 property objects. | Decides omission vs mis-routing (§1.3). Changes the fix and may reveal live bad data. **Before any edit.** |
| **2** | 🔴 **G2 baseline.** Run UAT **D** and **D′** live; record `broker_email` and `normalizeAddress(property_address)` for both. | devops | The only regression baseline that exists. Worthless if taken after the edit. |
| **3** | **P0 probe.** Record `shippedPrompt().length()` (`B`) and `extractionPromptOverride().length()`. Both must read 20,596. | devops | Proves the trap is live on this org before anything changes. |
| **4** | **Apex edit** — §5.1 Parts A/B/C, T5, header revision log. Length figures left as placeholders. | technical-architect | — |
| **5** | **Code review**, then **deploy** `LLMExtractionCalloutService.cls` + `LLMExtractionCalloutServiceTest.cls`. | code-review → devops | Standard gate. The loader (step 7) reads `shippedPrompt()` from the **deployed** class, so the class must be live first (`:908-909`). |
| **6** | **Measure `N`** — execute `LLMExtractionCalloutService.shippedPrompt().length()` against the org. 🔴 Measure, never count (C5). | devops | `N` is unknowable until the class is deployed. |
| **7** | 🔴 **G3 / probe P1.** Confirm `shippedPrompt().length()` = `N` **and** `extractionPromptOverride().length()` still = `B`. **They must differ.** | devops | The anti-vacuity control. Skipping it makes step 9 meaningless. |
| **8** | 🔴 **CANCELLED 2026-08-31 — DO NOT EXECUTE. DO NOT WRITE A CHARACTER COUNT INTO L1, L2, L3 OR L4, BEFORE OR AFTER DEPLOY.** This step originally read *"Backfill `N` into L1, L2, L4 and `scripts/load-broker-protection-config.apex:71` (L3)."* The implementation instead **de-pinned all four sites**, which is stronger, and `LLMExtractionCalloutService.cls` now carries `🔴 THE LENGTH IS NOT STATED HERE, AND THAT IS THE POLICY — DO NOT ADD A NUMBER`. Executing this step as written would re-pin `shippedPrompt()`'s `@return` — the one site the class header names as "the site whose staleness propagated everywhere" — on its **fifth** stale figure. `shippedPrompt().length()` is the sole authority; there is nothing to backfill. | — | Retracted after code review W2. |
| **9** | 🔴 **RUN `scripts/load-broker-protection-config.apex`.** **THE STEP WITHOUT WHICH NOTHING CHANGES AT RUNTIME.** Confirm the record has no Setup edits since this morning first (the loader discards them). | devops | Must follow step 5. `resolvePrompt()` prefers the record; until this runs the stale 20,596-char override still wins. |
| **10** | **Poll** until `extractionPromptOverride().length()` changes. The loader is async (`enqueueDeployment`). | devops | A probe run immediately after step 9 reads the old value and looks like failure. |
| **11** | **G4 / probe P2.** `shippedPrompt().length()` == `extractionPromptOverride().length()` == `N`, and `N ≠ B`. Plus the content probe: the override contains the new bullet's distinctive phrase. | devops | — |
| **12** | 🔴 **G4 continued.** Re-run UAT **D** and **D′**; diff the normalized keys against step 2 **by hand**. Any drift → roll back per G4. | devops | The only registry-safety check that exists. |
| **13** | **G5 / V4 acceptance.** Re-send the failing email. Assert `building_sf` = 112400, `Building_SF__c` = 112400, `field_confidence.building_sf` ≥ 0.9, `Lot_Size_Acres__c` = **4.6** (🔴 NOT null — corrected 2026-08-31, see §6 V4.3; ≈2.58 means Part A failed), not in `LLM_Unavailable`. | devops | 🔴 A green deploy is **not** acceptance. |
| **14** | *(only if D2 = option b)* Run the corpus population-rate script; report per-key rates for the eight remaining template-only keys. | technical-architect → devops | Feeds a **separate** future decision. Not part of this change. |
| **15** | Documentation. | documentation | After G5. |

---

## 11. FILES TO BE TOUCHED — COMPLETE LIST

### Edited

| # | Path | Change |
|---|---|---|
| 1 | `force-app/main/default/classes/LLMExtractionCalloutService.cls` | `ENRICHED_EXTRACTION_RULES`: narrow the `lot_size_sf` bullet (`:672-673`), add the `building_sf` bullet after it, add `building_sf` to the `field_confidence` exemplar list (`:797`). Comments: `shippedPrompt()` `@return` (L1, `:917-920`), `EXTRACTION_INSTRUCTION` header (L2, `:849-859`), new dated revision-log section in the class header. |
| 2 | `force-app/main/default/classes/LLMExtractionCalloutServiceTest.cls` | New structural test **T5** + banner-compatibility argument + stated limitation. Allowlist iff D2 = "building_sf only". ⚠ Do **not** edit the P0 probe record at `:12`. |
| 3 | `force-app/main/default/classes/ExtractionRegressionFixtureTest.cls` | **Comment-only.** Append a dated `⚠ RE-MEASURED` line to the section-2 tombstone updating the 20,000 / 20,596 / 97% figures (L4, `:287-296`), and one sentence confirming T5 does not violate the DO NOT RESTORE banner (extending the existing `:317-323` paragraph). **No assertion changes. No fixture changes.** |
| 4 | `scripts/load-broker-protection-config.apex` | Line 71 `expect 20596` → `expect <N>`, with a dated note preserving the existing arithmetic explanation at `:56-70`. Local file; not deployed. |

### Executed, not edited

| Path | Role |
|---|---|
| `scripts/load-broker-protection-config.apex` | Step 9 — the mandatory loader re-run. |

### Read for verification, not modified

`force-app/main/default/classes/LLMExtractionParser.cls` (`:356`, `:361`),
`force-app/main/default/classes/EmailToLeadService.cls` (`:743`, `:745`),
`force-app/main/default/objects/Lead/fields/Building_SF__c.field-meta.xml`,
`force-app/main/default/permissionsets/{Broker_Protection_Access,DPEG_Acquisition_Edit,DPEG_Acquisition_View}.permissionset-meta.xml`.

### 🔴 Explicitly NOT to be touched

`ARCHITECTURE.md` · `.claude/skills/sf-apex/SKILL.md` ·
`docs/2026-08-31-cmdt-longtext-truncation-p0.md` · `BrokerProtectionConfigSelector.cls` ·
`BrokerProtectionConfigSelectorTest.cls` · `BrokerProtectionConfig.cls` (subject to **D3**) ·
`Extraction_Prompt__c.field-meta.xml` · `ExtractionScoreUtil.cls` ·
`LEGACY_EXTRACTION_RULES` / `LEGACY_RESPONSE_FORMAT` · the response template (`:810-822`) ·
the picklist value lines (`:823-835`) · `MAX_PROPERTIES_IN_PROMPT` · `MODEL` / `MAX_TOKENS` /
`MAX_INPUT_CHARS` / `TIMEOUT_MS` / `ENDPOINT` · and the concurrent session's entire file set
(dashboards, tabs, `DPEG_Transaction_*` permission sets, seed scripts, `Transaction__c` fields,
reports, `LeadConvertService`, `LeadConvertServiceTest`, `TestDataFactory`).

---

## 12. ARCHITECTURE.md CONFORMANCE

| Rule | Status |
|---|---|
| §2 layering | No layer boundary crossed. The edit is to a string constant inside the existing callout-service class. No SOQL, no DML added. |
| §2 CMDT long-text carve-out | Respected and unchanged. This design depends on the fix deployed this morning and proposes no change to it. |
| §3.3 direct OpenAI callout | Preserved. `ENDPOINT`, the Named Credential, and the `extract(String,String,String)` signature are untouched, so the "one class owns the boundary / retirement is a one-line change" promise stays literally true. **No fourth §3 exception is created or implied.** |
| §2 bulk tests (251) | Not applicable, and this must be stated in T5's header so review does not demand it. T5 asserts a property of a compile-time string constant: there is no trigger, no batch, no loop and no records to insert. `.claude/rules/bulk-test-rule.md`'s per-transaction-singleton carve-out applies on independently sufficient grounds. `LLMExtractionCalloutService` is the one class the narrowed 2026-07-31 exemption list still names as exempt. |
| §2 coverage 90% | T5 is additive; existing coverage of this class is unaffected. |
| §1 naming | No new API names created. |
| `.claude/rules/salesforce-global-rule.md` | ⚠ **`mcp=unavailable`, `mcp_tools=none`.** This agent's tool set is file-system only — there is no `salesforce-api-context` MCP server configured and no org access from here. No new metadata type is being generated in this change (the only metadata file in scope, `Extraction_Prompt__c.field-meta.xml`, requires **no change**), so no per-type skill/API-context loop was required. Any implementing agent that does generate metadata must run the gate itself. |

---

## 13. PROMPTS FOR SPECIALIST AGENTS

### ⚫ PROMPT FOR `salesforce-technical-architect`

```
Edit the extraction prompt in force-app/main/default/classes/LLMExtractionCalloutService.cls so
that building square footage stated in a broker email lands in properties[].building_sf.

READ FIRST: agent-output/design-requirements.md (this document) in full, plus §§1-4 of
LLMExtractionCalloutService.cls's own class header, and the section-2 tombstone in
ExtractionRegressionFixtureTest.cls (lines 260-329).

ROOT CAUSE (measured, do not re-derive): building_sf appears ONLY in the JSON response template
at line 819 and has no defining rule anywhere. Worse, the only rule in the prompt that fires on
the phrase "square feet" (lines 672-673) routes it to lot_size_sf, and its trailing sentence
"Never fill both from a single figure" then forbids building_sf. LLMExtractionParser.cls:361
converts lot_size_sf to acres and EmailToLeadService.cls:745 writes it to Lot_Size_Acres__c, so
the mis-route silently fabricates a lot size.

MAKE EXACTLY THESE CHANGES, ALL INSIDE ENRICHED_EXTRACTION_RULES:
A. Narrow the lot_size_sf bullet at :672-673 so it scopes to LAND / SITE area in square feet.
B. Add a building_sf bullet immediately after it, containing: a definition (building /
   improvements area in sq ft); an explicit contrast with lot_size_acres/lot_size_sf; a worked
   example in the house style ("112,400 square feet of building on a 3.2-acre site" -> building_sf
   112400, lot_size_acres 3.2); a clause that a figure stated in narrative prose is still a stated
   value; and a null-if-absent clause that does NOT weaken line 668's "Use null for any value the
   email does not state".
C. Add "building_sf" to the field_confidence exemplar key list at :797.

DO NOT TOUCH: LEGACY_EXTRACTION_RULES, LEGACY_RESPONSE_FORMAT, the response template (:810-822),
the picklist value lines (:823-835), MAX_PROPERTIES_IN_PROMPT, MODEL, MAX_TOKENS, MAX_INPUT_CHARS,
TIMEOUT_MS, ENDPOINT, the extract() signature, or ANY paragraph governing broker_name,
broker_email, property_address or sent_datetime (INPUT SHAPE :562-579, BROKER vs LISTING BROKER
:593-612, broker_company :613-660, sent_datetime :661-666). Editing the prompt re-keys the
Property_Registry__c claim key; a diff outside the three sites above is a defect.

Do NOT touch BrokerProtectionConfig, BrokerProtectionConfigSelector, the truncation guard,
Extraction_Prompt__c.field-meta.xml, ExtractionScoreUtil (building_sf is deliberately excluded from
the signed-off nine-key score - do not add it), or anything in the concurrent session's file set
(dashboards, tabs, DPEG_Transaction_* permission sets, seed scripts, Transaction__c fields,
reports, LeadConvertService, LeadConvertServiceTest, TestDataFactory).

ADD ONE TEST to LLMExtractionCalloutServiceTest: T5, asserting the STRUCTURAL invariant that every
key present in the JSON response template is mentioned at least once elsewhere in the prompt. This
is the general form of the bug and would have caught it the day building_sf was added. It must NOT
be a verbatim byte pin - ExtractionRegressionFixtureTest.cls:310-323 forbids that by name. In T5's
header: argue its compatibility with that banner in the same shape T1-T4 already use; state the
limitation that it runs against shippedPrompt() (the Apex fallback) and says nothing about an
admin-edited Setup value; and state why .claude/rules/bulk-test-rule.md's 251-record mandate does
not apply (a property of a compile-time string constant; no trigger, loop, batch or records).
Include a dated allowlist of the eight other template-only keys (broker_phone, broker_mobile,
broker_title, walt_years, adr, zoning, seller_entity, deal_room_link) as visible accepted
exceptions, unless instructed otherwise at Gate 1.

LENGTH FIGURES: *** THE BACKFILL INSTRUCTION THAT STOOD HERE IS RETRACTED (2026-08-31, code
review W2). DO NOT BACKFILL N ANYWHERE. *** It read: "Once devops reports N, backfill it in a
comment-only pass at shippedPrompt()'s @return tag, the EXTRACTION_INSTRUCTION header block,
ExtractionRegressionFixtureTest, and scripts/load-broker-protection-config.apex:71."
Following that would re-pin the exact site the class header now forbids by name, on a fifth stale
figure. The implementation de-pinned all four sites instead. The length is still MEASURED, never
counted from source (a source count under-reports by exactly 4, because MAX_PROPERTIES_IN_PROMPT is
interpolated twice at runtime) - but it is measured for a probe result reported to a human, and is
NOT written back into any file. shippedPrompt().length() is the sole authority.
Do NOT update any of the 2026-08-31 CMDT-truncation probe records (255 / 20,596 / identical=false)
in ARCHITECTURE.md, SKILL.md, docs/, BrokerProtectionConfigSelector*, BrokerProtectionConfig, or
LLMExtractionCalloutServiceTest.cls:12 - those are dated historical measurements and editing them
falsifies the incident record.

Add a new dated revision-log section to the class header following the file's existing convention
for its ~10 prior prompt revisions: what changed, that LEGACY is untouched, that no arbitration
value moved, the Part A narrowing and its risk statement, and that UAT D/D' are mandatory re-runs.

Do not deploy. Do not run scripts.
```

### 🔴 PROMPT FOR `salesforce-devops`

```
Operational steps for the building_sf prompt fix. Follow agent-output/design-requirements.md §10
exactly - the order is load-bearing and an out-of-order run produces a false pass.

BEFORE THE EDIT
1. On usman-dpeg, read Inbound_Email_Staging__c.Extracted_JSON__c for the row behind Lead
   00Qiw000000wZVHEA2, and read that Lead's Lot_Size_Acres__c. Report whether properties[0]
   contains a lot_size_sf key and whether Lot_Size_Acres__c is populated (~2.58 would indicate the
   112,400 sq ft building figure was mis-routed to lot size). BLOCKING - report before proceeding.
2. Run UAT fixtures D and D' live (defined in agent-output/design-requirements-extraction-
   completeness.md §6.5, named in LLMExtractionCalloutService.cls:178-195). Record broker_email
   and PropertyMatchingService.normalizeAddress(property_address) for each. This is the ONLY
   regression baseline that exists for this prompt.
3. Probe P0: report LLMExtractionCalloutService.shippedPrompt().length() and
   BrokerProtectionConfig.extractionPromptOverride().length(). Both should read 20596.

AFTER THE APEX DEPLOY
4. Measure N = LLMExtractionCalloutService.shippedPrompt().length() against the org. Report it.
   MEASURE, never count.
5. Probe P1 - BLOCKING ANTI-VACUITY CONTROL: confirm shippedPrompt().length() == N AND
   extractionPromptOverride().length() == 20596. THEY MUST DIFFER. If they match, STOP: either the
   deploy did not land or the config record is not populated, and every later check would pass
   vacuously.

THE STEP WITHOUT WHICH NOTHING CHANGES AT RUNTIME
6. First confirm Broker_Protection_Config.Default has not been edited in Setup since this morning
   (the loader upserts every field and discards Setup tuning). Then run
   scripts/load-broker-protection-config.apex.
   resolvePrompt() PREFERS the configured record over the Apex constant, so until this runs the
   stale 20,596-character override is still what OpenAI receives - the deploy alone changes nothing.
7. The loader is ASYNCHRONOUS (Metadata.Operations.enqueueDeployment). POLL until
   extractionPromptOverride().length() changes. A probe taken immediately after step 6 reads the
   old value and looks exactly like a failed edit.
8. Probe P2: shippedPrompt().length() == extractionPromptOverride().length() == N, and N != 20596.
   Plus a content probe: extractionPromptOverride() contains the distinctive phrase from the new
   building_sf bullet.
   Note: getInstance('Default').Extraction_Prompt__c.length() will still read 255 at every stage.
   That is correct and unchanged - it is the platform truncation this morning's fix bypasses.
9. Re-run UAT D and D'. Diff broker_email and the NORMALIZED property_address against step 2 BY
   HAND - the same normalized key, not a similar address. Any drift: roll back by clearing
   Extraction_Prompt__c in Setup (falls back to the shipped constant), then revert the Apex.

ACCEPTANCE - A GREEN DEPLOY IS NOT ACCEPTANCE
10. Re-send the email behind Lead 00Qiw000000wZVHEA2. Assert on the NEW record:
    - Extracted_JSON__c properties[0].building_sf == 112400
    - Lead.Building_SF__c == 112400
    - field_confidence.building_sf >= 0.9
    - Lead.Lot_Size_Acres__c == 4.6  (🔴 CORRECTED 2026-08-31 - this line said NULL and was WRONG.
      The email states "The hotel sits on 4.6 acres", so 4.6 is the fix WORKING. The mis-route
      signature is ~2.58 (112400 sq ft / 43560). NULL now means the key-omission is unfixed.)
    - the Lead is NOT in Outcome__c = '... - LLM unavailable' / the LLM_Unavailable list view
11. Also re-run the standing UAT checks this class header declares mandatory after ANY prompt edit:
    an OM with a bid deadline from a named broker must still classify acquisition_deal; a genuine
    marketplace blast must still classify call_for_offers.

Deploy scope is exactly: LLMExtractionCalloutService.cls, LLMExtractionCalloutServiceTest.cls,
ExtractionRegressionFixtureTest.cls (comment-only). scripts/ is not deployed.
Do not deploy anything belonging to the concurrent session sharing this working tree - diff every
component against the org before deploying.
```

---

## 14. WHAT THIS AGENT COULD NOT VERIFY

Stated so nothing here is mistaken for measurement:

1. **Whether `lot_size_sf` absorbed the 112,400** on the failing row, and whether
   `Lot_Size_Acres__c` on Lead `00Qiw000000wZVHEA2` carries a fabricated value. No org access. This
   is gate **G1** and is the first step of the execution order.
2. **The new prompt length `N`.** Not knowable, and not computable by counting (C5). Measured at
   step 6.
3. **Whether the other eight template-only keys are actually failing.** Their template-only status
   is verified from source; their live population rate is not. That is exactly why decision **D2**
   recommends measuring instead of editing.
4. **`mcp=unavailable, mcp_tools=none`** — no `salesforce-api-context` MCP server is configured for
   this agent and no metadata generation is in scope for this change.
