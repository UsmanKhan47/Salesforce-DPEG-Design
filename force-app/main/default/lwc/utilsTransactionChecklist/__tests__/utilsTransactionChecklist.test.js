/**
 * c/utilsTransactionChecklist — pure-module unit tests. No DOM, no wires, no component.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS FILE IS THE RISK 1 FALSIFIER, AND IT IS DESIGNED TO GO RED — NOT JUST TO PASS.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * RISK 1 (design §1) is that criticality and wire-verification used to be derived by REGEX over
 * task subject text, in a way that fails SILENTLY and in the unsafe direction: clean up the
 * subject and the red CRITICAL rows stop rendering and the Wire Sentinel metric reads zero, with
 * no error anywhere.
 *
 * The old Jest suite could not have caught that, because its fixtures BAKED IN the subject-marker
 * convention: every "critical" fixture subject also ended in `(anti-fraud)` or `(CRITICAL)`, so a
 * component repointed to boolean fields and a component still parsing subjects produce identical
 * output against it. It would have passed vacuously either way.
 *
 * The tests below break that tie deliberately, in BOTH directions:
 *   • `MARKERLESS` — a new-model item whose subject contains NEITHER marker but whose
 *     `isCritical` / `isWireVerification` are TRUE. A residual subject parse renders it plain,
 *     so those assertions fail. This mirrors `ChecklistRollupServiceTest`'s canary, which gives
 *     its wire item a subject WITHOUT `anti-fraud` for exactly the same reason.
 *   • `MARKED_BUT_FALSE` — a new-model item whose subject DOES contain `(anti-fraud)` but whose
 *     booleans are FALSE. A residual subject parse renders it critical, so that assertion fails.
 * Together they pin the boolean fields as the ONLY source of meaning on the new model. Neither
 * test can pass while a regex is consulted, and neither can be satisfied by a lucky fixture.
 *
 * 🔴 THE LEGACY PATH IS PINNED TOO, IN THE OPPOSITE DIRECTION. `Task` carries no
 * `Is_Wire_Verification__c` / `Is_Critical__c` (verified 2026-09-01 against
 * `objects/Activity/fields/`), so its subjects are genuinely the only signal and the regex is
 * CORRECT there. `normalizeLegacyGroups` is asserted to still derive both from the subject — so
 * an over-eager cleanup that deletes the regex outright also goes red.
 *
 * ⚠ THE PARENTHESES IN THE LEGACY REGEX ARE LOAD-BEARING. Checklist items A4 and A5 legitimately
 * contain the words "critical dates" and are NOT critical. A bare `contains('critical')` flags
 * both. That is asserted here so the "simplification" cannot be made silently.
 */
import {
    MODEL_CHECKLIST,
    MODEL_LEGACY,
    MODEL_UNKNOWN,
    PHASES,
    displaySubject,
    modelFor,
    normalizeChecklistGroups,
    normalizeLegacyGroups,
    percent,
    phaseKeyForLetter,
    phaseKeyForStage,
    stripMarkerForDisplay
} from 'c/utilsTransactionChecklist';

describe('c-utils-transaction-checklist :: model discrimination', () => {
    it('maps a true Checklist_Fanned_Out__c to the new model', () => {
        expect(modelFor(true)).toBe(MODEL_CHECKLIST);
    });

    it('maps a false Checklist_Fanned_Out__c to the legacy model', () => {
        expect(modelFor(false)).toBe(MODEL_LEGACY);
    });

    it.each([
        ['undefined', undefined],
        ['null', null],
        ['the empty string', ''],
        ['the string "true"', 'true'],
        ['zero', 0]
    ])('treats %s as UNKNOWN rather than coercing it to a model', (_label, value) => {
        // A checkbox is never null when it is READABLE, so anything that is not strictly
        // true/false means "we do not know". Coercing here would let a component silently pick
        // the legacy model for a deal that has already been migrated — and a migrated deal still
        // has its old Task rows, so it would render a complete, plausible, stale checklist.
        expect(modelFor(value)).toBe(MODEL_UNKNOWN);
    });
});

