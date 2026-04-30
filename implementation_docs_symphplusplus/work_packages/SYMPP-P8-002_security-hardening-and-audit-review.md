# SYMPP-P8-002 — Security hardening and audit review

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 8 — Hardening and pilot |
| Kind | security |
| Owner role | worker |
| Dependencies | SYMPP-P6-003, SYMPP-P7-002 |

## Summary

Perform focused security hardening on secrets, permissions, redaction, grants, scope expansion, and audit trails.

## Implementation tasks

- Review all logging paths for secrets.
- Add redaction tests around grants/tokens.
- Review permission checks for every MCP/API action.
- Add audit events for override/revocation/scope approval.
- Document residual risks.

## Acceptance criteria

- [ ] No raw grant secrets in logs/tests/API.
- [ ] Every MCP/API mutating action checks grant capability.
- [ ] Revocation/override/scope approval are auditable.
- [ ] Residual risks document exists.

## Test plan

### Unit tests

- Redaction tests.
- Capability check tests per endpoint/tool.
- Revocation audit event.
- Override audit event.

### Integration / E2E tests

- Attempt common unauthorized actions across API/MCP.
- Run full test suite with secret-grep if feasible.

### Negative / regression tests

- Do not rely on prompt wording for security.
- Do not leave admin endpoints unauthenticated.


## Deliverables

- Implementation PR for `SYMPP-P8-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P8-002: Security hardening and audit review.

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

Package dependencies: SYMPP-P6-003, SYMPP-P7-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
