---
name: lwc-jest-scoped-run
description: Running a subset of LWC Jest suites via sfdx-lwc-jest — the benign "not recognized ... undefined" warning
metadata:
  type: reference
---

Scoped LWC Jest runs use bare positional name-patterns:
`npm test -- brokerAssignmentActions brokerAssignmentDetail ...`

sfdx-lwc-jest (7.9.0 in this repo) prints a red line:
`error The following argument(s) are not recognized by lwc-jest: undefined`
and even dumps its `--help`. **This is benign.** It still forwards every pattern
to Jest as an OR-regex and runs exactly those suites — confirm via the tail line
`Ran all test suites matching /pat1|pat2|.../i` and the `Test Suites: N passed`
summary. Trust the PASS/FAIL summary, not the warning.

Toolchain (already installed, nothing to add): sfdx-lwc-jest 7.9.0 + @sa11y/jest,
config in `jest.config.js` + `jest.setup.js` (registers `toBeAccessible()`).
Apex wire mocks use `createApexTestWireAdapter` from `@salesforce/sfdx-lwc-jest`;
`@salesforce/apex` (`refreshApex`) and `lightning/uiRecordApi`
(`notifyRecordUpdateAvailable`, `getRecord`) are auto-stubbed — do not `jest.mock`
them.
