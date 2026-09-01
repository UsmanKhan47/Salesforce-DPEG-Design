/**
 * c/utilsTransactionChecklist — the Transaction checklist's shared view model.
 *
 * ARCHITECTURE.md §5 puts shared utilities in `lwc/utils*` as stateless lowerCamelCase modules
 * with no `.html`. This one is deliberately SEPARATE from the general-purpose `c/utils` bundle:
 * `c/utils` is imported by dozens of components and is a hub file that a concurrent workstream
 * may be editing, whereas everything here is owned by three Transaction bundles and is expected
 * to be deleted wholesale when the legacy Task model retires at M5.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS MODULE EXISTS AT ALL: TWO DATA MODELS ARE LIVE AT THE SAME TIME.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The checklist is being migrated from standard `Task` rows to `Checklist__c` /
 * `Checklist_Item__c`, and Phase 4 cuts deals over ONE AT A TIME. So a single org — a single
 * user's single browser session — will show new-model deals and legacy deals side by side for
 * weeks.
 *
 * THE DISCRIMINATOR IS `Transaction__c.Checklist_Fanned_Out__c`, and nothing else:
 *   • true  -> `Checklist__c` / `Checklist_Item__c` via `ChecklistController.getChecklist`
 *   • false -> legacy `Task` rows via `TransactionTaskController.getTaskGroups`
 * It is a single-writer field (only `ChecklistFanoutService` writes it), which is what makes it
 * trustworthy: no seed script, no `TestDataFactory`, and no bypass flag can set it accidentally.
 * The components read it with LDS `getRecord` — ARCHITECTURE.md §5's first-choice data access,
 * and correct here because it is a single-record read with real record context.
 *
 * 🔴 WHEN THE DISCRIMINATOR CANNOT BE READ, NEITHER MODEL IS RENDERED. `modelFor` returns
 * `MODEL_UNKNOWN` and the components show an error, NOT a guess. Guessing legacy would be the
 * dangerous default: a deal already migrated to the new model STILL HAS its old `Task` rows
 * (design §7 leaves them in place deliberately), so a wrong guess renders a full, plausible,
 * stale checklist that nobody can tell is stale.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 RISK 1 — HOW THE SUBJECT-TEXT COUPLING IS RETIRED WITHOUT A WINDOW IN WHICH IT IS HALF-DONE
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Before Phase 3, `transactionTaskGroups.js` derived BOTH "is this critical" and "is this a wire
 * step" from a regex over the task subject. That coupling fails SILENTLY and in the unsafe
 * direction: clean up the subject text and the red CRITICAL rows simply stop rendering, with no
 * error anywhere.
 *
 * ✅ THE RETIREMENT IS ATOMIC BY CONSTRUCTION, NOT BY CAREFUL SEQUENCING. The same single flag
 * that selects the DATA SOURCE also selects the NORMALISER:
 *   • `normalizeChecklistGroups` (new model) reads `isCritical` / `isWireVerification` — real
 *     boolean fields — and CONTAINS NO REGEX AT ALL.
 *   • `normalizeLegacyGroups` (legacy model) keeps the regex, because `Task` genuinely carries no
 *     such fields (verified 2026-09-01: `objects/Activity/fields/` has no `Is_Wire_Verification__c`
 *     and no `Is_Critical__c`) and its subjects are frozen on rows that already exist.
 * There is therefore NO reachable state in which new-model data is read by a subject parser, or
 * legacy data by a boolean that does not exist on it. Each parser reads only the model whose data
 * actually carries what it reads.
 *
 * ⚠ `displaySubject` STILL STRIPS THE PARENTHETICAL, AND THAT IS COSMETIC ONLY. The CMDT subjects
 * still carry `(anti-fraud)` / `(CRITICAL - frequently missed)` — `scripts/load-transaction-task-defs.apex`
 * seeds `Is_Critical__c` and `Is_Wire_Verification__c` from an explicit `{B2,F12,I7,J4}` /
 * `{B2,I7}` key set, never from a parse, so the markers are decoration the UI hides. Its regex is
 * declared SEPARATELY from the legacy semantic ones on purpose: deleting the legacy pair at M5
 * must not silently change what the screen displays.
 *
 * @module c/utilsTransactionChecklist
 */

/** The deal is on `Checklist__c` / `Checklist_Item__c`. */
export const MODEL_CHECKLIST = 'checklist';

/** The deal is still on standard `Task` rows. */
export const MODEL_LEGACY = 'legacy';

/**
 * The discriminator could not be read. NOT a model — the caller must render an error, never fall
 * back to either model. See the class note above for why falling back to legacy is the worst of
 * the three options.
 */
