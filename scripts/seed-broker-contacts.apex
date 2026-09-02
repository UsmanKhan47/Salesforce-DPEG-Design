/**
 * Seed broker Contacts for the Acquisition Broker Hub.
 * Brokers are standard Contacts on the `Contact.Broker` RECORD TYPE.
 *
 * ⚠ CORRECTED 2026-08-20. This line read "Brokers are standard Contacts flagged with
 * Is_Broker__c = true." The broker definition MOVED to the record type; `Is_Broker__c` is
 * retained on Contact but is no longer what makes a Contact a broker. Every query and every
 * insert in this file moved with it — see the 🔴 block immediately below.
 *
 * =====================================================================================
 * 🔴 2026-08-20 — WHAT MOVED IN THIS FILE, AND WHY THE TWO HALVES CANNOT DRIFT APART
 * =====================================================================================
 * STEP 1 builds the `doomed` roster (the scan basis) and STEP 5 deletes it. Those are ONE
 * LIST, not two queries: STEP 5 calls `Database.delete(doomed, false)` on the exact rows
 * STEP 1 selected. That is load-bearing and MUST STAY THAT WAY.
 *
 * If STEP 1 and the delete were ever split back into two independent queries and only one
 * were repointed, this script would scan zero rows, print "SCAN SKIPPED: there are no broker
 * Contacts in this org", pass the STEP 3 abort gate, and then delete the org's REAL broker
 * roster across all EIGHT SetNull lookups — reporting SEED VERDICT: COMPLETE while doing it.
 * The guard would not be broken, it would be INVERTED: an all-clear that is itself the evidence
 * the scan looked at the wrong population.
 *
 * 🔴 NEVER REINTRODUCE A SECOND `[SELECT ... FROM Contact WHERE <broker predicate>]` IN THIS
 * FILE. One predicate, one list, scanned and deleted.
 *
 * STEP 6's inserted roster is stamped with the Broker record type for the same reason: an
 * unstamped seed Contact is no longer a broker, so it would satisfy nothing, be invisible to
 * every broker query, and be REFUSED by SEVEN of the eight broker lookup filters.
 *
 * ⚠ CORRECTED 2026-08-31 (Tranche 1 code review, W-6). Retracted in place rather than bumped,
 * because the replacement is NOT simply the new lookup count and a reader who silently swaps
 * "six" for "eight" would be wrong in the more dangerous direction:
 *
 *     RETRACTED: "be REFUSED by all six broker lookup filters."
 *
 * EIGHT lookups across SEVEN objects point at these Contacts (the inventory is ~50 lines below,
 * and it is already right — this line and the two the review named were the stale ones). But
 * only SEVEN of those eight declare a `<lookupFilter>` at all. `Opportunity.Broker__c` declares
 * NONE — measured 2026-08-31 by grepping `<lookupFilter>` across all eight field files — because
 * it is stamped by `LeadConvertService` rather than typed by a user, so there is no picker to
 * filter. An unstamped seed Contact is therefore refused by seven of them and SILENTLY ACCEPTED
 * by the eighth, which is worse than being refused everywhere: the bad row lands on the one
 * object whose lookup nothing validates. That asymmetry is why the number is worth stating
 * precisely instead of rounding to "all of them".
 *
 * =====================================================================================
 * 🔴 2026-08-31 (Tranche 1 RE-REVIEW, W-4b) — THE FIFTH STALE COUNT, AND THE FIFTH PARTIAL
 *    EDIT. ONE RECORD BLOCK FOR ALL OF THEM, DELIBERATELY.
 * =====================================================================================
 * The staleness note ~100 lines below says a count in this file "has now gone stale on four
 * separate occasions and every one of them was a partial edit, not a missed grep." W-6 earlier
 * the same day corrected the headline, the record-type sentence and `BROKER_LOOKUPS` — and left
 * FOUR OTHER SENTENCES saying five, three or seven. That is occasion number five, by the same
 * mechanism the note predicted, ONE DAY after it was written.
 *
 * Corrected IN PLACE, all four, in one edit, with the dead text recorded HERE rather than in
 * four more scattered blocks — because four separate retractions is how a reader ends up
 * quoting whichever one they hit first:
 *
 *     RETRACTED (this header, ~15 lines up): "delete the org's REAL broker roster across five
 *     SetNull lookups".
 *     RETRACTED (THE GUARD block, STEP 2): "STEP 2 scans all five lookups BEFORE any DML".
 *     RETRACTED (FORCE block): "⚠ FORCE DOES NOT REPAIR THE OTHER THREE FORMULA OBJECTS".
 *     RETRACTED (PRE-FLIGHT GATE, in code): "blanked lookups across all five SetNull fields".
 *
 * THE FIGURE IS EIGHT LOOKUPS ACROSS SEVEN OBJECTS, as the headline below already said. Three of
 * the four were plain arithmetic. The FORCE one was not, and it is the one worth reading:
 * "the other THREE FORMULA objects" was wrong about the KIND, not just the count. There are only
 * TWO formula objects (`Broker_Assignment__c`, `Lease_Inquiry__c`); `Opportunity` carries no
 * denormalised copy at all, and `Broker_Listing__c` — the eighth lookup — carries STORED
 * Text(255) that is not a formula and does not self-heal. FORCE still correctly repairs none of
 * them, but for THREE different reasons, not one. See the corrected paragraph for the split.
 *
 * 🔴 THE STRUCTURAL FIX, NOT JUST THE ARITHMETIC ONE: three of the four sentences never needed a
 * number. They now say "every entry in `BROKER_LOOKUPS`" / "all EIGHT", and `BROKER_LOOKUPS` is
 * named as the authority. A prose count that no test and no compiler can falsify will go stale a
 * sixth time; a pointer to the map cannot. Count from the map.
 *
 * =====================================================================================
 * STEP ORDER — THE RECORD-TYPE GATE RUNS FIRST, BEFORE STEP 1
 * =====================================================================================
 * A PRE-FLIGHT GATE resolves the Contact.Broker record type and aborts if it is missing OR
 * not visible to the operator. It sits ABOVE STEP 1, so the running order is:
 *
 *     PRE-FLIGHT GATE (describe, no SOQL, no DML)
 *       -> STEP 1 roster query -> STEP 2 scan -> STEP 3 decision gate
 *       -> STEP 4 denorm clears -> STEP 5 delete -> STEP 6 seed -> STEP 7 verdict
 *
 * 🔴 THE GATE USED TO SIT IN STEP 6, AFTER THE DELETE, AND THAT WAS A DATA-LOSS BUG (fixed
 * 2026-08-20, code review W1). SOQL DOES NOT FILTER BY RECORD-TYPE VISIBILITY, so an operator
 * who can SEE no Broker record type still selects — and still DELETES — every broker Contact
 * in the org at STEP 5, and only then discovers it cannot re-create them. Aborting late was
 * only ever harmless in the OTHER failure case (record type absent entirely, where STEP 1
 * matches nothing and the delete is a no-op). Do not move the gate back down. The full
 * argument is at the gate itself.
 *
 * Run:  sf apex run --file scripts/seed-broker-contacts.apex --target-org usman-dpeg
 * Then read the SCAN / ORPHAN RISK lines and the final "SEED VERDICT" line.
 *
 * =====================================================================================
 * 🔴 THIS SCRIPT IS DESTRUCTIVE. IT IS REBUILD-ONLY. NEVER RUN IT AGAINST REAL DATA.
 * =====================================================================================
 * STEP 5 below deletes EVERY Contact in the org on the `Contact.Broker` record type — not
 * just the twelve rows this file creates. (⚠ CORRECTED 2026-08-20: read "with
 * Is_Broker__c = true". THE BLAST RADIUS GREW WHEN THE DEFINITION MOVED: measured on
 * `usman-dpeg`, ZERO Contacts carried the checkbox while 19 sat on the Broker record type.
 * This script's delete went from a guaranteed no-op to a 19-row destruction on the same day
 * its predicate changed. That is the single most important consequence of the definition
 * move anywhere in this repo.) Broker Contacts also arrive from other seeds
 * (`seed-broker-assignments.apex`, `seed-lease-inquiries.apex` both create their own, by
 * email) and, in a real org, from a human flagging a genuine broker. This script cannot
 * tell those apart and does not try to.
 *
 * ⚠ CORRECTED 2026-08-20 (BOV broker-contact lookup). The count was FOUR and is now FIVE.
 * Retracted in place rather than edited to a new number, because a reader who has the old
 * count in their head needs to see WHICH entry appeared:
 *
 *     RETRACTED: "FOUR LOOKUPS POINT AT THOSE CONTACTS. ALL FOUR ARE deleteConstraint =
 *     SetNull..."
 *
 * ⚠ CORRECTED AGAIN 2026-08-20 (re-review, same day). Same reason as above — a reader
 * carrying FIVE needs to see what changed, not just a new number:
 *
 *     RETRACTED: "FIVE LOOKUPS POINT AT THOSE CONTACTS. ALL FIVE ARE deleteConstraint =
 *     SetNull, so the delete does not fail — it silently BLANKS the lookup on every
 *     referencing record" (followed by a five-row list that omitted BOV_Broker_Change__c
 *     entirely — Workstream B added it the same day this count was last corrected, and
 *     BROKER_LOOKUPS / STORED_DENORM_TEXT below had not been updated to match).
 *
 * EIGHT LOOKUPS ACROSS SEVEN OBJECTS POINT AT THOSE CONTACTS. ALL EIGHT ARE deleteConstraint =
 * SetNull, so the delete does not fail — it silently BLANKS the lookup on every referencing
 * record:
 *
 *   Disposition__c.Broker__c                 rel. Brokered_Dispositions      🔴 SEE THE NEXT
 *                                             BLOCK
 *   BOV_Submission__c.Broker__c              rel. Brokered_BOV_Submissions   🔴 SEE THE NEXT
 *                                             BLOCK — ADDED 2026-08-20, THE SECOND
 *                                             STORED-TEXT CASE
 *   Broker_Assignment__c.Broker__c           rel. Broker_Assignments
 *   Lease_Inquiry__c.Broker__c               rel. Lease_Inquiries
 *   Opportunity.Broker__c                    rel. Brokered_Opportunities     (the Broker
 *                                             Protection submitting broker, stamped by
 *                                             LeadConvertService)
 *   BOV_Broker_Change__c.Outgoing_Broker__c  rel. Outgoing_Broker_Changes    🔴 SEE THE NEXT
 *                                             BLOCK — ADDED 2026-08-20 (Workstream B), THE
 *                                             THIRD STORED-TEXT CASE, AND THE FIRST OBJECT
 *                                             WITH TWO BROKER LOOKUPS ON ONE ROW
 *   BOV_Broker_Change__c.Incoming_Broker__c  rel. Incoming_Broker_Changes    same object,
 *                                             independent of Outgoing_Broker__c above — a
 *                                             single history row can be orphaned on either
 *                                             field, or both, in the same delete
 *   Broker_Listing__c.Broker__c              rel. Broker_Listings            🔴 ADDED
 *                                             2026-08-31 (Tranche 1 item 5), THE EIGHTH.
 *                                             SEE THE PARAGRAPH IMMEDIATELY BELOW — it is
 *                                             NOT a stored-text case today, and that is a
 *                                             measured fact with an expiry date on it.
 *
 * ⚠ CORRECTED 2026-08-31, same shape as the two corrections above it. The headline three
 * paragraphs up previously read:
 *
 *     RETRACTED: "SEVEN LOOKUPS ACROSS SIX OBJECTS POINT AT THOSE CONTACTS. ALL SEVEN ARE
 *     deleteConstraint = SetNull".
 *
 * It is EIGHT ACROSS SEVEN. Every other word stands: the new field is `deleteConstraint SetNull`
 * like its seven siblings (Restrict is forbidden — see the block below), so the delete still does
 * not fail, it silently BLANKS.
 *
 * 🔴 THE HEADLINE ITSELF WAS LEFT SAYING "SEVEN" FOR A DAY AFTER THIS CORRECTION WAS WRITTEN, AND
 * THAT IS THE FAILURE MODE THIS FILE KEEPS REPEATING (Tranche 1 code review, W-6, 2026-08-31).
 * Three separate corrections now sit in this header and each one was written UNDER the sentence it
 * corrects, so a reader hits the wrong number first and the correction only if they keep going.
 * The headline is now corrected IN PLACE and this block is the record of what it used to say —
 * which is the convention the rest of the repo uses and the one this file should have used the
 * first time. ⚠ If a NINTH lookup ever appears, fix the headline, the record-type sentence at the
 * top of this header, and `BROKER_LOOKUPS` in the SAME edit; a count in this file has now gone
 * stale on four separate occasions and every one of them was a partial edit, not a missed grep.
 *
 * 🔴 `Broker_Listing__c` IS **NOW IN** `STORED_DENORM_TEXT` BELOW — THE CONDITION THIS BLOCK
 * SET OUT WAS MET ON 2026-09-02. The reasoning is retracted in place rather than deleted,
 * because the ARGUMENT it makes is still the right test to apply to the next object; only its
 * ANSWER for this one changed:
 *
 *     RETRACTED: "WHY `Broker_Listing__c` IS **NOT** IN `STORED_DENORM_TEXT` BELOW... the
 *     obvious move is to add it and the obvious move is WRONG TODAY. On `BOV_Submission__c`
 *     those two fields are STAMPED FROM `Broker__c` by `BovSubmissionBrokerStampService`,
 *     which is what makes them a denormalised copy that goes stale when the lookup is
 *     blanked. On `Broker_Listing__c` they are not: `Broker_Firm__c` is copied from
 *     `Disposition__c.Selected_Broker__c` by `DispositionStageEntryService
 *     .openBrokerListings`, `Contact_Name__c` is typed by a human, and Tranche 1 ships the
 *     lookup with NO STAMP SERVICE AT ALL — the field is blank on every auto-created listing.
 *     Listing them here would report text that never named the deleted broker in the first
 *     place, which is a false positive in a guard whose whole value is that its report can be
 *     trusted. ⚠ THE MOMENT A STAMP SERVICE IS ADDED FOR `Broker_Listing__c.Broker__c`, THIS
 *     DECISION INVERTS and both fields belong in `STORED_DENORM_TEXT`."
 *
 * WHAT CHANGED: `BovSubmissionService.replaceSelectedBroker`'s write 3a (Tranche 4 item 5,
 * lookup stamp added 2026-09-02 by code-review S1) now inserts a `Broker_Listing__c` with
 * `Broker__c`, `Broker_Firm__c` and `Contact_Name__c` ALL SET FROM THE SAME SUBMISSION, in one
 * statement. On those rows the two Text fields are a denormalised copy of the Contact in the
 * lookup, exactly as on `BOV_Submission__c`, so a SetNull cascade leaves them naming a broker
 * that no longer exists. That is a stamp in every sense that matters to this guard, even
 * though no `*BrokerStampService` class was created for it — do not read the retracted text's
 * phrase "stamp SERVICE" so literally that the condition never fires.
 *
 * ⚠ THE FALSE-POSITIVE WORRY IN THE RETRACTED TEXT DOES NOT SURVIVE THE CHANGE, AND THAT IS
 * NOT LUCK — IT IS HOW STEP 2 IS BUILT. The scan's WHERE clause is `<lookup> IN :doomedIds`,
 * so a row is only ever reported when its LOOKUP points at a Contact this run would delete.
 * An auto-created listing has `Broker__c` BLANK (nothing but write 3a ever sets it), so it can
 * never enter the result set and its stage-entry-copied `Broker_Firm__c` can never be
 * reported. Every row this entry can report is a row whose text genuinely names the doomed
 * Contact. Nothing about the entry is conditional any more.
 *
 * 🔴 DO NOT "FIX" THIS BY SWITCHING ANY OF THOSE FIELDS TO deleteConstraint = Restrict.
 * That was considered and rejected — see the XML comment in
 * `objects/Disposition__c/fields/Broker__c.field-meta.xml`. Restrict would block
 * legitimate Contact deletion for the whole org and would turn this script's line into a
 * hard failure. That is a different bug, not a fix. THE GUARD BELONGS HERE, IN THE SCRIPT,
 * and STEPS 2-4 below are it.
 *
 * =====================================================================================
 * 🔴 WHY Disposition__c, BOV_Submission__c AND (PARTIALLY) BOV_Broker_Change__c NEED EXTRA
 *    SCRUTINY: STORED TEXT SURVIVES A CASCADE THAT A FORMULA WOULD NOT
 * =====================================================================================
 * ⚠ Title CORRECTED 2026-08-20 (re-review, same day as the count above) to add
 * BOV_Broker_Change__c. RETRACTED: "WHY Disposition__c AND BOV_Submission__c ARE THE SEVERE
 * ONES" — that omitted the third object entirely; see its own paragraph below for why its
 * severity is real but PARTIAL, not identical to the other two.
 *
 * Three of the seven objects fail VISIBLY. `Broker_Assignment__c.Broker_Name__c` /
 * `Broker_Firm__c` / `Broker_Email__c` and `Lease_Inquiry__c.Broker_Name__c` /
 * `Broker_Firm__c` are FORMULA fields over `Broker__r.*` (measured, not assumed — read
 * their field-meta.xml), so when the lookup is nulled they evaluate to blank in the same
 * instant. The page goes empty and a human can see that something was lost.
 * `Opportunity.Broker__c` has no denormalised copy at all.
 *
 * ⚠ COUNT CORRECTED 2026-08-31 (Tranche 1 code review, W-6). RETRACTED: "Three of the six
 * objects fail VISIBLY." The denominator moved to SEVEN with `Broker_Listing__c`; the NUMERATOR
 * did not, and that is the part worth stating rather than a silent bump.
 *
 * ⚠ AND CORRECTED AGAIN 2026-09-02, WHICH IS THE PREDICTED MOVE ACTUALLY HAPPENING. The line
 * below said what would trigger it and it triggered:
 *
 *     RETRACTED: "`Broker_Listing__c` is in neither camp: it has no stamp service, so a
 *     SetNull there leaves behind NO text naming the deleted broker (see the paragraph
 *     above), and it therefore fails neither visibly nor corruptingly — it just quietly loses
 *     the link. 3 visible + 3 severe stored-text (Disposition__c, BOV_Submission__c,
 *     BOV_Broker_Change__c) + 1 neither = 7. 🔴 IF A STAMP SERVICE IS EVER ADDED FOR
 *     `Broker_Listing__c.Broker__c`, IT MOVES INTO THE SEVERE GROUP, not the visible one, and
 *     this arithmetic becomes 3 + 4 + 0."
 *
 * `BovSubmissionService.replaceSelectedBroker`'s write 3a now stamps the lookup alongside both
 * Text fields (code-review S1), so `Broker_Listing__c` IS in the severe stored-text camp and
 * the arithmetic IS 3 visible + 4 severe stored-text (Disposition__c, BOV_Submission__c,
 * BOV_Broker_Change__c, Broker_Listing__c) + 0 neither = 7.
 * ⚠ ITS SEVERITY IS PARTIAL, LIKE `BOV_Broker_Change__c`'S AND FOR A DIFFERENT REASON: only
 * listings APPENDED BY A BROKER CHANGE carry the lookup at all, so a SetNull cascade corrupts
 * those and merely no-ops on every auto-created listing. Partial is still severe — a corrupted
 * row that reads as healthy is the failure mode this whole block is about, and one is enough.
 * 🔴 IT IS NOT IN `FORCE_CLEARS_DENORM` AND MUST NOT BE ADDED THERE. Same call as
 * `BOV_Submission__c` and `BOV_Broker_Change__c`: those two Text fields are what the Active
 * Listing card RENDERS, so blanking them from a script would replace a wrong-but-diagnosable
 * row with an empty one, and the report already names every affected row.
 *
 * `Disposition__c.Selected_Broker__c` IS DIFFERENT. It is a STORED Text(255) that
 * `DispositionBrokerStampService` writes from the lookup — a real value on the row, not a
 * derivation. A SetNull cascade blanks `Broker__c` and LEAVES THAT TEXT BEHIND. The
 * disposition then still displays the vanished broker's name in the highlights panel, in
 * the `Broker Selection` Path step, on the `Broker_Selection_Approval` page and in every
 * report — while `DispositionApprovalService` (line ~266, `disposition.Broker__c == null`)
 * refuses Submit for Approval with a message about choosing a broker that names a broker
 * the page is already showing. Corruption that reads as health, and the reason this guard
 * exists rather than a note in a runbook.
 *
 * 🔴 `BOV_Submission__c` IS THE SAME SHAPE, ONLY WORSE, AND IT NEEDS **TWO** FIELDS.
 * `Broker_Firm__c` and `Contact_Name__c` are BOTH stored Text(255), both stamped from the
 * lookup by `BovSubmissionBrokerStampService` since 2026-08-20. Worse than the Disposition
 * case for two reasons:
 *   1. `Broker_Display__c` is a FORMULA over BOTH stored texts
 *      (`Broker_Firm__c & " — " & Contact_Name__c`). A formula normally self-heals; this one
 *      cannot, because its inputs are stored. So the comparison matrix keeps rendering a
 *      deleted broker's firm AND name with nothing anywhere to notice.
 *   2. `BovSubmissionTriggerHandler` copies `Broker_Firm__c` VERBATIM onto
 *      `Disposition__c.Selected_Broker__c` on approval, so a stale firm can propagate to a
 *      SECOND object after the broker is already gone.
 *
 * 🔴 `BOV_Broker_Change__c` ADDS A THIRD CASE — ADDED 2026-08-20 (Workstream B) — AND IT IS
 * ONLY PARTIALLY MITIGATED, NOT ELIMINATED, BY ITS TWO FIRM SNAPSHOTS. Do not read the
 * paragraph below as "so it's fine": it is better than the other two in one specific way and
 * no better in another.
 * `Outgoing_Broker_Firm__c` and `Incoming_Broker_Firm__c` are BOTH stored Text(255), stamped
 * by `BovSubmissionService.replaceSelectedBroker` at write time from whichever Contact was
 * chosen in the matching lookup (`objects/BOV_Broker_Change__c/fields/Outgoing_Broker_Firm__c
 * .field-meta.xml` and its Incoming sibling). THE MITIGATING PART: because that firm text is
 * stamped, a SetNull cascade blanking `Outgoing_Broker__c` / `Incoming_Broker__c` leaves the
 * firm name — the part a reader scans for first — intact on the row, unlike a formula field
 * on `Broker_Assignment__c` / `Lease_Inquiry__c` going visibly blank. THE PART THAT IS NOT
 * MITIGATED: this object is an append-only AUDIT LOG of who replaced whom (see
 * `objects/BOV_Broker_Change__c/BOV_Broker_Change__c.object-meta.xml`), and a nulled lookup
 * on an audit row means that row can no longer be navigated to the Contact it names, even
 * though the firm text still reads correctly — the row stops lying about WHICH FIRM and
 * starts silently losing WHETHER THE PERSON IT NAMES IS STILL REACHABLE FROM IT. That is why
 * this object is SCANNED AND REPORTED below alongside the other two, not treated as safe.
 *
 * ⚠ BUT THE REMEDY IS NOT THE SAME FOR ALL THREE — SEE `FORCE_CLEARS_DENORM` BELOW. On
 * Disposition the text is a DERIVED DISPLAY COPY and blanking it makes the record honest. On
 * BOV_Submission and BOV_Broker_Change__c the text IS ENTERED OR AUDITED DATA — respectively
 * the firm and person who actually bid, entered by an analyst, and the firm snapshot on a
 * completed broker-replacement history row — not a derivation. BOV_Broker_Change__c in
 * particular exists so that history CANNOT be rewritten: both permission sets granting it
 * (`DPEG_Disposition_View`, `DPEG_Disposition_Edit`) give every field `readable=true` and
 * NO field `editable=true`, and the object's own `allowEdit` is `false` in both — a FORCE run
 * blanking its stored text via `Database.update` would be rewriting an audit trail that the
 * declarative security model deliberately makes un-rewritable through the UI. Blanking either
 * object's stored text to repair a broken lookup would destroy or alter a historical record in
 * order to tidy a display. This script therefore SCANS AND REPORTS BOV_Submission__c and
 * BOV_Broker_Change__c and DOES NOT CLEAR EITHER.
 *
 * ⚠ THE PREMISE, STATED SO IT CAN BE CHALLENGED: "the stored text survives" is a claim
 * that a SetNull cascade does NOT fire `DispositionTrigger`, and therefore never reaches
 * `DispositionBrokerStampService`, whose null-broker branch would otherwise clear the text
 * for us. This script does not depend on that claim being true. STEP 4 replaces the
 * cascade with an EXPLICIT `Database.update`, which unambiguously does fire the trigger;
 * if the cascade fired it too, STEP 4 is a harmless no-op that writes null over null.
 *
 * =====================================================================================
 * THE GUARD (requirements 2.6 / risk R1, part 1 of the three-part mitigation)
 * =====================================================================================
 * STEP 2 scans EVERY entry in `BROKER_LOOKUPS` BEFORE any DML and reports every record that
 * would be orphaned, by name, with the broker it points at and — for Disposition and
 * BOV_Submission — every stale stored text that would be left behind, field by field.
 * ⚠ CORRECTED IN PLACE 2026-08-31 (Tranche 1 RE-REVIEW, W-4b). The sentence above still said
 * "all five lookups" for a day after the correction below was written — the correction was
 * added UNDER the stale sentence instead of replacing it, which is the exact failure this
 * file's staleness note describes. The number is gone rather than bumped, on the reasoning
 * already given below. Dead text recorded in the W-4b block in the header.
 * ⚠ CORRECTED 2026-08-31 (Tranche 1 item 5). "all five lookups" is retracted rather than
 * silently bumped, because a reader carrying FIVE needs to see that it has now moved twice
 * more: it was already SEVEN before this change (the 2026-08-20 re-review added
 * BOV_Broker_Change__c's two), and `Broker_Listing__c.Broker__c` makes it EIGHT ACROSS SEVEN
 * OBJECTS. 🔴 THE NUMBER IS THE PART THAT KEEPS DECAYING AND THE SENTENCE NEVER NEEDED IT.
 * What is load-bearing is that STEP 2 scans EVERY entry in `BROKER_LOOKUPS` — read that map,
 * do not count from this paragraph.
 *
 * STEP 3 then ABORTS with zero DML if the scan found anything, unless FORCE = true.
 *
 * ⚠ THE SCAN BINDS TO THE CONTACTS ACTUALLY BEING DELETED (`WHERE Broker__c IN :doomedIds`),
 * NOT `!= null`. Two reasons, and both matter:
 *   - `Opportunity.Broker__c` carries NO lookup filter, so most of its values are ordinary
 *     Contacts this script never touches. `!= null` would report them as at-risk and the
 *     guard would cry wolf on every run until nobody read it.
 *   - A lookup filter is enforced at EDIT time only, so a row pointing at a Contact that
 *     was un-flagged after the pick is genuinely not at risk. Binding gets that right.
 *
 * ⚠ ON-MARKET ROWS ARE STRUCTURALLY OUT OF SCOPE AND ARE NEVER TOUCHED. `Selected_Broker__c`
 * is written on the on-market path too, and those rows leave `Broker__c` NULL. Because the
 * scan keys on the LOOKUP, such a row is never selected, never reported and never cleared.
 *
 * 🔴 CORRECTED 2026-08-20 — THE MIDDOT WAS MISATTRIBUTED. The sentence is quoted and
 * retracted IN PLACE rather than deleted, because it named the wrong writer and a future
 * reader chasing the middot would otherwise go and read the BOV classes for a format they
 * do not produce:
 *
 *     RETRACTED: "...by the BOV chain (`BovSubmissionTriggerHandler` / `BovSubmissionService`),
 *     in a DIFFERENT format — firm-only with a U+00B7 middot, e.g. `CBRE · Mark Chen`..."
 *
 * TWO THINGS WERE WRONG WITH IT, AND THE SECOND IS VISIBLE ON ITS OWN FACE. First, the
 * attribution: the BOV chain has never written a middot. `BovSubmissionTriggerHandler` (the
 * `brokerByDisposition` stamp) and `BovSubmissionService.replaceSelectedBroker` both assign
 * `BOV_Submission__c.Broker_Firm__c` VERBATIM AND ALONE — one field, no concatenation, no
 * separator, no person. Second, the sentence contradicted itself: "firm-only" cannot be
 * illustrated by `CBRE · Mark Chen`, which names a person.
 *
 * THERE ARE THREE FORMATS IN `Selected_Broker__c`, NOT TWO. Anything reasoning about this
 * field needs all three:
 *
 *   1. `Firm`            e.g. `CBRE`
 *                        WRITER: the on-market BOV chain — `BovSubmissionTriggerHandler`
 *                        (approved-selection stamp) and `BovSubmissionService
 *                        .replaceSelectedBroker`. Copied straight from
 *                        `BOV_Submission__c.Broker_Firm__c`. THIS is the real live on-market
 *                        format.
 *   2. `Firm · Person`   e.g. `CBRE · Mark Chen`  (U+00B7 middot)
 *                        WRITER: THE DISPOSITION SEED SCRIPTS, AND NOTHING ELSE IN THE ORG —
 *                        `scripts/seed-disposition.apex:38`,
 *                        `scripts/seed-disposition-bulk.apex:68,75,80`,
 *                        `scripts/seed-disp0002.apex:8`. It is a hand-typed literal in a
 *                        fixture, never produced by any deployed class, and it is not a format
 *                        any code path can generate. Treat it as demo residue.
 *   3. `Person - Firm`   e.g. `Dana Pierce - JLL`  (spaced hyphen)
 *                        WRITER: `DispositionBrokerStampService`, off-market only, stamped
 *                        from `Disposition__c.Broker__c` in before-context.
 *
 * ⚠ AND THE SEED LITERALS ARE NOT EVEN CONSISTENT WITH THE ROSTER THIS FILE CREATES —
 * `seed-disp0002.apex` writes `Marcus & Millichap · Dana Pierce` while STEP 6 below seeds
 * Dana Pierce at CBRE. That is not a bug to chase; it is the sharpest available argument for
 * the standing rule that NO CONSUMER MAY PARSE `Selected_Broker__c`.
 *
 * (Measured on usman-dpeg 2026-08-20: exactly three rows carry format 2 — DISP-0006,
 * DISP-0007, DISP-0008 — all On_Market, all with a null `Broker__c`. This script must leave
 * all three exactly as they are, and it does.)
 * 🔴 THAT IS WHY STEP 4 CLEARS ONLY ROWS THE SCAN RETURNED. A blanket
 * "clear Selected_Broker__c" would destroy the on-market stamp, which no broker
 * Contact delete can harm.
 *
 * =====================================================================================
 * FORCE — WHAT IT DOES, AND WHY IT IS NOT MERELY "IGNORE THE WARNING"
 * =====================================================================================
 * FORCE = true proceeds through a non-empty scan. It does NOT simply let the silent
 * cascade happen: STEP 4 first NULLS `Broker__c` AND `Selected_Broker__c` together, on the
 * scanned Disposition rows only, in one explicit logged `Database.update`. So the destruction
 * still occurs, but the record ends HONEST (blank lookup, blank text, approval gate correctly
 * refusing) instead of LYING (blank lookup, stale text, approval gate refusing a record
 * that looks complete).
 *
 * `Selected_Broker__c` is set explicitly rather than left to the trigger on purpose. The
 * trigger's clear-branch is the deployed behaviour and would normally do it, but this
 * script runs in rebuild orgs where `DispositionBrokerStampService` may not be deployed
 * yet — and "the guard works only if some other class is deployed" is exactly the failure
 * mode a guard must not have. Writing both fields costs nothing and removes the dependency.
 *
 * ⚠ FORCE DOES NOT REPAIR THE OTHER FOUR OBJECTS EITHER, DELIBERATELY — BUT FOR THREE
 * DIFFERENT REASONS, NOT ONE. Corrected in place 2026-08-31 (Tranche 1 RE-REVIEW, W-4b);
 * this read "THE OTHER THREE FORMULA OBJECTS ... Their denormalised fields are formulas (see
 * above) and re-derive to blank on their own", which was wrong about the KIND as well as the
 * count, and the kind is the part that would have misled someone adding an entry:
 *   - `Broker_Assignment__c` and `Lease_Inquiry__c` — the only TWO formula objects. Their
 *     denormalised fields re-derive to blank on their own; there is nothing stored to correct,
 *     and an update on them would be DML that changes no observable state.
 *   - `Opportunity` — no denormalised copy of any kind. Nothing to repair, nothing to go stale.
 *   - `Broker_Listing__c` — the EIGHTH lookup, added by Tranche 1, and NOT a formula object.
 *     `Broker_Firm__c` / `Contact_Name__c` are STORED Text(255), so they do NOT self-heal. It
 *     is excluded because Tranche 1 ships no stamp service for `Broker__c`, so that text never
 *     named the deleted broker in the first place — the full argument is in this header's
 *     `Broker_Listing__c` paragraph. 🔴 IF A STAMP SERVICE IS ADDED, THIS ENTRY MOVES: it
 *     becomes a stored-text case like Disposition and BOV, and the decision is then whether to
 *     clear it, not whether it self-heals. It never self-heals.
 *
 * 🔴 FORCE ALSO DOES NOT CLEAR `BOV_Submission__c`, AND THAT IS A DIFFERENT DECISION FROM
 * THE PARAGRAPH ABOVE — NOT AN OVERSIGHT AND NOT AN INHERITANCE OF IT. Those two fields ARE
 * stored, they DO go stale, and the scan reports them by name for exactly that reason. They
 * are left alone because of WHAT THEY ARE, not what type they are:
 *
 *   - THE TEXT IS ENTERED DATA, NOT A DERIVATION. It is the firm and the person who
 *     submitted a BOV — the "Broker Firm" and "Contact" columns of the comparison matrix,
 *     and, on rows created before 2026-08-20, values a human typed with no lookup at all.
 *     Blanking them destroys the record of who bid. Blanking `Selected_Broker__c` destroys
 *     a display copy that `Broker__c` can regenerate.
 *   - THE ROWS MAY BE LOCKED ANYWAY. `Broker_Finalize_Approval` sets
 *     `recordEditability = AdminOnly`, so a submitted submission would refuse the update
 *     with ENTITY_IS_LOCKED and the "repair" would be partial by construction.
 *   - A NAMED ORPHAN RISK LINE PER ROW IS THE DELIVERABLE HERE. An analyst reading it can
 *     decide per record; this script cannot, and a script that silently deletes evidence to
 *     keep a display tidy is worse than the stale display.
 *
 * ⚠ THE LOOKUP IS STILL BLANKED ON THOSE ROWS — by the SetNull cascade in STEP 5, which no
 * decision here can prevent. So a forced run leaves BOV_Submission rows in the LYING state
 * (blank lookup, stale text) ON PURPOSE, with every one of them named in the log. That is
 * the trade, stated plainly rather than buried: evidence preserved, display stale, both
 * visible. If that is ever judged the wrong trade, the change is to add 'BOV_Submission__c'
 * to `FORCE_CLEARS_DENORM` below — one line, and the shape already supports it.
 *
 * =====================================================================================
 * PREVIEW_ONLY DEFAULTS TO **false** HERE — A DELIBERATE DIVERGENCE FROM THE REPAIR SCRIPTS
 * =====================================================================================
 * `scripts/repair-onmarket-nda-baseline.apex` defaults PREVIEW_ONLY to true, and that is
 * right FOR A REPAIR SCRIPT: it writes to live data, and reading its plan must not require
 * having already executed it.
 *
 * This is a REBUILD SEED. Its entire purpose is to write, it is invoked from rebuild
 * runbooks, and defaulting it to preview would introduce a NEW silent failure — a fresh
 * scratch org that seeds nothing and reports success. The safety that PREVIEW_ONLY buys a
 * repair script is bought here by a STRONGER mechanism that cannot be forgotten: the scan
 * in STEP 2 always runs, and STEP 3 aborts by itself whenever the destructive case is real.
 * PREVIEW_ONLY is retained as an on-demand audit switch ("what would this cost me right
 * now?"), not as the default posture.
 *
 * =====================================================================================
 * NO WITH USER_MODE, AND A NOTE ON WHAT THIS SCRIPT COMPILES AGAINST
 * =====================================================================================
 * ARCHITECTURE.md §2 mandates `WITH USER_MODE` for SELECTOR CLASSES in force-app. This is
 * anonymous Apex run by an administrator, is not part of the deployed codebase and is not a
 * selector; the surrounding scripts/ files follow the same convention. USER_MODE here would
 * only add a way for the guard itself to throw on a field the running admin lacks FLS on —
 * which, for a Metadata-API-deployed field, is the default state.
 *
 * 🔴 THE SCAN IS DESCRIBE-GUARDED AND DYNAMIC ON PURPOSE. Anonymous Apex compiles against
 * the ORG's schema, not this repo.
 *
 * ⚠ CORRECTED 2026-08-20 — THE PREMISE SHIPPED. Retracted in place so the sentence cannot be
 * read as current fact:
 *
 *     RETRACTED: "`Disposition__c.Broker__c` HAS NOT DEPLOYED YET as of 2026-08-20"
 *
 * It IS deployed on usman-dpeg. THE DESIGN DECISION IT JUSTIFIED IS UNCHANGED AND MUST NOT BE
 * "simplified" back to static SOQL, because the argument never depended on that field being
 * undeployed in ONE org — it depends on this script being REBUILD-ONLY and therefore expected
 * to run against fresh scratch orgs where the §4 metadata has not landed yet. A static
 * `SELECT Broker__c FROM Disposition__c` would fail to COMPILE there and take THE WHOLE SEED
 * DOWN WITH IT: the guard would break the very script it protects, in exactly the orgs where
 * it has nothing to protect. Every lookup is therefore resolved through
 * `Schema.getGlobalDescribe()` and queried via `Database.query`, and an absent object or field
 * is reported and skipped rather than thrown.
 *
 * ROLLBACK: none. A deleted Contact and a nulled lookup are not recoverable from here
 * (the Contacts land in the Recycle Bin, but the lookups do NOT re-point on undelete).
 * That asymmetry is the whole argument for the guard.
 */

