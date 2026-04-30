# SYMPP-P1-003 — Lifecycle state machine and policy templates

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 1 — Core ledger |
| Kind | core |
| Owner role | worker |
| Dependencies | SYMPP-P1-001, SYMPP-P1-002 |

## Summary

Add server-side lifecycle validation and policy templates for quick-fix, hotfix, phase-child, and investigation packages.

## Implementation tasks

- Define allowed statuses for standalone and phase-child packages.
- Implement transition validation.
- Add policy templates with required gates, expiry defaults, planning depth, and review-suite requirements.
- Attach expanded policy to WorkPackage or compute it reliably.
- Add transition event recording if event ledger exists; otherwise leave hook for P1-005.

## Acceptance criteria

- [ ] Invalid transitions are rejected.
- [ ] Policy templates expand into constraints/readiness requirements.
- [ ] Standalone hotfix and phase-child have different terminal readiness states.
- [ ] Worker cannot mark merged through lifecycle API.

## Test plan

### Unit tests

- Allowed transitions pass.
- Invalid transitions fail.
- quick_fix/hotfix/phase_child/investigation templates expand correctly.
- Worker capability cannot transition to merged.

### Integration / E2E tests

- Create hotfix and drive status through happy path to ready_for_human_merge.
- Create phase child and drive to ready_for_architect_merge.

### Negative / regression tests

- Do not allow created -> merged.
- Do not allow worker to advance phase state.


## Deliverables

- Implementation PR for `SYMPP-P1-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P1-003: Lifecycle state machine and policy templates.

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

Package dependencies: SYMPP-P1-001, SYMPP-P1-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
