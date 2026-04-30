# SYMPP-P6-003 — Changed-file scope guard and readiness gates

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 6 — GitHub/review integration |
| Kind | security |
| Owner role | worker |
| Dependencies | SYMPP-P6-001, SYMPP-P6-002, SYMPP-P1-003 |

## Summary

Enforce changed-file/base-branch/scope guard and combine readiness gates across plan, blockers, PR, CI, review suite, and scope.

## Implementation tasks

- Add allowed_file_globs/constraints to policy or package.
- Fetch changed files from PR metadata.
- Implement scope evaluation.
- Implement combined readiness gate service.
- Record failures as structured reasons.
- Allow scope expansion approval to update constraints.

## Acceptance criteria

- [ ] Out-of-scope changed files block readiness.
- [ ] Wrong base branch blocks readiness.
- [ ] Missing CI/review artifacts block readiness when required.
- [ ] Approved scope expansion permits new files.
- [ ] Readiness reasons are visible.

## Test plan

### Unit tests

- Glob matching.
- Wrong base branch fails.
- Out-of-scope file fails.
- Approved expansion passes.
- Active blocker fails.
- Incomplete required plan fails.

### Integration / E2E tests

- Attach PR with changed files; mark_ready fails/passes based on scope.
- Approve scope expansion and re-evaluate readiness.

### Negative / regression tests

- Worker cannot approve own expansion.
- Scope guard cannot be disabled by worker.


## Deliverables

- Implementation PR for `SYMPP-P6-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P6-003: Changed-file scope guard and readiness gates.

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

Package dependencies: SYMPP-P6-001, SYMPP-P6-002, SYMPP-P1-003.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
