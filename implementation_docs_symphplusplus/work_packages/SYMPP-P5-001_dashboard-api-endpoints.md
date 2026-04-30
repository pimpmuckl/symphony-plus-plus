# SYMPP-P5-001 — Dashboard API endpoints

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 5 — Dashboard |
| Kind | dashboard |
| Owner role | worker |
| Dependencies | SYMPP-P1-004, SYMPP-P1-005, SYMPP-P2-003 |

## Summary

Add read-oriented API endpoints for board, work package detail, timeline, artifacts, blockers, grants, and agent runs.

## Implementation tasks

- Implement board endpoint grouped by status.
- Implement work-package detail endpoint.
- Implement timeline/events endpoint.
- Expose artifact and run summaries.
- Apply redaction and role-aware fields.

## Acceptance criteria

- [ ] Dashboard API returns useful state for standalone packages.
- [ ] Raw secrets are never returned.
- [ ] Timeline includes progress/finding/status events.
- [ ] API tests cover redaction.

## Test plan

### Unit tests

- Serialize package card.
- Serialize detail.
- Redact secrets.
- Group by status.

### Integration / E2E tests

- Create package with events/artifacts and fetch board/detail.
- Verify worker-scoped API cannot fetch global board unless allowed.

### Negative / regression tests

- Do not expose raw secret hashes unless explicitly safe.
- Do not add mutating controls in this package.


## Deliverables

- Implementation PR for `SYMPP-P5-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P5-001: Dashboard API endpoints.

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

Package dependencies: SYMPP-P1-004, SYMPP-P1-005, SYMPP-P2-003.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
