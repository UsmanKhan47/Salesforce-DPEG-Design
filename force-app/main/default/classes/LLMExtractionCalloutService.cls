/**
 * Dedicated OpenAI callout wrapper for Broker-Protection LLM field extraction. Given the
 * text (and optionally an image) of a forwarded broker email, it asks a vision-capable
 * model to classify the email, identify the ORIGINAL broker, and pull the full
 * deal-screening field set for EVERY property the email pitches, returning a typed
 * LLMExtractionResult.
 *
 * LAYER — callout service. Per ARCHITECTURE.md §2 ("all ASB/Plaid callouts wrapped
 * in a dedicated service class ... so they can be mocked via HttpCalloutMock") the
 * single `Http.send` lives here and nowhere else, so callers (and their tests) mock this
 * one boundary via HttpCalloutMock. No SOQL, no DML.
 *
 * ⚠ DELIBERATE, TEMPORARY §3 EXCEPTION — DIRECT (NON-ASB) EXTERNAL CALLOUT.
 * ARCHITECTURE.md §3 mandates a hub-and-spoke model where "All external integrations
 * route through ASB. No direct peer-to-peer integrations between Salesforce and
 * external systems." This class INTENTIONALLY breaks that rule: it calls OpenAI
 * directly via the `OpenAI_API` Named Credential rather than through the Avanza
 * Service Bus. The exception is accepted because NO ASB LLM-extraction endpoint
 * exists yet — there is nothing on the bus to route to. It is scoped and reversible:
 * when ASB exposes an LLM-extraction spoke, ONLY this class's endpoint constant (and
 * the Named Credential it points at) change; the public `extract(...)` signature,
 * the request-shaping, and every downstream caller stay identical. Credentials are
 * never hardcoded — the API key lives entirely in the OpenAI_Credential external
 * credential (§3.2), injected into the Authorization header by the platform.
 *
 * ═══ 🔴 THE PROMPT IS PART OF THE CLAIM ENGINE. TREAT IT AS PRODUCTION LOGIC. ═══
 * The first-broker-wins ledger arbitrates on exactly two extracted values — `broker_email`
 * (repeat detection and submission attribution) and `property_address` (normalized into the
 * unique Property_Registry__c.Property_Key__c). A subtly differently-worded address produces
 * a DIFFERENT claim key, and the 0.6 Jaccard fuzzy threshold may or may not rescue it. The
 * failure is invisible: a competing broker quietly WINS a property they lost, or a repeat
 * registers as a new claim. No exception, no error row, no failing test.
 *
 * Three structural protections, all load-bearing:
 *   1. LEGACY_EXTRACTION_RULES is the pre-enrichment instruction VERBATIM and FIRST, in its
 *      own delimited block, ahead of every new instruction. Do not paraphrase it, reorder
 *      it, or "tidy" its wording — it is diffable against git history on purpose.
 *   2. MODEL and temperature are UNCHANGED (gpt-4o-mini, 0). Changing the model at the same
 *      time as the prompt would make any regression impossible to attribute.
 *   3. ROLLBACK IS ONE LINE. Set
 *        EXTRACTION_INSTRUCTION = LEGACY_EXTRACTION_RULES + LEGACY_RESPONSE_FORMAT;
 *      and the pipeline is back on the original four-key contract with NO other code
 *      change — LLMExtractionParser accepts a response with no `properties` array by
 *      synthesizing a one-element array from the top-level `property_address`.
 *
 * ═══ RESPONSE SIZING — WHY MAX_TOKENS IS 4096 AND NOT 512 (C-14) ═══
 * The enriched contract is roughly 20x the old one: ~150 tokens of email-level block, plus
 * 200-260 per property object, plus a narrative. Three properties is ~1,150 tokens; ten is
 * ~2,900. The previous 512 was 4-8x too small, and a TRUNCATED response is the most
 * dangerous failure this class has: it is cut mid-object, JSON.deserializeUntyped throws,
 * and (before this change) the email landed on an Error staging row with NO Lead, NO Task
 * and NO claim — strictly worse than an outage. Four changes address it together:
 * 4096 max_tokens, OpenAI JSON mode (`response_format: json_object`, which GUARANTEES
 * syntactically valid JSON), prompt-level caps on `deal_summary` and property count, and —
 * in ExtractAddressQueueable — a degrade catch widened to JSONException.
 *
 * Cost is NOT the constraint: ~10k input + ~1.5k output on gpt-4o-mini is ~$0.0024 per
 * email, about $36/month at 500 emails/day. Shrinking the prompt "for cost" would trade a
 * trivial saving for the truncation failure above.
 *
 * ═══ PROMPT TUNING 2026-08-02 — three rules added, ALL in the ENRICHED block ═══
 * Three extraction defects observed on live traffic (staging row a0aiw000000NEK1AAO). See
 * agent-output/design-requirements-prompt-tuning.md.
 *   1. property_name came back empty even when the name led the body. Now defined as the
 *      marketing / brand name, explicitly contrasted with property_address, with an
 *      example, and "leave it empty rather than invent one".
 *   2. offer_due_date was recalled from TRAINING DATA (a real 2023 campaign) for a date
 *      that appears nowhere in the email. Year-less dates now anchor on the year-bearing
 *      "Sent:"/"Date:" line, else the injected REFERENCE DATE, rolling forward a year only
 *      when the date would otherwise sit more than 30 days in the past — never backward,
 *      never from world knowledge.
 *   3. sent_datetime was fabricated the same way, and unlike offer_due_date it passes
 *      through NO plausibility gate — the 2023 value reached
 *      Competing_Broker_Submission__c.Submitted_DateTime__c, which is the 90-day recency
 *      filter behind REPEAT DETECTION. A submission stamped outside that window is
 *      invisible, so the broker's own follow-up re-routes as a fresh competing claim. That
 *      makes this an arbitration defect, not a display bug, and the highest-priority of the
 *      three. sent_datetime is now explicit-or-EMPTY.
 *
 * ⚠ LEGACY_EXTRACTION_RULES AND LEGACY_RESPONSE_FORMAT WERE NOT TOUCHED. Rule 3 concerns a
 * LEGACY value, and was still written into the enriched block as a paragraph that DEFERS to
 * the original rule (the pattern BROKER vs LISTING BROKER already uses). It may only narrow
 * sent_datetime toward empty; it does not restate WHERE the value is read from — the
 * OUTERMOST / EARLIEST "Sent:" line stays authoritative — and it names none of the other
 * claim values. Editing the legacy block would have broken both protection 1 and the
 * one-line rollback in protection 3 above.
 *
 * ═══ CONVERSION ENRICHMENT S4, 2026-08-03 — broker_company FROM THE EMAIL DOMAIN ═══
 * One rule added, again ENRICHED-BLOCK ONLY (LEGACY_EXTRACTION_RULES and LEGACY_RESPONSE_FORMAT
 * are untouched, so protections 1 and 3 both stand): when the email states no company anywhere,
 * broker_company MAY be inferred from the DOMAIN of broker_email — never from a free/consumer
 * mailbox domain, and never with a division/team/region suffix appended. A stated company always
 * wins; the rule only fills a value that would otherwise be empty. It carries the same explicit
 * deferral sentence the BROKER vs LISTING BROKER and sent_datetime paragraphs use, because it
 * READS broker_email and must not be read as redefining it. broker_company is already a key in
 * the enriched response schema, so there is NO schema change.
 *
 * ⚠ THIS IS THE FIRST PROMPT CHANGE WHOSE OUTPUT FEEDS AN ATTACHMENT DECISION.
 * broker_company flows into EmailToLeadService.buildLead -> Lead.Company, and since Smart Lead
 * Conversion Lead.Company is an ACCOUNT MATCH KEY (LeadConvertMatchService.collectMatchKeys ->
 * AccountSelector.selectByNames). This paragraph therefore participates in deciding WHICH FIRM a
 * deal is attributed to — it is no longer display-only. Two things are load-bearing if you edit
 * it: (a) the "never append a division, team, region, market or group name" clause — "JLL" vs
 * "JLL Capital Markets" is exactly the fragmentation exact-name matching cannot bridge; (b) the
 * free-mail blocklist, which is what stops hotmail.com becoming a brokerage. The failure mode is
 * recoverable (a slightly-off firm name mints a second Account a human can merge), which is why
 * domain inference beats the 'Unknown - Via Email' placeholder it replaces. NO downstream code
 * change accompanies it — traced end to end in
 * agent-output/design-requirements-conversion-enrichment.md §6.3.
 *
 * ⚠ THE FREE-MAIL BLOCKLIST DIVERGES FROM DESIGN §6.2 — REVIEWER-MANDATED HARDENING, 2026-08-03.
 * §6.2's wording is otherwise carried verbatim, but its blocklist named only webmail providers and
 * then relied on the catch-all "any other consumer mailbox provider ... never from a domain that is
 * not a company's own domain". That leaves ISP mailboxes wide open, because an ISP domain IS a real
 * company's own domain: under the preceding "use the registrable part of the domain" sentence,
 * comcast.net yields "Comcast", att.net yields "AT&T". Those are precisely the values that must
 * never be produced — Lead.Company feeds AccountSelector.selectByNames, and BrokerFirmController
 * then aggregates every deal on that Account as ONE firm's, so a single leaked ISP domain pools
 * unrelated independent brokers into a "Comcast" brokerage. That is the same defect D1b's
 * placeholder guard exists to prevent, arriving by a different route. Two additions close it:
 * the named ISP/consumer domains, and an explicit "an ISP/telecom/cable/webmail/portal domain is
 * never the firm, even when its name is a real company" rule with concrete counter-examples. A
 * third sentence resolves ambiguity toward EMPTY — but is scoped to the mailbox-provider question
 * only, deliberately, so it does not suppress the unknown-but-genuine brokerage domain
 * (orion-realty.com -> "Orion Realty") that is the whole point of S4.
 *
 * ═══ EXTRACTION COMPLETENESS FIX 1, 2026-08-03 — THE INPUT NOW CARRIES A Subject: LINE ═══
 * The text handed to `extract(...)` is no longer the raw body alone: `ExtractAddressQueueable
 * .buildLlmText` prepends `Subject: <subject, CR/LF collapsed to one space>` and a blank line.
 * NOTHING IN THIS CLASS CHANGED TO ACHIEVE THAT — not the signature, not buildRequestBody, not
 * MAX_INPUT_CHARS — because the composition happens at the queueable call site, which keeps the
 * §3 ASB re-homing promise in this header literally true. One enriched paragraph was added
 * (FIRST in the block, because it describes the SHAPE of the input and everything after depends
 * on it) telling the model the line exists and may be read for any value. Without it the legacy
 * rule "property_address is any property address found anywhere in the BODY" would license the
 * model to ignore a subject-only market like "Suburban Chicago" — which is the exact email that
 * motivated the fix.
 *
 * ⚠ LEGACY_EXTRACTION_RULES AND LEGACY_RESPONSE_FORMAT ARE AGAIN UNTOUCHED. Note the legacy
 * block's opening sentence ("The content below is the body of a broker email") is now slightly
 * imprecise — that is ACCEPTED, not overlooked: editing it would break the byte-pin and the
 * one-line rollback lever, and the enriched paragraph corrects the shape explicitly.
 *
 * ═══ 🔴 WHY THE PARAGRAPH NARROWS broker_name / broker_email / sent_datetime BACK OUT ═══
 * The CR/LF collapse in `buildLlmText` closes `From:` INJECTION structurally — a one-line subject
 * can never contain a line that BEGINS `From:`. It does NOT close the symmetric `Sent:` exposure,
 * and prepending actually INVERTS it: the subject now sits at the HEAD of the composed text, which
 * is exactly where the legacy rule's "OUTERMOST / EARLIEST Sent: line" points. A subject such as
 * `FW: Sent: Monday — 123 Main St` therefore presents the EARLIEST `Sent:` token in the whole
 * input. The damage is not cosmetic: a fabricated `sent_datetime` flows to
 * `Competing_Broker_Submission__c.Submitted_DateTime__c`, which is the 90-day recency filter behind
 * REPEAT DETECTION — a submission stamped outside that window is invisible, so the broker's own
 * follow-up re-routes as a fresh COMPETING claim. That is an arbitration defect, and it is reachable
 * by accident (forwarded-subject debris), not only by an attacker.
 *
 * The fix is a prohibition in the same paragraph that did the widening: the Subject line is NEVER a
 * source for broker_name, broker_email or sent_datetime, and a `From:`/`Sent:` fragment inside it is
 * transport debris rather than a header line "whatever its position in the text" — the clause that
 * defeats the head-of-input inversion specifically. Note this ALSO hardens the `From:` route
 * SEMANTICALLY, on top of the structural collapse, so the two routes are now defended
 * independently rather than by one mechanism.
 *
 * ⚠ Read that alongside the prohibition in `ExtractAddressQueueable.buildLlmText`: the DETERMINISTIC
 * path (applyRegexFallback / applyEnvelopeEmailFallback) is hard-closed BY CONSTRUCTION because it
 * never sees the composed text at all, whereas this LLM path is SOFT-mitigated — collapse plus
 * prompt narrowing. Do not describe either mitigation as "the" control; they defend different paths
 * and only one of them is enforceable in Apex.
 *
 * 🔴 BODY-OVER-SUBJECT PRECEDENCE IS WHY THIS CANNOT RE-KEY AN EXISTING CLAIM. The paragraph
 * widens where `property_address` may be found, and `property_address` is one of the two values
 * the first-broker-wins ledger arbitrates on. The precedence clause bounds that exactly: the
 * subject may only ADD an address where the body stated none. Every existing
 * Property_Registry__c row was keyed from a body-derived address, so those emails extract
 * unchanged; the behaviour change is confined to emails that today yield NO key at all, where
 * there is nothing to regress against. Do not weaken or drop that clause — it is the whole
 * safety argument, and it is only observable live (UAT cases D and D′ below).
 *
 * ═══ ⚠ UAT D / D′ ARE RECURRING CHECKS, NOT ONE-OFF SIGN-OFF ═══
 * Both live in agent-output/design-requirements-extraction-completeness.md §6.5; D′ is added here
 * because §6.5 predates the reviewer's W1 finding.
 *   • D  — re-send a previously-processed email that already owns a registry row AND states its
 *          address in the BODY. Its new property_address must normalize to the SAME
 *          Property_Key__c, landing on branch (d) COMPETING (or (b) REPEAT). A NEW registry row
 *          means the key drifted → roll back FIX 1.
 *   • D′ — the body states address A and the subject states a DIFFERENT address B. The extracted
 *          property_address must normalize to A. THIS IS THE ONLY SCENARIO THAT ACTUALLY
 *          EXERCISES THE PRECEDENCE CLAUSE — D confirms nothing drifted, D′ confirms the rule
 *          that prevents drift is being obeyed. Without D′ the clause is untested in both
 *          directions.
 * 🔁 RE-RUN BOTH AFTER ANY MODEL-VERSION CHANGE (and after any edit to this block). There is NO
 * deterministic control for a prompt rule — no Apex test can assert it, and the model's behaviour
 * can move under a version bump without a single line of this repo changing. The rollback lever is
 * one line and is guaranteed by a unit test: blank-subject byte-identity means reverting
 * `extractOrDegrade` to `staging.Raw_Body__c` restores the previous input exactly
 * (ExtractAddressQueueableTest.buildLlmText_blankSubject_returnsTheBodyByteIdentically).
 *
 * ═══ INTAKE RULES V2, 2026-08-03 — U2 (category_confidence) AND U3 (stated firm wins) ═══
 * Two edits, BOTH ENRICHED-BLOCK ONLY. LEGACY_EXTRACTION_RULES and LEGACY_RESPONSE_FORMAT are
 * untouched again, so protections 1 and 3 both stand and no fixture pin is re-pinned.
 *
 *   U2 — one sentence appended to the CLASSIFICATION paragraph and one key added to the
 *   response schema: `category_confidence`.
 *
 *   🔴 THE SUPPRESSION RULE ITSELF IS CATEGORICAL AND LIVES ENTIRELY IN APEX: an email classified
 *   `call_for_offers` produces no Lead, unconditionally (ExtractAddressQueueable
 *   .isCallForOffersGated). `category_confidence` is NOT gated on. It is parsed and stored so it
 *   rides along in `Extracted_JSON__c` as TUNING DATA — the only evidence available if that
 *   suppression later proves too aggressive. An earlier draft gated on it behind a Custom Metadata
 *   threshold; that machinery was deleted, because the business rule needs no dial and a toggle
 *   that ships OFF is a feature that has never run.
 *
 *   WHAT THE SENTENCE IS STILL FOR, AND WHY IT STAYS: most of its text does not describe a
 *   confidence at all — it DEFINES THE CATEGORY'S BOUNDARY (a one-recipient offering, an
 *   off-market or exclusive introduction, or anything inviting a direct conversation is NOT
 *   call_for_offers). Now that the category ALONE decides whether a Lead exists, that boundary is
 *   the single highest-leverage sentence in this block: a model that over-applies
 *   `call_for_offers` silently suppresses real broker submissions. Sharpen this wording before
 *   reaching for a threshold.
 *
 *   🔴 U2 DEGRADES CORRECTLY BY CONSTRUCTION. A legacy-shape response (the one-line rollback
 *   lever) and an LLM degrade both carry NO `email_category` at all; the parser coerces that to
 *   'other', which the gate ignores. Reverting this block silently DISABLES the suppression rather
 *   than stranding it on — the safe direction.
 *
 *   U3 — the `broker_company` paragraph's opening is REPLACED (everything from
 *   `kevin.girard@jll.com gives "JLL"` onward, including the whole free-mail blocklist and the
 *   reviewer-mandated ISP hardening, is carried verbatim and unchanged). Three things changed
 *   and one of them is load-bearing:
 *     (a) FRAMING — the paragraph used to be headed "WHEN THE EMAIL DOES NOT NAME THE FIRM", so
 *         its own "use it exactly as written" sentence read as an exception to inference rather
 *         than as precedence. It is now "STATED ALWAYS BEATS INFERRED", with inference bounded
 *         by an explicit "ONLY if no firm is stated anywhere" clause. That clause is what
 *         confines the behaviour change to emails where a firm IS stated.
 *     (b) FOOTER — the letterhead / disclaimer / address-block / copyright line is now named
 *         explicitly, including on an attached flyer image. That is where blast platforms and
 *         free-mail-sending brokers put the firm, and it was the one place the old wording did
 *         not look. The winning shape is a footer-only firm on a free-mail domain: today that
 *         yields EMPTY -> COMPANY_PLACEHOLDER -> no Account match; now it yields the real firm.
 *     (c) 🔴 THE DIVISION-STRIP RULE NOW APPLIES TO STATED NAMES, NOT ONLY INFERRED ONES. This
 *         is the highest-value line in U3 and the reason (a) is safe. Lead.Company is an ACCOUNT
 *         MATCH KEY (LeadConvertMatchService.collectMatchKeys -> AccountSelector.selectByNames),
 *         and a FOOTER STATES THE DIVISION far more often than the clean firm — "JLL Capital
 *         Markets", "CBRE | Investment Properties", "Marcus & Millichap IPA". Making stated names
 *         win WITHOUT extending the strip rule would have fed division strings straight into
 *         Account matching and minted a second Account per division: U3 would have caused the
 *         exact fragmentation the S4 header names as load-bearing. Do not weaken it.
 *     A "several firms" clause resolves the blast-platform case (sender's firm wins; the other
 *     firm goes to deal_summary), which keeps broker_company tied to broker_email's owner.
 *
 * ⚠ BOTH EDITS TOUCH THIS BLOCK, SO UAT D AND D′ BELOW ARE MANDATORY RE-RUNS — they are declared
 * recurring checks after ANY edit here, not one-off sign-off. U3 additionally needs cases F
 * (footer-only firm on a free-mail domain) and F′ (a stated "JLL Capital Markets" must yield
 * "JLL"), which are the only way (c) can be verified at all.
 *
 * ═══ LIVE-RUN DEFECT FIXES, 2026-08-12 — THREE EDITS, ALL ENRICHED-BLOCK ONLY ═══
 * Six real emails were run through the live pipeline on `usman-dpeg` with real extraction (no
 * mocks). Three of the four defects found were PROMPT defects. LEGACY_EXTRACTION_RULES and
 * LEGACY_RESPONSE_FORMAT are untouched AGAIN, so protections 1 and 3 both stand, no fixture pin
 * in ExtractionRegressionFixtureTest is re-pinned, and MODEL / temperature / MAX_TOKENS /
 * MAX_INPUT_CHARS / the `extract(String,String,String)` signature are all unchanged — the §3.3
 * ASB re-homing promise is preserved. See agent-output/design-requirements-pipeline-defects.md.
 *
 *   EDIT 1 (CRITICAL) — call_for_offers NARROWED, in the CLASSIFICATION paragraph.
 *   🔴 THE MEASURED FAILURE IS A LOST CLAIM, NOT A MISLABELLED EMAIL. An ordinary offering
 *   memorandum from ONE named broker — property name, address, square feet, occupancy, guidance
 *   price, cap rate, plus the sentence "Offers due 30 September 2026" — was classified
 *   `call_for_offers` at `category_confidence` 1.0. `ExtractAddressQueueable.isCallForOffersGated`
 *   then suppressed it: no Lead and, the damage, NO REGISTRY CLAIM. A DIFFERENT broker sent the
 *   SAME property without a deadline line and won `8800 kirby oaks drive houston tx 77054`
 *   outright. Most brokered OMs state a bid deadline, so this is ORDINARY traffic, not a tail
 *   case — the population the old wording gated was far larger than "marketed campaigns DPEG does
 *   not work". The edit makes the category require a MASS-DISTRIBUTION SHAPE (no individual
 *   recipient, broadcast register, unsubscribe/mailing-list language, a platform notification),
 *   states outright that a stated offers-due date is neither sufficient nor evidence, gives
 *   positive AND negative exemplars with the measured email as the canonical NEGATIVE, and tells
 *   the model the asymmetric cost so borderline cases fall to acquisition_deal.
 *
 *   ⚠ THE OFFER DEADLINE AND THE CATEGORY ARE DELIBERATELY NOT COUPLED. A deadline sentence must
 *   still populate `offer_due_date` on the property block exactly as before — only what the
 *   CATEGORY MEANS changed. Nothing in the edit touches the `offer_due_date` rules, and a future
 *   edit that makes the deadline conditional on the category would break the call-for-offers
 *   stamp (`CallForOffersStampService`), which reads that field on a matched live deal.
 *
 *   🔴 RESIDUAL, ACCEPTED BY EXPLICIT USER DECISION AT GATE 1 — READ THIS BEFORE TRUSTING THE
 *   FIX. The design recommended pairing this narrowing with a DETERMINISTIC, transport-layer
 *   corroboration factor in Apex (recipient count, `Precedence: bulk`, `List-Unsubscribe:`, a
 *   platform sender domain) so that suppression required a second signal OF A DIFFERENT KIND
 *   from the model's own opinion. The user chose the prompt-only option. THE CONSEQUENCE IS
 *   THAT THIS FIX RESTS ENTIRELY ON MODEL JUDGEMENT WITH NO DETERMINISTIC BACKSTOP: the
 *   suppression is still one model opinion, so the SAME FAILURE CLASS CAN RECUR with different
 *   wording — an exclusive OM phrased like a campaign, a broker who writes "Dear Investor" out
 *   of habit — and when it does, the loss is again a permanently unclaimed property recoverable
 *   only by manual registry surgery. This is a known accepted residual, not an oversight. Two
 *   things follow: `Gated_Call_For_Offers` is an ACTIVE WATCH, not an archive; and the levers
 *   available if it recurs are (a) sharpening THIS wording again or (b) revisiting the
 *   deterministic factor — never `category_confidence`, which was 1.0 on the measured email and
 *   is therefore MEASURED-DEAD for this failure, whatever threshold were applied to it.
 *
 *   EDIT 2 — `confidence` CALIBRATED, in the same paragraph. MEASURED: an internal email ("Team
 *   lunch Friday + Q3 expense reports") returned `is_acquisition_related = false` — CORRECT — at
 *   `confidence` 0.0, so `LLMExtractionParser` banded it LOW and D2's hard gate, a CONJUNCTION of
 *   `false` AND HIGH band, did not fire. The model had to be both RIGHT and CONFIDENT to suppress
 *   anything, and it was only right. 🔴 THE FIX IS AT THE CAUSE, AND THE APEX FLOOR IS
 *   DELIBERATELY UNCHANGED: 0.0 is the value this very block SHOWS in its response template, so
 *   the most likely reading of the measurement is a model echoing the template default rather
 *   than a model that was genuinely unsure. The edit says the template value is a shape and never
 *   an answer, names the contradiction (0.0 beside a definite verdict), and requires 0.9+ for the
 *   plainly-not-real-estate classes. `ExtractAddressQueueable.isHardGated` is NOT touched: its
 *   asymmetry is deliberate and documented (generosity is the right bias for a first-come ledger,
 *   because claiming a junk address costs one deletable registry row while failing to claim a
 *   real one costs a broker their commission), and lowering the floor globally would start
 *   suppressing low-confidence REAL broker emails — re-creating EDIT 1's failure in a new place.
 *
 *   EDIT 3 — the PLATFORM-SENDER case added to BROKER vs LISTING BROKER. MEASURED: an email
 *   reading "Listing broker: Dana Whitfield, dana.whitfield@zzbrokergamma.com" returned Dana in
 *   `broker_name`/`broker_email` and left `listing_broker_*` EMPTY, so `CallForOffersStampService`
 *   correctly wrote nothing (its W1 rule: passing null preserves what the deal knows).
 *   🔴 THE PROHIBITION ALREADY EXISTED AND WAS DISOBEYED, SO RESTATING IT HARDER IS NOT THE FIX —
 *   and could not be, because the LEGACY block is declared AUTHORITATIVE for exactly those two
 *   keys and takes them from the outermost "From:" line. On that email the envelope sender was a
 *   PLATFORM (`listings@zzmarketplace.com`) and U1 stood down (`From_Address__c ==
 *   Forwarded_By__c`, the paste-forward guard), so nothing demoted Dana either. The edit answers
 *   the case the legacy rule is SILENT on — what to do when the outermost "From:" is a platform
 *   or role mailbox rather than a person — which is why it narrows nothing the legacy block
 *   claims and keeps the byte-pin honest.
 *
 *   ⚠ EDIT 3 IS AN ARBITRATION CHANGE. `broker_email` drives repeat detection and
 *   `Competing_Broker_Submission__c.Broker_Email__c`, so it changes WHO WINS a property.
 *   `property_address` is untouched by all three edits, so NO `Property_Key__c` moves and no
 *   existing registry row is re-keyed — the change is bounded to ATTRIBUTION, never to claim
 *   identity. Keep it that way.
 *
 * ═══ CODE-REVIEW FIXES TO THE ABOVE, 2026-08-12 — TWO MORE ENRICHED-BLOCK EDITS ═══
 * Review of the three edits found that EDIT 1's narrowing had over-shot and could reproduce the
 * inversion U2 exists to prevent. LEGACY_EXTRACTION_RULES and LEGACY_RESPONSE_FORMAT are untouched
 * yet again, so no fixture pin moves.
 *
 *   FIX A (BLOCKING) — EDIT 1's EXEMPLAR LISTS COLLIDED, AND EVERY COLLISION RESOLVED THE WRONG
 *   WAY. Two facts made the negative exemplar "a forwarded broker email whose original sender is a
 *   named person at a brokerage" useless as a discriminator: EVERY email reaching this pipeline is
 *   a forwarded broker email (broker -> DPEG's coordinator -> the email service, ARCHITECTURE
 *   INTAKE RULES V2 rule 1), and genuine marketed blasts are overwhelmingly sent BY a named person
 *   at a brokerage. A real JLL/CBRE blast with "Dear Investor" and an unsubscribe footer therefore
 *   satisfied the NEGATIVE list and the POSITIVE list at once, and both tie-breaks ("WHEN IN DOUBT
 *   IT IS NOT call_for_offers", "Bias every borderline judgement toward acquisition_deal") sent it
 *   to acquisition_deal. 🔴 THAT IS NOT A MISLABEL — it routes to branch (e) WINNER and TAKES A
 *   `Property_Registry__c` CLAIM ON A BLAST, which is the precise inversion `isCallForOffersGated`
 *   documents: the first blast becomes the winner and a later broker holding a genuine exclusive
 *   routes to branch (d) with no Lead. The fix adds an explicit PRECEDENCE paragraph — the
 *   mass-send signals DECIDE, and being sent by a named person at a brokerage NEVER overrides them
 *   — and carves the same UNLESS into the exemplar itself. Doubt about whether the SIGNALS are
 *   present still resolves to acquisition_deal, so EDIT 1's measured fix is preserved: the
 *   precedence bites only where the signals are affirmatively on the email's face.
 *
 *   FIX B — THE COST MODEL EDIT 1 TAUGHT WAS FACTUALLY WRONG. It ended "a wrong acquisition_deal
 *   costs nothing but a record a human can review". It costs a REGISTRY CLAIM ON A BLAST. That
 *   sentence is the model's fallback for every borderline case, so a false statement there outranks
 *   the rules above it. 🔴 THE BIAS TOWARD acquisition_deal IS KEPT — it is still correct, but for
 *   the honest reason rather than the false one: a wrong call_for_offers is a CERTAIN loss the
 *   instant it is made, while a wrong acquisition_deal is a CONTINGENT one that only becomes a loss
 *   if a second broker submits the same property, and it leaves a record a human can find. The
 *   CLAIM was corrected, not the DIRECTION.
 *
 *   FIX C — `broker_company` POOLING, closing a defect EDIT 3 opened. EDIT 3 sends a platform or
 *   role-mailbox sender into `broker_name`/`broker_email`, but `broker_company` was defined as "the
 *   firm of the person identified by broker_email" and its "several firms" clause then made the
 *   SENDING PLATFORM'S firm win. That reaches `Lead.Company` -> `AccountSelector.selectByNames` and
 *   pools every platform-sourced deal under one Account; and it arrives a SECOND time by another
 *   route, because `broker_email` -> `Lead.Email` -> `LeadConvertMatchService` matches Contacts on
 *   EMAIL ALONE and the matched Contact then dictates the Account. The fix mirrors the existing
 *   free-mail rule's exact shape: when `broker_email` is a listing platform, marketplace, CRM or
 *   marketing system, or a role mailbox, `broker_company` is EMPTY and the firms named go to
 *   `deal_summary`. Empty yields COMPANY_PLACEHOLDER, which D1b deliberately excludes from Account
 *   matching — the safe direction.
 *
 * ⚠ UAT D AND D′ ARE MANDATORY RE-RUNS FOR THIS CHANGE SET TOO (they are declared recurring after
 * ANY edit to this block). Add: an OM with a bid deadline from a named broker must come back
 * `acquisition_deal`; a genuine marketplace blast must still come back `call_for_offers`; the
 * platform-sender email must return the platform in `broker_*` and Dana in `listing_broker_*`;
 * and an internal non-property email must return `false` at 0.9+. FIX A ADDS THE CASE THAT
 * DISCRIMINATES IT AT ALL — a blast SENT BY A NAMED BROKER AT A REAL FIRM ("Dear Investor", an
 * unsubscribe footer, polished flyer attached) must come back `call_for_offers`, while the SAME
 * broker's one-recipient OM with a bid deadline must still come back `acquisition_deal`; run both
 * or neither, because either alone can be satisfied by a model that ignores the distinction. FIX C
 * adds: the platform-sender email must return `broker_company` EMPTY (not "ZZ Marketplace"), with
 * the platform and any listing brokerage named in `deal_summary`. NONE OF THESE IS UNIT-TESTABLE
 * — the model is mocked in Apex tests, so a green suite says nothing about any of them. The free
 * corpus is the org itself: `Inbound_Email_Staging__c` retains `Raw_Body__c` and
 * `Extracted_JSON__c` for every email ever processed and rows are never deleted, so re-running
 * the new prompt over a sample and asserting the SAME `broker_email` and the SAME
 * `PropertyMatchingService.normalizeAddress(property_address)` — the same normalized key, not a
 * similar one — is the only real regression check available.
 *
 * ═══ ACQUISITION OBSERVATIONS PACK, PHASE 1 — 2026-08-14. TWO ENRICHED-BLOCK EDITS ═══
 * LEGACY_EXTRACTION_RULES and LEGACY_RESPONSE_FORMAT are untouched AGAIN, so no fixture pin
 * moves and the one-line rollback lever still composes back verbatim
 * (ExtractionRegressionFixtureTest). Neither edit touches broker_name, broker_email,
 * property_address or sent_datetime, so NO claim is re-keyed and NO attribution moves.
 *
 *   EDIT 1 — NEW KEY `listing_status` (spec §2.3). A per-property closed-set value,
 *   On Market / Off Market, landing on Lead.Listing_Status__c and carried to the Opportunity
 *   at conversion. Three things about it are deliberate and are stated in the prompt itself:
 *   it DEFAULTS TO null and the model is told in terms not to guess; it must NOT be inferred
 *   from `sale_process`, from an offer deadline or from a deal-room link (those correlate and
 *   are not the same fact); and LLMExtractionParser describe-validates it against the live
 *   RESTRICTED picklist, so an off-list answer becomes null plus a Deal_Notes__c note rather
 *   than an INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST that would roll back a committed claim.
 *   A legacy-shape response carries no such key and therefore parses to blank — the prompt
 *   rollback degrades this feature to manual entry rather than stranding it.
 *
 *   EDIT 2 — `deal_type must be one of: Land, Retail.` (was `Land, Commercial`). 🔴 THIS IS
 *   THE PROMPT'S ONLY LIVE-BEHAVIOUR REPOINT IN THE Commercial -> Retail MIGRATION and it is
 *   requirements §9 C13: the line instructs the model WHICH VALUE TO EMIT, so it is behaviour,
 *   not documentation, and it belongs in the D3 repoint wave. It is SAFE to land at D3 while
 *   `Commercial` is still active because the parser validates against the live picklist and
 *   both values validate between D1 and D4; what is NOT safe is leaving it, because after D4
 *   the model would be instructed to emit a deleted value and the guard drops it SILENTLY.
 *
 * ⚠ THE `listing_status` KEY IS NOT UNIT-TESTABLE END TO END — the model is mocked in every
 * Apex test, so a green suite says nothing about whether it is populated correctly. Add it to
 * the recurring UAT D / D′ list: an OM that says "off-market opportunity" must come back
 * `Off Market`; a marketplace listing page must come back `On Market`; and — the case that
 * actually discriminates — an ordinary OM that says NEITHER, but does carry a bid deadline and
 * a deal-room link, must come back null. The third alone is worth more than the first two,
 * because inferring from those two signals is exactly the failure the rule forbids.
 *
 * ⚠ THE REQUEST BODY IS NO LONGER CONSTANT ACROSS CALLOUTS. buildRequestBody now injects a
 * dynamic REFERENCE DATE line (yyyy-MM-dd, GMT, evaluated per callout) between the
 * instruction and the email text — see referenceDateLine() for the hazard it carries and
 * the guard sentence that contains it. No signature, caller, parser, model, temperature,
 * token or cap change accompanies it.
 *
 * ═══ WS7 PER-FIELD CONFIDENCE — 2026-08-30. ONE ENRICHED-BLOCK EDIT, +1,338 CHARACTERS ═══
 * A new response key, `field_confidence`: an object mapping each key the model returned a value
 * for to a 0–1 score for THAT VALUE. It becomes Lead.Field_Confidence_JSON__c, and the count of
 * its entries below the WS5 medium threshold becomes Lead.Low_Confidence_Field_Count__c, which
 * drives one Review Queue list-view filter. LEGACY_EXTRACTION_RULES and LEGACY_RESPONSE_FORMAT
 * are untouched AGAIN; the edit is one new paragraph immediately above the response template plus
 * `"field_confidence": {}` inside it.
 *
 * 🔴 THE THREE CONFIDENCE KEYS NOW IN THE SCHEMA ANSWER THREE DIFFERENT QUESTIONS AND MUST NOT
 * BE COLLAPSED. `confidence` → is_acquisition_related (and it alone feeds the >= 0.85 hard
 * suppression gate). `category_confidence` → email_category (parsed, gated on by nothing, per its
 * own field's Javadoc). `field_confidence` → "did I read this value correctly", per value. The
 * prompt paragraph says so explicitly because a model shown three confidence numbers will
 * otherwise return one number three times, and a `field_confidence` that merely echoes
 * `confidence` would produce a review queue that never disagrees with the band beside it.
 *
 * ⚠ NEITHER UNIT-TESTABLE NOR REGRESSION-GUARDED, and both halves of that matter. The model is
 * mocked in every Apex test, so a green suite proves the PARSER handles the key and proves
 * nothing about whether the model returns it or scores it sensibly. And WS5 removed the prompt's
 * only automated backstop (ExtractionRegressionFixtureTest section 2) hours before this edit — so
 * the mitigation named there is the ONLY one that applies here: run the two manual fixtures
 * before and after, and diff `broker_email` and
 * `PropertyMatchingService.normalizeAddress(property_address)` BY HAND. This edit adds a key and
 * touches none of the four legacy values, so no claim should be re-keyed — "should" is the
 * accurate word, because changing a response schema changes model behaviour everywhere in it,
 * and that is precisely the risk the user accepted when the guard was retired.
 *
 * ⚠ ADD TO THE RECURRING UAT LIST: an email that states its NOI outright and merely IMPLIES the
 * year built must come back with `noi` scored 0.9+ and `year_built` below 0.60 — one email, both
 * directions, because a model that returns a flat 0.9 for everything satisfies either half alone.
 *
 * ═══ SCHEMA-KEY DEFINITION PASS — 2026-08-31. ONE ENRICHED-BLOCK EDIT, NINE KEYS DEFINED ═══
 * Nine response-schema keys were **template-only**: they appeared in the JSON response shape and
 * NOWHERE ELSE, so the model was shown a slot and never told what belongs in it —
 * `building_sf`, `broker_phone`, `broker_mobile`, `broker_title`, `walt_years`, `adr`, `zoning`,
 * `seller_entity`, `deal_room_link`. Each now has one definition bullet in the
 * ANTI-HALLUCINATION list, in the register of the peers that already worked (`unit_count` is
 * defined, `cap_rate`/`occupancy_pct` carry a units rule, `year_built` carries a worked example).
 * `building_sf` was additionally added to the PER-FIELD CONFIDENCE exemplar key list.
 * LEGACY_EXTRACTION_RULES and LEGACY_RESPONSE_FORMAT are untouched AGAIN, and so are the INPUT
 * SHAPE, BROKER vs LISTING BROKER, `broker_company`, `sent_datetime`, the response template and
 * the picklist-value lines — EIGHT regions, each verified byte-identical to HEAD by its own
 * per-paragraph hash (region name / HEAD md5 / working md5 / verdict), not by assertion and not
 * by a whole-file diff. ⚠ THE ENUMERATION AND THE COUNT ARE THE AUDIT RECORD OF WHAT WAS
 * ACTUALLY HASHED — if you add a region, add it to both, and if they disagree trust neither.
 *
 * 🔴 THE NARROWING EDITS — THERE ARE THREE, NOT ONE, AND EACH CARRIES ITS OWN RISK STATEMENT.
 * Everything else in this pass is purely additive; these three can SUPPRESS a value the previous
 * prompt would have emitted, which is why they are enumerated rather than described in aggregate.
 * A fourth suppressing change — the `broker_phone`/`broker_mobile` role-mailbox carve-out — is
 * recorded separately below under the taken review suggestions; it is not repeated here.
 *
 * (1) `lot_size` — THE ONLY ONE THAT IS ALSO A RE-ROUTE. The `lot_size` bullet previously read
 * "lot_size_sf ONLY if it states square feet" — the ONLY rule in the whole prompt that fired on
 * the bare phrase "square feet", and its trailing "Never fill both from a single figure" then
 * forbade `building_sf` outright. It is now scoped to the LAND or SITE area. This NARROWS
 * `lot_size_sf` and can widen nothing: it cannot cause a value to be invented, only stop a
 * BUILDING figure being captured as LAND. That mis-route matters because there is no
 * `Lot_Size_SF__c` — LLMExtractionParser converts `lot_size_sf` to acres and EmailToLeadService
 * writes it to `Lot_Size_Acres__c`, so a mis-routed building area would have become a FABRICATED
 * lot size that looks like a successful extraction. ⚠ MEASURED 2026-08-31: `lot_size_sf` is
 * populated on 0 of 4 property objects — it has not fired anywhere in the SURVIVING corpus. This
 * narrowing is therefore PROPHYLACTIC: there is no bad data to remediate and no corpus sweep is
 * owed. 🔴 BOUND THAT CLAIM BEFORE RELYING ON IT — THREE LIMITATIONS, STATED SO NOBODY READS IT
 * AS STRONGER THAN IT IS:
 *   1. N = 4 property objects across 6 staging rows. `Inbound_Email_Staging__c` rows are never
 *      deleted BY THE PIPELINE, but most of this org's history was removed in an unrelated
 *      clean-slate wipe earlier on 2026-08-31, so "the whole corpus" means the POST-WIPE
 *      remainder, not the project's history.
 *   2. The method was string matching over the whole `Extracted_JSON__c`, so a key appearing only
 *      in `field_confidence` counts as "present" even when `properties[0]` lacks it. It
 *      over-reports presence and therefore UNDER-reports the defect.
 *   3. Two of the three populated `building_sf` values are the same number (96400, 96400) — about
 *      2-3 distinct emails, not 3 independent observations.
 * None of the three overturns the conclusion (0 of 4 is still 0), but all three cap how much
 * weight it can carry. Re-measure before treating any of this as a rate.
 *
 * (2) `seller_entity` — "A description rather than a name … is not a seller entity; leave it
 * empty." This SUPPRESSES a value: an email whose only ownership language is descriptive
 * ("the seller is a private family office") previously had nothing stopping the model putting
 * that phrase in `seller_entity`, and it reaches a stored field — EmailToLeadService writes it
 * to `Lead.Seller_Entity__c`, which LeadConvertService carries onward. The narrowing is right
 * (a description is not a legal entity, and a Lead field named for one should not hold prose)
 * but it is a behaviour change, not a clarification, and it is named here so nobody discovers
 * that by finding the field newly blank.
 *   ⚠ MEASURED 2026-08-31, `usman-dpeg`, all 6 `Inbound_Email_Staging__c` rows: `seller_entity`
 *   is emitted as "" on every row that emits the key at all (IES-0000065/66/67) and is absent
 *   from the rest, and NO Lead in the org carries a non-null `Seller_Entity__c`. So this
 *   narrowing is PROPHYLACTIC in the surviving corpus — it empties nothing today. 🔴 A prior
 *   draft of this note asserted it would empty IES-0000067's live value; that was WRONG and the
 *   query above is why. Do not restore that claim without re-running it — the corpus is the
 *   POST-WIPE remainder and the same three limitations stated under (1) apply here unchanged.
 *
 * (3) `walt_years` — "If the email states it in months, return null rather than converting."
 * Also suppressing, and also reaching a stored field (`Lead.WALT_Years__c`). Returning null
 * is deliberate: the key is named `_years`, so a months figure passed through unconverted would
 * be wrong by 12x in a field nothing downstream re-checks, and "NEVER derive one number from
 * another" forbids the conversion that would fix it. Losing the fact is the lesser harm.
 *   ⚠ MEASURED 2026-08-31, same 6 rows: exactly one row emits a `walt_years` value — IES-0000065,
 *   6.5 — and that email states "6.5 years of weighted average lease term", i.e. in YEARS. The
 *   months clause therefore suppresses nothing in the surviving corpus either. It is a guard
 *   against an input shape not yet observed, not a change to observed behaviour.
 *
 * 🔴 THE ACCEPTANCE ASSERTION FOR THIS CHANGE IS NOT "Lot_Size_Acres__c IS NULL". IT WAS, IN THE
 * DESIGN DOC, AND IT IS WRONG — DO NOT EXECUTE IT. `agent-output/design-requirements.md` states
 * at §6 V4.3, §10 step 13 and §13 devops step 10 that the acceptance email must yield a NULL
 * `Lot_Size_Acres__c`, on the premise that it "states no site area". IT STATES ONE:
 * IES-0000068's body reads "The hotel sits on 4.6 acres". The model dropped `lot_size_acres` by
 * the same key-omission that dropped `building_sf` — which is why the field is null TODAY and why
 * null looks like the right answer.
 *   ✅ EXPECT `Lot_Size_Acres__c` = 4.6 after this change. That is the fix WORKING, not failing.
 *   🔴 THE MIS-ROUTE SIGNATURE IS `Lot_Size_Acres__c` ≈ 2.58 — 112,400 sq ft pushed through
 *      LLMExtractionParser's sq-ft-to-acres conversion (112400 / 43560 = 2.5803). THAT is the
 *      value that means Part A failed. 4.6 means it worked; 2.58 means roll back.
 * Executing the design doc's assertion literally would roll back a correct fix at gate G4 or loop
 * forever at G5. The design doc has been corrected at all three sites in the same change.
 *
 * ⚠ THE CAUSE IS NOT "TEMPLATE-ONLY KEYS ARE NEVER EMITTED" — MEASURED, AND WEAKER THAN THAT.
 * Same corpus, same prompt: `building_sf` was populated on 3 of 4 property objects (96400, 96400,
 * 61200). It failed on exactly one row, IES-0000068, where the model returned a property object
 * carrying only 14 of the template's 24 keys and dropped every key it had no labelled fact-list
 * line for — including `lot_size_acres` ("sits on 4.6 acres") and `year_renovated` ("renovation
 * completed in 2023"), BOTH OF WHICH WERE ALREADY RULE-BEARING. So a definition is not sufficient
 * on its own, and nobody should read this entry as proof that it is. What the definitions do buy
 * is a stated meaning, a stated unit, and — for `building_sf` — the removal of a contradicting
 * instruction and an explicit "prose counts as stated", which is the exact shape of the observed
 * miss (that email's 112,400 SF reached only the `deal_summary` narrative).
 *
 * 🔴 EVERY WORKED EXAMPLE IN THE NEW BULLETS USES INVENTED VALUES THAT APPEAR IN NO LIVE EMAIL,
 * AND THAT IS A CORRECTNESS PROPERTY, NOT HOUSE STYLE. The first draft of this pass wrote the
 * `building_sf` example as "112,400 square feet of building on a 4.6-acre site" — the exact two
 * figures in IES-0000068, the email the acceptance run re-sends. That would have destroyed the
 * only real proof this change has: the model is mocked in every Apex test, so a live extraction
 * is the sole evidence, and an exemplar the model can copy makes "it read the email" and "it
 * copied the prompt" indistinguishable. It is also a production leakage vector in both
 * directions — a concrete number in the prompt can come back for an email that states none, the
 * parser accepts it under MAX_COUNT, EmailToLeadService stamps it, nothing logs it, and
 * `building_sf` is outside SCORED_KEYS so `Extraction_Score_Pct__c` does not move either.
 * FOUR MORE LEAKS WERE FOUND BY THE SAME CHECK AND FIXED: `walt_years` "6.5" (IES-0000065/67),
 * `adr` "148" (IES-0000068's unit_count — a CROSS-KEY leak, worse than a same-key one),
 * `seller_entity` "a local physician partnership" (IES-0000067 verbatim), and `broker_title`
 * "Senior Director, Hospitality Investment Sales" (IES-0000068's signature verbatim).
 * ✅ VERIFIED, AND THE METHOD MATTERS AS MUCH AS THE RESULT — COPY THE METHOD, NOT JUST THE
 * VERDICT. The leakage vector is the BARE EMITTED VALUE, not the phrase it sits in: the parser
 * receives 205, never "ADR $205", so searching for the phrase can pass while the value leaks.
 * That is exactly the shape of the `adr` "148" CROSS-KEY leak found above. The corpus also
 * stores building areas UN-SEPARATED (96400, 61200), so a comma-formatted-only search for
 * "84,500" would have been vacuous. And the model is fed the SUBJECT LINE concatenated ahead of
 * the body (see the composition at the ExtractAddressQueueable call site), with INPUT SHAPE
 * declaring the subject readable for property_name, property_address,
 * unit_count, offer_due_date, asset_type and sale_process — so the body alone is not the corpus.
 * THE CHECK IS THEREFORE: match each exemplar in BOTH its prompt-formatted form AND its bare
 * emitted form ("84,500" and 84500; "ADR $205" and 205), against `Subject__c` CONCATENATED WITH
 * `Raw_Body__c`, across every `Inbound_Email_Staging__c` row, and require zero hits.
 *   ⚠ MEASURED 2026-08-31, `usman-dpeg`, all 6 staging rows, subject+body, bare values: 84500 /
 *   84,500 / 3.7 / 8.3 / 205 / C-2 / PD-14 / "Land SF" / "Lot SF" / "Site SF" / "a family
 *   partnership" / "Managing Director, Capital Markets" — ZERO HITS, each one individually.
 *   🔴 THE ACRE EXEMPLAR WAS 2.1 AND HAD TO BE CHANGED TO 3.7: 2.1 HIT IES-0000068, the
 *   acceptance email, inside "a $2.1M soft-goods renovation". Different unit and different
 *   context, so the copy risk was low — but IES-0000068's expected `lot_size_acres` is 4.6, and a
 *   returned 2.1 would have been indistinguishable between "copied the prompt" and "misread the
 *   $2.1M". Removing that ambiguity cost one token. 5.3, 7.4 and 9.2 also measured clean if a
 *   future edit needs another.
 *   ⚠ FOUR STRINGS IN THESE BULLETS ARE DELIBERATELY EXCLUDED FROM THE SWEEP, NOT MISSED —
 *   "Building Size", "Net rentable area", "GLA" and "meeting, workspace or storefront area".
 *   They are LABEL and CATEGORY strings telling the model what to recognise; they are not values
 *   a model can copy into a numeric or text slot, so a hit on them would be expected and
 *   harmless. Stated explicitly because a ✅ VERIFIED list reads as exhaustive otherwise.
 * ⚠ RE-RUN THAT CHECK BEFORE ADDING ANY WORKED EXAMPLE TO THIS PROMPT, and re-run it against the
 * corpus AS IT IS THEN — a clean value today is not clean after new mail arrives. The house style
 * elsewhere already does this by instinct ("Orion ParkView, 1400 Royal Lane", "88/22"); this
 * pass is the first that had to be told.
 *
 * ⚠ THREE REVIEW SUGGESTIONS WERE TAKEN, AND ALL THREE CHANGE MODEL BEHAVIOUR — RECORDED, NOT
 * SILENT.
 *   W5 — `broker_phone`/`broker_mobile` now carry the SAME role-mailbox carve-out that
 *   `broker_company` and `broker_title` already had. Without it the bullet actively instructed
 *   the mis-attribution: "if only one number is given and it is not labelled, put it in
 *   broker_phone". On a marketplace blast where broker_email is listings@<platform> and the only
 *   number is the LISTING broker's direct line, `Lead.Phone` would carry a named human's number
 *   under a no-reply address and somebody would call it believing it was the submitting broker.
 *   S2 — the same `broker_phone`/`broker_mobile` carve-out now ROUTES the discarded number to
 *   `deal_summary` instead of dropping it. W5 alone made the two carve-outs asymmetric:
 *   `broker_company` already sent its refused value onward ("put the platform's own name,
 *   together with any listing brokerage the email names, in deal_summary"), while the phone
 *   one silently destroyed it. There is no `listing_broker_phone` key and none is being added,
 *   so on a marketplace blast the listing broker's only phone number was unrecoverable from
 *   Salesforce entirely — the email body is retained on `Inbound_Email_Staging__c`, but nothing
 *   a user works from surfaces it. This is a behaviour change and it is deliberately a NARROW
 *   one: the number lands in a free-text narrative field, never in a typed field, so it cannot
 *   re-create the mis-attribution W5 exists to prevent. `Lead.Phone` still comes only from
 *   `broker_phone`, which stays empty for a role mailbox.
 *   W6 — the bare label "SF" is now qualified to "when it labels the improvements", and
 *   "Land SF" / "Lot SF" / "Site SF" are named explicitly as `lot_size_sf`. An unqualified "SF"
 *   made `building_sf` the nearest match for "Lot Size: 43,560 SF" — the MIRROR IMAGE of the
 *   defect this pass exists to fix. The asymmetry that caused the original bug (a positive
 *   example for one side, no negative for the other) is now closed on both sides.
 *
 * ⚠ NEITHER UNIT-TESTABLE NOR REGRESSION-GUARDED, exactly as WS7 records above. The model is
 * mocked in every Apex test. The ONLY mitigations are the manual ones: run UAT D and D′ before
 * and after and diff `broker_email` and
 * `PropertyMatchingService.normalizeAddress(property_address)` BY HAND, and re-run the two
 * standing classification checks (an OM with a bid deadline from a named broker must still be
 * `acquisition_deal`; a genuine marketplace blast must still be `call_for_offers`). This edit
 * touches none of the four legacy values, so no claim SHOULD be re-keyed — "should" is the
 * accurate word for the same reason WS7 gives.
 *
 * 🔴 AND THE APEX DEPLOY ALONE CHANGES NOTHING AT RUNTIME. `resolvePrompt()` prefers the
 * `Broker_Protection_Config__mdt.Default.Extraction_Prompt__c` record, which currently holds a
 * copy of the PRE-edit prompt. `scripts/load-broker-protection-config.apex` MUST be re-run after
 * this class is deployed, and it is ASYNCHRONOUS — poll until
 * `BrokerProtectionConfig.extractionPromptOverride().length()` changes before concluding the edit
 * failed. Full ordered protocol, including the anti-vacuity control probe that must be taken
 * BETWEEN the deploy and the loader run: agent-output/design-requirements.md §6 V3 and §10.
 *
 * ⚠ TWO NEW LINES NAME `broker_email`, AND THAT IS ANCHORING, NOT RE-DEFINITION — CHECKED.
 * The broker_phone/broker_mobile and broker_title bullets both read "…of broker_email's owner".
 * They consume `broker_email` as an already-decided value in order to say WHOSE phone and WHOSE
 * title to take; they state no rule about which line `broker_email` is read from, add no source,
 * remove no source, and change no precedence. Every such rule still lives exclusively in
 * LEGACY_EXTRACTION_RULES ("the OUTERMOST / EARLIEST From: line"), the INPUT SHAPE paragraph
 * ("THE SUBJECT LINE IS NEVER A SOURCE FOR broker_name, broker_email OR sent_datetime") and the
 * BROKER vs LISTING BROKER paragraph — all three verified byte-identical to HEAD. This is the
 * same anchoring `broker_company` has always used ("the firm of the person identified by
 * broker_email"), which is the established pattern here precisely because it makes a new field
 * DEPEND on the arbitration value instead of competing with it. 🔴 The failure mode to watch for
 * in any future edit is the opposite shape — a new bullet that offers `broker_email` a NEW place
 * to be read from, or that lets another field's evidence override it. Neither line does that.
 *
 * ⚠ `building_sf` IS DELIBERATELY NOT IN `ExtractionScoreUtil.SCORED_KEYS` and must not be added
 * because this edit made it extract better. The nine-key denominator was signed off 2026-08-14
 * and `building_sf` was cut on purpose: a land deal has no building area, so scoring it would
 * report a complete extraction as a poor one.
 *
 * ═══ ACCEPTANCE-RUN FIXES TO THE ABOVE — 2026-08-31. TWO ENRICHED-BLOCK BULLETS ═══
 * The nine-key pass above was deployed and confirmed on three live emails (Email A hit the
 * three-way criterion exactly — `Building_SF__c` 112400 and `Lot_Size_Acres__c` 4.6, the PASS
 * value, not the 2.58 mis-route; Email B populated SIX of six newly-ruled keys on a different
 * broker and asset class, which is what validates the rule-bearing-vs-template-only diagnosis
 * rather than a mention-count theory; Email C confirmed the role-mailbox carve-out fires). The
 * SAME RUN surfaced two further defects, fixed here. LEGACY_EXTRACTION_RULES and
 * LEGACY_RESPONSE_FORMAT are untouched AGAIN, and so are INPUT SHAPE, BROKER vs LISTING BROKER,
 * `broker_company`, `sent_datetime`, the response template, the blanket closed-set line and the
 * four picklist-value lines — NINE regions, each verified byte-identical to the pre-edit working
 * copy by its own per-region hash, not by a whole-file diff (the tree is shared with a
 * concurrent session, so a diff cannot distinguish "unchanged" from "not shown").
 *
 *   FIX 2 — `deal_type` NOW HAS A RULE, WRITTEN AS DEFAULT-TO-RETAIL. 🔴 MEASURED ACROSS FOUR
 *   LIVE EXTRACTIONS: `Retail` for both hotels, NULL for the medical office and NULL for the
 *   industrial deal. Null is not cosmetic — and 🔴 THE CONVERSION LAYER HAS SINCE MOVED, SO READ
 *   THE NEXT SENTENCE IN THE PAST TENSE. `LeadConvertService` USED TO guard its record-type
 *   lookup with `if (String.isNotBlank(l.Deal_Type__c))`, which is how Opportunity
 *   006iw000000fgpiAAA ("Marrowbrook Station Medical Plaza") came to be live with
 *   `RecordTypeId = null`: no Path, and no record-type picklist backstop. That Opportunity is
 *   real and is STILL untyped — the default below is not retroactive.
 *   🔴 AS OF 2026-08-31 THAT WRAPPER NO LONGER EXISTS. `LeadConvertService` now DEFAULTS a blank
 *   Deal Type at conversion (`DEFAULT_DEAL_TYPE`, describe-guarded) instead of skipping the
 *   lookup, so a blank Lead yields a Retail-typed Opportunity rather than an untyped one. DO NOT
 *   GO HUNTING FOR A `String.isNotBlank` GUARD IN THAT CLASS AND DO NOT CONCLUDE THE CONVERSION
 *   LAYER IS UNPROTECTED WHEN YOU FAIL TO FIND ONE — its absence is the fix, not a regression to
 *   restore. This prompt-side fix is UPSTREAM of that default and does not replace it: it makes
 *   the LEAD state a deal type in the first place, so the default is reached rarely rather than
 *   on the normal path.
 *   🔴 IT IS WRITTEN AS A DEFAULT, NOT AS A TWO-WAY CHOICE, AND THAT FRAMING IS THE FIX. A
 *   Land/Retail-agnostic asset class (medical office, industrial, hospitality) is the NORMAL
 *   case here, not the edge case, so "choose Land or Retail" reproduces the null. The bullet
 *   therefore says RETURN Retail FOR EVERYTHING ELSE and names the normal case explicitly.
 *   🔴 `Deal_Type__c` IS A RECORD-TYPE SELECTOR, NOT A PROPERTY CATEGORY. It is a two-value
 *   picklist whose only job is choosing the Opportunity record type, and it shares the token
 *   `Retail` with `Asset_Type__c` while meaning something entirely different: `deal_type =
 *   Retail` on a HOTEL is CORRECT. The bullet says so in terms ("Retail here means 'not raw
 *   land'; it does NOT mean the property is a shop, and deal_type must NEVER be made to agree
 *   with asset_type") because the one failure mode worse than the null is a model that starts
 *   aligning the two fields.
 *   ⚠ THE ENUM LINE AND EVERY PICKLIST VALUE LIST ARE UNTOUCHED — a definition was ADDED, a
 *   constraint was not edited. Those lines are hardcoded and drift there loses properties with
 *   no exception and no log (see the D3 repoint comment at the `deal_type` enum line).
 *   ⚠ NO WORKED EXAMPLE WAS ADDED TO THIS BULLET, so no exemplar-leak sweep is owed for it. The
 *   only concrete strings it carries are CATEGORY nouns ("a hotel, a clinic, a warehouse") which
 *   name what a property IS; they are not values a model can copy into a closed two-value slot.
 *   The 84,500 SF / 3.7-acre example above is undisturbed and its sweep still stands.
 *   ⚠ `LeadConvertService` IS NOT CHANGED HERE — it is owned by a concurrent session, and as of
 *   2026-08-31 it DEFAULTS a blank Deal Type at conversion (see the past-tense correction above;
 *   the null-tolerant skip it used to perform is gone). This fix reduces how often that default
 *   is reached; it does not replace it.
 *
 *   FIX 3 (PROMPT HALF) — `listing_broker_email` MUST BE AN ADDRESS WRITTEN IN THE EMAIL.
 *   🔴 MEASURED: Lead 00Qiw000000wuY7EAI carries `Listing_Broker_Email__c =
 *   info@nordhavencommercial.com` while the email's actual sender is
 *   `listings@crexi-listings.example.com` — a different domain — and the body contains NO `@`
 *   CHARACTER AT ALL. The model invented a plausible address from the firm name in the
 *   signature. `broker_email` is fabricated the same way but is overwritten by
 *   `applySenderFirstBrokerIdentity` with the envelope sender; the LISTING pair had no
 *   equivalent backstop. This is the "somebody contacts the wrong person" failure the
 *   `broker_phone` role-mailbox carve-out exists to prevent, displaced one field across and
 *   worse, because a plausible address invites use.
 *   🔴 THE PROMPT BULLET IS THE WEAKER HALF AND IS NOT THE CONTROL. A code-side guard —
 *   `ExtractAddressQueueable.dropUngroundedListingBrokerEmail` — ships in the same change and
 *   drops the value when it appears nowhere in `Subject__c` + `Raw_Body__c`. BOTH were taken,
 *   deliberately: this bullet reduces the rate, the guard makes the outcome deterministic. The
 *   reasoning is that the model has ALREADY been measured disobeying this instruction's subject
 *   matter, and that a prompt rule is not unit-testable in this repo AT ALL (see the two
 *   NEITHER-UNIT-TESTABLE notes above) while a text-presence guard is — and is tested, with a
 *   fabricated-address fixture and a grounded negative control.
 *   ⚠ IT NAMES `broker_email` NOWHERE AND NARROWS NOTHING IT OWNS. The bullet closes with the
 *   established deferral sentence ("it does not change how broker_name, broker_email,
 *   property_address or sent_datetime are determined"), and the guard is scoped to the LISTING
 *   pair only — `broker_email` is half the `Property_Registry__c` claim key and is deliberately
 *   left to its existing envelope backstop.
 *   ⚠ `listing_broker_name` IS NOT GUARDED, on measured grounds: on the same defective
 *   extraction "Yvette Marchetti" was correctly DEMOTED rather than promoted or invented, so the
 *   name path behaved. A literal-substring guard on a name would also drop legitimate
 *   re-spacings ("Y. Marchetti", "Yvette Marchetti, CCIM"), which an exact-token address cannot
 *   suffer from.
 *
 * ⚠ THE STRUCTURAL GUARD ON THIS BLOCK WAS STRENGTHENED IN THE SAME CHANGE.
 * `LLMExtractionCalloutServiceTest.everyResponseTemplateKey_isRuleBearingElsewhereInThePrompt`
 * used to assert each response-template key was MENTIONED elsewhere; `deal_type` PASSED that
 * while being effectively template-only, because a blanket "MUST be one of the listed values"
 * line and an enum line are mentions that define nothing. It now EXCLUDES the template, the
 * blanket line and the enum lines and requires a mention in the remainder. A mention COUNT was
 * considered and rejected as wrong in both directions — measured, five healthy keys carry two
 * mentions while the broken `deal_type` carried three.
 *
 * @see LLMExtractionParser.cls (turns the response into typed values; never throws)
 * @see LLMExtractionResult.cls / PropertyExtraction.cls (the return types)
 * @see ExtractAddressQueueable.cls (the only caller; owns the degrade path)
 * @see .claude/skills/sf-integration (callout-patterns, named-credentials-guide)
 * @see force-app/main/default/namedCredentials/OpenAI_API.namedCredential-meta.xml
 * @see force-app/main/default/externalCredentials/OpenAI_Credential.externalCredential-meta.xml
 */
