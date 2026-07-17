/**
 * Registers the @sa11y/jest accessibility matchers on Jest's `expect`, making
 * `await expect(element).toBeAccessible()` available in every LWC test.
 *
 * As of @sa11y/jest v8 the package `main` only re-exports — importing the bare
 * "@sa11y/jest" module no longer auto-registers the matcher. Registration must
 * be invoked explicitly via setup(), which also installs sa11y's custom axe
 * rules. Automatic per-test checks stay OFF by default (autoCheckOpts.runAfterEach
 * is false) — each test opts in with an explicit toBeAccessible() call.
 *
 * Loaded through jest.config.js -> setupFilesAfterEnv (after the LWC preset).
 */
const { setup } = require('@sa11y/jest');

setup();
