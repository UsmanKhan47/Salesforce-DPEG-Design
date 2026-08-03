# Design Requirements — Broker Protection INTAKE RULES V2

**Date:** 2026-08-03
**Module:** Lead Intake / Broker Protection
**Status:** Gate-1 design. Fixed business inputs (U1/U2/U3 decided by the user); this document designs the HOW only.
**Reference:** `ARCHITECTURE.md` §1 (Lead Intake / Broker Protection), §2 (Key Apex Services, Broker Protection staging model), §3.3 (direct OpenAI callout exception)

---

## 0. WHAT THE USER REQUESTED (fixed — not re-opened)

| # | Change | Decided |
|---|---|---|
| **U1** | When an inbound email is NOT a genuine forward, the Lead **and the claim identity** is the **actual envelope sender**. Contacts named in the body go to `Listing_Broker_Name__c` / `Listing_Broker_Email__c`. Genuine forwards keep today's behaviour. | Yes |
| **U2** | Mass-marketed **call-for-offers** blasts are logged (staging + outcome label) but create **no Lead**. Only direct/exclusive opportunities become Leads. | Yes |
| **U3** | `broker_company`: a firm name **stated anywhere** in the email — including signature and footer blocks — beats domain inference. Inference stays fallback-only. | Yes |

Triggering incident (U1): a direct send from `usmankhan-96@hotmail.com` produced a Lead for the body-named `mark.stern@jll.com`.

---

## 1. RECON FINDINGS THAT CHANGE THE DESIGN

Five things found in the source that a naive implementation would get wrong. Read these before §2–§4.

### F1 — U1 was already scoped, by name, in the code, as "its own change"

`ExtractAddressQueueable.applyEnvelopeEmailFallback`'s Javadoc ends with:

> **POSSIBLE FUTURE SHARPENING (deliberately NOT done here):** suppress only when `applyRegexFallback` actually found a "From:" line that yielded no address — **a quoted "From:" block is positive evidence of a forward, which a direct email does not have.** That would recover case 2 without weakening case 1's protection. Left alone because it is a behaviour change and this note was written post-review; **raise it as its own change.**

U1 **is** that change, raised as its own change, and the predicate the code already proposed ("is there a quoted `From:` block?") is the predicate this design adopts. This is not a new invention — it is the execution of a pre-authorised, pre-reasoned design note. It also means U1 **closes the documented residual gap #2** of the W2 suppression logic (see §2.4).

### F2 — a prompt-side U1 is structurally impossible, not merely expensive

The model never receives the envelope. `ExtractAddressQueueable.buildLlmText(subject, body)` composes **subject + body only**; `From_Address__c`, `From_Name__c` and `Forwarded_By__c` are never sent. A prompt rule saying "the broker is the envelope sender" is therefore un-actionable — the model cannot see the envelope sender.

Making it actionable would require **injecting the envelope From into the prompt text**, which is precisely the `From:`-injection surface `buildLlmText`'s 🔴 prohibition block was written to close on 2026-08-03. That settles §2.1 on its own, before cost is even considered.

### F3 — `confidence` measures the wrong question for U2

The prompt defines `confidence` as *"how certain you are of **is_acquisition_related**"*. A call-for-offers blast **is** acquisition-related, so its `confidence` will be **high** — and so will a genuine exclusive's. Gating U2 on `confidence >= 0.85` therefore adds **almost no discrimination**: the "two-factor" guardrail collapses into the one-factor rule `email_category == 'call_for_offers'`.

This is the exact failure shape recorded for the Opportunity deal-action gate in `ARCHITECTURE.md` §2 ("membership and the flag are different questions" — a two-factor condition silently replaced by a one-factor one). The fix is a **category-scoped confidence**, `category_confidence`, added to the **enriched** block (§3.1).

### F4 — a claim without a Lead is forbidden by a deployed validation rule, not merely unwise

`objects/Property_Registry__c/validationRules/Winning_Lead_Required.validationRule-meta.xml`:

```
errorConditionFormula: AND(ISNEW(), ISBLANK(Winning_Lead__c))
```

`Competing_Broker_Submission__c` carries the identically-named VR. Orphan (`Winning_Lead__c = null`) registry rows exist **only** as the after-effect of a `SetNull` Lead delete — they can never be *inserted*. So "register a CFO claim with no Lead" is not a trade-off to weigh; it requires deactivating a VR that exists specifically to make the lookup behave as required. **U2 gets no claim.** See §3.3 for why that is also the right business answer.

### F5 — U3 is ~40% already built, and the missing 60% is not what the request names

The S4 paragraph already says *"if the body, **the signature block** or the subject states the broker's company, use it exactly as written"*. What is actually missing is different and more important:

- the sentence is **subordinate to an inference heading** (`broker_company WHEN THE EMAIL DOES NOT NAME THE FIRM`), so it reads as an exception to inference rather than as precedence;
- **"footer" is not named** (disclaimer blocks, letterhead, copyright lines — where blast platforms put the firm);
- 🔴 **the division-strip rule is attached only to the INFERENCE sentence.** A footer states `"JLL Capital Markets"`, `"CBRE | Investment Properties"`, `"Marcus & Millichap IPA"` — the *division*, while domain inference gives the clean firm. So U3 as literally requested would make stated names **beat** inference and thereby **fragment `Lead.Company` → `AccountSelector.selectByNames`**, which the S4 header names as load-bearing. See §4.2.

---

## 2. U1 — SENDER-FIRST BROKER IDENTITY FOR DIRECT EMAILS

### 2.1 VERDICT — **APEX ONLY. ZERO PROMPT CHANGE. ZERO FIXTURE RE-PIN.**