export const MODEL_UNKNOWN = 'unknown';

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
 * 🔴 LEGACY-MODEL ONLY. Matches a PARENTHESISED `(anti-fraud)` or `(CRITICAL …)` marker in a
 * `Task.Subject`.
 *
 * ⚠ THE PARENTHESES ARE LOAD-BEARING AND A BARE `contains('critical')` IS WRONG. Items A4
 * (`Receive critical dates from title company`) and A5 (`Log critical dates into Salesforce deal
 * record`) both contain the word "critical" and are NOT critical items. The org renders exactly
 * four: {B2, F12, I7, J4}. Do not "simplify" this.
 *
 * ⚠ USED ONLY BY `normalizeLegacyGroups`. It must never be applied to `Checklist_Item__c` data,
 * which carries the real booleans.
 */
const LEGACY_CRITICAL_RE = /\(\s*(anti-?fraud|critical[^)]*)\s*\)/i;

/** 🔴 LEGACY-MODEL ONLY. The anti-fraud wire-verification marker. See `LEGACY_CRITICAL_RE`. */
const LEGACY_WIRE_RE = /\(\s*anti-?fraud\s*\)/i;

/**
 * COSMETIC ONLY. Strips the trailing marker from a subject for display.
 *
 * Declared separately from `LEGACY_CRITICAL_RE` even though the pattern is currently identical.
 * They have different lifetimes: the legacy semantic pair is deleted at M5 when the Task model
 * retires, while this one survives for as long as the CMDT subjects carry decoration. Sharing one
 * constant would make that deletion silently change what the screen renders.
 */
const DISPLAY_MARKER_RE = /\(\s*(anti-?fraud|critical[^)]*)\s*\)/i;

/**
 * Which model a deal is on.
 *
 * @param {boolean|null|undefined} fannedOut `Transaction__c.Checklist_Fanned_Out__c`.
 * @returns {string} `MODEL_CHECKLIST` when strictly `true`, `MODEL_LEGACY` when strictly `false`,
 *          `MODEL_UNKNOWN` for anything else (not loaded, unreadable, or an unexpected type).
 *          A checkbox is never null when it is readable, so `MODEL_UNKNOWN` genuinely means
 *          "we do not know", not "false".
 */
export function modelFor(fannedOut) {
    if (fannedOut === true) {
        return MODEL_CHECKLIST;
    }
    if (fannedOut === false) {
        return MODEL_LEGACY;
    }
    return MODEL_UNKNOWN;
}

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
    if (!subject) {
        return '';
    }
    return String(subject).replace(DISPLAY_MARKER_RE, '').trim();
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
                blocked: item.blocked === true
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

/**
 * Normalises `TransactionTaskController.getTaskGroups` output (legacy `Task` model) into the SAME
 * shared view model, so the rendering code is identical for both models and there is exactly one
 * template to keep correct.
 *
 * 🔴 THIS IS THE ONLY PLACE A SUBJECT IS PARSED FOR MEANING, AND IT IS CORRECT HERE. `Task`
 * carries no `Is_Critical__c` / `Is_Wire_Verification__c` — the markers in the frozen subjects of
 * already-created rows are genuinely the only signal available. Deleting this function is an M5
 * task, together with the two `LEGACY_*_RE` constants and the legacy wire in the components.
 *
 * ⚠ `blocked` IS ALWAYS FALSE HERE. `Task.Is_Prerequisite_Met__c` exists (Phase 0) but
 * `TransactionTaskController.TaskRow` does not expose it, and widening that DTO would mean
 * changing a live class that serves every un-migrated deal for a purely advisory badge. The
 * legacy server-side gate is unaffected: `TaskPrerequisiteService` still refuses the save and
 * `TransactionTaskController` still surfaces the refusal verbatim. The user simply learns about
 * the block when they act, exactly as they do today.
 *
 * @param {Array<object>|null|undefined} rows `GroupRow[]` from Apex.
 * @returns {Array<object>} normalised groups; `[]` for null/empty input.
 */
export function normalizeLegacyGroups(rows) {
    if (!Array.isArray(rows)) {
        return [];
    }
    return rows.map((group) => {
        const items = (group.tasks || []).map((task) => {
            const subject = task.subject || '';
            const critical = LEGACY_CRITICAL_RE.test(subject);
            const wire = LEGACY_WIRE_RE.test(subject);
            const done = task.done === true;
            return {
                id: task.id,
                subject: displaySubject(subject),
                rawSubject: subject,
                critical,
                wire,
                done,
                verifyComplete: task.verifyComplete === true,
                verified: wire && done && task.verifyComplete === true,
                verifiedByName: task.verifiedBy || '',
                verifiedAt: task.verifiedAt || null,
                phone: task.phone || '',
                comment: (task.notes || '').trim(),
                completedByName: task.completedByName || '',
                completedDateTime: task.completedDate || null,
                blocked: false
            };
        });
        const total = group.total != null ? group.total : items.length;
        const complete =
            group.complete != null ? group.complete : items.filter((i) => i.done).length;
        return {
            key: group.key,
            letter: group.letter || '',
            name: group.name || '',
            ownerLabel: group.ownerLabel || '',
            conditional: group.conditional === true,
            phaseKey: phaseKeyForLetter(group.letter),
            total,
            complete,
            pct: group.pct != null ? group.pct : percent(complete, total),
            items
        };
    });
}
