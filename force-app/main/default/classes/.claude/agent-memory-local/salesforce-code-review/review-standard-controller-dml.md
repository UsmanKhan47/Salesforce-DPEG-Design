---
name: review-standard-controller-dml
description: DML + business logic living in LWC controllers is pre-existing accepted debt from the P4 cleanup wave — warn, don't block; but reject class headers that miscite the rules as sanctioning it
metadata:
  type: feedback
---

Several LWC controllers (e.g. `LeaseInquiryController`) hold DML, transaction management and
business logic that `.claude/rules/apex-layering-rule.md` reserves for the Service layer
(Controller row: "Thin: call service, catch AuraHandledException"; prohibits business logic).

**Why:** the P4 cleanup wave **deliberately scoped itself to SOQL only** — it moved every
inline query into Selectors and left DML in place. That was accepted at the time. Blocking a
new, validated feature on debt a prior accepted phase consciously deferred is inconsistent
review, so treat it as a WARNING plus a tracked extraction item, not CHANGES REQUIRED —
unless the change is what *introduces* the violation.

**How to apply:** the thing actually worth pushing on is the **justification text**, not the
code. A class header that claims the rules bless a pattern they prohibit will be copied by the
next developer and turns a tracked deferral into a fake convention. Require it to read as an
accepted deferral with a pointer to the extraction item. ARCHITECTURE.md's "written
justification" escape hatch means *honest* justification, not a citation that does not check
out — always open the cited file.

**UPDATE 2026-07-21 — the P6 controller-thinning sweep resolved most of this debt.** The 13
write controllers (incl. `LeaseInquiryController`) now delegate DML/business logic to a
like-named `*Service`; their headers correctly cite `apex-layering-rule.md` for moving the DML
*out*, not for keeping it in. The old miscited-header example is gone. Residual controller-layer
findings as of 2026-07-21 are NOT about DML-in-controller: (a) `LeaseInquiryController` has 6
read methods with no try/catch — a §5 boundary gap, not a layering one (its sibling
`LeaseRenewalController` is the correct wrap-every-method pattern); (b) `OpportunityApprovalController`
was NOT thinned by P6 and still holds Approval.process orchestration + parent resolution +
error-derivation in the controller, and leaks `e.getMessage()` raw at the §5 boundary. Treat
(b)'s layering as warn-not-block per the accepted-debt stance above; the raw-message leak is a
straightforward §5 fix.

Related: [[review-standard-system-debug]]
