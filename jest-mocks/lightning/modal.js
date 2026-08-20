/**
 * lightning/modal — LOCAL JEST STUB
 * =============================================================================
 * 🔴 THIS FILE EXISTS BECAUSE sfdx-lwc-jest DOES NOT SHIP A `lightning/modal`
 * STUB. Verified against @salesforce/sfdx-lwc-jest 7.9.0: its
 * `src/lightning-stubs/` directory carries `modalHeader`, `modalBody` and
 * `modalFooter` but NOT `modal` itself. The resolver
 * (`sfdx-lwc-jest/src/resolver.js`) returns `undefined` for an unknown
 * `lightning/*` module and falls through to the plain node resolver, so
 * `import LightningModal from 'lightning/modal'` fails the whole suite with
 * "Cannot find module 'lightning/modal'" — a MODULE-RESOLUTION error, which
 * reads nothing like "you need a stub" and sends the reader hunting for a typo.
 *
 * Wired in through `jest.config.js` -> `moduleNameMapper`, which Jest applies
 * BEFORE the resolver, so it takes precedence over the (absent) stub lookup.
 *
 * ── WHY IT LIVES AT THE REPO ROOT AND NOT UNDER force-app/ ──────────────────
 * `sfdx-project.json`'s only package directory is `force-app/main/default`.
 * Anything under this root `jest-mocks/` folder is structurally outside every
 * deployable path, so no `.forceignore` entry is needed and no future widening
 * of an ignore rule can accidentally push a Jest stub at the org. (`__tests__`
 * is protected by a `.forceignore` GLOB, which is a weaker guarantee — see the
 * Account/** incident documented in `.forceignore` itself.)
 *
 * ── WHAT THE REAL API IS, AND WHAT THIS REPRODUCES ─────────────────────────
 * A modal component extends this class and calls `this.close(result)`; a CALLER
 * invokes the static `open({ size, label, description, ...publicProps })`, which
 * resolves to whatever `close()` was passed (or `undefined` when the user
 * dismisses it). This stub reproduces:
 *
 *   - the public props the platform sets from `open()`'s argument object
 *     (`label`, `size`, `description`, `disableClose`), so a subclass can be
 *     mounted directly with `createElement` and driven like any other component;
 *   - `close(result)` as a public method that dispatches a catchable `close`
 *     CustomEvent carrying the result in `detail` — this is the ONLY handle a
 *     test has on the modal's return value, since there is no promise to await
 *     when the component is mounted directly;
 *   - a static `open()` that THROWS.
 *
 * 🔴 THE THROWING `open()` IS DELIBERATE AND MIRRORS `lightning/confirm`'s OWN
 * SHIPPED STUB, which throws the same way. A component that OPENS a modal must
 * replace the modal module in its own suite:
 *
 *     jest.mock('c/sellMeterInitiateModal', () => ({
 *         __esModule: true,
 *         default: { open: jest.fn() }
 *     }));
 *
 * The alternative — a static `open()` that silently resolved `undefined` —
 * would make every "the caller acts on the modal's result" test pass while
 * asserting nothing, which is precisely the green-but-meaningless failure mode
 * this project has been bitten by before. Failing loudly is the feature.
 */
import { LightningElement, api } from 'lwc';

export default class LightningModal extends LightningElement {
    /** Accessible name, set by the platform from `open({ label })`. */
    @api label;
    /** 'small' | 'medium' | 'large' | 'full', set from `open({ size })`. */
    @api size;
    /** Long description for assistive tech, set from `open({ description })`. */
    @api description;
    /** When true the platform suppresses the close (X) button and ESC. */
    @api disableClose = false;

    /**
     * Closes the modal with a result. In the platform this resolves the promise
     * returned by `open()`; here it dispatches a `close` event so a test that
     * mounted the modal directly can assert the payload.
     *
     * ⚠ STUB ARTEFACT — `close()` WITH NO ARGUMENT ARRIVES AS `detail === null`,
     * NOT `undefined`. That is `CustomEvent`'s own coercion (the DOM spec
     * defaults `detail` to `null`), not a behaviour of the real LightningModal,
     * whose `open()` promise genuinely resolves `undefined` on a dismiss. Assert
     * FALSINESS, or `toBeNull()` with this note beside it — never `toBeUndefined()`
     * — and make sure the consuming component treats both the same way (every
     * caller in this repo does: `if (!result) return;`).
     *
     * @param {*} [result] the value the opener receives
     */
    @api
    close(result) {
        this.dispatchEvent(new CustomEvent('close', { detail: result }));
    }

    /**
     * @throws always — see the block comment above. Mock the modal module in
     *         the OPENING component's test instead.
     */
    static open() {
        throw new Error(
            "lightning/modal's Jest stub does not implement open(). Mock the " +
                'modal module in the opening component\'s test: ' +
                "jest.mock('c/<theModal>', () => ({ __esModule: true, default: { open: jest.fn() } }))"
        );
    }
}
