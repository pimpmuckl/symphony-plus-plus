# SYMPP-P5-002 — Dashboard board UI

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 5 — Dashboard |
| Kind | dashboard |
| Owner role | worker |
| Dependencies | SYMPP-P5-001 |

## Summary

Build the first human-facing board UI with status columns and compact work-package cards.

## Implementation tasks

- Add board route/page.
- Render columns by status.
- Render cards with ID, title, kind, repo/base, PR link, last update, blocker count, readiness indicators.
- Add filtering by kind/repo/phase if cheap.
- Keep UI read-only.

## Acceptance criteria

- [ ] Human can see active packages by status.
- [ ] Cards show enough information to detect stalled or blocked work.
- [ ] No raw secrets are displayed.
- [ ] Read-only UI does not alter state.

## Test plan

### Unit tests

- Component/render tests if UI framework supports them.
- Formatting helpers tested.

### Integration / E2E tests

- Fetch board API and render packages.
- Verify empty board state.

### Negative / regression tests

- Do not add merge/revoke controls yet.
- Do not require GitHub sync to render basic cards.


## Deliverables

- Implementation PR for `SYMPP-P5-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P5-002: Dashboard board UI.

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

Package dependencies: SYMPP-P5-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
