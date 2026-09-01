/**
 * c-sell-meter-override-modal — LightningModal suite.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 sfdx-lwc-jest SHIPS NO `lightning/modal` STUB — READ jest-mocks/lightning/modal.js
 * ─────────────────────────────────────────────────────────────────────────────
 * A repo-local stub is mapped in via `jest.config.js` -> moduleNameMapper. Because it
 * extends LightningElement, the modal is mounted DIRECTLY with `createElement` here and
 * driven like any other component; `close(result)` is observed through the stub's `close`
 * CustomEvent. There is no promise to await, because there is no platform `open()` in
 * play — that path is exercised from the OPENER's suite (`c-sell-meter-list`), which
 * mocks this module wholesale. Same arrangement as `c/sellMeterInitiateModal`.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING ASSERTIONS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. THE REASON IS MANDATORY, AND THE DISABLED BUTTON IS WHAT MAKES IT SO. `required` on
 *    a `lightning-textarea` only fires through `reportValidity()`, which nothing calls
 *    here — it draws the asterisk and nothing else. Both halves are pinned separately
 *    (the attribute AND the disabled state), because a test asserting only `required`
 *    passes against a dialog that can return a blank reason.
 * 2. WHITESPACE IS NOT A REASON. A textarea holding only spaces must keep the button
 *    disabled and must never be closed with. The field is read by an approving principal
 *    on the approval screen; " " in it is worse than nothing, because it looks answered.
 * 3. THE RESOLVED SHAPE IS `{ confirmed, reason }`, NEVER A BARE BOOLEAN. Resolving a
 *    boolean is exactly the shape of `LightningConfirm`, which this component exists to
 *    replace precisely because a boolean cannot carry a reason. A regression to it would
 *    make the caller's `answer.confirmed` read `undefined` — falsy, so the override would
 *    silently stop working with a green suite on both sides.
 * 4. THE PROPERTY IS NAMED IN THE QUESTION. The retired confirm put it in its message and
 *    the caller's suite pinned it. A confirmation that does not name its subject asks the
 *    user to confirm a word rather than a decision, and this dialog is reached from a
 *    table where every row offers the same button.
 * 5. THE WARNING BAND USES `*-base-95` / `*-base-40`, NOT `warning-container-1`. That
 *    substitution is dark-on-dark under the `slds` base theme and NO OTHER GATE IN THIS
 *    PIPELINE CATCHES IT — the SLDS linter only checks that a hook was used, and axe's
 *    colour-contrast rule is inert in jsdom. The source-text assertion below is the only
 *    falsifier that exists.
 *
 * ⚠ WHY SOME ASSERTIONS READ ELEMENT PROPERTIES RATHER THAN TEXT. `lightning-textarea`'s
 * Jest stub renders an EMPTY template, so its label and value never reach jsdom's text
 * content. The strongest available statement is the property read off the element in the
 * shadow root — which is what the TEMPLATE passed it. Deliberately NOT the component's
 * getter: this repo has a measured defect where a getter-only assertion stayed green while
 * the rendered binding was wrong.
 */
import { createElement } from 'lwc';
import SellMeterOverrideModal from 'c/sellMeterOverrideModal';

const PROPERTY = 'Harbor Point';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not cosmetic
// and not optional: the file NAMES the banned token in prose ("NOT `warning-container-1`"),
// so the absence assertion would fail against its own documentation. Same convention as
// c-sell-meter-initiate-modal's T-GRID block and c-competing-broker-submissions' T2.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'sellMeterOverrideModal.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

/** One rule's body out of the comment-stripped stylesheet, or ''. */
function rule(selector) {
    const match = new RegExp(
        '(?:^|[};])\\s*' + selector.replace(/\./g, '\\.') + '(?![\\w-])\\s*\\{([^}]*)\\}'
    ).exec(CSS_SOURCE);
    return match ? match[1] : '';
}