| Option | Verdict | Reason |
|---|---|---|
| Edit `LEGACY_EXTRACTION_RULES` | ❌ **Rejected** | The broker rule lives there (`The OUTERMOST / EARLIEST "From:" line identifies the ORIGINAL BROKER`), so a prompt-side U1 is necessarily a **legacy-block** edit. That breaks protection 1 (byte-pin), protection 3 (one-line rollback), and forces re-pinning `ExtractionRegressionFixtureTest.legacyExtractionRules_areStillVerbatim` + `rollbackLever_recomposesTheOriginalFourKeyPrompt` — and buys a **soft, model-version-fragile, untestable** rule in place of a deterministic one. |
| Add an enriched-block paragraph | ❌ **Rejected** | Structurally impossible (F2): the model has no envelope. Making it possible re-opens the closed `From:`-injection surface. |
| **Deterministic Apex override in `ExtractAddressQueueable`** | ✅ **ADOPT** | All four inputs are already on the staging row. Deterministic, unit-testable, diffable, and reversible by deleting one method call. |

**The framing that makes this airtight, and which belongs in the code comment:** the legacy rule says *take the broker from the outermost `From:` line*. U1's override fires **exactly when there is no such line** — i.e. when the legacy rule was inapplicable and the model answered from prose instead. The Apex override therefore **does not contradict the prompt; it supplies the answer for the case the prompt does not cover.**

### 2.2 The forward predicate

New pure, `@TestVisible`, static function on `ExtractAddressQueueable`:

```
private static Boolean isGenuineForward(String rawBody)
```

Returns `true` when **either**:

1. **`FROM_LINE_PATTERN.matcher(rawBody).find()`** — a header-block `From:` line in the body. `FROM_LINE_PATTERN` (`(?im)^\s*From:\s*(.+)$`) **already exists** and is line-anchored; reuse it verbatim. Do **not** author a second regex with different anchoring — one semantic rule, one pattern.
2. **`FORWARD_MARKER_PATTERN`** (new) matches — `-----Original Message-----`, `---------- Forwarded message ---------`, `Begin forwarded message:`. Line-anchored, case-insensitive, dash-count tolerant. Redundant with (1) for English clients; it is the backstop for a client that emits a marker with a header block this repo's `From:` pattern does not match.

`null`/blank body → `false` (no forward evidence → override applies).

**Why the predicate is deliberately biased toward "forward":** the two error directions are wildly asymmetric.

| Misclassification | Consequence |
|---|---|
| A **genuine manual forward** read as a direct send | The claim is attributed to the **internal DPEG employee** who forwarded it. Silent, authoritative, and exactly the failure `applyEnvelopeEmailFallback`'s "blank beats wrong" note exists to prevent. **Catastrophic.** |
| A **direct send** read as a forward | Today's behaviour is preserved. The incident recurs for that one email. **Recoverable, visible.** |

So any evidence of a forward stands the override down.

**Rejected signals**, with reasons (do not add them later without re-reading this):