describe('c-utils-transaction-checklist :: phase labels', () => {
    it('labels the four phases with the values Transaction__c.Stage__c actually uses', () => {
        // 🔴 THE LABEL FIX (design §2.12). Until Phase 3 the UI said "Closing" and "Post Closing"
        // while the data said "Closing Prep" and "Post-Closing". The DATA is correct — these
        // strings are byte-identical to Transaction__c.Stage__c's first four values and to
        // Checklist__c.Stage__c's restricted value set. NOTE THE HYPHEN in Post-Closing.
        expect(PHASES.map((p) => p.name)).toEqual([
            'Open Contract',
            'Due Diligence',
            'Closing Prep',
            'Post-Closing'
        ]);
    });

    it('keeps the four FlexiPage phase keys unchanged', () => {
        // ⚠ DEPLOY CONTRACT. Transaction_Record_Page.flexipage pins four transactionTaskGroups
        // instances with phase = open / dd / close / post. Renaming a key silently un-pins a tab
        // on a page whose deploy REPLACES the org copy with no version history.
        expect(PHASES.map((p) => p.key)).toEqual(['open', 'dd', 'close', 'post']);
    });

    it('maps every phase stage value to its own key', () => {
        PHASES.forEach((p) => {
            expect(phaseKeyForStage(p.stage)).toBe(p.key);
        });
    });

    it('does not map the pre-Phase-3 label spellings to anything', () => {
        // An absence pin: if someone "restores" the old spellings to Checklist__c.Stage__c, the
        // groups would silently fall into no phase at all rather than erroring.
        expect(phaseKeyForStage('Closing')).toBeUndefined();
        expect(phaseKeyForStage('Post Closing')).toBeUndefined();
    });

    it('falls back to the group letter when a checklist carries no stage', () => {
        // Checklist__c.Stage__c has NO default, deliberately — the field's description says a
        // plausible default would hide a fan-out that failed to stamp the phase. So a blank stage
        // is a real, expected state and the letter fallback keeps the group on screen.
        expect(phaseKeyForLetter('A')).toBe('open');
        expect(phaseKeyForLetter('H2')).toBe('dd');
        expect(phaseKeyForLetter('I')).toBe('close');
        expect(phaseKeyForLetter('J')).toBe('post');
        expect(phaseKeyForLetter('Z')).toBeUndefined();
        expect(phaseKeyForLetter(undefined)).toBeUndefined();
    });
});

describe('c-utils-transaction-checklist :: displaySubject', () => {
    it('strips a parenthesised marker for display', () => {
        expect(displaySubject('Verify wiring instructions by phone (anti-fraud)')).toBe(
            'Verify wiring instructions by phone'
        );
        expect(displaySubject('Set up auto loan payment (CRITICAL - frequently missed)')).toBe(
            'Set up auto loan payment'
        );
    });

    it('leaves "critical dates" alone — the parentheses are what make a marker a marker', () => {
        // A4 / A5. A bare contains('critical') strips or flags these; the parenthesised form does
        // not touch them.
        expect(displaySubject('Receive critical dates from title company')).toBe(
            'Receive critical dates from title company'
        );
    });

    it('returns the empty string, never undefined, for blank input', () => {
        // ⚠ This value is bound to element ATTRIBUTES (data-subject, aria-label). A getter bound
        // to an attribute is written UNCONDITIONALLY, so returning undefined renders the literal
        // text "undefined" into the DOM.
        expect(displaySubject(undefined)).toBe('');
        expect(displaySubject(null)).toBe('');
        expect(displaySubject('')).toBe('');
    });
});

describe('c-utils-transaction-checklist :: stripMarkerForDisplay', () => {
    it('strips the marker out of a SERVER MESSAGE that quotes a subject', () => {
        // The wire-fraud gate interpolates the blocking item's RAW Subject__c into its refusal,
        // and that refusal is shown to the user verbatim. Without this, the toast names the step
        // one way and the row directly above it names the same step another way.
        const refusal =
            'Complete "Call title company to verbally verify wiring instructions (anti-fraud)" first.';
        expect(stripMarkerForDisplay(refusal)).toBe(
            'Complete "Call title company to verbally verify wiring instructions " first.'
        );
    });

    it('leaves a message with no marker completely alone', () => {
        const plain = 'This checklist item is no longer available to you.';
        expect(stripMarkerForDisplay(plain)).toBe(plain);
    });

    it('returns the empty string for blank input, never undefined', () => {
        expect(stripMarkerForDisplay(undefined)).toBe('');
        expect(stripMarkerForDisplay(null)).toBe('');
    });
});

describe('c-utils-transaction-checklist :: percent', () => {
    it('rounds to a whole percent and returns 0 for an empty group', () => {
        expect(percent(1, 3)).toBe(33);
        expect(percent(2, 3)).toBe(67);
        expect(percent(3, 3)).toBe(100);
        expect(percent(0, 0)).toBe(0);
    });
});

// ═══════════════════════════════════════════════════════════════════════════════════════════
// RISK 1 — the new model reads BOOLEAN FIELDS and nothing else.
// ═══════════════════════════════════════════════════════════════════════════════════════════

