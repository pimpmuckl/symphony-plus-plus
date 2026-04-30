# SYMPP-P7-001 — Phase entity and architect grants

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 7 — Phase/architect delegation |
| Kind | delegation |
| Owner role | worker |
| Dependencies | SYMPP-P1-002, SYMPP-P1-003 |

## Summary

Add Phase/container entity and architect-scoped grants that can manage child packages but not arbitrary global state.

## Implementation tasks

- Add Phase schema/entity.
- Add architect grant scope for phase.
- Implement permission checks for phase-scoped actions.
- Add phase board read model.
- Add tests for out-of-scope denial.

## Acceptance criteria

- [ ] Phase can be created and read.
- [ ] Architect grant can access its phase.
- [ ] Architect grant cannot access unrelated phase.
- [ ] Worker grant cannot access phase board.

## Test plan

### Unit tests

- Create phase.
- Architect reads own phase.
- Architect denied other phase.
- Worker denied phase board.

### Integration / E2E tests

- Create phase, mint architect grant, claim/read phase board.
- Run existing standalone hotfix flow to ensure no phase dependency introduced.

### Negative / regression tests

- Do not require standalone packages to have phase.
- Do not give architect global admin by default.


## Deliverables

- Implementation PR for `SYMPP-P7-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P7-001: Phase entity and architect grants.

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

Package dependencies: SYMPP-P1-002, SYMPP-P1-003.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
