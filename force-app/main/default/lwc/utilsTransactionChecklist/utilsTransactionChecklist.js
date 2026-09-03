/**
 * c/utilsTransactionChecklist — the Transaction checklist's shared view model.
 *
 * ARCHITECTURE.md §5 puts shared utilities in `lwc/utils*` as stateless lowerCamelCase modules
 * with no `.html`. This one is deliberately SEPARATE from the general-purpose `c/utils` bundle:
 * `c/utils` is imported by dozens of components and is a hub file that a concurrent workstream
 * may be editing, whereas everything here is owned by three Transaction bundles.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 AMENDED 2026-09-03 (M5) — THE DUAL-MODEL WINDOW IS CLOSED AND THE DISCRIMINATOR IS GONE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * This module existed because TWO data models were live at once: the checklist was migrated from
 * standard `Task` rows to `Checklist__c` / `Checklist_Item__c` one deal at a time, so a single
 * browser session could show new-model and legacy deals side by side. Four things went at M5:
 *   • `modelFor` and `MODEL_CHECKLIST` / `MODEL_LEGACY` / `MODEL_UNKNOWN` — the discriminator over
 *     `Transaction__c.Checklist_Fanned_Out__c`;
 *   • `normalizeLegacyGroups` — the `Task`-shaped normaliser;
 *   • `LEGACY_CRITICAL_RE` and `LEGACY_WIRE_RE` — the two SEMANTIC subject regexes.
 * The three components now call `normalizeChecklistGroups` unconditionally.
 *
 * 🔴 REMOVING THE DISCRIMINATOR IS SAFE ONLY BECAUSE NO DEAL CAN BE ON THE LEGACY MODEL ANY MORE.
 * That is a fact about the org, not an inference from the code: the legacy fan-out
 * (`TaskFanoutService`), its queueable, its rollup, its prerequisite gate, its controller, the
 * script that could re-arm it, and the eight Transaction-only `Activity` fields it wrote were all
 * deleted in the same change, after a probe confirmed ZERO `Task` rows carried
 * `Transaction_Deal__c` or `Task_Group__c` org-wide. Nothing can produce a legacy-model deal, so
 * there is no state in which the removed branch would have been the correct one.
 *
 * ⚠ THERE IS ONE USER-VISIBLE CONSEQUENCE AND IT IS NOT A BUG, BUT IT IS NOT NOTHING EITHER.
 * `modelFor(false)` returned `MODEL_LEGACY`, and `Checklist_Fanned_Out__c` is false on EVERY
 * Transaction that has not yet had a contract executed — not only on migrated deals. Those deals
 * used to render the legacy component's empty state; they now render the CHECKLIST component with
 * zero rows. Confirm that empty state reads sensibly (design §7 UI-4) — no automated test in this
 * suite can see the difference.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 RISK 1 — THE SUBJECT-TEXT COUPLING IS NOW FULLY RETIRED
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Before Phase 3, `transactionTaskGroups.js` derived BOTH "is this critical" and "is this a wire
 * step" from a regex over the task subject. That coupling failed SILENTLY and in the unsafe
 * direction: clean up the subject text and the red CRITICAL rows simply stop rendering, with no
 * error anywhere. `normalizeChecklistGroups` reads `isCritical` / `isWireVerification` — real
 * boolean fields — and CONTAINS NO REGEX AT ALL. With `normalizeLegacyGroups` gone, NO SUBJECT IS
 * PARSED FOR MEANING ANYWHERE IN THIS MODULE. Do not reintroduce one.
 *
 * ⚠ `displaySubject` STILL STRIPS THE PARENTHETICAL, AND THAT IS COSMETIC ONLY. The CMDT subjects
 * still carry `(anti-fraud)` / `(CRITICAL - frequently missed)` — `scripts/load-transaction-task-defs.apex`
 * seeds `Is_Critical__c` and `Is_Wire_Verification__c` from an explicit `{B2,F12,I7,J4}` /
 * `{B2,I7}` key set, never from a parse, so the markers are decoration the UI hides. Its regex was
 * declared SEPARATELY from the legacy semantic ones precisely so deleting that pair at M5 could
 * not silently change what the screen displays — see `DISPLAY_MARKER_RE`.
 *
 * @module c/utilsTransactionChecklist
 */