/** A subject with NO marker in it at all. See the file header. */
const MARKERLESS_SUBJECT = 'Confirm wiring instructions verbally with the escrow officer';

/** A subject that DOES carry the legacy marker, on an item whose booleans are false. */
const MARKED_SUBJECT = 'Order the survey (anti-fraud)';

function checklistGroup(items) {
    return [
        {
            id: 'a1Y000000000001',
            letter: 'B',
            name: 'Earnest Money & Wires',
            ownerLabel: 'Danish',
            conditional: false,
            stage: 'Open Contract',
            total: items.length,
            complete: items.filter((i) => i.done).length,
            pct: 0,
            items
        }
    ];
}

describe('c-utils-transaction-checklist :: normalizeChecklistGroups (new model)', () => {
    it('flags a MARKERLESS item as critical and wire from its boolean fields', () => {
        // 🔴 THE CANARY. The subject contains neither "(anti-fraud)" nor "(CRITICAL)". If any
        // regex survives on this path, both assertions fail. Mirrors ChecklistRollupServiceTest.
        const [group] = normalizeChecklistGroups(
            checklistGroup([
                {
                    id: 'i1',
                    subject: MARKERLESS_SUBJECT,
                    isCritical: true,
                    isWireVerification: true,
                    done: false,
                    verifyComplete: false,
                    blocked: false
                }
            ])
        );
        expect(group.items[0].critical).toBe(true);
        expect(group.items[0].wire).toBe(true);
        // And the subject is rendered unchanged, because there was no marker to strip.
        expect(group.items[0].subject).toBe(MARKERLESS_SUBJECT);
    });

    it('does NOT flag a MARKED item whose boolean fields are false', () => {
        // 🔴 THE CONVERSE CANARY. A surviving regex would flag this; the booleans say otherwise
        // and the booleans win. Without this test, a component that ORed the two sources would
        // still pass the canary above.
        const [group] = normalizeChecklistGroups(
            checklistGroup([
                {
                    id: 'i2',
                    subject: MARKED_SUBJECT,
                    isCritical: false,
                    isWireVerification: false,
                    done: false,
                    verifyComplete: false,
                    blocked: false
                }
            ])
        );
        expect(group.items[0].critical).toBe(false);
        expect(group.items[0].wire).toBe(false);
        // The marker is still hidden for DISPLAY — that strip is cosmetic and independent of
        // meaning. Asserting it here is what stops the two being re-coupled.
        expect(group.items[0].subject).toBe('Order the survey');
        expect(group.items[0].rawSubject).toBe(MARKED_SUBJECT);
    });

    it('treats Verified as done, not just Completed', () => {
        // Flag__c is a lossy picklist and DONE means Completed OR Verified. The Apex side owns
        // that decision (ChecklistItemDomain.isDone) and hands it over as `done`; this asserts the
        // module does not second-guess it.
        const [group] = normalizeChecklistGroups(
            checklistGroup([
                {
                    id: 'i3',
                    subject: MARKERLESS_SUBJECT,
                    isCritical: true,
                    isWireVerification: true,
                    done: true,
                    verifyComplete: true,
                    verifiedByName: 'Jane Doe',
                    blocked: false
                }
            ])
        );
        expect(group.items[0].done).toBe(true);
        // A verified wire item is no longer shown as an open critical risk.
        expect(group.items[0].verified).toBe(true);
    });

    it('maps a group to its phase by STAGE, preferring it over the letter', () => {
        const rows = checklistGroup([]);
        rows[0].letter = 'J'; // would map to 'post' by letter
        rows[0].stage = 'Closing Prep'; // but the stage says 'close'
        const [group] = normalizeChecklistGroups(rows);
        expect(group.phaseKey).toBe('close');
    });

    it('carries the blocked flag through for the prerequisite badge', () => {
        const [group] = normalizeChecklistGroups(
            checklistGroup([
                { id: 'i4', subject: 'Send wire request', done: false, blocked: true }
            ])
        );
        expect(group.items[0].blocked).toBe(true);
    });

    it('returns an empty array for null / non-array input', () => {
        expect(normalizeChecklistGroups(undefined)).toEqual([]);
        expect(normalizeChecklistGroups(null)).toEqual([]);
    });
});

