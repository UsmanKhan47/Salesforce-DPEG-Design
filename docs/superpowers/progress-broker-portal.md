# Broker Portal — Execution Progress Ledger

Plan: `docs/superpowers/plans/2026-06-22-broker-portal.md`
Target org: **DPEG-Acq-3** (Active, expires 2026-07-15). DPEG-Acq-2 expired/deleted.
No git in workspace → checkpoint = deploy + passing tests. Run `sf` in PowerShell.

| Task | Description | Status |
|---|---|---|
| 1 | Broker_Portal_Leads Queue | ✅ complete (deployed + verified) |
| 2 | Broker_Portal_New_Lead CustomNotificationType | ✅ complete (deployed + verified) |
| 3 | Controller skeleton + getFormMetadata | ✅ complete |
| 4 | submitDeal happy path | ✅ complete |
| 5 | submitDeal validation + honeypot | ✅ complete |
| 6 | submitDeal dedup | ✅ complete (12/12 tests; plan bug fixed: `in` is reserved → param renamed `sub`) |
| 7 | Invocable notifier + tests | ✅ complete (2/2 tests) |
| 8 | Notify Flow | ✅ complete (active; end-to-end submit verified in-transaction) |
| 9 | brokerDealIntakeForm LWC | ✅ complete (deployed clean; community targets accepted) |
| 10 | Experience site + guest access | 🟡 AUTOMATED: Digital Experiences enabled (user), site "DPEG Broker Portal" created via `sf community create`, guest profile granted Apex class access + Lead Create/Read. REMAINING (user, in Builder): place LWC on page → publish → activate → add queue members |
| 11 | End-to-end verification (MANUAL - user) | pending |

## Log
- (start) Verified DPEG-Acq-3 baseline: Lead custom fields present, 'Broker Portal' LeadSource valid, BrokerPortalController not yet present.
- Tasks 1-9 complete. Plan bug fixed (`in` reserved word → `sub`).
- Final whole-feature review (opus): no Critical; core security solid. Fixed 3 Important/Minor: queue now fails closed (never guest-owned), server-side length caps added, +5 validation tests, LWC max-length. Honeypot-only abuse control = accepted v1 limit (spec §11 deferred CAPTCHA).
- **Code build verified: 19/19 Apex tests pass (17 controller + 2 notifier); flow active; e2e submit confirmed in-transaction; LWC deployed.**
- **REMAINING = Tasks 10-11, MANUAL (user) in Setup: enable Digital Experiences, create LWR site, add LWC, guest permissions, queue members, then e2e guest test.**
