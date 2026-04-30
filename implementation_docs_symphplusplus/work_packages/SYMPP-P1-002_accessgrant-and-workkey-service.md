# SYMPP-P1-002 — AccessGrant and WorkKey service

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 1 — Core ledger |
| Kind | security |
| Owner role | worker |
| Dependencies | SYMPP-P1-001 |

## Summary

Implement scoped grants and high-entropy one-time work keys for workers and architects.

## Implementation tasks

- Add AccessGrant schema/table/entity.
- Implement grant minting service.
- Generate short display keys and high-entropy secrets.
- Store only secret hash/verifier.
- Implement claim flow with expiry, revocation, and binding to AgentRun placeholder or claim identity.
- Redact raw secrets from logs/inspection.

## Acceptance criteria

- [ ] Worker grant can be minted for one WorkPackage.
- [ ] Claiming valid secret returns scoped assignment.
- [ ] Expired/revoked/invalid secrets are rejected.
- [ ] Raw secret is not stored.
- [ ] Raw secret is returned only at mint time.

## Test plan

### Unit tests

- Secret generation length/entropy shape.
- Secret hash stored; raw secret absent from persistence.
- Valid claim succeeds.
- Expired claim fails.
- Revoked claim fails.
- Invalid claim fails.
- Double claim follows explicit policy and is tested.

### Integration / E2E tests

- Create WorkPackage then mint and claim AccessGrant.
- Check logs/test output for no raw secret if feasible.

### Negative / regression tests

- Four-character display key alone must not authenticate.
- Worker grant cannot contain architect capabilities.


## Deliverables

- Implementation PR for `SYMPP-P1-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P1-002: AccessGrant and WorkKey service.

Read this package spec fully. Implement only this package's scope. Do not implement dependent packages. If you discover that the package requires broader scope, stop and request scope expansion with a concrete reason.

Before coding:
1. Inspect the current repository state.
2. Confirm the dependency packages are merged or available.
3. Create a brief implementation plan.

During coding:
1. Keep changes limited to this package.
2. Add or update tests from the package test plan.
3. Preserve existing Symphony behavior unless this package explicitly changes it.

Before PR:
1. Run the relevant tests.
2. Verify every acceptance criterion is satisfied or explain any exception.
3. Write a PR summary with test results and risk notes.

Package dependencies: SYMPP-P1-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