/**
 * The four deal phases.
 *
 * 🔴 `name` AND `stage` ARE BOTH HERE AND THEY ARE NOW THE SAME STRINGS — THAT IS THE LABEL FIX.
 * Until Phase 3 the UI displayed `Closing` and `Post Closing` while the data said `Closing Prep`
 * and `Post-Closing` (design §2.12). The DATA values are byte-identical to `Transaction__c.Stage__c`
 * and to `Checklist__c.Stage__c`'s restricted value set, and they are the correct ones — so the
 * LABELS moved to match, not the data. Note the HYPHEN in `Post-Closing`.
 *
 * ⚠ `key` IS A DEPLOY CONTRACT AND MUST NOT CHANGE. `Transaction_Record_Page.flexipage` pins four
 * `transactionTaskGroups` instances with `phase` = `open` / `dd` / `close` / `post`. Renaming a
 * key silently un-pins a tab — the component falls back to showing all phases inside one tab, on
 * a page whose deploy REPLACES the org copy with no version history.
 *
 * ⚠ `Closed` is deliberately absent: no task group belongs to the terminal stage.
 *
 * @type {Array<{key: string, name: string, stage: string, letters: string[], icon: string}>}
 */
export const PHASES = [
    {
        key: 'open',
        name: 'Open Contract',
        stage: 'Open Contract',
        letters: ['A', 'B'],
        icon: 'utility:contract'
    },
    {
        key: 'dd',
        name: 'Due Diligence',
        stage: 'Due Diligence',
        letters: ['C', 'D', 'E', 'F', 'G', 'H', 'H2'],
        icon: 'utility:search'
    },
    {
        key: 'close',
        name: 'Closing Prep',
        stage: 'Closing Prep',
        letters: ['I'],
        icon: 'utility:money'
    },
    {
        key: 'post',
        name: 'Post-Closing',
        stage: 'Post-Closing',
        letters: ['J'],
        icon: 'utility:success'
    }
];

const PHASE_KEY_BY_LETTER = {};
const PHASE_KEY_BY_STAGE = {};
PHASES.forEach((phase) => {
    PHASE_KEY_BY_STAGE[phase.stage] = phase.key;
    phase.letters.forEach((letter) => {
        PHASE_KEY_BY_LETTER[letter] = phase.key;
    });
});

/**
 * COSMETIC ONLY. Strips the trailing marker from a subject for display.
 *
 * 🔴 THIS CONSTANT IS THE REASON M5 COULD DELETE THE LEGACY PAIR WITHOUT CHANGING THE SCREEN.
 * It was declared separately from the two SEMANTIC regexes (`LEGACY_CRITICAL_RE` /
 * `LEGACY_WIRE_RE`) even though the pattern was byte-identical, precisely because they had
 * different lifetimes: the semantic pair died with the Task model on 2026-09-03, while this one
 * survives for as long as the CMDT subjects carry `(anti-fraud)` / `(CRITICAL …)` decoration.
 * Sharing one constant would have made that deletion silently stop stripping the marker, and the
 * markers would have appeared in the UI with no error anywhere.
 * ⚠ The CMDT subjects STILL carry the markers and must —
 * `ChecklistCaptureDefProviderTest.everyCoordinateStillMatchesItsLoaderSubject` asserts them, and
 * `scripts/load-transaction-task-defs.apex` is the only way the definitions reach an org. They are
 * decoration the UI hides, never a signal anything parses for meaning.
 */
const DISPLAY_MARKER_RE = /\(\s*(anti-?fraud|critical[^)]*)\s*\)/i;

/**
 * The phase key for a `Checklist__c.Stage__c` value (new model).
 *
 * @param {string|null|undefined} stage e.g. `'Closing Prep'`.
 * @returns {string|undefined} `'close'`, or `undefined` for an unmapped/blank stage.
 */
export function phaseKeyForStage(stage) {
    return stage ? PHASE_KEY_BY_STAGE[stage] : undefined;
}

/**
 * The phase key for a group letter (legacy model, and the new model's fallback when a fan-out
 * failed to stamp `Stage__c`).
 *
 * ⚠ `Checklist__c.Stage__c` HAS NO DEFAULT VALUE, DELIBERATELY — the field's own description says
 * a plausible default would hide a fan-out that failed to stamp the phase. So a blank stage is a
 * real, expected, visible state and this fallback is what keeps such a group on screen instead of
 * dropping it into no phase at all.
 *
 * @param {string|null|undefined} letter e.g. `'H2'`.
 * @returns {string|undefined} the phase key, or `undefined` for an unmapped letter.
 */
export function phaseKeyForLetter(letter) {
    return letter ? PHASE_KEY_BY_LETTER[letter] : undefined;
}

/**
 * The subject as the user should see it — marker stripped, trimmed.
 *
 * @param {string|null|undefined} subject the raw `Subject__c` / `Task.Subject`.
 * @returns {string} the display text; `''` (never `undefined`) for a blank input, because this
 *          value is bound to element attributes and a getter bound to an attribute is written
 *          UNCONDITIONALLY — returning `undefined` renders the literal string `"undefined"`.
 */
