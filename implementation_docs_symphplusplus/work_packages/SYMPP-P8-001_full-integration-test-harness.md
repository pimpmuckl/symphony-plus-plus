# SYMPP-P8-001 — Full integration test harness

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 8 — Hardening and pilot |
| Kind | hardening |
| Owner role | worker |
| Dependencies | SYMPP-P4-003, SYMPP-P6-003, SYMPP-P7-003 |

## Summary

Build a durable integration test harness covering standalone, MCP, GitHub/review gates, and architect delegation flows.

## Implementation tasks

- Consolidate E2E scenarios into CI profile or documented local profile.
- Add fixtures/fakes for GitHub and review-suite results.
- Add two-package phase test.
- Add failure-mode tests for invalid grants and scope drift.
- Document how to run.

## Acceptance criteria

- [ ] One command runs core Symphony++ integration suite or documented profile.
- [ ] Standalone hotfix scenario passes.
- [ ] Phase architect scenario passes.
- [ ] Security denial scenarios pass.
- [ ] CI feasibility documented.

## Test plan

### Unit tests

- Covered by existing unit suites.

### Integration / E2E tests

- Run full E2E test profile.
- Verify fake GitHub/review services behave deterministically.

### Negative / regression tests

- Do not require real production credentials for default tests.
- Do not make tests flaky due to network.


## Deliverables

- Implementation PR for `SYMPP-P8-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P8-001: Full integration test harness.

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

Package dependencies: SYMPP-P4-003, SYMPP-P6-003, SYMPP-P7-003.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
