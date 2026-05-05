# SYMPP-P5-004 — Runtime observability and alerts

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 5 — Dashboard |
| Kind | dashboard |
| Owner role | worker |
| Dependencies | SYMPP-P2-003, SYMPP-P5-001 |

## Summary

Add runtime view and basic alert indicators for stale agents, blockers, scope drift, missing readiness evidence, and failed runs.

## Implementation tasks

- Expose active/queued/stopped AgentRuns.
- Add stale heartbeat detection.
- Add blockers and missing-evidence indicators.
- Add scope-drift placeholder until GitHub sync lands.
- Document alert thresholds.

## Alert thresholds

- Active or queued AgentRuns are flagged as stale when `last_seen_at` is at least 300 seconds old.
- Stale heartbeat indicators are read-only dashboard hints. They do not stop, retry, revoke, page, notify, or otherwise mutate runtime state.
- Scope drift remains a placeholder in this package. It is surfaced as not configured until a later GitHub-sync package owns changed-file evidence.

## Acceptance criteria

- [ ] Human can see active worker runs and stale state.
- [ ] Blocked packages are obvious.
- [ ] Ready-but-missing-evidence packages are flagged.
- [ ] Runtime view does not control or mutate runs yet.

## Test plan

### Unit tests

- Stale calculation.
- Alert indicator calculation.
- Missing evidence calculation.

### Integration / E2E tests

- Create stale/fresh runs and verify API/UI state.
- Create blocked package and verify board indicator.

### Negative / regression tests

- Do not page/notify externally yet unless explicitly configured.
- Do not expose secrets in runtime logs.


## Deliverables

- Implementation PR for `SYMPP-P5-004`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P5-004: Runtime observability and alerts.

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

Package dependencies: SYMPP-P2-003, SYMPP-P5-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