// ── PREVIEW_ONLY: true = run the scan, print the full report, then RETURN before any DML.
//    Defaults to FALSE. See the header for why this differs from the repair scripts.
final Boolean PREVIEW_ONLY = false;

// ── FORCE: true = proceed even though the scan found referencing records, clearing the
//    stored Disposition text alongside the lookup (STEP 4) so nothing is left lying.
//    Defaults to FALSE. Flip it only after reading every ORPHAN RISK line.
final Boolean FORCE = false;

// ── Every lookup that points at a broker Contact, object API -> lookup field API(s).
//    🔴 IF ANOTHER Contact LOOKUP IS EVER ADDED, ADD IT HERE. Nothing maintains this list
//    automatically, and a missing entry means that object is orphaned silently — the exact
//    failure this whole file exists to prevent.
//    ⚠ CORRECTED 2026-08-20: this banner said "IF A FIFTH ... IS EVER ADDED" and the line
//    below it asserted "The four below are the complete set in this repo as of 2026-08-20".
//    A fifth WAS added the same day — BOV_Submission__c.Broker__c — so both statements are
//    retracted and replaced. The FIVE below are the complete set as of 2026-08-20
//    (`grep -rl "<referenceTo>Contact</referenceTo>" objects/`). Re-run that grep before
//    trusting this list; a date on a comment is not a measurement.
//    ⚠ CORRECTED AGAIN 2026-08-20 (re-review, same day). Retracted, not silently bumped to
//    "SIXTH", because the correction is not just a new count — it is a SHAPE change:
//
//        RETRACTED: "🔴 IF A SIXTH Contact LOOKUP IS EVER ADDED, ADD IT HERE... The FIVE
//        below are the complete set as of 2026-08-20" — followed by
//        `Map<String, String> BROKER_LOOKUPS` holding exactly one field API per object.
//
//    Workstream B added BOV_Broker_Change__c the same day with TWO Contact lookups on ONE
//    object — Outgoing_Broker__c and Incoming_Broker__c — which `Map<String, String>` cannot
//    express for a single key without dropping one of them, the exact "force one field in
//    and lose the other silently" failure STORED_DENORM_TEXT's own header already warns
//    against a few lines below. The value type therefore changes to `List<String>`, matching
//    STORED_DENORM_TEXT's existing shape, and STEP 2 / STEP 4 below are rewritten to iterate
//    every lookup field an object declares rather than assume exactly one.
//    [SUPERSEDED — THE NEXT PARAGRAPH RETRACTS THE SENTENCE THAT FOLLOWS. IT IS LEFT VERBATIM
//    BECAUSE IT IS QUOTED VERBATIM THERE.] SEVEN lookup
//    fields across SIX objects are the complete set as of 2026-08-20 — re-run the grep above
//    before trusting this list; a date on a comment is not a measurement.
//    ⚠ CORRECTED AGAIN 2026-08-31 (Tranche 1 item 5). Retracted rather than bumped, for the
//    third time in this comment, because the correction carries a fact the number does not:
//
//        RETRACTED: "SEVEN lookup fields across SIX objects are the complete set as of
//        2026-08-20".
//
//    `Broker_Listing__c.Broker__c` was created by Tranche 1 and is the EIGHTH, across SEVEN
//    objects. 🔴 IT IS A PURE ADDITION — no shape change was needed, unlike the 2026-08-20
//    correction, because this object declares exactly one Contact lookup.
//    🔴 THE FIELD MAY NOT BE DEPLOYED YET WHEN THIS SCRIPT RUNS, AND THAT IS HANDLED, NOT
//    IGNORED. Tranche 1's deploy order puts the schema wave ahead of this script, but a
//    rebuild org can be part-way through: STEP 2 describes every declared field individually
//    and routes a missing one into `notInThisOrg` rather than failing the run (that
//    per-field check was itself added on 2026-08-20 for exactly this reason). So adding the
//    entry now is safe in an org that does not yet have the field, and is REQUIRED in one
//    that does — the delete blanks it either way, silently, with no error.
//    ⚠ Re-run `grep -rl "<referenceTo>Contact</referenceTo>" objects/` before trusting THIS
//    list too. A date on a comment is still not a measurement.
final Map<String, List<String>> BROKER_LOOKUPS = new Map<String, List<String>>{
    'Disposition__c'       => new List<String>{ 'Broker__c' },
    'BOV_Submission__c'    => new List<String>{ 'Broker__c' },
    'Broker_Assignment__c' => new List<String>{ 'Broker__c' },
    'Lease_Inquiry__c'     => new List<String>{ 'Broker__c' },
    'Opportunity'          => new List<String>{ 'Broker__c' },
    'BOV_Broker_Change__c' => new List<String>{ 'Outgoing_Broker__c', 'Incoming_Broker__c' },
    // 🔴 ADDED 2026-08-31 (Tranche 1 item 5).
    // ⚠ AMENDED 2026-09-02. RETRACTED: "Deliberately absent from STORED_DENORM_TEXT below —
    // its Broker_Firm__c / Contact_Name__c are NOT stamped from this lookup today." They now
    // ARE, on listings appended by BovSubmissionService.replaceSelectedBroker's write 3a, and
    // the object HAS an entry in STORED_DENORM_TEXT below. Full argument in this file's header.
    'Broker_Listing__c'    => new List<String>{ 'Broker__c' }
};

