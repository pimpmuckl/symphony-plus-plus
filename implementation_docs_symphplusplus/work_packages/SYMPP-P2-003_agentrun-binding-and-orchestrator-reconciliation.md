# SYMPP-P2-003 — AgentRun binding and orchestrator reconciliation

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 2 — Symphony adapter |
| Kind | adapter |
| Owner role | worker |
| Dependencies | SYMPP-P1-002, SYMPP-P2-001 |

## Summary

Bind dispatched Symphony worker runs to Symphony++ AgentRun records and reconcile state on retries/stops.

## Implementation tasks

- Create AgentRun record when dispatcher starts a Symphony++ package.
- Bind AgentRun to WorkPackage and grant/session where available.
- Update last_seen/status during lifecycle.
- Handle stop/retry/reconciliation events.
- Prevent duplicate active runs for same package unless policy allows.

## Acceptance criteria

- [ ] Dispatched package has AgentRun record.
- [ ] Retry/stop updates AgentRun status.
- [ ] Duplicate dispatch is prevented or explicitly controlled.
- [ ] Dashboard/API can later use AgentRun state.

## Test plan

### Unit tests

- Create AgentRun.
- Update heartbeat/status.
- Prevent duplicate active run.
- Bind to grant if claim flow already known.

### Integration / E2E tests

- Simulate dispatch then stop/retry.
- Verify WorkPackage state remains consistent.

### Negative / regression tests

- Do not orphan active AgentRun on failed claim.
- Do not allow two active workers to mutate same package by accident.


## Deliverables

- Implementation PR for `SYMPP-P2-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P2-003: AgentRun binding and orchestrator reconciliation.

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

Package dependencies: SYMPP-P1-002, SYMPP-P2-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