export function displaySubject(subject) {
    return stripMarkerForDisplay(subject);
}

/**
 * The same cosmetic strip, applied to a SERVER MESSAGE rather than to a subject.
 *
 * 🔴 WHY THIS EXISTS AS ITS OWN EXPORT. `ChecklistItemPrerequisiteService` interpolates the
 * blocking item's RAW `Subject__c` into its refusal text — markers and all — and that text is
 * surfaced to the user VERBATIM (deliberately: it names the step they have to finish). So without
 * this, the toast says
 *     Complete "Call title company to verbally verify wiring instructions (anti-fraud)" first
 * while the row directly above it reads
 *     Call title company to verbally verify wiring instructions
 * — the same step, spelled two ways, in the same viewport, at the exact moment the user is
 * confused about why their click was refused.
 *
 * ⚠ COSMETIC ONLY, and it must stay that way. It does not decide anything, and the SERVER text is
 * still the single source of the explanation — this only removes decoration the UI hides
 * everywhere else. `DISPLAY_MARKER_RE` is non-global, so it strips at most the one marker inside
 * the quoted subject and cannot chew through the rest of a message.
 *
 * @param {string|null|undefined} text any user-facing string that may embed a subject.
 * @returns {string} the text with a leading/trailing-trimmed marker removed; `''` when blank.
 */
export function stripMarkerForDisplay(text) {
    if (!text) {
        return '';
    }
    return String(text).replace(DISPLAY_MARKER_RE, '').trim();
}

/**
 * Percentage helper shared by both normalisers, so a group's bar and a phase's bar can never
 * round differently.
 *
 * @param {number} complete completed count.
 * @param {number} total total count.
 * @returns {number} whole percent, 0 when total is 0.
 */
export function percent(complete, total) {
    if (!total) {
        return 0;
    }
    return Math.round((complete / total) * 100);
}

/**
 * Normalises `ChecklistController.getChecklist` output into the shared view model.
 *
 * 🔴 CONTAINS NO REGEX AND MUST NEVER ACQUIRE ONE. `critical` and `wire` come from the real
 * boolean fields `Is_Critical__c` / `Is_Wire_Verification__c` — the same two fields
 * `ChecklistRollupService` uses to compute `Transaction__c.Wire_Open_Risks__c`. That agreement is
 * the whole point: the number on the Wire Sentinel dashboard tile and the red flag on this screen
 * are now derived from the same data, so they cannot drift apart.
 *
 * @param {Array<object>|null|undefined} rows `ChecklistRow[]` from Apex.
 * @returns {Array<object>} normalised groups; `[]` for null/empty input.
 */
export function normalizeChecklistGroups(rows) {
    if (!Array.isArray(rows)) {
        return [];
    }
    return rows.map((group) => {
        const items = (group.items || []).map((item) => {
            const critical = item.isCritical === true;
            const wire = item.isWireVerification === true;
            const done = item.done === true;
            return {
                id: item.id,
                subject: displaySubject(item.subject),
                rawSubject: item.subject || '',
                critical,
                wire,
                done,
                verifyComplete: item.verifyComplete === true,
                verified: wire && done && item.verifyComplete === true,
                verifiedByName: item.verifiedByName || '',
                verifiedAt: item.verifiedAt || null,
                phone: item.phone || '',
                comment: (item.comment || '').trim(),
                completedByName: item.completedByName || '',
                completedDateTime: item.completedDateTime || null,
                blocked: item.blocked === true,
                // PHASE 5. TRUE when this item records an output somewhere other than its own row
                // (financing detail on Loan__c, coverage on Insurance_Binder__c, an uploaded
                // document), so the click routes to the capture dialog rather than the plain
                // confirm dialog. Resolved SERVER-SIDE from the coordinate
                // (group letter + sequence) by ChecklistCaptureDefProvider — never from the
                // subject text, and never re-derived here.
                hasCapture: item.hasCapture === true
            };
        });
        const total = group.total != null ? group.total : items.length;
        const complete =
            group.complete != null ? group.complete : items.filter((i) => i.done).length;
        return {
            key: group.id,
            letter: group.letter || '',
            name: group.name || '',
            ownerLabel: group.ownerLabel || '',
            conditional: group.conditional === true,
            // Stage first, letter as the documented fallback for an unstamped group.
            phaseKey: phaseKeyForStage(group.stage) || phaseKeyForLetter(group.letter),
            total,
            complete,
            pct: group.pct != null ? group.pct : percent(complete, total),
            items
        };
    });
}