// ── Objects carrying STORED (non-formula) denormalised copies of the broker, which a
//    SetNull cascade does NOT clear and which therefore keep naming a deleted broker.
//    These are SCANNED AND REPORTED. Whether FORCE may also BLANK them is a SEPARATE
//    question answered by FORCE_CLEARS_DENORM below — the two are deliberately not the
//    same list.
//
// 🔴 CORRECTED 2026-08-20. THE ASSERTION BELOW WAS TRUE WHEN WRITTEN AND IS NOW FALSE. It
//    is retracted in place, because it was a MEASUREMENT and a future reader needs to know
//    that the measurement was re-taken rather than that someone disagreed with it:
//
//        RETRACTED: "🔴 DISPOSITION IS THE ONLY ENTRY, AND THAT IS A MEASURED FACT, NOT AN
//        OMISSION. Broker_Assignment__c.Broker_Name__c / Broker_Firm__c / Broker_Email__c
//        and Lease_Inquiry__c.Broker_Name__c / Broker_Firm__c are all FORMULA fields over
//        Broker__r.*, so they self-heal to blank; Opportunity has no copy. Adding any of
//        them here would be an update that changes nothing."
//
//    WHAT STAYS TRUE: every clause about Broker_Assignment__c, Lease_Inquiry__c and
//    Opportunity. Those three are still formulas or nothing, still self-heal, and still must
//    NOT be added here.
//    WHAT BECAME FALSE: "Disposition is the ONLY entry". BOV_Submission__c.Broker_Firm__c
//    and Contact_Name__c are stored Text(255) stamped by BovSubmissionBrokerStampService
//    (2026-08-20), so there were TWO objects with stored copies AT THAT POINT — THREE in the
//    map today, the third added in the paragraph immediately below, and a FOURTH
//    (Broker_Listing__c) deliberately excluded for the reason given in the header. Count the
//    map, not this sentence. ("there are now TWO" corrected in place 2026-08-31, W-4b.)
//    BOV needs TWO FIELDS, which is why the value type here is List<String> and no longer
//    String. That shape change is the whole reason this is not a one-line edit.
//    ⚠ CHECKED AGAIN 2026-08-20 (re-review, same day) FOR BOV_Broker_Change__c, WHICH ALSO
//    NEEDS TWO FIELDS (Outgoing_Broker_Firm__c, Incoming_Broker_Firm__c — both stored
//    Text(255), both stamped by BovSubmissionService.replaceSelectedBroker). Unlike
//    BROKER_LOOKUPS above, NO SHAPE CHANGE WAS NEEDED HERE: this map was already
//    `Map<String, List<String>>` and can hold two field APIs under one object key without
//    modification. The entry below is therefore a pure addition.
//
// 🔴 FOURTH ENTRY ADDED 2026-09-02 — Broker_Listing__c. The sentence six lines up that called
//    it "a FOURTH (Broker_Listing__c) deliberately excluded for the reason given in the header"
//    is RETRACTED; the header's own condition ("the moment a stamp is added for
//    Broker_Listing__c.Broker__c, this decision INVERTS") was met by
//    BovSubmissionService.replaceSelectedBroker's write 3a, which since code-review S1 sets
//    Broker__c, Broker_Firm__c and Contact_Name__c from ONE submission in ONE statement. On
//    those rows the two Text fields are a denormalised copy of the Contact in the lookup and a
//    SetNull cascade strands them naming a deleted broker.
//    ⚠ NO FALSE POSITIVES FROM AUTO-CREATED LISTINGS: STEP 2 only ever selects rows whose
//    LOOKUP is in :doomedIds, and an auto-created listing's Broker__c is blank, so it cannot
//    enter the result set. Read the header block before shortening this to a one-liner.
//    ⚠ AND STILL NOT IN FORCE_CLEARS_DENORM below — scanning and clearing are separate
//    decisions and only the scan changed.
final Map<String, List<String>> STORED_DENORM_TEXT = new Map<String, List<String>>{
    'Disposition__c'       => new List<String>{ 'Selected_Broker__c' },
    'BOV_Submission__c'    => new List<String>{ 'Broker_Firm__c', 'Contact_Name__c' },
    'BOV_Broker_Change__c' => new List<String>{ 'Outgoing_Broker_Firm__c', 'Incoming_Broker_Firm__c' },
    'Broker_Listing__c'    => new List<String>{ 'Broker_Firm__c', 'Contact_Name__c' }
};