public with sharing class LLMExtractionCalloutService {

    /** Named-Credential-backed chat-completions endpoint. Only this line changes when
     *  the callout is later re-homed onto an ASB LLM-extraction spoke. */
    private static final String ENDPOINT = 'callout:OpenAI_API/v1/chat/completions';

    /**
     * Vision-capable, low-cost model used for the extraction. UNCHANGED by the enrichment
     * on purpose — see protection 2 in the class header.
     *
     * ⚠ SINCE WS5 (2026-08-30) THIS IS THE FALLBACK, NOT THE LIVE VALUE. The live value
     * is BrokerProtectionConfig.model(), which returns this string when the
     * Broker_Protection_Config__mdt.Default record is absent or its Model__c is blank.
     * Keeping the literal here means an org with no config record behaves exactly as it did
     * before WS5.
     */
    private static final String MODEL = 'gpt-4o-mini';

    /** Callout timeout in milliseconds. Raised from 30s: a ten-property extraction is
     *  materially slower than a four-key one, and a timeout costs the email its address.
     *  The platform's per-callout ceiling is 120s, so this is comfortably inside it. */
    private static final Integer TIMEOUT_MS = 60000;

    /**
     * Upper bound on the model's response tokens. 512 -> 4096 (C-14) — see the class
     * header's RESPONSE SIZING note. Well inside gpt-4o-mini's 16k output ceiling.
     *
     * ⚠ SINCE WS5 (2026-08-30) THIS IS THE FALLBACK, NOT THE LIVE VALUE — see MODEL above.
     * The live value is BrokerProtectionConfig.maxTokens().
     */
    private static final Integer MAX_TOKENS = 4096;

    /**
     * Ceiling on the email text sent to the model (C-15). Raw_Body__c can hold 131,072
     * characters (~33k tokens) and the tail of a long forward is quoted history that adds
     * cost and latency without adding facts.
     *
     * ⚠ This clip touches the LEGACY four values, so it is only safe because the outermost
     * "From:" / "Sent:" lines of a forward sit at the TOP of the body — which is exactly
     * what the regression fixtures assert (ExtractionRegressionFixtureTest).
     */
    private static final Integer MAX_INPUT_CHARS = 40000;

    /** Property objects the model is asked to return at most. MUST stay in step with
     *  ExtractAddressQueueable.MAX_PROPERTIES — the prompt cap bounds the RESPONSE, the
     *  queueable cap bounds the WORK, and a mismatch merely wastes tokens. */
    private static final Integer MAX_PROPERTIES_IN_PROMPT = 10;

    /**
     * 🔴 THE PRE-ENRICHMENT INSTRUCTION, VERBATIM. Every sentence below shipped in
     * production and produced the `broker_email` / `property_address` values the existing
     * Property_Registry__c rows are keyed on. It is reproduced character for character,
     * minus only its final response-format sentence (retained separately as
     * LEGACY_RESPONSE_FORMAT, because "respond with exactly these four keys" is
     * incompatible with the enriched schema). DO NOT EDIT.
     *
     * @TestVisible so ExtractionRegressionFixtureTest can pin the exact text: an accidental
     * edit to the claim engine's prompt would otherwise be invisible until a broker lost a
     * property.
     */
    @TestVisible
    private static final String LEGACY_EXTRACTION_RULES =
        'You are extracting fields from a FORWARDED email. The content below is the ' +
        'body of a broker email that an internal DPEG user forwarded on. ' +
        'The OUTERMOST / EARLIEST "From:" line identifies the ORIGINAL BROKER — take ' +
        'broker_name and broker_email from that line. The "To:" line identifies the ' +
        'internal person who forwarded the email — IGNORE it; never use it for the ' +
        'broker. property_address is any property address found anywhere in the body. ' +
        'sent_datetime is the OUTERMOST / EARLIEST "Sent:" line, converted to UTC and ' +
        'formatted as "yyyy-MM-dd HH:mm:ss". If a value is absent, use an empty ' +
        'string.';

    /**
     * The retired tail of the original instruction, kept ONLY as the rollback lever
     * described in the class header. Nothing references it on the enriched path; the
     * regression test asserts it still composes back into the original prompt verbatim.
     */
    @TestVisible
    private static final String LEGACY_RESPONSE_FORMAT =
        ' Respond ONLY with a single JSON object of exactly these keys and no ' +
        'other text: {"broker_name": "", "broker_email": "", "property_address": "", ' +
        '"sent_datetime": ""}.';

    /**
     * The enrichment layered ON TOP of the legacy rules. It never restates or contradicts
     * them — where the two could disagree it defers explicitly, because the four legacy
     * values are the claim engine's input and their behaviour must not drift.
     */
    private static final String ENRICHED_EXTRACTION_RULES =
        '\n\n=== END OF THE ORIGINAL RULES. THEY REMAIN AUTHORITATIVE FOR broker_name, ' +
        'broker_email, property_address AND sent_datetime. ===\n\n' +
        'INPUT SHAPE: the content below begins with a single line "Subject: ..." carrying the ' +
        'subject of the forwarded email exactly as it was received, followed by a blank line ' +
        'and then the body. That Subject line IS part of the email\'s content and you MAY read ' +
        'it for any value you extract — property_name, property_address, unit_count, ' +
        'offer_due_date, asset_type, sale_process and the classification — because broker ' +
        'subject lines routinely carry the offer deadline, the unit count, the asset name and ' +
        'the market, and often carry them nowhere else. THE SUBJECT LINE IS NEVER A SOURCE FOR ' +
        'broker_name, broker_email OR sent_datetime — those three come ONLY from the rules ' +
        'above, read from the body. A "From:" or "Sent:" fragment appearing inside the Subject ' +
        'line is transport debris, not a header line: it is never the outermost or earliest ' +
        'such line, whatever its position in the text. BODY-OVER-SUBJECT PRECEDENCE: when the ' +
        'body and the subject both state a property address, the BODY WINS; the subject may ' +
        'only supply an address the body does not state anywhere. A leading forwarding or reply ' +
        'prefix — "RE:", "FW:", "FWD:", or a bracketed mailing-list tag — is transport noise and ' +
        'is never part of property_name. This paragraph describes only WHERE values may be read ' +
        'from; it does not change which "From:" or "Sent:" line is authoritative for ' +
        'broker_name, broker_email or sent_datetime (a "Subject:" line is neither of those), and ' +
        'it relaxes no anti-hallucination rule below.\n\n' +
        'In addition to those four values, extract the full deal-screening field set and ' +
        'classify the email.\n\n' +
        '- property_name is the marketing or brand name of the property — typically the ' +
        'subject line, the first sentence of the body, or the headline of an attached ' +
        'flyer image. It is DISTINCT from property_address: in "Orion ParkView, 1400 ' +
        'Royal Lane, Dallas TX", property_name is "Orion ParkView" and property_address ' +
        'is "1400 Royal Lane, Dallas TX". If the email gives the property no name, leave ' +
        'property_name empty; never invent one.\n\n' +
        'MULTIPLE PROPERTIES: one email may pitch several properties. Return ONE object in ' +
        '"properties" per DISTINCT property, and take its "property_address" using the ' +
        'original rule above. Return at most ' + MAX_PROPERTIES_IN_PROMPT + ' property ' +
        'objects; if the email lists more, return the first ' + MAX_PROPERTIES_IN_PROMPT +
        ' and describe the remainder in "deal_summary".\n\n' +
        'BROKER vs LISTING BROKER: broker_name / broker_email are the sender of the ' +
        'original email, per the rules above. Some emails are blast or marketing sends ' +
        'where the sender is NOT the listing broker; put that person in ' +
        'listing_broker_name / listing_broker_email. NEVER put the listing broker into ' +
        'broker_name or broker_email.\n' +
        'WHEN THE SENDER IS A PLATFORM OR AN AUTOMATED MAILBOX RATHER THAN A PERSON: the ' +
        'rules above still decide WHICH LINE broker_name and broker_email come from, and the ' +
        'outermost / earliest "From:" line is still that line even when it names a listing ' +
        'platform, a marketplace, a CRM or marketing system, or a role mailbox such as ' +
        'listings@, deals@, info@, marketing@, notifications@, no-reply@ or do-not-reply@ ' +
        'rather than an individual. In that case broker_name is that sender as written — the ' +
        'platform or mailbox name — and broker_email is its address. A person named in the ' +
        'BODY under a "Listing broker:", "Listing agent:", "Exclusively listed by", ' +
        '"Marketed by", "Advisor:" or "For more information contact" style label is ' +
        'listing_broker_name / listing_broker_email, and is NOT promoted into broker_name or ' +
        'broker_email merely because the sender happens not to be a person. If the input ' +
        'carries no usable outermost "From:" line at all, leave broker_name and broker_email ' +
        'EMPTY rather than substituting somebody named in the body: an empty value is always ' +
        'safe, whereas the wrong person there silently attributes the submission to someone ' +
        'who did not send it.\n\n' +
        'broker_company — STATED ALWAYS BEATS INFERRED: broker_company is the firm of the ' +
        'person identified by broker_email. If that firm is named ANYWHERE in the email, use ' +
        'the stated name; look in the body, the subject, the sender\'s SIGNATURE BLOCK, and ' +
        'the FOOTER — the letterhead, disclaimer, address block or copyright line at the ' +
        'bottom of the message or of an attached flyer image, which is frequently the only ' +
        'place the firm is written. Return only the FIRM name: when the stated form carries a ' +
        'division, team, region, market, group or business-line qualifier, strip it — "JLL ' +
        'Capital Markets" gives "JLL", "CBRE | Investment Properties" gives "CBRE", "Marcus & ' +
        'Millichap IPA" gives "Marcus & Millichap". When the email names several firms — for ' +
        'example a sending platform in the header and a listing brokerage in the footer — ' +
        'broker_company is the firm of broker_email\'s owner, and any other firm belongs in ' +
        'deal_summary. WHEN broker_email IS NOT AN INDIVIDUAL\'S ADDRESS, LEAVE broker_company ' +
        'EMPTY: if broker_email belongs to a listing platform, a marketplace, a CRM or ' +
        'marketing system, or a role mailbox such as listings@, deals@, info@, marketing@, ' +
        'notifications@, no-reply@ or do-not-reply@, then it identifies a SENDING SYSTEM rather ' +
        'than a person at a firm, so there is no "firm of broker_email\'s owner" either to ' +
        'state or to infer — return broker_company EMPTY and put the platform\'s own name, ' +
        'together with any listing brokerage the email names, in deal_summary. This holds even ' +
        'when the platform\'s name is written plainly in the header, the footer, the letterhead ' +
        'or the copyright line: a stated name is still not this sender\'s brokerage. An empty ' +
        'value is always safe, whereas the platform\'s name there silently groups every deal ' +
        'that ever arrived through it under one company. ONLY if no firm is stated anywhere ' +
        'may you infer broker_company from ' +
        'the DOMAIN of broker_email — kevin.girard@jll.com gives "JLL". When the domain belongs to a ' +
        'brokerage whose conventional capitalization you recognise, use that conventional ' +
        'form (for example JLL, CBRE, Cushman & Wakefield, Marcus & Millichap, Newmark, ' +
        'Colliers, Avison Young, Lee & Associates, Berkadia, Walker & Dunlop, Eastdil ' +
        'Secured, NorthMarq, Matthews, Institutional Property Advisors). Otherwise use the ' +
        'registrable part of the domain with ordinary capitalization and no suffix — ' +
        'orion-realty.com gives "Orion Realty". Return only the FIRM name the domain ' +
        'implies; never append a division, team, region, market or group name. NEVER infer ' +
        'a company from a free or consumer mailbox domain — gmail.com, googlemail.com, ' +
        'hotmail.com, outlook.com, live.com, msn.com, yahoo.com, ymail.com, aol.com, ' +
        'icloud.com, me.com, mac.com, proton.me, protonmail.com, gmx.com, gmx.net, ' +
        'zoho.com, mail.com, yandex.com, comcast.net, verizon.net, att.net, ' +
        'sbcglobal.net, bellsouth.net, cox.net, charter.net, earthlink.net, ' +
        'optonline.net, rr.com, roadrunner.com, windstream.net, frontier.com, aim.com, ' +
        'juno.com, or any other consumer mailbox provider — and never from a domain that ' +
        'is not a company\'s own domain. In those cases leave broker_company EMPTY. AN ' +
        'INTERNET-SERVICE-PROVIDER, TELECOM, CABLE, WEBMAIL OR PORTAL DOMAIN IS NEVER THE ' +
        'BROKER\'S FIRM, even when its name is a real company: comcast.net must not give ' +
        '"Comcast", att.net must not give "AT&T", verizon.net must not give "Verizon", and ' +
        'sbcglobal.net must not give "SBC Global". If you cannot tell whether a domain is a ' +
        'business\'s own domain or a mailbox provider, treat it as a mailbox provider and ' +
        'leave broker_company EMPTY — an empty value is always safe, whereas a wrong firm ' +
        'name silently groups unrelated brokers under one company. This ' +
        'rule reads broker_email only as a source for broker_company; it does not change ' +
        'how broker_name, broker_email, property_address or sent_datetime are determined.\n\n' +
        'sent_datetime WHEN NO DATE IS STATED: the rules above remain authoritative for ' +
        'which line sent_datetime is taken from. This adds only one restriction on ' +
        'whether it may be filled at all. It must come from explicit content — a "Sent:" ' +
        'or "Date:" header line, or a date written in the body. If the email states no ' +
        'send date, return an EMPTY STRING for sent_datetime. Never infer it from ' +
        'knowledge of the property, the campaign or the listing.\n\n' +
        'ANTI-HALLUCINATION RULES (these matter more than completeness):\n' +
        '- Use null for any value the email does not state. Never guess and never infer.\n' +
        '- NEVER derive one number from another. Do not compute price from cap rate and ' +
        'NOI, do not compute NOI from price and cap rate, and do not convert square feet ' +
        'to acres or acres to square feet. Report only what is written.\n' +
        '- lot_size_acres and lot_size_sf are the LAND or SITE area only: lot_size_acres ' +
        'ONLY if the email states the site in acres, lot_size_sf ONLY if it states the site ' +
        'in square feet. Never fill both from a single figure, and never put a building or ' +
        'floor area in either.\n' +
        '- building_sf is the BUILDING area — the gross, rentable or net rentable square feet ' +
        'of the improvements, however the email labels it ("Building Size", "Net rentable ' +
        'area", "GLA", or a bare "SF" when it labels the improvements). It is NOT the site: ' +
        '"84,500 square feet of building on a 3.7-acre site" gives building_sf 84500 and ' +
        'lot_size_acres 3.7. "Land SF", "Lot SF" and "Site SF" are lot_size_sf, NEVER ' +
        'building_sf. Where the email gives several areas, building_sf is the WHOLE building, ' +
        'never a component within it such as meeting, workspace or storefront area. Return it ' +
        'whenever the email states a building size, including when the figure is written in a ' +
        'sentence of prose rather than in a labelled fact list; return null when the email ' +
        'states none.\n' +
        '- Numbers must be plain numerics with no symbols, units or separators: write ' +
        '7100000, not "$7.1M".\n' +
        '- cap_rate and occupancy_pct are PERCENTAGE numbers: 6.75 means 6.75 percent and ' +
        '88 means 88 percent. Never return a fraction such as 0.0675 or 0.88.\n' +
        '- year_built and year_renovated: return the year exactly as written ("88/22" ' +
        'means year_built 88 and year_renovated 22); do not expand it.\n' +
        '- If the email quotes both a reported and an adjusted or pro-forma NOI, put the ' +
        'ADJUSTED figure in "noi" and mention BOTH in "deal_summary".\n' +
        '- If a price is quoted as a range, use guidance_price_low and guidance_price_high ' +
        'and leave guidance_price null. If a single asking price is quoted, use ' +
        'guidance_price and leave the range null.\n' +
        '- unit_count is apartment units, or hotel keys for a hospitality asset.\n' +
        '- walt_years is the weighted average lease term remaining, in YEARS, as a plain ' +
        'number: "WALT 8.3 years" gives 8.3. If the email states it in months, return null ' +
        'rather than converting.\n' +
        '- adr is the average daily rate of a hospitality asset, in dollars: "ADR $205" gives ' +
        '205. It is never RevPAR and never occupancy.\n' +
        '- zoning is the zoning designation or code exactly as written ("C-2", "PD-14"); leave ' +
        'it empty if the email states none.\n' +
        '- seller_entity is the named legal owner or selling entity when the email names one. ' +
        'A description rather than a name — "a family partnership" — is not a seller ' +
        'entity; leave it empty.\n' +
        '- deal_room_link is the URL of a deal room, data room or document portal the email ' +
        'links to. A website, unsubscribe, map or calendar link is not one; leave it empty.\n' +
        '- broker_phone is the office, main or direct telephone number of broker_email\'s ' +
        'owner, as written; broker_mobile is their mobile or cell number when the email labels ' +
        'one as such. If only one number is given, it is not labelled, and it plainly belongs ' +
        'to broker_email\'s owner, put it in broker_phone and leave broker_mobile empty. WHEN ' +
        'broker_email IS NOT AN INDIVIDUAL\'S ADDRESS, LEAVE BOTH EMPTY: if broker_email ' +
        'belongs to a listing platform, a marketplace, a CRM or marketing system, or a role ' +
        'mailbox such as listings@, deals@, info@, marketing@, notifications@, no-reply@ or ' +
        'do-not-reply@, then a number in the body is somebody else\'s — usually the listing ' +
        'broker\'s — and there is no "number of broker_email\'s owner" ' +
        'to state. Put that number, and whose it is, in deal_summary rather than dropping ' +
        'it, exactly as broker_company does with a platform name it must not use. An ' +
        'empty value ' +
        'is always safe, whereas the wrong number there sends a caller to a person who did not ' +
        'send the email.\n' +
        '- broker_title is that same person\'s job title as written in their signature block — ' +
        '"Managing Director, Capital Markets". Never infer one, and never take the ' +
        'title of anyone other than broker_email\'s owner.\n' +
        '- listing_broker_email must be an address WRITTEN IN THE EMAIL for the person the ' +
        'message names as the listing broker. Copy it character for character from the text. ' +
        'NEVER construct one: not from the firm\'s name, not from its website or domain, not ' +
        'from the person\'s name, and not from any address pattern you have seen elsewhere. If ' +
        'the email names a listing broker but states no address for them, fill ' +
        'listing_broker_name and leave listing_broker_email EMPTY — an empty value is always ' +
        'safe, whereas an invented address is one somebody will write to. This adds a ' +
        'restriction on listing_broker_email only; it does not change how broker_name, ' +
        'broker_email, property_address or sent_datetime are determined.\n' +
        '- Relative deadlines are resolved against sent_datetime: "offers due today" means ' +
        'the date of sent_datetime, or the date of the anchor A defined below when the ' +
        'email states no send date. For an auction DATE RANGE use the START date. ' +
        'offer_due_date is formatted "yyyy-MM-dd". A date written WITHOUT A YEAR takes ' +
        'its year from the anchor date A, where A is the year-bearing "Sent:" or "Date:" ' +
        'line in the email when one exists, and otherwise the supplied REFERENCE DATE. ' +
        'Give such a date the year of A; give it the year AFTER A only if it would ' +
        'otherwise fall more than 30 days before A. Never roll a year backward, and never ' +
        'use knowledge of when a real-world campaign or listing happened.\n' +
        '- asset_type, deal_type, sale_process and listing_status MUST be one of the ' +
        'listed values or null. Never invent a value.\n' +
        '- deal_type is NOT a property category and is NOT a second opinion about asset_type, ' +
        'even though both use the word Retail. It records ONE fact: whether what is being sold ' +
        'is RAW LAND or not. Return Land when the subject of the sale is undeveloped ground — a ' +
        'development site, a pad, acreage, or a ground lease of unimproved ground. RETURN Retail ' +
        'FOR EVERYTHING ELSE: any property that includes a standing building, whatever kind of ' +
        'building it is. A hotel, a clinic, a warehouse, an office building, an apartment ' +
        'community, a self-storage facility and a shopping center are ALL deal_type Retail. ' +
        'Retail here means "not raw land"; it does NOT mean the property is a shop, and ' +
        'deal_type must NEVER be made to agree with asset_type. A property that is neither raw ' +
        'land nor a store is the NORMAL case and its answer is Retail — do not return null ' +
        'because neither word seems to describe the building. Return null ONLY when the email ' +
        'does not say what is being sold at all.\n' +
        '- listing_status is On Market when the email shows the property is being marketed ' +
        'publicly — a listing platform or marketplace page, a public listing link, an ' +
        'advertised campaign, or wording such as "now listed", "just listed", "on the ' +
        'market" or "publicly marketed". It is Off Market when the email shows the seller ' +
        'is shopping it privately — wording such as "off market", "off-market ' +
        'opportunity", "quiet listing", "pocket listing", "not publicly marketed", "before ' +
        'it goes to market", or an exclusive introduction to a named recipient. IF THE ' +
        'EMAIL DOES NOT SAY, RETURN null. Do not infer it from sale_process, from the ' +
        'presence of an offer deadline, from a deal room link, from how polished the ' +
        'marketing material is, or from anything you know about the property outside this ' +
        'email — a wrong answer here is worse than an empty one, because nothing tells the ' +
        'reader it needs correcting.\n' +
        '- deal_summary is at most 800 characters.\n\n' +
        'CLASSIFICATION: email_category is one of acquisition_deal, call_for_offers, ' +
        'reply, system_notification, newsletter, out_of_office, other. ' +
        'is_acquisition_related is true when the email offers, markets or discusses a ' +
        'commercial real-estate property for potential acquisition, and false for ' +
        'automated notifications, forwarding confirmations, out-of-office replies and ' +
        'newsletters. confidence is a number from 0 to 1 expressing how certain you are ' +
        'of is_acquisition_related. IT IS A REAL JUDGEMENT AND MUST NOT BE LEFT AT THE 0.0 ' +
        'SHOWN IN THE RESPONSE TEMPLATE BELOW — that 0.0 illustrates the SHAPE of the reply ' +
        'and is never an answer. 0.0 means "I cannot tell at all whether this email concerns ' +
        'a property", so returning 0.0 next to a definite is_acquisition_related contradicts ' +
        'itself. When the email plainly has nothing to do with commercial real estate — ' +
        'internal staff, HR or team mail, calendar and meeting logistics, expense, payroll or ' +
        'invoice administration, IT and system notices, personal correspondence, marketing ' +
        'unrelated to property, out-of-office and delivery receipts — return ' +
        'is_acquisition_related false with confidence 0.9 or above: there is nothing uncertain ' +
        'about such an email, and reporting low confidence about it is itself an error. ' +
        'Reserve confidence below 0.85 for emails that genuinely could go either way. ' +
        'category_confidence is a number from 0 to 1 expressing how certain you are of ' +
        'email_category SPECIFICALLY — it is a SEPARATE judgement from confidence, which ' +
        'concerns is_acquisition_related only. Return category_confidence above 0.85 only ' +
        'when the email is unambiguously of that category on its face.\n' +
        'call_for_offers MEANS A MASS-DISTRIBUTION MARKETED CAMPAIGN BLAST AND NOTHING ELSE. ' +
        'A STATED OFFER DEADLINE IS NOT SUFFICIENT AND IS NOT EVEN EVIDENCE: most ordinary ' +
        'offering memoranda quote a bid date, and a deadline sentence on its own says nothing ' +
        'about how the email was distributed. Classify call_for_offers ONLY when the email ' +
        'itself shows a mass or list send to the market at large — it addresses no one in ' +
        'particular ("Dear Investor", "All", or no salutation), it reads as a broadcast ' +
        'announcement rather than as a message written to this recipient, it carries ' +
        'unsubscribe, mailing-preference or "you are receiving this because" language, or it ' +
        'is a marketplace or listing-platform notification rather than a broker writing to ' +
        'someone. WHEN IN DOUBT IT IS NOT call_for_offers.\n' +
        'PRECEDENCE — THE MASS-SEND SIGNALS DECIDE, AND NOTHING BELOW OVERRIDES THEM. The ' +
        'exemplars that follow are read UNDER the test above, never against it. When an email ' +
        'carries the mass-send signals ON ITS FACE — no individual addressee, a broadcast ' +
        'register, unsubscribe or mailing-preference or "you are receiving this because" ' +
        'language, or a marketplace or listing-platform notification — it is call_for_offers ' +
        'EVEN IF IT ALSO MATCHES ONE OF THE acquisition_deal EXEMPLARS BELOW. In particular, ' +
        'BEING SENT BY A NAMED PERSON AT A BROKERAGE NEVER OVERRIDES THOSE SIGNALS: marketed ' +
        'campaign blasts are normally sent by a named broker at a real firm, and every email you ' +
        'are shown has been forwarded to us by an internal person, so neither fact tells the two ' +
        'categories apart at all. The same holds for polished marketing material, an attached ' +
        'flyer, quoted property facts, and an invitation to call, tour or ask a question — a ' +
        'blast carries all of those too. Only where the mass-send signals are ABSENT do the ' +
        'exemplars below apply, and there they are decisive. Where you cannot tell whether those ' +
        'signals are present, they are not present: doubt about the SIGNALS resolves to ' +
        'acquisition_deal exactly as the sentence above says.\n' +
        'These are acquisition_deal, NOT call_for_offers:\n' +
        '- an offering memorandum or property flyer from a named individual broker that ' +
        'quotes property facts (name, address, square feet, occupancy, guidance price, cap ' +
        'rate) AND states "Offers due 30 September 2026". The deadline changes NOTHING. This ' +
        'is the canonical case and it is acquisition_deal;\n' +
        '- an off-market or exclusive introduction;\n' +
        '- a property offering sent to one recipient;\n' +
        '- any email that invites a direct conversation, a call, a tour or a question;\n' +
        '- a forwarded broker email whose original sender is a named person at a brokerage, ' +
        'however polished the marketing material attached to it — UNLESS the email itself ' +
        'carries the mass-send signals above (no individual addressee, an unsubscribe or ' +
        'mailing-list footer, a broadcast register), in which case the mass-send signals win ' +
        'and it is call_for_offers. EVERY email you are shown is a forwarded broker email, so ' +
        'this exemplar on its own distinguishes nothing; what it rules out is treating a ' +
        'forward, or a named human sender, as EVIDENCE OF A BLAST.\n' +
        'These are call_for_offers:\n' +
        '- a marketplace or listing-platform blast announcing a call for offers to its whole ' +
        'subscriber list;\n' +
        '- a campaign announcement addressed to "Investors" or "All" with no individual ' +
        'recipient and an unsubscribe or mailing-list footer;\n' +
        '- a "best and final" or "call for offers" round announcement circulated to every ' +
        'bidder in a marketed process.\n' +
        'WHY THIS ONE JUDGEMENT MATTERS MORE THAN THE OTHERS: an email you classify ' +
        'call_for_offers is suppressed entirely — no record is created for it and the broker ' +
        'who sent it receives no first-contact protection. NEITHER ERROR IS FREE, so do not ' +
        'treat either direction as costless. A wrong call_for_offers costs a real broker their ' +
        'claim on a real property; nothing in the system reports it, and only a person editing ' +
        'the ledger by hand can give the claim back. A wrong acquisition_deal REGISTERS A ' +
        'FIRST-COME CLAIM ON THAT PROPERTY FOR WHOEVER SENT THE BLAST, which can later stand in ' +
        'the way of the broker who genuinely holds the listing — it is not merely a record ' +
        'somebody reviews. Bias every borderline judgement toward acquisition_deal ANYWAY, for ' +
        'a reason that survives that correction: the first error is a CERTAIN loss the instant ' +
        'it is made, while the second is a CONTINGENT one that becomes a loss only if a second ' +
        'broker later submits the same property, and it leaves a visible record a human can ' +
        'find and correct. Bias is not licence: where the mass-send signals above are plainly ' +
        'present, classify call_for_offers.\n\n' +
        'PER-FIELD CONFIDENCE: field_confidence is a JSON object reporting how certain you are ' +
        'of EACH VALUE YOU RETURNED. It is a THIRD, separate judgement — confidence concerns ' +
        'is_acquisition_related and category_confidence concerns email_category, and neither ' +
        'says anything about whether you read the NOI or the year built correctly. Include one ' +
        'entry per key you returned a non-empty value for, named exactly as it appears in the ' +
        'shape below and with no prefix for the property-level keys ("noi", "year_built", ' +
        '"cap_rate", "building_sf"), and give it a number from 0 to 1. OMIT any key you left ' +
        'empty or null: an ' +
        'absent entry means "no value", never "a value I doubt". Score a value the email states ' +
        'outright at 0.9 or above; score below 0.60 anything you inferred, converted, or read ' +
        'from a table, a footnote or attached marketing material — 0.60 is the line below which ' +
        'a person is asked to check the value by hand, so a guess scored high is a wrong answer ' +
        'nobody is sent to look at. Where you return several properties, return ONE object for ' +
        'the whole email and give each property-level key your LOWEST confidence for it across ' +
        'them. THIS PARAGRAPH ONLY REPORTS ON VALUES YOU HAVE ALREADY DECIDED — it changes none ' +
        'of them, it relaxes no rule above, and it is never a reason to return a value you would ' +
        'otherwise have left empty.\n\n' +
        'Respond ONLY with a single JSON object in exactly this shape, with no other ' +
        'text:\n' +
        '{"email_category": "other", "is_acquisition_related": true, "confidence": 0.0, ' +
        '"category_confidence": 0.0, "field_confidence": {}, ' +
        '"broker_name": "", "broker_email": "", "broker_company": "", "broker_phone": "", ' +
        '"broker_mobile": "", "broker_title": "", "listing_broker_name": "", ' +
        '"listing_broker_email": "", "sent_datetime": "", "deal_summary": "", ' +
        '"properties": [{"property_name": "", "property_address": "", "asset_type": null, ' +
        '"deal_type": null, "sale_process": null, "listing_status": null, ' +
        '"guidance_price": null, ' +
        '"guidance_price_low": null, "guidance_price_high": null, "cap_rate": null, ' +
        '"noi": null, "occupancy_pct": null, "building_sf": null, "lot_size_acres": null, ' +
        '"lot_size_sf": null, "unit_count": null, "year_built": null, ' +
        '"year_renovated": null, "walt_years": null, "adr": null, "zoning": "", ' +
        '"seller_entity": "", "deal_room_link": "", "offer_due_date": null}]}\n\n' +
        'asset_type must be one of: Retail, C-Store, Land, Industrial, Office, ' +
        'Multifamily, Storage, Mixed-Use, Hospitality, Medical Office.\n' +
        // 🔴 THIS LINE IS BEHAVIOUR, NOT DOCUMENTATION (requirements §9 C13). It tells the
        // model which Deal_Type__c values it may emit, so the Commercial -> Retail migration
        // MUST repoint it at D3. LLMExtractionParser describe-validates `deal_type` against
        // the live picklist, so between D1 and D4 (when both values are active) either answer
        // validates and nothing breaks — but after D4 an un-repointed prompt would instruct the
        // model to emit a DELETED value, which the guard then drops SILENTLY: no exception, no
        // log, and every email-born deal arrives with no deal type and therefore no record type.
        'deal_type must be one of: Land, Retail.\n' +
        'sale_process must be one of: Off-Market, On-Market Listing, Call for Offers, ' +
        'Auction.\n' +
        'listing_status must be one of: On Market, Off Market.';

    /**
     * THE prompt — ONE constant, which is what makes the rollback described in the class
     * header a single-line change.
     *
     * ⚠ SINCE WS5 (2026-08-30) THIS IS THE FALLBACK, NOT NECESSARILY THE LIVE PROMPT.
     * resolvePrompt() below returns Broker_Protection_Config__mdt.Default.Extraction_Prompt__c
     * when that record exists, carries a non-blank value, AND that value passes the two
     * usability tests added 2026-08-31 (longer than 255 characters, contains the token 'json').
     * This constant is used otherwise. It is exactly what
     * scripts/load-broker-protection-config.apex writes into the record, so a freshly
     * loaded org sends a byte-identical prompt to a never-loaded one.
     *
     * ═══ 🔴 THE LENGTH IS NOT STATED HERE, AND THAT IS THE POLICY — DO NOT ADD A NUMBER ═══
     * The 2026-08-31 schema-key definition pass moved the prompt's length. It is deliberately
     * NOT restated, because there is no way to state it correctly from this file:
     *   • the only authority is `shippedPrompt().length()` evaluated AT RUNTIME on a DEPLOYED
     *     class — and until it is deployed that value does not exist;
     *   • any figure written here in advance is therefore a SOURCE COUNT, and a source count
     *     under-reports by exactly 4 because ENRICHED_EXTRACTION_RULES interpolates
     *     MAX_PROPERTIES_IN_PROMPT twice. That is the exact error made below in 2026-08-31's
     *     20,592 → 20,596 correction, and it looks like a plausible fix when it is wrong;
     *   • and filling one in after deployment would mean re-deploying this class purely to
     *     correct a comment.
     * A tag that names no number cannot go stale a fifth time. This mirrors the policy already
     * adopted for Extraction_Prompt__c's field <description> and its in-root XML comment, both
     * of which had their numbers removed for this same reason.
     * 🔴 IF YOU NEED THE LENGTH, EVALUATE `LLMExtractionCalloutService.shippedPrompt().length()`
     * AGAINST THE ORG. Never count the literals, and never copy a figure out of a comment.
     *
     * ═══ THE PRIOR MEASUREMENT, KEPT BECAUSE ITS ARITHMETIC LESSON STILL APPLIES ═══
     * MEASURED on `usman-dpeg` at API 67.0 on 2026-08-31, BEFORE the definition pass:
     * `LLMExtractionCalloutService.shippedPrompt().length()` == **20,596**.
     *
     * This block, ExtractionRegressionFixtureTest and the loader all said 20,592 until then.
     * THE ORG AND THE REPO NEVER DISAGREED — the org's ApexClass Body was verified
     * byte-identical to this file on 2026-08-31. 20,592 is what you get by adding up the STRING
     * LITERALS ONLY (LEGACY 596 + ENRICHED's literals 19,996). It misses the FOUR characters
     * that ENRICHED_EXTRACTION_RULES interpolates at RUNTIME:
     * `MAX_PROPERTIES_IN_PROMPT` (= 10, two characters) appears TWICE in that concatenation.
     * 596 + 19,996 + 4 = 20,596.
     *
     * ⚠ CONSEQUENCE FOR ANYONE RE-DERIVING THIS NUMBER FROM SOURCE: the length is
     * VALUE-DEPENDENT. Changing MAX_PROPERTIES_IN_PROMPT from 10 to 9 or to 100 changes the
     * prompt length without touching a single string literal. Counting the literals by hand or
     * with a script WILL under-report by 4 and look like a plausible correction back to 20,592.
     * The authority is a live `shippedPrompt().length()`, nothing else. This repo was bitten
     * THREE times by a stale prompt-length figure (19,254 → 20,592 → 20,596); the first two
     * were real edits, the third was this arithmetic blind spot. There is no fourth entry
     * because the 2026-08-31 definition pass DE-PINNED the figure instead of restating it —
     * see the block above. Do not restart the sequence by adding a number back.
     *
     * 🔴 THE PROMPT IS ALSO NOW READ BY SOQL, NOT getInstance(). Broker_Protection_Config__mdt's
     * Extraction_Prompt__c is a LongTextArea, and getInstance()/getAll() SILENTLY CLIP long text
     * to 255 characters. That truncated head contains no 'json', OpenAI refused every request,
     * and ExtractAddressQueueable degraded silently — a live P0 (measured 2026-08-31:
     * getInstance 255 / SOQL 20,596 / identical = false). BrokerProtectionConfig now reads this
     * one field through BrokerProtectionConfigSelector. See .claude/skills/sf-apex/SKILL.md and
     * ARCHITECTURE.md §2, both amended in the same change.
     *
     * 🔴 THAT EQUIVALENCE IS NOT AUTOMATIC AFTER WS7 — THE LOADER MUST BE RE-RUN. An org whose
     * record was seeded BEFORE the WS7 edit holds the 19,254-character prompt and will keep
     * sending it, because resolvePrompt() prefers the record. Such an org returns no
     * `field_confidence` at all, LLMExtractionParser degrades to an empty map without throwing,
     * and every Lead is stamped `Low_Confidence_Field_Count__c = 0` — the feature is silently
     * absent, not broken, and nothing logs it. Re-running the loader is what turns it on.
     * ✅ THERE IS NOTHING LEFT TO KEEP IN SYNC. This paragraph used to say the loader's
     * seed-length debug line "agrees with this block", and tracked the corrections that kept
     * them agreeing (19254 → 20592 → 20596). BOTH HALVES ARE NOW OBSOLETE: the 2026-08-31
     * definition pass de-pinned the loader line AND this block, so neither states a figure and
     * there is no agreement to maintain. ⚠ DO NOT GO LOOKING FOR A 20596 IN THE LOADER — it was
     * removed on purpose, and restoring a pin "so they agree again" reinstates exactly the
     * failure mode the de-pinning removed. The loader now simply PRINTS the length it seeded;
     * that print IS the measurement.
     */
    private static final String EXTRACTION_INSTRUCTION =
        LEGACY_EXTRACTION_RULES + ENRICHED_EXTRACTION_RULES;

    /**
     * The prompt this CLASS ships — i.e. EXTRACTION_INSTRUCTION, the compile-time fallback.
     *
     * 🔴 THIS IS NOT THE LIVE PROMPT. The live prompt is resolvePrompt(), which prefers the
     * Setup-configured Broker_Protection_Config__mdt.Default.Extraction_Prompt__c when that
     * value is present and usable. Do not call this to find out what the org actually sends.
     *
     * WHY IT IS PUBLIC. It exists for exactly one caller:
     * scripts/load-broker-protection-config.apex, which SEEDS the CMDT record. Seeding from
     * this method rather than from a transcribed copy of the prompt is a correctness
     * property, not a convenience — a hand-copied 20,596-character literal in the loader
     * would be a SECOND copy of the exact text that keys the broker registry, and the first
     * time someone edited the Apex constant and re-ran the loader the two would disagree
     * silently. Sourcing the seed from here makes "the loaded record equals the shipped
     * prompt" true by construction instead of by discipline.
     *
     * ⚠ It also means the loader must run AFTER this class is deployed. That ordering is
     * stated in the loader's own header.
     *
     * 🔴 AND AFTER 2026-08-31 IT MEANS MORE THAN THAT: RE-RUNNING THE LOADER BEFORE THE
     * TRUNCATION FIX IS DEPLOYED REINSTATES THE P0. The loader writes this full string into the
     * record; the DEFECT was on the READ side (getInstance clipping it back to 255). Until
     * BrokerProtectionConfig + BrokerProtectionConfigSelector are live, a populated record is
     * strictly worse than a blank one, because blank falls back to this constant and works.
     *
     * @return LEGACY_EXTRACTION_RULES + ENRICHED_EXTRACTION_RULES. Never null, never blank.
     *         🔴 NO CHARACTER COUNT IS STATED HERE, ON PURPOSE — DO NOT ADD ONE. This tag used
     *         to name a figure, and scripts/load-broker-protection-config.apex and
     *         Extraction_Prompt__c's field <description> both defer to it BY NAME, which made
     *         it the single site whose staleness propagated everywhere. It went stale three
     *         times (19,254 → 20,592 → 20,596), and the third correction was not a prompt edit
     *         at all but an arithmetic blind spot: counting the string literals under-reports
     *         by exactly 4, because ENRICHED_EXTRACTION_RULES interpolates
     *         MAX_PROPERTIES_IN_PROMPT twice at RUNTIME. A number cannot be written here
     *         correctly in advance — the only authority is `shippedPrompt().length()` evaluated
     *         against a DEPLOYED class — and writing it afterwards would mean re-deploying this
     *         class to fix a comment. A tag that names no number cannot go stale.
     *         ⚠ NEED THE LENGTH? Run `System.debug(LLMExtractionCalloutService
     *         .shippedPrompt().length());` against the org. Never count the literals.
     */
    public static String shippedPrompt() {
        return EXTRACTION_INSTRUCTION;
    }

    /**
     * The extraction instruction actually sent on this callout.
     *
     * 🔴 THIS METHOD IS THE ENFORCEMENT POINT FOR BrokerProtectionConfig's ONE NULLABLE
     * ACCESSOR. extractionPromptOverride() is documented to return null when there is no
     * override, precisely because its default is the ~20KB constant above — a value that
     * belongs to this class and must not be copied into the config accessor, where a second
     * copy could silently drift and re-key the broker registry. Any future caller of
     * extractionPromptOverride() must resolve the default the same way and must not invent
     * a different one.
     *
     * ⚠ A BLANK Extraction_Prompt__c IS TREATED AS "NO OVERRIDE", NOT AS "SEND AN EMPTY
     * PROMPT". An admin who clears the field in Setup gets the shipped prompt back, not a
     * callout with no instructions — the latter would return unparseable output for every
     * inbound email and silently stop the pipeline producing Leads.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE DEFENSIVE GUARD (2026-08-31) — A CONFIGURED PROMPT THAT CANNOT WORK NEVER
     *    REACHES OpenAI
     * ═══════════════════════════════════════════════════════════════════════════════════
     * Added as the first half of a live-P0 fix. Two rejection tests, each with a DISTINCT
     * diagnosis, both falling back to EXTRACTION_INSTRUCTION:
     *
     *   1. `length() <= PROMPT_TRUNCATION_BOUNDARY` (255) ⇒ TRUNCATED_AT_OR_BELOW_255
     *   2. `!containsIgnoreCase('json')`                  ⇒ MISSING_JSON_TOKEN
     *
     * WHY THE `json` TEST. It is NOT a heuristic — it is the literal precondition OpenAI
     * enforces, quoted verbatim from the error this org received on every inbound email:
     * "'messages' must contain the word 'json' in some form, to use 'response_format' of type
     * 'json_object'." buildRequestBody sets exactly that response_format.
     *
     * WHY THE LENGTH TEST, AND WHY 255 AND NOT A ROUNDER NUMBER. 255 is the width
     * `getInstance()`/`getAll()` clip a LongTextArea to — so a configured value at or below it
     * is INDISTINGUISHABLE from a truncation artifact. Any other threshold (500, 1000) would be
     * an invented number; this one is the boundary itself, which is the only non-arbitrary
     * choice available. Measured on `usman-dpeg` 2026-08-31: getInstance 255 / SOQL 20,596.
     *
     * ⚠ ORDER MATTERS AND IS DELIBERATE. The 255-char head of the real prompt fails BOTH tests.
     * Length is checked FIRST because "this value was truncated" is the correct ROOT-CAUSE
     * diagnosis, and "this prompt lacks the json token" would send the next reader to rewrite a
     * prompt that is in fact fine and merely clipped. The two must never share one message.
     *
     * 🔴 RESIDUAL RISK, ACCEPTED AND STATED PLAINLY. A GENUINE prompt of 255 characters or
     * fewer is now SILENTLY IGNORED in favour of the shipped constant. That is a real cost of
     * the length floor and it is accepted for two reasons: the guard is SELF-HEALING (the
     * pipeline keeps working on a known-good prompt rather than failing), and a real extraction
     * prompt for this task — which must enumerate the JSON schema, ten asset types, the
     * deal/sale/listing enumerations and the date rules — cannot be that short. If a legitimate
     * short prompt is ever wanted, raise the boundary deliberately; do not delete the check.
     *
     * ⚠ THE OVERRIDE IS CHECKED, NEVER THE COMPOSED MESSAGE. `json` could arrive accidentally
     * from `referenceDateLine()` or the forwarded email body, which would make the guard pass
     * or fail per-email and non-deterministically. The prompt is the admin-editable part and
     * the only part worth gating.
     *
     * ⚠ THE GUARD LIVES HERE, NOT IN BrokerProtectionConfig, ON PURPOSE. This class owns the
     * OpenAI boundary and is therefore the only class entitled to know that
     * `response_format: json_object` requires the token `json` in `messages`. A config accessor
     * that learned an integration precondition would be the exact dependency inversion
     * BrokerProtectionConfig's own header forbids.
     *
     * ⚠ KNOWN LIMITATION — SAID OUT LOUD RATHER THAN REPEATING WS8 FINDING W6. The ERROR line
     * this guard emits will, in practice, be read by nobody. BrokerProtectionConfig's header
     * already establishes why: a Salesforce debug log exists only while a trace flag is active
     * ON THE EXECUTING PRINCIPAL, and this runs inside an async queueable as the Email Service
     * context user — the principal least likely to be traced. That is ACCEPTABLE HERE, and the
     * reason is specific: unlike GATE A's audit trail, this guard is self-healing. The cost of
     * an unread log is "my Setup override is being ignored and I don't know why", not an
     * outage. A durable stamp was considered and is out of the approved scope.
     *
     * @return The configured prompt when one is set AND usable, otherwise EXTRACTION_INSTRUCTION.
     */
    private static String resolvePrompt() {
        String configured = BrokerProtectionConfig.extractionPromptOverride();
        if (configured == null) {
            return EXTRACTION_INSTRUCTION;
        }
        if (configured.length() <= PROMPT_TRUNCATION_BOUNDARY) {
            rejectPromptOnce(PromptRejectionReason.TRUNCATED_AT_OR_BELOW_255, configured.length());
            return EXTRACTION_INSTRUCTION;
        }
        if (!configured.containsIgnoreCase('json')) {
            rejectPromptOnce(PromptRejectionReason.MISSING_JSON_TOKEN, configured.length());
            return EXTRACTION_INSTRUCTION;
        }
        return configured;
    }

    /**
     * The width `getInstance()` / `getAll()` clip a LongTextArea or Html CMDT field to.
     *
     * 🔴 THIS IS A MEASURED PLATFORM CONSTANT, NOT A TUNING KNOB. `usman-dpeg`, API 67.0,
     * 2026-08-31: `getInstance('Default').Extraction_Prompt__c`.length() == 255 while SOQL on
     * the same row in the same transaction returned 20,596. Changing this number changes what
     * "looks truncated" means and re-opens the residual risk argued at `resolvePrompt`.
     */
    private static final Integer PROMPT_TRUNCATION_BOUNDARY = 255;

    /**
     * Why a configured prompt was rejected. An enum rather than two booleans or a free string,
     * so the two diagnoses cannot be conflated by a caller or a test — they send a reader to
     * different places (a truncating READ vs. a badly WRITTEN prompt).
     */
    public enum PromptRejectionReason { TRUNCATED_AT_OR_BELOW_255, MISSING_JSON_TOKEN }

    /**
     * The reason logged this transaction, or null when nothing was rejected.
     *
     * Doubles as the ONCE-PER-TRANSACTION guard — a 10-property email must not emit ten
     * identical ERROR lines. `extract()` runs once per queueable execution today and the
     * config is cached, so this is belt-and-braces; it costs nothing and makes the invariant
     * explicit rather than incidental.
     *
     * ⚠ @TestVisible because a `System.debug` line is not assertable. This field is the only
     * observable a test has for "the guard fired, and for THIS reason".
     *
     * ═══ 🔴 A SECOND, DIFFERENT REJECTION IN THE SAME TRANSACTION IS MASKED — BY DESIGN ═══
     * ⚠ CORRECTED 2026-08-31 (review finding S1). This block used to say "Tests reset it by
     * assigning null directly". NO TEST DOES, and none needs to today: each of T1-T4 in
     * `LLMExtractionCalloutServiceTest` provokes at most one rejection, and the only test that
     * calls `BrokerProtectionConfig.overrideForTest` twice in one transaction
     * (`blankOverride_yieldsTheShippedPrompt_withoutLoggingARejection`) rejects nothing in either
     * leg — so a reset there would assert nothing and would merely look like one.
     *
     * The consequence is stated here rather than left to be discovered: because this field IS the
     * once-per-transaction guard, the FIRST reason wins and every later one is discarded. A future
     * test that injects a TRUNCATED override and then a `json`-less one in a single transaction
     * would assert the first reason and pass while proving nothing about the second. Such a test
     * must either use two transactions (two test methods) or set this field back to null between
     * legs — it is `@TestVisible`, so any test class can simply assign to it. No
     * reset method is offered, because the assignment is one line and adding a production-visible
     * reset would suggest the guard is resettable at runtime, which it must not be.
     */
    @TestVisible
    private static PromptRejectionReason promptRejectionLogged = null;

    /**
     * Emit ONE ERROR per transaction naming the type, the record, the field, the resolved
     * length, the reason and the action.
     *
     * ERROR, not WARN, and the sibling comparison is the justification: BrokerProtectionConfig's
     * `warnOnce` uses WARN for "an admin typed a bad number, we defaulted" — one field degraded.
     * This is "the admin's configured feature is ENTIRELY INOPERATIVE and every inbound email is
     * being processed with a prompt they did not choose". That is one severity up.
     *
     * @param reason Which test the configured value failed.
     * @param length The resolved override's length, so a truncation is recognisable on sight.
     */
    private static void rejectPromptOnce(PromptRejectionReason reason, Integer length) {
        if (promptRejectionLogged != null) {
            return;
        }
        promptRejectionLogged = reason;

        String diagnosis = reason == PromptRejectionReason.TRUNCATED_AT_OR_BELOW_255
            ? 'it is ' + length + ' characters, at or below the ' + PROMPT_TRUNCATION_BOUNDARY
              + '-character width that getInstance()/getAll() clip a LongTextArea to, so this '
              + 'value is indistinguishable from a TRUNCATED READ rather than a real prompt'
            : 'it is ' + length + ' characters but does NOT contain the token \'json\', which '
              + 'OpenAI requires in \'messages\' to use response_format of type \'json_object\'';

        System.debug(LoggingLevel.ERROR,
            'BROKER PROTECTION REJECTED THE CONFIGURED EXTRACTION PROMPT ['
            + reason + ']: Broker_Protection_Config__mdt.' + BrokerProtectionConfig.RECORD_NAME
            + '.Extraction_Prompt__c was not used because ' + diagnosis
            + '. Falling back to the shipped prompt (LLMExtractionCalloutService.shippedPrompt()), '
            + 'so extraction continues — but the Setup override is being IGNORED. '
            + 'FIX THE RECORD IN SETUP.');
    }

    /**
     * Extract the broker identity, email classification and per-property deal fields from a
     * forwarded broker email.
     *
     * The user message content is built as a list of parts. When `imageBase64` is
     * non-blank an image_url part (a `data:<mime>;base64,<data>` URL) is added first,
     * then the text part carrying the extraction instruction plus `textContent`; when
     * there is no image the content is just the text part. No Authorization header is
     * set here — the platform injects it from the OpenAI_Credential external credential.
     *
     * The response is parsed by LLMExtractionParser, which NEVER throws: an unexpected
     * response shape yields an empty-but-valid result still carrying the raw content, so
     * the D3 tier-1 store is written either way.
     *
     * @param textContent   The forwarded email body text; may be blank. Clipped to
     *                      MAX_INPUT_CHARS before sending.
     * @param imageBase64   Base64 of an optional inline image (e.g. a screenshot of
     *                      the forwarded email); blank/null to send text only.
     * @param imageMimeType MIME type for the image data URL (e.g. 'image/png'); used
     *                      only when `imageBase64` is non-blank.
     * @return The typed extraction. `rawJson` carries the model's content (code fences
     *         removed) for Inbound_Email_Staging__c.Extracted_JSON__c.
     * @throws CalloutException when the OpenAI endpoint returns a non-200 status. The
     *         caller DEGRADES on this rather than failing — an outage is a missing optional
     *         input, not a pipeline failure.
     * @throws JSONException when the OpenAI ENVELOPE itself is unparseable. The caller
     *         degrades on this too (C-14) — see ExtractAddressQueueable's degrade block.
     * @example
     * LLMExtractionResult extraction =
     *     new LLMExtractionCalloutService().extract(emailBody, null, null);
     */
    public LLMExtractionResult extract(String textContent, String imageBase64, String imageMimeType) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(ENDPOINT);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(TIMEOUT_MS);
        request.setBody(buildRequestBody(textContent, imageBase64, imageMimeType));

        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() != 200) {
            throw new CalloutException(
                'OpenAI extraction callout failed: HTTP ' + response.getStatusCode() +
                ' ' + response.getStatus() + ' — ' + response.getBody()
            );
        }

        String rawContent = extractMessageContent(response.getBody());
        return LLMExtractionParser.parse(stripCodeFences(rawContent));
    }

    /**
     * Serialize the chat-completions request body: model, temperature 0 (deterministic),
     * max_tokens, JSON mode, and one user message whose content is the ordered parts list.
     * JSON.serialize handles all escaping of the embedded instruction/email text.
     *
     * `response_format: {"type": "json_object"}` is the single strongest mitigation against
     * the truncation failure described in the class header: OpenAI JSON mode guarantees the
     * content is syntactically valid JSON, which also demotes stripCodeFences from
     * load-bearing to belt-and-braces.
     *
     * ⚠ A dynamic REFERENCE DATE line sits between the instruction and the email text
     * (D4, 2026-08-02) — see referenceDateLine(). It is the only part of this body that
     * is not constant across callouts.
     *
     * @param textContent   Forwarded email body (may be blank); clipped to MAX_INPUT_CHARS.
     * @param imageBase64   Optional base64 image; when non-blank, added as the first
     *                      content part.
     * @param imageMimeType MIME type for the image data URL.
     * @return The serialized JSON request body.
     */
    private String buildRequestBody(String textContent, String imageBase64, String imageMimeType) {
        String clippedText = InboundEmailFieldUtil.clip(textContent, MAX_INPUT_CHARS);
        Map<String, Object> textPart = new Map<String, Object>{
            'type' => 'text',
            'text' => resolvePrompt() + '\n\n' + referenceDateLine() + '\n\n' +
                (clippedText == null ? '' : clippedText)
        };

        List<Object> content = new List<Object>();
        if (String.isNotBlank(imageBase64)) {
            String dataUrl = 'data:' + imageMimeType + ';base64,' + imageBase64;
            content.add(new Map<String, Object>{
                'type' => 'image_url',
                'image_url' => new Map<String, Object>{ 'url' => dataUrl }
            });
        }
        content.add(textPart);

        Map<String, Object> body = new Map<String, Object>{
            'model' => BrokerProtectionConfig.model(),
            'temperature' => BrokerProtectionConfig.temperature(),
            'max_tokens' => BrokerProtectionConfig.maxTokens(),
            'response_format' => new Map<String, Object>{ 'type' => 'json_object' },
            'messages' => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => content }
            }
        };
        return JSON.serialize(body);
    }

    /**
     * The labelled REFERENCE DATE line injected between the instruction and the email
     * text (D4, 2026-08-02).
     *
     * WHY IT EXISTS: the year-less-date rule in the enriched block anchors on the
     * year-bearing "Sent:"/"Date:" line of the forward — but some emails carry no date
     * anywhere (the Orion case). Without an injected anchor the rule is un-actionable for
     * exactly those emails, and a legitimately extractable deadline would be dropped.
     *
     * ⚠ THE GUARD SENTENCE IS THE POINT, NOT DECORATION. Handing a date to a model that
     * is also being asked for `sent_datetime` creates one obvious hazard: it harvests the
     * reference date as the send time — reintroducing the fabricated timestamp this whole
     * change exists to remove, and in a form that looks plausible. The line therefore says
     * outright that it is context only and is never sent_datetime, and that is a named UAT
     * check (case B: `sent_datetime` must still come back empty).
     *
     * AND IF THE GUARD IS IGNORED, THE FORMAT FAILS SAFE — the no-time-component choice is
     * a second line of defence, not only an anti-harvest hint. A harvested `2026-08-02`
     * reaches ExtractAddressQueueable.parseSentDatetime, whose Datetime.valueOfGmt REQUIRES
     * `yyyy-MM-dd HH:mm:ss` and REJECTS a date-only string (verified in usman-dpeg:
     * `System.TypeException: Invalid date/time: 2026-08-02`). Its catch then falls back to
     * Datetime.now() — which for a just-received email is the CORRECT value. So the harvest
     * hazard degrades from plausible-looking fabrication to harmless. Emitting a full
     * timestamp here would forfeit that property.
     *
     * FORMAT: `yyyy-MM-dd` in GMT — ISO, unambiguous, no locale and no time component to
     * be mistaken for a timestamp. Evaluated at RUNTIME, once per callout, so the request
     * body is not constant across calls; `LLMExtractionCalloutServiceTest` asserts on
     * `contains` and an UPPER BOUND on length (`< 80000`), both of which are unaffected.
     *
     * GMT IS DELIBERATE AND MUST NOT BE "FIXED" TO ORG TIME. An email arriving near
     * midnight org-time (say 23:30) gets a REFERENCE DATE one day ahead of the local date.
     * That can only change an outcome when a year-less date sits exactly on the 30-day
     * boundary of the roll-forward rule, and it can only affect offer_due_date — a
     * screening field, never a claim key. Formatting in org time instead would buy that
     * negligible edge at the price of locale dependence and a Setup-changeable timezone
     * silently altering prompt behaviour.
     *
     * @return The labelled reference-date line.
     */
    private static String referenceDateLine() {
        return 'REFERENCE DATE (the date this email was received): ' +
            Datetime.now().formatGmt('yyyy-MM-dd') +
            '. Use it ONLY to resolve a date written without a year. It is NOT a value ' +
            'to extract; it is never sent_datetime.';
    }

    /**
     * Pull `choices[0].message.content` (the model's text) out of the raw response
     * body. Returns an empty string if the response shape is unexpected rather than
     * dereferencing a missing node.
     *
     * @param responseBody The raw OpenAI response JSON.
     * @return The assistant message content, or '' when it cannot be located.
     * @throws JSONException when `responseBody` is not valid JSON at all.
     */
    private String extractMessageContent(String responseBody) {
        if (String.isBlank(responseBody)) {
            return '';
        }
        Object parsed = JSON.deserializeUntyped(responseBody);
        if (!(parsed instanceof Map<String, Object>)) {
            return '';
        }
        Object choicesObj = ((Map<String, Object>) parsed).get('choices');
        if (!(choicesObj instanceof List<Object>)) {
            return '';
        }
        List<Object> choices = (List<Object>) choicesObj;
        if (choices.isEmpty() || !(choices[0] instanceof Map<String, Object>)) {
            return '';
        }
        Object messageObj = ((Map<String, Object>) choices[0]).get('message');
        if (!(messageObj instanceof Map<String, Object>)) {
            return '';
        }
        Object contentObj = ((Map<String, Object>) messageObj).get('content');
        return contentObj == null ? '' : String.valueOf(contentObj);
    }

    /**
     * Strip a leading ```json / ``` fence and a trailing ``` fence that models often
     * wrap JSON in, leaving the bare JSON object. Belt-and-braces since JSON mode was
     * enabled, and retained because it also guarantees Extracted_JSON__c holds parseable
     * JSON rather than a fenced blob.
     *
     * @param raw The model content, possibly fenced.
     * @return The content with surrounding code fences removed and trimmed.
     */
    private String stripCodeFences(String raw) {
        if (String.isBlank(raw)) {
            return '';
        }
        String cleaned = raw.trim();
        cleaned = cleaned.replaceFirst('^```[a-zA-Z]*\\s*', '');
        cleaned = cleaned.replaceFirst('\\s*```\\s*$', '');
        return cleaned.trim();
    }
}
