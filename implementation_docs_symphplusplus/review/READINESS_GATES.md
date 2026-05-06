# Readiness Gates

A WorkPackage can be marked ready only when all gates required by its policy template pass.

## Common gates

- WorkPackage status is eligible for readiness.
- No active blocker remains.
- Required plan nodes are complete or skipped with rationale.
- Acceptance criteria have evidence.
- Required PR exists.
- Required review-suite artifact exists in the latest review package for the current head SHA.
- Required CI/check status is green.
- Changed files are within allowed scope.
- Base branch matches package constraints.

## Phase-child additional gates

- Parent phase is active.
- Child package belongs to the phase and remains inside the architect anchor repo, base branch, and allowed file globs.
- Architect approval is required after worker readiness.

## Hotfix additional gates

- Grant has not expired or package has been reauthorized.
- Human merge is required.
- Hotfix review-suite profile passes.

## Investigation additional gates

- Recommendation evidence exists. `request_scope_expansion` records the protected worker recommendation and persists the canonical `recommendation.md` artifact for new investigation packages. Stored legacy `request_scope_expansion` rows do not satisfy readiness unless the canonical artifact already exists. It does not approve expanded scope.
- Findings are summarized.
- PR is not required unless package explicitly asks for one.