// ── Of the objects above, the ones whose stored text the FORCE path may BLANK in STEP 4.
//    🔴 SCANNING AND CLEARING ARE DIFFERENT DECISIONS AND THIS SET IS WHERE THEY SEPARATE.
//    Disposition__c is here because Selected_Broker__c is a DERIVED DISPLAY COPY — blanking
//    it makes the record honest and Broker__c can regenerate it.
//    BOV_Submission__c is DELIBERATELY ABSENT because its two fields are the broker's
//    RESPONSE DATA (who bid, and at what firm), not a derivation — see the FORCE block in
//    the header for the full argument, including the ENTITY_IS_LOCKED problem a clear would
//    hit on any submitted submission. Its rows are still SCANNED and every one is REPORTED
//    by name with its stale values; they are simply not written to.
//    ⚠ ADDED 2026-08-20 (re-review, same day): BOV_Broker_Change__c IS ALSO DELIBERATELY
//    ABSENT, for a related but distinct reason. It is an append-only AUDIT LOG of who
//    replaced whom (see the object header), and both permission sets granting it
//    (DPEG_Disposition_View, DPEG_Disposition_Edit) give every field readable=true and NO
//    field editable=true, with the object's own allowEdit false in both — the declarative
//    security model deliberately makes this object un-rewritable through the UI. A FORCE run
//    blanking its stored firm text via Database.update would rewrite that audit trail from
//    a script, defeating the reason the object is read-only in the first place. Its rows are
//    still SCANNED and every one is REPORTED by name with both stale firm values; they are
//    simply not written to. The damage is PARTIALLY mitigated — the firm text survives the
//    cascade and keeps reading correctly — but not eliminated, because the lookup itself
//    still goes blank and the row can no longer be navigated to the Contact it names.
//    ⚠ Adding an object here without its entry in STORED_DENORM_TEXT above does nothing —
//    STEP 4 iterates the fields that were actually selected.
final Set<String> FORCE_CLEARS_DENORM = new Set<String>{ 'Disposition__c' };