describe('c-utils-transaction-checklist :: normalizeLegacyGroups (legacy Task model)', () => {
    function legacyGroup(tasks) {
        return [
            {
                key: 'B. Earnest Money & Wires',
                letter: 'B',
                name: 'Earnest Money & Wires',
                ownerLabel: 'Danish',
                conditional: false,
                total: tasks.length,
                complete: tasks.filter((t) => t.done).length,
                pct: 0,
                tasks
            }
        ];
    }

    it('STILL derives critical and wire from the subject — Task has no boolean fields', () => {
        // 🔴 The legacy parse is CORRECT and must not be deleted with the new-model one. Task
        // carries no Is_Critical__c / Is_Wire_Verification__c, and the markers on already-created
        // rows are frozen, so the subject is genuinely the only signal available.
        const [group] = normalizeLegacyGroups(
            legacyGroup([
                {
                    id: 't1',
                    subject: 'Call title company to verbally verify wiring instructions (anti-fraud)',
                    done: false
                }
            ])
        );
        expect(group.items[0].critical).toBe(true);
        expect(group.items[0].wire).toBe(true);
    });

    it('flags (CRITICAL) as critical but NOT as a wire step', () => {
        const [group] = normalizeLegacyGroups(
            legacyGroup([
                { id: 't2', subject: 'Set up auto loan payment at lender bank (CRITICAL)', done: false }
            ])
        );
        expect(group.items[0].critical).toBe(true);
        expect(group.items[0].wire).toBe(false);
    });

    it.each([
        'Receive critical dates from title company',
        'Log critical dates into Salesforce deal record'
    ])('does NOT flag "%s" — the parentheses are load-bearing', (subject) => {
        // A4 and A5. A bare contains('critical') wrongly flags both. The live org renders exactly
        // four critical items: {B2, F12, I7, J4}.
        const [group] = normalizeLegacyGroups(legacyGroup([{ id: 't3', subject, done: false }]));
        expect(group.items[0].critical).toBe(false);
    });

    it('never reports a legacy row as blocked', () => {
        // TransactionTaskController.TaskRow does not expose Is_Prerequisite_Met__c, and widening
        // that live DTO for an advisory badge was rejected. The legacy SERVER gate is unaffected.
        const [group] = normalizeLegacyGroups(
            legacyGroup([{ id: 't4', subject: 'Send wire request to accounting', done: false }])
        );
        expect(group.items[0].blocked).toBe(false);
    });

    it('produces the SAME item shape as the checklist normaliser', () => {
        // One shape means one template, which is what makes the dual-model window survivable.
        const [legacy] = normalizeLegacyGroups(
            legacyGroup([{ id: 't5', subject: 'Order the survey', done: true, notes: ' filed ' }])
        );
        const [checklist] = normalizeChecklistGroups(
            checklistGroup([
                { id: 'i5', subject: 'Order the survey', done: true, comment: ' filed ' }
            ])
        );
        expect(Object.keys(legacy.items[0]).sort()).toEqual(
            Object.keys(checklist.items[0]).sort()
        );
        expect(legacy.items[0].comment).toBe('filed');
        expect(checklist.items[0].comment).toBe('filed');
    });
});

describe('c-utils-transaction-checklist :: hasCapture (Phase 5)', () => {
    it('carries the server-derived hasCapture straight through on the new model', () => {
        // Server-derived from the item COORDINATE (group letter + sequence) by
        // ChecklistCaptureDefProvider. This module must not re-derive it, and must not drop it.
        const [group] = normalizeChecklistGroups(
            checklistGroup([
                { id: 'i-cap', subject: 'Select bank account type', hasCapture: true },
                { id: 'i-plain', subject: 'Follow up with bankers', hasCapture: false },
                { id: 'i-absent', subject: 'Sign engagement letter' }
            ])
        );
        expect(group.items[0].hasCapture).toBe(true);
        expect(group.items[1].hasCapture).toBe(false);
        // An absent key is NOT a capture. A truthy coercion here would open the capture dialog on
        // every row served by an older controller build.
        expect(group.items[2].hasCapture).toBe(false);
    });

    it('never reports a capture on the LEGACY model, whatever the payload says', () => {
        // Loan__c and Insurance_Binder__c hang off the CHECKLIST model. An un-migrated deal must
        // behave exactly as it did before Phase 5 - that is the point of the dual-model window.
        const [group] = normalizeLegacyGroups(
            [
                {
                    key: 'B. Earnest Money',
                    letter: 'B',
                    name: 'Earnest Money',
                    ownerLabel: 'Danish',
                    total: 1,
                    complete: 0,
                    pct: 0,
                    tasks: [
                        { id: 't-cap', subject: 'Select bank account type', hasCapture: true }
                    ]
                }
            ]
        );
        expect(group.items[0].hasCapture).toBe(false);
    });
});