describe('c-sell-meter-override-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = {}) {
        const element = createElement('c-sell-meter-override-modal', {
            is: SellMeterOverrideModal
        });
        Object.assign(element, { propertyName: PROPERTY }, props);
        document.body.appendChild(element);
        return element;
    }

    const textarea = (el) => el.shadowRoot.querySelector('.smo-reason');
    const confirmBtn = (el) => el.shadowRoot.querySelector('.smo-confirm');
    const cancelBtn = (el) => el.shadowRoot.querySelector('.smo-cancel');
    const warning = (el) => el.shadowRoot.querySelector('.smo-warning');

    /** Types into the reason field the way lightning-textarea reports a change. */
    async function type(element, value) {
        textarea(element).dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        await Promise.resolve();
    }

    /** Captures the modal's close payload. */
    function listenForClose(element) {
        const handler = jest.fn();
        element.addEventListener('close', handler);
        return handler;
    }

    // ── 4. THE QUESTION NAMES THE PROPERTY ───────────────────────────────────

    it('🔴 names the property in the override question', async () => {
        const element = createComponent();

        await Promise.resolve();

        const text = warning(element).textContent;
        expect(text).toContain(PROPERTY);
        // The band rule is stated in DAYS, not in a colour name — the user is not looking
        // at the legend when this dialog is over the top of it.
        expect(text).toContain('31 to 90 days');
        expect(text).toContain('overrides the sell meter');
    });

    it('falls back to "this property" rather than rendering undefined', async () => {
        const element = createComponent({ propertyName: undefined });

        await Promise.resolve();

        expect(warning(element).textContent).toContain('this property');
        expect(element.shadowRoot.innerHTML).not.toContain('undefined');
    });

    it('announces the warning to assistive tech', async () => {
        const element = createComponent();

        await Promise.resolve();

        // role=alert, NOT alertdialog: lightning-modal already carries dialog semantics
        // and nesting a second dialog role inside it is invalid.
        expect(warning(element).getAttribute('role')).toBe('alert');
    });

    // ── 1 + 2. THE MANDATORY REASON ──────────────────────────────────────────

    /**
     * 🔴 THE PRESENCE HALF OF THE MANDATORY-REASON PIN. Asserted separately from the
     * disabled state below because the two are independent mechanisms and only one of
     * them actually enforces anything — `required` draws the asterisk, `confirmDisabled`
     * is the gate. A single assertion covering "it is required" would pass against a
     * dialog whose button is always enabled.
     */
    it('renders the reason field as required, with a question for a label', async () => {
        const element = createComponent();

        await Promise.resolve();

        const field = textarea(element);
        expect(field).not.toBeNull();
        expect(field.required).toBe(true);
        // A question is answerable; a label reading "Reason" invites "override" as an
        // answer, and this text is read by a different person than the one typing it.
        expect(field.label).toBe('Why are you overriding the sell meter?');
    });

    it('🔴 Continue is DISABLED until a reason is typed, and enabled after', async () => {
        const element = createComponent();

        await Promise.resolve();

        // Presence-then-absence on ONE instance: the disabled state is asserted BEFORE and
        // AFTER on the same component, so neither half can pass because the control was
        // deleted.
        expect(confirmBtn(element).disabled).toBe(true);

        await type(element, 'Fund matures in Q3.');

        expect(confirmBtn(element).disabled).toBe(false);
    });

    it('🔴 whitespace is not a reason — Continue stays disabled', async () => {
        const element = createComponent();

        await Promise.resolve();
        await type(element, '   \n\t  ');

        expect(confirmBtn(element).disabled).toBe(true);
    });

    it('🔴 clearing the reason re-disables Continue', async () => {
        const element = createComponent();

        await Promise.resolve();
        await type(element, 'A reason.');
        expect(confirmBtn(element).disabled).toBe(false);

        await type(element, '');

        expect(confirmBtn(element).disabled).toBe(true);
    });

    /**
     * The handler's own guard, independent of the disabled attribute. A disabled attribute
     * is a rendering instruction; `handleConfirm` is a handler and can be reached. This
     * component's sibling has a documented incident of a row-action payload diverging from
     * what its column definition said.
     */
    it('🔴 clicking Continue with a blank reason closes NOTHING', async () => {
        const element = createComponent();
        const closed = listenForClose(element);

        await Promise.resolve();
        confirmBtn(element).click();
        await Promise.resolve();

        expect(closed).not.toHaveBeenCalled();
    });

    // ── 3. THE RESOLVE CONTRACT ──────────────────────────────────────────────

    it('🔴 confirms with { confirmed: true, reason }, NOT a bare boolean', async () => {
        const element = createComponent();
        const closed = listenForClose(element);

        await Promise.resolve();
        await type(element, 'Fund matures in Q3 and the buyer pool is deep.');
        confirmBtn(element).click();
        await Promise.resolve();

        expect(closed).toHaveBeenCalledTimes(1);
        const payload = closed.mock.calls[0][0].detail;
        expect(payload).toEqual({
            confirmed: true,
            reason: 'Fund matures in Q3 and the buyer pool is deep.'
        });
        // 🔴 A bare boolean is the shape of LightningConfirm — the thing this component
        // exists to replace. A regression to it makes the caller's `answer.confirmed` read
        // `undefined` (falsy), so the override silently stops working with a green suite on
        // both sides of the boundary.
        expect(typeof payload).toBe('object');
    });

    it('trims the reason before resolving it', async () => {
        const element = createComponent();
        const closed = listenForClose(element);

        await Promise.resolve();
        await type(element, '   Market window closes in October.   ');
        confirmBtn(element).click();
        await Promise.resolve();

        expect(closed.mock.calls[0][0].detail.reason).toBe(
            'Market window closes in October.'
        );
    });

    it('cancels with { confirmed: false } and no reason', async () => {
        const element = createComponent();
        const closed = listenForClose(element);

        await Promise.resolve();
        // Typed and then cancelled: the reason must NOT travel back on a refusal.
        await type(element, 'changed my mind');
        cancelBtn(element).click();
        await Promise.resolve();

        expect(closed).toHaveBeenCalledTimes(1);
        expect(closed.mock.calls[0][0].detail).toEqual({ confirmed: false });
    });

    // ── 5. SLDS 2 TOKENS ─────────────────────────────────────────────────────

    /**
     * 🔴 THE ONLY FALSIFIER FOR A DARK-ON-DARK WARNING BAND.
     * `--slds-g-color-warning-container-1` reads like a pale container and resolves to a
     * SOLID mid-orange (#dd7a01) under the `slds` base theme, so pairing it with dark text
     * is unreadable — and it passes the SLDS linter (which only checks a hook was used),
     * Jest (which asserts class names) and axe (whose colour-contrast rule is inert in
     * jsdom). Another file in this repo ships that exact pairing today.
     */
    it('🔴 the warning band uses base-95/base-40, never warning-container-1', () => {
        const band = rule('.smo-warning');

        expect(band).toMatch(/--slds-g-color-warning-base-95/);
        // Warning is the one semantic whose readable text step is -40, not -30.
        expect(band).toMatch(/--slds-g-color-warning-base-40/);
        expect(band).not.toMatch(/container-1/);
    });

    it('uses only SLDS design tokens for colour — no hardcoded values outside fallbacks', () => {
        // Every colour-bearing declaration must START with var(--slds-, so the literal is
        // only ever reachable as a documented fallback.
        const declarations = CSS_SOURCE.match(
            /(?:^|[;{])\s*(?:background|color|box-shadow)\s*:[^;}]+/g
        ) || [];
        expect(declarations.length).toBeGreaterThan(0);
        declarations.forEach((d) => {
            const value = d.slice(d.indexOf(':') + 1).trim();
            expect(value.startsWith('var(--slds-') || value.startsWith('inset')).toBe(true);
        });
    });

    // ── ACCESSIBILITY ────────────────────────────────────────────────────────

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible with a reason typed', async () => {
        const element = createComponent();

        await Promise.resolve();
        await type(element, 'Fund matures in Q3.');

        await expect(element).toBeAccessible();
    });
});
