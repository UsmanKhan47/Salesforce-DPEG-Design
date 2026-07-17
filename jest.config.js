/**
 * Jest configuration for DPEG Lightning Web Components.
 *
 * Extends the Salesforce-maintained sfdx-lwc-jest preset (which wires the LWC
 * compiler, jsdom environment, and the `lightning/*` / `@salesforce/*` module
 * mocks) and layers in the @sa11y/jest accessibility matchers.
 *
 * jest.setup.js calls @sa11y/jest's setup() to register the `toBeAccessible()`
 * matcher on every test, per ARCHITECTURE.md §5. (In @sa11y/jest v8 the bare
 * "@sa11y/jest" module no longer auto-registers on import — setup() must run.)
 *
 * These tests run locally / in CI only. `.forceignore` excludes **\/__tests__\/**
 * so nothing here is ever deployed to the org.
 */
const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    setupFilesAfterEnv: [
        ...(jestConfig.setupFilesAfterEnv || []),
        '<rootDir>/jest.setup.js'
    ]
    // NOTE: coverage is intentionally left to the sfdx-lwc-jest default, which
    // reports only the component modules a test actually exercises. Do not add a
    // broad `collectCoverageFrom` glob over all 82 bundles until most have suites
    // — it drowns real coverage in empty 0% rows and misreports namespaced
    // (`c/*`) modules. A repo-wide coverage threshold gate is a later-phase task.
};