- **`FW:` / `FWD:` subject prefix** — the memory note and the enriched block both treat the subject as attacker-controlled transport noise, and adding a second semantic rule in Apex that overlaps a prompt rule is exactly the drift the module has already ruled against. *(Note it would be safe-by-asymmetry — it can only preserve today's behaviour — so it is available as a hardening if UAT B shows misses. Not in v1.)*
- **`Forwarded_By__c != From_Address__c` forcing "forward = true"** — 🔴 **actively wrong.** On an **auto-forward** the envelope From *is already the broker*; treating auto-forwards as "genuine forwards" would keep today's LLM-prose behaviour on the module's **highest-volume production shape** and leave the incident class open there. `Forwarded_By__c` is used in §2.3's guard, never in the predicate.

### 2.3 The override and the demotion precedence

New private method, called **after** `applyRegexFallback` and `applyEnvelopeEmailFallback`, **before** `isHardGated`:

```
applySenderFirstBrokerIdentity(extraction);
```

Order of guards — each `return` is a documented reason **not** to override:

```
1. isGenuineForward(staging.Raw_Body__c)            -> return   // the prompt rule applied; keep it
2. sender = sanitizeEmail(staging.From_Address__c)
   sender == null                                   -> return   // nothing to override WITH
3. sender.equalsIgnoreCase(extraction.brokerEmail)  -> return   // the model already agreed — NO-OP
4. isInternalAddress(sender)                        -> return   // R1 guard, §2.5 / D-2
5. demote + swap
```

**Guard 3 is load-bearing and must not be "simplified away".** A real broker sending directly from their firm address (`mark.stern@jll.com`, no forward block) hits guard 3 and **nothing changes** — company, phone, title and mobile are all kept. The demotion in step 5 only ever runs when the envelope sender and the body-named broker genuinely **differ**, which is the only case where the extracted contact block describes somebody other than the Lead.

**Step 5 — demotion, exactly:**

| Field | Action |
|---|---|
| `brokerEmail` | `:= sender` (the envelope From, sanitized) |
| `brokerName` | `:= staging.From_Name__c` when non-blank, else **null**. Null is correct: `EmailToLeadService.applyName` already falls back `brokerName → fromName → 'Unknown'`, and `createLead` already passes `fromName = staging.From_Name__c`. No new plumbing. |
| `listingBrokerEmail` / `listingBrokerName` | **Fill-if-blank only.** If `listingBrokerEmail` is blank → take the demoted `brokerEmail`/`brokerName`. If it is already populated and **equals** the demoted address (case-insensitive) → no-op. If it is already populated with a **different** address → **leave it alone**; the model made an explicit listing-broker call and overwriting it destroys information. |
| `brokerCompany`, `brokerPhone`, `brokerMobile`, `brokerTitle` | **Cleared to null.** They describe the body-named person, not the Lead. 🔴 `brokerCompany` in particular flows to `Lead.Company` → `LeadConvertMatchService.collectMatchKeys` → `AccountSelector.selectByNames`, so keeping it would **attribute the deal to the body-named broker's firm's Account**. Clearing it drops `Lead.Company` to `COMPANY_PLACEHOLDER`, which `LeadConvertMatchService` D1b **deliberately excludes from Account matching** — the correct, recoverable outcome. |
| `extraction.notes` | **One note appended**, via the existing `LLMExtractionResult.addNote` (which already lands on `Deal_Notes__c` under `-- Extraction notes --`). It must name **every discarded value**, because that note is the only route back for a human. |

Proposed note text (developer may adjust wording, not content):

```
Sender-first identity: no forwarded-message block was found, so this Lead is the envelope
sender (<sender>). The body named <oldName> <oldEmail> (<oldCompany>, <oldTitle>,
<oldPhone>/<oldMobile>) — recorded as the listing contact.
```

**No new fields. No schema change. No selector. No SOQL. No DML.** The override is pure in-memory mutation of an already-loaded DTO, so the `lastRunQueryCount` / `lastRunDmlCount` budgets are untouched — assert that.

### 2.4 Interplay with the existing logic (specified, as requested)

| Existing mechanism | Interplay |
|---|---|
| **`applyRegexFallback`** | Unchanged, and runs **first**. It fills blanks from the body's `From:` line — which by construction exists only when `isGenuineForward` is `true`, i.e. exactly when the override stands down. The two are **mutually exclusive by construction**, not by convention. |
| **`applyEnvelopeEmailFallback` (W2)** | **Keep it. Do not merge or delete it.** It still owns a case the override does not reach: a **genuine forward** whose quoted `From:` block yields a name but no address, on an auto-forward (`From != Forwarded_By`). There the override stands down and W2 correctly supplies the envelope address. |
| **W2 residual gap #2** ("a correct address discarded" on a direct send, because `From == Forwarded_By` cannot be told apart from a manual forward) | ✅ **CLOSED by U1.** The override supplies the envelope address on exactly that shape. **Amend W2's Javadoc**: replace the "POSSIBLE FUTURE SHARPENING … raise it as its own change" paragraph with a pointer to `applySenderFirstBrokerIdentity`. |
| **W2 residual gap #1** (false negative: a manual forward carrying an `X-Forwarded-For`) | **Unchanged — neither widened nor narrowed.** On that email the body still carries a `From:` block, so `isGenuineForward` is `true` and the override never runs. State this explicitly so review does not assume U1 disturbed it. |
| **`buildLlmText`'s 🔴 prohibition** ("`applyRegexFallback` and `applyEnvelopeEmailFallback` MUST continue to read `Raw_Body__c` and the envelope, NEVER the composed text") | **Extends verbatim to `isGenuineForward` and `applySenderFirstBrokerIdentity`.** Both read `staging.Raw_Body__c` and the envelope only. Feeding the composed text to `isGenuineForward` would make a subject line reading `From: someone` flip the predicate — attacker-controlled, deterministic, and it would hand a claim to whoever can set a subject. Add the class to that prohibition list in the comment. |
| **Ordering vs the relevance gate** | The override runs **before** `isHardGated`. It must: a hard-gated email still logs its Task and the demotion note still belongs on the staging audit trail. |
| **Reply / pre-filter branches** | Unreachable — both exit in `routePrologueWithoutCallout` before any extraction exists. |

### 2.5 Arbitration impact and residuals

U1 **is an arbitration change** — `broker_email` feeds `PropertyMatchingService.findBrokerSubmission` (repeat detection) and `Competing_Broker_Submission__c.Broker_Email__c` (attribution). It does **not** touch `property_address`, so **no `Property_Key__c` changes and no existing claim is re-keyed.**

| ID | Residual | Disposition |
|---|---|---|
| **R1** | A **manual forward whose body carries no recognisable `From:` block and no marker** (e.g. a localized mail client emitting `Von:` / `De:`) would be read as a direct send and attribute the claim to the **internal employee**. | Primary mitigation is the two-signal predicate (§2.2). Closure is **D-2** below. Consequence is severe and silent, so this must be an explicit decision, not an oversight. |
| **R2** | A **direct send that pastes a marketing email including its header block** is read as a forward, so the pasted original broker keeps the claim. | **Accepted.** Arguably correct — the pasted original *is* the deal's source. Visible in `Extracted_JSON__c`. |
| **R3** | Submissions recorded **before** U1 under a body-named broker will not match as **repeats** after U1, so a follow-up direct send routes as a **competing submission** instead. | **Accepted.** Population is direct sends only; the trail is append-only so nothing is lost; worst case is one extra `Competing_Broker_Submission__c` row. **Do not "fix" it** by adding a third `findBrokerSubmission` lookup on the demoted address — that is +1 SOQL **per property inside the loop** (up to +10 per email) against the documented ~8/property budget, for a shrinking historical population. |
| **R4** | A direct-send Lead loses its firm name (`brokerCompany` cleared → `COMPANY_PLACEHOLDER`). | **Accepted and intended** — see the `Lead.Company` row in §2.3. The demotion note carries the discarded company so a human can set it in one click. |

---

## 3. U2 — NO LEAD FOR MASS-MARKETED CALL-FOR-OFFERS BLASTS

### 3.1 Guardrail (a) — misclassification: the gate must be genuinely two-factor

Per **F3**, `confidence` answers a different question and would make the gate one-factor. Design:

**Add `category_confidence` to the ENRICHED block** (prompt change — enriched only, §5). One key, one sentence, one parser field.

Proposed enriched sentence (append to the existing `CLASSIFICATION:` paragraph — **verbatim, do not paraphrase**):

```
category_confidence is a number from 0 to 1 expressing how certain you are of
email_category SPECIFICALLY — it is a SEPARATE judgement from confidence, which
concerns is_acquisition_related only. Return category_confidence above 0.85 only
when the email is unambiguously of that category on its face. A property offering
sent to one recipient, an off-market or exclusive introduction, or any email that
invites a direct conversation is NOT call_for_offers; call_for_offers means a
marketed campaign inviting offers from the market at large, typically with a stated
offer deadline and a mass or list send.
```

And in the response-schema JSON, immediately after `"confidence": 0.0`:

```
"category_confidence": 0.0,
```

**Suppression fires only when ALL of:**

1. `extraction.emailCategory == 'call_for_offers'` **AND**
2. `extraction.categoryConfidence != null && extraction.categoryConfidence >= threshold` **AND**
3. the CMDT toggle `Suppress_Call_For_Offers__c == true`.

**Threshold: reuse `LLMExtractionParser.CONFIDENCE_HIGH_MIN` (0.85)** as the *code default*, exposed as the CMDT field `Call_For_Offers_Min_Confidence__c` for tuning. **Do not introduce a second hardcoded number** — the existing constant already carries the comment *"Tuning the gate happens here, never in the prompt."*

**Fail-open in every ambiguous direction** (the when-unsure-create philosophy, preserved literally):
- `category_confidence` **missing, null, or unparseable → treated as 0 → Lead created.** This is also the automatic behaviour on a **rollback** to the legacy prompt shape and on **LLM degrade**, both of which yield no category at all.
- Anything not exactly `call_for_offers` → Lead created.
- Toggle off (the default) → Lead created.

**The near-miss note (this is how the threshold gets tuned).** When conditions 1 and 3 hold but 2 does **not**, append via `extraction.addNote(...)`:

```
Classified call_for_offers at category_confidence <x> — below the <threshold>
suppression threshold, so a Lead was created.
```

That lands on `Deal_Notes__c` and is the **only** way to find the near-miss population. Zero new labels, zero list-view impact.

### 3.2 Placement in the routing tree

**Email-level, immediately after `isHardGated`, before `routeProperties`** — a byte-for-byte mirror of the existing hard gate:

```
if (isCallForOffersGated(extraction)) {
    outcomes.add(new RoutingOutcome(OUTCOME_CALL_FOR_OFFERS, null, null, PRIORITY_NO_PROPERTY));
    finish();
    return;
}
```

**Per-property placement is rejected**: `email_category` is an email-level value, and evaluating it inside the loop would interleave a classification decision with the cluster-lock ordering that the deadlock fix depends on.

`finish()` still runs, so **the Task is still logged** — mandatory, or a platform redelivery re-runs the whole pipeline (the same reason the two existing gates log one). `Extracted_JSON__c` is already written verbatim **before** any routing decision (D3 tier 1), so the full extraction survives the gate.

### 3.3 Guardrail (b) — the claim engine: **no claim, and that is the right answer**

**Recommendation: CFO-gated emails take NO claim.** Three independent reasons, in descending strength:

1. **It is structurally forbidden (F4).** `Property_Registry__c.Winning_Lead_Required` is `AND(ISNEW(), ISBLANK(Winning_Lead__c))` — a registry row cannot be *inserted* without a Lead. `Competing_Broker_Submission__c` carries the same VR. The orphan rows that exist (and that orphan adoption reads) are the *after-effect* of a `SetNull` Lead delete, never an insert. Claim-without-Lead would require weakening a VR written specifically to make the lookup behave as required.
2. **It would be actively harmful if it were possible.** Registering a CFO blast would make the **first blast the WINNER** of that property. A later broker with a **genuine exclusive** on the same asset would then route to branch (d) COMPETING, receive **no Lead**, and have the email logged on `resolveLiveRecord(null)` — a silent total loss of a real submission. That inverts the module's whole purpose.
3. **The business outcome is correct.** A CFO property gets no first-broker-wins tracking, so the first broker to bring it **directly or exclusively** wins it clean. An exclusive beating a blast is the desired arbitration, not a gap.

**Residual, stated (R5):** DPEG loses the ability to answer "who blasted us this asset first?" from the ledger. Mitigation: the staging row is never deleted and `Extracted_JSON__c` holds every property verbatim; the new list view (§3.7) makes that population listable.

### 3.4 Guardrail (c) — replies and repeats to CFO threads: **no new mechanism needed**

Verified in source, not assumed:

- **Replies.** `PropertyMatchingService.findRecordByReplyHeaders` ends `return (match.WhatId != null) ? match.WhatId : match.WhoId;`. A gate's Task is logged **unattached** (both null), so the lookup returns `null` and the reply **falls through to the normal path** and is classified afresh. This is **already** the deployed behaviour for `Not Acquisition (gated)` and `Not Acquisition (pre-filtered)`; the CFO gate inherits it. A reply that re-classifies as CFO is gated again and gets its own staging row — correct, since each email gets one row.
- **Repeats.** Branch (b) keys on `Competing_Broker_Submission__c` rows, and a CFO email creates none. A repeat blast is simply classified and gated again.

**No new labels for (c).** Adding "reply to a gated thread" labels would require a mechanism (a lookup from Task to gate) that does not exist and that the two deployed gates deliberately do without.

### 3.5 Guardrail (d) — reversibility: **Custom Metadata, recommended**

| Option | Verdict |
|---|---|
| Hardcoded constants | ❌ The user states this rule is "likely to be tuned"; every tune becomes deploy → review → test → deploy. |
| Hierarchy Custom Setting | ❌ Per-user override is meaningless for an automated pipeline, and it adds a data-load step. |
| **`Broker_Intake_Setting__mdt`, one `Default` record** | ✅ **ADOPT.** CMDT precedent exists in-repo (`Task_Group_Def__mdt`, `Transaction_Task_Def__mdt`). **CMDT reads via `getInstance('Default')` are not SOQL and consume no query limit** — which matters because this module asserts a governor budget. |

Type: `Broker_Intake_Setting__mdt`

| Field | Type | Code default when the record is missing |
|---|---|---|
| `Suppress_Call_For_Offers__c` | Checkbox | `false` (**ship dark**) |
| `Call_For_Offers_Min_Confidence__c` | Number(3,2) | `LLMExtractionParser.CONFIDENCE_HIGH_MIN` (0.85) |
| `Internal_Domains__c` | Text(255) | empty → §2.3 guard 4 is a no-op (see **D-2**) |

Read through a new pure accessor, `BrokerIntakeSettingUtil` — a **utility, not a Service** (no DML, no orchestration), matching the in-module precedent that `InboundEmailFieldUtil` "is a pure utility (not a service)". **No selector is required and none should be added**: a CMDT `getInstance` is not SOQL, so the §2 "all SOQL lives in a selector" rule does not engage. State that in the class header so review does not demand one.

🔴 **Two mandatory properties of the accessor:**

1. **A missing record must degrade to the code defaults**, never throw. This org has a recorded history of CMDT **record** deploys failing with `UNKNOWN_EXCEPTION` (the `Transaction_Task_Def__mdt` load had to be done through an Apex loader). If the record fails to arrive, the pipeline must behave exactly as it does today.
2. **`@TestVisible` static override fields** so tests set the toggle explicitly.

⚠ **The vacuous-pass trap.** A toggle-gated feature can ship as a proven no-op with a fully green suite. Two tests are therefore mandatory, not optional: one asserting the **default is OFF and a CFO email still creates a Lead**, and one asserting the behaviour **with the toggle ON**. Likewise the UAT matrix's step 0 is "flip the toggle" — without it every CFO UAT case passes for the wrong reason.

### 3.6 Guardrail (e) — outcome labels

**One new label:**

```
public static final String OUTCOME_CALL_FOR_OFFERS = 'Not Routed (call for offers)';
```

🔴 **It must NOT start with `Not Acquisition`.** A CFO blast **is** acquisition-related; filing it under that prefix would be semantically wrong and would silently pollute the deployed `Gated_Not_Acquisition` list view, whose filter is `Outcome__c startsWith 'Not Acquisition'`.

No second label is needed: the near-miss population is carried by the `Deal_Notes__c` note (§3.1), which is where a human working the Lead will actually see it.

`Outcome__c` is free Text and historical rows are **not** back-filled — the established precedent for the retired `Competing Duplicate` label. The field's `<description>` must gain the new label (it already enumerates the others).

### 3.7 Guardrail (f) — what the user sees

New list view on `Inbound_Email_Staging__c`, mirroring the `Gated_Not_Acquisition` precedent exactly:

```
Gated_Call_For_Offers   label: "Gated: Call for Offers"
filter: Outcome__c startsWith 'Not Routed'
columns: NAME, From_Address__c, Subject__c, Outcome__c, Property_Count__c, Processed_DateTime__c
filterScope: Everything
```

`Property_Count__c` is added over the existing view's column set because a blast's value to a human is *how many properties it named*.

### 3.8 🔴 CONFLICT TO SURFACE — U2 partially reverses the recorded `Precedence: bulk` decision

`ExtractAddressQueueable`'s `SENDER_CONTAINS` block carries an explicit, code-review-overruled, user-endorsed prohibition:

> 🔴 `Precedence: bulk` **IS DELIBERATELY EXCLUDED. DO NOT ADD IT** … `Precedence: bulk` means MASS-SENT, not MACHINE-GENERATED. It is exactly what a legitimate broker BLAST platform (RCM, Crexi, Buildout) sets on a real listing announcement — **the highest-value email this pipeline exists to capture.**

U2's business rule is the opposite: mass-marketed blasts should **not** become Leads. The conflict is real and must be visible to the user.

**Resolution — the two are reconcilable, and the existing text says how.** That same block continues:

> Bulk mail must reach the LLM and be classified there, where a wrong call lands in the soft tier … instead of vanishing.

U2's gate runs **after** the callout, which is precisely what that sentence asks for. Therefore:

- ✅ Implement U2 **post-callout only**, exactly as §3.2 specifies.
- ❌ **Do NOT add `bulk`, `List-Unsubscribe`, or any blast signal to `SENDER_CONTAINS` / `SENDER_EXACT` / the header pre-filter.** A pre-callout suppression would deny bulk mail the tiered gate and re-open the "lost claim, unobservable" failure the prohibition was written for.
- The `SENDER_CONTAINS` comment must be **amended, not contradicted**: add a sentence recording that intake-rules-v2 introduced a post-callout call-for-offers gate and that this prohibition still stands for the pre-callout filter.

**If the user disagrees with this reconciliation** — i.e. wants blasts suppressed *before* the callout — that is a different change with a different risk profile and should be raised separately.

---

## 4. U3 — FOOTER / SIGNATURE COMPANY EXTRACTION

### 4.1 Verdict — enriched block only, prompt-only, no Apex, no schema, pins untouched

`broker_company` is already a key in the enriched response schema and already flows `LLMExtractionParser → LLMExtractionResult.brokerCompany → EmailToLeadService.buildLead → Lead.Company`. **No code change accompanies U3.**

Per **F5**, the existing S4 sentence already names the signature block. The three real gaps are: precedence framing, "footer", and — the important one — the division-strip rule.

### 4.2 🔴 The finding: U3 as literally requested would fragment Account matching

The S4 header states this is load-bearing:

> (a) the "never append a division, team, region, market or group name" clause — **"JLL" vs "JLL Capital Markets" is exactly the fragmentation exact-name matching cannot bridge**

That clause is currently attached **only to the domain-inference sentence**. U3 makes **stated** names beat inference — and a footer states the *division* far more often than the clean firm (`JLL Capital Markets`, `CBRE | Investment Properties`, `Marcus & Millichap IPA`, `Cushman & Wakefield Sunbelt Multifamily Advisory Group`). Without extending the clause, U3 would systematically feed division strings into `Lead.Company` → `AccountSelector.selectByNames` and mint a second Account per division.

**The division-strip rule must therefore be extended to stated names.** This is the single highest-value item in U3.

### 4.3 The proposed enriched-block edit (verbatim — developer must not paraphrase)

Replace the opening of the S4 paragraph. **Current:**

```
broker_company WHEN THE EMAIL DOES NOT NAME THE FIRM: if the body, the signature
block or the subject states the broker's company, use it exactly as written. If no
company is stated anywhere, you MAY infer broker_company from the DOMAIN of
broker_email — ...
```

**Proposed:**

```
broker_company — STATED ALWAYS BEATS INFERRED: broker_company is the firm of the
person identified by broker_email. If that firm is named ANYWHERE in the email, use
the stated name; look in the body, the subject, the sender's SIGNATURE BLOCK, and
the FOOTER — the letterhead, disclaimer, address block or copyright line at the
bottom of the message or of an attached flyer image, which is frequently the only
place the firm is written. Return only the FIRM name: when the stated form carries a
division, team, region, market, group or business-line qualifier, strip it — "JLL
Capital Markets" gives "JLL", "CBRE | Investment Properties" gives "CBRE", "Marcus &
Millichap IPA" gives "Marcus & Millichap". When the email names several firms — for
example a sending platform in the header and a listing brokerage in the footer —
broker_company is the firm of broker_email's owner, and any other firm belongs in
deal_summary. ONLY if no firm is stated anywhere may you infer broker_company from
the DOMAIN of broker_email — ...
```

Everything from `— kevin.girard@jll.com gives "JLL"` onward — the conventional-capitalisation list, the free-mail blocklist, the ISP/telecom prohibition, the resolve-to-empty sentence, and the closing deferral sentence — is **carried verbatim and unchanged**. The reviewer-mandated ISP hardening is not touched.

### 4.4 Bounding the change (the mandatory precedence framing)

Per the established pattern for prompt widening — *"widening where a value may be found is the safe shape, if you add a precedence clause"* — U3's precedence is the **`ONLY if no firm is stated anywhere`** clause, which makes inference strictly a fallback and confines the behaviour change to emails where a firm **is** stated.

| Email shape | Today | After U3 | Assessment |
|---|---|---|---|
| Firm stated inline; domain agrees | stated | stated (unchanged) | No change |
| Firm only in the footer; business domain | inferred from domain | **stated, division-stripped** | Converges on the same string in the common case (`jll.com` → "JLL"; footer "JLL Capital Markets" → "JLL"). |
| Firm only in the footer; **free-mail / ISP domain** | **EMPTY** → `COMPANY_PLACEHOLDER` → no Account match | **the real firm** → Account match | ✅ **The win.** This is the U1 incident's own shape. |
| Footer names a firm ≠ the sender's firm (blast platform) | domain-inferred sender firm | sender's firm (the "several firms" clause) | Guarded by the new clause. |

**Residual (R6):** a stated legal-name variant (`"Orion Realty Advisors"`) versus the domain-inferred form (`"Orion Realty"`) can mint two Accounts across the change boundary. **Accepted** — the S4 header already establishes that this failure mode is recoverable (a human merges Accounts), which is exactly why domain inference was preferred over the placeholder in the first place.

⚠ **Interaction with U1, stated:** when U1's override fires, `brokerCompany` is **cleared** (§2.3), so U3's footer-extracted firm is discarded on that path and carried in the demotion note instead. That is correct — the footer firm belongs to the body-named contact, not to the envelope sender. When U1's override does **not** fire (guard 3: a real broker sending directly), U3's value is kept, and that pairing is the win in the table above.

---

## 5. PROMPT-CHANGE LEDGER (what is touched, what is pinned)

| Block | U1 | U2 | U3 | Fixture impact |
|---|---|---|---|---|
| `LEGACY_EXTRACTION_RULES` | **untouched** | **untouched** | **untouched** | `legacyExtractionRules_areStillVerbatim` unchanged and must stay **green** |
| `LEGACY_RESPONSE_FORMAT` | **untouched** | **untouched** | **untouched** | `rollbackLever_recomposesTheOriginalFourKeyPrompt` unchanged and must stay **green** |
| `ENRICHED_EXTRACTION_RULES` | untouched | `category_confidence` sentence + schema key | S4 paragraph opening replaced | none — the pins do not cover this block |
| `MODEL` / `temperature` / `MAX_TOKENS` / `MAX_INPUT_CHARS` | unchanged | unchanged | unchanged | protection 2 preserved |

**The one-line rollback lever survives intact**, and it degrades correctly: a legacy-shape response carries no `email_category` and no `category_confidence`, so the U2 gate fails open and the pipeline behaves exactly as it does today.

⚠ **U2 and U3 both edit the enriched block, which makes UAT cases D and D′ from `agent-output/design-requirements-extraction-completeness.md` §6.5 MANDATORY re-runs** — the `LLMExtractionCalloutService` header declares them recurring checks after *any* edit to that block, not one-off sign-off. They are carried into §8 as case G.

**ADD a sixth regression fixture, do not re-pin the existing five.** `ExtractionRegressionFixtureTest`'s header states the intended maintenance action: *"Adding a fixture when a NEW email shape appears in production is the intended maintenance action, and it costs one entry in `fixtures()`."* U1 introduces exactly such a shape — **direct send, no forward block, body names a different contact.** Adding it grows the corpus without disturbing a single pin.

---

## 6. COMPONENT LIST

### 🔵 ADMIN WORK (`salesforce-admin`)

| # | Component | Detail |
|---|---|---|
| A1 | **`Broker_Intake_Setting__mdt`** (new CMDT type) | `Suppress_Call_For_Offers__c` (Checkbox), `Call_For_Offers_Min_Confidence__c` (Number 3,2), `Internal_Domains__c` (Text 255, comma-separated) |
| A2 | **`Default` CMDT record** | `Suppress_Call_For_Offers__c = false` (ship dark), `Call_For_Offers_Min_Confidence__c = 0.85`, `Internal_Domains__c` empty. ⚠ Known org gotcha: CMDT **record** deploys have failed here with `UNKNOWN_EXCEPTION` — be prepared to load via anonymous Apex. The code must not depend on the record existing. |
| A3 | **`Inbound_Email_Staging__c` list view `Gated_Call_For_Offers`** | Per §3.7 |
| A4 | **`Inbound_Email_Staging__c.Outcome__c` `<description>`** | Append `'Not Routed (call for offers)'` to the documented label list |

*No new objects, no new fields on `Lead`, no new fields on `Inbound_Email_Staging__c`, no permission-set change (the CMDT type needs no FLS grant for Apex reads), no validation-rule change.*

### 🟢 DEVELOPMENT WORK (`salesforce-developer`)

| # | Component | Change |
|---|---|---|
| D1 | **`ExtractAddressQueueable.cls`** | New `OUTCOME_CALL_FOR_OFFERS`; new `FORWARD_MARKER_PATTERN`; new `@TestVisible static Boolean isGenuineForward(String)`; new `applySenderFirstBrokerIdentity(...)` + `demoteBodyBroker(...)`; new `isCallForOffersGated(...)`; two call-site insertions in `execute()`; amend the `applyEnvelopeEmailFallback` Javadoc (gap #2 closed), the `buildLlmText` prohibition list, and the `SENDER_CONTAINS` `Precedence: bulk` note; extend the class-header routing tree |
| D2 | **`LLMExtractionCalloutService.cls`** | ENRICHED block only: `category_confidence` sentence + schema key (U2), S4 paragraph opening replaced (U3). Header note per the existing convention. **Legacy constants untouched.** |
| D3 | **`LLMExtractionParser.cls`** | Parse `category_confidence` → `result.categoryConfidence`, reusing the existing `toConfidence` clamp. Absent/unparseable → `null`. |
| D4 | **`LLMExtractionResult.cls`** | New `public Decimal categoryConfidence;` with a Javadoc noting it is a **separate judgement** from `confidence` |
| D5 | **`BrokerIntakeSettingUtil.cls`** (new) | Pure CMDT accessor; hardcoded safe defaults on a missing record; `@TestVisible` overrides; header note that a CMDT `getInstance` is not SOQL and needs no selector |

### 🟡 TESTS (`salesforce-unit-testing`)

`ExtractAddressQueueableTest`, `LLMExtractionParserTest`, `BrokerIntakeSettingUtilTest` (new), `ExtractionRegressionFixtureTest` (**add fixture 6 only**). Detail in §7.

### 🔷 DOCS

`ARCHITECTURE.md` §2 amendments (routing tree gains the CFO gate; the sender-first identity rule; the new outcome label) — **required in the same PR** per §6. Plus `docs/2026-08-03-intake-rules-v2.md`.

---

## 7. TEST PLAN

### U1 — fully deterministic

| Test | Asserts |
|---|---|
| `isGenuineForward` truth table | `-----Original Message-----` ✓; `---------- Forwarded message ---------` ✓; `Begin forwarded message:` ✓; a bare line-start `From: x@y` ✓; a **mid-line** `... From: x ...` ✗ (line anchoring); no marker ✗; null/blank ✗ |
| `directSend_bodyNamesADifferentBroker_swapsIdentity` | `brokerEmail` == envelope, `brokerName` == `From_Name__c`, `listingBroker*` == the demoted pair, `brokerCompany/Phone/Mobile/Title` all null, one note added |
| `directSend_modelAlreadyReturnedTheSender_changesNothing` | 🔴 **the discrimination test** — guard 3: no clear, no demotion, no note |
| `manualForwardWithQuotedBlock_isUntouched` | Extraction identical before/after (use the regression corpus's manual-forward body) |
| `autoForwardWithNoQuotedBlock_stillResolvesToTheBroker` | The high-volume production shape keeps working |
| `listingBrokerAlreadySet_isNotOverwritten` | Different existing `listingBrokerEmail` survives; note still added |
| `endToEnd_incidentShape_leadIsTheEnvelopeSender` | Through `execute()`: `Lead.Email` == envelope, `Lead.Listing_Broker_Email__c` == body-named, `Lead.Company` == `COMPANY_PLACEHOLDER` |
| `senderFirstOverride_addsNoQueriesAndNoDml` | `lastRunQueryCount` / `lastRunDmlCount` unchanged vs the pre-change budget |

### U2

| Test | Asserts |
|---|---|
| `callForOffers_toggleOff_stillCreatesALead` | 🔴 **the vacuous-pass guard** — the default must be OFF and behaviour must be today's |
| `callForOffers_toggleOn_highCategoryConfidence_createsNoLead` | 0 Leads, outcome == `OUTCOME_CALL_FOR_OFFERS`, `Result_Record_Id__c` null, staging `Processed`, **one Task logged** |
| `callForOffers_gated_takesNoClaim` | `[SELECT COUNT() FROM Property_Registry__c]` == 0 **and** `Competing_Broker_Submission__c` == 0, on a CFO email that carries a usable address |
| `callForOffers_belowThreshold_createsALeadAndRecordsTheNearMiss` | Lead created; `Deal_Notes__c` contains the near-miss note |
| `callForOffers_categoryConfidenceMissing_createsALead` | Fail-open (also covers the legacy-shape rollback path) |
| `acquisitionDeal_atAnyConfidence_createsALead` | The gate is category-scoped |
| `callForOffers_gateIsUnreachableOnAReply` | Reply exits pre-callout; no gate, no second classification |
| `callForOffers_gated_stillStoresExtractedJson` | D3 tier 1 survives the gate |
| `LLMExtractionParserTest` | `category_confidence` present / absent / out-of-range / non-numeric; `confidence` and `category_confidence` are independent |
| `BrokerIntakeSettingUtilTest` | Missing record → code defaults; override seam works |

### U3

**No Apex test is possible** — the class header is explicit that a prompt rule's *effect* cannot be asserted in Apex. Verification is UAT case F (§8). What Apex **does** pin: `ExtractionRegressionFixtureTest` stays green **untouched**, which is the proof the byte-pins were not disturbed.

---

## 8. UAT MATRIX

**Step 0 (mandatory, or every U2 case passes for the wrong reason):** set `Suppress_Call_For_Offers__c = true` on the `Default` CMDT record.
**Step 0b (mandatory for every case):** forward each test email **FRESH** — a redelivery is skipped by the Message-ID idempotency guard and proves nothing.
**Where to read results:** on `Inbound_Email_Staging__c` (`Outcome__c`, `Extracted_JSON__c`, `Routed_Record_Ids__c`) — the only surface written on **every** branch, including the ones that create no Lead.

| # | Case | Setup | Expected |
|---|---|---|---|
| **A** | **Direct send** | From a non-firm mailbox (e.g. hotmail), no forward block, body names a different broker with a signature | `Lead.Email` == the **envelope sender**; `Listing_Broker_Email__c` == the body-named address; `Deal_Notes__c` carries the demotion line naming the discarded company/phone/title; `Lead.Company` == `Unknown - Via Email` |
| **B** | **Genuine manual forward** | An employee forwards a broker email; quoted `From:` header block present | `Lead.Email` == the **original broker** — **byte-identical to today**. Regression pin. |
| **B′** | **Genuine auto-forward** | Mailbox rule; `X-Forwarded-For` present; no quoted block | `Lead.Email` == the broker (envelope). Unchanged. |
| **C** | **CFO blast suppressed** | A real marketed call-for-offers with a stated deadline, toggle ON | **NO Lead.** `Outcome__c` == `Not Routed (call for offers)`; a Task is logged; **0 new `Property_Registry__c` rows**; visible in the `Gated: Call for Offers` list view |
| **D** | **CFO-unsure still creates** | An email that reads ambiguously between exclusive and campaign | **Lead IS created**; `Deal_Notes__c` carries the near-miss note with the observed `category_confidence` |
| **E** | 🔴 **Misclassification probe — run BEFORE flipping the toggle** | Leave the toggle **OFF** for ≥1 week of live traffic. Then query `Inbound_Email_Staging__c` and read `email_category` + `category_confidence` out of `Extracted_JSON__c` for every row that produced a Lead. | **No genuine direct/exclusive opportunity appears at `call_for_offers` with `category_confidence >= 0.85`.** Flip the toggle only once that holds. This turns the toggle into a **measurement instrument first and a suppression second**, and it is the only real answer to guardrail (a). |
| **F** | **Footer company** | Email whose only firm mention is in the footer/disclaimer; sent from a free-mail domain | `broker_company` == the **stated firm** (not empty, not the mailbox provider) → `Lead.Company` |
| **F′** | **Division strip** | Footer states `"JLL Capital Markets"` | `broker_company` == **`"JLL"`** — the Account-fragmentation pin |
| **G** | **Recurring enriched-block checks** | Re-run cases **D** and **D′** from `design-requirements-extraction-completeness.md` §6.5 | An already-claimed property re-extracts to the **same** `Property_Key__c` (D); a body address beats a subject address (D′). Mandatory because U2 and U3 both edit the enriched block. |
| **H** | **Rollback drill** | Set `Suppress_Call_For_Offers__c = false` | A CFO blast creates a Lead again with no deploy. Proves the lever. |

---

## 9. OPEN DECISIONS FOR THE USER

| ID | Decision | Recommendation |
|---|---|---|
| **D-1** | Outcome label casing — `'Not Routed (call for offers)'` (proposed) vs the user's `'Not routed (call for offers)'` | Proposed form, for consistency with `'Not Acquisition (gated)'`. One-line change either way. **Whatever is chosen must match the list-view filter `startsWith 'Not Routed'`.** |
| **D-2** | 🔴 **Close residual R1** (a manual forward with no recognisable `From:` block would attribute the claim to a DPEG employee). Options: **(a)** ship without a guard and accept R1; **(b)** CMDT `Internal_Domains__c` list — zero SOQL, admin-maintained, can go stale; **(c)** query `User.Email` for the envelope sender — self-maintaining and exact, but **+1 SOQL per email** and needs a new `UserSelector` method plus a `SYSTEM_MODE` decision for the automated context. | **(b)**, defaulted empty so it is a no-op until an admin fills it. It is on the CMDT this design already introduces, costs nothing at runtime, and (c)'s query is a permanent cost on a budget this module asserts. |
| **D-3** | Add `category_confidence` to the enriched block (U2) | **Yes.** Without it the "high confidence" half of the user's own guardrail carries no information (F3) and the gate is one-factor. Enriched-block only, so no pin is disturbed. |
| **D-4** | §3.8 — accept the post-callout reconciliation of U2 with the `Precedence: bulk` prohibition | **Yes.** If the user actually wants pre-callout blast suppression, that is a separate change with a materially worse risk profile (lost claims, unobservable). |
| **D-5** | Add regression fixture 6 (`direct send, body names a different contact`) | **Yes** — this is the corpus's own documented maintenance action, and it is additive, not a re-pin. |

---

## 10. EXECUTION ORDER AND ROUTING

```
1. ADMIN   A1–A2  Broker_Intake_Setting__mdt type + Default record
              ↳ must land FIRST: D5 compiles against the type
2. DEV     D2–D4  Prompt (enriched only) + parser + DTO
              ↳ D1's gate reads categoryConfidence, so this precedes it
3. DEV     D5     BrokerIntakeSettingUtil
4. DEV     D1     ExtractAddressQueueable — U1 override + U2 gate
5. ADMIN   A3–A4  List view + Outcome__c description
              ↳ A3's filter must match D1's final label string
6. TESTS   §7     unit-testing agent
7. REVIEW  code-review
8. DEPLOY + DOCS (parallel) — ARCHITECTURE.md §2 in the SAME PR
```

**Routing recommendation:** **`salesforce-developer`** for all Apex (D1–D5) — the module is warm, the layering is unchanged (a queueable orchestrator plus a pure utility), there is no new integration, no new callout, no LDV concern and no performance work, so `salesforce-technical-architect` is not indicated. **`salesforce-admin`** for A1–A4 — one CMDT type, one record, one list view, one field description: routine declarative work, well below the `salesforce-solution-architect` threshold.

---

## 11. SUMMARY OF VERDICTS

| Question | Verdict |
|---|---|
| U1 prompt or Apex? | **Apex only.** The model never sees the envelope (F2); a prompt-side U1 would be a **legacy-block** edit and would break the byte-pin, the rollback lever, and determinism — for a strictly weaker rule. |
| Fixture pins | **Untouched.** U1 is pure Apex; U2/U3 are enriched-block only. One fixture **added**, none re-pinned. |
| U1 forward predicate | Body-level `From:` header line **or** a forward marker, both read from `Raw_Body__c`, biased toward "forward". `Forwarded_By__c` is **not** in the predicate. |
| U2 threshold | `category_confidence >= 0.85`, defaulting to the existing `LLMExtractionParser.CONFIDENCE_HIGH_MIN`; **no second hardcoded number**. Missing/unparseable → fail open. |
| U2 claim engine | **No claim.** Structurally forbidden by a deployed VR (F4), harmful if it were possible, and the correct business outcome. |
| U2 toggle | **CMDT `Broker_Intake_Setting__mdt`, default OFF** (ship dark), safe code defaults on a missing record. |
| U2 labels | One new: `'Not Routed (call for offers)'`. **Must not** start with `'Not Acquisition'`. Near-misses get a `Deal_Notes__c` note, not a second label. |
| U3 | Prompt-only, enriched-only. **The real work is extending the division-strip rule to STATED names** — without it U3 fragments `Lead.Company` → Account matching. |
| Biggest risk | **R1** — a manual forward with no recognisable header block attributing a claim to a DPEG employee. Decision **D-2**. |
| Second-biggest risk | Shipping U2 as a **proven no-op** behind an OFF toggle with a green suite. Mitigated by two mandatory tests and UAT step 0 / case E. |
