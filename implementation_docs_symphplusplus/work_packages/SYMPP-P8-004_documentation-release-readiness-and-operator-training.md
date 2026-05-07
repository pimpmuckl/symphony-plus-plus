# SYMPP-P8-004 — Documentation, release readiness, and operator training

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 8 — Hardening and pilot |
| Kind | docs |
| Owner role | worker |
| Dependencies | SYMPP-P8-001, SYMPP-P8-002 |

## Summary

Finalize documentation for operators, architects, workers, reviewers, setup, troubleshooting, and release gates.

This narrowed slice only owns the release validation policy ratchet and focused
release-readiness documentation. The broader operator-training rewrite remains
outside this PR.

## Implementation tasks

- Write operator guide.
- Write architecture-agent guide.
- Write worker-agent guide.
- Write reviewer checklist.
- Update setup docs.
- Create troubleshooting section.
- Document known limitations.

## Acceptance criteria

- [ ] Docs cover standalone and phase-based flows.
- [ ] A new operator can create a hotfix package from docs.
- [ ] Reviewer checklist exists.
- [ ] Known limitations are explicit.
- [ ] Release gate checklist exists.

## Test plan

### Unit tests

- Docs link checker if available.

### Integration / E2E tests

- Have an agent follow docs in dry run or test repo.
- Run existing tests to verify no docs-only breakage.

### Negative / regression tests

- Do not claim production readiness beyond proven scope.
- Do not omit security limitations.


## Deliverables

- Implementation PR for `SYMPP-P8-004`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P8-004: Documentation, release readiness, and operator training.

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

Package dependencies: SYMPP-P8-001, SYMPP-P8-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