// ── Bounds. This is a demo-seed guard, not a data-migration tool.
final Integer SCAN_LIMIT = 5000;
final Integer MAX_LOG_ROWS_PER_OBJECT = 25;

// ═════════════════════════════════════════════════════════════════════════════════════
// PRE-FLIGHT GATE. The Contact.Broker record type must resolve BEFORE anything else runs.
// ═════════════════════════════════════════════════════════════════════════════════════
// 🔴 MOVED HERE 2026-08-20 (code review W1). This describe-and-abort used to sit down in STEP 6,
// which placed it AFTER STEP 5's destructive delete. The two failure paths are NOT symmetric, and
// the dangerous one is not the one the old comment anticipated:
//
//   • Record type ABSENT from the org -> STEP 1's `WHERE RecordType.DeveloperName = 'Broker'`
//     matches 0 rows -> the delete is a no-op -> aborting late was harmless. This is the case the
//     old placement survived, which is exactly why it looked safe.
//
//   • 🔴 Record type PRESENT but NOT `isAvailable()` TO THE OPERATOR -> SOQL DOES NOT FILTER BY
//     RECORD-TYPE VISIBILITY, so STEP 1 still matches every broker Contact in the org, STEP 5
//     DELETES THEM ALL, and only then does the script discover it cannot re-create them. The org
//     is left with ZERO brokers and blanked lookups across every field in `BROKER_LOOKUPS` —
//     all EIGHT of them, across seven objects — unrecoverably. ("all five SetNull fields"
//     corrected in place 2026-08-31, Tranche 1 RE-REVIEW W-4b; see the W-4b block in the header.)
//     An UNDER-PROVISIONED OPERATOR — not a missing record type — is what turned this script into
//     data loss, and that is the case the old placement did NOT survive.
//
// The gate depends on NOTHING that STEPS 1-5 produce and costs no SOQL, so there was never a
// reason for it to run late. Both sibling seeds already do it this way: seed-broker-assignments
// .apex and seed-lease-inquiries.apex each place the identical describe-and-abort above their
// first DML. This file was the outlier.
//
// A DESCRIBE, NOT A QUERY — the same pattern seed-disposition.apex uses for its own record type:
// `[SELECT Id FROM RecordType WHERE ...].Id` throws QueryException in an org where the record type
// has not deployed yet, which would take the script down with an uncatchable exception instead of
// the legible abort below.
// ⚠ `brokerRtId` stays in scope for STEP 6's insert, which is its only consumer.
Schema.RecordTypeInfo brokerRtInfo =
    Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName().get('Broker');
