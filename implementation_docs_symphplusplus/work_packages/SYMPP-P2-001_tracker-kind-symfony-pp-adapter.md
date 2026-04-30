# SYMPP-P2-001 — `tracker.kind: Symphony_pp` adapter

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 2 — Symphony adapter |
| Kind | adapter |
| Owner role | worker |
| Dependencies | SYMPP-P1-001, SYMPP-P1-003, SYMPP-P1-004 |

## Summary

Expose Symphony++ WorkPackages as normalized Symphony issues so the existing orchestrator can dispatch them.

## Implementation tasks

- Add config support for `tracker.kind: Symphony_pp`.
- Implement adapter functions expected by upstream tracker interface.
- Map WorkPackage fields to normalized issue fields.
- Return only eligible active states.
- Preserve existing Linear adapter behavior.

## Acceptance criteria

- [ ] Symphony++ packages appear as dispatchable issues.
- [ ] Terminal/blocked packages are filtered or represented according to config.
- [ ] Existing Linear tests pass.
- [ ] Adapter is covered by tests.

## Test plan

### Unit tests

- Map WorkPackage to issue.
- Filter by active states.
- Exclude terminal states.
- Preserve labels/priority/blockers if represented.

### Integration / E2E tests

- Run orchestrator polling against test Symphony++ packages.
- Run existing Linear adapter tests if present.

### Negative / regression tests

- Do not remove Linear config.
- Do not hard-code Kraken-specific fields.


## Deliverables

- Implementation PR for `SYMPP-P2-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P2-001: `tracker.kind: Symphony_pp` adapter.

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

Package dependencies: SYMPP-P1-001, SYMPP-P1-003, SYMPP-P1-004.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
