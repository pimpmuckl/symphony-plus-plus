# SYMPP-P1-004 — Virtual planning file renderers

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 1 — Core ledger |
| Kind | core |
| Owner role | worker |
| Dependencies | SYMPP-P1-001 |

## Summary

Render context.md, task_plan.md, findings.md, progress.md, acceptance.md, review_suite.md, and handoff.md from canonical state.

## Implementation tasks

- Add PlanNode, Finding, ProgressEvent, and Artifact schemas/entities if not already present.
- Implement Markdown renderers for virtual files.
- Implement versioning or expected_version support for plan updates if feasible.
- Ensure empty state renders useful starter documents.
- Add snapshot-style tests for rendering.

## Acceptance criteria

- [ ] A new WorkPackage renders all required virtual files.
- [ ] Plan nodes render as checklists.
- [ ] Findings/progress are append-only in rendered order.
- [ ] Acceptance criteria render clearly.
- [ ] No local planning files are required as source of truth.

## Test plan

### Unit tests

- Render empty context/task_plan/findings/progress.
- Render plan with done/pending/skipped nodes.
- Render findings sorted by created time.
- Render progress timeline sorted by created time.
- Markdown output is stable enough for snapshot tests.

### Integration / E2E tests

- Create package, add plan/finding/progress, render all virtual files.
- Verify renderer works for hotfix and phase-child policy templates.

### Negative / regression tests

- Do not let renderer mutate state.
- Do not treat generated markdown exports as authoritative writes.


## Deliverables

- Implementation PR for `SYMPP-P1-004`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P1-004: Virtual planning file renderers.

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

Package dependencies: SYMPP-P1-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
