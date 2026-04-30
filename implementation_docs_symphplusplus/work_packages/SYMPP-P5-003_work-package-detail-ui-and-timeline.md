# SYMPP-P5-003 — Work package detail UI and timeline

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 5 — Dashboard |
| Kind | dashboard |
| Owner role | worker |
| Dependencies | SYMPP-P5-001 |

## Summary

Build detail view that shows virtual planning files, findings, progress timeline, artifacts, PR state, grants, and agent runs.

## Implementation tasks

- Add detail route/page.
- Render overview, scope, acceptance criteria, task plan, findings, progress timeline, artifacts, branch/PR state, grants/run summary.
- Redact sensitive fields.
- Add copyable package ID and PR link.

## Acceptance criteria

- [ ] Human can inspect a package without reading transcripts.
- [ ] Virtual planning file state is visible.
- [ ] Timeline is chronological.
- [ ] Sensitive fields are redacted.

## Test plan

### Unit tests

- Render helpers for timeline and plan status.
- Redaction helper if UI-side.

### Integration / E2E tests

- Create test package with plan/finding/progress/artifact and render detail.
- Verify missing data states.

### Negative / regression tests

- Do not expose raw secrets.
- Do not allow worker-scoped viewer to see sibling details.


## Deliverables

- Implementation PR for `SYMPP-P5-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P5-003: Work package detail UI and timeline.

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
