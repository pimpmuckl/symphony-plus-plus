# Test Strategy

## Test goals

Symphony++ must prove three things:

1. It preserves upstream Symphony behavior.
2. It enforces scoped work-package permissions.
3. It supports both quick standalone work and phase/architect delegation.

## Test categories

### Unit tests

- WorkPackage validation.
- AccessGrant secret generation and hashing.
- Grant claim validation.
- State-transition validation.
- Capability checks.
- Markdown renderers.
- Policy template expansion.
- Readiness gate predicates.

### Integration tests

- `tracker.kind: Symphony_pp` returns eligible packages.
- Existing Linear tracker behavior remains unchanged.
- MCP tools enforce scope.
- Worker can update own package.
- Worker cannot read sibling package.
- Architect can mint narrower child grant.
- Architect cannot mint out-of-scope child grant.
- Dashboard API reflects ledger state.

### End-to-end tests

- Standalone hotfix lifecycle.
- Worker claim and virtual-file update lifecycle.
- PR attachment and readiness check.
- Scope guard rejects out-of-scope changed files.
- Phase architect creates child packages and supervises ready state.

### Security tests

- Invalid secret rejected.
- Expired grant rejected.
- Revoked grant rejected.
- Already-claimed grant cannot be rebound unless policy explicitly allows continuation.
- Raw secret never appears in logs.
- Worker cannot list grants.
- Worker cannot mark merged.
- Worker cannot self-approve scope expansion.

## Required package-level testing fields

Every work package must specify:

- Unit tests.
- Integration tests.
- E2E/manual tests if applicable.
- Negative tests.
- Acceptance criteria.
- Regression checks for existing Symphony behavior.

## E2E milestone scenario

```text
Create hotfix work package.
Mint worker key.
Claim through MCP.
Read virtual files.
Append plan/progress/finding.
Attach branch and PR.
Simulate CI/review-suite artifact.
Mark ready for human merge.
Verify dashboard/API state.
Verify worker cannot access another package.
```

This scenario should become the primary regression test before any Kraken pilot.
