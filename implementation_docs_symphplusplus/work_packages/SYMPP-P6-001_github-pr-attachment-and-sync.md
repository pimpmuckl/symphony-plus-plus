# SYMPP-P6-001 — GitHub PR attachment and sync

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 6 — GitHub/review integration |
| Kind | integration |
| Owner role | worker |
| Dependencies | SYMPP-P4-003, SYMPP-P5-001 |

## Summary

Attach and synchronize GitHub PR metadata, including branch, head SHA, changed files, CI/check summary, review state, and merge state.

## Implementation tasks

- Implement PR attachment validation.
- Add GitHub client abstraction.
- Fetch PR metadata by URL/number.
- Store PR artifact with head SHA and branch.
- Poll or webhook-sync CI/review/merge state.
- Update package readiness inputs.

## Acceptance criteria

- [ ] Attached PR metadata is stored and visible.
- [ ] Head SHA changes are detected.
- [ ] CI/review/merge state can be fetched in test/dry mode.
- [ ] Readiness gates can depend on current PR state.

## Test plan

### Unit tests

- Parse PR URL.
- Map GitHub metadata to artifact/state.
- Detect stale artifact head SHA.
- Handle API errors.

### Integration / E2E tests

- Attach test/mock PR and sync metadata.
- Verify dashboard detail shows PR state.
- Existing readiness fails when PR state is missing/stale.

### Negative / regression tests

- Do not require GitHub sync for investigation packages.
- Do not expose GitHub tokens.


## Deliverables

- Implementation PR for `SYMPP-P6-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P6-001: GitHub PR attachment and sync.

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

Package dependencies: SYMPP-P4-003, SYMPP-P5-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