Id brokerRtId = (brokerRtInfo != null && brokerRtInfo.isAvailable())
    ? brokerRtInfo.getRecordTypeId()
    : null;
if (brokerRtId == null) {
    // 🔴 ABORT, do not degrade. Unlike TestDataFactory.recordTypeId — where an unstamped row is an
    // acceptable outcome for an under-provisioned test persona — an unstamped row HERE would mean
    // the twelve Contacts STEP 6 inserts are not brokers at all.
    System.debug(LoggingLevel.ERROR,
        'ABORT: the Contact.Broker record type is missing from this org, or is not available to '
        + UserInfo.getUserName() + ', so every Contact this script would insert would NOT be a '
        + 'broker under the current definition. NOTHING WAS SCANNED, NOTHING WAS DELETED, NOTHING '
        + 'WAS CREATED, AND NO DML WAS PERFORMED - this gate runs before STEP 1. Your existing '
        + 'broker Contacts are UNTOUCHED. Deploy the record type (or grant its visibility to this '
        + 'user), then re-run this script.');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 1. Exactly which Contacts is the delete in STEP 5 about to destroy? (This query is
// the same one the original script inlined into `delete [SELECT ...]`, hoisted so the guard
// can see it.) Everything downstream binds to THIS set, so the report is the real blast
// radius rather than "anything with a non-null broker".
// ═════════════════════════════════════════════════════════════════════════════════════
// ⚠ BOUNDED AT SCAN_LIMIT LIKE EVERY OTHER QUERY IN THIS FILE (added 2026-08-20). It was the
// only unbounded one, and it is the one that matters most: this list is BOTH the scan basis in
// STEP 2 AND the delete list in STEP 5, so an unbounded run in a large org risks the 50,000-row
// query cap taking the script down with an uncatchable LimitException before the guard ever
// speaks. A truncated result is worse than a slow one and is therefore treated as fatal below,
// not merely logged: the scan would bind to a PARTIAL set of doomed Contacts and report a blast
// radius smaller than the real one, while STEP 5 deleted only part of the roster.
// 🔴 PREDICATE MOVED 2026-08-20: `WHERE Is_Broker__c = true` -> `WHERE RecordType.DeveloperName
// = 'Broker'`. This is THE query that decides what gets deleted — STEP 5 deletes this exact list
// and issues no query of its own. Read the 🔴 block in this file's header before touching it.
List<Contact> doomed = [
    SELECT Id, Name, Broker_Firm__c
    FROM Contact
    WHERE RecordType.DeveloperName = 'Broker'
    ORDER BY Name
    LIMIT :SCAN_LIMIT
];
Boolean doomedCapHit = doomed.size() == SCAN_LIMIT;
Map<Id, Contact> doomedById = new Map<Id, Contact>(doomed);
Set<Id> doomedIds = new Set<Id>(doomedById.keySet());

System.debug(LoggingLevel.INFO, 'SCAN BASIS: ' + doomedIds.size()
    + ' existing Contact(s) on the Contact.Broker record type would be deleted by this run.');

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 2. THE GUARD SCAN. Read-only. Runs before any DML, always.
// ═════════════════════════════════════════════════════════════════════════════════════
Map<String, List<SObject>> hitsByObject = new Map<String, List<SObject>>();
// Object API -> the stored-text fields this org ACTUALLY has and that were therefore SELECTED.
// Never assume STORED_DENORM_TEXT's contents are all present: a rebuild org may hold the lookup
// but not the denorm field, and STEP 4 must only write columns it queried.
Map<String, List<String>> denormSelected = new Map<String, List<String>>();
// ⚠ ADDED 2026-08-20 (re-review, same day). Object API -> the lookup field(s) this org
// ACTUALLY has and that were therefore SELECTED and used to build the scan's WHERE clause.
// Same reasoning as denormSelected above, and STEP 4 must null only the fields recorded here
// - never re-derive from BROKER_LOOKUPS directly, which may declare a field this org lacks.
Map<String, List<String>> lookupsSelected = new Map<String, List<String>>();
List<String> notInThisOrg = new List<String>();
Integer totalHits = 0;
// Seeded from STEP 1's own cap so a truncated DOOMED list routes into the single existing abort
// site below rather than opening a second one.
Boolean scanCapHit = doomedCapHit;

if (doomedIds.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'SCAN SKIPPED: there are no broker Contacts in this org, '
        + 'so nothing can be deleted and nothing can be orphaned. This is the expected state of a '
        + 'freshly rebuilt org.');
} else {
    Map<String, Schema.SObjectType> globalTypes = Schema.getGlobalDescribe();

    // Sorted so the report reads the same way on every run. Map key order is not guaranteed.
    List<String> scanOrder = new List<String>(BROKER_LOOKUPS.keySet());
    scanOrder.sort();

    for (String objectApi : scanOrder) {
        List<String> declaredLookups = BROKER_LOOKUPS.get(objectApi);

        Schema.SObjectType sot = globalTypes.get(objectApi);
        if (sot == null) {
            notInThisOrg.add(objectApi + ' (object not present)');
            continue;
        }
        // fields.getMap() keys are case-insensitive, so the exact API name is a safe lookup.
        Map<String, Schema.SObjectField> fieldsByName = sot.getDescribe().fields.getMap();

        // ⚠ ADDED 2026-08-20 (re-review, same day): each object's lookup fields are now checked
        // INDIVIDUALLY, not as a single all-or-nothing field, because BOV_Broker_Change__c
        // declares TWO (Outgoing_Broker__c, Incoming_Broker__c) and a rebuild org could
        // legitimately have deployed one and not the other mid-rollout.
        List<String> lookupApis = new List<String>();
        for (String declaredLookupApi : declaredLookups) {
            if (fieldsByName.get(declaredLookupApi) == null) {
                notInThisOrg.add(objectApi + '.' + declaredLookupApi + ' (field not deployed)');
                continue;
            }
            lookupApis.add(declaredLookupApi);
        }
        if (lookupApis.isEmpty()) {
            continue;
        }

        // The stored-text columns, each included ONLY if this org actually has it. Per-field
        // rather than per-object since 2026-08-20: BOV_Submission__c carries TWO, and a rebuild
        // org could legitimately have one and not the other.
        List<String> denormApis = new List<String>();
        List<String> declaredDenorm = STORED_DENORM_TEXT.get(objectApi);
        if (declaredDenorm != null) {
            for (String denormApi : declaredDenorm) {
                if (fieldsByName.get(denormApi) == null) {
                    System.debug(LoggingLevel.WARN, 'SCAN ' + objectApi + ': ' + denormApi
                        + ' is not deployed in this org, so there is no stored text to report.');
                    continue;
                }
                denormApis.add(denormApi);
            }
        }
        if (!denormApis.isEmpty()) {
            denormSelected.put(objectApi, denormApis);
        }
        lookupsSelected.put(objectApi, lookupApis);

        // WHERE is an OR across every lookup field this object carries, since 2026-08-20: a
        // BOV_Broker_Change__c row is at risk if EITHER Outgoing_Broker__c OR Incoming_Broker__c
        // (or both) points at a doomed Contact, not only when the first one does.
        List<String> whereClauses = new List<String>();
        for (String lookupApi : lookupApis) {
            whereClauses.add(lookupApi + ' IN :doomedIds');
        }
        String soql =
            'SELECT Id, Name, ' + String.join(lookupApis, ', ')
            + (denormApis.isEmpty() ? '' : ', ' + String.join(denormApis, ', '))
            + ' FROM ' + objectApi
            + ' WHERE (' + String.join(whereClauses, ' OR ') + ')'
            + ' ORDER BY Name'
            + ' LIMIT ' + SCAN_LIMIT;
        List<SObject> hits = Database.query(soql);

        if (hits.isEmpty()) {
            System.debug(LoggingLevel.INFO, 'SCAN ' + objectApi + '.' + String.join(lookupApis, '/')
                + ' -> 0 referencing records. Safe.');
            continue;
        }

        hitsByObject.put(objectApi, hits);
        totalHits += hits.size();
        if (hits.size() == SCAN_LIMIT) {
            scanCapHit = true;
        }

        System.debug(LoggingLevel.WARN, 'SCAN ' + objectApi + '.' + String.join(lookupApis, '/') + ' -> '
            + hits.size() + ' referencing record(s) WOULD BE ORPHANED on at least one lookup field.');

        Integer logged = 0;
        for (SObject row : hits) {
            if (logged >= MAX_LOG_ROWS_PER_OBJECT) {
                System.debug(LoggingLevel.WARN, '    ... and ' + (hits.size() - logged)
                    + ' more on ' + objectApi + ' (per-object log cap reached).');
                break;
            }
            logged++;

            // ⚠ ADDED 2026-08-20 (re-review, same day): loop every lookup field this object
            // carries and report each one that actually hit a doomed Contact separately - a
            // BOV_Broker_Change__c row can be orphaned on Outgoing_Broker__c, Incoming_Broker__c,
            // or both in the SAME row, and each is a distinct fact the analyst needs named.
            for (String lookupApi : lookupApis) {
                Id brokerId = (Id) row.get(lookupApi);
                if (brokerId == null || !doomedIds.contains(brokerId)) {
                    continue;
                }
                Contact broker = doomedById.get(brokerId);
                String brokerLabel = (broker == null)
                    ? String.valueOf(brokerId)
                    : broker.Name + (String.isBlank(broker.Broker_Firm__c)
                        ? ''
                        : ' (' + broker.Broker_Firm__c + ')');

                // Every stored text this object carries, reported field by field. The suffix says
                // whether FORCE would repair it or deliberately leave it, so the analyst reading
                // the line knows what the forced run will and will not do to THIS record. Reported
                // per lookup HIT rather than per denorm-field role: on BOV_Broker_Change__c an
                // Outgoing_Broker__c hit and an Incoming_Broker__c hit both list BOTH firm
                // snapshots, which over-informs rather than under-informs and is deliberate.
                String staleNote = '';
                // ⚠ NOT named `denormApi` — that identifier is already a for-loop variable earlier
                // in this same enclosing block, and Apex's scoping rules around repeated loop
                // variables are not worth testing in a script that cannot be compiled without
                // running it.
                for (String staleFieldApi : denormApis) {
                    Object storedText = row.get(staleFieldApi);
                    staleNote += ' | ' + staleFieldApi + ' = '
                        + (storedText == null ? '(blank)' : '"' + String.valueOf(storedText) + '"')
                        + ' <- STORED TEXT: the cascade does NOT clear this, so the record would keep '
                        + 'displaying this broker after the lookup is blanked'
                        + (FORCE_CLEARS_DENORM.contains(objectApi)
                            ? ' (FORCE would blank it — derived display copy)'
                            : ' 🔴 (FORCE WILL **NOT** BLANK IT — this is the broker\'s entered '
                              + 'response data, not a derivation. Review this row by hand.)');
                }

                System.debug(LoggingLevel.WARN, '    ORPHAN RISK ' + objectApi + '.' + lookupApi + ' '
                    + String.valueOf(row.get('Name')) + ' -> broker ' + brokerLabel + staleNote);
            }
        }
    }
}

if (!notInThisOrg.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'SCAN NOTE: not scanned because they are not in this org yet - '
        + String.join(notInThisOrg, ', ') + '. Expected in a rebuild org before the broker-lookup '
        + 'metadata deploys (off-market Disposition__c.Broker__c, BOV_Submission__c.Broker__c '
        + 'from 2026-08-20, and Broker_Listing__c.Broker__c from Tranche 1 - the example list was '
        + 'stale until 2026-08-31, W-4b); those lookups hold no data, so they cannot be orphaned. '
        + 'Re-run the '
        + 'scan after the deploy before trusting a clean result.');
}
// 🔴 A TRUNCATED SCAN ABORTS AND **FORCE CANNOT OVERRIDE IT**, deliberately. FORCE means "I have
//    read the ORPHAN RISK lines and accept them"; if the scan was capped, those lines are not the
//    whole story, so consenting to them consents to nothing. Worse, STEP 4 would then correct only
//    the rows it happened to see and leave the rest displaying deleted brokers - a PARTIAL repair
//    that looks like a complete one. The escape hatch is raising SCAN_LIMIT, which is a visible,
//    deliberate edit, not a blanket flag.
//    ⚠ SINCE 2026-08-20 THIS ALSO COVERS A TRUNCATED **STEP 1**. When `doomedCapHit` is true the
//    per-object counts are not merely lower bounds on the REPORT - the doomed set itself is
//    partial, so STEP 5 would delete only some of the broker roster and leave the remainder
//    behind for the insert in STEP 6 to duplicate. Same abort, strictly worse cause.
if (scanCapHit) {
    System.debug(LoggingLevel.ERROR, 'ABORT: the scan was TRUNCATED at the ' + SCAN_LIMIT
        + '-row cap' + (doomedCapHit
            ? ' (STEP 1 itself hit the cap, so the DOOMED CONTACT LIST is partial too)'
            : '')
        + ', so the counts above are LOWER BOUNDS and no decision made from them is sound. '
        + 'Nothing was deleted, nothing was created, no DML was performed. An org at this scale is '
        + 'not a rebuild org and this script is almost certainly the wrong tool for it - STOP and '
        + 'reconsider. If you are certain, raise SCAN_LIMIT and re-run.');
    System.debug(LoggingLevel.ERROR, 'SEED VERDICT: ABORTED BY GUARD (scan truncated, no DML performed)');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 3. THE DECISION GATE. The first DML in this script is in STEP 4, so returning
// here is a genuine no-op, not a partial run.
// ═════════════════════════════════════════════════════════════════════════════════════
if (totalHits > 0) {
    System.debug(LoggingLevel.ERROR, 'GUARD: ' + totalHits + ' record(s) across '
        + hitsByObject.keySet() + ' reference a broker Contact that this seed would delete.');

    if (!FORCE) {
        System.debug(LoggingLevel.ERROR,
            'ABORT: nothing was deleted, nothing was created, no DML was performed. This org holds '
            + 'data that depends on its broker Contacts, so it is not a rebuild org. Read every '
            + 'ORPHAN RISK line above. If you genuinely intend to destroy those references, set '
            + 'FORCE = true and re-run - that path also blanks the stored Disposition text so no '
            + 'record is left displaying a broker it no longer has.');
        System.debug(LoggingLevel.ERROR, 'SEED VERDICT: ABORTED BY GUARD (no DML performed)');
        return;
    }

    System.debug(LoggingLevel.ERROR, 'FORCE = true: proceeding anyway. The ' + totalHits
        + ' record(s) above WILL lose their broker. This is not reversible from here.');
}

if (PREVIEW_ONLY) {
    System.debug(LoggingLevel.WARN, 'PREVIEW ONLY - NO DML WAS PERFORMED. This run would have '
        + 'deleted ' + doomedIds.size() + ' broker Contact(s), orphaned ' + totalHits
        + ' referencing record(s) and re-created the broker roster listed in STEP 6. Set '
        + 'PREVIEW_ONLY = false to execute.');
    System.debug(LoggingLevel.WARN, 'SEED VERDICT: PREVIEW (no DML performed)');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 4. FORCE PATH ONLY — replace the silent cascade with an explicit, logged write.
// Reached only when the scan found rows AND FORCE is true (otherwise STEP 3 returned, or
// there is nothing to clear). Clears the lookup and the STORED text together so the
// record cannot end up blank-but-still-naming-someone. Only rows the scan RETURNED are
// touched, which is what keeps the on-market BOV stamp safe (see the header).
//
// 🔴 SCOPED TO `FORCE_CLEARS_DENORM`, NOT TO `denormSelected`, SINCE 2026-08-20. The two used
// to be the same set and no longer are: BOV_Submission__c is SCANNED and REPORTED but never
// written, because its stored text is the broker's response data rather than a derived display
// copy. See the FORCE block in the header. A row skipped here still loses its lookup to the
// SetNull cascade in STEP 5 — that is the accepted, logged trade, not a gap.
// ═════════════════════════════════════════════════════════════════════════════════════
Integer clearedRows = 0;
Integer clearFailures = 0;
Integer preservedRows = 0;

for (String objectApi : denormSelected.keySet()) {
    List<SObject> hits = hitsByObject.get(objectApi);
    if (hits == null || hits.isEmpty()) {
        continue;
    }
    List<String> denormApis = denormSelected.get(objectApi);

    if (!FORCE_CLEARS_DENORM.contains(objectApi)) {
        preservedRows += hits.size();
        System.debug(LoggingLevel.WARN, 'NOT CLEARED (deliberate) ' + objectApi + ': '
            + hits.size() + ' row(s) keep ' + String.join(denormApis, ' and ')
            + ' even though their broker lookup is about to be blanked by the cascade. Those '
            + 'fields hold ENTERED DATA, not a derivation, and blanking them would destroy the '
            + 'record of who submitted. Every affected row is named in an ORPHAN RISK line above; '
            + 'review them by hand.');
        continue;
    }

    // ⚠ CHANGED 2026-08-20 (re-review, same day): iterates every SELECTED lookup field for this
    // object, not a single BROKER_LOOKUPS.get(objectApi) value - that call would now return a
    // List<String> and could no longer be assigned straight into a lookup field name. No object
    // in FORCE_CLEARS_DENORM today has more than one lookup field, so this is currently a
    // one-iteration loop everywhere it runs, but it no longer silently assumes that stays true.
    List<String> lookupApisForClear = lookupsSelected.get(objectApi);
    for (SObject row : hits) {
        for (String lookupApi : lookupApisForClear) {
            row.put(lookupApi, null);
        }
        for (String clearFieldApi : denormApis) {
            row.put(clearFieldApi, null);
        }
    }

    // allOrNone = false: one locked or validation-refused row must not cost the others their
    // correction. Every failure is reported individually because a row that fails HERE is
    // precisely the row that will be silently orphaned by the delete in STEP 5.
    List<Database.SaveResult> clearResults = Database.update(hits, false);
    for (Integer i = 0; i < clearResults.size(); i++) {
        if (clearResults[i].isSuccess()) {
            clearedRows++;
            System.debug(LoggingLevel.INFO, 'CLEARED ' + objectApi + ' '
                + String.valueOf(hits[i].get('Name')) + ' - ' + String.join(lookupApisForClear, ' and ')
                + ' and ' + String.join(denormApis, ', ') + ' are now all blank.');
        } else {
            clearFailures++;
            String detail = '';
            for (Database.Error err : clearResults[i].getErrors()) {
                detail += err.getStatusCode() + ': ' + err.getMessage() + ' ';
            }
            System.debug(LoggingLevel.ERROR, 'CLEAR FAILED ' + objectApi + ' '
                + String.valueOf(hits[i].get('Name')) + ' -> ' + detail
                + '|| THIS ROW WILL STILL BE ORPHANED BY THE DELETE BELOW AND WILL KEEP DISPLAYING '
                + 'ITS OLD BROKER. A pending approval locks the record (recordEditability = '
                + 'AdminOnly); recall or resolve it, then blank '
                + String.join(denormApis, ' and ') + ' by hand.');
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 5. The destructive delete. Database.delete rather than `delete [SELECT ...]` so a
// refusal is reported per row instead of aborting the whole seed and leaving the org with
// neither the old brokers nor the new ones.
// ═════════════════════════════════════════════════════════════════════════════════════
Integer deleted = 0;
Integer deleteFailures = 0;

if (!doomed.isEmpty()) {
    List<Database.DeleteResult> deleteResults = Database.delete(doomed, false);
    for (Integer i = 0; i < deleteResults.size(); i++) {
        if (deleteResults[i].isSuccess()) {
            deleted++;
        } else {
            deleteFailures++;
            String detail = '';
            for (Database.Error err : deleteResults[i].getErrors()) {
                detail += err.getStatusCode() + ': ' + err.getMessage() + ' ';
            }
            System.debug(LoggingLevel.ERROR, 'DELETE FAILED for Contact ' + doomed[i].Name
                + ' -> ' + detail + '|| That broker survives and the insert below will create a '
                + 'DUPLICATE of it if the name matches the seed list.');
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 6. Seed.
// ⚠ NO LONGER "unchanged from the original script" (2026-08-20). `Is_Broker__c = true` is kept on
// every row below — the field is retained on Contact and several test classes still resolve their
// fixture through it — but IT IS NO LONGER WHAT MAKES THESE ROWS BROKERS. The record-type stamp
// applied below is. Without it, this script would delete the org's brokers in STEP 5 and then
// insert twelve Contacts that no broker query returns and no broker lookup filter accepts: a seed
// that reports COMPLETE and leaves the Broker Hub empty.
//
// 🔴 `brokerRtId` IS RESOLVED AND VALIDATED AT THE TOP OF THIS FILE, NOT HERE — see the PRE-FLIGHT
// GATE above STEP 1 (moved 2026-08-20, code review W1). It used to be resolved at this point,
// which put its abort AFTER STEP 5's delete and made an under-provisioned operator lose the org's
// entire broker roster. DO NOT MOVE IT BACK DOWN HERE.
List<Contact> brokers = new List<Contact>{
    new Contact(FirstName='Dana',   LastName='Pierce',    Is_Broker__c=true, Broker_Firm__c='CBRE',                 Broker_Specialty__c='Retail',      Broker_Status__c='Active',   Active_Listings__c=12, Offers_Received__c=18, Closed_Volume__c=48000000, Avg_Days_On_Market__c=88),
    new Contact(FirstName='Marcus', LastName='Whitfield', Is_Broker__c=true, Broker_Firm__c='Marcus & Millichap',   Broker_Specialty__c='Retail',      Broker_Status__c='Active',   Active_Listings__c=9,  Offers_Received__c=14, Closed_Volume__c=36000000, Avg_Days_On_Market__c=95),
    new Contact(FirstName='Priya',  LastName='Nair',      Is_Broker__c=true, Broker_Firm__c='JLL',                  Broker_Specialty__c='Office',      Broker_Status__c='Active',   Active_Listings__c=8,  Offers_Received__c=11, Closed_Volume__c=41000000, Avg_Days_On_Market__c=102),
    new Contact(FirstName='Carlos', LastName='Alvarez',   Is_Broker__c=true, Broker_Firm__c='Newmark',              Broker_Specialty__c='Industrial',  Broker_Status__c='Active',   Active_Listings__c=7,  Offers_Received__c=9,  Closed_Volume__c=33000000, Avg_Days_On_Market__c=70),
    new Contact(FirstName='Sofia',  LastName='Marchetti', Is_Broker__c=true, Broker_Firm__c='Cushman & Wakefield',  Broker_Specialty__c='Multifamily', Broker_Status__c='Active',   Active_Listings__c=6,  Offers_Received__c=8,  Closed_Volume__c=52000000, Avg_Days_On_Market__c=65),
    new Contact(FirstName='Ethan',  LastName='Brooks',    Is_Broker__c=true, Broker_Firm__c='Colliers',             Broker_Specialty__c='Office',      Broker_Status__c='Active',   Active_Listings__c=5,  Offers_Received__c=6,  Closed_Volume__c=22000000, Avg_Days_On_Market__c=120),
    new Contact(FirstName='Hannah', LastName='Cole',      Is_Broker__c=true, Broker_Firm__c='Eastdil Secured',      Broker_Specialty__c='Mixed-Use',   Broker_Status__c='Active',   Active_Listings__c=4,  Offers_Received__c=5,  Closed_Volume__c=60000000, Avg_Days_On_Market__c=58),
    new Contact(FirstName='Liam',   LastName='O\'Donnell', Is_Broker__c=true, Broker_Firm__c='Berkadia',            Broker_Specialty__c='Multifamily', Broker_Status__c='Active',   Active_Listings__c=3,  Offers_Received__c=4,  Closed_Volume__c=28000000, Avg_Days_On_Market__c=75),
    new Contact(FirstName='Grace',  LastName='Sullivan',  Is_Broker__c=true, Broker_Firm__c='Walker & Dunlop',      Broker_Specialty__c='Industrial',  Broker_Status__c='Active',   Active_Listings__c=3,  Offers_Received__c=3,  Closed_Volume__c=19000000, Avg_Days_On_Market__c=84),
    new Contact(FirstName='Noah',   LastName='Bennett',   Is_Broker__c=true, Broker_Firm__c='Lee & Associates',     Broker_Specialty__c='Land',        Broker_Status__c='Active',   Active_Listings__c=2,  Offers_Received__c=2,  Closed_Volume__c=9000000,  Avg_Days_On_Market__c=140),
    new Contact(FirstName='Olivia', LastName='Reyes',     Is_Broker__c=true, Broker_Firm__c='Avison Young',         Broker_Specialty__c='Retail',      Broker_Status__c='Active',   Active_Listings__c=2,  Offers_Received__c=1,  Closed_Volume__c=12000000, Avg_Days_On_Market__c=110),
    new Contact(FirstName='Walter', LastName='Kim',       Is_Broker__c=true, Broker_Firm__c='Northmarq',            Broker_Specialty__c='Office',      Broker_Status__c='Inactive', Active_Listings__c=0,  Offers_Received__c=0,  Closed_Volume__c=0,        Avg_Days_On_Market__c=0)
};

// 🔴 THE LINE THAT MAKES THEM BROKERS. See the STEP 6 banner above.
for (Contact b : brokers) {
    b.RecordTypeId = brokerRtId;
}

Integer created = 0;
Integer createFailures = 0;
List<Database.SaveResult> insertResults = Database.insert(brokers, false);
for (Integer i = 0; i < insertResults.size(); i++) {
    if (insertResults[i].isSuccess()) {
        created++;
    } else {
        createFailures++;
        String detail = '';
        for (Database.Error err : insertResults[i].getErrors()) {
            detail += err.getStatusCode() + ': ' + err.getMessage() + ' ';
        }
        System.debug(LoggingLevel.ERROR, 'INSERT FAILED for '
            + brokers[i].FirstName + ' ' + brokers[i].LastName + ' -> ' + detail);
    }
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 7. Verdict.
// ═════════════════════════════════════════════════════════════════════════════════════
System.debug(LoggingLevel.INFO, 'SEED SUMMARY: orphan-risk records found ' + totalHits
    + ', pre-emptively cleared ' + clearedRows + ', clear-failures ' + clearFailures
    + ', STORED TEXT DELIBERATELY PRESERVED on ' + preservedRows + ' row(s)'
    + ', contacts deleted ' + deleted + ', delete-failures ' + deleteFailures
    + ', contacts created ' + created + ', create-failures ' + createFailures + '.');
// ⚠ `preservedRows` is NOT a failure count and must not be read as one. It is the number of
// rows (BOV_Submission__c today) whose stored broker text was left intact ON PURPOSE while the
// cascade blanked their lookup — evidence kept, display stale, every row named above. It is
// therefore deliberately absent from the VERDICT condition below.
if (preservedRows > 0) {
    System.debug(LoggingLevel.WARN, 'SEED NOTE: ' + preservedRows + ' row(s) on '
        + 'objects outside FORCE_CLEARS_DENORM now have a blank broker lookup and a stale stored '
        + 'broker text. That is the documented trade, not an error — see the FORCE block in this '
        + 'file\'s header. Read the ORPHAN RISK lines to decide each one by hand.');
}
System.debug(LoggingLevel.INFO, 'SEED VERDICT: '
    + ((clearFailures == 0 && deleteFailures == 0 && createFailures == 0)
        ? (totalHits == 0 ? 'COMPLETE' : 'COMPLETE (FORCED - ' + totalHits + ' record(s) lost their broker)')
        : 'INCOMPLETE - read the FAILED lines above'));
